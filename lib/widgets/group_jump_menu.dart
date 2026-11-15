import 'dart:math' as math;

import 'package:flutter/material.dart';

import 'app_colors.dart';

/// 메뉴 한 줄: (값, 보이는 이름, 아이콘, 글자·아이콘 색(없으면 기본))
typedef ScaleMenuItem<T> = (T, String, IconData, Color?);

/// 누른 아이콘(칩)에서 빠져나오며 커지고, 닫힐 때는 다시 작아지며 그 안으로 들어가는 메뉴.
/// [전체] 그룹 목록, 파일의 점 3개 메뉴가 같이 쓴다.
class GroupJumpMenuRoute<T> extends PopupRoute<T> {
  GroupJumpMenuRoute({required this.anchor, required this.items, this.barrierLabel, this.leadingFor, this.beside = false, this.selected, this.compact = false});

  /// 지금 고른 값 (줄 끝에 체크 표시)
  final T? selected;

  /// true면 누른 것(예: 그룹 이름)의 바로 오른쪽, 위쪽을 맞춰 펼침
  final bool beside;

  /// 글자 길이만큼만 (최소 너비 없이, 오른쪽 빈 공간 없게)
  final bool compact;

  /// 줄 앞 그림을 따로 줄 때 (예: 그룹 이름이 파일 형식이면 그 형식 아이콘). null이면 기본 아이콘
  final Widget? Function(T value)? leadingFor;

  /// 누른 아이콘(칩)의 화면 위치
  final Rect anchor;
  final List<ScaleMenuItem<T>> items;

  @override
  final String? barrierLabel;

  @override
  Color? get barrierColor => Colors.transparent;

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
    const double menuWidth = 220, rowHeight = 46;
    final double menuHeight = math.min(screen.height * 0.6, items.length * rowHeight + 12);
    // 화면 오른쪽에 있는 아이콘이면 메뉴 오른쪽 끝을 맞추고, 아래 공간이 모자라면 위로 펼침
    final bool alignRight = !beside && anchor.center.dx > screen.width / 2;
    final bool above = !beside && anchor.bottom + 6 + menuHeight > screen.height - pad.bottom - 8 && anchor.top - 6 - menuHeight > pad.top;
    final double edgeX = beside
        ? math.min(anchor.right + 28, screen.width - 8 - 140)
        : alignRight ? math.min(screen.width - 8, anchor.right) : math.max(8.0, anchor.left);
    // 위아래 어디로도 다 들어가지 않으면 화면 안에 들어오도록 올려서 펼침
    final double edgeY = beside
        ? math.max(pad.top + 8, math.min(anchor.top, screen.height - pad.bottom - 8 - menuHeight))
        : above
            ? anchor.top - 6
            : math.max(pad.top + 8, math.min(anchor.bottom + 6, screen.height - pad.bottom - 8 - menuHeight));
    final Alignment corner = above ? (alignRight ? Alignment.bottomRight : Alignment.bottomLeft) : (alignRight ? Alignment.topRight : Alignment.topLeft);
    // 누른 아이콘 가운데에서 커져 나오도록 (메뉴 모서리 기준)
    final Offset origin = Offset(anchor.center.dx - edgeX, anchor.center.dy - edgeY);
    final curved = CurvedAnimation(parent: animation, curve: Curves.easeOutBack, reverseCurve: Curves.easeInCubic);
    final fade = CurvedAnimation(parent: animation, curve: const Interval(0, 0.5), reverseCurve: const Interval(0.4, 1));
    final cs = Theme.of(context).colorScheme;
    final card = Material(
      // 그룹 목록 위에 뜨는 편집 메뉴(beside)는 목록과 구분되게 조금 더 진한 바탕
      color: beside ? Color.alphaBlend(cs.onSurface.withValues(alpha: 0.07), cs.surfaceContainerHighest) : cs.surfaceContainerHigh,
      elevation: 6,
      borderRadius: BorderRadius.circular(14),
      clipBehavior: Clip.antiAlias,
      child: ConstrainedBox(
        // 글자 길이만큼만 (오른쪽 빈 공간 없이)
        constraints: BoxConstraints(minWidth: beside || compact ? 0 : 150, maxWidth: menuWidth, maxHeight: screen.height * 0.6),
        child: IntrinsicWidth(
          // ListView는 내용 너비를 잴 수 없어 Column + 스크롤로
          child: SingleChildScrollView(
            padding: const EdgeInsets.symmetric(vertical: 6),
            child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              for (final (value, label, icon, color) in items)
                InkWell(
                  onTap: () => Navigator.of(context).pop(value),
                  child: Padding(
                    padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
                    child: Row(
                      children: [
                        leadingFor?.call(value) ?? Icon(icon, size: 16, color: color ?? cs.onSurfaceVariant),
                        const SizedBox(width: 10),
                        Flexible(child: Text(label, overflow: TextOverflow.ellipsis, style: TextStyle(fontSize: 15, color: color))),
                        if (selected != null && selected == value) ...[
                          const SizedBox(width: 12),
                          Icon(Icons.check, size: 18, color: AppColors.mark(context)),
                        ],
                      ],
                    ),
                  ),
                ),
            ],
          ),
          ),
        ),
      ),
    );
    return Stack(
      children: [
        Positioned(
          left: alignRight ? null : edgeX,
          right: alignRight ? screen.width - edgeX : null,
          top: above ? null : edgeY,
          bottom: above ? screen.height - edgeY : null,
          child: AnimatedBuilder(
            animation: animation,
            child: card,
            builder: (context, child) => Opacity(
              opacity: fade.value.clamp(0.0, 1.0),
              child: Transform.scale(
                scale: 0.12 + 0.88 * curved.value,
                alignment: corner,
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

/// 편집 버튼 모음: 메뉴 한 줄씩이 아니라 버튼 하나하나로, 메인 화면 [파일 추가] 버튼처럼
/// 누른 자리에서 하나씩 차례로 빠져나오고(앞 버튼 뒤에 숨어 있다가) 닫을 때는 거꾸로 들어감.
/// 빨간 색을 준 항목(삭제)은 빨간 바탕에 흰 아이콘·글씨
class ActionButtonsRoute<T> extends PopupRoute<T> {
  ActionButtonsRoute({required this.anchor, required this.items, this.barrierLabel, this.beside = false, this.besideLeft});

  final Rect anchor;
  final List<ScaleMenuItem<T>> items;
  final bool beside;

  /// 옆에 띄울 때 버튼 왼쪽 끝 자리 (그룹 목록 오른쪽 바깥). 없으면 누른 이름 바로 오른쪽
  final double? besideLeft;

  @override
  final String? barrierLabel;

  @override
  Color? get barrierColor => Colors.transparent;

  @override
  bool get barrierDismissible => true;

  @override
  Duration get transitionDuration => Anim.ms(460);

  @override
  Duration get reverseTransitionDuration => Anim.ms(340);

  @override
  Widget buildPage(BuildContext context, Animation<double> animation, Animation<double> secondaryAnimation) {
    final Size screen = MediaQuery.sizeOf(context);
    final EdgeInsets pad = MediaQuery.paddingOf(context);
    const double rowH = 54; // 버튼 높이 46 + 사이 8
    const double boxW = 260; // 버튼들이 놓이는 자리 너비 (가장 긴 버튼도 들어가게)
    const double sideSlide = 180; // 옆에 띄울 때 미끄러져 나오는 거리
    final double total = items.length * rowH;
    final bool alignRight = !beside && anchor.center.dx > screen.width / 2;
    final bool above = !beside && anchor.bottom + 6 + total > screen.height - pad.bottom - 8 && anchor.top - 6 - total > pad.top;
    final double edgeX = beside
        ? math.min(besideLeft ?? anchor.right + 16, screen.width - 8 - 150)
        : alignRight ? math.min(screen.width - 8, anchor.right) : math.max(8.0, anchor.left);
    final double edgeY = beside
        ? math.max(pad.top + 8, math.min(anchor.top - 4, screen.height - pad.bottom - 8 - total))
        : above
            ? anchor.top - 6
            : math.max(pad.top + 8, math.min(anchor.bottom + 6, screen.height - pad.bottom - 8 - total));
    final cs = Theme.of(context).colorScheme;
    final shadows = AppColors.sigShadows(context);

    Widget button(ScaleMenuItem<T> it) {
      final (value, label, icon, color) = it;
      final bool danger = color != null;
      final Color bg = danger ? Colors.redAccent : cs.surfaceContainerHighest;
      final Color fg = danger ? Colors.white : cs.onSurface;
      return Padding(
        padding: const EdgeInsets.only(bottom: rowH - 46),
        child: Material(
          color: bg,
          elevation: 3,
          shadowColor: Colors.black54,
          shape: const StadiumBorder(),
          clipBehavior: Clip.antiAlias,
          child: InkWell(
            onTap: () => Navigator.of(context).pop(value),
            child: SizedBox(
              height: 46,
              child: Padding(
                padding: const EdgeInsets.symmetric(horizontal: 18),
                child: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Icon(icon, size: 20, color: fg, shadows: danger ? shadows : null),
                    const SizedBox(width: 8),
                    Text(label, style: TextStyle(fontSize: 15, fontWeight: FontWeight.w600, color: fg, shadows: danger ? shadows : null)),
                  ],
                ),
              ),
            ),
          ),
        ),
      );
    }

    return Stack(
      children: [
        Positioned(
          left: alignRight ? null : math.max(8.0, math.min(edgeX, screen.width - 8 - 170)), // 버튼이 화면 밖으로 나가지 않을 만큼만 당김
          right: alignRight ? screen.width - edgeX : null,
          top: above ? null : edgeY,
          bottom: above ? screen.height - edgeY : null,
          width: boxW,
          height: total,
          child: AnimatedBuilder(
            animation: animation,
            builder: (context, _) {
              final double t = animation.value;
              final bool opening = animation.status == AnimationStatus.forward || animation.status == AnimationStatus.completed;
              final int n = items.length;
              // 누른 자리에 가까운 버튼부터 차례로 (위로 펼치면 맨 아래 버튼이 먼저)
              final order = above ? [for (int i = n - 1; i >= 0; i--) i] : [for (int i = 0; i < n; i++) i];
              final offsets = List<Offset>.filled(n, Offset.zero);
              final shown = List<double>.filled(n, 0);
              double hidden = 0; // 앞 버튼이 아직 덜 나온 만큼 (그 뒤에 붙어 함께 움직임)
              for (int k = 0; k < n; k++) {
                final int i = order[k];
                final double raw = ((t - k * 0.22) / 0.56).clamp(0.0, 1.0);
                final double p = (opening ? Curves.easeOutBack : Curves.easeOutCubic).transform(raw);
                if (beside) {
                  // 옆에 띄울 때: 목록 오른쪽 가장자리 뒤에서 오른쪽으로 하나씩 미끄러져 나옴
                  offsets[i] = Offset(-sideSlide * (1 - p), 0);
                } else {
                  hidden += rowH * (1 - p);
                  offsets[i] = Offset(0, above ? hidden : -hidden);
                }
                shown[i] = raw;
              }
              // 누른 자리에서 먼 버튼부터 그려, 가까운 버튼 뒤에 숨어 있다가 빠져나옴
              final paintOrder = order.reversed.toList();
              final Widget stack = SizedBox(
                width: boxW,
                height: total,
                child: Stack(
                  clipBehavior: Clip.none,
                  children: [
                    for (final i in paintOrder)
                      Positioned(
                        top: i * rowH,
                        left: alignRight ? null : 0,
                        right: alignRight ? 0 : null,
                        child: Transform.translate(
                          offset: offsets[i],
                          child: Opacity(opacity: (shown[i] * 3).clamp(0.0, 1.0), child: button(items[i])),
                        ),
                      ),
                  ],
                ),
              );
              // 옆에 띄울 때는 왼쪽 가장자리(목록 바로 옆)에서 잘라, 목록 뒤에서 나오는 것처럼 보이게 (그림자 자리는 남김)
              return beside ? ClipRect(clipper: _LeftEdgeClipper(), child: stack) : stack;
            },
          ),
        ),
      ],
    );
  }
}

/// 왼쪽만 자르고 위·아래·오른쪽은 그림자가 보이게 넉넉히 둠
class _LeftEdgeClipper extends CustomClipper<Rect> {
  @override
  Rect getClip(Size size) => Rect.fromLTRB(-2, -24, size.width + 40, size.height + 24);

  @override
  bool shouldReclip(_LeftEdgeClipper oldClipper) => false;
}

/// [anchorContext] 위치에서 편집 버튼들을 하나씩 빠져나오게 띄우고 고른 값을 돌려줌 (닫으면 null)
Future<T?> showScaleMenu<T>(BuildContext anchorContext, List<ScaleMenuItem<T>> items, {bool beside = false, bool compact = false, double? besideLeft}) {
  final box = anchorContext.findRenderObject() as RenderBox?;
  if (box == null || !box.hasSize) return Future.value(null);
  // 메뉴가 놓이는 화면 기준 좌표 (태블릿처럼 앱을 크게 보여 줄 때도 누른 자리에 맞게)
  final RenderObject? overlayBox = Navigator.of(anchorContext).overlay?.context.findRenderObject();
  final Offset topLeft = box.localToGlobal(Offset.zero, ancestor: overlayBox);
  return Navigator.of(anchorContext).push<T>(
    ActionButtonsRoute<T>(
      anchor: topLeft & box.size,
      barrierLabel: MaterialLocalizations.of(anchorContext).modalBarrierDismissLabel,
      items: items,
      beside: beside,
      besideLeft: besideLeft,
    ),
  );
}
