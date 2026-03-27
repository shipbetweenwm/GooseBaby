/// 失败经验自动检索 Hook
/// 
/// 核心功能：
/// 1. 工具调用前自动检索相关失败经验，注入提示
/// 2. 工具失败后自动保存失败经验
/// 3. 工具成功后关联之前的失败，保存「失败+解决方案」
/// 4. 高频失败经验自动升级为永久记忆

import 'dart:async';
import 'package:flutter/foundation.dart';
import 'agent_hooks.dart';
import 'agent_types.dart';
import '../memory/memory_manager.dart';

/// 失败经验 Hook
class FailureLessonHook extends BaseHook {
  final MemoryManager _memoryManager;
  
  /// 待关联的失败记录（key: 工具名, value: 失败信息）
  final Map<String, _PendingFailure> _pendingFailures = {};
  
  /// 同类工具失败计数（用于触发反省提示）
  final Map<String, int> _toolFailCount = {};
  
  /// 最大连续失败次数（超过后强制停止）
  static const int maxConsecutiveFailures = 3;
  
  /// 启动反省提示的失败次数阈值
  static const int reflectionThreshold = 2;
  
  FailureLessonHook(this._memoryManager)
      : super(
          id: 'failure_lesson',
          name: '失败经验',
          description: '自动检索失败经验并在工具调用前注入提示',
          priority: 10, // 高优先级，先执行
        );
  
  @override
  Future<HookResult?> beforeToolCall(ToolCall call, AgentLoopContext context) async {
    // 跳过思考类工具
    if (_isInternalTool(call.name)) return null;
    
    // 1. 检索相关失败经验
    final relevantFailures = _memoryManager.searchRelevantFailures(call.name, call.arguments);
    
    if (relevantFailures != null && relevantFailures.isNotEmpty) {
      debugPrint('🪝 [FailureLesson] 检索到相关失败经验，注入提示');
      return HookResult.inject(
        _buildInjectionMessage(relevantFailures),
        userMessage: '检测到相关失败经验，已注入提示',
      );
    }
    
    // 2. 检查是否有高频失败经验需要注入
    final highFreqFailures = _memoryManager.getFailureLessonsContext();
    if (highFreqFailures.isNotEmpty && context.currentTurn == 0) {
      // 首轮注入高频失败经验
      debugPrint('🪝 [FailureLesson] 注入高频失败经验');
      return HookResult.inject(
        '\n$highFreqFailures',
        userMessage: '已注入高频失败经验',
      );
    }
    
    return null;
  }
  
  @override
  Future<void> afterToolCall(ToolCall call, ToolResult result, AgentLoopContext context) async {
    if (_isInternalTool(call.name)) return;
    
    if (result.isError) {
      // 工具失败 → 缓存失败信息
      _handleToolFailure(call, result, context);
    } else {
      // 工具成功 → 检查是否需要关联之前的失败
      _handleToolSuccess(call, result, context);
    }
  }
  
  /// 处理工具失败
  void _handleToolFailure(ToolCall call, ToolResult result, AgentLoopContext context) {
    // 记录失败
    context.recordFailedToolCall(call, result.content);
    
    // 累计失败次数
    _toolFailCount[call.name] = (_toolFailCount[call.name] ?? 0) + 1;
    
    // 缓存失败信息（等待可能的后续成功）
    _pendingFailures[call.id] = _PendingFailure(
      toolName: call.name,
      summary: _buildSummary(call),
      error: result.content,
      arguments: Map.from(call.arguments),
      timestamp: DateTime.now(),
    );
    
    debugPrint('🪝 [FailureLesson] 记录失败: ${call.name}');
    
    // 检查是否达到反省阈值
    final failCount = _toolFailCount[call.name] ?? 0;
    if (failCount >= reflectionThreshold) {
      debugPrint('🪝 [FailureLesson] 同工具失败 $failCount 次，建议反省');
    }
  }
  
  /// 处理工具成功
  void _handleToolSuccess(ToolCall call, ToolResult result, AgentLoopContext context) {
    // 重置失败计数
    _toolFailCount.remove(call.name);
    
    // ── 失效相关的旧失败经验（环境可能已变化） ──
    _memoryManager.invalidateRelatedFailures(call.name, call.arguments);
    
    // 查找是否有待关联的失败记录
    if (_pendingFailures.isEmpty) return;
    
    // 优先匹配同工具的失败
    _PendingFailure? matchedFailure;
    for (final entry in _pendingFailures.entries) {
      if (entry.value.toolName == call.name) {
        matchedFailure = entry.value;
        _pendingFailures.remove(entry.key);
        break;
      }
    }
    
    // 没有同工具匹配，取最近的失败（说明 LLM 换了思路成功）
    if (matchedFailure == null && _pendingFailures.isNotEmpty) {
      matchedFailure = _pendingFailures.values.last;
      _pendingFailures.remove(_pendingFailures.keys.last);
    }
    
    if (matchedFailure != null) {
      // 构建解决方案描述
      final solution = _buildSolution(matchedFailure, call);
      
      // 保存失败经验（失败+解决方案）
      _memoryManager.saveFailureLesson(
        skillId: matchedFailure.toolName,
        summary: matchedFailure.summary,
        error: matchedFailure.error,
        solution: solution,
      );
      
      debugPrint('🪝 [FailureLesson] 保存失败经验: ${matchedFailure.toolName} → $solution');
    }
  }
  
  /// 构建失败经验注入消息
  String _buildInjectionMessage(String failures) {
    final sb = StringBuffer();
    sb.writeln('【⚠️ 失败经验提示】');
    sb.writeln('在执行类似操作时曾遇到过以下问题，请参考避免：');
    sb.writeln();
    sb.writeln(failures);
    sb.writeln();
    sb.writeln('请根据以上经验调整你的操作方式。如果问题仍然存在，尝试换一种完全不同的方法。');
    return sb.toString();
  }
  
  /// 构建工具调用摘要
  String _buildSummary(ToolCall call) {
    final args = call.arguments;
    final parts = <String>[];
    
    if (args['command'] != null) {
      final cmd = args['command'] as String;
      parts.add(cmd.length > 80 ? '${cmd.substring(0, 80)}...' : cmd);
    } else if (args['path'] != null) {
      parts.add(args['path'] as String);
    } else if (args['script'] != null) {
      final script = args['script'] as String;
      parts.add(script.length > 80 ? '${script.substring(0, 80)}...' : script);
    }
    
    return parts.isEmpty ? call.name : parts.join(' ');
  }
  
  /// 构建解决方案描述
  String _buildSolution(_PendingFailure failure, ToolCall successCall) {
    final sb = StringBuffer();
    
    if (failure.toolName == successCall.name) {
      // 同工具成功（说明换了参数/方式）
      sb.write('同工具修正: ');
      final args = successCall.arguments;
      
      if (args['command'] != null) {
        final cmd = args['command'] as String;
        sb.write('command → ${cmd.length > 100 ? '${cmd.substring(0, 100)}...' : cmd}');
      } else if (args['path'] != null) {
        sb.write('path → ${args['path']}');
      } else if (args['script'] != null) {
        final script = args['script'] as String;
        sb.write('script → ${script.length > 100 ? '${script.substring(0, 100)}...' : script}');
      } else {
        sb.write('参数已调整');
      }
    } else {
      // 换了不同工具成功
      sb.write('换用 ${successCall.name} 解决');
    }
    
    return sb.toString();
  }
  
  /// 判断是否为内部工具（不需要记录失败经验）
  bool _isInternalTool(String toolName) {
    return toolName == 'think' || 
           toolName == 'save_memory' || 
           toolName == 'activate_skill';
  }
  
  /// 获取当前待处理的失败数量
  int get pendingFailureCount => _pendingFailures.length;
  
  /// 清空待处理的失败记录
  void clearPendingFailures() {
    _pendingFailures.clear();
    _toolFailCount.clear();
  }
  
  /// 获取失败统计
  Map<String, int> getFailureStats() {
    return Map.from(_toolFailCount);
  }
}

/// 待关联的失败记录
class _PendingFailure {
  final String toolName;
  final String summary;
  final String error;
  final Map<String, dynamic> arguments;
  final DateTime timestamp;
  
  _PendingFailure({
    required this.toolName,
    required this.summary,
    required this.error,
    required this.arguments,
    required this.timestamp,
  });
}

/// 循环检测 Hook
/// 
/// 检测并阻止循环调用行为：
/// 1. 重复调用相同工具和参数
/// 2. 同工具连续失败过多
/// 3. 工具调用停滞无进展
class LoopDetectionHook extends BaseHook {
  /// 最近调用的签名列表
  final List<String> _recentSignatures = [];
  
  /// 最近结果的长度列表
  final List<int> _recentResultLengths = [];
  
  /// 配置
  static const int maxDuplicateRounds = 3;
  static const int maxStagnantRounds = 4;
  static const int maxConsecutiveFailures = 3;
  
  LoopDetectionHook()
      : super(
          id: 'loop_detection',
          name: '循环检测',
          description: '检测并阻止循环调用行为',
          priority: 5, // 最高优先级
        );
  
  @override
  Future<HookResult?> beforeToolCall(ToolCall call, AgentLoopContext context) async {
    // 检查重复调用
    final signature = call.signature;
    _recentSignatures.add(signature);
    
    if (_recentSignatures.length > maxDuplicateRounds) {
      _recentSignatures.removeAt(0);
    }
    
    // 检测连续重复
    if (_recentSignatures.length >= maxDuplicateRounds &&
        _recentSignatures.toSet().length == 1) {
      debugPrint('🪝 [LoopDetection] 检测到重复调用: $signature');
      return HookResult.inject(
        '【系统警告】检测到你连续 ${maxDuplicateRounds} 轮调用完全相同的工具。'
        '请停止重复，换一种完全不同的方法，或者直接告诉用户当前方法不可行。',
        userMessage: '检测到循环调用，已注入警告',
      );
    }
    
    // 检测同工具连续失败
    final failCount = context.getFailureCount(call.name);
    if (failCount >= maxConsecutiveFailures) {
      debugPrint('🪝 [LoopDetection] 同工具失败过多: ${call.name}');
      return HookResult.block(
        '${call.name} 已连续失败 $failCount 次，请换一种不同的方法。',
      );
    }
    
    return null;
  }
  
  @override
  Future<void> afterToolCall(ToolCall call, ToolResult result, AgentLoopContext context) async {
    // 记录结果长度（用于停滞检测）
    _recentResultLengths.add(result.content.length);
    
    if (_recentResultLengths.length > maxStagnantRounds) {
      _recentResultLengths.removeAt(0);
    }
    
    // 检测停滞
    if (_recentResultLengths.length >= maxStagnantRounds) {
      final avg = _recentResultLengths.reduce((a, b) => a + b) / _recentResultLengths.length;
      final variance = _recentResultLengths
          .map((l) => (l - avg) * (l - avg))
          .reduce((a, b) => a + b) / _recentResultLengths.length;
      
      if (variance < 100) {
        debugPrint('🪝 [LoopDetection] 检测到停滞: 方差=$variance');
      }
    }
  }
  
  /// 重置检测状态
  void reset() {
    _recentSignatures.clear();
    _recentResultLengths.clear();
  }
}

/// 工具执行超时 Hook
class TimeoutHook extends BaseHook {
  final Duration defaultTimeout;
  
  TimeoutHook({
    this.defaultTimeout = const Duration(seconds: 60),
  }) : super(
          id: 'timeout',
          name: '超时控制',
          description: '控制工具执行超时',
          priority: 1,
        );
  
  // 具体超时逻辑需要在工具执行层实现
  // 这里只提供配置和状态检查
}

/// 反思 Hook（合并版）
/// 
/// 核心功能：
/// 1. 工具失败时调用 LLM 分析失败原因
/// 2. 生成改进策略建议和具体替代方案
/// 3. 检测重复参数，避免无意义重试
/// 4. 注入建议到上下文，帮助 Agent 自我纠错
/// 5. 常见错误类型快捷路径（不需要调 LLM）
/// 6. LLM 分析带超时控制（300秒）
class ReflectionHook extends BaseHook {
  /// LLM Provider 工厂函数
  final Future<String> Function(String prompt)? llmProvider;
  
  /// 失败分析缓存（避免重复分析）
  final Map<String, _ReflectionResult> _reflectionCache = {};
  
  /// 连续失败计数
  final Map<String, int> _consecutiveFailures = {};
  
  /// 失败的参数签名（用于检测重复）
  final Map<String, String> _failedSignatures = {};
  
  /// 最近的错误信息（用于错误分类）
  final Map<String, String> _lastErrorMessages = {};
  
  /// 触发反思的失败次数阈值
  static const int reflectionThreshold = 1;
  
  /// 最大连续失败次数（超过后停止反思，直接告知用户）
  static const int maxConsecutiveFailures = 3;
  
  /// LLM 分析超时时间
  static const Duration analysisTimeout = Duration(seconds: 300);
  
  ReflectionHook({
    this.llmProvider,
  }) : super(
          id: 'reflection',
          name: '反思分析',
          description: '工具失败时分析原因、生成策略建议、检测重复参数',
          priority: 15, // 在 FailureLesson 之后执行
        );
  
  @override
  Future<void> onToolError(ToolCall call, dynamic error, AgentLoopContext context) async {
    if (_isInternalTool(call.name)) return;
    
    // 累计失败次数
    _consecutiveFailures[call.name] = (_consecutiveFailures[call.name] ?? 0) + 1;
    
    // 记录参数签名（用于检测重复）
    _failedSignatures[call.name] = call.signature;
    
    // 记录错误信息（用于错误分类）
    _lastErrorMessages[call.name] = error.toString();
    
    final failCount = _consecutiveFailures[call.name]!;
    debugPrint('🪝 [Reflection] ${call.name} 失败 $failCount 次');
    
    // 超过最大次数，不再反思
    if (failCount > maxConsecutiveFailures) {
      debugPrint('🪝 [Reflection] 超过最大失败次数，跳过反思');
    }
  }
  
  @override
  Future<HookResult?> beforeToolCall(ToolCall call, AgentLoopContext context) async {
    if (_isInternalTool(call.name)) return null;
    
    final failCount = _consecutiveFailures[call.name] ?? 0;
    
    // 检查是否在重复相同的参数
    if (failCount > 0 && _failedSignatures[call.name] == call.signature) {
      debugPrint('🪝 [Reflection] 检测到重复参数，建议更换策略');
      return HookResult.inject(
        '【⚠️ 重复检测】你已经用完全相同的参数尝试过 ${call.name}，结果会一样失败。\n'
        '请换用不同的参数或完全不同的方法。',
        userMessage: '检测到重复参数，建议更换策略',
      );
    }
    
    return null;
  }
  
  @override
  Future<HookResult?> beforeRetry(ToolCall call, int retryCount, AgentLoopContext context) async {
    if (_isInternalTool(call.name)) return null;
    
    final failCount = _consecutiveFailures[call.name] ?? 0;
    
    // 达到反思阈值
    if (failCount >= reflectionThreshold) {
      final cacheKey = '${call.name}_${call.signature}';
      
      // 检查缓存
      if (_reflectionCache.containsKey(cacheKey)) {
        final cached = _reflectionCache[cacheKey]!;
        debugPrint('🪝 [Reflection] 使用缓存的反思结果');
        return _buildRetryHookResult(cached, call);
      }
      
      // 先尝试错误分类快捷路径（不需要调 LLM）
      final errorMsg = _lastErrorMessages[call.name] ?? '';
      final quickResult = _tryQuickAnalysis(call, errorMsg);
      if (quickResult != null) {
        debugPrint('🪝 [Reflection] 使用快捷路径分析（${quickResult.failureReason}）');
        _reflectionCache[cacheKey] = quickResult;
        return _buildRetryHookResult(quickResult, call, userMessage: '已分析失败原因（快速诊断）');
      }
      
      // 快捷路径无法处理，调用 LLM 分析（带超时）
      if (llmProvider != null) {
        debugPrint('🪝 [Reflection] 调用 LLM 分析失败原因（${analysisTimeout.inSeconds}秒超时）...');
        
        final reflection = await _analyzeFailureWithTimeout(call, context);
        
        if (reflection != null) {
          // 缓存结果
          _reflectionCache[cacheKey] = reflection;
          
          // 限制缓存大小
          if (_reflectionCache.length > 20) {
            _reflectionCache.remove(_reflectionCache.keys.first);
          }
          
          return _buildRetryHookResult(reflection, call, userMessage: '已分析失败原因，正在尝试新策略');
        }
      }
    }
    
    return null;
  }
  
  /// 构建重试 Hook 结果
  /// 如果有替代方案且工具名与当前工具相同，通过 modifyArgs 真正修改参数
  HookResult _buildRetryHookResult(_ReflectionResult reflection, ToolCall call, {String? userMessage}) {
    Map<String, dynamic>? modifiedArgs;
    
    // 从替代方案中提取可执行的参数修改
    if (reflection.alternativeStrategies.isNotEmpty) {
      for (final alt in reflection.alternativeStrategies) {
        // 只有当替代方案建议使用同一个工具且有具体参数时，才自动修改
        if (alt.suggestedArgs != null && 
            (alt.toolName == null || alt.toolName == call.name)) {
          // 检查参数确实有变化（不是原封不动）
          final hasChange = alt.suggestedArgs!.entries.any((e) {
            final original = call.arguments[e.key];
            return original == null || original.toString() != e.value.toString();
          });
          if (hasChange) {
            modifiedArgs = alt.suggestedArgs;
            debugPrint('🪝 [Reflection] 自动应用替代方案参数: ${alt.description}');
            break;
          }
        }
      }
    }
    
    if (modifiedArgs != null) {
      // 同时注入消息说明 + 修改参数
      return HookResult(
        shouldInject: true,
        injectedMessage: reflection.toInjectionMessage(),
        userMessage: userMessage ?? '已分析失败原因，自动应用替代方案',
        modifiedArgs: modifiedArgs,
      );
    }
    
    // 没有可自动执行的替代方案，仅注入文本建议
    return HookResult.inject(
      reflection.toInjectionMessage(),
      userMessage: userMessage,
    );
  }
  
  @override
  Future<void> afterToolCall(ToolCall call, ToolResult result, AgentLoopContext context) async {
    // 成功后重置失败计数和签名
    if (!result.isError) {
      _consecutiveFailures.remove(call.name);
      _failedSignatures.remove(call.name);
      _lastErrorMessages.remove(call.name);
    }
  }
  
  /// 错误分类快捷路径：对常见错误类型不需要调 LLM，直接生成建议
  _ReflectionResult? _tryQuickAnalysis(ToolCall call, String errorMsg) {
    final errorLower = errorMsg.toLowerCase();
    final category = _classifyError(errorLower);
    
    if (category == null) return null;
    
    final failCount = _consecutiveFailures[call.name] ?? 1;
    
    switch (category) {
      case _ErrorCategory.permissionDenied:
        return _ReflectionResult(
          toolName: call.name,
          failureReason: '权限不足，无法执行该操作',
          suggestions: [
            '检查是否需要 sudo 或管理员权限',
            '确认文件/目录的读写权限',
            '尝试使用当前用户有权限的路径',
          ],
          alternativeStrategies: [],
          consecutiveFailures: failCount,
        );
        
      case _ErrorCategory.fileNotFound:
        return _ReflectionResult(
          toolName: call.name,
          failureReason: '文件或路径不存在',
          suggestions: [
            '使用 ls 或 find 确认文件实际路径',
            '检查路径拼写是否正确（大小写敏感）',
            '确认工作目录是否正确',
          ],
          alternativeStrategies: [],
          consecutiveFailures: failCount,
        );
        
      case _ErrorCategory.networkError:
        return _ReflectionResult(
          toolName: call.name,
          failureReason: '网络连接失败或超时',
          suggestions: [
            '检查网络连接是否正常',
            '如果是下载/安装操作，尝试更换镜像源',
            '适当等待后重试',
          ],
          alternativeStrategies: [],
          consecutiveFailures: failCount,
        );
        
      case _ErrorCategory.syntaxError:
        return _ReflectionResult(
          toolName: call.name,
          failureReason: '命令或脚本语法错误',
          suggestions: [
            '仔细检查命令语法和引号匹配',
            '确认使用的 shell 类型（bash/zsh/sh）',
            '检查特殊字符是否需要转义',
          ],
          alternativeStrategies: [],
          consecutiveFailures: failCount,
        );
        
      case _ErrorCategory.dependencyMissing:
        return _ReflectionResult(
          toolName: call.name,
          failureReason: '缺少依赖包或命令未安装',
          suggestions: [
            '先安装所需依赖（如 npm install、pip install、brew install 等）',
            '检查 PATH 环境变量是否包含该命令',
            '尝试使用 which/where 确认命令位置',
          ],
          alternativeStrategies: [],
          consecutiveFailures: failCount,
        );
    }
  }
  
  /// 错误分类
  _ErrorCategory? _classifyError(String errorLower) {
    // 权限错误
    if (errorLower.contains('permission denied') ||
        errorLower.contains('access denied') ||
        errorLower.contains('eacces') ||
        errorLower.contains('operation not permitted') ||
        errorLower.contains('权限不足')) {
      return _ErrorCategory.permissionDenied;
    }
    
    // 文件不存在
    if (errorLower.contains('no such file') ||
        errorLower.contains('not found') && (errorLower.contains('file') || errorLower.contains('directory')) ||
        errorLower.contains('enoent') ||
        errorLower.contains('does not exist') ||
        errorLower.contains('文件不存在')) {
      return _ErrorCategory.fileNotFound;
    }
    
    // 网络错误
    if (errorLower.contains('connection refused') ||
        errorLower.contains('connection timed out') ||
        errorLower.contains('network') && errorLower.contains('error') ||
        errorLower.contains('econnrefused') ||
        errorLower.contains('econnreset') ||
        errorLower.contains('etimedout') ||
        errorLower.contains('dns') ||
        errorLower.contains('socket hang up') ||
        errorLower.contains('fetch failed')) {
      return _ErrorCategory.networkError;
    }
    
    // 语法错误
    if (errorLower.contains('syntax error') ||
        errorLower.contains('syntaxerror') ||
        errorLower.contains('unexpected token') ||
        errorLower.contains('parse error') ||
        errorLower.contains('unterminated') ||
        errorLower.contains('unexpected end')) {
      return _ErrorCategory.syntaxError;
    }
    
    // 依赖缺失
    if (errorLower.contains('command not found') ||
        errorLower.contains('not recognized') ||
        errorLower.contains('module not found') ||
        errorLower.contains('no module named') ||
        errorLower.contains('cannot find module') ||
        errorLower.contains('package not found') ||
        errorLower.contains('未找到命令')) {
      return _ErrorCategory.dependencyMissing;
    }
    
    return null;
  }
  
  /// 调用 LLM 分析失败原因（带超时）
  Future<_ReflectionResult?> _analyzeFailureWithTimeout(ToolCall call, AgentLoopContext context) async {
    try {
      return await _analyzeFailure(call, context).timeout(
        analysisTimeout,
        onTimeout: () {
          debugPrint('🪝 [Reflection] LLM 分析超时（${analysisTimeout.inSeconds}秒），跳过');
          // 超时时返回通用建议
          return _ReflectionResult(
            toolName: call.name,
            failureReason: '分析超时，请根据错误信息自行调整',
            suggestions: ['尝试调整参数', '换用其他工具', '检查错误信息中的关键提示'],
            alternativeStrategies: [],
            consecutiveFailures: _consecutiveFailures[call.name] ?? 1,
          );
        },
      );
    } catch (e) {
      debugPrint('🪝 [Reflection] 分析失败: $e');
      return null;
    }
  }
  
  /// 调用 LLM 分析失败原因
  Future<_ReflectionResult?> _analyzeFailure(ToolCall call, AgentLoopContext context) async {
    try {
      // 获取最近的失败记录
      final recentFailures = context.failedToolCalls
          .where((f) => f.call.name == call.name)
          .toList();
      
      if (recentFailures.isEmpty) return null;
      
      final lastFailure = recentFailures.last;
      final failCount = _consecutiveFailures[call.name] ?? 1;
      
      // 构建分析 prompt
      final prompt = '''请分析以下工具调用失败的原因，并提供具体的改进建议和替代方案。

## 工具信息
- 工具名称: ${call.name}
- 调用参数: ${_formatArgs(call.arguments)}
- 已连续失败: $failCount 次

## 失败信息
- 错误内容: ${lastFailure.error}

## 上下文
- 用户原始请求: ${context.userRequest}
- 当前轮次: ${context.currentTurn}/${context.maxTurns}
- 已执行工具数: ${context.executedToolCalls.length}

## 请按以下格式回答

### 失败原因
（一句话说明失败的根本原因）

### 改进建议
- 建议1
- 建议2

### 替代方案1
描述: （简要描述这个替代方案）
工具: （建议使用的工具名，如相同则填同上）
参数修改: （具体需要修改的参数，格式: key=new_value）

### 替代方案2（可选）
描述: （简要描述这个替代方案）
工具: （建议使用的工具名）
参数修改: （具体需要修改的参数）

请用简洁的中文回答。最多提供2个替代方案。''';

      final response = await llmProvider!(prompt);
      
      // 解析响应
      return _parseReflectionResponse(response, call.name, call.arguments);
      
    } catch (e) {
      debugPrint('🪝 [Reflection] 分析失败: $e');
      return null;
    }
  }
  
  /// 解析 LLM 响应
  _ReflectionResult _parseReflectionResponse(String response, String toolName, Map<String, dynamic> originalArgs) {
    final lines = response.split('\n');
    String reason = '';
    List<String> suggestions = [];
    List<_AlternativeStrategy> alternatives = [];
    
    String? currentSection;
    _AlternativeStrategy? currentAlternative;
    
    for (final line in lines) {
      final trimmed = line.trim();
      
      // 检测段落标题
      if (trimmed.contains('失败原因')) {
        currentSection = 'reason';
        // 提取冒号后的内容
        final colonIdx = trimmed.indexOf('：');
        if (colonIdx == -1) {
          final colonIdx2 = trimmed.indexOf(':');
          if (colonIdx2 != -1) {
            reason = trimmed.substring(colonIdx2 + 1).trim();
          }
        } else {
          reason = trimmed.substring(colonIdx + 1).trim();
        }
        continue;
      } else if (trimmed.contains('改进建议')) {
        currentSection = 'suggestions';
        continue;
      } else if (trimmed.contains('替代方案')) {
        // 保存上一个替代方案
        if (currentAlternative != null) {
          alternatives.add(currentAlternative);
        }
        currentSection = 'alternative';
        currentAlternative = const _AlternativeStrategy(description: '');
        // 提取描述
        final descMatch = RegExp(r'替代方案\d*[：:]\s*(.+)').firstMatch(trimmed);
        if (descMatch != null) {
          currentAlternative = _AlternativeStrategy(description: descMatch.group(1)!.trim());
        }
        continue;
      }
      
      // 解析内容
      if (currentSection == 'reason' && trimmed.isNotEmpty && !trimmed.startsWith('#')) {
        reason += ' $trimmed';
      } else if (currentSection == 'suggestions') {
        if (trimmed.startsWith('-') || trimmed.startsWith('•') || trimmed.startsWith('*')) {
          suggestions.add(trimmed.substring(1).trim());
        } else if (trimmed.isNotEmpty && !trimmed.startsWith('#')) {
          suggestions.add(trimmed);
        }
      } else if (currentSection == 'alternative' && currentAlternative != null) {
        if (trimmed.startsWith('描述') || trimmed.startsWith('description')) {
          final colonIdx = trimmed.contains('：') ? trimmed.indexOf('：') : trimmed.indexOf(':');
          if (colonIdx != -1 && colonIdx < trimmed.length - 1) {
            final desc = trimmed.substring(colonIdx + 1).trim();
            currentAlternative = _AlternativeStrategy(
              description: desc,
              toolName: currentAlternative.toolName,
              suggestedArgs: currentAlternative.suggestedArgs,
            );
          }
        } else if (trimmed.startsWith('工具') || trimmed.startsWith('tool')) {
          final colonIdx = trimmed.contains('：') ? trimmed.indexOf('：') : trimmed.indexOf(':');
          if (colonIdx != -1 && colonIdx < trimmed.length - 1) {
            final tool = trimmed.substring(colonIdx + 1).trim();
            // 创建新的替代方案，使用原始参数作为基础
            currentAlternative = _AlternativeStrategy(
              description: currentAlternative.description,
              toolName: tool == '同上' ? toolName : tool,
              suggestedArgs: currentAlternative.suggestedArgs ?? Map.from(originalArgs),
            );
          }
        } else if (trimmed.startsWith('参数') || trimmed.startsWith('args')) {
          final colonIdx = trimmed.contains('：') ? trimmed.indexOf('：') : trimmed.indexOf(':');
          if (colonIdx != -1 && colonIdx < trimmed.length - 1) {
            final argsStr = trimmed.substring(colonIdx + 1).trim();
            final newArgs = _parseArgsModification(argsStr, originalArgs);
            currentAlternative = _AlternativeStrategy(
              description: currentAlternative.description,
              toolName: currentAlternative.toolName,
              suggestedArgs: newArgs,
            );
          }
        }
      }
    }
    
    // 保存最后一个替代方案
    if (currentAlternative != null && currentAlternative.description.isNotEmpty) {
      alternatives.add(currentAlternative);
    }
    
    return _ReflectionResult(
      toolName: toolName,
      failureReason: reason.trim().isNotEmpty ? reason.trim() : '参数或操作方式有误',
      suggestions: suggestions.isNotEmpty ? suggestions : ['尝试调整参数', '换用其他工具'],
      alternativeStrategies: alternatives,
      consecutiveFailures: _consecutiveFailures[toolName] ?? 1,
    );
  }
  
  /// 解析参数修改字符串
  Map<String, dynamic> _parseArgsModification(String argsStr, Map<String, dynamic> originalArgs) {
    final newArgs = Map<String, dynamic>.from(originalArgs);
    
    // 格式: key=new_value, key2=new_value2
    final pairs = argsStr.split(',');
    for (final pair in pairs) {
      final parts = pair.split('=');
      if (parts.length == 2) {
        final key = parts[0].trim();
        var value = parts[1].trim();
        // 移除引号
        if ((value.startsWith('"') && value.endsWith('"')) ||
            (value.startsWith("'") && value.endsWith("'"))) {
          value = value.substring(1, value.length - 1);
        }
        newArgs[key] = value;
      }
    }
    
    return newArgs;
  }
  
  /// 格式化参数
  String _formatArgs(Map<String, dynamic> args) {
    return args.entries
        .map((e) => '${e.key}=${_truncate(e.value.toString(), 50)}')
        .join(', ');
  }
  
  /// 截断字符串
  String _truncate(String s, int maxLen) {
    return s.length > maxLen ? '${s.substring(0, maxLen)}...' : s;
  }
  
  /// 判断是否为内部工具
  bool _isInternalTool(String toolName) {
    return toolName == 'think' || 
           toolName == 'save_memory' || 
           toolName == 'activate_skill';
  }
  
  /// 清空缓存和状态
  void clearCache() {
    _reflectionCache.clear();
    _consecutiveFailures.clear();
    _failedSignatures.clear();
    _lastErrorMessages.clear();
  }
}

/// 反思结果
class _ReflectionResult {
  final String toolName;
  final String failureReason;
  final List<String> suggestions;
  
  /// 具体的替代方案（可执行的参数建议）
  final List<_AlternativeStrategy> alternativeStrategies;
  
  /// 连续失败次数
  final int consecutiveFailures;
  
  _ReflectionResult({
    required this.toolName,
    required this.failureReason,
    required this.suggestions,
    this.alternativeStrategies = const [],
    this.consecutiveFailures = 1,
  });
  
  String toInjectionMessage() {
    final sb = StringBuffer();
    
    // 根据失败次数决定提示语气
    if (consecutiveFailures >= 3) {
      sb.writeln('【🚨 紧急反思】${toolName} 已连续失败 $consecutiveFailures 次！');
    } else {
      sb.writeln('【🔍 反思分析】');
    }
    
    sb.writeln('**失败原因**: $failureReason');
    sb.writeln();
    
    if (suggestions.isNotEmpty) {
      sb.writeln('**改进建议**:');
      for (final s in suggestions) {
        sb.writeln('- $s');
      }
      sb.writeln();
    }
    
    if (alternativeStrategies.isNotEmpty) {
      sb.writeln('**替代方案**:');
      for (int i = 0; i < alternativeStrategies.length; i++) {
        final alt = alternativeStrategies[i];
        sb.writeln('${i + 1}. ${alt.description}');
        if (alt.toolName != null && alt.suggestedArgs != null) {
          sb.writeln('   工具: ${alt.toolName}');
          sb.writeln('   参数: ${_formatArgsShort(alt.suggestedArgs!)}');
        }
      }
      sb.writeln();
    }
    
    if (consecutiveFailures >= 3) {
      sb.writeln('⚠️ 此工具已多次失败，请考虑换用完全不同的方法，或直接告知用户当前方法不可行。');
    } else {
      sb.writeln('请根据以上分析调整你的策略，或尝试提供的替代方案。');
    }
    
    return sb.toString();
  }
  
  String _formatArgsShort(Map<String, dynamic> args) {
    final entries = args.entries.take(3).toList();
    return entries.map((e) => '${e.key}=${e.value.toString().length > 30 ? '${e.value.toString().substring(0, 30)}...' : e.value}').join(', ');
  }
}

/// 替代策略
class _AlternativeStrategy {
  final String description;
  final String? toolName;
  final Map<String, dynamic>? suggestedArgs;
  
  const _AlternativeStrategy({
    required this.description,
    this.toolName,
    this.suggestedArgs,
  });
}

/// 错误类型分类（用于快捷路径分析）
enum _ErrorCategory {
  /// 权限不足
  permissionDenied,
  /// 文件/路径不存在
  fileNotFound,
  /// 网络连接错误
  networkError,
  /// 语法错误
  syntaxError,
  /// 依赖/命令缺失
  dependencyMissing,
}
