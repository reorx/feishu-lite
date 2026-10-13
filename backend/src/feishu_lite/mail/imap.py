"""Async INBOX-only adapter. No scheduling, SQLite, SSE or account lifecycle."""
import re
import imaplib
from datetime import datetime
from pydantic import ValidationError

from .executor import ImapExecutor
from .html import render_body
from .mime import decode_body, normalize_structure, parse_headers, select_body
from .types import (FetchedBody, MailBody, MailError, MailFolder, MailKey,
                    MailSummary, SelectedMailbox)

HEADER_FIELDS = 'FROM TO CC SUBJECT DATE MESSAGE-ID'
HEADER_PEEK = f'BODY.PEEK[HEADER.FIELDS ({HEADER_FIELDS})]'
HEADER_KEY = f'BODY[HEADER.FIELDS ({HEADER_FIELDS})]'.encode()
SUMMARY_FIELDS = ['FLAGS', 'INTERNALDATE', 'RFC822.SIZE', 'BODYSTRUCTURE', HEADER_PEEK]


def _uid(value):
    if type(value) is not int or not 1 <= value <= 4294967295:
        raise MailError('invalid_uid')
    return value


def _uids(values):
    if len(values) > 100:
        raise MailError('invalid_batch')
    return list(dict.fromkeys(_uid(value) for value in values))


def _flags(values):
    return [flag.decode('ascii') for flag in values]


class ImapAdapter(ImapExecutor):
    async def connect(self):
        return await self.submit(self._open, priority=0)

    def _open(self):
        if self.client is not None:
            raise MailError('already_connected')
        return self._connect()

    def _require_inbox(self, folder):
        if not isinstance(folder, str) or folder.upper() != 'INBOX':
            raise MailError('unsupported_folder')
        if self.selected is None:
            raise MailError('mailbox_not_selected')

    def _require_key(self, key):
        self._require_inbox(key.folder_id)
        if key.account_id != self.identity.account_id or key.uidvalidity != self.selected.uidvalidity:
            raise MailError('stale_message')

    async def list_folders(self):
        return await self.submit(self._list_folders)

    def _list_folders(self):
        # INBOX is the sole case-insensitive protocol identifier. Canonicalize
        # its key so catalog, SELECT and C1 cache share the same folder scope.
        return [MailFolder(id='INBOX' if name.upper() == 'INBOX' else name,
                           name=name, delimiter=delimiter.decode() if delimiter else None,
                           flags=_flags(flags), selectable=b'\\NOSELECT' not in {f.upper() for f in flags},
                           supported=name.upper() == 'INBOX' and b'\\NOSELECT' not in {f.upper() for f in flags})
                for flags, delimiter, name in self.client.list_folders()]

    async def select_inbox(self, *, readonly=False):
        return await self.submit(lambda: self._select_inbox(readonly), priority=1)

    def _select_inbox(self, readonly):
        # imaplib raises readonly for a successful SELECT returning READ-ONLY.
        # At this top-level selection boundary, EXAMINE retrieves the same
        # metadata without pretending that the mailbox is writable.
        try:
            data = self.client.select_folder('INBOX', readonly=readonly)
        except imaplib.IMAP4.readonly:
            readonly = True
            data = self.client.select_folder('INBOX', readonly=True)
        self.selected = SelectedMailbox(uidvalidity=data[b'UIDVALIDITY'], uidnext=data[b'UIDNEXT'],
                                        flags=_flags(data.get(b'FLAGS', ())),
                                        permanent_flags=_flags(data.get(b'PERMANENTFLAGS', ())),
                                        readonly=readonly or bool(data.get(b'READ-ONLY', False)))
        return self.selected

    async def all_uids(self, *, folder='INBOX'):
        return await self.submit(lambda: self._search(['ALL'], folder, reverse=True))

    async def unseen(self, *, folder='INBOX'):
        return await self.submit(lambda: self._search(['UNSEEN'], folder))

    async def new_uids(self, watermark, *, folder='INBOX'):
        if type(watermark) is not int or not 1 <= watermark <= 4294967296:
            raise MailError('invalid_uid')
        if watermark == 4294967296:
            return await self.submit(lambda: self._empty_search(folder))
        return await self.submit(lambda: [uid for uid in self._search(['UID', f'{watermark}:*'], folder) if uid >= watermark])

    def _empty_search(self, folder):
        self._require_inbox(folder)
        return []

    async def existing_uids(self, cached, *, folder='INBOX'):
        # Bound each wire set. C3 may call multiple batches for larger caches.
        ids = _uids(cached)
        if not ids:
            return await self.submit(lambda: self._empty_search(folder))
        return await self.submit(lambda: [uid for uid in self._search(['UID', ','.join(map(str, ids))], folder) if uid in ids])

    def _search(self, criteria, folder, *, reverse=False):
        self._require_inbox(folder)
        return sorted({_uid(uid) for uid in self.client.search(criteria)}, reverse=reverse)

    async def uid_page(self, *, before_uid=None, limit=100, folder='INBOX'):
        if type(limit) is not int or not 1 <= limit <= 100:
            raise MailError('invalid_page_size')
        if before_uid is not None:
            _uid(before_uid)
        return await self.submit(lambda: [uid for uid in self._search(['ALL'], folder, reverse=True)
                                         if before_uid is None or uid < before_uid][:limit])

    async def summaries(self, uids, *, folder='INBOX'):
        ids = _uids(uids)
        return await self.submit(lambda: self._summaries(ids, folder))

    def _summaries(self, ids, folder):
        self._require_inbox(folder)
        self.transport.begin(self.command_timeout, literal_limit=self.limits.max_header_bytes,
                             literal_code='headers_too_large')
        response = self.client.fetch(ids, SUMMARY_FIELDS)
        if ids and not response:
            raise MailError('message_missing')
        return [self._parse_summary(uid, response.get(uid)) for uid in ids]

    def _parse_summary(self, uid, data):
        # A complete single-record parse is a top-level message boundary.
        key = MailKey(account_id=self.identity.account_id, folder_id='INBOX',
                      uidvalidity=self.selected.uidvalidity, uid=uid)
        if data is None:
            return MailSummary(key=key, received_at=0, error='message_missing')
        try:
            headers = parse_headers(data[HEADER_KEY], self.limits)
            selection = select_body(normalize_structure(data[b'BODYSTRUCTURE'], self.limits))
            received = data[b'INTERNALDATE']
            if not isinstance(received, datetime) or received.tzinfo is None:
                raise MailError('malformed_response')
            flags = _flags(data[b'FLAGS'])
            return MailSummary(key=key, **headers.model_dump(), received_at=int(received.timestamp()),
                               size=data[b'RFC822.SIZE'], flags=flags, unread='\\seen' not in {f.lower() for f in flags},
                               attachments=selection.attachments, body_part=selection.body)
        except MailError as exc:
            return MailSummary(key=key, received_at=0, error=exc.code)
        except (KeyError, TypeError, ValueError, UnicodeError, ValidationError):
            return MailSummary(key=key, received_at=0, error='malformed_response')

    async def body(self, key, part):
        return await self.submit(lambda: self._body(key, part), priority=0)

    def _body(self, key, part):
        self._require_key(key)
        if part is None or not re.fullmatch(r'[1-9][0-9]*(?:\.[1-9][0-9]*)*', part.section) or part.media_type not in ('text/plain', 'text/html') or part.disposition == 'attachment':
            raise MailError('unsupported_body')
        if part.encoded_size > self.limits.max_body_bytes:
            raise MailError('body_too_large')
        self.transport.begin(self.command_timeout, literal_limit=self.limits.max_body_bytes,
                             literal_code='body_too_large')
        response = self.client.fetch([key.uid], [f'BODY.PEEK[{part.section}]'])
        data = response.get(key.uid, {})
        literal = data.get(f'BODY[{part.section}]'.encode())
        if not isinstance(literal, bytes):
            raise MailError('message_missing')
        raw = decode_body(part, literal, self.limits)
        return FetchedBody(raw=raw, body=MailBody(kind=raw.kind, content=render_body(raw)))

    async def render_cached_body(self, raw):
        # Caller detaches raw via MailStore.get_raw_body on the loop thread.
        return await self.submit(lambda: MailBody(kind=raw.kind, content=render_body(raw)), priority=0)

    async def mark_seen(self, key):
        return await self.submit(lambda: self._mark_seen(key), priority=0)

    def _mark_seen(self, key):
        self._require_key(key)
        if self.selected.readonly or not {'\\seen', '\\*'}.intersection(f.lower() for f in self.selected.permanent_flags):
            raise MailError('mailbox_readonly')
        # A tagged OK for UID STORE of an absent UID is also legal: first
        # establish presence; C3 reconciles UNSEEN after a successful STORE.
        if key.uid not in self._search(['UID', str(key.uid)], 'INBOX'):
            raise MailError('message_missing')
        self.client.add_flags([key.uid], ['\\Seen'], silent=True)
        # UID STORE may return tagged OK even if the UID vanished meanwhile.
        # Verify this single UID; C3 still owns the whole-INBOX reconciliation.
        flags = self.client.get_flags([key.uid])
        if key.uid not in flags:
            raise MailError('message_missing')
        if b'\\SEEN' not in {flag.upper() for flag in flags[key.uid]}:
            raise MailError('seen_not_persisted')
        return None
