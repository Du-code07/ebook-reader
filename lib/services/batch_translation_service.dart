import 'dart:convert';
import 'dart:io';
import 'dart:math' as math;
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

  static Future<String> translateWithGugugoPipeline(
    String text, {
    required String sourceLang,
    required String targetLang,
  }) async {
    final cleaned = text.trim();
    if (cleaned.isEmpty) return '';

    final gugugoUrl = await StorageService.getGugugoServerUrl();
    final hfToken = await StorageService.getGugugoHfToken();

    if (gugugoUrl.isNotEmpty) {
      try {
        final base = gugugoUrl.endsWith('/') ? gugugoUrl.substring(0, gugugoUrl.length - 1) : gugugoUrl;
        final trType = sourceLang == 'ja' ? 'JA->KO' : 'EN->KO';
        for (final endpoint in ['$base/api/predict', '$base/run/predict']) {
          final resp = await http
              .post(
                Uri.parse(endpoint),
                headers: {'Content-Type': 'application/json'},
                body: jsonEncode({
                  'data': [cleaned, trType]
                }),
              )
              .timeout(const Duration(seconds: 8));
          if (resp.statusCode == 200) {
            final decoded = jsonDecode(utf8.decode(resp.bodyBytes));
            final dataList = decoded['data'];
            if (dataList is List && dataList.isNotEmpty) {
              var out = dataList.first.toString().trim();
              if (out.contains('</끝>')) {
                out = out.substring(0, out.indexOf('</끝>')).trim();
              }
              if (out.isNotEmpty) return out;
            }
          }
        }
      } catch (_) {}
    }

    if (sourceLang == 'ja' || sourceLang == 'en') {
      try {
        final modelId = sourceLang == 'ja'
            ? 'squarelike/Gugugo-koja-1.3B-V0.95'
            : 'squarelike/Gugugo-koen-1.3B-V1.0';
        final langLabel = sourceLang == 'ja' ? '일본어' : '영어';
        final prompt = '### $langLabel: $cleaned</끝>\n### 한국어:';

        final headers = <String, String>{'Content-Type': 'application/json'};
        if (hfToken.isNotEmpty) {
          headers['Authorization'] = 'Bearer $hfToken';
        }

        final resp = await http
            .post(
              Uri.parse('https://api-inference.huggingface.co/models/$modelId'),
              headers: headers,
              body: jsonEncode({
                'inputs': prompt,
                'parameters': {
                  'max_new_tokens': 256,
                  'temperature': 0.3,
                  'return_full_text': false,
                },
              }),
            )
            .timeout(const Duration(seconds: 5));

        if (resp.statusCode == 200) {
          final decoded = jsonDecode(utf8.decode(resp.bodyBytes));
          if (decoded is List && decoded.isNotEmpty) {
            var gen = (decoded.first['generated_text'] ?? '').toString();
            if (gen.startsWith(prompt)) {
              gen = gen.substring(prompt.length);
            }
            if (gen.contains('</끝>')) {
              gen = gen.substring(0, gen.indexOf('</끝>'));
            }
            gen = gen.replaceAll(RegExp(r'###.*'), '').trim();
            if (gen.isNotEmpty) return gen;
          }
        }
      } catch (_) {}
    }

    try {
      final uri = Uri.https('translate.googleapis.com', '/translate_a/single', {
        'client': 'gtx',
        'sl': sourceLang,
        'tl': targetLang,
        'dt': 't',
        'q': cleaned,
      });
      final resp = await http.get(uri).timeout(const Duration(seconds: 6));
      if (resp.statusCode == 200) {
        final data = jsonDecode(utf8.decode(resp.bodyBytes));
        if (data is List && data.isNotEmpty && data[0] is List) {
          final buffer = StringBuffer();
          for (final seg in data[0]) {
            if (seg is List && seg.isNotEmpty && seg[0] != null) {
              buffer.write(seg[0].toString());
            }
          }
          final result = buffer.toString().trim();
          if (result.isNotEmpty) return result;
        }
      }
    } catch (_) {}

    try {
      final res = await _translator.translate(cleaned, from: sourceLang, to: targetLang);
      return res.text.trim();
    } catch (_) {
      return cleaned;
    }
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
    for (int i = 0; i < plainTexts.length; i++) {
      if (plainTexts[i].isNotEmpty) {
        translatedList[i] = await translateWithGugugoPipeline(
          plainTexts[i],
          sourceLang: sourceLang,
          targetLang: targetLang,
        );
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
        final double imgWidth = frame.image.width.toDouble();
        final double imgHeight = frame.image.height.toDouble();

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
        final List<bool> isVerticalFlags = [];

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

          final bool isVertBubble = clusterIsVertical && (strictRect.height >= strictRect.width * 1.05);

          exactRects.add(strictRect);
          mergedSentences.add(combinedText);

          final bool isShout = combinedText.contains('!') ||
              combinedText.contains('！') ||
              combinedText.contains('?!') ||
              combinedText.contains('？！');
          isSerifFlags.add(!isShout);
          isBoldFlags.add(isShout);
          isVerticalFlags.add(isVertBubble);
        }

        final List<String> translatedSentences = List.from(mergedSentences);
        for (int k = 0; k < mergedSentences.length; k++) {
          final tr = await translateWithGugugoPipeline(
            mergedSentences[k],
            sourceLang: sourceLang,
            targetLang: targetLang,
          );
          if (tr.isNotEmpty) {
            translatedSentences[k] = tr;
          }
        }

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
              translatedText: translatedSentences[k],
              isSerif: isSerifFlags[k],
              isBold: isBoldFlags[k],
              isVertical: isVerticalFlags[k],
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
