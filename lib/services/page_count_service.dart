import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:isolate';

import 'package:archive/archive_io.dart';
import 'package:flutter/services.dart';
import 'package:path_provider/path_provider.dart';

import 'doc_thumbnail_service.dart';
import 'storage_service.dart';
import 'txt_page_document.dart';

/// 서재: 열어 보지 않은 파일도 전체 쪽 수를 세어 쪽 표시 자리에 '1/전체'로 보여 줌.
/// 한 번 연 파일은 읽던 쪽('지금/전체')이 이미 있으므로 건드리지 않음
class PageCountService {
  static const MethodChannel _native = MethodChannel('ebook_reader/pdf_renderer');
  static Future<void> _queue = Future<void>.value();
  static final Set<String> _tried = {}; // 앱을 켠 동안 한 번만 셈 (못 센 파일을 계속 다시 세지 않게)

  /// 쪽 표시가 없는 파일이면 전체 쪽 수를 세어 '1/전체'로 저장. 새로 저장했으면 그 표시를 돌려줌
  static Future<String?> ensureLabel(String path) {
    if (!_tried.add(path)) return Future<String?>.value(null);
    final done = Completer<String?>();
    // 무거운 일은 하나씩 (서재를 쓰는 동안 기기가 버벅이지 않게)
    _queue = _queue.then((_) async {
      String? label;
      try {
        if (await StorageService.getPageLabel(path) == null) {
          final int? n = await count(path);
          if (n != null && n > 0 && await StorageService.getPageLabel(path) == null) {
            label = '1/$n';
            await StorageService.savePageLabel(path, label);
          }
        }
      } catch (_) {}
      done.complete(label);
    });
    return done.future;
  }

  /// 전체 쪽 수 (뷰어에 나오는 수와 같은 방식). 모르면 null
  static Future<int?> count(String path) async {
    if (!File(path).existsSync()) return null;
    final String ext = path.split('.').last.toLowerCase();
    switch (ext) {
      case 'pdf':
        return await _native.invokeMethod<int>('pdfPageCount', {'filePath': path});
      case 'cbz':
        return await Isolate.run(() => _cbzPages(path));
      case 'epub':
        // EPUB은 글이 화면에 따라 다시 흐르므로 뷰어와 같은 어림셈 (목차 장 수 × 10, 목차가 없으면 100)
        final int chapters = await Isolate.run(() => _epubChapters(path));
        return chapters > 0 ? chapters * 10 : 100;
      case 'txt':
        // TXT는 정해진 종이 크기로 쪽을 나누므로 화면과 관계없이 같은 수
        final doc = await TxtPageDocument.open(File(path), await getTemporaryDirectory());
        final int n = doc.pageCount;
        await doc.dispose();
        return n;
      default:
        // 한글·워드·PPT·엑셀: 문서 뷰어와 같은 엔진으로 셈
        return await DocThumbnailService.pageCount(path);
    }
  }

  static bool _isPageImage(ArchiveFile f) {
    final String lower = f.name.toLowerCase();
    return f.isFile &&
        !lower.contains('__macosx') &&
        !f.name.split('/').last.startsWith('._') &&
        (lower.endsWith('.jpg') || lower.endsWith('.jpeg') || lower.endsWith('.png') || lower.endsWith('.webp'));
  }

  static int? _cbzPages(String path) {
    final input = InputFileStream(path);
    try {
      return ZipDecoder().decodeBuffer(input).files.where(_isPageImage).length;
    } finally {
      input.closeSync();
    }
  }

  /// EPUB 목차의 맨 위 장 수 (뷰어가 쓰는 목차와 같은 것: EPUB3 nav 문서, 없으면 toc.ncx)
  static int _epubChapters(String path) {
    final input = InputFileStream(path);
    try {
      final archive = ZipDecoder().decodeBuffer(input);
      String? read(String name) {
        final f = archive.findFile(name);
        if (f == null || !f.isFile) return null;
        return utf8.decode(f.content as List<int>, allowMalformed: true);
      }

      final container = read('META-INF/container.xml');
      final String? opfPath = container == null ? null : RegExp(r'''full-path\s*=\s*["']([^"']+)["']''').firstMatch(container)?.group(1);
      final opf = opfPath == null ? null : read(opfPath);
      if (opf == null) return 0;
      final String base = opfPath!.contains('/') ? opfPath.substring(0, opfPath.lastIndexOf('/') + 1) : '';
      String resolve(String href) => Uri.decodeFull(base + href.split('#').first);
      final items = RegExp(r'<item\b[^>]*>', caseSensitive: false).allMatches(opf).map((m) => m.group(0)!).toList();
      String? attr(String tag, String name) => RegExp('\\b$name\\s*=\\s*["\']([^"\']*)["\']', caseSensitive: false).firstMatch(tag)?.group(1);

      // EPUB3 nav 문서: <nav epub:type="toc"> 바로 아래 <ol>의 <li> 수
      final nav = items.where((t) => (attr(t, 'properties') ?? '').split(RegExp(r'\s+')).contains('nav')).firstOrNull;
      if (nav != null) {
        final href = attr(nav, 'href');
        final html = href == null ? null : read(resolve(href));
        if (html != null) {
          final tocNav = RegExp(r'''<nav\b[^>]*epub:type\s*=\s*["'][^"']*\btoc\b[^"']*["'][^>]*>([\s\S]*?)</nav>''', caseSensitive: false).firstMatch(html);
          final int n = tocNav == null ? 0 : _topLevel(tocNav.group(1)!, 'ol', 'li');
          if (n > 0) return n;
        }
      }
      // EPUB2 toc.ncx: <navMap> 바로 아래 <navPoint> 수
      final spineToc = RegExp(r'<spine\b[^>]*\btoc\s*=\s*["' "'" r']([^"' "'" r']+)', caseSensitive: false).firstMatch(opf)?.group(1);
      String? ncxHref;
      for (final t in items) {
        if ((spineToc != null && attr(t, 'id') == spineToc) || (attr(t, 'media-type') ?? '').contains('dtbncx')) {
          ncxHref = attr(t, 'href');
          break;
        }
      }
      final ncx = ncxHref == null ? null : read(resolve(ncxHref));
      if (ncx == null) return 0;
      final navMap = RegExp(r'<navMap\b[^>]*>([\s\S]*?)</navMap>', caseSensitive: false).firstMatch(ncx);
      return navMap == null ? 0 : _topLevel('<navMap>${navMap.group(1)!}</navMap>', 'navMap', 'navPoint');
    } catch (_) {
      return 0;
    } finally {
      input.closeSync();
    }
  }

  /// [html]에서 첫 [list] 태그 바로 아래 [item] 태그 수 (안쪽 항목은 세지 않음)
  static int _topLevel(String html, String list, String item) {
    final tags = RegExp('<(/?)($list|$item)\\b[^>]*?(/?)>', caseSensitive: false).allMatches(html);
    int depth = 0, open = 0, count = 0;
    bool started = false;
    for (final m in tags) {
      final bool close = m.group(1) == '/', self = m.group(3) == '/';
      if (m.group(2)!.toLowerCase() == list.toLowerCase()) {
        if (close) {
          depth--;
          if (started && depth == 0) break;
        } else if (!self) {
          depth++;
          started = true;
        }
      } else if (close) {
        if (open > 0) open--;
      } else if (started) {
        if (depth == 1 && open == 0) count++;
        if (!self) open++;
      }
    }
    return count;
  }
}
