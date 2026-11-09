import 'dart:math' as math;

import 'package:flutter/material.dart';

/// 빠른 메뉴 항목
class QuickArcMenuItem {
  const QuickArcMenuItem({
    required this.icon,
    required this.tooltip,
    required this.onTap,
    this.closeAfterTap = false,
  });

  final Widget icon;
  final String tooltip;
  final VoidCallback onTap;

  /// 누른 뒤 메뉴를 닫을지 여부 (파일 이동·화면 잠금처럼 화면이 바뀌는 기능)
  final bool closeAfterTap;
}

/// 오른쪽 아래 흰 동그라미 버튼 + 그 주위로 호(활) 모양으로 펼쳐지는 아이콘 메뉴.
/// - 동그라미를 누르면 열림/닫힘
/// - 호 위를 손가락으로 밀면 아이콘이 호를 따라 돌아가며 나머지 아이콘이 나타남
///
/// 이 위젯은 화면 오른쪽 아래에 Positioned(right, bottom)로 배치하는 것을 전제로 한다.
class QuickArcMenu extends StatefulWidget {
  const QuickArcMenu({super.key, required this.items});

  final List<QuickArcMenuItem> items;

  @override
  State<QuickArcMenu> createState() => _QuickArcMenuState();
}

class _QuickArcMenuState extends State<QuickArcMenu>
    with TickerProviderStateMixin {
  // ── 모양 ──
  static const double _circleRadius = 28.0; // 흰 동그라미 반지름
  static const double _arcRadius = 104.0; // 동그라미 중심 ~ 아이콘 중심 거리
  static const double _itemRadius = 22.0; // 아이콘 버튼 반지름
  static const double _bandWidth = 54.0; // 호 띠 두께

  // 호가 보이는 각도 범위 (화면 좌표: 0°=오른쪽, 90°=아래, 180°=왼쪽, 270°=위)
  // 동그라미 왼쪽 약간 아래(170°)에서 시작해 동그라미 바로 위(270°)까지
  static const double _startDeg = 170.0;
  static const double _endDeg = 270.0;
  static const double _stepDeg = 25.0; // 아이콘 간격 → 한 번에 5개 보임

  // 상자 크기: 동그라미 중심이 상자 오른쪽 아래에서 (_rightPad, _bottomPad) 만큼 떨어진 곳
  static const double _rightPad = _circleRadius + 4.0;
  static const double _bottomPad = _itemRadius + 22.0;
  static const double _boxW = _arcRadius + _itemRadius + 6.0 + _rightPad;
  static const double _boxH = _arcRadius + _itemRadius + 6.0 + _bottomPad;

  late final AnimationController _openCtrl = AnimationController(
      vsync: this, duration: const Duration(milliseconds: 200));
  late final AnimationController _snapCtrl = AnimationController(
      vsync: this, duration: const Duration(milliseconds: 160));

  bool _open = false;
  double _scrollDeg = 0.0; // 호를 따라 밀어낸 각도
  double? _lastPanDeg;
  double _snapFrom = 0.0;
  double _snapTo = 0.0;

  Offset get _center => const Offset(_boxW - _rightPad, _boxH - _bottomPad);

  double get _maxScrollDeg {
    final double needed =
        (widget.items.length - 1) * _stepDeg - (_endDeg - _startDeg);
    return math.max(0.0, needed);
  }

  @override
  void initState() {
    super.initState();
    _snapCtrl.addListener(() {
      final t = Curves.easeOut.transform(_snapCtrl.value);
      setState(() => _scrollDeg = _snapFrom + (_snapTo - _snapFrom) * t);
    });
  }

  @override
  void dispose() {
    _openCtrl.dispose();
    _snapCtrl.dispose();
    super.dispose();
  }

  void _toggle() {
    setState(() => _open = !_open);
    if (_open) {
      _openCtrl.forward();
    } else {
      _openCtrl.reverse();
    }
  }

  void _close() {
    if (!_open) return;
    setState(() => _open = false);
    _openCtrl.reverse();
  }

  double _angleOf(Offset local) {
    final d = local - _center;
    double deg = math.atan2(d.dy, d.dx) * 180.0 / math.pi;
    if (deg < 0) deg += 360.0;
    return deg;
  }

  void _onPanStart(DragStartDetails d) {
    _snapCtrl.stop();
    _lastPanDeg = _angleOf(d.localPosition);
  }

  void _onPanUpdate(DragUpdateDetails d) {
    final double cur = _angleOf(d.localPosition);
    final double? last = _lastPanDeg;
    _lastPanDeg = cur;
    if (last == null) return;
    double delta = cur - last;
    if (delta > 180) delta -= 360;
    if (delta < -180) delta += 360;
    // 손가락을 따라 아이콘이 움직이도록: 손가락 각도가 커지면 아이콘 각도도 커짐(= 스크롤 각도 감소)
    setState(() =>
        _scrollDeg = (_scrollDeg - delta).clamp(0.0, _maxScrollDeg).toDouble());
  }

  void _onPanEnd(DragEndDetails d) {
    _lastPanDeg = null;
    // 아이콘이 칸에 딱 맞게 정렬되도록 가까운 위치로 살짝 이동
    final double target = ((_scrollDeg / _stepDeg).round() * _stepDeg)
        .clamp(0.0, _maxScrollDeg)
        .toDouble();
    if ((target - _scrollDeg).abs() < 0.5) return;
    _snapFrom = _scrollDeg;
    _snapTo = target;
    _snapCtrl.forward(from: 0.0);
  }

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      width: _boxW,
      height: _boxH,
      // 띠·아이콘 어디서 밀어도 호를 따라 이동 (빈 공간은 본문으로 통과)
      child: GestureDetector(
        behavior: HitTestBehavior.deferToChild,
        onPanStart: _open ? _onPanStart : null,
        onPanUpdate: _open ? _onPanUpdate : null,
        onPanEnd: _open ? _onPanEnd : null,
        child: AnimatedBuilder(
          animation: _openCtrl,
          builder: (context, _) {
            final double t = Curves.easeOutCubic.transform(_openCtrl.value);
            final List<Widget> children = [];

            if (t > 0.0) {
              // 호 모양 배경 띠 (띠 위를 밀어서 아이콘 이동)
              children.add(Positioned.fill(
                child: CustomPaint(
                  painter: _ArcBandPainter(
                    center: _center,
                    radius: _arcRadius * t,
                    bandWidth: _bandWidth,
                    startDeg: _startDeg - _stepDeg * 0.5,
                    endDeg: _endDeg + _stepDeg * 0.4,
                    opacity: t,
                  ),
                ),
              ));

              for (int i = 0; i < widget.items.length; i++) {
                final double deg = _startDeg + i * _stepDeg - _scrollDeg;
                // 보이는 범위 밖으로 나간 아이콘은 서서히 사라짐
                final double outside = deg < _startDeg
                    ? (_startDeg - deg)
                    : (deg > _endDeg ? deg - _endDeg : 0.0);
                final double fade = (1.0 - outside / (_stepDeg * 0.6))
                    .clamp(0.0, 1.0)
                    .toDouble();
                if (fade <= 0.01) continue;
                final double rad = deg * math.pi / 180.0;
                final Offset p = _center +
                    Offset(math.cos(rad), math.sin(rad)) * (_arcRadius * t);
                final item = widget.items[i];
                children.add(Positioned(
                  left: p.dx - _itemRadius,
                  top: p.dy - _itemRadius,
                  width: _itemRadius * 2,
                  height: _itemRadius * 2,
                  child: Opacity(
                    opacity: (fade * t).clamp(0.0, 1.0).toDouble(),
                    child: IgnorePointer(
                      ignoring: !_open || fade < 0.6,
                      child: Tooltip(
                        message: item.tooltip,
                        child: Material(
                          color: Colors.transparent, // 아이콘 뒤 회색 동그라미 없음 (누를 때 물결 효과만 표시)
                          shape: const CircleBorder(),
                          clipBehavior: Clip.antiAlias,
                          child: InkWell(
                            customBorder: const CircleBorder(),
                            onTap: () {
                              item.onTap();
                              if (item.closeAfterTap) _close();
                            },
                            child: Center(child: item.icon),
                          ),
                        ),
                      ),
                    ),
                  ),
                ));
              }
            }

            // 흰 동그라미 버튼
            children.add(Positioned(
              left: _center.dx - _circleRadius,
              top: _center.dy - _circleRadius,
              width: _circleRadius * 2,
              height: _circleRadius * 2,
              child: GestureDetector(
                behavior: HitTestBehavior.opaque,
                onTap: _toggle,
                child: Container(
                  decoration: BoxDecoration(
                    shape: BoxShape.circle,
                    color: Colors.black.withValues(alpha: 0.55),
                    border: Border.all(
                      color: Color.lerp(Colors.white, Colors.amber, t) ??
                          Colors.white,
                      width: 2.6,
                    ),
                  ),
                ),
              ),
            ));

            return Stack(clipBehavior: Clip.none, children: children);
          },
        ),
      ),
    );
  }
}

class _ArcBandPainter extends CustomPainter {
  _ArcBandPainter({
    required this.center,
    required this.radius,
    required this.bandWidth,
    required this.startDeg,
    required this.endDeg,
    required this.opacity,
  });

  final Offset center;
  final double radius;
  final double bandWidth;
  final double startDeg;
  final double endDeg;
  final double opacity;

  @override
  void paint(Canvas canvas, Size size) {
    if (radius <= 1) return;
    final rect = Rect.fromCircle(center: center, radius: radius);
    final double start = startDeg * math.pi / 180.0;
    final double sweep = (endDeg - startDeg) * math.pi / 180.0;
    final band = Paint()
      ..style = PaintingStyle.stroke
      ..strokeWidth = bandWidth
      ..strokeCap = StrokeCap.round
      ..color = Colors.black.withValues(alpha: 0.78 * opacity);
    canvas.drawArc(rect, start, sweep, false, band);
    final outline = Paint()
      ..style = PaintingStyle.stroke
      ..strokeWidth = 1.0
      ..color = Colors.white.withValues(alpha: 0.18 * opacity);
    canvas.drawArc(
        Rect.fromCircle(center: center, radius: radius + bandWidth / 2),
        start,
        sweep,
        false,
        outline);
    canvas.drawArc(
        Rect.fromCircle(center: center, radius: radius - bandWidth / 2),
        start,
        sweep,
        false,
        outline);
  }

  // 띠 영역에서만 터치를 받고, 나머지 빈 공간은 아래 화면(본문)으로 통과시킨다
  @override
  bool? hitTest(Offset position) {
    final d = position - center;
    final double dist = d.distance;
    if ((dist - radius).abs() > bandWidth / 2 + 4) return false;
    double deg = math.atan2(d.dy, d.dx) * 180.0 / math.pi;
    if (deg < 0) deg += 360.0;
    return deg >= startDeg - 12 && deg <= endDeg + 12;
  }

  @override
  bool shouldRepaint(covariant _ArcBandPainter old) =>
      old.radius != radius || old.opacity != opacity || old.center != center;
}
