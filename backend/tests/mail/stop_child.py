"""Full asyncio + FastAPI lifespan exit harness; synthetic IMAP only."""
import asyncio
import socket
import sys
import threading
import time
from contextlib import asynccontextmanager

from fastapi import FastAPI
from pydantic import SecretStr

from feishu_lite.mail.imap import ImapAdapter
from feishu_lite.mail.types import ImapConfig, MailError
from tests.mail.imap_server import imap_server


async def main(phase):
    scenario = 'greeting_stall' if phase == 'tls_stall' else 'normal' if phase in ('idle', 'dns_stall', 'connect_stall') else phase
    async with imap_server(scenario) as server:
        config = ImapConfig(account_id='synthetic-account', generation=1, host='127.0.0.1',
                            port=server.port, username=SecretStr('user@example.invalid'),
                            password=SecretStr('synthetic-password'))
        client = ImapAdapter(config, _plaintext_loopback=phase != 'tls_stall')
        dns_entered = threading.Event()
        connect_entered = threading.Event()
        if phase == 'connect_stall':
            original_socket = socket.socket
            class DelayedConnectSocket(original_socket):
                def connect(self, address):
                    self.unblock = threading.Event()
                    connect_entered.set()
                    self.unblock.wait(3)
                    raise ConnectionAbortedError()

                def shutdown(self, how):
                    self.unblock.set()
            socket.socket = DelayedConnectSocket
        if phase == 'dns_stall':
            original = socket.getaddrinfo
            def slow_dns(*args, **kwargs):
                dns_entered.set()
                time.sleep(3)
                return original(*args, **kwargs)
            socket.getaddrinfo = slow_dns
        tasks = []

        @asynccontextmanager
        async def lifespan(app):
            if phase in ('tls_stall', 'greeting_stall', 'dns_stall', 'connect_stall'):
                tasks.append(asyncio.create_task(client.connect()))
                if phase in ('dns_stall', 'connect_stall'):
                    entered = dns_entered if phase == 'dns_stall' else connect_entered
                    while not entered.is_set():
                        await asyncio.sleep(.005)
                else:
                    await server.events['connected'].wait()
            else:
                await client.connect()
                await client.select_inbox()
                await server.events['idle'].wait()
                if phase != 'idle':
                    tasks.append(asyncio.create_task(client.summaries([9])))
                    await server.events['done' if phase == 'done_stall' else 'fetch'].wait()
            try:
                yield
            finally:
                try:
                    await client.stop()
                except MailError as exc:
                    assert phase == 'dns_stall' and exc.code == 'stop_timeout'
                results = await asyncio.gather(*tasks, return_exceptions=True)
                assert all(isinstance(result, MailError) and result.code == 'executor_stopped' for result in results)
                assert client.pending_count == 0
                assert phase == 'dns_stall' or not client.thread_alive
                assert phase != 'dns_stall' or client.sock is None

        app = FastAPI(lifespan=lifespan)
        async with app.router.lifespan_context(app):
            stopped = asyncio.Event()
            loop = asyncio.get_running_loop()
            def on_input():
                if sys.stdin.readline().strip() == 'STOP':
                    stopped.set()
            loop.add_reader(sys.stdin.fileno(), on_input)
            print('READY', flush=True)
            await stopped.wait()
            loop.remove_reader(sys.stdin.fileno())
    assert not server.tasks and not server.writers
    print('CLOSED', flush=True)


if __name__ == '__main__':
    asyncio.run(main(sys.argv[1]))
