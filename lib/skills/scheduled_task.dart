import 'dart:async';
import 'dart:convert';
import 'package:flutter/material.dart';
import 'package:hive/hive.dart';
import '../utils/type_utils.dart';
import 'skill_base.dart';

/// 定时任务
class ScheduledTask {
  final String id;
  String title;
  String description;
  TaskFrequency frequency;
  DateTime? nextRun;
  DateTime? lastRun;
  bool enabled;
  String prompt; // 要执行的 prompt（当 skillId 为空时使用）
  String? skillId; // 可选：直接执行的技能 ID
  String? skillArgsJson; // 可选：技能参数（JSON 字符串）

  ScheduledTask({
    required this.id,
    required this.title,
    this.description = '',
    required this.frequency,
    this.nextRun,
    this.lastRun,
    this.enabled = true,
    required this.prompt,
    this.skillId,
    this.skillArgsJson,
  });

  Map<String, dynamic> toJson() => {
        'id': id,
        'title': title,
        'description': description,
        'frequency': frequency.toJson(),
        'nextRun': nextRun?.toIso8601String(),
        'lastRun': lastRun?.toIso8601String(),
        'enabled': enabled,
        'prompt': prompt,
        if (skillId != null) 'skillId': skillId,
        if (skillArgsJson != null) 'skillArgsJson': skillArgsJson,
      };

  factory ScheduledTask.fromJson(Map<String, dynamic> json) => ScheduledTask(
        id: json['id'] as String,
        title: json['title'] as String,
        description: json['description'] as String? ?? '',
        frequency: TaskFrequency.fromJson(Map<String, dynamic>.from(json['frequency'])),
        nextRun: json['nextRun'] != null ? DateTime.parse(json['nextRun'] as String) : null,
        lastRun: json['lastRun'] != null ? DateTime.parse(json['lastRun'] as String) : null,
        enabled: json['enabled'] as bool? ?? true,
        prompt: json['prompt'] as String? ?? '',
        skillId: json['skillId'] as String?,
        skillArgsJson: json['skillArgsJson'] as String?,
      );

  /// 计算下一次运行时间
  DateTime calculateNextRun() {
    final now = DateTime.now();
    switch (frequency.type) {
      case FrequencyType.once:
        return frequency.specificTime ?? now;
      case FrequencyType.daily:
        var next = DateTime(now.year, now.month, now.day, frequency.hour!, frequency.minute!);
        if (next.isBefore(now)) {
          next = next.add(const Duration(days: 1));
        }
        return next;
      case FrequencyType.weekly:
        var next = _getNextWeekday(now, frequency.weekdays!);
        next = DateTime(next.year, next.month, next.day, frequency.hour!, frequency.minute!);
        if (next.isBefore(now)) {
          next = _getNextWeekday(next.add(const Duration(days: 1)), frequency.weekdays!);
          next = DateTime(next.year, next.month, next.day, frequency.hour!, frequency.minute!);
        }
        return next;
      case FrequencyType.interval:
        return now.add(Duration(minutes: frequency.intervalMinutes!));
    }
  }

  /// 获取下一个指定星期几的日期
  DateTime _getNextWeekday(DateTime from, List<int> weekdays) {
    for (var i = 0; i < 7; i++) {
      final candidate = from.add(Duration(days: i));
      if (weekdays.contains(candidate.weekday)) {
        return candidate;
      }
    }
    return from;
  }
}

/// 任务频率
class TaskFrequency {
  final FrequencyType type;
  final DateTime? specificTime; // once: 具体时间
  final int? hour; // daily/weekly: 小时
  final int? minute; // daily/weekly: 分钟
  final List<int>? weekdays; // weekly: 星期几 (1=周一, 7=周日)
  final int? intervalMinutes; // interval: 间隔分钟数

  TaskFrequency.once(this.specificTime)
      : type = FrequencyType.once,
        hour = null,
        minute = null,
        weekdays = null,
        intervalMinutes = null;

  TaskFrequency.daily(this.hour, this.minute)
      : type = FrequencyType.daily,
        specificTime = null,
        weekdays = null,
        intervalMinutes = null;

  TaskFrequency.weekly(this.weekdays, this.hour, this.minute)
      : type = FrequencyType.weekly,
        specificTime = null,
        intervalMinutes = null;

  TaskFrequency.interval(this.intervalMinutes)
      : type = FrequencyType.interval,
        specificTime = null,
        hour = null,
        minute = null,
        weekdays = null;

  Map<String, dynamic> toJson() => {
        'type': type.toString(),
        'specificTime': specificTime?.toIso8601String(),
        'hour': hour,
        'minute': minute,
        'weekdays': weekdays,
        'intervalMinutes': intervalMinutes,
      };

  factory TaskFrequency.fromJson(Map<String, dynamic> json) {
    final type = FrequencyType.values.firstWhere(
      (e) => e.toString() == json['type'],
      orElse: () => FrequencyType.daily,
    );
    switch (type) {
      case FrequencyType.once:
        return TaskFrequency.once(
          json['specificTime'] != null ? DateTime.parse(json['specificTime'] as String) : null,
        );
      case FrequencyType.daily:
        return TaskFrequency.daily(json['hour'] as int, json['minute'] as int);
      case FrequencyType.weekly:
        return TaskFrequency.weekly(
          (json['weekdays'] as List).cast<int>(),
          json['hour'] as int,
          json['minute'] as int,
        );
      case FrequencyType.interval:
        return TaskFrequency.interval(json['intervalMinutes'] as int);
    }
  }

  String get displayText {
    switch (type) {
      case FrequencyType.once:
        if (specificTime == null) return '一次性任务';
        return '${specificTime!.month}/${specificTime!.day} ${_formatTime(specificTime!.hour, specificTime!.minute)}';
      case FrequencyType.daily:
        return '每天 ${_formatTime(hour!, minute!)}';
      case FrequencyType.weekly:
        final days = weekdays!.map((w) => _weekdayName(w)).join('、');
        return '每周$days ${_formatTime(hour!, minute!)}';
      case FrequencyType.interval:
        if (intervalMinutes! < 60) {
          return '每 $intervalMinutes 分钟';
        } else {
          final hours = intervalMinutes! ~/ 60;
          final mins = intervalMinutes! % 60;
          return mins > 0 ? '每 $hours 小时 $mins 分钟' : '每 $hours 小时';
        }
    }
  }

  String _formatTime(int h, int m) => '${h.toString().padLeft(2, '0')}:${m.toString().padLeft(2, '0')}';

  String _weekdayName(int w) {
    const names = ['周一', '周二', '周三', '周四', '周五', '周六', '周日'];
    return names[w - 1];
  }
}

enum FrequencyType {
  once, // 一次性
  daily, // 每天
  weekly, // 每周
  interval, // 间隔
}

/// 定时任务管理器
class ScheduledTaskManager extends ChangeNotifier {
  static const String _boxName = 'scheduled_tasks';

  late Box _box;
  final List<ScheduledTask> _tasks = [];
  Timer? _checkTimer;
  
  /// Prompt 执行回调（由外部设置，用于执行定时任务的 prompt）
  Function(String prompt, String taskTitle)? onExecutePrompt;

  /// 技能执行回调（由外部设置，用于直接执行定时任务绑定的技能）
  Future<SkillResult> Function(String skillId, Map<String, dynamic> args)? onExecuteSkill;

  List<ScheduledTask> get tasks => _tasks;
  List<ScheduledTask> get enabledTasks => _tasks.where((t) => t.enabled).toList();

  Future<void> initialize() async {
    _box = await Hive.openBox(_boxName);
    await _loadTasks();
    _startTimer();
  }

  Future<void> _loadTasks() async {
    try {
      final data = _box.get('tasks', defaultValue: <dynamic>[]);
      if (data is List && data.isNotEmpty) {
        _tasks.clear();
        _tasks.addAll(
          data.map((item) => ScheduledTask.fromJson(Map<String, dynamic>.from(item))).toList(),
        );
      }
      notifyListeners();
    } catch (e) {
      debugPrint('🦢 加载定时任务失败: $e');
    }
  }

  Future<void> _saveTasks() async {
    try {
      await _box.put('tasks', _tasks.map((t) => t.toJson()).toList());
      notifyListeners();
    } catch (e) {
      debugPrint('🦢 保存定时任务失败: $e');
    }
  }

  /// 添加任务
  Future<void> addTask(ScheduledTask task) async {
    task.nextRun = task.calculateNextRun();
    _tasks.add(task);
    await _saveTasks();
  }

  /// 更新任务
  Future<void> updateTask(ScheduledTask task) async {
    final index = _tasks.indexWhere((t) => t.id == task.id);
    if (index != -1) {
      task.nextRun = task.calculateNextRun();
      _tasks[index] = task;
      await _saveTasks();
    }
  }

  /// 删除任务
  Future<void> deleteTask(String id) async {
    _tasks.removeWhere((t) => t.id == id);
    await _saveTasks();
  }

  /// 启用/禁用任务
  Future<void> toggleTask(String id) async {
    final task = _tasks.firstWhere((t) => t.id == id);
    task.enabled = !task.enabled;
    if (task.enabled) {
      task.nextRun = task.calculateNextRun();
    }
    await _saveTasks();
  }

  /// 启动定时检查
  void _startTimer() {
    _checkTimer?.cancel();
    // 每分钟检查一次
    _checkTimer = Timer.periodic(const Duration(minutes: 1), (timer) {
      _checkAndExecuteTasks();
    });
  }

  /// 检查并执行到期任务
  Future<void> _checkAndExecuteTasks() async {
    final now = DateTime.now();
    for (final task in enabledTasks) {
      if (task.nextRun != null && task.nextRun!.isBefore(now)) {
        // 执行任务
        await _executeTask(task);
        
        // 更新下次运行时间
        task.lastRun = now;
        if (task.frequency.type == FrequencyType.once) {
          task.enabled = false; // 一次性任务执行后禁用
        }
        task.nextRun = task.calculateNextRun();
        await _saveTasks();
      }
    }
  }

  /// 执行任务
  Future<void> _executeTask(ScheduledTask task) async {
    debugPrint('🦢 执行定时任务: ${task.title}');

    // 优先执行绑定的技能
    if (task.skillId != null && task.skillId!.isNotEmpty && onExecuteSkill != null) {
      try {
        Map<String, dynamic> skillArgs = {};
        if (task.skillArgsJson != null && task.skillArgsJson!.isNotEmpty) {
          skillArgs = safeMap(jsonDecode(task.skillArgsJson!));
        }
        final result = await onExecuteSkill!(task.skillId!, skillArgs);
        debugPrint('🦢 定时任务技能执行: ${task.title} -> ${result.success ? "✅" : "❌"}');
      } catch (e) {
        debugPrint('🦢 定时任务技能执行失败: $e');
      }
      notifyListeners();
      return;
    }

    // 回退到 prompt 模式
    if (onExecutePrompt == null) {
      debugPrint('🦢 Prompt 执行回调未设置');
      return;
    }

    if (task.prompt.trim().isEmpty) {
      debugPrint('🦢 任务未设置 prompt');
      return;
    }

    try {
      onExecutePrompt!(task.prompt, task.title);
      debugPrint('🦢 定时任务执行成功: ${task.title}');
    } catch (e) {
      debugPrint('🦢 定时任务执行失败: $e');
    }

    // 通知监听器
    notifyListeners();
  }

  @override
  void dispose() {
    _checkTimer?.cancel();
    super.dispose();
  }
}
