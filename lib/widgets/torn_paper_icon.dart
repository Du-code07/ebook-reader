import 'package:flutter/material.dart';

/// 종이색 아이콘: 아랫부분이 살짝 찢어진 종이 한 장
class TornPaperIcon extends StatelessWidget {
  const TornPaperIcon({super.key, this.size = 18, this.color});
  final double size;
  final Color? color;

  @override
  Widget build(BuildContext context) {
    final c = color ?? IconTheme.of(context).color ?? Theme.of(context).colorScheme.onSurface;
    return SizedBox.square(dimension: size, child: CustomPaint(painter: _TornPaperPainter(c)));
  }
}

class _TornPaperPainter extends CustomPainter {
  _TornPaperPainter(this.color);
  final Color color;

  @override
  void paint(Canvas canvas, Size size) {
    final s = size.shortestSide;
    final double l = s * 0.2, r = s * 0.8, t = s * 0.1, b = s * 0.86;
    final stroke = Paint()
      ..color = color
      ..style = PaintingStyle.stroke
      ..strokeWidth = s * 0.085
      ..strokeJoin = StrokeJoin.round
      ..strokeCap = StrokeCap.round;
    // 위·양옆은 반듯하게, 아래는 들쭉날쭉 찢어진 모양
    final p = Path()
      ..moveTo(l, b - s * 0.04)
      ..lineTo(l, t)
      ..lineTo(r, t)
      ..lineTo(r, b - s * 0.08);
    const teeth = [0.0, 0.07, -0.03, 0.06, -0.05, 0.05, 0.0];
    for (int i = 1; i < teeth.length; i++) {
      final double x = r - (r - l) * i / (teeth.length - 1);
      p.lineTo(x, b + s * teeth[i] - s * 0.03);
    }
    canvas.drawPath(p, stroke);
    // 글줄 두 개
    final line = Paint()
      ..color = color.withValues(alpha: 0.75)
      ..strokeWidth = s * 0.07
      ..strokeCap = StrokeCap.round;
    canvas.drawLine(Offset(l + s * 0.13, t + s * 0.22), Offset(r - s * 0.13, t + s * 0.22), line);
    canvas.drawLine(Offset(l + s * 0.13, t + s * 0.4), Offset(r - s * 0.2, t + s * 0.4), line);
  }

  @override
  bool shouldRepaint(_TornPaperPainter old) => old.color != color;
}
