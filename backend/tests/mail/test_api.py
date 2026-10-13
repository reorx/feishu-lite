"""Wire contracts through real loopback HTTP/SSE, isolated SQLite and C2 fakes."""
import asyncio
from contextlib import asynccontextmanager

import httpx
import pytest
import uvicorn

from feishu_lite.api import create_app
from feishu_lite.mail.service import MailService
from feishu_lite.mail.types import MailCursor, MailKey
from feishu_lite.service import Service
from feishu_lite.store import Store
from tests.conftest import EventStream, TOKEN, _Server
from tests.fakes import FakeSource, make_chat, make_msg
from tests.mail.fake_imap import FakeMailbox

SECRET = 'SYNTHETIC-C3B-SECRET-DO-NOT-ECHO'
ADDRESS = 'synthetic@example.invalid'


@asynccontextmanager
async def live_backend(path, box, *, logged_in=False):
    source = FakeSource()
    source.has_credentials = logged_in
    source.add_chat(make_chat('synthetic'), [make_msg('synthetic', 0)])
    chat_store = Store(path / 'cache.db')
    chat = Service(source, chat_store, qr_poll_interval=.01, resync_interval=3600)
    def mail_factory(store, *, emit):
        return MailService(store, adapter_factory=box.factory, emit=emit, clock=lambda: box.now)
    app = create_app(chat, TOKEN, mail_path=path / 'mail.db', mail_factory=mail_factory)
    server = _Server(uvicorn.Config(app, host='127.0.0.1', port=0, log_level='warning', access_log=False))
    task = asyncio.create_task(server.serve())
    try:
        while not server.started:
            if task.done():
                await task
                raise AssertionError('startup failed')
            await asyncio.sleep(.005)
        port = server.servers[0].sockets[0].getsockname()[1]
        async with httpx.AsyncClient(base_url=f'http://127.0.0.1:{port}',
                                     headers={'Authorization': f'Bearer {TOKEN}'}) as client:
            yield client, app.state.mail, chat, source
    finally:
        server.should_exit = True
        await asyncio.wait_for(task, 5)
        chat_store.db.close()
    assert all(not io.thread_alive for io in box.instances)
    assert not chat._subscribers


@pytest.fixture
async def wire(tmp_path):
    box = FakeMailbox()
    async with live_backend(tmp_path, box) as (client, mail, chat, source):
        yield client, mail, chat, source, box


async def configured(client):
    response = await client.put('/mail/account', json={'address': ADDRESS, 'password': SECRET})
    assert response.status_code == 200, response.text
    account = response.json()['account']['id']
    response = await client.post('/mail/sync')
    assert response.status_code == 200, response.text
    return account


async def test_chat_logged_out_can_configure_mail_and_stream_both_domains(wire):
    client, mail, chat, source, box = wire
    status = (await client.get('/status')).json()
    assert status['state'] == 'logged_out' and status['features'] == ['mail']
    assert (await client.get('/mail/status')).json()['state'] == 'unconfigured'
    async with EventStream(client) as events:
        account = await configured(client)
        await events.wait_for(lambda n, d: n == 'mail.status' and d['status']['state'] == 'online')
        assert (await client.get('/status')).json()['state'] == 'logged_out'
        box.add(25)
        await client.post('/mail/sync')
        _, arrival = await events.wait_for(lambda n, d: n == 'mail.arrived')
        assert arrival['account_id'] == account and arrival['notification']['items'][0]['key']['uid'] == 25
        assert not events.named('message.new')
        await client.post('/login/qr')
        await events.wait_for(lambda n, d: n == 'status' and d['state'] == 'online')
    assert mail.status().pending


@pytest.mark.parametrize('method,path', [
    ('GET','/mail/status'), ('POST','/mail/account/test'), ('PUT','/mail/account'),
    ('PUT','/mail/account/credential'), ('DELETE','/mail/account'), ('GET','/mail/folders'),
    ('GET','/mail/messages'), ('GET','/mail/messages/synthetic'), ('POST','/mail/messages/synthetic/read'),
    ('POST','/mail/sync'), ('POST','/mail/notifications/ack'), ('GET','/events'),
])
@pytest.mark.parametrize('authorization', [None, 'Bearer wrong'])
async def test_token_required_for_every_mail_route(wire, method, path, authorization):
    client, _, _, _, box = wire
    headers = {} if authorization is None else {'Authorization': authorization}
    async with httpx.AsyncClient(base_url=client.base_url) as anonymous:
        response = await anonymous.request(method, path, headers=headers, content=b'{bad json')
    assert response.status_code == 401
    assert not box.instances


@pytest.mark.parametrize('method,path', [('PUT','/mail/account'), ('POST','/mail/account/test'),
                                          ('PUT','/mail/account/credential')])
@pytest.mark.parametrize('payload', [
    '{"password":"' + SECRET + '",',
    {'address': {'nested': SECRET}, 'password': SECRET},
    {'address': ADDRESS, 'password': {'nested': SECRET}},
    {'address': ADDRESS, 'password': SECRET, SECRET: {'nested': SECRET}},
    {'address': SECRET, 'password': SECRET},
    [SECRET, {'password': SECRET}],
    {'mail_account_id': {'nested': SECRET}, 'password': SECRET},
])
async def test_account_validation_never_echoes_secrets(wire, method, path, payload, caplog):
    client, _, _, _, box = wire
    response = await client.request(method, path, **({'content': payload} if isinstance(payload, str) else {'json': payload}))
    assert response.status_code == 422
    assert response.json() == {'domain': 'mail', 'code': 'invalid_request'}
    assert SECRET not in response.text and SECRET not in caplog.text
    assert not box.instances


async def test_read_body_paging_folders_and_account_removal(wire):
    client, mail, chat, _, box = wire
    box.uids = set(range(1, 154))
    box.unread = {1, 2, 153}
    box.uidnext = 154
    account = await configured(client)
    assert (await client.get('/mail/status')).json()['unread_count'] == 3
    folders = (await client.get('/mail/folders')).json()
    assert folders[1]['id'] == '分类/中文' and not folders[1]['supported']
    first = (await client.get('/mail/messages')).json()
    assert len(first['items']) == 100
    second = (await client.get('/mail/messages', params={'cursor': first['next_cursor']})).json()
    assert len(second['items']) == 50
    assert not {row['key']['uid'] for row in first['items']} & {row['key']['uid'] for row in second['items']}
    key = MailKey.model_validate(first['items'][0]['key'])
    response = await client.get('/mail/messages/' + key.id)
    assert response.json() == {'kind': 'html', 'content': '<b>synthetic</b>'}
    assert 153 in box.unread and not any(name == 'seen' for name, _ in box.calls)
    response = await client.post('/mail/messages/' + key.id + '/read')
    assert response.json() == {'read_ids': [key.id]}
    assert (await client.get('/mail/status')).json()['unread_count'] == 2
    assert (await client.post('/mail/messages/' + key.id + '/read')).json() == {'read_ids': []}
    changed = (await client.put('/mail/account', json={'address': 'other@example.invalid', 'password': SECRET})).json()
    assert changed['removed_account_id'] == account and changed['account']['id'] != account
    old = await client.get('/mail/messages/' + key.id)
    assert old.status_code == 410 and old.json()['code'] == 'stale_message'
    removed = (await client.delete('/mail/account')).json()
    assert removed['removed_account_id'] == changed['account']['id']
    assert mail.status().state == 'unconfigured' and chat.store.get_chat('synthetic') is None


async def test_test_connection_does_not_save_and_auth_failure_does_not_logout_chat(wire):
    client, mail, chat, source, box = wire
    assert (await client.post('/login/qr')).status_code == 200
    while chat.state != 'online':
        await asyncio.sleep(.005)
    result = await client.post('/mail/account/test', json={'address': ADDRESS, 'password': SECRET})
    assert result.json() == {'writable': True, 'supports_idle': True}
    assert mail.status().state == 'unconfigured' and all(io.closed.is_set() for io in box.instances)
    box.errors['connect'] = 'authentication_failed'
    response = await client.post('/mail/account/test', json={'address': ADDRESS, 'password': SECRET})
    assert response.status_code == 403 and response.json() == {'domain': 'mail', 'code': 'authentication_failed'}
    await client.put('/mail/account', json={'address': ADDRESS, 'password': SECRET})
    response = await client.post('/mail/sync')
    assert response.status_code == 403
    assert mail.status().state == 'auth_failed' and (await client.get('/status')).json()['state'] == 'online'
    await source.push(make_msg('synthetic', 1, text='synthetic live chat'))
    await asyncio.sleep(.02)
    assert (await client.get('/chats/synthetic/messages')).status_code == 200


async def test_restart_inject_pending_ack_and_old_validity(tmp_path):
    box = FakeMailbox()
    async with live_backend(tmp_path, box) as (client, mail, _, _):
        account = await configured(client)
        box.add(25)
        await client.post('/mail/sync')
        pending = (await client.get('/mail/status')).json()['pending']
        assert len(pending) == 1
        await client.get('/mail/messages/' + MailKey.model_validate(pending[0]['items'][0]['key']).id)
    async with live_backend(tmp_path, box) as (client, mail, _, _):
        status = (await client.get('/mail/status')).json()
        assert status['state'] == 'credential_missing' and status['pending'] == pending
        assert (await client.post('/mail/sync')).json()['code'] == 'credential_missing'
        mismatch = await client.put('/mail/account/credential', json={'mail_account_id':'wrong', 'password':SECRET})
        assert mismatch.status_code == 400 and mismatch.json()['code'] == 'account_mismatch'
        assert (await client.put('/mail/account/credential', json={'mail_account_id':account,'password':SECRET})).status_code == 200
        await client.post('/mail/sync')
        generation = mail.generation
        await client.put('/mail/account/credential', json={'mail_account_id':account,'password':SECRET})
        assert mail.generation == generation and mail.status().pending[0].id == pending[0]['id']
        key = MailKey.model_validate(pending[0]['items'][0]['key'])
        cursor = MailCursor(key=key).id
        ack = {'mail_account_id':account,'uidvalidity':key.uidvalidity,'batch_id':pending[0]['id']}
        assert (await client.post('/mail/notifications/ack',json=ack)).json()['pending'] == []
        assert (await client.post('/mail/notifications/ack',json=ack)).status_code == 200
        box.validity += 1
        await client.post('/mail/sync',params={'reconnect':True})
        assert (await client.get('/mail/messages',params={'cursor':cursor})).status_code == 410
        assert (await client.get('/mail/messages/'+key.id)).status_code == 410
        assert (await client.post('/mail/notifications/ack',json=ack)).status_code == 410
    async with live_backend(tmp_path, box) as (client, mail, _, _):
        assert (await client.get('/mail/status')).json()['pending'] == []
    assert SECRET.encode() not in (tmp_path/'mail.db').read_bytes()


async def test_safe_errors_and_chat_validation_compatibility(wire):
    client, _, _, _, box = wire
    assert (await client.get('/mail/messages')).status_code == 400
    await configured(client)
    for url, params, code in [('/mail/messages',{'folder':'分类/中文'},'unsupported_folder'),
                               ('/mail/messages',{'cursor':'bad'},'invalid_id'),
                               ('/mail/messages/bad',{},'invalid_id')]:
        response = await client.get(url,params=params)
        assert response.status_code == 400 and response.json() == {'domain':'mail','code':code}
    response = await client.post('/chats/synthetic/messages',json={'text':''})
    assert response.status_code == 422 and isinstance(response.json()['detail'],list)


async def test_queue_overflow_ends_stream_without_ack_and_disconnect_unsubscribes(wire):
    client, mail, chat, _, box = wire
    await configured(client)
    queue = chat.subscribe()
    assert queue.maxsize > 0
    box.add(25)
    await client.post('/mail/sync')
    for _ in range(queue.maxsize + 1):
        mail._emit_status()
    assert queue not in chat._subscribers and await queue.get() is None
    assert mail.status().pending
    async with EventStream(client) as events:
        await events.wait_for(lambda n,d: n == 'mail.status')
        assert len(chat._subscribers) == 1
    for _ in range(100):
        if not chat._subscribers:
            break
        await asyncio.sleep(.005)
    assert not chat._subscribers
    assert (await client.get('/mail/status')).json()['pending']


@pytest.mark.parametrize('code,status', [('offline',503),('message_missing',404),('body_too_large',413),
                                         ('mailbox_readonly',403),('disconnected',502),('tls_failed',502),
                                         ('command_rejected',502),('idle_done_timeout',504)])
async def test_domain_failure_mapping_preserves_unread_and_chat(wire, code, status):
    client, mail, chat, _, box = wire
    await configured(client)
    key = MailKey.model_validate((await client.get('/mail/messages')).json()['items'][1]['key'])
    box.errors['seen'] = code
    response = await client.post('/mail/messages/'+key.id+'/read')
    assert response.status_code == status and response.json() == {'domain':'mail','code':code}
    assert mail.store.get_summary(key).unread and key.uid in box.unread
    assert (await client.get('/status')).json()['state'] == 'logged_out'


async def test_unexpected_error_with_secret_cause_cannot_reach_http_or_traceback(wire, caplog):
    client, _, _, _, box = wire
    async def broken(io):
        raise RuntimeError(SECRET) from ValueError({'password':SECRET})
    box.hooks['connect'] = broken
    response = await client.post('/mail/account/test',json={'address':ADDRESS,'password':SECRET})
    assert response.status_code == 500 and response.json() == {'domain':'mail','code':'internal_error'}
    assert SECRET not in response.text and SECRET not in caplog.text
    assert all(io.closed.is_set() for io in box.instances)


async def test_mail_wait_does_not_block_chat_and_offline_cache_body(wire):
    client, mail, chat, source, box = wire
    await configured(client)
    key = MailKey.model_validate((await client.get('/mail/messages')).json()['items'][1]['key'])
    await client.get('/mail/messages/'+key.id)
    began = asyncio.Event()
    release = asyncio.Event()
    async def stalled(io):
        began.set()
        await release.wait()
    box.hooks['unseen'] = stalled
    sync = asyncio.create_task(client.post('/mail/sync'))
    try:
        await began.wait()
        assert (await asyncio.wait_for(client.post('/login/qr'),.5)).status_code == 200
        while chat.state != 'online':
            await asyncio.sleep(.005)
        async with EventStream(client) as events:
            await source.push(make_msg('synthetic',1,text='synthetic marker'))
            await events.wait_for(lambda n,d: n == 'message.new')
    finally:
        release.set()
        await sync
    box.hooks.clear()
    box.errors['unseen'] = 'disconnected'
    assert (await client.post('/mail/sync')).status_code == 502
    assert mail.status().state == 'offline'
    assert (await client.get('/mail/messages/'+key.id)).status_code == 200
    assert (await client.post('/mail/messages/'+key.id+'/read')).status_code == 503
    assert (await client.get('/mail/messages')).status_code == 200
    assert (await client.delete('/mail/account')).status_code == 200
    assert chat.state == 'online' and chat.store.get_chat('synthetic') is not None
    assert (await client.post('/logout')).status_code == 200


async def test_disconnect_cancels_probe_and_releases_owner(wire):
    client, mail, _, _, box = wire
    began = asyncio.Event()
    async def stalled(io):
        began.set()
        await asyncio.Event().wait()
    box.hooks['connect'] = stalled
    request = asyncio.create_task(client.post('/mail/account/test',json={'address':ADDRESS,'password':SECRET}))
    await began.wait()
    request.cancel()
    await asyncio.gather(request,return_exceptions=True)
    for _ in range(100):
        if not mail.probes:
            break
        await asyncio.sleep(.005)
    assert not mail.probes and all(io.closed.is_set() for io in box.instances)
    assert mail.status().state == 'unconfigured'


async def test_real_stream_overflow_finishes_and_reconnect_recovers_pending(wire):
    client, mail, chat, _, box = wire
    await configured(client)
    box.add(25)
    await client.post('/mail/sync')
    async with EventStream(client) as events:
        await events.wait_for(lambda n,d: n == 'mail.status')
        queue = next(iter(chat._subscribers))
        for _ in range(queue.maxsize+1):
            mail._emit_status()
        await asyncio.wait_for(asyncio.shield(events._task),1)
    assert not chat._subscribers
    async with EventStream(client) as events:
        _, snapshot = await events.wait_for(lambda n,d: n == 'mail.status')
        assert snapshot['status']['pending']
        assert not events.named('mail.arrived')
    assert (await client.get('/mail/status')).json()['pending']


@pytest.mark.parametrize('operation', ['body','seen'])
async def test_http_result_from_removed_account_is_rejected(wire, operation):
    client, mail, _, _, box = wire
    old_account = await configured(client)
    key = MailKey.model_validate((await client.get('/mail/messages')).json()['items'][1]['key'])
    began, release = asyncio.Event(), asyncio.Event()
    async def stall(io):
        began.set()
        await release.wait()
    box.hooks[operation] = stall
    request = asyncio.create_task(client.get('/mail/messages/'+key.id) if operation == 'body' else
                                  client.post('/mail/messages/'+key.id+'/read'))
    try:
        await began.wait()
        change = (await client.put('/mail/account',json={'address':'other@example.invalid','password':SECRET})).json()
        assert change['removed_account_id'] == old_account
    finally:
        release.set()
    response = await request
    assert response.status_code == 410 and response.json() == {'domain':'mail','code':'stale_request'}
    assert not mail.store.accounts()[0].id == old_account


async def test_command_timeout_is_a_gateway_timeout(wire):
    client, _, _, _, box = wire
    box.errors['connect'] = 'command_timeout'
    response = await client.post('/mail/account/test',json={'address':ADDRESS,'password':SECRET})
    assert response.status_code == 504 and response.json() == {'domain':'mail','code':'command_timeout'}


async def test_probe_http_deadline_cancels_and_cleans_owner(wire, monkeypatch):
    from feishu_lite.mail import api as mail_api
    monkeypatch.setattr(mail_api,'MAIL_REQUEST_TIMEOUT',.03,raising=False)
    client, mail, _, _, box = wire
    async def stalled(io):
        await asyncio.Event().wait()
    box.hooks['connect'] = stalled
    response = await asyncio.wait_for(client.post('/mail/account/test',json={'address':ADDRESS,'password':SECRET}),.3)
    assert response.status_code == 504 and response.json() == {'domain':'mail','code':'request_timeout'}
    assert not mail.probes and all(io.closed.is_set() for io in box.instances)


async def test_http_sync_deadline_keeps_shared_round_and_wait_false_is_available(wire, monkeypatch):
    from feishu_lite.mail import api as mail_api
    client, mail, _, _, box = wire
    await configured(client)
    monkeypatch.setattr(mail_api,'MAIL_REQUEST_TIMEOUT',.03,raising=False)
    release = asyncio.Event()
    async def stalled(io):
        await release.wait()
    box.hooks['unseen'] = stalled
    try:
        response = await asyncio.wait_for(client.post('/mail/sync'),.3)
        assert response.status_code == 504 and response.json()['code'] == 'request_timeout'
        assert (await client.post('/mail/sync',params={'wait':False})).status_code == 200
    finally:
        release.set()
    await mail.refresh()
    assert mail.status().state == 'online'


async def test_wire_summaries_and_pending_expose_opaque_message_id(wire):
    client, mail, _, _, box = wire
    await configured(client)
    rows = (await client.get('/mail/messages')).json()['items']
    assert all(row['id'] == MailKey.model_validate(row['key']).id for row in rows)
    box.add(25)
    await client.post('/mail/sync')
    pending = (await client.get('/mail/status')).json()['pending']
    row = pending[0]['items'][0]
    assert row['id'] == MailKey.model_validate(row['key']).id
    # Presentation-only derived id must not change persisted C1 JSON/schema.
    assert all('"id"' not in raw[0] for raw in mail.store.db.execute('SELECT data FROM summaries'))


async def test_invalid_utf8_credential_json_is_safe_validation_error(wire, caplog):
    client, _, _, _, box = wire
    response = await client.post('/mail/account/test',content=b'{"password":"'+SECRET.encode()+b'"}\xff',
                                 headers={'Content-Type':'application/json'})
    assert response.status_code == 422 and response.json() == {'domain':'mail','code':'invalid_request'}
    assert SECRET not in response.text and SECRET not in caplog.text
    assert not box.instances
