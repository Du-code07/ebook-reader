import 'dart:math' as math;

import 'package:flutter/material.dart';

/// [전체] 칩 아래에 펼쳐지는 그룹 목록.
/// 나타날 때는 [전체] 칩에서 빠져나오며 커지고, 사라질 때는 다시 작아지며 칩 안으로 들어간다.
class GroupJumpMenuRoute<T> extends PopupRoute<T> {
  GroupJumpMenuRoute({required this.anchor, required this.items, this.barrierLabel});

  /// [전체] 칩의 화면 위치
  final Rect anchor;

  /// (값, 보이는 이름)
  final List<(T, String)> items;

  @override
  final String? barrierLabel;

  @override
  Color? get barrierColor => Colors.transparent;

  @override
  bool get barrierDismissible => true;

  @override
  Duration get transitionDuration => const Duration(milliseconds: 300);

  @override
  Duration get reverseTransitionDuration => const Duration(milliseconds: 200);

  @override
  Widget buildPage(BuildContext context, Animation<double> animation, Animation<double> secondaryAnimation) {
    final Size screen = MediaQuery.sizeOf(context);
    const double menuWidth = 220;
    final double left = anchor.left.clamp(8.0, math.max(8.0, screen.width - menuWidth - 8)).toDouble();
    final double top = anchor.bottom + 6;
    // 칩 가운데에서 커져 나오도록 (메뉴 왼쪽 위 기준 좌표)
    final Offset origin = Offset(anchor.center.dx - left, anchor.center.dy - top);
    final curved = CurvedAnimation(parent: animation, curve: Curves.easeOutBack, reverseCurve: Curves.easeInCubic);
    final fade = CurvedAnimation(parent: animation, curve: const Interval(0, 0.5), reverseCurve: const Interval(0.4, 1));
    final cs = Theme.of(context).colorScheme;
    final card = Material(
      color: cs.surfaceContainerHigh,
      elevation: 6,
      borderRadius: BorderRadius.circular(14),
      clipBehavior: Clip.antiAlias,
      child: ConstrainedBox(
        constraints: BoxConstraints(minWidth: 160, maxWidth: menuWidth, maxHeight: screen.height * 0.6),
        child: ListView(
          padding: const EdgeInsets.symmetric(vertical: 6),
          shrinkWrap: true,
          children: [
            for (final (value, label) in items)
              InkWell(
                onTap: () => Navigator.of(context).pop(value),
                child: Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
                  child: Row(
                    children: [
                      Icon(Icons.folder_outlined, size: 18, color: cs.onSurfaceVariant),
                      const SizedBox(width: 10),
                      Flexible(child: Text(label, overflow: TextOverflow.ellipsis, style: const TextStyle(fontSize: 15))),
                    ],
                  ),
                ),
              ),
          ],
        ),
      ),
    );
    return Stack(
      children: [
        Positioned(
          left: left,
          top: top,
          child: AnimatedBuilder(
            animation: animation,
            child: card,
            builder: (context, child) => Opacity(
              opacity: fade.value.clamp(0.0, 1.0),
              child: Transform.scale(
                scale: 0.12 + 0.88 * curved.value,
                alignment: Alignment.topLeft,
                origin: origin,
                child: child,
              ),
            ),
          ),
        ),
      ],
    );
  }
}
