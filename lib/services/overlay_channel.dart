import 'dart:io';
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import '../models/teleprompter_script.dart';

/// 系统级跨应用悬浮能力状态
class OverlayStartResult {
  const OverlayStartResult({
    required this.started,
    required this.message,
    this.requiresPermission = false,
  });

  final bool started;
  final String message;
  final bool requiresPermission;
}

/// 来自原生悬浮窗（Android 透明悬浮窗 / iOS 画中画）的反向事件回调
typedef OverlayLifecycleCallback = void Function();
typedef OverlayPlayStateCallback = void Function(bool isPlaying);

/// 与 Android 透明悬浮窗 / iOS 画中画双向通信的原生桥接层
/// - Flutter -> Native: startOverlay / updateSettings / syncProgress / setAiVoiceMode / stopOverlay
/// - Native -> Flutter: onOverlayStopped / onOverlayPlayStateChanged / onOverlayReset
class OverlayChannel {
  static const MethodChannel _channel = MethodChannel('com.inscriber/overlay');

  static bool _handlerRegistered = false;
  static OverlayLifecycleCallback? _onOverlayStopped;
  static OverlayPlayStateCallback? _onOverlayPlayStateChanged;
  static OverlayLifecycleCallback? _onOverlayReset;

  /// 注册原生悬浮窗反向事件监听（由 BackgroundOverlayVoiceController 调用）
  static void bindNativeCallbacks({
    OverlayLifecycleCallback? onStopped,
    OverlayPlayStateCallback? onPlayStateChanged,
    OverlayLifecycleCallback? onReset,
  }) {
    _onOverlayStopped = onStopped;
    _onOverlayPlayStateChanged = onPlayStateChanged;
    _onOverlayReset = onReset;

    if (!_handlerRegistered) {
      _handlerRegistered = true;
      _channel.setMethodCallHandler((call) async {
        switch (call.method) {
          case 'onOverlayStopped':
            _onOverlayStopped?.call();
            break;
          case 'onOverlayPlayStateChanged':
            final playing = call.arguments as bool? ?? false;
            _onOverlayPlayStateChanged?.call(playing);
            break;
          case 'onOverlayReset':
            _onOverlayReset?.call();
            break;
        }
      });
    }
  }

  /// 当前运行平台是否支持跨应用悬浮
  static bool get isMobilePlatform =>
      !kIsWeb && (Platform.isAndroid || Platform.isIOS);

  static String get platformCapabilityHint {
    if (kIsWeb) return 'Web 端仅支持应用内悬浮预览';
    if (Platform.isAndroid) {
      return 'Android 支持全透明系统悬浮窗，并可由后台 Sherpa-ONNX 实时驱动 AI 语音跟随';
    }
    if (Platform.isIOS) {
      return 'iOS 将以画中画（PiP）悬浮在其他应用上方，支持后台 Sherpa-ONNX 实时同步 AI 跟读进度';
    }
    return '当前桌面端支持应用内预览模式';
  }

  /// 检查是否具备悬浮窗权限（iOS 返回画中画支持状态，Android 检查 SYSTEM_ALERT_WINDOW）
  static Future<bool> hasOverlayPermission() async {
    if (!isMobilePlatform) return false;
    try {
      final granted = await _channel.invokeMethod<bool>('hasPermission');
      return granted ?? false;
    } on PlatformException {
      return false;
    } on MissingPluginException {
      return false;
    }
  }

  /// 跳转系统设置申请悬浮窗权限（Android）
  static Future<void> requestOverlayPermission() async {
    if (!isMobilePlatform) return;
    try {
      await _channel.invokeMethod<void>('requestPermission');
    } on PlatformException {
      // 忽略异常，由上层提示用户
    } on MissingPluginException {
      // 非移动宿主环境忽略
    }
  }

  /// 启动系统级悬浮提词（Android: 透明悬浮窗服务；iOS: 画中画窗口）
  static Future<OverlayStartResult> startOverlay({
    required TeleprompterScript script,
    required List<String> lines,
  }) async {
    if (!isMobilePlatform) {
      return const OverlayStartResult(
        started: false,
        message: '当前平台不支持系统级悬浮，请使用应用内悬浮预览。',
      );
    }

    try {
      final hasPerm = await hasOverlayPermission();
      if (!hasPerm && Platform.isAndroid) {
        await requestOverlayPermission();
        return const OverlayStartResult(
          started: false,
          requiresPermission: true,
          message: '请在系统设置中开启“显示在其他应用的上层”权限后，再次点击启动。',
        );
      }

      final isAiVoice = script.settings.scrollMode == ScrollMode.aiVoice;
      final ok = await _channel.invokeMethod<bool>('startOverlay', {
        'title': script.title,
        'lines': lines,
        'charsPerMinute': script.settings.charsPerMinute,
        'fontSize': script.settings.fontSize,
        'visibleLines': script.settings.visibleLines,
        'activeTextColor': script.settings.activeTextColorValue,
        'inactiveTextColor': script.settings.inactiveTextColorValue,
        'backgroundOpacity': script.settings.backgroundOpacity,
        'enableTextShadow': script.settings.enableTextShadow,
        'mirrorMode': script.settings.mirrorMode,
        'aiVoiceMode': isAiVoice,
      });

      if (ok == true) {
        return OverlayStartResult(
          started: true,
          message: Platform.isAndroid
              ? (isAiVoice
                  ? '透明悬浮窗与后台 AI 语音跟读已启动，可直接切换到相机或直播应用。'
                  : '透明悬浮提词已启动，现在可以切换到相机或任意应用使用。')
              : (isAiVoice
                  ? '画中画提词与后台 AI 语音跟读已启动，切换应用后自动悬浮。'
                  : '画中画提词已启动，切换至其他应用后将自动以小窗悬浮。'),
        );
      }
      return const OverlayStartResult(
        started: false,
        message: '启动悬浮提词失败，请检查系统权限或画中画设置。',
      );
    } on MissingPluginException {
      return const OverlayStartResult(
        started: false,
        message: '未检测到原生悬浮插件通道（请使用 Android / iOS 真机或模拟器运行）。',
      );
    } on PlatformException catch (e) {
      return OverlayStartResult(
        started: false,
        message: e.message ?? '启动悬浮窗时发生系统异常。',
      );
    }
  }

  /// 实时同步 Flutter 后台 Sherpa-ONNX 计算出的最新朗读进度给原生悬浮窗 / 画中画
  /// [lineProgress] 为 Flutter 侧行进度；[charRatio] 为全文可读字比例 [0.0, 1.0]（抗不同换行宽度偏差）
  static Future<void> syncProgress({
    required double lineProgress,
    required double charRatio,
    String? recognizedText,
  }) async {
    if (!isMobilePlatform) return;
    try {
      await _channel.invokeMethod<void>('syncProgress', {
        'progress': lineProgress,
        'charRatio': charRatio.clamp(0.0, 1.0),
        if (recognizedText != null) 'recognizedText': recognizedText,
      });
    } catch (_) {
      // 悬浮窗未运行或已关闭时忽略
    }
  }

  /// 通知原生悬浮窗切换外部 AI 跟随 / 固定速率降级模式
  static Future<void> setAiVoiceMode(bool enabled) async {
    if (!isMobilePlatform) return;
    try {
      await _channel.invokeMethod<void>('setAiVoiceMode', {
        'enabled': enabled,
      });
    } catch (_) {
      // 忽略
    }
  }

  /// 动态更新正在运行的悬浮窗参数（如速率、字号、透明度）
  static Future<void> updateOverlaySettings(
    TeleprompterSettings settings,
  ) async {
    if (!isMobilePlatform) return;
    try {
      await _channel.invokeMethod<void>('updateSettings', {
        'charsPerMinute': settings.charsPerMinute,
        'fontSize': settings.fontSize,
        'visibleLines': settings.visibleLines,
        'activeTextColor': settings.activeTextColorValue,
        'inactiveTextColor': settings.inactiveTextColorValue,
        'backgroundOpacity': settings.backgroundOpacity,
        'enableTextShadow': settings.enableTextShadow,
        'mirrorMode': settings.mirrorMode,
        'aiVoiceMode': settings.scrollMode == ScrollMode.aiVoice,
      });
    } catch (_) {
      // 悬浮窗未运行时忽略
    }
  }

  /// 关闭系统级悬浮提词
  static Future<void> stopOverlay() async {
    if (!isMobilePlatform) return;
    try {
      await _channel.invokeMethod<void>('stopOverlay');
    } catch (_) {
      // 忽略
    }
  }
}
