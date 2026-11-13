import 'package:flutter/material.dart';

/// 앱 대표 색 RGB(163, 204, 163): 고른 것·켜짐·버튼 바탕과 체크 표시에만 쓰고, 글씨·아이콘에는 쓰지 않음.
/// 대표 색 바탕 위의 글씨·아이콘은 진한 초록 #2E5A2E. 다크 모드에서는 대표 색 대신 회색('글꼴 찾기' 단추 바탕과 같은 색)에 흰 글씨
class AppColors {
  static const Color signature = Color(0xFFA3CCA3);
  static const Color signatureDark = Color(0xFF343438);

  /// 대표 색 바탕 위 글씨·아이콘 색
  static const Color onSignature = Color(0xFF2E5A2E);

  /// 지금 테마의 대표 색 바탕 위 글씨·아이콘 색 (다크는 회색 바탕이라 흰색)
  static Color onSig(BuildContext context) => Theme.of(context).brightness == Brightness.dark ? Colors.white : onSignature;
  static Color of(BuildContext context) => Theme.of(context).brightness == Brightness.dark ? signatureDark : signature;

  /// 체크 표시·고른 동그라미처럼 '아이콘'으로 보이는 표시: 밝은 테마는 대표 색, 다크는 밝은 회색 (회색 바탕 위에서도 보이게)
  static Color mark(BuildContext context) => Theme.of(context).brightness == Brightness.dark ? const Color(0xFFE6E6E9) : signature;
}

/// 아이콘이 바뀌는 움직임의 기본값 ([전체] 그룹 아이콘과 같은 빠르기·느낌)
/// 파일 뒤 바탕: 앱 테마가 밝으면 흰색(편안한 모드는 미색), 어두우면 검은색
Color viewerBackdrop(BuildContext context) =>
    Theme.of(context).brightness == Brightness.dark ? Colors.black : Theme.of(context).colorScheme.surface;

/// 쪽 사이 간격 줄 (스크롤 보기·두 쪽 보기): 테마와 상관없이 밝은 회색
const Color kViewerGapColor = Color(0xFFE2E2E6);

/// 뷰어 배경 설정(라이트/다크)이 있는 파일(한글·워드·TXT)의 쪽 뒤 바탕
Color viewerThemeBackdrop(String theme) => theme == 'dark' ? Colors.black : Colors.white;

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
      // 모양이 아예 바뀔 때는 살짝 겹쳐 바뀌고, 새 아이콘은 스스로 조각이 미끄러지며 제자리로 (morph_icons.dart)
      transitionBuilder: (child, anim) => FadeTransition(opacity: anim, child: child),
      child: child,
    );
  }
}
