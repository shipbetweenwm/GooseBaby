import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

/// 代码块组件 — 自实现语法高亮、行号、复制按钮（无需外部依赖）
class CodeBlock extends StatefulWidget {
  final String code;
  final String? language;
  final bool showLineNumbers;

  const CodeBlock({
    super.key,
    required this.code,
    this.language,
    this.showLineNumbers = true,
  });

  @override
  State<CodeBlock> createState() => _CodeBlockState();
}

class _CodeBlockState extends State<CodeBlock> {
  bool _copied = false;

  void _copyToClipboard() {
    Clipboard.setData(ClipboardData(text: widget.code));
    setState(() => _copied = true);
    Future.delayed(const Duration(seconds: 2), () {
      if (mounted) setState(() => _copied = false);
    });
  }

  @override
  Widget build(BuildContext context) {
    final lang = widget.language?.toLowerCase().trim();
    final lines = widget.code.split('\n');

    return Container(
      margin: const EdgeInsets.symmetric(vertical: 6),
      decoration: BoxDecoration(
        color: const Color(0xFF1E1E2E),
        borderRadius: BorderRadius.circular(10),
        border: Border.all(color: const Color(0xFF313244), width: 0.5),
      ),
      clipBehavior: Clip.antiAlias,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          _buildToolbar(lang),
          _buildCodeArea(lines),
        ],
      ),
    );
  }

  Widget _buildToolbar(String? lang) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
      decoration: const BoxDecoration(
        color: Color(0xFF181825),
        border: Border(bottom: BorderSide(color: Color(0xFF313244), width: 0.5)),
      ),
      child: Row(
        children: [
          // 三个装饰点（macOS 风格）
          Row(
            children: [
              _dot(const Color(0xFFED6A5E)),
              const SizedBox(width: 6),
              _dot(const Color(0xFFF5BF4F)),
              const SizedBox(width: 6),
              _dot(const Color(0xFF62C554)),
            ],
          ),
          const SizedBox(width: 12),
          // 语言标签
          if (lang != null && lang.isNotEmpty)
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
              decoration: BoxDecoration(
                color: const Color(0xFF313244),
                borderRadius: BorderRadius.circular(4),
              ),
              child: Text(
                lang,
                style: const TextStyle(
                  fontSize: 11,
                  color: Color(0xFF6C7086),
                  fontFamily: 'Consolas',
                ),
              ),
            ),
          const Spacer(),
          // 复制按钮
          InkWell(
            onTap: _copyToClipboard,
            borderRadius: BorderRadius.circular(4),
            child: Padding(
              padding: const EdgeInsets.all(4),
              child: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Icon(
                    _copied ? Icons.check : Icons.copy_rounded,
                    size: 14,
                    color: _copied ? const Color(0xFFA6E3A1) : const Color(0xFF6C7086),
                  ),
                  const SizedBox(width: 4),
                  Text(
                    _copied ? '已复制' : '复制',
                    style: TextStyle(
                      fontSize: 11,
                      color: _copied ? const Color(0xFFA6E3A1) : const Color(0xFF6C7086),
                    ),
                  ),
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _dot(Color color) {
    return Container(
      width: 10,
      height: 10,
      decoration: BoxDecoration(color: color, shape: BoxShape.circle),
    );
  }

  Widget _buildCodeArea(List<String> lines) {
    return Scrollbar(
        child: SingleChildScrollView(
          child: SingleChildScrollView(
            scrollDirection: Axis.horizontal,
            child: IntrinsicHeight(
              child: Row(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  // 行号列
                  if (widget.showLineNumbers)
                    Container(
                      padding: const EdgeInsets.symmetric(vertical: 12, horizontal: 10),
                      decoration: const BoxDecoration(
                        border: Border(right: BorderSide(color: Color(0xFF313244), width: 0.5)),
                      ),
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.end,
                        children: List.generate(lines.length, (i) {
                          return SizedBox(
                            height: 20,
                            child: Text(
                              '${i + 1}',
                              style: const TextStyle(
                                fontSize: 12,
                                color: Color(0xFF585B70),
                                fontFamily: 'Consolas',
                                height: 1.67,
                              ),
                            ),
                          );
                        }),
                      ),
                    ),
                  // 代码内容（简单高亮）
                  Padding(
                    padding: const EdgeInsets.all(12),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: lines.map((line) {
                        return SizedBox(
                          height: 20,
                          child: _buildHighlightedLine(line),
                        );
                      }).toList(),
                    ),
                  ),
                ],
              ),
            ),
          ),
        ),
    );
  }

  /// 简单的语法高亮（关键字、字符串、注释、数字）
  Widget _buildHighlightedLine(String line) {
    final spans = _highlightLine(line);
    return RichText(
      text: TextSpan(
        style: const TextStyle(
          fontSize: 13,
          fontFamily: 'Consolas',
          height: 1.54,
          color: Color(0xFFCDD6F4), // 默认文本色
        ),
        children: spans,
      ),
    );
  }

  List<TextSpan> _highlightLine(String line) {
    final spans = <TextSpan>[];
    final lang = widget.language?.toLowerCase() ?? '';

    // 注释检测
    if (_isComment(line.trimLeft(), lang)) {
      spans.add(TextSpan(
        text: line,
        style: const TextStyle(color: Color(0xFF6C7086), fontStyle: FontStyle.italic),
      ));
      return spans;
    }

    // 用正则匹配进行简单高亮
    final regex = RegExp(
      r'("(?:[^"\\]|\\.)*"' // 双引号字符串
      r"|'(?:[^'\\]|\\.)*')" // 单引号字符串  → group(1)
      r'|(\b\d+\.?\d*\b)' // 数字 → group(2)
      r'|(\b(?:import|export|from|as|class|extends|implements|abstract|final|const|var|let|static|void|int|double|String|bool|List|Map|Set|dynamic|return|if|else|for|while|do|switch|case|break|continue|try|catch|finally|throw|new|this|super|async|await|yield|enum|typedef|mixin|with|get|set|required|late|override|null|true|false|function|def|self|print|struct|interface|package|public|private|protected|fn|pub|mod|use|impl|trait|type|val|fun|object|companion|sealed|data|when|is|in|not|and|or|elif|except|pass|raise|lambda|None|True|False)\b)' // 关键字 → group(3)
      r'|(@\w+)' // 注解/装饰器 → group(4)
      r'|((?://|#).*$)' // 行内注释 → group(5)
    );

    int lastEnd = 0;
    for (final match in regex.allMatches(line)) {
      // 匹配前的普通文本
      if (match.start > lastEnd) {
        spans.add(TextSpan(text: line.substring(lastEnd, match.start)));
      }

      if (match.group(1) != null) {
        // 字符串 → 绿色
        spans.add(TextSpan(
          text: match.group(0),
          style: const TextStyle(color: Color(0xFFA6E3A1)),
        ));
      } else if (match.group(2) != null) {
        // 数字 → 橙色
        spans.add(TextSpan(
          text: match.group(0),
          style: const TextStyle(color: Color(0xFFFAB387)),
        ));
      } else if (match.group(3) != null) {
        // 关键字 → 紫色
        spans.add(TextSpan(
          text: match.group(0),
          style: const TextStyle(color: Color(0xFFCBA6F7), fontWeight: FontWeight.w500),
        ));
      } else if (match.group(4) != null) {
        // 注解 → 黄色
        spans.add(TextSpan(
          text: match.group(0),
          style: const TextStyle(color: Color(0xFFF9E2AF)),
        ));
      } else if (match.group(5) != null) {
        // 注释 → 灰色
        spans.add(TextSpan(
          text: match.group(0),
          style: const TextStyle(color: Color(0xFF6C7086), fontStyle: FontStyle.italic),
        ));
      }

      lastEnd = match.end;
    }

    // 剩余文本
    if (lastEnd < line.length) {
      spans.add(TextSpan(text: line.substring(lastEnd)));
    }

    if (spans.isEmpty) {
      spans.add(TextSpan(text: line));
    }

    return spans;
  }

  bool _isComment(String trimmed, String lang) {
    if (trimmed.startsWith('//') || trimmed.startsWith('#')) return true;
    if (trimmed.startsWith('/*') || trimmed.startsWith('*')) return true;
    if (trimmed.startsWith('--') && (lang == 'sql' || lang == 'lua')) return true;
    return false;
  }
}
