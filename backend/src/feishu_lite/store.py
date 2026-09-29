"""SQLite cache of chats, messages and user names."""

import sqlite3
from pathlib import Path

from .types import Chat, Message

SCHEMA = """
CREATE TABLE IF NOT EXISTS chats (
    id TEXT PRIMARY KEY,
    name TEXT NOT NULL DEFAULT '',
    type TEXT NOT NULL DEFAULT 'group',
    unread INTEGER NOT NULL DEFAULT 0,
    muted INTEGER NOT NULL DEFAULT 0,
    last_message_preview TEXT NOT NULL DEFAULT '',
    last_message_time INTEGER NOT NULL DEFAULT 0,
    last_position INTEGER NOT NULL DEFAULT -1,
    rank_time INTEGER NOT NULL DEFAULT 0
);
CREATE TABLE IF NOT EXISTS messages (
    id TEXT PRIMARY KEY,
    chat_id TEXT NOT NULL,
    position INTEGER NOT NULL,
    sender_id TEXT NOT NULL,
    is_self INTEGER NOT NULL,
    create_time INTEGER NOT NULL,
    type TEXT NOT NULL,
    text TEXT NOT NULL,
    badged INTEGER NOT NULL DEFAULT 1,
    at_me INTEGER NOT NULL DEFAULT 0
);
CREATE INDEX IF NOT EXISTS messages_chat_position ON messages (chat_id, position);
CREATE TABLE IF NOT EXISTS users (
    id TEXT PRIMARY KEY,
    name TEXT NOT NULL
);
"""

CHAT_FIELDS = list(Chat.model_fields)
MESSAGE_COLUMNS = [
    'id',
    'chat_id',
    'position',
    'sender_id',
    'is_self',
    'create_time',
    'type',
    'text',
    'badged',
    'at_me',
]
MESSAGE_SELECT = f"SELECT {', '.join('m.' + c for c in MESSAGE_COLUMNS)}, COALESCE(u.name, '') AS sender_name FROM messages m LEFT JOIN users u ON u.id = m.sender_id"


class Store:
    def __init__(self, path: Path):
        self.db = sqlite3.connect(str(path), check_same_thread=False)
        self.db.row_factory = sqlite3.Row
        self.db.executescript(SCHEMA)

    def get_chat(self, chat_id: str) -> Chat | None:
        row = self.db.execute('SELECT * FROM chats WHERE id = ?', (chat_id,)).fetchone()
        return Chat(**dict(row)) if row else None

    def list_chats(self, limit: int = 500) -> list[Chat]:
        rows = self.db.execute('SELECT * FROM chats ORDER BY rank_time DESC, id LIMIT ?', (limit,)).fetchall()
        return [Chat(**dict(r)) for r in rows]

    def save_chat(self, chat: Chat):
        data = chat.model_dump()
        cols = ', '.join(CHAT_FIELDS)
        marks = ', '.join('?' for _ in CHAT_FIELDS)
        self.db.execute(f'INSERT OR REPLACE INTO chats ({cols}) VALUES ({marks})', [data[f] for f in CHAT_FIELDS])
        self.db.commit()

    def has_message(self, message_id: str) -> bool:
        return self.db.execute('SELECT 1 FROM messages WHERE id = ?', (message_id,)).fetchone() is not None

    def add_message(self, msg: Message) -> bool:
        """Insert unless a message with the same id exists. Returns whether it was new."""
        data = msg.model_dump()
        cur = self.db.execute(
            f'INSERT OR IGNORE INTO messages ({", ".join(MESSAGE_COLUMNS)}) VALUES ({", ".join("?" for _ in MESSAGE_COLUMNS)})',
            [data[c] for c in MESSAGE_COLUMNS],
        )
        self.db.commit()
        return cur.rowcount == 1

    def get_message(self, message_id: str) -> Message | None:
        row = self.db.execute(f'{MESSAGE_SELECT} WHERE m.id = ?', (message_id,)).fetchone()
        return Message(**dict(row)) if row else None

    def messages_between(self, chat_id: str, low: int, high: int) -> list[Message]:
        rows = self.db.execute(
            f'{MESSAGE_SELECT} WHERE m.chat_id = ? AND m.position BETWEEN ? AND ? ORDER BY m.position, m.create_time',
            (chat_id, low, high),
        ).fetchall()
        return [Message(**dict(r)) for r in rows]

    def count_messages(self, chat_id: str) -> int:
        return self.db.execute('SELECT COUNT(*) FROM messages WHERE chat_id = ?', (chat_id,)).fetchone()[0]

    def latest_message(self, chat_id: str) -> Message | None:
        row = self.db.execute(
            f'{MESSAGE_SELECT} WHERE m.chat_id = ? ORDER BY m.position DESC LIMIT 1', (chat_id,)
        ).fetchone()
        return Message(**dict(row)) if row else None

    def user_names(self, user_ids) -> dict[str, str]:
        ids = list(set(user_ids))
        if not ids:
            return {}
        rows = self.db.execute(
            f'SELECT id, name FROM users WHERE id IN ({", ".join("?" for _ in ids)})', ids
        ).fetchall()
        return {r['id']: r['name'] for r in rows}

    def save_user_names(self, names: dict[str, str]):
        self.db.executemany('INSERT OR REPLACE INTO users (id, name) VALUES (?, ?)', list(names.items()))
        self.db.commit()

    def clear(self):
        self.db.executescript('DELETE FROM chats; DELETE FROM messages; DELETE FROM users;')
