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

/// 그룹 목록·그룹 단추의 [전체] 아이콘: 서류가 들어 있는 폴더 (어디서나 같은 모양)
/// 테마 색으로 칠하고 진한 테두리로 감싸 어느 바탕에서도 잘 보이게
/// (밝은 테마는 시그니쳐 초록 계열, 다크는 회색 계열, 서재는 초록 독서등 계열)
class FolderDocsIcon extends StatelessWidget {
  const FolderDocsIcon({super.key, this.size = 20});

  final double size;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final bool dark = theme.brightness == Brightness.dark;
    final Color sig = theme.colorScheme.secondaryContainer;
    final _FolderDocsPainter painter;
    if (!dark) {
      painter = _FolderDocsPainter(
          back: const Color(0xFF6F9E6F), front: const Color(0xFFA3CCA3), paper: Colors.white, lines: const Color(0xFF8DB98D), edge: const Color(0xFF3C6A3C));
    } else if (sig.value != 0xFF343438) {
      // 서재처럼 색이 있는 다크 테마
      painter = _FolderDocsPainter(
          back: Color.lerp(sig, Colors.black, 0.25)!, front: Color.lerp(sig, Colors.white, 0.2)!, paper: const Color(0xFFF3E8D5), lines: const Color(0xFF8A765F), edge: const Color(0xFFE8D5B5));
    } else {
      painter = const _FolderDocsPainter(
          back: Color(0xFF55585E), front: Color(0xFF8B8F96), paper: Color(0xFFEDEDEF), lines: Color(0xFF8B8F96), edge: Color(0xFFD4D6DA));
    }
    return SizedBox.square(dimension: size, child: CustomPaint(painter: painter));
  }
}

class _FolderDocsPainter extends CustomPainter {
  const _FolderDocsPainter({required this.back, required this.front, required this.paper, required this.lines, required this.edge});

  final Color back, front, paper, lines, edge;

  @override
  void paint(Canvas canvas, Size size) {
    final double u = size.width / 24;
    canvas.save();
    canvas.scale(u);
    final edgePaint = Paint()
      ..color = edge
      ..style = PaintingStyle.stroke
      ..strokeWidth = 1.4
      ..strokeJoin = StrokeJoin.round;
    // 뒤쪽 폴더 (손잡이 달린 윗부분)
    final backPath = Path()
      ..moveTo(2.5, 20)
      ..lineTo(2.5, 5.2)
      ..quadraticBezierTo(2.5, 4, 3.7, 4)
      ..lineTo(8.6, 4)
      ..lineTo(10.4, 6)
      ..lineTo(20.3, 6)
      ..quadraticBezierTo(21.5, 6, 21.5, 7.2)
      ..lineTo(21.5, 20)
      ..close();
    canvas.drawPath(backPath, Paint()..color = back);
    canvas.drawPath(backPath, edgePaint);
    // 서류 두 장 (살짝 오른쪽으로 꽂아 왼쪽 위 손잡이가 보이게)
    final paper2 = RRect.fromLTRBR(11, 1.6, 20, 12, const Radius.circular(1.2));
    canvas.drawRRect(paper2, Paint()..color = Color.lerp(paper, lines, 0.35)!);
    canvas.drawRRect(paper2, edgePaint);
    final sheet = RRect.fromLTRBR(7.6, 3, 18.4, 14, const Radius.circular(1.2));
    canvas.drawRRect(sheet, Paint()..color = paper);
    canvas.drawRRect(sheet, edgePaint);
    final line = Paint()
      ..color = lines
      ..strokeWidth = 1.5
      ..strokeCap = StrokeCap.round;
    canvas.drawLine(const Offset(10, 6.2), const Offset(16, 6.2), line);
    canvas.drawLine(const Offset(10, 8.8), const Offset(14.4, 8.8), line);
    // 앞쪽 폴더 판
    final frontRect = RRect.fromLTRBR(2.5, 10.8, 21.5, 20.5, const Radius.circular(1.6));
    canvas.drawRRect(frontRect, Paint()..color = front);
    canvas.drawRRect(frontRect, edgePaint);
    canvas.restore();
  }

  @override
  bool shouldRepaint(covariant _FolderDocsPainter old) =>
      old.back != back || old.front != front || old.paper != paper || old.lines != lines || old.edge != edge;
}

/// 즐겨찾기 아이콘: 노란 책갈피 + 진한 테두리 (밝은 바탕·초록 바탕에서도 잘 보이게)
class FavoritesIcon extends StatelessWidget {
  const FavoritesIcon({super.key, this.size = 18});

  final double size;

  @override
  Widget build(BuildContext context) {
    return SizedBox.square(
      dimension: size,
      child: Stack(alignment: Alignment.center, children: [
        Icon(Icons.bookmarks, size: size, color: const Color(0xFFFFC107)),
        Icon(Icons.bookmarks_outlined, size: size, color: const Color(0xFFB07800)),
      ]),
    );
  }
}

/// 파일 탐색 아이콘: 폴더(손잡이는 왼쪽 위) 안쪽에 돋보기, 폴더 선과 돋보기는 닿지 않게 띄움
class FolderSearchIcon extends StatelessWidget {
  const FolderSearchIcon({super.key, this.size = 21, this.color});

  final double size;
  final Color? color;

  @override
  Widget build(BuildContext context) {
    final Color c = color ?? IconTheme.of(context).color ?? Theme.of(context).colorScheme.onSurfaceVariant;
    return SizedBox.square(dimension: size, child: CustomPaint(painter: _FolderSearchPainter(c)));
  }
}

class _FolderSearchPainter extends CustomPainter {
  _FolderSearchPainter(this.color);

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
    canvas.saveLayer(const Rect.fromLTWH(-2, -2, 28, 28), Paint());
    // 폴더 (손잡이는 왼쪽 위)
    final folder = Path()
      ..moveTo(4.2, 4.5)
      ..lineTo(8.6, 4.5)
      ..lineTo(10.6, 6.6)
      ..lineTo(19.8, 6.6)
      ..quadraticBezierTo(21.5, 6.6, 21.5, 8.3)
      ..lineTo(21.5, 17.8)
      ..quadraticBezierTo(21.5, 19.5, 19.8, 19.5)
      ..lineTo(4.2, 19.5)
      ..quadraticBezierTo(2.5, 19.5, 2.5, 17.8)
      ..lineTo(2.5, 6.2)
      ..quadraticBezierTo(2.5, 4.5, 4.2, 4.5)
      ..close();
    canvas.drawPath(folder, stroke);
    // 돋보기 자리: 폴더 선을 살짝 지워 서로 닿지 않게
    const Offset c = Offset(13.4, 12.6);
    const double r = 3.1;
    const Offset h1 = Offset(15.7, 14.9), h2 = Offset(17.6, 16.8);
    final clear = Paint()
      ..blendMode = BlendMode.clear
      ..style = PaintingStyle.stroke
      ..strokeCap = StrokeCap.round
      ..strokeWidth = 1.8 + 2.2;
    canvas.drawCircle(c, r, clear);
    canvas.drawLine(h1, h2, clear);
    canvas.drawCircle(c, r, stroke);
    canvas.drawLine(h1, h2, stroke);
    canvas.restore();
    canvas.restore();
  }

  @override
  bool shouldRepaint(covariant _FolderSearchPainter old) => old.color != color;
}
