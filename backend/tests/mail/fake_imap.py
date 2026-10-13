"""Controllable C2 contract fake; real SQLite belongs to the service tests."""
import asyncio
import uuid

from feishu_lite.mail.html import render_body
from feishu_lite.mail.types import (BodyPart, FetchedBody, ImapIdentity, ImapResult,
                                  MailBody, MailError, MailFolder, MailKey,
                                  MailSummary, RawBody, SelectedMailbox)


class FakeMailbox:
    def __init__(self, uids=(3, 9, 22), unseen=(3, 9), uidnext=23):
        self.uids = set(uids)
        self.unread = set(unseen)
        self.uidnext = uidnext
        self.validity = 77
        self.now = 10000
        self.received = {}
        self.instances = []
        self.hooks = {}
        self.errors = {}
        self.calls = []
        self.idle = True
        self.bad = set()

    def factory(self, config):
        io = FakeImap(self, config)
        self.instances.append(io)
        return io

    def add(self, *uids, age=0):
        self.uids.update(uids)
        self.unread.update(uids)
        self.uidnext = max(self.uidnext, max(uids) + 1)
        self.received.update({uid: self.now - age for uid in uids})


class FakeImap:
    def __init__(self, box, config):
        self.box = box
        self.config = config
        self.identity = ImapIdentity(account_id=config.account_id, generation=config.generation,
                                     connection_id=uuid.uuid4().hex)
        self.reconcile_needed = asyncio.Event()
        self.closed = asyncio.Event()
        self.failure = None
        self.thread_alive = False
        self.stops = 0

    async def call(self, name, value, args=None):
        self.box.calls.append((name, args))
        if name in self.box.hooks:
            await self.box.hooks[name](self)
        if name in self.box.errors:
            raise MailError(self.box.errors[name])
        return ImapResult(identity=self.identity, value=value() if callable(value) else value)

    async def connect(self):
        self.thread_alive = True
        return await self.call('connect', ('IDLE',) if self.box.idle else ())

    async def list_folders(self):
        return await self.call('folders', [MailFolder(id='INBOX', name='收件箱', supported=True),
                                          MailFolder(id='分类/中文', name='中文', delimiter='/')])

    async def select_inbox(self, **kwargs):
        # Snapshot UIDNEXT before the hook introduces an initialization arrival.
        selected = SelectedMailbox(uidvalidity=self.box.validity, uidnext=self.box.uidnext,
                                   flags=['\\Seen'], permanent_flags=['\\Seen'], readonly=False)
        return await self.call('select', selected)

    async def all_uids(self):
        return await self.call('all', lambda: sorted(self.box.uids, reverse=True))

    async def unseen(self):
        return await self.call('unseen', lambda: sorted(self.box.unread & self.box.uids))

    async def new_uids(self, watermark):
        # Deliberately includes n:*'s last UID even below watermark.
        return await self.call('new', lambda: sorted(uid for uid in self.box.uids
                              if uid >= watermark or uid == max(self.box.uids)), watermark)

    async def existing_uids(self, cached):
        assert len(cached) <= 100
        return await self.call('existing', lambda: sorted(set(cached) & self.box.uids), list(cached))

    async def summaries(self, uids):
        assert len(uids) <= 100
        if self.box.bad.intersection(uids):
            self.failure = MailError('malformed_response')
            self.closed.set()
            raise self.failure
        return await self.call('summaries', lambda: [self.summary(uid) for uid in uids
                                                    if uid in self.box.uids], list(uids))

    def summary(self, uid):
        return MailSummary(key=MailKey(account_id=self.identity.account_id, folder_id='INBOX',
                                       uidvalidity=self.box.validity, uid=uid),
                           subject=f'Synthetic {uid}', received_at=self.box.received.get(uid, self.box.now),
                           unread=uid in self.box.unread, flags=['\\Flagged'],
                           body_part=BodyPart(section='1', media_type='text/html'))

    async def body(self, key, part):
        raw = RawBody(kind='html', source='<b>synthetic</b><script>bad</script>')
        return await self.call('body', FetchedBody(raw=raw, body=MailBody(kind='html', content=render_body(raw))))

    async def render_cached_body(self, raw):
        self.thread_alive = True
        return await self.call('render', MailBody(kind=raw.kind, content=render_body(raw)))

    async def mark_seen(self, key):
        result = await self.call('seen', None, key.uid)
        self.box.unread.discard(key.uid)
        return result

    async def stop(self):
        self.stops += 1
        if 'stop' in self.box.hooks:
            await self.box.hooks['stop'](self)
        if self.box.errors.get('stop') == 'stop_timeout':
            raise MailError('stop_timeout')
        self.thread_alive = False
        self.closed.set()
