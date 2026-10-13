"""MailService + real C2 owner + Store, full isolated subprocess shutdown."""
import asyncio
import socket
import sys
import tempfile
import threading
import time
from pathlib import Path

from pydantic import SecretStr

from feishu_lite.mail.imap import ImapAdapter
from feishu_lite.mail.service import MailService
from feishu_lite.mail.store import MailStore
from tests.mail.imap_server import imap_server


async def main(phase):
    with tempfile.TemporaryDirectory() as directory:
        store = MailStore(Path(directory)/'mail.db')
        async with imap_server('greeting_stall' if phase == 'greeting' else 'normal') as server:
            owners = []
            def factory(config):
                io = ImapAdapter(config.model_copy(update={'host':'127.0.0.1', 'port':server.port}),
                                 _plaintext_loopback=True)
                owners.append(io)
                return io
            service = MailService(store, adapter_factory=factory)
            dns_entered = threading.Event()
            if phase == 'dns':
                original = socket.getaddrinfo
                def stalled_dns(*args, **kwargs):
                    dns_entered.set()
                    time.sleep(4)
                    return original(*args, **kwargs)
                socket.getaddrinfo = stalled_dns
            await service.start()
            await service.configure('synthetic@example.invalid',SecretStr('synthetic-password'))
            requests = []
            if phase == 'dns':
                while not dns_entered.is_set():
                    await asyncio.sleep(.005)
            elif phase == 'greeting':
                await server.events['connected'].wait()
            else:
                await service.refresh()
                if phase == 'fetch':
                    server.scenario = 'fetch_stall'
                    server.events['fetch'].clear()
                    requests.append(asyncio.create_task(service.body((await service.messages()).items[0].key.id)))
                    await server.events['fetch'].wait()
                else:
                    # Exercise both network and render-only owners together.
                    message_id = (await service.messages()).items[0].key.id
                    await service.body(message_id)
                    await service.body(message_id)
                    await server.events['idle'].wait()
            stopped = asyncio.Event()
            loop = asyncio.get_running_loop()
            def on_input():
                if sys.stdin.readline().strip() == 'STOP':
                    stopped.set()
            loop.add_reader(sys.stdin.fileno(),on_input)
            print('READY',flush=True)
            await stopped.wait()
            loop.remove_reader(sys.stdin.fileno())
            await service.stop()
            await asyncio.gather(*requests,return_exceptions=True)
            assert all(not io.thread_alive for io in owners) or phase == 'dns'
            assert all(io.pending_count == 0 for io in owners)
            assert loop._default_executor is None
            store.close()
        assert not server.tasks and not server.writers
    print('CLOSED',flush=True)


if __name__ == '__main__':
    asyncio.run(main(sys.argv[1]))
