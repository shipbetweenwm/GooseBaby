import 'package:flutter/foundation.dart';
import 'skill_base.dart';

/// Think 工具 — 透明化思考（参考 Claude Code 的 Think tool）
/// 空操作工具，用于记录推理过程，不执行任何代码。
/// 让 LLM 在复杂任务、错误排查、多步规划时先组织思路。
class ThinkSkill extends GooseSkill {
  @override
  String get id => 'think';

  @override
  String get name => '思考';

  @override
  String get description =>
      '记录推理过程的透明化思考工具。'
      '遇到复杂问题（多步骤任务、排查错误、做技术决策、对比方案）时调用此工具组织思路。'
      '此工具不执行任何代码，只是帮助你在采取行动前理清思路。';

  @override
  String get icon => '🧠';

  @override
  String get category => '思考';

  @override
  List<SkillParam> get params => [
        const SkillParam(
          name: 'thought',
          description: '你的思考过程。'
              '包括：需求分析、技术方案对比、代码结构规划、错误根因分析、风险评估等。',
          type: 'string',
          required: true,
        ),
      ];

  @override
  Future<SkillResult> execute(Map<String, dynamic> args) async {
    final thought = args['thought'] as String? ?? '';
    if (thought.trim().isEmpty) {
      return SkillResult.fail('思考内容为空');
    }

    debugPrint('🧠 Think: ${thought.length > 100 ? "${thought.substring(0, 100)}..." : thought}');

    // Think 工具不执行任何操作，直接返回确认
    return SkillResult.ok('思考已记录，请继续执行下一步。');
  }
}
