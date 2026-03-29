/// CUA 操作时间线面板
///
/// 在 CUA 模式下实时展示当前任务的子任务分解进度和操作历史。
/// 参考Plan模式的 _buildPlanPanel() 样式，使用深橙色主题（CUA 品牌色）。
library;

import 'dart:async';
import 'package:flutter/material.dart';
import '../../../skills/cua_recorder.dart';
import '../../../skills/cua_skill.dart';

/// CUA 操作时间线面板
class CuaTimelinePanel extends StatefulWidget {
  final VoidCallback? onClose;

  const CuaTimelinePanel({
    super.key,
    this.onClose,
  });

  @override
  State<CuaTimelinePanel> createState() => _CuaTimelinePanelState();
}

class _CuaTimelinePanelState extends State<CuaTimelinePanel> {
  Timer? _refreshTimer;
  CuaTask? _task;
  bool _isExpanded = false;

  @override
  void initState() {
    super.initState();
    _task = CuaSkill.getCurrentTask();
    // 注册子任务变更通知
    CuaSkill.onSubTaskChanged = _onTaskChanged;
    // 每 500ms 刷新一次（操作计数、状态变化）
    _refreshTimer = Timer.periodic(const Duration(milliseconds: 500), (_) {
      _refreshTask();
    });
  }

  @override
  void dispose() {
    _refreshTimer?.cancel();
    CuaSkill.onSubTaskChanged = null;
    super.dispose();
  }

  void _onTaskChanged(CuaTask task) {
    if (mounted) setState(() => _task = task);
  }

  void _refreshTask() {
    final current = CuaSkill.getCurrentTask();
    if (current != _task && mounted) {
      setState(() => _task = current);
    }
  }

  @override
  Widget build(BuildContext context) {
    final task = _task;
    if (task == null) return const SizedBox.shrink();

    final hasSubTasks = task.subTasks.isNotEmpty;

    return Container(
      constraints: BoxConstraints(maxHeight: _isExpanded ? 240 : 40),
      decoration: BoxDecoration(
        color: Colors.orange.shade50,
        border: Border(bottom: BorderSide(color: Colors.orange.shade200, width: 0.5)),
      ),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          // 标题栏（始终显示，点击可展开/折叠）
          GestureDetector(
            onTap: () => setState(() => _isExpanded = !_isExpanded),
            child: _buildHeader(hasSubTasks),
          ),
          // 内容区域（展开时显示）
          if (_isExpanded)
            Flexible(
              child: hasSubTasks
                  ? _buildSubTaskList(context)
                  : _buildOperationTimeline(context),
            ),
        ],
      ),
    );
  }

  Widget _buildHeader(bool hasSubTasks) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 6),
      decoration: BoxDecoration(
        color: Colors.orange.shade100,
        border: Border(bottom: BorderSide(color: Colors.orange.shade200)),
      ),
      child: Row(
        children: [
          // 展开/折叠箭头
          Icon(
            _isExpanded ? Icons.expand_less : Icons.expand_more,
            size: 16,
            color: Colors.orange.shade700,
          ),
          const SizedBox(width: 2),
          const Icon(Icons.timeline, size: 14, color: Color(0xFFFF5722)),
          const SizedBox(width: 4),
          Expanded(
            child: Text(
              _task!.description.length > 25
                  ? '${_task!.description.substring(0, 25)}...'
                  : _task!.description,
              style: const TextStyle(
                fontSize: 12,
                fontWeight: FontWeight.w600,
                color: Color(0xFFFF5722),
              ),
              overflow: TextOverflow.ellipsis,
            ),
          ),
          // 进度信息
          if (hasSubTasks) ...[
            const SizedBox(width: 6),
            Text(
              '${(_task!.subTaskProgress * 100).toInt()}%',
              style: TextStyle(fontSize: 10, color: Colors.orange.shade700),
            ),
            const SizedBox(width: 4),
            SizedBox(
              width: 40,
              height: 3,
              child: LinearProgressIndicator(
                value: _task!.subTaskProgress,
                backgroundColor: Colors.orange.shade100,
                valueColor: AlwaysStoppedAnimation<Color>(Colors.orange.shade600),
              ),
            ),
          ],
          // 操作计数
          Text(
            '${_task!.operationCount}步',
            style: TextStyle(fontSize: 10, color: Colors.orange.shade700),
          ),
          const SizedBox(width: 4),
          // 关闭按钮
          if (widget.onClose != null)
            InkWell(
              onTap: widget.onClose,
              child: const Padding(
                padding: EdgeInsets.all(2),
                child: Icon(Icons.close, size: 14, color: Colors.grey),
              ),
            ),
        ],
      ),
    );
  }

  /// 子任务列表视图
  Widget _buildSubTaskList(BuildContext context) {
    return ListView.builder(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
      itemCount: _task!.subTasks.length,
      itemBuilder: (context, index) {
        final sub = _task!.subTasks[index];
        return _buildSubTaskItem(sub, index, context);
      },
    );
  }

  Widget _buildSubTaskItem(CuaSubTask sub, int index, BuildContext context) {
    final statusColor = _getStatusColor(sub.status);
    final statusIcon = _getStatusIcon(sub.status);
    final isActive = sub.status == 'running';

    return Container(
      margin: const EdgeInsets.only(bottom: 2),
      padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 4),
      decoration: BoxDecoration(
        color: isActive ? Colors.orange.shade50 : Colors.white,
        borderRadius: BorderRadius.circular(4),
        border: Border.all(
          color: isActive ? Colors.orange.shade300 : Colors.grey.shade200,
        ),
      ),
      child: Row(
        children: [
          // 状态图标
          Container(
            width: 20,
            height: 20,
            decoration: BoxDecoration(
              color: statusColor.withOpacity(0.15),
              shape: BoxShape.circle,
            ),
            alignment: Alignment.center,
            child: sub.status == 'pending'
                ? Text('${index + 1}', style: TextStyle(fontSize: 10, fontWeight: FontWeight.bold, color: statusColor))
                : Icon(statusIcon, size: 12, color: statusColor),
          ),
          const SizedBox(width: 8),
          // 子任务描述
          Expanded(
            child: Text(
              sub.description,
              style: TextStyle(
                fontSize: 11,
                color: sub.status == 'pending' ? Colors.grey.shade600 : Colors.black87,
              ),
              overflow: TextOverflow.ellipsis,
              maxLines: 1,
            ),
          ),
          // 操作数
          if (sub.operationCount > 0)
            Text(
              '${sub.operationCount}步',
              style: TextStyle(fontSize: 9, color: Colors.grey.shade500),
            ),
          const SizedBox(width: 4),
          // 状态标签
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 1),
            decoration: BoxDecoration(
              color: statusColor.withOpacity(0.1),
              borderRadius: BorderRadius.circular(3),
            ),
            child: Text(
              _getStatusLabel(sub.status),
              style: TextStyle(fontSize: 9, color: statusColor),
            ),
          ),
        ],
      ),
    );
  }

  /// 操作时间线视图（无子任务时显示）
  Widget _buildOperationTimeline(BuildContext context) {
    // 最多显示最近 15 条操作
    final recentOps = _task!.operations.length > 15
        ? _task!.operations.sublist(_task!.operations.length - 15)
        : _task!.operations;

    if (recentOps.isEmpty) {
      return const Padding(
        padding: EdgeInsets.all(12),
        child: Center(
          child: Text('等待操作...', style: TextStyle(fontSize: 11, color: Colors.grey)),
        ),
      );
    }

    return ListView.builder(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
      itemCount: recentOps.length,
      itemBuilder: (context, index) {
        final op = recentOps[index];
        final isLast = index == recentOps.length - 1;

        return Padding(
          padding: const EdgeInsets.symmetric(vertical: 1),
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              // 时间线圆点
              Column(
                children: [
                  Container(
                    width: 8,
                    height: 8,
                    decoration: BoxDecoration(
                      color: op.success ? Colors.green.shade400 : Colors.red.shade400,
                      shape: BoxShape.circle,
                      border: Border.all(color: Colors.grey.shade300, width: 1),
                    ),
                  ),
                  if (!isLast)
                    Container(
                      width: 1,
                      height: 18,
                      color: Colors.grey.shade300,
                    ),
                ],
              ),
              const SizedBox(width: 6),
              // 操作内容
              Expanded(
                child: Text(
                  '${op.displayTitle}${op.displayDesc.isNotEmpty ? ' ${op.displayDesc}' : ''}',
                  style: TextStyle(
                    fontSize: 10,
                    color: Colors.grey.shade700,
                  ),
                  overflow: TextOverflow.ellipsis,
                  maxLines: 1,
                ),
              ),
              // 耗时
              if (op.durationMs > 0)
                Text(
                  _formatDuration(op.durationMs),
                  style: TextStyle(fontSize: 9, color: Colors.grey.shade400),
                ),
            ],
          ),
        );
      },
    );
  }

  Color _getStatusColor(String status) {
    switch (status) {
      case 'pending': return Colors.grey;
      case 'running': return Colors.orange;
      case 'completed': return Colors.green;
      case 'failed': return Colors.red;
      case 'skipped': return Colors.orange.shade700;
      default: return Colors.grey;
    }
  }

  IconData _getStatusIcon(String status) {
    switch (status) {
      case 'pending': return Icons.circle_outlined;
      case 'running': return Icons.sync;
      case 'completed': return Icons.check;
      case 'failed': return Icons.close;
      case 'skipped': return Icons.skip_next;
      default: return Icons.circle_outlined;
    }
  }

  String _getStatusLabel(String status) {
    switch (status) {
      case 'pending': return '待执行';
      case 'running': return '执行中';
      case 'completed': return '完成';
      case 'failed': return '失败';
      case 'skipped': return '跳过';
      default: return status;
    }
  }

  String _formatDuration(int ms) {
    if (ms < 1000) return '${ms}ms';
    if (ms < 60000) return '${(ms / 1000).toStringAsFixed(1)}s';
    final mins = ms ~/ 60000;
    final secs = ((ms % 60000) / 1000).toStringAsFixed(0);
    return '${mins}m${secs}s';
  }
}
