/// 动态配置中心（模块 8）
///
/// 所有 Agent 行为参数集中管理，支持：
/// 1. 运行时热更新
/// 2. 按用户/任务类型差异化配置
/// 3. A/B 测试
/// 4. JSON 文件加载/持久化
///
/// 设计原则：
/// - 所有配置项都有安全的默认值，不传等于现有行为
/// - 使用扁平化 key（如 "agent.maxTurns"）便于覆盖和序列化
/// - 变更通知：支持监听配置变更事件
library;
import 'dart:convert';
import 'dart:io';
import 'package:flutter/foundation.dart';

/// 配置变更事件
class ConfigChangeEvent {
  final String key;
  final dynamic oldValue;
  final dynamic newValue;
  final DateTime timestamp;

  const ConfigChangeEvent({
    required this.key,
    required this.oldValue,
    required this.newValue,
    required this.timestamp,
  });

  @override
  String toString() => 'ConfigChange($key: $oldValue → $newValue)';
}

/// 配置变更监听器
typedef ConfigChangeListener = void Function(ConfigChangeEvent event);

/// 动态配置中心
class AgentConfig {
  static final AgentConfig _instance = AgentConfig._();
  factory AgentConfig() => _instance;
  AgentConfig._();

  // ═══════════════════════════════════════════
  // Agent Loop 配置
  // ═══════════════════════════════════════════

  /// 最大工具调用轮数（当前硬编码在 AgentLoop.run 参数 maxTurns = 30）
  int get maxTurns => _get<int>('agent.maxTurns', 30);

  /// 每个会话的最大 Token 消耗
  int get maxTokensPerSession => _get<int>('agent.maxTokensPerSession', 100000);

  /// 单个工具调用超时（秒）
  int get toolTimeoutSeconds => _get<int>('agent.toolTimeoutSeconds', 30);
  Duration get toolTimeout => Duration(seconds: toolTimeoutSeconds);

  /// LLM API 调用间隔（毫秒），防止 429 限流
  int get llmCallIntervalMs => _get<int>('agent.llmCallIntervalMs', 1000);

  /// LLM API 429 重试最大次数
  int get llmMaxRetries => _get<int>('agent.llmMaxRetries', 3);

  // ═══════════════════════════════════════════
  // 循环防护配置（当前硬编码在 agent_loop.dart 中）
  // ═══════════════════════════════════════════

  /// 连续重复调用检测轮数（agent_loop.dart: maxDuplicateRounds = 3）
  int get maxDuplicateRounds => _get<int>('loop.maxDuplicateRounds', 3);

  /// 无进展检测轮数（agent_loop.dart: maxStagnantRounds = 4）
  int get maxStagnantRounds => _get<int>('loop.maxStagnantRounds', 4);

  /// 同类工具连续失败检测次数（agent_loop.dart: maxFailedCalls = 5）
  int get maxFailedCalls => _get<int>('loop.maxFailedCalls', 5);

  /// 无进展检测的方差阈值（agent_loop.dart: variance < 100）
  double get stagnantVarianceThreshold =>
      _get<double>('loop.stagnantVarianceThreshold', 100.0);

  /// CUA 模式：最大纯文本退出轮数
  int get cuaMaxPlainTextRounds => _get<int>('loop.cuaMaxPlainTextRounds', 3);

  // ═══════════════════════════════════════════
  // Hook 配置
  // ═══════════════════════════════════════════

  /// 连续失败阈值（failure_lesson_hook.dart: maxConsecutiveFailures = 3）
  int get maxConsecutiveFailures =>
      _get<int>('hook.maxConsecutiveFailures', 3);

  /// 反思触发阈值（failure_lesson_hook.dart: 连续失败 2 次触发反思）
  int get reflectionThreshold => _get<int>('hook.reflectionThreshold', 2);

  /// 是否启用反思 Hook
  bool get enableReflection => _get<bool>('hook.enableReflection', true);

  /// 是否启用工具学习
  bool get enableToolLearning => _get<bool>('hook.enableToolLearning', true);

  /// 是否启用循环检测 Hook
  bool get enableLoopDetection => _get<bool>('hook.enableLoopDetection', true);

  /// 是否启用性能统计 Hook
  bool get enablePerformanceStats =>
      _get<bool>('hook.enablePerformanceStats', true);

  /// 是否启用安全 Hook
  bool get enableSecurityHook => _get<bool>('hook.enableSecurityHook', true);

  /// 超时 Hook 时间（秒）
  int get hookTimeoutSeconds => _get<int>('hook.timeoutSeconds', 120);

  // ═══════════════════════════════════════════
  // 记忆配置
  // ═══════════════════════════════════════════

  /// 最大记忆条目数
  int get maxMemoryEntries => _get<int>('memory.maxEntries', 200);

  /// 记忆衰减率
  double get memoryDecayRate => _get<double>('memory.decayRate', 0.1);

  /// 记忆搜索返回 Top K
  int get memorySearchTopK => _get<int>('memory.searchTopK', 5);

  /// 向量搜索相似度阈值
  double get vectorSimilarityThreshold =>
      _get<double>('memory.vectorSimilarityThreshold', 0.3);

  /// 失败经验最大保留条数
  int get maxFailureLessons => _get<int>('memory.maxFailureLessons', 50);

  /// 失败经验检索 Top K
  int get failureLessonTopK => _get<int>('memory.failureLessonTopK', 3);

  // ═══════════════════════════════════════════
  // 模块总开关（供 UI 面板使用）
  // ═══════════════════════════════════════════

  /// 是否启用 Guardrails 防护系统
  bool get enableGuardrails => _get<bool>('guardrails.enabled', true);

  /// 是否启用 Observability 可观测性
  bool get enableObservability => _get<bool>('observability.enabled', true);

  /// 是否启用 Recovery 错误恢复
  bool get enableRecovery => _get<bool>('recovery.enabled', true);

  /// 是否启用 ToolSelector 智能工具选择
  bool get enableToolSelector => _get<bool>('toolSelector.enabled', true);

  // ═══════════════════════════════════════════
  // Guardrails 配置
  // ═══════════════════════════════════════════

  /// 是否启用成本控制
  bool get enableCostControl =>
      _get<bool>('guardrails.enableCostControl', true);

  /// 每会话最大工具调用次数
  int get maxToolCallsPerSession =>
      _get<int>('guardrails.maxToolCallsPerSession', 100);

  /// 每会话最大 LLM 调用次数
  int get maxLLMCallsPerSession =>
      _get<int>('guardrails.maxLLMCallsPerSession', 50);

  /// 工具调用预算（总次数）
  int get maxToolCallBudget =>
      _get<int>('guardrails.maxToolCallBudget', 100);

  /// 时间预算（分钟）
  int get maxTimeBudgetMinutes =>
      _get<int>('guardrails.maxTimeBudgetMinutes', 10);

  /// 会话最大持续时间（分钟）
  int get maxSessionDurationMinutes =>
      _get<int>('guardrails.maxSessionDurationMinutes', 30);
  Duration get maxSessionDuration =>
      Duration(minutes: maxSessionDurationMinutes);

  /// 是否启用输出脱敏
  bool get enableOutputSanitize =>
      _get<bool>('guardrails.enableOutputSanitize', true);

  /// 是否启用输入验证
  bool get enableInputValidation =>
      _get<bool>('guardrails.enableInputValidation', true);

  /// 是否启用路径安全检查
  bool get enablePathSecurity =>
      _get<bool>('guardrails.enablePathSecurity', true);

  // ═══════════════════════════════════════════
  // Prompt 配置
  // ═══════════════════════════════════════════

  /// 默认 Prompt 级别
  String get defaultPromptLevel =>
      _get<String>('prompt.defaultLevel', 'standard');

  /// System Prompt 最大 Token 数
  int get maxSystemPromptTokens =>
      _get<int>('prompt.maxSystemTokens', 8000);

  /// 消息历史最大 Token 数
  int get maxHistoryTokens => _get<int>('prompt.maxHistoryTokens', 32000);

  // ═══════════════════════════════════════════
  // 可观测性配置
  // ═══════════════════════════════════════════

  /// 是否启用 Tracing
  bool get enableTracing => _get<bool>('observability.enableTracing', true);

  /// 是否启用 Metrics 收集
  bool get enableMetrics => _get<bool>('observability.enableMetrics', true);

  /// Trace 导出器类型（console / file / none）
  String get traceExporter =>
      _get<String>('observability.traceExporter', 'console');

  /// Metrics 报告间隔（秒）
  int get metricsReportIntervalSeconds =>
      _get<int>('observability.metricsReportIntervalSeconds', 60);

  // ═══════════════════════════════════════════
  // 工具选择器配置
  // ═══════════════════════════════════════════

  /// 工具过滤分数阈值（低于此分数的工具不推荐）
  double get toolFilterThreshold =>
      _get<double>('toolSelector.filterThreshold', 0.1);

  /// 是否启用工具使用建议注入
  bool get enableToolSuggestions =>
      _get<bool>('toolSelector.enableSuggestions', true);

  // ═══════════════════════════════════════════
  // 恢复管理器配置
  // ═══════════════════════════════════════════

  /// 最大状态快照数
  int get maxSnapshots => _get<int>('recovery.maxSnapshots', 10);

  /// 降级策略链最大尝试次数
  int get maxDegradationAttempts =>
      _get<int>('recovery.maxDegradationAttempts', 3);

  /// 最大重试次数
  int get retryMaxAttempts => _get<int>('recovery.retryMaxAttempts', 3);

  // ═══════════════════════════════════════════
  // 配置存储与管理
  // ═══════════════════════════════════════════

  /// 配置覆盖存储
  final Map<String, dynamic> _overrides = {};

  /// 变更监听器
  final List<ConfigChangeListener> _listeners = [];

  /// 获取配置值
  T _get<T>(String key, T defaultValue) {
    final value = _overrides[key];
    if (value == null) return defaultValue;

    // 类型安全转换
    if (T == double && value is int) {
      return (value.toDouble()) as T;
    }
    if (T == int && value is double) {
      return (value.toInt()) as T;
    }

    try {
      return value as T;
    } catch (_) {
      debugPrint('⚠️ [AgentConfig] 配置类型不匹配: $key, 期望 $T, 实际 ${value.runtimeType}');
      return defaultValue;
    }
  }

  /// 覆盖单个配置项
  void setOverride(String key, dynamic value) {
    final oldValue = _overrides[key];
    _overrides[key] = value;
    _notifyChange(ConfigChangeEvent(
      key: key,
      oldValue: oldValue,
      newValue: value,
      timestamp: DateTime.now(),
    ));
  }

  /// 批量覆盖配置
  void overrideAll(Map<String, dynamic> overrides) {
    for (final entry in overrides.entries) {
      setOverride(entry.key, entry.value);
    }
  }

  /// 移除配置覆盖（恢复默认值）
  void removeOverride(String key) {
    final oldValue = _overrides.remove(key);
    if (oldValue != null) {
      _notifyChange(ConfigChangeEvent(
        key: key,
        oldValue: oldValue,
        newValue: null,
        timestamp: DateTime.now(),
      ));
    }
  }

  /// 清除所有覆盖（恢复全部默认值）
  void clearOverrides() {
    _overrides.clear();
  }

  /// 重置所有配置为默认值（别名，供 UI 调用）
  void reset() => clearOverrides();

  /// 从 JSON Map 加载配置（嵌套结构自动扁平化）
  void loadFromJson(Map<String, dynamic> json) {
    _overrides.clear();
    _flattenJson(json, '', _overrides);
    debugPrint('📦 [AgentConfig] 已加载 ${_overrides.length} 个配置项');
  }

  /// 从 JSON 文件加载配置
  Future<void> loadFromFile(String filePath) async {
    try {
      final file = File(filePath);
      if (!await file.exists()) {
        debugPrint('⚠️ [AgentConfig] 配置文件不存在: $filePath');
        return;
      }
      final content = await file.readAsString();
      final json = jsonDecode(content) as Map<String, dynamic>;
      loadFromJson(json);
    } catch (e) {
      debugPrint('❌ [AgentConfig] 加载配置文件失败: $e');
    }
  }

  /// 保存当前配置到 JSON 文件
  Future<void> saveToFile(String filePath) async {
    try {
      final file = File(filePath);
      await file.parent.create(recursive: true);
      final json = _unflattenJson(_overrides);
      await file.writeAsString(
        const JsonEncoder.withIndent('  ').convert(json),
      );
      debugPrint('💾 [AgentConfig] 已保存配置到: $filePath');
    } catch (e) {
      debugPrint('❌ [AgentConfig] 保存配置文件失败: $e');
    }
  }

  /// 导出当前所有配置（含默认值）
  Map<String, dynamic> exportAll() {
    return {
      'agent': {
        'maxTurns': maxTurns,
        'maxTokensPerSession': maxTokensPerSession,
        'toolTimeoutSeconds': toolTimeoutSeconds,
        'llmCallIntervalMs': llmCallIntervalMs,
        'llmMaxRetries': llmMaxRetries,
      },
      'loop': {
        'maxDuplicateRounds': maxDuplicateRounds,
        'maxStagnantRounds': maxStagnantRounds,
        'maxFailedCalls': maxFailedCalls,
        'stagnantVarianceThreshold': stagnantVarianceThreshold,
        'cuaMaxPlainTextRounds': cuaMaxPlainTextRounds,
      },
      'hook': {
        'maxConsecutiveFailures': maxConsecutiveFailures,
        'reflectionThreshold': reflectionThreshold,
        'enableReflection': enableReflection,
        'enableToolLearning': enableToolLearning,
        'enableLoopDetection': enableLoopDetection,
        'enablePerformanceStats': enablePerformanceStats,
        'enableSecurityHook': enableSecurityHook,
        'timeoutSeconds': hookTimeoutSeconds,
      },
      'memory': {
        'maxEntries': maxMemoryEntries,
        'decayRate': memoryDecayRate,
        'searchTopK': memorySearchTopK,
        'vectorSimilarityThreshold': vectorSimilarityThreshold,
        'maxFailureLessons': maxFailureLessons,
        'failureLessonTopK': failureLessonTopK,
      },
      'guardrails': {
        'enableCostControl': enableCostControl,
        'maxToolCallsPerSession': maxToolCallsPerSession,
        'maxLLMCallsPerSession': maxLLMCallsPerSession,
        'maxSessionDurationMinutes': maxSessionDurationMinutes,
        'enableOutputSanitize': enableOutputSanitize,
        'enableInputValidation': enableInputValidation,
        'enablePathSecurity': enablePathSecurity,
      },
      'prompt': {
        'defaultLevel': defaultPromptLevel,
        'maxSystemTokens': maxSystemPromptTokens,
        'maxHistoryTokens': maxHistoryTokens,
      },
      'observability': {
        'enabled': enableObservability,
        'enableTracing': enableTracing,
        'enableMetrics': enableMetrics,
        'traceExporter': traceExporter,
        'metricsReportIntervalSeconds': metricsReportIntervalSeconds,
      },
      'toolSelector': {
        'enabled': enableToolSelector,
        'filterThreshold': toolFilterThreshold,
        'enableSuggestions': enableToolSuggestions,
      },
      'recovery': {
        'enabled': enableRecovery,
        'maxSnapshots': maxSnapshots,
        'maxDegradationAttempts': maxDegradationAttempts,
        'retryMaxAttempts': retryMaxAttempts,
      },
    };
  }

  /// 获取当前覆盖的配置项
  Map<String, dynamic> get overrides => Map.unmodifiable(_overrides);

  /// 注册配置变更监听器
  void addListener(ConfigChangeListener listener) {
    _listeners.add(listener);
  }

  /// 移除配置变更监听器
  void removeListener(ConfigChangeListener listener) {
    _listeners.remove(listener);
  }

  /// 通知配置变更
  void _notifyChange(ConfigChangeEvent event) {
    for (final listener in _listeners) {
      try {
        listener(event);
      } catch (e) {
        debugPrint('⚠️ [AgentConfig] 监听器错误: $e');
      }
    }
  }

  /// 将嵌套 JSON 扁平化为 "a.b.c" 格式的 key
  void _flattenJson(
      Map<String, dynamic> json, String prefix, Map<String, dynamic> result) {
    for (final entry in json.entries) {
      final key = prefix.isEmpty ? entry.key : '$prefix.${entry.key}';
      if (entry.value is Map<String, dynamic>) {
        _flattenJson(entry.value as Map<String, dynamic>, key, result);
      } else {
        result[key] = entry.value;
      }
    }
  }

  /// 将扁平化的 key 还原为嵌套 JSON
  Map<String, dynamic> _unflattenJson(Map<String, dynamic> flat) {
    final result = <String, dynamic>{};
    for (final entry in flat.entries) {
      final parts = entry.key.split('.');
      var current = result;
      for (var i = 0; i < parts.length - 1; i++) {
        current.putIfAbsent(parts[i], () => <String, dynamic>{});
        current = current[parts[i]] as Map<String, dynamic>;
      }
      current[parts.last] = entry.value;
    }
    return result;
  }

  @override
  String toString() => 'AgentConfig(${_overrides.length} overrides)';
}
