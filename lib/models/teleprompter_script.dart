import 'dart:convert';
import 'package:flutter/material.dart';

/// 提词滚动模式（当前支持固定速率，预留 AI 语音跟随扩展）
enum ScrollMode {
  fixedRate,
  aiVoice,
}

extension ScrollModeX on ScrollMode {
  String get label {
    switch (this) {
      case ScrollMode.fixedRate:
        return '固定速率';
      case ScrollMode.aiVoice:
        return 'AI 语音跟随';
    }
  }

  String get storageValue => name;

  static ScrollMode fromStorage(String? value) {
    return ScrollMode.values.firstWhere(
      (mode) => mode.name == value,
      orElse: () => ScrollMode.fixedRate,
    );
  }
}

/// 单个提词的播放与外观配置
class TeleprompterSettings {
  const TeleprompterSettings({
    this.scrollMode = ScrollMode.fixedRate,
    this.charsPerMinute = 180,
    this.fontSize = 22.0,
    this.visibleLines = 3,
    this.activeTextColorValue = 0xFF20201E,
    this.inactiveTextColorValue = 0x996E6D68,
    this.backgroundOpacity = 0.0,
    this.enableTextShadow = true,
    this.mirrorMode = false,
    this.maxCharsPerLine = 16,
  });

  /// 滚动模式（固定速率 / 预留 AI 语音）
  final ScrollMode scrollMode;

  /// 固定速率：每分钟朗读字数（CPM），范围建议 60 ~ 420
  final int charsPerMinute;

  /// 提词主行字体大小（sp）
  final double fontSize;

  /// 悬浮时同时显示的行数（默认 3 行，歌词式居中高亮）
  final int visibleLines;

  /// 当前朗读行文字颜色
  final int activeTextColorValue;

  /// 上一行 / 下一行文字颜色
  final int inactiveTextColorValue;

  /// 悬浮层背景透明度（0.0 = 完全透明，1.0 = 完全不透明）
  final double backgroundOpacity;

  /// 是否开启文字阴影/描边（透明悬浮时强烈建议开启，保证浅色画面清晰可读）
  final bool enableTextShadow;

  /// 镜像模式（配合实体分光镜提词器使用）
  final bool mirrorMode;

  /// 每行预期排版字数（用于统一估算换行与歌词滚动节奏）
  final int maxCharsPerLine;

  Color get activeTextColor => Color(activeTextColorValue);
  Color get inactiveTextColor => Color(inactiveTextColorValue);

  TeleprompterSettings copyWith({
    ScrollMode? scrollMode,
    int? charsPerMinute,
    double? fontSize,
    int? visibleLines,
    int? activeTextColorValue,
    int? inactiveTextColorValue,
    double? backgroundOpacity,
    bool? enableTextShadow,
    bool? mirrorMode,
    int? maxCharsPerLine,
  }) {
    return TeleprompterSettings(
      scrollMode: scrollMode ?? this.scrollMode,
      charsPerMinute: charsPerMinute ?? this.charsPerMinute,
      fontSize: fontSize ?? this.fontSize,
      visibleLines: visibleLines ?? this.visibleLines,
      activeTextColorValue: activeTextColorValue ?? this.activeTextColorValue,
      inactiveTextColorValue:
          inactiveTextColorValue ?? this.inactiveTextColorValue,
      backgroundOpacity: backgroundOpacity ?? this.backgroundOpacity,
      enableTextShadow: enableTextShadow ?? this.enableTextShadow,
      mirrorMode: mirrorMode ?? this.mirrorMode,
      maxCharsPerLine: maxCharsPerLine ?? this.maxCharsPerLine,
    );
  }

  Map<String, dynamic> toJson() {
    return {
      'scrollMode': scrollMode.storageValue,
      'charsPerMinute': charsPerMinute,
      'fontSize': fontSize,
      'visibleLines': visibleLines,
      'activeTextColorValue': activeTextColorValue,
      'inactiveTextColorValue': inactiveTextColorValue,
      'backgroundOpacity': backgroundOpacity,
      'enableTextShadow': enableTextShadow,
      'mirrorMode': mirrorMode,
      'maxCharsPerLine': maxCharsPerLine,
    };
  }

  factory TeleprompterSettings.fromJson(Map<String, dynamic>? json) {
    if (json == null) return const TeleprompterSettings();
    return TeleprompterSettings(
      scrollMode: ScrollModeX.fromStorage(json['scrollMode'] as String?),
      charsPerMinute: (json['charsPerMinute'] as num?)?.toInt() ?? 180,
      fontSize: (json['fontSize'] as num?)?.toDouble() ?? 22.0,
      visibleLines: (json['visibleLines'] as num?)?.toInt() ?? 3,
      activeTextColorValue:
          (json['activeTextColorValue'] as num?)?.toInt() ?? 0xFF20201E,
      inactiveTextColorValue:
          (json['inactiveTextColorValue'] as num?)?.toInt() ?? 0x996E6D68,
      backgroundOpacity:
          (json['backgroundOpacity'] as num?)?.toDouble() ?? 0.0,
      enableTextShadow: json['enableTextShadow'] as bool? ?? true,
      mirrorMode: json['mirrorMode'] as bool? ?? false,
      maxCharsPerLine: (json['maxCharsPerLine'] as num?)?.toInt() ?? 16,
    );
  }
}

/// 提词稿件实体
class TeleprompterScript {
  const TeleprompterScript({
    required this.id,
    required this.title,
    required this.content,
    required this.updatedAt,
    this.settings = const TeleprompterSettings(),
  });

  final String id;
  final String title;
  final String content;
  final DateTime updatedAt;
  final TeleprompterSettings settings;

  /// 统计有效朗读字符数（去除空白符）
  int get charCount => content.replaceAll(RegExp(r'\s+'), '').length;

  /// 按当前设定速率估算总朗读时长
  Duration get estimatedDuration {
    if (charCount == 0 || settings.charsPerMinute <= 0) {
      return Duration.zero;
    }
    final seconds = (charCount / settings.charsPerMinute * 60).ceil();
    return Duration(seconds: seconds);
  }

  String get formattedDuration {
    final totalSeconds = estimatedDuration.inSeconds;
    final minutes = totalSeconds ~/ 60;
    final seconds = totalSeconds % 60;
    if (minutes == 0) {
      return '$seconds秒';
    }
    return '$minutes分${seconds.toString().padLeft(2, '0')}秒';
  }

  TeleprompterScript copyWith({
    String? id,
    String? title,
    String? content,
    DateTime? updatedAt,
    TeleprompterSettings? settings,
  }) {
    return TeleprompterScript(
      id: id ?? this.id,
      title: title ?? this.title,
      content: content ?? this.content,
      updatedAt: updatedAt ?? this.updatedAt,
      settings: settings ?? this.settings,
    );
  }

  Map<String, dynamic> toJson() {
    return {
      'id': id,
      'title': title,
      'content': content,
      'updatedAt': updatedAt.toIso8601String(),
      'settings': settings.toJson(),
    };
  }

  factory TeleprompterScript.fromJson(Map<String, dynamic> json) {
    return TeleprompterScript(
      id: json['id'] as String,
      title: json['title'] as String? ?? '未命名提词',
      content: json['content'] as String? ?? '',
      updatedAt: DateTime.tryParse(json['updatedAt'] as String? ?? '') ??
          DateTime.now(),
      settings: TeleprompterSettings.fromJson(
        json['settings'] as Map<String, dynamic>?,
      ),
    );
  }

  static String encodeList(List<TeleprompterScript> scripts) {
    return jsonEncode(scripts.map((s) => s.toJson()).toList());
  }

  static List<TeleprompterScript> decodeList(String raw) {
    final decoded = jsonDecode(raw) as List<dynamic>;
    return decoded
        .map((e) => TeleprompterScript.fromJson(e as Map<String, dynamic>))
        .toList();
  }
}
