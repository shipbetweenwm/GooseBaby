import 'package:flutter/foundation.dart';
import 'skill_base.dart';
import 'built_in/weather_skill.dart';
import 'built_in/time_skill.dart';
import 'built_in/calculator_skill.dart';
import 'built_in/joke_skill.dart';
import 'built_in/reminder_skill.dart';
import 'built_in/system_info_skill.dart';

/// 技能管理器
/// 负责注册、管理和调度所有鹅宝技能
class SkillManager extends ChangeNotifier {
  final Map<String, GooseSkill> _skills = {};
  final Set<String> _disabledSkills = {};

  Map<String, GooseSkill> get skills => Map.unmodifiable(_skills);
  List<GooseSkill> get enabledSkills =>
      _skills.values.where((s) => !_disabledSkills.contains(s.id)).toList();

  SkillManager() {
    _registerBuiltInSkills();
  }

  /// 注册内置技能
  void _registerBuiltInSkills() {
    register(WeatherSkill());
    register(TimeSkill());
    register(CalculatorSkill());
    register(JokeSkill());
    register(ReminderSkill());
    register(SystemInfoSkill());
    debugPrint('🦢 鹅宝技能系统已加载 ${_skills.length} 个技能');
  }

  /// 注册一个技能
  void register(GooseSkill skill) {
    _skills[skill.id] = skill;
    notifyListeners();
  }

  /// 注销一个技能
  void unregister(String skillId) {
    _skills.remove(skillId);
    _disabledSkills.remove(skillId);
    notifyListeners();
  }

  /// 启用/禁用技能
  void setEnabled(String skillId, bool enabled) {
    if (enabled) {
      _disabledSkills.remove(skillId);
    } else {
      _disabledSkills.add(skillId);
    }
    notifyListeners();
  }

  /// 获取技能
  GooseSkill? getSkill(String skillId) => _skills[skillId];

  /// 执行技能
  Future<SkillResult> execute(String skillId, Map<String, dynamic> args) async {
    final skill = _skills[skillId];
    if (skill == null) {
      return SkillResult.fail('未找到技能: $skillId');
    }
    if (_disabledSkills.contains(skillId)) {
      return SkillResult.fail('技能 ${skill.name} 已被禁用');
    }

    try {
      debugPrint('🦢 执行技能: ${skill.name} ($skillId) 参数: $args');
      final result = await skill.execute(args);
      debugPrint('🦢 技能执行完成: ${result.success ? "✅" : "❌"} ${result.message}');
      return result;
    } catch (e) {
      debugPrint('🦢 技能执行异常: $e');
      return SkillResult.fail('技能执行出错: $e');
    }
  }

  /// 生成所有已启用技能的 Function Calling tools 列表
  List<Map<String, dynamic>> toFunctionTools() {
    return enabledSkills.map((s) => s.toFunctionTool()).toList();
  }

  /// 根据分类获取技能
  Map<String, List<GooseSkill>> getSkillsByCategory() {
    final map = <String, List<GooseSkill>>{};
    for (final skill in _skills.values) {
      map.putIfAbsent(skill.category, () => []).add(skill);
    }
    return map;
  }
}
