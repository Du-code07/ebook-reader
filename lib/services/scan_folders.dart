import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../widgets/pop_dialog.dart';

typedef ScanTr = String Function(String ko, String en, String zh, String ja);

/// 탐색할 폴더 하나 (시스템 폴더 선택 창에서 사용자가 고른 폴더)
class ScanFolder {
  const ScanFolder(this.uri, this.name);
  final String uri;
  final String name;

  Map<String, String> toJson() => {'uri': uri, 'name': name};
}

/// 찾은 파일 하나 (폴더 안의 문서 주소 + 이름)
class FoundFile {
  const FoundFile(this.uri, this.name, this.size);
  final String uri;
  final String name;
  final int size;
}

/// 파일 탐색·글꼴 찾기가 함께 쓰는 '탐색할 폴더' 목록.
/// 사용자가 고른 폴더(와 그 안의 폴더)만 읽음 — 저장소 전체 접근 권한 없이 동작
class ScanFolders {
  static const MethodChannel _ch = MethodChannel('ebook_reader/pdf_renderer');
  static const String _key = 'scan_folders_v145';

  /// 목록이 바뀌면 알림 (설정 화면의 폴더 수 표시 등)
  static final ValueNotifier<int> changed = ValueNotifier<int>(0);

  static Future<List<ScanFolder>> load() async {
    final prefs = await SharedPreferences.getInstance();
    final raw = prefs.getString(_key);
    if (raw == null) return [];
    try {
      final List list = jsonDecode(raw);
      return [
        for (final e in list)
          if (e is Map && e['uri'] is String) ScanFolder(e['uri'] as String, (e['name'] as String?) ?? ''),
      ];
    } catch (_) {
      return [];
    }
  }

  static Future<void> _save(List<ScanFolder> folders) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(_key, jsonEncode([for (final f in folders) f.toJson()]));
    changed.value++;
  }

  /// 시스템 폴더 선택 창을 띄워 폴더를 하나 더 등록 (고르지 않으면 null)
  static Future<ScanFolder?> add() async {
    final r = await _ch.invokeMapMethod<String, dynamic>('pickScanFolder').catchError((_) => null);
    final uri = r?['uri'] as String?;
    if (uri == null) return null;
    final folder = ScanFolder(uri, (r?['name'] as String?) ?? '');
    final list = await load();
    if (!list.any((f) => f.uri == uri)) {
      list.add(folder);
      await _save(list);
    }
    return folder;
  }

  static Future<void> remove(ScanFolder folder) async {
    final list = await load();
    list.removeWhere((f) => f.uri == folder.uri);
    await _save(list);
    await _ch.invokeMethod('releaseScanFolder', {'uri': folder.uri}).catchError((_) => null);
  }

  /// 등록한 폴더가 없으면 먼저 안내하고 하나 고르게 함. 고를 폴더가 없으면 빈 목록
  static Future<List<ScanFolder>> ensure(BuildContext context, ScanTr tr) async {
    var list = await _usable();
    if (list.isNotEmpty || !context.mounted) return list;
    final go = await showPopDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text(tr('탐색할 폴더 고르기', 'Choose folders to search', '选择要查找的文件夹', '探すフォルダを選ぶ')),
        content: Text(tr(
          '파일을 찾을 폴더를 골라 주세요\n고른 폴더와 그 안의 폴더에서 찾고, 다음부터는 바로 찾아요\n폴더는 앱 설정 > 탐색할 폴더에서 더 넣거나 뺄 수 있어요',
          'Choose a folder to search for files\n이리ERI searches it and the folders inside it, and remembers it for next time\nAdd or remove folders in App Settings > Folders to Search',
          '请选择要查找文件的文件夹\n会在该文件夹及其子文件夹中查找，下次直接查找\n可在应用设置 > 要查找的文件夹中添加或移除',
          'ファイルを探すフォルダを選んでください\n選んだフォルダとその中のフォルダから探し、次からはすぐに探します\nフォルダはアプリ設定 > 探すフォルダで追加・削除できます',
        )),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx, false), child: Text(tr('취소', 'Cancel', '取消', 'キャンセル'))),
          FilledButton(onPressed: () => Navigator.pop(ctx, true), child: Text(tr('폴더 고르기', 'Choose Folder', '选择文件夹', 'フォルダを選ぶ'))),
        ],
      ),
    );
    if (go != true) return [];
    await add();
    return _usable();
  }

  /// 아직 읽을 수 있는 폴더만 (폴더를 지웠거나 허락이 풀린 것은 목록에서 뺌)
  static Future<List<ScanFolder>> _usable() async {
    final list = await load();
    final ok = <ScanFolder>[];
    for (final f in list) {
      final usable = await _ch.invokeMethod<bool>('scanFolderUsable', {'uri': f.uri}).catchError((_) => false) ?? false;
      if (usable) ok.add(f);
    }
    if (ok.length != list.length) await _save(ok);
    return ok;
  }

  /// 폴더들에서 [exts] 형식의 파일을 찾음 (하위 폴더 포함, 숨은 파일 제외)
  static Future<List<FoundFile>> scan(List<ScanFolder> folders, List<String> exts, {int minSize = 1, int? maxSize}) async {
    final r = await _ch.invokeListMethod<dynamic>('scanTreeFiles', {
      'trees': [for (final f in folders) f.uri],
      'exts': exts,
      'minSize': minSize,
      if (maxSize != null) 'maxSize': maxSize,
    });
    return [
      for (final e in r ?? const [])
        if (e is Map && e['uri'] is String)
          FoundFile(e['uri'] as String, (e['name'] as String?) ?? '', ((e['size'] as num?) ?? 0).toInt()),
    ];
  }

  /// 찾은 파일을 앱 안 [dest] 경로로 복사
  static Future<bool> copyTo(FoundFile file, String dest) async =>
      await _ch.invokeMethod<bool>('copyUriTo', {'uri': file.uri, 'dest': dest}).catchError((_) => false) ?? false;
}
