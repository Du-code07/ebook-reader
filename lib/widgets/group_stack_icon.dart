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
class FolderDocsIcon extends StatelessWidget {
  const FolderDocsIcon({super.key, this.size = 20, this.color});

  final double size;
  final Color? color;

  @override
  Widget build(BuildContext context) {
    final Color c = color ?? IconTheme.of(context).color ?? Theme.of(context).colorScheme.onSurface;
    return SizedBox.square(dimension: size, child: CustomPaint(painter: _FolderDocsPainter(c)));
  }
}

class _FolderDocsPainter extends CustomPainter {
  _FolderDocsPainter(this.color);

  final Color color;

  @override
  void paint(Canvas canvas, Size size) {
    final double u = size.width / 24;
    canvas.save();
    canvas.scale(u);
    final stroke = Paint()
      ..color = color
      ..style = PaintingStyle.stroke
      ..strokeWidth = 1.8
      ..strokeJoin = StrokeJoin.round
      ..strokeCap = StrokeCap.round;
    final clear = Paint()..blendMode = BlendMode.clear;
    canvas.saveLayer(const Rect.fromLTWH(-2, -2, 28, 28), Paint());
    // 뒤쪽 폴더 (손잡이 달린 윗부분)
    final back = Path()
      ..moveTo(2.5, 12)
      ..lineTo(2.5, 5.2)
      ..quadraticBezierTo(2.5, 4, 3.7, 4)
      ..lineTo(8.6, 4)
      ..lineTo(10.4, 6)
      ..lineTo(20.3, 6)
      ..quadraticBezierTo(21.5, 6, 21.5, 7.2)
      ..lineTo(21.5, 12);
    canvas.drawPath(back, stroke);
    // 폴더에 꽂힌 서류
    final paper = RRect.fromLTRBR(6, 2.6, 18, 14, const Radius.circular(1.2));
    canvas.drawRRect(paper.inflate(1.4), clear);
    canvas.drawRRect(paper, stroke);
    canvas.drawLine(const Offset(8.8, 6), const Offset(15.2, 6), stroke);
    canvas.drawLine(const Offset(8.8, 8.8), const Offset(13.4, 8.8), stroke);
    // 앞쪽 폴더 판
    final front = RRect.fromLTRBR(2.5, 10.8, 21.5, 20.5, const Radius.circular(1.6));
    canvas.drawRRect(front.inflate(1.2), clear);
    canvas.drawRRect(front, stroke);
    canvas.restore();
    canvas.restore();
  }

  @override
  bool shouldRepaint(covariant _FolderDocsPainter old) => old.color != color;
}
