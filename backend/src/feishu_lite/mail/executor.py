"""One bounded priority queue and one daemon owner per IMAP connection.

Only the asyncio thread owns futures; worker delivery uses call_soon_threadsafe.
Cancellation discards queued/late results; a command already on the wire runs to
its finite deadline (a sent STORE cannot be undone). Fatal wire errors retire
this instance; C3 creates a new generation and owns reconnection policy.
"""
import asyncio
import heapq
import imaplib
import itertools
import socket
import ssl
import threading
import time
import uuid
from dataclasses import dataclass, field
from typing import Callable

from imapclient.exceptions import IMAPClientError, ProtocolError
from pydantic import ValidationError

from .transport import BoundedClient, TransportLimitError, TransportStats
from .types import ImapIdentity, ImapResult, MailAuthenticationError, MailError, MailLimits


@dataclass(order=True)
class WorkItem:
    priority: int
    sequence: int
    operation: Callable = field(compare=False, repr=False)
    cancelled: threading.Event = field(default_factory=threading.Event, compare=False)


class ImapExecutor:
    def __init__(self, config, *, limits=MailLimits(), queue_size=64,
                 command_timeout=10., done_timeout=.6, idle_poll=.05,
                 idle_renew=28 * 60, tls_context=None, _plaintext_loopback=False):
        if queue_size < 1 or not 0 < done_timeout <= .8 or not 0 < idle_poll <= .5 or not 0 < idle_renew <= 29 * 60 or command_timeout <= 0:
            raise ValueError('invalid executor limits')
        self.config = config
        self.identity = ImapIdentity(account_id=config.account_id, generation=config.generation, connection_id=uuid.uuid4().hex)
        self.limits = limits
        self.queue_size = queue_size
        self.command_timeout = command_timeout
        self.done_timeout = done_timeout
        self.idle_poll = idle_poll
        self.idle_renew = idle_renew
        self.context = tls_context or ssl.create_default_context()
        self.plaintext = _plaintext_loopback
        self.transport_stats = TransportStats()
        self.stopped = threading.Event()
        self.condition = threading.Condition()
        self.queue = []
        self.sequence = itertools.count()
        self.pending = {}
        self.thread = None
        self.client = None
        self.transport = None
        self.sock = None
        self.selected = None
        self.loop = None
        self.reconcile_needed = asyncio.Event()
        self.closed = asyncio.Event()
        self.failure = None
        self.phase = 'new'

    @property
    def thread_alive(self):
        return self.thread is not None and self.thread.is_alive()

    @property
    def pending_count(self):
        return len(self.pending)

    def _publish(self, *, sock=None, transport=None):
        with self.condition:
            if transport is not None:
                self.transport = transport
            if sock is not None:
                self.sock = sock
                if self.stopped.is_set():
                    sock.close()
                    raise MailError('executor_stopped')

    async def submit(self, operation, *, priority=10):
        loop = asyncio.get_running_loop()
        if self.loop is None:
            self.loop = loop
        if self.loop is not loop:
            raise MailError('wrong_event_loop')
        with self.condition:
            if self.stopped.is_set():
                raise MailError('executor_stopped')
            # Remove cancelled entries so they do not consume queue capacity.
            self.queue = [work for work in self.queue if not work.cancelled.is_set()]
            heapq.heapify(self.queue)
            if len(self.queue) >= self.queue_size:
                raise MailError('queue_full')
            work = WorkItem(priority, next(self.sequence), operation)
            future = loop.create_future()
            self.pending[work.sequence] = future
            heapq.heappush(self.queue, work)
            self.condition.notify()
            if self.thread is None:
                self.thread = threading.Thread(target=self._run, name=f'mail-imap-{self.identity.connection_id[:8]}', daemon=True)
                self.thread.start()
        try:
            return await future
        finally:
            work.cancelled.set()
            self.pending.pop(work.sequence, None)

    def _deliver(self, work, value=None, error=None):
        future = self.pending.pop(work.sequence, None)
        if future is None or future.done():
            return
        if self.stopped.is_set() and error is None:
            error = MailError('executor_stopped')
        if error is not None:
            future.set_exception(error)
        else:
            future.set_result(ImapResult(identity=self.identity, value=value))

    def _signal_reconcile(self):
        if not self.stopped.is_set():
            self.reconcile_needed.set()

    def _post(self, callback, *args):
        # Top-level cross-thread delivery boundary. DNS can finish after the
        # stopping loop has closed; callback loss must not skip owner cleanup.
        try:
            self.loop.call_soon_threadsafe(callback, *args)
        except RuntimeError:
            self.stopped.set()

    def _fail_pending(self, error):
        for future in self.pending.values():
            if not future.done():
                future.set_exception(MailError(error.code))
        self.pending.clear()

    def _finished(self, failure):
        self.failure = failure
        self._fail_pending(failure or MailError('executor_stopped'))
        self.closed.set()

    def _connect(self):
        self.phase = 'connect'
        self.client = BoundedClient(self.config, context=self.context, stopped=self.stopped,
                                    publish=self._publish, limits=self.limits, stats=self.transport_stats,
                                    timeout=self.command_timeout, plaintext=self.plaintext)
        self.transport.begin(self.command_timeout)
        self.phase = 'authenticate'
        self.client.login(self.config.username.get_secret_value(), self.config.password.get_secret_value())
        self.phase = 'command'
        return tuple(cap.decode('ascii') for cap in self.client.capabilities())

    def _run(self):
        threading.current_thread().mail_imap_owner = True
        fatal = None
        try:
            while not self.stopped.is_set():
                work = self._next_work()
                if work is not None:
                    self._execute(work)
                elif self.selected is not None and self.client.has_capability('IDLE'):
                    self._idle()
                else:
                    with self.condition:
                        if not self.queue and not self.stopped.is_set():
                            self.condition.wait(.1)
        except Exception as exc:
            # Owner thread is the top-level network/error boundary. Never
            # deliver raw exception/cause/traceback to callers or log it.
            fatal = None if self.stopped.is_set() else self._safe_error(exc)
        finally:
            self.stopped.set()
            self._cleanup()
            self._post(self._finished, fatal)

    def _next_work(self):
        with self.condition:
            while self.queue:
                work = heapq.heappop(self.queue)
                if not work.cancelled.is_set():
                    return work
        return None

    def _execute(self, work):
        # Per-work boundary: malformed individual records and rejected commands
        # can fail without corrupting an otherwise synchronized connection.
        try:
            self.phase = 'command'
            if self.transport is not None:
                self.transport.begin(self.command_timeout)
            value = work.operation()
        except Exception as exc:
            error = self._safe_error(exc)
            self._post(self._deliver, work, None, error)
            if isinstance(exc, TransportLimitError) or error.code not in ('command_rejected', 'mailbox_readonly', 'message_missing',
                                  'stale_message', 'unsupported_folder', 'unsupported_body',
                                  'invalid_page_size', 'invalid_uid', 'invalid_batch',
                                  'mailbox_not_selected', 'already_connected', 'body_too_large',
                                  'seen_not_persisted',
                                  'malformed_encoding', 'unsupported_charset', 'unsupported_transfer_encoding'):
                raise MailError(error.code) from None
        else:
            self._post(self._deliver, work, value)

    def _idle(self):
        self.phase = 'idle_start'
        self.transport.begin(self.command_timeout)
        self.client.idle()
        renew_at = time.monotonic() + self.idle_renew
        self.phase = 'idle_poll'
        while not self.stopped.is_set() and time.monotonic() < renew_at:
            with self.condition:
                if self.queue:
                    break
            self.transport.begin(self.idle_poll * 2, polling=True)
            signals = self.client.idle_check(timeout=self.idle_poll)
            if signals:
                self._post(self._signal_reconcile)
        self.phase = 'idle_done'
        self.transport.closing = self.stopped.is_set()
        self.transport.begin(self.done_timeout)
        signals = self.client.idle_done()[1]
        if signals:
            self._post(self._signal_reconcile)

    def _safe_error(self, exc):
        if isinstance(exc, MailError):
            return MailError(exc.code)
        if self.stopped.is_set():
            return MailError('executor_stopped')
        if isinstance(exc, ssl.SSLError):
            return MailError('tls_failed')
        if isinstance(exc, (TimeoutError, socket.timeout)):
            return MailError('idle_done_timeout' if self.phase == 'idle_done' else 'command_timeout')
        if isinstance(exc, imaplib.IMAP4.readonly):
            return MailError('mailbox_readonly')
        if isinstance(exc, (imaplib.IMAP4.abort, OSError)):
            return MailError('disconnected')
        if isinstance(exc, (ProtocolError, ValueError, TypeError, KeyError, UnicodeError, ValidationError)):
            return MailError('malformed_response')
        if isinstance(exc, (IMAPClientError, imaplib.IMAP4.error)):
            return MailAuthenticationError() if self.phase == 'authenticate' else MailError('command_rejected')
        return MailError('imap_failed')

    def _cleanup(self):
        # Cleanup is another top-level boundary; a broken peer must not hide
        # the original safe error or prevent closing every published handle.
        try:
            if self.client is not None and self.phase in ('command', 'idle_done', 'idle_poll'):
                self.transport.closing = True
                self.transport.begin(.25)
                self.client.logout()
        except Exception:
            pass
        finally:
            if self.transport is not None and getattr(self.transport, 'file', None) is not None:
                self.transport.file.close()
            if self.sock is not None:
                self.sock.close()
            with self.condition:
                self.queue.clear()
                self.sock = None
            self.phase = 'closed'

    async def stop(self):
        if self.loop is not None and self.loop is not asyncio.get_running_loop():
            raise MailError('wrong_event_loop')
        self.stopped.set()
        self._fail_pending(MailError('executor_stopped'))
        if self.thread is None:
            self.closed.set()
        with self.condition:
            self.condition.notify_all()
        deadline = time.monotonic() + 1.5
        # Give idle polling/empty queue a brief chance for DONE + LOGOUT.
        if self.phase in ('idle_poll', 'idle_done'):
            self.transport.closing = True
            grace = time.monotonic() + .15
            while self.thread_alive and time.monotonic() < grace:
                await asyncio.sleep(.01)
        self._shutdown_socket()
        while self.thread_alive and time.monotonic() < deadline:
            await asyncio.sleep(.01)
        if self.thread_alive:
            # Only platform DNS can lack a cancellable socket. Results are
            # retired immediately; daemon will stop before a late connect.
            raise MailError('stop_timeout')

    def _shutdown_socket(self):
        # socket.shutdown is the sole cross-thread socket operation. It is a
        # deliberate extension of IMAPClient's public polling-only socket API.
        with self.condition:
            sock = self.sock
        if sock is not None:
            try:
                sock.shutdown(socket.SHUT_RDWR)
            except OSError:
                pass
