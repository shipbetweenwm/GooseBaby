import 'package:flutter/foundation.dart';
import 'skill_base.dart';
import '../ai/memory/memory_manager.dart';

/// SaveMemory 工具 — LLM 主动保存记忆（参考 Claude Code 的 Memory 机制）
/// 让 LLM 自主判断何时需要保存信息到长期记忆，替代正则匹配"记住"的方式。
/// 触发场景：用户提到 token、密钥、偏好、约定、名字等需要长期记住的内容。
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
      memoryManager!.save(content.trim(), metadata: {
        'type': '用户指令',
        'source': 'llm_save_memory',
      });
      debugPrint('💾 SaveMemory: 已保存 - $content');
      return SkillResult.ok('已记住: $content');
    } catch (e) {
      debugPrint('💾 SaveMemory: 保存失败 - $e');
      return SkillResult.fail('保存记忆失败: $e');
    }
  }
}
