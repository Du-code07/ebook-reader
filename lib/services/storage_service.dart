import 'dart:convert';
import 'package:shared_preferences/shared_preferences.dart';

class BookmarkItem {
  final String id;
  final String label;
  final String position;
  final String createdAt;

  BookmarkItem({
    required this.id,
    required this.label,
    required this.position,
    required this.createdAt,
  });

  Map<String, dynamic> toJson() => {
        'id': id,
        'label': label,
        'position': position,
        'createdAt': createdAt,
      };

  factory BookmarkItem.fromJson(Map<String, dynamic> json) => BookmarkItem(
        id: json['id'] ?? '',
        label: json['label'] ?? '',
        position: json['position'] ?? '',
        createdAt: json['createdAt'] ?? '',
      );
}

class BubbleTranslation {
  final double leftRatio;
  final double topRatio;
  final double widthRatio;
  final double heightRatio;
  final String originalText;
  final String translatedText;
  final bool isSerif;
  final bool isBold;
  final bool isDarkBg;

  BubbleTranslation({
    required this.leftRatio,
    required this.topRatio,
    required this.widthRatio,
    required this.heightRatio,
    required this.originalText,
    required this.translatedText,
    this.isSerif = true,
    this.isBold = false,
    this.isDarkBg = false,
  });

  Map<String, dynamic> toJson() => {
        'l': leftRatio,
        't': topRatio,
        'w': widthRatio,
        'h': heightRatio,
        'o': originalText,
        'tr': translatedText,
        's': isSerif,
        'b': isBold,
        'd': isDarkBg,
      };

  factory BubbleTranslation.fromJson(Map<String, dynamic> json) => BubbleTranslation(
        leftRatio: (json['l'] as num).toDouble(),
        topRatio: (json['t'] as num).toDouble(),
        widthRatio: (json['w'] as num).toDouble(),
        heightRatio: (json['h'] as num).toDouble(),
        originalText: json['o'] ?? '',
        translatedText: json['tr'] ?? '',
        isSerif: json['s'] ?? true,
        isBold: json['b'] ?? false,
        isDarkBg: json['d'] ?? false,
      );
}

class MemoStroke {
  final List<double> dxList;
  final List<double> dyList;
  final int colorValue;
  final double strokeWidth;

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
        colorValue: (json['c'] as num).toInt(),
        strokeWidth: (json['w'] as num).toDouble(),
      );
}

class StorageService {
  static Future<void> saveLastPosition(String bookPath, String pos) async {
    final prefs = await SharedPreferences.getInstance();
    final prev = prefs.getString('pos_$bookPath');
    if (prev != null && prev != pos) {
      await prefs.setString('prev_pos_$bookPath', prev);
    }
    await prefs.setString('pos_$bookPath', pos);
  }

  static Future<String?> getLastPosition(String bookPath) async {
    final prefs = await SharedPreferences.getInstance();
    return prefs.getString('pos_$bookPath');
  }

  static Future<String?> getPreviousPosition(String bookPath) async {
    final prefs = await SharedPreferences.getInstance();
    return prefs.getString('prev_pos_$bookPath');
  }

  static Future<void> saveProgress(String bookPath, double progress) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setDouble('prog_$bookPath', progress);
  }

  static Future<double> getProgress(String bookPath) async {
    final prefs = await SharedPreferences.getInstance();
    return prefs.getDouble('prog_$bookPath') ?? 0.0;
  }

  static Future<void> setDarkMode(bool isDark) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setBool('app_dark_mode', isDark);
  }

  static Future<bool> getDarkMode() async {
    final prefs = await SharedPreferences.getInstance();
    return prefs.getBool('app_dark_mode') ?? false;
  }

  // EPUB 배경 테마 설정: 'white' (흰색), 'sepia' (종이색), 'dark' (다크)
  static Future<void> setEpubBgTheme(String theme) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString('epub_bg_theme', theme);
  }

  static Future<String> getEpubBgTheme() async {
    final prefs = await SharedPreferences.getInstance();
    return prefs.getString('epub_bg_theme') ?? 'white';
  }

  static Future<void> setTwoPageLandscape(bool enabled) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setBool('two_page_landscape', enabled);
  }

  static Future<bool> getTwoPageLandscape() async {
    final prefs = await SharedPreferences.getInstance();
    return prefs.getBool('two_page_landscape') ?? true;
  }

  // 3. 넘김 방향 전환 상태 기억 (기본값: 왼쪽 -> 오른쪽 false)
  static Future<void> setReadingDirectionRtl(bool isRtl) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setBool('viewer_reading_rtl', isRtl);
  }

  static Future<bool> getReadingDirectionRtl() async {
    final prefs = await SharedPreferences.getInstance();
    return prefs.getBool('viewer_reading_rtl') ?? false;
  }

  // 7. 페이지 전환 설정 3가지 (음량 버튼, 화면 이동 버튼, S펜 버튼 - 3개 동시 사용 가능)
  static Future<void> setUseVolumeTurn(bool enabled) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setBool('turn_use_volume', enabled);
  }

  static Future<bool> getUseVolumeTurn() async {
    final prefs = await SharedPreferences.getInstance();
    return prefs.getBool('turn_use_volume') ?? true;
  }

  static Future<void> setUseQuickNavTurn(bool enabled) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setBool('turn_use_quick_nav', enabled);
  }

  static Future<bool> getUseQuickNavTurn() async {
    final prefs = await SharedPreferences.getInstance();
    return prefs.getBool('turn_use_quick_nav') ?? false;
  }

  static Future<void> setUseSpenTurn(bool enabled) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setBool('turn_use_spen', enabled);
  }

  static Future<bool> getUseSpenTurn() async {
    final prefs = await SharedPreferences.getInstance();
    return prefs.getBool('turn_use_spen') ?? true;
  }

  // 뷰어 하단 정보 표시 설정: 'progress' (진행률), 'page' (페이지 번호), 'both' (진행률 및 페이지 번호), 'none' (정보 표시 없음)
  static Future<void> setFooterInfoMode(String mode) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString('viewer_footer_info_mode', mode);
  }

  static Future<String> getFooterInfoMode() async {
    final prefs = await SharedPreferences.getInstance();
    return prefs.getString('viewer_footer_info_mode') ?? 'both';
  }

  // 8. 진행도 UI 위치 설정: 'right' (오른쪽), 'left' (왼쪽), 'bottom' (하단), 'hidden' (숨김)
  static Future<void> setProgressBarPosition(String pos) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString('viewer_progress_bar_pos', pos);
  }

  static Future<String> getProgressBarPosition() async {
    final prefs = await SharedPreferences.getInstance();
    return prefs.getString('viewer_progress_bar_pos') ?? 'right';
  }

  // 6. S펜 간단 메모(필기 스트로크 및 텍스트 노트) 저장/조회
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

  static Future<void> savePageMemoNote(String bookKey, int pageIndex, String note) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString('memo_note_${bookKey}_$pageIndex', note);
  }

  static Future<String> getPageMemoNote(String bookKey, int pageIndex) async {
    final prefs = await SharedPreferences.getInstance();
    return prefs.getString('memo_note_${bookKey}_$pageIndex') ?? '';
  }

  // 3. EPUB 각 페이지(CFI 위치)별 독립 필기 저장/조회 (페이지를 넘기면 해당 페이지 필기만 표시!)
  static Future<void> saveEpubLocationStrokes(
      String bookKey, String locationKey, List<MemoStroke> strokes) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(
      'epub_strokes_${bookKey}_$locationKey',
      jsonEncode(strokes.map((e) => e.toJson()).toList()),
    );
  }

  static Future<List<MemoStroke>> getEpubLocationStrokes(
      String bookKey, String locationKey) async {
    final prefs = await SharedPreferences.getInstance();
    final raw = prefs.getString('epub_strokes_${bookKey}_$locationKey');
    if (raw == null) return [];
    final List decoded = jsonDecode(raw);
    return decoded.map((e) => MemoStroke.fromJson(e)).toList();
  }

  static Future<void> setGugugoApiConfig({required String serverUrl, required String hfToken}) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString('gugugo_server_url', serverUrl.trim());
    await prefs.setString('gugugo_hf_token', hfToken.trim());
  }

  static Future<String> getGugugoServerUrl() async {
    final prefs = await SharedPreferences.getInstance();
    return prefs.getString('gugugo_server_url') ?? '';
  }

  static Future<String> getGugugoHfToken() async {
    final prefs = await SharedPreferences.getInstance();
    return prefs.getString('gugugo_hf_token') ?? '';
  }

  static Future<List<BookmarkItem>> getBookmarks(String bookPath) async {
    final prefs = await SharedPreferences.getInstance();
    final raw = prefs.getStringList('bm_$bookPath') ?? [];
    return raw.map((e) => BookmarkItem.fromJson(jsonDecode(e))).toList();
  }

  static Future<void> addBookmark(String bookPath, BookmarkItem item) async {
    final prefs = await SharedPreferences.getInstance();
    final list = await getBookmarks(bookPath);
    list.insert(0, item);
    await prefs.setStringList(
      'bm_$bookPath',
      list.map((e) => jsonEncode(e.toJson())).toList(),
    );
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

  static Future<List<String>> getGroups() async {
    final prefs = await SharedPreferences.getInstance();
    return prefs.getStringList('book_groups_v2') ?? ['전체', 'PDF/문서'];
  }

  static Future<void> addGroup(String groupName) async {
    final prefs = await SharedPreferences.getInstance();
    final groups = await getGroups();
    if (!groups.contains(groupName)) {
      groups.add(groupName);
      await prefs.setStringList('book_groups_v2', groups);
    }
  }

  static Future<void> removeGroup(String groupName) async {
    if (groupName == '전체') return;
    final prefs = await SharedPreferences.getInstance();
    final groups = await getGroups();
    groups.remove(groupName);
    await prefs.setStringList('book_groups_v2', groups);
    for (final key in prefs.getKeys().toList()) {
      if (key.startsWith('grp_') && prefs.getString(key) == groupName) {
        await prefs.setString(key, 'PDF/문서');
      }
    }
  }

  static Future<void> migrateBookMetadata(String oldPath, String newPath) async {
    if (oldPath == newPath) return;
    final prefs = await SharedPreferences.getInstance();
    for (final prefix in ['pos_', 'prev_pos_', 'prog_', 'grp_']) {
      final val = prefs.get('$prefix$oldPath');
      if (val != null) {
        if (val is String) await prefs.setString('$prefix$newPath', val);
        if (val is double) await prefs.setDouble('$prefix$newPath', val);
        await prefs.remove('$prefix$oldPath');
      }
    }
    final bms = prefs.getStringList('bm_$oldPath');
    if (bms != null) {
      await prefs.setStringList('bm_$newPath', bms);
      await prefs.remove('bm_$oldPath');
    }
    for (final key in prefs.getKeys().toList()) {
      for (final prefix in [
        'bubbles_v5_',
        'memo_strokes_',
        'memo_note_',
        'epub_strokes_',
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

  static Future<void> setBookGroup(String bookPath, String groupName) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString('grp_$bookPath', groupName);
  }

  static Future<String> getBookGroup(String bookPath) async {
    final prefs = await SharedPreferences.getInstance();
    return prefs.getString('grp_$bookPath') ?? 'PDF/문서';
  }

  static Future<void> removeBookMetadata(String bookPath) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.remove('pos_$bookPath');
    await prefs.remove('prev_pos_$bookPath');
    await prefs.remove('prog_$bookPath');
    await prefs.remove('bm_$bookPath');
    await prefs.remove('grp_$bookPath');
    for (final key in prefs.getKeys().toList()) {
      if (key.startsWith('bubbles_v5_${bookPath}_') ||
          key.startsWith('bubbles_v4_${bookPath}_') ||
          key.startsWith('bubbles_v3_${bookPath}_') ||
          key.startsWith('bubbles_v2_${bookPath}_') ||
          key.startsWith('bubbles_${bookPath}_') ||
          key.startsWith('memo_strokes_${bookPath}_') ||
          key.startsWith('memo_note_${bookPath}_')) {
        await prefs.remove(key);
      }
    }
  }

  static Future<void> saveImageBubbleCache(
      String bookKey, int pageIndex, List<BubbleTranslation> bubbles) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(
      'bubbles_v5_${bookKey}_$pageIndex',
      jsonEncode(bubbles.map((e) => e.toJson()).toList()),
    );
  }

  static Future<List<BubbleTranslation>?> getImageBubbleCache(
      String bookKey, int pageIndex) async {
    final prefs = await SharedPreferences.getInstance();
    final raw = prefs.getString('bubbles_v5_${bookKey}_$pageIndex');
    if (raw == null) return null;
    final List decoded = jsonDecode(raw);
    return decoded.map((e) => BubbleTranslation.fromJson(e)).toList();
  }

  static Future<void> clearImageBubbleCacheForBook(String bookKey) async {
    final prefs = await SharedPreferences.getInstance();
    for (final key in prefs.getKeys().toList()) {
      if (key.startsWith('bubbles_v5_${bookKey}_') ||
          key.startsWith('bubbles_v4_${bookKey}_') ||
          key.startsWith('bubbles_v3_${bookKey}_') ||
          key.startsWith('bubbles_v2_${bookKey}_') ||
          key.startsWith('bubbles_${bookKey}_')) {
        await prefs.remove(key);
      }
    }
  }
}
