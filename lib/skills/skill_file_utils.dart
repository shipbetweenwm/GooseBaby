import 'dart:io';
import 'package:flutter/foundation.dart';
import 'package:path/path.dart' as p;

/// 技能文件操作工具类
/// 提供跨技能共用的文件收集、MIME 类型识别等功能
class SkillFileUtils {
  SkillFileUtils._();

  /// 用户自定义的工作目录（通过设置面板配置）
  /// 如果为 null，则使用默认工作目录（桌面）
  static String? _customWorkingDir;

  /// 当前会话的工作目录（每次对话独立，避免文件名冲突）
  /// 如果为 null，则回退到 effectiveBaseWorkingDir
  static String? _sessionWorkingDir;

  /// 缓存用户 home 路径（避免重复检测）
  static String? _cachedHome;

  /// 获取当前用户的 home 目录（macOS GUI 应用的 HOME 可能是 /var/root）
  static String get _userHome {
    if (_cachedHome != null) return _cachedHome!;

    // macOS GUI 应用启动时 HOME 环境变量可能不正确
    // 使用 whoami + dscl 获取真实用户 home
    if (Platform.isMacOS) {
      try {
        final whoami = Process.runSync('whoami', []).stdout.toString().trim();
        if (whoami.isNotEmpty && whoami != 'root') {
          final result = Process.runSync('dscl', [
            '.', '-read', '/Users/$whoami', 'NFSHomeDirectory',
          ]).stdout.toString().trim();
          // 输出格式: NFSHomeDirectory: /Users/xxx
          final match = RegExp(r'NFSHomeDirectory:\s*(.+)').firstMatch(result);
          if (match != null) {
            final home = match.group(1)!.trim();
            if (Directory(home).existsSync()) {
              _cachedHome = home;
              return home;
            }
          }
        }
      } catch (_) {}
    }

    // 回退到环境变量
    final home = Platform.environment['USERPROFILE']
        ?? Platform.environment['HOME']
        ?? p.dirname(Platform.resolvedExecutable);
    _cachedHome = home;
    return home;
  }

  /// 默认工作目录：用户桌面
  /// 文件读写、脚本执行的相对路径都基于此目录
  static String get defaultWorkingDir {
    final home = _userHome;
    final desktop = p.join(home, 'Desktop');
    // 如果桌面目录存在就用桌面，否则用 home
    try {
      if (Directory(desktop).existsSync()) return desktop;
    } catch (_) {
      // 权限不足等异常，忽略
    }
    return home;
  }

  /// 获取当前有效的基础工作目录（用户自定义或默认）
  static String get effectiveBaseWorkingDir =>
      _customWorkingDir ?? defaultWorkingDir;

  /// 获取当前有效的工作目录
  /// 如果设置了 sessionWorkingDir 则使用它，否则回退到 effectiveBaseWorkingDir
  static String get effectiveWorkingDir =>
      _sessionWorkingDir ?? effectiveBaseWorkingDir;

  /// 设置用户自定义工作目录
  static set customWorkingDir(String? path) {
    _customWorkingDir = path;
    debugPrint('📁 自定义工作目录: $path');
  }

  /// 获取用户自定义工作目录
  static String? get customWorkingDir => _customWorkingDir;

  /// 设置当前会话的工作目录
  /// 在每次发消息前由 chat_panel 调用
  /// [sessionId] 用于生成唯一的会话目录名
  static Future<void> setSessionWorkingDir(String sessionId) async {
    final base = defaultWorkingDir;
    final sessionDir = p.join(base, 'GooseBaby_$sessionId');
    await Directory(sessionDir).create(recursive: true);
    _sessionWorkingDir = sessionDir;
    debugPrint('📁 会话工作目录: $sessionDir');
  }

  /// 清除会话工作目录（切换会话时调用）
  static void clearSessionWorkingDir() {
    _sessionWorkingDir = null;
  }

  /// 缓存的 Python 路径检测结果
  static String? _cachedPythonPath;

  /// 检测系统中可用的 Python 绝对路径
  /// 优先级: py > python > python3
  /// 在 Windows 上会跳过 WindowsApps 的 stub python
  static Future<String?> detectPythonPath() async {
    if (_cachedPythonPath != null) return _cachedPythonPath;

    final candidates = Platform.isWindows
        ? ['py', 'python', 'python3']
        : ['python3', 'python'];

    for (final cmd in candidates) {
      try {
        final result = await Process.run(
          Platform.isWindows ? 'cmd' : 'bash',
          [Platform.isWindows ? '/c' : '-c', 'where $cmd'],
        ).timeout(const Duration(seconds: 5));

        final paths = (result.stdout as String)
            .split('\n')
            .map((s) => s.trim())
            .where((s) => s.isNotEmpty);

        for (final path in paths) {
          // 跳过 Windows Store stub
          if (path.contains('WindowsApps\\python') ||
              path.contains('WindowsApps\\python3')) {
            continue;
          }
          // 验证可执行文件确实存在
          if (File(path).existsSync()) {
            _cachedPythonPath = path;
            debugPrint('🐍 检测到 Python: $path');
            return path;
          }
        }
      } catch (_) {}
    }
    debugPrint('⚠️ 未检测到 Python');
    return null;
  }

  /// 列出目录中所有文件路径（用于 diff 对比）
  static Future<Set<String>> listFilePaths(String dirPath) async {
    final paths = <String>{};
    try {
      final dir = Directory(dirPath);
      if (!await dir.exists()) return paths;
      await for (final entity in dir.list(recursive: true)) {
        if (entity is File) paths.add(entity.path);
      }
    } catch (_) {}
    return paths;
  }

  /// 收集新生成的文件（对比执行前的快照）
  static Future<List<Map<String, dynamic>>> collectNewFiles(
    String dirPath,
    Set<String> existingPaths, {
    Set<String>? skipPatterns,
  }) async {
    final files = <Map<String, dynamic>>[];
    final dir = Directory(dirPath);
    if (!await dir.exists()) return files;

    const imageExtensions = {
      '.png', '.jpg', '.jpeg', '.gif', '.bmp', '.webp', '.svg', '.ico'
    };

    final defaultSkipPatterns = {'.pyc', '__pycache__'};

    try {
      await for (final entity in dir.list(recursive: true)) {
        if (entity is! File) continue;
        if (existingPaths.contains(entity.path)) continue;

        final name = p.basename(entity.path);

        // 检查跳过模式
        bool shouldSkip = false;
        for (final pattern in [...?skipPatterns, ...defaultSkipPatterns]) {
          if (name.endsWith(pattern) || name.startsWith(pattern)) {
            shouldSkip = true;
            break;
          }
        }
        if (shouldSkip) continue;

        final stat = await entity.stat();
        final ext = p.extension(name).toLowerCase();
        files.add({
          'name': name,
          'path': entity.path,
          'size': stat.size,
          'isImage': imageExtensions.contains(ext),
          'mimeType': guessMimeType(name),
        });
      }
    } catch (e) {
      debugPrint('📁 收集输出文件失败: $e');
    }

    return files;
  }

  /// 根据文件扩展名猜测 MIME 类型
  static String guessMimeType(String fileName) {
    final ext = p.extension(fileName).toLowerCase();
    const mimeMap = {
      '.png': 'image/png',
      '.jpg': 'image/jpeg',
      '.jpeg': 'image/jpeg',
      '.gif': 'image/gif',
      '.bmp': 'image/bmp',
      '.webp': 'image/webp',
      '.svg': 'image/svg+xml',
      '.pdf': 'application/pdf',
      '.csv': 'text/csv',
      '.json': 'application/json',
      '.txt': 'text/plain',
      '.html': 'text/html',
      '.xml': 'application/xml',
      '.pptx': 'application/vnd.openxmlformats-officedocument.presentationml.presentation',
      '.xlsx': 'application/vnd.openxmlformats-officedocument.spreadsheetml.sheet',
      '.docx': 'application/vnd.openxmlformats-officedocument.wordprocessingml.document',
      '.mp3': 'audio/mpeg',
      '.mp4': 'video/mp4',
      '.wav': 'audio/wav',
      '.zip': 'application/zip',
    };
    return mimeMap[ext] ?? 'application/octet-stream';
  }

  /// 格式化文件大小
  static String formatSize(int bytes) {
    if (bytes < 1024) return '$bytes B';
    if (bytes < 1024 * 1024) return '${(bytes / 1024).toStringAsFixed(1)} KB';
    return '${(bytes / (1024 * 1024)).toStringAsFixed(1)} MB';
  }

  /// 剥除路径两端的引号/转义引号（LLM 可能传递 "C:\file.py"、\"C:\file.py\" 等格式）
  static String stripPathQuotes(String path) {
    var trimmed = path.trim();
    // 循环剥离两端的引号字符（处理多层嵌套如 \"\"path\"\"）
    while (trimmed.isNotEmpty) {
      final start = trimmed[0];
      final end = trimmed[trimmed.length - 1];
      bool stripped = false;
      if ((start == '"' || start == "'") && (end == '"' || end == "'")) {
        trimmed = trimmed.substring(1, trimmed.length - 1).trim();
        stripped = true;
      } else if (trimmed.startsWith('\\"') || trimmed.startsWith("\\'")) {
        trimmed = trimmed.substring(2).trim();
        stripped = true;
        if (trimmed.endsWith('\\"') || trimmed.endsWith("\\'")) {
          trimmed = trimmed.substring(0, trimmed.length - 2).trim();
        }
      }
      if (!stripped) break;
    }
    return trimmed;
  }

  /// 截断文本
  static String truncate(String text, int maxLen) {
    if (text.length <= maxLen) return text;
    return '${text.substring(0, maxLen)}\n... (已截断，共 ${text.length} 字符)';
  }
}
