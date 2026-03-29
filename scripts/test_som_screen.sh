#!/bin/bash
# ═══════════════════════════════════════════════════════
# 当前屏幕截图 + SOM 标记绘制测试
# ═══════════════════════════════════════════════════════

WORK_DIR="/tmp/som_screen_test_$$"
mkdir -p "$WORK_DIR"
PNG_PATH="$WORK_DIR/screen.png"
JPG_PATH="$WORK_DIR/screen_som.jpg"

echo "═══════════════════════════════════════"
echo "  当前屏幕 SOM 标记测试"
echo "═══════════════════════════════════════"
echo ""

# 截屏
screencapture -x "$PNG_PATH" 2>/dev/null
IMG_W=$(sips -g pixelWidth "$PNG_PATH" 2>/dev/null | grep pixelWidth | awk '{print $2}')
IMG_H=$(sips -g pixelHeight "$PNG_PATH" 2>/dev/null | grep pixelHeight | awk '{print $2}')
SCALE=$(system_profiler SPDisplaysDataType 2>/dev/null | grep "Retina" | head -1 | wc -l | tr -d ' ')
[ "$SCALE" = "1" ] && SF=2 || SF=1
LOGICAL_W=$((IMG_W / SF))
LOGICAL_H=$((IMG_H / SF))
echo "截图: ${IMG_W}x${IMG_H} (Retina ${SF}x), 逻辑: ${LOGICAL_W}x${LOGICAL_H}"
echo ""

# 获取 UI 树 + 提取标记 + 绘制 SOM，全部在一个 Python 脚本中完成
python3 << PYEOF
import sys, json, re, time
from AppKit import NSWorkspace
from ApplicationServices import (
    AXUIElementCreateApplication, AXUIElementCopyAttributeValue,
    kAXChildrenAttribute, kAXRoleAttribute, kAXTitleAttribute,
    kAXValueAttribute, kAXDescriptionAttribute, kAXPositionAttribute, kAXSizeAttribute,
)

# ── 工具函数 ──
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

# ── 收集所有可见窗口的 UI 元素 ──
# 获取所有运行中的应用
all_apps = NSWorkspace.sharedWorkspace().runningApplications()
logical_w, logical_h = $LOGICAL_W, $LOGICAL_H
markers = []
marker_id = [1]

interactive_roles = {
    'AXButton', 'AXTextField', 'AXTextArea', 'AXPopUpButton',
    'AXCheckBox', 'AXRadioButton', 'AXLink', 'AXStaticText',
    'AXMenuItem', 'AXMenuButton', 'AXComboBox', 'AXSlider',
    'AXStepper', 'AXIncrementor', 'AXDecrementor',
    'AXDisclosureTriangle', 'AXTabGroup', 'AXImage',
    'AXToolbar', 'AXScrollArea', 'AXGroup', 'AXWebArea',
    'AXRow', 'AXOutlineRow', 'AXTable', 'AXList',
    'AXSplitGroup', 'AXSheet', 'AXDrawer', 'AXGrowArea',
    'AXMenuBarItem', 'AXMenu',
    'button', 'text field', 'text area', 'checkbox',
    'radio button', 'link', 'menu item', 'menu button',
    'slider', 'image', 'list', 'search field', 'group',
}

print("扫描所有可见应用窗口...")
app_count = 0
total_nodes = 0

for app in all_apps:
    try:
        name = app.localizedName()
        if not name:
            continue
        pid = int(app.processIdentifier())
        # 只处理有窗口的前台应用
        if not app.isActive():
            # 检查是否有窗口
            windows_check = _get_attr(AXUIElementCreateApplication(pid), 'AXWindows')
            if not windows_check:
                continue
    except:
        continue

    app_elem = AXUIElementCreateApplication(pid)
    windows = _get_attr(app_elem, 'AXWindows')
    if not windows:
        continue

    app_count += 1

    for win in windows:
        def traverse(element, depth=0, max_depth=5):
            if depth > max_depth:
                return
            r = _get_attr(element, kAXRoleAttribute) or ''
            t = _get_attr(element, kAXTitleAttribute) or ''
            v = _get_attr(element, kAXValueAttribute) or ''
            pos = _get_point(element)
            sz = _get_size(element)

            is_interactive = False
            rl = r.lower()
            for ir in interactive_roles:
                if ir.lower() in rl:
                    is_interactive = True
                    break

            # StaticText 需要有内容
            if is_interactive and 'statictext' in rl and not t and not v:
                is_interactive = False

            if is_interactive and pos and sz:
                x, y = pos
                w, h = sz
                # 归一化
                nx = x / logical_w
                ny = y / logical_h
                nw = w / logical_w
                nh = h / logical_h
                area = nw * nh

                # 过滤：太小、太大、重叠、不可见
                if area >= 0.005 and area <= 0.6 and nw >= 0.003 and nh >= 0.003 \
                   and x >= -10 and y >= -10 and x < logical_w + 10 and y < logical_h + 10:
                    cx = nx + nw / 2
                    cy = ny + nh / 2
                    overlaps = False
                    for m in markers:
                        dx = cx - m['cx']
                        dy = cy - m['cy']
                        if dx*dx + dy*dy < 0.0004:
                            overlaps = True
                            break
                    if not overlaps and len(markers) < 100:
                        label = t or v or ''
                        if len(label) > 25:
                            label = label[:25] + '...'
                        markers.append({
                            'id': marker_id[0],
                            'cx': cx, 'cy': cy,
                            'w': nw, 'h': nh,
                            'role': r,
                            'title': label,
                        })
                        marker_id[0] += 1

            children = _get_attr(element, kAXChildrenAttribute)
            if children:
                for child in children:
                    traverse(child, depth + 1, max_depth)

        traverse(win)


print(f"扫描了 {app_count} 个应用, 提取 {len(markers)} 个标记")
print("")

if markers:
    # 显示前 20 个
    print("标记列表 (前20个):")
    for m in markers[:20]:
        print(f"  [{m['id']:>2}] {m['role']:<20} \"{m['title']:<25}\" ({m['cx']*logical_w:.0f},{m['cy']*logical_h:.0f})")
    if len(markers) > 20:
        print(f"  ... 还有 {len(markers)-20} 个")
else:
    print("未提取到标记。当前前台应用可能不暴露 UI 元素（如 Electron 应用）。")

# ── 用 Pillow 绘制 SOM 标记 ──
from PIL import Image, ImageDraw, ImageFont

img = Image.open('$PNG_PATH').convert('RGBA')
w, h = img.size

overlay = Image.new('RGBA', img.size, (0, 0, 0, 0))
draw = ImageDraw.Draw(overlay)

# 加载字体
font = None
for fp in ['/System/Library/Fonts/Helvetica.ttc', '/System/Library/Fonts/SFNSText.ttf', '/Library/Fonts/Arial.ttf']:
    try:
        font = ImageFont.truetype(fp, 16)
        break
    except:
        continue

# 颜色方案
colors = [
    (220, 50, 47, 220),   # 红
    (38, 139, 210, 220),   # 蓝
    (133, 153, 0, 220),    # 绿
    (181, 137, 0, 220),    # 黄
    (211, 54, 130, 220),   # 粉
    (108, 113, 196, 220),  # 紫
]

for m in markers:
    cx = int(m['cx'] * w)
    cy = int(m['cy'] * h)
    ew = m['w'] * w
    eh = m['h'] * h
    radius = int(max(min(ew, eh) * 0.25, 14))
    radius = min(radius, 26)

    color = colors[(m['id'] - 1) % len(colors)]

    # 画圆
    draw.ellipse(
        [cx - radius, cy - radius, cx + radius, cy + radius],
        fill=color,
        outline=(255, 255, 255, 255),
        width=2,
    )

    # 画编号
    label = str(m['id'])
    if font:
        bbox = draw.textbbox((0, 0), label, font=font)
        tw = bbox[2] - bbox[0]
        th = bbox[3] - bbox[1]
        draw.text((cx - tw // 2, cy - th // 2 - 1), label, fill=(255, 255, 255, 255), font=font)
    else:
        draw.text((cx - 4, cy - 7), label, fill=(255, 255, 255, 255))

result = Image.alpha_composite(img, overlay)
result.convert('RGB').save('$JPG_PATH', 'JPEG', quality=85)

print("")
print(f"SOM 标记已绘制到: $JPG_PATH")
print(f"共 {len(markers)} 个标记")
PYEOF

# 打开查看
if [ -f "$JPG_PATH" ]; then
    echo ""
    echo "打开图片查看效果..."
    open "$JPG_PATH"
    echo "测试文件: $WORK_DIR"
fi
