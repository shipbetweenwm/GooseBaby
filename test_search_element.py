#!/usr/bin/env python3
"""遍历前台应用 UI 树，查找包含指定关键词的组件（增强版）"""

import sys
import time
import subprocess

try:
    from AppKit import NSWorkspace
    from ApplicationServices import (
        AXUIElementCreateApplication, AXUIElementCopyAttributeNames,
        AXUIElementCopyAttributeValue,
        kAXChildrenAttribute, kAXRoleAttribute, kAXTitleAttribute,
        kAXValueAttribute, kAXPositionAttribute, kAXSizeAttribute,
        kAXDescriptionAttribute, kAXHelpAttribute, kAXPlaceholderValueAttribute,
        kAXFocusedAttribute, kAXSelectedTextAttribute,
    )
except ImportError:
    print("❌ 需要 pyobjc: pip install pyobjc")
    sys.exit(1)

KEYWORD = sys.argv[1] if len(sys.argv) > 1 else "小黑板"

print(f"⏳ 3 秒后开始检测，请切换到目标应用...")
time.sleep(3)

# ── 获取前台应用 ──
front_app = NSWorkspace.sharedWorkspace().frontmostApplication()
if not front_app:
    print("❌ 没有前台应用")
    sys.exit(1)

pid = int(front_app.processIdentifier())
name = front_app.localizedName() or "?"
print(f"前台应用: {name} (PID: {pid})")
print(f"搜索关键词: \"{KEYWORD}\"")


def _get_attr(element, attr):
    try:
        v = None
        err, v = AXUIElementCopyAttributeValue(element, attr, None)
        return v if err == 0 else None
    except:
        return None


def _get_point(element):
    try:
        v = _get_attr(element, kAXPositionAttribute)
        if v:
            from ApplicationServices import AXValueGetValue, kAXValueCGPointType
            pt = (0.0, 0.0)
            AXValueGetValue(v, kAXValueCGPointType, pt)
            return (pt[0], pt[1])
    except:
        pass
    return None


def _get_size(element):
    try:
        v = _get_attr(element, kAXSizeAttribute)
        if v:
            from ApplicationServices import AXValueGetValue, kAXValueCGSizeType
            sz = (0.0, 0.0)
            AXValueGetValue(v, kAXValueCGSizeType, sz)
            return (sz[0], sz[1])
    except:
        pass
    return None


def _get_all_text_attrs(element):
    """获取元素所有可能包含文本的属性"""
    texts = []
    # 标准属性
    for attr in [kAXTitleAttribute, kAXValueAttribute, kAXDescriptionAttribute,
                 kAXHelpAttribute, kAXPlaceholderValueAttribute, kAXSelectedTextAttribute]:
        v = _get_attr(element, attr)
        if v and str(v).strip():
            texts.append(str(v).strip())

    # 获取所有属性名，检查是否有其他包含文本的属性
    try:
        err, attr_names = AXUIElementCopyAttributeNames(element, None)
        if err == 0 and attr_names:
            # 常见的额外文本属性
            extra_attrs = ['AXText', 'AXString', 'AXLabel', 'AXLinkedText',
                          'AXAnnouncedValue', 'AXURL', 'AXAccessKey',
                          'AXDocument', 'AXWebArea', 'AXHtmlContent']
            for ea in extra_attrs:
                if ea not in attr_names:
                    continue
                v = _get_attr(element, ea)
                if v and str(v).strip():
                    texts.append(str(v).strip())
    except:
        pass

    return texts


def _search(node, path="", depth=0, results=None):
    if results is None:
        results = []
    if depth > 50:
        return results

    role = _get_attr(node, kAXRoleAttribute) or ""
    pos = _get_point(node)
    sz = _get_size(node)
    p = f"{path}/{role}" if path else role

    # 收集该节点所有文本
    texts = _get_all_text_attrs(node)
    combined = " ".join(texts)

    if KEYWORD.lower() in combined.lower():
        coord = f"({pos[0]:.0f},{pos[1]:.0f} {sz[0]:.0f}x{sz[1]:.0f})" if pos and sz else "无坐标"
        results.append({
            'depth': depth,
            'path': p,
            'role': role,
            'texts': texts,
            'coord': coord,
        })

    # 递归子节点
    children = _get_attr(node, kAXChildrenAttribute)
    if children:
        for child in children:
            _search(child, p, depth + 1, results)

    return results


# ── 方法 1：Accessibility API ──
print(f"\n🔍 方法 1: Accessibility API 遍历...")
app_elem = AXUIElementCreateApplication(pid)
results = _search(app_elem)

if results:
    print(f"✅ 找到 {len(results)} 个匹配组件:\n")
    for r in results:
        indent = "  " * min(r['depth'], 4)
        print(f"  {indent}[{r['role']}]")
        for t in r['texts']:
            print(f"    {indent}文本: \"{t}\"")
        print(f"    {indent}path: {r['path']}")
        print(f"    {indent}coord: {r['coord']}")
        print()
else:
    print("  ❌ Accessibility API 未找到匹配")

# ── 方法 2：AppleScript / UI scripting ──
print(f"\n🔍 方法 2: AppleScript 遍历...")
try:
    script = f'''
    tell application "System Events"
        tell process "{name}"
            set allElements to entire contents
            set output to ""
            repeat with elem in allElements
                try
                    set elemDesc to description of elem
                    if elemDesc contains "{KEYWORD}" then
                        set output to output & "[role=" & role of elem & "] description=\\"" & elemDesc & "\\""
                        try
                            set output to output & " pos=(" & position of elem & ")"
                        end try
                        try
                            set output to output & " size=(" & size of elem & ")"
                        end try
                        set output to output & linefeed
                    end if
                end try
                try
                    set elemTitle to name of elem
                    if elemTitle contains "{KEYWORD}" then
                        set output to output & "[role=" & role of elem & "] name=\\"" & elemTitle & "\\""
                        try
                            set output to output & " pos=(" & position of elem & ")"
                        end try
                        try
                            set output to output & " size=(" & size of elem & ")"
                        end try
                        set output to output & linefeed
                    end if
                end try
                try
                    set elemValue to value of elem
                    if elemValue is not "" and elemValue contains "{KEYWORD}" then
                        set output to output & "[role=" & role of elem & "] value=\\"" & elemValue & "\\""
                        try
                            set output to output & " pos=(" & position of elem & ")"
                        end try
                        try
                            set output to output & " size=(" & size of elem & ")"
                        end try
                        set output to output & linefeed
                    end if
                end try
            end repeat
            return output
        end tell
    end tell
    '''
    proc = subprocess.run(
        ['osascript', '-e', script],
        capture_output=True, text=True, timeout=30
    )
    output = proc.stdout.strip()
    if output:
        lines = output.strip().split('\n')
        print(f"✅ 找到 {len(lines)} 个匹配组件:\n")
        for line in lines:
            print(f"  {line}")
    else:
        if proc.returncode != 0 and proc.stderr.strip():
            print(f"  ⚠️ AppleScript 错误: {proc.stderr.strip()[:200]}")
        else:
            print("  ❌ AppleScript 未找到匹配")
except Exception as e:
    print(f"  ⚠️ AppleScript 执行失败: {e}")

# ── 方法 3：列出所有 UI 元素的 role 和文本（采样前 200 个有文本的元素） ──
print(f"\n🔍 方法 3: 列出所有含文本的元素（前 200 个）...")
sample_results = []

def _collect_all(node, path="", depth=0, results=None):
    if results is None:
        results = []
    if depth > 50 or len(results) > 200:
        return results

    role = _get_attr(node, kAXRoleAttribute) or ""
    texts = _get_all_text_attrs(node)
    pos = _get_point(node)
    sz = _get_size(node)
    p = f"{path}/{role}" if path else role

    if texts:
        combined = " ".join(texts)
        if len(combined) > 0:
            coord = f"({pos[0]:.0f},{pos[1]:.0f} {sz[0]:.0f}x{sz[1]:.0f})" if pos and sz else "无坐标"
            results.append({
                'role': role,
                'text': combined[:80],
                'path': p,
                'coord': coord,
            })

    children = _get_attr(node, kAXChildrenAttribute)
    if children:
        for child in children:
            _collect_all(child, p, depth + 1, results)
    return results

all_elements = _collect_all(app_elem)
if all_elements:
    print(f"  共 {len(all_elements)} 个含文本元素，显示前 {min(len(all_elements), 200)} 个:\n")
    for i, e in enumerate(all_elements):
        marker = " ⭐" if KEYWORD.lower() in e['text'].lower() else ""
        print(f"  {i+1:>3}. [{e['role']:<20}] \"{e['text']:<40}\" {e['coord']}{marker}")
else:
    print("  ❌ 没有找到任何含文本的元素")
