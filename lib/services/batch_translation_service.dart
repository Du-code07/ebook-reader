import 'dart:convert';
import 'dart:io';
import 'dart:math' as math;
import 'dart:typed_data';
import 'dart:ui' as ui;
import 'package:archive/archive.dart';
import 'package:google_mlkit_text_recognition/google_mlkit_text_recognition.dart';
import 'package:http/http.dart' as http;
import 'package:translator/translator.dart';
import 'storage_service.dart';

class _TextColUnit {
  final ui.Rect rect;
  final String text;
  final double avgCharSize;
  final bool isVerticalLine;

  _TextColUnit({
    required this.rect,
    required this.text,
    required this.avgCharSize,
    required this.isVerticalLine,
  });
}

class BatchTranslationService {
  static final GoogleTranslator _translator = GoogleTranslator();

  // 업로드해주신 Google 번역 Chrome 확장 프로그램(v2.0.18, bubble_compiled.js)의 공식 OnePlatform API 키 및 엔드포인트
  static const String _chromeExtOnePlatformUrl = 'https://translate-pa.googleapis.com/v1/translate';
  static const String _chromeExtAjaxSingleUrl = 'https://translate.googleapis.com/translate_a/single';
  static const String _chromeExtApiKey = 'AIzaSyDLEeFI5OtFBwYBIoK_jj5m32rZK5CkCXA';

  /// OCR 오인식 노이즈 정리 (일본어 세로쓰기 만화에서 자주 섞이는 특수기호 노이즈 제거)
  static String cleanOcrSourceText(String raw, String sourceLang) {
    String s = raw.trim();
    if (s.isEmpty) return '';
    if (sourceLang == 'ja' || sourceLang == 'zh-cn') {
      s = s
          .replaceAll(RegExp(r'[|｜¦]'), '')
          .replaceAll('ـ', 'ー')
          .replaceAll(RegExp(r'\s+'), '');
    }
    return s.trim();
  }

  /// 한국어 띄어쓰기 및 맞춤법 자동 교정기
  static String polishKoreanSpacingAndSpelling(String raw) {
    if (raw.trim().isEmpty) return '';
    String s = raw.trim();

    s = s
        .replaceAll('</끝>', '')
        .replaceAll(RegExp(r'###.*'), '')
        .replaceAll('「', '"')
        .replaceAll('」', '"')
        .replaceAll('『', '"')
        .replaceAll('』', '"')
        .replaceAll('…', '...')
        .replaceAll(RegExp(r'[ \t]+'), ' ');

    // 문장부호 뒤 자동 띄어쓰기 보정
    s = s.replaceAllMapped(
      RegExp(r'([,!?])[가-힣]'),
      (m) => '${m.group(0)!.substring(0, 1)} ${m.group(0)!.substring(1)}',
    );
    s = s.replaceAllMapped(
      RegExp(r'(\.{1,3})([가-힣])'),
      (m) => '${m.group(1)} ${m.group(2)}',
    );

    // 자주 틀리는 한국어 맞춤법 및 의존명사 띄어쓰기 교정 규칙
    final Map<RegExp, String> spellingRules = {
      RegExp(r'안되([요네고지])'): '안 돼\$1',
      RegExp(r'안된다'): '안 된다',
      RegExp(r'안돼요'): '안 돼요',
      RegExp(r'되서'): '돼서',
      RegExp(r'되요'): '돼요',
      RegExp(r'웬지'): '왠지',
      RegExp(r'어떻해'): '어떡해',
      RegExp(r'할수있'): '할 수 있',
      RegExp(r'할수없'): '할 수 없',
      RegExp(r'볼수있'): '볼 수 있',
      RegExp(r'볼수없'): '볼 수 없',
      RegExp(r'갈수있'): '갈 수 있',
      RegExp(r'갈수없'): '갈 수 없',
      RegExp(r'될수있'): '될 수 있',
      RegExp(r'인것같'): '인 것 같',
      RegExp(r'한것같'): '한 것 같',
      RegExp(r'할것같'): '할 것 같',
      RegExp(r'거에요'): '거예요',
    };

    spellingRules.forEach((pattern, replacement) {
      s = s.replaceAllMapped(pattern, (m) {
        String out = replacement;
        for (int g = 1; g <= m.groupCount; g++) {
          out = out.replaceAll('\$$g', m.group(g) ?? '');
        }
        return out;
      });
    });

    // 조사 앞 불필요한 공백 제거
    s = s.replaceAllMapped(
      RegExp(r'([가-힣])\s+(은|는|이|가|을|를|에|에서|에게|으로|로|과|와|도|만|까지|부터)(?=\s|[,.!?]|$)'),
      (m) => '${m.group(1)}${m.group(2)}',
    );

    s = s.replaceAll(RegExp(r'\s{2,}'), ' ').trim();
    return s;
  }

  /// Google 번역 Chrome 확장 프로그램(bubble_compiled.js)의 OnePlatform(/v1/translate) 및 GTX(/translate_a/single) 엔진 탑재
  static Future<String> translateWithGoogleChromeExtensionEngine(
    String text, {
    required String sourceLang,
    required String targetLang,
  }) async {
    final cleaned = cleanOcrSourceText(text, sourceLang);
    if (cleaned.isEmpty) return '';

    // 1순위: Google 번역 Chrome 확장 프로그램의 OnePlatform API (translate-pa.googleapis.com/v1/translate)
    try {
      final queryParams = <String, dynamic>{
        'params.client': 'gtx',
        'query.source_language': sourceLang,
        'query.target_language': targetLang,
        'query.display_language': 'ko',
        'query.text': cleaned,
        'key': _chromeExtApiKey,
        'data_types': [
          'TRANSLATION',
          'SENTENCE_SPLITS',
          'QUERY_CORRECTION_AUTOCORRECT',
        ],
      };

      final uri = Uri.parse(_chromeExtOnePlatformUrl).replace(queryParameters: queryParams);
      final resp = await http.get(
        uri,
        headers: {
          'Accept': 'application/json, text/plain, */*',
          'User-Agent':
              'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/130.0.0.0 Safari/537.36',
        },
      ).timeout(const Duration(seconds: 6));

      if (resp.statusCode == 200) {
        final bodyStr = utf8.decode(resp.bodyBytes).trim();
        final decoded = jsonDecode(bodyStr);
        if (decoded is Map) {
          if (decoded['translation'] != null && decoded['translation'].toString().trim().isNotEmpty) {
            return polishKoreanSpacingAndSpelling(decoded['translation'].toString());
          }
          if (decoded['sentences'] is List) {
            final parts = <String>[];
            for (final s in decoded['sentences']) {
              if (s is Map && s['trans'] != null) {
                parts.add(s['trans'].toString().trim());
              }
            }
            if (parts.isNotEmpty) {
              return polishKoreanSpacingAndSpelling(parts.join(' '));
            }
          }
        } else if (decoded is List && decoded.isNotEmpty) {
          // JSPB 배열 형태로 반환될 때 첫 번째 필드(1: translation) 또는 두 번째 필드(2: sentences) 추출
          if (decoded[0] is String && (decoded[0] as String).trim().isNotEmpty) {
            return polishKoreanSpacingAndSpelling(decoded[0] as String);
          }
          if (decoded.length > 1 && decoded[1] is List) {
            final parts = <String>[];
            for (final s in decoded[1]) {
              if (s is List && s.isNotEmpty && s[0] != null) {
                parts.add(s[0].toString().trim());
              }
            }
            if (parts.isNotEmpty) {
              return polishKoreanSpacingAndSpelling(parts.join(' '));
            }
          }
        }
      }
    } catch (_) {}

    // 2순위: Google 번역 Chrome 확장 프로그램의 GTX Single API (자동 오타 교정 dt=qc & 문장 분리 dt=t & dj=1 포함)
    try {
      final uri = Uri.parse(_chromeExtAjaxSingleUrl).replace(queryParameters: {
        'client': 'gtx',
        'sl': sourceLang,
        'tl': targetLang,
        'hl': 'ko',
        'dt': ['t', 'qc', 'bd'],
        'dj': '1',
        'ie': 'UTF-8',
        'oe': 'UTF-8',
        'source': 'bubble',
        'q': cleaned,
      });
      final resp = await http.get(
        uri,
        headers: {
          'User-Agent':
              'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/130.0.0.0 Safari/537.36',
        },
      ).timeout(const Duration(seconds: 6));

      if (resp.statusCode == 200) {
        final data = jsonDecode(utf8.decode(resp.bodyBytes));
        if (data is Map && data['sentences'] is List) {
          final parts = <String>[];
          for (final seg in data['sentences']) {
            if (seg is Map && seg['trans'] != null) {
              parts.add(seg['trans'].toString().trim());
            }
          }
          final result = parts.where((p) => p.isNotEmpty).join(' ');
          if (result.isNotEmpty) return polishKoreanSpacingAndSpelling(result);
        }
      }
    } catch (_) {}

    try {
      final res = await _translator.translate(cleaned, from: sourceLang, to: targetLang);
      return polishKoreanSpacingAndSpelling(res.text);
    } catch (_) {
      return cleaned;
    }
  }

  /// 한 페이지 안의 모든 말풍선 문장들을 문맥이 이어지도록 한꺼번에 Google Chrome 확장 번역기로 번역!
  /// (문맥 단절로 인해 반말/존댓말이나 대명사가 엉망이 되는 현상을 막아줍니다)
  static Future<List<String>> translatePageSentencesWithContext(
    List<String> sentences, {
    required String sourceLang,
    required String targetLang,
  }) async {
    if (sentences.isEmpty) return [];
    final cleanedList = sentences.map((s) => cleanOcrSourceText(s, sourceLang)).toList();

    // 여러 말풍선을 줄바꿈으로 묶어서 한 번에 번역 요청 후 다시 줄 단위로 분리하면 앞뒤 대사 문맥이 유지됨!
    try {
      final joined = cleanedList.join('\n');
      final translatedBlock = await translateWithGoogleChromeExtensionEngine(
        joined,
        sourceLang: sourceLang,
        targetLang: targetLang,
      );
      final lines = translatedBlock
          .split('\n')
          .map((l) => polishKoreanSpacingAndSpelling(l))
          .where((l) => l.isNotEmpty)
          .toList();
      if (lines.length == sentences.length) {
        return lines;
      }
    } catch (_) {}

    // 줄 개수가 다를 경우 각 말풍선별로 정확하게 개별 번역
    final List<String> results = List.from(sentences);
    for (int i = 0; i < sentences.length; i++) {
      final tr = await translateWithGoogleChromeExtensionEngine(
        sentences[i],
        sourceLang: sourceLang,
        targetLang: targetLang,
      );
      if (tr.isNotEmpty) {
        results[i] = tr;
      }
    }
    return results;
  }

  static Future<File> preTranslateWholeEpub({
    required File sourceEpub,
    required String targetLang,
    String sourceLang = 'ja',
    required void Function(int current, int total, String status) onProgress,
  }) async {
    final outPath = sourceEpub.path.replaceAll(
      RegExp(r'\.epub$', caseSensitive: false),
      '_${sourceLang}_to_${targetLang}_translated.epub',
    );
    final outFile = File(outPath);
    if (await outFile.exists()) {
      return outFile;
    }

    final bytes = await sourceEpub.readAsBytes();
    final archive = ZipDecoder().decodeBytes(bytes);
    final newArchive = Archive();

    final htmlFiles = archive.files.where((f) =>
        f.isFile &&
        (f.name.endsWith('.xhtml') || f.name.endsWith('.html') || f.name.endsWith('.htm'))).toList();

    int processed = 0;
    final total = htmlFiles.length;

    for (final file in archive.files) {
      if (!file.isFile) continue;

      if (file.name.endsWith('.xhtml') || file.name.endsWith('.html') || file.name.endsWith('.htm')) {
        processed++;
        onProgress(processed, total, '사전 번역 중 ($processed / $total)...');
        final content = utf8.decode(file.content as List<int>, allowMalformed: true);
        final translatedHtml = await _translateHtmlPreservingFonts(content, sourceLang, targetLang);
        final encoded = utf8.encode(translatedHtml);
        newArchive.addFile(ArchiveFile(file.name, encoded.length, encoded));
      } else if (file.name.endsWith('.css')) {
        final cssContent = utf8.decode(file.content as List<int>, allowMalformed: true);
        final patchedCss = cssContent
            .replaceAll(RegExp(r'writing-mode\s*:\s*vertical-rl', caseSensitive: false), 'writing-mode: horizontal-tb')
            .replaceAll(RegExp(r'-webkit-writing-mode\s*:\s*vertical-rl', caseSensitive: false), '-webkit-writing-mode: horizontal-tb')
            .replaceAll(RegExp(r'-epub-writing-mode\s*:\s*vertical-rl', caseSensitive: false), '-epub-writing-mode: horizontal-tb');
        final encodedCss = utf8.encode(patchedCss);
        newArchive.addFile(ArchiveFile(file.name, encodedCss.length, encodedCss));
      } else {
        newArchive.addFile(file);
      }
    }

    final zipBytes = ZipEncoder().encode(newArchive);
    await outFile.writeAsBytes(zipBytes!);
    return outFile;
  }

  static String _stripJapaneseRubyAndTags(String rawHtml) {
    var cleaned = rawHtml
        .replaceAll(RegExp(r'<rt[^>]*>.*?</rt>', dotAll: true, caseSensitive: false), '')
        .replaceAll(RegExp(r'<rp[^>]*>.*?</rp>', dotAll: true, caseSensitive: false), '');
    cleaned = cleaned.replaceAll(RegExp(r'<[^>]+>'), '').trim();
    return cleaned;
  }

  static Future<String> _translateHtmlPreservingFonts(
      String html, String sourceLang, String targetLang) async {
    final paragraphRegex = RegExp(r'(<p[^>]*>)(.*?)(</p>)', dotAll: true);
    final matches = paragraphRegex.allMatches(html).toList();
    if (matches.isEmpty) return html;

    final StringBuffer buffer = StringBuffer();
    int lastEnd = 0;

    final List<String> plainTexts = [];
    for (final m in matches) {
      plainTexts.add(_stripJapaneseRubyAndTags(m.group(2)!));
    }

    final List<String> translatedList = List.filled(plainTexts.length, '');
    const int chunkSize = 15;
    for (int i = 0; i < plainTexts.length; i += chunkSize) {
      final end = (i + chunkSize < plainTexts.length) ? i + chunkSize : plainTexts.length;
      final slice = plainTexts.sublist(i, end);
      final nonEmptyIndices = <int>[];
      final nonEmptyTexts = <String>[];

      for (int j = 0; j < slice.length; j++) {
        if (slice[j].isNotEmpty) {
          nonEmptyIndices.add(i + j);
          nonEmptyTexts.add(slice[j]);
        }
      }

      if (nonEmptyTexts.isNotEmpty) {
        final batchOut = await translatePageSentencesWithContext(
          nonEmptyTexts,
          sourceLang: sourceLang,
          targetLang: targetLang,
        );
        for (int k = 0; k < nonEmptyIndices.length; k++) {
          translatedList[nonEmptyIndices[k]] =
              (k < batchOut.length) ? batchOut[k] : nonEmptyTexts[k];
        }
      }
    }

    for (int idx = 0; idx < matches.length; idx++) {
      final m = matches[idx];
      buffer.write(html.substring(lastEnd, m.start));
      final openTag = m.group(1)!;
      final origInner = m.group(2)!;
      final closeTag = m.group(3)!;
      final tr = translatedList[idx];

      if (tr.isNotEmpty) {
        buffer.write(
          '$openTag<span style="font-family:inherit; background:rgba(255,250,220,0.92); '
          'color:#1e1e1e; padding:3px 7px; border-radius:8px; border:1px solid rgba(0,0,0,0.15); '
          'display:inline-block; margin:2px 0; word-break:keep-all;">$tr</span>$closeTag',
        );
      } else {
        buffer.write('$openTag$origInner$closeTag');
      }
      lastEnd = m.end;
    }
    buffer.write(html.substring(lastEnd));
    return buffer.toString();
  }

  static bool _belongsToSameTextRegion(_TextColUnit a, _TextColUnit b) {
    if (a.isVerticalLine != b.isVerticalLine) return false;

    final double charSize = math.max<double>(a.avgCharSize, b.avgCharSize).clamp(8.0, 120.0).toDouble();

    final double hGap = math.max<double>(0.0, math.max<double>(a.rect.left - b.rect.right, b.rect.left - a.rect.right));
    final double vGap = math.max<double>(0.0, math.max<double>(a.rect.top - b.rect.bottom, b.rect.top - a.rect.bottom));

    final double overlapHeight = math.min<double>(a.rect.bottom, b.rect.bottom) - math.max<double>(a.rect.top, b.rect.top);
    final double minHeight = math.min<double>(a.rect.height, b.rect.height);
    final double overlapWidth = math.min<double>(a.rect.right, b.rect.right) - math.max<double>(a.rect.left, b.rect.left);
    final double minWidth = math.min<double>(a.rect.width, b.rect.width);

    if (a.isVerticalLine) {
      final bool verticallyAligned = overlapHeight > -charSize * 0.45 || vGap < charSize * 0.85;
      final bool horizontallyClose = hGap < charSize * 1.95;
      if (verticallyAligned && horizontallyClose) return true;

      if (overlapWidth > minWidth * 0.35 && vGap < charSize * 1.3) return true;
      return false;
    } else {
      final bool horizontallyAligned = overlapWidth > minWidth * 0.25 || (a.rect.left - b.rect.left).abs() < charSize * 2.2;
      final bool verticallyClose = vGap < charSize * 1.25;
      if (horizontallyAligned && verticallyClose) return true;

      if (overlapHeight > minHeight * 0.45 && hGap < charSize * 1.8) return true;
      return false;
    }
  }

  static bool _isRubyFuriganaColumn(_TextColUnit candidate, List<_TextColUnit> allUnits, double medianSize) {
    if (!candidate.isVerticalLine) return false;
    final onlyKana = RegExp(r'^[\u3040-\u309F\u30A0-\u30FF\u30FC\s・。、]+$').hasMatch(candidate.text);
    if (!onlyKana) return false;
    if (candidate.avgCharSize >= medianSize * 0.65) return false;

    for (final mainCol in allUnits) {
      if (identical(candidate, mainCol) || !mainCol.isVerticalLine) continue;
      if (mainCol.avgCharSize >= medianSize * 0.8) {
        final double vOverlap = math.min<double>(candidate.rect.bottom, mainCol.rect.bottom) -
            math.max<double>(candidate.rect.top, mainCol.rect.top);
        final double hDist = (candidate.rect.left - mainCol.rect.right).abs();
        final double hDist2 = (candidate.rect.right - mainCol.rect.left).abs();
        if (vOverlap > 0 && math.min<double>(hDist, hDist2) < mainCol.avgCharSize * 0.9) {
          return true;
        }
      }
    }
    return false;
  }

  static bool _detectDarkBackground(
      ByteData? rgbaBytes, int imgW, int imgH, ui.Rect rect) {
    if (rgbaBytes == null || imgW <= 0 || imgH <= 0) return false;

    final int left = rect.left.round().clamp(0, imgW - 1).toInt();
    final int right = rect.right.round().clamp(0, imgW - 1).toInt();
    final int top = rect.top.round().clamp(0, imgH - 1).toInt();
    final int bottom = rect.bottom.round().clamp(0, imgH - 1).toInt();

    if (right <= left || bottom <= top) return false;

    int darkCount = 0;
    int totalSamples = 0;
    final int stepX = math.max<int>(1, (right - left) ~/ 8);
    final int stepY = math.max<int>(1, (bottom - top) ~/ 8);

    for (int y = top; y <= bottom; y += stepY) {
      for (int x = left; x <= right; x += stepX) {
        final int offset = (y * imgW + x) * 4;
        if (offset + 2 < rgbaBytes.lengthInBytes) {
          final int r = rgbaBytes.getUint8(offset);
          final int g = rgbaBytes.getUint8(offset + 1);
          final int b = rgbaBytes.getUint8(offset + 2);
          final double lum = 0.299 * r + 0.587 * g + 0.114 * b;
          if (lum < 110.0) {
            darkCount++;
          }
          totalSamples++;
        }
      }
    }

    if (totalSamples == 0) return false;
    return (darkCount / totalSamples) >= 0.58;
  }

  static Future<void> preTranslateAllImages({
    required String bookKey,
    required List<File> imageFiles,
    required String targetLang,
    String sourceLang = 'ja',
    TextRecognitionScript script = TextRecognitionScript.japanese,
    bool forceRetranslate = false,
    required void Function(int current, int total, String status) onProgress,
  }) async {
    if (forceRetranslate) {
      await StorageService.clearImageBubbleCacheForBook(bookKey);
    }

    final recognizer = TextRecognizer(script: script);
    final isCjkScript =
        script == TextRecognitionScript.japanese || script == TextRecognitionScript.chinese;

    try {
      for (int i = 0; i < imageFiles.length; i++) {
        onProgress(
          i + 1,
          imageFiles.length,
          '사전 번역 중 (${i + 1} / ${imageFiles.length})...',
        );
        if (!forceRetranslate) {
          final cached = await StorageService.getImageBubbleCache(bookKey, i);
          if (cached != null) continue;
        }

        final file = imageFiles[i];
        final bytes = await file.readAsBytes();
        final codec = await ui.instantiateImageCodec(bytes);
        final frame = await codec.getNextFrame();
        final ui.Image decodedImg = frame.image;
        final double imgWidth = decodedImg.width.toDouble();
        final double imgHeight = decodedImg.height.toDouble();
        final ByteData? rgbaBytes =
            await decodedImg.toByteData(format: ui.ImageByteFormat.rawRgba);

        final inputImage = InputImage.fromFilePath(file.path);
        final recognized = await recognizer.processImage(inputImage);

        final List<_TextColUnit> rawUnits = [];
        for (final block in recognized.blocks) {
          for (final line in block.lines) {
            final t = line.text.trim();
            if (t.isEmpty) continue;
            final r = line.boundingBox;
            if (r.width < 5 || r.height < 5) continue;

            final bool isVertLine = isCjkScript &&
                (r.height > r.width * 1.25) &&
                (t.length >= 2 || r.height > r.width * 1.5);
            final double charSize = isVertLine ? r.width : r.height;

            rawUnits.add(_TextColUnit(
              rect: r,
              text: t,
              avgCharSize: charSize,
              isVerticalLine: isVertLine,
            ));
          }
        }

        if (rawUnits.isEmpty) {
          await StorageService.saveImageBubbleCache(bookKey, i, []);
          continue;
        }

        final sortedSizes = rawUnits.map((u) => u.avgCharSize).toList()..sort();
        final double medianSize = sortedSizes[sortedSizes.length ~/ 2];
        final filteredUnits = rawUnits
            .where((u) => !_isRubyFuriganaColumn(u, rawUnits, medianSize))
            .toList();

        final int n = filteredUnits.length;
        final List<bool> visited = List.filled(n, false);
        final List<List<_TextColUnit>> textClusters = [];

        for (int idx = 0; idx < n; idx++) {
          if (visited[idx]) continue;
          final cluster = <_TextColUnit>[];
          final queue = <int>[idx];
          visited[idx] = true;

          while (queue.isNotEmpty) {
            final cur = queue.removeAt(0);
            final curUnit = filteredUnits[cur];
            cluster.add(curUnit);

            for (int next = 0; next < n; next++) {
              if (!visited[next]) {
                if (_belongsToSameTextRegion(curUnit, filteredUnits[next])) {
                  visited[next] = true;
                  queue.add(next);
                }
              }
            }
          }
          textClusters.add(cluster);
        }

        final List<ui.Rect> exactRects = [];
        final List<String> mergedSentences = [];
        final List<bool> isSerifFlags = [];
        final List<bool> isBoldFlags = [];
        final List<bool> isDarkBgFlags = [];

        for (final cluster in textClusters) {
          final bool clusterIsVertical = cluster.first.isVerticalLine;

          if (clusterIsVertical) {
            cluster.sort((a, b) {
              final double xDiff = b.rect.center.dx - a.rect.center.dx;
              if (xDiff.abs() > medianSize * 0.45) {
                return xDiff > 0 ? 1 : -1;
              }
              return a.rect.top.compareTo(b.rect.top);
            });
          } else {
            cluster.sort((a, b) {
              final double yDiff = a.rect.center.dy - b.rect.center.dy;
              if (yDiff.abs() > medianSize * 0.45) {
                return yDiff > 0 ? 1 : -1;
              }
              return a.rect.left.compareTo(b.rect.left);
            });
          }

          double minL = cluster.first.rect.left;
          double minT = cluster.first.rect.top;
          double maxR = cluster.first.rect.right;
          double maxB = cluster.first.rect.bottom;

          for (final u in cluster) {
            if (u.rect.left < minL) minL = u.rect.left;
            if (u.rect.top < minT) minT = u.rect.top;
            if (u.rect.right > maxR) maxR = u.rect.right;
            if (u.rect.bottom > maxB) maxB = u.rect.bottom;
          }

          final String joiner = (clusterIsVertical || isCjkScript) ? '' : ' ';
          String combinedText = cluster.map((u) => u.text).join(joiner).trim();
          if (clusterIsVertical) {
            combinedText = combinedText.replaceAll(RegExp(r'\s+'), '');
          }
          if (combinedText.isEmpty) continue;

          final strictRect = ui.Rect.fromLTRB(
            minL.clamp(0.0, imgWidth).toDouble(),
            minT.clamp(0.0, imgHeight).toDouble(),
            maxR.clamp(0.0, imgWidth).toDouble(),
            maxB.clamp(0.0, imgHeight).toDouble(),
          );

          final bool darkBg = _detectDarkBackground(
            rgbaBytes,
            decodedImg.width,
            decodedImg.height,
            strictRect,
          );

          exactRects.add(strictRect);
          mergedSentences.add(combinedText);

          final bool isShout = combinedText.contains('!') ||
              combinedText.contains('！') ||
              combinedText.contains('?!') ||
              combinedText.contains('？！');
          isSerifFlags.add(!isShout);
          isBoldFlags.add(isShout);
          isDarkBgFlags.add(darkBg);
        }

        // Google 번역 Chrome 확장 프로그램 엔진으로 페이지 내 대사들을 문맥 유지 번역
        final List<String> translatedSentences = await translatePageSentencesWithContext(
          mergedSentences,
          sourceLang: sourceLang,
          targetLang: targetLang,
        );

        final List<BubbleTranslation> bubbles = [];
        for (int k = 0; k < exactRects.length; k++) {
          final rect = exactRects[k];
          bubbles.add(
            BubbleTranslation(
              leftRatio: (rect.left / imgWidth).clamp(0.0, 0.99).toDouble(),
              topRatio: (rect.top / imgHeight).clamp(0.0, 0.99).toDouble(),
              widthRatio: (rect.width / imgWidth).clamp(0.015, 0.99).toDouble(),
              heightRatio: (rect.height / imgHeight).clamp(0.015, 0.99).toDouble(),
              originalText: mergedSentences[k],
              translatedText: k < translatedSentences.length ? translatedSentences[k] : mergedSentences[k],
              isSerif: isSerifFlags[k],
              isBold: isBoldFlags[k],
              isDarkBg: isDarkBgFlags[k],
            ),
          );
        }

        await StorageService.saveImageBubbleCache(bookKey, i, bubbles);
      }
    } finally {
      await recognizer.close();
    }
  }
}
