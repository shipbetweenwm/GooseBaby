import 'package:hive/hive.dart';
import 'package:flutter/material.dart';
import '../../models/models.dart';

/// 单个会话
class Conversation {
  final String id;
  String title;
  DateTime createdAt;
  DateTime updatedAt;
  List<ConversationMessage> messages;

  Conversation({
    required this.id,
    required this.title,
    required this.createdAt,
    required this.updatedAt,
    this.messages = const [],
  });

  Map<String, dynamic> toJson() => {
        'id': id,
        'title': title,
        'createdAt': createdAt.toIso8601String(),
        'updatedAt': updatedAt.toIso8601String(),
        'messages': messages.map((m) => m.toJson()).toList(),
      };

  factory Conversation.fromJson(Map<String, dynamic> json) => Conversation(
        id: json['id'] as String,
        title: json['title'] as String,
        createdAt: DateTime.parse(json['createdAt'] as String),
        updatedAt: DateTime.parse(json['updatedAt'] as String),
        messages: (json['messages'] as List?)
                ?.map((m) => ConversationMessage.fromJson(Map<String, dynamic>.from(m)))
                .toList() ??
            [],
      );
}

/// 会话中的消息
class ConversationMessage {
  final String content;
  final bool isUser;
  final DateTime timestamp;
  final String? skillResult;
  final bool isError;
  final List<MessageAttachment> attachments;
  /// 工具调用期间产生的 API 消息序列（用于多轮会话上下文）
  final List<Map<String, dynamic>>? apiMessages;
  /// 工具调用步骤记录（思考+执行过程，用于停止/关闭后恢复显示）
  final List<Map<String, dynamic>>? toolSteps;

  ConversationMessage({
    required this.content,
    required this.isUser,
    required this.timestamp,
    this.skillResult,
    this.isError = false,
    this.attachments = const [],
    this.apiMessages,
    this.toolSteps,
  });

  Map<String, dynamic> toJson() => {
        'content': content,
        'isUser': isUser,
        'timestamp': timestamp.toIso8601String(),
        'skillResult': skillResult,
        'isError': isError,
        'attachments': attachments.map((a) => a.toJson()).toList(),
        'apiMessages': apiMessages,
        'toolSteps': toolSteps,
      };

  factory ConversationMessage.fromJson(Map<String, dynamic> json) => ConversationMessage(
        content: json['content'] as String,
        isUser: json['isUser'] as bool,
        timestamp: DateTime.parse(json['timestamp'] as String),
        skillResult: json['skillResult'] as String?,
        isError: json['isError'] as bool? ?? false,
        attachments: (json['attachments'] as List?)
                ?.map((a) => MessageAttachment.fromJson(Map<String, dynamic>.from(a)))
                .toList() ??
            [],
        apiMessages: (json['apiMessages'] as List?)
                ?.map((m) => Map<String, dynamic>.from(m as Map))
                .toList(),
        toolSteps: (json['toolSteps'] as List?)
                ?.map((m) => Map<String, dynamic>.from(m as Map))
                .toList(),
      );
}

/// 会话管理器
class ConversationManager extends ChangeNotifier {
  static const String _boxName = 'conversations';
  static const String _currentIdKey = 'current_conversation_id';

  late Box _box;
  List<Conversation> _conversations = [];
  String? _currentConversationId;

  List<Conversation> get conversations => _conversations;
  String? get currentConversationId => _currentConversationId;

  Conversation? get currentConversation {
    if (_currentConversationId == null) return null;
    try {
      return _conversations.firstWhere((c) => c.id == _currentConversationId);
    } catch (_) {
      return null;
    }
  }

  Future<void> initialize() async {
    _box = await Hive.openBox(_boxName);
    await _loadConversations();
  }

  Future<void> _loadConversations() async {
    try {
      final data = _box.get('conversations', defaultValue: <dynamic>[]);
      if (data is List && data.isNotEmpty) {
        _conversations = data
            .map((item) => Conversation.fromJson(Map<String, dynamic>.from(item)))
            .toList();
      }

      // 加载当前会话ID
      _currentConversationId = _box.get(_currentIdKey) as String?;

      // 如果没有会话，创建默认会话
      if (_conversations.isEmpty) {
        await createConversation('和鹅宝聊天');
      }

      // 如果当前会话ID不存在，使用第一个
      if (_currentConversationId == null && _conversations.isNotEmpty) {
        _currentConversationId = _conversations.first.id;
        await _box.put(_currentIdKey, _currentConversationId);
      }

      notifyListeners();
    } catch (e) {
      debugPrint('🦢 加载会话失败: $e');
    }
  }

  Future<void> _saveConversations() async {
    try {
      await _box.put('conversations', _conversations.map((c) => c.toJson()).toList());
      notifyListeners();
    } catch (e) {
      debugPrint('🦢 保存会话失败: $e');
    }
  }

  /// 创建新会话
  Future<String> createConversation(String title) async {
    final now = DateTime.now();
    final conv = Conversation(
      id: now.millisecondsSinceEpoch.toString(),
      title: title,
      createdAt: now,
      updatedAt: now,
      messages: [],
    );

    _conversations.insert(0, conv);
    _currentConversationId = conv.id;
    await _box.put(_currentIdKey, _currentConversationId);
    await _saveConversations();

    return conv.id;
  }

  /// 切换当前会话
  Future<void> switchConversation(String id) async {
    if (_conversations.any((c) => c.id == id)) {
      _currentConversationId = id;
      await _box.put(_currentIdKey, _currentConversationId);
      notifyListeners();
    }
  }

  /// 删除会话
  Future<void> deleteConversation(String id) async {
    _conversations.removeWhere((c) => c.id == id);

    // 如果删除的是当前会话，切换到第一个
    if (_currentConversationId == id) {
      _currentConversationId = _conversations.isNotEmpty ? _conversations.first.id : null;
      await _box.put(_currentIdKey, _currentConversationId);
    }

    await _saveConversations();
  }

  /// 添加消息到当前会话
  Future<void> addMessage(ConversationMessage message) async {
    final conv = currentConversation;
    if (conv == null) return;

    conv.messages.add(message);
    conv.updatedAt = DateTime.now();
    await _saveConversations();
  }

  /// 替换当前会话的全部消息（幂等操作，避免重复保存）
  Future<void> updateMessages(List<ConversationMessage> messages) async {
    final conv = currentConversation;
    if (conv == null) return;

    conv.messages = List.from(messages);
    conv.updatedAt = DateTime.now();
    await _saveConversations();
  }

  /// 替换指定会话的全部消息（用于防止切换会话后保存到错误会话）
  Future<void> updateMessagesFor(String conversationId, List<ConversationMessage> messages) async {
    try {
      final conv = _conversations.firstWhere((c) => c.id == conversationId);
      conv.messages = List.from(messages);
      conv.updatedAt = DateTime.now();
      await _saveConversations();
    } catch (_) {
      debugPrint('🦢 未找到会话 $conversationId');
    }
  }

  /// 更新会话标题
  Future<void> updateTitle(String id, String newTitle) async {
    try {
      final conv = _conversations.firstWhere((c) => c.id == id);
      conv.title = newTitle;
      conv.updatedAt = DateTime.now();
      await _saveConversations();
    } catch (_) {}
  }

  /// 清空当前会话消息
  Future<void> clearCurrentMessages() async {
    final conv = currentConversation;
    if (conv == null) return;

    conv.messages.clear();
    conv.updatedAt = DateTime.now();
    await _saveConversations();
  }

  /// 静态方法：获取当天所有会话内容摘要（用于日记生成）
  /// 直接读取 Hive box，无需初始化 ConversationManager 实例
  static Future<String> getTodayConversationsSummary() async {
    try {
      final box = await Hive.openBox('conversations');
      final data = box.get('conversations', defaultValue: <dynamic>[]);
      
      if (data is! List || data.isEmpty) return '';
      
      final now = DateTime.now();
      final today = DateTime(now.year, now.month, now.day);
      
      final buffer = StringBuffer();
      int totalMessages = 0;
      const maxMessages = 50; // 最多展示 50 条消息
      
      for (final item in data) {
        if (item is! Map) continue;
        final conv = Conversation.fromJson(Map<String, dynamic>.from(item));
        
        for (final msg in conv.messages) {
          // 只取今天的消息
          final msgDate = DateTime(msg.timestamp.year, msg.timestamp.month, msg.timestamp.day);
          if (msgDate == today) {
            final role = msg.isUser ? '主人' : '鹅宝';
            final time = '${msg.timestamp.hour.toString().padLeft(2, '0')}:${msg.timestamp.minute.toString().padLeft(2, '0')}';
            // 截取过长的消息
            final content = msg.content.length > 100 
                ? '${msg.content.substring(0, 100)}...' 
                : msg.content;
            buffer.writeln('[$time] $role: $content');
            totalMessages++;
            if (totalMessages >= maxMessages) break;
          }
        }
        if (totalMessages >= maxMessages) break;
      }
      
      return buffer.toString();
    } catch (e) {
      debugPrint('📔 获取今日会话失败: $e');
      return '';
    }
  }
}
