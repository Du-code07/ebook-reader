import 'package:flutter/material.dart';

/// 앱 대표 색 (연두색): 고른 것·켜짐·버튼 바탕과 체크 표시에만 쓰고, 글씨·아이콘에는 쓰지 않음.
/// 연두색 바탕 위의 글씨는 흰색.
class AppColors {
  static const Color signature = Color(0xFF9CCC65);
  static const Color signatureDark = Color(0xFF86B851);
  static Color of(BuildContext context) => Theme.of(context).brightness == Brightness.dark ? signatureDark : signature;
}

/// 아이콘이 바뀌는 움직임의 기본값 ([전체] 그룹 아이콘과 같은 빠르기·느낌)
/// 파일 뒤 바탕: 앱 테마가 밝으면 흰색, 어두우면(밝은 다크 포함) 검은색
Color viewerBackdrop(BuildContext context) =>
    Theme.of(context).brightness == Brightness.dark ? Colors.black : Colors.white;

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
