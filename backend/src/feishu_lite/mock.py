"""Local dataset adapters. No protocol clients, network calls or persistent fixture edits."""

import asyncio
import json
import time
import uuid
from datetime import datetime, timedelta
from pathlib import Path
from typing import Literal

from pydantic import BaseModel, ConfigDict, Field, SecretStr, model_validator

from .api import create_app
from .mail.html import render_body
from .mail.service import MailService
from .mail.types import (
    Attachment,
    BodyPart,
    FetchedBody,
    ImapIdentity,
    ImapResult,
    MailBody,
    MailFolder,
    MailHeaders,
    MailKey,
    MailSummary,
    RawBody,
    SelectedMailbox,
)
from .meeting import meeting_text
from .service import Service
from .store import Store
from .types import Chat, FeedItem, Message, User


class FixtureModel(BaseModel):
    model_config = ConfigDict(extra='forbid')


class RelativeTime(FixtureModel):
    day: int = 0
    time: str = Field(pattern=r'^([01]\d|2[0-3]):[0-5]\d$')

    def resolve(self, now: datetime) -> int:
        hour, minute = map(int, self.time.split(':'))
        return int(
            (now.replace(hour=hour, minute=minute, second=0, microsecond=0) + timedelta(days=self.day)).timestamp()
        )


def timestamp(value, now):
    return value.resolve(now) if isinstance(value, RelativeTime) else value


class Meeting(FixtureModel):
    topic: str
    number: str = Field(pattern=r'^[0-9]{9}$')

    def text(self):
        return meeting_text(self.topic, self.number)


class ChatMessage(FixtureModel):
    id: str = Field(min_length=1)
    sender_id: str
    time: RelativeTime | int
    type: Literal['text', 'post', 'image', 'video_chat', 'system'] = 'text'
    text: str = ''
    image: str | None = None
    meeting: Meeting | None = None
    badged: bool = True
    at_me: bool = False

    @model_validator(mode='after')
    def required_content(self):
        if self.type == 'image' and not self.image:
            raise ValueError('image message requires image path')
        if self.type == 'video_chat' and not self.meeting:
            raise ValueError('video_chat requires meeting')
        return self

    def display_text(self):
        if self.type == 'video_chat':
            return self.meeting.text()
        if self.type == 'image':
            return '[图片]'
        return self.text


class ChatFixture(FixtureModel):
    id: str = Field(min_length=1)
    name: str
    type: Literal['p2p', 'group'] = 'group'
    unread: int = Field(default=0, ge=0)
    muted: bool = False
    messages: list[ChatMessage] = Field(default_factory=list)


class ChatData(FixtureModel):
    me: User = Field(default_factory=lambda: User(id='mock-me', name='模拟用户'))
    users: list[User] = Field(default_factory=list)
    chats: list[ChatFixture] = Field(default_factory=list)

    @model_validator(mode='after')
    def references(self):
        unique([self.me.id, *(u.id for u in self.users)], 'user id')
        unique([c.id for c in self.chats], 'chat id')
        unique([m.id for c in self.chats for m in c.messages], 'message id')
        users = {self.me.id, *(u.id for u in self.users)}
        for ci, chat in enumerate(self.chats):
            for mi, message in enumerate(chat.messages):
                if message.sender_id not in users:
                    raise ValueError(f'chats.{ci}.messages.{mi}.sender_id: unknown user {message.sender_id}')
        return self


def unique(values, label):
    if len(values) != len(set(values)):
        raise ValueError(f'duplicate {label}')


class EmailFixture(MailHeaders):
    uid: int = Field(ge=1, le=4294967295)
    time: RelativeTime | int
    unread: bool = True
    body: RawBody
    attachments: list[Attachment] = Field(default_factory=list)


class EmailData(FixtureModel):
    address: str = Field(pattern=r'^[^\s@]+@[^\s@]+$')
    folders: list[MailFolder]
    messages: list[EmailFixture] = Field(default_factory=list)

    @model_validator(mode='after')
    def references(self):
        unique([f.id for f in self.folders], 'folder id')
        unique([m.uid for m in self.messages], 'mail uid')
        if not any(f.id == 'INBOX' and f.supported and f.selectable for f in self.folders):
            raise ValueError('folders requires supported, selectable INBOX')
        if any(f.supported for f in self.folders if f.id != 'INBOX'):
            raise ValueError('only INBOX is supported')
        return self


class Dataset(FixtureModel):
    root: Path
    now: datetime
    chat: ChatData
    mail: EmailData | None = None

    @classmethod
    def load(cls, root: Path, *, now=None):
        root = root.expanduser().resolve()
        if not root.is_dir():
            raise ValueError(f'mock data directory does not exist: {root}')
        values = {}
        for filename, model, key in [('messages.json', ChatData, 'chat'), ('emails.json', EmailData, 'mail')]:
            path = root / filename
            if path.exists():
                # Dataset loading is the input boundary: retain filename + pydantic field location.
                try:
                    values[key] = model.model_validate_json(path.read_text())
                except (ValueError, OSError) as error:
                    raise ValueError(f'{path}: {error}') from error
        data = cls(root=root, now=now or datetime.now(), chat=values.get('chat', ChatData()), mail=values.get('mail'))
        for ci, chat in enumerate(data.chat.chats):
            for mi, message in enumerate(chat.messages):
                if message.image:
                    path = data.image_path(message.image)
                    if not path.is_file():
                        raise ValueError(f'{root}/messages.json chats.{ci}.messages.{mi}.image: missing file {path}')
        return data

    def image_path(self, name):
        path = (self.root / name).resolve()
        if not path.is_relative_to(self.root / 'images'):
            raise ValueError(f'{self.root}/messages.json image: must stay inside images/: {name}')
        return path


class MockSource:
    def __init__(self, data: Dataset):
        self.data = data
        self.me = data.chat.me
        self.names = {u.id: u.name for u in [self.me, *data.chat.users]}
        self.chats = {}
        self.history = {}
        self.images = {}
        for item in data.chat.chats:
            history = {}
            for position, row in enumerate(item.messages):
                history[position] = Message(
                    id=row.id,
                    chat_id=item.id,
                    position=position,
                    sender_id=row.sender_id,
                    sender_name=self.names[row.sender_id],
                    is_self=row.sender_id == self.me.id,
                    create_time=timestamp(row.time, data.now),
                    type=row.type,
                    text=row.display_text(),
                    badged=row.badged and row.type != 'system',
                    at_me=row.at_me,
                )
                if row.image:
                    self.images[row.id] = data.image_path(row.image)
            latest = history.get(len(history) - 1)
            self.history[item.id] = history
            self.chats[item.id] = Chat(
                id=item.id,
                name=item.name,
                type=item.type,
                unread=item.unread,
                muted=item.muted,
                last_position=len(history) - 1,
                rank_time=latest.create_time if latest else 0,
                last_message_time=latest.create_time if latest else 0,
            )

    async def restore(self):
        return self.me.model_copy()

    async def list_feed(self, limit):
        return [
            FeedItem(chat=c.model_copy(), last_message=self.history[c.id].get(c.last_position))
            for c in sorted(self.chats.values(), key=lambda c: c.rank_time, reverse=True)[:limit]
        ]

    async def get_chat(self, chat_id):
        chat = self.chats.get(chat_id)
        return chat.model_copy() if chat else None

    async def pull_history(self, chat_id, positions):
        rows = self.history.get(chat_id, {})
        return [rows[p].model_copy() for p in sorted(positions) if p in rows]

    async def send_text(self, chat_id, text):
        chat = self.chats[chat_id]
        message = Message(
            id=f'mock-{uuid.uuid4().hex}',
            chat_id=chat_id,
            position=chat.last_position + 1,
            sender_id=self.me.id,
            sender_name=self.me.name,
            is_self=True,
            create_time=int(time.time()),
            type='text',
            text=text,
        )
        self.history[chat_id][message.position] = message
        chat.last_position = message.position
        chat.rank_time = chat.last_message_time = message.create_time
        return message.model_copy()

    async def mark_read(self, chat_id, max_position):
        self.chats[chat_id].unread = 0

    async def fetch_image(self, message):
        return self.images[message.id].read_bytes()

    async def user_names(self, user_ids):
        return {uid: self.names[uid] for uid in user_ids if uid in self.names}

    async def stream(self, on_connected, on_message):
        on_connected()
        await asyncio.Future()

    async def keepalive(self):
        pass

    async def logout(self):
        pass

    async def qr_login_start(self):
        return 'mock-local-login'

    async def qr_login_poll(self):
        return 'success'


class MockMailbox:
    def __init__(self, data: Dataset):
        self.data = data
        self.rows = {m.uid: m for m in data.mail.messages} if data.mail else {}
        self.unread = {uid for uid, row in self.rows.items() if row.unread}

    def factory(self, config):
        return MockImap(self, config)


class MockImap:
    def __init__(self, box, config):
        self.box = box
        self.identity = ImapIdentity(
            account_id=config.account_id, generation=config.generation, connection_id=uuid.uuid4().hex
        )
        self.reconcile_needed = asyncio.Event()
        self.closed = asyncio.Event()
        self.failure = None
        self.thread_alive = False

    def result(self, value):
        return ImapResult(identity=self.identity, value=value)

    async def connect(self):
        return self.result(('IDLE',))

    async def list_folders(self):
        return self.result(self.box.data.mail.folders if self.box.data.mail else [])

    async def select_inbox(self, **kwargs):
        return self.result(
            SelectedMailbox(
                uidvalidity=1,
                uidnext=max(self.box.rows, default=0) + 1,
                flags=['\\Seen'],
                permanent_flags=['\\Seen'],
                readonly=False,
            )
        )

    async def all_uids(self):
        return self.result(sorted(self.box.rows, reverse=True))

    async def unseen(self):
        return self.result(sorted(self.box.unread))

    async def new_uids(self, watermark):
        return self.result([uid for uid in self.box.rows if uid >= watermark])

    async def existing_uids(self, cached):
        return self.result(sorted(set(cached) & self.box.rows.keys()))

    async def summaries(self, uids):
        return self.result([self.summary(uid) for uid in uids if uid in self.box.rows])

    def summary(self, uid):
        row = self.box.rows[uid]
        fields = row.model_dump(include=set(MailHeaders.model_fields))
        return MailSummary(
            **fields,
            key=MailKey(account_id=self.identity.account_id, folder_id='INBOX', uidvalidity=1, uid=uid),
            received_at=timestamp(row.time, self.box.data.now),
            unread=uid in self.box.unread,
            attachments=row.attachments,
            flags=[] if uid in self.box.unread else ['\\Seen'],
            body_part=BodyPart(section='1', media_type=f'text/{row.body.kind}'),
        )

    async def body(self, key, part):
        raw = self.box.rows[key.uid].body
        return self.result(FetchedBody(raw=raw, body=MailBody(kind=raw.kind, content=render_body(raw))))

    async def render_cached_body(self, raw):
        return self.result(MailBody(kind=raw.kind, content=render_body(raw)))

    async def mark_seen(self, key):
        self.box.unread.discard(key.uid)
        return self.result(None)

    async def stop(self):
        self.closed.set()


class MockMailService(MailService):
    def __init__(self, store, *, data, emit):
        self.dataset = data
        self.mailbox = MockMailbox(data)
        super().__init__(store, adapter_factory=self.mailbox.factory, emit=emit)

    async def start(self):
        await super().start()
        if self.dataset.mail:
            await self.configure(self.dataset.mail.address, SecretStr('mock-only'))
            await self.refresh()


def create_mock_app(data: Dataset, home: Path, token: str):
    home.mkdir(parents=True, exist_ok=True)
    service = Service(MockSource(data), Store(home / 'cache.db'))
    return create_app(
        service,
        token,
        mail_path=home / 'mail.db',
        mail_factory=lambda store, emit: MockMailService(store, data=data, emit=emit),
    )
