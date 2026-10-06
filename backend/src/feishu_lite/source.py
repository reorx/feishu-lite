"""Protocol layer: larkx (reverse-engineered Feishu web protocol) behind the Source interface.

larkx reads LARKX_HOME at import time, so main.py sets it before importing this module.
Everything else in the backend only talks to the `Source` protocol, so a broken larkx can be
swapped out here without touching the store, service or API.
"""

import asyncio
import logging
import time
from collections.abc import Awaitable, Callable
from typing import Protocol

import requests
import websockets
from larkx import media
from google.protobuf.message import DecodeError
from larkx.auth import CSRF_URL, QR_POLLING_URL, LarkAuth, QrLogin
from larkx.auth import AuthExpired as LarkxAuthExpired
from larkx.client import LarkClient
from larkx.config import CREDENTIALS_PATH
from larkx.proto import builders, decoders, gateway
from larkx.proto import proto_pb2 as P
from larkx.proto.ids import generate_long_request_id
from protobuf_to_dict import protobuf_to_dict

from . import render
from .types import AuthExpired, Chat, FeedItem, Message, QrStatus, User

log = logging.getLogger(__name__)

UA = 'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/150.0.0.0 Safari/537.36'
FEED_PAGE = 50
QR_STATUS = {1: 'waiting', 2: 'scanned', 3: 'failed', 4: 'failed', 5: 'expired'}
MESSAGE_DELETED = 2


class Source(Protocol):
    async def restore(self) -> User | None:
        """Load saved credentials. None if there are none; AuthExpired if the server rejects them."""

    async def qr_login_start(self) -> str: ...

    async def qr_login_poll(self) -> QrStatus:
        """Advance the QR login by one poll; on success credentials are saved."""

    async def logout(self) -> None: ...

    async def list_feed(self, limit: int) -> list[FeedItem]: ...

    async def get_chat(self, chat_id: str) -> Chat | None: ...

    async def pull_history(self, chat_id: str, positions: list[int]) -> list[Message]: ...

    async def send_text(self, chat_id: str, text: str) -> Message: ...

    async def fetch_image(self, message: Message) -> bytes: ...

    async def mark_read(self, chat_id: str, max_position: int) -> None: ...

    async def user_names(self, user_ids: list[str]) -> dict[str, str]: ...

    async def stream(self, on_connected: Callable[[], None], on_message: Callable[[Message], Awaitable[None]]) -> None:
        """Hold the push connection open; returns or raises when it drops."""

    async def keepalive(self) -> None: ...


class _Client(LarkClient):
    """LarkClient minus its constructor's credential check, which reports "offline" as AuthExpired."""

    def __init__(self, auth: LarkAuth):
        self.auth = auth
        self.loop = None
        self._loop_started = False


class LarkxSource:
    def __init__(self):
        self.auth: LarkAuth | None = None
        self.client: _Client | None = None
        self.me: User | None = None
        self._qr: QrLogin | None = None

    async def _call(self, fn, *args):
        """Run a blocking larkx call in a thread, translating credential failures into AuthExpired."""
        try:
            return await asyncio.to_thread(fn, *args)
        except LarkxAuthExpired as e:
            raise AuthExpired(str(e)) from e
        except requests.HTTPError as e:
            if e.response is not None and e.response.status_code == 401:
                raise AuthExpired('gateway rejected the session (HTTP 401)') from e
            raise

    # ---- login ----

    async def restore(self):
        auth = LarkAuth()
        if not CREDENTIALS_PATH.exists() or not auth.cookies:
            return None
        await self._call(auth.get_ticket)
        if not auth.app_key or not auth.user_id:
            await self._call(auth._fetch_profile)
            await self._call(auth.save)
        self.auth = auth
        self.client = _Client(auth)
        self.me = User(id=str(auth.user_id))
        names = await self.user_names([self.me.id])
        self.me.name = names.get(self.me.id, '')
        return self.me

    async def qr_login_start(self):
        self._qr = await self._call(QrLogin)
        return self._qr.qr_content

    async def qr_login_poll(self):
        return await self._call(self._qr_poll_once)

    def _qr_poll_once(self) -> QrStatus:
        qr = self._qr
        data = qr.session.post(QR_POLLING_URL, json={}, timeout=15).json().get('data') or {}
        if not data:
            return 'failed'
        step = data.get('next_step')
        status = (data.get('step_info') or {}).get('status')
        if step != 'qr_login_polling' or qr.session.cookies.get('session') or status == 0:
            qr.finish(LarkAuth())
            self._qr = None
            return 'success'
        return QR_STATUS.get(status, 'waiting')

    async def logout(self):
        CREDENTIALS_PATH.unlink(missing_ok=True)
        self.auth = self.client = self.me = None

    async def keepalive(self):
        await self._call(self._keepalive)

    def _keepalive(self):
        # QR sessions carry an opaque `session` cookie the csrf call does not rotate; we still merge
        # whatever it sets and then probe the ticket endpoint, which fails once the session is gone.
        resp = requests.post(
            CSRF_URL,
            params={'_t': int(time.time() * 1000)},
            cookies=self.auth.cookies,
            headers={'user-agent': UA},
            timeout=10,
        )
        resp.raise_for_status()
        for cookie in resp.cookies:
            self.auth.cookies[cookie.name] = cookie.value
        self.auth.csrf_token = self.auth.cookies.get('swp_csrf_token', self.auth.csrf_token)
        self.auth.get_ticket()
        self.auth.save()

    # ---- chats and messages ----

    async def list_feed(self, limit):
        return await self._call(self._list_feed, limit)

    def _list_feed(self, limit) -> list[FeedItem]:
        cards, chats, messages = {}, {}, {}
        req = {'type': 1, 'pullType': 1, 'count': FEED_PAGE, 'withMessageEntity': True}
        while True:
            resp = self.client.api('feed.PullFeedCardsRequest', req)
            page = resp.get('cards') or []
            for card in page:
                cards.setdefault(card.get('id'), card)
            chats.update(resp.get('chats') or {})
            messages.update(resp.get('messages') or {})
            chat_cards = [c for c in cards.values() if c.get('type') == 1 and c.get('id') in chats]
            cursor = resp.get('nextCursor')
            if len(chat_cards) >= limit or not page or not cursor:
                break
            req = {'type': 1, 'pullType': 2, 'cursor': cursor, 'count': FEED_PAGE, 'withMessageEntity': True}
        chat_cards = sorted(chat_cards, key=lambda c: c.get('rankTime', 0), reverse=True)[:limit]
        names = self._user_names_sync(
            [self._partner_id(chats[c['id']]) for c in chat_cards if chats[c['id']].get('type') == 1]
        )
        items = []
        for card in chat_cards:
            raw = chats[card['id']]
            last = messages.get(raw.get('lastMessageId') or '')
            items.append(
                FeedItem(
                    chat=self._to_chat(raw, names, card.get('rankTime')),
                    last_message=self._to_message(last) if last else None,
                )
            )
        return items

    async def get_chat(self, chat_id):
        return await self._call(self._get_chat, chat_id)

    def _get_chat(self, chat_id) -> Chat | None:
        resp = self.client.api('chats.PullChatsByIdsRequest', {'chatIds': [chat_id]})
        raw = (resp.get('chats') or {}).get(chat_id)
        if not raw:
            return None
        names = self._user_names_sync([self._partner_id(raw)]) if raw.get('type') == 1 else {}
        return self._to_chat(raw, names)

    async def pull_history(self, chat_id, positions):
        resp = await self._call(
            self.client.api,
            'messages.PullMessagesByPositionsRequest',
            {'chatId': chat_id, 'positions': list(positions)},
        )
        msgs = [self._to_message(m) for m in (resp.get('messages') or {}).values()]
        return sorted(msgs, key=lambda m: m.position)

    async def send_text(self, chat_id, text):
        return await self._call(self._send_text, chat_id, text)

    async def fetch_image(self, message: Message) -> bytes:
        return await self._call(self._fetch_image, message)

    def _fetch_image(self, message: Message) -> bytes:
        # Resolve again so old text-only caches work and revoked resources aren't displayed.
        response = self.client.api(
            'messages.PullMessagesByPositionsRequest',
            {'chatId': message.chat_id, 'positions': [message.position]},
        )
        raw = (response.get('messages') or {}).get(message.id)
        if not raw or decoders.enum_to_int(raw.get('type', 0)) != 5:
            raise LookupError('image message unavailable')
        if raw.get('isRemoved') or raw.get('status') == MESSAGE_DELETED:
            raise LookupError('image message revoked')
        content = P.ImageContent()
        content.ParseFromString(raw.get('content') or b'')
        key = media.extract_resource_key(5, protobuf_to_dict(content))
        if not key:
            raise LookupError('image resource unavailable')
        url = media.message_resource_url(message.id, key, message.chat_id)
        data, _ = media.download(self.auth, url, max_bytes=25 * 1024 * 1024)
        return data

    def _send_text(self, chat_id, text) -> Message:
        packet = builders.build_send_message_packet(text, chat_id, generate_long_request_id())
        resp_packet = P.Packet()
        resp_packet.ParseFromString(self.client._gateway_post(packet))
        if not resp_packet.payload:
            raise RuntimeError(f'send failed: gateway status {resp_packet.status}')
        resp = gateway.response_to_dict(gateway.resolve_type('messages.PutMessageResponse'), resp_packet.payload)
        return self._to_message(resp['message'])

    async def mark_read(self, chat_id, max_position):
        await self._call(
            self.client.api, 'messages.PutReadMessagesRequest', {'chatId': chat_id, 'maxPosition': max_position}
        )

    async def user_names(self, user_ids):
        return await self._call(self._user_names_sync, user_ids)

    def _user_names_sync(self, user_ids) -> dict[str, str]:
        ids = sorted({u for u in user_ids if u})
        if not ids:
            return {}
        chatters = self.client.api('chatters.PullChattersByIdsRequest', {'chatterIds': ids}).get('chatters') or {}
        return {uid: c.get('alias') or c.get('name') or '' for uid, c in chatters.items()}

    # ---- push ----

    async def stream(self, on_connected, on_message):
        self.auth.load()  # pick up credential edits made on disk since the last connect
        url = await self._call(self.client.build_ws_url)
        async with websockets.connect(url, max_size=None, open_timeout=15) as ws:
            log.info('push connection open')
            on_connected()
            heartbeat = asyncio.create_task(self.client.heartbeat_loop(ws))
            try:
                async for raw in ws:
                    try:
                        messages = await self._read_frame(ws, raw)
                    except DecodeError:
                        log.debug('skipping undecodable frame')
                        continue
                    for msg in messages:
                        await on_message(msg)
            finally:
                heartbeat.cancel()

    async def _read_frame(self, ws, raw: bytes) -> list[Message]:
        frame = P.Frame()
        frame.ParseFromString(raw)
        packet = P.Packet()
        packet.ParseFromString(frame.payload)
        if packet.sid:
            await self.client.send_ack(ws, packet.sid)
        if packet.cmd != 6 or not packet.payload:
            return []
        push = P.PushMessagesRequest()
        push.ParseFromString(packet.payload)
        at_me = {k for k, v in push.messagesAtMe.items() if v}
        out = []
        for key, entity in push.messages.items():
            data = protobuf_to_dict(entity)
            if data.get('fromId'):
                out.append(self._to_message(data, at_me=key in at_me or data.get('id') in at_me))
        return out

    # ---- conversions ----

    def _partner_id(self, raw_chat: dict) -> str:
        ids = [x for x in (raw_chat.get('key') or '').split(':') if x and x != self.me.id]
        return ids[0] if ids else self.me.id

    def _to_chat(self, raw: dict, names: dict[str, str], rank_time=None) -> Chat:
        is_p2p = raw.get('type') == 1
        if is_p2p:
            name = names.get(self._partner_id(raw), '')
        else:
            # `name` can be the English one (e.g. the Feishu Assistant group); the official client shows zh_cn
            name = ((raw.get('i18nInf') or {}).get('i18nNames') or {}).get('zh_cn', '')
        return Chat(
            id=str(raw['id']),
            name=name or raw.get('name') or '',
            type='p2p' if is_p2p else 'group',
            unread=raw.get('newMessageCount') or 0,
            muted=not raw.get('isRemind', True),
            last_position=raw.get('lastMessagePosition', -1),
            last_message_time=raw.get('updateTime') or 0,
            rank_time=rank_time or raw.get('updateTime') or 0,
        )

    def _to_message(self, data: dict, at_me=False) -> Message:
        msg_type = decoders.enum_to_int(data.get('type', 0))
        try:
            text = render.render_content(msg_type, data.get('content') or b'')
        except DecodeError:
            log.warning('could not decode content of message %s (type %s)', data.get('id'), msg_type)
            text = render.PLACEHOLDERS.get(msg_type, '[消息]')
        if data.get('isRemoved') or data.get('status') == MESSAGE_DELETED:
            text = '[消息已撤回]'
        sender_id = str(data.get('fromId') or '')
        return Message(
            id=str(data['id']),
            chat_id=str(data.get('chatId') or data.get('channelId') or ''),
            position=int(data.get('position') or 0),
            sender_id=sender_id,
            is_self=self.me is not None and sender_id == self.me.id,
            create_time=int(data.get('createTime') or 0),
            type=render.type_name(msg_type),
            text=text,
            badged=bool(data.get('isBadged', True)),
            at_me=at_me,
        )
