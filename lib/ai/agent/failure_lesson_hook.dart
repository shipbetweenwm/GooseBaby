/// 失败经验自动检索 Hook
/// 
/// 核心功能：
/// 1. 工具调用前自动检索相关失败经验，注入提示
/// 2. 工具失败后自动保存失败经验
/// 3. 工具成功后关联之前的失败，保存「失败+解决方案」
/// 4. 高频失败经验自动升级为永久记忆

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
