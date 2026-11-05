import 'dart:async';
import 'dart:io';
import 'dart:math' as math;
import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_epub_viewer/flutter_epub_viewer.dart';
import '../services/batch_translation_service.dart';
import '../services/storage_service.dart';
import '../services/volume_key_service.dart';
import 'pdf_and_image_viewer.dart';

class _EpubMemoPainter extends CustomPainter {
  final List<MemoStroke> strokes;
  final List<Offset> currentPoints;
  final Color currentColor;
  final double currentWidth;

  _EpubMemoPainter({
    required this.strokes,
    required this.currentPoints,
    required this.currentColor,
    required this.currentWidth,
  });

  @override
  void paint(Canvas canvas, Size size) {
    for (final s in strokes) {
      if (s.dxList.isEmpty) continue;
      final paint = Paint()
        ..color = Color(s.colorValue)
        ..strokeWidth = s.strokeWidth
        ..strokeCap = StrokeCap.round
        ..strokeJoin = StrokeJoin.round
        ..style = PaintingStyle.stroke;

      final path = Path();
      path.moveTo(s.dxList.first * size.width, s.dyList.first * size.height);
      for (int i = 1; i < s.dxList.length; i++) {
        path.lineTo(s.dxList[i] * size.width, s.dyList[i] * size.height);
      }
      canvas.drawPath(path, paint);
    }

    if (currentPoints.isNotEmpty) {
      final paint = Paint()
        ..color = currentColor
        ..strokeWidth = currentWidth
        ..strokeCap = StrokeCap.round
        ..strokeJoin = StrokeJoin.round
        ..style = PaintingStyle.stroke;

      final path = Path();
      path.moveTo(currentPoints.first.dx, currentPoints.first.dy);
      for (int i = 1; i < currentPoints.length; i++) {
        path.lineTo(currentPoints[i].dx, currentPoints[i].dy);
      }
      canvas.drawPath(path, paint);
    }
  }

  @override
  bool shouldRepaint(covariant _EpubMemoPainter oldDelegate) => true;
}

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
  String _epubBgTheme = 'white'; // 'white', 'sepia', 'dark'
  bool _enableTwoPageInLandscape = true;
  bool _isMangaRtlMode = false;
  int _fontSize = 18;
  List<EpubChapter> _chapters = [];

  bool _showControls = false;
  bool _isTouchLocked = false;
  bool _useVolumeTurn = true;
  bool _useQuickNavTurn = false;
  bool _useSpenTurn = true;

  // S펜 필기 및 지우개 상태 (손터치는 페이지 넘기기만 가능, S펜으로만 필기/지우개 작동)
  bool _isMemoMode = false;
  bool _isEraserMode = false;
  int? _activeStylusPointerId;
  List<MemoStroke> _epubStrokes = [];
  final List<Offset> _activeStrokePoints = [];
  Color _penColor = Colors.amber;
  final double _penWidth = 3.2;
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
      _isMemoMode = false;
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
    final isRtl = await StorageService.getReadingDirectionRtl();
    final isDark = await StorageService.getDarkMode();
    final savedBg = await StorageService.getEpubBgTheme();
    final footerMode = await StorageService.getFooterInfoMode();
    final barPos = await StorageService.getProgressBarPosition();
    final volTurn = await StorageService.getUseVolumeTurn();
    final quickTurn = await StorageService.getUseQuickNavTurn();
    final spenTurn = await StorageService.getUseSpenTurn();
    final memo = await StorageService.getPageMemoNote(widget.filePath, 0);
    final strokes = await StorageService.getPageMemoStrokes(widget.filePath, 0);

    _bindHardwareButtons();

    setState(() {
      _initialCfi = savedCfi;
      _currentCfi = savedCfi;
      _previousJumpCfi = prevCfi;
      _progress = savedProg.clamp(0.0, 1.0).toDouble();
      _enableTwoPageInLandscape = twoPage;
      _isMangaRtlMode = isRtl;
      _epubBgTheme = savedBg.isNotEmpty ? savedBg : (isDark ? 'dark' : 'white');
      _footerInfoMode = footerMode;
      _progressBarPos = barPos;
      _useVolumeTurn = volTurn;
      _useQuickNavTurn = quickTurn;
      _useSpenTurn = spenTurn;
      _bookMemoNote = memo;
      _epubStrokes = strokes;
      _isLoading = false;
    });
  }

  void _turnNext() {
    if (_isMangaRtlMode) {
      _epubController.prev();
    } else {
      _epubController.next();
    }
  }

  void _turnPrev() {
    if (_isMangaRtlMode) {
      _epubController.next();
    } else {
      _epubController.prev();
    }
  }

  void _bindHardwareButtons() {
    _volumeKeyService.startListening(
      onVolumeUp: () {
        if (_useVolumeTurn) _turnPrev();
      },
      onVolumeDown: () {
        if (_useVolumeTurn) _turnNext();
      },
      onVolumeBothUnlock: _unlockTouchScreenByVolumeCombo,
      onSpenSinglePress: () {
        if (_useSpenTurn) _turnNext();
      },
      onSpenDoublePress: () {
        if (_useSpenTurn) _turnPrev();
      },
    );
  }

  Widget _buildDualDirectionIcon() {
    final bool isRightActive = !_isMangaRtlMode;
    const Color activeColor = Colors.amber;
    const Color inactiveColor = Colors.white38;

    return SizedBox(
      width: 24,
      height: 22,
      child: Stack(
        alignment: Alignment.center,
        children: [
          Positioned(
            top: 1,
            child: Icon(
              Icons.east,
              size: 14,
              color: isRightActive ? activeColor : inactiveColor,
            ),
          ),
          Positioned(
            bottom: 1,
            child: Icon(
              Icons.west,
              size: 14,
              color: !isRightActive ? activeColor : inactiveColor,
            ),
          ),
        ],
      ),
    );
  }

  Future<void> _eraseEpubStrokeAt(Offset localPos, double drawWidth, double drawHeight) async {
    if (_epubStrokes.isEmpty || drawWidth <= 0 || drawHeight <= 0) return;

    const double hitRadius = 22.0;
    bool removedAny = false;
    final remaining = <MemoStroke>[];

    for (final s in _epubStrokes) {
      bool hit = false;
      for (int i = 0; i < s.dxList.length; i++) {
        final px = s.dxList[i] * drawWidth;
        final py = s.dyList[i] * drawHeight;
        if ((Offset(px, py) - localPos).distance <= hitRadius) {
          hit = true;
          break;
        }
      }
      if (hit) {
        removedAny = true;
      } else {
        remaining.add(s);
      }
    }

    if (removedAny) {
      setState(() => _epubStrokes = remaining);
      await StorageService.savePageMemoStrokes(widget.filePath, 0, remaining);
    }
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
          if (_epubStrokes.isNotEmpty || _bookMemoNote.isNotEmpty)
            TextButton(
              onPressed: () async {
                await StorageService.savePageMemoStrokes(widget.filePath, 0, []);
                await StorageService.savePageMemoNote(widget.filePath, 0, '');
                setState(() {
                  _epubStrokes = [];
                  _bookMemoNote = '';
                });
                if (ctx.mounted) Navigator.pop(ctx);
              },
              child: const Text('메모/필기 모두 지우기', style: TextStyle(color: Colors.redAccent)),
            ),
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

  /// 뷰어 표시 설정 (JPG 뷰어와 100% 동일한 UI + EPUB 글자 크기 및 다크 모드 설정 포함)
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
                Row(
                  mainAxisAlignment: MainAxisAlignment.spaceBetween,
                  children: [
                    const Text('글자 크기', style: TextStyle(fontSize: 13, fontWeight: FontWeight.w600)),
                    Row(
                      children: [
                        IconButton(
                          icon: const Icon(Icons.text_decrease),
                          onPressed: () {
                            _changeFontSize(-2);
                            setModalState(() {});
                          },
                        ),
                        Text('${_fontSize}pt', style: const TextStyle(fontWeight: FontWeight.bold)),
                        IconButton(
                          icon: const Icon(Icons.text_increase),
                          onPressed: () {
                            _changeFontSize(2);
                            setModalState(() {});
                          },
                        ),
                      ],
                    ),
                  ],
                ),
                const SizedBox(height: 8),
                const Text('배경 색상', style: TextStyle(fontSize: 13, fontWeight: FontWeight.w600)),
                const SizedBox(height: 6),
                Wrap(
                  spacing: 8,
                  runSpacing: 6,
                  children: [
                    ChoiceChip(
                      label: const Text('흰색'),
                      selected: _epubBgTheme == 'white',
                      onSelected: (_) async {
                        await _setEpubThemeMode('white');
                        setModalState(() {});
                      },
                    ),
                    ChoiceChip(
                      label: const Text('종이색'),
                      selected: _epubBgTheme == 'sepia',
                      onSelected: (_) async {
                        await _setEpubThemeMode('sepia');
                        setModalState(() {});
                      },
                    ),
                    ChoiceChip(
                      label: const Text('다크'),
                      selected: _epubBgTheme == 'dark',
                      onSelected: (_) async {
                        await _setEpubThemeMode('dark');
                        setModalState(() {});
                      },
                    ),
                  ],
                ),
                const Divider(height: 16),
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
                      label: const Text('페이지 이동 버튼'),
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

  Future<void> _handleBatchTranslateBook({bool forceRetranslate = false}) async {
    if (_isTranslatedFileActive && !forceRetranslate) {
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
    // S펜 입력일 때는 페이지 탭 넘김 대신 필기 레이어가 동작하도록 구분
    if (_isMemoMode &&
        (event.kind == PointerDeviceKind.stylus ||
            event.kind == PointerDeviceKind.invertedStylus)) {
      return;
    }
    _pointerDownPosition = event.position;
    _pointerDownTime = DateTime.now();
  }

  void _handlePointerUp(PointerUpEvent event, Size screenSize) {
    if (_isTouchLocked || _pointerDownPosition == null || _pointerDownTime == null) return;
    if (_isMemoMode &&
        (event.kind == PointerDeviceKind.stylus ||
            event.kind == PointerDeviceKind.invertedStylus)) {
      return;
    }
    final distance = (event.position - _pointerDownPosition!).distance;
    final duration = DateTime.now().difference(_pointerDownTime!).inMilliseconds;

    if (distance < 15.0 && duration < 250) {
      final dx = event.position.dx;
      if (dx > screenSize.width * 0.2 && dx < screenSize.width * 0.8) {
        _toggleControls();
      } else if (dx <= screenSize.width * 0.2) {
        _turnPrev();
      } else {
        _turnNext();
      }
    }
    _pointerDownPosition = null;
    _pointerDownTime = null;
  }

  Color _getBgColor() {
    if (_epubBgTheme == 'dark') return const Color(0xFF1E1E1E);
    if (_epubBgTheme == 'sepia') return const Color(0xFFFBF0D9);
    return Colors.white;
  }

  Color _getFgColor() {
    if (_epubBgTheme == 'dark') return const Color(0xFFD4D4D4);
    if (_epubBgTheme == 'sepia') return const Color(0xFF3B2F2F);
    return const Color(0xFF141414);
  }

  EpubTheme _buildTheme() {
    return EpubTheme.custom(
      backgroundDecoration: BoxDecoration(
        color: _getBgColor(),
      ),
      foregroundColor: _getFgColor(),
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

  Future<void> _setEpubThemeMode(String mode) async {
    setState(() => _epubBgTheme = mode);
    await StorageService.setEpubBgTheme(mode);
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

  /// 2. EPUB 진행도 슬라이더 바도 JPG/PDF 뷰어와 동일한 다크 반투명 디자인(Colors.black87)으로 통일
  Widget _buildEpubProgressBar() {
    if (!_showControls || _isTouchLocked || _progressBarPos == 'hidden') {
      return const Positioned(
        key: ValueKey('epub_progress_bar_hidden'),
        left: 0,
        bottom: 0,
        width: 0,
        height: 0,
        child: SizedBox.shrink(),
      );
    }

    final double val = _progress.clamp(0.0, 1.0).toDouble();

    if (_progressBarPos == 'bottom') {
      return Positioned(
        key: const ValueKey('epub_progress_bar_bottom'),
        left: 16.0,
        right: _useQuickNavTurn ? 116.0 : 16.0,
        bottom: 28.0,
        child: Material(
          elevation: 6,
          color: Colors.black87,
          borderRadius: BorderRadius.circular(26),
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 4),
            child: Row(
              children: [
                IconButton(
                  icon: const Icon(Icons.chevron_left, color: Colors.white),
                  onPressed: _turnPrev,
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
                  style: const TextStyle(fontSize: 11, fontWeight: FontWeight.bold, color: Colors.white),
                ),
                IconButton(
                  icon: const Icon(Icons.chevron_right, color: Colors.white),
                  onPressed: _turnNext,
                ),
              ],
            ),
          ),
        ),
      );
    }

    return Positioned(
      key: ValueKey('epub_progress_bar_$_progressBarPos'),
      top: 72.0,
      bottom: _useQuickNavTurn && _progressBarPos == 'right' ? 84.0 : 48.0,
      left: _progressBarPos == 'left' ? 8.0 : null,
      right: _progressBarPos == 'right' ? 8.0 : null,
      width: 52.0,
      child: Material(
        elevation: 6,
        color: Colors.black87,
        borderRadius: BorderRadius.circular(26),
        child: Padding(
          padding: const EdgeInsets.symmetric(vertical: 8),
          child: Column(
            children: [
              IconButton(
                icon: const Icon(Icons.expand_less, color: Colors.white, size: 22),
                padding: EdgeInsets.zero,
                constraints: const BoxConstraints(minWidth: 36, minHeight: 36),
                onPressed: _turnPrev,
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
                style: const TextStyle(fontSize: 10, fontWeight: FontWeight.bold, color: Colors.white),
              ),
              IconButton(
                icon: const Icon(Icons.expand_more, color: Colors.white, size: 22),
                padding: EdgeInsets.zero,
                constraints: const BoxConstraints(minWidth: 36, minHeight: 36),
                onPressed: _turnNext,
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildQuickNavButtons(double bottomInset) {
    return Positioned(
      right: 12.0,
      bottom: math.max<double>(bottomInset + 24.0, 28.0),
      child: Material(
        color: Colors.black87,
        borderRadius: BorderRadius.circular(24),
        elevation: 6,
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 4),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              IconButton(
                icon: const Icon(Icons.arrow_upward, color: Colors.amber, size: 22),
                tooltip: '이전 페이지',
                constraints: const BoxConstraints(minWidth: 40, minHeight: 40),
                padding: EdgeInsets.zero,
                onPressed: _turnPrev,
              ),
              Container(width: 1, height: 22, color: Colors.white24),
              IconButton(
                icon: const Icon(Icons.arrow_downward, color: Colors.amber, size: 22),
                tooltip: '다음 페이지',
                constraints: const BoxConstraints(minWidth: 40, minHeight: 40),
                padding: EdgeInsets.zero,
                onPressed: _turnNext,
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

    final bgColor = _getBgColor();
    final footerTextColor = _epubBgTheme == 'dark' ? Colors.white54 : Colors.black54;
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
          // 1. EPUB 뷰어 본문
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

          // S펜 전용 필기/지우개 오버레이 (손터치는 EPUB 페이지 넘기기로 통과, S펜만 필기/지우개 작동)
          if (_epubStrokes.isNotEmpty || _isMemoMode)
            Positioned.fill(
              child: LayoutBuilder(
                builder: (context, constraints) {
                  final double drawWidth = constraints.maxWidth;
                  final double drawHeight = constraints.maxHeight;
                  return StylusOnlyHitTestWrapper(
                    enabled: _isMemoMode,
                    child: Listener(
                      behavior: HitTestBehavior.opaque,
                      onPointerDown: (event) {
                        if (!_isMemoMode) return;
                        if (event.kind != PointerDeviceKind.stylus &&
                            event.kind != PointerDeviceKind.invertedStylus) {
                          return;
                        }
                        _activeStylusPointerId = event.pointer;
                        final bool useEraser =
                            _isEraserMode || event.kind == PointerDeviceKind.invertedStylus;
                        if (useEraser) {
                          _eraseEpubStrokeAt(event.localPosition, drawWidth, drawHeight);
                        } else {
                          setState(() {
                            _activeStrokePoints
                              ..clear()
                              ..add(event.localPosition);
                          });
                        }
                      },
                      onPointerMove: (event) {
                        if (!_isMemoMode || event.pointer != _activeStylusPointerId) return;
                        final bool useEraser =
                            _isEraserMode || event.kind == PointerDeviceKind.invertedStylus;
                        if (useEraser) {
                          _eraseEpubStrokeAt(event.localPosition, drawWidth, drawHeight);
                        } else {
                          setState(() {
                            _activeStrokePoints.add(event.localPosition);
                          });
                        }
                      },
                      onPointerUp: (event) async {
                        if (!_isMemoMode || event.pointer != _activeStylusPointerId) return;
                        _activeStylusPointerId = null;
                        final bool useEraser =
                            _isEraserMode || event.kind == PointerDeviceKind.invertedStylus;
                        if (!useEraser &&
                            _activeStrokePoints.isNotEmpty &&
                            drawWidth > 0 &&
                            drawHeight > 0) {
                          final stroke = MemoStroke(
                            dxList: _activeStrokePoints
                                .map((p) => (p.dx / drawWidth).clamp(0.0, 1.0).toDouble())
                                .toList(),
                            dyList: _activeStrokePoints
                                .map((p) => (p.dy / drawHeight).clamp(0.0, 1.0).toDouble())
                                .toList(),
                            colorValue: _penColor.value,
                            strokeWidth: _penWidth,
                          );
                          final list = List<MemoStroke>.from(_epubStrokes)..add(stroke);
                          setState(() {
                            _epubStrokes = list;
                            _activeStrokePoints.clear();
                          });
                          await StorageService.savePageMemoStrokes(widget.filePath, 0, list);
                        }
                      },
                      onPointerCancel: (_) {
                        _activeStylusPointerId = null;
                        setState(() => _activeStrokePoints.clear());
                      },
                      child: CustomPaint(
                        painter: _EpubMemoPainter(
                          strokes: _epubStrokes,
                          currentPoints: _activeStrokePoints,
                          currentColor: _penColor,
                          currentWidth: _penWidth,
                        ),
                      ),
                    ),
                  );
                },
              ),
            ),

          if (footerText.isNotEmpty)
            Positioned(
              left: 20,
              right: 20,
              bottom: math.max<double>(bottomPadding + 4.0, 8.0),
              child: IgnorePointer(
                child: Align(
                  alignment: Alignment.centerRight,
                  child: Text(
                    footerText,
                    style: TextStyle(
                      fontSize: 12,
                      fontWeight: FontWeight.w500,
                      color: footerTextColor,
                    ),
                  ),
                ),
              ),
            ),

          // S펜 필기 모드 상단 미니 툴바 (펜 색상 + 지우개 버튼 포함)
          if (_isMemoMode && !_isTouchLocked)
            Positioned(
              top: _showControls ? 58 : 12,
              left: 12,
              right: 12,
              child: Center(
                child: Material(
                  color: Colors.black87,
                  borderRadius: BorderRadius.circular(24),
                  elevation: 6,
                  child: Padding(
                    padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
                    child: SingleChildScrollView(
                      scrollDirection: Axis.horizontal,
                      child: Row(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          Icon(
                            _isEraserMode ? Icons.auto_fix_normal : Icons.draw,
                            color: Colors.amber,
                            size: 18,
                          ),
                          const SizedBox(width: 6),
                          Text(
                            _isEraserMode ? 'S펜 지우개' : 'S펜 필기 (손터치: 페이지 이동)',
                            style: const TextStyle(color: Colors.white, fontSize: 11),
                          ),
                          const SizedBox(width: 8),
                          ...[Colors.amber, Colors.redAccent, Colors.lightBlueAccent, Colors.greenAccent]
                              .map((c) => GestureDetector(
                                    onTap: () => setState(() {
                                      _penColor = c;
                                      _isEraserMode = false;
                                    }),
                                    child: Container(
                                      margin: const EdgeInsets.symmetric(horizontal: 3),
                                      width: 18,
                                      height: 18,
                                      decoration: BoxDecoration(
                                        color: c,
                                        shape: BoxShape.circle,
                                        border: Border.all(
                                          color: (!_isEraserMode && _penColor == c)
                                              ? Colors.white
                                              : Colors.transparent,
                                          width: 2,
                                        ),
                                      ),
                                    ),
                                  )),
                          const SizedBox(width: 4),
                          IconButton(
                            icon: Icon(
                              Icons.cleaning_services_outlined,
                              color: _isEraserMode ? Colors.amber : Colors.white,
                              size: 18,
                            ),
                            tooltip: 'S펜 지우개',
                            onPressed: () => setState(() => _isEraserMode = !_isEraserMode),
                          ),
                          IconButton(
                            icon: const Icon(Icons.note_alt_outlined, color: Colors.white, size: 18),
                            tooltip: '텍스트 메모 입력',
                            onPressed: _showEpubMemoDialog,
                          ),
                          IconButton(
                            icon: const Icon(Icons.delete_sweep_outlined, color: Colors.redAccent, size: 18),
                            tooltip: '필기 전체 지우기',
                            onPressed: () async {
                              setState(() => _epubStrokes = []);
                              await StorageService.savePageMemoStrokes(widget.filePath, 0, []);
                            },
                          ),
                          TextButton(
                            onPressed: () => setState(() {
                              _isMemoMode = false;
                              _isEraserMode = false;
                            }),
                            child: const Text('완료', style: TextStyle(color: Colors.amber)),
                          ),
                        ],
                      ),
                    ),
                  ),
                ),
              ),
            ),

          // 2. EPUB 상단 컨트롤 바도 JPG 뷰어와 동일한 검은색 반투명(Colors.black87) UI 및 아이콘 구성으로 통일!
          if (_showControls && !_isTouchLocked)
            Positioned(
              top: 0,
              left: 0,
              right: 0,
              child: Material(
                color: Colors.black87,
                child: Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 6),
                  child: Row(
                    children: [
                      IconButton(
                        icon: const Icon(Icons.arrow_back, color: Colors.white),
                        onPressed: () => Navigator.pop(context),
                      ),
                      IconButton(
                        icon: const Icon(Icons.list, color: Colors.white, size: 20),
                        tooltip: '목차',
                        onPressed: () => _scaffoldKey.currentState?.openDrawer(),
                      ),
                      Expanded(
                        child: Text(
                          widget.bookTitle,
                          style: const TextStyle(color: Colors.white, fontSize: 14),
                          overflow: TextOverflow.ellipsis,
                        ),
                      ),
                      if (_previousJumpCfi != null)
                        IconButton(
                          icon: const Icon(Icons.restore, color: Colors.amber, size: 20),
                          tooltip: '이전 페이지로 돌아가기',
                          onPressed: () {
                            final target = _previousJumpCfi!;
                            setState(() => _previousJumpCfi = _currentCfi);
                            _epubController.display(cfi: target);
                          },
                        ),
                      IconButton(
                        icon: const Icon(Icons.screen_lock_portrait, color: Colors.white, size: 20),
                        tooltip: '화면 터치 잠금',
                        onPressed: _lockTouchScreen,
                      ),
                      IconButton(
                        icon: Icon(
                          Icons.draw_outlined,
                          color: _isMemoMode ? Colors.amber : Colors.white,
                          size: 20,
                        ),
                        tooltip: 'S펜 메모',
                        onPressed: () {
                          setState(() {
                            _isMemoMode = !_isMemoMode;
                            _isEraserMode = false;
                          });
                        },
                      ),
                      IconButton(
                        icon: Icon(
                          _enableTwoPageInLandscape ? Icons.menu_book : Icons.stay_current_portrait,
                          color: _enableTwoPageInLandscape ? Colors.amber : Colors.white,
                          size: 20,
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
                        icon: _buildDualDirectionIcon(),
                        tooltip: _isMangaRtlMode ? '(오른쪽 -> 왼쪽)' : '방향(왼쪽 -> 오른쪽)',
                        onPressed: () async {
                          final nextRtl = !_isMangaRtlMode;
                          await StorageService.setReadingDirectionRtl(nextRtl);
                          setState(() => _isMangaRtlMode = nextRtl);
                          if (mounted) {
                            ScaffoldMessenger.of(context).showSnackBar(
                              SnackBar(
                                content: Text(nextRtl ? '(오른쪽 -> 왼쪽)' : '방향(왼쪽 -> 오른쪽)'),
                                duration: const Duration(milliseconds: 900),
                              ),
                            );
                          }
                        },
                      ),
                      IconButton(
                        icon: Icon(
                          _isTranslatedFileActive ? Icons.chat_bubble : Icons.translate,
                          color: _isTranslatedFileActive ? Colors.amber : Colors.white,
                          size: 20,
                        ),
                        tooltip: '번역',
                        onPressed: () => _handleBatchTranslateBook(forceRetranslate: false),
                      ),
                      if (_isTranslatedFileActive)
                        IconButton(
                          icon: const Icon(Icons.refresh, color: Colors.white70, size: 19),
                          tooltip: '다시 번역',
                          onPressed: () => _handleBatchTranslateBook(forceRetranslate: true),
                        ),
                      IconButton(
                        icon: const Icon(Icons.bookmarks_outlined, color: Colors.white, size: 20),
                        tooltip: '북마크',
                        onPressed: _openBookmarkSheet,
                      ),
                      IconButton(
                        icon: const Icon(Icons.tune, color: Colors.white, size: 20),
                        tooltip: '뷰어 표시 설정',
                        onPressed: _showViewerSettingsSheet,
                      ),
                    ],
                  ),
                ),
              ),
            ),

          _buildEpubProgressBar(),

          if (_useQuickNavTurn && !_isTouchLocked)
            _buildQuickNavButtons(bottomPadding),
        ],
      ),
    );
  }
}
