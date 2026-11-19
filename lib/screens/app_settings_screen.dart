import 'dart:async';
import '../services/pro.dart';
import 'pro_screen.dart';
import '../widgets/favorite_ribbon.dart';
import '../widgets/file_type_icon.dart';
import 'user_fonts_screen.dart';
import 'tap_zone_screen.dart';
import 'legal_screen.dart';
import 'licenses_screen.dart';
import 'scan_folders_screen.dart';
import '../services/scan_folders.dart';
import 'privacy_lock_screen.dart';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:path_provider/path_provider.dart';
import '../widgets/pop_dialog.dart';
import '../widgets/app_colors.dart';

import '../services/storage_service.dart';
import '../widgets/choice_sheet.dart';
import 'language_select_screen.dart';

/// 앱 설정 화면: 항목을 누르면 아래에서 고르기 창이 올라온다.
class AppSettingsScreen extends StatefulWidget {
  const AppSettingsScreen({
    super.key,
    required this.appLang,
    required this.themeMode,
    required this.onChangeThemeMode,
    required this.viewMode,
    required this.hideExtension,
    this.hideGroupName = false,
    this.onChangeHideGroupName,
    this.hideThumbnails = false,
    this.onChangeHideThumbnails,
    this.hidePageCount = false,
    this.onChangeHidePageCount,
    required this.onChangeLanguage,
    required this.onChangeViewMode,
    required this.onChangeHideExtension,
    required this.onOpenGuide,
    this.scrollController,
    this.scrollPhysics,
    this.asSheet = false,
  });

  /// 지금 화면 문구에 쓰는 언어 (ko/en/zh/ja)
  final String appLang;
  final String themeMode; // 'system' | 'light' | 'dark'
  final Future<void> Function(String mode) onChangeThemeMode;
  final String viewMode; // 'grid' | 'list'
  final bool hideExtension;
  final bool hideGroupName;
  final Future<void> Function(bool hide)? onChangeHideGroupName;
  final bool hideThumbnails;
  final Future<void> Function(bool hide)? onChangeHideThumbnails;
  final bool hidePageCount;
  final Future<void> Function(bool hide)? onChangeHidePageCount;
  final ValueChanged<String> onChangeLanguage; // 'system' | ko/en/zh/ja
  final Future<void> Function(String mode) onChangeViewMode;
  final Future<void> Function(bool hide) onChangeHideExtension;
  final void Function(String lang) onOpenGuide;

  /// 아래에서 올라오는 창으로 띄울 때(위에서 아래로 끌어 닫기) 쓰는 스크롤 연결
  final ScrollController? scrollController;
  final ScrollPhysics? scrollPhysics;

  /// 창으로 띄웠는지: 맨 위 손잡이 줄과 '내리기' 버튼 표시
  final bool asSheet;

  @override
  State<AppSettingsScreen> createState() => _AppSettingsScreenState();
}

class _AppSettingsScreenState extends State<AppSettingsScreen> {
  late String _lang = widget.appLang;
  late String _langSetting = StorageService.appLangSetting ?? 'system';
  late String _themeMode = widget.themeMode;
  late String _viewMode = widget.viewMode;
  late bool _hideExt = widget.hideExtension;
  late bool _hideGroup = widget.hideGroupName;
  late bool _hideThumbs = widget.hideThumbnails;
  late bool _hidePages = widget.hidePageCount;
  bool _rememberPage = StorageService.rememberPage;

  bool _tapGuideOff = StorageService.tapGuideOff;

  @override
  void initState() {
    super.initState();
    _measureCache();
    _countScanFolders();
  }

  int _scanFolderCount = 0;
  Future<void> _countScanFolders() async {
    final n = (await ScanFolders.load()).length;
    if (mounted) setState(() => _scanFolderCount = n);
  }

  Future<void> _setTapGuideOff(bool v) async {
    setState(() => _tapGuideOff = v);
    await StorageService.setTapGuideOff(v);
  }

  Future<void> _setRememberPage(bool v) async {
    setState(() => _rememberPage = v);
    await StorageService.setRememberPage(v);
  }

  String _t(String ko, String en, String zh, String ja) => AppI18n.t(_lang, ko: ko, en: en, zh: zh, ja: ja);

  String _viewModeLabel(String mode) => mode == 'grid'
      ? _t('표지형 (썸네일)', 'Cover View (Thumbnail)', '封面视图 (缩略图)', '表紙表示 (サムネイル)')
      : _t('목록형 (리스트)', 'List View', '列表视图', 'リスト表示');

  String _themeLabel(String mode) => switch (mode) {
        'dark' => _t('다크 모드', 'Dark mode', '深色模式', 'ダークモード'),
        'comfort' => _t('편안한 모드', 'Comfort mode', '护眼模式', '目に優しいモード'),
        'light' => _t('라이트 모드', 'Light mode', '浅色模式', 'ライトモード'),
        _ => _t('기본 시스템', 'System default', '跟随系统', 'システムのデフォルト'),
      };

  Future<void> _pickTheme() async {
    final v = await showChoiceSheet<String>(
      context: context,
      title: _t('앱 테마', 'App Theme', '应用主题', 'アプリのテーマ'),
      options: [
        ChoiceOption('system', _themeLabel('system'), icon: Icons.brightness_auto_outlined),
        ChoiceOption('light', _themeLabel('light'), icon: Icons.light_mode_outlined),
        ChoiceOption('dark', _themeLabel('dark'), icon: Icons.dark_mode_outlined),
        ChoiceOption('comfort', _themeLabel('comfort'), icon: Icons.wb_incandescent_outlined),
      ],
      current: _themeMode,
      centered: StorageService.simpleStyle, // 심플: 가운데 창
    );
    if (v == null || !mounted) return;
    setState(() => _themeMode = v);
    await widget.onChangeThemeMode(v);
  }

  String _styleLabel(String style) =>
      style == 'simple' ? _t('심플', 'Simple', '简洁', 'シンプル') : _t('기본', 'Default', '默认', '標準');

  Future<void> _pickStyle() async {
    final v = await showChoiceSheet<String>(
      context: context,
      title: _t('앱 스타일', 'App Style', '应用样式', 'アプリのスタイル'),
      options: [
        ChoiceOption('basic', _styleLabel('basic'), icon: Icons.space_dashboard_outlined),
        ChoiceOption('simple', _styleLabel('simple'), icon: Icons.crop_square_rounded),
      ],
      current: StorageService.appStyle.value,
      centered: StorageService.simpleStyle, // 심플: 가운데 창
    );
    if (v == null || !mounted) return;
    await StorageService.setAppStyle(v);
    if (mounted) setState(() {});
  }

  Future<void> _pickLanguage() async {
    final v = await showChoiceSheet<String>(
      context: context,
      title: _t('언어', 'Language', '语言', '言語'),
      options: [for (final code in LanguageSelectScreen.options) ChoiceOption(code, languageOptionLabel(code))],
      current: _langSetting,
      centered: StorageService.simpleStyle, // 심플: 가운데 창
    );
    if (v == null || !mounted) return;
    widget.onChangeLanguage(v);
    setState(() {
      _langSetting = v;
      _lang = StorageService.resolveAppLanguage(v);
    });
  }

  /// 파일 표시 방식(표지형/목록형) + 파일 형식 숨기기 + 그룹 이름 숨기기 — 누르면 바로 적용
  Future<void> _pickViewMode() async {
    await showChoiceSheetWithToggle<String>(
      context: context,
      title: _t('파일 표시 방식', 'Bookshelf View Mode', '文件显示样式', 'ファイル表示形式'),
      // 완료 대신 초기화: 목록형, 모든 스위치 끔
      resetLabel: _t('초기화', 'Reset', '重置', 'リセット'),
      resetTo: 'list',
      options: [
        ChoiceOption('list', _viewModeLabel('list'), icon: Icons.view_list_rounded),
        ChoiceOption('grid', _viewModeLabel('grid'), icon: Icons.grid_view_rounded),
      ],
      current: _viewMode,
      centered: StorageService.simpleStyle, // 심플: 가운데 창
      toggleIcon: Icons.visibility_off_outlined,
      toggleLabel: _t('파일 형식 숨기기', 'Hide file type', '隐藏文件类型', 'ファイル形式を隠す'),
      toggleSubtitle: _t('.docx, .pdf 등', '.docx, .pdf, etc', '.docx、.pdf 等', '.docx、.pdf など'),
      toggleValue: _hideExt,
      onChanged: (r) async {
        final (mode, hide) = r;
        if (!mounted) return;
        final bool modeChanged = mode != _viewMode, hideChanged = hide != _hideExt;
        setState(() {
          _viewMode = mode;
          _hideExt = hide;
        });
        if (modeChanged) await widget.onChangeViewMode(mode);
        if (hideChanged) await widget.onChangeHideExtension(hide);
      },
      moreToggles: [
        // 목록형을 골랐을 때만: 파일을 옆으로 밀어 즐겨찾기·휴지통 하는 동작 끄기
        SheetToggle(
          icon: Icons.swipe_outlined,
          label: _t('밀어서 즐겨찾기·삭제 끄기', 'Turn off swipe actions', '关闭滑动收藏·删除', 'スワイプでお気に入り・削除をオフ'),
          subtitle: _t('파일을 옆으로 밀어도 즐겨찾기·휴지통 이동을 하지 않아요', 'Swiping a file no longer bookmarks or trashes it', '左右滑动文件不再收藏或移至回收站', 'ファイルを横にスワイプしてもお気に入り・ゴミ箱移動をしません'),
          value: StorageService.listSwipeOff.value,
          onlyFor: 'list',
          onChanged: (v) async {
            if (!mounted) return;
            setState(() {});
            await StorageService.setListSwipeOff(v);
          },
        ),
        // 표지형을 골랐을 때만: 표지 그림 끄기 (TXT처럼 가운데 아이콘만)
        SheetToggle(
          icon: Icons.hide_image_outlined,
          label: _t('표지 그림 끄기', 'Hide covers', '隐藏封面', '表紙を隠す'),
          subtitle: _t('표지 대신 파일 아이콘만', 'Show file icons only', '只显示文件图标', 'ファイルアイコンのみ'),
          value: _hideThumbs,
          onlyFor: 'grid',
          onChanged: (v) async {
            if (!mounted) return;
            setState(() => _hideThumbs = v);
            await widget.onChangeHideThumbnails?.call(v);
          },
        ),
        // 표지형을 골랐을 때만: 책갈피를 잡아당기지 않고 누르기만 해도 즐겨찾기 (기본은 잡아당기기)
        SheetToggle(
          icon: Icons.bookmark_remove_outlined,
          label: _t('책갈피 터치로 즐겨찾기', 'Tap bookmark to favorite', '轻触书签即可收藏', 'しおりをタップしてお気に入り'),
          subtitle: _t('당기지 않고 터치로 즐겨찾기', 'Tap instead of pulling', '无需下拉，轻触即可收藏', '引っ張らずにタップでお気に入り'),
          value: FavoriteRibbon.animationOff.value,
          onlyFor: 'grid',
          onChanged: (v) async {
            if (!mounted) return;
            setState(() => FavoriteRibbon.animationOff.value = v);
            await StorageService.setRibbonAnimationOff(v);
          },
        ),
        SheetToggle(
          icon: Icons.label_off_outlined,
          label: _t('그룹 이름 숨기기', 'Hide group name', '隐藏分组名称', 'グループ名を隠す'),
          subtitle: _t('파일 아래 [그룹 이름]', '[Group] under each file', '文件下方的 [分组]', 'ファイルの下の [グループ]'),
          value: _hideGroup,
          onChanged: (v) async {
            if (!mounted) return;
            setState(() => _hideGroup = v);
            await widget.onChangeHideGroupName?.call(v);
          },
        ),
        SheetToggle(
          icon: Icons.filter_none_outlined,
          label: _t('페이지 수 숨기기', 'Hide page count', '隐藏页数', 'ページ数を隠す'),
          subtitle: _t('파일 아래 (페이지 수)', 'Under each file (page count)', '文件下方的页数', 'ファイルの下のページ数'),
          value: _hidePages,
          onChanged: (v) async {
            if (!mounted) return;
            setState(() => _hidePages = v);
            await widget.onChangeHidePageCount?.call(v);
          },
        ),
      ],
    );
  }

  // ── 데이터 ──
  int? _cacheBytes;

  /// 지울 수 있는 임시 파일 폴더 (지워도 필요할 때 다시 만들어짐)
  Future<List<Directory>> _cacheDirs() async => [
        await getTemporaryDirectory(),
        Directory('${(await getApplicationSupportDirectory()).path}/outline_cache'),
      ];

  Future<void> _measureCache() async {
    int total = 0;
    try {
      for (final d in await _cacheDirs()) {
        if (!await d.exists()) continue;
        await for (final e in d.list(recursive: true, followLinks: false)) {
          if (e is File) {
            try {
              total += await e.length();
            } catch (_) {}
          }
        }
      }
    } catch (_) {}
    if (mounted) setState(() => _cacheBytes = total);
  }

  String _fmtBytes(int b) {
    if (b < 1024) return '${b}B';
    if (b < 1024 * 1024) return '${(b / 1024).toStringAsFixed(0)}KB';
    if (b < 1024 * 1024 * 1024) return '${(b / 1024 / 1024).toStringAsFixed(1)}MB';
    return '${(b / 1024 / 1024 / 1024).toStringAsFixed(2)}GB';
  }

  Future<void> _clearCache() async {
    final ok = await showPopDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text(_t('캐시 지우기', 'Clear Cache', '清除缓存', 'キャッシュを削除')),
        content: Text(_t('다시 만들 수 있는 임시 파일만 지워요\n지우면 파일을 열 때 조금 느려져요',
            'Delete temporary files such as pre-rendered pages and contents?\nYour files, notes and settings stay',
            '要删除预先渲染的页面、目录等临时文件吗？\n文件、笔记和设置不受影响',
            '事前に描いたページ・目次などの一時ファイルを削除しますか？\nファイル・メモ・設定はそのままです')),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx, false), child: Text(_t('취소', 'Cancel', '取消', 'キャンセル'))),
          ElevatedButton(onPressed: () => Navigator.pop(ctx, true), child: Text(_t('지우기', 'Clear', '清除', '削除'))),
        ],
      ),
    );
    if (ok != true || !mounted) return;
    for (final d in await _cacheDirs()) {
      try {
        if (!await d.exists()) continue;
        await for (final e in d.list(followLinks: false)) {
          try {
            await e.delete(recursive: true);
          } catch (_) {}
        }
      } catch (_) {}
    }
    PaintingBinding.instance.imageCache.clear();
    await _measureCache();
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(_t('캐시를 지웠어요', 'Cache cleared', '缓存已清除', 'キャッシュを削除しました'))));
  }

  Future<void> _clearData() async {
    final ok = await showPopDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text(_t('데이터 지우기', 'Clear Data', '清除数据', 'データを削除')),
        content: Text(_t('앱에 넣은 파일·메모·북마크·설정이 모두 지워지고 되돌릴 수 없어요\n허용해 둔 접근 권한도 해제되고, 지운 뒤 앱이 닫혀요\n합치기·스캔으로 만든 PDF도 앱 안에 저장돼 있어 함께 지워져요\nDownload 폴더 등에 있는 원본 파일과 공유로 다른 앱에 보낸 파일은 지워지지 않아요',
            'All files, notes, bookmarks and settings in the app will be deleted and cannot be restored\nGranted permissions are revoked and the app will close afterwards\nPDFs made by merging or scanning are stored in the app and will be deleted too\nOriginal files in folders such as Download and files sent to other apps by sharing are not deleted',
            '应用中的所有文件、笔记、书签和设置都将被删除且无法恢复\n已授予的权限也将被撤销，删除后应用将关闭\n合并·扫描生成的 PDF 也保存在应用中，将一并删除\nDownload 等文件夹中的原文件以及通过分享发送到其他应用的文件不会被删除',
            'アプリ内のファイル・メモ・ブックマーク・設定がすべて削除され、元に戻せません\n許可した権限も解除され、削除後アプリが閉じます\n結合・スキャンで作ったPDFもアプリ内に保存されているため一緒に削除されます\nDownloadなどのフォルダにある元のファイルや、共有で他のアプリに送ったファイルは削除されません')),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx, false), child: Text(_t('취소', 'Cancel', '取消', 'キャンセル'))),
          ElevatedButton(
            style: ElevatedButton.styleFrom(backgroundColor: Colors.redAccent, foregroundColor: Colors.white),
            onPressed: () => Navigator.pop(ctx, true),
            child: Text(_t('모두 지우기', 'Delete All', '全部删除', 'すべて削除')),
          ),
        ],
      ),
    );
    if (ok != true || !mounted) return;
    const ch = MethodChannel('ebook_reader/pdf_renderer');
    final done = await ch.invokeMethod<bool>('clearAppData').catchError((_) => false) ?? false;
    if (!done && mounted) {
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(_t('데이터를 지우지 못했어요', 'Could not clear data', '无法清除数据', 'データを削除できませんでした'))));
    }
  }

  Widget _section(String text) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(24, 20, 24, 6),
      child: Text(
        text,
        style: TextStyle(fontSize: 13.5, fontWeight: FontWeight.w800, color: Theme.of(context).colorScheme.onSurfaceVariant),
      ),
    );
  }

  Widget _item({
    required IconData icon,
    required String title,
    String? subtitle,
    VoidCallback? onTap,
    Widget? trailing,
    Widget? leading,
  }) {
    final cs = Theme.of(context).colorScheme;
    return ListTile(
      contentPadding: const EdgeInsets.symmetric(horizontal: 24, vertical: 4),
      leading: leading ?? Icon(icon, size: 23, color: cs.onSurface),
      title: Text(title, style: const TextStyle(fontSize: 16.5, fontWeight: FontWeight.w700)),
      subtitle: subtitle == null ? null : Text(subtitle, style: TextStyle(fontSize: 14, color: cs.onSurfaceVariant)),
      trailing: trailing ?? Icon(Icons.chevron_right, color: cs.onSurfaceVariant),
      onTap: onTap,
    );
  }

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    return Scaffold(
      appBar: widget.asSheet
          // 창으로 띄울 때: 맨 위 회색 막대 + 제목까지 간격 (밑에서 올라오는 모든 창과 같게), 그 아래 [∨ 앱 설정]
          ? PreferredSize(
              preferredSize: const Size.fromHeight(10 + 4 + 22 + 48),
              child: Material(
                color: Theme.of(context).appBarTheme.backgroundColor ?? cs.surface,
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    const SheetGrip(below: 22),
                    SizedBox(
                      height: 48,
                      child: Row(children: [
                        const SizedBox(width: 4),
                        IconButton(
                          icon: const Icon(Icons.keyboard_arrow_down),
                          tooltip: _t('닫기', 'Close', '关闭', '閉じる'),
                          onPressed: () => Navigator.maybePop(context),
                        ),
                        const SizedBox(width: 12),
                        Text(_t('앱 설정', 'App Settings', '应用设置', 'アプリ設定'),
                            style: (Theme.of(context).textTheme.titleLarge ?? const TextStyle()).copyWith(fontWeight: FontWeight.w800)),
                      ]),
                    ),
                  ],
                ),
              ),
            )
          : AppBar(title: Text(_t('앱 설정', 'App Settings', '应用设置', 'アプリ設定'), style: const TextStyle(fontWeight: FontWeight.w800))),
      body: SafeArea(
        top: !widget.asSheet,
        child: ListView(
          controller: widget.scrollController,
          physics: widget.scrollPhysics,
          padding: const EdgeInsets.only(bottom: 16),
          children: [
            _section(_t('일반', 'General', '通用', '一般')),
            // 앱 스타일: 기본(아래 막대) / 심플(위 막대)
            _item(
              icon: Icons.dashboard_customize_outlined,
              title: _t('앱 스타일', 'App Style', '应用样式', 'アプリのスタイル'),
              subtitle: _styleLabel(StorageService.appStyle.value),
              onTap: _pickStyle,
            ),
            _item(
              icon: Icons.dark_mode_outlined,
              title: _t('앱 테마', 'App Theme', '应用主题', 'アプリのテーマ'),
              subtitle: _themeLabel(_themeMode),
              onTap: _pickTheme,
            ),
            _item(
              icon: Icons.language,
              leading: const LanguageGlyphIcon(size: 23),
              title: _t('언어', 'Language', '语言', '言語'),
              subtitle: languageOptionLabel(_langSetting),
              onTap: _pickLanguage,
            ),
            // 사생활 보호: 앱 잠금·모든 파일 잠금 (비밀번호·패턴·생체 인식)
            _item(
              icon: Icons.lock_outline,
              title: _t('사생활 보호', 'Privacy', '隐私保护', 'プライバシー保護'),
              subtitle: _t('앱·파일을 비밀번호·패턴·생체 인식으로 잠가요', 'Lock the app and files with a PIN, pattern or biometrics', '用密码·图案·生物识别锁定应用和文件', 'アプリ・ファイルを暗証番号・パターン・生体認証でロックします'),
              onTap: () async {
                await Navigator.of(context).push(MaterialPageRoute(builder: (_) => PrivacyLockScreen(t: _t)));
                if (mounted) setState(() {});
              },
            ),
            // 애니메이션 끄기: 앱 전체의 움직임을 바로 바뀌게
            ValueListenableBuilder<bool>(
              valueListenable: Anim.off,
              builder: (context, off, _) => _item(
                icon: Icons.motion_photos_off_outlined,
                title: _t('애니메이션 끄기', 'Turn Off Animations', '关闭动画', 'アニメーションをオフ'),
                subtitle: _t('버튼·창이 움직임 없이 바로 바뀌어요', 'Buttons and windows change instantly without motion', '按钮和窗口立即切换，没有动画', 'ボタン・ウィンドウが動きなしですぐ切り替わります'),
                onTap: () => StorageService.setAnimOff(!off),
                trailing: Switch(value: off, onChanged: StorageService.setAnimOff),
              ),
            ),
            // 파일: 파일 목록·여는 방식에 관한 설정
            _section(_t('파일', 'Files', '文件', 'ファイル')),
            _item(
              icon: _viewMode == 'grid' ? Icons.grid_view_rounded : Icons.view_list_rounded,
              title: _t('파일 표시 방식', 'Bookshelf View Mode', '文件显示样式', 'ファイル表示形式'),
              // 지금 방식 + 형식 숨김 여부
              subtitle: [
                _viewModeLabel(_viewMode),
                if (_hideExt) _t('형식 숨김', 'extensions hidden', '隐藏扩展名', '形式を隠す'),
                if (_hideGroup) _t('그룹 숨김', 'groups hidden', '隐藏分组', 'グループを隠す'),
              ].join(' · '),
              onTap: _pickViewMode,
            ),
            _item(
              icon: Icons.bookmark_added_outlined,
              title: _t('페이지 기억하기', 'Remember Last Page', '记住页面', 'ページを記憶'),
              subtitle: _t('마지막으로 읽던 쪽으로 열어요', 'Opens at the page you last read', '打开到上次阅读的页面', '最後に読んだページで開きます'),
              onTap: () => _setRememberPage(!_rememberPage),
              trailing: Switch(value: _rememberPage, onChanged: _setRememberPage),
            ),
            _item(
              icon: Icons.grid_view_outlined,
              title: _t('탭 영역', 'Tap Zones', '点击区域', 'タップ領域'),
              subtitle: _t('영역별로 눌렀을 때의 동작을 정해요', 'Set what tapping each area does', '设置点击各区域时的操作', 'エリアごとのタップ時の動作を決めます'),
              onTap: () => Navigator.of(context).push(MaterialPageRoute(builder: (_) => TapZoneScreen(t: _t))),
            ),
            _item(
              icon: Icons.touch_app_outlined,
              title: _t('탭 가이드라인 끄기', 'Turn Off Tap Guide', '关闭点击指引', 'タップガイドをオフ'),
              subtitle: _t('파일을 열 때마다 탭 영역 안내를 보여 주지 않아요', 'Does not show the tap zone guide each time a file opens', '每次打开文件时不显示点击区域指引', 'ファイルを開くたびにタップ領域の案内を表示しません'),
              onTap: () => _setTapGuideOff(!_tapGuideOff),
              trailing: Switch(value: _tapGuideOff, onChanged: _setTapGuideOff),
            ),
            // 파일 탐색·글꼴 찾기가 찾아볼 폴더 (사용자가 고른 폴더만 읽음)
            _item(
              icon: Icons.folder_open_outlined,
              title: _t('탐색할 폴더', 'Folders to Search', '要查找的文件夹', '探すフォルダ'),
              subtitle: _scanFolderCount == 0
                  ? _t('파일 탐색·글꼴 찾기가 찾을 폴더', 'Where Find Files and Find Fonts search', '查找文件·查找字体的位置', 'ファイル検索・フォント検索が探すフォルダ')
                  : _t('폴더 $_scanFolderCount개', '$_scanFolderCount folder(s)', '$_scanFolderCount 个文件夹', 'フォルダ $_scanFolderCount 個'),
              onTap: () async {
                await Navigator.of(context).push(MaterialPageRoute(builder: (_) => ScanFoldersScreen(appLang: _lang)));
                _countScanFolders();
              },
            ),
            // (스크롤 보기는 이제 문서 화면 안에서 바로 보여 주므로 미리 준비·준비 완료 알림 설정이 필요 없음)
            _section(_t('글꼴', 'Fonts', '字体', 'フォント')),
            _item(
              icon: Icons.description_outlined,
              leading: const DocPairIcon(size: 25),
              title: _t('한글·워드 글꼴', 'HWP·Word Fonts', 'HWP·Word 字体', 'HWP・Wordフォント'),
              subtitle: _t('문서 글꼴', 'Document fonts', '文档字体', '文書フォント'),
              onTap: () => Navigator.of(context).push(MaterialPageRoute(builder: (_) => UserFontsScreen(t: _t, category: 'doc'))),
            ),
            _item(
              icon: Icons.font_download_outlined,
              title: _t('앱 글꼴', 'App Font', '应用字体', 'アプリのフォント'),
              subtitle: _t('메뉴·목록·설정 화면 글꼴', 'Font for menus, lists and settings', '菜单、列表、设置的字体', 'メニュー・一覧・設定のフォント'),
              onTap: () => Navigator.of(context).push(MaterialPageRoute(builder: (_) => UserFontsScreen(t: _t, category: 'app'))),
            ),
            _item(
              icon: Icons.menu_book_outlined,
              leading: FileTypeIcon(ext: 'epub', size: 24, color: Theme.of(context).colorScheme.onSurface),
              title: _t('EPUB 글꼴', 'EPUB Font', 'EPUB字体', 'EPUBフォント'),
              subtitle: _t('EPUB 책 본문 글꼴', 'Font for EPUB book text', 'EPUB正文字体', 'EPUB本文のフォント'),
              onTap: () => Navigator.of(context).push(MaterialPageRoute(builder: (_) => UserFontsScreen(t: _t, category: 'epub'))),
            ),
            // 데이터: 캐시 지우기 · 데이터 지우기
            // 프로: FReader 프로 구매와 유료 기능 숨기기
            _section(_t('프로', 'Pro', '专业版', 'プロ')),
            // FReader 프로: 유료 기능 구매·복원과 무료 체험 상태
            ListenableBuilder(
              listenable: Listenable.merge([Pro.owned, Pro.trialChanged]),
              builder: (context, _) => _item(
                icon: Icons.workspace_premium_outlined,
                title: _t('FReader 프로', 'FReader Pro', 'FReader 专业版', 'FReader プロ'),
                subtitle: Pro.owned.value
                    ? _t('구매했어요', 'Purchased', '已购买', '購入済み')
                    : !Pro.trialStarted
                        ? _t('무료 체험을 시작할 수 있어요', 'You can start a free trial', '可以开始免费试用', '無料体験を始められます')
                        : Pro.trialActive
                            ? _t('무료 체험 ${Pro.durationText(_lang, Pro.trialLeft)} 남음', '${Pro.durationText(_lang, Pro.trialLeft)} of free trial left', '免费试用剩 ${Pro.durationText(_lang, Pro.trialLeft)}', '無料体験 残り${Pro.durationText(_lang, Pro.trialLeft)}')
                            : _t('무료 체험이 끝났어요', 'Your free trial has ended', '免费试用已结束', '無料体験は終了しました'),
                onTap: () async {
                  await Navigator.of(context).push(MaterialPageRoute(builder: (_) => ProScreen(lang: _lang)));
                  if (mounted) setState(() {});
                },
              ),
            ),
            // 유료 기능 숨기기: 파일 추가 메뉴에서 스캔·합치기를 감춤 (구매한 뒤에는 쓸 수 없음 — 유료 기능이 항상 보임)
            ListenableBuilder(
              listenable: Listenable.merge([Pro.hidePaid, Pro.owned]),
              builder: (context, _) {
                final bool owned = Pro.owned.value;
                final bool hide = Pro.hidePaid.value && !owned;
                return _item(
                  icon: Icons.visibility_off_outlined,
                  title: _t('유료 기능 숨기기', 'Hide Paid Features', '隐藏付费功能', '有料機能を隠す'),
                  subtitle: owned
                      ? _t('FReader 프로를 구매해서 유료 기능이 모두 보여요', 'All paid features are shown because you own FReader Pro', '已购买 FReader 专业版，付费功能全部显示', 'FReader プロを購入済みのため、有料機能はすべて表示されます')
                      : _t('파일 추가 메뉴에서 스캔·PDF 합치기·이미지 합치기를 숨겨요', 'Hides Scan, Merge PDFs and Merge Images in the Add Files menu',
                          '在添加文件菜单中隐藏扫描、合并 PDF 和合并图片', 'ファイル追加メニューでスキャン・PDF結合・画像結合を隠します'),
                  onTap: owned ? null : () => Pro.setHidePaid(!hide),
                  trailing: Switch(value: hide, onChanged: owned ? null : Pro.setHidePaid),
                );
              },
            ),
            _section(_t('데이터', 'Data', '数据', 'データ')),
            _item(
              icon: Icons.cleaning_services_outlined,
              title: _t('캐시 지우기', 'Clear Cache', '清除缓存', 'キャッシュを削除'),
              subtitle: _cacheBytes == null
                  ? _t('미리 그려 둔 쪽·목차 등 임시 파일', 'Temporary files such as pre-rendered pages and contents', '预先渲染的页面、目录等临时文件', '事前に描いたページ・目次などの一時ファイル')
                  : _t('임시 파일 ${_fmtBytes(_cacheBytes!)}', 'Temporary files ${_fmtBytes(_cacheBytes!)}', '临时文件 ${_fmtBytes(_cacheBytes!)}', '一時ファイル ${_fmtBytes(_cacheBytes!)}'),
              onTap: _clearCache,
            ),
            _item(
              icon: Icons.delete_forever_outlined,
              title: _t('데이터 지우기', 'Clear Data', '清除数据', 'データを削除'),
              subtitle: _t('파일·메모·설정·접근 권한을 모두 지우고 처음 상태로', 'Delete all files, notes, settings and permissions and start over', '删除所有文件、笔记、设置和权限，恢复初始状态', 'ファイル・メモ・設定・権限をすべて削除して初期状態に'),
              onTap: _clearData,
            ),
            _section(_t('도움말', 'Help', '帮助', 'ヘルプ')),
            _item(
              icon: Icons.lightbulb_outline,
              title: _t('가이드', 'Guide', '指南', 'ガイド'),
              subtitle: _t('예시 화면에서 단추를 하나씩 알려 줘요', 'Explains each button on a sample screen', '在示例画面上逐个介绍按钮', '見本の画面でボタンを一つずつ説明します'),
              onTap: () => widget.onOpenGuide(_lang),
            ),
            _item(
              icon: Icons.gavel_outlined,
              title: _t('이용 약관', 'Terms of Service', '使用条款', '利用規約'),
              onTap: () => Navigator.of(context).push(MaterialPageRoute(builder: (_) => LegalScreen(doc: LegalDoc.terms, lang: _lang))),
            ),
            _item(
              icon: Icons.privacy_tip_outlined,
              title: _t('개인정보 처리방침', 'Privacy Policy', '隐私政策', 'プライバシーポリシー'),
              onTap: () => Navigator.of(context).push(MaterialPageRoute(builder: (_) => LegalScreen(doc: LegalDoc.privacy, lang: _lang))),
            ),
            _item(
              icon: Icons.article_outlined,
              title: _t('오픈소스 라이선스', 'Open Source Licenses', '开源许可', 'オープンソースライセンス'),
              onTap: () => Navigator.of(context).push(MaterialPageRoute(builder: (_) => LicensesScreen(appLang: _lang))),
            ),
          ],
        ),
      ),
    );
  }
}
