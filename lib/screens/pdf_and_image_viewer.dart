import 'dart:async';
import 'dart:io';
import 'dart:math' as math;
import 'dart:ui' as ui;
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
  static const MethodChannel _sumiChannel = MethodChannel('ebook_reader/sumi_launcher');
  final PageController _pageController = PageController();
  final VolumeKeyService _volumeKeyService = VolumeKeyService();

  List<File> _imagePages = [];
  final Map<int, Size> _pageImageSizes = {};
  bool _isPreparingPages = true;
  int _currentPage = 0;
  int _totalPages = 1;
  int? _previousJumpPage;
  bool _showControls = true;
  bool _showTranslatedBubbles = false;
  bool _isMangaRtlMode = false;
  TextRecognitionScript _selectedScript = TextRecognitionScript.japanese;
  String _sourceLangCode = 'ja';
  final Map<int, List<BubbleTranslation>> _bubblesByPage = {};

  int _totalReadingSeconds = 0;
  Timer? _readingTimer;

  String get _bookKey => widget.files.first.path;

  @override
  void initState() {
    super.initState();
    _initMedia();
  }

  Future<Size> _getImageDimension(File file) async {
    try {
      final bytes = await file.readAsBytes();
      final codec = await ui.instantiateImageCodec(bytes);
      final frame = await codec.getNextFrame();
      return Size(frame.image.width.toDouble(), frame.image.height.toDouble());
    } catch (_) {
      return const Size(1000, 1400);
    }
  }

  Future<void> _ensurePageDimensionLoaded(int index) async {
    if (_pageImageSizes.containsKey(index) || index < 0 || index >= _imagePages.length) return;
    final sz = await _getImageDimension(_imagePages[index]);
    if (mounted) {
      setState(() {
        _pageImageSizes[index] = sz;
      });
    }
  }

  Future<void> _initMedia() async {
    _totalReadingSeconds = await StorageService.getReadingSeconds(_bookKey);
    final tempDir = await getTemporaryDirectory();
    final first = widget.files.first;
    final lower = first.path.toLowerCase();

    if (widget.isPdf || lower.endsWith('.pdf')) {
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

    if (_imagePages.isNotEmpty) {
      _pageImageSizes[_currentPage] = await _getImageDimension(_imagePages[_currentPage]);
      if (_currentPage + 1 < _imagePages.length) {
        _ensurePageDimensionLoaded(_currentPage + 1);
      }
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

    // 음량 버튼으로 넘길 때 손으로 밀어 넘기는 것처럼 부드러운 슬라이드 애니메이션 적용
    _volumeKeyService.startListening(
      onVolumeUp: () => _goToPage(_currentPage - 1, smoothAnimation: true),
      onVolumeDown: () => _goToPage(_currentPage + 1, smoothAnimation: true),
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

  void _goToPage(int page, {bool recordHistory = true, bool smoothAnimation = true}) {
    if (page < 0 || page >= _totalPages) return;
    if (recordHistory && (page - _currentPage).abs() > 1) {
      _previousJumpPage = _currentPage;
    }
    setState(() => _currentPage = page);
    _ensurePageDimensionLoaded(page);
    if (page + 1 < _totalPages) _ensurePageDimensionLoaded(page + 1);

    StorageService.saveLastPosition(_bookKey, page.toString());
    if (_totalPages > 0) {
      StorageService.saveProgress(_bookKey, (page + 1) / _totalPages);
    }

    if (_pageController.hasClients) {
      if (smoothAnimation && (page - _currentPage).abs() <= 2) {
        _pageController.animateToPage(
          page,
          duration: const Duration(milliseconds: 300),
          curve: Curves.easeOutCubic,
        );
      } else {
        _pageController.jumpToPage(page);
      }
    }
  }

  Future<void> _showLanguageAndTranslateDialog({bool forceRetranslate = false}) async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (ctx) => StatefulBuilder(
        builder: (ctx, setModalState) => AlertDialog(
          title: const Text('만화/문서 말풍선 번역 설정'),
          content: SingleChildScrollView(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                const Text('원문 언어를 선택하세요 (기본값: 일본어):', style: TextStyle(fontSize: 13)),
                const SizedBox(height: 8),
                DropdownButton<String>(
                  isExpanded: true,
                  value: _sourceLangCode,
                  items: const [
                    DropdownMenuItem(value: 'ja', child: Text('일본어 (세로쓰기 말풍선 통합 인식)')),
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
                  '• 낱글자가 아닌 말풍선 전체 문장을 하나로 묶어 번역하고, 원본 대사 자리에 만화책 서체로 자연스럽게 덮어씌웁니다.',
                  style: TextStyle(fontSize: 12, color: Colors.black54),
                ),
              ],
            ),
          ),
          actions: [
            TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text('취소')),
            OutlinedButton.icon(
              icon: const Icon(Icons.open_in_new, size: 16),
              label: const Text('Sumi 앱/웹 열기'),
              onPressed: () async {
                Navigator.pop(ctx, false);
                await _sumiChannel.invokeMethod('openSumiApp', {'fallback': 'web'});
              },
            ),
            ElevatedButton(
              onPressed: () => Navigator.pop(ctx, true),
              child: const Text('앱 내 말풍선 통합 번역'),
            ),
          ],
        ),
      ),
    );

    if (confirmed == true) {
      await _runWholeFileBatchTranslation(forceRetranslate: forceRetranslate);
    }
  }

  Future<void> _runWholeFileBatchTranslation({bool forceRetranslate = false}) async {
    int current = 0;
    int total = _imagePages.length;
    String status = '말풍선 영역 통합 스캔 및 번역 준비 중...';
    StateSetter? dialogSetState;

    showDialog(
      context: context,
      barrierDismissible: false,
      builder: (ctx) => StatefulBuilder(
        builder: (ctx, setDialogState) {
          dialogSetState = setDialogState;
          return AlertDialog(
            title: const Text('말풍선 통째로 사전 번역 중'),
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
      forceRetranslate: forceRetranslate,
      onProgress: (c, t, s) {
        dialogSetState?.call(() {
          current = c;
          total = t;
          status = s;
        });
      },
    );

    _bubblesByPage.clear();
    for (int i = 0; i < _imagePages.length; i++) {
      final cached = await StorageService.getImageBubbleCache(_bookKey, i);
      if (cached != null) _bubblesByPage[i] = cached;
    }

    if (mounted) {
      Navigator.pop(context);
      setState(() => _showTranslatedBubbles = true);
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('말풍선 통합 번역 완료! (번역 아이콘을 길게 누르면 다시 번역할 수 있습니다)')),
      );
    }
  }

  /// 말풍선 크기에 맞춰 가장 읽기 좋은 글자 크기를 자동 계산 (세로줄 찌그러짐 방지)
  double _computeOptimalFontSize(String text, double boxW, double boxH) {
    if (text.isEmpty || boxW <= 0 || boxH <= 0) return 12.0;
    final area = boxW * boxH;
    final est = math.sqrt(area / (text.length * 1.45));
    return est.clamp(9.5, 22.0);
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
                        _goToPage(target, recordHistory: true, smoothAnimation: false);
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

    final mediaQuery = MediaQuery.of(context);
    final bottomInset = mediaQuery.viewPadding.bottom;

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
                physics: const BouncingScrollPhysics(),
                itemCount: _imagePages.length,
                onPageChanged: (idx) {
                  setState(() => _currentPage = idx);
                  _ensurePageDimensionLoaded(idx);
                  if (idx + 1 < _totalPages) _ensurePageDimensionLoaded(idx + 1);
                  StorageService.saveLastPosition(_bookKey, idx.toString());
                  StorageService.saveProgress(_bookKey, (idx + 1) / _totalPages);
                },
                itemBuilder: (context, index) {
                  final bubbles = _bubblesByPage[index] ?? [];
                  final imgSize = _pageImageSizes[index];

                  return LayoutBuilder(
                    builder: (context, constraints) {
                      // 태블릿 및 다양한 화면 비율에서 이미지가 실제로 그려지는 영역(Rect)을 정확히 계산하여 UI 잘림 및 말풍선 위치 어긋남 완벽 해결!
                      double drawLeft = 0;
                      double drawTop = 0;
                      double drawWidth = constraints.maxWidth;
                      double drawHeight = constraints.maxHeight;

                      if (imgSize != null && imgSize.width > 0 && imgSize.height > 0) {
                        final fitted = applyBoxFit(BoxFit.contain, imgSize, constraints.biggest);
                        drawWidth = fitted.destination.width;
                        drawHeight = fitted.destination.height;
                        drawLeft = (constraints.maxWidth - drawWidth) / 2.0;
                        drawTop = (constraints.maxHeight - drawHeight) / 2.0;
                      } else {
                        _ensurePageDimensionLoaded(index);
                      }

                      return InteractiveViewer(
                        minScale: 1.0,
                        maxScale: 3.5,
                        child: Stack(
                          fit: StackFit.expand,
                          children: [
                            Image.file(
                              _imagePages[index],
                              fit: BoxFit.contain,
                              width: constraints.maxWidth,
                              height: constraints.maxHeight,
                            ),
                            if (_showTranslatedBubbles && bubbles.isNotEmpty)
                              ...bubbles.map((b) {
                                final rawW = b.widthRatio * drawWidth;
                                final rawH = b.heightRatio * drawHeight;
                                // 세로로 좁은 일본어 대사 영역이라도 한국어 가로 문장이 자연스럽게 들어가도록 최소 가로 폭 보정
                                final minReadableW = math.max(rawW, math.min(drawWidth * 0.42, rawH * 0.82));
                                final centerX = drawLeft + (b.leftRatio + b.widthRatio / 2.0) * drawWidth;
                                final boxW = minReadableW.clamp(44.0, drawWidth * 0.92);
                                final boxH = rawH.clamp(28.0, drawHeight * 0.92);
                                final boxLeft = (centerX - boxW / 2.0).clamp(
                                  drawLeft,
                                  math.max(drawLeft, drawLeft + drawWidth - boxW),
                                );
                                final boxTop = (drawTop + b.topRatio * drawHeight).clamp(
                                  drawTop,
                                  math.max(drawTop, drawTop + drawHeight - boxH),
                                );

                                final fontSize = _computeOptimalFontSize(b.translatedText, boxW - 8, boxH - 6);

                                return Positioned(
                                  left: boxLeft,
                                  top: boxTop,
                                  width: boxW,
                                  height: boxH,
                                  child: Container(
                                    padding: const EdgeInsets.symmetric(horizontal: 5, vertical: 3),
                                    decoration: BoxDecoration(
                                      // 테두리 선을 없애고 원본 말풍선 내부를 깨끗한 흰색으로 덮어 실제 식자(Typesetting)처럼 표현
                                      color: Colors.white,
                                      borderRadius: BorderRadius.circular(boxW * 0.18),
                                    ),
                                    alignment: Alignment.center,
                                    child: Center(
                                      child: Text(
                                        b.translatedText,
                                        textAlign: TextAlign.center,
                                        softWrap: true,
                                        style: TextStyle(
                                          color: const Color(0xFF141414),
                                          fontSize: fontSize,
                                          fontWeight: b.isBold ? FontWeight.w800 : FontWeight.w600,
                                          fontFamily: b.isSerif ? 'serif' : 'sans-serif',
                                          height: 1.22,
                                          letterSpacing: -0.3,
                                        ),
                                      ),
                                    ),
                                  ),
                                );
                              }),
                          ],
                        ),
                      );
                    },
                  );
                },
              ),
            ),
          ),

          // 최하단 상시 미니 상태줄 (태블릿 하단 네비게이션 바 잘림 방지 SafeArea 반영)
          Positioned(
            left: 20,
            right: 20,
            bottom: math.max(bottomInset + 4, 8),
            child: IgnorePointer(
              child: Row(
                mainAxisAlignment: MainAxisAlignment.spaceBetween,
                children: [
                  Text(
                    '읽은 시간: ${StorageService.formatReadingTime(_totalReadingSeconds)}',
                    style: const TextStyle(
                      color: Colors.white70,
                      fontSize: 12,
                      shadows: [Shadow(color: Colors.black, blurRadius: 4)],
                    ),
                  ),
                  Text(
                    '${_currentPage + 1} / $_totalPages 페이지',
                    style: const TextStyle(
                      color: Colors.white70,
                      fontSize: 12,
                      shadows: [Shadow(color: Colors.black, blurRadius: 4)],
                    ),
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
                  child: Padding(
                    padding: const EdgeInsets.symmetric(horizontal: 4),
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
                              _goToPage(target, recordHistory: false, smoothAnimation: true);
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
                            ScaffoldMessenger.of(context).showSnackBar(
                              SnackBar(
                                content: Text(_isMangaRtlMode
                                    ? '일본 만화책 넘김 방향 (오른쪽 → 왼쪽) 적용됨'
                                    : '일반 넘김 방향 (왼쪽 → 오른쪽) 적용됨'),
                                duration: const Duration(seconds: 1),
                              ),
                            );
                          },
                        ),
                        GestureDetector(
                          onLongPress: () => _showLanguageAndTranslateDialog(forceRetranslate: true),
                          child: IconButton(
                            icon: Icon(
                              _showTranslatedBubbles ? Icons.chat_bubble : Icons.translate,
                              color: _showTranslatedBubbles ? Colors.amber : Colors.white,
                            ),
                            tooltip: '말풍선 번역 켜기/끄기 (길게 누르면 다시 번역)',
                            onPressed: () {
                              if (_bubblesByPage.isEmpty) {
                                _showLanguageAndTranslateDialog(forceRetranslate: false);
                              } else {
                                setState(() => _showTranslatedBubbles = !_showTranslatedBubbles);
                              }
                            },
                          ),
                        ),
                        if (_bubblesByPage.isNotEmpty)
                          IconButton(
                            icon: const Icon(Icons.refresh, color: Colors.white70, size: 20),
                            tooltip: '말풍선 다시 번역하기',
                            onPressed: () => _showLanguageAndTranslateDialog(forceRetranslate: true),
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
            ),

          if (_showControls && _totalPages > 1)
            Positioned(
              bottom: math.max(bottomInset + 26, 28),
              left: 0,
              right: 0,
              child: Material(
                color: Colors.black87,
                child: SafeArea(
                  top: false,
                  bottom: false,
                  child: Padding(
                    padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 6),
                    child: Row(
                      children: [
                        IconButton(
                          icon: const Icon(Icons.chevron_left, color: Colors.white),
                          onPressed: () => _goToPage(_currentPage - 1, smoothAnimation: true),
                        ),
                        Expanded(
                          child: Slider(
                            value: _currentPage.toDouble().clamp(0, (_totalPages - 1).toDouble()),
                            min: 0,
                            max: (_totalPages - 1).toDouble(),
                            onChanged: (v) => _goToPage(v.round(), smoothAnimation: false),
                          ),
                        ),
                        IconButton(
                          icon: const Icon(Icons.chevron_right, color: Colors.white),
                          onPressed: () => _goToPage(_currentPage + 1, smoothAnimation: true),
                        ),
                      ],
                    ),
                  ),
                ),
              ),
            ),
        ],
      ),
    );
  }
}
