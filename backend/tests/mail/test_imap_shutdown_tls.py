import asyncio
import socket
import ssl
import subprocess
import sys
import threading
import time

import pytest

from feishu_lite.mail.imap import ImapAdapter
from feishu_lite.mail.types import MailError
from tests.mail.imap_server import imap_server
from tests.mail.test_imap_executor import adapter, ready


@pytest.fixture
def certificate(tmp_path):
    cert = tmp_path / 'synthetic-cert.pem'
    key = tmp_path / 'synthetic-key.pem'
    subprocess.run(['openssl', 'req', '-x509', '-newkey', 'rsa:2048', '-nodes', '-days', '1',
                    '-subj', '/CN=synthetic.invalid', '-addext', 'subjectAltName=IP:127.0.0.1',
                    '-keyout', str(key), '-out', str(cert)], check=True, capture_output=True)
    server_context = ssl.SSLContext(ssl.PROTOCOL_TLS_SERVER)
    server_context.load_cert_chain(cert, key)
    trusted = ssl.create_default_context(cafile=str(cert))
    return server_context, trusted


async def test_real_tls_trusted_certificate_and_required_hostname_verification(certificate):
    server_context, trusted = certificate
    async with imap_server(tls=server_context, idle=False) as server:
        client = ImapAdapter(adapter(server).config, tls_context=trusted)
        try:
            await ready(client)
            assert trusted.check_hostname and trusted.verify_mode == ssl.CERT_REQUIRED
            assert (await client.unseen()).value == [3, 9]
            assert isinstance(client.client.socket(), ssl.SSLSocket)
        finally:
            await client.stop()


async def test_real_tls_rejects_untrusted_certificate(certificate):
    async with imap_server(tls=certificate[0], idle=False) as server:
        client = ImapAdapter(adapter(server).config)
        try:
            with pytest.raises(MailError, match='tls_failed'):
                await client.connect()
        finally:
            await client.stop()
        assert not client.thread_alive


async def test_tls_rejects_wrong_hostname_even_when_ca_is_trusted(certificate, monkeypatch):
    async with imap_server(tls=certificate[0], idle=False) as server:
        original = socket.getaddrinfo
        monkeypatch.setattr(socket, 'getaddrinfo', lambda host, *args, **kwargs: original('127.0.0.1', *args, **kwargs))
        config = adapter(server).config.model_copy(update={'host': 'wrong.synthetic.invalid'})
        client = ImapAdapter(config, tls_context=certificate[1])
        try:
            with pytest.raises(MailError, match='tls_failed'):
                await client.connect()
        finally:
            await client.stop()


async def test_insecure_tls_context_is_rejected_before_connection():
    async with imap_server() as server:
        context = ssl._create_unverified_context()
        client = ImapAdapter(adapter(server).config, tls_context=context)
        try:
            with pytest.raises(MailError, match='insecure_transport'):
                await client.connect()
            assert not server.commands
        finally:
            await client.stop()


async def test_connection_tries_next_dns_address_without_leaking_failed_socket(monkeypatch):
    async with imap_server(idle=False) as server:
        original = socket.getaddrinfo
        good = original('127.0.0.1', server.port, type=socket.SOCK_STREAM)
        # A deterministic refused address before the actual scripted peer.
        bad = [(socket.AF_INET, socket.SOCK_STREAM, 6, '', ('127.0.0.1', 0))]
        monkeypatch.setattr(socket, 'getaddrinfo', lambda *args, **kwargs: bad + good)
        client = adapter(server)
        try:
            await ready(client)
            assert (await client.unseen()).value == [3, 9]
        finally:
            await client.stop()
        assert client.sock is None and not client.thread_alive


@pytest.mark.parametrize('phase', ['idle', 'done_stall', 'fetch_stall', 'half_line', 'greeting_stall', 'tls_stall', 'dns_stall', 'connect_stall'])
async def test_complete_service_subprocess_exits_within_two_seconds(phase, record_property):
    process = await asyncio.create_subprocess_exec(sys.executable, '-m', 'tests.mail.stop_child', phase,
                                                  stdin=asyncio.subprocess.PIPE, stdout=asyncio.subprocess.PIPE,
                                                  stderr=asyncio.subprocess.PIPE)
    try:
        assert await asyncio.wait_for(process.stdout.readline(), 5) == b'READY\n'
        start = time.monotonic()
        process.stdin.write(b'STOP\n')
        await process.stdin.drain()
        stdout, stderr = await asyncio.wait_for(process.communicate(), 2)
        elapsed = time.monotonic() - start
        print(f'TIMING stop_process {phase} {elapsed:.6f}')
        record_property('stop_signal_to_process_exit_seconds', elapsed)
        assert process.returncode == 0 and stderr == b'' and stdout == b'CLOSED\n', stderr.decode()
        assert elapsed < 2
    finally:
        if process.returncode is None:
            process.kill()
            await process.wait()


async def test_stop_while_dns_has_no_handle_retires_results_and_prevents_late_socket(monkeypatch):
    async with imap_server() as server:
        entered, released = threading.Event(), threading.Event()
        original = socket.getaddrinfo
        def slow_dns(*args, **kwargs):
            entered.set()
            released.wait(3)
            return original(*args, **kwargs)
        monkeypatch.setattr(socket, 'getaddrinfo', slow_dns)
        client = adapter(server)
        pending = asyncio.create_task(client.connect())
        while not entered.is_set():
            await asyncio.sleep(.005)
        try:
            with pytest.raises(MailError, match='stop_timeout'):
                await client.stop()
            assert client.sock is None and client.pending_count == 0
            with pytest.raises(MailError, match='executor_stopped'):
                await pending
        finally:
            released.set()
            await client.stop()
        assert not client.thread_alive and not server.commands


async def test_late_dns_completion_after_loop_close_still_runs_owner_cleanup(monkeypatch):
    async with imap_server() as server:
        entered, released = threading.Event(), threading.Event()
        original = socket.getaddrinfo
        escaped = []
        monkeypatch.setattr(threading, 'excepthook', lambda args: escaped.append(args.exc_type))
        def slow_dns(*args, **kwargs):
            entered.set()
            released.wait(3)
            return original(*args, **kwargs)
        monkeypatch.setattr(socket, 'getaddrinfo', slow_dns)
        client = adapter(server)
        pending = asyncio.create_task(client.connect())
        while not entered.is_set():
            await asyncio.sleep(.005)
        with pytest.raises(MailError, match='stop_timeout'):
            await client.stop()
        with pytest.raises(MailError, match='executor_stopped'):
            await pending
        # Reproduce shutdown of the owner loop without closing pytest's loop.
        closed_loop = asyncio.new_event_loop()
        closed_loop.close()
        client.loop = closed_loop
        released.set()
        deadline = time.monotonic() + 1
        while client.thread_alive and time.monotonic() < deadline:
            await asyncio.sleep(.01)
        assert not escaped and not client.thread_alive and client.phase == 'closed'
        assert not server.commands and client.sock is None
