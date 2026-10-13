"""C1 behaviors; all identities, headers and payloads are synthetic."""
import base64
import json
import sqlite3
from concurrent.futures import ThreadPoolExecutor

import pytest
from feishu_lite.mail.types import MailKey, MailCursor, MailSummary, RawBody, MailError, MailFolder
from feishu_lite.mail.store import MailStore


def key(uid=1, account='a', folder='INBOX', validity=10):
    return MailKey(account_id=account, folder_id=folder, uidvalidity=validity, uid=uid)


def summary(uid=1, **kwargs):
    return MailSummary(key=key(uid, **kwargs), subject=f'synthetic {uid}', received_at=1000)


@pytest.fixture
def store(tmp_path):
    result = MailStore(tmp_path / 'mail.db')
    result.save_account('a', 'a@example.invalid')
    result.save_account('b', 'b@example.invalid')
    result.reset_folder('a', MailFolder(id='INBOX', name='收件箱', supported=True), 10, 1)
    result.reset_folder('b', MailFolder(id='INBOX', name='收件箱', supported=True), 10, 1)
    yield result
    result.close()


def test_stable_ids_escape_folder_paths_and_keep_all_identity_components():
    original = key(42, folder='分类/中文')
    assert '/' not in original.id and '=' not in original.id
    assert MailKey.from_id(original.id) == original
    assert key(42, account='b').id != key(42).id
    assert key(42, validity=11).id != key(42).id
    cursor = MailCursor(key=original)
    assert MailCursor.from_id(cursor.id) == cursor
    with pytest.raises(MailError, match='invalid_id'):
        MailKey.from_id(cursor.id)


@pytest.mark.parametrize('bad', ['', '/', 'abcd=', 'A' * 4097, 'e30', '%%%%'])
def test_invalid_ids_are_rejected_without_echoing_input(bad):
    with pytest.raises(MailError, match='invalid_id') as exc:
        MailKey.from_id(bad)
    assert str(exc.value) == 'invalid_id'


@pytest.mark.parametrize('data', [[1,'message','a','INBOX',True,1], [1,'message','a','INBOX',10,0], [1,'message','a','INBOX',10,'1'], [2,'message','a','INBOX',10,1], [1,'message','','INBOX',10,1]])
def test_id_payload_validation(data):
    encoded = base64.urlsafe_b64encode(json.dumps(data).encode()).decode().rstrip('=')
    with pytest.raises(MailError):
        MailKey.from_id(encoded)


def test_summary_only_pages_are_descending_gap_safe_and_default_100_50(store):
    uids = [n * 3 for n in range(1, 161)]
    store.save_summaries([summary(uid) for uid in uids])
    page = store.page('a', 'INBOX')
    assert [s.key.uid for s in page.items] == list(reversed(uids))[:100]
    next_page = store.page('a', 'INBOX', cursor=page.next_cursor)
    last = store.page('a', 'INBOX', cursor=next_page.next_cursor)
    assert len(next_page.items) == 50 and len(last.items) == 10 and last.next_cursor is None
    assert [s.key.uid for s in page.items + next_page.items + last.items] == list(reversed(uids))
    assert store.get_body(key()) is None


def test_account_and_cursor_isolation(store):
    store.save_summaries([summary(1), summary(1, account='b')])
    cursor = MailCursor(key=key(2)).id
    with pytest.raises(MailError, match='stale_cursor'):
        store.page('b', 'INBOX', cursor=cursor)
    assert len(store.page('b','INBOX').items) == 1


def test_uidvalidity_rebuild_invalidates_body_cursor_and_notifications(store):
    store.commit_arrivals([summary(1)], sync_next=2, batch_id='batch', notify_next=2)
    store.save_body(key(), RawBody(kind='html', source='<b>old</b>'))
    cursor = MailCursor(key=key(2)).id
    store.reset_folder('a', MailFolder(id='INBOX', name='收件箱'), 11, 5)
    assert store.page('a','INBOX').items == []
    assert store.pending('a','INBOX') == []
    with pytest.raises(MailError, match='stale_message'):
        store.get_body(key())
    with pytest.raises(MailError, match='stale_cursor'):
        store.page('a','INBOX',cursor=cursor)
    with pytest.raises(MailError, match='stale_message'):
        store.save_summaries([summary(2)])


def test_unread_snapshot_counts_whole_inbox_and_updates_cached_flags(store):
    store.save_summaries([summary(1), summary(3)])
    store.replace_unseen('a','INBOX',10,{3,5,7,9}, checked_at=123)
    state = store.sync_state('a','INBOX')
    assert state.unread_count == 4 and state.checked_at == 123
    items = store.page('a','INBOX').items
    assert items[0].unread and not items[1].unread
    assert store.sync_state('b','INBOX').unread_count == 0
    store.replace_unseen('a','INBOX',10,set(),checked_at=124)
    assert store.sync_state('a','INBOX').unread_count == 0


def test_pending_ack_survives_restart_and_out_of_order_ack_never_skips(store, tmp_path):
    store.commit_arrivals([summary(1)], sync_next=2, batch_id='one', notify_next=2)
    store.commit_arrivals([summary(3)], sync_next=4, batch_id='two', notify_next=4)
    assert store.sync_state('a','INBOX').notify_next == 1
    assert len(store.pending('a','INBOX')) == 2
    store.ack('a','INBOX',10,'two')
    assert store.sync_state('a','INBOX').notify_next == 1
    reopened = MailStore(tmp_path / 'mail.db')
    assert [b.id for b in reopened.pending('a','INBOX')] == ['one']
    reopened.ack('a','INBOX',10,'one')
    reopened.ack('a','INBOX',10,'one')
    assert reopened.sync_state('a','INBOX').notify_next == 4
    assert reopened.pending('a','INBOX') == []
    reopened.close()


def test_arrivals_atomic_and_duplicate_batch_idempotent(store):
    store.commit_arrivals([summary(1)], sync_next=2, batch_id='one', notify_next=2)
    store.commit_arrivals([summary(1)], sync_next=2, batch_id='one', notify_next=2)
    assert len(store.pending('a','INBOX')) == 1
    with pytest.raises(MailError):
        store.commit_arrivals([summary(2), summary(3,validity=11)],sync_next=4,batch_id='bad',notify_next=4)
    assert [x.key.uid for x in store.page('a','INBOX').items] == [1]
    assert store.sync_state('a','INBOX').sync_next == 2


def test_delete_removes_body_and_pending_target_and_account_remove_leaves_chat(store,tmp_path):
    chat = tmp_path / 'cache.db'
    chat.write_bytes(b'synthetic chat sentinel')
    store.commit_arrivals([summary(1)],sync_next=2,batch_id='one',notify_next=2)
    store.save_body(key(),RawBody(kind='plain',source='hello'))
    store.delete_messages('a','INBOX',10,{1})
    assert store.get_body(key()) is None and store.pending('a','INBOX') == []
    assert store.sync_state('a','INBOX').notify_next == 2
    store.save_summaries([summary(2),summary(2,account='b')])
    store.remove_account('a')
    assert store.account('a') is None
    assert len(store.page('b','INBOX').items) == 1
    assert chat.read_bytes() == b'synthetic chat sentinel'


def test_raw_cache_is_resanitized_on_every_read(store,monkeypatch):
    store.save_summaries([summary()])
    store.save_body(key(),RawBody(kind='html',source='<script>evil</script><b>hello</b>'))
    assert store.get_body(key()).content == '<b>hello</b>'
    monkeypatch.setattr('feishu_lite.mail.store.render_body',lambda raw:'new policy')
    assert store.get_body(key()).content == 'new policy'
    assert store.db.execute('SELECT source FROM bodies').fetchone()[0].startswith('<script>')


def test_store_pragmas_migration_reopen_and_thread_ownership(store,tmp_path):
    assert store.db.execute('PRAGMA journal_mode').fetchone()[0] == 'wal'
    assert store.db.execute('PRAGMA busy_timeout').fetchone()[0] == 1000
    assert store.db.execute('PRAGMA user_version').fetchone()[0] == 2
    store.save_summaries([summary()])
    with ThreadPoolExecutor(max_workers=1) as pool:
        with pytest.raises(sqlite3.ProgrammingError):
            pool.submit(store.save_summaries,[summary(2)]).result()
    store.db.execute('DROP TABLE notification_items')
    store.db.execute('DROP TABLE notification_batches')
    store.db.execute('PRAGMA user_version=1')
    store.db.commit()
    reopened = MailStore(tmp_path/'mail.db')
    assert len(reopened.page('a','INBOX').items) == 1
    assert reopened.db.execute('PRAGMA user_version').fetchone()[0] == 2
    assert reopened.pending('a','INBOX') == []
    reopened.close()


def test_future_schema_and_wrong_filename_rejected(tmp_path):
    with pytest.raises(MailError,match='invalid_store_path'):
        MailStore(tmp_path/'cache.db')
    db = sqlite3.connect(tmp_path/'mail.db')
    db.execute('PRAGMA user_version=999')
    db.close()
    with pytest.raises(MailError,match='unsupported_schema'):
        MailStore(tmp_path/'mail.db')


def test_largest_valid_unicode_identity_roundtrips():
    original = key(folder='邮' * 512,account='账' * 512)
    assert MailKey.from_id(original.id) == original


def test_ack_replay_does_not_recreate_pending_and_new_batch_only_targets_new_uids(store):
    store.commit_arrivals([summary(1)],sync_next=2,batch_id='one',notify_next=2)
    store.ack('a','INBOX',10,'one')
    store.commit_arrivals([summary(1)],sync_next=2,batch_id='one',notify_next=2)
    assert store.pending('a','INBOX') == []
    store.commit_arrivals([summary(1),summary(3)],sync_next=4,batch_id='two',notify_next=4)
    assert [k.uid for k in store.pending('a','INBOX')[0].keys] == [3]


def test_conflicting_duplicate_batch_rolls_back_cache_and_watermark(store):
    store.commit_arrivals([summary(1)],sync_next=2,batch_id='same',notify_next=2)
    with pytest.raises(MailError,match='batch_conflict'):
        store.commit_arrivals([summary(3)],sync_next=4,batch_id='same',notify_next=4)
    assert [s.key.uid for s in store.page('a','INBOX').items] == [1]
    assert store.sync_state('a','INBOX').sync_next == 2


def test_watermark_gap_rejected(store):
    with pytest.raises(MailError,match='invalid_watermark'):
        store.commit_arrivals([summary(1)],sync_next=5,batch_id='one',notify_next=2)
    assert store.page('a','INBOX').items == []


def test_unread_cleanup_preserves_other_flags_and_ack_silent_intervals(store):
    flagged = summary().model_copy(update={'flags':['\\Flagged','\\Answered']})
    store.commit_arrivals([flagged],sync_next=2,batch_id='one',notify_next=2)
    store.advance_sync('a','INBOX',10,5)
    assert store.sync_state('a','INBOX').sync_next == 5
    assert store.sync_state('a','INBOX').notify_next == 1
    changed = store.replace_unseen('a','INBOX',10,set(),checked_at=1)
    assert changed == [key()]
    assert store.page('a','INBOX').items[0].flags == ['\\Flagged','\\Answered','\\Seen']
    assert store.pending('a','INBOX') == []
    assert store.sync_state('a','INBOX').notify_next == 5
    store.reset_folder('a',MailFolder(id='INBOX',name='renamed'),10,100)
    assert store.sync_state('a','INBOX').sync_next == 5  # same validity never clears a cache
    with pytest.raises(MailError,match='stale_message'):
        store.ack('a','INBOX',11,'one')


def test_account_address_change_requires_new_id(store):
    with pytest.raises(MailError,match='account_address_changed'):
        store.save_account('a','other@example.invalid')
    assert store.account('a').address == 'a@example.invalid'


def test_list_catalog_does_not_require_selecting_unsupported_folders(store):
    listed = [MailFolder(id='INBOX',name='收件箱',supported=True),
              MailFolder(id='分类/中文',name='中文',delimiter='/',selectable=False,flags=['\\Noselect'])]
    store.save_folders('a',listed)
    assert store.folders('a') == listed
    assert store.cached_uids('a','INBOX',10) == set()
    store.save_summaries([summary(1),summary(9)])
    assert store.cached_uids('a','INBOX',10) == {1,9}
    assert store.get_summary(key(9)).subject == 'synthetic 9'
    store.save_folders('a',[listed[1]])
    with pytest.raises(MailError,match='stale_message'):
        store.get_summary(key())
    assert store.folders('b')[0].id == 'INBOX'


def test_raw_body_can_be_detached_for_worker_sanitizing_without_sqlite_access(store):
    from feishu_lite.mail.html import render_body
    store.save_summaries([summary()])
    store.save_body(key(),RawBody(kind='html',source='<b>hello</b><script>evil</script>'))
    raw = store.get_raw_body(key())
    with ThreadPoolExecutor(max_workers=1) as pool:
        assert pool.submit(render_body,raw).result() == '<b>hello</b>'
