import 'dart:math' as math;
import 'package:flutter/foundation.dart';
import 'package:hive/hive.dart';
import 'vector_memory.dart';
import 'context_manager.dart';

/// 记忆管理器
/// 管理鹅宝的短期记忆和长期记忆
class MemoryManager extends ChangeNotifier {
  final List<Map<String, dynamic>> _longTermMemories = [];
  Map<String, dynamic> _userProfile = {};

  // ── 情感事件记忆 ──
  final List<Map<String, dynamic>> _emotionalEvents = [];
  
  // ── 向量记忆存储（可选，用于语义搜索 fallback） ──
  VectorMemoryStore? _vectorStore;

  // ── 衰减配置常量 ──
  /// 失败经验最大保留天数
  static const int failureMaxAgeDays = 30;
  /// 失败经验最大存储条数
  static const int failureMaxCount = 50;
  /// 永久记忆注入 prompt 的最大条数
  static const int promotedMaxInPrompt = 5;
  /// 永久记忆注入 prompt 的最大字符数
  static const int promotedMaxCharsInPrompt = 1500;
  /// 失败经验衰减速率 (指数衰减 λ, 每天)
  static const double failureDecayRate = 0.05;
  /// 普通记忆衰减速率 (每天)
  static const double normalDecayRate = 0.02;
  /// 访问加分上限
  static const double accessBoostCap = 0.5;
  /// 每次访问的加分值
  static const double accessBoostPerHit = 0.1;
  /// 升级为永久记忆所需的最小命中次数
  static const int promotedThreshold = 3;
  /// 是否在本次会话中已执行过衰减清理
  bool _decayCleanedThisSession = false;
  
  // ── 扩展记忆容量 ──
  /// 普通记忆最大存储条数（支持大量记忆）
  static const int normalMemoryMaxCount = 1000;
  /// 重要记忆标签（这些记忆永不衰减）
  static const List<String> importantMemoryTags = ['重要', '永久', '喜好', '名字', '生日', '地址', '电话'];
  /// 注入 prompt 的记忆检索数量
  static const int retrievalMaxCount = 10;

  List<Map<String, dynamic>> get longTermMemories => _longTermMemories;
  Map<String, dynamic> get userProfile => _userProfile;

  MemoryManager() {
    _loadMemories();
  }
  
  /// 设置向量记忆存储（用于语义搜索 fallback）
  void setVectorStore(VectorMemoryStore store) {
    _vectorStore = store;
  }

  void _loadMemories() {
    final box = Hive.box('memory');

    // 加载长期记忆
    final memories = box.get('long_term', defaultValue: <dynamic>[]);
    if (memories is List) {
      for (final m in memories) {
        if (m is Map) {
          _longTermMemories.add(Map<String, dynamic>.from(m));
        }
      }
    }

    // 加载用户画像
    final profile = box.get('user_profile');
    if (profile is Map) {
      _userProfile = Map<String, dynamic>.from(profile);
    }

    // 加载情感事件
    final events = box.get('emotional_events', defaultValue: <dynamic>[]);
    if (events is List) {
      for (final e in events) {
        if (e is Map) {
          _emotionalEvents.add(Map<String, dynamic>.from(e));
        }
      }
    }
  }

  void _saveMemories() {
    final box = Hive.box('memory');
    box.put('long_term', _longTermMemories);
    box.put('user_profile', _userProfile);
  }

  /// 保存一条长期记忆
  /// [content] 记忆内容
  /// [metadata] 可选的元数据，可包含 type, importance, tags 等
  /// [isImportant] 是否为重要记忆（重要记忆永不衰减，优先检索）
  void save(String content, {Map<String, dynamic>? metadata, bool? isImportant}) {
    if (content.trim().isEmpty) return;

    // 判断是否为重要记忆
    final isImportantMemory = isImportant ?? _isImportantContent(content);
    
    // 去重：如果已存在高度相似的记忆（完全相同或已包含），则更新而非新增
    final existingIdx = _findSimilarMemory(content);
    if (existingIdx != null) {
      final existing = _longTermMemories[existingIdx];
      final existingContent = existing['content'] as String;
      // 如果新内容更长更详细，则替换
      if (content.length > existingContent.length * 1.2) {
        existing['content'] = content;
        existing['timestamp'] = DateTime.now().toIso8601String();
        existing['metadata'] = {
          ...(metadata ?? {}),
          'isImportant': isImportantMemory,
          'type': '合并更新',
          'source': 'merged',
          'original': existingContent,
        };
        debugPrint('🧠 记忆合并更新: $content');
        _saveMemories();
        notifyListeners();
      }
      return;
    }

    _longTermMemories.add({
      'content': content,
      'timestamp': DateTime.now().toIso8601String(),
      'accessCount': 0,
      'importance': isImportantMemory ? 1.0 : _calculateImportance(content),
      'metadata': {
        ...(metadata ?? {}),
        'isImportant': isImportantMemory,
      },
    });
    
    // 同步到向量存储（用于语义搜索）
    _vectorStore?.add(content, metadata: {
      'isImportant': isImportantMemory,
      'timestamp': DateTime.now().toIso8601String(),
    });

    // 智能淘汰：当超过限制时，优先淘汰非重要、低访问、旧的普通记忆
    if (_longTermMemories.length > normalMemoryMaxCount) {
      _smartEviction();
    }

    _saveMemories();
    notifyListeners();
  }

  // ── API Key 相关的记忆能力 ──

  /// 判断文本是否含 API key 信息（用于自动标记为永久重要记忆）
  static bool isApiKeyContent(String content) {
    final lower = content.toLowerCase();
    // 服务名关键词
    const serviceNames = [
      'tavily', 'brave', 'exa', 'gnews', 'openai', 'anthropic',
      'gemini', 'qwen', 'deepseek', 'kimi', 'minimax',
    ];
    // key 关键词
    const keyWords = ['api key', 'apikey', 'api_key', 'token', 'secret key', '密钥', '接口密钥'];

    final hasService = serviceNames.any((s) => lower.contains(s));
    final hasKeyWord = keyWords.any((k) => lower.contains(k));

    // 含典型 key 格式（sk-xxx、tvly-xxx、BSAxxx 等）
    final hasKeyPattern = RegExp(
      r'(sk-[a-zA-Z0-9]{10,}|tvly-[a-zA-Z0-9]{10,}|BSA[a-zA-Z0-9]{10,}|[a-zA-Z0-9]{30,})',
    ).hasMatch(content);

    return hasKeyWord || (hasService && hasKeyPattern);
  }

  /// 从永久记忆中提取指定搜索引擎的 API key
  ///
  /// 扫描所有长期记忆，找出明确提到 [providerName] 的 API key 记录，
  /// 返回第一个匹配的 key 字符串（裸 key），找不到则返回 null。
  String? searchApiKeyFromMemory(String providerName) {
    final lowerProvider = providerName.toLowerCase();
    // 用于捕获 key 值的正则：常见 key 格式
    final keyExtract = RegExp(
      r'(?:key|token|secret)[^\S\n]*[：:=\s]+([A-Za-z0-9\-_]{10,})',
      caseSensitive: false,
    );

    for (final mem in _longTermMemories.reversed) {
      final content = (mem['content'] as String? ?? '').toLowerCase();
      if (!content.contains(lowerProvider)) continue;
      if (!isApiKeyContent(content)) continue;

      // 尝试提取 key 值
      final m = keyExtract.firstMatch(mem['content'] as String);
      if (m != null) {
        final candidate = m.group(1)!.trim();
        if (candidate.length >= 10) return candidate;
      }

      // 备用：找第一个连续的长 token（>=20字符的字母数字串）
      final tokenMatch = RegExp(r'[A-Za-z0-9\-_]{20,}').firstMatch(mem['content'] as String);
      if (tokenMatch != null) return tokenMatch.group(0);
    }
    return null;
  }

  /// 判断内容是否为重要记忆
  bool _isImportantContent(String content) {
    // API key 自动标为重要
    if (isApiKeyContent(content)) return true;

    final lower = content.toLowerCase();
    // 检查是否包含重要标签
    for (final tag in importantMemoryTags) {
      if (lower.contains(tag.toLowerCase())) {
        return true;
      }
    }
    // 检查特定模式
    if (lower.contains('我叫') || lower.contains('名字是') ||
        lower.contains('生日是') || lower.contains('喜欢吃') ||
        lower.contains('不喜欢') || lower.contains('住址') ||
        lower.contains('电话') || lower.contains('记得') ||
        lower.contains('别忘了') || lower.contains('一定要记住')) {
      return true;
    }
    return false;
  }
  
  /// 计算记忆的重要性评分（0.0-1.0）
  double _calculateImportance(String content) {
    double score = 0.5; // 基础分
    
    // 包含个人信息的加分
    if (content.contains('我') || content.contains('我的')) {
      score += 0.1;
    }
    // 包含情感词汇的加分
    if (content.contains('喜欢') || content.contains('爱') || content.contains('讨厌')) {
      score += 0.15;
    }
    // 包含时间相关（生日、纪念日等）加分
    if (content.contains('生日') || content.contains('纪念日') || content.contains('节日')) {
      score += 0.2;
    }
    // 内容长度适中的加分（太短可能不重要，太长可能是日志）
    if (content.length > 20 && content.length < 200) {
      score += 0.1;
    }
    
    return score.clamp(0.0, 1.0);
  }
  
  /// 智能淘汰：优先淘汰非重要、低访问、旧的普通记忆
  void _smartEviction() {
    // 分离重要记忆和普通记忆
    final importantMemories = _longTermMemories.where((m) {
      final metadata = m['metadata'];
      return metadata is Map && metadata['isImportant'] == true;
    }).toList();
    
    final normalMemories = _longTermMemories.where((m) {
      final metadata = m['metadata'];
      return !(metadata is Map && metadata['isImportant'] == true);
    }).toList();
    
    // 计算需要淘汰的数量
    final excessCount = _longTermMemories.length - normalMemoryMaxCount;
    if (excessCount <= 0) return;
    
    // 对普通记忆按综合评分排序（低分优先淘汰）
    normalMemories.sort((a, b) {
      final scoreA = _calculateEvictionScore(a);
      final scoreB = _calculateEvictionScore(b);
      return scoreA.compareTo(scoreB); // 低分在前
    });
    
    // 淘汰最低评分的记忆
    final toRemove = normalMemories.take(excessCount).toList();
    for (final m in toRemove) {
      _longTermMemories.remove(m);
    }
    
    debugPrint('🧠 智能淘汰: 移除 ${toRemove.length} 条低优先级记忆，保留 ${importantMemories.length} 条重要记忆');
  }
  
  /// 计算记忆的淘汰评分（越低越容易被淘汰）
  double _calculateEvictionScore(Map<String, dynamic> memory) {
    final importance = (memory['importance'] as num?)?.toDouble() ?? 0.5;
    final accessCount = (memory['accessCount'] as int?) ?? 0;
    final timestampStr = memory['timestamp'] as String?;
    
    // 时间衰减
    double timeScore = 0.5;
    if (timestampStr != null) {
      final timestamp = DateTime.tryParse(timestampStr);
      if (timestamp != null) {
        final daysOld = DateTime.now().difference(timestamp).inDays;
        timeScore = math.exp(-normalDecayRate * daysOld);
      }
    }
    
    // 访问加分
    final accessScore = (accessCount * accessBoostPerHit).clamp(0.0, accessBoostCap);
    
    // 综合评分：重要性权重最高
    return importance * 0.5 + timeScore * 0.3 + accessScore * 0.2;
  }

  /// 保存一条失败经验记忆（工具执行失败 + 解决方案）
  /// 格式: [失败经验] 工具名: 简述 | 错误: xxx | 解决: xxx
  void saveFailureLesson({
    required String skillId,
    required String summary,
    required String error,
    String? solution,
  }) {
    // 构建失败经验记忆内容
    final parts = <String>['[失败经验] $skillId: $summary'];
    // 错误信息截断，避免记忆过长
    final truncatedError = error.length > 200 ? '${error.substring(0, 200)}...' : error;
    parts.add('错误: $truncatedError');
    if (solution != null && solution.isNotEmpty) {
      final truncatedSolution = solution.length > 300 ? '${solution.substring(0, 300)}...' : solution;
      parts.add('解决: $truncatedSolution');
    }
    final content = parts.join(' | ');

    // 去重：如果已存在相同工具 + 相同错误的记忆，跳过或更新
    final errorKey = truncatedError.toLowerCase().substring(0, 50);
    for (int i = 0; i < _longTermMemories.length; i++) {
      final existing = _longTermMemories[i];
      final existingContent = (existing['content'] as String).toLowerCase();
      if (existingContent.contains('[失败经验]') &&
          existingContent.contains(skillId.toLowerCase()) &&
          existingContent.contains(errorKey)) {
        // 已存在相似失败经验，如果有新解决方案则更新
        if (solution != null && solution.isNotEmpty && !existingContent.contains('解决:')) {
          existing['content'] = content;
          existing['timestamp'] = DateTime.now().toIso8601String();
          _saveMemories();
          debugPrint('🧠 失败经验更新(追加解决方案): $skillId - $summary');
        }
        return; // 已存在，不再重复添加
      }
    }

    save(content, metadata: {
      'type': '失败经验',
      'source': 'tool_failure',
      'skillId': skillId,
      'summary': summary,
      'promoted': false, // 尚未升级为永久记忆
      'hitCount': 0, // 被检索命中的次数
    });
    
    // 同步到向量存储（用于语义搜索 fallback）
    _vectorStore?.add(content, metadata: {
      'type': 'failure_lesson',
      'skillId': skillId,
    });
    
    debugPrint('🧠 失败经验保存: $skillId - $summary');
  }

  /// 获取所有失败经验记忆
  List<Map<String, dynamic>> getFailureLessons() {
    return _longTermMemories
        .where((m) {
          final metadata = m['metadata'];
          return metadata is Map &&
              metadata['type'] == '失败经验';
        })
        .toList();
  }

  /// 获取已升级的永久记忆（仅这些才注入 system prompt）
  List<Map<String, dynamic>> getPromotedFailures() {
    return _longTermMemories.where((m) {
      final metadata = m['metadata'];
      return metadata is Map &&
          metadata['type'] == '失败经验' &&
          metadata['promoted'] == true;
    }).toList();
  }

  /// 获取永久记忆上下文（注入到 system prompt）
  /// 只有被多次命中的失败经验才会出现在这里
  String getFailureLessonsContext({
    int maxItems = promotedMaxInPrompt,
    int maxChars = promotedMaxCharsInPrompt,
  }) {
    final failures = getPromotedFailures();
    if (failures.isEmpty) return '';

    // 按命中次数排序（高频在前）
    failures.sort((a, b) {
      final aHits = (a['metadata'] as Map?)?['hitCount'] as int? ?? 0;
      final bHits = (b['metadata'] as Map?)?['hitCount'] as int? ?? 0;
      return bHits.compareTo(aHits);
    });

    final sb = StringBuffer('## 高频失败经验（永久记忆，必须避免）\n');
    sb.writeln('以下错误反复出现，已升级为永久记忆，请务必避免：\n');

    int charCount = 0;
    int itemCount = 0;
    for (final f in failures) {
      if (itemCount >= maxItems) break;
      final content = f['content'] as String;
      final line = '- $content\n';
      if (charCount + line.length > maxChars) break;
      sb.write(line);
      charCount += line.length;
      itemCount++;

      _incrementAccessCount(f);
    }

    return '$sb';
  }

  /// 按需检索相关失败经验（在工具调用前搜索，作为一次性提示注入）
  /// [toolId] 工具 ID（如 shell_exec、write_file）
  /// [args] 工具参数（用于关键词匹配）
  /// 返回匹配到的失败经验文本，不命中返回 null
  /// 
  /// 优化策略：
  /// 1. 错误类型分类索引（工具ID精确匹配权重更高）
  /// 2. 关键词长度加权（长关键词匹配更有意义）
  /// 3. 最小匹配阈值过滤误匹配
  String? searchRelevantFailures(String toolId, Map<String, dynamic> args) {
    final failures = getFailureLessons();
    if (failures.isEmpty) return null;

    // 构建搜索关键词：工具ID + 参数值
    final searchTerms = <String>[
      toolId.toLowerCase(),
      if (args['command'] != null) (args['command'] as String).toLowerCase(),
      if (args['script'] != null) (args['script'] as String).toLowerCase(),
      if (args['path'] != null) (args['path'] as String).toLowerCase(),
      if (args['interpreter'] != null) (args['interpreter'] as String).toLowerCase(),
    ];

    // 去除空字符串
    searchTerms.removeWhere((s) => s.trim().isEmpty);
    if (searchTerms.isEmpty) return null;

    // 提取有意义的关键词（去掉过短的通用词）
    final keywords = <String>[];
    for (final term in searchTerms) {
      final parts = term.split(RegExp(r'[\\/\s,;]+'));
      for (final part in parts) {
        if (part.length > 2) {
          keywords.add(part);
        }
      }
    }
    if (keywords.isEmpty) return null;

    final matched = <MapEntry<Map<String, dynamic>, double>>[];

    for (final failure in failures) {
      // 已升级为永久记忆的跳过（已通过 system prompt 注入，避免重复提示）
      final metadata = failure['metadata'];
      if (metadata is Map && metadata['promoted'] == true) continue;
      // 已标记为过时的跳过（环境已变化，经验不再适用）
      if (metadata is Map && metadata['outdated'] == true) continue;

      final content = (failure['content'] as String).toLowerCase();
      double score = 0;

      // 工具ID精确匹配（最高权重）
      if (content.contains('[失败经验] ${toolId.toLowerCase()}')) {
        score += 5.0;
      } else if (content.contains(toolId.toLowerCase())) {
        score += 3.0;
      }

      // 关键词匹配（长关键词权重更高，避免短关键词误匹配）
      for (final kw in keywords) {
        if (content.contains(kw)) {
          // 长关键词加权：>8字符 +2, >4字符 +1.5, 其他 +1
          if (kw.length > 8) {
            score += 2.0;
          } else if (kw.length > 4) {
            score += 1.5;
          } else {
            score += 1.0;
          }
        }
      }
      
      // 错误类型分类匹配：如果参数中包含相同的错误模式关键词，加分
      final errorType = _extractErrorType(content);
      if (errorType != null) {
        // 检查当前参数是否涉及类似场景
        for (final term in searchTerms) {
          if (_isRelatedToErrorType(term, errorType)) {
            score += 2.0;
            break;
          }
        }
      }

      // 最小匹配阈值：至少需要工具ID匹配 或 2个以上关键词匹配
      if (score >= 3.0) {
        matched.add(MapEntry(failure, score));

        // 更新命中次数
        if (metadata is Map) {
          metadata['hitCount'] = (metadata['hitCount'] as int? ?? 0) + 1;

          // 检查是否需要升级为永久记忆
          if (metadata['promoted'] != true &&
              (metadata['hitCount'] as int) >= promotedThreshold) {
            metadata['promoted'] = true;
            debugPrint('🧠 失败经验升级为永久记忆: ${failure['content'].toString().substring(0, 50)}...');
            _saveMemories();
          }
        }

        // 增加访问计数
        _incrementAccessCount(failure);
      }
    }

    if (matched.isEmpty) {
      // ── Fallback: 向量语义搜索 ──
      if (_vectorStore != null) {
        return _semanticSearchFailures(toolId, searchTerms);
      }
      return null;
    }

    // 按匹配分排序，取 top 3
    matched.sort((a, b) => b.value.compareTo(a.value));

    final topResults = matched.take(3);
    final sb = StringBuffer('【⚠️ 相关失败经验提示】\n');
    sb.writeln('之前执行类似操作时遇到过以下问题，请参考避免：\n');
    for (final entry in topResults) {
      sb.writeln('- ${entry.key['content'] as String}');
    }
    sb.writeln('\n请根据以上经验调整你的操作。');

    return sb.toString();
  }
  
  /// 从失败经验内容中提取错误类型标签
  String? _extractErrorType(String content) {
    if (content.contains('permission denied') || content.contains('eacces') || content.contains('权限')) {
      return 'permission';
    }
    if (content.contains('no such file') || content.contains('enoent') || content.contains('not found') && content.contains('file')) {
      return 'file_not_found';
    }
    if (content.contains('connection') || content.contains('network') || content.contains('timeout') || content.contains('fetch failed')) {
      return 'network';
    }
    if (content.contains('syntax error') || content.contains('unexpected token') || content.contains('parse error')) {
      return 'syntax';
    }
    if (content.contains('command not found') || content.contains('module not found') || content.contains('no module named')) {
      return 'dependency';
    }
    return null;
  }
  
  /// 检查搜索词是否与特定错误类型相关
  bool _isRelatedToErrorType(String searchTerm, String errorType) {
    switch (errorType) {
      case 'permission':
        return searchTerm.contains('sudo') || searchTerm.contains('chmod') || searchTerm.contains('chown');
      case 'file_not_found':
        return searchTerm.contains('/') || searchTerm.contains('\\') || searchTerm.contains('.');
      case 'network':
        return searchTerm.contains('http') || searchTerm.contains('npm') || searchTerm.contains('pip') || searchTerm.contains('curl');
      case 'syntax':
        return searchTerm.contains('sh') || searchTerm.contains('bash') || searchTerm.contains('python') || searchTerm.contains('node');
      case 'dependency':
        return searchTerm.contains('install') || searchTerm.contains('npm') || searchTerm.contains('pip') || searchTerm.contains('brew');
      default:
        return false;
    }
  }
  
  /// 向量语义搜索失败经验（关键词匹配无结果时的 fallback）
  String? _semanticSearchFailures(String toolId, List<String> searchTerms) {
    if (_vectorStore == null || _vectorStore!.count == 0) return null;
    
    // 构建查询文本
    final query = '$toolId ${searchTerms.join(' ')}';
    
    // 同步执行语义搜索（VectorMemoryStore.search 是 async 的，这里用 then 回调不阻塞）
    // 由于 searchRelevantFailures 本身不是 async，我们直接用简单的向量匹配
    // 注意：LocalEmbeddingService.embed 是轻量级的本地计算，实际上不会真正异步
    try {
      final queryVector = _syncEmbed(query);
      if (queryVector == null) return null;
      
      final results = <MapEntry<String, double>>[];
      
      // 从失败经验中筛选
      final failures = getFailureLessons();
      for (final failure in failures) {
        final metadata = failure['metadata'];
        if (metadata is Map && metadata['promoted'] == true) continue;
        if (metadata is Map && metadata['outdated'] == true) continue;
        
        final content = failure['content'] as String;
        final contentVector = _syncEmbed(content);
        if (contentVector == null) continue;
        
        final score = _cosineSimilarity(queryVector, contentVector);
        if (score > 0.3) { // 语义相似度阈值
          results.add(MapEntry(content, score));
        }
      }
      
      if (results.isEmpty) return null;
      
      results.sort((a, b) => b.value.compareTo(a.value));
      final topResults = results.take(3);
      
      final sb = StringBuffer('【⚠️ 相关失败经验提示（语义匹配）】\n');
      sb.writeln('之前执行类似操作时遇到过以下问题，请参考避免：\n');
      for (final entry in topResults) {
        sb.writeln('- ${entry.key}');
      }
      sb.writeln('\n请根据以上经验调整你的操作。');
      
      debugPrint('🧠 语义搜索 fallback 命中 ${results.length} 条失败经验');
      return sb.toString();
    } catch (e) {
      debugPrint('🧠 语义搜索 fallback 失败: $e');
      return null;
    }
  }
  
  /// 简单的同步向量嵌入（使用 LocalEmbeddingService 的逻辑）
  List<double>? _syncEmbed(String text) {
    const dimension = 256;
    final tokens = <String>[];
    
    // 英文单词
    for (final match in RegExp(r'[a-zA-Z]+').allMatches(text.toLowerCase())) {
      tokens.add(match.group(0)!);
    }
    // 中文字符
    for (final match in RegExp(r'[\u4e00-\u9fff]').allMatches(text)) {
      tokens.add(match.group(0)!);
    }
    
    if (tokens.isEmpty) return null;
    
    final vector = List<double>.filled(dimension, 0.0);
    for (int i = 0; i < tokens.length; i++) {
      final hash = tokens[i].hashCode.abs() % (dimension ~/ 2);
      vector[hash] += 1.0;
      if (i < dimension ~/ 2) {
        vector[dimension ~/ 2 + i] = 1.0 / (i + 1);
      }
    }
    
    // L2 归一化
    double norm = 0;
    for (final v in vector) {
      norm += v * v;
    }
    norm = math.sqrt(norm);
    if (norm > 0) {
      for (int i = 0; i < vector.length; i++) {
        vector[i] /= norm;
      }
    }
    
    return vector;
  }
  
  /// 余弦相似度
  double _cosineSimilarity(List<double> a, List<double> b) {
    if (a.length != b.length) return 0;
    double dot = 0, normA = 0, normB = 0;
    for (int i = 0; i < a.length; i++) {
      dot += a[i] * b[i];
      normA += a[i] * a[i];
      normB += b[i] * b[i];
    }
    if (normA == 0 || normB == 0) return 0;
    return dot / (math.sqrt(normA) * math.sqrt(normB));
  }

  /// 失效相关的失败经验（工具成功执行后调用）
  /// 当同一工具+类似操作成功了，说明之前的失败经验可能已过时
  /// [toolId] 成功的工具 ID
  /// [args] 成功的工具参数
  void invalidateRelatedFailures(String toolId, Map<String, dynamic> args) {
    final failures = getFailureLessons();
    if (failures.isEmpty) return;
    
    final toolLower = toolId.toLowerCase();
    int invalidatedCount = 0;
    
    // 构建成功操作的关键词
    final successKeywords = <String>[];
    if (args['command'] != null) {
      final cmd = (args['command'] as String).toLowerCase();
      // 提取命令核心（如 npm install → npm, pip install → pip）
      final parts = cmd.split(RegExp(r'\s+'));
      if (parts.isNotEmpty) successKeywords.add(parts.first);
      if (parts.length > 1) successKeywords.add(parts.take(2).join(' '));
    }
    if (args['path'] != null) {
      successKeywords.add((args['path'] as String).toLowerCase());
    }
    
    for (final failure in failures) {
      final metadata = failure['metadata'];
      if (metadata is! Map) continue;
      // 跳过已失效的
      if (metadata['outdated'] == true) continue;
      
      final content = (failure['content'] as String).toLowerCase();
      final skillId = metadata['skillId'] as String? ?? '';
      
      // 条件1: 同一工具
      if (skillId.toLowerCase() != toolLower) continue;
      
      // 条件2: 操作相似（关键词匹配）
      bool isRelated = false;
      for (final kw in successKeywords) {
        if (kw.length > 3 && content.contains(kw)) {
          isRelated = true;
          break;
        }
      }
      
      if (!isRelated) continue;
      
      // 条件3: 属于环境类错误（这类错误随环境变化而失效）
      final errorType = _extractErrorType(content);
      final isEnvironmentError = errorType == 'dependency' || 
                                  errorType == 'file_not_found' || 
                                  errorType == 'permission' ||
                                  errorType == 'network';
      
      if (isEnvironmentError) {
        // 标记为已过时，不再在 searchRelevantFailures 中返回
        metadata['outdated'] = true;
        metadata['outdatedAt'] = DateTime.now().toIso8601String();
        metadata['outdatedReason'] = '同工具成功执行，环境可能已变化';
        invalidatedCount++;
        debugPrint('🧠 失败经验标记为过时: ${failure['content'].toString().substring(0, 60)}...');
      }
    }
    
    if (invalidatedCount > 0) {
      _saveMemories();
      debugPrint('🧠 共 $invalidatedCount 条失败经验被标记为过时');
    }
  }

  /// 查找是否已存在相似记忆（返回索引，无则 null）
  int? _findSimilarMemory(String content) {
    final normalized = content.toLowerCase().trim();
    // 去掉标签前缀后比较（如 [喜好] 喜欢吃火锅 → 喜欢吃火锅）
    final coreContent = normalized.replaceFirst(RegExp(r'^\[[^\]]+\]\s*'), '');

    for (int i = 0; i < _longTermMemories.length; i++) {
      final existing = (_longTermMemories[i]['content'] as String).toLowerCase().trim();
      final existingCore = existing.replaceFirst(RegExp(r'^\[[^\]]+\]\s*'), '');

      if (existing == normalized || existing == coreContent) {
        return i; // 完全相同
      }
      // 包含关系：新内容完全包含旧内容，或旧内容完全包含新内容
      if (coreContent.length >= 4 &&
          (coreContent.contains(existingCore) || existingCore.contains(coreContent))) {
        return i;
      }
    }
    return null;
  }

  /// 搜索相关记忆（关键词匹配 + 中文 bigram + 重要性排序 + 语义搜索 fallback）
  /// [query] 搜索查询
  /// [limit] 返回结果数量限制
  /// [includeImportant] 是否优先包含重要记忆
  List<String> search(String query, {int limit = retrievalMaxCount, bool includeImportant = true}) {
    if (query.isEmpty) return [];

    final queryLower = query.toLowerCase();

    // 提取关键词：空白分词 + 中文 bigram（2字滑动窗口）+ 英文单词
    final keywords = <String>[];

    // 空白分词（适用于英文/数字/token等）
    final spaceTokens = queryLower.split(RegExp(r'\s+'));
    for (final token in spaceTokens) {
      if (token.length >= 2) keywords.add(token);
    }

    // 中文 bigram：对连续中文字符生成 2 字滑动窗口
    final chinesePattern = RegExp(r'[\u4e00-\u9fff]+');
    for (final match in chinesePattern.allMatches(queryLower)) {
      final segment = match.group(0)!;
      for (int i = 0; i <= segment.length - 2; i++) {
        keywords.add(segment.substring(i, i + 2));
      }
      // 也加入完整中文段（长度≤4时更有效）
      if (segment.length <= 4) keywords.add(segment);
    }

    // 去重
    final keywordSet = keywords.toSet();
    keywords
      ..clear()
      ..addAll(keywordSet);

    if (keywords.isEmpty) {
      // 关键词为空时，返回重要记忆
      if (includeImportant) {
        return _getImportantMemories(limit);
      }
      return [];
    }

    final scored = <MapEntry<Map<String, dynamic>, double>>[];

    for (final memory in _longTermMemories) {
      final content = (memory['content'] as String).toLowerCase();
      int matchScore = 0;
      for (final keyword in keywords) {
        if (content.contains(keyword)) matchScore++;
      }
      if (matchScore > 0) {
        // 基础匹配分
        double score = matchScore.toDouble();
        
        // 重要记忆加分
        final metadata = memory['metadata'];
        final isImportant = metadata is Map && metadata['isImportant'] == true;
        if (isImportant && includeImportant) {
          score *= 2.0;
        }
        
        // 重要性评分加成
        final importance = (memory['importance'] as num?)?.toDouble() ?? 0.5;
        score *= (1.0 + importance * 0.5);
        
        // 时间衰减加成
        final decayBonus = _calculateDecayScore(memory);
        score *= (1.0 + decayBonus * 0.3);
        
        scored.add(MapEntry(memory, score));

        // 被搜索命中时增加访问次数
        _incrementAccessCount(memory);
      }
    }

    // 如果关键词匹配没有结果，尝试语义搜索
    if (scored.isEmpty && _vectorStore != null && _vectorStore!.count > 0) {
      final semanticResults = _semanticSearch(query, limit);
      if (semanticResults.isNotEmpty) {
        return semanticResults;
      }
    }

    scored.sort((a, b) => b.value.compareTo(a.value));
    return scored.take(limit).map((e) => e.key['content'] as String).toList();
  }
  
  /// 获取重要记忆列表
  List<String> _getImportantMemories(int limit) {
    final important = _longTermMemories.where((m) {
      final metadata = m['metadata'];
      return metadata is Map && metadata['isImportant'] == true;
    }).toList();
    
    // 按时间倒序
    important.sort((a, b) {
      final ta = DateTime.tryParse(a['timestamp'] as String? ?? '') ?? DateTime(2000);
      final tb = DateTime.tryParse(b['timestamp'] as String? ?? '') ?? DateTime(2000);
      return tb.compareTo(ta);
    });
    
    return important.take(limit).map((m) => m['content'] as String).toList();
  }
  
  /// 语义搜索（使用本地向量计算）
  List<String> _semanticSearch(String query, int limit) {
    try {
      // 使用已实现的同步向量嵌入方法
      final queryVector = _syncEmbed(query);
      if (queryVector == null) return [];
      
      final results = <MapEntry<String, double>>[];
      
      // 从长期记忆中搜索
      for (final memory in _longTermMemories) {
        final content = memory['content'] as String;
        final contentVector = _syncEmbed(content);
        if (contentVector == null) continue;
        
        final score = _cosineSimilarity(queryVector, contentVector);
        if (score > 0.3) { // 语义相似度阈值
          results.add(MapEntry(content, score));
        }
      }
      
      if (results.isEmpty) return [];
      
      // 按相似度排序
      results.sort((a, b) => b.value.compareTo(a.value));
      debugPrint('🧠 语义搜索命中 ${results.length} 条记忆');
      return results.take(limit).map((e) => e.key).toList();
    } catch (e) {
      debugPrint('🧠 语义搜索失败: $e');
      return [];
    }
  }

  /// 获取记忆上下文字符串（注入到 system prompt）
  /// 包含：1) 关键词匹配的相关记忆 2) 最近的非失败经验记忆（确保不遗漏）
  String getMemoryContext(String userMessage) {
    final relevantMemories = search(userMessage, limit: 5);

    // 补充最近的非失败经验记忆（按时间倒序，最多5条）
    // 这些记忆可能因关键词不匹配而没被 search 找到，但仍然重要
    final recentNonFailureMemories = _longTermMemories.reversed
        .where((m) {
          final metadata = m['metadata'];
          return !(metadata is Map && metadata['type'] == '失败经验');
        })
        .take(5)
        .map((m) => m['content'] as String)
        .toList();

    // 去重：从 recentNonFailureMemories 中移除已在 relevantMemories 中的
    final existingSet = relevantMemories.toSet();
    final additionalMemories = recentNonFailureMemories
        .where((m) => !existingSet.any((e) => e.contains(m) || m.contains(e)))
        .take(3) // 最多补充3条
        .toList();

    final allMemories = [...relevantMemories, ...additionalMemories];

    if (allMemories.isEmpty && _userProfile.isEmpty) return '';

    final parts = <String>[];

    if (_userProfile.isNotEmpty) {
      parts.add('用户信息: ${_userProfile.entries.map((e) => '${e.key}: ${e.value}').join(', ')}');
    }

    if (allMemories.isNotEmpty) {
      parts.add('相关记忆:\n${allMemories.map((m) => '- $m').join('\n')}');
    }

    return parts.join('\n\n');
  }
  
  // ═══════════════════════════════════════════════════════════════════
  /// 记忆注入作为 SystemPromptSegment 统一管理（优化6）
  /// ═══════════════════════════════════════════════════════════════════
  
  /// 获取记忆注入 Segment 列表
  /// 返回可用于 ContextManager 的 SystemPromptSegment 列表
  /// 每个 Segment 有独立的优先级和 token 上限
  List<SystemPromptSegment> getMemorySegments(String userMessage, {
    int userProfileMaxTokens = 200,
    int relevantMemoriesMaxTokens = 800,
    int failureLessonsMaxTokens = 500,
  }) {
    final segments = <SystemPromptSegment>[];
    
    // 1. 用户画像 Segment（优先级最高）
    if (_userProfile.isNotEmpty) {
      final profileContent = _userProfile.entries
          .map((e) => '${e.key}: ${e.value}')
          .join('\n');
      segments.add(SystemPromptSegment(
        id: 'user_profile',
        title: '用户信息',
        content: profileContent,
        priority: 9, // 高优先级
        maxTokens: userProfileMaxTokens,
        optional: false,
        compressible: true,
      ));
    }
    
    // 2. 相关记忆 Segment
    final relevantMemories = search(userMessage, limit: 5);
    if (relevantMemories.isNotEmpty) {
      segments.add(SystemPromptSegment(
        id: 'relevant_memories',
        title: '相关记忆',
        content: relevantMemories.map((m) => '- $m').join('\n'),
        priority: 7,
        maxTokens: relevantMemoriesMaxTokens,
        optional: true,
        compressible: true,
      ));
    }
    
    // 3. 高频失败经验 Segment（升级为永久记忆的）
    final failureContext = getFailureLessonsContext();
    if (failureContext.isNotEmpty) {
      segments.add(SystemPromptSegment(
        id: 'failure_lessons',
        title: '高频失败经验',
        content: failureContext,
        priority: 8, // 优先级高于普通记忆
        maxTokens: failureLessonsMaxTokens,
        optional: false, // 不可省略
        compressible: false,
      ));
    }
    
    return segments;
  }
  
  /// 获取所有记忆 Segment 的总 token 数估算
  int estimateMemorySegmentsTokens(String userMessage) {
    final segments = getMemorySegments(userMessage);
    return segments.fold(0, (sum, seg) => sum + seg.tokenCount);
  }

  /// 更新用户画像
  void updateProfile(String key, dynamic value) {
    _userProfile[key] = value;
    _saveMemories();
    notifyListeners();
  }

  /// 获取用户画像
  Map<String, dynamic> getUserProfile() => _userProfile;

  /// 计算记忆的衰减评分（0~2.0，越高越相关）
  /// 使用指数衰减: score = e^(-λ * daysOld) + accessBoost
  /// 失败经验衰减更快（λ=0.05），普通记忆较慢（λ=0.02）
  double _calculateDecayScore(Map<String, dynamic> memory) {
    final timestampStr = memory['timestamp'] as String?;
    if (timestampStr == null) return 0;

    final timestamp = DateTime.tryParse(timestampStr) ?? DateTime.now();
    final daysOld = DateTime.now().difference(timestamp).inDays.toDouble();
    final accessCount = memory['accessCount'] as int? ?? 0;

    // 根据类型选择衰减速率
    final metadata = memory['metadata'];
    final isFailureLesson = metadata is Map && metadata['type'] == '失败经验';
    final lambda = isFailureLesson ? failureDecayRate : normalDecayRate;

    // 指数衰减: 新记忆 ≈ 1.0, 7天 ≈ 0.7, 14天 ≈ 0.5, 30天 ≈ 0.22
    double score = math.exp(-lambda * daysOld);

    // 访问加分（频繁被使用的记忆衰减更慢）
    score += (accessCount * accessBoostPerHit).clamp(0.0, accessBoostCap);

    return score;
  }

  /// 增加记忆的访问计数
  void _incrementAccessCount(Map<String, dynamic> memory) {
    memory['accessCount'] = (memory['accessCount'] as int? ?? 0) + 1;
  }

  /// 衰减清理：移除过期的失败经验，淘汰超限的旧记忆
  /// 每次会话只需调用一次（幂等）
  void decayAndCleanup() {
    if (_decayCleanedThisSession) return;
    _decayCleanedThisSession = true;

    final now = DateTime.now();
    int removedCount = 0;

    // 1. 移除超过最大保留天数的失败经验
    _longTermMemories.removeWhere((m) {
      final metadata = m['metadata'];
      if (metadata is Map && metadata['type'] == '失败经验') {
        final timestampStr = m['timestamp'] as String?;
        if (timestampStr != null) {
          final timestamp = DateTime.tryParse(timestampStr);
          if (timestamp != null &&
              now.difference(timestamp).inDays > failureMaxAgeDays) {
            removedCount++;
            return true;
          }
        }
      }
      return false;
    });

    // 2. 失败经验总数超限时，淘汰衰减评分最低的（最旧+最少访问）
    final failureLessons = getFailureLessons();
    if (failureLessons.length > failureMaxCount) {
      // 按衰减评分排序（低分在前 = 最应淘汰）
      failureLessons.sort((a, b) =>
          _calculateDecayScore(a).compareTo(_calculateDecayScore(b)));
      final excess = failureLessons.length - failureMaxCount;
      for (int i = 0; i < excess; i++) {
        _longTermMemories.remove(failureLessons[i]);
        removedCount++;
      }
    }

    // 3. 为所有记忆补充缺失的 accessCount 字段（兼容旧数据）
    for (final m in _longTermMemories) {
      m['accessCount'] ??= 0;
    }

    if (removedCount > 0) {
      debugPrint('🧠 衰减清理: 移除 $removedCount 条过期/多余记忆');
      _saveMemories();
      notifyListeners();
    }
  }

  // ── 情感事件记忆系统 ──

  /// 保存一条情感事件
  void saveEmotionalEvent({
    required String emotion,    // happy/sad/stressed/lonely/excited/tired/normal
    required String context,    // "主人凌晨2点还在工作"
    required double intensity,  // 0.0~1.0 强度
  }) {
    if (emotion == 'normal' && intensity < 0.3) return; // 忽略无明显情绪

    _emotionalEvents.add({
      'emotion': emotion,
      'context': context,
      'intensity': intensity,
      'timestamp': DateTime.now().toIso8601String(),
    });

    // 限制最多 100 条情感事件
    if (_emotionalEvents.length > 100) {
      _emotionalEvents.removeRange(0, _emotionalEvents.length - 100);
    }

    _saveEmotionalEvents();
    debugPrint('💝 情感事件记录: $emotion ($intensity) - $context');
  }

  /// 保存情感事件到存储
  void _saveEmotionalEvents() {
    try {
      final box = Hive.box('memory');
      box.put('emotional_events', _emotionalEvents);
    } catch (e) {
      debugPrint('💝 保存情感事件失败: $e');
    }
  }

  /// 获取最近 N 天的情感事件摘要（注入到 prompt）
  String getEmotionalContext({int days = 3, int maxItems = 5}) {
    if (_emotionalEvents.isEmpty) return '';

    final cutoff = DateTime.now().subtract(Duration(days: days));
    final recent = _emotionalEvents.where((e) {
      final ts = DateTime.tryParse(e['timestamp'] as String? ?? '');
      return ts != null && ts.isAfter(cutoff);
    }).toList();

    if (recent.isEmpty) return '';

    // 按时间倒序，取最近的几条
    recent.sort((a, b) {
      final ta = DateTime.tryParse(a['timestamp'] as String? ?? '') ?? DateTime(2000);
      final tb = DateTime.tryParse(b['timestamp'] as String? ?? '') ?? DateTime(2000);
      return tb.compareTo(ta);
    });

    final items = recent.take(maxItems);
    final sb = StringBuffer('## 主人最近的情绪记录\n');
    for (final e in items) {
      final emotion = e['emotion'] as String? ?? 'normal';
      final context = e['context'] as String? ?? '';
      final intensity = (e['intensity'] as num?)?.toDouble() ?? 0;
      final ts = DateTime.tryParse(e['timestamp'] as String? ?? '');
      final timeDesc = ts != null ? _formatRelativeTime(ts) : '';
      sb.writeln('- $timeDesc ${_emotionLabel(emotion)}(强度${(intensity * 100).toInt()}%)：$context');
    }
    sb.writeln('\n请根据以上记录适当调整语气（比如主人最近不开心，要更温柔关心）');
    return sb.toString();
  }

  /// 获取主人最近的主要情绪倾向
  String getRecentMoodTrend() {
    if (_emotionalEvents.isEmpty) return 'normal';

    final cutoff = DateTime.now().subtract(const Duration(days: 3));
    final recent = _emotionalEvents.where((e) {
      final ts = DateTime.tryParse(e['timestamp'] as String? ?? '');
      return ts != null && ts.isAfter(cutoff);
    }).toList();

    if (recent.isEmpty) return 'normal';

    // 统计各情绪出现次数（按强度加权）
    final emotionScores = <String, double>{};
    for (final e in recent) {
      final emotion = e['emotion'] as String? ?? 'normal';
      final intensity = (e['intensity'] as num?)?.toDouble() ?? 0.5;
      emotionScores[emotion] = (emotionScores[emotion] ?? 0) + intensity;
    }

    // 找出最突出的情绪
    var maxEmotion = 'normal';
    var maxScore = 0.0;
    for (final entry in emotionScores.entries) {
      if (entry.value > maxScore && entry.key != 'normal') {
        maxScore = entry.value;
        maxEmotion = entry.key;
      }
    }

    return maxScore > 0.5 ? maxEmotion : 'normal';
  }

  String _formatRelativeTime(DateTime ts) {
    final diff = DateTime.now().difference(ts);
    if (diff.inMinutes < 60) return '${diff.inMinutes}分钟前';
    if (diff.inHours < 24) return '${diff.inHours}小时前';
    if (diff.inDays == 1) return '昨天';
    if (diff.inDays == 2) return '前天';
    return '${diff.inDays}天前';
  }

  String _emotionLabel(String emotion) {
    switch (emotion) {
      case 'happy': return '😊开心';
      case 'sad': return '😢难过';
      case 'stressed': return '😰压力大';
      case 'lonely': return '😔孤独';
      case 'excited': return '🤩兴奋';
      case 'tired': return '😴疲惫';
      default: return '😐平静';
    }
  }

  /// 清除所有记忆
  void clearAll() {
    _longTermMemories.clear();
    _userProfile.clear();
    _emotionalEvents.clear();
    _saveMemories();
    _saveEmotionalEvents();
    notifyListeners();
  }

  /// 获取所有记忆的内容文本列表（用于批量回顾）
  List<String> getAllMemoryContents() {
    return _longTermMemories
        .map((m) => m['content'] as String)
        .toList();
  }

  /// 获取最近 N 条记忆（按时间倒序）
  List<Map<String, dynamic>> getRecentMemories({int limit = 10}) {
    if (_longTermMemories.length <= limit) {
      return List.from(_longTermMemories.reversed);
    }
    return _longTermMemories
        .sublist(_longTermMemories.length - limit)
        .reversed
        .toList();
  }

  /// 检查是否已存在包含指定关键词的记忆
  bool hasMemoryContaining(String keyword) {
    final lower = keyword.toLowerCase();
    return _longTermMemories.any(
      (m) => (m['content'] as String).toLowerCase().contains(lower),
    );
  }
}
