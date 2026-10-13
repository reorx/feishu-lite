"""Version-scoped IMAPClient 4.1.0 transport hardening.

IDLE/DONE, commands and protocol parsing remain library operations. This module
owns early socket publication, bounded raw reads and disabled protocol logging.
IMAPClient's nonblocking idle_check calls readline repeatedly: keep incomplete
lines across polls and bound each poll so continuous pushes cannot starve work.
No global monkeypatches; neither imaplib debug nor the library logger sees wire.
"""
import imaplib
import ipaddress
import logging
import socket
import ssl
import threading
import time
from dataclasses import dataclass

from imapclient import IMAPClient

from .types import MailError, MailLimits


class _OwnerLogFilter(logging.Filter):
    def filter(self, record):
        return not getattr(threading.current_thread(), 'mail_imap_owner', False)


# Library login/_raw_command log above imaplib.debug; mute only this executor's
# threads, leaving unrelated IMAPClient users and application logs untouched.
for _logger in ('imapclient.imapclient', 'imapclient.imaplib'):
    logging.getLogger(_logger).addFilter(_OwnerLogFilter())


class TransportLimitError(MailError):
    """Unread wire remains: connection must retire after this safe error."""


@dataclass
class TransportStats:
    literal_bytes: int = 0
    wire_bytes: int = 0


class BoundedIMAP4(imaplib.IMAP4):
    def __init__(self, host, port, *, context, stopped, publish, limits, stats, timeout):
        self.context = context
        self.stopped = stopped
        self.publish = publish
        self.limits = limits
        self.stats = stats
        self.buffer = bytearray()
        self.eof = False
        self.begin(timeout)
        # Publish the object even when __init__ later fails on greeting/TLS.
        publish(transport=self)
        super().__init__(host, port, timeout=timeout)
        self.debug = 0

    def _mesg(self, *args, **kwargs):
        pass

    def _log(self, *args, **kwargs):
        # imaplib retains raw commands/responses in a debug ring even at zero.
        # A disabled logger alone would still retain credentials in that ring.
        pass

    def _create_socket(self, timeout):
        # getaddrinfo has no portable cancellation. If DNS is slow, stop retires
        # the daemon; the stop check below prevents creating a late socket.
        addresses = socket.getaddrinfo(self.host, self.port, type=socket.SOCK_STREAM)
        if self.stopped.is_set():
            raise MailError('executor_stopped')
        sock = self._connect_tcp(addresses)
        if self.context is not None:
            sock = self.context.wrap_socket(sock, server_hostname=self.host, do_handshake_on_connect=False)
            self.publish(sock=sock)
            sock.settimeout(self.remaining())
            sock.do_handshake()
        sock.settimeout(self.remaining())
        return sock

    def _connect_tcp(self, addresses):
        # This is the top-level TCP establishment boundary: try DNS endpoints
        # serially under ONE deadline, and close each failed published socket.
        for family, kind, proto, _, address in addresses:
            sock = socket.socket(family, kind, proto)
            self.publish(sock=sock)
            try:
                sock.settimeout(self.remaining())
                sock.connect(address)
                return sock
            except OSError:
                sock.close()
                if self.stopped.is_set():
                    raise MailError('executor_stopped') from None
        raise MailError('disconnected')

    def begin(self, timeout, *, literal_limit=None, literal_code='response_too_large', polling=False):
        self.deadline = time.monotonic() + timeout
        self.response_bytes = 0
        self.literal_limit = literal_limit or self.limits.max_response_bytes
        self.literal_code = literal_code
        self.polling = polling
        self.depth = 0
        self.atoms = 0

    def remaining(self):
        if self.stopped.is_set() and not getattr(self, 'closing', False):
            raise MailError('executor_stopped')
        remaining = self.deadline - time.monotonic()
        if remaining <= 0:
            if self.polling:
                raise BlockingIOError()
            raise TimeoutError()
        return remaining

    def _receive(self, size):
        remaining = self.remaining()
        if not self.polling:
            self.sock.settimeout(remaining)
        data = self.sock.recv(min(size, 65536))
        if not data:
            self.eof = True
            raise imaplib.IMAP4.abort('EOF')
        self.stats.wire_bytes += len(data)
        return data

    def _count(self, size):
        self.response_bytes += size
        if self.response_bytes > self.limits.max_response_bytes:
            raise TransportLimitError('response_too_large')

    def read(self, size):
        # imaplib calls read(declared_literal_size); reject BEFORE allocating.
        if size > self.literal_limit:
            raise TransportLimitError(self.literal_code)
        if self.response_bytes + size > self.limits.max_response_bytes:
            raise TransportLimitError('response_too_large')
        data = bytearray()
        if self.buffer:
            count = min(size, len(self.buffer))
            data.extend(self.buffer[:count])
            del self.buffer[:count]
        while len(data) < size:
            data.extend(self._receive(size - len(data)))
        self._count(len(data))
        self.stats.literal_bytes += len(data)
        return bytes(data)

    def readline(self):
        while True:
            self.remaining()
            end = self.buffer.find(b'\n')
            if end >= 0:
                line = bytes(self.buffer[:end + 1])
                del self.buffer[:end + 1]
                self._count(len(line))
                self._check_complexity(line)
                return line
            if len(self.buffer) + self.response_bytes >= self.limits.max_response_bytes:
                raise TransportLimitError('response_too_large')
            budget = self.limits.max_response_bytes - self.response_bytes - len(self.buffer)
            self.buffer.extend(self._receive(budget))

    def _check_complexity(self, line):
        # Parentheses inside quotes are data. Scan before recursive library
        # parsing, including ignored message/rfc822 and unsolicited FETCH.
        if b' FETCH (' in line:
            self.depth = 0
            self.atoms = 0
        elif self.depth == 0:
            return
        quoted = escaped = False
        for char in line:
            if escaped:
                escaped = False
            elif quoted and char == 92:
                escaped = True
            elif char == 34:
                quoted = not quoted
            elif not quoted:
                if char == 40:
                    self.depth += 1
                    if self.depth > self.limits.max_depth * 3 + 3:
                        raise TransportLimitError('mime_too_deep')
                elif char == 41:
                    self.depth -= 1
                if char in (32, 40, 41):
                    self.atoms += 1
                    if self.atoms > self.limits.max_parts * 64:
                        raise TransportLimitError('too_many_parts')

    def send(self, data):
        self.sock.settimeout(self.remaining())
        super().send(data)


class BoundedClient(IMAPClient):
    def __init__(self, config, *, context, stopped, publish, limits, stats, timeout, plaintext=False):
        if plaintext and not ipaddress.ip_address(config.host).is_loopback:
            raise MailError('insecure_transport')
        if not plaintext and (context.verify_mode != ssl.CERT_REQUIRED or not context.check_hostname):
            raise MailError('insecure_transport')
        self.transport_options = dict(context=None if plaintext else context, stopped=stopped,
                                      publish=publish, limits=limits, stats=stats, timeout=timeout)
        super().__init__(config.host, port=config.port, ssl=not plaintext, ssl_context=context, timeout=timeout)
        # IMAPClient sets debug=5 and logger adapters after construction.
        self._imap.debug = 0
        self._imap._mesg = lambda *args, **kwargs: None
        self.normalise_times = False

    def _create_IMAP4(self):
        return BoundedIMAP4(self.host, self.port, **self.transport_options)

    def idle_check(self, timeout=None):
        result = super().idle_check(timeout)
        if self._imap.eof:
            raise MailError('disconnected')
        return result
