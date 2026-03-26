import 'package:flutter/foundation.dart';
import 'skill_base.dart';
import 'scheduled_task.dart';

/// 定时任务技能 - 让 AI 通过 function calling 创建/管理定时任务
///
/// 用户可以在对话中说"每天下午6点提醒我吃晚饭"，
/// AI 会解析意图后调用此技能创建定时任务。
class ScheduleTaskSkill extends GooseSkill {
  /// 定时任务管理器（由外部注入）
  ScheduledTaskManager? taskManager;

  @override
  String get id => 'schedule_task';

  @override
  String get name => '定时任务';

  @override
  String get description =>
      '创建、删除或列出定时任务。当用户请求设置提醒、定时执行某事时调用此工具。'
      '支持一次性、每天、每周、间隔执行四种模式。';

  @override
  String get icon => '⏰';

  @override
  String get category => '系统';

  @override
  List<SkillParam> get params => [
        const SkillParam(
          name: 'action',
          description: '操作类型：create（创建任务）、delete（删除任务）、list（列出所有任务）',
          type: 'enum',
          required: true,
          enumValues: ['create', 'delete', 'list'],
        ),
        const SkillParam(
          name: 'title',
          description: '任务标题，如"吃晚饭提醒"、"喝水提醒"。创建时必填',
          type: 'string',
          required: false,
        ),
        const SkillParam(
          name: 'prompt',
          description: '任务触发时鹅宝要说的话/执行的指令，如"主人，该吃晚饭啦！记得好好吃饭哦~"。创建时必填',
          type: 'string',
          required: false,
        ),
        const SkillParam(
          name: 'frequency_type',
          description: '频率类型：once（一次性）、daily（每天）、weekly（每周）、interval（间隔）。创建时必填',
          type: 'enum',
          required: false,
          enumValues: ['once', 'daily', 'weekly', 'interval'],
        ),
        const SkillParam(
          name: 'hour',
          description: '执行时间的小时（0-23），daily/weekly/once 模式必填。如 18 表示下午6点',
          type: 'int',
          required: false,
        ),
        const SkillParam(
          name: 'minute',
          description: '执行时间的分钟（0-59），daily/weekly/once 模式必填。如 30 表示半点',
          type: 'int',
          required: false,
          defaultValue: 0,
        ),
        const SkillParam(
          name: 'weekdays',
          description: '每周几执行（1=周一到7=周日），weekly 模式必填。如 "1,3,5" 表示周一三五',
          type: 'string',
          required: false,
        ),
        const SkillParam(
          name: 'interval_minutes',
          description: '间隔分钟数，interval 模式必填。如 60 表示每小时',
          type: 'int',
          required: false,
        ),
        const SkillParam(
          name: 'task_id',
          description: '要删除的任务ID，delete 操作必填',
          type: 'string',
          required: false,
        ),
      ];

  @override
  Future<SkillResult> execute(Map<String, dynamic> args, {void Function(String line)? onOutput}) async {
    if (taskManager == null) {
      return SkillResult.fail('定时任务管理器未初始化');
    }

    final action = args['action'] as String? ?? 'create';

    switch (action) {
      case 'create':
        return _createTask(args);
      case 'delete':
        return _deleteTask(args);
      case 'list':
        return _listTasks();
      default:
        return SkillResult.fail('不支持的操作: $action');
    }
  }

  /// 创建定时任务
  Future<SkillResult> _createTask(Map<String, dynamic> args) async {
    final title = args['title'] as String?;
    final prompt = args['prompt'] as String?;
    final frequencyType = args['frequency_type'] as String?;

    if (title == null || title.isEmpty) {
      return SkillResult.fail('请提供任务标题（title）');
    }
    if (prompt == null || prompt.isEmpty) {
      return SkillResult.fail('请提供任务触发时的提示内容（prompt）');
    }
    if (frequencyType == null) {
      return SkillResult.fail('请提供频率类型（frequency_type）');
    }

    // 解析时间参数
    final hour = _parseIntArg(args, 'hour');
    final minute = _parseIntArg(args, 'minute') ?? 0;

    TaskFrequency frequency;
    try {
      switch (frequencyType) {
        case 'once':
          if (hour == null) {
            return SkillResult.fail('一次性任务需要指定 hour（小时）');
          }
          final now = DateTime.now();
          var targetTime = DateTime(now.year, now.month, now.day, hour, minute);
          // 如果今天的时间已过，设为明天
          if (targetTime.isBefore(now)) {
            targetTime = targetTime.add(const Duration(days: 1));
          }
          frequency = TaskFrequency.once(targetTime);
          break;
        case 'daily':
          if (hour == null) {
            return SkillResult.fail('每天执行的任务需要指定 hour（小时）');
          }
          frequency = TaskFrequency.daily(hour, minute);
          break;
        case 'weekly':
          if (hour == null) {
            return SkillResult.fail('每周执行的任务需要指定 hour（小时）');
          }
          final weekdaysStr = args['weekdays'] as String?;
          if (weekdaysStr == null || weekdaysStr.isEmpty) {
            return SkillResult.fail('每周执行的任务需要指定 weekdays（周几）');
          }
          final weekdays = weekdaysStr.split(',')
              .map((s) => int.tryParse(s.trim()))
              .where((w) => w != null && w >= 1 && w <= 7)
              .cast<int>()
              .toList();
          if (weekdays.isEmpty) {
            return SkillResult.fail('weekdays 格式错误，应为 1-7 的数字用逗号分隔，如 "1,3,5"');
          }
          frequency = TaskFrequency.weekly(weekdays, hour, minute);
          break;
        case 'interval':
          final intervalMinutes = _parseIntArg(args, 'interval_minutes');
          if (intervalMinutes == null || intervalMinutes <= 0) {
            return SkillResult.fail('间隔模式需要指定 interval_minutes（间隔分钟数，>0）');
          }
          frequency = TaskFrequency.interval(intervalMinutes);
          break;
        default:
          return SkillResult.fail('不支持的频率类型: $frequencyType。支持：once, daily, weekly, interval');
      }
    } catch (e) {
      return SkillResult.fail('解析任务参数失败: $e');
    }

    // 创建任务
    final taskId = 'task_${DateTime.now().millisecondsSinceEpoch}';
    final task = ScheduledTask(
      id: taskId,
      title: title,
      description: '由对话创建',
      frequency: frequency,
      enabled: true,
      prompt: prompt,
    );

    try {
      await taskManager!.addTask(task);
      debugPrint('⏰ 定时任务已创建: $title (${frequency.displayText})');
      return SkillResult.ok(
        '✅ 定时任务已创建！\n'
        '📋 标题: $title\n'
        '⏰ 频率: ${frequency.displayText}\n'
        '💬 内容: $prompt\n'
        '🆔 ID: $taskId',
        data: {'taskId': taskId, 'title': title, 'frequency': frequency.displayText},
      );
    } catch (e) {
      return SkillResult.fail('创建定时任务失败: $e');
    }
  }

  /// 删除定时任务
  Future<SkillResult> _deleteTask(Map<String, dynamic> args) async {
    final taskId = args['task_id'] as String?;
    if (taskId == null || taskId.isEmpty) {
      // 如果没有提供 ID，尝试按标题匹配
      final title = args['title'] as String?;
      if (title != null && title.isNotEmpty) {
        final matchTask = taskManager!.tasks.firstWhere(
          (t) => t.title.contains(title) || title.contains(t.title),
          orElse: () => ScheduledTask(
            id: '', title: '', frequency: TaskFrequency.daily(0, 0), prompt: '',
          ),
        );
        if (matchTask.id.isNotEmpty) {
          await taskManager!.deleteTask(matchTask.id);
          return SkillResult.ok('✅ 已删除定时任务: ${matchTask.title}');
        }
        return SkillResult.fail('未找到标题包含"$title"的定时任务');
      }
      return SkillResult.fail('请提供要删除的任务 ID（task_id）或标题（title）');
    }

    final exists = taskManager!.tasks.any((t) => t.id == taskId);
    if (!exists) {
      return SkillResult.fail('未找到 ID 为 "$taskId" 的定时任务');
    }

    await taskManager!.deleteTask(taskId);
    return SkillResult.ok('✅ 已删除定时任务 (ID: $taskId)');
  }

  /// 列出所有定时任务
  Future<SkillResult> _listTasks() async {
    final tasks = taskManager!.tasks;
    if (tasks.isEmpty) {
      return SkillResult.ok('📋 当前没有任何定时任务。');
    }

    final sb = StringBuffer();
    sb.writeln('📋 当前定时任务列表（共 ${tasks.length} 个）：\n');
    for (final task in tasks) {
      final status = task.enabled ? '✅启用' : '⏸️暂停';
      sb.writeln('• **${task.title}** [$status]');
      sb.writeln('  频率: ${task.frequency.displayText}');
      sb.writeln('  内容: ${task.prompt}');
      sb.writeln('  ID: ${task.id}');
      if (task.nextRun != null) {
        sb.writeln('  下次执行: ${_formatDateTime(task.nextRun!)}');
      }
      sb.writeln();
    }

    return SkillResult.ok(sb.toString());
  }

  /// 解析整数参数（兼容 String 和 int/double 类型）
  int? _parseIntArg(Map<String, dynamic> args, String key) {
    final value = args[key];
    if (value == null) return null;
    if (value is int) return value;
    if (value is double) return value.toInt();
    if (value is String) return int.tryParse(value);
    return null;
  }

  /// 格式化日期时间
  String _formatDateTime(DateTime dt) {
    return '${dt.year}-${dt.month.toString().padLeft(2, '0')}-${dt.day.toString().padLeft(2, '0')} '
        '${dt.hour.toString().padLeft(2, '0')}:${dt.minute.toString().padLeft(2, '0')}';
  }
}
