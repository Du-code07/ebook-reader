import 'dart:math' as math;
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';

/// 종이처럼 말아 넘기기: 넘기기 직전 화면 그림([image])이 접힌 선을 따라 말려 넘어가고,
/// 그 아래로 이미 넘어간 새 쪽이 보인다. 말린 뒷면에는 글자가 거울처럼 흐리게 비친다.
/// [fromRight]: 오른쪽 가장자리부터 말림(다음 쪽 방향으로 민 경우), false면 왼쪽부터
class PageCurlOverlay extends StatelessWidget {
  const PageCurlOverlay({super.key, required this.image, required this.progress, required this.fromRight, this.paper});

  final ui.Image image;
  final Animation<double> progress;
  final bool fromRight;

  /// 종이 뒷면 색 (없으면 그림 가장자리 색에 가까운 흰색)
  final Color? paper;

  @override
  Widget build(BuildContext context) {
    final Color back = paper ?? (Theme.of(context).brightness == Brightness.dark ? const Color(0xFF2A2A2C) : const Color(0xFFF7F5F0));
    return IgnorePointer(
      child: AnimatedBuilder(
        animation: progress,
        builder: (context, _) => CustomPaint(
          size: Size.infinite,
          painter: PageCurlPainter(image: image, t: progress.value, fromRight: fromRight, back: back),
        ),
      ),
    );
  }
}

class PageCurlPainter extends CustomPainter {
  PageCurlPainter({required this.image, required this.t, required this.fromRight, required this.back});

  final ui.Image image;
  final double t;
  final bool fromRight;
  final Color back;

  @override
  void paint(Canvas canvas, Size size) {
    if (size.isEmpty) return;
    final Rect page = Offset.zero & size;
    final Rect src = Rect.fromLTWH(0, 0, image.width.toDouble(), image.height.toDouble());
    final paint = Paint()..filterQuality = FilterQuality.low;

    // 접는 선: n·q = c (n은 말려 나가는 쪽을 가리킴). 위쪽 모서리가 먼저 말리도록 살짝 기울임
    const double tilt = 0.32;
    final Offset n = fromRight ? Offset(math.cos(tilt), -math.sin(tilt)) : Offset(-math.cos(tilt), -math.sin(tilt));
    double dot(Offset q) => q.dx * n.dx + q.dy * n.dy;
    final corners = [page.topLeft, page.topRight, page.bottomLeft, page.bottomRight];
    final double hi = corners.map(dot).reduce(math.max);
    final double lo = corners.map(dot).reduce(math.min);
    final double c = hi - (hi - lo + 2) * t.clamp(0.0, 1.0);

    // 접는 선을 기준으로 남는 쪽(n·q <= c) 다각형
    Path half(bool keep) {
      final double big = (size.width + size.height) * 4;
      final Offset dir = Offset(-n.dy, n.dx); // 선의 방향
      final Offset p0 = n * c; // 선 위의 한 점
      final Offset a = p0 + dir * big, b = p0 - dir * big;
      final Offset away = n * (keep ? -big : big);
      return Path()
        ..moveTo(a.dx, a.dy)
        ..lineTo(b.dx, b.dy)
        ..lineTo(b.dx + away.dx, b.dy + away.dy)
        ..lineTo(a.dx + away.dx, a.dy + away.dy)
        ..close();
    }

    final Path keep = half(true);
    final Path gone = half(false);

    // 1) 아직 넘어가지 않은 부분
    canvas.save();
    canvas.clipRect(page);
    canvas.clipPath(keep);
    canvas.drawImageRect(image, src, page, paint);
    canvas.restore();

    // 2) 새로 드러난 쪽 위, 접힌 선 근처의 그림자
    {
      final Offset p0 = n * c;
      final shadow = Paint()
        ..shader = ui.Gradient.linear(p0, p0 + n * 34, [const Color(0x55000000), const Color(0x00000000)]);
      canvas.save();
      canvas.clipRect(page);
      canvas.clipPath(gone);
      canvas.drawRect(page, shadow);
      canvas.restore();
    }

    // 3) 말린 뒷면: 넘어간 부분을 접는 선으로 뒤집어 그린 것 (뒷면이라 글자가 흐리게 거울처럼)
    final Float64List m = Float64List(16)
      ..[0] = 1 - 2 * n.dx * n.dx
      ..[1] = -2 * n.dx * n.dy
      ..[4] = -2 * n.dx * n.dy
      ..[5] = 1 - 2 * n.dy * n.dy
      ..[10] = 1
      ..[12] = 2 * c * n.dx
      ..[13] = 2 * c * n.dy
      ..[15] = 1;
    canvas.save();
    canvas.clipRect(page);
    canvas.clipPath(keep);
    // 뒷면 그림자 (말린 종이가 아래 쪽에 드리우는 그림자)
    final Path flap = Path()..addRect(page);
    final Path flapShape = Path.combine(PathOperation.intersect, flap.transform(m), keep);
    canvas.drawShadow(flapShape, Colors.black, 6, false);
    canvas.transform(m);
    canvas.clipRect(page);
    canvas.drawImageRect(image, src, page, paint);
    canvas.drawRect(page, Paint()..color = back.withValues(alpha: 0.86));
    canvas.restore();

    // 4) 말린 종이의 둥근 느낌: 접는 선 쪽이 밝고 바깥으로 갈수록 살짝 어두워짐
    {
      final Offset p0 = n * c;
      final shade = Paint()
        ..shader = ui.Gradient.linear(p0, p0 - n * 90, [const Color(0x14000000), const Color(0x00FFFFFF), const Color(0x1A000000)], [0.0, 0.35, 1.0]);
      canvas.save();
      canvas.clipRect(page);
      canvas.clipPath(flapShape);
      canvas.drawRect(page, shade);
      canvas.restore();
    }
  }

  @override
  bool shouldRepaint(covariant PageCurlPainter old) => old.t != t || old.image != image || old.fromRight != fromRight || old.back != back;
}
