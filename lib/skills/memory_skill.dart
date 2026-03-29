import 'package:flutter/foundation.dart';
import 'skill_base.dart';
import '../ai/memory/memory_manager.dart';
import '../utils/storage.dart';

/// SaveMemory 工具 — LLM 主动保存记忆（参考 Claude Code 的 Memory 机制）
/// 让 LLM 自主判断何时需要保存信息到长期记忆，替代正则匹配"记住"的方式。
/// 触发场景：用户提到 token、密钥、偏好、约定、名字等需要长期记住的内容。
///
/// 特殊处理：如果内容包含 API key 信息，自动：
/// 1. 强制 isImportant=true，永不衰减
/// 2. 同步写入 Hive 搜索 key 配置（使三级查找立即生效）
class SaveMemorySkill extends GooseSkill {
  /// 记忆管理器引用（由外部注入）
  MemoryManager? memoryManager;

  @override
  String get id => 'save_memory';

  @override
  String get name => '保存记忆';

  @override
  String get description =>
      '将需要跨会话记住的重要信息保存到长期记忆。'
      '当用户要求记住某些信息（如 token、密钥、API key、偏好、配置、名字、约定等），'
      '或对话中出现了重要的事实信息时，调用此工具保存。'
      '不需要保存临时性的对话内容。';

  @override
  String get icon => '💾';

  @override
  String get category => '记忆';

  @override
  List<SkillParam> get params => [
        const SkillParam(
          name: 'content',
          description: '要保存的记忆内容。简洁明了地描述要记住的信息。'
              '例如："主人的 GitHub token 是 ghp_xxx"、"主人喜欢用 Vue 而不是 React"、"项目数据库密码是 xxx"',
          type: 'string',
          required: true,
        ),
      ];

  @override
  Future<SkillResult> execute(Map<String, dynamic> args, {void Function(String line)? onOutput}) async {
    final content = args['content'] as String? ?? '';
    if (content.trim().isEmpty) {
      return SkillResult.fail('记忆内容为空');
    }

    if (content.trim().length < 2) {
      return SkillResult.fail('记忆内容太短，请提供更详细的信息');
    }

    if (memoryManager == null) {
      debugPrint('💾 SaveMemory: memoryManager 未注入');
      return SkillResult.fail('记忆系统未初始化');
    }

    try {
      // ── 检测是否为 API key 内容 ──
      final isApiKey = MemoryManager.isApiKeyContent(content);

      memoryManager!.save(
        content.trim(),
        isImportant: isApiKey ? true : null, // API key 强制永久重要
        metadata: {
          'type': isApiKey ? 'api_key' : '用户指令',
          'source': 'llm_save_memory',
          if (isApiKey) 'isApiKey': true,
        },
      );

      // ── 若含 API key，同步写入 Hive 使三级查找立即可用 ──
      if (isApiKey) {
        await _syncApiKeyToHive(content);
        debugPrint('💾 SaveMemory: 检测到 API key，已永久保存并同步到配置');
        return SkillResult.ok('✅ 已永久保存 API key 记忆，搜索/新闻工具下次使用时会自动调取');
      }

      debugPrint('💾 SaveMemory: 已保存 - $content');
      return SkillResult.ok('已记住: $content');
    } catch (e) {
      debugPrint('💾 SaveMemory: 保存失败 - $e');
      return SkillResult.fail('保存记忆失败: $e');
    }
  }

  /// 从记忆文本中提取 provider 名称和 key 值，写入 Hive
  Future<void> _syncApiKeyToHive(String content) async {
    final lower = content.toLowerCase();
    // 匹配已知的 provider
    const providers = ['tavily', 'brave', 'exa', 'gnews'];
    for (final provider in providers) {
      if (!lower.contains(provider)) continue;
      // 提取 key 值：取长度 >=10 的字母数字串
      final match = RegExp(r'[A-Za-z0-9\-_]{10,}').firstMatch(content);
      if (match != null) {
        final candidate = match.group(0)!;
        // 排除 provider 名本身
        if (candidate.toLowerCase() == provider) continue;
        await StorageManager.saveSearchApiKey(provider, candidate);
        debugPrint('💾 已同步 $provider key 到 Hive');
      }
      break; // 一次只处理第一个匹配的 provider
    }
  }
}
