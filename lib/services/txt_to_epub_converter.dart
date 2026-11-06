import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';
import 'package:archive/archive.dart';
import 'package:flutter/services.dart';

class TxtToEpubConverter {
  static const MethodChannel _pdfAndDocChannel = MethodChannel('ebook_reader/pdf_renderer');

  static String _escapeXml(String input) {
    return input
        .replaceAll('&', '&amp;')
        .replaceAll('<', '&lt;')
        .replaceAll('>', '&gt;')
        .replaceAll('"', '&quot;')
        .replaceAll("'", '&apos;');
  }

  /// Word(.docx, .doc), 한글(.hwpx, .hwp), 텍스트(.txt) 파일을 정식 EPUB으로 변환하여 열람
  static Future<File> convertDocumentToEpub(File sourceFile) async {
    final ext = sourceFile.path.split('.').last.toLowerCase();
    if (ext == 'txt') {
      return convertTxtToEpub(sourceFile);
    }

    // 캐시 버전 키를 v2로 분리하여 이전 깨진 캐시가 절대 재사용되지 않도록 보장
    final outPath = '${sourceFile.path}.v2.converted.epub';
    final outFile = File(outPath);
    if (await outFile.exists() && await outFile.length() > 0) {
      return outFile;
    }

    final fileName = sourceFile.path.split(Platform.pathSeparator).last;
    final List<String> paragraphs = await _extractParagraphsFromDocument(sourceFile, ext);

    return _buildEpubFromParagraphs(
      outFile: outFile,
      title: fileName,
      paragraphs: paragraphs.isEmpty
          ? ['문서 내용을 불러왔습니다. ($fileName)', '표시할 텍스트 본문이 없거나 이미지 전용 문서입니다.']
          : paragraphs,
    );
  }

  static Future<List<String>> _extractParagraphsFromDocument(File file, String ext) async {
    final List<String> lines = [];

    // 1. 한컴 한글 HWP 5.0 (.hwp):
    //    (1) Android 네이티브 오픈소스 HWP 파서(kr.dogfoot:hwplib, Apache-2.0) 호출
    //    (2) 폴백으로 rhwp/hop(MIT 라이선스) 규격의 OLE2 Compound File + Deflate + HWPTAG_PARA_TEXT(Tag 67) 파서 실행
    if (ext == 'hwp') {
      try {
        final String? nativeText = await _pdfAndDocChannel.invokeMethod<String>(
          'extractHwpText',
          {'hwpPath': file.path},
        );
        if (nativeText != null && nativeText.trim().isNotEmpty) {
          for (final l in nativeText.split(RegExp(r'\r?\n'))) {
            final trimmed = l.trim();
            if (trimmed.isNotEmpty) {
              lines.add(trimmed);
            }
          }
          if (lines.isNotEmpty) return lines;
        }
      } catch (_) {}

      try {
        final bytes = await file.readAsBytes();
        // 만약 확장자만 .hwp이고 실제로는 ZIP(HWPX)인 경우 처리
        if (bytes.length >= 4 && bytes[0] == 0x50 && bytes[1] == 0x4B) {
          lines.addAll(_extractHwpxFromBytes(bytes));
          if (lines.isNotEmpty) return lines;
        }
        // OLE2 Compound File (0xD0CF11E0A1B11AE1) HWP 5.0 정밀 파싱
        final oleLines = _parseHwp5OleCompoundFile(Uint8List.fromList(bytes));
        if (oleLines.isNotEmpty) return oleLines;
      } catch (_) {}
    }

    final bytes = await file.readAsBytes();

    // 2. ZIP 기반 오픈 문서 포맷 (.docx, .hwpx)
    if (ext == 'docx' || ext == 'hwpx') {
      try {
        if (ext == 'hwpx') {
          final hwpxLines = _extractHwpxFromBytes(bytes);
          if (hwpxLines.isNotEmpty) return hwpxLines;
        }
        final archive = ZipDecoder().decodeBytes(bytes);
        for (final entry in archive.files) {
          if (!entry.isFile) continue;
          final name = entry.name.toLowerCase();

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
        }
      } catch (_) {}
    }

    if (lines.isEmpty) {
      lines.addAll(_extractReadableStringsFromBinary(bytes));
    }

    return lines;
  }

  static List<String> _extractHwpxFromBytes(List<int> bytes) {
    final lines = <String>[];
    final archive = ZipDecoder().decodeBytes(bytes);
    final sectionEntries = archive.files
        .where((e) => e.isFile && e.name.toLowerCase().contains('section') && e.name.toLowerCase().endsWith('.xml'))
        .toList()
      ..sort((a, b) => a.name.compareTo(b.name));

    for (final entry in sectionEntries) {
      final xml = utf8.decode(entry.content as List<int>, allowMalformed: true);
      final pMatches = RegExp(r'<hp:p[\s>][\s\S]*?</hp:p>').allMatches(xml);
      if (pMatches.isNotEmpty) {
        for (final pm in pMatches) {
          final pXml = pm.group(0) ?? '';
          final tMatches = RegExp(r'<hp:t[^>]*>([\s\S]*?)</hp:t>').allMatches(pXml);
          final buf = StringBuffer();
          for (final tm in tMatches) {
            buf.write(_unescapeXmlEntities(tm.group(1) ?? ''));
          }
          final clean = buf.toString().trim();
          if (clean.isNotEmpty) lines.add(clean);
        }
      } else {
        final tMatches = RegExp(r'<hp:t[^>]*>([\s\S]*?)</hp:t>').allMatches(xml);
        for (final tm in tMatches) {
          final clean = _unescapeXmlEntities(tm.group(1) ?? '').trim();
          if (clean.isNotEmpty) lines.add(clean);
        }
      }
    }
    return lines;
  }

  /// rhwp / hop (MIT License) HWP 5.0 OLE2 Compound File + Raw Deflate + HWPTAG_PARA_TEXT (Tag 67) 파서
  static List<String> _parseHwp5OleCompoundFile(Uint8List bytes) {
    if (bytes.length < 512) return [];
    // OLE2 Magic Header 확인: D0 CF 11 E0 A1 B1 1A E1
    if (bytes[0] != 0xD0 || bytes[1] != 0xCF || bytes[2] != 0x11 || bytes[3] != 0xE0) {
      return [];
    }

    final bd = ByteData.sublistView(bytes);
    final int sectorShift = bd.getUint16(30, Endian.little);
    final int miniSectorShift = bd.getUint16(32, Endian.little);
    final int sectorSize = 1 << sectorShift;
    final int miniSectorSize = 1 << miniSectorShift;

    final int numFatSectors = bd.getUint32(44, Endian.little);
    final int firstDirSector = bd.getUint32(48, Endian.little);
    final int miniCutoff = bd.getUint32(56, Endian.little);
    final int firstMiniFatSector = bd.getUint32(60, Endian.little);
    final int numMiniFatSectors = bd.getUint32(64, Endian.little);
    final int firstDifatSector = bd.getUint32(68, Endian.little);
    final int numDifatSectors = bd.getUint32(72, Endian.little);

    // 1. DIFAT 목록 수집
    final List<int> fatSectorIds = [];
    for (int i = 0; i < 109 && fatSectorIds.length < numFatSectors; i++) {
      final sid = bd.getUint32(76 + i * 4, Endian.little);
      if (sid < 0xFFFFFFFE) fatSectorIds.add(sid);
    }
    int difatSec = firstDifatSector;
    for (int d = 0; d < numDifatSectors && difatSec < 0xFFFFFFFE; d++) {
      final offset = (difatSec + 1) * sectorSize;
      if (offset + sectorSize > bytes.length) break;
      final countInSec = (sectorSize ~/ 4) - 1;
      for (int i = 0; i < countInSec && fatSectorIds.length < numFatSectors; i++) {
        final sid = bd.getUint32(offset + i * 4, Endian.little);
        if (sid < 0xFFFFFFFE) fatSectorIds.add(sid);
      }
      difatSec = bd.getUint32(offset + sectorSize - 4, Endian.little);
    }

    // 2. FAT 테이블 구축
    final List<int> fat = [];
    for (final sid in fatSectorIds) {
      final offset = (sid + 1) * sectorSize;
      if (offset + sectorSize > bytes.length) continue;
      for (int i = 0; i < sectorSize ~/ 4; i++) {
        fat.add(bd.getUint32(offset + i * 4, Endian.little));
      }
    }

    Uint8List readChain(int startSector, [int? exactSize]) {
      final builder = BytesBuilder(copy: false);
      int cur = startSector;
      int guard = 0;
      while (cur < 0xFFFFFFFE && cur < fat.length && guard < 200000) {
        final pos = (cur + 1) * sectorSize;
        if (pos + sectorSize <= bytes.length) {
          builder.add(Uint8List.sublistView(bytes, pos, pos + sectorSize));
        } else {
          break;
        }
        cur = fat[cur];
        guard++;
      }
      final raw = builder.takeBytes();
      if (exactSize != null && exactSize < raw.length) {
        return Uint8List.sublistView(raw, 0, exactSize);
      }
      return raw;
    }

    // 3. Directory Entries 읽기
    final dirBytes = readChain(firstDirSector);
    final dirBd = ByteData.sublistView(dirBytes);
    final int numDirs = dirBytes.length ~/ 128;

    int rootStartSector = 0xFFFFFFFF;
    int rootSize = 0;
    Uint8List? fileHeaderData;
    Uint8List? prvTextData;
    final Map<String, (int, int)> sectionStreams = {};

    for (int i = 0; i < numDirs; i++) {
      final base = i * 128;
      final nameByteLen = dirBd.getUint16(base + 64, Endian.little);
      if (nameByteLen <= 2 || nameByteLen > 64) continue;
      final objType = dirBytes[base + 66];
      if (objType == 0) continue;

      final codeUnits = <int>[];
      for (int k = 0; k < (nameByteLen - 2) ~/ 2; k++) {
        codeUnits.add(dirBd.getUint16(base + k * 2, Endian.little));
      }
      final name = String.fromCharCodes(codeUnits);
      final startSec = dirBd.getUint32(base + 116, Endian.little);
      final streamSize = dirBd.getUint32(base + 120, Endian.little);

      if (objType == 5) {
        rootStartSector = startSec;
        rootSize = streamSize;
      } else if (objType == 2) {
        if (name == 'FileHeader' && streamSize >= 36) {
          sectionStreams['__FileHeader__'] = (startSec, streamSize);
        } else if (name == 'PrvText') {
          prvTextData = (streamSize < miniCutoff && rootStartSector < 0xFFFFFFFE)
              ? null // miniStream에서 아래에서 추출
              : readChain(startSec, streamSize);
          sectionStreams['__PrvText__'] = (startSec, streamSize);
        } else if (name.startsWith('Section')) {
          sectionStreams[name] = (startSec, streamSize);
        }
      }
    }

    // MiniFAT 및 MiniStream 구성
    final List<int> miniFat = [];
    if (firstMiniFatSector < 0xFFFFFFFE && numMiniFatSectors > 0) {
      final miniFatBytes = readChain(firstMiniFatSector);
      final mfBd = ByteData.sublistView(miniFatBytes);
      for (int i = 0; i < miniFatBytes.length ~/ 4; i++) {
        miniFat.add(mfBd.getUint32(i * 4, Endian.little));
      }
    }
    final Uint8List miniStream =
        (rootStartSector < 0xFFFFFFFE && rootSize > 0) ? readChain(rootStartSector, rootSize) : Uint8List(0);

    Uint8List readEntryStream(int startSec, int size) {
      if (size == 0) return Uint8List(0);
      if (size >= miniCutoff || miniStream.isEmpty) {
        return readChain(startSec, size);
      }
      final builder = BytesBuilder(copy: false);
      int cur = startSec;
      int guard = 0;
      while (cur < 0xFFFFFFFE && cur < miniFat.length && guard < 100000) {
        final pos = cur * miniSectorSize;
        if (pos + miniSectorSize <= miniStream.length) {
          builder.add(Uint8List.sublistView(miniStream, pos, pos + miniSectorSize));
        } else {
          break;
        }
        cur = miniFat[cur];
        guard++;
      }
      final raw = builder.takeBytes();
      if (size < raw.length) {
        return Uint8List.sublistView(raw, 0, size);
      }
      return raw;
    }

    bool isCompressed = true;
    if (sectionStreams.containsKey('__FileHeader__')) {
      final (fhSec, fhSize) = sectionStreams['__FileHeader__']!;
      fileHeaderData = readEntryStream(fhSec, fhSize);
      if (fileHeaderData.length >= 40) {
        final flags = ByteData.sublistView(fileHeaderData).getUint32(36, Endian.little);
        isCompressed = (flags & 0x01) != 0;
      }
    }

    final List<String> extractedParagraphs = [];
    final sortedSectionNames = sectionStreams.keys.where((k) => k.startsWith('Section')).toList()
      ..sort();

    for (final secName in sortedSectionNames) {
      final (startSec, size) = sectionStreams[secName]!;
      Uint8List secBytes = readEntryStream(startSec, size);
      if (secBytes.isEmpty) continue;

      if (isCompressed) {
        try {
          secBytes = Uint8List.fromList(ZLibCodec(raw: true).decoder.convert(secBytes));
        } catch (_) {
          try {
            secBytes = Uint8List.fromList(ZLibCodec(raw: false).decoder.convert(secBytes));
          } catch (_) {}
        }
      }

      extractedParagraphs.addAll(_parseHwpSectionRecords(secBytes));
    }

    if (extractedParagraphs.isNotEmpty) {
      return extractedParagraphs;
    }

    // 만약 암호화되었거나 배포용 문서여서 Section 파싱 결과가 비어있다면 PrvText(미리보기 텍스트) 추출
    if (sectionStreams.containsKey('__PrvText__')) {
      final (startSec, size) = sectionStreams['__PrvText__']!;
      final rawPrv = prvTextData ?? readEntryStream(startSec, size);
      if (rawPrv.length >= 2) {
        final pBd = ByteData.sublistView(rawPrv);
        final units = <int>[];
        for (int i = 0; i + 1 < rawPrv.length; i += 2) {
          units.add(pBd.getUint16(i, Endian.little));
        }
        final prvStr = String.fromCharCodes(units);
        for (final line in prvStr.split(RegExp(r'\r?\n'))) {
          final t = line.trim();
          if (t.isNotEmpty) extractedParagraphs.add(t);
        }
      }
    }

    return extractedParagraphs;
  }

  /// HWP 5.0 레코드 스트림에서 HWPTAG_PARA_TEXT (Tag ID = 67) 텍스트 정밀 디코딩
  static List<String> _parseHwpSectionRecords(Uint8List data) {
    final List<String> paragraphs = [];
    final bd = ByteData.sublistView(data);
    int offset = 0;

    while (offset + 4 <= data.length) {
      final header = bd.getUint32(offset, Endian.little);
      offset += 4;

      final int tagId = header & 0x3FF;
      int recSize = (header >> 20) & 0xFFF;
      if (recSize == 0xFFF) {
        if (offset + 4 > data.length) break;
        recSize = bd.getUint32(offset, Endian.little);
        offset += 4;
      }

      if (offset + recSize > data.length) break;

      // HWPTAG_PARA_TEXT == 67 (0x43)
      if (tagId == 67 && recSize >= 2) {
        final buf = StringBuffer();
        int pos = offset;
        final int end = offset + recSize;

        while (pos + 1 < end) {
          final int ch = bd.getUint16(pos, Endian.little);
          pos += 2;

          if (ch == 0) {
            break;
          } else if (ch == 1 ||
              ch == 2 ||
              ch == 3 ||
              ch == 11 ||
              ch == 12 ||
              ch == 14 ||
              ch == 15 ||
              ch == 16 ||
              ch == 17 ||
              ch == 18 ||
              ch == 21 ||
              ch == 22 ||
              ch == 23) {
            // HWP 5.0 확장/인라인 컨트롤 문자: 총 8 WCHAR(16바이트) 차지하므로 나머지 14바이트 스킵
            pos += 14;
          } else if (ch == 4 ||
              ch == 5 ||
              ch == 6 ||
              ch == 7 ||
              ch == 8 ||
              ch == 9 ||
              ch == 19 ||
              ch == 20) {
            // 인라인 컨트롤(16바이트) 중 탭(9)은 공백 추가
            if (ch == 9) buf.write('    ');
            pos += 14;
          } else if (ch == 10 || ch == 13) {
            buf.write('\n');
          } else if (ch >= 32) {
            buf.writeCharCode(ch);
          }
        }

        for (final line in buf.toString().split('\n')) {
          final trimmed = line.trim();
          if (trimmed.isNotEmpty) {
            paragraphs.add(trimmed);
          }
        }
      }

      offset += recSize;
    }

    return paragraphs;
  }

  static List<String> _extractReadableStringsFromBinary(List<int> bytes) {
    final result = <String>[];
    final buf = StringBuffer();
    for (int i = 0; i + 1 < bytes.length; i += 2) {
      final code = bytes[i] | (bytes[i + 1] << 8);
      final isKorean = code >= 0xAC00 && code <= 0xD7A3;
      final isAsciiPrintable = (code >= 0x20 && code <= 0x7E) || code == 0x0A || code == 0x0D;

      if (isKorean || isAsciiPrintable) {
        buf.writeCharCode(code);
      } else {
        if (buf.length >= 6) {
          final s = buf.toString().trim();
          if (RegExp(r'[가-힣a-zA-Z0-9]{3,}').hasMatch(s)) {
            for (final line in s.split(RegExp(r'\r?\n'))) {
              final t = line.trim();
              if (t.length >= 3) result.add(t);
            }
          }
        }
        buf.clear();
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
    html, body { font-family: sans-serif; line-height: 1.75; padding: 4%; word-break: keep-all; }
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
