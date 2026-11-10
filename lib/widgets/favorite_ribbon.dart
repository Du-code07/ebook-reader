import 'package:flutter/material.dart';

/// 파일 왼쪽 위 끝에 걸쳐 있는 작은 책갈피 모양 즐겨찾기 표시.
/// 꺼져 있으면 빈 책갈피가 살짝 위로 올라가 있고, 켜지면 살짝 내려오면서 노랗게 바뀐다.
/// 부모가 위쪽을 잘라(clip) 주면 책갈피가 위 테두리에 꽂혀 있는 것처럼 보인다.
class FavoriteRibbon extends StatelessWidget {
  const FavoriteRibbon({
    super.key,
    required this.active,
    this.onTap,
    this.width = 12,
    this.height = 19,
    this.onImage = false,
    this.isDark = false,
  });

  final bool active;
  final VoidCallback? onTap;
  final double width;
  final double height;

  /// 표지(그림) 위에 놓일 때: 어떤 그림 위에서도 보이도록 흰 테두리 + 옅은 그림자
  final bool onImage;
  final bool isDark;

  /// 꺼져 있을 때 위로 올라가 있는 정도
  double get _lift => height * 0.32;

  @override
  Widget build(BuildContext context) {
    final Color outline = onImage ? Colors.white : (isDark ? Colors.white60 : Colors.black45);
    final Color emptyFill = onImage ? Colors.black26 : Colors.transparent;
    return GestureDetector(
      behavior: HitTestBehavior.opaque,
      onTap: onTap,
      child: SizedBox(
        width: width + 14,
        height: height + 8,
        child: Align(
          alignment: Alignment.topCenter,
          child: TweenAnimationBuilder<double>(
            tween: Tween<double>(end: active ? 1.0 : 0.0),
            duration: const Duration(milliseconds: 280),
            curve: Curves.easeOutBack,
            builder: (context, t, _) {
              final double c = t.clamp(0.0, 1.0).toDouble();
              return Transform.translate(
                offset: Offset(0, -_lift * (1 - t)),
                child: CustomPaint(
                  size: Size(width, height),
                  painter: _RibbonPainter(
                    fill: Color.lerp(emptyFill, Colors.amber, c)!,
                    stroke: Color.lerp(outline, const Color(0xFFE0A000), c)!,
                    shadow: onImage,
                  ),
                ),
              );
            },
          ),
        ),
      ),
    );
  }
}

class _RibbonPainter extends CustomPainter {
  _RibbonPainter({required this.fill, required this.stroke, required this.shadow});

  final Color fill;
  final Color stroke;
  final bool shadow;

  @override
  void paint(Canvas canvas, Size size) {
    final double w = size.width, h = size.height;
    final double sw = (w * 0.13).clamp(1.2, 2.0).toDouble();
    // 위쪽은 테두리 밖으로 이어지도록 조금 더 위에서 시작
    final path = Path()
      ..moveTo(sw / 2, -sw)
      ..lineTo(w - sw / 2, -sw)
      ..lineTo(w - sw / 2, h - sw / 2)
      ..lineTo(w / 2, h - w * 0.42)
      ..lineTo(sw / 2, h - sw / 2)
      ..close();
    if (shadow) {
      canvas.drawShadow(path, Colors.black54, 1.5, false);
    }
    canvas.drawPath(path, Paint()..color = fill);
    canvas.drawPath(
      path,
      Paint()
        ..style = PaintingStyle.stroke
        ..strokeWidth = sw
        ..strokeJoin = StrokeJoin.round
        ..color = stroke,
    );
  }

  @override
  bool shouldRepaint(_RibbonPainter old) => old.fill != fill || old.stroke != stroke || old.shadow != shadow;
}
