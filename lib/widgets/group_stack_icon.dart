import 'package:flutter/material.dart';

/// [전체] 그룹 아이콘: 작대기 3개가 살짝 간격을 두고 비스듬히 겹쳐 쌓인 모양
class GroupStackIcon extends StatelessWidget {
  const GroupStackIcon({super.key, this.size = 18, this.color});

  final double size;
  final Color? color;

  @override
  Widget build(BuildContext context) {
    final Color c = color ?? IconTheme.of(context).color ?? Theme.of(context).colorScheme.onSurface;
    return SizedBox.square(dimension: size, child: CustomPaint(painter: _GroupStackPainter(c)));
  }
}

class _GroupStackPainter extends CustomPainter {
  _GroupStackPainter(this.color);

  final Color color;

  @override
  void paint(Canvas canvas, Size size) {
    final double s = size.shortestSide;
    final double barH = s * 0.17;
    final double barW = s * 0.66;
    final Paint fill = Paint()..color = color;
    // 위에서부터 한 칸씩 오른쪽으로 비켜 쌓인 3개의 막대 (막대 사이는 살짝 띄움)
    for (int i = 0; i < 3; i++) {
      final double x = s * (0.06 + i * 0.12);
      final double y = s * (0.17 + i * 0.25);
      canvas.drawRRect(
        RRect.fromRectAndRadius(Rect.fromLTWH(x, y, barW, barH), Radius.circular(barH / 2)),
        fill,
      );
    }
  }

  @override
  bool shouldRepaint(_GroupStackPainter old) => old.color != color;
}
