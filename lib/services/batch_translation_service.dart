import 'dart:convert';
import 'dart:io';
import 'dart:ui' as ui;
import 'package:archive/archive.dart';
import 'package:google_mlkit_text_recognition/google_mlkit_text_recognition.dart';
import 'package:translator/translator.dart';
import 'storage_service.dart';

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
        // 일본어 세로쓰기(vertical-rl) EPUB을 한국어 가독성에 맞게 가로쓰기로 보정하되 원본 폰트 패밀리는 100% 보존
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

  /// 일본어 루비(후리가나 <rt>...</rt>, <rp>...</rp>) 태그를 먼저 제거하여
  /// 한자와 히라가나가 섞여 번역기가 오역하는 현상을 방지하고, 원글 글꼴을 계승합니다.
  static String _stripJapaneseRubyAndTags(String rawHtml) {
    // 1. <rt>후리가나</rt> 및 <rp>(</rp> 제거
    var cleaned = rawHtml
        .replaceAll(RegExp(r'<rt[^>]*>.*?</rt>', dotAll: true, caseSensitive: false), '')
        .replaceAll(RegExp(r'<rp[^>]*>.*?</rp>', dotAll: true, caseSensitive: false), '');
    // 2. 나머지 인라인 HTML 태그 제거
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

  /// 2. 일본어 만화/스캔 이미지(JPG, PNG, CBZ) 전체 스캔 후 말풍선 오버레이 일괄 사전 번역
  /// - Google ML Kit Japanese Script 기본 탑재
  /// - 일본어 세로쓰기 대사 줄바꿈 무공백 결합 처리 및 말풍선 비율 기반 명조/고딕 스타일 매칭
  static Future<void> preTranslateAllImages({
    required String bookKey,
    required List<File> imageFiles,
    required String targetLang,
    String sourceLang = 'ja',
    TextRecognitionScript script = TextRecognitionScript.japanese,
    required void Function(int current, int total, String status) onProgress,
  }) async {
    final recognizer = TextRecognizer(script: script);
    try {
      for (int i = 0; i < imageFiles.length; i++) {
        onProgress(
          i + 1,
          imageFiles.length,
          '일본어 말풍선 OCR 및 사전 번역 중 (${i + 1} / ${imageFiles.length})...',
        );
        final cached = await StorageService.getImageBubbleCache(bookKey, i);
        if (cached != null) continue;

        final file = imageFiles[i];
        final bytes = await file.readAsBytes();
        final codec = await ui.instantiateImageCodec(bytes);
        final frame = await codec.getNextFrame();
        final imgWidth = frame.image.width.toDouble();
        final imgHeight = frame.image.height.toDouble();

        final inputImage = InputImage.fromFilePath(file.path);
        final recognized = await recognizer.processImage(inputImage);

        final List<BubbleTranslation> bubbles = [];
        final List<ui.Rect> rects = [];
        final List<String> rawTexts = [];
        final List<bool> isSerifFlags = [];

        for (final block in recognized.blocks) {
          final rect = block.boundingBox;
          // 일본어는 줄바꿈 시 공백 없이 이어붙여야 문맥이 깨지지 않음
          final joiner = (script == TextRecognitionScript.japanese ||
                  script == TextRecognitionScript.chinese)
              ? ''
              : ' ';
          final rawText = block.lines.map((l) => l.text.trim()).join(joiner).trim();
          if (rawText.isEmpty) continue;

          rects.add(rect);
          rawTexts.add(rawText);
          // 세로로 긴 말풍선(일본 만화 독백/나레이션 등)이나 문장부호 특성에 따라 명조/고딕 구분
          final isVerticalBubble = rect.height > rect.width * 1.35;
          isSerifFlags.add(isVerticalBubble);
        }

        // 페이지 내 모든 말풍선 대사를 한 번에 묶음 번역하여 속도 극대화
        List<String> translatedTexts = List.from(rawTexts);
        if (rawTexts.isNotEmpty) {
          try {
            final joined = rawTexts.join('\n===SPLIT===\n');
            final res = await _translator.translate(joined, from: sourceLang, to: targetLang);
            final parts = res.text.split(RegExp(r'\s*===SPLIT===\s*'));
            for (int k = 0; k < rawTexts.length; k++) {
              if (k < parts.length && parts[k].trim().isNotEmpty) {
                translatedTexts[k] = parts[k].trim();
              }
            }
          } catch (_) {}
        }

        for (int k = 0; k < rects.length; k++) {
          final rect = rects[k];
          bubbles.add(
            BubbleTranslation(
              leftRatio: (rect.left / imgWidth).clamp(0.0, 0.95),
              topRatio: (rect.top / imgHeight).clamp(0.0, 0.95),
              widthRatio: (rect.width / imgWidth).clamp(0.08, 0.95),
              heightRatio: (rect.height / imgHeight).clamp(0.04, 0.95),
              originalText: rawTexts[k],
              translatedText: translatedTexts[k],
              isSerif: isSerifFlags[k],
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
