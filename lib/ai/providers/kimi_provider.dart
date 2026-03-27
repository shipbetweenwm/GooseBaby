import '../../models/models.dart';
import 'openai_provider.dart';

/// Kimi (月之暗面 Moonshot) 大模型适配器
/// 兼容 OpenAI 接口
class KimiProvider extends OpenAIProvider {
  @override
  String get name => 'kimi';

  @override
  String get displayName => 'Kimi';

  @override
  List<String> get supportedModels => [
    'moonshot-v1-8k',
    'moonshot-v1-32k',
    'moonshot-v1-128k',
  ];

  @override
  Future<bool> isAvailable(LLMConfig config) async {
    if (config.apiKey.isEmpty) return false;
    try {
      await chat(
        [{'role': 'user', 'content': 'hi'}],
        config: LLMConfig(
          provider: 'kimi', model: 'moonshot-v1-8k',
          apiKey: config.apiKey,
          baseUrl: config.baseUrl ?? 'https://api.moonshot.cn/v1',
          maxTokens: 10,
        ),
      );
      return true;
    } catch (_) {
      return false;
    }
  }
}
