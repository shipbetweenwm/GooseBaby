#!/usr/bin/env python3
"""
CUA SOM 测试 — AXActions 智能过滤方案 (test3)

过滤策略（完全基于 AXActions，不使用角色白名单猜测）：
  1. AXActionNames 过滤：只保留有交互动作的元素（AXPress/AXConfirm/AXPick 等）
  2. 父子包含去重：父子完全重叠时，只保留更内层+有语义的元素
  3. 可滚动容器智能处理：有交互子元素→跳过容器；无交互子元素→保留容器
  4. 深度限制 15 层，节点上限 5000

用法：
  python3 test3.py [delay_seconds]
"""

import subprocess, sys, os, json, re, time

WORK_DIR = f"/tmp/som_test3_{os.getpid()}"
os.makedirs(WORK_DIR, exist_ok=True)
PNG_PATH = f"{WORK_DIR}/screen.png"
JPG_PATH = f"{WORK_DIR}/screen_som.jpg"

# ═══ 配置 ═══
MAX_DEPTH = 15       # 最大遍历深度
MAX_NODES = 5000     # 最大遍历节点数

print("=" * 50)
print("  CUA SOM — AXActions 智能过滤方案")
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
        AXUIElementCopyActionNames,
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
    try:
        import Quartz
        from Quartz import kAXValueTypeCGPoint, kAXValueTypeCGSize
        import ctypes
        point = Quartz.CGPoint()
        if Quartz.AXValueGetValue(val, kAXValueTypeCGPoint, ctypes.byref(point)):
            return (float(point.x), float(point.y))
        size = Quartz.CGSize()
        if Quartz.AXValueGetValue(val, kAXValueTypeCGSize, ctypes.byref(size)):
            return (float(size.width), float(size.height))
    except:
        pass
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

def _get_actions(element):
    """获取元素支持的 AX 动作列表（必须使用 AXUIElementCopyActionNames 专用 API）"""
    try:
        result = AXUIElementCopyActionNames(element, None)
        if isinstance(result, tuple):
            err, val = result
            if err == 0 and val:
                return [str(a) for a in val]
        return []
    except:
        return []

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

# ═══ 可交互动作集合 ═══
# 只要元素支持以下任意一个动作，就认为它是可交互的
INTERACTIVE_ACTIONS = {
    'AXPress',          # 可点击（按钮、链接等）
    'AXIncrement',      # 可增加（滑块、stepper）
    'AXDecrement',      # 可减少
    'AXConfirm',        # 可确认
    'AXPick',           # 可选择（picker、弹出菜单）
    'AXCancel',         # 可取消
    'AXShowMenu',       # 可显示菜单（右键菜单等）
    'AXOpen',           # 可打开
    'AXRaise',          # 可提升（窗口）
}

# ═══ 角色兜底白名单 ═══
# 某些应用（微信/企业微信/QQ 等 Qt/Electron 应用）的列表行、单元格等
# 虽然实际可点击，但 macOS AX API 不返回 AXPress 动作
# 对这些角色做兜底：即使 AXActions 为空，也保留
CLICKABLE_ROLE_FALLBACK = {
    'AXRow',            # 列表行（微信聊天列表、通讯录等）
    'AXCell',           # 单元格（表格、网格视图）
    'AXButton',         # 按钮（某些自定义按钮不报告 AXPress）
    'AXLink',           # 链接
    'AXMenuItem',       # 菜单项
    'AXMenuBarItem',    # 菜单栏项
    'AXCheckBox',       # 复选框
    'AXRadioButton',    # 单选按钮
    'AXPopUpButton',    # 弹出按钮
    'AXComboBox',       # 组合框
    'AXSlider',         # 滑块
    'AXTextField',      # 文本输入框
    'AXTextArea',       # 文本区域
    'AXTabGroup',       # 标签页组
    'AXTab',            # 标签页
    'AXDisclosureTriangle',  # 展开三角
    'AXColorWell',      # 颜色选择器
    'AXSegmentedControl',    # 分段控件
    'AXToolbar',        # 工具栏（可点击的工具栏按钮）
    'AXOutline',        # 大纲视图（树形列表）
    'AXOutlineRow',     # 大纲行
    'AXList'           # 列表视图
}

# 可滚动容器的角色
SCROLLABLE_ROLES = {
    'AXScrollArea', 'AXScrollBar',
}

# 顶层应用/窗口容器（始终跳过自身）
TOP_CONTAINER_ROLES = {
    'AXApplication', 'AXWindow',
}

# ═══ 递归遍历 UI 树 ═══
node_count = [0]
node_limit_hit = [False]

def _node_to_dict(element, depth):
    """递归构建 UI 树字典，同时记录 AXActions"""
    if depth > MAX_DEPTH:
        return None
    if node_count[0] >= MAX_NODES:
        if not node_limit_hit[0]:
            print(f"  ⚠️ 节点数达到上限 {MAX_NODES}，停止遍历")
            node_limit_hit[0] = True
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
    if enabled is not None:
        result['enabled'] = bool(enabled)

    # 获取 AXActions
    actions = _get_actions(element)
    if actions:
        result['actions'] = actions

    # 获取坐标
    pos = _get_point(element)
    sz = _get_size(element)
    if pos and sz and sz[0] > 0 and sz[1] > 0:
        result['x'], result['y'] = pos[0], pos[1]
        result['width'], result['height'] = sz[0], sz[1]

    # 递归子节点
    children = _get_attr(element, kAXChildrenAttribute)
    cl = []
    if children:
        for child in children:
            if node_count[0] >= MAX_NODES:
                break
            cd = _node_to_dict(child, depth + 1)
            if cd:
                cl.append(cd)
    if cl:
        result['children'] = cl

    return result

t0 = time.time()
tree = _node_to_dict(app_elem, 0)
elapsed = time.time() - t0
print(f"  ✅ UI 树: {node_count[0]} 个节点 (上限 {MAX_NODES}), 深度上限 {MAX_DEPTH}, 耗时 {elapsed:.2f}s")

# 保存 UI 树 JSON
tree_path = f"{WORK_DIR}/ui_tree.json"
with open(tree_path, 'w') as f:
    json.dump(tree, f, ensure_ascii=False, indent=2)

# ═══ Step 4: AXActions 智能过滤 ═══
print("\n[4/5] AXActions 智能过滤...")

all_nodes = []     # 记录所有节点（含过滤原因），用于调试
raw_markers = []   # 第一轮过滤后的候选标记（尚未去重）
next_id = [1]

def _get_label(node):
    """获取节点的文字标签"""
    label = (node.get('title') or node.get('value') or node.get('description') or '').strip()
    if not label:
        label = _collect_child_text(node)
    if len(label) > 30:
        label = label[:30] + '...'
    return label

def _collect_child_text(node):
    """递归从子元素中收集可见文本"""
    texts = []
    for child in node.get('children', []):
        cr = child.get('role', '')
        t = (child.get('title') or child.get('value') or child.get('description') or '').strip()
        if t and cr in ('AXStaticText', 'AXButton', 'AXLink', 'AXMenuItem'):
            texts.append(t)
        elif cr in ('AXGroup', 'AXRow', 'AXCell'):
            t2 = _collect_child_text(child)
            if t2:
                texts.append(t2)
    return ' '.join(texts)[:30]

def _has_interactive_action(node):
    """判断节点是否有可交互动作"""
    actions = set(node.get('actions', []))
    return bool(actions & INTERACTIVE_ACTIONS)

def _has_interactive_descendants(node):
    """递归检查子树中是否有可交互后代"""
    for child in node.get('children', []):
        if _has_interactive_action(child):
            return True
        if _has_interactive_descendants(child):
            return True
    return False

def traverse(node, depth=0):
    """
    第一轮遍历：基于 AXActions 过滤
    
    规则：
      1. 无坐标 → 跳过
      2. 零尺寸 → 跳过
      3. 屏幕外 → 跳过
      4. disabled → 跳过
      5. 顶层容器 (AXApplication/AXWindow) → 跳过自身，递归子节点
      6. 可滚动容器 → 有交互子元素则跳过容器，无则保留
      7. 核心: 无交互动作 (AXActions) → 跳过
    """
    role = node.get('role', '')
    x = node.get('x')
    y = node.get('y')
    w = node.get('width', 0)
    h = node.get('height', 0)
    enabled = node.get('enabled', True)
    label = _get_label(node)
    actions = node.get('actions', [])
    has_pos = x is not None and y is not None

    # ── 判断过滤原因 ──
    skip_reason = None

    if not has_pos:
        skip_reason = "无坐标"
    elif w <= 0 or h <= 0:
        skip_reason = f"零尺寸 ({w:.0f}x{h:.0f})"
    elif not enabled:
        skip_reason = "disabled"
    elif role in TOP_CONTAINER_ROLES:
        skip_reason = f"顶层容器 {role}"
    elif role in SCROLLABLE_ROLES:
        # ── 策略3: 可滚动容器智能处理 ──
        if _has_interactive_descendants(node):
            skip_reason = f"可滚动容器(有交互子元素) {role}"
        else:
            # 没有交互子元素 → 保留容器自身以便执行滚动
            skip_reason = None
    
    # ── 策略1: AXActions 优先 + 角色白名单兜底 ──
    if skip_reason is None:
        node_actions = set(actions)
        has_action = bool(node_actions & INTERACTIVE_ACTIONS)
        has_role_fallback = role in CLICKABLE_ROLE_FALLBACK
        if not has_action and not has_role_fallback:
            skip_reason = f"无交互动作且非可点击角色 {role} actions={actions}"

    # 记录节点信息用于调试
    all_nodes.append({
        'role': role, 'title': label,
        'x': x or 0, 'y': y or 0, 'w': w, 'h': h,
        'enabled': enabled, 'actions': actions,
        'depth': depth, 'skip_reason': skip_reason,
    })

    # 通过过滤 → 加入候选标记列表
    if skip_reason is None and has_pos:
        cx = (x + w / 2) * scale_x
        cy = (y + h / 2) * scale_y
        pw = w * scale_x
        ph = h * scale_y
        raw_markers.append({
            'id': 0,  # 稍后分配
            'cx': cx, 'cy': cy,
            'pw': pw, 'ph': ph,
            'lx': x, 'ly': y, 'lw': w, 'lh': h,  # 逻辑坐标（用于去重）
            'role': role,
            'title': label,
            'actions': actions,
            'depth': depth,
        })

    # 递归子节点
    for child in node.get('children', []):
        traverse(child, depth + 1)

traverse(tree)
print(f"  第一轮(AXActions过滤): {len(raw_markers)} 个候选标记")

# ═══ 策略2: 父子包含关系智能去重 ═══
print("  执行父子包含去重...")

def _bbox_contains(outer, inner, tolerance=2):
    """检查 outer 的 bbox 是否完全包含 inner（逻辑坐标）"""
    ox1 = outer['lx'] - tolerance
    oy1 = outer['ly'] - tolerance
    ox2 = outer['lx'] + outer['lw'] + tolerance
    oy2 = outer['ly'] + outer['lh'] + tolerance
    ix1 = inner['lx']
    iy1 = inner['ly']
    ix2 = inner['lx'] + inner['lw']
    iy2 = inner['ly'] + inner['lh']
    return ox1 <= ix1 and oy1 <= iy1 and ox2 >= ix2 and oy2 >= iy2

def _label_quality(marker):
    """评估标记的语义质量（标签长度 + 是否有值）"""
    title = marker.get('title', '')
    return len(title)

def _smart_dedup(markers):
    """
    基于包含关系的智能去重：
    - 如果两个标记 A 完全包含 B（A 更大，B 更内层）
    - 且两者都是交互元素
    - 则优先保留更内层的（B），除非 B 完全没有语义而 A 有
    """
    if not markers:
        return markers

    n = len(markers)
    removed = set()

    # 按面积从大到小排序，便于外层先比较
    indexed = list(enumerate(markers))
    indexed.sort(key=lambda x: x[1]['lw'] * x[1]['lh'], reverse=True)

    for i_idx in range(n):
        i, outer = indexed[i_idx]
        if i in removed:
            continue
        for j_idx in range(i_idx + 1, n):
            j, inner = indexed[j_idx]
            if j in removed:
                continue

            # 检查 outer 是否包含 inner
            if not _bbox_contains(outer, inner):
                continue

            # outer 包含 inner —— 决定保留谁
            outer_quality = _label_quality(outer)
            inner_quality = _label_quality(inner)

            # 面积比：inner 占 outer 的比例
            outer_area = outer['lw'] * outer['lh']
            inner_area = inner['lw'] * inner['lh']
            area_ratio = inner_area / outer_area if outer_area > 0 else 0

            if area_ratio > 0.85:
                # 几乎完全重叠（>85% 面积）→ 保留语义更好的那个
                if inner_quality >= outer_quality:
                    removed.add(i)  # 去掉外层
                    break  # outer 已移除，不用再检查它包含的其他元素
                else:
                    removed.add(j)  # 去掉内层
            else:
                # 外层明显更大 → 内层是独立子元素
                if inner_quality > 0:
                    # 内层有语义 → 保留内层，去掉外层（外层是容器）
                    removed.add(i)
                    break
                elif outer_quality > 0 and inner_quality == 0:
                    # 内层无语义，外层有 → 去掉内层
                    removed.add(j)
                else:
                    # 都没有语义 → 保留更内层的（更精确的定位）
                    removed.add(i)
                    break

    result = [m for idx, m in enumerate(markers) if idx not in removed]
    return result

deduped_markers = _smart_dedup(raw_markers)
removed_count = len(raw_markers) - len(deduped_markers)
print(f"  去重移除: {removed_count} 个重叠标记")

# ═══ 绘制阶段额外过滤（过大/过小）═══
final_markers = []
img_area = img_w * img_h
skip_draw_count = 0
for m in deduped_markers:
    ew = m['pw']
    eh = m['ph']
    if ew * eh > img_area * 0.5:
        skip_draw_count += 1
        continue
    if ew < 4 or eh < 4:
        skip_draw_count += 1
        continue
    final_markers.append(m)

# 分配最终 ID
for idx, m in enumerate(final_markers):
    m['id'] = idx + 1

print(f"  最终标记: {len(final_markers)} 个 (绘制过滤掉 {skip_draw_count} 个过大/过小)")

# ═══ 坐标调试 ═══
if final_markers:
    min_cx = min(m['cx'] for m in final_markers)
    max_cx = max(m['cx'] for m in final_markers)
    min_cy = min(m['cy'] for m in final_markers)
    max_cy = max(m['cy'] for m in final_markers)
    print(f"\n  --- 坐标调试 ---")
    print(f"  截图像素: {img_w} x {img_h}")
    print(f"  逻辑屏幕: {logical_w} x {logical_h}")
    print(f"  缩放比: scale_x={scale_x:.2f} scale_y={scale_y:.2f}")
    print(f"  标记 cx 范围: {min_cx:.0f} ~ {max_cx:.0f} (截图宽={img_w})")
    print(f"  标记 cy 范围: {min_cy:.0f} ~ {max_cy:.0f} (截图高={img_h})")
    out_count = sum(1 for m in final_markers if m['cx'] < 0 or m['cx'] > img_w or m['cy'] < 0 or m['cy'] > img_h)
    print(f"  超出截图范围的标记: {out_count} / {len(final_markers)}")
    print(f"  前5个标记:")
    for m in final_markers[:5]:
        print(f"    [{m['id']}] {m['role']:<22} \"{m['title']:<20}\" 逻辑({m['lx']:.0f},{m['ly']:.0f}) 像素({m['cx']:.0f},{m['cy']:.0f}) actions={m['actions']}")
    print(f"  ----------------")

# ═══ 打印过滤统计 ═══
kept_count = sum(1 for n in all_nodes if n['skip_reason'] is None)
skipped_count = sum(1 for n in all_nodes if n['skip_reason'] is not None)
print(f"\n  --- 全部 {len(all_nodes)} 个节点 (保留 {kept_count}, 过滤 {skipped_count}) ---")

reason_counts = {}
for n in all_nodes:
    r = n['skip_reason']
    if r:
        if r.startswith("无交互动作"):
            key = "无交互动作"
        elif r.startswith("屏幕外"):
            key = "屏幕外"
        elif r.startswith("零尺寸"):
            key = "零尺寸"
        elif r.startswith("可滚动容器"):
            key = "可滚动容器(有交互子元素)"
        elif r.startswith("顶层容器"):
            key = "顶层容器"
        else:
            key = r
        reason_counts[key] = reason_counts.get(key, 0) + 1

print(f"\n  过滤原因统计:")
for reason, count in sorted(reason_counts.items(), key=lambda x: -x[1]):
    print(f"    {reason:<30} ×{count}")

print(f"\n  全部节点:")
for n in all_nodes:
    indent = "  " * n['depth']
    label = n['title'] or ''
    pos = f"({n['x']:.0f},{n['y']:.0f}) {n['w']:.0f}x{n['h']:.0f}" if n['x'] else "(无坐标)"
    en = "" if n['enabled'] else " [disabled]"
    actions_str = f" actions={n['actions']}" if n['actions'] else ""
    if n['skip_reason']:
        print(f"    {indent}✗ {n['role']:<22} \"{label:<20}\"{actions_str} {pos}{en}  ← {n['skip_reason']}")
    else:
        print(f"    {indent}✓ {n['role']:<22} \"{label:<20}\"{actions_str} {pos}{en}")

# ═══ 打印保留的标记 ═══
print(f"\n  --- 最终 {len(final_markers)} 个标记 (去重移除 {removed_count}, 绘制过滤 {skip_draw_count}) ---")
for m in final_markers:
    print(f"    [{m['id']:>3}] {m['role']:<22} \"{m['title']:<20}\" ({m['cx']:.0f},{m['cy']:.0f}) {m['pw']:.0f}x{m['ph']:.0f} actions={m['actions']}")

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
            font_badge = ImageFont.truetype(fp, 20)
        break
    except:
        continue

COLORS = [
    (220, 50, 47, 220), (38, 139, 210, 220), (133, 153, 0, 220),
    (181, 137, 0, 220), (211, 54, 130, 220), (108, 113, 196, 220),
]

# 按面积从大到小排序绘制，小元素最后画（在最上层）
draw_markers = sorted(final_markers, key=lambda m: m['pw'] * m['ph'], reverse=True)

# 第一遍：画矩形边框
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
    draw.rectangle([x1, y1, x2, y2], outline=color, width=2)

# 第二遍：画编号气泡和文字（确保在所有矩形之上）
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

    # 编号气泡
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
print(f"  ✅ SOM 标记绘制完成: {JPG_PATH} ({jpg_size:,} bytes)")
print(f"  实际绘制: {len(draw_markers)} 个")

# ═══ 汇总 ═══
print("\n" + "=" * 50)
print(f"  前台应用: {app_name}")
print(f"  UI 树节点: {node_count[0]} (深度上限={MAX_DEPTH}, 节点上限={MAX_NODES})")
print(f"  第一轮(AXActions): {len(raw_markers)} 个候选")
print(f"  第二轮(父子去重): -{removed_count} → {len(deduped_markers)} 个")
print(f"  第三轮(大小过滤): -{skip_draw_count} → {len(final_markers)} 个最终标记")
print(f"  过滤掉: {skipped_count} 个节点")
print("=" * 50)
print(f"\n  UI 树 JSON: {tree_path}")
print(f"  原始截图: {PNG_PATH}")
print(f"  SOM 标记图: {JPG_PATH}")
print(f"\n  清理: rm -rf {WORK_DIR}")

subprocess.run(["open", JPG_PATH])
