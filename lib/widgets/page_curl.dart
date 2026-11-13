import 'dart:math' as math;
import 'dart:ui' as ui;

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/scheduler.dart';

import 'app_colors.dart';

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


// ─────────────────────────────────────────────────────────────────────────────
// 두 쪽 보기: 책처럼 넘기기
// 손가락을 따라 아래(또는 위) 모서리부터 비스듬히 말려 올라가고, 책등(가운데)에 붙은 채로
// 반대쪽으로 넘어간다. 넘어가는 장의 뒷면에는 다음 쪽이 보이고, 들린 자리에는 실제 새 쪽이 드러난다.
// ─────────────────────────────────────────────────────────────────────────────

enum _BookPhase { idle, waiting, dragging, settling }

/// 책처럼 넘기기의 손가락 추적과 마무리 움직임을 맡음 (화면마다 하나)
class BookCurlDrag extends ChangeNotifier {
  BookCurlDrag({
    required TickerProvider vsync,
    required this.capture,
    required this.turn,
    required this.isRtl,
    this.canTurn,
  }) {
    _anim = AnimationController(vsync: vsync)..addListener(_onTick);
  }

  /// 지금 화면을 그림으로 찍음
  final Future<ui.Image?> Function() capture;

  /// 실제 화면을 한 번 넘김 (+1 다음, -1 이전). 넘어갔으면 true
  final Future<bool> Function(int dir) turn;

  /// 읽기 방향이 오른쪽→왼쪽인지 (만화·세로쓰기)
  final bool Function() isRtl;

  /// 넘길 쪽이 있는지 (모르면 null)
  final bool Function(int dir)? canTurn;

  /// 화면 위에 놓이는 넘기기 층의 열쇠 (손가락 위치를 이 층 기준으로 바꿈)
  final GlobalKey layerKey = GlobalKey();

  late final AnimationController _anim;
  _BookPhase _phase = _BookPhase.idle;

  ui.Image? image;
  final ValueNotifier<ui.Image?> after = ValueNotifier<ui.Image?>(null);
  bool fromRight = true;
  bool bottom = true;
  Offset point = Offset.zero;
  Size size = Size.zero;

  int _dir = 1;
  Offset _start = Offset.zero;
  Offset _finger = Offset.zero;
  DateTime _startTime = DateTime.now();
  bool? _released; // 손을 뗐을 때 넘기기로 했는지
  Future<bool>? _turning;
  Offset _from = Offset.zero, _to = Offset.zero;
  int _gen = 0;

  /// 지금 넘기는 중 (손가락으로 끄는 중이거나 마무리 중)
  bool get busy => _phase != _BookPhase.idle;

  /// 이번 손동작으로 끌기가 시작됨 (손을 떼면 [end]를 불러야 함)
  bool get tracking => _phase == _BookPhase.waiting || _phase == _BookPhase.dragging;

  bool get active => image != null;

  Offset _toLocal(Offset global) {
    final box = layerKey.currentContext?.findRenderObject() as RenderBox?;
    if (box == null || !box.hasSize) return global;
    size = box.size;
    return box.globalToLocal(global);
  }

  double get _sx => size.width / 2;
  double get _pw => fromRight ? size.width - _sx : _sx;
  Offset get corner => Offset(fromRight ? size.width : 0, bottom ? size.height : 0);
  Offset get _target => Offset(2 * _sx - corner.dx, corner.dy);

  /// 책등에 붙은 종이가 갈 수 있는 곳으로 모서리 위치를 제한
  Offset _constrain(Offset q) {
    final double h = size.height;
    final Offset a1 = Offset(_sx, corner.dy);
    Offset d = q - a1;
    if (d.distance > _pw) q = a1 + d / d.distance * _pw;
    final Offset a2 = Offset(_sx, h - corner.dy);
    final double r2 = math.sqrt(_pw * _pw + h * h);
    d = q - a2;
    if (d.distance > r2) q = a2 + d / d.distance * r2;
    final double y = bottom ? math.min(q.dy, h) : math.max(q.dy, 0.0);
    return Offset(q.dx, y);
  }

  double _progressOf(double x) => ((corner.dx - x) / (corner.dx - _target.dx)).clamp(0.0, 1.0);

  /// 손가락 위치 → 말려 올라간 모서리 위치
  Offset _fingerToPoint(Offset f) {
    final Offset c = corner, t = _target;
    // 손가락이 화면 반대편 끝에 닿으면 다 넘어가도록 (모서리 가까이에서 잡으면 거의 손가락 그대로)
    final double far = fromRight ? 0.0 : size.width;
    final double span = math.max((_start.dx - far).abs(), _pw * 0.5);
    final double gain = ((c.dx - t.dx).abs() / span).clamp(1.0, 2.6);
    double x = c.dx + (f.dx - _start.dx) * gain;
    x = fromRight ? x.clamp(t.dx, c.dx) : x.clamp(c.dx, t.dx);
    final double p = _progressOf(x);
    // 똑바로 밀어도 모서리가 살짝 들려 비스듬히 말리도록
    final double lift = size.height * 0.14 * math.sin(math.pi * p);
    final double y = c.dy + (f.dy - _start.dy) + (bottom ? -lift : lift);
    return _constrain(Offset(x, y));
  }

  /// 손가락이 가로로 끌리기 시작함. [pre]: 손가락이 닿을 때 미리 찍어 둔 그림 (넘겨받아 정리까지 맡음)
  Future<void> begin(Offset globalStart, Offset globalNow, Future<ui.Image?>? pre) async {
    if (_phase != _BookPhase.idle) {
      pre?.then((i) => i?.dispose());
      return;
    }
    final double dx = globalNow.dx - globalStart.dx;
    final bool right = dx < 0;
    final int dir = (right != isRtl()) ? 1 : -1;
    if (canTurn != null && !canTurn!(dir)) {
      pre?.then((i) => i?.dispose());
      return;
    }
    final int gen = ++_gen;
    _phase = _BookPhase.waiting;
    _released = null;
    _turning = null;
    _dir = dir;
    fromRight = right;
    _startTime = DateTime.now();
    _start = _toLocal(globalStart);
    _finger = _toLocal(globalNow);
    bottom = _start.dy > size.height * 0.5;

    ui.Image? img = pre == null ? null : await pre;
    img ??= await capture();
    if (gen != _gen) {
      img?.dispose();
      return;
    }
    if (img == null || size.isEmpty) {
      img?.dispose();
      final bool go = _released == true;
      _phase = _BookPhase.idle;
      if (go) await turn(dir);
      return;
    }
    if (_released == false) {
      // 그림이 오기 전에 손을 떼고 되돌림: 아무것도 하지 않음
      img.dispose();
      _phase = _BookPhase.idle;
      _released = null;
      return;
    }
    image = img;
    point = _released == null ? _fingerToPoint(_finger) : corner;
    if (_released == null) _phase = _BookPhase.dragging;
    notifyListeners();
    await SchedulerBinding.instance.endOfFrame;
    if (gen != _gen) return;
    // 덮개(넘기기 전 그림)를 씌운 채로 실제 화면을 넘겨 둠 → 들린 자리에 새 쪽이 드러남
    _turning = turn(dir);
    // 그림이 준비되기 전에 이미 손을 뗐으면 바로 마무리 움직임 시작
    if (_released != null && _phase == _BookPhase.waiting) _settle(_released!);
    final bool turned = await _turning!;
    if (gen != _gen) return;
    if (turned) {
      await Future<void>.delayed(const Duration(milliseconds: 16)); // 새 쪽이 그려질 시간
      if (gen != _gen) return;
      capture().then((a) {
        if (gen == _gen && image != null) {
          after.value?.dispose();
          after.value = a;
        } else {
          a?.dispose();
        }
      });
    }
  }

  /// 손가락이 움직임
  void update(Offset global) {
    if (!tracking) return;
    _finger = _toLocal(global);
    if (_phase == _BookPhase.dragging) {
      point = _fingerToPoint(_finger);
      notifyListeners();
    }
  }

  /// 손을 뗌. [cancel]이면 무조건 되돌림
  void end({bool cancel = false}) {
    if (!tracking) return;
    bool commit = false;
    if (!cancel) {
      final double moved = (_finger.dx - _start.dx) * (fromRight ? -1 : 1);
      final int ms = DateTime.now().difference(_startTime).inMilliseconds;
      final bool flick = ms < 350 && moved > 30;
      final double p = image == null ? 0 : _progressOf(point.dx);
      commit = flick || p > 0.3;
    }
    _released = commit;
    if (image == null) return; // 그림이 준비되면 begin()에서 이어서 마무리
    _settle(commit);
  }

  /// 손가락 없이 한 번에 넘김 (끌기가 시작되지 않은 빠른 밀기)
  void autoTurn(double dx, Future<ui.Image?>? pre, Offset globalStart) {
    begin(globalStart, globalStart + Offset(dx.sign * 20, 0), pre); // 첫 기다림 전까지는 바로 실행됨
    if (tracking && image == null) _released = true;
  }

  Future<void> _settle(bool commit) async {
    final int gen = _gen;
    _phase = _BookPhase.settling;
    _from = point;
    _to = commit ? _target : corner;
    final double dist = (_to.dx - _from.dx).abs() / math.max(1.0, (corner.dx - _target.dx).abs());
    _anim.duration = Anim.ms((160 + 380 * dist).round());
    _anim.value = 0;
    await _anim.animateTo(1, curve: Curves.easeOutCubic);
    if (gen != _gen) return;
    final bool turned = await (_turning ?? Future<bool>.value(false));
    if (gen != _gen) return;
    if (commit && !turned) {
      // 넘길 쪽이 없었음: 제자리로 되돌림
      _from = point;
      _to = corner;
      _anim.duration = Anim.ms(320);
      _anim.value = 0;
      await _anim.animateTo(1, curve: Curves.easeOutCubic);
      if (gen != _gen) return;
    } else if (!commit && turned) {
      // 되돌림: 덮개가 다 덮은 상태에서 실제 화면도 원래 쪽으로
      await turn(-_dir);
      if (gen != _gen) return;
      await SchedulerBinding.instance.endOfFrame;
    }
    _clear();
  }

  void _onTick() {
    if (_phase != _BookPhase.settling) return;
    final double e = _anim.value;
    final Offset q = Offset.lerp(_from, _to, e)!;
    // 넘어가는 동안 모서리가 살짝 들렸다가 내려앉음
    final double span = (_to.dx - _from.dx).abs() / math.max(1.0, (corner.dx - _target.dx).abs());
    final double lift = size.height * 0.10 * span * math.sin(math.pi * e);
    point = _constrain(q + Offset(0, bottom ? -lift : lift));
    notifyListeners();
  }

  void _clear() {
    _gen++;
    _anim.stop();
    _phase = _BookPhase.idle;
    _released = null;
    _turning = null;
    image?.dispose();
    image = null;
    after.value?.dispose();
    after.value = null;
    notifyListeners();
  }

  @override
  void dispose() {
    _gen++;
    _anim.dispose();
    image?.dispose();
    after.value?.dispose();
    after.dispose();
    super.dispose();
  }
}

/// 화면 위에 깔리는 책처럼 넘기기 층 (넘기지 않을 때는 아무것도 그리지 않음)
class BookCurlLayer extends StatelessWidget {
  BookCurlLayer({required this.drag, this.paper}) : super(key: drag.layerKey);

  final BookCurlDrag drag;
  final Color? paper;

  @override
  Widget build(BuildContext context) {
    final Color back = paper ?? (Theme.of(context).brightness == Brightness.dark ? const Color(0xFF2A2A2C) : const Color(0xFFF7F5F0));
    return IgnorePointer(
      child: ListenableBuilder(
        listenable: Listenable.merge([drag, drag.after]),
        builder: (context, _) {
          final img = drag.image;
          if (img == null) return const SizedBox.expand();
          return CustomPaint(
            size: Size.infinite,
            painter: BookCurlPainter(image: img, after: drag.after.value, point: drag.point, fromRight: drag.fromRight, bottom: drag.bottom, back: back),
          );
        },
      ),
    );
  }
}

/// 두 쪽 보기 책 넘김 그림: [point]는 들려 올라간 모서리가 지금 있는 곳
/// 접힌 선은 원래 모서리와 [point]를 잇는 선의 수직이등분선. 그 바깥 부분이 뒤집혀 넘어감
class BookCurlPainter extends CustomPainter {
  BookCurlPainter({required this.image, required this.after, required this.point, required this.fromRight, required this.bottom, required this.back});

  final ui.Image image;
  final ui.Image? after;
  final Offset point;
  final bool fromRight;
  final bool bottom;
  final Color back;

  static Float64List _reflect(Offset n, double c) => Float64List(16)
    ..[0] = 1 - 2 * n.dx * n.dx
    ..[1] = -2 * n.dx * n.dy
    ..[4] = -2 * n.dx * n.dy
    ..[5] = 1 - 2 * n.dy * n.dy
    ..[10] = 1
    ..[12] = 2 * c * n.dx
    ..[13] = 2 * c * n.dy
    ..[15] = 1;

  @override
  void paint(Canvas canvas, Size size) {
    if (size.isEmpty) return;
    final double w = size.width, h = size.height, sx = w / 2;
    final Rect full = Offset.zero & size;
    final Rect src = Rect.fromLTWH(0, 0, image.width.toDouble(), image.height.toDouble());
    final paint = Paint()..filterQuality = FilterQuality.low;
    final Offset c0 = Offset(fromRight ? w : 0, bottom ? h : 0);
    final Offset v = c0 - point;
    final double len = v.distance;
    if (len < 0.5) {
      canvas.drawImageRect(image, src, full, paint);
      return;
    }
    final Offset n = v / len; // 모서리 쪽을 가리킴
    final Offset mid = (c0 + point) / 2;
    final double c = n.dx * mid.dx + n.dy * mid.dy;
    final Rect page = fromRight ? Rect.fromLTRB(sx, 0, w, h) : Rect.fromLTRB(0, 0, sx, h);
    // 다 넘어갈 즈음엔 그림자·윤기를 걷어 새 쪽과 똑같아지게
    final double prog = ((c0.dx - point.dx) / (2 * c0.dx - 2 * sx)).clamp(0.0, 1.0);
    final double fade = ((1 - prog) * 5).clamp(0.0, 1.0);
    Color k(int argb) => Color(argb).withValues(alpha: Color(argb).a * fade);

    Path halfPlane(bool cornerSide) {
      final double big = (w + h) * 4;
      final Offset dir = Offset(-n.dy, n.dx);
      final Offset p0 = n * c;
      final Offset a = p0 + dir * big, b = p0 - dir * big;
      final Offset away = n * (cornerSide ? big : -big);
      return Path()
        ..moveTo(a.dx, a.dy)
        ..lineTo(b.dx, b.dy)
        ..lineTo(b.dx + away.dx, b.dy + away.dy)
        ..lineTo(a.dx + away.dx, a.dy + away.dy)
        ..close();
    }

    // 넘어가는 장에서 접힌 선 바깥(모서리 쪽) 부분
    final Path flapLeaf = Path.combine(PathOperation.intersect, Path()..addRect(page), halfPlane(true));
    final Path rest = Path.combine(PathOperation.difference, Path()..addRect(full), flapLeaf);

    // 1) 아직 그대로인 부분 (넘기기 전 화면)
    canvas.save();
    canvas.clipPath(rest);
    canvas.drawImageRect(image, src, full, paint);
    canvas.restore();

    // 2) 들린 자리(실제 새 쪽이 비침): 접힌 선 근처와 책등 쪽에 그림자
    {
      final Offset p0 = n * c;
      final double sw = math.min(56.0, math.max(14.0, len * 0.35));
      canvas.save();
      canvas.clipPath(flapLeaf);
      canvas.drawRect(page, Paint()..shader = ui.Gradient.linear(p0, p0 + n * sw, [k(0x59000000), const Color(0x00000000)]));
      canvas.drawRect(
        page,
        Paint()
          ..shader = ui.Gradient.linear(Offset(sx, 0), Offset(fromRight ? sx + 26 : sx - 26, 0), [k(0x24000000), const Color(0x00000000)]),
      );
      canvas.restore();
    }

    // 3) 넘어가는 장의 뒷면 (접힌 선으로 뒤집혀 반대쪽에 놓임)
    final Float64List r = _reflect(n, c);
    final Path flapScreen = flapLeaf.transform(r);
    if (fade > 0) canvas.drawShadow(flapScreen, Colors.black, 7 * fade, false);
    canvas.save();
    canvas.transform(r);
    canvas.clipPath(flapLeaf);
    final a = after;
    if (a != null) {
      // 뒷면 = 넘긴 뒤 반대편에 오는 새 쪽. 책등을 기준으로 한 번 더 뒤집어 그리면 제자리에 바로 놓임
      final Float64List mirror = Float64List(16)
        ..[0] = -1
        ..[5] = 1
        ..[10] = 1
        ..[12] = 2 * sx
        ..[15] = 1;
      canvas.transform(mirror);
      canvas.drawImageRect(a, Rect.fromLTWH(0, 0, a.width.toDouble(), a.height.toDouble()), full, paint);
    } else {
      // 새 쪽 그림이 아직 없으면 종이 뒷면 (앞면 글자가 흐리게 비침)
      canvas.drawImageRect(image, src, full, paint);
      canvas.drawRect(full, Paint()..color = back.withValues(alpha: 0.88));
    }
    canvas.restore();

    // 4) 둥글게 말린 느낌: 접힌 선 쪽이 어둡다가 밝게 빛나고 바깥으로 갈수록 살짝 어두워짐
    {
      final Offset p0 = n * c;
      final double cw = math.min(_pwOf(w) * 0.9, math.max(24.0, len * 0.55));
      canvas.save();
      canvas.clipPath(flapScreen);
      canvas.drawRect(
        full,
        Paint()
          ..shader = ui.Gradient.linear(
            p0,
            p0 - n * cw,
            [k(0x38000000), const Color(0x00FFFFFF), k(0x2EFFFFFF), const Color(0x00000000), k(0x14000000)],
            [0.0, 0.10, 0.28, 0.55, 1.0],
          ),
      );
      canvas.restore();
    }
  }

  double _pwOf(double w) => w / 2;

  @override
  bool shouldRepaint(covariant BookCurlPainter old) =>
      old.point != point || old.image != image || old.after != after || old.fromRight != fromRight || old.bottom != bottom || old.back != back;
}
