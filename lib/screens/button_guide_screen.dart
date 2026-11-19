import 'dart:math' as math;

import 'package:flutter/material.dart';

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
      (_GuideKind.viewer, Icon(Icons.view_agenda_outlined, color: cs.onSurface), _tr('파일 상단바·도구 모음', 'File Top Bar & Toolbox', '文件顶部栏·工具箱', 'ファイル上部バー・ツールボックス'),
          _tr('파일을 볼 때 쓰는 단추', 'Buttons you use while reading a file', '阅读文件时使用的按钮', 'ファイルを見るときに使うボタン')),
      (_GuideKind.memo, QuillInkIcon(color: cs.onSurface, size: 24), _tr('메모 도구 모음', 'Memo Toolbar', '笔记工具栏', 'メモツールバー'),
          _tr('펜·지우개·되돌리기 등 메모 도구', 'Pen, eraser, undo and other memo tools', '笔·橡皮擦·撤销等笔记工具', 'ペン・消しゴム・元に戻すなどのメモツール')),
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
    final Offset tl = stage.globalToLocal(box.localToGlobal(Offset.zero));
    final Offset br = stage.globalToLocal(box.localToGlobal(box.size.bottomRight(Offset.zero)));
    final Rect r = Rect.fromPoints(tl, br).inflate(6);
    setState(() {
      _from = _hole ?? r;
      _to = r;
    });
    _move.forward(from: 0);
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
          _Step('group', tr('그룹', 'Group', '分组', 'グループ'),
              tr('지금 보고 있는 그룹이에요\n누르면 그룹 목록이 나와 다른 그룹으로 가고, 꾹 누르면 이름 수정·삭제, ≡를 끌면 순서를 바꿔요',
                  'The group you are viewing\nTap to open the group list and switch groups; long-press to rename or delete, drag ≡ to reorder',
                  '当前查看的分组\n点击打开分组列表切换分组；长按可修改名称·删除，拖动≡可调整顺序',
                  '今見ているグループです\nタップでグループ一覧を開いて切り替え、長押しで名前の修正・削除、≡をドラッグで並べ替えます')),
          _Step('search', tr('검색', 'Search', '搜索', '検索'),
              tr('파일 이름으로 찾아요', 'Find files by name', '按文件名查找', 'ファイル名で探します')),
          if (!simple)
            _Step('add', tr('파일 추가', 'Add Files', '添加文件', 'ファイル追加'),
                tr('파일 탐색·파일 추가·스캔·PDF 합치기·이미지 합치기를 골라요', 'Choose find files, add files, scan, merge PDFs or merge images', '可选择查找文件·添加文件·扫描·合并 PDF·合并图片', 'ファイル検索・ファイル追加・スキャン・PDF結合・画像結合を選びます')),
          _Step('trash', tr('휴지통', 'Trash', '回收站', 'ゴミ箱'),
              tr('지운 파일을 모아 둬요\n되살리거나 완전히 지울 수 있어요', 'Keeps deleted files\nRestore them or delete them for good', '存放删除的文件\n可以恢复或彻底删除', '削除したファイルを保管します\n元に戻すか完全に削除できます')),
          if (!simple) _settingsStep(),
          if (!simple)
            _Step('refresh', tr('새로 고침', 'Refresh', '刷新', '更新'),
                tr('서재를 다시 읽어 와요', 'Reload your library', '重新读取书架', '書斎を読み込み直します')),
          _Step('sort', tr('정렬', 'Sort', '排序', '並べ替え'),
              tr('이름이나 파일 추가 날짜 순으로 정렬하고, 정렬을 기억할 수 있어요', 'Sort by name or date added, and keep the order if you like', '按名称或添加日期排序，也可以记住排序', '名前か追加日で並べ替え、並べ替えを記憶できます')),
          if (simple) ...[
            _settingsStep(),
            _Step('add', tr('파일 추가', 'Add Files', '添加文件', 'ファイル追加'),
                tr('파일 탐색·파일 추가·PDF 합치기·이미지 합치기·문서 스캔 아이콘이 위로 나와요\n아이콘을 꾹 누르면 이름이 보여요', 'Icons for find files, add files, merge PDFs, merge images and scan documents appear above it\nLong-press an icon to see its name', '上方会出现查找文件·添加文件·合并 PDF·合并图片·扫描文档图标\n长按图标可查看名称', 'ファイル検索・ファイル追加・PDF結合・画像結合・文書スキャンのアイコンが上に出ます\nアイコンを長押しすると名前が表示されます')),
          ],
          if (simple)
            _Step('list', tr('새로 고침', 'Refresh', '刷新', '更新'),
                tr('목록을 맨 위에서 아래로 당기면 새로 고침 아이콘이 나오며 서재를 다시 읽어 와요', 'Pull the list down from the top to show the refresh icon and reload your library', '从顶部向下拉列表，会出现刷新图标并重新读取书架', '一覧を一番上から下に引くと更新アイコンが出て、書斎を読み込み直します')),
          _Step('ribbon', tr('즐겨찾기 책갈피', 'Favorite Ribbon', '收藏书签', 'お気に入りのしおり'),
              tr('누르거나 아래로 당기면 즐겨찾기가 켜지고 꺼져요', 'Tap or pull it down to add or remove a favorite', '点击或向下拉即可收藏或取消收藏', 'タップするか下に引くとお気に入りのオン・オフが切り替わります')),
          _Step('card', tr('파일', 'File', '文件', 'ファイル'),
              tr('누르면 열려요\n오른쪽으로 밀면 즐겨찾기, 왼쪽으로 밀면 휴지통으로 가요\n꾹 누르면 여러 개를 골라요',
                  'Tap to open\nSwipe right to favorite, swipe left to move to trash\nLong-press to select several',
                  '点击打开\n向右滑收藏，向左滑移至回收站\n长按可多选',
                  'タップで開きます\n右にスワイプでお気に入り、左にスワイプでゴミ箱へ\n長押しで複数選択します')),
          _Step('more', tr('파일 메뉴', 'File Menu', '文件菜单', 'ファイルメニュー'),
              tr('파일 정보·공유·이름 수정·그룹 이동·휴지통을 골라요', 'File info, share, rename, move to group or trash', '文件信息·分享·修改名称·移动分组·回收站', 'ファイル情報・共有・名前の修正・グループ移動・ゴミ箱を選びます')),
        ];
      case _GuideKind.viewer:
        return [
          _Step('page', tr('화면 가운데', 'Middle of the Screen', '屏幕中间', '画面の中央'),
              tr('누르면 위아래 막대가 나타나거나 숨어요\n양옆을 누르거나 옆으로 밀면 쪽이 넘어가요', 'Tap to show or hide the bars\nTap the sides or swipe to turn pages', '点击显示或隐藏上下栏\n点击两侧或左右滑动即可翻页', 'タップで上下のバーを表示・非表示\n左右をタップするかスワイプでページをめくります')),
          _Step('back', tr('뒤로', 'Back', '返回', '戻る'), tr('서재로 돌아가요', 'Return to the library', '返回书架', '書斎に戻ります')),
          _Step('find', tr('단어 검색', 'Find in File', '在文件中查找', 'ファイル内検索'),
              tr('파일 안에서 단어를 찾아요 (한글·워드·PPT·TXT)', 'Find words in the file (Hangul, Word, PPT, TXT)', '在文件中查找文字（韩文·Word·PPT·TXT）', 'ファイル内の単語を探します(ハングル・Word・PPT・TXT)')),
          _Step('theme', tr('테마', 'Theme', '主题', 'テーマ'),
              tr('파일 배경을 라이트·다크·편안함으로 바꿔요 (EPUB은 세피아도)', 'Switch the page background to light, dark or comfort (EPUB also has sepia)', '将页面背景切换为浅色·深色·护眼（EPUB 还有棕褐色）', 'ページの背景をライト・ダーク・目に優しいに切り替えます(EPUBはセピアも)')),
          _Step('toc', tr('목차', 'Contents', '目录', '目次'), tr('목차를 열어 원하는 곳으로 가요', 'Open the contents and jump anywhere', '打开目录跳转到任意位置', '目次を開いて好きな場所に移動します')),
          _Step('prev', tr('이전 파일', 'Previous File', '上一个文件', '前のファイル'), tr('같은 그룹의 이전 파일을 열어요', 'Open the previous file in the same group', '打开同一分组中的上一个文件', '同じグループの前のファイルを開きます')),
          _Step('next', tr('다음 파일', 'Next File', '下一个文件', '次のファイル'), tr('같은 그룹의 다음 파일을 열어요', 'Open the next file in the same group', '打开同一分组中的下一个文件', '同じグループの次のファイルを開きます')),
          _Step('rotate', tr('화면 회전', 'Rotate Screen', '旋转屏幕', '画面回転'),
              tr('자동·세로 고정·가로 고정을 골라요', 'Choose auto, portrait lock or landscape lock', '选择自动·锁定竖屏·锁定横屏', '自動・縦に固定・横に固定を選びます')),
          _Step('display', tr('페이지 표시', 'Page Display', '页面显示', 'ページ表示'),
              tr('한 페이지·두 페이지·자동(가로 화면에서 두 페이지)을 골라요', 'Choose one page, two pages or auto (two pages in landscape)', '选择单页·双页·自动（横屏时双页）', '1ページ・2ページ・自動(横画面で2ページ)を選びます')),
          _Step('mode', tr('페이지 모드', 'Page Mode', '翻页模式', 'ページモード'),
              tr('탭·슬라이드·스크롤 중 넘기는 방식을 골라요\n창을 닫을 때 적용돼요', 'Choose how pages turn: tap, slide or scroll\nApplies when the window closes', '选择翻页方式：点击·滑动·滚动\n关闭窗口时生效', 'タップ・スライド・スクロールからめくり方を選びます\nウィンドウを閉じると適用されます')),
          _Step('direction', tr('읽기 방향', 'Reading Direction', '阅读方向', '読む方向'),
              tr('좌→우·우→좌를 바꿔요 (파일마다 기억)', 'Switch left-to-right or right-to-left (remembered per file)', '切换左→右·右→左（按文件记忆）', '左→右・右→左を切り替えます(ファイルごとに記憶)')),
          _Step('memo', tr('메모', 'Memo', '笔记', 'メモ'), tr('쪽 위에 S펜이나 손가락으로 메모해요', 'Write on the page with the S Pen or your finger', '用 S Pen 或手指在页面上写笔记', 'Sペンや指でページにメモします')),
          _Step('copy', tr('글자 복사', 'Copy Text', '复制文字', '文字をコピー'), tr('쪽의 글자를 골라 복사해요', 'Select and copy text on the page', '选择并复制页面上的文字', 'ページの文字を選んでコピーします')),
          _Step('bookmark', tr('북마크', 'Bookmarks', '书签', 'ブックマーク'), tr('지금 쪽을 북마크하고 북마크 목록을 봐요', 'Bookmark this page and see your bookmarks', '为当前页添加书签并查看书签列表', '今のページをブックマークし、一覧を見ます')),
          _Step('viewer', tr('뷰어 설정', 'Viewer Settings', '阅读器设置', 'ビューア設定'),
              tr('왼손잡이·페이지 전환 버튼·진행도 UI 위치·메모 도구 모음 위치·하단 정보 표시를 정해요', 'Set left-handed mode, page-turn buttons, progress bar position, memo toolbar position and footer info', '设置左手模式·翻页按键·进度条位置·笔记工具栏位置·底部信息', '左利き・ページめくりボタン・進行度バーの位置・メモツールバーの位置・下部情報表示を設定します')),
        ];
      case _GuideKind.memo:
        return [
          _Step('page', tr('쪽 위에 쓰기', 'Writing on the Page', '在页面上书写', 'ページに書く'),
              tr('S펜으로 바로 써요\n메모는 쪽에 붙어 확대·이동해도 함께 움직여요', 'Write right away with the S Pen\nMemos stay on the page when you zoom or move', '用 S Pen 直接书写\n笔记贴在页面上，放大·移动时一起移动', 'Sペンですぐ書けます\nメモはページに付いて、拡大・移動しても一緒に動きます')),
          _Step('finger', tr('손으로 그리기', 'Finger Writing', '手指书写', '指で手書き'),
              tr('켜면 손가락으로도 써요\n꺼 두면 손가락으로는 쪽을 넘기고 S펜으로만 써요', 'Turn on to write with your finger too\nWhen off, your finger turns pages and only the S Pen writes', '开启后也可用手指书写\n关闭时手指用于翻页，只用 S Pen 书写', 'オンにすると指でも書けます\nオフのときは指でページをめくり、Sペンだけで書きます')),
          _Step('pen', tr('펜', 'Pen', '笔', 'ペン'),
              tr('펜으로 써요\n한 번 더 누르면 굵기·색상을 골라요', 'Write with the pen\nTap again to choose width and color', '用笔书写\n再点一次可选择粗细·颜色', 'ペンで書きます\nもう一度タップで太さ・色を選びます')),
          _Step('eraser', tr('지우개', 'Eraser', '橡皮擦', '消しゴム'),
              tr('문질러 지워요\n한 번 더 누르면 지우개 종류(획 지우개·영역 지우개)를 골라요', 'Rub to erase\nTap again to choose the eraser type (stroke or area)', '擦拭即可擦除\n再点一次可选择橡皮擦类型（笔画·区域）', 'こすって消します\nもう一度タップで消しゴムの種類(ストローク・部分)を選びます')),
          _Step('undo', tr('되돌리기', 'Undo', '撤销', '元に戻す'), tr('방금 한 것을 되돌려요', 'Undo the last change', '撤销上一步', '直前の操作を元に戻します')),
          _Step('redo', tr('다시 실행', 'Redo', '重做', 'やり直し'), tr('되돌린 것을 다시 해요', 'Redo what you undid', '恢复已撤销的操作', '元に戻した操作をやり直します')),
          _Step('clear', tr('전체 지우기', 'Clear All', '全部清除', 'すべて消去'), tr('보고 있는 쪽의 메모를 모두 지워요', 'Clear all memos on the page you are viewing', '清除当前页的全部笔记', '見ているページのメモをすべて消します')),
          _Step('done', tr('완료', 'Done', '完成', '完了'), tr('메모를 마치고 도구 모음을 닫아요', 'Finish and close the memo toolbar', '结束书写并关闭笔记工具栏', 'メモを終えてツールバーを閉じます')),
        ];
      case _GuideKind.settings:
        return [
          _Step('style', tr('앱 스타일', 'App Style', '应用样式', 'アプリのスタイル'),
              tr('기본(아래 막대)과 심플(위 막대와 오른쪽 아래 [+]) 중에 골라요', 'Choose Default (bottom bar) or Simple (top bar and [+] at the bottom right)', '在默认（底部栏）和简洁（顶部栏和右下角[+]）之间选择', '標準(下のバー)とシンプル(上のバーと右下の[+])から選びます')),
          _Step('theme', tr('앱 테마', 'App Theme', '应用主题', 'アプリのテーマ'),
              tr('기본 시스템·라이트·다크·편안한 모드를 골라요', 'Choose system default, light, dark or comfort mode', '选择跟随系统·浅色·深色·护眼模式', 'システムのデフォルト・ライト・ダーク・目に優しいモードを選びます')),
          _Step('lang', tr('언어', 'Language', '语言', '言語'), tr('앱에 쓰는 언어를 바꿔요', 'Change the app language', '更改应用语言', 'アプリの言語を変えます')),
          _Step('privacy', tr('사생활 보호', 'Privacy', '隐私保护', 'プライバシー保護'),
              tr('앱·파일을 비밀번호·패턴·생체 인식으로 잠가요', 'Lock the app and files with a PIN, pattern or biometrics', '用密码·图案·生物识别锁定应用·文件', 'アプリ・ファイルをパスワード・パターン・生体認証でロックします')),
          _Step('anim', tr('애니메이션 끄기', 'Turn Off Animations', '关闭动画', 'アニメーションをオフ'),
              tr('버튼·창이 움직임 없이 바로 바뀌어요', 'Buttons and windows change instantly without motion', '按钮·窗口直接切换，没有动画', 'ボタンやウィンドウが動きなしですぐ切り替わります')),
          _Step('view', tr('파일 표시 방식', 'Bookshelf View Mode', '文件显示样式', 'ファイル表示形式'),
              tr('목록형·표지형과 확장자·그룹 이름·페이지 수 표시 등을 정해요', 'Choose list or cover view and whether to show extensions, group names and page counts', '选择列表·封面样式，以及是否显示扩展名·分组名称·页数等', 'リスト・表紙形式と、拡張子・グループ名・ページ数の表示などを決めます')),
          _Step('remember', tr('페이지 기억하기', 'Remember Last Page', '记住页面', 'ページを記憶'),
              tr('마지막으로 읽던 쪽으로 열어요', 'Opens at the page you last read', '打开到上次阅读的页面', '最後に読んだページで開きます')),
          _Step('tapzone', tr('탭 영역', 'Tap Zones', '点击区域', 'タップ領域'),
              tr('영역별로 눌렀을 때의 동작을 정해요', 'Set what tapping each area does', '设置点击各区域时的操作', 'エリアごとにタップしたときの動作を決めます')),
          _Step('tapguide', tr('탭 가이드라인 끄기', 'Turn Off Tap Guide', '关闭点击指引', 'タップガイドをオフ'),
              tr('파일을 열 때마다 탭 영역 안내를 보여 주지 않아요', 'Does not show the tap zone guide each time a file opens', '打开文件时不再显示点击区域指引', 'ファイルを開くたびにタップ領域の案内を表示しません')),
          _Step('folders', tr('탐색할 폴더', 'Folders to Search', '要查找的文件夹', '探すフォルダ'),
              tr('파일 탐색·글꼴 찾기가 찾을 폴더를 넣고 빼요\n넣은 폴더와 그 안의 폴더에서만 찾아요', 'Add or remove the folders Find Files and Find Fonts search\nOnly these folders and the folders inside them are searched', '添加或移除查找文件·查找字体的文件夹\n只在这些文件夹及其子文件夹中查找', 'ファイル検索・フォント検索が探すフォルダを追加・削除します\n追加したフォルダとその中のフォルダだけを探します')),
          _Step('docfont', tr('한글·워드 글꼴', 'HWP·Word Fonts', 'HWP·Word 字体', 'HWP・Wordフォント'),
              tr('문서에 쓰인 글꼴이 기기에 없을 때 대신 쓸 글꼴 파일을 넣어요', 'Add font files to stand in for ones a document uses but your device lacks', '添加字体文件，代替文档中设备没有的字体', '文書で使われていて端末にないフォントの代わりになるフォントファイルを追加します')),
          _Step('appfont', tr('앱 글꼴', 'App Font', '应用字体', 'アプリのフォント'),
              tr('메뉴·목록·설정 화면 글꼴을 바꿔요', 'Change the font for menus, lists and settings', '更改菜单、列表、设置的字体', 'メニュー・一覧・設定画面のフォントを変えます')),
          _Step('epubfont', tr('EPUB 글꼴', 'EPUB Font', 'EPUB字体', 'EPUBフォント'),
              tr('EPUB 책 본문 글꼴을 바꿔요', 'Change the font for EPUB book text', '更改 EPUB 正文字体', 'EPUB本文のフォントを変えます')),
          _Step('pro', tr('이리ERI 프로', '이리ERI Pro', '이리ERI 专业版', '이리ERI プロ'),
              tr('유료 기능을 사거나 무료 체험을 시작해요', 'Buy the paid features or start the free trial', '购买付费功能或开始免费试用', '有料機能を購入するか無料体験を始めます')),
          _Step('hidepaid', tr('유료 기능 숨기기', 'Hide Paid Features', '隐藏付费功能', '有料機能を隠す'),
              tr('사지 않은 유료 기능을 메뉴에서 숨겨요', 'Hides paid features you have not bought from the menus', '在菜单中隐藏未购买的付费功能', '購入していない有料機能をメニューから隠します')),
          _Step('cache', tr('캐시 지우기', 'Clear Cache', '清除缓存', 'キャッシュを削除'),
              tr('다시 만들 수 있는 임시 파일만 지워요', 'Deletes only temporary files that can be rebuilt', '只删除可以重新生成的临时文件', '作り直せる一時ファイルだけを削除します')),
          _Step('data', tr('데이터 지우기', 'Clear Data', '清除数据', 'データを削除'),
              tr('파일·메모·설정·접근 권한을 모두 지우고 처음 상태로', 'Delete all files, notes, settings and permissions and start over', '删除所有文件·笔记·设置·访问权限，恢复初始状态', 'ファイル・メモ・設定・アクセス権限をすべて削除して初期状態に')),
          _Step('guide', tr('가이드', 'Guide', '指南', 'ガイド'), tr('지금 보고 있는 이 안내를 다시 열어요', 'Opens this guide again', '再次打开本指南', 'このガイドをもう一度開きます')),
          _Step('faq', tr('자주 묻는 질문', 'FAQ', '常见问题', 'よくある質問'),
              tr('지원 형식·요금·파일 추가 방식 등 자주 묻는 질문을 봐요', 'See common questions about formats, pricing, adding files and more', '查看支持格式·费用·文件添加方式等常见问题', '対応形式・料金・ファイルの追加方法などのよくある質問を見ます')),
          _Step('contact', tr('문의하기', 'Contact Us', '联系我们', 'お問い合わせ'),
              tr('이메일·제목·내용을 적어 개발자에게 문의해요', 'Write your email, subject and message to contact the developer', '填写邮箱·标题·内容联系开发者', 'メール・件名・内容を書いて開発者に問い合わせます')),
          _Step('terms', tr('이용 약관', 'Terms of Service', '使用条款', '利用規約'), tr('앱 이용 약관을 봐요', 'Read the terms of service', '查看使用条款', '利用規約を見ます')),
          _Step('policy', tr('개인정보 처리방침', 'Privacy Policy', '隐私政策', 'プライバシーポリシー'),
              tr('앱이 정보를 어떻게 다루는지 봐요', 'See how the app handles information', '查看应用如何处理信息', 'アプリが情報をどう扱うかを見ます')),
          _Step('licenses', tr('오픈소스 라이선스', 'Open Source Licenses', '开源许可', 'オープンソースライセンス'),
              tr('앱에 들어 있는 오픈소스 소프트웨어·글꼴의 라이선스를 봐요', 'See the licenses of open source software and fonts in the app', '查看应用中开源软件·字体的许可', 'アプリに含まれるオープンソースソフトウェア・フォントのライセンスを見ます')),
        ];
    }
  }

  _Step _settingsStep() => _Step('settings', tr('설정', 'Settings', '设置', '設定'),
      tr('앱 스타일·테마·언어 등 앱 설정을 열어요', 'Open app settings such as style, theme and language', '打开样式·主题·语言等应用设置', 'スタイル・テーマ・言語などのアプリ設定を開きます'));

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
    return AnimatedPositioned(
      duration: Anim.ms(260),
      curve: Curves.easeOutCubic,
      left: 16,
      right: 16,
      top: below ? math.min(hole.bottom + 14, size.height - 260) : null,
      bottom: below ? null : math.max(size.height - hole.top + 14, pad.bottom + 16),
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
    Widget iconBtn(String id, Widget icon) => Padding(padding: const EdgeInsets.all(4), child: SizedBox.square(key: k(id), dimension: 40, child: Center(child: icon)));
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
    if (simple) {
      return Scaffold(
        body: SafeArea(
          child: Stack(
            children: [
              Column(
                children: [
                  SizedBox(
                    height: 56,
                    child: Row(children: [
                      const SizedBox(width: 16),
                      title,
                      const Spacer(),
                      iconBtn('search', const Icon(Icons.search)),
                      iconBtn('trash', const TrashLidIcon(open: false)),
                      iconBtn('sort', const SortBarsIcon(flipped: false)),
                      iconBtn('settings', const SpinGearIcon(turns: 0)),
                      const SizedBox(width: 4),
                    ]),
                  ),
                  SizedBox(
                    height: 54,
                    child: Align(
                      alignment: Alignment.centerLeft,
                      child: Padding(
                        padding: const EdgeInsets.symmetric(horizontal: 12),
                        child: Container(
                          key: k('group'),
                          padding: const EdgeInsets.fromLTRB(10, 6, 14, 6),
                          decoration: BoxDecoration(color: AppColors.of(context), borderRadius: BorderRadius.circular(10)),
                          child: Row(mainAxisSize: MainAxisSize.min, children: [
                            groupIcon,
                            const SizedBox(width: 6),
                            Text(groupLabel, style: TextStyle(fontWeight: FontWeight.w700, color: AppColors.onSig(context), shadows: AppColors.sigShadows(context))),
                          ]),
                        ),
                      ),
                    ),
                  ),
                  const Divider(height: 1),
                  Expanded(child: KeyedSubtree(key: k('list'), child: list)),
                ],
              ),
              Positioned(
                right: 16,
                bottom: 16,
                child: Container(
                  key: k('add'),
                  width: 56,
                  height: 56,
                  decoration: BoxDecoration(color: AppColors.of(context), borderRadius: BorderRadius.circular(16), boxShadow: const [BoxShadow(color: Colors.black26, blurRadius: 6, offset: Offset(0, 2))]),
                  child: Icon(Icons.add, size: 28, color: AppColors.onSig(context), shadows: AppColors.sigShadows(context)),
                ),
              ),
            ],
          ),
        ),
      );
    }
    Widget barItem(String id, Widget icon, String label) => Expanded(
          child: Column(
            key: k(id),
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              SizedBox(height: 26, child: Center(child: icon)),
              const SizedBox(height: 3),
              Text(label, maxLines: 1, overflow: TextOverflow.ellipsis, style: TextStyle(fontSize: 12, fontWeight: FontWeight.w600, color: cs.onSurface)),
            ],
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
                iconBtn('refresh', const Icon(Icons.refresh)),
                iconBtn('sort', const SortBarsIcon(flipped: false)),
                const SizedBox(width: 4),
              ]),
            ),
            Expanded(child: list),
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
                      width: 52,
                      height: 52,
                      decoration: BoxDecoration(color: AppColors.of(context), shape: BoxShape.circle, boxShadow: const [BoxShadow(color: Colors.black26, blurRadius: 3, offset: Offset(0, 1))]),
                      child: Icon(Icons.add, size: 30, color: AppColors.onSig(context), shadows: AppColors.sigShadows(context)),
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
        b('direction', const DirectionArrowIcon(rightToLeft: false, size: 22)),
        b('memo', const QuillInkIcon(color: Colors.white, size: 22)),
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
            if (active)
              Container(
                width: kMemoToolExtent - 8,
                height: kMemoToolExtent - 8,
                decoration: BoxDecoration(color: AppColors.signature, borderRadius: BorderRadius.circular(10)),
              ),
            icon(active ? AppColors.onSignature : (color ?? Colors.white)),
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
                b('pen', (c) => QuillInkIcon(color: c, ink: const Color(0xFFE53935), size: 22), active: true),
                b('eraser', (c) => EraserIcon(color: c)),
                b('undo', (c) => Icon(Icons.undo, color: c, size: 16)),
                b('redo', (c) => Icon(Icons.redo, color: Colors.white30, size: 16)),
                b('clear', (c) => Icon(Icons.delete_sweep_outlined, color: c, size: 16), color: Colors.redAccent),
                SizedBox(
                  key: k('done'),
                  height: kMemoToolExtent,
                  child: Padding(
                    padding: const EdgeInsets.symmetric(horizontal: 11),
                    child: Center(child: Text(tr('완료', 'Done', '完成', '完了'), style: const TextStyle(color: Colors.amber, fontSize: 14, fontWeight: FontWeight.w600))),
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
          item('style', const Icon(Icons.dashboard_customize_outlined), tr('앱 스타일', 'App Style', '应用样式', 'アプリのスタイル'), sub: tr('기본', 'Default', '默认', '標準')),
          item('theme', const Icon(Icons.dark_mode_outlined), tr('앱 테마', 'App Theme', '应用主题', 'アプリのテーマ'), sub: tr('기본 시스템', 'System default', '跟随系统', 'システムのデフォルト')),
          item('lang', const LanguageGlyphIcon(size: 23), tr('언어', 'Language', '语言', '言語')),
          item('privacy', const Icon(Icons.lock_outline), tr('사생활 보호', 'Privacy', '隐私保护', 'プライバシー保護')),
          item('anim', const Icon(Icons.motion_photos_off_outlined), tr('애니메이션 끄기', 'Turn Off Animations', '关闭动画', 'アニメーションをオフ'), toggle: true),
          section(tr('파일', 'Files', '文件', 'ファイル')),
          item('view', const Icon(Icons.view_list_rounded), tr('파일 표시 방식', 'Bookshelf View Mode', '文件显示样式', 'ファイル表示形式')),
          item('remember', const Icon(Icons.bookmark_added_outlined), tr('페이지 기억하기', 'Remember Last Page', '记住页面', 'ページを記憶'), toggle: true),
          item('tapzone', const Icon(Icons.grid_view_outlined), tr('탭 영역', 'Tap Zones', '点击区域', 'タップ領域')),
          item('tapguide', const Icon(Icons.touch_app_outlined), tr('탭 가이드라인 끄기', 'Turn Off Tap Guide', '关闭点击指引', 'タップガイドをオフ'), toggle: true),
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
          item('terms', const Icon(Icons.gavel_outlined), tr('이용 약관', 'Terms of Service', '使用条款', '利用規約')),
          item('policy', const Icon(Icons.privacy_tip_outlined), tr('개인정보 처리방침', 'Privacy Policy', '隐私政策', 'プライバシーポリシー')),
          item('licenses', const Icon(Icons.article_outlined), tr('오픈소스 라이선스', 'Open Source Licenses', '开源许可', 'オープンソースライセンス')),
        ],
      ),
    );
  }
}
