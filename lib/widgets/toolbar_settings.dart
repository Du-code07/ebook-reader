import 'dart:convert';
import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart' show HapticFeedback;
import 'package:shared_preferences/shared_preferences.dart';

import 'memo_tools.dart' show MemoToolIcon;
import 'morph_icons.dart' show MoonMorphIcon;
import 'quick_tool_bar.dart';
import 'ui_scale.dart';
import 'viewer_dialogs.dart' show PageModeIcon, ViewerSheetPull, ViewerSheetScope, pageDisplayGlyph, rotationGlyph, showViewerDialog, viewerPanel;

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

/// 도구 모음 설정 목록에 보일 아이콘 (테마 글자색으로, 이 파일에서 쓰지 않는 아이콘도 자리를 옮길 수 있게 모두)
Widget toolbarCatalogIcon(String id, Color color, {double size = 20}) => switch (id) {
      'find' => Icon(Icons.search, color: color, size: size),
      'slideshow' => Icon(Icons.slideshow, color: color, size: size),
      'theme' => MoonMorphIcon(filled: false, size: size, color: color),
      'toc' => Icon(Icons.list, color: color, size: size),
      'prev' => Icon(Icons.skip_previous_rounded, color: color, size: size + 1),
      'next' => Icon(Icons.skip_next_rounded, color: color, size: size + 1),
      'rotate' => rotationGlyph('auto', size: size, color: color),
      'display' => pageDisplayGlyph('auto', size: size, color: color),
      'mode' => PageModeIcon(mode: 'tap', size: size, color: color),
      'direction' => Icon(Icons.swap_horiz_rounded, color: color, size: size + 1),
      'memo' => MemoToolIcon(kind: 'memo', color: color, size: size + 2),
      'copy' => Icon(Icons.copy_all_outlined, color: color, size: size),
      _ => Icon(Icons.bookmarks_outlined, color: color, size: size),
    };

/// 도구 모음 설정 목록에 보일 이름
String toolbarCatalogLabel(String id, String Function(String ko, String en, String zh, String ja) tr) => switch (id) {
      'find' => tr('단어 검색', 'Find in File', '在文件中查找', 'ファイル内検索'),
      'slideshow' => tr('슬라이드 쇼', 'Slide Show', '幻灯片放映', 'スライドショー'),
      'theme' => tr('배경 색상', 'Background Color', '背景颜色', '背景色'),
      'toc' => tr('목차', 'Contents', '目录', '目次'),
      'prev' => tr('이전 파일로 이동', 'Previous File', '上一个文件', '前のファイル'),
      'next' => tr('다음 파일로 이동', 'Next File', '下一个文件', '次のファイル'),
      'rotate' => tr('화면 회전', 'Rotate Screen', '旋转屏幕', '画面回転'),
      'display' => tr('페이지 표시', 'Page Display', '页面显示', 'ページ表示'),
      'mode' => tr('페이지 이동', 'Page Turning', '翻页', 'ページ移動'),
      'direction' => tr('읽기 방향', 'Reading Direction', '阅读方向', '読む方向'),
      'memo' => tr('메모', 'Memo', '笔记', 'メモ'),
      'copy' => tr('글자 복사', 'Copy Text', '复制文字', '文字をコピー'),
      _ => tr('북마크', 'Bookmarks', '书签', 'ブックマーク'),
    };

/// 도구 모음 설정 창의 한 줄 (아이콘 + 이름 + 오른쪽 단추). 창 밖(EPUB 글자 크기 등)에서도 같은 모양으로 씀
Widget toolbarSettingsRow(BuildContext context, {required Widget icon, required String label, String? note, Widget? trailing, bool dim = false, Widget? leading}) {
  final cs = Theme.of(context).colorScheme;
  return Container(
    height: 56,
    decoration: BoxDecoration(border: Border(bottom: BorderSide(color: cs.outlineVariant.withValues(alpha: 0.5)))),
    padding: const EdgeInsets.only(right: 8),
    child: Row(
      children: [
        leading ?? const SizedBox(width: 40),
        Opacity(opacity: dim ? 0.35 : 1, child: SizedBox(width: 28, child: Center(child: icon))),
        const SizedBox(width: 12),
        Expanded(
          child: Opacity(
            opacity: dim ? 0.35 : 1,
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(label, maxLines: 1, overflow: TextOverflow.ellipsis, style: TextStyle(color: cs.onSurface, fontSize: 15, fontWeight: FontWeight.w600)),
                if (note != null) Text(note, maxLines: 1, overflow: TextOverflow.ellipsis, style: TextStyle(color: cs.onSurfaceVariant, fontSize: 11.5)),
              ],
            ),
          ),
        ),
        if (trailing != null) trailing,
      ],
    ),
  );
}

/// 도구 모음 설정 창 (화면 가운데): 상단바·도구 모음 아이콘의 순서를 끌어서 바꾸고, X로 숨기고 ✓로 다시 보이게 함
/// [items]: 이 파일에서 쓸 수 있는 아이콘 (id → 항목, 미리보기에 씀). 이 파일에서 안 쓰는 아이콘도 목록에서 자리를 옮길 수 있음
/// 바꾼 배치는 창을 닫을 때 파일 화면에 한 번에 적용 (창을 쓰는 동안 뒤 화면을 다시 그리지 않아 버벅이지 않게)
Future<void> showToolbarSettingsDialog(
  BuildContext context, {
  required String Function(String ko, String en, String zh, String ja) tr,
  required Map<String, QuickToolItem> items,
  required bool progressHidden,
  required ValueChanged<bool> onProgressHidden,
  required Future<void> Function() onReset,
  Widget Function(StateSetter setDlg)? extra,
}) async {
  ToolbarLayout? result;
  // 다른 설정 창(화면 회전 등)과 같은 움직임·빠르기
  await showViewerDialog<void>(
    context,
    (ctx) => _ToolbarSettings(
      tr: tr,
      items: items,
      progressHidden: progressHidden,
      onProgressHidden: onProgressHidden,
      onReset: onReset,
      extra: extra,
      onChanged: (l) => result = l,
    ),
  );
  if (result != null) await ToolbarLayout.save(result!);
}

class _ToolbarSettings extends StatefulWidget {
  const _ToolbarSettings({
    required this.tr,
    required this.items,
    required this.progressHidden,
    required this.onProgressHidden,
    required this.onReset,
    required this.onChanged,
    this.extra,
  });
  final String Function(String ko, String en, String zh, String ja) tr;
  final Map<String, QuickToolItem> items;
  final bool progressHidden;
  final ValueChanged<bool> onProgressHidden;
  final Future<void> Function() onReset;
  final ValueChanged<ToolbarLayout> onChanged;
  final Widget Function(StateSetter setDlg)? extra;

  @override
  State<_ToolbarSettings> createState() => _ToolbarSettingsState();
}

class _ToolbarSettingsState extends State<_ToolbarSettings> {
  static const String _topHead = '#top';
  static const String _barHead = '#bar';

  late ToolbarLayout _l = ToolbarLayout.current.value.copy();
  late bool _progressHidden = widget.progressHidden;
  String? _warn;
  Offset _grab = Offset.zero; // 잡은 줄 안에서 누른 자리 (앱 화면 크기를 바꿨을 때도 끄는 줄이 손가락 밑에 있게)

  String get _maxTopText => widget.tr('상단바에는 아이콘을 5개까지 둘 수 있어요', 'The top bar can hold up to 5 icons', '顶部栏最多可放 5 个图标', '上部バーには最大5個まで置けます');

  /// 상단바에서 숨기지 않은 아이콘 수 (이 파일에서 안 쓰는 아이콘도 셈)
  int _visibleTop(ToolbarLayout l) => l.top.where((id) => !l.hidden.contains(id)).length;

  void _apply(ToolbarLayout l) {
    setState(() {
      _l = l;
      _warn = null;
    });
    widget.onChanged(l);
  }

  /// 끌어서 놓았을 때 (newIndex는 뺀 뒤 자리): 머리줄(상단바·도구 모음)을 기준으로 다시 나눔
  void _onReorder(int oldIndex, int newIndex) {
    final List<String> flat = [_topHead, ..._l.top, _barHead, ..._l.bar];
    if (oldIndex <= 0 || flat[oldIndex] == _barHead) return;
    final String id = flat.removeAt(oldIndex);
    flat.insert(newIndex.clamp(1, flat.length), id);
    final int split = flat.indexOf(_barHead);
    final next = ToolbarLayout(top: flat.sublist(1, split), bar: flat.sublist(split + 1), hidden: Set.of(_l.hidden));
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

  /// 보이는 아이콘은 ✓, 숨긴 아이콘은 X. 누르면 바뀜
  Widget _hideButton({required bool hidden, required VoidCallback onTap}) {
    final cs = Theme.of(context).colorScheme;
    return Semantics(
      button: true,
      label: hidden ? widget.tr('숨김 (누르면 보이기)', 'Hidden (tap to show)', '已隐藏（点按显示）', '非表示(タップで表示)') : widget.tr('보임 (누르면 숨기기)', 'Shown (tap to hide)', '已显示（点按隐藏）', '表示中(タップで非表示)'),
      child: InkResponse(
        onTap: onTap,
        radius: 22,
        child: SizedBox(
          width: 36,
          height: 36,
          child: Icon(hidden ? Icons.close_rounded : Icons.check_rounded, size: hidden ? 20 : 22, color: hidden ? cs.onSurfaceVariant : cs.primary),
        ),
      ),
    );
  }

  Widget _row(int index, String id) {
    final cs = Theme.of(context).colorScheme;
    final bool hidden = _l.hidden.contains(id);
    final bool here = widget.items.containsKey(id);
    return Builder(
      key: ValueKey('row-$id'),
      builder: (rowCtx) => Listener(
        // 잡은 자리를 기억 (끄는 줄이 손가락 밑에 정확히 있게)
        onPointerDown: (e) {
          final box = rowCtx.findRenderObject();
          if (box is RenderBox && box.hasSize) _grab = box.globalToLocal(e.position);
        },
        child: ReorderableDelayedDragStartListener(
          index: index,
          child: Material(
            color: Colors.transparent,
            child: toolbarSettingsRow(
              context,
              // 손잡이(≡): 그룹 목록의 손잡이와 같은 모양, 끌어서 순서 바꾸기 (줄을 길게 눌러도 됨)
              // 손잡이를 끄는 동안 밑에서 올라온 창이 같이 내려가지 않게
              leading: Listener(
                onPointerDown: (_) => ViewerSheetPull.hold(rowCtx, true),
                onPointerUp: (_) => ViewerSheetPull.hold(rowCtx, false),
                onPointerCancel: (_) => ViewerSheetPull.hold(rowCtx, false),
                child: ReorderableDragStartListener(
                  index: index,
                  child: SizedBox(width: 40, height: 56, child: Icon(Icons.drag_handle, size: 20, color: cs.onSurfaceVariant.withValues(alpha: 0.7))),
                ),
              ),
              icon: toolbarCatalogIcon(id, cs.onSurface),
              label: toolbarCatalogLabel(id, widget.tr),
              // 이 파일에서는 쓰지 않는 아이콘: 자리만 옮겨 두고 이 파일에서는 보이지 않음
              note: here ? null : widget.tr('이 파일 형식에서는 보이지 않아요', 'Not shown for this file type', '此文件类型中不显示', 'このファイル形式では表示されません'),
              dim: hidden,
              trailing: _hideButton(hidden: hidden, onTap: () => _toggleHidden(id)),
            ),
          ),
        ),
      ),
    );
  }

  Widget _head(String key, String text, {String? trailing}) {
    final cs = Theme.of(context).colorScheme;
    return Container(
      key: ValueKey(key),
      padding: const EdgeInsets.fromLTRB(16, 16, 18, 6),
      child: Row(
        children: [
          Expanded(child: Text(text, style: TextStyle(color: cs.onSurfaceVariant, fontSize: 13, fontWeight: FontWeight.w700))),
          if (trailing != null) Text(trailing, style: TextStyle(color: cs.onSurfaceVariant.withValues(alpha: 0.8), fontSize: 12)),
        ],
      ),
    );
  }

  /// 미리보기: 지금 배치대로 이 파일의 상단바와 도구 모음 (파일 화면처럼 검은 바탕)
  Widget _preview() {
    // 이 파일에서 안 쓰는 아이콘도 미리보기에는 보임 (실제 파일 화면에서는 안 보임)
    final List<String> shownTop = [for (final id in _l.top) if (!_l.hidden.contains(id)) id];
    final List<String> topIds = shownTop.take(ToolbarLayout.maxTop).toList();
    final List<String> barIds = [...shownTop.skip(ToolbarLayout.maxTop), for (final id in _l.bar) if (!_l.hidden.contains(id)) id];
    Widget icons(List<String> ids) => Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            for (final id in ids)
              SizedBox(
                width: 30,
                height: 36,
                child: Center(
                  child: widget.items[id] != null
                      ? IconTheme.merge(data: const IconThemeData(color: Colors.white, size: 18), child: widget.items[id]!.icon)
                      : toolbarCatalogIcon(id, Colors.white, size: 18),
                ),
              ),
          ],
        );
    return Column(
      children: [
        Container(
          height: 40,
          padding: const EdgeInsets.symmetric(horizontal: 8),
          decoration: BoxDecoration(color: Colors.black87, borderRadius: BorderRadius.circular(12)),
          child: Row(
            children: [
              const Icon(Icons.arrow_back, color: Colors.white, size: 16),
              const SizedBox(width: 8),
              Expanded(
                child: Container(height: 7, margin: const EdgeInsets.only(right: 24), decoration: BoxDecoration(color: Colors.white24, borderRadius: BorderRadius.circular(4))),
              ),
              icons(topIds),
            ],
          ),
        ),
        const SizedBox(height: 8),
        Container(
          height: 44,
          padding: const EdgeInsets.symmetric(horizontal: 6),
          decoration: BoxDecoration(color: const Color(0xEE1C1C1E), borderRadius: BorderRadius.circular(22)),
          child: Row(
            children: [
              // 도구 모음: 아이콘 수에 맞춰 막대를 꽉 채워 고르게 (다 들어가지 않으면 왼쪽부터 밀어서 보기)
              Expanded(
                child: LayoutBuilder(builder: (context, c) {
                  if (barIds.isEmpty || barIds.length * 30.0 > c.maxWidth) {
                    return SingleChildScrollView(scrollDirection: Axis.horizontal, child: icons(barIds));
                  }
                  return Row(children: [
                    for (final id in barIds)
                      Expanded(
                        child: SizedBox(
                          height: 36,
                          child: Center(
                            child: widget.items[id] != null
                                ? IconTheme.merge(data: const IconThemeData(color: Colors.white, size: 18), child: widget.items[id]!.icon)
                                : toolbarCatalogIcon(id, Colors.white, size: 18),
                          ),
                        ),
                      ),
                  ]);
                }),
              ),
              Container(width: 1, height: 20, color: Colors.white.withValues(alpha: 0.18)),
              const SizedBox(width: 30, child: Center(child: Icon(Icons.tune, color: Colors.white, size: 17))),
            ],
          ),
        ),
      ],
    );
  }

  @override
  Widget build(BuildContext context) {
    final tr = widget.tr;
    final cs = Theme.of(context).colorScheme;
    final double uiScale = UiScale.of(context);
    final Size screen = MediaQuery.sizeOf(context);
    int i = 0;
    final List<Widget> rows = [_head(_topHead, tr('상단바', 'Top bar', '顶部栏', '上部バー'), trailing: '${_visibleTop(_l)} / ${ToolbarLayout.maxTop}')];
    i++;
    for (final id in _l.top) {
      rows.add(_row(i++, id));
    }
    rows.add(_head(_barHead, tr('도구 모음', 'Toolbar', '工具栏', 'ツールバー')));
    i++;
    for (final id in _l.bar) {
      rows.add(_row(i++, id));
    }

    // 가운데 창: 화면 회전 창과 같은 너비 / 기본 스타일: 밑에서 올라오는 창
    final bool sheet = ViewerSheetScope.of(context);
    final Widget panel = viewerPanel(
          context,
          color: cs.surfaceContainerHigh,
          radius: 26,
          width: math.min(460.0, screen.width - 40.0),
          maxHeight: screen.height * 0.72,
          child: Padding(
            padding: EdgeInsets.fromLTRB(0, sheet ? 4 : 18, 0, 6),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                // 제목 + 초기화
                Padding(
                  padding: const EdgeInsets.only(left: 18, right: 14),
                  child: Row(
                    children: [
                      Expanded(
                        child: Text(tr('도구 모음 설정', 'Toolbar Settings', '工具栏设置', 'ツールバー設定'),
                            style: TextStyle(color: cs.onSurface, fontSize: 19, fontWeight: FontWeight.w800)),
                      ),
                      // 초기화: 아이콘 배치·숨김, 진행바 보이기, 옮긴 도구 모음·메모 도구 모음·진행바·스크롤 막대 자리
                      TextButton.icon(
                        style: TextButton.styleFrom(
                          foregroundColor: cs.onSurface,
                          padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
                          minimumSize: const Size(0, 36),
                        ),
                        icon: const Icon(Icons.restart_alt_rounded, size: 20),
                        onPressed: () async {
                          await widget.onReset();
                          if (!mounted) return;
                          setState(() {
                            _l = ToolbarLayout.defaults();
                            _progressHidden = false;
                            _warn = null;
                          });
                          widget.onChanged(_l);
                        },
                        label: Text(tr('초기화', 'Reset', '重置', 'リセット'), style: const TextStyle(fontWeight: FontWeight.bold)),
                      ),
                    ],
                  ),
                ),
                const SizedBox(height: 6),
                Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 18),
                  child: Text(
                    tr('줄을 길게 누르거나 손잡이를 끌어 순서를 바꿔요\n✓는 보이는 아이콘, X는 숨긴 아이콘이에요 (눌러서 바꿔요)',
                        'Long-press a row or drag its handle to reorder\n✓ means shown and X means hidden (tap to switch)',
                        '长按一行或拖动手柄可调整顺序\n✓ 表示显示，X 表示隐藏（点按切换）',
                        '行を長押しするかハンドルを引いて並べ替えます\n✓は表示、Xは非表示です(タップで切り替え)'),
                    style: TextStyle(color: cs.onSurfaceVariant, fontSize: 12.5, height: 1.4),
                  ),
                ),
                const SizedBox(height: 12),
                Padding(padding: const EdgeInsets.symmetric(horizontal: 14), child: _preview()),
                if (_warn != null)
                  Padding(
                    padding: const EdgeInsets.fromLTRB(18, 8, 18, 0),
                    child: Text(_warn!, style: TextStyle(color: cs.error, fontSize: 12.5, fontWeight: FontWeight.w600)),
                  ),
                // 목록 높이를 미리 정해 둠: 끄는 동안 창 높이가 바뀌어 들썩이지 않게 (화면보다 크면 창 안에서 스크롤)
                Flexible(
                  child: SizedBox(
                  height: (_l.top.length + _l.bar.length) * 56.0 + 3 * 42.0 + 56.0 + (widget.extra != null ? 56.0 : 0.0) + 8.0,
                  child: ReorderableListView(
                    buildDefaultDragHandles: false,
                    padding: EdgeInsets.zero,
                    onReorderStart: (_) => HapticFeedback.selectionClick(),
                    onReorderItem: _onReorder,
                    // 끄는 줄: 손가락 밑에 정확히 (앱 화면 크기를 바꿨을 때도), 살짝 떠오름
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
                    footer: Column(
                      key: const ValueKey('footer'),
                      crossAxisAlignment: CrossAxisAlignment.stretch,
                      children: [
                        _head('#etc', tr('그 밖에', 'Others', '其他', 'その他')),
                        // 진행바: 숨기기 / 다시 보이기
                        toolbarSettingsRow(
                          context,
                          icon: Icon(Icons.linear_scale, color: cs.onSurface, size: 20),
                          label: tr('페이지 막대', 'Page Bar', '页面条', 'ページバー'),
                          dim: _progressHidden,
                          trailing: _hideButton(
                            hidden: _progressHidden,
                            onTap: () {
                              setState(() => _progressHidden = !_progressHidden);
                              widget.onProgressHidden(_progressHidden);
                            },
                          ),
                        ),
                        if (widget.extra != null) widget.extra!(setState),
                        const SizedBox(height: 4),
                      ],
                    ),
                    children: rows,
                  ),
                  ),
                ),
              ],
            ),
          ),
    );
    return sheet ? panel : Center(child: panel);
  }
}
