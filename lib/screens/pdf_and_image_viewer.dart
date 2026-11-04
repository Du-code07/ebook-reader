import 'dart:async';
import 'dart:io';
import 'package:archive/archive.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:google_mlkit_text_recognition/google_mlkit_text_recognition.dart';
import 'package:path_provider/path_provider.dart';
import '../services/batch_translation_service.dart';
import '../services/storage_service.dart';
import '../services/volume_key_service.dart';

class UniversalMediaReaderScreen extends StatefulWidget {
  final List<File> files;
  final String title;
  final bool isPdf;

  const UniversalMediaReaderScreen({
    super.key,
    required this.files,
    required this.title,
    required this.isPdf,
  });

  @override
  State<UniversalMediaReaderScreen> createState() => _UniversalMediaReaderScreenState();
}

class _UniversalMediaReaderScreenState extends State<UniversalMediaReaderScreen> {
  static const MethodChannel _pdfChannel = MethodChannel('ebook_reader/pdf_renderer');
  final PageController _pageController = PageController();
  final VolumeKeyService _volumeKeyService = VolumeKeyService();

  List<File> _imagePages = [];
  bool _isPreparingPages = true;
  int _currentPage = 0;
  int _totalPages = 1;
  int? _previousJumpPage;
  bool _showControls = true;
  bool _showTranslatedBubbles = false;
  bool _isMangaRtlMode = false;
  TextRecognitionScript _selectedScript = TextRecognitionScript.japanese;
  String _sourceLangCode = 'ja';
  Map<int, List<BubbleTranslation>> _bubblesByPage = {};

  int _totalReadingSeconds = 0;
  Timer? _readingTimer;

  String get _bookKey => widget.files.first.path;

  @override
  void initState() {
    super.initState();
    _initMedia();
  }

  Future<void> _initMedia() async {
    _totalReadingSeconds = await StorageService.getReadingSeconds(_bookKey);
    final tempDir = await getTemporaryDirectory();
    final first = widget.files.first;
    final lower = first.path.toLowerCase();

    if (widget.isPdf || lower.endsWith('.pdf')) {
      // Android 내장 PdfRenderer를 통해 PDF 페이지들을 이미지로 변환 (PDF에서도 말풍선 번역 완벽 작동)
      final outDir = Directory('${tempDir.path}/pdf_${first.uri.pathSegments.last}');
      final List<dynamic>? renderedPaths = await _pdfChannel.invokeMethod('renderPdfToImages', {
        'pdfPath': first.path,
        'outDirPath': outDir.path,
      });
      if (renderedPaths != null) {
        _imagePages = renderedPaths.map((p) => File(p.toString())).toList();
      }
    } else if (lower.endsWith('.cbz') || lower.endsWith('.zip')) {
      final bytes = await first.readAsBytes();
      final archive = ZipDecoder().decodeBytes(bytes);
      final extractDir = Directory('${tempDir.path}/cbz_${first.uri.pathSegments.last}');
      await extractDir.create(recursive: true);
      final extracted = <File>[];
      for (final f in archive.files) {
        if (f.isFile &&
            (f.name.toLowerCase().endsWith('.jpg') ||
                f.name.toLowerCase().endsWith('.jpeg') ||
                f.name.toLowerCase().endsWith('.png') ||
                f.name.toLowerCase().endsWith('.webp'))) {
          final outFile = File('${extractDir.path}/${f.name.split('/').last}');
          await outFile.writeAsBytes(f.content as List<int>);
          extracted.add(outFile);
        }
      }
      extracted.sort((a, b) => a.path.compareTo(b.path));
      _imagePages = extracted;
    } else {
      _imagePages = widget.files;
    }

    _totalPages = _imagePages.isNotEmpty ? _imagePages.length : 1;

    final savedPos = await StorageService.getLastPosition(_bookKey);
    if (savedPos != null) {
      final savedPage = int.tryParse(savedPos) ?? 0;
      _currentPage = savedPage.clamp(0, _totalPages - 1);
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (_pageController.hasClients) {
          _pageController.jumpToPage(_currentPage);
        }
      });
    }

    for (int i = 0; i < _imagePages.length; i++) {
      final cached = await StorageService.getImageBubbleCache(_bookKey, i);
      if (cached != null) {
        _bubblesByPage[i] = cached;
      }
    }
    if (_bubblesByPage.isNotEmpty) {
      _showTranslatedBubbles = true;
    }

    _volumeKeyService.startListening(
      onVolumeUp: () => _goToPage(_currentPage - 1),
      onVolumeDown: () => _goToPage(_currentPage + 1),
    );

    _readingTimer = Timer.periodic(const Duration(seconds: 1), (_) {
      if (mounted) {
        setState(() => _totalReadingSeconds++);
        if (_totalReadingSeconds % 5 == 0) {
          StorageService.addReadingSeconds(_bookKey, 5);
        }
      }
    });

    if (mounted) {
      setState(() => _isPreparingPages = false);
    }
  }

  void _goToPage(int page, {bool recordHistory = true}) {
    if (page < 0 || page >= _totalPages) return;
    if (recordHistory && (page - _currentPage).abs() > 1) {
      _previousJumpPage = _currentPage;
    }
    setState(() => _currentPage = page);
    StorageService.saveLastPosition(_bookKey, page.toString());
    if (_totalPages > 0) {
      StorageService.saveProgress(_bookKey, (page + 1) / _totalPages);
    }

    if (_pageController.hasClients) {
      _pageController.jumpToPage(page);
    }
  }

  Future<void> _showLanguageAndTranslateDialog() async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (ctx) => StatefulBuilder(
        builder: (ctx, setModalState) => AlertDialog(
          title: const Text('파일 통째로 사전 번역 설정'),
          content: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              const Text('원문 언어를 선택하세요 (기본값: 일본어):', style: TextStyle(fontSize: 13)),
              const SizedBox(height: 8),
              DropdownButton<String>(
                isExpanded: true,
                value: _sourceLangCode,
                items: const [
                  DropdownMenuItem(value: 'ja', child: Text('일본어 (Japanese - 한자/히라가나/가타카나)')),
                  DropdownMenuItem(value: 'en', child: Text('영어 (English)')),
                  DropdownMenuItem(value: 'zh-cn', child: Text('중국어 (Chinese)')),
                ],
                onChanged: (val) {
                  if (val == null) return;
                  setModalState(() {
                    _sourceLangCode = val;
                    if (val == 'ja') {
                      _selectedScript = TextRecognitionScript.japanese;
                    } else if (val == 'zh-cn') {
                      _selectedScript = TextRecognitionScript.chinese;
                    } else {
                      _selectedScript = TextRecognitionScript.latin;
                    }
                  });
                },
              ),
              const SizedBox(height: 8),
              const Text(
                '• 모든 페이지(PDF/만화/이미지)의 말풍선을 미리 번역하여 캐싱하므로 페이지 넘김 딜레이가 0초입니다.',
                style: TextStyle(fontSize: 12, color: Colors.black54),
              ),
            ],
          ),
          actions: [
            TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text('취소')),
            ElevatedButton(
              onPressed: () => Navigator.pop(ctx, true),
              child: const Text('전체 사전 번역 시작'),
            ),
          ],
        ),
      ),
    );

    if (confirmed == true) {
      await _runWholeFileBatchTranslation();
    }
  }

  Future<void> _runWholeFileBatchTranslation() async {
    int current = 0;
    int total = _imagePages.length;
    String status = '말풍선 스캔 및 사전 번역 준비 중...';
    StateSetter? dialogSetState;

    showDialog(
      context: context,
      barrierDismissible: false,
      builder: (ctx) => StatefulBuilder(
        builder: (ctx, setDialogState) {
          dialogSetState = setDialogState;
          return AlertDialog(
            title: const Text('파일 통째로 사전 번역 중'),
            content: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                LinearProgressIndicator(value: total > 0 ? current / total : null),
                const SizedBox(height: 12),
                Text(status, style: const TextStyle(fontSize: 13)),
              ],
            ),
          );
        },
      ),
    );

    await BatchTranslationService.preTranslateAllImages(
      bookKey: _bookKey,
      imageFiles: _imagePages,
      targetLang: 'ko',
      sourceLang: _sourceLangCode,
      script: _selectedScript,
      onProgress: (c, t, s) {
        dialogSetState?.call(() {
          current = c;
          total = t;
          status = s;
        });
      },
    );

    for (int i = 0; i < _imagePages.length; i++) {
      final cached = await StorageService.getImageBubbleCache(_bookKey, i);
      if (cached != null) _bubblesByPage[i] = cached;
    }

    if (mounted) {
      Navigator.pop(context);
      setState(() => _showTranslatedBubbles = true);
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('전체 사전 번역 완료! 이제 딜레이 없이 읽을 수 있습니다.')),
      );
    }
  }

  Future<void> _showBookmarkSheet() async {
    final bookmarks = await StorageService.getBookmarks(_bookKey);
    if (!mounted) return;
    showModalBottomSheet(
      context: context,
      builder: (ctx) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            ListTile(
              title: const Text('북마크 목록', style: TextStyle(fontWeight: FontWeight.bold)),
              trailing: ElevatedButton.icon(
                icon: const Icon(Icons.bookmark_add, size: 18),
                label: const Text('현재 페이지 북마크 추가'),
                onPressed: () async {
                  final now = DateTime.now();
                  await StorageService.addBookmark(
                    _bookKey,
                    BookmarkItem(
                      id: now.millisecondsSinceEpoch.toString(),
                      label: '${_currentPage + 1}페이지 북마크',
                      position: _currentPage.toString(),
                      createdAt: '${now.month}/${now.day} ${now.hour}:${now.minute.toString().padLeft(2, '0')}',
                    ),
                  );
                  if (ctx.mounted) Navigator.pop(ctx);
                  _showBookmarkSheet();
                },
              ),
            ),
            const Divider(height: 1),
            if (bookmarks.isEmpty)
              const Padding(
                padding: EdgeInsets.all(24.0),
                child: Text('저장된 북마크가 없습니다.'),
              )
            else
              Flexible(
                child: ListView.builder(
                  shrinkWrap: true,
                  itemCount: bookmarks.length,
                  itemBuilder: (_, idx) {
                    final bm = bookmarks[idx];
                    return ListTile(
                      leading: const Icon(Icons.bookmark, color: Colors.amber),
                      title: Text(bm.label),
                      subtitle: Text('저장 시각: ${bm.createdAt}'),
                      trailing: IconButton(
                        icon: const Icon(Icons.delete_outline),
                        onPressed: () async {
                          await StorageService.removeBookmark(_bookKey, bm.id);
                          if (ctx.mounted) Navigator.pop(ctx);
                          _showBookmarkSheet();
                        },
                      ),
                      onTap: () {
                        Navigator.pop(ctx);
                        final target = int.tryParse(bm.position) ?? 0;
                        _goToPage(target, recordHistory: true);
                      },
                    );
                  },
                ),
              ),
          ],
        ),
      ),
    );
  }

  @override
  void dispose() {
    _readingTimer?.cancel();
    _volumeKeyService.stopListening();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    if (_isPreparingPages) {
      return const Scaffold(
        backgroundColor: Colors.black,
        body: Center(
          child: CircularProgressIndicator(color: Colors.amber),
        ),
      );
    }

    return Scaffold(
      backgroundColor: Colors.black,
      body: Stack(
        children: [
          Positioned.fill(
            child: GestureDetector(
              onTap: () => setState(() => _showControls = !_showControls),
              child: PageView.builder(
                controller: _pageController,
                reverse: _isMangaRtlMode,
                itemCount: _imagePages.length,
                onPageChanged: (idx) {
                  setState(() => _currentPage = idx);
                  StorageService.saveLastPosition(_bookKey, idx.toString());
                  StorageService.saveProgress(_bookKey, (idx + 1) / _totalPages);
                },
                itemBuilder: (context, index) {
                  final bubbles = _bubblesByPage[index] ?? [];
                  return LayoutBuilder(
                    builder: (context, constraints) {
                      return Stack(
                        fit: StackFit.expand,
                        children: [
                          Image.file(_imagePages[index], fit: BoxFit.contain),
                          if (_showTranslatedBubbles && bubbles.isNotEmpty)
                            ...bubbles.map((b) {
                              return Positioned(
                                left: b.leftRatio * constraints.maxWidth,
                                top: b.topRatio * constraints.maxHeight,
                                width: b.widthRatio * constraints.maxWidth,
                                height: b.heightRatio * constraints.maxHeight,
                                child: Container(
                                  padding: const EdgeInsets.all(4),
                                  decoration: BoxDecoration(
                                    color: Colors.white.withOpacity(0.95),
                                    borderRadius: BorderRadius.circular(12),
                                    border: Border.all(color: Colors.black87, width: 1.2),
                                    boxShadow: const [
                                      BoxShadow(color: Colors.black26, blurRadius: 3),
                                    ],
                                  ),
                                  alignment: Alignment.center,
                                  child: FittedBox(
                                    fit: BoxFit.scaleDown,
                                    child: ConstrainedBox(
                                      constraints: BoxConstraints(
                                        maxWidth: b.widthRatio * constraints.maxWidth,
                                      ),
                                      child: Text(
                                        b.translatedText,
                                        textAlign: TextAlign.center,
                                        style: TextStyle(
                                          color: Colors.black,
                                          fontWeight: FontWeight.w700,
                                          fontFamily: b.isSerif ? 'serif' : 'sans-serif',
                                          height: 1.25,
                                        ),
                                      ),
                                    ),
                                  ),
                                ),
                              );
                            }),
                        ],
                      );
                    },
                  );
                },
              ),
            ),
          ),

          // 최하단 상시 미니 상태줄 (읽은 시간 + 페이지 진행률)
          Positioned(
            left: 16,
            right: 16,
            bottom: 6,
            child: IgnorePointer(
              child: Row(
                mainAxisAlignment: MainAxisAlignment.spaceBetween,
                children: [
                  Text(
                    '읽은 시간: ${StorageService.formatReadingTime(_totalReadingSeconds)}',
                    style: const TextStyle(color: Colors.white70, fontSize: 11),
                  ),
                  Text(
                    '${_currentPage + 1} / $_totalPages 페이지',
                    style: const TextStyle(color: Colors.white70, fontSize: 11),
                  ),
                ],
              ),
            ),
          ),

          // 상단 컨트롤 바
          if (_showControls)
            Positioned(
              top: 0,
              left: 0,
              right: 0,
              child: Material(
                color: Colors.black87,
                child: SafeArea(
                  bottom: false,
                  child: Row(
                    children: [
                      IconButton(
                        icon: const Icon(Icons.arrow_back, color: Colors.white),
                        onPressed: () => Navigator.pop(context),
                      ),
                      Expanded(
                        child: Text(
                          widget.title,
                          style: const TextStyle(color: Colors.white, fontSize: 15),
                          overflow: TextOverflow.ellipsis,
                        ),
                      ),
                      if (_previousJumpPage != null)
                        IconButton(
                          icon: const Icon(Icons.restore, color: Colors.amber),
                          tooltip: '이전 페이지(${_previousJumpPage! + 1}p)로 돌아가기',
                          onPressed: () {
                            final target = _previousJumpPage!;
                            _previousJumpPage = null;
                            _goToPage(target, recordHistory: false);
                          },
                        ),
                      IconButton(
                        icon: Icon(
                          Icons.swap_horiz,
                          color: _isMangaRtlMode ? Colors.amber : Colors.white,
                        ),
                        tooltip: '일본 만화 제본 방향(우→좌 넘김) 전환',
                        onPressed: () {
                          setState(() => _isMangaRtlMode = !_isMangaRtlMode);
                        },
                      ),
                      IconButton(
                        icon: Icon(
                          _showTranslatedBubbles ? Icons.chat_bubble : Icons.translate,
                          color: _showTranslatedBubbles ? Colors.amber : Colors.white,
                        ),
                        tooltip: '파일 전체 말풍선 사전 번역 (PDF/JPG/PNG/CBZ 모두 지원)',
                        onPressed: () {
                          if (_bubblesByPage.isEmpty) {
                            _showLanguageAndTranslateDialog();
                          } else {
                            setState(() => _showTranslatedBubbles = !_showTranslatedBubbles);
                          }
                        },
                      ),
                      IconButton(
                        icon: const Icon(Icons.bookmarks_outlined, color: Colors.white),
                        tooltip: '북마크',
                        onPressed: _showBookmarkSheet,
                      ),
                    ],
                  ),
                ),
              ),
            ),

          if (_showControls && _totalPages > 1)
            Positioned(
              bottom: 24,
              left: 0,
              right: 0,
              child: Material(
                color: Colors.black87,
                child: Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
                  child: Row(
                    children: [
                      IconButton(
                        icon: const Icon(Icons.chevron_left, color: Colors.white),
                        onPressed: () => _goToPage(_currentPage - 1),
                      ),
                      Expanded(
                        child: Slider(
                          value: _currentPage.toDouble().clamp(0, (_totalPages - 1).toDouble()),
                          min: 0,
                          max: (_totalPages - 1).toDouble(),
                          onChanged: (v) => _goToPage(v.round()),
                        ),
                      ),
                      IconButton(
                        icon: const Icon(Icons.chevron_right, color: Colors.white),
                        onPressed: () => _goToPage(_currentPage + 1),
                      ),
                    ],
                  ),
                ),
              ),
            ),
        ],
      ),
    );
  }
}
