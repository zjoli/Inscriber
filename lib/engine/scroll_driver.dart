import 'package:flutter/foundation.dart';
import 'line_splitter.dart';
import 'voice_alignment_engine.dart';

/// 提词滚动驱动器抽象基类
/// 固定速率模式与 AI 语音识别跟随模式均实现此接口，实现 UI 与驱动逻辑解耦
abstract class ScrollDriver extends ChangeNotifier {
  ScrollDriver({required List<String> lines})
      : _lines = lines.isEmpty ? const ['（暂无提词内容）'] : List.unmodifiable(lines);

  List<String> _lines;
  double _progress = 0.0;
  bool _isPlaying = false;

  List<String> get lines => _lines;

  /// 连续浮点行进度：0.0 表示第 0 行居中，1.5 表示正从第 1 行平滑滚动到第 2 行
  double get progress => _progress;

  int get currentLineIndex =>
      _progress.round().clamp(0, (_lines.length - 1).clamp(0, 1 << 20));

  double get maxProgress => (_lines.length - 1).clamp(0, 1 << 20).toDouble();

  bool get isPlaying => _isPlaying;

  bool get isFinished => _lines.length <= 1 || _progress >= maxProgress;

  /// 整体进度百分比 [0.0, 1.0]
  double get normalizedProgress =>
      maxProgress <= 0 ? 1.0 : (_progress / maxProgress).clamp(0.0, 1.0);

  @protected
  void setProgress(double value) {
    final clamped = value.clamp(0.0, maxProgress);
    if ((clamped - _progress).abs() > 1e-6) {
      _progress = clamped;
      notifyListeners();
    }
  }

  @protected
  void setPlaying(bool playing) {
    if (_isPlaying != playing) {
      _isPlaying = playing;
      notifyListeners();
    }
  }

  void updateLines(List<String> newLines) {
    _lines = newLines.isEmpty
        ? const ['（暂无提词内容）']
        : List.unmodifiable(newLines);
    _progress = _progress.clamp(0.0, maxProgress);
    notifyListeners();
  }

  void play() {
    if (isFinished) {
      _progress = 0.0;
    }
    setPlaying(true);
  }

  void pause() {
    setPlaying(false);
  }

  void togglePlay() {
    if (_isPlaying) {
      pause();
    } else {
      play();
    }
  }

  void reset() {
    _isPlaying = false;
    _progress = 0.0;
    notifyListeners();
  }

  void seekToLine(double targetLineProgress) {
    _progress = targetLineProgress.clamp(0.0, maxProgress);
    notifyListeners();
  }

  /// 每帧由 Ticker 触发推进状态
  void tick(Duration delta);
}

/// 固定速率滚动驱动器
/// 根据每行实际字数与设定语速（CPM）动态计算行停留时长，确保长短句滚动节奏自然
class FixedRateScrollDriver extends ScrollDriver {
  FixedRateScrollDriver({
    required super.lines,
    required int charsPerMinute,
  }) : _charsPerMinute = charsPerMinute.clamp(60, 480);

  int _charsPerMinute;

  int get charsPerMinute => _charsPerMinute;

  void updateCharsPerMinute(int cpm) {
    final clamped = cpm.clamp(60, 480);
    if (_charsPerMinute != clamped) {
      _charsPerMinute = clamped;
      notifyListeners();
    }
  }

  /// 计算指定行按当前速率滚动完所需秒数
  double secondsForLine(int lineIndex) {
    if (lineIndex < 0 || lineIndex >= lines.length) return 2.0;
    final readableUnits = LyricLineSplitter.countReadableUnits(lines[lineIndex]);
    final charsPerSecond = _charsPerMinute / 60.0;
    // 最短停留 0.85 秒，避免极短感叹句一闪而过
    return (readableUnits / charsPerSecond).clamp(0.85, 25.0);
  }

  @override
  void tick(Duration delta) {
    if (!isPlaying || delta <= Duration.zero) return;
    if (isFinished) {
      pause();
      return;
    }

    final dtSeconds = delta.inMicroseconds / 1000000.0;
    final activeIndex = progress.floor().clamp(0, lines.length - 1);
    final lineDuration = secondsForLine(activeIndex);
    final nextProgress = progress + (dtSeconds / lineDuration);

    if (nextProgress >= maxProgress) {
      setProgress(maxProgress);
      pause();
    } else {
      setProgress(nextProgress);
    }
  }
}

/// AI 语音识别智能滚动驱动器
/// 接收实时流式识别文本 -> 拼音模糊滑动窗口对齐 -> 指数阻尼平滑滚动
class AiVoiceScrollDriver extends ScrollDriver {
  AiVoiceScrollDriver({required super.lines})
      : _alignmentEngine = VoiceAlignmentEngine(lines: lines);

  final VoiceAlignmentEngine _alignmentEngine;

  double _targetProgress = 0.0;
  String _lastRecognizedText = '';
  double _lastConfidence = 0.0;
  double _soundLevel = 0.0;

  double get targetProgress => _targetProgress;
  String get lastRecognizedText => _lastRecognizedText;
  double get lastConfidence => _lastConfidence;

  /// 归一化实时麦克风音量 [0.0, 1.0]，用于驱动绿色声波条动态跳动
  double get soundLevel => _soundLevel;

  @override
  void updateLines(List<String> newLines) {
    super.updateLines(newLines);
    _alignmentEngine.updateLines(lines);
    _targetProgress = _targetProgress.clamp(0.0, maxProgress);
  }

  @override
  void reset() {
    _alignmentEngine.reset();
    _targetProgress = 0.0;
    _lastRecognizedText = '';
    _lastConfidence = 0.0;
    _soundLevel = 0.0;
    super.reset();
  }

  @override
  void seekToLine(double targetLineProgress) {
    final clamped = targetLineProgress.clamp(0.0, maxProgress);
    _targetProgress = clamped;
    _alignmentEngine.syncToLineProgress(clamped);
    super.seekToLine(clamped);
  }

  void updateSoundLevel(double normalizedLevel) {
    final clamped = normalizedLevel.clamp(0.0, 1.0);
    if ((clamped - _soundLevel).abs() > 0.02) {
      _soundLevel = clamped;
      notifyListeners();
    }
  }

  /// 接收来自任意 VoiceRecognizer（Web Speech / 系统 ASR / 未来 Sherpa-ONNX）的实时识别文本
  AlignmentMatchResult onPartialTranscript(String recognizedText) {
    _lastRecognizedText = recognizedText.trim();
    if (!isPlaying || _lastRecognizedText.isEmpty) {
      notifyListeners();
      return AlignmentMatchResult(
        matched: false,
        tokenIndex: _alignmentEngine.cursorTokenIndex,
        lineProgress: _targetProgress,
        confidence: 0.0,
      );
    }

    final result = _alignmentEngine.alignTranscript(_lastRecognizedText);
    _lastConfidence = result.confidence;
    if (result.matched && result.lineProgress > _targetProgress) {
      _targetProgress = result.lineProgress.clamp(0.0, maxProgress);
    }
    notifyListeners();
    return result;
  }

  @override
  void tick(Duration delta) {
    if (!isPlaying || delta <= Duration.zero) return;
    final dtSeconds = delta.inMicroseconds / 1000000.0;
    // 指数阻尼插值：跟手不滞后、平滑无跳变
    final diff = _targetProgress - progress;
    if (diff.abs() < 0.001) {
      if (diff.abs() > 0) setProgress(_targetProgress);
      return;
    }
    final factor = (dtSeconds * 7.5).clamp(0.0, 1.0);
    setProgress(progress + diff * factor);
  }
}
