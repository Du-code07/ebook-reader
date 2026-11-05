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
  final bool isVertical;

  BubbleTranslation({
    required this.leftRatio,
    required this.topRatio,
    required this.widthRatio,
    required this.heightRatio,
    required this.originalText,
    required this.translatedText,
    this.isSerif = true,
    this.isBold = false,
    this.isVertical = true,
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
        'v': isVertical,
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
        isVertical: json['v'] ?? true,
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

  static Future<void> setTwoPageLandscape(bool enabled) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setBool('two_page_landscape', enabled);
  }

  static Future<bool> getTwoPageLandscape() async {
    final prefs = await SharedPreferences.getInstance();
    return prefs.getBool('two_page_landscape') ?? true;
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

  // 진행도 UI 위치 설정: 'right' (오른쪽), 'left' (왼쪽), 'bottom' (하단)
  static Future<void> setProgressBarPosition(String pos) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString('viewer_progress_bar_pos', pos);
  }

  static Future<String> getProgressBarPosition() async {
    final prefs = await SharedPreferences.getInstance();
    return prefs.getString('viewer_progress_bar_pos') ?? 'right';
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
    return prefs.getStringList('book_groups') ?? ['전체', '소설/문학', '만화/웹툰', 'PDF/문서'];
  }

  static Future<void> addGroup(String groupName) async {
    final prefs = await SharedPreferences.getInstance();
    final groups = await getGroups();
    if (!groups.contains(groupName)) {
      groups.add(groupName);
      await prefs.setStringList('book_groups', groups);
    }
  }

  static Future<void> removeGroup(String groupName) async {
    if (groupName == '전체') return;
    final prefs = await SharedPreferences.getInstance();
    final groups = await getGroups();
    groups.remove(groupName);
    await prefs.setStringList('book_groups', groups);
    for (final key in prefs.getKeys().toList()) {
      if (key.startsWith('grp_') && prefs.getString(key) == groupName) {
        await prefs.setString(key, '미분류');
      }
    }
  }

  static Future<void> setBookGroup(String bookPath, String groupName) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString('grp_$bookPath', groupName);
  }

  static Future<String> getBookGroup(String bookPath) async {
    final prefs = await SharedPreferences.getInstance();
    return prefs.getString('grp_$bookPath') ?? '미분류';
  }

  static Future<void> removeBookMetadata(String bookPath) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.remove('pos_$bookPath');
    await prefs.remove('prev_pos_$bookPath');
    await prefs.remove('prog_$bookPath');
    await prefs.remove('bm_$bookPath');
    await prefs.remove('grp_$bookPath');
    for (final key in prefs.getKeys().toList()) {
      if (key.startsWith('bubbles_v4_${bookPath}_') ||
          key.startsWith('bubbles_v3_${bookPath}_') ||
          key.startsWith('bubbles_v2_${bookPath}_') ||
          key.startsWith('bubbles_${bookPath}_')) {
        await prefs.remove(key);
      }
    }
  }

  static Future<void> saveImageBubbleCache(
      String bookKey, int pageIndex, List<BubbleTranslation> bubbles) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(
      'bubbles_v4_${bookKey}_$pageIndex',
      jsonEncode(bubbles.map((e) => e.toJson())).toList(),
    );
  }

  static Future<List<BubbleTranslation>?> getImageBubbleCache(
      String bookKey, int pageIndex) async {
    final prefs = await SharedPreferences.getInstance();
    final raw = prefs.getString('bubbles_v4_${bookKey}_$pageIndex');
    if (raw == null) return null;
    final List decoded = jsonDecode(raw);
    return decoded.map((e) => BubbleTranslation.fromJson(e)).toList();
  }

  static Future<void> clearImageBubbleCacheForBook(String bookKey) async {
    final prefs = await SharedPreferences.getInstance();
    for (final key in prefs.getKeys().toList()) {
      if (key.startsWith('bubbles_v4_${bookKey}_') ||
          key.startsWith('bubbles_v3_${bookKey}_') ||
          key.startsWith('bubbles_v2_${bookKey}_') ||
          key.startsWith('bubbles_${bookKey}_')) {
        await prefs.remove(key);
      }
    }
  }
}
