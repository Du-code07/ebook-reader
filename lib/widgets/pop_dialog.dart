import 'package:flutter/material.dart';

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
    transitionDuration: const Duration(milliseconds: 300),
    pageBuilder: (ctx, _, __) => captured.wrap(SafeArea(child: Builder(builder: builder))),
    transitionBuilder: (ctx, anim, _, child) => popTransition(ctx, anim, child),
  );
}
