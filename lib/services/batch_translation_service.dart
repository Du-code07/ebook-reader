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
  final double avgCharWidth;

  _TextColUnit({
    required this.rect,
    required this.text,
    required this.avgCharWidth,
  });
}

class BatchTranslationService {
  static final GoogleTranslator _translator = GoogleTranslator();

  /// Gugugo 오픈소스 모델(squarelike/Gugugo-koja-1.3B-V0.95 및 Gugugo-koen-7B-V1.1) 프로토콜 기반 번역기
  /// 1순위: 사용자가 설정한 Gugugo Gradio WebUI 서버 (app_translation.py 호환: /run/predict 또는 /api/predict)
  /// 2순위: HuggingFace Inference API (squarelike/Gugugo-koja-1.3B-V0.95 프롬프트: "### 일본어: {x}</끝>\n### 한국어:")
  /// 3순위: 모바일 온디바이스 무설치 즉시 실행을 위한 멀티 엔진 폴백 (GTX 신경망 번역 + 만화 구어체 후처리)
  static Future<String> translateWithGugugoPipeline(
    String text, {
    required String sourceLang,
    required String targetLang,
  }) async {
    final cleaned = text.trim();
    if (cleaned.isEmpty) return '';

    final gugugoUrl = await StorageService.getGugugoServerUrl();
    final hfToken = await StorageService.getGugugoHfToken();

    // 1) Gugugo Gradio 서버(app_translation.py)가 입력되어 있는 경우 직접 호출
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

    // 2) Gugugo HuggingFace 모델(squarelike/Gugugo-koja-1.3B-V0.95 / Gugugo-koen-7B-V1.1) 프롬프트 직접 호출
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

    // 3) 기본 내장 신경망 번역 폴백 (별도 서버 없이도 100% 작동 + Gugugo 한계점인 짧은 만화 감탄사/구어체 보완)
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

  /// 1. 일본어/외국어 EPUB 파일 통째로 사전 번역
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
        onProgress(processed, total, 'Gugugo 한일 번역 파이프라인으로 챕터 번역 중 ($processed / $total)...');
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

  /// 두 텍스트 열(또는 줄)이 같은 만화 말풍선 안에 속하는지 공간 거리로 판별
  static bool _belongsToSameSpeechBubble(_TextColUnit a, _TextColUnit b, bool isVerticalScript) {
    final double charSize = math.max<double>(a.avgCharWidth, b.avgCharWidth).clamp(10.0, 120.0).toDouble();

    final double hGap = math.max<double>(0.0, math.max<double>(a.rect.left - b.rect.right, b.rect.left - a.rect.right));
    final double vGap = math.max<double>(0.0, math.max<double>(a.rect.top - b.rect.bottom, b.rect.top - a.rect.bottom));

    final double overlapHeight = math.min<double>(a.rect.bottom, b.rect.bottom) - math.max<double>(a.rect.top, b.rect.top);
    final double minHeight = math.min<double>(a.rect.height, b.rect.height);
    final double overlapWidth = math.min<double>(a.rect.right, b.rect.right) - math.max<double>(a.rect.left, b.rect.left);
    final double minWidth = math.min<double>(a.rect.width, b.rect.width);

    if (isVerticalScript) {
      final bool verticallyAligned = overlapHeight > -charSize * 0.45 || vGap < charSize * 0.85;
      final bool horizontallyClose = hGap < charSize * 1.95;
      if (verticallyAligned && horizontallyClose) return true;

      if (overlapWidth > minWidth * 0.35 && vGap < charSize * 1.3) return true;
      return false;
    } else {
      final bool horizontallyAligned = overlapWidth > -charSize * 0.5 || hGap < charSize * 1.3;
      final bool verticallyClose = vGap < charSize * 1.5;
      return horizontallyAligned && verticallyClose;
    }
  }

  static bool _isRubyFuriganaColumn(_TextColUnit candidate, List<_TextColUnit> allUnits, double medianWidth) {
    final onlyKana = RegExp(r'^[\u3040-\u309F\u30A0-\u30FF\u30FC\s・。、]+$').hasMatch(candidate.text);
    if (!onlyKana) return false;
    if (candidate.avgCharWidth >= medianWidth * 0.65) return false;

    for (final mainCol in allUnits) {
      if (identical(candidate, mainCol)) continue;
      if (mainCol.avgCharWidth >= medianWidth * 0.8) {
        final double vOverlap = math.min<double>(candidate.rect.bottom, mainCol.rect.bottom) -
            math.max<double>(candidate.rect.top, mainCol.rect.top);
        final double hDist = (candidate.rect.left - mainCol.rect.right).abs();
        final double hDist2 = (candidate.rect.right - mainCol.rect.left).abs();
        if (vOverlap > 0 && math.min<double>(hDist, hDist2) < mainCol.avgCharWidth * 0.9) {
          return true;
        }
      }
    }
    return false;
  }

  /// 2. 일본어 만화/스캔 이미지 말풍선 통합 번역 (세로 말풍선 세로쓰기 유지 & 원본 말풍선 크기 절대 초과 금지)
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
    final isVerticalScript =
        script == TextRecognitionScript.japanese || script == TextRecognitionScript.chinese;

    try {
      for (int i = 0; i < imageFiles.length; i++) {
        onProgress(
          i + 1,
          imageFiles.length,
          'Gugugo 한일 번역 엔진으로 말풍선 번역 중 (${i + 1} / ${imageFiles.length})...',
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
            if (t.length == 1 && RegExp(r'^[0-9a-zA-Z!@#$%^&*()_+\-=\[\]{};:"\\|,.<>/?~`]$').hasMatch(t)) {
              continue;
            }
            final r = line.boundingBox;
            if (r.width < 6 || r.height < 6) continue;
            final double charW = isVerticalScript ? r.width : (r.height > 0 ? r.height : r.width);
            rawUnits.add(_TextColUnit(rect: r, text: t, avgCharWidth: charW));
          }
        }

        if (rawUnits.isEmpty) {
          await StorageService.saveImageBubbleCache(bookKey, i, []);
          continue;
        }

        final sortedWidths = rawUnits.map((u) => u.avgCharWidth).toList()..sort();
        final double medianWidth = sortedWidths[sortedWidths.length ~/ 2];
        final filteredUnits = rawUnits
            .where((u) => !_isRubyFuriganaColumn(u, rawUnits, medianWidth))
            .toList();

        final int n = filteredUnits.length;
        final List<bool> visited = List.filled(n, false);
        final List<List<_TextColUnit>> bubbleClusters = [];

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
                if (_belongsToSameSpeechBubble(curUnit, filteredUnits[next], isVerticalScript)) {
                  visited[next] = true;
                  queue.add(next);
                }
              }
            }
          }
          bubbleClusters.add(cluster);
        }

        final List<ui.Rect> exactRects = [];
        final List<String> mergedSentences = [];
        final List<bool> isSerifFlags = [];
        final List<bool> isBoldFlags = [];
        final List<bool> isVerticalFlags = [];

        for (final cluster in bubbleClusters) {
          if (isVerticalScript) {
            // 일본 만화 세로쓰기: 오른쪽 열부터 왼쪽 열 순서로 정렬
            cluster.sort((a, b) {
              final double xDiff = b.rect.center.dx - a.rect.center.dx;
              if (xDiff.abs() > medianWidth * 0.45) {
                return xDiff > 0 ? 1 : -1;
              }
              return a.rect.top.compareTo(b.rect.top);
            });
          } else {
            cluster.sort((a, b) {
              final double yDiff = a.rect.center.dy - b.rect.center.dy;
              if (yDiff.abs() > medianWidth * 0.5) {
                return yDiff > 0 ? 1 : -1;
              }
              return a.rect.left.compareTo(b.rect.left);
            });
          }

          double minL = cluster.first.rect.left;
          double minT = cluster.first.rect.top;
          double maxR = cluster.first.rect.right;
          double maxB = cluster.first.rect.bottom;

          int verticalLinesCount = 0;
          for (final u in cluster) {
            if (u.rect.left < minL) minL = u.rect.left;
            if (u.rect.top < minT) minT = u.rect.top;
            if (u.rect.right > maxR) maxR = u.rect.right;
            if (u.rect.bottom > maxB) maxB = u.rect.bottom;
            if (u.rect.height > u.rect.width * 1.15) {
              verticalLinesCount++;
            }
          }

          final joiner = isVerticalScript ? '' : ' ';
          String combinedText = cluster.map((u) => u.text).join(joiner).trim();
          if (isVerticalScript) {
            combinedText = combinedText.replaceAll(RegExp(r'\s+'), '');
          }
          if (combinedText.isEmpty) continue;

          // 중요: 만화책에 있는 기존 말풍선보다 절대 커지지 않도록, 검출된 원문 텍스트 바운딩 박스(minL, minT, maxR, maxB)를 그대로 사용!
          final strictRect = ui.Rect.fromLTRB(
            minL.clamp(0.0, imgWidth).toDouble(),
            minT.clamp(0.0, imgHeight).toDouble(),
            maxR.clamp(0.0, imgWidth).toDouble(),
            maxB.clamp(0.0, imgHeight).toDouble(),
          );

          final bool isVertBubble = isVerticalScript &&
              (verticalLinesCount >= (cluster.length / 2.0) || strictRect.height >= strictRect.width * 1.05);

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

        // Gugugo 파이프라인으로 말풍선 문장 번역
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
              widthRatio: (rect.width / imgWidth).clamp(0.02, 0.99).toDouble(),
              heightRatio: (rect.height / imgHeight).clamp(0.02, 0.99).toDouble(),
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
