import 'dart:io';
import 'package:flutter/material.dart';
import 'package:file_picker/file_picker.dart';
import 'package:path_provider/path_provider.dart';
import 'screens/pdf_and_image_viewer.dart';
import 'screens/reader_screen.dart';
import 'services/storage_service.dart';
import 'services/txt_to_epub_converter.dart';

void main() {
  WidgetsFlutterBinding.ensureInitialized();
  runApp(const MaterialApp(
    debugShowCheckedModeBanner: false,
    title: '올인원 모바일 리더기',
    home: BookshelfScreen(),
  ));
}

class BookshelfScreen extends StatefulWidget {
  const BookshelfScreen({super.key});

  @override
  State<BookshelfScreen> createState() => _BookshelfScreenState();
}

class _BookshelfScreenState extends State<BookshelfScreen> {
  List<File> _allBooks = [];
  List<String> _groups = ['전체', '소설/문학', '만화/웹툰', 'PDF/문서'];
  String _selectedGroup = '전체';
  Map<String, String> _bookGroupMap = {};
  Map<String, int> _bookReadingTimeMap = {};
  Map<String, double> _bookProgressMap = {};

  static const _supportedExts = ['epub', 'txt', 'pdf', 'jpg', 'jpeg', 'png', 'webp', 'cbz', 'zip'];

  @override
  void initState() {
    super.initState();
    _loadLibrary();
  }

  Future<void> _loadLibrary() async {
    final dir = await getApplicationDocumentsDirectory();
    final entities = dir.listSync();
    final files = <File>[];

    for (final e in entities) {
      if (e is File) {
        final lower = e.path.toLowerCase();
        // 자동 생성된 임시 번역본/변환본은 서재 중복 표시 제외
        if (lower.endsWith('_ko_translated.epub') || lower.endsWith('.converted.epub')) continue;
        final ext = lower.split('.').last;
        if (_supportedExts.contains(ext)) {
          files.add(e);
        }
      }
    }

    final groups = await StorageService.getGroups();
    final grpMap = <String, String>{};
    final timeMap = <String, int>{};
    final progMap = <String, double>{};

    for (final f in files) {
      grpMap[f.path] = await StorageService.getBookGroup(f.path);
      timeMap[f.path] = await StorageService.getReadingSeconds(f.path);
      progMap[f.path] = await StorageService.getProgress(f.path);
    }

    if (mounted) {
      setState(() {
        _allBooks = files;
        _groups = groups;
        _bookGroupMap = grpMap;
        _bookReadingTimeMap = timeMap;
        _bookProgressMap = progMap;
      });
    }
  }

  Future<void> _pickAndImportFiles() async {
    final result = await FilePicker.platform.pickFiles(
      type: FileType.custom,
      allowedExtensions: _supportedExts,
      allowMultiple: true,
    );

    if (result != null && result.files.isNotEmpty) {
      final appDir = await getApplicationDocumentsDirectory();
      final importedFiles = <File>[];

      for (final pf in result.files) {
        if (pf.path == null) continue;
        final saved = await File(pf.path!).copy('${appDir.path}/${pf.name}');
        if (_selectedGroup != '전체') {
          await StorageService.setBookGroup(saved.path, _selectedGroup);
        }
        importedFiles.add(saved);
      }

      await _loadLibrary();
      if (importedFiles.length == 1 && mounted) {
        _openFile(importedFiles.first);
      }
    }
  }

  Future<void> _openFile(File file) async {
    final name = file.path.split(Platform.pathSeparator).last;
    final ext = name.split('.').last.toLowerCase();

    if (ext == 'epub') {
      await Navigator.push(
        context,
        MaterialPageRoute(
          builder: (_) => ReaderScreen(filePath: file.path, bookTitle: name),
        ),
      );
    } else if (ext == 'txt') {
      final epubFile = await TxtToEpubConverter.convertTxtToEpub(file);
      if (!mounted) return;
      await Navigator.push(
        context,
        MaterialPageRoute(
          builder: (_) => ReaderScreen(filePath: epubFile.path, bookTitle: name),
        ),
      );
    } else if (ext == 'pdf') {
      await Navigator.push(
        context,
        MaterialPageRoute(
          builder: (_) => UniversalMediaReaderScreen(
            files: [file],
            title: name,
            isPdf: true,
          ),
        ),
      );
    } else {
      // JPG, PNG, WEBP, CBZ, ZIP 만화/이미지 열람
      await Navigator.push(
        context,
        MaterialPageRoute(
          builder: (_) => UniversalMediaReaderScreen(
            files: [file],
            title: name,
            isPdf: false,
          ),
        ),
      );
    }

    _loadLibrary();
  }

  Future<void> _createNewGroupDialog() async {
    final controller = TextEditingController();
    await showDialog(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('새 파일 그룹(폴더) 만들기'),
        content: TextField(
          controller: controller,
          decoration: const InputDecoration(hintText: '예: 영어 원서, 판타지, 전공서적'),
        ),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx), child: const Text('취소')),
          ElevatedButton(
            onPressed: () async {
              final text = controller.text.trim();
              if (text.isNotEmpty) {
                await StorageService.addGroup(text);
                if (ctx.mounted) Navigator.pop(ctx);
                _loadLibrary();
              }
            },
            child: const Text('추가'),
          ),
        ],
      ),
    );
  }

  Future<void> _assignGroupDialog(File file) async {
    await showModalBottomSheet(
      context: context,
      builder: (ctx) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const ListTile(
              title: Text('파일 그룹(카테고리) 이동', style: TextStyle(fontWeight: FontWeight.bold)),
            ),
            const Divider(height: 1),
            ..._groups.where((g) => g != '전체').map((g) => ListTile(
                  leading: const Icon(Icons.folder_outlined),
                  title: Text(g),
                  onTap: () async {
                    await StorageService.setBookGroup(file.path, g);
                    if (ctx.mounted) Navigator.pop(ctx);
                    _loadLibrary();
                  },
                )),
          ],
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final filteredBooks = _selectedGroup == '전체'
        ? _allBooks
        : _allBooks.where((f) => _bookGroupMap[f.path] == _selectedGroup).toList();

    return Scaffold(
      appBar: AppBar(
        title: const Text('내 서재 (EPUB·PDF·만화·번역)'),
        actions: [
          IconButton(
            icon: const Icon(Icons.create_new_folder_outlined),
            tooltip: '새 그룹 만들기',
            onPressed: _createNewGroupDialog,
          ),
        ],
      ),
      body: Column(
        children: [
          // 상단 그룹(카테고리) 필터 칩 바
          SizedBox(
            height: 52,
            child: ListView.separated(
              padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
              scrollDirection: Axis.horizontal,
              itemCount: _groups.length,
              separatorBuilder: (_, __) => const SizedBox(width: 8),
              itemBuilder: (context, index) {
                final grp = _groups[index];
                final selected = grp == _selectedGroup;
                return ChoiceChip(
                  label: Text(grp),
                  selected: selected,
                  onSelected: (_) => setState(() => _selectedGroup = grp),
                );
              },
            ),
          ),
          const Divider(height: 1),
          Expanded(
            child: filteredBooks.isEmpty
                ? Center(
                    child: ElevatedButton.icon(
                      icon: const Icon(Icons.folder_open),
                      label: const Text('파일 열기 (EPUB, PDF, JPG, PNG, TXT, CBZ)'),
                      onPressed: _pickAndImportFiles,
                    ),
                  )
                : ListView.separated(
                    itemCount: filteredBooks.length,
                    separatorBuilder: (_, __) => const Divider(height: 1),
                    itemBuilder: (context, index) {
                      final file = filteredBooks[index];
                      final fileName = file.path.split(Platform.pathSeparator).last;
                      final grp = _bookGroupMap[file.path] ?? '미분류';
                      final secs = _bookReadingTimeMap[file.path] ?? 0;
                      final prog = (_bookProgressMap[file.path] ?? 0.0) * 100;

                      return ListTile(
                        leading: Icon(
                          fileName.toLowerCase().endsWith('.pdf')
                              ? Icons.picture_as_pdf
                              : (fileName.toLowerCase().endsWith('.epub') ||
                                      fileName.toLowerCase().endsWith('.txt'))
                                  ? Icons.menu_book
                                  : Icons.image,
                          color: Colors.indigo,
                        ),
                        title: Text(fileName, maxLines: 1, overflow: TextOverflow.ellipsis),
                        subtitle: Text(
                          '[$grp]  •  진행률 ${prog.toStringAsFixed(1)}%  •  읽은 시간 ${StorageService.formatReadingTime(secs)}',
                          style: const TextStyle(fontSize: 12),
                        ),
                        trailing: IconButton(
                          icon: const Icon(Icons.drive_file_move_outline),
                          tooltip: '그룹 변경',
                          onPressed: () => _assignGroupDialog(file),
                        ),
                        onTap: () => _openFile(file),
                      );
                    },
                  ),
          ),
        ],
      ),
      floatingActionButton: FloatingActionButton.extended(
        onPressed: _pickAndImportFiles,
        icon: const Icon(Icons.add),
        label: const Text('파일 추가'),
      ),
    );
  }
}
