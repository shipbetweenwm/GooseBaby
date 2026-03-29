/// 安全 Hook — 危险命令拦截
///
/// 职责：
/// 1. [硬拦截] 高危命令（删除系统目录、格式化磁盘、fork bomb 等）→ HookResult.block
/// 2. [软提醒] 中危命令（sudo、chmod 777、rm -r 等）→ HookResult.inject，让 LLM 自审
/// 3. [路径提醒] write_file 写入系统目录时直接 block
///
/// 此 Hook 优先级设为 1，最先执行，保证安全检查在所有其他逻辑之前触发。
library;

import 'dart:io';
import 'package:flutter/foundation.dart';
import 'agent_hooks.dart';
import 'agent_types.dart';

class SecurityHook extends BaseHook {
  SecurityHook()
      : super(
          id: 'security',
          name: '安全拦截',
          description: '拦截高危命令，软提醒中危命令，防止 Agent 误操作系统文件',
          priority: 1, // 最高优先级，所有 Hook 中最先执行
        );

  // ── 高危：直接 block，无论用户如何要求 ──
  // macOS/Linux: rm -rf /、rm -rf ~、dd of=/dev/*、mkfs、fork bomb
  // Windows: format C:、rd /s /q C:\、del /f /s /q C:\
  // 通用: shutdown/halt/reboot（防止误关机）
  static final _hardBlock = RegExp(
    r'rm\s+-[rRfF]{1,3}\s+[/~]'      // rm -rf / 或 rm -rf ~
    r'|rm\s+-[rRfF]{1,3}\s+"?/?["`]' // rm -rf "/"
    r'|\bdd\b.{0,60}\bof\s*=\s*/dev/' // dd ... of=/dev/xxx
    r'|\bmkfs\b'                       // mkfs（格式化文件系统）
    r'|:()\{.*:.*\|.*:.*&.*\}.*;.*:'  // fork bomb: :(){ :|:& };:
    r'|\bformat\s+[c-zA-Z]:'          // Windows: format C:
    r'|\brd\s+/[sS].*[cC]:\\'         // Windows: rd /s /q C:\
    r'|\bdel\s+/[fF]\s+/[sS].*[cC]:\\'// Windows: del /f /s /q C:\
    r'|\bshutdown\b'                   // shutdown
    r'|\bhalt\b'                       // halt
    r'|\bpoweroff\b'                   // poweroff
    r'|\breboot\b',                    // reboot
    caseSensitive: false,
  );

  // ── 中危：注入提醒，让 LLM 二次确认 ──
  // sudo、su、chmod 777、chown -R、rm -r（非根目录）、mv 覆盖、truncate
  static final _softWarn = RegExp(
    r'\bsudo\b'                         // sudo
    r'|\bsu\b(?:\s|$)'                  // su（单独命令）
    r'|\bchmod\s+[0-9]*7[0-9][0-9]\b'  // chmod 777/775/...
    r'|\bchown\s+-[rR]'                 // chown -R
    r'|\brm\s+-[rRfF]'                  // rm -r/rf（中危，非根目录）
    r'|\btruncate\b'                    // truncate（清空文件）
    r'|\bcrontab\s+-r\b'                // crontab -r（删除定时任务）
    r'|\bkillall\b'                     // killall
    r'|\bkill\s+-9\b',                  // kill -9
    caseSensitive: false,
  );

  // ── write_file 系统目录黑名单（跨平台）──
  static final _systemPathPrefixes = Platform.isWindows
      ? [
          r'c:\windows',
          r'c:\program files',
          r'c:\programdata',
          r'c:\system32',
        ]
      : [
          '/etc/',
          '/usr/',
          '/bin/',
          '/sbin/',
          '/lib/',
          '/lib64/',
          '/System/',        // macOS
          '/private/etc/',   // macOS
          '/private/var/',   // macOS
          '/Applications/',  // macOS 应用目录
        ];

  @override
  Future<HookResult?> beforeToolCall(ToolCall call, AgentLoopContext context) async {
    switch (call.name) {
      case 'shell_exec':
        return _checkShellCommand(call);
      case 'write_file':
        return _checkWritePath(call);
      default:
        return null;
    }
  }

  HookResult? _checkShellCommand(ToolCall call) {
    final cmd = (call.arguments['command'] as String? ?? '').trim();
    if (cmd.isEmpty) return null;

    // 硬拦截
    if (_hardBlock.hasMatch(cmd)) {
      debugPrint('🔒 [Security] 硬拦截高危命令: $cmd');
      return HookResult.block(
        '⚠️ 安全拦截：检测到高危命令，已阻止执行。\n'
        '命令: `$cmd`\n'
        '原因: 此命令可能导致系统文件损坏或数据不可恢复丢失。\n'
        '如果用户明确需要此操作，请告知用户手动在终端执行，鹅宝不会代为运行。',
      );
    }

    // 软提醒
    if (_softWarn.hasMatch(cmd)) {
      debugPrint('🔒 [Security] 软提醒中危命令: $cmd');
      return HookResult.inject(
        '【🔒 安全提醒】即将执行潜在危险命令: `$cmd`\n'
        '请再次确认：\n'
        '1. 这是用户明确要求的操作吗？\n'
        '2. 操作范围是否精确（路径/目标正确）？\n'
        '3. 是否有更安全的替代方案？\n'
        '如果不确定，请先告知用户操作后果再执行。',
        userMessage: '已注入安全提醒，等待 LLM 确认',
      );
    }

    return null;
  }

  HookResult? _checkWritePath(ToolCall call) {
    final rawPath = (call.arguments['path'] as String? ?? '').trim().toLowerCase();
    if (rawPath.isEmpty) return null;

    for (final prefix in _systemPathPrefixes) {
      if (rawPath.startsWith(prefix)) {
        debugPrint('🔒 [Security] 阻止写入系统目录: $rawPath');
        return HookResult.block(
          '⚠️ 安全拦截：不允许写入系统目录。\n'
          '目标路径: `${call.arguments['path']}`\n'
          '原因: 写入系统目录可能破坏操作系统或应用程序。\n'
          '请将文件写入用户目录（如桌面、文稿、工作目录等）。',
        );
      }
    }

    return null;
  }
}
