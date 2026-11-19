import 'dart:math' as math;

import 'package:flutter/material.dart';

import '../widgets/app_colors.dart';

/// 시작 화면: 앱 아이콘(책 읽는 늑대)이 나타난 뒤, 늑대가 손으로 안경 오른쪽을 잡고 살짝 올렸다가 다시 내리고 사라짐
/// 그림은 assets/splash/ 의 층(바탕·안경·눈·책 앞쪽·손)을 겹쳐 그림. 좌표는 모두 그림 한 변을 1로 본 비율
/// 바탕(base): 안경과 오른손을 지운 그림 / 안경(glass): 테+렌즈 / 눈(eyes): 렌즈 위에 고정 / 책(book): 팔이 책 뒤로 숨게 덮는 부분 / 손(paw)
class SplashOverlay extends StatefulWidget {
  const SplashOverlay({super.key, required this.onDone});
  final VoidCallback onDone;

  /// 앱 이름 (설치한 앱 이름과 같게)
  static const String appName = '이리ERI';

  @override
  State<SplashOverlay> createState() => _SplashOverlayState();
}

class _SplashOverlayState extends State<SplashOverlay> with SingleTickerProviderStateMixin {
  static const int _totalMs = 3100;
  late final AnimationController _c = AnimationController(vsync: this, duration: const Duration(milliseconds: _totalMs));

  static const List<String> _layers = [
    'assets/splash/base.webp',
    'assets/splash/glass.png',
    'assets/splash/eyes.png',
    'assets/splash/book.png',
    'assets/splash/paw.png',
  ];

  // 손(오른손): 쉴 때(책 위) → 안경 오른쪽 테를 아래에서 잡음 → 안경과 함께 올렸다가 내림 → 다시 책 위로
  static const Offset _pawRest = Offset(0.6982, 0.5595);
  static const Offset _pawGrab = Offset(0.6958, 0.4733);
  static const double _pawGrabTilt = -0.45; // 잡을 때 손이 기우는 각도(라디안)
  static const Size _pawSize = Size(0.1165, 0.0882);
  static const Offset _armRoot = Offset(0.7039, 0.6149); // 팔이 시작하는 곳 (책 뒤에 가려짐)
  // 안경: 왼쪽 다리 끝을 축으로 오른쪽이 들리게 살짝 돌리면서 조금 올림
  static const Offset _glassPivot = Offset(0.2670, 0.4207);
  static const double _liftAngle = -0.06;
  static const double _liftUp = 0.0065;

  /// 안경을 [lift](0~1)만큼 들었을 때 점 [p]가 옮겨 가는 곳
  static Offset _liftPoint(Offset p, double lift) {
    final double a = _liftAngle * lift;
    final Offset d = p - _glassPivot;
    final double c = math.cos(a), sn = math.sin(a);
    return _glassPivot + Offset(d.dx * c - d.dy * sn, d.dx * sn + d.dy * c) + Offset(0, -_liftUp * lift);
  }

  double _seg(double t, double a, double b, [Curve curve = Curves.linear]) {
    if (t <= a) return 0;
    if (t >= b) return 1;
    return curve.transform((t - a) / (b - a));
  }

  double _ms(int ms) => ms / _totalMs;

  bool _started = false;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    if (_started) return;
    _started = true;
    // 그림을 다 읽은 뒤 움직이기 시작 (첫 화면에 빈칸이 보이지 않게). 늦어도 0.6초 안에는 시작
    final Future<void> ready = Future.wait([
      for (final String p in _layers) precacheImage(AssetImage(p), context).catchError((_) {}),
    ]).timeout(const Duration(milliseconds: 600), onTimeout: () => const []);
    ready.whenComplete(_start);
  }

  void _start() {
    if (!mounted) return;
    // 애니메이션 끄기를 켰으면 움직이지 않고 다 나온 모습으로 약 1초 보여 준 뒤 사라짐
    if (Anim.off.value) {
      _c.value = _ms(2600);
      Future<void>.delayed(const Duration(milliseconds: 1000), () {
        if (mounted) widget.onDone();
      });
      return;
    }
    _c.forward().whenCompleteOrCancel(() {
      if (mounted) widget.onDone();
    });
  }

  @override
  void dispose() {
    _c.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final Color bg = Theme.of(context).scaffoldBackgroundColor;
    final Color fg = Theme.of(context).colorScheme.onSurface;
    const double size = 200;
    // Material로 감싸야 글자 밑에 노란 밑줄(글자 모양이 정해지지 않았다는 표시)이 생기지 않음
    return Material(
      type: MaterialType.transparency,
      child: AbsorbPointer(
      child: AnimatedBuilder(
        animation: _c,
        builder: (context, _) {
          final double t = _c.value;
          final double intro = _seg(t, 0, _ms(450), Curves.easeOutCubic);
          final double name = _seg(t, _ms(250), _ms(700), Curves.easeOutCubic);
          final double reach = _seg(t, _ms(650), _ms(1100), Curves.easeInOutCubic);
          final double up = _seg(t, _ms(1100), _ms(1450), Curves.easeOutCubic);
          final double down = _seg(t, _ms(1600), _ms(1900), Curves.easeInOutCubic);
          final double release = _seg(t, _ms(1950), _ms(2400), Curves.easeInOutCubic);
          final double out = _seg(t, _ms(2750), 1, Curves.easeInCubic);

          // 안경을 든 정도 (올렸다가 다시 내림)
          final double lift = up * (1 - down);
          // 손 위치·기울기
          Offset paw;
          double angle;
          if (release > 0) {
            paw = Offset.lerp(_pawGrab, _pawRest, release)!.translate(0, -0.015 * math.sin(math.pi * release));
            angle = _pawGrabTilt * (1 - release);
          } else if (up > 0) {
            paw = _liftPoint(_pawGrab, lift);
            angle = _pawGrabTilt + _liftAngle * lift;
          } else {
            paw = Offset.lerp(_pawRest, _pawGrab, reach)!.translate(0, -0.015 * math.sin(math.pi * reach));
            angle = _pawGrabTilt * reach;
          }

          return Opacity(
            opacity: 1 - out,
            child: ColoredBox(
              color: bg,
              child: Center(
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Opacity(
                      opacity: intro.clamp(0.0, 1.0),
                      child: Transform.scale(
                        scale: (0.86 + 0.14 * intro) * (1 + 0.05 * out),
                        child: SizedBox(
                          width: size,
                          height: size,
                          child: Stack(
                            clipBehavior: Clip.none,
                            children: [
                              _layer(_layers[0]),
                              Positioned.fill(
                                child: Transform.translate(
                                  offset: Offset(0, -_liftUp * lift * size),
                                  child: Transform.rotate(
                                    angle: _liftAngle * lift,
                                    origin: Offset((_glassPivot.dx - 0.5) * size, (_glassPivot.dy - 0.5) * size),
                                    child: _img(_layers[1]),
                                  ),
                                ),
                              ),
                              _layer(_layers[2]),
                              Positioned.fill(child: CustomPaint(painter: _ArmPainter(root: _armRoot, paw: paw))),
                              _layer(_layers[3]),
                              Positioned(
                                left: (paw.dx - _pawSize.width / 2) * size,
                                top: (paw.dy - _pawSize.height / 2) * size,
                                width: _pawSize.width * size,
                                height: _pawSize.height * size,
                                child: Transform.rotate(angle: angle, child: _img(_layers[4])),
                              ),
                            ],
                          ),
                        ),
                      ),
                    ),
                    const SizedBox(height: 18),
                    // 앱 이름
                    Opacity(
                      opacity: name.clamp(0.0, 1.0),
                      child: Transform.translate(
                        offset: Offset(0, 14 * (1 - name)),
                        child: Text(
                          SplashOverlay.appName,
                          style: TextStyle(color: fg, fontSize: 26, fontWeight: FontWeight.w800, letterSpacing: 0.6),
                        ),
                      ),
                    ),
                  ],
                ),
              ),
            ),
          );
        },
      ),
      ),
    );
  }

  Widget _img(String path) => Image.asset(path, fit: BoxFit.fill, filterQuality: FilterQuality.medium, gaplessPlayback: true);

  Widget _layer(String path) => Positioned.fill(child: _img(path));
}

/// 책 뒤에서 나와 손까지 이어지는 팔 (손과 같은 털색, 가운데가 살짝 밝게)
class _ArmPainter extends CustomPainter {
  _ArmPainter({required this.root, required this.paw});
  final Offset root;
  final Offset paw;

  @override
  void paint(Canvas canvas, Size size) {
    final Offset a = Offset(root.dx * size.width, root.dy * size.height);
    final Offset b = Offset(paw.dx * size.width, paw.dy * size.height);
    if ((a - b).distance < size.width * 0.02) return;
    // 팔꿈치 쪽(오른쪽 아래)으로 살짝 휘게
    final Offset ctrl = Offset(a.dx + size.width * 0.01, (a.dy + b.dy) / 2 + size.height * 0.04);
    final Path path = Path()
      ..moveTo(a.dx, a.dy)
      ..quadraticBezierTo(ctrl.dx, ctrl.dy, b.dx, b.dy);
    final double w = size.width * 0.098;
    canvas.drawPath(
      path,
      Paint()
        ..color = const Color(0xFF93A48A)
        ..style = PaintingStyle.stroke
        ..strokeWidth = w
        ..strokeCap = StrokeCap.round,
    );
    canvas.drawPath(
      path,
      Paint()
        ..color = const Color(0xFFA2B399)
        ..style = PaintingStyle.stroke
        ..strokeWidth = w * 0.55
        ..strokeCap = StrokeCap.round
        ..maskFilter = MaskFilter.blur(BlurStyle.normal, size.width * 0.012),
    );
  }

  @override
  bool shouldRepaint(_ArmPainter old) => old.root != root || old.paw != paw;
}
