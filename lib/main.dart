import 'dart:io';
import 'dart:math' as math;
import 'package:archive/archive.dart';
import 'package:flutter/material.dart';
import 'package:file_picker/file_picker.dart';
import 'package:path_provider/path_provider.dart';
import 'screens/pdf_and_image_viewer.dart';
import 'screens/reader_screen.dart';
import 'services/storage_service.dart';
import 'services/txt_to_epub_converter.dart';

void main() async {
  WidgetsFlutterBinding.ensureInitialized();
  final initialDark = await StorageService.getDarkMode();
  runApp(MyEbookApp(initialDark: initialDark));
}

class MyEbookApp extends StatefulWidget {
  final bool initialDark;
  const MyEbookApp({super.key, required this.initialDark});

  @override
  State<MyEbookApp> createState() => _MyEbookAppState();
}

class _MyEbookAppState extends State<MyEbookApp> {
  late bool _isDarkMode;

  @override
  void initState() {
    super.initState();
    _isDarkMode = widget.initialDark;
  }

  void _toggleDarkMode() async {
    final nextVal = !_isDarkMode;
    setState(() => _isDarkMode = nextVal);
    await StorageService.setDarkMode(nextVal);
  }

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      debugShowCheckedModeBanner: false,
      title: 'FReader',
      themeMode: _isDarkMode ? ThemeMode.dark : ThemeMode.light,
      theme: ThemeData(
        useMaterial3: true,
        brightness: Brightness.light,
        colorSchemeSeed: Colors.indigo,
      ),
      darkTheme: ThemeData(
        useMaterial3: true,
        brightness: Brightness.dark,
        colorSchemeSeed: Colors.indigo,
      ),
      home: BookshelfScreen(
        isDarkMode: _isDarkMode,
        onToggleDarkMode: _toggleDarkMode,
      ),
    );
  }
}

class BookshelfScreen extends StatefulWidget {
  final bool isDarkMode;
  final VoidCallback onToggleDarkMode;

  const BookshelfScreen({
    super.key,
    required this.isDarkMode,
    required this.onToggleDarkMode,
  });

  @override
  State<BookshelfScreen> createState() => _BookshelfScreenState();
}

class _BookshelfScreenState extends State<BookshelfScreen> {
  List<File> _allBooks = [];
  List<File> _trashedBooks = [];
  List<String> _groups = ['전체', '소설/문학', '만화/웹툰', 'PDF/문서'];
  String _selectedGroup = '전체';
  Map<String, String> _bookGroupMap = {};
  Map<String, double> _bookProgressMap = {};

  bool _isSelectionMode = false;
  final Set<String> _selectedFilePaths = {};

  static const _supportedExts = ['epub', 'txt', 'pdf', 'jpg', 'jpeg', 'png', 'webp', 'cbz', 'zip'];
  static const _imageExts = ['jpg', 'jpeg', 'png', 'webp'];

  @override
  void initState() {
    super.initState();
    _loadLibrary();
  }

  int _naturalCompare(String a, String b) {
    final reg = RegExp(r'(\d+)|(\D+)');
    final matchesA = reg.allMatches(a.toLowerCase()).toList();
    final matchesB = reg.allMatches(b.toLowerCase()).toList();
    final len = matchesA.length < matchesB.length ? matchesA.length : matchesB.length;
    for (int i = 0; i < len; i++) {
      final partA = matchesA[i].group(0)!;
      final partB = matchesB[i].group(0)!;
      final numA = int.tryParse(partA);
      final numB = int.tryParse(partB);
      if (numA != null && numB != null) {
        final cmp = numA.compareTo(numB);
        if (cmp != 0) return cmp;
      } else {
        final cmp = partA.compareTo(partB);
        if (cmp != 0) return cmp;
      }
    }
    return matchesA.length.compareTo(matchesB.length);
  }

  Future<Directory> _getTrashDirectory() async {
    final appDir = await getApplicationDocumentsDirectory();
    final trashDir = Directory('${appDir.path}/.trash_bin');
    if (!await trashDir.exists()) {
      await trashDir.create(recursive: true);
    }
    return trashDir;
  }

  Future<void> _loadLibrary() async {
    final dir = await getApplicationDocumentsDirectory();
    final trashDir = await _getTrashDirectory();

    final entities = dir.listSync();
    final files = <File>[];

    for (final e in entities) {
      if (e is File) {
        final lower = e.path.toLowerCase();
        if (lower.endsWith('_translated.epub') || lower.endsWith('.converted.epub')) continue;
        final ext = lower.split('.').last;
        if (_supportedExts.contains(ext)) {
          files.add(e);
        }
      }
    }

    final trashEntities = trashDir.listSync();
    final trashed = <File>[];
    for (final e in trashEntities) {
      if (e is File) {
        trashed.add(e);
      }
    }

    files.sort((a, b) => _naturalCompare(
          a.path.split(Platform.pathSeparator).last,
          b.path.split(Platform.pathSeparator).last,
        ));
    trashed.sort((a, b) => _naturalCompare(
          a.path.split(Platform.pathSeparator).last,
          b.path.split(Platform.pathSeparator).last,
        ));

    final groups = await StorageService.getGroups();
    final grpMap = <String, String>{};
    final progMap = <String, double>{};

    for (final f in files) {
      grpMap[f.path] = await StorageService.getBookGroup(f.path);
      progMap[f.path] = await StorageService.getProgress(f.path);
    }

    if (mounted) {
      setState(() {
        _allBooks = files;
        _trashedBooks = trashed;
        _groups = groups;
        if (!_groups.contains(_selectedGroup)) {
          _selectedGroup = '전체';
        }
        _bookGroupMap = grpMap;
        _bookProgressMap = progMap;
        _selectedFilePaths.removeWhere((p) => !_allBooks.any((f) => f.path == p));
        if (_selectedFilePaths.isEmpty) {
          _isSelectionMode = false;
        }
      });
    }
  }

  Future<void> _pickAndImportFiles() async {
    final result = await FilePicker.platform.pickFiles(
      type: FileType.any,
      allowMultiple: true,
    );

    if (result == null || result.files.isEmpty) return;

    final validPicked = result.files.where((pf) {
      if (pf.path == null) return false;
      final ext = pf.name.split('.').last.toLowerCase();
      return _supportedExts.contains(ext);
    }).toList();

    if (validPicked.isEmpty) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('지원되는 파일 형식(EPUB, PDF, JPG, PNG, TXT, CBZ, ZIP)을 선택해 주세요.')),
        );
      }
      return;
    }

    final imagePicked = validPicked.where((pf) {
      final ext = pf.name.split('.').last.toLowerCase();
      return _imageExts.contains(ext);
    }).toList();

    if (imagePicked.length >= 2 && imagePicked.length == validPicked.length && mounted) {
      final action = await showDialog<String>(
        context: context,
        builder: (ctx) => AlertDialog(
          title: Text('이미지 ${imagePicked.length}장 추가 방식 선택'),
          content: const Text(
            '선택한 이미지들을 하나로 묶어 통합 파일(.cbz)로 추가할까요?',
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(ctx, 'separate'),
              child: const Text('개별 파일로 추가'),
            ),
            ElevatedButton.icon(
              icon: const Icon(Icons.auto_stories, size: 18),
              onPressed: () => Navigator.pop(ctx, 'merge'),
              label: const Text('JPG 이미지 합치기'),
            ),
          ],
        ),
      );

      if (action == 'merge') {
        final paths = imagePicked.map((e) => File(e.path!)).toList();
        await _createMangaBookFromImages(paths, deleteSourceAfter: false);
        return;
      }
    }

    final appDir = await getApplicationDocumentsDirectory();
    final importedFiles = <File>[];

    for (final pf in validPicked) {
      if (pf.path == null) continue;
      final saved = await File(pf.path!).copy('${appDir.path}/${pf.name}');
      if (_selectedGroup != '전체') {
        await StorageService.setBookGroup(saved.path, _selectedGroup);
      }
      importedFiles.add(saved);
    }

    await _loadLibrary();
    if (mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('${importedFiles.length}개의 파일이 서재에 추가되었습니다.')),
      );
    }
  }

  Future<void> _createMangaBookFromImages(List<File> sourceImages, {bool deleteSourceAfter = false}) async {
    final now = DateTime.now();
    final dateStr = '${now.year}${now.month.toString().padLeft(2, '0')}${now.day.toString().padLeft(2, '0')}';
    final rand4 = (1000 + math.Random().nextInt(9000)).toString();
    final defaultFileName = '파일_${dateStr}_$rand4';

    final titleController = TextEditingController(text: defaultFileName);
    bool deleteOriginals = deleteSourceAfter;

    final confirmed = await showDialog<bool>(
      context: context,
      builder: (ctx) => StatefulBuilder(
        builder: (ctx, setModalState) => AlertDialog(
          title: const Text('JPG 통합 파일 만들기'),
          content: SingleChildScrollView(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                const Text('이미지 번호 순서대로 묶어 파일을 만듭니다.'),
                const SizedBox(height: 12),
                TextField(
                  controller: titleController,
                  decoration: const InputDecoration(
                    labelText: '파일 제목',
                    border: OutlineInputBorder(),
                  ),
                ),
                if (deleteSourceAfter) ...[
                  const SizedBox(height: 8),
                  CheckboxListTile(
                    contentPadding: EdgeInsets.zero,
                    value: deleteOriginals,
                    title: const Text('통합 후 기존 낱장 이미지 휴지통으로 이동', style: TextStyle(fontSize: 13)),
                    onChanged: (v) => setModalState(() => deleteOriginals = v ?? false),
                  ),
                ],
              ],
            ),
          ),
          actions: [
            TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text('취소')),
            ElevatedButton(
              onPressed: () => Navigator.pop(ctx, true),
              child: const Text('만들기'),
            ),
          ],
        ),
      ),
    );

    if (confirmed != true || !mounted) return;

    final bookTitle = titleController.text.trim().isEmpty ? defaultFileName : titleController.text.trim();
    sourceImages.sort((a, b) => _naturalCompare(
          a.path.split(Platform.pathSeparator).last,
          b.path.split(Platform.pathSeparator).last,
        ));

    int currentStep = 0;
    final int totalSteps = sourceImages.length + 1;
    String progressStatus = '이미지 정렬 및 준비 중...';
    StateSetter? progressSetState;

    showDialog(
      context: context,
      barrierDismissible: false,
      builder: (ctx) => StatefulBuilder(
        builder: (ctx, setDialogState) {
          progressSetState = setDialogState;
          final double ratio = totalSteps > 0 ? (currentStep / totalSteps).clamp(0.0, 1.0).toDouble() : 0.0;
          return AlertDialog(
            title: const Text('JPG 통합 파일 생성 중'),
            content: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                LinearProgressIndicator(value: ratio),
                const SizedBox(height: 12),
                Text(
                  '${(ratio * 100).toStringAsFixed(0)}% 완료 ($currentStep / ${sourceImages.length}장)',
                  style: const TextStyle(fontWeight: FontWeight.bold, fontSize: 13),
                ),
                const SizedBox(height: 6),
                Text(progressStatus, style: const TextStyle(fontSize: 12)),
              ],
            ),
          );
        },
      ),
    );

    await Future.delayed(const Duration(milliseconds: 50));

    final archive = Archive();
    for (int i = 0; i < sourceImages.length; i++) {
      final img = sourceImages[i];
      final fileName = img.path.split(Platform.pathSeparator).last;
      final ext = img.path.split('.').last.toLowerCase();

      progressSetState?.call(() {
        currentStep = i + 1;
        progressStatus = '페이지 병합 중 (${i + 1}/${sourceImages.length}): $fileName';
      });
      await Future.delayed(const Duration(milliseconds: 15));

      final bytes = await img.readAsBytes();
      final entryName = 'page_${i.toString().padLeft(4, '0')}.$ext';
      archive.addFile(ArchiveFile(entryName, bytes.length, bytes));
    }

    progressSetState?.call(() {
      currentStep = totalSteps;
      progressStatus = 'CBZ 압축 및 파일 저장 중';
    });
    await Future.delayed(const Duration(milliseconds: 50));

    final appDir = await getApplicationDocumentsDirectory();
    final safeTitle = bookTitle.replaceAll(RegExp(r'[\\/:*?"<>|]'), '_');
    final outFile = File('${appDir.path}/$safeTitle.cbz');
    final zipBytes = ZipEncoder().encode(archive);
    await outFile.writeAsBytes(zipBytes!);

    final targetGroup = _selectedGroup == '전체' ? '만화/웹툰' : _selectedGroup;
    await StorageService.setBookGroup(outFile.path, targetGroup);

    if (deleteOriginals) {
      for (final img in sourceImages) {
        if (await img.exists()) {
          await _moveFileToTrash(img, reloadAfter: false);
        }
      }
    }

    if (mounted) {
      Navigator.pop(context);
    }

    await _loadLibrary();
    if (mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('"$safeTitle.cbz" 파일이 생성되었습니다.')),
      );
      _openFile(outFile);
    }
  }

  Future<void> _showMergeExistingImagesDialog() async {
    final existingImages = _allBooks.where((f) {
      final ext = f.path.split('.').last.toLowerCase();
      return _imageExts.contains(ext);
    }).toList();

    if (existingImages.isEmpty) {
      final result = await FilePicker.platform.pickFiles(
        type: FileType.image,
        allowMultiple: true,
      );
      if (result != null && result.files.length >= 2) {
        final files = result.files.where((f) => f.path != null).map((f) => File(f.path!)).toList();
        await _createMangaBookFromImages(files, deleteSourceAfter: false);
      } else if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('합칠 JPG/PNG 이미지를 2장 이상 선택해 주세요.')),
        );
      }
      return;
    }

    final selectedPaths = existingImages.map((e) => e.path).toSet();

    final proceed = await showDialog<bool>(
      context: context,
      builder: (ctx) => StatefulBuilder(
        builder: (ctx, setModalState) => AlertDialog(
          title: const Text('JPG 이미지 합치기'),
          content: SizedBox(
            width: 420,
            height: 360,
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  mainAxisAlignment: MainAxisAlignment.spaceBetween,
                  children: [
                    Text('선택됨: ${selectedPaths.length}장', style: const TextStyle(fontWeight: FontWeight.bold)),
                    TextButton.icon(
                      icon: const Icon(Icons.folder_open, size: 16),
                      label: const Text('기기에서 바로 선택'),
                      onPressed: () async {
                        Navigator.pop(ctx, false);
                        final result = await FilePicker.platform.pickFiles(
                          type: FileType.image,
                          allowMultiple: true,
                        );
                        if (result != null && result.files.length >= 2) {
                          final files = result.files.where((f) => f.path != null).map((f) => File(f.path!)).toList();
                          await _createMangaBookFromImages(files, deleteSourceAfter: false);
                        }
                      },
                    ),
                  ],
                ),
                const Divider(height: 1),
                Expanded(
                  child: ListView.builder(
                    itemCount: existingImages.length,
                    itemBuilder: (_, idx) {
                      final f = existingImages[idx];
                      final name = f.path.split(Platform.pathSeparator).last;
                      final checked = selectedPaths.contains(f.path);
                      return CheckboxListTile(
                        dense: true,
                        value: checked,
                        title: Text(name, maxLines: 1, overflow: TextOverflow.ellipsis),
                        onChanged: (v) {
                          setModalState(() {
                            if (v == true) {
                              selectedPaths.add(f.path);
                            } else {
                              selectedPaths.remove(f.path);
                            }
                          });
                        },
                      );
                    },
                  ),
                ),
              ],
            ),
          ),
          actions: [
            TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text('취소')),
            ElevatedButton(
              onPressed: selectedPaths.length >= 2 ? () => Navigator.pop(ctx, true) : null,
              child: const Text('선택한 이미지 합치기'),
            ),
          ],
        ),
      ),
    );

    if (proceed == true && selectedPaths.length >= 2) {
      final chosen = existingImages.where((f) => selectedPaths.contains(f.path)).toList();
      await _createMangaBookFromImages(chosen, deleteSourceAfter: true);
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
    } else if (_imageExts.contains(ext)) {
      final currentGroup = _bookGroupMap[file.path];
      final siblingImages = _allBooks.where((f) {
        final fExt = f.path.split('.').last.toLowerCase();
        return _imageExts.contains(fExt) && _bookGroupMap[f.path] == currentGroup;
      }).toList();

      final targetList = siblingImages.length > 1 ? siblingImages : [file];
      final String bookKey = targetList.first.path;
      final savedPos = await StorageService.getLastPosition(bookKey);
      final clickedIdx = targetList.indexWhere((f) => f.path == file.path);

      if (clickedIdx > 0 || savedPos == null) {
        await StorageService.saveLastPosition(bookKey, clickedIdx.clamp(0, targetList.length - 1).toString());
      }

      if (!mounted) return;
      await Navigator.push(
        context,
        MaterialPageRoute(
          builder: (_) => UniversalMediaReaderScreen(
            files: targetList,
            title: targetList.length > 1 ? '$name 외 ${targetList.length - 1}장' : name,
            isPdf: false,
            customBookKey: bookKey,
          ),
        ),
      );
    } else {
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
        title: const Text('새 그룹 만들기'),
        content: TextField(
          controller: controller,
          decoration: const InputDecoration(
            border: OutlineInputBorder(),
          ),
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

  Future<void> _confirmDeleteGroup(String groupName) async {
    if (groupName == '전체') {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('"전체" 기본 보기는 삭제할 수 없습니다.')),
      );
      return;
    }

    final confirmed = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text('"$groupName" 그룹 삭제'),
        content: Text('"$groupName" 그룹을 삭제할까요?\n(그룹 안의 파일들은 삭제되지 않고 미분류로 유지됩니다)'),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text('취소')),
          ElevatedButton(
            style: ElevatedButton.styleFrom(backgroundColor: Colors.redAccent, foregroundColor: Colors.white),
            onPressed: () => Navigator.pop(ctx, true),
            child: const Text('그룹 삭제'),
          ),
        ],
      ),
    );

    if (confirmed == true) {
      await StorageService.removeGroup(groupName);
      if (_selectedGroup == groupName) {
        _selectedGroup = '전체';
      }
      await _loadLibrary();
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('"$groupName" 그룹이 삭제되었습니다.')),
        );
      }
    }
  }

  Future<void> _moveFileToTrash(File file, {bool reloadAfter = true}) async {
    final fileName = file.path.split(Platform.pathSeparator).last;
    final trashDir = await _getTrashDirectory();
    final targetPath = '${trashDir.path}/$fileName';
    if (await file.exists()) {
      await file.copy(targetPath);
      await file.delete();
    }
    if (reloadAfter) {
      await _loadLibrary();
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('"$fileName" 파일이 휴지통으로 이동되었습니다.')),
        );
      }
    }
  }

  Future<void> _deleteSelectedFilesBatch() async {
    if (_selectedFilePaths.isEmpty) return;
    final count = _selectedFilePaths.length;

    final confirmed = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('선택한 파일 삭제'),
        content: Text('선택한 ${count}개의 파일을 휴지통으로 이동할까요?'),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text('취소')),
          ElevatedButton(
            style: ElevatedButton.styleFrom(backgroundColor: Colors.redAccent, foregroundColor: Colors.white),
            onPressed: () => Navigator.pop(ctx, true),
            child: const Text('삭제'),
          ),
        ],
      ),
    );

    if (confirmed != true) return;

    final targets = _allBooks.where((f) => _selectedFilePaths.contains(f.path)).toList();
    for (final f in targets) {
      await _moveFileToTrash(f, reloadAfter: false);
    }

    setState(() {
      _selectedFilePaths.clear();
      _isSelectionMode = false;
    });

    await _loadLibrary();
    if (mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('${targets.length}개의 파일이 휴지통으로 이동되었습니다.')),
      );
    }
  }

  Future<void> _showTrashBinDialog() async {
    await _loadLibrary();
    if (!mounted) return;

    await showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      builder: (ctx) => StatefulBuilder(
        builder: (ctx, setModalState) => SafeArea(
          child: SizedBox(
            height: MediaQuery.of(context).size.height * 0.65,
            child: Column(
              children: [
                ListTile(
                  leading: const Icon(Icons.delete_outline),
                  title: Text(
                    '휴지통 (${_trashedBooks.length})',
                    style: const TextStyle(fontWeight: FontWeight.bold),
                  ),
                  trailing: _trashedBooks.isNotEmpty
                      ? TextButton.icon(
                          icon: const Icon(Icons.delete_forever, color: Colors.redAccent, size: 18),
                          label: const Text('휴지통 비우기', style: TextStyle(color: Colors.redAccent)),
                          onPressed: () async {
                            final confirmEmpty = await showDialog<bool>(
                              context: ctx,
                              builder: (dCtx) => AlertDialog(
                                title: const Text('휴지통 비우기'),
                                content: const Text('휴지통의 모든 파일을 영구 삭제할까요?'),
                                actions: [
                                  TextButton(onPressed: () => Navigator.pop(dCtx, false), child: const Text('취소')),
                                  ElevatedButton(
                                    style: ElevatedButton.styleFrom(
                                      backgroundColor: Colors.redAccent,
                                      foregroundColor: Colors.white,
                                    ),
                                    onPressed: () => Navigator.pop(dCtx, true),
                                    child: const Text('영구 삭제'),
                                  ),
                                ],
                              ),
                            );
                            if (confirmEmpty == true) {
                              final appDir = await getApplicationDocumentsDirectory();
                              for (final tf in _trashedBooks) {
                                final fileName = tf.path.split(Platform.pathSeparator).last;
                                await StorageService.removeBookMetadata('${appDir.path}/$fileName');
                                if (await tf.exists()) await tf.delete();
                              }
                              await _loadLibrary();
                              setModalState(() {});
                            }
                          },
                        )
                      : null,
                ),
                const Divider(height: 1),
                Expanded(
                  child: _trashedBooks.isEmpty
                      ? const Center(child: Text('휴지통이 비어 있습니다.'))
                      : ListView.separated(
                          itemCount: _trashedBooks.length,
                          separatorBuilder: (_, __) => const Divider(height: 1),
                          itemBuilder: (_, idx) {
                            final tf = _trashedBooks[idx];
                            final fileName = tf.path.split(Platform.pathSeparator).last;
                            return ListTile(
                              leading: const Icon(Icons.insert_drive_file_outlined),
                              title: Text(fileName, maxLines: 1, overflow: TextOverflow.ellipsis),
                              trailing: Row(
                                mainAxisSize: MainAxisSize.min,
                                children: [
                                  TextButton.icon(
                                    icon: const Icon(Icons.restore_from_trash, size: 18),
                                    label: const Text('복원'),
                                    onPressed: () async {
                                      final appDir = await getApplicationDocumentsDirectory();
                                      final restoredPath = '${appDir.path}/$fileName';
                                      if (await tf.exists()) {
                                        await tf.copy(restoredPath);
                                        await tf.delete();
                                      }
                                      await _loadLibrary();
                                      setModalState(() {});
                                      if (mounted) {
                                        ScaffoldMessenger.of(context).showSnackBar(
                                          SnackBar(content: Text('"$fileName" 파일이 복원되었습니다.')),
                                        );
                                      }
                                    },
                                  ),
                                  IconButton(
                                    icon: const Icon(Icons.delete_forever, color: Colors.redAccent),
                                    tooltip: '영구 삭제',
                                    onPressed: () async {
                                      final appDir = await getApplicationDocumentsDirectory();
                                      await StorageService.removeBookMetadata('${appDir.path}/$fileName');
                                      if (await tf.exists()) {
                                        await tf.delete();
                                      }
                                      await _loadLibrary();
                                      setModalState(() {});
                                      if (mounted) {
                                        ScaffoldMessenger.of(context).showSnackBar(
                                          SnackBar(content: Text('"$fileName" 파일이 영구 삭제되었습니다.')),
                                        );
                                      }
                                    },
                                  ),
                                ],
                              ),
                            );
                          },
                        ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  Future<void> _assignGroupDialog(File file) async {
    await showModalBottomSheet(
      context: context,
      builder: (ctx) => SafeArea(
        child: SingleChildScrollView(
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
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final filteredBooks = _selectedGroup == '전체'
        ? _allBooks
        : _allBooks.where((f) => _bookGroupMap[f.path] == _selectedGroup).toList();

    return Scaffold(
      appBar: _isSelectionMode
          ? AppBar(
              leading: IconButton(
                icon: const Icon(Icons.close),
                onPressed: () {
                  setState(() {
                    _isSelectionMode = false;
                    _selectedFilePaths.clear();
                  });
                },
              ),
              title: Text('${_selectedFilePaths.length}개 선택됨'),
              actions: [
                TextButton(
                  onPressed: () {
                    setState(() {
                      if (_selectedFilePaths.length == filteredBooks.length) {
                        _selectedFilePaths.clear();
                      } else {
                        _selectedFilePaths.addAll(filteredBooks.map((f) => f.path));
                      }
                    });
                  },
                  child: const Text('전체 선택'),
                ),
                IconButton(
                  icon: const Icon(Icons.delete_outline, color: Colors.redAccent),
                  tooltip: '선택 삭제',
                  onPressed: _selectedFilePaths.isNotEmpty ? _deleteSelectedFilesBatch : null,
                ),
              ],
            )
          : AppBar(
              title: const Text('MY'),
              actions: [
                IconButton(
                  icon: Icon(widget.isDarkMode ? Icons.light_mode : Icons.dark_mode),
                  tooltip: '다크 모드 전환',
                  onPressed: widget.onToggleDarkMode,
                ),
                IconButton(
                  icon: const Icon(Icons.auto_stories_outlined),
                  tooltip: 'JPG 이미지 합치기',
                  onPressed: _showMergeExistingImagesDialog,
                ),
                IconButton(
                  icon: const Icon(Icons.create_new_folder_outlined),
                  tooltip: '새 그룹 만들기',
                  onPressed: _createNewGroupDialog,
                ),
                IconButton(
                  icon: Badge(
                    isLabelVisible: _trashedBooks.isNotEmpty,
                    label: Text('${_trashedBooks.length}'),
                    child: const Icon(Icons.delete_outline),
                  ),
                  tooltip: '휴지통',
                  onPressed: _showTrashBinDialog,
                ),
              ],
            ),
      body: SafeArea(
        child: Column(
          children: [
            SizedBox(
              height: 54,
              child: ListView.separated(
                padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
                scrollDirection: Axis.horizontal,
                itemCount: _groups.length,
                separatorBuilder: (_, __) => const SizedBox(width: 8),
                itemBuilder: (context, index) {
                  final grp = _groups[index];
                  final selected = grp == _selectedGroup;
                  return GestureDetector(
                    onLongPress: () => _confirmDeleteGroup(grp),
                    child: ChoiceChip(
                      label: Text(grp),
                      selected: selected,
                      onSelected: (_) => setState(() => _selectedGroup = grp),
                    ),
                  );
                },
              ),
            ),
            const Divider(height: 1),
            Expanded(
              child: filteredBooks.isEmpty
                  ? Center(
                      child: Padding(
                        padding: const EdgeInsets.all(24.0),
                        child: OutlinedButton.icon(
                          icon: const Icon(Icons.auto_stories),
                          label: const Text('JPG 이미지 합치기'),
                          onPressed: _showMergeExistingImagesDialog,
                        ),
                      ),
                    )
                  : ListView.separated(
                      padding: const EdgeInsets.only(bottom: 88),
                      itemCount: filteredBooks.length,
                      separatorBuilder: (_, __) => const Divider(height: 1),
                      itemBuilder: (context, index) {
                        final file = filteredBooks[index];
                        final fileName = file.path.split(Platform.pathSeparator).last;
                        final grp = _bookGroupMap[file.path] ?? '미분류';
                        final prog = (_bookProgressMap[file.path] ?? 0.0) * 100;
                        final isSelected = _selectedFilePaths.contains(file.path);

                        return Dismissible(
                          key: ValueKey(file.path),
                          direction: _isSelectionMode ? DismissDirection.none : DismissDirection.endToStart,
                          background: Container(
                            color: Colors.redAccent,
                            alignment: Alignment.centerRight,
                            padding: const EdgeInsets.symmetric(horizontal: 20),
                            child: const Row(
                              mainAxisAlignment: MainAxisAlignment.end,
                              children: [
                                Icon(Icons.delete_outline, color: Colors.white),
                                SizedBox(width: 6),
                                Text('휴지통 이동', style: TextStyle(color: Colors.white, fontWeight: FontWeight.bold)),
                              ],
                            ),
                          ),
                          onDismissed: (_) => _moveFileToTrash(file),
                          child: ListTile(
                            selected: isSelected,
                            leading: _isSelectionMode
                                ? Checkbox(
                                    value: isSelected,
                                    onChanged: (v) {
                                      setState(() {
                                        if (v == true) {
                                          _selectedFilePaths.add(file.path);
                                        } else {
                                          _selectedFilePaths.remove(file.path);
                                          if (_selectedFilePaths.isEmpty) {
                                            _isSelectionMode = false;
                                          }
                                        }
                                      });
                                    },
                                  )
                                : Icon(
                                    fileName.toLowerCase().endsWith('.pdf')
                                        ? Icons.picture_as_pdf
                                        : (fileName.toLowerCase().endsWith('.epub') ||
                                                fileName.toLowerCase().endsWith('.txt'))
                                            ? Icons.menu_book
                                            : (fileName.toLowerCase().endsWith('.cbz') ||
                                                    fileName.toLowerCase().endsWith('.zip'))
                                                ? Icons.auto_stories
                                                : Icons.image,
                                    color: Colors.indigo,
                                  ),
                            title: Text(fileName, maxLines: 1, overflow: TextOverflow.ellipsis),
                            subtitle: Text(
                              '[$grp]  •  진행률 ${prog.toStringAsFixed(1)}%',
                              style: const TextStyle(fontSize: 12),
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                            ),
                            trailing: _isSelectionMode
                                ? null
                                : IconButton(
                                    icon: const Icon(Icons.drive_file_move_outline),
                                    tooltip: '그룹 변경',
                                    onPressed: () => _assignGroupDialog(file),
                                  ),
                            onLongPress: () {
                              setState(() {
                                _isSelectionMode = true;
                                _selectedFilePaths.add(file.path);
                              });
                            },
                            onTap: () {
                              if (_isSelectionMode) {
                                setState(() {
                                  if (isSelected) {
                                    _selectedFilePaths.remove(file.path);
                                    if (_selectedFilePaths.isEmpty) {
                                      _isSelectionMode = false;
                                    }
                                  } else {
                                    _selectedFilePaths.add(file.path);
                                  }
                                });
                              } else {
                                _openFile(file);
                              }
                            },
                          ),
                        );
                      },
                    ),
            ),
          ],
        ),
      ),
      floatingActionButton: _isSelectionMode
          ? FloatingActionButton.extended(
              backgroundColor: Colors.redAccent,
              foregroundColor: Colors.white,
              onPressed: _selectedFilePaths.isNotEmpty ? _deleteSelectedFilesBatch : null,
              icon: const Icon(Icons.delete_outline),
              label: Text('선택 삭제 (${_selectedFilePaths.length})'),
            )
          : FloatingActionButton.extended(
              onPressed: _pickAndImportFiles,
              icon: const Icon(Icons.add),
              label: const Text('파일 추가'),
            ),
    );
  }
}
