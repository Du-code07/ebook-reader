import 'package:flutter/material.dart';

import '../services/scan_folders.dart';
import '../services/storage_service.dart';

/// 앱 설정 > 탐색할 폴더: 파일 탐색·글꼴 찾기가 찾아볼 폴더를 넣고 뺌
class ScanFoldersScreen extends StatefulWidget {
  const ScanFoldersScreen({super.key, required this.appLang});
  final String appLang;

  @override
  State<ScanFoldersScreen> createState() => _ScanFoldersScreenState();
}

class _ScanFoldersScreenState extends State<ScanFoldersScreen> {
  List<ScanFolder>? _folders;

  String _tr(String ko, String en, String zh, String ja) => AppI18n.t(widget.appLang, ko: ko, en: en, zh: zh, ja: ja);

  @override
  void initState() {
    super.initState();
    _reload();
  }

  Future<void> _reload() async {
    final list = await ScanFolders.load();
    if (mounted) setState(() => _folders = list);
  }

  Future<void> _add() async {
    await ScanFolders.add();
    await _reload();
  }

  Future<void> _remove(ScanFolder f) async {
    await ScanFolders.remove(f);
    await _reload();
  }

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final list = _folders;
    return Scaffold(
      appBar: AppBar(title: Text(_tr('탐색할 폴더', 'Folders to Search', '要查找的文件夹', '探すフォルダ'), style: const TextStyle(fontWeight: FontWeight.w800))),
      body: SafeArea(
        child: list == null
            ? const SizedBox.shrink()
            : ListView(
                padding: const EdgeInsets.fromLTRB(16, 4, 16, 24),
                children: [
                  Padding(
                    padding: const EdgeInsets.fromLTRB(8, 0, 8, 14),
                    child: Text(
                      _tr('파일 탐색과 글꼴 찾기는 여기 넣은 폴더와 그 안의 폴더에서만 찾아요\n안드로이드 정책상 내장 메모리 전체와 Download 폴더 자체는 고를 수 없어요 (Download 안의 폴더는 고를 수 있어요)',
                          'Find Files and Find Fonts search only these folders and the folders inside them\nAndroid does not allow choosing the whole internal storage or the Download folder itself (folders inside Download can be chosen)',
                          '查找文件和查找字体只在这里添加的文件夹及其子文件夹中查找\n根据安卓政策，无法选择整个内部存储或 Download 文件夹本身（可以选择 Download 内的文件夹）',
                          'ファイル検索とフォント検索は、ここに追加したフォルダとその中のフォルダだけを探します\nAndroidの仕様で内部ストレージ全体とDownloadフォルダ自体は選べません（Download内のフォルダは選べます）'),
                      style: TextStyle(fontSize: 14, height: 1.45, color: cs.onSurfaceVariant),
                    ),
                  ),
                  if (list.isEmpty)
                    Padding(
                      padding: const EdgeInsets.symmetric(vertical: 28),
                      child: Center(
                        child: Text(_tr('아직 넣은 폴더가 없어요', 'No folders yet', '还没有添加文件夹', 'まだフォルダがありません'),
                            style: TextStyle(fontSize: 15, color: cs.onSurfaceVariant)),
                      ),
                    ),
                  for (final f in list)
                    Padding(
                      padding: const EdgeInsets.symmetric(vertical: 4),
                      child: Material(
                        color: cs.surfaceContainerHigh,
                        borderRadius: BorderRadius.circular(14),
                        clipBehavior: Clip.antiAlias,
                        child: ListTile(
                          leading: Icon(Icons.folder_outlined, color: cs.onSurface),
                          title: Text(f.name.isEmpty ? f.uri : f.name, maxLines: 2, overflow: TextOverflow.ellipsis,
                              style: const TextStyle(fontWeight: FontWeight.w700)),
                          trailing: IconButton(
                            icon: const Icon(Icons.close),
                            tooltip: _tr('빼기', 'Remove', '移除', '外す'),
                            onPressed: () => _remove(f),
                          ),
                        ),
                      ),
                    ),
                  const SizedBox(height: 14),
                  Center(
                    child: FilledButton.icon(
                      onPressed: _add,
                      icon: const Icon(Icons.create_new_folder_outlined),
                      label: Text(_tr('폴더 넣기', 'Add Folder', '添加文件夹', 'フォルダを追加')),
                    ),
                  ),
                ],
              ),
      ),
    );
  }
}
