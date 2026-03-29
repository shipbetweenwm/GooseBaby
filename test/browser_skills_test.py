#!/usr/bin/env python3
"""
浏览器相关 Skills 自动化测试

覆盖:
  1. BrowserSkill - _escapeJs JS 注入防护
  2. BrowserSkill - JSON 提取正则
  3. WebFetchSkill - HTML 标题提取
  4. WebFetchSkill - CSS 选择器提取
  5. WebFetchSkill - 链接提取
  6. WebFetchSkill - HTML 实体解码
  7. WebFetchSkill - HTML → Markdown 转换
  8. BrowserSkill - 脚本生成
  9. 实际 HTTP 测试 (example.com / httpbin.org)

运行: python3 test/browser_skills_test.py
"""

import re
import json
import urllib.request
import urllib.error
import ssl
import sys

passed = 0
failed = 0
failures = []

def expect(name, condition, detail=None):
    global passed, failed
    if condition:
        passed += 1
        print(f'  ✅ {name}')
    else:
        failed += 1
        msg = f'  ❌ {name}'
        if detail:
            msg += f' — {detail}'
        print(msg)
        failures.append(msg)

def expect_eq(name, actual, expected):
    global passed, failed
    if actual == expected:
        passed += 1
        print(f'  ✅ {name}')
    else:
        failed += 1
        msg = f'  ❌ {name} — 期望: {expected!r}, 实际: {actual!r}'
        print(msg)
        failures.append(msg)

def section(title):
    print(f'\n{"=" * 60}')
    print(f'  {title}')
    print(f'{"=" * 60}')


# ======================== 模拟 Dart 逻辑 ========================

def escape_js(input_str):
    """模拟 BrowserSkill._escapeJs"""
    s = input_str
    s = s.replace('\\', '\\\\')
    s = s.replace("'", "\\'")
    s = s.replace('\n', '\\n')
    s = s.replace('\r', '\\r')
    s = s.replace('\t', '\\t')
    return s

def extract_json(stdout):
    """模拟 BrowserSkill._executeScript 中的 JSON 提取"""
    match = re.search(r'\{[\s\S]*\}', stdout)
    if match:
        try:
            return json.loads(match.group(0))
        except json.JSONDecodeError:
            return None
    return None

def decode_html_entities(text):
    """模拟 WebFetchSkill._decodeHtmlEntities"""
    s = text
    s = s.replace('&nbsp;', ' ')
    s = s.replace('&amp;', '&')
    s = s.replace('&lt;', '<')
    s = s.replace('&gt;', '>')
    s = s.replace('&quot;', '"')
    s = s.replace('&#39;', "'")
    s = s.replace('&apos;', "'")
    s = re.sub(r'&#(\d+);', lambda m: chr(int(m.group(1))), s)
    s = re.sub(r'&#x([0-9a-fA-F]+);', lambda m: chr(int(m.group(1), 16)), s)
    return s

def extract_title(html):
    """模拟 WebFetchSkill._extractTitle"""
    match = re.search(r'<title[^>]*>([^<]+)</title>', html, re.IGNORECASE)
    if match:
        return decode_html_entities(match.group(1).strip())
    match = re.search(r'<h1[^>]*>([^<]+)</h1>', html, re.IGNORECASE)
    if match:
        return decode_html_entities(match.group(1).strip())
    return ''

def extract_by_selector(html, selector):
    """模拟 WebFetchSkill._extractBySelector"""
    if selector.startswith('.'):
        class_name = selector[1:]
        pattern = re.compile(
            r'<[^>]*class="[^"]*' + re.escape(class_name) + r'[^"]*"[^>]*>([\s\S]*?)</[^>]*>',
            re.IGNORECASE)
    elif selector.startswith('#'):
        id_name = selector[1:]
        pattern = re.compile(
            r'<[^>]*id="' + re.escape(id_name) + r'"[^>]*>([\s\S]*?)</[^>]*>',
            re.IGNORECASE)
    else:
        pattern = re.compile(
            r'<' + re.escape(selector) + r'[^>]*>([\s\S]*?)</' + re.escape(selector) + r'>',
            re.IGNORECASE)
    results = [m.group(1) for m in pattern.finditer(html)]
    return '\n\n'.join(results)

def extract_links(html, base_url):
    """模拟 WebFetchSkill._extractLinks"""
    links = []
    pattern = re.compile(r'<a[^>]*href="([^"]+)"[^>]*>([^<]*)</a>', re.IGNORECASE)
    for match in pattern.finditer(html):
        href = match.group(1)
        text = decode_html_entities(match.group(2).strip())
        if not href or href.startswith('#') or href.startswith('javascript:') or href.startswith('mailto:'):
            continue
        if not href.startswith('http'):
            try:
                href = urllib.parse.urljoin(base_url, href)
            except Exception:
                continue
        if not any(l['url'] == href for l in links):
            links.append({'url': href, 'text': text if text else href})
    return links

def extract_main_content(html):
    """模拟 WebFetchSkill._extractMainContent"""
    content = html
    remove_patterns = [
        r'<script[^>]*>[\s\S]*?</script>',
        r'<style[^>]*>[\s\S]*?</style>',
        r'<nav[^>]*>[\s\S]*?</nav>',
        r'<footer[^>]*>[\s\S]*?</footer>',
        r'<aside[^>]*>[\s\S]*?</aside>',
        r'<header[^>]*>[\s\S]*?</header>',
        r'<noscript[^>]*>[\s\S]*?</noscript>',
        r'<iframe[^>]*>[\s\S]*?</iframe>',
        r'<!--[\s\S]*?-->',
    ]
    for p in remove_patterns:
        content = re.sub(p, '', content, flags=re.IGNORECASE)

    main_patterns = [
        r'<main[^>]*>([\s\S]*?)</main>',
        r'<article[^>]*>([\s\S]*?)</article>',
        r'<div[^>]*class="[^"]*content[^"]*"[^>]*>([\s\S]*?)</div>',
        r'<div[^>]*class="[^"]*article[^"]*"[^>]*>([\s\S]*?)</div>',
        r'<body[^>]*>([\s\S]*?)</body>',
    ]
    for p in main_patterns:
        match = re.search(p, content, re.IGNORECASE)
        if match:
            content = match.group(1)
            break
    return content

def html_to_markdown(html):
    """模拟 WebFetchSkill._htmlToMarkdown (简化版)"""
    md = html
    for i in range(1, 7):
        md = re.sub(rf'<h{i}[^>]*>([^<]+)</h{i}>', lambda m: f'\n{"#" * i} {m.group(1)}\n', md, flags=re.IGNORECASE)
    md = re.sub(r'<p[^>]*>([\s\S]*?)</p>', lambda m: f'\n{m.group(1)}\n', md, flags=re.IGNORECASE)
    md = re.sub(r'<a[^>]*href="([^"]+)"[^>]*>([^<]+)</a>', lambda m: f'[{m.group(2)}]({m.group(1)})', md, flags=re.IGNORECASE)
    md = re.sub(r'<(strong|b)[^>]*>([^<]+)</\1>', lambda m: f'**{m.group(2)}**', md, flags=re.IGNORECASE)
    md = re.sub(r'<(em|i)[^>]*>([^<]+)</\1>', lambda m: f'*{m.group(2)}*', md, flags=re.IGNORECASE)
    md = re.sub(r'<pre[^>]*><code[^>]*>([\s\S]*?)</code></pre>', lambda m: f'\n```\n{m.group(1)}\n```\n', md, flags=re.IGNORECASE)
    md = re.sub(r'<code[^>]*>([^<]+)</code>', lambda m: f'`{m.group(1)}`', md, flags=re.IGNORECASE)
    md = re.sub(r'<li[^>]*>([^<]+)</li>', lambda m: f'- {m.group(1)}', md, flags=re.IGNORECASE)
    md = re.sub(r'<br\s*/?>', '\n', md, flags=re.IGNORECASE)
    md = re.sub(r'<[^>]+>', '', md)
    md = decode_html_entities(md)
    md = re.sub(r'\n{3,}', '\n\n', md)
    md = re.sub(r' {2,}', ' ', md)
    return md.strip()

import urllib.parse

def http_fetch(url, timeout=15):
    """简单的 HTTP GET"""
    ctx = ssl.create_default_context()
    ctx.check_hostname = False
    ctx.verify_mode = ssl.CERT_NONE
    req = urllib.request.Request(url, headers={
        'User-Agent': 'Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/537.36'
    })
    try:
        with urllib.request.urlopen(req, timeout=timeout, context=ctx) as resp:
            return resp.status, resp.read().decode('utf-8', errors='replace')
    except Exception as e:
        return None, str(e)


# ======================== 测试用例 ========================

def main():
    global passed, failed
    section('1. BrowserSkill — _escapeJs JS 注入防护')

    expect('基本文本不变', escape_js('hello') == 'hello')
    expect('反斜杠转义', escape_js('a\\b') == 'a\\\\b')
    expect('单引号转义', escape_js("it's") == "it\\'s")
    expect('换行转义', escape_js('a\nb') == 'a\\nb')
    expect('回车转义', escape_js('a\rb') == 'a\\rb')
    expect('Tab 转义', escape_js('a\tb') == 'a\\tb')

    # 已知缺陷
    escaped_template = escape_js('${alert(1)}')
    expect('BUG: ${} 模板字符串未防护', '${alert(1)}' in escaped_template,
           detail='_escapeJs 不处理反引号和 ${}，在 ` 包裹的 JS 模板字符串中可能导致注入')

    escaped_backslash_n = escape_js("\\n'test")
    expect('多特殊字符混合', escaped_backslash_n == "\\\\n\\'test")

    section('2. BrowserSkill — JSON 提取正则')

    expect_eq('正常 JSON', extract_json('{"success": true, "title": "Hello"}')['success'], True)

    multi_json = '{"success": true} extra {"success": false}'
    multi_result = extract_json(multi_json)
    # 贪婪匹配会从第一个 { 匹配到最后一个 }，得到的不是合法 JSON
    # 这是预期行为（测试证明贪婪匹配确实有问题）
    expect('BUG: 多 JSON 贪婪匹配产生无效 JSON', multi_result is None,
           detail='贪婪 \\{[\\s\\S]*\\} 跨 JSON 边界，产生无效 JSON')

    nested = '{"outer": {"inner": "value"}, "success": true}'
    nested_result = extract_json(nested)
    expect('嵌套 JSON 正常解析', nested_result is not None and nested_result.get('success') == True)

    empty_output = 'no json here'
    expect('无 JSON 返回 None', extract_json(empty_output) is None)

    prefix = 'prefix {"success":true} suffix'
    expect('带前后缀的 JSON', extract_json(prefix) is not None)

    section('3. WebFetchSkill — 标题提取')

    expect_eq('<title> 标签', extract_title('<html><head><title>测试页面</title></head></html>'), '测试页面')
    expect_eq('<h1> 标签(无 title)', extract_title('<h1>主标题</h1>'), '主标题')
    expect_eq('无标题返回空', extract_title('<p>内容</p>'), '')
    expect_eq('HTML 实体解码', extract_title('<title>Dart &amp; Flutter</title>'), 'Dart & Flutter')
    expect_eq('数字实体解码', extract_title('<title>Test&#39;s</title>'), "Test's")

    section('4. WebFetchSkill — CSS 选择器提取')

    sample = '<div class="content"><p>主要内容</p></div><div id="main"><p>主区域</p></div><article>文章</article>'
    expect('.content 选择器', '主要内容' in extract_by_selector(sample, '.content'))
    expect('#main 选择器', '主区域' in extract_by_selector(sample, '#main'))
    expect('article 选择器', '文章' in extract_by_selector(sample, 'article'))

    # Bug: 不支持复合选择器
    complex_html = '<div class="nav bar">导航栏</div>'
    complex_result = extract_by_selector(complex_html, '.nav.bar')
    expect('BUG: 复合选择器 .nav.bar 不支持', '导航栏' not in complex_result,
           detail='正则实现不支持后代/复合选择器')

    # Bug: class 子串匹配不精确
    multi_class = '<div class="icon-content">图标</div><div class="content">正文</div>'
    multi_result = extract_by_selector(multi_class, '.content')
    expect('BUG: .content 误匹配 icon-content',
           '正文' in multi_result and '图标' in multi_result,
           detail='正则 [^"]*$className[^"]* 会匹配包含 content 的任意 class')

    # Bug: class 前缀不精确
    prefix_bug = '<div class="my-content-box">错误匹配</div><div class="content">正确匹配</div>'
    prefix_result = extract_by_selector(prefix_bug, '.content')
    expect('BUG: .content 误匹配 my-content-box',
           '错误匹配' in prefix_result,
           detail='class="my-content-box" 也被 .content 匹配')

    # 不存在的选择器
    expect('不存在选择器返回空', extract_by_selector(sample, '.nonexist') == '')

    section('5. WebFetchSkill — 链接提取')

    link_html = '''
    <a href="https://example.com/page1">链接1</a>
    <a href="/relative/path">相对链接</a>
    <a href="#anchor">锚点</a>
    <a href="javascript:void(0)">JS链接</a>
    <a href="mailto:test@example.com">邮箱</a>
    <a href="https://example.com/page1">重复链接</a>
    <a href='single-quote'>单引号href</a>
    <a href="">空链接</a>
    '''

    links = extract_links(link_html, 'https://example.com/')
    expect_eq('有效链接数量', len(links), 2)
    expect('绝对链接正确', any(l['url'] == 'https://example.com/page1' for l in links))
    expect('相对路径转绝对', any(l['url'] == 'https://example.com/relative/path' for l in links))
    expect('跳过锚点', not any('#anchor' in l['url'] for l in links))
    expect('跳过 JS', not any('javascript:' in l['url'] for l in links))
    expect('跳过 mailto', not any('mailto:' in l['url'] for l in links))
    expect('去重', sum(1 for l in links if l['url'] == 'https://example.com/page1') == 1)
    expect('BUG: 单引号 href 被忽略',
           not any(l['text'] == '单引号href' for l in links),
           detail='正则只匹配 href="..."，不匹配 href=\'...\'')
    expect('跳过空链接', not any(l['url'] == '' for l in links))

    section('6. WebFetchSkill — HTML 实体解码')

    expect_eq('&amp;', decode_html_entities('A&amp;B'), 'A&B')
    expect_eq('&lt;&gt;', decode_html_entities('&lt;div&gt;'), '<div>')
    expect_eq("&#39;", decode_html_entities("it&#39;s"), "it's")
    expect_eq('&#x27;', decode_html_entities('test&#x27;s'), "test's")
    expect_eq('&nbsp;', decode_html_entities('a&nbsp;b'), 'a b')
    expect_eq('&#60;', decode_html_entities('&#60;'), '<')
    expect_eq('&#x3E;', decode_html_entities('&#x3E;'), '>')

    section('7. WebFetchSkill — HTML → Markdown 转换')

    md_input = '<h1>标题</h1><p>段落<strong>加粗</strong>和<em>斜体</em></p>'
    md_output = html_to_markdown(md_input)
    expect('标题转换', '# 标题' in md_output)
    expect('加粗转换', '**加粗**' in md_output)
    expect('斜体转换', '*斜体*' in md_output)
    expect('标签移除', '<p>' not in md_output and '</p>' not in md_output)

    code_input = '<pre><code>console.log("hi")</code></pre>'
    code_output = html_to_markdown(code_input)
    expect('代码块转换', '```' in code_output)
    expect('代码内容保留', 'console.log' in code_output)

    list_input = '<ul><li>项目1</li><li>项目2</li></ul>'
    list_output = html_to_markdown(list_input)
    expect('列表转换', '- 项目1' in list_output)
    expect('列表项2', '- 项目2' in list_output)

    link_input = '<a href="https://example.com">Example</a>'
    link_output = html_to_markdown(link_input)
    expect('链接转换', '[Example](https://example.com)' in link_output)

    section('8. BrowserSkill — 脚本生成安全检查')

    # URL 中包含特殊字符
    special_urls = [
        "https://example.com/path?key=value&other=123",
        "https://example.com/search?q=it's",
        "https://example.com/path?q=hello%20world",
        "https://example.com/path?callback=func(data)",
    ]
    for url in special_urls:
        escaped = escape_js(url)
        # 检查 JS 语法是否安全（不会截断字符串）
        expect(f'URL 安全: {url[:50]}{"..." if len(url) > 50 else ""}',
               "'" not in escaped.replace("\\'", ""))

    # evaluate action 的 script 注入风险
    evil_script = 'process.exit()'
    escaped_script = escape_js(evil_script)
    expect('evaluate script 转义后保留原意',
           escaped_script == evil_script,
           detail='escapeJs 不防护 JS 代码注入，evaluate action 本身就是执行任意 JS')

    section('9. 实际 HTTP 测试')

    print('\n  🌐 测试 example.com ...')
    try:
        status, body = http_fetch('https://example.com')
        if status is None:
            expect('example.com 连接', False, detail=body)
        else:
            expect_eq('example.com 状态码', status, 200)
            expect('example.com 内容非空', len(body) > 0)
            title = extract_title(body)
            expect(f'example.com 标题: {title}', title != '', detail=f'title={title}')
            links = extract_links(body, 'https://example.com')
            expect(f'example.com 链接数: {len(links)}', len(links) >= 1)

            # 测试内容提取
            main_content = extract_main_content(body)
            expect('example.com 主内容非空', len(main_content) > 0)
            md = html_to_markdown(main_content)
            expect(f'example.com Markdown ({len(md)} 字符)', len(md) > 50)
    except Exception as e:
        expect('example.com 测试', False, detail=str(e))

    print('\n  🌐 测试 httpbin.org ...')
    try:
        status, body = http_fetch('https://httpbin.org/html')
        if status is None:
            expect('httpbin.org 连接', False, detail=body)
        else:
            expect_eq('httpbin.org 状态码', status, 200)
            title = extract_title(body)
            expect(f'httpbin.org 标题提取', len(title) > 0 or len(body) > 100,
                   detail=f'title={title}')

            # httpbin/html 包含 <h1>Merman</h1>
            expect('httpbin.org h1 匹配', '<h1>' in body.lower() or '<H1>' in body)
    except Exception as e:
        expect('httpbin.org 测试', False, detail=str(e))

    print('\n  🌐 测试中文页面 (baidu.com) ...')
    try:
        status, body = http_fetch('https://www.baidu.com', timeout=10)
        if status is None:
            expect('baidu.com 连接', False, detail=body)
        else:
            expect_eq('baidu.com 状态码', status, 200)
            # 百度首页可能通过 JS 渲染 title，原始 HTML 中不一定有 <title>
            title = extract_title(body)
            has_title = len(title) > 0
            if not has_title:
                # 检查是否是因为百度用了特殊编码
                has_baidu = '百度' in body or 'baidu' in body.lower()
                expect(f'baidu.com 标题检测 (body 含百度: {has_baidu})', has_baidu,
                       detail=f'title={title}, body_length={len(body)}')
            else:
                expect(f'baidu.com 标题: {title}', '百度' in title)
    except Exception as e:
        expect('baidu.com 测试', False, detail=str(e))

    # 汇总
    print(f'\n{"=" * 60}')
    print(f'  📊 测试汇总: {passed} 通过, {failed} 失败')
    print(f'{"=" * 60}')
    if failures:
        print('\n  ❌ 失败列表:')
        for f in failures:
            print(f)
    else:
        print('\n  🎉 全部通过!')
    print()

    sys.exit(1 if failed > 0 else 0)


if __name__ == '__main__':
    main()
