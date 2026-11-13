import 'package:flutter/material.dart';

/// 앱 대표 색 RGB(163, 204, 163): 고른 것·켜짐·버튼 바탕과 체크 표시에만 쓰고, 글씨·아이콘에는 쓰지 않음.
/// 대표 색 바탕 위의 글씨·아이콘은 흰색. 다크 모드에서는 대표 색 대신 회색('글꼴 찾기' 단추 바탕과 같은 색)
class AppColors {
  static const Color signature = Color(0xFFA3CCA3);
  static const Color signatureDark = Color(0xFF343438);

  /// 대표 색 바탕 위 글씨·아이콘 색
  static const Color onSignature = Colors.white;

  /// 대표 색 바탕 위 흰 글씨가 잘 보이게 까는 옅은 그림자 (밝은 테마만, 다크는 회색 바탕이라 필요 없음)
  static List<Shadow>? sigShadows(BuildContext context) =>
      Theme.of(context).brightness == Brightness.dark ? null : const [Shadow(color: Color(0x66000000), blurRadius: 3, offset: Offset(0, 0.6))];

  /// 지금 테마의 대표 색 바탕 위 글씨·아이콘 색
  static Color onSig(BuildContext context) => Theme.of(context).colorScheme.onSecondaryContainer;
  static Color of(BuildContext context) =>
      Theme.of(context).extension<SigColors>()?.sig ?? (Theme.of(context).brightness == Brightness.dark ? signatureDark : signature);

  /// 체크 표시·고른 동그라미처럼 '아이콘'으로 보이는 표시: 밝은 테마는 대표 색, 다크는 밝은 회색 (회색 바탕 위에서도 보이게)
  static Color mark(BuildContext context) =>
      Theme.of(context).extension<SigColors>()?.mark ?? (Theme.of(context).brightness == Brightness.dark ? const Color(0xFFE6E6E9) : signature);
}

/// 테마마다 다른 대표 색 (서재 테마는 초록 스탠드 색 등)
class SigColors extends ThemeExtension<SigColors> {
  const SigColors({required this.sig, required this.mark});

  /// 고른 것·켜짐·버튼 바탕
  final Color sig;

  /// 체크 표시처럼 아이콘으로 보이는 표시
  final Color mark;

  @override
  SigColors copyWith({Color? sig, Color? mark}) => SigColors(sig: sig ?? this.sig, mark: mark ?? this.mark);

  @override
  SigColors lerp(ThemeExtension<SigColors>? other, double t) {
    if (other is! SigColors) return this;
    return SigColors(sig: Color.lerp(sig, other.sig, t)!, mark: Color.lerp(mark, other.mark, t)!);
  }
}

/// 아이콘이 바뀌는 움직임의 기본값 ([전체] 그룹 아이콘과 같은 빠르기·느낌)
/// 파일 뒤 바탕: 앱 테마가 밝으면 흰색(편안한 모드는 미색), 어두우면 검은색
Color viewerBackdrop(BuildContext context) =>
    Theme.of(context).brightness == Brightness.dark ? Colors.black : Theme.of(context).colorScheme.surface;

/// 쪽 사이 간격 줄 (스크롤 보기·두 쪽 보기): 테마와 상관없이 밝은 회색
const Color kViewerGapColor = Color(0xFFE2E2E6);

/// 뷰어 배경 설정(라이트/다크)이 있는 파일(한글·워드·TXT)의 쪽 뒤 바탕
Color viewerThemeBackdrop(String theme) => theme == 'dark' ? Colors.black : Colors.white;

Duration get kIconMotion => Anim.ms(240);
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

/// 앱 설정 '애니메이션 멈추기': 켜면 앱의 움직임(버튼 튀어나옴·아이콘 움직임·창 열고 닫기·페이지 넘김 효과)을 모두 바로 바뀌게
class Anim {
  static final ValueNotifier<bool> off = ValueNotifier<bool>(false);

  /// 움직임 시간. 멈추기를 켜면 1ms (0이면 일부 스크롤 움직임이 오류를 내므로)
  static Duration ms(int v) => Duration(milliseconds: off.value ? 1 : v);
}
