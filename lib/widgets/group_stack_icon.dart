import 'package:flutter/material.dart';
import 'app_colors.dart';

/// [전체] 그룹 아이콘: 평소에는 작대기 3개가 나란히 있다가,
/// 그룹 목록을 펼치면([spread]) 한 칸씩 비켜 엇갈리게 바뀐다.
class GroupStackIcon extends StatelessWidget {
  const GroupStackIcon({super.key, this.size = 18, this.color, this.spread = false});

  final double size;
  final Color? color;
  final bool spread;

  @override
  Widget build(BuildContext context) {
    final Color c = color ?? IconTheme.of(context).color ?? Theme.of(context).colorScheme.onSurface;
    return TweenAnimationBuilder<double>(
      tween: Tween<double>(end: spread ? 1.0 : 0.0),
      duration: kIconMotion,
      curve: kIconCurve,
      builder: (context, t, _) => SizedBox.square(dimension: size, child: CustomPaint(painter: _GroupStackPainter(c, t))),
    );
  }
}

class _GroupStackPainter extends CustomPainter {
  _GroupStackPainter(this.color, this.spread);

  final Color color;
  final double spread; // 0: 나란히, 1: 엇갈림

  @override
  void paint(Canvas canvas, Size size) {
    final double s = size.shortestSide;
    final double barH = s * 0.17;
    final double barW = s * 0.66;
    final Paint fill = Paint()..color = color;
    for (int i = 0; i < 3; i++) {
      final double aligned = (1 - 0.66) / 2; // 가운데 맞춤
      final double staggered = 0.06 + i * 0.12; // 위에서부터 한 칸씩 오른쪽으로
      final double x = s * (aligned + (staggered - aligned) * spread);
      final double y = s * (0.17 + i * 0.25);
      canvas.drawRRect(RRect.fromRectAndRadius(Rect.fromLTWH(x, y, barW, barH), Radius.circular(barH / 2)), fill);
    }
  }

  @override
  bool shouldRepaint(_GroupStackPainter old) => old.color != color || old.spread != spread;
}

/// 그룹 목록의 [전체] 아이콘: 서류가 들어 있는 폴더
/// - 기본: 테마 색으로 칠한 폴더(밝은 테마는 시그니쳐 색 계열, 다크는 회색 계열) + 흰 서류
/// - [onAccent]: 시그니쳐 색 바탕 위(고른 칸)에서는 진한 초록 선으로 (다크는 흰 선)
class FolderDocsIcon extends StatelessWidget {
  const FolderDocsIcon({super.key, this.size = 20, this.onAccent = false, this.color});

  final double size;
  final bool onAccent;

  /// 선 색을 직접 정할 때 (선으로 그림)
  final Color? color;

  @override
  Widget build(BuildContext context) {
    final bool dark = Theme.of(context).brightness == Brightness.dark;
    final _FolderDocsPainter painter;
    if (onAccent || color != null) {
      painter = _FolderDocsPainter.line(color ?? (dark ? Colors.white : const Color(0xFF2E5A2E)));
    } else if (dark) {
      painter = const _FolderDocsPainter.filled(back: Color(0xFF55585E), front: Color(0xFF8B8F96), paper: Color(0xFFEDEDEF), lines: Color(0xFF8B8F96));
    } else {
      painter = const _FolderDocsPainter.filled(back: Color(0xFF6F9E6F), front: Color(0xFFA3CCA3), paper: Colors.white, lines: Color(0xFF8DB98D));
    }
    return SizedBox.square(dimension: size, child: CustomPaint(painter: painter));
  }
}

class _FolderDocsPainter extends CustomPainter {
  const _FolderDocsPainter.line(Color c)
      : filled = false,
        back = c,
        front = c,
        paper = c,
        lines = c;
  const _FolderDocsPainter.filled({required this.back, required this.front, required this.paper, required this.lines}) : filled = true;

  final bool filled;
  final Color back, front, paper, lines;

  static Path _backPath() => Path()
    ..moveTo(2.5, 12)
    ..lineTo(2.5, 5.2)
    ..quadraticBezierTo(2.5, 4, 3.7, 4)
    ..lineTo(8.6, 4)
    ..lineTo(10.4, 6)
    ..lineTo(20.3, 6)
    ..quadraticBezierTo(21.5, 6, 21.5, 7.2)
    ..lineTo(21.5, 12);

  @override
  void paint(Canvas canvas, Size size) {
    final double u = size.width / 24;
    canvas.save();
    canvas.scale(u);
    final paperRect = RRect.fromLTRBR(6, 2.6, 18, 14, const Radius.circular(1.2));
    final frontRect = RRect.fromLTRBR(2.5, 10.8, 21.5, 20.5, const Radius.circular(1.6));
    if (filled) {
      // 칠한 폴더: 뒤 폴더 → 서류 → 앞 판
      final backFill = Path.from(_backPath())
        ..lineTo(21.5, 20)
        ..lineTo(2.5, 20)
        ..close();
      canvas.drawPath(backFill, Paint()..color = back);
      // 서류는 살짝 오른쪽으로 꽂아 왼쪽 위 폴더 손잡이가 보이게, 두 장 겹침
      canvas.drawRRect(RRect.fromLTRBR(11, 1.6, 20, 12, const Radius.circular(1.2)), Paint()..color = Color.lerp(paper, lines, 0.35)!);
      final sheet = RRect.fromLTRBR(7.6, 3, 18.4, 14, const Radius.circular(1.2));
      canvas.drawRRect(sheet, Paint()..color = paper);
      final line = Paint()
        ..color = lines
        ..strokeWidth = 1.5
        ..strokeCap = StrokeCap.round;
      canvas.drawLine(const Offset(10, 6.2), const Offset(16, 6.2), line);
      canvas.drawLine(const Offset(10, 8.8), const Offset(14.4, 8.8), line);
      canvas.drawRRect(frontRect, Paint()..color = front);
      canvas.restore();
      return;
    }
    final stroke = Paint()
      ..color = front
      ..style = PaintingStyle.stroke
      ..strokeWidth = 1.8
      ..strokeJoin = StrokeJoin.round
      ..strokeCap = StrokeCap.round;
    final clear = Paint()..blendMode = BlendMode.clear;
    canvas.saveLayer(const Rect.fromLTWH(-2, -2, 28, 28), Paint());
    // 뒤쪽 폴더 (손잡이 달린 윗부분)
    canvas.drawPath(_backPath(), stroke);
    // 폴더에 꽂힌 서류
    canvas.drawRRect(paperRect.inflate(1.4), clear);
    canvas.drawRRect(paperRect, stroke);
    canvas.drawLine(const Offset(8.8, 6), const Offset(15.2, 6), stroke);
    canvas.drawLine(const Offset(8.8, 8.8), const Offset(13.4, 8.8), stroke);
    // 앞쪽 폴더 판
    canvas.drawRRect(frontRect.inflate(1.2), clear);
    canvas.drawRRect(frontRect, stroke);
    canvas.restore();
    canvas.restore();
  }

  @override
  bool shouldRepaint(covariant _FolderDocsPainter old) =>
      old.filled != filled || old.back != back || old.front != front || old.paper != paper || old.lines != lines;
}
