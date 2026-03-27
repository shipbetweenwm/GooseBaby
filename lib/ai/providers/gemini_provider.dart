import '../../models/models.dart';
import 'openai_provider.dart';

/// Google Gemini 大模型适配器
/// 使用 OpenAI 兼容接口（Gemini API 支持）
class GeminiProvider extends OpenAIProvider {
  @override
  String get name => 'gemini';

  @override
  String get displayName => 'Gemini';

  @override
  List<String> get supportedModels => [
    'gemini-2.5-flash',
    'gemini-2.5-pro',
    'gemini-2.0-flash',
    'gemini-1.5-pro',
    'gemini-1.5-flash',
  ];

  @override
  Future<bool> isAvailable(LLMConfig config) async {
    if (config.apiKey.isEmpty) return false;
    try {
      await chat(
        [{'role': 'user', 'content': 'hi'}],
        config: LLMConfig(
          provider: 'gemini', model: 'gemini-2.0-flash',
          apiKey: config.apiKey,
          baseUrl: config.baseUrl ?? 'https://generativelanguage.googleapis.com/v1beta/openai',
          maxTokens: 10,
        ),
      );
      return true;
    } catch (_) {
      return false;
    }
  }
}
