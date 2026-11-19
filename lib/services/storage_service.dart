import 'package:flutter/widgets.dart';
import 'dart:convert';
import 'package:shared_preferences/shared_preferences.dart';
import 'i18n_extra.dart';
import '../widgets/app_colors.dart';

class BookmarkItem {
  final String id;
  final String label;
  final String position;
  final String createdAt;

  /// 2페이지 보기에서 저장한 북마크 (두 쪽을 함께 북마크)
  final bool spread;

  /// 북마크할 때의 화면 회전 설정('auto'·'portrait'·'landscape')과 실제 방향(가로면 true), 페이지 표시('one'·'two'·'auto')
  /// → 북마크를 누르면 그때 보기 그대로 돌아가서 보여 줌
  final String? rotation;
  final bool? landscape;
  final String? display;

  /// 스크롤 보기에서 한 북마크 (스크롤 보기에서만 책갈피가 보이고, 누르면 스크롤 보기로 돌아가 보여 줌)
  final bool scroll;

  /// 북마크할 때의 페이지 모드: 'tap' · 'slide' · 'tap+slide' · 'scroll' (목록에 함께 보여 줌)
  final String? mode;

  BookmarkItem({
    required this.id,
    required this.label,
    required this.position,
    required this.createdAt,
    this.spread = false,
    this.rotation,
    this.landscape,
    this.display,
    this.scroll = false,
    this.mode,
  });

  Map<String, dynamic> toJson() => {
        'id': id,
        'label': label,
        'position': position,
        'createdAt': createdAt,
        if (spread) 'spread': true,
        if (rotation != null) 'rotation': rotation,
        if (landscape != null) 'landscape': landscape,
        if (display != null) 'display': display,
        if (scroll) 'scroll': true,
        if (mode != null) 'mode': mode,
      };

  factory BookmarkItem.fromJson(Map<String, dynamic> json) => BookmarkItem(
        id: json['id'] ?? '',
        label: json['label'] ?? '',
        position: json['position'] ?? '',
        createdAt: json['createdAt'] ?? '',
        spread: json['spread'] == true,
        rotation: json['rotation'] is String ? json['rotation'] as String : null,
        landscape: json['landscape'] is bool ? json['landscape'] as bool : null,
        display: json['display'] is String ? json['display'] as String : null,
        scroll: json['scroll'] == true,
        mode: json['mode'] is String ? json['mode'] as String : null,
      );
}

class MemoStroke {
  final List<double> dxList;
  final List<double> dyList;
  final int colorValue;

  /// 굵기: 쪽 너비에 대한 비율 (쪽이 커지거나 확대하면 같이 굵어짐). 0.5 이상이면 예전 방식(화면 점 크기)
  final double strokeWidth;

  /// 너비가 [pageWidth]인 쪽 위에 그릴 때의 굵기
  double widthOn(double pageWidth) => strokeWidth < 0.5 ? strokeWidth * pageWidth : strokeWidth;

  MemoStroke({
    required this.dxList,
    required this.dyList,
    required this.colorValue,
    required this.strokeWidth,
  });

  Map<String, dynamic> toJson() => {
        'x': dxList,
        'y': dyList,
        'c': colorValue,
        'w': strokeWidth,
      };

  factory MemoStroke.fromJson(Map<String, dynamic> json) => MemoStroke(
        dxList: (json['x'] as List).map((e) => (e as num).toDouble()).toList(),
        dyList: (json['y'] as List).map((e) => (e as num).toDouble()).toList(),
        colorValue: (json['c'] as num?)?.toInt() ?? 0xFFFFC107,
        strokeWidth: (json['w'] as num?)?.toDouble() ?? 2.0,
      );
}


class AppI18n {
  static String t(
    String lang, {
    required String ko,
    required String en,
    required String zh,
    required String ja,
  }) {
    switch (lang) {
      case 'en':
        return en;
      // 프랑스어·러시아어·스페인어: 영어 문구로 번역표에서 찾음 (없으면 영어)
      case 'fr':
      case 'ru':
      case 'es':
        return I18nExtra.tr(lang, en) ?? en;
      case 'zh':
        return zh;
      case 'ja':
        return ja;
      default:
        return ko;
    }
  }
}

class StorageService {
  static final ValueNotifier<String> appLangNotifier = ValueNotifier<String>('ko');
  static final ValueNotifier<bool?> desiredLandscapeNotifier = ValueNotifier<bool?>(null);
  // 페이지 기억하기 (기본 꺼짐). 끄면 읽던 자리를 새로 저장하지 않고 처음부터 보여 주며,
  // 다시 켜면 끄기 전에 저장해 둔 자리를 그대로 보여 준다
  static bool rememberPage = false;

  static Future<void> loadRememberPage() async {
    final prefs = await SharedPreferences.getInstance();
    rememberPage = prefs.getBool('remember_page_v116') ?? false;
    tapGuideOff = prefs.getBool('tap_guide_off_v104') ?? false;
    Anim.off.value = prefs.getBool('anim_off_v109') ?? false;
    pageCurl = prefs.getBool('page_curl_v109') ?? true;
    final zones = prefs.getString('tap_zones_v122');
    tapZones.value = zones != null && RegExp(r'^[PNMX]{9}$').hasMatch(zones) ? zones : tapZonesDefault;
  }

  /// 탭 영역 (화면 3×3 칸, 왼쪽 위부터 줄마다): P = 이전, N = 다음, M = 메뉴, X = 없음
  /// 기본: 위 6칸 메뉴, 맨 아래 줄 왼쪽 칸 이전, 나머지 다음
  static const String tapZonesDefault = 'MMMMMMPNN';
  static final ValueNotifier<String> tapZones = ValueNotifier<String>(tapZonesDefault);

  static Future<void> setTapZones(String zones) async {
    tapZones.value = zones;
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString('tap_zones_v122', zones);
  }

  /// 슬라이드로 넘길 때 책처럼 넘기기 (기본 켜짐)
  static bool pageCurl = true;

  static Future<void> setPageCurl(bool on) async {
    pageCurl = on;
    final prefs = await SharedPreferences.getInstance();
    await prefs.setBool('page_curl_v109', on);
  }

  /// 애니메이션 끄기 (앱 전체)
  static Future<void> setAnimOff(bool off) async {
    Anim.off.value = off;
    final prefs = await SharedPreferences.getInstance();
    await prefs.setBool('anim_off_v109', off);
  }

  // 탭 존 가이드라인 끄기 (기본: 켜짐 = 파일을 열 때마다 화면 영역 안내를 보여 줌)
  static bool tapGuideOff = false;

  static Future<void> setTapGuideOff(bool off) async {
    tapGuideOff = off;
    final prefs = await SharedPreferences.getInstance();
    await prefs.setBool('tap_guide_off_v104', off);
  }

  static Future<void> setRememberPage(bool on) async {
    rememberPage = on;
    final prefs = await SharedPreferences.getInstance();
    await prefs.setBool('remember_page_v116', on);
  }

  static Future<void> saveLastPosition(String bookPath, String pos) async {
    if (!rememberPage) return;
    final prefs = await SharedPreferences.getInstance();
    final oldPos = prefs.getString('pos_$bookPath');
    if (oldPos != null && oldPos != pos) {
      await prefs.setString('prev_pos_$bookPath', oldPos);
    }
    await prefs.setString('pos_$bookPath', pos);
  }

  static Future<String?> getLastPosition(String bookPath) async {
    if (!rememberPage) return null;
    final prefs = await SharedPreferences.getInstance();
    return prefs.getString('pos_$bookPath');
  }

  static Future<void> saveProgress(String bookPath, double progress) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setDouble('prog_$bookPath', progress);
  }

  static Future<double> getProgress(String bookPath) async {
    final prefs = await SharedPreferences.getInstance();
    return prefs.getDouble('prog_$bookPath') ?? 0.0;
  }

  // 마지막으로 읽은 쪽 '지금/전체' (예: 6/983) — 파일 목록에 표시
  static Future<void> savePageLabel(String bookPath, String label) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString('pagelbl_$bookPath', label);
  }

  static Future<String?> getPageLabel(String bookPath) async {
    final prefs = await SharedPreferences.getInstance();
    return prefs.getString('pagelbl_$bookPath');
  }

  // 앱 테마: 'system'(기본 시스템, 휴대폰 설정 따라감) / 'light' / 'dark'
  static Future<void> setAppThemeMode(String mode) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString('app_theme_mode', mode);
  }

  static Future<String> getAppThemeMode() async {
    final prefs = await SharedPreferences.getInstance();
    return prefs.getString('app_theme_mode') ?? 'system';
  }

  /// 앱 테마 설정값 → 지금 실제로 어두운 화면인지
  static bool isDarkFor(String mode) => mode == 'dark' || mode == 'black' || mode == 'dim' || mode == 'library' || // 없어진 테마는 다크로 봄
      (mode == 'system' && WidgetsBinding.instance.platformDispatcher.platformBrightness == Brightness.dark);


  // 앱 언어 설정 ('system': 기본 시스템, 'ko': 한국어, 'en': 영어, 'zh': 중국어, 'ja': 일본어)
  // 저장값은 'system'일 수 있고, 실제 화면 문구에 쓰는 언어(appLangNotifier)는 항상 ko/en/zh/ja 중 하나다.
  static const List<String> supportedAppLanguages = ['ko', 'en', 'zh', 'ja', 'fr', 'ru', 'es'];

  /// 사용자가 고른 언어 설정값 ('system' 포함). 아직 고른 적 없으면 null.
  static String? appLangSetting;

  /// 휴대폰(시스템) 언어 → 앱이 지원하는 언어. 지원하지 않는 언어면 영어.
  static String resolveSystemLanguage() {
    for (final locale in WidgetsBinding.instance.platformDispatcher.locales) {
      final code = locale.languageCode.toLowerCase();
      if (supportedAppLanguages.contains(code)) return code;
    }
    return 'en';
  }

  /// 설정값('system' 포함) → 실제로 쓸 언어 코드
  static String resolveAppLanguage(String setting) => setting == 'system' ? resolveSystemLanguage() : setting;

  static Future<void> setAppLanguage(String setting) async {
    appLangSetting = setting;
    appLangNotifier.value = resolveAppLanguage(setting);
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString('app_language_code', setting);
  }

  /// 아직 언어를 고른 적이 없는지 (앱 처음 시작 시 언어 선택 화면 표시용)
  /// 비밀번호가 걸린 문서 (쪽 화면 저장·먼저 띄우기를 하지 않음)
  static Future<void> markProtectedDoc(String path) async {
    final prefs = await SharedPreferences.getInstance();
    final list = prefs.getStringList('protected_docs_v115') ?? <String>[];
    if (!list.contains(path)) await prefs.setStringList('protected_docs_v115', [...list, path]);
  }

  static Future<bool> isProtectedDoc(String path) async {
    final prefs = await SharedPreferences.getInstance();
    return (prefs.getStringList('protected_docs_v115') ?? const <String>[]).contains(path);
  }

  /// 처음 시작할 때 '앱 접근 권한 안내'를 본 적 있는지
  static Future<void> markPermissionGuideShown() async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setBool('perm_guide_shown_v113', true);
  }

  static Future<bool> needsLanguageSelection() async {
    final prefs = await SharedPreferences.getInstance();
    return prefs.getString('app_language_code') == null;
  }

  /// 실제로 쓸 언어 코드 (ko/en/zh/ja). 고른 적이 없으면 시스템 언어를 따른다.
  static Future<String> getAppLanguage() async {
    final prefs = await SharedPreferences.getInstance();
    final setting = prefs.getString('app_language_code') ?? 'system';
    appLangSetting = prefs.getString('app_language_code');
    final code = resolveAppLanguage(setting);
    appLangNotifier.value = code;
    return code;
  }

  // 파일 이름 뒤에 형식(.pdf, .epub 등) 숨기기 설정
  // 파일 표시 방식 기본값을 목록형('list')으로 변경
  static Future<void> setBookshelfViewMode(String mode) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString('bookshelf_view_mode_v27', mode);
  }

  static Future<String> getBookshelfViewMode() async {
    final prefs = await SharedPreferences.getInstance();
    return prefs.getString('bookshelf_view_mode_v27') ?? 'list';
  }

  static Future<void> setHideFileExtension(bool hide) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setBool('hide_file_extension', hide);
  }

  static Future<bool> getHideFileExtension() async {
    final prefs = await SharedPreferences.getInstance();
    return prefs.getBool('hide_file_extension') ?? false;
  }

  /// 표지형에서 표지 그림 끄기 (켜면 아이콘만)
  static Future<void> setHideThumbnails(bool hide) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setBool('hide_thumbnails', hide);
  }

  static Future<bool> getHideThumbnails() async {
    final prefs = await SharedPreferences.getInstance();
    return prefs.getBool('hide_thumbnails') ?? false;
  }

  /// 스크롤 보기의 회색 스크롤 막대 끄기
  static Future<bool> getScrollBarOff() async => (await SharedPreferences.getInstance()).getBool('scroll_bar_off_v100') ?? false;
  static Future<void> setScrollBarOff(bool off) async => (await SharedPreferences.getInstance()).setBool('scroll_bar_off_v100', off);

  /// 목록형: 파일을 옆으로 밀어 즐겨찾기(오른쪽)·휴지통(왼쪽) 하는 동작 끄기
  static final ValueNotifier<bool> listSwipeOff = ValueNotifier<bool>(false);
  static Future<void> loadListSwipeOff() async {
    listSwipeOff.value = (await SharedPreferences.getInstance()).getBool('list_swipe_off_v99') ?? false;
  }
  static Future<void> setListSwipeOff(bool off) async {
    listSwipeOff.value = off;
    await (await SharedPreferences.getInstance()).setBool('list_swipe_off_v99', off);
  }

  /// 앱 스타일: 'basic'(기본: 아래 막대·한 네모 편집창·밑에서 올라오는 창) / 'simple'(심플: 위 막대·아이콘만 편집창·가운데 창)
  static final ValueNotifier<String> appStyle = ValueNotifier<String>('basic');
  static bool get simpleStyle => appStyle.value == 'simple';
  static Future<void> loadAppStyle() async {
    appStyle.value = (await SharedPreferences.getInstance()).getString('app_style_v140') == 'simple' ? 'simple' : 'basic';
  }
  static Future<void> setAppStyle(String style) async {
    appStyle.value = style == 'simple' ? 'simple' : 'basic';
    await (await SharedPreferences.getInstance()).setString('app_style_v140', appStyle.value);
  }

  /// 표지형: 책갈피를 잡아당겨 북마크하는 움직임 끄기
  static Future<void> setRibbonAnimationOff(bool off) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setBool('ribbon_tap_v116', off);
  }

  static Future<bool> getRibbonAnimationOff() async {
    final prefs = await SharedPreferences.getInstance();
    return prefs.getBool('ribbon_tap_v116') ?? false;
  }

  /// 사용자가 고른 표지 그림: 파일 경로 → 표지 그림 경로
  static Future<Map<String, String>> getCustomCovers() async {
    final prefs = await SharedPreferences.getInstance();
    try {
      final m = jsonDecode(prefs.getString('custom_covers') ?? '{}') as Map<String, dynamic>;
      return m.map((k, v) => MapEntry(k, '$v'));
    } catch (_) {
      return {};
    }
  }

  static Future<void> setCustomCover(String bookPath, String? coverPath) async {
    final prefs = await SharedPreferences.getInstance();
    final m = await getCustomCovers();
    if (coverPath == null) {
      m.remove(bookPath);
    } else {
      m[bookPath] = coverPath;
    }
    await prefs.setString('custom_covers', jsonEncode(m));
  }

  /// 파일 목록에서 [그룹 이름] 숨기기
  // 파일 목록: 페이지 수 숨기기
  static Future<bool> getHidePageCount() async => (await SharedPreferences.getInstance()).getBool('hide_page_count_v90') ?? false;
  static Future<void> setHidePageCount(bool v) async => (await SharedPreferences.getInstance()).setBool('hide_page_count_v90', v);

  /// 파일을 앱에 추가한 날짜 (밀리초). 저장해 둔 것이 없으면 null
  static Future<Map<String, int>> getAddedDates() async {
    final raw = (await SharedPreferences.getInstance()).getString('added_dates_v90');
    if (raw == null) return {};
    try {
      return (jsonDecode(raw) as Map).map((k, v) => MapEntry('$k', (v as num).toInt()));
    } catch (_) {
      return {};
    }
  }

  static Future<void> setAddedDates(Map<String, int> m) async =>
      (await SharedPreferences.getInstance()).setString('added_dates_v90', jsonEncode(m));

  // 파일 정렬: 기준 'name' | 'date', 순서 asc(이름 오름차순·오래된 순) / desc, 정렬 기억하기
  static Future<(String, bool, bool)> getLibrarySort() async {
    final p = await SharedPreferences.getInstance();
    final remember = p.getBool('lib_sort_remember_v90') ?? true; // 기본: 정렬 기억하기 켜짐
    if (!remember) return ('name', true, false);
    return (p.getString('lib_sort_by_v90') ?? 'name', p.getBool('lib_sort_asc_v90') ?? true, true);
  }

  static Future<void> setLibrarySort(String by, bool asc, bool remember) async {
    final p = await SharedPreferences.getInstance();
    await p.setBool('lib_sort_remember_v90', remember);
    await p.setString('lib_sort_by_v90', by);
    await p.setBool('lib_sort_asc_v90', asc);
  }

  static Future<void> setHideGroupName(bool hide) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setBool('hide_group_name', hide);
  }

  static Future<bool> getHideGroupName() async {
    final prefs = await SharedPreferences.getInstance();
    return prefs.getBool('hide_group_name') ?? false;
  }

  // 즐겨찾기(별표) 도서 관리
  static Future<Set<String>> getFavoriteBooks() async {
    final prefs = await SharedPreferences.getInstance();
    final list = prefs.getStringList('favorite_book_paths') ?? [];
    return list.toSet();
  }

  /// 여러 파일을 한꺼번에 즐겨찾기에 넣거나(on) 뺌
  static Future<void> setFavoriteBooks(Iterable<String> paths, bool on) async {
    final prefs = await SharedPreferences.getInstance();
    final favs = (prefs.getStringList('favorite_book_paths') ?? []).toSet();
    if (on) {
      favs.addAll(paths);
    } else {
      favs.removeAll(paths);
    }
    await prefs.setStringList('favorite_book_paths', favs.toList());
  }

  static Future<bool> toggleFavoriteBook(String bookPath) async {
    final prefs = await SharedPreferences.getInstance();
    final favs = (prefs.getStringList('favorite_book_paths') ?? []).toSet();
    final bool isNowFav;
    if (favs.contains(bookPath)) {
      favs.remove(bookPath);
      isNowFav = false;
    } else {
      favs.add(bookPath);
      isNowFav = true;
    }
    await prefs.setStringList('favorite_book_paths', favs.toList());
    return isNowFav;
  }

  static Future<void> setEpubBgTheme(String theme) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString('epub_bg_theme', theme);
  }

  static Future<String> getEpubBgTheme() async {
    final prefs = await SharedPreferences.getInstance();
    return prefs.getString('epub_bg_theme') ?? 'white';
  }

  /// 파일 안 테마 '편안한 모드' (EPUB 말고 워드·한글·TXT 등): 라이트 화면 위에 따뜻한 색을 덮음
  static Future<void> setDocComfort(bool on) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setBool('doc_comfort_theme', on);
  }

  static Future<bool> getDocComfort() async {
    final prefs = await SharedPreferences.getInstance();
    return prefs.getBool('doc_comfort_theme') ?? false;
  }

  static String _normalizeBookKey(String bookPath) {
    return bookPath.replaceAll(
      RegExp(r'(_v25_converted|\.v2\.converted|\.converted)\.epub$', caseSensitive: false),
      '',
    );
  }

  // 파일마다 읽기 방향 기억하기 (처음 여는 파일은 좌->우(false)가 기본값)
  static Future<void> setBookReadingDirectionRtl(String bookPath, bool isRtl) async {
    final prefs = await SharedPreferences.getInstance();
    final key = _normalizeBookKey(bookPath);
    await prefs.setBool('reading_dir_rtl_v26_$key', isRtl);
  }

  /// 이 책에 읽기 방향을 직접 정한 적이 없으면 null
  static Future<bool?> getBookReadingDirectionRtlOrNull(String bookPath) async {
    final prefs = await SharedPreferences.getInstance();
    final key = _normalizeBookKey(bookPath);
    return prefs.getBool('reading_dir_rtl_v26_$key');
  }

  static Future<bool> getBookReadingDirectionRtl(String bookPath) async {
    final prefs = await SharedPreferences.getInstance();
    final key = _normalizeBookKey(bookPath);
    return prefs.getBool('reading_dir_rtl_v26_$key') ?? false;
  }

  static Future<void> setUseVolumeTurn(bool enabled) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setBool('use_volume_turn', enabled);
  }

  static Future<bool> getUseVolumeTurn() async {
    final prefs = await SharedPreferences.getInstance();
    return prefs.getBool('use_volume_turn') ?? true;
  }

  // 페이지 모드 (v88에서 새로 시작: 예전 페이지 전환 설정은 쓰지 않음)
  // 탭(기본값 켜짐) / 스크롤 / 슬라이드(옆으로 밀기). 스크롤과 슬라이드는 함께 켤 수 없음
  static Future<void> setUseSwipeTurn(bool enabled) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setBool('page_mode_slide_v88', enabled);
    if (enabled) await prefs.setBool('page_mode_scroll_v88', false);
  }

  static Future<bool> getUseSwipeTurn() async {
    final prefs = await SharedPreferences.getInstance();
    return prefs.getBool('page_mode_slide_v88') ?? false;
  }

  static Future<void> setPageModeTap(bool enabled) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setBool('page_mode_tap_v88', enabled);
  }

  static Future<bool> getPageModeTap() async {
    final prefs = await SharedPreferences.getInstance();
    return prefs.getBool('page_mode_tap_v88') ?? true;
  }

  static Future<void> setPageModeScroll(bool enabled) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setBool('page_mode_scroll_v88', enabled);
    if (enabled) await prefs.setBool('page_mode_slide_v88', false);
  }

  static Future<bool> getPageModeScroll() async {
    final prefs = await SharedPreferences.getInstance();
    return prefs.getBool('page_mode_scroll_v88') ?? false;
  }

  /// 페이지 표시: 'one'(한 페이지) / 'two'(두 페이지) / 'auto'(화면이 넓으면 두 페이지)
  static Future<String> getPageDisplay() async {
    final prefs = await SharedPreferences.getInstance();
    final v = prefs.getString('page_display_v88');
    return (v == 'two' || v == 'auto') ? v! : 'one';
  }

  static Future<void> setPageDisplay(String mode) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString('page_display_v88', mode);
  }

  // 메모 지우개 종류: 'area'(닿은 부분만) / 'stroke'(닿은 획 전체)
  static Future<void> setMemoEraserType(String type) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString('memo_eraser_type', type);
  }

  static Future<String> getMemoEraserType() async {
    final prefs = await SharedPreferences.getInstance();
    final v = prefs.getString('memo_eraser_type');
    return (v == 'stroke' || v == 'area') ? v! : 'area';
  }

  // 진행바 UI 하단('bottom')을 기본값으로 설정
  static Future<void> setProgressBarPosition(String pos) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString('progress_bar_pos_v26', pos);
  }

  static Future<String> getProgressBarPosition() async {
    final prefs = await SharedPreferences.getInstance();
    final v = prefs.getString('progress_bar_pos_v26');
    return (v == 'left' || v == 'right' || v == 'top') ? v! : 'bottom';
  }

  // 도구 모음 자리: 'bottom'(기본) / 'top' / 'left' / 'right' (도구 모음을 길게 눌러 끌어 옮김)
  static Future<void> setToolbarPosition(String pos) async => (await SharedPreferences.getInstance()).setString('quick_toolbar_pos_v1', pos);
  static Future<String> getToolbarPosition() async {
    final v = (await SharedPreferences.getInstance()).getString('quick_toolbar_pos_v1');
    return (v == 'left' || v == 'right' || v == 'top') ? v! : 'bottom';
  }

  // 진행바 숨기기 (자리는 진행바를 길게 눌러 옮김)
  static Future<void> setProgressBarHidden(bool v) async => (await SharedPreferences.getInstance()).setBool('progress_bar_hidden_v1', v);
  static Future<bool> getProgressBarHidden() async => (await SharedPreferences.getInstance()).getBool('progress_bar_hidden_v1') ?? false;

  // 메모 도구모음 위치: 'bottom'(기본) / 'top' / 'left' / 'right' (도구 모음을 길게 눌러 끌어 옮김)
  static Future<void> setMemoToolbarPosition(String pos) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString('memo_toolbar_pos', pos);
  }

  static Future<String> getMemoToolbarPosition() async {
    final prefs = await SharedPreferences.getInstance();
    return prefs.getString('memo_toolbar_pos') ?? 'bottom';
  }

  // 스크롤 막대 자리: 'left'면 왼쪽 (기본 'right', 막대를 길게 눌러 옮김)
  static Future<void> setQuickMenuSide(String side) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString('quick_menu_side', side);
  }

  static Future<String> getQuickMenuSide() async {
    final prefs = await SharedPreferences.getInstance();
    return prefs.getString('quick_menu_side') ?? 'right';
  }

  /// PDF·CBZ 쪽 메모 (쪽마다 하나 — 한 쪽·두 쪽 보기 공통)
  static Future<void> savePageMemoStrokes(
      String bookKey, int pageIndex, List<MemoStroke> strokes) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(
      'memo_strokes_${bookKey}_$pageIndex',
      jsonEncode(strokes.map((e) => e.toJson()).toList()),
    );
  }

  static Future<List<MemoStroke>> getPageMemoStrokes(
      String bookKey, int pageIndex) async {
    final prefs = await SharedPreferences.getInstance();
    final raw = prefs.getString('memo_strokes_${bookKey}_$pageIndex');
    if (raw == null) return [];
    final List decoded = jsonDecode(raw);
    return decoded.map((e) => MemoStroke.fromJson(e)).toList();
  }

  static Future<void> saveLocationStrokes(
      String bookKey, String locationKey, List<MemoStroke> strokes) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(
      'page_strokes_${bookKey}_$locationKey',
      jsonEncode(strokes.map((e) => e.toJson()).toList()),
    );
  }

  /// 쪽마다 저장한 메모 ('pg:쪽') 모두: 쪽 번호 → 획들 (스크롤 보기에서 한꺼번에 보여 줄 때)
  static Future<Map<int, List<MemoStroke>>> getAllPageStrokes(String bookKey) async {
    final prefs = await SharedPreferences.getInstance();
    final String prefix = 'page_strokes_${bookKey}_pg:';
    final out = <int, List<MemoStroke>>{};
    for (final k in prefs.getKeys()) {
      if (!k.startsWith(prefix)) continue;
      final int? page = int.tryParse(k.substring(prefix.length));
      final raw = prefs.getString(k);
      if (page == null || raw == null) continue;
      final List decoded = jsonDecode(raw);
      final strokes = decoded.map((e) => MemoStroke.fromJson(e)).toList();
      if (strokes.isNotEmpty) out[page] = strokes;
    }
    return out;
  }

  static Future<List<MemoStroke>> getLocationStrokes(
      String bookKey, String locationKey) async {
    final prefs = await SharedPreferences.getInstance();
    final raw = prefs.getString('page_strokes_${bookKey}_$locationKey');
    if (raw == null) return [];
    final List decoded = jsonDecode(raw);
    return decoded.map((e) => MemoStroke.fromJson(e)).toList();
  }

  static Future<List<BookmarkItem>> getBookmarks(String bookPath) async {
    final prefs = await SharedPreferences.getInstance();
    final rawList = prefs.getStringList('bm_$bookPath') ?? [];
    return rawList.map((e) => BookmarkItem.fromJson(jsonDecode(e))).toList();
  }

  static Future<void> addBookmark(String bookPath, BookmarkItem item) async {
    final prefs = await SharedPreferences.getInstance();
    final list = await getBookmarks(bookPath);
    list.add(item);
    await prefs.setStringList(
      'bm_$bookPath',
      list.map((e) => jsonEncode(e.toJson())).toList(),
    );
  }

  /// 이 파일의 북마크를 모두 지움
  static Future<void> clearBookmarks(String bookPath) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.remove('bm_$bookPath');
  }

  static Future<void> removeBookmark(String bookPath, String id) async {
    final prefs = await SharedPreferences.getInstance();
    final list = await getBookmarks(bookPath);
    list.removeWhere((e) => e.id == id);
    await prefs.setStringList(
      'bm_$bookPath',
      list.map((e) => jsonEncode(e.toJson())).toList(),
    );
  }

  static const List<String> defaultGroups = ['전체', 'pdf', 'ppt', 'cbz', 'xlsx', 'hwpx', 'docx', 'epub', 'txt'];

  static Future<List<String>> getGroups() async {
    final prefs = await SharedPreferences.getInstance();
    // 처음 켤 때: 파일 형식별 그룹을 미리 만들어 둠
    final saved = prefs.getStringList('book_groups_v2');
    return saved ?? List<String>.of(defaultGroups);
  }

  static Future<void> addGroup(String groupName) async {
    final prefs = await SharedPreferences.getInstance();
    final groups = await getGroups();
    if (!groups.contains(groupName)) {
      groups.add(groupName);
      await prefs.setStringList('book_groups_v2', groups);
    }
  }

  /// 그룹 순서 저장 ([전체]는 항상 맨 앞)
  static Future<void> setGroupOrder(List<String> groups) async {
    final prefs = await SharedPreferences.getInstance();
    final ordered = ['전체', ...groups.where((g) => g != '전체')];
    await prefs.setStringList('book_groups_v2', ordered);
  }

  static Future<void> removeGroup(String groupName) async {
    if (groupName == '전체') return;
    final prefs = await SharedPreferences.getInstance();
    final groups = await getGroups();
    groups.remove(groupName);
    await prefs.setStringList('book_groups_v2', groups);
    for (final key in prefs.getKeys().toList()) {
      if (key.startsWith('grp_') && prefs.getString(key) == groupName) {
        await prefs.setString(key, '미분류');
      }
    }
  }

  /// 그룹 이름 바꾸기 (그 그룹에 있던 파일도 새 이름으로 따라감)
  static Future<bool> renameGroup(String oldName, String newName) async {
    if (oldName == '전체' || newName.isEmpty || oldName == newName) return false;
    final prefs = await SharedPreferences.getInstance();
    final groups = await getGroups();
    final i = groups.indexOf(oldName);
    if (i < 0 || groups.contains(newName)) return false;
    groups[i] = newName;
    await prefs.setStringList('book_groups_v2', groups);
    for (final key in prefs.getKeys().toList()) {
      if (key.startsWith('grp_') && prefs.getString(key) == oldName) {
        await prefs.setString(key, newName);
      }
    }
    return true;
  }

  static Future<void> setBookGroup(String bookPath, String groupName) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString('grp_$bookPath', groupName);
  }

  static Future<String> getBookGroup(String bookPath) async {
    final prefs = await SharedPreferences.getInstance();
    return prefs.getString('grp_$bookPath') ?? '미분류';
  }

  static Future<void> migrateBookMetadata(String oldPath, String newPath) async {
    if (oldPath == newPath) return;
    final prefs = await SharedPreferences.getInstance();
    final oldNorm = _normalizeBookKey(oldPath);
    final newNorm = _normalizeBookKey(newPath);
    final oldRtl = prefs.getBool('reading_dir_rtl_v26_$oldNorm');
    if (oldRtl != null) {
      await prefs.setBool('reading_dir_rtl_v26_$newNorm', oldRtl);
      await prefs.remove('reading_dir_rtl_v26_$oldNorm');
    }
    for (final prefix in ['pos_', 'prev_pos_', 'prog_', 'pagelbl_', 'grp_']) {
      final val = prefs.get('$prefix$oldPath');
      if (val != null) {
        if (val is String) await prefs.setString('$prefix$newPath', val);
        if (val is double) await prefs.setDouble('$prefix$newPath', val);
        await prefs.remove('$prefix$oldPath');
      }
    }
    final covers = await getCustomCovers();
    final cover = covers.remove(oldPath);
    if (cover != null) {
      covers[newPath] = cover;
      await prefs.setString('custom_covers', jsonEncode(covers));
    }
    final bms = prefs.getStringList('bm_$oldPath');
    if (bms != null) {
      await prefs.setStringList('bm_$newPath', bms);
      await prefs.remove('bm_$oldPath');
    }
    final favs = (prefs.getStringList('favorite_book_paths') ?? []).toSet();
    if (favs.contains(oldPath)) {
      favs.remove(oldPath);
      favs.add(newPath);
      await prefs.setStringList('favorite_book_paths', favs.toList());
    }
    for (final key in prefs.getKeys().toList()) {
      for (final prefix in [
        'bubbles_v5_',
        'memo_strokes_',
        'memo_note_',
        'page_strokes_',
      ]) {
        final matchPrefix = '$prefix${oldPath}_';
        if (key.startsWith(matchPrefix)) {
          final suffix = key.substring(matchPrefix.length);
          final strVal = prefs.getString(key);
          if (strVal != null) {
            await prefs.setString('$prefix${newPath}_$suffix', strVal);
          }
          await prefs.remove(key);
        }
      }
    }
  }

  static Future<void> removeBookMetadata(String bookPath) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.remove('reading_dir_rtl_v26_${_normalizeBookKey(bookPath)}');
    await prefs.remove('pos_$bookPath');
    await prefs.remove('prev_pos_$bookPath');
    await prefs.remove('prog_$bookPath');
    await prefs.remove('pagelbl_$bookPath');
    await prefs.remove('bm_$bookPath');
    await prefs.remove('grp_$bookPath');
    final favs = (prefs.getStringList('favorite_book_paths') ?? []).toSet();
    if (favs.remove(bookPath)) {
      await prefs.setStringList('favorite_book_paths', favs.toList());
    }
    for (final key in prefs.getKeys().toList()) {
      if (key.startsWith('bubbles_v5_${bookPath}_') ||
          key.startsWith('bubbles_v4_${bookPath}_') ||
          key.startsWith('bubbles_v3_${bookPath}_') ||
          key.startsWith('bubbles_v2_${bookPath}_') ||
          key.startsWith('bubbles_${bookPath}_') ||
          key.startsWith('memo_strokes_${bookPath}_') ||
          key.startsWith('memo_note_${bookPath}_') ||
          key.startsWith('page_strokes_${bookPath}_')) {
        await prefs.remove(key);
      }
    }
  }

}
