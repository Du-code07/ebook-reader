import 'package:flutter/material.dart';

import '../widgets/app_colors.dart';

/// 시작 화면: 앱을 켤 때 가운데 앱 아이콘이 움직이며 나타나고, 약 2.6초 뒤 사라지며 다음 화면(첫 실행이면 언어 선택)으로
/// 아이콘은 지금 앱 아이콘(Flutter 기본 로고)을 그대로 씀. 나중에 앱 아이콘을 바꾸면 [_AppIcon]만 바꾸면 됨
class SplashOverlay extends StatefulWidget {
  const SplashOverlay({super.key, required this.onDone});
  final VoidCallback onDone;

  @override
  State<SplashOverlay> createState() => _SplashOverlayState();
}

class _SplashOverlayState extends State<SplashOverlay> with SingleTickerProviderStateMixin {
  static const int _totalMs = 2600;
  late final AnimationController _c = AnimationController(vsync: this, duration: const Duration(milliseconds: _totalMs));

  // 구간: 아이콘이 튀어나옴 → 뒤로 퍼지는 동그라미 → 이름이 아래에서 올라옴 → 잠깐 머문 뒤 사라짐
  late final Animation<double> _iconIn = CurvedAnimation(parent: _c, curve: const Interval(0.0, 0.30, curve: Curves.easeOutBack));
  late final Animation<double> _iconFade = CurvedAnimation(parent: _c, curve: const Interval(0.0, 0.16, curve: Curves.easeOut));
  late final Animation<double> _ring = CurvedAnimation(parent: _c, curve: const Interval(0.16, 0.62, curve: Curves.easeOutCubic));
  late final Animation<double> _name = CurvedAnimation(parent: _c, curve: const Interval(0.28, 0.50, curve: Curves.easeOutCubic));
  late final Animation<double> _out = CurvedAnimation(parent: _c, curve: const Interval(0.85, 1.0, curve: Curves.easeInCubic));

  @override
  void initState() {
    super.initState();
    // 움직임 멈추기를 켰으면 움직이지 않고 다 나온 모습으로 보여 줌
    if (Anim.off.value) _c.value = 0.84;
    _c.forward().whenCompleteOrCancel(() {
      if (mounted) widget.onDone();
    });
  }

  @override
  void dispose() {
    _c.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final Color bg = Theme.of(context).scaffoldBackgroundColor;
    final Color sig = AppColors.of(context);
    final Color fg = Theme.of(context).colorScheme.onSurface;
    const double iconSize = 112;
    return AbsorbPointer(
      child: AnimatedBuilder(
        animation: _c,
        builder: (context, _) {
          final double out = _out.value;
          return Opacity(
            opacity: 1 - out,
            child: ColoredBox(
              color: bg,
              child: Center(
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    SizedBox(
                      width: iconSize * 2.2,
                      height: iconSize * 2.2,
                      child: Stack(
                        alignment: Alignment.center,
                        children: [
                          // 아이콘 뒤로 퍼지며 옅어지는 동그라미
                          if (_ring.value > 0 && _ring.value < 1)
                            Transform.scale(
                              scale: 0.7 + 1.3 * _ring.value,
                              child: Container(
                                width: iconSize * 1.1,
                                height: iconSize * 1.1,
                                decoration: BoxDecoration(
                                  shape: BoxShape.circle,
                                  color: sig.withValues(alpha: 0.32 * (1 - _ring.value)),
                                ),
                              ),
                            ),
                          // 앱 아이콘: 작게 시작해 살짝 튕기며 커짐, 사라질 때 조금 더 커짐
                          Opacity(
                            opacity: _iconFade.value.clamp(0.0, 1.0),
                            child: Transform.scale(
                              scale: (0.45 + 0.55 * _iconIn.value) * (1 + 0.08 * out),
                              child: const _AppIcon(size: iconSize),
                            ),
                          ),
                        ],
                      ),
                    ),
                    // 앱 이름
                    Opacity(
                      opacity: _name.value.clamp(0.0, 1.0),
                      child: Transform.translate(
                        offset: Offset(0, 14 * (1 - _name.value)),
                        child: Text(
                          'FReader',
                          style: TextStyle(color: fg, fontSize: 26, fontWeight: FontWeight.w800, letterSpacing: 0.6),
                        ),
                      ),
                    ),
                  ],
                ),
              ),
            ),
          );
        },
      ),
    );
  }
}

/// 지금 앱 아이콘 (Flutter 기본 로고)
class _AppIcon extends StatelessWidget {
  const _AppIcon({required this.size});
  final double size;

  @override
  Widget build(BuildContext context) => FlutterLogo(size: size);
}
