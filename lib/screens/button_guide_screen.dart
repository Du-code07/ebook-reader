import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';

import '../services/pro.dart';
import '../services/storage_service.dart';
import '../widgets/app_colors.dart';
import '../widgets/direction_arrow_icon.dart';
import '../widgets/favorite_ribbon.dart';
import '../widgets/file_type_icon.dart';
import '../widgets/group_stack_icon.dart';
import '../widgets/memo_tools.dart';
import '../widgets/morph_icons.dart';
import '../widgets/push_aside_route.dart';
import '../widgets/viewer_dialogs.dart';

typedef _Tr = String Function(String ko, String en, String zh, String ja);

/// 도움말 '가이드': 예시 화면 위에서 단추를 하나씩 비추며 알려 주는 가이드
/// (메인 화면 / 파일 상단바·도구 모음 / 메모 도구 모음 / 설정)
class ButtonGuideScreen extends StatelessWidget {
  const ButtonGuideScreen({super.key, required this.appLang});
  final String appLang;

  String _tr(String ko, String en, String zh, String ja) => AppI18n.t(appLang, ko: ko, en: en, zh: zh, ja: ja);

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final guides = <(_GuideKind, Widget, String, String)>[
      (_GuideKind.main, Icon(Icons.home_outlined, color: cs.onSurface), _tr('메인 화면', 'Main Screen', '主界面', 'メイン画面'),
          _tr('그룹·검색·파일 추가·휴지통·설정과 파일 다루기', 'Groups, search, adding files, trash, settings and files', '分组·搜索·添加文件·回收站·设置和文件操作', 'グループ・検索・ファイル追加・ゴミ箱・設定とファイル操作')),
      (_GuideKind.viewer, Icon(Icons.view_agenda_outlined, color: cs.onSurface), _tr('파일 상단·도구 모음 막대', 'File Top & Tool Bar', '文件顶部·工具栏', 'ファイル上部・ツールバー'),
          _tr('파일을 볼 때 쓰는 단추', 'Buttons you use while reading a file', '阅读文件时使用的按钮', 'ファイルを見るときに使うボタン')),
      (_GuideKind.memo, MemoToolIcon(kind: 'memo', color: cs.onSurface, size: 24), _tr('메모 도구 막대', 'Memo Tool Bar', '笔记工具栏', 'メモツールバー'),
          _tr('펜·지우개·스티커 등 메모 도구', 'Pen, eraser, sticker and other memo tools', '笔·橡皮擦·贴纸等笔记工具', 'ペン・消しゴム・ステッカーなどのメモツール')),
      (_GuideKind.settings, SpinGearIcon(turns: 0, color: cs.onSurface), _tr('설정', 'Settings', '设置', '設定'),
          _tr('앱 설정의 항목', 'Items in the app settings', '应用设置中的各项', 'アプリ設定の項目')),
    ];
    return Scaffold(
      appBar: AppBar(title: Text(_tr('가이드', 'Guide', '指南', 'ガイド'), style: const TextStyle(fontWeight: FontWeight.w800))),
      body: SafeArea(
        child: ListView(
          padding: const EdgeInsets.fromLTRB(16, 4, 16, 24),
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(4, 0, 4, 12),
              child: Text(
                _tr('고르면 예시 화면에서 단추를 하나씩 알려 줘요', 'Pick one to see each button explained on a sample screen', '选择后会在示例画面上逐个介绍按钮', '選ぶと見本の画面でボタンを一つずつ説明します'),
                style: TextStyle(fontSize: 14, color: cs.onSurfaceVariant),
              ),
            ),
            for (final (kind, icon, title, sub) in guides)
              Padding(
                padding: const EdgeInsets.symmetric(vertical: 5),
                child: Material(
                  color: cs.surfaceContainerHigh,
                  borderRadius: BorderRadius.circular(16),
                  clipBehavior: Clip.antiAlias,
                  child: ListTile(
                    contentPadding: const EdgeInsets.symmetric(horizontal: 18, vertical: 8),
                    leading: SizedBox(width: 28, child: Center(child: icon)),
                    title: Text(title, style: const TextStyle(fontSize: 16.5, fontWeight: FontWeight.w800)),
                    subtitle: Text(sub, style: TextStyle(fontSize: 13.5, color: cs.onSurfaceVariant)),
                    trailing: Icon(Icons.play_circle_outline, color: cs.onSurfaceVariant),
                    onTap: () => Navigator.push(
                      context,
                      PushAsideRoute(builder: (_) => _GuideRunner(kind: kind, tr: _tr)),
                    ),
                  ),
                ),
              ),
          ],
        ),
      ),
    );
  }
}

enum _GuideKind { main, viewer, memo, settings }

/// 가이드 한 단계: 비출 단추와 설명
class _Step {
  const _Step(this.id, this.title, this.desc);
  final String id;
  final String title;
  final String desc;
}

class _GuideRunner extends StatefulWidget {
  const _GuideRunner({required this.kind, required this.tr});
  final _GuideKind kind;
  final _Tr tr;

  @override
  State<_GuideRunner> createState() => _GuideRunnerState();
}

class _GuideRunnerState extends State<_GuideRunner> with TickerProviderStateMixin {
  final Map<String, GlobalKey> _keys = {};
  final GlobalKey _stageKey = GlobalKey();
  late final List<_Step> _steps = _buildSteps();
  int _i = 0;
  Rect? _from;
  Rect? _to;
  late final AnimationController _move = AnimationController(vsync: this, duration: Anim.ms(320))..addListener(() => setState(() {}));
  // 누르는 흉내: 단추 둘레로 퍼지는 고리
  late final AnimationController _pulse = AnimationController(vsync: this, duration: const Duration(milliseconds: 1400));
  late final bool _simple = StorageService.simpleStyle;

  _Tr get tr => widget.tr;
  GlobalKey _k(String id) => _keys.putIfAbsent(id, GlobalKey.new);

  @override
  void initState() {
    super.initState();
    if (!Anim.off.value) _pulse.repeat();
    WidgetsBinding.instance.addPostFrameCallback((_) => _focus());
  }

  @override
  void dispose() {
    _move.dispose();
    _pulse.dispose();
    super.dispose();
  }

  Rect? get _hole {
    if (_to == null) return null;
    if (_from == null) return _to;
    return Rect.lerp(_from, _to, Curves.easeOutCubic.transform(_move.value));
  }

  /// 지금 단계의 단추를 찾아(목록 안이면 보이게 굴려서) 비춤
  Future<void> _focus() async {
    final ctx = _keys[_steps[_i].id]?.currentContext;
    if (ctx == null || !mounted) return;
    if (Scrollable.maybeOf(ctx) != null) {
      await Scrollable.ensureVisible(ctx, alignment: 0.35, duration: Anim.ms(280), curve: Curves.easeOutCubic);
      await WidgetsBinding.instance.endOfFrame; // 굴린 자리가 화면에 그려진 뒤에 재기
    }
    if (!mounted) return;
    final box = ctx.findRenderObject() as RenderBox?;
    final stage = _stageKey.currentContext?.findRenderObject() as RenderBox?;
    if (box == null || stage == null || !box.hasSize) return;
    final Rect r = _spotRect(box, stage);
    setState(() {
      _from = _hole ?? r;
      _to = r;
    });
    _move.forward(from: 0);
  }

  /// 비출 자리: 작은 단추는 그림(아이콘·글자) 크기에 맞춘 네모로 그림이 정가운데 오게,
  /// 넓은 자리(목록·쪽 등)는 그 자리 그대로. 어느 쪽이든 화면 밖으로 나가 잘리지 않게 맞춤
  Rect _spotRect(RenderBox box, RenderBox stage) {
    Rect toStage(RenderBox b) => MatrixUtils.transformRect(b.getTransformTo(stage), Offset.zero & b.size);
    final Rect whole = toStage(box);
    final Rect bounds = (Offset.zero & stage.size).deflate(6);
    Rect spot;
    if (whole.longestSide <= 96) {
      // 단추 안에서 눈에 보이는 그림만 모음. 선택 표시 선처럼 가는 장식은 가운데를 정할 때 빼고, 비추는 네모 안에는 들어가게
      Rect? art;
      final List<Rect> thin = [];
      void visit(RenderObject o) {
        if (o is RenderBox && o.hasSize && o.size.shortestSide > 0) {
          final bool painted = o is RenderDecoratedBox && o.decoration is BoxDecoration &&
              ((o.decoration as BoxDecoration).color != null || (o.decoration as BoxDecoration).border != null);
          if (painted && o.size.shortestSide < 12) thin.add(toStage(o));
          final bool decorated = painted && o.size.shortestSide >= 12;
          if (o is RenderParagraph || o is RenderImage || decorated || (o is RenderCustomPaint && (o.painter != null || o.foregroundPainter != null))) {
            final Rect rr = toStage(o);
            art = art == null ? rr : art!.expandToInclude(rr);
            if (!decorated) return;
          }
        }
        o.visitChildren(visit);
      }
      visit(box);
      final Rect a = art ?? whole;
      final double ratio = a.width / math.max(1.0, a.height);
      spot = ratio >= 0.5 && ratio <= 2
          ? Rect.fromCenter(center: a.center, width: math.max(a.width, a.height) + 16, height: math.max(a.width, a.height) + 16)
          : a.inflate(8);
      for (final t in thin) {
        final double hx = math.max(spot.width / 2, math.max((t.left - spot.center.dx).abs(), (t.right - spot.center.dx).abs()) + 5);
        final double hy = math.max(spot.height / 2, math.max((t.top - spot.center.dy).abs(), (t.bottom - spot.center.dy).abs()) + 5);
        spot = Rect.fromCenter(center: spot.center, width: hx * 2, height: hy * 2);
      }
      // 화면 끝에 닿으면 가운데는 그대로 두고 크기만 줄여 맞춤 (그래도 넘치면 안으로 밀기)
      final Offset c = spot.center;
      final double hw = math.max(math.min(spot.width / 2, math.min(c.dx - bounds.left, bounds.right - c.dx)), a.width / 2 + 3);
      final double hh = math.max(math.min(spot.height / 2, math.min(c.dy - bounds.top, bounds.bottom - c.dy)), a.height / 2 + 3);
      spot = Rect.fromCenter(center: c, width: hw * 2, height: hh * 2);
      final double dx = spot.left < bounds.left ? bounds.left - spot.left : (spot.right > bounds.right ? bounds.right - spot.right : 0);
      final double dy = spot.top < bounds.top ? bounds.top - spot.top : (spot.bottom > bounds.bottom ? bounds.bottom - spot.bottom : 0);
      spot = spot.shift(Offset(dx, dy));
    } else {
      spot = whole.inflate(6).intersect(bounds);
    }
    return spot;
  }

  void _go(int d) {
    final int n = _i + d;
    if (n < 0) return;
    if (n >= _steps.length) {
      Navigator.pop(context);
      return;
    }
    setState(() => _i = n);
    _focus();
  }

  // ── 단계 ──
  List<_Step> _buildSteps() {
    switch (widget.kind) {
      case _GuideKind.main:
        final simple = StorageService.simpleStyle;
        return [
          _Step('group', tr('그룹', 'Groups', '分组', 'グループ'),
              simple
                  ? tr('누르면 [그룹 목록]이 열리고, 새 그룹도 추가할 수 있어요\n추가한 그룹은 길게 눌러 순서를 바꾸고, ⋯을 눌러 이름을 바꾸거나 삭제할 수 있어요',
                      'Tap to open [Group List] and add new groups\nLong-press added groups to reorder them, or tap ⋯ to rename or delete',
                      '点击打开[分组列表]，也可添加新分组\n长按已添加的分组可调整顺序，点击 ⋯ 可重命名或删除',
                      'タップすると[グループ一覧]が開き、新しいグループも追加できます\n追加したグループは長押しで並べ替え、⋯で名前の変更や削除ができます')
                  : tr('누르면 [즐겨찾기]와 [그룹 목록]이 열리고, 새 그룹도 추가할 수 있어요\n추가한 그룹은 길게 눌러 순서를 바꾸고, ⋯을 눌러 이름을 바꾸거나 삭제할 수 있어요',
                      'Tap to open [Favorites] and [Group List], and add new groups\nLong-press added groups to reorder them, or tap ⋯ to rename or delete',
                      '点击打开[收藏]和[分组列表]，也可添加新分组\n长按已添加的分组可调整顺序，点击 ⋯ 可重命名或删除',
                      'タップすると[お気に入り]と[グループ一覧]が開き、新しいグループも追加できます\n追加したグループは長押しで並べ替え、⋯で名前の変更や削除ができます')),
          if (simple)
            _Step('fav', tr('즐겨찾기', 'Favorites', '收藏', 'お気に入り'),
                tr('즐겨찾기한 파일만 모아 봐요', 'View only your favorite files', '只查看收藏的文件', 'お気に入りのファイルだけを集めて見ます')),
          if (simple)
            _Step('pin', tr('그룹 꺼내기', 'Pin Groups', '放出分组', 'グループを置く'),
                tr('자주 보는 그룹을 꺼낼 수 있어요', 'Pin groups you view often', '可以把常用的分组放出来', 'よく見るグループを外に出しておけます')),
          _Step('search', tr('검색', 'Search', '搜索', '検索'),
              tr('파일 이름을 검색해서 찾을 수 있어요', 'Search for files by name', '可按文件名搜索查找', 'ファイル名を検索して探せます')),
          if (!simple)
            _Step('add', tr('파일 추가', 'Add Files', '添加文件', 'ファイル追加'),
                tr('여러 방식으로 파일을 추가할 수 있어요\n[정렬]을 통해 파일 순서도 변경할 수 있어요',
                    'Add files in multiple ways\nYou can also change the file order using [Sort]',
                    '可以通过多种方式添加文件\n也可以通过[排序]更改文件顺序',
                    'いろいろな方法でファイルを追加できます\n[並べ替え]でファイルの順番も変えられます')),
          _Step('trash', tr('휴지통', 'Trash', '回收站', 'ゴミ箱'),
              tr('파일을 지워도 바로 사라지지 않고 휴지통으로 옮겨져요\n휴지통에서 지운 파일을 다시 되살리거나 완전히 비울 수 있어요',
                  'Deleted files move to Trash instead of disappearing right away\nRestore deleted files or empty them permanently from Trash',
                  '删除的文件不会立刻消失，而是移至回收站\n可在回收站中恢复已删文件或彻底清空',
                  'ファイルを削除してもすぐには消えず、ゴミ箱に移動します\nゴミ箱で復元するか完全に空にできます')),
          if (!simple) _settingsStep(),
          if (simple) ...[
            _settingsStep(),
            _Step('add', tr('파일 추가', 'Add Files', '添加文件', 'ファイル追加'),
                tr('여러 방식으로 파일을 추가할 수 있어요\n[정렬]을 통해 파일 순서도 변경할 수 있어요',
                    'Add files in multiple ways\nYou can also change the file order using [Sort]',
                    '可以通过多种方式添加文件\n也可以通过[排序]更改文件顺序',
                    'いろいろな方法でファイルを追加できます\n[並べ替え]でファイルの順番も変えられます')),
          ],
          _Step('list', tr('새로 고침', 'Refresh', '刷新', '更新'),
              tr('목록을 맨 위에서 아래로 당기면 새로 고침 아이콘이 나오며 서재를 다시 읽어 와요', 'Pull the list down from the top to show the refresh icon and reload your library', '从顶部向下拉列表，会出现刷新图标并重新读取书架', '一覧を一番上から下に引くと更新アイコンが出て、書斎を読み込み直します')),
          _Step('ribbon', tr('즐겨찾기 띠', 'Favorite Ribbon', '收藏书签', 'お気に入りリボン'),
              tr('누르거나 아래로 당기면 즐겨찾기에 넣거나 뺄 수 있어요', 'Tap or pull down to add or remove from favorites', '点击或向下拉即可加入或移出收藏', 'タップするか下に引くとお気に入りに入れたり外したりできます')),
          _Step('card', tr('파일', 'File', '文件', 'ファイル'),
              tr('파일을 길게 눌러 여러 개를 고른 뒤 한꺼번에 옮길 수 있어요',
                  'Long-press to select multiple files and move them all at once',
                  '长按选择多个文件后可一次性移动',
                  'ファイルを長押しして複数選び、まとめて移動できます')),
          _Step('more', tr('파일 메뉴', 'File Menu', '文件菜单', 'ファイルメニュー'),
              tr('파일을 관리하는 여러 메뉴를 열 수 있어요',
                  'Open various menus to manage the file',
                  '可以打开管理文件的多项菜单',
                  'ファイルを管理するさまざまなメニューを開けます')),
        ];
      case _GuideKind.viewer:
        return [
          _Step('find', tr('단어 검색', 'Find in File', '在文件中查找', 'ファイル内検索'),
              tr('파일 안에서 단어를 찾아요', 'Find words in the file', '在文件中查找文字', 'ファイル内の単語を探します')),
          _Step('theme', tr('테마', 'Theme', '主题', 'テーマ'),
              tr('파일 배경을 바꿀 수 있어요', 'Change the file background', '可以更改文件背景', 'ファイルの背景を変えられます')),
          _Step('toc', tr('목차', 'Contents', '目录', '目次'),
              tr('목차가 있는 파일은 목차를 볼 수 있어요', 'View the table of contents if the file has one', '有目录的文件可以查看目录', '目次があるファイルは目次を見られます')),
          _Step('prev', tr('이전 파일', 'Previous File', '上一个文件', '前のファイル'), tr('같은 그룹의 이전 파일을 열어요', 'Open the previous file in the same group', '打开同一分组中的上一个文件', '同じグループの前のファイルを開きます')),
          _Step('next', tr('다음 파일', 'Next File', '下一个文件', '次のファイル'), tr('같은 그룹의 다음 파일을 열어요', 'Open the next file in the same group', '打开同一分组中的下一个文件', '同じグループの次のファイルを開きます')),
          _Step('rotate', tr('화면 회전', 'Rotate Screen', '旋转屏幕', '画面回転'),
              tr('화면 회전 방식을 골라요', 'Choose the screen rotation mode', '选择屏幕旋转方式', '画面の回転方法を選びます')),
          _Step('display', tr('페이지 표시', 'Page Display', '页面显示', 'ページ表示'),
              tr('페이지 표시 방식을 골라요', 'Choose how pages are displayed', '选择页面显示方式', 'ページの表示方法を選びます')),
          _Step('mode', tr('페이지 이동', 'Page Turning', '翻页', 'ページ移動'),
              tr('페이지 넘기는 방식을 골라요', 'Choose how pages turn', '选择翻页方式', 'ページのめくり方を選びます')),
          _Step('direction', tr('읽기 방향', 'Reading Direction', '阅读方向', '読む方向'),
              tr('페이지 넘기는 방향을 바꿀 수 있어요', 'Change the page-turning direction', '可以更改翻页方向', 'ページをめくる方向を変えられます')),
          _Step('memo', tr('메모', 'Memo', '笔记', 'メモ'),
              tr('지원하는 펜이나 손으로 메모해요', 'Take notes with a supported pen or your finger', '用支持的触控笔或手指做笔记', '対応ペンや指でメモします')),
          _Step('copy', tr('글자 복사', 'Copy Text', '复制文字', '文字をコピー'),
              tr('지금 보고 있는 페이지에서 원하는 글자를 골라 복사해요\n(글자를 길게 눌러도 바로 복사할 수 있어요)',
                  'Select and copy text on the current page\n(You can also long-press text directly to copy)',
                  '在当前页面选择并复制所需文字\n（长按文字也可以直接复制）',
                  '今見ているページから好きな文字を選んでコピーします\n（文字を長押ししてもそのままコピーできます）')),
          _Step('bookmark', tr('북마크', 'Bookmarks', '书签', 'ブックマーク'),
              tr('지금 보고 있는 페이지를 북마크해 두고, 목록에서 언제든지 바로 이동할 수 있어요',
                  'Bookmark the current page and jump back anytime from the list',
                  '将当前页面加入书签，随时从列表中直接跳转',
                  '今見ているページをブックマークして、一覧からいつでもすぐ移動できます')),
          _Step('viewer', tr('도구 모음 설정', 'Toolbar Settings', '工具栏设置', 'ツールバー設定'),
              tr('도구의 순서를 바꾸거나 숨길 수 있어요\n(도구 모음 막대는 길게 눌러 위치를 변경할 수 있어요)',
                  'Reorder or hide tools\n(Long-press the toolbar to change its position)',
                  '可以调整工具顺序或隐藏工具\n（长按工具栏可更改位置）',
                  'ツールの順番を変えたり隠したりできます\n（ツールバーは長押しで位置を変えられます）')),
          _Step('progress', tr('페이지 막대', 'Page Bar', '页面条', 'ページバー'),
              tr('맨 처음이나 맨 끝으로 한 번에 넘어가고, 페이지 번호를 누르면 원하는 페이지로 바로 갈 수 있어요\n(길게 눌러 위치를 변경할 수 있어요)',
                  'Jump to the first or last page at once, or tap the page number to go to any page\n(Long-press to change its position)',
                  '可一键跳至首页或末页，点击页码可直接前往指定页面\n（长按可更改位置）',
                  '最初や最後のページへ一度に移動でき、ページ番号を押すと好きなページへすぐ行けます\n（長押しで位置を変えられます）')),
        ];
      case _GuideKind.memo:
        return [
          _Step('finger', tr('손으로 그리기', 'Finger Writing', '手指书写', '指で手書き'),
              tr('켜면 손가락으로도 그릴 수 있고, 끄면 지원하는 펜으로만 그릴 수 있어요',
                  'Turn on to draw with your finger; turn off to draw only with a supported pen',
                  '开启后可用手指绘制，关闭后仅支持触控笔绘制',
                  'オンにすると指でも描け、オフにすると対応ペンだけで描けます')),
          _Step('pen', tr('펜', 'Pen', '笔', 'ペン'),
              tr('원하는 선을 그을 수 있으며, 한 번 더 누르면 펜 설정 창이 열려요',
                  'Draw lines freely, and tap again to open pen settings',
                  '可自由绘制线条，再点一次打开笔设置窗口',
                  '自由に線を引け、もう一度タップするとペン設定が開きます')),
          _Step('hl', tr('형광펜', 'Highlighter', '荧光笔', '蛍光ペン'),
              tr('반투명 선을 그을 수 있으며, 한 번 더 누르면 형광펜 설정 창이 열려요',
                  'Draw translucent highlights, and tap again to open highlighter settings',
                  '可绘制半透明高亮线条，再点一次打开荧光笔设置窗口',
                  '半透明の線を引け、もう一度タップすると蛍光ペン設定が開きます')),
          _Step('tape', tr('스티커', 'Sticker', '贴纸', 'ステッカー'),
              tr('가리고 싶은 곳에 붙였다 뗄 수 있고, 한 번 더 누르면 스티커 설정이 열려요',
                  'Stick and peel to cover parts of the page, and tap again to open sticker settings',
                  '可在想遮住的位置粘贴和揭下，再点一次打开贴纸设置',
                  '隠したいところに貼ったりはがしたりでき、もう一度タップするとステッカー設定が開きます')),
          _Step('eraser', tr('지우개', 'Eraser', '橡皮擦', '消しゴム'),
              tr('메모한 부분을 지울 수 있고, 한 번 더 누르면 지우개 설정 창이 열려요',
                  'Erase your notes, and tap again to open eraser settings',
                  '可擦除笔记内容，再点一次打开橡皮擦设置窗口',
                  'メモした部分を消せ、もう一度タップすると消しゴム設定が開きます')),
          _Step('undo', tr('되돌리기', 'Undo', '撤销', '元に戻す'),
              tr('방금 그리거나 지운 작업을 한 단계 되돌려요', 'Undo the last draw or erase action', '撤销上一步绘制或擦除操作', '直前に描いたり消したりした操作を1段階元に戻します')),
          _Step('redo', tr('다시 실행', 'Redo', '重做', 'やり直し'),
              tr('방금 되돌린 작업을 다시 실행해요', 'Redo the action you just undid', '重新执行刚才撤销的操作', '直前に元に戻した操作をやり直します')),
          _Step('done', tr('완료', 'Done', '完成', '完了'),
              tr('메모를 하고 나면 완료 버튼을 눌러야 저장돼요\n(메모 도구 막대는 길게 눌러 위치를 변경할 수 있어요)',
                  'Tap Done after taking notes to save them\n(Long-press the memo tool bar to change its position)',
                  '记完笔记后需点击完成按钮才会保存\n（长按笔记工具栏可更改位置）',
                  'メモをしたあと完了ボタンを押すと保存されます\n（メモツールバーは長押しで位置を変えられます）')),
        ];
      case _GuideKind.settings:
        return [
          _Step('style', tr('앱 스타일', 'App Style', '应用样式', 'アプリのスタイル'),
              tr('앱의 메인 화면 배치를 바꿀 수 있어요', 'Change the layout of the app\'s main screen', '可以更改应用主界面的布局', 'アプリのメイン画面の配置を変えられます')),
          _Step('theme', tr('앱 테마', 'App Theme', '应用主题', 'アプリのテーマ'),
              tr('앱의 화면 색상과 밝기 테마를 바꿀 수 있어요', 'Change the app\'s screen color and brightness theme', '可以更改应用的屏幕颜色和亮度主题', 'アプリの画面の色と明るさテーマを変えられます')),
          _Step('lang', tr('언어', 'Language', '语言', '言語'),
              tr('앱에 쓰는 언어를 바꿀 수 있어요', 'Change the app language', '可以更改应用语言', 'アプリで使う言語を変えられます')),
          _Step('privacy', tr('사생활 보호', 'Privacy', '隐私保护', 'プライバシー保護'),
              tr('앱 또는 파일을 잠글 수 있어요', 'Lock the app or files', '可以锁定应用或文件', 'アプリやファイルをロックできます')),
          _Step('anim', tr('애니메이션 끄기', 'Turn Off Animations', '关闭动画', 'アニメーションをオフ'),
              tr('모든 애니메이션을 끌 수 있어요', 'Turn off all animations', '可以关闭所有动画', 'すべてのアニメーションをオフにできます')),
          _Step('view', tr('파일 표시 방식', 'Bookshelf View Mode', '文件显示样式', 'ファイル表示形式'),
              tr('서재에서 파일이 보이는 방식과 여러 설정을 바꿀 수 있어요', 'Change how files appear in your library and other display options', '可以更改书架中文件的显示方式及多项设置', '書斎でのファイルの表示方法や各種設定を変えられます')),
          _Step('remember', tr('페이지 기억하기', 'Remember Last Page', '记住页面', 'ページを記憶'),
              tr('마지막으로 읽던 쪽으로 열어요', 'Opens at the page you last read', '打开到上次阅读的页面', '最後に読んだページで開きます')),
          _Step('tapzone', tr('탭 영역', 'Tap Zones', '点击区域', 'タップ領域'),
              tr('영역별로 눌렀을 때의 동작을 정해요', 'Set what tapping each area does', '设置点击各区域时的操作', 'エリアごとにタップしたときの動作を決めます')),
          _Step('folders', tr('탐색할 폴더', 'Folders to Search', '要查找的文件夹', '探すフォルダ'),
              tr('파일과 글꼴을 찾아올 폴더를 등록해 둘 수 있어요', 'Register folders to search for files and fonts', '可以登记查找文件和字体的文件夹', 'ファイルやフォントを探すフォルダを登録できます')),
          _Step('docfont', tr('한글·워드 글꼴', 'HWP·Word Fonts', 'HWP·Word 字体', 'HWP・Wordフォント'),
              tr('파일에 쓰인 글꼴이 기기에 없을 때 대신 쓸 글꼴 파일을 넣어요', 'Add replacement font files when fonts used in a file are missing on your device', '当文件使用的字体在设备上缺失时，可添加替代字体文件', 'ファイルで使われているフォントが端末にないときに代わりに使うフォントファイルを追加します')),
          _Step('appfont', tr('앱 글꼴', 'App Font', '应用字体', 'アプリのフォント'),
              tr('파일 외 모든 글꼴을 바꿔요', 'Change all app fonts outside of documents', '更改文件以外的所有应用字体', '文書以外のすべてのアプリフォントを変えます')),
          _Step('epubfont', tr('EPUB 글꼴', 'EPUB Font', 'EPUB字体', 'EPUBフォント'),
              tr('EPUB 책 본문 글꼴을 바꿔요', 'Change the font for EPUB book text', '更改 EPUB 正文字体', 'EPUB本文のフォントを変えます')),
          _Step('pro', tr('이리ERI 프로', '이리ERI Pro', '이리ERI 专业版', '이리ERI プロ'),
              Pro.freePeriod
                  ? tr('유료 기능과 무료 제공 기간(2027년 3월 1일까지)을 확인해요', 'See the paid features and the free period (until March 1, 2027)', '查看付费功能和免费提供期间（至2027年3月1日）', '有料機能と無料提供期間（2027年3月1日まで）を確認します')
                  : tr('유료 기능과 업데이트 안내를 확인해요', 'See the paid features and how to update', '查看付费功能和更新说明', '有料機能とアップデートの案内を確認します')),
          _Step('hidepaid', tr('유료 기능 숨기기', 'Hide Paid Features', '隐藏付费功能', '有料機能を隠す'),
              tr('쓸 수 없는 유료 기능을 메뉴에서 숨겨요', 'Hides paid features you cannot use from the menus', '在菜单中隐藏无法使用的付费功能', '使えない有料機能をメニューから隠します')),
          _Step('cache', tr('캐시 지우기', 'Clear Cache', '清除缓存', 'キャッシュを削除'),
              tr('다시 만들 수 있는 임시 파일만 지워요', 'Deletes only temporary files that can be rebuilt', '只删除可以重新生成的临时文件', '作り直せる一時ファイルだけを削除します')),
          _Step('data', tr('데이터 지우기', 'Clear Data', '清除数据', 'データを削除'),
              tr('앱을 처음 설치한 상태로 되돌려요', 'Resets the app to how it was when first installed', '将应用恢复到刚安装时的状态', 'アプリをインストール直後の状態に戻します')),
          _Step('guide', tr('가이드', 'Guide', '指南', 'ガイド'),
              tr('앱의 모든 설명을 볼 수 있어요', 'View all explanations for the app', '可以查看应用的全部说明', 'アプリのすべての説明を見られます')),
          _Step('faq', tr('자주 묻는 질문', 'FAQ', '常见问题', 'よくある質問'),
              tr('자주 묻는 질문과 답을 볼 수 있어요', 'See frequently asked questions and answers', '可以查看常见问题及解答', 'よくある質問と回答を見られます')),
          _Step('contact', tr('문의하기', 'Contact Us', '联系我们', 'お問い合わせ'),
              tr('오류나 개선할 점을 개발자에게 직접 문의할 수 있어요', 'Contact the developer directly about bugs or suggestions', '可以直接向开发者反馈错误或改进建议', '不具合や改善点について開発者に直接問い合わせられます')),
          _Step('review', tr('리뷰 남기기', 'Write a Review', '撰写评价', 'レビューを書く'),
              tr('Google Play 스토어에 리뷰를 남겨요', 'Leave a review on the Google Play Store', '在 Google Play 商店留下评价', 'Google Play ストアにレビューを書きます')),
          _Step('terms', tr('이용 약관', 'Terms of Service', '使用条款', '利用規約'), tr('앱 이용 약관을 봐요', 'Read the terms of service', '查看使用条款', '利用規約を見ます')),
          _Step('policy', tr('개인정보 처리방침', 'Privacy Policy', '隐私政策', 'プライバシーポリシー'),
              tr('앱이 정보를 어떻게 다루는지 봐요', 'See how the app handles information', '查看应用如何处理信息', 'アプリが情報をどう扱うかを見ます')),
          _Step('licenses', tr('오픈소스 라이선스', 'Open Source Licenses', '开源许可', 'オープンソースライセンス'),
              tr('앱에 들어 있는 오픈소스 소프트웨어·글꼴의 라이선스를 봐요', 'See the licenses of open source software and fonts in the app', '查看应用中开源软件·字体的许可', 'アプリに含まれるオープンソースソフトウェア・フォントのライセンスを見ます')),
        ];
    }
  }

  _Step _settingsStep() => _Step('settings', tr('설정', 'Settings', '设置', '設定'),
      tr('앱 설정을 열어요', 'Open app settings', '打开应用设置', 'アプリ設定を開きます'));

  @override
  Widget build(BuildContext context) {
    final step = _steps[_i];
    final Widget mock = switch (widget.kind) {
      _GuideKind.main => _MainMock(k: _k, tr: tr, simple: _simple),
      _GuideKind.viewer => _ViewerMock(k: _k, tr: tr),
      _GuideKind.memo => _MemoMock(k: _k, tr: tr),
      _GuideKind.settings => _SettingsMock(k: _k, tr: tr),
    };
    return Scaffold(
      body: Stack(
        key: _stageKey,
        children: [
          Positioned.fill(child: IgnorePointer(child: mock)),
          // 어둡게 덮고 단추 자리만 밝게 + 누르는 흉내 고리. 아무 데나 누르면 다음
          Positioned.fill(
            child: GestureDetector(
              behavior: HitTestBehavior.opaque,
              onTap: () => _go(1),
              child: AnimatedBuilder(
                animation: _pulse,
                builder: (context, _) => CustomPaint(painter: _SpotPainter(_hole, _pulse.value, AppColors.of(context))),
              ),
            ),
          ),
          if (_hole != null) _bubble(context, step),
        ],
      ),
    );
  }

  Widget _bubble(BuildContext context, _Step step) {
    final cs = Theme.of(context).colorScheme;
    final Size size = MediaQuery.sizeOf(context);
    final Rect hole = _to ?? _hole!;
    final EdgeInsets pad = MediaQuery.paddingOf(context);
    final double spaceAbove = hole.top - pad.top;
    final double spaceBelow = size.height - hole.bottom - pad.bottom;
    final bool tallHole = hole.height > size.height * 0.45 || (spaceAbove < 220 && spaceBelow < 220);
    final bool below = hole.center.dy < size.height * 0.5;
    final card = Material(
      color: cs.surfaceContainerHigh,
      borderRadius: BorderRadius.circular(20),
      elevation: 8,
      child: Padding(
        padding: const EdgeInsets.fromLTRB(18, 14, 12, 12),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Container(
                  padding: const EdgeInsets.symmetric(horizontal: 9, vertical: 3),
                  decoration: BoxDecoration(color: AppColors.of(context), borderRadius: BorderRadius.circular(10)),
                  child: Text('${_i + 1} / ${_steps.length}',
                      style: TextStyle(fontSize: 12, fontWeight: FontWeight.w800, color: AppColors.onSig(context), shadows: AppColors.sigShadows(context))),
                ),
                const Spacer(),
                TextButton(
                  onPressed: () => Navigator.pop(context),
                  child: Text(tr('그만 보기', 'Close', '关闭', '閉じる')),
                ),
              ],
            ),
            const SizedBox(height: 4),
            Text(step.title, style: const TextStyle(fontSize: 18, fontWeight: FontWeight.w800)),
            const SizedBox(height: 6),
            Padding(
              padding: const EdgeInsets.only(right: 6),
              child: Text(step.desc, style: TextStyle(fontSize: 14.5, height: 1.45, color: cs.onSurfaceVariant)),
            ),
            const SizedBox(height: 10),
            Row(
              children: [
                if (_i > 0)
                  OutlinedButton(onPressed: () => _go(-1), child: Text(tr('이전', 'Back', '上一步', '前へ')))
                else
                  const SizedBox.shrink(),
                const Spacer(),
                FilledButton(
                  style: FilledButton.styleFrom(backgroundColor: AppColors.of(context)),
                  onPressed: () => _go(1),
                  child: Text(
                    _i == _steps.length - 1 ? tr('마치기', 'Finish', '完成', '終了') : tr('다음', 'Next', '下一步', '次へ'),
                    style: TextStyle(color: AppColors.onSig(context), fontWeight: FontWeight.w700, shadows: AppColors.sigShadows(context)),
                  ),
                ),
              ],
            ),
          ],
        ),
      ),
    );
    // 새로 고침처럼 비추는 영역이 화면 대부분을 차지하면 위·아래가 아니라 화면 안쪽 안전한 위치에 띄움
    final double? topPos;
    final double? bottomPos;
    if (tallHole) {
      topPos = null;
      bottomPos = math.max(pad.bottom + 96, size.height * 0.18);
    } else if (below) {
      topPos = (hole.bottom + 14).clamp(pad.top + 16, math.max(pad.top + 16, size.height - pad.bottom - 240));
      bottomPos = null;
    } else {
      topPos = null;
      bottomPos = (size.height - hole.top + 14).clamp(pad.bottom + 16, math.max(pad.bottom + 16, size.height - pad.top - 240));
    }
    return AnimatedPositioned(
      duration: Anim.ms(260),
      curve: Curves.easeOutCubic,
      left: 16,
      right: 16,
      top: topPos,
      bottom: bottomPos,
      child: Center(child: ConstrainedBox(constraints: const BoxConstraints(maxWidth: 480), child: card)),
    );
  }
}

/// 어둡게 덮고 [hole]만 비우고, 그 둘레에 누르는 흉내 고리
class _SpotPainter extends CustomPainter {
  _SpotPainter(this.hole, this.t, this.accent);
  final Rect? hole;
  final double t;
  final Color accent;

  @override
  void paint(Canvas canvas, Size size) {
    final Paint dim = Paint()..color = Colors.black.withValues(alpha: 0.62);
    if (hole == null) {
      canvas.drawRect(Offset.zero & size, dim);
      return;
    }
    final double r = math.min(16.0, math.min(hole!.width, hole!.height) / 2);
    final RRect rr = RRect.fromRectAndRadius(hole!, Radius.circular(r));
    canvas.drawPath(Path.combine(PathOperation.difference, Path()..addRect(Offset.zero & size), Path()..addRRect(rr)), dim);
    canvas.drawRRect(rr, Paint()
      ..style = PaintingStyle.stroke
      ..strokeWidth = 2.5
      ..color = accent);
    // 누르는 흉내: 비춘 자리 둘레에서 고리가 퍼져 나감 (단추 그림은 가리지 않게 바깥으로만)
    if (t <= 0) return;
    final double p = (t * 1.6).clamp(0.0, 1.0);
    if (p < 1) {
      canvas.drawRRect(rr.inflate(2 + 14 * p), Paint()
        ..style = PaintingStyle.stroke
        ..strokeWidth = 3 * (1 - p) + 0.5
        ..color = accent.withValues(alpha: 0.9 * (1 - p)));
    }
  }

  @override
  bool shouldRepaint(_SpotPainter old) => old.hole != hole || old.t != t || old.accent != accent;
}

// ─────────────────────────────── 예시 화면 ───────────────────────────────

typedef _KeyOf = GlobalKey Function(String id);

/// 예시 파일 카드 (메인 화면 목록형과 같은 모양)
class _FileCard extends StatelessWidget {
  const _FileCard({required this.name, required this.ext, required this.meta, this.fav = false, this.cardKey, this.ribbonKey, this.moreKey});
  final String name;
  final String ext;
  final String meta;
  final bool fav;
  final Key? cardKey;
  final Key? ribbonKey;
  final Key? moreKey;

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final bool dark = Theme.of(context).brightness == Brightness.dark;
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 5),
      child: Container(
        key: cardKey,
        decoration: BoxDecoration(
          color: dark ? cs.surfaceContainerHigh : cs.surfaceContainerLowest,
          borderRadius: BorderRadius.circular(14),
          boxShadow: [BoxShadow(color: Colors.black.withValues(alpha: dark ? 0.28 : 0.13), blurRadius: 8, offset: const Offset(0, 2))],
        ),
        child: Stack(
          clipBehavior: Clip.none,
          children: [
            Material(
              type: MaterialType.transparency,
              child: ListTile(
              minTileHeight: 72,
              leading: FileTypeIcon(ext: ext),
              title: Text(name, maxLines: 1, overflow: TextOverflow.ellipsis),
              subtitle: Text(meta, style: const TextStyle(fontSize: 12)),
              trailing: Padding(padding: const EdgeInsets.all(8), child: Icon(Icons.more_horiz, key: moreKey)),
            ),
            ),
            Positioned(top: 0, left: 10, child: SizedBox(key: ribbonKey, child: FavoriteRibbon(active: fav, width: 12, height: 18, isDark: dark))),
            Positioned(
              top: -1,
              left: 13,
              child: Container(width: 20, height: 2, decoration: BoxDecoration(color: dark ? Colors.white60 : Colors.black45, borderRadius: BorderRadius.circular(1))),
            ),
          ],
        ),
      ),
    );
  }
}

class _MainMock extends StatelessWidget {
  const _MainMock({required this.k, required this.tr, required this.simple});
  final _KeyOf k;
  final _Tr tr;
  final bool simple;

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final files = [
      (tr('여행 계획', 'Trip plan', '旅行计划', '旅行計画'), 'pdf', '[pdf] · (3/12)', true),
      (tr('회의록', 'Meeting notes', '会议记录', '議事録'), 'hwpx', '[hwpx] · (1/4)', false),
      (tr('보고서', 'Report', '报告', '報告書'), 'docx', '[docx] · (5/20)', false),
      (tr('소설', 'Novel', '小说', '小説'), 'epub', '[epub] · (12%)', false),
    ];
    final title = Text(tr('내 서재', 'My Library', '我的书架', 'マイライブラリ'), style: const TextStyle(fontSize: 22, fontWeight: FontWeight.w800));
    final list = ListView(
      padding: const EdgeInsets.fromLTRB(12, 6, 12, 16),
      children: [
        for (int i = 0; i < files.length; i++)
          _FileCard(
            name: '${files[i].$1}.${files[i].$2}',
            ext: files[i].$2,
            meta: files[i].$3,
            fav: files[i].$4,
            cardKey: i == 1 ? k('card') : null,
            ribbonKey: i == 0 ? k('ribbon') : null,
            moreKey: i == 0 ? k('more') : null,
          ),
      ],
    );
    final groupIcon = const FolderDocsIcon(size: 20);
    final groupLabel = tr('내 서재', 'My Library', '我的书架', 'マイライブラリ');
    // 와이드: 왼쪽 둥근 네모 아이콘 막대 (위: 그룹·즐겨찾기 / 아래: 검색·휴지통·설정·[+]) + 오른쪽 파일
    if (simple) {
      final bool dark = Theme.of(context).brightness == Brightness.dark;
      // 고른 칸: 아이콘 왼쪽에 굵은 시그니처 색 선 (바탕색 없음)
      Widget railItem(String id, Widget icon, String? label, {bool selected = false}) {
        final Color fg = cs.onSurface;
        return Container(
          key: k(id),
          height: label == null ? 48 : 58,
          margin: const EdgeInsets.symmetric(vertical: 2),
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.center,
            children: [
              Container(width: 4, height: selected ? 26 : 0, decoration: BoxDecoration(color: AppColors.mark(context), borderRadius: BorderRadius.circular(2))),
              Expanded(
                child: Column(
                  mainAxisAlignment: MainAxisAlignment.center,
                  children: [
                    SizedBox(
                      height: 26,
                      child: Center(child: IconTheme.merge(data: IconThemeData(size: 24, color: fg), child: icon)),
                    ),
                    if (label != null) ...[
                      const SizedBox(height: 3),
                      Text(label, maxLines: 1, overflow: TextOverflow.ellipsis, style: TextStyle(fontSize: 11, fontWeight: selected ? FontWeight.w800 : FontWeight.w600, color: fg)),
                    ],
                  ],
                ),
              ),
              const SizedBox(width: 4),
            ],
          ),
        );
      }
      Widget divider() => Padding(
            padding: const EdgeInsets.symmetric(vertical: 6),
            child: Center(child: Container(width: 22, height: 1, color: cs.outlineVariant)),
          );
      return Scaffold(
        body: SafeArea(
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Container(
                width: 76,
                margin: const EdgeInsets.fromLTRB(10, 10, 6, 10),
                padding: const EdgeInsets.fromLTRB(6, 10, 6, 0),
                decoration: BoxDecoration(
                  color: dark ? cs.surfaceContainerHigh : cs.surfaceContainerLowest,
                  borderRadius: BorderRadius.circular(14),
                  border: dark ? null : Border.all(color: cs.outlineVariant, width: 1.6),
                ),
                child: Column(children: [
                  railItem('group', groupIcon, groupLabel, selected: true),
                  railItem('fav', const FavoritesIcon(size: 22), tr('즐겨찾기', 'Favorites', '收藏', 'お気に入り')),
                  divider(),
                  SizedBox(key: k('pin'), height: 44, child: Center(child: Icon(Icons.add, size: 24, color: cs.onSurfaceVariant))),
                  const Spacer(),
                  divider(),
                  railItem('search', const Icon(Icons.search), null),
                  railItem('trash', const TrashLidIcon(open: false), null),
                  railItem('settings', const SpinGearIcon(turns: 0), null),
                  Container(
                    key: k('add'),
                    width: 52,
                    height: 52,
                    margin: const EdgeInsets.only(top: 8, bottom: 14),
                    decoration: BoxDecoration(color: AppColors.of(context), borderRadius: BorderRadius.circular(16)),
                    child: Icon(Icons.add, size: 30, color: AppColors.onSig(context), shadows: AppColors.sigShadows(context)),
                  ),
                ]),
              ),
              Expanded(child: KeyedSubtree(key: k('list'), child: list)),
            ],
          ),
        ),
      );
    }
    Widget barItem(String id, Widget icon, String label) => Expanded(
          child: Center(
            child: Padding(
              key: k(id),
              padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 4),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  SizedBox(height: 26, child: Center(child: icon)),
                  const SizedBox(height: 3),
                  Text(label, maxLines: 1, overflow: TextOverflow.ellipsis, style: TextStyle(fontSize: 12, fontWeight: FontWeight.w600, color: cs.onSurface)),
                ],
              ),
            ),
          ),
        );
    return Scaffold(
      body: SafeArea(
        child: Column(
          children: [
            SizedBox(
              height: 56,
              child: Row(children: [
                const SizedBox(width: 16),
                title,
                const Spacer(),
              ]),
            ),
            Expanded(child: KeyedSubtree(key: k('list'), child: list)),
            Container(
              height: 66,
              decoration: BoxDecoration(color: cs.surfaceContainerLow, border: Border(top: BorderSide(color: cs.outlineVariant.withValues(alpha: 0.6)))),
              child: Row(children: [
                barItem('group', groupIcon, groupLabel),
                barItem('search', Icon(Icons.search, size: 24, color: cs.onSurface), tr('검색', 'Search', '搜索', '検索')),
                Expanded(
                  child: Center(
                    child: Container(
                      key: k('add'),
                      width: 44,
                      height: 44,
                      decoration: BoxDecoration(color: AppColors.of(context), shape: BoxShape.circle, boxShadow: const [BoxShadow(color: Colors.black26, blurRadius: 3, offset: Offset(0, 1))]),
                      child: Icon(Icons.add, size: 26, color: AppColors.onSig(context), shadows: AppColors.sigShadows(context)),
                    ),
                  ),
                ),
                barItem('trash', const TrashLidIcon(open: false), tr('휴지통', 'Trash', '回收站', 'ゴミ箱')),
                barItem('settings', const SpinGearIcon(turns: 0), tr('설정', 'Settings', '设置', '設定')),
              ]),
            ),
          ],
        ),
      ),
    );
  }
}

/// 예시 쪽: 흰 종이에 글줄 (메모 예시는 손글씨 획도)
class _SamplePage extends StatelessWidget {
  const _SamplePage({this.ink = false});
  final bool ink;

  @override
  Widget build(BuildContext context) {
    return Container(
      color: const Color(0xFFE9E9E9),
      alignment: Alignment.center,
      padding: const EdgeInsets.fromLTRB(22, 70, 22, 90),
      child: AspectRatio(
        aspectRatio: 1 / 1.414,
        child: Container(
          decoration: const BoxDecoration(color: Colors.white, boxShadow: [BoxShadow(color: Colors.black26, blurRadius: 6)]),
          child: CustomPaint(painter: _PageLinesPainter(ink)),
        ),
      ),
    );
  }
}

class _PageLinesPainter extends CustomPainter {
  _PageLinesPainter(this.ink);
  final bool ink;

  @override
  void paint(Canvas canvas, Size size) {
    final double m = size.width * 0.1;
    final Paint line = Paint()..color = const Color(0xFFCCCCCC);
    final Paint head = Paint()..color = const Color(0xFF9E9E9E);
    canvas.drawRRect(RRect.fromRectAndRadius(Rect.fromLTWH(m, m, size.width * 0.5, size.height * 0.03), const Radius.circular(3)), head);
    final rnd = math.Random(7);
    double y = m + size.height * 0.08;
    while (y < size.height - m) {
      final double w = (size.width - 2 * m) * (0.7 + 0.3 * rnd.nextDouble());
      canvas.drawRRect(RRect.fromRectAndRadius(Rect.fromLTWH(m, y, w, size.height * 0.014), const Radius.circular(2)), line);
      y += size.height * (rnd.nextDouble() < 0.15 ? 0.06 : 0.035);
    }
    if (ink) {
      // 손글씨 예시: 밑줄과 동그라미
      final Paint pen = Paint()
        ..color = const Color(0xFFE53935)
        ..style = PaintingStyle.stroke
        ..strokeWidth = size.width * 0.008
        ..strokeCap = StrokeCap.round;
      final double y1 = m + size.height * 0.08 + size.height * 0.035 * 3 + size.height * 0.022;
      final Path p = Path()..moveTo(m, y1);
      for (double x = m; x < size.width * 0.75; x += 6) {
        p.lineTo(x, y1 + math.sin(x / 9) * 1.2);
      }
      canvas.drawPath(p, pen);
      canvas.drawOval(Rect.fromLTWH(size.width * 0.55, size.height * 0.42, size.width * 0.34, size.height * 0.07), pen..color = const Color(0xFF1E88E5));
    }
  }

  @override
  bool shouldRepaint(_PageLinesPainter old) => old.ink != ink;
}

/// 파일 화면 위 검은 막대 (뒤로 · 파일 이름 · 단어 검색 · 테마 · 목차)
class _ViewerTopBar extends StatelessWidget {
  const _ViewerTopBar({required this.k, required this.tr});
  final _KeyOf k;
  final _Tr tr;

  @override
  Widget build(BuildContext context) {
    Widget b(String id, Widget icon) => SizedBox(key: k(id), width: 38, height: 40, child: Center(child: icon));
    return Material(
      color: Colors.black87,
      child: SafeArea(
        bottom: false,
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 4),
          child: Row(children: [
            b('back', const Icon(Icons.arrow_back, color: Colors.white, size: 17)),
            Expanded(
              child: Padding(
                padding: const EdgeInsets.symmetric(horizontal: 6),
                child: Text(tr('보고서.docx', 'Report.docx', '报告.docx', '報告書.docx'), style: const TextStyle(color: Colors.white, fontSize: 14), maxLines: 1),
              ),
            ),
            b('find', const Icon(Icons.search, color: Colors.white, size: 18)),
            b('theme', const MoonMorphIcon(filled: false, size: 19, color: Colors.white)),
            b('toc', const Icon(Icons.list, color: Colors.white, size: 17)),
          ]),
        ),
      ),
    );
  }
}

class _ViewerMock extends StatelessWidget {
  const _ViewerMock({required this.k, required this.tr});
  final _KeyOf k;
  final _Tr tr;

  @override
  Widget build(BuildContext context) {
    Widget b(String id, Widget icon) => SizedBox(
          key: k(id),
          width: 40,
          height: 52,
          child: Center(child: IconTheme.merge(data: const IconThemeData(color: Colors.white, size: 20), child: icon)),
        );
    final bar = Container(
      height: 52,
      decoration: BoxDecoration(
        color: const Color(0xEE1C1C1E),
        borderRadius: BorderRadius.circular(22),
        border: Border.all(color: Colors.white.withValues(alpha: 0.10)),
        boxShadow: const [BoxShadow(color: Colors.black38, blurRadius: 10, offset: Offset(0, 3))],
      ),
      padding: const EdgeInsets.symmetric(horizontal: 8),
      child: Row(mainAxisSize: MainAxisSize.min, children: [
        b('prev', const Icon(Icons.skip_previous_rounded, size: 19)),
        b('next', const Icon(Icons.skip_next_rounded, size: 19)),
        b('rotate', rotationGlyph('auto', size: 19, color: Colors.white)),
        b('display', pageDisplayGlyph('one', size: 19, color: Colors.white)),
        b('mode', const PageModeIcon(mode: 'tap+slide', color: Colors.white, size: 19)),
        b('direction', const DirectionArrowIcon(rightToLeft: false, size: 20)),
        b('memo', const MemoToolIcon(kind: 'memo', color: Colors.white, size: 22)),
        b('copy', const Icon(Icons.copy_all_outlined, size: 17)),
        b('bookmark', const Icon(Icons.bookmarks_outlined, size: 17)),
        Container(width: 1, height: 24, color: Colors.white.withValues(alpha: 0.18)),
        Padding(padding: const EdgeInsets.only(left: 2), child: b('viewer', const Icon(Icons.tune, size: 20))),
      ]),
    );
    return Stack(
      children: [
        const Positioned.fill(child: _SamplePage()),
        Positioned.fill(child: Center(child: SizedBox(key: k('page'), width: 150, height: 150))),
        Positioned(top: 0, left: 0, right: 0, child: _ViewerTopBar(k: k, tr: tr)),
        Positioned(
          left: 16,
          right: 16,
          bottom: 88 + MediaQuery.paddingOf(context).bottom,
          child: Center(
            child: Container(
              key: k('progress'),
              height: 38,
              constraints: const BoxConstraints(maxWidth: 420),
              decoration: BoxDecoration(
                color: const Color(0xEE1C1C1E),
                borderRadius: BorderRadius.circular(19),
                border: Border.all(color: Colors.white.withValues(alpha: 0.10)),
                boxShadow: const [BoxShadow(color: Colors.black38, blurRadius: 8, offset: Offset(0, 2))],
              ),
              padding: const EdgeInsets.symmetric(horizontal: 10),
              child: Row(
                children: [
                  const Icon(Icons.first_page_rounded, color: Colors.white70, size: 18),
                  const SizedBox(width: 8),
                  Expanded(
                    child: Stack(
                      alignment: Alignment.centerLeft,
                      children: [
                        Container(height: 3, decoration: BoxDecoration(color: Colors.white24, borderRadius: BorderRadius.circular(2))),
                        FractionallySizedBox(
                          widthFactor: 0.35,
                          child: Container(height: 3, decoration: BoxDecoration(color: AppColors.of(context), borderRadius: BorderRadius.circular(2))),
                        ),
                      ],
                    ),
                  ),
                  const SizedBox(width: 10),
                  const Text('12 / 34', style: TextStyle(color: Colors.white, fontSize: 12, fontWeight: FontWeight.w700)),
                  const SizedBox(width: 6),
                  const Icon(Icons.last_page_rounded, color: Colors.white70, size: 18),
                ],
              ),
            ),
          ),
        ),
        Positioned(
          left: 12,
          right: 12,
          bottom: 24 + MediaQuery.paddingOf(context).bottom,
          child: Center(child: FittedBox(fit: BoxFit.scaleDown, child: bar)),
        ),
      ],
    );
  }
}

class _MemoMock extends StatelessWidget {
  const _MemoMock({required this.k, required this.tr});
  final _KeyOf k;
  final _Tr tr;

  @override
  Widget build(BuildContext context) {
    Widget b(String id, Widget Function(Color) icon, {bool active = false, Color? color}) => SizedBox(
          key: k(id),
          width: kMemoToolExtent,
          height: kMemoToolExtent,
          child: Stack(alignment: Alignment.center, children: [
            if (active) Positioned(left: 2.5, child: MemoToolButton.activeBar()),
            icon(color ?? Colors.white),
          ]),
        );
    return Stack(
      children: [
        const Positioned.fill(child: _SamplePage(ink: true)),
        Positioned.fill(child: Center(child: SizedBox(key: k('page'), width: 170, height: 150))),
        Positioned(
          left: 12,
          right: 12,
          bottom: 28 + MediaQuery.paddingOf(context).bottom,
          child: Center(
            child: FittedBox(
              fit: BoxFit.scaleDown,
              child: MemoToolbar(children: [
                b('finger', (c) => FingerDrawIcon(color: c, size: 22)),
                b('pen', (c) => MemoToolIcon(kind: 'pen', color: c, accent: const Color(0xFFE53935), size: 22), active: true),
                b('hl', (c) => MemoToolIcon(kind: 'hl', color: c, accent: const Color(0xFFFFD60A), size: 22)),
                b('tape', (c) => MemoToolIcon(kind: 'tape', color: c, accent: const Color(0xFFFF7043), size: 22)),
                b('eraser', (c) => EraserIcon(color: c)),
                b('undo', (c) => Icon(Icons.undo, color: c, size: 16)),
                b('redo', (c) => Icon(Icons.redo, color: Colors.white30, size: 16)),
                SizedBox(
                  key: k('done'),
                  height: kMemoToolExtent,
                  child: Padding(
                    padding: const EdgeInsets.symmetric(horizontal: 11),
                    child: Center(child: Text(tr('완료', 'Done', '完成', '完了'), style: const TextStyle(color: AppColors.signature, fontSize: 14, fontWeight: FontWeight.w600))),
                  ),
                ),
              ]),
            ),
          ),
        ),
      ],
    );
  }
}

class _SettingsMock extends StatelessWidget {
  const _SettingsMock({required this.k, required this.tr});
  final _KeyOf k;
  final _Tr tr;

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    Widget section(String t) => Padding(
          padding: const EdgeInsets.fromLTRB(24, 18, 24, 6),
          child: Text(t, style: TextStyle(fontSize: 14, fontWeight: FontWeight.w700, color: cs.primary)),
        );
    Widget item(String id, Widget leading, String title, {String? sub, bool toggle = false}) => ListTile(
          key: k(id),
          contentPadding: const EdgeInsets.symmetric(horizontal: 24, vertical: 4),
          leading: IconTheme.merge(data: IconThemeData(size: 23, color: cs.onSurface), child: leading),
          title: Text(title, style: const TextStyle(fontSize: 16.5, fontWeight: FontWeight.w700)),
          subtitle: sub == null ? null : Text(sub, style: TextStyle(fontSize: 14, color: cs.onSurfaceVariant)),
          trailing: toggle ? Switch(value: false, onChanged: (_) {}) : Icon(Icons.chevron_right, color: cs.onSurfaceVariant),
        );
    return Scaffold(
      appBar: AppBar(automaticallyImplyLeading: false, title: Text(tr('앱 설정', 'App Settings', '应用设置', 'アプリ設定'), style: const TextStyle(fontWeight: FontWeight.w800))),
      body: ListView(
        padding: const EdgeInsets.only(bottom: 320),
        children: [
          section(tr('일반', 'General', '通用', '一般')),
          item('style', const Icon(Icons.dashboard_customize_outlined), tr('앱 스타일', 'App Style', '应用样式', 'アプリのスタイル'), sub: tr('컴팩트', 'Compact', '紧凑', 'コンパクト')),
          item('theme', const Icon(Icons.brightness_auto_outlined), tr('앱 테마', 'App Theme', '应用主题', 'アプリのテーマ'), sub: tr('기본 시스템', 'System default', '跟随系统', 'システムのデフォルト')),
          item('lang', const LanguageGlyphIcon(size: 23), tr('언어', 'Language', '语言', '言語')),
          item('privacy', const Icon(Icons.lock_outline), tr('사생활 보호', 'Privacy', '隐私保护', 'プライバシー保護')),
          item('anim', const Icon(Icons.motion_photos_off_outlined), tr('애니메이션 끄기', 'Turn Off Animations', '关闭动画', 'アニメーションをオフ'), toggle: true),
          section(tr('파일', 'Files', '文件', 'ファイル')),
          item('view', const Icon(Icons.view_list_rounded), tr('파일 표시 방식', 'Bookshelf View Mode', '文件显示样式', 'ファイル表示形式')),
          item('remember', const Icon(Icons.bookmark_added_outlined), tr('페이지 기억하기', 'Remember Last Page', '记住页面', 'ページを記憶'), toggle: true),
          item('tapzone', const Icon(Icons.grid_view_outlined), tr('탭 영역', 'Tap Zones', '点击区域', 'タップ領域')),
          item('folders', const Icon(Icons.folder_open_outlined), tr('탐색할 폴더', 'Folders to Search', '要查找的文件夹', '探すフォルダ')),
          section(tr('글꼴', 'Fonts', '字体', 'フォント')),
          item('docfont', const DocPairIcon(size: 25), tr('한글·워드 글꼴', 'HWP·Word Fonts', 'HWP·Word 字体', 'HWP・Wordフォント')),
          item('appfont', const Icon(Icons.font_download_outlined), tr('앱 글꼴', 'App Font', '应用字体', 'アプリのフォント')),
          item('epubfont', FileTypeIcon(ext: 'epub', size: 24, color: cs.onSurface), tr('EPUB 글꼴', 'EPUB Font', 'EPUB字体', 'EPUBフォント')),
          section(tr('프로', 'Pro', '专业版', 'プロ')),
          item('pro', const Icon(Icons.workspace_premium_outlined), tr('이리ERI 프로', '이리ERI Pro', '이리ERI 专业版', '이리ERI プロ')),
          item('hidepaid', const Icon(Icons.visibility_off_outlined), tr('유료 기능 숨기기', 'Hide Paid Features', '隐藏付费功能', '有料機能を隠す'), toggle: true),
          section(tr('데이터', 'Data', '数据', 'データ')),
          item('cache', const Icon(Icons.cleaning_services_outlined), tr('캐시 지우기', 'Clear Cache', '清除缓存', 'キャッシュを削除')),
          item('data', const Icon(Icons.delete_forever_outlined), tr('데이터 지우기', 'Clear Data', '清除数据', 'データを削除')),
          section(tr('도움말', 'Help', '帮助', 'ヘルプ')),
          item('guide', const Icon(Icons.lightbulb_outline), tr('가이드', 'Guide', '指南', 'ガイド')),
          item('faq', const Icon(Icons.help_outline), tr('자주 묻는 질문', 'FAQ', '常见问题', 'よくある質問')),
          item('contact', const Icon(Icons.mail_outline), tr('문의하기', 'Contact Us', '联系我们', 'お問い合わせ')),
          item('review', const Icon(Icons.rate_review_outlined), tr('리뷰 남기기', 'Write a Review', '撰写评价', 'レビューを書く')),
          item('terms', const Icon(Icons.gavel_outlined), tr('이용 약관', 'Terms of Service', '使用条款', '利用規約')),
          item('policy', const Icon(Icons.privacy_tip_outlined), tr('개인정보 처리방침', 'Privacy Policy', '隐私政策', 'プライバシーポリシー')),
          item('licenses', const Icon(Icons.article_outlined), tr('오픈소스 라이선스', 'Open Source Licenses', '开源许可', 'オープンソースライセンス')),
        ],
      ),
    );
  }
}
