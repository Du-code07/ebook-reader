import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

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
