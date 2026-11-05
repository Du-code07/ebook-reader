import 'dart:async';
import 'dart:io';
import 'dart:math' as math;
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
  bool _enableTwoPageInLandscape = true;
  int _fontSize = 18;
  List<EpubChapter> _chapters = [];

  bool _showControls = false;
  bool _isTouchLocked = false;
  bool _useVolumeTurn = true;
  bool _useQuickNavTurn = false;
  bool _useSpenTurn = true;
  String _bookMemoNote = '';

  String _footerInfoMode = 'both';
  String _progressBarPos = 'right';
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

  void _unlockTouchScreenByVolumeCombo() {
    if (!_isTouchLocked || !mounted) return;
    setState(() {
      _isTouchLocked = false;
    });
    ScaffoldMessenger.of(context).showSnackBar(
      const SnackBar(
        content: Text('음량 버튼 동시 입력으로 화면 터치 잠금이 해제되었습니다.'),
        duration: Duration(seconds: 1),
      ),
    );
  }

  void _lockTouchScreen() {
    setState(() {
      _isTouchLocked = true;
      _showControls = false;
    });
    ScaffoldMessenger.of(context).showSnackBar(
      const SnackBar(
        content: Text('화면 터치가 잠겼습니다. (음량 버튼 2개를 동시에 누르면 잠금 해제)'),
        duration: Duration(seconds: 2),
      ),
    );
  }

  Future<void> _initReader() async {
    final savedCfi = await StorageService.getLastPosition(widget.filePath);
    final prevCfi = await StorageService.getPreviousPosition(widget.filePath);
    final savedProg = await StorageService.getProgress(widget.filePath);
    final twoPage = await StorageService.getTwoPageLandscape();
    final isDark = await StorageService.getDarkMode();
    final footerMode = await StorageService.getFooterInfoMode();
    final barPos = await StorageService.getProgressBarPosition();
    final volTurn = await StorageService.getUseVolumeTurn();
    final quickTurn = await StorageService.getUseQuickNavTurn();
    final spenTurn = await StorageService.getUseSpenTurn();
    final memo = await StorageService.getPageMemoNote(widget.filePath, 0);

    _bindHardwareButtons();

    setState(() {
      _initialCfi = savedCfi;
      _currentCfi = savedCfi;
      _previousJumpCfi = prevCfi;
      _progress = savedProg.clamp(0.0, 1.0).toDouble();
      _enableTwoPageInLandscape = twoPage;
      _isDarkMode = isDark;
      _footerInfoMode = footerMode;
      _progressBarPos = barPos;
      _useVolumeTurn = volTurn;
      _useQuickNavTurn = quickTurn;
      _useSpenTurn = spenTurn;
      _bookMemoNote = memo;
      _isLoading = false;
    });
  }

  void _bindHardwareButtons() {
    _volumeKeyService.startListening(
      onVolumeUp: () {
        if (_useVolumeTurn) _epubController.prev();
      },
      onVolumeDown: () {
        if (_useVolumeTurn) _epubController.next();
      },
      onVolumeBothUnlock: _unlockTouchScreenByVolumeCombo,
      onSpenSinglePress: () {
        if (_useSpenTurn) _epubController.next();
      },
      onSpenDoublePress: () {
        if (_useSpenTurn) _epubController.prev();
      },
    );
  }

  Future<void> _showEpubMemoDialog() async {
    final ctrl = TextEditingController(text: _bookMemoNote);
    await showDialog(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('S펜 간단 메모'),
        content: TextField(
          controller: ctrl,
          maxLines: 4,
          decoration: const InputDecoration(
            hintText: 'S펜이나 키보드로 메모를 남겨보세요.',
            border: OutlineInputBorder(),
          ),
        ),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx), child: const Text('취소')),
          ElevatedButton(
            onPressed: () async {
              final text = ctrl.text.trim();
              await StorageService.savePageMemoNote(widget.filePath, 0, text);
              setState(() => _bookMemoNote = text);
              if (ctx.mounted) Navigator.pop(ctx);
            },
            child: const Text('저장'),
          ),
        ],
      ),
    );
  }

  Future<void> _showViewerSettingsSheet() async {
    await showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      builder: (ctx) => StatefulBuilder(
        builder: (ctx, setModalState) => SafeArea(
          child: SingleChildScrollView(
            padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                const Text('뷰어 표시 설정', style: TextStyle(fontSize: 16, fontWeight: FontWeight.bold)),
                const SizedBox(height: 12),
                const Text('페이지 전환 설정 (동시 사용 가능)', style: TextStyle(fontSize: 13, fontWeight: FontWeight.w600)),
                const SizedBox(height: 6),
                Wrap(
                  spacing: 8,
                  runSpacing: 6,
                  children: [
                    FilterChip(
                      label: const Text('음량 버튼'),
                      selected: _useVolumeTurn,
                      onSelected: (val) async {
                        await StorageService.setUseVolumeTurn(val);
                        setState(() => _useVolumeTurn = val);
                        setModalState(() {});
                      },
                    ),
                    FilterChip(
                      label: const Text('화면 이동 버튼'),
                      selected: _useQuickNavTurn,
                      onSelected: (val) async {
                        await StorageService.setUseQuickNavTurn(val);
                        setState(() => _useQuickNavTurn = val);
                        setModalState(() {});
                      },
                    ),
                    FilterChip(
                      label: const Text('S펜 버튼'),
                      selected: _useSpenTurn,
                      onSelected: (val) async {
                        await StorageService.setUseSpenTurn(val);
                        setState(() => _useSpenTurn = val);
                        setModalState(() {});
                      },
                    ),
                  ],
                ),
                const Divider(height: 24),
                const Text('진행도 UI 위치', style: TextStyle(fontSize: 13, fontWeight: FontWeight.w600)),
                const SizedBox(height: 6),
                Wrap(
                  spacing: 8,
                  runSpacing: 6,
                  children: [
                    ChoiceChip(
                      label: const Text('오른쪽'),
                      selected: _progressBarPos == 'right',
                      onSelected: (_) async {
                        await StorageService.setProgressBarPosition('right');
                        setState(() => _progressBarPos = 'right');
                        setModalState(() {});
                      },
                    ),
                    ChoiceChip(
                      label: const Text('왼쪽'),
                      selected: _progressBarPos == 'left',
                      onSelected: (_) async {
                        await StorageService.setProgressBarPosition('left');
                        setState(() => _progressBarPos = 'left');
                        setModalState(() {});
                      },
                    ),
                    ChoiceChip(
                      label: const Text('하단'),
                      selected: _progressBarPos == 'bottom',
                      onSelected: (_) async {
                        await StorageService.setProgressBarPosition('bottom');
                        setState(() => _progressBarPos = 'bottom');
                        setModalState(() {});
                      },
                    ),
                    ChoiceChip(
                      label: const Text('숨김'),
                      selected: _progressBarPos == 'hidden',
                      onSelected: (_) async {
                        await StorageService.setProgressBarPosition('hidden');
                        setState(() => _progressBarPos = 'hidden');
                        setModalState(() {});
                      },
                    ),
                  ],
                ),
                const Divider(height: 24),
                const Text('하단 정보 표시', style: TextStyle(fontSize: 13, fontWeight: FontWeight.w600)),
                const SizedBox(height: 6),
                Wrap(
                  spacing: 8,
                  runSpacing: 6,
                  children: [
                    ChoiceChip(
                      label: const Text('진행률'),
                      selected: _footerInfoMode == 'progress',
                      onSelected: (_) async {
                        await StorageService.setFooterInfoMode('progress');
                        setState(() => _footerInfoMode = 'progress');
                        setModalState(() {});
                      },
                    ),
                    ChoiceChip(
                      label: const Text('페이지 번호'),
                      selected: _footerInfoMode == 'page',
                      onSelected: (_) async {
                        await StorageService.setFooterInfoMode('page');
                        setState(() => _footerInfoMode = 'page');
                        setModalState(() {});
                      },
                    ),
                    ChoiceChip(
                      label: const Text('진행률 및 페이지 번호'),
                      selected: _footerInfoMode == 'both',
                      onSelected: (_) async {
                        await StorageService.setFooterInfoMode('both');
                        setState(() => _footerInfoMode = 'both');
                        setModalState(() {});
                      },
                    ),
                    ChoiceChip(
                      label: const Text('정보 표시 없음'),
                      selected: _footerInfoMode == 'none',
                      onSelected: (_) async {
                        await StorageService.setFooterInfoMode('none');
                        setState(() => _footerInfoMode = 'none');
                        setModalState(() {});
                      },
                    ),
                  ],
                ),
                const SizedBox(height: 8),
              ],
            ),
          ),
        ),
      ),
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
    if (_isTouchLocked) return;
    setState(() => _showControls = !_showControls);
    SystemChrome.setEnabledSystemUIMode(SystemUiMode.immersiveSticky);
  }

  void _handlePointerDown(PointerDownEvent event) {
    if (_isTouchLocked) return;
    _pointerDownPosition = event.position;
    _pointerDownTime = DateTime.now();
  }

  void _handlePointerUp(PointerUpEvent event, Size screenSize) {
    if (_isTouchLocked || _pointerDownPosition == null || _pointerDownTime == null) return;
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

  String _formatEpubFooterText() {
    if (_footerInfoMode == 'none') return '';
    final int totalEstPages = (_chapters.isNotEmpty ? _chapters.length * 10 : 100);
    final int curEstPage = ((_progress * totalEstPages).round()).clamp(1, totalEstPages).toInt();
    final String progStr = '${(_progress * 100).toStringAsFixed(1)}%';
    final String pageStr = '$curEstPage / $totalEstPages';

    if (_footerInfoMode == 'progress') {
      return progStr;
    } else if (_footerInfoMode == 'page') {
      return pageStr;
    } else {
      return '$progStr  |  $pageStr';
    }
  }

  Widget _buildEpubProgressBar(Color barColor, Color iconColor) {

    final double val = _progress.clamp(0.0, 1.0).toDouble();

    if (_progressBarPos == 'bottom') {
      return Positioned(
        left: 16.0,
        right: _useQuickNavTurn ? 116.0 : 16.0,
        bottom: 28.0,
        child: Material(
          elevation: 6,
          color: barColor,
          borderRadius: BorderRadius.circular(26),
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 4),
            child: Row(
              children: [
                IconButton(
                  icon: Icon(Icons.chevron_left, color: iconColor),
                  onPressed: () => _epubController.prev(),
                ),
                Expanded(
                  child: Slider(
                    value: val,
                    min: 0.0,
                    max: 1.0,
                    onChanged: (v) => setState(() => _progress = v),
                    onChangeEnd: (v) {
                      if (_currentCfi != null) {
                        setState(() => _previousJumpCfi = _currentCfi);
                      }
                      _epubController.toProgressPercentage(v);
                    },
                  ),
                ),
                Text(
                  '${(_progress * 100).toStringAsFixed(0)}%',
                  style: TextStyle(fontSize: 11, fontWeight: FontWeight.bold, color: iconColor),
                ),
                IconButton(
                  icon: Icon(Icons.chevron_right, color: iconColor),
                  onPressed: () => _epubController.next(),
                ),
              ],
            ),
          ),
        ),
      );
    }

    return Positioned(
      top: 72.0,
      bottom: _useQuickNavTurn && _progressBarPos == 'right' ? 84.0 : 48.0,
      left: _progressBarPos == 'left' ? 8.0 : null,
      right: _progressBarPos == 'right' ? 8.0 : null,
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
                    value: val,
                    min: 0.0,
                    max: 1.0,
                    onChanged: (v) => setState(() => _progress = v),
                    onChangeEnd: (v) {
                      if (_currentCfi != null) {
                        setState(() => _previousJumpCfi = _currentCfi);
                      }
                      _epubController.toProgressPercentage(v);
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
    );
  }

  Widget _buildQuickNavButtons(double bottomInset, Color barColor, Color iconColor) {
    return Positioned(
      right: 12.0,
      bottom: math.max<double>(bottomInset + 24.0, 28.0),
      child: Material(
        color: barColor,
        borderRadius: BorderRadius.circular(24),
        elevation: 6,
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 4),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              IconButton(
                icon: Icon(Icons.arrow_upward, color: iconColor, size: 22),
                tooltip: '이전 페이지',
                constraints: const BoxConstraints(minWidth: 40, minHeight: 40),
                padding: EdgeInsets.zero,
                onPressed: () => _epubController.prev(),
              ),
              Container(width: 1, height: 22, color: iconColor.withOpacity(0.24)),
              IconButton(
                icon: Icon(Icons.arrow_downward, color: iconColor, size: 22),
                tooltip: '다음 페이지',
                constraints: const BoxConstraints(minWidth: 40, minHeight: 40),
                padding: EdgeInsets.zero,
                onPressed: () => _epubController.next(),
              ),
            ],
          ),
        ),
      ),
    );
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
    final footerText = _formatEpubFooterText();

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
              child: AbsorbPointer(
                absorbing: _isTouchLocked,
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
          ),

          if (footerText.isNotEmpty)
            Positioned(
              left: 16,
              right: 16,
              bottom: bottomPadding > 0 ? bottomPadding / 2 : 4,
              height: 22,
              child: IgnorePointer(
                child: Align(
                  alignment: Alignment.centerRight,
                  child: Text(
                    footerText,
                    style: TextStyle(
                      fontSize: 11,
                      fontWeight: FontWeight.w500,
                      color: footerTextColor,
                    ),
                  ),
                ),
              ),
            ),

          if (_showControls && !_isTouchLocked)
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
                            fontSize: 14,
                            fontWeight: FontWeight.w600,
                            color: iconColor,
                          ),
                          overflow: TextOverflow.ellipsis,
                        ),
                      ),
                      IconButton(
                        icon: Icon(Icons.screen_lock_portrait, color: iconColor, size: 20),
                        tooltip: '화면 터치 잠금',
                        onPressed: _lockTouchScreen,
                      ),
                      IconButton(
                        icon: Icon(
                          Icons.draw_outlined,
                          color: _bookMemoNote.isNotEmpty ? Colors.amber[800] : iconColor,
                          size: 20,
                        ),
                        tooltip: 'S펜 메모',
                        onPressed: _showEpubMemoDialog,
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
                          icon: const Icon(Icons.restore, color: Colors.indigo, size: 20),
                          tooltip: '이전에 읽던 페이지로 돌아가기',
                          onPressed: () {
                            final target = _previousJumpCfi!;
                            setState(() => _previousJumpCfi = _currentCfi);
                            _epubController.display(cfi: target);
                          },
                        ),
                      IconButton(
                        icon: Icon(
                          Icons.translate,
                          color: _isTranslatedFileActive ? Colors.amber[800] : iconColor,
                          size: 20,
                        ),
                        tooltip: '번역',
                        onPressed: _handleBatchTranslateBook,
                      ),
                      IconButton(
                        icon: Icon(Icons.bookmarks_outlined, color: iconColor, size: 20),
                        tooltip: '북마크',
                        onPressed: _openBookmarkSheet,
                      ),
                      IconButton(
                        icon: Icon(Icons.tune, color: iconColor, size: 20),
                        tooltip: '뷰어 표시 설정',
                        onPressed: _showViewerSettingsSheet,
                      ),
                      IconButton(
                        icon: Icon(
                          _isDarkMode ? Icons.light_mode : Icons.dark_mode,
                          color: iconColor,
                          size: 20,
                        ),
                        onPressed: _toggleTheme,
                      ),
                    ],
                  ),
                ),
              ),
            ),

          if (_showControls && !_isTouchLocked && _progressBarPos != 'hidden')
            _buildEpubProgressBar(barColor, iconColor),

          if (_useQuickNavTurn && !_isTouchLocked)
            _buildQuickNavButtons(bottomPadding, barColor, iconColor),
        ],
      ),
    );
  }
}
