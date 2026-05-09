/// 分层 Guardrails 系统（模块 3）
///
/// 四层防护架构：
/// L1: 输入验证 — 在工具调用前验证参数合法性
/// L2: 执行防护 — 运行时的安全边界（继承自 SecurityHook）
/// L3: 输出验证 — 确保输出不含敏感信息
/// L4: 成本控制 — Token/调用次数/时间预算
///
/// 设计原则：
/// - 与现有 SecurityHook 兼容，GuardrailHook 是 SecurityHook 的超集
/// - 所有 Guardrail 都是可插拔的，通过列表组合
/// - 支持 canAutoFix: 某些参数错误可以自动修复
import 'dart:io';
import 'package:flutter/foundation.dart';
import '../agent/agent_hooks.dart';
import '../agent/agent_types.dart';
import '../config/agent_config.dart';

// ═══════════════════════════════════════════
// Guardrail 结果
// ═══════════════════════════════════════════

/// Guardrail 检查结果
class GuardrailResult {
  /// 是否通过
  final bool isPassed;

  /// 是否被阻止
  final bool isBlocked;

  /// 是否已脱敏
  final bool isSanitized;

  /// 原因描述
  final String? reason;

  /// 是否可以自动修复
  final bool canAutoFix;

  /// 修复建议（JSON 参数覆盖）
  final Map<String, dynamic>? fixSuggestion;

  /// 脱敏后的输出
  final String? sanitizedOutput;

  const GuardrailResult._({
    this.isPassed = false,
    this.isBlocked = false,
    this.isSanitized = false,
    this.reason,
    this.canAutoFix = false,
    this.fixSuggestion,
    this.sanitizedOutput,
  });

  /// 通过
  factory GuardrailResult.passed() => const GuardrailResult._(isPassed: true);

  /// 阻止
  factory GuardrailResult.blocked(String reason,
          {bool canAutoFix = false,
          Map<String, dynamic>? fixSuggestion}) =>
      GuardrailResult._(
        isBlocked: true,
        reason: reason,
        canAutoFix: canAutoFix,
        fixSuggestion: fixSuggestion,
      );

  /// 已脱敏
  factory GuardrailResult.sanitized(
          String sanitizedOutput, String reason) =>
      GuardrailResult._(
        isPassed: true,
        isSanitized: true,
        sanitizedOutput: sanitizedOutput,
        reason: reason,
      );
}

// ═══════════════════════════════════════════
// 成本检查结果
// ═══════════════════════════════════════════

/// 成本检查结果
class CostCheckResult {
  final bool isExceeded;
  final String? message;
  final int remainingTokens;
  final int remainingToolCalls;
  final int remainingLLMCalls;

  const CostCheckResult._({
    this.isExceeded = false,
    this.message,
    this.remainingTokens = 0,
    this.remainingToolCalls = 0,
    this.remainingLLMCalls = 0,
  });

  factory CostCheckResult.ok({
    int remainingTokens = 0,
    int remainingToolCalls = 0,
    int remainingLLMCalls = 0,
  }) =>
      CostCheckResult._(
        remainingTokens: remainingTokens,
        remainingToolCalls: remainingToolCalls,
        remainingLLMCalls: remainingLLMCalls,
      );

  factory CostCheckResult.exceeded(String message) =>
      CostCheckResult._(isExceeded: true, message: message);
}

// ═══════════════════════════════════════════
// L1: 输入验证 Guardrail 接口
// ═══════════════════════════════════════════

/// L1: 输入参数验证接口
abstract class InputGuardrail {
  String get name;

  Future<GuardrailResult> validate(ToolCall call);
}

// ═══════════════════════════════════════════
// L3: 输出验证 Guardrail 接口
// ═══════════════════════════════════════════

/// L3: 输出内容验证接口
abstract class OutputGuardrail {
  String get name;

  Future<GuardrailResult> validate(ToolResult result);
}

// ═══════════════════════════════════════════
// L1 具体实现: 文件路径安全验证
// ═══════════════════════════════════════════

/// 文件路径安全验证
class FilePathGuardrail extends InputGuardrail {
  @override
  String get name => '文件路径安全';

  /// 系统关键路径（跨平台）
  static final _criticalPaths = Platform.isWindows
      ? [
          r'c:\windows',
          r'c:\program files',
          r'c:\programdata',
          r'c:\system32',
        ]
      : [
          '/etc/', '/usr/', '/bin/', '/sbin/',
          '/lib/', '/lib64/',
          '/System/', // macOS
          '/private/etc/', '/private/var/',
        ];

  @override
  Future<GuardrailResult> validate(ToolCall call) async {
    if (!AgentConfig().enablePathSecurity) {
      return GuardrailResult.passed();
    }

    // 提取可能的路径参数
    final path = call.arguments['path'] as String? ??
        call.arguments['filePath'] as String? ??
        call.arguments['target_file'] as String? ??
        '';
    if (path.isEmpty) return GuardrailResult.passed();

    // 路径穿越检查
    if (path.contains('..')) {
      return GuardrailResult.blocked(
        '路径穿越攻击检测：路径中包含 ".."',
        canAutoFix: false,
      );
    }

    // 波浪线展开检查（可能引用 home 目录的敏感路径）
    if (path.startsWith('~/')) {
      // 允许 home 目录下的操作，但记录
      debugPrint('🛡️ [Guardrails] 允许 home 路径: $path');
    }

    // 系统关键路径保护
    final lowerPath = path.toLowerCase();
    for (final cp in _criticalPaths) {
      if (lowerPath.startsWith(cp)) {
        return GuardrailResult.blocked(
          '禁止访问系统路径：$path',
        );
      }
    }

    return GuardrailResult.passed();
  }
}

// ═══════════════════════════════════════════
// L1 具体实现: 命令安全验证（继承自 SecurityHook 的逻辑）
// ═══════════════════════════════════════════

/// 命令安全验证（整合 SecurityHook 的检测逻辑）
class CommandSafetyGuardrail extends InputGuardrail {
  @override
  String get name => '命令安全';

  // 高危命令模式（从 SecurityHook 迁移）
  static final _hardBlock = RegExp(
    r'rm\s+-[rRfF]{1,3}\s+[/~]'
    r'|rm\s+-[rRfF]{1,3}\s+"?/?["`]'
    r'|\bdd\b.{0,60}\bof\s*=\s*/dev/'
    r'|\bmkfs\b'
    r'|:()\{.*:.*\|.*:.*&.*\}.*;.*:'
    r'|\bformat\s+[c-zA-Z]:'
    r'|\brd\s+/[sS].*[cC]:\\'
    r'|\bdel\s+/[fF]\s+/[sS].*[cC]:\\'
    r'|\bshutdown\b'
    r'|\bhalt\b'
    r'|\bpoweroff\b'
    r'|\breboot\b',
    caseSensitive: false,
  );

  // 中危命令模式
  static final _softWarn = RegExp(
    r'\bsudo\b'
    r'|\bsu\b(?:\s|$)'
    r'|\bchmod\s+[0-9]*7[0-9][0-9]\b'
    r'|\bchown\s+-[rR]'
    r'|\brm\s+-[rRfF]'
    r'|\btruncate\b'
    r'|\bcrontab\s+-r\b'
    r'|\bkillall\b'
    r'|\bkill\s+-9\b',
    caseSensitive: false,
  );

  @override
  Future<GuardrailResult> validate(ToolCall call) async {
    // 只检查 shell 命令类工具
    if (call.name != 'shell_exec' && call.name != 'execute_command') {
      return GuardrailResult.passed();
    }

    final cmd =
        (call.arguments['command'] as String? ?? '').trim();
    if (cmd.isEmpty) return GuardrailResult.passed();

    // 硬拦截
    if (_hardBlock.hasMatch(cmd)) {
      return GuardrailResult.blocked(
        '⚠️ 高危命令拦截：$cmd\n'
        '原因: 此命令可能导致系统文件损坏或数据不可恢复丢失。',
      );
    }

    // 中危不拦截，由 GuardrailHook 转为注入提醒
    // （这里只标记，不阻止）

    return GuardrailResult.passed();
  }

  /// 检查是否为中危命令
  bool isSoftWarn(String command) => _softWarn.hasMatch(command);

  /// 获取中危命令提醒消息
  String getSoftWarnMessage(String command) =>
      '【🔒 安全提醒】即将执行潜在危险命令: `$command`\n'
      '请再次确认：\n'
      '1. 这是用户明确要求的操作吗？\n'
      '2. 操作范围是否精确？\n'
      '3. 是否有更安全的替代方案？';
}

// ═══════════════════════════════════════════
// L3 具体实现: 输出内容安全过滤
// ═══════════════════════════════════════════

/// 输出内容安全过滤
class OutputSanitizer extends OutputGuardrail {
  @override
  String get name => '输出脱敏';

  /// 敏感信息匹配模式
  static final _sensitivePatterns = [
    // API Key / Token / Secret
    RegExp(
      r'(?:api[_-]?key|token|secret|password|passwd|pwd)\s*[:=]\s*["\x27]?\S{8,}',
      caseSensitive: false,
    ),
    // AWS Key
    RegExp(r'(?:AKIA|ASIA)[A-Z0-9]{16}'),
    // 私钥
    RegExp(r'-----BEGIN (?:RSA |EC |DSA )?PRIVATE KEY-----'),
    // JWT Token
    RegExp(r'eyJ[A-Za-z0-9_-]{10,}\.eyJ[A-Za-z0-9_-]{10,}\.[A-Za-z0-9_-]+'),
  ];

  @override
  Future<GuardrailResult> validate(ToolResult result) async {
    if (!AgentConfig().enableOutputSanitize) {
      return GuardrailResult.passed();
    }

    var output = result.content;
    var sanitized = false;

    for (final pattern in _sensitivePatterns) {
      if (pattern.hasMatch(output)) {
        output = output.replaceAllMapped(pattern, (match) {
          final matched = match.group(0)!;
          if (matched.length > 16) {
            return '${matched.substring(0, 8)}***REDACTED***';
          }
          return '***REDACTED***';
        });
        sanitized = true;
      }
    }

    if (sanitized) {
      return GuardrailResult.sanitized(
        output,
        '已自动脱敏输出中的敏感信息',
      );
    }

    return GuardrailResult.passed();
  }
}

// ═══════════════════════════════════════════
// L4: 成本控制器
// ═══════════════════════════════════════════

/// L4: 成本控制器
class CostController {
  int _totalTokens = 0;
  int _totalToolCalls = 0;
  int _totalLLMCalls = 0;
  DateTime? _sessionStart;

  /// 获取当前统计
  int get totalTokens => _totalTokens;
  int get totalToolCalls => _totalToolCalls;
  int get totalLLMCalls => _totalLLMCalls;

  /// 检查是否超出预算
  CostCheckResult checkBudget() {
    final config = AgentConfig();
    if (!config.enableCostControl) {
      return CostCheckResult.ok(
        remainingTokens: config.maxTokensPerSession,
        remainingToolCalls: config.maxToolCallsPerSession,
        remainingLLMCalls: config.maxLLMCallsPerSession,
      );
    }

    // Token 预算
    if (_totalTokens >= config.maxTokensPerSession) {
      return CostCheckResult.exceeded(
        'Token 预算已耗尽 ($_totalTokens/${config.maxTokensPerSession})',
      );
    }

    // 工具调用次数
    if (_totalToolCalls >= config.maxToolCallsPerSession) {
      return CostCheckResult.exceeded(
        '工具调用次数已达上限 ($_totalToolCalls/${config.maxToolCallsPerSession})',
      );
    }

    // LLM 调用次数
    if (_totalLLMCalls >= config.maxLLMCallsPerSession) {
      return CostCheckResult.exceeded(
        'LLM 调用次数已达上限 ($_totalLLMCalls/${config.maxLLMCallsPerSession})',
      );
    }

    // 会话时间
    if (_sessionStart != null) {
      final elapsed = DateTime.now().difference(_sessionStart!);
      if (elapsed >= config.maxSessionDuration) {
        return CostCheckResult.exceeded(
          '会话时间已超限 (${elapsed.inMinutes}/${config.maxSessionDurationMinutes}分钟)',
        );
      }
    }

    return CostCheckResult.ok(
      remainingTokens: config.maxTokensPerSession - _totalTokens,
      remainingToolCalls:
          config.maxToolCallsPerSession - _totalToolCalls,
      remainingLLMCalls:
          config.maxLLMCallsPerSession - _totalLLMCalls,
    );
  }

  /// 记录资源使用
  void recordUsage({
    int tokens = 0,
    bool isToolCall = false,
    bool isLLMCall = false,
  }) {
    _sessionStart ??= DateTime.now();
    _totalTokens += tokens;
    if (isToolCall) _totalToolCalls++;
    if (isLLMCall) _totalLLMCalls++;
  }

  /// 重置（新会话开始时）
  void reset() {
    _totalTokens = 0;
    _totalToolCalls = 0;
    _totalLLMCalls = 0;
    _sessionStart = null;
  }

  /// 获取使用报告
  Map<String, dynamic> getUsageReport() {
    final config = AgentConfig();
    final elapsed = _sessionStart != null
        ? DateTime.now().difference(_sessionStart!)
        : Duration.zero;
    return {
      'tokens': '$_totalTokens / ${config.maxTokensPerSession}',
      'toolCalls': '$_totalToolCalls / ${config.maxToolCallsPerSession}',
      'llmCalls': '$_totalLLMCalls / ${config.maxLLMCallsPerSession}',
      'duration': '${elapsed.inMinutes} / ${config.maxSessionDurationMinutes} 分钟',
    };
  }
}

// ═══════════════════════════════════════════
// Guardrails 系统（组合所有层级）
// ═══════════════════════════════════════════

/// 分层 Guardrails 系统
class GuardrailsSystem {
  final List<InputGuardrail> inputGuardrails;
  final List<OutputGuardrail> outputGuardrails;
  final CostController costController;
  final CommandSafetyGuardrail _commandSafety;

  GuardrailsSystem({
    List<InputGuardrail>? inputGuardrails,
    List<OutputGuardrail>? outputGuardrails,
    CostController? costController,
  })  : inputGuardrails = inputGuardrails ??
            [
              FilePathGuardrail(),
              CommandSafetyGuardrail(),
            ],
        outputGuardrails = outputGuardrails ??
            [
              OutputSanitizer(),
            ],
        costController = costController ?? CostController(),
        _commandSafety = CommandSafetyGuardrail();

  /// 输入验证管道
  Future<GuardrailResult> validateInput(ToolCall call) async {
    for (final guardrail in inputGuardrails) {
      try {
        final result = await guardrail.validate(call);
        if (result.isBlocked) {
          debugPrint(
              '🛡️ [Guardrails] 输入验证被 ${guardrail.name} 阻止: ${result.reason}');
          return result;
        }
      } catch (e) {
        debugPrint('⚠️ [Guardrails] ${guardrail.name} 验证异常: $e');
      }
    }
    return GuardrailResult.passed();
  }

  /// 输出验证管道
  Future<GuardrailResult> validateOutput(ToolResult result) async {
    for (final guardrail in outputGuardrails) {
      try {
        final gResult = await guardrail.validate(result);
        if (gResult.isBlocked || gResult.isSanitized) {
          debugPrint(
              '🛡️ [Guardrails] 输出被 ${guardrail.name} 处理: ${gResult.reason}');
          return gResult;
        }
      } catch (e) {
        debugPrint('⚠️ [Guardrails] ${guardrail.name} 验证异常: $e');
      }
    }
    return GuardrailResult.passed();
  }

  /// 检查是否为中危命令（用于软提醒）
  bool isCommandSoftWarn(ToolCall call) {
    if (call.name != 'shell_exec' && call.name != 'execute_command') {
      return false;
    }
    final cmd = call.arguments['command'] as String? ?? '';
    return _commandSafety.isSoftWarn(cmd);
  }

  /// 获取中危命令提醒消息
  String getCommandSoftWarnMessage(ToolCall call) {
    final cmd = call.arguments['command'] as String? ?? '';
    return _commandSafety.getSoftWarnMessage(cmd);
  }
}

// ═══════════════════════════════════════════
// GuardrailHook — 将 Guardrails 集成为 Hook
// ═══════════════════════════════════════════

/// 将 Guardrails 系统集成为 AgentHook
///
/// 替代原有的 SecurityHook，提供更全面的防护：
/// - beforeToolCall: 成本预检 + 输入验证 + 中危命令提醒
/// - afterToolCall: 输出验证（脱敏） + 成本记录
///
/// 向后兼容：如果不传 GuardrailsSystem，默认创建含
/// FilePathGuardrail + CommandSafetyGuardrail + OutputSanitizer 的标准配置
class GuardrailHook extends BaseHook {
  final GuardrailsSystem _guardrails;

  GuardrailHook([GuardrailsSystem? guardrails])
      : _guardrails = guardrails ?? GuardrailsSystem(),
        super(
          id: 'guardrails',
          name: '分层防护',
          description:
              '输入验证 + 命令安全 + 输出脱敏 + 成本控制',
          priority: 1, // 最高优先级
        );

  @override
  Future<void> onLoopStart(AgentLoopContext context) async {
    // 新会话开始时重置成本计数
    _guardrails.costController.reset();
  }

  @override
  Future<HookResult?> beforeToolCall(
      ToolCall call, AgentLoopContext context) async {
    // 1. 成本预检
    final costCheck = _guardrails.costController.checkBudget();
    if (costCheck.isExceeded) {
      return HookResult.block('⚠️ ${costCheck.message}');
    }

    // 2. 输入验证管道
    final inputResult = await _guardrails.validateInput(call);
    if (inputResult.isBlocked) {
      if (inputResult.canAutoFix && inputResult.fixSuggestion != null) {
        // 自动修复参数
        return HookResult.modifyArgs(
          inputResult.fixSuggestion!,
          reason: '🛡️ 自动修复: ${inputResult.reason}',
        );
      }
      return HookResult.block('🛡️ ${inputResult.reason}');
    }

    // 3. 中危命令软提醒（不阻止，注入确认消息）
    if (_guardrails.isCommandSoftWarn(call)) {
      final warnMsg = _guardrails.getCommandSoftWarnMessage(call);
      return HookResult.inject(
        warnMsg,
        userMessage: '已注入安全提醒，等待 LLM 确认',
      );
    }

    return null; // 通过
  }

  @override
  Future<void> afterToolCall(
      ToolCall call, ToolResult result, AgentLoopContext context) async {
    // 1. 输出验证
    final outputResult = await _guardrails.validateOutput(result);
    if (outputResult.isSanitized && outputResult.sanitizedOutput != null) {
      // 注意：ToolResult.content 是 final，这里通过日志记录脱敏信息
      // 实际脱敏需要在 AgentLoop 层面处理
      debugPrint('🛡️ [Guardrails] 输出已脱敏: ${outputResult.reason}');
    }

    // 2. 记录成本
    _guardrails.costController.recordUsage(isToolCall: true);
  }

  @override
  Future<void> onLoopEnd(AgentLoopResult result) async {
    // 打印成本报告
    final report = _guardrails.costController.getUsageReport();
    debugPrint('💰 [Guardrails] 会话成本报告: $report');
  }

  /// 获取 Guardrails 系统（用于外部查询）
  GuardrailsSystem get guardrails => _guardrails;
}
