import 'dart:math' as math;

import 'package:flutter/material.dart';

/// 태블릿(짧은 변 600 이상)에서만 앱 화면 전체를 조금 크게 보여 준다:
/// 보통 글자(14pt)가 2pt 커지는 만큼(16/14배). 휴대폰은 그대로.
/// 책 본문(문서·사진 화면)은 [UiUnscale]로 감싸 원래 선명도·크기 그대로 둔다.
class UiScale extends InheritedWidget {
  const UiScale({super.key, required this.scale, required super.child});
  final double scale;

  static double of(BuildContext context) => context.dependOnInheritedWidgetOfExactType<UiScale>()?.scale ?? 1.0;

  /// 태블릿으로 보는 짧은 변 (dp)
  static const double tabletShortestSide = 600;

  static double scaleFor(Size size) => size.shortestSide >= tabletShortestSide ? 16 / 14 : 1.0;

  @override
  bool updateShouldNotify(UiScale old) => old.scale != scale;
}

MediaQueryData _scaledMq(MediaQueryData mq, double f) => mq.copyWith(
      size: mq.size * f,
      padding: mq.padding * f,
      viewPadding: mq.viewPadding * f,
      viewInsets: mq.viewInsets * f,
      systemGestureInsets: mq.systemGestureInsets * f,
    );

Widget _scaleBox(BuildContext context, double f, Widget child, MediaQueryData data) {
  return LayoutBuilder(
    builder: (context, c) {
      final double w = c.maxWidth, h = c.maxHeight;
      if (!w.isFinite || !h.isFinite) return child;
      return Transform.scale(
        scale: f,
        alignment: Alignment.topLeft,
        child: OverflowBox(
          alignment: Alignment.topLeft,
          minWidth: w / f,
          maxWidth: w / f,
          minHeight: h / f,
          maxHeight: h / f,
          child: MediaQuery(data: data, child: child),
        ),
      );
    },
  );
}

/// 앱 전체를 크게 보이게 (MaterialApp.builder에서 감쌈)
class UiScaleBox extends StatelessWidget {
  const UiScaleBox({super.key, required this.child});
  final Widget child;

  @override
  Widget build(BuildContext context) {
    final mq = MediaQuery.of(context);
    final double s = UiScale.scaleFor(mq.size);
    if ((s - 1).abs() < 0.02) return UiScale(scale: 1, child: child);
    return UiScale(scale: s, child: _scaleBox(context, s, child, _scaledMq(mq, 1 / s)));
  }
}

/// 크게 보이게 한 화면 안에서 이 부분만 원래 크기로 (책 본문)
class UiUnscale extends StatelessWidget {
  const UiUnscale({super.key, required this.child});
  final Widget child;

  @override
  Widget build(BuildContext context) {
    final double s = UiScale.of(context);
    if ((s - 1).abs() < 0.02) return child;
    final mq = MediaQuery.of(context);
    return UiScale(scale: 1, child: _scaleBox(context, 1 / s, child, _scaledMq(mq, s)));
  }
}

/// 화면 전체 좌표(실제 크기)를 크게 보이게 한 화면의 좌표로
Offset uiScaledPosition(BuildContext context, Offset global) {
  final s = UiScale.of(context);
  return s == 1 ? global : global / math.max(0.01, s);
}
