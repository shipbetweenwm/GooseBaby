/// 问答路由机制
///
/// 在 AgentLoop 之前，根据用户输入智能判断走哪条处理路径：
/// - 简单问答 → Ask 模式（直接回答，不调用工具或只调用只读工具）
/// - 复杂任务 → Plan/Craft 模式（走规划 + 工具调用流程）
/// - 桌面操控 → CUA 模式（走多模态操控流程）
///
/// 路由信号来源：
/// 1. 关键词匹配（快速路径，0 token 消耗）
/// 2. LLM 分类（精确路径，少量 token 消耗，可选）
/// 3. 用户显式指定模式（最高优先级）
import 'agent_mode.dart';
import 'tool_selector.dart';

/// 路由结果
class RouteResult {
  /// 推荐的执行模式
  final AgentMode recommendedMode;

  /// 路由置信度（0.0 ~ 1.0）
  final double confidence;

  /// 路由原因
  final String reason;

  /// 检测到的任务类型
  final TaskType detectedTaskType;

  /// 是否需要结构化规划
  final bool needsPlanning;

  /// 预估复杂度（1-5，5 最复杂）
  final int complexity;

  const RouteResult({
    required this.recommendedMode,
    required this.confidence,
    required this.reason,
    required this.detectedTaskType,
    this.needsPlanning = false,
    this.complexity = 1,
  });
}

/// 问答路由器
class QueryRouter {
  /// 单轮关键词路由（零 token 消耗）
  RouteResult route(String userQuery, {AgentMode? userSpecifiedMode}) {
    // 用户显式指定模式，最高优先级
    if (userSpecifiedMode != null) {
      return RouteResult(
        recommendedMode: userSpecifiedMode,
        confidence: 1.0,
        reason: '用户显式指定 ${userSpecifiedMode.displayName} 模式',
        detectedTaskType: TaskType.general,
      );
    }

    final lowerQuery = userQuery.toLowerCase();
    final detectedType = _detectTaskType(lowerQuery);
    final complexity = _estimateComplexity(lowerQuery);

    // ── 规则 1：CUA 操控关键词 → CUA 模式 ──
    if (_matchesAny(lowerQuery, [
      '打开应用', '点击按钮', '操控电脑', '截图看看', '鼠标点击',
      '键盘输入', 'open app', 'click button', 'desktop control',
      'screenshot', '自动化操作', '桌面操作', '操控桌面',
    ])) {
      return RouteResult(
        recommendedMode: AgentMode.cua,
        confidence: 0.9,
        reason: '检测到桌面操控意图',
        detectedTaskType: TaskType.desktopControl,
        complexity: complexity,
      );
    }

    // ── 规则 2：纯问答关键词 → Ask 模式 ──
    if (_isPureQuestion(lowerQuery)) {
      return RouteResult(
        recommendedMode: AgentMode.ask,
        confidence: 0.85,
        reason: '检测到纯问答意图，无需工具操作',
        detectedTaskType: TaskType.qa,
        complexity: 1,
      );
    }

    // ── 规则 3：复杂任务关键词 → Plan 模式 ──
    if (_needsPlanning(lowerQuery) || complexity >= 4) {
      return RouteResult(
        recommendedMode: AgentMode.plan,
        confidence: 0.8,
        reason: '检测到复杂任务，需要先规划后执行',
        detectedTaskType: detectedType,
        needsPlanning: true,
        complexity: complexity,
      );
    }

    // ── 规则 4：操作类关键词 → Craft 模式 ──
    if (_isActionOriented(lowerQuery)) {
      return RouteResult(
        recommendedMode: AgentMode.craft,
        confidence: 0.85,
        reason: '检测到操作意图，直接执行',
        detectedTaskType: detectedType,
        complexity: complexity,
      );
    }

    // ── 默认：中等复杂度用 Craft，高复杂度用 Plan ──
    if (complexity >= 3) {
      return RouteResult(
        recommendedMode: AgentMode.plan,
        confidence: 0.6,
        reason: '中等偏高复杂度，建议先规划',
        detectedTaskType: detectedType,
        needsPlanning: true,
        complexity: complexity,
      );
    }

    return RouteResult(
      recommendedMode: AgentMode.craft,
      confidence: 0.5,
      reason: '默认走 Craft 模式',
      detectedTaskType: detectedType,
      complexity: complexity,
    );
  }

  /// 判断是否为纯问答
  bool _isPureQuestion(String query) {
    // 只问不改
    final questionPatterns = [
      '什么是', '怎么理解', '为什么', '解释一下', '告诉我',
      '帮我理解', '是什么意思', '有什么区别', '比较一下',
      'what is', 'explain', 'how does', 'why', 'tell me about',
      'analyze', '分析一下', '评估一下', '怎么看',
    ];

    final actionPatterns = [
      '修改', '创建', '删除', '运行', '执行', '写一个', '实现',
      'edit', 'create', 'delete', 'run', 'execute', 'write', 'implement',
      '帮我改', '帮我写', '帮我建', '修复',
    ];

    final hasQuestion = _matchesAny(query, questionPatterns);
    final hasAction = _matchesAny(query, actionPatterns);

    return hasQuestion && !hasAction;
  }

  /// 判断是否需要规划
  bool _needsPlanning(String query) {
    return _matchesAny(query, [
      '先规划', '先分析', '分步骤', '一步步来', '制定计划',
      '重构', '架构调整', '多文件', '批量处理',
      'plan first', 'step by step', 'refactor', 'restructure',
    ]);
  }

  /// 判断是否为操作导向
  bool _isActionOriented(String query) {
    return _matchesAny(query, [
      '帮我修改', '帮我创建', '帮我运行', '帮我安装',
      '修改文件', '创建文件', '删除文件', '运行命令',
      'fix', 'modify', 'create', 'install', 'build',
      '替换', '更新', '添加', '删除', '编译',
    ]);
  }

  /// 检测任务类型（复用 ToolSelector 的逻辑）
  TaskType _detectTaskType(String query) {
    if (_matchesAny(query, [
      '编辑', '修改', '写入', '创建文件', 'replace', 'edit',
    ])) {
      return TaskType.fileEdit;
    }
    if (_matchesAny(query, [
      '搜索', '查找', '找到', '在哪', 'search', 'find',
    ])) {
      return TaskType.search;
    }
    if (_matchesAny(query, [
      '运行', '执行', 'run', 'execute', '命令', 'install',
    ])) {
      return TaskType.shell;
    }
    if (_matchesAny(query, [
      '修复', '调试', 'fix', 'debug', 'bug', 'error',
    ])) {
      return TaskType.debug;
    }
    if (_matchesAny(query, [
      '生成', '实现', '写一个', 'generate', 'implement',
    ])) {
      return TaskType.codeGeneration;
    }
    return TaskType.general;
  }

  /// 估算任务复杂度（1-5）
  int _estimateComplexity(String query) {
    int complexity = 1;

    // 多步骤关键词
    if (_matchesAny(query, ['然后', '接着', '之后', '还要', 'and then', 'after that'])) {
      complexity += 1;
    }

    // 多文件/多模块
    if (_matchesAny(query, ['所有文件', '多个文件', '批量', 'all files', 'multiple'])) {
      complexity += 1;
    }

    // 重构/架构级
    if (_matchesAny(query, ['重构', '架构', '重新设计', 'refactor', 'restructure', 'redesign'])) {
      complexity += 2;
    }

    // 长查询暗示复杂度
    if (query.length > 200) complexity += 1;

    return complexity.clamp(1, 5);
  }

  bool _matchesAny(String text, List<String> keywords) {
    return keywords.any((k) => text.contains(k));
  }
}
