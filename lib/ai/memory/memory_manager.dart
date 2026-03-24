import 'dart:math' as math;
import 'package:flutter/foundation.dart';
import 'package:hive/hive.dart';

/// 记忆管理器
/// 管理鹅宝的短期记忆和长期记忆
class MemoryManager extends ChangeNotifier {
  final List<Map<String, dynamic>> _longTermMemories = [];
  Map<String, dynamic> _userProfile = {};

  // ── 情感事件记忆 ──
  final List<Map<String, dynamic>> _emotionalEvents = [];

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

  List<Map<String, dynamic>> get longTermMemories => _longTermMemories;
  Map<String, dynamic> get userProfile => _userProfile;

  MemoryManager() {
    _loadMemories();
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
  void save(String content, {Map<String, dynamic>? metadata}) {
    if (content.trim().isEmpty) return;

    // 去重：如果已存在高度相似的记忆（完全相同或已包含），则更新而非新增
    final existingIdx = _findSimilarMemory(content);
    if (existingIdx != null) {
      final existing = _longTermMemories[existingIdx];
      final existingContent = existing['content'] as String;
      // 如果新内容更长更详细，则替换
      if (content.length > existingContent.length * 1.2) {
        existing['content'] = content;
        existing['timestamp'] = DateTime.now().toIso8601String();
        existing['metadata'] = {'type': '合并更新', 'source': 'merged', 'original': existingContent};
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
      'metadata': metadata ?? {},
    });

    // 限制最多 200 条长期记忆
    if (_longTermMemories.length > 200) {
      _longTermMemories.removeAt(0);
    }

    _saveMemories();
    notifyListeners();
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

    final matched = <Map<String, dynamic>>[];

    for (final failure in failures) {
      // 已升级为永久记忆的跳过（已通过 system prompt 注入，避免重复提示）
      final metadata = failure['metadata'];
      if (metadata is Map && metadata['promoted'] == true) continue;

      final content = (failure['content'] as String).toLowerCase();
      int score = 0;

      // 关键词匹配
      for (final term in searchTerms) {
        // 提取 term 中的关键部分（去掉路径中的具体文件名，保留命令/扩展名等）
        final keywords = term.split(RegExp(r'[\\/\s,;]+')).where((s) => s.length > 1);
        for (final kw in keywords) {
          if (content.contains(kw)) score++;
        }
      }

      // 工具ID精确匹配加分
      if (content.contains(toolId.toLowerCase())) score += 3;

      if (score > 0) {
        matched.add(failure);

        // 更新命中次数
        final metadata = failure['metadata'];
        if (metadata is Map) {
          metadata['hitCount'] = (metadata['hitCount'] as int? ?? 0) + 1;

          // 检查是否需要升级为永久记忆
          if (metadata['promoted'] != true &&
              (metadata['hitCount'] as int) >= promotedThreshold) {
            metadata['promoted'] = true;
            debugPrint('🧠 失败经验升级为永久记忆: ${failure['content'].substring(0, 50)}...');
            _saveMemories();
          }
        }

        // 增加访问计数
        _incrementAccessCount(failure);
      }
    }

    if (matched.isEmpty) return null;

    // 按匹配分排序，取 top 3
    matched.sort((a, b) {
      final aHits = (a['metadata'] as Map?)?['hitCount'] as int? ?? 0;
      final bHits = (b['metadata'] as Map?)?['hitCount'] as int? ?? 0;
      return bHits.compareTo(aHits); // 高频经验优先
    });

    final topResults = matched.take(3);
    final sb = StringBuffer('【⚠️ 相关失败经验提示】\n');
    sb.writeln('之前执行类似操作时遇到过以下问题，请参考避免：\n');
    for (final f in topResults) {
      sb.writeln('- ${f['content'] as String}');
    }
    sb.writeln('\n请根据以上经验调整你的操作。');

    return sb.toString();
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

  /// 搜索相关记忆（关键词匹配 + 中文 bigram 匹配 + 时间衰减排序）
  List<String> search(String query, {int limit = 5}) {
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

    if (keywords.isEmpty) return [];

    final scored = <MapEntry<Map<String, dynamic>, double>>[];

    for (final memory in _longTermMemories) {
      final content = (memory['content'] as String).toLowerCase();
      int matchScore = 0;
      for (final keyword in keywords) {
        if (content.contains(keyword)) matchScore++;
      }
      if (matchScore > 0) {
        // 关键词匹配分 × (1 + 衰减分) → 新记忆排序靠前
        final decayBonus = _calculateDecayScore(memory);
        scored.add(MapEntry(memory, matchScore * (1.0 + decayBonus)));

        // 被搜索命中时增加访问次数
        _incrementAccessCount(memory);
      }
    }

    scored.sort((a, b) => b.value.compareTo(a.value));
    return scored.take(limit).map((e) => e.key['content'] as String).toList();
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
