"""C3a observable journeys: actual Store, synthetic IMAP, no HTTP wiring."""
import asyncio
import json
import time
import uuid

import pytest
from pydantic import SecretStr

from feishu_lite.mail.service import MailService
from feishu_lite.mail.store import MailStore
from feishu_lite.mail.types import MailCursor, MailError
from tests.mail.fake_imap import FakeMailbox

PASSWORD = SecretStr('synthetic-service-secret')


@pytest.fixture
async def setup(tmp_path):
    store = MailStore(tmp_path / 'mail.db')
    box = FakeMailbox()
    events = []
    service = MailService(store, adapter_factory=box.factory, clock=lambda: box.now,
                          emit=events.append, reconcile_interval=.2, retry_delays=(.02, .04),
                          push_interval=.02)
    await service.start()
    yield service, store, box, events
    await service.stop()
    store.close()


async def configured(setup):
    service, store, box, events = setup
    await service.configure('synthetic@example.invalid', PASSWORD)
    await service.refresh()
    assert service.status().state == 'online'
    return service, store, box, events


async def until(predicate):
    async with asyncio.timeout(2):
        while not predicate():
            await asyncio.sleep(.005)


def arrivals(events):
    return [event for event in events if event.type == 'mail.arrived']


async def test_first_import_is_silent_and_initialization_gap_arrives_once(setup):
    service, store, box, events = setup
    async def arrival(io):
        box.hooks.pop('select')
        box.add(23)
    box.hooks['select'] = arrival
    await configured(setup)
    status = service.status()
    uuid.UUID(status.mail_account_id)
    assert status.unread_count == 3
    assert [s.key.uid for s in (await service.messages()).items] == [23, 22, 9, 3]
    assert len(status.pending) == 1
    assert [s.key.uid for s in status.pending[0].items] == [23]
    assert len(arrivals(events)) == 1
    await service.refresh()
    assert len(arrivals(events)) == 1
    assert store.sync_state(status.mail_account_id, 'INBOX').notify_next == 23


async def test_gap_pages_count_entire_unseen_and_do_not_notify(setup):
    service, store, box, events = setup
    box.uids = {n * 3 for n in range(1, 171)}
    box.unread = box.uids.copy()
    box.uidnext = 511
    await configured(setup)
    first = await service.messages()
    second = await service.messages(cursor=first.next_cursor)
    third = await service.messages(cursor=second.next_cursor)
    assert [len(page.items) for page in (first, second, third)] == [100, 50, 20]
    assert len({s.key.uid for p in (first, second, third) for s in p.items}) == 170
    assert third.next_cursor is None
    assert service.status().unread_count == 170 and not arrivals(events)
    with pytest.raises(MailError, match='unsupported_folder'):
        await service.messages(folder='分类/中文')
    assert len(service.folders()) == 2


async def test_pending_restart_ack_out_of_order_and_password_never_persisted(setup, tmp_path):
    service, store, box, events = await configured(setup)
    box.add(23)
    await service.refresh()
    box.add(24)
    await service.refresh()
    before = service.status()
    await service.ack(before.mail_account_id, 77, before.pending[1].id)
    assert store.sync_state(before.mail_account_id, 'INBOX').notify_next == 23
    await service.stop()
    reopened = MailStore(tmp_path / 'mail.db')
    restored = MailService(reopened, adapter_factory=box.factory, clock=lambda: box.now)
    try:
        await restored.start()
        assert restored.status().state == 'credential_missing'
        assert restored.status().pending[0] == before.pending[0]
        assert restored.status().unread_count == 4
        assert PASSWORD.get_secret_value() not in (tmp_path / 'mail.db').read_bytes().decode('latin1')
        assert PASSWORD.get_secret_value() not in json.dumps([e.model_dump() for e in events])
        await restored.ack(before.mail_account_id, 77, before.pending[0].id)
        await restored.ack(before.mail_account_id, 77, before.pending[0].id)
        assert reopened.sync_state(before.mail_account_id, 'INBOX').notify_next == 25
        await restored.inject_credential(before.mail_account_id, PASSWORD)
        await restored.refresh()
        assert not restored.status().pending
        assert reopened.sync_state(before.mail_account_id, 'INBOX').sync_next == 25
    finally:
        await restored.stop()
        reopened.close()


@pytest.mark.parametrize('uids,age,mode', [((23,24,25),0,'individual'), ((23,24,25,26),0,'summary'),
                                         ((23,),601,'summary'), ((23,),600,'individual')])
async def test_notification_thresholds_use_received_time_and_stable_batches(setup, uids, age, mode):
    service, store, box, events = await configured(setup)
    box.add(*uids, age=age)
    await service.refresh()
    pending = service.status().pending
    assert len(pending) == 1 and pending[0].mode == mode
    await service.refresh(reconnect=True)
    assert service.status().pending == pending
    assert len(arrivals(events)) == 1


async def test_remote_flags_and_deletes_remove_targets_without_old_unread_notifications(setup):
    service, store, box, events = await configured(setup)
    box.add(23, 24)
    await service.refresh()
    keys = {s.key.uid:s.key for s in (await service.messages()).items}
    box.unread.discard(23)
    box.unread.add(22)  # old Seen becomes unread, badge only
    box.uids.remove(24)
    await service.refresh()
    update = [e for e in events if e.type == 'mail.updated'][-1]
    assert keys[23].id in update.read_ids and keys[24].id in update.deleted_ids
    assert service.status().unread_count == 3 and not service.status().pending
    assert len(arrivals(events)) == 1
    assert '\\Flagged' in store.get_summary(keys[23]).flags


async def test_uidvalidity_reset_is_silent_and_invalidates_every_old_target(setup):
    service, store, box, events = await configured(setup)
    box.add(23)
    await service.refresh()
    key = (await service.messages()).items[0].key
    await service.body(key.id)
    cursor = MailCursor(key=key).id
    old_batch = service.status().pending[0]
    box.validity = 78
    await service.refresh(reconnect=True)
    assert service.status().uidvalidity == 78 and not service.status().pending
    assert len(arrivals(events)) == 1
    for operation in (service.body(key.id), service.messages(cursor=cursor),
                      service.ack(key.account_id,77,old_batch.id)):
        with pytest.raises(MailError, match='stale_'):
            await operation


async def test_cached_body_offline_and_read_failure_do_not_forge_seen(setup):
    service, store, box, events = await configured(setup)
    key = next(s.key for s in (await service.messages()).items if s.unread)
    body = await service.body(key.id)
    assert body.content == '<b>synthetic</b>' and service.status().unread_count == 2
    box.errors['seen'] = 'seen_not_persisted'
    with pytest.raises(MailError, match='seen_not_persisted'):
        await service.read(key.id)
    assert store.get_summary(key).unread
    box.errors.pop('seen')
    read_ids = await service.read(key.id)
    assert key.id in read_ids and not store.get_summary(key).unread
    io = next(i for i in box.instances if i.config.password.get_secret_value())
    io.failure = MailError('disconnected')
    io.closed.set()
    box.errors['connect'] = 'disconnected'
    await until(lambda: service.status().state == 'offline')
    assert (await service.body(key.id)).content == body.content
    assert service.status().unread_stale and service.status().last_sync_at == box.now
    with pytest.raises(MailError, match='offline'):
        await service.read(key.id)


async def test_auth_failure_stops_retry_and_wrong_id_rejects_credential(setup):
    service, store, box, events = setup
    box.errors['connect'] = 'authentication_failed'
    await service.configure('synthetic@example.invalid',PASSWORD)
    with pytest.raises(MailError, match='authentication_failed'):
        await service.refresh()
    assert service.status().state == 'auth_failed'
    count = len(box.instances)
    await asyncio.sleep(.12)
    assert len(box.instances) == count
    with pytest.raises(MailError, match='account_mismatch'):
        await service.inject_credential('wrong', PASSWORD)
    box.errors.clear()
    await service.inject_credential(service.status().mail_account_id, SecretStr('replacement'))
    await service.refresh()
    assert service.status().state == 'online'


async def test_refresh_coalesces_and_periodic_push_closed_reconnect_are_independent(setup):
    service, store, box, events = await configured(setup)
    entered, release = asyncio.Event(), asyncio.Event()
    async def blocked(io):
        entered.set()
        await release.wait()
    box.hooks['unseen'] = blocked
    requests = [asyncio.create_task(service.refresh()) for _ in range(12)]
    await entered.wait()
    box.add(23)
    release.set()
    await asyncio.gather(*requests)
    box.hooks.clear()
    assert len(arrivals(events)) == 1
    box.add(24)
    io = next(i for i in box.instances if i.config.password.get_secret_value())
    io.reconcile_needed.set()
    await until(lambda: service.status().unread_count == 4)
    box.unread.discard(3)
    await until(lambda: service.status().unread_count == 3)
    generation = service.status().generation
    io.failure = MailError('disconnected')
    io.closed.set()
    await until(lambda: service.status().generation > generation and service.status().state == 'online')


async def test_no_idle_periodic_check_finds_new_mail(setup):
    service, store, box, events = setup
    box.idle = False
    await configured(setup)
    box.add(23)
    await until(lambda: bool(service.status().pending))


async def test_change_remove_and_late_body_never_revive_account(setup, tmp_path):
    service, store, box, events = await configured(setup)
    (tmp_path/'cache.db').write_bytes(b'chat sentinel')
    old = service.status().mail_account_id
    key = (await service.messages()).items[0].key
    entered, release = asyncio.Event(), asyncio.Event()
    async def blocked(io):
        entered.set()
        await release.wait()
    box.hooks['body'] = blocked
    request = asyncio.create_task(service.body(key.id))
    await entered.wait()
    changed = await service.configure('other@example.invalid',PASSWORD)
    release.set()
    with pytest.raises(MailError, match='stale_'):
        await request
    assert changed.removed_account_id == old and store.account(old) is None
    await service.refresh()
    assert service.status().mail_account_id != old
    removed = await service.remove_account()
    assert removed.removed_account_id == changed.account.id
    assert service.status().state == 'unconfigured' and service.status().unread_count == 0
    assert (tmp_path/'cache.db').read_bytes() == b'chat sentinel'


async def test_test_connection_does_not_persist_and_always_stops(setup):
    service, store, box, events = setup
    await service.test_connection('probe@example.invalid',PASSWORD)
    assert service.status().state == 'unconfigured'
    assert store.accounts() == [] and box.instances[-1].stops == 1
    box.errors['connect'] = 'authentication_failed'
    with pytest.raises(MailError, match='authentication_failed'):
        await service.test_connection('probe@example.invalid',PASSWORD)
    assert box.instances[-1].stops == 1 and store.accounts() == []


async def test_dns_stop_timeout_blocks_replacement_until_owner_is_closed(setup):
    service, store, box, events = await configured(setup)
    old_io = next(i for i in box.instances if i.config.password.get_secret_value())
    box.errors['stop'] = 'stop_timeout'
    await service.refresh(reconnect=True, wait=False)
    await until(lambda: service.status().error == 'stop_timeout')
    count = len(box.instances)
    await asyncio.sleep(.15)
    assert len(box.instances) == count
    box.errors.clear()
    old_io.thread_alive = False
    old_io.closed.set()
    await service.refresh()
    assert service.status().state == 'online'


async def test_parser_poison_is_isolated_with_bounded_reconnections_and_good_uids_progress(setup):
    service, store, box, events = await configured(setup)
    box.bad = {24}
    box.add(23,24,25)
    await service.refresh()
    page = await service.messages()
    assert [s.key.uid for s in page.items][:3] == [25,24,23]
    assert next(s for s in page.items if s.key.uid == 24).error == 'malformed_response'
    assert store.sync_state(service.status().mail_account_id,'INBOX').sync_next == 26
    count = len(box.instances)
    await service.refresh()
    assert len(box.instances) == count and len(arrivals(events)) == 1


async def test_stop_releases_render_and_network_resources_without_default_executor(setup):
    service, store, box, events = await configured(setup)
    await service.body((await service.messages()).items[0].key.id)
    await service.body((await service.messages()).items[0].key.id)
    began = time.monotonic()
    await service.stop()
    assert time.monotonic()-began < 2
    assert all(not io.thread_alive for io in box.instances)
    assert asyncio.get_running_loop()._default_executor is None


async def test_arrival_after_unseen_snapshot_is_not_marked_read_or_lost(setup):
    service, store, box, events = await configured(setup)
    async def arrival(io):
        box.hooks.pop('new')
        box.add(23)
    box.hooks['new'] = arrival
    await service.refresh()
    assert service.status().unread_count == 3
    assert [row.key.uid for row in service.status().pending[0].items] == [23]
    assert len(arrivals(events)) == 1


async def test_poison_last_uid_still_completes_round_without_requesting_manual_retry(setup):
    service, store, box, events = await configured(setup)
    box.bad = {25}
    box.add(23,24,25)
    await service.refresh()
    assert service.status().state == 'online' and service.status().unread_count == 5
    assert [s.key.uid for s in service.status().pending[0].items] == [23,24,25]


async def test_explicit_seen_late_account_change_and_delete_are_not_success(setup):
    service, store, box, events = await configured(setup)
    key = next(s.key for s in (await service.messages()).items if s.unread)
    entered, release = asyncio.Event(), asyncio.Event()
    async def blocked(io):
        entered.set()
        await release.wait()
    box.hooks['seen'] = blocked
    request = asyncio.create_task(service.read(key.id))
    await entered.wait()
    await service.remove_account()
    release.set()
    with pytest.raises(MailError, match='stale_'):
        await request
    box.hooks.clear()
    await service.configure('synthetic@example.invalid',PASSWORD)
    await service.refresh()
    key = next(s.key for s in (await service.messages()).items if s.unread)
    async def deleted(io):
        box.uids.discard(key.uid)
    box.hooks['seen'] = deleted
    with pytest.raises(MailError, match='message_missing'):
        await service.read(key.id)
    assert store.get_summary(key) is None


async def test_stale_identity_and_uidvalidity_body_results_are_rejected(setup):
    service, store, box, events = await configured(setup)
    key = (await service.messages()).items[0].key
    io = service.io
    original = io.body
    async def wrong_identity(key, part):
        result = await original(key,part)
        return result.model_copy(update={'identity':result.identity.model_copy(update={'connection_id':'wrong'})})
    io.body = wrong_identity
    with pytest.raises(MailError, match='stale_request'):
        await service.body(key.id)
    assert store.get_raw_body(key) is None


async def test_credential_injection_is_idempotent_and_offline_pages_preserve_cache(setup):
    service, store, box, events = await configured(setup)
    state = store.sync_state(service.account.id,'INBOX')
    count = len(box.instances)
    await service.inject_credential(service.account.id,PASSWORD)
    assert len(box.instances) == count
    io = service.io
    io.failure = MailError('disconnected')
    io.closed.set()
    box.errors['connect'] = 'disconnected'
    await until(lambda: service.status().state == 'offline')
    assert len((await service.messages()).items) == 3
    assert store.sync_state(service.account.id,'INBOX').sync_next == state.sync_next


async def test_first_service_empty_inbox_then_arrival(setup):
    service, store, box, events = setup
    box.uids = box.unread = set()
    box.uidnext = 1
    await configured(setup)
    assert (await service.messages()).items == []
    box.add(1)
    await service.refresh()
    assert service.status().unread_count == 1 and len(arrivals(events)) == 1


async def test_same_rejected_credential_does_not_restart_auth_attempts(setup):
    service, store, box, events = setup
    box.errors['connect'] = 'authentication_failed'
    await service.configure('synthetic@example.invalid',PASSWORD)
    with pytest.raises(MailError):
        await service.refresh()
    count = len(box.instances)
    await service.inject_credential(service.account.id,PASSWORD)
    await asyncio.sleep(.06)
    assert service.status().state == 'auth_failed' and len(box.instances) == count


async def test_stop_interrupts_a_connection_test_instead_of_waiting_for_lifecycle_lock(setup):
    service, store, box, events = setup
    entered, release = asyncio.Event(), asyncio.Event()
    async def stalled(io):
        entered.set()
        await release.wait()
        if io.closed.is_set():
            raise MailError('executor_stopped')
    box.hooks['connect'] = stalled
    probe = asyncio.create_task(service.test_connection('probe@example.invalid',PASSWORD))
    await entered.wait()
    try:
        async with asyncio.timeout(.1):
            await service.stop()
    finally:
        release.set()
        await asyncio.gather(probe, return_exceptions=True)
    assert not box.instances[-1].thread_alive


async def test_seen_during_reconciliation_is_not_rolled_back_by_old_unseen(setup):
    service, store, box, events = await configured(setup)
    key = next(s.key for s in (await service.messages()).items if s.unread)
    entered, release = asyncio.Event(), asyncio.Event()
    async def blocked(io):
        box.hooks.pop('new')
        entered.set()
        await release.wait()
    box.hooks['new'] = blocked
    request = asyncio.create_task(service.refresh())
    await entered.wait()
    assert key.id in await service.read(key.id)
    release.set()
    await request
    assert not store.get_summary(key).unread and service.status().unread_count == 1


async def test_cancelled_refresh_caller_does_not_cancel_other_callers_sync(setup):
    service, store, box, events = await configured(setup)
    entered, release = asyncio.Event(), asyncio.Event()
    async def blocked(io):
        entered.set()
        await release.wait()
    box.hooks['new'] = blocked
    first = asyncio.create_task(service.refresh())
    await entered.wait()
    second = asyncio.create_task(service.refresh())
    first.cancel()
    await asyncio.gather(first, return_exceptions=True)
    release.set()
    await second
    assert service.status().state == 'online'


async def test_stop_during_retirement_keeps_owner_cleanup_tracked(setup):
    service, store, box, events = await configured(setup)
    entered, release = asyncio.Event(), asyncio.Event()
    async def stopping(io):
        entered.set()
        await release.wait()
    box.hooks['stop'] = stopping
    await service.refresh(reconnect=True,wait=False)
    await entered.wait()
    stop = asyncio.create_task(service.stop())
    await asyncio.sleep(.02)
    stopped_early = stop.done()
    release.set()
    await stop
    assert not stopped_early
    assert all(not io.thread_alive for io in box.instances)


async def test_large_arrival_and_existence_batches_are_bounded_and_ack_summary_stable(setup):
    service, store, box, events = await configured(setup)
    box.add(*range(23,183))
    await service.refresh()
    assert service.status().unread_count == 162
    pending = service.status().pending[0]
    assert pending.mode == 'summary' and len(pending.items) == 160
    assert all(len(args) <= 100 for name,args in box.calls if name in ('summaries','existing'))
    box.unread.discard(23)
    await service.refresh()
    updated = service.status().pending[0]
    assert updated.id == pending.id and updated.mode == 'summary' and len(updated.items) == 159
    await service.ack(service.account.id,77,pending.id)
    await service.refresh(reconnect=True)
    assert not service.status().pending and len(arrivals(events)) == 1


async def test_late_initial_sync_after_remove_cannot_recreate_account(setup):
    service, store, box, events = setup
    entered = asyncio.Event()
    async def stall(io):
        entered.set()
        await asyncio.Event().wait()
    box.hooks['select'] = stall
    await service.configure('synthetic@example.invalid',PASSWORD)
    await entered.wait()
    old = service.account.id
    await service.remove_account()
    assert store.accounts() == [] and store.account(old) is None
    assert service.status().state == 'unconfigured'


async def test_interrupted_initial_import_retries_historical_page_before_online(setup):
    service, store, box, events = setup
    box.errors['summaries'] = 'disconnected'
    await service.configure('synthetic@example.invalid',PASSWORD)
    with pytest.raises(MailError, match='disconnected'):
        await service.refresh()
    account_id = service.account.id
    assert store.sync_state(account_id,'INBOX').checked_at is None
    box.errors.clear()
    await service.refresh()
    assert len(store.page(account_id,'INBOX').items) == 3
    assert not arrivals(events)


async def test_read_deleted_during_store_emits_notification_cleanup_target(setup):
    service, store, box, events = await configured(setup)
    box.add(23)
    await service.refresh()
    key = service.status().pending[0].items[0].key
    async def deleted(io):
        box.uids.discard(23)
    box.hooks['seen'] = deleted
    with pytest.raises(MailError, match='message_missing'):
        await service.read(key.id)
    assert not service.status().pending
    assert key.id in [e for e in events if e.type == 'mail.updated'][-1].deleted_ids


async def test_push_flood_is_coalesced_with_sleep_between_rounds(setup):
    service, store, box, events = await configured(setup)
    io = service.io
    async def push(io):
        io.reconcile_needed.set()
    box.hooks['unseen'] = push
    before = sum(name == 'unseen' for name,args in box.calls)
    io.reconcile_needed.set()
    await asyncio.sleep(.09)
    after = sum(name == 'unseen' for name,args in box.calls)
    assert 1 <= after-before <= 6


async def test_network_miss_body_error_does_not_block_other_messages(setup):
    service, store, box, events = await configured(setup)
    ids = [s.key.id for s in (await service.messages()).items]
    box.errors['body'] = 'malformed_encoding'
    with pytest.raises(MailError, match='malformed_encoding'):
        await service.body(ids[0])
    assert service.status().state == 'online'
    box.errors.clear()
    assert (await service.body(ids[1])).content == '<b>synthetic</b>'


async def test_concurrent_explicit_reads_never_restore_another_messages_unread(setup):
    service, store, box, events = await configured(setup)
    keys = [s.key for s in (await service.messages()).items if s.unread]
    entered, release = asyncio.Event(), asyncio.Event()
    async def blocked(io):
        box.hooks.pop('existing')
        entered.set()
        await release.wait()
    box.hooks['existing'] = blocked
    first = asyncio.create_task(service.read(keys[0].id))
    await entered.wait()
    second = asyncio.create_task(service.read(keys[1].id))
    await asyncio.sleep(.01)
    release.set()
    await asyncio.gather(first,second)
    assert service.status().unread_count == 0
    assert all(not store.get_summary(key).unread for key in keys)


async def test_new_seen_summary_becoming_unread_before_final_snapshot_is_pending(setup):
    service, store, box, events = await configured(setup)
    box.add(23)
    box.unread.discard(23)
    async def make_unread(io):
        box.hooks.pop('existing')
        box.unread.add(23)
    box.hooks['existing'] = make_unread
    await service.refresh()
    assert service.status().unread_count == 3
    assert service.status().pending[0].items[0].key.uid == 23


async def test_parser_recovery_budget_does_not_poison_unattempted_good_summaries(setup):
    service, store, box, events = await configured(setup)
    box.add(*range(23,123))
    box.bad = set(range(23,122))
    before = len(box.instances)
    await service.refresh()
    assert len(box.instances)-before <= 9
    assert service.status().state == 'online'
    assert len(service.status().pending[0].items) == 100
    box.bad.clear()
    page = await service.messages()
    assert next(row for row in page.items if row.key.uid == 122).error is None
