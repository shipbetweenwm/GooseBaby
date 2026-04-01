#!/usr/bin/env python3
"""
CUA 针对性 UI 组件定位 — 千问 VL 视觉模型 (test5)

与 test4 的区别：
  test4 = 全量扫描所有可交互组件（慢，30-80 个元素）
  test5 = 针对性查找指定组件（快，1-5 个元素）

用法：
  export DASHSCOPE_API_KEY="sk-xxx"

  # 查找搜索框
  python3 test5.py "搜索框"
  python3 test5.py "search bar" 3

  # 查找按钮
  python3 test5.py "登录按钮"
  python3 test5.py "login button" 5

  # 查找导航项
  python3 test5.py "设置菜单"
  python3 test5.py "settings menu" --model qwen-vl-max-latest

参数：
  python3 test5.py <query> [delay] [--model MODEL] [--key KEY]
"""

import subprocess, sys, os, json, time, base64, re, argparse

# ═══ 参数解析 ═══
parser = argparse.ArgumentParser(description="千问 VL 针对性 UI 组件定位")
parser.add_argument("query", help="要查找的 UI 组件描述（中英文均可）")
parser.add_argument("delay", nargs="?", type=int, default=3, help="截屏前等待秒数 (默认 3)")
parser.add_argument("--model", default="qwen-vl-plus-latest", help="千问VL模型名 (默认 qwen-vl-plus-latest，更快)")
parser.add_argument("--key", default=None, help="DashScope API Key (也可用环境变量 DASHSCOPE_API_KEY)")
args = parser.parse_args()

WORK_DIR = f"/tmp/som_test5_{os.getpid()}"
os.makedirs(WORK_DIR, exist_ok=True)
PNG_PATH = f"{WORK_DIR}/screen.png"
JPG_PATH = f"{WORK_DIR}/screen_target.jpg"

API_KEY = args.key or os.environ.get("DASHSCOPE_API_KEY", "")
MODEL = args.model
QUERY = args.query

print("=" * 60)
print("  CUA 针对性组件定位 — 千问 VL")
print(f"  模型: {MODEL}")
print(f"  目标: {QUERY}")
print("=" * 60)

if not API_KEY:
    print("\n  ❌ 未设置 API Key!")
    print("  请设置环境变量: export DASHSCOPE_API_KEY='sk-xxx'")
    print("  或使用参数: python3 test5.py '<query>' --key sk-xxx")
    sys.exit(1)
print(f"  ✅ API Key: {API_KEY[:8]}...{API_KEY[-4:]}")

# ═══ Step 0: 等待用户切换到目标应用 ═══
DELAY = args.delay
print(f"\n  ⏳ {DELAY} 秒后截屏，请先切换到你要测试的目标应用...")
for i in range(DELAY, 0, -1):
    print(f"     {i}...", flush=True)
    time.sleep(1)

# ═══ Step 1: 获取前景窗口并截屏 ═══
print("\n[1/4] 获取前景窗口并截屏...")

applescript = '''
tell application "System Events"
    set frontApp to name of first application process whose frontmost is true
    tell process frontApp
        tell front window
            set {posX, posY} to position
            set {winW, winH} to size
        end tell
    end tell
end tell
return (posX as text) & "," & (posY as text) & "," & (winW as text) & "," & (winH as text)
'''

win_rect = None
try:
    r = subprocess.run(["osascript", "-e", applescript], capture_output=True, text=True, timeout=2)
    if r.returncode == 0 and r.stdout.strip():
        parts = [int(x.strip()) for x in r.stdout.strip().split(",")]
        if len(parts) == 4:
            win_rect = parts
            print(f"  前景窗口: x={parts[0]}, y={parts[1]}, w={parts[2]}, h={parts[3]}")
except Exception as e:
    print(f"  ⚠ 获取前景窗口失败: {e}，回退全屏截图")

if win_rect:
    rect_str = f"{win_rect[0]},{win_rect[1]},{win_rect[2]},{win_rect[3]}"
    r = subprocess.run(["screencapture", "-x", "-R", rect_str, PNG_PATH], capture_output=True, text=True)
    if not os.path.exists(PNG_PATH) or os.path.getsize(PNG_PATH) < 1000:
        print(f"  ⚠ 窗口截图失败，回退全屏")
        r = subprocess.run(["screencapture", "-x", PNG_PATH], capture_output=True, text=True)
    else:
        print(f"  ✅ 仅截取前景窗口区域")
else:
    r = subprocess.run(["screencapture", "-x", PNG_PATH], capture_output=True, text=True)

sz = os.path.getsize(PNG_PATH) if os.path.exists(PNG_PATH) else 0
if sz < 1000:
    print(f"  ❌ 截屏失败或为空 ({sz} bytes)")
    sys.exit(1)
print(f"  ✅ 截屏成功 ({sz:,} bytes)")

# 获取分辨率
from PIL import Image, ImageDraw, ImageFont
img = Image.open(PNG_PATH)
img_w, img_h = img.size
print(f"  截图分辨率: {img_w}x{img_h}")

MAX_LONG_EDGE = 1920
scale_factor = 1.0
if max(img_w, img_h) > MAX_LONG_EDGE:
    scale_factor = MAX_LONG_EDGE / max(img_w, img_h)
    new_w = int(img_w * scale_factor)
    new_h = int(img_h * scale_factor)
    img_resized = img.resize((new_w, new_h), Image.LANCZOS)
    print(f"  缩放至: {new_w}x{new_h} (factor={scale_factor:.3f})")
else:
    img_resized = img
    new_w, new_h = img_w, img_h
    print(f"  无需缩放")

resized_path = f"{WORK_DIR}/screen_resized.jpg"
img_resized.convert("RGB").save(resized_path, "JPEG", quality=75)
with open(resized_path, "rb") as f:
    img_b64 = base64.b64encode(f.read()).decode("utf-8")
resized_size = os.path.getsize(resized_path)
print(f"  发送图片大小: {resized_size:,} bytes ({len(img_b64):,} chars base64)")

# ═══ Step 2: 调用千问 VL — 针对性定位 ═══
print(f"\n[2/4] 调用千问 VL ({MODEL}) — 针对性定位: \"{QUERY}\"...")

import urllib.request
import urllib.error

# 针对性 prompt：极简，只要求找到指定组件
SYSTEM_PROMPT = (
    "You are a UI element locator. Given a screenshot and a target description, "
    "find the matching element(s). Output bbox_2d in [0,1000) normalized coordinates. "
    "Also infer the element's function."
)

USER_PROMPT = f"""Find this UI element in the screenshot: "{QUERY}"

Return ALL matching elements as a JSON array. Each element must have:
- bbox_2d: [x1,y1,x2,y2] in [0,1000) normalized coordinates
- type: element type (button, input, link, icon_button, tab, menu, checkbox, toggle, etc.)
- label: visible text on the element (empty string if none)
- function: what clicking/interacting with it would do (be specific)

For icon-only elements, infer function from the icon shape.

If the element is NOT found, return: [{{"found":false}}]

Output JSON array ONLY:
[{{"bbox_2d":[x1,y1,x2,y2],"type":"button","label":"Send","function":"Send the current message"}}]"""

api_url = "https://dashscope.aliyuncs.com/api/v1/services/aigc/multimodal-generation/generation"

request_body = {
    "model": MODEL,
    "input": {
        "messages": [
            {"role": "system", "content": [{"text": SYSTEM_PROMPT}]},
            {
                "role": "user",
                "content": [
                    {"text": USER_PROMPT},
                    {"image": f"data:image/jpeg;base64,{img_b64}"}
                ]
            }
        ]
    },
    "parameters": {
        "result_format": "message",
        "max_tokens": 2048,
        "temperature": 0.1,
        "response_format": {"type": "json_object"},
    }
}

headers = {
    "Content-Type": "application/json",
    "Authorization": f"Bearer {API_KEY}",
}

t0 = time.time()
print(f"  请求中...")

try:
    req_data = json.dumps(request_body).encode("utf-8")
    req = urllib.request.Request(api_url, data=req_data, headers=headers, method="POST")
    with urllib.request.urlopen(req, timeout=60) as resp:
        resp_data = json.loads(resp.read().decode("utf-8"))
except urllib.error.HTTPError as e:
    body = e.read().decode("utf-8") if e.fp else ""
    print(f"  ❌ API 错误 [{e.code}]: {body[:500]}")
    sys.exit(1)
except Exception as e:
    print(f"  ❌ 请求失败: {e}")
    sys.exit(1)

elapsed = time.time() - t0
print(f"  ✅ 响应耗时: {elapsed:.1f}s")

# 提取模型回复
output = resp_data.get("output", {})
choices = output.get("choices", [])
if choices:
    msg_content = choices[0].get("message", {}).get("content", [])
    if isinstance(msg_content, list):
        content = "".join(item.get("text", "") for item in msg_content if isinstance(item, dict))
    elif isinstance(msg_content, str):
        content = msg_content
    else:
        content = str(msg_content)
else:
    content = ""
usage = resp_data.get("usage", {})
print(f"  Token: prompt={usage.get('input_tokens', '?')}, completion={usage.get('output_tokens', '?')}, total={usage.get('total_tokens', '?')}")

raw_path = f"{WORK_DIR}/vlm_response.txt"
with open(raw_path, "w") as f:
    f.write(content)
print(f"  模型回复: {content[:500]}")

# ═══ Step 3: 解析 JSON 结果 ═══
print(f"\n[3/4] 解析识别结果...")

def fix_json_string(s):
    s = re.sub(r'\)\s*([,\]\}])', r'}\1', s)
    s = re.sub(r'\)\s*$', '}', s)
    s = re.sub(r'("(?:[^"\\]|\\.)*")\s*\)', r'\1}', s)
    s = re.sub(r',\s*([}\]])', r'\1', s)
    open_sq = s.count('[') - s.count(']')
    open_cr = s.count('{') - s.count('}')
    if open_cr > 0:
        s += '}' * open_cr
    if open_sq > 0:
        s += ']' * open_sq
    return s

def extract_json_from_text(text):
    m = re.search(r'```(?:json)?\s*\n?(.*?)\n?\s*```', text, re.DOTALL)
    if m:
        text = m.group(1).strip()
    try:
        result = json.loads(text)
        if isinstance(result, list):
            return result
        if isinstance(result, dict) and "elements" in result:
            return result["elements"]
    except json.JSONDecodeError:
        pass
    m = re.search(r'\[.*\]', text, re.DOTALL)
    if m:
        raw = m.group(0)
        try:
            return json.loads(raw)
        except json.JSONDecodeError:
            pass
        fixed = fix_json_string(raw)
        try:
            result = json.loads(fixed)
            if isinstance(result, list):
                print(f"  ⚠ JSON 已自动修复")
                return result
        except json.JSONDecodeError:
            pass
    # 逐行兜底
    elements = []
    for line_match in re.finditer(r'\{[^{}]+\}', text):
        try:
            obj = json.loads(line_match.group(0))
            if "bbox" in obj or "bbox_2d" in obj or "box" in obj or "found" in obj:
                elements.append(obj)
        except json.JSONDecodeError:
            continue
    if elements:
        return elements
    return None

elements = extract_json_from_text(content)

if not elements:
    print(f"  ❌ 无法从模型回复中解析出 JSON 结构")
    print(f"  请检查原始回复: {raw_path}")
    sys.exit(1)

# 检查 "found": false
if len(elements) == 1 and isinstance(elements[0], dict) and elements[0].get("found") == False:
    print(f"  ⚠ 未找到匹配的元素: \"{QUERY}\"")
    sys.exit(0)

print(f"  ✅ 解析出 {len(elements)} 个匹配组件")

# ═══ 坐标映射 ═══
valid_elements = []
for elem in elements:
    bbox = elem.get("bbox_2d") or elem.get("bbox") or elem.get("box")
    if not bbox or len(bbox) < 4:
        continue
    try:
        x1, y1, x2, y2 = float(bbox[0]), float(bbox[1]), float(bbox[2]), float(bbox[3])
    except (ValueError, TypeError):
        continue
    if x2 <= x1 or y2 <= y1:
        continue
    valid_elements.append({
        "bbox": [x1, y1, x2, y2],
        "type": elem.get("type", elem.get("category", "unknown")),
        "label": elem.get("label", elem.get("description", elem.get("text", ""))),
        "function": elem.get("function", elem.get("action", "")),
    })

if not valid_elements:
    print(f"  ❌ 没有有效的 bbox 数据")
    sys.exit(1)

# 判断坐标系
all_x = [e["bbox"][0] for e in valid_elements] + [e["bbox"][2] for e in valid_elements]
all_y = [e["bbox"][1] for e in valid_elements] + [e["bbox"][3] for e in valid_elements]
max_coord = max(max(all_x), max(all_y))
min_x, min_y = min(all_x), min(all_y)

if max_coord <= 1.0:
    coord_system = "归一化 [0,1]"
    def map_coord(bbox):
        return [bbox[0] * img_w, bbox[1] * img_h, bbox[2] * img_w, bbox[3] * img_h]
elif max_coord <= 1000 and min_x >= 0:
    coord_system = "Qwen 归一化 [0,1000)"
    def map_coord(bbox):
        return [bbox[0] / 1000 * img_w, bbox[1] / 1000 * img_h, bbox[2] / 1000 * img_w, bbox[3] / 1000 * img_h]
elif max_coord <= max(new_w, new_h) * 1.1:
    coord_system = f"缩放图像素 ({new_w}x{new_h})"
    inv_factor = 1.0 / scale_factor if scale_factor != 1.0 else 1.0
    def map_coord(bbox):
        return [bbox[0] * inv_factor, bbox[1] * inv_factor, bbox[2] * inv_factor, bbox[3] * inv_factor]
elif max_coord <= max(img_w, img_h) * 1.1:
    coord_system = "原图像素"
    def map_coord(bbox):
        return bbox
else:
    ref_w = max(all_x) * 1.05
    ref_h = max(all_y) * 1.05
    coord_system = f"自适应 ({ref_w:.0f}x{ref_h:.0f})"
    def map_coord(bbox):
        sx = img_w / ref_w
        sy = img_h / ref_h
        return [bbox[0] * sx, bbox[1] * sy, bbox[2] * sx, bbox[3] * sy]

print(f"  坐标系: {coord_system}")

# 映射到原图像素
markers = []
for idx, elem in enumerate(valid_elements):
    mapped = map_coord(elem["bbox"])
    x1, y1, x2, y2 = int(mapped[0]), int(mapped[1]), int(mapped[2]), int(mapped[3])
    x1 = max(0, min(x1, img_w - 1))
    y1 = max(0, min(y1, img_h - 1))
    x2 = max(0, min(x2, img_w))
    y2 = max(0, min(y2, img_h))
    w, h = x2 - x1, y2 - y1
    if w < 2 or h < 2:
        continue
    markers.append({
        "id": len(markers) + 1,
        "x1": x1, "y1": y1, "x2": x2, "y2": y2,
        "cx": (x1 + x2) // 2, "cy": (y1 + y2) // 2,
        "w": w, "h": h,
        "type": elem["type"],
        "label": elem["label"][:30] if elem["label"] else "",
        "function": elem.get("function", "")[:60] if elem.get("function") else "",
    })

print(f"  有效标记: {len(markers)} 个")

# 打印结果
print(f"\n  ── 查找结果: \"{QUERY}\" ({len(markers)} 个匹配) ──")
for m in markers:
    func_str = f"\n         → {m['function']}" if m.get('function') else ""
    print(f"    [{m['id']}] {m['type']:<12} \"{m['label']:<24}\"")
    print(f"        位置: ({m['x1']}, {m['y1']}) → ({m['x2']}, {m['y2']}) | 中心: ({m['cx']}, {m['cy']}) | 大小: {m['w']}x{m['h']}{func_str}")
print(f"  ──")

# 保存结果
result_path = f"{WORK_DIR}/vlm_elements.json"
with open(result_path, "w") as f:
    json.dump(markers, f, ensure_ascii=False, indent=2)

# ═══ Step 4: 绘制标记图 ═══
print(f"\n[4/4] 绘制标记图...")

img_draw = img.convert("RGBA")
overlay = Image.new("RGBA", img_draw.size, (0, 0, 0, 0))
draw = ImageDraw.Draw(overlay)

# 加载字体
font = font_small = font_badge = None
for fp in [
    "/System/Library/Fonts/PingFang.ttc",
    "/System/Library/Fonts/STHeiti Light.ttc",
    "/System/Library/Fonts/Helvetica.ttc",
    "/Library/Fonts/Arial Unicode.ttf",
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
    (42, 161, 152, 220), (88, 110, 117, 220),
]

for m in markers:
    color = COLORS[(m["id"] - 1) % len(COLORS)]
    # 矩形边框（更粗，醒目）
    draw.rectangle([m["x1"], m["y1"], m["x2"], m["y2"]], outline=color, width=3)

    # 编号气泡
    badge_r = 18
    bx = m["x1"] + badge_r
    by = m["y1"] + badge_r
    draw.ellipse([bx - badge_r, by - badge_r, bx + badge_r, by + badge_r],
                 fill=color, outline=(255, 255, 255, 255), width=2)
    label = str(m["id"])
    if font_badge:
        bbox = draw.textbbox((0, 0), label, font=font_badge)
        tw, th = bbox[2] - bbox[0], bbox[3] - bbox[1]
        draw.text((bx - tw // 2, by - th // 2 - 1), label, fill=(255, 255, 255, 255), font=font_badge)
    else:
        draw.text((bx - 4, by - 7), label, fill=(255, 255, 255, 255))

    # 文字标签（上方显示查询目标）
    tag = f"{QUERY}"
    if m["label"]:
        tag += f" — {m['label'][:20]}"
    if font_small:
        tbbox = draw.textbbox((0, 0), tag, font=font_small)
        ttw = tbbox[2] - tbbox[0]
        tth = tbbox[3] - tbbox[1]
        tx = m["x1"]
        ty = m["y1"] - tth - 6
        if ty < 0:
            ty = m["y2"] + 4
        draw.rectangle([tx - 2, ty - 1, tx + ttw + 2, ty + tth + 2], fill=(0, 0, 0, 200))
        draw.text((tx, ty), tag, fill=(255, 255, 255, 255), font=font_small)

    # 功能描述（下方）
    if m.get("function"):
        func_tag = m["function"][:30]
        if font_small:
            fbbox = draw.textbbox((0, 0), func_tag, font=font_small)
            ftw = fbbox[2] - fbbox[0]
            fth = fbbox[3] - fbbox[1]
            fx = m["x1"]
            fy = m["y2"] + 4
            draw.rectangle([fx - 2, fy - 1, fx + ftw + 2, fy + fth + 2], fill=(0, 0, 0, 180))
            draw.text((fx, fy), func_tag, fill=(200, 255, 200, 255), font=font_small)

result_img = Image.alpha_composite(img_draw, overlay)
result_img.convert("RGB").save(JPG_PATH, "JPEG", quality=90)
jpg_size = os.path.getsize(JPG_PATH)
print(f"  ✅ 标记图: {JPG_PATH} ({jpg_size:,} bytes)")

# ═══ 汇总 ═══
print("\n" + "=" * 60)
print(f"  查询: \"{QUERY}\"")
print(f"  模型: {MODEL}")
print(f"  API 耗时: {elapsed:.1f}s")
print(f"  匹配: {len(markers)} 个")
print(f"  Token: {usage.get('input_tokens', '?')} + {usage.get('output_tokens', '?')} = {usage.get('total_tokens', '?')}")
print("=" * 60)
if markers:
    m = markers[0]
    print(f"\n  🎯 最佳匹配: [{m['id']}] {m['type']} \"{m['label']}\"")
    print(f"     点击坐标: ({m['cx']}, {m['cy']})")
    print(f"     bbox: ({m['x1']}, {m['y1']}, {m['x2']}, {m['y2']})")
    if m.get("function"):
        print(f"     功能: {m['function']}")
print(f"\n  截图: {PNG_PATH}")
print(f"  标记图: {JPG_PATH}")
print(f"  结果: {result_path}")

subprocess.run(["open", JPG_PATH])
