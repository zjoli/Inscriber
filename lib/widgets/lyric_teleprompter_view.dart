import 'dart:math' as math;
import 'package:flutter/material.dart';
import '../models/teleprompter_script.dart';

/// 音乐歌词式 3 行平滑滚动提词核心组件
/// - 严格控制可视区仅呈现 [settings.visibleLines] 行（默认 3 行）
/// - 配合 LyricLineSplitter.splitToFitWidth 自动换行，绝不出现“...”截断
/// - 背景默认完全透明，并根据文字明暗自动匹配高对比度描边阴影
class LyricTeleprompterView extends StatelessWidget {
  const LyricTeleprompterView({
    super.key,
    required this.lines,
    required this.progress,
    required this.settings,
    this.horizontalPadding = 12.0,
    this.onTap,
  });

  final List<String> lines;
  final double progress;
  final TeleprompterSettings settings;
  final double horizontalPadding;
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) {
    final visibleLines = settings.visibleLines.clamp(1, 5);
    final double lineHeight = settings.fontSize * 1.65;
    final double viewportHeight = lineHeight * visibleLines;
    final double centerY = viewportHeight / 2;

    final int centerIndex = progress.round();
    final int halfSpan = (visibleLines ~/ 2) + 2;
    final int startIndex = math.max(0, centerIndex - halfSpan);
    final int endIndex = math.min(lines.length - 1, centerIndex + halfSpan);

    // 根据主文字亮度自适应阴影色：深色字配柔和白光晕，浅色字配深色描边阴影
    final bool isDarkInk = settings.activeTextColor.computeLuminance() < 0.35;
    final shadows = settings.enableTextShadow
        ? (isDarkInk
            ? const <Shadow>[
                Shadow(
                  color: Color(0xCCFFFFFF),
                  blurRadius: 5,
                  offset: Offset(0, 0),
                ),
                Shadow(
                  color: Color(0x88FFFFFF),
                  blurRadius: 1.5,
                  offset: Offset(0, 1),
                ),
              ]
            : const <Shadow>[
                Shadow(
                  color: Color(0xDD000000),
                  blurRadius: 6,
                  offset: Offset(0, 1.5),
                ),
                Shadow(
                  color: Color(0xAA000000),
                  blurRadius: 2,
                  offset: Offset(0, 0),
                ),
              ])
        : null;

    Widget content = GestureDetector(
      behavior: HitTestBehavior.translucent,
      onTap: onTap,
      child: Container(
        height: viewportHeight,
        width: double.infinity,
        decoration: BoxDecoration(
          color: settings.backgroundOpacity <= 0.001
              ? Colors.transparent
              : Colors.black.withValues(
                  alpha: settings.backgroundOpacity.clamp(0.0, 0.9),
                ),
          borderRadius: BorderRadius.circular(14),
        ),
        child: ClipRect(
          child: Stack(
            clipBehavior: Clip.hardEdge,
            children: [
              for (int i = startIndex; i <= endIndex; i++)
                _buildLyricLine(
                  index: i,
                  text: lines[i],
                  lineHeight: lineHeight,
                  centerY: centerY,
                  visibleLines: visibleLines,
                  shadows: shadows,
                ),
            ],
          ),
        ),
      ),
    );

    if (settings.mirrorMode) {
      content = Transform.flip(
        flipX: true,
        child: content,
      );
    }

    return content;
  }

  Widget _buildLyricLine({
    required int index,
    required String text,
    required double lineHeight,
    required double centerY,
    required int visibleLines,
    required List<Shadow>? shadows,
  }) {
    final double delta = index - progress;
    final double absDelta = delta.abs();
    final double maxVisibleDelta = (visibleLines / 2.0) + 0.15;

    double opacity;
    if (absDelta >= maxVisibleDelta) {
      opacity = 0.0;
    } else if (absDelta <= 0.2) {
      opacity = 1.0;
    } else {
      final t = ((absDelta - 0.2) / (maxVisibleDelta - 0.2)).clamp(0.0, 1.0);
      final baseFade = delta < 0 ? 0.42 : 0.60;
      opacity = absDelta <= 1.0
          ? 1.0 - (1.0 - baseFade) * absDelta
          : baseFade * (1.0 - t);
    }

    final double focusFactor = (1.0 - absDelta.clamp(0.0, 1.0));
    final double scale = 0.90 + 0.12 * focusFactor;
    final Color color = Color.lerp(
          settings.inactiveTextColor,
          settings.activeTextColor,
          focusFactor,
        ) ??
        settings.activeTextColor;

    final double top = centerY + (delta * lineHeight) - (lineHeight / 2);

    return Positioned(
      left: horizontalPadding,
      right: horizontalPadding,
      top: top,
      height: lineHeight,
      child: Opacity(
        opacity: opacity.clamp(0.0, 1.0),
        child: Center(
          // 配合宽度自动换行，再加 FittedBox.scaleDown 作为最后防线，彻底杜绝 “...” 截断
          child: FittedBox(
            fit: BoxFit.scaleDown,
            alignment: Alignment.center,
            child: Transform.scale(
              scale: scale,
              alignment: Alignment.center,
              child: Text(
                text,
                maxLines: 1,
                softWrap: false,
                textAlign: TextAlign.center,
                style: TextStyle(
                  color: color,
                  fontSize: settings.fontSize,
                  fontWeight:
                      focusFactor > 0.55 ? FontWeight.w700 : FontWeight.w400,
                  height: 1.25,
                  letterSpacing: 0.4,
                  shadows: shadows,
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}
