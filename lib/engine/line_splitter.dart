import 'package:flutter/painting.dart';

/// 将完整提词文本按自然语义与真实像素宽度自动换行为“歌词行”列表
/// 保证在任何字号和屏幕宽度下，每一行都能完整显示，绝不出现“...”截断
class LyricLineSplitter {
  static final RegExp _punctuationRegex =
      RegExp(r'[，。！？；：、,.!?;:）)】」》\s]');

  /// 基于视觉字符数的快速断句（适用于无法测量像素宽度的纯逻辑场景）
  static List<String> split(String content, {int maxCharsPerLine = 16}) {
    final normalized = content.replaceAll('\r\n', '\n').trim();
    if (normalized.isEmpty) {
      return const ['（暂无提词内容）'];
    }

    final safeLimit = maxCharsPerLine.clamp(6, 40).toDouble();
    final result = <String>[];

    for (final rawParagraph in normalized.split('\n')) {
      final paragraph = rawParagraph.trim();
      if (paragraph.isEmpty) continue;
      result.addAll(_splitParagraphByUnits(paragraph, safeLimit));
    }

    return result.isEmpty ? const ['（暂无提词内容）'] : result;
  }

  /// 基于真实渲染宽度的自动换行（核心防截断机制）
  /// 使用当前高亮行放大后的真实 [TextStyle] 与容器可用像素宽度 [maxWidth] 测量，
  /// 确保每行 100% 完整展示，绝不省略任何文字。
  static List<String> splitToFitWidth(
    String content, {
    required double maxWidth,
    required double fontSize,
    int maxCharsPerLine = 24,
    double activeScale = 1.04,
    double letterSpacing = 0.4,
    TextDirection textDirection = TextDirection.ltr,
  }) {
    final normalized = content.replaceAll('\r\n', '\n').trim();
    if (normalized.isEmpty) {
      return const ['（暂无提词内容）'];
    }

    // 留出 8px 安全余量，防止字距微调或粗体放大导致边缘裁剪
    final safeWidth = (maxWidth - 8.0).clamp(60.0, 2000.0);
    final measureStyle = TextStyle(
      fontSize: fontSize * activeScale,
      fontWeight: FontWeight.w700,
      letterSpacing: letterSpacing,
      height: 1.25,
    );

    final painter = TextPainter(
      textDirection: textDirection,
      maxLines: 1,
    );

    double measureWidth(String text) {
      painter.text = TextSpan(text: text, style: measureStyle);
      painter.layout();
      return painter.width;
    }

    final safeUnitLimit = maxCharsPerLine.clamp(6, 40).toDouble();
    final result = <String>[];

    for (final rawParagraph in normalized.split('\n')) {
      final paragraph = rawParagraph.trim();
      if (paragraph.isEmpty) continue;
      result.addAll(
        _wrapParagraphToWidth(
          paragraph,
          safeWidth: safeWidth,
          maxUnits: safeUnitLimit,
          measureWidth: measureWidth,
        ),
      );
    }

    painter.dispose();
    return result.isEmpty ? const ['（暂无提词内容）'] : result;
  }

  static List<String> _wrapParagraphToWidth(
    String paragraph, {
    required double safeWidth,
    required double maxUnits,
    required double Function(String) measureWidth,
  }) {
    final lines = <String>[];
    final chars = paragraph.runes.map(String.fromCharCode).toList();
    int start = 0;

    while (start < chars.length) {
      // 跳过行首多余空白
      while (start < chars.length && chars[start].trim().isEmpty) {
        start++;
      }
      if (start >= chars.length) break;

      int end = start;
      double units = 0;
      int lastPunctuationEnd = -1;
      int lastSpaceEnd = -1;

      while (end < chars.length) {
        final nextChar = chars[end];
        final candidate = chars.sublist(start, end + 1).join();
        final nextUnits = units + _charVisualWeight(nextChar.runes.first);
        final exceedsWidth = measureWidth(candidate) > safeWidth;
        final exceedsUnits = nextUnits > maxUnits;

        if (end > start && (exceedsWidth || exceedsUnits)) {
          break;
        }

        end++;
        units = nextUnits;

        if (_punctuationRegex.hasMatch(nextChar)) {
          lastPunctuationEnd = end;
        }
        if (nextChar == ' ') {
          lastSpaceEnd = end;
        }
      }

      // 如果还没到段落末尾，优先在后半行的标点或英文空格处自然断行
      int splitAt = end;
      if (end < chars.length) {
        final minPreferredBreak = start + ((end - start) * 0.55).floor();
        if (lastPunctuationEnd > minPreferredBreak &&
            lastPunctuationEnd <= end) {
          splitAt = lastPunctuationEnd;
        } else if (lastSpaceEnd > minPreferredBreak && lastSpaceEnd <= end) {
          splitAt = lastSpaceEnd;
        }
      }

      // 兜底：至少推进 1 个字符，避免死循环
      if (splitAt <= start) {
        splitAt = start + 1;
      }

      final line = chars.sublist(start, splitAt).join().trim();
      if (line.isNotEmpty) {
        lines.add(line);
      }
      start = splitAt;
    }

    return lines;
  }

  static List<String> _splitParagraphByUnits(
    String paragraph,
    double maxUnits,
  ) {
    final lines = <String>[];
    final buffer = StringBuffer();
    double units = 0;
    int lastBreakIndexInBuffer = -1;

    final runes = paragraph.runes.toList();
    for (int i = 0; i < runes.length; i++) {
      final ch = String.fromCharCode(runes[i]);
      final charWeight = _charVisualWeight(runes[i]);

      buffer.write(ch);
      units += charWeight;

      if (_punctuationRegex.hasMatch(ch)) {
        lastBreakIndexInBuffer = buffer.length;
      }

      if (units >= maxUnits) {
        final current = buffer.toString();
        if (lastBreakIndexInBuffer > 0 &&
            lastBreakIndexInBuffer >= (current.length * 0.55).floor()) {
          final head = current.substring(0, lastBreakIndexInBuffer).trim();
          final tail = current.substring(lastBreakIndexInBuffer).trim();
          if (head.isNotEmpty) {
            lines.add(head);
          }
          buffer.clear();
          buffer.write(tail);
          units = _measureUnits(tail);
          lastBreakIndexInBuffer = -1;
        } else {
          final trimmed = current.trim();
          if (trimmed.isNotEmpty) {
            lines.add(trimmed);
          }
          buffer.clear();
          units = 0;
          lastBreakIndexInBuffer = -1;
        }
      }
    }

    final remaining = buffer.toString().trim();
    if (remaining.isNotEmpty) {
      lines.add(remaining);
    }

    return lines;
  }

  static double _measureUnits(String text) {
    double sum = 0;
    for (final r in text.runes) {
      sum += _charVisualWeight(r);
    }
    return sum;
  }

  /// 中文及全角字符记 1.0，英文/数字/半角标点记 0.55
  static double _charVisualWeight(int rune) {
    if (rune <= 0x007F) {
      return 0.55;
    }
    return 1.0;
  }

  /// 计算单行有效朗读字数（用于固定速率下计算该行停留时长）
  static int countReadableUnits(String line) {
    final stripped = line.replaceAll(RegExp(r'[\s，。！？；：、,.!?;:]'), '');
    if (stripped.isEmpty) return 1;
    double sum = 0;
    for (final r in stripped.runes) {
      sum += _charVisualWeight(r);
    }
    return sum.ceil().clamp(1, 200);
  }
}
