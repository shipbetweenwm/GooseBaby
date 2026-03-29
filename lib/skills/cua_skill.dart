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
import 'package:ffi/ffi.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:path/path.dart' as p;
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

typedef CGEventKeyboardSetUnicodeStringNat = Void Function(Pointer<Void>, Uint16, Pointer<Void>);
typedef CGEventKeyboardSetUnicodeStringDart = void Function(Pointer<Void>, int, Pointer<Void>);

// CGEventSetString — CGEventKeyboardSetUnicodeString 的现代替代 (macOS 10.11+)
// 接受 CFStringRef (const char*)，比手动构造 UTF-16 buffer 更可靠
typedef CGEventSetStringNat = Void Function(Pointer<Void>, Pointer<Void>);
typedef CGEventSetStringDart = void Function(Pointer<Void>, Pointer<Void>);

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

  static CGEventKeyboardSetUnicodeStringDart get _cgEventKeyboardSetUnicodeString =>
      lib.lookupFunction<CGEventKeyboardSetUnicodeStringNat, CGEventKeyboardSetUnicodeStringDart>('CGEventKeyboardSetUnicodeString');

  static CGEventSetStringDart get _cgEventSetString =>
      lib.lookupFunction<CGEventSetStringNat, CGEventSetStringDart>('CGEventSetString');

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

/// CUA 技能 — 视觉感知 + 操作模拟
class CuaSkill extends GooseSkill {
  /// 缓存 cliclick 可执行文件路径（macOS GUI 应用的 PATH 可能不包含 /opt/homebrew/bin）
  static String? _cliclickPath;

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

  /// 将归一化坐标 (0~1000) 转换为屏幕像素坐标
  /// 自动 clamp 超出范围的值并输出警告
  static int _normalizedToPixel(int normalized, int screenSize, [String? hint]) {
    if (normalized < 0 || normalized > 1000) {
      debugPrint('⚠️ CUA 坐标越界: ${hint != null ? "$hint " : ""}$normalized 超出 0~1000 范围，自动 clamp');
      normalized = normalized.clamp(0, 1000);
    }
    if (normalized <= 0) return 0;
    if (normalized >= 1000) return screenSize;
    return (normalized / 1000 * screenSize).round();
  }

  @override
  String get id => 'cua';

  @override
  String get name => 'CUA 桌面控制';

  @override
  String get description =>
      'Computer Use Agent — 像人一样操作计算机。'
      '通过截图感知屏幕，通过模拟鼠标/键盘操控 UI。'
      '【视觉感知】screenshot: 截取屏幕截图（返回 base64 图片，并自动分析屏幕内容，描述可见的 UI 元素和文字）。'
      '【UI 树解析】get_ui_tree: 通过系统 Accessibility API 读取当前应用的 UI 元素树，基于文本/类型/层级精准定位，无需猜坐标。'
      '【应用操作】open_app: 直接打开应用程序（推荐，比 Spotlight 更快）。'
      '【鼠标操作】mouse_click: 点击指定坐标（操作后自动截图确认）; mouse_move: 移动鼠标; '
      'mouse_scroll: 滚动鼠标（操作后自动截图确认）; mouse_drag: 拖拽操作（操作后自动截图确认）。'
      '【键盘操作】key_type: 输入文本（操作后自动截图确认）; key_combo: 按下快捷键组合（操作后自动截图确认）。'
      '【任务管理】get_history: 查看历史操作记录; resume_task: 恢复中断的任务; export_task: 导出操作报告。'
      '【坐标系统】虚拟坐标 X/Y 0~1000，左上角(0,0)，右下角(1000,1000)。X 对应屏幕宽度，Y 对应屏幕高度，各自独立映射。'
      '【自适应等待】所有操作后根据操作类型自动等待不同时间（点击500ms、滚动200ms、输入后100ms、打开应用2000ms），并在等待后自动截图确认结果。';

  @override
  String get icon => '🖥️';

  @override
  String get category => '内置工具';

  @override
  String get bestPractice =>
      '1. 所有坐标归一化到 0~1000，左上角 (0,0)，右下角 (1000,1000)\n'
      '2. mouse_click/mouse_move/mouse_drag 操作后自动截图确认，无需手动再调 screenshot\n'
      '3. mouse_click 支持 left/right/middle 三种按键\n'
      '4. key_combo 示例: "cmd+c"(复制), "ctrl+shift+i"(开发者工具), "alt+tab"(切换窗口)\n'
      '5. 输入文本前务必先 mouse_click 点击输入框使其获得焦点\n'
      '6. 打开应用优先使用 open_app，比通过 Spotlight 操作更可靠\n'
      '7. get_ui_tree 可补充截图看不清的情况（小文字、低对比度）\n'
      '8. 操作某个应用前，务必先调用 open_app 确保该应用在前台，然后再截图和操作\n'
      '9. 截图后会显示前台应用名称和 SOM 标记数量，如果前台应用不是目标应用，先切换\n';

  @override
  List<SkillParam> get params => [
    const SkillParam(
      name: 'action',
      description: '操作类型:\n'
          '- cua_plan: Planner 子任务分解 — 将复杂任务分解为多个子任务步骤\n'
          '- set_subtask_status: 更新子任务状态（开始/完成/失败/跳过）\n'
          '- screenshot: 截取屏幕截图\n'
          '- get_ui_tree: 读取 UI 元素树（Accessibility API，精准定位）\n'
          '- mouse_click: 鼠标点击（自动截图确认）\n'
          '- mouse_move: 移动鼠标\n'
          '- mouse_scroll: 鼠标滚轮滚动（自动截图确认）\n'
          '- mouse_drag: 鼠标拖拽（自动截图确认）\n'
          '- key_type: 键盘输入文本（自动截图确认）\n'
          '- key_combo: 键盘快捷键组合（自动截图确认）\n'
          '- open_app: 直接打开应用程序（自动截图确认）\n'
          '- get_history: 查看历史操作记录\n'
          '- resume_task: 恢复中断的任务（传入 task_id）\n'
          '- export_task: 导出操作报告（传入 task_id）',
      type: 'enum',
      required: true,
      enumValues: ['cua_plan', 'set_subtask_status', 'screenshot', 'get_ui_tree', 'mouse_click', 'mouse_move', 'mouse_scroll', 'mouse_drag', 'key_type', 'key_combo', 'open_app', 'get_history', 'resume_task', 'export_task'],
    ),
    const SkillParam(
      name: 'x',
      description: 'X 坐标，0~1000（0=最左，1000=最右）。mouse_click/mouse_move/mouse_drag 时必填。',
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
      description: '快捷键组合，用 + 连接。示例: "cmd+c", "ctrl+shift+i", "alt+tab"。仅 key_combo 时必填。',
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
      name: 'app_filter',
      description: '应用过滤名称（仅 get_ui_tree 使用）。只返回匹配此名称的应用 UI 树。',
      type: 'string',
      required: false,
    ),
    const SkillParam(
      name: 'max_depth',
      description: 'UI 树最大解析深度（仅 get_ui_tree 使用，默认 6，最大 10）。',
      type: 'int',
      required: false,
      defaultValue: 6,
    ),
    const SkillParam(
      name: 'task_id',
      description: '任务 ID（仅 resume_task/export_task 使用）。从 get_history 获取。',
      type: 'string',
      required: false,
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
  ];

  @override
  List<SkillExample> get examples => const [
    SkillExample(
      scenario: '截取屏幕观察当前状态',
      argsJson: '{"action": "screenshot"}',
    ),
    SkillExample(
      scenario: '点击屏幕指定位置（归一化坐标）',
      argsJson: '{"action": "mouse_click", "x": 500, "y": 300}',
    ),
    SkillExample(
      scenario: '双击打开文件（屏幕右上方）',
      argsJson: '{"action": "mouse_click", "x": 200, "y": 150, "clicks": 2}',
    ),
    SkillExample(
      scenario: '输入文本到输入框',
      argsJson: '{"action": "key_type", "text": "Hello World"}',
    ),
    SkillExample(
      scenario: '按下 Ctrl+C 复制',
      argsJson: '{"action": "key_combo", "keys": "ctrl+c"}',
    ),
    SkillExample(
      scenario: '直接打开微信应用',
      argsJson: '{"action": "open_app", "app_name": "微信"}',
    ),
    SkillExample(
      scenario: '直接打开 Safari 浏览器',
      argsJson: '{"action": "open_app", "app_name": "Safari"}',
    ),
    SkillExample(
      scenario: '读取当前应用的 UI 元素树（精准定位）',
      argsJson: '{"action": "get_ui_tree"}',
    ),
    SkillExample(
      scenario: '读取指定应用的 UI 元素树',
      argsJson: '{"action": "get_ui_tree", "app_filter": "Safari", "max_depth": 8}',
    ),
    SkillExample(
      scenario: '查看历史操作记录',
      argsJson: '{"action": "get_history"}',
    ),
    SkillExample(
      scenario: '恢复中断的任务',
      argsJson: '{"action": "resume_task", "task_id": "cua_1234567890"}',
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
        case 'screenshot':
          result = await _takeScreenshot(args);
        case 'get_ui_tree':
          result = await _getUiTree(args);
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
        case 'get_history':
          return await _getHistory();
        case 'resume_task':
          return await _resumeTask(args);
        case 'export_task':
          return await _exportTask(args);
        default:
          return SkillResult.fail('未知的 CUA 操作类型: $action。'
              '支持: cua_plan, set_subtask_status, screenshot, get_ui_tree, mouse_click, '
              'mouse_move, mouse_scroll, mouse_drag, key_type, key_combo, open_app, '
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
        return const Duration(milliseconds: 800);
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
    final sampleCount = 200;
    final step = (base64A.length / sampleCount).ceil();
    var matchCount = 0;

    for (var offset = 0; offset < base64A.length && offset < base64B.length; offset += step) {
      if (base64A[offset] == base64B[offset]) matchCount++;
    }

    return matchCount / sampleCount;
  }

  /// 等待 UI 响应后截图确认（所有操作统一调用）
  /// 改进：对高延迟操作进行截图变化检测，屏幕稳定后再截图
  Future<Map<String, dynamic>?> _waitForChangeAndScreenshot(String action) async {
    final baseWait = _adaptiveWaitForAction(action);
    await Future.delayed(baseWait);

    // 对高延迟操作，进行变化检测：等待屏幕稳定
    if (_needsChangeDetection(action) && _lastScreenshotBase64 != null) {
      final maxRetries = 5;
      final retryInterval = const Duration(milliseconds: 200);

      for (var attempt = 0; attempt < maxRetries; attempt++) {
        // 快速截图（不保存文件，只获取 base64）
        final quickShot = await _quickScreenshot();
        if (quickShot == null) break;

        final similarity = _computeScreenshotSimilarity(_lastScreenshotBase64!, quickShot);
        debugPrint('🔍 变化检测: attempt=$attempt similarity=${similarity.toStringAsFixed(2)}');

        if (similarity < 0.95) {
          // 屏幕已变化，等待一小段时间让动画完成
          await Future.delayed(const Duration(milliseconds: 200));
          break;
        }

        // 屏幕未变化，继续等待
        if (attempt < maxRetries - 1) {
          await Future.delayed(retryInterval);
        }
      }
    }

    final result = await _takeScreenshotForConfirm();
    if (result != null) {
      _lastScreenshotBase64 = result['base64'] as String?;
    }
    return result;
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
      case 'get_ui_tree':
        return 'CUA UI 树分析';
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

  /// 最近一次截图时的前台应用名称（由 _drawSomOnPng 设置）
  static String _lastFrontmostApp = '';

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

      // SOM 标记：在 PNG 上绘制可交互元素编号（在 JPEG 转换前）
      await _drawSomOnPng(pngPath);

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

      final somInfo = CuaSom.lastMarkers.isNotEmpty
          ? '\n   SOM 标记: ${CuaSom.lastMarkers.length} 个元素'
          : '';
      debugPrint('🖥️ 截图成功: ${SkillFileUtils.formatSize(fileSize)} '
          '逻辑: ${logicalWidth}x$logicalHeight 物理: ${physicalWidth}x$physicalHeight 缩放: ${scaleFactor}x$somInfo');

      // content 不嵌入 base64（避免撑爆 API 请求体），base64 仅存 data 供 UI 渲染
      return SkillResult.ok(
        '✅ 屏幕截图成功\n'
        '   大小: ${SkillFileUtils.formatSize(fileSize)}$somInfo',
        data: {
          'filePath': jpgPath,
          'fileSize': fileSize,
          'width': logicalWidth,
          'height': logicalHeight,
          'base64': base64Image,
          'mimeType': 'image/jpeg',
          'imageType': 'screenshot',
          'somMarkerCount': CuaSom.lastMarkers.length,
          'frontmostApp': _lastFrontmostApp,
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

  /// 在 PNG 截图上绘制 SOM 标记
  ///
  /// 流程：获取 UI 树 → 提取可交互元素 → 用 Python Pillow 绘制编号圆圈 → 覆盖原 PNG
  /// 失败时静默忽略，不影响正常截图流程
  Future<void> _drawSomOnPng(String pngPath) async {
    try {
      if (!await File(pngPath).exists()) return;

      final meta = _lastScreenMeta;
      final screenW = meta?['logicalWidth'] as int? ?? _detectScreenWidth();
      final screenH = meta?['logicalHeight'] as int? ?? _detectScreenHeight();

      debugPrint('🏷️ SOM: 获取 UI 树 (screenW=$screenW, screenH=$screenH)...');

      // 获取 UI 树（超时 5 秒，深度 10 以获取更多节点）
      final treeResult = await CuaAccessibility.getUiTree(maxDepth: 10)
          .timeout(const Duration(seconds: 5), onTimeout: () {
            debugPrint('🏷️ SOM: UI 树获取超时');
            return const UiTreeResult();
          });

      if (treeResult.root == null) {
        debugPrint('🏷️ SOM: UI 树 root 为空 (${treeResult.appName}, nodes=${treeResult.nodeCount})');
        CuaSom.lastMarkers = [];
        return;
      }

      // 提取可交互元素标记
      final markers = CuaSom.extractMarkers(treeResult.root, screenW, screenH);
      CuaSom.lastMarkers = markers;
      _lastFrontmostApp = treeResult.appName;

      if (markers.isEmpty) {
        debugPrint('🏷️ SOM: 未提取到可交互标记');
        return;
      }

      debugPrint('🏷️ SOM: 提取了 ${markers.length} 个标记，开始绘制...');

      // 用 Python Pillow 在 PNG 上绘制标记（直接就地修改文件）
      final success = await CuaSom.drawMarkersWithPillow(pngPath, markers);
      if (success) {
        debugPrint('🏷️ SOM: 标记已绘制到 $pngPath');
      } else {
        debugPrint('⚠️ SOM: Pillow 绘制失败');
      }
    } catch (e, st) {
      debugPrint('⚠️ SOM 标记失败（不影响截图）: $e');
      debugPrint('⚠️ SOM stacktrace: $st');
      CuaSom.lastMarkers = [];
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
        debugPrint('🖥️ 屏幕元信息: $_lastScreenMeta');
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
    // 归一化坐标 0~1000 → 像素坐标
    final screenWidth = _detectScreenWidth();
    final screenHeight = _detectScreenHeight();
    final x = _normalizedToPixel((args['x'] as int?) ?? 0, screenWidth, 'mouse_click.x');
    final y = _normalizedToPixel((args['y'] as int?) ?? 0, screenHeight, 'mouse_click.y');
    final normalizedX = (args['x'] as int?) ?? 0;
    final normalizedY = (args['y'] as int?) ?? 0;
    final button = args['button'] as String? ?? 'left';
    final clicks = (args['clicks'] as int?) ?? 1;

    // 匹配最近的 SOM 标记
    final marker = CuaSom.findNearestMarker(normalizedX.toDouble(), normalizedY.toDouble());
    final markerHint = marker != null
        ? '，命中标记 [${marker.id}] ${marker.role}${marker.title.isNotEmpty ? ' "${marker.title}"' : ''}'
        : '';

    debugPrint('🖥️ CUA mouse_click: 归一化($normalizedX, $normalizedY) → 像素($x, $y) button=$button clicks=$clicks$markerHint');

    if (Platform.isMacOS) {
      await _mouseClickMacOS(x, y, button, clicks);
    } else if (Platform.isWindows) {
      await _mouseClickWindows(x, y, button, clicks);
    } else if (Platform.isLinux) {
      await _mouseClickLinux(x, y, button, clicks);
    } else {
      throw CuaException('mouse_click', '不支持的平台');
    }

    // 点击后自适应等待 UI 响应，然后自动截图确认
    final confirmResult = await _waitForChangeAndScreenshot('mouse_click');

    final confirmInfo = confirmResult != null
        ? '\n📸 点击后截图确认:\n   ${confirmResult['info']}'
        : '';
    return SkillResult.ok(
      '✅ 鼠标点击成功 ($x, $y) button=$button clicks=$clicks$markerHint$confirmInfo',
      data: confirmResult,
    );
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

        await _drawSomOnPng(pngPath);

        await _convertToJpeg(pngPath, jpgPath);

        final file = File(jpgPath);
        if (!await file.exists()) return null;

        final fileSize = await file.length();
        final bytes = await file.readAsBytes();
        final base64Image = base64Encode(bytes);
        final meta = _lastScreenMeta;
        final screenWidth = meta?['logicalWidth'] as int? ?? _detectScreenWidth();
        final screenHeight = meta?['logicalHeight'] as int? ?? _detectScreenHeight();

        final somInfo = CuaSom.lastMarkers.isNotEmpty
            ? ', SOM: ${CuaSom.lastMarkers.length} 个标记'
            : '';
        debugPrint('📸 确认截图: ${SkillFileUtils.formatSize(fileSize)}$somInfo');

        return {
          'filePath': jpgPath,
          'fileSize': fileSize,
          'width': screenWidth,
          'height': screenHeight,
          'base64': base64Image,
          'mimeType': 'image/jpeg',
          'imageType': 'confirm_screenshot',
          'info': '操作后截图确认, 大小: ${SkillFileUtils.formatSize(fileSize)}$somInfo',
          'somMarkerCount': CuaSom.lastMarkers.length,
          'frontmostApp': _lastFrontmostApp,
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
    } on StateError catch (e) {
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
    final screenWidth = _detectScreenWidth();
    final screenHeight = _detectScreenHeight();
    final x = _normalizedToPixel((args['x'] as int?) ?? 0, screenWidth, 'mouse_move.x');
    final y = _normalizedToPixel((args['y'] as int?) ?? 0, screenHeight, 'mouse_move.y');

    debugPrint('🖥️ CUA mouse_move: ($x, $y)');

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
    final screenWidth = _detectScreenWidth();
    final screenHeight = _detectScreenHeight();
    final x = _normalizedToPixel((args['x'] as int?) ?? 0, screenWidth, 'mouse_scroll.x');
    final y = _normalizedToPixel((args['y'] as int?) ?? 0, screenHeight, 'mouse_scroll.y');
    final scrollX = args['scroll_x'] as int? ?? 0;
    final scrollY = args['scroll_y'] as int? ?? 0;

    debugPrint('🖥️ CUA mouse_scroll: ($x, $y) delta=($scrollX, $scrollY)');

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

    // 操作后自适应等待并截图确认
    final confirmResult = await _waitForChangeAndScreenshot('mouse_scroll');
    final confirmInfo = confirmResult != null
        ? '\n📸 滚动后截图确认:\n   ${confirmResult['info']}'
        : '';
    return SkillResult.ok('✅ 滚动操作完成: 水平=$scrollX, 垂直=$scrollY$confirmInfo');
  }

  Future<SkillResult> _mouseDrag(Map<String, dynamic> args) async {
    final screenWidth = _detectScreenWidth();
    final screenHeight = _detectScreenHeight();
    final x = _normalizedToPixel((args['x'] as int?) ?? 0, screenWidth, 'mouse_drag.x');
    final y = _normalizedToPixel((args['y'] as int?) ?? 0, screenHeight, 'mouse_drag.y');
    final targetX = _normalizedToPixel((args['target_x'] as int?) ?? args['x'] as int? ?? 0, screenWidth, 'mouse_drag.target_x');
    final targetY = _normalizedToPixel((args['target_y'] as int?) ?? args['y'] as int? ?? 0, screenHeight, 'mouse_drag.target_y');

    debugPrint('🖥️ CUA mouse_drag: ($x, $y) → ($targetX, $targetY)');

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

    // 操作后自适应等待并截图确认
    final confirmResult = await _waitForChangeAndScreenshot('mouse_drag');
    final confirmInfo = confirmResult != null
        ? '\n📸 拖拽后截图确认:\n   ${confirmResult['info']}'
        : '';
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

    debugPrint('🖥️ CUA open_app: $appName');

    if (Platform.isMacOS) {
      await _openAppMacOS(appName);
    } else if (Platform.isWindows) {
      await _openAppWindows(appName);
    } else if (Platform.isLinux) {
      await _openAppLinux(appName);
    }

    // 打开应用后自适应等待（应用启动较慢）并截图确认
    final confirmResult = await _waitForChangeAndScreenshot('open_app');
    final confirmInfo = confirmResult != null
        ? '\n📸 打开应用后截图确认:\n   ${confirmResult['info']}'
        : '';
    return SkillResult.ok('✅ 已打开应用: $appName$confirmInfo');
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

    // 操作后自适应等待并截图确认
    final confirmResult = await _waitForChangeAndScreenshot('key_type');
    final confirmInfo = confirmResult != null
        ? '\n📸 输入后截图确认:\n   ${confirmResult['info']}'
        : '';
    return SkillResult.ok('✅ 文本输入完成 (${text.length} 字符)$confirmInfo');
  }

  Future<SkillResult> _keyCombo(Map<String, dynamic> args) async {
    final keys = args['keys'] as String? ?? '';
    if (keys.isEmpty) {
      throw CuaException('key_combo', 'keys 参数不能为空');
    }

    debugPrint('🖥️ CUA key_combo: $keys');

    if (Platform.isMacOS) {
      await _keyComboMacOS(keys);
    } else if (Platform.isWindows) {
      await _keyComboWindows(keys);
    } else if (Platform.isLinux) {
      await _keyComboLinux(keys);
    }

    // 操作后自适应等待并截图确认
    final confirmResult = await _waitForChangeAndScreenshot('key_combo');
    final confirmInfo = confirmResult != null
        ? '\n📸 快捷键后截图确认:\n   ${confirmResult['info']}'
        : '';
    return SkillResult.ok('✅ 快捷键执行成功: $keys$confirmInfo');
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

  Future<SkillResult> _getUiTree(Map<String, dynamic> args) async {
    final maxDepth = ((args['max_depth'] as int?) ?? 6).clamp(1, 10);
    final appFilter = args['app_filter'] as String?;

    debugPrint('🌳 CUA get_ui_tree: maxDepth=$maxDepth appFilter=$appFilter');

    try {
      final treeResult = await CuaAccessibility.getUiTree(
        maxDepth: maxDepth,
        appFilter: appFilter,
      );

      final buffer = StringBuffer();
      buffer.writeln('✅ UI 树解析成功');
      if (treeResult.appName.isNotEmpty) {
        buffer.writeln('   当前应用: ${treeResult.appName}');
      }
      if (treeResult.appBundleId.isNotEmpty) {
        buffer.writeln('   Bundle ID: ${treeResult.appBundleId}');
      }
      buffer.writeln('   元素数量: ${treeResult.nodeCount}');
      buffer.writeln('   解析深度: $maxDepth');
      buffer.writeln();
      buffer.writeln('🌳 UI 元素树:');
      buffer.writeln(treeResult.text);

      return SkillResult.ok(buffer.toString(), data: {
        'nodeCount': treeResult.nodeCount,
        'appName': treeResult.appName,
      });
    } on StateError catch (e) {
      throw CuaException('get_ui_tree', e.message);
    } catch (e) {
      throw CuaException('get_ui_tree', 'UI 树解析失败: $e');
    }
  }

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
