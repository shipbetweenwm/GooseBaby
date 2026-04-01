/// CUA (Computer Use Agent) 技能
///
/// 让鹅宝像人一样操作计算机：
/// - 视觉感知：截取屏幕截图，识别 UI 元素
/// - 鼠标模拟：点击、移动、拖拽、滚轮
/// - 键盘模拟：输入文本、快捷键组合
/// - 安全机制：仅限 Craft 模式，沙盒化执行
///
/// 跨平台支持：macOS / Windows / Linux
library;

import 'dart:convert';
import 'dart:ffi';
import 'dart:io';
import 'dart:math' show max;
import 'package:ffi/ffi.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:path/path.dart' as p;
import '../ai/llm_manager.dart';
import 'skill_base.dart';
import 'skill_file_utils.dart';
import 'cua_accessibility.dart';
import 'cua_recorder.dart';
import 'cua_som.dart';

// ─── macOS 原生 CGEvent FFI 绑定 ───
// 在进程内直接发送键盘/鼠标事件，仅需应用自身有辅助功能权限
// 不依赖 cliclick / osascript 等外部进程

// MethodChannel：原生截图（避免依赖 screencapture 外部命令的权限问题）
const _kScreenshotChannel = MethodChannel('goose_baby/screenshot');

// CGEventFlags
const _kCGEventFlagMaskCommand = 0x00100000;
const _kCGEventFlagMaskShift   = 0x00020000;
const _kCGEventFlagMaskOption  = 0x00080000;
const _kCGEventFlagMaskControl = 0x00040000;
const _kCGEventFlagMaskFn      = 0x00800000;

// CGEventSourceStateID
const _kCGEventSourceStateHIDSystemState = 1;
// kCGEventTapLocation: 使用 kCGSessionEventTap 而非 kCGHIDEventTap
// kCGHIDEventTap(0) 在 Electron 等应用中被忽略，kCGSessionEventTap(1) 兼容性更好
const _kCGSessionEventTap = 1;

// kCGMouseEventType
const _kCGEventLeftMouseDown = 1;
const _kCGEventLeftMouseUp = 2;
const _kCGEventRightMouseDown = 3;
const _kCGEventRightMouseUp = 4;
const _kCGEventMouseMoved = 5;
const _kCGEventLeftMouseDragged = 6;

// kCGScrollEventUnit
const _kCGScrollEventUnitPixel = 1;

// CGEventRef = Pointer<Void>, CGEventSourceRef = Pointer<Void>
// 使用 typedef 来简化签名

typedef CGEventSourceCreateNat = Pointer<Void> Function(Uint32);
typedef CGEventSourceCreateDart = Pointer<Void> Function(int);

typedef CGEventCreateKeyboardEventNat = Pointer<Void> Function(Pointer<Void>, Uint16, Int32);
typedef CGEventCreateKeyboardEventDart = Pointer<Void> Function(Pointer<Void>, int, int);

typedef CGEventSetFlagsNat = Void Function(Pointer<Void>, Uint64);
typedef CGEventSetFlagsDart = void Function(Pointer<Void>, int);

typedef CGEventPostNat = Void Function(Uint32, Pointer<Void>);
typedef CGEventPostDart = void Function(int, Pointer<Void>);

typedef CGEventCreateMouseEventNat = Pointer<Void> Function(Pointer<Void>, Uint32, Double, Double, Uint64);
typedef CGEventCreateMouseEventDart = Pointer<Void> Function(Pointer<Void>, int, double, double, int);

typedef CGEventCreateScrollWheelEventNat = Pointer<Void> Function(Pointer<Void>, Uint32, Int32, Int32, Int32, Int32);
typedef CGEventCreateScrollWheelEventDart = Pointer<Void> Function(Pointer<Void>, int, int, int, int, int);

// CGEventSetString — CGEventKeyboardSetUnicodeString 的现代替代 (macOS 10.11+)
// 接受 CFStringRef (const char*)，比手动构造 UTF-16 buffer 更可靠
typedef CGEventSetStringNat = Void Function(Pointer<Void>, Pointer<Void>);
typedef CGEventSetStringDart = void Function(Pointer<Void>, Pointer<Void>);

// CGEventSourceGetLocation — 获取当前鼠标位置
// CGPoint = (Double x, Double y)
typedef CGEventSourceGetLocationNat = Void Function(Int32, Pointer<Double>);
typedef CGEventSourceGetLocationDart = void Function(int, Pointer<Double>);

class _MacOSNative {
  static DynamicLibrary? _lib;
  static DynamicLibrary get lib => _lib ??= DynamicLibrary.open(
    '/System/Library/Frameworks/CoreGraphics.framework/CoreGraphics',
  );

  static DynamicLibrary get _appKitLib => DynamicLibrary.open(
    '/System/Library/Frameworks/ApplicationServices.framework/ApplicationServices',
  );

  static CGEventSourceCreateDart get _cgEventSourceCreate =>
      lib.lookupFunction<CGEventSourceCreateNat, CGEventSourceCreateDart>('CGEventSourceCreate');

  static CGEventCreateKeyboardEventDart get _cgEventCreateKeyboardEvent =>
      lib.lookupFunction<CGEventCreateKeyboardEventNat, CGEventCreateKeyboardEventDart>('CGEventCreateKeyboardEvent');

  static CGEventSetFlagsDart get _cgEventSetFlags =>
      lib.lookupFunction<CGEventSetFlagsNat, CGEventSetFlagsDart>('CGEventSetFlags');

  static CGEventPostDart get _cgEventPost =>
      lib.lookupFunction<CGEventPostNat, CGEventPostDart>('CGEventPost');

  static CGEventCreateMouseEventDart get _cgEventCreateMouseEvent =>
      lib.lookupFunction<CGEventCreateMouseEventNat, CGEventCreateMouseEventDart>('CGEventCreateMouseEvent');

  static CGEventCreateScrollWheelEventDart get _cgEventCreateScrollWheelEvent =>
      lib.lookupFunction<CGEventCreateScrollWheelEventNat, CGEventCreateScrollWheelEventDart>('CGEventCreateScrollWheelEvent');

  static CGEventSetStringDart get _cgEventSetString =>
      lib.lookupFunction<CGEventSetStringNat, CGEventSetStringDart>('CGEventSetString');

  static CGEventSourceGetLocationDart get _cgEventSourceGetLocation =>
      lib.lookupFunction<CGEventSourceGetLocationNat, CGEventSourceGetLocationDart>('CGEventSourceGetLocation');

  // AXIsProcessTrusted — 检查应用是否有辅助功能权限
  static final _axIsProcessTrusted = _appKitLib.lookupFunction<
      Bool Function(Pointer<Void>),
      bool Function(Pointer<Void>)>('AXIsProcessTrusted');

  /// 检查当前是否有辅助功能权限
  static bool isTrusted() => _axIsProcessTrusted(nullptr);

  /// 如果没有辅助功能权限则抛出异常
  static void ensureTrusted() {
    if (!isTrusted()) {
      throw StateError('缺少辅助功能权限');
    }
  }

  /// 获取当前鼠标位置（屏幕逻辑坐标）
  static (int, int)? getMousePosition() {
    try {
      final ptr = calloc<Double>(2);
      _cgEventSourceGetLocation(_kCGEventSourceStateHIDSystemState, ptr);
      final x = ptr[0].round();
      final y = ptr[1].round();
      calloc.free(ptr);
      return (x, y);
    } catch (e) {
      debugPrint('⚠️ 获取鼠标位置失败: $e');
      return null;
    }
  }

  /// 发送键盘快捷键（进程内，仅需应用自身辅助功能权限）
  static void postKeyEvent(int keyCode, int flags, {bool keyDown = true}) {
    ensureTrusted();
    final source = _cgEventSourceCreate(_kCGEventSourceStateHIDSystemState);
    final event = _cgEventCreateKeyboardEvent(source, keyCode, keyDown ? 1 : 0);
    _cgEventSetFlags(event, flags);
    _cgEventPost(_kCGSessionEventTap, event);
  }

  /// 发送键盘快捷键组合（按下并立即释放）
  static void postKeyCombo(int keyCode, int flags) {
    postKeyEvent(keyCode, flags, keyDown: true);
    postKeyEvent(keyCode, flags, keyDown: false);
  }

  /// 发送 Unicode 文本输入
  /// 逐字符发送 keyDown + keyUp，使用 CGEventSetString 确保文字内容正确传递
  static void postUnicodeText(String text) {
    ensureTrusted();
    final source = _cgEventSourceCreate(_kCGEventSourceStateHIDSystemState);
    final chars = text.runes.toList();

    for (var i = 0; i < chars.length; i++) {
      final ch = chars[i];
      final str = String.fromCharCode(ch);

      // keyDown — 用 CGEventSetString 设置 Unicode 内容
      final downEvent = _cgEventCreateKeyboardEvent(source, 0, 1);
      final cStr = str.toNativeUtf8();
      _cgEventSetString(downEvent, cStr.cast<Void>());
      _cgEventPost(_kCGSessionEventTap, downEvent);
      calloc.free(cStr);

      // keyDown/keyUp 间短暂延迟
      sleep(const Duration(milliseconds: 1));

      // keyUp
      final upEvent = _cgEventCreateKeyboardEvent(source, 0, 0);
      final cStrUp = str.toNativeUtf8();
      _cgEventSetString(upEvent, cStrUp.cast<Void>());
      _cgEventPost(_kCGSessionEventTap, upEvent);
      calloc.free(cStrUp);

      // 字符间延迟 200ms
      if (i < chars.length - 1) {
        sleep(const Duration(milliseconds: 200));
      }
    }
  }

  /// 发送鼠标点击
  static void postMouseClick(double x, double y, int button, int clicks) {
    ensureTrusted();
    final source = _cgEventSourceCreate(_kCGEventSourceStateHIDSystemState);
    final int downType, upType;
    switch (button) {
      case 1: downType = _kCGEventRightMouseDown; upType = _kCGEventRightMouseUp; break;
      default: downType = _kCGEventLeftMouseDown; upType = _kCGEventLeftMouseUp;
    }
    for (var i = 0; i < clicks; i++) {
      final down = _cgEventCreateMouseEvent(source, downType, x, y, 0);
      _cgEventPost(_kCGSessionEventTap, down);
      final up = _cgEventCreateMouseEvent(source, upType, x, y, 0);
      _cgEventPost(_kCGSessionEventTap, up);
    }
  }

  /// 发送鼠标移动
  static void postMouseMove(double x, double y) {
    ensureTrusted();
    final source = _cgEventSourceCreate(_kCGEventSourceStateHIDSystemState);
    final event = _cgEventCreateMouseEvent(source, _kCGEventMouseMoved, x, y, 0);
    _cgEventPost(_kCGSessionEventTap, event);
  }

  /// 发送鼠标拖拽
  static void postMouseDrag(double fromX, double fromY, double toX, double toY) {
    ensureTrusted();
    postMouseMove(fromX, fromY);
    const steps = 20;
    final dx = (toX - fromX) / steps;
    final dy = (toY - fromY) / steps;
    for (var i = 1; i <= steps; i++) {
      final source = _cgEventSourceCreate(_kCGEventSourceStateHIDSystemState);
      final event = _cgEventCreateMouseEvent(source, _kCGEventLeftMouseDragged, fromX + dx * i, fromY + dy * i, 0);
      _cgEventPost(_kCGSessionEventTap, event);
      sleep(const Duration(milliseconds: 5));
    }
    final source = _cgEventSourceCreate(_kCGEventSourceStateHIDSystemState);
    final up = _cgEventCreateMouseEvent(source, _kCGEventLeftMouseUp, toX, toY, 0);
    _cgEventPost(_kCGSessionEventTap, up);
  }

  /// 发送滚轮事件
  static void postScrollWheel(int clicks, {bool horizontal = false}) {
    ensureTrusted();
    final source = _cgEventSourceCreate(_kCGEventSourceStateHIDSystemState);
    final event = _cgEventCreateScrollWheelEvent(source, _kCGScrollEventUnitPixel, 1, clicks, 0, 0);
    _cgEventPost(_kCGSessionEventTap, event);
  }
}

// ─── macOS Key Code 映射（与 AppleScript key code 一致）───
const _macKeyCodeMap = <String, int>{
  'a': 0, 'b': 11, 'c': 8, 'd': 2, 'e': 14, 'f': 3, 'g': 5, 'h': 4,
  'i': 34, 'j': 38, 'k': 40, 'l': 37, 'm': 46, 'n': 45, 'o': 31,
  'p': 35, 'q': 12, 'r': 15, 's': 1, 't': 17, 'u': 32, 'v': 9,
  'w': 13, 'x': 7, 'y': 16, 'z': 6,
  '0': 29, '1': 18, '2': 19, '3': 20, '4': 21, '5': 23,
  '6': 22, '7': 26, '8': 28, '9': 25,
  'return': 36, 'enter': 36, 'tab': 48, 'space': 49, 'delete': 51,
  'escape': 53, 'esc': 53, 'f1': 122, 'f2': 120, 'f3': 99, 'f4': 118,
  'f5': 96, 'f6': 97, 'f7': 98, 'f8': 100, 'f9': 101, 'f10': 109,
  'f11': 103, 'f12': 111, 'up': 126, 'down': 125, 'left': 123, 'right': 124,
  'home': 115, 'end': 119, 'pageup': 116, 'pagedown': 121,
  'backspace': 51,
};

/// 解析修饰键字符串为 CGEventFlags
int _parseModifiers(List<String> modifiers) {
  var flags = 0;
  for (final m in modifiers) {
    switch (m) {
      case 'cmd': case 'command': flags |= _kCGEventFlagMaskCommand; break;
      case 'shift': flags |= _kCGEventFlagMaskShift; break;
      case 'alt': case 'option': flags |= _kCGEventFlagMaskOption; break;
      case 'ctrl': case 'control': flags |= _kCGEventFlagMaskControl; break;
      case 'fn': flags |= _kCGEventFlagMaskFn; break;
    }
  }
  return flags;
}

/// 从 "cmd+shift+a" 中解析修饰键列表
List<String> _parseModifierKeys(String keys) {
  final parts = keys.toLowerCase().split('+');
  final modifiers = <String>[];
  for (var i = 0; i < parts.length - 1; i++) {
    modifiers.add(parts[i].trim());
  }
  return modifiers;
}

/// 从 "cmd+shift+a" 中提取主键
String _parseMainKey(String keys) {
  return keys.toLowerCase().split('+').last.trim();
}

/// find_element 坐标缓存项
class _FindElementCoord {
  final int cx;
  final int cy;
  final String query;
  final DateTime timestamp;
  _FindElementCoord({required this.cx, required this.cy, required this.query, required this.timestamp});
}

/// 根据元素类型智能计算点击位置
/// 
/// 不同 UI 组件的最佳点击位置不同：
/// - 输入框：左侧 20%，方便光标定位
/// - 下拉框：右侧 75%，点击下拉箭头区域
/// - 复选框/单选框：左侧 15%，点击实际框体
/// - 列表项：左侧 15%，避开右侧操作按钮
/// - 其他：中心点
Map<String, dynamic> _getSmartClickPosition({
  required String elemType,
  required int x1,
  required int y1,
  required int x2,
  required int y2,
}) {
  final w = x2 - x1;
  final h = y2 - y1;
  
  // 默认中心点
  int cx = ((x1 + x2) / 2).round();
  int cy = ((y1 + y2) / 2).round();
  String? desc;
  
  // 标准化元素类型
  final type = elemType.toLowerCase();
  
  // 根据类型智能调整
  if (type.contains('input') || type.contains('text') || type.contains('search') || type.contains('field')) {
    // 输入框、搜索框：左侧 20%
    cx = (x1 + w * 0.2).round();
    cy = ((y1 + y2) / 2).round();
    desc = '[输入框: 左偏20%]';
    
  } else if (type.contains('dropdown') || type.contains('select') || type.contains('combo')) {
    // 下拉框、选择框：右侧 75%（下拉箭头区域）
    cx = (x1 + w * 0.75).round();
    cy = ((y1 + y2) / 2).round();
    desc = '[下拉框: 右偏75%]';
    
  } else if (type.contains('check') || type.contains('radio') || type.contains('toggle')) {
    // 复选框、单选框、开关：左侧 15%（点击实际框体）
    cx = (x1 + w * 0.15).round();
    cy = ((y1 + y2) / 2).round();
    desc = '[复选框: 左偏15%]';
    
  } else if (type.contains('list') || type.contains('menu') || type.contains('item')) {
    // 列表项、菜单项：左侧 15%，避开右侧操作按钮
    cx = (x1 + w * 0.15).round();
    cy = ((y1 + y2) / 2).round();
    desc = '[列表项: 左偏15%]';
    
  } else if (type.contains('slider')) {
    // 滑块：左侧 10%（起点）
    cx = (x1 + w * 0.1).round();
    cy = ((y1 + y2) / 2).round();
    desc = '[滑块: 左偏10%]';
    
  } else if (type.contains('tab')) {
    // 标签页：水平中心 + 垂直偏上 40%
    cx = ((x1 + x2) / 2).round();
    cy = (y1 + h * 0.4).round();
    desc = '[标签页: 中上40%]';
    
  } else if (type.contains('icon') || type.contains('button')) {
    // 图标按钮、按钮：中心点
    cx = ((x1 + x2) / 2).round();
    cy = ((y1 + y2) / 2).round();
    desc = '[按钮: 中心点]';
    
  } else {
    // 默认：中心点
    desc = '[默认: 中心点]';
  }
  
  return {
    'cx': cx,
    'cy': cy,
    'desc': desc,
  };
}

/// CUA 技能 — 视觉感知 + 操作模拟
class CuaSkill extends GooseSkill {
  /// 缓存 cliclick 可执行文件路径（macOS GUI 应用的 PATH 可能不包含 /opt/homebrew/bin）
  static String? _cliclickPath;

  /// LLM 管理器（运行时注入，用于视觉分析）
  LLMManager? _llmManager;

  /// 注入 LLM 管理器
  void setLLMManager(LLMManager manager) => _llmManager = manager;

  // ── find_element 坐标校验缓存 ──
  // 记录最近一次 find_element 返回的有效坐标，用于校验 mouse_click 是否合法
  static final List<_FindElementCoord> _recentFindCoords = [];
  /// find_element 坐标的有效时效（秒）：超过此时间认为坐标过期
  static const int _findCoordTtlSeconds = 60;
  /// 坐标容差（屏幕逻辑像素）：mouse_click 坐标与 find_element 坐标偏差在此范围内认为匹配
  static const int _coordTolerance = 80;

  /// 查找 cliclick 路径（仅在首次使用时检测）
  static Future<String?> _findCliclick() async {
    if (_cliclickPath != null) return _cliclickPath;

    // 常见安装路径
    final candidates = [
      '/opt/homebrew/bin/cliclick',
      '/usr/local/bin/cliclick',
    ];

    for (final path in candidates) {
      if (await File(path).exists()) {
        _cliclickPath = path;
        debugPrint('🖥️ CUA: 找到 cliclick → $path');
        return _cliclickPath;
      }
    }

    // 回退到 which 查找
    try {
      final result = await Process.run('which', ['cliclick']);
      if (result.exitCode == 0 && result.stdout.toString().trim().isNotEmpty) {
        _cliclickPath = result.stdout.toString().trim();
        debugPrint('🖥️ CUA: 找到 cliclick → $_cliclickPath');
        return _cliclickPath;
      }
    } catch (_) {}

    debugPrint('⚠️ CUA: 未找到 cliclick，请运行 brew install cliclick');
    return null;
  }

  /// 执行 cliclick 命令（直接调用二进制，确保继承辅助功能权限）
  ///
  /// [cmd] 如 "kp:a"（单命令）或 "kd:cmd kp:c ku:cmd"（多命令拼接）
  /// 直接通过 Process.run 调用 cliclick 而非 bash -c，
  /// 因为 macOS 辅助功能权限基于进程链，经过 bash 中间层会导致权限丢失。
  static Future<ProcessResult> _runCliclickBash(String cmd) async {
    final cliclick = await _findCliclick();
    if (cliclick == null) {
      return ProcessResult(-1, -1, '', 'cliclick 未安装。请运行: brew install cliclick');
    }
    // cliclick 支持空格分隔的多个子命令，直接作为参数传入
    return Process.run(cliclick, cmd.split(' '));
  }

  CuaSkill();

  @override
  String get id => 'cua';

  @override
  String get name => 'CUA 桌面控制';

  @override
  String get description =>
      'Computer Use Agent — 像人一样操作计算机。\n\n'
      '【核心工作流】\n'
      '1. cua_observe: 观察当前屏幕（截图 + 状态分析），返回当前应用、状态描述、关键元素\n'
      '2. find_element: 根据描述定位 UI 元素，返回屏幕坐标\n'
      '3. mouse_click/key_type: 执行操作\n'
      '4. cua_step: 一键循环（自动完成观察→决策→执行）\n\n'
      '【基础操作】\n'
      '• screenshot: 截取屏幕\n'
      '• mouse_click/move/scroll/drag: 鼠标操作\n'
      '• key_type/key_combo: 键盘操作\n'
      '• open_app: 打开应用\n\n'
      '【任务管理】\n'
      '• cua_plan: 规划任务步骤\n'
      '• get_history: 查看操作历史\n\n'
      '【坐标系统】屏幕逻辑坐标，左上角(0,0)';

  @override
  String get icon => '🖥️';

  @override
  String get category => '内置工具';

  @override
  String get bestPractice =>
      '【推荐工作流】\n'
      '1. 先用 cua_observe 观察当前屏幕状态\n'
      '2. 用 find_element 定位目标元素\n'
      '3. 执行 mouse_click 或 key_type 操作\n'
      '4. 重复以上步骤直到任务完成\n\n'
      '【坐标注意】\n'
      '• 所有坐标使用屏幕逻辑坐标\n'
      '• find_element 返回的坐标可直接用于 mouse_click\n\n'
      '【操作建议】\n'
      '• 输入文本前先点击输入框获得焦点\n'
      '• 输入完成后可用 key_combo "enter" 提交/发送/确认\n'
      '• 打开应用推荐用 Spotlight（cmd+space → 输入应用名 → 回车），比 open_app 更可靠\n'
      '• key_combo 支持单独按键: "enter", "tab", "escape", "backspace"\n'
      '• key_combo 支持组合键: "cmd+c", "ctrl+shift+i", "alt+tab", "cmd+shift+enter"\n';

  @override
  List<SkillParam> get params => [
    const SkillParam(
      name: 'action',
      description: '操作类型:\n'
          '【核心工作流】\n'
          '- cua_observe: 观察当前屏幕（截图 + 状态分析）\n'
          '- cua_step: 一键循环（观察→决策→执行）\n'
          '- find_element: 查找 UI 元素位置\n'
          '【基础操作】\n'
          '- screenshot: 截取屏幕\n'
          '- mouse_click: 鼠标点击\n'
          '- mouse_move: 移动鼠标\n'
          '- mouse_scroll: 滚动\n'
          '- mouse_drag: 拖拽\n'
          '- key_type: 输入文本\n'
          '- key_combo: 快捷键\n'
          '- open_app: 打开应用\n'
          '- wait: 等待页面/应用加载（等待指定秒数后重新截图）\n'
          '【任务管理】\n'
          '- cua_plan: 规划任务步骤\n'
          '- get_history: 查看操作历史',
      type: 'enum',
      required: true,
      enumValues: [
        'cua_observe', 'cua_step', 'find_element',
        'screenshot', 'mouse_click', 'mouse_move', 'mouse_scroll', 'mouse_drag',
        'key_type', 'key_combo', 'open_app', 'wait',
        'cua_plan', 'get_history',
      ],
    ),
    const SkillParam(
      name: 'x',
      description: 'X 坐标（屏幕逻辑坐标，和 find_element 返回值一致）。mouse_click/mouse_move/mouse_drag 时必填。',
      type: 'int',
      required: false,
    ),
    const SkillParam(
      name: 'y',
      description: 'Y 坐标，0~1000（0=最上，1000=最下）。mouse_click/mouse_move/mouse_drag 时必填。',
      type: 'int',
      required: false,
    ),
    const SkillParam(
      name: 'button',
      description: '鼠标按键: left(默认), right, middle。仅 mouse_click 时使用。',
      type: 'enum',
      required: false,
      enumValues: ['left', 'right', 'middle'],
    ),
    const SkillParam(
      name: 'clicks',
      description: '点击次数: 1(默认单击), 2(双击)。',
      type: 'int',
      required: false,
      defaultValue: 1,
    ),
    const SkillParam(
      name: 'target_x',
      description: '拖拽目标 X 坐标，0~1000。仅 mouse_drag 时使用。',
      type: 'int',
      required: false,
    ),
    const SkillParam(
      name: 'target_y',
      description: '拖拽目标 Y 坐标，0~1000。仅 mouse_drag 时使用。',
      type: 'int',
      required: false,
    ),
    const SkillParam(
      name: 'scroll_x',
      description: '水平滚动量（正值向右，负值向左）。仅 mouse_scroll 时使用。',
      type: 'int',
      required: false,
      defaultValue: 0,
    ),
    const SkillParam(
      name: 'scroll_y',
      description: '垂直滚动量（正值向下，负值向上）。仅 mouse_scroll 时使用。',
      type: 'int',
      required: false,
    ),
    const SkillParam(
      name: 'text',
      description: '要输入的文本内容。仅 key_type 时必填。',
      type: 'string',
      required: false,
    ),
    const SkillParam(
      name: 'keys',
      description: '快捷键组合，用 + 连接。仅 key_combo 时必填。\n'
          '【常用快捷键】\n'
          '• 输入框操作: "enter"(提交/发送/确认/换行), "tab"(切换焦点/下一个字段), "escape"(取消/关闭)\n'
          '• 文本编辑: "cmd+a"(全选), "cmd+c"(复制), "cmd+v"(粘贴), "cmd+x"(剪切), "cmd+z"(撤销), "cmd+shift+z"(重做)\n'
          '• 应用切换: "cmd+tab"(切换应用), "cmd+space"(Spotlight搜索), "alt+tab"(Windows切换窗口)\n'
          '• 窗口管理: "cmd+w"(关闭标签/窗口), "cmd+q"(退出应用), "cmd+n"(新建窗口), "cmd+t"(新建标签)\n'
          '• 导航: "cmd+l"(聚焦地址栏), "cmd+f"(查找), "up"/"down"/"left"/"right"(方向键)\n'
          '• 单独按键也支持: "enter", "tab", "escape", "space", "backspace", "delete", "up", "down", "left", "right", "f1"~"f12"\n'
          '• 示例: "cmd+c", "ctrl+shift+i", "alt+tab", "enter", "cmd+shift+enter"',
      type: 'string',
      required: false,
    ),
    const SkillParam(
      name: 'app_name',
      description: '要打开的应用名称。仅 open_app 时必填。'
          'macOS: 使用应用名或 .app 路径（如 "微信", "Safari", "/Applications/WeChat.app"）\n'
          'Windows: 使用可执行文件名或完整路径（如 "wechat.exe", "C:\\Program Files\\WeChat\\WeChat.exe"）\n'
          'Linux: 使用包名或可执行文件名（如 "wechat", "telegram-desktop"）',
      type: 'string',
      required: false,
    ),
    const SkillParam(
      name: 'display',
      description: '要截取的显示器编号（多显示器时使用，默认为 1 即主显示器）。仅 screenshot 时使用。',
      type: 'int',
      required: false,
      defaultValue: 1,
    ),
    const SkillParam(
      name: 'query',
      description: '要查找的 UI 元素描述（仅 find_element 使用）。示例: "发送按钮", "搜索输入框"。',
      type: 'string',
      required: false,
    ),
    const SkillParam(
      name: 'duration',
      description: '等待秒数（仅 wait 使用）。默认 2 秒，最大 10 秒。'
          '等待期间会监测屏幕变化，页面稳定后立即截图返回。',
      type: 'int',
      required: false,
      defaultValue: 2,
    ),
    const SkillParam(
      name: 'task_goal',
      description: '任务目标描述（仅 cua_observe/cua_step 使用）。用于提供上下文，帮助 VLM 更好地理解当前状态。'
          '示例: "在微信中发送消息给文件传输助手"',
      type: 'string',
      required: false,
    ),
    const SkillParam(
      name: 'auto_execute',
      description: '是否自动执行建议的操作（仅 cua_step 使用）。默认 false，只返回建议。',
      type: 'bool',
      required: false,
      defaultValue: false,
    ),
    const SkillParam(
      name: 'subtasks',
      description: '子任务列表（仅 cua_plan 使用）。JSON 数组格式，每项包含 description 字段。'
          '示例: [{"description": "打开微信应用"}, {"description": "搜索联系人"}, {"description": "发送消息"}]',
      type: 'string',
      required: false,
    ),
    const SkillParam(
      name: 'subtask_id',
      description: '子任务 ID（仅 set_subtask_status 使用）。从 cua_plan 返回结果中获取。',
      type: 'string',
      required: false,
    ),
    const SkillParam(
      name: 'subtask_status',
      description: '子任务目标状态（仅 set_subtask_status 使用）: running(开始执行), completed(已完成), failed(失败), skipped(跳过)。',
      type: 'enum',
      required: false,
      enumValues: ['running', 'completed', 'failed', 'skipped'],
    ),
    const SkillParam(
      name: 'query',
      description: '要查找的 UI 元素描述（仅 find_element 使用）。中英文均可，如 "搜索框"、"登录按钮"、"settings menu"。',
      type: 'string',
      required: false,
    ),
    const SkillParam(
      name: 'purpose',
      description: '操作目的说明。例如：点击搜索框、输入用户名、打开设置页面等。用于生成清晰的意图描述。',
      type: 'string',
      required: false,
    ),
    const SkillParam(
      name: 'expected_outcome',
      description: '期望的操作结果（可选）。用于智能分析操作是否成功。'
          '示例: "搜索框获得焦点并显示光标"、"微信应用窗口出现在前台"。',
      type: 'string',
      required: false,
    ),
    const SkillParam(
      name: 'task_context',
      description: '当前任务的上下文描述（可选）。用于智能分析下一步操作建议。'
          '示例: "在微信中搜索文件传输助手并发送消息"、"打开设置并修改主题为深色模式"。',
      type: 'string',
      required: false,
    ),
  ];

  @override
  List<SkillExample> get examples => const [
    // ═══════════════════════════════════════════
    // 核心工作流程
    // ═══════════════════════════════════════════
    SkillExample(
      scenario: '【核心】观察当前屏幕状态（截图+分析）',
      argsJson: '{"action": "cua_observe", "task_goal": "在微信中发送消息给文件传输助手"}',
    ),
    SkillExample(
      scenario: '【核心】一键执行完整循环（观察+决策+执行）',
      argsJson: '{"action": "cua_step", "task_goal": "打开微信并发消息", "auto_execute": true}',
    ),
    SkillExample(
      scenario: '【核心】查找 UI 元素位置',
      argsJson: '{"action": "find_element", "query": "发送按钮"}',
    ),
    // ═══════════════════════════════════════════
    // 基础操作
    // ═══════════════════════════════════════════
    SkillExample(
      scenario: '截取屏幕',
      argsJson: '{"action": "screenshot"}',
    ),
    SkillExample(
      scenario: '点击屏幕指定位置',
      argsJson: '{"action": "mouse_click", "x": 500, "y": 300}',
    ),
    SkillExample(
      scenario: '双击打开文件',
      argsJson: '{"action": "mouse_click", "x": 200, "y": 150, "clicks": 2}',
    ),
    SkillExample(
      scenario: '输入文本',
      argsJson: '{"action": "key_type", "text": "Hello World"}',
    ),
    SkillExample(
      scenario: '快捷键复制',
      argsJson: '{"action": "key_combo", "keys": "cmd+c"}',
    ),
    SkillExample(
      scenario: '输入框按回车提交/发送',
      argsJson: '{"action": "key_combo", "keys": "enter"}',
    ),
    SkillExample(
      scenario: '全选文本',
      argsJson: '{"action": "key_combo", "keys": "cmd+a"}',
    ),
    SkillExample(
      scenario: '按 Tab 切换到下一个输入框',
      argsJson: '{"action": "key_combo", "keys": "tab"}',
    ),
    SkillExample(
      scenario: '按 Escape 关闭弹窗/取消',
      argsJson: '{"action": "key_combo", "keys": "escape"}',
    ),
    SkillExample(
      scenario: '打开应用',
      argsJson: '{"action": "open_app", "app_name": "微信"}',
    ),
    // ═══════════════════════════════════════════
    // 任务管理
    // ═══════════════════════════════════════════
    SkillExample(
      scenario: '规划任务步骤',
      argsJson: '{"action": "cua_plan", "subtasks": "[{\\"description\\": \\"打开微信\\"}, {\\"description\\": \\"搜索联系人\\"}]"}',
    ),
    SkillExample(
      scenario: '查看操作历史',
      argsJson: '{"action": "get_history"}',
    ),
  ];

  @override
  Future<SkillResult> execute(Map<String, dynamic> args, {void Function(String line)? onOutput}) async {
    final action = args['action'] as String? ?? '';
    final startTime = DateTime.now();

    try {
      SkillResult result;
      switch (action) {
        case 'cua_plan':
          return await _cuaPlan(args);
        case 'set_subtask_status':
          return await _setSubTaskStatus(args);
        case 'cua_observe':
          return await _cuaObserve(args);
        case 'cua_step':
          return await _cuaStep(args);
        case 'screenshot':
          result = await _takeScreenshot(args);
        case 'find_element':
          return await _findElement(args);
        case 'mouse_click':
          result = await _mouseClick(args);
        case 'mouse_move':
          result = await _mouseMove(args);
        case 'mouse_scroll':
          result = await _mouseScroll(args);
        case 'mouse_drag':
          result = await _mouseDrag(args);
        case 'key_type':
          result = await _keyType(args);
        case 'key_combo':
          result = await _keyCombo(args);
        case 'open_app':
          result = await _openApp(args);
        case 'wait':
          result = await _waitAction(args);
        case 'get_history':
          return await _getHistory();
        case 'resume_task':
          return await _resumeTask(args);
        case 'export_task':
          return await _exportTask(args);
        default:
          return SkillResult.fail('未知的 CUA 操作类型: $action。'
              '支持: cua_plan, set_subtask_status, screenshot, mouse_click, '
              'mouse_move, mouse_scroll, mouse_drag, key_type, key_combo, open_app, wait, '
              'get_history, resume_task, export_task');
      }

      // 记录操作到当前任务
      _recordOperation(action, args, result, startTime);

      return result;
    } on CuaException catch (e) {
      debugPrint('🖥️ CUA 错误: ${e.action} - ${e.message}');
      // 记录失败操作
      _recordOperation(action, args, SkillResult.fail(e.message), startTime, error: e.message);
      return SkillResult.fail('CUA 操作失败 (${e.action}): ${e.message}');
    } catch (e, st) {
      debugPrint('🖥️ CUA 异常: $e\n$st');
      _recordOperation(action, args, SkillResult.fail(e.toString()), startTime, error: e.toString());
      return SkillResult.fail('CUA 操作异常: $e');
    }
  }

  // ─── 自适应等待时间（优化4） ───
  /// 上一次截图的 base64（用于变化检测）
  static String? _lastScreenshotBase64;

  /// 根据操作类型返回基础等待时间（变化检测前的最小等待）
  static Duration _adaptiveWaitForAction(String action) {
    switch (action) {
      case 'mouse_click':
        return const Duration(milliseconds: 300);
      case 'key_type':
        return const Duration(milliseconds: 100);
      case 'key_combo':
        return const Duration(milliseconds: 200);
      case 'mouse_scroll':
        return const Duration(milliseconds: 150);
      case 'mouse_drag':
        return const Duration(milliseconds: 200);
      case 'open_app':
        return const Duration(milliseconds: 1500);
      default:
        return const Duration(milliseconds: 300);
    }
  }

  /// 需要变化检测的操作类型（高延迟操作如点击、滚动、快捷键）
  static bool _needsChangeDetection(String action) {
    return const {'mouse_click', 'key_combo', 'open_app', 'mouse_drag'}.contains(action);
  }

  /// 计算两张截图的相似度（简化版：比较 base64 长度差异 + 前 N 字节）
  /// 返回 0~1 的相似度，1 表示完全相同
  static double _computeScreenshotSimilarity(String base64A, String base64B) {
    if (base64A.length != base64B.length) {
      // 长度差异 >5% 认为不同
      final lengthDiff = (base64A.length - base64B.length).abs() / base64A.length;
      if (lengthDiff > 0.05) return 0.0;
    }

    // 比较头部和尾部数据块（JPEG header + 尾部区域）
    // 完整比较太慢，抽样比较即可
    const sampleCount = 200;
    final step = (base64A.length / sampleCount).ceil();
    var matchCount = 0;

    for (var offset = 0; offset < base64A.length && offset < base64B.length; offset += step) {
      if (base64A[offset] == base64B[offset]) matchCount++;
    }

    return matchCount / sampleCount;
  }

  /// 等待 UI 响应后截图确认（所有操作统一调用）
  /// 双阶段变化检测：① 等屏幕开始变化 → ② 等屏幕稳定（不再变化）再截图
  /// 解决：应用/页面加载慢时截图过早的问题
  Future<Map<String, dynamic>?> _waitForChangeAndScreenshot(
    String action, {
    String? expectedOutcome,
    String? taskContext,
  }) async {
    final baseWait = _adaptiveWaitForAction(action);
    await Future.delayed(baseWait);

    // 对高延迟操作，进行双阶段变化检测
    if (_needsChangeDetection(action) && _lastScreenshotBase64 != null) {
      // ── 阶段1：等待屏幕开始变化 ──
      const maxWaitForChange = 8; // 最多等 8 次 × 250ms = 2秒
      const waitInterval = Duration(milliseconds: 250);
      String? changedShot;

      for (var attempt = 0; attempt < maxWaitForChange; attempt++) {
        final quickShot = await _quickScreenshot();
        if (quickShot == null) break;

        final similarity = _computeScreenshotSimilarity(_lastScreenshotBase64!, quickShot);
        debugPrint('🔍 变化检测(等变化): attempt=$attempt similarity=${similarity.toStringAsFixed(2)}');

        if (similarity < 0.95) {
          changedShot = quickShot;
          debugPrint('🔍 检测到屏幕变化，进入稳定等待...');
          break;
        }

        if (attempt < maxWaitForChange - 1) {
          await Future.delayed(waitInterval);
        }
      }

      // ── 阶段2：等待屏幕稳定（不再变化） ──
      if (changedShot != null) {
        const maxWaitForStable = 10; // 最多等 10 次 × 300ms = 3秒
        const stableInterval = Duration(milliseconds: 300);
        var previousShot = changedShot;

        for (var attempt = 0; attempt < maxWaitForStable; attempt++) {
          await Future.delayed(stableInterval);
          final quickShot = await _quickScreenshot();
          if (quickShot == null) break;

          final similarity = _computeScreenshotSimilarity(previousShot, quickShot);

          if (similarity > 0.97) {
            // 连续两帧相似度很高，认为屏幕已稳定
            debugPrint('✅ 屏幕已稳定');
            break;
          }

          previousShot = quickShot;
        }
      }
    }

    final result = await _takeScreenshotForConfirm();
    if (result != null) {
      _lastScreenshotBase64 = result['base64'] as String?;
      
      // 智能分析截图（如果有期望结果或任务上下文）
      if (expectedOutcome != null || taskContext != null) {
        final analysis = await _analyzeScreenshotWithVlm(
          result['base64'] as String,
          action: action,
          expectedOutcome: expectedOutcome,
          taskContext: taskContext,
        );
        if (analysis != null) {
          result['analysis'] = analysis;
        }
      }
    }
    return result;
  }

  /// 使用 VLM 智能分析截图
  /// 判断操作是否成功，并给出下一步建议
  Future<Map<String, dynamic>?> _analyzeScreenshotWithVlm(
    String imageBase64, {
    required String action,
    String? expectedOutcome,
    String? taskContext,
  }) async {
    // 检查是否注入了 LLMManager
    if (_llmManager == null) {
      debugPrint('⚠️ CUA: LLMManager 未注入，跳过智能分析');
      return null;
    }

    // 检查是否配置了视觉模型
    final visionProvider = _llmManager!.currentConfig.visionProvider;
    final visionModel = _llmManager!.currentConfig.visionModel;
    if (visionProvider == null || visionProvider.isEmpty || 
        visionModel == null || visionModel.isEmpty) {
      debugPrint('⚠️ CUA: 未配置视觉模型，跳过智能分析');
      return null;
    }

    debugPrint('🤖 VLM 智能分析截图 ($visionProvider / $visionModel)...');

    final prompt = '''You are a UI automation analyst. Analyze the screenshot to:
1. Determine if the last operation was successful
2. Describe the current screen state
3. Suggest the next action to accomplish the user's goal

Be concise and practical. Focus on actionable insights.

${taskContext != null ? '任务目标: $taskContext' : ''}
刚执行的操作: $action
${expectedOutcome != null ? '期望结果: $expectedOutcome' : ''}

请分析当前截图，返回 JSON 格式:
{
  "success": true/false,
  "successReason": "为什么判断成功/失败",
  "screenDescription": "当前屏幕状态描述（1-2句话）",
  "keyElements": ["可见的关键UI元素列表"],
  "nextAction": {
    "action": "建议的下一步操作类型 (mouse_click/key_type/key_combo/find_element等)",
    "reason": "为什么建议这个操作",
    "params": {操作参数，如 x, y, text 等}
  },
  "blockers": ["阻碍任务完成的问题，如弹窗、错误提示等"],
  "confidence": 0.0-1.0
}

如果操作成功，直接给出下一步建议。
如果操作失败，说明失败原因并给出重试或替代方案。
只返回 JSON，不要其他文字。''';

    try {
      final response = await _llmManager!.analyzeScreenshot(
        base64Image: imageBase64,
        mimeType: 'image/jpeg',
        prompt: prompt,
      );

      if (response == null || response.isEmpty) {
        debugPrint('⚠️ VLM 分析返回空结果');
        return null;
      }

      // 解析 JSON
      final jsonMatch = RegExp(r'\{[\s\S]*\}').firstMatch(response);
      if (jsonMatch != null) {
        final analysis = jsonDecode(jsonMatch.group(0)!) as Map<String, dynamic>;
        debugPrint('🤖 分析结果: success=${analysis['success']}, nextAction=${analysis['nextAction']?['action']}');
        return analysis;
      }
      
      debugPrint('⚠️ VLM 分析结果无法解析为 JSON: ${response.substring(0, response.length.clamp(0, 200))}');
      return null;
    } catch (e) {
      debugPrint('⚠️ VLM 分析失败: $e');
      return null;
    }
  }

  // ═══════════════════════════════════════════
  // cua_observe: 观察 - 截图 + 状态分析
  // ═══════════════════════════════════════════

  /// 观察：截图并分析当前屏幕状态
  /// 
  /// 输入：
  /// - task_goal: 任务目标（可选，用于提供上下文）
  /// 
  /// 输出：
  /// - screenshot: 截图信息
  /// - state: 当前状态描述
  /// - elements: 关键 UI 元素列表
  /// - suggestion: 下一步建议
  Future<SkillResult> _cuaObserve(Map<String, dynamic> args) async {
    final taskGoal = args['task_goal'] as String?;
    debugPrint('👁️ CUA observe: taskGoal=$taskGoal');

    // Step 1: 截图
    final screenshotResult = await _takeScreenshot({});
    if (!screenshotResult.success) {
      return screenshotResult;
    }

    final screenshotData = screenshotResult.data!;
    final base64 = screenshotData['base64'] as String;
    final logicalW = screenshotData['width'] as int;
    final logicalH = screenshotData['height'] as int;

    // Step 2: 分析截图（需要 LLMManager）
    if (_llmManager == null) {
      return SkillResult.ok(
        '✅ 截图成功（未配置视觉模型，跳过分析）\n'
        '   分辨率: ${logicalW}x$logicalH',
        data: {
          ...screenshotData,
          'state': '未分析',
          'elements': [],
          'suggestion': null,
        },
      );
    }

    final visionProvider = _llmManager!.currentConfig.visionProvider;
    final visionModel = _llmManager!.currentConfig.visionModel;
    if (visionProvider == null || visionProvider.isEmpty ||
        visionModel == null || visionModel.isEmpty) {
      return SkillResult.ok(
        '✅ 截图成功（未配置视觉模型，跳过分析）\n'
        '   分辨率: ${logicalW}x$logicalH',
        data: {
          ...screenshotData,
          'state': '未分析',
          'elements': [],
          'suggestion': null,
        },
      );
    }

    debugPrint('🤖 VLM 分析屏幕状态 ($visionProvider / $visionModel)...');

    final prompt = '''你是一个 macOS 桌面操作 Agent 的视觉分析模块。分析当前截图，返回结构化状态信息。

## 观察重点（优先级最高！）
1. **识别最上层应用**：首先确认当前前台应用是什么（appName）
2. **验证应用是否正确**：
   - 如果用户任务需要操作特定应用（如"打开微信..."），必须确认当前前台应用是否是目标应用
   - ⚠️ 如果当前应用不是目标应用，建议先切换到目标应用（使用 Spotlight 或 open_app）
   - ⛔ 绝对不要在错误的应用窗口中进行操作！
3. **示例**：
   - 任务"打开微信，发送消息" → 如果当前是 Finder/Chrome，必须先建议切换到微信
   - 任务"打开网易云音乐..." → 如果当前是微信，必须先建议切换到网易云音乐

${taskGoal != null ? '## 用户任务目标\n$taskGoal\n' : ''}
## 任务进度追踪（重要！）
分析当前屏幕状态，判断任务进度：
- **currentStep**：当前正在执行的步骤（如"正在搜索联系人"）
- **completedSteps**：已完成的步骤列表（如["打开微信", "进入搜索"]）
- **remainingSteps**：剩余需要完成的步骤（如["输入消息", "发送消息"]）
- **completionPercentage**：任务完成百分比（0-100）

**示例判断：**
- 任务"打开微信，搜索安琪，发送消息'今天天气真好'"
- 当前在微信聊天界面，输入框为空 → currentStep="准备输入消息"，completionPercentage=60
- 当前在微信聊天界面，右侧绿色气泡显示"今天天气真好" → currentStep="已完成"，completionPercentage=100，screenStatus="Done"

## 坐标系
所有坐标归一化到 0~1000。左上角 (0,0)，右下角 (1000,1000)。

## 输出要求
返回 JSON 格式：
{
  "appName": "当前前台应用名称",
  "windowTitle": "窗口标题",
  "state": "当前状态描述（1-2句话，如：微信聊天界面，正在查看文件传输助手的对话）",
  "taskProgress": {
    "currentStep": "当前步骤描述（如：正在搜索联系人）",
    "completedSteps": ["已完成的步骤1", "已完成的步骤2"],
    "remainingSteps": ["剩余步骤1", "剩余步骤2"],
    "completionPercentage": 60
  },
  "screenStatus": "Ready / Loading / Error / LoginRequired / Done",
  "keyElements": [
    {"type": "button/input/link/text/icon", "label": "元素文本", "description": "功能描述", "approximate_position": "top-left/center/bottom-right 等大致位置"}
  ],
  "canProceed": true/false,
  "blockers": ["阻碍任务的问题，如弹窗、登录要求（二维码/登陆框等）、错误提示等"],
  "suggestion": {
    "action": "click/type/scroll/wait/key_combo/open_app/done",
    "target": "目标元素的文字描述（用于 find_element 查找）",
    "detail": "具体操作说明（如要输入什么文字、按什么快捷键）",
    "reason": "为什么建议这个操作"
  }
}

## screenStatus 判断标准（最重要！）
- **Ready**: 页面/应用已完全加载，可以进行操作（但任务可能未完成）
- **Loading**: 有加载指示器（spinner、进度条）、启动画面、白屏、骨架屏、Dock 图标弹跳中
  → suggestion.action 应为 "wait"，等待 2~5 秒
- **Error**: 页面显示错误提示、崩溃信息、网络错误
- **LoginRequired**: 需要登录才能继续
- **Done**: ⚠️ **这是任务完成的唯一判定标准！**
  - 当且仅当**完整任务目标已达成**时，screenStatus 必须设为 'Done'
  - ⛔ 不要把子任务完成当成整个任务完成（如只打开了微信就判断 Done）
  - ⛔ 如果任务还有后续步骤，screenStatus 必须是 'Ready'，不能是 'Done'
  
  ### 发送消息任务的完成判断（常见场景）：
  必须同时满足以下条件才能判断为 Done：
  1. **在正确的聊天窗口**：窗口标题/聊天对象名称匹配任务目标（如"安琪"、"安琪和减肥"）
  2. **消息内容已发送**：
     - 在聊天记录中看到任务要求发送的消息内容（如"今天天气真好"）
     - ⚠️ 必须是**用户发送的消息**（右侧绿色气泡），不是对方的消息（左侧白色气泡）
     - 消息有"已送达"/"已读"标记，或消息在对话记录中出现
  3. **示例判断**：
     - 任务："搜索安琪，发送'今天天气真好'" → 看到"今天天气真好"出现在右侧绿色气泡中 → Done ✅
     - 任务同上，但看到"今天天气真好"在左侧白色气泡 → 是对方发送的，用户尚未发送 → Ready ❌

## suggestion.action 判断标准
- **done**: 当前步骤已完成，建议结束（⚠️ 这只是建议，不代表整个任务完成！）
- **click**: 需要点击按钮/元素来完成任务
- **type**: 需要输入文字
- **key_combo**: 需要按快捷键（如 enter 发送消息）
- **wait**: 页面加载中，需要等待

## 最佳实践（优先级）
1. **打开应用**：优先建议用 Spotlight，不要建议点击 Dock 图标
   - 例如：打开微信 → key_combo("cmd+space") → key_type("微信") → key_combo("enter")
   - 原因：Spotlight 不需要定位图标坐标，更可靠
2. **输入框提交**：输入框输入文字后，优先建议 `key_combo("enter")` 发送，而不是点击发送按钮
   - 例如：微信/QQ 聊天 → key_type("消息") → key_combo("enter")
   - 原因：Enter 键更可靠，不需要定位按钮坐标

⚠️ 关键区分：
- screenStatus='Done'：整个任务完成（全局视角）→ 触发退出循环
- suggestion.action='done'：当前步骤完成（子任务视角）→ 只是建议，可能还有后续步骤

只返回 JSON，不要其他内容。''';

    try {
      final response = await _llmManager!.analyzeScreenshot(
        base64Image: base64,
        mimeType: 'image/jpeg',
        prompt: prompt,
      );

      if (response == null || response.isEmpty) {
        return SkillResult.ok(
          '✅ 截图成功（VLM 分析返回空）\n'
          '   分辨率: ${logicalW}x$logicalH',
          data: {
            ...screenshotData,
            'state': '分析失败',
            'elements': [],
            'suggestion': null,
          },
        );
      }

      // 解析 JSON
      final jsonMatch = RegExp(r'\{[\s\S]*\}').firstMatch(response);
      if (jsonMatch == null) {
        return SkillResult.ok(
          '✅ 截图成功（VLM 分析格式错误）\n'
          '   分辨率: ${logicalW}x$logicalH',
          data: {
            ...screenshotData,
            'state': '分析格式错误',
            'elements': [],
            'suggestion': null,
            'rawResponse': response,
          },
        );
      }

      final analysis = jsonDecode(jsonMatch.group(0)!) as Map<String, dynamic>;
      final appName = analysis['appName'] as String? ?? '';
      final state = analysis['state'] as String? ?? '';
      final screenStatus = analysis['screenStatus'] as String? ?? 'Ready';
      final keyElements = analysis['keyElements'] as List? ?? [];
      final canProceed = analysis['canProceed'] as bool? ?? true;
      final blockers = analysis['blockers'] as List? ?? [];
      final suggestion = analysis['suggestion'] as Map<String, dynamic>?;

      debugPrint('🤖 观察结果: app=$appName, state=$state, screenStatus=$screenStatus, canProceed=$canProceed');

      // 构建输出
      final buffer = StringBuffer();
      buffer.writeln('✅ 屏幕状态观察完成');
      buffer.writeln('   📱 应用: ${appName.isNotEmpty ? appName : "未知"}');
      buffer.writeln('   📋 状态: $state');
      buffer.writeln('   🚦 屏幕状态: $screenStatus');
      if (blockers.isNotEmpty) {
        buffer.writeln('   ⚠️ 阻碍: ${blockers.join(", ")}');
      }
      if (suggestion != null) {
        final sugAction = suggestion['action'] ?? '';
        final sugTarget = suggestion['target'] ?? '';
        final sugDetail = suggestion['detail'] ?? '';
        buffer.writeln('   💡 建议: $sugAction - $sugTarget');
        if (sugDetail.toString().isNotEmpty) {
          buffer.writeln('   📝 详情: $sugDetail');
        }
      }
      buffer.writeln('   🔍 关键元素: ${keyElements.length} 个');
      for (var i = 0; i < keyElements.length; i++) {
        final elem = keyElements[i];
        if (elem is Map<String, dynamic>) {
          final eType = elem['type'] ?? '';
          final eLabel = elem['label'] ?? '';
          final eDesc = elem['description'] ?? '';
          final ePos = elem['approximate_position'] ?? '';
          buffer.writeln('      [${i + 1}] $eType | "$eLabel" | $eDesc | 位置: $ePos');
        }
      }

      // 调试：打印 suggestion 内容
      final suggestionAction = suggestion?['action'] as String?;
      debugPrint('🔍 [CUA] cua_observe 返回 suggestion: $suggestion');
      debugPrint('🔍 [CUA] suggestionAction=$suggestionAction, screenStatus=$screenStatus');

      return SkillResult.ok(
        buffer.toString(),
        data: {
          ...screenshotData,
          'appName': appName,
          'state': state,
          'screenStatus': screenStatus,
          'keyElements': keyElements,
          'canProceed': canProceed,
          'blockers': blockers,
          'suggestion': suggestion,
        },
      );
    } catch (e) {
      debugPrint('⚠️ VLM 分析失败: $e');
      return SkillResult.ok(
        '✅ 截图成功（VLM 分析异常: $e）\n'
        '   分辨率: ${logicalW}x$logicalH',
        data: {
          ...screenshotData,
          'state': '分析异常',
          'elements': [],
          'suggestion': null,
          'error': e.toString(),
        },
      );
    }
  }

  // ═══════════════════════════════════════════
  // cua_step: 一键循环 - 观察 + 决策 + 执行
  // ═══════════════════════════════════════════

  /// 一键执行完整的 CUA 循环
  /// 
  /// 输入：
  /// - task_goal: 任务目标（必需）
  /// - auto_execute: 是否自动执行建议的操作（默认 false，只返回建议）
  /// 
  /// 流程：
  /// 1. 截图并分析当前状态
  /// 2. 根据任务目标决定下一步
  /// 3. 如果 auto_execute=true，自动执行建议操作
  /// 
  /// 输出：
  /// - observe: 观察结果
  /// - suggestion: 建议的操作
  /// - executed: 是否已执行
  /// - result: 执行结果（如果已执行）
  Future<SkillResult> _cuaStep(Map<String, dynamic> args) async {
    final taskGoal = args['task_goal'] as String?;
    final autoExecute = (args['auto_execute'] as bool?) ?? false;

    if (taskGoal == null || taskGoal.isEmpty) {
      return SkillResult.fail('cua_step 需要 task_goal 参数，描述任务目标');
    }

    debugPrint('🔄 CUA step: taskGoal=$taskGoal autoExecute=$autoExecute');

    // Step 1: 观察当前状态
    final observeResult = await _cuaObserve({'task_goal': taskGoal});
    if (!observeResult.success) {
      return observeResult;
    }

    final observeData = observeResult.data!;
    final state = observeData['state'] as String? ?? '';
    final suggestion = observeData['suggestion'] as Map<String, dynamic>?;
    final canProceed = observeData['canProceed'] as bool? ?? true;
    final blockers = observeData['blockers'] as List? ?? [];

    // Step 2: 检查是否可以继续
    if (!canProceed) {
      return SkillResult.ok(
        '⚠️ 任务受阻，无法继续\n'
        '   状态: $state\n'
        '   阻碍: ${blockers.join(", ")}\n'
        '   建议: ${suggestion?['reason'] ?? "无"}',
        data: {
          'observe': observeData,
          'executed': false,
          'blocked': true,
        },
      );
    }

    // Step 3: 检查是否已完成（只检测强信号）
    // 强信号：screenStatus='Done'（整个任务完成）
    // 弱信号：suggestion.action='done'（子任务完成）→ 不触发完成
    final screenStatus = observeData['screenStatus'] as String?;
    final suggestionAction = suggestion?['action'] as String?;
    final isTaskDone = screenStatus?.toLowerCase() == 'done';
    
    debugPrint('🔍 [CUA] _cuaStep screenStatus=$screenStatus, suggestionAction=$suggestionAction, isTaskDone=$isTaskDone');
    
    if (isTaskDone) {
      debugPrint('🎯 [CUA] _cuaStep 检测到 screenStatus=Done（任务完成），返回 done=true');
      return SkillResult.ok(
        '✅ 任务已完成\n'
        '   状态: $state',
        data: {
          'observe': observeData,
          'executed': false,
          'done': true,
        },
      );
    }

    // Step 4: 返回建议或自动执行
    if (!autoExecute || suggestion == null) {
      return SkillResult.ok(
        '👁️ 观察完成，等待决策\n'
        '   状态: $state\n'
        '   建议: ${suggestion?['action']} - ${suggestion?['target']}\n'
        '   原因: ${suggestion?['reason'] ?? "无"}',
        data: {
          'observe': observeData,
          'suggestion': suggestion,
          'executed': false,
        },
      );
    }

    // Step 5: 自动执行建议的操作
    debugPrint('🔄 自动执行: ${suggestion['action']} - ${suggestion['target']}');

    SkillResult? executeResult;
    final action = suggestion['action'] as String?;

    switch (action) {
      case 'click':
        // 需要先 find_element 定位
        final findResult = await _findElement({
          'query': suggestion['target'],
          'task_context': taskGoal,
        });
        if (findResult.success && findResult.data != null) {
          final cx = findResult.data!['clickX'];
          final cy = findResult.data!['clickY'];
          if (cx != null && cy != null) {
            executeResult = await _mouseClick({
              'x': cx,
              'y': cy,
              'button': 'left',
              'clicks': 1,
            });
          } else {
            executeResult = SkillResult.fail('find_element 未返回有效坐标');
          }
        } else {
          executeResult = findResult;
        }
        break;

      case 'type':
        final text = suggestion['text'] as String?;
        if (text != null && text.isNotEmpty) {
          executeResult = await _keyType({'text': text});
        } else {
          executeResult = SkillResult.fail('type 操作缺少 text 参数');
        }
        break;

      case 'scroll':
        final direction = suggestion['direction'] as String? ?? 'down';
        executeResult = await _mouseScroll({
          'direction': direction,
          'amount': 3,
        });
        break;

      case 'wait':
        await Future.delayed(const Duration(seconds: 2));
        executeResult = SkillResult.ok('等待 2 秒');
        break;

      default:
        executeResult = SkillResult.fail('未知的操作类型: $action');
    }

    return SkillResult.ok(
      '✅ CUA 步骤完成\n'
      '   状态: $state\n'
      '   操作: $action\n'
      '   结果: ${executeResult.success ? "成功" : executeResult.message}',
      data: {
        'observe': observeData,
        'suggestion': suggestion,
        'executed': true,
        'executeResult': executeResult.data,
      },
    );
  }

  /// 快速截图（只获取 base64，不保存确认文件）
  /// 用于变化检测，减少 I/O 开销
  Future<String?> _quickScreenshot() async {
    try {
      final timestamp = DateTime.now().millisecondsSinceEpoch;
      final pngPath = p.join(SkillFileUtils.effectiveWorkingDir, 'cua_quick_$timestamp.png');

      if (Platform.isMacOS) {
        await _screenshotMacOS(pngPath, 1);
      } else if (Platform.isWindows) {
        await _screenshotWindows(pngPath);
      } else if (Platform.isLinux) {
        await _screenshotLinux(pngPath, 1);
      } else {
        return null;
      }

      final file = File(pngPath);
      if (!await file.exists()) return null;
      final bytes = await file.readAsBytes();
      final base64 = base64Encode(bytes);
      // 清理临时文件
      try { await file.delete(); } catch (_) {}
      return base64;
    } catch (e) {
      debugPrint('⚠️ 快速截图失败: $e');
      return null;
    }
  }

  // ─── 操作录制（优化6+8） ───
  static CuaTask? _currentTask;

  /// 会话级自动创建的任务描述（首个操作的内容摘要）
  static String? _sessionDescription;

  /// 设置当前活跃的 CUA 任务
  static void setCurrentTask(CuaTask? task) => _currentTask = task;

  /// 获取当前活跃的 CUA 任务
  static CuaTask? getCurrentTask() => _currentTask;

  /// 自动创建任务（首个 CUA 操作时调用）
  static CuaTask _ensureTask(String action, Map<String, dynamic> args) {
    if (_currentTask != null) return _currentTask!;

    // 根据首个操作推断任务描述
    _sessionDescription ??= _inferDescription(action, args);
    final task = CuaTaskRecorder.createTask(_sessionDescription!);
    _currentTask = task;
    debugPrint('📋 CUA 自动创建任务: ${task.taskId} (${_sessionDescription})');
    return task;
  }

  /// 保存并关闭当前任务
  static Future<void> finalizeTask({String status = 'completed'}) async {
    final task = _currentTask;
    if (task == null) return;

    task.status = status;
    task.endTime = DateTime.now();
    await CuaTaskRecorder.saveTask(task);
    debugPrint('📋 CUA 任务已保存: ${task.taskId} status=$status (${task.operationCount} 步)');
    _currentTask = null;
    _sessionDescription = null;
  }

  /// 静默重置当前任务（清空对话时调用，不持久化）
  static void finalizeTaskSilently() {
    _currentTask = null;
    _sessionDescription = null;
    debugPrint('🧹 CUA 任务状态已重置');
  }

  /// 从首个操作推断任务描述
  static String _inferDescription(String action, Map<String, dynamic> args) {
    switch (action) {
      case 'screenshot':
        return 'CUA 截图会话';
      case 'open_app':
        return '操作 ${args['app_name'] ?? '应用'}';
      case 'mouse_click':
        return 'CUA 鼠标操作会话';
      case 'key_type':
        final text = args['text'] as String? ?? '';
        return '输入 "${text.length > 20 ? '${text.substring(0, 20)}...' : text}"';
      case 'key_combo':
        return 'CUA 快捷键操作 ${args['keys'] ?? ''}';
      default:
        return 'CUA 桌面操作会话';
    }
  }

  /// 记录一次操作
  void _recordOperation(
    String action,
    Map<String, dynamic> args,
    SkillResult result,
    DateTime startTime, {
    String? error,
  }) {
    // 自动创建任务（如果还没有）
    final task = _ensureTask(action, args);

    final screenshotPath = result.data?['filePath'] as String?;
    final durationMs = DateTime.now().difference(startTime).inMilliseconds;

    CuaTaskRecorder.recordOperation(task, CuaOperationRecord(
      timestamp: startTime.millisecondsSinceEpoch,
      action: action,
      args: Map.from(args)..remove('action'),
      success: result.success,
      result: result.message.length > 500
          ? '${result.message.substring(0, 500)}...'
          : result.message,
      screenshotPath: screenshotPath,
      error: error,
      durationMs: durationMs,
    ));

    // 每 10 步操作自动保存一次（防止崩溃丢失）
    if (task.operationCount % 10 == 0) {
      CuaTaskRecorder.saveTask(task);
    }
  }

  // ═══════════════════════════════════════════
  // 截图
  // ═══════════════════════════════════════════

  /// 截图元信息（逻辑/物理分辨率、缩放因子）
  static Map<String, dynamic>? _lastScreenMeta;

  Future<SkillResult> _takeScreenshot(Map<String, dynamic> args) async {
    final display = (args['display'] as int?) ?? 1;
    debugPrint('🖥️ CUA screenshot: display=$display');

    // 临时文件路径（PNG → JPEG 压缩后大小约为 1/10）
    final timestamp = DateTime.now().millisecondsSinceEpoch;
    final pngPath = p.join(SkillFileUtils.effectiveWorkingDir, 'cua_screenshot_$timestamp.png');
    final jpgPath = p.join(SkillFileUtils.effectiveWorkingDir, 'cua_screenshot_$timestamp.jpg');

    try {
      if (Platform.isMacOS) {
        await _screenshotMacOS(pngPath, display);
      } else if (Platform.isWindows) {
        await _screenshotWindows(pngPath);
      } else if (Platform.isLinux) {
        await _screenshotLinux(pngPath, display);
      } else {
        throw CuaException('screenshot', '不支持的平台: ${Platform.operatingSystem}');
      }

      // PNG → JPEG 压缩（质量 85%，保证视觉模型能清晰识别）
      await _convertToJpeg(pngPath, jpgPath);

      final file = File(jpgPath);
      if (!await file.exists()) {
        throw CuaException('screenshot', '截图文件未生成');
      }

      final fileSize = await file.length();
      final bytes = await file.readAsBytes();
      final base64Image = base64Encode(bytes);

      // 使用原生返回的逻辑分辨率（macOS），回退到 system_profiler
      final meta = _lastScreenMeta;
      final logicalWidth = meta?['logicalWidth'] as int? ?? _detectScreenWidth();
      final logicalHeight = meta?['logicalHeight'] as int? ?? _detectScreenHeight();
      final physicalWidth = meta?['physicalWidth'] as int? ?? logicalWidth;
      final physicalHeight = meta?['physicalHeight'] as int? ?? logicalHeight;
      final scaleFactor = meta?['scaleFactor'] as double? ?? 1.0;

      debugPrint('🖥️ 截图成功: ${SkillFileUtils.formatSize(fileSize)} '
          '逻辑: ${logicalWidth}x$logicalHeight 物理: ${physicalWidth}x$physicalHeight 缩放: ${scaleFactor}x');

      // content 不嵌入 base64（避免撑爆 API 请求体），base64 仅存 data 供 UI 渲染
      return SkillResult.ok(
        '✅ 屏幕截图成功\n'
        '   大小: ${SkillFileUtils.formatSize(fileSize)}',
        data: {
          'filePath': jpgPath,
          'fileSize': fileSize,
          'width': logicalWidth,
          'height': logicalHeight,
          'base64': base64Image,
          'mimeType': 'image/jpeg',
          'imageType': 'screenshot',
        },
      );
    } catch (e) {
      if (e is CuaException) rethrow;
      throw CuaException('screenshot', '截图失败: $e');
    } finally {
      // 清理原始 PNG
      try { await File(pngPath).delete(); } catch (_) {}
    }
  }

  // ═══════════════════════════════════════════
  // 针对性 UI 元素定位（视觉模型，比全量扫描快 5-10 倍）
  // ═══════════════════════════════════════════

  /// 针对性查找 UI 元素（视觉模型定位）
  ///
  /// 流程：获取前景窗口 → 截图 → 调用 VLM → 返回坐标 + 绘制标记图
  Future<SkillResult> _findElement(Map<String, dynamic> args) async {
    final query = args['query'] as String?;
    if (query == null || query.isEmpty) {
      throw CuaException('find_element', '请提供要查找的元素描述 (query 参数)');
    }

    debugPrint('🔍 CUA find_element: "$query"');
    final startTime = DateTime.now();

    // 🎯 输出意图：查找 UI 元素（同时显示在控制台和对话框）
    final purpose = args['purpose'] as String?;
    final intentText = StringBuffer();
    intentText.writeln('🎯 意图: 查找 UI 元素');
    intentText.writeln('   目标: "$query"');
    if (purpose != null && purpose.isNotEmpty) {
      intentText.writeln('   目的: $purpose');
    }
    debugPrint(intentText.toString().trim());

    // Step 1: 获取鼠标位置（屏幕逻辑坐标）
    int mouseX = 0, mouseY = 0;
    int logicalW = _detectScreenWidth();
    int logicalH = _detectScreenHeight();

    if (Platform.isMacOS) {
      final mousePos = _MacOSNative.getMousePosition();
      if (mousePos != null) {
        mouseX = mousePos.$1;
        mouseY = mousePos.$2;
        debugPrint('🔍 鼠标位置（逻辑）: ($mouseX, $mouseY)');
      }
    }

    // Step 2: 全屏截图
    final timestamp = DateTime.now().millisecondsSinceEpoch;
    final pngPath = p.join(SkillFileUtils.effectiveWorkingDir, 'cua_find_$timestamp.png');
    final jpgPath = p.join(SkillFileUtils.effectiveWorkingDir, 'cua_find_$timestamp.jpg');
    final markerPath = p.join(SkillFileUtils.effectiveWorkingDir, 'cua_find_marker_$timestamp.jpg');

    try {
      if (Platform.isMacOS) {
        await Process.run('screencapture', ['-x', pngPath]);
        debugPrint('🔍 全屏截图');
      } else if (Platform.isWindows) {
        await _screenshotWindows(pngPath);
      } else if (Platform.isLinux) {
        await _screenshotLinux(pngPath, 1);
      }

      if (!await File(pngPath).exists()) {
        throw CuaException('find_element', '截图失败');
      }

      // Step 3: 读取实际截图尺寸（物理像素）
      int captureW = logicalW;  // 用于 VLM 的尺寸（可能是缩放后的）
      int captureH = logicalH;
      double retinaScale = 1.0;  // Retina 缩放因子
      double vlmScale = 1.0;     // VLM 图片缩放比例

      if (Platform.isMacOS) {
        // 使用 sips 查询图片尺寸（物理像素）
        final sipsResult = await Process.run('sips', ['-g', 'pixelWidth', '-g', 'pixelHeight', pngPath]);
        if (sipsResult.exitCode == 0) {
          final output = sipsResult.stdout.toString();
          final wMatch = RegExp(r'pixelWidth:\s*(\d+)').firstMatch(output);
          final hMatch = RegExp(r'pixelHeight:\s*(\d+)').firstMatch(output);
          if (wMatch != null && hMatch != null) {
            final actualW = int.parse(wMatch.group(1)!);
            final actualH = int.parse(hMatch.group(1)!);
            debugPrint('🔍 实际截图尺寸: ${actualW}x$actualH (窗口逻辑尺寸: ${logicalW}x$logicalH)');
            
            // 计算 Retina 缩放因子（物理像素 / 逻辑尺寸）
            if (logicalW > 0) {
              retinaScale = actualW / logicalW;
              debugPrint('🔍 Retina 缩放因子: ${retinaScale.toStringAsFixed(2)}x (物理=${actualW}, 逻辑=${logicalW})');
            }
            
            captureW = actualW;
            captureH = actualH;

            // 如果图片过大，需要缩放用于 VLM
            const maxEdge = 1920;
            if (max(actualW, actualH) > maxEdge) {
              vlmScale = maxEdge / max(actualW, actualH);
              captureW = (actualW * vlmScale).round();
              captureH = (actualH * vlmScale).round();
              debugPrint('🔍 VLM 缩放: ${actualW}x$actualH -> ${captureW}x${captureH}');
            }
          }
        }
      }

      // 使用 sips 转换为 JPEG 并压缩（macOS）
      if (Platform.isMacOS) {
        // 如果需要缩放，使用 sips -Z 参数
        if (vlmScale < 1.0) {
          await Process.run('sips', ['-Z', '${max(captureW, captureH)}', '-s', 'format', 'jpeg', '-s', 'formatOptions', '75', pngPath, '--out', jpgPath]);
        } else {
          await Process.run('sips', ['-s', 'format', 'jpeg', '-s', 'formatOptions', '75', pngPath, '--out', jpgPath]);
        }
      } else {
        await File(pngPath).copy(jpgPath);
      }

      final jpgBytes = await File(jpgPath).readAsBytes();
      final jpgBase64 = base64Encode(jpgBytes);
      debugPrint('🔍 图片大小: ${jpgBytes.length} bytes');

      // Step 4: 调用 VLM API
      final vlmResult = await _callVlmForFindElement(query, jpgBase64);
      final elapsed = DateTime.now().difference(startTime);

      if (vlmResult == null || vlmResult.isEmpty) {
        return SkillResult.fail('未找到匹配的元素: "$query"');
      }

      // Step 5: 坐标映射
      // VLM [0,1000) → 缩放后像素 → 物理像素 → 逻辑坐标 → 屏幕坐标
      final markers = <Map<String, dynamic>>[];
      for (final elem in vlmResult) {
        final bbox = elem['bbox_2d'] as List? ?? elem['bbox'] as List?;
        if (bbox == null || bbox.length < 4) continue;

        double x1 = (bbox[0] as num).toDouble();
        double y1 = (bbox[1] as num).toDouble();
        double x2 = (bbox[2] as num).toDouble();
        double y2 = (bbox[3] as num).toDouble();

        debugPrint('🔍 CUA 坐标转换: VLM原始=[$x1, $y1, $x2, $y2]');

        // VLM [0,1000) → 缩放后像素
        final maxCoord = [x1, y1, x2, y2].reduce((a, b) => a > b ? a : b);
        if (maxCoord <= 1000) {
          // Qwen 归一化 [0,1000)
          x1 = x1 / 1000 * captureW;
          y1 = y1 / 1000 * captureH;
          x2 = x2 / 1000 * captureW;
          y2 = y2 / 1000 * captureH;
          debugPrint('🔍 CUA 坐标转换: [0,1000) → 缩放后像素=[$x1, $y1, $x2, $y2] (captureW=$captureW, captureH=$captureH)');
        } else if (maxCoord <= 1.0) {
          // 归一化 [0,1]
          x1 = x1 * captureW;
          y1 = y1 * captureH;
          x2 = x2 * captureW;
          y2 = y2 * captureH;
          debugPrint('🔍 CUA 坐标转换: [0,1] → 缩放后像素=[$x1, $y1, $x2, $y2]');
        }

        // 缩放后像素 → 物理像素
        double x1Phys = x1 / vlmScale;
        double y1Phys = y1 / vlmScale;
        double x2Phys = x2 / vlmScale;
        double y2Phys = y2 / vlmScale;
        debugPrint('🔍 CUA 坐标转换: 缩放后像素 → 物理像素=[$x1Phys, $y1Phys, $x2Phys, $y2Phys] (vlmScale=$vlmScale)');

        // 物理像素 → 屏幕逻辑坐标（全屏截图不需要偏移）
        final screenX1 = (x1Phys / retinaScale).round();
        final screenY1 = (y1Phys / retinaScale).round();
        final screenX2 = (x2Phys / retinaScale).round();
        final screenY2 = (y2Phys / retinaScale).round();
        
        // 智能计算点击位置（根据元素类型）
        final elemType = (elem['type'] ?? 'unknown').toString().toLowerCase();
        final clickResult = _getSmartClickPosition(
          elemType: elemType,
          x1: screenX1,
          y1: screenY1,
          x2: screenX2,
          y2: screenY2,
        );
        final cx = clickResult['cx']!;
        final cy = clickResult['cy']!;
        final offsetDesc = clickResult['desc'] ?? '';
        
        debugPrint('🔍 CUA 坐标转换: 物理像素 → 屏幕逻辑=[$screenX1, $screenY1, $screenX2, $screenY2] (retinaScale=$retinaScale)');
        debugPrint('🔍 CUA 坐标转换: 最终屏幕坐标=($cx, $cy) $offsetDesc');

        markers.add({
          'id': markers.length + 1,
          'x1': screenX1, 'y1': screenY1, 'x2': screenX2, 'y2': screenY2,
          'cx': cx, 'cy': cy,
          'w': screenX2 - screenX1, 'h': screenY2 - screenY1,
          'type': elem['type'] ?? 'unknown',
          'label': elem['label'] ?? '',
          'function': elem['function'] ?? '',
          'physX1': x1Phys.round(), 'physY1': y1Phys.round(),  // 物理像素（用于绘制）
          'physX2': x2Phys.round(), 'physY2': y2Phys.round(),
        });
      }

      if (markers.isEmpty) {
        return SkillResult.fail('未找到有效的元素坐标: "$query"');
      }

      // Step 6: 绘制标记图（包含鼠标位置）
      await _drawFindElementMarker(pngPath, markerPath, markers, query, mouseX, mouseY, retinaScale);

      // 构建返回结果（包含意图）
      final best = markers.first;
      final resultText = StringBuffer();
      resultText.writeln(intentText.toString().trim());  // 意图显示在对话框
      resultText.writeln('');
      resultText.writeln('✅ 找到 ${markers.length} 个匹配元素');
      resultText.writeln('');
      
      // 鼠标位置（相对于屏幕）
      if (mouseX > 0 || mouseY > 0) {
        resultText.writeln('🖱️ 当前鼠标位置（屏幕逻辑坐标）:');
        resultText.writeln('   位置: ($mouseX, $mouseY)');
        resultText.writeln('');
      }
      
      // 组件位置信息
      resultText.writeln('🎯 组件位置信息:');
      resultText.writeln('   最佳匹配: [${best['id']}] ${best['type']} "${best['label']}"');
      resultText.writeln('   中心坐标: (${best['cx']}, ${best['cy']}) ← 点击此位置');
      resultText.writeln('   边界框: (${best['x1']}, ${best['y1']}) ~ (${best['x2']}, ${best['y2']})');
      resultText.writeln('   尺寸: ${best['w']} × ${best['h']} 像素');
      if (best['function'] != null && best['function'].toString().isNotEmpty) {
        resultText.writeln('   功能: ${best['function']}');
      }
      resultText.writeln('   耗时: ${elapsed.inMilliseconds}ms');
      
      // 位置关系提示
      if (mouseX > 0 || mouseY > 0) {
        final dx = (best['cx'] as int) - mouseX;
        final dy = (best['cy'] as int) - mouseY;
        resultText.writeln('');
        resultText.writeln('📍 位置关系:');
        resultText.writeln('   鼠标 → 组件中心: Δx=$dx, Δy=$dy');
        if (dx.abs() < 50 && dy.abs() < 50) {
          resultText.writeln('   💡 鼠标已接近目标组件');
        }
      }
      
      // 添加下一步建议
      resultText.writeln('\n💡 下一步建议:');
      resultText.writeln('   1. 点击该元素: mouse_click(x=${best['cx']}, y=${best['cy']})');
      if (best['type'] == 'input' || best['type'] == 'textfield' || best['type'] == 'textbox') {
        resultText.writeln('   2. 输入文本: key_type(text="你的内容")');
      }

      debugPrint('🔍 find_element 完成: ${markers.length} 个结果，耗时 ${elapsed.inMilliseconds}ms');

      // 缓存 find_element 返回的坐标（用于 mouse_click 校验）
      final now = DateTime.now();
      // 先清理过期坐标
      _recentFindCoords.removeWhere((c) => now.difference(c.timestamp).inSeconds > _findCoordTtlSeconds);
      // 添加新坐标
      for (final m in markers) {
        _recentFindCoords.add(_FindElementCoord(
          cx: m['cx'] as int,
          cy: m['cy'] as int,
          query: query,
          timestamp: now,
        ));
      }
      debugPrint('📌 缓存 find_element 坐标: ${markers.length} 个，当前缓存总数: ${_recentFindCoords.length}');

      // 读取标记图 base64（用于在对话框中显示）
      String? markerBase64;
      try {
        final markerFile = File(markerPath);
        if (await markerFile.exists()) {
          final markerBytes = await markerFile.readAsBytes();
          markerBase64 = base64Encode(markerBytes);
          debugPrint('🔍 标记图大小: ${markerBytes.length} bytes');
        }
      } catch (e) {
        debugPrint('⚠️ 读取标记图失败: $e');
      }

      return SkillResult.ok(
        resultText.toString(),
        data: {
          'query': query,
          'markers': markers,
          'bestMatch': best,
          'clickX': best['cx'],
          'clickY': best['cy'],
          'elapsedMs': elapsed.inMilliseconds,
          'markerImage': markerPath,
          'filePath': markerPath,
          'base64': markerBase64,
          'mimeType': 'image/jpeg',
          'imageType': 'screenshot',   // 复用截图渲染通道，让对话框显示标记图
          'intent': '查找 UI 元素: $query',
          'result': '找到 ${markers.length} 个匹配，最佳: ${best['type']} [${best['label']}]',
        },
      );
    } finally {
      // 清理临时文件
      try { await File(pngPath).delete(); } catch (_) {}
    }
  }

  /// 调用 VLM API 查找元素
  Future<List<Map<String, dynamic>>?> _callVlmForFindElement(String query, String imageBase64) async {
    // 检查是否注入了 LLMManager
    if (_llmManager == null) {
      throw CuaException('find_element', 'LLMManager 未注入，无法使用视觉分析');
    }

    // 检查是否配置了视觉模型
    final visionProvider = _llmManager!.currentConfig.visionProvider;
    final visionModel = _llmManager!.currentConfig.visionModel;
    if (visionProvider == null || visionProvider.isEmpty || 
        visionModel == null || visionModel.isEmpty) {
      throw CuaException('find_element', '未配置视觉模型，请在设置中配置');
    }

    // 🎯 优化后的 Prompt：更精确、更有上下文
    final prompt = '''You are a precise UI element locator for desktop applications. Your task is to identify the EXACT position of UI elements.

## Target Element
Find this UI element: "$query"

## Critical Rules
1. **Be Precise**: The bounding box must tightly fit the element, not the entire container
2. **Text Matching**: If query contains text, find the element with that exact or similar text
3. **Icon Recognition**: For icon-only elements, identify by shape (magnifier=search, gear=settings, etc.)
4. **Type Inference**: Determine element type from appearance (button, input, link, dropdown, checkbox, etc.)
5. **Multiple Matches**: Return ALL matching elements sorted by relevance (best match first)

## Common Element Types
- **input/search_box**: Text input fields, search bars
- **button**: Clickable buttons (text or icon)
- **dropdown/select**: Dropdown menus, combo boxes
- **checkbox/radio**: Checkbox or radio button (include the box itself, not just the label)
- **tab**: Tab items in tab bars
- **link**: Hyperlinks (often blue, underlined)
- **menu_item**: Menu items in dropdown or context menus
- **list_item**: Items in a list view

## Output Format
Return a JSON array. Each element must have:
- bbox_2d: [x1,y1,x2,y2] in [0,1000) normalized coordinates (MUST be accurate!)
- type: element type (see above)
- label: visible text on the element (empty string if icon-only)
- function: what clicking does (be specific and concise)
- confidence: 0.0-1.0 (how confident you are about this match)

If NOT found or unclear, return: [{"found":false,"reason":"explanation"}]

## Examples
Query: "搜索框"
Result: [{"bbox_2d":[50,120,350,160],"type":"input","label":"","function":"Search input field","confidence":0.95}]

Query: "发送按钮"
Result: [{"bbox_2d":[700,400,780,440],"type":"button","label":"发送","function":"Send message","confidence":0.98}]

Now find: "$query"''';

    try {
      final response = await _llmManager!.analyzeScreenshot(
        base64Image: imageBase64,
        mimeType: 'image/jpeg',
        prompt: prompt,
      );

      if (response == null || response.isEmpty) {
        throw CuaException('find_element', '视觉模型返回空结果');
      }

      // 解析 JSON 数组
      final jsonMatch = RegExp(r'\[[\s\S]*\]').firstMatch(response);
      if (jsonMatch != null) {
        final elements = jsonDecode(jsonMatch.group(0)!) as List;
        final rawResults = elements.cast<Map<String, dynamic>>();
        
        // 🎯 置信度过滤：移除低置信度结果
        const minConfidence = 0.6;  // 最低置信度阈值
        final filteredResults = rawResults.where((elem) {
          // 检查 found:false 标记
          if (elem['found'] == false) {
            return false;
          }
          
          // 检查置信度（如果提供）
          final confidence = elem['confidence'];
          if (confidence != null) {
            final confValue = (confidence as num).toDouble();
            if (confValue < minConfidence) {
              debugPrint('⚠️ 过滤低置信度结果: ${(elem['label'] ?? 'unknown')} (置信度: $confValue)');
              return false;
            }
          }
          
          // 验证 bbox 合理性
          final bbox = elem['bbox_2d'] ?? elem['bbox'];
          if (bbox != null && bbox is List && bbox.length >= 4) {
            final x1 = (bbox[0] as num).toDouble();
            final y1 = (bbox[1] as num).toDouble();
            final x2 = (bbox[2] as num).toDouble();
            final y2 = (bbox[3] as num).toDouble();
            
            // 检查坐标是否合法
            if (x2 <= x1 || y2 <= y1) {
              debugPrint('⚠️ 过滤非法 bbox: [$x1, $y1, $x2, $y2]');
              return false;
            }
            
            // 检查 bbox 是否过大（可能是误识别整个窗口）
            final width = x2 - x1;
            final height = y2 - y1;
            if (width > 800 || height > 800) {
              debugPrint('⚠️ 过滤超大 bbox: ${width}x$height (可能误识别整个窗口)');
              return false;
            }
          }
          
          return true;
        }).toList();
        
        // 按置信度排序（如果提供）
        filteredResults.sort((a, b) {
          final confA = (a['confidence'] as num?)?.toDouble() ?? 0.5;
          final confB = (b['confidence'] as num?)?.toDouble() ?? 0.5;
          return confB.compareTo(confA);  // 降序
        });
        
        debugPrint('✅ VLM 结果: ${rawResults.length} 个 → 过滤后 ${filteredResults.length} 个');
        return filteredResults;
      }
      
      throw CuaException('find_element', '视觉模型返回格式错误: ${response.substring(0, response.length.clamp(0, 200))}');
    } on CuaException {
      rethrow;
    } catch (e) {
      throw CuaException('find_element', 'VLM 调用失败: $e');
    }
  }

  /// 绘制标记图（用于调试）
  Future<void> _drawFindElementMarker(
    String pngPath,
    String outPath,
    List<Map<String, dynamic>> markers,
    String query,
    int mouseX,
    int mouseY,
    double retinaScale,
  ) async {
    try {
      // 使用 Python Pillow 绘制标记
      final markersJson = jsonEncode(markers);
      final pyScript = '''
import sys
try:
    from PIL import Image, ImageDraw, ImageFont
    import json

    img = Image.open("${pngPath}").convert("RGBA")
    draw = ImageDraw.Draw(img)

    # 加载字体
    font = None
    font_small = None
    for fp in ["/System/Library/Fonts/PingFang.ttc", "/System/Library/Fonts/Helvetica.ttc"]:
        try:
            font = ImageFont.truetype(fp, 16)
            font_small = ImageFont.truetype(fp, 12)
            break
        except: pass

    COLORS = [(220, 50, 47), (38, 139, 210), (133, 153, 0), (181, 137, 0)]

    # 绘制鼠标位置（绿色十字 + 坐标标注）
    mouse_x, mouse_y, retina_scale = ${mouseX}, ${mouseY}, ${retinaScale}
    if mouse_x > 0 or mouse_y > 0:
        # 屏幕逻辑坐标 → 物理像素（全屏截图，无需偏移）
        mouse_win_x = int(mouse_x * retina_scale)
        mouse_win_y = int(mouse_y * retina_scale)

        if 0 <= mouse_win_x <= img.width and 0 <= mouse_win_y <= img.height:
            mouse_color = (0, 255, 100)
            cross_size = 20
            # 十字准星
            draw.line([mouse_win_x - cross_size, mouse_win_y, mouse_win_x + cross_size, mouse_win_y],
                      fill=mouse_color + (255,), width=2)
            draw.line([mouse_win_x, mouse_win_y - cross_size, mouse_win_x, mouse_win_y + cross_size],
                      fill=mouse_color + (255,), width=2)
            # 外圈
            draw.ellipse([mouse_win_x - 12, mouse_win_y - 12, mouse_win_x + 12, mouse_win_y + 12],
                         outline=mouse_color + (255,), width=2)
            # 坐标标注
            mouse_label = f"({mouse_x}, {mouse_y})"
            if font_small:
                mbbox = draw.textbbox((0, 0), mouse_label, font=font_small)
                mw, mh = mbbox[2] - mbbox[0], mbbox[3] - mbbox[1]
                mx = mouse_win_x + 20
                my = mouse_win_y - mh // 2
                if mx + mw > img.width: mx = mouse_win_x - mw - 20
                if my < 0: my = 10
                if my + mh > img.height: my = img.height - mh - 10
                draw.rectangle([mx - 2, my - 1, mx + mw + 2, my + mh + 1], fill=(0, 0, 0, 200))
                draw.text((mx, my), mouse_label, fill=mouse_color + (255,), font=font_small)

    markers = json.loads("""$markersJson""")

    for m in markers:
        color = COLORS[(m["id"] - 1) % len(COLORS)]
        # 使用物理像素坐标
        x1, y1, x2, y2 = m["physX1"], m["physY1"], m["physX2"], m["physY2"]

        # 矩形边框
        draw.rectangle([x1, y1, x2, y2], outline=color + (255,), width=3)

        # 四个角坐标标注
        corners = [
            (x1, y1, f"({m['x1']},{m['y1']})"),
            (x2, y1, f"({m['x2']},{m['y1']})"),
            (x1, y2, f"({m['x1']},{m['y2']})"),
            (x2, y2, f"({m['x2']},{m['y2']})"),
        ]
        for cx, cy, text in corners:
            draw.ellipse([cx - 4, cy - 4, cx + 4, cy + 4], fill=color + (255,))
            if font_small:
                draw.text((cx + 8, cy - 6), text, fill=color + (255,), font=font_small)

        # 中心点十字
        win_cx = (x1 + x2) // 2
        win_cy = (y1 + y2) // 2
        draw.ellipse([win_cx - 6, win_cy - 6, win_cx + 6, win_cy + 6],
                     outline=color + (255,), width=2)
        draw.line([win_cx - 10, win_cy, win_cx + 10, win_cy], fill=color + (255,), width=2)
        draw.line([win_cx, win_cy - 10, win_cx, win_cy + 10], fill=color + (255,), width=2)

        # 编号气泡
        badge_r = 18
        bx, by = x1 + badge_r, y1 + badge_r
        draw.ellipse([bx - badge_r, by - badge_r, bx + badge_r, by + badge_r],
                     fill=color + (255,), outline=(255, 255, 255, 255), width=2)
        label = str(m["id"])
        if font:
            bbox = draw.textbbox((0, 0), label, font=font)
            tw, th = bbox[2] - bbox[0], bbox[3] - bbox[1]
            draw.text((bx - tw // 2, by - th // 2 - 1), label, fill=(255, 255, 255, 255), font=font)

        # 标签（类型 + 文本）
        tag = f"{m['type']}: {m.get('label', '')[:20]}" if m.get('label') else m['type']
        if font_small:
            tbbox = draw.textbbox((0, 0), tag, font=font_small)
            tw, th = tbbox[2] - tbbox[0], tbbox[3] - tbbox[1]
            tx, ty = x1, y1 - th - 6
            if ty < 0: ty = y2 + 4
            draw.rectangle([tx - 2, ty - 1, tx + tw + 2, ty + th + 1], fill=(0, 0, 0, 200))
            draw.text((tx, ty), tag, fill=(255, 255, 255, 255), font=font_small)

        # 屏幕坐标（底部）
        coord_text = f"屏幕: ({m['cx']}, {m['cy']})"
        if font_small:
            cbbox = draw.textbbox((0, 0), coord_text, font=font_small)
            cw, ch = cbbox[2] - cbbox[0], cbbox[3] - cbbox[1]
            cx_txt, cy_txt = x1, y2 + 4
            draw.rectangle([cx_txt - 2, cy_txt - 1, cx_txt + cw + 2, cy_txt + ch + 1], fill=(0, 0, 0, 180))
            draw.text((cx_txt, cy_txt), coord_text, fill=(200, 255, 200, 255), font=font_small)

    img.convert("RGB").save("$outPath", "JPEG", quality=90)
    print("OK")
except Exception as e:
    print(f"ERROR: {e}", file=sys.stderr)
    sys.exit(1)
''';
      final result = await Process.run('python3', ['-c', pyScript]);
      if (result.exitCode == 0) {
        debugPrint('🔍 标记图已保存: $outPath');
      } else {
        debugPrint('⚠️ 标记图绘制失败: ${result.stderr}');
      }
    } catch (e) {
      debugPrint('⚠️ 标记图绘制异常: $e');
    }
  }

  /// 将 PNG 截图转换为 JPEG（质量 85%，保证视觉模型能清晰识别元素）
  Future<void> _convertToJpeg(String pngPath, String jpgPath) async {
    if (Platform.isMacOS) {
      final result = await Process.run('sips', [
        '-s', 'format', 'jpeg',
        '-s', 'formatOptions', '85',
        pngPath, '--out', jpgPath,
      ]);
      if (result.exitCode != 0) {
        // sips 失败则直接使用 PNG（不应发生，但做兜底）
        await File(pngPath).copy(jpgPath);
      }
    } else {
      // Windows/Linux：直接用 PNG（非 macOS 平台暂不转换）
      await File(pngPath).copy(jpgPath);
    }
  }

  Future<void> _screenshotMacOS(String filePath, int display) async {
    // 使用原生 MethodChannel 截图（CoreGraphics CGWindowListCreateImage）
    // 在应用进程内调用，继承应用的屏幕录制权限，不依赖 screencapture 外部命令
    // 同时自动排除鹅宝自身窗口，不会截到宠物/聊天面板
    try {
      final result = await _kScreenshotChannel.invokeMethod<Map>('captureScreen', {'filePath': filePath});
      if (!await File(filePath).exists()) {
        throw CuaException('screenshot', '截图文件未生成');
      }
      // 保存原生层返回的屏幕元信息（逻辑/物理分辨率、缩放因子）
      if (result != null) {
        _lastScreenMeta = {
          'logicalWidth': (result['logicalWidth'] as num?)?.toInt(),
          'logicalHeight': (result['logicalHeight'] as num?)?.toInt(),
          'physicalWidth': (result['physicalWidth'] as num?)?.toInt(),
          'physicalHeight': (result['physicalHeight'] as num?)?.toInt(),
          'scaleFactor': (result['scaleFactor'] as num?)?.toDouble(),
        };

      }
    } on PlatformException catch (e) {
      debugPrint('⚠️ 原生截图失败: ${e.message}，回退到 screencapture');
      // 回退到 screencapture（需要系统设置中单独授权）
      final args = ['-x'];
      if (display > 1) args.addAll(['-D', '$display']);
      args.add(filePath);
      final result = await Process.run('screencapture', args);
      if (result.exitCode != 0) {
        throw CuaException('screenshot', 'screencapture 失败: ${result.stderr}');
      }
      if (!await File(filePath).exists()) {
        throw CuaException('screenshot',
            '截图文件未生成。请检查：\n'
            '1. 系统偏好设置 → 隐私与安全性 → 屏幕录制 → 勾选鹅宝\n'
            '2. 修改权限后需重启应用');
      }
      // screencapture 回退时无法获取缩放因子，清除元信息
      _lastScreenMeta = null;
    }
  }

  Future<void> _screenshotWindows(String filePath) async {
    // 使用 PowerShell + .NET 截图
    final psScript = '''
Add-Type -AssemblyName System.Windows.Forms
Add-Type -AssemblyName System.Drawing
\$screen = [System.Windows.Forms.Screen]::PrimaryScreen.Bounds
\$bitmap = New-Object System.Drawing.Bitmap(\$screen.Width, \$screen.Height)
\$graphics = [System.Drawing.Graphics]::FromImage(\$bitmap)
\$graphics.CopyFromScreen(\$screen.Location, [System.Drawing.Point]::Empty, \$screen.Size)
\$bitmap.Save('$filePath')
\$graphics.Dispose()
\$bitmap.Dispose()
''';
    final result = await Process.run(
      'powershell',
      ['-NoProfile', '-Command', psScript],
    );
    if (result.exitCode != 0) {
      throw CuaException('screenshot', 'PowerShell 截图失败: ${result.stderr}');
    }
  }

  Future<void> _screenshotLinux(String filePath, int display) async {
    // 优先使用 gnome-screenshot，回退到 scrot/import
    final tools = ['gnome-screenshot', 'scrot', 'import'];
    for (final tool in tools) {
      try {
        final args = tool == 'import'
            ? ['-window', 'root', filePath]
            : ['-f', filePath];
        final result = await Process.run(tool, args);
        if (result.exitCode == 0) return;
      } catch (_) {
        continue;
      }
    }
    throw CuaException('screenshot', '未找到截图工具（需要 gnome-screenshot/scrot/ImageMagick）');
  }

  /// 检测屏幕逻辑分辨率（macOS 返回 NSScreen 的 points 尺寸，非物理像素）
  /// system_profiler 返回的是物理像素（如 3456x2234），需要除以缩放因子得到逻辑分辨率
  int _detectScreenWidth() {
    // 优先使用 _lastScreenMeta（原生 NSScreen 的准确逻辑尺寸）
    final meta = _lastScreenMeta;
    if (meta != null && meta['logicalWidth'] != null) {
      return meta['logicalWidth'] as int;
    }
    try {
      if (Platform.isMacOS) {
        // 尝试用 python3 获取 NSScreen 逻辑分辨率
        final pyResult = Process.runSync('python3', [
          '-c',
          'from AppKit import NSScreen; s=NSScreen.mainScreen(); print(int(s.frame().size.width))'
        ]);
        if (pyResult.exitCode == 0) {
          final w = int.tryParse(pyResult.stdout.toString().trim());
          if (w != null && w > 0) return w;
        }
        // 回退：system_profiler 返回物理像素，除以 2（Retina 默认缩放）
        final result = Process.runSync('system_profiler', ['SPDisplaysDataType']);
        final stdout = result.stdout.toString();
        final match = RegExp(r'Resolution:\s*(\d+)\s*x\s*(\d+)').firstMatch(stdout);
        if (match != null) {
          final physicalW = int.tryParse(match.group(1)!) ?? 1920;
          final isRetina = stdout.contains('Retina');
          return isRetina ? physicalW ~/ 2 : physicalW;
        }
      }
    } catch (_) {}
    return 1920; // 默认值
  }

  int _detectScreenHeight() {
    // 优先使用 _lastScreenMeta（原生 NSScreen 的准确逻辑尺寸）
    final meta = _lastScreenMeta;
    if (meta != null && meta['logicalHeight'] != null) {
      return meta['logicalHeight'] as int;
    }
    try {
      if (Platform.isMacOS) {
        // 尝试用 python3 获取 NSScreen 逻辑分辨率
        final pyResult = Process.runSync('python3', [
          '-c',
          'from AppKit import NSScreen; s=NSScreen.mainScreen(); print(int(s.frame().size.height))'
        ]);
        if (pyResult.exitCode == 0) {
          final h = int.tryParse(pyResult.stdout.toString().trim());
          if (h != null && h > 0) return h;
        }
        // 回退：system_profiler 返回物理像素，除以 2（Retina 默认缩放）
        final result = Process.runSync('system_profiler', ['SPDisplaysDataType']);
        final stdout = result.stdout.toString();
        final match = RegExp(r'Resolution:\s*(\d+)\s*x\s*(\d+)').firstMatch(stdout);
        if (match != null) {
          final physicalH = int.tryParse(match.group(2)!) ?? 1080;
          final isRetina = stdout.contains('Retina');
          return isRetina ? physicalH ~/ 2 : physicalH;
        }
      }
    } catch (_) {}
    return 1080; // 默认值
  }

  // ═══════════════════════════════════════════
  // 鼠标操作
  // ═══════════════════════════════════════════

  Future<SkillResult> _mouseClick(Map<String, dynamic> args) async {
    // 和 test_cua_wechat.py 保持一致：直接使用屏幕逻辑坐标
    final x = (args['x'] as int?) ?? 0;
    final y = (args['y'] as int?) ?? 0;
    final button = args['button'] as String? ?? 'left';
    final clicks = (args['clicks'] as int?) ?? 1;
    final purpose = args['purpose'] as String?;
    final expectedOutcome = args['expected_outcome'] as String?;
    final taskContext = args['task_context'] as String?;

    // ── find_element 坐标校验 ──
    // 检查 mouse_click 的坐标是否来自最近的 find_element 返回值
    final now = DateTime.now();
    // 先清理过期坐标
    _recentFindCoords.removeWhere((c) => now.difference(c.timestamp).inSeconds > _findCoordTtlSeconds);
    
    bool coordValidated = false;
    String? matchedQuery;
    if (_recentFindCoords.isNotEmpty) {
      for (final coord in _recentFindCoords) {
        final dx = (x - coord.cx).abs();
        final dy = (y - coord.cy).abs();
        if (dx <= _coordTolerance && dy <= _coordTolerance) {
          coordValidated = true;
          matchedQuery = coord.query;
          break;
        }
      }
    }
    
    if (!coordValidated) {
      debugPrint('⛔ mouse_click 坐标($x, $y) 未通过 find_element 校验！缓存坐标: ${_recentFindCoords.map((c) => "(${c.cx},${c.cy})").join(", ")}');
      return SkillResult.fail(
        '⛔ 操作被拦截：mouse_click 的坐标 ($x, $y) 不是来自 find_element 的返回值！\n\n'
        '🚫 严禁凭猜测或记忆直接给坐标点击。\n'
        '✅ 正确流程：先调用 cua(action="find_element", query="目标元素描述") 定位元素，再用返回的精确坐标执行 mouse_click。\n'
        '${_recentFindCoords.isEmpty ? "💡 当前没有任何 find_element 缓存坐标，请先调用 find_element。" : "💡 当前缓存的 find_element 坐标: ${_recentFindCoords.map((c) => "(${c.cx},${c.cy}) [${c.query}]").join(", ")}"}',
      );
    }
    
    debugPrint('✅ mouse_click 坐标校验通过: ($x, $y) 匹配 find_element("$matchedQuery")');


    // 匹配最近的 SOM 标记（需要转换坐标）
    final screenWidth = _detectScreenWidth();
    final screenHeight = _detectScreenHeight();
    final normalizedX = (x / screenWidth * 1000).round();
    final normalizedY = (y / screenHeight * 1000).round();
    final marker = CuaSom.findNearestMarker(normalizedX.toDouble(), normalizedY.toDouble());
    final markerHint = marker != null
        ? ' [${marker.id}] ${marker.role}${marker.title.isNotEmpty ? ' "${marker.title}"' : ''}'
        : '';

    // 🎯 输出意图（同时显示在控制台和对话框）
    final intentText = StringBuffer();
    intentText.writeln('🎯 意图: 鼠标点击');
    intentText.writeln('   操作: ${button} ${clicks == 2 ? '双击' : '单击'}');
    intentText.writeln('   位置: ($x, $y)$markerHint');
    if (purpose != null && purpose.isNotEmpty) {
      intentText.writeln('   目的: $purpose');
    }
    debugPrint(intentText.toString().trim());

    debugPrint('🖥️ CUA mouse_click: 屏幕坐标($x, $y) button=$button clicks=$clicks$markerHint');

    if (Platform.isMacOS) {
      await _mouseClickMacOS(x, y, button, clicks);
    } else if (Platform.isWindows) {
      await _mouseClickWindows(x, y, button, clicks);
    } else if (Platform.isLinux) {
      await _mouseClickLinux(x, y, button, clicks);
    } else {
      throw CuaException('mouse_click', '不支持的平台');
    }

    // 点击后自适应等待 UI 响应，然后自动截图确认（支持智能分析）
    final confirmResult = await _waitForChangeAndScreenshot(
      'mouse_click',
      expectedOutcome: expectedOutcome,
      taskContext: taskContext,
    );

    final confirmInfo = _formatConfirmResult(confirmResult);
    final resultText = StringBuffer();
    resultText.writeln(intentText.toString().trim());
    resultText.writeln('');
    resultText.writeln('✅ 鼠标点击成功 ($x, $y) button=$button clicks=$clicks$confirmInfo');
    return SkillResult.ok(
      resultText.toString().trim(),
      data: {
        ...?confirmResult,
        'intent': '鼠标点击 ($x, $y)',
        'result': '点击完成',
      },
    );
  }

  /// 格式化确认结果（包含智能分析）
  String _formatConfirmResult(Map<String, dynamic>? result) {
    if (result == null) return '';
    
    final buffer = StringBuffer();
    buffer.writeln('\n📸 操作后截图确认:');
    buffer.writeln('   ${result['info']}');
    
    final analysis = result['analysis'] as Map<String, dynamic>?;
    if (analysis != null) {
      final success = analysis['success'] == true;
      buffer.writeln('\n🤖 智能分析:');
      buffer.writeln('   操作结果: ${success ? '✅ 成功' : '❌ 失败'} - ${analysis['successReason'] ?? '未知'}');
      buffer.writeln('   屏幕状态: ${analysis['screenDescription'] ?? '未知'}');
      
      final nextAction = analysis['nextAction'] as Map<String, dynamic>?;
      if (nextAction != null) {
        buffer.writeln('   建议下一步: ${nextAction['action']} - ${nextAction['reason']}');
      }
      
      final blockers = analysis['blockers'] as List?;
      if (blockers != null && blockers.isNotEmpty) {
        buffer.writeln('   ⚠️ 阻碍因素: ${blockers.join(', ')}');
      }
    }
    return buffer.toString();
  }

  /// 点击后截图确认（复用截图逻辑，不经过视觉分析）
  Future<Map<String, dynamic>?> _takeScreenshotForConfirm() async {
    try {
      final timestamp = DateTime.now().millisecondsSinceEpoch;
      final pngPath = p.join(SkillFileUtils.effectiveWorkingDir, 'cua_confirm_$timestamp.png');
      final jpgPath = p.join(SkillFileUtils.effectiveWorkingDir, 'cua_confirm_$timestamp.jpg');

      try {
        if (Platform.isMacOS) {
          await _screenshotMacOS(pngPath, 1);
        } else if (Platform.isWindows) {
          await _screenshotWindows(pngPath);
        } else if (Platform.isLinux) {
          await _screenshotLinux(pngPath, 1);
        } else {
          return null;
        }

        // 注意：不自动分析所有 UI，保持截图原样
        // 符合 test_cua_wechat.py 的逻辑

        await _convertToJpeg(pngPath, jpgPath);

        final file = File(jpgPath);
        if (!await file.exists()) return null;

        final fileSize = await file.length();
        final bytes = await file.readAsBytes();
        final base64Image = base64Encode(bytes);
        final meta = _lastScreenMeta;
        final screenWidth = meta?['logicalWidth'] as int? ?? _detectScreenWidth();
        final screenHeight = meta?['logicalHeight'] as int? ?? _detectScreenHeight();

        debugPrint('📸 确认截图: ${SkillFileUtils.formatSize(fileSize)}');

        return {
          'filePath': jpgPath,
          'fileSize': fileSize,
          'width': screenWidth,
          'height': screenHeight,
          'base64': base64Image,
          'mimeType': 'image/jpeg',
          'imageType': 'confirm_screenshot',
          'info': '操作后截图确认, 大小: ${SkillFileUtils.formatSize(fileSize)}',
        };
      } finally {
        try { await File(pngPath).delete(); } catch (_) {}
      }
    } catch (e) {
      debugPrint('⚠️ 点击确认截图失败: $e');
      return null;
    }
  }

  Future<void> _mouseClickMacOS(int x, int y, String button, int clicks) async {
    // CGEvent 和截图都使用左上角为原点、Y 轴向下的坐标系统，无需翻转
    // （cliclick 同样使用左上角原点，坐标一致）
    final buttonMap = {'left': 0, 'right': 1, 'middle': 2};
    final btn = buttonMap[button] ?? 0;
    debugPrint('🖥️ CUA CGEvent mouse_click: ($x, $y) button=$btn clicks=$clicks');

    // 优先使用原生 CGEvent（进程内，仅需应用自身辅助功能权限）
    try {
      _MacOSNative.postMouseClick(x.toDouble(), y.toDouble(), btn, clicks);
      return;
    } on StateError {
      throw CuaException('mouse_click',
          '辅助功能权限不足。\n'
          '请在 系统设置 → 隐私与安全性 → 辅助功能 中勾选鹅宝，然后重启应用。');
    } catch (e) {
      debugPrint('⚠️ CUA CGEvent mouse_click 失败: $e，回退到 cliclick');
    }
    // 回退到 cliclick（同样使用左上角原点坐标）
    final buttonMap2 = {'left': 'c', 'right': 'r', 'middle': 'm'};
    final key = buttonMap2[button] ?? 'c';
    final cmd = clicks == 1
        ? 'kp:$key $x,$y'
        : 'kp:$key $x,$y kp:$key $x,$y';
    final result = await _runCliclickBash(cmd);
    if (result.exitCode != 0) {
      await _mouseClickAppleScript(x, y, button, clicks);
    }
  }

  Future<void> _mouseClickAppleScript(int x, int y, String button, int clicks) async {
    // 纯 AppleScript 方案：使用 System Events 的 click at（不依赖 Python/PyObjC）
    // 注意：仅支持左键点击，右键需要辅助功能权限
    if (button == 'left') {
      final script = '''
tell application "System Events"
  set clicksCount to $clicks
  repeat clicksCount times
    click at {$x, $y}
  end repeat
end tell
''';
      final result = await Process.run('osascript', ['-e', script]);
      if (result.exitCode != 0) {
        throw CuaException('mouse_click',
            'AppleScript 点击失败: ${result.stderr}\n'
            '请确保已安装 cliclick（brew install cliclick）');
      }
    } else {
      throw CuaException('mouse_click',
          '右键/中键点击需要 cliclick（brew install cliclick）');
    }
  }

  Future<void> _mouseClickWindows(int x, int y, String button, int clicks) async {
    // 使用 user32.dll SendInput API（兼容 UWP 应用，SendKeys 不支持 UWP）
    final mouseDownFlags = {'left': 0x0002, 'middle': 0x0020, 'right': 0x0008};
    final mouseUpFlags = {'left': 0x0004, 'middle': 0x0040, 'right': 0x0010};
    final downFlag = mouseDownFlags[button] ?? 0x0002;
    final upFlag = mouseUpFlags[button] ?? 0x0004;

    final psScript = r'''
Add-Type @"
using System;
using System.Runtime.InteropServices;
public class WinInput {
    [StructLayout(LayoutKind.Sequential)]
    struct INPUT {
        public uint type;
        public MOUSEINPUT mi;
    }
    [StructLayout(LayoutKind.Sequential)]
    struct MOUSEINPUT {
        public int dx;
        public int dy;
        public uint mouseData;
        public uint dwFlags;
        public uint time;
        public IntPtr dwExtraInfo;
    }
    [DllImport("user32.dll", SetLastError = true)]
    static extern uint SendInput(uint nInputs, INPUT[] pInputs, int cbSize);
    [DllImport("user32.dll")]
    static extern bool SetCursorPos(int X, int Y);

    public static void MouseClick(int x, int y, uint downFlag, uint upFlag, int clicks) {
        SetCursorPos(x, y);
        System.Threading.Thread.Sleep(50);
        for (int i = 0; i < clicks; i++) {
            INPUT[] inputs = new INPUT[2];
            inputs[0].type = 0;
            inputs[0].mi.dwFlags = downFlag;
            inputs[1].type = 0;
            inputs[1].mi.dwFlags = upFlag;
            SendInput(2, inputs, Marshal.SizeOf(typeof(INPUT)));
            System.Threading.Thread.Sleep(50);
        }
    }
}
"@ -ErrorAction SilentlyContinue
''';

    final clickScript = '[WinInput]::MouseClick($x, $y, $downFlag, $upFlag, $clicks)';
    final result = await Process.run('powershell', ['-NoProfile', '-Command', '$psScript\n$clickScript']);
    if (result.exitCode != 0) {
      // 回退到旧的 SendKeys 方式
      debugPrint('⚠️ Windows SendInput 失败，回退到 SendKeys: ${result.stderr}');
      final buttonCode = {'left': 0, 'middle': 4096, 'right': 2048}[button] ?? 0;
      final fallbackScript = '''
Add-Type -AssemblyName System.Windows.Forms
\$pos = New-Object System.Drawing.Point($x, $y)
[System.Windows.Forms.Cursor]::Position = \$pos
Start-Sleep -Milliseconds 50
for (\$i = 0; \$i -lt $clicks; \$i++) {
  [System.Windows.Forms.SendKeys]::SendWait('{'$buttonCode'}')
  Start-Sleep -Milliseconds 50
}
''';
      final fallbackResult = await Process.run('powershell', ['-NoProfile', '-Command', fallbackScript]);
      if (fallbackResult.exitCode != 0) {
        throw CuaException('mouse_click', 'Windows 点击失败: ${fallbackResult.stderr}');
      }
    }
  }

  Future<void> _mouseClickLinux(int x, int y, String button, int clicks) async {
    // 使用 xdotool
    final buttonNum = {'left': 1, 'middle': 2, 'right': 3}[button] ?? 1;
    for (var i = 0; i < clicks; i++) {
      final result = await Process.run('xdotool', ['mousemove', '$x', '$y', 'click', '--repeat', '$clicks', '--delay', '50', '$buttonNum']);
      if (result.exitCode != 0) {
        throw CuaException('mouse_click', 'xdotool 未安装或执行失败');
      }
    }
  }

  Future<SkillResult> _mouseMove(Map<String, dynamic> args) async {
    // 和 test_cua_wechat.py 保持一致：直接使用屏幕逻辑坐标
    final x = (args['x'] as int?) ?? 0;
    final y = (args['y'] as int?) ?? 0;

    debugPrint('🖥️ CUA mouse_move: 屏幕坐标($x, $y)');

    if (Platform.isMacOS) {
      // CGEvent 使用左上角原点，与截图一致，无需翻转
      try {
        _MacOSNative.postMouseMove(x.toDouble(), y.toDouble());
      } on StateError {
        throw CuaException('mouse_move',
            '辅助功能权限不足。请在 系统设置 → 隐私与安全性 → 辅助功能 中勾选鹅宝，然后重启应用。');
      } catch (e) {
        debugPrint('⚠️ CUA CGEvent mouse_move 失败: $e，回退到 cliclick');
        final result = await _runCliclickBash('m:$x,$y');
        if (result.exitCode != 0) {
          throw CuaException('mouse_move',
              'cliclick 未安装或执行失败。请运行: brew install cliclick');
        }
      }
    } else if (Platform.isWindows) {
      final psScript = '''
Add-Type -AssemblyName System.Windows.Forms
[System.Windows.Forms.Cursor]::Position = New-Object System.Drawing.Point($x, $y)
''';
      await Process.run('powershell', ['-NoProfile', '-Command', psScript]);
    } else if (Platform.isLinux) {
      await Process.run('xdotool', ['mousemove', '--sync', '$x', '$y']);
    }

    return SkillResult.ok('✅ 鼠标移动到 ($x, $y)');
  }

  Future<SkillResult> _mouseScroll(Map<String, dynamic> args) async {
    // 和其他鼠标操作保持一致：直接使用屏幕逻辑坐标
    final x = (args['x'] as int?) ?? 0;
    final y = (args['y'] as int?) ?? 0;
    final scrollX = args['scroll_x'] as int? ?? 0;
    final scrollY = args['scroll_y'] as int? ?? 0;
    final expectedOutcome = args['expected_outcome'] as String?;
    final taskContext = args['task_context'] as String?;

    debugPrint('🖥️ CUA mouse_scroll: 屏幕坐标($x, $y) delta=($scrollX, $scrollY)');

    if (Platform.isMacOS) {
      final clampedY = (-scrollY).clamp(-100, 100);
      final clampedX = scrollX.clamp(-100, 100);
      if (clampedY != 0 || clampedX != 0) {
        try {
          debugPrint('🖥️ CUA CGEvent mouse_scroll: ($clampedX, $clampedY)');
          // CGEvent scrollWheel: 正值向上滚，负值向下滚
          if (clampedY != 0) _MacOSNative.postScrollWheel(clampedY);
          if (clampedX != 0) _MacOSNative.postScrollWheel(clampedX, horizontal: true);
        } on StateError {
          throw CuaException('mouse_scroll',
              '辅助功能权限不足。请在 系统设置 → 隐私与安全性 → 辅助功能 中勾选鹅宝，然后重启应用。');
        } catch (e) {
          debugPrint('⚠️ CUA CGEvent mouse_scroll 失败: $e，回退到 cliclick');
          final result = await _runCliclickBash('ss:$clampedX,$clampedY');
          if (result.exitCode != 0) {
            throw CuaException('mouse_scroll',
                'cliclick 未安装或执行失败。请运行: brew install cliclick');
          }
        }
      }
    } else if (Platform.isWindows) {
      final psScript = '''
Add-Type -AssemblyName System.Windows.Forms
[System.Windows.Forms.Cursor]::Position = New-Object System.Drawing.Point($x, $y)
Start-Sleep -Milliseconds 50
[System.Windows.Forms.SendKeys]::SendWait('{WHEEL_UP $scrollY}')
''';
      await Process.run('powershell', ['-NoProfile', '-Command', psScript]);
    } else if (Platform.isLinux) {
      // xdotool click 4=up, 5=down
      if (scrollY < 0) {
        for (var i = 0; i < scrollY.abs(); i++) {
          await Process.run('xdotool', ['click', '4']);
        }
      } else if (scrollY > 0) {
        for (var i = 0; i < scrollY; i++) {
          await Process.run('xdotool', ['click', '5']);
        }
      }
    }

    // 操作后自适应等待并截图确认（支持智能分析）
    final confirmResult = await _waitForChangeAndScreenshot(
      'mouse_scroll',
      expectedOutcome: expectedOutcome,
      taskContext: taskContext,
    );
    final confirmInfo = _formatConfirmResult(confirmResult);
    return SkillResult.ok('✅ 滚动操作完成: 水平=$scrollX, 垂直=$scrollY$confirmInfo');
  }

  Future<SkillResult> _mouseDrag(Map<String, dynamic> args) async {
    // 和 test_cua_wechat.py 保持一致：直接使用屏幕逻辑坐标
    final x = (args['x'] as int?) ?? 0;
    final y = (args['y'] as int?) ?? 0;
    final targetX = (args['target_x'] as int?) ?? args['x'] as int? ?? 0;
    final targetY = (args['target_y'] as int?) ?? args['y'] as int? ?? 0;
    final expectedOutcome = args['expected_outcome'] as String?;
    final taskContext = args['task_context'] as String?;

    debugPrint('🖥️ CUA mouse_drag: 屏幕坐标($x, $y) → ($targetX, $targetY)');

    if (Platform.isMacOS) {
      // CGEvent 使用左上角原点，与截图一致，无需翻转
      try {
        _MacOSNative.postMouseDrag(x.toDouble(), y.toDouble(), targetX.toDouble(), targetY.toDouble());
      } on StateError {
        throw CuaException('mouse_drag',
            '辅助功能权限不足。请在 系统设置 → 隐私与安全性 → 辅助功能 中勾选鹅宝，然后重启应用。');
      } catch (e) {
        debugPrint('⚠️ CUA CGEvent mouse_drag 失败: $e，回退到 cliclick');
        final result = await _runCliclickBash('kd:c $x,$y mm:$targetX,$targetY mu:c');
        if (result.exitCode != 0) {
          throw CuaException('mouse_drag',
              'cliclick 未安装或执行失败。请运行: brew install cliclick');
        }
      }
    } else if (Platform.isWindows) {
      final psScript = '''
Add-Type -AssemblyName System.Windows.Forms
Add-Type -AssemblyName System.Drawing
\$start = New-Object System.Drawing.Point($x, $y)
\$end = New-Object System.Drawing.Point($targetX, $targetY)
[System.Windows.Forms.Cursor]::Position = \$start
Start-Sleep -Milliseconds 100
[System.Windows.Forms.SendKeys]::SendWait('{LEFT}')
Start-Sleep -Milliseconds 50
[System.Windows.Forms.Cursor]::Position = \$end
Start-Sleep -Milliseconds 50
[System.Windows.Forms.SendKeys]::SendWait('{LEFT UP}')
''';
      await Process.run('powershell', ['-NoProfile', '-Command', psScript]);
    } else if (Platform.isLinux) {
      // xdotool: 按下 → 移动 → 释放
      await Process.run('xdotool', ['mousedown', '1']);
      await Process.run('xdotool', ['mousemove', '--sync', '$targetX', '$targetY']);
      await Process.run('xdotool', ['mouseup', '1']);
    }

    // 操作后自适应等待并截图确认（支持智能分析）
    final confirmResult = await _waitForChangeAndScreenshot(
      'mouse_drag',
      expectedOutcome: expectedOutcome,
      taskContext: taskContext,
    );
    final confirmInfo = _formatConfirmResult(confirmResult);
    return SkillResult.ok('✅ 拖拽完成: ($x, $y) → ($targetX, $targetY)$confirmInfo');
  }

  // ═══════════════════════════════════════════
  // 打开应用
  // ═══════════════════════════════════════════

  Future<SkillResult> _openApp(Map<String, dynamic> args) async {
    final appName = args['app_name'] as String? ?? '';
    if (appName.isEmpty) {
      throw CuaException('open_app', 'app_name 参数不能为空');
    }
    final purpose = args['purpose'] as String?;
    final expectedOutcome = args['expected_outcome'] as String?;
    final taskContext = args['task_context'] as String?;

    // 🎯 输出意图（同时显示在控制台和对话框）
    final intentText = StringBuffer();
    intentText.writeln('🎯 意图: 打开应用');
    intentText.writeln('   应用: $appName');
    if (purpose != null && purpose.isNotEmpty) {
      intentText.writeln('   目的: $purpose');
    }
    debugPrint(intentText.toString().trim());

    debugPrint('🖥️ CUA open_app: $appName');

    if (Platform.isMacOS) {
      await _openAppMacOS(appName);
    } else if (Platform.isWindows) {
      await _openAppWindows(appName);
    } else if (Platform.isLinux) {
      await _openAppLinux(appName);
    }

    // 打开应用后自适应等待（应用启动较慢）并截图确认（支持智能分析）
    final confirmResult = await _waitForChangeAndScreenshot(
      'open_app',
      expectedOutcome: expectedOutcome,
      taskContext: taskContext,
    );
    final confirmInfo = _formatConfirmResult(confirmResult);
    final resultText = StringBuffer();
    resultText.writeln(intentText.toString().trim());
    resultText.writeln('');
    resultText.writeln('✅ 已打开应用: $appName$confirmInfo');
    return SkillResult.ok(
      resultText.toString().trim(),
      data: {
        ...?confirmResult,
        'intent': '打开应用: $appName',
        'result': '应用已启动',
      },
    );
  }

  // ─── wait action: 主动等待页面/应用加载 ───

  /// 等待指定秒数，期间监测屏幕变化，页面稳定后立即截图返回
  /// 解决：操作后程序加载慢，Brain 截图时还没加载完导致误判
  Future<SkillResult> _waitAction(Map<String, dynamic> args) async {
    final durationSec = (args['duration'] as num?)?.toInt() ?? 2;
    final clampedDuration = durationSec.clamp(1, 10);

    debugPrint('⏳ CUA wait: 等待 ${clampedDuration}s，期间监测屏幕变化...');

    // 先拿一张基准截图
    final baseShot = await _quickScreenshot();

    // 等待指定时长，同时监测屏幕是否稳定
    final deadline = DateTime.now().add(Duration(seconds: clampedDuration));
    const checkInterval = Duration(milliseconds: 500);
    var previousShot = baseShot;
    var stableCount = 0;
    const stableThreshold = 2; // 连续 2 次稳定才认为加载完成

    while (DateTime.now().isBefore(deadline)) {
      await Future.delayed(checkInterval);
      final currentShot = await _quickScreenshot();
      if (currentShot == null || previousShot == null) continue;

      final similarity = _computeScreenshotSimilarity(previousShot, currentShot);
      debugPrint('⏳ wait 稳定检测: similarity=${similarity.toStringAsFixed(2)} stableCount=$stableCount');

      if (similarity > 0.97) {
        stableCount++;
        if (stableCount >= stableThreshold) {
          debugPrint('✅ 页面已稳定（等待了 ${DateTime.now().difference(deadline.subtract(Duration(seconds: clampedDuration))).inMilliseconds}ms）');
          break;
        }
      } else {
        stableCount = 0; // 还在变化，重置计数
      }
      previousShot = currentShot;
    }

    // 截图返回
    final confirmResult = await _takeScreenshotForConfirm();
    if (confirmResult != null) {
      _lastScreenshotBase64 = confirmResult['base64'] as String?;
    }
    final confirmInfo = _formatConfirmResult(confirmResult);

    return SkillResult.ok(
      '⏳ 已等待加载（最长 ${clampedDuration}s，页面稳定后截图）$confirmInfo',
      data: {
        ...?confirmResult,
        'intent': '等待页面加载 ${clampedDuration}s',
        'result': '等待完成，已截图',
      },
    );
  }

  Future<void> _openAppMacOS(String appName) async {
    // 如果是 .app 路径，直接用 open 命令
    if (appName.endsWith('.app')) {
      final result = await Process.run('open', ['-a', appName]);
      if (result.exitCode != 0) {
        throw CuaException('open_app', '打开应用失败: ${result.stderr}');
      }
      return;
    }

    // 尝试按应用名打开（open -a 支持中文名如 "微信"）
    var result = await Process.run('open', ['-a', appName]);
    if (result.exitCode == 0) return;

    // 回退：在 /Applications 中模糊匹配
    final grepPattern = appName.replaceAll(RegExp(r'[&|;<>()`]'), '');
    final bashScript = 'app=\$(ls /Applications/ | grep -i "$grepPattern" | head -1); '
        'if [ -n "\$app" ]; then open "/Applications/\$app"; else exit 1; fi';
    result = await Process.run('bash', ['-c', bashScript]);
    if (result.exitCode != 0) {
      throw CuaException('open_app',
          '未找到应用 "$appName"。\n'
          '请确认应用名称正确，或提供完整路径（如 /Applications/WeChat.app）');
    }
  }

  Future<void> _openAppWindows(String appName) async {
    // 如果是完整路径，直接启动
    if (appName.contains('\\') || appName.contains('/')) {
      final result = await Process.run('cmd', ['/c', 'start', '', appName]);
      if (result.exitCode != 0) {
        throw CuaException('open_app', '打开应用失败: ${result.stderr}');
      }
      return;
    }
    // 否则尝试 start 命令
    final result = await Process.run('cmd', ['/c', 'start', '', appName]);
    if (result.exitCode != 0) {
      throw CuaException('open_app', '未找到应用 "$appName"');
    }
  }

  Future<void> _openAppLinux(String appName) async {
    final bashScript =
        'which "$appName" > /dev/null 2>&1 && nohup "$appName" & '
        '|| (which gtk-launch > /dev/null 2>&1 && gtk-launch "$appName" & '
        '|| (which xdg-open > /dev/null 2>&1 && nohup xdg-open "\$(which "$appName" 2>/dev/null || echo "$appName")" &))';
    final result = await Process.run('bash', ['-c', bashScript]);
    if (result.exitCode != 0) {
      throw CuaException('open_app', '未找到应用 "$appName"');
    }
  }

  // ═══════════════════════════════════════════
  // 键盘操作
  // ═══════════════════════════════════════════

  Future<SkillResult> _keyType(Map<String, dynamic> args) async {
    final text = args['text'] as String? ?? '';
    if (text.isEmpty) {
      throw CuaException('key_type', 'text 参数不能为空');
    }
    final purpose = args['purpose'] as String?;
    final expectedOutcome = args['expected_outcome'] as String?;
    final taskContext = args['task_context'] as String?;

    // 🎯 输出意图（同时显示在控制台和对话框）
    final displayText = text.length > 50 ? '${text.substring(0, 50)}...' : text;
    final intentText = StringBuffer();
    intentText.writeln('🎯 意图: 输入文本');
    intentText.writeln('   内容: "$displayText"');
    if (purpose != null && purpose.isNotEmpty) {
      intentText.writeln('   目的: $purpose');
    }
    debugPrint(intentText.toString().trim());

    debugPrint('🖥️ CUA key_type: "${text.length > 50 ? '${text.substring(0, 50)}...' : text}"');

    if (Platform.isMacOS) {
      // 短暂延迟确保目标窗口（如 Spotlight）已准备好接收输入
      await Future.delayed(const Duration(milliseconds: 150));

      // 检查文本是否包含非 ASCII 字符（中文等）
      final hasNonAscii = text.runes.any((r) => r > 127);

      if (hasNonAscii) {
        // 非 ASCII 文本（中文等）使用剪贴板 + Cmd+V 粘贴，更可靠
        // 逐字符 CGEvent 对 Spotlight 等系统 UI 和中文输入法不友好
        debugPrint('🖥️ CUA clipboard key_type (non-ASCII): "${text.length > 50 ? '${text.substring(0, 50)}...' : text}"');
        try {
          // 保存当前剪贴板内容
          final savedClip = await Process.run('pbpaste', []);
          final savedText = savedClip.stdout.toString();

          // 写入新文本到剪贴板
          final proc = await Process.start('pbcopy', []);
          proc.stdin.write(text);
          await proc.stdin.close();
          await proc.exitCode;

          await Future.delayed(const Duration(milliseconds: 50));

          // 发送 Cmd+V 粘贴
          _MacOSNative.postKeyCombo(9 /* v */, _kCGEventFlagMaskCommand);
          await Future.delayed(const Duration(milliseconds: 200));

          // 恢复原始剪贴板内容
          final restoreProc = await Process.start('pbcopy', []);
          restoreProc.stdin.write(savedText);
          await restoreProc.stdin.close();
          await restoreProc.exitCode;
        } on StateError {
          throw CuaException('key_type',
              '辅助功能权限不足。请在 系统设置 → 隐私与安全性 → 辅助功能 中勾选鹅宝，然后重启应用。');
        } catch (e) {
          debugPrint('⚠️ CUA clipboard key_type 失败: $e');
          throw CuaException('key_type', '文本输入失败: $e');
        }
      } else {
        // ASCII 文本使用原生 CGEvent 逐字符输入
        try {
          debugPrint('🖥️ CUA CGEvent key_type: "${text.length > 50 ? '${text.substring(0, 50)}...' : text}"');
          _MacOSNative.postUnicodeText(text);
        } on StateError {
          throw CuaException('key_type',
              '辅助功能权限不足。请在 系统设置 → 隐私与安全性 → 辅助功能 中勾选鹅宝，然后重启应用。');
        } catch (e) {
          debugPrint('⚠️ CUA CGEvent key_type 失败: $e，回退到 cliclick');
          // 回退到 cliclick
          final cliclick = await _findCliclick();
          if (cliclick == null) {
            throw CuaException('key_type', 'cliclick 未安装。请运行: brew install cliclick');
          }
          final result = await Process.run(cliclick, ['t:$text']);
          if (result.exitCode != 0) {
            throw CuaException('key_type',
                'cliclick 未安装或执行失败。请运行: brew install cliclick');
          }
        }
      }
    } else if (Platform.isWindows) {
      // 优先使用剪贴板 + Ctrl+V 粘贴（兼容 UWP 应用和中文输入）
      try {
        // 使用 PowerShell SetClipboard + SendInput Ctrl+V
        final textForPs = text.replaceAll("'", "''"); // 转义单引号
        final psScript = r'''
Add-Type @"
using System;
using System.Runtime.InteropServices;
public class WinKeyInput {
    [StructLayout(LayoutKind.Sequential)]
    struct INPUT {
        public uint type;
        public KEYBDINPUT ki;
    }
    [StructLayout(LayoutKind.Sequential)]
    struct KEYBDINPUT {
        public ushort wVk;
        public ushort wScan;
        public uint dwFlags;
        public uint time;
        public IntPtr dwExtraInfo;
    }
    [DllImport("user32.dll", SetLastError = true)]
    static extern uint SendInput(uint nInputs, INPUT[] pInputs, int cbSize);

    public static void KeyCombo(ushort vkDown, ushort vkUp) {
        INPUT[] inputs = new INPUT[4];
        inputs[0].type = 1; inputs[0].ki.wVk = 0x11; inputs[0].ki.dwFlags = 0; // Ctrl down
        inputs[1].type = 1; inputs[1].ki.wVk = vkDown; inputs[1].ki.dwFlags = 0; // V down
        inputs[2].type = 1; inputs[2].ki.wVk = vkUp; inputs[2].ki.dwFlags = 2; // V up
        inputs[3].type = 1; inputs[3].ki.wVk = 0x11; inputs[3].ki.dwFlags = 2; // Ctrl up
        SendInput(4, inputs, Marshal.SizeOf(typeof(INPUT)));
    }
}
"@ -ErrorAction SilentlyContinue
try {
    Add-Type -AssemblyName System.Windows.Forms
    [System.Windows.Forms.Clipboard]::SetText(''' + textForPs + r''')
    [WinKeyInput]::KeyCombo(0x56, 0x56)
} catch {
    Write-Error $_.Exception.Message
}
''';
        final result = await Process.run('powershell', ['-NoProfile', '-Command', psScript]);
        if (result.exitCode != 0) {
          // 回退到 SendKeys
          debugPrint('⚠️ Windows SendInput 粘贴失败，回退到 SendKeys');
          final escaped = text
              .replaceAll('{', '{{}')
              .replaceAll('}', '}}')
              .replaceAll('+', '{+}')
              .replaceAll('^', '{^}')
              .replaceAll('~', '{~}')
              .replaceAll('(', '{(}')
              .replaceAll(')', '{)}');
          await Process.run('powershell', ['-NoProfile', '-Command', '[System.Windows.Forms.SendKeys]::SendWait("$escaped")']);
        }
      } catch (e) {
        throw CuaException('key_type', 'Windows 文本输入失败: $e');
      }
    } else if (Platform.isLinux) {
      await Process.run('xdotool', ['type', '--clearmodifiers', text]);
    }

    // 操作后自适应等待并截图确认（支持智能分析）
    final confirmResult = await _waitForChangeAndScreenshot(
      'key_type',
      expectedOutcome: expectedOutcome,
      taskContext: taskContext,
    );
    final confirmInfo = _formatConfirmResult(confirmResult);
    final resultText = StringBuffer();
    resultText.writeln(intentText.toString().trim());
    resultText.writeln('');
    resultText.writeln('✅ 文本输入完成 (${text.length} 字符)$confirmInfo');
    return SkillResult.ok(
      resultText.toString().trim(),
      data: {
        ...?confirmResult,
        'intent': '输入文本: $displayText',
        'result': '输入完成 (${text.length} 字符)',
      },
    );
  }

  Future<SkillResult> _keyCombo(Map<String, dynamic> args) async {
    final keys = args['keys'] as String? ?? '';
    if (keys.isEmpty) {
      throw CuaException('key_combo', 'keys 参数不能为空');
    }
    final purpose = args['purpose'] as String?;
    final expectedOutcome = args['expected_outcome'] as String?;
    final taskContext = args['task_context'] as String?;

    // 🎯 输出意图（同时显示在控制台和对话框）
    final intentText = StringBuffer();
    intentText.writeln('🎯 意图: 执行快捷键');
    intentText.writeln('   按键: $keys');
    if (purpose != null && purpose.isNotEmpty) {
      intentText.writeln('   目的: $purpose');
    }
    debugPrint(intentText.toString().trim());

    debugPrint('🖥️ CUA key_combo: $keys');

    if (Platform.isMacOS) {
      await _keyComboMacOS(keys);
    } else if (Platform.isWindows) {
      await _keyComboWindows(keys);
    } else if (Platform.isLinux) {
      await _keyComboLinux(keys);
    }

    // 操作后自适应等待并截图确认（支持智能分析）
    final confirmResult = await _waitForChangeAndScreenshot(
      'key_combo',
      expectedOutcome: expectedOutcome,
      taskContext: taskContext,
    );
    final confirmInfo = _formatConfirmResult(confirmResult);
    final resultText = StringBuffer();
    resultText.writeln(intentText.toString().trim());
    resultText.writeln('');
    resultText.writeln('✅ 快捷键执行成功: $keys$confirmInfo');
    return SkillResult.ok(
      resultText.toString().trim(),
      data: {
        ...?confirmResult,
        'intent': '执行快捷键: $keys',
        'result': '快捷键已执行',
      },
    );
  }

  Future<void> _keyComboMacOS(String keys) async {
    // 优先使用原生 CGEvent API（进程内执行，仅需应用自身有辅助功能权限）
    try {
      final mainKey = _parseMainKey(keys);
      final modifiers = _parseModifierKeys(keys);
      final flags = _parseModifiers(modifiers);
      final keyCode = _macKeyCodeMap[mainKey];
      if (keyCode == null) {
        debugPrint('⚠️ CUA CGEvent: 未知键 $mainKey，回退到 cliclick');
        await _keyComboCliclickFallback(keys);
        return;
      }
      debugPrint('🖥️ CUA CGEvent key_combo: $keys → keyCode=$keyCode flags=$flags');
      _MacOSNative.postKeyCombo(keyCode, flags);
      return;
    } on StateError catch (e) {
      // 缺少辅助功能权限
      throw CuaException('key_combo',
          '辅助功能权限不足，CGEvent 无法发送键盘事件。\n'
          '请在 系统设置 → 隐私与安全性 → 辅助功能 中勾选鹅宝，然后重启应用。\n'
          '详细: ${e.message}');
    } catch (e) {
      debugPrint('⚠️ CUA CGEvent key_combo 失败: $e，回退到 cliclick');
    }
    // 回退到 cliclick
    await _keyComboCliclickFallback(keys);
  }

  Future<void> _keyComboCliclickFallback(String keys) async {
    final parts = keys.toLowerCase().split('+');
    final modifiers = <String>[];
    final mainKey = parts.last;

    for (var i = 0; i < parts.length - 1; i++) {
      switch (parts[i].trim()) {
        case 'cmd': case 'command': modifiers.add('command'); break;
        case 'shift': modifiers.add('shift'); break;
        case 'alt': case 'option': modifiers.add('option'); break;
        case 'ctrl': case 'control': modifiers.add('control'); break;
        case 'fn': modifiers.add('fn'); break;
      }
    }

    if (modifiers.isNotEmpty) {
      final downCmd = modifiers.map((m) => 'kd:$m').join(' ');
      final upCmd = modifiers.map((m) => 'ku:$m').join(' ');
      final cmd = '$downCmd kp:$mainKey $upCmd';
      final result = await _runCliclickBash(cmd);
      if (result.exitCode != 0) {
        await _keyComboAppleScript(keys);
      }
    } else {
      final result = await _runCliclickBash('kp:$mainKey');
      if (result.exitCode != 0) {
        throw CuaException('key_combo',
            'cliclick 未安装或执行失败。请运行: brew install cliclick');
      }
    }
  }

  Future<void> _keyComboAppleScript(String keys) async {
    // AppleScript 的 key code 映射
    final parts = keys.toLowerCase().split('+');
    final modifiers = <String>[];
    final mainKey = parts.last;

    for (var i = 0; i < parts.length - 1; i++) {
      switch (parts[i].trim()) {
        case 'cmd': case 'command': modifiers.add('command down'); break;
        case 'shift': modifiers.add('shift down'); break;
        case 'alt': case 'option': modifiers.add('option down'); break;
        case 'ctrl': case 'control': modifiers.add('control down'); break;
      }
    }

    final keyMap = {
      'a': 0, 'b': 11, 'c': 8, 'd': 2, 'e': 14, 'f': 3, 'g': 5, 'h': 4,
      'i': 34, 'j': 38, 'k': 40, 'l': 37, 'm': 46, 'n': 45, 'o': 31,
      'p': 35, 'q': 12, 'r': 15, 's': 1, 't': 17, 'u': 32, 'v': 9,
      'w': 13, 'x': 7, 'y': 16, 'z': 6,
      '0': 29, '1': 18, '2': 19, '3': 20, '4': 21, '5': 23,
      '6': 22, '7': 26, '8': 28, '9': 25,
      'return': 36, 'enter': 36, 'tab': 48, 'space': 49, 'delete': 51,
      'escape': 53, 'esc': 53, 'f1': 122, 'f2': 120, 'f3': 99, 'f4': 118,
      'f5': 96, 'f6': 97, 'f7': 98, 'f8': 100, 'f9': 101, 'f10': 109,
      'f11': 103, 'f12': 111, 'up': 126, 'down': 125, 'left': 123, 'right': 124,
      'home': 115, 'end': 119, 'pageup': 116, 'pagedown': 121,
    };

    final keyCode = keyMap[mainKey] ?? 0;
    final usingStr = modifiers.isEmpty ? '' : 'using {${modifiers.join(', ')}}';

    final script = '''
tell application "System Events"
  key code $keyCode $usingStr
end tell
''';
    final result = await Process.run('osascript', ['-e', script]);
    if (result.exitCode != 0) {
      final errMsg = result.stderr?.toString() ?? '';
      if (errMsg.contains('不允许') || errMsg.contains('not allowed') || errMsg.contains('1002')) {
        throw CuaException('key_combo',
            '辅助功能权限不足 (错误 1002)。\n'
            '请在 系统设置 → 隐私与安全性 → 辅助功能 中确认以下项目均已勾选：\n'
            '1. 鹅宝（GooseBaby）\n'
            '2. /opt/homebrew/bin/cliclick（如果通过 Homebrew 安装）\n'
            '3. osascript（/usr/bin/osascript）\n'
            '修改权限后需要 完全退出并重新启动 鹅宝。');
      }
      throw CuaException('key_combo', 'AppleScript 快捷键失败: $errMsg');
    }
  }

  Future<void> _keyComboWindows(String keys) async {
    // 使用 user32.dll SendInput API（兼容 UWP 应用）
    // Virtual Key Codes: https://learn.microsoft.com/en-us/windows/win32/inputdev/virtual-key-codes
    final vkMap = {
      'ctrl': 0x11, 'shift': 0x10, 'alt': 0x12, 'win': 0x5B,
      'tab': 0x09, 'enter': 0x0D, 'return': 0x0D,
      'escape': 0x1B, 'esc': 0x1B, 'backspace': 0x08, 'delete': 0x2E,
      'home': 0x24, 'end': 0x23, 'pageup': 0x21, 'pagedown': 0x22,
      'up': 0x26, 'down': 0x28, 'left': 0x25, 'right': 0x27,
      'space': 0x20,
      'f1': 0x70, 'f2': 0x71, 'f3': 0x72, 'f4': 0x73,
      'f5': 0x74, 'f6': 0x75, 'f7': 0x76, 'f8': 0x77,
      'f9': 0x78, 'f10': 0x79, 'f11': 0x7A, 'f12': 0x7B,
      'insert': 0x2D, 'printscreen': 0x2C, 'scrolllock': 0x91,
      'numlock': 0x90, 'capslock': 0x14, 'pause': 0x13,
    };

    final parts = keys.toLowerCase().split('+');
    final vkCodes = <int>[];
    for (final p in parts) {
      final trimmed = p.trim();
      if (vkMap.containsKey(trimmed)) {
        vkCodes.add(vkMap[trimmed]!);
      } else if (trimmed.length == 1) {
        // 单字符 → VK code (A=0x41, 0=0x30, etc.)
        final code = trimmed.toUpperCase().codeUnitAt(0);
        if (code >= 0x30 && code <= 0x5A) {
          vkCodes.add(code);
        } else {
          vkCodes.add(code);
        }
      } else {
        vkCodes.add(trimmed.toUpperCase().codeUnitAt(0));
      }
    }

    if (vkCodes.isEmpty) return;

    // 构建 SendInput 脚本
    // 输入序列: modifier_down ... key_down key_up ... modifier_up
    final vkList = vkCodes.join(',');
    final psScript = r'''
Add-Type @"
using System;
using System.Runtime.InteropServices;
public class WinKeyCombo {
    [StructLayout(LayoutKind.Sequential)]
    struct INPUT { public uint type; public KEYBDINPUT ki; }
    [StructLayout(LayoutKind.Sequential)]
    struct KEYBDINPUT { public ushort wVk; public ushort wScan; public uint dwFlags; public uint time; public IntPtr dwExtraInfo; }
    [DllImport("user32.dll", SetLastError = true)]
    static extern uint SendInput(uint nInputs, INPUT[] pInputs, int cbSize);

    public static void SendCombo(int[] vkCodes) {
        // 按下顺序: 所有键 down
        // 释放顺序: 所有键 up（逆序）
        int n = vkCodes.Length;
        INPUT[] inputs = new INPUT[n * 2];
        for (int i = 0; i < n; i++) {
            inputs[i].type = 1;
            inputs[i].ki.wVk = (ushort)vkCodes[i];
            inputs[i].ki.dwFlags = 0; // key down
        }
        for (int i = 0; i < n; i++) {
            inputs[n + i].type = 1;
            inputs[n + i].ki.wVk = (ushort)vkCodes[n - 1 - i];
            inputs[n + i].ki.dwFlags = 2; // key up
        }
        SendInput((uint)(n * 2), inputs, Marshal.SizeOf(typeof(INPUT)));
    }
}
"@ -ErrorAction SilentlyContinue
[WinKeyCombo]::SendCombo(@(VK_LIST))
'''.replaceAll('VK_LIST', vkList);

    final result = await Process.run('powershell', ['-NoProfile', '-Command', psScript]);
    if (result.exitCode != 0) {
      // 回退到 SendKeys
      debugPrint('⚠️ Windows SendInput 快捷键失败，回退到 SendKeys');
      final sendKeysMap = {
        'ctrl': '^', 'shift': '+', 'alt': '%',
        'tab': '{TAB}', 'enter': '{ENTER}', 'return': '{ENTER}',
        'escape': '{ESC}', 'esc': '{ESC}', 'backspace': '{BS}', 'delete': '{DEL}',
        'up': '{UP}', 'down': '{DOWN}', 'left': '{LEFT}', 'right': '{RIGHT}',
      };
      final sendKeys = parts.map((p) => sendKeysMap[p.trim()] ?? p.trim().toUpperCase()).join('');
      await Process.run('powershell', ['-NoProfile', '-Command', '[System.Windows.Forms.SendKeys]::SendWait("$sendKeys")']);
    }
  }

  Future<void> _keyComboLinux(String keys) async {
    // xdotool key 支持 --clearmodifiers
    final keyMap = {
      'ctrl': 'ctrl', 'shift': 'shift', 'alt': 'alt', 'super': 'super',
      'cmd': 'ctrl', 'command': 'ctrl', // Linux 上 cmd → ctrl
      'tab': 'Tab', 'enter': 'Return', 'return': 'Return',
      'escape': 'Escape', 'esc': 'Escape', 'backspace': 'BackSpace', 'delete': 'Delete',
      'home': 'Home', 'end': 'End', 'pageup': 'Page_Up', 'pagedown': 'Page_Down',
      'up': 'Up', 'down': 'Down', 'left': 'Left', 'right': 'Right',
      'space': 'space', 'f1': 'F1', 'f2': 'F2', 'f3': 'F3', 'f4': 'F4',
      'f5': 'F5', 'f6': 'F6', 'f7': 'F7', 'f8': 'F8',
      'f9': 'F9', 'f10': 'F10', 'f11': 'F11', 'f12': 'F12',
    };

    final parts = keys.toLowerCase().split('+');
    final xdotoolKeys = parts.map((p) => keyMap[p.trim()] ?? p.trim().toUpperCase()).join('+');

    await Process.run('xdotool', ['key', '--clearmodifiers', xdotoolKeys]);
  }

  // ═══════════════════════════════════════════
  // UI 树解析（优化1）
  // ═══════════════════════════════════════════

  

  // ═══════════════════════════════════════════
  // 任务管理（优化6+8）
  // ═══════════════════════════════════════════

  Future<SkillResult> _getHistory() async {
    debugPrint('📋 CUA get_history');

    try {
      final tasks = await CuaTaskRecorder.listTasks(limit: 10);

      if (tasks.isEmpty) {
        return SkillResult.ok('📋 暂无历史操作记录。');
      }

      final buffer = StringBuffer();
      buffer.writeln('📋 最近 ${tasks.length} 个 CUA 任务：\n');

      for (var i = 0; i < tasks.length; i++) {
        final t = tasks[i];
        final statusIcon = t.status == 'completed' ? '✅'
            : t.status == 'running' ? '🔄'
            : t.status == 'paused' ? '⏸️'
            : '❌';
        buffer.writeln('$statusIcon ${i + 1}. ${t.description}');
        buffer.writeln('   ID: ${t.taskId}');
        buffer.writeln('   操作数: ${t.operationCount} (成功${t.successCount}/失败${t.failCount})');
        buffer.writeln('   耗时: ${t.duration.inSeconds}秒');
        buffer.writeln('   状态: ${t.status}');
        buffer.writeln();
      }

      buffer.writeln('💡 使用 resume_task + task_id 恢复任务');
      buffer.writeln('💡 使用 export_task + task_id 导出详细报告');

      return SkillResult.ok(buffer.toString());
    } catch (e) {
      return SkillResult.ok('📋 查看历史记录失败: $e');
    }
  }

  Future<SkillResult> _resumeTask(Map<String, dynamic> args) async {
    final taskId = args['task_id'] as String? ?? '';
    if (taskId.isEmpty) {
      return SkillResult.fail('resume_task 需要 task_id 参数。使用 get_history 查看可用任务。');
    }

    debugPrint('🔄 CUA resume_task: $taskId');

    try {
      final task = await CuaTaskRecorder.loadTask(taskId);
      if (task == null) {
        return SkillResult.fail('未找到任务 $taskId。使用 get_history 查看可用任务。');
      }

      final context = CuaTaskRecorder.buildResumeContext(task);
      _currentTask = task;
      task.status = 'running';

      return SkillResult.ok(context, data: {
        'taskId': task.taskId,
        'operationCount': task.operationCount,
        'description': task.description,
      });
    } catch (e) {
      return SkillResult.fail('恢复任务失败: $e');
    }
  }

  Future<SkillResult> _exportTask(Map<String, dynamic> args) async {
    final taskId = args['task_id'] as String? ?? '';
    if (taskId.isEmpty) {
      // 如果没有指定 task_id，导出当前任务
      final task = _currentTask;
      if (task == null) {
        return SkillResult.fail('export_task 需要 task_id 参数。使用 get_history 查看可用任务。');
      }
      final markdown = CuaTaskRecorder.exportToMarkdown(task);
      final reportPath = p.join(
        SkillFileUtils.effectiveWorkingDir,
        'cua_report_${task.taskId}.md',
      );
      await File(reportPath).writeAsString(markdown);
      return SkillResult.ok(
        '✅ 操作报告已导出到: $reportPath\n   共 ${task.operationCount} 步操作',
        data: {'filePath': reportPath},
      );
    }

    debugPrint('📄 CUA export_task: $taskId');

    try {
      final task = await CuaTaskRecorder.loadTask(taskId);
      if (task == null) {
        return SkillResult.fail('未找到任务 $taskId。');
      }

      final markdown = CuaTaskRecorder.exportToMarkdown(task);
      final reportPath = p.join(
        SkillFileUtils.effectiveWorkingDir,
        'cua_report_${taskId}.md',
      );
      await File(reportPath).writeAsString(markdown);

      return SkillResult.ok(
        '✅ 操作报告已导出到: $reportPath\n'
        '   任务: ${task.description}\n'
        '   操作数: ${task.operationCount} (成功${task.successCount}/失败${task.failCount})\n'
        '   总耗时: ${task.duration.inSeconds}秒',
        data: {'filePath': reportPath},
      );
    } catch (e) {
      return SkillResult.fail('导出报告失败: $e');
    }
  }

  // ═══════════════════════════════════════════
  // Planner 子任务分解
  // ═══════════════════════════════════════════

  /// 子任务变更通知回调（UI 层注册，用于实时刷新时间线面板）
  static void Function(CuaTask)? onSubTaskChanged;

  /// Planner：将复杂任务分解为子任务步骤
  Future<SkillResult> _cuaPlan(Map<String, dynamic> args) async {
    final subtasksRaw = args['subtasks'];
    if (subtasksRaw == null) {
      return SkillResult.fail('cua_plan 需要 subtasks 参数。'
          '格式: JSON 数组 [{"description": "步骤1"}, {"description": "步骤2"}]');
    }

    final List<dynamic> subtaskList;
    try {
      if (subtasksRaw is String) {
        subtaskList = jsonDecode(subtasksRaw) as List;
      } else if (subtasksRaw is List) {
        subtaskList = subtasksRaw;
      } else {
        return SkillResult.fail('subtasks 格式错误，需要 JSON 数组或字符串。');
      }
    } catch (e) {
      return SkillResult.fail('subtasks JSON 解析失败: $e');
    }

    if (subtaskList.isEmpty) {
      return SkillResult.fail('subtasks 不能为空，至少需要一个子任务。');
    }

    // 确保当前任务存在
    final task = _ensureTask('cua_plan', args);

    // 清除之前的子任务（允许重新规划）
    task.subTasks.clear();

    // 创建子任务
    for (var i = 0; i < subtaskList.length; i++) {
      final item = subtaskList[i] as Map;
      final desc = item['description'] as String? ?? '步骤 ${i + 1}';
      task.subTasks.add(CuaSubTask(
        id: 'sub_${task.taskId}_${i + 1}',
        order: i + 1,
        description: desc,
      ));
    }

    // 自动保存
    await CuaTaskRecorder.saveTask(task);

    // 通知 UI 刷新
    onSubTaskChanged?.call(task);

    final buffer = StringBuffer();
    buffer.writeln('✅ 任务已分解为 ${subtaskList.length} 个子任务：\n');
    for (var i = 0; i < task.subTasks.length; i++) {
      final sub = task.subTasks[i];
      buffer.writeln('  ${i + 1}. [${sub.id}] ${sub.description}');
    }
    buffer.writeln('\n💡 请按顺序执行子任务，每开始一个子任务时调用 set_subtask_status 设置状态为 running，'
        '完成后设置为 completed。');

    return SkillResult.ok(buffer.toString(), data: {
      'subtaskCount': task.subTasks.length,
      'subtasks': task.subTasks.map((s) => {'id': s.id, 'order': s.order, 'description': s.description}).toList(),
    });
  }

  /// 更新子任务状态
  Future<SkillResult> _setSubTaskStatus(Map<String, dynamic> args) async {
    final subtaskId = args['subtask_id'] as String? ?? '';
    final newStatus = args['subtask_status'] as String? ?? '';

    if (subtaskId.isEmpty) {
      return SkillResult.fail('set_subtask_status 需要 subtask_id 参数。从 cua_plan 返回结果中获取。');
    }
    if (newStatus.isEmpty || !const ['running', 'completed', 'failed', 'skipped'].contains(newStatus)) {
      return SkillResult.fail('subtask_status 必须是: running, completed, failed, skipped');
    }

    final task = _currentTask;
    if (task == null) {
      return SkillResult.fail('当前没有活跃的 CUA 任务。请先执行 CUA 操作。');
    }

    // 查找目标子任务
    CuaSubTask? target;
    for (final sub in task.subTasks) {
      if (sub.id == subtaskId) {
        target = sub;
        break;
      }
    }

    if (target == null) {
      return SkillResult.fail('未找到子任务 $subtaskId。请检查 subtask_id 是否正确。');
    }

    final oldStatus = target.status;
    target.status = newStatus;

    // 根据状态更新操作索引
    if (newStatus == 'running') {
      target.startOperationIndex = task.operationCount;
      target.endOperationIndex = null;
    } else if (newStatus == 'completed' || newStatus == 'failed' || newStatus == 'skipped') {
      target.endOperationIndex = task.operationCount;
    }

    // 自动保存
    await CuaTaskRecorder.saveTask(task);

    // 通知 UI 刷新
    onSubTaskChanged?.call(task);

    return SkillResult.ok(
      '✅ 子任务状态已更新: "${target.description}" $oldStatus → $newStatus\n'
      '   当前进度: ${task.subTaskProgress * 100}% (${task.subTasks.where((t) => t.status == 'completed' || t.status == 'skipped').length}/${task.subTasks.length})',
    );
  }
}

/// CUA 异常
class CuaException implements Exception {
  final String action;
  final String message;

  CuaException(this.action, this.message);

  @override
  String toString() => 'CuaException[$action]: $message';
}
