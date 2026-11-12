import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import 'app_colors.dart';
import 'group_jump_menu.dart';
import 'ui_scale.dart';

/// 그룹 목록에서 [즐겨찾기]를 고르면 돌려주는 값
const String kFavoritesGroupKey = '__favorites__';

/// [☰ 그룹] 단추 바로 아래로 펼쳐지는 그룹 목록
/// - 맨 위 [전체] · [즐겨찾기]는 고정 (옮기기·꾹 누르기 없음)
/// - 나머지 그룹은 오른쪽 손잡이(≡)를 끌어 순서 바꾸기, 꾹 누르면 [이름 수정 / 그룹 삭제]
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
  });

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
  Color? get barrierColor => Colors.black.withValues(alpha: 0.18);

  @override
  bool get barrierDismissible => true;

  @override
  Duration get transitionDuration => kIconMotion;

  @override
  Duration get reverseTransitionDuration => const Duration(milliseconds: 160);

  @override
  Widget buildPage(BuildContext context, Animation<double> animation, Animation<double> secondaryAnimation) {
    final Size screen = MediaQuery.sizeOf(context);
    final EdgeInsets pad = MediaQuery.paddingOf(context);
    final double left = math.max(8.0, anchor.left);
    final double top = anchor.bottom + 6;
    final double maxH = math.max(160.0, screen.height - pad.bottom - 12 - top);
    final curved = CurvedAnimation(parent: animation, curve: kIconCurve, reverseCurve: Curves.easeInCubic);
    return Stack(children: [
      Positioned(
        left: left,
        top: top,
        child: AnimatedBuilder(
          animation: curved,
          builder: (context, child) => Opacity(
            opacity: curved.value.clamp(0.0, 1.0),
            child: Align(
              alignment: Alignment.topLeft,
              heightFactor: 0.6 + 0.4 * curved.value,
              child: Transform.translate(offset: Offset(0, -8 * (1 - curved.value)), child: child),
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
  final Map<String, GlobalKey> _nameKeys = {};

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
    final Color fg = sel ? Colors.white : cs.onSurface;
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
              SizedBox(width: 24, child: Center(child: leading)),
              const SizedBox(width: 12),
              Expanded(
                child: Align(
                  alignment: Alignment.centerLeft,
                  // 꾹 누르면 이 이름 바로 오른쪽에 편집 메뉴가 뜸
                  child: Text(label,
                      key: _nameKeys.putIfAbsent(value, GlobalKey.new),
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(fontSize: 15, color: fg, fontWeight: sel ? FontWeight.w700 : FontWeight.w500)),
                ),
              ),
              if (sel) const Padding(padding: EdgeInsets.only(left: 6), child: Icon(Icons.check, size: 18, color: Colors.white)),
              const SizedBox(width: 14),
            ]),
          ),
        ),
      ),
    );
  }

  Future<void> _groupMenu(BuildContext rowContext, String g) async {
    HapticFeedback.selectionClick();
    final nameCtx = _nameKeys[g]?.currentContext ?? rowContext;
    final action = await showScaleMenu<String>(nameCtx, [
      ('rename', r.renameLabel, Icons.edit_outlined, null),
      ('delete', r.deleteLabel, Icons.delete_outline, Colors.redAccent),
    ], beside: true);
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
              handle: ReorderableDragStartListener(
                index: index,
                child: SizedBox(
                  width: 40,
                  height: 46,
                  child: Icon(Icons.drag_handle, size: 20, color: sel ? Colors.white : cs.onSurfaceVariant.withValues(alpha: 0.7)),
                ),
              ),
            ),
          ),
        );
      },
    );
    return Material(
      color: cs.surfaceContainerHigh,
      elevation: 6,
      borderRadius: BorderRadius.circular(14),
      clipBehavior: Clip.antiAlias,
      child: Padding(
        padding: const EdgeInsets.symmetric(vertical: 6),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            _row(key: const ValueKey('dd:all'), value: '전체', leading: r.allLeading, label: r.allLabel),
            _row(
              key: const ValueKey('dd:fav'),
              value: kFavoritesGroupKey,
              leading: const Icon(Icons.bookmarks, color: Colors.amber, size: 20),
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
