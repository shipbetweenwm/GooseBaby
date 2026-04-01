#!/usr/bin/env python3
"""
CUA 纯视觉兜底方案测试 — 千问 VL 大模型识别 UI 可交互组件 (test4)

目标：
  不依赖 macOS AX 辅助功能 API，纯粹通过截图 + 千问视觉模型
  识别屏幕上所有可交互的 UI 组件（按钮、输入框、链接、菜单等），
  返回每个组件的 bbox 坐标和描述，绘制 SOM 标记图。

用法：
  # 需要先设置 DASHSCOPE_API_KEY 环境变量
  export DASHSCOPE_API_KEY="sk-xxx"

  python3 test4.py [delay_seconds] [--model MODEL]

  示例:
    python3 test4.py 3                          # 3秒延迟，默认模型
    python3 test4.py 5 --model qwen-vl-max      # 5秒延迟，指定模型
"""

import subprocess, sys, os, json, time, base64, re, argparse

# ═══ 参数解析 ═══
parser = argparse.ArgumentParser(description="千问 VL 纯视觉 UI 组件识别测试")
parser.add_argument("delay", nargs="?", type=int, default=3, help="截屏前等待秒数 (默认 3)")
parser.add_argument("--model", default="qwen-vl-max-latest", help="千问VL模型名 (默认 qwen-vl-max-latest)")
parser.add_argument("--key", default=None, help="DashScope API Key (也可用环境变量 DASHSCOPE_API_KEY)")
args = parser.parse_args()

WORK_DIR = f"/tmp/som_test4_{os.getpid()}"
os.makedirs(WORK_DIR, exist_ok=True)
PNG_PATH = f"{WORK_DIR}/screen.png"
JPG_PATH = f"{WORK_DIR}/screen_vision_som.jpg"

API_KEY = args.key or os.environ.get("DASHSCOPE_API_KEY", "")
MODEL = args.model

print("=" * 60)
print("  CUA 纯视觉兜底方案 — 千问 VL UI 组件识别")
print(f"  模型: {MODEL}")
print("=" * 60)

if not API_KEY:
    print("\n  ❌ 未设置 API Key!")
    print("  请设置环境变量: export DASHSCOPE_API_KEY='sk-xxx'")
    print("  或使用参数: python3 test4.py --key sk-xxx")
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

# 用 AppleScript 一次性获取前景窗口的 position 和 size
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

# 智能缩放：控制长边 ≤ 2560，平衡精度与速度
# 原始 Retina 截图 5120x2880 直接发太慢（base64 大 + 模型处理 tile 多）
# 缩到 2240 长边，在清晰度和速度之间取折中
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

# ═══ Step 2: 调用千问 VL 视觉模型（DashScope 原生接口）═══
print(f"\n[2/4] 调用千问 VL ({MODEL}) — DashScope 原生接口...")

import urllib.request
import urllib.error

# 构造 prompt —— Qwen-VL 原生 grounding 格式（bbox_2d 归一化 0-1000 坐标）
# 精简 prompt：减少 token 消耗加速推理，同时保持检测完整性
SYSTEM_PROMPT = "You are an exhaustive UI element detector. Find ALL interactable elements. Output bbox_2d in [0,1000) normalized coordinates. When in doubt, INCLUDE the element."

USER_PROMPT = """Detect ALL interactable UI elements in this screenshot. Be EXHAUSTIVE.

Scan systematically: menu bar → title bar → sidebar → main content → right panel → bottom bar.

Include: buttons, links, inputs, menus, tabs, checkboxes, radio buttons, dropdowns, toggles, icon buttons, nav items, toolbar buttons, window controls (close/min/max), status bar items, scroll bars, sliders, cards, list items.

For icons without text, infer function (magnifier=search, gear=settings, X=close, bell=notifications, trash=delete, +=add, …=more, pencil=edit, arrows=back/forward, heart=favorite, share, download, upload, person=profile, home, folder, eye=preview, lock, star, refresh, filter, sort, copy, play, pause).

Output JSON array ONLY:
[{"bbox_2d":[x1,y1,x2,y2],"type":"button","label":"Send"}]"""

# ═══ 使用 DashScope 原生多模态接口 ═══
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
        "max_tokens": 8192,              # 够用即可，避免不必要的推理时间
        "temperature": 0.1,
        "response_format": {"type": "json_object"},  # 强制 JSON 输出
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
    with urllib.request.urlopen(req, timeout=120) as resp:
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

# 提取模型回复 — DashScope 原生接口响应格式
# 格式: {"output": {"choices": [{"message": {"content": [{"text": "..."}]}}]}, "usage": {...}}
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
print(f"  Token 用量: prompt={usage.get('input_tokens', usage.get('prompt_tokens', '?'))}, completion={usage.get('output_tokens', usage.get('completion_tokens', '?'))}, total={usage.get('total_tokens', '?')}")

# 保存原始回复
raw_path = f"{WORK_DIR}/vlm_response.txt"
with open(raw_path, "w") as f:
    f.write(content)
print(f"  原始回复保存: {raw_path}")
print(f"\n  --- 模型原始回复 (前 2000 字) ---")
print(content[:2000])
if len(content) > 2000:
    print(f"  ... (共 {len(content)} 字)")
print(f"  ---")

# ═══ Step 3: 解析 JSON 结果 ═══
print(f"\n[3/4] 解析识别结果...")

def fix_json_string(s):
    """修复模型常见的 JSON 输出错误"""
    # 1. 修复 ) 误用为 ] 或 } 的情况，例如 "label": "xxx")
    s = re.sub(r'\)\s*([,\]\}])', r'}\1', s)   # "xxx") , → "xxx"} ,
    s = re.sub(r'\)\s*$', '}', s)                # 末尾的 )
    # 修复 {...) 为 {...}
    s = re.sub(r'("(?:[^"\\]|\\.)*")\s*\)', r'\1}', s)
    
    # 2. 修复重复 key（保留最后一个）—— 逐行处理
    # 例如 "label": "tab", "type": "tab", "label": "插入"
    # JSON 标准中重复 key 的行为未定义，Python json 模块会取最后一个
    # 但有些情况会导致解析错误，这里做预处理
    
    # 3. 移除尾部多余逗号: ,] 或 ,}
    s = re.sub(r',\s*([}\]])', r'\1', s)
    
    # 4. 修复缺少闭合的情况
    # 统计括号
    open_sq = s.count('[') - s.count(']')
    open_cr = s.count('{') - s.count('}')
    if open_cr > 0:
        s += '}' * open_cr
    if open_sq > 0:
        s += ']' * open_sq
    
    return s

def extract_json_from_text(text):
    """从模型回复中提取 JSON 数组（可能包裹在 ```json ``` 中），有容错修复能力"""
    # 尝试提取 ```json ... ``` 代码块
    m = re.search(r'```(?:json)?\s*\n?(.*?)\n?\s*```', text, re.DOTALL)
    if m:
        text = m.group(1).strip()
    
    # 尝试直接解析
    try:
        result = json.loads(text)
        if isinstance(result, list):
            return result
        if isinstance(result, dict) and "elements" in result:
            return result["elements"]
    except json.JSONDecodeError:
        pass
    
    # 尝试找到第一个 [ ... ] 结构
    m = re.search(r'\[.*\]', text, re.DOTALL)
    if m:
        raw = m.group(0)
        try:
            return json.loads(raw)
        except json.JSONDecodeError:
            pass
        # 尝试修复后再解析
        fixed = fix_json_string(raw)
        try:
            result = json.loads(fixed)
            if isinstance(result, list):
                print(f"  ⚠ JSON 有格式错误，已自动修复")
                return result
        except json.JSONDecodeError:
            pass
    
    # 最后兜底：逐行提取 JSON 对象
    print(f"  ⚠ 整体 JSON 解析失败，尝试逐行提取...")
    elements = []
    for line_match in re.finditer(r'\{[^{}]+\}', text):
        try:
            obj = json.loads(line_match.group(0))
            if "bbox" in obj or "bbox_2d" in obj or "box" in obj:
                elements.append(obj)
        except json.JSONDecodeError:
            # 尝试修复单个对象
            fixed_obj = fix_json_string(line_match.group(0))
            try:
                obj = json.loads(fixed_obj)
                if "bbox" in obj or "bbox_2d" in obj or "box" in obj:
                    elements.append(obj)
            except json.JSONDecodeError:
                continue
    if elements:
        print(f"  ⚠ 逐行提取恢复了 {len(elements)} 个元素")
        return elements
    
    return None

elements = extract_json_from_text(content)

if not elements:
    print(f"  ❌ 无法从模型回复中解析出 JSON 结构")
    print(f"  请检查原始回复: {raw_path}")
    sys.exit(1)

print(f"  ✅ 解析出 {len(elements)} 个 UI 组件")

# ═══ 坐标自适应映射 ═══
# Qwen-VL 原生 grounding 使用 [0, 1000) 归一化坐标
# 但仍保留自适应逻辑以兼容其他输出格式

valid_elements = []
for elem in elements:
    # 优先取 bbox_2d（Qwen 原生 grounding 格式），再取 bbox / box
    bbox = elem.get("bbox_2d") or elem.get("bbox") or elem.get("box")
    if not bbox or len(bbox) < 4:
        continue
    try:
        x1, y1, x2, y2 = float(bbox[0]), float(bbox[1]), float(bbox[2]), float(bbox[3])
    except (ValueError, TypeError):
        continue
    # 跳过无效 bbox (x2 <= x1 或 y2 <= y1)
    if x2 <= x1 or y2 <= y1:
        continue
    valid_elements.append({
        "bbox": [x1, y1, x2, y2],
        "type": elem.get("type", elem.get("category", "unknown")),
        "label": elem.get("label", elem.get("description", elem.get("text", ""))),
    })

if not valid_elements:
    print(f"  ❌ 没有有效的 bbox 数据")
    sys.exit(1)

# 分析坐标范围，判断坐标系
all_coords = []
for e in valid_elements:
    all_coords.extend(e["bbox"])
all_x = [e["bbox"][0] for e in valid_elements] + [e["bbox"][2] for e in valid_elements]
all_y = [e["bbox"][1] for e in valid_elements] + [e["bbox"][3] for e in valid_elements]
max_x = max(all_x)
max_y = max(all_y)
min_x = min(all_x)
min_y = min(all_y)
max_coord = max(max_x, max_y)

print(f"\n  --- 坐标分析 ---")
print(f"  发送图尺寸: {new_w}x{new_h}")
print(f"  原始截图尺寸: {img_w}x{img_h}")
print(f"  坐标范围 X: {min_x:.1f} ~ {max_x:.1f}")
print(f"  坐标范围 Y: {min_y:.1f} ~ {max_y:.1f}")

# 判断坐标系并映射到原图像素坐标
# 优先判断 [0, 1000) 归一化坐标（Qwen-VL 原生 grounding 格式）
if max_coord <= 1.0:
    # 归一化 [0, 1] 坐标
    coord_system = "归一化 [0,1]"
    def map_coord(bbox):
        return [bbox[0] * img_w, bbox[1] * img_h, bbox[2] * img_w, bbox[3] * img_h]
elif max_coord <= 1000 and min_x >= 0:
    # [0, 1000) 归一化坐标 — Qwen-VL 原生 grounding 输出
    coord_system = "Qwen 归一化 [0,1000)"
    def map_coord(bbox):
        return [bbox[0] / 1000 * img_w, bbox[1] / 1000 * img_h, bbox[2] / 1000 * img_w, bbox[3] / 1000 * img_h]
elif max_x <= new_w * 1.1 and max_y <= new_h * 1.1:
    # 相对于缩放后图片的像素坐标
    coord_system = f"缩放图像素 ({new_w}x{new_h})"
    inv_factor = 1.0 / scale_factor if scale_factor != 1.0 else 1.0
    def map_coord(bbox):
        return [bbox[0] * inv_factor, bbox[1] * inv_factor, bbox[2] * inv_factor, bbox[3] * inv_factor]
elif max_x <= img_w * 1.1 and max_y <= img_h * 1.1:
    # 直接就是原图像素坐标
    coord_system = "原图像素"
    def map_coord(bbox):
        return bbox
else:
    # 自适应：用极值推断参考分辨率
    ref_w = max_x * 1.05
    ref_h = max_y * 1.05
    coord_system = f"自适应参考 ({ref_w:.0f}x{ref_h:.0f})"
    def map_coord(bbox):
        sx = img_w / ref_w
        sy = img_h / ref_h
        return [bbox[0] * sx, bbox[1] * sy, bbox[2] * sx, bbox[3] * sy]

print(f"  判定坐标系: {coord_system}")

# 映射坐标到原图像素
markers = []
for idx, elem in enumerate(valid_elements):
    mapped = map_coord(elem["bbox"])
    x1, y1, x2, y2 = int(mapped[0]), int(mapped[1]), int(mapped[2]), int(mapped[3])
    # 裁剪到图片范围
    x1 = max(0, min(x1, img_w - 1))
    y1 = max(0, min(y1, img_h - 1))
    x2 = max(0, min(x2, img_w))
    y2 = max(0, min(y2, img_h))
    w = x2 - x1
    h = y2 - y1
    if w < 2 or h < 2:
        continue
    # 过滤占屏幕面积超 50% 的
    if w * h > img_w * img_h * 0.5:
        continue
    markers.append({
        "id": len(markers) + 1,
        "x1": x1, "y1": y1, "x2": x2, "y2": y2,
        "cx": (x1 + x2) // 2, "cy": (y1 + y2) // 2,
        "w": w, "h": h,
        "type": elem["type"],
        "label": elem["label"][:30] if elem["label"] else "",
    })

print(f"  映射后有效标记: {len(markers)} 个")

# 打印识别结果
print(f"\n  --- 识别到的 UI 组件 ({len(markers)} 个) ---")
for m in markers:
    print(f"    [{m['id']:>3}] {m['type']:<12} \"{m['label']:<24}\" bbox=({m['x1']},{m['y1']},{m['x2']},{m['y2']}) {m['w']}x{m['h']}")
print(f"  ---")

# 保存结构化结果
result_path = f"{WORK_DIR}/vlm_elements.json"
with open(result_path, "w") as f:
    json.dump(markers, f, ensure_ascii=False, indent=2)
print(f"  结果保存: {result_path}")

# ═══ Step 4: 绘制 SOM 标记图 ═══
print(f"\n[4/4] 绘制 SOM 标记图...")

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

# 按面积从大到小绘制
draw_markers = sorted(markers, key=lambda m: m["w"] * m["h"], reverse=True)

# 第一遍：矩形边框
for m in draw_markers:
    color = COLORS[(m["id"] - 1) % len(COLORS)]
    draw.rectangle([m["x1"], m["y1"], m["x2"], m["y2"]], outline=color, width=2)

# 第二遍：编号气泡 + 文字标签
for m in draw_markers:
    color = COLORS[(m["id"] - 1) % len(COLORS)]

    # 编号气泡
    badge_r = 16
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

    # 文字标签（类型 + 描述）
    tag = f"{m['type']}"
    if m["label"]:
        tag += f": {m['label'][:16]}"
    if font_small:
        tbbox = draw.textbbox((0, 0), tag, font=font_small)
        ttw = tbbox[2] - tbbox[0]
        tth = tbbox[3] - tbbox[1]
        tx = m["x1"] + 4
        ty = m["y2"] - tth - 4
        draw.rectangle([tx - 2, ty - 1, tx + ttw + 2, ty + tth + 2], fill=(0, 0, 0, 180))
        draw.text((tx, ty), tag, fill=(255, 255, 255, 255), font=font_small)

result_img = Image.alpha_composite(img_draw, overlay)
result_img.convert("RGB").save(JPG_PATH, "JPEG", quality=90)
jpg_size = os.path.getsize(JPG_PATH)
print(f"  ✅ SOM 标记图: {JPG_PATH} ({jpg_size:,} bytes)")
print(f"  绘制: {len(draw_markers)} 个标记")

# ═══ 汇总 ═══
print("\n" + "=" * 60)
print(f"  方案: 千问 VL 纯视觉识别 (无 AX API)")
print(f"  模型: {MODEL}")
print(f"  API 耗时: {elapsed:.1f}s")
print(f"  坐标系: {coord_system}")
print(f"  识别组件: {len(markers)} 个")
print(f"  Token: prompt={usage.get('input_tokens', usage.get('prompt_tokens', '?'))}, completion={usage.get('output_tokens', usage.get('completion_tokens', '?'))}")
print("=" * 60)
print(f"\n  原始截图: {PNG_PATH}")
print(f"  SOM 标记图: {JPG_PATH}")
print(f"  模型回复: {raw_path}")
print(f"  结构化结果: {result_path}")
print(f"\n  清理: rm -rf {WORK_DIR}")

subprocess.run(["open", JPG_PATH])
