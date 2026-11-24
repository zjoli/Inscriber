import 'dart:async';
import 'offline_model_manager.dart';
import 'voice_recognizer.dart';

/// Web 平台占位实现（Web 端无本地文件系统与原生 FFI，自动由工厂切换为浏览器语音识别）
class SherpaOnnxVoiceRecognizer implements VoiceRecognizer {
  SherpaOnnxVoiceRecognizer({OfflineModelManager? modelManager});

  final StreamController<VoiceRecognitionEvent> _controller =
      StreamController<VoiceRecognitionEvent>.broadcast();

  @override
  Stream<VoiceRecognitionEvent> get events => _controller.stream;

  @override
  VoiceRecognizerState get state => VoiceRecognizerState.unavailable;

  @override
  bool get isListening => false;

  @override
  Future<bool> initialize() async => false;

  @override
  Future<bool> startListening({String localeId = 'zh_CN'}) async => false;

  @override
  Future<void> stopListening() async {}

  @override
  Future<void> dispose() => _controller.close();
}
