import 'dart:convert';
import '../models/models.dart';
import '../ai/llm/llm_provider.dart';

/// 任务推理引擎（基于大模型）
/// 使用LLM进行任务可行性分析、风险评估、优化建议
class TaskReasoner {
  final LLMProvider llmProvider;
  
  TaskReasoner({required this.llmProvider});
  
  /// 分析任务可行性
  Future<TaskFeasibility> analyzeFeasibility({
    required String task,
    required String mode, // Ask/Craft/Plan/Team/CUA
    required List<String> availableTools,
    String? context,
  }) async {
    final prompt = _buildFeasibilityPrompt(
      task: task,
      mode: mode,
      availableTools: availableTools,
      context: context,
    );
    
    try {
      final response = await llmProvider.chat(prompt);
      return _parseFeasibilityResponse(response, task);
    } catch (e) {
      // LLM调用失败，返回保守评估
      return TaskFeasibility(
        task: task,
        isFeasible: false,
        confidence: 0.3,
        blockers: ['无法评估任务可行性'],
        requirements: [],
      );
    }
  }
  
  /// 评估任务风险
  Future<TaskRiskAssessment> assessRisk({
    required String task,
    required String mode,
    required List<String> availableTools,
    String? context,
  }) async {
    final prompt = _buildRiskPrompt(
      task: task,
      mode: mode,
      availableTools: availableTools,
      context: context,
    );
    
    try {
      final response = await llmProvider.chat(prompt);
      return _parseRiskResponse(response, task);
    } catch (e) {
      // LLM调用失败，返回高风险评估（保守策略）
      return TaskRiskAssessment(
        task: task,
        overallRisk: RiskLevel.high,
        risks: [
          Risk(
            type: RiskType.unknown,
            severity: RiskSeverity.high,
            description: '无法评估风险',
            mitigation: '建议人工确认后执行',
          ),
        ],
        requiresUserConfirmation: true,
      );
    }
  }
  
  /// 生成优化建议
  Future<List<OptimizationSuggestion>> suggestOptimizations({
    required String task,
    required String mode,
    required TaskFeasibility feasibility,
    required TaskRiskAssessment riskAssessment,
    String? context,
  }) async {
    final prompt = _buildOptimizationPrompt(
      task: task,
      mode: mode,
      feasibility: feasibility,
      riskAssessment: riskAssessment,
      context: context,
    );
    
    try {
      final response = await llmProvider.chat(prompt);
      return _parseOptimizationResponse(response);
    } catch (e) {
      // LLM调用失败，返回空建议
      return [];
    }
  }
  
  /// 综合评估（一次性完成可行性+风险评估）
  Future<TaskEvaluation> evaluate({
    required String task,
    required String mode,
    required List<String> availableTools,
    String? context,
  }) async {
    // 并行执行可行性分析和风险评估
    final results = await Future.wait([
      analyzeFeasibility(
        task: task,
        mode: mode,
        availableTools: availableTools,
        context: context,
      ),
      assessRisk(
        task: task,
        mode: mode,
        availableTools: availableTools,
        context: context,
      ),
    ]);
    
    final feasibility = results[0] as TaskFeasibility;
    final riskAssessment = results[1] as TaskRiskAssessment;
    
    // 生成优化建议
    final optimizations = await suggestOptimizations(
      task: task,
      mode: mode,
      feasibility: feasibility,
      riskAssessment: riskAssessment,
      context: context,
    );
    
    return TaskEvaluation(
      task: task,
      mode: mode,
      feasibility: feasibility,
      riskAssessment: riskAssessment,
      optimizations: optimizations,
      timestamp: DateTime.now(),
    );
  }
  
  /// 构建可行性分析prompt
  String _buildFeasibilityPrompt({
    required String task,
    required String mode,
    required List<String> availableTools,
    String? context,
  }) {
    return '''
你是一个任务可行性分析专家，需要评估AI助手能否完成给定任务。

## 任务信息
- 任务描述：$task
- 执行模式：$mode (Ask=问答, Craft=创作, Plan=规划, Team=协作, CUA=电脑操作)
- 可用工具：${availableTools.join(', ')}
${context != null ? '- 任务上下文：$context' : ''}

## 分析维度
1. **能力匹配**：AI助手是否具备完成该任务的能力？
   - Ask模式：信息查询、知识问答
   - Craft模式：内容创作、代码生成
   - Plan模式：任务规划、步骤分解
   - Team模式：多任务协作、并行执行
   - CUA模式：电脑操作、应用控制

2. **工具可用性**：所需工具是否都在可用列表中？

3. **信息充分性**：任务描述是否足够清晰？是否缺少必要信息？

4. **技术限制**：是否存在技术限制（如API限制、权限限制等）？

## 输出格式（JSON）
```json
{
  "isFeasible": true,
  "confidence": 0.85,
  "blockers": [
    "缺少文件路径信息"
  ],
  "requirements": [
    "需要用户提供文件路径",
    "需要文件读取权限"
  ],
  "estimatedSteps": 5,
  "estimatedDuration": "5分钟",
  "alternativeApproaches": [
    "如果文件路径不确定，可以先搜索文件"
  ]
}
```

注意：
- isFeasible为false时，必须在blockers中说明原因
- confidence表示完成任务的把握程度（0-1）
- 如果缺少信息，在requirements中列出

请严格按照JSON格式输出，不要添加任何其他内容。
''';
  }
  
  /// 构建风险评估prompt
  String _buildRiskPrompt({
    required String task,
    required String mode,
    required List<String> availableTools,
    String? context,
  }) {
    return '''
你是一个风险评估专家，需要评估AI助手执行任务可能带来的风险。

## 任务信息
- 任务描述：$task
- 执行模式：$mode
- 可用工具：${availableTools.join(', ')}
${context != null ? '- 任务上下文：$context' : ''}

## 风险类型
1. **数据安全风险**：可能删除、修改重要数据
2. **系统稳定性风险**：可能导致系统崩溃、应用异常
3. **隐私泄露风险**：可能访问敏感信息、泄露隐私
4. **资源消耗风险**：可能消耗大量资源（时间、内存、网络）
5. **不可逆操作风险**：操作无法撤销或难以恢复
6. **合规风险**：可能违反法律、道德规范

## 风险等级
- **低**：风险可控，影响范围小，可恢复
- **中**：需要谨慎，可能造成一定损失
- **高**：危险操作，可能造成严重后果
- **严重**：禁止操作，可能导致不可逆损害

## 输出格式（JSON）
```json
{
  "overallRisk": "low|medium|high|critical",
  "risks": [
    {
      "type": "data_safety|system_stability|privacy|resource|irreversible|compliance",
      "severity": "low|medium|high|critical",
      "description": "风险描述",
      "affectedArea": "受影响范围",
      "mitigation": "缓解措施",
      "probability": 0.7
    }
  ],
  "requiresUserConfirmation": true,
  "confirmationMessage": "此操作将删除文件，是否继续？",
  "safeGuards": [
    "操作前创建备份",
    "限制操作范围",
    "实时监控执行过程"
  ]
}
```

注意：
- overallRisk为high或critical时，requiresUserConfirmation必须为true
- severity为high或critical时，必须提供mitigation和safeGuards

请严格按照JSON格式输出，不要添加任何其他内容。
''';
  }
  
  /// 构建优化建议prompt
  String _buildOptimizationPrompt({
    required String task,
    required String mode,
    required TaskFeasibility feasibility,
    required TaskRiskAssessment riskAssessment,
    String? context,
  }) {
    final feasibilityStr = _formatFeasibility(feasibility);
    final risksStr = _formatRisks(riskAssessment);
    
    return '''
你是一个任务优化专家，需要为AI助手提供任务执行优化建议。

## 任务信息
- 任务描述：$task
- 执行模式：$mode
${context != null ? '- 任务上下文：$context' : ''}

## 可行性分析结果
$feasibilityStr

## 风险评估结果
$risksStr

## 优化维度
1. **执行效率**：如何更快完成任务？
2. **资源优化**：如何减少资源消耗？
3. **风险降低**：如何降低风险？
4. **用户体验**：如何提升用户体验？
5. **错误处理**：如何应对可能的错误？

## 输出格式（JSON）
```json
{
  "suggestions": [
    {
      "type": "efficiency|resource|risk_reduction|user_experience|error_handling",
      "priority": "high|medium|low",
      "description": "优化建议描述",
      "rationale": "优化理由",
      "expectedBenefit": "预期收益",
      "implementation": "具体实施方法",
      "tradeoffs": "可能的权衡"
    }
  ]
}
```

请严格按照JSON格式输出，不要添加任何其他内容。
''';
  }
  
  /// 解析可行性响应
  TaskFeasibility _parseFeasibilityResponse(String response, String task) {
    try {
      final jsonStr = _extractJson(response);
      final data = json.decode(jsonStr) as Map<String, dynamic>;
      
      return TaskFeasibility(
        task: task,
        isFeasible: data['isFeasible'] as bool,
        confidence: (data['confidence'] as num).toDouble(),
        blockers: List<String>.from(data['blockers'] as List? ?? []),
        requirements: List<String>.from(data['requirements'] as List? ?? []),
        estimatedSteps: data['estimatedSteps'] as int?,
        estimatedDuration: data['estimatedDuration'] as String?,
        alternativeApproaches: List<String>.from(
          data['alternativeApproaches'] as List? ?? []
        ),
      );
    } catch (e) {
      return TaskFeasibility(
        task: task,
        isFeasible: false,
        confidence: 0.3,
        blockers: ['无法解析可行性分析结果'],
        requirements: [],
      );
    }
  }
  
  /// 解析风险响应
  TaskRiskAssessment _parseRiskResponse(String response, String task) {
    try {
      final jsonStr = _extractJson(response);
      final data = json.decode(jsonStr) as Map<String, dynamic>;
      
      final risks = (data['risks'] as List)
          .map((r) => Risk(
            type: _parseRiskType(r['type'] as String),
            severity: _parseRiskSeverity(r['severity'] as String),
            description: r['description'] as String,
            affectedArea: r['affectedArea'] as String?,
            mitigation: r['mitigation'] as String?,
            probability: (r['probability'] as num?)?.toDouble(),
          ))
          .toList();
      
      return TaskRiskAssessment(
        task: task,
        overallRisk: _parseRiskLevel(data['overallRisk'] as String),
        risks: risks,
        requiresUserConfirmation: data['requiresUserConfirmation'] as bool? ?? false,
        confirmationMessage: data['confirmationMessage'] as String?,
        safeGuards: List<String>.from(data['safeGuards'] as List? ?? []),
      );
    } catch (e) {
      return TaskRiskAssessment(
        task: task,
        overallRisk: RiskLevel.high,
        risks: [
          Risk(
            type: RiskType.unknown,
            severity: RiskSeverity.high,
            description: '无法解析风险评估结果',
            mitigation: '建议人工确认',
          ),
        ],
        requiresUserConfirmation: true,
      );
    }
  }
  
  /// 解析优化响应
  List<OptimizationSuggestion> _parseOptimizationResponse(String response) {
    try {
      final jsonStr = _extractJson(response);
      final data = json.decode(jsonStr) as Map<String, dynamic>;
      
      return (data['suggestions'] as List)
          .map((s) => OptimizationSuggestion(
            type: _parseOptimizationType(s['type'] as String),
            priority: _parseOptimizationPriority(s['priority'] as String),
            description: s['description'] as String,
            rationale: s['rationale'] as String?,
            expectedBenefit: s['expectedBenefit'] as String?,
            implementation: s['implementation'] as String?,
            tradeoffs: s['tradeoffs'] as String?,
          ))
          .toList();
    } catch (e) {
      return [];
    }
  }
  
  /// 从响应中提取JSON
  String _extractJson(String response) {
    // 尝试提取```json ... ```之间的内容
    final jsonMatch = RegExp(r'```json\s*(.*?)\s*```', dotAll: true).firstMatch(response);
    if (jsonMatch != null) {
      return jsonMatch.group(1)!;
    }
    
    // 尝试提取{ ... }之间的内容
    final braceMatch = RegExp(r'\{.*\}', dotAll: true).firstMatch(response);
    if (braceMatch != null) {
      return braceMatch.group(0)!;
    }
    
    return response;
  }
  
  /// 格式化可行性分析
  String _formatFeasibility(TaskFeasibility f) {
    return '''
可行性：${f.isFeasible ? '是' : '否'}
置信度：${(f.confidence * 100).toStringAsFixed(0)}%
障碍因素：${f.blockers.join(', ')}
必要条件：${f.requirements.join(', ')}
预估步骤：${f.estimatedSteps ?? '未知'}
预估时长：${f.estimatedDuration ?? '未知'}
''';
  }
  
  /// 格式化风险评估
  String _formatRisks(TaskRiskAssessment r) {
    return '''
整体风险：${r.overallRisk.name}
风险数量：${r.risks.length}
需要确认：${r.requiresUserConfirmation ? '是' : '否'}
${r.confirmationMessage != null ? '确认信息：${r.confirmationMessage}' : ''}
''';
  }
  
  // 辅助解析函数
  RiskType _parseRiskType(String s) =>
    RiskType.values.firstWhere((e) => e.name == s, orElse: () => RiskType.unknown);
  
  RiskSeverity _parseRiskSeverity(String s) =>
    RiskSeverity.values.firstWhere((e) => e.name == s, orElse: () => RiskSeverity.medium);
  
  RiskLevel _parseRiskLevel(String s) =>
    RiskLevel.values.firstWhere((e) => e.name == s, orElse: () => RiskLevel.medium);
  
  OptimizationType _parseOptimizationType(String s) =>
    OptimizationType.values.firstWhere((e) => e.name == s, orElse: () => OptimizationType.efficiency);
  
  OptimizationPriority _parseOptimizationPriority(String s) =>
    OptimizationPriority.values.firstWhere((e) => e.name == s, orElse: () => OptimizationPriority.medium);
}

// ===== 数据模型 =====

/// 任务可行性分析
class TaskFeasibility {
  final String task;
  final bool isFeasible;
  final double confidence;
  final List<String> blockers;
  final List<String> requirements;
  final int? estimatedSteps;
  final String? estimatedDuration;
  final List<String> alternativeApproaches;
  
  TaskFeasibility({
    required this.task,
    required this.isFeasible,
    required this.confidence,
    required this.blockers,
    required this.requirements,
    this.estimatedSteps,
    this.estimatedDuration,
    this.alternativeApproaches = const [],
  });
}

/// 任务风险评估
class TaskRiskAssessment {
  final String task;
  final RiskLevel overallRisk;
  final List<Risk> risks;
  final bool requiresUserConfirmation;
  final String? confirmationMessage;
  final List<String> safeGuards;
  
  TaskRiskAssessment({
    required this.task,
    required this.overallRisk,
    required this.risks,
    required this.requiresUserConfirmation,
    this.confirmationMessage,
    this.safeGuards = const [],
  });
}

/// 风险
class Risk {
  final RiskType type;
  final RiskSeverity severity;
  final String description;
  final String? affectedArea;
  final String? mitigation;
  final double? probability;
  
  Risk({
    required this.type,
    required this.severity,
    required this.description,
    this.affectedArea,
    this.mitigation,
    this.probability,
  });
}

enum RiskType {
  dataSafety,        // 数据安全
  systemStability,   // 系统稳定性
  privacy,           // 隐私泄露
  resource,          // 资源消耗
  irreversible,      // 不可逆操作
  compliance,        // 合规风险
  unknown,           // 未知风险
}

enum RiskSeverity {
  low,
  medium,
  high,
  critical,
}

enum RiskLevel {
  low,
  medium,
  high,
  critical,
}

/// 优化建议
class OptimizationSuggestion {
  final OptimizationType type;
  final OptimizationPriority priority;
  final String description;
  final String? rationale;
  final String? expectedBenefit;
  final String? implementation;
  final String? tradeoffs;
  
  OptimizationSuggestion({
    required this.type,
    required this.priority,
    required this.description,
    this.rationale,
    this.expectedBenefit,
    this.implementation,
    this.tradeoffs,
  });
}

enum OptimizationType {
  efficiency,        // 执行效率
  resource,          // 资源优化
  riskReduction,     // 风险降低
  userExperience,    // 用户体验
  errorHandling,     // 错误处理
}

enum OptimizationPriority {
  high,
  medium,
  low,
}

/// 任务综合评估
class TaskEvaluation {
  final String task;
  final String mode;
  final TaskFeasibility feasibility;
  final TaskRiskAssessment riskAssessment;
  final List<OptimizationSuggestion> optimizations;
  final DateTime timestamp;
  
  TaskEvaluation({
    required this.task,
    required this.mode,
    required this.feasibility,
    required this.riskAssessment,
    required this.optimizations,
    required this.timestamp,
  });
  
  /// 是否应该执行该任务
  bool get shouldExecute {
    return feasibility.isFeasible && 
           riskAssessment.overallRisk != RiskLevel.critical;
  }
  
  /// 是否需要用户确认
  bool get requiresConfirmation {
    return riskAssessment.requiresUserConfirmation ||
           riskAssessment.overallRisk == RiskLevel.high;
  }
}
