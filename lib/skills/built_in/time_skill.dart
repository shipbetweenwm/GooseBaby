import 'package:intl/intl.dart';
import '../skill_base.dart';

/// 时间日期技能
class TimeSkill extends GooseSkill {
  @override
  String get id => 'time';

  @override
  String get name => '时间日期';

  @override
  String get description => '查询当前时间、日期，或进行日期计算（距离某天还有多少天）';

  @override
  String get icon => '🕐';

  @override
  String get category => '生活工具';

  @override
  List<SkillParam> get params => [
    const SkillParam(
      name: 'action',
      description: '操作类型',
      type: 'enum',
      required: true,
      enumValues: ['current_time', 'current_date', 'countdown', 'weekday'],
    ),
    const SkillParam(
      name: 'target_date',
      description: '目标日期（用于countdown或weekday），格式YYYY-MM-DD',
      type: 'string',
      required: false,
    ),
  ];

  @override
  Future<SkillResult> execute(Map<String, dynamic> args) async {
    final action = args['action'] as String? ?? 'current_time';
    final now = DateTime.now();

    switch (action) {
      case 'current_time':
        final timeStr = DateFormat('HH:mm:ss').format(now);
        final dateStr = DateFormat('yyyy年MM月dd日 EEEE', 'zh_CN').format(now);
        return SkillResult.ok(
          '现在是 $dateStr $timeStr',
          data: {'time': timeStr, 'date': dateStr},
        );

      case 'current_date':
        final dateStr = DateFormat('yyyy年MM月dd日 EEEE', 'zh_CN').format(now);
        return SkillResult.ok('今天是 $dateStr');

      case 'countdown':
        final targetStr = args['target_date'] as String?;
        if (targetStr == null) {
          return SkillResult.fail('需要提供目标日期哦~');
        }
        try {
          final target = DateTime.parse(targetStr);
          final diff = target.difference(now).inDays;
          if (diff > 0) {
            return SkillResult.ok('距离 $targetStr 还有 $diff 天！');
          } else if (diff < 0) {
            return SkillResult.ok('$targetStr 已经过去了 ${-diff} 天~');
          } else {
            return SkillResult.ok('就是今天啦！🎉');
          }
        } catch (_) {
          return SkillResult.fail('日期格式不对，应该是 YYYY-MM-DD 格式~');
        }

      case 'weekday':
        final targetStr = args['target_date'] as String?;
        if (targetStr == null) {
          return SkillResult.fail('需要提供日期哦~');
        }
        try {
          final target = DateTime.parse(targetStr);
          final weekday = DateFormat('EEEE', 'zh_CN').format(target);
          return SkillResult.ok('$targetStr 是 $weekday');
        } catch (_) {
          return SkillResult.fail('日期格式不对，应该是 YYYY-MM-DD 格式~');
        }

      default:
        return SkillResult.fail('不支持的操作: $action');
    }
  }
}
