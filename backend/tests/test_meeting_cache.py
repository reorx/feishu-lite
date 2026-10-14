from feishu_lite.store import Store

from .fakes import make_chat, make_msg


def meeting(text):
    return make_msg('A', 0, text=text).model_copy(update={'type': 'video_chat'})


def test_enrich_cached_meeting_without_treating_it_as_new(tmp_path):
    store = Store(tmp_path / 'cache.db')
    old = meeting('[视频会议]')
    rich = meeting('[视频会议] 测试会议\n会议号：123 456 789\n入会入口：https://vc.feishu.cn/w/123456789')
    assert store.add_message(old)
    assert not store.add_message(rich)
    assert store.get_message(old.id).text == rich.text
    assert not store.add_message(old)
    assert store.get_message(old.id).text == rich.text
    store.db.close()


def test_revoked_meeting_is_not_restored_by_cache_enrichment(tmp_path):
    store = Store(tmp_path / 'cache.db')
    revoked = meeting('[消息已撤回]')
    store.add_message(revoked)
    assert not store.add_message(meeting('[视频会议] 测试会议\n会议号：123 456 789'))
    assert store.get_message(revoked.id).text == '[消息已撤回]'
    store.db.close()


async def test_cached_meeting_is_refetched_once_without_mark_read_or_notification(source, make_backend):
    rich = meeting('[视频会议] 测试会议\n会议号：123 456 789\n入会入口：https://vc.feishu.cn/w/123456789')
    source.add_chat(make_chat('A', unread=3), [rich])
    h = await make_backend(source)
    h.service.store.db.execute('UPDATE messages SET text=? WHERE id=?', ('[视频会议]', rich.id))
    h.service.store.db.commit()
    async with h.events() as events:
        response = await h.client.get('/chats/A/messages')
        assert response.json()[0]['text'] == rich.text
        calls = len(source.history_calls)
        await h.client.get('/chats/A/messages')
        assert len(source.history_calls) == calls
        assert source.read_calls == []
        assert (await h.chat('A'))['unread'] == 3
        assert not events.named('message.new')


async def test_unavailable_meeting_details_do_not_refetch_on_every_page(source, make_backend):
    source.add_chat(make_chat('A'), [meeting('[视频会议]')])
    h = await make_backend(source)
    await h.client.get('/chats/A/messages')
    calls = len(source.history_calls)
    await h.client.get('/chats/A/messages')
    assert len(source.history_calls) == calls
