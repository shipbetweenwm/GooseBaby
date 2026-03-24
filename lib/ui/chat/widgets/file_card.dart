import 'dart:io';
import 'package:flutter/material.dart';
import '../../../models/models.dart';

/// 文件附件卡片 — 展示文件名、大小、图标
class FileCard extends StatelessWidget {
  final MessageAttachment attachment;
  final bool isUser;

  const FileCard({
    super.key,
    required this.attachment,
    this.isUser = false,
  });

  @override
  Widget build(BuildContext context) {
    return Container(
      margin: const EdgeInsets.only(top: 6),
      padding: const EdgeInsets.all(10),
      decoration: BoxDecoration(
        color: isUser
            ? Colors.white.withOpacity(0.15)
            : const Color(0xFFF0F2F5),
        borderRadius: BorderRadius.circular(10),
        border: Border.all(
          color: isUser
              ? Colors.white.withOpacity(0.2)
              : const Color(0xFFE0E0E0),
          width: 0.5,
        ),
      ),
      child: InkWell(
        onTap: _openFile,
        borderRadius: BorderRadius.circular(10),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            // 文件图标
            Container(
              width: 36,
              height: 36,
              decoration: BoxDecoration(
                color: _getIconColor().withOpacity(0.15),
                borderRadius: BorderRadius.circular(8),
              ),
              child: Icon(
                _getFileIcon(),
                size: 20,
                color: _getIconColor(),
              ),
            ),
            const SizedBox(width: 10),
            // 文件信息
            Flexible(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                mainAxisSize: MainAxisSize.min,
                children: [
                  Text(
                    attachment.fileName ?? '未知文件',
                    style: TextStyle(
                      fontSize: 13,
                      fontWeight: FontWeight.w500,
                      color: isUser ? Colors.white : const Color(0xFF424242),
                    ),
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                  ),
                  const SizedBox(height: 2),
                  Text(
                    attachment.formattedSize,
                    style: TextStyle(
                      fontSize: 11,
                      color: isUser
                          ? Colors.white.withOpacity(0.7)
                          : Colors.grey.shade500,
                    ),
                  ),
                ],
              ),
            ),
            const SizedBox(width: 8),
            Icon(
              Icons.download_rounded,
              size: 18,
              color: isUser
                  ? Colors.white.withOpacity(0.7)
                  : Colors.grey.shade400,
            ),
          ],
        ),
      ),
    );
  }

  void _openFile() {
    final path = attachment.filePath;
    if (path == null) return;
    try {
      // 将路径转换为 Windows 格式（反斜杠）
      final winPath = path.replaceAll('/', '\\');
      final file = File(winPath);
      if (file.existsSync()) {
        // 文件存在：在资源管理器中定位并选中文件
        Process.run('explorer', ['/select,', winPath]);
      } else {
        // 文件不存在：打开文件所在目录
        final dir = file.parent.path;
        Process.run('explorer', [dir]);
      }
    } catch (_) {}
  }

  IconData _getFileIcon() {
    final ext = _getExtension();
    switch (ext) {
      case 'pdf':
        return Icons.picture_as_pdf_rounded;
      case 'doc':
      case 'docx':
        return Icons.description_rounded;
      case 'xls':
      case 'xlsx':
        return Icons.table_chart_rounded;
      case 'ppt':
      case 'pptx':
        return Icons.slideshow_rounded;
      case 'zip':
      case 'rar':
      case '7z':
      case 'tar':
      case 'gz':
        return Icons.folder_zip_rounded;
      case 'mp3':
      case 'wav':
      case 'flac':
      case 'aac':
        return Icons.audio_file_rounded;
      case 'mp4':
      case 'avi':
      case 'mkv':
      case 'mov':
        return Icons.video_file_rounded;
      case 'txt':
      case 'log':
        return Icons.text_snippet_rounded;
      case 'json':
      case 'xml':
      case 'yaml':
      case 'yml':
        return Icons.data_object_rounded;
      case 'dart':
      case 'py':
      case 'js':
      case 'ts':
      case 'java':
      case 'cpp':
      case 'c':
      case 'go':
      case 'rs':
        return Icons.code_rounded;
      default:
        return Icons.insert_drive_file_rounded;
    }
  }

  Color _getIconColor() {
    final ext = _getExtension();
    switch (ext) {
      case 'pdf':
        return Colors.red;
      case 'doc':
      case 'docx':
        return Colors.blue;
      case 'xls':
      case 'xlsx':
        return Colors.green;
      case 'ppt':
      case 'pptx':
        return Colors.orange;
      case 'zip':
      case 'rar':
      case '7z':
        return Colors.amber;
      case 'mp3':
      case 'wav':
        return Colors.purple;
      case 'mp4':
      case 'avi':
        return Colors.pink;
      case 'dart':
        return Colors.cyan;
      case 'py':
        return Colors.yellow.shade700;
      case 'js':
      case 'ts':
        return Colors.amber.shade700;
      default:
        return Colors.blueGrey;
    }
  }

  String _getExtension() {
    final name = attachment.fileName ?? '';
    final dot = name.lastIndexOf('.');
    if (dot < 0 || dot == name.length - 1) return '';
    return name.substring(dot + 1).toLowerCase();
  }
}