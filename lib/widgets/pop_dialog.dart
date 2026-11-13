import 'package:flutter/material.dart';
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
Widget popTransition(BuildContext context, Animation<double> animation, Widget child) {
  final curved = CurvedAnimation(parent: animation, curve: Curves.easeOutBack, reverseCurve: Curves.easeInCubic);
  final fade = CurvedAnimation(parent: animation, curve: const Interval(0, 0.5), reverseCurve: const Interval(0.4, 1));
  final Size screen = MediaQuery.sizeOf(context);
  final Offset center = screen.center(Offset.zero);
  final Offset origin = (TapOrigin.last ?? center) - center;
  return AnimatedBuilder(
    animation: animation,
    child: child,
    builder: (context, child) => Opacity(
      opacity: fade.value.clamp(0.0, 1.0),
      child: Transform.scale(scale: 0.12 + 0.88 * curved.value, origin: origin, child: child),
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
  return showGeneralDialog<T>(
    context: context,
    useRootNavigator: useRootNavigator,
    barrierDismissible: barrierDismissible,
    barrierLabel: MaterialLocalizations.of(context).modalBarrierDismissLabel,
    barrierColor: barrierColor ?? Colors.black54,
    transitionDuration: Anim.ms(300),
    pageBuilder: (ctx, _, __) => captured.wrap(SafeArea(child: Builder(builder: builder))),
    transitionBuilder: (ctx, anim, _, child) => popTransition(ctx, anim, child),
  );
}

/// 단추 바로 아래로 펼쳐지는 작은 창 (그룹 목록과 같은 움직임: 단추에서 튀어나오고, 닫힐 때 단추 안으로 들어감)
/// [alignRight]면 창 오른쪽 끝을 단추 오른쪽 끝에 맞춤
class PopPanelRoute<T> extends PopupRoute<T> {
  PopPanelRoute({required this.anchor, required this.builder, this.width = 360, this.alignRight = true, this.barrierLabel});

  final Rect anchor;
  final WidgetBuilder builder;
  final double width;
  final bool alignRight;

  @override
  final String? barrierLabel;

  @override
  Color? get barrierColor => Colors.black.withValues(alpha: 0.18);

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
