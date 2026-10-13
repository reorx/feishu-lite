"""All the way from loopback HTTP through real IMAPClient wire operations."""
import time

from feishu_lite.mail.imap import ImapAdapter
from feishu_lite.mail.types import MailKey
from tests.conftest import EventStream
from tests.mail.fake_imap import FakeMailbox
from tests.mail.imap_server import imap_server
from tests.mail.test_api import ADDRESS, SECRET, configured, live_backend


async def test_http_real_imap_peek_seen_arrival_and_safe_limit(tmp_path, record_property):
    box = FakeMailbox()
    async with imap_server() as peer:
        def factory(config):
            io = ImapAdapter(config.model_copy(update={'host':'127.0.0.1','port':peer.port}),_plaintext_loopback=True)
            box.instances.append(io)
            return io
        box.factory = factory
        async with live_backend(tmp_path,box) as (client,mail,chat,_):
            await configured(client)
            folders = (await client.get('/mail/folders')).json()
            assert len(folders) == 3 and folders[1]['name'] == '目录'
            page = (await client.get('/mail/messages')).json()
            assert [row['key']['uid'] for row in page['items']] == [22,9,3]
            assert page['items'][1]['attachments'][0]['filename'] == 'sample.pdf'
            key = MailKey.model_validate(page['items'][1]['key'])
            await peer.events['idle'].wait()
            began = time.monotonic()
            response = await client.get('/mail/messages/'+key.id)
            elapsed = peer.fetch_at - began
            record_property('http_body_fetch_seconds',elapsed)
            assert elapsed < 2 and peer.serialized
            assert response.json() == {'kind':'html','content':'<b>hello</b>'}
            assert b'\\Seen' not in peer.flags[key.uid]
            assert not any(b' STORE ' in cmd for cmd in peer.commands)
            assert any(b'BODY.PEEK[2]' in cmd for cmd in peer.commands)
            response = await client.post('/mail/messages/'+key.id+'/read')
            assert response.json() == {'read_ids':[key.id]}
            assert b'\\Seen' in peer.flags[key.uid]
            assert (await client.get('/mail/status')).json()['unread_count'] == 1
            async with EventStream(client) as events:
                peer.flags[25] = set()
                await client.post('/mail/sync')
                _, arrival = await events.wait_for(lambda n,d:n == 'mail.arrived')
                assert arrival['notification']['items'][0]['key']['uid'] == 25
                assert not events.named('message.new')
            peer.scenario = 'body_oversize'
            new_key = MailKey.model_validate(arrival['notification']['items'][0]['key'])
            response = await client.get('/mail/messages/'+new_key.id)
            assert response.status_code == 413 and response.json() == {'domain':'mail','code':'body_too_large'}
            assert (await client.get('/status')).json()['state'] == 'logged_out'
        assert not peer.tasks and not peer.writers
