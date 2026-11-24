import 'dart:async';
import 'package:flutter/material.dart';
import 'package:flutter/scheduler.dart';
import '../engine/line_splitter.dart';
import '../engine/scroll_driver.dart';
import '../models/teleprompter_script.dart';
import '../services/offline_model_manager.dart';
import '../services/overlay_channel.dart';
import '../services/script_repository.dart';
import '../services/voice_recognizer.dart';
import '../services/voice_recognizer_factory.dart';
import '../theme/app_theme.dart';
import '../widgets/lyric_teleprompter_view.dart';
import '../widgets/model_download_dialog.dart';
import 'floating_teleprompter_page.dart';

/// 页面 2：选中某个提词并配置滚动模式（固定速率 / AI 语音跟随）、外观与文本内容
class ScriptSettingsPage extends StatefulWidget {
  const ScriptSettingsPage({
    super.key,
    required this.script,
    required this.repository,
    this.voiceRecognizer,
  });

  final TeleprompterScript script;
  final ScriptRepository repository;

  /// 允许测试时注入自定义识别器，默认使用跨平台 SystemSpeechVoiceRecognizer
  final VoiceRecognizer? voiceRecognizer;

  @override
  State<ScriptSettingsPage> createState() => _ScriptSettingsPageState();
}

class _ScriptSettingsPageState extends State<ScriptSettingsPage>
    with SingleTickerProviderStateMixin {
  late TeleprompterScript _script;
  late TextEditingController _titleController;
  late TextEditingController _contentController;

  late FixedRateScrollDriver _fixedDriver;
  late AiVoiceScrollDriver _voiceDriver;
  late VoiceRecognizer _voiceRecognizer;
  StreamSubscription<VoiceRecognitionEvent>? _voiceSub;

  late Ticker _ticker;
  Duration _lastElapsed = Duration.zero;
  bool _dirty = false;
  bool _previewDarkBackdrop = false;
  double _lastPreviewWidth = 0;
  bool _offlineModelReady = false;
  bool _loadingRecognizer = false;

  static const List<int> _presetTextColors = [
    0xFF20201E, // 炭黑（默认，适配暖纸/浅色画面）
    0xFF2E6B1E, // 森林绿
    0xFFFFFFFF, // 纯白（适合深色/相机画面）
    0xFFFFF59D, // 暖黄
    0xFF90CAF9, // 天空蓝
  ];

  ScrollDriver get _activeDriver =>
      _script.settings.scrollMode == ScrollMode.aiVoice
          ? _voiceDriver
          : _fixedDriver;

  bool get _isAiMode => _script.settings.scrollMode == ScrollMode.aiVoice;

  @override
  void initState() {
    super.initState();
    _script = widget.script;
    _titleController = TextEditingController(text: _script.title);
    _contentController = TextEditingController(text: _script.content);

    final lines = LyricLineSplitter.split(
      _script.content,
      maxCharsPerLine: _script.settings.maxCharsPerLine,
    );
    _fixedDriver = FixedRateScrollDriver(
      lines: lines,
      charsPerMinute: _script.settings.charsPerMinute,
    );
    _voiceDriver = AiVoiceScrollDriver(lines: lines);
    _voiceRecognizer = widget.voiceRecognizer ?? createDefaultVoiceRecognizer();
    _voiceSub = _voiceRecognizer.events.listen(_onVoiceEvent);
    _refreshOfflineModelStatus();

    _ticker = createTicker((elapsed) {
      final delta = _lastElapsed == Duration.zero
          ? Duration.zero
          : elapsed - _lastElapsed;
      _lastElapsed = elapsed;
      _activeDriver.tick(delta);
    })
      ..start();
  }

  @override
  void dispose() {
    _voiceSub?.cancel();
    if (widget.voiceRecognizer == null) {
      _voiceRecognizer.dispose();
    } else {
      _voiceRecognizer.stopListening();
    }
    _ticker.dispose();
    _fixedDriver.dispose();
    _voiceDriver.dispose();
    _titleController.dispose();
    _contentController.dispose();
    super.dispose();
  }

  void _onVoiceEvent(VoiceRecognitionEvent event) {
    if (!mounted) return;
    if (event.soundLevel != null) {
      _voiceDriver.updateSoundLevel(event.soundLevel!);
    }
    if (event.partialText != null && event.partialText!.isNotEmpty) {
      _voiceDriver.onPartialTranscript(event.partialText!);
    }
    if (event.errorMessage != null && event.errorMessage!.isNotEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text(event.errorMessage!)),
      );
      if (event.state == VoiceRecognizerState.error ||
          event.state == VoiceRecognizerState.unavailable) {
        _voiceDriver.pause();
      }
    }
  }

  Future<void> _refreshOfflineModelStatus() async {
    final ready = await OfflineModelManager.instance.isModelReady();
    if (mounted) {
      setState(() => _offlineModelReady = ready);
    }
  }

  Future<void> _selectAiVoiceMode() async {
    final ready = await ensureAiVoiceModelReady(context);
    if (!mounted) return;
    await _refreshOfflineModelStatus();
    if (!ready) return;
    _updateSettings(
      _script.settings.copyWith(scrollMode: ScrollMode.aiVoice),
    );
  }

  Future<void> _togglePreviewPlayback() async {
    if (_isAiMode) {
      if (_voiceDriver.isPlaying) {
        _voiceDriver.pause();
        await _voiceRecognizer.stopListening();
      } else {
        final modelReady = await ensureAiVoiceModelReady(context);
        if (!mounted) return;
        await _refreshOfflineModelStatus();
        if (!modelReady) return;

        setState(() => _loadingRecognizer = true);
        _voiceDriver.play();
        final started = await _voiceRecognizer.startListening();
        if (!mounted) return;
        setState(() => _loadingRecognizer = false);
        if (!started) {
          _voiceDriver.pause();
        }
      }
    } else {
      _fixedDriver.togglePlay();
    }
  }

  Future<void> _stopAllPreviews() async {
    _fixedDriver.pause();
    _voiceDriver.pause();
    await _voiceRecognizer.stopListening();
  }

  void _rewrapPreviewLines(double viewportWidth) {
    final availableTextWidth = (viewportWidth - 24.0).clamp(80.0, 1200.0);
    final wrapped = LyricLineSplitter.splitToFitWidth(
      _script.content,
      maxWidth: availableTextWidth,
      fontSize: _script.settings.fontSize,
      maxCharsPerLine: _script.settings.maxCharsPerLine,
    );
    _fixedDriver.updateLines(wrapped);
    _voiceDriver.updateLines(wrapped);
  }

  void _updateSettings(TeleprompterSettings newSettings) {
    final modeChanged = newSettings.scrollMode != _script.settings.scrollMode;
    if (modeChanged) {
      _stopAllPreviews();
    }
    setState(() {
      _script = _script.copyWith(
        settings: newSettings,
        updatedAt: DateTime.now(),
      );
      _dirty = true;
    });
    _fixedDriver.updateCharsPerMinute(newSettings.charsPerMinute);
    if (_lastPreviewWidth > 0) {
      _rewrapPreviewLines(_lastPreviewWidth);
    } else {
      final split = LyricLineSplitter.split(
        _script.content,
        maxCharsPerLine: newSettings.maxCharsPerLine,
      );
      _fixedDriver.updateLines(split);
      _voiceDriver.updateLines(split);
    }
  }

  void _syncTextChanges() {
    final title = _titleController.text.trim();
    final content = _contentController.text;
    setState(() {
      _script = _script.copyWith(
        title: title.isEmpty ? '未命名提词' : title,
        content: content,
        updatedAt: DateTime.now(),
      );
      _dirty = true;
    });
    if (_lastPreviewWidth > 0) {
      _rewrapPreviewLines(_lastPreviewWidth);
    } else {
      final split = LyricLineSplitter.split(
        content,
        maxCharsPerLine: _script.settings.maxCharsPerLine,
      );
      _fixedDriver.updateLines(split);
      _voiceDriver.updateLines(split);
    }
  }

  Future<TeleprompterScript> _saveScript({bool showToast = false}) async {
    final latest = _script.copyWith(
      title: _titleController.text.trim().isEmpty
          ? '未命名提词'
          : _titleController.text.trim(),
      content: _contentController.text,
      updatedAt: DateTime.now(),
    );
    await widget.repository.upsertScript(latest);
    if (mounted) {
      setState(() {
        _script = latest;
        _dirty = false;
      });
      if (showToast) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('提词设置已保存')),
        );
      }
    }
    return latest;
  }

  Future<void> _openInAppFloating() async {
    await _stopAllPreviews();
    final saved = await _saveScript();
    if (!mounted) return;
    await Navigator.of(context).push(
      PageRouteBuilder(
        opaque: false,
        barrierColor: Colors.transparent,
        pageBuilder: (_, __, ___) => FloatingTeleprompterPage(script: saved),
      ),
    );
  }

  Future<void> _launchSystemOverlay() async {
    await _stopAllPreviews();
    final saved = await _saveScript();
    final lines = LyricLineSplitter.split(
      saved.content,
      maxCharsPerLine: saved.settings.maxCharsPerLine,
    );
    final result = await OverlayChannel.startOverlay(
      script: saved,
      lines: lines,
    );
    if (!mounted) return;

    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(result.message),
        duration: const Duration(seconds: 3),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final settings = _script.settings;

    return PopScope(
      canPop: false,
      onPopInvokedWithResult: (didPop, _) async {
        if (didPop) return;
        await _stopAllPreviews();
        final saved = _dirty ? await _saveScript() : _script;
        if (context.mounted) {
          Navigator.of(context).pop(saved);
        }
      },
      child: Scaffold(
        appBar: AppBar(
          title: const Text(
            '提词设置',
            style: TextStyle(
              fontWeight: FontWeight.w700,
              color: AppColors.inkPrimary,
            ),
          ),
          actions: [
            Padding(
              padding: const EdgeInsets.only(right: 12),
              child: OutlinedButton.icon(
                onPressed: () => _saveScript(showToast: true),
                style: OutlinedButton.styleFrom(
                  padding: const EdgeInsets.symmetric(
                    horizontal: 14,
                    vertical: 6,
                  ),
                  visualDensity: VisualDensity.compact,
                ),
                icon: const Icon(Icons.check, size: 16),
                label: const Text('保存', style: TextStyle(fontSize: 13)),
              ),
            ),
          ],
        ),
        body: Column(
          children: [
            // 顶部实时 3 行歌词式预览区（支持定速与 AI 语音跟读实时试听）
            _buildLivePreviewBox(settings),
            // 设置项滚动列表
            Expanded(
              child: ListView(
                padding: const EdgeInsets.fromLTRB(16, 14, 16, 24),
                children: [
                  _buildSectionTitle('滚动模式'),
                  const SizedBox(height: 8),
                  _buildScrollModeSelector(settings),
                  const SizedBox(height: 20),
                  _buildSectionTitle(_isAiMode ? '兜底速率与排版' : '固定速率与排版'),
                  const SizedBox(height: 8),
                  _buildSliderCard(
                    title: _isAiMode ? '兜底朗读速率' : '朗读速率',
                    valueLabel:
                        '${settings.charsPerMinute} 字/分 · 约 ${_script.formattedDuration}',
                    value: settings.charsPerMinute.toDouble(),
                    min: 60,
                    max: 360,
                    divisions: 30,
                    onChanged: (v) => _updateSettings(
                      settings.copyWith(charsPerMinute: v.round()),
                    ),
                    trailingPresets: [
                      _SpeedPresetChip(
                        label: '慢速 130',
                        selected: settings.charsPerMinute == 130,
                        onTap: () => _updateSettings(
                          settings.copyWith(charsPerMinute: 130),
                        ),
                      ),
                      _SpeedPresetChip(
                        label: '标准 180',
                        selected: settings.charsPerMinute == 180,
                        onTap: () => _updateSettings(
                          settings.copyWith(charsPerMinute: 180),
                        ),
                      ),
                      _SpeedPresetChip(
                        label: '流畅 240',
                        selected: settings.charsPerMinute == 240,
                        onTap: () => _updateSettings(
                          settings.copyWith(charsPerMinute: 240),
                        ),
                      ),
                    ],
                  ),
                  const SizedBox(height: 12),
                  _buildSliderCard(
                    title: '字体大小',
                    valueLabel: '${settings.fontSize.round()} sp',
                    value: settings.fontSize,
                    min: 16,
                    max: 34,
                    divisions: 18,
                    onChanged: (v) => _updateSettings(
                      settings.copyWith(fontSize: v.roundToDouble()),
                    ),
                  ),
                  const SizedBox(height: 12),
                  _buildSliderCard(
                    title: '每行最多字数（超宽自动换行）',
                    valueLabel: '${settings.maxCharsPerLine} 字/行',
                    value: settings.maxCharsPerLine.toDouble(),
                    min: 10,
                    max: 24,
                    divisions: 14,
                    onChanged: (v) => _updateSettings(
                      settings.copyWith(maxCharsPerLine: v.round()),
                    ),
                  ),
                  const SizedBox(height: 12),
                  _buildSliderCard(
                    title: '背景透明度',
                    valueLabel: settings.backgroundOpacity <= 0.01
                        ? '0%（完全透明）'
                        : '${(settings.backgroundOpacity * 100).round()}%',
                    value: settings.backgroundOpacity,
                    min: 0.0,
                    max: 0.7,
                    divisions: 14,
                    onChanged: (v) => _updateSettings(
                      settings.copyWith(backgroundOpacity: v),
                    ),
                  ),
                  const SizedBox(height: 12),
                  _buildAppearanceCard(settings),
                  const SizedBox(height: 20),
                  _buildSectionTitle('提词内容编辑'),
                  const SizedBox(height: 8),
                  TextField(
                    controller: _titleController,
                    style: const TextStyle(color: AppColors.inkPrimary),
                    onChanged: (_) => _syncTextChanges(),
                    decoration: const InputDecoration(labelText: '标题'),
                  ),
                  const SizedBox(height: 12),
                  TextField(
                    controller: _contentController,
                    style: const TextStyle(
                      color: AppColors.inkPrimary,
                      height: 1.55,
                    ),
                    onChanged: (_) => _syncTextChanges(),
                    maxLines: 6,
                    decoration: const InputDecoration(
                      labelText: '台词正文',
                      alignLabelWithHint: true,
                    ),
                  ),
                  const SizedBox(height: 12),
                  Text(
                    OverlayChannel.platformCapabilityHint,
                    style: const TextStyle(
                      fontSize: 12,
                      color: AppColors.inkTertiary,
                    ),
                  ),
                ],
              ),
            ),
            // 底部启动栏
            _buildBottomActionBar(),
          ],
        ),
      ),
    );
  }

  Widget _buildLivePreviewBox(TeleprompterSettings settings) {
    final bool useDarkSurface = _previewDarkBackdrop;
    final Color outerBg =
        useDarkSurface ? const Color(0xFF2B2C28) : AppColors.surface;
    final Color innerBg =
        useDarkSurface ? const Color(0xFF232421) : const Color(0xFFF6F5F0);
    final Color headerInk =
        useDarkSurface ? Colors.white70 : AppColors.inkSecondary;

    final driver = _activeDriver;

    return Container(
      margin: const EdgeInsets.fromLTRB(16, 4, 16, 4),
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(20),
        color: outerBg,
        border: Border.all(
          color: useDarkSurface ? const Color(0xFF3A3C37) : AppColors.border,
        ),
      ),
      child: Column(
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(14, 8, 10, 4),
            child: ListenableBuilder(
              listenable: driver,
              builder: (_, __) => Row(
                children: [
                  _MiniWaveformBars(
                    active: driver.isPlaying,
                    level: _isAiMode ? _voiceDriver.soundLevel : 0.6,
                  ),
                  const SizedBox(width: 8),
                  Expanded(
                    child: Text(
                      _isAiMode
                          ? (_loadingRecognizer
                              ? '正在加载离线语音模型…'
                              : (driver.isPlaying
                                  ? 'AI 语音监听中 · 请朗读台词'
                                  : 'AI 语音跟读预览（点击麦克风试听）'))
                          : '3 行歌词实时预览',
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(
                        fontSize: 12.2,
                        fontWeight: FontWeight.w500,
                        color: headerInk,
                      ),
                    ),
                  ),
                  GestureDetector(
                    onTap: () => setState(
                      () => _previewDarkBackdrop = !_previewDarkBackdrop,
                    ),
                    child: Container(
                      padding: const EdgeInsets.symmetric(
                        horizontal: 8,
                        vertical: 3,
                      ),
                      decoration: BoxDecoration(
                        color: useDarkSurface
                            ? Colors.white.withValues(alpha: 0.1)
                            : AppColors.chipBackground,
                        borderRadius: BorderRadius.circular(999),
                        border: Border.all(
                          color: useDarkSurface
                              ? Colors.white24
                              : AppColors.border,
                        ),
                      ),
                      child: Text(
                        useDarkSurface ? '深景底' : '浅纸底',
                        style: TextStyle(
                          fontSize: 11,
                          color: headerInk,
                          fontWeight: FontWeight.w500,
                        ),
                      ),
                    ),
                  ),
                  IconButton(
                    tooltip: '重头试看',
                    icon: Icon(
                      Icons.replay,
                      size: 18,
                      color: headerInk,
                    ),
                    onPressed: () {
                      driver.reset();
                      if (_isAiMode) {
                        _voiceRecognizer.stopListening();
                      }
                    },
                    visualDensity: VisualDensity.compact,
                  ),
                  IconButton(
                    tooltip: driver.isPlaying
                        ? (_isAiMode ? '停止语音跟读' : '暂停预览')
                        : (_isAiMode ? '开启麦克风试读' : '试看滚动'),
                    icon: Icon(
                      _isAiMode
                          ? (driver.isPlaying
                              ? Icons.stop_circle
                              : Icons.mic_rounded)
                          : (driver.isPlaying
                              ? Icons.pause_circle_filled
                              : Icons.play_circle_filled),
                      color: _isAiMode && driver.isPlaying
                          ? AppColors.danger
                          : AppColors.accentGreen,
                      size: 26,
                    ),
                    onPressed: _togglePreviewPlayback,
                    visualDensity: VisualDensity.compact,
                  ),
                ],
              ),
            ),
          ),
          Padding(
            padding: const EdgeInsets.fromLTRB(10, 0, 10, 10),
            child: Container(
              decoration: BoxDecoration(
                color: innerBg,
                borderRadius: BorderRadius.circular(14),
                border: Border.all(
                  color: useDarkSurface
                      ? Colors.white.withValues(alpha: 0.06)
                      : AppColors.border.withValues(alpha: 0.65),
                ),
              ),
              child: LayoutBuilder(
                builder: (context, constraints) {
                  if ((constraints.maxWidth - _lastPreviewWidth).abs() > 1.0) {
                    _lastPreviewWidth = constraints.maxWidth;
                    WidgetsBinding.instance.addPostFrameCallback((_) {
                      if (mounted) {
                        _rewrapPreviewLines(constraints.maxWidth);
                      }
                    });
                  }
                  return ListenableBuilder(
                    listenable: driver,
                    builder: (_, __) => Column(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        LyricTeleprompterView(
                          lines: driver.lines,
                          progress: driver.progress,
                          settings: settings,
                          onTap: _togglePreviewPlayback,
                        ),
                        if (_isAiMode &&
                            _voiceDriver.lastRecognizedText.isNotEmpty)
                          Container(
                            width: double.infinity,
                            padding: const EdgeInsets.fromLTRB(10, 4, 10, 6),
                            decoration: BoxDecoration(
                              border: Border(
                                top: BorderSide(
                                  color: useDarkSurface
                                      ? Colors.white10
                                      : AppColors.border.withValues(alpha: 0.6),
                                ),
                              ),
                            ),
                            child: Text(
                              '实时识别：${_voiceDriver.lastRecognizedText}',
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                              style: TextStyle(
                                fontSize: 11,
                                color: useDarkSurface
                                    ? Colors.white60
                                    : AppColors.inkSecondary,
                              ),
                            ),
                          ),
                      ],
                    ),
                  );
                },
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildSectionTitle(String title) {
    return Text(
      title,
      style: const TextStyle(
        fontSize: 13.5,
        fontWeight: FontWeight.w700,
        color: AppColors.inkSecondary,
        letterSpacing: 0.2,
      ),
    );
  }

  Widget _buildScrollModeSelector(TeleprompterSettings settings) {
    final supportsOffline =
        OfflineModelManager.instance.supportsLocalOfflineModel;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Row(
          children: [
            Expanded(
              child: _ModeOptionCard(
                title: '固定速率滚动',
                subtitle: '按字速匀速歌词推进',
                icon: Icons.speed,
                selected: settings.scrollMode == ScrollMode.fixedRate,
                onTap: () => _updateSettings(
                  settings.copyWith(scrollMode: ScrollMode.fixedRate),
                ),
              ),
            ),
            const SizedBox(width: 12),
            Expanded(
              child: _ModeOptionCard(
                title: 'AI 语音跟随',
                subtitle: supportsOffline
                    ? (_offlineModelReady ? '离线中英双语已就绪' : '首次点击自动下载模型')
                    : '拼音模糊对齐，说多快滚多快',
                icon: Icons.mic_none_rounded,
                selected: settings.scrollMode == ScrollMode.aiVoice,
                badgeText: supportsOffline
                    ? (_offlineModelReady ? '已离线就绪' : '首次下载')
                    : '实时跟读',
                onTap: _selectAiVoiceMode,
              ),
            ),
          ],
        ),
        if (settings.scrollMode == ScrollMode.aiVoice) ...[
          const SizedBox(height: 10),
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
            decoration: BoxDecoration(
              color: AppColors.surface,
              borderRadius: BorderRadius.circular(14),
              border: Border.all(color: AppColors.border),
            ),
            child: Row(
              children: [
                Icon(
                  supportsOffline
                      ? (_offlineModelReady
                          ? Icons.offline_pin_rounded
                          : Icons.cloud_download_outlined)
                      : Icons.public_rounded,
                  size: 17,
                  color: AppColors.accentGreenDark,
                ),
                const SizedBox(width: 8),
                Expanded(
                  child: Text(
                    supportsOffline
                        ? (_offlineModelReady
                            ? 'Sherpa-ONNX 中英双语模型已缓存，断网也可离线跟读'
                            : '离线模型尚未下载（${OfflineModelManager.instance.estimatedTotalSizeLabel}）')
                        : 'Chrome 预览使用浏览器实时语音；手机真机首次使用将自动下载离线 Sherpa-ONNX 模型',
                    style: const TextStyle(
                      fontSize: 12,
                      color: AppColors.inkSecondary,
                      height: 1.35,
                    ),
                  ),
                ),
                if (supportsOffline) ...[
                  const SizedBox(width: 8),
                  TextButton(
                    onPressed: () async {
                      if (_offlineModelReady) {
                        await _stopAllPreviews();
                        await OfflineModelManager.instance.deleteModel();
                        await _refreshOfflineModelStatus();
                        if (!mounted) return;
                        ScaffoldMessenger.of(context).showSnackBar(
                          const SnackBar(content: Text('已清理离线语音模型缓存')),
                        );
                      } else {
                        await ensureAiVoiceModelReady(context);
                        await _refreshOfflineModelStatus();
                      }
                    },
                    style: TextButton.styleFrom(
                      foregroundColor: _offlineModelReady
                          ? AppColors.inkSecondary
                          : AppColors.accentGreenDark,
                      visualDensity: VisualDensity.compact,
                    ),
                    child: Text(
                      _offlineModelReady ? '清理缓存' : '立即下载',
                      style: const TextStyle(fontSize: 12),
                    ),
                  ),
                ],
              ],
            ),
          ),
        ],
      ],
    );
  }

  Widget _buildSliderCard({
    required String title,
    required String valueLabel,
    required double value,
    required double min,
    required double max,
    required int divisions,
    required ValueChanged<double> onChanged,
    List<Widget>? trailingPresets,
  }) {
    return Material(
      color: AppColors.surface,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(18),
        side: const BorderSide(color: AppColors.border),
      ),
      child: Padding(
        padding: const EdgeInsets.fromLTRB(16, 12, 16, 8),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Text(
                  title,
                  style: const TextStyle(
                    fontSize: 14,
                    fontWeight: FontWeight.w600,
                    color: AppColors.inkPrimary,
                  ),
                ),
                const Spacer(),
                Text(
                  valueLabel,
                  style: const TextStyle(
                    fontSize: 12.5,
                    color: AppColors.accentGreenDark,
                    fontWeight: FontWeight.w600,
                  ),
                ),
              ],
            ),
            Slider(
              value: value.clamp(min, max),
              min: min,
              max: max,
              divisions: divisions,
              onChanged: onChanged,
            ),
            if (trailingPresets != null && trailingPresets.isNotEmpty)
              Padding(
                padding: const EdgeInsets.only(bottom: 6),
                child: Wrap(spacing: 8, children: trailingPresets),
              ),
          ],
        ),
      ),
    );
  }

  Widget _buildAppearanceCard(TeleprompterSettings settings) {
    return Material(
      color: AppColors.surface,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(18),
        side: const BorderSide(color: AppColors.border),
      ),
      clipBehavior: Clip.antiAlias,
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const Text(
              '当前行高亮颜色',
              style: TextStyle(
                fontSize: 14,
                fontWeight: FontWeight.w600,
                color: AppColors.inkPrimary,
              ),
            ),
            const SizedBox(height: 12),
            Row(
              children: _presetTextColors.map((colorValue) {
                final selected = settings.activeTextColorValue == colorValue;
                return Padding(
                  padding: const EdgeInsets.only(right: 12),
                  child: GestureDetector(
                    onTap: () {
                      final isDarkColor =
                          Color(colorValue).computeLuminance() < 0.35;
                      _updateSettings(
                        settings.copyWith(
                          activeTextColorValue: colorValue,
                          inactiveTextColorValue:
                              isDarkColor ? 0x996E6D68 : 0xB3E2E8F0,
                        ),
                      );
                    },
                    child: Container(
                      width: 32,
                      height: 32,
                      decoration: BoxDecoration(
                        color: Color(colorValue),
                        shape: BoxShape.circle,
                        border: Border.all(
                          color: selected
                              ? AppColors.accentGreen
                              : AppColors.border,
                          width: selected ? 3 : 1.2,
                        ),
                        boxShadow: const [
                          BoxShadow(
                            color: Color(0x14000000),
                            blurRadius: 4,
                            offset: Offset(0, 1),
                          ),
                        ],
                      ),
                    ),
                  ),
                );
              }).toList(),
            ),
            const Divider(height: 24, color: AppColors.border),
            SwitchListTile(
              contentPadding: EdgeInsets.zero,
              title: const Text(
                '文字描边阴影',
                style: TextStyle(
                  fontSize: 14,
                  fontWeight: FontWeight.w500,
                  color: AppColors.inkPrimary,
                ),
              ),
              subtitle: const Text(
                '透明悬浮在浅色或复杂画面上时保证清晰可读',
                style: TextStyle(fontSize: 12, color: AppColors.inkSecondary),
              ),
              value: settings.enableTextShadow,
              onChanged: (v) => _updateSettings(
                settings.copyWith(enableTextShadow: v),
              ),
            ),
            SwitchListTile(
              contentPadding: EdgeInsets.zero,
              title: const Text(
                '水平镜像模式',
                style: TextStyle(
                  fontSize: 14,
                  fontWeight: FontWeight.w500,
                  color: AppColors.inkPrimary,
                ),
              ),
              subtitle: const Text(
                '配合专业分光镜提词器硬件使用',
                style: TextStyle(fontSize: 12, color: AppColors.inkSecondary),
              ),
              value: settings.mirrorMode,
              onChanged: (v) => _updateSettings(
                settings.copyWith(mirrorMode: v),
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildBottomActionBar() {
    return Container(
      padding: EdgeInsets.fromLTRB(
        16,
        12,
        16,
        MediaQuery.of(context).padding.bottom + 12,
      ),
      decoration: const BoxDecoration(
        color: AppColors.background,
        border: Border(top: BorderSide(color: AppColors.border)),
      ),
      child: Row(
        children: [
          Expanded(
            child: OutlinedButton.icon(
              onPressed: _openInAppFloating,
              icon: const Icon(Icons.subtitles_outlined, size: 18),
              label: const Text('进入悬浮页'),
              style: OutlinedButton.styleFrom(
                padding: const EdgeInsets.symmetric(vertical: 14),
              ),
            ),
          ),
          const SizedBox(width: 12),
          Expanded(
            flex: 2,
            child: FilledButton.icon(
              onPressed: _launchSystemOverlay,
              icon: const Icon(Icons.picture_in_picture_alt, size: 18),
              label: const Text('悬浮到其他应用之上'),
              style: FilledButton.styleFrom(
                padding: const EdgeInsets.symmetric(vertical: 14),
              ),
            ),
          ),
        ],
      ),
    );
  }
}

/// 仿 Granola 底部鲜活草绿动态声波条（随真实麦克风音量跳动）
class _MiniWaveformBars extends StatelessWidget {
  const _MiniWaveformBars({
    required this.active,
    this.level = 0.5,
  });

  final bool active;
  final double level;

  @override
  Widget build(BuildContext context) {
    final boost = active ? (0.45 + level.clamp(0.0, 1.0) * 0.95) : 0.35;
    final baseHeights = [10.0, 14.0, 16.0, 11.0, 8.0];
    return Row(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.center,
      children: baseHeights.map((h) {
        return AnimatedContainer(
          duration: const Duration(milliseconds: 110),
          width: 3,
          height: (h * boost).clamp(4.0, 18.0),
          margin: const EdgeInsets.symmetric(horizontal: 1.2),
          decoration: BoxDecoration(
            color: active
                ? AppColors.accentGreen
                : AppColors.accentGreen.withValues(alpha: 0.4),
            borderRadius: BorderRadius.circular(2),
          ),
        );
      }).toList(),
    );
  }
}

class _ModeOptionCard extends StatelessWidget {
  const _ModeOptionCard({
    required this.title,
    required this.subtitle,
    required this.icon,
    required this.selected,
    required this.onTap,
    this.badgeText,
  });

  final String title;
  final String subtitle;
  final IconData icon;
  final bool selected;
  final VoidCallback onTap;
  final String? badgeText;

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onTap: onTap,
      child: Container(
        padding: const EdgeInsets.all(14),
        decoration: BoxDecoration(
          color: AppColors.surface,
          borderRadius: BorderRadius.circular(18),
          border: Border.all(
            color: selected ? AppColors.inkPrimary : AppColors.border,
            width: selected ? 1.6 : 1,
          ),
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Icon(
                  icon,
                  size: 18,
                  color: selected
                      ? AppColors.inkPrimary
                      : AppColors.inkSecondary,
                ),
                const Spacer(),
                if (selected)
                  Container(
                    width: 8,
                    height: 8,
                    decoration: const BoxDecoration(
                      color: AppColors.accentGreen,
                      shape: BoxShape.circle,
                    ),
                  )
                else if (badgeText != null)
                  Container(
                    padding: const EdgeInsets.symmetric(
                      horizontal: 7,
                      vertical: 2,
                    ),
                    decoration: BoxDecoration(
                      color: AppColors.accentGreenSoft,
                      borderRadius: BorderRadius.circular(999),
                    ),
                    child: Text(
                      badgeText!,
                      style: const TextStyle(
                        fontSize: 10,
                        fontWeight: FontWeight.w600,
                        color: AppColors.accentGreenDark,
                      ),
                    ),
                  ),
              ],
            ),
            const SizedBox(height: 8),
            Text(
              title,
              style: const TextStyle(
                fontSize: 14,
                fontWeight: FontWeight.w700,
                color: AppColors.inkPrimary,
              ),
            ),
            const SizedBox(height: 2),
            Text(
              subtitle,
              style: const TextStyle(
                fontSize: 11.5,
                color: AppColors.inkSecondary,
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _SpeedPresetChip extends StatelessWidget {
  const _SpeedPresetChip({
    required this.label,
    required this.selected,
    required this.onTap,
  });

  final String label;
  final bool selected;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onTap: onTap,
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 11, vertical: 6),
        decoration: BoxDecoration(
          color: selected ? AppColors.inkPrimary : AppColors.chipBackground,
          borderRadius: BorderRadius.circular(999),
          border: Border.all(
            color: selected ? AppColors.inkPrimary : AppColors.border,
          ),
        ),
        child: Text(
          label,
          style: TextStyle(
            fontSize: 12,
            fontWeight: FontWeight.w500,
            color: selected ? Colors.white : AppColors.inkSecondary,
          ),
        ),
      ),
    );
  }
}
