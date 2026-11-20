import 'dart:async';
import 'dart:io';
import 'dart:math' as math;
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';

import 'app_colors.dart';

import '../services/storage_service.dart';
import 'pop_dialog.dart';
import 'bar_drag.dart';

typedef MemoTr = String Function(String ko, String en, String zh, String ja);

// ─────────────────────────────────────────────────────────────────────────────
// 되돌리기 / 다시 실행 기록
// 페이지(또는 EPUB 위치)별로 '바뀌기 전 필기'를 저장해 두고 순서대로 되돌린다.
class MemoHistory {
  static const int _maxDepth = 60;
  final Map<Object, List<_HistoryEntry>> _undo = {};
  final Map<Object, List<_HistoryEntry>> _redo = {};
  int _seq = 0;

  /// 필기가 바뀌기 직전의 상태를 기록 (새 동작이 생기면 다시 실행 기록은 사라짐)
  void record(Object key, List<MemoStroke> before) {
    final stack = _undo.putIfAbsent(key, () => []);
    stack.add(_HistoryEntry(++_seq, List<MemoStroke>.unmodifiable(before)));
    if (stack.length > _maxDepth) stack.removeAt(0);
    _redo.remove(key);
  }

  bool canUndo(Iterable<Object> keys) => keys.any((k) => _undo[k]?.isNotEmpty ?? false);
  bool canRedo(Iterable<Object> keys) => keys.any((k) => _redo[k]?.isNotEmpty ?? false);

  /// 보이는 페이지들 중 가장 최근에 바뀐 곳을 되돌린다. 반환: (페이지 키, 되돌린 필기)
  (Object, List<MemoStroke>)? undo(Iterable<Object> keys, List<MemoStroke> Function(Object key) current) {
    final key = _latest(_undo, keys);
    if (key == null) return null;
    final entry = _undo[key]!.removeLast();
    _redo.putIfAbsent(key, () => []).add(_HistoryEntry(++_seq, List<MemoStroke>.unmodifiable(current(key))));
    return (key, entry.strokes);
  }

  /// 가장 최근에 되돌린 것을 다시 실행한다.
  (Object, List<MemoStroke>)? redo(Iterable<Object> keys, List<MemoStroke> Function(Object key) current) {
    final key = _latest(_redo, keys);
    if (key == null) return null;
    final entry = _redo[key]!.removeLast();
    _undo.putIfAbsent(key, () => []).add(_HistoryEntry(++_seq, List<MemoStroke>.unmodifiable(current(key))));
    return (key, entry.strokes);
  }

  Object? _latest(Map<Object, List<_HistoryEntry>> map, Iterable<Object> keys) {
    Object? best;
    int bestSeq = -1;
    for (final k in keys) {
      final s = map[k];
      if (s == null || s.isEmpty) continue;
      if (s.last.seq > bestSeq) {
        bestSeq = s.last.seq;
        best = k;
      }
    }
    return best;
  }
}

class _HistoryEntry {
  _HistoryEntry(this.seq, this.strokes);
  final int seq;
  final List<MemoStroke> strokes;
}

// ─────────────────────────────────────────────────────────────────────────────
// 메모바 아이콘 버튼 (누르기 + 꾹 누르기)
/// 메모 도구모음의 모든 도구가 쓰는 같은 크기의 칸 (간격을 똑같이 맞추기 위함)
const double kMemoToolExtent = 40.0;

class MemoToolButton extends StatelessWidget {
  const MemoToolButton({
    super.key,
    this.icon,
    this.iconBuilder,
    required this.label,
    this.onTap,
    this.onReselect,
    this.active = false,
    this.enabled = true,
    this.dotColor,
    this.color,
  });

  final IconData? icon;

  /// 기본 아이콘에 없는 모양(예: 지우개)을 직접 그릴 때 사용
  final Widget Function(Color color)? iconBuilder;
  final String label;
  final VoidCallback? onTap;

  /// 이미 선택된(active) 상태에서 한 번 더 눌렀을 때 (버튼 위치를 기준으로 메뉴를 띄울 수 있도록 context 전달)
  final void Function(BuildContext buttonContext)? onReselect;
  final bool active;
  final bool enabled;

  /// 아이콘 왼쪽 작은 점 (현재 펜 색상 표시)
  final Color? dotColor;

  /// 기본(흰색) 대신 쓸 아이콘 색 (예: 필기 전체 지우기 = 빨강)
  final Color? color;

  @override
  Widget build(BuildContext context) {
    // 고른 도구: 시그니쳐 색 바탕 + 진한 초록 아이콘
    final Color color = !enabled ? Colors.white30 : (active ? AppColors.onSignature : (this.color ?? Colors.white));
    return Semantics(
      button: true,
      label: label,
      child: InkResponse(
        // 고를 때 퍼지는 번짐(그라데이션) 효과 없이
        splashFactory: NoSplash.splashFactory,
        highlightColor: Colors.transparent,
        radius: 18,
        onTap: !enabled
            ? null
            : () {
                if (active && onReselect != null) {
                  onReselect!(context);
                } else {
                  onTap?.call();
                }
              },
        child: SizedBox(
          width: kMemoToolExtent,
          height: kMemoToolExtent,
          child: Stack(
            alignment: Alignment.center,
            children: [
              if (active && enabled)
                AnimatedContainer(
                  duration: Anim.ms(150),
                  width: kMemoToolExtent - 8,
                  height: kMemoToolExtent - 8,
                  decoration: BoxDecoration(color: AppColors.signature, borderRadius: BorderRadius.circular(10)),
                ),
              iconBuilder != null ? iconBuilder!(color) : Icon(icon, color: color, size: 16, shadows: active ? AppColors.sigShadows(context) : null),
              // 펜 색: 펜 몸통 왼쪽에 살짝 띄워서
              if (dotColor != null)
                Positioned(
                  left: 3,
                  child: Container(
                    width: 6,
                    height: 6,
                    decoration: BoxDecoration(
                      color: dotColor,
                      shape: BoxShape.circle,
                      border: Border.all(color: Colors.white70, width: 0.8),
                    ),
                  ),
                ),
            ],
          ),
        ),
      ),
    );
  }
}

/// 메모 도구모음의 '완료' 버튼. 아이콘 칸과 같은 높이·좌우 여백을 써서 간격을 맞춘다.
class MemoDoneButton extends StatelessWidget {
  const MemoDoneButton({super.key, required this.label, required this.onTap});

  final String label;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return Semantics(
      button: true,
      label: label,
      child: InkResponse(
        radius: 18,
        onTap: onTap,
        child: ConstrainedBox(
          constraints: const BoxConstraints(minWidth: kMemoToolExtent, minHeight: kMemoToolExtent),
          child: Padding(
            // 18px 아이콘이 40px 칸 안에서 갖는 좌우 여백(11px)과 같게
            padding: const EdgeInsets.symmetric(horizontal: 11),
            child: Center(
              widthFactor: 1,
              heightFactor: 1,
              child: Text(label, style: const TextStyle(color: Colors.amber, fontSize: 14, fontWeight: FontWeight.w600)),
            ),
          ),
        ),
      ),
    );
  }
}

/// 메모 도구 모음을 길게 눌러 끌어 옮김: 손가락을 따라 움직이다가, 놓으면 가장 가까운 화면 가장자리
/// ('top'·'bottom'·'left'·'right')에 붙음. 지우개처럼 길게 누르기를 따로 쓰는 단추는 그 단추가 먼저 받음
class MemoToolbarMover extends StatefulWidget {
  const MemoToolbarMover({super.key, required this.current, required this.feedback, required this.onDrop, required this.child});
  /// 지금 놓인 가장자리
  final String current;
  /// [side]에 놓였을 때의 모양 (끄는 동안 손가락을 따라 그려짐)
  final Widget Function(String side) feedback;
  final ValueChanged<String> onDrop;
  final Widget child;

  @override
  State<MemoToolbarMover> createState() => _MemoToolbarMoverState();
}

/// 길게 눌러 끌면 손가락을 따라 움직이고, 가장자리 근처에서는 그 자리 모양으로만 바뀜. 놓으면 가장 가까운 가장자리에 자석처럼 붙음
class _MemoToolbarMoverState extends State<MemoToolbarMover> with TickerProviderStateMixin, BarDragMixin<MemoToolbarMover> {
  @override
  List<String> get dragSides => const ['top', 'bottom', 'left', 'right'];
  @override
  String get dragCurrent => widget.current;
  @override
  Widget dragFeedback(String side) => widget.feedback(side);
  @override
  void dragDrop(String side) => widget.onDrop(side);

  @override
  void dispose() {
    disposeBarDrag();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onLongPressStart: (d) => dragStart(d.globalPosition),
      onLongPressMoveUpdate: (d) => dragMove(d.globalPosition),
      onLongPressEnd: (_) => dragEnd(),
      onLongPressCancel: () => dragEnd(cancel: true),
      child: Opacity(opacity: barDragging ? 0.0 : 1.0, child: widget.child),
    );
  }
}

/// 메모 도구모음 바탕. [vertical]이면 세로(왼쪽/오른쪽 배치), 아니면 가로(상단/하단 배치).
class MemoToolbar extends StatelessWidget {
  const MemoToolbar({super.key, required this.children, this.vertical = false});

  final List<Widget> children;
  final bool vertical;

  @override
  Widget build(BuildContext context) {
    return Material(
      color: Colors.black87,
      borderRadius: BorderRadius.circular(24),
      elevation: 6,
      // 아이콘을 누를 때 퍼지는 효과가 도구모음 밖으로 나가지 않게 자름
      clipBehavior: Clip.antiAlias,
      child: Padding(
        padding: vertical ? const EdgeInsets.symmetric(horizontal: 4, vertical: 8) : const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
        child: SingleChildScrollView(
          scrollDirection: vertical ? Axis.vertical : Axis.horizontal,
          child: Flex(
            direction: vertical ? Axis.vertical : Axis.horizontal,
            mainAxisSize: MainAxisSize.min,
            children: children,
          ),
        ),
      ),
    );
  }
}

// ─────────────────────────────────────────────────────────────────────────────
// 메모 도구 설정 (펜·형광펜·테이프·지우개): 모든 파일 보기가 함께 쓰고 앱을 다시 열어도 기억함
/// 펜 색 (맨 앞 빨강이 기본)
const List<Color> kMemoPenColors = [
  Colors.redAccent,
  Colors.amber,
  Colors.lightBlueAccent,
  Colors.greenAccent,
  Colors.white,
  Colors.black,
];

const List<Color> kMemoPenMoreColors = [
  Color(0xFFD50000),
  Color(0xFFFF6D00),
  Color(0xFFFFD600),
  Color(0xFF64DD17),
  Color(0xFF00BFA5),
  Color(0xFF0091EA),
  Color(0xFF2962FF),
  Color(0xFF6200EA),
  Color(0xFFC51162),
  Color(0xFFFF80AB),
  Color(0xFF8D6E63),
  Color(0xFF9E9E9E),
  Color(0xFF455A64),
  Color(0xFF1B5E20),
  Color(0xFF0D47A1),
  Color(0xFF4A148C),
];

/// 형광펜 색 (맨 앞 노랑이 기본)
const List<Color> kMemoHighlighterColors = [
  Color(0xFFFFD60A),
  Color(0xFFFF9F0A),
  Color(0xFFFF6B9A),
  Color(0xFF7EE081),
  Color(0xFF5AC8FA),
  Color(0xFFB98CFF),
];

/// 테이프 색 (맨 앞 주황이 기본)
const List<Color> kMemoTapeColors = [
  Color(0xFFFF7043),
  Color(0xFFFFCA28),
  Color(0xFF9CCC65),
  Color(0xFF4FC3F7),
  Color(0xFFBA68C8),
  Color(0xFFF48FB1),
  Color(0xFFBDBDBD),
  Color(0xFF616161),
];

class MemoToolSettings {
  /// 지금 고른 쓰기 도구: 'pen' · 'hl'(형광펜) · 'tape'
  String tool = 'pen';

  Color penColor = kMemoPenColors.first;
  double penWidth = 2.0;
  bool penStraight = false;

  Color hlColor = kMemoHighlighterColors.first;
  double hlWidth = 16.0;
  int hlOpacity = 45; // %
  bool hlStraight = false;
  bool hlFit = false;

  Color tapeColor = kMemoTapeColors.first;
  double tapeWidth = 22.0;
  bool tapeStraight = false;
  bool tapeFit = false;

  /// 테이프 숨기기: 테이프는 테두리만 남고 안쪽은 비쳐 보임
  bool tapeHidden = false;

  /// 지우개: 'area'(닿은 부분만) · 'stroke'(닿은 획 전체), 형광펜만·테이프만 지우기
  String eraserType = 'area';
  bool eraseOnlyHl = false;
  bool eraseOnlyTape = false;

  /// [kind] 도구로 그을 때의 색 (형광펜은 투명도 포함)
  Color colorOf(String kind) => switch (kind) {
        'hl' => hlColor.withValues(alpha: hlOpacity / 100),
        'tape' => tapeColor,
        _ => penColor,
      };

  /// 지금 도구로 그을 때의 색
  Color get color => colorOf(tool);

  /// 지금 도구로 그을 때의 굵기 (화면 점)
  double get width => switch (tool) { 'hl' => hlWidth, 'tape' => tapeWidth, _ => penWidth };

  bool get straight => switch (tool) { 'hl' => hlStraight, 'tape' => tapeStraight, _ => penStraight };

  /// 글자 크기에 맞춰 두께 조절 (형광펜·테이프)
  bool get fitText => switch (tool) { 'hl' => hlFit, 'tape' => tapeFit, _ => false };

  /// 지우개가 이 획을 지우는지 (형광펜만·테이프만 지우기)
  bool erases(MemoStroke s) {
    if (!eraseOnlyHl && !eraseOnlyTape) return true;
    return (eraseOnlyHl && s.kind == 'hl') || (eraseOnlyTape && s.kind == 'tape');
  }

  Map<String, dynamic> toJson() => {
        'tool': tool,
        'pc': penColor.toARGB32(),
        'pw': penWidth,
        'ps': penStraight,
        'hc': hlColor.toARGB32(),
        'hw': hlWidth,
        'ho': hlOpacity,
        'hs': hlStraight,
        'hf': hlFit,
        'tc': tapeColor.toARGB32(),
        'tw': tapeWidth,
        'ts': tapeStraight,
        'tf': tapeFit,
        'th': tapeHidden,
        'et': eraserType,
        'eh': eraseOnlyHl,
        'ex': eraseOnlyTape,
      };

  void _read(Map<String, dynamic> m) {
    T v<T>(String k, T d) => m[k] is T ? m[k] as T : d;
    double n(String k, double d) => m[k] is num ? (m[k] as num).toDouble() : d;
    final String t = v('tool', 'pen');
    tool = (t == 'hl' || t == 'tape') ? t : 'pen';
    penColor = Color(v('pc', penColor.toARGB32()));
    penWidth = n('pw', penWidth).clamp(0.5, 20.0).toDouble();
    penStraight = v('ps', false);
    hlColor = Color(v('hc', hlColor.toARGB32()));
    hlWidth = n('hw', hlWidth).clamp(4.0, 40.0).toDouble();
    hlOpacity = n('ho', hlOpacity.toDouble()).round().clamp(10, 100);
    hlStraight = v('hs', false);
    hlFit = v('hf', false);
    tapeColor = Color(v('tc', tapeColor.toARGB32()));
    tapeWidth = n('tw', tapeWidth).clamp(6.0, 48.0).toDouble();
    tapeStraight = v('ts', false);
    tapeFit = v('tf', false);
    tapeHidden = v('th', false);
    final String e = v('et', 'area');
    eraserType = e == 'stroke' ? 'stroke' : 'area';
    eraseOnlyHl = v('eh', false);
    eraseOnlyTape = v('ex', false);
  }
}

/// 모든 파일 보기가 함께 쓰는 메모 도구 설정
class MemoTools {
  static final MemoToolSettings s = MemoToolSettings();

  /// 설정이 바뀌면 알림 (파일 화면이 다시 그림)
  static final ValueNotifier<int> changed = ValueNotifier<int>(0);

  static Future<void> load() async {
    final m = await StorageService.getMemoToolSettings();
    if (m != null) s._read(m);
    changed.value++;
  }

  static Future<void> save() async {
    changed.value++;
    await StorageService.setMemoToolSettings(s.toJson());
  }
}

// ─────────────────────────────────────────────────────────────────────────────
// 그리기: 펜(둥근 끝) · 형광펜(납작한 끝, 비침) · 테이프(네모난 끝, 숨기면 테두리만)

/// 획 하나를 화면 좌표 [pts]로 그림
void paintMemoLine(Canvas canvas, List<Offset> pts, {required String kind, required Color color, required double width}) {
  if (pts.isEmpty || width <= 0) return;
  final path = Path()..moveTo(pts.first.dx, pts.first.dy);
  for (int i = 1; i < pts.length; i++) {
    path.lineTo(pts[i].dx, pts[i].dy);
  }
  if (pts.length == 1) path.lineTo(pts.first.dx + 0.01, pts.first.dy);
  final paint = Paint()
    ..color = color
    ..strokeWidth = width
    ..style = PaintingStyle.stroke
    ..strokeJoin = StrokeJoin.round;
  switch (kind) {
    case 'hl':
      canvas.drawPath(path, paint..strokeCap = StrokeCap.square);
    case 'tape':
      paint.strokeCap = StrokeCap.square;
      if (!MemoTools.s.tapeHidden) {
        canvas.drawPath(path, paint);
      } else {
        // 숨긴 테이프: 바깥 테두리만 남기고 안쪽은 비워 아래가 보이게
        final double border = math.max(1.6, width * 0.09);
        canvas.saveLayer(path.getBounds().inflate(width), Paint());
        canvas.drawPath(path, paint);
        canvas.drawPath(
          path,
          Paint()
            ..style = PaintingStyle.stroke
            ..strokeWidth = math.max(0.0, width - border * 2)
            ..strokeCap = StrokeCap.square
            ..strokeJoin = StrokeJoin.round
            ..blendMode = BlendMode.clear,
        );
        canvas.restore();
      }
    default:
      canvas.drawPath(path, paint..strokeCap = StrokeCap.round);
  }
}

/// 저장된 획들을 그림 ([toLocal]: 0~1 좌표 → 화면, [unit]: 굵기 기준 너비). 형광펜은 글씨 밑에 깔리게 먼저
void paintMemoStrokes(Canvas canvas, List<MemoStroke> strokes, {required Offset Function(double fx, double fy) toLocal, required double unit}) {
  void one(MemoStroke s) {
    if (s.dxList.isEmpty) return;
    paintMemoLine(
      canvas,
      [for (int i = 0; i < s.dxList.length; i++) toLocal(s.dxList[i], s.dyList[i])],
      kind: s.kind,
      color: Color(s.colorValue),
      width: s.widthOn(unit),
    );
  }

  for (final s in strokes) {
    if (s.kind == 'hl') one(s);
  }
  for (final s in strokes) {
    if (s.kind != 'hl') one(s);
  }
}

/// 지금 긋고 있는 획 (지금 도구의 모양으로, 확대한 만큼 [scale]배 굵게)
void paintMemoActive(Canvas canvas, List<Offset> pts, {double scale = 1}) {
  final st = MemoTools.s;
  paintMemoLine(canvas, pts, kind: st.tool, color: st.color, width: st.width * scale);
}

/// 직선 자동 보정: 거의 곧은 획은 두 점짜리 직선으로 (가로·세로에 가까우면 딱 맞춤)
List<Offset> straightenMemoLine(List<Offset> pts) {
  if (pts.length < 3) return pts;
  final Offset a = pts.first, b = pts.last;
  final Offset ab = b - a;
  final double len = ab.distance;
  if (len < 24) return pts;
  double maxDev = 0;
  for (final p in pts) {
    final double d = ((p.dx - a.dx) * ab.dy - (p.dy - a.dy) * ab.dx).abs() / len;
    if (d > maxDev) maxDev = d;
  }
  if (maxDev > math.max(7.0, len * 0.07)) return pts;
  final double ang = math.atan2(ab.dy, ab.dx).abs();
  const double snap = 5 * math.pi / 180;
  if (ang < snap || (math.pi - ang) < snap) return [a, Offset(b.dx, a.dy)];
  if ((ang - math.pi / 2).abs() < snap) return [a, Offset(a.dx, b.dy)];
  return [a, b];
}

/// 다 그은 획의 점들: 지금 도구가 직선 자동 보정이면 곧게
List<Offset> finishMemoPoints(List<Offset> pts) => MemoTools.s.straight ? straightenMemoLine(pts) : pts;

double _distToSegment(Offset p, Offset a, Offset b) {
  final Offset ab = b - a;
  final double l2 = ab.dx * ab.dx + ab.dy * ab.dy;
  if (l2 == 0) return (p - a).distance;
  final double t = (((p - a).dx * ab.dx + (p - a).dy * ab.dy) / l2).clamp(0.0, 1.0);
  return (p - (a + ab * t)).distance;
}

/// 지우개: [prev]→[cur]로 문지른 자리에 닿은 획(또는 닿은 부분)을 뺀 목록. 지운 게 없으면 null
/// 지우개 종류·형광펜만·테이프만 지우기는 [MemoTools] 설정을 따름
List<MemoStroke>? eraseMemoStrokes(
  List<MemoStroke> strokes,
  Offset prev,
  Offset cur, {
  required Offset Function(double fx, double fy) toLocal,
  required Offset Function(Offset local) toFrac,
  required double unit,
  required double hitRadius,
}) {
  final st = MemoTools.s;
  bool modified = false;
  final next = <MemoStroke>[];
  for (final s in strokes) {
    if (s.dxList.isEmpty) continue;
    if (!st.erases(s)) {
      next.add(s);
      continue;
    }
    // 넓은 형광펜·테이프는 가장자리에 닿아도 지워지게
    final double r = hitRadius + (s.kind == 'pen' ? 0 : s.widthOn(unit) / 2);
    final pts = [for (int i = 0; i < s.dxList.length; i++) toLocal(s.dxList[i], s.dyList[i])];
    double minX = double.infinity, maxX = double.negativeInfinity, minY = double.infinity, maxY = double.negativeInfinity;
    for (final p in pts) {
      minX = math.min(minX, p.dx);
      maxX = math.max(maxX, p.dx);
      minY = math.min(minY, p.dy);
      maxY = math.max(maxY, p.dy);
    }
    if (maxX < math.min(prev.dx, cur.dx) - r || minX > math.max(prev.dx, cur.dx) + r || maxY < math.min(prev.dy, cur.dy) - r || minY > math.max(prev.dy, cur.dy) + r) {
      next.add(s);
      continue;
    }
    // 4점 간격으로 촘촘히
    final dense = <Offset>[];
    for (int i = 0; i < pts.length; i++) {
      dense.add(pts[i]);
      if (i + 1 < pts.length) {
        final double d = (pts[i + 1] - pts[i]).distance;
        if (d > 4.0) {
          final int steps = (d / 4.0).ceil();
          for (int k = 1; k < steps; k++) {
            dense.add(Offset.lerp(pts[i], pts[i + 1], k / steps)!);
          }
        }
      }
    }
    if (!dense.any((p) => _distToSegment(p, prev, cur) <= r)) {
      next.add(s);
      continue;
    }
    modified = true;
    if (st.eraserType == 'stroke') continue; // 획 지우개: 통째로
    List<Offset> run = [];
    void flush() {
      if (run.isEmpty) return;
      if (run.length == 1) run.add(run.first + const Offset(0.2, 0.2));
      final compact = <Offset>[run.first];
      for (int i = 1; i < run.length - 1; i++) {
        if ((run[i] - compact.last).distance >= 2.2) compact.add(run[i]);
      }
      compact.add(run.last);
      final fr = [for (final p in compact) toFrac(p)];
      next.add(s.copyWith(dxList: [for (final f in fr) f.dx], dyList: [for (final f in fr) f.dy]));
      run = [];
    }

    for (final p in dense) {
      if (_distToSegment(p, prev, cur) <= r) {
        flush();
      } else {
        run.add(p);
      }
    }
    flush();
  }
  return modified ? next : null;
}

// ─────────────────────────────────────────────────────────────────────────────
// 글자 크기에 맞춰 두께 조절: 쪽 그림에서 획 아래 글줄의 높이를 찾아 그 높이로, 글줄 가운데에 맞춤

class _InkGray {
  _InkGray(this.w, this.h, this.lum);
  final int w, h;
  final Uint8List lum;
}

class MemoTextFit {
  static final Map<String, Future<_InkGray?>> _cache = {};

  /// 쪽 그림을 작게 줄여 밝기만 읽어 둠 (최근 6쪽)
  static Future<_InkGray?> _gray(String path) {
    final hit = _cache.remove(path);
    if (hit != null) return _cache[path] = hit;
    final f = _decode(path);
    _cache[path] = f;
    while (_cache.length > 6) {
      _cache.remove(_cache.keys.first);
    }
    return f;
  }

  static Future<_InkGray?> _decode(String path) async {
    try {
      final bytes = await File(path).readAsBytes();
      final codec = await ui.instantiateImageCodec(bytes, targetWidth: 480);
      final frame = await codec.getNextFrame();
      final img = frame.image;
      final data = await img.toByteData(format: ui.ImageByteFormat.rawRgba);
      final int w = img.width, h = img.height;
      img.dispose();
      if (data == null) return null;
      final lum = Uint8List(w * h);
      for (int i = 0; i < w * h; i++) {
        final int o = i * 4;
        lum[i] = ((data.getUint8(o) * 299 + data.getUint8(o + 1) * 587 + data.getUint8(o + 2) * 114) ~/ 1000);
      }
      return _InkGray(w, h, lum);
    } catch (_) {
      return null;
    }
  }

  /// 쓰기 시작할 때 미리 읽어 둠
  static void prefetch(String path) => unawaited(_gray(path));

  /// [pts]: 쪽 안 0~1 좌표. 글줄을 찾으면 (가운데로 옮긴 점들, 글줄 높이(쪽 높이 비율)), 못 찾으면 null
  static Future<({List<Offset> pts, double height})?> fit(String imagePath, List<Offset> pts) async {
    if (pts.isEmpty) return null;
    final g = await _gray(imagePath);
    if (g == null) return null;
    double minX = 1, maxX = 0, sumY = 0, minY = 1, maxY = 0;
    for (final p in pts) {
      minX = math.min(minX, p.dx);
      maxX = math.max(maxX, p.dx);
      minY = math.min(minY, p.dy);
      maxY = math.max(maxY, p.dy);
      sumY += p.dy;
    }
    int x0 = (minX * g.w).floor(), x1 = (maxX * g.w).ceil();
    if (x1 - x0 < 6) {
      x0 -= 3;
      x1 += 3;
    }
    x0 = x0.clamp(0, g.w - 1);
    x1 = x1.clamp(0, g.w - 1);
    final int yc = ((sumY / pts.length) * g.h).round().clamp(0, g.h - 1);
    final int range = math.max(4, (g.h * 0.06).round());
    final int ya = math.max(0, yc - range), yb = math.min(g.h - 1, yc + range);
    // 바탕 밝기: 그 둘레에서 밝은 쪽(85%)
    final sample = <int>[];
    final int stepY = math.max(1, (yb - ya) ~/ 40), stepX = math.max(1, (x1 - x0) ~/ 60);
    for (int y = ya; y <= yb; y += stepY) {
      for (int x = x0; x <= x1; x += stepX) {
        sample.add(g.lum[y * g.w + x]);
      }
    }
    if (sample.isEmpty) return null;
    sample.sort();
    final int bg = sample[(sample.length * 0.85).floor().clamp(0, sample.length - 1)];
    final int thr = bg - 55;
    if (thr <= 0) return null;
    final int cols = x1 - x0 + 1;
    double inkAt(int y) {
      int c = 0;
      for (int x = x0; x <= x1; x++) {
        if (g.lum[y * g.w + x] < thr) c++;
      }
      return c / cols;
    }

    final rows = <int, double>{for (int y = ya; y <= yb; y++) y: inkAt(y)};
    // 획 가까이에서 글씨가 있는 줄
    final int near = math.max(2, (g.h * 0.025).round());
    int? start;
    for (int d = 0; d <= near && start == null; d++) {
      for (final y in [yc - d, yc + d]) {
        if ((rows[y] ?? 0) >= 0.03) {
          start = y;
          break;
        }
      }
    }
    if (start == null) return null;
    bool ink(int y) => (rows[y] ?? 0) >= 0.01;
    int top = start, bottom = start;
    while (top - 1 >= ya && (ink(top - 1) || ink(top - 2))) {
      top--;
    }
    while (bottom + 1 <= yb && (ink(bottom + 1) || ink(bottom + 2))) {
      bottom++;
    }
    final int hpx = bottom - top + 1;
    if (hpx < 2 || hpx > g.h * 0.08) return null;
    final double height = hpx / g.h;
    final double center = (top + bottom + 1) / 2 / g.h;
    // 가로로 그은 획이면 글줄 가운데로 옮김
    final bool flat = (maxY - minY) < math.max(height * 1.5, 0.02);
    final double shift = flat ? center - sumY / pts.length : 0;
    return (pts: [for (final p in pts) Offset(p.dx, (p.dy + shift).clamp(0.0, 1.0))], height: height);
  }
}

// ─────────────────────────────────────────────────────────────────────────────
// 펜·형광펜·테이프 설정 창 (고른 도구를 한 번 더 눌렀을 때): 선 굵기 (+ 형광펜 투명도) + 직선 자동 보정 (+ 글자 크기에 맞춰 두께 조절) + 색상
Future<void> showMemoToolPanel({required BuildContext context, required String kind, required MemoTr tr}) {
  return showPopDialog<void>(
    context: context,
    barrierColor: Colors.black26,
    builder: (ctx) => _MemoToolPanel(kind: kind, tr: tr),
  );
}

class _MemoToolPanel extends StatefulWidget {
  const _MemoToolPanel({required this.kind, required this.tr});
  final String kind;
  final MemoTr tr;

  @override
  State<_MemoToolPanel> createState() => _MemoToolPanelState();
}

class _MemoToolPanelState extends State<_MemoToolPanel> {
  static const Color _panelColor = Color(0xFF2B2B2E);
  MemoToolSettings get _s => MemoTools.s;
  late bool _showMore = widget.kind == 'pen' && !kMemoPenColors.any((c) => c.toARGB32() == _s.penColor.toARGB32());

  bool get _pen => widget.kind == 'pen';
  bool get _hl => widget.kind == 'hl';

  (double, double, double) get _range => switch (widget.kind) { 'hl' => (4.0, 40.0, 1.0), 'tape' => (6.0, 48.0, 1.0), _ => (0.5, 20.0, 0.5) };

  double get _width => switch (widget.kind) { 'hl' => _s.hlWidth, 'tape' => _s.tapeWidth, _ => _s.penWidth };
  Color get _color => switch (widget.kind) { 'hl' => _s.hlColor, 'tape' => _s.tapeColor, _ => _s.penColor };

  void _changed(VoidCallback f) {
    setState(f);
    _s.tool = widget.kind;
    MemoTools.save();
  }

  void _setWidth(double w) {
    final (min, max, step) = _range;
    final double v = ((w / step).round() * step).clamp(min, max).toDouble();
    if (v == _width) return;
    _changed(() {
      switch (widget.kind) {
        case 'hl':
          _s.hlWidth = v;
        case 'tape':
          _s.tapeWidth = v;
        default:
          _s.penWidth = v;
      }
    });
  }

  void _setOpacity(int v) {
    final int o = v.clamp(10, 100);
    if (o == _s.hlOpacity) return;
    _changed(() => _s.hlOpacity = o);
  }

  void _setColor(Color c) => _changed(() {
        switch (widget.kind) {
          case 'hl':
            _s.hlColor = c;
          case 'tape':
            _s.tapeColor = c;
          default:
            _s.penColor = c;
        }
      });

  String _num(double v) => v == v.roundToDouble() ? v.toStringAsFixed(0) : v.toStringAsFixed(1);

  Widget _colorDot(Color c, {double size = 34}) {
    final bool selected = c.toARGB32() == _color.toARGB32();
    final bool light = c.computeLuminance() > 0.6;
    return GestureDetector(
      onTap: () => _setColor(c),
      child: Container(
        width: size,
        height: size,
        decoration: BoxDecoration(
          color: c,
          shape: BoxShape.circle,
          border: Border.all(color: selected ? Colors.white : Colors.white24, width: selected ? 2.4 : 1.0),
        ),
        child: selected ? Icon(Icons.check, size: size * 0.55, color: light ? Colors.black : Colors.white) : null,
      ),
    );
  }

  /// -/+ 단추와 숫자 손잡이 슬라이더 (선 굵기·투명도)
  Widget _slider({
    required String label,
    required double value,
    required double min,
    required double max,
    required int divisions,
    required String shown,
    required ValueChanged<double> onChanged,
    required VoidCallback onMinus,
    required VoidCallback onPlus,
    Color? fill,
  }) {
    final tr = widget.tr;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Text(label, style: const TextStyle(color: Colors.white70, fontSize: 13)),
        const SizedBox(height: 4),
        Row(
          children: [
            IconButton(icon: const Icon(Icons.remove, color: Colors.white), tooltip: tr('줄이기', 'Less', '减少', '減らす'), onPressed: onMinus),
            Expanded(
              child: SliderTheme(
                data: SliderTheme.of(context).copyWith(
                  trackHeight: 22,
                  activeTrackColor: fill ?? Colors.white24,
                  inactiveTrackColor: Colors.white12,
                  thumbColor: const Color(0xFF6E6E73),
                  overlayColor: Colors.white10,
                  thumbShape: _NumberThumbShape(label: shown),
                  trackShape: const RoundedRectSliderTrackShape(),
                ),
                child: Slider(value: value, min: min, max: max, divisions: divisions, onChanged: onChanged),
              ),
            ),
            IconButton(icon: const Icon(Icons.add, color: Colors.white), tooltip: tr('늘리기', 'More', '增加', '増やす'), onPressed: onPlus),
          ],
        ),
      ],
    );
  }

  Widget _toggle(String label, bool value, ValueChanged<bool> onChanged) => Padding(
        padding: const EdgeInsets.symmetric(vertical: 2),
        child: Row(
          children: [
            Expanded(child: Text(label, style: const TextStyle(color: Colors.white, fontSize: 15, fontWeight: FontWeight.w600))),
            Switch(
              value: value,
              activeTrackColor: AppColors.signature,
              onChanged: (v) => _changed(() => onChanged(v)),
            ),
          ],
        ),
      );

  @override
  Widget build(BuildContext context) {
    final tr = widget.tr;
    final (min, max, step) = _range;
    final String title = switch (widget.kind) {
      'hl' => tr('형광펜', 'Highlighter', '荧光笔', '蛍光ペン'),
      'tape' => tr('테이프', 'Tape', '胶带', 'テープ'),
      _ => tr('펜', 'Pen', '笔', 'ペン'),
    };
    final List<Color> colors = switch (widget.kind) { 'hl' => kMemoHighlighterColors, 'tape' => kMemoTapeColors, _ => kMemoPenColors };
    return Dialog(
      backgroundColor: _panelColor,
      insetPadding: const EdgeInsets.symmetric(horizontal: 24, vertical: 24),
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(32)),
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 420),
        child: SingleChildScrollView(
          padding: const EdgeInsets.fromLTRB(22, 14, 22, 22),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              // 머리줄: 도구 아이콘 + 제목 + 닫기
              Row(
                children: [
                  MemoToolIcon(kind: widget.kind, color: Colors.white, accent: _color, size: 22),
                  const SizedBox(width: 8),
                  Expanded(child: Text(title, style: const TextStyle(color: Colors.white, fontSize: 16, fontWeight: FontWeight.w600))),
                  Material(
                    color: Colors.white12,
                    shape: const CircleBorder(),
                    child: IconButton(
                      icon: const Icon(Icons.close, color: Colors.white, size: 19),
                      tooltip: tr('닫기', 'Close', '关闭', '閉じる'),
                      onPressed: () => Navigator.pop(context),
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 12),
              // 미리보기
              Container(
                height: 64,
                decoration: BoxDecoration(color: Colors.black26, borderRadius: BorderRadius.circular(14)),
                child: CustomPaint(painter: _ToolPreviewPainter(kind: widget.kind, color: MemoTools.s.colorOf(widget.kind), width: _width, hidden: _s.tapeHidden)),
              ),
              const SizedBox(height: 16),
              _slider(
                label: tr('선 굵기', 'Thickness', '线条粗细', '線の太さ'),
                value: _width,
                min: min,
                max: max,
                divisions: ((max - min) / step).round(),
                shown: _num(_width),
                onChanged: _setWidth,
                onMinus: () => _setWidth(_width - step),
                onPlus: () => _setWidth(_width + step),
              ),
              // 형광펜: 투명도 (선 굵기 밑)
              if (_hl) ...[
                const SizedBox(height: 6),
                _slider(
                  label: tr('투명도', 'Opacity', '不透明度', '不透明度'),
                  value: _s.hlOpacity.toDouble(),
                  min: 10,
                  max: 100,
                  divisions: 18,
                  shown: '${_s.hlOpacity}',
                  fill: _s.hlColor.withValues(alpha: _s.hlOpacity / 100),
                  onChanged: (v) => _setOpacity(v.round()),
                  onMinus: () => _setOpacity(_s.hlOpacity - 5),
                  onPlus: () => _setOpacity(_s.hlOpacity + 5),
                ),
              ],
              const SizedBox(height: 8),
              _toggle(
                tr('직선 자동 보정', 'Auto-Straighten Lines', '自动拉直线条', '直線を自動補正'),
                switch (widget.kind) { 'hl' => _s.hlStraight, 'tape' => _s.tapeStraight, _ => _s.penStraight },
                (v) => switch (widget.kind) { 'hl' => _s.hlStraight = v, 'tape' => _s.tapeStraight = v, _ => _s.penStraight = v },
              ),
              if (!_pen)
                _toggle(
                  tr('글자 크기에 맞춰 두께 조절', 'Match Thickness to Text Size', '按文字大小调整粗细', '文字サイズに合わせて太さを調整'),
                  _hl ? _s.hlFit : _s.tapeFit,
                  (v) => _hl ? _s.hlFit = v : _s.tapeFit = v,
                ),
              // 테이프: 숨기기 (테두리만 남기고 안쪽은 비쳐 보이게)
              if (widget.kind == 'tape')
                _toggle(tr('테이프 숨기기', 'Hide Tape', '隐藏胶带', 'テープを隠す'), _s.tapeHidden, (v) => _s.tapeHidden = v),
              const SizedBox(height: 12),
              Text(tr('색상', 'Color', '颜色', '色'), style: const TextStyle(color: Colors.white70, fontSize: 13)),
              const SizedBox(height: 10),
              Wrap(
                spacing: 10,
                runSpacing: 10,
                crossAxisAlignment: WrapCrossAlignment.center,
                children: [
                  ...colors.map(_colorDot),
                  // 펜: 더 많은 색상 펼치기
                  if (_pen)
                    GestureDetector(
                      onTap: () => setState(() => _showMore = !_showMore),
                      child: Container(
                        width: 34,
                        height: 34,
                        decoration: BoxDecoration(
                          shape: BoxShape.circle,
                          border: Border.all(color: _showMore ? Colors.white : Colors.white38, width: 1.4),
                        ),
                        child: const _PaletteDots(),
                      ),
                    ),
                ],
              ),
              if (_pen && _showMore) ...[
                const SizedBox(height: 12),
                Wrap(spacing: 10, runSpacing: 10, children: kMemoPenMoreColors.map((c) => _colorDot(c, size: 30)).toList()),
              ],
            ],
          ),
        ),
      ),
    );
  }
}

class _ToolPreviewPainter extends CustomPainter {
  _ToolPreviewPainter({required this.kind, required this.color, required this.width, required this.hidden});
  final String kind;
  final Color color;
  final double width;
  final bool hidden;

  @override
  void paint(Canvas canvas, Size size) {
    final double w = size.width, h = size.height;
    final List<Offset> pts = kind == 'pen'
        ? [
            for (int i = 0; i <= 40; i++)
              Offset(w * (0.12 + 0.76 * i / 40), h * (0.5 + 0.22 * math.sin(i / 40 * math.pi * 2.2)))
          ]
        : [Offset(w * 0.18, h * 0.5), Offset(w * 0.82, h * 0.5)];
    // 형광펜은 글자 위에 칠한 모습이 보이게 회색 글줄을 깔아 둠
    if (kind != 'pen') {
      final line = Paint()..color = Colors.white38;
      for (int i = 0; i < 9; i++) {
        canvas.drawRRect(RRect.fromRectAndRadius(Rect.fromLTWH(w * (0.2 + i * 0.068), h * 0.5 - 6, w * 0.05, 12), const Radius.circular(2)), line);
      }
    }
    paintMemoLine(canvas, pts, kind: kind, color: color, width: width.clamp(0.5, h * 0.8).toDouble());
  }

  @override
  bool shouldRepaint(covariant _ToolPreviewPainter old) => old.color != color || old.width != width || old.kind != kind || old.hidden != hidden;
}

// ─────────────────────────────────────────────────────────────────────────────
// 지우개 설정 창 (지우개를 한 번 더 눌렀을 때): 획/영역 지우개, 형광펜만·테이프만 지우기, 선·테이프 모두 지우기
Future<void> showEraserPanel({
  required BuildContext context,
  required MemoTr tr,
  required VoidCallback onClearLines,
  required VoidCallback onClearTapes,
}) {
  return showPopDialog<void>(
    context: context,
    barrierColor: Colors.black26,
    builder: (ctx) => _EraserPanel(tr: tr, onClearLines: onClearLines, onClearTapes: onClearTapes),
  );
}

class _EraserPanel extends StatefulWidget {
  const _EraserPanel({required this.tr, required this.onClearLines, required this.onClearTapes});
  final MemoTr tr;
  final VoidCallback onClearLines;
  final VoidCallback onClearTapes;

  @override
  State<_EraserPanel> createState() => _EraserPanelState();
}

class _EraserPanelState extends State<_EraserPanel> {
  MemoToolSettings get _s => MemoTools.s;

  void _changed(VoidCallback f) {
    setState(f);
    MemoTools.save();
  }

  @override
  Widget build(BuildContext context) {
    final tr = widget.tr;
    Widget radio(String value, String label) => InkWell(
          borderRadius: BorderRadius.circular(12),
          onTap: () => _changed(() => _s.eraserType = value),
          child: Padding(
            padding: const EdgeInsets.symmetric(vertical: 10),
            child: Row(
              children: [
                Icon(_s.eraserType == value ? Icons.radio_button_checked : Icons.radio_button_unchecked,
                    color: _s.eraserType == value ? AppColors.signature : Colors.white38, size: 24),
                const SizedBox(width: 16),
                Text(label, style: const TextStyle(color: Colors.white, fontSize: 16, fontWeight: FontWeight.w600)),
              ],
            ),
          ),
        );
    Widget toggle(String label, bool value, ValueChanged<bool> onChanged) => Row(
          children: [
            Expanded(child: Text(label, style: const TextStyle(color: Colors.white, fontSize: 15, fontWeight: FontWeight.w600))),
            Switch(value: value, activeTrackColor: AppColors.signature, onChanged: (v) => _changed(() => onChanged(v))),
          ],
        );
    Widget clear(String label, VoidCallback onTap) => TextButton(
          style: TextButton.styleFrom(foregroundColor: Colors.white, padding: const EdgeInsets.symmetric(vertical: 14)),
          onPressed: () {
            onTap();
            Navigator.pop(context);
          },
          child: Text(label, style: const TextStyle(fontSize: 16, fontWeight: FontWeight.w700)),
        );
    return Dialog(
      backgroundColor: const Color(0xFF2B2B2E),
      insetPadding: const EdgeInsets.symmetric(horizontal: 24, vertical: 24),
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(32)),
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 420),
        child: SingleChildScrollView(
          padding: const EdgeInsets.fromLTRB(22, 14, 22, 12),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Row(
                children: [
                  const EraserIcon(color: Colors.white, size: 20),
                  const SizedBox(width: 8),
                  Expanded(child: Text(tr('지우개', 'Eraser', '橡皮擦', '消しゴム'), style: const TextStyle(color: Colors.white, fontSize: 16, fontWeight: FontWeight.w600))),
                  Material(
                    color: Colors.white12,
                    shape: const CircleBorder(),
                    child: IconButton(
                      icon: const Icon(Icons.close, color: Colors.white, size: 19),
                      tooltip: tr('닫기', 'Close', '关闭', '閉じる'),
                      onPressed: () => Navigator.pop(context),
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 8),
              radio('stroke', tr('획 지우개', 'Stroke Eraser', '笔画橡皮擦', 'ストローク消しゴム')),
              radio('area', tr('영역 지우개', 'Area Eraser', '区域橡皮擦', '部分消しゴム')),
              const SizedBox(height: 6),
              toggle(tr('형광펜만 지우기', 'Erase Highlighter Only', '仅擦除荧光笔', '蛍光ペンだけ消す'), _s.eraseOnlyHl, (v) => _s.eraseOnlyHl = v),
              toggle(tr('테이프만 지우기', 'Erase Tape Only', '仅擦除胶带', 'テープだけ消す'), _s.eraseOnlyTape, (v) => _s.eraseOnlyTape = v),
              const SizedBox(height: 8),
              const Divider(color: Colors.white12, height: 1),
              // 보고 있는 쪽의 선(펜·형광펜) / 테이프를 모두 지움
              clear(tr('선 모두 지우기', 'Clear All Lines', '清除全部线条', '線をすべて消す'), widget.onClearLines),
              clear(tr('테이프 모두 지우기', 'Clear All Tape', '清除全部胶带', 'テープをすべて消す'), widget.onClearTapes),
            ],
          ),
        ),
      ),
    );
  }
}


class _PaletteDots extends StatelessWidget {
  const _PaletteDots();

  @override
  Widget build(BuildContext context) {
    const colors = [Colors.red, Colors.orange, Colors.yellow, Colors.green, Colors.blue, Colors.purple];
    return Padding(
      padding: const EdgeInsets.all(7),
      child: Wrap(
        spacing: 2,
        runSpacing: 2,
        alignment: WrapAlignment.center,
        children: colors
            .map((c) => Container(width: 5.5, height: 5.5, decoration: BoxDecoration(color: c, shape: BoxShape.circle)))
            .toList(),
      ),
    );
  }
}

/// 숫자가 들어간 둥근 손잡이 (사진 속 '5' 손잡이 모양)
class _NumberThumbShape extends SliderComponentShape {
  const _NumberThumbShape({required this.label});
  final String label;
  static const double _r = 19.0;

  @override
  Size getPreferredSize(bool isEnabled, bool isDiscrete) => const Size.fromRadius(_r);

  @override
  void paint(
    PaintingContext context,
    Offset center, {
    required Animation<double> activationAnimation,
    required Animation<double> enableAnimation,
    required bool isDiscrete,
    required TextPainter labelPainter,
    required RenderBox parentBox,
    required SliderThemeData sliderTheme,
    required TextDirection textDirection,
    required double value,
    required double textScaleFactor,
    required Size sizeWithOverflow,
  }) {
    final canvas = context.canvas;
    canvas.drawCircle(center, _r, Paint()..color = const Color(0xFF6E6E73));
    canvas.drawCircle(
      center,
      _r,
      Paint()
        ..color = Colors.white24
        ..style = PaintingStyle.stroke
        ..strokeWidth = 1,
    );
    final tp = TextPainter(
      text: TextSpan(
        text: label,
        // 앱 글꼴을 그대로 쓰도록 슬라이더 테마의 글자 스타일을 기반으로 함
        style: (sliderTheme.valueIndicatorTextStyle ?? const TextStyle())
            .copyWith(color: Colors.white, fontSize: 14, fontWeight: FontWeight.w600),
      ),
      textDirection: TextDirection.ltr,
    )..layout();
    tp.paint(canvas, center - Offset(tp.width / 2, tp.height / 2));
  }
}

// ─────────────────────────────────────────────────────────────────────────────
// 지우개 모양 아이콘 (비스듬한 지우개 + 고무 부분 채움 + 바닥 선)
class EraserIcon extends StatelessWidget {
  const EraserIcon({super.key, required this.color, this.size = 18});
  final Color color;
  final double size;

  @override
  Widget build(BuildContext context) =>
      CustomPaint(size: Size.square(size), painter: _EraserIconPainter(color));
}

class _EraserIconPainter extends CustomPainter {
  _EraserIconPainter(this.color);
  final Color color;

  @override
  void paint(Canvas canvas, Size size) {
    final double s = size.width;
    final stroke = Paint()
      ..color = color
      ..style = PaintingStyle.stroke
      ..strokeWidth = s * 0.085
      ..strokeJoin = StrokeJoin.round;
    final fill = Paint()..color = color;

    canvas.save();
    canvas.translate(s * 0.52, s * 0.44);
    canvas.rotate(-0.785398); // -45°
    final body = RRect.fromRectAndRadius(
      Rect.fromCenter(center: Offset.zero, width: s * 0.86, height: s * 0.40),
      Radius.circular(s * 0.09),
    );
    // 고무(지우는 쪽) 부분 채우기: 왼쪽 약 40%
    canvas.save();
    canvas.clipRRect(body);
    canvas.drawRect(Rect.fromLTWH(-s * 0.43, -s * 0.20, s * 0.34, s * 0.40), fill);
    canvas.restore();
    canvas.drawRRect(body, stroke);
    canvas.restore();

    // 바닥 선
    canvas.drawLine(Offset(s * 0.36, s * 0.90), Offset(s * 0.92, s * 0.90), stroke..strokeCap = StrokeCap.round);
  }

  @override
  bool shouldRepaint(covariant _EraserIconPainter old) => old.color != color;
}

/// 메모 도구 아이콘 (24칸 기준으로 그림)
/// - 'memo': 무색 연필 + 밑줄 (파일 화면 도구 모음의 메모 단추)
/// - 'pen': 연필 + 끝마개·밑줄이 고른 색 [accent]
/// - 'hl': 형광펜 (납작한 펜촉) + 굵은 밑줄이 고른 색
/// - 'tape': 비스듬한 테이프 조각 (양끝 톱니), 안쪽이 고른 색
class MemoToolIcon extends StatelessWidget {
  const MemoToolIcon({super.key, required this.kind, required this.color, this.accent, this.size = 22});
  final String kind;

  /// 테두리 색
  final Color color;

  /// 고른 색 (없으면 테두리 색)
  final Color? accent;
  final double size;

  @override
  Widget build(BuildContext context) =>
      SizedBox.square(dimension: size, child: CustomPaint(painter: _MemoToolIconPainter(kind, color, accent ?? color)));
}

class _MemoToolIconPainter extends CustomPainter {
  _MemoToolIconPainter(this.kind, this.color, this.accent);
  final String kind;
  final Color color;
  final Color accent;

  @override
  void paint(Canvas canvas, Size size) {
    final double u = size.width / 24.0;
    canvas.save();
    canvas.scale(u);
    final line = Paint()
      ..color = color
      ..style = PaintingStyle.stroke
      ..strokeWidth = 1.7
      ..strokeCap = StrokeCap.round
      ..strokeJoin = StrokeJoin.round;
    final fillAccent = Paint()..color = accent;

    if (kind == 'tape') {
      // 테이프: 가운데를 지나 비스듬히, 양끝은 톱니
      canvas.translate(12, 12);
      canvas.rotate(-math.pi / 4);
      const double hw = 11.0, hh = 4.6;
      final path = Path()..moveTo(-hw, -hh);
      path.lineTo(hw, -hh);
      for (int i = 0; i < 4; i++) {
        final double y0 = -hh + i * (2 * hh / 4);
        path.lineTo(hw - 1.6, y0 + hh / 4);
        path.lineTo(hw, y0 + hh / 2);
      }
      path.lineTo(-hw, hh);
      for (int i = 0; i < 4; i++) {
        final double y0 = hh - i * (2 * hh / 4);
        path.lineTo(-hw + 1.6, y0 - hh / 4);
        path.lineTo(-hw, y0 - hh / 2);
      }
      path.close();
      canvas.drawPath(path, fillAccent);
      canvas.drawPath(path, line..strokeWidth = 1.5);
      canvas.restore();
      return;
    }

    final bool hl = kind == 'hl';
    // 밑줄 (형광펜은 굵은 막대)
    if (kind == 'memo') {
      canvas.drawLine(const Offset(3.5, 21.5), const Offset(20.5, 21.5), line);
    } else if (hl) {
      canvas.drawRRect(RRect.fromRectAndRadius(const Rect.fromLTRB(3.0, 19.2, 21.0, 23.0), const Radius.circular(1.9)), fillAccent);
    } else {
      canvas.drawRRect(RRect.fromRectAndRadius(const Rect.fromLTRB(3.0, 20.0, 21.0, 22.8), const Radius.circular(1.4)), fillAccent);
    }

    // 연필 몸통: 오른쪽 위 → 왼쪽 아래 (펜촉)
    canvas.save();
    canvas.translate(13.2, 9.6);
    canvas.rotate(-math.pi / 4);
    final double hh = hl ? 3.1 : 2.7;
    final body = Path()
      ..moveTo(7.6, -hh)
      ..lineTo(-5.6, -hh)
      ..lineTo(hl ? -9.0 : -10.4, hl ? -1.0 : 0) // 펜촉
      ..lineTo(hl ? -9.0 : -10.4, hl ? 1.0 : 0)
      ..lineTo(-5.6, hh)
      ..lineTo(7.6, hh)
      ..close();
    if (kind != 'memo') {
      // 끝마개 (형광펜은 몸통 띠) = 고른 색
      canvas.drawRect(Rect.fromLTRB(hl ? 1.6 : 4.4, -hh, hl ? 4.4 : 7.6, hh), fillAccent);
      if (hl) {
        // 형광펜 펜촉도 고른 색
        canvas.drawPath(
          Path()
            ..moveTo(-5.6, -hh)
            ..lineTo(-9.0, -1.0)
            ..lineTo(-9.0, 1.0)
            ..lineTo(-5.6, hh)
            ..close(),
          fillAccent,
        );
      }
    }
    canvas.drawPath(body, line);
    // 펜촉과 몸통 사이 줄, 끝마개 줄
    canvas.drawLine(Offset(-5.6, -hh), Offset(-5.6, hh), line);
    if (!hl) canvas.drawLine(Offset(4.4, -hh), Offset(4.4, hh), line);
    canvas.restore();
    canvas.restore();
  }

  @override
  bool shouldRepaint(_MemoToolIconPainter old) => old.kind != kind || old.color != color || old.accent != accent;
}


/// 손으로 글씨 쓰기 아이콘: 손가락 끝에서 선이 그어지는 모양
class FingerDrawIcon extends StatelessWidget {
  const FingerDrawIcon({super.key, required this.color, this.size = 22});

  final Color color;
  final double size;

  @override
  Widget build(BuildContext context) {
    return SizedBox.square(
      dimension: size,
      child: Stack(
        clipBehavior: Clip.none,
        children: [
          // 손가락으로 그은 선 (손가락 끝에서 왼쪽 아래로 물결)
          Positioned.fill(child: CustomPaint(painter: _FingerLinePainter(color))),
          // 검지를 세운 손 (오른쪽 아래)
          Positioned(
            right: -size * 0.06,
            bottom: -size * 0.06,
            child: Icon(Icons.pan_tool_alt, size: size * 0.78, color: color),
          ),
        ],
      ),
    );
  }
}

class _FingerLinePainter extends CustomPainter {
  _FingerLinePainter(this.color);

  final Color color;

  @override
  void paint(Canvas canvas, Size size) {
    final double u = size.width / 24.0;
    canvas.save();
    canvas.scale(u);
    final path = Path()
      ..moveTo(14.4, 7.6) // 손가락 끝
      ..cubicTo(12.0, 3.0, 7.2, 2.4, 5.8, 5.8)
      ..cubicTo(4.6, 9.0, 8.8, 10.2, 7.6, 13.4)
      ..cubicTo(6.8, 15.6, 3.8, 15.8, 1.6, 14.6);
    canvas.drawPath(
      path,
      Paint()
        ..color = color
        ..style = PaintingStyle.stroke
        ..strokeWidth = 1.8
        ..strokeCap = StrokeCap.round
        ..strokeJoin = StrokeJoin.round,
    );
    canvas.restore();
  }

  @override
  bool shouldRepaint(_FingerLinePainter old) => old.color != color;
}
