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

  /// 한국어 띄어쓰기 및 맞춤법 자동 교정기 (번역 결과물의 어색한 붙여쓰기·맞춤법·문장부호 보정)
  static String polishKoreanSpacingAndSpelling(String raw) {
    if (raw.trim().isEmpty) return '';
    String s = raw.trim();

    // 1. 일본어/번역기 특유의 불필요한 기호 및 공백 정규화
    s = s
        .replaceAll('</끝>', '')
        .replaceAll(RegExp(r'###.*'), '')
        .replaceAll('「', '"')
        .replaceAll('」', '"')
        .replaceAll('『', '"')
        .replaceAll('』', '"')
        .replaceAll('…', '...')
        .replaceAll(RegExp(r'[ \t]+'), ' ');

    // 2. 문장부호 뒤 자동 띄어쓰기 보정 (마침표, 쉼표, 느낌표, 물음표 뒤에 한글이 바로 붙은 경우 띄어쓰기 추가)
    s = s.replaceAllMapped(
      RegExp(r'([,!?])[가-힣]'),
      (m) => '${m.group(0)!.substring(0, 1)} ${m.group(0)!.substring(1)}',
    );
    s = s.replaceAllMapped(
      RegExp(r'(\.{1,3})([가-힣])'),
      (m) => '${m.group(1)} ${m.group(2)}',
    );

    // 3. 자주 틀리는 한국어 맞춤법 및 의존명사 띄어쓰기 교정 규칙
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
      RegExp(r'같은데'): '같은데',
      RegExp(r'모르겠어([요]?)'): '모르겠어\$1',
      RegExp(r'괜찮아([요]?)'): '괜찮아\$1',
      RegExp(r'거에요'): '거예요',
      RegExp(r'건가요'): '건가요',
      RegExp(r'뭐야'): '뭐야',
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

    // 4. 조사 앞 불필요한 공백 제거 (예: "나 는" -> "나는", "그 것 은" -> "그것은")
    s = s.replaceAllMapped(
      RegExp(r'([가-힣])\s+(은|는|이|가|을|를|에|에서|에게|으로|로|과|와|도|만|까지|부터)(?=\s|[,.!?]|$)'),
      (m) => '${m.group(1)}${m.group(2)}',
    );

    // 5. 중복 공백 정리
    s = s.replaceAll(RegExp(r'\s{2,}'), ' ').trim();
    return s;
  }

  /// Gugugo 오픈소스 모델(squarelike/Gugugo-koja-1.3B-V0.95 및 Gugugo-koen-7B-V1.1) 프로토콜 기반 번역 + 한국어 띄어쓰기/맞춤법 보정
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
              if (out.isNotEmpty) return polishKoreanSpacingAndSpelling(out);
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
            if (gen.isNotEmpty) return polishKoreanSpacingAndSpelling(gen);
          }
        }
      } catch (_) {}
    }

    // 내장 신경망 번역 (dj=1 옵션으로 문장 세그먼트별 정확한 띄어쓰기 결합)
    try {
      final uri = Uri.https('translate.googleapis.com', '/translate_a/single', {
        'client': 'gtx',
        'sl': sourceLang,
        'tl': targetLang,
        'dt': 't',
        'dj': '1',
        'q': cleaned,
      });
      final resp = await http.get(uri).timeout(const Duration(seconds: 6));
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

  /// 5. 말풍선/텍스트 영역의 원본 이미지 픽셀 밝기를 샘플링하여 검은색 배경인지 자동 판별!
  /// 배경 픽셀들의 평균 밝기(Luminance)가 115 미만이면 검은색/어두운 배경으로 판정 -> 검은 배경 + 흰색 글씨로 렌더링!
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
    // 글자 획(약 20~35%)을 제외하고도 영역의 58% 이상이 어두우면 검은색 배경 말풍선/박스로 판정
    return (darkCount / totalSamples) >= 0.58;
  }

  /// 2. 만화 말풍선 + 일반 PDF/사진 문구 통합 번역 (세로 일본어도 말풍선 크기에 맞춰 가로 한글로 조판 + 검은 배경 자동 감지)
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
            // 세로쓰기 일본어 대사: 오른쪽 열부터 왼쪽 열 순서로 문장 결합
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

          // 원문 말풍선 크기를 넘지 않도록 바운딩 박스 고정
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
