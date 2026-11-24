import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import '../theme/app_theme.dart';

/// 在 Chrome Web / 桌面宽屏环境下，自动以标准手机比例（390 × 844）居中展示应用；
/// 在真实手机端或窄屏窗口下直接全屏渲染，无任何多余装饰。
class MobilePreviewFrame extends StatelessWidget {
  const MobilePreviewFrame({
    super.key,
    required this.child,
  });

  final Widget child;

  static const double phoneWidth = 390.0;
  static const double phoneHeight = 844.0;

  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(
      builder: (context, constraints) {
        final shouldWrapAsPhone =
            (kIsWeb || constraints.maxWidth > 520) && constraints.maxWidth > 500;
        if (!shouldWrapAsPhone) {
          return child;
        }

        final parentMediaQuery = MediaQuery.of(context);
        final phoneMediaQuery = parentMediaQuery.copyWith(
          size: const Size(phoneWidth, phoneHeight),
          padding: const EdgeInsets.only(top: 48, bottom: 24),
          viewPadding: const EdgeInsets.only(top: 48, bottom: 24),
        );

        return Container(
          decoration: const BoxDecoration(
            gradient: RadialGradient(
              center: Alignment(0, -0.25),
              radius: 1.15,
              colors: [Color(0xFFE7E5DE), Color(0xFFD6D3C9)],
            ),
          ),
          alignment: Alignment.center,
          padding: const EdgeInsets.symmetric(vertical: 20, horizontal: 16),
          child: FittedBox(
            fit: BoxFit.contain,
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                // 精致手机外框
                Container(
                  width: phoneWidth + 18,
                  height: phoneHeight + 18,
                  padding: const EdgeInsets.all(9),
                  decoration: BoxDecoration(
                    color: const Color(0xFF20201E),
                    borderRadius: BorderRadius.circular(52),
                    border: Border.all(
                      color: const Color(0xFF3E3E3A),
                      width: 1.8,
                    ),
                    boxShadow: const [
                      BoxShadow(
                        color: Color(0x38000000),
                        blurRadius: 38,
                        spreadRadius: 2,
                        offset: Offset(0, 18),
                      ),
                    ],
                  ),
                  child: ClipRRect(
                    borderRadius: BorderRadius.circular(44),
                    child: SizedBox(
                      width: phoneWidth,
                      height: phoneHeight,
                      child: Stack(
                        fit: StackFit.expand,
                        children: [
                          MediaQuery(
                            data: phoneMediaQuery,
                            child: child,
                          ),
                          // 顶部模拟手机状态栏与灵动岛（不拦截点击事件）
                          const Positioned(
                            top: 0,
                            left: 0,
                            right: 0,
                            height: 46,
                            child: IgnorePointer(
                              child: _PhoneStatusBarOverlay(),
                            ),
                          ),
                          // 底部模拟手势横条
                          Positioned(
                            bottom: 8,
                            left: 0,
                            right: 0,
                            child: IgnorePointer(
                              child: Center(
                                child: Container(
                                  width: 126,
                                  height: 4.5,
                                  decoration: BoxDecoration(
                                    color: AppColors.inkPrimary
                                        .withValues(alpha: 0.25),
                                    borderRadius: BorderRadius.circular(4),
                                  ),
                                ),
                              ),
                            ),
                          ),
                        ],
                      ),
                    ),
                  ),
                ),
                const SizedBox(height: 12),
                Text(
                  'Inscriber · 手机布局预览 (390 × 844)',
                  style: TextStyle(
                    fontSize: 12,
                    color: AppColors.inkPrimary.withValues(alpha: 0.55),
                    letterSpacing: 0.4,
                    decoration: TextDecoration.none,
                    fontWeight: FontWeight.w500,
                  ),
                ),
              ],
            ),
          ),
        );
      },
    );
  }
}

class _PhoneStatusBarOverlay extends StatelessWidget {
  const _PhoneStatusBarOverlay();

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 10),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.center,
        children: [
          const Text(
            '9:41',
            style: TextStyle(
              color: AppColors.inkPrimary,
              fontSize: 13.5,
              fontWeight: FontWeight.w600,
              decoration: TextDecoration.none,
            ),
          ),
          const Spacer(),
          // 灵动岛 / 前置摄像头指示区（提醒提词位置贴近镜头）
          Container(
            width: 108,
            height: 26,
            decoration: BoxDecoration(
              color: const Color(0xFF1A1A18),
              borderRadius: BorderRadius.circular(18),
            ),
            alignment: Alignment.centerRight,
            padding: const EdgeInsets.only(right: 10),
            child: Container(
              width: 10,
              height: 10,
              decoration: BoxDecoration(
                shape: BoxShape.circle,
                color: const Color(0xFF1E293B),
                border: Border.all(color: const Color(0xFF334155), width: 1.5),
              ),
            ),
          ),
          const Spacer(),
          const Icon(
            Icons.signal_cellular_alt,
            color: AppColors.inkPrimary,
            size: 15,
          ),
          const SizedBox(width: 5),
          const Icon(Icons.wifi, color: AppColors.inkPrimary, size: 15),
          const SizedBox(width: 5),
          const Icon(Icons.battery_full, color: AppColors.inkPrimary, size: 16),
        ],
      ),
    );
  }
}
