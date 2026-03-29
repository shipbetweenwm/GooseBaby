import 'dart:io';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import '../../../models/models.dart';

/// 文件附件卡片 — 展示文件名、大小、图标 + 文件内容预览（默认3行，可展开）
class FileCard extends StatefulWidget {
  final MessageAttachment attachment;
  final bool isUser;

  const FileCard({
    super.key,
    required this.attachment,
    this.isUser = false,
  });

  @override
  State<FileCard> createState() => FileCardState();
}

class FileCardState extends State<FileCard> {
  bool _expanded = false;
  String? _fileContent;
  bool _isLoading = false;
  int _totalLines = 0;

  /// 预览显示的行数
  static const int _previewLines = 3;

  /// 最大预览字符数
  static const int _maxPreviewChars = 8000;

  /// 图片最大尺寸限制（字节）
  static const int _maxImageBytes = 10 * 1024 * 1024; // 10MB

  bool get _canPreview => _isTextFile(widget.attachment);

  bool get _isImage => _isImageFile(widget.attachment);

  bool _isTextFile(MessageAttachment att) {
    final ext = _getExtension(att);
    const textExts = {
      'txt', 'log', 'md', 'json', 'xml', 'yaml', 'yml', 'toml', 'csv',
      'tsv', 'html', 'htm', 'css', 'sql', 'ini', 'cfg', 'conf', 'env',
      'gitignore', 'dockerfile', 'dart', 'py', 'js', 'ts', 'jsx', 'tsx',
      'java', 'cpp', 'c', 'h', 'hpp', 'go', 'rs', 'rb', 'php', 'pl',
      'sh', 'bat', 'cmd', 'ps1', 'lua', 'r', 'swift', 'kt', 'scala',
      'vue', 'svelte', 'scss', 'less', 'sass', 'makefile',
    };
    return textExts.contains(ext);
  }

  bool _isImageFile(MessageAttachment att) {
    final ext = _getExtension(att);
    const imageExts = {'png', 'jpg', 'jpeg', 'gif', 'webp', 'bmp', 'ico', 'svg'};
    return imageExts.contains(ext);
  }

  void _loadContent() {
    if (_isLoading || _fileContent != null) return;
    final path = widget.attachment.filePath;
    if (path == null) return;

    setState(() => _isLoading = true);
    try {
      final file = File(path);
      if (!file.existsSync()) return;
      final size = file.lengthSync();
      if (size > 512 * 1024) return; // > 512KB 不预览

      final content = file.readAsStringSync();
      final lines = content.split('\n');
      _totalLines = lines.length;

      if (content.length > _maxPreviewChars) {
        _fileContent = content.substring(0, _maxPreviewChars);
      } else {
        _fileContent = content;
      }
    } catch (_) {
      // 非文本文件或读取失败，静默忽略
    } finally {
      if (mounted) setState(() => _isLoading = false);
    }
  }

  String _getExtension(MessageAttachment att) {
    final name = att.fileName ?? '';
    final dot = name.lastIndexOf('.');
    if (dot < 0 || dot == name.length - 1) return '';
    return name.substring(dot + 1).toLowerCase();
  }

  String _formatBytes(int bytes) {
    if (bytes < 1024) return '$bytes B';
    if (bytes < 1024 * 1024) return '${(bytes / 1024).toStringAsFixed(1)} KB';
    return '${(bytes / (1024 * 1024)).toStringAsFixed(1)} MB';
  }

  String _getPreviewContent() {
    if (_fileContent == null) return '';
    final lines = _fileContent!.split('\n');
    if (lines.length <= _previewLines) return _fileContent!;
    return lines.take(_previewLines).join('\n');
  }

  void _copyContent() {
    if (_fileContent != null) {
      Clipboard.setData(ClipboardData(text: _fileContent!));
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text('已复制文件内容', style: TextStyle(fontSize: 12)),
          duration: Duration(seconds: 1),
        ),
      );
    }
  }

  void _openFile() {
    final path = widget.attachment.filePath;
    if (path == null) return;
    try {
      final file = File(path);
      if (file.existsSync()) {
        if (Platform.isMacOS) {
          Process.run('open', ['-R', path]); // 在 Finder 中显示
        } else if (Platform.isWindows) {
          final winPath = path.replaceAll('/', '\\');
          Process.run('explorer', ['/select,', winPath]);
        } else if (Platform.isLinux) {
          Process.run('xdg-open', [file.parent.path]);
        }
      } else {
        // 文件不存在，尝试打开父目录
        final dir = file.parent.path;
        if (Platform.isMacOS) {
          Process.run('open', [dir]);
        } else if (Platform.isWindows) {
          Process.run('explorer', [dir.replaceAll('/', '\\')]);
        } else if (Platform.isLinux) {
          Process.run('xdg-open', [dir]);
        }
      }
    } catch (_) {}
  }

  @override
  Widget build(BuildContext context) {
    return Container(
      margin: const EdgeInsets.only(top: 6),
      decoration: BoxDecoration(
        color: widget.isUser
            ? Colors.white.withOpacity(0.15)
            : const Color(0xFFF0F2F5),
        borderRadius: BorderRadius.circular(10),
        border: Border.all(
          color: widget.isUser
              ? Colors.white.withOpacity(0.2)
              : const Color(0xFFE0E0E0),
          width: 0.5,
        ),
      ),
      clipBehavior: Clip.antiAlias,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        mainAxisSize: MainAxisSize.min,
        children: [
          // 文件头部（文件名 + 大小 + 打开按钮）
          InkWell(
            onTap: () {
              _openFile();
              // 点击头部时异步加载内容
              if (_canPreview && _fileContent == null) _loadContent();
            },
            borderRadius: const BorderRadius.vertical(top: Radius.circular(10)),
            child: Padding(
              padding: const EdgeInsets.all(10),
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
                          widget.attachment.fileName ?? '未知文件',
                          style: TextStyle(
                            fontSize: 13,
                            fontWeight: FontWeight.w500,
                            color: widget.isUser ? Colors.white : const Color(0xFF424242),
                          ),
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                        ),
                        const SizedBox(height: 2),
                        Text(
                          widget.attachment.formattedSize,
                          style: TextStyle(
                            fontSize: 11,
                            color: widget.isUser
                                ? Colors.white.withOpacity(0.7)
                                : Colors.grey.shade500,
                          ),
                        ),
                      ],
                    ),
                  ),
                  const SizedBox(width: 8),
                  Icon(
                    Icons.open_in_new_rounded,
                    size: 16,
                    color: widget.isUser
                        ? Colors.white.withOpacity(0.7)
                        : Colors.grey.shade400,
                  ),
                ],
              ),
            ),
          ),

          // 文件内容预览区域（仅文本文件）
          if (_canPreview) ...[
            // 加载指示器
            if (_isLoading)
              const Padding(
                padding: EdgeInsets.symmetric(horizontal: 12, vertical: 8),
                child: SizedBox(
                  width: 14,
                  height: 14,
                  child: CircularProgressIndicator(strokeWidth: 2),
                ),
              )
            // 预览内容
            else if (_fileContent != null)
              _buildPreview(),
          ],

          // 图片预览区域
          if (_isImage)
            _buildImagePreview(),
        ],
      ),
    );
  }

  Widget _buildImagePreview() {
    final path = widget.attachment.filePath;
    if (path == null) return const SizedBox.shrink();

    final file = File(path);
    if (!file.existsSync()) return const SizedBox.shrink();

    final size = file.lengthSync();
    if (size > _maxImageBytes) {
      return Padding(
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
        child: Text(
          '图片过大，无法预览 (${_formatBytes(size)})',
          style: TextStyle(fontSize: 11, color: Colors.grey.shade500),
        ),
      );
    }

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        // 分隔线
        Container(
          margin: const EdgeInsets.symmetric(horizontal: 10),
          height: 0.5,
          color: Colors.grey.shade300,
        ),
        // 图片预览
        Padding(
          padding: const EdgeInsets.all(8),
          child: ClipRRect(
            borderRadius: BorderRadius.circular(6),
            child: ConstrainedBox(
              constraints: const BoxConstraints(maxHeight: 200),
              child: Image.file(
                file,
                fit: BoxFit.contain,
                errorBuilder: (context, error, stackTrace) {
                  return Padding(
                    padding: const EdgeInsets.all(12),
                    child: Text(
                      '图片加载失败',
                      style: TextStyle(fontSize: 11, color: Colors.grey.shade500),
                    ),
                  );
                },
              ),
            ),
          ),
        ),
      ],
    );
  }

  Widget _buildPreview() {
    final lines = _fileContent!.split('\n');
    final needsCollapse = lines.length > _previewLines;
    final displayContent = _expanded ? _fileContent! : _getPreviewContent();

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        // 分隔线
        Container(
          margin: const EdgeInsets.symmetric(horizontal: 10),
          height: 0.5,
          color: Colors.grey.shade300,
        ),
        // 代码预览
        Container(
          width: double.infinity,
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              // 文件内容（等宽字体）
              SelectableText(
                displayContent,
                style: TextStyle(
                  fontSize: 11,
                  height: 1.5,
                  color: Colors.grey.shade800,
                  fontFamily: 'Consolas',
                ),
              ),
              // 展开/折叠 + 复制按钮
              if (needsCollapse || _expanded)
                Padding(
                  padding: const EdgeInsets.only(top: 6),
                  child: Row(
                    children: [
                      // 展开/折叠
                      InkWell(
                        onTap: () => setState(() => _expanded = !_expanded),
                        borderRadius: BorderRadius.circular(4),
                        child: Padding(
                          padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
                          child: Row(
                            mainAxisSize: MainAxisSize.min,
                            children: [
                              Icon(
                                _expanded ? Icons.expand_less : Icons.expand_more,
                                size: 14,
                                color: Colors.grey.shade500,
                              ),
                              const SizedBox(width: 2),
                              Text(
                                _expanded ? '收起' : '展开全部 (${_totalLines} 行)',
                                style: TextStyle(
                                  fontSize: 10,
                                  color: Colors.grey.shade500,
                                ),
                              ),
                            ],
                          ),
                        ),
                      ),
                      const Spacer(),
                      // 复制按钮
                      InkWell(
                        onTap: _copyContent,
                        borderRadius: BorderRadius.circular(4),
                        child: Padding(
                          padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
                          child: Row(
                            mainAxisSize: MainAxisSize.min,
                            children: [
                              Icon(
                                Icons.copy_rounded,
                                size: 12,
                                color: Colors.grey.shade500,
                              ),
                              const SizedBox(width: 2),
                              Text(
                                '复制',
                                style: TextStyle(
                                  fontSize: 10,
                                  color: Colors.grey.shade500,
                                ),
                              ),
                            ],
                          ),
                        ),
                      ),
                    ],
                  ),
                ),
            ],
          ),
        ),
      ],
    );
  }

  IconData _getFileIcon() {
    final ext = _getExtension(widget.attachment);
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
    final ext = _getExtension(widget.attachment);
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
}
