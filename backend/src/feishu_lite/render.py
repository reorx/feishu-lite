"""Turn Feishu message content (protobuf bytes) into plain display text.

Text and post bodies are a tree of rich-text elements: `elementIds` are the roots and each
element lists its `childIds`. larkx's own extractor walks the flat dictionary, which scrambles
lists and paragraphs, so we walk the tree here.
"""

import re

from larkx.proto import lark_all_pb2 as L
from larkx.proto import proto_pb2 as P

RTE = L.entities.RichTextElement

TYPE_NAMES = {
    2: 'post',
    3: 'file',
    4: 'text',
    5: 'image',
    6: 'system',
    7: 'audio',
    8: 'email',
    9: 'share_chat',
    10: 'sticker',
    11: 'merge_forward',
    12: 'calendar',
    13: 'cloud_file',
    14: 'card',
    15: 'media',
    16: 'share_calendar_event',
    17: 'hongbao',
    18: 'general_calendar',
    19: 'video_chat',
    20: 'location',
    22: 'hongbao',
    23: 'share_user',
    24: 'todo',
    25: 'folder',
    27: 'vote',
    28: 'link',
}
PLACEHOLDERS = {
    5: '[图片]',
    7: '[语音]',
    8: '[邮件]',
    9: '[群名片]',
    10: '[表情包]',
    11: '[合并转发]',
    12: '[日程]',
    13: '[云文档]',
    15: '[视频]',
    16: '[日程]',
    17: '[红包]',
    18: '[日程]',
    19: '[视频会议]',
    20: '[位置]',
    22: '[红包]',
    23: '[名片]',
    24: '[任务]',
    25: '[文件夹]',
    27: '[投票]',
    28: '[链接]',
}

# RichTextElement.Tag values
TEXT, IMG, PARA, FIGURE, AT, ANCHOR, BOLD, ITALIC, UNDERLINE, EMOTION = 1, 2, 3, 4, 5, 6, 7, 8, 9, 10
DIV, LINK, MEDIA, DOCS, H1, H2, H3, UL, OL, LI, QUOTE, CODE, CODE_BLOCK, HR, MENTION = (
    14,
    17,
    18,
    22,
    23,
    24,
    25,
    26,
    27,
    28,
    29,
    30,
    31,
    32,
    36,
)
TEXT_TAGS = {TEXT, BOLD, ITALIC, UNDERLINE, LINK, CODE}
BLOCK_TAGS = {PARA, FIGURE, DIV, H1, H2, H3, QUOTE, CODE_BLOCK, LI}
INLINE_PLACEHOLDERS = {IMG: '[图片]', EMOTION: '[表情]', MEDIA: '[视频]', DOCS: '[文档]'}


def type_name(msg_type: int) -> str:
    return TYPE_NAMES.get(msg_type, 'unknown')


def render_content(msg_type: int, content: bytes) -> str:
    if msg_type == 4:
        tc = P.TextContent()
        tc.ParseFromString(content)
        return _rich_text(tc.richText) or tc.text
    if msg_type == 2:
        pc = P.PostContent()
        pc.ParseFromString(content)
        body = _rich_text(pc.richText)
        return '\n'.join(part for part in (pc.title, body) if part) or '[富文本]'
    if msg_type == 3:
        fc = P.FileContent()
        fc.ParseFromString(content)
        return f'[文件] {fc.name}'.strip()
    if msg_type == 14:
        cc = P.CardContent()
        cc.ParseFromString(content)
        title = cc.cardHeader.title or cc.cardHeader.mainTitle
        return f'[卡片] {title}' if title else '[卡片]'
    if msg_type == 6:
        return _system_text(content)
    return PLACEHOLDERS.get(msg_type, '[消息]')


def _system_text(content: bytes) -> str:
    sc = P.SystemContent()
    sc.ParseFromString(content)
    text = re.sub(r'\{(\w+)\}', lambda m: sc.contents.get(m.group(1), ''), sc.messageTemplate).strip()
    return text or '[系统消息]'


def _rich_text(rt) -> str:
    elements = rt.elements.dictionary
    roots = list(rt.elementIds) or sorted(elements, key=lambda k: int(k) if k.isdigit() else 0)
    lines = _lines(roots, elements)
    return '\n'.join(line.rstrip() for line in lines).strip()


def _lines(ids, elements) -> list[str]:
    lines, inline = [], []

    def flush():
        if inline:
            lines.append(''.join(inline))
            inline.clear()

    for eid in ids:
        el = elements.get(eid)
        if el is None:
            continue
        if el.tag in (UL, OL):
            flush()
            lines.extend(_list_lines(el, elements))
        elif el.tag in BLOCK_TAGS:
            flush()
            lines.extend(_lines(list(el.childIds), elements) or [''])
        elif el.tag == HR:
            flush()
            lines.append('---')
        else:
            inline.append(_inline(el, elements))
    flush()
    return lines


def _list_lines(el, elements) -> list[str]:
    lines = []
    for index, child_id in enumerate(el.childIds, start=1):
        child = elements.get(child_id)
        if child is None:
            continue
        marker = f'{index}. ' if el.tag == OL else '- '
        sub = _lines(list(child.childIds), elements) or ['']
        lines.append(marker + sub[0])
        lines.extend('   ' + line for line in sub[1:])
    return lines


def _inline(el, elements) -> str:
    children = ''.join(_inline(elements[c], elements) for c in el.childIds if c in elements)
    if el.tag in TEXT_TAGS:
        return _parse(P.TextProperty, el.property).content + children
    if el.tag == AT:
        name = _parse(RTE.AtProperty, el.property).content
        return name if name.startswith('@') else f'@{name}'
    if el.tag == ANCHOR:
        prop = _parse(RTE.AnchorProperty, el.property)
        return prop.content or prop.textContent or prop.href
    if el.tag == MENTION:
        return _parse(RTE.MentionProperty, el.property).content
    if el.tag in INLINE_PLACEHOLDERS:
        return INLINE_PLACEHOLDERS[el.tag]
    return children


def _parse(cls, data: bytes):
    msg = cls()
    msg.ParseFromString(data)
    return msg
