/// CUA Accessibility - UI 树解析
///
/// 通过系统 Accessibility API 读取 UI 元素树，提供基于属性的结构化定位能力。
/// - macOS: 通过 Python 脚本调用 ApplicationServices/Accessibility API
/// - Windows: 通过 PowerShell 调用 UIAutomation COM 对象
library;

import 'dart:convert';
import 'dart:io';
import 'package:flutter/foundation.dart';

/// UI 树中的一个节点
class UiTreeNode {
  final String role;
  final String title;
  final String value;
  final String description;
  final double? x;
  final double? y;
  final double? width;
  final double? height;
  final bool enabled;
  final List<UiTreeNode> children;

  const UiTreeNode({
    this.role = '',
    this.title = '',
    this.value = '',
    this.description = '',
    this.x,
    this.y,
    this.width,
    this.height,
    this.enabled = true,
    this.children = const [],
  });

  Map<String, dynamic> toJson() => {
    'role': role,
    'title': title,
    if (value.isNotEmpty) 'value': value,
    if (description.isNotEmpty) 'description': description,
    if (x != null) 'x': x,
    if (y != null) 'y': y,
    if (width != null) 'width': width,
    if (height != null) 'height': height,
    'enabled': enabled,
    if (children.isNotEmpty)
      'children': children.map((c) => c.toJson()).toList(),
  };

  factory UiTreeNode.fromJson(Map<String, dynamic> json) => UiTreeNode(
    role: json['role'] as String? ?? '',
    title: json['title'] as String? ?? '',
    value: json['value'] as String? ?? '',
    description: json['description'] as String? ?? '',
    x: (json['x'] as num?)?.toDouble(),
    y: (json['y'] as num?)?.toDouble(),
    width: (json['width'] as num?)?.toDouble(),
    height: (json['height'] as num?)?.toDouble(),
    enabled: json['enabled'] as bool? ?? true,
    children: (json['children'] as List?)
            ?.map((c) => UiTreeNode.fromJson(c as Map<String, dynamic>))
            .toList() ??
        [],
  );

  /// 将 UI 树格式化为可读文本（供 LLM 分析）
  String toReadableText({int indent = 0, int maxDepth = 8, int currentDepth = 0}) {
    if (currentDepth > maxDepth) return '';
    final prefix = '  ' * indent;
    final buffer = StringBuffer();

    final label = <String>[
      role,
      if (title.isNotEmpty) '"$title"',
      if (value.isNotEmpty) 'val="$value"',
      if (description.isNotEmpty) 'desc="$description"',
    ].join(' ');

    if (x != null && y != null) {
      buffer.writeln('$prefix- $label (${x!.round()}, ${y!.round()})');
    } else {
      buffer.writeln('$prefix- $label');
    }

    for (final child in children) {
      buffer.write(child.toReadableText(
        indent: indent + 1,
        maxDepth: maxDepth,
        currentDepth: currentDepth + 1,
      ));
    }
    return buffer.toString();
  }
}

/// UI 树解析结果
class UiTreeResult {
  final UiTreeNode? root;
  final String appBundleId;
  final String appName;
  final String text;
  final int nodeCount;

  const UiTreeResult({
    this.root,
    this.appBundleId = '',
    this.appName = '',
    this.text = '',
    this.nodeCount = 0,
  });
}

/// UI 树解析器
class CuaAccessibility {
  /// macOS: 通过 Python 脚本读取 Accessibility 树
  /// 优先使用 pyobjc（更强大），失败后回退到 AppleScript
  static Future<UiTreeResult> getUiTreeMacOS({
    int maxDepth = 6,
    String? appFilter,
  }) async {
    // ── 方案1：Python pyobjc（推荐，功能完整） ──
    try {
      return await _getUiTreeMacOSPython(maxDepth: maxDepth, appFilter: appFilter);
    } on StateError {
      rethrow; // 权限错误直接抛出，不降级
    } catch (e) {
      debugPrint('⚠️ macOS Python UI 树解析失败: $e，回退到 AppleScript');
    }

    // ── 方案2：AppleScript 回退（无需外部依赖） ──
    try {
      return await _getUiTreeMacOSAppleScript(maxDepth: maxDepth);
    } on StateError {
      rethrow;
    } catch (e) {
      throw Exception(
        'UI 树解析失败（Python 和 AppleScript 均失败）。\n'
        'Python 方式需要: python3 + pyobjc (pip install pyobjc)\n'
        'AppleScript 方式需要: 辅助功能权限\n'
        '错误: $e',
      );
    }
  }

  /// macOS Python pyobjc 方式
  static Future<UiTreeResult> _getUiTreeMacOSPython({
    int maxDepth = 6,
    String? appFilter,
  }) async {
    final script = _buildMacOsScript(maxDepth: maxDepth, appFilter: appFilter);

    final result = await Process.run('python3', ['-c', script]);

    if (result.exitCode != 0) {
      final stderr = result.stderr.toString();
      if (stderr.contains('not trusted') ||
          stderr.contains('AXIsProcessTrusted') ||
          stderr.contains('permission')) {
        throw StateError(
          '缺少辅助功能权限。\n'
          '请在 系统设置 → 隐私与安全性 → 辅助功能 中勾选终端(Terminal)和鹅宝(GooseBaby)，然后重启应用。',
        );
      }
      // python3/pyobjc 不可用时，抛出异常让调用方降级
      if (stderr.contains('ModuleNotFoundError') ||
          stderr.contains('No module named') ||
          stderr.contains('ImportError')) {
        throw Exception('pyobjc 未安装或 python3 不可用: $stderr');
      }
      throw Exception('UI 树解析失败: $stderr');
    }

    final output = result.stdout.toString().trim();
    if (output.isEmpty) {
      return const UiTreeResult(text: '未找到 UI 元素');
    }

    final jsonStr = output.substring(output.indexOf('{'), output.lastIndexOf('}') + 1);
    final data = jsonDecode(jsonStr) as Map<String, dynamic>;
    final children = (data['children'] as List?)
            ?.map((c) => UiTreeNode.fromJson(c as Map<String, dynamic>))
            .toList() ??
        [];

    final root = UiTreeNode(
      role: data['role'] as String? ?? 'application',
      title: data['title'] as String? ?? '',
      children: children,
    );

    // 统计节点数
    int countNodes(UiTreeNode node) {
      var count = 1;
      for (final c in node.children) {
        count += countNodes(c);
      }
      return count;
    }

    final nodeCount = children.fold<int>(0, (sum, c) => sum + countNodes(c));
    final text = root.toReadableText(maxDepth: maxDepth);

    return UiTreeResult(
      root: root,
      appBundleId: data['bundleId'] as String? ?? '',
      appName: data['title'] as String? ?? '',
      text: text,
      nodeCount: nodeCount,
    );
  }

  /// macOS AppleScript 回退方式（无需 python3/pyobjc）
  /// 通过 osascript 调用 System Events 获取基本的 UI 元素信息
  static Future<UiTreeResult> _getUiTreeMacOSAppleScript({int maxDepth = 6}) async {
    final script = '''
tell application "System Events"
  set frontApp to name of first application process whose frontmost is true
  set appDesc to description of first application process whose frontmost is true
  set windowList to name of every window of first application process whose frontmost is true
  set uiElements to ""
  set elemCount to 0
  
  try
    set allUI to every UI element of first application process whose frontmost is true
    repeat with elem in allUI
      set uiElements to uiElements & "  - " & (role of elem) & " \\"" & (description of elem) & "\\""
      if (value of elem) is not missing value then
        set uiElements to uiElements & " val=\\"" & (value of elem) & "\\""
      end if
      set uiElements to uiElements & linefeed
      set elemCount to elemCount + 1
    end repeat
  end try
end tell

return frontApp & "|" & appDesc & "|" & (windowList as text) & "|" & elemCount & "|" & uiElements
''';

    final result = await Process.run('osascript', ['-e', script]);
    if (result.exitCode != 0) {
      final stderr = result.stderr?.toString() ?? '';
      if (stderr.contains('not allowed') || stderr.contains('1002') || stderr.contains('不允许')) {
        throw StateError(
          '缺少辅助功能权限。\n'
          '请在 系统设置 → 隐私与安全性 → 辅助功能 中勾选鹅宝(GooseBaby)，然后重启应用。',
        );
      }
      throw Exception('AppleScript UI 树解析失败: $stderr');
    }

    final output = result.stdout.toString().trim();
    final parts = output.split('|');
    if (parts.length < 4) {
      return const UiTreeResult(text: 'AppleScript 未获取到 UI 信息');
    }

    final appName = parts[0];
    final appDesc = parts[1];
    final windows = parts[2];
    final elemCount = int.tryParse(parts[3]) ?? 0;
    final uiElements = parts.length > 4 ? parts.sublist(4).join('|') : '';

    final buffer = StringBuffer();
    buffer.writeln('- role: application title: "$appName"');
    if (appDesc.isNotEmpty && appDesc != appName) {
      buffer.writeln('  description: "$appDesc"');
    }
    if (windows.isNotEmpty && windows != '') {
      buffer.writeln('  windows: $windows');
    }
    if (uiElements.isNotEmpty) {
      buffer.writeln('  children:');
      for (final line in uiElements.split('\n').where((l) => l.trim().isNotEmpty)) {
        buffer.writeln('    $line');
      }
    }

    return UiTreeResult(
      appName: appName,
      text: buffer.toString(),
      nodeCount: elemCount,
    );
  }

  /// macOS Python 脚本：通过 pyobjc 读取 Accessibility 树
  static String _buildMacOsScript({int maxDepth = 6, String? appFilter}) {
    final filterClause = appFilter != null
        ? '''
if "$appFilter".lower() not in app_title.lower() and "$appFilter".lower() not in bundle_id.lower():
    print(json.dumps({"error": "focused app does not match filter", "title": app_title, "bundleId": bundle_id}))
    sys.exit(0)
'''
        : '';

    return r'''
import sys, json, re
from ApplicationServices import (
    AXUIElementCreateApplication, AXUIElementCopyAttributeValue,
    kAXFocusedUIElementAttribute,
    kAXChildrenAttribute, kAXRoleAttribute, kAXTitleAttribute,
    kAXValueAttribute, kAXDescriptionAttribute, kAXPositionAttribute,
    kAXSizeAttribute, kAXEnabledAttribute, kAXRoleDescriptionAttribute,
)
from AppKit import NSWorkspace

def _get_attr(element, attr):
    """获取 AX 属性值。pyobjc 返回 (error_code, value)，error_code=0 表示成功。"""
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

def _parse_ax_value(val, pattern1, pattern2):
    """通过解析 AXValue.description() 字符串提取坐标/尺寸。
    pyobjc 的 AXValueGetValue 在 Python 3.12+ 中存在参数传递 bug，
    因此改用 description 字符串解析方式。"""
    try:
        desc = val.description()
        m = re.search(pattern1, desc)
        if m:
            return (float(m.group(1)), float(m.group(2)))
        m = re.search(pattern2, desc)
        if m:
            return (float(m.group(1)), float(m.group(2)))
    except:
        pass
    return None

def _get_point(element):
    pos = _get_attr(element, kAXPositionAttribute)
    if pos:
        result = _parse_ax_value(pos, r'x:([-\d.]+)\s+y:([-\d.]+)', r'x:([-\d.]+),\s*y:([-\d.]+)')
        if result:
            return {"x": result[0], "y": result[1]}
    return None

def _get_size(element):
    sz = _get_attr(element, kAXSizeAttribute)
    if sz:
        result = _parse_ax_value(sz, r'w:([-\d.]+)\s+h:([-\d.]+)', r'width:([-\d.]+)\s+height:([-\d.]+)')
        if result:
            return {"width": result[0], "height": result[1]}
    return None

def _collect_child_text(node):
    """递归从子元素中收集可见文本"""
    texts = []
    for child in (node.get("children") or []):
        cr = child.get("role", "").lower()
        t = (child.get("title") or child.get("value") or child.get("description") or "").strip()
        if t and ("statictext" in cr or "button" in cr or "link" in cr):
            texts.append(t)
        elif "group" in cr or "row" in cr:
            t2 = _collect_child_text(child)
            if t2:
                texts.append(t2)
    return " ".join(texts)[:30]

def _node_to_dict(element, depth=0, max_depth=MAX_DEPTH, ancestor_rect=None):
    """ancestor_rect: 最近有坐标的祖先坐标，仅叶子节点无坐标时继承"""
    if depth > max_depth:
        return None
    result = {}
    role = _get_attr(element, kAXRoleAttribute)
    title = _get_attr(element, kAXTitleAttribute)
    value = _get_attr(element, kAXValueAttribute)
    desc = _get_attr(element, kAXDescriptionAttribute)
    role_desc = _get_attr(element, kAXRoleDescriptionAttribute)
    enabled = _get_attr(element, kAXEnabledAttribute)

    result["role"] = str(role) if role else ""
    result["title"] = str(title) if title else ""
    if value is not None and str(value).strip():
        result["value"] = str(value)[:200]
    if desc is not None and str(desc).strip():
        result["description"] = str(desc)[:200]
    if role_desc is not None and str(role_desc).strip() and str(role_desc) != str(role):
        result["roleDescription"] = str(role_desc)

    pos = _get_point(element)
    sz = _get_size(element)
    has_own_bounds = False
    my_rect = ancestor_rect
    if pos and sz and sz["width"] > 0 and sz["height"] > 0:
        result["x"] = pos["x"]
        result["y"] = pos["y"]
        result["width"] = sz["width"]
        result["height"] = sz["height"]
        my_rect = (pos["x"], pos["y"], sz["width"], sz["height"])
        has_own_bounds = True

    if enabled is not None:
        result["enabled"] = bool(enabled)

    children_val = _get_attr(element, kAXChildrenAttribute)
    child_list = []
    if children_val:
        try:
            for child in children_val:
                child_dict = _node_to_dict(child, depth + 1, max_depth, ancestor_rect=my_rect)
                if child_dict:
                    child_list.append(child_dict)
        except:
            pass

    # 没有自身坐标的叶子节点，继承最近祖先坐标
    if not has_own_bounds and not child_list and ancestor_rect:
        result["x"] = ancestor_rect[0]
        result["y"] = ancestor_rect[1]
        result["width"] = ancestor_rect[2]
        result["height"] = ancestor_rect[3]

    if child_list:
        result["children"] = child_list

    # 收集子元素文本（用于标记标签）
    if not result.get("title") and not result.get("value") and not result.get("description"):
        child_text = _collect_child_text(result)
        if child_text:
            result["childText"] = child_text

    return result

# 通过 NSWorkspace 获取前台应用（不依赖 kAXFocusedApplicationAttribute）
ws = NSWorkspace.sharedWorkspace()
front_app = ws.frontmostApplication()
if not front_app:
    print(json.dumps({"error": "no frontmost application", "role": "system", "title": "无前台应用", "children": []}))
    sys.exit(0)

app_pid = int(front_app.processIdentifier())
app_title = front_app.localizedName() or ""
bundle_id = front_app.bundleIdentifier() or ""

# 通过 PID 创建 AX 应用元素
app = AXUIElementCreateApplication(app_pid)

FILTER_CLAUSE

# 解析应用窗口
app_dict = _node_to_dict(app, 0, MAX_DEPTH)
if app_dict is None:
    app_dict = {"role": "application", "title": app_title, "children": []}
app_dict["title"] = app_title
app_dict["bundleId"] = bundle_id

print(json.dumps(app_dict, ensure_ascii=False))
'''.replaceAll('MAX_DEPTH', '$maxDepth').replaceAll('FILTER_CLAUSE', filterClause);
  }

  /// Windows: 通过 PowerShell UIAutomation 读取 UI 树
  static Future<UiTreeResult> getUiTreeWindows({int maxDepth = 6}) async {
    final psScript = '''
[void][System.Reflection.Assembly]::LoadWithPartialName("UIAutomationClient")
[void][System.Reflection.Assembly]::LoadWithPartialName("UIAutomationTypes")

\$uia = [System.Windows.Automation.AutomationElement]::RootElement
\$treeScope = [System.Windows.Automation.TreeScope]::Children
\$cond = [System.Windows.Automation.Condition]::TrueCondition

function Get-UINode {
    param(\$elem, \$depth, \$maxDepth)
    if (\$depth -gt \$maxDepth) { return \$null }

    \$result = @{}
    try {
        \$current = \$elem.Current
        \$result["role"] = \$current.LocalizedControlType
        \$result["title"] = \$current.Name
        if (\$current.ClassName) { \$result["className"] = \$current.ClassName }
        if (\$current.AutomationId) { \$result["automationId"] = \$current.AutomationId }
        if (\$current.IsEnabled) { \$result["enabled"] = \$true } else { \$result["enabled"] = \$false }
        if (\$current.IsKeyboardFocusable) { \$result["focusable"] = \$true }

        \$rect = \$current.BoundingRectangle
        if (\$rect -ne [System.Windows.Automation.Rect]::Empty) {
            \$result["x"] = \$rect.X
            \$result["y"] = \$rect.Y
            \$result["width"] = \$rect.Width
            \$result["height"] = \$rect.Height
        }

        if (\$current.Value.Value) {
            \$result["value"] = \$current.Value.Value
        }
    } catch {}

    \$children = @()
    try {
        \$childElems = \$elem.FindAll(\$treeScope, \$cond)
        if (\$childElems) {
            foreach (\$child in \$childElems) {
                \$childNode = Get-UINode -elem \$child -depth (\$depth + 1) -maxDepth \$maxDepth
                if (\$childNode) { \$children += \$childNode }
            }
        }
    } catch {}
    if (\$children.Count -gt 0) { \$result["children"] = \$children }
    return \$result
}

\$rootNode = Get-UINode -elem \$uia -depth 0 -maxDepth $maxDepth
if (-not \$rootNode) { \$rootNode = @{"role"="desktop";"title"="Desktop";"children"=@()} }
\$json = \$rootNode | ConvertTo-Json -Depth 10 -Compress
Write-Output \$json
''';

    try {
      final result = await Process.run(
        'powershell',
        ['-NoProfile', '-Command', psScript],
      ).timeout(const Duration(seconds: 10));

      if (result.exitCode != 0) {
        throw Exception('Windows UIAutomation 失败: ${result.stderr}');
      }

      final output = result.stdout.toString().trim();
      if (output.isEmpty) {
        return const UiTreeResult(text: '未找到 UI 元素');
      }

      final data = jsonDecode(output) as Map<String, dynamic>;
      final children = (data['children'] as List?)
              ?.map((c) => UiTreeNode.fromJson(c as Map<String, dynamic>))
              .toList() ??
          [];

      final root = UiTreeNode(
        role: data['role'] as String? ?? 'desktop',
        title: data['title'] as String? ?? '',
        children: children,
      );

      int countNodes(UiTreeNode node) {
        var count = 1;
        for (final c in node.children) {
          count += countNodes(c);
        }
        return count;
      }

      return UiTreeResult(
        root: root,
        appName: data['title'] as String? ?? 'Desktop',
        text: root.toReadableText(maxDepth: maxDepth),
        nodeCount: children.fold<int>(0, (sum, c) => sum + countNodes(c)),
      );
    } catch (e) {
      if (e is Exception && e.toString().contains('TimeoutException')) {
        throw Exception('Windows UIAutomation 超时（10秒）');
      }
      rethrow;
    }
  }

  /// Linux: 通过 xdotool/xdpyinfo 获取基本的窗口信息
  static Future<UiTreeResult> getUiTreeLinux({int maxDepth = 4}) async {
    try {
      // 获取活动窗口列表
      final result = await Process.run('xdotool', ['search', '--name', '']);
      if (result.exitCode != 0) {
        return const UiTreeResult(text: '未找到窗口信息（需要 xdotool）');
      }

      final windowIds = (result.stdout.toString().trim().split('\n'))
          .where((id) => id.trim().isNotEmpty)
          .take(20);

      final buffer = StringBuffer();
      buffer.writeln('role: desktop');
      buffer.writeln('children:');

      for (final wid in windowIds) {
        try {
          final nameResult = await Process.run(
            'xdotool',
            ['getwindowname', wid.trim()],
          );
          final name = nameResult.stdout.toString().trim();
          if (name.isNotEmpty) {
            buffer.writeln('  - role: window title: "$name"');
          }
        } catch (_) {}
      }

      return UiTreeResult(
        text: buffer.toString(),
        nodeCount: windowIds.length,
      );
    } catch (e) {
      return UiTreeResult(text: 'UI 树解析失败: $e');
    }
  }

  /// 跨平台 UI 树解析入口
  static Future<UiTreeResult> getUiTree({
    int maxDepth = 6,
    String? appFilter,
  }) async {
    if (Platform.isMacOS) {
      return getUiTreeMacOS(maxDepth: maxDepth, appFilter: appFilter);
    } else if (Platform.isWindows) {
      return getUiTreeWindows(maxDepth: maxDepth);
    } else if (Platform.isLinux) {
      return getUiTreeLinux(maxDepth: maxDepth);
    } else {
      return const UiTreeResult(text: '不支持的平台');
    }
  }
}
