"""In-memory stand-in for the Feishu protocol layer, driven by the tests."""

import asyncio

from feishu_lite.types import AuthExpired, Chat, FeedItem, Message, User

ME = User(id='u_me', name='我')


def make_chat(chat_id, *, name='', type='group', unread=0, muted=False, last_position=-1, rank_time=0):
    return Chat(
        id=chat_id, name=name, type=type, unread=unread, muted=muted, last_position=last_position, rank_time=rank_time
    )


def make_msg(chat_id, position, *, sender_id='u_alice', text='hi', create_time=None, badged=True, msg_id=None):
    return Message(
        id=msg_id or f'{chat_id}-m{position}',
        chat_id=chat_id,
        position=position,
        sender_id=sender_id,
        is_self=sender_id == ME.id,
        create_time=create_time if create_time is not None else 1_700_000_000 + position,
        type='text',
        text=text,
        badged=badged,
    )


class FakeSource:
    """Server-side state lives here; the service under test only sees it through the Source interface."""

    def __init__(self):
        self.me = ME
        self.has_credentials = True
        self.expired = False
        self.chats: dict[str, Chat] = {}
        self.history: dict[str, dict[int, Message]] = {}
        self.names = {ME.id: ME.name, 'u_alice': 'Alice', 'u_bob': 'Bob'}
        self.sent: list[tuple[str, str]] = []
        self.read_calls: list[tuple[str, int]] = []
        self.history_calls: list[tuple[str, list[int]]] = []
        self.connect_count = 0
        self.connected = asyncio.Event()
        self.qr_script = ['waiting', 'scanned', 'success']
        self._stream_q: asyncio.Queue | None = None
        self._send_seq = 1000

    # ---- server-side state helpers used by tests ----

    def add_chat(self, chat: Chat, messages=()):
        self.chats[chat.id] = chat
        self.history.setdefault(chat.id, {})
        for m in messages:
            self.add_message(m, count_unread=False)

    def add_message(self, msg: Message, count_unread=True):
        self.history.setdefault(msg.chat_id, {})[msg.position] = msg
        chat = self.chats[msg.chat_id]
        chat.last_position = max(chat.last_position, msg.position)
        chat.rank_time = max(chat.rank_time, msg.create_time)
        chat.last_message_time = max(chat.last_message_time, msg.create_time)
        if count_unread and not msg.is_self and msg.badged:
            chat.unread += 1

    async def push(self, msg: Message, *, times=1):
        """A message arrives on the server and is pushed over the live connection."""
        self.add_message(msg)
        for _ in range(times):
            self._stream_q.put_nowait(msg)

    def disconnect(self):
        self.connected.clear()
        self._stream_q.put_nowait(ConnectionError('connection dropped'))

    def expire(self):
        self.expired = True
        self._stream_q.put_nowait(AuthExpired('session is not valid'))

    # ---- Source interface ----

    async def restore(self):
        if not self.has_credentials:
            return None
        if self.expired:
            raise AuthExpired('session is not valid')
        return self.me

    async def qr_login_start(self):
        return '{"qrlogin":{"token":"fake"}}'

    async def qr_login_poll(self):
        status = self.qr_script.pop(0) if self.qr_script else 'success'
        if status == 'success':
            self.has_credentials = True
            self.expired = False
        return status

    async def logout(self):
        self.has_credentials = False

    async def list_feed(self, limit):
        items = []
        for chat in sorted(self.chats.values(), key=lambda c: c.rank_time, reverse=True)[:limit]:
            last = self.history.get(chat.id, {}).get(chat.last_position)
            items.append(FeedItem(chat=chat.model_copy(), last_message=last.model_copy() if last else None))
        return items

    async def get_chat(self, chat_id):
        chat = self.chats.get(chat_id)
        return chat.model_copy() if chat else None

    async def pull_history(self, chat_id, positions):
        self.history_calls.append((chat_id, list(positions)))
        msgs = self.history.get(chat_id, {})
        return [msgs[p].model_copy() for p in sorted(positions) if p in msgs]

    async def send_text(self, chat_id, text):
        self.sent.append((chat_id, text))
        self._send_seq += 1
        position = self.chats[chat_id].last_position + 1
        msg = make_msg(chat_id, position, sender_id=ME.id, text=text, msg_id=f'sent-{self._send_seq}')
        self.add_message(msg)
        return msg.model_copy()

    async def mark_read(self, chat_id, max_position):
        self.read_calls.append((chat_id, max_position))
        self.chats[chat_id].unread = 0

    async def user_names(self, user_ids):
        return {uid: self.names[uid] for uid in user_ids if uid in self.names}

    async def stream(self, on_connected, on_message):
        if self.expired:
            raise AuthExpired('session is not valid')
        self.connect_count += 1
        self._stream_q = asyncio.Queue()
        on_connected()
        self.connected.set()
        while True:
            item = await self._stream_q.get()
            if isinstance(item, BaseException):
                raise item
            await on_message(item.model_copy())

    async def keepalive(self):
        if self.expired:
            raise AuthExpired('session is not valid')
