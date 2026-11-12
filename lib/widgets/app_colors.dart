import 'package:flutter/material.dart';

/// 앱 대표 색 (연두색): 고른 것·켜짐·버튼 바탕과 체크 표시에만 쓰고, 글씨·아이콘에는 쓰지 않음.
/// 연두색 바탕 위의 글씨는 흰색.
class AppColors {
  static const Color signature = Color(0xFF9CCC65);
  static const Color signatureDark = Color(0xFF86B851);
  static Color of(BuildContext context) => Theme.of(context).brightness == Brightness.dark ? signatureDark : signature;
}

/// 아이콘이 바뀌는 움직임의 기본값 ([전체] 그룹 아이콘과 같은 빠르기·느낌)
const Duration kIconMotion = Duration(milliseconds: 240);
const Curve kIconCurve = Curves.easeOutCubic;

/// 아이콘이 다른 아이콘으로 바뀔 때: 살짝 돌며 커지고 흐려지며 바뀜 (기본 움직임)
class MorphIcon extends StatelessWidget {
  const MorphIcon({super.key, required this.child});
  final Widget child; // 바뀌면 key를 다르게

  @override
  Widget build(BuildContext context) {
    return AnimatedSwitcher(
      duration: kIconMotion,
      switchInCurve: kIconCurve,
      switchOutCurve: kIconCurve,
      transitionBuilder: (child, anim) => FadeTransition(
        opacity: anim,
        child: RotationTransition(
          turns: Tween<double>(begin: -0.125, end: 0).animate(anim),
          child: ScaleTransition(scale: Tween<double>(begin: 0.7, end: 1).animate(anim), child: child),
        ),
      ),
      child: child,
    );
  }
}
