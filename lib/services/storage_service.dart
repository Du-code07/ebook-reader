import 'dart:convert';
import 'package:shared_preferences/shared_preferences.dart';

class BookmarkItem {
  final String id;
  final String label;
  final String position; // CFI for EPUB, page index for PDF/Image
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

  BubbleTranslation({
    required this.leftRatio,
    required this.topRatio,
    required this.widthRatio,
    required this.heightRatio,
    required this.originalText,
    required this.translatedText,
    this.isSerif = false,
  });

  Map<String, dynamic> toJson() => {
        'l': leftRatio,
        't': topRatio,
        'w': widthRatio,
        'h': heightRatio,
        'o': originalText,
        'tr': translatedText,
        's': isSerif,
      };

  factory BubbleTranslation.fromJson(Map<String, dynamic> json) => BubbleTranslation(
        leftRatio: (json['l'] as num).toDouble(),
        topRatio: (json['t'] as num).toDouble(),
        widthRatio: (json['w'] as num).toDouble(),
        heightRatio: (json['h'] as num).toDouble(),
        originalText: json['o'] ?? '',
        translatedText: json['tr'] ?? '',
        isSerif: json['s'] ?? false,
      );
}

class StorageService {
  // 1. 마지막 읽은 위치 및 이전 위치 히스토리 (읽었던 페이지로 돌아가기)
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

  // 2. 진행률(%) 저장
  static Future<void> saveProgress(String bookPath, double progress) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setDouble('prog_$bookPath', progress);
  }

  static Future<double> getProgress(String bookPath) async {
    final prefs = await SharedPreferences.getInstance();
    return prefs.getDouble('prog_$bookPath') ?? 0.0;
  }

  // 3. 누적 읽은 시간(초) 저장 및 포맷팅
  static Future<void> addReadingSeconds(String bookPath, int deltaSeconds) async {
    final prefs = await SharedPreferences.getInstance();
    final current = prefs.getInt('time_$bookPath') ?? 0;
    await prefs.setInt('time_$bookPath', current + deltaSeconds);
  }

  static Future<int> getReadingSeconds(String bookPath) async {
    final prefs = await SharedPreferences.getInstance();
    return prefs.getInt('time_$bookPath') ?? 0;
  }

  static String formatReadingTime(int totalSeconds) {
    final hours = totalSeconds ~/ 3600;
    final minutes = (totalSeconds % 3600) ~/ 60;
    final seconds = totalSeconds % 60;
    if (hours > 0) {
      return '${hours}시간 ${minutes}분';
    } else if (minutes > 0) {
      return '${minutes}분 ${seconds}초';
    }
    return '${seconds}초';
  }

  // 4. 북마크 관리 (추가 / 조회 / 삭제)
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

  // 5. 파일 그룹화 (카테고리/폴더 관리)
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

  static Future<void> setBookGroup(String bookPath, String groupName) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString('grp_$bookPath', groupName);
  }

  static Future<String> getBookGroup(String bookPath) async {
    final prefs = await SharedPreferences.getInstance();
    return prefs.getString('grp_$bookPath') ?? '미분류';
  }

  // 6. 사전 전체 번역(Pre-translation) 말풍선 캐시 저장
  static Future<void> saveImageBubbleCache(
      String bookKey, int pageIndex, List<BubbleTranslation> bubbles) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(
      'bubbles_${bookKey}_$pageIndex',
      jsonEncode(bubbles.map((e) => e.toJson()).toList()),
    );
  }

  static Future<List<BubbleTranslation>?> getImageBubbleCache(
      String bookKey, int pageIndex) async {
    final prefs = await SharedPreferences.getInstance();
    final raw = prefs.getString('bubbles_${bookKey}_$pageIndex');
    if (raw == null) return null;
    final List decoded = jsonDecode(raw);
    return decoded.map((e) => BubbleTranslation.fromJson(e)).toList();
  }
}
