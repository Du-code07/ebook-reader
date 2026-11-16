import 'package:flutter/material.dart';

/// 북마크한 쪽의 왼쪽 위에 걸리는 책갈피 끈 (쪽 맨 위에서 아래로 늘어진 모양)
class BookmarkRibbon extends StatelessWidget {
  const BookmarkRibbon({super.key, this.width = 16, this.height = 28});

  final double width, height;

  @override
  Widget build(BuildContext context) => CustomPaint(size: Size(width, height), painter: _RibbonPainter());
}

class _RibbonPainter extends CustomPainter {
  @override
  void paint(Canvas canvas, Size size) {
    final double w = size.width, h = size.height;
    final path = Path()
      ..moveTo(0, 0)
      ..lineTo(w, 0)
      ..lineTo(w, h)
      ..lineTo(w / 2, h - w * 0.45)
      ..lineTo(0, h)
      ..close();
    canvas.drawShadow(path, Colors.black, 1.5, false);
    canvas.drawPath(path, Paint()..color = const Color(0xFFF2B01E));
    // 끈 가운데 옅은 줄 (천 느낌)
    canvas.drawLine(Offset(w / 2, 0), Offset(w / 2, h - w * 0.55), Paint()
      ..color = const Color(0x33FFFFFF)
      ..strokeWidth = 1.2);
  }

  @override
  bool shouldRepaint(covariant CustomPainter oldDelegate) => false;
}
