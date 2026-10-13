import asyncio
import time

import pytest
from pydantic import SecretStr

from feishu_lite.mail.imap import ImapAdapter
from feishu_lite.mail.types import ImapConfig, MailError, MailKey
from tests.mail.imap_server import imap_server


def adapter(server, **kwargs):
    return ImapAdapter(ImapConfig(account_id='synthetic-account', generation=1,
                                 host='127.0.0.1', port=server.port,
                                 username=SecretStr('user@example.invalid'),
                                 password=SecretStr('synthetic-password')),
                       _plaintext_loopback=True, **kwargs)


async def ready(client, readonly=False):
    await client.connect()
    return await client.select_inbox(readonly=readonly)


def key(uid=9):
    return MailKey(account_id='synthetic-account', folder_id='INBOX', uidvalidity=77, uid=uid)


async def test_catalog_selection_search_and_sparse_uid_pages(tmp_path):
    async with imap_server(idle=False) as server:
        client = adapter(server)
        try:
            await client.connect()
            folders = (await client.list_folders()).value
            assert [f.id for f in folders] == ['INBOX', '目录', '目录/归档']
            assert folders[0].name == 'inbox'
            assert folders[0].supported and not folders[1].selectable
            assert folders[2].delimiter == '/' and not folders[2].supported
            selected = (await client.select_inbox()).value
            assert selected.uidvalidity == 77 and selected.uidnext == 23
            assert not selected.readonly and '\\Seen' in selected.permanent_flags
            assert (await client.unseen()).value == [3, 9]
            assert (await client.all_uids()).value == [22, 9, 3]
            assert (await client.new_uids(30)).value == []
            assert (await client.existing_uids([3, 8, 22])).value == [3, 22]
            assert (await client.uid_page(limit=2)).value == [22, 9]
            assert (await client.uid_page(before_uid=9, limit=2)).value == [3]
            from feishu_lite.mail.store import MailStore
            store = MailStore(tmp_path / 'mail.db')
            try:
                store.save_account(client.identity.account_id, 'user@example.invalid')
                store.save_folders(client.identity.account_id, folders)
                store.reset_folder(client.identity.account_id, folders[0], selected.uidvalidity, selected.uidnext)
                store.save_summaries((await client.summaries([9])).value)
                assert store.page(client.identity.account_id, 'INBOX').items[0].key == key()
            finally:
                store.close()
            with pytest.raises(MailError, match='unsupported_folder'):
                await client.all_uids(folder='目录/归档')
            assert not any(b'STATUS' in c for c in server.commands)
        finally:
            await client.stop()
        await asyncio.sleep(.02)  # let the peer observe TCP EOF
        assert not client.thread_alive and not server.writers


async def test_daemon_owner_does_not_create_default_thread_pool():
    async with imap_server(idle=False) as server:
        loop = asyncio.get_running_loop()
        before = loop._default_executor
        client = adapter(server)
        try:
            await ready(client)
            await client.unseen()
            assert client.thread.daemon
            assert loop._default_executor is before
        finally:
            await client.stop()


async def test_summary_body_peek_and_explicit_seen_preserves_flags():
    async with imap_server(idle=False) as server:
        client = adapter(server)
        try:
            await ready(client)
            summaries = (await client.summaries([3, 9])).value
            assert summaries[0].subject == 'Synthetic'
            assert summaries[0].received_at == 1791853200
            assert summaries[0].body_part.section == '2'
            assert summaries[0].attachments[0].filename == 'sample.pdf'
            fetched = (await client.body(key(3), summaries[0].body_part)).value
            assert fetched.raw.source == '<b>hello</b>'
            assert fetched.body.content == '<b>hello</b>'
            assert server.flags[3] == {b'\\Flagged'}
            await client.mark_seen(key(3))
            assert server.flags[3] == {b'\\Seen', b'\\Flagged'}
            fetches = [c for c in server.commands if b'UID FETCH' in c]
            assert any(b'BODY.PEEK[2]' in fetch for fetch in fetches)
            assert all(b'RFC822)' not in c and b'BODY.PEEK[3]' not in c for c in fetches)
            assert any(b'+FLAGS.SILENT (\\Seen)' in c for c in server.commands)
            with pytest.raises(MailError, match='stale_message'):
                await client.body(key().model_copy(update={'account_id': 'old-account'}), summaries[0].body_part)
        finally:
            await client.stop()


@pytest.mark.parametrize('scenario', ['normal', 'push', 'flood', 'idle_half_line'])
async def test_idle_request_starts_fetch_within_two_seconds_after_tagged_done(scenario, record_property):
    async with imap_server(scenario) as server:
        client = adapter(server)
        try:
            await ready(client)
            server.events['idle'].clear()
            part = (await client.summaries([9])).value[0].body_part
            await asyncio.wait_for(server.events['idle'].wait(), 2)
            start = time.monotonic()
            result = await client.body(key(), part)
            elapsed = server.fetch_at - start
            record_property('enqueue_to_wire_fetch_seconds', elapsed)
            print(f'TIMING idle_to_fetch {scenario} {elapsed:.6f}')
            assert elapsed < 2 and result.value.body.content == '<b>hello</b>'
            assert server.serialized
            if scenario in ('push', 'flood'):
                assert client.reconcile_needed.is_set()
        finally:
            await client.stop()


@pytest.mark.parametrize('scenario', ['done_stall', 'idle_partial_stall'])
async def test_done_without_confirmation_is_bounded_and_never_sends_fetch(scenario):
    async with imap_server(scenario) as server:
        client = adapter(server)
        try:
            await ready(client)
            await server.events['idle'].wait()
            start = time.monotonic()
            with pytest.raises(MailError, match='idle_done_timeout'):
                await client.summaries([9])
            assert time.monotonic() - start < 2
            assert server.fetch_at is None and server.serialized
        finally:
            await client.stop()


@pytest.mark.parametrize('scenario', ['fetch_stall', 'half_line', 'disconnect', 'fetch_empty'])
async def test_missing_broken_or_slow_fetch_is_safe_and_event_loop_keeps_running(scenario):
    async with imap_server(scenario, idle=False) as server:
        client = adapter(server, command_timeout=.3)
        try:
            await ready(client)
            ticks = 0
            async def pulse():
                nonlocal ticks
                for _ in range(10):
                    ticks += 1
                    await asyncio.sleep(.02)
            task = asyncio.create_task(pulse())
            with pytest.raises(MailError) as caught:
                await client.summaries([9])
            assert caught.value.code in ('command_timeout', 'disconnected', 'message_missing')
            await task
            assert ticks == 10 and 'FETCH' not in str(caught.value)
        finally:
            await client.stop()


@pytest.mark.parametrize('scenario,code', [('header_oversize', 'headers_too_large'), ('body_oversize', 'body_too_large'), ('deep_structure', 'mime_too_deep')])
async def test_network_limits_reject_declared_literal_and_structure_before_library_parse(scenario, code):
    async with imap_server(scenario, idle=False) as server:
        client = adapter(server)
        try:
            await ready(client)
            with pytest.raises(MailError, match=code):
                if scenario == 'body_oversize':
                    from feishu_lite.mail.types import BodyPart
                    await client.body(key(), BodyPart(section='2', media_type='text/html'))
                else:
                    await client.summaries([9])
            assert client.transport_stats.literal_bytes == 0
        finally:
            await client.stop()


async def test_bad_single_message_does_not_poison_next_request():
    async with imap_server('bad_structure', idle=False) as server:
        client = adapter(server)
        try:
            await ready(client)
            result = (await client.summaries([9, 3])).value
            assert result[0].error == 'malformed_mime' and result[1].error is None
            assert (await client.unseen()).value == [3, 9]
        finally:
            await client.stop()


@pytest.mark.parametrize('scenario,code', [('missing_header', 'malformed_response'), ('missing_one', 'message_missing')])
async def test_incomplete_single_record_does_not_discard_other_messages(scenario, code):
    async with imap_server(scenario, idle=False) as server:
        client = adapter(server)
        try:
            await ready(client)
            result = (await client.summaries([9, 3])).value
            assert result[0].error == code and result[1].error is None
            assert (await client.unseen()).value == [3, 9]
        finally:
            await client.stop()


async def test_bad_internaldate_is_a_single_message_error():
    async with imap_server('bad_date', idle=False) as server:
        client = adapter(server)
        try:
            await ready(client)
            result = (await client.summaries([9, 3])).value
            assert result[0].error == 'malformed_response' and result[1].error is None
            assert (await client.unseen()).value == [3, 9]
        finally:
            await client.stop()


@pytest.mark.parametrize('scenario,code', [('wire_oversize', 'response_too_large'), ('too_many_atoms', 'too_many_parts')])
async def test_raw_line_and_atom_budgets_are_enforced(scenario, code):
    from feishu_lite.mail.types import MailLimits
    async with imap_server(scenario, idle=False) as server:
        client = adapter(server, limits=MailLimits(max_response_bytes=2048, max_parts=2))
        try:
            await ready(client)
            with pytest.raises(MailError, match=code):
                await client.summaries([9])
        finally:
            await client.stop()


async def test_cached_body_render_uses_owner_thread_and_can_run_without_connection(monkeypatch):
    import threading
    import feishu_lite.mail.imap as module
    from feishu_lite.mail.types import RawBody
    thread_ids = []
    original = module.render_body
    def inspect_render(raw):
        thread_ids.append(threading.get_ident())
        return original(raw)
    monkeypatch.setattr(module, 'render_body', inspect_render)
    async with imap_server(idle=False) as server:
        client = adapter(server)
        try:
            result = await client.render_cached_body(RawBody(kind='html', source='<script>x</script><b>safe</b>'))
            assert result.value.content == '<b>safe</b>'
            assert thread_ids == [client.thread.ident] and thread_ids[0] != threading.get_ident()
            assert server.commands == []
        finally:
            await client.stop()


async def test_cancel_active_request_and_stop_old_generation_never_deliver_into_replacement():
    async with imap_server('search_delay', idle=False) as server:
        old = adapter(server)
        await ready(old)
        cancelled = asyncio.create_task(old.unseen())
        await server.events['search'].wait()
        cancelled.cancel()
        await asyncio.gather(cancelled, return_exceptions=True)
        await asyncio.sleep(.2)
        assert old.pending_count == 0
        await old.stop()
        replacement = ImapAdapter(old.config.model_copy(update={'generation': 2}), _plaintext_loopback=True)
        try:
            result = await ready(replacement)
            assert result.identity.generation == 2
            assert result.identity.connection_id != old.identity.connection_id
            with pytest.raises(MailError, match='executor_stopped'):
                await old.unseen()
        finally:
            await replacement.stop()


async def test_idle_renews_on_deadline_and_logs_out_cleanly_on_stop():
    async with imap_server() as server:
        client = adapter(server, idle_renew=.1)
        try:
            await ready(client)
            await server.events['idle'].wait()
            await asyncio.sleep(.3)
            assert sum(b' IDLE' in c for c in server.commands) >= 2
        finally:
            await client.stop()
        assert server.serialized
        assert server.events['logout'].is_set()


async def test_idle_disconnect_is_observable_without_an_outstanding_request():
    async with imap_server('idle_disconnect') as server:
        client = adapter(server)
        try:
            await ready(client)
            await asyncio.wait_for(client.closed.wait(), 1)
            assert client.failure.code == 'disconnected'
            assert client.pending_count == 0
        finally:
            await client.stop()


@pytest.mark.parametrize('readonly,scenario,code', [(True, 'normal', 'mailbox_readonly'), (False, 'store_failed', 'command_rejected')])
async def test_seen_failure_never_reports_success(readonly, scenario, code):
    async with imap_server(scenario, idle=False) as server:
        client = adapter(server)
        try:
            await ready(client, readonly=readonly)
            with pytest.raises(MailError, match=code):
                await client.mark_seen(key())
            assert b'\\Seen' not in server.flags[9]
        finally:
            await client.stop()


@pytest.mark.parametrize('scenario,code', [('store_noop', 'seen_not_persisted'), ('store_disappeared', 'message_missing')])
async def test_seen_tagged_ok_does_not_fake_success_when_uid_disappears_or_server_ignores_flag(scenario, code):
    async with imap_server(scenario, idle=False) as server:
        client = adapter(server)
        try:
            await ready(client)
            with pytest.raises(MailError, match=code):
                await client.mark_seen(key())
        finally:
            await client.stop()


async def test_select_returned_readonly_blocks_store_even_when_write_was_requested():
    async with imap_server(readonly=True, idle=False) as server:
        client = adapter(server)
        try:
            selected = (await ready(client)).value
            assert selected.readonly
            with pytest.raises(MailError, match='mailbox_readonly'):
                await client.mark_seen(key())
            assert not any(b' STORE ' in c for c in server.commands)
        finally:
            await client.stop()


async def test_summary_seen_flag_is_case_insensitive():
    async with imap_server(idle=False) as server:
        server.flags[9] = {b'\\sEEN'}
        client = adapter(server)
        try:
            await ready(client)
            assert not (await client.summaries([9])).value[0].unread
        finally:
            await client.stop()


async def test_auth_failure_is_mail_specific_and_redacted(caplog):
    async with imap_server('auth_failed') as server:
        client = adapter(server)
        caplog.set_level('DEBUG')
        try:
            with pytest.raises(MailError, match='authentication_failed') as caught:
                await client.connect()
            from feishu_lite.mail.types import MailAuthenticationError
            assert isinstance(caught.value, MailAuthenticationError)
            assert caught.value.__cause__ is None
            assert 'synthetic-password' not in caplog.text
            assert 'user@example.invalid' not in caplog.text
            assert 'secret-like' not in caplog.text
            assert 'synthetic-password' not in repr(client.config)
        finally:
            await client.stop()


async def test_successful_auth_and_message_operations_do_not_log_wire_or_identity(caplog):
    async with imap_server(idle=False) as server:
        client = adapter(server)
        caplog.set_level('DEBUG')
        try:
            await ready(client)
            await client.summaries([9])
            await client.mark_seen(key(3))
            assert 'user@example.invalid' not in caplog.text
            assert 'synthetic-password' not in caplog.text
            assert 'Synthetic' not in caplog.text
            assert client.client._imap._cmd_log == {}
        finally:
            await client.stop()


@pytest.mark.parametrize('user_operation', ['seen', 'body'])
async def test_priority_bounded_queue_and_cancelled_requests_never_reach_wire(user_operation):
    async with imap_server('search_delay', idle=False) as server:
        client = adapter(server, queue_size=3)
        try:
            await ready(client)
            part = (await client.summaries([3])).value[0].body_part
            baseline = len(server.commands)
            active = asyncio.create_task(client.unseen())
            await server.events['search'].wait()
            low = asyncio.create_task(client.summaries([9]))
            cancelled = asyncio.create_task(client.summaries([22]))
            high = asyncio.create_task(client.mark_seen(key(3)) if user_operation == 'seen' else client.body(key(3), part))
            await asyncio.sleep(.01)
            with pytest.raises(MailError, match='queue_full'):
                await client.all_uids()
            cancelled.cancel()
            await asyncio.gather(cancelled, return_exceptions=True)
            await asyncio.gather(active, low, high)
            cmds = [c for c in server.commands[baseline:] if b'UID' in c]
            if user_operation == 'seen':
                assert b'SEARCH UID 3' in cmds[1] and b'STORE' in cmds[2] and b'FETCH 9' in cmds[4]
            else:
                assert b'FETCH 3 (BODY.PEEK[2])' in cmds[1] and b'FETCH 9' in cmds[2]
            assert not any(b'FETCH 22' in c for c in cmds)
        finally:
            await client.stop()


@pytest.mark.parametrize('phase', ['idle', 'done_stall', 'fetch_stall', 'half_line', 'greeting_stall'])
async def test_stop_aborts_blocked_owner_and_all_pending_futures(phase, record_property):
    async with imap_server('normal' if phase == 'idle' else phase) as server:
        client = adapter(server)
        if phase == 'greeting_stall':
            pending = asyncio.create_task(client.connect())
            await server.events['connected'].wait()
        else:
            await ready(client)
            await server.events['idle'].wait()
            pending = asyncio.create_task(client.summaries([9])) if phase != 'idle' else None
            if pending:
                await server.events['done' if phase == 'done_stall' else 'fetch'].wait()
        start = time.monotonic()
        await client.stop()
        elapsed = time.monotonic() - start
        print(f'TIMING stop_owner {phase} {elapsed:.6f}')
        record_property('stop_to_thread_closed_seconds', elapsed)
        assert elapsed < 2 and not client.thread_alive
        assert client.pending_count == 0
        await asyncio.wait_for(client.closed.wait(), 1)
        assert client.failure is None
        if pending:
            with pytest.raises(MailError, match='executor_stopped'):
                await pending
        with pytest.raises(MailError, match='executor_stopped'):
            await client.unseen()
