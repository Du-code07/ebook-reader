import 'dart:io';

import 'package:path_provider/path_provider.dart';

import 'storage_service.dart';

/// 파일 화면의 [이전 파일로 이동]·[다음 파일로 이동]이 쓰는 파일 줄
/// - 서재에서 파일을 열 때 그때 보이던 목록(그룹·정렬 그대로)을 기억해 두고 그 순서로 이동
/// - 다른 경로(연결 앱 등)로 열었으면 그 파일의 그룹을 서재 정렬 설정대로 줄 세움
/// - 줄의 처음·끝에서는 더 가지 않음 (돌아서 반대쪽 끝으로 가지 않음)
class LibraryNav {
  LibraryNav._();

  /// 서재에서 마지막으로 파일을 열 때 보이던 목록 (파일 경로, 화면 순서)
  static List<String> order = const [];

  static const supportedExts = [
    'epub', 'txt', 'pdf', 'jpg', 'jpeg', 'png', 'webp', 'cbz',
    'docx', 'doc', 'hwpx', 'hwp', 'pptx', 'ppt', 'xlsx', 'xlsm', 'xls',
  ];

  static Future<List<String>> listFor(String path) async {
    if (order.contains(path)) return order;
    final group = await StorageService.getBookGroup(path);
    final favs = await StorageService.getFavoriteBooks();
    final (by, asc, _) = await StorageService.getLibrarySort();
    final added = await StorageService.getAddedDates();
    final dir = await getApplicationDocumentsDirectory();
    final files = <String>[];
    for (final e in dir.listSync()) {
      if (e is! File) continue;
      final lower = e.path.toLowerCase();
      if (lower.endsWith('_translated.epub') || lower.endsWith('.converted.epub') || lower.endsWith('_converted.epub')) continue;
      if (!supportedExts.contains(lower.split('.').last)) continue;
      if (await StorageService.getBookGroup(e.path) == group) files.add(e.path);
    }
    String nameOf(String p) => p.split(Platform.pathSeparator).last;
    files.sort((a, b) {
      final af = favs.contains(a), bf = favs.contains(b);
      if (af != bf) return af ? -1 : 1;
      int c;
      if (by == 'date') {
        c = (added[a] ?? 0).compareTo(added[b] ?? 0);
        if (c == 0) c = naturalCompare(nameOf(a), nameOf(b));
      } else {
        c = naturalCompare(nameOf(a), nameOf(b));
      }
      return asc ? c : -c;
    });
    return files;
  }

  /// [step] -1: 이전 파일, 1: 다음 파일. 없으면 null (줄의 처음·끝, 파일이 하나뿐일 때)
  static Future<String?> neighbor(String path, int step) async {
    final list = await listFor(path);
    final i = list.indexOf(path);
    if (i < 0) return null;
    final j = i + step;
    if (j < 0 || j >= list.length) return null;
    final p = list[j];
    return File(p).existsSync() ? p : null;
  }

  static int naturalCompare(String a, String b) {
    final reg = RegExp(r'(\d+)|(\D+)');
    final ma = reg.allMatches(a.toLowerCase()).toList();
    final mb = reg.allMatches(b.toLowerCase()).toList();
    final len = ma.length < mb.length ? ma.length : mb.length;
    for (int i = 0; i < len; i++) {
      final pa = ma[i].group(0)!, pb = mb[i].group(0)!;
      final na = int.tryParse(pa), nb = int.tryParse(pb);
      final c = (na != null && nb != null) ? na.compareTo(nb) : pa.compareTo(pb);
      if (c != 0) return c;
    }
    return ma.length.compareTo(mb.length);
  }
}
