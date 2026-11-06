import 'dart:io';
import 'dart:math' as math;
import 'dart:ui' as ui;
import 'package:archive/archive.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:file_picker/file_picker.dart';
import 'package:path_provider/path_provider.dart';
import 'screens/pdf_and_image_viewer.dart';
import 'screens/reader_screen.dart';
import 'services/storage_service.dart';
import 'services/batch_translation_service.dart';
import 'services/txt_to_epub_converter.dart';

void main() async {
  WidgetsFlutterBinding.ensureInitialized();
  final initialDark = await StorageService.getDarkMode();
  final initialLang = await StorageService.getAppLanguage();
  runApp(MyEbookApp(initialDark: initialDark, initialLang: initialLang));
}

class MyEbookApp extends StatefulWidget {
  final bool initialDark;
  final String initialLang;
  const MyEbookApp({
    super.key,
    required this.initialDark,
    required this.initialLang,
  });

  @override
  State<MyEbookApp> createState() => _MyEbookAppState();
}

class _MyEbookAppState extends State<MyEbookApp> {
  late bool _isDarkMode;
  late String _appLang;

  @override
  void initState() {
    super.initState();
    _isDarkMode = widget.initialDark;
    _appLang = widget.initialLang;
  }

  void _toggleDarkMode() async {
    final nextVal = !_isDarkMode;
    setState(() => _isDarkMode = nextVal);
    await StorageService.setDarkMode(nextVal);
  }

  void _changeAppLanguage(String newLang) async {
    setState(() => _appLang = newLang);
    await StorageService.setAppLanguage(newLang);
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
        appLang: _appLang,
        onToggleDarkMode: _toggleDarkMode,
        onChangeLanguage: _changeAppLanguage,
      ),
    );
  }
}

class BookshelfScreen extends StatefulWidget {
  final bool isDarkMode;
  final String appLang;
  final VoidCallback onToggleDarkMode;
  final ValueChanged<String> onChangeLanguage;

  const BookshelfScreen({
    super.key,
    required this.isDarkMode,
    required this.appLang,
    required this.onToggleDarkMode,
    required this.onChangeLanguage,
  });

  @override
  State<BookshelfScreen> createState() => _BookshelfScreenState();
}

class _BookshelfScreenState extends State<BookshelfScreen> {
  static const MethodChannel _pdfChannel = MethodChannel('ebook_reader/pdf_renderer');

  List<File> _allBooks = [];
  List<File> _trashedBooks = [];
  List<String> _groups = ['전체', 'PDF/문서'];
  String _selectedGroup = '전체';
  Map<String, String> _bookGroupMap = {};
  Map<String, double> _bookProgressMap = {};
  Set<String> _favoritePaths = {};
  bool _hideFileExtension = false;

  bool _isSelectionMode = false;
  final Set<String> _selectedFilePaths = {};

  // 11. 삼성 노트(.sdocx, .spd), MS 워드(.docx, .doc), 한컴 한글(.hwpx, .hwp) 포함
  static const _supportedExts = [
    'epub', 'txt', 'pdf', 'jpg', 'jpeg', 'png', 'webp', 'cbz', 'zip',
    'sdocx', 'spd', 'docx', 'doc', 'hwpx', 'hwp'
  ];
  static const _imageExts = ['jpg', 'jpeg', 'png', 'webp'];
  static const _docConvertExts = ['txt', 'docx', 'doc', 'hwpx', 'hwp'];

  String _tr(String ko, String en, String zh, String ja) {
    switch (widget.appLang) {
      case 'en':
        return en;
      case 'zh':
        return zh;
      case 'ja':
        return ja;
      default:
        return ko;
    }
  }

  String _formatDisplayFileName(String rawFileName) {
    if (!_hideFileExtension) return rawFileName;
    final dotIdx = rawFileName.lastIndexOf('.');
    if (dotIdx > 0) {
      return rawFileName.substring(0, dotIdx);
    }
    return rawFileName;
  }

  @override
  void initState() {
    super.initState();
    BatchTranslationService.translationCompletedEvent.addListener(_onTranslationFinishedInBackground);
    _loadLibrary();
  }

  @override
  void dispose() {
    BatchTranslationService.translationCompletedEvent.removeListener(_onTranslationFinishedInBackground);
    super.dispose();
  }

  void _onTranslationFinishedInBackground() {
    if (mounted) {
      _loadLibrary();
    }
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

    final favs = await StorageService.getFavoriteBooks();
    final hideExt = await StorageService.getHideFileExtension();

    // 2. 즐겨찾기(별표)된 파일이 해당 그룹에서 가장 상단에 오도록 정렬
    files.sort((a, b) {
      final aFav = favs.contains(a.path);
      final bFav = favs.contains(b.path);
      if (aFav != bFav) return aFav ? -1 : 1;
      return _naturalCompare(
        a.path.split(Platform.pathSeparator).last,
        b.path.split(Platform.pathSeparator).last,
      );
    });

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
        _favoritePaths = favs;
        _hideFileExtension = hideExt;
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
          const SnackBar(
            content: Text('지원되는 파일 형식(EPUB, PDF, JPG, PNG, TXT, CBZ, ZIP, 삼성노트, 워드, 한글)을 선택해 주세요.'),
          ),
        );
      }
      return;
    }

    final pdfPicked = validPicked.where((pf) {
      final ext = pf.name.split('.').last.toLowerCase();
      return ext == 'pdf';
    }).toList();

    if (pdfPicked.length >= 2 && pdfPicked.length == validPicked.length && mounted) {
      final action = await showDialog<String>(
        context: context,
        builder: (ctx) => AlertDialog(
          title: Text('PDF ${pdfPicked.length}개 추가 방식 선택'),
          content: const Text(
            '선택한 PDF 파일들을 하나로 합쳐서 단일 PDF 파일로 추가할까요?',
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(ctx, 'separate'),
              child: const Text('개별 파일로 추가'),
            ),
            ElevatedButton.icon(
              icon: const Icon(Icons.picture_as_pdf, size: 18),
              onPressed: () => Navigator.pop(ctx, 'merge_pdf'),
              label: const Text('하나의 PDF로 합치기'),
            ),
          ],
        ),
      );

      if (action == 'merge_pdf') {
        final paths = pdfPicked.map((e) => File(e.path!)).toList();
        await _createMergedPdfFromFiles(paths, deleteSourceAfter: false);
        return;
      }
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
      // 13. '전체' 그룹에서 파일을 생성/추가하면 '[미분류]'로 분류!
      final targetGrp = _selectedGroup == '전체' ? '미분류' : _selectedGroup;
      await StorageService.setBookGroup(saved.path, targetGrp);
      importedFiles.add(saved);
    }

    await _loadLibrary();
    if (mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('${importedFiles.length}개의 파일이 서재에 추가되었습니다.')),
      );
    }
  }

  /// 10 & 13. JPG 통합 파일 만들기 (이름 순서 vs 선택한 순서 물어보기 + '전체' 탭에서는 '미분류'로 저장)
  Future<void> _createMangaBookFromImages(List<File> sourceImages, {bool deleteSourceAfter = false}) async {
    final now = DateTime.now();
    final dateStr = '${now.year}${now.month.toString().padLeft(2, '0')}${now.day.toString().padLeft(2, '0')}';
    final rand4 = (1000 + math.Random().nextInt(9000)).toString();
    final defaultFileName = '파일_${dateStr}_$rand4';

    final titleController = TextEditingController(text: defaultFileName);
    bool deleteOriginals = deleteSourceAfter;
    bool sortByName = true; // true: 이름 순서대로, false: 고른 순서대로

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
                TextField(
                  controller: titleController,
                  decoration: const InputDecoration(
                    labelText: '파일 제목',
                    suffixText: '.cbz',
                    border: OutlineInputBorder(),
                  ),
                ),
                const SizedBox(height: 14),
                const Text('합치는 순서 선택', style: TextStyle(fontSize: 13, fontWeight: FontWeight.bold)),
                RadioListTile<bool>(
                  dense: true,
                  contentPadding: EdgeInsets.zero,
                  title: const Text('파일 이름 순서대로 합치기', style: TextStyle(fontSize: 13)),
                  value: true,
                  groupValue: sortByName,
                  onChanged: (v) => setModalState(() => sortByName = v ?? true),
                ),
                RadioListTile<bool>(
                  dense: true,
                  contentPadding: EdgeInsets.zero,
                  title: const Text('파일을 고른(선택한) 순서대로 합치기', style: TextStyle(fontSize: 13)),
                  value: false,
                  groupValue: sortByName,
                  onChanged: (v) => setModalState(() => sortByName = v ?? false),
                ),
                if (deleteSourceAfter) ...[
                  const Divider(height: 12),
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
    final orderedImages = List<File>.from(sourceImages);
    if (sortByName) {
      orderedImages.sort((a, b) => _naturalCompare(
            a.path.split(Platform.pathSeparator).last,
            b.path.split(Platform.pathSeparator).last,
          ));
    }

    int currentStep = 0;
    final int totalSteps = orderedImages.length + 1;
    String progressStatus = '이미지 준비 중...';
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
                  '${(ratio * 100).toStringAsFixed(0)}% 완료 ($currentStep / ${orderedImages.length}장)',
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
    for (int i = 0; i < orderedImages.length; i++) {
      final img = orderedImages[i];
      final fileName = img.path.split(Platform.pathSeparator).last;
      final ext = img.path.split('.').last.toLowerCase();

      progressSetState?.call(() {
        currentStep = i + 1;
        progressStatus = '페이지 병합 중 (${i + 1}/${orderedImages.length}): $fileName';
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

    // 13. '전체' 그룹에서 파일을 생성하면 '[미분류]'로 분류!
    final targetGroup = _selectedGroup == '전체' ? '미분류' : _selectedGroup;
    await StorageService.setBookGroup(outFile.path, targetGroup);

    if (deleteOriginals) {
      for (final img in orderedImages) {
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

    // 선택한 순서를 그대로 기억하도록 List<String> 사용
    final List<String> selectedPaths = [];

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
                    Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        TextButton(
                          onPressed: () {
                            setModalState(() {
                              if (selectedPaths.length == existingImages.length) {
                                selectedPaths.clear();
                              } else {
                                selectedPaths
                                  ..clear()
                                  ..addAll(existingImages.map((e) => e.path));
                              }
                            });
                          },
                          child: const Text('전체선택'),
                        ),
                        TextButton.icon(
                          icon: const Icon(Icons.folder_open, size: 16),
                          label: const Text('기기에서 선택'),
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
                  ],
                ),
                const Divider(height: 1),
                Expanded(
                  child: ListView.builder(
                    itemCount: existingImages.length,
                    itemBuilder: (_, idx) {
                      final f = existingImages[idx];
                      final name = _formatDisplayFileName(f.path.split(Platform.pathSeparator).last);
                      final selIndex = selectedPaths.indexOf(f.path);
                      final checked = selIndex != -1;
                      return CheckboxListTile(
                        dense: true,
                        value: checked,
                        secondary: checked
                            ? CircleAvatar(
                                radius: 11,
                                backgroundColor: Colors.indigo,
                                child: Text(
                                  '${selIndex + 1}',
                                  style: const TextStyle(fontSize: 11, color: Colors.white, fontWeight: FontWeight.bold),
                                ),
                              )
                            : null,
                        title: Text(name, maxLines: 1, overflow: TextOverflow.ellipsis),
                        onChanged: (v) {
                          setModalState(() {
                            if (v == true) {
                              if (!selectedPaths.contains(f.path)) {
                                selectedPaths.add(f.path);
                              }
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
      final fileByPath = {for (final f in existingImages) f.path: f};
      final chosen = selectedPaths.map((p) => fileByPath[p]!).toList();
      await _createMangaBookFromImages(chosen, deleteSourceAfter: true);
    }
  }

  /// 5, 10, 13. 여러 PDF 파일을 하나의 PDF로 병합 (이름 순서 vs 고른 순서 선택 가능 + '전체' 탭에서는 '미분류' 분류)
  Future<void> _createMergedPdfFromFiles(List<File> sourcePdfs, {bool deleteSourceAfter = false}) async {
    final now = DateTime.now();
    final dateStr = '${now.year}${now.month.toString().padLeft(2, '0')}${now.day.toString().padLeft(2, '0')}';
    final rand4 = (1000 + math.Random().nextInt(9000)).toString();
    final defaultFileName = '통합PDF_${dateStr}_$rand4';

    final titleController = TextEditingController(text: defaultFileName);
    bool deleteOriginals = deleteSourceAfter;
    bool sortByName = false; // 기본값: 고른 순서대로 또는 이름 순서대로 선택 가능

    final confirmed = await showDialog<bool>(
      context: context,
      builder: (ctx) => StatefulBuilder(
        builder: (ctx, setModalState) => AlertDialog(
          title: const Text('PDF 하나로 합치기'),
          content: SingleChildScrollView(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text('선택한 ${sourcePdfs.length}개의 PDF를 합쳐 하나의 PDF로 만듭니다.'),
                const SizedBox(height: 12),
                TextField(
                  controller: titleController,
                  decoration: const InputDecoration(
                    labelText: '합쳐진 PDF 파일 이름',
                    suffixText: '.pdf',
                    border: OutlineInputBorder(),
                  ),
                ),
                const SizedBox(height: 14),
                const Text('합치는 순서 선택', style: TextStyle(fontSize: 13, fontWeight: FontWeight.bold)),
                RadioListTile<bool>(
                  dense: true,
                  contentPadding: EdgeInsets.zero,
                  title: const Text('파일을 고른(선택한) 순서대로 합치기', style: TextStyle(fontSize: 13)),
                  value: false,
                  groupValue: sortByName,
                  onChanged: (v) => setModalState(() => sortByName = v ?? false),
                ),
                RadioListTile<bool>(
                  dense: true,
                  contentPadding: EdgeInsets.zero,
                  title: const Text('파일 이름 순서대로 합치기', style: TextStyle(fontSize: 13)),
                  value: true,
                  groupValue: sortByName,
                  onChanged: (v) => setModalState(() => sortByName = v ?? true),
                ),
                if (deleteSourceAfter) ...[
                  const Divider(height: 12),
                  CheckboxListTile(
                    contentPadding: EdgeInsets.zero,
                    value: deleteOriginals,
                    title: const Text('합친 후 기존 개별 PDF 파일 휴지통으로 이동', style: TextStyle(fontSize: 13)),
                    onChanged: (v) => setModalState(() => deleteOriginals = v ?? false),
                  ),
                ],
              ],
            ),
          ),
          actions: [
            TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text('취소')),
            ElevatedButton.icon(
              icon: const Icon(Icons.picture_as_pdf, size: 18),
              onPressed: () => Navigator.pop(ctx, true),
              label: const Text('PDF 합치기'),
            ),
          ],
        ),
      ),
    );

    if (confirmed != true || !mounted) return;

    final rawTitle = titleController.text.trim().isEmpty ? defaultFileName : titleController.text.trim();
    final cleanTitle = rawTitle.replaceAll(RegExp(r'\.pdf$', caseSensitive: false), '');
    final safeTitle = cleanTitle.replaceAll(RegExp(r'[\\/:*?"<>|]'), '_');

    final orderedPdfs = List<File>.from(sourcePdfs);
    if (sortByName) {
      orderedPdfs.sort((a, b) => _naturalCompare(
            a.path.split(Platform.pathSeparator).last,
            b.path.split(Platform.pathSeparator).last,
          ));
    }

    showDialog(
      context: context,
      barrierDismissible: false,
      builder: (ctx) => const AlertDialog(
        title: Text('PDF 병합 중'),
        content: Row(
          children: [
            CircularProgressIndicator(),
            SizedBox(width: 16),
            Expanded(
              child: Text(
                'PDF 페이지들을 하나로 합치는 중입니다... 잠시만 기다려 주세요.',
                style: TextStyle(fontSize: 13),
              ),
            ),
          ],
        ),
      ),
    );

    try {
      final appDir = await getApplicationDocumentsDirectory();
      final outPath = '${appDir.path}/$safeTitle.pdf';

      await _pdfChannel.invokeMethod('mergePdfs', {
        'inputPaths': orderedPdfs.map((f) => f.path).toList(),
        'outputPath': outPath,
      });

      final outFile = File(outPath);
      // 13. '전체' 그룹에서 파일을 생성하면 '[미분류]'로 분류!
      final targetGroup = _selectedGroup == '전체' ? '미분류' : _selectedGroup;
      await StorageService.setBookGroup(outFile.path, targetGroup);

      if (deleteOriginals) {
        for (final pdf in orderedPdfs) {
          if (pdf.path != outFile.path && await pdf.exists()) {
            await _moveFileToTrash(pdf, reloadAfter: false);
          }
        }
      }

      if (mounted) Navigator.pop(context);
      await _loadLibrary();

      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('"$safeTitle.pdf" 통합 파일이 생성되었습니다.')),
        );
        _openFile(outFile);
      }
    } catch (e) {
      if (mounted) {
        Navigator.pop(context);
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('PDF 병합 중 오류가 발생했습니다: $e')),
        );
      }
    }
  }

  /// 10 & 17. PDF 합치기 다이얼로그 (기본 선택됨: 0개로 시작 + 선택한 순서 번호 표시!)
  Future<void> _showMergeExistingPdfsDialog() async {
    final existingPdfs = _allBooks.where((f) {
      final ext = f.path.split('.').last.toLowerCase();
      return ext == 'pdf';
    }).toList();

    if (existingPdfs.length < 2) {
      final result = await FilePicker.platform.pickFiles(
        type: FileType.custom,
        allowedExtensions: ['pdf'],
        allowMultiple: true,
      );
      if (result != null && result.files.length >= 2) {
        final files = result.files.where((f) => f.path != null).map((f) => File(f.path!)).toList();
        await _createMergedPdfFromFiles(files, deleteSourceAfter: false);
      } else if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('합칠 PDF 파일을 2개 이상 선택해 주세요.')),
        );
      }
      return;
    }

    // 17. 기본 설정을 '선택됨: 0개'로 변경! (사용자가 고르는 순서대로 리스트에 추가됨)
    final List<String> selectedPaths = [];

    final proceed = await showDialog<bool>(
      context: context,
      builder: (ctx) => StatefulBuilder(
        builder: (ctx, setModalState) => AlertDialog(
          title: const Text('PDF 합치기'),
          content: SizedBox(
            width: 420,
            height: 360,
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  mainAxisAlignment: MainAxisAlignment.spaceBetween,
                  children: [
                    Text('선택됨: ${selectedPaths.length}개', style: const TextStyle(fontWeight: FontWeight.bold)),
                    Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        TextButton(
                          onPressed: () {
                            setModalState(() {
                              if (selectedPaths.length == existingPdfs.length) {
                                selectedPaths.clear();
                              } else {
                                selectedPaths
                                  ..clear()
                                  ..addAll(existingPdfs.map((e) => e.path));
                              }
                            });
                          },
                          child: const Text('전체선택'),
                        ),
                        TextButton.icon(
                          icon: const Icon(Icons.folder_open, size: 16),
                          label: const Text('기기에서 선택'),
                          onPressed: () async {
                            Navigator.pop(ctx, false);
                            final result = await FilePicker.platform.pickFiles(
                              type: FileType.custom,
                              allowedExtensions: ['pdf'],
                              allowMultiple: true,
                            );
                            if (result != null && result.files.length >= 2) {
                              final files = result.files.where((f) => f.path != null).map((f) => File(f.path!)).toList();
                              await _createMergedPdfFromFiles(files, deleteSourceAfter: false);
                            }
                          },
                        ),
                      ],
                    ),
                  ],
                ),
                const Divider(height: 1),
                Expanded(
                  child: ListView.builder(
                    itemCount: existingPdfs.length,
                    itemBuilder: (_, idx) {
                      final f = existingPdfs[idx];
                      final name = _formatDisplayFileName(f.path.split(Platform.pathSeparator).last);
                      final selIndex = selectedPaths.indexOf(f.path);
                      final checked = selIndex != -1;
                      return CheckboxListTile(
                        dense: true,
                        value: checked,
                        secondary: checked
                            ? CircleAvatar(
                                radius: 11,
                                backgroundColor: Colors.indigo,
                                child: Text(
                                  '${selIndex + 1}',
                                  style: const TextStyle(fontSize: 11, color: Colors.white, fontWeight: FontWeight.bold),
                                ),
                              )
                            : null,
                        title: Text(name, maxLines: 1, overflow: TextOverflow.ellipsis),
                        onChanged: (v) {
                          setModalState(() {
                            if (v == true) {
                              if (!selectedPaths.contains(f.path)) {
                                selectedPaths.add(f.path);
                              }
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
              child: const Text('선택한 PDF 합치기'),
            ),
          ],
        ),
      ),
    );

    if (proceed == true && selectedPaths.length >= 2) {
      final fileByPath = {for (final f in existingPdfs) f.path: f};
      final chosen = selectedPaths.map((p) => fileByPath[p]!).toList();
      await _createMergedPdfFromFiles(chosen, deleteSourceAfter: true);
    }
  }

  /// 3. 파일 이름 변경 다이얼로그 (연필 아이콘 클릭 시)
  Future<void> _renameFileDialog(File file) async {
    final fullName = file.path.split(Platform.pathSeparator).last;
    final dotIdx = fullName.lastIndexOf('.');
    final baseName = dotIdx > 0 ? fullName.substring(0, dotIdx) : fullName;
    final ext = dotIdx > 0 ? fullName.substring(dotIdx + 1) : '';

    final ctrl = TextEditingController(text: baseName);

    final confirmed = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('파일 이름 변경'),
        content: TextField(
          controller: ctrl,
          autofocus: true,
          decoration: InputDecoration(
            labelText: '새 파일 이름',
            suffixText: ext.isNotEmpty ? '.$ext' : null,
            border: const OutlineInputBorder(),
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: const Text('취소'),
          ),
          ElevatedButton(
            onPressed: () => Navigator.pop(ctx, true),
            child: const Text('변경'),
          ),
        ],
      ),
    );

    if (confirmed != true || !mounted) return;

    final rawNewBase = ctrl.text.trim();
    if (rawNewBase.isEmpty) return;

    final safeNewBase = rawNewBase.replaceAll(RegExp(r'[\\/:*?"<>|]'), '_');
    final newFileName = ext.isNotEmpty ? '$safeNewBase.$ext' : safeNewBase;
    if (newFileName == fullName) return;

    final newPath = '${file.parent.path}/$newFileName';
    if (await File(newPath).exists()) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('같은 이름의 파일이 이미 존재합니다.')),
        );
      }
      return;
    }

    try {
      final oldPath = file.path;
      await file.rename(newPath);
      await StorageService.migrateBookMetadata(oldPath, newPath);

      await _loadLibrary();
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('파일 이름이 "$newFileName"(으)로 변경되었습니다.')),
        );
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('이름 변경 실패: $e')),
        );
      }
    }
  }

  /// 11. 파일 열기 (EPUB, PDF, JPG, CBZ, TXT, 삼성 노트 .sdocx/.spd, 워드 .docx/.doc, 한글 .hwpx/.hwp 모두 지원!)
  Future<void> _openFile(File file) async {
    final rawName = file.path.split(Platform.pathSeparator).last;
    final displayName = _formatDisplayFileName(rawName);
    final ext = rawName.split('.').last.toLowerCase();

    if (ext == 'epub') {
      await Navigator.push(
        context,
        MaterialPageRoute(
          builder: (_) => ReaderScreen(filePath: file.path, bookTitle: displayName),
        ),
      );
    } else if (ext == 'sdocx' || ext == 'spd') {
      final noteImages = await TxtToEpubConverter.extractSamsungNoteImagesIfPresent(file);
      if (!mounted) return;
      if (noteImages.isNotEmpty) {
        await Navigator.push(
          context,
          MaterialPageRoute(
            builder: (_) => UniversalMediaReaderScreen(
              files: noteImages,
              title: displayName,
              isPdf: false,
              customBookKey: file.path,
            ),
          ),
        );
      } else {
        final epubFile = await TxtToEpubConverter.convertDocumentToEpub(file);
        if (!mounted) return;
        await Navigator.push(
          context,
          MaterialPageRoute(
            builder: (_) => ReaderScreen(filePath: epubFile.path, bookTitle: displayName),
          ),
        );
      }
    } else if (_docConvertExts.contains(ext)) {
      final epubFile = await TxtToEpubConverter.convertDocumentToEpub(file);
      if (!mounted) return;
      await Navigator.push(
        context,
        MaterialPageRoute(
          builder: (_) => ReaderScreen(filePath: epubFile.path, bookTitle: displayName),
        ),
      );
    } else if (ext == 'pdf') {
      await Navigator.push(
        context,
        MaterialPageRoute(
          builder: (_) => UniversalMediaReaderScreen(
            files: [file],
            title: displayName,
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
            title: targetList.length > 1 ? '$displayName 외 ${targetList.length - 1}장' : displayName,
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
            title: displayName,
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
          autofocus: true,
          decoration: const InputDecoration(
            hintText: '그룹 이름 입력',
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
        content: Text('"$groupName" 그룹을 삭제할까요?\n(그룹 안의 파일들은 삭제되지 않고 [미분류]로 유지됩니다)'),
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

  /// 14. 여러 개 선택한 파일을 한 번에 원하는 그룹으로 일괄 이동 ('선택 삭제' 왼쪽에 배치)
  Future<void> _moveSelectedFilesBatch() async {
    if (_selectedFilePaths.isEmpty) return;
    final candidateGroups = [
      ..._groups.where((g) => g != '전체'),
      if (!_groups.contains('미분류')) '미분류',
    ];

    final chosenGroup = await showModalBottomSheet<String>(
      context: context,
      builder: (ctx) => SafeArea(
        child: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              ListTile(
                title: Text(
                  '선택한 ${_selectedFilePaths.length}개 파일 그룹 이동',
                  style: const TextStyle(fontWeight: FontWeight.bold),
                ),
              ),
              const Divider(height: 1),
              ...candidateGroups.map((g) => ListTile(
                    leading: const Icon(Icons.folder_outlined),
                    title: Text(g),
                    onTap: () => Navigator.pop(ctx, g),
                  )),
            ],
          ),
        ),
      ),
    );

    if (chosenGroup == null) return;

    final count = _selectedFilePaths.length;
    for (final path in _selectedFilePaths) {
      await StorageService.setBookGroup(path, chosenGroup);
    }

    setState(() {
      _selectedFilePaths.clear();
      _isSelectionMode = false;
    });

    await _loadLibrary();
    if (mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('$count개의 파일이 [$chosenGroup] 그룹으로 이동되었습니다.')),
      );
    }
  }

  Future<void> _deleteSelectedFilesBatch() async {
    if (_selectedFilePaths.isEmpty) return;
    final count = _selectedFilePaths.length;

    final confirmed = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('선택한 파일 삭제'),
        content: Text('선택한 $count개의 파일을 휴지통으로 이동할까요?'),
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
                              title: Text(_formatDisplayFileName(fileName), maxLines: 1, overflow: TextOverflow.ellipsis),
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
                                      final confirmDelete = await showDialog<bool>(
                                        context: ctx,
                                        builder: (dCtx) => AlertDialog(
                                          title: const Text('영구 삭제'),
                                          content: Text('"$fileName" 파일을 영구 삭제할까요?'),
                                          actions: [
                                            TextButton(
                                              onPressed: () => Navigator.pop(dCtx, false),
                                              child: const Text('취소'),
                                            ),
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
                                      if (confirmDelete == true) {
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
    final candidateGroups = [
      ..._groups.where((g) => g != '전체'),
      if (!_groups.contains('미분류')) '미분류',
    ];
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
              ...candidateGroups.map((g) => ListTile(
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

  /// 5. 앱 내에서 언제든 열람 가능한 시각적 아이콘 설명 가이드 PDF 자동 생성 및 열기
  Future<void> _generateAndOpenIconGuidePdf() async {
    final appDir = await getApplicationDocumentsDirectory();
    final pdfFile = File('${appDir.path}/FReader_아이콘_설명_가이드.pdf');
    final tempDir = await getTemporaryDirectory();

    final pagesSpec = [
      {
        'title': '1. 서재(MY) 상단 바 및 그룹 바 아이콘 안내',
        'subtitle': '서재 화면 우측 상단 아이콘과 그룹(+) 추가 버튼의 위치 및 기능입니다.',
        'banner': '[MY 서재 상단 바]   ☀️/🌙 다크모드   |   📄 PDF 합치기   |   📖 JPG 합치기   |   🗑️ 휴지통   |   ⚙️ 설정',
        'items': [
          '• ☀️ / 🌙 (다크 모드 전환): 라이트 모드와 다크 모드를 즉시 전환합니다.',
          '• 📄 (PDF 합치기): 여러 개의 PDF 파일을 이름 순서 또는 고른 순서대로 묶어 하나의 PDF로 만듭니다.',
          '• 📖 (JPG 이미지 합치기): 여러 장의 JPG/PNG 이미지를 묶어 단권 만화/문서(.cbz)로 만듭니다.',
          '• 🗑️ (휴지통): 삭제한 파일을 복원하거나 영구 삭제합니다.',
          '• ⚙️ (톱니바퀴 설정): 프로그램 언어(한국어/영어/중국어/일본어) 변경 및 확장자 숨기기를 설정합니다.',
          '• [ + ] (그룹 바 맨 오른쪽 + 버튼): 새로운 파일 그룹(카테고리)을 추가합니다 (길게 누르면 그룹 삭제).',
        ],
      },
      {
        'title': '2. 파일 목록 우측 아이콘 및 다중 선택 기능 안내',
        'subtitle': '각 파일 항목의 오른쪽에 위치한 3가지 아이콘과 길게 누르기(다중 선택) 기능입니다.',
        'banner': '[파일 항목 우측]   파일이름.pdf          ⭐ 즐겨찾기   |   ✏️ 이름 변경   |   📁 그룹 이동',
        'items': [
          '• ⭐ / ☆ (별 모양 즐겨찾기): 누르면 노란색 별로 바뀌며 해당 그룹의 가장 상단에 고정됩니다.',
          '• ✏️ (연필 모양 편집): 파일의 확장자를 유지한 채 파일 이름을 변경합니다.',
          '• 📁 (파일 그룹 이동): 해당 파일을 다른 그룹 또는 [미분류]로 이동합니다.',
          '• [파일 길게 누르기 -> 다중 선택 모드]: 상단/하단의 [그룹 이동] 버튼으로 여러 파일을 한 번에 이동하거나 [선택 삭제]로 일괄 삭제합니다.',
        ],
      },
      {
        'title': '3. 뷰어 상단 바 · S펜 필기 툴바 · 하단 진행도/이동 버튼 안내',
        'subtitle': '파일 열람 중 화면을 가볍게 탭하면 나타나는 상단·하단 컨트롤 아이콘 설명입니다.',
        'banner': '[뷰어 상단 바]  ← 뒤로  |  ⏮️ 이전 파일  |  ⏭️ 다음 파일  |  🖊️ S펜 필기  |  📖 2페이지  |  ⇄ 방향  |  🌐 번역  |  🔖 북마크  |  🎛️ 설정',
        'items': [
          '• ⏮️ / ⏭️ (이전·다음 파일 이동): 현재 파일과 같은 그룹에 속한 이전/다음 파일로 즉시 이동합니다.',
          '• 🖊️ (S펜 필기 툴바): 6가지 색상(노란·빨간·하늘·초록·흰색·검은색), 선 굵기 슬라이더, S펜 지우개, 메모 기능을 제공합니다.',
          '• 🌐 (Google ML Kit 번역): 일본어·중국어·한국어 텍스트를 현재 설정된 앱 언어로 백그라운드 번역합니다.',
          '• ⏮ / ⏭ (진행도 바 양끝 화살표): 문서의 맨 처음(1페이지)과 맨 마지막 페이지로 즉시 이동합니다.',
          '• ⬅️ / ➡️ (우측 하단 페이지 이동 버튼): 이전 페이지(←)와 다음 페이지(→)로 전환합니다.',
          '• 📳 화면 잠금/해제: 기기를 흔들거나 음량(+)·(-) 버튼을 동시에 눌러 화면 터치를 잠그고 해제합니다.',
        ],
      },
    ];

    final List<String> pngPaths = [];
    for (int i = 0; i < pagesSpec.length; i++) {
      final spec = pagesSpec[i];
      final recorder = ui.PictureRecorder();
      const double w = 1240;
      const double h = 1754;
      final canvas = Canvas(recorder, const Rect.fromLTWH(0, 0, w, h));

      canvas.drawRect(const Rect.fromLTWH(0, 0, w, h), Paint()..color = const Color(0xFFF8FAFC));
      canvas.drawRect(const Rect.fromLTWH(0, 0, w, 150), Paint()..color = const Color(0xFF1E293B));

      void drawText(String text, double x, double y, double maxW, double fontSize, Color color, {FontWeight weight = FontWeight.normal}) {
        final tp = TextPainter(
          text: TextSpan(
            text: text,
            style: TextStyle(color: color, fontSize: fontSize, fontWeight: weight, height: 1.45),
          ),
          textDirection: TextDirection.ltr,
        )..layout(maxWidth: maxW);
        tp.paint(canvas, Offset(x, y));
      }

      drawText('FReader 아이콘 및 기능 설명 가이드 (${i + 1}/${pagesSpec.length})', 60, 48, w - 120, 34, Colors.white, weight: FontWeight.bold);
      drawText(spec['title'] as String, 60, 195, w - 120, 32, const Color(0xFF0F172A), weight: FontWeight.bold);
      drawText(spec['subtitle'] as String, 60, 250, w - 120, 22, const Color(0xFF475569));

      // Draw visual bar mockup
      final bannerRect = RRect.fromRectAndRadius(const Rect.fromLTWH(60, 320, w - 120, 120), const Radius.circular(18));
      canvas.drawRRect(bannerRect, Paint()..color = const Color(0xFF0F172A));
      drawText(spec['banner'] as String, 90, 360, w - 180, 24, const Color(0xFFFBBF24), weight: FontWeight.bold);

      double curY = 490;
      for (final item in (spec['items'] as List<String>)) {
        final cardRect = RRect.fromRectAndRadius(Rect.fromLTWH(60, curY, w - 120, 165), const Radius.circular(14));
        canvas.drawRRect(cardRect, Paint()..color = Colors.white);
        canvas.drawRRect(
          cardRect,
          Paint()
            ..color = const Color(0xFFCBD5E1)
            ..style = PaintingStyle.stroke
            ..strokeWidth = 2,
        );
        drawText(item, 90, curY + 32, w - 180, 23, const Color(0xFF1E293B), weight: FontWeight.w600);
        curY += 190;
      }

      final picture = recorder.endRecording();
      final img = await picture.toImage(w.toInt(), h.toInt());
      final byteData = await img.toByteData(format: ui.ImageByteFormat.png);
      final pngFile = File('${tempDir.path}/guide_page_$i.png');
      await pngFile.writeAsBytes(byteData!.buffer.asUint8List());
      pngPaths.add(pngFile.path);
    }

    if (!mounted) return;
    await Navigator.push(
      context,
      MaterialPageRoute(
        builder: (_) => UniversalMediaReaderScreen(
          files: pngPaths.map((p) => File(p)).toList(),
          title: 'FReader 아이콘 설명 가이드',
          isPdf: false,
          customBookKey: pdfFile.path,
        ),
      ),
    );
  }

  /// 6 & 15. 우측 상단 톱니바퀴(설정) 다이얼로그: 언어 변경(한국어/영어/중국어/일본어) + 파일 형식(확장자) 숨기기 + 화면 잠금 설정 + 아이콘 가이드 보기
  Future<void> _showGlobalSettingsDialog() async {
    bool useShake = await StorageService.getUseShakeLock();
    bool useVolCombo = await StorageService.getUseVolumeComboLock();
    String currentLang = widget.appLang;
    bool hideExt = _hideFileExtension;

    if (!mounted) return;
    await showDialog(
      context: context,
      builder: (ctx) => StatefulBuilder(
        builder: (ctx, setModalState) => AlertDialog(
          title: Row(
            children: [
              const Icon(Icons.settings, size: 22),
              const SizedBox(width: 8),
              Text(_tr('프로그램 설정', 'Settings', '应用设置', 'アプリ設定')),
            ],
          ),
          content: SingleChildScrollView(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  _tr('1. 언어 설정 (표시 언어 및 번역 타겟 언어)', '1. Language (UI & Translation Target)', '1. 语言设置 (界面与翻译目标语言)', '1. 言語設定 (表示および翻訳先言語)'),
                  style: const TextStyle(fontSize: 13, fontWeight: FontWeight.bold),
                ),
                const SizedBox(height: 8),
                Wrap(
                  spacing: 8,
                  runSpacing: 6,
                  children: [
                    {'code': 'ko', 'label': '한국어'},
                    {'code': 'en', 'label': 'English'},
                    {'code': 'zh', 'label': '中文'},
                    {'code': 'ja', 'label': '日本語'},
                  ].map((item) {
                    final code = item['code']!;
                    return ChoiceChip(
                      label: Text(item['label']!),
                      selected: currentLang == code,
                      onSelected: (_) {
                        setModalState(() => currentLang = code);
                        widget.onChangeLanguage(code);
                      },
                    );
                  }).toList(),
                ),
                const Divider(height: 24),
                Text(
                  _tr('2. 파일 표시 설정', '2. File Display', '2. 文件显示设置', '2. ファイル表示設定'),
                  style: const TextStyle(fontSize: 13, fontWeight: FontWeight.bold),
                ),
                SwitchListTile(
                  contentPadding: EdgeInsets.zero,
                  dense: true,
                  title: Text(
                    _tr('파일 이름 뒤에 형식(.pdf, .epub 등) 숨기기', 'Hide file extension (.pdf, .epub)', '隐藏文件扩展名', '파일 확장자(.pdf 등)を隠す'),
                    style: const TextStyle(fontSize: 13),
                  ),
                  value: hideExt,
                  onChanged: (val) async {
                    await StorageService.setHideFileExtension(val);
                    setModalState(() => hideExt = val);
                    setState(() => _hideFileExtension = val);
                  },
                ),
                const Divider(height: 24),
                Text(
                  _tr('3. 화면 잠금 방식 설정 (동시 사용 가능)', '3. Screen Lock Methods', '3. 屏幕锁定方式', '3. 画面ロック設定'),
                  style: const TextStyle(fontSize: 13, fontWeight: FontWeight.bold),
                ),
                CheckboxListTile(
                  contentPadding: EdgeInsets.zero,
                  dense: true,
                  title: const Text('흔들어서 잠그고 끄기', style: TextStyle(fontSize: 13)),
                  value: useShake,
                  onChanged: (val) async {
                    final next = val ?? true;
                    await StorageService.setUseShakeLock(next);
                    setModalState(() => useShake = next);
                  },
                ),
                CheckboxListTile(
                  contentPadding: EdgeInsets.zero,
                  dense: true,
                  title: const Text('음량 버튼 동시에 눌러서 끄고 켜기', style: TextStyle(fontSize: 13)),
                  value: useVolCombo,
                  onChanged: (val) async {
                    final next = val ?? true;
                    await StorageService.setUseVolumeComboLock(next);
                    setModalState(() => useVolCombo = next);
                  },
                ),
                const Divider(height: 24),
                SizedBox(
                  width: double.infinity,
                  child: OutlinedButton.icon(
                    icon: const Icon(Icons.menu_book_outlined, size: 18),
                    label: const Text('각 아이콘 위치 및 기능 설명 가이드 열람'),
                    onPressed: () {
                      Navigator.pop(ctx);
                      _generateAndOpenIconGuidePdf();
                    },
                  ),
                ),
              ],
            ),
          ),
          actions: [
            ElevatedButton(
              onPressed: () => Navigator.pop(ctx),
              child: Text(_tr('닫기', 'Close', '关闭', '閉じる')),
            ),
          ],
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final filteredBooks = _selectedGroup == '전체'
        ? _allBooks
        : _allBooks.where((f) => (_bookGroupMap[f.path] ?? '미분류') == _selectedGroup).toList();

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
                  child: Text(_tr('전체 선택', 'Select All', '全选', 'すべて選択')),
                ),
                // 14. '선택 삭제' 왼쪽에 '그룹 이동' 버튼 배치!
                TextButton.icon(
                  icon: const Icon(Icons.drive_file_move_outline, size: 18),
                  label: Text(_tr('그룹 이동', 'Move Group', '移动分组', 'グループ移動')),
                  onPressed: _selectedFilePaths.isNotEmpty ? _moveSelectedFilesBatch : null,
                ),
                IconButton(
                  icon: const Icon(Icons.delete_outline, color: Colors.redAccent),
                  tooltip: _tr('선택 삭제', 'Delete Selected', '删除所选', '選択削除'),
                  onPressed: _selectedFilePaths.isNotEmpty ? _deleteSelectedFilesBatch : null,
                ),
              ],
            )
          : AppBar(
              title: const Text('MY'),
              actions: [
                IconButton(
                  icon: Icon(widget.isDarkMode ? Icons.light_mode : Icons.dark_mode),
                  tooltip: _tr('다크 모드 전환', 'Toggle Dark Mode', '切换深色模式', 'ダークモード切替'),
                  onPressed: widget.onToggleDarkMode,
                ),
                IconButton(
                  icon: const Icon(Icons.picture_as_pdf_outlined),
                  tooltip: _tr('PDF 합치기', 'Merge PDFs', '合并 PDF', 'PDF結合'),
                  onPressed: _showMergeExistingPdfsDialog,
                ),
                IconButton(
                  icon: const Icon(Icons.auto_stories_outlined),
                  tooltip: _tr('JPG 이미지 합치기', 'Merge JPGs', '合并图片', 'JPG結合'),
                  onPressed: _showMergeExistingImagesDialog,
                ),
                // 9. 상단 바의 파일 그룹 생성 아이콘을 제거하고 그룹 네모칸 맨 우측 [+] 버튼으로 대체!
                IconButton(
                  icon: Badge(
                    isLabelVisible: _trashedBooks.isNotEmpty,
                    label: Text('${_trashedBooks.length}'),
                    child: const Icon(Icons.delete_outline),
                  ),
                  tooltip: _tr('휴지통', 'Trash', '回收站', 'ゴミ箱'),
                  onPressed: _showTrashBinDialog,
                ),
                // 6. 휴지통 옆에 톱니바퀴(설정) 아이콘 추가!
                IconButton(
                  icon: const Icon(Icons.settings_outlined),
                  tooltip: _tr('설정', 'Settings', '设置', '設定'),
                  onPressed: _showGlobalSettingsDialog,
                ),
              ],
            ),
      body: SafeArea(
        child: Column(
          children: [
            // 9. 파일 그룹 이름이 있는 네모칸 가장 오른쪽에 [+] 아이콘을 추가해서 누르면 그룹을 추가!
            SizedBox(
              height: 54,
              child: ListView.separated(
                padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
                scrollDirection: Axis.horizontal,
                itemCount: _groups.length + 1,
                separatorBuilder: (_, __) => const SizedBox(width: 8),
                itemBuilder: (context, index) {
                  if (index == _groups.length) {
                    return ActionChip(
                      avatar: const Icon(Icons.add, size: 18),
                      label: const Text('+', style: TextStyle(fontWeight: FontWeight.bold)),
                      tooltip: _tr('새 그룹 추가', 'Add Group', '新建分组', 'グループ追加'),
                      onPressed: _createNewGroupDialog,
                    );
                  }
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
                        child: Wrap(
                          spacing: 12,
                          runSpacing: 10,
                          alignment: WrapAlignment.center,
                          children: [
                            OutlinedButton.icon(
                              icon: const Icon(Icons.picture_as_pdf),
                              label: Text(_tr('PDF 합치기', 'Merge PDFs', '合并 PDF', 'PDF結合')),
                              onPressed: _showMergeExistingPdfsDialog,
                            ),
                            OutlinedButton.icon(
                              icon: const Icon(Icons.auto_stories),
                              label: Text(_tr('JPG 이미지 합치기', 'Merge JPGs', '合并图片', 'JPG結合')),
                              onPressed: _showMergeExistingImagesDialog,
                            ),
                          ],
                        ),
                      ),
                    )
                  : ListView.separated(
                      padding: const EdgeInsets.only(bottom: 88),
                      itemCount: filteredBooks.length,
                      separatorBuilder: (_, __) => const Divider(height: 1),
                      itemBuilder: (context, index) {
                        final file = filteredBooks[index];
                        final rawFileName = file.path.split(Platform.pathSeparator).last;
                        final displayFileName = _formatDisplayFileName(rawFileName);
                        final grp = _bookGroupMap[file.path] ?? '미분류';
                        final prog = (_bookProgressMap[file.path] ?? 0.0) * 100;
                        final isSelected = _selectedFilePaths.contains(file.path);
                        final isFavorite = _favoritePaths.contains(file.path);
                        final lowerExt = rawFileName.split('.').last.toLowerCase();

                        // 16. 라이트 모드에서 번역 진행도가 어둡고 선명하게 보이도록 색상 보정
                        final Color badgeBg = widget.isDarkMode
                            ? Colors.amber.withOpacity(0.18)
                            : const Color(0xFF1E293B);
                        final Color badgeBorder = widget.isDarkMode
                            ? Colors.amber
                            : const Color(0xFF0F172A);
                        final Color badgeFg = widget.isDarkMode
                            ? Colors.amber
                            : Colors.white;
                        final Color progressBarColor = widget.isDarkMode
                            ? Colors.amber
                            : const Color(0xFF0F766E);

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
                                    lowerExt == 'pdf'
                                        ? Icons.picture_as_pdf
                                        : (lowerExt == 'sdocx' || lowerExt == 'spd')
                                            ? Icons.edit_note_rounded
                                            : (lowerExt == 'docx' || lowerExt == 'doc' || lowerExt == 'hwpx' || lowerExt == 'hwp')
                                                ? Icons.description_outlined
                                                : (lowerExt == 'epub' || lowerExt == 'txt')
                                                    ? Icons.menu_book
                                                    : (lowerExt == 'cbz' || lowerExt == 'zip')
                                                        ? Icons.auto_stories
                                                        : Icons.image,
                                    color: Colors.indigo,
                                  ),
                            title: ValueListenableBuilder<Map<String, TranslationTaskInfo>>(
                              valueListenable: BatchTranslationService.activeTasks,
                              builder: (context, activeTasks, _) {
                                TranslationTaskInfo? task = activeTasks[file.path];
                                if (task == null && _imageExts.contains(lowerExt)) {
                                  final currentGroup = _bookGroupMap[file.path];
                                  final firstSibling = _allBooks.firstWhere(
                                    (f) =>
                                        _imageExts.contains(f.path.split('.').last.toLowerCase()) &&
                                        _bookGroupMap[f.path] == currentGroup,
                                    orElse: () => file,
                                  );
                                  task = activeTasks[firstSibling.path];
                                }
                                return Row(
                                  children: [
                                    Expanded(
                                      child: Text(
                                        displayFileName,
                                        maxLines: 1,
                                        overflow: TextOverflow.ellipsis,
                                      ),
                                    ),
                                    if (task != null) ...[
                                      const SizedBox(width: 8),
                                      Container(
                                        padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
                                        decoration: BoxDecoration(
                                          color: badgeBg,
                                          borderRadius: BorderRadius.circular(12),
                                          border: Border.all(color: badgeBorder, width: 1),
                                        ),
                                        child: Row(
                                          mainAxisSize: MainAxisSize.min,
                                          children: [
                                            SizedBox(
                                              width: 11,
                                              height: 11,
                                              child: CircularProgressIndicator(
                                                strokeWidth: 2,
                                                color: badgeFg,
                                              ),
                                            ),
                                            const SizedBox(width: 5),
                                            Text(
                                              '번역 ${(task.progress * 100).toStringAsFixed(0)}% (${task.current}/${task.total})',
                                              style: TextStyle(
                                                fontSize: 11,
                                                fontWeight: FontWeight.bold,
                                                color: badgeFg,
                                              ),
                                            ),
                                          ],
                                        ),
                                      ),
                                    ],
                                  ],
                                );
                              },
                            ),
                            subtitle: ValueListenableBuilder<Map<String, TranslationTaskInfo>>(
                              valueListenable: BatchTranslationService.activeTasks,
                              builder: (context, activeTasks, _) {
                                TranslationTaskInfo? task = activeTasks[file.path];
                                if (task == null && _imageExts.contains(lowerExt)) {
                                  final currentGroup = _bookGroupMap[file.path];
                                  final firstSibling = _allBooks.firstWhere(
                                    (f) =>
                                        _imageExts.contains(f.path.split('.').last.toLowerCase()) &&
                                        _bookGroupMap[f.path] == currentGroup,
                                    orElse: () => file,
                                  );
                                  task = activeTasks[firstSibling.path];
                                }
                                return Column(
                                  crossAxisAlignment: CrossAxisAlignment.start,
                                  children: [
                                    Text(
                                      task != null
                                          ? '[$grp]  •  진행률 ${prog.toStringAsFixed(1)}%  •  ${task.status}'
                                          : '[$grp]  •  진행률 ${prog.toStringAsFixed(1)}%',
                                      style: const TextStyle(fontSize: 12),
                                      maxLines: 1,
                                      overflow: TextOverflow.ellipsis,
                                    ),
                                    if (task != null) ...[
                                      const SizedBox(height: 4),
                                      LinearProgressIndicator(
                                        value: task.progress.clamp(0.0, 1.0).toDouble(),
                                        minHeight: 5,
                                        color: progressBarColor,
                                        backgroundColor: widget.isDarkMode ? Colors.white12 : Colors.black12,
                                        borderRadius: BorderRadius.circular(2),
                                      ),
                                    ],
                                  ],
                                );
                              },
                            ),
                            // 2 & 3. 편집(연필) 아이콘 왼쪽에 별 모양(즐겨찾기) 아이콘 추가!
                            trailing: _isSelectionMode
                                ? null
                                : Row(
                                    mainAxisSize: MainAxisSize.min,
                                    children: [
                                      IconButton(
                                        visualDensity: VisualDensity.compact,
                                        icon: Icon(
                                          isFavorite ? Icons.star_rounded : Icons.star_border_rounded,
                                          color: isFavorite ? Colors.amber : null,
                                        ),
                                        tooltip: _tr('즐겨찾기', 'Favorite', '收藏', 'お気に入り'),
                                        onPressed: () async {
                                          await StorageService.toggleFavoriteBook(file.path);
                                          await _loadLibrary();
                                        },
                                      ),
                                      IconButton(
                                        visualDensity: VisualDensity.compact,
                                        icon: const Icon(Icons.edit_outlined),
                                        tooltip: _tr('파일 이름 변경', 'Rename', '重命名', '名前変更'),
                                        onPressed: () => _renameFileDialog(file),
                                      ),
                                      IconButton(
                                        visualDensity: VisualDensity.compact,
                                        icon: const Icon(Icons.drive_file_move_outline),
                                        tooltip: _tr('그룹 변경', 'Move Group', '移动分组', 'グループ移動'),
                                        onPressed: () => _assignGroupDialog(file),
                                      ),
                                    ],
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
      // 14. 다중 선택 모드 하단에도 '선택 삭제' 왼쪽에 '그룹 이동' 버튼 배치!
      floatingActionButton: _isSelectionMode
          ? Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                FloatingActionButton.extended(
                  heroTag: 'fab_batch_move_group',
                  backgroundColor: Colors.indigo,
                  foregroundColor: Colors.white,
                  onPressed: _selectedFilePaths.isNotEmpty ? _moveSelectedFilesBatch : null,
                  icon: const Icon(Icons.drive_file_move_outline),
                  label: Text('${_tr("그룹 이동", "Move Group", "移动分组", "グループ移動")} (${_selectedFilePaths.length})'),
                ),
                const SizedBox(width: 10),
                FloatingActionButton.extended(
                  heroTag: 'fab_batch_delete',
                  backgroundColor: Colors.redAccent,
                  foregroundColor: Colors.white,
                  onPressed: _selectedFilePaths.isNotEmpty ? _deleteSelectedFilesBatch : null,
                  icon: const Icon(Icons.delete_outline),
                  label: Text('${_tr("선택 삭제", "Delete", "删除", "削除")} (${_selectedFilePaths.length})'),
                ),
              ],
            )
          : FloatingActionButton.extended(
              onPressed: _pickAndImportFiles,
              icon: const Icon(Icons.add),
              label: Text(_tr('파일 추가', 'Add Files', '添加文件', 'ファイル追加')),
            ),
    );
  }
}
