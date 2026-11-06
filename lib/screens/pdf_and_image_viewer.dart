import 'dart:async';
import 'dart:io';
import 'dart:math' as math;
import 'dart:ui' as ui;
import 'package:archive/archive.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:google_mlkit_text_recognition/google_mlkit_text_recognition.dart';
import 'package:path_provider/path_provider.dart';
import '../services/batch_translation_service.dart';
import '../services/storage_service.dart';
import '../services/volume_key_service.dart';

/// S펜 전용 터치 필터 위젯:
/// S펜(stylus / invertedStylus) 입력만 자식(필기/지우개 레이어)으로 전달하고,
/// 일반 손가락 터치(touch)는 무시하여 아래쪽 PageView가 평소처럼 손가락 스와이프로 페이지를 넘길 수 있게 해줍니다!
class StylusOnlyHitTestWrapper extends SingleChildRenderObjectWidget {
  final bool enabled;

  const StylusOnlyHitTestWrapper({
    super.key,
    required this.enabled,
    required super.child,
  });

  @override
  RenderObject createRenderObject(BuildContext context) {
    return _RenderStylusOnlyHitTestBox(enabled: enabled);
  }

  @override
  void updateRenderObject(BuildContext context, RenderObject renderObject) {
    (renderObject as _RenderStylusOnlyHitTestBox).enabled = enabled;
  }
}

class _RenderStylusOnlyHitTestBox extends RenderProxyBox {
  bool enabled;
  _RenderStylusOnlyHitTestBox({required this.enabled});

  @override
  bool hitTest(BoxHitTestResult result, {required Offset position}) {
    if (!enabled) return false;
    return super.hitTest(result, position: position);
  }

  @override
  void handleEvent(PointerEvent event, BoxHitTestEntry entry) {
    // 손가락 터치일 때는 이벤트를 가로채지 않고 패스합니다.
    if (event.kind != PointerDeviceKind.stylus &&
        event.kind != PointerDeviceKind.invertedStylus) {
      return;
    }
    super.handleEvent(event, entry);
  }
}

class _MemoCanvasPainter extends CustomPainter {
  final List<MemoStroke> strokes;
  final List<Offset> currentPoints;
  final Color currentColor;
  final double currentWidth;

  _MemoCanvasPainter({
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
  bool shouldRepaint(covariant _MemoCanvasPainter oldDelegate) => true;
}

class UniversalMediaReaderScreen extends StatefulWidget {
  final List<File> files;
  final String title;
  final bool isPdf;
  final String? customBookKey;

  const UniversalMediaReaderScreen({
    super.key,
    required this.files,
    required this.title,
    required this.isPdf,
    this.customBookKey,
  });

  @override
  State<UniversalMediaReaderScreen> createState() => _UniversalMediaReaderScreenState();
}

class _UniversalMediaReaderScreenState extends State<UniversalMediaReaderScreen> {
  static const MethodChannel _pdfChannel = MethodChannel('ebook_reader/pdf_renderer');
  PageController? _pageController;
  final VolumeKeyService _volumeKeyService = VolumeKeyService();

  List<File> _imagePages = [];
  final Map<int, Size> _pageImageSizes = {};
  bool _isPreparingPages = true;
  int _currentPage = 0;
  int _totalPages = 1;
  int? _previousJumpPage;
  bool _showControls = false;
  bool _showTranslatedBubbles = false;
  bool _isMangaRtlMode = false;
  bool _enableTwoPageInLandscape = true;
  bool _lastIsSpreadMode = false;

  bool _isTouchLocked = false;

  // 페이지 전환 설정 3가지 (음량 버튼, 페이지 이동 버튼, S펜 버튼 - 3개 동시 사용 가능)
  bool _useVolumeTurn = true;
  bool _useQuickNavTurn = false;
  bool _useSpenTurn = true;

  // 4. S펜 필기 및 지우개 모드 상태 (손가락 터치는 페이지 넘기기만 되고, 글씨 쓰기/지우기는 S펜으로만 작동)
  bool _isMemoMode = false;
  bool _isEraserMode = false;
  int? _activeStylusPointerId;
  final Map<int, List<MemoStroke>> _memoStrokesByPage = {};
  final Map<int, String> _memoNotesByPage = {};
  final List<Offset> _activeStrokePoints = [];
  Color _penColor = Colors.amber;
  final double _penWidth = 3.2;

  String _footerInfoMode = 'both';
  String _progressBarPos = 'right';

  TextRecognitionScript _selectedScript = TextRecognitionScript.japanese;
  String _sourceLangCode = 'ja';
  final Map<int, List<BubbleTranslation>> _bubblesByPage = {};

  String get _bookKey => widget.customBookKey ?? widget.files.first.path;

  @override
  void initState() {
    super.initState();
    SystemChrome.setEnabledSystemUIMode(SystemUiMode.immersiveSticky);
    _initMedia();
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
    _enableTwoPageInLandscape = await StorageService.getTwoPageLandscape();
    _isMangaRtlMode = await StorageService.getReadingDirectionRtl();
    _useVolumeTurn = await StorageService.getUseVolumeTurn();
    _useQuickNavTurn = await StorageService.getUseQuickNavTurn();
    _useSpenTurn = await StorageService.getUseSpenTurn();
    _footerInfoMode = await StorageService.getFooterInfoMode();
    _progressBarPos = await StorageService.getProgressBarPosition();

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
      _currentPage = savedPage.clamp(0, _totalPages - 1).toInt();
    }

    _pageController = PageController(initialPage: _currentPage);

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
      final strokes = await StorageService.getPageMemoStrokes(_bookKey, i);
      if (strokes.isNotEmpty) {
        _memoStrokesByPage[i] = strokes;
      }
      final note = await StorageService.getPageMemoNote(_bookKey, i);
      if (note.isNotEmpty) {
        _memoNotesByPage[i] = note;
      }
    }
    if (_bubblesByPage.isNotEmpty) {
      _showTranslatedBubbles = true;
    }

    _bindHardwareButtons();

    if (mounted) {
      setState(() => _isPreparingPages = false);
      WidgetsBinding.instance.addPostFrameCallback((_) {
        _syncControllerToCurrentPage(animate: false);
      });
    }
  }

  void _bindHardwareButtons() {
    _volumeKeyService.startListening(
      onVolumeUp: () {
        if (_useVolumeTurn) _stepPage(-1);
      },
      onVolumeDown: () {
        if (_useVolumeTurn) _stepPage(1);
      },
      onVolumeBothUnlock: _unlockTouchScreenByVolumeCombo,
      onSpenSinglePress: () {
        if (_useSpenTurn) _stepPage(1); // S펜 버튼 1번 클릭 -> 다음 페이지
      },
      onSpenDoublePress: () {
        if (_useSpenTurn) _stepPage(-1); // S펜 버튼 2번 클릭 -> 이전 페이지
      },
    );
  }

  bool _isSpreadActive(BuildContext context) {
    final size = MediaQuery.of(context).size;
    return _enableTwoPageInLandscape && size.width > size.height && _totalPages > 1;
  }

  void _syncControllerToCurrentPage({bool animate = true}) {
    final ctrl = _pageController;
    if (ctrl == null || !ctrl.hasClients) return;
    final int targetViewIdx = _lastIsSpreadMode ? (_currentPage ~/ 2) : _currentPage;
    final int currentViewIdx = (ctrl.page?.round() ?? targetViewIdx);
    if (currentViewIdx == targetViewIdx) return;

    if (animate && (targetViewIdx - currentViewIdx).abs() <= 2) {
      ctrl.animateToPage(
        targetViewIdx,
        duration: const Duration(milliseconds: 300),
        curve: Curves.easeOutCubic,
      );
    } else {
      ctrl.jumpToPage(targetViewIdx);
    }
  }

  void _stepPage(int direction) {
    final int step = _lastIsSpreadMode ? 2 : 1;
    final int target = (_currentPage + direction * step).clamp(0, _totalPages - 1).toInt();
    _goToPage(target, recordHistory: false, smoothAnimation: true);
  }

  void _goToPage(int page, {bool recordHistory = true, bool smoothAnimation = true}) {
    if (page < 0 || page >= _totalPages) return;
    if (recordHistory && (page - _currentPage).abs() > 2) {
      _previousJumpPage = _currentPage;
    }
    setState(() => _currentPage = page);
    _ensurePageDimensionLoaded(page);
    if (page + 1 < _totalPages) _ensurePageDimensionLoaded(page + 1);

    StorageService.saveLastPosition(_bookKey, page.toString());
    if (_totalPages > 0) {
      StorageService.saveProgress(_bookKey, (page + 1) / _totalPages);
    }

    final ctrl = _pageController;
    if (ctrl != null && ctrl.hasClients) {
      final int targetViewIdx = _lastIsSpreadMode ? (page ~/ 2) : page;
      final int currentViewIdx = ctrl.page?.round() ?? targetViewIdx;
      if (smoothAnimation && (targetViewIdx - currentViewIdx).abs() <= 2) {
        ctrl.animateToPage(
          targetViewIdx,
          duration: const Duration(milliseconds: 300),
          curve: Curves.easeOutCubic,
        );
      } else {
        ctrl.jumpToPage(targetViewIdx);
      }
    }
  }

  void _toggleControls() {
    if (_isTouchLocked) return;
    setState(() => _showControls = !_showControls);
    SystemChrome.setEnabledSystemUIMode(SystemUiMode.immersiveSticky);
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

  /// S펜 지우개 기능: S펜 끝이 닿은 위치(localPos) 주변의 필기 선들을 즉시 삭제!
  Future<void> _eraseStrokeAt(int pageIndex, Offset localPos, double drawWidth, double drawHeight) async {
    final strokes = _memoStrokesByPage[pageIndex];
    if (strokes == null || strokes.isEmpty || drawWidth <= 0 || drawHeight <= 0) return;

    const double hitRadius = 22.0;
    bool removedAny = false;
    final remaining = <MemoStroke>[];

    for (final s in strokes) {
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
      setState(() {
        _memoStrokesByPage[pageIndex] = remaining;
      });
      await StorageService.savePageMemoStrokes(_bookKey, pageIndex, remaining);
    }
  }

  Future<void> _showMemoTextDialog() async {
    final currentNote = _memoNotesByPage[_currentPage] ?? '';
    final ctrl = TextEditingController(text: currentNote);

    await showDialog(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text('${_currentPage + 1}페이지 메모'),
        content: TextField(
          controller: ctrl,
          maxLines: 4,
          decoration: const InputDecoration(
            hintText: 'S펜이나 키보드로 간단한 메모를 남겨보세요.',
            border: OutlineInputBorder(),
          ),
        ),
        actions: [
          if ((_memoStrokesByPage[_currentPage]?.isNotEmpty ?? false) || currentNote.isNotEmpty)
            TextButton(
              onPressed: () async {
                await StorageService.savePageMemoStrokes(_bookKey, _currentPage, []);
                await StorageService.savePageMemoNote(_bookKey, _currentPage, '');
                setState(() {
                  _memoStrokesByPage.remove(_currentPage);
                  _memoNotesByPage.remove(_currentPage);
                });
                if (ctx.mounted) Navigator.pop(ctx);
              },
              child: const Text('메모/필기 모두 지우기', style: TextStyle(color: Colors.redAccent)),
            ),
          TextButton(onPressed: () => Navigator.pop(ctx), child: const Text('취소')),
          ElevatedButton(
            onPressed: () async {
              final text = ctrl.text.trim();
              await StorageService.savePageMemoNote(_bookKey, _currentPage, text);
              setState(() {
                if (text.isEmpty) {
                  _memoNotesByPage.remove(_currentPage);
                } else {
                  _memoNotesByPage[_currentPage] = text;
                }
              });
              if (ctx.mounted) Navigator.pop(ctx);
            },
            child: const Text('저장'),
          ),
        ],
      ),
    );
  }

  /// 뷰어 표시 설정 ('화면 이동 버튼' -> '페이지 이동 버튼' 문구 수정 반영)
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

  Future<void> _showLanguageAndTranslateDialog({bool forceRetranslate = false}) async {
    if (!mounted) return;
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (ctx) => StatefulBuilder(
        builder: (ctx, setModalState) => AlertDialog(
          title: const Text('번역'),
          content: SingleChildScrollView(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                const Text('원문 언어를 선택하세요', style: TextStyle(fontSize: 13)),
                const SizedBox(height: 8),
                DropdownButton<String>(
                  isExpanded: true,
                  value: _sourceLangCode,
                  items: const [
                    DropdownMenuItem(value: 'ja', child: Text('일본어')),
                    DropdownMenuItem(value: 'en', child: Text('영어')),
                    DropdownMenuItem(value: 'zh-cn', child: Text('중국어')),
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
              ],
            ),
          ),
          actions: [
            TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text('취소')),
            ElevatedButton(
              onPressed: () => Navigator.pop(ctx, true),
              child: const Text('번역 시작'),
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
        const SnackBar(content: Text('번역이 완료되었습니다.')),
      );
    }
  }

  Widget _buildFittedHorizontalKoreanText(BubbleTranslation b, double boxW, double boxH) {
    final double safeW = math.max<double>(14.0, boxW - 3.0);
    final double safeH = math.max<double>(12.0, boxH - 2.0);
    final double area = safeW * safeH;
    final double estFont = math
        .sqrt(area / math.max<double>(1.0, b.translatedText.length * 1.55))
        .clamp(6.5, 22.0)
        .toDouble();

    final Color textColor = b.isDarkBg ? Colors.white : const Color(0xFF111111);

    return FittedBox(
      fit: BoxFit.scaleDown,
      alignment: Alignment.center,
      child: ConstrainedBox(
        constraints: BoxConstraints(maxWidth: safeW),
        child: Text(
          b.translatedText,
          textAlign: TextAlign.center,
          softWrap: true,
          style: TextStyle(
            color: textColor,
            fontSize: estFont,
            fontWeight: b.isBold ? FontWeight.w800 : FontWeight.w600,
            fontFamily: b.isSerif ? 'serif' : 'sans-serif',
            height: 1.18,
            letterSpacing: -0.2,
          ),
        ),
      ),
    );
  }

  Widget _buildSinglePagePanel(int pageIndex) {
    if (pageIndex < 0 || pageIndex >= _imagePages.length) {
      return const SizedBox.expand();
    }

    final bubbles = _bubblesByPage[pageIndex] ?? [];
    final strokes = _memoStrokesByPage[pageIndex] ?? [];
    final memoNote = _memoNotesByPage[pageIndex] ?? '';
    final imgSize = _pageImageSizes[pageIndex];

    return LayoutBuilder(
      builder: (context, constraints) {
        double drawLeft = 0.0;
        double drawTop = 0.0;
        double drawWidth = constraints.maxWidth;
        double drawHeight = constraints.maxHeight;

        if (imgSize != null && imgSize.width > 0 && imgSize.height > 0) {
          final fitted = applyBoxFit(BoxFit.contain, imgSize, constraints.biggest);
          drawWidth = fitted.destination.width;
          drawHeight = fitted.destination.height;
          drawLeft = (constraints.maxWidth - drawWidth) / 2.0;
          drawTop = (constraints.maxHeight - drawHeight) / 2.0;
        } else {
          _ensurePageDimensionLoaded(pageIndex);
        }

        return Stack(
          fit: StackFit.expand,
          children: [
            Image.file(
              _imagePages[pageIndex],
              fit: BoxFit.contain,
              width: constraints.maxWidth,
              height: constraints.maxHeight,
            ),
            if (_showTranslatedBubbles && bubbles.isNotEmpty)
              ...bubbles.map((b) {
                final double boxW = (b.widthRatio * drawWidth).clamp(12.0, drawWidth).toDouble();
                final double boxH = (b.heightRatio * drawHeight).clamp(12.0, drawHeight).toDouble();
                final double boxLeft = (drawLeft + b.leftRatio * drawWidth).clamp(
                  drawLeft,
                  math.max<double>(drawLeft, drawLeft + drawWidth - boxW),
                ).toDouble();
                final double boxTop = (drawTop + b.topRatio * drawHeight).clamp(
                  drawTop,
                  math.max<double>(drawTop, drawTop + drawHeight - boxH),
                ).toDouble();

                final Color bgColor = b.isDarkBg
                    ? const Color(0xFF121212).withOpacity(0.95)
                    : Colors.white.withOpacity(0.96);

                return Positioned(
                  left: boxLeft,
                  top: boxTop,
                  width: boxW,
                  height: boxH,
                  child: Container(
                    padding: const EdgeInsets.symmetric(horizontal: 2.0, vertical: 1.0),
                    decoration: BoxDecoration(
                      color: bgColor,
                      borderRadius: BorderRadius.circular(4.0),
                    ),
                    alignment: Alignment.center,
                    clipBehavior: Clip.hardEdge,
                    child: _buildFittedHorizontalKoreanText(b, boxW, boxH),
                  ),
                );
              }),

            // 4. S펜 전용 필기 및 지우개 레이어:
            // StylusOnlyHitTestWrapper를 통해 손가락 터치는 PageView(페이지 넘기기)로 그대로 통과시키고,
            // 오직 S펜(stylus / invertedStylus)으로 터치할 때만 글씨 쓰기 또는 지우개가 작동합니다!
            if (strokes.isNotEmpty || (_isMemoMode && pageIndex == _currentPage))
              Positioned(
                left: drawLeft,
                top: drawTop,
                width: drawWidth,
                height: drawHeight,
                child: StylusOnlyHitTestWrapper(
                  enabled: _isMemoMode && pageIndex == _currentPage,
                  // GestureDetector(supportedDevices: stylus)가 GestureArena를 독점하여 S펜 필기 중에는 S펜으로 페이지가 절대 넘어가지 않게 차단! (손가락 스와이프는 그대로 페이지 이동 가능)
                  child: GestureDetector(
                    behavior: HitTestBehavior.opaque,
                    supportedDevices: const {
                      PointerDeviceKind.stylus,
                      PointerDeviceKind.invertedStylus,
                    },
                    onPanStart: (_) {},
                    onPanUpdate: (_) {},
                    onPanEnd: (_) {},
                    child: Listener(
                      behavior: HitTestBehavior.opaque,
                    onPointerDown: (event) {
                      if (!_isMemoMode || pageIndex != _currentPage) return;
                      if (event.kind != PointerDeviceKind.stylus &&
                          event.kind != PointerDeviceKind.invertedStylus) {
                        return;
                      }
                      _activeStylusPointerId = event.pointer;
                      final bool useEraser =
                          _isEraserMode || event.kind == PointerDeviceKind.invertedStylus;
                      if (useEraser) {
                        _eraseStrokeAt(pageIndex, event.localPosition, drawWidth, drawHeight);
                      } else {
                        setState(() {
                          _activeStrokePoints
                            ..clear()
                            ..add(event.localPosition);
                        });
                      }
                    },
                    onPointerMove: (event) {
                      if (!_isMemoMode ||
                          pageIndex != _currentPage ||
                          event.pointer != _activeStylusPointerId) {
                        return;
                      }
                      final bool useEraser =
                          _isEraserMode || event.kind == PointerDeviceKind.invertedStylus;
                      if (useEraser) {
                        _eraseStrokeAt(pageIndex, event.localPosition, drawWidth, drawHeight);
                      } else {
                        setState(() {
                          _activeStrokePoints.add(event.localPosition);
                        });
                      }
                    },
                    onPointerUp: (event) async {
                      if (!_isMemoMode ||
                          pageIndex != _currentPage ||
                          event.pointer != _activeStylusPointerId) {
                        return;
                      }
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
                        final list = List<MemoStroke>.from(_memoStrokesByPage[pageIndex] ?? [])
                          ..add(stroke);
                        setState(() {
                          _memoStrokesByPage[pageIndex] = list;
                          _activeStrokePoints.clear();
                        });
                        await StorageService.savePageMemoStrokes(_bookKey, pageIndex, list);
                      }
                    },
                    onPointerCancel: (_) {
                      _activeStylusPointerId = null;
                      setState(() => _activeStrokePoints.clear());
                    },
                      child: CustomPaint(
                        painter: _MemoCanvasPainter(
                          strokes: strokes,
                          currentPoints: pageIndex == _currentPage ? _activeStrokePoints : const [],
                          currentColor: _penColor,
                          currentWidth: _penWidth,
                        ),
                      ),
                    ),
                  ),
                ),
              ),

            if (memoNote.isNotEmpty)
              Positioned(
                left: drawLeft + 12.0,
                top: drawTop + 12.0,
                child: GestureDetector(
                  onTap: _showMemoTextDialog,
                  child: Container(
                    constraints: const BoxConstraints(maxWidth: 220),
                    padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
                    decoration: BoxDecoration(
                      color: Colors.amber.shade200.withOpacity(0.95),
                      borderRadius: BorderRadius.circular(8),
                      boxShadow: const [BoxShadow(color: Colors.black38, blurRadius: 4)],
                    ),
                    child: Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        const Icon(Icons.edit_note, size: 16, color: Colors.black87),
                        const SizedBox(width: 4),
                        Flexible(
                          child: Text(
                            memoNote,
                            style: const TextStyle(color: Colors.black87, fontSize: 12),
                            maxLines: 3,
                            overflow: TextOverflow.ellipsis,
                          ),
                        ),
                      ],
                    ),
                  ),
                ),
              ),
          ],
        );
      },
    );
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

  String _formatFooterText(bool isSpread) {
    if (_footerInfoMode == 'none') return '';
    final double progPercent = _totalPages > 0 ? ((_currentPage + 1) / _totalPages * 100.0).clamp(0.0, 100.0).toDouble() : 0.0;
    final String progStr = '${progPercent.toStringAsFixed(1)}%';
    final String pageStr = isSpread && (_currentPage + 1 < _totalPages)
        ? '${_currentPage + 1}-${_currentPage + 2} / $_totalPages'
        : '${_currentPage + 1} / $_totalPages';

    if (_footerInfoMode == 'progress') {
      return progStr;
    } else if (_footerInfoMode == 'page') {
      return pageStr;
    } else {
      return '$progStr  |  $pageStr';
    }
  }

  Widget _buildProgressControlBar() {
    if (!_showControls || _isTouchLocked || _totalPages <= 1 || _progressBarPos == 'hidden') {
      return const Positioned(
        key: ValueKey('progress_bar_hidden'),
        left: 0,
        bottom: 0,
        width: 0,
        height: 0,
        child: SizedBox.shrink(),
      );
    }

    final double sliderVal = _currentPage.toDouble().clamp(0.0, math.max<double>(0.0, (_totalPages - 1).toDouble())).toDouble();
    final double sliderMax = math.max<double>(1.0, (_totalPages - 1).toDouble());

    if (_progressBarPos == 'bottom') {
      return Positioned(
        key: const ValueKey('progress_bar_bottom'),
        left: 16.0,
        right: _useQuickNavTurn ? 116.0 : 16.0,
        bottom: 28.0,
        child: Material(
          color: Colors.black87,
          borderRadius: BorderRadius.circular(26),
          elevation: 6,
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 4),
            child: Row(
              children: [
                IconButton(
                  icon: const Icon(Icons.chevron_left, color: Colors.white),
                  onPressed: () => _stepPage(-1),
                ),
                Expanded(
                  child: Slider(
                    value: sliderVal,
                    min: 0.0,
                    max: sliderMax,
                    onChanged: (v) => _goToPage(v.round(), smoothAnimation: false),
                  ),
                ),
                Text(
                  '${_currentPage + 1}/$_totalPages',
                  style: const TextStyle(color: Colors.white, fontSize: 11, fontWeight: FontWeight.bold),
                ),
                IconButton(
                  icon: const Icon(Icons.chevron_right, color: Colors.white),
                  onPressed: () => _stepPage(1),
                ),
              ],
            ),
          ),
        ),
      );
    }

    return Positioned(
      key: ValueKey('progress_bar_$_progressBarPos'),
      top: 72.0,
      bottom: _useQuickNavTurn && _progressBarPos == 'right' ? 84.0 : 48.0,
      left: _progressBarPos == 'left' ? 8.0 : null,
      right: _progressBarPos == 'right' ? 8.0 : null,
      width: 52.0,
      child: Material(
        color: Colors.black87,
        borderRadius: BorderRadius.circular(26),
        elevation: 6,
        child: Padding(
          padding: const EdgeInsets.symmetric(vertical: 8),
          child: Column(
            children: [
              IconButton(
                icon: const Icon(Icons.expand_less, color: Colors.white, size: 22),
                padding: EdgeInsets.zero,
                constraints: const BoxConstraints(minWidth: 36, minHeight: 36),
                onPressed: () => _stepPage(-1),
              ),
              Expanded(
                child: RotatedBox(
                  quarterTurns: 1,
                  child: Slider(
                    value: sliderVal,
                    min: 0.0,
                    max: sliderMax,
                    onChanged: (v) => _goToPage(v.round(), smoothAnimation: false),
                  ),
                ),
              ),
              Text(
                '${_currentPage + 1}/$_totalPages',
                style: const TextStyle(color: Colors.white, fontSize: 10, fontWeight: FontWeight.bold),
              ),
              IconButton(
                icon: const Icon(Icons.expand_more, color: Colors.white, size: 22),
                padding: EdgeInsets.zero,
                constraints: const BoxConstraints(minWidth: 36, minHeight: 36),
                onPressed: () => _stepPage(1),
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
                onPressed: () => _stepPage(-1),
              ),
              Container(width: 1, height: 22, color: Colors.white24),
              IconButton(
                icon: const Icon(Icons.arrow_downward, color: Colors.amber, size: 22),
                tooltip: '다음 페이지',
                constraints: const BoxConstraints(minWidth: 40, minHeight: 40),
                padding: EdgeInsets.zero,
                onPressed: () => _stepPage(1),
              ),
            ],
          ),
        ),
      ),
    );
  }

  @override
  void dispose() {
    _volumeKeyService.stopListening();
    _pageController?.dispose();
    SystemChrome.setEnabledSystemUIMode(
      SystemUiMode.manual,
      overlays: SystemUiOverlay.values,
    );
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    if (_isPreparingPages || _pageController == null) {
      return const Scaffold(
        backgroundColor: Colors.black,
        body: Center(
          child: CircularProgressIndicator(color: Colors.amber),
        ),
      );
    }

    final mediaQuery = MediaQuery.of(context);
    final double bottomInset = mediaQuery.viewPadding.bottom;
    final bool isSpread = _isSpreadActive(context);

    if (isSpread != _lastIsSpreadMode) {
      _lastIsSpreadMode = isSpread;
      final int targetViewIdx = isSpread ? (_currentPage ~/ 2) : _currentPage;
      _pageController?.dispose();
      _pageController = PageController(initialPage: targetViewIdx);
    }

    final int viewItemCount = isSpread ? ((_totalPages + 1) ~/ 2) : _totalPages;
    final String footerText = _formatFooterText(isSpread);

    return Scaffold(
      backgroundColor: Colors.black,
      body: Stack(
        children: [
          Positioned.fill(
            child: AbsorbPointer(
              absorbing: _isTouchLocked,
              child: GestureDetector(
                onTap: _toggleControls,
                child: PageView.builder(
                  key: ValueKey('pageview_spread_$isSpread'),
                  controller: _pageController,
                  reverse: _isMangaRtlMode,
                  // 4. S펜 필기 모드(_isMemoMode)가 켜져 있어도 손가락 스와이프로는 페이지를 넘길 수 있도록 BouncingScrollPhysics 유지!
                  physics: _isTouchLocked
                      ? const NeverScrollableScrollPhysics()
                      : const BouncingScrollPhysics(),
                  itemCount: viewItemCount,
                  onPageChanged: (viewIdx) {
                    final int actualPage = isSpread ? (viewIdx * 2) : viewIdx;
                    setState(() => _currentPage = actualPage);
                    _ensurePageDimensionLoaded(actualPage);
                    if (actualPage + 1 < _totalPages) _ensurePageDimensionLoaded(actualPage + 1);
                    StorageService.saveLastPosition(_bookKey, actualPage.toString());
                    StorageService.saveProgress(_bookKey, (actualPage + 1) / _totalPages);
                  },
                  itemBuilder: (context, viewIdx) {
                    if (!isSpread) {
                      return InteractiveViewer(
                        panEnabled: !_isMemoMode,
                        scaleEnabled: !_isMemoMode,
                        minScale: 1.0,
                        maxScale: 3.5,
                        child: _buildSinglePagePanel(viewIdx),
                      );
                    }

                    final int firstPage = viewIdx * 2;
                    final int secondPage = firstPage + 1;
                    final Widget leftPanel = _isMangaRtlMode
                        ? (secondPage < _totalPages ? _buildSinglePagePanel(secondPage) : const SizedBox.expand())
                        : _buildSinglePagePanel(firstPage);
                    final Widget rightPanel = _isMangaRtlMode
                        ? _buildSinglePagePanel(firstPage)
                        : (secondPage < _totalPages ? _buildSinglePagePanel(secondPage) : const SizedBox.expand());

                    return InteractiveViewer(
                      panEnabled: !_isMemoMode,
                      scaleEnabled: !_isMemoMode,
                      minScale: 1.0,
                      maxScale: 3.5,
                      child: Row(
                        children: [
                          Expanded(child: leftPanel),
                          Container(width: 1, color: Colors.white12),
                          Expanded(child: rightPanel),
                        ],
                      ),
                    );
                  },
                ),
              ),
            ),
          ),

          if (footerText.isNotEmpty)
            Positioned(
              left: 20,
              right: 20,
              bottom: math.max<double>(bottomInset + 4.0, 8.0),
              child: IgnorePointer(
                child: Align(
                  alignment: Alignment.centerRight,
                  child: Text(
                    footerText,
                    style: const TextStyle(
                      color: Colors.white70,
                      fontSize: 12,
                      shadows: [Shadow(color: Colors.black, blurRadius: 4)],
                    ),
                  ),
                ),
              ),
            ),

          // 4. S펜 필기 모드 상단 미니 툴바 (펜 색상 선택 + 지우개 버튼 추가!)
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
                          // 지우개 토글 버튼
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
                            onPressed: _showMemoTextDialog,
                          ),
                          IconButton(
                            icon: const Icon(Icons.delete_sweep_outlined, color: Colors.redAccent, size: 18),
                            tooltip: '현재 페이지 필기 전체 지우기',
                            onPressed: () async {
                              setState(() => _memoStrokesByPage.remove(_currentPage));
                              await StorageService.savePageMemoStrokes(_bookKey, _currentPage, []);
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
                      Expanded(
                        child: Text(
                          widget.title,
                          style: const TextStyle(color: Colors.white, fontSize: 14),
                          overflow: TextOverflow.ellipsis,
                        ),
                      ),
                      if (_previousJumpPage != null)
                        IconButton(
                          icon: const Icon(Icons.restore, color: Colors.amber, size: 20),
                          tooltip: '이전 페이지로 돌아가기',
                          onPressed: () {
                            final target = _previousJumpPage!;
                            _previousJumpPage = null;
                            _goToPage(target, recordHistory: false, smoothAnimation: true);
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
                          setState(() => _enableTwoPageInLandscape = nextVal);
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
                      GestureDetector(
                        onLongPress: () => _showLanguageAndTranslateDialog(forceRetranslate: true),
                        child: IconButton(
                          icon: Icon(
                            _showTranslatedBubbles ? Icons.chat_bubble : Icons.translate,
                            color: _showTranslatedBubbles ? Colors.amber : Colors.white,
                            size: 20,
                          ),
                          tooltip: '번역',
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
                          icon: const Icon(Icons.refresh, color: Colors.white70, size: 19),
                          tooltip: '다시 번역',
                          onPressed: () => _showLanguageAndTranslateDialog(forceRetranslate: true),
                        ),
                      IconButton(
                        icon: const Icon(Icons.bookmarks_outlined, color: Colors.white, size: 20),
                        tooltip: '북마크',
                        onPressed: _showBookmarkSheet,
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

          _buildProgressControlBar(),

          if (_useQuickNavTurn && !_isTouchLocked && _totalPages > 1)
            _buildQuickNavButtons(bottomInset),
        ],
      ),
    );
  }
}
