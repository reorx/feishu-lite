"""Mock datasets exercise real services; showcase content is deliberately not pinned."""
import asyncio
import json
from datetime import datetime
from pathlib import Path

import pytest
from feishu_lite.mock import Dataset, MockSource, create_mock_app


def fixture(root):
    root.mkdir(exist_ok=True)
    chat = {'me': {'id': 'me', 'name': 'Test'}, 'users': [{'id': 'a', 'name': 'Alice'}],
            'chats': [{'id': 'c', 'name': 'Room', 'unread': 2, 'messages': [
                {'id': 'm', 'sender_id': 'a', 'time': {'day': -1, 'time': '09:30'}, 'text': 'hello'},
                {'id': 'v', 'sender_id': 'me', 'time': 1700000000, 'type': 'video_chat',
                 'meeting': {'topic': 'Review', 'number': '123456789'}}]}]}
    mail = {'address': 'me@example.com', 'folders': [{'id': 'INBOX', 'name': 'Inbox', 'supported': True}],
            'messages': [{'uid': i, 'subject': f'Mail {i}', 'time': {'day': 0, 'time': '10:00'},
                          'body': {'kind': 'html', 'source': '<b>hello</b><script>bad()</script>'}}
                         for i in range(1, 103)]}
    (root / 'messages.json').write_text(json.dumps(chat))
    (root / 'emails.json').write_text(json.dumps(mail))
    return root


def test_relative_time_and_validation(tmp_path):
    data = Dataset.load(fixture(tmp_path), now=datetime(2026, 10, 21, 18))
    assert data.chat.chats[0].messages[0].time.resolve(data.now) == int(datetime(2026, 10, 20, 9, 30).timestamp())
    (tmp_path / 'messages.json').write_text('{"chats": [{}]}')
    with pytest.raises(ValueError, match='messages.json'):
        Dataset.load(tmp_path)
    with pytest.raises(ValueError, match='directory'):
        Dataset.load(tmp_path / 'missing')


@pytest.mark.asyncio
async def test_source_methods_reset_and_no_stream_arrivals(tmp_path):
    root = fixture(tmp_path)
    before = (root / 'messages.json').read_bytes()
    source = MockSource(Dataset.load(root))
    assert (await source.restore()).id == 'me'
    assert (await source.user_names(['a'])) == {'a': 'Alice'}
    assert len(await source.list_feed(1)) == 1
    messages = await source.pull_history('c', [0, 1])
    assert messages[1].is_self and 'https://vc.feishu.cn/w/123456789' in messages[1].text
    sent = await source.send_text('c', 'sent')
    assert sent.position == 2 and sent.is_self
    await source.mark_read('c', 2)
    assert (await source.get_chat('c')).unread == 0
    connected = asyncio.Event()
    task = asyncio.create_task(source.stream(connected.set, lambda _: pytest.fail('unexpected push')))
    await asyncio.wait_for(connected.wait(), 1)
    await source.keepalive()
    task.cancel()
    await asyncio.gather(task, return_exceptions=True)
    fresh = MockSource(Dataset.load(root))
    assert (await fresh.get_chat('c')).unread == 2
    assert (root / 'messages.json').read_bytes() == before


@pytest.mark.asyncio
async def test_real_services_mail_import_pages_body_seen_and_chat(tmp_path):
    root = fixture(tmp_path / 'data')
    app = create_mock_app(Dataset.load(root), tmp_path / 'home', 'token')
    async with app.router.lifespan_context(app):
        mail = app.state.mail
        await mail.refresh()
        assert mail.status().state == 'online'
        assert mail.status().pending == []
        page = await mail.messages()
        assert len(page.items) == 100
        assert len((await mail.messages(cursor=page.next_cursor)).items) == 2
        message = page.items[0]
        body = await mail.body(message.id)
        assert '<script>' not in body.content and 'hello' in body.content
        assert mail.summary(message.id).unread
        await mail.read(message.id)
        assert not mail.summary(message.id).unread
        assert mail.status().unread_count == 101
        chat = app.state.chat
        await chat.sync_feed()
        assert len(await chat.get_messages('c')) == 2
        await chat.mark_read('c')
        assert chat.list_chats()[0].unread == 0
        assert (await chat.send_text('c', 'local')).is_self


@pytest.mark.asyncio
async def test_missing_files_stay_local(tmp_path):
    app = create_mock_app(Dataset.load(tmp_path), tmp_path / 'home', 'token')
    async with app.router.lifespan_context(app):
        assert app.state.mail.status().state == 'unconfigured'
        assert (await app.state.chat.source.restore()).id == 'mock-me'
        assert await app.state.chat.source.list_feed(100) == []


def test_showcase_loads():
    Dataset.load(Path(__file__).parents[2] / 'mock-data/showcase')


@pytest.mark.asyncio
async def test_image_validation_and_bytes(tmp_path):
    from PIL import Image
    root = fixture(tmp_path)
    (root / 'images').mkdir()
    Image.new('RGB', (4, 4)).save(root / 'images/test.png')
    chat = json.loads((root / 'messages.json').read_text())
    message = chat['chats'][0]['messages'][0]
    message.update(type='image', image='images/test.png')
    (root / 'messages.json').write_text(json.dumps(chat))
    source = MockSource(Dataset.load(root))
    assert await source.fetch_image((await source.pull_history('c', [0]))[0]) == (root / 'images/test.png').read_bytes()
    message['image'] = '../outside.png'
    (root / 'messages.json').write_text(json.dumps(chat))
    with pytest.raises(ValueError, match='messages.json image'):
        Dataset.load(root)


def test_cli_rejects_invalid_fixture_without_real_storage(tmp_path):
    import os
    import subprocess
    import sys
    env = dict(os.environ, FEISHU_LITE_HOME=str(tmp_path / 'real-home'), FEISHU_LITE_TOKEN='test')
    result = subprocess.run([str(Path(sys.executable).with_name('feishu-lite-backend')), '--mock-data', str(tmp_path / 'absent')],
                            env=env, text=True, capture_output=True)
    assert result.returncode == 2
    assert 'directory does not exist' in result.stderr
    assert not (tmp_path / 'real-home').exists()
