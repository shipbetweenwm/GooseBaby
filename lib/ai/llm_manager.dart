import 'dart:async';
import 'package:flutter/foundation.dart';
import 'package:hive/hive.dart';
import '../models/models.dart';
import 'agent/agent_types.dart';
import 'providers/llm_provider.dart';
import 'providers/qwen_provider.dart';
import 'providers/hunyuan_provider.dart';
import 'providers/openai_provider.dart';
import 'providers/claude_provider.dart';
import 'providers/ollama_provider.dart';
import 'providers/chatglm_provider.dart';
import 'providers/deepseek_provider.dart';
import 'providers/kimi_provider.dart';
import 'providers/minimax_provider.dart';
import 'providers/gemini_provider.dart';
import 'prompts.dart';
import 'task_aware_prompt.dart';

/// LLM 管理器
/// 负责模型路由、配置管理、对话调度
class LLMManager extends ChangeNotifier {
  final Map<String, LLMProvider> _providers = {};
  LLMConfig _currentConfig = const LLMConfig(provider: 'qwen', model: 'qwen-turbo');
  bool _isProcessing = false;

  bool get isProcessing => _isProcessing;
  LLMConfig get currentConfig => _currentConfig;

  LLMManager() {
    _providers['qwen'] = QwenProvider();
    _providers['hunyuan'] = HunyuanProvider();
    _providers['openai'] = OpenAIProvider();
    _providers['claude'] = ClaudeProvider();
    _providers['deepseek'] = DeepSeekProvider();
    _providers['kimi'] = KimiProvider();
    _providers['minimax'] = MiniMaxProvider();
    _providers['gemini'] = GeminiProvider();
    _providers['ollama'] = OllamaProvider();
    _providers['chatglm'] = ChatGLMProvider();
    _loadConfig();
  }

  /// 从本地加载模型配置
  void _loadConfig() {
    final box = Hive.box('settings');
    final saved = box.get('llm_config');
    if (saved != null && saved is Map) {
      var config = LLMConfig.fromJson(Map<String, dynamic>.from(saved));
      if (config.maxTokens < 81920) {
        config = config.copyWith(maxTokens: 81920);
        box.put('llm_config', config.toJson());
      }
      if (config.provider == 'hunyuan' &&
          config.baseUrl != null &&
          config.baseUrl!.contains('hunyuan.tencentcloudapi.com')) {
        config = config.copyWith(baseUrl: 'https://api.hunyuan.cloud.tencent.com/v1');
        box.put('llm_config', config.toJson());
      }
      _currentConfig = config;
    }
  }

  void setConfig(LLMConfig config) {
    _currentConfig = config;
    final box = Hive.box('settings');
    box.put('llm_config', config.toJson());
    notifyListeners();
  }

  List<Map<String, dynamic>> getAvailableProviders() {
    return _providers.entries.map((e) => <String, dynamic>{
      'name': e.value.name,
      'displayName': e.value.displayName,
      'models': e.value.supportedModels,
    }).toList();
  }

  LLMProvider? get currentProvider => _providers[_currentConfig.provider];

  /// 同步对话（带鹅宝人格），返回结构化响应
  Future<AgentResponse> chat({
    required List<ChatMessage> chatHistory,
    List<Map<String, dynamic>>? tools,
    String? memoryContext,
    String? improvementContext,
    String? agentSkillsPrompt,
    String? envPrompt,
    bool workMode = false,
  }) async {
    final provider = currentProvider;
    if (provider == null) {
      throw Exception('未配置模型提供者: ${_currentConfig.provider}');
    }

    _isProcessing = true;
    notifyListeners();

    try {
      final messages = _buildMessages(
        chatHistory: chatHistory,
        workMode: workMode,
        memoryContext: memoryContext,
        improvementContext: improvementContext,
        agentSkillsPrompt: agentSkillsPrompt,
        envPrompt: envPrompt,
      );

      return await provider.chat(messages, config: _currentConfig, tools: tools);
    } finally {
      _isProcessing = false;
      notifyListeners();
    }
  }

  /// 使用原始消息列表调用 LLM（保留 tool_calls/tool 等 API 字段）
  Future<AgentResponse> chatWithMessages(
    List<Map<String, dynamic>> rawMessages, {
    List<Map<String, dynamic>>? tools,
  }) async {
    final provider = currentProvider;
    if (provider == null) {
      throw Exception('未配置模型提供者: ${_currentConfig.provider}');
    }
    return await provider.chat(rawMessages, config: _currentConfig, tools: tools);
  }

  /// 流式调用（使用原始消息列表，保留 tool_calls/tool 等 API 字段）
  /// 用于纯文本回复的流式展示
  Stream<String> chatStreamWithMessages(
    List<Map<String, dynamic>> rawMessages, {
    List<Map<String, dynamic>>? tools,
  }) async* {
    final provider = currentProvider;
    if (provider == null) {
      throw Exception('未配置模型提供者: ${_currentConfig.provider}');
    }

    _isProcessing = true;
    notifyListeners();

    try {
      yield* provider.chatStream(rawMessages, config: _currentConfig, tools: tools);
    } finally {
      _isProcessing = false;
      notifyListeners();
    }
  }

  /// 原始对话（供 self-improvement 等内部模块使用）
  Future<String> chatRaw(List<Map<String, dynamic>> messages) async {
    final provider = currentProvider;
    if (provider == null) {
      throw Exception('未配置模型提供者: ${_currentConfig.provider}');
    }
    try {
      final resp = await provider.chat(messages, config: _currentConfig);
      return resp.text;
    } catch (e) {
      debugPrint('🦢 chatRaw 调用失败: $e');
      return '';
    }
  }

  /// 流式对话
  Stream<String> chatStream({
    required List<ChatMessage> chatHistory,
    List<Map<String, dynamic>>? tools,
    String? memoryContext,
    bool workMode = false,
  }) async* {
    final provider = currentProvider;
    if (provider == null) {
      throw Exception('未配置模型提供者: ${_currentConfig.provider}');
    }

    _isProcessing = true;
    notifyListeners();

    try {
      final messages = _buildMessages(
        chatHistory: chatHistory,
        workMode: workMode,
        memoryContext: memoryContext,
      );

      yield* provider.chatStream(messages, config: _currentConfig, tools: tools);
    } finally {
      _isProcessing = false;
      notifyListeners();
    }
  }

  /// 构建 messages 列表（system prompt + 对话历史）
  List<Map<String, dynamic>> _buildMessages({
    required List<ChatMessage> chatHistory,
    bool workMode = false,
    String? memoryContext,
    String? improvementContext,
    String? agentSkillsPrompt,
    String? envPrompt,
  }) {
    final messages = <Map<String, dynamic>>[];

    String systemPrompt = workMode
        ? GoosePrompts.workModeSystemPrompt
        : GoosePrompts.systemPrompt;
    if (memoryContext != null && memoryContext.isNotEmpty) {
      systemPrompt += '\n\n## 关于主人的记忆\n$memoryContext';
    }
    if (improvementContext != null && improvementContext.isNotEmpty) {
      systemPrompt += '\n\n$improvementContext';
    }
    if (agentSkillsPrompt != null && agentSkillsPrompt.isNotEmpty) {
      systemPrompt += '\n\n$agentSkillsPrompt';
    }
    if (envPrompt != null && envPrompt.isNotEmpty) {
      systemPrompt += envPrompt;
    }
    messages.add({'role': 'system', 'content': systemPrompt});

    final recentHistory = chatHistory.length > 40
        ? chatHistory.sublist(chatHistory.length - 40)
        : chatHistory;
    for (final msg in recentHistory) {
      messages.add(msg.toApiMessage());
    }
    return messages;
  }

  String extractEmotion(String response) {
    final lower = response.toLowerCase();
    if (lower.contains('😊') || lower.contains('开心') || lower.contains('嘿嘿') || lower.contains('哈哈')) return 'happy';
    if (lower.contains('😢') || lower.contains('难过') || lower.contains('伤心')) return 'sad';
    if (lower.contains('😳') || lower.contains('害羞') || lower.contains('不好意思')) return 'shy';
    if (lower.contains('🤩') || lower.contains('太棒了') || lower.contains('厉害')) return 'excited';
    if (lower.contains('😤') || lower.contains('生气') || lower.contains('哼')) return 'angry';
    if (lower.contains('😴') || lower.contains('困') || lower.contains('好累')) return 'sleepy';
    return 'normal';
  }

  Future<bool> testConnection(LLMConfig config) async {
    final provider = _providers[config.provider];
    if (provider == null) return false;
    return await provider.isAvailable(config);
  }
}
