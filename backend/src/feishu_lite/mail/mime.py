"""Bounded MIME foundation for IMAPClient 4.1 BodyData (never fetch RFC822).

normalize_structure accepts the library's parsed BodyData: multipart is
([BodyData children], subtype, params, disposition, ...), singlepart follows
RFC 3501 fields. decode_body accepts only the selected BODY.PEEK[section]
transfer-encoded literal, NOT an entire message or attachment payload.
"""
import base64
import binascii
import quopri
import re
from email import policy
from email.header import decode_header
from email.message import Message
from email.parser import BytesHeaderParser
from email.utils import getaddresses

from .types import (Attachment, BodyPart, BodySelection, MailAddress, MailError,
                    MailHeaders, MailLimits, ParseResult, RawBody)


def decode_text(value: bytes, charset: str | None = None) -> str:
    """Charset decoding boundary; errors become safe domain codes."""
    charset = charset.lower().strip() if charset else None
    if charset in ('gb2312', 'gbk'):
        charset = 'gb18030'
    if charset in (None, 'unknown-8bit'):
        candidate = value.decode('utf-8', errors='surrogateescape')
        if not any(0xDC80 <= ord(char) <= 0xDCFF for char in candidate):
            return candidate
        charset = 'gb18030'
    try:
        return value.decode(charset)
    except LookupError as exc:
        raise MailError('unsupported_charset') from exc
    except UnicodeError as exc:
        raise MailError('malformed_encoding') from exc


def _header_text(value) -> str:
    fragments = decode_header(value)
    return ''.join(decode_text(part, charset) if isinstance(part, bytes) else
                   decode_text(part.encode('utf-8', errors='surrogateescape'))
                   for part, charset in fragments)


def parse_headers(raw: bytes, limits: MailLimits = MailLimits()) -> MailHeaders:
    """Header input boundary. Caller isolates any failure to this message."""
    if len(raw) > limits.max_header_bytes:
        raise MailError('headers_too_large')
    if len(raw) > limits.max_response_bytes:
        raise MailError('response_too_large')
    try:
        message = BytesHeaderParser(policy=policy.compat32).parsebytes(raw)
        if message.defects:
            raise MailError('malformed_mime')
        return MailHeaders(subject=_header_text(message.get('Subject', '')),
                           sender=_addresses(message.get_all('From', [])),
                           to=_addresses(message.get_all('To', [])),
                           cc=_addresses(message.get_all('Cc', [])),
                           date=_header_text(message.get('Date', '')),
                           message_id=_header_text(message.get('Message-ID', '')))
    except (ValueError, UnicodeError, binascii.Error) as exc:
        raise MailError('malformed_mime') from exc


def _addresses(headers) -> list[MailAddress]:
    return [MailAddress(name=name, address=address)
            for name, address in getaddresses([_header_text(h) for h in headers]) if address]


def _atom(value) -> str:
    if not isinstance(value, bytes):
        raise MailError('malformed_mime')
    return decode_text(value)


def _parameters(raw) -> dict[str, str]:
    if raw is None:
        return {}
    if not isinstance(raw, (tuple, list)) or len(raw) % 2:
        raise MailError('malformed_mime')
    return {_atom(raw[i]).lower(): _atom(raw[i + 1]) for i in range(0, len(raw), 2)}


def _filename(params: dict[str, str]) -> str:
    # email handles RFC2231 continuations; avoid get_filename's lossy charset decode.
    message = Message(policy=policy.compat32)
    suffix = ''.join(f'; {name}="{value.replace(chr(34), chr(92) + chr(34))}"'
                     for name, value in params.items() if name.startswith(('filename', 'name')))
    message['Content-Disposition'] = 'attachment' + suffix
    value = message.get_param('filename', header='content-disposition')
    if value is None:
        value = message.get_param('name', header='content-disposition')
    if isinstance(value, tuple):
        return decode_text(value[2].encode('latin1'), value[0])
    return _header_text(value or '')


def _disposition(raw) -> tuple[str | None, dict[str, str]]:
    if raw is None:
        return None, {}
    if not isinstance(raw, (tuple, list)) or len(raw) != 2:
        raise MailError('malformed_mime')
    return _atom(raw[0]).lower(), _parameters(raw[1])


def _check_structure_response(raw, limits: MailLimits):
    # Bound before recursive normalization, including ignored message/rfc822 trees.
    stack = [(raw, 1)]
    size = atoms = 0
    while stack:
        value, depth = stack.pop()
        atoms += 1
        if atoms > limits.max_parts * 64:
            raise MailError('too_many_parts')
        if isinstance(value, (tuple, list)):
            if depth > limits.max_depth * 3 + 3:
                raise MailError('mime_too_deep')
            stack.extend((child, depth + 1) for child in value)
        elif isinstance(value, bytes):
            size += len(value)
        elif value is None or type(value) is int:
            size += 8
        else:
            raise MailError('malformed_mime')
        if size > limits.max_response_bytes:
            raise MailError('response_too_large')


def normalize_structure(raw, limits: MailLimits = MailLimits()) -> BodyPart:
    _check_structure_response(raw, limits)
    count = [0]
    # Parsed BODYSTRUCTURE is an input boundary, including RFC2231 filename decoding.
    try:
        return _normalize(raw, '', 1, count, limits)
    except (ValueError, UnicodeError, binascii.Error) as exc:
        raise MailError('malformed_mime') from exc


def _normalize(raw, section: str, depth: int, count: list[int], limits: MailLimits) -> BodyPart:
    count[0] += 1
    if count[0] > limits.max_parts:
        raise MailError('too_many_parts')
    if depth > limits.max_depth:
        raise MailError('mime_too_deep')
    if not isinstance(raw, tuple) or not raw:
        raise MailError('malformed_mime')
    if isinstance(raw[0], list):
        if len(raw) < 2 or not raw[0]:
            raise MailError('malformed_mime')
        params = _parameters(raw[2] if len(raw) > 2 else None)
        disposition, disposition_params = _disposition(raw[3] if len(raw) > 3 else None)
        children = [_normalize(child, f'{section}.{i}' if section else str(i), depth + 1, count, limits)
                    for i, child in enumerate(raw[0], 1)]
        return BodyPart(section=section, media_type='multipart/' + _atom(raw[1]).lower(),
                        params=params, disposition=disposition,
                        filename=_filename(params | disposition_params), children=children)
    if len(raw) < 7:
        raise MailError('malformed_mime')
    media = _atom(raw[0]).lower() + '/' + _atom(raw[1]).lower()
    if type(raw[6]) is not int or raw[6] < 0:
        raise MailError('malformed_mime')
    # Extension displacement differs for text, message/rfc822 and ordinary singlepart.
    disposition_index = 9 if media.startswith('text/') else 11 if media == 'message/rfc822' else 8
    minimum = 8 if media.startswith('text/') else 10 if media == 'message/rfc822' else 7
    if len(raw) < minimum:
        raise MailError('malformed_mime')
    disposition, disposition_params = _disposition(raw[disposition_index] if len(raw) > disposition_index else None)
    params = _parameters(raw[2])
    return BodyPart(section=section or '1', media_type=media, params=params,
                    content_id=_atom(raw[3]).strip('<>') if raw[3] else None,
                    encoding=_atom(raw[5]).lower(), encoded_size=raw[6], disposition=disposition,
                    filename=_filename(params | disposition_params))


def _body(part: BodyPart) -> BodyPart | None:
    if part.disposition == 'attachment' or part.media_type == 'message/rfc822':
        return None
    if part.media_type in ('text/html', 'text/plain'):
        return part
    if part.media_type == 'multipart/related':
        start = part.params.get('start', '').strip('<>')
        root = next((child for child in part.children if child.content_id == start), None) if start else part.children[0]
        return _body(root) if root else None
    candidates = [_body(child) for child in part.children]
    candidates = [candidate for candidate in candidates if candidate]
    if part.media_type == 'multipart/alternative':
        return next((candidate for candidate in reversed(candidates) if candidate.media_type == 'text/html'),
                    candidates[-1] if candidates else None)
    return candidates[0] if candidates else None


def _attachments(part: BodyPart) -> list[Attachment]:
    if (part.disposition == 'attachment' or part.media_type == 'message/rfc822'
            or not part.media_type.startswith(('text/', 'multipart/'))):
        return [Attachment(section=part.section, filename=part.filename, media_type=part.media_type,
                           encoded_size=None if part.children else part.encoded_size, content_id=part.content_id)]
    return [attachment for child in part.children for attachment in _attachments(child)]


def select_body(part: BodyPart) -> BodySelection:
    return BodySelection(body=_body(part), attachments=_attachments(part))


def decode_body(part: BodyPart, literal: bytes, limits: MailLimits = MailLimits()) -> RawBody:
    """Literal decoding boundary: no STORE, attachment decoding, or implicit read."""
    if part.media_type not in ('text/plain', 'text/html') or part.disposition == 'attachment':
        raise MailError('unsupported_body')
    if len(literal) > limits.max_response_bytes:
        raise MailError('response_too_large')
    if len(literal) > limits.max_body_bytes or part.encoded_size > limits.max_body_bytes:
        raise MailError('body_too_large')
    try:
        decoded = _transfer_decode(part.encoding, literal)
        if len(decoded) > limits.max_body_bytes:
            raise MailError('body_too_large')
        source = decode_text(decoded, part.params.get('charset'))
        if len(source.encode('utf-8')) > limits.max_body_bytes:
            raise MailError('body_too_large')
        return RawBody(kind='html' if part.media_type == 'text/html' else 'plain', source=source)
    except (ValueError, binascii.Error) as exc:
        raise MailError('malformed_mime') from exc


def _transfer_decode(encoding: str, literal: bytes) -> bytes:
    if encoding == 'base64':
        return base64.b64decode(re.sub(rb'[\r\n\t ]', b'', literal), validate=True)
    if encoding == 'quoted-printable':
        if re.search(rb'=(?![0-9a-fA-F]{2}|\r?\n)', literal):
            raise MailError('malformed_mime')
        return quopri.decodestring(literal)
    if encoding in ('7bit', '8bit', 'binary'):
        return literal
    raise MailError('unsupported_transfer_encoding')


def parse_messages(messages: list[tuple[tuple, dict[str, bytes]]], limits: MailLimits = MailLimits()) -> list[ParseResult]:
    """Optional per-message batch boundary for synthetic/full supplied literals.

    The adapter normally normalizes first and fetches just selection.body.section;
    this boundary illustrates how a single malformed mail leaves the batch usable.
    Missing literal means metadata-only, never causes an implicit full-message fetch.
    """
    results = []
    for structure, literals in messages:
        try:
            if sum(len(value) for value in literals.values()) > limits.max_response_bytes:
                raise MailError('response_too_large')
            selection = select_body(normalize_structure(structure, limits))
            part = selection.body
            body = decode_body(part, literals[part.section], limits) if part and part.section in literals else None
            results.append(ParseResult(selection=selection, body=body))
        except MailError as exc:
            results.append(ParseResult(error=exc.code))
    return results
