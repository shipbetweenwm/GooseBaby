/// 智能工具选择策略（模块 5）
///
/// 基于任务类型 + 历史成功率 + 工具能力匹配，
/// 为 LLM 提供工具排序建议和使用策略。
///
/// 不是替代 LLM 选择工具，而是：
/// 1. 过滤掉明显不适用的工具（减少 token）
/// 2. 对工具按推荐度排序
/// 3. 在 System Prompt 中注入使用建议
///
/// 与现有 TaskAwarePromptInjector 的协作：
/// - TaskAwarePromptInjector: 粗粒度的提示词注入
/// - ToolSelector: 精细的工具评分 + 排序 + 使用建议
import '../observability/tracer.dart';
import '../config/agent_config.dart';

// ═══════════════════════════════════════════
// 任务类型
// ═══════════════════════════════════════════

/// 任务类型枚举
enum TaskType {
  /// 文件编辑
  fileEdit,

  /// 代码搜索
  search,

  /// Shell 命令执行
  shell,

  /// 代码生成
  codeGeneration,

  /// 问答/分析
  qa,

  /// 调试/修复
  debug,

  /// 项目管理
  projectManagement,

  /// 桌面操控 (CUA)
  desktopControl,

  /// 未知/通用
  general,
}

// ═══════════════════════════════════════════
// 工具评分结果
// ═══════════════════════════════════════════

/// 带评分的工具
class ScoredTool {
  final Map<String, dynamic> tool;
  final double score;
  final String reason;

  const ScoredTool({
    required this.tool,
    required this.score,
    required this.reason,
  });

  String get toolName =>
      (tool['function'] as Map<String, dynamic>?)?['name'] as String? ?? '';
}

/// 工具选择结果
class ToolSelectionResult {
  /// 按推荐度排序的工具列表
  final List<Map<String, dynamic>> rankedTools;

  /// 使用建议（注入 System Prompt）
  final String suggestions;

  /// 被过滤掉的工具
  final List<Map<String, dynamic>> filteredOut;

  /// 检测到的任务类型
  final TaskType detectedTaskType;

  const ToolSelectionResult({
    required this.rankedTools,
    required this.suggestions,
    this.filteredOut = const [],
    required this.detectedTaskType,
  });
}

// ═══════════════════════════════════════════
// 智能工具选择器
// ═══════════════════════════════════════════

/// 智能工具选择器
class ToolSelector {
  final MetricsCollector _metrics;

  ToolSelector({MetricsCollector? metrics})
      : _metrics = metrics ?? MetricsCollector();

  /// 为任务选择最优工具集
  Future<ToolSelectionResult> selectTools({
    required String userQuery,
    required List<Map<String, dynamic>> allTools,
    TaskType? taskType,
  }) async {
    // 1. 检测任务类型（如果未指定）
    final detectedType = taskType ?? detectTaskType(userQuery);

    // 2. 为每个工具评分
    final scoredTools = <ScoredTool>[];
    for (final tool in allTools) {
      final toolName =
          (tool['function'] as Map<String, dynamic>?)?['name'] as String? ?? '';
      if (toolName.isEmpty) continue;

      final score = _calculateToolScore(toolName, detectedType);
      final reason = _getScoreReason(toolName, detectedType, score);
      scoredTools.add(ScoredTool(tool: tool, score: score, reason: reason));
    }

    // 3. 按分数排序
    scoredTools.sort((a, b) => b.score.compareTo(a.score));

    // 4. 过滤低分工具
    final threshold = AgentConfig().toolFilterThreshold;
    final filtered =
        scoredTools.where((s) => s.score < threshold).map((s) => s.tool).toList();
    final ranked =
        scoredTools.where((s) => s.score >= threshold).map((s) => s.tool).toList();

    // 5. 构建使用建议
    final suggestions = _generateUsageSuggestions(scoredTools, detectedType);

    return ToolSelectionResult(
      rankedTools: ranked.isNotEmpty ? ranked : allTools, // 降级：返回全部
      suggestions: suggestions,
      filteredOut: filtered,
      detectedTaskType: detectedType,
    );
  }

  /// 检测任务类型
  TaskType detectTaskType(String query) {
    final lowerQuery = query.toLowerCase();

    // 文件编辑相关
    if (_matchesAny(lowerQuery, [
      '编辑', '修改', '写入', '创建文件', '更新', 'edit', 'modify', 'write',
      'create file', 'update', '添加', 'add to file', '替换', 'replace',
    ])) {
      return TaskType.fileEdit;
    }

    // 搜索相关
    if (_matchesAny(lowerQuery, [
      '搜索', '查找', '找到', '在哪', 'search', 'find', 'where', 'grep',
      '定位', 'locate', '哪个文件',
    ])) {
      return TaskType.search;
    }

    // Shell 命令
    if (_matchesAny(lowerQuery, [
      '运行', '执行', 'run', 'execute', '命令', 'command', 'npm', 'pip',
      'install', '安装', '编译', 'build', 'compile', 'git',
    ])) {
      return TaskType.shell;
    }

    // 代码生成
    if (_matchesAny(lowerQuery, [
      '生成', '实现', '写一个', 'generate', 'implement', 'create', '新建',
      '开发', '代码', 'code',
    ])) {
      return TaskType.codeGeneration;
    }

    // 调试/修复
    if (_matchesAny(lowerQuery, [
      '修复', '调试', 'fix', 'debug', 'bug', '错误', 'error', '问题',
      'issue', '崩溃', 'crash', '报错',
    ])) {
      return TaskType.debug;
    }

    // 问答
    if (_matchesAny(lowerQuery, [
      '什么是', '怎么', '为什么', '解释', '分析', 'what', 'how', 'why',
      'explain', '告诉我', '帮我理解',
    ])) {
      return TaskType.qa;
    }

    // CUA
    if (_matchesAny(lowerQuery, [
      '打开', '点击', '操控', 'click', 'open app', '桌面', 'desktop',
      '截图', 'screenshot', '鼠标', '键盘',
    ])) {
      return TaskType.desktopControl;
    }

    return TaskType.general;
  }

  bool _matchesAny(String text, List<String> keywords) {
    return keywords.any((k) => text.contains(k));
  }

  /// 计算工具评分
  double _calculateToolScore(String toolName, TaskType taskType) {
    double score = 0.0;

    // 1. 任务类型匹配度（确定性规则，权重 0.5）
    final affinity = _taskToolAffinity[taskType]?[toolName] ?? 0.2;
    score += affinity * 0.5;

    // 2. 历史成功率（从 Metrics 获取，权重 0.3）
    final successRate = _metrics.getSuccessRate(toolName);
    if (successRate > 0) {
      score += successRate * 0.3;
    } else {
      score += 0.15; // 无历史数据时给中等分
    }

    // 3. 调用延迟评分（权重 0.2）
    final avgLatency = _metrics.getAvgLatency(toolName);
    if (avgLatency != null) {
      if (avgLatency.inSeconds < 2) {
        score += 0.2; // 快速工具加满分
      } else if (avgLatency.inSeconds < 5) {
        score += 0.15;
      } else if (avgLatency.inSeconds < 10) {
        score += 0.1;
      } else {
        score += 0.05; // 慢速工具低分
      }
    } else {
      score += 0.1; // 无数据给中等分
    }

    return score;
  }

  /// 获取评分原因
  String _getScoreReason(String toolName, TaskType taskType, double score) {
    final affinity = _taskToolAffinity[taskType]?[toolName];
    if (affinity != null && affinity > 0.7) {
      return '任务类型高度匹配';
    } else if (affinity != null && affinity > 0.4) {
      return '任务类型部分匹配';
    } else if (score > 0.5) {
      return '历史表现良好';
    } else {
      return '低相关度';
    }
  }

  /// 生成使用建议
  String _generateUsageSuggestions(
      List<ScoredTool> scoredTools, TaskType taskType) {
    if (!AgentConfig().enableToolSuggestions) return '';

    final buffer = StringBuffer();
    final topTools =
        scoredTools.where((s) => s.score > 0.5).take(5).toList();

    if (topTools.isEmpty) return '';

    buffer.writeln('【工具使用建议】');
    buffer.writeln('检测到任务类型: ${_taskTypeNames[taskType] ?? "通用"}');
    buffer.writeln('推荐工具优先级:');

    for (var i = 0; i < topTools.length; i++) {
      buffer.writeln(
          '  ${i + 1}. ${topTools[i].toolName} — ${topTools[i].reason}');
    }

    // 添加任务类型特定的建议
    final tipKey = _taskTypeTips[taskType];
    if (tipKey != null) {
      buffer.writeln('\n💡 提示: $tipKey');
    }

    return buffer.toString();
  }

  /// 任务类型-工具亲和度矩阵
  static const Map<TaskType, Map<String, double>> _taskToolAffinity = {
    TaskType.fileEdit: {
      'read_file': 0.9,
      'write_file': 0.85,
      'replace_in_file': 0.9,
      'search_content': 0.7,
      'search_file': 0.6,
      'list_dir': 0.5,
      'codebase_search': 0.6,
    },
    TaskType.search: {
      'codebase_search': 0.95,
      'search_content': 0.9,
      'search_file': 0.85,
      'read_file': 0.4,
      'list_dir': 0.6,
    },
    TaskType.shell: {
      'execute_command': 0.95,
      'read_file': 0.3,
      'write_file': 0.2,
    },
    TaskType.codeGeneration: {
      'write_file': 0.9,
      'read_file': 0.8,
      'search_content': 0.6,
      'codebase_search': 0.7,
      'execute_command': 0.4,
      'list_dir': 0.5,
    },
    TaskType.debug: {
      'read_file': 0.9,
      'search_content': 0.85,
      'codebase_search': 0.8,
      'execute_command': 0.7,
      'replace_in_file': 0.6,
      'list_dir': 0.4,
    },
    TaskType.qa: {
      'think': 0.9,
      'web_search': 0.8,
      'read_file': 0.5,
      'codebase_search': 0.6,
      'search_content': 0.5,
    },
    TaskType.desktopControl: {
      'cua': 0.95,
      'think': 0.8,
    },
    TaskType.general: {
      'think': 0.6,
      'read_file': 0.5,
      'search_content': 0.5,
      'codebase_search': 0.5,
      'write_file': 0.4,
      'execute_command': 0.4,
    },
  };

  /// 任务类型名称映射
  static const _taskTypeNames = {
    TaskType.fileEdit: '文件编辑',
    TaskType.search: '代码搜索',
    TaskType.shell: '命令执行',
    TaskType.codeGeneration: '代码生成',
    TaskType.qa: '问答分析',
    TaskType.debug: '调试修复',
    TaskType.projectManagement: '项目管理',
    TaskType.desktopControl: '桌面操控',
    TaskType.general: '通用',
  };

  /// 任务类型使用提示
  static const _taskTypeTips = {
    TaskType.fileEdit:
        '编辑文件时优先使用 replace_in_file 进行精确替换，避免用 write_file 覆盖整个文件',
    TaskType.search:
        '搜索代码时优先使用 codebase_search（语义搜索），精确匹配用 search_content',
    TaskType.debug:
        '调试时先读取相关文件理解上下文，再搜索错误信息相关代码',
    TaskType.codeGeneration:
        '生成代码前先搜索项目中的类似实现，保持代码风格一致',
    TaskType.shell:
        '执行命令前确认命令安全性，避免破坏性操作',
  };
}
