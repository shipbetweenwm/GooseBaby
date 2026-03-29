/// CUA 操作录制与任务持久化
///
/// 记录每次 CUA 操作的完整信息（动作、参数、截图、结果），
/// 支持序列化到本地文件、断点续作、时间线回放。
library;

import 'dart:convert';
import 'dart:io';
import 'package:flutter/foundation.dart';
import 'package:path/path.dart' as p;
import 'skill_file_utils.dart';

/// 单次 CUA 操作记录
class CuaOperationRecord {
  final int timestamp;
  final String action;
  final Map<String, dynamic> args;
  final bool success;
  final String result;
  final String? screenshotPath;
  final String? thumbnailBase64;
  final String? error;
  final int durationMs;

  const CuaOperationRecord({
    required this.timestamp,
    required this.action,
    required this.args,
    required this.success,
    required this.result,
    this.screenshotPath,
    this.thumbnailBase64,
    this.error,
    this.durationMs = 0,
  });

  Map<String, dynamic> toJson() => {
    'timestamp': timestamp,
    'action': action,
    'args': args,
    'success': success,
    'result': result,
    if (screenshotPath != null) 'screenshotPath': screenshotPath,
    if (thumbnailBase64 != null && thumbnailBase64!.length < 50000)
      'thumbnailBase64': thumbnailBase64,
    if (error != null) 'error': error,
    'durationMs': durationMs,
  };

  factory CuaOperationRecord.fromJson(Map<String, dynamic> json) =>
      CuaOperationRecord(
        timestamp: json['timestamp'] as int? ?? 0,
        action: json['action'] as String? ?? '',
        args: (json['args'] as Map<String, dynamic>?) ?? {},
        success: json['success'] as bool? ?? false,
        result: json['result'] as String? ?? '',
        screenshotPath: json['screenshotPath'] as String?,
        thumbnailBase64: json['thumbnailBase64'] as String?,
        error: json['error'] as String?,
        durationMs: json['durationMs'] as int? ?? 0,
      );

  /// 操作的中文描述
  String get displayTitle {
    const titleMap = {
      'screenshot': '📸 截图',
      'mouse_click': '🖱️ 点击',
      'mouse_move': '🖱️ 移动',
      'mouse_scroll': '🖱️ 滚动',
      'mouse_drag': '🖱️ 拖拽',
      'key_type': '⌨️ 输入',
      'key_combo': '⌨️ 快捷键',
      'open_app': '🚀 打开应用',
      'get_ui_tree': '🌳 UI 树',
      'cua_plan': '📋 规划',
    };
    return titleMap[action] ?? '⚙️ $action';
  }

  /// 操作的简要描述（用于时间线）
  String get displayDesc {
    switch (action) {
      case 'mouse_click':
        final x = args['x'];
        final y = args['y'];
        return '($x, $y) ${args['button'] ?? 'left'}';
      case 'key_type':
        final text = args['text'] as String? ?? '';
        return text.length > 30 ? '${text.substring(0, 30)}...' : text;
      case 'key_combo':
        return args['keys'] as String? ?? '';
      case 'open_app':
        return args['app_name'] as String? ?? '';
      case 'mouse_scroll':
        return '(${args['x']}, ${args['y']}) Δ(${args['scroll_x']}, ${args['scroll_y']})';
      default:
        return '';
    }
  }
}

/// CUA 子任务（Planner 分解出的步骤）
class CuaSubTask {
  final String id;
  final int order;
  String description;
  String status; // pending, running, completed, failed, skipped
  String? result;
  int? startOperationIndex; // 该子任务对应的起始操作索引
  int? endOperationIndex;   // 该子任务对应的结束操作索引

  CuaSubTask({
    required this.id,
    required this.order,
    required this.description,
    this.status = 'pending',
    this.result,
    this.startOperationIndex,
    this.endOperationIndex,
  });

  Map<String, dynamic> toJson() => {
    'id': id,
    'order': order,
    'description': description,
    'status': status,
    if (result != null) 'result': result,
    if (startOperationIndex != null) 'startOperationIndex': startOperationIndex,
    if (endOperationIndex != null) 'endOperationIndex': endOperationIndex,
  };

  factory CuaSubTask.fromJson(Map<String, dynamic> json) => CuaSubTask(
    id: json['id'] as String? ?? '',
    order: json['order'] as int? ?? 0,
    description: json['description'] as String? ?? '',
    status: json['status'] as String? ?? 'pending',
    result: json['result'] as String?,
    startOperationIndex: json['startOperationIndex'] as int?,
    endOperationIndex: json['endOperationIndex'] as int?,
  );

  /// 获取属于该子任务的操作列表
  List<CuaOperationRecord> getOperations(List<CuaOperationRecord> allOps) {
    if (startOperationIndex == null) return [];
    final end = (endOperationIndex ?? allOps.length);
    return allOps.sublist(startOperationIndex!, end.clamp(0, allOps.length));
  }

  /// 操作数
  int get operationCount {
    if (startOperationIndex != null && endOperationIndex != null) {
      return (endOperationIndex! - startOperationIndex!).clamp(0, 9999);
    }
    return 0;
  }
}

/// CUA 任务（一次完整的 CUA 会话）
class CuaTask {
  final String taskId;
  final String description;
  final List<CuaOperationRecord> operations;
  final List<CuaSubTask> subTasks;
  final DateTime startTime;
  DateTime? endTime;
  String status; // running, completed, failed, paused

  CuaTask({
    required this.taskId,
    required this.description,
    List<CuaOperationRecord>? operations,
    List<CuaSubTask>? subTasks,
    DateTime? startTime,
    this.endTime,
    this.status = 'running',
  })  : operations = operations ?? [],
        subTasks = subTasks ?? [],
        startTime = startTime ?? DateTime.now();

  int get operationCount => operations.length;
  int get successCount => operations.where((o) => o.success).length;
  int get failCount => operations.where((o) => !o.success).length;
  Duration get duration =>
      (endTime ?? DateTime.now()).difference(startTime);

  /// 当前活跃的子任务
  CuaSubTask? get activeSubTask {
    for (final t in subTasks) {
      if (t.status == 'running') return t;
    }
    return null;
  }

  /// 子任务完成进度
  double get subTaskProgress {
    if (subTasks.isEmpty) return 1.0;
    final completed = subTasks.where((t) => t.status == 'completed' || t.status == 'skipped').length;
    return completed / subTasks.length;
  }

  Map<String, dynamic> toJson() => {
    'taskId': taskId,
    'description': description,
    'operations': operations.map((o) => o.toJson()).toList(),
    if (subTasks.isNotEmpty) 'subTasks': subTasks.map((t) => t.toJson()).toList(),
    'startTime': startTime.millisecondsSinceEpoch,
    'endTime': endTime?.millisecondsSinceEpoch,
    'status': status,
  };

  factory CuaTask.fromJson(Map<String, dynamic> json) => CuaTask(
    taskId: json['taskId'] as String? ?? '',
    description: json['description'] as String? ?? '',
    operations: (json['operations'] as List?)
            ?.map((o) => CuaOperationRecord.fromJson(o as Map<String, dynamic>))
            .toList() ??
        [],
    subTasks: (json['subTasks'] as List?)
            ?.map((t) => CuaSubTask.fromJson(t as Map<String, dynamic>))
            .toList() ??
        [],
    startTime: json['startTime'] != null
        ? DateTime.fromMillisecondsSinceEpoch(json['startTime'] as int)
        : null,
    endTime: json['endTime'] != null
        ? DateTime.fromMillisecondsSinceEpoch(json['endTime'] as int)
        : null,
    status: json['status'] as String? ?? 'running',
  );
}

/// CUA 任务录制器 - 管理任务的记录、保存、恢复
class CuaTaskRecorder {
  CuaTaskRecorder();

  /// CUA 任务存储目录
  static String get _taskDir =>
      p.join(SkillFileUtils.effectiveWorkingDir, '.cua_tasks');

  /// 确保存储目录存在
  static Future<void> _ensureDir() async {
    final dir = Directory(_taskDir);
    if (!await dir.exists()) {
      await dir.create(recursive: true);
    }
  }

  /// 创建新任务
  static CuaTask createTask(String description) {
    final taskId = 'cua_${DateTime.now().millisecondsSinceEpoch}';
    return CuaTask(taskId: taskId, description: description);
  }

  /// 记录一次操作
  static void recordOperation(CuaTask task, CuaOperationRecord record) {
    task.operations.add(record);
  }

  /// 保存任务到本地
  static Future<void> saveTask(CuaTask task) async {
    await _ensureDir();
    final filePath = p.join(_taskDir, '${task.taskId}.json');
    final jsonStr = const JsonEncoder.withIndent('  ').convert(task.toJson());
    await File(filePath).writeAsString(jsonStr);
    debugPrint('💾 CUA 任务已保存: ${task.taskId} (${task.operationCount} 步操作)');
  }

  /// 加载任务
  static Future<CuaTask?> loadTask(String taskId) async {
    final filePath = p.join(_taskDir, '$taskId.json');
    final file = File(filePath);
    if (!await file.exists()) return null;

    try {
      final content = await file.readAsString();
      final data = jsonDecode(content) as Map<String, dynamic>;
      return CuaTask.fromJson(data);
    } catch (e) {
      debugPrint('⚠️ 加载 CUA 任务失败: $e');
      return null;
    }
  }

  /// 列出所有已保存的任务
  static Future<List<CuaTask>> listTasks({int limit = 20}) async {
    await _ensureDir();
    final dir = Directory(_taskDir);
    if (!await dir.exists()) return [];

    final files = await dir
        .list()
        .where((e) => e is File && e.path.endsWith('.json'))
        .toList();

    // 按修改时间倒序
    files.sort((a, b) =>
        b.statSync().modified.compareTo(a.statSync().modified));

    final tasks = <CuaTask>[];
    for (final file in files.take(limit)) {
      try {
        final content = await (file as File).readAsString();
        final data = jsonDecode(content) as Map<String, dynamic>;
        tasks.add(CuaTask.fromJson(data));
      } catch (_) {}
    }
    return tasks;
  }

  /// 导出任务为 Markdown 报告
  static String exportToMarkdown(CuaTask task) {
    final buffer = StringBuffer();
    buffer.writeln('# CUA 操作报告');
    buffer.writeln();
    buffer.writeln('**任务**: ${task.description}');
    buffer.writeln('**开始时间**: ${task.startTime}');
    buffer.writeln('**状态**: ${task.status}');
    buffer.writeln('**总操作数**: ${task.operationCount}');
    buffer.writeln('**成功/失败**: ${task.successCount}/${task.failCount}');
    buffer.writeln('**耗时**: ${task.duration.inSeconds}秒');
    buffer.writeln();
    buffer.writeln('## 操作时间线');
    buffer.writeln();

    for (var i = 0; i < task.operations.length; i++) {
      final op = task.operations[i];
      final time = DateTime.fromMillisecondsSinceEpoch(op.timestamp);
      final status = op.success ? '✅' : '❌';
      buffer.writeln('### $status ${i + 1}. ${op.displayTitle}');
      buffer.writeln();
      if (op.displayDesc.isNotEmpty) {
        buffer.writeln('- **参数**: ${op.displayDesc}');
      }
      buffer.writeln('- **时间**: $time');
      if (op.durationMs > 0) {
        buffer.writeln('- **耗时**: ${op.durationMs}ms');
      }
      buffer.writeln('- **结果**: ${op.result.length > 200 ? '${op.result.substring(0, 200)}...' : op.result}');
      if (op.error != null) {
        buffer.writeln('- **错误**: ${op.error}');
      }
      buffer.writeln();
    }

    return buffer.toString();
  }

  /// 删除旧任务（保留最近 N 个）
  static Future<void> cleanupOldTasks({int keepCount = 50}) async {
    final tasks = await listTasks(limit: 1000);
    if (tasks.length <= keepCount) return;

    final toDelete = tasks.skip(keepCount);
    for (final task in toDelete) {
      final filePath = p.join(_taskDir, '${task.taskId}.json');
      try {
        await File(filePath).delete();
      } catch (_) {}
    }
    debugPrint('🧹 CUA 清理了 ${toDelete.length} 个旧任务');
  }

  /// 获取当前运行中任务的摘要（用于 LLM 上下文注入）
  static String buildResumeContext(CuaTask task) {
    if (task.operations.isEmpty) return '';

    final buffer = StringBuffer();
    buffer.writeln('📋 【CUA 任务恢复】以下是之前中断的任务已完成的操作：');
    buffer.writeln('任务: ${task.description}');
    buffer.writeln('已完成 ${task.operationCount} 步操作：');
    buffer.writeln();

    for (var i = 0; i < task.operations.length; i++) {
      final op = task.operations[i];
      final status = op.success ? '✅' : '❌';
      buffer.writeln(
        '$status ${i + 1}. ${op.displayTitle} ${op.displayDesc.isNotEmpty ? '- ${op.displayDesc}' : ''}',
      );
    }

    buffer.writeln();
    buffer.writeln('请基于以上已完成的操作，继续执行未完成的部分。');
    return buffer.toString();
  }
}
