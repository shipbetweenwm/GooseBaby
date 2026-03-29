#!/bin/bash
# ═══════════════════════════════════════════════════════
# CUA SOM 端到端测试脚本
# 测试完整流程：截图 → UI树获取 → SOM标记绘制
# ═══════════════════════════════════════════════════════

set +e

WORK_DIR="/tmp/cua_som_test_$$"
rm -rf "$WORK_DIR"
mkdir -p "$WORK_DIR"

PASS=0
FAIL=0

pass() { echo "✅ $1"; PASS=$((PASS + 1)); }
fail() { echo "❌ $1"; FAIL=$((FAIL + 1)); }

echo "═══════════════════════════════════════"
echo "  CUA SOM 端到端测试"
echo "═══════════════════════════════════════"
echo ""

# ── 步骤1：截屏测试 ──
echo "── 步骤1：macOS 截屏 ──"
PNG_PATH="$WORK_DIR/test_screenshot.png"
JPG_PATH="$WORK_DIR/test_screenshot.jpg"

if screencapture -x "$PNG_PATH" 2>/dev/null; then
    if [ -f "$PNG_PATH" ] && [ -s "$PNG_PATH" ]; then
        SIZE=$(stat -f%z "$PNG_PATH")
        pass "截屏成功: $PNG_PATH (${SIZE} bytes)"
    else
        fail "截屏文件为空或不存在"
        exit 1
    fi
else
    fail "screencapture 命令失败"
    exit 1
fi
echo ""

# ── 步骤2：获取逻辑分辨率 ──
echo "── 步骤2：屏幕分辨率 ──"

# 从截图文件获取物理像素尺寸
IMG_W=$(sips -g pixelWidth "$PNG_PATH" 2>/dev/null | grep pixelWidth | awk '{print $2}')
IMG_H=$(sips -g pixelHeight "$PNG_PATH" 2>/dev/null | grep pixelHeight | awk '{print $2}')

# 获取 Retina 缩放因子
SCALE=$(system_profiler SPDisplaysDataType 2>/dev/null | grep "Retina" | head -1 | wc -l | tr -d ' ')
if [ "$SCALE" = "1" ]; then
    SCALE_FACTOR=2
else
    SCALE_FACTOR=1
fi

# 逻辑分辨率 = 物理像素 / scaleFactor
LOGICAL_W=$((IMG_W / SCALE_FACTOR))
LOGICAL_H=$((IMG_H / SCALE_FACTOR))

echo "  物理像素: ${IMG_W} x ${IMG_H}"
echo "  Retina: ${SCALE_FACTOR}x"
echo "  逻辑分辨率: ${LOGICAL_W} x ${LOGICAL_H}"
echo ""

# ── 步骤3：PNG → JPEG 转换测试 ──
echo "── 步骤3：sips PNG → JPEG 转换 ──"
sips -s format jpeg -s formatOptions 85 "$PNG_PATH" --out "$JPG_PATH" 2>/dev/null
if [ -f "$JPG_PATH" ] && [ -s "$JPG_PATH" ]; then
    JPG_SIZE=$(stat -f%z "$JPG_PATH")
    pass "JPEG 转换成功: $JPG_PATH (${JPG_SIZE} bytes)"
else
    fail "JPEG 转换失败"
fi
echo ""

# ── 步骤4：Pillow 可用性测试 ──
echo "── 步骤4：Pillow 可用性 ──"
if python3 -c "from PIL import Image, ImageDraw, ImageFont; print('OK')" 2>/dev/null; then
    pass "Pillow 已安装"
else
    fail "Pillow 未安装，尝试安装..."
    pip3 install Pillow -q 2>/dev/null
    if python3 -c "from PIL import Image, ImageDraw, ImageFont; print('OK')" 2>/dev/null; then
        pass "Pillow 安装成功"
    else
        fail "Pillow 安装失败"
        exit 1
    fi
fi
echo ""

# ── 步骤5：pyobjc 可用性测试 ──
echo "── 步骤5：pyobjc 可用性（UI树依赖） ──"
PYOBJC_OK=false
if python3 -c "
from ApplicationServices import (
    AXUIElementCreateSystemWide, AXUIElementCopyAttributeValue,
    kAXFocusedApplicationAttribute
)
print('OK')
" 2>/dev/null; then
    pass "pyobjc 已安装"
    PYOBJC_OK=true
else
    fail "pyobjc 未安装（UI树获取可能失败）"
    echo "  尝试安装 pyobjc..."
    pip3 install pyobjc-framework-ApplicationServices -q 2>/dev/null && \
    PYOBJC_OK=true && pass "pyobjc 安装成功" || fail "pyobjc 安装失败"
fi
echo ""

# ── 步骤6：UI 树获取测试 ──
echo "── 步骤6：UI 树获取（pyobjc，3秒超时） ──"
UI_TREE_JSON="$WORK_DIR/ui_tree.json"
MARKER_COUNT=0

if [ "$PYOBJC_OK" = true ]; then
    python3 -c "
import sys, json, time, re

start = time.time()

from ApplicationServices import (
    AXUIElementCreateApplication, AXUIElementCopyAttributeValue,
    kAXChildrenAttribute, kAXRoleAttribute, kAXTitleAttribute,
    kAXValueAttribute, kAXDescriptionAttribute, kAXPositionAttribute,
    kAXSizeAttribute, kAXEnabledAttribute, kAXRoleDescriptionAttribute,
)
from AppKit import NSWorkspace

def _get_attr(element, attr):
    try:
        result = AXUIElementCopyAttributeValue(element, attr, None)
        if isinstance(result, tuple):
            err, val = result
            if err != 0:
                return None
            return val
        return result
    except:
        return None

def _parse_ax_value(val, p1, p2):
    try:
        desc = val.description()
        m = re.search(p1, desc)
        if m: return (float(m.group(1)), float(m.group(2)))
        m = re.search(p2, desc)
        if m: return (float(m.group(1)), float(m.group(2)))
    except:
        pass
    return None

def _get_point(element):
    pos = _get_attr(element, kAXPositionAttribute)
    if pos:
        r = _parse_ax_value(pos, r'x:([-\d.]+)\s+y:([-\d.]+)', r'x:([-\d.]+),\s*y:([-\d.]+)')
        if r: return {'x': r[0], 'y': r[1]}
    return None

def _get_size(element):
    sz = _get_attr(element, kAXSizeAttribute)
    if sz:
        r = _parse_ax_value(sz, r'w:([-\d.]+)\s+h:([-\d.]+)', r'width:([-\d.]+)\s+height:([-\d.]+)')
        if r: return {'width': r[0], 'height': r[1]}
    return None

def _node_to_dict(element, depth, max_depth):
    if depth > max_depth:
        return None
    result = {}
    role = _get_attr(element, kAXRoleAttribute)
    title = _get_attr(element, kAXTitleAttribute)
    value = _get_attr(element, kAXValueAttribute)
    desc = _get_attr(element, kAXDescriptionAttribute)

    result['role'] = str(role) if role else ''
    result['title'] = str(title) if title else ''

    pos = _get_point(element)
    if pos:
        result['x'] = pos['x']
        result['y'] = pos['y']

    size = _get_size(element)
    if size:
        result['width'] = size['width']
        result['height'] = size['height']

    children_val = _get_attr(element, kAXChildrenAttribute)
    child_list = []
    if children_val:
        try:
            for child in children_val:
                d = _node_to_dict(child, depth + 1, max_depth)
                if d:
                    child_list.append(d)
        except:
            pass
    if child_list:
        result['children'] = child_list

    return result

# 通过 NSWorkspace 获取前台应用（不依赖 kAXFocusedApplicationAttribute）
ws = NSWorkspace.sharedWorkspace()
front_app = ws.frontmostApplication()
if not front_app:
    print(json.dumps({'error': 'no frontmost app', 'role': 'system', 'title': 'none', 'children': []}))
    sys.exit(0)

app_pid = int(front_app.processIdentifier())
app_title = front_app.localizedName() or ''
bundle_id = front_app.bundleIdentifier() or ''

# 通过 PID 创建 AX 元素
app_elem = AXUIElementCreateApplication(app_pid)

app_dict = _node_to_dict(app_elem, 0, 6)
if not app_dict:
    app_dict = {'role': 'application', 'title': app_title, 'children': []}
app_dict['title'] = app_title
app_dict['bundleId'] = bundle_id

elapsed = time.time() - start
print(f'TIME:{elapsed:.2f}s', file=sys.stderr)
print(json.dumps(app_dict, ensure_ascii=False))
" 2>"$WORK_DIR/ui_tree_time.txt" > "$UI_TREE_JSON"
    
    if [ -s "$UI_TREE_JSON" ]; then
        ELAPSED=$(cat "$WORK_DIR/ui_tree_time.txt")
        NODE_COUNT=$(python3 -c "
import json
data = json.load(open('$UI_TREE_JSON'))
def count(n): return 1 + sum(count(c) for c in n.get('children', []))
print(count(data))
")
        echo "  UI 树: app=$(python3 -c "import json; print(json.load(open('$UI_TREE_JSON')).get('title','?'))" 2>/dev/null), $NODE_COUNT 个节点, 耗时 $ELAPSED"
        
        if [ "$NODE_COUNT" -gt "0" ]; then
            pass "UI 树获取成功 ($NODE_COUNT 节点)"
        else
            fail "UI 树为空"
        fi
    else
        fail "UI 树 JSON 输出为空"
    fi
else
    fail "跳过（pyobjc 不可用）"
fi
echo ""

# ── 步骤7：提取 SOM 标记 ──
echo "── 步骤7：提取 SOM 可交互标记 ──"
MARKERS_JSON="$WORK_DIR/markers.json"

if [ -s "$UI_TREE_JSON" ]; then
    python3 -c "
import json

with open('$UI_TREE_JSON') as f:
    data = json.load(f)

# 获取 PNG 实际尺寸
from PIL import Image
img = Image.open('$PNG_PATH')
img_w, img_h = img.size
print(f'  PNG 尺寸: {img_w} x {img_h} (Retina 2x)', file=__import__('sys').stderr)

# 逻辑分辨率
logical_w = $LOGICAL_W
logical_h = $LOGICAL_H
print(f'  逻辑分辨率: {logical_w} x {logical_h}', file=__import__('sys').stderr)

interactive_roles = {
    'AXButton', 'AXTextField', 'AXTextArea', 'AXPopUpButton',
    'AXCheckBox', 'AXRadioButton', 'AXLink', 'AXStaticText',
    'AXMenuItem', 'AXMenuButton', 'AXComboBox', 'AXSlider',
    'AXStepper', 'AXIncrementor', 'AXDecrementor',
    'AXDisclosureTriangle', 'AXTabGroup', 'AXImage',
    'button', 'text field', 'text area', 'checkbox',
    'radio button', 'link', 'menu item', 'menu button',
    'slider', 'image', 'list', 'search field',
}

markers = []
next_id = 1

def traverse(node):
    global next_id
    role = node.get('role', '').lower()
    
    is_interactive = False
    for ir in interactive_roles:
        if ir.lower() in role:
            is_interactive = True
            break
    
    # StaticText 需要有 title/value
    if is_interactive and 'statictext' in role:
        title = node.get('title', '')
        value = node.get('value', '')
        desc = node.get('description', '')
        if not title and not value and not desc:
            is_interactive = False
    
    if (is_interactive and 
        'x' in node and 'y' in node and 
        'width' in node and 'height' in node):
        
        nx = node['x'] / logical_w * 1000
        ny = node['y'] / logical_h * 1000
        nw = node['width'] / logical_w * 1000
        nh = node['height'] / logical_h * 1000
        
        area = nw * nh
        if area >= 10 and area <= 800000 and nw >= 3 and nh >= 3:
            cx = nx + nw / 2
            cy = ny + nh / 2
            # 去重检查
            overlaps = False
            for m in markers:
                dx = cx - m['cx']
                dy = cy - m['cy']
                if dx*dx + dy*dy < 400:
                    overlaps = True
                    break
            if not overlaps and len(markers) < 50:
                markers.append({
                    'id': next_id,
                    'cx': cx / 1000.0,  # 归一化到 0~1
                    'cy': cy / 1000.0,
                    'w': nw / 1000.0,
                    'h': nh / 1000.0,
                    'role': node.get('role', ''),
                    'title': node.get('title', ''),
                })
                next_id += 1
    
    for child in node.get('children', []):
        traverse(child)

traverse(data)
with open('$MARKERS_JSON', 'w') as f:
    json.dump(markers, f, ensure_ascii=False)
print(f'  提取了 {len(markers)} 个标记')
for m in markers[:10]:
    print(f'    [{m[\"id\"]}] {m[\"role\"]} \"{m[\"title\"]}\" center=({m[\"cx\"]*1000:.0f}, {m[\"cy\"]*1000:.0f})')
if len(markers) > 10:
    print(f'    ... 还有 {len(markers)-10} 个')
" 2>&1
    
    MARKER_COUNT=$(python3 -c "import json; print(len(json.load(open('$MARKERS_JSON'))))" 2>/dev/null)
    
    if [ -n "$MARKER_COUNT" ] && [ "$MARKER_COUNT" -gt "0" ]; then
        pass "提取了 $MARKER_COUNT 个可交互标记"
    else
        fail "未提取到任何可交互标记（可能 UI 元素无坐标信息）"
    fi
else
    fail "跳过（无 UI 树数据）"
fi
echo ""

# ── 步骤8：Pillow 绘制 SOM 标记 ──
echo "── 步骤8：Pillow 在截图上绘制 SOM 标记 ──"
SOM_PNG="$WORK_DIR/som_marked.png"
SOM_JPG="$WORK_DIR/som_marked.jpg"

if [ -n "$MARKER_COUNT" ] && [ "$MARKER_COUNT" -gt "0" ]; then
    # 先复制 PNG（保留原文件）
    cp "$PNG_PATH" "$SOM_PNG"
    
    python3 -c "
import json, sys
from PIL import Image, ImageDraw, ImageFont

png_path = '$SOM_PNG'
with open('$MARKERS_JSON') as f:
    markers = json.load(f)

img = Image.open(png_path).convert('RGBA')
w, h = img.size
print(f'  图像尺寸: {w} x {h}')

overlay = Image.new('RGBA', img.size, (0, 0, 0, 0))
draw = ImageDraw.Draw(overlay)

font = None
for fp in ['/System/Library/Fonts/Helvetica.ttc', '/System/Library/Fonts/SFNSText.ttf', '/Library/Fonts/Arial.ttf']:
    try:
        font = ImageFont.truetype(fp, 14)
        print(f'  字体: {fp}')
        break
    except:
        continue

fill_color = (220, 50, 47, 220)
border_color = (255, 255, 255, 255)
text_color = (255, 255, 255, 255)

for m in markers:
    cx = int(m['cx'] * w)
    cy = int(m['cy'] * h)
    ew = m['w'] * w
    eh = m['h'] * h
    radius = int(max(min(ew, eh) * 0.2, 12))
    radius = min(radius, 22)
    
    draw.ellipse(
        [cx - radius, cy - radius, cx + radius, cy + radius],
        fill=fill_color,
        outline=border_color,
        width=2,
    )
    
    label = str(m['id'])
    if font:
        bbox = draw.textbbox((0, 0), label, font=font)
        tw = bbox[2] - bbox[0]
        th = bbox[3] - bbox[1]
        draw.text((cx - tw // 2, cy - th // 2 - 1), label, fill=text_color, font=font)
    else:
        draw.text((cx - 3, cy - 6), label, fill=text_color)

result = Image.alpha_composite(img, overlay)
result.convert('RGB').save(png_path, 'PNG')
print(f'  绘制完成: {len(markers)} 个标记')
print(f'OK:{len(markers)}')
" 2>&1
    
    if [ -f "$SOM_PNG" ] && [ -s "$SOM_PNG" ]; then
        SOM_SIZE=$(stat -f%z "$SOM_PNG")
        pass "SOM 标记 PNG 生成成功: $SOM_PNG (${SOM_SIZE} bytes)"
    else
        fail "SOM 标记 PNG 生成失败"
    fi
    
    # ── 步骤9：SOM PNG → JPEG 转换 ──
    echo ""
    echo "── 步骤9：SOM PNG → JPEG 转换 ──"
    sips -s format jpeg -s formatOptions 85 "$SOM_PNG" --out "$SOM_JPG" 2>/dev/null
    if [ -f "$SOM_JPG" ] && [ -s "$SOM_JPG" ]; then
        JPG2_SIZE=$(stat -f%z "$SOM_JPG")
        pass "SOM JPEG 生成成功: $SOM_JPG (${JPG2_SIZE} bytes)"
    else
        fail "SOM JPEG 转换失败"
    fi
else
    echo "  跳过（无标记可绘制）"
    # 创建一个模拟标记来测试绘制流程
    echo ""
    echo "── 步骤8b：模拟标记绘制测试 ──"
    cp "$PNG_PATH" "$SOM_PNG"
    
    python3 -c "
import json
markers = [
    {'id': 1, 'cx': 0.15, 'cy': 0.25, 'w': 0.08, 'h': 0.04},
    {'id': 2, 'cx': 0.50, 'cy': 0.50, 'w': 0.10, 'h': 0.05},
    {'id': 3, 'cx': 0.80, 'cy': 0.75, 'w': 0.06, 'h': 0.03},
]
with open('$MARKERS_JSON', 'w') as f:
    json.dump(markers, f)
print('  创建了 3 个模拟标记')
" 2>&1
    
    python3 -c "
import json, sys
from PIL import Image, ImageDraw, ImageFont

png_path = '$SOM_PNG'
with open('$MARKERS_JSON') as f:
    markers = json.load(f)

img = Image.open(png_path).convert('RGBA')
w, h = img.size
overlay = Image.new('RGBA', img.size, (0, 0, 0, 0))
draw = ImageDraw.Draw(overlay)

font = None
for fp in ['/System/Library/Fonts/Helvetica.ttc', '/System/Library/Fonts/SFNSText.ttf']:
    try:
        font = ImageFont.truetype(fp, 14)
        break
    except:
        continue

for m in markers:
    cx = int(m['cx'] * w)
    cy = int(m['cy'] * h)
    radius = 18
    draw.ellipse([cx-radius, cy-radius, cx+radius, cy+radius], fill=(220,50,47,220), outline=(255,255,255,255), width=2)
    label = str(m['id'])
    if font:
        bbox = draw.textbbox((0,0), label, font=font)
        tw, th = bbox[2]-bbox[0], bbox[3]-bbox[1]
        draw.text((cx-tw//2, cy-th//2-1), label, fill=(255,255,255,255), font=font)

result = Image.alpha_composite(img, overlay)
result.convert('RGB').save(png_path, 'PNG')
print('OK:3')
" 2>&1
    
    if [ -f "$SOM_PNG" ] && [ -s "$SOM_PNG" ]; then
        pass "模拟标记绘制成功"
    else
        fail "模拟标记绘制失败"
    fi
    
    sips -s format jpeg -s formatOptions 85 "$SOM_PNG" --out "$SOM_JPG" 2>/dev/null
    if [ -f "$SOM_JPG" ] && [ -s "$SOM_JPG" ]; then
        pass "模拟标记 JPEG 转换成功"
    fi
fi
echo ""

# ── 步骤10：对比验证 ──
echo "── 步骤10：文件对比 ──"
echo ""
echo "  原始截图:  $PNG_PATH ($(stat -f%z "$PNG_PATH") bytes)"
echo "  原始 JPEG: $JPG_PATH ($(stat -f%z "$JPG_PATH") bytes)"
if [ -f "$SOM_PNG" ]; then
    echo "  SOM PNG:   $SOM_PNG ($(stat -f%z "$SOM_PNG") bytes)"
fi
if [ -f "$SOM_JPG" ]; then
    echo "  SOM JPEG:  $SOM_JPG ($(stat -f%z "$SOM_JPG") bytes)"
fi
echo ""

# 检查 SOM 图片是否与原始不同（说明标记确实画上了）
if [ -f "$SOM_JPG" ] && [ -f "$JPG_PATH" ]; then
    ORIG_MD5=$(md5 -q "$JPG_PATH" 2>/dev/null)
    SOM_MD5=$(md5 -q "$SOM_JPG" 2>/dev/null)
    if [ "$ORIG_MD5" != "$SOM_MD5" ]; then
        pass "SOM JPEG 与原始 JPEG 不同（标记已绘制）"
    else
        fail "SOM JPEG 与原始 JPEG 相同（标记可能未绘制）"
    fi
fi
echo ""

# ── 打开图片查看 ──
echo "═══════════════════════════════════════"
echo "  结果汇总"
echo "═══════════════════════════════════════"
echo ""
echo "  通过: $PASS  |  失败: $FAIL"
echo ""

if [ -f "$SOM_JPG" ]; then
    echo "  打开 SOM 标记后的 JPEG 查看效果："
    echo "    open \"$SOM_JPG\""
    echo ""
    open "$SOM_JPG"
fi

# 清理（保留图片供查看）
echo "  测试文件保存在: $WORK_DIR"
echo "  清理命令: rm -rf $WORK_DIR"

if [ "$FAIL" -eq 0 ]; then
    echo ""
    echo "🎉 所有测试通过！"
else
    echo ""
    echo "⚠️  有 $FAIL 个测试失败，请检查上方日志"
fi

exit $FAIL
