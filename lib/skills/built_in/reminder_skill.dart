import 'dart:async';
import 'package:flutter/foundation.dart';
import '../skill_base.dart';

/// 提醒事项技能
class ReminderSkill extends GooseSkill {
  static final List<_Reminder> _reminders = [];
  static final List<Timer> _timers = [];

  /// 当提醒触发时的回调（由外部设置）
  static void Function(String message)? onReminderTriggered;

  @override
  String get id => 'reminder';

  @override
  String get name => '提醒闹钟';

  @override
  String get description => '设置定时提醒，比如"5分钟后提醒我喝水"、"查看所有提醒"';

  @override
  String get icon => '⏰';

  @override
  String get category => '效率工具';

  @override
  List<SkillParam> get params => [
    const SkillParam(
      name: 'action',
      description: '操作类型',
      type: 'enum',
      required: true,
      enumValues: ['set', 'list', 'cancel'],
    ),
    const SkillParam(
      name: 'minutes',
      description: '提醒时间（分钟后），action为set时需要',
      type: 'int',
      required: false,
    ),
    const SkillParam(
      name: 'message',
      description: '提醒内容',
      type: 'string',
      required: false,
    ),
    const SkillParam(
      name: 'reminder_id',
      description: '要取消的提醒ID，action为cancel时需要',
      type: 'int',
      required: false,
    ),
  ];

  @override
  Future<SkillResult> execute(Map<String, dynamic> args) async {
    final action = args['action'] as String;

    switch (action) {
      case 'set':
        return _setReminder(args);
      case 'list':
        return _listReminders();
      case 'cancel':
        return _cancelReminder(args);
      default:
        return SkillResult.fail('不支持的操作: $action');
    }
  }

  SkillResult _setReminder(Map<String, dynamic> args) {
    final minutes = args['minutes'];
    if (minutes == null) {
      return SkillResult.fail('需要告诉鹅宝多少分钟后提醒呀~');
    }

    final mins = minutes is int ? minutes : int.tryParse(minutes.toString()) ?? 0;
    if (mins <= 0 || mins > 1440) {
      return SkillResult.fail('提醒时间应该在1分钟到24小时之间哦~');
    }

    final message = args['message'] as String? ?? '时间到啦！';
    final id = DateTime.now().millisecondsSinceEpoch;
    final triggerTime = DateTime.now().add(Duration(minutes: mins));

    final reminder = _Reminder(
      id: id,
      message: message,
      triggerTime: triggerTime,
    );

    _reminders.add(reminder);

    // 设置定时器
    final timer = Timer(Duration(minutes: mins), () {
      debugPrint('⏰ 鹅宝提醒: $message');
      _reminders.removeWhere((r) => r.id == id);
      onReminderTriggered?.call('⏰ 鹅宝提醒你: $message');
    });
    _timers.add(timer);

    return SkillResult.ok(
      '好的！鹅宝会在${mins}分钟后提醒你「$message」嘎~',
      data: {
        'reminder_id': id,
        'trigger_time': triggerTime.toIso8601String(),
        'message': message,
      },
    );
  }

  SkillResult _listReminders() {
    // 清除已过期的
    _reminders.removeWhere((r) => r.triggerTime.isBefore(DateTime.now()));

    if (_reminders.isEmpty) {
      return SkillResult.ok('目前没有待触发的提醒哦~');
    }

    final lines = _reminders.map((r) {
      final remaining = r.triggerTime.difference(DateTime.now());
      final mins = remaining.inMinutes;
      return '• [${r.id}] "${r.message}" - 还有${mins}分钟';
    }).join('\n');

    return SkillResult.ok(
      '当前有${_reminders.length}个提醒：\n$lines',
      data: {
        'count': _reminders.length,
        'reminders': _reminders.map((r) => <String, dynamic>{
            'id': r.id,
            'message': r.message,
            'triggerTime': r.triggerTime.toIso8601String(),
        }).toList(),
      },
    );
  }

  SkillResult _cancelReminder(Map<String, dynamic> args) {
    final reminderId = args['reminder_id'];
    if (reminderId == null) {
      return SkillResult.fail('需要告诉鹅宝要取消哪个提醒呀~ 用 list 先看看~');
    }

    final id = reminderId is int ? reminderId : int.tryParse(reminderId.toString());
    final index = _reminders.indexWhere((r) => r.id == id);

    if (index == -1) {
      return SkillResult.fail('没有找到这个提醒呢~');
    }

    _reminders.removeAt(index);
    return SkillResult.ok('提醒已取消啦~ 嘎~');
  }

  /// 清除所有提醒
  static void cancelAll() {
    for (final timer in _timers) {
      timer.cancel();
    }
    _timers.clear();
    _reminders.clear();
  }
}

class _Reminder {
  final int id;
  final String message;
  final DateTime triggerTime;

  _Reminder({required this.id, required this.message, required this.triggerTime});
}
