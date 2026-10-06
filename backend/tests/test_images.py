"""Image viewing: old cached messages, protected downloads and unavailable resources."""

from io import BytesIO
from unittest.mock import AsyncMock, Mock

import pytest
from larkx.proto import proto_pb2 as P
from PIL import Image

from feishu_lite.source import LarkxSource
from feishu_lite.types import AuthExpired
from .fakes import make_chat, make_msg


def png_bytes():
    buffer = BytesIO()
    Image.new('RGB', (8, 6), 'blue').save(buffer, format='PNG')
    return buffer.getvalue()


def image_message():
    return make_msg('test-chat', 0).model_copy(update={'type': 'image', 'text': '[图片]'})


@pytest.mark.asyncio
async def test_old_cached_image_can_be_downloaded_without_marking_read(source, make_backend):
    message = image_message()
    source.add_chat(make_chat(message.chat_id), [message])
    source.fetch_image = AsyncMock(return_value=png_bytes())
    backend = await make_backend(source)
    await backend.service.sync_feed()
    response = await backend.client.get(f'/messages/{message.id}/image')
    assert response.status_code == 200
    assert response.headers['content-type'] == 'image/png'
    assert response.headers['cache-control'] == 'no-store'
    assert response.content == png_bytes()
    source.fetch_image.assert_awaited_once_with(message.model_copy(update={'sender_name': 'Alice'}))
    assert source.read_calls == []


@pytest.mark.asyncio
async def test_image_route_requires_token_and_known_image_message(backend):
    backend.source.fetch_image = AsyncMock()
    response = await backend.client.get('/messages/unknown/image', headers={'Authorization': ''})
    assert response.status_code == 401
    assert (await backend.client.get('/messages/unknown/image')).status_code == 404
    for message in [make_msg('c', 0), image_message().model_copy(update={'text': '[消息已撤回]'})]:
        backend.service.store.add_message(message)
        assert (await backend.client.get(f'/messages/{message.id}/image')).status_code == 404
    backend.source.fetch_image.assert_not_awaited()


@pytest.mark.asyncio
@pytest.mark.parametrize('failure,status', [(LookupError(), 404), (ConnectionError(), 502), (AuthExpired(), 409)])
async def test_image_download_failure_is_retryable_or_reports_expired_login(backend, failure, status):
    message = image_message()
    backend.service.store.add_message(message)
    backend.source.fetch_image = AsyncMock(side_effect=failure)
    response = await backend.client.get(f'/messages/{message.id}/image')
    assert response.status_code == status
    if status == 409:
        assert backend.service.state == 'logged_out'


@pytest.mark.asyncio
async def test_non_image_download_is_rejected(backend):
    message = image_message()
    backend.service.store.add_message(message)
    backend.source.fetch_image = AsyncMock(return_value=b'<html>login required</html>')
    assert (await backend.client.get(f'/messages/{message.id}/image')).status_code == 502


@pytest.mark.asyncio
@pytest.mark.parametrize('variant', ['origin', 'imageKey', 'v2'])
async def test_protocol_download_resolves_image_keys(monkeypatch, variant):
    content = P.ImageContent()
    if variant == 'v2':
        content.imageV2.imageKey = 'fixture-key'
    elif variant == 'origin':
        content.image.origin.key = 'fixture-key'
    else:
        content.image.imageKey = 'fixture-key'
    source = LarkxSource()
    source.auth = Mock()
    source.client = Mock()
    message = image_message()
    raw = {'id': message.id, 'chatId': message.chat_id, 'type': 5, 'content': content.SerializeToString()}
    source.client.api.return_value = {'messages': {message.id: raw}}
    download = Mock(return_value=(png_bytes(), 'application/octet-stream'))
    monkeypatch.setattr('larkx.media.download', download)
    assert await source.fetch_image(message) == png_bytes()
    assert download.call_args.args[1].endswith(f'/messages/{message.id}/keys/fixture-key?chat_id=test-chat')
    assert download.call_args.kwargs['max_bytes'] <= 25 * 1024 * 1024


@pytest.mark.asyncio
@pytest.mark.parametrize('raw', [None, {'type': 4}, {'type': 5, 'isRemoved': True}, {'type': 5, 'status': 2}, {'type': 5, 'content': b''}])
async def test_missing_or_revoked_image_never_downloads(monkeypatch, raw):
    source = LarkxSource()
    source.client = Mock()
    message = image_message()
    source.client.api.return_value = {'messages': {message.id: raw} if raw else {}}
    download = Mock()
    monkeypatch.setattr('larkx.media.download', download)
    with pytest.raises(LookupError):
        await source.fetch_image(message)
    download.assert_not_called()


@pytest.mark.asyncio
async def test_retry_succeeds_after_temporary_download_failure(backend):
    message = image_message()
    backend.service.store.add_message(message)
    backend.source.fetch_image = AsyncMock(side_effect=[ConnectionError(), png_bytes()])
    path = f'/messages/{message.id}/image'
    assert (await backend.client.get(path)).status_code == 502
    response = await backend.client.get(path)
    assert response.status_code == 200
    assert response.content == png_bytes()


@pytest.mark.asyncio
async def test_pushed_image_is_immediately_available(backend):
    backend.source.add_chat(make_chat('test-chat'))
    await backend.service.sync_feed()
    backend.source.fetch_image = AsyncMock(return_value=png_bytes())
    message = image_message()
    async with backend.events() as events:
        await backend.source.push(message)
        _, payload = await events.wait_for(lambda name, data: name == 'message.new')
        assert payload['message']['type'] == 'image'
        assert payload['message']['text'] == '[图片]'
        assert (await backend.client.get(f'/messages/{message.id}/image')).status_code == 200
