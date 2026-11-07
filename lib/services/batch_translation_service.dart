import 'dart:convert';
import 'dart:io';
import 'dart:math' as math;
import 'dart:typed_data';
import 'dart:ui' as ui;
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
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

class TranslationTaskInfo {
  final int current;
  final int total;
  final String status;
  final bool isCompleted;

  TranslationTaskInfo({
    required this.current,
    required this.total,
    required this.status,
    this.isCompleted = false,
  });

  double get progress => total > 0 ? (current / total).clamp(0.0, 1.0).toDouble() : 0.0;
}

class BatchTranslationService {
  static final GoogleTranslator _translator = GoogleTranslator();

  /// 4. 백그라운드 번역 진행 상태 전역 알림기 (뒤로가기를 눌러 서재로 나가도 번역이 계속되며, 서재 파일 옆에 실시간 진행도 표시!)
  static final ValueNotifier<Map<String, TranslationTaskInfo>> activeTasks =
      ValueNotifier<Map<String, TranslationTaskInfo>>({});

  static final ValueNotifier<int> translationCompletedEvent = ValueNotifier<int>(0);

  static void _updateTaskProgress(String bookKey, int current, int total, String status) {
    final nextMap = Map<String, TranslationTaskInfo>.from(activeTasks.value);
    nextMap[bookKey] = TranslationTaskInfo(
      current: current,
      total: total,
      status: status,
    );
    activeTasks.value = nextMap;
  }

  static void _finishTask(String bookKey) {
    final nextMap = Map<String, TranslationTaskInfo>.from(activeTasks.value);
    nextMap.remove(bookKey);
    activeTasks.value = nextMap;
    translationCompletedEvent.value = translationCompletedEvent.value + 1;
  }

  static bool isBookTranslating(String bookKey) {
    return activeTasks.value.containsKey(bookKey);
  }

  /// OCR 오인식 노이즈 정리 (일본어/중국어 세로쓰기 만화에서 자주 섞이는 특수기호 노이즈 제거)
  static String cleanOcrSourceText(String raw, String sourceLang) {
    String s = raw.trim();
    if (s.isEmpty) return '';
    if (sourceLang == 'ja' || sourceLang == 'zh' || sourceLang == 'zh-cn') {
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
        .replaceAll(RegExp(r'[ 	]+'), ' ');

    // 문장부호 뒤 자동 띄어쓰기 보정
    s = s.replaceAllMapped(
      RegExp(r'([,?!])([가-힣a-zA-Z0-9])'),
      (m) => '${m.group(1)} ${m.group(2)}',
    );
    s = s.replaceAllMapped(
      RegExp(r'([.]{1})([가-힣])'),
      (m) => '.${m.group(2) != null ? " " + m.group(2)! : ""}',
    );

    // 자주 틀리는 한국어 맞춤법 및 어색한 번역투 자동 교정
    const corrections = <String, String>{
      '안되요': '안 돼요',
      '안되니까': '안 되니까',
      '안됩니다': '안 됩니다',
      '안되는': '안 되는',
      '되요': '돼요',
      '됬': '됐',
      '어떻해': '어떡해',
      '어떻게 해': '어떡해',
      '할께': '할게',
      '줄께': '줄게',
      '갈께': '갈게',
      '볼께': '볼게',
      '할꺼야': '할 거야',
      '될꺼야': '될 거야',
      '있을꺼야': '있을 거야',
      '거에요': '거예요',
      '뭐에요': '뭐예요',
      '아니에요': '아니에요',
      '왜냐면': '왜냐하면',
      '그치만': '그렇지만',
      '어쨋든': '어쨌든',
      '어쨌든간에': '어쨌든',
      '금새': '금세',
      '왠지': '왠지',
      '웬지': '왠지',
      '몇일': '며칠',
      '오랫만에': '오랜만에',
      '일찌기': '일찍이',
      '더우기': '더욱이',
      '깨달음': '깨달음',
    };
    corrections.forEach((wrong, right) {
      s = s.replaceAll(wrong, right);
    });

    // 의존명사 띄어쓰기 교정 (할수 -> 할 수, 한것 -> 한 것 등)
    s = s.replaceAllMapped(
      RegExp(r'([가-힣][을를은는던진할될갈볼줄])(수|것|줄|리|지|데|바)(?=[가-힣\s.,?!]|$)'),
      (m) => '${m.group(1)} ${m.group(2)}',
    );

    return s.replaceAll(RegExp(r'\s+'), ' ').trim();
  }

  // 1. OCR에 사용 중인 Google ML Kit의 공식 온디바이스 번역 라이브러리(com.google.mlkit:translate) 연동 채널
  static const MethodChannel _mlkitTranslateChannel = MethodChannel('ebook_reader/mlkit_translate');

  /// Google ML Kit 공식 온디바이스 번역 엔진으로 단문/문단 번역 (Japanese, Chinese, Korean, English -> 앱 설정 언어)
  static Future<String> translateWithOfficialMlKit(
    String text, {
    required String sourceLang,
    required String targetLang,
  }) async {
    final cleaned = cleanOcrSourceText(text, sourceLang);
    if (cleaned.isEmpty) return '';

    try {
      final String? res = await _mlkitTranslateChannel.invokeMethod<String>('translateText', {
        'text': cleaned,
        'sourceLang': sourceLang,
        'targetLang': targetLang,
      });
      if (res != null && res.trim().isNotEmpty) {
        return targetLang == 'ko' ? polishKoreanSpacingAndSpelling(res) : res.trim();
      }
    } catch (_) {}

    // 온디바이스 모델 초기 다운로드 전이거나 예외 시에만 폴백
    try {
      final fallback = await _translator.translate(
        cleaned,
        from: sourceLang == 'zh' ? 'zh-cn' : sourceLang,
        to: targetLang == 'zh' ? 'zh-cn' : targetLang,
      );
      return targetLang == 'ko' ? polishKoreanSpacingAndSpelling(fallback.text) : fallback.text.trim();
    } catch (_) {
      return cleaned;
    }
  }

  /// 페이지 내 모든 말풍선 대사를 Google ML Kit 공식 온디바이스 번역기로 일괄 번역
  static Future<List<String>> translatePageSentencesWithContext(
    List<String> rawSentences, {
    required String sourceLang,
    required String targetLang,
  }) async {
    if (rawSentences.isEmpty) return [];

    final List<String> cleanedList = rawSentences
        .map<String>((s) => cleanOcrSourceText(s, sourceLang))
        .toList();

    try {
      final List<dynamic>? batchRes = await _mlkitTranslateChannel.invokeMethod<List<dynamic>>(
        'translateBatch',
        {
          'texts': cleanedList,
          'sourceLang': sourceLang,
          'targetLang': targetLang,
        },
      );
      if (batchRes != null && batchRes.length == rawSentences.length) {
        return batchRes
            .map<String>((e) => targetLang == 'ko'
                ? polishKoreanSpacingAndSpelling(e.toString())
                : e.toString().trim())
            .toList();
      }
    } catch (_) {}

    final List<String> results = [];
    for (final s in cleanedList) {
      if (s.isEmpty) {
        results.add('');
      } else {
        final tr = await translateWithOfficialMlKit(
          s,
          sourceLang: sourceLang,
          targetLang: targetLang,
        );
        results.add(tr);
      }
    }
    return results;
  }

  static Future<File> preTranslateWholeEpub({
    required File sourceEpub,
    required String targetLang,
    String sourceLang = 'ja',
    void Function(int current, int total, String status)? onProgress,
  }) async {
    final String bookKey = sourceEpub.path;
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
        final lang = StorageService.appLangNotifier.value;
        final msg = lang == 'en' ? 'Pre-translating ($processed / $total)...' : (lang == 'zh' ? '正在预先翻译 ($processed / $total)...' : (lang == 'ja' ? '事前翻訳中 ($processed / $total)...' : '사전 번역 중 ($processed / $total)...'));
        _updateTaskProgress(bookKey, processed, total, msg);
        onProgress?.call(processed, total, msg);
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
    _finishTask(bookKey);
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
    void Function(int current, int total, String status)? onProgress,
  }) async {
    if (forceRetranslate) {
      await StorageService.clearImageBubbleCacheForBook(bookKey);
    }

    final recognizer = TextRecognizer(script: script);
    final isCjkScript =
        script == TextRecognitionScript.japanese || script == TextRecognitionScript.chinese;

    try {
      for (int i = 0; i < imageFiles.length; i++) {
        final lang = StorageService.appLangNotifier.value;
        final msg = lang == 'en' ? 'Pre-translating (${i + 1} / ${imageFiles.length})...' : (lang == 'zh' ? '正在预先翻译 (${i + 1} / ${imageFiles.length})...' : (lang == 'ja' ? '事前翻訳中 (${i + 1} / ${imageFiles.length})...' : '사전 번역 중 (${i + 1} / ${imageFiles.length})...'));
        _updateTaskProgress(bookKey, i + 1, imageFiles.length, msg);
        onProgress?.call(i + 1, imageFiles.length, msg);
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
      _finishTask(bookKey);
      await recognizer.close();
    }
  }
}
