import 'dart:math' as math;
import 'package:flutter/material.dart';
import 'package:flutter/gestures.dart';
import 'app_colors.dart';

/// 마지막으로 화면을 누른 자리 (앱 화면 기준). 창이 그 자리에서 커져 나오게 씀
class TapOrigin {
  static Offset? last;

  /// 앱 화면 전체를 감싸 누른 자리를 기억 (다른 동작에는 영향 없음)
  static Widget track(Widget child) => Listener(
        behavior: HitTestBehavior.translucent,
        onPointerDown: (e) => last = e.localPosition,
        child: child,
      );
}

/// 꾹 눌러 뜨는 메뉴와 같은 움직임: 누른 자리에서 커져 나오고, 닫힐 때는 그 자리로 작아지며 들어감
/// [from]: 창을 연 자리 (열 때 붙잡아 둔 값). 창 안의 단추를 눌러 닫아도 처음 연 아이콘 자리로 돌아감
Widget popTransition(BuildContext context, Animation<double> animation, Widget child, {Offset? from}) {
  final curved = CurvedAnimation(parent: animation, curve: Curves.easeOutBack, reverseCurve: Curves.easeInCubic);
  final fade = CurvedAnimation(parent: animation, curve: const Interval(0, 0.5), reverseCurve: const Interval(0.4, 1));
  final Size screen = MediaQuery.sizeOf(context);
  final Offset center = screen.center(Offset.zero);
  final Offset origin = (from ?? TapOrigin.last ?? center) - center;
  // 부드럽게: 흐려짐은 FadeTransition(창을 다시 그리지 않고 겹만 바꿈), 창 내용은 한 번만 그려 두고(RepaintBoundary) 크기만 바꿈
  return FadeTransition(
    opacity: fade,
    child: AnimatedBuilder(
      animation: curved,
      child: RepaintBoundary(child: child),
      builder: (context, child) => Transform.scale(scale: 0.12 + 0.88 * curved.value, origin: origin, child: child),
    ),
  );
}

/// showDialog 대신: 같은 대화창을 누른 자리에서 커져 나오게
Future<T?> showPopDialog<T>({
  required BuildContext context,
  required WidgetBuilder builder,
  bool barrierDismissible = true,
  Color? barrierColor,
  bool useRootNavigator = true,
}) {
  final captured = InheritedTheme.capture(from: context, to: Navigator.of(context, rootNavigator: useRootNavigator).context);
  final Offset? from = TapOrigin.last; // 연 자리를 붙잡아 둠 (닫을 때 창 안에서 누른 자리로 들어가지 않게)
  return showGeneralDialog<T>(
    context: context,
    useRootNavigator: useRootNavigator,
    barrierDismissible: barrierDismissible,
    barrierLabel: MaterialLocalizations.of(context).modalBarrierDismissLabel,
    barrierColor: barrierColor ?? Colors.black54,
    transitionDuration: Anim.ms(300),
    pageBuilder: (ctx, _, __) => captured.wrap(SafeArea(child: Builder(builder: builder))),
    transitionBuilder: (ctx, anim, _, child) => popTransition(ctx, anim, child, from: from),
  );
}

/// 단추 바로 아래로 펼쳐지는 작은 창 (그룹 목록과 같은 움직임: 단추에서 튀어나오고, 닫힐 때 단추 안으로 들어감)
/// [alignRight]면 창 오른쪽 끝을 단추 오른쪽 끝에 맞춤
class PopPanelRoute<T> extends PopupRoute<T> {
  PopPanelRoute({required this.anchor, required this.builder, this.width = 360, this.alignRight = true, this.barrierLabel, this.fromBottom = false});

  final Rect anchor;
  final WidgetBuilder builder;
  final double width;
  final bool alignRight;

  /// 단추 아래가 아니라 화면 밑에서 위로 올라오는 창으로 (앱 스타일 '기본'의 아래 막대에서 열 때)
  final bool fromBottom;

  @override
  final String? barrierLabel;

  @override
  Color? get barrierColor => Colors.black.withValues(alpha: fromBottom ? 0.32 : 0.18);

  @override
  bool get barrierDismissible => true;

  @override
  Duration get transitionDuration => Anim.ms(300);

  @override
  Duration get reverseTransitionDuration => Anim.ms(200);

  @override
  Widget buildPage(BuildContext context, Animation<double> animation, Animation<double> secondaryAnimation) {
    final Size screen = MediaQuery.sizeOf(context);
    final EdgeInsets pad = MediaQuery.paddingOf(context);
    if (fromBottom) {
      return BottomRise(
        animation: animation,
        gripBelow: 8, // 바로 아래 제목 줄(ListTile)에 위 여백이 있어 합치면 다른 창과 같은 간격
        child: SafeArea(top: false, child: SingleChildScrollView(child: Builder(builder: builder))),
      );
    }
    final double w = width.clamp(200.0, screen.width - 16).toDouble();
    final double left = alignRight ? (anchor.right - w).clamp(8.0, screen.width - 8 - w).toDouble() : anchor.left.clamp(8.0, screen.width - 8 - w).toDouble();
    final double top = anchor.bottom + 4;
    final double maxH = (screen.height - pad.bottom - 12 - top).clamp(160.0, double.infinity).toDouble();
    final curved = CurvedAnimation(parent: animation, curve: Curves.easeOutBack, reverseCurve: Curves.easeInCubic);
    final fade = CurvedAnimation(parent: animation, curve: const Interval(0, 0.5), reverseCurve: const Interval(0.4, 1));
    // 단추 가운데에서 커져 나옴 (창 왼쪽 위 모서리 기준)
    final Offset origin = Offset(anchor.center.dx - left, anchor.center.dy - top);
    return Stack(children: [
      Positioned(
        left: left,
        top: top,
        width: w,
        child: AnimatedBuilder(
          animation: animation,
          builder: (context, child) => Opacity(
            opacity: fade.value.clamp(0.0, 1.0),
            child: Transform.scale(scale: 0.12 + 0.88 * curved.value, alignment: Alignment.topLeft, origin: origin, child: child),
          ),
          child: ConstrainedBox(
            constraints: BoxConstraints(maxHeight: maxH),
            child: Material(
              color: Theme.of(context).colorScheme.surfaceContainerHigh,
              elevation: 6,
              borderRadius: BorderRadius.circular(18),
              clipBehavior: Clip.antiAlias,
              child: SingleChildScrollView(child: Builder(builder: builder)),
            ),
          ),
        ),
      ),
    ]);
  }
}

/// 화면 밑에서 위로 올라오는 창 (아래쪽에 붙고, 넓은 화면에서는 가운데 640까지, 높이는 화면의 85%까지)
/// 맨 위 회색 막대를 아래로 끌면 따라 내려오고, 충분히 내리면 닫힘
class BottomRise extends StatefulWidget {
  const BottomRise({super.key, required this.animation, required this.child, this.gripBelow = 34});
  final Animation<double> animation;
  final Widget child;

  /// 회색 막대 아래 간격 (제목이 있으면 제목까지)
  final double gripBelow;

  /// 안쪽에서 손가락 끌기를 따로 쓰는 동안(그룹 순서 바꾸기 등) 창이 같이 내려가지 않게
  static void holdPull(BuildContext context, bool hold) => context.findAncestorStateOfType<_BottomRiseState>()?._hold = hold;

  @override
  State<BottomRise> createState() => _BottomRiseState();
}

class _BottomRiseState extends State<BottomRise> with SingleTickerProviderStateMixin {
  double _drag = 0; // 아래로 끌어 내린 만큼
  late final AnimationController _back = AnimationController(vsync: this, duration: Anim.ms(200))
    ..addListener(() => setState(() => _drag = _from * (1 - Curves.easeOutCubic.transform(_back.value))));
  double _from = 0;

  @override
  void dispose() {
    _back.dispose();
    super.dispose();
  }

  // ── 내용을 끌어 창 내리기 (앱 설정 창처럼: 내용이 맨 위일 때 아래로 끌면 창이 따라 내려옴) ──
  bool _innerAtTop = true; // 안쪽 목록이 맨 위인지 (목록이 없으면 늘 맨 위)
  bool _hold = false;
  int? _pointer;
  bool _pulling = false;
  Offset _pending = Offset.zero;
  VelocityTracker? _velocity;

  bool _onScroll(ScrollNotification n) {
    if (n.metrics.axis == Axis.vertical) _innerAtTop = n.metrics.pixels <= n.metrics.minScrollExtent + 0.5;
    return false;
  }

  void _onDown(PointerDownEvent e) {
    if (_pointer != null) return;
    _pointer = e.pointer;
    _pulling = false;
    _pending = Offset.zero;
    _velocity = VelocityTracker.withKind(e.kind)..addPosition(e.timeStamp, e.position);
  }

  void _onMove(PointerMoveEvent e) {
    if (e.pointer != _pointer || _hold) return;
    _velocity?.addPosition(e.timeStamp, e.position);
    if (!_pulling) {
      if (!_innerAtTop) return;
      _pending += e.delta;
      // 아래로, 옆보다 세로로 더 움직였을 때만 (옆으로 미는 동작과 겹치지 않게)
      if (_pending.dy > kTouchSlop && _pending.dy > _pending.dx.abs()) {
        _pulling = true;
        _back.stop();
      } else if (_pending.dy < -kTouchSlop) {
        _pointer = null; // 위로 올리면 평소 스크롤
      }
      return;
    }
    setState(() => _drag = math.max(0.0, _drag + e.delta.dy));
  }

  void _onUp(PointerEvent e) {
    if (e.pointer != _pointer) return;
    _pointer = null;
    if (!_pulling) return;
    _pulling = false;
    final double v = _velocity?.getVelocity().pixelsPerSecond.dy ?? 0;
    _end(DragEndDetails(primaryVelocity: v, velocity: Velocity(pixelsPerSecond: Offset(0, v))));
  }

  void _end(DragEndDetails d) {
    // 많이 내렸거나 빠르게 내리면 닫음, 아니면 제자리로
    if (_drag > 90 || (d.primaryVelocity ?? 0) > 700) {
      Navigator.of(context).maybePop();
      return;
    }
    _from = _drag;
    _back.forward(from: 0);
  }

  @override
  Widget build(BuildContext context) {
    final Size screen = MediaQuery.sizeOf(context);
    final slide = CurvedAnimation(parent: widget.animation, curve: Curves.easeOutCubic, reverseCurve: Curves.easeInCubic);
    return Align(
      alignment: Alignment.bottomCenter,
      child: SlideTransition(
        position: Tween<Offset>(begin: const Offset(0, 1), end: Offset.zero).animate(slide),
        child: Transform.translate(
          offset: Offset(0, _drag),
          child: ConstrainedBox(
            constraints: BoxConstraints(maxHeight: screen.height * 0.85, maxWidth: 640),
            child: Material(
              color: Theme.of(context).colorScheme.surfaceContainerHigh,
              borderRadius: const BorderRadius.vertical(top: Radius.circular(24)),
              clipBehavior: Clip.antiAlias,
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  // 회색 막대 자리: 아래로 끌어 창 내리기
                  GestureDetector(
                    behavior: HitTestBehavior.opaque,
                    onVerticalDragStart: (_) => _back.stop(),
                    onVerticalDragUpdate: (d) => setState(() => _drag = math.max(0.0, _drag + d.delta.dy)),
                    onVerticalDragEnd: _end,
                    child: SheetGrip(below: widget.gripBelow),
                  ),
                  Flexible(
                    child: NotificationListener<ScrollNotification>(
                      onNotification: _onScroll,
                      child: Listener(
                        onPointerDown: _onDown,
                        onPointerMove: _onMove,
                        onPointerUp: _onUp,
                        onPointerCancel: _onUp,
                        child: widget.child,
                      ),
                    ),
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}
