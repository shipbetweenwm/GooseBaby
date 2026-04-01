import 'dart:convert';
import 'package:shared_preferences/shared_preferences.dart';
import '../ai/llm/llm_provider.dart';

/// 工具使用学习器（基于大模型）
/// 从成功/失败案例中学习最佳实践，优化工具使用策略
class ToolLearner {
  static const String _storageKey = 'tool_learner_cases';
  static const int _maxCases = 100; // 最多保留100个案例
  
  final LLMProvider llmProvider;
  final List<ToolUsageCase> cases;
  
  ToolLearner({
    required this.llmProvider,
    List<ToolUsageCase>? cases,
  }) : cases = cases ?? [];
  
  /// 从存储加载案例
  static Future<ToolLearner> load(LLMProvider llmProvider) async {
    final prefs = await SharedPreferences.getInstance();
    final jsonString = prefs.getString(_storageKey);
    
    List<ToolUsageCase> cases = [];
    if (jsonString != null) {
      try {
        final List<dynamic> jsonList = json.decode(jsonString);
        cases = jsonList.map((e) => ToolUsageCase.fromJson(e)).toList();
      } catch (e) {
        // 解析失败，使用空列表
      }
    }
    
    return ToolLearner(
      llmProvider: llmProvider,
      cases: cases,
    );
  }
  
  /// 保存案例
  Future<void> save() async {
    final prefs = await SharedPreferences.getInstance();
    final jsonList = cases.map((e) => e.toJson()).toList();
    await prefs.setString(_storageKey, json.encode(jsonList));
  }
  
  /// 记录工具使用案例
  Future<void> recordCase({
    required String toolName,
    required Map<String, dynamic> parameters,
    required bool isSuccess,
    required String result,
    String? errorMessage,
    Duration? executionTime,
    Map<String, dynamic>? context,
  }) async {
    final case_ = ToolUsageCase(
      id: DateTime.now().millisecondsSinceEpoch.toString(),
      toolName: toolName,
      parameters: parameters,
      isSuccess: isSuccess,
      result: result,
      errorMessage: errorMessage,
      executionTime: executionTime,
      timestamp: DateTime.now(),
      context: context,
    );
    
    cases.add(case_);
    
    // 保留最近的案例
    if (cases.length > _maxCases) {
      cases.removeRange(0, cases.length - _maxCases);
    }
    
    await save();
    
    // 如果是失败案例，立即分析并学习
    if (!isSuccess) {
      await _learnFromFailure(case_);
    }
  }
  
  /// 从失败案例中学习
  Future<ToolUsageBestPractice> _learnFromFailure(ToolUsageCase failureCase) async {
    // 查找相似的成功案例
    final similarSuccesses = _findSimilarCases(
      failureCase.toolName,
      successOnly: true,
    );
    
    // 使用LLM分析失败原因和最佳实践
    final analysis = await _analyzeFailureWithLLM(
      failureCase: failureCase,
      similarSuccesses: similarSuccesses,
    );
    
    // 生成最佳实践
    final bestPractice = analysis.bestPractice;
    
    // 更新案例的最佳实践
    final caseIndex = cases.indexWhere((c) => c.id == failureCase.id);
    if (caseIndex != -1) {
      cases[caseIndex] = cases[caseIndex].copyWith(
        lessonsLearned: analysis.lessons,
        suggestedFix: analysis.suggestedFix,
      );
      await save();
    }
    
    return bestPractice;
  }
  
  /// 获取工具的最佳实践
  Future<ToolUsageBestPractice?> getBestPractice(String toolName) async {
    // 查找该工具的所有案例
    final toolCases = cases.where((c) => c.toolName == toolName).toList();
    
    if (toolCases.isEmpty) {
      return null;
    }
    
    // 计算成功率
    final successCount = toolCases.where((c) => c.isSuccess).length;
    final successRate = successCount / toolCases.length;
    
    // 如果成功率高且有足够案例，从现有案例中提取最佳实践
    if (successRate > 0.7 && toolCases.length >= 5) {
      return _extractBestPracticeFromCases(toolName, toolCases);
    }
    
    // 否则使用LLM生成最佳实践
    return await _generateBestPracticeWithLLM(toolName, toolCases);
  }
  
  /// 预测工具使用的成功率
  Future<ToolSuccessPrediction> predictSuccess({
    required String toolName,
    required Map<String, dynamic> parameters,
  }) async {
    // 查找相似案例
    final similarCases = _findSimilarCases(toolName, parameters: parameters);
    
    if (similarCases.isEmpty) {
      return ToolSuccessPrediction(
        toolName: toolName,
        predictedSuccessRate: 0.5,
        confidence: 0.3,
        reasoning: '无历史案例参考',
      );
    }
    
    // 计算历史成功率
    final successCount = similarCases.where((c) => c.isSuccess).length;
    final historicalSuccessRate = successCount / similarCases.length;
    
    // 使用LLM分析当前参数的特殊性
    final prediction = await _predictWithLLM(
      toolName: toolName,
      parameters: parameters,
      similarCases: similarCases,
      historicalSuccessRate: historicalSuccessRate,
    );
    
    return prediction;
  }
  
  /// 查找相似案例
  List<ToolUsageCase> _findSimilarCases(
    String toolName, {
    Map<String, dynamic>? parameters,
    bool successOnly = false,
  }) {
    var similar = cases.where((c) => c.toolName == toolName);
    
    if (successOnly) {
      similar = similar.where((c) => c.isSuccess);
    }
    
    // 如果提供了参数，可以进一步筛选相似参数的案例
    // 这里简化处理，返回所有同工具案例
    return similar.toList();
  }
  
  /// 使用LLM分析失败案例
  Future<_FailureAnalysis> _analyzeFailureWithLLM({
    required ToolUsageCase failureCase,
    required List<ToolUsageCase> similarSuccesses,
  }) async {
    final prompt = '''
你是一个工具使用分析专家，需要分析工具调用失败的原因并生成最佳实践。

## 失败案例
- 工具名称：${failureCase.toolName}
- 调用参数：${json.encode(failureCase.parameters)}
- 错误信息：${failureCase.errorMessage ?? '无'}
- 执行结果：${failureCase.result}
- 上下文：${failureCase.context != null ? json.encode(failureCase.context) : '无'}

## 相似成功案例（共${similarSuccesses.length}个）
${similarSuccesses.take(3).map((c) => '''
- 参数：${json.encode(c.parameters)}
- 结果：${c.result}
''').join('\n')}

## 分析任务
1. 分析失败的根本原因
2. 对比成功案例，找出关键差异
3. 提取教训和最佳实践
4. 给出修复建议

## 输出格式（JSON）
```json
{
  "rootCause": "失败根本原因",
  "keyDifferences": ["成功案例的关键差异1", "关键差异2"],
  "lessons": ["教训1", "教训2"],
  "suggestedFix": "具体修复建议",
  "bestPractice": {
    "toolName": "工具名称",
    "description": "最佳实践描述",
    "requiredParameters": ["必要参数1", "必要参数2"],
    "recommendedParameters": {
      "参数名": "推荐值或说明"
    },
    "commonPitfalls": ["常见陷阱1", "陷阱2"],
    "successTips": ["成功技巧1", "技巧2"],
    "errorHandling": {
      "常见错误": "处理方法"
    },
    "confidence": 0.85
  }
}
```

请严格按照JSON格式输出，不要添加任何其他内容。
''';

    try {
      final response = await llmProvider.chat(prompt);
      return _parseFailureAnalysis(response);
    } catch (e) {
      // 解析失败，返回基础分析
      return _FailureAnalysis(
        lessons: ['工具调用失败'],
        suggestedFix: '检查参数和权限',
        bestPractice: ToolUsageBestPractice(
          toolName: failureCase.toolName,
          description: '基础最佳实践',
          confidence: 0.3,
        ),
      );
    }
  }
  
  /// 使用LLM生成最佳实践
  Future<ToolUsageBestPractice> _generateBestPracticeWithLLM(
    String toolName,
    List<ToolUsageCase> cases,
  ) async {
    final successCases = cases.where((c) => c.isSuccess).toList();
    final failureCases = cases.where((c) => !c.isSuccess).toList();
    
    final prompt = '''
你是一个工具使用专家，需要从历史案例中提取最佳实践。

## 工具名称
$toolName

## 成功案例（共${successCases.length}个）
${successCases.take(5).map((c) => '''
- 参数：${json.encode(c.parameters)}
- 结果：${c.result}
- 执行时间：${c.executionTime?.inMilliseconds ?? '未知'}ms
''').join('\n')}

## 失败案例（共${failureCases.length}个）
${failureCases.take(5).map((c) => '''
- 参数：${json.encode(c.parameters)}
- 错误：${c.errorMessage ?? '未知'}
''').join('\n')}

## 分析任务
从成功和失败案例中提取该工具的最佳实践，包括：
1. 必要参数和推荐参数
2. 常见陷阱和避免方法
3. 成功技巧
4. 错误处理策略

## 输出格式（JSON）
```json
{
  "toolName": "$toolName",
  "description": "最佳实践描述",
  "requiredParameters": ["必要参数1"],
  "recommendedParameters": {
    "参数名": "推荐值或说明"
  },
  "commonPitfalls": ["常见陷阱"],
  "successTips": ["成功技巧"],
  "errorHandling": {
    "错误类型": "处理方法"
  },
  "confidence": 0.8
}
```

请严格按照JSON格式输出，不要添加任何其他内容。
''';

    try {
      final response = await llmProvider.chat(prompt);
      return _parseBestPractice(response);
    } catch (e) {
      return ToolUsageBestPractice(
        toolName: toolName,
        description: '基础最佳实践',
        confidence: 0.3,
      );
    }
  }
  
  /// 使用LLM预测成功率
  Future<ToolSuccessPrediction> _predictWithLLM({
    required String toolName,
    required Map<String, dynamic> parameters,
    required List<ToolUsageCase> similarCases,
    required double historicalSuccessRate,
  }) async {
    final prompt = '''
你是一个工具使用预测专家，需要预测当前参数下工具调用的成功率。

## 工具名称
$toolName

## 当前参数
${json.encode(parameters)}

## 历史案例（共${similarCases.length}个）
成功率：${(historicalSuccessRate * 100).toStringAsFixed(0)}%
${similarCases.take(5).map((c) => '''
- 参数：${json.encode(c.parameters)}
- 结果：${c.isSuccess ? '成功' : '失败'} - ${c.errorMessage ?? c.result}
''').join('\n')}

## 预测任务
分析当前参数与历史案例的相似性，预测成功率。

## 输出格式（JSON）
```json
{
  "toolName": "$toolName",
  "predictedSuccessRate": 0.75,
  "confidence": 0.8,
  "reasoning": "参数与成功案例相似度高",
  "riskFactors": ["风险因素1"],
  "suggestions": ["建议1"]
}
```

请严格按照JSON格式输出，不要添加任何其他内容。
''';

    try {
      final response = await llmProvider.chat(prompt);
      return _parsePrediction(response, toolName);
    } catch (e) {
      return ToolSuccessPrediction(
        toolName: toolName,
        predictedSuccessRate: historicalSuccessRate,
        confidence: 0.5,
        reasoning: '基于历史成功率',
      );
    }
  }
  
  /// 从成功案例中提取最佳实践
  ToolUsageBestPractice _extractBestPracticeFromCases(
    String toolName,
    List<ToolUsageCase> cases,
  ) {
    final successCases = cases.where((c) => c.isSuccess).toList();
    
    // 统计最常用的参数组合
    final paramStats = <String, Map<String, int>>{};
    for (final case_ in successCases) {
      for (final entry in case_.parameters.entries) {
        paramStats[entry.key] = paramStats[entry.key] ?? {};
        final valueStr = entry.value.toString();
        paramStats[entry.key]![valueStr] = 
          (paramStats[entry.key]![valueStr] ?? 0) + 1;
      }
    }
    
    // 提取推荐参数值
    final recommendedParams = <String, String>{};
    paramStats.forEach((param, values) {
      final sorted = values.entries.toList()
        ..sort((a, b) => b.value.compareTo(a.value));
      if (sorted.isNotEmpty) {
        recommendedParams[param] = sorted.first.key;
      }
    });
    
    return ToolUsageBestPractice(
      toolName: toolName,
      description: '从${successCases.length}个成功案例中提取',
      recommendedParameters: recommendedParams,
      successTips: ['使用历史成功的参数组合'],
      confidence: 0.8,
    );
  }
  
  /// 解析失败分析
  _FailureAnalysis _parseFailureAnalysis(String response) {
    try {
      final jsonStr = _extractJson(response);
      final data = json.decode(jsonStr) as Map<String, dynamic>;
      
      final bestPracticeData = data['bestPractice'] as Map<String, dynamic>;
      
      return _FailureAnalysis(
        rootCause: data['rootCause'] as String?,
        lessons: List<String>.from(data['lessons'] as List? ?? []),
        suggestedFix: data['suggestedFix'] as String?,
        bestPractice: ToolUsageBestPractice(
          toolName: bestPracticeData['toolName'] as String,
          description: bestPracticeData['description'] as String? ?? '',
          requiredParameters: List<String>.from(
            bestPracticeData['requiredParameters'] as List? ?? []
          ),
          recommendedParameters: Map<String, dynamic>.from(
            bestPracticeData['recommendedParameters'] as Map? ?? {}
          ),
          commonPitfalls: List<String>.from(
            bestPracticeData['commonPitfalls'] as List? ?? []
          ),
          successTips: List<String>.from(
            bestPracticeData['successTips'] as List? ?? []
          ),
          errorHandling: Map<String, String>.from(
            bestPracticeData['errorHandling'] as Map? ?? {}
          ),
          confidence: (bestPracticeData['confidence'] as num?)?.toDouble() ?? 0.5,
        ),
      );
    } catch (e) {
      return _FailureAnalysis(
        lessons: ['解析失败'],
        suggestedFix: '重新分析',
        bestPractice: ToolUsageBestPractice(
          toolName: '',
          description: '',
          confidence: 0.3,
        ),
      );
    }
  }
  
  /// 解析最佳实践
  ToolUsageBestPractice _parseBestPractice(String response) {
    try {
      final jsonStr = _extractJson(response);
      final data = json.decode(jsonStr) as Map<String, dynamic>;
      
      return ToolUsageBestPractice(
        toolName: data['toolName'] as String,
        description: data['description'] as String? ?? '',
        requiredParameters: List<String>.from(
          data['requiredParameters'] as List? ?? []
        ),
        recommendedParameters: Map<String, dynamic>.from(
          data['recommendedParameters'] as Map? ?? {}
        ),
        commonPitfalls: List<String>.from(
          data['commonPitfalls'] as List? ?? []
        ),
        successTips: List<String>.from(
          data['successTips'] as List? ?? []
        ),
        errorHandling: Map<String, String>.from(
          data['errorHandling'] as Map? ?? {}
        ),
        confidence: (data['confidence'] as num?)?.toDouble() ?? 0.5,
      );
    } catch (e) {
      return ToolUsageBestPractice(
        toolName: '',
        description: '',
        confidence: 0.3,
      );
    }
  }
  
  /// 解析预测结果
  ToolSuccessPrediction _parsePrediction(String response, String toolName) {
    try {
      final jsonStr = _extractJson(response);
      final data = json.decode(jsonStr) as Map<String, dynamic>;
      
      return ToolSuccessPrediction(
        toolName: toolName,
        predictedSuccessRate: (data['predictedSuccessRate'] as num).toDouble(),
        confidence: (data['confidence'] as num).toDouble(),
        reasoning: data['reasoning'] as String?,
        riskFactors: List<String>.from(data['riskFactors'] as List? ?? []),
        suggestions: List<String>.from(data['suggestions'] as List? ?? []),
      );
    } catch (e) {
      return ToolSuccessPrediction(
        toolName: toolName,
        predictedSuccessRate: 0.5,
        confidence: 0.3,
        reasoning: '解析失败',
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
}

// ===== 数据模型 =====

/// 工具使用案例
class ToolUsageCase {
  final String id;
  final String toolName;
  final Map<String, dynamic> parameters;
  final bool isSuccess;
  final String result;
  final String? errorMessage;
  final Duration? executionTime;
  final DateTime timestamp;
  final Map<String, dynamic>? context;
  final List<String>? lessonsLearned;
  final String? suggestedFix;
  
  ToolUsageCase({
    required this.id,
    required this.toolName,
    required this.parameters,
    required this.isSuccess,
    required this.result,
    this.errorMessage,
    this.executionTime,
    required this.timestamp,
    this.context,
    this.lessonsLearned,
    this.suggestedFix,
  });
  
  ToolUsageCase copyWith({
    List<String>? lessonsLearned,
    String? suggestedFix,
  }) {
    return ToolUsageCase(
      id: id,
      toolName: toolName,
      parameters: parameters,
      isSuccess: isSuccess,
      result: result,
      errorMessage: errorMessage,
      executionTime: executionTime,
      timestamp: timestamp,
      context: context,
      lessonsLearned: lessonsLearned ?? this.lessonsLearned,
      suggestedFix: suggestedFix ?? this.suggestedFix,
    );
  }
  
  Map<String, dynamic> toJson() => {
    'id': id,
    'toolName': toolName,
    'parameters': parameters,
    'isSuccess': isSuccess,
    'result': result,
    'errorMessage': errorMessage,
    'executionTime': executionTime?.inMilliseconds,
    'timestamp': timestamp.toIso8601String(),
    'context': context,
    'lessonsLearned': lessonsLearned,
    'suggestedFix': suggestedFix,
  };
  
  factory ToolUsageCase.fromJson(Map<String, dynamic> json) => ToolUsageCase(
    id: json['id'] as String,
    toolName: json['toolName'] as String,
    parameters: Map<String, dynamic>.from(json['parameters'] as Map),
    isSuccess: json['isSuccess'] as bool,
    result: json['result'] as String,
    errorMessage: json['errorMessage'] as String?,
    executionTime: json['executionTime'] != null 
      ? Duration(milliseconds: json['executionTime'] as int)
      : null,
    timestamp: DateTime.parse(json['timestamp'] as String),
    context: json['context'] as Map<String, dynamic>?,
    lessonsLearned: (json['lessonsLearned'] as List?)?.cast<String>(),
    suggestedFix: json['suggestedFix'] as String?,
  );
}

/// 工具使用最佳实践
class ToolUsageBestPractice {
  final String toolName;
  final String description;
  final List<String> requiredParameters;
  final Map<String, dynamic> recommendedParameters;
  final List<String> commonPitfalls;
  final List<String> successTips;
  final Map<String, String> errorHandling;
  final double confidence;
  
  ToolUsageBestPractice({
    required this.toolName,
    required this.description,
    this.requiredParameters = const [],
    this.recommendedParameters = const {},
    this.commonPitfalls = const [],
    this.successTips = const [],
    this.errorHandling = const {},
    required this.confidence,
  });
}

/// 工具成功率预测
class ToolSuccessPrediction {
  final String toolName;
  final double predictedSuccessRate;
  final double confidence;
  final String? reasoning;
  final List<String> riskFactors;
  final List<String> suggestions;
  
  ToolSuccessPrediction({
    required this.toolName,
    required this.predictedSuccessRate,
    required this.confidence,
    this.reasoning,
    this.riskFactors = const [],
    this.suggestions = const [],
  });
}

/// 失败分析结果
class _FailureAnalysis {
  final String? rootCause;
  final List<String> lessons;
  final String? suggestedFix;
  final ToolUsageBestPractice bestPractice;
  
  _FailureAnalysis({
    this.rootCause,
    required this.lessons,
    this.suggestedFix,
    required this.bestPractice,
  });
}
