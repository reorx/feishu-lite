"""How LarkxSource maps Feishu chat entities onto our Chat model (no network)."""

from feishu_lite.source import LarkxSource


def group_entity(**extra):
    return {
        'id': '1001',
        'type': 2,
        'name': "Alice's Feishu Assistant",
        'newMessageCount': 3,
        'isRemind': False,
        'lastMessagePosition': 9,
        'updateTime': 1700000000,
        **extra,
    }


def test_group_name_prefers_the_chinese_name_the_official_client_shows():
    raw = group_entity(i18nInf={'i18nNames': {'zh_cn': '爱丽丝的飞书助手', 'en_us': "Alice's Feishu Assistant"}})
    assert LarkxSource()._to_chat(raw, {}).name == '爱丽丝的飞书助手'


def test_group_without_a_chinese_name_keeps_its_plain_name():
    assert LarkxSource()._to_chat(group_entity(), {}).name == "Alice's Feishu Assistant"
    raw = group_entity(i18nInf={'i18nNames': {'zh_cn': '', 'en_us': 'Other'}})
    assert LarkxSource()._to_chat(raw, {}).name == "Alice's Feishu Assistant"
