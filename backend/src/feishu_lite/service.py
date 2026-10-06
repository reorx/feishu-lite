"""Keeps the local cache in step with the Source and fans changes out to SSE subscribers."""

import asyncio
import logging
from io import BytesIO
from typing import TYPE_CHECKING

from PIL import Image

from .store import Store
from .types import AuthExpired, Chat, Message, QrStatus, State, Status, User

if TYPE_CHECKING:
    from .source import Source

log = logging.getLogger(__name__)

PREVIEW_MAX = 120
BACKFILL_MAX = 50


class ChatNotFound(LookupError):
    pass


class Service:
    def __init__(
        self,
        source: 'Source',
        store: Store,
        *,
        backoff=(1, 2, 5, 10, 30),
        feed_limit=100,
        keepalive_interval=4 * 3600,
        resync_interval=300,
        qr_poll_interval=2.0,
    ):
        self.source = source
        self.store = store
        self.backoff = backoff
        self.feed_limit = feed_limit
        self.keepalive_interval = keepalive_interval
        self.resync_interval = resync_interval
        self.qr_poll_interval = qr_poll_interval

        self.state: State = 'logged_out'
        self.user: User | None = None
        self.last_error: str | None = None
        self.qr_status: QrStatus = 'idle'

        self._subscribers: set[asyncio.Queue] = set()
        self._ingest_lock = asyncio.Lock()
        self._session_task: asyncio.Task | None = None
        self._qr_task: asyncio.Task | None = None
        self._tasks: set[asyncio.Task] = set()
        self._reconnect_attempt = 0

    # ---- lifecycle ----

    async def start(self):
        self._start_session()
        self._spawn(self._every(self.keepalive_interval, self._keepalive))
        self._spawn(self._every(self.resync_interval, self.sync_feed))

    async def stop(self):
        tasks = [t for t in (self._session_task, self._qr_task, *self._tasks) if t]
        for task in tasks:
            task.cancel()
        await asyncio.gather(*tasks, return_exceptions=True)

    def status(self) -> Status:
        return Status(state=self.state, user=self.user, last_error=self.last_error)

    # ---- events ----

    def subscribe(self) -> asyncio.Queue:
        queue = asyncio.Queue()
        self._subscribers.add(queue)
        return queue

    def unsubscribe(self, queue: asyncio.Queue):
        self._subscribers.discard(queue)

    def _emit(self, event: str, data: dict):
        for queue in list(self._subscribers):
            queue.put_nowait((event, data))

    def _set_state(self, state: State):
        if state != self.state:
            self.state = state
            self._emit('status', self.status().model_dump())

    def _spawn(self, coro):
        task = asyncio.create_task(coro)
        self._tasks.add(task)
        task.add_done_callback(self._tasks.discard)
        return task

    # ---- session: login restore, push stream, reconnects ----

    def _start_session(self):
        if self._session_task and not self._session_task.done():
            self._session_task.cancel()
        self._reconnect_attempt = 0
        self._session_task = asyncio.create_task(self._session_loop())

    async def _session_loop(self):
        while True:
            try:
                if self.user is None:
                    self._set_state('connecting')
                    user = await self.source.restore()
                    if user is None:
                        self._to_logged_out(None)
                        return
                    self.user = user
                    self.store.save_user_names({user.id: user.name})
                await self.source.stream(self._on_connected, self._on_push)
                raise ConnectionError('push connection closed')
            except AuthExpired as e:
                self._to_logged_out(str(e))
                return
            except Exception as e:
                delay = self.backoff[min(self._reconnect_attempt, len(self.backoff) - 1)]
                self._reconnect_attempt += 1
                log.warning('connection lost (%s: %s), retrying in %ss', type(e).__name__, e, delay)
                self.last_error = f'{type(e).__name__}: {e}'
                self._set_state('reconnecting')
                await asyncio.sleep(delay)

    def _on_connected(self):
        self._reconnect_attempt = 0
        self.last_error = None
        self._set_state('online')
        self._spawn(self.sync_feed())

    def _to_logged_out(self, error: str | None):
        if error:
            log.warning('logged out: %s', error)
        self.user = None
        self.last_error = error
        if self.state == 'logged_out':
            self._emit('status', self.status().model_dump())
        self._set_state('logged_out')
        if self._session_task and self._session_task is not asyncio.current_task():
            self._session_task.cancel()

    def handle_auth_expired(self, error: AuthExpired):
        if self.state != 'logged_out':
            self._to_logged_out(str(error))

    async def _every(self, interval, fn):
        while True:
            await asyncio.sleep(interval)
            if self.state != 'online':
                continue
            try:
                await fn()
            except AuthExpired as e:
                self._to_logged_out(str(e))
            except Exception:
                log.exception('periodic %s failed', fn.__name__)

    async def _keepalive(self):
        await self.source.keepalive()
        log.info('keepalive ok')

    # ---- QR login ----

    async def start_qr_login(self) -> str:
        if self._qr_task:
            self._qr_task.cancel()
        content = await self.source.qr_login_start()
        self.qr_status = 'waiting'
        self._qr_task = asyncio.create_task(self._poll_qr())
        return content

    async def _poll_qr(self):
        try:
            while self.qr_status in ('waiting', 'scanned'):
                await asyncio.sleep(self.qr_poll_interval)
                self.qr_status = await self.source.qr_login_poll()
        except Exception as e:
            log.warning('QR login failed: %s', e)
            self.qr_status = 'failed'
            return
        if self.qr_status == 'success':
            log.info('QR login succeeded')
            self.last_error = None
            self._start_session()

    async def logout(self):
        if self._qr_task:
            self._qr_task.cancel()
        await self.source.logout()
        self.store.clear()
        self.qr_status = 'idle'
        self._to_logged_out(None)

    # ---- feed sync and backfill ----

    async def sync_feed(self):
        items = await self.source.list_feed(self.feed_limit)
        await self._ensure_names(i.last_message.sender_id for i in items if i.last_message)
        for item in items:
            await self._merge_remote_chat(item.chat, item.last_message)
        log.info('feed synced: %d chats', len(items))

    async def _merge_remote_chat(self, remote: Chat, last_message: Message | None):
        local = self.store.get_chat(remote.id)
        if local and remote.last_position > local.last_position and self.store.count_messages(remote.id):
            await self._backfill(remote.id, local.last_position + 1, remote.last_position)
        if last_message:
            self.store.add_message(last_message)
        elif remote.last_position >= 0 and not self.store.messages_between(
            remote.id, remote.last_position, remote.last_position
        ):
            await self._backfill(remote.id, remote.last_position, remote.last_position)

        chat = remote.model_copy()
        if local and not chat.name:
            chat.name = local.name
        latest = self.store.latest_message(chat.id)
        if latest:
            chat.last_message_preview = self._preview(chat, latest)
            chat.last_message_time = latest.create_time
        elif local:
            chat.last_message_preview = local.last_message_preview
        if chat != local:
            self.store.save_chat(chat)
            self._emit('chat.updated', {'chat': chat.model_dump()})

    async def _backfill(self, chat_id: str, low: int, high: int):
        low = max(low, high - BACKFILL_MAX + 1, 0)
        if high < low:
            return
        messages = await self.source.pull_history(chat_id, list(range(low, high + 1)))
        await self._ensure_names(m.sender_id for m in messages)
        for msg in messages:
            self.store.add_message(msg)

    async def _ensure_names(self, user_ids):
        ids = {u for u in user_ids if u}
        missing = ids - self.store.user_names(ids).keys()
        if missing:
            names = await self.source.user_names(sorted(missing))
            if names:
                self.store.save_user_names(names)

    def _preview(self, chat: Chat, msg: Message) -> str:
        text = ' '.join(msg.text.split())
        if chat.type == 'group' and not msg.is_self and msg.sender_name and msg.type != 'system':
            text = f'{msg.sender_name}: {text}'
        return text[:PREVIEW_MAX]

    # ---- live messages ----

    async def _on_push(self, msg: Message):
        try:
            await self._ingest(msg)
        except AuthExpired:
            raise
        except Exception:
            log.exception('failed to handle pushed message %s', msg.id)

    async def _ingest(self, msg: Message) -> Message | None:
        """Store a live message once and announce it. Pushes may repeat and our own sends echo back."""
        async with self._ingest_lock:
            if self.store.has_message(msg.id):
                return None
            chat = self.store.get_chat(msg.chat_id)
            counted_by_server = False
            if chat is None:
                chat = await self.source.get_chat(msg.chat_id) or Chat(id=msg.chat_id)
                counted_by_server = True
            await self._ensure_names([msg.sender_id])
            self.store.add_message(msg)
            stored = self.store.get_message(msg.id)

            is_newer = msg.position > chat.last_position
            if is_newer and not counted_by_server and not msg.is_self and msg.badged:
                chat.unread += 1
            if msg.position >= chat.last_position:
                chat.last_position = msg.position
                chat.last_message_time = msg.create_time
                chat.last_message_preview = self._preview(chat, stored)
            chat.rank_time = max(chat.rank_time, msg.create_time)
            self.store.save_chat(chat)
            self._emit('message.new', {'message': stored.model_dump(), 'chat': chat.model_dump()})
            return stored

    # ---- API operations ----

    def list_chats(self) -> list[Chat]:
        return self.store.list_chats()

    def _require_chat(self, chat_id: str) -> Chat:
        chat = self.store.get_chat(chat_id)
        if chat is None:
            raise ChatNotFound(chat_id)
        return chat

    async def get_messages(self, chat_id: str, before_position: int | None = None, limit: int = 30) -> list[Message]:
        chat = self._require_chat(chat_id)
        high = chat.last_position if before_position is None else before_position - 1
        if high < 0:
            return []
        low = max(0, high - limit + 1)
        cached = self.store.messages_between(chat_id, low, high)
        if len({m.position for m in cached}) < high - low + 1:
            await self._backfill(chat_id, low, high)
            cached = self.store.messages_between(chat_id, low, high)
        return cached

    async def send_text(self, chat_id: str, text: str) -> Message:
        self._require_chat(chat_id)
        sent = await self.source.send_text(chat_id, text)
        await self._ingest(sent)
        return self.store.get_message(sent.id)

    async def get_image(self, message_id: str) -> tuple[bytes, str]:
        if self.user is None:
            raise AuthExpired('not logged in')
        message = self.store.get_message(message_id)
        if message is None or message.type != 'image' or message.text == '[消息已撤回]':
            raise LookupError('image message unavailable')
        data = await self.source.fetch_image(message)
        # The file service may return application/octet-stream, or a login HTML page.
        with Image.open(BytesIO(data)) as image:
            if image.width * image.height > 40_000_000:
                raise ValueError('image dimensions too large')
            media_type = Image.MIME.get(image.format)
            if not media_type or not media_type.startswith('image/'):
                raise ValueError('unsupported image format')
            image.verify()
        return data, media_type

    async def mark_read(self, chat_id: str):
        chat = self._require_chat(chat_id)
        if chat.unread:
            chat.unread = 0
            self.store.save_chat(chat)
            self._emit('chat.updated', {'chat': chat.model_dump()})
        if chat.last_position >= 0:
            await self.source.mark_read(chat_id, chat.last_position)
