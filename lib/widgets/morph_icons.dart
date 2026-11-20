import 'dart:math' as math;

import 'package:flutter/material.dart';

import 'app_colors.dart';

// [전체](그룹) 아이콘과 같은 움직임: 그림 조각이 미끄러지듯 제자리를 바꿈 (같은 빠르기·곡선)
// - 메뉴가 열리면(open) 모양이 바뀌었다가, 닫히면 되돌아옴
// - 처음 나타날 때도 조각이 제자리로 미끄러져 들어옴

/// 파일 추가 단추의 + : 열리면 두 막대가 돌아 × 로
class PlusCloseIcon extends StatelessWidget {
  const PlusCloseIcon({super.key, required this.open, this.size = 24, this.color, this.shadows});
  final bool open;
  final double size;
  final Color? color;
  final List<Shadow>? shadows;

  @override
  Widget build(BuildContext context) {
    final Color c = color ?? IconTheme.of(context).color ?? Theme.of(context).colorScheme.onSurface;
    return TweenAnimationBuilder<double>(
      tween: Tween<double>(end: open ? 1.0 : 0.0),
      duration: kIconMotion,
      curve: kIconCurve,
      builder: (context, t, _) => SizedBox.square(dimension: size, child: CustomPaint(painter: _PlusPainter(c, t, shadows))),
    );
  }
}

class _PlusPainter extends CustomPainter {
  _PlusPainter(this.color, this.t, this.shadows);
  final Color color;
  final double t;
  final List<Shadow>? shadows;

  @override
  void paint(Canvas canvas, Size size) {
    final double s = size.shortestSide;
    final double barH = s * 0.13, barW = s * 0.66 - s * 0.06 * t;
    final Offset c = Offset(size.width / 2, size.height / 2);
    void bars(Paint p, Offset off) {
      for (final double base in [0.0, math.pi / 2]) {
        canvas.save();
        canvas.translate(c.dx + off.dx, c.dy + off.dy);
        canvas.rotate(base + t * math.pi / 4);
        canvas.drawRRect(RRect.fromRectAndRadius(Rect.fromCenter(center: Offset.zero, width: barW, height: barH), Radius.circular(barH / 2)), p);
        canvas.restore();
      }
    }

    // 글자 그림자처럼 은은한 그림자 (시그니처 바탕 위 흰 아이콘)
    for (final sh in shadows ?? const <Shadow>[]) {
      bars(Paint()
        ..color = sh.color
        ..maskFilter = sh.blurRadius > 0 ? MaskFilter.blur(BlurStyle.normal, sh.blurSigma) : null, sh.offset);
    }
    bars(Paint()..color = color, Offset.zero);
  }

  @override
  bool shouldRepaint(_PlusPainter old) => old.color != color || old.t != t || old.shadows != shadows;
}

/// 다크 모드 달: 라이트일 때 테두리 달, 다크일 때 꽉 찬 노란 달.
/// 바뀔 때와 메뉴가 열릴 때 달의 그림자(가린 원)가 미끄러지며 모양이 바뀜
class MoonMorphIcon extends StatelessWidget {
  const MoonMorphIcon({super.key, required this.filled, this.open = false, this.size = 18, this.color, this.fillColor = Colors.amber});
  final bool filled, open;
  final double size;
  final Color? color;
  final Color fillColor;

  @override
  Widget build(BuildContext context) {
    final Color c = color ?? IconTheme.of(context).color ?? Theme.of(context).colorScheme.onSurface;
    return TweenAnimationBuilder<double>(
      // 처음 나타날 때: 둥근 달에서 그림자가 미끄러져 들어와 초승달로
      tween: Tween<double>(begin: 0, end: 1),
      duration: kIconMotion,
      curve: kIconCurve,
      builder: (context, appear, _) => TweenAnimationBuilder<double>(
        tween: Tween<double>(end: filled ? 1.0 : 0.0),
        duration: kIconMotion,
        curve: kIconCurve,
        builder: (context, f, _) => TweenAnimationBuilder<double>(
          tween: Tween<double>(end: open ? 1.0 : 0.0),
          duration: kIconMotion,
          curve: kIconCurve,
          builder: (context, o, _) => SizedBox.square(
            dimension: size,
            child: CustomPaint(painter: _MoonPainter(Color.lerp(c, fillColor, f)!, f, o, appear)),
          ),
        ),
      ),
    );
  }
}

class _MoonPainter extends CustomPainter {
  _MoonPainter(this.color, this.fill, this.open, this.appear);
  final Color color;
  final double fill, open, appear;

  @override
  void paint(Canvas canvas, Size size) {
    final double s = size.shortestSide;
    final Offset c = Offset(size.width / 2, size.height / 2);
    final double r = s * 0.38;
    // 그림자 원이 오른쪽 위에서 미끄러져 들어옴 (열리면 조금 빠져 달이 차오름)
    final double d = r * (0.72 + 0.28 * open + 1.3 * (1 - appear));
    final Offset bite = c + Offset(d * 0.86, -d * 0.5);
    final Path disc = Path()..addOval(Rect.fromCircle(center: c, radius: r));
    final Path cut = Path()..addOval(Rect.fromCircle(center: bite, radius: r * 0.82));
    final Path moon = Path.combine(PathOperation.difference, disc, cut);
    if (fill > 0) canvas.drawPath(moon, Paint()..color = color.withValues(alpha: color.a * fill));
    canvas.drawPath(
      moon,
      Paint()
        ..color = color
        ..style = PaintingStyle.stroke
        ..strokeWidth = s * 0.085
        ..strokeJoin = StrokeJoin.round,
    );
  }

  @override
  bool shouldRepaint(_MoonPainter old) => old.color != color || old.fill != fill || old.open != open || old.appear != appear;
}

/// 세피아(양피지) 아이콘: 위아래가 말린 양피지 두루마리.
/// 나타날 때·메뉴가 열릴 때 두루마리가 펼쳐지듯 아래 말이가 미끄러져 내려감
class ParchmentIcon extends StatelessWidget {
  const ParchmentIcon({super.key, this.open = false, this.size = 18, this.color});
  final bool open;
  final double size;

  /// 선 색 (없으면 주변 아이콘 색). 색을 따로 칠하지 않고 선으로만 그린 옛날 종이
  final Color? color;

  @override
  Widget build(BuildContext context) {
    final Color c = color ?? IconTheme.of(context).color ?? Theme.of(context).colorScheme.onSurfaceVariant;
    return TweenAnimationBuilder<double>(
      tween: Tween<double>(begin: 0, end: 1),
      duration: kIconMotion,
      curve: kIconCurve,
      builder: (context, appear, _) => TweenAnimationBuilder<double>(
        tween: Tween<double>(end: open ? 1.0 : 0.0),
        duration: kIconMotion,
        curve: kIconCurve,
        builder: (context, o, _) => SizedBox.square(dimension: size, child: CustomPaint(painter: _ParchmentPainter(appear, o, c))),
      ),
    );
  }
}

/// 옛날 종이: 아래가 찢긴 듯 물결진 낱장 + 접힌 귀퉁이 + 글 줄 (선으로만)
class _ParchmentPainter extends CustomPainter {
  _ParchmentPainter(this.appear, this.open, this.color);
  final double appear, open;
  final Color color;

  @override
  void paint(Canvas canvas, Size size) {
    final double s = size.shortestSide;
    final double ox = (size.width - s) / 2, oy = (size.height - s) / 2;
    final double sw = math.max(1.2, s * 0.085);
    final Paint stroke = Paint()
      ..color = color
      ..style = PaintingStyle.stroke
      ..strokeWidth = sw
      ..strokeJoin = StrokeJoin.round
      ..strokeCap = StrokeCap.round;
    final double l = ox + s * 0.18, r = ox + s * 0.82, t = oy + s * 0.1, b = oy + s * 0.88;
    // 접힌 귀퉁이 크기: 메뉴를 열면 조금 더 접힘
    final double fold = s * (0.2 + 0.08 * open) * appear;
    final double w = r - l;
    final Path page = Path()
      ..moveTo(l, t)
      ..lineTo(r - fold, t)
      ..lineTo(r, t + fold)
      // 오른쪽: 살짝 휜 낡은 가장자리
      ..quadraticBezierTo(r - s * 0.03, t + (b - t) * 0.55, r, b - s * 0.06)
      // 아래: 찢긴 듯 물결
      ..quadraticBezierTo(l + w * 0.85, b + s * 0.03, l + w * 0.7, b - s * 0.02)
      ..quadraticBezierTo(l + w * 0.5, b - s * 0.07, l + w * 0.32, b)
      ..quadraticBezierTo(l + w * 0.14, b + s * 0.04, l, b - s * 0.03)
      // 왼쪽: 살짝 휜 가장자리
      ..quadraticBezierTo(l + s * 0.03, t + (b - t) * 0.45, l, t)
      ..close();
    canvas.drawPath(page, stroke);
    if (fold > 0.5) {
      // 접힌 귀퉁이 안쪽 선
      canvas.drawPath(
          Path()
            ..moveTo(r - fold, t)
            ..lineTo(r - fold, t + fold)
            ..lineTo(r, t + fold),
          stroke);
    }
    // 글 줄
    final Paint lp = Paint()
      ..color = color.withValues(alpha: 0.9 * appear)
      ..strokeWidth = sw * 0.8
      ..strokeCap = StrokeCap.round;
    final double lx = l + w * 0.2;
    canvas.drawLine(Offset(lx, t + (b - t) * 0.42), Offset(r - w * 0.2, t + (b - t) * 0.42), lp);
    canvas.drawLine(Offset(lx, t + (b - t) * 0.62), Offset(r - w * 0.34, t + (b - t) * 0.62), lp);
  }

  @override
  bool shouldRepaint(_ParchmentPainter old) => old.appear != appear || old.open != open || old.color != color;
}

/// 메뉴 아이콘: 휴지통 모양은 앱 어디서나 서재 위 휴지통과 같은 모양으로
Widget menuIcon(IconData icon, {double? size, Color? color, List<Shadow>? shadows}) {
  if (icon == Icons.delete_outline || icon == Icons.delete || icon == Icons.delete_forever) return TrashLidIcon(open: false, size: size, color: color);
  return Icon(icon, size: size, color: color, shadows: shadows);
}

/// 휴지통 아이콘: [open]이면 뚜껑이 왼쪽 끝을 축으로 들리고, 닫히면 다시 덮임
class TrashLidIcon extends StatelessWidget {
  const TrashLidIcon({super.key, required this.open, this.size, this.color});

  final bool open;
  final double? size;
  final Color? color;

  @override
  Widget build(BuildContext context) {
    final Color c = color ?? IconTheme.of(context).color ?? Theme.of(context).colorScheme.onSurfaceVariant;
    return TweenAnimationBuilder<double>(
      tween: Tween<double>(end: open ? 1 : 0),
      duration: Anim.ms(320),
      curve: open ? Curves.easeOutBack : Curves.easeInCubic,
      builder: (context, t, _) => SizedBox.square(dimension: size ?? IconTheme.of(context).size ?? 24, child: CustomPaint(painter: _TrashPainter(c, t))),
    );
  }
}

class _TrashPainter extends CustomPainter {
  _TrashPainter(this.color, this.t);

  final Color color;
  final double t;

  @override
  void paint(Canvas canvas, Size size) {
    canvas.save();
    canvas.scale(size.width / 24);
    final p = Paint()
      ..color = color
      ..style = PaintingStyle.stroke
      ..strokeWidth = 2
      ..strokeJoin = StrokeJoin.round
      ..strokeCap = StrokeCap.round;
    // 통
    final body = Path()
      ..moveTo(6.2, 8.5)
      ..lineTo(7.1, 19.2)
      ..quadraticBezierTo(7.25, 20.5, 8.6, 20.5)
      ..lineTo(15.4, 20.5)
      ..quadraticBezierTo(16.75, 20.5, 16.9, 19.2)
      ..lineTo(17.8, 8.5);
    canvas.drawPath(body, p);
    canvas.drawLine(const Offset(10.2, 11.5), const Offset(10.5, 17.3), p);
    canvas.drawLine(const Offset(13.8, 11.5), const Offset(13.5, 17.3), p);
    // 뚜껑: 왼쪽 끝을 축으로 들림
    canvas.save();
    const Offset hinge = Offset(4.5, 6.5);
    canvas.translate(hinge.dx, hinge.dy);
    canvas.rotate(-0.42 * t);
    canvas.translate(-hinge.dx, -hinge.dy + -0.6 * t);
    canvas.drawLine(const Offset(4.5, 6.5), const Offset(19.5, 6.5), p);
    final handle = Path()
      ..moveTo(9.5, 6.5)
      ..lineTo(9.5, 4.6)
      ..quadraticBezierTo(9.5, 3.5, 10.6, 3.5)
      ..lineTo(13.4, 3.5)
      ..quadraticBezierTo(14.5, 3.5, 14.5, 4.6)
      ..lineTo(14.5, 6.5);
    canvas.drawPath(handle, p);
    canvas.restore();
    canvas.restore();
  }

  @override
  bool shouldRepaint(covariant _TrashPainter old) => old.t != t || old.color != color;
}

/// 정렬 아이콘: [flipped]가 바뀔 때마다 막대(긴 것·중간·짧은 것)가 위아래로 자리를 바꿈
class SortBarsIcon extends StatelessWidget {
  const SortBarsIcon({super.key, required this.flipped, this.size, this.color});

  final bool flipped;
  final double? size;
  final Color? color;

  @override
  Widget build(BuildContext context) {
    final Color c = color ?? IconTheme.of(context).color ?? Theme.of(context).colorScheme.onSurfaceVariant;
    return TweenAnimationBuilder<double>(
      tween: Tween<double>(end: flipped ? 1 : 0),
      duration: Anim.ms(380),
      curve: Curves.easeInOutCubic,
      builder: (context, t, _) => SizedBox.square(dimension: size ?? IconTheme.of(context).size ?? 24, child: CustomPaint(painter: _SortBarsPainter(c, t))),
    );
  }
}

class _SortBarsPainter extends CustomPainter {
  _SortBarsPainter(this.color, this.t);

  final Color color;
  final double t;

  @override
  void paint(Canvas canvas, Size size) {
    canvas.save();
    canvas.scale(size.width / 24);
    final p = Paint()
      ..color = color
      ..strokeWidth = 2
      ..strokeCap = StrokeCap.round;
    const ys = [7.0, 12.0, 17.0];
    const lens = [16.0, 10.0, 4.0]; // 긴 막대부터
    for (int i = 0; i < 3; i++) {
      // 막대마다 조금씩 늦게 출발해 차례로 미끄러짐
      final double local = ((t - i * 0.12) / 0.76).clamp(0.0, 1.0);
      final double y = ys[i] + (ys[2 - i] - ys[i]) * Curves.easeInOutCubic.transform(local);
      canvas.drawLine(Offset(4, y), Offset(4 + lens[i], y), p);
    }
    canvas.restore();
  }

  @override
  bool shouldRepaint(covariant _SortBarsPainter old) => old.t != t || old.color != color;
}

/// 설정 아이콘: [turns]가 바뀌면 톱니바퀴가 그만큼 돌아감
class SpinGearIcon extends StatelessWidget {
  const SpinGearIcon({super.key, required this.turns, this.size, this.color});

  final double turns;
  final double? size;
  final Color? color;

  @override
  Widget build(BuildContext context) {
    return AnimatedRotation(
      turns: turns,
      duration: Anim.ms(600),
      curve: Curves.easeOutBack,
      child: Icon(Icons.settings_outlined, size: size, color: color),
    );
  }
}
