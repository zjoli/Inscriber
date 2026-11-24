import 'package:flutter/material.dart';

/// 温暖纸感极简配色系统（参考 Granola 风格）
/// - 暖米白纸感底色 + 纯白卡片/胶囊按钮 + 炭黑主按钮 + 鲜活草绿实时状态点缀
class AppColors {
  AppColors._();

  /// 主背景：温暖纸感米灰
  static const Color background = Color(0xFFF1F0EC);

  /// 卡片 / 胶囊按钮表面：纯白
  static const Color surface = Color(0xFFFFFFFF);

  /// 次级填充 / 标签底色：浅暖灰
  static const Color surfaceMuted = Color(0xFFE9E7E1);

  /// 柔和标签芯片底色
  static const Color chipBackground = Color(0xFFF4F3EE);

  /// 极细描边 / 分割线
  static const Color border = Color(0xFFDFDDD6);

  /// 主文字 / 图标 / 主 CTA 按钮背景（炭黑）
  static const Color inkPrimary = Color(0xFF20201E);

  /// 次级文字 / 正文说明（暖中灰）
  static const Color inkSecondary = Color(0xFF6E6D68);

  /// 占位文字 / 弱提示（浅暖灰）
  static const Color inkTertiary = Color(0xFF93918B);

  /// 点缀色：鲜活草绿（用于运行状态、音量/节奏指示、焦点高亮）
  static const Color accentGreen = Color(0xFF68C22E);

  /// 点缀绿浅底色
  static const Color accentGreenSoft = Color(0xFFEAF6E1);

  /// 点缀绿深文字色（保证在浅绿底上的高对比度）
  static const Color accentGreenDark = Color(0xFF3E7F16);

  /// 柔和警示红
  static const Color danger = Color(0xFFD64545);

  /// 预览暗箱底色（用于对比展示透明悬浮白字效果）
  static const Color previewDarkSurface = Color(0xFF232421);
}

class AppTheme {
  AppTheme._();

  static ThemeData build() {
    final colorScheme = ColorScheme.fromSeed(
      seedColor: AppColors.accentGreen,
      brightness: Brightness.light,
      primary: AppColors.inkPrimary,
      onPrimary: Colors.white,
      secondary: AppColors.accentGreen,
      onSecondary: Colors.white,
      surface: AppColors.surface,
      onSurface: AppColors.inkPrimary,
      outline: AppColors.border,
    );

    return ThemeData(
      useMaterial3: true,
      colorScheme: colorScheme,
      scaffoldBackgroundColor: AppColors.background,
      appBarTheme: const AppBarTheme(
        backgroundColor: AppColors.background,
        foregroundColor: AppColors.inkPrimary,
        surfaceTintColor: Colors.transparent,
        elevation: 0,
        centerTitle: false,
      ),
      dividerColor: AppColors.border,
      sliderTheme: SliderThemeData(
        activeTrackColor: AppColors.inkPrimary,
        inactiveTrackColor: AppColors.border,
        thumbColor: AppColors.inkPrimary,
        overlayColor: AppColors.inkPrimary.withValues(alpha: 0.12),
        trackHeight: 3.5,
      ),
      switchTheme: SwitchThemeData(
        thumbColor: WidgetStateProperty.resolveWith((states) {
          return Colors.white;
        }),
        trackColor: WidgetStateProperty.resolveWith((states) {
          if (states.contains(WidgetState.selected)) {
            return AppColors.accentGreen;
          }
          return AppColors.border;
        }),
        trackOutlineColor: WidgetStateProperty.all(Colors.transparent),
      ),
      filledButtonTheme: FilledButtonThemeData(
        style: FilledButton.styleFrom(
          backgroundColor: AppColors.inkPrimary,
          foregroundColor: Colors.white,
          elevation: 0,
          shape: const StadiumBorder(),
          textStyle: const TextStyle(
            fontWeight: FontWeight.w600,
            fontSize: 14.5,
          ),
        ),
      ),
      outlinedButtonTheme: OutlinedButtonThemeData(
        style: OutlinedButton.styleFrom(
          backgroundColor: AppColors.surface,
          foregroundColor: AppColors.inkPrimary,
          side: const BorderSide(color: AppColors.border, width: 1.2),
          shape: const StadiumBorder(),
          textStyle: const TextStyle(
            fontWeight: FontWeight.w600,
            fontSize: 14.5,
          ),
        ),
      ),
      floatingActionButtonTheme: const FloatingActionButtonThemeData(
        backgroundColor: AppColors.inkPrimary,
        foregroundColor: Colors.white,
        elevation: 2,
        shape: StadiumBorder(),
      ),
      snackBarTheme: SnackBarThemeData(
        backgroundColor: AppColors.inkPrimary,
        contentTextStyle: const TextStyle(color: Colors.white, fontSize: 13.5),
        behavior: SnackBarBehavior.floating,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(14),
        ),
      ),
      inputDecorationTheme: InputDecorationTheme(
        filled: true,
        fillColor: AppColors.surface,
        hintStyle: const TextStyle(color: AppColors.inkTertiary),
        labelStyle: const TextStyle(color: AppColors.inkSecondary),
        border: OutlineInputBorder(
          borderRadius: BorderRadius.circular(14),
          borderSide: const BorderSide(color: AppColors.border),
        ),
        enabledBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(14),
          borderSide: const BorderSide(color: AppColors.border),
        ),
        focusedBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(14),
          borderSide: const BorderSide(color: AppColors.inkPrimary, width: 1.4),
        ),
      ),
    );
  }
}
