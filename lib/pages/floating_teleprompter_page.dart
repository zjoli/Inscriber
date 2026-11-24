import 'dart:async';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/scheduler.dart';
import '../engine/line_splitter.dart';
import '../engine/scroll_driver.dart';
import '../models/teleprompter_script.dart';
import '../services/background_overlay_voice_controller.dart';
import '../services/overlay_channel.dart';
import '../services/voice_recognizer.dart';
import '../services/voice_recognizer_factory.dart';
import '../theme/app_theme.dart';
import '../widgets/lyric_teleprompter_view.dart';
import '../widgets/model_download_dialog.dart';

/// 页面 3：悬浮提词页（极简透明，仅保留 3 行音乐歌词式滚动提词）
/// - 支持「固定速率」与「AI 语音跟随」双模式，并可在悬浮页内一键切换
/// - 平时自动隐藏所有 UI 控件，仅呈现 3 行提词文字，其余背景完全透明
/// - AI 模式下实时采集麦克风语音 -> 拼音模糊对齐 -> 平滑跟读，且声波条随音量跳动
class FloatingTeleprompterPage extends StatefulWidget {
  const FloatingTeleprompterPage({
    super.key,
    required this.script,
    this.voiceRecognizer,
  });

  final TeleprompterScript script;
  final VoiceRecognizer? voiceRecognizer;

  @override
  State<FloatingTeleprompterPage> createState() =>
      _FloatingTeleprompterPageState();
}

class _FloatingTeleprompterPageState extends State<FloatingTeleprompterPage>
    with SingleTickerProviderStateMixin {
  late TeleprompterSettings _settings;
  late FixedRateScrollDriver _fixedDriver;
  late AiVoiceScrollDriver _voiceDriver;
  late VoiceRecognizer _voiceRecognizer;
  StreamSubscription<VoiceRecognitionEvent>? _voiceSub;

  late Ticker _ticker;
  Duration _lastElapsed = Duration.zero;

  bool _showControls = true;
  bool _pureTransparentCanvas = !kIsWeb;
  double _verticalFraction = 0.10;
  double _lastViewportWidth = 0;
  bool _loadingModel = false;
  Timer? _autoHideTimer;

  bool get _isAiMode => _settings.scrollMode == ScrollMode.aiVoice;
  ScrollDriver get _activeDriver => _isAiMode ? _voiceDriver : _fixedDriver;

  @override
  void initState() {
    super.initState();
    _settings = widget.script.settings;
    final lines = LyricLineSplitter.split(
      widget.script.content,
      maxCharsPerLine: _settings.maxCharsPerLine,
    );
    _fixedDriver = FixedRateScrollDriver(
      lines: lines,
      charsPerMinute: _settings.charsPerMinute,
    );
    _voiceDriver = AiVoiceScrollDriver(lines: lines);
    _voiceRecognizer = widget.voiceRecognizer ?? createDefaultVoiceRecognizer();
    _voiceSub = _voiceRecognizer.events.listen(_onVoiceEvent);

    _ticker = createTicker((elapsed) {
      final delta = _lastElapsed == Duration.zero
          ? Duration.zero
          : elapsed - _lastElapsed;
      _lastElapsed = elapsed;
      _activeDriver.tick(delta);
    })
      ..start();

    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) {
        _startActiveMode();
      }
    });
  }

  @override
  void dispose() {
    _autoHideTimer?.cancel();
    _voiceSub?.cancel();
    if (widget.voiceRecognizer == null) {
      _voiceRecognizer.dispose();
    } else {
      _voiceRecognizer.stopListening();
    }
    _ticker.dispose();
    _fixedDriver.dispose();
    _voiceDriver.dispose();
    super.dispose();
  }

  Future<void> _startActiveMode() async {
    if (_isAiMode) {
      _fixedDriver.pause();
      final modelReady = await ensureAiVoiceModelReady(context);
      if (!mounted) return;
      if (!modelReady) {
        // 用户取消了首次下载，平滑退回固定速率模式
        await _switchScrollMode(ScrollMode.fixedRate);
        return;
      }

      setState(() => _loadingModel = true);
      _voiceDriver.play();
      final started = await _voiceRecognizer.startListening();
      if (!mounted) return;
      setState(() => _loadingModel = false);
      if (started) {
        _scheduleHideControls();
      } else {
        _voiceDriver.pause();
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: const Text('未能启动麦克风语音跟随，可切换为固定速率滚动。'),
            action: SnackBarAction(
              label: '切回定速',
              textColor: AppColors.accentGreen,
              onPressed: () => _switchScrollMode(ScrollMode.fixedRate),
            ),
          ),
        );
      }
    } else {
      await _voiceRecognizer.stopListening();
      _voiceDriver.pause();
      _fixedDriver.play();
      _scheduleHideControls();
    }
  }

  void _onVoiceEvent(VoiceRecognitionEvent event) {
    if (!mounted || !_isAiMode) return;
    if (event.soundLevel != null) {
      _voiceDriver.updateSoundLevel(event.soundLevel!);
    }
    if (event.partialText != null && event.partialText!.isNotEmpty) {
      _voiceDriver.onPartialTranscript(event.partialText!);
    }
    if (event.errorMessage != null && event.errorMessage!.isNotEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(event.errorMessage!),
          action: SnackBarAction(
            label: '切回定速',
            textColor: AppColors.accentGreen,
            onPressed: () => _switchScrollMode(ScrollMode.fixedRate),
          ),
        ),
      );
      if (event.state == VoiceRecognizerState.error ||
          event.state == VoiceRecognizerState.unavailable) {
        _voiceDriver.pause();
      }
    }
  }

  Future<void> _switchScrollMode(ScrollMode targetMode) async {
    if (_settings.scrollMode == targetMode) return;
    final currentProgress = _activeDriver.progress;

    await _voiceRecognizer.stopListening();
    _fixedDriver.pause();
    _voiceDriver.pause();

    setState(() {
      _settings = _settings.copyWith(scrollMode: targetMode);
    });

    // 无缝承接当前朗读行位置，不重头跳回
    _activeDriver.seekToLine(currentProgress);
    await _startActiveMode();
  }

  Future<void> _togglePlayPause() async {
    if (_isAiMode) {
      if (_voiceDriver.isPlaying) {
        _voiceDriver.pause();
        await _voiceRecognizer.stopListening();
        _autoHideTimer?.cancel();
      } else {
        _voiceDriver.play();
        final ok = await _voiceRecognizer.startListening();
        if (!mounted) return;
        if (ok) {
          _scheduleHideControls();
        } else {
          _voiceDriver.pause();
        }
      }
    } else {
      _fixedDriver.togglePlay();
      if (_fixedDriver.isPlaying) {
        _scheduleHideControls();
      } else {
        _autoHideTimer?.cancel();
      }
    }
  }

  void _scheduleHideControls() {
    _autoHideTimer?.cancel();
    _autoHideTimer = Timer(const Duration(milliseconds: 2800), () {
      if (mounted && _activeDriver.isPlaying) {
        setState(() => _showControls = false);
      }
    });
  }

  void _revealControlsTemporarily() {
    setState(() => _showControls = true);
    _scheduleHideControls();
  }

  void _adjustSpeed(int deltaCpm) {
    final nextCpm = (_settings.charsPerMinute + deltaCpm).clamp(60, 360);
    setState(() {
      _settings = _settings.copyWith(charsPerMinute: nextCpm);
    });
    _fixedDriver.updateCharsPerMinute(nextCpm);
    OverlayChannel.updateOverlaySettings(_settings);
    _scheduleHideControls();
  }

  void _rewrapForWidth(double viewportWidth) {
    final availableTextWidth = (viewportWidth - 24.0).clamp(80.0, 1200.0);
    final wrapped = LyricLineSplitter.splitToFitWidth(
      widget.script.content,
      maxWidth: availableTextWidth,
      fontSize: _settings.fontSize,
      maxCharsPerLine: _settings.maxCharsPerLine,
    );
    _fixedDriver.updateLines(wrapped);
    _voiceDriver.updateLines(wrapped);
  }

  Future<void> _switchToSystemOverlay() async {
    final currentProgress = _activeDriver.progress;
    await _voiceRecognizer.stopListening();
    _fixedDriver.pause();
    _voiceDriver.pause();

    if (_isAiMode) {
      if (!mounted) return;
      final modelReady = await ensureAiVoiceModelReady(context);
      if (!mounted || !modelReady) return;
    }

    final result = await OverlayChannel.startOverlay(
      script: widget.script.copyWith(settings: _settings),
      lines: _activeDriver.lines,
    );
    if (!mounted) return;

    if (result.started && _isAiMode) {
      final voiceOk = await BackgroundOverlayVoiceController.instance.start(
        lines: _activeDriver.lines,
        initialLineProgress: currentProgress,
      );
      if (!mounted) return;
      if (!voiceOk) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('悬浮窗已启动，麦克风暂不可用，已自动降级为固定速率。')),
        );
        return;
      }
    } else if (result.started) {
      await BackgroundOverlayVoiceController.instance.stop();
    }

    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: Text(result.message)),
    );
  }

  @override
  Widget build(BuildContext context) {
    final screenHeight = MediaQuery.of(context).size.height;
    final topPadding = MediaQuery.of(context).padding.top;
    final overlayTop =
        (topPadding + (screenHeight - topPadding - 220) * _verticalFraction)
            .clamp(topPadding + 8.0, screenHeight - 180.0);
    final driver = _activeDriver;

    return Scaffold(
      backgroundColor: Colors.transparent,
      body: GestureDetector(
        behavior: HitTestBehavior.translucent,
        onTap: () {
          if (_showControls) {
            setState(() => _showControls = false);
          } else {
            _revealControlsTemporarily();
          }
        },
        child: Stack(
          fit: StackFit.expand,
          children: [
            if (!_pureTransparentCanvas) _buildSimulatedCameraBackdrop(),

            // 核心悬浮 3 行歌词提词区（自动按实际宽度换行，绝不出现“...”截断）
            Positioned(
              left: 12,
              right: 12,
              top: overlayTop,
              child: LayoutBuilder(
                builder: (context, constraints) {
                  if ((constraints.maxWidth - _lastViewportWidth).abs() > 1.0) {
                    _lastViewportWidth = constraints.maxWidth;
                    WidgetsBinding.instance.addPostFrameCallback((_) {
                      if (mounted) {
                        _rewrapForWidth(constraints.maxWidth);
                      }
                    });
                  }
                  return GestureDetector(
                    onVerticalDragUpdate: (details) {
                      setState(() {
                        _verticalFraction = (_verticalFraction +
                                details.delta.dy / (screenHeight * 0.7))
                            .clamp(0.0, 0.85);
                      });
                    },
                    child: ListenableBuilder(
                      listenable: driver,
                      builder: (_, __) => LyricTeleprompterView(
                        lines: driver.lines,
                        progress: driver.progress,
                        settings: _settings,
                        onTap: _revealControlsTemporarily,
                      ),
                    ),
                  );
                },
              ),
            ),

            // 顶部极简返回/模式与系统悬浮入口（播放时自动淡出）
            Positioned(
              left: 12,
              right: 12,
              top: topPadding + 6,
              child: IgnorePointer(
                ignoring: !_showControls,
                child: AnimatedOpacity(
                  duration: const Duration(milliseconds: 220),
                  opacity: _showControls ? 1.0 : 0.0,
                  child: Row(
                    children: [
                      _PaperPillButton(
                        icon: Icons.arrow_back,
                        label: '返回',
                        onTap: () => Navigator.of(context).pop(),
                      ),
                      const Spacer(),
                      _PaperPillButton(
                        icon: _pureTransparentCanvas
                            ? Icons.wallpaper_outlined
                            : Icons.opacity,
                        label: _pureTransparentCanvas ? '模拟底图' : '纯透明',
                        onTap: () {
                          setState(() {
                            _pureTransparentCanvas = !_pureTransparentCanvas;
                          });
                          _scheduleHideControls();
                        },
                      ),
                      const SizedBox(width: 8),
                      _PaperPillButton(
                        icon: Icons.picture_in_picture_alt,
                        label: '跨应用悬浮',
                        primary: true,
                        onTap: _switchToSystemOverlay,
                      ),
                    ],
                  ),
                ),
              ),
            ),

            // 底部极简胶囊控制栏（参考 Granola 底部风格，支持定速 ↔ AI语音一键切换）
            Positioned(
              left: 16,
              right: 16,
              bottom: MediaQuery.of(context).padding.bottom + 20,
              child: IgnorePointer(
                ignoring: !_showControls,
                child: AnimatedOpacity(
                  duration: const Duration(milliseconds: 220),
                  opacity: _showControls ? 1.0 : 0.0,
                  child: _buildFloatingControlDock(),
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildFloatingControlDock() {
    final driver = _activeDriver;
    return ListenableBuilder(
      listenable: driver,
      builder: (_, __) {
        return Container(
          padding: const EdgeInsets.fromLTRB(14, 10, 14, 12),
          decoration: BoxDecoration(
            color: AppColors.background.withValues(alpha: 0.95),
            borderRadius: BorderRadius.circular(28),
            border: Border.all(color: AppColors.border),
            boxShadow: const [
              BoxShadow(
                color: Color(0x28000000),
                blurRadius: 20,
                offset: Offset(0, 8),
              ),
            ],
          ),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              // AI 模式实时识别与加载状态回显条
              if (_isAiMode)
                Padding(
                  padding: const EdgeInsets.only(bottom: 4),
                  child: Row(
                    children: [
                      if (_loadingModel)
                        const SizedBox(
                          width: 13,
                          height: 13,
                          child: CircularProgressIndicator(
                            strokeWidth: 2,
                            color: AppColors.accentGreenDark,
                          ),
                        )
                      else
                        Icon(
                          driver.isPlaying
                              ? Icons.mic_rounded
                              : Icons.mic_off_rounded,
                          size: 14,
                          color: driver.isPlaying
                              ? AppColors.accentGreenDark
                              : AppColors.inkTertiary,
                        ),
                      const SizedBox(width: 6),
                      Expanded(
                        child: Text(
                          _loadingModel
                              ? '正在加载离线语音模型，请稍候…'
                              : (_voiceDriver.lastRecognizedText.isNotEmpty
                                  ? '正在跟读：${_voiceDriver.lastRecognizedText}'
                                  : (driver.isPlaying
                                      ? 'AI 语音监听中，请自然朗读当前台词…'
                                      : 'AI 语音跟随已暂停')),
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: const TextStyle(
                            fontSize: 11.5,
                            color: AppColors.inkSecondary,
                          ),
                        ),
                      ),
                    ],
                  ),
                ),

              // 进度微调条（支持拖动后 AI 语音立即从新行继续对齐）
              Row(
                children: [
                  Text(
                    '第 ${driver.currentLineIndex + 1}/${driver.lines.length} 行',
                    style: const TextStyle(
                      fontSize: 11.5,
                      color: AppColors.inkSecondary,
                      fontWeight: FontWeight.w500,
                    ),
                  ),
                  Expanded(
                    child: SliderTheme(
                      data: SliderTheme.of(context).copyWith(
                        trackHeight: 2.8,
                        thumbShape: const RoundSliderThumbShape(
                          enabledThumbRadius: 6,
                        ),
                      ),
                      child: Slider(
                        value: driver.progress.clamp(0.0, driver.maxProgress),
                        min: 0.0,
                        max: driver.maxProgress <= 0 ? 1.0 : driver.maxProgress,
                        onChanged: driver.maxProgress <= 0
                            ? null
                            : (v) {
                                driver.seekToLine(v);
                                _scheduleHideControls();
                              },
                      ),
                    ),
                  ),
                  // 一键切换：固定速率 ↔ AI 语音
                  GestureDetector(
                    onTap: () => _switchScrollMode(
                      _isAiMode ? ScrollMode.fixedRate : ScrollMode.aiVoice,
                    ),
                    child: Container(
                      padding: const EdgeInsets.symmetric(
                        horizontal: 8,
                        vertical: 3,
                      ),
                      decoration: BoxDecoration(
                        color: _isAiMode
                            ? AppColors.accentGreenSoft
                            : AppColors.chipBackground,
                        borderRadius: BorderRadius.circular(999),
                        border: Border.all(
                          color: _isAiMode
                              ? AppColors.accentGreen.withValues(alpha: 0.4)
                              : AppColors.border,
                        ),
                      ),
                      child: Text(
                        _isAiMode
                            ? 'AI 语音'
                            : '${_settings.charsPerMinute}字/分',
                        style: TextStyle(
                          fontSize: 11,
                          color: _isAiMode
                              ? AppColors.accentGreenDark
                              : AppColors.inkSecondary,
                          fontWeight: FontWeight.w600,
                        ),
                      ),
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 2),
              Row(
                children: [
                  // 左侧纯白暂停/继续大胶囊（Granola 风格）
                  GestureDetector(
                    onTap: _togglePlayPause,
                    child: Container(
                      width: 66,
                      height: 44,
                      decoration: BoxDecoration(
                        color: AppColors.surface,
                        borderRadius: BorderRadius.circular(999),
                        border: Border.all(color: AppColors.border),
                      ),
                      child: Icon(
                        driver.isPlaying
                            ? Icons.pause_rounded
                            : (_isAiMode
                                ? Icons.mic_rounded
                                : Icons.play_arrow_rounded),
                        color: AppColors.inkPrimary,
                        size: 25,
                      ),
                    ),
                  ),
                  const Spacer(),
                  // 中间鲜活绿色实时声波 + 快捷操作
                  _LiveGreenIndicator(
                    playing: driver.isPlaying,
                    level: _isAiMode ? _voiceDriver.soundLevel : 0.65,
                  ),
                  const SizedBox(width: 6),
                  if (!_isAiMode) ...[
                    IconButton(
                      tooltip: '减速 (-20 字/分)',
                      icon: const Icon(
                        Icons.remove_circle_outline,
                        color: AppColors.inkSecondary,
                        size: 21,
                      ),
                      visualDensity: VisualDensity.compact,
                      onPressed: () => _adjustSpeed(-20),
                    ),
                    IconButton(
                      tooltip: '加速 (+20 字/分)',
                      icon: const Icon(
                        Icons.add_circle_outline,
                        color: AppColors.inkSecondary,
                        size: 21,
                      ),
                      visualDensity: VisualDensity.compact,
                      onPressed: () => _adjustSpeed(20),
                    ),
                  ] else
                    TextButton.icon(
                      onPressed: () => _switchScrollMode(ScrollMode.fixedRate),
                      style: TextButton.styleFrom(
                        foregroundColor: AppColors.inkSecondary,
                        padding: const EdgeInsets.symmetric(horizontal: 8),
                        visualDensity: VisualDensity.compact,
                      ),
                      icon: const Icon(Icons.speed, size: 16),
                      label: const Text('切定速', style: TextStyle(fontSize: 12)),
                    ),
                  IconButton(
                    tooltip: '回到开头',
                    icon: const Icon(
                      Icons.replay,
                      color: AppColors.inkSecondary,
                      size: 20,
                    ),
                    visualDensity: VisualDensity.compact,
                    onPressed: () {
                      driver.reset();
                      _startActiveMode();
                    },
                  ),
                  const Spacer(),
                  // 右侧炭黑隐藏胶囊
                  GestureDetector(
                    onTap: () => setState(() => _showControls = false),
                    child: Container(
                      height: 44,
                      padding: const EdgeInsets.symmetric(horizontal: 18),
                      decoration: BoxDecoration(
                        color: AppColors.inkPrimary,
                        borderRadius: BorderRadius.circular(999),
                      ),
                      alignment: Alignment.center,
                      child: const Text(
                        '隐藏',
                        style: TextStyle(
                          color: Colors.white,
                          fontSize: 13.5,
                          fontWeight: FontWeight.w600,
                        ),
                      ),
                    ),
                  ),
                ],
              ),
            ],
          ),
        );
      },
    );
  }

  Widget _buildSimulatedCameraBackdrop() {
    final bool isDarkInk = _settings.activeTextColor.computeLuminance() < 0.35;
    final Color hintInk = isDarkInk
        ? AppColors.inkPrimary.withValues(alpha: 0.32)
        : Colors.white.withValues(alpha: 0.28);

    return Container(
      decoration: BoxDecoration(
        gradient: LinearGradient(
          colors: isDarkInk
              ? const [Color(0xFFEBE9E2), Color(0xFFE1DFD7), Color(0xFFE8E6DF)]
              : const [Color(0xFF2B2E2B), Color(0xFF3A3E39), Color(0xFF262724)],
          begin: Alignment.topCenter,
          end: Alignment.bottomCenter,
        ),
      ),
      child: Stack(
        fit: StackFit.expand,
        children: [
          Center(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                Icon(
                  _isAiMode
                      ? Icons.graphic_eq_rounded
                      : Icons.videocam_outlined,
                  size: 52,
                  color: hintInk.withValues(alpha: 0.5),
                ),
                const SizedBox(height: 10),
                Text(
                  _isAiMode
                      ? '模拟其他应用画面（AI 语音跟随模式）\n请直接对着麦克风朗读台词\n提词会自动跟随你的语速平滑滚动'
                      : '模拟其他应用画面\n提词区背景透明，仅浮现 3 行自动换行字幕\n上下拖动提词区可贴近镜头',
                  textAlign: TextAlign.center,
                  style: TextStyle(
                    color: hintInk,
                    fontSize: 13.5,
                    height: 1.65,
                  ),
                ),
              ],
            ),
          ),
          Positioned(
            bottom: 36,
            left: 0,
            right: 0,
            child: IgnorePointer(
              child: Center(
                child: Container(
                  width: 64,
                  height: 64,
                  decoration: BoxDecoration(
                    shape: BoxShape.circle,
                    border: Border.all(
                      color: hintInk,
                      width: 3.5,
                    ),
                  ),
                  padding: const EdgeInsets.all(5),
                  child: Container(
                    decoration: BoxDecoration(
                      shape: BoxShape.circle,
                      color: AppColors.danger.withValues(alpha: 0.55),
                    ),
                  ),
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }
}

class _LiveGreenIndicator extends StatelessWidget {
  const _LiveGreenIndicator({
    required this.playing,
    this.level = 0.6,
  });

  final bool playing;
  final double level;

  @override
  Widget build(BuildContext context) {
    final boost = playing ? (0.45 + level.clamp(0.0, 1.0) * 1.0) : 0.35;
    final baseHeights = [10.0, 14.0, 17.0, 11.0, 8.0];
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: baseHeights.map((h) {
        return AnimatedContainer(
          duration: const Duration(milliseconds: 110),
          width: 3,
          height: (h * boost).clamp(4.0, 20.0),
          margin: const EdgeInsets.symmetric(horizontal: 1.2),
          decoration: BoxDecoration(
            color: playing
                ? AppColors.accentGreen
                : AppColors.inkTertiary.withValues(alpha: 0.5),
            borderRadius: BorderRadius.circular(2),
          ),
        );
      }).toList(),
    );
  }
}

class _PaperPillButton extends StatelessWidget {
  const _PaperPillButton({
    required this.icon,
    required this.label,
    required this.onTap,
    this.primary = false,
  });

  final IconData icon;
  final String label;
  final VoidCallback onTap;
  final bool primary;

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onTap: onTap,
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 13, vertical: 8),
        decoration: BoxDecoration(
          color: primary
              ? AppColors.inkPrimary
              : AppColors.surface.withValues(alpha: 0.94),
          borderRadius: BorderRadius.circular(999),
          border: Border.all(
            color: primary ? AppColors.inkPrimary : AppColors.border,
          ),
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(
              icon,
              size: 15.5,
              color: primary ? Colors.white : AppColors.inkPrimary,
            ),
            const SizedBox(width: 5),
            Text(
              label,
              style: TextStyle(
                fontSize: 12.5,
                color: primary ? Colors.white : AppColors.inkPrimary,
                fontWeight: FontWeight.w600,
              ),
            ),
          ],
        ),
      ),
    );
  }
}
