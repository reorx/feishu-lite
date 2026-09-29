import asyncio
import contextlib
import json
import os
import tempfile

# larkx reads LARKX_HOME at import time; never let tests touch real credentials.
os.environ['LARKX_HOME'] = tempfile.mkdtemp(prefix='larkx-test-')

import httpx
import pytest
import uvicorn

from feishu_lite.api import create_app
from feishu_lite.service import Service
from feishu_lite.store import Store

from .fakes import FakeSource

TOKEN = 'test-token'


class _Server(uvicorn.Server):
    @contextlib.contextmanager
    def capture_signals(self):
        yield


class EventStream:
    """Collects SSE events from GET /events in the background."""

    def __init__(self, client):
        self.client = client
        self.events: list[tuple[str, dict]] = []
        self._changed = asyncio.Condition()
        self._task = None
        self._opened = asyncio.Event()

    async def __aenter__(self):
        self._task = asyncio.create_task(self._run())
        await asyncio.wait_for(self._opened.wait(), 5)
        return self

    async def __aexit__(self, *exc):
        self._task.cancel()
        with contextlib.suppress(asyncio.CancelledError):
            await self._task

    async def _run(self):
        async with self.client.stream('GET', '/events', timeout=None) as resp:
            assert resp.status_code == 200
            self._opened.set()
            name = None
            async for line in resp.aiter_lines():
                if line.startswith('event:'):
                    name = line.split(':', 1)[1].strip()
                elif line.startswith('data:') and name:
                    data = json.loads(line.split(':', 1)[1])
                    async with self._changed:
                        self.events.append((name, data))
                        self._changed.notify_all()
                    name = None

    async def wait_for(self, predicate, timeout=3):
        async def _wait():
            async with self._changed:
                while True:
                    for name, data in self.events:
                        if predicate(name, data):
                            return name, data
                    await self._changed.wait()

        return await asyncio.wait_for(_wait(), timeout)

    def named(self, name):
        return [data for n, data in self.events if n == name]


class Harness:
    def __init__(self, source, service, client):
        self.source = source
        self.service = service
        self.client = client

    def events(self):
        return EventStream(self.client)

    async def wait_state(self, state, timeout=3):
        async def _wait():
            while self.service.state != state:
                await asyncio.sleep(0.01)

        await asyncio.wait_for(_wait(), timeout)

    async def chats(self):
        resp = await self.client.get('/chats')
        assert resp.status_code == 200
        return resp.json()

    async def chat(self, chat_id):
        return next(c for c in await self.chats() if c['id'] == chat_id)


@pytest.fixture
def source():
    return FakeSource()


@pytest.fixture
async def make_backend(tmp_path):
    """Start service + HTTP server in-process against the given FakeSource."""
    started = []

    async def _make(source, wait_online=True):
        store = Store(tmp_path / 'cache.db')
        service = Service(source, store, backoff=(0.05, 0.05, 0.1), qr_poll_interval=0.01, resync_interval=3600)
        app = create_app(service, TOKEN)
        server = _Server(uvicorn.Config(app, host='127.0.0.1', port=0, log_level='warning', lifespan='on'))
        task = asyncio.create_task(server.serve())
        while not server.started:
            await asyncio.sleep(0.01)
        port = server.servers[0].sockets[0].getsockname()[1]
        client = httpx.AsyncClient(base_url=f'http://127.0.0.1:{port}', headers={'Authorization': f'Bearer {TOKEN}'})
        started.append((server, task, client))
        h = Harness(source, service, client)
        if wait_online:
            await h.wait_state('online')
        return h

    yield _make
    for server, task, client in started:
        await client.aclose()
        server.should_exit = True
        await asyncio.wait_for(task, 5)


@pytest.fixture
async def backend(source, make_backend):
    return await make_backend(source)
