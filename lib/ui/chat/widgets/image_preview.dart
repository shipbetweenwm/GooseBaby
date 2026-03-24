import 'dart:io';
import 'package:flutter/material.dart';
import '../../../models/models.dart';

/// 图片预览组件 — 缩略图 + 点击放大
class ImagePreview extends StatelessWidget {
  final MessageAttachment attachment;
  final bool isUser;

  const ImagePreview({
    super.key,
    required this.attachment,
    this.isUser = false,
  });

  @override
  Widget build(BuildContext context) {
    final path = attachment.filePath;
    if (path == null || !File(path).existsSync()) {
      return _buildErrorPlaceholder();
    }

    return GestureDetector(
      onTap: () => _showFullImage(context, path),
      child: Container(
        margin: const EdgeInsets.only(top: 6),
        constraints: const BoxConstraints(
          maxWidth: 240,
          maxHeight: 200,
        ),
        decoration: BoxDecoration(
          borderRadius: BorderRadius.circular(10),
          border: Border.all(
            color: isUser
                ? Colors.white.withOpacity(0.2)
                : const Color(0xFFE0E0E0),
            width: 0.5,
          ),
        ),
        clipBehavior: Clip.antiAlias,
        child: Stack(
          children: [
            // 图片
            ClipRRect(
              borderRadius: BorderRadius.circular(9.5),
              child: Image.file(
                File(path),
                fit: BoxFit.cover,
                width: double.infinity,
                errorBuilder: (_, __, ___) => _buildErrorPlaceholder(),
              ),
            ),
            // 放大提示图标
            Positioned(
              right: 6,
              bottom: 6,
              child: Container(
                padding: const EdgeInsets.all(4),
                decoration: BoxDecoration(
                  color: Colors.black.withOpacity(0.5),
                  borderRadius: BorderRadius.circular(4),
                ),
                child: const Icon(
                  Icons.zoom_in_rounded,
                  size: 14,
                  color: Colors.white,
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildErrorPlaceholder() {
    return Container(
      margin: const EdgeInsets.only(top: 6),
      width: 120,
      height: 80,
      decoration: BoxDecoration(
        color: Colors.grey.shade200,
        borderRadius: BorderRadius.circular(10),
      ),
      child: Column(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          Icon(Icons.broken_image_rounded, color: Colors.grey.shade400, size: 28),
          const SizedBox(height: 4),
          Text(
            '图片加载失败',
            style: TextStyle(fontSize: 10, color: Colors.grey.shade500),
          ),
        ],
      ),
    );
  }

  void _showFullImage(BuildContext context, String path) {
    showDialog(
      context: context,
      barrierColor: Colors.black87,
      builder: (ctx) => _FullImageDialog(imagePath: path),
    );
  }
}

/// 全屏图片查看弹窗
class _FullImageDialog extends StatelessWidget {
  final String imagePath;

  const _FullImageDialog({required this.imagePath});

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onTap: () => Navigator.of(context).pop(),
      child: Dialog(
        backgroundColor: Colors.transparent,
        insetPadding: const EdgeInsets.all(20),
        child: Stack(
          children: [
            Center(
              child: InteractiveViewer(
                minScale: 0.5,
                maxScale: 4.0,
                child: ClipRRect(
                  borderRadius: BorderRadius.circular(8),
                  child: Image.file(
                    File(imagePath),
                    fit: BoxFit.contain,
                  ),
                ),
              ),
            ),
            Positioned(
              top: 0,
              right: 0,
              child: IconButton(
                onPressed: () => Navigator.of(context).pop(),
                icon: const Icon(Icons.close, color: Colors.white, size: 28),
              ),
            ),
          ],
        ),
      ),
    );
  }
}
