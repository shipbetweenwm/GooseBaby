#!/usr/bin/env python3
"""
CUA SOM 端到端测试 — 在 Terminal 中运行

权限要求：
  1. 辅助功能：系统设置 → 隐私与安全性 → 辅助功能 → Terminal
  2. 屏幕录制：系统设置 → 隐私与安全性 → 屏幕录制 → Terminal

用法：
  python3 scripts/test_som_terminal.py
"""

import subprocess, sys, os, json, re, time

WORK_DIR = f"/tmp/som_test_{os.getpid()}"
os.makedirs(WORK_DIR, exist_ok=True)
PNG_PATH = f"{WORK_DIR}/screen.png"
JPG_PATH = f"{WORK_DIR}/screen_som.jpg"

print("=" * 50)
print("  CUA SOM 端到端测试")
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
    print(f"  ⚠️ sips 解析失败 (stdout={repr(r.stdout[:200])}, stderr={repr(r.stderr[:200])})")
    # 用 Pillow 兜底
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
        kAXDescriptionAttribute,
    )
    print("  ✅ pyobjc OK")
except ImportError as e:
    print(f"  ❌ {e}")
    print("  运行: pip3 install pyobjc-framework-ApplicationServices")
    sys.exit(1)

# 获取真实屏幕逻辑分辨率
main_screen = NSScreen.mainScreen()
screen_frame = main_screen.frame()
logical_w = int(screen_frame.size.width)
logical_h = int(screen_frame.size.height)
# 缩放比 = 截图像素 / 逻辑点数
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

# 只获取前台应用（聚焦的应用）
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

# ═══ 坐标诊断 ═══
print(f"\n  --- 坐标诊断 ---")
print(f"  屏幕逻辑尺寸: {logical_w} x {logical_h}")
win_pos = _get_point(app_elem)
win_sz = _get_size(app_elem)
if win_pos:
    print(f"  应用窗口位置(AX原始): x={win_pos[0]:.0f}, y={win_pos[1]:.0f}")
if win_sz:
    print(f"  应用窗口大小(AX原始): w={win_sz[0]:.0f}, h={win_sz[1]:.0f}")

# 获取窗口元素，打印几个子元素坐标
children = _get_attr(app_elem, kAXChildrenAttribute)
if children:
    print(f"  顶层子元素数: {len(children)}")
    diag_count = 0
    for c in children[:10]:
        cp = _get_point(c)
        cs = _get_size(c)
        cr = _get_attr(c, kAXRoleAttribute)
        ct = _get_attr(c, kAXTitleAttribute)
        if cp and cs and diag_count < 5:
            print(f"    元素: {cr} \"{ct}\" pos=({cp[0]:.0f},{cp[1]:.0f}) size=({cs[0]:.0f},{cs[1]:.0f})")
            diag_count += 1
print(f"  如果 y 值接近 {logical_h}，说明原点在左下(需要翻转)")
print(f"  如果 y 值接近 0，说明原点在左上(不需要翻转)")
print(f"  --------------\n")

# 递归遍历 UI 树
node_count = [0]

def _node_to_dict(element, depth, max_depth, ancestor_rect=None):
    """ancestor_rect: 最近有坐标的祖先坐标，仅叶子节点无坐标时继承"""
    if depth > max_depth:
        return None
    node_count[0] += 1
    result = {}
    r = _get_attr(element, kAXRoleAttribute)
    t = _get_attr(element, kAXTitleAttribute)
    v = _get_attr(element, kAXValueAttribute)
    d = _get_attr(element, kAXDescriptionAttribute)
    result['role'] = str(r) if r else ''
    result['title'] = str(t) if t else ''
    if v and str(v).strip():
        result['value'] = str(v)[:200]
    if d and str(d).strip():
        result['description'] = str(d)[:200]
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
    # 没有自身坐标的叶子节点，继承最近祖先坐标
    if not has_own_bounds and not cl and ancestor_rect:
        result['x'], result['y'] = ancestor_rect[0], ancestor_rect[1]
        result['width'], result['height'] = ancestor_rect[2], ancestor_rect[3]
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

# ═══ Step 4: 提取 SOM 标记 ═══
print("\n[4/5] 提取可交互标记...")

interactive_roles = {
    'AXButton', 'AXTextField', 'AXTextArea', 'AXPopUpButton',
    'AXCheckBox', 'AXRadioButton', 'AXLink', 'AXStaticText',
    'AXMenuItem', 'AXMenuButton', 'AXComboBox', 'AXSlider',
    'AXStepper', 'AXIncrementor', 'AXDecrementor',
    'AXDisclosureTriangle', 'AXTabGroup', 'AXImage',
    'AXToolbar', 'AXScrollArea', 'AXGroup', 'AXWebArea',
    'AXRow', 'AXOutlineRow', 'AXTable', 'AXList',
    'AXMenuBarItem', 'AXMenu', 'AXSplitGroup',
    'AXCell', 'AXColumn', 'AXLayoutArea', 'AXLayoutItem',
    'AXSheet', 'AXDrawer', 'AXGrowArea', 'AXUnknown',
    'AXBrowser', 'AXDockItem', 'AXGrid', 'AXHelpTag',
    'AXLevelIndicator', 'AXMovieView', 'AXPicker', 'AXProgressIndicator',
    'AXRatingIndicator', 'AXRelevanceIndicator', 'AXScrollThumb',
    'AXSearchField', 'AXSegmentedControl', 'AXSortButton',
    'AXSplitter', 'AXStaticText', 'AXStatusBar', 'AXSwitch',
    'AXTab', 'AXTimePicker', 'AXToggle', 'AXToolTip',
    'AXValueIndicator', 'AXZoomButton',
}

# 明确不可交互的角色黑名单
NON_INTERACTIVE_ROLES = {
    'axwindow',            # 窗口本身
    'axsplitgroup',        # 分割视图容器
    'axlayoutarea',        # 布局区域
    'axlayoutitem',        # 布局项
    'axgrowarea',          # 拖拽缩放区域
    'axdrawer',            # 抽屉容器
    'axsheet',             # Sheet 容器
    'axscrollbar',         # 滚动条
    'axscrollarea',        # 滚动区域容器
    'axunknown',           # 未知元素
}

markers = []
next_id = [1]
all_nodes = []  # 记录所有节点（保留+过滤）

def _collect_child_text(node):
    """递归从子元素中收集可见文本"""
    texts = []
    for child in node.get('children', []):
        cr = child.get('role', '').lower()
        t = (child.get('title') or child.get('value') or child.get('description') or '').strip()
        if t and ('statictext' in cr or 'button' in cr or 'link' in cr):
            texts.append(t)
        elif 'group' in cr or 'row' in cr:
            # 继续递归，但只取一层
            t2 = _collect_child_text(child)
            if t2:
                texts.append(t2)
    return ' '.join(texts)[:30]

def traverse(node, depth=0):
    """遍历节点，记录全部节点（含过滤原因）"""
    if 'x' not in node or 'y' not in node:
        for child in node.get('children', []):
            traverse(child, depth + 1)
        return
    role = node.get('role', '')
    role_lower = role.lower()
    x, y = node['x'], node['y']
    w, h = node['width'], node['height']
    label = (node.get('title') or node.get('value') or node.get('description') or '').strip()
    if not label:
        label = _collect_child_text(node)
    if len(label) > 30:
        label = label[:30] + '...'

    # 判断过滤原因
    skip_reason = None
    if x < -10 or y < -10 or x >= logical_w + 10 or y >= logical_h + 10:
        skip_reason = f"屏幕外 ({x:.0f},{y:.0f})"
    elif role_lower in NON_INTERACTIVE_ROLES:
        skip_reason = f"不可交互角色 {role}"

    all_nodes.append({
        'role': role, 'title': label,
        'x': x, 'y': y, 'w': w, 'h': h,
        'depth': depth, 'skip_reason': skip_reason,
    })

    if skip_reason is None:
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
print(f"  ✅ 提取 {len(markers)} 个标记")

# ═══ 打印全部节点详情（含过滤原因）═══
kept_count = sum(1 for n in all_nodes if n['skip_reason'] is None)
skipped_count = sum(1 for n in all_nodes if n['skip_reason'] is not None)
print(f"\n  --- 全部 {len(all_nodes)} 个节点 (保留 {kept_count}, 过滤 {skipped_count}) ---")
for n in all_nodes:
    indent = "  " * n['depth']
    label = n['title'] or ''
    pos = f"({n['x']:.0f},{n['y']:.0f}) {n['w']:.0f}x{n['h']:.0f}"
    if n['skip_reason']:
        print(f"    {indent}✗ {n['role']:<22} \"{label:<25}\" {pos}  ← {n['skip_reason']}")
    else:
        print(f"    {indent}✓ {n['role']:<22} \"{label:<25}\" {pos}")

if markers:
    for m in markers:
        print(f"    [{m['id']:>2}] {m['role']:<20} \"{m['title']:<30}\" ({m['cx']:.0f},{m['cy']:.0f})")

# ═══ Step 5: 绘制 SOM 标记 ═══
print("\n[5/5] 绘制 SOM 标记...")

img = Image.open(PNG_PATH).convert('RGBA')
w, h = img.size
overlay = Image.new('RGBA', img.size, (0, 0, 0, 0))
draw = ImageDraw.Draw(overlay)

# 加载字体（优先中文字体）
font = None
font_small = None
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
        break
    except:
        continue

# 颜色方案
COLORS = [
    (220, 50, 47, 220), (38, 139, 210, 220), (133, 153, 0, 220),
    (181, 137, 0, 220), (211, 54, 130, 220), (108, 113, 196, 220),
]

for m in markers:
    cx = int(m['cx'])
    cy = int(m['cy'])
    ew = m['pw']
    eh = m['ph']
    color = COLORS[(m['id'] - 1) % len(COLORS)]
    # 元素矩形边界
    x1 = int(cx - ew / 2)
    y1 = int(cy - eh / 2)
    x2 = int(cx + ew / 2)
    y2 = int(cy + eh / 2)
    # 绘制描边框（不填充，只画边框）
    draw.rectangle([x1, y1, x2, y2], outline=color, width=2)
    # 左上角编号气泡（放在框内）
    badge_r = 10
    bx = x1 + badge_r
    by = y1 + badge_r
    draw.ellipse([bx-badge_r, by-badge_r, bx+badge_r, by+badge_r],
                 fill=color, outline=(255,255,255,255), width=1)
    label = str(m['id'])
    if font:
        bbox = draw.textbbox((0, 0), label, font=font)
        tw, th = bbox[2]-bbox[0], bbox[3]-bbox[1]
        draw.text((bx - tw//2, by - th//2 - 1), label, fill=(255,255,255,255), font=font)
    else:
        draw.text((bx - 4, by - 7), label, fill=(255,255,255,255))
    # 文字标签（框内左下角）
    if m['title'] and font_small:
        tag = m['title'][:20]
        tbbox = draw.textbbox((0, 0), tag, font=font_small)
        ttw = tbbox[2] - tbbox[0]
        tth = tbbox[3] - tbbox[1]
        tx = x1 + 4
        ty = y2 - tth - 4
        # 半透明背景
        draw.rectangle([tx-2, ty-1, tx+ttw+2, ty+tth+2], fill=(0,0,0,160))
        draw.text((tx, ty), tag, fill=(255,255,255,255), font=font_small)

result = Image.alpha_composite(img, overlay)
result.convert('RGB').save(JPG_PATH, 'JPEG', quality=85)
jpg_size = os.path.getsize(JPG_PATH)
print(f"  ✅ SOM 标记绘制完成: {JPG_PATH} ({jpg_size:,} bytes)")

# ═══ 汇总 ═══
print("\n" + "=" * 50)
print(f"  前台应用: {app_name}")
print(f"  UI 树节点: {node_count[0]}")
print(f"  SOM 标记数: {len(markers)}")
print("=" * 50)
print(f"\n  UI 树 JSON: {tree_path}")
print(f"  原始截图: {PNG_PATH}")
print(f"  SOM 标记图: {JPG_PATH}")
print(f"\n  清理: rm -rf {WORK_DIR}")

# 打开图片
subprocess.run(["open", JPG_PATH])

