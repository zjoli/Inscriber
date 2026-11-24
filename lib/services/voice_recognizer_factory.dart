import 'package:flutter/foundation.dart';
import 'offline_model_manager.dart';
import 'sherpa_voice_recognizer.dart';
import 'voice_recognizer.dart';

/// 按运行平台自动创建最佳实时流式语音识别器：
/// - Android / iOS / macOS / Desktop：优先使用本地全离线 Sherpa-ONNX（Zipformer 中英双语）
/// - Chrome Web：使用浏览器内置 Web Speech API
VoiceRecognizer createDefaultVoiceRecognizer({
  OfflineModelManager? modelManager,
}) {
  if (kIsWeb) {
    return SystemSpeechVoiceRecognizer();
  }
  return SherpaOnnxVoiceRecognizer(
    modelManager: modelManager ?? OfflineModelManager.instance,
  );
}
