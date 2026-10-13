"""Independent mail orchestration; no FastAPI, chat lifecycle or thread-pool work.

The caller owns Store creation/closure on this event loop. C2 owns protocol and
MIME work. One runner coalesces refresh/IDLE/periodic work; user body/Seen calls
use C2's priority queue. Every awaited result is fenced before SQLite or emit.
"""
import asyncio
import time
import uuid
from collections.abc import Callable

from pydantic import SecretStr

from .imap import ImapAdapter
from .store import MailStore
from .types import (ImapConfig, MailAccount, MailAccountChange, MailConnectionTest,
                    MailCursor, MailError, MailEvent, MailKey, MailNotification,
                    MailPage, MailStatus, MailSummary)

PARSER_ERRORS = frozenset({'malformed_response', 'response_too_large', 'headers_too_large',
                          'mime_too_deep', 'too_many_parts'})


def chunks(values, size=100):
    values = list(values)
    return [values[index:index + size] for index in range(0, len(values), size)]


class MailService:
    def __init__(self, store: MailStore, *, adapter_factory: Callable[[ImapConfig], ImapAdapter] = ImapAdapter,
                 clock: Callable[[], float] = time.time, emit: Callable[[MailEvent], None] = lambda event: None,
                 reconcile_interval=45., retry_delays=(1., 2., 5., 10., 30., 60.),
                 push_interval=.1):
        if not 0 < reconcile_interval <= 60 or push_interval <= 0 or not retry_delays or any(d <= 0 for d in retry_delays):
            raise ValueError('invalid mail scheduling limits')
        self.store = store
        self.factory = adapter_factory
        self.clock = clock
        self.emit = emit
        self.interval = reconcile_interval
        self.retry_delays = retry_delays
        self.push_interval = push_interval
        self.account = None
        self.password = None
        self.state = 'unconfigured'
        self.error = None
        self.generation = 0
        self.epoch = 0
        self.io = None
        self.renderer = None
        self.retired = []
        self.owner_stops = {}
        self.probes = set()
        self.runner = None
        self.wake = asyncio.Event()
        self.round_future = None
        self.reconnect_requested = False
        self.lifecycle = asyncio.Lock()
        self.sync_lock = asyncio.Lock()
        self.read_lock = asyncio.Lock()
        self.started = False
        self.stopping = False
        self.fetch_reconnections = 0
        self.unseen_revision = 0

    async def start(self):
        if self.stopping:
            raise MailError('service_stopped')
        if self.started:
            return
        accounts = self.store.accounts()
        if len(accounts) > 1:
            raise MailError('account_config_invalid')
        self.account = accounts[0] if accounts else None
        self.state = 'credential_missing' if self.account else 'unconfigured'
        self.started = True
        self._emit_status()

    def _sync_state(self):
        if self.account and self.store.has_folder(self.account.id, 'INBOX'):
            return self.store.sync_state(self.account.id, 'INBOX')
        return None

    def _notifications(self):
        if self._sync_state() is None:
            return []
        return [MailNotification(id=batch.id, account_id=batch.account_id,
                                 uidvalidity=batch.uidvalidity,
                                 mode='summary' if batch.id.startswith('summary:') else 'individual',
                                 items=[self.store.get_summary(key) for key in batch.keys])
                for batch in self.store.pending(self.account.id, 'INBOX')]

    def status(self) -> MailStatus:
        state = self._sync_state()
        return MailStatus(mail_account_id=self.account.id if self.account else None,
                          address=self.account.address if self.account else None,
                          state=self.state, generation=self.generation,
                          uidvalidity=state.uidvalidity if state else None,
                          last_sync_at=state.checked_at if state else None,
                          unread_count=state.unread_count if state else 0,
                          unread_stale=self.state != 'online', pending=self._notifications(),
                          error=self.error)

    def _event(self, kind, **fields):
        state = self._sync_state()
        return MailEvent(type=kind, account_id=self.account.id if self.account else None,
                         generation=self.generation, uidvalidity=state.uidvalidity if state else None,
                         **fields)

    def _emit_status(self):
        self.emit(self._event('mail.status', status=self.status()))

    def _set_state(self, state, error=None):
        self.state, self.error = state, error
        self._emit_status()

    def _require_started(self):
        if not self.started or self.stopping:
            raise MailError('service_stopped')

    def _require_account(self, account_id=None):
        self._require_started()
        if self.account is None:
            raise MailError('unconfigured')
        if account_id is not None and account_id != self.account.id:
            raise MailError('account_mismatch')

    def _check_epoch(self, epoch):
        if epoch != self.epoch or self.stopping:
            raise MailError('stale_request')

    def _value(self, io, result, epoch, validity=None):
        self._check_epoch(epoch)
        if io is not self.io or result.identity != io.identity or result.identity.account_id != self.account.id:
            raise MailError('stale_request')
        if validity is not None:
            state = self._sync_state()
            if state is None or state.uidvalidity != validity:
                raise MailError('stale_message')
        return result.value

    def _config(self, account, password):
        self.generation += 1
        return ImapConfig(account_id=account.id, generation=self.generation,
                          username=SecretStr(account.address), password=password)

    async def configure(self, address: str, password: SecretStr) -> MailAccountChange:
        async with self.lifecycle:
            self._require_started()
            if self.account and self.account.address == address:
                await self._inject(password)
                return MailAccountChange(account=self.account)
            old = self.account.id if self.account else None
            await self._cancel_account_work()
            if old:
                self.store.remove_account(old)
            self.account = MailAccount(id=str(uuid.uuid4()), address=address)
            self.store.save_account(self.account.id, address)
            self.password = password
            self._set_state('connecting')
            self._start_runner()
            return MailAccountChange(account=self.account, removed_account_id=old)

    async def inject_credential(self, account_id: str, password: SecretStr):
        async with self.lifecycle:
            self._require_account(account_id)
            await self._inject(password)

    async def _inject(self, password):
        # Identical rejected credentials are not a credential change either.
        if self.password == password and (self.state == 'auth_failed' or
                                         self.runner and not self.runner.done()):
            return
        await self._cancel_account_work()
        self.password = password
        self._set_state('connecting')
        self._start_runner()

    async def remove_account(self) -> MailAccountChange:
        async with self.lifecycle:
            self._require_started()
            old = self.account.id if self.account else None
            await self._cancel_account_work()
            if old:
                self.store.remove_account(old)
            self.account = None
            self.password = None
            self._set_state('unconfigured')
            return MailAccountChange(removed_account_id=old)

    async def test_connection(self, address: str, password: SecretStr) -> MailConnectionTest:
        # No account mutation, Store writes or pending notification side effects.
        async with self.lifecycle:
            self._require_started()
            self._require_owners_closed()
            if self.probes:
                raise MailError('connection_test_busy')
            account = MailAccount(id=str(uuid.uuid4()), address=address)
            io = self.factory(ImapConfig(account_id=account.id, generation=1,
                                        username=SecretStr(address), password=password))
            self.probes.add(io)
        try:
            capabilities = (await io.connect()).value
            await io.list_folders()
            selected = (await io.select_inbox()).value
            self._require_started()
            return MailConnectionTest(writable=not selected.readonly and
                                      bool({'\\seen', '\\*'} & {f.lower() for f in selected.permanent_flags}),
                                      supports_idle='IDLE' in capabilities)
        finally:
            await self._stop_owner(io)
            self.probes.discard(io)

    def _start_runner(self):
        if self.runner is None or self.runner.done():
            self.runner = asyncio.create_task(self._run(self.epoch), name='mail-sync')

    async def refresh(self, *, reconnect=False, wait=True):
        self._require_account()
        if self.password is None:
            raise MailError('credential_missing')
        if self.state == 'auth_failed':
            raise MailError('authentication_failed')
        self.reconnect_requested |= reconnect
        if self.round_future is None or self.round_future.done():
            self.round_future = asyncio.get_running_loop().create_future()
            # wait=False / disconnected client still must consume a safe error.
            self.round_future.add_done_callback(lambda future: future.exception() if not future.cancelled() else None)
        future = self.round_future
        self.wake.set()
        self._start_runner()
        if wait:
            await asyncio.shield(future)

    def _complete_round(self, error=None):
        future = self.round_future
        self.round_future = None
        if future and not future.done():
            if error:
                future.set_exception(MailError(error))
            else:
                future.set_result(None)

    def _require_owners_closed(self):
        self.retired = [io for io in self.retired if not io.closed.is_set()]
        self.owner_stops = {io: task for io, task in self.owner_stops.items() if not io.closed.is_set()}
        if self.retired:
            raise MailError('stop_timeout')

    async def _stop_owner(self, io):
        # Track retirement BEFORE awaiting it. Cancelling the runner during a
        # stop must neither cancel owner cleanup nor lose the last reference.
        if io not in self.owner_stops:
            self.retired.append(io)
            task = asyncio.create_task(self._finish_owner_stop(io), name='mail-owner-stop')
            task.add_done_callback(lambda future: future.exception() if not future.cancelled() else None)
            self.owner_stops[io] = task
        await asyncio.shield(self.owner_stops[io])
        if io.closed.is_set():
            self.retired = [owner for owner in self.retired if owner is not io]
            self.owner_stops.pop(io, None)

    async def _finish_owner_stop(self, io):
        # Top-level owner lifecycle boundary: C2 has a finite 1.5 s DNS limit.
        try:
            await io.stop()
        except MailError as exc:
            if exc.code != 'stop_timeout':
                raise
            self.error = 'stop_timeout'

    async def _retire_network(self):
        io, self.io = self.io, None
        if io:
            await self._stop_owner(io)

    async def _cancel_account_work(self):
        self.epoch += 1  # fence all caller-owned in-flight body/page/Seen requests
        self._complete_round('stale_request')
        runner, self.runner = self.runner, None
        if runner:
            runner.cancel()
        owners = {io for io in (self.io, self.renderer, *self.probes, *self.retired) if io is not None}
        self.io = self.renderer = None
        # Both owners stop concurrently; no additive 1.5 s join deadline.
        await asyncio.gather(*(self._stop_owner(io) for io in owners))
        if runner:
            await asyncio.gather(runner, return_exceptions=True)
        self.reconnect_requested = False
        self.wake.clear()

    async def stop(self):
        async with self.lifecycle:
            if self.stopping:
                return
            self.stopping = True
            await self._cancel_account_work()
            self.password = None
            self.started = False

    async def _open(self, epoch, *, import_history=True):
        self._require_owners_closed()
        self._check_epoch(epoch)
        self.io = self.factory(self._config(self.account, self.password))
        io = self.io
        self._set_state('connecting')
        self._value(io, await io.connect(), epoch)
        folders = self._value(io, await io.list_folders(), epoch)
        selected = self._value(io, await io.select_inbox(), epoch)
        inbox = next((f for f in folders if f.id == 'INBOX' and f.supported and f.selectable), None)
        if inbox is None:
            raise MailError('inbox_missing')
        state = self._sync_state()
        reset = state is None or state.uidvalidity != selected.uidvalidity
        self.store.save_folders(self.account.id, folders)
        self.store.reset_folder(self.account.id, inbox, selected.uidvalidity, selected.uidnext)
        if reset:
            self.emit(self._event('mail.updated', reset=True))
        # A persisted SELECT baseline does not mean the historical import
        # finished. Retry until the first complete reconciliation is committed.
        baseline = self._sync_state()
        if import_history and baseline.checked_at is None:
            all_uids = self._value(io, await io.all_uids(), epoch, selected.uidvalidity)
            # Freeze the SELECT UIDNEXT baseline; arrivals in this gap are new.
            historical = [uid for uid in all_uids if uid < baseline.sync_next][:100]
            rows = await self._fetch_summaries(historical, epoch, selected.uidvalidity)
            self.store.save_summaries(rows)
        return selected

    async def _run(self, epoch):
        attempts = 0
        try:
            while epoch == self.epoch and not self.stopping:
                try:
                    self.wake.clear()
                    async with self.sync_lock:
                        self.fetch_reconnections = 0
                        if self.reconnect_requested:
                            self.reconnect_requested = False
                            await self._retire_network()
                        if self.io and self.io.closed.is_set():
                            error = self.io.failure
                            await self._retire_network()
                            if error:
                                raise error
                        if self.io is None:
                            await self._open(epoch)
                        await self._reconcile(epoch)
                    # A forced reconnect requested during this round must be
                    # completed before refresh callers receive success.
                    if self.reconnect_requested:
                        continue
                    self._set_state('online')
                    self._complete_round()
                    self.wake.clear()
                    attempts = 0
                    await self._wait_signal(self.interval)
                except MailError as exc:
                    self._check_epoch(epoch)
                    await self._retire_network()
                    if exc.code == 'authentication_failed':
                        self._set_state('auth_failed', exc.code)
                        self._complete_round(exc.code)
                        return
                    self._set_state('offline', 'stop_timeout' if self.retired else exc.code)
                    self._complete_round(self.error)
                    delay = self.retry_delays[min(attempts, len(self.retry_delays)-1)]
                    attempts += 1
                    await self._wait_signal(delay)
        except asyncio.CancelledError:
            raise
        except MailError:
            # Lifecycle fencing: stale work is intentionally abandoned.
            return
        except Exception:
            # Service task boundary never emits the raw exception/cause.
            if epoch != self.epoch or self.stopping:
                return
            await self._retire_network()
            self._set_state('offline', 'service_failed')
            self._complete_round('service_failed')

    async def _wait_signal(self, delay):
        signals = [self.wake.wait()]
        if self.io:
            signals.extend([self.io.reconcile_needed.wait(), self.io.closed.wait()])
        signals.extend(io.closed.wait() for io in self.retired)
        waiters = [asyncio.create_task(signal) for signal in signals]
        try:
            await asyncio.wait(waiters, timeout=delay, return_when=asyncio.FIRST_COMPLETED)
            # Coalesce push floods and enforce a yield even if signals stay set.
            await asyncio.sleep(self.push_interval)
        finally:
            for waiter in waiters:
                waiter.cancel()
            await asyncio.gather(*waiters, return_exceptions=True)

    async def _reconcile(self, epoch):
        io = self.io
        io.reconcile_needed.clear()  # signals arriving during queries survive
        state = self._sync_state()
        validity = state.uidvalidity
        revision = self.unseen_revision
        unseen = set(self._value(io, await io.unseen(), epoch, validity))
        uids = self._value(io, await io.new_uids(state.sync_next), epoch, validity)
        uids = sorted({uid for uid in uids if uid >= state.sync_next})
        rows = await self._fetch_summaries(uids, epoch, validity)
        # FETCH may have used new connections to isolate a poisoned parser row.
        if self.io is None:
            selected = await self._open(epoch, import_history=False)
            if selected.uidvalidity != validity:
                raise MailError('stale_message')
        io = self.io
        cached = self.store.cached_uids(self.account.id, 'INBOX', validity) | set(uids)
        present = set()
        for group in chunks(sorted(cached)):
            present.update(self._value(io, await io.existing_uids(group), epoch, validity))
        deleted = cached - present
        if rows or revision != self.unseen_revision:
            # New arrivals after the first UNSEEN or an interleaved explicit
            # Seen must not be overwritten by the older snapshot.
            unseen = set(self._value(io, await io.unseen(), epoch, validity))
        rows = [row.model_copy(update={'unread': row.key.uid in unseen})
                for row in rows if row.key.uid in present]
        # Even an unread error placeholder needs a durable target. Otherwise
        # exhausting the parser budget could silently skip a later good mail.
        eligible = [row for row in rows if row.unread and row.error != 'message_missing']
        if uids:
            next_uid = max(uids) + 1
            silent = [row for row in rows if row not in eligible]
            self.store.save_summaries(silent)
            if eligible:
                summary = len(eligible) > 3 or any(0 < row.received_at < int(self.clock()) - 600
                                                  for row in eligible)
                batch = ('summary:' if summary else 'individual:') + uuid.uuid4().hex
                self.store.commit_arrivals(eligible, sync_next=next_uid, batch_id=batch, notify_next=next_uid)
            else:
                self.store.advance_sync(self.account.id, 'INBOX', validity, next_uid)
        self.store.delete_messages(self.account.id, 'INBOX', validity, deleted)
        read = self.store.replace_unseen(self.account.id, 'INBOX', validity, unseen - deleted,
                                         checked_at=int(self.clock()))
        self.emit(self._event('mail.updated', read_ids=[key.id for key in read],
                             deleted_ids=[MailKey(account_id=self.account.id, folder_id='INBOX',
                                                  uidvalidity=validity, uid=uid).id for uid in sorted(deleted)]))
        # Persist before emit; only the newly created batch is announced.
        if uids and eligible:
            notification = next((n for n in self._notifications() if n.id == batch), None)
            if notification:
                self.emit(self._event('mail.arrived', notification=notification))

    async def _fetch_summaries(self, uids, epoch, validity):
        rows = []
        for group in chunks(uids):
            rows.extend(await self._fetch_group(group, epoch, validity))
        return rows

    async def _fetch_group(self, uids, epoch, validity):
        # Batch/message operation boundary: split only fatal parser failures,
        # never repeatedly retry auth/network failures as malformed messages.
        try:
            if self.io is None or self.io.closed.is_set():
                if self.fetch_reconnections >= 8:
                    return self._placeholders(uids, validity, 'summary_unavailable')
                self.fetch_reconnections += 1
                await self._retire_network()
                selected = await self._open(epoch, import_history=False)
                if selected.uidvalidity != validity:
                    raise MailError('stale_message')
            io = self.io
            result = self._value(io, await io.summaries(uids), epoch, validity)
            if any(row.key.account_id != self.account.id or row.key.uidvalidity != validity or
                   row.key.folder_id != 'INBOX' or row.key.uid not in uids for row in result):
                raise MailError('stale_message')
            return result
        except MailError as exc:
            self._check_epoch(epoch)
            if exc.code == 'message_missing':
                return []
            if exc.code not in PARSER_ERRORS:
                raise
            await self._retire_network()
            if len(uids) == 1:
                return self._placeholders(uids, validity, exc.code)
            middle = len(uids)//2
            first = await self._fetch_group(uids[:middle], epoch, validity)
            return first + await self._fetch_group(uids[middle:], epoch, validity)

    def _placeholders(self, uids, validity, error):
        return [MailSummary(key=MailKey(account_id=self.account.id, folder_id='INBOX',
                                        uidvalidity=validity, uid=uid), received_at=0,
                            unread=False, error=error) for uid in uids]

    def folders(self):
        self._require_account()
        return self.store.folders(self.account.id)

    def _require_online(self):
        if self.state != 'online' or self.io is None or self.io.closed.is_set():
            raise MailError('offline')
        return self.io

    def _key(self, message_id):
        self._require_account()
        key = MailKey.from_id(message_id)
        if key.account_id != self.account.id:
            raise MailError('stale_message')
        if key.folder_id != 'INBOX':
            raise MailError('unsupported_folder')
        summary = self.store.get_summary(key)
        if summary is None:
            raise MailError('message_missing')
        return key, summary

    async def messages(self, *, folder='INBOX', cursor=None) -> MailPage:
        self._require_account()
        epoch = self.epoch
        if folder != 'INBOX':
            raise MailError('unsupported_folder')
        state = self._sync_state()
        if state is None:
            raise MailError('not_synced')
        before = 4294967296
        if cursor:
            key = MailCursor.from_id(cursor).key
            if (key.account_id, key.folder_id, key.uidvalidity) != (self.account.id, folder, state.uidvalidity):
                raise MailError('stale_cursor')
            before = key.uid
        limit = 50 if cursor else 100
        if self.state != 'online' or self.io is None or self.io.closed.is_set():
            return self.store.page(self.account.id, folder, cursor=cursor, limit=limit)
        async with self.sync_lock:
            self._check_epoch(epoch)
            self._require_account()
            if self._sync_state().uidvalidity != state.uidvalidity:
                raise MailError('stale_cursor')
            self.fetch_reconnections = 0
            return await self._network_page(folder, state, before, limit)

    async def _network_page(self, folder, state, before, limit):
        epoch, io = self.epoch, self.io
        # ALL only for initial/history pages, not every flags reconciliation.
        uids = self._value(io, await io.all_uids(), epoch, state.uidvalidity)
        selected = sorted({uid for uid in uids if uid < before}, reverse=True)
        group = selected[:limit]
        cached = {uid: self.store.get_summary(MailKey(account_id=self.account.id,
                   folder_id=folder, uidvalidity=state.uidvalidity, uid=uid)) for uid in group}
        missing = [uid for uid, row in cached.items() if row is None or row.error == 'summary_unavailable']
        rows = await self._fetch_summaries(missing, epoch, state.uidvalidity)
        self._check_epoch(epoch)
        self.store.save_summaries(rows)  # historical backfill never advances/announces arrivals
        if self.io is None:
            await self._open(epoch, import_history=False)
        self._set_state('online')
        items = [self.store.get_summary(MailKey(account_id=self.account.id, folder_id=folder,
                 uidvalidity=state.uidvalidity, uid=uid)) for uid in group]
        items = [item for item in items if item is not None]
        next_cursor = MailCursor(key=items[-1].key).id if len(selected) > limit and items else None
        return MailPage(items=items, next_cursor=next_cursor)

    async def body(self, message_id):
        key, summary = self._key(message_id)
        epoch = self.epoch
        raw = self.store.get_raw_body(key)
        if raw is not None:
            if self.renderer is None:
                self.renderer = self.factory(ImapConfig(account_id=self.account.id, generation=max(1, self.generation),
                                             username=SecretStr(''), password=SecretStr('')))
            renderer = self.renderer
            result = await renderer.render_cached_body(raw)
            self._check_epoch(epoch)
            self._key(message_id)  # deletion/UIDVALIDITY can change while rendering
            if renderer is not self.renderer or result.identity != renderer.identity:
                raise MailError('stale_request')
            return result.value
        io = self._require_online()
        fetched = self._value(io, await io.body(key, summary.body_part), epoch, key.uidvalidity)
        self._key(message_id)
        self.store.save_body(key, fetched.raw)
        return fetched.body

    async def read(self, message_id) -> list[str]:
        epoch = self.epoch
        async with self.read_lock:
            self._check_epoch(epoch)
            return await self._read(message_id)

    async def _read(self, message_id):
        key, summary = self._key(message_id)
        io = self._require_online()
        if not summary.unread:
            return []
        epoch = self.epoch
        self._value(io, await io.mark_seen(key), epoch, key.uidvalidity)
        self._key(message_id)
        unseen = set(self._value(io, await io.unseen(), epoch, key.uidvalidity))
        self._key(message_id)
        if key.uid in unseen:
            raise MailError('seen_not_persisted')
        # Verify deletion after STORE before returning a delayed success.
        exists = self._value(io, await io.existing_uids([key.uid]), epoch, key.uidvalidity)
        if key.uid not in exists:
            self.store.delete_messages(key.account_id, 'INBOX', key.uidvalidity, {key.uid})
            self.emit(self._event('mail.updated', deleted_ids=[key.id]))
            self._emit_status()
            raise MailError('message_missing')
        changed = self.store.replace_unseen(key.account_id, 'INBOX', key.uidvalidity, unseen,
                                            checked_at=int(self.clock()))
        self.unseen_revision += 1
        ids = [k.id for k in changed]
        self.emit(self._event('mail.updated', read_ids=ids))
        self._emit_status()
        return ids

    async def ack(self, account_id, uidvalidity, batch_id):
        self._require_account(account_id)
        self.store.ack(account_id, 'INBOX', uidvalidity, batch_id)
        self._emit_status()
