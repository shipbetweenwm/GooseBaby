import 'package:flutter/foundation.dart';
import 'package:hive/hive.dart';

/// 记忆管理器
/// 管理鹅宝的短期记忆和长期记忆
class MemoryManager extends ChangeNotifier {
  final List<Map<String, dynamic>> _longTermMemories = [];
  Map<String, dynamic> _userProfile = {};

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
  }

  void _saveMemories() {
    final box = Hive.box('memory');
    box.put('long_term', _longTermMemories);
    box.put('user_profile', _userProfile);
  }

  /// 保存一条长期记忆
  void save(String content, {Map<String, dynamic>? metadata}) {
    if (content.trim().isEmpty) return;

    _longTermMemories.add({
      'content': content,
      'timestamp': DateTime.now().toIso8601String(),
      'metadata': metadata ?? {},
    });

    // 限制最多 200 条长期记忆
    if (_longTermMemories.length > 200) {
      _longTermMemories.removeAt(0);
    }

    _saveMemories();
    notifyListeners();
  }

  /// 搜索相关记忆（简单关键词匹配，后续可升级为向量搜索）
  List<String> search(String query, {int limit = 5}) {
    if (query.isEmpty) return [];

    final keywords = query.toLowerCase().split(RegExp(r'\s+'));
    final scored = <MapEntry<String, int>>[];

    for (final memory in _longTermMemories) {
      final content = (memory['content'] as String).toLowerCase();
      int score = 0;
      for (final keyword in keywords) {
        if (content.contains(keyword)) {
          score++;
        }
      }
      if (score > 0) {
        scored.add(MapEntry(memory['content'] as String, score));
      }
    }

    scored.sort((a, b) => b.value.compareTo(a.value));
    return scored.take(limit).map((e) => e.key).toList();
  }

  /// 获取记忆上下文字符串（注入到 system prompt）
  String getMemoryContext(String userMessage) {
    final relevantMemories = search(userMessage, limit: 5);
    if (relevantMemories.isEmpty && _userProfile.isEmpty) return '';

    final parts = <String>[];

    if (_userProfile.isNotEmpty) {
      parts.add('用户信息: ${_userProfile.entries.map((e) => '${e.key}: ${e.value}').join(', ')}');
    }

    if (relevantMemories.isNotEmpty) {
      parts.add('相关记忆:\n${relevantMemories.map((m) => '- $m').join('\n')}');
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

  /// 清除所有记忆
  void clearAll() {
    _longTermMemories.clear();
    _userProfile.clear();
    _saveMemories();
    notifyListeners();
  }
}
