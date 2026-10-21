"""Meeting display text shared by protocol rendering and local datasets."""

import re


def meeting_text(topic: str, number: str) -> str:
    title = f'[视频会议] {topic}'.strip()
    number = number.strip()
    valid_number = number if re.fullmatch(r'[0-9]{9}', number) else ''
    if valid_number:
        number = ' '.join(valid_number[i : i + 3] for i in range(0, 9, 3))
    lines = [title]
    if number:
        lines.append(f'会议号：{number}')
    # The web client accepts the public number, never the internal meetingId.
    entry = f'https://vc.feishu.cn/w/{valid_number}'
    lines.append(f'入会入口：{entry}')
    return '\n'.join(lines)
