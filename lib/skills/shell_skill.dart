import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'package:flutter/foundation.dart';
import 'package:path/path.dart' as p;
import 'skill_base.dart';
import 'skill_file_utils.dart';

/// 通用 Shell 执行技能
/// 统一使用 command 参数执行所有命令，在 workingDirectory 下运行
class ShellExecSkill extends GooseSkill {
  ShellExecSkill();

  @override
  String get id => 'shell_exec';

  @override
  String get name => 'Shell 执行器';

  @override
  String get description =>
      '在本地执行 shell 命令，并获取输出结果。'
      '使用 `command` 参数传入要执行的命令，如：'
      '`python generate_ppt.py`、`pip install requests`、`dir`、`echo hello` 等。'
      '【推荐流程】先用 `write_file` 将代码写入 .py 文件，再用 `command` 执行，如 `command: "python my_script.py"`。'
      '【重要】command 中的脚本文件只需传文件名，不要拼接路径，系统会在工作目录下自动找到。'
      '【禁止】不要用 python -c "..." 等内联多行代码方式。'
      '如果指定了 working_dir，执行后生成的文件会自动收集并展示给用户。';

  @override
  String get icon => '💻';

  @override
  String get category => '内置工具';

  @override
  List<SkillParam> get params => [
        const SkillParam(
          name: 'command',
          description: '要执行的 shell 命令。多条命令可用 && 连接。'
              '执行脚本时只需写文件名，如 "python my_script.py"，不需要写完整路径。'
              '【禁止】不要用 python -c "..." 传递多行代码。',
          type: 'string',
          required: true,
        ),
        const SkillParam(
          name: 'working_dir',
          description:
              '可选：指定工作目录路径。执行后程序会自动收集该目录中新生成的文件。'
              '如果不指定，则使用会话默认工作目录。',
          type: 'string',
          required: false,
        ),
        const SkillParam(
          name: 'timeout',
          description: '可选：命令超时时间（秒），默认 120 秒。',
          type: 'int',
          required: false,
        ),
      ];

  /// 清理命令中的绝对路径：提取纯文件名，让 workingDirectory 处理定位
  String _sanitizeCommand(String command) {
    var cmd = command;

    // 去掉命令中所有引号包裹的绝对路径 → 替换为纯文件名
    // 匹配 "C:\...\file.ext" 或 'C:\...\file.ext'
    cmd = cmd.replaceAllMapped(
      RegExp(r'''["']([A-Za-z]:[/\\][^"']+)["']'''),
      (m) {
        final absPath = m.group(1)!;
        final fileName = absPath.split(RegExp(r'[/\\]')).last;
        debugPrint('💻 路径清理(引号包裹): "$absPath" → "$fileName"');
        return '"$fileName"';
      },
    );

    // 匹配不带引号的绝对路径（空格前后界定）
    cmd = cmd.replaceAllMapped(
      RegExp(r'(?<=\s|^)([A-Za-z]:[/\\]\S+\.[\w]{1,5})(?=\s|$)'),
      (m) {
        final absPath = m.group(1)!;
        final fileName = absPath.split(RegExp(r'[/\\]')).last;
        debugPrint('💻 路径清理(裸路径): "$absPath" → "$fileName"');
        return fileName;
      },
    );

    return cmd;
  }

  @override
  Future<SkillResult> execute(Map<String, dynamic> args, {void Function(String line)? onOutput}) async {
    // 兼容旧的 script 参数：如果传了 script 没传 command，自动转换
    String command = args['command'] as String? ?? '';
    final script = args['script'] as String? ?? '';

    if (command.trim().isEmpty && script.trim().isNotEmpty) {
      // 旧 script 模式兼容：提取纯文件名，自动推断解释器
      String cleaned = script.replaceAll('"', '').replaceAll("'", '').trim();
      final fileName = cleaned.split(RegExp(r'[/\\]')).last.trim();
      if (fileName.isEmpty) {
        return SkillResult.fail('无法从 script 参数提取文件名: "$script"');
      }
      final ext = p.extension(fileName).toLowerCase();
      String interp = args['interpreter'] as String? ?? '';
      if (interp.isEmpty) {
        interp = Platform.isWindows
            ? const {'.py': 'python', '.bat': 'cmd /c', '.cmd': 'cmd /c', '.ps1': 'powershell', '.js': 'node', '.sh': 'bash'}[ext] ?? 'cmd /c'
            : const {'.py': 'python3', '.sh': 'bash', '.js': 'node'}[ext] ?? 'bash';
      }
      command = '$interp $fileName';
      debugPrint('💻 shell_exec 兼容 script→command: "$script" → "$command"');
    }

    if (command.trim().isEmpty) {
      return SkillResult.fail('未提供 command 参数');
    }

    try {
      final workDir = SkillFileUtils.stripPathQuotes(args['working_dir'] as String? ?? '');
      final timeoutSec = (args['timeout'] as int?) ?? 120;

      // 清理命令中的绝对路径
      final actualCommand = _sanitizeCommand(command);

      // 确定工作目录
      final effectiveWorkDir = workDir.isNotEmpty
          ? workDir
          : SkillFileUtils.effectiveWorkingDir;

      debugPrint('💻 shell_exec: "$actualCommand" (workDir=$effectiveWorkDir, timeout=${timeoutSec}s)');

      // 记录工作目录中的已有文件（用于 diff）
      final existingFiles = await SkillFileUtils.listFilePaths(effectiveWorkDir);

      // 使用 Process.start 实现流式输出
      final isWindows = Platform.isWindows;
      final process = await Process.start(
        isWindows ? 'cmd' : 'bash',
        [isWindows ? '/c' : '-c', actualCommand],
        workingDirectory: effectiveWorkDir,
      );

      // 流式收集 stdout/stderr
      final stdoutBuffer = StringBuffer();
      final stderrBuffer = StringBuffer();

      // stdout 实时流式输出（allowMalformed 容忍 GBK 等非 UTF-8 字节）
      final stdoutDone = Completer<void>();
      process.stdout
          .transform(const Utf8Decoder(allowMalformed: true))
          .transform(const LineSplitter())
          .listen(
        (line) {
          stdoutBuffer.writeln(line);
          // 实时推送输出行给调用方
          onOutput?.call(line);
        },
        onDone: () => stdoutDone.complete(),
        onError: (e) {
          if (!stdoutDone.isCompleted) stdoutDone.completeError(e);
        },
      );

      // stderr 实时流式输出（allowMalformed 容忍 GBK 等非 UTF-8 字节）
      final stderrDone = Completer<void>();
      process.stderr
          .transform(const Utf8Decoder(allowMalformed: true))
          .transform(const LineSplitter())
          .listen(
        (line) {
          stderrBuffer.writeln(line);
          onOutput?.call(line);
        },
        onDone: () => stderrDone.complete(),
        onError: (e) {
          if (!stderrDone.isCompleted) stderrDone.completeError(e);
        },
      );

      // 等待进程结束，带超时
      final exitCode = await process.exitCode
          .timeout(Duration(seconds: timeoutSec));

      // 等待所有输出流关闭
      await Future.wait([
        stdoutDone.future,
        stderrDone.future,
      ]).timeout(const Duration(seconds: 5), onTimeout: () => <void>[]);

      final stdout = stdoutBuffer.toString().trim();
      final stderr = stderrBuffer.toString().trim();

      // 收集新生成的文件
      final outputFiles = await SkillFileUtils.collectNewFiles(effectiveWorkDir, existingFiles);

      // 构建结果消息
      final sb = StringBuffer();
      if (exitCode == 0) {
        sb.writeln('✅ 执行成功 (exit code: 0)');
        if (stdout.isNotEmpty) {
          sb.writeln('\n📤 输出:\n```\n$stdout\n```');
        }
        if (outputFiles.isNotEmpty) {
          sb.writeln('\n📁 生成了 ${outputFiles.length} 个文件:');
          for (final f in outputFiles) {
            sb.writeln('  • ${f['name']} (${SkillFileUtils.formatSize(f['size'] as int)})');
          }
        }
      } else {
        sb.writeln('❌ 执行失败 (exit code: $exitCode)');
        if (exitCode == 9009) {
          sb.writeln('\n💡 提示: exit code 9009 表示 Windows 找不到指定的程序或命令。');
          final cmdLower = actualCommand.toLowerCase();
          if (cmdLower.startsWith('python ') || cmdLower.startsWith('python3 ')) {
            final pythonPath = await SkillFileUtils.detectPythonPath();
            if (pythonPath != null) {
              sb.writeln('   ⚠️ `python` 不在 PATH 中，请改用: `$pythonPath`');
            } else {
              sb.writeln('   ⚠️ `python` 不在 PATH 中，尝试用 `py` 替代');
            }
          } else if (cmdLower.startsWith('pip ') || cmdLower.startsWith('pip3 ')) {
            sb.writeln('   ⚠️ `pip` 不在 PATH 中，尝试 `py -m pip` 替代');
          } else {
            sb.writeln('   请检查: 1) 程序是否已安装  2) 是否已加入系统 PATH');
          }
        } else if (exitCode == 103) {
          sb.writeln('\n💡 提示: exit code 103 表示 py launcher 找不到指定的 Python 版本。');
        } else if (exitCode == 1) {
          sb.writeln('\n💡 提示: 程序运行出错，请查看下方错误信息。');
        } else if (exitCode == 2) {
          sb.writeln('\n💡 提示: exit code 2 通常表示文件未找到或语法错误。');
        }
        if (stderr.isNotEmpty) {
          sb.writeln('\n错误信息:\n```\n$stderr\n```');
        }
        if (stdout.isNotEmpty) {
          sb.writeln('\n标准输出:\n```\n$stdout\n```');
        }
        if (stderr.isEmpty && stdout.isEmpty) {
          sb.writeln('\n⚠️ 没有输出信息。工作目录: $effectiveWorkDir');
          sb.writeln('   执行的命令: $actualCommand');
        }
      }

      debugPrint('💻 shell_exec 结果: exit=$exitCode, '
          'stdout=${stdout.length} chars, files=${outputFiles.length}');

      return SkillResult.ok(
        sb.toString(),
        data: {
          'exitCode': exitCode,
          'stdout': stdout,
          'stderr': stderr,
          'command': actualCommand,
          'outputFiles': outputFiles,
          'workingDir': effectiveWorkDir,
        },
        onOutput: onOutput,
      );
    } on TimeoutException {
      return SkillResult.fail('命令执行超时，请尝试增大 timeout 参数或优化命令');
    } catch (e) {
      debugPrint('💻 shell_exec 异常: $e');
      return SkillResult.fail('❌ 命令执行出错: $e');
    }
  }
}
