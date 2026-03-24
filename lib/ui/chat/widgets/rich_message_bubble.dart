import 'package:flutter/material.dart';
import 'package:flutter/gestures.dart';
import 'package:url_launcher/url_launcher.dart';
import '../../../models/models.dart';
import 'code_block.dart';
import 'file_card.dart';
import 'image_preview.dart';

/// 富文本消息气泡 — 自实现 Markdown 渲染 + 代码高亮 + 图片 + 文件
class RichMessageBubble extends StatelessWidget {
  final String content;
  final bool isUser;
  final bool isError;
  final String? skillResult;
  final DateTime timestamp;
  final List<MessageAttachment> attachments;
  final double fontSize;

  /// 基准字体大小比例因子（默认 14 / 用户设置的 fontSize）
  double get _scale => fontSize / 14.0;

  const RichMessageBubble({
    super.key,
    required this.content,
    required this.isUser,
    required this.timestamp,
    this.isError = false,
    this.skillResult,
    this.attachments = const [],
    this.fontSize = 14.0,
  });

  @override
  Widget build(BuildContext context) {
    return Align(
      alignment: isUser ? Alignment.centerRight : Alignment.centerLeft,
      child: LayoutBuilder(
        builder: (context, constraints) {
          // 气泡最大宽度 = 面板可用宽度的 85%，确保随面板拖拽自适应
          final maxWidth = (constraints.maxWidth * 0.85).clamp(200.0, 900.0);
          return Container(
            margin: const EdgeInsets.symmetric(vertical: 4),
            constraints: BoxConstraints(maxWidth: maxWidth),
            child: Column(
              crossAxisAlignment:
                  isUser ? CrossAxisAlignment.end : CrossAxisAlignment.start,
              children: [
                // 附件区域
                if (attachments.isNotEmpty) ...[
                  _buildAttachments(),
                  const SizedBox(height: 4),
                ],
                // 主消息气泡
                if (content.isNotEmpty) _buildBubble(context),
                // 技能标签
                if (skillResult != null)
                  Padding(
                    padding: const EdgeInsets.only(top: 4),
                    child: Container(
                  padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
                  decoration: BoxDecoration(
                    color: Colors.green.shade50,
                    borderRadius: BorderRadius.circular(8),
                  ),
                  child: Text(
                    skillResult!,
                    style: TextStyle(fontSize: 11, color: Colors.green.shade700),
                  ),
                ),
              ),
            // 时间戳
            Padding(
              padding: const EdgeInsets.only(top: 2),
              child: Text(
                '${timestamp.hour.toString().padLeft(2, '0')}:'
                '${timestamp.minute.toString().padLeft(2, '0')}',
                style: TextStyle(fontSize: 10, color: Colors.grey.shade400),
              ),
            ),
          ],
        ),
      );
        },
      ),
    );
  }

  Widget _buildBubble(BuildContext context) {
    final bgColor = isUser
        ? const Color(0xFF4FC3F7)
        : isError
            ? Colors.red.shade50
            : Colors.white;

    return Container(
      decoration: BoxDecoration(
        color: bgColor,
        borderRadius: BorderRadius.only(
          topLeft: const Radius.circular(16),
          topRight: const Radius.circular(16),
          bottomLeft: Radius.circular(isUser ? 16 : 4),
          bottomRight: Radius.circular(isUser ? 4 : 16),
        ),
        boxShadow: [
          BoxShadow(
            color: Colors.black.withOpacity(0.05),
            blurRadius: 4,
            offset: const Offset(0, 1),
          ),
        ],
      ),
      clipBehavior: Clip.antiAlias,
      child: isUser
          ? _buildPlainText()
          : _buildRichContent(context),
    );
  }

  /// 用户消息 — 纯文本
  Widget _buildPlainText() {
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
      child: Text(
        content,
        style: TextStyle(
          fontSize: fontSize,
          color: Colors.white,
          height: 1.5,
        ),
      ),
    );
  }

  /// AI 消息 — 富文本渲染（Markdown 子集）
  Widget _buildRichContent(BuildContext context) {
    final textColor = isError ? Colors.red.shade700 : const Color(0xFF424242);

    // 检查是否包含代码块
    if (_hasCodeBlocks(content)) {
      return _buildMixedContent(context, textColor);
    }

    // 无代码块 → 渲染行内 Markdown
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
      child: _MarkdownText(text: content, textColor: textColor, fontSize: fontSize, scale: _scale),
    );
  }

  /// 包含代码块的混合内容
  Widget _buildMixedContent(BuildContext context, Color textColor) {
    final parts = _splitCodeBlocks(content);
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 8),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: parts.map((part) {
          if (part.isCode) {
            return CodeBlock(
              code: part.content,
              language: part.language,
            );
          }
          if (part.content.trim().isEmpty) return const SizedBox.shrink();
          return Padding(
            padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
            child: _MarkdownText(text: part.content, textColor: textColor, fontSize: fontSize, scale: _scale),
          );
        }).toList(),
      ),
    );
  }

  /// 附件区域
  Widget _buildAttachments() {
    return Column(
      crossAxisAlignment:
          isUser ? CrossAxisAlignment.end : CrossAxisAlignment.start,
      children: attachments.map((att) {
        switch (att.type) {
          case AttachmentType.image:
            return ImagePreview(attachment: att, isUser: isUser);
          case AttachmentType.file:
            return FileCard(attachment: att, isUser: isUser);
          case AttachmentType.code:
            return CodeBlock(
              code: att.code ?? '',
              language: att.language,
            );
        }
      }).toList(),
    );
  }

  bool _hasCodeBlocks(String text) {
    return RegExp(r'```[\s\S]*?```').hasMatch(text);
  }

  List<_ContentPart> _splitCodeBlocks(String text) {
    final parts = <_ContentPart>[];
    final regex = RegExp(r'```(\w*)\n?([\s\S]*?)```');
    int lastEnd = 0;

    for (final match in regex.allMatches(text)) {
      if (match.start > lastEnd) {
        final before = text.substring(lastEnd, match.start);
        if (before.trim().isNotEmpty) {
          parts.add(_ContentPart(content: before, isCode: false));
        }
      }
      parts.add(_ContentPart(
        content: match.group(2)?.trimRight() ?? '',
        isCode: true,
        language: match.group(1),
      ));
      lastEnd = match.end;
    }

    if (lastEnd < text.length) {
      final tail = text.substring(lastEnd);
      if (tail.trim().isNotEmpty) {
        parts.add(_ContentPart(content: tail, isCode: false));
      }
    }

    return parts;
  }
}

class _ContentPart {
  final String content;
  final bool isCode;
  final String? language;
  _ContentPart({required this.content, required this.isCode, this.language});
}

/// 自实现的轻量 Markdown 文本渲染
/// 支持：**粗体**、*斜体*、`行内代码`、[链接](url)、~~删除线~~、标题、列表、引用
class _MarkdownText extends StatelessWidget {
  final String text;
  final Color textColor;
  final double fontSize;
  final double scale;

  const _MarkdownText({
    required this.text,
    required this.textColor,
    this.fontSize = 14.0,
    this.scale = 1.0,
  });

  @override
  Widget build(BuildContext context) {
    final lines = text.split('\n');
    final widgets = <Widget>[];

    for (int i = 0; i < lines.length; i++) {
      final line = lines[i];

      // 空行
      if (line.trim().isEmpty) {
        widgets.add(const SizedBox(height: 6));
        continue;
      }

      // 标题
      if (line.startsWith('### ')) {
        widgets.add(_buildHeading(line.substring(4), fontSize * 1.07, FontWeight.w600));
        continue;
      }
      if (line.startsWith('## ')) {
        widgets.add(_buildHeading(line.substring(3), fontSize * 1.21, FontWeight.bold));
        continue;
      }
      if (line.startsWith('# ')) {
        widgets.add(_buildHeading(line.substring(2), fontSize * 1.36, FontWeight.bold));
        continue;
      }

      // 引用块
      if (line.startsWith('> ')) {
        widgets.add(_buildBlockquote(line.substring(2)));
        continue;
      }

      // 分割线
      if (RegExp(r'^-{3,}$|^\*{3,}$|^_{3,}$').hasMatch(line.trim())) {
        widgets.add(Padding(
          padding: const EdgeInsets.symmetric(vertical: 6),
          child: Divider(color: Colors.grey.shade300, height: 1),
        ));
        continue;
      }

      // 无序列表
      if (RegExp(r'^[\s]*[-*+]\s').hasMatch(line)) {
        final indent = line.indexOf(RegExp(r'[-*+]'));
        final content = line.replaceFirst(RegExp(r'^[\s]*[-*+]\s'), '');
        widgets.add(_buildListItem(content, indent: indent));
        continue;
      }

      // 有序列表
      if (RegExp(r'^[\s]*\d+\.\s').hasMatch(line)) {
        final match = RegExp(r'^([\s]*)(\d+)\.\s(.*)').firstMatch(line);
        if (match != null) {
          widgets.add(_buildOrderedListItem(match.group(3)!, match.group(2)!));
          continue;
        }
      }

      // 普通段落
      widgets.add(Padding(
        padding: const EdgeInsets.symmetric(vertical: 1),
        child: _buildInlineRichText(line),
      ));
    }

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: widgets,
    );
  }

  Widget _buildHeading(String text, double fontSize, FontWeight weight) {
    return Padding(
      padding: const EdgeInsets.only(top: 8, bottom: 4),
      child: _buildInlineRichText(text, baseStyle: TextStyle(
        fontSize: fontSize,
        fontWeight: weight,
        color: textColor,
        height: 1.4,
      )),
    );
  }

  Widget _buildBlockquote(String text) {
    return Container(
      margin: const EdgeInsets.symmetric(vertical: 4),
      padding: const EdgeInsets.fromLTRB(10, 6, 8, 6),
      decoration: BoxDecoration(
        border: Border(left: BorderSide(color: Colors.blue.shade300, width: 3)),
        color: Colors.blue.shade50,
        borderRadius: const BorderRadius.only(
          topRight: Radius.circular(4),
          bottomRight: Radius.circular(4),
        ),
      ),
      child: _buildInlineRichText(text, baseStyle: TextStyle(
        fontSize: fontSize * 0.93,
        color: Colors.blueGrey.shade700,
        fontStyle: FontStyle.italic,
        height: 1.5,
      )),
    );
  }

  Widget _buildListItem(String text, {int indent = 0}) {
    return Padding(
      padding: EdgeInsets.only(left: indent * 8.0 + 4, top: 2, bottom: 2),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Padding(
            padding: const EdgeInsets.only(top: 6, right: 6),
            child: Container(
              width: 5,
              height: 5,
              decoration: BoxDecoration(
                color: textColor.withOpacity(0.5),
                shape: BoxShape.circle,
              ),
            ),
          ),
          Expanded(child: _buildInlineRichText(text)),
        ],
      ),
    );
  }

  Widget _buildOrderedListItem(String text, String number) {
    return Padding(
      padding: const EdgeInsets.only(left: 4, top: 2, bottom: 2),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            '$number. ',
            style: TextStyle(
              fontSize: fontSize,
              color: textColor,
              fontWeight: FontWeight.w500,
              height: 1.6,
            ),
          ),
          Expanded(child: _buildInlineRichText(text)),
        ],
      ),
    );
  }

  /// 行内 Markdown 渲染
  Widget _buildInlineRichText(String text, {TextStyle? baseStyle}) {
    final style = baseStyle ?? TextStyle(fontSize: fontSize, color: textColor, height: 1.6);
    final spans = _parseInline(text, style);
    return Text.rich(
      TextSpan(children: spans),
    );
  }

  /// 解析行内 Markdown 格式
  List<InlineSpan> _parseInline(String text, TextStyle baseStyle) {
    final spans = <InlineSpan>[];

    // 用正则解析各种行内格式
    final regex = RegExp(
      r'(\*\*\*(.+?)\*\*\*)'        // ***粗斜体***  group(1,2)
      r'|(\*\*(.+?)\*\*)'           // **粗体**      group(3,4)
      r'|(\*(.+?)\*)'               // *斜体*        group(5,6)
      r'|(~~(.+?)~~)'               // ~~删除线~~    group(7,8)
      r'|(`([^`]+?)`)'              // `行内代码`    group(9,10)
      r'|(\[([^\]]+)\]\(([^)]+)\))' // [链接](url)   group(11,12,13)
    );

    int lastEnd = 0;
    for (final match in regex.allMatches(text)) {
      // 前面的普通文本
      if (match.start > lastEnd) {
        spans.add(TextSpan(
          text: text.substring(lastEnd, match.start),
          style: baseStyle,
        ));
      }

      if (match.group(2) != null) {
        // 粗斜体
        spans.add(TextSpan(
          text: match.group(2),
          style: baseStyle.copyWith(
            fontWeight: FontWeight.bold,
            fontStyle: FontStyle.italic,
          ),
        ));
      } else if (match.group(4) != null) {
        // 粗体
        spans.add(TextSpan(
          text: match.group(4),
          style: baseStyle.copyWith(fontWeight: FontWeight.bold),
        ));
      } else if (match.group(6) != null) {
        // 斜体
        spans.add(TextSpan(
          text: match.group(6),
          style: baseStyle.copyWith(fontStyle: FontStyle.italic),
        ));
      } else if (match.group(8) != null) {
        // 删除线
        spans.add(TextSpan(
          text: match.group(8),
          style: baseStyle.copyWith(decoration: TextDecoration.lineThrough),
        ));
      } else if (match.group(10) != null) {
        // 行内代码（使用TextSpan保持选择连续性）
        spans.add(TextSpan(
          text: ' ${match.group(10)} ',
          style: baseStyle.copyWith(
            fontSize: fontSize * 0.89,
            color: const Color(0xFFE06C75),
            fontFamily: 'Consolas',
            backgroundColor: const Color(0xFFF0F2F5),
          ),
        ));
      } else if (match.group(12) != null) {
        // 链接
        spans.add(TextSpan(
          text: match.group(12),
          style: baseStyle.copyWith(
            color: Colors.blue.shade600,
            decoration: TextDecoration.underline,
          ),
          recognizer: TapGestureRecognizer()
            ..onTap = () {
              final url = match.group(13);
              if (url != null) launchUrl(Uri.parse(url));
            },
        ));
      }

      lastEnd = match.end;
    }

    // 剩余文本
    if (lastEnd < text.length) {
      spans.add(TextSpan(
        text: text.substring(lastEnd),
        style: baseStyle,
      ));
    }

    if (spans.isEmpty) {
      spans.add(TextSpan(text: text, style: baseStyle));
    }

    return spans;
  }
}
