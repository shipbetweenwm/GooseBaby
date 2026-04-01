#!/usr/bin/env python3
"""
调试脚本 v4：
用正确的微信主窗口坐标，在左侧导航栏区域做坐标反查
"""

import sys, time

DELAY = 3
print(f"\n⏳ {DELAY} 秒后开始，请切换到微信...")
for i in range(DELAY, 0, -1):
    print(f"   {i}...", flush=True)
    time.sleep(1)
print("   开始!\n")

from AppKit import NSWorkspace
from ApplicationServices import (
    AXUIElementCreateApplication, AXUIElementCopyAttributeValue,
    AXUIElementCopyAttributeNames, AXUIElementCopyActionNames,
    AXUIElementCopyElementAtPosition,
    kAXChildrenAttribute, kAXRoleAttribute, kAXTitleAttribute,
    kAXValueAttribute, kAXPositionAttribute, kAXSizeAttribute,
    kAXDescriptionAttribute, kAXEnabledAttribute,
    kAXSubroleAttribute,
)
import Quartz, ctypes

def _get_attr(element, attr):
    try:
        result = AXUIElementCopyAttributeValue(element, attr, None)
        if isinstance(result, tuple):
            err, val = result
            return val if err == 0 else None
        return result
    except:
        return None

def _get_point(e):
    p = _get_attr(e, kAXPositionAttribute)
    if p is None:
        return None
    try:
        pt = Quartz.CGPoint()
        if Quartz.AXValueGetValue(p, Quartz.kAXValueTypeCGPoint, ctypes.byref(pt)):
            return (float(pt.x), float(pt.y))
    except:
        pass
    return None

def _get_size(e):
    s = _get_attr(e, kAXSizeAttribute)
    if s is None:
        return None
    try:
        sz = Quartz.CGSize()
        if Quartz.AXValueGetValue(s, Quartz.kAXValueTypeCGSize, ctypes.byref(sz)):
            return (float(sz.width), float(sz.height))
    except:
        pass
    return None

def _fmt_value(val):
    if val is None:
        return "None"
    try:
        pt = Quartz.CGPoint()
        if Quartz.AXValueGetValue(val, Quartz.kAXValueTypeCGPoint, ctypes.byref(pt)):
            return f"CGPoint({pt.x:.1f}, {pt.y:.1f})"
        sz = Quartz.CGSize()
        if Quartz.AXValueGetValue(val, Quartz.kAXValueTypeCGSize, ctypes.byref(sz)):
            return f"CGSize({sz.width:.1f}, {sz.height:.1f})"
        rect = Quartz.CGRect()
        if Quartz.AXValueGetValue(val, Quartz.kAXValueTypeCGRect, ctypes.byref(rect)):
            return f"CGRect({rect.origin.x:.1f}, {rect.origin.y:.1f}, {rect.size.width:.1f}, {rect.size.height:.1f})"
    except:
        pass
    s = repr(val)
    return s[:150] + "..." if len(s) > 150 else s

# ═══ 获取前台应用 ═══
ws = NSWorkspace.sharedWorkspace()
front_app = ws.frontmostApplication()
if not front_app:
    print("❌ 无前台应用")
    sys.exit(1)

app_pid = int(front_app.processIdentifier())
app_name = front_app.localizedName() or "?"
print(f"前台应用: {app_name} (PID: {app_pid})")

app_elem = AXUIElementCreateApplication(app_pid)

# ═══ 方法1: CGWindowListCopyWindowInfo 获取主窗口 ═══
print("\n" + "=" * 70)
print("步骤1: 获取微信主窗口位置")
print("=" * 70)

window_list = Quartz.CGWindowListCopyWindowInfo(
    Quartz.kCGWindowListOptionOnScreenOnly | Quartz.kCGWindowListExcludeDesktopElements,
    Quartz.kCGNullWindowID
)

main_bounds = None
for win_info in window_list:
    owner_pid = win_info.get('kCGWindowOwnerPID', 0)
    if owner_pid == app_pid:
        win_name = win_info.get('kCGWindowName', '')
        bounds = win_info.get('kCGWindowBounds', {})
        layer = win_info.get('kCGWindowLayer', -1)
        w = bounds.get('Width', 0)
        h = bounds.get('Height', 0)
        print(f"  窗口: name=\"{win_name}\", layer={layer}, "
              f"x={bounds.get('X',0)}, y={bounds.get('Y',0)}, w={w}, h={h}")
        # 选最大的窗口作为主窗口
        if main_bounds is None or w * h > main_bounds.get('Width', 0) * main_bounds.get('Height', 0):
            main_bounds = bounds

if not main_bounds:
    print("  ❌ 未找到微信窗口")
    sys.exit(1)

wx = main_bounds['X']
wy = main_bounds['Y']
ww = main_bounds['Width']
wh = main_bounds['Height']
print(f"\n  ✅ 主窗口: ({wx}, {wy}) {ww}x{wh}")

# ═══ 方法2: 坐标反查——扫描整个左侧区域 ═══
print("\n" + "=" * 70)
print("步骤2: AXUIElementCopyElementAtPosition 扫描左侧导航栏")
print("=" * 70)
print(f"  扫描区域: x=[{wx}..{wx+60}], y=[{wy+50}..{wy+wh-50}]")

# 创建系统级元素用于坐标查询
from ApplicationServices import AXUIElementCreateSystemWide
system_elem = AXUIElementCreateSystemWide()

# 扫描左侧区域
scan_results = {}  # key -> (elem, role, label, pos, size, all_attrs)

for x_offset in [15, 25, 35, 50]:
    px = wx + x_offset
    for y_offset in range(40, int(wh) - 20, 15):
        py = wy + y_offset
        try:
            # 尝试用 app 元素
            err, hit_elem = AXUIElementCopyElementAtPosition(app_elem, float(px), float(py), None)
            if err != 0 or not hit_elem:
                # fallback: 用 system-wide 元素
                err, hit_elem = AXUIElementCopyElementAtPosition(system_elem, float(px), float(py), None)
            if err == 0 and hit_elem:
                h_role = _get_attr(hit_elem, kAXRoleAttribute) or '?'
                h_subrole = _get_attr(hit_elem, kAXSubroleAttribute) or ''
                h_title = _get_attr(hit_elem, kAXTitleAttribute)
                h_desc = _get_attr(hit_elem, kAXDescriptionAttribute)
                h_value = _get_attr(hit_elem, kAXValueAttribute)
                h_pos = _get_point(hit_elem)
                h_sz = _get_size(hit_elem)

                label = ''
                for v in [h_title, h_desc, h_value]:
                    if v:
                        s = str(v).strip()
                        if s:
                            label = s
                            break

                role_str = str(h_role)
                sub_str = f"/{h_subrole}" if h_subrole else ""
                key = f"{role_str}{sub_str}:{label}:{h_pos}:{h_sz}"

                if key not in scan_results:
                    scan_results[key] = (px, py, role_str, sub_str, label, h_pos, h_sz, hit_elem)
        except:
            pass

print(f"\n  找到 {len(scan_results)} 个不同的 AX 元素:\n")
for key, (px, py, role_str, sub_str, label, h_pos, h_sz, hit_elem) in sorted(scan_results.items()):
    has_real = h_pos and h_sz and (h_sz[0] > 0 or h_sz[1] > 0)
    marker = "✅" if has_real else "❓"
    print(f"  {marker} ({px:.0f},{py:.0f}) → {role_str}{sub_str} \"{label}\" pos={h_pos} size={h_sz}")

    # 打印详细属性
    try:
        err2, attrs2 = AXUIElementCopyAttributeNames(hit_elem, None)
        if err2 == 0 and attrs2:
            print(f"      属性 ({len(attrs2)}):")
            for a2 in sorted(attrs2):
                v2 = _get_attr(hit_elem, a2)
                if a2 == kAXChildrenAttribute:
                    cnt = len(v2) if v2 else 0
                    print(f"        {a2} = [{cnt} children]")
                else:
                    print(f"        {a2} = {_fmt_value(v2)}")
    except:
        pass
    print()

# ═══ 方法3: 也扫描窗口中间和右侧区域（简略） ═══
print("=" * 70)
print("步骤3: 快速扫描窗口其他区域")
print("=" * 70)

other_results = {}
for x_pct in [0.1, 0.3, 0.5, 0.7, 0.9]:
    px = wx + ww * x_pct
    for y_pct in [0.1, 0.3, 0.5, 0.7, 0.9]:
        py = wy + wh * y_pct
        try:
            err, hit_elem = AXUIElementCopyElementAtPosition(app_elem, float(px), float(py), None)
            if err == 0 and hit_elem:
                h_role = _get_attr(hit_elem, kAXRoleAttribute) or '?'
                h_title = _get_attr(hit_elem, kAXTitleAttribute)
                h_desc = _get_attr(hit_elem, kAXDescriptionAttribute)
                label = ''
                for v in [h_title, h_desc]:
                    if v:
                        s = str(v).strip()
                        if s:
                            label = s
                            break
                h_pos = _get_point(hit_elem)
                h_sz = _get_size(hit_elem)
                key = f"{h_role}:{label}:{h_pos}"
                if key not in other_results:
                    other_results[key] = True
                    print(f"  ({px:.0f},{py:.0f}) → {h_role} \"{label}\" pos={h_pos} size={h_sz}")
        except:
            pass

print("\n✅ 调试完成")
