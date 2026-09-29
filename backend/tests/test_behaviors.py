"""Coarse behaviour tests: FakeSource + real HTTP/SSE server in-process."""

import asyncio

import httpx

from .conftest import TOKEN
from .fakes import ME, make_chat, make_msg


def seed_two_chats(source):
    source.add_chat(make_chat('A', name='Alpha', rank_time=100), [make_msg('A', 0, create_time=100)])
    source.add_chat(make_chat('B', name='Beta', rank_time=200), [make_msg('B', 0, create_time=200)])


async def test_incoming_push_bumps_unread_preview_and_order(source, make_backend):
    seed_two_chats(source)
    h = await make_backend(source)
    assert [c['id'] for c in await h.chats()] == ['B', 'A']

    async with h.events() as ev:
        msg = make_msg('A', 1, sender_id='u_alice', text='新消息', create_time=300)
        await source.push(msg, times=2)  # the server really does push some messages twice
        await source.push(make_msg('B', 1, create_time=301, text='marker'))
        await ev.wait_for(lambda n, d: n == 'message.new' and d['message']['text'] == 'marker')

        new_for_a = [d for d in ev.named('message.new') if d['message']['id'] == msg.id]
        assert len(new_for_a) == 1
        event = new_for_a[0]
        assert event['message']['sender_name'] == 'Alice'
        assert event['message']['is_self'] is False
        assert event['chat']['unread'] == 1

    chat_a = await h.chat('A')
    assert chat_a['unread'] == 1
    assert chat_a['last_message_preview'] == 'Alice: 新消息'
    assert chat_a['last_message_time'] == 300


async def test_own_message_from_other_device_is_stored_without_unread(source, make_backend):
    seed_two_chats(source)
    h = await make_backend(source)

    async with h.events() as ev:
        mine = make_msg('A', 1, sender_id=ME.id, text='我在手机上回的', create_time=300)
        await source.push(mine)
        _, event = await ev.wait_for(lambda n, d: n == 'message.new' and d['message']['id'] == mine.id)

    assert event['message']['is_self'] is True
    chat_a = await h.chat('A')
    assert chat_a['unread'] == 0
    assert chat_a['last_message_preview'] == '我在手机上回的'
    assert [c['id'] for c in await h.chats()][0] == 'A'
    messages = (await h.client.get('/chats/A/messages')).json()
    assert messages[-1]['id'] == mine.id


async def test_opening_uncached_chat_pulls_history_and_pages_backwards(source, make_backend):
    source.add_chat(make_chat('C', name='Gamma', rank_time=100), [make_msg('C', p, text=f'#{p}') for p in range(50)])
    h = await make_backend(source)

    page1 = (await h.client.get('/chats/C/messages', params={'limit': 30})).json()
    assert [m['position'] for m in page1] == list(range(20, 50))
    assert page1[0]['sender_name'] == 'Alice'

    calls = len(source.history_calls)
    again = (await h.client.get('/chats/C/messages', params={'limit': 30})).json()
    assert again == page1
    assert len(source.history_calls) == calls, 'cached page must not hit the source again'

    page2 = (await h.client.get('/chats/C/messages', params={'before_position': 20, 'limit': 30})).json()
    assert [m['position'] for m in page2] == list(range(0, 20))

    page3 = (await h.client.get('/chats/C/messages', params={'before_position': 0})).json()
    assert page3 == []


async def test_sent_text_shows_up_exactly_once(source, make_backend):
    seed_two_chats(source)
    h = await make_backend(source)

    async with h.events() as ev:
        resp = await h.client.post('/chats/A/messages', json={'text': '好的'})
        assert resp.status_code == 200
        sent = resp.json()
        assert sent['is_self'] is True and sent['text'] == '好的'
        assert source.sent == [('A', '好的')]

        # the server echoes our own message back over the push channel
        echo = source.history['A'][sent['position']]
        await source.push(echo)
        await source.push(make_msg('B', 1, text='marker'))
        await ev.wait_for(lambda n, d: n == 'message.new' and d['message']['text'] == 'marker')
        assert len([d for d in ev.named('message.new') if d['message']['id'] == sent['id']]) == 1

    messages = (await h.client.get('/chats/A/messages')).json()
    assert [m['id'] for m in messages].count(sent['id']) == 1
    assert (await h.chat('A'))['last_message_preview'] == '好的'


async def test_mark_read_clears_unread_and_syncs_max_position(source, make_backend):
    source.add_chat(make_chat('A', name='Alpha', rank_time=100, unread=3), [make_msg('A', p) for p in range(10)])
    h = await make_backend(source)
    assert (await h.chat('A'))['unread'] == 3

    async with h.events() as ev:
        resp = await h.client.post('/chats/A/read')
        assert resp.status_code == 200
        await ev.wait_for(lambda n, d: n == 'chat.updated' and d['chat']['id'] == 'A' and d['chat']['unread'] == 0)

    assert (await h.chat('A'))['unread'] == 0
    assert source.read_calls == [('A', 9)]


async def test_reconnect_backfills_missed_messages_without_message_new(source, make_backend):
    source.add_chat(make_chat('A', name='Alpha', rank_time=100), [make_msg('A', p) for p in range(5)])
    h = await make_backend(source)
    assert len((await h.client.get('/chats/A/messages')).json()) == 5

    async with h.events() as ev:
        # messages that arrive on the server while our connection is down
        source.add_message(make_msg('A', 5, text='断线时 1', create_time=500))
        source.add_message(make_msg('A', 6, text='断线时 2', create_time=501))
        source.disconnect()
        await ev.wait_for(lambda n, d: n == 'status' and d['state'] == 'reconnecting')
        await ev.wait_for(
            lambda n, d: n == 'chat.updated' and d['chat']['id'] == 'A' and d['chat']['last_position'] == 6
        )
        assert source.connect_count == 2
        assert not [d for d in ev.named('message.new') if d['message']['chat_id'] == 'A']

    chat_a = await h.chat('A')
    assert chat_a['unread'] == 2
    assert chat_a['last_message_preview'] == 'Alice: 断线时 2'
    calls = len(source.history_calls)
    messages = (await h.client.get('/chats/A/messages')).json()
    assert [m['text'] for m in messages][-2:] == ['断线时 1', '断线时 2']
    assert len(source.history_calls) == calls, 'backfilled messages should already be in the cache'


async def test_expired_credentials_switch_to_logged_out(source, make_backend):
    seed_two_chats(source)
    h = await make_backend(source)

    async with h.events() as ev:
        source.expire()
        await ev.wait_for(lambda n, d: n == 'status' and d['state'] == 'logged_out')

    status = (await h.client.get('/status')).json()
    assert status['state'] == 'logged_out'
    assert status['user'] is None
    assert status['last_error']


async def test_requests_without_valid_token_are_rejected(source, make_backend):
    h = await make_backend(source)
    base = str(h.client.base_url)
    async with httpx.AsyncClient(base_url=base) as anon:
        assert (await anon.get('/status')).status_code == 401
        assert (await anon.get('/chats', headers={'Authorization': 'Bearer wrong'})).status_code == 401
        assert (await anon.get('/events')).status_code == 401
        assert (await anon.post('/chats/A/messages', json={'text': 'x'})).status_code == 401
        assert (await anon.get('/status', headers={'Authorization': f'Bearer {TOKEN}'})).status_code == 200


async def test_qr_login_brings_service_online(source, make_backend):
    source.has_credentials = False
    h = await make_backend(source, wait_online=False)
    await h.wait_state('logged_out')
    assert (await h.client.get('/status')).json()['last_error'] is None

    resp = await h.client.post('/login/qr')
    assert resp.status_code == 200
    assert 'qrlogin' in resp.json()['qr_content']

    async def _until_success():
        while (await h.client.get('/login/qr/status')).json()['status'] != 'success':
            await asyncio.sleep(0.01)

    await asyncio.wait_for(_until_success(), 3)
    await h.wait_state('online')
    assert (await h.client.get('/status')).json()['user'] == {'id': ME.id, 'name': ME.name}


async def test_logout_forgets_credentials_and_cache(source, make_backend):
    seed_two_chats(source)
    h = await make_backend(source)
    assert len(await h.chats()) == 2

    assert (await h.client.post('/logout')).status_code == 200
    await h.wait_state('logged_out')
    assert source.has_credentials is False
    assert await h.chats() == []
