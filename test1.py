#!/usr/bin/env python3
"""
CUA SOM 测试 — AX 属性过滤方案

过滤策略（不使用面积过滤和距离合并）：
  1. 角色白名单：只保留可交互的 AXRole
  2. kAXEnabled：跳过 disabled 的控件
  3. 零尺寸过滤：跳过 width=0 或 height=0 的元素
  4. 屏幕外过滤：跳过完全在屏幕外的元素

用法：
  python3 test1.py [delay_seconds]
"""

import subprocess, sys, os, json, re, time

WORK_DIR = f"/tmp/som_test1_{os.getpid()}"
os.makedirs(WORK_DIR, exist_ok=True)
PNG_PATH = f"{WORK_DIR}/screen.png"
JPG_PATH = f"{WORK_DIR}/screen_som.jpg"

print("=" * 50)
print("  CUA SOM — AX 属性过滤方案")
print("=" * 50)

# ═══ Step 0: 等待用户切换到目标应用 ═══
DELAY = int(sys.argv[1]) if len(sys.argv) > 1 else 3
print(f"\n  ⏳ {DELAY} 秒后开始，请先切换到你要测试的目标应用...")
for i in range(DELAY, 0, -1):
    print(f"     {i}...", flush=True)
    time.sleep(1)

# ═══ Step 1: 截屏 ═══
print("\n[1/5] 截屏...")
r = subprocess.run(["screencapture", "-x", PNG_PATH], capture_output=True, text=True)
sz = os.path.getsize(PNG_PATH) if os.path.exists(PNG_PATH) else 0
if sz < 1000:
    print(f"  ❌ 截屏失败或为空 ({sz} bytes)")
    print("  请给 Terminal 授予【屏幕录制】权限:")
    print("  系统设置 → 隐私与安全性 → 屏幕录制 → 添加 Terminal")
    sys.exit(1)
print(f"  ✅ 截屏成功 ({sz:,} bytes)")

# 获取分辨率
r = subprocess.run(["sips", "-g", "pixelWidth", "-g", "pixelHeight", PNG_PATH],
                   capture_output=True, text=True)
output = (r.stdout + "\n" + r.stderr).strip()
img_w = img_h = 0
for line in output.split("\n"):
    if "pixelWidth" in line:
        parts = line.split(":")
        if len(parts) >= 2:
            try: img_w = int(parts[-1].strip())
            except: pass
    elif "pixelHeight" in line:
        parts = line.split(":")
        if len(parts) >= 2:
            try: img_h = int(parts[-1].strip())
            except: pass
if img_w <= 0 or img_h <= 0:
    try:
        from PIL import Image
        tmp = Image.open(PNG_PATH)
        img_w, img_h = tmp.size
        print(f"  ✅ Pillow 兜底读取分辨率: {img_w}x{img_h}")
    except:
        print("  ❌ 无法获取分辨率")
        sys.exit(1)

# ═══ Step 2: 检查依赖 ═══
print("\n[2/5] 检查依赖...")
try:
    from AppKit import NSWorkspace, NSScreen
    from ApplicationServices import (
        AXUIElementCreateApplication, AXUIElementCopyAttributeValue,
        kAXChildrenAttribute, kAXRoleAttribute, kAXTitleAttribute,
        kAXValueAttribute, kAXPositionAttribute, kAXSizeAttribute,
        kAXDescriptionAttribute, kAXEnabledAttribute,
        kAXRoleDescriptionAttribute,
    )
    print("  ✅ pyobjc OK")
except ImportError as e:
    print(f"  ❌ {e}")
    print("  运行: pip3 install pyobjc-framework-ApplicationServices")
    sys.exit(1)

# 尝试导入 kAXFocusedAttribute（可能不在所有版本中）
try:
    from ApplicationServices import kAXFocusedAttribute
except ImportError:
    kAXFocusedAttribute = "AXFocused"

# 获取真实屏幕逻辑分辨率
main_screen = NSScreen.mainScreen()
screen_frame = main_screen.frame()
logical_w = int(screen_frame.size.width)
logical_h = int(screen_frame.size.height)
scale_x = img_w / logical_w
scale_y = img_h / logical_h
print(f"  截图像素: {img_w}x{img_h}")
print(f"  屏幕逻辑: {logical_w}x{logical_h}")
print(f"  缩放比: {scale_x:.1f}x{scale_y:.1f}")
try:
    from PIL import Image, ImageDraw, ImageFont
    print("  ✅ Pillow OK")
except ImportError:
    print("  ❌ Pillow 缺失")
    print("  运行: pip3 install Pillow")
    sys.exit(1)

# ═══ Step 3: 获取前台应用的 UI 树 ═══
print("\n[3/5] 获取前台应用 UI 树...")

def _get_attr(element, attr):
    try:
        result = AXUIElementCopyAttributeValue(element, attr, None)
        if isinstance(result, tuple):
            err, val = result
            return val if err == 0 else None
        return result
    except:
        return None

def _parse_ax(val, p1, p2):
    """解析 AXValue (position/size)，优先用 AXValueGetValue，fallback 到正则"""
    # 方法1: 直接用 CoreFoundation AXValueGetValue
    try:
        import Quartz
        from Quartz import kAXValueTypeCGPoint, kAXValueTypeCGSize
        import ctypes
        # 尝试解析为 CGPoint
        point = Quartz.CGPoint()
        if Quartz.AXValueGetValue(val, kAXValueTypeCGPoint, ctypes.byref(point)):
            return (float(point.x), float(point.y))
        # 尝试解析为 CGSize
        size = Quartz.CGSize()
        if Quartz.AXValueGetValue(val, kAXValueTypeCGSize, ctypes.byref(size)):
            return (float(size.width), float(size.height))
    except:
        pass
    # 方法2: 正则 fallback
    try:
        desc = val.description()
        m = re.search(p1, desc)
        if m: return (float(m.group(1)), float(m.group(2)))
        m = re.search(p2, desc)
        if m: return (float(m.group(1)), float(m.group(2)))
    except:
        pass
    return None

def _get_point(e):
    p = _get_attr(e, kAXPositionAttribute)
    if p:
        r = _parse_ax(p, r'x:([-\d.]+)\s+y:([-\d.]+)', r'x:([-\d.]+),\s*y:([-\d.]+)')
        if r: return r
    return None

def _get_size(e):
    s = _get_attr(e, kAXSizeAttribute)
    if s:
        r = _parse_ax(s, r'w:([-\d.]+)\s+h:([-\d.]+)', r'width:([-\d.]+)\s+height:([-\d.]+)')
        if r: return r
    return None

# 只获取前台应用
ws = NSWorkspace.sharedWorkspace()
front_app = ws.frontmostApplication()
if not front_app:
    print("  ❌ 无前台应用")
    sys.exit(1)

app_pid = int(front_app.processIdentifier())
app_name = front_app.localizedName() or "?"
print(f"  前台应用: {app_name} (PID: {app_pid})")

app_elem = AXUIElementCreateApplication(app_pid)

test_result = _get_attr(app_elem, kAXRoleAttribute)
if test_result is None:
    print("  ❌ 辅助功能权限不足!")
    print("  请给 Terminal 授予【辅助功能】权限:")
    print("  系统设置 → 隐私与安全性 → 辅助功能 → 添加 Terminal")
    sys.exit(1)

# ═══ 可交互角色白名单 ═══
# 只有这些角色才会被标记为可交互元素
INTERACTIVE_ROLES = {
    # 按钮类
    'AXButton', 'AXMenuButton', 'AXPopUpButton', 'AXDisclosureTriangle',
    'AXSortButton', 'AXZoomButton', 'AXToggle', 'AXSwitch',
    # 输入类
    'AXTextField', 'AXTextArea', 'AXSearchField', 'AXComboBox',
    # 选择类
    'AXCheckBox', 'AXRadioButton', 'AXSlider', 'AXStepper',
    'AXIncrementor', 'AXDecrementor', 'AXPicker', 'AXTimePicker',
    'AXSegmentedControl',
    # 链接/菜单
    'AXLink', 'AXMenuItem', 'AXMenuBarItem',
    # 列表行（可点击选中）
    'AXRow', 'AXOutlineRow', 'AXCell',
    # Tab
    'AXTab', 'AXTabGroup',
    # 静态文本（可能可选中/复制）
    'AXStaticText',
    # 图片（可能是可点击图标）
    'AXImage',
    # 有些应用的可点击元素是 Group
    'AXGroup',
    # 工具栏项通常可点击
    'AXToolbar',
}

# 纯顶层容器角色（永远跳过自身，递归子节点）
# 这些角色几乎不可能直接交互
SKIP_ROLES = {
    'AXApplication', 'AXWindow',
    'AXScrollArea', 'AXScrollBar',
    'AXSplitGroup', 'AXSplitter',
    'AXLayoutArea', 'AXLayoutItem',
    'AXGrowArea',
    'AXWebArea',     # 网页容器，子元素才是真正的交互对象
    'AXOutline',
    'AXBrowser',
    'AXColumn',
}

# ═══ 递归遍历 UI 树，同时读取 AX 属性 ═══
node_count = [0]

def _node_to_dict(element, depth, max_depth, ancestor_rect=None):
    if depth > max_depth:
        return None
    node_count[0] += 1
    result = {}
    r = _get_attr(element, kAXRoleAttribute)
    t = _get_attr(element, kAXTitleAttribute)
    v = _get_attr(element, kAXValueAttribute)
    d = _get_attr(element, kAXDescriptionAttribute)
    enabled = _get_attr(element, kAXEnabledAttribute)

    result['role'] = str(r) if r else ''
    result['title'] = str(t) if t else ''
    if v and str(v).strip():
        result['value'] = str(v)[:200]
    if d and str(d).strip():
        result['description'] = str(d)[:200]
    # 记录 enabled 属性（None 表示该元素没有此属性，视为 enabled）
    if enabled is not None:
        result['enabled'] = bool(enabled)

    pos = _get_point(element)
    sz = _get_size(element)
    has_own_bounds = False
    my_rect = ancestor_rect
    if pos and sz and sz[0] > 0 and sz[1] > 0:
        result['x'], result['y'] = pos[0], pos[1]
        result['width'], result['height'] = sz[0], sz[1]
        my_rect = (pos[0], pos[1], sz[0], sz[1])
        has_own_bounds = True
    children = _get_attr(element, kAXChildrenAttribute)
    cl = []
    if children:
        for child in children:
            cd = _node_to_dict(child, depth + 1, max_depth, ancestor_rect=my_rect)
            if cd:
                cl.append(cd)
    # 没有自身坐标的叶子节点，标记为继承坐标（用于调试）
    if not has_own_bounds and not cl and ancestor_rect:
        result['x'], result['y'] = ancestor_rect[0], ancestor_rect[1]
        result['width'], result['height'] = ancestor_rect[2], ancestor_rect[3]
        result['inherited_pos'] = True
    if cl:
        result['children'] = cl
    return result

t0 = time.time()
tree = _node_to_dict(app_elem, 0, 10)
elapsed = time.time() - t0
print(f"  ✅ UI 树: {node_count[0]} 个节点, 耗时 {elapsed:.2f}s")

# 保存 UI 树 JSON
tree_path = f"{WORK_DIR}/ui_tree.json"
with open(tree_path, 'w') as f:
    json.dump(tree, f, ensure_ascii=False, indent=2)

# ═══ Step 4: AX 属性过滤提取 ═══
print("\n[4/5] AX 属性过滤提取...")

markers = []
next_id = [1]
all_nodes = []  # 记录所有节点（含过滤原因）
_seen_positions = set()  # 坐标去重

def _collect_child_text(node):
    """递归从子元素中收集可见文本"""
    texts = []
    for child in node.get('children', []):
        cr = child.get('role', '')
        t = (child.get('title') or child.get('value') or child.get('description') or '').strip()
        if t and cr in ('AXStaticText', 'AXButton', 'AXLink'):
            texts.append(t)
        elif cr in ('AXGroup', 'AXRow'):
            t2 = _collect_child_text(child)
            if t2:
                texts.append(t2)
    return ' '.join(texts)[:30]

def traverse(node, depth=0):
    """遍历节点，按 AX 属性过滤"""
    role = node.get('role', '')
    x = node.get('x')
    y = node.get('y')
    w = node.get('width', 0)
    h = node.get('height', 0)
    enabled = node.get('enabled', True)  # 默认 enabled
    label = (node.get('title') or node.get('value') or node.get('description') or '').strip()
    if not label:
        label = _collect_child_text(node)
    if len(label) > 30:
        label = label[:30] + '...'

    has_pos = x is not None and y is not None

    # ── 判断过滤原因 ──
    skip_reason = None
    if not has_pos:
        skip_reason = "无坐标"
    elif w <= 0 or h <= 0:
        skip_reason = f"零尺寸 ({w:.0f}x{h:.0f})"
    elif x < -10 or y < -10 or x >= logical_w + 10 or y >= logical_h + 10:
        skip_reason = f"屏幕外 ({x:.0f},{y:.0f})"
    elif not enabled:
        skip_reason = "disabled"
    elif role in SKIP_ROLES:
        skip_reason = f"容器角色 {role}"
    elif role not in INTERACTIVE_ROLES:
        skip_reason = f"非交互角色 {role}"
    # 继承坐标的节点：AX API 未返回真实位置，标记但不画
    elif node.get('inherited_pos'):
        skip_reason = f"继承坐标 (无自身位置)"

    # 坐标去重：多个元素共享完全相同的坐标+尺寸 → 重叠元素
    if skip_reason is None and has_pos:
        pos_key = (round(x, 1), round(y, 1), round(w, 1), round(h, 1))
        if pos_key in _seen_positions:
            skip_reason = f"坐标重复 ({x:.0f},{y:.0f} {w:.0f}x{h:.0f})"
        else:
            _seen_positions.add(pos_key)

    all_nodes.append({
        'role': role, 'title': label,
        'x': x or 0, 'y': y or 0, 'w': w, 'h': h,
        'enabled': enabled,
        'depth': depth, 'skip_reason': skip_reason,
    })

    if skip_reason is None and has_pos:
        cx = (x + w / 2) * scale_x
        cy = (y + h / 2) * scale_y
        pw = w * scale_x
        ph = h * scale_y
        markers.append({
            'id': next_id[0], 'cx': cx, 'cy': cy,
            'pw': pw, 'ph': ph,
            'role': role,
            'title': label,
        })
        next_id[0] += 1

    for child in node.get('children', []):
        traverse(child, depth + 1)

traverse(tree)
print(f"  ✅ 提取 {len(markers)} 个可交互标记")

# ═══ 坐标调试 ═══
if markers:
    min_cx = min(m['cx'] for m in markers)
    max_cx = max(m['cx'] for m in markers)
    min_cy = min(m['cy'] for m in markers)
    max_cy = max(m['cy'] for m in markers)
    print(f"\n  --- 坐标调试 ---")
    print(f"  截图像素: {img_w} x {img_h}")
    print(f"  逻辑屏幕: {logical_w} x {logical_h}")
    print(f"  缩放比: scale_x={scale_x:.2f} scale_y={scale_y:.2f}")
    print(f"  标记 cx 范围: {min_cx:.0f} ~ {max_cx:.0f} (截图宽={img_w})")
    print(f"  标记 cy 范围: {min_cy:.0f} ~ {max_cy:.0f} (截图高={img_h})")
    out_count = sum(1 for m in markers if m['cx'] < 0 or m['cx'] > img_w or m['cy'] < 0 or m['cy'] > img_h)
    print(f"  超出截图范围的标记: {out_count} / {len(markers)}")
    # 打印前5个标记的原始逻辑坐标
    print(f"  前5个标记:")
    for m in markers[:5]:
        lx = m['cx'] / scale_x - m['pw'] / scale_x / 2  # 还原逻辑坐标
        ly = m['cy'] / scale_y - m['ph'] / scale_y / 2
        print(f"    [{m['id']}] 逻辑({lx:.0f},{ly:.0f}) → 像素({m['cx']:.0f},{m['cy']:.0f}) 大小({m['pw']:.0f}x{m['ph']:.0f})")
    print(f"  ----------------")

# ═══ 打印全部节点详情（含过滤原因）═══
kept_count = sum(1 for n in all_nodes if n['skip_reason'] is None)
skipped_count = sum(1 for n in all_nodes if n['skip_reason'] is not None)
print(f"\n  --- 全部 {len(all_nodes)} 个节点 (保留 {kept_count}, 过滤 {skipped_count}) ---")

# 统计过滤原因分布
reason_counts = {}
for n in all_nodes:
    r = n['skip_reason']
    if r:
        # 归类原因
        if r.startswith("容器角色"):
            key = "容器角色"
        elif r.startswith("非交互角色"):
            key = "非交互角色"
        elif r.startswith("屏幕外"):
            key = "屏幕外"
        elif r.startswith("零尺寸"):
            key = "零尺寸"
        else:
            key = r
        reason_counts[key] = reason_counts.get(key, 0) + 1

print(f"\n  过滤原因统计:")
for reason, count in sorted(reason_counts.items(), key=lambda x: -x[1]):
    print(f"    {reason:<16} ×{count}")

print(f"\n  全部节点:")
for n in all_nodes:
    indent = "  " * n['depth']
    label = n['title'] or ''
    pos = f"({n['x']:.0f},{n['y']:.0f}) {n['w']:.0f}x{n['h']:.0f}" if n['x'] else "(无坐标)"
    en = "" if n['enabled'] else " [disabled]"
    if n['skip_reason']:
        print(f"    {indent}✗ {n['role']:<22} \"{label:<25}\" {pos}{en}  ← {n['skip_reason']}")
    else:
        print(f"    {indent}✓ {n['role']:<22} \"{label:<25}\" {pos}{en}")

# ═══ 打印保留的标记 ═══
print(f"\n  --- 保留的 {len(markers)} 个标记 ---")
for m in markers:
    print(f"    [{m['id']:>2}] {m['role']:<22} \"{m['title']:<25}\" ({m['cx']:.0f},{m['cy']:.0f}) {m['pw']:.0f}x{m['ph']:.0f}")

# ═══ Step 5: 绘制 SOM 标记 ═══
print("\n[5/5] 绘制 SOM 标记...")

img = Image.open(PNG_PATH).convert('RGBA')
w, h = img.size
overlay = Image.new('RGBA', img.size, (0, 0, 0, 0))
draw = ImageDraw.Draw(overlay)

font = None
font_small = None
font_badge = None
for fp in [
    '/System/Library/Fonts/PingFang.ttc',
    '/System/Library/Fonts/STHeiti Light.ttc',
    '/System/Library/Fonts/STHeiti Medium.ttc',
    '/Library/Fonts/Arial Unicode.ttf',
    '/System/Library/Fonts/Helvetica.ttc',
    '/System/Library/Fonts/SFNSText.ttf',
]:
    try:
        if font is None:
            font = ImageFont.truetype(fp, 14)
            font_small = ImageFont.truetype(fp, 11)
            font_badge = ImageFont.truetype(fp, 20)  # 编号用大字体
        break
    except:
        continue

COLORS = [
    (220, 50, 47, 220), (38, 139, 210, 220), (133, 153, 0, 220),
    (181, 137, 0, 220), (211, 54, 130, 220), (108, 113, 196, 220),
]

# 按面积从大到小排序绘制，小元素最后画（在最上层，不被遮盖）
draw_markers = []
drawn_count = 0
for m in markers:
    ew = m['pw']
    eh = m['ph']
    img_area = img_w * img_h
    if ew * eh > img_area * 0.5:
        continue
    if ew < 4 or eh < 4:
        continue
    draw_markers.append(m)
draw_markers.sort(key=lambda m: m['pw'] * m['ph'], reverse=True)

for m in draw_markers:
    cx = int(m['cx'])
    cy = int(m['cy'])
    ew = m['pw']
    eh = m['ph']
    drawn_count += 1
    color = COLORS[(m['id'] - 1) % len(COLORS)]
    x1 = int(cx - ew / 2)
    y1 = int(cy - eh / 2)
    x2 = int(cx + ew / 2)
    y2 = int(cy + eh / 2)
    draw.rectangle([x1, y1, x2, y2], outline=color, width=2)

# 第二遍：只画编号气泡和文字（确保在所有矩形之上）
for m in draw_markers:
    cx = int(m['cx'])
    cy = int(m['cy'])
    ew = m['pw']
    eh = m['ph']
    color = COLORS[(m['id'] - 1) % len(COLORS)]
    x1 = int(cx - ew / 2)
    y1 = int(cy - eh / 2)
    x2 = int(cx + ew / 2)
    y2 = int(cy + eh / 2)
    # 编号气泡（放大到 r=16）
    badge_r = 16
    bx = x1 + badge_r
    by = y1 + badge_r
    draw.ellipse([bx-badge_r, by-badge_r, bx+badge_r, by+badge_r],
                 fill=color, outline=(255,255,255,255), width=2)
    label = str(m['id'])
    if font_badge:
        bbox = draw.textbbox((0, 0), label, font=font_badge)
        tw, th = bbox[2]-bbox[0], bbox[3]-bbox[1]
        draw.text((bx - tw//2, by - th//2 - 1), label, fill=(255,255,255,255), font=font_badge)
    else:
        draw.text((bx - 4, by - 7), label, fill=(255,255,255,255))
    # 文字标签
    if m['title'] and font_small:
        tag = m['title'][:20]
        tbbox = draw.textbbox((0, 0), tag, font=font_small)
        ttw = tbbox[2] - tbbox[0]
        tth = tbbox[3] - tbbox[1]
        tx = x1 + 4
        ty = y2 - tth - 4
        draw.rectangle([tx-2, ty-1, tx+ttw+2, ty+tth+2], fill=(0,0,0,160))
        draw.text((tx, ty), tag, fill=(255,255,255,255), font=font_small)

result = Image.alpha_composite(img, overlay)
result.convert('RGB').save(JPG_PATH, 'JPEG', quality=85)
jpg_size = os.path.getsize(JPG_PATH)
skipped_draw = len(markers) - drawn_count
print(f"  ✅ SOM 标记绘制完成: {JPG_PATH} ({jpg_size:,} bytes)")
print(f"  实际绘制: {drawn_count} 个 (跳过 {skipped_draw} 个过大/过小元素)")

# ═══ 汇总 ═══
print("\n" + "=" * 50)
print(f"  前台应用: {app_name}")
print(f"  UI 树节点: {node_count[0]}")
print(f"  AX 过滤后: {len(markers)} 个可交互标记")
print(f"  过滤掉: {skipped_count} 个节点")
print("=" * 50)
print(f"\n  UI 树 JSON: {tree_path}")
print(f"  原始截图: {PNG_PATH}")
print(f"  SOM 标记图: {JPG_PATH}")
print(f"\n  清理: rm -rf {WORK_DIR}")

subprocess.run(["open", JPG_PATH])
