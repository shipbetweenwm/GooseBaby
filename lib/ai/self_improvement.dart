import 'package:flutter/foundation.dart';
import 'package:hive/hive.dart';
import '../models/models.dart';
import 'llm_manager.dart';
import 'memory/memory_manager.dart';

/// Self-Improvement 引擎
///
/// 鹅宝的自我进化机制：
/// 1. 智能记忆提取 - 从对话中提取结构化信息（姓名、喜好、习惯、重要事件）
/// 2. 对话反思 - 分析对话质量，提取改进策略
/// 3. 用户画像更新 - 持续完善对用户的理解
/// 4. 互动模式学习 - 学习用户偏好的对话风格
class SelfImprovementEngine extends ChangeNotifier {
  final LLMManager _llmManager;
  final MemoryManager _memoryManager;

  /// 对话反思记录
  final List<Map<String, dynamic>> _reflections = [];

  /// 学习到的对话策略
  final List<String> _learnedStrategies = [];

  /// 累计对话轮次（用于触发定期反思）
  int _conversationTurns = 0;

  /// 上次反思的轮次
  int _lastReflectionTurn = 0;

  List<Map<String, dynamic>> get reflections => _reflections;
  List<String> get learnedStrategies => List.unmodifiable(_learnedStrategies);
  int get conversationTurns => _conversationTurns;

  SelfImprovementEngine({
    required LLMManager llmManager,
    required MemoryManager memoryManager,
  })  : _llmManager = llmManager,
        _memoryManager = memoryManager {
    _loadState();
  }

  void _loadState() {
    try {
      final box = Hive.box('memory');

      // 加载已学习的策略
      final strategies = box.get('learned_strategies', defaultValue: <dynamic>[]);
      if (strategies is List) {
        _learnedStrategies.addAll(strategies.cast<String>());
      }

      // 加载对话轮次
      _conversationTurns = box.get('conversation_turns', defaultValue: 0) as int;
      _lastReflectionTurn = box.get('last_reflection_turn', defaultValue: 0) as int;

      // 加载反思记录
      final refs = box.get('reflections', defaultValue: <dynamic>[]);
      if (refs is List) {
        for (final r in refs) {
          if (r is Map) {
            _reflections.add(Map<String, dynamic>.from(r));
          }
        }
      }
    } catch (e) {
      debugPrint('🧠 Self-improvement 状态加载失败: $e');
    }
  }

  void _saveState() {
    try {
      final box = Hive.box('memory');
      box.put('learned_strategies', _learnedStrategies);
      box.put('conversation_turns', _conversationTurns);
      box.put('last_reflection_turn', _lastReflectionTurn);
      // 只保留最近 20 条反思
      final recentReflections = _reflections.length > 20
          ? _reflections.sublist(_reflections.length - 20)
          : _reflections;
      box.put('reflections', recentReflections);
    } catch (e) {
      debugPrint('🧠 Self-improvement 状态保存失败: $e');
    }
  }

  /// 对话后处理 - 每次对话结束后调用
  ///
  /// 做三件事：
  /// 1. 智能记忆提取（基于多轮上下文）
  /// 2. 计数并决定是否触发深度回顾
  /// 3. 用户画像更新
  Future<void> afterConversation({
    required String userMessage,
    required String botResponse,
    required List<ChatMessage> recentHistory,
  }) async {
    _conversationTurns++;

    // 1. 智能记忆提取（每次都做，传入多轮上下文）
    await _extractAndSaveMemory(userMessage, botResponse, recentHistory);

    // 2. 每 5 轮对话触发一次深度回顾（反思 + 记忆合并/整理）
    if (_conversationTurns - _lastReflectionTurn >= 5) {
      await _deepReview(recentHistory);
      _lastReflectionTurn = _conversationTurns;
    }

    _saveState();
  }

  /// 智能记忆提取 - 从对话中提取有价值的信息（基于多轮上下文）
  Future<void> _extractAndSaveMemory(
    String userMsg, String botReply, List<ChatMessage> recentHistory,
  ) async {
    // 太短的消息不提取
    if (userMsg.length < 5) return;

    try {
      // 构建多轮上下文（最近 6 条消息，即 3 轮对话）
      final contextWindow = recentHistory.length > 6
          ? recentHistory.sublist(recentHistory.length - 6)
          : recentHistory;
      final contextText = contextWindow
          .map((m) => '${m.role == 'user' ? '用户' : '鹅宝'}: ${m.content}')
          .join('\n');

      final extractPrompt = '''分析以下对话片段，提取需要长期记住的关键信息。

$contextText

请提取以下类型的信息（如果有的话）：
1. [名字] 用户提到的自己或他人的名字
2. [喜好] 用户表达的喜好、兴趣、爱好
3. [习惯] 用户的日常习惯、作息
4. [事件] 用户提到的重要事件、计划、截止日期
5. [情感] 用户当前的情绪状态、困扰
6. [事实] 用户提到的关于自己的事实信息（工作、学校、城市等）
7. [记忆] 用户明确要求记住的内容

每条信息一行，格式: [类型] 内容
如果没有需要记住的信息，只回复: 无

注意：
- 只提取确定的事实信息，不要猜测或编造
- 结合上下文理解语义，如用户说"下周三面试"提取为[事件]
- 如果信息在上下文中已出现过，不要重复提取
- 关注用户主动分享的个人信息（名字、工作、家庭、城市等）''';

      // 构建消息列表
      final messages = [
        {'role': 'system', 'content': '你是一个记忆提取助手，从对话中提取需要长期记住的结构化信息。只输出提取结果，不要闲聊。'},
        {'role': 'user', 'content': extractPrompt},
      ];

      final result = await _llmManager.chatRaw(messages);

      if (result.trim() == '无' || result.trim().isEmpty) return;

      // 解析提取结果
      final lines = result.split('\n').where((l) => l.trim().isNotEmpty).toList();
      int savedCount = 0;
      for (final line in lines) {
        final trimmed = line.trim();
        if (trimmed.startsWith('[') && trimmed.contains(']')) {
          final tagEnd = trimmed.indexOf(']');
          final tag = trimmed.substring(1, tagEnd).trim();
          final content = trimmed.substring(tagEnd + 1).trim();

          if (content.isNotEmpty) {
            if (tag == '名字' || tag == '事实') {
              _memoryManager.updateProfile(tag, content);
              debugPrint('🧠 更新用户画像: [$tag] $content');
            } else if (tag == '记忆') {
              _memoryManager.save(content, metadata: {'type': '记忆', 'source': 'explicit_memory', 'important': true});
              debugPrint('🧠 保存显式记忆: $content');
            } else {
              _memoryManager.save('[$tag] $content', metadata: {'type': tag, 'source': 'self_improvement'});
              debugPrint('🧠 提取记忆: [$tag] $content');
            }
            savedCount++;
          }
        }
      }
      if (savedCount > 0) {
        debugPrint('🧠 本轮提取 $savedCount 条新记忆');
      }
    } catch (e) {
      debugPrint('🧠 记忆提取失败: $e');
    }
  }

  /// 深度回顾 - 每 5 轮对话触发一次
  /// 同时做：对话反思 + 记忆回顾整理 + 用户画像补充
  Future<void> _deepReview(List<ChatMessage> recentHistory) async {
    if (recentHistory.length < 4) return;

    // 并行执行：对话质量反思 + 记忆回顾
    await Future.wait([
      _reflectOnConversations(recentHistory),
      _reviewAndConsolidateMemories(recentHistory),
    ]);
  }

  /// 对话反思 - 分析最近对话，提取改进策略
  Future<void> _reflectOnConversations(List<ChatMessage> recentHistory) async {
    if (recentHistory.length < 4) return; // 至少 2 轮对话

    try {
      // 取最近 10 条消息用于反思
      final recent = recentHistory.length > 10
          ? recentHistory.sublist(recentHistory.length - 10)
          : recentHistory;

      final dialogText = recent
          .map((m) => '${m.role == 'user' ? '用户' : '鹅宝'}: ${m.content}')
          .join('\n');

      final reflectPrompt = '''回顾以下鹅宝（AI 小白鹅）和用户的对话，进行自我反思：

$dialogText

请从以下维度分析并给出改进建议（每条一行，简洁）：
1. 回复质量：鹅宝的回复是否有帮助、是否准确？
2. 情感连接：鹅宝是否恰当回应了用户的情绪？
3. 角色一致性：鹅宝是否保持了可爱小白鹅的人设？
4. 用户偏好：用户似乎喜欢什么样的对话风格？

格式：每条以 "- " 开头，最多 5 条建议。
只输出改进建议，不要重复对话内容。''';

      final messages = [
        {'role': 'system', 'content': '你是一个对话质量分析师。分析 AI 宠物"鹅宝"的对话表现，给出具体改进建议。'},
        {'role': 'user', 'content': reflectPrompt},
      ];

      final result = await _llmManager.chatRaw(messages);

      if (result.trim().isEmpty) return;

      // 解析反思结果
      final suggestions = result
          .split('\n')
          .where((l) => l.trim().startsWith('-') || l.trim().startsWith('•'))
          .map((l) => l.replaceFirst(RegExp(r'^[\s\-•]+'), '').trim())
          .where((l) => l.isNotEmpty)
          .toList();

      if (suggestions.isNotEmpty) {
        // 记录反思
        _reflections.add({
          'timestamp': DateTime.now().toIso8601String(),
          'turn': _conversationTurns,
          'suggestions': suggestions,
        });

        // 更新学习策略（去重，保留最近 15 条）
        for (final s in suggestions) {
          if (!_learnedStrategies.contains(s)) {
            _learnedStrategies.add(s);
          }
        }
        if (_learnedStrategies.length > 15) {
          _learnedStrategies.removeRange(0, _learnedStrategies.length - 15);
        }

        debugPrint('🧠 对话反思完成，提取 ${suggestions.length} 条改进建议');
        notifyListeners();
      }
    } catch (e) {
      debugPrint('🧠 对话反思失败: $e');
    }
  }

  /// 记忆回顾与整理 - 从多轮对话中补充提取遗漏的记忆
  Future<void> _reviewAndConsolidateMemories(List<ChatMessage> recentHistory) async {
    if (recentHistory.length < 6) return;

    try {
      // 取最近 15 条消息用于回顾
      final recent = recentHistory.length > 15
          ? recentHistory.sublist(recentHistory.length - 15)
          : recentHistory;

      final dialogText = recent
          .map((m) => '${m.role == 'user' ? '用户' : '鹅宝'}: ${m.content}')
          .join('\n');

      // 取出已有记忆摘要，让 LLM 知道哪些已经记住了
      final existingMemories = _memoryManager.getRecentMemories(limit: 10);
      final existingText = existingMemories.isEmpty
          ? '（暂无已有记忆）'
          : existingMemories.map((m) => '- ${m['content']}').join('\n');

      final reviewPrompt = '''回顾以下对话和已有记忆，找出对话中遗漏的重要信息。

## 最近对话
$dialogText

## 鹅宝已有的记忆
$existingText

请完成以下任务：
1. 从对话中找出尚未记住的重要信息（名字、喜好、习惯、事件、事实等）
2. 注意：不要重复已有记忆中的内容

每条新信息一行，格式: [类型] 内容
如果没有遗漏的重要信息，只回复: 无

只输出新发现的信息，不要重复已知内容。''';

      final messages = [
        {'role': 'system', 'content': '你是一个记忆回顾助手，负责从对话中找出之前遗漏的重要信息。只输出新发现的信息。'},
        {'role': 'user', 'content': reviewPrompt},
      ];

      final result = await _llmManager.chatRaw(messages);
      if (result.trim() == '无' || result.trim().isEmpty) return;

      // 解析并保存新发现的记忆
      final lines = result.split('\n').where((l) => l.trim().isNotEmpty).toList();
      int newCount = 0;
      for (final line in lines) {
        final trimmed = line.trim();
        if (trimmed.startsWith('[') && trimmed.contains(']')) {
          final tagEnd = trimmed.indexOf(']');
          final tag = trimmed.substring(1, tagEnd).trim();
          final content = trimmed.substring(tagEnd + 1).trim();

          if (content.isNotEmpty) {
            if (tag == '名字' || tag == '事实') {
              _memoryManager.updateProfile(tag, content);
            }
            _memoryManager.save('[$tag] $content', metadata: {'type': tag, 'source': 'review'});
            debugPrint('🧠 回顾补充记忆: [$tag] $content');
            newCount++;
          }
        }
      }
      if (newCount > 0) {
        debugPrint('🧠 记忆回顾完成，补充 $newCount 条新记忆');
      }
    } catch (e) {
      debugPrint('🧠 记忆回顾失败: $e');
    }
  }

  /// 获取学习到的策略上下文（注入到 system prompt）
  String getImprovementContext() {
    if (_learnedStrategies.isEmpty) return '';

    return '''
## 自我改进备忘
以下是你从过去的对话中学到的改进建议，请在回复时参考：
${_learnedStrategies.map((s) => '- $s').join('\n')}
''';
  }

  /// 获取统计信息
  Map<String, dynamic> getStats() {
    return {
      'totalTurns': _conversationTurns,
      'totalReflections': _reflections.length,
      'learnedStrategies': _learnedStrategies.length,
      'memoriesCount': _memoryManager.longTermMemories.length,
      'profileKeys': _memoryManager.userProfile.keys.length,
    };
  }
}
