"""Models shared across the backend. Kept free of larkx imports so tests and the service can use them directly."""

from typing import Literal

from pydantic import BaseModel

ChatType = Literal['p2p', 'group']
State = Literal['logged_out', 'connecting', 'online', 'reconnecting']
QrStatus = Literal['idle', 'waiting', 'scanned', 'success', 'expired', 'failed']


class AuthExpired(Exception):
    """Credentials were rejected by the server (not a network problem)."""


class User(BaseModel):
    id: str
    name: str = ''


class Chat(BaseModel):
    id: str
    name: str = ''
    type: ChatType = 'group'
    unread: int = 0
    muted: bool = False
    last_message_preview: str = ''
    last_message_time: int = 0  # unix seconds
    last_position: int = -1
    rank_time: int = 0  # sort key, newest first; mirrors the server's feed ranking


class Message(BaseModel):
    id: str
    chat_id: str
    position: int
    sender_id: str
    sender_name: str = ''
    is_self: bool = False
    create_time: int  # unix seconds
    type: str  # text / post / image / file / card / system / ...
    text: str
    badged: bool = True  # counts towards unread (system messages don't)
    at_me: bool = False


class FeedItem(BaseModel):
    chat: Chat
    last_message: Message | None = None


class Status(BaseModel):
    state: State
    user: User | None = None
    last_error: str | None = None
