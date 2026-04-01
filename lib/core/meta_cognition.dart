import 'dart:convert';
import '../models/models.dart';
import '../ai/llm/llm_provider.dart';
import 'autonomous_learner.dart';
import 'tool_learner.dart';

/// 元认知系统（基于大模型）
/// 让AI能够"思考自己的思考"：能力评估、任务匹配、自我反思、能力提升
class MetaCognition {
  final LLMProvider llmProvider;
  final AutonomousLearner autonomousLearner;
  final ToolLearner toolLearner;
  
  MetaCognition({
    required this.llmProvider,
    required this.autonomousLearner,
    required this.toolLearner,
  });
  
  /// 评估自身能力
  Future<CapabilityAssessment> assessCapabilities() async {
    // 收集能力数据
    final insights = autonomousLearner.getInsights();
    final healthAlerts = autonomousLearner.detectUnhealthyPatterns();
    
    // 获取工具使用统计
    final toolStats = _getToolStatistics();
    
    final prompt = '''
你是一个AI能力评估专家，需要评估AI助手鹅宝的综合能力。

## 用户关系能力
- 关系健康度：${(insights.relationshipHealth * 100).toStringAsFixed(0)}%
- 偏好语气：${insights.preferredTone}
- 用户兴趣：${insights.interests.join(', ')}
- 健康警告：${healthAlerts.map((a) => a.message).join('; ')}

## 工具使用能力
$toolStats

## 评估维度
请评估以下能力维度（0-100分）：
1. **对话能力**：理解、回应、共情能力
2. **情感支持**：识别、分析、干预情感问题
3. **任务执行**：规划、执行、监控任务
4. **学习能力**：从经验中学习、适应变化
5. **自我认知**：了解能力边界、承认无知
6. **风险意识**：识别风险、采取防护措施
7. **创造力**：生成新颖、有用的想法
8. **协作能力**：与用户协作、与其他AI协作

## 输出格式（JSON）
```json
{
  "overallScore": 75,
  "dimensions": [
    {
      "name": "对话能力",
      "score": 85,
      "strengths": ["擅长倾听", "回应温暖"],
      "weaknesses": ["有时过于啰嗦"],
      "improvements": ["学习更简洁的表达方式"]
    }
  ],
  "coreCompetencies": ["情感陪伴", "任务协助"],
  "limitationAreas": ["复杂编程", "专业分析"],
  "confidenceInAssessment": 0.8
}
```

请严格按照JSON格式输出，不要添加任何其他内容。
''';

    try {
      final response = await llmProvider.chat(prompt);
      return _parseCapabilityAssessment(response);
    } catch (e) {
      return CapabilityAssessment(
        overallScore: 50,
        dimensions: [],
        coreCompetencies: ['基础对话'],
        limitationAreas: ['无法评估'],
        confidenceInAssessment: 0.3,
      );
    }
  }
  
  /// 判断能否完成任务
  Future<TaskMatching> matchTask({
    required String task,
    required String mode,
    required CapabilityAssessment capabilities,
  }) async {
    final prompt = '''
你是一个任务匹配专家，需要判断AI助手是否有能力完成给定任务。

## 任务信息
- 任务描述：$task
- 执行模式：$mode

## AI能力评估
- 总体得分：${capabilities.overallScore}/100
- 核心能力：${capabilities.coreCompetencies.join(', ')}
- 限制领域：${capabilities.limitationAreas.join(', ')}
- 各维度得分：
${capabilities.dimensions.map((d) => '  - ${d.name}：${d.score}/100').join('\n')}

## 匹配分析
请分析：
1. 该任务需要哪些能力？
2. AI助手是否具备这些能力？
3. 是否需要额外的工具或资源？
4. 置信度如何？

## 输出格式（JSON）
```json
{
  "canPerform": true,
  "confidence": 0.85,
  "requiredCapabilities": ["对话能力", "情感支持"],
  "missingCapabilities": [],
  "capabilityGaps": [],
  "alternativeApproach": "如果缺少某些能力，可以采用的替代方案",
  "riskAssessment": {
    "level": "low|medium|high",
    "factors": ["风险因素"],
    "mitigations": ["缓解措施"]
  },
  "suggestedTools": ["需要的工具"],
  "estimatedDifficulty": "easy|medium|hard|expert"
}
```

请严格按照JSON格式输出，不要添加任何其他内容。
''';

    try {
      final response = await llmProvider.chat(prompt);
      return _parseTaskMatching(response, task, mode);
    } catch (e) {
      return TaskMatching(
        task: task,
        mode: mode,
        canPerform: false,
        confidence: 0.3,
        requiredCapabilities: [],
        missingCapabilities: ['无法评估'],
        capabilityGaps: ['评估失败'],
        estimatedDifficulty: TaskDifficulty.unknown,
      );
    }
  }
  
  /// 自我反思
  Future<SelfReflection> reflect({
    required String recentInteraction,
    required String userFeedback,
    required CapabilityAssessment capabilities,
  }) async {
    final prompt = '''
你是一个自我反思专家，帮助AI助手反思自己的表现并找到改进方向。

## 最近交互
$recentInteraction

## 用户反馈
$userFeedback

## 当前能力评估
- 总体得分：${capabilities.overallScore}/100
- 优势：${capabilities.dimensions.where((d) => d.score >= 70).map((d) => d.name).join(', ')}
- 劣势：${capabilities.dimensions.where((d) => d.score < 50).map((d) => d.name).join(', ')}

## 反思任务
请从以下角度反思：
1. **表现评估**：做得好的地方和不足之处
2. **用户反馈分析**：用户的真实需求和感受
3. **改进机会**：具体的改进方向
4. **学习计划**：如何提升相关能力

## 输出格式（JSON）
```json
{
  "performanceAssessment": {
    "strengths": ["做得好的地方"],
    "weaknesses": ["不足之处"],
    "score": 75
  },
  "feedbackAnalysis": {
    "userNeeds": ["用户真实需求"],
    "emotionalState": "用户情绪状态",
    "satisfactionLevel": 0.8,
    "unspokenExpectations": ["未明说的期望"]
  },
  "improvements": [
    {
      "area": "改进领域",
      "current": "当前状态",
      "target": "目标状态",
      "actions": ["具体行动"],
      "priority": "high|medium|low",
      "timeline": "预期时间"
    }
  ],
  "learningPlan": {
    "shortTerm": ["短期学习目标"],
    "mediumTerm": ["中期学习目标"],
    "longTerm": ["长期学习目标"],
    "resources": ["需要的资源"]
  },
  "selfAwareness": {
    "knownStrengths": ["已知的优势"],
    "knownWeaknesses": ["已知的劣势"],
    "blindSpots": ["盲点"],
    "overConfidence": ["可能过度自信的领域"],
    "underConfidence": ["可能低估的领域"]
  }
}
```

请严格按照JSON格式输出，不要添加任何其他内容。
''';

    try {
      final response = await llmProvider.chat(prompt);
      return _parseSelfReflection(response);
    } catch (e) {
      return SelfReflection(
        performanceAssessment: PerformanceAssessment(
          strengths: [],
          weaknesses: ['无法反思'],
          score: 50,
        ),
        improvements: [],
        learningPlan: LearningPlan(
          shortTerm: [],
          mediumTerm: [],
          longTerm: [],
          resources: [],
        ),
      );
    }
  }
  
  /// 生成能力提升计划
  Future<CapabilityImprovementPlan> generateImprovementPlan({
    required CapabilityAssessment currentCapabilities,
    required SelfReflection recentReflection,
    required List<String> userRequests,
  }) async {
    final prompt = '''
你是一个能力提升规划专家，为AI助手制定系统化的能力提升计划。

## 当前能力
- 总体得分：${currentCapabilities.overallScore}/100
- 核心能力：${currentCapabilities.coreCompetencies.join(', ')}
- 限制领域：${currentCapabilities.limitationAreas.join(', ')}

## 近期反思
- 优势：${recentReflection.performanceAssessment.strengths.join(', ')}
- 劣势：${recentReflection.performanceAssessment.weaknesses.join(', ')}
- 改进方向：${recentReflection.improvements.map((i) => i.area).join(', ')}

## 用户高频需求
${userRequests.take(10).join('\n')}

## 规划任务
请制定能力提升计划，包括：
1. **优先级排序**：哪些能力最需要提升？
2. **具体目标**：每个能力要达到什么水平？
3. **学习方法**：如何提升这些能力？
4. **资源需求**：需要哪些资源？
5. **时间规划**：预期何时达成目标？
6. **评估方法**：如何评估能力提升？

## 输出格式（JSON）
```json
{
  "priorities": [
    {
      "capability": "能力名称",
      "currentLevel": 50,
      "targetLevel": 75,
      "priority": "high|medium|low",
      "rationale": "为什么重要"
    }
  ],
  "learningPath": [
    {
      "capability": "能力名称",
      "steps": [
        {
          "action": "学习动作",
          "method": "学习方法",
          "duration": "预计时长",
          "resources": ["需要资源"],
          "milestone": "里程碑"
        }
      ]
    }
  ],
  "timeline": {
    "shortTerm": {
      "duration": "1-2周",
      "goals": ["短期目标"],
      "expectedImprovement": 10
    },
    "mediumTerm": {
      "duration": "1-3个月",
      "goals": ["中期目标"],
      "expectedImprovement": 25
    },
    "longTerm": {
      "duration": "3-12个月",
      "goals": ["长期目标"],
      "expectedImprovement": 40
    }
  },
  "resourceNeeds": {
    "knowledge": ["知识资源"],
    "tools": ["工具资源"],
    "data": ["数据资源"],
    "feedback": ["反馈来源"]
  },
  "evaluationMetrics": {
    "quantitative": ["量化指标"],
    "qualitative": ["质化指标"],
    "frequency": "评估频率"
  }
}
```

请严格按照JSON格式输出，不要添加任何其他内容。
''';

    try {
      final response = await llmProvider.chat(prompt);
      return _parseImprovementPlan(response);
    } catch (e) {
      return CapabilityImprovementPlan(
        priorities: [],
        learningPath: [],
        timeline: ImprovementTimeline(
          shortTerm: TimelinePhase(duration: '1-2周', goals: [], expectedImprovement: 5),
          mediumTerm: TimelinePhase(duration: '1-3个月', goals: [], expectedImprovement: 15),
          longTerm: TimelinePhase(duration: '3-12个月', goals: [], expectedImprovement: 30),
        ),
        resourceNeeds: ResourceNeeds(),
      );
    }
  }
  
  /// 获取工具统计信息
  String _getToolStatistics() {
    final toolNames = toolLearner.cases.map((c) => c.toolName).toSet();
    
    final stats = StringBuffer();
    for (final tool in toolNames) {
      final toolCases = toolLearner.cases.where((c) => c.toolName == tool);
      final successCount = toolCases.where((c) => c.isSuccess).length;
      final totalCount = toolCases.length;
      final successRate = totalCount > 0 ? (successCount / totalCount * 100).toStringAsFixed(0) : '0';
      
      stats.writeln('- $tool：成功率${successRate}%（${successCount}/${totalCount}）');
    }
    
    return stats.toString();
  }
  
  /// 解析能力评估
  CapabilityAssessment _parseCapabilityAssessment(String response) {
    try {
      final jsonStr = _extractJson(response);
      final data = json.decode(jsonStr) as Map<String, dynamic>;
      
      final dimensions = (data['dimensions'] as List)
          .map((d) => CapabilityDimension(
            name: d['name'] as String,
            score: d['score'] as int,
            strengths: List<String>.from(d['strengths'] as List? ?? []),
            weaknesses: List<String>.from(d['weaknesses'] as List? ?? []),
            improvements: List<String>.from(d['improvements'] as List? ?? []),
          ))
          .toList();
      
      return CapabilityAssessment(
        overallScore: data['overallScore'] as int,
        dimensions: dimensions,
        coreCompetencies: List<String>.from(data['coreCompetencies'] as List? ?? []),
        limitationAreas: List<String>.from(data['limitationAreas'] as List? ?? []),
        confidenceInAssessment: (data['confidenceInAssessment'] as num?)?.toDouble() ?? 0.5,
      );
    } catch (e) {
      return CapabilityAssessment(
        overallScore: 50,
        dimensions: [],
        coreCompetencies: [],
        limitationAreas: ['解析失败'],
        confidenceInAssessment: 0.3,
      );
    }
  }
  
  /// 解析任务匹配
  TaskMatching _parseTaskMatching(String response, String task, String mode) {
    try {
      final jsonStr = _extractJson(response);
      final data = json.decode(jsonStr) as Map<String, dynamic>;
      
      final riskData = data['riskAssessment'] as Map<String, dynamic>?;
      
      return TaskMatching(
        task: task,
        mode: mode,
        canPerform: data['canPerform'] as bool,
        confidence: (data['confidence'] as num).toDouble(),
        requiredCapabilities: List<String>.from(data['requiredCapabilities'] as List? ?? []),
        missingCapabilities: List<String>.from(data['missingCapabilities'] as List? ?? []),
        capabilityGaps: List<String>.from(data['capabilityGaps'] as List? ?? []),
        alternativeApproach: data['alternativeApproach'] as String?,
        riskAssessment: riskData != null ? TaskRisk(
          level: _parseRiskLevel(riskData['level'] as String),
          factors: List<String>.from(riskData['factors'] as List? ?? []),
          mitigations: List<String>.from(riskData['mitigations'] as List? ?? []),
        ) : null,
        suggestedTools: List<String>.from(data['suggestedTools'] as List? ?? []),
        estimatedDifficulty: _parseTaskDifficulty(data['estimatedDifficulty'] as String?),
      );
    } catch (e) {
      return TaskMatching(
        task: task,
        mode: mode,
        canPerform: false,
        confidence: 0.3,
        requiredCapabilities: [],
        missingCapabilities: ['解析失败'],
        capabilityGaps: [],
        estimatedDifficulty: TaskDifficulty.unknown,
      );
    }
  }
  
  /// 解析自我反思
  SelfReflection _parseSelfReflection(String response) {
    try {
      final jsonStr = _extractJson(response);
      final data = json.decode(jsonStr) as Map<String, dynamic>;
      
      final perfData = data['performanceAssessment'] as Map<String, dynamic>;
      final improveData = data['improvements'] as List;
      final learningData = data['learningPlan'] as Map<String, dynamic>;
      
      return SelfReflection(
        performanceAssessment: PerformanceAssessment(
          strengths: List<String>.from(perfData['strengths'] as List? ?? []),
          weaknesses: List<String>.from(perfData['weaknesses'] as List? ?? []),
          score: perfData['score'] as int,
        ),
        feedbackAnalysis: data['feedbackAnalysis'] != null
          ? FeedbackAnalysis.fromJson(data['feedbackAnalysis'] as Map<String, dynamic>)
          : null,
        improvements: improveData.map((i) => Improvement.fromJson(i as Map<String, dynamic>)).toList(),
        learningPlan: LearningPlan.fromJson(learningData),
        selfAwareness: data['selfAwareness'] != null
          ? SelfAwareness.fromJson(data['selfAwareness'] as Map<String, dynamic>)
          : null,
      );
    } catch (e) {
      return SelfReflection(
        performanceAssessment: PerformanceAssessment(
          strengths: [],
          weaknesses: ['解析失败'],
          score: 50,
        ),
        improvements: [],
        learningPlan: LearningPlan(
          shortTerm: [],
          mediumTerm: [],
          longTerm: [],
          resources: [],
        ),
      );
    }
  }
  
  /// 解析能力提升计划
  CapabilityImprovementPlan _parseImprovementPlan(String response) {
    try {
      final jsonStr = _extractJson(response);
      final data = json.decode(jsonStr) as Map<String, dynamic>;
      
      final priorities = (data['priorities'] as List)
          .map((p) => ImprovementPriority.fromJson(p as Map<String, dynamic>))
          .toList();
      
      final learningPath = (data['learningPath'] as List)
          .map((l) => LearningPath.fromJson(l as Map<String, dynamic>))
          .toList();
      
      final timelineData = data['timeline'] as Map<String, dynamic>;
      final resourceData = data['resourceNeeds'] as Map<String, dynamic>?;
      
      return CapabilityImprovementPlan(
        priorities: priorities,
        learningPath: learningPath,
        timeline: ImprovementTimeline(
          shortTerm: TimelinePhase.fromJson(timelineData['shortTerm'] as Map<String, dynamic>),
          mediumTerm: TimelinePhase.fromJson(timelineData['mediumTerm'] as Map<String, dynamic>),
          longTerm: TimelinePhase.fromJson(timelineData['longTerm'] as Map<String, dynamic>),
        ),
        resourceNeeds: resourceData != null
          ? ResourceNeeds.fromJson(resourceData)
          : ResourceNeeds(),
      );
    } catch (e) {
      return CapabilityImprovementPlan(
        priorities: [],
        learningPath: [],
        timeline: ImprovementTimeline(
          shortTerm: TimelinePhase(duration: '1-2周', goals: [], expectedImprovement: 5),
          mediumTerm: TimelinePhase(duration: '1-3个月', goals: [], expectedImprovement: 15),
          longTerm: TimelinePhase(duration: '3-12个月', goals: [], expectedImprovement: 30),
        ),
        resourceNeeds: ResourceNeeds(),
      );
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
  
  // 辅助解析函数
  TaskDifficulty _parseTaskDifficulty(String? s) =>
    TaskDifficulty.values.firstWhere((e) => e.name == s, orElse: () => TaskDifficulty.medium);
  
  String _parseRiskLevel(String s) => s;
}

// ===== 数据模型 =====

/// 能力评估
class CapabilityAssessment {
  final int overallScore;
  final List<CapabilityDimension> dimensions;
  final List<String> coreCompetencies;
  final List<String> limitationAreas;
  final double confidenceInAssessment;
  
  CapabilityAssessment({
    required this.overallScore,
    required this.dimensions,
    required this.coreCompetencies,
    required this.limitationAreas,
    required this.confidenceInAssessment,
  });
}

/// 能力维度
class CapabilityDimension {
  final String name;
  final int score;
  final List<String> strengths;
  final List<String> weaknesses;
  final List<String> improvements;
  
  CapabilityDimension({
    required this.name,
    required this.score,
    required this.strengths,
    required this.weaknesses,
    required this.improvements,
  });
}

/// 任务匹配
class TaskMatching {
  final String task;
  final String mode;
  final bool canPerform;
  final double confidence;
  final List<String> requiredCapabilities;
  final List<String> missingCapabilities;
  final List<String> capabilityGaps;
  final String? alternativeApproach;
  final TaskRisk? riskAssessment;
  final List<String> suggestedTools;
  final TaskDifficulty estimatedDifficulty;
  
  TaskMatching({
    required this.task,
    required this.mode,
    required this.canPerform,
    required this.confidence,
    required this.requiredCapabilities,
    required this.missingCapabilities,
    required this.capabilityGaps,
    this.alternativeApproach,
    this.riskAssessment,
    this.suggestedTools = const [],
    required this.estimatedDifficulty,
  });
}

class TaskRisk {
  final String level;
  final List<String> factors;
  final List<String> mitigations;
  
  TaskRisk({
    required this.level,
    required this.factors,
    required this.mitigations,
  });
}

enum TaskDifficulty {
  easy,
  medium,
  hard,
  expert,
  unknown,
}

/// 自我反思
class SelfReflection {
  final PerformanceAssessment performanceAssessment;
  final FeedbackAnalysis? feedbackAnalysis;
  final List<Improvement> improvements;
  final LearningPlan learningPlan;
  final SelfAwareness? selfAwareness;
  
  SelfReflection({
    required this.performanceAssessment,
    this.feedbackAnalysis,
    required this.improvements,
    required this.learningPlan,
    this.selfAwareness,
  });
}

class PerformanceAssessment {
  final List<String> strengths;
  final List<String> weaknesses;
  final int score;
  
  PerformanceAssessment({
    required this.strengths,
    required this.weaknesses,
    required this.score,
  });
}

class FeedbackAnalysis {
  final List<String> userNeeds;
  final String emotionalState;
  final double satisfactionLevel;
  final List<String> unspokenExpectations;
  
  FeedbackAnalysis({
    required this.userNeeds,
    required this.emotionalState,
    required this.satisfactionLevel,
    required this.unspokenExpectations,
  });
  
  factory FeedbackAnalysis.fromJson(Map<String, dynamic> json) => FeedbackAnalysis(
    userNeeds: List<String>.from(json['userNeeds'] as List? ?? []),
    emotionalState: json['emotionalState'] as String? ?? '',
    satisfactionLevel: (json['satisfactionLevel'] as num?)?.toDouble() ?? 0.5,
    unspokenExpectations: List<String>.from(json['unspokenExpectations'] as List? ?? []),
  );
}

class Improvement {
  final String area;
  final String current;
  final String target;
  final List<String> actions;
  final String priority;
  final String timeline;
  
  Improvement({
    required this.area,
    required this.current,
    required this.target,
    required this.actions,
    required this.priority,
    required this.timeline,
  });
  
  factory Improvement.fromJson(Map<String, dynamic> json) => Improvement(
    area: json['area'] as String,
    current: json['current'] as String,
    target: json['target'] as String,
    actions: List<String>.from(json['actions'] as List? ?? []),
    priority: json['priority'] as String? ?? 'medium',
    timeline: json['timeline'] as String? ?? '',
  );
}

class LearningPlan {
  final List<String> shortTerm;
  final List<String> mediumTerm;
  final List<String> longTerm;
  final List<String> resources;
  
  LearningPlan({
    required this.shortTerm,
    required this.mediumTerm,
    required this.longTerm,
    required this.resources,
  });
  
  factory LearningPlan.fromJson(Map<String, dynamic> json) => LearningPlan(
    shortTerm: List<String>.from(json['shortTerm'] as List? ?? []),
    mediumTerm: List<String>.from(json['mediumTerm'] as List? ?? []),
    longTerm: List<String>.from(json['longTerm'] as List? ?? []),
    resources: List<String>.from(json['resources'] as List? ?? []),
  );
}

class SelfAwareness {
  final List<String> knownStrengths;
  final List<String> knownWeaknesses;
  final List<String> blindSpots;
  final List<String> overConfidence;
  final List<String> underConfidence;
  
  SelfAwareness({
    required this.knownStrengths,
    required this.knownWeaknesses,
    required this.blindSpots,
    required this.overConfidence,
    required this.underConfidence,
  });
  
  factory SelfAwareness.fromJson(Map<String, dynamic> json) => SelfAwareness(
    knownStrengths: List<String>.from(json['knownStrengths'] as List? ?? []),
    knownWeaknesses: List<String>.from(json['knownWeaknesses'] as List? ?? []),
    blindSpots: List<String>.from(json['blindSpots'] as List? ?? []),
    overConfidence: List<String>.from(json['overConfidence'] as List? ?? []),
    underConfidence: List<String>.from(json['underConfidence'] as List? ?? []),
  );
}

/// 能力提升计划
class CapabilityImprovementPlan {
  final List<ImprovementPriority> priorities;
  final List<LearningPath> learningPath;
  final ImprovementTimeline timeline;
  final ResourceNeeds resourceNeeds;
  
  CapabilityImprovementPlan({
    required this.priorities,
    required this.learningPath,
    required this.timeline,
    required this.resourceNeeds,
  });
}

class ImprovementPriority {
  final String capability;
  final int currentLevel;
  final int targetLevel;
  final String priority;
  final String rationale;
  
  ImprovementPriority({
    required this.capability,
    required this.currentLevel,
    required this.targetLevel,
    required this.priority,
    required this.rationale,
  });
  
  factory ImprovementPriority.fromJson(Map<String, dynamic> json) => ImprovementPriority(
    capability: json['capability'] as String,
    currentLevel: json['currentLevel'] as int,
    targetLevel: json['targetLevel'] as int,
    priority: json['priority'] as String? ?? 'medium',
    rationale: json['rationale'] as String? ?? '',
  );
}

class LearningPath {
  final String capability;
  final List<LearningStep> steps;
  
  LearningPath({
    required this.capability,
    required this.steps,
  });
  
  factory LearningPath.fromJson(Map<String, dynamic> json) => LearningPath(
    capability: json['capability'] as String,
    steps: (json['steps'] as List)
        .map((s) => LearningStep.fromJson(s as Map<String, dynamic>))
        .toList(),
  );
}

class LearningStep {
  final String action;
  final String method;
  final String duration;
  final List<String> resources;
  final String milestone;
  
  LearningStep({
    required this.action,
    required this.method,
    required this.duration,
    required this.resources,
    required this.milestone,
  });
  
  factory LearningStep.fromJson(Map<String, dynamic> json) => LearningStep(
    action: json['action'] as String,
    method: json['method'] as String,
    duration: json['duration'] as String? ?? '',
    resources: List<String>.from(json['resources'] as List? ?? []),
    milestone: json['milestone'] as String? ?? '',
  );
}

class ImprovementTimeline {
  final TimelinePhase shortTerm;
  final TimelinePhase mediumTerm;
  final TimelinePhase longTerm;
  
  ImprovementTimeline({
    required this.shortTerm,
    required this.mediumTerm,
    required this.longTerm,
  });
}

class TimelinePhase {
  final String duration;
  final List<String> goals;
  final int expectedImprovement;
  
  TimelinePhase({
    required this.duration,
    required this.goals,
    required this.expectedImprovement,
  });
  
  factory TimelinePhase.fromJson(Map<String, dynamic> json) => TimelinePhase(
    duration: json['duration'] as String? ?? '',
    goals: List<String>.from(json['goals'] as List? ?? []),
    expectedImprovement: json['expectedImprovement'] as int? ?? 0,
  );
}

class ResourceNeeds {
  final List<String> knowledge;
  final List<String> tools;
  final List<String> data;
  final List<String> feedback;
  
  ResourceNeeds({
    this.knowledge = const [],
    this.tools = const [],
    this.data = const [],
    this.feedback = const [],
  });
  
  factory ResourceNeeds.fromJson(Map<String, dynamic> json) => ResourceNeeds(
    knowledge: List<String>.from(json['knowledge'] as List? ?? []),
    tools: List<String>.from(json['tools'] as List? ?? []),
    data: List<String>.from(json['data'] as List? ?? []),
    feedback: List<String>.from(json['feedback'] as List? ?? []),
  );
}
