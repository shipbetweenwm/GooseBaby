import 'dart:convert';
import 'package:shared_preferences/shared_preferences.dart';
import '../models/models.dart';
import 'emotion_analyzer.dart';
import '../ai/llm/llm_provider.dart';

/// 情感推理引擎（基于大模型）
/// 使用LLM进行深度情感推理：原因分析、趋势预测、干预建议
class EmotionReasoner {
  static const String _storageKey = 'emotion_reasoner_history';
  
  final LLMProvider llmProvider;
  final List<EmotionContext> emotionHistory;
  
  EmotionReasoner({
    required this.llmProvider,
    List<EmotionContext>? emotionHistory,
  }) : emotionHistory = emotionHistory ?? [];
  
  /// 从存储加载历史数据
  static Future<EmotionReasoner> load(LLMProvider llmProvider) async {
    final prefs = await SharedPreferences.getInstance();
    final jsonString = prefs.getString(_storageKey);
    
    List<EmotionContext> history = [];
    if (jsonString != null) {
      try {
        final List<dynamic> jsonList = json.decode(jsonString);
        history = jsonList.map((e) => EmotionContext.fromJson(e)).toList();
      } catch (e) {
        // 解析失败，使用空历史
      }
    }
    
    return EmotionReasoner(
      llmProvider: llmProvider,
      emotionHistory: history,
    );
  }
  
  /// 保存历史数据
  Future<void> save() async {
    final prefs = await SharedPreferences.getInstance();
    final jsonList = emotionHistory.map((e) => e.toJson()).toList();
    await prefs.setString(_storageKey, json.encode(jsonList));
  }
  
  /// 记录情绪上下文
  Future<void> recordEmotion({
    required String emotion,
    required double intensity,
    required String context,
    required DateTime timestamp,
  }) async {
    emotionHistory.add(EmotionContext(
      emotion: emotion,
      intensity: intensity,
      context: context,
      timestamp: timestamp,
    ));
    
    // 只保留最近50条记录
    if (emotionHistory.length > 50) {
      emotionHistory.removeRange(0, emotionHistory.length - 50);
    }
    
    await save();
  }
  
  /// 分析情绪原因（使用大模型推理）
  Future<EmotionAnalysis> analyzeCause({
    required String currentEmotion,
    required double intensity,
    required String recentContext,
  }) async {
    final prompt = _buildAnalysisPrompt(
      currentEmotion: currentEmotion,
      intensity: intensity,
      recentContext: recentContext,
    );
    
    try {
      final response = await llmProvider.chat(prompt);
      return _parseAnalysisResponse(response, currentEmotion);
    } catch (e) {
      // 如果LLM调用失败，返回基础分析
      return EmotionAnalysis(
        emotion: currentEmotion,
        reasons: [
          EmotionReason(
            category: ReasonCategory.unknown,
            description: '无法分析具体原因',
            confidence: 0.3,
            triggers: [],
          ),
        ],
        timestamp: DateTime.now(),
      );
    }
  }
  
  /// 预测情绪变化趋势（使用大模型推理）
  Future<EmotionPrediction> predict({
    required String currentEmotion,
    required double intensity,
    required String recentContext,
    String? upcomingEvent,
  }) async {
    final prompt = _buildPredictionPrompt(
      currentEmotion: currentEmotion,
      intensity: intensity,
      recentContext: recentContext,
      upcomingEvent: upcomingEvent,
    );
    
    try {
      final response = await llmProvider.chat(prompt);
      return _parsePredictionResponse(response, currentEmotion);
    } catch (e) {
      // 如果LLM调用失败，返回默认预测
      return EmotionPrediction(
        currentEmotion: currentEmotion,
        shortTermTrend: _ShortTermPrediction(
          trend: EmotionTrend.stable,
          probability: 0.5,
          expectedDuration: Duration(hours: 1),
          likelyNextEmotions: [currentEmotion],
        ),
        mediumTermTrend: _MediumTermPrediction(
          trend: EmotionTrend.stable,
          probability: 0.5,
          factors: ['日常波动'],
        ),
        risks: [],
        timestamp: DateTime.now(),
      );
    }
  }
  
  /// 生成干预建议（使用大模型推理）
  Future<List<InterventionSuggestion>> suggestInterventions({
    required String currentEmotion,
    required double intensity,
    required String recentContext,
    required PetState petState,
    EmotionAnalysis? analysis,
    EmotionPrediction? prediction,
  }) async {
    final prompt = _buildInterventionPrompt(
      currentEmotion: currentEmotion,
      intensity: intensity,
      recentContext: recentContext,
      petState: petState,
      analysis: analysis,
      prediction: prediction,
    );
    
    try {
      final response = await llmProvider.chat(prompt);
      return _parseInterventionResponse(response);
    } catch (e) {
      // 如果LLM调用失败，返回基础干预
      return _getBasicInterventions(currentEmotion, petState);
    }
  }
  
  /// 构建分析prompt
  String _buildAnalysisPrompt({
    required String currentEmotion,
    required double intensity,
    required String recentContext,
  }) {
    final emotionHistoryStr = _formatEmotionHistory();
    
    return '''
你是一个情感分析专家，需要分析用户当前情绪的原因。

## 当前情绪
- 情绪类型：${EmotionAnalyzer.getEmotionName(currentEmotion)}
- 情绪强度：${(intensity * 100).toStringAsFixed(0)}%
- 最近对话：$recentContext

## 情绪历史（最近10条）
$emotionHistoryStr

## 分析任务
请分析当前情绪的可能原因，包括：
1. 时间因素（深夜、周一等）
2. 上下文内容（工作、关系、健康等）
3. 情绪模式（连续负面、情绪波动等）
4. 其他可能的触发因素

## 输出格式（JSON）
```json
{
  "reasons": [
    {
      "category": "work_related|relationship|health|time_of_day|pattern|duration|unknown",
      "description": "具体原因描述",
      "confidence": 0.8,
      "triggers": ["触发词1", "触发词2"]
    }
  ]
}
```

请严格按照JSON格式输出，不要添加任何其他内容。
''';
  }
  
  /// 构建预测prompt
  String _buildPredictionPrompt({
    required String currentEmotion,
    required double intensity,
    required String recentContext,
    String? upcomingEvent,
  }) {
    final emotionHistoryStr = _formatEmotionHistory();
    
    return '''
你是一个情绪预测专家，需要预测用户情绪的变化趋势。

## 当前情绪
- 情绪类型：${EmotionAnalyzer.getEmotionName(currentEmotion)}
- 情绪强度：${(intensity * 100).toStringAsFixed(0)}%
- 当前时间：${DateTime.now().toString()}
- 最近对话：$recentContext
${upcomingEvent != null ? '- 即将发生的事件：$upcomingEvent' : ''}

## 情绪历史（最近10条）
$emotionHistoryStr

## 预测任务
请预测情绪的短期和中期变化趋势，以及潜在风险。

## 输出格式（JSON）
```json
{
  "shortTerm": {
    "trend": "improving|stable|worsening",
    "probability": 0.65,
    "expectedDuration": "1小时",
    "likelyNextEmotions": ["sad", "calm"]
  },
  "mediumTerm": {
    "trend": "improving|stable|worsening",
    "probability": 0.55,
    "factors": ["工作结束", "放松时段"]
  },
  "risks": [
    {
      "type": "prolonged_negative|emotional_instability|anxiety_escalation",
      "severity": "low|medium|high",
      "description": "风险描述",
      "probability": 0.6
    }
  ]
}
```

请严格按照JSON格式输出，不要添加任何其他内容。
''';
  }
  
  /// 构建干预prompt
  String _buildInterventionPrompt({
    required String currentEmotion,
    required double intensity,
    required String recentContext,
    required PetState petState,
    EmotionAnalysis? analysis,
    EmotionPrediction? prediction,
  }) {
    final analysisStr = analysis != null ? _formatAnalysis(analysis) : '无';
    final predictionStr = prediction != null ? _formatPrediction(prediction) : '无';
    
    return '''
你是一个情感干预专家，为AI宠物鹅宝设计干预策略。

## 用户当前状态
- 情绪类型：${EmotionAnalyzer.getEmotionName(currentEmotion)}
- 情绪强度：${(intensity * 100).toStringAsFixed(0)}%
- 最近对话：$recentContext

## 鹅宝当前性格
- 温柔度：${petState.gentleness.toStringAsFixed(0)}%
- 活泼度：${petState.liveliness.toStringAsFixed(0)}%
- 傲娇度：${petState.tsundere.toStringAsFixed(0)}%
- 性格描述：${petState.gentleness >= 70 ? '温柔体贴' : petState.gentleness >= 50 ? '善解人意' : '独立自主'}
${petState.liveliness >= 70 ? '活泼好动' : petState.liveliness >= 50 ? '开朗活泼' : '沉稳内敛'}
${petState.tsundere >= 70 ? '傲娇可爱' : petState.tsundere >= 50 ? '小傲娇' : ''}

## 情绪分析结果
$analysisStr

## 情绪预测结果
$predictionStr

## 干预任务
请生成合适的干预建议，包括：
1. 情感支持（倾听、陪伴、认可）
2. 问题解决（分析、建议、协助）
3. 情绪调节（放松、转移、宣泄）
4. 自我关怀（休息、优先级、边界）

注意：
- 干预策略要符合鹅宝的性格特点
- 话术要自然、温暖、不说教
- 避免过度干预，尊重用户自主性
- 如果用户情绪严重，建议专业帮助

## 输出格式（JSON）
```json
{
  "interventions": [
    {
      "type": "emotional_support|problem_solving|emotional_regulation|self_care",
      "priority": "high|medium|low",
      "action": "行动描述",
      "script": "具体话术",
      "expectedEffect": "预期效果",
      "timing": "immediate|within_hour|flexible"
    }
  ]
}
```

请严格按照JSON格式输出，不要添加任何其他内容。
''';
  }
  
  /// 解析分析响应
  EmotionAnalysis _parseAnalysisResponse(String response, String emotion) {
    try {
      // 提取JSON部分
      final jsonStr = _extractJson(response);
      final data = json.decode(jsonStr) as Map<String, dynamic>;
      
      final reasons = (data['reasons'] as List)
          .map((r) => EmotionReason(
            category: _parseReasonCategory(r['category'] as String),
            description: r['description'] as String,
            confidence: (r['confidence'] as num).toDouble(),
            triggers: List<String>.from(r['triggers'] as List),
          ))
          .toList();
      
      return EmotionAnalysis(
        emotion: emotion,
        reasons: reasons,
        timestamp: DateTime.now(),
      );
    } catch (e) {
      // 解析失败，返回默认分析
      return EmotionAnalysis(
        emotion: emotion,
        reasons: [
          EmotionReason(
            category: ReasonCategory.unknown,
            description: '无法解析分析结果',
            confidence: 0.3,
            triggers: [],
          ),
        ],
        timestamp: DateTime.now(),
      );
    }
  }
  
  /// 解析预测响应
  EmotionPrediction _parsePredictionResponse(String response, String emotion) {
    try {
      final jsonStr = _extractJson(response);
      final data = json.decode(jsonStr) as Map<String, dynamic>;
      
      final shortTerm = data['shortTerm'] as Map<String, dynamic>;
      final mediumTerm = data['mediumTerm'] as Map<String, dynamic>;
      final risks = (data['risks'] as List)
          .map((r) => EmotionRisk(
            type: _parseRiskType(r['type'] as String),
            severity: _parseRiskSeverity(r['severity'] as String),
            description: r['description'] as String,
            probability: (r['probability'] as num).toDouble(),
          ))
          .toList();
      
      return EmotionPrediction(
        currentEmotion: emotion,
        shortTermTrend: _ShortTermPrediction(
          trend: _parseEmotionTrend(shortTerm['trend'] as String),
          probability: (shortTerm['probability'] as num).toDouble(),
          expectedDuration: _parseDuration(shortTerm['expectedDuration'] as String),
          likelyNextEmotions: List<String>.from(shortTerm['likelyNextEmotions'] as List),
        ),
        mediumTermTrend: _MediumTermPrediction(
          trend: _parseEmotionTrend(mediumTerm['trend'] as String),
          probability: (mediumTerm['probability'] as num).toDouble(),
          factors: List<String>.from(mediumTerm['factors'] as List),
        ),
        risks: risks,
        timestamp: DateTime.now(),
      );
    } catch (e) {
      // 解析失败，返回默认预测
      return EmotionPrediction(
        currentEmotion: emotion,
        shortTermTrend: _ShortTermPrediction(
          trend: EmotionTrend.stable,
          probability: 0.5,
          expectedDuration: Duration(hours: 1),
          likelyNextEmotions: [emotion],
        ),
        mediumTermTrend: _MediumTermPrediction(
          trend: EmotionTrend.stable,
          probability: 0.5,
          factors: ['日常波动'],
        ),
        risks: [],
        timestamp: DateTime.now(),
      );
    }
  }
  
  /// 解析干预响应
  List<InterventionSuggestion> _parseInterventionResponse(String response) {
    try {
      final jsonStr = _extractJson(response);
      final data = json.decode(jsonStr) as Map<String, dynamic>;
      
      return (data['interventions'] as List)
          .map((i) => InterventionSuggestion(
            type: _parseInterventionType(i['type'] as String),
            priority: _parseInterventionPriority(i['priority'] as String),
            action: i['action'] as String,
            script: i['script'] as String,
            expectedEffect: i['expectedEffect'] as String,
            timing: _parseTiming(i['timing'] as String),
          ))
          .toList();
    } catch (e) {
      // 解析失败，返回空列表
      return [];
    }
  }
  
  /// 格式化情绪历史
  String _formatEmotionHistory() {
    if (emotionHistory.isEmpty) {
      return '暂无历史记录';
    }
    
    final recent = emotionHistory.reversed.take(10).toList();
    return recent.asMap().entries.map((e) {
      final i = e.key + 1;
      final ctx = e.value;
      return '$i. ${ctx.timestamp.toString()} - ${EmotionAnalyzer.getEmotionName(ctx.emotion)} (${(ctx.intensity * 100).toStringAsFixed(0)}%) - ${ctx.context}';
    }).join('\n');
  }
  
  /// 格式化分析结果
  String _formatAnalysis(EmotionAnalysis analysis) {
    return analysis.reasons.asMap().entries.map((e) {
      final i = e.key + 1;
      final r = e.value;
      return '$i. ${r.description}（置信度：${(r.confidence * 100).toStringAsFixed(0)}%）';
    }).join('\n');
  }
  
  /// 格式化预测结果
  String _formatPrediction(EmotionPrediction prediction) {
    return '''
短期趋势：${prediction.shortTermTrend.trend.name}（概率：${(prediction.shortTermTrend.probability * 100).toStringAsFixed(0)}%）
中期趋势：${prediction.mediumTermTrend.trend.name}（概率：${(prediction.mediumTermTrend.probability * 100).toStringAsFixed(0)}%）
风险数量：${prediction.risks.length}
''';
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
  
  /// 获取基础干预（LLM调用失败时的后备方案）
  List<InterventionSuggestion> _getBasicInterventions(String emotion, PetState petState) {
    switch (emotion) {
      case EmotionAnalyzer.sad:
        return [
          InterventionSuggestion(
            type: InterventionType.emotionalSupport,
            priority: InterventionPriority.high,
            action: '主动倾听',
            script: '要不要聊聊？我会陪着你的~',
            expectedEffect: '提供情感支持',
            timing: InterventionTiming.immediate,
          ),
        ];
      case EmotionAnalyzer.anxious:
        return [
          InterventionSuggestion(
            type: InterventionType.emotionalRegulation,
            priority: InterventionPriority.high,
            action: '引导放松',
            script: '深呼吸...我们一起放松一下？',
            expectedEffect: '缓解焦虑',
            timing: InterventionTiming.immediate,
          ),
        ];
      default:
        return [
          InterventionSuggestion(
            type: InterventionType.emotionalSupport,
            priority: InterventionPriority.medium,
            action: '主动关心',
            script: '在干嘛呢？',
            expectedEffect: '保持连接',
            timing: InterventionTiming.flexible,
          ),
        ];
    }
  }
  
  // 辅助解析函数
  ReasonCategory _parseReasonCategory(String s) => 
    ReasonCategory.values.firstWhere((e) => e.name == s, orElse: () => ReasonCategory.unknown);
  
  EmotionTrend _parseEmotionTrend(String s) => 
    EmotionTrend.values.firstWhere((e) => e.name == s, orElse: () => EmotionTrend.stable);
  
  RiskType _parseRiskType(String s) => 
    RiskType.values.firstWhere((e) => e.name == s, orElse: () => RiskType.prolongedNegative);
  
  RiskSeverity _parseRiskSeverity(String s) => 
    RiskSeverity.values.firstWhere((e) => e.name == s, orElse: () => RiskSeverity.low);
  
  InterventionType _parseInterventionType(String s) => 
    InterventionType.values.firstWhere((e) => e.name == s, orElse: () => InterventionType.emotionalSupport);
  
  InterventionPriority _parseInterventionPriority(String s) => 
    InterventionPriority.values.firstWhere((e) => e.name == s, orElse: () => InterventionPriority.medium);
  
  InterventionTiming _parseTiming(String s) => 
    InterventionTiming.values.firstWhere((e) => e.name == s, orElse: () => InterventionTiming.flexible);
  
  Duration _parseDuration(String s) {
    // 简单解析，如"1小时"、"30分钟"
    if (s.contains('小时')) {
      final hours = int.tryParse(RegExp(r'\d+').firstMatch(s)?.group(0) ?? '1') ?? 1;
      return Duration(hours: hours);
    } else if (s.contains('分钟')) {
      final minutes = int.tryParse(RegExp(r'\d+').firstMatch(s)?.group(0) ?? '30') ?? 30;
      return Duration(minutes: minutes);
    }
    return Duration(hours: 1);
  }
}

// ===== 数据模型 =====

/// 情绪上下文
class EmotionContext {
  final String emotion;
  final double intensity;
  final String context;
  final DateTime timestamp;
  
  EmotionContext({
    required this.emotion,
    required this.intensity,
    required this.context,
    required this.timestamp,
  });
  
  Map<String, dynamic> toJson() => {
    'emotion': emotion,
    'intensity': intensity,
    'context': context,
    'timestamp': timestamp.toIso8601String(),
  };
  
  factory EmotionContext.fromJson(Map<String, dynamic> json) => EmotionContext(
    emotion: json['emotion'] as String,
    intensity: (json['intensity'] as num).toDouble(),
    context: json['context'] as String,
    timestamp: DateTime.parse(json['timestamp'] as String),
  );
}

/// 情绪分析结果
class EmotionAnalysis {
  final String emotion;
  final List<EmotionReason> reasons;
  final DateTime timestamp;
  
  EmotionAnalysis({
    required this.emotion,
    required this.reasons,
    required this.timestamp,
  });
}

/// 情绪原因
class EmotionReason {
  final ReasonCategory category;
  final String description;
  final double confidence;
  final List<String> triggers;
  
  EmotionReason({
    required this.category,
    required this.description,
    required this.confidence,
    required this.triggers,
  });
}

enum ReasonCategory {
  workRelated,      // 工作相关
  relationship,     // 人际关系
  health,           // 健康问题
  timeOfDay,        // 时间因素
  pattern,          // 情绪模式
  duration,         // 持续时间
  unknown,          // 未知原因
}

/// 情绪预测结果
class EmotionPrediction {
  final String currentEmotion;
  final _ShortTermPrediction shortTermTrend;
  final _MediumTermPrediction mediumTermTrend;
  final List<EmotionRisk> risks;
  final DateTime timestamp;
  
  EmotionPrediction({
    required this.currentEmotion,
    required this.shortTermTrend,
    required this.mediumTermTrend,
    required this.risks,
    required this.timestamp,
  });
}

class _ShortTermPrediction {
  final EmotionTrend trend;
  final double probability;
  final Duration expectedDuration;
  final List<String> likelyNextEmotions;
  
  _ShortTermPrediction({
    required this.trend,
    required this.probability,
    required this.expectedDuration,
    required this.likelyNextEmotions,
  });
}

class _MediumTermPrediction {
  final EmotionTrend trend;
  final double probability;
  final List<String> factors;
  
  _MediumTermPrediction({
    required this.trend,
    required this.probability,
    required this.factors,
  });
}

enum EmotionTrend {
  improving,  // 改善中
  stable,     // 稳定
  worsening,  // 恶化中
}

/// 情绪风险
class EmotionRisk {
  final RiskType type;
  final RiskSeverity severity;
  final String description;
  final double probability;
  
  EmotionRisk({
    required this.type,
    required this.severity,
    required this.description,
    required this.probability,
  });
}

enum RiskType {
  prolongedNegative,      // 持续负面情绪
  emotionalInstability,   // 情绪不稳定
  anxietyEscalation,      // 焦虑加剧
}

enum RiskSeverity {
  low,
  medium,
  high,
}

/// 干预建议
class InterventionSuggestion {
  final InterventionType type;
  final InterventionPriority priority;
  final String action;
  final String script;
  final String expectedEffect;
  final InterventionTiming timing;
  
  InterventionSuggestion({
    required this.type,
    required this.priority,
    required this.action,
    required this.script,
    required this.expectedEffect,
    required this.timing,
  });
}

enum InterventionType {
  emotionalSupport,      // 情感支持
  problemSolving,        // 问题解决
  emotionalRegulation,   // 情绪调节
  selfCare,              // 自我关怀
}

enum InterventionPriority {
  high,
  medium,
  low,
}

enum InterventionTiming {
  immediate,     // 立即执行
  withinHour,    // 1小时内
  flexible,      // 灵活安排
}
