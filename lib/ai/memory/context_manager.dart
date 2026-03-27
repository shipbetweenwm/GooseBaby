import 'package:flutter/foundation.dart';

/// System Prompt 级别
/// 根据任务复杂度和 token 预算自动选择
enum PromptLevel {
  /// 最小级：仅人格设定（~500 token）- 简单聊天
  minimal,
  /// 标准级：人格 + 基础工具说明（~2000 token）- 默认
  standard,
  /// 完整级：完整说明 + 技能文档（~8000 token）- 复杂任务
  full,
}

/// PromptLevel 扩展方法
extension PromptLevelExtension on PromptLevel {
  /// 从字符串解析
  static PromptLevel? fromString(String value) {
    switch (value.toLowerCase()) {
      case 'minimal':
        return PromptLevel.minimal;
      case 'standard':
        return PromptLevel.standard;
      case 'full':
        return PromptLevel.full;
      default:
        return null;
    }
  }
  
  /// 显示名称
  String get displayName {
    switch (this) {
      case PromptLevel.minimal:
        return '简洁模式';
      case PromptLevel.standard:
        return '标准模式';
      case PromptLevel.full:
        return '完整模式';
    }
  }
}

/// Token 计数器
/// 提供精确或估算的 token 计数功能
class TokenCounter {
  /// 不同模型的 token 估算系数
  /// 中文约 1.5 字符/token，英文约 4 字符/token
  static const double _chineseCharsPerToken = 1.5;
  static const double _englishCharsPerToken = 4.0;
  
  /// 计算 token 数量
  static int count(String text, {String model = 'default'}) {
    int chineseCount = 0;
    int englishCount = 0;
    
    for (int i = 0; i < text.length; i++) {
      final code = text.codeUnitAt(i);
      // 中文字符范围
      if (code >= 0x4e00 && code <= 0x9fff) {
        chineseCount++;
      } else {
        englishCount++;
      }
    }
    
    // 混合计算
    final chineseTokens = (chineseCount / _chineseCharsPerToken).ceil();
    final englishTokens = (englishCount / _englishCharsPerToken).ceil();
    
    return chineseTokens + englishTokens;
  }
  
  /// 计算消息列表的 token 数
  static int countMessages(List<Map<String, dynamic>> messages, {String model = 'default'}) {
    int total = 0;
    
    for (final msg in messages) {
      // 每条消息有约 4 token 的格式开销
      total += 4;
      
      // role
      final role = msg['role'] as String?;
      if (role != null) {
        total += count(role);
      }
      
      // content
      final content = msg['content'];
      if (content is String) {
        total += count(content);
      } else if (content is List) {
        for (final part in content) {
          if (part is Map && part['text'] is String) {
            total += count(part['text'] as String);
          }
          // 图片 token 估算（低分辨率 85，高分辨率 170-1105）
          if (part is Map && part['type'] == 'image_url') {
            total += 85; // 简化估算
          }
        }
      }
      
      // name 字段
      if (msg['name'] is String) {
        total += count(msg['name'] as String);
      }
      
      // 工具调用
      if (msg['tool_calls'] is List) {
        for (final tc in msg['tool_calls'] as List) {
          if (tc is Map) {
            total += 4; // 格式开销
            final func = tc['function'];
            if (func is Map) {
              total += count(func['name']?.toString() ?? '');
              total += count(func['arguments']?.toString() ?? '');
            }
          }
        }
      }
      
      // 工具调用结果
      if (msg['tool_call_id'] is String) {
        total += count(msg['tool_call_id'] as String);
      }
    }
    
    // 对话格式额外开销
    total += 3;
    
    return total;
  }
  
  /// 估算文本截断位置（指定 token 数）
  static int truncatePosition(String text, int maxTokens) {
    int tokens = 0;
    int pos = 0;
    
    for (int i = 0; i < text.length; i++) {
      final code = text.codeUnitAt(i);
      // 中文字符
      if (code >= 0x4e00 && code <= 0x9fff) {
        tokens += 1;
      } else {
        // 英文和其他字符
        tokens += 1;
      }
      
      // 每 4 个英文/其他字符算 1 token
      if (i > 0 && (i + 1) % 4 == 0) {
        if (code < 0x4e00 || code > 0x9fff) {
          // 英文累计满了才加 token
        }
      }
      
      pos = i + 1;
      
      if (tokens >= maxTokens) {
        // 找到最近的词边界
        while (pos < text.length && text[pos] != ' ' && text[pos] != '\n') {
          pos--;
        }
        if (pos == 0) pos = i + 1; // 避免截断为空
        break;
      }
    }
    
    return pos;
  }
}

/// System Prompt 分段
/// 每个分段有优先级和字符上限
class SystemPromptSegment {
  final String id;
  final String title;
  final String content;
  final int priority;      // 优先级（1-10，10 最高）
  final int maxChars;      // 字符上限（0 = 无限制）
  final int maxTokens;     // token 上限（0 = 无限制）
  final bool optional;     // 是否可选（空间不足时可省略）
  final bool compressible; // 是否可压缩（用摘要替代）
  
  const SystemPromptSegment({
    required this.id,
    required this.title,
    required this.content,
    this.priority = 5,
    this.maxChars = 0,
    this.maxTokens = 0,
    this.optional = false,
    this.compressible = false,
  });
  
  /// 当前内容的 token 数
  int get tokenCount => TokenCounter.count(content);
  
  /// 当前内容的字符数
  int get charCount => content.length;
  
  /// 是否需要压缩
  bool get needsCompression {
    if (maxChars > 0 && charCount > maxChars) return true;
    if (maxTokens > 0 && tokenCount > maxTokens) return true;
    return false;
  }
}

/// 上下文管理器
/// 管理 System Prompt 分段注入和 token 预算分配
class ContextManager extends ChangeNotifier {
  /// 各分段定义
  final List<SystemPromptSegment> _segments = [];
  
  /// 模型上下文窗口大小
  int _contextWindow = 128000;
  
  /// 预留给输出的 token 数
  int _outputReserve = 4096;
  
  /// 预留给工具定义的 token 数
  int _toolsReserve = 2000;
  
  /// 预留给对话历史的 token 数
  int _historyReserve = 20000;
  
  /// System Prompt 最大 token 数
  int _systemPromptMax = 8000;
  
  /// 当前使用的 token 数
  int _currentTokens = 0;
  
  /// 当前 Prompt 级别
  PromptLevel _promptLevel = PromptLevel.standard;
  
  /// 历史消息摘要缓存
  String? _cachedHistorySummary;
  int _cachedHistoryTokenCount = 0;
  
  /// LLM 摘要生成函数（由外部注入）
  Future<String> Function(String prompt)? _llmSummarizer;
  
  /// 工具调用摘要缓存（key: 消息索引, value: 摘要）
  final Map<int, String> _toolCallSummaryCache = {};
  
  /// 获取上下文窗口大小
  int get contextWindow => _contextWindow;
  
  /// 获取当前 token 使用量
  int get currentTokens => _currentTokens;
  
  /// 获取可用 token 预算
  int get availableTokens => _contextWindow - _outputReserve - _toolsReserve - _currentTokens;
  
  /// 获取当前 Prompt 级别
  PromptLevel get promptLevel => _promptLevel;
  
  /// 获取历史预留 token 数
  int get historyReserve => _historyReserve;
  
  /// 设置模型上下文窗口大小
  void setContextWindow(int tokens) {
    _contextWindow = tokens;
    notifyListeners();
  }
  
  /// 设置 Prompt 级别
  void setPromptLevel(PromptLevel level) {
    _promptLevel = level;
    notifyListeners();
  }
  
  /// 设置 LLM 摘要生成器
  void setLLMSummarizer(Future<String> Function(String prompt) summarizer) {
    _llmSummarizer = summarizer;
  }
  
  /// 设置输出预留
  void setOutputReserve(int tokens) {
    _outputReserve = tokens;
    notifyListeners();
  }
  
  /// 设置工具预留
  void setToolsReserve(int tokens) {
    _toolsReserve = tokens;
    notifyListeners();
  }
  
  /// 设置历史记录预留
  void setHistoryReserve(int tokens) {
    _historyReserve = tokens;
    notifyListeners();
  }
  
  /// 设置 System Prompt 最大 token 数
  void setSystemPromptMax(int tokens) {
    _systemPromptMax = tokens;
    notifyListeners();
  }
  
  /// 添加分段
  void addSegment(SystemPromptSegment segment) {
    _segments.add(segment);
    notifyListeners();
  }
  
  /// 移除分段
  void removeSegment(String id) {
    _segments.removeWhere((s) => s.id == id);
    notifyListeners();
  }
  
  /// 清空分段
  void clearSegments() {
    _segments.clear();
    _currentTokens = 0;
    notifyListeners();
  }
  
  /// 构建最终 System Prompt
  /// 根据优先级和 token 预算组装分段
  String build({int? customMaxTokens}) {
    final maxTokens = customMaxTokens ?? _systemPromptMax;
    
    // 按优先级排序（高优先级在前）
    final sorted = List<SystemPromptSegment>.from(_segments)
      ..sort((a, b) => b.priority.compareTo(a.priority));
    
    final buffer = StringBuffer();
    int usedTokens = 0;
    
    for (final segment in sorted) {
      String content = segment.content;
      int tokens = TokenCounter.count(content);
      
      // 检查是否需要压缩
      if (segment.needsCompression || (maxTokens > 0 && usedTokens + tokens > maxTokens)) {
        if (segment.optional) {
          // 可选分段，跳过
          continue;
        } else if (segment.compressible) {
          // 可压缩分段，生成摘要
          final compressed = _compressSegment(segment, maxTokens - usedTokens);
          if (compressed != null) {
            content = compressed;
            tokens = TokenCounter.count(content);
          } else {
            continue; // 压缩失败，跳过
          }
        } else {
          // 不可压缩且不可选，截断
          final remaining = maxTokens - usedTokens;
          if (remaining > 100) { // 至少保留 100 token
            final pos = TokenCounter.truncatePosition(content, remaining);
            content = '${content.substring(0, pos)}...';
            tokens = TokenCounter.count(content);
          } else {
            continue; // 空间不足，跳过
          }
        }
      }
      
      // 添加分段标题
      if (buffer.isNotEmpty) {
        buffer.writeln();
        buffer.writeln();
      }
      buffer.writeln('## ${segment.title}');
      buffer.write(content);
      
      usedTokens += tokens + 10; // 加上标题的 token
    }
    
    _currentTokens = usedTokens;
    notifyListeners();
    
    return buffer.toString();
  }
  
  /// 压缩分段（生成摘要）
  String? _compressSegment(SystemPromptSegment segment, int maxTokens) {
    // 简单实现：截取关键句
    // 实际应用中可以调用 LLM 生成摘要
    final content = segment.content;
    
    if (maxTokens < 50) return null; // 太小了，放弃
    
    // 按句子分割
    final sentences = content.split(RegExp(r'[。！？\n]'));
    if (sentences.isEmpty) return null;
    
    // 保留前面的句子（通常是最重要的）
    final buffer = StringBuffer();
    int tokens = 0;
    
    for (final sentence in sentences) {
      if (sentence.trim().isEmpty) continue;
      
      final sentenceTokens = TokenCounter.count(sentence);
      if (tokens + sentenceTokens > maxTokens - 20) break; // 留一些余量
      
      if (buffer.isNotEmpty) buffer.write('。');
      buffer.write(sentence.trim());
      tokens += sentenceTokens;
    }
    
    if (buffer.isEmpty) return null;
    return buffer.toString();
  }
  
  /// 计算对话历史的 token 数
  int countHistoryTokens(List<Map<String, dynamic>> messages) {
    return TokenCounter.countMessages(messages);
  }
  
  /// 检查是否需要摘要历史
  bool needsHistorySummary(List<Map<String, dynamic>> messages) {
    final historyTokens = countHistoryTokens(messages);
    return historyTokens > _historyReserve;
  }
  
  /// 估算摘要后的 token 数
  int estimateSummaryTokens(List<Map<String, dynamic>> messages) {
    // 摘要通常是原文的 10-20%
    final original = countHistoryTokens(messages);
    return (original * 0.15).ceil();
  }
  
  /// 获取上下文使用统计
  Map<String, dynamic> getStats() {
    return {
      'context_window': _contextWindow,
      'current_tokens': _currentTokens,
      'available_tokens': availableTokens,
      'output_reserve': _outputReserve,
      'tools_reserve': _toolsReserve,
      'history_reserve': _historyReserve,
      'system_prompt_max': _systemPromptMax,
      'segment_count': _segments.length,
      'prompt_level': _promptLevel.name,
    };
  }
  
  // ═══════════════════════════════════════════════════════════════════
  /// Token 预算控制的历史消息修剪
  /// 返回修剪后的消息列表，确保总 token 不超过 historyReserve
  /// ═══════════════════════════════════════════════════════════════════
  
  /// 修剪历史消息（Token 预算控制）
  /// [messages] 原始消息列表
  /// [maxTokens] 最大 token 预算（默认使用 _historyReserve）
  /// [apiMessageGroups] 需要特殊处理的 apiMessages 组（工具调用序列）
  /// 返回修剪后的消息列表和被裁剪的 token 数
  ({List<Map<String, dynamic>> messages, int trimmedTokens, bool needsSummary}) trimHistoryByTokenBudget(
    List<Map<String, dynamic>> messages, {
    int? maxTokens,
    List<List<Map<String, dynamic>>>? apiMessageGroups,
  }) {
    final budget = maxTokens ?? _historyReserve;
    final result = <Map<String, dynamic>>[];
    int totalTokens = 0;
    int trimmedTokens = 0;
    
    // 从后向前遍历，保留最新消息
    for (int i = messages.length - 1; i >= 0; i--) {
      final msg = messages[i];
      final msgTokens = _countMessageTokens(msg);
      
      if (totalTokens + msgTokens <= budget) {
        result.insert(0, msg);
        totalTokens += msgTokens;
      } else {
        trimmedTokens += msgTokens;
      }
    }
    
    // 如果有 apiMessageGroups，检查是否需要摘要
    bool needsSummary = false;
    if (apiMessageGroups != null && apiMessageGroups.isNotEmpty) {
      for (final group in apiMessageGroups) {
        final groupTokens = TokenCounter.countMessages(group);
        if (groupTokens > budget * 0.3) {
          needsSummary = true;
          break;
        }
      }
    }
    
    return (messages: result, trimmedTokens: trimmedTokens, needsSummary: needsSummary);
  }
  
  /// 计算单条消息的 token 数
  int _countMessageTokens(Map<String, dynamic> msg) {
    int tokens = 4; // 消息格式开销
    
    final role = msg['role'] as String?;
    if (role != null) tokens += TokenCounter.count(role);
    
    final content = msg['content'];
    if (content is String) {
      tokens += TokenCounter.count(content);
    } else if (content is List) {
      for (final part in content) {
        if (part is Map && part['text'] is String) {
          tokens += TokenCounter.count(part['text'] as String);
        }
        if (part is Map && part['type'] == 'image_url') {
          tokens += 85;
        }
      }
    }
    
    if (msg['tool_calls'] is List) {
      for (final tc in msg['tool_calls'] as List) {
        if (tc is Map) {
          tokens += 4;
          final func = tc['function'];
          if (func is Map) {
            tokens += TokenCounter.count(func['name']?.toString() ?? '');
            tokens += TokenCounter.count(func['arguments']?.toString() ?? '');
          }
        }
      }
    }
    
    if (msg['tool_call_id'] is String) {
      tokens += TokenCounter.count(msg['tool_call_id'] as String);
    }
    
    return tokens;
  }
  
  // ═══════════════════════════════════════════════════════════════════
  /// 工具调用摘要生成
  /// ═══════════════════════════════════════════════════════════════════
  
  /// 生成工具调用序列的结构化摘要
  /// [apiMessages] 工具调用消息序列（assistant tool_calls + tool results）
  /// [finalContent] 最终回复内容
  /// 返回结构化摘要文本
  String generateToolCallSummary(
    List<Map<String, dynamic>> apiMessages, {
    String? finalContent,
  }) {
    final toolCalls = <_ToolCallRecord>[];
    String? failedTool;
    String? failureReason;
    
    for (final msg in apiMessages) {
      // 提取工具调用
      if (msg['role'] == 'assistant' && msg['tool_calls'] != null) {
        for (final tc in msg['tool_calls'] as List) {
          if (tc is Map) {
            final func = tc['function'];
            if (func is Map) {
              toolCalls.add(_ToolCallRecord(
                name: func['name']?.toString() ?? 'unknown',
                arguments: func['arguments']?.toString() ?? '{}',
              ));
            }
          }
        }
      }
      
      // 提取工具结果和失败信息
      if (msg['role'] == 'tool') {
        final content = msg['content']?.toString() ?? '';
        // 检查是否失败
        if (content.toLowerCase().contains('error') || 
            content.contains('失败') || 
            content.contains('failed')) {
          failedTool = msg['name']?.toString();
          failureReason = content.length > 200 
              ? '${content.substring(0, 200)}...' 
              : content;
        }
      }
    }
    
    // 构建摘要
    final buffer = StringBuffer();
    buffer.writeln('【历史工具调用】');
    buffer.writeln('工具序列: ${toolCalls.map((t) => t.name).join(" → ")}');
    
    if (failedTool != null) {
      buffer.writeln('失败记录: $failedTool - ${failureReason ?? "未知原因"}');
    }
    
    if (finalContent != null && finalContent.isNotEmpty) {
      buffer.writeln('最终结果: ${finalContent.length > 150 ? "${finalContent.substring(0, 150)}..." : finalContent}');
    }
    
    return buffer.toString();
  }
  
  /// 使用 LLM 生成更智能的工具调用摘要（可选）
  /// 需要先通过 setLLMSummarizer 设置摘要生成器
  Future<String?> generateLLMToolCallSummary(
    List<Map<String, dynamic>> apiMessages, {
    String? finalContent,
  }) async {
    if (_llmSummarizer == null) return null;
    
    // 构建摘要 prompt
    final toolNames = <String>[];
    for (final msg in apiMessages) {
      if (msg['role'] == 'assistant' && msg['tool_calls'] != null) {
        for (final tc in msg['tool_calls'] as List) {
          if (tc is Map && tc['function'] is Map) {
            toolNames.add((tc['function'] as Map)['name']?.toString() ?? '');
          }
        }
      }
    }
    
    final prompt = '''
请为以下工具调用序列生成简洁的结构化摘要（100字以内）：

工具序列: ${toolNames.join(' → ')}
最终回复: ${finalContent ?? '无'}

请用以下格式输出：
【任务】...
【使用工具】...
【关键结果】...
【失败记录】（如有）...
''';
    
    try {
      return await _llmSummarizer!(prompt);
    } catch (e) {
      debugPrint('[ContextManager] LLM摘要生成失败: $e');
      return null;
    }
  }
  
  // ═══════════════════════════════════════════════════════════════════
  /// Prompt 级别相关
  /// ═══════════════════════════════════════════════════════════════════
  
  /// 根据 Prompt 级别获取推荐的 System Prompt 最大 token
  int getSystemPromptMaxForLevel(PromptLevel level) {
    switch (level) {
      case PromptLevel.minimal:
        return 500;
      case PromptLevel.standard:
        return 2000;
      case PromptLevel.full:
        return _systemPromptMax; // 使用配置的最大值
    }
  }
  
  /// 自动选择 Prompt 级别
  /// [userMessage] 用户消息
  /// [availableBudget] 可用 token 预算
  PromptLevel autoSelectPromptLevel(String userMessage, int availableBudget) {
    final msgLower = userMessage.toLowerCase();
    
    // 检测复杂任务关键词
    final complexKeywords = ['分析', '生成', '创建', '开发', '编写', '实现', '处理', '转换', 
      'analyze', 'generate', 'create', 'develop', 'implement', 'process'];
    final hasComplexKeyword = complexKeywords.any((k) => msgLower.contains(k));
    
    // 检测工具调用意图
    final toolKeywords = ['文件', '脚本', '执行', '运行', '数据', '表格', '图表',
      'file', 'script', 'run', 'execute', 'data', 'excel', 'chart'];
    final hasToolIntent = toolKeywords.any((k) => msgLower.contains(k));
    
    // 检测简单聊天
    final simpleKeywords = ['你好', '早上好', '晚安', '在吗', '怎么样', '开心',
      'hello', 'hi', 'hey', 'how are', 'good morning', 'good night'];
    final isSimpleChat = simpleKeywords.any((k) => msgLower.contains(k));
    
    // 预算不足时降级
    if (availableBudget < 2000) {
      return PromptLevel.minimal;
    }
    
    // 根据意图选择
    if (isSimpleChat && !hasComplexKeyword && !hasToolIntent) {
      return PromptLevel.minimal;
    }
    
    if (hasComplexKeyword || hasToolIntent) {
      return PromptLevel.full;
    }
    
    return PromptLevel.standard;
  }
  
  /// 清除缓存
  void clearCache() {
    _cachedHistorySummary = null;
    _cachedHistoryTokenCount = 0;
    _toolCallSummaryCache.clear();
  }
  
  /// 获取或生成历史摘要（带缓存）
  Future<String?> getOrGenerateHistorySummary(
    List<Map<String, dynamic>> messages,
  ) async {
    final currentTokenCount = TokenCounter.countMessages(messages);
    
    // 如果缓存有效且 token 数未变，直接返回缓存
    if (_cachedHistorySummary != null && 
        _cachedHistoryTokenCount == currentTokenCount) {
      return _cachedHistorySummary;
    }
    
    // 需要摘要
    if (!needsHistorySummary(messages)) {
      return null;
    }
    
    // 使用 LLM 生成摘要
    if (_llmSummarizer != null) {
      try {
        final historyText = messages.map((m) {
          final role = m['role'] as String? ?? '';
          final content = m['content']?.toString() ?? '';
          return '[$role] $content';
        }).join('\n');
        
        final summary = await _llmSummarizer!(
          '请为以下对话历史生成简洁摘要（200字以内，保留关键决策和结果）：\n\n$historyText',
        );
        
        // 更新缓存
        _cachedHistorySummary = summary;
        _cachedHistoryTokenCount = currentTokenCount;
        
        return summary;
      } catch (e) {
        debugPrint('[ContextManager] 历史摘要生成失败: $e');
      }
    }
    
    return null;
  }
}

/// 工具调用记录（内部使用）
class _ToolCallRecord {
  final String name;
  final String arguments;
  
  const _ToolCallRecord({required this.name, required this.arguments});
}

/// 模型上下文窗口配置
class ModelContextConfig {
  /// 模型名称
  final String model;
  
  /// 上下文窗口大小
  final int contextWindow;
  
  /// 最大输出 token
  final int maxOutput;
  
  /// 推荐的 System Prompt 大小
  final int recommendedSystemPrompt;
  
  const ModelContextConfig({
    required this.model,
    required this.contextWindow,
    required this.maxOutput,
    required this.recommendedSystemPrompt,
  });
  
  /// 预定义模型配置
  static const Map<String, ModelContextConfig> presets = {
    'gpt-4o': ModelContextConfig(
      model: 'gpt-4o',
      contextWindow: 128000,
      maxOutput: 16384,
      recommendedSystemPrompt: 8000,
    ),
    'gpt-4o-mini': ModelContextConfig(
      model: 'gpt-4o-mini',
      contextWindow: 128000,
      maxOutput: 16384,
      recommendedSystemPrompt: 8000,
    ),
    'gpt-4-turbo': ModelContextConfig(
      model: 'gpt-4-turbo',
      contextWindow: 128000,
      maxOutput: 4096,
      recommendedSystemPrompt: 8000,
    ),
    'gpt-3.5-turbo': ModelContextConfig(
      model: 'gpt-3.5-turbo',
      contextWindow: 16385,
      maxOutput: 4096,
      recommendedSystemPrompt: 4000,
    ),
    'claude-3-opus': ModelContextConfig(
      model: 'claude-3-opus',
      contextWindow: 200000,
      maxOutput: 4096,
      recommendedSystemPrompt: 15000,
    ),
    'claude-3-sonnet': ModelContextConfig(
      model: 'claude-3-sonnet',
      contextWindow: 200000,
      maxOutput: 4096,
      recommendedSystemPrompt: 15000,
    ),
    'qwen-turbo': ModelContextConfig(
      model: 'qwen-turbo',
      contextWindow: 131072,
      maxOutput: 8192,
      recommendedSystemPrompt: 8000,
    ),
    'qwen-plus': ModelContextConfig(
      model: 'qwen-plus',
      contextWindow: 131072,
      maxOutput: 8192,
      recommendedSystemPrompt: 8000,
    ),
    'qwen-max': ModelContextConfig(
      model: 'qwen-max',
      contextWindow: 32768,
      maxOutput: 8192,
      recommendedSystemPrompt: 6000,
    ),
  };
  
  /// 获取模型配置
  static ModelContextConfig get(String model) {
    return presets[model] ?? const ModelContextConfig(
      model: 'default',
      contextWindow: 8192,
      maxOutput: 2048,
      recommendedSystemPrompt: 2000,
    );
  }
}
