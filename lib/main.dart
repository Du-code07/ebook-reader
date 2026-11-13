import 'dart:async';
import 'dart:io';
import 'dart:isolate';
import 'dart:math' as math;
import 'package:archive/archive.dart';
import 'package:flutter/material.dart';
import 'services/app_messenger.dart';
import 'package:flutter/services.dart';
import 'package:file_picker/file_picker.dart';
import 'package:path_provider/path_provider.dart';
import 'screens/pdf_and_image_viewer.dart';
import 'screens/reader_screen.dart';
import 'screens/language_select_screen.dart';
import 'screens/app_settings_screen.dart';
import 'widgets/sheet_pull_to_close.dart';
import 'widgets/file_type_icon.dart';
import 'widgets/memo_tools.dart';
import 'widgets/favorite_ribbon.dart';
import 'widgets/group_stack_icon.dart';
import 'widgets/group_jump_menu.dart';
import 'widgets/group_dropdown.dart';
import 'widgets/morph_icons.dart';
import 'widgets/viewer_dialogs.dart';
import 'widgets/ui_scale.dart';
import 'widgets/app_colors.dart';
import 'services/storage_service.dart';
import 'services/user_fonts.dart';
import 'services/pdf_export_service.dart' show ExportFileIcon;
import 'package:flutter_epub_viewer/flutter_epub_viewer.dart' show EpubBookServer;
import 'services/doc_thumbnail_service.dart';
import 'widgets/pop_dialog.dart';

/// 상태표시줄 본래 높이(기기 픽셀). 태블릿에서 상단바를 이 높이에 맞춰 항상 내려 둔다
final ValueNotifier<int> statusBarHeightPx = ValueNotifier<int>(0);

Future<void> _readStatusBarHeight() async {
  try {
    final px = await const MethodChannel('ebook_reader/volume_control').invokeMethod<int>('statusBarHeight');
    if (px != null && px > 0) statusBarHeightPx.value = px;
  } catch (_) {}
}

void main() async {
  WidgetsFlutterBinding.ensureInitialized();
  // 상태표시줄 본래 높이 (태블릿에서 상단바를 이만큼 항상 내려 둠)
  await _readStatusBarHeight();
  PaintingBinding.instance.imageCache.maximumSize = 3000;
  PaintingBinding.instance.imageCache.maximumSizeBytes = 300 << 20;
  try {
    await UserFonts.dir(); // 사용자가 넣은 글꼴 폴더 (문서 화면이 바로 읽을 수 있게 미리 준비)
    EpubBookServer.userFontDir = UserFonts.cachedDirPath; // EPUB 글꼴도 같은 폴더에서
    await UserFonts.loadAppFont();
  } catch (_) {}
  await StorageService.loadRememberPage();
  final initialThemeMode = await StorageService.getAppThemeMode();
  final initialLang = await StorageService.getAppLanguage();
  // 앱 처음 시작 시(언어를 고른 적 없을 때) 언어 선택 화면부터 보여 준다
  final needsLanguage = await StorageService.needsLanguageSelection();
  runApp(MyEbookApp(initialThemeMode: initialThemeMode, initialLang: initialLang, needsLanguage: needsLanguage));
}

/// 문서 폴더·휴지통·표지 폴더의 파일 경로들 (다른 isolate에서 읽음)
Future<({List<String> files, List<String> trash, List<String> thumbs})> _listLibraryFolders(String docs, String trash, String thumbs) {
  return Isolate.run(() {
    List<String> filesIn(String path, {bool create = false}) {
      final d = Directory(path);
      try {
        if (!d.existsSync()) {
          if (create) d.createSync(recursive: true);
          return const [];
        }
        return [for (final e in d.listSync()) if (e is File) e.path];
      } catch (_) {
        return const [];
      }
    }

    return (files: filesIn(docs), trash: filesIn(trash), thumbs: filesIn(thumbs, create: true));
  });
}

class MyEbookApp extends StatefulWidget {
  final String initialThemeMode; // 'system' | 'light' | 'dark'
  final String initialLang;
  final bool needsLanguage;
  const MyEbookApp({
    super.key,
    required this.initialThemeMode,
    required this.initialLang,
    this.needsLanguage = false,
  });

  @override
  State<MyEbookApp> createState() => _MyEbookAppState();
}

class _MyEbookAppState extends State<MyEbookApp> with SingleTickerProviderStateMixin, WidgetsBindingObserver {
  late String _themeMode;
  bool get _isDarkMode => StorageService.isDarkFor(_themeMode);
  late String _appLang;
  late bool _needsLanguage;
  bool _needsTheme = false; // 처음 시작: 언어를 고른 다음 앱 테마 고르기
  late final AnimationController _rotationAnimController;
  late final Animation<double> _rotationFadeAnim;
  late final Animation<double> _rotationScaleAnim;
  @override
  void initState() {
    super.initState();
    // '완전 다크 모드'는 없앰: 예전에 고른 경우 다크 모드로
    // 없어진 테마(완전 다크·밝은 다크)는 다크로
    _themeMode = widget.initialThemeMode == 'black' || widget.initialThemeMode == 'dim' ? 'dark' : widget.initialThemeMode;
    _appLang = widget.initialLang;
    _needsLanguage = widget.needsLanguage;
    WidgetsBinding.instance.addObserver(this);
    _rotationAnimController = AnimationController(
      vsync: this,
      duration: Anim.ms(240),
      value: 1.0,
    );
    _rotationFadeAnim = Tween<double>(begin: 0.72, end: 1.0).animate(
      CurvedAnimation(parent: _rotationAnimController, curve: Curves.easeOutCubic),
    );
    _rotationScaleAnim = Tween<double>(begin: 0.96, end: 1.0).animate(
      CurvedAnimation(parent: _rotationAnimController, curve: Curves.easeOutCubic),
    );
    StorageService.desiredLandscapeNotifier.addListener(_onDesiredOrientationChanged);
    // 화면이 다 붙은 뒤에 실제 상태표시줄 높이를 한 번 더 읽음 (시작 직후에는 못 읽는 기기가 있음)
    WidgetsBinding.instance.addPostFrameCallback((_) => _readStatusBarHeight());
  }

  void _onDesiredOrientationChanged() {
    if (mounted) {
      _rotationAnimController.forward(from: 0.0);
    }
  }

  @override
  void dispose() {
    StorageService.desiredLandscapeNotifier.removeListener(_onDesiredOrientationChanged);
    WidgetsBinding.instance.removeObserver(this);
    _rotationAnimController.dispose();
    super.dispose();
  }


  /// 앱 테마 바꾸기 ('system' | 'light' | 'dark')
  Future<void> _changeThemeMode(String mode) async {
    setState(() => _themeMode = mode);
    await StorageService.setAppThemeMode(mode);
  }

  /// [setting]: 'system'(기본 시스템) 또는 'ko'/'en'/'zh'/'ja'
  void _changeAppLanguage(String setting) async {
    setState(() => _appLang = StorageService.resolveAppLanguage(setting));
    await StorageService.setAppLanguage(setting);
  }

  // '기본 시스템' 테마일 때 휴대폰의 밝게/어둡게가 바뀌면 다시 그린다
  @override
  void didChangePlatformBrightness() {
    if (_themeMode == 'system' && mounted) setState(() {});
  }

  // '기본 시스템'일 때 휴대폰 언어를 바꾸면 앱 문구도 따라 바뀐다
  @override
  void didChangeLocales(List<Locale>? locales) {
    final setting = StorageService.appLangSetting ?? 'system';
    if (setting != 'system') return;
    final code = StorageService.resolveSystemLanguage();
    StorageService.appLangNotifier.value = code;
    if (mounted && code != _appLang) setState(() => _appLang = code);
  }

  /// 앱 테마: 다크는 기본(남색 기운) / 완전 다크(검정) / 밝은 다크(회색) 세 가지
  /// 글씨·아이콘은 전체적으로 조금 작게 (아이콘 기본 21)
  // 굵기만 정함 (글꼴은 비워 두어 앱 글꼴이 그대로 적용되게)
  static const TextTheme _boldTitles = TextTheme(
    headlineLarge: TextStyle(fontWeight: FontWeight.w800),
    headlineMedium: TextStyle(fontWeight: FontWeight.w800),
    headlineSmall: TextStyle(fontWeight: FontWeight.w800), // 대화창 제목
    titleLarge: TextStyle(fontWeight: FontWeight.w800), // 상단바 제목
    titleMedium: TextStyle(fontWeight: FontWeight.w700),
    titleSmall: TextStyle(fontWeight: FontWeight.w700),
  );

  ThemeData _appTheme(Brightness b, {String variant = 'dark'}) {
    final String? appFont = UserFonts.appFontName.value;
    // 앱 대표 색: 연두색 — 고른 것·켜짐·버튼 '바탕'에만 (글씨·아이콘은 기본 색), 연두 바탕 위 글씨는 흰색
    final Color sig = variant == 'library' ? const Color(0xFF3F6B4F) : (b == Brightness.light ? AppColors.signature : AppColors.signatureDark);
    Color mark = b == Brightness.light ? sig : const Color(0xFFE6E6E9);
    // 색이 섞이지 않은 무채색 바탕 (예전 연두빛 바탕 대신): 라이트는 완전 흰색
    var scheme = ColorScheme.fromSeed(seedColor: const Color(0xFF8A8A8A), brightness: b, dynamicSchemeVariant: DynamicSchemeVariant.monochrome);
    if (b == Brightness.light && variant == 'comfort') {
      // 편안한 모드: 푸른빛을 줄인 따뜻한 미색 종이 바탕 + 짙은 갈색 글씨
      scheme = scheme.copyWith(
        surface: const Color(0xFFFAF3E6),
        onSurface: const Color(0xFF3B3328),
        onSurfaceVariant: const Color(0xFF6B5E4D),
        surfaceContainerLowest: const Color(0xFFFFFAF1),
        surfaceContainerLow: const Color(0xFFF6EEDF),
        surfaceContainer: const Color(0xFFF2E9D8),
        surfaceContainerHigh: const Color(0xFFEDE3D0),
        surfaceContainerHighest: const Color(0xFFE7DCC7),
        outline: const Color(0xFFAD9F88),
        outlineVariant: const Color(0xFFD8CCB6),
        primary: const Color(0xFF4A4034),
        onPrimary: Colors.white,
        secondary: const Color(0xFF6E6252),
        primaryContainer: sig,
        onPrimaryContainer: AppColors.onSignature,
        secondaryContainer: sig,
        onSecondaryContainer: AppColors.onSignature,
      );
    } else if (b == Brightness.light) {
      scheme = scheme.copyWith(
        surface: Colors.white,
        onSurface: const Color(0xFF1C1C1E),
        onSurfaceVariant: const Color(0xFF5C5C61),
        surfaceContainerLowest: Colors.white,
        surfaceContainerLow: const Color(0xFFF7F7F8),
        surfaceContainer: const Color(0xFFF2F2F4),
        surfaceContainerHigh: const Color(0xFFECECEF),
        surfaceContainerHighest: const Color(0xFFE6E6E9),
        primary: const Color(0xFF33363A),
        onPrimary: Colors.white,
        primaryContainer: sig,
        onPrimaryContainer: AppColors.onSignature,
        secondary: const Color(0xFF5E6166),
        secondaryContainer: sig,
        onSecondaryContainer: AppColors.onSignature,
      );
    } else if (variant == 'library') {
      // 서재: 짙은 호두나무 책장 바탕 + 미색 종이 글씨, 대표 색은 초록 독서등(뱅커스 램프) 색
      mark = const Color(0xFFA9D1B2);
      scheme = scheme.copyWith(
        surface: const Color(0xFF2A211B),
        onSurface: const Color(0xFFEFE4D2),
        onSurfaceVariant: const Color(0xFFC7B59C),
        surfaceContainerLowest: const Color(0xFF211A15),
        surfaceContainerLow: const Color(0xFF30261F),
        surfaceContainer: const Color(0xFF372B23),
        surfaceContainerHigh: const Color(0xFF40332A),
        surfaceContainerHighest: const Color(0xFF4A3B30),
        outline: const Color(0xFF8A765F),
        outlineVariant: const Color(0xFF5A4A3C),
        primary: const Color(0xFFE8D5B5),
        onPrimary: const Color(0xFF2A211B),
        secondary: const Color(0xFFD9C3A0),
        primaryContainer: sig,
        onPrimaryContainer: Colors.white,
        secondaryContainer: sig,
        onSecondaryContainer: Colors.white,
      );
    } else {
      // 다크: 대표 색 자리에는 회색 (글꼴 찾기 단추 바탕과 같은 색), 그 위 글씨는 흰색
      scheme = scheme.copyWith(
        surface: const Color(0xFF141416),
        onSurface: const Color(0xFFE6E6E9),
        onSurfaceVariant: const Color(0xFFB4B4BA),
        surfaceContainerLowest: const Color(0xFF0E0E10),
        surfaceContainerLow: const Color(0xFF1A1A1D),
        surfaceContainer: const Color(0xFF1F1F22),
        surfaceContainerHigh: const Color(0xFF29292D),
        surfaceContainerHighest: sig,
        primary: const Color(0xFFE6E6E9),
        onPrimary: const Color(0xFF1A1A1C),
        primaryContainer: sig,
        onPrimaryContainer: Colors.white,
        secondaryContainer: sig,
        onSecondaryContainer: Colors.white,
      );
    }
    return ThemeData(
      useMaterial3: true,
      colorScheme: scheme,
      // 애니메이션 멈추기: 화면 넘어갈 때도 바로
      pageTransitionsTheme: Anim.off.value
          ? const PageTransitionsTheme(builders: {
              TargetPlatform.android: _NoPageTransition(),
              TargetPlatform.iOS: _NoPageTransition(),
            })
          : null,
      extensions: [SigColors(sig: sig, mark: mark)],
      fontFamily: appFont,
      iconTheme: IconThemeData(size: 21, color: scheme.onSurface),
      // 상단바 아이콘: 테마 글자색 (다크·밝은 다크에서도 보이게)
      // 제목 느낌의 글씨는 모두 굵게 (상단바 제목·창 제목·항목 제목)
      textTheme: _boldTitles,
      appBarTheme: AppBarTheme(
        iconTheme: IconThemeData(size: 21, color: scheme.onSurface),
        actionsIconTheme: IconThemeData(size: 21, color: scheme.onSurfaceVariant),
      ),
      // 켜짐 스위치·체크 상자: 연두색 바탕 + 흰 손잡이/체크
      switchTheme: SwitchThemeData(
        trackColor: WidgetStateProperty.resolveWith((s) => s.contains(WidgetState.selected) ? sig : (b == Brightness.dark ? scheme.surfaceContainerLow : null)),
        thumbColor: WidgetStateProperty.resolveWith((s) => s.contains(WidgetState.selected) ? Colors.white : null),
        trackOutlineColor: WidgetStateProperty.resolveWith((s) => s.contains(WidgetState.selected) ? (b == Brightness.dark ? const Color(0xFF5A5A60) : sig) : null),
      ),
      checkboxTheme: CheckboxThemeData(
        fillColor: WidgetStateProperty.resolveWith((s) => s.contains(WidgetState.selected) ? sig : null),
        checkColor: WidgetStatePropertyAll(b == Brightness.dark ? Colors.white : AppColors.onSignature),
      ),
      radioTheme: RadioThemeData(fillColor: WidgetStateProperty.resolveWith((s) => s.contains(WidgetState.selected) ? sig : null)),
      // 아래에서 올라오는 모든 창: 위쪽 가운데 회색 막대
      bottomSheetTheme: BottomSheetThemeData(
        showDragHandle: true,
        dragHandleColor: scheme.onSurfaceVariant.withValues(alpha: 0.4),
        dragHandleSize: const Size(40, 4),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return ValueListenableBuilder<String?>(
      valueListenable: UserFonts.appFontName,
      // 애니메이션 멈추기를 바꾸면 화면 전환 방식도 다시 정함
      builder: (context, _, __) => ValueListenableBuilder<bool>(valueListenable: Anim.off, builder: (context, _, __) => _buildApp(context)),
    );
  }

  Widget _buildApp(BuildContext context) {
    return MaterialApp(
      scaffoldMessengerKey: appMessengerKey,
      debugShowCheckedModeBanner: false,
      title: 'FReader',
      // 테마를 바꿀 때 색을 서서히 섞는 동안 화면 전체를 매번 다시 그려 느려짐 → 바로 바꿈
      themeAnimationDuration: Duration.zero,
      themeMode: _themeMode == 'dark' || _themeMode == 'library'
          ? ThemeMode.dark
          : (_themeMode == 'light' || _themeMode == 'comfort' ? ThemeMode.light : ThemeMode.system),
      theme: _appTheme(Brightness.light, variant: _themeMode == 'comfort' ? 'comfort' : 'light'),
      darkTheme: _appTheme(Brightness.dark, variant: _themeMode == 'library' ? 'library' : 'dark'),
      builder: (context, child) {
        // 상태표시줄을 내려 화면 위에 보이는 동안에는 그 높이만큼 위쪽 여백을 늘려
        // 상단바(SafeArea를 쓰는 곳 모두)가 함께 내려와 겹치지 않게 한다
        // 태블릿: 상태표시줄을 내려도 상단바 아이콘을 가리지 않도록 상단바를 상태표시줄 높이만큼 항상 내려 둔다
        // (앱 시작 화면·파일 열람 화면 모두. 휴대폰은 그대로)
        // 상단바 아이콘 위에는 원래 16dp 빈칸이 있으므로, 상태표시줄 높이보다 10dp 덜 내려
        // 상태표시줄 바로 아래(약 6dp 여유)에 아이콘이 오게 한다
        final content = ValueListenableBuilder<int>(
          valueListenable: statusBarHeightPx,
          builder: (context, px, _) {
            final mq = MediaQuery.of(context);
            final bool tablet = mq.size.shortestSide >= 600;
            final double dpr = mq.devicePixelRatio > 0 ? mq.devicePixelRatio : 1.0;
            final double top = px / dpr - 10;
            // 글씨를 전체적으로 약 3pt 작게 (16 → 13.6)
            final scaler = TextScaler.linear((mq.textScaler.scale(16) / 16) * 0.85);
            if (!tablet || top <= mq.padding.top + 0.5) {
              return MediaQuery(data: mq.copyWith(textScaler: scaler), child: child ?? const SizedBox.shrink());
            }
            return MediaQuery(
              data: mq.copyWith(
                textScaler: scaler,
                padding: mq.padding.copyWith(top: top),
                viewPadding: mq.viewPadding.copyWith(top: math.max(mq.viewPadding.top, top)),
              ),
              child: child ?? const SizedBox.shrink(),
            );
          },
        );
        final Widget app = FadeTransition(
          opacity: _rotationFadeAnim,
          child: ScaleTransition(
            scale: _rotationScaleAnim,
            // 아이콘을 꾹 누르거나 S펜을 가까이 대면 뜨던 이름 말풍선을 모두 끔 (화면 낭독용 이름은 그대로)
            // 화면이 넓으면(태블릿 등) 기준 휴대폰과 같은 비율로 앱 화면 전체를 크게
            // 앱 글꼴: 테마 밖(창 위에 바로 그려지는 글 등)까지 모든 글자에
            child: TooltipVisibility(
              visible: false,
              child: UiScaleBox(
                // 누른 자리 기억 (창이 그 자리에서 커져 나오게)
                child: TapOrigin.track(UserFonts.appFontName.value == null
                    ? content
                    : DefaultTextStyle.merge(style: TextStyle(fontFamily: UserFonts.appFontName.value), child: content)),
              ),
            ),
          ),
        );
        if (_themeMode != 'comfort') return app;
        // 편안한 모드: 화면 전체(열어 본 파일 포함)에 옅은 호박색을 덮어 푸른빛을 줄임
        return Stack(fit: StackFit.expand, textDirection: TextDirection.ltr, children: [
          app,
          const IgnorePointer(child: ColoredBox(color: Color(0x1FFF9100))),
        ]);
      },
      home: _needsLanguage
          ? LanguageSelectScreen(
              onConfirmed: (setting) {
                _changeAppLanguage(setting);
                setState(() {
                  _needsLanguage = false;
                  _needsTheme = true;
                });
              },
            )
          : _needsTheme
          ? ThemeSelectScreen(
              lang: _appLang,
              initial: _themeMode,
              onChanged: _changeThemeMode,
              onConfirmed: (mode) {
                _changeThemeMode(mode);
                setState(() => _needsTheme = false);
              },
            )
          : BookshelfScreen(
              isDarkMode: _isDarkMode,
              appLang: _appLang,
              themeMode: _themeMode,
              onChangeThemeMode: _changeThemeMode,
              onChangeLanguage: _changeAppLanguage,
            ),
    );
  }
}

/// '사용 설명서' 화면: 지금 앱에 있는 기능만, 실제 아이콘과 함께
class UserManualScreen extends StatelessWidget {
  final String appLang;
  const UserManualScreen({super.key, required this.appLang});

  String _tr(String ko, String en, String zh, String ja) => AppI18n.t(appLang, ko: ko, en: en, zh: zh, ja: ja);

  Widget _section(BuildContext context, String text) => Padding(
        padding: const EdgeInsets.only(top: 22, bottom: 6),
        child: Text(text, style: const TextStyle(fontSize: 18, fontWeight: FontWeight.w800)),
      );

  Widget _row(BuildContext context, {required Widget icon, required String title, required String desc}) {
    final cs = Theme.of(context).colorScheme;
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 8),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Container(
            width: 44,
            height: 44,
            decoration: BoxDecoration(color: cs.surfaceContainerHighest, borderRadius: BorderRadius.circular(12)),
            alignment: Alignment.center,
            child: IconTheme(data: IconThemeData(color: cs.onSurface, size: 21), child: icon),
          ),
          const SizedBox(width: 14),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(title, style: const TextStyle(fontSize: 15, fontWeight: FontWeight.w800)),
                const SizedBox(height: 3),
                Text(desc, style: TextStyle(fontSize: 13, height: 1.45, color: cs.onSurfaceVariant)),
              ],
            ),
          ),
        ],
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    return Scaffold(
      appBar: AppBar(title: Text(_tr('사용 설명서', 'User Manual', '使用说明书', '取扱説明書'))),
      body: SafeArea(
        child: ListView(
          padding: const EdgeInsets.fromLTRB(16, 4, 16, 24),
          children: [
            Text(
              _tr('PDF·EPUB·워드(docx·doc)·한글(hwp·hwpx)·엑셀(xlsx)·PPT(pptx)·TXT·사진(jpg·png)·만화(cbz) 파일을 볼 수 있어요',
                  'Opens PDF, EPUB, Word (docx, doc), Hangul (hwp, hwpx), Excel (xlsx), PowerPoint (pptx), TXT, images (jpg, png) and comics (cbz)',
                  '可查看 PDF、EPUB、Word(docx·doc)、韩文(hwp·hwpx)、Excel(xlsx)、PPT(pptx)、TXT、图片(jpg·png)、漫画(cbz)文件',
                  'PDF・EPUB・Word(docx・doc)・ハングル(hwp・hwpx)・Excel(xlsx)・PPT(pptx)・TXT・画像(jpg・png)・漫画(cbz)を閲覧できます'),
              style: TextStyle(fontSize: 13.5, height: 1.45, color: cs.onSurfaceVariant),
            ),

            // ── 1. 서재(MY) ──
            _section(context, _tr('1. 서재 (MY)', '1. Library (MY)', '1. 书架 (MY)', '1. 書斎 (MY)')),
            _row(context,
                icon: const Icon(Icons.add),
                title: _tr('파일 추가', 'Add Files', '添加文件', 'ファイル追加'),
                desc: _tr('오른쪽 아래 [파일 추가]를 누르면 파일 추가·PDF 합치기·이미지 합치기(CBZ로 묶기)를 고를 수 있어요',
                    'Tap [Add Files] at the bottom right to add files, merge PDFs, or merge images into a CBZ book',
                    '点右下角[添加文件]可选择添加文件、合并 PDF、合并图片（打包为 CBZ）',
                    '右下の[ファイル追加]から、ファイル追加・PDF結合・画像結合(CBZにまとめる)を選べます')),
            _row(context,
                icon: GroupStackIcon(size: 19, spread: false, color: cs.onSurface),
                title: _tr('그룹', 'Groups', '分组', 'グループ'),
                desc: _tr('[그룹] 단추를 누르면 그룹 목록이 펼쳐져요\n맨 위 [전체]·[즐겨찾기]는 고정이고, 그룹은 ≡ 손잡이를 끌어 순서를 바꾸고, 꾹 눌러 이름 수정·그룹 삭제를 해요\n지운 그룹의 파일은 미분류로 옮겨져 [전체]에서 볼 수 있어요\n맨 아래 [+ 그룹 추가]로 새 그룹을 만들어요',
                    'Tap [Groups] to open the group list\n[All] and [Favorites] stay on top; drag the ≡ handle to reorder, long-press a group to rename or delete it (its files move to Uncategorized, shown in [All])\nUse [+ Add Group] at the bottom to create one',
                    '点[分组]打开分组列表\n[全部]和[收藏]固定在顶部；拖动 ≡ 手柄调整顺序，长按分组可重命名或删除（其中文件移至未分类，可在[全部]中查看）\n底部[+ 添加分组]可新建分组',
                    '[グループ]を押すとグループ一覧が開きます\n[すべて]・[お気に入り]は固定、≡ を引いて並べ替え、長押しで名前変更・削除できます（中のファイルは未分類に移り[すべて]に表示）\n一番下の[+ グループ追加]で作成します')),
            _row(context,
                icon: const SizedBox(width: 24, height: 24, child: FavoriteRibbon(active: true, width: 12, height: 18, isDark: true)),
                title: _tr('즐겨찾기 (책갈피)', 'Favorites (Ribbon)', '收藏（书签）', 'お気に入り（しおり）'),
                desc: _tr('파일 왼쪽 위 책갈피를 누르거나, 목록형에서 파일을 오른쪽으로 밀면 즐겨찾기가 되어 맨 위에 놓여요\n그룹 목록의 [즐겨찾기]에서 모아 볼 수 있어요',
                    'Tap the ribbon at a file\'s top-left, or swipe the file right in list view, to favorite it and pin it to the top\nSee them all under [Favorites] in the group list',
                    '点文件左上角的书签，或在列表视图中向右滑动文件，即可收藏并置顶\n可在分组列表的[收藏]中集中查看',
                    'ファイル左上のしおりを押すか、リスト表示で右へスワイプするとお気に入りになり一番上に表示されます\nグループ一覧の[お気に入り]でまとめて見られます')),
            _row(context,
                icon: const Icon(Icons.more_vert),
                title: _tr('파일 메뉴 (점 3개)', 'File Menu (⋮)', '文件菜单 (⋮)', 'ファイルメニュー (⋮)'),
                desc: _tr('이름 변경·그룹 이동·휴지통 이동을 해요\n표지형에서는 표지 변경·원래 표지로도 있어요\n목록형에서 파일을 왼쪽으로 밀면 휴지통으로 가요\n(밀기는 앱 설정에서 끌 수 있어요)',
                    'Rename, move to a group, or move to trash\nIn cover view you can also change or reset the cover\nIn list view, swipe a file left to trash it (swiping can be turned off in app settings)',
                    '可重命名、移动分组、移至回收站\n封面视图中还可更换或恢复封面\n列表视图中向左滑动文件即移至回收站（可在应用设置中关闭滑动）',
                    '名前変更・グループ移動・ゴミ箱へ移動ができます\n表紙表示では表紙の変更・元に戻すも\nリスト表示で左へスワイプするとゴミ箱へ（スワイプはアプリ設定でオフにできます）')),
            _row(context,
                icon: const Icon(Icons.checklist_rounded),
                title: _tr('여러 파일 고르기', 'Select Multiple Files', '多选文件', '複数ファイルを選択'),
                desc: _tr('파일을 꾹 누르면 여러 개를 고를 수 있고, 아래 단추로 한꺼번에 그룹 이동하거나 휴지통으로 보내요',
                    'Long-press a file to select several, then move them to a group or trash them at once with the buttons below',
                    '长按文件可多选，再用下方按钮一次移动分组或移至回收站',
                    'ファイルを長押しすると複数選べ、下のボタンでまとめてグループ移動・ゴミ箱へ移動できます')),
            _row(context,
                icon: const Icon(Icons.search),
                title: _tr('검색', 'Search', '搜索', '検索'),
                desc: _tr('파일 이름으로 찾아요', 'Find files by name', '按文件名查找', 'ファイル名で探します')),
            _row(context,
                icon: const Icon(Icons.delete_outline),
                title: _tr('휴지통', 'Trash', '回收站', 'ゴミ箱'),
                desc: _tr('지운 파일을 되살리거나 완전히 지워요\n빨간 숫자는 휴지통에 있는 파일 수예요',
                    'Restore or permanently delete removed files\nThe red number shows how many files are in the trash',
                    '恢复或彻底删除已删除的文件\n红色数字为回收站中的文件数',
                    '削除したファイルを復元または完全削除します\n赤い数字はゴミ箱のファイル数です')),
            _row(context,
                icon: const Icon(Icons.sort_rounded),
                title: _tr('정렬', 'Sort', '排序', '並べ替え'),
                desc: _tr('이름(오름차순·내림차순) 또는 파일 추가 날짜(최신순·오래된 순)로 정렬해요\n[정렬 기억하기]를 켜면 다음에도 그대로예요',
                    'Sort by name (ascending/descending) or date added (newest/oldest)\nTurn on [Remember sort] to keep it next time',
                    '按名称（升序/降序）或添加日期（最新/最早）排序\n开启[记住排序]后下次仍保持',
                    '名前(昇順・降順)または追加日(新しい順・古い順)で並べ替えます\n[並べ替えを記憶]をオンにすると次回も同じです')),
            _row(context,
                icon: const Icon(Icons.settings_outlined),
                title: _tr('앱 설정', 'App Settings', '应用设置', 'アプリ設定'),
                desc: _tr('앱 테마(라이트·다크·편안한 모드·서재), 언어, 파일 표시 방식(목록형·표지형, 형식·그룹 숨기기), 페이지 기억하기, 탭 가이드라인 끄기, 글꼴(한글·워드·EPUB·앱 글꼴, 글꼴 찾기), 사용 설명서가 있어요',
                    'App theme (light, dark, comfort, library), language, file display (list/cover, hide extensions or groups), remember last page, turn off the tap guide, fonts (HWP·Word, EPUB and app fonts, Find Fonts), and this manual',
                    '包含应用主题（浅色·深色·舒适·书房）、语言、文件显示方式（列表·封面，隐藏格式·分组）、记住页面、关闭点击指引、字体（韩文·Word、EPUB、应用字体，查找字体）和使用说明书',
                    'アプリのテーマ(ライト・ダーク・快適・書斎)、言語、ファイル表示(リスト・表紙、形式・グループを隠す)、ページを記憶、タップガイドをオフ、フォント(ハングル・Word・EPUB・アプリ、フォント検索)、取扱説明書があります')),

            // ── 2. 파일 보기 ──
            _section(context, _tr('2. 파일 보기', '2. Reading Files', '2. 查看文件', '2. ファイルを見る')),
            _row(context,
                icon: const Icon(Icons.touch_app_outlined),
                title: _tr('화면 누르기 (탭 존)', 'Tap Zones', '点击区域', 'タップゾーン'),
                desc: _tr('탭 넘김일 때 화면 위 2/3를 누르면 메뉴, 아래 1/3의 왼쪽·오른쪽을 누르면 이전·다음 쪽이에요\n슬라이드·스크롤일 때는 어디를 눌러도 메뉴예요\n파일을 열 때마다 구역 안내가 나오고, 앱 설정에서 끌 수 있어요',
                    'With tap turning, tap the top two-thirds for the menu and the bottom-left / bottom-right for the previous / next page\nIn slide or scroll mode, any tap opens the menu\nA zone guide appears each time a file opens; turn it off in app settings',
                    '点击翻页时，点屏幕上方 2/3 打开菜单，点下方 1/3 的左·右翻到上一页·下一页\n滑动·滚动模式下点任意处都是菜单\n每次打开文件会显示区域指引，可在应用设置中关闭',
                    'タップめくりでは画面上 2/3 でメニュー、下 1/3 の左・右で前・次のページです\nスライド・スクロールではどこを押してもメニューです\nファイルを開くたびに区域の案内が出て、アプリ設定でオフにできます')),
            _row(context,
                icon: const Icon(Icons.list),
                title: _tr('목차', 'Contents', '目录', '目次'),
                desc: _tr('EPUB·PDF는 파일에 들어 있는 목차(책갈피)를, 워드·한글은 문서의 목차 쪽이나 번호 붙은 제목으로 목차를 만들어 보여 줘요\n목차가 없으면 \'표시할 목차가 없어요\'라고 나와요\n파일 내보내기를 하면 목차도 함께 들어가요',
                    'EPUB and PDF show the contents (bookmarks) stored in the file; Word and Hangul build contents from the document\'s contents page or numbered headings\nIf there are none, it says "No contents to show"\nExported files keep the contents',
                    'EPUB·PDF 显示文件内的目录（书签），Word·韩文根据目录页或编号标题生成目录\n没有目录时显示“没有可显示的目录”\n导出文件时目录也会一并保存',
                    'EPUB・PDFはファイル内の目次(しおり)を、Word・ハングルは目次ページや番号付きの見出しから目次を作ります\nない場合は「表示できる目次がありません」と出ます\n書き出したファイルにも目次が入ります')),
            _row(context,
                icon: const Icon(Icons.search),
                title: _tr('파일 내 단어 검색', 'Find in File', '在文件中查找', 'ファイル内検索'),
                desc: _tr('파일 안의 글자를 찾아 그 쪽으로 이동해요', 'Finds words in the file and jumps to them', '查找文件中的文字并跳转', 'ファイル内の文字を探してそのページへ移動します')),
            _row(context,
                icon: const MoonMorphIcon(filled: false, size: 20),
                title: _tr('배경 색상', 'Background Color', '背景颜色', '背景色'),
                desc: _tr('라이트·다크를 바꿔요(EPUB은 세피아도)\n한글·워드·TXT는 이 설정을, 그 밖의 파일은 앱 테마를 따르고, 파일에 배경색이 있으면 그 색이 먼저예요',
                    'Switch light / dark (EPUB also has sepia)\nHangul, Word and TXT follow this setting; other files follow the app theme\nA file\'s own background color always comes first',
                    '切换浅色·深色（EPUB 另有棕褐色）\n韩文·Word·TXT 按此设置，其他文件按应用主题；文件自带背景色时优先使用',
                    'ライト・ダークを切り替えます(EPUBはセピアも)\nハングル・Word・TXTはこの設定、それ以外はアプリのテーマに従い、ファイル自体の背景色があればそれが優先です')),
            _row(context,
                icon: ExportFileIcon(size: 21, color: cs.onSurface),
                title: _tr('파일 내보내기', 'Export File', '导出文件', 'ファイルを書き出す'),
                desc: _tr('메모·필기와 목차를 넣은 PDF로 내보내요', 'Exports a PDF including your memos, handwriting and contents', '导出包含笔记、手写和目录的 PDF', 'メモ・手書きと目次を入れたPDFに書き出します')),
            _row(context,
                icon: const Icon(Icons.tune),
                title: _tr('뷰어 설정', 'Viewer Settings', '阅读器设置', 'ビューア設定'),
                desc: _tr('글자 크기(EPUB), 페이지 모드(탭·슬라이드·스크롤 — 스크롤이면 스크롤바 끄기), 페이지 전환 버튼(음량·S펜), 화면 잠금 끄는 방법(흔들기·음량 버튼 동시에), 진행도 UI 위치, 메모 도구 모음 위치, 도구 모음 형태, 왼손잡이, 하단 정보 표시를 정해요',
                    'Font size (EPUB), page mode (tap / slide / scroll — with an option to hide the scroll bar), page-turn buttons (volume, S Pen), how to unlock the screen (shake / both volume keys), progress bar position, memo toolbar position, toolbox style, left-handed mode and footer info',
                    '设置字号（EPUB）、翻页模式（点击·滑动·滚动，滚动时可隐藏滚动条）、翻页按键（音量·S Pen）、解除锁屏方式（摇晃·同时按音量键）、进度条位置、笔记工具栏位置、工具箱样式、左手模式和底部信息',
                    '文字サイズ(EPUB)、ページモード(タップ・スライド・スクロール — スクロール時はスクロールバーを隠す)、ページめくりボタン(音量・Sペン)、画面ロックの解除方法(振る・音量ボタン同時押し)、進行度バーの位置、メモツールバーの位置、ツールボックスの形、左利き、下部情報表示を設定します')),
            _row(context,
                icon: const Icon(Icons.grid_view_rounded),
                title: _tr('도구 모음', 'Toolbox', '工具箱', 'ツールボックス'),
                desc: _tr('이전·다음 파일(같은 그룹), 화면 잠금, 화면 회전(자동·세로·가로), 페이지 표시(한 쪽·두 쪽·자동), 읽기 방향(좌→우·우→좌, 파일마다 기억), 메모, 글자 복사, 북마크, 확대·축소가 있어요',
                    'Previous / next file (same group), lock screen, rotate (auto / portrait / landscape), page display (one / two pages / auto), reading direction (L→R / R→L, remembered per file), memo, copy text, bookmarks, and zoom',
                    '包括上一个·下一个文件（同一分组）、锁定屏幕、旋转屏幕（自动·竖屏·横屏）、页面显示（单页·双页·自动）、阅读方向（左→右·右→左，按文件记忆）、笔记、复制文字、书签、放大·缩小',
                    '前・次のファイル(同じグループ)、画面ロック、画面回転(自動・縦・横)、ページ表示(1ページ・2ページ・自動)、読む方向(左→右・右→左、ファイルごとに記憶)、メモ、文字コピー、ブックマーク、拡大・縮小があります')),
            _row(context,
                icon: const Icon(Icons.swap_vert_rounded),
                title: _tr('스크롤 보기', 'Scroll View', '滚动视图', 'スクロール表示'),
                desc: _tr('쪽을 세로로 이어서 봐요\n오른쪽 회색 막대를 끌면 빠르게 이동해요\n두 손가락으로 벌려 확대하고, 두 번 누르면 원래 크기로 돌아와요\n스크롤 보기에서는 메모를 쓰지 않아요',
                    'Pages continue vertically\nDrag the gray bar on the right to move quickly\nPinch to zoom and double-tap to reset\nMemos are off in scroll view',
                    '页面纵向连续显示\n拖动右侧灰色滚动条可快速移动\n双指张开放大，双击恢复原始大小\n滚动视图中不能使用笔记',
                    'ページを縦につなげて表示します\n右の灰色バーを引くと素早く移動できます\n2本指で拡大、ダブルタップで元のサイズに戻ります\nスクロール表示ではメモは使えません')),

            // ── 3. 메모 ──
            _section(context, _tr('3. 메모 (필기)', '3. Memos (Handwriting)', '3. 笔记（手写）', '3. メモ（手書き）')),
            _row(context,
                icon: QuillInkIcon(color: cs.onSurface, size: 22),
                title: _tr('메모 도구 모음', 'Memo Toolbar', '笔记工具栏', 'メモツールバー'),
                desc: _tr('펜(한 번 더 누르면 굵기·색상), 획 지우개(한 번 더 누르면 종류), 손으로 글씨 쓰기, 되돌리기·다시 실행, 필기 전체 지우기, 완료가 있어요\n고른 도구는 연두색으로 표시돼요\nS펜으로 쓰는 동안에는 쪽이 넘어가지 않아요',
                    'Pen (tap again for width and color), stroke eraser (tap again for type), finger writing, undo / redo, clear all and done\nThe selected tool is highlighted in green\nWriting with the S Pen never turns the page',
                    '有笔（再点一次调粗细·颜色）、笔画橡皮擦（再点一次选类型）、手指书写、撤销·重做、清除全部手写、完成\n所选工具以绿色显示\n用 S Pen 书写时不会翻页',
                    'ペン(もう一度でペンの太さ・色)、消しゴム(もう一度で種類)、指で手書き、元に戻す・やり直し、手書きを全消去、完了があります\n選んだツールは黄緑で表示されます\nSペンで書いている間はページがめくれません')),
          ],
        ),
      ),
    );
  }
}

/// 그리드/리스트 스크롤 시 화면 밖으로 나간 카드 위젯과 디코딩된 썸네일 GPU 텍스처가 절대 파괴되지 않도록 유지하는 KeepAlive 래퍼
class _KeepAliveBookItem extends StatefulWidget {
  final Widget child;
  const _KeepAliveBookItem({super.key, required this.child});

  @override
  State<_KeepAliveBookItem> createState() => _KeepAliveBookItemState();
}

class _KeepAliveBookItemState extends State<_KeepAliveBookItem>
    with AutomaticKeepAliveClientMixin {
  @override
  bool get wantKeepAlive => true;

  @override
  Widget build(BuildContext context) {
    super.build(context);
    return widget.child;
  }
}

class BookshelfScreen extends StatefulWidget {
  final bool isDarkMode;
  final String appLang;
  final String themeMode;
  final Future<void> Function(String mode) onChangeThemeMode;
  final ValueChanged<String> onChangeLanguage;

  const BookshelfScreen({
    super.key,
    required this.isDarkMode,
    required this.appLang,
    required this.themeMode,
    required this.onChangeThemeMode,
    required this.onChangeLanguage,
  });

  @override
  State<BookshelfScreen> createState() => _BookshelfScreenState();
}

class _BookshelfScreenState extends State<BookshelfScreen> with TickerProviderStateMixin {
  static const MethodChannel _pdfChannel = MethodChannel('ebook_reader/pdf_renderer');

  List<File> _allBooks = [];
  // 상단 아이콘 움직임: 휴지통 뚜껑·정렬 막대·설정 톱니바퀴
  final GlobalKey _trashBtnKey = GlobalKey();
  bool _trashPanelOpen = false;
  bool _sortPanelOpen = false;
  double _gearTurns = 0;
  List<File> _trashedBooks = [];
  List<String> _groups = List<String>.of(StorageService.defaultGroups);

  // ── 파일 검색 (상단 돋보기) ──
  bool _searchOpen = false;
  String _searchQuery = '';
  final TextEditingController _searchCtrl = TextEditingController();
  final FocusNode _searchFocus = FocusNode();
  late final AnimationController _searchAnim =
      AnimationController(vsync: this, duration: Anim.ms(300), reverseDuration: Anim.ms(210));
  // 펼칠 때는 빠르게 나가다 천천히 멈추고, 돌아올 때도 빠르게 출발해 제자리에 부드럽게 내려앉음
  late final CurvedAnimation _searchCurve = CurvedAnimation(parent: _searchAnim, curve: Curves.easeOutCubic, reverseCurve: Curves.easeInCubic);

  void _openSearch() {
    if (_searchOpen) return;
    setState(() {
      _searchOpen = true;
      _searchQuery = '';
    });
    _searchCtrl.clear();
    _searchAnim.forward();
    // 줄이 다 그어질 즈음 자판을 올림
    Future<void>.delayed(const Duration(milliseconds: 180), () {
      if (mounted && _searchOpen) _searchFocus.requestFocus();
    });
  }

  /// 처음 상태로: 검색어도 지움 (뒤로 가기, 파일 열기, 다른 아이콘을 누를 때)
  void _closeSearch() {
    if (!_searchOpen) return;
    _searchFocus.unfocus();
    _searchCtrl.clear();
    setState(() {
      _searchOpen = false;
      _searchQuery = '';
    });
    _searchAnim.reverse();
  }

  static const TextStyle _searchTextStyle = TextStyle(fontSize: 18, fontWeight: FontWeight.w600);

  /// 돋보기가 왼쪽으로 조금 가면서 그 뒤로 짧은 밑줄이 그어지고, 글자를 칠수록 밑줄이 왼쪽으로 늘어남
  /// ("MY" 글자 가까이 오면 더 늘지 않음). 닫으면 다시 오른쪽 돋보기로 말려 들어감
  Widget _buildSearchArea() {
    final Color lineColor = Theme.of(context).colorScheme.onSurface;
    return LayoutBuilder(
      builder: (context, c) {
        final double w = c.maxWidth;
        const double iconSize = 24;
        final double home = w + 28; // 닫혀 있을 때 돋보기 자리 (PDF 합치기 아이콘 왼쪽)
        // 밑줄 길이 = 친 글자 폭 + 여유 (처음에는 짧게), 돋보기가 왼쪽 끝(MY 옆)에 닿으면 멈춤
        final tp = TextPainter(text: TextSpan(text: _searchQuery, style: _searchTextStyle), textDirection: TextDirection.ltr, maxLines: 1)
          ..layout();
        // 화면이 좁은 휴대폰에서는 자리가 110보다 좁을 수 있음 (clamp 아래값이 위값보다 크면 오류 → 회색 상자가 뜨고 검색이 안 되던 문제)
        final double lineLen = (tp.width + 64).clamp(math.min(110.0, home), home).toDouble();
        final double target = home - lineLen;
        return TweenAnimationBuilder<double>(
          tween: Tween<double>(end: target),
          duration: Anim.ms(160),
          curve: Curves.easeOut,
          builder: (context, openLeft, _) => AnimatedBuilder(
          animation: _searchCurve,
          builder: (context, _) {
            final double t = _searchCurve.value;
            if (_searchAnim.isDismissed) return const SizedBox(height: 40);
            // 돋보기 위치: 오른쪽(원래 돋보기 자리) → 글자 길이에 맞는 자리
            final double iconLeft = home + (openLeft - home) * t;
            final double textOpacity = ((t - 0.55) / 0.45).clamp(0.0, 1.0).toDouble();
            return SizedBox(
              height: 40,
              child: Stack(
                clipBehavior: Clip.none,
                children: [
                  // 밑줄: 돋보기가 지나간 자리부터 오른쪽 PDF 합치기 아이콘 바로 앞까지 (비워 둔 돋보기 자리까지 이어짐)
                  Positioned(
                    left: iconLeft + iconSize + 4,
                    right: -56,
                    bottom: 5,
                    child: Container(height: 2, decoration: BoxDecoration(color: lineColor, borderRadius: BorderRadius.circular(1))),
                  ),
                  Positioned(left: iconLeft, top: 8, child: Icon(Icons.search, size: iconSize, color: lineColor)),
                  Positioned(
                    left: iconLeft + iconSize + 8,
                    right: -56,
                    top: 0,
                    bottom: 10,
                    child: Opacity(
                      opacity: textOpacity,
                      child: TextField(
                        controller: _searchCtrl,
                        focusNode: _searchFocus,
                        textInputAction: TextInputAction.search,
                        style: _searchTextStyle,
                        // 깜빡이는 세로 막대가 밑줄에 닿지 않게 짧게
                        cursorHeight: 17,
                        decoration: const InputDecoration(border: InputBorder.none, isCollapsed: true, contentPadding: EdgeInsets.only(top: 6)),
                        // 한 글자 칠 때마다 결과가 바뀜
                        onChanged: (v) => setState(() => _searchQuery = v),
                        // 자판의 확인(검색)을 눌러도 검색 화면은 그대로 (자판만 내림)
                        onSubmitted: (_) => _searchFocus.unfocus(),
                      ),
                    ),
                  ),
                ],
              ),
            );
          },
          ),
        );
      },
    );
  }
  final GlobalKey _allGroupChipKey = GlobalKey();
  String _selectedGroup = '전체';
  Map<String, String> _bookGroupMap = {};
  Map<String, String> _bookPageLabelMap = {}; // 마지막으로 읽은 쪽 '지금/전체'
  Set<String> _favoritePaths = {};
  bool _hideFileExtension = false;
  bool _hideGroupName = false; // 파일 아래 [그룹 이름] 숨기기
  bool _hidePageCount = false; // 파일 아래 페이지 수 숨기기
  Map<String, int> _addedDates = {}; // 파일 추가 날짜 (밀리초)
  // 파일 정렬: 기준 'name'(이름) | 'date'(추가 날짜), 오름차순(이름 가→하 / 오래된 순)
  String _sortBy = 'name';
  bool _sortAsc = true;
  bool _sortRemember = true;
  bool _sortLoaded = false;

  /// 파일 정렬 창: 정렬 기준(이름 / 추가 날짜) · 순서 · 정렬 기억하기. 고르면 바로 적용
  final GlobalKey _sortBtnKey = GlobalKey();

  /// 정렬 창: 정렬 단추에서 튀어나와 바로 아래로 펼쳐짐 (그룹 목록과 같은 움직임)
  /// 이름을 고르면 그 아래 오름차순·내림차순, 파일 추가 날짜를 고르면 그 아래 최신순·오래된 순
  Future<void> _showSortSheet() async {
    Future<void> apply() async {
      setState(() => _allBooks = List<File>.of(_allBooks)..sort((a, b) => _libCompare(a, b, _favoritePaths)));
      await StorageService.setLibrarySort(_sortBy, _sortAsc, _sortRemember);
    }

    final box = _sortBtnKey.currentContext?.findRenderObject() as RenderBox?;
    if (box == null || !box.hasSize) return;
    final RenderObject? overlayBox = Navigator.of(context).overlay?.context.findRenderObject();
    final Rect anchor = box.localToGlobal(Offset.zero, ancestor: overlayBox) & box.size;
    setState(() => _sortPanelOpen = true);
    await Navigator.of(context).push<void>(PopPanelRoute<void>(
      anchor: anchor,
      width: 380,
      barrierLabel: MaterialLocalizations.of(context).modalBarrierDismissLabel,
      builder: (ctx) => StatefulBuilder(
        builder: (ctx, setSheet) {
          final cs = Theme.of(ctx).colorScheme;
          final bool byName = _sortBy == 'name';
          Widget byRow(String value, String text) => InkWell(
                borderRadius: BorderRadius.circular(10),
                onTap: () {
                  // 기준을 바꾸면 순서는 기본값으로: 이름은 오름차순, 추가 날짜는 최신순
                  setSheet(() {
                    if (_sortBy != value) _sortAsc = value == 'name';
                    _sortBy = value;
                  });
                  apply();
                },
                child: Padding(
                  padding: const EdgeInsets.symmetric(vertical: 12),
                  child: Row(
                    children: [
                      Expanded(child: Text(text, style: const TextStyle(fontSize: 17, fontWeight: FontWeight.w700))),
                      Icon(_sortBy == value ? Icons.check_circle : Icons.circle_outlined, size: 24, color: _sortBy == value ? AppColors.mark(ctx) : cs.outline),
                    ],
                  ),
                ),
              );
          // 고른 기준 바로 아래에만 순서 고르기가 펼쳐짐
          Widget orders(bool forName) => AnimatedSize(
                duration: Anim.ms(220),
                curve: Curves.easeOutCubic,
                alignment: Alignment.topCenter,
                child: byName != forName
                    ? const SizedBox(width: double.infinity, height: 0)
                    : Padding(
                        padding: const EdgeInsets.only(bottom: 10),
                        child: SettingGroup(children: [
                          SettingOption(
                            label: Text(forName ? _tr('오름차순', 'Ascending', '升序', '昇順') : _tr('최신순', 'Newest', '最新', '新しい順')),
                            selected: forName ? _sortAsc : !_sortAsc,
                            onSelected: (_) {
                              setSheet(() => _sortAsc = forName);
                              apply();
                            },
                          ),
                          SettingOption(
                            label: Text(forName ? _tr('내림차순', 'Descending', '降序', '降順') : _tr('오래된 순', 'Oldest', '最早', '古い順')),
                            selected: forName ? !_sortAsc : _sortAsc,
                            onSelected: (_) {
                              setSheet(() => _sortAsc = !forName);
                              apply();
                            },
                          ),
                        ]),
                      ),
              );
          return Padding(
            padding: const EdgeInsets.fromLTRB(20, 16, 20, 14),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Text(_tr('정렬', 'Sort', '排序', '並べ替え'), style: const TextStyle(fontSize: 21, fontWeight: FontWeight.w800)),
                const SizedBox(height: 10),
                byRow('name', _tr('이름', 'Name', '名称', '名前')),
                orders(true),
                Divider(height: 1, color: cs.outlineVariant.withValues(alpha: 0.5)),
                byRow('date', _tr('파일 추가 날짜', 'Date added', '添加日期', '追加日')),
                orders(false),
                const SizedBox(height: 4),
                SettingToggle(
                  label: Column(
                    mainAxisSize: MainAxisSize.min,
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(_tr('정렬 기억하기', 'Remember sort', '记住排序', '並べ替えを記憶')),
                      const SizedBox(height: 2),
                      Text(
                        _tr('다시 열어도 이 정렬을 유지해요', 'Keeps this order when you reopen the app', '重新打开后仍保持此排序', '再度開いてもこの並べ替えを保ちます'),
                        style: TextStyle(fontSize: 12, fontWeight: FontWeight.w400, color: cs.onSurfaceVariant),
                      ),
                    ],
                  ),
                  selected: _sortRemember,
                  onSelected: (v) {
                    setSheet(() => _sortRemember = v);
                    apply();
                  },
                ),
                // 초기화: 이름 오름차순, 정렬 기억하기 켜짐
                SettingDoneButton(
                  label: _tr('초기화', 'Reset', '重置', 'リセット'),
                  onPressed: () {
                    setSheet(() {
                      _sortBy = 'name';
                      _sortAsc = true;
                      _sortRemember = true;
                    });
                    apply();
                  },
                ),
              ],
            ),
          );
        },
      ),
    ));
    if (mounted) setState(() => _sortPanelOpen = false);
  }

  /// 북마크한 파일 먼저, 그다음 고른 정렬 (이름 / 추가 날짜)
  int _libCompare(File a, File b, Set<String> favs) {
    final aFav = favs.contains(a.path), bFav = favs.contains(b.path);
    if (aFav != bFav) return aFav ? -1 : 1;
    String nameOf(File f) => f.path.split(Platform.pathSeparator).last;
    int c;
    if (_sortBy == 'date') {
      c = (_addedDates[a.path] ?? 0).compareTo(_addedDates[b.path] ?? 0);
      if (c == 0) c = _naturalCompare(nameOf(a), nameOf(b));
    } else {
      c = _naturalCompare(nameOf(a), nameOf(b));
    }
    return _sortAsc ? c : -c;
  }

  /// 파일 아래 작은 글: [그룹] • 마지막으로 읽은 쪽(6/983)
  String _fileMetaText(String path, String grpDisplay, bool showGroup) {
    final parts = <String>[];
    if (showGroup) parts.add('[$grpDisplay]');
    if (!_hidePageCount) {
      final p = _pageLabelText(path);
      if (p.isNotEmpty) parts.add(p);
    }
    return parts.join('  •  ');
  }
  bool _hideThumbnails = false; // 표지형: 표지 그림 끄기 (아이콘만)
  Map<String, String> _customCovers = {}; // 사용자가 고른 표지
  String _bookshelfViewMode = 'list'; // 기본값: 'list' (목록형)
  static final Map<String, ImageProvider> _globalThumbMemoryCache = {};
  final Map<String, ValueNotifier<ImageProvider?>> _thumbNotifiers = {};
  final Set<String> _thumbnailGeneratingPaths = {};
  final Set<String> _noCoverPaths = {}; // 표지 그림이 없는 EPUB·CBZ (이번 실행 동안 다시 찾지 않음)

  bool _isSelectionMode = false;
  final Set<String> _selectedFilePaths = {};
  final ScrollController _bookshelfScrollController = ScrollController();
  final Map<String, GlobalKey> _fileRowKeys = {};
  bool _isDragSelecting = false;
  bool _dragTargetSelectState = true;
  String? _lastDragTouchedPath;
  final Map<int, Offset> _activeBookshelfPointers = {};
  Timer? _dragEdgeScrollTimer;
  Offset? _lastDragGlobalPos;

  // 메모장(.txt), 워드(.docx, .doc), 한글(.hwpx, .hwp), 파워포인트(.pptx, .ppt)도 열람 (모두 기기 안에서 처리)
  static const _supportedExts = [
    'epub', 'txt', 'pdf', 'jpg', 'jpeg', 'png', 'webp', 'cbz',
    'docx', 'doc', 'hwpx', 'hwp', 'pptx', 'ppt', 'xlsx', 'xlsm', 'xls',
  ];
  static const _imageExts = ['jpg', 'jpeg', 'png', 'webp'];

  /// 글 문서(리더 화면에서 여는 형식)
  static const _readerExts = ['epub', 'txt', 'docx', 'doc', 'hwpx', 'hwp', 'pptx', 'ppt', 'xlsx', 'xlsm', 'xls'];

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
    // 손가락이 화면 위/아래 가장자리에 머무는 동안 일정 속도로 부드럽게 자동 스크롤
    _lastDragGlobalPos = globalPos;
    _dragEdgeScrollTimer ??= Timer.periodic(const Duration(milliseconds: 16), (t) {
      final g = _lastDragGlobalPos;
      if (!mounted || !_isDragSelecting || g == null || !_bookshelfScrollController.hasClients) {
        t.cancel();
        _dragEdgeScrollTimer = null;
        return;
      }
      final screenH = MediaQuery.of(context).size.height;
      double step = 0.0;
      if (g.dy < 160) {
        step = -(2.0 + 18.0 * ((160 - g.dy) / 160).clamp(0.0, 1.0));
      } else if (g.dy > screenH - 120) {
        step = 2.0 + 18.0 * ((g.dy - (screenH - 120)) / 120).clamp(0.0, 1.0);
      }
      if (step == 0.0) return;
      final pos = _bookshelfScrollController.position;
      final double target = (pos.pixels + step).clamp(pos.minScrollExtent, pos.maxScrollExtent).toDouble();
      if (target != pos.pixels) {
        _bookshelfScrollController.jumpTo(target);
        final hitPath = _findFileRowPathAtGlobalPos(g);
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
      }
    });
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
    _loadLibrary();
    StorageService.listSwipeOff.addListener(_onListSwipeSetting);
  }

  void _onListSwipeSetting() {
    if (mounted) setState(() {});
  }

  ValueNotifier<ImageProvider?> _getThumbNotifier(String bookPath) {
    return _thumbNotifiers.putIfAbsent(
      bookPath,
      () => ValueNotifier<ImageProvider?>(_globalThumbMemoryCache[bookPath]),
    );
  }

  void _cacheThumbnailFromFileSync(String bookPath, String thumbPath, {bool isRawOriginalImage = false}) {
    if (_globalThumbMemoryCache.containsKey(bookPath)) {
      _getThumbNotifier(bookPath).value = _globalThumbMemoryCache[bookPath];
      return;
    }
    try {
      final f = File(thumbPath);
      if (!f.existsSync()) return;
      // 표지는 화면에 작게 보이므로 작은 크기로 풀어 둔다 (큰 그림을 통째로 풀면 목록·화면 전환이 버벅임).
      // 파일은 백그라운드에서 읽는다. 표지를 새로 만든 경우를 위해 예전 그림 캐시는 비운다.
      if (!isRawOriginalImage && f.lengthSync() < 64) return;
      final ImageProvider provider = ResizeImage(FileImage(f), width: isRawOriginalImage ? 360 : 420, allowUpscaling: false);
      provider.evict().catchError((_) => false);
      _globalThumbMemoryCache[bookPath] = provider;
      _getThumbNotifier(bookPath).value = provider;
      if (mounted) {
        precacheImage(provider, context).catchError((_) {});
      }
    } catch (_) {}
  }

  @override
  void dispose() {
    StorageService.listSwipeOff.removeListener(_onListSwipeSetting);
    _searchCurve.dispose();
    _searchAnim.dispose();
    _searchCtrl.dispose();
    _searchFocus.dispose();
    _dragEdgeScrollTimer?.cancel();
    for (final notifier in _thumbNotifiers.values) {
      notifier.dispose();
    }
    _bookshelfScrollController.dispose();
    super.dispose();
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
    // 폴더 목록 읽기는 따로(백그라운드)에서: 파일·표지가 많아도 화면 전환이 버벅이지 않게
    final listed = await _listLibraryFolders(dir.path, trashDir.path, '${dir.path}/.thumbnails');

    final entities = <FileSystemEntity>[for (final p in listed.files) File(p)];
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

    final trashEntities = <FileSystemEntity>[for (final p in listed.trash) File(p)];
    final trashed = <File>[];
    for (final e in trashEntities) {
      if (e is File) {
        trashed.add(e);
      }
    }

    final favs = await StorageService.getFavoriteBooks();
    final hideExt = await StorageService.getHideFileExtension();
    final hideGroup = await StorageService.getHideGroupName();
    final hideThumbs = await StorageService.getHideThumbnails();
    FavoriteRibbon.animationOff.value = await StorageService.getRibbonAnimationOff();
    await StorageService.loadListSwipeOff();
    final covers = await StorageService.getCustomCovers();
    final viewMode = await StorageService.getBookshelfViewMode();
    final hidePages = await StorageService.getHidePageCount();
    // 파일 추가 날짜: 처음 보는 파일은 지금 파일 시각으로 정해 저장 (이후 그대로)
    final dates = await StorageService.getAddedDates();
    bool datesChanged = false;
    for (final f in files) {
      if (dates.containsKey(f.path)) continue;
      int ms;
      try {
        ms = f.statSync().modified.millisecondsSinceEpoch;
      } catch (_) {
        ms = DateTime.now().millisecondsSinceEpoch;
      }
      dates[f.path] = ms;
      datesChanged = true;
    }
    if (datesChanged) await StorageService.setAddedDates(dates);
    _addedDates = dates;
    if (!_sortLoaded) {
      final (by, asc, remember) = await StorageService.getLibrarySort();
      _sortBy = by;
      _sortAsc = asc;
      _sortRemember = remember;
      _sortLoaded = true;
    }

    files.sort((a, b) => _libCompare(a, b, favs));

    trashed.sort((a, b) => _naturalCompare(
          a.path.split(Platform.pathSeparator).last,
          b.path.split(Platform.pathSeparator).last,
        ));

    final groups = await StorageService.getGroups();
    final grpMap = <String, String>{};
    final pageMap = <String, String>{};

    for (final f in files) {
      grpMap[f.path] = await StorageService.getBookGroup(f.path);
      final lbl = await StorageService.getPageLabel(f.path);
      if (lbl != null) pageMap[f.path] = lbl;
    }

    // 디스크에 이미 생성되어 있는 썸네일 바이트(MemoryImage)를 setState 전에 동기식으로 즉시 메모리에 고정하여 스크롤 시 재로딩 원천 차단
    final thumbDir = Directory('${dir.path}/.thumbnails');
    final Map<String, String> existingThumbBySafeKey = {};
    final Map<String, String> existingDocThumbBySafeKey = {}; // 한글·워드 표지 (흐린 옛 표지와 구분)
    final Map<String, String> existingSlideThumbBySafeKey = {}; // 슬라이드 표지 (흰 화면으로 찍힌 옛 표지와 구분)
    final Map<String, String> existingEpubThumbBySafeKey = {}; // EPUB 표지 (책에 적힌 표지만, 옛 '첫 그림' 표지와 구분)
    for (final entity in <FileSystemEntity>[for (final p in listed.thumbs) File(p)]) {
      if (entity is File) {
        final name = entity.path.split(Platform.pathSeparator).last;
        if (name.startsWith('thumb_v36_') && name.endsWith('.jpg')) {
          final k = name.substring('thumb_v36_'.length, name.length - 4);
          existingThumbBySafeKey[k] = entity.path;
        } else if (name.startsWith('thumb_d2_') && name.endsWith('.jpg')) {
          final k = name.substring('thumb_d2_'.length, name.length - 4);
          existingDocThumbBySafeKey[k] = entity.path;
        } else if (name.startsWith('thumb_s3_') && name.endsWith('.jpg')) {
          final k = name.substring('thumb_s3_'.length, name.length - 4);
          existingSlideThumbBySafeKey[k] = entity.path;
        } else if (name.startsWith('thumb_e1_') && name.endsWith('.jpg')) {
          final k = name.substring('thumb_e1_'.length, name.length - 4);
          existingEpubThumbBySafeKey[k] = entity.path;
        } else if (name.startsWith('thumb_hq26_') && name.endsWith('.jpg')) {
          final parts = name.split('_');
          if (parts.length >= 3) {
            existingThumbBySafeKey.putIfAbsent(parts[2], () => entity.path);
          }
        }
      }
    }

    for (final f in files) {
      final path = f.path;
      if (_globalThumbMemoryCache.containsKey(path)) {
        _getThumbNotifier(path).value = _globalThumbMemoryCache[path];
        continue;
      }
      final ext = path.split('.').last.toLowerCase();
      if (_imageExts.contains(ext)) {
        _cacheThumbnailFromFileSync(path, path, isRawOriginalImage: true);
        continue;
      }
      // 사용자가 고른 표지가 있으면 그것
      final custom = covers[path];
      if (custom != null && File(custom).existsSync()) {
        _cacheThumbnailFromFileSync(path, custom, isRawOriginalImage: true);
        continue;
      }
      final safeKey = path.hashCode.toUnsigned(32).toString();
      final existingThumbPath = (ext == 'pptx' || ext == 'ppt')
          ? existingSlideThumbBySafeKey[safeKey]
          : ext == 'epub'
              ? existingEpubThumbBySafeKey[safeKey]
              : DocThumbnailService.supportedExts.contains(ext)
              ? existingDocThumbBySafeKey[safeKey]
              : existingThumbBySafeKey[safeKey];
      if (existingThumbPath != null) {
        _cacheThumbnailFromFileSync(path, existingThumbPath);
        if (DocThumbnailService.supportedExts.contains(ext)) _noteDocThumbQuality(path, existingThumbPath);
      }
    }

    if (mounted) {
      setState(() {
        _allBooks = files;
        _trashedBooks = trashed;
        _groups = groups;
        _favoritePaths = favs;
        _hideFileExtension = hideExt;
        _hideGroupName = hideGroup;
        _hidePageCount = hidePages;
        _hideThumbnails = hideThumbs;
        _customCovers = covers;
        _bookshelfViewMode = viewMode;
        if (!_groups.contains(_selectedGroup)) {
          _selectedGroup = '전체';
        }
        _bookGroupMap = grpMap;
        _bookPageLabelMap = pageMap;
        _selectedFilePaths.removeWhere((p) => !_allBooks.any((f) => f.path == p));
        if (_selectedFilePaths.isEmpty) {
          _isSelectionMode = false;
        }
      });
      for (final f in files) {
        if (!_globalThumbMemoryCache.containsKey(f.path) || _wantsSharpDocThumb(f.path)) {
          _ensureBookThumbnail(f, thumbDir.path);
        }
      }
    }
  }

  /// 한글·워드 표지를 화면 밖에서 그리다 실패한 파일 (앱을 다시 켤 때까지 다시 시도하지 않음)
  static final Set<String> _docThumbFailed = {};

  /// 파일 안의 작은 미리보기 그림으로 임시 표지를 쓴 한글·워드 (표지형 보기에서 첫 페이지를 다시 그림)
  static final Set<String> _docThumbLowRes = {};

  void _noteDocThumbQuality(String bookPath, String thumbPath) {
    if (File('$thumbPath.low').existsSync()) {
      _docThumbLowRes.add(bookPath);
    } else {
      _docThumbLowRes.remove(bookPath);
    }
  }

  bool _wantsSharpDocThumb(String bookPath) =>
      _bookshelfViewMode == 'grid' && _docThumbLowRes.contains(bookPath) && !_docThumbFailed.contains(bookPath);

  /// 13. 각 파일의 가장 첫 페이지를 초고속 네이티브 스레드 풀에서 썸네일 이미지로 생성 및 MemoryImage로 영구 고정
  Future<void> _ensureBookThumbnail(File file, [String? cachedThumbDirPath]) async {
    final path = file.path;
    if (_globalThumbMemoryCache.containsKey(path) && !_wantsSharpDocThumb(path)) return;
    if (_thumbnailGeneratingPaths.contains(path)) return;
    _thumbnailGeneratingPaths.add(path);

    try {
      final custom = _customCovers[path];
      if (custom != null && File(custom).existsSync()) {
        _cacheThumbnailFromFileSync(path, custom, isRawOriginalImage: true);
        return;
      }
      final ext = path.split('.').last.toLowerCase();
      if (_imageExts.contains(ext)) {
        _cacheThumbnailFromFileSync(path, path, isRawOriginalImage: true);
        return;
      }

      final String thumbDirPath = cachedThumbDirPath ??
          '${(await getApplicationDocumentsDirectory()).path}/.thumbnails';
      final safeKey = path.hashCode.toUnsigned(32).toString();
      final bool isDocType = DocThumbnailService.supportedExts.contains(ext);
      final bool isSlideType = ext == 'pptx' || ext == 'ppt';
      // 슬라이드 표지는 예전에 흰 화면으로 찍힌 것이 남아 있을 수 있어 새 이름(s3)으로 다시 만든다
      final thumbPath = isSlideType
          ? '$thumbDirPath/thumb_s3_$safeKey.jpg'
          : isDocType
              ? '$thumbDirPath/thumb_d2_$safeKey.jpg'
              : ext == 'epub'
                  ? '$thumbDirPath/thumb_e1_$safeKey.jpg'
                  : '$thumbDirPath/thumb_v36_$safeKey.jpg';
      final thumbFile = File(thumbPath);

      if (thumbFile.existsSync() && thumbFile.lengthSync() > 64) {
        _cacheThumbnailFromFileSync(path, thumbPath);
        // 작은 미리보기로 임시 표지를 쓴 한글·워드는 표지형 보기에서 첫 페이지를 다시 선명하게 그린다
        if (isDocType) _noteDocThumbQuality(path, thumbPath);
        if (!isDocType || !_wantsSharpDocThumb(path)) return;
      }
      if (isDocType) {
        // 예전 버전이 만든 (흐릴 수 있는) 표지는 지운다
        for (final old in [
          File('$thumbDirPath/thumb_v36_$safeKey.jpg'),
          if (isSlideType) File('$thumbDirPath/thumb_d2_$safeKey.jpg'),
          if (isSlideType) File('$thumbDirPath/thumb_d2_$safeKey.jpg.low'),
        ]) {
          if (old.existsSync()) {
            try {
              old.deleteSync();
            } catch (_) {}
          }
        }
      }

      if (ext == 'pdf') {
        final rendered = await _pdfChannel.invokeMethod<String>(
          'renderPdfFirstPageThumbnail',
          {
            'filePath': path,
            'outPath': thumbPath,
            'maxWidth': 420,
          },
        );
        if (rendered != null) {
          _cacheThumbnailFromFileSync(path, rendered);
          return;
        }
      } else if (DocThumbnailService.supportedExts.contains(ext)) {
        // 한글·워드: 파일 안의 미리보기 그림 → 없으면 (표지형 보기일 때만) 첫 페이지를 화면 밖에서 그림
        if (_docThumbFailed.contains(path)) return;
        final bool allowRender = _bookshelfViewMode == 'grid';
        final ok = await DocThumbnailService.make(path, thumbPath, allowRender: allowRender);
        if (ok) {
          _globalThumbMemoryCache.remove(path); // 임시(흐린) 표지를 새 표지로 바꾼다
          _cacheThumbnailFromFileSync(path, thumbPath);
          _noteDocThumbQuality(path, thumbPath);
          return;
        }
        if (allowRender) _docThumbFailed.add(path);
      } else if (ext == 'cbz' || ext == 'epub') {
        if (_noCoverPaths.contains(path)) return;
        if (ext == 'epub') {
          // 예전에 '첫 그림'으로 만든 표지는 지움 (표지가 아닐 수 있음)
          final old = File('$thumbDirPath/thumb_v36_$safeKey.jpg');
          if (old.existsSync()) {
            try {
              old.deleteSync();
            } catch (_) {}
          }
        }
        final rendered = await _pdfChannel.invokeMethod<String>(
          'extractArchiveFirstImageThumbnail',
          {
            'filePath': path,
            'outPath': thumbPath,
            'maxWidth': 420,
          },
        );
        if (rendered != null) {
          _cacheThumbnailFromFileSync(path, rendered);
          return;
        }
        _noCoverPaths.add(path); // 표지 없음: 파일 아이콘으로 보여 주고 다시 찾지 않음
      }
    } catch (_) {
    } finally {
      _thumbnailGeneratingPaths.remove(path);
    }
  }

  /// 파일 고르기: 고른 파일을 앱으로 가져오는 동안(파일이 많으면 오래 걸림) 안내 창을 띄운다
  Future<FilePickerResult?> _pickFilesWithNotice({
    FileType type = FileType.any,
    bool allowMultiple = false,
    List<String>? allowedExtensions,
  }) async {
    bool shown = false;
    void hide() {
      if (!shown || !mounted) return;
      shown = false;
      Navigator.of(context, rootNavigator: true).pop();
    }

    try {
      return await FilePicker.platform.pickFiles(
        type: type,
        allowMultiple: allowMultiple,
        allowedExtensions: allowedExtensions,
        onFileLoading: (status) {
          if (status == FilePickerStatus.picking && !shown && mounted) {
            shown = true;
            showPopDialog<void>(
              context: context,
              barrierDismissible: false,
              useRootNavigator: true,
              builder: (ctx) => PopScope(
                canPop: false,
                child: AlertDialog(
                  // 위아래 여백을 똑같이 → 문구가 네모칸 한가운데에
                  contentPadding: const EdgeInsets.symmetric(horizontal: 24, vertical: 22),
                  content: Row(
                    mainAxisSize: MainAxisSize.min,
                    mainAxisAlignment: MainAxisAlignment.center,
                    crossAxisAlignment: CrossAxisAlignment.center,
                    children: [
                      const SizedBox(width: 22, height: 22, child: CircularProgressIndicator(strokeWidth: 2.5)),
                      const SizedBox(width: 18),
                      Flexible(
                        child: Text(
                          _tr(
                            '파일을 불러오는 중...\n시간이 조금 걸릴 수 있어요',
                            'Loading files...\nThis may take a moment',
                            '正在读取文件...\n可能需要一点时间',
                            'ファイルを読み込み中...\n少し時間がかかることがあります',
                          ),
                          style: const TextStyle(fontSize: 14, height: 1.4, leadingDistribution: TextLeadingDistribution.even),
                          textHeightBehavior: const TextHeightBehavior(applyHeightToFirstAscent: false, applyHeightToLastDescent: false),
                        ),
                      ),
                    ],
                  ),
                ),
              ),
            );
          } else if (status == FilePickerStatus.done) {
            hide();
          }
        },
      );
    } finally {
      hide();
    }
  }

  Future<void> _pickAndImportFiles() async {
    final result = await _pickFilesWithNotice(
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
                '지원되는 파일 형식(EPUB, PDF, JPG, PNG, CBZ)을 선택해 주세요',
                'Please select supported files (EPUB, PDF, JPG, PNG, CBZ)',
                '请选择受支持的文件格式 (EPUB, PDF, JPG, PNG, CBZ)',
                '対応ファイル形式(EPUB, PDF, JPG, PNG, CBZ)を選択してください',
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
      final action = await showPopDialog<String>(
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
              icon: const Icon(Icons.picture_as_pdf, size: 16),
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
      final action = await showPopDialog<String>(
        context: context,
        builder: (ctx) => AlertDialog(
          title: Text(_tr('이미지 추가 방식 선택', 'Image Import Option', '选择图片导入方式', '画像の追加方法を選択')),
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
              icon: const Icon(Icons.auto_stories, size: 16),
              onPressed: () => Navigator.pop(ctx, 'merge'),
              label: Text(_tr('이미지 합치기', 'Merge Images', '合并图片', '画像結合')),
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
              '${importedFiles.length}개의 파일이 서재에 추가되었습니다',
              'Added ${importedFiles.length} file(s) to bookshelf',
              '已添加 ${importedFiles.length} 个文件到书架',
              '${importedFiles.length}個のファイルが追加されました',
            ),
          ),
        ),
      );
    }
  }

  /// 형식 그룹의 파일 찾기: 기기 저장소에서 그 형식 파일을 모두 찾아 이 그룹에 넣음 (권한이 없으면 먼저 허용 받기)
  bool _groupScanBusy = false;
  Future<void> _scanFilesIntoGroup(String group, String ext) async {
    if (_groupScanBusy) return;
    const extsOf = {
      'pdf': ['pdf'],
      'epub': ['epub'],
      'txt': ['txt'],
      'docx': ['docx', 'doc'],
      'hwp': ['hwp', 'hwpx'],
      'pptx': ['pptx', 'ppt'],
      'xlsx': ['xlsx', 'xlsm', 'xls'],
      'cbz': ['cbz'],
      'jpg': ['jpg', 'jpeg', 'png', 'webp'],
    };
    final exts = extsOf[ext] ?? [ext];
    bool allowed = await _pdfChannel.invokeMethod<bool>('fontScanAllowed').catchError((_) => false) ?? false;
    if (!allowed) {
      if (!mounted) return;
      final go = await showPopDialog<bool>(
        context: context,
        builder: (ctx) => AlertDialog(
          title: Text(_tr('파일 접근 허용', 'Allow file access', '允许访问文件', 'ファイルへのアクセスを許可')),
          content: Text(_tr(
            '기기에 저장된 파일을 찾으려면 파일 접근 권한이 필요해요\n다음 화면에서 FReader를 허용해 주세요',
            'To find files on this device, FReader needs file access\nPlease allow it on the next screen',
            '要查找设备中的文件，需要文件访问权限\n请在下一个页面允许 FReader',
            '端末内のファイルを探すにはファイルへのアクセス権限が必要です\n次の画面で FReader を許可してください',
          )),
          actions: [
            TextButton(onPressed: () => Navigator.pop(ctx, false), child: Text(_tr('취소', 'Cancel', '取消', 'キャンセル'))),
            ElevatedButton(onPressed: () => Navigator.pop(ctx, true), child: Text(_tr('허용하러 가기', 'Allow', '去允许', '許可する'))),
          ],
        ),
      );
      if (go != true || !mounted) return;
      // 허용 화면에서 돌아올 때까지 기다림
      final back = Completer<void>();
      final listener = AppLifecycleListener(onResume: () {
        if (!back.isCompleted) back.complete();
      });
      await _pdfChannel.invokeMethod('requestFontScan').catchError((_) => null);
      await back.future.timeout(const Duration(minutes: 3), onTimeout: () {});
      listener.dispose();
      allowed = await _pdfChannel.invokeMethod<bool>('fontScanAllowed').catchError((_) => false) ?? false;
      if (!mounted) return;
      if (!allowed) {
        ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(_tr('파일 접근이 허용되지 않아 찾지 못했어요', 'File access was not allowed', '未允许文件访问，无法查找', 'ファイルへのアクセスが許可されていません'))));
        return;
      }
    }
    setState(() => _groupScanBusy = true);
    try {
      final groupLabel = _localizeGroupName(group);
      // 찾는 중 알림: 다른 알림이 앞에 쌓여 있으면 늦게 떠서 끝난 뒤에도 남았었음 → 앞 알림을 모두 치우고 띄운 뒤, 끝나면 이 알림만 닫음
      final messenger = ScaffoldMessenger.of(context);
      messenger.clearSnackBars();
      final searching = messenger.showSnackBar(SnackBar(
        duration: const Duration(seconds: 10),
        content: Row(children: [
          // 어두운 알림 바탕에서도 보이게 밝은 색
          SizedBox(width: 18, height: 18, child: CircularProgressIndicator(strokeWidth: 2.4, color: Theme.of(context).colorScheme.onInverseSurface)),
          const SizedBox(width: 14),
          Expanded(child: Text(_tr('기기에서 파일을 찾는 중이에요…', 'Searching for files…', '正在查找文件…', 'ファイルを探しています…'))),
        ]),
      ));
      // 너무 오래 걸리면 (기기 파일이 아주 많을 때) 10초에서 멈춤
      List<String> paths;
      try {
        paths = await _pdfChannel.invokeListMethod<String>('scanDocFiles', {'exts': exts}).timeout(const Duration(seconds: 10)) ?? const <String>[];
      } on TimeoutException {
        searching.close();
        if (mounted) {
          messenger.showSnackBar(SnackBar(content: Text(_tr('찾는 데 너무 오래 걸려 멈췄어요', 'Search took too long and was stopped', '查找时间过长，已停止', '時間がかかりすぎたため中止しました'))));
        }
        return;
      }
      searching.close();
      final appDir = await getApplicationDocumentsDirectory();
      // 서재에 이미 있는 같은 형식 파일 (이름 기준) → 복사하지 않고 이 그룹으로만 옮김
      final library = <String, File>{for (final f in _allBooks) f.path.split('/').last: f};
      final seen = <String>{};
      final newFiles = <String>[];
      final inLibrary = <File>[];
      for (final p in paths) {
        if (p.startsWith(appDir.path)) continue;
        final name = p.split('/').last;
        if (!seen.add(name)) continue;
        final have = library[name];
        if (have != null) {
          if (await StorageService.getBookGroup(have.path) != group) inLibrary.add(have);
        } else {
          newFiles.add(p);
        }
      }
      for (final f in _allBooks) {
        final name = f.path.split('/').last;
        final e = name.contains('.') ? name.split('.').last.toLowerCase() : '';
        if (exts.contains(e) && seen.add(name) && await StorageService.getBookGroup(f.path) != group) inLibrary.add(f);
      }
      if (!mounted) return;
      if (newFiles.isEmpty && inLibrary.isEmpty) {
        ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(_tr('새로 넣을 파일을 찾지 못했어요', 'No new files found', '没有找到新的文件', '新しいファイルは見つかりませんでした'))));
        return;
      }
      final n = newFiles.length + inLibrary.length;
      final ok = await showPopDialog<bool>(
        context: context,
        builder: (ctx) => AlertDialog(
          title: Text(_tr('파일 $n개를 찾았어요', 'Found $n file(s)', '找到 $n 个文件', 'ファイルが$n個見つかりました')),
          content: Text([
            _tr("'$groupLabel' 그룹에 모두 넣을까요?", "Put them all in '$groupLabel'?", "全部放入“$groupLabel”分组吗？", "「$groupLabel」グループにすべて入れますか？"),
            if (inLibrary.isNotEmpty)
              _tr('(서재에 있던 파일 ${inLibrary.length}개는 그룹만 옮겨요)', '(${inLibrary.length} file(s) already in the library will just be moved)', '（书架中已有的 ${inLibrary.length} 个文件只移动分组）', '（ライブラリにある${inLibrary.length}個はグループだけ移します）'),
          ].join('\n')),
          actions: [
            TextButton(onPressed: () => Navigator.pop(ctx, false), child: Text(_tr('취소', 'Cancel', '取消', 'キャンセル'))),
            ElevatedButton(onPressed: () => Navigator.pop(ctx, true), child: Text(_tr('넣기', 'Add', '放入', '入れる'))),
          ],
        ),
      );
      if (ok != true || !mounted) return;
      int added = 0;
      for (final f in inLibrary) {
        await StorageService.setBookGroup(f.path, group);
        added++;
      }
      for (final p in newFiles) {
        try {
          final saved = await File(p).copy('${appDir.path}/${p.split('/').last}');
          await StorageService.setBookGroup(saved.path, group);
          added++;
        } catch (_) {}
      }
      await _loadLibrary();
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(_tr("'$groupLabel' 그룹에 파일 $added개를 넣었어요", "Put $added file(s) in '$groupLabel'", "已将 $added 个文件放入“$groupLabel”", "「$groupLabel」に$added個のファイルを入れました"))));
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).clearSnackBars();
        ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(_tr('파일을 찾지 못했어요 ($e)', 'Could not search files ($e)', '无法查找文件 ($e)', 'ファイルを探せませんでした ($e)'))));
      }
    } finally {
      if (mounted) setState(() => _groupScanBusy = false);
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

    final confirmed = await showPopDialog<bool>(
      context: context,
      builder: (ctx) => StatefulBuilder(
        builder: (ctx, setModalState) => AlertDialog(
          title: Text(_tr('이미지 합치기', 'Merge Images', '合并图片', '画像結合')),
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
                  title: Text(_tr('파일을 선택한 순서대로 합치기', 'Keep Selected Order', '按选择顺序合并', '選択した順番通りに結合'), style: const TextStyle(fontSize: 13)),
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
              child: Text(_tr('확인', 'OK', '确定', 'OK')),
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

    showPopDialog(
      context: context,
      barrierDismissible: false,
      builder: (ctx) => StatefulBuilder(
        builder: (ctx, setDialogState) {
          progressSetState = setDialogState;
          final double ratio = totalSteps > 0 ? (currentStep / totalSteps).clamp(0.0, 1.0).toDouble() : 0.0;
          return AlertDialog(
            title: Text(_tr('이미지 합치는 중', 'Merging Images', '正在合并图片', '画像結合中')),
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
        progressStatus = fileName;
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
      final grpDisplay = _localizeGroupName(targetGroup);
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(
            _tr(
              'cbz 파일이 [$grpDisplay]에 생성되었습니다\n($safeTitle.cbz)',
              'cbz file created in [$grpDisplay]\n($safeTitle.cbz)',
              'cbz 文件已创建于 [$grpDisplay]\n($safeTitle.cbz)',
              'cbzファイルが [$grpDisplay] に作成されました\n($safeTitle.cbz)',
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
      final result = await _pickFilesWithNotice(
        type: FileType.image,
        allowMultiple: true,
      );
      if (result != null && result.files.length >= 2) {
        final files = result.files.where((f) => f.path != null).map((f) => File(f.path!)).toList();
        await _createMangaBookFromImages(files, deleteSourceAfter: false);
      } else if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text(_tr('JPG/PNG 파일을 2개 이상 선택해 주세요', 'Please select at least 2 JPG/PNG files', '请选择至少 2 个 JPG/PNG 文件', 'JPG/PNGファイルを2つ以上選択してください'))),
        );
      }
      return;
    }

    final result = await showPopDialog<Object?>(
      context: context,
      builder: (ctx) => _FileMergeSelectDialog(
        files: existingImages,
        tr: _tr,
        displayName: (f) => _formatDisplayFileName(f.path.split(Platform.pathSeparator).last),
        title: _tr('이미지 합치기', 'Merge Images', '合并图片', '画像結合'),
        mergeLabel: _tr('선택한 이미지 합치기', 'Merge Selected', '合并所选图片', '選択した画像を結合'),
      ),
    );

    if (result == 'browse') {
      final picked = await _pickFilesWithNotice(
        type: FileType.image,
        allowMultiple: true,
      );
      if (picked != null && picked.files.length >= 2) {
        final files = picked.files.where((f) => f.path != null).map((f) => File(f.path!)).toList();
        await _createMangaBookFromImages(files, deleteSourceAfter: false);
      } else if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text(_tr('JPG/PNG 파일을 2개 이상 선택해 주세요', 'Please select at least 2 JPG/PNG files', '请选择至少 2 个 JPG/PNG 文件', 'JPG/PNGファイルを2つ以上選択してください'))),
        );
      }
      return;
    }

    if (result is List<String> && result.length >= 2) {
      final fileByPath = {for (final f in existingImages) f.path: f};
      final chosen = result.map((p) => fileByPath[p]!).toList();
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
    bool sortByName = true;

    final confirmed = await showPopDialog<bool>(
      context: context,
      builder: (ctx) => StatefulBuilder(
        builder: (ctx, setModalState) => AlertDialog(
          title: Text(_tr('PDF 합치기', 'Merge PDFs', '合并 PDF', 'PDF結合')),
          content: SingleChildScrollView(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                TextField(
                  controller: titleController,
                  decoration: InputDecoration(
                    labelText: _tr('PDF 파일 이름', 'PDF Filename', 'PDF 文件名称', 'PDFファイル名'),
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
                  title: Text(_tr('파일 이름 순서대로 합치기', 'Sort by Filename', '按文件名顺序合并', 'ファイル名順に結合'), style: const TextStyle(fontSize: 13)),
                  value: true,
                  groupValue: sortByName,
                  onChanged: (v) => setModalState(() => sortByName = v ?? true),
                ),
                RadioListTile<bool>(
                  dense: true,
                  contentPadding: EdgeInsets.zero,
                  title: Text(_tr('파일을 선택한 순서대로 합치기', 'Keep Selected Order', '按选择顺序合并', '選択した順番通りに結合'), style: const TextStyle(fontSize: 13)),
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
                      _tr('기존 PDF 파일 휴지통으로 이동', 'Move original PDFs to Trash', '将原 PDF 移至回收站', '元のPDFをゴミ箱へ移動'),
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
              child: Text(_tr('확인', 'OK', '确定', 'OK')),
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

    int currentStep = 0;
    final int totalSteps = orderedPdfs.length;
    String progressStatus = _tr('PDF 합칠 준비 중...', 'Preparing PDFs...', '正在准备 PDF...', 'PDFを準備中...');
    StateSetter? progressSetState;

    _pdfChannel.setMethodCallHandler((call) async {
      if (call.method == 'onPdfMergeProgress') {
        final args = call.arguments as Map?;
        if (args != null) {
          final int cur = (args['current'] as num?)?.toInt() ?? 1;
          final String fName = (args['fileName'] ?? '').toString();
          progressSetState?.call(() {
            currentStep = cur;
            progressStatus = fName;
          });
        }
      }
      return null;
    });

    showPopDialog(
      context: context,
      barrierDismissible: false,
      builder: (ctx) => StatefulBuilder(
        builder: (ctx, setDialogState) {
          progressSetState = setDialogState;
          final double ratio = totalSteps > 0 ? (currentStep / totalSteps).clamp(0.0, 1.0).toDouble() : 0.0;
          return AlertDialog(
            title: Text(_tr('PDF 합치는 중', 'Merging PDFs', '正在合并 PDF', 'PDF結合中')),
            content: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                LinearProgressIndicator(value: currentStep > 0 ? ratio : null),
                const SizedBox(height: 12),
                Text(
                  '${(ratio * 100).toStringAsFixed(0)}% ($currentStep / ${orderedPdfs.length})',
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
        final grpDisplay = _localizeGroupName(targetGroup);
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text(
              _tr(
                'PDF 파일이 [$grpDisplay]에 생성되었습니다\n($safeTitle.pdf)',
                'PDF file created in [$grpDisplay]\n($safeTitle.pdf)',
                'PDF 文件已创建于 [$grpDisplay]\n($safeTitle.pdf)',
                'PDFファイルが [$grpDisplay] に作成されました\n($safeTitle.pdf)',
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
    } finally {
      _pdfChannel.setMethodCallHandler(null);
    }
  }

  Future<void> _showMergeExistingPdfsDialog() async {
    final existingPdfs = _allBooks.where((f) {
      final ext = f.path.split('.').last.toLowerCase();
      return ext == 'pdf';
    }).toList();

    if (existingPdfs.isEmpty) {
      final result = await _pickFilesWithNotice(
        type: FileType.custom,
        allowedExtensions: ['pdf'],
        allowMultiple: true,
      );
      if (result != null && result.files.length >= 2) {
        final files = result.files.where((f) => f.path != null).map((f) => File(f.path!)).toList();
        await _createMergedPdfFromFiles(files, deleteSourceAfter: false);
      } else if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text(_tr('PDF 파일을 2개 이상 선택해 주세요', 'Please select at least 2 PDF files', '请选择至少 2 个 PDF 文件', 'PDFファイルを2つ以上選択してください'))),
        );
      }
      return;
    }

    final result = await showPopDialog<Object?>(
      context: context,
      builder: (ctx) => _FileMergeSelectDialog(
        files: existingPdfs,
        tr: _tr,
        displayName: (f) => _formatDisplayFileName(f.path.split(Platform.pathSeparator).last),
        title: _tr('PDF 합치기', 'Merge PDFs', '合并 PDF', 'PDF結合'),
        mergeLabel: _tr('선택한 PDF 합치기', 'Merge Selected PDFs', '合并所选 PDF', '選択したPDFを結合'),
      ),
    );

    if (result == 'browse') {
      final picked = await _pickFilesWithNotice(
        type: FileType.custom,
        allowedExtensions: ['pdf'],
        allowMultiple: true,
      );
      if (picked != null && picked.files.length >= 2) {
        final files = picked.files.where((f) => f.path != null).map((f) => File(f.path!)).toList();
        await _createMergedPdfFromFiles(files, deleteSourceAfter: false);
      } else if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text(_tr('PDF 파일을 2개 이상 선택해 주세요', 'Please select at least 2 PDF files', '请选择至少 2 个 PDF 文件', 'PDFファイルを2つ以上選択してください'))),
        );
      }
      return;
    }

    if (result is List<String> && result.length >= 2) {
      final fileByPath = {for (final f in existingPdfs) f.path: f};
      final chosen = result.map((p) => fileByPath[p]!).toList();
      await _createMergedPdfFromFiles(chosen, deleteSourceAfter: true);
    }
  }

  Future<void> _renameFileDialog(File file) async {
    final fullName = file.path.split(Platform.pathSeparator).last;
    final dotIdx = fullName.lastIndexOf('.');
    final baseName = dotIdx > 0 ? fullName.substring(0, dotIdx) : fullName;
    final ext = dotIdx > 0 ? fullName.substring(dotIdx + 1) : '';

    final ctrl = TextEditingController(text: baseName);

    final confirmed = await showPopDialog<bool>(
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
          SnackBar(content: Text(_tr('같은 이름의 파일이 이미 존재합니다', 'A file with that name already exists', '同名文件已存在', '同じ名前のファイルが既に存在します'))),
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
    _closeSearch(); // 파일을 열면 검색은 처음 상태로
    final rawName = file.path.split(Platform.pathSeparator).last;
    final displayName = _formatDisplayFileName(rawName);
    final ext = rawName.split('.').last.toLowerCase();

    if (_readerExts.contains(ext)) {
      await Navigator.push(
        context,
        MaterialPageRoute(
          builder: (_) => ReaderScreen(filePath: file.path, bookTitle: displayName),
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

    // 파일 화면이 닫히는 움직임이 끝난 뒤에 목록을 새로 읽음 (닫히는 도중에 목록을 다시 그리면 버벅임)
    await Future<void>.delayed(const Duration(milliseconds: 360));
    if (mounted) _loadLibrary();
  }

  /// 설정 창에서 켜고 끌 때: 스위치가 움직이는 동안은 뒤의 파일 목록을 다시 그리지 않고, 끝난 뒤에 한 번
  Timer? _toggleTimer;
  final List<VoidCallback> _toggleQueue = [];
  void _afterToggle(VoidCallback change) {
    _toggleQueue.add(change);
    _toggleTimer?.cancel();
    _toggleTimer = Timer(const Duration(milliseconds: 260), () {
      if (!mounted) return;
      final pending = List.of(_toggleQueue);
      _toggleQueue.clear();
      setState(() {
        for (final c in pending) {
          c();
        }
      });
    });
  }

  Future<String?> _createNewGroupDialog() async {
    final controller = TextEditingController();
    String? created;
    await showPopDialog(
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
                created = text;
                if (ctx.mounted) Navigator.pop(ctx);
                await _loadLibrary();
              }
            },
            child: Text(_tr('추가', 'Add', '添加', '追加')),
          ),
        ],
      ),
    );
    return created;
  }

  /// 그룹 막대: [전체](고정) + 순서를 바꿀 수 있는 그룹들 + 새 그룹 추가
  /// - 그룹을 꾹 누르면 편집 상태(우상단 빨간 - 버튼)가 되고, 그대로 끌어 순서를 바꿀 수 있다
  /// - 편집 상태에서는 바로 끌어 순서를 바꾸고, - 를 누르면 그룹 삭제
  bool _favoritesOnly = false; // 즐겨찾기만 보는 중

  bool _fabOpen = false; // 파일 추가 버튼을 눌러 세 가지 메뉴가 펼쳐진 상태

  /// 파일 추가 버튼: 누르면 위로 [파일 추가 / PDF 병합 / 이미지 병합] 세 버튼이 펼쳐짐
  Widget _buildAddFab() {
    final cs = Theme.of(context).colorScheme;
    Widget action(String tag, IconData icon, String label, VoidCallback onTap) => Padding(
          padding: const EdgeInsets.only(bottom: 10),
          child: FloatingActionButton.extended(
            heroTag: tag,
            elevation: 2,
            backgroundColor: cs.surfaceContainerHighest,
            foregroundColor: cs.onSurface,
            onPressed: () {
              setState(() => _fabOpen = false);
              _closeSearch();
              onTap();
            },
            icon: Icon(icon),
            label: Text(label, style: const TextStyle(fontWeight: FontWeight.w600)),
          ),
        );
    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.end,
      children: [
        // 펼칠 때: 겹쳐 숨어 있던 버튼이 맨 아래 것부터 하나씩 차례로 빠져나옴
        // 접을 때: 거꾸로, 맨 위 버튼부터 바로 아래 버튼 뒤로 겹쳐 들어감 (마지막은 파일 추가 버튼 뒤로)
        TweenAnimationBuilder<double>(
          tween: Tween<double>(end: _fabOpen ? 1.0 : 0.0),
          duration: Anim.ms(_fabOpen ? 460 : 340),
          builder: (context, t, _) {
            if (t <= 0.001) return const SizedBox.shrink();
            // 위에서 아래 순서
            final items = <Widget>[
              // 그룹 이동 아이콘(폴더)에서 화살표 대신 +
              action('fab_add_plain', Icons.create_new_folder_outlined, _tr('파일 추가', 'Add Files', '添加文件', 'ファイル追加'), _pickAndImportFiles),
              action('fab_merge_pdf', Icons.picture_as_pdf_outlined, _tr('PDF 합치기', 'Merge PDFs', '合并 PDF', 'PDF結合'), _showMergeExistingPdfsDialog),
              action('fab_merge_img', Icons.photo_library_outlined, _tr('이미지 합치기', 'Merge Images', '合并图片', '画像結合'), _showMergeExistingImagesDialog),
            ];
            const double rowH = 66; // 버튼 높이 56 + 사이 10
            final int n = items.length;
            final offsets = List<double>.filled(n, 0);
            final shown = List<double>.filled(n, 0);
            double below = 0; // 바로 아래 버튼이 아직 덜 올라온 만큼 (그 뒤에 붙어 함께 움직임)
            for (int k = 0; k < n; k++) {
              final int i = n - 1 - k; // 아래에서 k번째
              final double raw = ((t - k * 0.22) / 0.56).clamp(0.0, 1.0);
              final double p = (_fabOpen ? Curves.easeOutBack : Curves.easeOutCubic).transform(raw);
              below += rowH * (1 - p);
              offsets[i] = below;
              shown[i] = raw;
            }
            return IgnorePointer(
              ignoring: !_fabOpen,
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.end,
                children: [
                  // 아래 버튼이 위 버튼보다 나중에 그려져 위 버튼이 그 뒤에 숨음
                  for (int i = 0; i < n; i++)
                    Transform.translate(
                      offset: Offset(0, offsets[i]),
                      child: Opacity(opacity: (shown[i] * 3).clamp(0.0, 1.0), child: items[i]),
                    ),
                ],
              ),
            );
          },
        ),
        FloatingActionButton.extended(
          heroTag: 'fab_add_files',
          onPressed: () {
            _closeSearch();
            setState(() => _fabOpen = !_fabOpen);
          },
          // 아이콘 움직임: [전체] 그룹 아이콘과 같은 빠르기·느낌 (기본 움직임)
          icon: PlusCloseIcon(open: _fabOpen, size: 24),
          label: Text(_fabOpen ? _tr('닫기', 'Close', '关闭', '閉じる') : _tr('파일 추가', 'Add Files', '添加文件', 'ファイル追加'),
              style: TextStyle(fontWeight: FontWeight.w800, shadows: AppColors.sigShadows(context))),
        ),
      ],
    );
  }

  /// 그룹 이름이 파일 형식 이름이면 그 형식(아이콘용 확장자), 아니면 null
  static String? _groupFormatExt(String name) {
    final n = name.trim().toLowerCase().replaceAll(RegExp(r'^\.'), '');
    const map = {
      'pdf': 'pdf',
      'epub': 'epub', '이펍': 'epub', '전자책': 'epub',
      'txt': 'txt', '텍스트': 'txt', '메모장': 'txt',
      'doc': 'docx', 'docx': 'docx', 'word': 'docx', '워드': 'docx',
      'hwp': 'hwp', 'hwpx': 'hwp', '한글': 'hwp', '한글 문서': 'hwp', '한글문서': 'hwp',
      'ppt': 'pptx', 'pptx': 'pptx', 'powerpoint': 'pptx', '파워포인트': 'pptx', 'ppt 문서': 'pptx',
      'xls': 'xlsx', 'xlsx': 'xlsx', 'xlsm': 'xlsx', 'excel': 'xlsx', '엑셀': 'xlsx',
      'cbz': 'cbz', '만화': 'cbz', 'comic': 'cbz', 'comics': 'cbz',
      'jpg': 'jpg', 'jpeg': 'jpg', 'png': 'jpg', 'webp': 'jpg', '이미지': 'jpg', '사진': 'jpg', 'image': 'jpg', 'images': 'jpg',
    };
    return map[n];
  }

  /// [그룹] 단추 하나 (예전 [전체] 단추와 같은 크기·아이콘): 누르면 아이콘이 펼쳐지며 바로 아래로 그룹 목록
  Widget _buildGroupBar() {
    final cs = Theme.of(context).colorScheme;
    // 고른 그룹의 아이콘과 이름 (전체도 아이콘 + '전체')
    final String label = _favoritesOnly ? _tr('즐겨찾기', 'Favorites', '收藏', 'お気に入り') : _localizeGroupName(_selectedGroup);
    final String? ext = _favoritesOnly || _selectedGroup == '전체' ? null : _groupFormatExt(_selectedGroup);
    final Widget groupIcon = _favoritesOnly
        ? const FavoritesIcon(size: 18)
        : _selectedGroup == '전체'
            ? const FolderDocsIcon(size: 20)
            : ext == null
                ? GroupFolderIcon(size: 18, color: cs.onSecondaryContainer)
                : FileTypeIcon(ext: ext, size: 18);
    return Align(
      alignment: Alignment.centerLeft,
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
        child: Row(mainAxisSize: MainAxisSize.min, children: [
          ChoiceChip(
            key: _allGroupChipKey,
            // 시그니쳐 색 칸 안에서도 아이콘 안쪽은 바탕(흰색)으로
            avatar: IconInnerFill(color: cs.surface, child: groupIcon),
            showCheckmark: false,
            // 아이콘과 글자 사이는 좁게, 글자 오른쪽 여백은 아이콘 왼쪽 여백과 같게 (칸 가운데에 오도록)
            labelPadding: const EdgeInsets.only(left: 4, right: 2),
            label: ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: 220),
              child: Text(label, maxLines: 1, overflow: TextOverflow.ellipsis, style: TextStyle(shadows: AppColors.sigShadows(context))),
            ),
            selected: true,
            onSelected: (_) {
              if (_searchOpen) {
                _closeSearch();
                return;
              }
              if (_fabOpen) setState(() => _fabOpen = false);
              _showGroupJumpMenu();
            },
          ),
          // 형식 그룹(PDF·워드 등): 기기에서 그 형식 파일을 찾아 이 그룹에 넣기
          if (ext != null)
            IconButton(
              // 상단바 아이콘과 같은 크기·색
              icon: _groupScanBusy
                  ? SizedBox.square(dimension: 18, child: CircularProgressIndicator(strokeWidth: 2.2, color: cs.onSurfaceVariant))
                  : FolderSearchIcon(size: 21, color: cs.onSurfaceVariant),
              tooltip: _tr('파일 탐색', 'Find Files', '查找文件', 'ファイル検索'),
              onPressed: _groupScanBusy ? null : () => _scanFilesIntoGroup(_selectedGroup, ext),
            ),
        ]),
      ),
    );
  }

  /// 파일의 점 3개 메뉴: 이름 변경 / 그룹 이동 (표지형은 휴지통 이동도)
  Future<void> _showFileMenu(BuildContext anchor, File file, {bool withTrash = false}) async {
    final action = await showScaleMenu<String>(anchor, [
      ('rename', _tr('이름 변경', 'Rename', '重命名', '名前変更'), Icons.edit_outlined, null),
      ('move_group', _tr('그룹 이동', 'Move Group', '移动分组', 'グループ移動'), Icons.drive_file_move_outline, null),
      if (_bookshelfViewMode == 'grid') ('cover', _tr('표지 변경', 'Change Cover', '更换封面', '表紙を変更'), Icons.image_outlined, null),
      if (_bookshelfViewMode == 'grid' && _customCovers.containsKey(file.path))
        ('cover_reset', _tr('원래 표지로', 'Original Cover', '恢复原封面', '元の表紙に戻す'), Icons.restore, null),
      if (withTrash) ('trash', _tr('휴지통 이동', 'Move to Trash', '移至回收站', 'ゴミ箱へ移動'), Icons.delete_outline, Colors.redAccent),
    ], compact: true);
    if (!mounted || action == null) return;
    if (action == 'rename') {
      _renameFileDialog(file);
    } else if (action == 'move_group') {
      _assignGroupDialog(file);
    } else if (action == 'trash') {
      _moveFileToTrash(file);
    } else if (action == 'cover') {
      _changeCover(file);
    } else if (action == 'cover_reset') {
      _resetCover(file);
    }
  }

  /// 표지 변경: 갖고 있는 그림을 골라 이 파일의 표지로 씀 (앱 안에 복사해 둠)
  Future<void> _changeCover(File file) async {
    final result = await _pickFilesWithNotice(type: FileType.image, allowMultiple: false);
    final picked = result?.files.firstOrNull?.path;
    if (picked == null || !mounted) return;
    try {
      final dir = Directory('${(await getApplicationDocumentsDirectory()).path}/.covers');
      await dir.create(recursive: true);
      final ext = picked.split('.').last.toLowerCase();
      final out = File('${dir.path}/${DateTime.now().millisecondsSinceEpoch}.${ext.length <= 4 ? ext : 'jpg'}');
      await File(picked).copy(out.path);
      final old = _customCovers[file.path];
      await StorageService.setCustomCover(file.path, out.path);
      if (old != null) {
        try {
          await File(old).delete();
        } catch (_) {}
      }
      _customCovers = await StorageService.getCustomCovers();
      _globalThumbMemoryCache.remove(file.path);
      _cacheThumbnailFromFileSync(file.path, out.path, isRawOriginalImage: true);
      if (mounted) setState(() {});
    } catch (_) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text(_tr('표지를 바꾸지 못했습니다', 'Could not change the cover', '无法更换封面', '表紙を変更できませんでした'))),
      );
    }
  }

  /// 원래 표지로: 고른 표지를 지우고 파일에서 만든 표지를 다시 씀
  Future<void> _resetCover(File file) async {
    final old = _customCovers[file.path];
    await StorageService.setCustomCover(file.path, null);
    if (old != null) {
      try {
        await File(old).delete();
      } catch (_) {}
    }
    _customCovers = await StorageService.getCustomCovers();
    _globalThumbMemoryCache.remove(file.path);
    _getThumbNotifier(file.path).value = null;
    if (mounted) setState(() {});
    _ensureBookThumbnail(file);
  }

  /// [☰ 그룹] 단추를 눌렀을 때: 바로 아래로 그룹 목록 (고르기·끌어 순서 바꾸기·꾹 눌러 이름 수정/삭제·추가)
  Future<void> _showGroupJumpMenu() async {
    final box = _allGroupChipKey.currentContext?.findRenderObject() as RenderBox?;
    if (box == null || !box.hasSize) return;
    // 앱 전체를 크게 보는 태블릿에서도 단추 바로 아래에 오도록 (메뉴가 놓이는 화면 기준 좌표)
    final RenderObject? overlayBox = Navigator.of(context).overlay?.context.findRenderObject();
    final Offset topLeft = box.localToGlobal(Offset.zero, ancestor: overlayBox);
    final Rect anchor = topLeft & box.size;
    final picked = await Navigator.of(context).push<String>(
      GroupDropdownRoute(
        anchor: anchor,
        barrierLabel: MaterialLocalizations.of(context).modalBarrierDismissLabel,
        groups: _groups.where((g) => g != '전체').toList(),
        selected: _favoritesOnly ? kFavoritesGroupKey : _selectedGroup,
        labelOf: _localizeGroupName,
        leadingOf: (g) {
          final ext = _groupFormatExt(g);
          return ext == null ? GroupFolderIcon(size: 20, color: Theme.of(context).colorScheme.onSurfaceVariant) : FileTypeIcon(ext: ext, size: 20);
        },
        allLeading: const FolderDocsIcon(size: 20),
        allLabel: _localizeGroupName('전체'),
        favLabel: _tr('즐겨찾기', 'Favorites', '收藏', 'お気に入り'),
        addLabel: _tr('그룹 추가', 'Add Group', '添加分组', 'グループ追加'),
        renameLabel: _tr('이름 수정', 'Rename', '重命名', '名前を変更'),
        deleteLabel: _tr('그룹 삭제', 'Delete Group', '删除分组', 'グループ削除'),
        onReorder: (order) {
          setState(() => _groups = ['전체', ...order]);
          StorageService.setGroupOrder(order);
        },
        onRename: _renameGroupDialog,
        onDelete: _confirmDeleteGroup,
        onAdd: _createNewGroupDialog,
      ),
    );
    if (!mounted) return;
    setState(() {
      if (picked == null) return;
      _closeSearch();
      if (picked == kFavoritesGroupKey) {
        _favoritesOnly = true;
      } else {
        _favoritesOnly = false;
        _selectedGroup = picked;
      }
    });
  }

  /// 그룹 이름 수정 (새 이름을 돌려줌, 취소하면 null)
  Future<String?> _renameGroupDialog(String group) async {
    final controller = TextEditingController(text: group);
    final name = await showPopDialog<String>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text(_tr('이름 수정', 'Rename Group', '重命名分组', 'グループ名を変更'), style: const TextStyle(fontWeight: FontWeight.w800)),
        content: TextField(
          controller: controller,
          autofocus: true,
          decoration: InputDecoration(
            hintText: _tr('그룹 이름 입력', 'Enter group name', '输入分组名称', 'グループ名を入力'),
            border: const OutlineInputBorder(),
          ),
          onSubmitted: (v) => Navigator.pop(ctx, v.trim()),
        ),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx), child: Text(_tr('취소', 'Cancel', '取消', 'キャンセル'))),
          ElevatedButton(
            onPressed: () => Navigator.pop(ctx, controller.text.trim()),
            child: Text(_tr('저장', 'Save', '保存', '保存')),
          ),
        ],
      ),
    );
    if (name == null || name.isEmpty || name == group || !mounted) return null;
    if (name == '전체' || name == '미분류' || _groups.contains(name)) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text(_tr('같은 이름의 그룹이 있어요', 'A group with that name already exists', '已有同名分组', '同じ名前のグループがあります'))),
      );
      return null;
    }
    final ok = await StorageService.renameGroup(group, name);
    if (!ok) return null;
    if (_selectedGroup == group) _selectedGroup = name;
    await _loadLibrary();
    return name;
  }

  Future<bool> _confirmDeleteGroup(String groupName) async {
    if (groupName == '전체') {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text(_tr('"전체" 기본 보기는 삭제할 수 없습니다', '"All" group cannot be deleted', '无法删除“全部”默认分组', '「すべて」は削除できません'))),
      );
      return false;
    }

    final confirmed = await showPopDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text(_tr('"$groupName" 그룹 삭제', 'Delete "$groupName"', '删除 "$groupName"', '「$groupName」グループ削除')),
        content: Text(
          _tr(
            '"$groupName" 그룹을 삭제할까요?\n그룹 안의 파일은 지워지지 않고 미분류로 옮겨져 [전체]에서 볼 수 있어요',
            'Delete group "$groupName"?\nFiles inside are kept, moved to Uncategorized and shown in [All]',
            '确定删除 "$groupName" 分组吗？\n组内文件不会删除，将移至未分类，可在[全部]中查看',
            '「$groupName」を削除しますか？\n中のファイルは削除されず、未分類に移り[すべて]で見られます',
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
      return true;
    }
    return false;
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
      sheetAnimationStyle: Anim.off.value ? AnimationStyle.noAnimation : null,
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
                  style: const TextStyle(fontWeight: FontWeight.w800),
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

    final confirmed = await showPopDialog<bool>(
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
    // 정렬 창처럼 휴지통 단추 아래에서 커져 나옴 (닫으면 단추로 들어감)
    final box = _trashBtnKey.currentContext?.findRenderObject() as RenderBox?;
    if (box == null || !box.hasSize) return;
    final RenderObject? overlayBox = Navigator.of(context).overlay?.context.findRenderObject();
    final Rect anchor = box.localToGlobal(Offset.zero, ancestor: overlayBox) & box.size;
    final double panelH = MediaQuery.of(context).size.height * 0.6;
    setState(() => _trashPanelOpen = true);
    await Navigator.of(context).push<void>(PopPanelRoute<void>(
      anchor: anchor,
      width: 400,
      barrierLabel: MaterialLocalizations.of(context).modalBarrierDismissLabel,
      builder: (ctx) => StatefulBuilder(
        builder: (ctx, setModalState) => SizedBox(
            height: panelH,
            child: Column(
              children: [
                ListTile(
                  leading: const Icon(Icons.delete_outline),
                  title: Text(
                    '${_tr("휴지통", "Trash", "回收站", "ゴミ箱")} (${_trashedBooks.length})',
                    style: const TextStyle(fontWeight: FontWeight.w800),
                  ),
                  trailing: _trashedBooks.isNotEmpty
                      ? TextButton.icon(
                          icon: const Icon(Icons.delete_forever, color: Colors.redAccent, size: 16),
                          label: Text(_tr('휴지통 비우기', 'Empty Trash', '清空回收站', 'ゴミ箱を空にする'), style: const TextStyle(color: Colors.redAccent)),
                          onPressed: () async {
                            final confirmEmpty = await showPopDialog<bool>(
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
                      ? Center(child: Text(_tr('휴지통이 비어 있습니다', 'Trash is empty', '回收站为空', 'ゴミ箱は空です')))
                      : ListView.separated(
                          itemCount: _trashedBooks.length,
                          separatorBuilder: (_, __) => const Divider(height: 1),
                          itemBuilder: (_, idx) {
                            final tf = _trashedBooks[idx];
                            final fileName = tf.path.split(Platform.pathSeparator).last;
                            final trashExt = fileName.contains('.') ? fileName.split('.').last.toLowerCase() : '';
                            return ListTile(
                              // 파일 이름 앞: 그 파일 형식 아이콘
                              leading: FileTypeIcon(ext: trashExt, size: 24),
                              title: Text(_formatDisplayFileName(fileName), maxLines: 1, overflow: TextOverflow.ellipsis),
                              trailing: Row(
                                mainAxisSize: MainAxisSize.min,
                                children: [
                                  TextButton.icon(
                                    icon: const Icon(Icons.restore_from_trash, size: 16),
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
                                      final confirmDelete = await showPopDialog<bool>(
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
    if (mounted) setState(() => _trashPanelOpen = false);
  }

  Future<void> _assignGroupDialog(File file) async {
    final candidateGroups = [
      ..._groups.where((g) => g != '전체'),
      if (!_groups.contains('미분류')) '미분류',
    ];
    await showModalBottomSheet(
      sheetAnimationStyle: Anim.off.value ? AnimationStyle.noAnimation : null,
      context: context,
      builder: (ctx) => SafeArea(
        child: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              ListTile(
                title: Text(_tr('파일 그룹 이동', 'Move to Group', '移动分组', 'グループ移動'), style: const TextStyle(fontWeight: FontWeight.w800)),
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

  /// 우측 상단 톱니바퀴 '앱 설정' 화면 (항목을 누르면 아래에서 고르기 창이 올라옴)
  /// 화면 전체 높이의 창으로 띄워서, 맨 위에서 아래로 끌면 내려가며 닫힌다.
  Future<void> _showGlobalSettingsDialog() async {
    if (!mounted) return;
    setState(() => _gearTurns += 0.5);
    try {
      await _showGlobalSettingsDialogInner();
    } finally {
      if (mounted) setState(() => _gearTurns -= 0.5);
    }
  }

  Future<void> _showGlobalSettingsDialogInner() async {
    final sheetCtrl = BottomSheet.createAnimationController(this);
    await showModalBottomSheet(
      sheetAnimationStyle: Anim.off.value ? AnimationStyle.noAnimation : null,
      context: context,
      isScrollControlled: true,
      useSafeArea: true,
      enableDrag: false,
      clipBehavior: Clip.antiAlias,
      // 화면의 2/3까지만 가림
      constraints: BoxConstraints(maxHeight: MediaQuery.of(context).size.height * 2 / 3),
      transitionAnimationController: sheetCtrl,
      builder: (sheetCtx) => SheetPullToClose(
        controller: sheetCtrl,
        builder: (ctx, scroll, physics) => AppSettingsScreen(
          asSheet: true,
          scrollController: scroll,
          scrollPhysics: physics,
          appLang: widget.appLang,
          themeMode: widget.themeMode,
          onChangeThemeMode: widget.onChangeThemeMode,
          viewMode: _bookshelfViewMode,
          hideExtension: _hideFileExtension,
          hideGroupName: _hideGroupName,
          hideThumbnails: _hideThumbnails,
          onChangeHideThumbnails: (hide) async {
            await StorageService.setHideThumbnails(hide);
            _afterToggle(() => _hideThumbnails = hide);
          },
          onChangeHideGroupName: (hide) async {
            await StorageService.setHideGroupName(hide);
            _afterToggle(() => _hideGroupName = hide);
          },
          hidePageCount: _hidePageCount,
          onChangeHidePageCount: (hide) async {
            await StorageService.setHidePageCount(hide);
            _afterToggle(() => _hidePageCount = hide);
          },
          onChangeLanguage: widget.onChangeLanguage,
          onChangeViewMode: (mode) async {
            await StorageService.setBookshelfViewMode(mode);
            _afterToggle(() => _bookshelfViewMode = mode);
            // 표지형으로 바꾸면 아직 표지가 없는 한글·워드 문서의 첫 페이지를 만든다
            if (mode == 'grid') {
              for (final f in _allBooks) {
                if (!_globalThumbMemoryCache.containsKey(f.path) || _wantsSharpDocThumb(f.path)) _ensureBookThumbnail(f);
              }
            }
          },
          onChangeHideExtension: (hide) async {
            await StorageService.setHideFileExtension(hide);
            _afterToggle(() => _hideFileExtension = hide);
          },
          onOpenManual: (lang) => Navigator.push(
            context,
            MaterialPageRoute(builder: (_) => UserManualScreen(appLang: lang)),
          ),
        ),
      ),
    );
    disposeSheetControllerWhenDone(sheetCtrl);
  }

  /// 즐겨찾기 켜기/끄기: 책갈피가 먼저 움직이고, 잠시 뒤 즐겨찾기 순서로 목록을 다시 정렬한다
  // 즐겨찾기로 자리가 바뀔 때: 가운데로 작아지며 사라졌다가, 새 자리에서 가운데부터 커지며 나타남
  final Set<String> _favShrinking = {};
  final Map<String, DateTime> _favGrowAt = {};

  Future<void> _toggleFavorite(File file) async {
    final path = file.path;
    setState(() {
      _favoritePaths = Set<String>.of(_favoritePaths);
      if (!_favoritePaths.remove(path)) _favoritePaths.add(path);
    });
    await StorageService.toggleFavoriteBook(path);
    // 지금 보이는 목록에서 자리가 그대로면 (예: 맨 위 파일을 즐겨찾기) 줄어들었다 커지는 움직임 없이 책갈피만 바꿈
    if (!_favoriteMovesFile(path)) {
      if (!mounted) return;
      await _loadLibrary();
      return;
    }
    // 책갈피가 움직이는 모습을 잠깐 보여 준 뒤
    await Future<void>.delayed(const Duration(milliseconds: 160));
    if (!mounted) return;
    setState(() => _favShrinking.add(path));
    await Future<void>.delayed(const Duration(milliseconds: 170));
    if (!mounted) return;
    await _loadLibrary();
    if (!mounted) return;
    setState(() {
      _favShrinking.remove(path);
      _favGrowAt[path] = DateTime.now();
    });
  }

  /// 목록형에서 오른쪽으로 밀어 즐겨찾기: 밀려 나간 줄은 바로 빠지고(같은 화면에서),
  /// 즐겨찾기 순서대로 다시 줄 세운 새 자리에 오른쪽에서 밀려 들어옴
  void _favoriteBySwipe(File file) {
    final path = file.path;
    final favs = Set<String>.of(_favoritePaths);
    if (!favs.remove(path)) favs.add(path);
    setState(() {
      _favoritePaths = favs;
      _allBooks = List<File>.of(_allBooks)
        ..sort((a, b) => _libCompare(a, b, favs));
      _favGrowAt[path] = DateTime.now();
    });
    unawaited(() async {
      await StorageService.toggleFavoriteBook(path);
      if (mounted) await _loadLibrary();
    }());
  }

  /// 즐겨찾기를 바꾼 뒤 지금 보이는 목록(그룹)에서 이 파일의 자리가 바뀌는가 (즐겨찾기 먼저, 그다음 이름 순)
  bool _favoriteMovesFile(String path) {
    if (_searchOpen) return false; // 검색 결과는 이름 순서라 자리가 바뀌지 않음
    final visible = _selectedGroup == '전체'
        ? List<File>.of(_allBooks)
        : _allBooks.where((f) => (_bookGroupMap[f.path] ?? '미분류') == _selectedGroup).toList();
    final before = visible.indexWhere((f) => f.path == path);
    if (before < 0) return false;
    final after = List<File>.of(visible)
      ..sort((a, b) => _libCompare(a, b, _favoritePaths));
    return after.indexWhere((f) => f.path == path) != before;
  }

  Widget _favPop(String path, Widget child, {bool slide = false}) =>
      _FavoritePop(shrinking: _favShrinking.contains(path), growAt: _favGrowAt[path], slide: slide, child: child);

  /// 파일 목록에 보여 줄 마지막으로 읽은 쪽 (예: (6/983)), 연 적 없으면 빈 문자열
  String _pageLabelText(String path) {
    final lbl = _bookPageLabelMap[path];
    return lbl == null ? '' : '($lbl)';
  }

  /// 1, 3, 10, 11, 13. 표지형(썸네일) 그리드 카드:
  /// - 고화질 첫 페이지 썸네일 (FilterQuality.high)
  /// - 휴대폰 한 화면에 9개(3×3) 들어가는 크기
  /// - 왼쪽 위 즐겨찾기 책갈피, 하단 점 3개(이름 변경 / 그룹 이동 / 휴지통 이동)
  /// - 진행바 및 진행률(%) 제거 (#11)
  /// - 그룹 이름은 [전체] 탭에서만 표시하고 개별 그룹 탭에서는 숨김 (#10), 그 오른쪽(또는 그 자리)에 마지막으로 읽은 쪽 (지금/전체)
  Widget _buildGridBookCard(File file) {
    final rowKey = _fileRowKeys.putIfAbsent(file.path, () => GlobalKey());
    final rawFileName = file.path.split(Platform.pathSeparator).last;
    final displayFileName = _formatDisplayFileName(rawFileName);
    final grp = _bookGroupMap[file.path] ?? '미분류';
    final grpDisplay = _localizeGroupName(grp);
    final bool showGroupLabel = _selectedGroup == '전체' && !_hideGroupName;
    final isSelected = _selectedFilePaths.contains(file.path);
    final isFavorite = _favoritePaths.contains(file.path);
    final lowerExt = rawFileName.split('.').last.toLowerCase();
    final thumbNotifier = _getThumbNotifier(file.path);


    return RepaintBoundary(
      child: Container(
        key: rowKey,
        child: GestureDetector(
          onLongPress: () {
            if (_activeBookshelfPointers.length >= 2) return;
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
            if (_activeBookshelfPointers.length >= 2) return;
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
                // 상단: 고화질 파일 첫 페이지 썸네일 영역 + 왼쪽 위 즐겨찾기 책갈피
                Expanded(
                  child: Stack(
                    fit: StackFit.expand,
                    children: [
                      Container(
                        color: widget.isDarkMode ? const Color(0xFF1E293B) : const Color(0xFFF1F5F9),
                        child: ValueListenableBuilder<ImageProvider?>(
                          valueListenable: thumbNotifier,
                          builder: (context, thumbProvider, _) {
                            // 표지 그림 끄기: 사용자가 고른 표지가 아니면 아이콘만
                            if (thumbProvider != null && (!_hideThumbnails || _customCovers.containsKey(file.path))) {
                              final bool slides = (lowerExt == 'pptx' || lowerExt == 'ppt') && !_customCovers.containsKey(file.path);
                              return Image(
                                image: thumbProvider,
                                // 슬라이드(가로)는 잘리지 않게 전체를 보여 준다
                                fit: slides ? BoxFit.contain : BoxFit.cover,
                                alignment: slides ? Alignment.center : Alignment.topCenter,
                                gaplessPlayback: true,
                                filterQuality: FilterQuality.low,
                                errorBuilder: (_, __, ___) => Center(
                                  child: FileTypeIcon(ext: lowerExt, size: 34),
                                ),
                              );
                            }
                            return Center(
                              child: Column(
                                mainAxisSize: MainAxisSize.min,
                                children: [
                                  FileTypeIcon(ext: lowerExt, size: 32),
                                  const SizedBox(height: 4),
                                  Container(
                                    padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
                                    decoration: BoxDecoration(
                                      color: const Color(0xFF7CB342).withValues(alpha: 0.16),
                                      borderRadius: BorderRadius.circular(5),
                                    ),
                                    child: Text(
                                      lowerExt.toUpperCase(),
                                      style: const TextStyle(
                                        fontSize: 10,
                                        fontWeight: FontWeight.bold,
                                        color: Color(0xFF4E7A1E),
                                      ),
                                    ),
                                  ),
                                ],
                              ),
                            );
                          },
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
                      // 왼쪽 위 끝에 걸친 즐겨찾기 책갈피
                      if (!_isSelectionMode)
                        Positioned(
                          top: 0,
                          left: 4, // 둥근 모서리를 피해 살짝 안쪽
                          child: FavoriteRibbon(
                            active: isFavorite,
                            onImage: true,
                            width: 18,
                            height: 27,
                            extraHitArea: 22, // 표지를 누르려다 파일이 열리지 않도록 누르는 범위를 넓게
                            onTap: () => _toggleFavorite(file),
                          ),
                        ),
                    ],
                  ),
                ),
                // 하단: 파일 제목 + 점 3개(이름 변경/그룹 이동) 아이콘 + ([전체] 탭일 때만 그룹 이름 표시)
                Container(
                  padding: const EdgeInsets.fromLTRB(7, 4, 2, 5),
                  color: widget.isDarkMode ? const Color(0xFF0F172A) : Colors.white,
                  // 그룹 이름·쪽 표시가 없으면 이름 줄을 칸 가운데에 (높이는 그대로, 생기면 다시 위로)
                  child: Builder(builder: (_) {
                    final meta = _fileMetaText(file.path, grpDisplay, showGroupLabel);
                    final Widget nameRow =
                      Row(
                        children: [
                          // 파일 이름 앞 형식 아이콘
                          FileTypeIcon(ext: lowerExt, size: 15),
                          const SizedBox(width: 3),
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
                              // 세로 점 3개: 그룹 목록처럼 아이콘에서 커져 나오는 메뉴
                              child: Builder(
                                builder: (btnCtx) => IconButton(
                                  padding: EdgeInsets.zero,
                                  iconSize: 17,
                                  icon: const Icon(Icons.more_vert, size: 15),
                                  tooltip: _tr('메뉴', 'More', '更多', 'メニュー'),
                                  onPressed: () => _showFileMenu(btnCtx, file, withTrash: true),
                                ),
                              ),
                            ),
                        ],
                      );
                    final Widget column = Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        nameRow,
                        const SizedBox(height: 1),
                        Text(
                          // 그룹 이름 오른쪽에 마지막으로 읽은 쪽 (특정 그룹 탭에서는 쪽만)
                          meta.isEmpty ? ' ' : meta,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: TextStyle(
                            fontSize: 10,
                            color: widget.isDarkMode ? Colors.white60 : Colors.black54,
                          ),
                        ),
                      ],
                    );
                    if (meta.isNotEmpty) return column;
                    return Stack(
                      children: [
                        IgnorePointer(child: ExcludeSemantics(child: Opacity(opacity: 0, child: column))),
                        Positioned.fill(child: Align(alignment: Alignment.centerLeft, child: nameRow)),
                      ],
                    );
                  }),
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
    final String query = _searchQuery.trim().toLowerCase();
    String nameOf(File f) => f.path.split(Platform.pathSeparator).last;
    final List<File> filteredBooks = _searchOpen
        // 검색 중: 검색어가 없으면 파일을 보여 주지 않고, 있으면 이름에 들어간 파일을 이름 순서대로 (모든 그룹에서)
        ? (query.isEmpty
            ? <File>[]
            : (_allBooks.where((f) => nameOf(f).toLowerCase().contains(query)).toList()
              ..sort((a, b) => _naturalCompare(nameOf(a).toLowerCase(), nameOf(b).toLowerCase()))))
        : _favoritesOnly
            ? _allBooks.where((f) => _favoritePaths.contains(f.path)).toList()
            : _selectedGroup == '전체'
            ? _allBooks
            : _allBooks.where((f) => (_bookGroupMap[f.path] ?? '미분류') == _selectedGroup).toList();

    return PopScope(
      canPop: !_isSelectionMode && !_searchOpen && !_favoritesOnly,
      onPopInvokedWithResult: (didPop, _) {
        if (!didPop && _searchOpen) {
          _closeSearch();
          return;
        }
        if (!didPop && _favoritesOnly && !_isSelectionMode) {
          setState(() => _favoritesOnly = false);
          return;
        }
        if (!didPop && _isSelectionMode) {
          setState(() {
            _isSelectionMode = false;
            _selectedFilePaths.clear();
            _isDragSelecting = false;
          });
        }
      },
      child: Scaffold(
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
              title: Row(
                children: [
                  const Text('MY', style: TextStyle(fontWeight: FontWeight.w800)),
                  const SizedBox(width: 20),
                  Expanded(child: _buildSearchArea()),
                ],
              ),
              actions: [
                // 파일 검색: 누르면 이 돋보기가 검색 밑줄로 바뀜 (검색 중에는 자리만 남김)
                // 움직이는 돋보기와 겹쳐 잔상이 보이지 않게: 펼쳐지는 동안에는 바로 숨기고, 다 돌아온 순간에만 다시 보임
                // (누를 때 퍼지는 물결도 남지 않게 없앰)
                IgnorePointer(
                  ignoring: _searchOpen,
                  child: AnimatedBuilder(
                    animation: _searchAnim,
                    builder: (context, child) => Opacity(opacity: !_searchOpen && _searchAnim.isDismissed ? 1 : 0, child: child),
                    child: IconButton(
                      icon: const Icon(Icons.search),
                      tooltip: _tr('파일 검색', 'Search Files', '搜索文件', 'ファイル検索'),
                      style: IconButton.styleFrom(splashFactory: NoSplash.splashFactory, highlightColor: Colors.transparent),
                      onPressed: _openSearch,
                    ),
                  ),
                ),
                IconButton(
                  icon: Badge(
                    isLabelVisible: _trashedBooks.isNotEmpty,
                    label: Text('${_trashedBooks.length}'),
                    // 휴지통 창이 열려 있는 동안 뚜껑이 열림
                    child: TrashLidIcon(open: _trashPanelOpen),
                  ),
                  key: _trashBtnKey,
                  tooltip: _tr('휴지통', 'Trash', '回收站', 'ゴミ箱'),
                  onPressed: () {
                    _closeSearch();
                    _showTrashBinDialog();
                  },
                ),
                IconButton(
                  key: _sortBtnKey,
                  // 정렬 창을 열고 닫을 때 막대가 위아래로 자리를 바꿈
                  icon: SortBarsIcon(flipped: _sortPanelOpen),
                  tooltip: _tr('정렬', 'Sort', '排序', '並べ替え'),
                  onPressed: () {
                    _closeSearch();
                    _showSortSheet();
                  },
                ),
                IconButton(
                  // 앱 설정을 열고 닫을 때 톱니바퀴가 돌아감
                  icon: SpinGearIcon(turns: _gearTurns),
                  tooltip: _tr('앱 설정', 'App Settings', '应用设置', 'アプリ設定'),
                  onPressed: () {
                    _closeSearch();
                    _showGlobalSettingsDialog();
                  },
                ),
              ],
            ),
      body: SafeArea(
        child: Column(
          children: [
            SizedBox(
              height: 54,
              child: _buildGroupBar(),
            ),
            const Divider(height: 1),
            Expanded(
              // 검색 중 빈 곳(파일이 아닌 곳)을 누르면 검색을 닫음 (파일을 누르면 파일이 먼저 받음)
              child: GestureDetector(
                behavior: (_searchOpen || _fabOpen) ? HitTestBehavior.opaque : HitTestBehavior.deferToChild,
                onTap: _searchOpen ? _closeSearch : (_fabOpen ? () => setState(() => _fabOpen = false) : null),
                child: filteredBooks.isEmpty && _searchOpen
                  // 검색 중: 검색어가 없으면 아무것도, 찾은 파일이 없으면 짧게 알림
                  ? (query.isEmpty
                      // 가로 폭 전체를 차지해야 빈 곳을 눌렀을 때 검색이 닫힘 (크기 0이면 눌림을 못 받음)
                      ? const SizedBox.expand()
                      // 자판이 올라오고 내려가도 문구가 움직이지 않게: 위에서부터 같은 자리에 둠
                      : Align(
                          alignment: Alignment.topCenter,
                          child: Padding(
                            padding: const EdgeInsets.only(top: 96),
                            child: Text(
                              _tr('찾은 파일이 없습니다', 'No matching files', '没有找到文件', '該当するファイルがありません'),
                              style: TextStyle(color: Theme.of(context).colorScheme.onSurfaceVariant),
                            ),
                          ),
                        ))
                  : filteredBooks.isEmpty
                  // 빈 그룹(전체·북마크 포함): 합치기 버튼 없이 안내 글만
                  ? Center(
                      child: Text(
                        _favoritesOnly
                            ? _tr('즐겨찾기한 파일이 없어요', 'No favorite files', '没有收藏的文件', 'お気に入りのファイルはありません')
                            : _tr('파일이 없어요', 'No files', '没有文件', 'ファイルがありません'),
                        style: TextStyle(fontSize: 15, color: Theme.of(context).colorScheme.onSurfaceVariant),
                      ),
                    )
                  : Row(
                      children: [
                        Expanded(
                          child: Listener(
                              behavior: HitTestBehavior.translucent,
                      // 선택: 파일을 꾹 누른 채 드래그 / 그냥 드래그: 목록 스크롤
                      // (꾹 누름이 인식되면 목록 스크롤은 자동으로 멈추고 선택만 진행됨)
                      onPointerDown: (event) {
                        _activeBookshelfPointers[event.pointer] = event.position;
                        if (_activeBookshelfPointers.length >= 2 && _isDragSelecting) {
                          setState(() => _isDragSelecting = false);
                        }
                      },
                      onPointerMove: (event) {
                        _activeBookshelfPointers[event.pointer] = event.position;
                        if (_isSelectionMode && _isDragSelecting && _activeBookshelfPointers.length < 2) {
                          _applyDragSelectionAtGlobalPos(event.position);
                        }
                      },
                      onPointerUp: (event) {
                        _activeBookshelfPointers.remove(event.pointer);
                        if (_activeBookshelfPointers.isEmpty) {
                          if (_isDragSelecting) {
                            setState(() => _isDragSelecting = false);
                          }
                          _lastDragTouchedPath = null;
                        }
                      },
                      onPointerCancel: (event) {
                        _activeBookshelfPointers.remove(event.pointer);
                        if (_activeBookshelfPointers.isEmpty) {
                          if (_isDragSelecting) {
                            setState(() => _isDragSelecting = false);
                          }
                          _lastDragTouchedPath = null;
                        }
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
                                  cacheExtent: 3000.0,
                                  physics: const AlwaysScrollableScrollPhysics(),
                                  padding: const EdgeInsets.fromLTRB(hPad, vPad, hPad, 88),
                                  gridDelegate: SliverGridDelegateWithFixedCrossAxisCount(
                                    crossAxisCount: crossCount,
                                    crossAxisSpacing: crossSpacing,
                                    mainAxisSpacing: mainSpacing,
                                    childAspectRatio: childAspect,
                                  ),
                                  itemCount: filteredBooks.length,
                                  itemBuilder: (context, index) {
                                    final bookFile = filteredBooks[index];
                                    return _KeepAliveBookItem(
                                      key: ValueKey(bookFile.path),
                                      child: _favPop(bookFile.path, _buildGridBookCard(bookFile)),
                                    );
                                  },
                                );
                              },
                            )
                          : ListView.separated(
                        controller: _bookshelfScrollController,
                        cacheExtent: 3000.0,
                        physics: const AlwaysScrollableScrollPhysics(),
                        padding: const EdgeInsets.only(bottom: 88),
                        itemCount: filteredBooks.length,
                        separatorBuilder: (_, __) => const Divider(height: 1),
                        itemBuilder: (context, index) {
                          final file = filteredBooks[index];
                          final rowKey = _fileRowKeys.putIfAbsent(file.path, () => GlobalKey());
                        final rawFileName = file.path.split(Platform.pathSeparator).last;
                        final displayFileName = _formatDisplayFileName(rawFileName);
                        final grp = _bookGroupMap[file.path] ?? '미분류';
                        final isSelected = _selectedFilePaths.contains(file.path);
                        final isFavorite = _favoritePaths.contains(file.path);
                        final lowerExt = rawFileName.split('.').last.toLowerCase();

                        return _favPop(file.path, Dismissible(
                          // 즐겨찾기가 바뀌면 다른 열쇠가 되어, 밀려 나간 줄은 사라지고 새 자리에 새 줄이 들어옴
                          key: ValueKey('${file.path}|$isFavorite'),
                          // 오른쪽으로 밀기: 즐겨찾기 켜기/끄기 (그대로 오른쪽으로 사라졌다가 새 자리에서 오른쪽부터 들어옴)
                          // 왼쪽으로 밀기: 휴지통
                          // (앱 설정 → 파일 표시 방식 → 목록형 '밀어서 즐겨찾기·휴지통 끄기')
                          direction: _isSelectionMode || StorageService.listSwipeOff.value ? DismissDirection.none : DismissDirection.horizontal,
                          resizeDuration: Anim.ms(220),
                          background: Container(
                            color: Colors.amber.shade600,
                            alignment: Alignment.centerLeft,
                            padding: const EdgeInsets.symmetric(horizontal: 20),
                            child: Row(
                              children: [
                                Icon(isFavorite ? Icons.bookmark_remove_outlined : Icons.bookmark_add_outlined, color: Colors.white),
                                const SizedBox(width: 6),
                                Text(
                                  isFavorite
                                      ? _tr('북마크 해제', 'Remove Bookmark', '取消书签', 'ブックマーク解除')
                                      : _tr('북마크', 'Bookmark', '书签', 'ブックマーク'),
                                  style: const TextStyle(color: Colors.white, fontWeight: FontWeight.bold),
                                ),
                              ],
                            ),
                          ),
                          secondaryBackground: Container(
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
                          onDismissed: (direction) {
                            if (direction == DismissDirection.startToEnd) {
                              _favoriteBySwipe(file);
                            } else {
                              _moveFileToTrash(file);
                            }
                          },
                          child: Container(
                            key: rowKey,
                            child: Stack(
                            clipBehavior: Clip.hardEdge,
                            children: [
                            ListTile(
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
                                : FileTypeIcon(ext: lowerExt),
                            title: Text(
                              displayFileName,
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                            ),
                            // 그룹 이름·쪽 표시가 없으면 이름만 줄 가운데에 (생기면 다시 위로)
                            subtitle: () {
                              // 10. [전체]에서만 그룹 이름 표시, 특정 그룹 선택 시 그룹 이름 표시 제거
                              // 그룹 이름 오른쪽: 마지막으로 읽은 쪽 (예: (6/983))
                              final subText = _fileMetaText(file.path, _localizeGroupName(grp), _selectedGroup == '전체' && !_hideGroupName);
                              if (subText.isEmpty) return null;
                              return Text(
                                subText,
                                style: const TextStyle(fontSize: 12),
                                maxLines: 1,
                                overflow: TextOverflow.ellipsis,
                              );
                            }(),
                            // 아래 줄이 없어도 줄 높이는 그대로
                            minTileHeight: 72,
                            trailing: _isSelectionMode
                                ? null
                                // 가로 점 3개: 이름 변경 / 그룹 이동 (표지형 세로 점 3개 메뉴와 같은 모양)
                                // 가로 점 3개: 그룹 목록처럼 아이콘에서 커져 나오는 메뉴
                                : Builder(
                                    builder: (btnCtx) => IconButton(
                                      icon: const Icon(Icons.more_horiz),
                                      tooltip: _tr('메뉴', 'More', '更多', 'メニュー'),
                                      onPressed: () => _showFileMenu(btnCtx, file),
                                    ),
                                  ),
                            onLongPress: () {
                              if (_activeBookshelfPointers.length >= 2) return;
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
                              if (_activeBookshelfPointers.length >= 2) return;
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
                            // 왼쪽 위 끝에 걸친 즐겨찾기 책갈피
                            if (!_isSelectionMode)
                              Positioned(
                                top: 0,
                                left: 0,
                                child: FavoriteRibbon(
                                  active: isFavorite,
                                  isDark: widget.isDarkMode,
                                  onTap: () => _toggleFavorite(file),
                                ),
                              ),
                            ],
                          ),
                          ),
                        ), slide: true);
                      },
                    ),
                          ),
                        ),
                      ],
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
                SizedBox(
                  height: 42,
                  child: FloatingActionButton.extended(
                    heroTag: 'fab_batch_move_group',
                    backgroundColor: AppColors.of(context),
                    foregroundColor: AppColors.onSig(context),
                    extendedPadding: const EdgeInsets.symmetric(horizontal: 13),
                    extendedIconLabelSpacing: 6,
                    onPressed: _selectedFilePaths.isNotEmpty ? _moveSelectedFilesBatch : null,
                    icon: const Icon(Icons.drive_file_move_outline, size: 16),
                    label: Text(
                      '${_tr("그룹", "Group", "分组", "グループ")} (${_selectedFilePaths.length})',
                      style: TextStyle(fontSize: 13.5, fontWeight: FontWeight.w600, shadows: AppColors.sigShadows(context)),
                    ),
                  ),
                ),
                const SizedBox(width: 8),
                SizedBox(
                  height: 42,
                  child: FloatingActionButton.extended(
                    heroTag: 'fab_batch_delete',
                    backgroundColor: Colors.redAccent,
                    foregroundColor: Colors.white,
                    extendedPadding: const EdgeInsets.symmetric(horizontal: 13),
                    extendedIconLabelSpacing: 6,
                    onPressed: _selectedFilePaths.isNotEmpty ? _deleteSelectedFilesBatch : null,
                    icon: const Icon(Icons.delete_outline, size: 16),
                    label: Text(
                      '${_tr("삭제", "Delete", "删除", "削除")} (${_selectedFilePaths.length})',
                      style: const TextStyle(fontSize: 13.5, fontWeight: FontWeight.w600),
                    ),
                  ),
                ),
              ],
            )
          : _buildAddFab(),
      ),
    );
  }
}

// ─────────────────────────────────────────────────────────────────────────────
// 드래그 선택 중 손가락이 목록 위/아래 가장자리에 머무는 동안 계속 부드럽게 자동 스크롤할 속도(16ms당 px)
double _edgeAutoScrollStep(double localDy, double viewportHeight, double zone) {
  if (localDy < zone) {
    final double t = ((zone - localDy) / zone).clamp(0.0, 1.6).toDouble();
    return -(2.0 + 18.0 * t);
  }
  if (localDy > viewportHeight - zone) {
    final double t = ((localDy - (viewportHeight - zone)) / zone).clamp(0.0, 1.6).toDouble();
    return 2.0 + 18.0 * t;
  }
  return 0.0;
}

/// 합치기용 파일 선택 창 (이미지·PDF 공용)
/// - 그냥 드래그: 목록 스크롤
/// - 파일을 꾹 누른 채 드래그: 지나가는 파일 연속 선택(가장자리에서 자동 스크롤)
/// 반환값: 선택한 경로 목록(List<String>) 또는 'browse'(기기에서 선택)
class _FileMergeSelectDialog extends StatefulWidget {
  const _FileMergeSelectDialog({
    required this.files,
    required this.tr,
    required this.displayName,
    required this.title,
    required this.mergeLabel,
  });

  final List<File> files;
  final String Function(String ko, String en, String zh, String ja) tr;
  final String Function(File f) displayName;
  final String title;
  final String mergeLabel;
  // 행 배치: [순서번호][파일이름][체크칸]

  @override
  State<_FileMergeSelectDialog> createState() => _FileMergeSelectDialogState();
}

class _FileMergeSelectDialogState extends State<_FileMergeSelectDialog> {
  static const double _rowH = 48.0;
  final ScrollController _sc = ScrollController();
  final GlobalKey _listKey = GlobalKey();
  final List<String> _selected = [];

  bool _dragSelecting = false;
  bool _dragTarget = true;
  int? _lastIndex;
  Offset? _tapDownPos;
  DateTime? _tapDownAt;
  Offset? _lastDragGlobal;
  Timer? _edgeTimer;

  @override
  void dispose() {
    _edgeTimer?.cancel();
    _sc.dispose();
    super.dispose();
  }

  RenderBox? get _listBox {
    final box = _listKey.currentContext?.findRenderObject();
    return (box is RenderBox && box.hasSize) ? box : null;
  }

  int? _indexAt(Offset global, {bool clampToList = false}) {
    final box = _listBox;
    if (box == null || widget.files.isEmpty) return null;
    double y = box.globalToLocal(global).dy;
    if (y < 0 || y >= box.size.height) {
      if (!clampToList) return null;
      y = y.clamp(0.0, box.size.height - 1).toDouble();
    }
    final double off = _sc.hasClients ? _sc.position.pixels : 0.0;
    final int idx = ((y + off) / _rowH).floor();
    if (idx < 0 || idx >= widget.files.length) return null;
    return idx;
  }

  void _setSelected(int idx, bool select) {
    final path = widget.files[idx].path;
    if (select) {
      if (!_selected.contains(path)) _selected.add(path);
    } else {
      _selected.remove(path);
    }
  }

  void _applyDragAt(Offset global) {
    final idx = _indexAt(global, clampToList: true);
    if (idx == null) return;
    final int from = _lastIndex ?? idx;
    if (from == idx && _lastIndex != null) return;
    setState(() {
      final int step = idx >= from ? 1 : -1;
      for (int i = from; ; i += step) {
        _setSelected(i, _dragTarget);
        if (i == idx) break;
      }
    });
    _lastIndex = idx;
  }

  void _ensureEdgeTimer() {
    _edgeTimer ??= Timer.periodic(const Duration(milliseconds: 16), (t) {
      final box = _listBox;
      final g = _lastDragGlobal;
      if (!mounted || !_dragSelecting || box == null || g == null || !_sc.hasClients) {
        t.cancel();
        _edgeTimer = null;
        return;
      }
      final double localDy = box.globalToLocal(g).dy;
      final double step = _edgeAutoScrollStep(localDy, box.size.height, 44.0);
      if (step == 0.0) return;
      final pos = _sc.position;
      final double target = (pos.pixels + step).clamp(pos.minScrollExtent, pos.maxScrollExtent).toDouble();
      if (target != pos.pixels) {
        _sc.jumpTo(target);
        _applyDragAt(g);
      }
    });
  }

  void _onLongPressStart(LongPressStartDetails d) {
    final idx = _indexAt(d.globalPosition);
    if (idx == null) return;
    HapticFeedback.selectionClick();
    setState(() {
      _dragSelecting = true;
      _dragTarget = !_selected.contains(widget.files[idx].path);
      _setSelected(idx, _dragTarget);
    });
    _lastIndex = idx;
    _lastDragGlobal = d.globalPosition;
  }

  void _onLongPressMove(LongPressMoveUpdateDetails d) {
    if (!_dragSelecting) return;
    _lastDragGlobal = d.globalPosition;
    _applyDragAt(d.globalPosition);
    _ensureEdgeTimer();
  }

  void _onLongPressEnd() {
    _dragSelecting = false;
    _lastIndex = null;
    _lastDragGlobal = null;
  }

  Widget _orderBadge(int selIndex) => CircleAvatar(
        radius: 11,
        backgroundColor: AppColors.of(context),
        child: Text(
          '${selIndex + 1}',
          style: TextStyle(fontSize: 11, color: AppColors.onSig(context), fontWeight: FontWeight.bold, shadows: AppColors.sigShadows(context)),
        ),
      );

  @override
  Widget build(BuildContext context) {
    final tr = widget.tr;
    final files = widget.files;
    return AlertDialog(
      title: Row(
        mainAxisAlignment: MainAxisAlignment.spaceBetween,
        children: [
          Expanded(
            child: FittedBox(
              fit: BoxFit.scaleDown,
              alignment: Alignment.centerLeft,
              child: Text(widget.title, maxLines: 1, softWrap: false),
            ),
          ),
          TextButton(
            onPressed: () {
              setState(() {
                if (_selected.length == files.length) {
                  _selected.clear();
                } else {
                  _selected
                    ..clear()
                    ..addAll(files.map((e) => e.path));
                }
              });
            },
            child: Text(tr('전체선택', 'Select All', '全选', 'すべて選択')),
          ),
        ],
      ),
      content: SizedBox(
        width: 420,
        height: 360,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              mainAxisAlignment: MainAxisAlignment.spaceBetween,
              children: [
                Text('${tr("선택됨", "Selected", "已选", "選択中")}: ${_selected.length}',
                    style: const TextStyle(fontWeight: FontWeight.w800)),
                TextButton.icon(
                  icon: const Icon(Icons.folder_open, size: 14),
                  label: Text(tr('기기에서 선택', 'Browse Device', '从设备选择', '端末から選択')),
                  onPressed: () => Navigator.pop(context, 'browse'),
                ),
              ],
            ),
            const Divider(height: 1),
            Expanded(
              child: GestureDetector(
                onLongPressStart: _onLongPressStart,
                onLongPressMoveUpdate: _onLongPressMove,
                onLongPressEnd: (_) => _onLongPressEnd(),
                onLongPressCancel: _onLongPressEnd,
                child: ListView.builder(
                  key: _listKey,
                  controller: _sc,
                  itemExtent: _rowH,
                  itemCount: files.length,
                  itemBuilder: (_, idx) {
                    final f = files[idx];
                    final selIndex = _selected.indexOf(f.path);
                    final checked = selIndex != -1;
                    final checkbox = IgnorePointer(child: Checkbox(value: checked, onChanged: (_) {}));
                    final name = Expanded(
                      child: Text(widget.displayName(f), maxLines: 1, overflow: TextOverflow.ellipsis),
                    );
                    // 한 번 누르면 바로 선택/해제 (화면 끌기·길게 누르기와 겨루지 않게 손을 뗄 때 직접 판단)
                    return Listener(
                      onPointerDown: (e) {
                        _tapDownPos = e.position;
                        _tapDownAt = DateTime.now();
                      },
                      onPointerUp: (e) {
                        final p0 = _tapDownPos, t0 = _tapDownAt;
                        _tapDownPos = null;
                        if (p0 == null || t0 == null || _dragSelecting) return;
                        if ((e.position - p0).distance > 14 || DateTime.now().difference(t0).inMilliseconds > 450) return;
                        setState(() => _setSelected(idx, !_selected.contains(f.path)));
                      },
                      child: InkWell(
                      onTap: () {},
                      child: Row(
                        children: [
                          SizedBox(
                            width: 40,
                            child: checked ? Center(child: _orderBadge(selIndex)) : null,
                          ),
                          name,
                          checkbox,
                        ],
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
      actions: [
        TextButton(onPressed: () => Navigator.pop(context), child: Text(tr('취소', 'Cancel', '取消', 'キャンセル'))),
        ElevatedButton(
          onPressed: _selected.length >= 2 ? () => Navigator.pop(context, List<String>.of(_selected)) : null,
          child: Text(widget.mergeLabel),
        ),
      ],
    );
  }
}


/// 즐겨찾기로 자리가 바뀌는 파일: 사라졌다가([shrinking]) 새 자리에서 나타남([growAt] 직후).
/// 표지형은 가운데로 작아졌다 커지고, 목록형([slide])은 오른쪽으로 밀려 나갔다가 오른쪽에서 밀려 들어옴
class _FavoritePop extends StatefulWidget {
  const _FavoritePop({required this.shrinking, required this.growAt, required this.child, this.slide = false});

  final bool shrinking;
  final bool slide;
  final DateTime? growAt;
  final Widget child;

  @override
  State<_FavoritePop> createState() => _FavoritePopState();
}

class _FavoritePopState extends State<_FavoritePop> with SingleTickerProviderStateMixin {
  late final AnimationController _c = AnimationController(vsync: this, value: widget.shrinking ? 0 : 1);

  bool _recent(DateTime? t) => t != null && DateTime.now().difference(t) < const Duration(milliseconds: 400);

  @override
  void initState() {
    super.initState();
    // 목록이 다시 정렬되며 새로 만들어진 경우
    if (!widget.shrinking && _recent(widget.growAt)) _grow();
  }

  void _grow() {
    _c.value = 0;
    _c.animateTo(1, duration: Anim.ms(widget.slide ? 260 : 220), curve: widget.slide ? Curves.easeOutCubic : Curves.easeOutBack);
  }

  @override
  void didUpdateWidget(_FavoritePop old) {
    super.didUpdateWidget(old);
    if (widget.shrinking && !old.shrinking) {
      _c.animateTo(0, duration: Anim.ms(160), curve: Curves.easeInCubic);
    } else if (!widget.shrinking && widget.growAt != old.growAt && _recent(widget.growAt)) {
      _grow();
    } else if (!widget.shrinking && old.shrinking && _c.value < 1) {
      _c.value = 1;
    }
  }

  @override
  void dispose() {
    _c.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    if (!widget.slide) return ScaleTransition(scale: _c, child: widget.child);
    return AnimatedBuilder(
      animation: _c,
      child: widget.child,
      builder: (context, child) => FractionalTranslation(translation: Offset(1 - _c.value, 0), child: child),
    );
  }
}

/// 애니메이션 멈추기를 켰을 때의 화면 전환: 움직임 없이 바로
class _NoPageTransition extends PageTransitionsBuilder {
  const _NoPageTransition();

  @override
  Widget buildTransitions<T>(PageRoute<T> route, BuildContext context, Animation<double> animation, Animation<double> secondaryAnimation, Widget child) => child;
}
