import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'app_colors.dart';

/// Fixed above the worksheet: dragging these tabs never scrolls the grid.
/// Every sheet is present, including names wider than the available screen.
class SpreadsheetTabBar extends StatefulWidget {
  const SpreadsheetTabBar({
    super.key,
    required this.names,
    required this.selectedIndex,
    required this.onSelected,
    this.atBottom = false,
  });

  /// 화면 아래에 둘 때: 고른 시트 표시 줄을 위쪽에 (엑셀 앱처럼)
  final bool atBottom;

  final List<String> names;
  final int selectedIndex;
  final ValueChanged<int> onSelected;

  @override
  State<SpreadsheetTabBar> createState() => _SpreadsheetTabBarState();
}

class _SpreadsheetTabBarState extends State<SpreadsheetTabBar> {
  final List<GlobalKey> _keys = [];
  double? _width;

  void _revealSelected() {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted || widget.selectedIndex < 0 || widget.selectedIndex >= _keys.length) return;
      final tabContext = _keys[widget.selectedIndex].currentContext;
      if (tabContext != null) {
        Scrollable.ensureVisible(tabContext,
            alignment: .5, duration: const Duration(milliseconds: 180));
      }
    });
  }

  @override
  void didUpdateWidget(covariant SpreadsheetTabBar oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.selectedIndex != widget.selectedIndex || !listEquals(oldWidget.names, widget.names)) {
      _revealSelected();
    }
  }

  @override
  Widget build(BuildContext context) {
    while (_keys.length < widget.names.length) {
      _keys.add(GlobalKey());
    }
    // 서재 위 그룹 칩과 같은 모양 (둥근 네모 테두리 + 아이콘, 고른 시트는 채움)
    return SizedBox(
      height: 56,
      child: LayoutBuilder(builder: (context, constraints) {
        if (_width != constraints.maxWidth) {
          _width = constraints.maxWidth;
          _revealSelected();
        }
        return SingleChildScrollView(
          scrollDirection: Axis.horizontal,
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
          child: Row(children: [
            for (int i = 0; i < widget.names.length; i++)
              Padding(
                key: _keys[i],
                padding: EdgeInsets.only(right: i == widget.names.length - 1 ? 0 : 8),
                child: ChoiceChip(
                  showCheckmark: false,
                  label: Text(widget.names[i], maxLines: 1, style: TextStyle(shadows: i == widget.selectedIndex ? AppColors.sigShadows(context) : null)),
                  selected: i == widget.selectedIndex,
                  onSelected: (_) => widget.onSelected(i),
                ),
              ),
          ]),
        );
      }),
    );
  }
}
