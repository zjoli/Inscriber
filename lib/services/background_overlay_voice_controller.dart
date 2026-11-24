import 'dart:async';
import 'package:flutter/foundation.dart';
import '../engine/voice_alignment_engine.dart';
import 'overlay_channel.dart';
import 'voice_recognizer.dart';
import 'voice_recognizer_factory.dart';

/// 进度同步发送函数（便于单元测试注入 mock）
typedef OverlayProgressSender = Future<void> Function({
  required double lineProgress,
  required double charRatio,
  String? recognizedText,
});

typedef OverlayAiModeSetter = Future<void> Function(bool enabled);

/// 跨应用悬浮窗专用的后台 AI 语音同步控制器（全局单例）
/// - 独立于具体页面生命周期，即使用户切回桌面/相机/直播 App，仍持续在 Flutter 后台运行 Sherpa-ONNX
/// - 将实时识别文本送入 VoiceAlignmentEngine，算出最新行进度与字比例，经 OverlayChannel.syncProgress 推送给原生悬浮窗
/// - 接收来自原生悬浮窗的暂停/播放/重头/关闭反向回调，确保麦克风与原生内存零泄漏
/// - 若前台 App（如系统相机）抢占麦克风导致录音异常，自动通知悬浮窗降级回固定速率滚动
class BackgroundOverlayVoiceController extends ChangeNotifier {
  BackgroundOverlayVoiceController({
    VoiceRecognizer Function()? recognizerFactory,
    OverlayProgressSender? progressSender,
    OverlayAiModeSetter? aiModeSetter,
  })  : _recognizerFactory = recognizerFactory ?? createDefaultVoiceRecognizer,
        _progressSender = progressSender ?? OverlayChannel.syncProgress,
        _aiModeSetter = aiModeSetter ?? OverlayChannel.setAiVoiceMode;

  static final BackgroundOverlayVoiceController instance =
      BackgroundOverlayVoiceController();

  final VoiceRecognizer Function() _recognizerFactory;
  final OverlayProgressSender _progressSender;
  final OverlayAiModeSetter _aiModeSetter;

  VoiceRecognizer? _recognizer;
  VoiceAlignmentEngine? _alignmentEngine;
  StreamSubscription<VoiceRecognitionEvent>? _sub;

  bool _active = false;
  bool _paused = false;
  String _lastRecognizedText = '';
  double _lastCharRatio = 0.0;
  DateTime _lastSyncTime = DateTime.fromMillisecondsSinceEpoch(0);

  bool get isActive => _active;
  bool get isPaused => _paused;
  String get lastRecognizedText => _lastRecognizedText;
  double get lastCharRatio => _lastCharRatio;

  /// 启动跨应用悬浮窗后台语音跟读（在原生悬浮窗启动成功后调用）
  Future<bool> start({
    required List<String> lines,
    double initialLineProgress = 0.0,
  }) async {
    await stop();

    OverlayChannel.bindNativeCallbacks(
      onStopped: () {
        stop();
      },
      onPlayStateChanged: (playing) {
        if (playing) {
          resume();
        } else {
          pause();
        }
      },
      onReset: () {
        reset();
      },
    );

    _alignmentEngine = VoiceAlignmentEngine(lines: lines);
    if (initialLineProgress > 0) {
      _alignmentEngine!.syncToLineProgress(initialLineProgress);
    }
    _lastCharRatio = _alignmentEngine!.currentCharRatio;
    _lastRecognizedText = '';
    _paused = false;

    final recognizer = _recognizerFactory();
    _recognizer = recognizer;
    _sub = recognizer.events.listen(_handleVoiceEvent);

    final started = await recognizer.startListening();
    if (!started) {
      // 麦克风被占用或权限未开启：自动降级为固定速率滚动，不卡死悬浮提词
      await _aiModeSetter(false);
      await stop();
      return false;
    }

    _active = true;
    await _aiModeSetter(true);
    await _progressSender(
      lineProgress: initialLineProgress,
      charRatio: _lastCharRatio,
    );
    notifyListeners();
    return true;
  }

  void _handleVoiceEvent(VoiceRecognitionEvent event) {
    if (!_active || _paused) return;

    if (event.partialText != null && event.partialText!.isNotEmpty) {
      _lastRecognizedText = event.partialText!.trim();
      final engine = _alignmentEngine;
      if (engine == null) return;

      final match = engine.alignTranscript(_lastRecognizedText);
      if (match.matched) {
        _lastCharRatio = match.charRatio;
        final now = DateTime.now();
        // 节流 45ms（最高 ~22Hz），既丝滑跟手又避免频繁跨桥通信开销
        if (now.difference(_lastSyncTime).inMilliseconds >= 45 ||
            event.isFinal) {
          _lastSyncTime = now;
          _progressSender(
            lineProgress: match.lineProgress,
            charRatio: match.charRatio,
            recognizedText: _lastRecognizedText,
          );
        }
        notifyListeners();
      }
      return;
    }

    if (event.state == VoiceRecognizerState.error ||
        event.state == VoiceRecognizerState.unavailable) {
      // 运行中若麦克风被其他直播/录像 App 抢占中断，平滑降级回固定速率滚动
      _aiModeSetter(false);
      stop();
    }
  }

  Future<void> pause() async {
    if (!_active || _paused) return;
    _paused = true;
    await _recognizer?.stopListening();
    notifyListeners();
  }

  Future<void> resume() async {
    if (!_active || !_paused) return;
    _paused = false;
    final ok = await (_recognizer?.startListening() ?? Future.value(false));
    if (!ok) {
      await _aiModeSetter(false);
      await stop();
      return;
    }
    notifyListeners();
  }

  Future<void> reset() async {
    if (!_active) return;
    _alignmentEngine?.reset();
    _lastCharRatio = 0.0;
    _lastRecognizedText = '';
    await _progressSender(lineProgress: 0.0, charRatio: 0.0);
    if (_paused) {
      await resume();
    }
    notifyListeners();
  }

  Future<void> stop() async {
    _active = false;
    _paused = false;
    await _sub?.cancel();
    _sub = null;
    final rec = _recognizer;
    _recognizer = null;
    if (rec != null) {
      await rec.dispose();
    }
    _alignmentEngine = null;
    _lastRecognizedText = '';
    notifyListeners();
  }
}
