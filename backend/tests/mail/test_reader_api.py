"""D2 route metadata: cached, authenticated, exact identity and no Seen."""
import pytest

from feishu_lite.mail.types import MailKey
from tests.mail.test_api import configured, wire  # shared real HTTP fixture


async def test_summary_by_id_outside_first_page_and_offline(wire):
    client, mail, _, _, box = wire
    box.uids = set(range(1, 154))
    box.uidnext = 154
    account = await configured(client)
    first = (await client.get('/mail/messages')).json()
    page = (await client.get('/mail/messages', params={'cursor': first['next_cursor']})).json()
    target = page['items'][-1]
    calls = list(box.calls)
    result = await client.get('/mail/messages/' + target['id'] + '/summary')
    assert result.status_code == 200
    assert result.json() == target
    assert box.calls == calls  # never body/STORE/full inbox for metadata
    await mail.io.stop()
    mail.state = 'offline'
    assert (await client.get('/mail/messages/' + target['id'] + '/summary')).json() == target
    assert account == target['key']['account_id']


@pytest.mark.parametrize('authorization', [None, 'Bearer wrong'])
async def test_summary_token_required(wire, authorization):
    client, _, _, _, _ = wire
    headers = {} if authorization is None else {'Authorization': authorization}
    result = await client.get('/mail/messages/synthetic/summary', headers={'Authorization': headers.get('Authorization', '')})
    assert result.status_code == 401


async def test_summary_rejects_wrong_account_validity_folder_and_deleted(wire):
    client, mail, _, _, box = wire
    account = await configured(client)
    target = (await client.get('/mail/messages')).json()['items'][0]
    key = MailKey.model_validate(target['key'])
    for altered, status, code in [
        (key.model_copy(update={'account_id': 'other'}), 410, 'stale_message'),
        (key.model_copy(update={'uidvalidity': key.uidvalidity + 1}), 410, 'stale_message'),
        (key.model_copy(update={'folder_id': 'Other'}), 400, 'unsupported_folder'),
    ]:
        result = await client.get('/mail/messages/' + altered.id + '/summary')
        assert result.status_code == status and result.json()['code'] == code
    mail.store.delete_messages(account, 'INBOX', key.uidvalidity, {key.uid})
    assert (await client.get('/mail/messages/' + key.id + '/summary')).status_code == 404
    assert (await client.get('/mail/messages/not-an-id/summary')).status_code == 400
