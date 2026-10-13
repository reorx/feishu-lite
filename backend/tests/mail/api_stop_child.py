"""Production create_app + BackendServer/_serve, HTTP/SSE and real C2 owners."""
import asyncio
import contextlib
import socket
import shutil
import sqlite3
import sys
import tempfile
import threading
import time
from pathlib import Path

import httpx
import uvicorn

from feishu_lite.api import create_app
from feishu_lite.mail.imap import ImapAdapter
from feishu_lite.mail.service import MailService
from feishu_lite.main import BackendServer, _serve
from feishu_lite.service import Service
from feishu_lite.store import Store
from tests.conftest import TOKEN
from tests.fakes import FakeSource
from tests.mail.imap_server import ScriptedIMAP


async def main(phase):
    with tempfile.TemporaryDirectory(prefix='c3b-api-stop-') as directory:
        path = Path(directory)
        peer = await ScriptedIMAP('greeting_stall' if phase == 'greeting' else 'normal').start()
        owners = []
        def adapter(config):
            io = ImapAdapter(config.model_copy(update={'host':'127.0.0.1','port':peer.port}),
                             _plaintext_loopback=True)
            owners.append(io)
            return io
        def mail_factory(store, *, emit):
            return MailService(store, adapter_factory=adapter, emit=emit)
        source = FakeSource()
        source.has_credentials = False
        store = Store(path/'cache.db')
        app = create_app(Service(source,store), TOKEN, mail_path=path/'mail.db',mail_factory=mail_factory)
        # Audit after the actual lifespan has closed Store, before Uvicorn
        # replays SIGTERM. Close synthetic peer/client resources at this point.
        original_lifespan = app.router.lifespan_context
        clients = []
        requests = []
        @contextlib.asynccontextmanager
        async def audited_lifespan(app):
            async with original_lifespan(app):
                yield
            assert all(io.pending_count == 0 for io in owners)
            assert all(not io.thread_alive for io in owners) or phase == 'dns-probes'
            assert asyncio.get_running_loop()._default_executor is None
            try:
                app.state.mail.store.db.execute('SELECT 1')
                raise AssertionError('store still open')
            except sqlite3.ProgrammingError:
                pass
            await asyncio.gather(*requests,return_exceptions=True)
            for client in clients:
                await client.aclose()
            await peer.close()
            store.db.close()
            assert not peer.tasks and not peer.writers
            shutil.rmtree(path)  # SIGTERM replay bypasses TemporaryDirectory.__exit__.
            print('CLOSED',flush=True)
        app.router.lifespan_context = audited_lifespan
        server = BackendServer(uvicorn.Config(app,host='127.0.0.1',port=0,log_level='critical',
                                              access_log=False,timeout_graceful_shutdown=.2))
        task = asyncio.create_task(_serve(server,None))
        while not server.started:
            await asyncio.sleep(.005)
        port = server.servers[0].sockets[0].getsockname()[1]
        client = httpx.AsyncClient(base_url=f'http://127.0.0.1:{port}',headers={'Authorization':f'Bearer {TOKEN}'})
        clients.append(client)
        payload = {'address':'synthetic@example.invalid','password':'synthetic-password'}
        if phase == 'dns-probes':
            entered = threading.Event()
            original = socket.getaddrinfo
            def stalled_dns(*args,**kwargs):
                # HTTP client/server must keep their own resolver operational.
                if threading.current_thread().name.startswith('mail-imap'):
                    entered.set()
                    time.sleep(5)
                return original(*args,**kwargs)
            socket.getaddrinfo = stalled_dns
        await client.put('/mail/account',json=payload)
        if phase == 'dns-probes':
            while not entered.is_set():
                await asyncio.sleep(.005)
            requests.append(asyncio.create_task(client.post('/mail/account/test',json=payload)))
            while len(owners) < 2:
                await asyncio.sleep(.005)
        elif phase == 'greeting':
            await peer.events['connected'].wait()
            requests.append(asyncio.create_task(client.post('/mail/account/test',json=payload)))
            while len(owners) < 2:
                await asyncio.sleep(.005)
        else:
            assert (await client.post('/mail/sync')).status_code == 200
            page = (await client.get('/mail/messages')).json()
            from feishu_lite.mail.types import MailKey
            message_id = MailKey.model_validate(page['items'][0]['key']).id
            if phase == 'fetch':
                peer.scenario = 'fetch_stall'
                peer.events['fetch'].clear()
                requests.append(asyncio.create_task(client.get('/mail/messages/'+message_id)))
                await peer.events['fetch'].wait()
            elif phase == 'probe':
                peer.scenario = 'greeting_stall'
                peer.events['connected'].clear()
                requests.append(asyncio.create_task(client.post('/mail/account/test',json=payload)))
                await peer.events['connected'].wait()
            else:
                await client.get('/mail/messages/'+message_id)
                await client.get('/mail/messages/'+message_id)
                await peer.events['idle'].wait()
        async def consume_sse():
            async with client.stream('GET','/events',timeout=None) as response:
                async for line in response.aiter_lines():
                    if line.startswith('event:'):
                        sse_open.set()
        sse_open = asyncio.Event()
        requests.append(asyncio.create_task(consume_sse()))
        await sse_open.wait()
        print('READY',flush=True)
        await task


if __name__ == '__main__':
    asyncio.run(main(sys.argv[1]))
