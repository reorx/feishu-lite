"""Independent mail.db. Construct/use/close on the event-loop owner thread.

All public writes are atomic; worker threads return data instead of writing here.
No credentials and no chat Store dependencies. Schema v1 contains cache/snapshot,
v2 adds durable pending/ack batches. Raw HTML is never returned as display HTML.
"""
import sqlite3
from pathlib import Path

from .html import render_body
from .types import (MailAccount, MailBody, MailCursor, MailError, MailFolder, MailKey,
                    MailLimits, MailPage, MailSummary, PendingBatch, RawBody, SyncState)

SCHEMA_V1 = '''
CREATE TABLE accounts (id TEXT PRIMARY KEY, address TEXT NOT NULL);
CREATE TABLE folder_catalog (
    account_id TEXT NOT NULL REFERENCES accounts(id) ON DELETE CASCADE,
    folder_id TEXT NOT NULL, metadata TEXT NOT NULL,
    PRIMARY KEY(account_id, folder_id)
);
CREATE TABLE folders (
    account_id TEXT NOT NULL REFERENCES accounts(id) ON DELETE CASCADE,
    folder_id TEXT NOT NULL, uidvalidity INTEGER NOT NULL,
    sync_next INTEGER NOT NULL, notify_next INTEGER NOT NULL,
    checked_at INTEGER, PRIMARY KEY(account_id, folder_id),
    UNIQUE(account_id, folder_id, uidvalidity),
    FOREIGN KEY(account_id, folder_id)
        REFERENCES folder_catalog(account_id, folder_id) ON DELETE CASCADE
);
CREATE TABLE summaries (
    account_id TEXT NOT NULL, folder_id TEXT NOT NULL, uidvalidity INTEGER NOT NULL,
    uid INTEGER NOT NULL, data TEXT NOT NULL,
    PRIMARY KEY(account_id, folder_id, uidvalidity, uid),
    FOREIGN KEY(account_id, folder_id, uidvalidity)
        REFERENCES folders(account_id, folder_id, uidvalidity) ON DELETE CASCADE
);
CREATE TABLE bodies (
    account_id TEXT NOT NULL, folder_id TEXT NOT NULL, uidvalidity INTEGER NOT NULL,
    uid INTEGER NOT NULL, kind TEXT NOT NULL, source TEXT NOT NULL,
    PRIMARY KEY(account_id, folder_id, uidvalidity, uid),
    FOREIGN KEY(account_id, folder_id, uidvalidity, uid)
        REFERENCES summaries(account_id, folder_id, uidvalidity, uid) ON DELETE CASCADE
);
CREATE TABLE unseen (
    account_id TEXT NOT NULL, folder_id TEXT NOT NULL, uidvalidity INTEGER NOT NULL,
    uid INTEGER NOT NULL, PRIMARY KEY(account_id, folder_id, uidvalidity, uid),
    FOREIGN KEY(account_id, folder_id, uidvalidity)
        REFERENCES folders(account_id, folder_id, uidvalidity) ON DELETE CASCADE
);
'''
SCHEMA_V2 = '''
CREATE TABLE notification_batches (
    account_id TEXT NOT NULL, folder_id TEXT NOT NULL, uidvalidity INTEGER NOT NULL,
    batch_id TEXT NOT NULL, notify_next INTEGER NOT NULL, acked INTEGER NOT NULL DEFAULT 0,
    PRIMARY KEY(account_id, folder_id, uidvalidity, batch_id),
    FOREIGN KEY(account_id, folder_id, uidvalidity)
        REFERENCES folders(account_id, folder_id, uidvalidity) ON DELETE CASCADE
);
CREATE TABLE notification_items (
    account_id TEXT NOT NULL, folder_id TEXT NOT NULL, uidvalidity INTEGER NOT NULL,
    batch_id TEXT NOT NULL, uid INTEGER NOT NULL,
    PRIMARY KEY(account_id, folder_id, uidvalidity, batch_id, uid),
    FOREIGN KEY(account_id, folder_id, uidvalidity, batch_id)
        REFERENCES notification_batches(account_id, folder_id, uidvalidity, batch_id) ON DELETE CASCADE,
    FOREIGN KEY(account_id, folder_id, uidvalidity, uid)
        REFERENCES summaries(account_id, folder_id, uidvalidity, uid) ON DELETE CASCADE
);
'''


def _scope(key: MailKey) -> tuple:
    return key.account_id, key.folder_id, key.uidvalidity


def _identity(key: MailKey) -> tuple:
    return *_scope(key), key.uid


class MailStore:
    def __init__(self, path: Path):
        if path.name != 'mail.db':
            raise MailError('invalid_store_path')
        self.db = sqlite3.connect(path)  # default check_same_thread=True enforces ownership
        self.db.row_factory = sqlite3.Row
        version = self.db.execute('PRAGMA user_version').fetchone()[0]
        if version not in (0, 1, 2):
            self.db.close()
            raise MailError('unsupported_schema')
        self.db.execute('PRAGMA journal_mode=WAL')
        self.db.execute('PRAGMA busy_timeout=1000')
        self.db.execute('PRAGMA foreign_keys=ON')
        migration = ''
        if version == 0:
            migration += SCHEMA_V1 + '\nPRAGMA user_version=1;\n'
        if version < 2:
            migration += SCHEMA_V2 + '\nPRAGMA user_version=2;\n'
        if migration:
            self.db.executescript('BEGIN IMMEDIATE;\n' + migration + '\nCOMMIT;')

    def close(self):
        self.db.close()

    def save_account(self, account_id: str, address: str):
        account = MailAccount(id=account_id, address=address)
        existing = self.account(account_id)
        if existing and existing.address != address:
            raise MailError('account_address_changed')  # C3 generates a NEW id for new address
        with self.db:
            self.db.execute('INSERT OR IGNORE INTO accounts VALUES (?, ?)', (account.id, account.address))

    def account(self, account_id: str) -> MailAccount | None:
        row = self.db.execute('SELECT * FROM accounts WHERE id=?', (account_id,)).fetchone()
        return MailAccount(**dict(row)) if row else None

    def accounts(self) -> list[MailAccount]:
        return [MailAccount(**dict(row)) for row in self.db.execute('SELECT * FROM accounts ORDER BY id')]

    def has_folder(self, account_id: str, folder_id: str) -> bool:
        return self.db.execute('SELECT 1 FROM folders WHERE account_id=? AND folder_id=?',
                               (account_id, folder_id)).fetchone() is not None

    def remove_account(self, account_id: str):
        with self.db:
            self.db.execute('DELETE FROM accounts WHERE id=?', (account_id,))

    def reset_folder(self, account_id: str, folder: MailFolder, uidvalidity: int, uidnext: int):
        state = SyncState(account_id=account_id, folder_id=folder.id, uidvalidity=uidvalidity,
                          sync_next=uidnext, notify_next=uidnext, unread_count=0)
        with self.db:
            self._save_folder(account_id, folder)
            old = self.db.execute('SELECT uidvalidity FROM folders WHERE account_id=? AND folder_id=?',
                                  (account_id, folder.id)).fetchone()
            if old and old[0] == uidvalidity:
                return
            self.db.execute('DELETE FROM folders WHERE account_id=? AND folder_id=?', (account_id, folder.id))
            self.db.execute('INSERT INTO folders VALUES (?, ?, ?, ?, ?, NULL)',
                            (account_id, folder.id, uidvalidity, state.sync_next, state.notify_next))

    def _save_folder(self, account_id: str, folder: MailFolder):
        self.db.execute('INSERT INTO folder_catalog VALUES (?, ?, ?) ON CONFLICT DO UPDATE SET metadata=excluded.metadata',
                        (account_id, folder.id, folder.model_dump_json()))

    def save_folders(self, account_id: str, folders: list[MailFolder]):
        """Replace a complete LIST snapshot; no SELECT/UIDVALIDITY needed for metadata."""
        retained = {folder.id for folder in folders}
        with self.db:
            old = self.db.execute('SELECT folder_id FROM folder_catalog WHERE account_id=?', (account_id,)).fetchall()
            for folder in folders:
                self._save_folder(account_id, folder)
            self.db.executemany('DELETE FROM folder_catalog WHERE account_id=? AND folder_id=?',
                                [(account_id, row[0]) for row in old if row[0] not in retained])

    def folders(self, account_id: str) -> list[MailFolder]:
        return [MailFolder.model_validate_json(row[0]) for row in
                self.db.execute('SELECT metadata FROM folder_catalog WHERE account_id=? ORDER BY folder_id', (account_id,))]

    def cached_uids(self, account_id: str, folder_id: str, validity: int) -> set[int]:
        self._require_generation(account_id, folder_id, validity)
        return {row[0] for row in self.db.execute(
            'SELECT uid FROM summaries WHERE account_id=? AND folder_id=? AND uidvalidity=?',
            (account_id, folder_id, validity))}

    def get_summary(self, key: MailKey) -> MailSummary | None:
        self._require_generation(*_scope(key))
        row = self.db.execute('SELECT data FROM summaries WHERE account_id=? AND folder_id=? AND uidvalidity=? AND uid=?',
                              _identity(key)).fetchone()
        return MailSummary.model_validate_json(row[0]) if row else None

    def _require_generation(self, account_id: str, folder_id: str, validity: int, code='stale_message'):
        row = self.db.execute('SELECT uidvalidity FROM folders WHERE account_id=? AND folder_id=?',
                              (account_id, folder_id)).fetchone()
        if row is None or row[0] != validity:
            raise MailError(code)

    def sync_state(self, account_id: str, folder_id: str) -> SyncState:
        row = self.db.execute('SELECT * FROM folders WHERE account_id=? AND folder_id=?',
                              (account_id, folder_id)).fetchone()
        if not row:
            raise MailError('folder_missing')
        count = self.db.execute('SELECT COUNT(*) FROM unseen WHERE account_id=? AND folder_id=?',
                                (account_id, folder_id)).fetchone()[0]
        return SyncState(account_id=account_id, folder_id=folder_id, uidvalidity=row['uidvalidity'],
                         sync_next=row['sync_next'], notify_next=row['notify_next'],
                         unread_count=count, checked_at=row['checked_at'])

    def _save_summary(self, summary: MailSummary):
        self._require_generation(*_scope(summary.key))
        self.db.execute('INSERT INTO summaries VALUES (?, ?, ?, ?, ?) ON CONFLICT DO UPDATE SET data=excluded.data',
                        (*_identity(summary.key), summary.model_dump_json()))

    def save_summaries(self, summaries: list[MailSummary]):
        with self.db:
            for summary in summaries:
                self._save_summary(summary)

    def page(self, account_id: str, folder_id: str, *, cursor: str | None = None, limit: int | None = None) -> MailPage:
        state = self.sync_state(account_id, folder_id)
        before = 4294967296
        if cursor is not None:
            key = MailCursor.from_id(cursor).key
            if _scope(key) != (account_id, folder_id, state.uidvalidity):
                raise MailError('stale_cursor')
            before = key.uid
        limit = limit if limit is not None else 50 if cursor is not None else 100
        if type(limit) is not int or not 1 <= limit <= 100:
            raise MailError('invalid_page_size')
        rows = self.db.execute('SELECT data FROM summaries WHERE account_id=? AND folder_id=? AND uid<? ORDER BY uid DESC LIMIT ?',
                               (account_id, folder_id, before, limit + 1)).fetchall()
        items = [MailSummary.model_validate_json(row[0]) for row in rows[:limit]]
        next_cursor = MailCursor(key=items[-1].key).id if len(rows) > limit else None
        return MailPage(items=items, next_cursor=next_cursor)

    def save_body(self, key: MailKey, raw: RawBody):
        self._require_generation(*_scope(key))
        if len(raw.source.encode('utf-8')) > MailLimits().max_body_bytes:
            raise MailError('body_too_large')
        with self.db:
            self.db.execute('INSERT INTO bodies VALUES (?, ?, ?, ?, ?, ?) ON CONFLICT DO UPDATE SET kind=excluded.kind, source=excluded.source',
                            (*_identity(key), raw.kind, raw.source))

    def get_raw_body(self, key: MailKey) -> RawBody | None:
        """Internal cache only; detach on owner thread, sanitize on MIME worker.

        C3 must never serialize this raw source as an API display field.
        """
        self._require_generation(*_scope(key))
        row = self.db.execute('SELECT kind, source FROM bodies WHERE account_id=? AND folder_id=? AND uidvalidity=? AND uid=?',
                              _identity(key)).fetchone()
        if not row:
            return None
        return RawBody(**dict(row))

    def get_body(self, key: MailKey) -> MailBody | None:
        """Synchronous convenience for callers without an event loop.

        Async integration uses get_raw_body + worker render_body instead.
        """
        raw = self.get_raw_body(key)
        return MailBody(kind=raw.kind, content=render_body(raw)) if raw else None

    def replace_unseen(self, account_id: str, folder_id: str, validity: int, uids: set[int], *, checked_at: int) -> list[MailKey]:
        self._require_generation(account_id, folder_id, validity)
        keys = [MailKey(account_id=account_id, folder_id=folder_id, uidvalidity=validity, uid=uid) for uid in uids]
        scope = account_id, folder_id, validity
        with self.db:
            self.db.execute('DELETE FROM unseen WHERE account_id=? AND folder_id=? AND uidvalidity=?', scope)
            self.db.executemany('INSERT INTO unseen VALUES (?, ?, ?, ?)', [_identity(key) for key in keys])
            became_read = self._update_flags(scope, uids)
            self.db.execute('UPDATE folders SET checked_at=? WHERE account_id=? AND folder_id=?',
                            (checked_at, account_id, folder_id))
            self._remove_empty_batches(scope)
        return became_read

    def _update_flags(self, scope: tuple, uids: set[int]) -> list[MailKey]:
        rows = self.db.execute('SELECT data FROM summaries WHERE account_id=? AND folder_id=? AND uidvalidity=?', scope).fetchall()
        became_read = []
        for row in rows:
            summary = MailSummary.model_validate_json(row[0])
            unread = summary.key.uid in uids
            flags = [flag for flag in summary.flags if flag.lower() != '\\seen']
            if not unread:
                flags.append('\\Seen')
                self.db.execute('DELETE FROM notification_items WHERE account_id=? AND folder_id=? AND uidvalidity=? AND uid=?', _identity(summary.key))
            if summary.unread and not unread:
                became_read.append(summary.key)
            self._save_summary(summary.model_copy(update={'unread': unread, 'flags': flags}))
        return became_read

    def commit_arrivals(self, summaries: list[MailSummary], *, sync_next: int, batch_id: str | None, notify_next: int):
        """Atomic cache + UID watermarks + pending insertion; caller decides eligibility.

        Supply only notification-eligible arrivals when batch_id is given; seen rows
        cannot become pending. For historical/non-notifying work pass batch_id=None.
        Global unread snapshots are separate server truth, never derived from this page.
        """
        if not summaries:
            raise MailError('empty_arrivals')
        scope = _scope(summaries[0].key)
        self._require_generation(*scope)
        if any(_scope(summary.key) != scope for summary in summaries):
            raise MailError('stale_message')
        state = self.sync_state(*scope[:2])
        # Validate supplied counters without coercion.
        validated = SyncState(**(state.model_dump() | {'sync_next': sync_next, 'notify_next': notify_next}))
        if notify_next != sync_next or any(summary.key.uid >= sync_next for summary in summaries):
            raise MailError('invalid_watermark')
        if batch_id is not None and (not batch_id or len(batch_id) > 512):
            raise MailError('invalid_batch')
        with self.db:
            for summary in summaries:
                self._save_summary(summary)
            self._record_checkpoint(scope, batch_id, validated.notify_next,
                                    [summary.key.uid for summary in summaries
                                     if summary.unread and summary.key.uid >= state.sync_next])
            self.db.execute('UPDATE folders SET sync_next=MAX(sync_next,?) WHERE account_id=? AND folder_id=?',
                            (validated.sync_next, *scope[:2]))
            self._drain_acked(scope)

    def advance_sync(self, account_id: str, folder_id: str, validity: int, uidnext: int):
        """Silent checkpoint for a reconciled interval with no eligible arrivals."""
        scope = account_id, folder_id, validity
        self._require_generation(*scope)
        state = self.sync_state(account_id, folder_id)
        validated = SyncState(**(state.model_dump() | {'sync_next': uidnext}))
        with self.db:
            self._record_checkpoint(scope, None, validated.sync_next, [])
            self.db.execute('UPDATE folders SET sync_next=MAX(sync_next,?) WHERE account_id=? AND folder_id=?',
                            (validated.sync_next, account_id, folder_id))
            self._drain_acked(scope)

    def _record_checkpoint(self, scope: tuple, batch_id: str | None, notify_next: int, uids: list[int]):
        state = self.sync_state(*scope[:2])
        if notify_next <= state.notify_next:
            return  # already acknowledged / historical replay
        identifier = batch_id if batch_id is not None else f'silent:{notify_next}'
        existing = self.db.execute('SELECT notify_next FROM notification_batches WHERE account_id=? AND folder_id=? AND uidvalidity=? AND batch_id=?',
                                   (*scope, identifier)).fetchone()
        if existing:
            if existing[0] != notify_next:
                raise MailError('batch_conflict')
            return
        if notify_next <= state.sync_next:
            raise MailError('invalid_watermark')
        self.db.execute('INSERT INTO notification_batches VALUES (?, ?, ?, ?, ?, ?)',
                        (*scope, identifier, notify_next, int(batch_id is None or not uids)))
        if batch_id is not None:
            self.db.executemany('INSERT INTO notification_items VALUES (?, ?, ?, ?, ?)',
                                [(*scope, identifier, uid) for uid in set(uids)])

    def pending(self, account_id: str, folder_id: str) -> list[PendingBatch]:
        state = self.sync_state(account_id, folder_id)
        scope = account_id, folder_id, state.uidvalidity
        rows = self.db.execute('SELECT * FROM notification_batches WHERE account_id=? AND folder_id=? AND uidvalidity=? AND acked=0 ORDER BY notify_next, batch_id',scope).fetchall()
        return [self._pending_batch(row, scope) for row in rows]

    def _pending_batch(self, row, scope: tuple) -> PendingBatch:
        keys = [MailKey(account_id=scope[0], folder_id=scope[1], uidvalidity=scope[2], uid=item[0])
                for item in self.db.execute('SELECT uid FROM notification_items WHERE account_id=? AND folder_id=? AND uidvalidity=? AND batch_id=? ORDER BY uid',(*scope,row['batch_id']))]
        return PendingBatch(id=row['batch_id'], account_id=scope[0], folder_id=scope[1], uidvalidity=scope[2],
                            notify_next=row['notify_next'], keys=keys)

    def ack(self, account_id: str, folder_id: str, validity: int, batch_id: str):
        scope = account_id, folder_id, validity
        self._require_generation(*scope)
        with self.db:
            self.db.execute('UPDATE notification_batches SET acked=1 WHERE account_id=? AND folder_id=? AND uidvalidity=? AND batch_id=?',(*scope,batch_id))
            self._drain_acked(scope)

    def _drain_acked(self, scope: tuple):
        rows = self.db.execute('SELECT batch_id, notify_next, acked FROM notification_batches WHERE account_id=? AND folder_id=? AND uidvalidity=? ORDER BY notify_next, batch_id',scope).fetchall()
        for row in rows:
            if not row['acked']:
                break
            self.db.execute('UPDATE folders SET notify_next=MAX(notify_next,?) WHERE account_id=? AND folder_id=?',(row['notify_next'],*scope[:2]))
            self.db.execute('DELETE FROM notification_batches WHERE account_id=? AND folder_id=? AND uidvalidity=? AND batch_id=?',(*scope,row['batch_id']))

    def _remove_empty_batches(self, scope: tuple):
        self.db.execute('''UPDATE notification_batches SET acked=1
            WHERE account_id=? AND folder_id=? AND uidvalidity=? AND NOT EXISTS
            (SELECT 1 FROM notification_items i WHERE i.account_id=notification_batches.account_id
             AND i.folder_id=notification_batches.folder_id AND i.uidvalidity=notification_batches.uidvalidity
             AND i.batch_id=notification_batches.batch_id)''',scope)
        self._drain_acked(scope)

    def delete_messages(self, account_id: str, folder_id: str, validity: int, uids: set[int]):
        scope = account_id, folder_id, validity
        self._require_generation(*scope)
        identities = [_identity(MailKey(account_id=account_id,folder_id=folder_id,uidvalidity=validity,uid=uid)) for uid in uids]
        with self.db:
            self.db.executemany('DELETE FROM summaries WHERE account_id=? AND folder_id=? AND uidvalidity=? AND uid=?',identities)
            self.db.executemany('DELETE FROM unseen WHERE account_id=? AND folder_id=? AND uidvalidity=? AND uid=?',identities)
            self._remove_empty_batches(scope)
