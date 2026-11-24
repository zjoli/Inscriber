import 'dart:async';
import 'dart:math' as math;
import 'dart:typed_data';
import 'package:record/record.dart';
import 'package:sherpa_onnx/sherpa_onnx.dart' as sherpa_onnx;
import 'offline_model_manager.dart';
import 'voice_recognizer.dart';

/// 端侧全离线流式语音识别器（Android / iOS / macOS / Desktop）
/// 基于 Sherpa-ONNX + streaming-zipformer-bilingual-zh-en-2023-02-20（int8）
/// - 通过 record 插件实时采集 16kHz 单声道 PCM16 音频流
/// - 边说边解码（< 200ms 延迟），无需联网、零 API 费用
class SherpaOnnxVoiceRecognizer implements VoiceRecognizer {
  SherpaOnnxVoiceRecognizer({OfflineModelManager? modelManager})
      : _modelManager = modelManager ?? OfflineModelManager.instance;

  final OfflineModelManager _modelManager;
  AudioRecorder? _recorder;
  final StreamController<VoiceRecognitionEvent> _controller =
      StreamController<VoiceRecognitionEvent>.broadcast();

  sherpa_onnx.OnlineRecognizer? _recognizer;
  sherpa_onnx.OnlineStream? _stream;
  StreamSubscription<Uint8List>? _audioSub;

  VoiceRecognizerState _state = VoiceRecognizerState.idle;
  bool _bindingsInitialized = false;
  bool _disposed = false;
  String _lastEmittedText = '';

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
    if (_recognizer != null) return true;
    _emit(const VoiceRecognitionEvent(state: VoiceRecognizerState.initializing));

    try {
      final paths = await _modelManager.getModelPaths();
      if (paths == null) {
        _emit(
          const VoiceRecognitionEvent(
            state: VoiceRecognizerState.unavailable,
            errorMessage: '离线语音模型尚未下载，请先完成首次下载。',
          ),
        );
        return false;
      }

      if (!_bindingsInitialized) {
        sherpa_onnx.initBindings();
        _bindingsInitialized = true;
      }

      final config = sherpa_onnx.OnlineRecognizerConfig(
        model: sherpa_onnx.OnlineModelConfig(
          transducer: sherpa_onnx.OnlineTransducerModelConfig(
            encoder: paths.encoderPath,
            decoder: paths.decoderPath,
            joiner: paths.joinerPath,
          ),
          tokens: paths.tokensPath,
          numThreads: 2,
          provider: 'cpu',
          modelType: '', // 留空自动识别 Zipformer 元数据
        ),
        decodingMethod: 'greedy_search',
        enableEndpoint: true,
        rule1MinTrailingSilence: 2.4,
        rule2MinTrailingSilence: 1.2,
        rule3MinUtteranceLength: 20.0,
      );

      _recognizer = sherpa_onnx.OnlineRecognizer(config);
      _emit(const VoiceRecognitionEvent(state: VoiceRecognizerState.idle));
      return true;
    } catch (e) {
      _emit(
        VoiceRecognitionEvent(
          state: VoiceRecognizerState.error,
          errorMessage: '加载离线语音模型失败：$e',
        ),
      );
      return false;
    }
  }

  @override
  Future<bool> startListening({String localeId = 'zh_CN'}) async {
    final ready = await initialize();
    if (!ready || _recognizer == null) return false;

    try {
      final recorder = _recorder ??= AudioRecorder();
      final hasPermission = await recorder.hasPermission();
      if (!hasPermission) {
        _emit(
          const VoiceRecognitionEvent(
            state: VoiceRecognizerState.error,
            errorMessage: '麦克风权限未开启，请在系统设置中允许访问麦克风。',
          ),
        );
        return false;
      }

      await stopListening();

      _stream = _recognizer!.createStream();
      _lastEmittedText = '';

      final pcmStream = await recorder.startStream(
        const RecordConfig(
          encoder: AudioEncoder.pcm16bits,
          sampleRate: 16000,
          numChannels: 1,
        ),
      );

      _audioSub = pcmStream.listen(
        _onPcmChunk,
        onError: (Object error) {
          _emit(
            VoiceRecognitionEvent(
              state: VoiceRecognizerState.error,
              errorMessage: '麦克风音频流中断：$error',
            ),
          );
        },
      );

      _emit(const VoiceRecognitionEvent(state: VoiceRecognizerState.listening));
      return true;
    } catch (e) {
      _emit(
        VoiceRecognitionEvent(
          state: VoiceRecognizerState.error,
          errorMessage: '无法开启离线语音采集：$e',
        ),
      );
      return false;
    }
  }

  void _onPcmChunk(Uint8List bytes) {
    final recognizer = _recognizer;
    final stream = _stream;
    if (_disposed || recognizer == null || stream == null || bytes.length < 2) {
      return;
    }

    // PCM16 Little-Endian -> 归一化 Float32 [-1.0, 1.0]，同时计算 RMS 音量驱动声波条
    final sampleCount = bytes.length ~/ 2;
    final floatSamples = Float32List(sampleCount);
    final data = ByteData.sublistView(bytes);
    double sumSquares = 0.0;

    for (int i = 0; i < sampleCount; i++) {
      final sample = data.getInt16(i * 2, Endian.little) / 32768.0;
      floatSamples[i] = sample;
      sumSquares += sample * sample;
    }

    final rms = math.sqrt(sumSquares / sampleCount);
    final normalizedLevel = (rms * 5.5).clamp(0.0, 1.0);
    _emit(VoiceRecognitionEvent(soundLevel: normalizedLevel));

    stream.acceptWaveform(samples: floatSamples, sampleRate: 16000);
    while (recognizer.isReady(stream)) {
      recognizer.decode(stream);
    }

    final text = recognizer.getResult(stream).text.trim();
    final isEndpoint = recognizer.isEndpoint(stream);

    if (text.isNotEmpty && text != _lastEmittedText) {
      _lastEmittedText = text;
      _emit(
        VoiceRecognitionEvent(
          partialText: text,
          isFinal: isEndpoint,
        ),
      );
    }

    // 检测到句尾停顿时重置流上下文，保持长时间口播低延迟低内存
    if (isEndpoint) {
      recognizer.reset(stream);
      _lastEmittedText = '';
    }
  }

  @override
  Future<void> stopListening() async {
    await _audioSub?.cancel();
    _audioSub = null;
    try {
      final recorder = _recorder;
      if (recorder != null && await recorder.isRecording()) {
        await recorder.stop();
      }
    } catch (_) {}

    _stream?.free();
    _stream = null;
    _lastEmittedText = '';

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
    await stopListening();
    _recognizer?.free();
    _recognizer = null;
    await _recorder?.dispose();
    _recorder = null;
    await _controller.close();
  }
}
