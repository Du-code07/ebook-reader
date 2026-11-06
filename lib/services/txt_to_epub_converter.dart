import 'dart:convert';
import 'dart:io';
import 'package:archive/archive.dart';
import 'package:path_provider/path_provider.dart';

class TxtToEpubConverter {
  static String _escapeXml(String input) {
    return input
        .replaceAll('&', '&amp;')
        .replaceAll('<', '&lt;')
        .replaceAll('>', '&gt;')
        .replaceAll('"', '&quot;')
        .replaceAll("'", '&apos;');
  }

  /// 11. 삼성 노트(.sdocx, .spd)에서 페이지 이미지가 있으면 추출하여 반환하고, 없으면 빈 리스트 반환
  static Future<List<File>> extractSamsungNoteImagesIfPresent(File file) async {
    try {
      final bytes = await file.readAsBytes();
      final archive = ZipDecoder().decodeBytes(bytes);
      final tempDir = await getTemporaryDirectory();
      final outDir = Directory('${tempDir.path}/sdoc_img_${file.path.hashCode.abs()}');
      await outDir.create(recursive: true);

      final extracted = <File>[];
      int idx = 0;
      for (final f in archive.files) {
        if (!f.isFile) continue;
        final lower = f.name.toLowerCase();
        if (lower.endsWith('.png') || lower.endsWith('.jpg') || lower.endsWith('.jpeg')) {
          // 작은 아이콘이나 썸네일 제외 (일정 크기 이상 페이지 이미지만 추출)
          final content = f.content as List<int>;
          if (content.length > 4096) {
            final ext = lower.split('.').last;
            final outFile = File('${outDir.path}/page_${idx.toString().padLeft(4, '0')}.$ext');
            await outFile.writeAsBytes(content);
            extracted.add(outFile);
            idx++;
          }
        }
      }
      return extracted;
    } catch (_) {
      return [];
    }
  }

  /// Word(.docx, .doc), 한글(.hwpx, .hwp), 삼성 노트(.sdocx, .spd), 텍스트(.txt) 파일을
  /// 모두 정식 EPUB 문서로 자동 변환하여 뷰어에서 열람할 수 있게 합니다!
  static Future<File> convertDocumentToEpub(File sourceFile) async {
    final ext = sourceFile.path.split('.').last.toLowerCase();
    if (ext == 'txt') {
      return convertTxtToEpub(sourceFile);
    }

    final outPath = '${sourceFile.path}.converted.epub';
    final outFile = File(outPath);
    if (await outFile.exists() && await outFile.length() > 0) {
      return outFile;
    }

    final fileName = sourceFile.path.split(Platform.pathSeparator).last;
    final List<String> paragraphs = await _extractParagraphsFromOfficeOrNote(sourceFile, ext);

    return _buildEpubFromParagraphs(
      outFile: outFile,
      title: fileName,
      paragraphs: paragraphs.isEmpty
          ? ['문서 내용을 불러왔습니다. ($fileName)', '텍스트 레이어가 없거나 이미지 기반 문서일 수 있습니다.']
          : paragraphs,
    );
  }

  static Future<List<String>> _extractParagraphsFromOfficeOrNote(File file, String ext) async {
    final bytes = await file.readAsBytes();
    final List<String> lines = [];

    // 1. ZIP 기반 문서 포맷 (.docx, .hwpx, .sdocx, .spd)
    if (ext == 'docx' || ext == 'hwpx' || ext == 'sdocx' || ext == 'spd') {
      try {
        final archive = ZipDecoder().decodeBytes(bytes);
        for (final entry in archive.files) {
          if (!entry.isFile) continue;
          final name = entry.name.toLowerCase();

          // MS Word: word/document.xml
          if (ext == 'docx' && name == 'word/document.xml') {
            final xml = utf8.decode(entry.content as List<int>, allowMalformed: true);
            final pMatches = RegExp(r'<w:p[\s>][\s\S]*?</w:p>').allMatches(xml);
            for (final pm in pMatches) {
              final pXml = pm.group(0) ?? '';
              final tMatches = RegExp(r'<w:t[^>]*>([\s\S]*?)</w:t>').allMatches(pXml);
              final buf = StringBuffer();
              for (final tm in tMatches) {
                buf.write(tm.group(1) ?? '');
              }
              final clean = _unescapeXmlEntities(buf.toString()).trim();
              if (clean.isNotEmpty) lines.add(clean);
            }
          }

          // 한컴 한글 OWPML: Contents/section*.xml 또는 PrvText.txt
          if (ext == 'hwpx' && (name.contains('section') && name.endsWith('.xml'))) {
            final xml = utf8.decode(entry.content as List<int>, allowMalformed: true);
            final tMatches = RegExp(r'<hp:t[^>]*>([\s\S]*?)</hp:t>').allMatches(xml);
            for (final tm in tMatches) {
              final clean = _unescapeXmlEntities(tm.group(1) ?? '').trim();
              if (clean.isNotEmpty) lines.add(clean);
            }
          } else if (name.endsWith('prvtext.txt') || name.endsWith('.txt')) {
            final txt = utf8.decode(entry.content as List<int>, allowMalformed: true);
            for (final l in txt.split(RegExp(r'\r?\n'))) {
              if (l.trim().isNotEmpty) lines.add(l.trim());
            }
          }

          // 삼성 노트 (.sdocx, .spd) 내부 XML/JSON/텍스트 추출
          if ((ext == 'sdocx' || ext == 'spd') &&
              (name.endsWith('.xml') || name.endsWith('.json') || name.endsWith('.txt'))) {
            final raw = utf8.decode(entry.content as List<int>, allowMalformed: true);
            final stripped = raw
                .replaceAll(RegExp(r'<[^>]+>'), '\n')
                .split(RegExp(r'\r?\n'))
                .map((s) => s.trim())
                .where((s) => s.length >= 2 && !s.startsWith('{') && !s.startsWith('http'))
                .toList();
            lines.addAll(stripped);
          }
        }
      } catch (_) {}
    }

    // 2. 구형 바이너리 포맷 (.hwp, .doc) 또는 위에서 텍스트가 추출되지 않은 경우 UTF-16LE 및 UTF-8 가독 문자열 추출
    if (lines.isEmpty) {
      lines.addAll(_extractReadableStringsFromBinary(bytes));
    }

    return lines;
  }

  static List<String> _extractReadableStringsFromBinary(List<int> bytes) {
    final result = <String>[];
    // UTF-16LE 한글/영문/일본어/한자 연속 문자열 추출 (.hwp PrvText 및 .doc 유니코드 스트림 호환)
    final buf = StringBuffer();
    for (int i = 0; i + 1 < bytes.length; i += 2) {
      final code = bytes[i] | (bytes[i + 1] << 8);
      final isKorean = code >= 0xAC00 && code <= 0xD7A3;
      final isJamo = code >= 0x3131 && code <= 0x318E;
      final isCjk = code >= 0x3040 && code <= 0x9FFF;
      final isAsciiPrintable = (code >= 0x20 && code <= 0x7E) || code == 0x0A || code == 0x0D;

      if (isKorean || isJamo || isCjk || isAsciiPrintable) {
        buf.writeCharCode(code);
      } else {
        if (buf.length >= 4) {
          final s = buf.toString().trim();
          if (RegExp(r'[가-힣a-zA-Z0-9\u3040-\u9FFF]{2,}').hasMatch(s)) {
            for (final line in s.split(RegExp(r'\r?\n'))) {
              final t = line.trim();
              if (t.length >= 2) result.add(t);
            }
          }
        }
        buf.clear();
      }
    }
    if (buf.length >= 4) {
      final s = buf.toString().trim();
      for (final line in s.split(RegExp(r'\r?\n'))) {
        final t = line.trim();
        if (t.length >= 2) result.add(t);
      }
    }

    if (result.isEmpty) {
      final utf8Str = utf8.decode(bytes, allowMalformed: true);
      for (final line in utf8Str.split(RegExp(r'\r?\n'))) {
        final clean = line.replaceAll(RegExp(r'[^\x20-\x7E가-힣ㄱ-ㅎㅏ-ㅣ\u3040-\u9FFF]'), '').trim();
        if (clean.length >= 3) {
          result.add(clean);
        }
      }
    }
    return result;
  }

  static String _unescapeXmlEntities(String input) {
    return input
        .replaceAll('&lt;', '<')
        .replaceAll('&gt;', '>')
        .replaceAll('&quot;', '"')
        .replaceAll('&apos;', "'")
        .replaceAll('&amp;', '&');
  }

  static Future<File> convertTxtToEpub(File txtFile) async {
    final outPath = '${txtFile.path}.converted.epub';
    final outFile = File(outPath);
    if (await outFile.exists() && await outFile.length() > 0) {
      return outFile;
    }

    final rawContent = await txtFile.readAsString();
    final title = txtFile.path.split(Platform.pathSeparator).last.replaceAll('.txt', '');
    final lines = rawContent.split(RegExp(r'\r?\n'));

    return _buildEpubFromParagraphs(
      outFile: outFile,
      title: title,
      paragraphs: lines,
    );
  }

  static Future<File> _buildEpubFromParagraphs({
    required File outFile,
    required String title,
    required List<String> paragraphs,
  }) async {
    final safeTitle = _escapeXml(title);
    final archive = Archive();

    final mimetypeBytes = utf8.encode('application/epub+zip');
    archive.addFile(ArchiveFile.noCompress('mimetype', mimetypeBytes.length, mimetypeBytes));

    const containerXml = '''<?xml version="1.0" encoding="UTF-8"?>
<container version="1.0" xmlns="urn:oasis:names:tc:opendocument:xmlns:container">
  <rootfiles>
    <rootfile full-path="OEBPS/content.opf" media-type="application/oebps-package+xml"/>
  </rootfiles>
</container>''';
    final containerBytes = utf8.encode(containerXml);
    archive.addFile(ArchiveFile('META-INF/container.xml', containerBytes.length, containerBytes));

    final bodyBuf = StringBuffer();
    for (final line in paragraphs) {
      final trimmed = line.trim();
      if (trimmed.isEmpty) {
        bodyBuf.writeln('<p>&#160;</p>');
      } else {
        bodyBuf.writeln('<p>${_escapeXml(trimmed)}</p>');
      }
    }

    final chapterXhtml = '''<?xml version="1.0" encoding="utf-8"?>
<!DOCTYPE html>
<html xmlns="http://www.w3.org/1999/xhtml">
<head>
  <title>$safeTitle</title>
  <style type="text/css">
    body { font-family: sans-serif; line-height: 1.75; padding: 4%; word-break: keep-all; }
    p { margin: 0.45em 0; text-indent: 0.5em; }
  </style>
</head>
<body>
  <h2>$safeTitle</h2>
  ${bodyBuf.toString()}
</body>
</html>''';
    final chapterBytes = utf8.encode(chapterXhtml);
    archive.addFile(ArchiveFile('OEBPS/chapter1.xhtml', chapterBytes.length, chapterBytes));

    final contentOpf = '''<?xml version="1.0" encoding="utf-8"?>
<package xmlns="http://www.idpf.org/2007/opf" unique-identifier="BookId" version="2.0">
  <metadata xmlns:dc="http://purl.org/dc/elements/1.1/">
    <dc:title>$safeTitle</dc:title>
    <dc:language>ko</dc:language>
    <dc:identifier id="BookId">urn:uuid:${DateTime.now().millisecondsSinceEpoch}</dc:identifier>
  </metadata>
  <manifest>
    <item id="ncx" href="toc.ncx" media-type="application/x-dtbncx+xml"/>
    <item id="chapter1" href="chapter1.xhtml" media-type="application/xhtml+xml"/>
  </manifest>
  <spine toc="ncx">
    <itemref idref="chapter1"/>
  </spine>
</package>''';
    final opfBytes = utf8.encode(contentOpf);
    archive.addFile(ArchiveFile('OEBPS/content.opf', opfBytes.length, opfBytes));

    final tocNcx = '''<?xml version="1.0" encoding="UTF-8"?>
<ncx xmlns="http://www.daisy.org/z3986/2005/ncx/" version="2.0">
  <head><meta name="dtb:uid" content="1"/></head>
  <docTitle><text>$safeTitle</text></docTitle>
  <navMap>
    <navPoint id="navPoint-1" playOrder="1">
      <navLabel><text>$safeTitle</text></navLabel>
      <content src="chapter1.xhtml"/>
    </navPoint>
  </navMap>
</ncx>''';
    final ncxBytes = utf8.encode(tocNcx);
    archive.addFile(ArchiveFile('OEBPS/toc.ncx', ncxBytes.length, ncxBytes));

    final zipBytes = ZipEncoder().encode(archive);
    await outFile.writeAsBytes(zipBytes!);
    return outFile;
  }
}
