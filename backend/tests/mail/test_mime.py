import base64
from email.header import Header

import pytest
from imapclient.response_types import BodyData

from feishu_lite.mail.mime import parse_headers, decode_text, normalize_structure, select_body, decode_body, parse_messages
from feishu_lite.mail.html import sanitize_html
from feishu_lite.mail.types import MailError, MailLimits


def text(subtype=b'PLAIN',params=None,disposition=None,size=10,encoding=b'8BIT',cid=None):
    return (b'TEXT',subtype,params,cid,None,encoding,size,1,None,disposition)


def multi(*parts,subtype=b'MIXED',params=None,disposition=None):
    return BodyData.create((*parts,subtype,params,disposition))


def test_headers_rfc2047_addresses_and_undeclared_gbk():
    raw = b'From: =?utf-8?b?5ZCI5oiQ?= <sender@example.invalid>\r\nTo: reader@example.invalid\r\nCc: cc@example.invalid\r\nSubject: ' + '中文主题'.encode('gbk') + b'\r\nMessage-ID: <synthetic@example.invalid>\r\n\r\n'
    header = parse_headers(raw)
    assert header.subject == '中文主题'
    assert header.sender[0].name == '合成'
    assert header.to[0].address == 'reader@example.invalid'
    assert header.cc[0].address == 'cc@example.invalid'
    assert header.message_id == '<synthetic@example.invalid>'


@pytest.mark.parametrize('charset',[None,'gb2312','gbk'])
def test_chinese_body_encoding(charset):
    assert decode_text('中文💡'.encode('gb18030'),charset) == '中文💡'


def test_alternative_related_root_and_ignore_attachments_forwarded_subtrees():
    forwarded = (b'MESSAGE',b'RFC822',None,None,None,b'7BIT',20,None,text(b'HTML'),1)
    tree = multi(text(disposition=(b'ATTACHMENT',(b'FILENAME',b'ignore.txt'))),forwarded,
                 multi(text(),text(b'HTML'),subtype=b'ALTERNATIVE'))
    normalized = normalize_structure(tree)
    selected = select_body(normalized)
    assert selected.body.section == '3.2' and selected.body.media_type == 'text/html'
    assert len(selected.attachments) == 2
    related = multi(text(b'HTML',cid=b'<wrong>'),text(b'PLAIN',cid=b'<root>'),subtype=b'RELATED',params=(b'START',b'<root>'))
    assert select_body(normalize_structure(related)).body.section == '2'
    assert select_body(normalize_structure(BodyData.create(text()))).body.section == '1'


def test_nested_related_section_and_inline_cid_metadata():
    image = (b'IMAGE',b'PNG',None,b'<img>',None,b'BASE64',512,None,(b'INLINE',(b'FILENAME',b'inline.png')))
    tree = multi(multi(text(b'HTML'),image,subtype=b'RELATED'),text(disposition=(b'ATTACHMENT',None)))
    result = select_body(normalize_structure(tree))
    assert result.body.section == '1.1'
    assert result.attachments[0].content_id == 'img'
    assert result.attachments[0].encoded_size == 512 and result.attachments[0].size_is_approximate


def test_rfc2231_and_rfc2047_attachment_filenames():
    encoded = str(Header('合成附件.txt','utf-8').encode()).encode()
    a = text(disposition=(b'ATTACHMENT',(b'FILENAME*',b"utf-8''%E5%90%88%E6%88%90.txt")))
    b = text(disposition=(b'ATTACHMENT',(b'FILENAME',encoded)))
    c = text(disposition=(b'ATTACHMENT',(b'FILENAME*0*',b"utf-8''%E5%90%88",b'FILENAME*1*',b'%E6%88%90.txt')))
    result = select_body(normalize_structure(multi(text(),a,b,c)))
    assert [x.filename for x in result.attachments] == ['合成.txt','合成附件.txt','合成.txt']


def test_transfer_encoding_and_rendered_html():
    selection = select_body(normalize_structure(BodyData.create(text(b'HTML',encoding=b'BASE64'))))
    raw = decode_body(selection.body,base64.b64encode(b'<b>safe</b><img src="cid:img">'))
    assert raw.kind == 'html' and '<img' in raw.source
    assert sanitize_html(raw.source) == '<b>safe</b>[图片已阻止]'


@pytest.mark.parametrize('payload',[b'%%%!',b'YQ=',b'\xff'])
def test_bad_base64_has_structured_error(payload):
    part = select_body(normalize_structure(BodyData.create(text(encoding=b'BASE64')))).body
    with pytest.raises(MailError,match='malformed_mime'):
        decode_body(part,payload)


@pytest.mark.parametrize('html',[
    '<script>evil()</script><p onclick="evil()">safe</p>',
    '<iframe src="https://bad.invalid">evil</iframe><p>safe</p>',
    '<form action="http://bad.invalid"><input autofocus>evil</form><p>safe</p>',
    '<meta http-equiv="refresh" content="0;url=http://bad.invalid"><base href="http://bad.invalid"><p>safe</p>',
    '<style>body{background:url(http://bad.invalid)}</style><p style="background:url(file:///secret)">safe</p>',
    '<svg onload="evil()"><a href="javascript:evil()">evil</a></svg><p>safe</p>',
])
def test_html_removes_active_content_and_keeps_readable_text(html):
    cleaned = sanitize_html(html)
    assert 'safe' in cleaned
    assert all(token not in cleaned for token in ['evil','bad.invalid','onclick','style=','<form','<svg','<iframe','<script'])


@pytest.mark.parametrize('url',['javascript:alert(1)','data:text/html,x','file:///secret','cid:img','/relative','//remote.invalid','mailto:a@example.invalid'])
def test_html_non_http_and_relative_links_have_no_href(url):
    assert 'href=' not in sanitize_html(f'<a href="{url}">link</a>')


def test_html_keeps_http_https_user_links_and_blocks_resources():
    cleaned = sanitize_html('<a href="https://example.invalid/page" target="_blank">click</a><a href="http://example.invalid">http</a><img src="https://bad.invalid" alt="chart"><img src="cid:one"><video src="file:///x"></video>')
    assert 'href="https://example.invalid/page"' in cleaned and 'href="http://example.invalid"' in cleaned
    assert 'src=' not in cleaned and 'target=' not in cleaned and '<img' not in cleaned
    assert 'chart' in cleaned and '[图片已阻止]' in cleaned


def test_structure_limits_malformed_and_no_body_are_explicit():
    with pytest.raises(MailError,match='too_many_parts'):
        normalize_structure(multi(text(),text()),MailLimits(max_parts=2))
    with pytest.raises(MailError,match='mime_too_deep'):
        normalize_structure(multi(multi(text())),MailLimits(max_depth=2))
    with pytest.raises(MailError,match='malformed_mime'):
        normalize_structure((b'TEXT',))
    result = select_body(normalize_structure(BodyData.create(text(disposition=(b'ATTACHMENT',None)))))
    assert result.body is None and len(result.attachments) == 1


def test_response_header_and_body_limits_and_single_mail_failure():
    with pytest.raises(MailError,match='response_too_large'):
        normalize_structure(BodyData.create(text(params=(b'CHARSET',b'x'*100))),MailLimits(max_response_bytes=10))
    with pytest.raises(MailError,match='headers_too_large'):
        parse_headers(b'Subject: hello\r\n',MailLimits(max_header_bytes=5))
    part = select_body(normalize_structure(BodyData.create(text()))).body
    with pytest.raises(MailError,match='body_too_large'):
        decode_body(part,b'hello',MailLimits(max_body_bytes=4))
    results = parse_messages([((b'TEXT',),{}),(BodyData.create(text()),{'1':b'hello'})])
    assert results[0].error == 'malformed_mime'
    assert results[1].body.source == 'hello' and results[1].error is None


def test_attachment_name_content_type_fallback_and_multipart_unknown_size():
    part = text(params=(b'NAME',b'fallback.txt'),disposition=(b'ATTACHMENT',(b'CREATION-DATE',b'date')))
    attached_multi = multi(text(),subtype=b'MIXED',disposition=(b'ATTACHMENT',None))
    result = select_body(normalize_structure(multi(text(),part,attached_multi)))
    assert result.attachments[0].filename == 'fallback.txt'
    assert result.attachments[1].encoded_size is None


def test_noncanonical_ids_and_wrong_tokens_remain_rejected():
    from feishu_lite.mail.types import MailKey
    # Canonical base64 does not make whitespace-altered JSON acceptable.
    raw = b'[1, "message", "a", "INBOX", 10, 1]'
    with pytest.raises(MailError,match='invalid_id'):
        MailKey.from_id(base64.urlsafe_b64encode(raw).decode().rstrip('='))


def test_quoted_printable_unknown_charset_and_attachment_not_decoded():
    raw = text(params=(b'CHARSET',b'GB2312'),encoding=b'QUOTED-PRINTABLE')
    selected = select_body(normalize_structure(BodyData.create(raw)))
    assert decode_body(selected.body,b'=D6=D0=CE=C4').source == '中文'
    with pytest.raises(MailError,match='malformed_mime'):
        decode_body(selected.body,b'=nothex')
    with pytest.raises(MailError,match='unsupported_charset'):
        decode_text(b'x','made-up-charset')
    forwarded = (b'MESSAGE',b'RFC822',None,None,None,b'7BIT',100,None,text(b'HTML'),1)
    results = parse_messages([(multi(text(),forwarded),{'1':b'visible','2':b'not a forwarded body'})])
    assert results[0].body.source == 'visible'


@pytest.mark.parametrize('html',[
    '<math><mtext><table><mglyph><style><!--</style><img title="--><img src=x onerror=alert(1)>">',
    '<svg><style><a id="</style><img src=\"file:///secret\" onerror=alert(1)>">',
    '<a href="jav&#x61;script:alert(1)" onclick="x()">safe</a>',
    '<a href="https://example.invalid" ping="http://bad.invalid" download="x">safe</a>',
    '<img srcset="https://bad.invalid/x 1x" alt="&lt;script&gt;">',
])
def test_malformed_html_cannot_escape_allowlist(html):
    from html.parser import HTMLParser
    seen = []
    class Audit(HTMLParser):
        def handle_starttag(self,tag,attrs):
            seen.append((tag,dict(attrs)))
    cleaned = sanitize_html(html)
    Audit().feed(cleaned)
    assert all(tag not in {'img','script','svg','math','style','iframe'} for tag,_ in seen)
    assert all(not any(k.startswith('on') or k in {'src','srcset','style','ping','download'} for k in attrs) for _,attrs in seen)
    assert all(not attrs.get('href','').lower().startswith(('javascript:','file:')) for _,attrs in seen)


def test_malformed_rfc2231_isolated_without_leaking_raw_exception():
    bad = text(disposition=(b'ATTACHMENT',(b'FILENAME*',"utf-8''合成".encode())))
    result = parse_messages([(multi(text(),bad),{'1':b'hello'}),(BodyData.create(text()),{'1':b'valid'})])
    assert result[0].error == 'malformed_mime'
    assert result[1].body.source == 'valid'


def test_imapclient_actual_fetch_parser_contract_selects_peek_section():
    from imapclient.response_parser import parse_fetch_response
    wire = [b'7 (UID 42 BODYSTRUCTURE (("TEXT" "PLAIN" ("CHARSET" "UTF-8") NIL NIL "7BIT" 5 1)("TEXT" "HTML" ("CHARSET" "UTF-8") NIL NIL "7BIT" 12 1) "ALTERNATIVE"))']
    data = parse_fetch_response(wire)
    structure = data[42][b'BODYSTRUCTURE']
    assert isinstance(structure,BodyData) and isinstance(structure[0],list)
    selected = select_body(normalize_structure(structure))
    assert selected.body.section == '2' and selected.body.media_type == 'text/html'
    assert decode_body(selected.body,b'<b>hello</b>').source == '<b>hello</b>'


@pytest.mark.parametrize('url',[
    'http://127.0.0.1:1234/token', 'http://10.0.0.8/wiki',
    'https://[::1]:8443/page', 'http://intranet/path',
    'https://work.internal/guide', 'http://service.local/page',
    'https://localhost/page', 'https://app.team.localhost/page',
])
def test_user_clicked_http_links_keep_valid_ip_and_intranet_hosts(url):
    assert f'href="{url}"' in sanitize_html(f'<a href="{url}">work link</a>')


@pytest.mark.parametrize('url',[
    'https:///no-host', 'http://', 'http://:8080/path', 'http://[broken',
    'http://example.invalid:not-a-port', 'http://example.invalid:99999',
    'http://bad host/path', 'http://bad%20host/path', 'http://./path',
])
def test_malformed_http_links_are_removed_without_failing_the_mail(url):
    cleaned = sanitize_html(f'<p>safe</p><a href="{url}">link</a>')
    assert 'href=' not in cleaned and '<p>safe</p>' in cleaned
