/// 结构化可观测性系统（模块 4）
///
/// 遵循 OpenTelemetry 语义规范的简化实现：
/// - Tracer: 创建和管理 Trace/Span
/// - Span: 表示一个操作的时间段
/// - MetricsCollector: 收集 Agent/Tool/LLM 运行指标
/// - ObservabilityHook: 将可观测性集成为 Hook（对现有代码侵入最小）
///
/// 使用方式：
/// 1. 作为独立 Hook 注入 AgentLoop（推荐，零侵入）
/// 2. 在代码中直接使用 Tracer/MetricsCollector（可选）
import 'dart:math';
import 'package:flutter/foundation.dart';
import '../agent/agent_hooks.dart';
import '../agent/agent_types.dart';
import '../config/agent_config.dart';

// ═══════════════════════════════════════════
// Span 状态
// ═══════════════════════════════════════════

/// Span 状态
enum SpanStatus {
  /// 正常
  ok,

  /// 发生错误
  error,

  /// 未设置
  unset,
}

// ═══════════════════════════════════════════
// Span 事件
// ═══════════════════════════════════════════

/// Span 事件（时间戳 + 属性）
class SpanEvent {
  final String name;
  final DateTime timestamp;
  final Map<String, dynamic>? attributes;

  const SpanEvent({
    required this.name,
    required this.timestamp,
    this.attributes,
  });

  Map<String, dynamic> toJson() => {
        'name': name,
        'timestamp': timestamp.toIso8601String(),
        if (attributes != null) 'attributes': attributes,
      };
}

// ═══════════════════════════════════════════
// Span
// ═══════════════════════════════════════════

/// Span 表示一个操作的时间段
///
/// 类似 OpenTelemetry Span：
/// - traceId: 追踪链路 ID（同一次 AgentLoop 执行共享）
/// - spanId: 当前 Span 唯一 ID
/// - parentSpanId: 父 Span ID（构成树状结构）
class Span {
  final String traceId;
  final String spanId;
  final String? parentSpanId;
  final String name;
  final DateTime startTime;
  DateTime? endTime;
  final Map<String, dynamic> attributes;
  SpanStatus status;
  String? errorMessage;
  final List<SpanEvent> events;
  final List<Span> children;

  Span({
    required this.traceId,
    required this.spanId,
    this.parentSpanId,
    required this.name,
    required this.startTime,
    Map<String, dynamic>? attributes,
  })  : attributes = attributes ?? {},
        status = SpanStatus.ok,
        events = [],
        children = [];

  /// 操作持续时间
  Duration get duration => (endTime ?? DateTime.now()).difference(startTime);

  /// 是否已结束
  bool get isEnded => endTime != null;

  /// 添加事件
  void addEvent(String name, {Map<String, dynamic>? attributes}) {
    events.add(SpanEvent(
      name: name,
      timestamp: DateTime.now(),
      attributes: attributes,
    ));
  }

  /// 设置属性
  void setAttribute(String key, dynamic value) {
    attributes[key] = value;
  }

  /// 标记错误
  void setError(dynamic error, {String? stackTrace}) {
    status = SpanStatus.error;
    errorMessage = error.toString();
    addEvent('exception', attributes: {
      'exception.type': error.runtimeType.toString(),
      'exception.message': error.toString(),
      if (stackTrace != null) 'exception.stacktrace': stackTrace,
    });
  }

  /// 结束 Span
  void end() {
    if (!isEnded) {
      endTime = DateTime.now();
    }
  }

  /// 转为 JSON
  Map<String, dynamic> toJson() => {
        'traceId': traceId,
        'spanId': spanId,
        if (parentSpanId != null) 'parentSpanId': parentSpanId,
        'name': name,
        'startTime': startTime.toIso8601String(),
        if (endTime != null) 'endTime': endTime!.toIso8601String(),
        'durationMs': duration.inMilliseconds,
        'status': status.name,
        if (errorMessage != null) 'error': errorMessage,
        if (attributes.isNotEmpty) 'attributes': attributes,
        if (events.isNotEmpty) 'events': events.map((e) => e.toJson()).toList(),
        if (children.isNotEmpty)
          'children': children.map((c) => c.toJson()).toList(),
      };
}

// ═══════════════════════════════════════════
// Trace
// ═══════════════════════════════════════════

/// 完整的 Trace（一次 AgentLoop 执行的追踪记录）
class Trace {
  final Span rootSpan;
  final DateTime createdAt;

  Trace({required this.rootSpan}) : createdAt = DateTime.now();

  String get traceId => rootSpan.traceId;
  Duration get totalDuration => rootSpan.duration;

  Map<String, dynamic> toJson() => {
        'traceId': traceId,
        'createdAt': createdAt.toIso8601String(),
        'totalDurationMs': totalDuration.inMilliseconds,
        'rootSpan': rootSpan.toJson(),
      };
}

// ═══════════════════════════════════════════
// Trace 导出器
// ═══════════════════════════════════════════

/// Trace 导出器接口
abstract class TraceExporter {
  Future<void> export(Trace trace);
}

/// 控制台导出器（调试用）
class ConsoleTraceExporter implements TraceExporter {
  @override
  Future<void> export(Trace trace) async {
    debugPrint('═══════════ Trace Report ═══════════');
    debugPrint('TraceId: ${trace.traceId}');
    debugPrint('Duration: ${trace.totalDuration.inMilliseconds}ms');
    _printSpan(trace.rootSpan, 0);
    debugPrint('═══════════════════════════════════');
  }

  void _printSpan(Span span, int depth) {
    final indent = '  ' * depth;
    final statusIcon =
        span.status == SpanStatus.error ? '❌' : '✅';
    debugPrint(
        '$indent$statusIcon ${span.name} (${span.duration.inMilliseconds}ms)');
    if (span.errorMessage != null) {
      debugPrint('$indent   Error: ${span.errorMessage}');
    }
    for (final child in span.children) {
      _printSpan(child, depth + 1);
    }
  }
}

// ═══════════════════════════════════════════
// Tracer
// ═══════════════════════════════════════════

/// 结构化 Trace 系统
class Tracer {
  static final Tracer _instance = Tracer._();
  factory Tracer() => _instance;
  Tracer._();

  final List<TraceExporter> _exporters = [];
  final List<Trace> _recentTraces = [];
  static const _maxRecentTraces = 50;

  final _random = Random();

  /// 注册导出器
  void addExporter(TraceExporter exporter) {
    _exporters.add(exporter);
  }

  /// 移除导出器
  void removeExporter(TraceExporter exporter) {
    _exporters.remove(exporter);
  }

  /// 开始一个新的 Span
  Span startSpan(
    String name, {
    Span? parent,
    Map<String, dynamic>? attributes,
  }) {
    final span = Span(
      traceId: parent?.traceId ?? _generateTraceId(),
      spanId: _generateSpanId(),
      parentSpanId: parent?.spanId,
      name: name,
      startTime: DateTime.now(),
      attributes: attributes,
    );

    // 自动建立父子关系
    parent?.children.add(span);

    return span;
  }

  /// 导出完整 Trace
  Future<void> export(Trace trace) async {
    // 保留最近的 Traces
    _recentTraces.add(trace);
    if (_recentTraces.length > _maxRecentTraces) {
      _recentTraces.removeAt(0);
    }

    // 导出到所有注册的导出器
    for (final exporter in _exporters) {
      try {
        await exporter.export(trace);
      } catch (e) {
        debugPrint('⚠️ [Tracer] 导出失败: $e');
      }
    }
  }

  /// 获取最近的 Traces
  List<Trace> get recentTraces => List.unmodifiable(_recentTraces);

  /// 生成 Trace ID（16 字符十六进制）
  String _generateTraceId() {
    final bytes = List.generate(8, (_) => _random.nextInt(256));
    return bytes.map((b) => b.toRadixString(16).padLeft(2, '0')).join();
  }

  /// 生成 Span ID（8 字符十六进制）
  String _generateSpanId() {
    final bytes = List.generate(4, (_) => _random.nextInt(256));
    return bytes.map((b) => b.toRadixString(16).padLeft(2, '0')).join();
  }
}

// ═══════════════════════════════════════════
// Metrics 收集器
// ═══════════════════════════════════════════

/// 工具级别指标
class _ToolMetrics {
  int totalCalls = 0;
  int failures = 0;
  final List<int> latenciesMs = [];

  void record(Duration duration, bool success) {
    totalCalls++;
    if (!success) failures++;
    latenciesMs.add(duration.inMilliseconds);
    // 只保留最近 100 条延迟记录
    if (latenciesMs.length > 100) {
      latenciesMs.removeAt(0);
    }
  }

  double get successRate =>
      totalCalls > 0 ? (totalCalls - failures) / totalCalls : 0.0;

  Duration get avgLatency {
    if (latenciesMs.isEmpty) return Duration.zero;
    final avg = latenciesMs.reduce((a, b) => a + b) / latenciesMs.length;
    return Duration(milliseconds: avg.round());
  }

  Duration get p95Latency {
    if (latenciesMs.isEmpty) return Duration.zero;
    final sorted = List<int>.from(latenciesMs)..sort();
    final index = (sorted.length * 0.95).ceil() - 1;
    return Duration(milliseconds: sorted[index.clamp(0, sorted.length - 1)]);
  }

  Map<String, dynamic> toJson() => {
        'totalCalls': totalCalls,
        'failures': failures,
        'successRate': (successRate * 100).toStringAsFixed(1),
        'avgLatencyMs': avgLatency.inMilliseconds,
        'p95LatencyMs': p95Latency.inMilliseconds,
      };
}

/// Metrics 收集器
class MetricsCollector {
  static final MetricsCollector _instance = MetricsCollector._();
  factory MetricsCollector() => _instance;
  MetricsCollector._();

  // ── Agent Loop Metrics ──
  final List<Duration> _loopDurations = [];
  final List<int> _turnsPerLoop = [];
  final List<int> _tokensPerLoop = [];
  int _totalLoops = 0;

  // ── Tool Metrics ──
  final Map<String, _ToolMetrics> _toolMetrics = {};

  // ── LLM Metrics ──
  int _totalLLMCalls = 0;
  int _totalInputTokens = 0;
  int _totalOutputTokens = 0;
  final List<int> _llmLatenciesMs = [];

  /// 记录 AgentLoop 完成
  void recordLoopComplete(Duration duration, int turns, {int tokens = 0}) {
    _totalLoops++;
    _loopDurations.add(duration);
    _turnsPerLoop.add(turns);
    _tokensPerLoop.add(tokens);

    // 保留最近 50 条记录
    if (_loopDurations.length > 50) {
      _loopDurations.removeAt(0);
      _turnsPerLoop.removeAt(0);
      _tokensPerLoop.removeAt(0);
    }
  }

  /// 记录工具调用
  void recordToolCall(String toolName, Duration duration, bool success) {
    _toolMetrics.putIfAbsent(toolName, () => _ToolMetrics());
    _toolMetrics[toolName]!.record(duration, success);
  }

  /// 记录 LLM 调用
  void recordLLMCall(Duration latency,
      {int inputTokens = 0, int outputTokens = 0}) {
    _totalLLMCalls++;
    _totalInputTokens += inputTokens;
    _totalOutputTokens += outputTokens;
    _llmLatenciesMs.add(latency.inMilliseconds);
    if (_llmLatenciesMs.length > 100) {
      _llmLatenciesMs.removeAt(0);
    }
  }

  /// 获取工具的平均延迟
  Duration? getAvgLatency(String toolName) {
    final metrics = _toolMetrics[toolName];
    if (metrics == null || metrics.totalCalls == 0) return null;
    return metrics.avgLatency;
  }

  /// 获取工具的成功率
  double getSuccessRate(String toolName) {
    final metrics = _toolMetrics[toolName];
    if (metrics == null || metrics.totalCalls == 0) return 0.0;
    return metrics.successRate;
  }

  /// 生成统计报告
  Map<String, dynamic> generateReport() {
    return {
      'agent_loops': {
        'total': _totalLoops,
        'avg_duration_ms': _average(_loopDurations.map((d) => d.inMilliseconds)),
        'avg_turns': _average(_turnsPerLoop),
        'avg_tokens': _average(_tokensPerLoop),
      },
      'tools': _toolMetrics
          .map((name, m) => MapEntry(name, m.toJson())),
      'llm': {
        'total_calls': _totalLLMCalls,
        'total_input_tokens': _totalInputTokens,
        'total_output_tokens': _totalOutputTokens,
        'avg_latency_ms': _average(_llmLatenciesMs),
      },
    };
  }

  /// 重置所有指标
  void reset() {
    _loopDurations.clear();
    _turnsPerLoop.clear();
    _tokensPerLoop.clear();
    _totalLoops = 0;
    _toolMetrics.clear();
    _totalLLMCalls = 0;
    _totalInputTokens = 0;
    _totalOutputTokens = 0;
    _llmLatenciesMs.clear();
  }

  double _average(Iterable<int> values) {
    if (values.isEmpty) return 0.0;
    return values.reduce((a, b) => a + b) / values.length;
  }
}

// ═══════════════════════════════════════════
// ObservabilityHook
// ═══════════════════════════════════════════

/// 将可观测性集成为 Hook（对现有代码侵入最小）
///
/// 自动追踪 AgentLoop 的完整生命周期：
/// - onLoopStart: 创建根 Span
/// - beforeToolCall: 创建工具调用子 Span
/// - afterToolCall: 结束工具调用 Span + 记录 Metrics
/// - onLoopEnd: 结束根 Span + 导出 Trace + 打印统计
class ObservabilityHook extends BaseHook {
  final Tracer _tracer;
  final MetricsCollector _metrics;
  Span? _currentLoopSpan;
  final Map<String, Span> _activeToolSpans = {};
  DateTime? _loopStartTime;
  int _currentTurns = 0;

  ObservabilityHook({Tracer? tracer, MetricsCollector? metrics})
      : _tracer = tracer ?? Tracer(),
        _metrics = metrics ?? MetricsCollector(),
        super(
          id: 'observability',
          name: '可观测性',
          description: '结构化追踪 + 指标收集',
          priority: 2, // 高优先级，在安全 Hook 之后
        );

  @override
  Future<void> onLoopStart(AgentLoopContext context) async {
    if (!AgentConfig().enableTracing) return;

    _loopStartTime = DateTime.now();
    _currentTurns = 0;
    _currentLoopSpan = _tracer.startSpan('agent_loop', attributes: {
      'session_id': context.sessionId,
      'max_turns': context.maxTurns,
      'user_request': context.userRequest.length > 200
          ? '${context.userRequest.substring(0, 200)}...'
          : context.userRequest,
      'is_sub_agent': context.isSubAgent,
    });
  }

  @override
  Future<HookResult?> beforeToolCall(
      ToolCall call, AgentLoopContext context) async {
    if (!AgentConfig().enableTracing || _currentLoopSpan == null) return null;

    _currentTurns = context.currentTurn;
    _activeToolSpans[call.id] = _tracer.startSpan(
      'tool.${call.name}',
      parent: _currentLoopSpan,
      attributes: {
        'tool.name': call.name,
        'tool.turn': context.currentTurn,
      },
    );

    return null; // 不拦截
  }

  @override
  Future<void> afterToolCall(
      ToolCall call, ToolResult result, AgentLoopContext context) async {
    final span = _activeToolSpans.remove(call.id);
    if (span != null) {
      span.setAttribute('tool.success', !result.isError);
      span.setAttribute('tool.output_length', result.content.length);
      if (result.isError) {
        span.setError(result.content);
      }
      span.end();

      // 记录 Metrics
      if (AgentConfig().enableMetrics) {
        _metrics.recordToolCall(
          call.name,
          span.duration,
          !result.isError,
        );
      }
    }
  }

  @override
  Future<void> onToolError(
      ToolCall call, dynamic error, AgentLoopContext context) async {
    final span = _activeToolSpans[call.id];
    if (span != null) {
      span.setError(error);
    }
  }

  @override
  Future<void> onLoopEnd(AgentLoopResult result) async {
    if (_currentLoopSpan == null) return;

    _currentLoopSpan!.setAttribute('agent.total_turns', _currentTurns);
    _currentLoopSpan!.setAttribute('agent.total_steps', result.steps.length);
    _currentLoopSpan!.setAttribute('agent.text_length', result.text.length);
    _currentLoopSpan!.setAttribute(
        'agent.skill_count', result.skillNames.length);
    _currentLoopSpan!.end();

    // 记录 Loop Metrics
    if (_loopStartTime != null && AgentConfig().enableMetrics) {
      _metrics.recordLoopComplete(
        DateTime.now().difference(_loopStartTime!),
        _currentTurns,
      );
    }

    // 导出 Trace
    if (AgentConfig().enableTracing) {
      final trace = Trace(rootSpan: _currentLoopSpan!);
      await _tracer.export(trace);
    }

    // 清理状态
    _currentLoopSpan = null;
    _activeToolSpans.clear();
    _loopStartTime = null;
  }

  /// 获取 Metrics 收集器（用于外部查询统计）
  MetricsCollector get metrics => _metrics;

  /// 获取 Tracer（用于外部查询 Traces）
  Tracer get tracer => _tracer;
}
