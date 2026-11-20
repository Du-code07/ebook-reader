import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import 'app_colors.dart';
import 'group_jump_menu.dart';
import 'pop_dialog.dart';
import 'group_stack_icon.dart';
import 'ui_scale.dart';
import 'file_type_icon.dart';

/// 그룹 목록에서 [즐겨찾기]를 고르면 돌려주는 값
const String kFavoritesGroupKey = '__favorites__';

/// [☰ 그룹] 단추 바로 아래로 펼쳐지는 그룹 목록
/// - 맨 위 [전체] · [즐겨찾기]는 고정 (옮기기·꾹 누르기 없음)
/// - 나머지 그룹은 왼쪽 손잡이(≡)를 끌어 순서 바꾸기, 꾹 누르면 목록 안 오른쪽 끝에 [이름 수정 / 그룹 삭제]
/// - 맨 아래 [+ 그룹 추가]
/// 고른 그룹 이름(또는 [kFavoritesGroupKey])을 돌려줌. 그냥 닫으면 null
class GroupDropdownRoute extends PopupRoute<String> {
  GroupDropdownRoute({
    required this.anchor,
    required this.groups,
    required this.selected,
    required this.labelOf,
    required this.leadingOf,
    required this.allLeading,
    required this.allLabel,
    required this.favLabel,
    required this.addLabel,
    required this.renameLabel,
    required this.deleteLabel,
    required this.onReorder,
    required this.onRename,
    required this.onDelete,
    required this.onAdd,
    this.barrierLabel,
    this.fromBottom = false,
    this.beside = false,
  });

  /// 단추 아래가 아니라 화면 밑에서 위로 올라오는 창으로 (앱 스타일 '기본'의 아래 막대에서 열 때)
  final bool fromBottom;

  /// 단추 오른쪽 옆으로 펼침 (심플 스타일 왼쪽 아이콘 막대에서 열 때)
  final bool beside;

  /// [☰ 그룹] 단추의 화면 위치
  final Rect anchor;

  /// 옮길 수 있는 그룹들 ([전체] 빼고)
  final List<String> groups;

  /// 지금 고른 것 ('전체', [kFavoritesGroupKey], 그룹 이름)
  final String selected;
  final String Function(String group) labelOf;
  final Widget Function(String group) leadingOf;
  final Widget allLeading;
  final String allLabel, favLabel, addLabel, renameLabel, deleteLabel;

  final void Function(List<String> order) onReorder;

  /// 새 이름을 돌려줌 (취소하면 null)
  final Future<String?> Function(String group) onRename;

  /// 지웠으면 true
  final Future<bool> Function(String group) onDelete;

  /// 새로 만든 그룹 이름 (취소하면 null)
  final Future<String?> Function() onAdd;

  @override
  final String? barrierLabel;

  @override
  Color? get barrierColor => Colors.black.withValues(alpha: fromBottom ? 0.32 : 0.18);

  @override
  bool get barrierDismissible => true;

  // 예전(99판) [전체] 그룹 메뉴와 같은 움직임: 누른 단추에서 커져 나오고, 닫힐 때는 다시 작아지며 단추 안으로 들어감
  @override
  Duration get transitionDuration => Anim.ms(300);

  @override
  Duration get reverseTransitionDuration => Anim.ms(200);

  @override
  Widget buildPage(BuildContext context, Animation<double> animation, Animation<double> secondaryAnimation) {
    if (fromBottom) return BottomRise(animation: animation, gripBelow: 10, child: _GroupDropdownPanel(route: this));
    final Size screen = MediaQuery.sizeOf(context);
    final EdgeInsets pad = MediaQuery.paddingOf(context);
    final double left = beside ? anchor.right + 6 : math.max(8.0, anchor.left);
    final double top = beside ? math.max(pad.top + 8, anchor.top) : anchor.bottom + 6;
    final double maxH = math.max(160.0, screen.height - pad.bottom - 12 - top);
    final curved = CurvedAnimation(parent: animation, curve: Curves.easeOutBack, reverseCurve: Curves.easeInCubic);
    final fade = CurvedAnimation(parent: animation, curve: const Interval(0, 0.5), reverseCurve: const Interval(0.4, 1));
    // 단추 가운데에서 커져 나오도록 (목록 왼쪽 위 모서리 기준)
    final Offset origin = Offset(anchor.center.dx - left, anchor.center.dy - top);
    return Stack(children: [
      Positioned(
        left: left,
        top: top,
        child: AnimatedBuilder(
          animation: animation,
          builder: (context, child) => Opacity(
            opacity: fade.value.clamp(0.0, 1.0),
            child: Transform.scale(
              scale: 0.12 + 0.88 * curved.value,
              alignment: Alignment.topLeft,
              origin: origin,
              child: child,
            ),
          ),
          child: ConstrainedBox(
            constraints: BoxConstraints(maxHeight: maxH, minWidth: 200, maxWidth: math.min(280.0, screen.width - left - 8)),
            child: _GroupDropdownPanel(route: this),
          ),
        ),
      ),
    ]);
  }
}

class _GroupDropdownPanel extends StatefulWidget {
  const _GroupDropdownPanel({required this.route});
  final GroupDropdownRoute route;

  @override
  State<_GroupDropdownPanel> createState() => _GroupDropdownPanelState();
}

class _GroupDropdownPanelState extends State<_GroupDropdownPanel> {
  late List<String> _groups = List.of(widget.route.groups);
  Offset _grab = Offset.zero;
  final GlobalKey _panelKey = GlobalKey();

  GroupDropdownRoute get r => widget.route;

  Widget _row({
    required Key key,
    required String value,
    required Widget leading,
    required String label,
    Widget? handle,
    GestureLongPressCallback? onLongPress,
  }) {
    final cs = Theme.of(context).colorScheme;
    final bool sel = value == r.selected;
    final Color fg = sel ? AppColors.onSig(context) : cs.onSurface;
    return Padding(
      key: key,
      padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 1),
      child: Material(
        color: sel ? AppColors.of(context) : Colors.transparent,
        borderRadius: BorderRadius.circular(10),
        clipBehavior: Clip.antiAlias,
        child: InkWell(
          onTap: () => Navigator.of(context).pop(value),
          // 고정된 [전체]·[즐겨찾기]는 꾹 눌러도 아무 일 없음 (고르기로 넘어가지 않게)
          onLongPress: onLongPress ?? () {},
          child: SizedBox(
            height: 46,
            child: Row(children: [
              // 왼쪽 손잡이(≡) 자리 (고정된 [전체]·[즐겨찾기]는 비워 둠)
              handle ?? const SizedBox(width: 40),
              // 고른 줄(시그니쳐 색)에서도 아이콘 안쪽은 목록 바탕색 그대로
              SizedBox(width: 24, child: Center(child: sel ? IconInnerFill(color: cs.surfaceContainerHigh, child: leading) : leading)),
              const SizedBox(width: 12),
              Expanded(
                child: Align(
                  alignment: Alignment.centerLeft,
                  child: Text(label,
                      overflow: TextOverflow.ellipsis,
                      // 위 그룹 이름 칸(칩)과 같은 글꼴·크기, 둘 다 굵게
                      style: (Theme.of(context).textTheme.labelLarge ?? const TextStyle()).copyWith(color: fg, fontWeight: FontWeight.w700, shadows: sel ? AppColors.sigShadows(context) : null)),
                ),
              ),
              if (sel) Padding(padding: const EdgeInsets.only(left: 6), child: Icon(Icons.check, size: 18, color: AppColors.onSig(context), shadows: AppColors.sigShadows(context))),
              const SizedBox(width: 14),
            ]),
          ),
        ),
      ),
    );
  }

  Future<void> _groupMenu(BuildContext rowContext, String g) async {
    HapticFeedback.selectionClick();
    // 편집 창(단추)은 그룹 목록 안쪽 오른쪽 끝에, 누른 줄 높이로 (목록 밖으로 나가지 않게)
    double? besideRight;
    final panelBox = _panelKey.currentContext?.findRenderObject() as RenderBox?;
    final RenderObject? overlayBox = Navigator.of(context).overlay?.context.findRenderObject();
    if (panelBox != null && panelBox.hasSize) {
      besideRight = panelBox.localToGlobal(Offset.zero, ancestor: overlayBox).dx + panelBox.size.width;
    }
    if (!mounted) return;
    // 줄 높이에 맞추려고 이름 대신 줄 전체를 기준으로
    final action = await showScaleMenu<String>(rowContext, [
      ('rename', r.renameLabel, Icons.edit_outlined, null),
      ('delete', r.deleteLabel, Icons.delete_outline, Colors.redAccent),
    ], beside: true, besideRight: besideRight, overList: true);
    if (!mounted || action == null) return;
    if (action == 'rename') {
      final name = await r.onRename(g);
      if (name != null && mounted) {
        setState(() {
          final i = _groups.indexOf(g);
          if (i >= 0) _groups[i] = name;
        });
      }
    } else if (action == 'delete') {
      final ok = await r.onDelete(g);
      if (!mounted || !ok) return;
      // 지금 보고 있던 그룹을 지웠으면 [전체]로 돌아가며 닫힘
      if (g == r.selected) {
        Navigator.of(context).pop('전체');
        return;
      }
      setState(() => _groups.remove(g));
    }
  }

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final double uiScale = UiScale.of(context);
    final list = ReorderableListView.builder(
      shrinkWrap: true,
      buildDefaultDragHandles: false,
      padding: EdgeInsets.zero,
      itemCount: _groups.length,
      onReorderStart: (_) => HapticFeedback.selectionClick(),
      // ignore: deprecated_member_use
      onReorder: (oldIndex, newIndex) {
        if (newIndex > oldIndex) newIndex -= 1;
        if (newIndex == oldIndex) return;
        setState(() => _groups.insert(newIndex, _groups.removeAt(oldIndex)));
        r.onReorder(List.of(_groups));
      },
      proxyDecorator: (child, index, animation) => Material(
        type: MaterialType.transparency,
        child: AnimatedBuilder(
          animation: animation,
          builder: (_, c) => UiScaleDragFix(
            scale: uiScale,
            grab: _grab,
            dropT: animation.status == AnimationStatus.reverse ? animation.value : null,
            child: Material(
              color: cs.surfaceContainerHighest,
              elevation: 4 * animation.value,
              borderRadius: BorderRadius.circular(10),
              child: c!,
            ),
          ),
          child: child,
        ),
      ),
      itemBuilder: (context, index) {
        final g = _groups[index];
        final bool sel = g == r.selected;
        return Builder(
          key: ValueKey('dd:$g'),
          builder: (rowCtx) => Listener(
            onPointerDown: (e) {
              final box = rowCtx.findRenderObject();
              if (box is RenderBox && box.hasSize) _grab = box.globalToLocal(e.position);
            },
            child: _row(
              key: ValueKey('ddrow:$g'),
              value: g,
              leading: r.leadingOf(g),
              label: r.labelOf(g),
              onLongPress: () => _groupMenu(rowCtx, g),
              // 손잡이(≡)를 끌어 순서 바꾸기
              handle: Listener(
                // 손잡이를 끄는 동안에는 아래에서 올라온 창이 같이 내려가지 않게
                onPointerDown: (_) => BottomRise.holdPull(context, true),
                onPointerUp: (_) => BottomRise.holdPull(context, false),
                onPointerCancel: (_) => BottomRise.holdPull(context, false),
                child: ReorderableDragStartListener(
                index: index,
                child: SizedBox(
                  width: 40,
                  height: 46,
                  child: Icon(Icons.drag_handle, size: 20, color: sel ? AppColors.onSig(context) : cs.onSurfaceVariant.withValues(alpha: 0.7), shadows: sel ? AppColors.sigShadows(context) : null),
                ),
              ),
              ),
            ),
          ),
        );
      },
    );
    return Material(
      key: _panelKey,
      color: cs.surfaceContainerHigh,
      elevation: r.fromBottom ? 0 : 6,
      // 밑에서 올라오는 창은 바깥 창(BottomRise)이 모서리·막대를 그림
      borderRadius: r.fromBottom ? BorderRadius.zero : BorderRadius.circular(14),
      clipBehavior: Clip.antiAlias,
      child: Padding(
        padding: EdgeInsets.only(top: r.fromBottom ? 0 : 6, bottom: 6 + (r.fromBottom ? MediaQuery.paddingOf(context).bottom : 0)),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            _row(key: const ValueKey('dd:all'), value: '전체', leading: r.allLeading, label: r.allLabel),
            _row(
              key: const ValueKey('dd:fav'),
              value: kFavoritesGroupKey,
              leading: const FavoritesIcon(size: 20),
              label: r.favLabel,
            ),
            if (_groups.isNotEmpty) Divider(height: 9, indent: 12, endIndent: 12, color: cs.outlineVariant),
            Flexible(child: list),
            Divider(height: 9, indent: 12, endIndent: 12, color: cs.outlineVariant),
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 6),
              child: InkWell(
                borderRadius: BorderRadius.circular(10),
                onTap: () async {
                  final name = await r.onAdd();
                  if (name != null && mounted && !_groups.contains(name)) setState(() => _groups.add(name));
                },
                child: SizedBox(
                  height: 44,
                  child: Row(children: [
                    const SizedBox(width: 40),
                    SizedBox(width: 24, child: Icon(Icons.add, size: 20, color: cs.onSurfaceVariant)),
                    const SizedBox(width: 12),
                    Text(r.addLabel, style: TextStyle(fontSize: 15, color: cs.onSurfaceVariant, fontWeight: FontWeight.w600)),
                  ]),
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}
