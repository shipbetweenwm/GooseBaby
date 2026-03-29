import 'dart:io';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:file_picker/file_picker.dart';
import 'package:mime/mime.dart';
import '../../../models/models.dart';

/// 增强版输入栏 — 文件/图片选择、附件预览、粘贴图片
class EnhancedInputBar extends StatefulWidget {
  final TextEditingController controller;
  final FocusNode focusNode;
  final bool isLoading;
  final VoidCallback onSend;
  final VoidCallback? onStop;
  final ValueChanged<List<MessageAttachment>> onAttachmentsChanged;
  final List<MessageAttachment> attachments;

  const EnhancedInputBar({
    super.key,
    required this.controller,
    required this.focusNode,
    required this.isLoading,
    required this.onSend,
    this.onStop,
    required this.onAttachmentsChanged,
    this.attachments = const [],
  });

  @override
  State<EnhancedInputBar> createState() => _EnhancedInputBarState();
}

class _EnhancedInputBarState extends State<EnhancedInputBar> {
  bool _showToolbar = false;

  /// 图片文件扩展名
  static const _imageExtensions = {
    'jpg', 'jpeg', 'png', 'gif', 'bmp', 'webp', 'svg', 'ico', 'tiff', 'tif'
  };

  /// 判断是否为图片文件
  bool _isImageFile(String path) {
    final ext = path.split('.').last.toLowerCase();
    return _imageExtensions.contains(ext);
  }

  /// 选择图片
  Future<void> _pickImages() async {
    try {
      final desktop = '${Platform.environment['USERPROFILE']}\\Desktop';
      final result = await FilePicker.platform.pickFiles(
        type: FileType.image,
        allowMultiple: true,
        dialogTitle: '选择图片',
        initialDirectory: Directory(desktop).existsSync() ? desktop : null,
      );
      if (result != null && result.files.isNotEmpty) {
        final newAttachments = <MessageAttachment>[...widget.attachments];
        for (final file in result.files) {
          if (file.path != null) {
            final stat = File(file.path!).statSync();
            newAttachments.add(MessageAttachment(
              type: AttachmentType.image,
              filePath: file.path,
              fileName: file.name,
              fileSize: stat.size,
              mimeType: lookupMimeType(file.path!),
            ));
          }
        }
        widget.onAttachmentsChanged(newAttachments);
      }
    } catch (e) {
      debugPrint('🦢 选择图片失败: $e');
    }
  }

  /// 选择文件
  Future<void> _pickFiles() async {
    try {
      final desktop = '${Platform.environment['USERPROFILE']}\\Desktop';
      final result = await FilePicker.platform.pickFiles(
        allowMultiple: true,
        dialogTitle: '选择文件',
        initialDirectory: Directory(desktop).existsSync() ? desktop : null,
      );
      if (result != null && result.files.isNotEmpty) {
        final newAttachments = <MessageAttachment>[...widget.attachments];
        for (final file in result.files) {
          if (file.path != null) {
            final stat = File(file.path!).statSync();
            final isImage = _isImageFile(file.path!);
            newAttachments.add(MessageAttachment(
              type: isImage ? AttachmentType.image : AttachmentType.file,
              filePath: file.path,
              fileName: file.name,
              fileSize: stat.size,
              mimeType: lookupMimeType(file.path!),
            ));
          }
        }
        widget.onAttachmentsChanged(newAttachments);
      }
    } catch (e) {
      debugPrint('🦢 选择文件失败: $e');
    }
  }

  /// 删除附件
  void _removeAttachment(int index) {
    final newAttachments = [...widget.attachments];
    newAttachments.removeAt(index);
    widget.onAttachmentsChanged(newAttachments);
  }

  @override
  Widget build(BuildContext context) {
    return Container(
      decoration: const BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.only(bottomLeft: Radius.circular(20)),
        border: Border(top: BorderSide(color: Color(0xFFE0E0E0), width: 0.5)),
      ),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          // 附件预览区域
          if (widget.attachments.isNotEmpty) _buildAttachmentPreview(),
          // 输入区域
          _buildInputRow(),
        ],
      ),
    );
  }

  /// 附件预览区域
  Widget _buildAttachmentPreview() {
    return Container(
      padding: const EdgeInsets.fromLTRB(12, 8, 12, 0),
      child: Wrap(
        spacing: 8,
        runSpacing: 8,
        children: List.generate(widget.attachments.length, (index) {
          final att = widget.attachments[index];
          return _buildAttachmentChip(att, index);
        }),
      ),
    );
  }

  /// 单个附件预览小卡片
  Widget _buildAttachmentChip(MessageAttachment att, int index) {
    if (att.type == AttachmentType.image && att.filePath != null) {
      return _buildImageChip(att, index);
    }
    return _buildFileChip(att, index);
  }

  /// 图片预览小卡片
  Widget _buildImageChip(MessageAttachment att, int index) {
    return Stack(
      children: [
        Container(
          width: 64,
          height: 64,
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(8),
            border: Border.all(color: const Color(0xFFE0E0E0), width: 0.5),
          ),
          clipBehavior: Clip.antiAlias,
          child: ClipRRect(
            borderRadius: BorderRadius.circular(7.5),
            child: Image.file(
              File(att.filePath!),
              fit: BoxFit.cover,
              width: 64,
              height: 64,
              errorBuilder: (_, __, ___) => Container(
                color: Colors.grey.shade200,
                child: Icon(Icons.broken_image, color: Colors.grey.shade400, size: 24),
              ),
            ),
          ),
        ),
        Positioned(
          top: -4,
          right: -4,
          child: _buildRemoveButton(index),
        ),
      ],
    );
  }

  /// 文件预览小卡片
  Widget _buildFileChip(MessageAttachment att, int index) {
    return Stack(
      children: [
        Container(
          constraints: const BoxConstraints(maxWidth: 160),
          padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
          decoration: BoxDecoration(
            color: const Color(0xFFF5F5F5),
            borderRadius: BorderRadius.circular(8),
            border: Border.all(color: const Color(0xFFE0E0E0), width: 0.5),
          ),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(Icons.insert_drive_file_rounded, size: 16, color: Colors.blue.shade400),
              const SizedBox(width: 6),
              Flexible(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Text(
                      att.fileName ?? '文件',
                      style: const TextStyle(fontSize: 11, fontWeight: FontWeight.w500),
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                    ),
                    Text(
                      att.formattedSize,
                      style: TextStyle(fontSize: 9, color: Colors.grey.shade500),
                    ),
                  ],
                ),
              ),
            ],
          ),
        ),
        Positioned(
          top: -4,
          right: -4,
          child: _buildRemoveButton(index),
        ),
      ],
    );
  }

  /// 删除按钮
  Widget _buildRemoveButton(int index) {
    return GestureDetector(
      onTap: () => _removeAttachment(index),
      child: Container(
        width: 18,
        height: 18,
        decoration: BoxDecoration(
          color: Colors.red.shade400,
          shape: BoxShape.circle,
          boxShadow: [
            BoxShadow(
              color: Colors.black.withOpacity(0.15),
              blurRadius: 2,
              offset: const Offset(0, 1),
            ),
          ],
        ),
        child: const Icon(Icons.close, size: 12, color: Colors.white),
      ),
    );
  }

  /// 输入区域
  Widget _buildInputRow() {
    return Padding(
      padding: const EdgeInsets.all(10),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.end,
        children: [
          // 附件按钮（展开/收起工具栏）
          _buildToolbarToggle(),
          // 展开的工具栏
          if (_showToolbar) ...[
            _buildToolButton(
              icon: Icons.image_rounded,
              color: Colors.green,
              tooltip: '发送图片',
              onTap: _pickImages,
            ),
            _buildToolButton(
              icon: Icons.attach_file_rounded,
              color: Colors.orange,
              tooltip: '发送文件',
              onTap: _pickFiles,
            ),
          ],
          const SizedBox(width: 6),
          // 输入框
          Expanded(
            child: Container(
              decoration: BoxDecoration(
                color: const Color(0xFFF5F5F5),
                borderRadius: BorderRadius.circular(20),
                border: Border.all(color: const Color(0xFFE8E8E8), width: 0.5),
              ),
              child: Focus(
                onKeyEvent: (node, event) {
                  if (event is KeyDownEvent &&
                      event.logicalKey == LogicalKeyboardKey.enter &&
                      !HardwareKeyboard.instance.isShiftPressed) {
                    // IME 合成中（中文输入法选字阶段）—— 透传给输入法，不发送
                    // composing != TextRange.empty 表示输入法尚未上屏
                    if (widget.controller.value.composing != TextRange.empty) {
                      return KeyEventResult.ignored;
                    }
                    // Enter 发送消息，消费事件阻止换行
                    _handleSend();
                    return KeyEventResult.handled;
                  }
                  return KeyEventResult.ignored;
                },
                child: TextField(
                  controller: widget.controller,
                  focusNode: widget.focusNode,
                  maxLines: 5,
                  minLines: 1,
                  decoration: InputDecoration(
                    hintText: widget.attachments.isEmpty
                        ? '跟鹅宝说点什么吧...'
                        : '添加说明...',
                    hintStyle: const TextStyle(color: Colors.grey, fontSize: 14),
                    border: InputBorder.none,
                    contentPadding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
                  ),
                  style: const TextStyle(fontSize: 14),
                  textInputAction: TextInputAction.newline,
                ),
              ),
            ),
          ),
          const SizedBox(width: 8),
          // 发送按钮
          _buildSendButton(),
        ],
      ),
    );
  }

  /// 工具栏展开/收起按钮
  Widget _buildToolbarToggle() {
    return GestureDetector(
      onTap: () => setState(() => _showToolbar = !_showToolbar),
      child: Container(
        width: 36,
        height: 36,
        margin: const EdgeInsets.only(right: 2),
        decoration: BoxDecoration(
          color: _showToolbar ? const Color(0xFF4FC3F7).withOpacity(0.1) : Colors.transparent,
          borderRadius: BorderRadius.circular(18),
        ),
        child: AnimatedRotation(
          turns: _showToolbar ? 0.125 : 0, // 45度
          duration: const Duration(milliseconds: 200),
          child: Icon(
            Icons.add_circle_outline_rounded,
            size: 24,
            color: _showToolbar ? const Color(0xFF4FC3F7) : Colors.grey.shade500,
          ),
        ),
      ),
    );
  }

  /// 工具按钮
  Widget _buildToolButton({
    required IconData icon,
    required Color color,
    required String tooltip,
    required VoidCallback onTap,
  }) {
    return Tooltip(
      message: tooltip,
      child: GestureDetector(
        onTap: onTap,
        child: Container(
          width: 36,
          height: 36,
          margin: const EdgeInsets.only(right: 2),
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(18),
          ),
          child: Icon(icon, size: 22, color: color),
        ),
      ),
    );
  }

  /// 发送按钮
  Widget _buildSendButton() {
    if (widget.isLoading) {
      // 加载中 → 显示停止按钮（红色，可点击）
      return Material(
        color: Colors.red.shade400,
        borderRadius: BorderRadius.circular(20),
        child: InkWell(
          onTap: widget.onStop,
          borderRadius: BorderRadius.circular(20),
          child: Container(
            width: 40,
            height: 40,
            alignment: Alignment.center,
            child: const Icon(
              Icons.stop_rounded,
              color: Colors.white,
              size: 22,
            ),
          ),
        ),
      );
    }

    // 正常状态 → 发送按钮
    return Material(
      color: const Color(0xFF4FC3F7),
      borderRadius: BorderRadius.circular(20),
      child: InkWell(
        onTap: _handleSend,
        borderRadius: BorderRadius.circular(20),
        child: Container(
          width: 40,
          height: 40,
          alignment: Alignment.center,
          child: const Icon(
            Icons.send_rounded,
            color: Colors.white,
            size: 20,
          ),
        ),
      ),
    );
  }

  void _handleSend() {
    if (widget.controller.text.trim().isEmpty && widget.attachments.isEmpty) return;
    widget.onSend();
    setState(() => _showToolbar = false);
  }
}
