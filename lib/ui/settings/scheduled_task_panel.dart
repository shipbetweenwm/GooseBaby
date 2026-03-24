import 'dart:async';
import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import '../../skills/scheduled_task.dart';

/// 定时任务配置面板
class ScheduledTaskPanel extends StatefulWidget {
  final VoidCallback? onClose;

  const ScheduledTaskPanel({super.key, this.onClose});

  @override
  State<ScheduledTaskPanel> createState() => _ScheduledTaskPanelState();
}

class _ScheduledTaskPanelState extends State<ScheduledTaskPanel> {
  ScheduledTask? _editingTask; // 正在编辑的任务（null表示新建）
  bool _showEditDialog = false;
  bool _showDeleteDialog = false;
  String? _deletingTaskId;

  @override
  Widget build(BuildContext context) {
    final taskManager = context.watch<ScheduledTaskManager>();

    return Stack(
      children: [
        Container(
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: const BorderRadius.only(
          topRight: Radius.circular(16),
          bottomRight: Radius.circular(16),
        ),
        boxShadow: [
          BoxShadow(
            color: Colors.black.withOpacity(0.1),
            blurRadius: 10,
            offset: const Offset(2, 0),
          ),
        ],
      ),
      child: Column(
        children: [
          // 标题栏
          Container(
            padding: const EdgeInsets.fromLTRB(20, 16, 12, 12),
            decoration: const BoxDecoration(
              border: Border(bottom: BorderSide(color: Color(0xFFE0E0E0), width: 0.5)),
            ),
            child: Row(
              children: [
                const Text(
                  '⏰ 定时任务',
                  style: TextStyle(fontSize: 18, fontWeight: FontWeight.bold),
                ),
                const Spacer(),
                IconButton(
                  icon: const Icon(Icons.add, size: 20),
                  onPressed: () => _showAddTaskDialog(context),
                  tooltip: '新建任务',
                ),
                IconButton(
                  icon: const Icon(Icons.close, size: 18),
                  onPressed: widget.onClose,
                  padding: EdgeInsets.zero,
                  constraints: const BoxConstraints(),
                ),
              ],
            ),
          ),
          // 任务列表
          Expanded(
            child: taskManager.tasks.isEmpty
                ? Center(
                    child: Column(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Icon(Icons.schedule, size: 48, color: Colors.grey.shade300),
                        const SizedBox(height: 12),
                        Text(
                          '还没有定时任务',
                          style: TextStyle(color: Colors.grey.shade500, fontSize: 14),
                        ),
                        const SizedBox(height: 8),
                        TextButton.icon(
                          icon: const Icon(Icons.add, size: 16),
                          label: const Text('创建任务'),
                          onPressed: () => _showAddTaskDialog(context),
                        ),
                      ],
                    ),
                  )
                : ListView.builder(
                    padding: const EdgeInsets.symmetric(vertical: 8, horizontal: 16),
                    itemCount: taskManager.tasks.length,
                    itemBuilder: (context, index) {
                      final task = taskManager.tasks[index];
                      return _TaskItem(
                        task: task,
                        onToggle: () => taskManager.toggleTask(task.id),
                        onEdit: () => _showEditTaskDialog(context, task),
                        onDelete: () => _deleteTask(context, task.id),
                      );
                    },
                  ),
          ),
        ],
      ),
        ),
        
        // 对话框叠加层
        if (_showEditDialog)
          _TaskEditDialog(
            task: _editingTask,
            onSave: (task) {
              if (_editingTask == null) {
                context.read<ScheduledTaskManager>().addTask(task);
              } else {
                context.read<ScheduledTaskManager>().updateTask(task);
              }
              setState(() {
                _showEditDialog = false;
                _editingTask = null;
              });
            },
            onCancel: () {
              setState(() {
                _showEditDialog = false;
                _editingTask = null;
              });
            },
          ),
        
        // 删除确认对话框
        if (_showDeleteDialog && _deletingTaskId != null)
          Align(
            alignment: Alignment.center,
            child: Container(
              margin: const EdgeInsets.all(40),
              padding: const EdgeInsets.all(20),
              decoration: BoxDecoration(
                color: Colors.white,
                borderRadius: BorderRadius.circular(16),
                boxShadow: [
                  BoxShadow(
                    color: Colors.black.withOpacity(0.2),
                    blurRadius: 20,
                    offset: const Offset(0, 8),
                  ),
                ],
              ),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  const Text(
                    '删除任务',
                    style: TextStyle(fontSize: 18, fontWeight: FontWeight.bold),
                  ),
                  const SizedBox(height: 16),
                  const Text('确定要删除这个任务吗？'),
                  const SizedBox(height: 20),
                  Row(
                    mainAxisAlignment: MainAxisAlignment.end,
                    children: [
                      TextButton(
                        onPressed: () {
                          setState(() {
                            _showDeleteDialog = false;
                            _deletingTaskId = null;
                          });
                        },
                        child: const Text('取消'),
                      ),
                      const SizedBox(width: 8),
                      TextButton(
                        onPressed: () {
                          context.read<ScheduledTaskManager>().deleteTask(_deletingTaskId!);
                          setState(() {
                            _showDeleteDialog = false;
                            _deletingTaskId = null;
                          });
                        },
                        child: const Text('删除', style: TextStyle(color: Colors.red)),
                      ),
                    ],
                  ),
                ],
              ),
            ),
          ),
      ],
    );
  }

  void _showAddTaskDialog(BuildContext context) {
    setState(() {
      _editingTask = null;
      _showEditDialog = true;
    });
  }

  void _showEditTaskDialog(BuildContext context, ScheduledTask task) {
    setState(() {
      _editingTask = task;
      _showEditDialog = true;
    });
  }

  void _deleteTask(BuildContext context, String id) {
    setState(() {
      _deletingTaskId = id;
      _showDeleteDialog = true;
    });
  }
}

/// 任务列表项
class _TaskItem extends StatefulWidget {
  final ScheduledTask task;
  final VoidCallback onToggle;
  final VoidCallback onEdit;
  final VoidCallback onDelete;

  const _TaskItem({
    required this.task,
    required this.onToggle,
    required this.onEdit,
    required this.onDelete,
  });

  @override
  State<_TaskItem> createState() => _TaskItemState();
}

class _TaskItemState extends State<_TaskItem> {
  late Timer _countdownTimer;

  @override
  void initState() {
    super.initState();
    // 每分钟刷新倒计时
    _countdownTimer = Timer.periodic(const Duration(minutes: 1), (_) {
      if (mounted) setState(() {});
    });
  }

  @override
  void dispose() {
    _countdownTimer.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final task = widget.task;
    return Card(
      margin: const EdgeInsets.only(bottom: 12),
      elevation: 1,
      child: InkWell(
        onTap: widget.onEdit,
        borderRadius: BorderRadius.circular(8),
        child: Padding(
          padding: const EdgeInsets.all(12),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                children: [
                  Switch(
                    value: task.enabled,
                    onChanged: (_) => widget.onToggle(),
                    materialTapTargetSize: MaterialTapTargetSize.shrinkWrap,
                  ),
                  const SizedBox(width: 8),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          task.title,
                          style: TextStyle(
                            fontSize: 15,
                            fontWeight: FontWeight.w600,
                            color: task.enabled ? Colors.black87 : Colors.grey,
                          ),
                        ),
                        if (task.description.isNotEmpty)
                          Padding(
                            padding: const EdgeInsets.only(top: 2),
                            child: Text(
                              task.description,
                              style: TextStyle(fontSize: 12, color: Colors.grey.shade600),
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                            ),
                          ),
                      ],
                    ),
                  ),
                  IconButton(
                    icon: const Icon(Icons.delete_outline, size: 18),
                    onPressed: widget.onDelete,
                    color: Colors.grey.shade400,
                    padding: EdgeInsets.zero,
                    constraints: const BoxConstraints(),
                  ),
                ],
              ),
              const SizedBox(height: 8),
              Row(
                children: [
                  Icon(Icons.schedule, size: 14, color: Colors.grey.shade600),
                  const SizedBox(width: 4),
                  Text(
                    task.frequency.displayText,
                    style: TextStyle(fontSize: 12, color: Colors.grey.shade700),
                  ),
                  const SizedBox(width: 16),
                  if (task.nextRun != null)
                    Icon(
                      Icons.access_time,
                      size: 14,
                      color: task.enabled ? const Color(0xFF4FC3F7) : Colors.grey.shade600,
                    ),
                  if (task.nextRun != null) ...[
                    const SizedBox(width: 4),
                    Text(
                      task.enabled
                          ? _formatCountdown(task.nextRun!)
                          : '已暂停',
                      style: TextStyle(
                        fontSize: 12,
                        color: task.enabled ? const Color(0xFF0288D1) : Colors.grey.shade700,
                        fontWeight: task.enabled ? FontWeight.w500 : FontWeight.normal,
                      ),
                    ),
                  ],
                ],
              ),
            ],
          ),
        ),
      ),
    );
  }

  /// 格式化倒计时：X小时X分钟后 / X分钟后 / 已过期
  String _formatCountdown(DateTime nextRun) {
    final now = DateTime.now();
    final diff = nextRun.difference(now);

    if (diff.isNegative) return '即将执行';

    final hours = diff.inHours;
    final minutes = diff.inMinutes % 60;

    if (hours >= 24) {
      return '今天执行';
    }

    if (hours > 0) {
      return minutes > 0 ? '$hours小时$minutes分钟后' : '$hours小时后';
    }

    return '$minutes分钟后';
  }
}

/// 任务编辑对话框
class _TaskEditDialog extends StatefulWidget {
  final ScheduledTask? task;
  final void Function(ScheduledTask) onSave;
  final VoidCallback onCancel;

  const _TaskEditDialog({
    this.task,
    required this.onSave,
    required this.onCancel,
  });

  @override
  State<_TaskEditDialog> createState() => _TaskEditDialogState();
}

class _TaskEditDialogState extends State<_TaskEditDialog> {
  late TextEditingController _titleController;
  late TextEditingController _descController;
  late TextEditingController _promptController;
  FrequencyType _frequencyType = FrequencyType.daily;
  TimeOfDay _time = const TimeOfDay(hour: 9, minute: 0);
  List<int> _selectedWeekdays = [1, 2, 3, 4, 5]; // 周一到周五
  int _intervalMinutes = 60;

  @override
  void initState() {
    super.initState();
    _titleController = TextEditingController(text: widget.task?.title ?? '');
    _descController = TextEditingController(text: widget.task?.description ?? '');
    _promptController = TextEditingController(text: widget.task?.prompt ?? '');
    if (widget.task != null) {
      _frequencyType = widget.task!.frequency.type;
      if (widget.task!.frequency.hour != null) {
        _time = TimeOfDay(hour: widget.task!.frequency.hour!, minute: widget.task!.frequency.minute!);
      }
      if (widget.task!.frequency.weekdays != null) {
        _selectedWeekdays = widget.task!.frequency.weekdays!;
      }
      if (widget.task!.frequency.intervalMinutes != null) {
        _intervalMinutes = widget.task!.frequency.intervalMinutes!;
      }
    }
  }

  @override
  void dispose() {
    _titleController.dispose();
    _descController.dispose();
    _promptController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Align(
      alignment: Alignment.topCenter, // 在设置面板顶部居中显示
      child: Container(
        margin: const EdgeInsets.only(top: 60), // 留出顶部空间
        width: 360,
        constraints: const BoxConstraints(maxHeight: 550),
        decoration: BoxDecoration(
          color: Colors.white,
          borderRadius: BorderRadius.circular(16),
          boxShadow: [
            BoxShadow(
              color: Colors.black.withOpacity(0.2),
              blurRadius: 20,
              offset: const Offset(0, 8),
            ),
          ],
        ),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            // 标题栏
            Padding(
              padding: const EdgeInsets.fromLTRB(20, 20, 20, 0),
              child: Row(
                children: [
                  Text(
                    widget.task == null ? '新建任务' : '编辑任务',
                    style: const TextStyle(fontSize: 18, fontWeight: FontWeight.bold),
                  ),
                  const Spacer(),
                  IconButton(
                    icon: const Icon(Icons.close, size: 18),
                    onPressed: widget.onCancel,
                    padding: EdgeInsets.zero,
                    constraints: const BoxConstraints(),
                    tooltip: '关闭',
                  ),
                ],
              ),
            ),
            const SizedBox(height: 16),
            // 可滚动的表单内容
            Flexible(
              child: SingleChildScrollView(
                padding: const EdgeInsets.symmetric(horizontal: 20),
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    TextField(
                      controller: _titleController,
                      decoration: const InputDecoration(
                        labelText: '任务名称',
                        border: OutlineInputBorder(),
                      ),
                    ),
                    const SizedBox(height: 12),
                    TextField(
                      controller: _descController,
                      decoration: const InputDecoration(
                        labelText: '描述（可选）',
                        border: OutlineInputBorder(),
                      ),
                      maxLines: 2,
                    ),
                    const SizedBox(height: 12),
                    TextField(
                      controller: _promptController,
                      decoration: const InputDecoration(
                        labelText: 'Prompt（要发送给 AI 的内容）',
                        border: OutlineInputBorder(),
                        hintText: '例如：提醒我喝水',
                      ),
                      maxLines: 3,
                    ),
                    const SizedBox(height: 12),
                    const Text('执行频率', style: TextStyle(fontWeight: FontWeight.w600)),
                    const SizedBox(height: 8),
                    DropdownButton<FrequencyType>(
                      value: _frequencyType,
                      isExpanded: true,
                      dropdownColor: Colors.white,
                      style: const TextStyle(color: Colors.black87, fontSize: 14),
                      items: const [
                        DropdownMenuItem(value: FrequencyType.daily, child: Text('每天')),
                        DropdownMenuItem(value: FrequencyType.weekly, child: Text('每周')),
                        DropdownMenuItem(value: FrequencyType.interval, child: Text('间隔')),
                      ],
                      onChanged: (value) => setState(() => _frequencyType = value!),
                    ),
                    const SizedBox(height: 12),
                    if (_frequencyType == FrequencyType.daily || _frequencyType == FrequencyType.weekly) ...[
                      ListTile(
                        title: Text('时间: ${_time.format(context)}'),
                        trailing: const Icon(Icons.access_time),
                        onTap: () async {
                          final time = await showTimePicker(context: context, initialTime: _time);
                          if (time != null) setState(() => _time = time);
                        },
                        contentPadding: EdgeInsets.zero,
                      ),
                    ],
                    if (_frequencyType == FrequencyType.weekly) ...[
                      const Text('星期', style: TextStyle(fontSize: 12)),
                      Wrap(
                        spacing: 8,
                        children: List.generate(7, (index) {
                          final day = index + 1;
                          final selected = _selectedWeekdays.contains(day);
                          return FilterChip(
                            label: Text(
                              _weekdayShort(day),
                              style: TextStyle(
                                color: selected ? Colors.white : Colors.black87,
                              ),
                            ),
                            selected: selected,
                            selectedColor: Theme.of(context).primaryColor,
                            backgroundColor: Colors.grey.shade100,
                            checkmarkColor: Colors.white,
                            onSelected: (value) {
                              setState(() {
                                if (value) {
                                  _selectedWeekdays.add(day);
                                } else {
                                  _selectedWeekdays.remove(day);
                                }
                              });
                            },
                          );
                        }),
                      ),
                    ],
                    if (_frequencyType == FrequencyType.interval) ...[
                      Row(
                        children: [
                          Expanded(
                            child: TextField(
                              decoration: const InputDecoration(
                                labelText: '间隔（分钟）',
                                border: OutlineInputBorder(),
                              ),
                              keyboardType: TextInputType.number,
                              controller: TextEditingController(text: _intervalMinutes.toString()),
                              onChanged: (value) => _intervalMinutes = int.tryParse(value) ?? 60,
                            ),
                          ),
                        ],
                      ),
                    ],
                  ],
                ),
              ),
            ),
            // 底部按钮（始终可见）
            Padding(
              padding: const EdgeInsets.fromLTRB(20, 12, 20, 20),
              child: Row(
                mainAxisAlignment: MainAxisAlignment.end,
                children: [
                  TextButton(
                    onPressed: widget.onCancel,
                    child: const Text('取消'),
                  ),
                  const SizedBox(width: 8),
                  ElevatedButton(
                    onPressed: _save,
                    child: const Text('确认'),
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }

  void _save() {
    if (_titleController.text.trim().isEmpty || _promptController.text.trim().isEmpty) {
      return;
    }

    TaskFrequency frequency;
    switch (_frequencyType) {
      case FrequencyType.daily:
        frequency = TaskFrequency.daily(_time.hour, _time.minute);
        break;
      case FrequencyType.weekly:
        if (_selectedWeekdays.isEmpty) return;
        frequency = TaskFrequency.weekly(_selectedWeekdays, _time.hour, _time.minute);
        break;
      case FrequencyType.interval:
        frequency = TaskFrequency.interval(_intervalMinutes);
        break;
      case FrequencyType.once:
        frequency = TaskFrequency.once(DateTime.now());
        break;
    }

    final task = ScheduledTask(
      id: widget.task?.id ?? DateTime.now().millisecondsSinceEpoch.toString(),
      title: _titleController.text.trim(),
      description: _descController.text.trim(),
      frequency: frequency,
      enabled: widget.task?.enabled ?? true,
      prompt: _promptController.text.trim(),
    );

    widget.onSave(task);
  }

  String _weekdayShort(int w) {
    const names = ['一', '二', '三', '四', '五', '六', '日'];
    return names[w - 1];
  }
}
