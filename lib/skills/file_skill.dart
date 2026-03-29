import 'dart:convert';
import 'dart:io';
import 'package:flutter/foundation.dart';
import 'package:path/path.dart' as p;
import 'skill_base.dart';
import 'skill_file_utils.dart';

// ── 系统目录黑名单（write_file 沙箱） ──
// 绝对不允许 LLM 写入这些路径，防止意外破坏系统文件
const _kSystemPathPrefixes = [
  // macOS / Linux 系统目录
  '/etc/', '/usr/', '/bin/', '/sbin/', '/lib/', '/lib64/',
  '/System/', '/private/etc/', '/private/var/', '/Applications/',
  // Windows 系统目录（小写比较）
  r'c:\windows', r'c:\program files', r'c:\programdata', r'c:\system32',
];

/// 检查路径是否落在系统目录黑名单中（不区分大小写）
bool _isSystemPath(String resolvedPath) {
  final lower = resolvedPath.toLowerCase().replaceAll(r'\', '/');
  for (final prefix in _kSystemPathPrefixes) {
    final lp = prefix.toLowerCase().replaceAll(r'\', '/');
    if (lower.startsWith(lp)) return true;
  }
  return false;
}

/// 文件写入工具
/// 让 LLM 可以将代码或内容写入本地文件，再通过 shell_exec 执行
class WriteFileSkill extends GooseSkill {
  WriteFileSkill();

  @override
  String get id => 'write_file';

  @override
  String get name => '文件写入';

  @override
  String get description =>
      '将内容写入本地文件。适合生成脚本、配置文件、代码文件等。'
      '写入后可通过 shell_exec 执行脚本。'
      '支持自动创建父目录。'
      '相对路径基于当前工作目录。';

  @override
  String get icon => '📝';

  @override
  String get category => '内置工具';

  @override
  List<SkillParam> get params => [
        const SkillParam(
          name: 'path',
          description: '文件路径。相对路径基于当前工作目录（如 script.py），也支持绝对路径（如 C:\\Users\\test\\script.py）',
          type: 'string',
          required: true,
        ),
        const SkillParam(
          name: 'content',
          description: '要写入的文件内容',
          type: 'string',
          required: true,
        ),
      ];

  @override
  Future<SkillResult> execute(Map<String, dynamic> args, {void Function(String line)? onOutput}) async {
    final path = SkillFileUtils.stripPathQuotes(args['path'] as String? ?? '');
    final content = args['content'] as String? ?? '';

    if (path.trim().isEmpty) {
      return SkillResult.fail('未提供文件路径');
    }

    // 处理相对路径：基于会话工作目录（每次对话独立，避免冲突）
    final resolvedPath = p.isAbsolute(path)
        ? path
        : p.join(SkillFileUtils.effectiveWorkingDir, path);

    // ── 安全校验：禁止写入系统目录 ──
    if (_isSystemPath(resolvedPath)) {
      debugPrint('📝 write_file 安全拦截: $resolvedPath');
      return SkillResult.fail(
        '⚠️ 安全限制：不允许写入系统目录。\n'
        '目标路径: `$resolvedPath`\n'
        '请将文件写入用户目录（如桌面、文稿、工作目录等）。',
      );
    }

    // 检查是否为二进制输出格式（pptx/pdf/docx/xlsx 等），write_file 只能写文本文件
    final ext = p.extension(resolvedPath).toLowerCase();
    if (_isBinaryOutputExt(ext)) {
      return SkillResult.fail(
        '❌ write_file 只能写入文本文件（脚本、代码、配置等），'
        '不能直接生成 $ext 二进制文件。\n\n'
        '正确做法：用 write_file 写一个 Python 脚本（如 generate_ppt.py），'
        '然后用 shell_exec 执行该脚本来生成 $ext 文件。\n'
        '示例 Python 库：\n'
        '- .pptx → python-pptx\n'
        '- .pdf → reportlab / fpdf\n'
        '- .docx → python-docx\n'
        '- .xlsx → openpyxl',
      );
    }

    try {
      debugPrint('📝 write_file: $resolvedPath (${content.length} chars)');

      // 自动创建父目录
      final parentDir = p.dirname(resolvedPath);
      await Directory(parentDir).create(recursive: true);

      // 写入文件（使用 UTF-8 编码，兼容 Python/JS 等所有编程语言）
      final file = File(resolvedPath);
      await file.writeAsString(content, encoding: utf8);

      final size = await file.length();
      final sizeStr = SkillFileUtils.formatSize(size);
      debugPrint('📝 write_file 成功: $sizeStr');

      // 对 Python 脚本自动做语法检查，提前发现语法错误
      if (ext == '.py') {
        final syntaxCheck = await _checkPythonSyntax(resolvedPath);
        if (syntaxCheck != null) {
          return SkillResult.fail(
            '⚠️ 文件已写入但 Python 语法检查失败，请修复后重新写入：\n'
            '   路径: `$resolvedPath`\n'
            '   大小: $sizeStr\n'
            '```\n$syntaxCheck\n```',
          );
        }
      }

      // 根据文件类型生成不同的成功提示
      final hint = _getWriteSuccessHint(ext);

      return SkillResult.ok(
        '✅ 文件写入成功\n'
        '   路径: `$resolvedPath`\n'
        '   大小: $sizeStr\n'
        '$hint',
        data: {
          'filePath': resolvedPath,
          'fileSize': size,
        },
      );
    } catch (e) {
      debugPrint('📝 write_file 失败: $e');
      return SkillResult.fail('写入文件失败: $e');
    }
  }

  /// 二进制输出格式扩展名（write_file 不允许写入，必须通过脚本生成）
  static const _binaryOutputExts = {
    '.pptx', '.ppt', '.pdf', '.docx', '.doc', '.xlsx', '.xls',
    '.png', '.jpg', '.jpeg', '.gif', '.webp', '.bmp', '.svg',
    '.mp3', '.mp4', '.wav', '.avi', '.mov',
    '.zip', '.rar', '.7z', '.tar', '.gz',
    '.exe', '.dll', '.so', '.dylib',
    '.ico', '.icns', '.ttf', '.otf', '.woff', '.woff2',
  };

  /// 判断扩展名是否为二进制输出格式
  static bool _isBinaryOutputExt(String ext) => _binaryOutputExts.contains(ext);

  /// 根据文件扩展名生成写入成功后的提示
  static String _getWriteSuccessHint(String ext) {
    if (_isScriptExt(ext)) {
      return '   💡 这是可执行脚本，请用 `shell_exec` 执行它来完成任务。';
    }
    if (_isDataFileExt(ext)) {
      return '   💡 这是数据/配置文件，如需进一步处理请用 `shell_exec`。';
    }
    return '   💡 文件已保存到本地。';
  }

  /// 可执行脚本扩展名
  static bool _isScriptExt(String ext) {
    return const ['.py', '.js', '.ts', '.sh', '.bash', '.bat', '.cmd',
        '.ps1', '.rb', '.go', '.rs', '.dart', '.java', '.kt', '.cs',
        '.lua', '.r', '.php', '.pl', '.swift'].contains(ext);
  }

  /// 数据/配置文件扩展名
  static bool _isDataFileExt(String ext) {
    return const ['.json', '.yaml', '.yml', '.toml', '.xml', '.csv',
        '.tsv', '.html', '.htm', '.css', '.sql', '.md', '.txt',
        '.ini', '.cfg', '.conf', '.env', '.gitignore', '.dockerfile'].contains(ext);
  }

  /// 对 Python 文件做语法检查，返回错误信息或 null（无错误）
  static Future<String?> _checkPythonSyntax(String filePath) async {
    try {
      final pythonPath = await SkillFileUtils.detectPythonPath();
      if (pythonPath == null) return null; // 找不到 Python 就跳过检查

      // 用 py_compile 做语法检查，错误输出到 stderr
      final result = await Process.run(
        pythonPath,
        ['-m', 'py_compile', filePath],
        stdoutEncoding: latin1,
        stderrEncoding: latin1,
      ).timeout(const Duration(seconds: 10));

      if (result.exitCode != 0) {
        final stderr = (result.stderr as String).trim();
        return stderr.isNotEmpty ? stderr : '语法错误 (exit code: ${result.exitCode})';
      }
      return null; // 无语法错误
    } catch (_) {
      return null; // 检查失败则跳过，不影响文件写入
    }
  }
}

/// 文件读取工具
/// 让 LLM 可以读取本地文件内容（代码、日志、配置等）
class ReadFileSkill extends GooseSkill {
  ReadFileSkill();

  @override
  String get id => 'read_file';

  @override
  String get name => '文件读取';

  @override
  String get description =>
      '读取本地文件内容。适合查看代码、日志、配置文件、CSV 等。'
      '对于二进制文件或超大文件会返回错误提示。';

  @override
  String get icon => '📂';

  @override
  String get category => '内置工具';

  @override
  List<SkillParam> get params => [
        const SkillParam(
          name: 'path',
          description: '文件的完整路径',
          type: 'string',
          required: true,
        ),
        const SkillParam(
          name: 'max_lines',
          description: '可选：最多读取的行数，默认 500 行。对于大文件建议设小一些。',
          type: 'int',
          required: false,
        ),
      ];

  @override
  Future<SkillResult> execute(Map<String, dynamic> args, {void Function(String line)? onOutput}) async {
    final path = SkillFileUtils.stripPathQuotes(args['path'] as String? ?? '');
    final maxLines = (args['max_lines'] as int?) ?? 500;

    if (path.trim().isEmpty) {
      return SkillResult.fail('未提供文件路径');
    }

    try {
      // 处理相对路径：基于会话工作目录
      final resolvedPath = p.isAbsolute(path)
          ? path
          : p.join(SkillFileUtils.effectiveWorkingDir, path);

      debugPrint('📂 read_file: $resolvedPath');

      final file = File(resolvedPath);
      if (!await file.exists()) {
        return SkillResult.fail('文件不存在: $resolvedPath');
      }

      // 检查文件大小（超过 5MB 不读取）
      final size = await file.length();
      if (size > 5 * 1024 * 1024) {
        return SkillResult.fail(
          '文件过大 (${SkillFileUtils.formatSize(size)})，超过 5MB 限制。'
          '请使用 shell_exec 的 head/tail 命令读取部分内容。',
        );
      }

      // 读取内容
      final lines = await file.readAsLines();

      String content;
      if (lines.length <= maxLines) {
        content = lines.join('\n');
      } else {
        content = lines.sublist(0, maxLines).join('\n');
        content += '\n\n... (共 ${lines.length} 行，已读取前 $maxLines 行)';
      }

      if (content.isEmpty) {
        return SkillResult.ok('✅ 文件为空\n   路径: `$resolvedPath`');
      }

      debugPrint('📂 read_file 成功: ${lines.length} 行, ${SkillFileUtils.formatSize(size)}');

      return SkillResult.ok(
        '✅ 读取成功 (${lines.length} 行, ${SkillFileUtils.formatSize(size)})\n'
        '```\n$content\n```',
        data: {
          'filePath': resolvedPath,
          'fileSize': size,
          'lineCount': lines.length,
        },
      );
    } catch (e) {
      debugPrint('📂 read_file 失败: $e');
      // 可能是二进制文件
      if (e is FileSystemException) {
        return SkillResult.fail('无法读取文件（可能是二进制文件）: $e');
      }
      return SkillResult.fail('读取文件失败: $e');
    }
  }
}
