import 'dart:math' as math;

import 'package:flutter/material.dart';

import '../services/storage_service.dart';
import 'app_colors.dart';
import 'morph_icons.dart';

/// 메뉴 한 줄: (값, 보이는 이름, 아이콘, 글자·아이콘 색(없으면 기본))
typedef ScaleMenuItem<T> = (T, String, IconData, Color?);

/// 누른 아이콘(칩)에서 빠져나오며 커지고, 닫힐 때는 다시 작아지며 그 안으로 들어가는 메뉴.
/// 앱 스타일 '기본'의 파일 편집(점 3개)·그룹 편집 창이 쓴다 (아이콘 + 이름을 한 네모 안에).
class GroupJumpMenuRoute<T> extends PopupRoute<T> {
  GroupJumpMenuRoute({required this.anchor, required this.items, this.barrierLabel, this.leadingFor, this.beside = false, this.selected, this.compact = false, this.boldLabels = false, this.besideRight});

  /// 이름을 굵게 (파일·그룹 편집창)
  final bool boldLabels;

  /// 옆에 띄울 때 메뉴 오른쪽 끝 자리 (그룹 목록 안쪽 오른쪽 끝, 목록 밖으로 나가지 않게)
  final double? besideRight;

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
    final bool alignRight = beside ? besideRight != null : anchor.center.dx > screen.width / 2;
    final bool above = !beside && anchor.bottom + 6 + menuHeight > screen.height - pad.bottom - 8 && anchor.top - 6 - menuHeight > pad.top;
    final double edgeX = beside
        ? (besideRight != null ? besideRight! - 14 /* 목록 오른쪽 끝에서 살짝 안쪽 */ : math.min(anchor.right + 28, screen.width - 8 - 140))
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
                        leadingFor?.call(value) ?? menuIcon(icon, size: 16, color: color ?? cs.onSurfaceVariant),
                        const SizedBox(width: 10),
                        Flexible(child: Text(label, overflow: TextOverflow.ellipsis, style: TextStyle(fontSize: 15, color: color, fontWeight: boldLabels ? FontWeight.w700 : null))),
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

/// 앱 스타일 '심플'의 편집 단추 모음: 글자 없이 동그란 아이콘 단추 하나하나로 (이름은 길게 누르면)
/// 누른 자리에서 하나씩 차례로 빠져나오고(앞 단추 뒤에 숨어 있다가) 닫을 때는 거꾸로 들어감.
/// 파일 편집(점 3개)은 누른 자리 아래로 가로 줄(표지형은 3개씩 두 줄), 그룹 편집은 그룹 목록 안 오른쪽 끝에 가로로.
/// 빨간 색을 준 항목(삭제)은 빨간 바탕에 흰 아이콘
class ActionButtonsRoute<T> extends PopupRoute<T> {
  ActionButtonsRoute({required this.anchor, required this.items, this.barrierLabel, this.columns, this.besideRight, this.overList = false});

  final Rect anchor;
  final List<ScaleMenuItem<T>> items;

  /// 한 줄에 놓을 단추 수 (없으면 모두 한 줄)
  final int? columns;

  /// 그룹 편집: 단추 줄 오른쪽 끝 자리 (그룹 목록 안쪽 오른쪽 끝). 누른 줄과 같은 높이에 놓음
  final double? besideRight;

  /// 단추가 목록 위에 겹쳐 놓이는지 (그룹 편집): 목록과 구별되게 바탕을 살짝 어둡게
  final bool overList;

  @override
  final String? barrierLabel;

  @override
  Color? get barrierColor => Colors.transparent;

  @override
  bool get barrierDismissible => true;

  @override
  Duration get transitionDuration => Anim.ms(380);

  @override
  Duration get reverseTransitionDuration => Anim.ms(340);

  /// 동그란 아이콘 단추 하나 (이름은 길게 누르면)
  Widget _circle(BuildContext context, ScaleMenuItem<T> it, double d, Color normalBg) {
    final (value, label, icon, color) = it;
    final bool danger = color != null;
    final cs = Theme.of(context).colorScheme;
    final Color fg = danger ? Colors.white : cs.onSurface;
    return Tooltip(
      message: label,
      child: Material(
        color: danger ? Colors.redAccent : normalBg,
        elevation: 3,
        shadowColor: Colors.black54,
        shape: const CircleBorder(),
        clipBehavior: Clip.antiAlias,
        child: InkWell(
          onTap: () => Navigator.of(context).pop(value),
          child: SizedBox.square(
            dimension: d,
            child: Center(child: menuIcon(icon, size: d * 0.44, color: fg, shadows: danger ? AppColors.sigShadows(context) : null)),
          ),
        ),
      ),
    );
  }

  @override
  Widget buildPage(BuildContext context, Animation<double> animation, Animation<double> secondaryAnimation) {
    final Size screen = MediaQuery.sizeOf(context);
    final EdgeInsets pad = MediaQuery.paddingOf(context);
    final cs = Theme.of(context).colorScheme;
    final Color normalBg = overList ? Color.alphaBlend(Colors.black.withValues(alpha: 0.07), cs.surfaceContainerHighest) : cs.surfaceContainerHighest;
    final int n = items.length;
    final int cols = math.max(1, math.min(columns ?? n, n));
    final int rows = (n + cols - 1) ~/ cols;
    const double gap = 8;
    // 단추가 많아도 화면 안에 다 들어가게 크기를 맞춤
    final double d = math.min(46.0, (screen.width - 16 - gap * (cols - 1)) / cols);
    final double boxW = cols * d + (cols - 1) * gap, boxH = rows * d + (rows - 1) * gap;
    final bool alignRight = besideRight != null || anchor.center.dx > screen.width / 2;
    final double rightEdge = besideRight != null ? besideRight! - 14 : anchor.right;
    final double left = (alignRight ? rightEdge - boxW : anchor.left).clamp(8.0, math.max(8.0, screen.width - 8 - boxW)).toDouble();
    final bool above = besideRight == null && anchor.bottom + 8 + boxH > screen.height - pad.bottom - 8;
    final double top = besideRight != null
        ? anchor.center.dy - d / 2 // 누른 줄과 같은 높이
        : above
            ? anchor.top - 8 - boxH
            : anchor.bottom + 8;
    // 단추 자리 (상자 안): 줄마다 오른쪽 맞춤이면 오른쪽부터 채움
    Offset slot(int i) {
      final int r = i ~/ cols, c = i % cols;
      final int inRow = math.min(cols, n - r * cols);
      final double rowStart = alignRight ? boxW - (inRow * d + (inRow - 1) * gap) : 0;
      return Offset(rowStart + c * (d + gap), r * (d + gap));
    }

    // 누른 자리에 가까운 단추부터 차례로 (오른쪽 맞춤이면 각 줄의 오른쪽부터)
    final order = <int>[
      for (int r = 0; r < rows; r++)
        for (int k = 0; k < math.min(cols, n - r * cols); k++) r * cols + (alignRight ? math.min(cols, n - r * cols) - 1 - k : k),
    ];
    return Stack(children: [
      Positioned(
        left: left,
        top: top,
        width: boxW,
        height: boxH,
        child: AnimatedBuilder(
          animation: animation,
          builder: (context, _) {
            final double t = animation.value;
            final bool opening = animation.status == AnimationStatus.forward || animation.status == AnimationStatus.completed;
            final offsets = List<double>.filled(n, 0);
            final shown = List<double>.filled(n, 0);
            final double step = n > 1 ? math.min(0.22, 0.48 / (n - 1)) : 0.0;
            // 줄마다: 앞 단추가 아직 덜 나온 만큼 뒤 단추가 그 뒤에 붙어 함께 움직임
            final hiddenOfRow = List<double>.filled(rows, 0);
            for (int k = 0; k < n; k++) {
              final int i = order[k];
              final int r = i ~/ cols;
              final double raw = ((t - k * step) / 0.52).clamp(0.0, 1.0);
              final double p = (opening ? Curves.easeOutBack : Curves.easeOutCubic).transform(raw);
              hiddenOfRow[r] += (d + gap) * (1 - p);
              offsets[i] = alignRight ? hiddenOfRow[r] : -hiddenOfRow[r];
              shown[i] = raw;
            }
            return Stack(clipBehavior: Clip.none, children: [
              // 누른 자리에서 먼 단추부터 그려, 가까운 단추 뒤에 숨어 있다가 빠져나옴
              for (final i in order.reversed)
                Positioned(
                  left: slot(i).dx,
                  top: slot(i).dy,
                  child: Transform.translate(
                    offset: Offset(offsets[i], 0),
                    child: Opacity(opacity: (shown[i] * 3).clamp(0.0, 1.0), child: _circle(context, items[i], d, normalBg)),
                  ),
                ),
            ]);
          },
        ),
      ),
    ]);
  }
}

/// [anchorContext] 위치에서 편집 단추(창)를 띄우고 고른 값을 돌려줌 (닫으면 null)
/// [beside]: 그룹 편집 — [besideRight](그룹 목록 안쪽 오른쪽 끝)에 맞춰 누른 줄 옆에
/// [columns]: 심플 스타일에서 한 줄에 놓을 단추 수 (표지형 파일 편집은 3)
Future<T?> showScaleMenu<T>(BuildContext anchorContext, List<ScaleMenuItem<T>> items, {bool beside = false, bool compact = false, double? besideRight, bool overList = false, int? columns}) {
  final box = anchorContext.findRenderObject() as RenderBox?;
  if (box == null || !box.hasSize) return Future.value(null);
  // 메뉴가 놓이는 화면 기준 좌표 (태블릿처럼 앱을 크게 보여 줄 때도 누른 자리에 맞게)
  final RenderObject? overlayBox = Navigator.of(anchorContext).overlay?.context.findRenderObject();
  final Offset topLeft = box.localToGlobal(Offset.zero, ancestor: overlayBox);
  final String barrierLabel = MaterialLocalizations.of(anchorContext).modalBarrierDismissLabel;
  // 앱 스타일 '기본': 아이콘 + 이름(굵게)을 한 네모(카드) 안에 모아서, 누른 자리에서 커져 나옴
  if (!StorageService.simpleStyle) {
    return Navigator.of(anchorContext).push<T>(
      GroupJumpMenuRoute<T>(anchor: topLeft & box.size, barrierLabel: barrierLabel, items: items, beside: beside, besideRight: besideRight, compact: compact, boldLabels: true),
    );
  }
  // 앱 스타일 '심플': 동그란 아이콘 단추만
  return Navigator.of(anchorContext).push<T>(
    ActionButtonsRoute<T>(
      anchor: topLeft & box.size,
      barrierLabel: barrierLabel,
      items: items,
      columns: columns,
      besideRight: beside ? besideRight : null,
      overList: overList,
    ),
  );
}
