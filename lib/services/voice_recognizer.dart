import 'dart:async';
import 'package:flutter/foundation.dart';
import 'package:speech_to_text/speech_to_text.dart';

enum VoiceRecognizerState {
  idle,
  initializing,
  listening,
  unavailable,
  error,
}

class VoiceRecognitionEvent {
  const VoiceRecognitionEvent({
    this.partialText,
    this.isFinal = false,
    this.soundLevel,
    this.state,
    this.errorMessage,
  });

  final String? partialText;
  final bool isFinal;
  final double? soundLevel;
  final VoiceRecognizerState? state;
  final String? errorMessage;
}

/// 可插拔的流式语音识别器抽象接口
/// - 第一阶段默认使用 [SystemSpeechVoiceRecognizer]（支持 Chrome Web Speech / iOS / Android）
/// - 后续可无缝替换为 [SherpaOnnxVoiceRecognizer]（纯离线端侧 Zipformer 模型），无需改动 UI 与对齐算法
abstract class VoiceRecognizer {
  Stream<VoiceRecognitionEvent> get events;
  VoiceRecognizerState get state;
  bool get isListening;

  Future<bool> initialize();
  Future<bool> startListening({String localeId = 'zh_CN'});
  Future<void> stopListening();
  Future<void> dispose();
}

/// 基于 speech_to_text 的跨平台实时流式识别器
/// 支持 Chrome（Web Speech API）、iOS（Apple Speech）、Android（SpeechRecognizer），
/// 并内置断句/静音自动续听机制，满足提词器连续长时间朗读场景。
class SystemSpeechVoiceRecognizer implements VoiceRecognizer {
  SystemSpeechVoiceRecognizer();

  final SpeechToText _speech = SpeechToText();
  final StreamController<VoiceRecognitionEvent> _controller =
      StreamController<VoiceRecognitionEvent>.broadcast();

  VoiceRecognizerState _state = VoiceRecognizerState.idle;
  bool _initialized = false;
  bool _shouldBeListening = false;
  bool _disposed = false;
  String _preferredLocaleId = 'zh_CN';
  Timer? _restartTimer;

  @override
  Stream<VoiceRecognitionEvent> get events => _controller.stream;

  @override
  VoiceRecognizerState get state => _state;

  @override
  bool get isListening => _state == VoiceRecognizerState.listening;

  void _emit(VoiceRecognitionEvent event) {
    if (_disposed || _controller.isClosed) return;
    if (event.state != null) {
      _state = event.state!;
    }
    _controller.add(event);
  }

  @override
  Future<bool> initialize() async {
    if (_initialized) return true;
    _emit(const VoiceRecognitionEvent(state: VoiceRecognizerState.initializing));

    try {
      final available = await _speech.initialize(
        onStatus: _handleStatus,
        onError: (error) {
          final friendly = _friendlyErrorMessage(error.errorMsg);
          // 常见的“无语音超时”在连续提词中不应报错终止，直接自动续听
          if (error.errorMsg.contains('no_match') ||
              error.errorMsg.contains('speech_timeout') ||
              error.errorMsg.contains('no-speech')) {
            if (_shouldBeListening) {
              _scheduleRestart();
            }
            return;
          }
          _emit(
            VoiceRecognitionEvent(
              state: error.permanent
                  ? VoiceRecognizerState.error
                  : VoiceRecognizerState.idle,
              errorMessage: friendly,
            ),
          );
          if (!error.permanent && _shouldBeListening) {
            _scheduleRestart();
          }
        },
      );

      _initialized = available;
      if (!available) {
        _emit(
          const VoiceRecognitionEvent(
            state: VoiceRecognizerState.unavailable,
            errorMessage: '当前设备或浏览器不支持语音识别，或未授予麦克风权限。',
          ),
        );
        return false;
      }

      // 自动探测可用的中文 locale（不同浏览器/系统可能命名为 zh-CN 或 zh_CN）
      try {
        final locales = await _speech.locales();
        final zhLocale = locales.where((l) {
          final id = l.localeId.toLowerCase().replaceAll('_', '-');
          return id.startsWith('zh-cn') || id.startsWith('zh-hans') || id == 'zh';
        }).toList();
        if (zhLocale.isNotEmpty) {
          _preferredLocaleId = zhLocale.first.localeId;
        }
      } catch (_) {
        // 某些浏览器不允许枚举 locales，保持默认 zh-CN
        _preferredLocaleId = kIsWeb ? 'zh-CN' : 'zh_CN';
      }

      _emit(const VoiceRecognitionEvent(state: VoiceRecognizerState.idle));
      return true;
    } catch (e) {
      _emit(
        VoiceRecognitionEvent(
          state: VoiceRecognizerState.error,
          errorMessage: '语音识别初始化失败：$e',
        ),
      );
      return false;
    }
  }

  @override
  Future<bool> startListening({String localeId = 'zh_CN'}) async {
    _shouldBeListening = true;
    _restartTimer?.cancel();

    final ok = await initialize();
    if (!ok) {
      _shouldBeListening = false;
      return false;
    }

    if (localeId.isNotEmpty && !localeId.startsWith('zh')) {
      _preferredLocaleId = localeId;
    }

    return _beginSingleSession();
  }

  Future<bool> _beginSingleSession() async {
    if (_disposed || !_shouldBeListening) return false;
    try {
      await _speech.listen(
        localeId: _preferredLocaleId,
        listenFor: const Duration(minutes: 5),
        pauseFor: const Duration(seconds: 12),
        listenOptions: SpeechListenOptions(
          listenMode: ListenMode.dictation,
          partialResults: true,
          cancelOnError: false,
          autoPunctuation: false,
        ),
        onSoundLevelChange: (level) {
          // speech_to_text 的音量一般在 [-2, 10] 或 [0, 100]，映射到 [0.0, 1.0]
          final normalized = level <= 12
              ? ((level + 2.0) / 12.0).clamp(0.0, 1.0)
              : (level / 100.0).clamp(0.0, 1.0);
          _emit(VoiceRecognitionEvent(soundLevel: normalized));
        },
        onResult: (result) {
          final words = result.recognizedWords.trim();
          if (words.isNotEmpty) {
            _emit(
              VoiceRecognitionEvent(
                partialText: words,
                isFinal: result.finalResult,
              ),
            );
          }
          if (result.finalResult && _shouldBeListening) {
            _scheduleRestart();
          }
        },
      );
      _emit(const VoiceRecognitionEvent(state: VoiceRecognizerState.listening));
      return true;
    } catch (e) {
      _emit(
        VoiceRecognitionEvent(
          state: VoiceRecognizerState.error,
          errorMessage: '无法开启麦克风语音监听：$e',
        ),
      );
      return false;
    }
  }

  void _handleStatus(String status) {
    if (_disposed) return;
    if (status == SpeechToText.listeningStatus) {
      _emit(const VoiceRecognitionEvent(state: VoiceRecognizerState.listening));
    } else if (status == SpeechToText.doneStatus ||
        status == SpeechToText.notListeningStatus) {
      if (_shouldBeListening) {
        _scheduleRestart();
      } else {
        _emit(
          const VoiceRecognitionEvent(
            state: VoiceRecognizerState.idle,
            soundLevel: 0.0,
          ),
        );
      }
    }
  }

  void _scheduleRestart() {
    if (_disposed || !_shouldBeListening) return;
    _restartTimer?.cancel();
    _restartTimer = Timer(const Duration(milliseconds: 280), () {
      if (_disposed || !_shouldBeListening) return;
      if (!_speech.isListening) {
        _beginSingleSession();
      }
    });
  }

  @override
  Future<void> stopListening() async {
    _shouldBeListening = false;
    _restartTimer?.cancel();
    if (_speech.isListening) {
      await _speech.stop();
    }
    _emit(
      const VoiceRecognitionEvent(
        state: VoiceRecognizerState.idle,
        soundLevel: 0.0,
      ),
    );
  }

  @override
  Future<void> dispose() async {
    _disposed = true;
    _shouldBeListening = false;
    _restartTimer?.cancel();
    try {
      if (_speech.isListening) {
        await _speech.cancel();
      }
    } catch (_) {}
    await _controller.close();
  }

  static String _friendlyErrorMessage(String raw) {
    final lower = raw.toLowerCase();
    if (lower.contains('not-allowed') || lower.contains('permission')) {
      return '麦克风权限被拒绝，请在浏览器或系统设置中允许访问麦克风。';
    }
    if (lower.contains('audio-capture')) {
      return '未检测到可用麦克风设备。';
    }
    if (lower.contains('network')) {
      return '语音识别服务网络不可用（浏览器自带语音识别需要联网；正式版手机端可切离线 Sherpa-ONNX）。';
    }
    return '语音识别遇到异常：$raw';
  }
}
