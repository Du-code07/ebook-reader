import 'dart:convert';
import 'dart:io';
import 'dart:math' as math;
import 'dart:ui' as ui;
import 'package:archive/archive.dart';
import 'package:google_mlkit_text_recognition/google_mlkit_text_recognition.dart';
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

  /// 1. 일본어/외국어 EPUB 파일 통째로 사전 번역 (후리가나 <rt> 분리 오류 방지 + 원글 명조/고딕 글꼴 유지 + 딜레이 제로)
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
        onProgress(processed, total, '일본어 챕터 사전 번역 중 ($processed / $total)...');
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
        try {
          final joined = nonEmptyTexts.join('\n===SPLIT===\n');
          final res = await _translator.translate(joined, from: sourceLang, to: targetLang);
          final parts = res.text.split(RegExp(r'\s*===SPLIT===\s*'));
          for (int k = 0; k < nonEmptyIndices.length; k++) {
            translatedList[nonEmptyIndices[k]] =
                (k < parts.length) ? parts[k].trim() : nonEmptyTexts[k];
          }
        } catch (_) {
          for (int k = 0; k < nonEmptyIndices.length; k++) {
            translatedList[nonEmptyIndices[k]] = nonEmptyTexts[k];
          }
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

  /// 두 텍스트 열(또는 줄)이 같은 만화 말풍선 안에 속하는지 공간 거리로 판별
  static bool _belongsToSameSpeechBubble(_TextColUnit a, _TextColUnit b, bool isVerticalScript) {
    final charSize = math.max(a.avgCharWidth, b.avgCharWidth).clamp(10.0, 120.0);

    final hGap = math.max(0.0, math.max(a.rect.left - b.rect.right, b.rect.left - a.rect.right));
    final vGap = math.max(0.0, math.max(a.rect.top - b.rect.bottom, b.rect.top - a.rect.bottom));

    final overlapHeight = math.min(a.rect.bottom, b.rect.bottom) - math.max(a.rect.top, b.rect.top);
    final minHeight = math.min(a.rect.height, b.rect.height);
    final overlapWidth = math.min(a.rect.right, b.rect.right) - math.max(a.rect.left, b.rect.left);
    final minWidth = math.min(a.rect.width, b.rect.width);

    if (isVerticalScript) {
      // 일본어/중국어 세로쓰기 말풍선: 옆 줄(오른쪽->왼쪽)과 수직 영역이 겹치거나 근접하고, 가로 간격이 글자 폭의 2.5배 이내면 하나의 말풍선!
      final verticallyAligned = overlapHeight > -charSize * 0.8 || vGap < charSize * 1.1;
      final horizontallyClose = hGap < charSize * 2.55;
      if (verticallyAligned && horizontallyClose) return true;

      // 같은 세로줄 안에서 위아래로 약간 끊어진 경우도 하나로 병합
      if (overlapWidth > minWidth * 0.3 && vGap < charSize * 1.6) return true;
      return false;
    } else {
      // 가로쓰기 만화(영어 등): 위->아래 줄 간격이 좁고 좌우 영역이 겹치면 하나의 말풍선
      final horizontallyAligned = overlapWidth > -charSize * 0.8 || hGap < charSize * 1.5;
      final verticallyClose = vGap < charSize * 1.8;
      return horizontallyAligned && verticallyClose;
    }
  }

  static bool _isRubyFuriganaColumn(_TextColUnit candidate, List<_TextColUnit> allUnits, double medianWidth) {
    // 후리가나(루비) 열 판별: 평균 글자 폭이 본문 열의 62% 미만이고 히라가나/가타카나로만 구성된 짧은 보조 열
    final onlyKana = RegExp(r'^[\u3040-\u309F\u30A0-\u30FF\u30FC\s・。、]+$').hasMatch(candidate.text);
    if (!onlyKana) return false;
    if (candidate.avgCharWidth >= medianWidth * 0.65) return false;

    for (final mainCol in allUnits) {
      if (identical(candidate, mainCol)) continue;
      if (mainCol.avgCharWidth >= medianWidth * 0.8) {
        final vOverlap = math.min(candidate.rect.bottom, mainCol.rect.bottom) -
            math.max(candidate.rect.top, mainCol.rect.top);
        final hDist = (candidate.rect.left - mainCol.rect.right).abs();
        final hDist2 = (candidate.rect.right - mainCol.rect.left).abs();
        if (vOverlap > 0 && math.min(hDist, hDist2) < mainCol.avgCharWidth * 0.9) {
          return true;
        }
      }
    }
    return false;
  }

  /// 2. 일본어 만화/스캔 이미지(JPG, PNG, CBZ, PDF) 말풍선 단위 통합 클러스터링 & 원문 덮어쓰기 번역
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
          '말풍선 영역 통합 감지 및 문맥 번역 중 (${i + 1} / ${imageFiles.length})...',
        );
        if (!forceRetranslate) {
          final cached = await StorageService.getImageBubbleCache(bookKey, i);
          if (cached != null) continue;
        }

        final file = imageFiles[i];
        final bytes = await file.readAsBytes();
        final codec = await ui.instantiateImageCodec(bytes);
        final frame = await codec.getNextFrame();
        final imgWidth = frame.image.width.toDouble();
        final imgHeight = frame.image.height.toDouble();

        final inputImage = InputImage.fromFilePath(file.path);
        final recognized = await recognizer.processImage(inputImage);

        // 1단계: 모든 텍스트 라인(세로열/가로줄) 수집 및 노이즈 필터링
        final List<_TextColUnit> rawUnits = [];
        for (final block in recognized.blocks) {
          for (final line in block.lines) {
            final t = line.text.trim();
            if (t.isEmpty) continue;
            // 배경 효과음이나 단순 기호 1글자 노이즈 제거
            if (t.length == 1 && RegExp(r'^[0-9a-zA-Z!@#$%^&*()_+\-=\[\]{};:"\\|,.<>/?~`]$').hasMatch(t)) {
              continue;
            }
            final r = line.boundingBox;
            if (r.width < 6 || r.height < 6) continue;
            final charW = isVerticalScript ? r.width : (r.height > 0 ? r.height : r.width);
            rawUnits.add(_TextColUnit(rect: r, text: t, avgCharWidth: charW));
          }
        }

        if (rawUnits.isEmpty) {
          await StorageService.saveImageBubbleCache(bookKey, i, []);
          continue;
        }

        // 2단계: 일본어 만화의 후리가나(한자 옆 작은 발음 열)가 별도 말풍선으로 쪼개지는 현상 제거
        final sortedWidths = rawUnits.map((u) => u.avgCharWidth).toList()..sort();
        final medianWidth = sortedWidths[sortedWidths.length ~/ 2];
        final filteredUnits = rawUnits
            .where((u) => !_isRubyFuriganaColumn(u, rawUnits, medianWidth))
            .toList();

        // 3단계: 인접한 텍스트 열들을 같은 말풍선(Connected Component)으로 통합 클러스터링!
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

        // 4단계: 각 말풍선 클러스터 내부의 열들을 올바른 만화 읽기 순서대로 정렬하여 한 문장으로 결합
        final List<ui.Rect> mergedRects = [];
        final List<String> mergedSentences = [];
        final List<bool> isSerifFlags = [];
        final List<bool> isBoldFlags = [];

        for (final cluster in bubbleClusters) {
          if (isVerticalScript) {
            // 일본 만화 세로쓰기: 오른쪽 열부터 왼쪽 열 순서로 읽어야 문장이 정상적으로 이어짐!
            cluster.sort((a, b) {
              final xDiff = b.rect.center.dx - a.rect.center.dx;
              if (xDiff.abs() > medianWidth * 0.45) {
                return xDiff > 0 ? 1 : -1;
              }
              return a.rect.top.compareTo(b.rect.top);
            });
          } else {
            // 가로쓰기: 위에서 아래, 왼쪽에서 오른쪽 순서
            cluster.sort((a, b) {
              final yDiff = a.rect.center.dy - b.rect.center.dy;
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

          for (final u in cluster) {
            if (u.rect.left < minL) minL = u.rect.left;
            if (u.rect.top < minT) minT = u.rect.top;
            if (u.rect.right > maxR) maxR = u.rect.right;
            if (u.rect.bottom > maxB) maxB = u.rect.bottom;
          }

          final joiner = isVerticalScript ? '' : ' ';
          String combinedText = cluster.map((u) => u.text).join(joiner).trim();
          // OCR 줄바꿈 하이픈이나 불필요한 공백 정리
          if (isVerticalScript) {
            combinedText = combinedText.replaceAll(RegExp(r'\s+'), '');
          }

          if (combinedText.isEmpty) continue;

          // 원문 글자가 말풍선 밖으로 삐져나오지 않도록 말풍선 내부 영역을 살짝 여유 있게 확장
          final padX = (maxR - minL) * 0.08 + 6.0;
          final padY = (maxB - minT) * 0.06 + 6.0;
          final expandedRect = ui.Rect.fromLTRB(
            (minL - padX).clamp(0.0, imgWidth),
            (minT - padY).clamp(0.0, imgHeight),
            (maxR + padX).clamp(0.0, imgWidth),
            (maxB + padY).clamp(0.0, imgHeight),
          );

          mergedRects.add(expandedRect);
          mergedSentences.add(combinedText);

          // 외침/강조 대사(!, ?, ！！ 등)는 굵은 글씨, 일반 만화 대사는 만화책 명조/앤티크 조판 스타일 적용
          final isShout = combinedText.contains('!') ||
              combinedText.contains('！') ||
              combinedText.contains('?!') ||
              combinedText.contains('？！');
          isSerifFlags.add(!isShout);
          isBoldFlags.add(isShout);
        }

        // 5단계: 한 페이지의 통합된 말풍선 문장들을 번역
        final List<String> translatedSentences = List.from(mergedSentences);
        for (int k = 0; k < mergedSentences.length; k++) {
          try {
            final res = await _translator.translate(
              mergedSentences[k],
              from: sourceLang,
              to: targetLang,
            );
            if (res.text.trim().isNotEmpty) {
              translatedSentences[k] = res.text.trim();
            }
          } catch (_) {}
        }

        final List<BubbleTranslation> bubbles = [];
        for (int k = 0; k < mergedRects.length; k++) {
          final rect = mergedRects[k];
          bubbles.add(
            BubbleTranslation(
              leftRatio: (rect.left / imgWidth).clamp(0.0, 0.98),
              topRatio: (rect.top / imgHeight).clamp(0.0, 0.98),
              widthRatio: (rect.width / imgWidth).clamp(0.05, 0.98),
              heightRatio: (rect.height / imgHeight).clamp(0.04, 0.98),
              originalText: mergedSentences[k],
              translatedText: translatedSentences[k],
              isSerif: isSerifFlags[k],
              isBold: isBoldFlags[k],
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
