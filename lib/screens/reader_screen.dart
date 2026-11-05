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
  String? _previousJumpCfi;
  String? _selectedCfiRange;
  bool _isLoading = true;
  bool _isDarkMode = false;
  bool _useVolumeKeys = true;
  bool _enableTwoPageInLandscape = true;
  int _fontSize = 18;
  List<EpubChapter> _chapters = [];

  bool _showControls = false;
  double _progress = 0.0;
  bool _hasRestoredInitialPosition = false;

  Offset? _pointerDownPosition;
  DateTime? _pointerDownTime;

  @override
  void initState() {
    super.initState();
    _activeFilePath = widget.filePath;
    WidgetsBinding.instance.addObserver(this);
    SystemChrome.setEnabledSystemUIMode(SystemUiMode.immersiveSticky);
    _initReader();
  }

  Future<void> _initReader() async {
    final savedCfi = await StorageService.getLastPosition(widget.filePath);
    final prevCfi = await StorageService.getPreviousPosition(widget.filePath);
    final savedProg = await StorageService.getProgress(widget.filePath);
    final twoPage = await StorageService.getTwoPageLandscape();
    final isDark = await StorageService.getDarkMode();

    if (_useVolumeKeys) {
      _enableVolumeNavigation();
    }
    setState(() {
      _initialCfi = savedCfi;
      _currentCfi = savedCfi;
      _previousJumpCfi = prevCfi;
      _progress = savedProg.clamp(0.0, 1.0).toDouble();
      _enableTwoPageInLandscape = twoPage;
      _isDarkMode = isDark;
      _isLoading = false;
    });
  }

  void _enableVolumeNavigation() {
    _volumeKeyService.startListening(
      onVolumeUp: () => _epubController.prev(),
      onVolumeDown: () => _epubController.next(),
    );
  }

  Future<void> _handleBatchTranslateBook() async {
    if (_isTranslatedFileActive) {
      setState(() {
        _isLoading = true;
        _activeFilePath = widget.filePath;
        _isTranslatedFileActive = false;
        _initialCfi = _currentCfi;
        _hasRestoredInitialPosition = false;
      });
      await Future.delayed(const Duration(milliseconds: 100));
      setState(() => _isLoading = false);
      return;
    }

    int cur = 0;
    int tot = 1;
    String status = '사전 번역 중...';
    StateSetter? dialogSetState;

    showDialog(
      context: context,
      barrierDismissible: false,
      builder: (ctx) => StatefulBuilder(
        builder: (ctx, setDialogState) {
          dialogSetState = setDialogState;
          return AlertDialog(
            title: const Text('사전 번역 중'),
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
        _hasRestoredInitialPosition = false;
      });
      await Future.delayed(const Duration(milliseconds: 100));
      setState(() => _isLoading = false);

      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('번역이 완료되었습니다.')),
      );
    } catch (e) {
      if (mounted) Navigator.pop(context);
    }
  }

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
    SystemChrome.setEnabledSystemUIMode(SystemUiMode.immersiveSticky);
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

  void _toggleTheme() async {
    final nextDark = !_isDarkMode;
    setState(() => _isDarkMode = nextDark);
    await StorageService.setDarkMode(nextDark);
    _epubController.updateTheme(theme: _buildTheme());
  }

  void _changeFontSize(int delta) {
    setState(() => _fontSize = (_fontSize + delta).clamp(12, 32).toInt());
    _epubController.setFontSize(fontSize: _fontSize.toDouble());
  }

  @override
  void dispose() {
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
    final bottomPadding = mediaQuery.viewPadding.bottom;
    final bool isLandscape = screenSize.width > screenSize.height;
    final EpubSpread spreadSetting =
        (isLandscape && _enableTwoPageInLandscape) ? EpubSpread.always : EpubSpread.none;

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
          Positioned.fill(
            child: Padding(
              padding: EdgeInsets.only(
                top: 12.0,
                bottom: (bottomPadding > 0 ? bottomPadding : 8.0) + 20.0,
              ),
              child: Listener(
                behavior: HitTestBehavior.translucent,
                onPointerDown: _handlePointerDown,
                onPointerUp: (event) => _handlePointerUp(event, screenSize),
                child: EpubViewer(
                  key: ValueKey('${_activeFilePath}_$spreadSetting'),
                  epubController: _epubController,
                  epubSource: EpubSource.fromFile(File(_activeFilePath)),
                  initialCfi: _initialCfi,
                  displaySettings: EpubDisplaySettings(
                    flow: EpubFlow.paginated,
                    snap: true,
                    spread: spreadSetting,
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
                    if (!_hasRestoredInitialPosition) {
                      _hasRestoredInitialPosition = true;
                      if (_initialCfi != null && _initialCfi!.isNotEmpty) {
                        Future.delayed(const Duration(milliseconds: 150), () {
                          _epubController.display(cfi: _initialCfi!);
                        });
                      } else if (_progress > 0.01) {
                        Future.delayed(const Duration(milliseconds: 150), () {
                          _epubController.toProgressPercentage(_progress);
                        });
                      }
                    }
                  },
                  onTextSelected: (epubTextSelection) {
                    _selectedCfiRange = epubTextSelection.selectionCfi;
                  },
                  onRelocated: (value) {
                    if (!_hasRestoredInitialPosition && _initialCfi != null && value.progress < 0.01 && _progress > 0.05) {
                      return;
                    }
                    _hasRestoredInitialPosition = true;
                    _currentCfi = value.startCfi;
                    StorageService.saveLastPosition(widget.filePath, value.startCfi);
                    StorageService.saveProgress(widget.filePath, value.progress);
                    if (mounted) {
                      setState(() {
                        _progress = value.progress.clamp(0.0, 1.0).toDouble();
                      });
                    }
                  },
                ),
              ),
            ),
          ),

          Positioned(
            left: 16,
            right: 16,
            bottom: bottomPadding > 0 ? bottomPadding / 2 : 4,
            height: 22,
            child: IgnorePointer(
              child: Align(
                alignment: Alignment.centerRight,
                child: Text(
                  '${(_progress * 100).toStringAsFixed(1)}%',
                  style: TextStyle(
                    fontSize: 11,
                    fontWeight: FontWeight.w500,
                    color: footerTextColor,
                  ),
                ),
              ),
            ),
          ),

          if (_showControls)
            Positioned(
              top: 0,
              left: 0,
              right: 0,
              child: Material(
                elevation: 4,
                color: barColor,
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
                      IconButton(
                        icon: Icon(Icons.text_decrease, color: iconColor, size: 20),
                        tooltip: '글자 작게',
                        onPressed: () => _changeFontSize(-2),
                      ),
                      IconButton(
                        icon: Icon(Icons.text_increase, color: iconColor, size: 20),
                        tooltip: '글자 크게',
                        onPressed: () => _changeFontSize(2),
                      ),
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
                      IconButton(
                        icon: Icon(
                          _enableTwoPageInLandscape ? Icons.menu_book : Icons.stay_current_portrait,
                          color: _enableTwoPageInLandscape ? Colors.indigo : iconColor,
                        ),
                        tooltip: '가로 모드 2페이지 보기 설정',
                        onPressed: () async {
                          final nextVal = !_enableTwoPageInLandscape;
                          await StorageService.setTwoPageLandscape(nextVal);
                          setState(() {
                            _initialCfi = _currentCfi;
                            _enableTwoPageInLandscape = nextVal;
                          });
                        },
                      ),
                      IconButton(
                        icon: Icon(
                          Icons.translate,
                          color: _isTranslatedFileActive ? Colors.amber[800] : iconColor,
                        ),
                        tooltip: '번역',
                        onPressed: _handleBatchTranslateBook,
                      ),
                      IconButton(
                        icon: Icon(Icons.bookmarks_outlined, color: iconColor),
                        tooltip: '북마크',
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

          if (_showControls)
            Positioned(
              top: 72.0,
              bottom: 48.0,
              right: 8.0,
              width: 52.0,
              child: Material(
                elevation: 6,
                color: barColor,
                borderRadius: BorderRadius.circular(26),
                child: Padding(
                  padding: const EdgeInsets.symmetric(vertical: 8),
                  child: Column(
                    children: [
                      IconButton(
                        icon: Icon(Icons.expand_less, color: iconColor, size: 22),
                        padding: EdgeInsets.zero,
                        constraints: const BoxConstraints(minWidth: 36, minHeight: 36),
                        onPressed: () => _epubController.prev(),
                      ),
                      Expanded(
                        child: RotatedBox(
                          quarterTurns: 1,
                          child: Slider(
                            value: _progress.clamp(0.0, 1.0).toDouble(),
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
                      ),
                      Text(
                        '${(_progress * 100).toStringAsFixed(0)}%',
                        style: TextStyle(fontSize: 10, fontWeight: FontWeight.bold, color: iconColor),
                      ),
                      IconButton(
                        icon: Icon(Icons.expand_more, color: iconColor, size: 22),
                        padding: EdgeInsets.zero,
                        constraints: const BoxConstraints(minWidth: 36, minHeight: 36),
                        onPressed: () => _epubController.next(),
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
