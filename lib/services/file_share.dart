import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import 'package:path_provider/path_provider.dart';

import 'pdf_outline_service.dart';
import 'storage_service.dart';

/// 파일을 형식 그대로 다른 앱으로 공유 (안드로이드 공유 창)
Future<void> shareFile(BuildContext context, String path, {String? title}) async {
  const channel = MethodChannel('ebook_reader/pdf_renderer');
  String tr(String ko, String en, String zh, String ja) => AppI18n.t(StorageService.appLangNotifier.value, ko: ko, en: en, zh: zh, ja: ja);
  final messenger = ScaffoldMessenger.maybeOf(context);
  try {
    if (!File(path).existsSync()) throw Exception('missing');
    final ok = await channel.invokeMethod<bool>('shareFile', {
      'path': path,
      'mime': shareMimeOf(path),
      'title': tr('공유', 'Share', '分享', '共有'),
    });
    if (ok != true) throw Exception('share failed');
  } catch (_) {
    messenger?.showSnackBar(SnackBar(content: Text(tr('파일을 공유하지 못했어요', 'Could not share the file', '无法分享文件', 'ファイルを共有できませんでした'))));
  }
}

/// 공유: PDF에 메모가 있으면 쪽마다 메모(펜 자국)를 PDF 주석으로 얹은 사본을 공유 (그 밖의 파일·메모가 없으면 파일 그대로)
/// 저장된 메모를 읽어서 넣음 (서재의 점 3개 메뉴에서 공유할 때)
Future<void> shareFileWithMemos(BuildContext context, String path, {String? title}) async {
  String tr(String ko, String en, String zh, String ja) => AppI18n.t(StorageService.appLangNotifier.value, ko: ko, en: en, zh: zh, ja: ja);
  if (!path.toLowerCase().endsWith('.pdf')) return shareFile(context, path, title: title);
  final Map<int, List<Map<String, Object?>>> memos = {};
  int pages = 0;
  try {
    pages = await const MethodChannel('ebook_reader/pdf_renderer').invokeMethod<int>('pdfPageCount', {'filePath': path}) ?? 0;
  } catch (_) {}
  for (int i = 0; i < pages; i++) {
    final strokes = await StorageService.getPageMemoStrokes(path, i);
    if (strokes.isNotEmpty) memos[i] = [for (final s in strokes) s.toJson()];
  }
  if (!context.mounted) return;
  if (memos.isEmpty) return shareFile(context, path, title: title);
  final messenger = ScaffoldMessenger.maybeOf(context);
  messenger
    ?..clearSnackBars()
    ..showSnackBar(SnackBar(
      content: Text(tr('메모를 넣은 PDF를 만들고 있어요', 'Preparing the PDF with memos', '正在生成含笔记的 PDF', 'メモ入りのPDFを作成しています')),
      duration: const Duration(minutes: 1),
    ));
  String? made;
  try {
    // 공유용 파일은 한 개만 남김 (예전에 만든 것은 지움)
    final dir = Directory('${(await getTemporaryDirectory()).path}/share');
    if (await dir.exists()) await dir.delete(recursive: true);
    await dir.create(recursive: true);
    String name = (title ?? path.split(Platform.pathSeparator).last).replaceAll(RegExp(r'[\\/:*?"<>|]'), '_').trim();
    if (name.isEmpty) name = 'memo';
    if (!name.toLowerCase().endsWith('.pdf')) name = '$name.pdf';
    final String out = '${dir.path}/$name';
    if (await PdfOutlineService.writeWithMemos(path, out, memos)) made = out;
  } catch (_) {}
  messenger?.hideCurrentSnackBar();
  if (!context.mounted) return;
  if (made == null) {
    messenger?.showSnackBar(SnackBar(
      content: Text(tr('메모를 넣지 못해 원래 파일을 공유해요', 'Could not add memos, sharing the original file', '无法加入笔记，将分享原文件', 'メモを入れられなかったため元のファイルを共有します')),
    ));
    made = path;
  }
  await shareFile(context, made, title: title);
}

/// 확장자로 알아낸 파일 형식 (모르면 아무 파일)
String shareMimeOf(String path) {
  final ext = path.split('.').last.toLowerCase();
  const map = {
    'pdf': 'application/pdf',
    'epub': 'application/epub+zip',
    'txt': 'text/plain',
    'doc': 'application/msword',
    'docx': 'application/vnd.openxmlformats-officedocument.wordprocessingml.document',
    'hwp': 'application/x-hwp',
    'hwpx': 'application/hwp+zip',
    'ppt': 'application/vnd.ms-powerpoint',
    'pptx': 'application/vnd.openxmlformats-officedocument.presentationml.presentation',
    'xls': 'application/vnd.ms-excel',
    'xlsx': 'application/vnd.openxmlformats-officedocument.spreadsheetml.sheet',
    'xlsm': 'application/vnd.ms-excel.sheet.macroEnabled.12',
    'cbz': 'application/vnd.comicbook+zip',
    'zip': 'application/zip',
  };
  return map[ext] ?? 'application/octet-stream';
}
