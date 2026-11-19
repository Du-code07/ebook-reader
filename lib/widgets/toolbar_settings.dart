import 'dart:convert';
import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'app_colors.dart';
import 'pop_dialog.dart';
import 'quick_tool_bar.dart';

/// 파일 보기 화면의 상단바·도구 모음에 어떤 아이콘을 어떤 순서로 둘지 (모든 뷰어가 함께 씀)
/// - [top]: 상단바 (왼쪽부터, 숨기지 않은 것 최대 [maxTop]개)
/// - [bar]: 도구 모음 (왼쪽부터)
/// - [hidden]: 숨긴 아이콘
/// 뷰어마다 쓸 수 없는 아이콘(예: PDF가 아닌 파일의 글자 복사)은 목록에 있어도 그 뷰어에서는 보이지 않음
class ToolbarLayout {
  ToolbarLayout({required this.top, required this.bar, required this.hidden});

  final List<String> top;
  final List<String> bar;
  final Set<String> hidden;

  static const int maxTop = 5;
  static const String _key = 'toolbar_layout_v1';

  static const List<String> defaultTop = ['find', 'slideshow', 'theme', 'toc'];
  static const List<String> defaultBar = ['prev', 'next', 'rotate', 'display', 'mode', 'direction', 'memo', 'copy', 'bookmark'];

  /// 지금 쓰는 배치 (뷰어들이 함께 보고, 바뀌면 다시 그림)
  static final ValueNotifier<ToolbarLayout> current = ValueNotifier<ToolbarLayout>(ToolbarLayout.defaults());

  factory ToolbarLayout.defaults() => ToolbarLayout(top: List.of(defaultTop), bar: List.of(defaultBar), hidden: <String>{});

  ToolbarLayout copy() => ToolbarLayout(top: List.of(top), bar: List.of(bar), hidden: Set.of(hidden));

  /// 저장해 둔 배치를 읽음 (나중에 새로 생긴 아이콘은 도구 모음 끝에 붙임)
  static Future<void> load() async {
    try {
      final String? raw = (await SharedPreferences.getInstance()).getString(_key);
      if (raw == null) return;
      final Map<String, dynamic> m = jsonDecode(raw) as Map<String, dynamic>;
      final known = {...defaultTop, ...defaultBar};
      final List<String> top = [for (final e in (m['top'] as List? ?? const [])) if (known.contains(e)) e as String];
      final List<String> bar = [for (final e in (m['bar'] as List? ?? const [])) if (known.contains(e) && !top.contains(e)) e as String];
      for (final id in [...defaultTop, ...defaultBar]) {
        if (!top.contains(id) && !bar.contains(id)) bar.add(id);
      }
      final hidden = {for (final e in (m['hidden'] as List? ?? const [])) if (known.contains(e)) e as String};
      current.value = ToolbarLayout(top: top, bar: bar, hidden: hidden);
    } catch (_) {}
  }

  static Future<void> save(ToolbarLayout l) async {
    current.value = l;
    await (await SharedPreferences.getInstance()).setString(_key, jsonEncode({'top': l.top, 'bar': l.bar, 'hidden': l.hidden.toList()}));
  }

  /// [items] 가운데 [ids] 순서로, 숨기지 않은 것만
  List<QuickToolItem> pick(List<String> ids, Map<String, QuickToolItem> items) =>
      [for (final id in ids) if (!hidden.contains(id) && items[id] != null) items[id]!];

  /// 상단바에 보일 것 (5개까지)
  List<QuickToolItem> topFor(Map<String, QuickToolItem> items) => pick(top, items).take(maxTop).toList();

  /// 도구 모음에 보일 것 (다른 파일에서 정한 배치라 상단바에 다 못 들어간 것은 도구 모음 앞쪽에)
  List<QuickToolItem> barFor(Map<String, QuickToolItem> items) => [...pick(top, items).skip(maxTop), ...pick(bar, items)];
}

/// 도구 모음 설정 창 (화면 가운데): 상단바·도구 모음 아이콘의 순서를 끌어서 바꾸고, X로 숨기고 ✓로 다시 보이게 함
/// [items]: 이 뷰어에서 쓸 수 있는 아이콘 (id → 항목). 진행바 숨기기, [extra](예: EPUB 글자 크기)와 초기화도 함께
Future<void> showToolbarSettingsDialog(
  BuildContext context, {
  required String Function(String ko, String en, String zh, String ja) tr,
  required Map<String, QuickToolItem> items,
  required bool progressHidden,
  required ValueChanged<bool> onProgressHidden,
  required Future<void> Function() onReset,
  Widget Function(StateSetter setDlg)? extra,
}) {
  return showPopDialog(
    context: context,
    builder: (ctx) => _ToolbarSettings(tr: tr, items: items, progressHidden: progressHidden, onProgressHidden: onProgressHidden, onReset: onReset, extra: extra),
  );
}

class _ToolbarSettings extends StatefulWidget {
  const _ToolbarSettings({required this.tr, required this.items, required this.progressHidden, required this.onProgressHidden, required this.onReset, this.extra});
  final String Function(String ko, String en, String zh, String ja) tr;
  final Map<String, QuickToolItem> items;
  final bool progressHidden;
  final ValueChanged<bool> onProgressHidden;
  final Future<void> Function() onReset;
  final Widget Function(StateSetter setDlg)? extra;

  @override
  State<_ToolbarSettings> createState() => _ToolbarSettingsState();
}

class _ToolbarSettingsState extends State<_ToolbarSettings> {
  static const Color _bg = Color(0xFF1C1C1E);
  static const Color _line = Color(0x1FFFFFFF);
  static const String _topHead = '#top';
  static const String _barHead = '#bar';

  late ToolbarLayout _l = ToolbarLayout.current.value.copy();
  late bool _progressHidden = widget.progressHidden;
  String? _warn;

  /// 대표 색(다크 모드는 밝은 회색) 바탕 위 글씨: 라이트는 흰 굵은 글씨 + 옅은 그림자
  Color get _onMark => Theme.of(context).brightness == Brightness.dark ? Colors.black87 : Colors.white;

  String get _maxTopText => widget.tr('상단바에는 아이콘을 5개까지 둘 수 있어요', 'The top bar can hold up to 5 icons', '顶部栏最多可放 5 个图标', '上部バーには最大5個まで置けます');

  /// 이 뷰어에서 쓸 수 있는 것만
  List<String> _avail(List<String> ids) => [for (final id in ids) if (widget.items.containsKey(id)) id];
  int _visibleTop(ToolbarLayout l) => _avail(l.top).where((id) => !l.hidden.contains(id)).length;

  void _apply(ToolbarLayout l) {
    setState(() {
      _l = l;
      _warn = null;
    });
    ToolbarLayout.save(l);
  }

  /// 끌어서 놓았을 때 (newIndex는 뺀 뒤 자리): 머리줄(상단바·도구 모음)을 기준으로 다시 나눔
  void _onReorder(int oldIndex, int newIndex) {
    final List<String> flat = [_topHead, ..._avail(_l.top), _barHead, ..._avail(_l.bar)];
    if (oldIndex <= 0 || flat[oldIndex] == _barHead) return;
    final String id = flat.removeAt(oldIndex);
    flat.insert(newIndex.clamp(1, flat.length), id);
    final int split = flat.indexOf(_barHead);
    final List<String> topA = flat.sublist(1, split);
    final List<String> barA = flat.sublist(split + 1);
    // 이 뷰어에 없는 아이콘은 원래 목록의 끝에 그대로 둠
    final next = ToolbarLayout(
      top: [...topA, ..._l.top.where((e) => !widget.items.containsKey(e))],
      bar: [...barA, ..._l.bar.where((e) => !widget.items.containsKey(e))],
      hidden: Set.of(_l.hidden),
    );
    if (_visibleTop(next) > ToolbarLayout.maxTop) {
      setState(() => _warn = _maxTopText);
      return;
    }
    _apply(next);
  }

  void _toggleHidden(String id) {
    final next = _l.copy();
    if (next.hidden.contains(id)) {
      next.hidden.remove(id);
      if (next.top.contains(id) && _visibleTop(next) > ToolbarLayout.maxTop) {
        setState(() => _warn = _maxTopText);
        return;
      }
    } else {
      next.hidden.add(id);
    }
    _apply(next);
  }

  Widget _hideButton({required bool hidden, required VoidCallback onTap, required String label}) {
    return Semantics(
      button: true,
      label: label,
      child: InkResponse(
        onTap: onTap,
        radius: 22,
        child: Container(
          width: 32,
          height: 32,
          decoration: BoxDecoration(
            shape: BoxShape.circle,
            color: hidden ? AppColors.mark(context) : Colors.transparent,
          ),
          child: Icon(hidden ? Icons.check_rounded : Icons.close_rounded, size: 20, color: hidden ? _onMark : Colors.white70, shadows: hidden ? AppColors.sigShadows(context) : null),
        ),
      ),
    );
  }

  Widget _row(int index, String id) {
    final QuickToolItem it = widget.items[id]!;
    final bool hidden = _l.hidden.contains(id);
    return ReorderableDelayedDragStartListener(
      key: ValueKey('row-$id'),
      index: index,
      child: Container(
        height: 56,
        decoration: const BoxDecoration(color: _bg, border: Border(bottom: BorderSide(color: _line))),
        padding: const EdgeInsets.only(left: 4, right: 10),
        child: Row(
          children: [
            // 끌어서 순서 바꾸기 (줄을 길게 눌러도 됨)
            ReorderableDragStartListener(
              index: index,
              child: const SizedBox(width: 40, height: 56, child: Icon(Icons.drag_indicator, color: Colors.white38, size: 22)),
            ),
            Opacity(
              opacity: hidden ? 0.35 : 1,
              child: SizedBox(width: 30, child: Center(child: IconTheme.merge(data: const IconThemeData(color: Colors.white, size: 20), child: it.icon))),
            ),
            const SizedBox(width: 14),
            Expanded(
              child: Opacity(
                opacity: hidden ? 0.35 : 1,
                child: Text(it.label ?? it.tooltip, maxLines: 1, overflow: TextOverflow.ellipsis, style: const TextStyle(color: Colors.white, fontSize: 15.5, fontWeight: FontWeight.w600)),
              ),
            ),
            _hideButton(
              hidden: hidden,
              onTap: () => _toggleHidden(id),
              label: hidden ? widget.tr('다시 보이기', 'Show', '显示', '表示する') : widget.tr('숨기기', 'Hide', '隐藏', '隠す'),
            ),
          ],
        ),
      ),
    );
  }

  Widget _head(String key, String text, {String? trailing}) => Container(
        key: ValueKey(key),
        color: _bg,
        padding: const EdgeInsets.fromLTRB(16, 18, 18, 6),
        child: Row(
          children: [
            Expanded(child: Text(text, style: const TextStyle(color: Colors.white60, fontSize: 13.5, fontWeight: FontWeight.w700))),
            if (trailing != null) Text(trailing, style: const TextStyle(color: Colors.white38, fontSize: 12.5)),
          ],
        ),
      );

  /// 미리보기: 지금 배치대로 상단바와 도구 모음
  Widget _preview() {
    final topItems = _l.pick(_l.top, widget.items);
    final barItems = _l.pick(_l.bar, widget.items);
    Widget icons(List<QuickToolItem> list) => Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            for (final it in list)
              SizedBox(width: 34, height: 40, child: Center(child: IconTheme.merge(data: const IconThemeData(color: Colors.white, size: 19), child: it.icon))),
          ],
        );
    return Column(
      children: [
        // 상단바: 뒤로 + 파일 이름 + 아이콘
        Container(
          height: 44,
          padding: const EdgeInsets.symmetric(horizontal: 8),
          decoration: BoxDecoration(color: Colors.black87, borderRadius: BorderRadius.circular(12), border: Border.all(color: _line)),
          child: Row(
            children: [
              const Icon(Icons.arrow_back, color: Colors.white, size: 17),
              const SizedBox(width: 8),
              Expanded(
                child: Container(height: 8, margin: const EdgeInsets.only(right: 40), decoration: BoxDecoration(color: Colors.white24, borderRadius: BorderRadius.circular(4))),
              ),
              icons(topItems),
            ],
          ),
        ),
        const SizedBox(height: 10),
        // 도구 모음: 왼쪽부터, 끝에 도구 모음 설정 고정
        Container(
          height: 48,
          padding: const EdgeInsets.symmetric(horizontal: 8),
          decoration: BoxDecoration(color: const Color(0xEE1C1C1E), borderRadius: BorderRadius.circular(22), border: Border.all(color: Colors.white.withValues(alpha: 0.12))),
          child: Row(
            children: [
              Expanded(
                child: SingleChildScrollView(scrollDirection: Axis.horizontal, child: icons(barItems)),
              ),
              Container(width: 1, height: 22, color: Colors.white.withValues(alpha: 0.18)),
              const SizedBox(width: 34, child: Center(child: Icon(Icons.tune, color: Colors.white, size: 18))),
            ],
          ),
        ),
      ],
    );
  }

  @override
  Widget build(BuildContext context) {
    final tr = widget.tr;
    final List<String> topIds = _avail(_l.top);
    final List<String> barIds = _avail(_l.bar);
    final Size screen = MediaQuery.sizeOf(context);
    int i = 0;
    final List<Widget> rows = [
      _head(_topHead, tr('상단바', 'Top bar', '顶部栏', '上部バー'), trailing: '${_visibleTop(_l)} / ${ToolbarLayout.maxTop}'),
    ];
    i++;
    for (final id in topIds) {
      rows.add(_row(i++, id));
    }
    rows.add(_head(_barHead, tr('도구 모음', 'Toolbar', '工具栏', 'ツールバー')));
    i++;
    for (final id in barIds) {
      rows.add(_row(i++, id));
    }

    return Center(
      child: ConstrainedBox(
        constraints: BoxConstraints(maxWidth: math.min(460.0, screen.width - 32.0), maxHeight: screen.height * 0.88),
        child: Material(
          color: _bg,
          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(28), side: const BorderSide(color: _line)),
          clipBehavior: Clip.antiAlias,
          child: Padding(
            padding: const EdgeInsets.fromLTRB(0, 22, 0, 10),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                // 제목 + 완료
                Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 22),
                  child: Row(
                    children: [
                      Expanded(
                        child: Text(tr('도구 모음 설정', 'Toolbar Settings', '工具栏设置', 'ツールバー設定'),
                            style: const TextStyle(color: Colors.white, fontSize: 22, fontWeight: FontWeight.w800)),
                      ),
                      FilledButton(
                        style: FilledButton.styleFrom(backgroundColor: AppColors.mark(context), padding: const EdgeInsets.symmetric(horizontal: 22, vertical: 12)),
                        onPressed: () => Navigator.pop(context),
                        child: Text(tr('완료', 'Done', '完成', '完了'),
                            style: TextStyle(color: _onMark, fontWeight: FontWeight.bold, shadows: AppColors.sigShadows(context))),
                      ),
                    ],
                  ),
                ),
                const SizedBox(height: 8),
                Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 22),
                  child: Text(
                    tr('줄을 길게 누르거나 왼쪽 손잡이를 끌어 순서를 바꿔요\n상단바와 도구 모음 사이로도 옮길 수 있어요',
                        'Long-press a row or drag its handle to reorder\nYou can also move icons between the top bar and the toolbar',
                        '长按一行或拖动左侧手柄可调整顺序\n也可以在顶部栏和工具栏之间移动',
                        '行を長押しするか左のハンドルを引いて並べ替えます\n上部バーとツールバーの間でも移せます'),
                    style: const TextStyle(color: Colors.white54, fontSize: 13, height: 1.4),
                  ),
                ),
                const SizedBox(height: 14),
                Padding(padding: const EdgeInsets.symmetric(horizontal: 18), child: _preview()),
                if (_warn != null)
                  Padding(
                    padding: const EdgeInsets.fromLTRB(22, 10, 22, 0),
                    child: Text(_warn!, style: const TextStyle(color: Color(0xFFFFB4A9), fontSize: 13, fontWeight: FontWeight.w600)),
                  ),
                const SizedBox(height: 4),
                Flexible(
                  child: ReorderableListView(
                    shrinkWrap: true,
                    buildDefaultDragHandles: false,
                    onReorderItem: _onReorder,
                    // 끄는 줄: 시그니처 색 테두리
                    proxyDecorator: (child, index, anim) => Material(
                      color: Colors.transparent,
                      child: DecoratedBox(
                        position: DecorationPosition.foreground,
                        decoration: BoxDecoration(border: Border.all(color: AppColors.mark(context), width: 2), borderRadius: BorderRadius.circular(10)),
                        child: child,
                      ),
                    ),
                    footer: Column(
                      key: const ValueKey('footer'),
                      crossAxisAlignment: CrossAxisAlignment.stretch,
                      children: [
                        _head('#etc', tr('그 밖에', 'Others', '其他', 'その他')),
                        // 진행바: 숨기기 / 다시 보이기
                        Container(
                          height: 56,
                          padding: const EdgeInsets.only(left: 44, right: 10),
                          decoration: const BoxDecoration(border: Border(bottom: BorderSide(color: _line))),
                          child: Row(
                            children: [
                              Opacity(
                                opacity: _progressHidden ? 0.35 : 1,
                                child: const SizedBox(width: 30, child: Icon(Icons.linear_scale, color: Colors.white, size: 20)),
                              ),
                              const SizedBox(width: 14),
                              Expanded(
                                child: Opacity(
                                  opacity: _progressHidden ? 0.35 : 1,
                                  child: Text(tr('진행바', 'Progress Bar', '进度条', '進行度バー'),
                                      style: const TextStyle(color: Colors.white, fontSize: 15.5, fontWeight: FontWeight.w600)),
                                ),
                              ),
                              _hideButton(
                                hidden: _progressHidden,
                                label: _progressHidden ? tr('다시 보이기', 'Show', '显示', '表示する') : tr('숨기기', 'Hide', '隐藏', '隠す'),
                                onTap: () {
                                  setState(() => _progressHidden = !_progressHidden);
                                  widget.onProgressHidden(_progressHidden);
                                },
                              ),
                            ],
                          ),
                        ),
                        if (widget.extra != null) widget.extra!(setState),
                        const SizedBox(height: 8),
                        // 초기화: 아이콘 배치·숨김, 옮긴 도구 모음·메모 도구 모음·진행바·스크롤 막대 자리
                        Center(
                          child: TextButton.icon(
                            onPressed: () async {
                              await widget.onReset();
                              if (!mounted) return;
                              setState(() {
                                _l = ToolbarLayout.current.value.copy();
                                _progressHidden = false;
                                _warn = null;
                              });
                            },
                            icon: const Icon(Icons.restart_alt, color: Colors.white70, size: 20),
                            label: Text(tr('초기화', 'Reset', '重置', 'リセット'), style: const TextStyle(color: Colors.white70, fontWeight: FontWeight.w600)),
                          ),
                        ),
                      ],
                    ),
                    children: rows,
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}
