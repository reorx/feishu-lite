"""Shared mail contracts; identifiers are versioned, canonical and URL-path safe."""
import base64
import binascii
import json
import re
from typing import Annotated, Generic, Literal, TypeVar

from pydantic import BaseModel, ConfigDict, Field, SecretStr, ValidationError, computed_field

UID = Annotated[int, Field(strict=True, ge=1, le=4294967295)]
UIDNext = Annotated[int, Field(strict=True, ge=1, le=4294967296)]
Identifier = Annotated[str, Field(strict=True, min_length=1, max_length=512, pattern=r'^[^\x00-\x1f\x7f]+$')]


class MailError(Exception):
    """Safe domain error: code only, never a header, credential or response."""
    def __init__(self, code: str):
        self.code = code
        super().__init__(code)


class MailAuthenticationError(MailError):
    """Mail credential failure; independent of chat AuthExpired."""
    def __init__(self):
        super().__init__('authentication_failed')


class MailModel(BaseModel):
    model_config = ConfigDict(extra='forbid', frozen=True)


def _encode(kind: str, key: 'MailKey') -> str:
    data = [1, kind, key.account_id, key.folder_id, key.uidvalidity, key.uid]
    return base64.urlsafe_b64encode(json.dumps(data, ensure_ascii=False, separators=(',', ':')).encode()).decode().rstrip('=')


def decode_key_id(value: str, kind: Literal['message', 'cursor']) -> 'MailKey':
    # Identifier decoding is an input boundary, so normalize only specific parser errors.
    if not isinstance(value, str) or len(value) > 8192 or not re.fullmatch(r'[A-Za-z0-9_-]+', value):
        raise MailError('invalid_id')
    try:
        raw = base64.b64decode(value + '=' * (-len(value) % 4), altchars=b'-_', validate=True)
        data = json.loads(raw.decode('utf-8'))
        if not isinstance(data, list) or len(data) != 6 or type(data[0]) is not int or data[:2] != [1, kind]:
            raise MailError('invalid_id')
        key = MailKey(account_id=data[2], folder_id=data[3], uidvalidity=data[4], uid=data[5])
        if _encode(kind, key) != value:
            raise MailError('invalid_id')
        return key
    except (ValueError, UnicodeError, binascii.Error, ValidationError) as exc:
        raise MailError('invalid_id') from exc


class MailKey(MailModel):
    account_id: Identifier
    folder_id: Identifier
    uidvalidity: UID
    uid: UID

    @property
    def id(self) -> str:
        return _encode('message', self)

    @classmethod
    def from_id(cls, value: str) -> 'MailKey':
        return decode_key_id(value, 'message')


class MailCursor(MailModel):
    key: MailKey

    @property
    def id(self) -> str:
        return _encode('cursor', self.key)

    @classmethod
    def from_id(cls, value: str) -> 'MailCursor':
        return cls(key=decode_key_id(value, 'cursor'))


class MailAccount(MailModel):
    id: Identifier
    address: str


class MailFolder(MailModel):
    id: Identifier  # exact decoded server identifier, not localized display name
    name: str
    delimiter: str | None = None
    flags: list[str] = Field(default_factory=list)
    selectable: bool = True
    supported: bool = False


class MailAddress(MailModel):
    name: str = ''
    address: str


class MailHeaders(MailModel):
    subject: str = ''
    sender: list[MailAddress] = Field(default_factory=list)
    to: list[MailAddress] = Field(default_factory=list)
    cc: list[MailAddress] = Field(default_factory=list)
    date: str = ''  # display header only; UID orders pages, INTERNALDATE supplies received_at
    message_id: str = ''  # never used as identity


class Attachment(MailModel):
    section: str
    filename: str = ''
    media_type: str
    encoded_size: int | None = Field(default=None, ge=0)
    size_is_approximate: bool = True
    content_id: str | None = None


class BodyPart(MailModel):
    section: str
    media_type: str
    params: dict[str, str] = Field(default_factory=dict)
    content_id: str | None = None
    encoding: str = '7bit'
    encoded_size: int = Field(default=0, ge=0)
    disposition: str | None = None
    filename: str = ''
    children: list['BodyPart'] = Field(default_factory=list)


class BodySelection(MailModel):
    body: BodyPart | None = None
    attachments: list[Attachment] = Field(default_factory=list)


class MailSummary(MailHeaders):
    key: MailKey
    received_at: int  # unix seconds, from INTERNALDATE
    size: int = Field(default=0, ge=0)
    flags: list[str] = Field(default_factory=list)
    unread: bool = True
    attachments: list[Attachment] = Field(default_factory=list)
    body_part: BodyPart | None = None
    error: str | None = None  # safe per-message error code; a bad row can still appear

    @computed_field
    @property
    def id(self) -> str:
        """Read-only wire id; clients need not reproduce canonical encoding."""
        return self.key.id


class RawBody(MailModel):
    kind: Literal['html', 'plain']
    source: str  # decoded source; internal cache, never a final display field


class MailBody(MailModel):
    kind: Literal['html', 'plain']
    content: str  # HTML is sanitized at read time; plain is text, not markup


class MailPage(MailModel):
    items: list[MailSummary]
    next_cursor: str | None = None


class SyncState(MailModel):
    account_id: str
    folder_id: str
    uidvalidity: UID
    sync_next: UIDNext
    notify_next: UIDNext
    unread_count: int
    checked_at: int | None = None


class PendingBatch(MailModel):
    id: str
    account_id: str
    folder_id: str
    uidvalidity: UID
    notify_next: UIDNext
    keys: list[MailKey]


class MailLimits(MailModel):
    max_response_bytes: int = Field(default=8 * 1024 * 1024, gt=0)
    max_header_bytes: int = Field(default=256 * 1024, gt=0)
    max_body_bytes: int = Field(default=2 * 1024 * 1024, gt=0)
    max_depth: int = Field(default=20, gt=0)
    max_parts: int = Field(default=200, gt=0)


class ParseResult(MailModel):
    selection: BodySelection | None = None
    body: RawBody | None = None
    error: str | None = None


class ImapConfig(MailModel):
    # Never serialize this internal configuration into a status/API payload.
    account_id: Identifier
    generation: int = Field(ge=1)
    host: str = 'imap.feishu.cn'
    port: int = Field(default=993, ge=1, le=65535)
    username: SecretStr = Field(repr=False, exclude=True)
    password: SecretStr = Field(repr=False, exclude=True)


class ImapIdentity(MailModel):
    account_id: str
    generation: int
    connection_id: str


ResultValue = TypeVar('ResultValue')


class ImapResult(MailModel, Generic[ResultValue]):
    identity: ImapIdentity
    value: ResultValue


class SelectedMailbox(MailModel):
    folder_id: str = 'INBOX'
    uidvalidity: UID
    uidnext: UIDNext
    flags: list[str]
    permanent_flags: list[str]
    readonly: bool


class FetchedBody(MailModel):
    raw: RawBody
    body: MailBody


class MailNotification(MailModel):
    id: str
    account_id: str
    folder_id: str = 'INBOX'
    uidvalidity: UID
    mode: Literal['individual', 'summary']
    items: list[MailSummary]


class MailStatus(MailModel):
    mail_account_id: str | None = None
    address: str | None = None
    state: Literal['unconfigured', 'credential_missing', 'connecting', 'online', 'offline', 'auth_failed']
    generation: int = 0
    uidvalidity: UID | None = None
    last_sync_at: int | None = None
    unread_count: int = 0
    unread_stale: bool = True
    pending: list[MailNotification] = Field(default_factory=list)
    error: str | None = None


class MailEvent(MailModel):
    type: Literal['mail.status', 'mail.updated', 'mail.arrived']
    account_id: str | None
    generation: int
    folder_id: str = 'INBOX'
    uidvalidity: UID | None = None
    status: MailStatus | None = None
    notification: MailNotification | None = None
    read_ids: list[str] = Field(default_factory=list)
    deleted_ids: list[str] = Field(default_factory=list)
    reset: bool = False


class MailAccountChange(MailModel):
    account: MailAccount | None = None
    removed_account_id: str | None = None


class MailConnectionTest(MailModel):
    writable: bool
    supports_idle: bool


class MailAccountRequest(MailModel):
    address: str = Field(strict=True, min_length=3, max_length=512, pattern=r'^[^\s@]+@[^\s@]+$')
    password: SecretStr = Field(strict=True, min_length=1, max_length=4096, repr=False)


class MailCredentialRequest(MailModel):
    mail_account_id: Identifier
    password: SecretStr = Field(strict=True, min_length=1, max_length=4096, repr=False)


class MailAckRequest(MailModel):
    mail_account_id: Identifier
    uidvalidity: UID
    batch_id: Identifier


class MailReadResult(MailModel):
    read_ids: list[str]


class MailAPIError(MailModel):
    domain: Literal['mail'] = 'mail'
    code: str
