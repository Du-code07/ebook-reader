import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';
import 'package:archive/archive.dart';
import 'package:flutter/services.dart';

class TxtToEpubConverter {
  static const MethodChannel _pdfChannel = MethodChannel('ebook_reader/pdf_renderer');

  /// TXT 파일을 EPUB으로 변환 (EPUB 뷰어 열람용)
  static Future<File> convertTxtToEpub(File txtFile) async {
    return convertDocumentToEpub(txtFile);
  }

  /// 2. 워드(.docx, .doc) 및 한글(.hwp, .hwpx) 파일을 표(Table)와 사진(Image)이 모두 포함된 PDF로 변환!
  static Future<File> convertDocOrHwpToPdf(File inputFile, {String? targetPdfPath}) async {
    final String outPath = targetPdfPath ??
        inputFile.path.replaceAll(
          RegExp(r'\.(docx|doc|hwpx|hwp)$', caseSensitive: false),
          '.pdf',
        );
    final outFile = File(outPath);

    final ext = inputFile.path.split('.').last.toLowerCase();
    final bytes = await inputFile.readAsBytes();
    final String title = inputFile.path
        .split(Platform.pathSeparator)
        .last
        .replaceAll(RegExp(r'\.[^.]+$'), '');

    List<Map<String, dynamic>> blocks = [];
    try {
      if (ext == 'docx') {
        blocks = _extractDocxStructuredBlocks(bytes);
      } else if (ext == 'hwpx') {
        blocks = _extractHwpxStructuredBlocks(bytes);
      } else if (ext == 'hwp') {
        blocks = _extractHwp5StructuredBlocks(Uint8List.fromList(bytes));
      } else if (ext == 'doc') {
        final lines = _extractReadableStringsFromBinary(bytes);
        blocks = lines.map((l) => <String, dynamic>{'type': 'paragraph', 'text': l}).toList();
      }
    } catch (_) {}

    if (blocks.isEmpty) {
      final fallbackLines = _extractReadableStringsFromBinary(bytes);
      for (final l in fallbackLines) {
        blocks.add({'type': 'paragraph', 'text': l});
      }
    }

    if (blocks.isEmpty) {
      blocks.add({
        'type': 'paragraph',
        'text': '[$title] 문서에서 표시할 수 있는 본문이나 표/이미지를 찾지 못했습니다.',
      });
    }

    final renderedPath = await _pdfChannel.invokeMethod<String>(
      'renderStructuredDocToPdf',
      {
        'outputPath': outFile.path,
        'blocks': blocks,
      },
    );

    if (renderedPath != null && File(renderedPath).existsSync()) {
      return File(renderedPath);
    }
    return outFile;
  }

  /// 워드(.docx)에서 본문 단락(<w:p>), 표(<w:tbl>), 이미지(word/media/*)를 문서 순서대로 정밀 추출
  static List<Map<String, dynamic>> _extractDocxStructuredBlocks(List<int> bytes) {
    final List<Map<String, dynamic>> blocks = [];
    final archive = ZipDecoder().decodeBytes(bytes);

    final Map<String, Uint8List> mediaByTarget = {};
    for (final file in archive) {
      if (!file.isFile) continue;
      final lower = file.name.toLowerCase();
      if (lower.startsWith('word/media/') &&
          (lower.endsWith('.png') ||
              lower.endsWith('.jpg') ||
              lower.endsWith('.jpeg') ||
              lower.endsWith('.bmp') ||
              lower.endsWith('.gif') ||
              lower.endsWith('.webp'))) {
        final raw = file.content as List<int>;
        final data = Uint8List.fromList(raw);
        final relKey = file.name.substring('word/'.length);
        mediaByTarget[relKey] = data;
        mediaByTarget[file.name] = data;
        mediaByTarget[file.name.split('/').last] = data;
      }
    }

    final Map<String, Uint8List> rIdToImage = {};
    for (final file in archive) {
      if (file.isFile && file.name == 'word/_rels/document.xml.rels') {
        final relXml = utf8.decode(file.content as List<int>, allowMalformed: true);
        final relMatches = RegExp(r'<Relationship\b[^>]*>', dotAll: true).allMatches(relXml);
        for (final m in relMatches) {
          final tag = m.group(0) ?? '';
          final idMatch = RegExp(r'\bId="([^"]+)"').firstMatch(tag);
          final targetMatch = RegExp(r'\bTarget="([^"]+)"').firstMatch(tag);
          if (idMatch != null && targetMatch != null) {
            final rId = idMatch.group(1)!;
            String target = targetMatch.group(1)!;
            if (target.startsWith('/word/')) {
              target = target.substring('/word/'.length);
            } else if (target.startsWith('word/')) {
              target = target.substring('word/'.length);
            }
            final img = mediaByTarget[target] ?? mediaByTarget[target.split('/').last];
            if (img != null) {
              rIdToImage[rId] = img;
            }
          }
        }
      }
    }

    final Set<Uint8List> emittedImages = {};

    for (final file in archive) {
      if (file.isFile && file.name == 'word/document.xml') {
        final xml = utf8.decode(file.content as List<int>, allowMalformed: true);
        int pos = 0;
        while (pos < xml.length) {
          final nextTbl = xml.indexOf('<w:tbl', pos);
          final nextP = xml.indexOf('<w:p', pos);

          if (nextTbl == -1 && nextP == -1) break;

          if (nextTbl != -1 && (nextP == -1 || nextTbl < nextP)) {
            final endTbl = _findMatchingCloseTag(xml, nextTbl, 'w:tbl');
            if (endTbl == -1) break;
            final tblXml = xml.substring(nextTbl, endTbl);
            final rows = _parseDocxTableRows(tblXml);
            if (rows.isNotEmpty) {
              blocks.add({'type': 'table', 'rows': rows});
            }
            for (final rm in RegExp(r'r:(?:embed|id)="(rId[^"]+)"').allMatches(tblXml)) {
              final rid = rm.group(1)!;
              final img = rIdToImage[rid];
              if (img != null && !emittedImages.contains(img)) {
                emittedImages.add(img);
                blocks.add({'type': 'image', 'bytes': img});
              }
            }
            pos = endTbl;
          } else {
            final afterChar = (nextP + 4 < xml.length) ? xml[nextP + 4] : '';
            if (afterChar != '>' && afterChar != ' ' && afterChar != '/') {
              pos = nextP + 4;
              continue;
            }
            final endP = _findMatchingCloseTag(xml, nextP, 'w:p');
            if (endP == -1) break;
            final pXml = xml.substring(nextP, endP);

            final pText = _extractDocxParagraphText(pXml);
            if (pText.isNotEmpty) {
              blocks.add({'type': 'paragraph', 'text': pText});
            }
            for (final rm in RegExp(r'r:(?:embed|id)="(rId[^"]+)"').allMatches(pXml)) {
              final rid = rm.group(1)!;
              final img = rIdToImage[rid];
              if (img != null && !emittedImages.contains(img)) {
                emittedImages.add(img);
                blocks.add({'type': 'image', 'bytes': img});
              }
            }
            pos = endP;
          }
        }
      }
    }

    for (final img in mediaByTarget.values.toSet()) {
      if (!emittedImages.contains(img)) {
        emittedImages.add(img);
        blocks.add({'type': 'image', 'bytes': img});
      }
    }

    return blocks;
  }

  static List<List<String>> _parseDocxTableRows(String tblXml) {
    final List<List<String>> rows = [];
    final trMatches = RegExp(r'<w:tr[\s>](.*?)</w:tr>', dotAll: true).allMatches(tblXml);
    for (final tr in trMatches) {
      final trContent = tr.group(1) ?? '';
      final List<String> rowCells = [];
      final tcMatches = RegExp(r'<w:tc[\s>](.*?)</w:tc>', dotAll: true).allMatches(trContent);
      for (final tc in tcMatches) {
        final tcContent = tc.group(1) ?? '';
        final cellParas = <String>[];
        final pMatches = RegExp(r'<w:p[\s>](.*?)</w:p>', dotAll: true).allMatches(tcContent);
        for (final pm in pMatches) {
          final pt = _extractDocxParagraphText(pm.group(0) ?? '');
          if (pt.isNotEmpty) cellParas.add(pt);
        }
        rowCells.add(cellParas.join('\n'));
      }
      if (rowCells.isNotEmpty) {
        rows.add(rowCells);
      }
    }
    return rows;
  }

  static String _extractDocxParagraphText(String pXml) {
    final String withBreaks = pXml
        .replaceAll(RegExp(r'<w:tab\s*/>'), '    ')
        .replaceAll(RegExp(r'<w:(?:br|cr)\b[^>]*/>'), '\n');
    final buf = StringBuffer();
    for (final tm in RegExp(r'<w:t(?:\s[^>]*)?>(.*?)</w:t>', dotAll: true).allMatches(withBreaks)) {
      buf.write(_unescapeXml(tm.group(1) ?? ''));
    }
    return buf.toString().trim();
  }

  static int _findMatchingCloseTag(String xml, int startIdx, String tagName) {
    final selfCloseEnd = xml.indexOf('>', startIdx);
    if (selfCloseEnd != -1 && xml[selfCloseEnd - 1] == '/') {
      return selfCloseEnd + 1;
    }
    final closeTag = '</$tagName>';
    final closeIdx = xml.indexOf(closeTag, startIdx);
    if (closeIdx == -1) return -1;
    return closeIdx + closeTag.length;
  }

  /// 한글 HWPX(.hwpx)에서 단락(<hp:p>), 표(<hp:tbl>), 이미지(BinData/*)를 정밀 추출
  static List<Map<String, dynamic>> _extractHwpxStructuredBlocks(List<int> bytes) {
    final List<Map<String, dynamic>> blocks = [];
    final archive = ZipDecoder().decodeBytes(bytes);

    final Map<String, Uint8List> binDataMap = {};
    final List<Uint8List> allImagesInOrder = [];

    final sortedFiles = archive.files.where((f) => f.isFile).toList()
      ..sort((a, b) => a.name.compareTo(b.name));

    for (final file in sortedFiles) {
      final lower = file.name.toLowerCase();
      if (lower.startsWith('bindata/') &&
          (lower.endsWith('.png') ||
              lower.endsWith('.jpg') ||
              lower.endsWith('.jpeg') ||
              lower.endsWith('.bmp') ||
              lower.endsWith('.gif') ||
              lower.endsWith('.webp'))) {
        final data = Uint8List.fromList(file.content as List<int>);
        final base = file.name.split('/').last;
        final noExt = base.replaceAll(RegExp(r'\.[^.]+$'), '');
        binDataMap[file.name] = data;
        binDataMap[base] = data;
        binDataMap[noExt] = data;
        binDataMap[noExt.toLowerCase()] = data;
        allImagesInOrder.add(data);
      }
    }

    for (final file in sortedFiles) {
      if (file.name.toLowerCase().endsWith('content.hpf')) {
        final hpfXml = utf8.decode(file.content as List<int>, allowMalformed: true);
        for (final m in RegExp(r'<opf:item\b[^>]*>', dotAll: true).allMatches(hpfXml)) {
          final tag = m.group(0) ?? '';
          final idM = RegExp(r'\bid="([^"]+)"').firstMatch(tag);
          final hrefM = RegExp(r'\bhref="([^"]+)"').firstMatch(tag);
          if (idM != null && hrefM != null) {
            final id = idM.group(1)!;
            final href = hrefM.group(1)!;
            final img = binDataMap[href] ?? binDataMap[href.split('/').last];
            if (img != null) {
              binDataMap[id] = img;
              binDataMap[id.toLowerCase()] = img;
            }
          }
        }
      }
    }

    final Set<Uint8List> emittedImages = {};
    final sectionFiles = sortedFiles
        .where((f) => f.name.startsWith('Contents/section') && f.name.endsWith('.xml'))
        .toList();

    for (final secFile in sectionFiles) {
      final xml = utf8.decode(secFile.content as List<int>, allowMalformed: true);
      int cursor = 0;
      while (cursor < xml.length) {
        final nextP = xml.indexOf('<hp:p', cursor);
        if (nextP == -1) break;
        final afterP = (nextP + 5 < xml.length) ? xml[nextP + 5] : '';
        if (afterP != '>' && afterP != ' ' && afterP != '/') {
          cursor = nextP + 5;
          continue;
        }
        final endP = _findOuterHpParagraphEnd(xml, nextP);
        if (endP == -1) break;
        final pBlock = xml.substring(nextP, endP);

        String pWithoutTables = pBlock;
        final tblMatches = RegExp(r'<hp:tbl\b[^>]*>(.*?)</hp:tbl>', dotAll: true).allMatches(pBlock).toList();
        if (tblMatches.isNotEmpty) {
          pWithoutTables = pBlock.replaceAll(RegExp(r'<hp:tbl\b[^>]*>.*?</hp:tbl>', dotAll: true), '');
        }

        final pTextBuf = StringBuffer();
        for (final tm in RegExp(r'<hp:t(?:\s[^>]*)?>(.*?)</hp:t>', dotAll: true).allMatches(pWithoutTables)) {
          pTextBuf.write(_unescapeXml(tm.group(1) ?? ''));
        }
        final pText = pTextBuf.toString().trim();
        if (pText.isNotEmpty) {
          blocks.add({'type': 'paragraph', 'text': pText});
        }

        for (final tblM in tblMatches) {
          final tblXml = tblM.group(1) ?? '';
          final List<List<String>> rows = [];
          for (final trM in RegExp(r'<hp:tr\b[^>]*>(.*?)</hp:tr>', dotAll: true).allMatches(tblXml)) {
            final trXml = trM.group(1) ?? '';
            final List<String> cells = [];
            for (final tcM in RegExp(r'<hp:tc\b[^>]*>(.*?)</hp:tc>', dotAll: true).allMatches(trXml)) {
              final tcXml = tcM.group(1) ?? '';
              final cellLines = <String>[];
              for (final cellPM in RegExp(r'<hp:p\b[^>]*>(.*?)</hp:p>', dotAll: true).allMatches(tcXml)) {
                final cBuf = StringBuffer();
                for (final tm in RegExp(r'<hp:t(?:\s[^>]*)?>(.*?)</hp:t>', dotAll: true).allMatches(cellPM.group(1) ?? '')) {
                  cBuf.write(_unescapeXml(tm.group(1) ?? ''));
                }
                final ct = cBuf.toString().trim();
                if (ct.isNotEmpty) cellLines.add(ct);
              }
              cells.add(cellLines.join('\n'));
            }
            if (cells.isNotEmpty) rows.add(cells);
          }
          if (rows.isNotEmpty) {
            blocks.add({'type': 'table', 'rows': rows});
          }
        }

        for (final imgM in RegExp(r'(?:binaryItemIDRef|binItemIDRef|binData)="([^"]+)"').allMatches(pBlock)) {
          final refId = imgM.group(1)!;
          final img = binDataMap[refId] ?? binDataMap[refId.toLowerCase()];
          if (img != null && !emittedImages.contains(img)) {
            emittedImages.add(img);
            blocks.add({'type': 'image', 'bytes': img});
          }
        }

        cursor = endP;
      }
    }

    for (final img in allImagesInOrder) {
      if (!emittedImages.contains(img)) {
        emittedImages.add(img);
        blocks.add({'type': 'image', 'bytes': img});
      }
    }

    return blocks;
  }

  static int _findOuterHpParagraphEnd(String xml, int startIdx) {
    int depth = 0;
    int i = startIdx;
    while (i < xml.length) {
      final nextOpen = xml.indexOf('<hp:p', i);
      final nextClose = xml.indexOf('</hp:p>', i);
      if (nextClose == -1) return -1;

      if (nextOpen != -1 && nextOpen < nextClose) {
        final afterC = (nextOpen + 5 < xml.length) ? xml[nextOpen + 5] : '';
        if (afterC == '>' || afterC == ' ' || afterC == '/') {
          final tagEnd = xml.indexOf('>', nextOpen);
          if (tagEnd != -1 && xml[tagEnd - 1] != '/') {
            depth++;
          }
          i = (tagEnd != -1) ? tagEnd + 1 : nextOpen + 5;
          continue;
        }
        i = nextOpen + 5;
        continue;
      } else {
        depth--;
        if (depth <= 0) {
          return nextClose + '</hp:p>'.length;
        }
        i = nextClose + '</hp:p>'.length;
      }
    }
    return -1;
  }

  /// HWP 5.0 바이너리(OLE2 Compound File)에서 단락, 표(HWPTAG_TABLE), 사진(BinData/*)을 정밀 추출
  static List<Map<String, dynamic>> _extractHwp5StructuredBlocks(Uint8List bytes) {
    final List<Map<String, dynamic>> blocks = [];
    if (bytes.length < 512) return blocks;

    if (bytes[0] != 0xD0 ||
        bytes[1] != 0xCF ||
        bytes[2] != 0x11 ||
        bytes[3] != 0xE0) {
      if (bytes[0] == 0x50 && bytes[1] == 0x4B) {
        return _extractHwpxStructuredBlocks(bytes);
      }
      return blocks;
    }

    final bd = ByteData.sublistView(bytes);
    final sectorShift = bd.getUint16(30, Endian.little);
    final miniSectorShift = bd.getUint16(32, Endian.little);
    final sectorSize = 1 << sectorShift;
    final miniSectorSize = 1 << miniSectorShift;

    final numFatSectors = bd.getUint32(44, Endian.little);
    final firstDirSector = bd.getUint32(48, Endian.little);
    final miniCutoff = bd.getUint32(56, Endian.little);
    final firstMiniFatSector = bd.getUint32(60, Endian.little);
    final numMiniFatSectors = bd.getUint32(64, Endian.little);
    final firstDifatSector = bd.getUint32(68, Endian.little);
    final numDifatSectors = bd.getUint32(72, Endian.little);

    final List<int> fatSectorIds = [];
    for (int i = 0; i < 109 && fatSectorIds.length < numFatSectors; i++) {
      final sid = bd.getUint32(76 + i * 4, Endian.little);
      if (sid < 0xFFFFFFFE) fatSectorIds.add(sid);
    }

    int difatSec = firstDifatSector;
    for (int d = 0; d < numDifatSectors && difatSec < 0xFFFFFFFE; d++) {
      final offset = (difatSec + 1) * sectorSize;
      if (offset + sectorSize > bytes.length) break;
      final entriesPerSec = (sectorSize ~/ 4) - 1;
      for (int i = 0; i < entriesPerSec && fatSectorIds.length < numFatSectors; i++) {
        final sid = bd.getUint32(offset + i * 4, Endian.little);
        if (sid < 0xFFFFFFFE) fatSectorIds.add(sid);
      }
      difatSec = bd.getUint32(offset + entriesPerSec * 4, Endian.little);
    }

    final List<int> fat = [];
    for (final fatSec in fatSectorIds) {
      final offset = (fatSec + 1) * sectorSize;
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

    final dirBytes = readChain(firstDirSector);
    final dirBd = ByteData.sublistView(dirBytes);
    final int entryCount = dirBytes.length ~/ 128;

    int rootStartSector = 0xFFFFFFFE;
    int rootSize = 0;
    final Map<String, (int, int)> sectionStreams = {};
    final Map<String, (int, int)> binDataStreams = {};

    for (int i = 0; i < entryCount; i++) {
      final base = i * 128;
      final nameByteLen = dirBd.getUint16(base + 64, Endian.little);
      final objType = dirBd.getUint8(base + 66);
      if (nameByteLen < 2 || nameByteLen > 64 || objType == 0) continue;

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
          sectionStreams['__PrvText__'] = (startSec, streamSize);
        } else if (name.startsWith('Section')) {
          sectionStreams[name] = (startSec, streamSize);
        } else if (name.toUpperCase().startsWith('BIN')) {
          binDataStreams[name] = (startSec, streamSize);
        }
      }
    }

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
      while (cur < 0xFFFFFFFE && cur < miniFat.length && guard < 150000) {
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
      final fileHeaderData = readEntryStream(fhSec, fhSize);
      if (fileHeaderData.length >= 40) {
        final flags = ByteData.sublistView(fileHeaderData).getUint32(36, Endian.little);
        isCompressed = (flags & 0x01) != 0;
      }
    }

    final List<Uint8List> extractedBinImages = [];
    final sortedBinNames = binDataStreams.keys.toList()..sort();
    for (final binName in sortedBinNames) {
      final lower = binName.toLowerCase();
      if (!lower.endsWith('.jpg') &&
          !lower.endsWith('.jpeg') &&
          !lower.endsWith('.png') &&
          !lower.endsWith('.bmp') &&
          !lower.endsWith('.gif') &&
          !lower.endsWith('.webp')) {
        continue;
      }
      final (bSec, bSize) = binDataStreams[binName]!;
      Uint8List rawBin = readEntryStream(bSec, bSize);
      if (rawBin.isEmpty) continue;

      if (isCompressed && !_looksLikeImageHeader(rawBin)) {
        try {
          rawBin = Uint8List.fromList(ZLibCodec(raw: true).decoder.convert(rawBin));
        } catch (_) {
          try {
            rawBin = Uint8List.fromList(ZLibCodec(raw: false).decoder.convert(rawBin));
          } catch (_) {}
        }
      }
      if (_looksLikeImageHeader(rawBin)) {
        extractedBinImages.add(rawBin);
      }
    }

    final Set<int> usedBinImageIndices = {};
    final sortedSectionNames = sectionStreams.keys.where((k) => k.startsWith('Section')).toList()..sort();

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

      blocks.addAll(
        _parseHwpSectionStructuredRecords(
          secBytes,
          extractedBinImages,
          usedBinImageIndices,
        ),
      );
    }

    for (int i = 0; i < extractedBinImages.length; i++) {
      if (!usedBinImageIndices.contains(i)) {
        usedBinImageIndices.add(i);
        blocks.add({'type': 'image', 'bytes': extractedBinImages[i]});
      }
    }

    if (blocks.isEmpty && sectionStreams.containsKey('__PrvText__')) {
      final (startSec, size) = sectionStreams['__PrvText__']!;
      final rawPrv = readEntryStream(startSec, size);
      if (rawPrv.length >= 2) {
        final pBd = ByteData.sublistView(rawPrv);
        final units = <int>[];
        for (int i = 0; i + 1 < rawPrv.length; i += 2) {
          units.add(pBd.getUint16(i, Endian.little));
        }
        final prvStr = String.fromCharCodes(units);
        for (final line in prvStr.split(RegExp(r'\r?\n'))) {
          final t = line.trim();
          if (t.isNotEmpty) {
            blocks.add({'type': 'paragraph', 'text': t});
          }
        }
      }
    }

    return blocks;
  }

  static bool _looksLikeImageHeader(Uint8List data) {
    if (data.length < 4) return false;
    if (data[0] == 0xFF && data[1] == 0xD8 && data[2] == 0xFF) return true;
    if (data[0] == 0x89 && data[1] == 0x50 && data[2] == 0x4E && data[3] == 0x47) return true;
    if (data[0] == 0x42 && data[1] == 0x4D) return true;
    if (data[0] == 0x47 && data[1] == 0x49 && data[2] == 0x46) return true;
    return false;
  }

  static List<Map<String, dynamic>> _parseHwpSectionStructuredRecords(
    Uint8List data,
    List<Uint8List> binImages,
    Set<int> usedBinImageIndices,
  ) {
    final List<Map<String, dynamic>> blocks = [];
    final bd = ByteData.sublistView(data);
    int offset = 0;

    int? activeTableLevel;
    int tableRows = 0;
    int tableCols = 0;
    List<List<List<String>>>? tableGrid;
    int currentCellRow = 0;
    int currentCellCol = -1;

    void flushActiveTable() {
      if (tableGrid != null && tableRows > 0 && tableCols > 0) {
        final List<List<String>> finalRows = [];
        for (final r in tableGrid!) {
          final rowStrs = r.map((cellLines) => cellLines.join('\n').trim()).toList();
          if (rowStrs.any((s) => s.isNotEmpty) || finalRows.isNotEmpty) {
            finalRows.add(rowStrs);
          }
        }
        if (finalRows.isNotEmpty) {
          blocks.add({'type': 'table', 'rows': finalRows});
        }
      }
      activeTableLevel = null;
      tableGrid = null;
      tableRows = 0;
      tableCols = 0;
      currentCellRow = 0;
      currentCellCol = -1;
    }

    while (offset + 4 <= data.length) {
      final header = bd.getUint32(offset, Endian.little);
      offset += 4;

      final int tagId = header & 0x3FF;
      final int level = (header >> 10) & 0x3FF;
      int recSize = (header >> 20) & 0xFFF;
      if (recSize == 0xFFF) {
        if (offset + 4 > data.length) break;
        recSize = bd.getUint32(offset, Endian.little);
        offset += 4;
      }

      if (offset + recSize > data.length) break;

      if (activeTableLevel != null && level < activeTableLevel!) {
        flushActiveTable();
      }

      if (tagId == 77 && recSize >= 8) {
        flushActiveTable();
        final rCount = bd.getUint16(offset + 4, Endian.little);
        final cCount = bd.getUint16(offset + 6, Endian.little);
        if (rCount > 0 && rCount <= 500 && cCount > 0 && cCount <= 50) {
          activeTableLevel = level;
          tableRows = rCount;
          tableCols = cCount;
          tableGrid = List.generate(
            tableRows,
            (_) => List.generate(tableCols, (_) => <String>[]),
          );
          currentCellRow = 0;
          currentCellCol = -1;
        }
      } else if (tagId == 72 && activeTableLevel != null && tableGrid != null) {
        bool matchedCoord = false;
        if (recSize >= 12) {
          for (final baseOff in [8, 6]) {
            if (baseOff + 4 <= recSize) {
              final cIdx = bd.getUint16(offset + baseOff, Endian.little);
              final rIdx = bd.getUint16(offset + baseOff + 2, Endian.little);
              if (rIdx < tableRows && cIdx < tableCols) {
                currentCellRow = rIdx;
                currentCellCol = cIdx;
                matchedCoord = true;
                break;
              }
            }
          }
        }
        if (!matchedCoord) {
          currentCellCol++;
          if (currentCellCol >= tableCols) {
            currentCellCol = 0;
            if (currentCellRow + 1 < tableRows) {
              currentCellRow++;
            }
          }
        }
      } else if (tagId == 85 && binImages.isNotEmpty) {
        int? matchedIdx;
        for (int i = 0; i < binImages.length; i++) {
          if (!usedBinImageIndices.contains(i)) {
            matchedIdx = i;
            break;
          }
        }
        if (matchedIdx != null) {
          usedBinImageIndices.add(matchedIdx);
          blocks.add({'type': 'image', 'bytes': binImages[matchedIdx]});
        }
      } else if (tagId == 67 && recSize >= 2) {
        final decodedLines = _decodeHwpParaText(bd, offset, recSize);
        if (decodedLines.isNotEmpty) {
          if (activeTableLevel != null && tableGrid != null) {
            final r = currentCellRow.clamp(0, tableRows - 1);
            final c = (currentCellCol < 0 ? 0 : currentCellCol).clamp(0, tableCols - 1);
            tableGrid![r][c].addAll(decodedLines);
          } else {
            for (final line in decodedLines) {
              blocks.add({'type': 'paragraph', 'text': line});
            }
          }
        }
      }

      offset += recSize;
    }

    flushActiveTable();
    return blocks;
  }

  static List<String> _decodeHwpParaText(ByteData bd, int offset, int recSize) {
    final List<String> lines = [];
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
        pos += 14;
      } else if (ch == 4 ||
          ch == 5 ||
          ch == 6 ||
          ch == 7 ||
          ch == 8 ||
          ch == 9 ||
          ch == 19 ||
          ch == 20) {
        if (ch == 9) buf.write('    ');
        pos += 14;
      } else if (ch == 10 || ch == 13) {
        buf.write('\n');
      } else if (ch >= 32) {
        buf.writeCharCode(ch);
      }
    }

    final text = buf.toString().trim();
    if (text.isNotEmpty) {
      for (final sub in text.split('\n')) {
        final t = sub.trim();
        if (t.isNotEmpty) lines.add(t);
      }
    }
    return lines;
  }

  /// TXT 등 일반 텍스트 문서를 EPUB 2.0으로 변환
  static Future<File> convertDocumentToEpub(File inputFile) async {
    final epubPath = inputFile.path.replaceAll(
      RegExp(r'\.(txt|docx|doc|hwpx|hwp)$', caseSensitive: false),
      '_converted.epub',
    );
    final outFile = File(epubPath);

    final ext = inputFile.path.split('.').last.toLowerCase();
    final bytes = await inputFile.readAsBytes();
    final String title = inputFile.path
        .split(Platform.pathSeparator)
        .last
        .replaceAll(RegExp(r'\.[^.]+$'), '');

    List<String> lines = [];
    if (ext == 'txt') {
      String content;
      try {
        content = utf8.decode(bytes);
      } catch (_) {
        content = latin1.decode(bytes, allowInvalid: true);
      }
      lines = content.split(RegExp(r'\r?\n'));
    } else {
      lines = _extractReadableStringsFromBinary(bytes);
    }

    if (lines.isEmpty) {
      lines = ['[$title] 문서에서 표시할 수 있는 텍스트를 찾지 못했습니다.'];
    }

    return _buildEpubArchive(outFile, title, lines);
  }

  static List<String> _extractReadableStringsFromBinary(List<int> bytes) {
    final List<String> result = [];
    try {
      final decoded = utf8.decode(bytes, allowMalformed: true);
      final matches = RegExp(r'[가-힣a-zA-Z0-9\s.,?!:;\-\(\)\[\]\"\x27]{8,}').allMatches(decoded);
      for (final m in matches) {
        final s = (m.group(0) ?? '').trim();
        if (s.length >= 8 && RegExp(r'[가-힣a-zA-Z]').hasMatch(s)) {
          result.add(s);
        }
      }
    } catch (_) {}
    return result;
  }

  static Future<File> _buildEpubArchive(File outFile, String title, List<String> lines) async {
    final archive = Archive();

    final mimetypeBytes = utf8.encode('application/epub+zip');
    final mimetypeFile = ArchiveFile('mimetype', mimetypeBytes.length, mimetypeBytes);
    mimetypeFile.compress = false;
    archive.addFile(mimetypeFile);

    const containerXml = '<?xml version="1.0" encoding="UTF-8"?>\n'
        '<container version="1.0" xmlns="urn:oasis:names:tc:opendocument:xmlns:container">\n'
        '  <rootfiles>\n'
        '    <rootfile full-path="OEBPS/content.opf" media-type="application/oebps-package+xml"/>\n'
        '  </rootfiles>\n'
        '</container>';
    archive.addFile(ArchiveFile('META-INF/container.xml', utf8.encode(containerXml).length, utf8.encode(containerXml)));

    final bodyBuf = StringBuffer();
    for (final line in lines) {
      final trimmed = line.trim();
      if (trimmed.isEmpty) {
        bodyBuf.writeln('<p>&#160;</p>');
      } else {
        bodyBuf.writeln('<p>${_escapeXml(trimmed)}</p>');
      }
    }

    final chapterXhtml = '<?xml version="1.0" encoding="UTF-8"?>\n'
        '<!DOCTYPE html PUBLIC "-//W3C//DTD XHTML 1.1//EN" "http://www.w3.org/TR/xhtml11/DTD/xhtml11.dtd">\n'
        '<html xmlns="http://www.w3.org/1999/xhtml" xml:lang="ko">\n'
        '<head>\n'
        '  <title>${_escapeXml(title)}</title>\n'
        '  <style type="text/css">\n'
        '    html, body { font-family: sans-serif; line-height: 1.75; padding: 4%; word-break: keep-all; }\n'
        '    p { margin: 0.45em 0; text-align: justify; }\n'
        '  </style>\n'
        '</head>\n'
        '<body>\n'
        '  <h2>${_escapeXml(title)}</h2>\n'
        '  ${bodyBuf.toString()}\n'
        '</body>\n'
        '</html>';
    final chapterBytes = utf8.encode(chapterXhtml);
    archive.addFile(ArchiveFile('OEBPS/chapter1.xhtml', chapterBytes.length, chapterBytes));

    final opfXml = '<?xml version="1.0" encoding="UTF-8"?>\n'
        '<package xmlns="http://www.idpf.org/2007/opf" unique-identifier="BookId" version="2.0">\n'
        '  <metadata xmlns:dc="http://purl.org/dc/elements/1.1/">\n'
        '    <dc:title>${_escapeXml(title)}</dc:title>\n'
        '    <dc:language>ko</dc:language>\n'
        '    <dc:identifier id="BookId">urn:uuid:${DateTime.now().millisecondsSinceEpoch}</dc:identifier>\n'
        '  </metadata>\n'
        '  <manifest>\n'
        '    <item id="ncx" href="toc.ncx" media-type="application/x-dtbncx+xml"/>\n'
        '    <item id="chap1" href="chapter1.xhtml" media-type="application/xhtml+xml"/>\n'
        '  </manifest>\n'
        '  <spine toc="ncx">\n'
        '    <itemref idref="chap1"/>\n'
        '  </spine>\n'
        '</package>';
    archive.addFile(ArchiveFile('OEBPS/content.opf', utf8.encode(opfXml).length, utf8.encode(opfXml)));

    final ncxXml = '<?xml version="1.0" encoding="UTF-8"?>\n'
        '<ncx xmlns="http://www.daisy.org/z3986/2005/ncx/" version="2.0">\n'
        '  <head><meta name="dtb:uid" content="1"/></head>\n'
        '  <docTitle><text>${_escapeXml(title)}</text></docTitle>\n'
        '  <navMap>\n'
        '    <navPoint id="navPoint-1" playOrder="1">\n'
        '      <navLabel><text>${_escapeXml(title)}</text></navLabel>\n'
        '      <content src="chapter1.xhtml"/>\n'
        '    </navPoint>\n'
        '  </navMap>\n'
        '</ncx>';
    archive.addFile(ArchiveFile('OEBPS/toc.ncx', utf8.encode(ncxXml).length, utf8.encode(ncxXml)));

    final zipBytes = ZipEncoder().encode(archive);
    await outFile.writeAsBytes(zipBytes!);
    return outFile;
  }

  static String _escapeXml(String s) {
    return s
        .replaceAll('&', '&amp;')
        .replaceAll('<', '&lt;')
        .replaceAll('>', '&gt;')
        .replaceAll('"', '&quot;')
        .replaceAll("'", '&apos;');
  }

  static String _unescapeXml(String s) {
    return s
        .replaceAll('&lt;', '<')
        .replaceAll('&gt;', '>')
        .replaceAll('&quot;', '"')
        .replaceAll('&apos;', "'")
        .replaceAll('&amp;', '&');
  }
}
