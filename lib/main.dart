import 'dart:io';
import 'dart:math' as math;
import 'package:archive/archive.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:file_picker/file_picker.dart';
import 'package:google_mlkit_text_recognition/google_mlkit_text_recognition.dart';
import 'package:path_provider/path_provider.dart';
import 'screens/pdf_and_image_viewer.dart';
import 'screens/reader_screen.dart';
import 'services/storage_service.dart';
import 'services/batch_translation_service.dart';
import 'services/txt_to_epub_converter.dart';

void main() async {
  WidgetsFlutterBinding.ensureInitialized();
  await SystemChrome.setEnabledSystemUIMode(SystemUiMode.immersiveSticky, overlays: []);
  SystemChrome.setSystemUIChangeCallback((systemOverlaysAreVisible) async {
    if (systemOverlaysAreVisible) {
      await SystemChrome.setEnabledSystemUIMode(SystemUiMode.immersiveSticky, overlays: []);
    }
  });
  final initialDark = await StorageService.getDarkMode();
  final initialLang = await StorageService.getAppLanguage();
  runApp(MyEbookApp(initialDark: initialDark, initialLang: initialLang));
}

class MyEbookApp extends StatefulWidget {
  final bool initialDark;
  final String initialLang;
  const MyEbookApp({
    super.key,
    required this.initialDark,
    required this.initialLang,
  });

  @override
  State<MyEbookApp> createState() => _MyEbookAppState();
}

class _MyEbookAppState extends State<MyEbookApp> with SingleTickerProviderStateMixin {
  late bool _isDarkMode;
  late String _appLang;
  late final AnimationController _rotationAnimController;
  late final Animation<double> _rotationFadeAnim;
  late final Animation<double> _rotationScaleAnim;

  @override
  void initState() {
    super.initState();
    _isDarkMode = widget.initialDark;
    _appLang = widget.initialLang;
    _rotationAnimController = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 240),
      value: 1.0,
    );
    _rotationFadeAnim = Tween<double>(begin: 0.72, end: 1.0).animate(
      CurvedAnimation(parent: _rotationAnimController, curve: Curves.easeOutCubic),
    );
    _rotationScaleAnim = Tween<double>(begin: 0.96, end: 1.0).animate(
      CurvedAnimation(parent: _rotationAnimController, curve: Curves.easeOutCubic),
    );
    StorageService.desiredLandscapeNotifier.addListener(_onDesiredOrientationChanged);
  }

  void _onDesiredOrientationChanged() {
    if (mounted) {
      _rotationAnimController.forward(from: 0.0);
    }
  }

  @override
  void dispose() {
    StorageService.desiredLandscapeNotifier.removeListener(_onDesiredOrientationChanged);
    _rotationAnimController.dispose();
    super.dispose();
  }

  void _toggleDarkMode() async {
    final nextVal = !_isDarkMode;
    setState(() => _isDarkMode = nextVal);
    await StorageService.setDarkMode(nextVal);
  }

  void _changeAppLanguage(String newLang) async {
    setState(() => _appLang = newLang);
    await StorageService.setAppLanguage(newLang);
  }

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      debugShowCheckedModeBanner: false,
      title: 'FReader',
      themeMode: _isDarkMode ? ThemeMode.dark : ThemeMode.light,
      theme: ThemeData(
        useMaterial3: true,
        brightness: Brightness.light,
        colorSchemeSeed: Colors.indigo,
      ),
      darkTheme: ThemeData(
        useMaterial3: true,
        brightness: Brightness.dark,
        colorSchemeSeed: Colors.indigo,
      ),
      // 8. 태블릿 화면 회전 시 Navigator와 Overlay(툴팁/아이콘 이름, 뷰어 표시 설정 바텀시트, 다이얼로그)까지
      // 모두 동일한 방향으로 부드럽게 회전되도록 MaterialApp.builder 최상단에서 통합 처리!
      builder: (context, child) {
        return ValueListenableBuilder<bool?>(
          valueListenable: StorageService.desiredLandscapeNotifier,
          builder: (context, desiredLandscape, _) {
            final mq = MediaQuery.of(context);
            final bool physicalIsLandscape = mq.size.width > mq.size.height;
            final bool needsSoftwareRotation =
                desiredLandscape != null && physicalIsLandscape != desiredLandscape;
            final int quarterTurns = needsSoftwareRotation ? 1 : 0;

            final MediaQueryData effectiveMq = needsSoftwareRotation
                ? mq.copyWith(
                    size: Size(mq.size.height, mq.size.width),
                    padding: EdgeInsets.only(
                      top: mq.padding.left,
                      right: mq.padding.top,
                      bottom: mq.padding.right,
                      left: mq.padding.bottom,
                    ),
                    viewPadding: EdgeInsets.only(
                      top: mq.viewPadding.left,
                      right: mq.viewPadding.top,
                      bottom: mq.viewPadding.right,
                      left: mq.viewPadding.bottom,
                    ),
                    viewInsets: EdgeInsets.only(
                      top: mq.viewInsets.left,
                      right: mq.viewInsets.top,
                      bottom: mq.viewInsets.right,
                      left: mq.viewInsets.bottom,
                    ),
                  )
                : mq;

            return FadeTransition(
              opacity: _rotationFadeAnim,
              child: ScaleTransition(
                scale: _rotationScaleAnim,
                child: RotatedBox(
                  quarterTurns: quarterTurns,
                  child: MediaQuery(
                    data: effectiveMq,
                    child: child ?? const SizedBox.shrink(),
                  ),
                ),
              ),
            );
          },
        );
      },
      home: BookshelfScreen(
        isDarkMode: _isDarkMode,
        appLang: _appLang,
        onToggleDarkMode: _toggleDarkMode,
        onChangeLanguage: _changeAppLanguage,
      ),
    );
  }
}

/// 6. 실제 앱에 표시되는 아이콘 위젯들을 그대로 사용하여 위치를 시각적으로 보여주는 '사용 설명서' 화면
class UserManualScreen extends StatelessWidget {
  final String appLang;
  const UserManualScreen({super.key, required this.appLang});

  String _tr(String ko, String en, String zh, String ja) =>
      AppI18n.t(appLang, ko: ko, en: en, zh: zh, ja: ja);

  Widget _buildDualDirectionSampleIcon() {
    return const SizedBox(
      width: 24,
      height: 22,
      child: Stack(
        alignment: Alignment.center,
        children: [
          Positioned(top: 1, child: Icon(Icons.east, size: 14, color: Colors.amber)),
          Positioned(bottom: 1, child: Icon(Icons.west, size: 14, color: Colors.white54)),
        ],
      ),
    );
  }

  Widget _buildIconGuideRow({
    required Widget iconWidget,
    required String title,
    required String desc,
    Color iconBg = const Color(0xFF1E293B),
  }) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 8.0),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Container(
            width: 44,
            height: 44,
            decoration: BoxDecoration(
              color: iconBg,
              borderRadius: BorderRadius.circular(12),
            ),
            alignment: Alignment.center,
            child: iconWidget,
          ),
          const SizedBox(width: 14),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(title, style: const TextStyle(fontSize: 14, fontWeight: FontWeight.bold)),
                const SizedBox(height: 3),
                Text(desc, style: const TextStyle(fontSize: 12.5, height: 1.4)),
              ],
            ),
          ),
        ],
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: Text(_tr('사용 설명서', 'User Manual', '使用说明书', '取扱説明書')),
      ),
      body: SafeArea(
        child: ListView(
          padding: const EdgeInsets.all(16),
          children: [
            // 1. 서재(MY) 화면 상단 및 파일 아이콘 안내
            Text(
              _tr('1. 서재(MY) 화면 아이콘 안내', '1. Bookshelf (MY) Screen Icons', '1. 书架 (MY) 界面图标说明', '1. 書斎(MY)画面のアイコン説明'),
              style: const TextStyle(fontSize: 17, fontWeight: FontWeight.bold),
            ),
            const SizedBox(height: 10),
            // 실제 서재 상단 바 미리보기
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
              decoration: BoxDecoration(
                color: const Color(0xFF1E293B),
                borderRadius: BorderRadius.circular(14),
              ),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(
                    children: [
                      const Text(
                        'MY',
                        style: TextStyle(color: Colors.white, fontSize: 16, fontWeight: FontWeight.bold),
                      ),
                      const Spacer(),
                      const Icon(Icons.dark_mode, color: Colors.white, size: 20),
                      const SizedBox(width: 14),
                      const Icon(Icons.picture_as_pdf_outlined, color: Colors.white, size: 20),
                      const SizedBox(width: 14),
                      const Icon(Icons.auto_stories_outlined, color: Colors.white, size: 20),
                      const SizedBox(width: 14),
                      const Icon(Icons.delete_outline, color: Colors.white, size: 20),
                      const SizedBox(width: 14),
                      const Icon(Icons.settings_outlined, color: Colors.white, size: 20),
                    ],
                  ),
                  const SizedBox(height: 10),
                  Row(
                    children: [
                      Container(
                        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
                        decoration: BoxDecoration(
                          color: Colors.indigo,
                          borderRadius: BorderRadius.circular(8),
                        ),
                        child: Text(
                          _tr('전체', 'All', '全部', 'すべて'),
                          style: const TextStyle(color: Colors.white, fontSize: 12),
                        ),
                      ),
                      const SizedBox(width: 6),
                      Container(
                        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
                        decoration: BoxDecoration(
                          color: Colors.white12,
                          borderRadius: BorderRadius.circular(8),
                        ),
                        child: const Text('PDF/문서', style: TextStyle(color: Colors.white, fontSize: 12)),
                      ),
                      const SizedBox(width: 6),
                      Container(
                        padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
                        decoration: BoxDecoration(
                          border: Border.all(color: Colors.amber),
                          borderRadius: BorderRadius.circular(8),
                        ),
                        child: const Icon(Icons.add, size: 16, color: Colors.amber),
                      ),
                      const Spacer(),
                      const Icon(Icons.star_rounded, color: Colors.amber, size: 20),
                      const SizedBox(width: 10),
                      const Icon(Icons.edit_outlined, color: Colors.white70, size: 19),
                      const SizedBox(width: 10),
                      const Icon(Icons.drive_file_move_outline, color: Colors.white70, size: 19),
                    ],
                  ),
                ],
              ),
            ),
            const SizedBox(height: 12),
            _buildIconGuideRow(
              iconWidget: const Icon(Icons.dark_mode, color: Colors.white, size: 22),
              title: _tr('다크 모드 / 라이트 모드 전환', 'Toggle Dark / Light Mode', '切换深色 / 浅色模式', 'ダーク / ライトモード切替'),
              desc: _tr('앱 전체 화면 테마를 라이트 모드와 다크 모드로 전환합니다.', 'Switches the app theme between Light and Dark mode.', '在浅色模式和深色模式之间切换。', 'アプリ全体のテーマをライト/ダークに切り替えます。'),
            ),
            _buildIconGuideRow(
              iconWidget: const Icon(Icons.document_scanner_outlined, color: Colors.amber, size: 22),
              title: _tr('문서 스캔 (하단 [+ 파일 추가] 왼쪽 버튼)', 'Document Scan (Left of [+ Add Files])', '文档扫描（[+ 添加文件] 左侧按钮）', '文書スキャン（[+ ファイル追加] の左）'),
              desc: _tr('카메라로 책이나 글이 적힌 종이를 촬영하면 그림자를 제거하고 글자를 깔끔하게 정돈합니다. 촬영할 때마다 1, 2, 3... 순서대로 번호가 매겨지며 [PDF 파일로 형성]을 누르면 순서대로 배치된 PDF 파일이 생성됩니다.', 'Captures book pages or paper via camera, cleans background shadows, sharpens text, numbers each shot sequentially (1, 2, 3...), and builds a PDF in order.', '用相机拍摄书页或纸张，自动去除阴影并锐化文字，按拍摄顺序编号并生成 PDF 文件。', 'カメラで本や紙を撮影し、影を除去して文字を鮮明に補正します。撮影順に番号が振られ、順番通りのPDFを作成します。'),
            ),
            _buildIconGuideRow(
              iconWidget: const Icon(Icons.picture_as_pdf_outlined, color: Colors.white, size: 22),
              title: _tr('PDF 합치기', 'Merge PDFs', '合并 PDF', 'PDF結合'),
              desc: _tr('2개 이상의 PDF 파일을 고른 순서대로 또는 파일 이름 순서대로 합쳐 하나의 PDF로 만듭니다.', 'Merges 2 or more PDF files in selected order or filename order into a single PDF.', '按所选顺序或文件名顺序将多个 PDF 合并为一个 PDF。', '2つ以上のPDFを選択順または名前順に結合して1つのPDFにします。'),
            ),
            _buildIconGuideRow(
              iconWidget: const Icon(Icons.auto_stories_outlined, color: Colors.white, size: 22),
              title: _tr('JPG 이미지 합치기', 'Merge JPG Images', '合并 JPG 图片', 'JPG画像結合'),
              desc: _tr('여러 장의 JPG/PNG 이미지를 고른 순서 또는 이름 순서대로 묶어 단권 파일(.cbz)로 만듭니다.', 'Bundles multiple JPG/PNG images in selected or filename order into a single .cbz book.', '将多张图片按选择顺序或名称顺序打包为单本文件(.cbz)。', '複数のJPG/PNG画像を選択順または名前順にまとめて1冊(.cbz)にします。'),
            ),
            _buildIconGuideRow(
              iconWidget: const Icon(Icons.delete_outline, color: Colors.white, size: 22),
              title: _tr('휴지통', 'Trash Bin', '回收站', 'ゴミ箱'),
              desc: _tr('삭제된 파일을 확인하고 복원하거나 영구 삭제합니다.', 'Restore or permanently delete trashed files.', '查看、恢复或永久删除已删除的文件。', '削除したファイルの復元または完全削除を行います。'),
            ),
            _buildIconGuideRow(
              iconWidget: const Icon(Icons.settings_outlined, color: Colors.white, size: 22),
              title: _tr('앱 설정', 'App Settings', '应用设置', 'アプリ設定'),
              desc: _tr('앱 언어(한국어/영어/중국어/일본어) 변경, 파일 이름 뒤 형식(확장자) 숨기기, 사용 설명서를 확인합니다.', 'Change app language (KO/EN/ZH/JA), hide file extensions, and open the User Manual.', '更改应用语言、隐藏文件扩展名及查看使用说明书。', '言語(韓/英/中/日)変更、拡張子非表示、取扱説明書を確認します。'),
            ),
            _buildIconGuideRow(
              iconWidget: const Icon(Icons.add, color: Colors.amber, size: 24),
              title: _tr('새 그룹 추가 (+ 버튼)', 'Add New Group (+)', '新建分组 (+)', '新規グループ追加 (+)'),
              desc: _tr('그룹 네모칸 맨 오른쪽의 [+] 아이콘을 눌러 새 그룹을 추가합니다. (기존 그룹 길게 누르기: 삭제)', 'Tap [+] at the right end of the group bar to add a group (long-press a group to delete).', '点击分组栏最右侧的 [+] 新建分组（长按分组可删除）。', 'グループバー右端の[+]で新規グループを追加します(長押しで削除)。'),
            ),
            _buildIconGuideRow(
              iconWidget: const Icon(Icons.star_rounded, color: Colors.amber, size: 24),
              title: _tr('즐겨찾기 (별 아이콘)', 'Favorite (Star Icon)', '收藏 (星标)', 'お気に入り (星アイコン)'),
              desc: _tr('누르면 노란색 별(★)로 바뀌며 해당 그룹의 가장 상단에 위치합니다.', 'Turns yellow (★) and pins the file to the very top of its group.', '点击变为黄色星标(★)，并将文件置顶于当前分组最上方。', '黄色い星(★)になり、そのグループの最上部に固定されます。'),
            ),
            _buildIconGuideRow(
              iconWidget: const Icon(Icons.edit_outlined, color: Colors.white, size: 22),
              title: _tr('이름 변경 (연필 아이콘)', 'Rename File (Pencil Icon)', '重命名文件 (铅笔图标)', 'ファイル名変更 (鉛筆アイコン)'),
              desc: _tr('확장자를 유지한 채 파일 이름을 변경합니다.', 'Renames the file while preserving its format extension.', '保持扩展名不变并修改文件名称。', '拡張子を維持したままファイル名を変更します。'),
            ),
            _buildIconGuideRow(
              iconWidget: const Icon(Icons.drive_file_move_outline, color: Colors.white, size: 22),
              title: _tr('그룹 이동 (개별 및 다중 선택)', 'Move to Group (Single & Batch)', '移动分组 (单个与批量)', 'グループ移動 (個別・一括)'),
              desc: _tr('파일을 다른 그룹으로 옮깁니다. 파일을 길게 눌러 다중 선택하면 하단 [그룹 이동] 버튼으로 한 번에 이동할 수 있습니다.', 'Moves the file to another group. Long-press files to batch move multiple files at once.', '将文件移至其他分组；长按多选后可通过底部按钮批量移动。', '別のグループへ移動します。長押しで複数選択すると一括移動できます。'),
            ),

            const Divider(height: 36),

            // 2. 파일 열람 시 나오는 상단 UI 아이콘 안내
            Text(
              _tr('2. 파일 열람 시 상단 UI 아이콘 안내', '2. Viewer Top Bar Icons', '2. 阅读界面顶部栏图标说明', '2. ファイル閲覧時の上部UIアイコン説明'),
              style: const TextStyle(fontSize: 17, fontWeight: FontWeight.bold),
            ),
            const SizedBox(height: 10),
            // 실제 뷰어 상단 바 미리보기
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 10),
              decoration: BoxDecoration(
                color: Colors.black87,
                borderRadius: BorderRadius.circular(14),
              ),
              child: SingleChildScrollView(
                scrollDirection: Axis.horizontal,
                child: Row(
                  children: [
                    const Icon(Icons.arrow_back, color: Colors.white, size: 20),
                    const SizedBox(width: 12),
                    const Icon(Icons.list, color: Colors.white, size: 20),
                    const SizedBox(width: 12),
                    Text(
                      _tr('문서 제목', 'Document', '文档标题', '文書タイトル'),
                      style: const TextStyle(color: Colors.white, fontSize: 13, fontWeight: FontWeight.bold),
                    ),
                    const SizedBox(width: 18),
                    const Icon(Icons.skip_previous_rounded, color: Colors.white, size: 22),
                    const SizedBox(width: 12),
                    const Icon(Icons.skip_next_rounded, color: Colors.white, size: 22),
                    const SizedBox(width: 12),
                    const Icon(Icons.lock_outline, color: Colors.white, size: 19),
                    const SizedBox(width: 12),
                    const Icon(Icons.screen_rotation, color: Colors.white, size: 19),
                    const SizedBox(width: 12),
                    const Icon(Icons.draw_outlined, color: Colors.amber, size: 20),
                    const SizedBox(width: 12),
                    const Icon(Icons.menu_book, color: Colors.amber, size: 20),
                    const SizedBox(width: 12),
                    _buildDualDirectionSampleIcon(),
                    const SizedBox(width: 12),
                    const Icon(Icons.bookmarks_outlined, color: Colors.white, size: 20),
                    const SizedBox(width: 12),
                    const Icon(Icons.tune, color: Colors.white, size: 20),
                  ],
                ),
              ),
            ),
            const SizedBox(height: 12),
            _buildIconGuideRow(
              iconWidget: const Icon(Icons.arrow_back, color: Colors.white, size: 22),
              title: _tr('뒤로가기', 'Back to Bookshelf', '返回书架', '書斎へ戻る'),
              desc: _tr('서재 화면으로 돌아갑니다. (화면 잠금 상태였다면 자동으로 잠금이 해제되며, 백그라운드 번역은 계속 유지됩니다.)', 'Returns to the bookshelf (automatically unlocks screen if locked; background translation continues).', '返回书架（若处于锁定状态则自动解锁，后台翻译继续进行）。', '書斎に戻ります(画面ロック中は自動解除され、バックグラウンド翻訳は継続します)。'),
            ),
            _buildIconGuideRow(
              iconWidget: const Icon(Icons.list, color: Colors.white, size: 22),
              title: _tr('목차 열기 (문서/EPUB)', 'Table of Contents', '打开目录', '目次を開く'),
              desc: _tr('EPUB·워드·한글·텍스트 문서의 장(Chapter) 목록 서랍을 엽니다.', 'Opens the chapter drawer for EPUB/Word/HWP/TXT documents.', '打开文档章节目录侧边栏。', 'EPUB・Word・HWP・TXT文書の目次を開きます。'),
            ),
            _buildIconGuideRow(
              iconWidget: const Row(
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  Icon(Icons.skip_previous_rounded, color: Colors.white, size: 19),
                  Icon(Icons.skip_next_rounded, color: Colors.white, size: 19),
                ],
              ),
              title: _tr('이전 파일 / 다음 파일 이동 (같은 그룹)', 'Previous / Next File in Same Group', '同分组上一文件 / 下一文件', '同じグループ内の前 / 次のファイルへ移動'),
              desc: _tr('서재로 나가지 않고 현재 파일과 같은 그룹에 있는 이전 파일 또는 다음 파일로 즉시 이동합니다.', 'Jumps directly to the previous or next file within the same group without leaving the viewer.', '无需返回书架，直接切换到同一分组中的上一个或下一个文件。', '書斎に戻らずに同じグループ内の前/次のファイルを直接開きます。'),
            ),
            _buildIconGuideRow(
              iconWidget: const Icon(Icons.draw_outlined, color: Colors.amber, size: 22),
              title: _tr('S펜 필기 모드 열기/닫기', 'S Pen Handwriting Mode', 'S Pen 手写模式', 'Sペン手書きモード'),
              desc: _tr('S펜 전용 필기 툴바를 엽니다. 필기 모드가 켜진 동안에는 S펜으로 화면을 움직여도 페이지가 흔들리거나 넘어가지 않으며, 손가락 스와이프로만 페이지가 이동합니다.', 'Opens the S Pen toolbar. While active, S Pen strokes never move or turn the page; finger swipes turn pages.', '打开 S Pen 工具栏。开启时 S Pen 书写不会移动页面，仅手指滑动可翻页。', 'Sペンツールバーを開きます。手書き中はSペンで画面が動かず、指のスワイプでのみページがめくれます。'),
            ),
            _buildIconGuideRow(
              iconWidget: const Icon(Icons.menu_book, color: Colors.amber, size: 22),
              title: _tr('가로 모드 2페이지 양면 보기', 'Two-Page Spread in Landscape', '横屏双页显示', '横画面2ページ見開き表示'),
              desc: _tr('태블릿 가로 화면에서 한 화면에 2페이지씩 나란히 보여줄지 1페이지만 보여줄지 전환합니다.', 'Toggles between 2-page side-by-side spread and single-page view in landscape orientation.', '在横屏模式下切换双页并排显示或单页显示。', '横画面で2ページ見開き表示と1ページ表示を切り替えます。'),
            ),
            _buildIconGuideRow(
              iconWidget: const Icon(Icons.screen_rotation, color: Colors.white, size: 22),
              title: _tr('화면 회전', 'Rotate Screen', '旋转屏幕', '画面回転'),
              desc: _tr('뷰어 화면을 가로 또는 세로 방향으로 부드럽게 회전합니다.', 'Smoothly rotates the viewer between landscape and portrait orientations.', '平滑切换横屏或竖屏阅读方向。', 'ビューア画面を縦向き・横向きに滑らかに回転します。'),
            ),
            _buildIconGuideRow(
              iconWidget: _buildDualDirectionSampleIcon(),
              title: _tr('읽기 방향 전환 (좌 → 우 / 우 → 좌)', 'Reading Direction (L → R / R → L)', '阅读方向切换 (左 → 右 / 右 → 左)', '読書方向切替 (左 → 右 / 右 → 左)'),
              desc: _tr('일반 도서 방향(좌 → 우, 기본값)과 만화 방향(우 → 좌)을 전환하며, 각 파일마다 설정한 읽기 방향을 개별적으로 기억합니다.', 'Switches between L → R (default) and R → L reading direction and remembers it for each file individually.', '切换左 → 右（默认）与右 → 左方向，并为每个文件单独记忆。', '左 → 右(基本)と右 → 左を切り替え、ファイルごとに記憶します。'),
            ),
            _buildIconGuideRow(
              iconWidget: const Icon(Icons.bookmarks_outlined, color: Colors.white, size: 22),
              title: _tr('북마크 추가 및 목록', 'Bookmarks', '书签管理', 'ブックマーク'),
              desc: _tr('현재 페이지를 북마크에 저장하거나 저장된 북마크 위치로 즉시 이동합니다.', 'Saves the current page as a bookmark or jumps to saved bookmarks.', '添加当前页书签或跳转到已保存的书签位置。', '現在のページをブックマーク登録、または登録済み位置へ移動します。'),
            ),
            _buildIconGuideRow(
              iconWidget: const Icon(Icons.tune, color: Colors.white, size: 22),
              title: _tr('뷰어 표시 설정', 'Viewer Display Settings', '阅读器显示设置', '뷰어表示設定'),
              desc: _tr('글자 크기·배경색(완전 흰색/종이색/다크), 화면 잠금 방식(흔들기 / 음량 버튼 동시 입력), 페이지 전환 버튼(음량 / 페이지 이동 / S펜), 진행도 UI 위치를 설정합니다.', 'Configure font size, background (pure white/sepia/dark), screen lock (shake / dual volume), page turn buttons, and progress bar position.', '设置字号、背景色、屏幕锁定方式（摇晃/双音量键）、翻页按钮及进度条位置。', '文字サイズ・背景色(純白/セピア/ダーク)、画面ロック方式(振る/音量同時押し)、ページ 전환、進行度バー位置を設定します。'),
            ),

            const Divider(height: 36),

            // 3. S펜 툴바 & 하단 진행도 UI & 페이지 이동 버튼 안내
            Text(
              _tr('3. S펜 필기 툴바 및 하단 이동 아이콘 안내', '3. S Pen Toolbar & Bottom Navigation Icons', '3. S Pen 工具栏与底部导航图标', '3. Sペンツールバーと下部移動アイコン'),
              style: const TextStyle(fontSize: 17, fontWeight: FontWeight.bold),
            ),
            const SizedBox(height: 12),
            _buildIconGuideRow(
              iconWidget: const Icon(Icons.touch_app, color: Colors.amber, size: 22),
              title: _tr('손으로 글씨 쓰기 (한 손가락 모양 아이콘)', 'Finger Writing (One-Finger Icon)', '手指书写（单指图标）', '指で手書き（指差しアイコン）'),
              desc: _tr('S펜 필기 바에서 색상 원 왼쪽의 한 손가락 아이콘을 누르면 아이콘에 색상(노란색)이 켜지며 손가락으로 글씨를 쓸 수 있습니다. 손으로 글씨를 쓰는 동안에는 손터치 페이지 넘김이 자동으로 잠깁니다.', 'Tap the one-finger icon to the left of the colors to light it up in color and write with your finger. Touch page turning is automatically locked while finger writing is active.', '点击颜色左侧的单指图标使其亮起颜色即可用手指书写，书写期间自动锁定触屏翻页。', '色の左にある指アイコンを押すと色が点灯し指で手書きできます。手書き中は指でのページめくりが自動ロックされます。'),
            ),
            _buildIconGuideRow(
              iconWidget: const Icon(Icons.cleaning_services_outlined, color: Colors.amber, size: 22),
              title: _tr('지우개 / 색상(6색) / 필기 전체 지우기', 'Eraser, 6 Colors & Clear All Strokes', '橡皮擦、6种颜色与清空手写', '消しゴム・6色パレット・手書き全消去'),
              desc: _tr('노란·빨간·하늘·초록·흰색·검은색 펜 선택과 선 굵기 슬라이더(기본 2.0pt), 부드러운 부분 지우개(🧹), 텍스트 메모(📝), 필기 전체 지우기(🗑, 2페이지 보기 시 양쪽 페이지 모두 삭제)를 제공합니다.', 'Pick from 6 colors, adjust stroke width, smooth partial Eraser, text notes, or Clear All Strokes (clears both pages in 2-page mode).', '支持6种颜色、粗细滑块、平滑局部橡皮擦、文字备注及清空手写（双页模式下同时清空两页）。', '6色、太さスライダー、滑らかな消しゴム、テキストメモ、手書き全消去(2ページ表示時は両ページ消去)が使えます。'),
            ),
            _buildIconGuideRow(
              iconWidget: const Row(
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  Icon(Icons.first_page, color: Colors.white, size: 19),
                  Icon(Icons.last_page, color: Colors.white, size: 19),
                ],
              ),
              title: _tr('진행도 바 맨 처음 / 맨 마지막 페이지 이동 화살표', 'Jump to First / Last Page Arrows', '跳转至第一页 / 最后一页箭头', '最初 / 最後のページへ移動する矢印'),
              desc: _tr('진행도 슬라이더 양끝의 화살표를 누르면 문서의 맨 처음(1페이지)과 맨 마지막(끝 페이지)으로 즉시 이동합니다.', 'Tap the arrows at both ends of the progress bar to jump straight to the first or last page.', '点击进度条两端的箭头可直接跳至第一页或最后一页。', '進行度バー両端の矢印で最初(1ページ)と最後のページへ即座に移動します。'),
            ),
            _buildIconGuideRow(
              iconWidget: const Row(
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  Icon(Icons.arrow_back, color: Colors.amber, size: 18),
                  SizedBox(width: 2),
                  Icon(Icons.arrow_forward, color: Colors.amber, size: 18),
                ],
              ),
              title: _tr('우측 하단 페이지 이동 버튼 (← / →)', 'Bottom-Right Page Nav Buttons (← / →)', '右下角翻页按钮 (← / →)', '右下ページ移動ボタン (← / →)'),
              desc: _tr('뷰어 표시 설정에서 [페이지 이동 버튼]을 켜면 우측 하단에 나타나며, 상단 UI를 띄우지 않고 깔끔하게 이전(←)·다음(→) 페이지로 전환합니다.', 'When enabled in Viewer Settings, appears at the bottom-right to turn to the previous (←) or next (→) page without popping up the top bar.', '在阅读器设置中开启后显示在右下角，点击左(←)/右(→)箭头可直接翻页且不会弹出顶部菜单。', '뷰어設定でONにすると右下に表示され、上部UIを出さずに前(←)・次(→)のページへ移動します。'),
            ),
          ],
        ),
      ),
    );
  }
}

class BookshelfScreen extends StatefulWidget {
  final bool isDarkMode;
  final String appLang;
  final VoidCallback onToggleDarkMode;
  final ValueChanged<String> onChangeLanguage;

  const BookshelfScreen({
    super.key,
    required this.isDarkMode,
    required this.appLang,
    required this.onToggleDarkMode,
    required this.onChangeLanguage,
  });

  @override
  State<BookshelfScreen> createState() => _BookshelfScreenState();
}

class _BookshelfScreenState extends State<BookshelfScreen> {
  static const MethodChannel _pdfChannel = MethodChannel('ebook_reader/pdf_renderer');

  List<File> _allBooks = [];
  List<File> _trashedBooks = [];
  List<String> _groups = ['전체', 'PDF/문서'];
  String _selectedGroup = '전체';
  Map<String, String> _bookGroupMap = {};
  Map<String, double> _bookProgressMap = {};
  Set<String> _favoritePaths = {};
  bool _hideFileExtension = false;
  String _bookshelfViewMode = 'list'; // 기본값: 'list' (목록형)
  final Map<String, String?> _thumbnailPathCache = {};
  final Set<String> _thumbnailGeneratingPaths = {};

  bool _isSelectionMode = false;
  final Set<String> _selectedFilePaths = {};
  final ScrollController _bookshelfScrollController = ScrollController();
  final Map<String, GlobalKey> _fileRowKeys = {};
  bool _isDragSelecting = false;
  bool _dragTargetSelectState = true;
  String? _lastDragTouchedPath;
  String? _pointerDownRowPath;
  Offset? _pointerDownGlobalPos;

  // 10, 11 & 13. 워드(.docx, .doc), 한글(.hwpx, .hwp), 메모장(.txt) 뷰어 열람 지원 (YML 제외)
  static const _supportedExts = [
    'epub', 'txt', 'pdf', 'jpg', 'jpeg', 'png', 'webp', 'cbz',
    'docx', 'doc', 'hwpx', 'hwp'
  ];
  static const _imageExts = ['jpg', 'jpeg', 'png', 'webp'];
  static const _docConvertExts = ['txt', 'docx', 'doc', 'hwpx', 'hwp'];

  String? _findFileRowPathAtGlobalPos(Offset globalPos) {
    for (final entry in _fileRowKeys.entries) {
      final ctx = entry.value.currentContext;
      if (ctx == null) continue;
      final box = ctx.findRenderObject() as RenderBox?;
      if (box == null || !box.hasSize || !box.attached) continue;
      final topLeft = box.localToGlobal(Offset.zero);
      final rect = topLeft & box.size;
      if (rect.contains(globalPos)) {
        return entry.key;
      }
    }
    return null;
  }

  void _applyDragSelectionAtGlobalPos(Offset globalPos) {
    final hitPath = _findFileRowPathAtGlobalPos(globalPos);
    if (hitPath != null && hitPath != _lastDragTouchedPath) {
      _lastDragTouchedPath = hitPath;
      setState(() {
        if (_dragTargetSelectState) {
          _selectedFilePaths.add(hitPath);
        } else {
          _selectedFilePaths.remove(hitPath);
        }
      });
    }
    if (_bookshelfScrollController.hasClients) {
      final screenH = MediaQuery.of(context).size.height;
      final pos = _bookshelfScrollController.position;
      if (globalPos.dy < 160 && pos.pixels > pos.minScrollExtent) {
        _bookshelfScrollController.jumpTo(
          (pos.pixels - 12.0).clamp(pos.minScrollExtent, pos.maxScrollExtent),
        );
      } else if (globalPos.dy > screenH - 120 && pos.pixels < pos.maxScrollExtent) {
        _bookshelfScrollController.jumpTo(
          (pos.pixels + 12.0).clamp(pos.minScrollExtent, pos.maxScrollExtent),
        );
      }
    }
  }

  String _tr(String ko, String en, String zh, String ja) =>
      AppI18n.t(widget.appLang, ko: ko, en: en, zh: zh, ja: ja);

  String _localizeGroupName(String g) {
    if (g == '전체') return _tr('전체', 'All', '全部', 'すべて');
    if (g == '미분류') return _tr('미분류', 'Uncategorized', '未分类', '未分類');
    if (g == 'PDF/문서') return _tr('PDF/문서', 'PDF/Docs', 'PDF/文档', 'PDF/文書');
    return g;
  }

  String _formatDisplayFileName(String rawFileName) {
    if (!_hideFileExtension) return rawFileName;
    final dotIdx = rawFileName.lastIndexOf('.');
    if (dotIdx > 0) {
      return rawFileName.substring(0, dotIdx);
    }
    return rawFileName;
  }

  @override
  void initState() {
    super.initState();
    BatchTranslationService.translationCompletedEvent.addListener(_onTranslationFinishedInBackground);
    _loadLibrary();
  }

  @override
  void dispose() {
    BatchTranslationService.translationCompletedEvent.removeListener(_onTranslationFinishedInBackground);
    super.dispose();
  }

  void _onTranslationFinishedInBackground() {
    if (mounted) {
      _loadLibrary();
    }
  }

  int _naturalCompare(String a, String b) {
    final reg = RegExp(r'(\d+)|(\D+)');
    final matchesA = reg.allMatches(a.toLowerCase()).toList();
    final matchesB = reg.allMatches(b.toLowerCase()).toList();
    final len = matchesA.length < matchesB.length ? matchesA.length : matchesB.length;
    for (int i = 0; i < len; i++) {
      final partA = matchesA[i].group(0)!;
      final partB = matchesB[i].group(0)!;
      final numA = int.tryParse(partA);
      final numB = int.tryParse(partB);
      if (numA != null && numB != null) {
        final cmp = numA.compareTo(numB);
        if (cmp != 0) return cmp;
      } else {
        final cmp = partA.compareTo(partB);
        if (cmp != 0) return cmp;
      }
    }
    return matchesA.length.compareTo(matchesB.length);
  }

  Future<Directory> _getTrashDirectory() async {
    final appDir = await getApplicationDocumentsDirectory();
    final trashDir = Directory('${appDir.path}/.trash_bin');
    if (!await trashDir.exists()) {
      await trashDir.create(recursive: true);
    }
    return trashDir;
  }

  Future<void> _loadLibrary() async {
    final dir = await getApplicationDocumentsDirectory();
    final trashDir = await _getTrashDirectory();

    final entities = dir.listSync();
    final files = <File>[];

    for (final e in entities) {
      if (e is File) {
        final lower = e.path.toLowerCase();
        if (lower.endsWith('_translated.epub') ||
            lower.endsWith('.converted.epub') ||
            lower.endsWith('_converted.epub')) continue;
        final ext = lower.split('.').last;
        if (_supportedExts.contains(ext)) {
          files.add(e);
        }
      }
    }

    final trashEntities = trashDir.listSync();
    final trashed = <File>[];
    for (final e in trashEntities) {
      if (e is File) {
        trashed.add(e);
      }
    }

    final favs = await StorageService.getFavoriteBooks();
    final hideExt = await StorageService.getHideFileExtension();
    final viewMode = await StorageService.getBookshelfViewMode();

    files.sort((a, b) {
      final aFav = favs.contains(a.path);
      final bFav = favs.contains(b.path);
      if (aFav != bFav) return aFav ? -1 : 1;
      return _naturalCompare(
        a.path.split(Platform.pathSeparator).last,
        b.path.split(Platform.pathSeparator).last,
      );
    });

    trashed.sort((a, b) => _naturalCompare(
          a.path.split(Platform.pathSeparator).last,
          b.path.split(Platform.pathSeparator).last,
        ));

    final groups = await StorageService.getGroups();
    final grpMap = <String, String>{};
    final progMap = <String, double>{};

    for (final f in files) {
      grpMap[f.path] = await StorageService.getBookGroup(f.path);
      progMap[f.path] = await StorageService.getProgress(f.path);
    }

    if (mounted) {
      setState(() {
        _allBooks = files;
        _trashedBooks = trashed;
        _groups = groups;
        _favoritePaths = favs;
        _hideFileExtension = hideExt;
        _bookshelfViewMode = viewMode;
        if (!_groups.contains(_selectedGroup)) {
          _selectedGroup = '전체';
        }
        _bookGroupMap = grpMap;
        _bookProgressMap = progMap;
        _selectedFilePaths.removeWhere((p) => !_allBooks.any((f) => f.path == p));
        if (_selectedFilePaths.isEmpty) {
          _isSelectionMode = false;
        }
      });
      for (final f in files) {
        _ensureBookThumbnail(f);
      }
    }
  }

  /// 13. 각 파일의 가장 첫 페이지를 썸네일 이미지로 생성 및 캐싱
  Future<void> _ensureBookThumbnail(File file) async {
    final path = file.path;
    if (_thumbnailPathCache.containsKey(path) && _thumbnailPathCache[path] != null) {
      if (File(_thumbnailPathCache[path]!).existsSync()) return;
    }
    if (_thumbnailGeneratingPaths.contains(path)) return;
    _thumbnailGeneratingPaths.add(path);

    try {
      final ext = path.split('.').last.toLowerCase();
      if (_imageExts.contains(ext)) {
        if (mounted) {
          setState(() => _thumbnailPathCache[path] = path);
        }
        return;
      }

      final appDir = await getApplicationDocumentsDirectory();
      final thumbDir = Directory('${appDir.path}/.thumbnails');
      if (!await thumbDir.exists()) {
        await thumbDir.create(recursive: true);
      }
      final safeKey = path.hashCode.toUnsigned(32).toString();
      final stat = await file.stat();
      final thumbPath = '${thumbDir.path}/thumb_hq26_${safeKey}_${stat.size}.jpg';
      final thumbFile = File(thumbPath);

      if (await thumbFile.exists() && await thumbFile.length() > 64) {
        if (mounted) {
          setState(() => _thumbnailPathCache[path] = thumbPath);
        }
        return;
      }

      if (ext == 'pdf') {
        final rendered = await _pdfChannel.invokeMethod<String>(
          'renderPdfFirstPageThumbnail',
          {
            'filePath': path,
            'outPath': thumbPath,
            'maxWidth': 1080,
          },
        );
        if (rendered != null && File(rendered).existsSync()) {
          if (mounted) {
            setState(() => _thumbnailPathCache[path] = rendered);
          }
          return;
        }
      } else if (ext == 'cbz' || ext == 'epub') {
        final bytes = await file.readAsBytes();
        final archive = ZipDecoder().decodeBytes(bytes);
        final imgEntries = archive.files.where((af) {
          if (!af.isFile) return false;
          final n = af.name.toLowerCase();
          return n.endsWith('.jpg') || n.endsWith('.jpeg') || n.endsWith('.png') || n.endsWith('.webp');
        }).toList();
        if (imgEntries.isNotEmpty) {
          imgEntries.sort((a, b) => _naturalCompare(a.name, b.name));
          final firstImg = imgEntries.first;
          final content = firstImg.content as List<int>;
          await thumbFile.writeAsBytes(content, flush: true);
          if (mounted) {
            setState(() => _thumbnailPathCache[path] = thumbPath);
          }
          return;
        }
      }
      _thumbnailPathCache[path] = null;
    } catch (_) {
      _thumbnailPathCache[path] = null;
    } finally {
      _thumbnailGeneratingPaths.remove(path);
    }
  }

  /// 1. OSS-DocumentScanner & Simple Scan PDF 방식 스캔 엔진:
  /// - ML Kit 온디바이스 글자 영역 인식 + 적분 영상 기반 Sauvola 적응형 이진화로
  ///   스캔본의 글자/표만 추출해 순백색(#FFFFFF) 빈 종이에 여백 없이(Zero-Margin) 배치!
  Future<File> _processRawScanToPureTextPage(File rawFile, String filterMode) async {
    final List<Map<String, int>> textBoxes = [];
    if (filterMode != 'magic_color') {
      final recognizer = TextRecognizer(script: TextRecognitionScript.korean);
      try {
        final inputImage = InputImage.fromFilePath(rawFile.path);
        final recognized = await recognizer.processImage(inputImage);
        for (final block in recognized.blocks) {
          final r = block.boundingBox;
          textBoxes.add({
            'left': r.left.round(),
            'top': r.top.round(),
            'right': r.right.round(),
            'bottom': r.bottom.round(),
          });
          for (final line in block.lines) {
            final lr = line.boundingBox;
            textBoxes.add({
              'left': lr.left.round(),
              'top': lr.top.round(),
              'right': lr.right.round(),
              'bottom': lr.bottom.round(),
            });
          }
        }
      } catch (_) {
      } finally {
        try {
          await recognizer.close();
        } catch (_) {}
      }
    }

    try {
      final String? processedPath = await _pdfChannel.invokeMethod<String>(
        'processScannedPageWithTextIsolation',
        {
          'imagePath': rawFile.path,
          'filterMode': filterMode,
          'textBoxes': textBoxes,
        },
      );
      if (processedPath != null && File(processedPath).existsSync()) {
        return File(processedPath);
      }
    } catch (_) {}
    return rawFile;
  }

  Future<void> _openDocumentScannerDialog() async {
    final now = DateTime.now();
    final dateStr = '${now.year}${now.month.toString().padLeft(2, '0')}${now.day.toString().padLeft(2, '0')}';
    final rand4 = (1000 + math.Random().nextInt(9000)).toString();
    final defaultTitle = '스캔_${dateStr}_$rand4';
    final titleController = TextEditingController(text: defaultTitle);

    // 원본 촬영 파일과 보정된 결과 파일을 함께 관리하여 필터 변경 시 즉시 재적용 가능
    final List<File> rawCapturedPages = [];
    final List<File> scannedPages = [];
    String selectedFilterMode = 'text_only_zero_margin'; // 기본값: 글자만 인식해 빈 종이에 여백 없이 배치
    bool isCapturing = false;
    bool isBuildingPdf = false;
    bool autoLaunchedFirstCamera = false;

    Future<void> triggerCameraCapture(StateSetter setModalState) async {
      if (isCapturing || isBuildingPdf) return;
      setModalState(() => isCapturing = true);
      try {
        final String? rawPath = await _pdfChannel.invokeMethod<String>('captureAndScanDocumentPage');
        if (rawPath != null && File(rawPath).existsSync()) {
          final rawFile = File(rawPath);
          final processedFile = await _processRawScanToPureTextPage(rawFile, selectedFilterMode);
          setModalState(() {
            rawCapturedPages.add(rawFile);
            scannedPages.add(processedFile);
          });
        }
      } catch (e) {
        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(content: Text('${_tr("카메라 스캔 오류", "Camera Scan Error", "扫描错误", "スキャンエラー")}: $e')),
          );
        }
      } finally {
        setModalState(() => isCapturing = false);
      }
    }

    Future<void> importImagesFromGalleryForScan(StateSetter setModalState) async {
      if (isCapturing || isBuildingPdf) return;
      final picked = await FilePicker.platform.pickFiles(
        type: FileType.image,
        allowMultiple: true,
      );
      if (picked == null || picked.files.isEmpty) return;
      setModalState(() => isCapturing = true);
      try {
        for (final pf in picked.files) {
          if (pf.path == null) continue;
          final rawFile = File(pf.path!);
          if (!rawFile.existsSync()) continue;
          final processedFile = await _processRawScanToPureTextPage(rawFile, selectedFilterMode);
          rawCapturedPages.add(rawFile);
          scannedPages.add(processedFile);
        }
      } finally {
        setModalState(() => isCapturing = false);
      }
    }

    Future<void> reapplyFilterToAllPages(String newMode, StateSetter setModalState) async {
      if (isCapturing || isBuildingPdf || selectedFilterMode == newMode) return;
      setModalState(() {
        selectedFilterMode = newMode;
        isCapturing = true;
      });
      try {
        final List<File> updated = [];
        for (int i = 0; i < rawCapturedPages.length; i++) {
          final res = await _processRawScanToPureTextPage(rawCapturedPages[i], newMode);
          updated.add(res);
        }
        setModalState(() {
          scannedPages
            ..clear()
            ..addAll(updated);
        });
      } finally {
        setModalState(() => isCapturing = false);
      }
    }

    if (!mounted) return;
    await showDialog(
      context: context,
      barrierDismissible: false,
      builder: (ctx) => StatefulBuilder(
        builder: (ctx, setModalState) {
          if (!autoLaunchedFirstCamera) {
            autoLaunchedFirstCamera = true;
            WidgetsBinding.instance.addPostFrameCallback((_) {
              triggerCameraCapture(setModalState);
            });
          }

          return AlertDialog(
            titlePadding: const EdgeInsets.fromLTRB(18, 14, 18, 6),
            contentPadding: const EdgeInsets.fromLTRB(16, 6, 16, 8),
            title: Row(
              children: [
                const Icon(Icons.document_scanner_outlined, color: Colors.indigo, size: 22),
                const SizedBox(width: 8),
                Expanded(
                  child: Text(
                    _tr(
                      '심플 문서 스캔 (${scannedPages.length}장)',
                      'Simple Document Scan (${scannedPages.length})',
                      '文档扫描 (${scannedPages.length}页)',
                      'シンプル文書スキャン (${scannedPages.length}枚)',
                    ),
                    style: const TextStyle(fontSize: 16.5, fontWeight: FontWeight.bold),
                  ),
                ),
              ],
            ),
            content: SizedBox(
              width: 480,
              height: 470,
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  TextField(
                    controller: titleController,
                    enabled: !isBuildingPdf,
                    decoration: InputDecoration(
                      labelText: _tr('생성할 PDF 파일 이름', 'Output PDF Filename', '生成的 PDF 文件名', '作成するPDFファイル名'),
                      suffixText: '.pdf',
                      isDense: true,
                      border: const OutlineInputBorder(),
                    ),
                  ),
                  const SizedBox(height: 8),
                  // OSS-DocumentScanner & Simple Scan 필터 모드 선택 칩
                  SingleChildScrollView(
                    scrollDirection: Axis.horizontal,
                    child: Row(
                      children: [
                        ChoiceChip(
                          visualDensity: VisualDensity.compact,
                          label: Text(
                            _tr('글자만 추출 (여백 없음)', 'Text Only (Zero Margin)', '仅提取文字 (无边距)', '文字のみ抽出 (余白なし)'),
                            style: const TextStyle(fontSize: 11.5),
                          ),
                          selected: selectedFilterMode == 'text_only_zero_margin',
                          onSelected: (_) => reapplyFilterToAllPages('text_only_zero_margin', setModalState),
                        ),
                        const SizedBox(width: 6),
                        ChoiceChip(
                          visualDensity: VisualDensity.compact,
                          label: Text(
                            _tr('백지 흑백 (전체 면)', 'Clean B&W (Full Page)', '净白黑白 (全页)', '白紙モノクロ (全面)'),
                            style: const TextStyle(fontSize: 11.5),
                          ),
                          selected: selectedFilterMode == 'full_bw',
                          onSelected: (_) => reapplyFilterToAllPages('full_bw', setModalState),
                        ),
                        const SizedBox(width: 6),
                        ChoiceChip(
                          visualDensity: VisualDensity.compact,
                          label: Text(
                            _tr('매직 컬러', 'Magic Color', '增强彩色', 'マジックカラー'),
                            style: const TextStyle(fontSize: 11.5),
                          ),
                          selected: selectedFilterMode == 'magic_color',
                          onSelected: (_) => reapplyFilterToAllPages('magic_color', setModalState),
                        ),
                      ],
                    ),
                  ),
                  const SizedBox(height: 8),
                  Expanded(
                    child: isCapturing
                        ? Center(
                            child: Column(
                              mainAxisSize: MainAxisSize.min,
                              children: [
                                const CircularProgressIndicator(),
                                const SizedBox(height: 14),
                                Text(
                                  _tr(
                                    '스캔본의 글자만 인식하여\n빈 종이에 여백 없이 깔끔하게 배치 중입니다...',
                                    'Isolating text onto a blank white page\nwith zero margins...',
                                    '正在识别文字并无边距排版至空白页...',
                                    '文字のみを認識して白紙に余白なしで配置中...',
                                  ),
                                  textAlign: TextAlign.center,
                                  style: const TextStyle(fontSize: 13),
                                ),
                              ],
                            ),
                          )
                        : scannedPages.isEmpty
                            ? Center(
                                child: Column(
                                  mainAxisSize: MainAxisSize.min,
                                  children: [
                                    const Icon(Icons.document_scanner_outlined, size: 48, color: Colors.grey),
                                    const SizedBox(height: 10),
                                    Text(
                                      _tr(
                                        '아래 [카메라 촬영] 버튼을 눌러 종이나 책을 찍으면\n글자만 깔끔하게 인식해 빈 종이에 여백 없이 담아줍니다.',
                                        'Tap [Camera] below to photograph a page.\nOnly the text will be extracted onto a blank sheet without margins.',
                                        '点击下方【拍照扫描】拍摄书页或纸张，\n将仅提取文字并无边距排入空白纸张。',
                                        '下の[カメラ撮影]で本や紙を撮影すると、\n文字だけを認識して白紙に余白なしで配置します。',
                                      ),
                                      textAlign: TextAlign.center,
                                      style: const TextStyle(fontSize: 12.5, color: Colors.grey),
                                    ),
                                  ],
                                ),
                              )
                            : GridView.builder(
                                gridDelegate: const SliverGridDelegateWithFixedCrossAxisCount(
                                  crossAxisCount: 2,
                                  crossAxisSpacing: 10,
                                  mainAxisSpacing: 10,
                                  childAspectRatio: 0.72,
                                ),
                                itemCount: scannedPages.length,
                                itemBuilder: (_, idx) {
                                  final pageFile = scannedPages[idx];
                                  final pageNum = idx + 1;
                                  return Card(
                                    color: Colors.white,
                                    clipBehavior: Clip.antiAlias,
                                    margin: EdgeInsets.zero,
                                    shape: RoundedRectangleBorder(
                                      borderRadius: BorderRadius.circular(10),
                                      side: const BorderSide(color: Colors.indigo, width: 1.2),
                                    ),
                                    child: Stack(
                                      fit: StackFit.expand,
                                      children: [
                                        Container(
                                          color: Colors.white,
                                          child: Image.file(
                                            pageFile,
                                            fit: BoxFit.contain,
                                            gaplessPlayback: true,
                                            filterQuality: FilterQuality.high,
                                          ),
                                        ),
                                        // 좌측 상단 순서 번호 배지 (#1, #2, #3...)
                                        Positioned(
                                          top: 6,
                                          left: 6,
                                          child: Container(
                                            padding: const EdgeInsets.symmetric(horizontal: 9, vertical: 3.5),
                                            decoration: BoxDecoration(
                                              color: Colors.indigo.withOpacity(0.92),
                                              borderRadius: BorderRadius.circular(12),
                                            ),
                                            child: Text(
                                              '#$pageNum',
                                              style: const TextStyle(
                                                color: Colors.white,
                                                fontWeight: FontWeight.bold,
                                                fontSize: 12,
                                              ),
                                            ),
                                          ),
                                        ),
                                        // 우측 상단 90도 회전(↻) 및 삭제(✕) 버튼
                                        Positioned(
                                          top: 4,
                                          right: 4,
                                          child: Row(
                                            mainAxisSize: MainAxisSize.min,
                                            children: [
                                              Material(
                                                color: Colors.black54,
                                                shape: const CircleBorder(),
                                                child: InkWell(
                                                  customBorder: const CircleBorder(),
                                                  onTap: isBuildingPdf
                                                      ? null
                                                      : () async {
                                                          final String? rotPath = await _pdfChannel.invokeMethod<String>(
                                                            'rotateScannedPageImage',
                                                            {'imagePath': pageFile.path},
                                                          );
                                                          if (rotPath != null && File(rotPath).existsSync()) {
                                                            setModalState(() {
                                                              scannedPages[idx] = File(rotPath);
                                                            });
                                                          }
                                                        },
                                                  child: const Padding(
                                                    padding: EdgeInsets.all(5.0),
                                                    child: Icon(Icons.rotate_right, size: 16, color: Colors.white),
                                                  ),
                                                ),
                                              ),
                                              const SizedBox(width: 4),
                                              Material(
                                                color: Colors.black54,
                                                shape: const CircleBorder(),
                                                child: InkWell(
                                                  customBorder: const CircleBorder(),
                                                  onTap: isBuildingPdf
                                                      ? null
                                                      : () {
                                                          setModalState(() {
                                                            if (idx < rawCapturedPages.length) {
                                                              rawCapturedPages.removeAt(idx);
                                                            }
                                                            scannedPages.removeAt(idx);
                                                          });
                                                        },
                                                  child: const Padding(
                                                    padding: EdgeInsets.all(5.0),
                                                    child: Icon(Icons.close, size: 16, color: Colors.white),
                                                  ),
                                                ),
                                              ),
                                            ],
                                          ),
                                        ),
                                        // 하단 순서 변경 버튼 (◀ / ▶)
                                        Positioned(
                                          left: 0,
                                          right: 0,
                                          bottom: 0,
                                          child: Container(
                                            color: Colors.black54,
                                            padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 2),
                                            child: Row(
                                              mainAxisAlignment: MainAxisAlignment.spaceBetween,
                                              children: [
                                                IconButton(
                                                  visualDensity: VisualDensity.compact,
                                                  padding: EdgeInsets.zero,
                                                  constraints: const BoxConstraints(minWidth: 28, minHeight: 24),
                                                  icon: const Icon(Icons.arrow_back_ios_new, size: 14, color: Colors.white),
                                                  onPressed: (idx > 0 && !isBuildingPdf)
                                                      ? () {
                                                          setModalState(() {
                                                            if (idx < rawCapturedPages.length) {
                                                              final rItem = rawCapturedPages.removeAt(idx);
                                                              rawCapturedPages.insert(idx - 1, rItem);
                                                            }
                                                            final item = scannedPages.removeAt(idx);
                                                            scannedPages.insert(idx - 1, item);
                                                          });
                                                        }
                                                      : null,
                                                ),
                                                Text(
                                                  '$pageNum / ${scannedPages.length}',
                                                  style: const TextStyle(
                                                    color: Colors.white,
                                                    fontSize: 11,
                                                    fontWeight: FontWeight.w600,
                                                  ),
                                                ),
                                                IconButton(
                                                  visualDensity: VisualDensity.compact,
                                                  padding: EdgeInsets.zero,
                                                  constraints: const BoxConstraints(minWidth: 28, minHeight: 24),
                                                  icon: const Icon(Icons.arrow_forward_ios, size: 14, color: Colors.white),
                                                  onPressed: (idx < scannedPages.length - 1 && !isBuildingPdf)
                                                      ? () {
                                                          setModalState(() {
                                                            if (idx < rawCapturedPages.length - 1) {
                                                              final rItem = rawCapturedPages.removeAt(idx);
                                                              rawCapturedPages.insert(idx + 1, rItem);
                                                            }
                                                            final item = scannedPages.removeAt(idx);
                                                            scannedPages.insert(idx + 1, item);
                                                          });
                                                        }
                                                      : null,
                                                ),
                                              ],
                                            ),
                                          ),
                                        ),
                                      ],
                                    ),
                                  );
                                },
                              ),
                  ),
                  const SizedBox(height: 8),
                  Row(
                    children: [
                      Expanded(
                        child: OutlinedButton.icon(
                          icon: const Icon(Icons.camera_alt_outlined, size: 18),
                          label: Text(
                            scannedPages.isEmpty
                                ? _tr('카메라 촬영 (#1)', 'Camera (#1)', '拍照 (#1)', 'カメラ (#1)')
                                : _tr('추가 촬영 (#${scannedPages.length + 1})', 'Add Shot (#${scannedPages.length + 1})', '继续拍 (#${scannedPages.length + 1})', '追加撮影 (#${scannedPages.length + 1})'),
                            style: const TextStyle(fontSize: 12.5),
                          ),
                          onPressed: (isCapturing || isBuildingPdf)
                              ? null
                              : () => triggerCameraCapture(setModalState),
                        ),
                      ),
                      const SizedBox(width: 8),
                      OutlinedButton.icon(
                        icon: const Icon(Icons.photo_library_outlined, size: 18),
                        label: Text(
                          _tr('사진 선택', 'Gallery', '相册', '写真選択'),
                          style: const TextStyle(fontSize: 12.5),
                        ),
                        onPressed: (isCapturing || isBuildingPdf)
                            ? null
                            : () => importImagesFromGalleryForScan(setModalState),
                      ),
                    ],
                  ),
                ],
              ),
            ),
            actions: [
              TextButton(
                onPressed: (isCapturing || isBuildingPdf)
                    ? null
                    : () => Navigator.pop(ctx),
                child: Text(_tr('취소', 'Cancel', '取消', 'キャンセル')),
              ),
              ElevatedButton.icon(
                icon: isBuildingPdf
                    ? const SizedBox(
                        width: 16,
                        height: 16,
                        child: CircularProgressIndicator(strokeWidth: 2, color: Colors.white),
                      )
                    : const Icon(Icons.picture_as_pdf, size: 18),
                label: Text(
                  _tr(
                    'PDF 파일로 형성 (${scannedPages.length}장)',
                    'Build PDF (${scannedPages.length})',
                    '生成 PDF 文件 (${scannedPages.length}页)',
                    'PDFファイルを作成 (${scannedPages.length}枚)',
                  ),
                ),
                onPressed: (scannedPages.isEmpty || isCapturing || isBuildingPdf)
                    ? null
                    : () async {
                        setModalState(() => isBuildingPdf = true);
                        try {
                          final rawName = titleController.text.trim().isEmpty
                              ? defaultTitle
                              : titleController.text.trim();
                          final cleanName = rawName
                              .replaceAll(RegExp(r'\.pdf$', caseSensitive: false), '')
                              .replaceAll(RegExp(r'[\\/:*?"<>|]'), '_');
                          final appDir = await getApplicationDocumentsDirectory();
                          final outPath = '${appDir.path}/$cleanName.pdf';

                          final String? createdPath = await _pdfChannel.invokeMethod<String>(
                            'createScannedPdfFromImages',
                            {
                              'imagePaths': scannedPages.map((f) => f.path).toList(),
                              'outputPath': outPath,
                            },
                          );

                          if (createdPath != null && File(createdPath).existsSync()) {
                            final targetGroup = _selectedGroup == '전체' ? 'PDF/문서' : _selectedGroup;
                            await StorageService.setBookGroup(createdPath, targetGroup);
                            for (final tempImg in [...scannedPages, ...rawCapturedPages]) {
                              try {
                                if (tempImg.path.contains('camera_scans') && await tempImg.exists()) {
                                  await tempImg.delete();
                                }
                              } catch (_) {}
                            }
                            if (ctx.mounted) Navigator.pop(ctx);
                            await _loadLibrary();
                            if (mounted) {
                              ScaffoldMessenger.of(context).showSnackBar(
                                SnackBar(
                                  content: Text(
                                    _tr(
                                      '여백 없는 깔끔한 스캔 PDF 파일이 생성되었습니다: $cleanName.pdf',
                                      'Clean zero-margin scanned PDF created: $cleanName.pdf',
                                      '已生成无边距清晰扫描 PDF 文件：$cleanName.pdf',
                                      '余白なしの鮮明なスキャンPDFが作成されました: $cleanName.pdf',
                                    ),
                                  ),
                                ),
                              );
                            }
                          }
                        } catch (e) {
                          setModalState(() => isBuildingPdf = false);
                          if (mounted) {
                            ScaffoldMessenger.of(context).showSnackBar(
                              SnackBar(content: Text('PDF 생성 오류: $e')),
                            );
                          }
                        }
                      },
              ),
            ],
          );
        },
      ),
    );
  }

  Future<void> _pickAndImportFiles() async {
    final result = await FilePicker.platform.pickFiles(
      type: FileType.any,
      allowMultiple: true,
    );

    if (result == null || result.files.isEmpty) return;

    final validPicked = result.files.where((pf) {
      if (pf.path == null) return false;
      final ext = pf.name.split('.').last.toLowerCase();
      return _supportedExts.contains(ext);
    }).toList();

    if (validPicked.isEmpty) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text(
              _tr(
                '지원되는 파일 형식(EPUB, PDF, JPG, PNG, TXT, CBZ, 워드, 한글)을 선택해 주세요.',
                'Please select supported files (EPUB, PDF, JPG, PNG, TXT, CBZ, Word, HWP).',
                '请选择受支持的文件格式 (EPUB, PDF, JPG, PNG, TXT, CBZ, Word, HWP)。',
                '対応ファイル形式(EPUB, PDF, JPG, PNG, TXT, CBZ, Word, HWP)を選択してください。',
              ),
            ),
          ),
        );
      }
      return;
    }

    final pdfPicked = validPicked.where((pf) {
      final ext = pf.name.split('.').last.toLowerCase();
      return ext == 'pdf';
    }).toList();

    if (pdfPicked.length >= 2 && pdfPicked.length == validPicked.length && mounted) {
      final action = await showDialog<String>(
        context: context,
        builder: (ctx) => AlertDialog(
          title: Text(_tr('PDF ${pdfPicked.length}개 추가 방식 선택', 'Import ${pdfPicked.length} PDFs', '选择导入 ${pdfPicked.length} 个 PDF 的方式', 'PDF ${pdfPicked.length}個の追加方法を選択')),
          content: Text(
            _tr(
              '선택한 PDF 파일들을 하나로 합쳐서 단일 PDF 파일로 추가할까요?',
              'Would you like to merge the selected PDFs into a single PDF file?',
              '是否将所选 PDF 合并为单个 PDF 文件添加？',
              '選択したPDFを1つのPDFファイルに結合して追加しますか？',
            ),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(ctx, 'separate'),
              child: Text(_tr('개별 파일로 추가', 'Add Separately', '单独添加', '個別に追加')),
            ),
            ElevatedButton.icon(
              icon: const Icon(Icons.picture_as_pdf, size: 18),
              onPressed: () => Navigator.pop(ctx, 'merge_pdf'),
              label: Text(_tr('하나의 PDF로 합치기', 'Merge into One PDF', '合并为一个 PDF', '1つのPDFに結合')),
            ),
          ],
        ),
      );

      if (action == 'merge_pdf') {
        final paths = pdfPicked.map((e) => File(e.path!)).toList();
        await _createMergedPdfFromFiles(paths, deleteSourceAfter: false);
        return;
      }
    }

    final imagePicked = validPicked.where((pf) {
      final ext = pf.name.split('.').last.toLowerCase();
      return _imageExts.contains(ext);
    }).toList();

    if (imagePicked.length >= 2 && imagePicked.length == validPicked.length && mounted) {
      final action = await showDialog<String>(
        context: context,
        builder: (ctx) => AlertDialog(
          title: Text(_tr('이미지 ${imagePicked.length}장 추가 방식 선택', 'Import ${imagePicked.length} Images', '选择导入 ${imagePicked.length} 张图片的方式', '画像 ${imagePicked.length}枚の追加方法を選択')),
          content: Text(
            _tr(
              '선택한 이미지들을 하나로 묶어 통합 파일(.cbz)로 추가할까요?',
              'Would you like to bundle the selected images into a single .cbz book?',
              '是否将所选图片打包为单个 .cbz 文件添加？',
              '選択した画像を1つのファイル(.cbz)にまとめて追加しますか？',
            ),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(ctx, 'separate'),
              child: Text(_tr('개별 파일로 추가', 'Add Separately', '单独添加', '個別に追加')),
            ),
            ElevatedButton.icon(
              icon: const Icon(Icons.auto_stories, size: 18),
              onPressed: () => Navigator.pop(ctx, 'merge'),
              label: Text(_tr('JPG 이미지 합치기', 'Merge JPGs', '合并图片', 'JPG結合')),
            ),
          ],
        ),
      );

      if (action == 'merge') {
        final paths = imagePicked.map((e) => File(e.path!)).toList();
        await _createMangaBookFromImages(paths, deleteSourceAfter: false);
        return;
      }
    }

    final appDir = await getApplicationDocumentsDirectory();
    final importedFiles = <File>[];

    for (final pf in validPicked) {
      if (pf.path == null) continue;
      final targetGrp = _selectedGroup == '전체' ? '미분류' : _selectedGroup;
      final saved = await File(pf.path!).copy('${appDir.path}/${pf.name}');
      await StorageService.setBookGroup(saved.path, targetGrp);
      importedFiles.add(saved);
    }

    await _loadLibrary();
    if (mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(
            _tr(
              '${importedFiles.length}개의 파일이 서재에 추가되었습니다.',
              'Added ${importedFiles.length} file(s) to bookshelf.',
              '已添加 ${importedFiles.length} 个文件到书架。',
              '${importedFiles.length}個のファイルが追加されました。',
            ),
          ),
        ),
      );
    }
  }

  Future<void> _createMangaBookFromImages(List<File> sourceImages, {bool deleteSourceAfter = false}) async {
    final now = DateTime.now();
    final dateStr = '${now.year}${now.month.toString().padLeft(2, '0')}${now.day.toString().padLeft(2, '0')}';
    final rand4 = (1000 + math.Random().nextInt(9000)).toString();
    final defaultFileName = '파일_${dateStr}_$rand4';

    final titleController = TextEditingController(text: defaultFileName);
    bool deleteOriginals = deleteSourceAfter;
    bool sortByName = true;

    final confirmed = await showDialog<bool>(
      context: context,
      builder: (ctx) => StatefulBuilder(
        builder: (ctx, setModalState) => AlertDialog(
          title: Text(_tr('JPG 통합 파일 만들기', 'Create Merged Image Book', '创建合并图片文件', 'JPG結合ファイル作成')),
          content: SingleChildScrollView(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                TextField(
                  controller: titleController,
                  decoration: InputDecoration(
                    labelText: _tr('파일 제목', 'File Title', '文件标题', 'ファイル名'),
                    suffixText: '.cbz',
                    border: const OutlineInputBorder(),
                  ),
                ),
                const SizedBox(height: 14),
                Text(
                  _tr('합치는 순서 선택', 'Merge Order', '合并顺序', '結合順序の選択'),
                  style: const TextStyle(fontSize: 13, fontWeight: FontWeight.bold),
                ),
                RadioListTile<bool>(
                  dense: true,
                  contentPadding: EdgeInsets.zero,
                  title: Text(_tr('파일 이름 순서대로 합치기', 'Sort by Filename', '按文件名顺序合并', 'ファイル名順に結合'), style: const TextStyle(fontSize: 13)),
                  value: true,
                  groupValue: sortByName,
                  onChanged: (v) => setModalState(() => sortByName = v ?? true),
                ),
                RadioListTile<bool>(
                  dense: true,
                  contentPadding: EdgeInsets.zero,
                  title: Text(_tr('파일을 고른(선택한) 순서대로 합치기', 'Keep Selected Order', '按选择顺序合并', '選択した順番通りに結合'), style: const TextStyle(fontSize: 13)),
                  value: false,
                  groupValue: sortByName,
                  onChanged: (v) => setModalState(() => sortByName = v ?? false),
                ),
                if (deleteSourceAfter) ...[
                  const Divider(height: 12),
                  CheckboxListTile(
                    contentPadding: EdgeInsets.zero,
                    value: deleteOriginals,
                    title: Text(
                      _tr('통합 후 기존 낱장 이미지 휴지통으로 이동', 'Move original images to Trash after merge', '合并后将原图移至回收站', '結合後に元の画像をゴミ箱へ移動'),
                      style: const TextStyle(fontSize: 13),
                    ),
                    onChanged: (v) => setModalState(() => deleteOriginals = v ?? false),
                  ),
                ],
              ],
            ),
          ),
          actions: [
            TextButton(onPressed: () => Navigator.pop(ctx, false), child: Text(_tr('취소', 'Cancel', '取消', 'キャンセル'))),
            ElevatedButton(
              onPressed: () => Navigator.pop(ctx, true),
              child: Text(_tr('만들기', 'Create', '创建', '作成')),
            ),
          ],
        ),
      ),
    );

    if (confirmed != true || !mounted) return;

    final bookTitle = titleController.text.trim().isEmpty ? defaultFileName : titleController.text.trim();
    final orderedImages = List<File>.from(sourceImages);
    if (sortByName) {
      orderedImages.sort((a, b) => _naturalCompare(
            a.path.split(Platform.pathSeparator).last,
            b.path.split(Platform.pathSeparator).last,
          ));
    }

    int currentStep = 0;
    final int totalSteps = orderedImages.length + 1;
    String progressStatus = _tr('이미지 준비 중...', 'Preparing images...', '正在准备图片...', '画像を準備中...');
    StateSetter? progressSetState;

    showDialog(
      context: context,
      barrierDismissible: false,
      builder: (ctx) => StatefulBuilder(
        builder: (ctx, setDialogState) {
          progressSetState = setDialogState;
          final double ratio = totalSteps > 0 ? (currentStep / totalSteps).clamp(0.0, 1.0).toDouble() : 0.0;
          return AlertDialog(
            title: Text(_tr('JPG 통합 파일 생성 중', 'Creating Merged Book', '正在生成合并文件', 'JPG結合ファイル作成中')),
            content: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                LinearProgressIndicator(value: ratio),
                const SizedBox(height: 12),
                Text(
                  '${(ratio * 100).toStringAsFixed(0)}% ($currentStep / ${orderedImages.length})',
                  style: const TextStyle(fontWeight: FontWeight.bold, fontSize: 13),
                ),
                const SizedBox(height: 6),
                Text(progressStatus, style: const TextStyle(fontSize: 12)),
              ],
            ),
          );
        },
      ),
    );

    await Future.delayed(const Duration(milliseconds: 50));

    final archive = Archive();
    for (int i = 0; i < orderedImages.length; i++) {
      final img = orderedImages[i];
      final fileName = img.path.split(Platform.pathSeparator).last;
      final ext = img.path.split('.').last.toLowerCase();

      progressSetState?.call(() {
        currentStep = i + 1;
        progressStatus = '(${i + 1}/${orderedImages.length}): $fileName';
      });
      await Future.delayed(const Duration(milliseconds: 15));

      final bytes = await img.readAsBytes();
      final entryName = 'page_${i.toString().padLeft(4, '0')}.$ext';
      archive.addFile(ArchiveFile(entryName, bytes.length, bytes));
    }

    final appDir = await getApplicationDocumentsDirectory();
    final safeTitle = bookTitle.replaceAll(RegExp(r'[\\/:*?"<>|]'), '_');
    final outFile = File('${appDir.path}/$safeTitle.cbz');
    final zipBytes = ZipEncoder().encode(archive);
    await outFile.writeAsBytes(zipBytes!);

    final targetGroup = _selectedGroup == '전체' ? '미분류' : _selectedGroup;
    await StorageService.setBookGroup(outFile.path, targetGroup);

    if (deleteOriginals) {
      for (final img in orderedImages) {
        if (await img.exists()) {
          await _moveFileToTrash(img, reloadAfter: false);
        }
      }
    }

    if (mounted) {
      Navigator.pop(context);
    }

    await _loadLibrary();
    if (mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(
            _tr(
              '통합 파일이 서재에 생성되었습니다: $safeTitle.cbz',
              'Merged file created in bookshelf: $safeTitle.cbz',
              '合并文件已添加到书架：$safeTitle.cbz',
              '結合ファイルが書斎に作成されました: $safeTitle.cbz',
            ),
          ),
        ),
      );
    }
  }

  Future<void> _showMergeExistingImagesDialog() async {
    final existingImages = _allBooks.where((f) {
      final ext = f.path.split('.').last.toLowerCase();
      return _imageExts.contains(ext);
    }).toList();

    if (existingImages.isEmpty) {
      final result = await FilePicker.platform.pickFiles(
        type: FileType.image,
        allowMultiple: true,
      );
      if (result != null && result.files.length >= 2) {
        final files = result.files.where((f) => f.path != null).map((f) => File(f.path!)).toList();
        await _createMangaBookFromImages(files, deleteSourceAfter: false);
      } else if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text(_tr('합칠 JPG/PNG 이미지를 2장 이상 선택해 주세요.', 'Select at least 2 images to merge.', '请选择至少 2 张图片进行合并。', '結合する画像を2枚以上選択してください。'))),
        );
      }
      return;
    }

    final List<String> selectedPaths = [];

    final proceed = await showDialog<bool>(
      context: context,
      builder: (ctx) => StatefulBuilder(
        builder: (ctx, setModalState) => AlertDialog(
          title: Text(_tr('JPG 이미지 합치기', 'Merge JPG Images', '合并 JPG 图片', 'JPG画像結合')),
          content: SizedBox(
            width: 420,
            height: 360,
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  mainAxisAlignment: MainAxisAlignment.spaceBetween,
                  children: [
                    Text('${_tr("선택됨", "Selected", "已选", "選択中")}: ${selectedPaths.length}', style: const TextStyle(fontWeight: FontWeight.bold)),
                    Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        TextButton(
                          onPressed: () {
                            setModalState(() {
                              if (selectedPaths.length == existingImages.length) {
                                selectedPaths.clear();
                              } else {
                                selectedPaths
                                  ..clear()
                                  ..addAll(existingImages.map((e) => e.path));
                              }
                            });
                          },
                          child: Text(_tr('전체선택', 'Select All', '全选', 'すべて選択')),
                        ),
                        TextButton.icon(
                          icon: const Icon(Icons.folder_open, size: 16),
                          label: Text(_tr('기기에서 선택', 'Browse Device', '从设备选择', '端末から選択')),
                          onPressed: () async {
                            Navigator.pop(ctx, false);
                            final result = await FilePicker.platform.pickFiles(
                              type: FileType.image,
                              allowMultiple: true,
                            );
                            if (result != null && result.files.length >= 2) {
                              final files = result.files.where((f) => f.path != null).map((f) => File(f.path!)).toList();
                              await _createMangaBookFromImages(files, deleteSourceAfter: false);
                            }
                          },
                        ),
                      ],
                    ),
                  ],
                ),
                const Divider(height: 1),
                Expanded(
                  child: ListView.builder(
                    itemCount: existingImages.length,
                    itemBuilder: (_, idx) {
                      final f = existingImages[idx];
                      final name = _formatDisplayFileName(f.path.split(Platform.pathSeparator).last);
                      final selIndex = selectedPaths.indexOf(f.path);
                      final checked = selIndex != -1;
                      return CheckboxListTile(
                        dense: true,
                        value: checked,
                        secondary: checked
                            ? CircleAvatar(
                                radius: 11,
                                backgroundColor: Colors.indigo,
                                child: Text(
                                  '${selIndex + 1}',
                                  style: const TextStyle(fontSize: 11, color: Colors.white, fontWeight: FontWeight.bold),
                                ),
                              )
                            : null,
                        title: Text(name, maxLines: 1, overflow: TextOverflow.ellipsis),
                        onChanged: (v) {
                          setModalState(() {
                            if (v == true) {
                              if (!selectedPaths.contains(f.path)) {
                                selectedPaths.add(f.path);
                              }
                            } else {
                              selectedPaths.remove(f.path);
                            }
                          });
                        },
                      );
                    },
                  ),
                ),
              ],
            ),
          ),
          actions: [
            TextButton(onPressed: () => Navigator.pop(ctx, false), child: Text(_tr('취소', 'Cancel', '取消', 'キャンセル'))),
            ElevatedButton(
              onPressed: selectedPaths.length >= 2 ? () => Navigator.pop(ctx, true) : null,
              child: Text(_tr('선택한 이미지 합치기', 'Merge Selected', '合并所选图片', '選択した画像を結合')),
            ),
          ],
        ),
      ),
    );

    if (proceed == true && selectedPaths.length >= 2) {
      final fileByPath = {for (final f in existingImages) f.path: f};
      final chosen = selectedPaths.map((p) => fileByPath[p]!).toList();
      await _createMangaBookFromImages(chosen, deleteSourceAfter: true);
    }
  }

  Future<void> _createMergedPdfFromFiles(List<File> sourcePdfs, {bool deleteSourceAfter = false}) async {
    final now = DateTime.now();
    final dateStr = '${now.year}${now.month.toString().padLeft(2, '0')}${now.day.toString().padLeft(2, '0')}';
    final rand4 = (1000 + math.Random().nextInt(9000)).toString();
    final defaultFileName = '통합PDF_${dateStr}_$rand4';

    final titleController = TextEditingController(text: defaultFileName);
    bool deleteOriginals = deleteSourceAfter;
    bool sortByName = false;

    final confirmed = await showDialog<bool>(
      context: context,
      builder: (ctx) => StatefulBuilder(
        builder: (ctx, setModalState) => AlertDialog(
          title: Text(_tr('PDF 하나로 합치기', 'Merge into Single PDF', '合并为一个 PDF', '1つのPDFに結合')),
          content: SingleChildScrollView(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                TextField(
                  controller: titleController,
                  decoration: InputDecoration(
                    labelText: _tr('합쳐진 PDF 파일 이름', 'Merged PDF Filename', '合并后的 PDF 名称', '結合後のPDFファイル名'),
                    suffixText: '.pdf',
                    border: const OutlineInputBorder(),
                  ),
                ),
                const SizedBox(height: 14),
                Text(
                  _tr('합치는 순서 선택', 'Merge Order', '合并顺序', '結合順序の選択'),
                  style: const TextStyle(fontSize: 13, fontWeight: FontWeight.bold),
                ),
                RadioListTile<bool>(
                  dense: true,
                  contentPadding: EdgeInsets.zero,
                  title: Text(_tr('파일을 고른(선택한) 순서대로 합치기', 'Keep Selected Order', '按选择顺序合并', '選択した順番通りに結合'), style: const TextStyle(fontSize: 13)),
                  value: false,
                  groupValue: sortByName,
                  onChanged: (v) => setModalState(() => sortByName = v ?? false),
                ),
                RadioListTile<bool>(
                  dense: true,
                  contentPadding: EdgeInsets.zero,
                  title: Text(_tr('파일 이름 순서대로 합치기', 'Sort by Filename', '按文件名顺序合并', 'ファイル名順に結合'), style: const TextStyle(fontSize: 13)),
                  value: true,
                  groupValue: sortByName,
                  onChanged: (v) => setModalState(() => sortByName = v ?? true),
                ),
                if (deleteSourceAfter) ...[
                  const Divider(height: 12),
                  CheckboxListTile(
                    contentPadding: EdgeInsets.zero,
                    value: deleteOriginals,
                    title: Text(
                      _tr('합친 후 기존 개별 PDF 파일 휴지통으로 이동', 'Move original PDFs to Trash after merge', '合并后将原 PDF 移至回收站', '結合後に元のPDFをゴミ箱へ移動'),
                      style: const TextStyle(fontSize: 13),
                    ),
                    onChanged: (v) => setModalState(() => deleteOriginals = v ?? false),
                  ),
                ],
              ],
            ),
          ),
          actions: [
            TextButton(onPressed: () => Navigator.pop(ctx, false), child: Text(_tr('취소', 'Cancel', '取消', 'キャンセル'))),
            ElevatedButton.icon(
              icon: const Icon(Icons.picture_as_pdf, size: 18),
              onPressed: () => Navigator.pop(ctx, true),
              label: Text(_tr('PDF 합치기', 'Merge PDFs', '合并 PDF', 'PDF結合')),
            ),
          ],
        ),
      ),
    );

    if (confirmed != true || !mounted) return;

    final rawTitle = titleController.text.trim().isEmpty ? defaultFileName : titleController.text.trim();
    final cleanTitle = rawTitle.replaceAll(RegExp(r'\.pdf$', caseSensitive: false), '');
    final safeTitle = cleanTitle.replaceAll(RegExp(r'[\\/:*?"<>|]'), '_');

    final orderedPdfs = List<File>.from(sourcePdfs);
    if (sortByName) {
      orderedPdfs.sort((a, b) => _naturalCompare(
            a.path.split(Platform.pathSeparator).last,
            b.path.split(Platform.pathSeparator).last,
          ));
    }

    showDialog(
      context: context,
      barrierDismissible: false,
      builder: (ctx) => AlertDialog(
        title: Text(_tr('PDF 병합 중', 'Merging PDFs', '正在合并 PDF', 'PDF結合中')),
        content: Row(
          children: [
            const CircularProgressIndicator(),
            const SizedBox(width: 16),
            Expanded(
              child: Text(
                _tr('PDF 페이지들을 하나로 합치는 중입니다...', 'Merging PDF pages into a single document...', '正在将 PDF 页面合并为一个文件...', 'PDFページを1つに結合しています...'),
                style: const TextStyle(fontSize: 13),
              ),
            ),
          ],
        ),
      ),
    );

    try {
      final appDir = await getApplicationDocumentsDirectory();
      final outPath = '${appDir.path}/$safeTitle.pdf';

      await _pdfChannel.invokeMethod('mergePdfs', {
        'inputPaths': orderedPdfs.map((f) => f.path).toList(),
        'outputPath': outPath,
      });

      final outFile = File(outPath);
      final targetGroup = _selectedGroup == '전체' ? '미분류' : _selectedGroup;
      await StorageService.setBookGroup(outFile.path, targetGroup);

      if (deleteOriginals) {
        for (final pdf in orderedPdfs) {
          if (pdf.path != outFile.path && await pdf.exists()) {
            await _moveFileToTrash(pdf, reloadAfter: false);
          }
        }
      }

      if (mounted) Navigator.pop(context);
      await _loadLibrary();

      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text(
              _tr(
                '합쳐진 PDF 파일이 서재에 생성되었습니다: $safeTitle.pdf',
                'Merged PDF created in bookshelf: $safeTitle.pdf',
                '合并后的 PDF 已添加到书架：$safeTitle.pdf',
                '結合されたPDFが書斎に作成されました: $safeTitle.pdf',
              ),
            ),
          ),
        );
      }
    } catch (e) {
      if (mounted) {
        Navigator.pop(context);
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('PDF Merge Error: $e')),
        );
      }
    }
  }

  Future<void> _showMergeExistingPdfsDialog() async {
    final existingPdfs = _allBooks.where((f) {
      final ext = f.path.split('.').last.toLowerCase();
      return ext == 'pdf';
    }).toList();

    if (existingPdfs.length < 2) {
      final result = await FilePicker.platform.pickFiles(
        type: FileType.custom,
        allowedExtensions: ['pdf'],
        allowMultiple: true,
      );
      if (result != null && result.files.length >= 2) {
        final files = result.files.where((f) => f.path != null).map((f) => File(f.path!)).toList();
        await _createMergedPdfFromFiles(files, deleteSourceAfter: false);
      } else if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text(_tr('합칠 PDF 파일을 2개 이상 선택해 주세요.', 'Select at least 2 PDF files to merge.', '请选择至少 2 个 PDF 文件进行合并。', '結合するPDFを2つ以上選択してください。'))),
        );
      }
      return;
    }

    final List<String> selectedPaths = [];

    final proceed = await showDialog<bool>(
      context: context,
      builder: (ctx) => StatefulBuilder(
        builder: (ctx, setModalState) => AlertDialog(
          title: Text(_tr('PDF 합치기', 'Merge PDFs', '合并 PDF', 'PDF結合')),
          content: SizedBox(
            width: 420,
            height: 360,
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  mainAxisAlignment: MainAxisAlignment.spaceBetween,
                  children: [
                    Text('${_tr("선택됨", "Selected", "已选", "選択中")}: ${selectedPaths.length}', style: const TextStyle(fontWeight: FontWeight.bold)),
                    Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        TextButton(
                          onPressed: () {
                            setModalState(() {
                              if (selectedPaths.length == existingPdfs.length) {
                                selectedPaths.clear();
                              } else {
                                selectedPaths
                                  ..clear()
                                  ..addAll(existingPdfs.map((e) => e.path));
                              }
                            });
                          },
                          child: Text(_tr('전체선택', 'Select All', '全选', 'すべて選択')),
                        ),
                        TextButton.icon(
                          icon: const Icon(Icons.folder_open, size: 16),
                          label: Text(_tr('기기에서 선택', 'Browse Device', '从设备选择', '端末から選択')),
                          onPressed: () async {
                            Navigator.pop(ctx, false);
                            final result = await FilePicker.platform.pickFiles(
                              type: FileType.custom,
                              allowedExtensions: ['pdf'],
                              allowMultiple: true,
                            );
                            if (result != null && result.files.length >= 2) {
                              final files = result.files.where((f) => f.path != null).map((f) => File(f.path!)).toList();
                              await _createMergedPdfFromFiles(files, deleteSourceAfter: false);
                            }
                          },
                        ),
                      ],
                    ),
                  ],
                ),
                const Divider(height: 1),
                Expanded(
                  child: ListView.builder(
                    itemCount: existingPdfs.length,
                    itemBuilder: (_, idx) {
                      final f = existingPdfs[idx];
                      final name = _formatDisplayFileName(f.path.split(Platform.pathSeparator).last);
                      final selIndex = selectedPaths.indexOf(f.path);
                      final checked = selIndex != -1;
                      return CheckboxListTile(
                        dense: true,
                        value: checked,
                        secondary: checked
                            ? CircleAvatar(
                                radius: 11,
                                backgroundColor: Colors.indigo,
                                child: Text(
                                  '${selIndex + 1}',
                                  style: const TextStyle(fontSize: 11, color: Colors.white, fontWeight: FontWeight.bold),
                                ),
                              )
                            : null,
                        title: Text(name, maxLines: 1, overflow: TextOverflow.ellipsis),
                        onChanged: (v) {
                          setModalState(() {
                            if (v == true) {
                              if (!selectedPaths.contains(f.path)) {
                                selectedPaths.add(f.path);
                              }
                            } else {
                              selectedPaths.remove(f.path);
                            }
                          });
                        },
                      );
                    },
                  ),
                ),
              ],
            ),
          ),
          actions: [
            TextButton(onPressed: () => Navigator.pop(ctx, false), child: Text(_tr('취소', 'Cancel', '取消', 'キャンセル'))),
            ElevatedButton(
              onPressed: selectedPaths.length >= 2 ? () => Navigator.pop(ctx, true) : null,
              child: Text(_tr('선택한 PDF 합치기', 'Merge Selected PDFs', '合并所选 PDF', '選択したPDFを結合')),
            ),
          ],
        ),
      ),
    );

    if (proceed == true && selectedPaths.length >= 2) {
      final fileByPath = {for (final f in existingPdfs) f.path: f};
      final chosen = selectedPaths.map((p) => fileByPath[p]!).toList();
      await _createMergedPdfFromFiles(chosen, deleteSourceAfter: true);
    }
  }

  Future<void> _renameFileDialog(File file) async {
    final fullName = file.path.split(Platform.pathSeparator).last;
    final dotIdx = fullName.lastIndexOf('.');
    final baseName = dotIdx > 0 ? fullName.substring(0, dotIdx) : fullName;
    final ext = dotIdx > 0 ? fullName.substring(dotIdx + 1) : '';

    final ctrl = TextEditingController(text: baseName);

    final confirmed = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text(_tr('이름 변경', 'Rename File', '重命名文件', 'ファイル名変更')),
        content: TextField(
          controller: ctrl,
          autofocus: true,
          decoration: InputDecoration(
            labelText: _tr('새 파일 이름', 'New Filename', '新文件名', '新しいファイル名'),
            suffixText: ext.isNotEmpty ? '.$ext' : null,
            border: const OutlineInputBorder(),
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: Text(_tr('취소', 'Cancel', '取消', 'キャンセル')),
          ),
          ElevatedButton(
            onPressed: () => Navigator.pop(ctx, true),
            child: Text(_tr('변경', 'Rename', '确定', '変更')),
          ),
        ],
      ),
    );

    if (confirmed != true || !mounted) return;

    final rawNewBase = ctrl.text.trim();
    if (rawNewBase.isEmpty) return;

    final safeNewBase = rawNewBase.replaceAll(RegExp(r'[\\/:*?"<>|]'), '_');
    final newFileName = ext.isNotEmpty ? '$safeNewBase.$ext' : safeNewBase;
    if (newFileName == fullName) return;

    final newPath = '${file.parent.path}/$newFileName';
    if (await File(newPath).exists()) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text(_tr('같은 이름의 파일이 이미 존재합니다.', 'A file with that name already exists.', '同名文件已存在。', '同じ名前のファイルが既に存在します。'))),
        );
      }
      return;
    }

    try {
      final oldPath = file.path;
      await file.rename(newPath);
      await StorageService.migrateBookMetadata(oldPath, newPath);
      await _loadLibrary();
    } catch (_) {}
  }

  Future<void> _openFile(File file) async {
    final rawName = file.path.split(Platform.pathSeparator).last;
    final displayName = _formatDisplayFileName(rawName);
    final ext = rawName.split('.').last.toLowerCase();

    if (ext == 'epub') {
      await Navigator.push(
        context,
        MaterialPageRoute(
          builder: (_) => ReaderScreen(filePath: file.path, bookTitle: displayName),
        ),
      );
    } else if (_docConvertExts.contains(ext)) {
      final epubFile = await TxtToEpubConverter.convertDocumentToEpub(file);
      if (!mounted) return;
      await Navigator.push(
        context,
        MaterialPageRoute(
          builder: (_) => ReaderScreen(filePath: epubFile.path, bookTitle: displayName),
        ),
      );
    } else if (ext == 'pdf') {
      await Navigator.push(
        context,
        MaterialPageRoute(
          builder: (_) => UniversalMediaReaderScreen(
            files: [file],
            title: displayName,
            isPdf: true,
          ),
        ),
      );
    } else if (_imageExts.contains(ext)) {
      final currentGroup = _bookGroupMap[file.path];
      final siblingImages = _allBooks.where((f) {
        final fExt = f.path.split('.').last.toLowerCase();
        return _imageExts.contains(fExt) && _bookGroupMap[f.path] == currentGroup;
      }).toList();

      final targetList = siblingImages.length > 1 ? siblingImages : [file];
      final String bookKey = targetList.first.path;
      final savedPos = await StorageService.getLastPosition(bookKey);
      final clickedIdx = targetList.indexWhere((f) => f.path == file.path);

      if (clickedIdx > 0 || savedPos == null) {
        await StorageService.saveLastPosition(bookKey, clickedIdx.clamp(0, targetList.length - 1).toString());
      }

      if (!mounted) return;
      await Navigator.push(
        context,
        MaterialPageRoute(
          builder: (_) => UniversalMediaReaderScreen(
            files: targetList,
            title: targetList.length > 1 ? '$displayName (+${targetList.length - 1})' : displayName,
            isPdf: false,
            customBookKey: bookKey,
          ),
        ),
      );
    } else {
      await Navigator.push(
        context,
        MaterialPageRoute(
          builder: (_) => UniversalMediaReaderScreen(
            files: [file],
            title: displayName,
            isPdf: false,
          ),
        ),
      );
    }

    // 뷰어 종료 후 서재로 돌아올 때 화면 회전 상태 초기화
    if (StorageService.desiredLandscapeNotifier.value != null) {
      StorageService.desiredLandscapeNotifier.value = null;
    }
    try {
      await _pdfChannel.invokeMethod('setScreenOrientation', {'mode': 'unspecified'});
    } catch (_) {}
    SystemChrome.setPreferredOrientations([]);

    _loadLibrary();
  }

  Future<void> _createNewGroupDialog() async {
    final controller = TextEditingController();
    await showDialog(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text(_tr('새 그룹 만들기', 'Create New Group', '新建分组', '新規グループ作成')),
        content: TextField(
          controller: controller,
          autofocus: true,
          decoration: InputDecoration(
            hintText: _tr('그룹 이름 입력', 'Enter group name', '输入分组名称', 'グループ名を入力'),
            border: const OutlineInputBorder(),
          ),
        ),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx), child: Text(_tr('취소', 'Cancel', '取消', 'キャンセル'))),
          ElevatedButton(
            onPressed: () async {
              final text = controller.text.trim();
              if (text.isNotEmpty) {
                await StorageService.addGroup(text);
                if (ctx.mounted) Navigator.pop(ctx);
                _loadLibrary();
              }
            },
            child: Text(_tr('추가', 'Add', '添加', '追加')),
          ),
        ],
      ),
    );
  }

  Future<void> _confirmDeleteGroup(String groupName) async {
    if (groupName == '전체') {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text(_tr('"전체" 기본 보기는 삭제할 수 없습니다.', '"All" group cannot be deleted.', '无法删除“全部”默认分组。', '「すべて」は削除できません。'))),
      );
      return;
    }

    final confirmed = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text(_tr('"$groupName" 그룹 삭제', 'Delete "$groupName"', '删除 "$groupName"', '「$groupName」グループ削除')),
        content: Text(
          _tr(
            '"$groupName" 그룹을 삭제할까요?\n(그룹 안의 파일들은 삭제되지 않고 [미분류]로 유지됩니다)',
            'Delete group "$groupName"?\n(Files inside will remain as [Uncategorized])',
            '确定删除 "$groupName" 分组吗？\n（组内文件不会删除，将归为[未分类]）',
            '「$groupName」を削除しますか？\n(中のファイルは削除されず[未分類]になります)',
          ),
        ),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx, false), child: Text(_tr('취소', 'Cancel', '取消', 'キャンセル'))),
          ElevatedButton(
            style: ElevatedButton.styleFrom(backgroundColor: Colors.redAccent, foregroundColor: Colors.white),
            onPressed: () => Navigator.pop(ctx, true),
            child: Text(_tr('그룹 삭제', 'Delete', '删除分组', '削除')),
          ),
        ],
      ),
    );

    if (confirmed == true) {
      await StorageService.removeGroup(groupName);
      if (_selectedGroup == groupName) {
        _selectedGroup = '전체';
      }
      await _loadLibrary();
    }
  }

  Future<void> _moveFileToTrash(File file, {bool reloadAfter = true}) async {
    final fileName = file.path.split(Platform.pathSeparator).last;
    final trashDir = await _getTrashDirectory();
    final targetPath = '${trashDir.path}/$fileName';
    if (await file.exists()) {
      await file.copy(targetPath);
      await file.delete();
    }
    if (reloadAfter) {
      await _loadLibrary();
    }
  }

  Future<void> _moveSelectedFilesBatch() async {
    if (_selectedFilePaths.isEmpty) return;
    final candidateGroups = [
      ..._groups.where((g) => g != '전체'),
      if (!_groups.contains('미분류')) '미분류',
    ];

    final chosenGroup = await showModalBottomSheet<String>(
      context: context,
      builder: (ctx) => SafeArea(
        child: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              ListTile(
                title: Text(
                  _tr(
                    '선택한 ${_selectedFilePaths.length}개 파일 그룹 이동',
                    'Move ${_selectedFilePaths.length} Selected File(s)',
                    '移动所选 ${_selectedFilePaths.length} 个文件',
                    '選択した${_selectedFilePaths.length}個のファイルを移動',
                  ),
                  style: const TextStyle(fontWeight: FontWeight.bold),
                ),
              ),
              const Divider(height: 1),
              ...candidateGroups.map((g) => ListTile(
                    leading: const Icon(Icons.folder_outlined),
                    title: Text(_localizeGroupName(g)),
                    onTap: () => Navigator.pop(ctx, g),
                  )),
            ],
          ),
        ),
      ),
    );

    if (chosenGroup == null) return;

    for (final path in _selectedFilePaths) {
      await StorageService.setBookGroup(path, chosenGroup);
    }

    setState(() {
      _selectedFilePaths.clear();
      _isSelectionMode = false;
    });

    await _loadLibrary();
  }

  Future<void> _deleteSelectedFilesBatch() async {
    if (_selectedFilePaths.isEmpty) return;
    final count = _selectedFilePaths.length;

    final confirmed = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text(_tr('선택한 파일 삭제', 'Delete Selected Files', '删除所选文件', '選択したファイルを削除')),
        content: Text(
          _tr(
            '선택한 $count개의 파일을 휴지통으로 이동할까요?',
            'Move $count selected file(s) to Trash?',
            '是否将所选 $count 个文件移至回收站？',
            '選択した$count個のファイルをゴミ箱へ移動しますか？',
          ),
        ),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx, false), child: Text(_tr('취소', 'Cancel', '取消', 'キャンセル'))),
          ElevatedButton(
            style: ElevatedButton.styleFrom(backgroundColor: Colors.redAccent, foregroundColor: Colors.white),
            onPressed: () => Navigator.pop(ctx, true),
            child: Text(_tr('삭제', 'Delete', '删除', '削除')),
          ),
        ],
      ),
    );

    if (confirmed != true) return;

    final targets = _allBooks.where((f) => _selectedFilePaths.contains(f.path)).toList();
    for (final f in targets) {
      await _moveFileToTrash(f, reloadAfter: false);
    }

    setState(() {
      _selectedFilePaths.clear();
      _isSelectionMode = false;
    });

    await _loadLibrary();
  }

  Future<void> _showTrashBinDialog() async {
    await _loadLibrary();
    if (!mounted) return;

    await showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      builder: (ctx) => StatefulBuilder(
        builder: (ctx, setModalState) => SafeArea(
          child: SizedBox(
            height: MediaQuery.of(context).size.height * 0.65,
            child: Column(
              children: [
                ListTile(
                  leading: const Icon(Icons.delete_outline),
                  title: Text(
                    '${_tr("휴지통", "Trash", "回收站", "ゴミ箱")} (${_trashedBooks.length})',
                    style: const TextStyle(fontWeight: FontWeight.bold),
                  ),
                  trailing: _trashedBooks.isNotEmpty
                      ? TextButton.icon(
                          icon: const Icon(Icons.delete_forever, color: Colors.redAccent, size: 18),
                          label: Text(_tr('휴지통 비우기', 'Empty Trash', '清空回收站', 'ゴミ箱を空にする'), style: const TextStyle(color: Colors.redAccent)),
                          onPressed: () async {
                            final confirmEmpty = await showDialog<bool>(
                              context: ctx,
                              builder: (dCtx) => AlertDialog(
                                title: Text(_tr('휴지통 비우기', 'Empty Trash', '清空回收站', 'ゴミ箱を空にする')),
                                content: Text(_tr('휴지통의 모든 파일을 영구 삭제할까요?', 'Permanently delete all files in Trash?', '确定永久删除回收站中的所有文件吗？', 'ゴミ箱内のすべてのファイルを完全に削除しますか？')),
                                actions: [
                                  TextButton(onPressed: () => Navigator.pop(dCtx, false), child: Text(_tr('취소', 'Cancel', '取消', 'キャンセル'))),
                                  ElevatedButton(
                                    style: ElevatedButton.styleFrom(
                                      backgroundColor: Colors.redAccent,
                                      foregroundColor: Colors.white,
                                    ),
                                    onPressed: () => Navigator.pop(dCtx, true),
                                    child: Text(_tr('영구 삭제', 'Delete Forever', '永久删除', '完全削除')),
                                  ),
                                ],
                              ),
                            );
                            if (confirmEmpty == true) {
                              final appDir = await getApplicationDocumentsDirectory();
                              for (final tf in _trashedBooks) {
                                final fileName = tf.path.split(Platform.pathSeparator).last;
                                await StorageService.removeBookMetadata('${appDir.path}/$fileName');
                                if (await tf.exists()) await tf.delete();
                              }
                              await _loadLibrary();
                              setModalState(() {});
                            }
                          },
                        )
                      : null,
                ),
                const Divider(height: 1),
                Expanded(
                  child: _trashedBooks.isEmpty
                      ? Center(child: Text(_tr('휴지통이 비어 있습니다.', 'Trash is empty.', '回收站为空。', 'ゴミ箱は空です。')))
                      : ListView.separated(
                          itemCount: _trashedBooks.length,
                          separatorBuilder: (_, __) => const Divider(height: 1),
                          itemBuilder: (_, idx) {
                            final tf = _trashedBooks[idx];
                            final fileName = tf.path.split(Platform.pathSeparator).last;
                            return ListTile(
                              leading: const Icon(Icons.insert_drive_file_outlined),
                              title: Text(_formatDisplayFileName(fileName), maxLines: 1, overflow: TextOverflow.ellipsis),
                              trailing: Row(
                                mainAxisSize: MainAxisSize.min,
                                children: [
                                  TextButton.icon(
                                    icon: const Icon(Icons.restore_from_trash, size: 18),
                                    label: Text(_tr('복원', 'Restore', '恢复', '復元')),
                                    onPressed: () async {
                                      final appDir = await getApplicationDocumentsDirectory();
                                      final restoredPath = '${appDir.path}/$fileName';
                                      if (await tf.exists()) {
                                        await tf.copy(restoredPath);
                                        await tf.delete();
                                      }
                                      await _loadLibrary();
                                      setModalState(() {});
                                    },
                                  ),
                                  IconButton(
                                    icon: const Icon(Icons.delete_forever, color: Colors.redAccent),
                                    tooltip: _tr('영구 삭제', 'Delete Forever', '永久删除', '完全削除'),
                                    onPressed: () async {
                                      final confirmDelete = await showDialog<bool>(
                                        context: ctx,
                                        builder: (dCtx) => AlertDialog(
                                          title: Text(_tr('영구 삭제', 'Delete Forever', '永久删除', '完全削除')),
                                          content: Text(_tr('"$fileName" 파일을 영구 삭제할까요?', 'Permanently delete "$fileName"?', '确定永久删除 "$fileName" 吗？', '「$fileName」を完全に削除しますか？')),
                                          actions: [
                                            TextButton(
                                              onPressed: () => Navigator.pop(dCtx, false),
                                              child: Text(_tr('취소', 'Cancel', '取消', 'キャンセル')),
                                            ),
                                            ElevatedButton(
                                              style: ElevatedButton.styleFrom(
                                                backgroundColor: Colors.redAccent,
                                                foregroundColor: Colors.white,
                                              ),
                                              onPressed: () => Navigator.pop(dCtx, true),
                                              child: Text(_tr('영구 삭제', 'Delete Forever', '永久删除', '完全削除')),
                                            ),
                                          ],
                                        ),
                                      );
                                      if (confirmDelete == true) {
                                        final appDir = await getApplicationDocumentsDirectory();
                                        await StorageService.removeBookMetadata('${appDir.path}/$fileName');
                                        if (await tf.exists()) {
                                          await tf.delete();
                                        }
                                        await _loadLibrary();
                                        setModalState(() {});
                                      }
                                    },
                                  ),
                                ],
                              ),
                            );
                          },
                        ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  Future<void> _assignGroupDialog(File file) async {
    final candidateGroups = [
      ..._groups.where((g) => g != '전체'),
      if (!_groups.contains('미분류')) '미분류',
    ];
    await showModalBottomSheet(
      context: context,
      builder: (ctx) => SafeArea(
        child: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              ListTile(
                title: Text(_tr('파일 그룹 이동', 'Move to Group', '移动分组', 'グループ移動'), style: const TextStyle(fontWeight: FontWeight.bold)),
              ),
              const Divider(height: 1),
              ...candidateGroups.map((g) => ListTile(
                    leading: const Icon(Icons.folder_outlined),
                    title: Text(_localizeGroupName(g)),
                    onTap: () async {
                      await StorageService.setBookGroup(file.path, g);
                      if (ctx.mounted) Navigator.pop(ctx);
                      _loadLibrary();
                    },
                  )),
            ],
          ),
        ),
      ),
    );
  }

  /// 1, 2, 6, 11, 15. 우측 상단 톱니바퀴 '앱 설정' 다이얼로그:
  /// - 문구: '프로그램 설정' -> '앱 설정'으로 변경 (#11)
  /// - 화면 잠금 방식 설정 제거 (뷰어 표시 설정에서만 제공) (#2)
  /// - '각 아이콘 위치 및 기능 설명 가이드 열람' -> '사용 설명서'로 변경 (#6)
  /// - 선택된 언어에 따라 다이얼로그 및 앱 전체 문구 실시간 번역 (#1)
  Future<void> _showGlobalSettingsDialog() async {
    String currentLang = widget.appLang;
    bool hideExt = _hideFileExtension;
    String viewMode = _bookshelfViewMode;

    if (!mounted) return;
    await showDialog(
      context: context,
      builder: (ctx) => StatefulBuilder(
        builder: (ctx, setModalState) {
          String tDialog(String ko, String en, String zh, String ja) =>
              AppI18n.t(currentLang, ko: ko, en: en, zh: zh, ja: ja);

          return AlertDialog(
            title: Row(
              children: [
                const Icon(Icons.settings, size: 22),
                const SizedBox(width: 8),
                Text(tDialog('앱 설정', 'App Settings', '应用设置', 'アプリ設定')),
              ],
            ),
            content: SingleChildScrollView(
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    tDialog(
                      '1. 언어 설정',
                      '1. Language',
                      '1. 语言设置',
                      '1. 言語設定',
                    ),
                    style: const TextStyle(fontSize: 13, fontWeight: FontWeight.bold),
                  ),
                  const SizedBox(height: 8),
                  Wrap(
                    spacing: 8,
                    runSpacing: 6,
                    children: [
                      {'code': 'ko', 'label': '한국어'},
                      {'code': 'en', 'label': 'English'},
                      {'code': 'zh', 'label': '中文'},
                      {'code': 'ja', 'label': '日本語'},
                    ].map((item) {
                      final code = item['code']!;
                      return ChoiceChip(
                        label: Text(item['label']!),
                        selected: currentLang == code,
                        onSelected: (_) {
                          setModalState(() => currentLang = code);
                          widget.onChangeLanguage(code);
                        },
                      );
                    }).toList(),
                  ),
                  const Divider(height: 24),
                  Text(
                    tDialog('2. 파일 보여주는 형식', '2. Bookshelf View Mode', '2. 文件显示样式', '2. ファイル表示形式'),
                    style: const TextStyle(fontSize: 13, fontWeight: FontWeight.bold),
                  ),
                  const SizedBox(height: 8),
                  Wrap(
                    spacing: 8,
                    runSpacing: 6,
                    children: [
                      ChoiceChip(
                        avatar: Icon(
                          Icons.grid_view_rounded,
                          size: 16,
                          color: viewMode == 'grid' ? Colors.amber : null,
                        ),
                        label: Text(tDialog('표지형 (썸네일)', 'Cover View (Thumbnail)', '封面视图 (缩略图)', '表紙表示 (サムネイル)')),
                        selected: viewMode == 'grid',
                        onSelected: (_) async {
                          await StorageService.setBookshelfViewMode('grid');
                          setModalState(() => viewMode = 'grid');
                          setState(() => _bookshelfViewMode = 'grid');
                        },
                      ),
                      ChoiceChip(
                        avatar: Icon(
                          Icons.view_list_rounded,
                          size: 16,
                          color: viewMode == 'list' ? Colors.amber : null,
                        ),
                        label: Text(tDialog('목록형 (리스트)', 'List View', '列表视图', 'リスト表示')),
                        selected: viewMode == 'list',
                        onSelected: (_) async {
                          await StorageService.setBookshelfViewMode('list');
                          setModalState(() => viewMode = 'list');
                          setState(() => _bookshelfViewMode = 'list');
                        },
                      ),
                    ],
                  ),
                  const SizedBox(height: 8),
                  SwitchListTile(
                    contentPadding: EdgeInsets.zero,
                    dense: true,
                    title: Text(
                      tDialog(
                        '파일 이름 뒤에 형식(.pdf, .epub 등) 숨기기',
                        'Hide file extension (.pdf, .epub)',
                        '隐藏文件扩展名 (.pdf, .epub)',
                        'ファイル名の後ろの形式(.pdf等)を隠す',
                      ),
                      style: const TextStyle(fontSize: 13),
                    ),
                    value: hideExt,
                    onChanged: (val) async {
                      await StorageService.setHideFileExtension(val);
                      setModalState(() => hideExt = val);
                      setState(() => _hideFileExtension = val);
                    },
                  ),
                  const Divider(height: 24),
                  SizedBox(
                    width: double.infinity,
                    child: OutlinedButton.icon(
                      icon: const Icon(Icons.menu_book_outlined, size: 18),
                      label: Text(tDialog('사용 설명서', 'User Manual', '使用说明书', '取扱説明書')),
                      onPressed: () {
                        Navigator.pop(ctx);
                        Navigator.push(
                          context,
                          MaterialPageRoute(
                            builder: (_) => UserManualScreen(appLang: currentLang),
                          ),
                        );
                      },
                    ),
                  ),
                ],
              ),
            ),
            actions: [
              ElevatedButton(
                onPressed: () => Navigator.pop(ctx),
                child: Text(tDialog('닫기', 'Close', '关闭', '閉じる')),
              ),
            ],
          );
        },
      ),
    );
  }

  /// 1, 3, 10, 11, 13. 표지형(썸네일) 그리드 카드:
  /// - 고화질 첫 페이지 썸네일 (FilterQuality.high)
  /// - 휴대폰 한 화면에 9개(3×3) 들어가는 크기
  /// - 우측 상단 즐겨찾기 별 아이콘, 하단 점 3개(이름 변경 / 그룹 이동 / 휴지통 이동)
  /// - 진행바 및 진행률(%) 제거 (#11)
  /// - 그룹 이름은 [전체] 탭에서만 표시하고 개별 그룹 탭에서는 숨김 (#10)
  Widget _buildGridBookCard(File file) {
    final rowKey = _fileRowKeys.putIfAbsent(file.path, () => GlobalKey());
    final rawFileName = file.path.split(Platform.pathSeparator).last;
    final displayFileName = _formatDisplayFileName(rawFileName);
    final grp = _bookGroupMap[file.path] ?? '미분류';
    final grpDisplay = _localizeGroupName(grp);
    final bool showGroupLabel = _selectedGroup == '전체';
    final isSelected = _selectedFilePaths.contains(file.path);
    final isFavorite = _favoritePaths.contains(file.path);
    final lowerExt = rawFileName.split('.').last.toLowerCase();
    final thumbPath = _thumbnailPathCache[file.path];

    final IconData fallbackIcon = lowerExt == 'pdf'
        ? Icons.picture_as_pdf
        : (lowerExt == 'docx' || lowerExt == 'doc' || lowerExt == 'hwpx' || lowerExt == 'hwp')
            ? Icons.description_outlined
            : (lowerExt == 'epub' || lowerExt == 'txt')
                ? Icons.menu_book
                : lowerExt == 'cbz'
                    ? Icons.auto_stories
                    : Icons.image;

    return RepaintBoundary(
      child: Container(
        key: rowKey,
        child: GestureDetector(
          onLongPress: () {
            setState(() {
              final bool targetSelect = !_isSelectionMode ? true : !isSelected;
              _isSelectionMode = true;
              _isDragSelecting = true;
              _dragTargetSelectState = targetSelect;
              _lastDragTouchedPath = file.path;
              if (targetSelect) {
                _selectedFilePaths.add(file.path);
              } else {
                _selectedFilePaths.remove(file.path);
              }
            });
          },
          onTap: () {
            if (_isSelectionMode) {
              setState(() {
                if (isSelected) {
                  _selectedFilePaths.remove(file.path);
                  if (_selectedFilePaths.isEmpty) {
                    _isSelectionMode = false;
                  }
                } else {
                  _selectedFilePaths.add(file.path);
                }
              });
            } else {
              _openFile(file);
            }
          },
          child: Card(
            elevation: isSelected ? 4 : 2,
            margin: EdgeInsets.zero,
            clipBehavior: Clip.antiAlias,
            shape: RoundedRectangleBorder(
              borderRadius: BorderRadius.circular(10),
              side: isSelected
                  ? const BorderSide(color: Colors.amber, width: 2.2)
                  : BorderSide(
                      color: widget.isDarkMode ? Colors.white12 : Colors.black12,
                      width: 1.0,
                    ),
            ),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                // 상단: 고화질 파일 첫 페이지 썸네일 영역 + 우측 상단 즐겨찾기 버튼
                Expanded(
                  child: Stack(
                    fit: StackFit.expand,
                    children: [
                      Container(
                        color: widget.isDarkMode ? const Color(0xFF1E293B) : const Color(0xFFF1F5F9),
                        child: (thumbPath != null && File(thumbPath).existsSync())
                            ? Image.file(
                                File(thumbPath),
                                fit: BoxFit.cover,
                                alignment: Alignment.topCenter,
                                gaplessPlayback: true,
                                filterQuality: FilterQuality.high,
                                errorBuilder: (_, __, ___) => Center(
                                  child: Icon(fallbackIcon, size: 34, color: Colors.indigo),
                                ),
                              )
                            : Center(
                                child: Column(
                                  mainAxisSize: MainAxisSize.min,
                                  children: [
                                    Icon(fallbackIcon, size: 32, color: Colors.indigo),
                                    const SizedBox(height: 4),
                                    Container(
                                      padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
                                      decoration: BoxDecoration(
                                        color: Colors.indigo.withOpacity(0.12),
                                        borderRadius: BorderRadius.circular(5),
                                      ),
                                      child: Text(
                                        lowerExt.toUpperCase(),
                                        style: const TextStyle(
                                          fontSize: 10,
                                          fontWeight: FontWeight.bold,
                                          color: Colors.indigo,
                                        ),
                                      ),
                                    ),
                                  ],
                                ),
                              ),
                      ),
                      if (_isSelectionMode)
                        Positioned(
                          top: 4,
                          left: 4,
                          child: Container(
                            decoration: BoxDecoration(
                              color: Colors.black54,
                              borderRadius: BorderRadius.circular(6),
                            ),
                            child: SizedBox(
                              width: 24,
                              height: 24,
                              child: Checkbox(
                                value: isSelected,
                                visualDensity: VisualDensity.compact,
                                side: const BorderSide(color: Colors.white, width: 1.5),
                                onChanged: (v) {
                                  setState(() {
                                    if (v == true) {
                                      _selectedFilePaths.add(file.path);
                                    } else {
                                      _selectedFilePaths.remove(file.path);
                                      if (_selectedFilePaths.isEmpty) {
                                        _isSelectionMode = false;
                                      }
                                    }
                                  });
                                },
                              ),
                            ),
                          ),
                        ),
                      // 우측 상단 즐겨찾기 버튼
                      Positioned(
                        top: 4,
                        right: 4,
                        child: Material(
                          color: Colors.black45,
                          shape: const CircleBorder(),
                          child: InkWell(
                            customBorder: const CircleBorder(),
                            onTap: () async {
                              await StorageService.toggleFavoriteBook(file.path);
                              await _loadLibrary();
                            },
                            child: Padding(
                              padding: const EdgeInsets.all(4.5),
                              child: Icon(
                                isFavorite ? Icons.star_rounded : Icons.star_border_rounded,
                                color: isFavorite ? Colors.amber : Colors.white,
                                size: 18,
                              ),
                            ),
                          ),
                        ),
                      ),
                    ],
                  ),
                ),
                // 하단: 파일 제목 + 점 3개(이름 변경/그룹 이동) 아이콘 + ([전체] 탭일 때만 그룹 이름 표시)
                Container(
                  padding: const EdgeInsets.fromLTRB(7, 4, 2, 5),
                  color: widget.isDarkMode ? const Color(0xFF0F172A) : Colors.white,
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Row(
                        children: [
                          Expanded(
                            child: Text(
                              displayFileName,
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                              style: const TextStyle(
                                fontSize: 11.5,
                                fontWeight: FontWeight.w600,
                              ),
                            ),
                          ),
                          if (!_isSelectionMode)
                            SizedBox(
                              width: 24,
                              height: 24,
                              child: PopupMenuButton<String>(
                                padding: EdgeInsets.zero,
                                iconSize: 17,
                                constraints: const BoxConstraints(minWidth: 125),
                                icon: const Icon(Icons.more_vert, size: 17),
                                tooltip: _tr('메뉴', 'More', '更多', 'メニュー'),
                                onSelected: (action) {
                                  if (action == 'rename') {
                                    _renameFileDialog(file);
                                  } else if (action == 'move_group') {
                                    _assignGroupDialog(file);
                                  } else if (action == 'trash') {
                                    _moveFileToTrash(file);
                                  }
                                },
                                itemBuilder: (ctx) => [
                                  PopupMenuItem<String>(
                                    value: 'rename',
                                    child: Row(
                                      children: [
                                        const Icon(Icons.edit_outlined, size: 18),
                                        const SizedBox(width: 8),
                                        Text(_tr('이름 변경', 'Rename', '重命名', '名前変更')),
                                      ],
                                    ),
                                  ),
                                  PopupMenuItem<String>(
                                    value: 'move_group',
                                    child: Row(
                                      children: [
                                        const Icon(Icons.drive_file_move_outline, size: 18),
                                        const SizedBox(width: 8),
                                        Text(_tr('그룹 이동', 'Move Group', '移动分组', 'グループ移動')),
                                      ],
                                    ),
                                  ),
                                  PopupMenuItem<String>(
                                    value: 'trash',
                                    child: Row(
                                      children: [
                                        const Icon(Icons.delete_outline, size: 18, color: Colors.redAccent),
                                        const SizedBox(width: 8),
                                        Text(
                                          _tr('휴지통 이동', 'Move to Trash', '移至回收站', 'ゴミ箱へ移動'),
                                          style: const TextStyle(color: Colors.redAccent),
                                        ),
                                      ],
                                    ),
                                  ),
                                ],
                              ),
                            ),
                        ],
                      ),
                      if (showGroupLabel) ...[
                        const SizedBox(height: 1),
                        Text(
                          '[$grpDisplay]',
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: TextStyle(
                            fontSize: 10,
                            color: widget.isDarkMode ? Colors.white60 : Colors.black54,
                          ),
                        ),
                      ],
                    ],
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final filteredBooks = _selectedGroup == '전체'
        ? _allBooks
        : _allBooks.where((f) => (_bookGroupMap[f.path] ?? '미분류') == _selectedGroup).toList();

    return Scaffold(
      appBar: _isSelectionMode
          ? AppBar(
              leading: IconButton(
                icon: const Icon(Icons.close),
                onPressed: () {
                  setState(() {
                    _isSelectionMode = false;
                    _selectedFilePaths.clear();
                  });
                },
              ),
              title: Text(
                _tr(
                  '${_selectedFilePaths.length}개 선택됨',
                  '${_selectedFilePaths.length} Selected',
                  '已选择 ${_selectedFilePaths.length} 项',
                  '${_selectedFilePaths.length}個選択中',
                ),
              ),
              // 5. 파일 여러 개 선택 창 상단에서 전체 선택 옆의 '그룹이동', '쓰레기통' 아이콘 삭제! (하단 버튼만 유지)
              actions: [
                TextButton(
                  onPressed: () {
                    setState(() {
                      if (_selectedFilePaths.length == filteredBooks.length) {
                        _selectedFilePaths.clear();
                      } else {
                        _selectedFilePaths.addAll(filteredBooks.map((f) => f.path));
                      }
                    });
                  },
                  child: Text(_tr('전체 선택', 'Select All', '全选', 'すべて選択')),
                ),
              ],
            )
          : AppBar(
              title: const Text('MY'),
              actions: [
                IconButton(
                  icon: Icon(widget.isDarkMode ? Icons.light_mode : Icons.dark_mode),
                  tooltip: _tr('다크 모드 전환', 'Toggle Dark Mode', '切换深色模式', 'ダークモード切替'),
                  onPressed: widget.onToggleDarkMode,
                ),
                IconButton(
                  icon: const Icon(Icons.picture_as_pdf_outlined),
                  tooltip: _tr('PDF 합치기', 'Merge PDFs', '合并 PDF', 'PDF結合'),
                  onPressed: _showMergeExistingPdfsDialog,
                ),
                IconButton(
                  icon: const Icon(Icons.auto_stories_outlined),
                  tooltip: _tr('JPG 이미지 합치기', 'Merge JPGs', '合并图片', 'JPG結合'),
                  onPressed: _showMergeExistingImagesDialog,
                ),
                IconButton(
                  icon: Badge(
                    isLabelVisible: _trashedBooks.isNotEmpty,
                    label: Text('${_trashedBooks.length}'),
                    child: const Icon(Icons.delete_outline),
                  ),
                  tooltip: _tr('휴지통', 'Trash', '回收站', 'ゴミ箱'),
                  onPressed: _showTrashBinDialog,
                ),
                IconButton(
                  icon: const Icon(Icons.settings_outlined),
                  tooltip: _tr('앱 설정', 'App Settings', '应用设置', 'アプリ設定'),
                  onPressed: _showGlobalSettingsDialog,
                ),
              ],
            ),
      body: SafeArea(
        child: Column(
          children: [
            SizedBox(
              height: 54,
              child: ListView.separated(
                padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
                scrollDirection: Axis.horizontal,
                itemCount: _groups.length + 1,
                separatorBuilder: (_, __) => const SizedBox(width: 8),
                itemBuilder: (context, index) {
                  if (index == _groups.length) {
                    return ActionChip(
                      label: Icon(
                        Icons.add,
                        size: 18,
                        color: Theme.of(context).colorScheme.primary,
                      ),
                      labelPadding: const EdgeInsets.symmetric(horizontal: 2),
                      tooltip: _tr('새 그룹 추가', 'Add Group', '新建分组', 'グループ追加'),
                      onPressed: _createNewGroupDialog,
                    );
                  }
                  final grp = _groups[index];
                  final selected = grp == _selectedGroup;
                  return GestureDetector(
                    onLongPress: () => _confirmDeleteGroup(grp),
                    child: ChoiceChip(
                      label: Text(_localizeGroupName(grp)),
                      selected: selected,
                      onSelected: (_) => setState(() => _selectedGroup = grp),
                    ),
                  );
                },
              ),
            ),
            const Divider(height: 1),
            Expanded(
              child: filteredBooks.isEmpty
                  ? Center(
                      child: Padding(
                        padding: const EdgeInsets.all(24.0),
                        child: Wrap(
                          spacing: 12,
                          runSpacing: 10,
                          alignment: WrapAlignment.center,
                          children: [
                            OutlinedButton.icon(
                              icon: const Icon(Icons.picture_as_pdf),
                              label: Text(_tr('PDF 합치기', 'Merge PDFs', '合并 PDF', 'PDF結合')),
                              onPressed: _showMergeExistingPdfsDialog,
                            ),
                            OutlinedButton.icon(
                              icon: const Icon(Icons.auto_stories),
                              label: Text(_tr('JPG 이미지 합치기', 'Merge JPGs', '合并图片', 'JPG結合')),
                              onPressed: _showMergeExistingImagesDialog,
                            ),
                          ],
                        ),
                      ),
                    )
                  : Listener(
                      behavior: HitTestBehavior.translucent,
                      onPointerDown: (event) {
                        if (_isSelectionMode) {
                          _pointerDownGlobalPos = event.position;
                          _pointerDownRowPath = _findFileRowPathAtGlobalPos(event.position);
                          _lastDragTouchedPath = null;
                        }
                      },
                      onPointerMove: (event) {
                        if (!_isSelectionMode) return;
                        if (!_isDragSelecting && _pointerDownGlobalPos != null) {
                          if ((event.position - _pointerDownGlobalPos!).distance > 8.0) {
                            setState(() {
                              _isDragSelecting = true;
                              if (_pointerDownRowPath != null) {
                                final alreadySelected = _selectedFilePaths.contains(_pointerDownRowPath!);
                                _dragTargetSelectState = !alreadySelected;
                                if (_dragTargetSelectState) {
                                  _selectedFilePaths.add(_pointerDownRowPath!);
                                } else {
                                  _selectedFilePaths.remove(_pointerDownRowPath!);
                                }
                                _lastDragTouchedPath = _pointerDownRowPath;
                              } else {
                                _dragTargetSelectState = true;
                              }
                            });
                          }
                        }
                        if (_isDragSelecting) {
                          _applyDragSelectionAtGlobalPos(event.position);
                        }
                      },
                      onPointerUp: (_) {
                        if (_isDragSelecting) {
                          setState(() => _isDragSelecting = false);
                        }
                        _pointerDownGlobalPos = null;
                        _pointerDownRowPath = null;
                        _lastDragTouchedPath = null;
                      },
                      onPointerCancel: (_) {
                        if (_isDragSelecting) {
                          setState(() => _isDragSelecting = false);
                        }
                        _pointerDownGlobalPos = null;
                        _pointerDownRowPath = null;
                        _lastDragTouchedPath = null;
                      },
                      child: _bookshelfViewMode == 'grid'
                          ? LayoutBuilder(
                              builder: (context, constraints) {
                                // 3. 휴대폰 기준 한 페이지에 9개(가로 3개 × 세로 3개)가 들어갈 정도로 크기 자동 조절
                                const int crossCount = 3;
                                const double hPad = 10.0;
                                const double vPad = 8.0;
                                const double crossSpacing = 8.0;
                                const double mainSpacing = 8.0;
                                final double cellW = ((constraints.maxWidth - (hPad * 2) - (crossSpacing * (crossCount - 1))) / crossCount).clamp(80.0, 420.0);
                                final double targetCellH = ((constraints.maxHeight - (vPad * 2) - (mainSpacing * 2)) / 3.0).clamp(130.0, 290.0);
                                final double childAspect = (cellW / targetCellH).clamp(0.50, 0.98);

                                return GridView.builder(
                                  controller: _bookshelfScrollController,
                                  physics: _isSelectionMode
                                      ? const NeverScrollableScrollPhysics()
                                      : const AlwaysScrollableScrollPhysics(),
                                  padding: const EdgeInsets.fromLTRB(hPad, vPad, hPad, 88),
                                  gridDelegate: SliverGridDelegateWithFixedCrossAxisCount(
                                    crossAxisCount: crossCount,
                                    crossAxisSpacing: crossSpacing,
                                    mainAxisSpacing: mainSpacing,
                                    childAspectRatio: childAspect,
                                  ),
                                  itemCount: filteredBooks.length,
                                  itemBuilder: (context, index) {
                                    return _buildGridBookCard(filteredBooks[index]);
                                  },
                                );
                              },
                            )
                          : ListView.separated(
                        controller: _bookshelfScrollController,
                        physics: _isSelectionMode
                            ? const NeverScrollableScrollPhysics()
                            : const AlwaysScrollableScrollPhysics(),
                        padding: const EdgeInsets.only(bottom: 88),
                        itemCount: filteredBooks.length,
                        separatorBuilder: (_, __) => const Divider(height: 1),
                        itemBuilder: (context, index) {
                          final file = filteredBooks[index];
                          final rowKey = _fileRowKeys.putIfAbsent(file.path, () => GlobalKey());
                        final rawFileName = file.path.split(Platform.pathSeparator).last;
                        final displayFileName = _formatDisplayFileName(rawFileName);
                        final grp = _bookGroupMap[file.path] ?? '미분류';
                        final prog = (_bookProgressMap[file.path] ?? 0.0) * 100;
                        final isSelected = _selectedFilePaths.contains(file.path);
                        final isFavorite = _favoritePaths.contains(file.path);
                        final lowerExt = rawFileName.split('.').last.toLowerCase();

                        final Color badgeBg = widget.isDarkMode
                            ? Colors.amber.withOpacity(0.18)
                            : const Color(0xFF1E293B);
                        final Color badgeBorder = widget.isDarkMode
                            ? Colors.amber
                            : const Color(0xFF0F172A);
                        final Color badgeFg = widget.isDarkMode
                            ? Colors.amber
                            : Colors.white;
                        final Color progressBarColor = widget.isDarkMode
                            ? Colors.amber
                            : const Color(0xFF0F766E);

                        return Dismissible(
                          key: ValueKey(file.path),
                          direction: _isSelectionMode ? DismissDirection.none : DismissDirection.endToStart,
                          background: Container(
                            color: Colors.redAccent,
                            alignment: Alignment.centerRight,
                            padding: const EdgeInsets.symmetric(horizontal: 20),
                            child: Row(
                              mainAxisAlignment: MainAxisAlignment.end,
                              children: [
                                const Icon(Icons.delete_outline, color: Colors.white),
                                const SizedBox(width: 6),
                                Text(_tr('휴지통 이동', 'Move to Trash', '移至回收站', 'ゴミ箱へ移動'), style: const TextStyle(color: Colors.white, fontWeight: FontWeight.bold)),
                              ],
                            ),
                          ),
                          onDismissed: (_) => _moveFileToTrash(file),
                          child: Container(
                            key: rowKey,
                            child: ListTile(
                            selected: isSelected,
                            leading: _isSelectionMode
                                ? Checkbox(
                                    value: isSelected,
                                    onChanged: (v) {
                                      setState(() {
                                        if (v == true) {
                                          _selectedFilePaths.add(file.path);
                                        } else {
                                          _selectedFilePaths.remove(file.path);
                                          if (_selectedFilePaths.isEmpty) {
                                            _isSelectionMode = false;
                                          }
                                        }
                                      });
                                    },
                                  )
                                : Icon(
                                    lowerExt == 'pdf'
                                        ? Icons.picture_as_pdf
                                        : (lowerExt == 'docx' || lowerExt == 'doc' || lowerExt == 'hwpx' || lowerExt == 'hwp')
                                            ? Icons.description_outlined
                                            : (lowerExt == 'epub' || lowerExt == 'txt')
                                                ? Icons.menu_book
                                                : lowerExt == 'cbz'
                                                    ? Icons.auto_stories
                                                    : Icons.image,
                                    color: Colors.indigo,
                                  ),
                            title: Text(
                              displayFileName,
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                            ),
                            subtitle: Builder(
                              builder: (context) {
                                final grpDisplay = _localizeGroupName(grp);
                                final progLabel = _tr('진행률', 'Progress', '进度', '進行率');
                                // 10. [전체]에서만 그룹 이름 표시, 특정 그룹 선택 시 그룹 이름 표시 제거
                                final subText = _selectedGroup == '전체'
                                    ? '[$grpDisplay]  •  $progLabel ${prog.toStringAsFixed(1)}%'
                                    : '$progLabel ${prog.toStringAsFixed(1)}%';
                                return Text(
                                  subText,
                                  style: const TextStyle(fontSize: 12),
                                  maxLines: 1,
                                  overflow: TextOverflow.ellipsis,
                                );
                              },
                            ),
                            trailing: _isSelectionMode
                                ? null
                                : Row(
                                    mainAxisSize: MainAxisSize.min,
                                    children: [
                                      IconButton(
                                        visualDensity: VisualDensity.compact,
                                        icon: Icon(
                                          isFavorite ? Icons.star_rounded : Icons.star_border_rounded,
                                          color: isFavorite ? Colors.amber : null,
                                        ),
                                        tooltip: _tr('즐겨찾기', 'Favorite', '收藏', 'お気に入り'),
                                        onPressed: () async {
                                          await StorageService.toggleFavoriteBook(file.path);
                                          await _loadLibrary();
                                        },
                                      ),
                                      IconButton(
                                        visualDensity: VisualDensity.compact,
                                        icon: const Icon(Icons.edit_outlined),
                                        tooltip: _tr('이름 변경', 'Rename', '重命名', '名前変更'),
                                        onPressed: () => _renameFileDialog(file),
                                      ),
                                      IconButton(
                                        visualDensity: VisualDensity.compact,
                                        icon: const Icon(Icons.drive_file_move_outline),
                                        tooltip: _tr('그룹 변경', 'Move Group', '移动分组', 'グループ移動'),
                                        onPressed: () => _assignGroupDialog(file),
                                      ),
                                    ],
                                  ),
                            onLongPress: () {
                              setState(() {
                                final bool targetSelect = !_isSelectionMode ? true : !isSelected;
                                _isSelectionMode = true;
                                _isDragSelecting = true;
                                _dragTargetSelectState = targetSelect;
                                _lastDragTouchedPath = file.path;
                                if (targetSelect) {
                                  _selectedFilePaths.add(file.path);
                                } else {
                                  _selectedFilePaths.remove(file.path);
                                }
                              });
                            },
                            onTap: () {
                              if (_isSelectionMode) {
                                setState(() {
                                  if (isSelected) {
                                    _selectedFilePaths.remove(file.path);
                                    if (_selectedFilePaths.isEmpty) {
                                      _isSelectionMode = false;
                                    }
                                  } else {
                                    _selectedFilePaths.add(file.path);
                                  }
                                });
                              } else {
                                _openFile(file);
                              }
                            },
                          ),
                          ),
                        );
                      },
                    ),
                      ),
            ),
          ],
        ),
      ),
      floatingActionButton: _isSelectionMode
          ? Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                FloatingActionButton.extended(
                  heroTag: 'fab_batch_move_group',
                  backgroundColor: Colors.indigo,
                  foregroundColor: Colors.white,
                  onPressed: _selectedFilePaths.isNotEmpty ? _moveSelectedFilesBatch : null,
                  icon: const Icon(Icons.drive_file_move_outline),
                  label: Text('${_tr("그룹 이동", "Move Group", "移动分组", "グループ移動")} (${_selectedFilePaths.length})'),
                ),
                const SizedBox(width: 10),
                FloatingActionButton.extended(
                  heroTag: 'fab_batch_delete',
                  backgroundColor: Colors.redAccent,
                  foregroundColor: Colors.white,
                  onPressed: _selectedFilePaths.isNotEmpty ? _deleteSelectedFilesBatch : null,
                  icon: const Icon(Icons.delete_outline),
                  label: Text('${_tr("선택 삭제", "Delete", "删除", "削除")} (${_selectedFilePaths.length})'),
                ),
              ],
            )
          : Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                FloatingActionButton.extended(
                  heroTag: 'fab_scan_document',
                  onPressed: _openDocumentScannerDialog,
                  icon: const Icon(Icons.document_scanner_outlined),
                  label: Text(_tr('스캔', 'Scan', '扫描', 'スキャン')),
                ),
                const SizedBox(width: 10),
                FloatingActionButton.extended(
                  heroTag: 'fab_add_files',
                  onPressed: _pickAndImportFiles,
                  icon: const Icon(Icons.add),
                  label: Text(_tr('파일 추가', 'Add Files', '添加文件', 'ファイル追加')),
                ),
              ],
            ),
    );
  }
}
