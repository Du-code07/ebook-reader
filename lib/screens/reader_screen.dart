import 'dart:async';
import 'dart:io';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_epub_viewer/flutter_epub_viewer.dart';
import '../services/batch_translation_service.dart';
import '../services/storage_service.dart';
import '../services/volume_key_service.dart';

class ReaderScreen extends StatefulWidget {
  final String filePath;
  final String bookTitle;

  const ReaderScreen({
    super.key,
    required this.filePath,
    required this.bookTitle,
  });

  @override
  State<ReaderScreen> createState() => _ReaderScreenState();
}

class _ReaderScreenState extends State<ReaderScreen> with WidgetsBindingObserver {
  final GlobalKey<ScaffoldState> _scaffoldKey = GlobalKey<ScaffoldState>();
  final EpubController _epubController = EpubController();
  final VolumeKeyService _volumeKeyService = VolumeKeyService();

  late String _activeFilePath;
  bool _isTranslatedFileActive = false;

  String? _initialCfi;
  String? _currentCfi;
  String? _previousJumpCfi; // 읽었던 페이지로 돌아가기용 이전 CFI 저장
  String? _selectedCfiRange;
  bool _isLoading = true;
  bool _isDarkMode = false;
  bool _useVolumeKeys = true;
  int _fontSize = 18;
  List<EpubChapter> _chapters = [];

  bool _showControls = true;
  double _progress = 0.0;
  String _currentTimeString = '';
  int _totalReadingSeconds = 0;
  Timer? _clockAndReadingTimer;

  Offset? _pointerDownPosition;
  DateTime? _pointerDownTime;

  @override
  void initState() {
    super.initState();
    _activeFilePath = widget.filePath;
    WidgetsBinding.instance.addObserver(this);
    _updateClock();
    _initReader();

    // 1초마다 누적 독서 시간 기록 및 시계 갱신
    _clockAndReadingTimer = Timer.periodic(const Duration(seconds: 1), (_) {
      if (mounted) {
        setState(() => _totalReadingSeconds++);
        if (_totalReadingSeconds % 5 == 0) {
          StorageService.addReadingSeconds(widget.filePath, 5);
        }
        if (_totalReadingSeconds % 15 == 0) {
          _updateClock();
        }
      }
    });
  }

  void _updateClock() {
    final now = DateTime.now();
    final hh = now.hour.toString().padLeft(2, '0');
    final mm = now.minute.toString().padLeft(2, '0');
    if (mounted) {
      setState(() => _currentTimeString = '$hh:$mm');
    }
  }

  Future<void> _initReader() async {
    final savedCfi = await StorageService.getLastPosition(widget.filePath);
    final prevCfi = await StorageService.getPreviousPosition(widget.filePath);
    final savedProg = await StorageService.getProgress(widget.filePath);
    final savedTime = await StorageService.getReadingSeconds(widget.filePath);

    if (_useVolumeKeys) {
      _enableVolumeNavigation();
    }
    setState(() {
      _initialCfi = savedCfi;
      _currentCfi = savedCfi;
      _previousJumpCfi = prevCfi;
      _progress = savedProg.clamp(0.0, 1.0);
      _totalReadingSeconds = savedTime;
      _isLoading = false;
    });
  }

  void _enableVolumeNavigation() {
    _volumeKeyService.startListening(
      onVolumeUp: () => _epubController.prev(),
      onVolumeDown: () => _epubController.next(),
    );
  }

  // 파일 통째로 사전 번역 실행 (번역 딜레이 제거 + 원본 글꼴 스타일 유지 말풍선 박스)
  Future<void> _handleBatchTranslateBook() async {
    if (_isTranslatedFileActive) {
      // 원본으로 즉시 전환
      setState(() {
        _isLoading = true;
        _activeFilePath = widget.filePath;
        _isTranslatedFileActive = false;
        _initialCfi = _currentCfi;
      });
      await Future.delayed(const Duration(milliseconds: 100));
      setState(() => _isLoading = false);
      return;
    }

    int cur = 0;
    int tot = 1;
    String status = '책 전체를 스캔하여 사전 번역 파일을 생성합니다...';
    StateSetter? dialogSetState;

    showDialog(
      context: context,
      barrierDismissible: false,
      builder: (ctx) => StatefulBuilder(
        builder: (ctx, setDialogState) {
          dialogSetState = setDialogState;
          return AlertDialog(
            title: const Text('책 전체 사전 번역 (딜레이 0초)'),
            content: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                LinearProgressIndicator(value: tot > 0 ? cur / tot : null),
                const SizedBox(height: 12),
                Text(status, style: const TextStyle(fontSize: 13)),
              ],
            ),
          );
        },
      ),
    );

    try {
      final translatedFile = await BatchTranslationService.preTranslateWholeEpub(
        sourceEpub: File(widget.filePath),
        targetLang: 'ko',
        onProgress: (c, t, s) {
          dialogSetState?.call(() {
            cur = c;
            tot = t;
            status = s;
          });
        },
      );

      if (!mounted) return;
      Navigator.pop(context);

      setState(() {
        _isLoading = true;
        _activeFilePath = translatedFile.path;
        _isTranslatedFileActive = true;
        _initialCfi = _currentCfi;
      });
      await Future.delayed(const Duration(milliseconds: 100));
      setState(() => _isLoading = false);

      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('책 전체 번역 완료! 이제 페이지를 넘길 때 번역 딜레이가 전혀 발생하지 않습니다.')),
      );
    } catch (e) {
      if (mounted) Navigator.pop(context);
    }
  }

  // 북마크 바텀시트 (추가/삭제/즉시 이동)
  Future<void> _openBookmarkSheet() async {
    final bookmarks = await StorageService.getBookmarks(widget.filePath);
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
                label: const Text('현재 페이지 북마크'),
                onPressed: () async {
                  if (_currentCfi == null) return;
                  final now = DateTime.now();
                  await StorageService.addBookmark(
                    widget.filePath,
                    BookmarkItem(
                      id: now.millisecondsSinceEpoch.toString(),
                      label: '진행률 ${(_progress * 100).toStringAsFixed(1)}% 지점',
                      position: _currentCfi!,
                      createdAt: '${now.month}/${now.day} ${now.hour}:${now.minute.toString().padLeft(2, '0')}',
                    ),
                  );
                  if (ctx.mounted) Navigator.pop(ctx);
                  _openBookmarkSheet();
                },
              ),
            ),
            const Divider(height: 1),
            if (bookmarks.isEmpty)
              const Padding(
                padding: EdgeInsets.all(24.0),
                child: Text('저장된 북마크가 없습니다. 우측 상단 버튼으로 추가해 보세요.'),
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
                          await StorageService.removeBookmark(widget.filePath, bm.id);
                          if (ctx.mounted) Navigator.pop(ctx);
                          _openBookmarkSheet();
                        },
                      ),
                      onTap: () {
                        Navigator.pop(ctx);
                        if (_currentCfi != null) {
                          setState(() => _previousJumpCfi = _currentCfi);
                        }
                        _epubController.display(cfi: bm.position);
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

  void _toggleControls() {
    setState(() => _showControls = !_showControls);
    if (_showControls) {
      SystemChrome.setEnabledSystemUIMode(SystemUiMode.edgeToEdge);
    } else {
      SystemChrome.setEnabledSystemUIMode(SystemUiMode.immersiveSticky);
    }
  }

  void _handlePointerDown(PointerDownEvent event) {
    _pointerDownPosition = event.position;
    _pointerDownTime = DateTime.now();
  }

  void _handlePointerUp(PointerUpEvent event, Size screenSize) {
    if (_pointerDownPosition == null || _pointerDownTime == null) return;
    final distance = (event.position - _pointerDownPosition!).distance;
    final duration = DateTime.now().difference(_pointerDownTime!).inMilliseconds;

    if (distance < 15.0 && duration < 250) {
      final dx = event.position.dx;
      if (dx > screenSize.width * 0.2 && dx < screenSize.width * 0.8) {
        _toggleControls();
      } else if (dx <= screenSize.width * 0.2) {
        _epubController.prev();
      } else {
        _epubController.next();
      }
    }
    _pointerDownPosition = null;
    _pointerDownTime = null;
  }

  EpubTheme _buildTheme() {
    return EpubTheme.custom(
      backgroundDecoration: BoxDecoration(
        color: _isDarkMode ? const Color(0xFF1E1E1E) : const Color(0xFFFBF0D9),
      ),
      foregroundColor: _isDarkMode ? const Color(0xFFD4D4D4) : const Color(0xFF3B2F2F),
      customCss: {
        'body, p': {
          'word-break': 'keep-all',
          'line-height': '1.75',
          'text-align': 'justify',
        },
        '::selection': {
          'background': 'rgba(255, 215, 0, 0.35)',
        },
      },
    );
  }

  void _toggleTheme() {
    setState(() => _isDarkMode = !_isDarkMode);
    _epubController.updateTheme(theme: _buildTheme());
  }

  void _changeFontSize(int delta) {
    setState(() => _fontSize = (_fontSize + delta).clamp(12, 32));
    _epubController.setFontSize(fontSize: _fontSize.toDouble());
  }

  @override
  void dispose() {
    _clockAndReadingTimer?.cancel();
    WidgetsBinding.instance.removeObserver(this);
    _volumeKeyService.stopListening();
    SystemChrome.setEnabledSystemUIMode(
      SystemUiMode.manual,
      overlays: SystemUiOverlay.values,
    );
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    if (_isLoading) {
      return const Scaffold(body: Center(child: CircularProgressIndicator()));
    }

    final mediaQuery = MediaQuery.of(context);
    final screenSize = mediaQuery.size;
    final topPadding = mediaQuery.viewPadding.top;
    final bottomPadding = mediaQuery.viewPadding.bottom;
    final bgColor = _isDarkMode ? const Color(0xFF1E1E1E) : const Color(0xFFFBF0D9);
    final barColor = _isDarkMode
        ? const Color(0xFF2C2C2C).withOpacity(0.96)
        : Colors.white.withOpacity(0.96);
    final iconColor = _isDarkMode ? Colors.white : Colors.black87;
    final footerTextColor = _isDarkMode ? Colors.white54 : Colors.black54;

    return Scaffold(
      key: _scaffoldKey,
      backgroundColor: bgColor,
      drawer: Drawer(
        child: SafeArea(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              const Padding(
                padding: EdgeInsets.all(16.0),
                child: Text('목차', style: TextStyle(fontSize: 18, fontWeight: FontWeight.bold)),
              ),
              const Divider(height: 1),
              Expanded(
                child: ListView.builder(
                  itemCount: _chapters.length,
                  itemBuilder: (context, index) {
                    final chapter = _chapters[index];
                    return ListTile(
                      title: Text(chapter.title.trim()),
                      onTap: () {
                        Navigator.pop(context);
                        if (_currentCfi != null) {
                          setState(() => _previousJumpCfi = _currentCfi);
                        }
                        _epubController.display(cfi: chapter.href);
                        if (_showControls) _toggleControls();
                      },
                    );
                  },
                ),
              ),
            ],
          ),
        ),
      ),
      body: Stack(
        children: [
          // 1. EPUB 뷰어 본문
          Positioned.fill(
            child: Padding(
              padding: EdgeInsets.only(
                top: topPadding > 0 ? topPadding : 24.0,
                bottom: (bottomPadding > 0 ? bottomPadding : 8.0) + 24.0,
              ),
              child: Listener(
                behavior: HitTestBehavior.translucent,
                onPointerDown: _handlePointerDown,
                onPointerUp: (event) => _handlePointerUp(event, screenSize),
                child: EpubViewer(
                  key: ValueKey(_activeFilePath),
                  epubController: _epubController,
                  epubSource: EpubSource.fromFile(File(_activeFilePath)),
                  initialCfi: _initialCfi,
                  displaySettings: EpubDisplaySettings(
                    flow: EpubFlow.paginated,
                    snap: true,
                    fontSize: _fontSize,
                    theme: _buildTheme(),
                  ),
                  selectionContextMenu: EpubContextMenu(
                    hideDefaultSystemItems: false,
                    items: [
                      EpubContextMenuItem(
                        id: 1,
                        title: '형광펜 칠하기',
                        action: () {
                          if (_selectedCfiRange != null) {
                            _epubController.addHighlight(
                              cfi: _selectedCfiRange!,
                              color: Colors.amber,
                            );
                          }
                        },
                      ),
                    ],
                  ),
                  onChaptersLoaded: (chapters) {
                    setState(() => _chapters = chapters);
                  },
                  onTextSelected: (epubTextSelection) {
                    _selectedCfiRange = epubTextSelection.selectionCfi;
                  },
                  onRelocated: (value) {
                    _currentCfi = value.startCfi;
                    StorageService.saveLastPosition(widget.filePath, value.startCfi);
                    StorageService.saveProgress(widget.filePath, value.progress);
                    if (mounted) {
                      setState(() {
                        _progress = value.progress.clamp(0.0, 1.0);
                      });
                    }
                  },
                ),
              ),
            ),
          ),

          // 2. 최하단 미니 상태줄 (읽은 시간 + 현재 시각 + 진행률 상시 표시)
          Positioned(
            left: 16,
            right: 16,
            bottom: bottomPadding > 0 ? bottomPadding / 2 : 4,
            height: 22,
            child: IgnorePointer(
              child: Row(
                mainAxisAlignment: MainAxisAlignment.spaceBetween,
                children: [
                  Expanded(
                    child: Text(
                      '읽은 시간: ${StorageService.formatReadingTime(_totalReadingSeconds)}',
                      style: TextStyle(fontSize: 11, color: footerTextColor),
                      overflow: TextOverflow.ellipsis,
                    ),
                  ),
                  Text(
                    '$_currentTimeString  |  ${(_progress * 100).toStringAsFixed(1)}%',
                    style: TextStyle(
                      fontSize: 11,
                      fontWeight: FontWeight.w500,
                      color: footerTextColor,
                    ),
                  ),
                ],
              ),
            ),
          ),

          // 3. 상단 오버레이 AppBar (통째로 번역, 북마크, 이전 읽던 위치 복귀 버튼 포함)
          AnimatedPositioned(
            duration: const Duration(milliseconds: 250),
            curve: Curves.easeInOut,
            top: _showControls ? 0 : -(kToolbarHeight + topPadding + 10),
            left: 0,
            right: 0,
            child: AnimatedOpacity(
              duration: const Duration(milliseconds: 200),
              opacity: _showControls ? 1.0 : 0.0,
              child: Material(
                elevation: 4,
                color: barColor,
                child: Padding(
                  padding: EdgeInsets.only(top: topPadding),
                  child: SizedBox(
                    height: kToolbarHeight,
                    child: Row(
                      children: [
                        IconButton(
                          icon: Icon(Icons.arrow_back, color: iconColor),
                          onPressed: () => Navigator.pop(context),
                        ),
                        IconButton(
                          icon: Icon(Icons.list, color: iconColor),
                          onPressed: () => _scaffoldKey.currentState?.openDrawer(),
                        ),
                        Expanded(
                          child: Text(
                            widget.bookTitle,
                            style: TextStyle(
                              fontSize: 15,
                              fontWeight: FontWeight.w600,
                              color: iconColor,
                            ),
                            overflow: TextOverflow.ellipsis,
                          ),
                        ),
                        // 읽었던 페이지로 돌아가기 버튼
                        if (_previousJumpCfi != null)
                          IconButton(
                            icon: const Icon(Icons.restore, color: Colors.indigo),
                            tooltip: '이전에 읽던 페이지로 돌아가기',
                            onPressed: () {
                              final target = _previousJumpCfi!;
                              setState(() => _previousJumpCfi = _currentCfi);
                              _epubController.display(cfi: target);
                            },
                          ),
                        // 파일 통째로 사전 번역 버튼
                        IconButton(
                          icon: Icon(
                            Icons.translate,
                            color: _isTranslatedFileActive ? Colors.amber[800] : iconColor,
                          ),
                          tooltip: '책 통째로 번역 (말풍선 스타일/딜레이 제거)',
                          onPressed: _handleBatchTranslateBook,
                        ),
                        // 북마크 버튼
                        IconButton(
                          icon: Icon(Icons.bookmarks_outlined, color: iconColor),
                          tooltip: '북마크 목록 및 추가',
                          onPressed: _openBookmarkSheet,
                        ),
                        IconButton(
                          icon: Icon(
                            _isDarkMode ? Icons.light_mode : Icons.dark_mode,
                            color: iconColor,
                          ),
                          onPressed: _toggleTheme,
                        ),
                      ],
                    ),
                  ),
                ),
              ),
            ),
          ),

          // 4. 하단 오버레이 컨트롤 바
          AnimatedPositioned(
            duration: const Duration(milliseconds: 250),
            curve: Curves.easeInOut,
            bottom: _showControls ? 0 : -(116 + bottomPadding + 10),
            left: 0,
            right: 0,
            child: AnimatedOpacity(
              duration: const Duration(milliseconds: 200),
              opacity: _showControls ? 1.0 : 0.0,
              child: Material(
                elevation: 8,
                color: barColor,
                child: Padding(
                  padding: EdgeInsets.only(bottom: bottomPadding, left: 12, right: 12, top: 8),
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Row(
                        children: [
                          Text('진행률', style: TextStyle(fontSize: 12, color: iconColor)),
                          Expanded(
                            child: Slider(
                              value: _progress.clamp(0.0, 1.0),
                              min: 0.0,
                              max: 1.0,
                              onChanged: (val) => setState(() => _progress = val),
                              onChangeEnd: (val) {
                                if (_currentCfi != null) {
                                  setState(() => _previousJumpCfi = _currentCfi);
                                }
                                _epubController.toProgressPercentage(val);
                              },
                            ),
                          ),
                          SizedBox(
                            width: 48,
                            child: Text(
                              '${(_progress * 100).toStringAsFixed(1)}%',
                              textAlign: TextAlign.right,
                              style: TextStyle(
                                fontSize: 12,
                                fontWeight: FontWeight.bold,
                                color: iconColor,
                              ),
                            ),
                          ),
                        ],
                      ),
                      SizedBox(
                        height: 48,
                        child: Row(
                          mainAxisAlignment: MainAxisAlignment.spaceEvenly,
                          children: [
                            IconButton(
                              icon: Icon(Icons.chevron_left, color: iconColor),
                              onPressed: () => _epubController.prev(),
                            ),
                            IconButton(
                              icon: Icon(Icons.text_decrease, color: iconColor),
                              onPressed: () => _changeFontSize(-2),
                            ),
                            Text(
                              '${_fontSize}pt',
                              style: TextStyle(fontWeight: FontWeight.bold, color: iconColor),
                            ),
                            IconButton(
                              icon: Icon(Icons.text_increase, color: iconColor),
                              onPressed: () => _changeFontSize(2),
                            ),
                            IconButton(
                              icon: Icon(Icons.chevron_right, color: iconColor),
                              onPressed: () => _epubController.next(),
                            ),
                          ],
                        ),
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
