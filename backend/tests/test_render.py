"""Message content -> display text, table-driven over sanitized real protocol samples."""

import json
from pathlib import Path

import pytest

from feishu_lite.render import render_content

CASES = json.loads((Path(__file__).parent / 'fixtures' / 'render_cases.json').read_text())


@pytest.mark.parametrize('case', CASES, ids=[c['name'] for c in CASES])
def test_render_content(case):
    assert render_content(case['type'], bytes.fromhex(case['content_hex'])) == case['expected']
