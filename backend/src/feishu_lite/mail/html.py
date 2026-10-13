"""Sanitize mail HTML fragments. Browser/CSP/navigation controls belong to the App."""
import html
import re
from html.parser import HTMLParser
from urllib.parse import unquote, urlsplit

import nh3

from .types import MailError, MailLimits, RawBody

TAGS = {'a', 'p', 'div', 'span', 'br', 'hr', 'b', 'strong', 'i', 'em', 'u', 's',
        'blockquote', 'pre', 'code', 'ul', 'ol', 'li', 'table', 'thead', 'tbody',
        'tfoot', 'tr', 'td', 'th', 'caption', 'h1', 'h2', 'h3', 'h4', 'h5', 'h6'}
DROP_CONTENT = {'script', 'style', 'iframe', 'object', 'embed', 'form', 'svg', 'math',
                'template', 'noscript', 'video', 'audio', 'canvas', 'head'}


class _ImagePlaceholders(HTMLParser):
    def __init__(self):
        super().__init__(convert_charrefs=False)
        self.fragments: list[str] = []

    def handle_starttag(self, tag, attrs):
        if tag == 'img':
            label = dict(attrs).get('alt') or '图片已阻止'
            self.fragments.append(html.escape(f'[{label}]'))
        else:
            self.fragments.append(self.get_starttag_text())

    def handle_startendtag(self, tag, attrs):
        self.handle_starttag(tag, attrs)

    def handle_endtag(self, tag):
        self.fragments.append(f'</{tag}>')

    def handle_data(self, data):
        self.fragments.append(data)

    def handle_entityref(self, name):
        self.fragments.append(f'&{name};')

    def handle_charref(self, name):
        self.fragments.append(f'&#{name};')


def _link_attribute(tag: str, attribute: str, value: str) -> str | None:
    if attribute != 'href':
        return value
    # nh3's callback is a URL input boundary. A retained href is for user navigation,
    # not permission to load resources; the App enforces network/gesture isolation.
    if re.search(r'[\x00-\x20\x7f\\]', value):
        return None
    try:
        parsed = urlsplit(value)
        host = unquote(parsed.hostname or '')
        parsed.port  # reject malformed/out-of-range ports, without classifying hosts
    except ValueError:
        return None
    if (parsed.scheme.lower() not in {'http', 'https'} or not host.strip('.')
            or re.search(r'[\s\x00-\x1f\x7f/\\?#@%<>\[\]]', host)):
        return None
    return value


CLEANER = nh3.Cleaner(tags=TAGS, clean_content_tags=DROP_CONTENT,
                      attributes={'a': {'href', 'title'}, 'td': {'colspan', 'rowspan'},
                                  'th': {'colspan', 'rowspan'}},
                      attribute_filter=_link_attribute, url_schemes={'http', 'https'},
                      url_relative='deny', link_rel='noopener noreferrer', strip_comments=True)


def sanitize_html(source: str, limits: MailLimits = MailLimits()) -> str:
    if len(source.encode('utf-8')) > limits.max_body_bytes:
        raise MailError('body_too_large')
    parser = _ImagePlaceholders()
    parser.feed(source)
    parser.close()
    return CLEANER.clean(''.join(parser.fragments))


def render_body(raw: RawBody) -> str:
    return sanitize_html(raw.source) if raw.kind == 'html' else raw.source
