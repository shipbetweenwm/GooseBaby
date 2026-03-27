import '../../models/models.dart';
import 'openai_provider.dart';

/// DeepSeek 大模型适配器
/// 兼容 OpenAI 接口
class DeepSeekProvider extends OpenAIProvider {
  @override
  String get name => 'deepseek';

  @override
  String get displayName => 'DeepSeek';

  @override
  List<String> get supportedModels => [
    'deepseek-chat',
    'deepseek-reasoner',
  ];

  @override
  Future<bool> isAvailable(LLMConfig config) async {
    if (config.apiKey.isEmpty) return false;
    try {
      await chat(
        [{'role': 'user', 'content': 'hi'}],
        config: LLMConfig(
          provider: 'deepseek', model: 'deepseek-chat',
          apiKey: config.apiKey,
          baseUrl: config.baseUrl ?? 'https://api.deepseek.com/v1',
          maxTokens: 10,
        ),
      );
      return true;
    } catch (_) {
      return false;
    }
  }
}
