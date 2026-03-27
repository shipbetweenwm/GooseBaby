import '../../models/models.dart';
import 'openai_provider.dart';

/// MiniMax 大模型适配器
/// 兼容 OpenAI 接口
class MiniMaxProvider extends OpenAIProvider {
  @override
  String get name => 'minimax';

  @override
  String get displayName => 'MiniMax';

  @override
  List<String> get supportedModels => [
    'MiniMax-Text-01',
    'abab6.5s-chat',
    'abab6.5-chat',
    'abab5.5-chat',
  ];

  @override
  Future<bool> isAvailable(LLMConfig config) async {
    if (config.apiKey.isEmpty) return false;
    try {
      await chat(
        [{'role': 'user', 'content': 'hi'}],
        config: LLMConfig(
          provider: 'minimax', model: 'abab6.5s-chat',
          apiKey: config.apiKey,
          baseUrl: config.baseUrl ?? 'https://api.minimax.chat/v1',
          maxTokens: 10,
        ),
      );
      return true;
    } catch (_) {
      return false;
    }
  }
}
