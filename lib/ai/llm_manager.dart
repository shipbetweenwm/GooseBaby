import 'dart:async';
import 'package:flutter/foundation.dart';
import 'package:hive/hive.dart';
import '../models/models.dart';
import 'providers/llm_provider.dart';
import 'providers/qwen_provider.dart';
import 'providers/hunyuan_provider.dart';
import 'providers/openai_provider.dart';
import 'providers/claude_provider.dart';
import 'providers/ollama_provider.dart';
import 'prompts.dart';

/// LLM 管理器
/// 负责模型路由、配置管理、对话调度
class LLMManager extends ChangeNotifier {
  final Map<String, LLMProvider> _providers = {};
  LLMConfig _currentConfig = const LLMConfig(provider: 'qwen', model: 'qwen-turbo');
  bool _isProcessing = false;

  bool get isProcessing => _isProcessing;
  LLMConfig get currentConfig => _currentConfig;

  LLMManager() {
    // 注册所有模型提供者
    _providers['qwen'] = QwenProvider();
    _providers['hunyuan'] = HunyuanProvider();
    _providers['openai'] = OpenAIProvider();
    _providers['claude'] = ClaudeProvider();
    _providers['ollama'] = OllamaProvider();

    _loadConfig();
  }

  /// 从本地加载模型配置
  void _loadConfig() {
    final box = Hive.box('settings');
    final saved = box.get('llm_config');
    if (saved != null && saved is Map) {
      _currentConfig = LLMConfig.fromJson(Map<String, dynamic>.from(saved));
    }
  }

  /// 保存模型配置
  void setConfig(LLMConfig config) {
    _currentConfig = config;
    final box = Hive.box('settings');
    box.put('llm_config', config.toJson());
    notifyListeners();
  }

  /// 获取所有可用的模型提供者信息
  List<Map<String, dynamic>> getAvailableProviders() {
    return _providers.entries.map((e) => <String, dynamic>{
      'name': e.value.name,
      'displayName': e.value.displayName,
      'models': e.value.supportedModels,
    }).toList();
  }

  /// 获取当前提供者
  LLMProvider? get _currentProvider => _providers[_currentConfig.provider];

  /// 同步对话（带鹅宝人格 + 记忆上下文）
  Future<String> chat(
    List<ChatMessage> chatHistory, {
    List<Map<String, dynamic>>? tools,
    String? memoryContext,
  }) async {
    final provider = _currentProvider;
    if (provider == null) {
      throw Exception('未配置模型提供者: ${_currentConfig.provider}');
    }

    _isProcessing = true;
    notifyListeners();

    try {
      // 构建消息列表：系统人格 + 记忆 + 对话历史
      final messages = <Map<String, dynamic>>[];

      // 1. 系统人格 Prompt
      String systemPrompt = GoosePrompts.systemPrompt;
      if (memoryContext != null && memoryContext.isNotEmpty) {
        systemPrompt += '\n\n## 关于主人的记忆\n$memoryContext';
      }
      messages.add({'role': 'system', 'content': systemPrompt});

      // 2. 对话历史（最近 20 轮）
      final recentHistory = chatHistory.length > 40
          ? chatHistory.sublist(chatHistory.length - 40)
          : chatHistory;
      for (final msg in recentHistory) {
        messages.add(msg.toApiMessage());
      }

      final response = await provider.chat(
        messages,
        config: _currentConfig,
        tools: tools,
      );

      return response;
    } finally {
      _isProcessing = false;
      notifyListeners();
    }
  }

  /// 流式对话
  Stream<String> chatStream(
    List<ChatMessage> chatHistory, {
    List<Map<String, dynamic>>? tools,
    String? memoryContext,
  }) async* {
    final provider = _currentProvider;
    if (provider == null) {
      throw Exception('未配置模型提供者: ${_currentConfig.provider}');
    }

    _isProcessing = true;
    notifyListeners();

    try {
      final messages = <Map<String, dynamic>>[];

      String systemPrompt = GoosePrompts.systemPrompt;
      if (memoryContext != null && memoryContext.isNotEmpty) {
        systemPrompt += '\n\n## 关于主人的记忆\n$memoryContext';
      }
      messages.add({'role': 'system', 'content': systemPrompt});

      final recentHistory = chatHistory.length > 40
          ? chatHistory.sublist(chatHistory.length - 40)
          : chatHistory;
      for (final msg in recentHistory) {
        messages.add(msg.toApiMessage());
      }

      yield* provider.chatStream(
        messages,
        config: _currentConfig,
        tools: tools,
      );
    } finally {
      _isProcessing = false;
      notifyListeners();
    }
  }

  /// 从 AI 回复中提取情绪标签
  String extractEmotion(String response) {
    final lower = response.toLowerCase();
    if (lower.contains('😊') || lower.contains('开心') || lower.contains('嘿嘿') || lower.contains('哈哈')) {
      return 'happy';
    }
    if (lower.contains('😢') || lower.contains('难过') || lower.contains('伤心')) {
      return 'sad';
    }
    if (lower.contains('🤔') || lower.contains('让我想想') || lower.contains('思考')) {
      return 'thinking';
    }
    if (lower.contains('😳') || lower.contains('害羞') || lower.contains('不好意思')) {
      return 'shy';
    }
    if (lower.contains('🤩') || lower.contains('太棒了') || lower.contains('厉害')) {
      return 'excited';
    }
    if (lower.contains('😤') || lower.contains('生气') || lower.contains('哼')) {
      return 'angry';
    }
    if (lower.contains('😴') || lower.contains('困') || lower.contains('好累')) {
      return 'sleepy';
    }
    return 'normal';
  }

  /// 测试模型连接
  Future<bool> testConnection(LLMConfig config) async {
    final provider = _providers[config.provider];
    if (provider == null) return false;
    return await provider.isAvailable(config);
  }
}
