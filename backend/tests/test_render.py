"""Message content -> display text, table-driven over sanitized real protocol samples."""

import json
from pathlib import Path

import pytest
from larkx.proto import lark_all_pb2 as L

from feishu_lite.render import render_content

CASES = json.loads((Path(__file__).parent / 'fixtures' / 'render_cases.json').read_text())


@pytest.mark.parametrize('case', CASES, ids=[c['name'] for c in CASES])
def test_render_content(case):
    assert render_content(case['type'], bytes.fromhex(case['content_hex'])) == case['expected']


def meeting_content(**fields):
    content = L.entities.VideoChatContent()
    content.type = 1
    for key, value in fields.items():
        setattr(content.meetingCard, key, value)
    return content.SerializeToString()


def test_meeting_invitation_displays_topic_number_and_web_entry():
    content = meeting_content(topic='测试交付会议', meetNumber='123456789', meetingId='9000000000000000001')
    assert render_content(19, content) == (
        '[视频会议] 测试交付会议\n会议号：123 456 789\n入会入口：https://vc.feishu.cn/w/123456789'
    )


def test_meeting_without_topic_keeps_number_and_does_not_use_internal_id():
    content = meeting_content(meetNumber='123456789', meetingId='9000000000000000001')
    assert render_content(19, content) == '[视频会议]\n会议号：123 456 789\n入会入口：https://vc.feishu.cn/w/123456789'


@pytest.mark.parametrize('fields', [{}, {'meetingId': '9000000000000000001'}, {'topic': '测试会议'}])
def test_meeting_without_public_number_still_offers_web_entry(fields):
    text = render_content(19, meeting_content(**fields))
    assert text.endswith('入会入口：https://vc.feishu.cn/w/')
    assert '会议号' not in text
    assert '9000000000000000001' not in text


def test_empty_meeting_content_retains_placeholder():
    assert render_content(19, b'') == '[视频会议]'
