import 'dart:async';
import 'dart:math' as math;
import 'dart:ui' as ui;

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/scheduler.dart';
import 'package:flutter/services.dart';


// ─────────────────────────────────────────────────────────────────────────────
// 책처럼 넘기기
// 손가락을 따라 아래(또는 위) 모서리부터 비스듬히 말려 올라가고, 책등에 붙은 채로 넘어간다.
// - 두 쪽 보기: 책등은 가운데. 넘어가는 장의 뒷면에 다음 쪽이 보임
// - 한 쪽 보기: 책등은 화면 반대편 끝. 뒷면은 종이 뒷면(글자가 흐리게 비침)
// 들린 자리에는 실제 새 쪽이 드러난다.
// ─────────────────────────────────────────────────────────────────────────────

enum _BookPhase { idle, waiting, dragging, settling }

/// 넘어가는 종이 한 장의 자리: [page]는 넘어가는 쪽(종이)의 네모, [spine]은 그 종이가 붙어 있는 책등의 x
/// (빈 여백은 넘어가지 않고 그대로 있음)
class BookPaper {
  const BookPaper(this.page, this.spine);
  final Rect page;
  final double spine;
}

/// 책처럼 넘기기의 손가락 추적과 마무리 움직임을 맡음 (화면마다 하나)
class BookCurlDrag extends ChangeNotifier {
  BookCurlDrag({
    required TickerProvider vsync,
    required this.capture,
    required this.turn,
    required this.isRtl,
    this.canTurn,
    this.paperOf,
    this.waitForPage,
    this.beforeAfterCapture,
    this.liveReady,
    this.reverseFront,
    this.onCommitted,
  }) {
    _anim = AnimationController(vsync: vsync)..addListener(_onTick);
  }

  /// 넘긴 뒤 새 쪽이 다 그려질 때까지 덮개를 걷지 않음 (EPUB: 장이 바뀔 때 잠깐 빈 화면이 보이는 것 막기)
  final bool Function()? waitForPage;

  /// 넘긴 뒤 새 쪽 그림을 찍기 전에 기다릴 일 (문서: 새 쪽이 다 그려졌다는 알림)
  final Future<void> Function()? beforeAfterCapture;

  /// 있으면 '실제 화면 비침' 방식: 들린 자리에 새 쪽 그림을 찍어 붙이지 않고, 넘겨 둔 실제 화면이
  /// 그대로 비쳐 보이게 함 (찍는 동안 화면이 멈추지 않아 부드럽고 바로 보임).
  /// 이 기다림이 끝나면(새 쪽이 다 그려짐) 비치기 시작함. 그 전에는 종이색
  final Future<void> Function()? liveReady;

  /// 되돌아오기(한 쪽 보기, 이전 쪽)를 시작할 때 이전 쪽 그림이 이미 있으면 줌 (바로 그려 글이 깜빡이지 않게)
  final ui.Image? Function()? reverseFront;

  /// 다 넘어감: (방향, 떠나온 쪽 그림 — 받은 쪽이 dispose)
  final void Function(int dir, ui.Image left)? onCommitted;

  /// 지금 쪽 종이 색 (넘기기 그림에서 알아냄). 종이 뒷면을 이 색으로 칠할 수 있음
  Color? paperTone;

  /// 종이 색을 알아낼지 (종이 뒷면을 쪽의 종이 색으로 칠하는 화면만)
  bool wantPaperTone = false;

  /// 넘겨 둔 실제 화면이 다 그려져 비쳐 보여도 됨
  final ValueNotifier<bool> live = ValueNotifier<bool>(false);
  Completer<void>? _liveDone;

  /// 그림이 한 가지 색뿐인지 (아직 그려지지 않은 빈 화면: 검정·흰색·종이색)
  /// 글자가 적은 쪽도 빈 화면으로 잘못 보지 않도록 점을 흐리게 하지 않고 그대로 뽑아
  /// 바탕색과 확실히 다른 점이 몇 개라도 있으면 그려진 화면으로 봄
  static Future<bool> looksBlank(ui.Image img) async {
    try {
      // 긴 쪽 256점 (약 10화소마다 한 점): 가는 글자·밑줄도 놓치지 않을 만큼 촘촘하게
      final double longSide = math.max(img.width, img.height).toDouble();
      final int nw = math.max(8, (img.width / longSide * 256).round());
      final int nh = math.max(8, (img.height / longSide * 256).round());
      final rec = ui.PictureRecorder();
      Canvas(rec).drawImageRect(img, Rect.fromLTWH(0, 0, img.width.toDouble(), img.height.toDouble()),
          Rect.fromLTWH(0, 0, nw.toDouble(), nh.toDouble()), Paint()..filterQuality = FilterQuality.none);
      final small = await rec.endRecording().toImage(nw, nh);
      final data = await small.toByteData(format: ui.ImageByteFormat.rawRgba);
      small.dispose();
      if (data == null) return false;
      final int px = nw * nh;
      // 바탕색: 고르게 뽑은 점들에서 가장 흔한 밝기
      final Map<int, int> votes = {};
      for (int i = 0; i < px; i += 61) {
        final int l = _lum(data, i) >> 3;
        votes[l] = (votes[l] ?? 0) + 1;
      }
      int base = 0, best = -1;
      votes.forEach((k, v) {
        if (v > best) {
          best = v;
          base = k;
        }
      });
      final int baseLum = base * 8 + 4;
      int differ = 0;
      for (int i = 0; i < px; i++) {
        if ((_lum(data, i) - baseLum).abs() > 28) {
          differ++;
          if (differ > 12) return false;
        }
      }
      return true;
    } catch (_) {
      return false;
    }
  }

  /// 종이 색: 쪽 가장자리 쪽에서 가장 흔한 색 (흰 종이·검은 종이·누런 종이 등)
  static Future<Color?> paperToneOf(ui.Image img, Rect region) async {
    try {
      const int n = 48;
      final Rect src = region.intersect(Rect.fromLTWH(0, 0, img.width.toDouble(), img.height.toDouble()));
      if (src.width < 8 || src.height < 8) return null;
      final rec = ui.PictureRecorder();
      Canvas(rec).drawImageRect(img, src, const Rect.fromLTWH(0, 0, n + 0.0, n + 0.0), Paint()..filterQuality = FilterQuality.none);
      final small = await rec.endRecording().toImage(n, n);
      final data = await small.toByteData(format: ui.ImageByteFormat.rawRgba);
      small.dispose();
      if (data == null) return null;
      final Map<int, int> votes = {};
      final Map<int, List<int>> sums = {};
      for (int y = 0; y < n; y++) {
        for (int x = 0; x < n; x++) {
          // 가장자리 띠(바깥 1/6)만: 글·그림보다 종이 바탕이 많은 곳
          if (x > n ~/ 6 && x < n - n ~/ 6 && y > n ~/ 6 && y < n - n ~/ 6) continue;
          final int o = (y * n + x) * 4;
          final int r = data.getUint8(o), g = data.getUint8(o + 1), b = data.getUint8(o + 2);
          final int k = ((r >> 4) << 8) | ((g >> 4) << 4) | (b >> 4);
          votes[k] = (votes[k] ?? 0) + 1;
          final sm = sums.putIfAbsent(k, () => [0, 0, 0]);
          sm[0] += r;
          sm[1] += g;
          sm[2] += b;
        }
      }
      int best = -1, bestK = 0;
      votes.forEach((k, v) {
        if (v > best) {
          best = v;
          bestK = k;
        }
      });
      if (best <= 0) return null;
      final sm = sums[bestK]!;
      return Color.fromARGB(255, sm[0] ~/ best, sm[1] ~/ best, sm[2] ~/ best);
    } catch (_) {
      return null;
    }
  }

  static int _lum(ByteData d, int i) {
    final int o = i * 4;
    return (77 * d.getUint8(o) + 150 * d.getUint8(o + 1) + 29 * d.getUint8(o + 2)) >> 8;
  }

  /// 빈 화면이 찍히면 조금 기다렸다가 다시 찍음 (최대 [tries]번). 끝까지 비면 마지막 것을 그대로 씀
  Future<ui.Image?> _captureSolid({int tries = 3, int gapMs = 80}) async {
    ui.Image? img;
    for (int i = 0; i < tries; i++) {
      img?.dispose();
      img = await capture();
      if (img == null || !await looksBlank(img)) return img;
      await Future<void>.delayed(Duration(milliseconds: gapMs));
    }
    return img;
  }

  /// 넘어가는 종이 자리 (층 기준 좌표). 모르면 null → 화면 전체(두 쪽 보기는 절반)를 종이로 봄
  final Future<BookPaper?> Function(bool spread, bool fromRight, Size size)? paperOf;

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

  /// 한 쪽 보기에서 이전 쪽으로: 밖으로 나갔던 이전 쪽이 다시 말려 들어와 덮음
  /// (넘어가는 종이 = 이전 쪽(새로 찍은 그림), 드러나는 자리 = 지금 쪽). [fromRight]는 그 종이의 모서리 쪽
  bool reverse = false;

  /// 손가락이 왼쪽으로 밀었는지 (오른쪽 모서리를 잡고 넘김)
  bool _swipeLeft = true;
  bool bottom = true;
  bool spread = true;
  Offset point = Offset.zero;
  Size size = Size.zero;

  /// 지금 넘어가는 종이 자리
  BookPaper paper = const BookPaper(Rect.zero, 0);

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

  /// 기본 종이 자리: 두 쪽 보기는 화면 절반(책등은 가운데), 한 쪽 보기는 화면 전체(책등은 반대편 끝)
  static BookPaper defaultPaper(bool spread, bool fromRight, Size size) {
    final double w = size.width, h = size.height;
    if (!spread) return BookPaper(Offset.zero & size, fromRight ? 0.0 : w);
    return BookPaper(fromRight ? Rect.fromLTRB(w / 2, 0, w, h) : Rect.fromLTRB(0, 0, w / 2, h), w / 2);
  }

  double get _sx => paper.spine;
  double get _pw => (corner.dx - _sx).abs();
  Offset get corner => Offset(fromRight ? paper.page.right : paper.page.left, bottom ? paper.page.bottom : paper.page.top);
  Offset get _target => Offset(2 * _sx - corner.dx, corner.dy);

  /// 책등에 붙은 종이가 갈 수 있는 곳으로 모서리 위치를 제한
  Offset _constrain(Offset q) {
    final Rect pg = paper.page;
    final double h = pg.height;
    final Offset a1 = Offset(_sx, corner.dy);
    Offset d = q - a1;
    if (d.distance > _pw) q = a1 + d / d.distance * _pw;
    final Offset a2 = Offset(_sx, bottom ? pg.top : pg.bottom);
    final double r2 = math.sqrt(_pw * _pw + h * h);
    d = q - a2;
    if (d.distance > r2) q = a2 + d / d.distance * r2;
    final double y = bottom ? math.min(q.dy, pg.bottom) : math.max(q.dy, pg.top);
    return Offset(q.dx, y);
  }

  double _progressOf(double x) => ((corner.dx - x) / (corner.dx - _target.dx)).clamp(0.0, 1.0);

  /// 손가락 위치 → 말려 올라간 모서리 위치
  Offset _fingerToPoint(Offset f) {
    final Offset c = corner, t = _target;
    // 손가락이 화면 반대편 끝에 닿으면 다 넘어가도록 (모서리 가까이에서 잡으면 거의 손가락 그대로)
    // 되돌아오기: 다 나가 있던 자리에서 손가락을 따라 모서리 쪽으로 들어옴
    final double far = reverse ? (fromRight ? size.width : 0.0) : (fromRight ? 0.0 : size.width);
    final double span = math.max((_start.dx - far).abs(), _pw * 0.5);
    final double gain = ((c.dx - t.dx).abs() / span).clamp(1.0, 2.6);
    double x = (reverse ? t.dx : c.dx) + (f.dx - _start.dx) * gain;
    x = fromRight ? x.clamp(t.dx, c.dx) : x.clamp(c.dx, t.dx);
    final double p = _progressOf(x);
    // 똑바로 밀어도 모서리가 살짝 들려 비스듬히 말리도록
    final double lift = paper.page.height * (spread ? 0.14 : 0.10) * math.sin(math.pi * p);
    final double y = c.dy + (f.dy - _start.dy) + (bottom ? -lift : lift);
    return _constrain(Offset(x, y));
  }

  /// 손가락이 가로로 끌리기 시작함. [pre]: 손가락이 닿을 때 미리 찍어 둔 그림 (넘겨받아 정리까지 맡음)
  Future<void> begin(Offset globalStart, Offset globalNow, Future<ui.Image?>? pre, {bool spread = true}) async {
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
    _swipeLeft = right;
    // 한 쪽 보기에서 이전 쪽으로 가면: 나갔던 종이가 되돌아오는 모양 (모서리는 손가락이 가는 쪽)
    reverse = !spread && dir < 0;
    fromRight = reverse ? !right : right;
    this.spread = spread;
    _startTime = DateTime.now();
    _start = _toLocal(globalStart);
    _finger = _toLocal(globalNow);
    paper = defaultPaper(spread, fromRight, size);
    bottom = _start.dy > paper.page.center.dy;
    // 실제 종이 자리 (빈 여백은 넘어가지 않게). 그림을 찍는 동안 함께 알아봄
    final Future<BookPaper?>? paperAsk = paperOf?.call(spread, fromRight, size).catchError((_) => null);

    ui.Image? img = pre == null ? null : await pre;
    // 미리 찍은 그림이 빈 화면(아직 그려지기 전)이면 다시 찍음
    if (img != null && await looksBlank(img)) {
      img.dispose();
      img = null;
    }
    img ??= await _captureSolid();
    final BookPaper? found = paperAsk == null ? null : await paperAsk;
    if (gen != _gen) {
      img?.dispose();
      return;
    }
    if (found != null && found.page.width > 20 && found.page.height > 20) {
      paper = found;
      bottom = _start.dy > paper.page.center.dy;
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
    // 되돌아오기: 들어올 이전 쪽 그림이 있으면 첫 장면부터 함께 (종이만 보였다가 글이 나타나는 깜빡임 없게)
    if (reverse) {
      final ui.Image? f = reverseFront?.call();
      if (f != null) {
        final old = after.value;
        after.value = f;
        old?.dispose();
      }
    }
    image = img;
    // 종이 색은 넘기기를 늦추지 않도록 따로 알아내 오는 대로 씀
    // (그림은 실제 화소 크기라 층 좌표의 종이 자리를 그림 좌표로 바꿔서)
    paperTone = null;
    if (wantPaperTone) {
      final double sx = size.width > 0 ? img.width / size.width : 1, sy = size.height > 0 ? img.height / size.height : 1;
      paperToneOf(img, Rect.fromLTRB(paper.page.left * sx, paper.page.top * sy, paper.page.right * sx, paper.page.bottom * sy)).then((c) {
        if (gen != _gen || c == null) return;
        paperTone = c;
        notifyListeners();
      });
    }
    point = _released == null ? _dragPoint() : (reverse ? _target : corner);
    if (_released == null) _phase = _BookPhase.dragging;
    notifyListeners();
    await SchedulerBinding.instance.endOfFrame;
    if (gen != _gen) return;
    // 덮개(넘기기 전 그림)를 씌운 채로 실제 화면을 넘겨 둠 → 들린 자리에 새 쪽이 드러남
    _afterReady = Completer<void>();
    _liveDone = Completer<void>();
    live.value = false;
    _turning = turn(dir);
    // 그림이 준비되기 전에 이미 손을 뗐으면 바로 마무리 움직임 시작
    if (_released != null && _phase == _BookPhase.waiting) _settle(_released!);
    final bool turned = await _turning!;
    if (gen != _gen) return;
    if (turned && liveReady != null) {
      // 실제 화면 비침: 새 쪽이 다 그려지면 들린 자리로 실제 화면이 보임
      try {
        await liveReady!().timeout(const Duration(milliseconds: 1500));
      } catch (_) {}
      if (gen != _gen) return;
      live.value = true;
      if (!(_liveDone?.isCompleted ?? true)) _liveDone!.complete();
      _frontArrived();
      // 한 쪽 보기는 새 쪽 그림이 필요 없음 (뒷면은 종이). 두 쪽 보기만 넘어가는 장 뒷면에 쓸 그림을 찍음
      if (!spread) {
        if (!(_afterReady?.isCompleted ?? true)) _afterReady!.complete();
        return;
      }
    }
    if (!(_liveDone?.isCompleted ?? true)) _liveDone!.complete();
    if (turned) {
      // 넘긴 뒤 새 쪽 그림: 들린 자리와(두 쪽 보기는) 넘어가는 장 뒷면에 씀.
      // 새 쪽이 다 그려지길 기다린 뒤 찍고, 빈 화면(검정·흰색)이 찍히면 버리고 다시 찍음 (아직 없으면 종이색으로 보임)
      if (liveReady == null) {
        try {
          await (beforeAfterCapture?.call() ?? Future<void>.value()).timeout(const Duration(milliseconds: 1500));
        } catch (_) {}
      }
      if (gen != _gen || image == null) return;
      bool good = false;
      ui.Image? lastBlank;
      for (final int wait in const [0, 60, 120, 180, 260, 360]) {
        if (wait > 0) await Future<void>.delayed(Duration(milliseconds: wait));
        if (gen != _gen || image == null) {
          lastBlank?.dispose();
          return;
        }
        await SchedulerBinding.instance.endOfFrame;
        final a = await capture();
        if (a == null) continue;
        if (await looksBlank(a)) {
          if (good) {
            a.dispose();
            break;
          }
          // 정말 빈 쪽일 수도 있어 마지막 것은 남겨 둠
          lastBlank?.dispose();
          lastBlank = a;
          continue;
        }
        lastBlank?.dispose();
        lastBlank = null;
        if (gen == _gen && image != null) {
          final old = after.value;
          after.value = a;
          old?.dispose();
          _frontArrived();
        } else {
          a.dispose();
          return;
        }
        if (!(_afterReady?.isCompleted ?? true)) _afterReady!.complete();
        // 늦게 그려지는 그림이 있을 수 있어 손가락으로 끄는 중일 때만 한 번 더 찍어 바꿔 끼움 (넘어가는 움직임 중엔 찍지 않아 끊김 없음)
        if (good || _phase != _BookPhase.dragging) break;
        good = true;
      }
      if (lastBlank != null) {
        if (gen == _gen && image != null && after.value == null) {
          after.value = lastBlank;
        } else {
          lastBlank.dispose();
        }
      }
    }
    if (!(_afterReady?.isCompleted ?? true)) _afterReady!.complete();
  }

  /// 새 쪽이 다 그려졌을 즈음(두 번째로 찍은 뒤) 끝나는 기다림. [waitForPage]일 때 마무리 전에 기다림
  Completer<void>? _afterReady;

  /// 손가락이 움직임
  /// 되돌아오기에서 들어올 이전 쪽이 아직 준비되지 않았으면 다 나가 있는 자리에 붙잡아 둠
  /// (빈 종이가 먼저 보였다가 글이 나타나는 깜빡임 없게)
  bool get _frontPending => reverse && after.value == null && !live.value;

  Offset _dragPoint() => _frontPending ? _target : _fingerToPoint(_finger);

  /// 이전 쪽이 준비됨: 붙잡아 둔 종이를 손가락 자리로
  void _frontArrived() {
    if (_phase == _BookPhase.dragging && reverse) {
      point = _dragPoint();
      notifyListeners();
    }
  }

  void update(Offset global) {
    if (!tracking) return;
    _finger = _toLocal(global);
    if (_phase == _BookPhase.dragging) {
      point = _dragPoint();
      notifyListeners();
    }
  }

  /// 손을 뗌. [cancel]이면 무조건 되돌림
  void end({bool cancel = false}) {
    if (!tracking) return;
    bool commit = false;
    if (!cancel) {
      final double moved = (_finger.dx - _start.dx) * (_swipeLeft ? -1 : 1);
      final int ms = DateTime.now().difference(_startTime).inMilliseconds;
      final bool flick = ms < 350 && moved > 30;
      final double p = image == null ? 0 : (reverse ? 1 - _progressOf(point.dx) : _progressOf(point.dx));
      commit = flick || p > 0.3;
    }
    _released = commit;
    if (image == null) return; // 그림이 준비되면 begin()에서 이어서 마무리
    _settle(commit);
  }

  /// 손가락 없이 한 번에 넘김 (끌기가 시작되지 않은 빠른 밀기)
  void autoTurn(double dx, Future<ui.Image?>? pre, Offset globalStart, {bool spread = true}) {
    begin(globalStart, globalStart + Offset(dx.sign * 20, 0), pre, spread: spread); // 첫 기다림 전까지는 바로 실행됨
    if (tracking && image == null) _released = true;
  }

  Future<void> _settle(bool commit) async {
    final int gen = _gen;
    _phase = _BookPhase.settling;
    // 되돌아오기를 다 넘기는데 이전 쪽이 아직 준비 안 됨: 준비될 때까지 기다렸다가 들어옴 (깜빡임 없게)
    if (commit && _frontPending) {
      final Future<void>? wait = liveReady != null ? _liveDone?.future : _afterReady?.future;
      await (wait ?? Future<void>.value()).timeout(const Duration(milliseconds: 1200), onTimeout: () {});
      if (gen != _gen) return;
    }
    _from = point;
    // 되돌아오기는 '넘김'이 모서리까지 덮는 것, '취소'가 다시 밖으로 나가는 것
    final Offset done = reverse ? corner : _target, undo = reverse ? _target : corner;
    _to = commit ? done : undo;
    final double dist = (_to.dx - _from.dx).abs() / math.max(1.0, (corner.dx - _target.dx).abs());
    _anim.duration = Duration(milliseconds: (160 + 380 * dist).round()); // '애니메이션 끄기'와 상관없이 움직임
    _anim.value = 0;
    await _anim.animateTo(1, curve: Curves.easeOutCubic);
    if (gen != _gen) return;
    final bool turned = await (_turning ?? Future<bool>.value(false));
    if (gen != _gen) return;
    if (commit && turned && (waitForPage?.call() ?? false)) {
      // 실제 화면 비침이면 새 쪽이 다 그려졌는지만, 아니면 새 쪽 그림을 찍을 때까지 기다림
      final Future<void>? wait = liveReady != null ? _liveDone?.future : _afterReady?.future;
      await (wait ?? Future<void>.value()).timeout(const Duration(milliseconds: 1200), onTimeout: () {});
      if (gen != _gen) return;
    }
    if (commit && !turned) {
      // 넘길 쪽이 없었음: 제자리로 되돌림
      _from = point;
      _to = undo;
      _anim.duration = const Duration(milliseconds: 320);
      _anim.value = 0;
      await _anim.animateTo(1, curve: Curves.easeOutCubic);
      if (gen != _gen) return;
    } else if (!commit && turned) {
      // 되돌림: 덮개가 다 덮은 상태에서 실제 화면도 원래 쪽으로
      await turn(-_dir);
      if (gen != _gen) return;
      await SchedulerBinding.instance.endOfFrame;
    }
    if (commit && turned && image != null) onCommitted?.call(_dir, image!.clone());
    _clear();
  }

  void _onTick() {
    if (_phase != _BookPhase.settling) return;
    final double e = _anim.value;
    final Offset q = Offset.lerp(_from, _to, e)!;
    // 넘어가는 동안 모서리가 살짝 들렸다가 내려앉음
    final double span = (_to.dx - _from.dx).abs() / math.max(1.0, (corner.dx - _target.dx).abs());
    final double lift = paper.page.height * 0.10 * span * math.sin(math.pi * e);
    point = _constrain(q + Offset(0, bottom ? -lift : lift));
    notifyListeners();
  }

  void _clear() {
    _gen++;
    _anim.stop();
    _phase = _BookPhase.idle;
    _released = null;
    _turning = null;
    live.value = false;
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
    live.dispose();
    super.dispose();
  }
}

/// 화면 위에 깔리는 책처럼 넘기기 층 (넘기지 않을 때는 아무것도 그리지 않음)
class BookCurlLayer extends StatelessWidget {
  BookCurlLayer({required this.drag, this.paper, this.texture, this.backside, this.textureKey, this.backsideFromPaper = false, this.keepOverlay = false}) : super(key: drag.layerKey);

  /// 문서 화면(WebView) 위: 넘기지 않을 때도 눈에 보이지 않는 막을 한 겹 깔아 둠.
  /// 넘김이 끝나 이 층이 통째로 사라지는 순간 안드로이드가 WebView를 한두 장면 숨겨
  /// 화면이 하얗게 번쩍이는 것을 막음 (덮개 층이 생겼다 없어졌다 하지 않게)
  final bool keepOverlay;

  /// 한 쪽 보기 종이 뒷면을 쪽의 종이 색(흰색·검은색·누런색 등)으로 (앱 테마와 상관없이)
  final bool backsideFromPaper;

  /// 종이 질감이 실제로 깔린 화면(이 층보다 넓을 수 있음). 질감을 그 자리에 맞춰 그려 넘길 때 무늬가 어긋나지 않게
  final GlobalKey? textureKey;

  final BookCurlDrag drag;
  final Color? paper;

  /// 한 쪽 보기에서 넘어가는 종이 뒷면 색 (없으면 종이 질감 또는 [paper])
  final Color? backside;

  /// 종이 질감 배경 (종이색 테마): 찍은 그림의 빈 곳 밑에 깔아 넘기는 종이가 비쳐 보이지 않게
  final ui.Image? texture;

  static ui.Image? _paper;
  static Future<ui.Image?>? _paperLoading;

  /// 종이 질감 그림 (한 번만 읽어 둠)
  static ui.Image? paperTexture(VoidCallback onReady) {
    if (_paper != null) return _paper;
    _paperLoading ??= () async {
      try {
        final data = await rootBundle.load('assets/textures/paper.jpg');
        final codec = await ui.instantiateImageCodec(data.buffer.asUint8List(), targetWidth: 1080);
        _paper = (await codec.getNextFrame()).image;
      } catch (_) {}
      return _paper;
    }();
    _paperLoading!.then((_) => onReady());
    return null;
  }

  @override
  Widget build(BuildContext context) {
    final Color back = paper ?? (Theme.of(context).brightness == Brightness.dark ? const Color(0xFF2A2A2C) : const Color(0xFFF7F5F0));
    return IgnorePointer(
      child: ListenableBuilder(
        listenable: Listenable.merge([drag, drag.after, drag.live]),
        builder: (context, _) {
          final img = drag.image;
          if (img == null) {
            return keepOverlay ? const ColoredBox(color: Color(0x01000000), child: SizedBox.expand()) : const SizedBox.expand();
          }
          Rect? groundRect;
          if (texture != null && textureKey != null) {
            final lb = drag.layerKey.currentContext?.findRenderObject() as RenderBox?;
            final gb = textureKey!.currentContext?.findRenderObject() as RenderBox?;
            if (lb != null && gb != null && lb.attached && gb.attached && lb.hasSize && gb.hasSize) {
              groundRect = lb.globalToLocal(gb.localToGlobal(Offset.zero)) & gb.size;
            }
          }
          return CustomPaint(
            size: Size.infinite,
            painter: BookCurlPainter(image: img, after: drag.after.value, point: drag.point, fromRight: drag.fromRight, bottom: drag.bottom, back: back, spread: drag.spread, ground: texture, paper: drag.paper, reverse: drag.reverse, backside: backsideFromPaper ? (drag.paperTone ?? Colors.white) : backside, groundRect: groundRect, live: drag.live.value),
          );
        },
      ),
    );
  }
}

/// 책 넘김 그림: [point]는 들려 올라간 모서리가 지금 있는 곳
/// 접힌 선은 원래 모서리와 [point]를 잇는 선의 수직이등분선. 그 바깥 부분이 뒤집혀 넘어감
class BookCurlPainter extends CustomPainter {
  BookCurlPainter({required this.image, required this.after, required this.point, required this.fromRight, required this.bottom, required this.back, this.spread = true, this.ground, this.paper, this.reverse = false, this.backside, this.groundRect, this.live = false});

  /// 넘겨 둔 실제 화면이 다 그려짐: 넘긴 뒤 보일 자리는 칠하지 않고 비워 실제 화면이 보이게
  final bool live;

  /// 종이 질감을 깔 자리 (층 기준). 실제 화면의 질감과 같은 자리·크기로 그려 무늬가 이어지게
  final Rect? groundRect;

  /// 되돌아오기(한 쪽 보기에서 이전 쪽): 넘어가는 종이 = [after](이전 쪽), 드러나는 자리 = [image](지금 쪽)
  final bool reverse;

  /// 한 쪽 보기 종이 뒷면 색 (없으면 종이 질감 또는 [back])
  final Color? backside;

  /// 넘어가는 종이 자리 (없으면 화면 전체, 두 쪽 보기는 절반)
  final BookPaper? paper;

  /// 찍은 그림 밑에 까는 바탕 그림 (종이 질감). 없으면 [back] 색으로 칠함
  final ui.Image? ground;

  /// 찍은 그림의 빈(투명한) 곳으로 아래 화면이 비치지 않게 바탕을 먼저 깔아 둠
  void _ground(Canvas canvas, Rect r) {
    final g = ground;
    if (g == null) {
      canvas.drawRect(r, Paint()..color = back.withValues(alpha: 1));
      return;
    }
    final Size gs = Size(g.width.toDouble(), g.height.toDouble());
    final Rect dst = groundRect ?? r;
    final fit = applyBoxFit(BoxFit.cover, gs, dst.size);
    canvas.save();
    canvas.clipRect(r);
    canvas.drawImageRect(g, Alignment.center.inscribe(fit.source, Offset.zero & gs), dst, Paint()..filterQuality = FilterQuality.low);
    canvas.restore();
  }

  /// 종이 뒷면 바탕: 정한 색이 있으면 그 색, 없으면 종이 질감(세피아) 또는 종이색
  void _backBase(Canvas canvas, Rect r) {
    final Color? b = backside;
    if (b != null) {
      canvas.drawRect(r, Paint()..color = b.withValues(alpha: 1));
    } else {
      _ground(canvas, r);
    }
  }

  /// 두 쪽 보기(책등이 가운데)인지, 한 쪽 보기(책등이 화면 끝)인지
  final bool spread;

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
    final BookPaper pp = (paper != null && !paper!.page.isEmpty) ? paper! : BookCurlDrag.defaultPaper(spread, fromRight, size);
    final double sx = pp.spine;
    final double w = size.width, h = size.height;
    final Rect full = Offset.zero & size;
    // 화면 그림의 맨 아래 한두 줄이 어둡게 찍히는 기기가 있어(아래 검은 줄) 살짝 잘라 씀
    Rect srcOf(ui.Image im) => Rect.fromLTWH(0, 0, im.width.toDouble(), math.max(1.0, im.height - 2.0));
    // 잘라 낸 만큼 그리는 자리도 줄여 늘리지 않음 (조금이라도 늘이면 글씨가 흐려 보임)
    Rect dstOf(ui.Image im) => Rect.fromLTWH(0, 0, size.width, size.height * math.max(1.0, im.height - 2.0) / im.height);
    final paint = Paint()..filterQuality = FilterQuality.medium;
    // 반듯하게 놓이는 그림(아직 안 넘어간 부분·드러나는 쪽)은 화면 화소와 1:1이면 보간 없이 그려 글씨가 흐려지지 않게
    final double dpr = ui.PlatformDispatcher.instance.views.isEmpty ? 1.0 : ui.PlatformDispatcher.instance.views.first.devicePixelRatio;
    final Paint crisp = Paint()..filterQuality = FilterQuality.none;
    Paint flat(ui.Image im) => (im.width - size.width * dpr).abs() < 2.5 ? crisp : paint;
    final Rect page = pp.page;
    // 넘어가는 종이(앞면)와 그 밑에서 드러나는 쪽
    final ui.Image? front = reverse ? after : image;
    final ui.Image? revealed = reverse ? image : after;
    void drawFront(Canvas cv) {
      final f = front;
      if (f != null) {
        cv.drawImageRect(f, srcOf(f), dstOf(f), flat(f));
      } else {
        // 이전 쪽 그림이 아직 없음: 종이만
        cv.save();
        cv.clipRect(page);
        _backBase(cv, full);
        cv.restore();
      }
    }

    final Offset c0 = Offset(fromRight ? page.right : page.left, bottom ? page.bottom : page.top);
    final Offset v = c0 - point;
    final double len = v.distance;
    if (len < 0.5) {
      _ground(canvas, full);
      if (reverse) canvas.drawImageRect(image, srcOf(image), dstOf(image), flat(image));
      drawFront(canvas);
      return;
    }
    final Offset n = v / len; // 모서리 쪽을 가리킴
    final Offset mid = (c0 + point) / 2;
    final double c = n.dx * mid.dx + n.dy * mid.dy;
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
    if (!reverse) {
      _ground(canvas, full);
      canvas.drawImageRect(image, srcOf(image), dstOf(image), flat(image));
    } else {
      // 되돌아오기: 종이 밖 여백은 지금 화면 그대로, 종이 자리는 들어오는 이전 쪽
      // (실제 화면이 이미 이전 쪽으로 넘어가 다 그려졌으면 그대로 비쳐 보이게 비워 둠)
      canvas.save();
      canvas.clipPath(Path.combine(PathOperation.difference, Path()..addRect(full), Path()..addRect(page)));
      _ground(canvas, full);
      canvas.drawImageRect(image, srcOf(image), dstOf(image), flat(image));
      canvas.restore();
      // 이전 쪽 그림이 있으면 그것을 (실제 화면이 바뀌는 순간의 깜빡임 없이), 없으면 다 그려진 실제 화면이 비치게
      if (!live || front != null) {
        canvas.clipRect(page);
        _ground(canvas, full);
        drawFront(canvas);
      }
    }
    canvas.restore();

    // 2) 들린 자리: 넘긴 뒤 찍은 새 쪽 그림(아직 없으면 종이색). 실제 화면은 비치지 않게 함
    //    (EPUB은 장이 바뀌는 동안 실제 화면이 잠깐 비어 검게 보일 수 있음)
    {
      final Offset p0 = n * c;
      final double sw = math.min(56.0, math.max(14.0, len * 0.35));
      canvas.save();
      canvas.clipPath(flapLeaf);
      // 넘기기: 실제 화면(새 쪽)이 다 그려졌으면 비워 두어 그대로 보이게
      if (reverse || !live) {
        final na = revealed;
        if (na != null) {
          _ground(canvas, full); // 종이 질감(세피아): 새 쪽 그림의 투명한 곳 밑에도 깔림
          canvas.drawImageRect(na, srcOf(na), dstOf(na), flat(na));
        } else {
          // 새 쪽이 아직 그려지는 중: 빈 종이 (문서는 흰 종이, EPUB은 보는 바탕색·종이 질감)
          _backBase(canvas, full);
        }
      }
      canvas.drawRect(page, Paint()..shader = ui.Gradient.linear(p0, p0 + n * sw, [k(0x59000000), const Color(0x00000000)]));
      if (spread) canvas.drawRect(
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
    final a = spread ? after : null;
    if (a != null) {
      // 뒷면 = 넘긴 뒤 반대편에 오는 새 쪽. 책등을 기준으로 한 번 더 뒤집어 그리면 제자리에 바로 놓임
      final Float64List mirror = Float64List(16)
        ..[0] = -1
        ..[5] = 1
        ..[10] = 1
        ..[12] = 2 * sx
        ..[15] = 1;
      canvas.transform(mirror);
      _ground(canvas, full);
      canvas.drawImageRect(a, srcOf(a), dstOf(a), paint);
    } else {
      // 한 쪽 보기 종이 뒷면: 흰 종이(또는 세피아 종이 질감) 위로 앞면 글자가 흐리게 비침
      _backBase(canvas, full);
      final f = front;
      if (f != null) {
        canvas.drawImageRect(f, srcOf(f), dstOf(f), Paint()
          ..filterQuality = FilterQuality.medium
          ..color = const Color(0x1F000000));
      }
    }
    canvas.restore();

    // 4) 둥글게 말린 느낌: 접힌 선 쪽이 어둡다가 밝게 빛나고 바깥으로 갈수록 살짝 어두워짐
    {
      final Offset p0 = n * c;
      final double cw = math.min((c0.dx - sx).abs() * 0.9, math.max(24.0, len * 0.55));
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

  @override
  bool shouldRepaint(covariant BookCurlPainter old) =>
      old.point != point || old.image != image || old.after != after || old.fromRight != fromRight || old.bottom != bottom || old.back != back || old.spread != spread || old.ground != ground || old.paper?.page != paper?.page || old.paper?.spine != paper?.spine || old.reverse != reverse || old.backside != backside || old.groundRect != groundRect || old.live != live;
}
