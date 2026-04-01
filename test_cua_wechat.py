#!/usr/bin/env python3
"""
CUA 端到端测试脚本 - 微信搜索文件传输助手

测试场景：
  1. 打开微信
  2. 搜索框搜索文件传输助手
  3. 在对话框输入 123

用法：
  export DASHSCOPE_API_KEY="sk-xxx"
  python3 test_cua_wechat.py
"""

import subprocess, sys, os, json, time, base64, re, argparse
from pathlib import Path

# ═══ 配置 ═══
API_KEY = 'sk-5c919adeac74446aba0e95db11d1f233'
MODEL = "qwen3-vl-flash"
WORK_DIR = Path(f"/tmp/cua_test_{os.getpid()}")
DELAY_BETWEEN_ACTIONS = 1.5  # 操作间隔（秒）

def log(msg: str, level: str = "INFO"):
    """带时间戳的日志"""
    ts = time.strftime("%H:%M:%S")
    prefix = {"INFO": "🔹", "OK": "✅", "WARN": "⚠️", "ERROR": "❌", "ACTION": "🎯"}.get(level, "•")
    print(f"[{ts}] {prefix} {msg}")

def run_cmd(cmd: list, timeout: int = 30) -> tuple[int, str, str]:
    """运行命令并返回 (exitcode, stdout, stderr)"""
    try:
        r = subprocess.run(cmd, capture_output=True, text=True, timeout=timeout)
        return r.returncode, r.stdout, r.stderr
    except subprocess.TimeoutExpired:
        return -1, "", "Timeout"
    except Exception as e:
        return -1, "", str(e)

# ═══ 截图功能 ═══
def get_mouse_position() -> tuple[int, int] | None:
    """获取当前鼠标位置（屏幕坐标）"""
    # 使用 Python Quartz（如果已安装）或 AppleScript
    try:
        # 方法 1: 使用 pyobjc (pip install pyobjc-framework-Quartz)
        from Quartz import CGEventSourceGetSourceStateID, kCGEventSourceStateHIDSystemState
        from Quartz import CGEventSourceGetLocation
        loc = CGEventSourceGetLocation(CGEventSourceGetSourceStateID(kCGEventSourceStateHIDSystemState))
        return int(loc.x), int(loc.y)
    except ImportError:
        pass

    # 方法 2: 使用 cliclick（如果已安装）
    r = run_cmd(["cliclick", "-p"], timeout=1)
    if r[0] == 0 and r[1].strip():
        # 输出格式: "x,y"
        parts = r[1].strip().split(",")
        if len(parts) == 2:
            try:
                return int(parts[0]), int(parts[1])
            except ValueError:
                pass

    # 方法 3: 使用 AppleScript（较慢）
    script = '''
tell application "System Events"
    set mousePos to do shell script "python3 -c \\"from Quartz import CGEventSourceGetLocation, CGEventSourceGetSourceStateID, kCGEventSourceStateHIDSystemState; loc = CGEventSourceGetLocation(CGEventSourceGetSourceStateID(kCGEventSourceStateHIDSystemState)); print(str(int(loc.x)) + ',' + str(int(loc.y)))\\""
    return mousePos
end tell
'''
    r = run_cmd(["osascript", "-e", script], timeout=2)
    if r[0] == 0 and r[1].strip():
        parts = r[1].strip().split(",")
        if len(parts) == 2:
            try:
                return int(parts[0]), int(parts[1])
            except ValueError:
                pass

    return None

def screenshot() -> tuple[str, int, int, int, int, str, int, int, float, float] | None:
    """截图并返回 (base64, x, y, w, h, png_path, mouse_x, mouse_y, scale, retina_scale)"""
    WORK_DIR.mkdir(exist_ok=True)
    png_path = WORK_DIR / "screen.png"

    # 获取鼠标位置（逻辑坐标）
    mouse_pos = get_mouse_position()
    mouse_x, mouse_y = mouse_pos if mouse_pos else (0, 0)
    if mouse_pos:
        log(f"鼠标位置（逻辑）: ({mouse_x}, {mouse_y})")

    # 获取前景窗口（逻辑尺寸）
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
        r = run_cmd(["osascript", "-e", applescript], timeout=2)
        if r[0] == 0 and r[1].strip():
            parts = [int(x.strip()) for x in r[1].strip().split(",")]
            if len(parts) == 4:
                win_rect = parts
    except:
        pass

    if win_rect:
        rect_str = f"{win_rect[0]},{win_rect[1]},{win_rect[2]},{win_rect[3]}"
        run_cmd(["screencapture", "-x", "-R", rect_str, str(png_path)])
    else:
        run_cmd(["screencapture", "-x", str(png_path)])

    if not png_path.exists() or png_path.stat().st_size < 1000:
        log("截图失败", "ERROR")
        return None

    # 读取实际尺寸（物理像素）
    from PIL import Image
    img = Image.open(png_path)
    actual_w, actual_h = img.size

    # 计算 Retina 缩放因子（物理像素 / 逻辑尺寸）
    retina_scale = 1.0
    if win_rect:
        retina_scale = actual_w / win_rect[2] if win_rect[2] > 0 else 1.0
        log(f"Retina 缩放因子: {retina_scale:.2f}x")

    w, h = actual_w, actual_h

    # 缩放（用于 VLM）
    max_edge = 1920
    scale = 1.0
    if max(w, h) > max_edge:
        scale = max_edge / max(w, h)
        w, h = int(w * scale), int(h * scale)
        img = img.resize((w, h), Image.LANCZOS)

    # 转 base64
    import io
    buf = io.BytesIO()
    img.convert("RGB").save(buf, format="JPEG", quality=75)
    b64 = base64.b64encode(buf.getvalue()).decode()

    return b64, win_rect[0] if win_rect else 0, win_rect[1] if win_rect else 0, w, h, str(png_path), mouse_x, mouse_y, scale, retina_scale

# ═══ VLM 调用 ═══
def find_element(query: str, image_b64: str) -> list[dict] | None:
    """调用 VLM 查找元素"""
    import urllib.request, urllib.error

    system_prompt = "You are a UI element locator. Find matching elements and output bbox_2d in [0,1000) coordinates."
    user_prompt = f'''Find this UI element: "{query}"

Return JSON array with:
- bbox_2d: [x1,y1,x2,y2] in [0,1000) normalized coordinates
- type: element type
- label: visible text
- function: what it does

If NOT found: [{{"found":false}}]

JSON only: [{{"bbox_2d":[x1,y1,x2,y2],"type":"button","label":"Send"}}]'''

    request_body = {
        "model": MODEL,
        "input": {
            "messages": [
                {"role": "system", "content": [{"text": system_prompt}]},
                {
                    "role": "user",
                    "content": [
                        {"text": user_prompt},
                        {"image": f"data:image/jpeg;base64,{image_b64}"}
                    ]
                }
            ]
        },
        "parameters": {
            "result_format": "message",
            "max_tokens": 2048,
            "temperature": 0.1,
        }
    }

    headers = {
        "Content-Type": "application/json",
        "Authorization": f"Bearer {API_KEY}",
    }

    try:
        req_data = json.dumps(request_body).encode()
        req = urllib.request.Request(
            "https://dashscope.aliyuncs.com/api/v1/services/aigc/multimodal-generation/generation",
            data=req_data,
            headers=headers,
            method="POST"
        )
        with urllib.request.urlopen(req, timeout=60) as resp:
            data = json.loads(resp.read().decode())

        choices = data.get("output", {}).get("choices", [])
        if not choices:
            return None

        content = choices[0].get("message", {}).get("content", [])
        text = "".join(item.get("text", "") for item in content if isinstance(item, dict))

        # 解析 JSON
        m = re.search(r'\[[\s\S]*\]', text)
        if m:
            return json.loads(m.group(0))
        return None
    except Exception as e:
        log(f"VLM API 错误: {e}", "ERROR")
        return None

def map_coords(elements: list, img_w: int, img_h: int, offset_x: int, offset_y: int,
               scale: float = 1.0, retina_scale: float = 1.0) -> list[dict]:
    """映射坐标到屏幕坐标
    
    Args:
        elements: VLM 返回的元素列表
        img_w, img_h: 缩放后发送给 VLM 的图片尺寸
        offset_x, offset_y: 窗口逻辑坐标偏移
        scale: VLM 图片缩放比例 (img_w / actual_w)
        retina_scale: Retina 缩放因子 (physical_pixels / logical_points)
    
    Returns:
        包含屏幕坐标和窗口坐标的元素列表
    """
    results = []
    for elem in elements:
        bbox = elem.get("bbox_2d") or elem.get("bbox")
        if not bbox or len(bbox) < 4:
            continue
        x1, y1, x2, y2 = float(bbox[0]), float(bbox[1]), float(bbox[2]), float(bbox[3])

        # VLM [0,1000) → 缩放后图片像素
        max_coord = max(x1, y1, x2, y2)
        if max_coord <= 1000:
            x1 = x1 / 1000 * img_w
            y1 = y1 / 1000 * img_h
            x2 = x2 / 1000 * img_w
            y2 = y2 / 1000 * img_h

        # 缩放后像素 → 原始物理像素
        x1_phys = x1 / scale
        y1_phys = y1 / scale
        x2_phys = x2 / scale
        y2_phys = y2 / scale

        # 物理像素 → 窗口逻辑坐标
        x1_logical = x1_phys / retina_scale
        y1_logical = y1_phys / retina_scale
        x2_logical = x2_phys / retina_scale
        y2_logical = y2_phys / retina_scale

        # 窗口逻辑 → 屏幕逻辑坐标
        screen_x1 = int(x1_logical + offset_x)
        screen_y1 = int(y1_logical + offset_y)
        screen_x2 = int(x2_logical + offset_x)
        screen_y2 = int(y2_logical + offset_y)
        cx = (screen_x1 + screen_x2) // 2
        cy = (screen_y1 + screen_y2) // 2

        results.append({
            "x1": screen_x1, "y1": screen_y1,
            "x2": screen_x2, "y2": screen_y2,
            "cx": cx, "cy": cy,
            "type": elem.get("type", "unknown"),
            "label": elem.get("label", ""),
            # 窗口内物理像素坐标（用于绘制）
            "win_x1": int(x1_phys), "win_y1": int(y1_phys),
            "win_x2": int(x2_phys), "win_y2": int(y2_phys),
        })
    return results

# ═══ 绘制标记图 ═══
def draw_markers(png_path: str, markers: list[dict], query: str, step_num: int,
                 offset_x: int = 0, offset_y: int = 0,
                 mouse_x: int = 0, mouse_y: int = 0, retina_scale: float = 1.0) -> str:
    """在截图上绘制识别框、坐标和鼠标位置"""
    from PIL import Image, ImageDraw, ImageFont

    img = Image.open(png_path).convert("RGBA")
    draw = ImageDraw.Draw(img)

    # 加载字体
    font = None
    font_small = None
    for fp in ["/System/Library/Fonts/PingFang.ttc", "/System/Library/Fonts/Helvetica.ttc"]:
        try:
            font = ImageFont.truetype(fp, 16)
            font_small = ImageFont.truetype(fp, 12)
            break
        except:
            pass

    COLORS = [
        (220, 50, 47),   # 红
        (38, 139, 210),  # 蓝
        (133, 153, 0),   # 绿
        (181, 137, 0),   # 黄
    ]

    # 绘制鼠标位置（绿色十字 + 坐标标注）
    if mouse_x > 0 or mouse_y > 0:
        # 计算鼠标在截图中的位置
        # 屏幕逻辑坐标 → 窗口逻辑坐标 → 窗口物理像素
        mouse_win_x = int((mouse_x - offset_x) * retina_scale)
        mouse_win_y = int((mouse_y - offset_y) * retina_scale)

        # 检查是否在截图范围内
        if 0 <= mouse_win_x <= img.width and 0 <= mouse_win_y <= img.height:
            mouse_color = (0, 255, 100)  # 绿色

            # 绘制十字准星
            cross_size = 20
            draw.line([mouse_win_x - cross_size, mouse_win_y, mouse_win_x + cross_size, mouse_win_y],
                      fill=mouse_color + (255,), width=2)
            draw.line([mouse_win_x, mouse_win_y - cross_size, mouse_win_x, mouse_win_y + cross_size],
                      fill=mouse_color + (255,), width=2)

            # 绘制外圈
            draw.ellipse([mouse_win_x - 12, mouse_win_y - 12, mouse_win_x + 12, mouse_win_y + 12],
                         outline=mouse_color + (255,), width=2)

            # 绘制坐标标注
            mouse_label = f"🖱️ ({mouse_x}, {mouse_y})"
            if font_small:
                mbbox = draw.textbbox((0, 0), mouse_label, font=font_small)
                mw, mh = mbbox[2] - mbbox[0], mbbox[3] - mbbox[1]
                # 标注位置：鼠标右侧，避免遮挡
                mx = mouse_win_x + 20
                my = mouse_win_y - mh // 2
                if mx + mw > img.width:
                    mx = mouse_win_x - mw - 20
                if my < 0:
                    my = 10
                if my + mh > img.height:
                    my = img.height - mh - 10
                draw.rectangle([mx - 2, my - 1, mx + mw + 2, my + mh + 1], fill=(0, 0, 0, 200))
                draw.text((mx, my), mouse_label, fill=mouse_color + (255,), font=font_small)

    for m in markers:
        color = COLORS[(markers.index(m)) % len(COLORS)]
        x1, y1, x2, y2 = m["win_x1"], m["win_y1"], m["win_x2"], m["win_y2"]

        # 绘制矩形边框
        draw.rectangle([x1, y1, x2, y2], outline=color + (255,), width=3)

        # 绘制四个角坐标标注
        corners = [
            (x1, y1, f"({m['x1']},{m['y1']})"),
            (x2, y1, f"({m['x2']},{m['y1']})"),
            (x1, y2, f"({m['x1']},{m['y2']})"),
            (x2, y2, f"({m['x2']},{m['y2']})"),
        ]
        for cx, cy, text in corners:
            # 绘制角点圆点
            draw.ellipse([cx - 4, cy - 4, cx + 4, cy + 4], fill=color + (255,))
            # 绘制坐标文本
            if font_small:
                draw.text((cx + 8, cy - 6), text, fill=color + (255,), font=font_small)

        # 绘制中心点
        cx, cy = m["cx"] - markers[0]["x1"] + x1, m["cy"] - markers[0]["y1"] + y1
        # 重新计算窗口内中心
        win_cx = (x1 + x2) // 2
        win_cy = (y1 + y2) // 2
        draw.ellipse([win_cx - 6, win_cy - 6, win_cx + 6, win_cy + 6],
                     outline=color + (255,), width=2)
        draw.line([win_cx - 10, win_cy, win_cx + 10, win_cy], fill=color + (255,), width=2)
        draw.line([win_cx, win_cy - 10, win_cx, win_cy + 10], fill=color + (255,), width=2)

        # 绘制编号气泡
        badge_r = 18
        bx, by = x1 + badge_r, y1 + badge_r
        draw.ellipse([bx - badge_r, by - badge_r, bx + badge_r, by + badge_r],
                     fill=color + (255,), outline=(255, 255, 255, 255), width=2)
        label = str(markers.index(m) + 1)
        if font:
            bbox = draw.textbbox((0, 0), label, font=font)
            tw, th = bbox[2] - bbox[0], bbox[3] - bbox[1]
            draw.text((bx - tw // 2, by - th // 2 - 1), label, fill=(255, 255, 255, 255), font=font)

        # 绘制标签（类型 + 文本）
        tag = f"{m['type']}: {m['label'][:20]}" if m['label'] else m['type']
        if font_small:
            tbbox = draw.textbbox((0, 0), tag, font=font_small)
            tw, th = tbbox[2] - tbbox[0], tbbox[3] - tbbox[1]
            tx, ty = x1, y1 - th - 6
            if ty < 0:
                ty = y2 + 4
            draw.rectangle([tx - 2, ty - 1, tx + tw + 2, ty + th + 1], fill=(0, 0, 0, 200))
            draw.text((tx, ty), tag, fill=(255, 255, 255, 255), font=font_small)

        # 绘制屏幕坐标（底部）
        coord_text = f"屏幕: ({m['cx']}, {m['cy']})"
        if font_small:
            cbbox = draw.textbbox((0, 0), coord_text, font=font_small)
            cw, ch = cbbox[2] - cbbox[0], cbbox[3] - cbbox[1]
            cx_txt, cy_txt = x1, y2 + 4
            if ty > 0 and ty < y2:  # 如果标签在上方，坐标显示在下方
                cy_txt = y2 + ch + 8
            draw.rectangle([cx_txt - 2, cy_txt - 1, cx_txt + cw + 2, cy_txt + ch + 1], fill=(0, 0, 0, 180))
            draw.text((cx_txt, cy_txt), coord_text, fill=(200, 255, 200, 255), font=font_small)

    # 顶部添加查询信息
    header = f"Step {step_num}: {query}"
    if font:
        hbbox = draw.textbbox((0, 0), header, font=font)
        hw, hh = hbbox[2] - hbbox[0], hbbox[3] - hbbox[1]
        draw.rectangle([0, 0, img.width, hh + 8], fill=(0, 0, 0, 200))
        draw.text((10, 4), header, fill=(255, 255, 255, 255), font=font)

    # 保存
    marker_path = WORK_DIR / f"marker_step{step_num}.jpg"
    img.convert("RGB").save(marker_path, "JPEG", quality=90)
    log(f"标记图已保存: {marker_path}", "OK")

    return str(marker_path)

# ═══ 操作功能 ═══
def open_app(app_name: str) -> bool:
    """打开应用"""
    log(f"打开应用: {app_name}", "ACTION")
    r = run_cmd(["open", "-a", app_name])
    if r[0] == 0:
        log(f"已打开 {app_name}", "OK")
        return True
    log(f"打开失败: {r[2]}", "ERROR")
    return False

def mouse_click(x: int, y: int, button: str = "left", clicks: int = 1) -> bool:
    """鼠标点击"""
    log(f"点击: ({x}, {y})", "ACTION")
    # 使用 cliclick (需要 brew install cliclick)
    key = {"left": "c", "right": "rc", "middle": "mc"}[button]
    cmd = f"m:{x},{y} {key}:{x},{y}"
    if clicks == 2:
        cmd = f"m:{x},{y} dc:{x},{y}"
    r = run_cmd(["cliclick"] + cmd.split())
    if r[0] != 0:
        # 回退到 AppleScript
        script = f'''
tell application "System Events"
    click at {{{x}, {y}}}
end tell
'''
        r = run_cmd(["osascript", "-e", script])
    return r[0] == 0

def key_type(text: str) -> bool:
    """输入文本（支持中文）"""
    log(f"输入: {text}", "ACTION")
    # 使用剪贴板粘贴方式输入中文
    # 先保存原剪贴板内容
    save_script = 'set theClipboard to the clipboard as text'
    r = run_cmd(["osascript", "-e", save_script])
    
    # 将文本复制到剪贴板
    import subprocess
    process = subprocess.Popen(['pbcopy'], stdin=subprocess.PIPE)
    process.communicate(text.encode('utf-8'))
    
    time.sleep(0.1)
    
    # 粘贴 (Cmd+V)
    paste_script = '''
tell application "System Events"
    keystroke "v" using {command down}
end tell
'''
    r = run_cmd(["osascript", "-e", paste_script])
    return r[0] == 0

def key_combo(keys: str) -> bool:
    """快捷键"""
    log(f"快捷键: {keys}", "ACTION")
    parts = keys.lower().split("+")
    modifiers = []
    key = ""
    for p in parts:
        if p in ["cmd", "command"]:
            modifiers.append("command down")
        elif p in ["ctrl", "control"]:
            modifiers.append("control down")
        elif p in ["alt", "option"]:
            modifiers.append("option down")
        elif p in ["shift"]:
            modifiers.append("shift down")
        else:
            key = p

    mods_str = ", ".join(modifiers) if modifiers else ""
    script = f'''
tell application "System Events"
    keystroke "{key}" using {{{mods_str}}}
end tell
''' if mods_str else f'''
tell application "System Events"
    keystroke "{key}"
end tell
'''
    r = run_cmd(["osascript", "-e", script])
    return r[0] == 0

# ═══ 全局变量：步骤计数 ═══
_step_counter = 0

def find_and_click(query: str, desc: str = "") -> bool:
    """查找并点击元素"""
    global _step_counter
    _step_counter += 1

    if desc:
        log(f"查找: {desc} ({query})")
    else:
        log(f"查找: {query}")

    # 截图
    result = screenshot()
    if not result:
        return False
    img_b64, offset_x, offset_y, img_w, img_h, png_path, mouse_x, mouse_y, scale, retina_scale = result

    # VLM 查找
    elements = find_element(query, img_b64)
    if not elements:
        log(f"未找到: {query}", "WARN")
        return False

    # 检查 found: false
    if len(elements) == 1 and elements[0].get("found") == False:
        log(f"元素不存在: {query}", "WARN")
        return False

    # 映射坐标（VLM 输出的是缩放后图片的坐标，需要转换）
    mapped = map_coords(elements, img_w, img_h, offset_x, offset_y, scale, retina_scale)
    if not mapped:
        log(f"坐标映射失败", "ERROR")
        return False

    # 绘制标记图（包含鼠标位置）
    draw_markers(png_path, mapped, query, _step_counter, offset_x, offset_y, mouse_x, mouse_y, retina_scale)

    # 点击第一个匹配
    target = mapped[0]
    log(f"找到: {target['type']} \"{target['label']}\" @ ({target['cx']}, {target['cy']})", "OK")
    time.sleep(0.5)
    return mouse_click(target['cx'], target['cy'])

# ═══ 主流程 ═══
def main():
    print("=" * 60)
    print("  CUA 端到端测试 - 微信搜索文件传输助手")
    print("=" * 60)

    if not API_KEY:
        log("未设置 DASHSCOPE_API_KEY", "ERROR")
        sys.exit(1)

    log(f"API Key: {API_KEY[:8]}...{API_KEY[-4:]}")

    # Step 1: 打开微信
    log("\n" + "=" * 40)
    log("Step 1: 打开微信")
    if not open_app("wechat"):
        log("打开微信失败", "ERROR")
        sys.exit(1)
    time.sleep(3)  # 等待应用启动

    # Step 2: 搜索文件传输助手
    log("\n" + "=" * 40)
    log("Step 2: 搜索文件传输助手")
    # 先尝试点击搜索框
    if find_and_click("搜索框或搜索图标", "搜索入口"):
        time.sleep(DELAY_BETWEEN_ACTIONS)
        # 输入搜索内容
        if not key_type("文件传输助手"):
            log("输入搜索内容失败", "ERROR")
            sys.exit(1)
        time.sleep(DELAY_BETWEEN_ACTIONS)
        # 点击搜索结果
        if not find_and_click("文件传输助手 搜索结果或联系人", "文件传输助手"):
            log("未找到文件传输助手", "ERROR")
            sys.exit(1)
    else:
        # 回退：用快捷键 Cmd+F 搜索
        log("尝试快捷键搜索...")
        key_combo("cmd+f")
        time.sleep(1)
        key_type("文件传输助手")
        time.sleep(DELAY_BETWEEN_ACTIONS)
        key_type("\n")  # 回车确认

    time.sleep(DELAY_BETWEEN_ACTIONS)

    # Step 3: 输入消息
    log("\n" + "=" * 40)
    log("Step 3: 输入消息")
    # 点击输入框
    if find_and_click("消息输入框或文本输入区域", "输入框"):
        time.sleep(0.5)
        # 输入消息
        if not key_type("123"):
            log("输入消息失败", "ERROR")
            sys.exit(1)
        log("已输入: 123", "OK")
    else:
        log("未找到输入框", "ERROR")
        sys.exit(1)

    time.sleep(DELAY_BETWEEN_ACTIONS)

    # Step 4: 发送消息
    log("\n" + "=" * 40)
    log("Step 4: 发送消息")
    # 尝试点击发送按钮
    if find_and_click("发送按钮", "发送"):
        log("已发送消息", "OK")
    else:
        # 回退：回车发送
        log("尝试回车发送...")
        key_type("\n")
        log("已发送消息", "OK")

    log("\n" + "=" * 60)
    log("测试完成！", "OK")
    print("=" * 60)

if __name__ == "__main__":
    main()
