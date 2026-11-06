import 'dart:async';
import 'dart:io';
import 'dart:math' as math;
import 'dart:ui' as ui;
import 'package:archive/archive.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:google_mlkit_text_recognition/google_mlkit_text_recognition.dart';
import 'package:path_provider/path_provider.dart';
import '../services/batch_translation_service.dart';
import '../services/storage_service.dart';
import '../services/volume_key_service.dart';
import '../services/txt_to_epub_converter.dart';
import 'reader_screen.dart';

/// 1. S펜 전용 즉시 승리 제스처 인식기 (Eager Stylus Gesture Recognizer):
/// S펜(stylus / invertedStylus)이 화면에 닿는 순간(PointerDown) 즉시 GestureArena에서 승리(accepted)를 선언하여
/// 하위 PageView나 InteractiveViewer, WebView가 S펜 움직임으로 화면을 흔들거나 페이지를 넘기는 것을 100% 원천 차단합니다!
/// 반면 일반 손가락 터치(PointerDeviceKind.touch)는 아예 거부(isPointerAllowed = false)하므로 손가락 스와이프로는 평소처럼 페이지가 부드럽게 넘어갑니다!
class EagerStylusPanGestureRecognizer extends OneSequenceGestureRecognizer {
  bool allowTouch = false;
  void Function(PointerDownEvent event)? onStylusDown;
  void Function(PointerMoveEvent event)? onStylusMove;
  void Function(PointerUpEvent event)? onStylusUp;
  void Function(PointerCancelEvent event)? onStylusCancel;

  @override
  bool isPointerAllowed(PointerDownEvent event) {
    if (allowTouch &&
        (event.kind == PointerDeviceKind.touch ||
            event.kind == PointerDeviceKind.mouse)) {
      return true;
    }
    return event.kind == PointerDeviceKind.stylus ||
        event.kind == PointerDeviceKind.invertedStylus;
  }

  @override
  void addAllowedPointer(PointerDownEvent event) {
    startTrackingPointer(event.pointer, event.transform);
    // 핵심: S펜이 닿자마자 제스처 아레나를 즉시 독점(accepted)하여 화면 이동/페이지 넘김을 0픽셀도 허용하지 않음!
    resolve(GestureDisposition.accepted);
    onStylusDown?.call(event);
  }

  @override
  void handleEvent(PointerEvent event) {
    if (event is PointerMoveEvent) {
      onStylusMove?.call(event);
    } else if (event is PointerUpEvent) {
      onStylusUp?.call(event);
      stopTrackingPointer(event.pointer);
    } else if (event is PointerCancelEvent) {
      onStylusCancel?.call(event);
      stopTrackingPointer(event.pointer);
    }
  }

  @override
  String get debugDescription => 'eager_stylus_pan';

  @override
  void didStopTrackingLastPointer(int pointer) {}
}

class StylusOnlyDrawingLayer extends StatelessWidget {
  final bool enabled;
  final bool allowTouch;
  final void Function(PointerDownEvent event) onStylusDown;
  final void Function(PointerMoveEvent event) onStylusMove;
  final void Function(PointerUpEvent event) onStylusUp;
  final void Function(PointerCancelEvent event) onStylusCancel;
  final Widget child;

  const StylusOnlyDrawingLayer({
    super.key,
    required this.enabled,
    this.allowTouch = false,
    required this.onStylusDown,
    required this.onStylusMove,
    required this.onStylusUp,
    required this.onStylusCancel,
    required this.child,
  });

  @override
  Widget build(BuildContext context) {
    if (!enabled) {
      return IgnorePointer(child: child);
    }
    return RawGestureDetector(
      behavior: HitTestBehavior.translucent,
      gestures: <Type, GestureRecognizerFactory>{
        EagerStylusPanGestureRecognizer:
            GestureRecognizerFactoryWithHandlers<EagerStylusPanGestureRecognizer>(
          () => EagerStylusPanGestureRecognizer(),
          (EagerStylusPanGestureRecognizer instance) {
            instance
              ..allowTouch = allowTouch
              ..onStylusDown = onStylusDown
              ..onStylusMove = onStylusMove
              ..onStylusUp = onStylusUp
              ..onStylusCancel = onStylusCancel;
          },
        ),
      },
      child: child,
    );
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

class _UniversalMediaReaderScreenState extends State<UniversalMediaReaderScreen> with WidgetsBindingObserver {
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
  bool _useShakeLock = true;
  bool _useVolumeComboLock = true;

  bool _useVolumeTurn = true;
  bool _useQuickNavTurn = false;
  bool _useSpenTurn = true;

  bool _isMemoMode = false;
  bool _isEraserMode = false;
  bool _allowFingerDrawing = false;
  bool _isStylusDown = false;
  int _activeDrawingPageIndex = 0;
  final Map<int, List<MemoStroke>> _memoStrokesByPage = {};
  final Map<int, String> _memoNotesByPage = {};
  final List<Offset> _activeStrokePoints = [];
  Color _penColor = Colors.amber;
  double _penWidth = 2.0;

  String _footerInfoMode = 'both';
  String _progressBarPos = 'right';

  TextRecognitionScript _selectedScript = TextRecognitionScript.japanese;
  String _sourceLangCode = 'ja';
  final Map<int, List<BubbleTranslation>> _bubblesByPage = {};

  String get _bookKey => widget.customBookKey ?? widget.files.first.path;

  String _tr(String ko, String en, String zh, String ja) =>
      AppI18n.t(StorageService.appLangNotifier.value, ko: ko, en: en, zh: zh, ja: ja);

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    SystemChrome.setEnabledSystemUIMode(SystemUiMode.immersiveSticky);
    BatchTranslationService.translationCompletedEvent.addListener(_onBackgroundTranslationFinished);
    _initMedia();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (_isTouchLocked &&
        (state == AppLifecycleState.paused ||
            state == AppLifecycleState.inactive ||
            state == AppLifecycleState.detached ||
            state == AppLifecycleState.hidden)) {
      setState(() => _isTouchLocked = false);
    }
  }

  void _onBackgroundTranslationFinished() {
    _reloadBubbleCachesFromStorage();
  }

  Future<void> _reloadBubbleCachesFromStorage() async {
    bool foundAny = false;
    for (int i = 0; i < _imagePages.length; i++) {
      final cached = await StorageService.getImageBubbleCache(_bookKey, i);
      if (cached != null) {
        _bubblesByPage[i] = cached;
        if (cached.isNotEmpty) foundAny = true;
      }
    }
    if (mounted && foundAny) {
      setState(() => _showTranslatedBubbles = true);
    }
  }

  void _toggleTouchScreenLock({required bool byVolume}) {
    if (!mounted) return;
    if (byVolume && !_useVolumeComboLock) return;
    if (!byVolume && !_useShakeLock) return;

    final nextLocked = !_isTouchLocked;
    setState(() {
      _isTouchLocked = nextLocked;
      if (nextLocked) {
        _showControls = false;
        _isMemoMode = false;
        _isStylusDown = false;
      }
    });
    ScaffoldMessenger.of(context).clearSnackBars();
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(
          nextLocked
              ? (byVolume ? '음량 버튼 동시 입력으로 화면이 잠겼습니다.' : '흔들기 감지로 화면이 잠겼습니다.')
              : (byVolume ? '음량 버튼 동시 입력으로 화면 잠금이 해제되었습니다.' : '흔들기 감지로 화면 잠금이 해제되었습니다.'),
        ),
        duration: const Duration(seconds: 1),
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

  /// 8. 같은 그룹 내의 이전(step: -1) 또는 다음(step: 1) 파일로 즉시 이동
  Future<void> _openAdjacentFileInSameGroup(int step) async {
    final currentPath = widget.files.first.path;
    final currentGroup = await StorageService.getBookGroup(currentPath);
    final favs = await StorageService.getFavoriteBooks();
    final dir = await getApplicationDocumentsDirectory();
    const supportedExts = [
      'epub', 'txt', 'pdf', 'jpg', 'jpeg', 'png', 'webp', 'cbz',
      'docx', 'doc', 'hwpx', 'hwp'
    ];
    const imageExts = ['jpg', 'jpeg', 'png', 'webp'];
    const docConvertExts = ['txt', 'docx', 'doc', 'hwpx', 'hwp'];

    final allFiles = <File>[];
    for (final e in dir.listSync()) {
      if (e is File) {
        final lower = e.path.toLowerCase();
        if (lower.endsWith('_translated.epub') || lower.endsWith('.converted.epub')) continue;
        final ext = lower.split('.').last;
        if (supportedExts.contains(ext)) {
          final grp = await StorageService.getBookGroup(e.path);
          if (grp == currentGroup) {
            allFiles.add(e);
          }
        }
      }
    }

    allFiles.sort((a, b) {
      final aFav = favs.contains(a.path);
      final bFav = favs.contains(b.path);
      if (aFav != bFav) return aFav ? -1 : 1;
      return _naturalCompare(
        a.path.split(Platform.pathSeparator).last,
        b.path.split(Platform.pathSeparator).last,
      );
    });

    final currentPathsSet = widget.files.map((f) => f.path).toSet();
    final curIdx = allFiles.indexWhere((f) => f.path == currentPath);
    if (curIdx == -1 || allFiles.length <= currentPathsSet.length) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text('현재 그룹("$currentGroup")에 이동할 다른 파일이 없습니다.'),
            duration: const Duration(seconds: 1),
          ),
        );
      }
      return;
    }

    File? targetFile;
    for (int i = 1; i < allFiles.length; i++) {
      final idx = (curIdx + step * i + allFiles.length * 10) % allFiles.length;
      final candidate = allFiles[idx];
      if (!currentPathsSet.contains(candidate.path)) {
        targetFile = candidate;
        break;
      }
    }

    if (targetFile == null || !mounted) return;

    final nextName = targetFile.path.split(Platform.pathSeparator).last;
    final nextExt = nextName.split('.').last.toLowerCase();

    ScaffoldMessenger.of(context).clearSnackBars();
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text('${step < 0 ? "이전" : "다음"} 파일 열기: $nextName'),
        duration: const Duration(milliseconds: 900),
      ),
    );

    if (nextExt == 'epub') {
      Navigator.pushReplacement(
        context,
        MaterialPageRoute(
          builder: (_) => ReaderScreen(filePath: targetFile!.path, bookTitle: nextName),
        ),
      );

    } else if (docConvertExts.contains(nextExt)) {
      final epubFile = await TxtToEpubConverter.convertDocumentToEpub(targetFile);
      if (!mounted) return;
      Navigator.pushReplacement(
        context,
        MaterialPageRoute(
          builder: (_) => ReaderScreen(filePath: epubFile.path, bookTitle: nextName),
        ),
      );
    } else if (nextExt == 'pdf') {
      Navigator.pushReplacement(
        context,
        MaterialPageRoute(
          builder: (_) => UniversalMediaReaderScreen(
            files: [targetFile!],
            title: nextName,
            isPdf: true,
          ),
        ),
      );
    } else if (imageExts.contains(nextExt)) {
      final siblingImages = allFiles.where((f) {
        final fExt = f.path.split('.').last.toLowerCase();
        return imageExts.contains(fExt);
      }).toList();
      final targetList = siblingImages.length > 1 ? siblingImages : [targetFile];
      final bookKey = targetList.first.path;
      final clickedIdx = targetList.indexWhere((f) => f.path == targetFile!.path);
      if (clickedIdx >= 0) {
        await StorageService.saveLastPosition(bookKey, clickedIdx.toString());
      }
      if (!mounted) return;
      Navigator.pushReplacement(
        context,
        MaterialPageRoute(
          builder: (_) => UniversalMediaReaderScreen(
            files: targetList,
            title: targetList.length > 1 ? '$nextName 외 ${targetList.length - 1}장' : nextName,
            isPdf: false,
            customBookKey: bookKey,
          ),
        ),
      );
    } else {
      Navigator.pushReplacement(
        context,
        MaterialPageRoute(
          builder: (_) => UniversalMediaReaderScreen(
            files: [targetFile!],
            title: nextName,
            isPdf: false,
          ),
        ),
      );
    }
  }

  Future<void> _initMedia() async {
    try {
      _enableTwoPageInLandscape = await StorageService.getTwoPageLandscape();
      _isMangaRtlMode = await StorageService.getReadingDirectionRtl();
      _useShakeLock = await StorageService.getUseShakeLock();
      _useVolumeComboLock = await StorageService.getUseVolumeComboLock();
      _useVolumeTurn = await StorageService.getUseVolumeTurn();
      _useQuickNavTurn = await StorageService.getUseQuickNavTurn();
      _useSpenTurn = await StorageService.getUseSpenTurn();
      _footerInfoMode = await StorageService.getFooterInfoMode();
      _progressBarPos = await StorageService.getProgressBarPosition();

      final tempDir = await getTemporaryDirectory();
      final first = widget.files.first;
      final lower = first.path.toLowerCase();
      final int safeFileLen = await first.exists() ? await first.length() : 0;
      final String safeHashKey = '${first.path.hashCode.abs()}_$safeFileLen';

      if (widget.isPdf || lower.endsWith('.pdf')) {
        final outDir = Directory('${tempDir.path}/pdf_$safeHashKey');
        final List<dynamic>? renderedPaths = await _pdfChannel.invokeMethod('renderPdfToImages', {
          'pdfPath': first.path,
          'outDirPath': outDir.path,
        });
        if (renderedPaths != null) {
          _imagePages = renderedPaths.map((p) => File(p.toString())).toList();
        }
      } else if (lower.endsWith('.cbz')) {
        final bytes = await first.readAsBytes();
        final archive = ZipDecoder().decodeBytes(bytes);
        final extractDir = Directory('${tempDir.path}/cbz_$safeHashKey');
        await extractDir.create(recursive: true);
        final extracted = <File>[];
        int idx = 0;
        for (final f in archive.files) {
          final lowerName = f.name.toLowerCase();
          if (f.isFile &&
              !lowerName.contains('__macosx') &&
              !f.name.split('/').last.startsWith('._') &&
              (lowerName.endsWith('.jpg') ||
                  lowerName.endsWith('.jpeg') ||
                  lowerName.endsWith('.png') ||
                  lowerName.endsWith('.webp'))) {
            final ext = lowerName.split('.').last;
            final safeEntryName = 'img_${idx.toString().padLeft(4, '0')}_${f.name.split('/').last.replaceAll(RegExp(r'[^a-zA-Z0-9._-]'), '_')}.$ext';
            final outFile = File('${extractDir.path}/$safeEntryName');
            if (!await outFile.exists() || await outFile.length() == 0) {
              await outFile.writeAsBytes(f.content as List<int>);
            }
            extracted.add(outFile);
            idx++;
          }
        }
        extracted.sort((a, b) => _naturalCompare(
              a.path.split(Platform.pathSeparator).last,
              b.path.split(Platform.pathSeparator).last,
            ));
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

      _bindHardwareButtons();
    } catch (e) {
      _pageController ??= PageController(initialPage: 0);
    } finally {
      if (mounted) {
        setState(() => _isPreparingPages = false);
        WidgetsBinding.instance.addPostFrameCallback((_) {
          _syncControllerToCurrentPage(animate: false);
        });
      }
    }

    // 캐시 및 필기 데이터 비동기 로드
    bool anyBubbles = false;
    for (int i = 0; i < _imagePages.length; i++) {
      final cached = await StorageService.getImageBubbleCache(_bookKey, i);
      if (cached != null) {
        _bubblesByPage[i] = cached;
        if (cached.isNotEmpty) anyBubbles = true;
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
    if (mounted && (anyBubbles || _memoStrokesByPage.isNotEmpty || _memoNotesByPage.isNotEmpty)) {
      setState(() {
        if (anyBubbles) _showTranslatedBubbles = true;
      });
    }
  }

  /// 2 & 5. S펜 버튼 1번 클릭(다음 페이지) / 2번 클릭(이전 페이지) 딜레이 0초 초고속 전환!
  void _bindHardwareButtons() {
    _volumeKeyService.startListening(
      onVolumeUp: () {
        if (_useVolumeTurn) _stepPage(-1);
      },
      onVolumeDown: () {
        if (_useVolumeTurn) _stepPage(1);
      },
      onVolumeBothUnlock: () => _toggleTouchScreenLock(byVolume: true),
      onShakeToggle: () => _toggleTouchScreenLock(byVolume: false),
      onSpenSinglePress: () {
        if (_useSpenTurn) _stepPage(1, fastResponse: true);
      },
      onSpenDoublePress: () {
        if (_useSpenTurn) _stepPage(-1, fastResponse: true);
      },
      onSpenDoubleRevert: () {
        // 1번 클릭으로 즉시 1페이지 앞으로 갔던 것을 취소하고 원래 페이지 기준 이전 페이지(-2)로 즉시 이동!
        if (_useSpenTurn) _stepPage(-2, fastResponse: true);
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
        duration: const Duration(milliseconds: 220),
        curve: Curves.easeOutCubic,
      );
    } else {
      ctrl.jumpToPage(targetViewIdx);
    }
  }

  void _stepPage(int direction, {bool fastResponse = false}) {
    final int step = _lastIsSpreadMode ? 2 : 1;
    final int target = (_currentPage + direction * step).clamp(0, _totalPages - 1).toInt();
    _goToPage(
      target,
      recordHistory: false,
      smoothAnimation: true,
      animDurationMs: fastResponse ? 140 : 250,
    );
  }

  void _goToPage(
    int page, {
    bool recordHistory = true,
    bool smoothAnimation = true,
    int animDurationMs = 250,
  }) {
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
          duration: Duration(milliseconds: animDurationMs),
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
                Text(
                  _tr('뷰어 표시 설정', 'Viewer Display Settings', '阅读器显示设置', '뷰어表示設定'),
                  style: const TextStyle(fontSize: 16, fontWeight: FontWeight.bold),
                ),
                const SizedBox(height: 12),
                Text(
                  _tr('화면 잠금 설정 (동시 사용 가능)', 'Screen Lock Settings (Multiple allowed)', '屏幕锁定设置 (可同时启用)', '画面ロック設定 (同時使用可)'),
                  style: const TextStyle(fontSize: 13, fontWeight: FontWeight.w600),
                ),
                const SizedBox(height: 6),
                Wrap(
                  spacing: 8,
                  runSpacing: 6,
                  children: [
                    FilterChip(
                      label: Text(_tr('흔들어서 잠그고 끄기', 'Shake to Lock/Unlock', '摇晃锁定/解锁', '振ってロック/解除')),
                      selected: _useShakeLock,
                      onSelected: (val) async {
                        await StorageService.setUseShakeLock(val);
                        setState(() => _useShakeLock = val);
                        setModalState(() {});
                      },
                    ),
                    FilterChip(
                      label: Text(_tr('음량 버튼 동시에 눌러서 끄고 켜기', 'Press Both Volume Keys to Lock/Unlock', '同时按音量键锁定/解锁', '音量ボタン同時押しでロック/解除')),
                      selected: _useVolumeComboLock,
                      onSelected: (val) async {
                        await StorageService.setUseVolumeComboLock(val);
                        setState(() => _useVolumeComboLock = val);
                        setModalState(() {});
                      },
                    ),
                  ],
                ),
                const Divider(height: 20),
                Text(
                  _tr('페이지 전환 설정 (동시 사용 가능)', 'Page Turn Settings (Multiple allowed)', '翻页方式设置 (可同时启用)', 'ページめくり設定 (同時使用可)'),
                  style: const TextStyle(fontSize: 13, fontWeight: FontWeight.w600),
                ),
                const SizedBox(height: 6),
                Wrap(
                  spacing: 8,
                  runSpacing: 6,
                  children: [
                    FilterChip(
                      label: Text(_tr('음량 버튼', 'Volume Keys', '音量键', '音量ボタン')),
                      selected: _useVolumeTurn,
                      onSelected: (val) async {
                        await StorageService.setUseVolumeTurn(val);
                        setState(() => _useVolumeTurn = val);
                        setModalState(() {});
                      },
                    ),
                    FilterChip(
                      label: Text(_tr('페이지 이동 버튼', 'Page Nav Buttons', '翻页按钮', 'ページ移動ボタン')),
                      selected: _useQuickNavTurn,
                      onSelected: (val) async {
                        await StorageService.setUseQuickNavTurn(val);
                        setState(() => _useQuickNavTurn = val);
                        setModalState(() {});
                      },
                    ),
                    FilterChip(
                      label: Text(_tr('S펜 버튼', 'S Pen Button', 'S Pen 按钮', 'Sペンボタン')),
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
                Text(
                  _tr('진행도 UI 위치', 'Progress Bar Position', '进度条位置', '進行度バーの位置'),
                  style: const TextStyle(fontSize: 13, fontWeight: FontWeight.w600),
                ),
                const SizedBox(height: 6),
                Wrap(
                  spacing: 8,
                  runSpacing: 6,
                  children: [
                    ChoiceChip(
                      label: Text(_tr('오른쪽', 'Right', '右侧', '右')),
                      selected: _progressBarPos == 'right',
                      onSelected: (_) async {
                        await StorageService.setProgressBarPosition('right');
                        setState(() => _progressBarPos = 'right');
                        setModalState(() {});
                      },
                    ),
                    ChoiceChip(
                      label: Text(_tr('왼쪽', 'Left', '左侧', '左')),
                      selected: _progressBarPos == 'left',
                      onSelected: (_) async {
                        await StorageService.setProgressBarPosition('left');
                        setState(() => _progressBarPos = 'left');
                        setModalState(() {});
                      },
                    ),
                    ChoiceChip(
                      label: Text(_tr('하단', 'Bottom', '底部', '下部')),
                      selected: _progressBarPos == 'bottom',
                      onSelected: (_) async {
                        await StorageService.setProgressBarPosition('bottom');
                        setState(() => _progressBarPos = 'bottom');
                        setModalState(() {});
                      },
                    ),
                    ChoiceChip(
                      label: Text(_tr('숨김', 'Hidden', '隐藏', '非表示')),
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
                Text(
                  _tr('하단 정보 표시', 'Footer Info Display', '底部信息显示', '下部情報表示'),
                  style: const TextStyle(fontSize: 13, fontWeight: FontWeight.w600),
                ),
                const SizedBox(height: 6),
                Wrap(
                  spacing: 8,
                  runSpacing: 6,
                  children: [
                    ChoiceChip(
                      label: Text(_tr('진행률', 'Progress %', '进度百分比', '進行率')),
                      selected: _footerInfoMode == 'progress',
                      onSelected: (_) async {
                        await StorageService.setFooterInfoMode('progress');
                        setState(() => _footerInfoMode = 'progress');
                        setModalState(() {});
                      },
                    ),
                    ChoiceChip(
                      label: Text(_tr('페이지 번호', 'Page Number', '页码', 'ページ番号')),
                      selected: _footerInfoMode == 'page',
                      onSelected: (_) async {
                        await StorageService.setFooterInfoMode('page');
                        setState(() => _footerInfoMode = 'page');
                        setModalState(() {});
                      },
                    ),
                    ChoiceChip(
                      label: Text(_tr('진행률 및 페이지 번호', 'Both Progress & Page', '进度与页码', '進行率とページ番号')),
                      selected: _footerInfoMode == 'both',
                      onSelected: (_) async {
                        await StorageService.setFooterInfoMode('both');
                        setState(() => _footerInfoMode = 'both');
                        setModalState(() {});
                      },
                    ),
                    ChoiceChip(
                      label: Text(_tr('정보 표시 없음', 'None', '不显示', '表示なし')),
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
    if (BatchTranslationService.isBookTranslating(_bookKey)) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('현재 백그라운드에서 번역이 진행 중입니다.')),
      );
      return;
    }

    final targetLang = await StorageService.getAppLanguage();
    final targetLangLabels = {
      'ko': '한국어 (Korean)',
      'en': '영어 (English)',
      'zh': '중국어 (Chinese)',
      'ja': '일본어 (Japanese)',
    };
    final targetLabel = targetLangLabels[targetLang] ?? '한국어 (Korean)';

    if (!mounted) return;
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (ctx) => StatefulBuilder(
        builder: (ctx, setModalState) => AlertDialog(
          title: const Text('Google ML Kit 공식 번역'),
          content: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                '원본 언어를 선택하면 현재 앱 설정 언어($targetLabel)로 번역합니다:',
                style: const TextStyle(fontSize: 13),
              ),
              const SizedBox(height: 12),
              Wrap(
                spacing: 8,
                runSpacing: 6,
                children: [
                  ChoiceChip(
                    label: const Text('일본어 (Japanese)'),
                    selected: _sourceLangCode == 'ja',
                    onSelected: (_) {
                      setModalState(() {
                        _sourceLangCode = 'ja';
                        _selectedScript = TextRecognitionScript.japanese;
                      });
                    },
                  ),
                  ChoiceChip(
                    label: const Text('중국어 (Chinese)'),
                    selected: _sourceLangCode == 'zh',
                    onSelected: (_) {
                      setModalState(() {
                        _sourceLangCode = 'zh';
                        _selectedScript = TextRecognitionScript.chinese;
                      });
                    },
                  ),
                  ChoiceChip(
                    label: const Text('한국어 (Korean)'),
                    selected: _sourceLangCode == 'ko',
                    onSelected: (_) {
                      setModalState(() {
                        _sourceLangCode = 'ko';
                        _selectedScript = TextRecognitionScript.korean;
                      });
                    },
                  ),
                ],
              ),
            ],
          ),
          actions: [
            TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text('취소')),
            ElevatedButton.icon(
              icon: const Icon(Icons.translate, size: 18),
              label: const Text('번역 시작'),
              onPressed: () => Navigator.pop(ctx, true),
            ),
          ],
        ),
      ),
    );

    if (confirmed == true) {
      _startBackgroundBatchTranslation(
        forceRetranslate: forceRetranslate,
        targetLang: targetLang,
      );
    }
  }

  /// 1 & 4. Google ML Kit 공식 번역기로 설정 언어(targetLang)로 백그라운드 번역
  void _startBackgroundBatchTranslation({
    bool forceRetranslate = false,
    required String targetLang,
  }) {
    final String key = _bookKey;
    final List<File> pages = List<File>.from(_imagePages);
    final String lang = _sourceLangCode;
    final TextRecognitionScript scr = _selectedScript;

    ScaffoldMessenger.of(context).showSnackBar(
      const SnackBar(
        content: Text('Google ML Kit 백그라운드 번역이 시작되었습니다. (뒤로가기를 눌러도 유지됩니다)'),
        duration: Duration(seconds: 2),
      ),
    );

    BatchTranslationService.preTranslateAllImages(
      bookKey: key,
      imageFiles: pages,
      targetLang: targetLang,
      sourceLang: lang,
      script: scr,
      forceRetranslate: forceRetranslate,
      onProgress: (c, t, s) {
        StorageService.getImageBubbleCache(key, c - 1).then((cached) {
          if (cached != null && mounted) {
            setState(() {
              _bubblesByPage[c - 1] = cached;
              _showTranslatedBubbles = true;
            });
          }
        });
      },
    ).then((_) async {
      await _reloadBubbleCachesFromStorage();
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('번역이 완료되었습니다.')),
        );
      }
    });
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

            // 1. S펜 필기 레이어: EagerStylusPanGestureRecognizer를 통해 S펜이 닿는 즉시 제스처 아레나를 독점하여
            // S펜으로 필기할 때 화면이 같이 움직이거나 페이지가 넘어가는 현상을 100% 차단! (손가락 스와이프로는 페이지 이동 가능)
            if (_isMemoMode)
              Positioned.fill(
                child: StylusOnlyDrawingLayer(
                  enabled: _isMemoMode,
                  allowTouch: _allowFingerDrawing,
                  onStylusDown: (_) {},
                  onStylusMove: (_) {},
                  onStylusUp: (_) {},
                  onStylusCancel: (_) {},
                  child: const SizedBox.expand(),
                ),
              ),
            if (strokes.isNotEmpty || _isMemoMode)
              Positioned(
                left: drawLeft,
                top: drawTop,
                width: drawWidth,
                height: drawHeight,
                child: StylusOnlyDrawingLayer(
                  enabled: _isMemoMode,
                  allowTouch: _allowFingerDrawing,
                  onStylusDown: (event) {
                    final bool useEraser =
                        _isEraserMode || event.kind == PointerDeviceKind.invertedStylus;
                    if (useEraser) {
                      _eraseStrokeAt(pageIndex, event.localPosition, drawWidth, drawHeight);
                    } else {
                      setState(() {
                        _activeDrawingPageIndex = pageIndex;
                        _activeStrokePoints
                          ..clear()
                          ..add(event.localPosition);
                      });
                    }
                  },
                  onStylusMove: (event) {
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
                  onStylusUp: (event) async {
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
                  onStylusCancel: (_) {
                    setState(() => _activeStrokePoints.clear());
                  },
                  child: CustomPaint(
                    painter: _MemoCanvasPainter(
                      strokes: strokes,
                      currentPoints: pageIndex == _activeDrawingPageIndex ? _activeStrokePoints : const [],
                      currentColor: _penColor,
                      currentWidth: _penWidth,
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
    final int effectivePage = (isSpread && (_currentPage + 2 >= _totalPages)) ? _totalPages : (_currentPage + 1);
    final double progPercent = _totalPages > 0 ? (effectivePage / _totalPages * 100.0).clamp(0.0, 100.0).toDouble() : 0.0;
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

  /// 6. 진행도 UI의 화살표를 맨 처음(0페이지)과 맨 마지막(_totalPages - 1 페이지)으로 즉시 이동하는 용도로 변경!
  /// + 하단 배치 시 우측 하단 페이지 이동 버튼과 절대 겹치지 않도록 슬림/컴팩트 사이즈로 축소 및 여백 확보!
  Widget _buildProgressControlBar(double bottomInset) {
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

    final bool isSpreadNow = _isSpreadActive(context);
    final int displayedPageNum = (isSpreadNow && (_currentPage + 2 >= _totalPages))
        ? _totalPages
        : (_currentPage + 1).clamp(1, _totalPages).toInt();
    final double sliderMax = math.max<double>(1.0, (_totalPages - 1).toDouble());
    final double sliderVal = (displayedPageNum - 1).toDouble().clamp(0.0, sliderMax).toDouble();
    final double baseBottom = math.max<double>(bottomInset + 24.0, 28.0);

    if (_progressBarPos == 'bottom') {
      return Positioned(
        key: const ValueKey('progress_bar_bottom'),
        left: 14.0,
        // 페이지 이동 버튼(우측 12.0, 너비 약 88px -> 우측 100px 차지)과 겹치지 않도록 118px 여유 간격 확보
        right: _useQuickNavTurn ? 118.0 : 14.0,
        bottom: baseBottom,
        height: 38.0,
        child: Material(
          color: Colors.black87,
          borderRadius: BorderRadius.circular(19),
          elevation: 5,
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
            child: Row(
              children: [
                IconButton(
                  icon: const Icon(Icons.first_page, color: Colors.white, size: 18),
                  tooltip: '처음으로 이동',
                  visualDensity: VisualDensity.compact,
                  padding: EdgeInsets.zero,
                  constraints: const BoxConstraints(minWidth: 28, minHeight: 28),
                  onPressed: () => _goToPage(0, recordHistory: true, smoothAnimation: false),
                ),
                Expanded(
                  child: SliderTheme(
                    data: SliderTheme.of(context).copyWith(
                      trackHeight: 2.8,
                      thumbShape: const RoundSliderThumbShape(enabledThumbRadius: 6.0),
                      overlayShape: const RoundSliderOverlayShape(overlayRadius: 11.0),
                    ),
                    child: Slider(
                      value: sliderVal,
                      min: 0.0,
                      max: sliderMax,
                      onChanged: (v) => _goToPage(v.round(), smoothAnimation: false),
                    ),
                  ),
                ),
                Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 2),
                  child: Text(
                    '$displayedPageNum/$_totalPages',
                    style: const TextStyle(color: Colors.white, fontSize: 10.5, fontWeight: FontWeight.bold),
                  ),
                ),
                IconButton(
                  icon: const Icon(Icons.last_page, color: Colors.white, size: 18),
                  tooltip: '마지막으로 이동',
                  visualDensity: VisualDensity.compact,
                  padding: EdgeInsets.zero,
                  constraints: const BoxConstraints(minWidth: 28, minHeight: 28),
                  onPressed: () => _goToPage(_totalPages - 1, recordHistory: true, smoothAnimation: false),
                ),
              ],
            ),
          ),
        ),
      );
    }

    return Positioned(
      key: ValueKey('progress_bar_$_progressBarPos'),
      top: 76.0,
      bottom: _useQuickNavTurn && _progressBarPos == 'right' ? (baseBottom + 48.0) : (baseBottom + 8.0),
      left: _progressBarPos == 'left' ? 8.0 : null,
      right: _progressBarPos == 'right' ? 8.0 : null,
      width: 40.0,
      child: Material(
        color: Colors.black87,
        borderRadius: BorderRadius.circular(20),
        elevation: 5,
        child: Padding(
          padding: const EdgeInsets.symmetric(vertical: 6),
          child: Column(
            children: [
              IconButton(
                icon: const Icon(Icons.vertical_align_top, color: Colors.white, size: 18),
                tooltip: '처음으로 이동',
                visualDensity: VisualDensity.compact,
                padding: EdgeInsets.zero,
                constraints: const BoxConstraints(minWidth: 30, minHeight: 30),
                onPressed: () => _goToPage(0, recordHistory: true, smoothAnimation: false),
              ),
              Expanded(
                child: RotatedBox(
                  quarterTurns: 1,
                  child: SliderTheme(
                    data: SliderTheme.of(context).copyWith(
                      trackHeight: 2.8,
                      thumbShape: const RoundSliderThumbShape(enabledThumbRadius: 6.0),
                      overlayShape: const RoundSliderOverlayShape(overlayRadius: 11.0),
                    ),
                    child: Slider(
                      value: sliderVal,
                      min: 0.0,
                      max: sliderMax,
                      onChanged: (v) => _goToPage(v.round(), smoothAnimation: false),
                    ),
                  ),
                ),
              ),
              Text(
                '$displayedPageNum/$_totalPages',
                style: const TextStyle(color: Colors.white, fontSize: 9.5, fontWeight: FontWeight.bold),
              ),
              IconButton(
                icon: const Icon(Icons.vertical_align_bottom, color: Colors.white, size: 18),
                tooltip: '마지막으로 이동',
                visualDensity: VisualDensity.compact,
                padding: EdgeInsets.zero,
                constraints: const BoxConstraints(minWidth: 30, minHeight: 30),
                onPressed: () => _goToPage(_totalPages - 1, recordHistory: true, smoothAnimation: false),
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
      height: 38.0,
      child: Material(
        color: Colors.black87,
        borderRadius: BorderRadius.circular(19),
        elevation: 5,
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 2),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              IconButton(
                icon: const Icon(Icons.arrow_back, color: Colors.amber, size: 19),
                tooltip: '이전 페이지',
                visualDensity: VisualDensity.compact,
                constraints: const BoxConstraints(minWidth: 34, minHeight: 34),
                padding: EdgeInsets.zero,
                onPressed: () => _stepPage(-1),
              ),
              Container(width: 1, height: 18, color: Colors.white24),
              IconButton(
                icon: const Icon(Icons.arrow_forward, color: Colors.amber, size: 19),
                tooltip: '다음 페이지',
                visualDensity: VisualDensity.compact,
                constraints: const BoxConstraints(minWidth: 34, minHeight: 34),
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
    WidgetsBinding.instance.removeObserver(this);
    BatchTranslationService.translationCompletedEvent.removeListener(_onBackgroundTranslationFinished);
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

    return PopScope(
      onPopInvokedWithResult: (didPop, _) {
        if (_isTouchLocked) {
          _isTouchLocked = false;
        }
      },
      child: Scaffold(
      backgroundColor: Colors.black,
      body: Stack(
        fit: StackFit.expand,
        children: [
          Positioned.fill(
            child: AbsorbPointer(
              absorbing: _isTouchLocked,
              child: Listener(
                behavior: HitTestBehavior.translucent,
                onPointerDown: (event) {
                  if (_isMemoMode &&
                      (event.kind == PointerDeviceKind.stylus ||
                          event.kind == PointerDeviceKind.invertedStylus)) {
                    if (!_isStylusDown) {
                      setState(() => _isStylusDown = true);
                    }
                  }
                },
                onPointerUp: (event) {
                  if (_isStylusDown &&
                      (event.kind == PointerDeviceKind.stylus ||
                          event.kind == PointerDeviceKind.invertedStylus)) {
                    setState(() => _isStylusDown = false);
                  }
                },
                onPointerCancel: (event) {
                  if (_isStylusDown) {
                    setState(() => _isStylusDown = false);
                  }
                },
                child: GestureDetector(
                  onTap: _toggleControls,
                  child: PageView.builder(
                    key: ValueKey('pageview_spread_$isSpread'),
                    controller: _pageController,
                    reverse: _isMangaRtlMode,
                    physics: (_isTouchLocked || (_isMemoMode && (_isStylusDown || _allowFingerDrawing)))
                        ? const NeverScrollableScrollPhysics()
                        : const BouncingScrollPhysics(),
                  itemCount: viewItemCount,
                  onPageChanged: (viewIdx) {
                    int actualPage = isSpread ? (viewIdx * 2) : viewIdx;
                    if (isSpread && viewIdx == viewItemCount - 1) {
                      actualPage = (_totalPages - 1).clamp(0, _totalPages - 1).toInt();
                    }
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

          // 백그라운드 번역 진행 중일 때 뷰어 내 미니 진행 표시줄 (항상 Positioned가 Stack의 직계 자식이 되도록 배치!)
          Positioned(
            left: 16,
            bottom: math.max<double>(bottomInset + 24.0, 28.0) + (_showControls && _progressBarPos == 'bottom' ? 46.0 : 0.0),
            child: ValueListenableBuilder<Map<String, TranslationTaskInfo>>(
              valueListenable: BatchTranslationService.activeTasks,
              builder: (context, tasks, _) {
                final task = tasks[_bookKey];
                if (task == null) return const SizedBox.shrink();
                return Material(
                  color: Colors.black87,
                  borderRadius: BorderRadius.circular(20),
                  child: Padding(
                    padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
                    child: Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        const SizedBox(
                          width: 14,
                          height: 14,
                          child: CircularProgressIndicator(strokeWidth: 2, color: Colors.amber),
                        ),
                        const SizedBox(width: 8),
                        Text(
                          '번역 ${(task.progress * 100).toStringAsFixed(0)}% (${task.current}/${task.total})',
                          style: const TextStyle(color: Colors.white, fontSize: 11),
                        ),
                      ],
                    ),
                  ),
                );
              },
            ),
          ),

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
                          IconButton(
                            padding: const EdgeInsets.symmetric(horizontal: 4),
                            constraints: const BoxConstraints(),
                            icon: Icon(
                              _isEraserMode ? Icons.auto_fix_normal : Icons.draw,
                              color: _allowFingerDrawing ? Colors.white : Colors.amber,
                              size: 20,
                            ),
                            tooltip: _tr(
                              '손으로 글씨 쓰기 (활성 시 흰색 / 페이지 넘김 잠금)',
                              'Finger Writing (White when active / Locks page turn)',
                              '手指书写（开启时变白 / 锁定翻页）',
                              '指で手書き（ONで白色 / ページめくりロック）',
                            ),
                            onPressed: () => setState(() => _allowFingerDrawing = !_allowFingerDrawing),
                          ),
                          const SizedBox(width: 6),
                          ...[
                            Colors.amber,
                            Colors.redAccent,
                            Colors.lightBlueAccent,
                            Colors.greenAccent,
                            Colors.white,
                            Colors.black,
                          ].map((c) => GestureDetector(
                                onTap: () => setState(() {
                                  _penColor = c;
                                  _isEraserMode = false;
                                }),
                                child: Container(
                                  margin: const EdgeInsets.symmetric(horizontal: 3),
                                  width: 20,
                                  height: 20,
                                  decoration: BoxDecoration(
                                    color: c,
                                    shape: BoxShape.circle,
                                    border: Border.all(
                                      color: (!_isEraserMode && _penColor == c)
                                          ? Colors.amberAccent
                                          : Colors.white54,
                                      width: (!_isEraserMode && _penColor == c) ? 2.2 : 1.0,
                                    ),
                                  ),
                                ),
                              )),
                          const SizedBox(width: 6),
                          const Icon(Icons.line_weight, color: Colors.white70, size: 15),
                          SizedBox(
                            width: 82,
                            child: SliderTheme(
                              data: SliderTheme.of(context).copyWith(
                                trackHeight: 2.2,
                                thumbShape: const RoundSliderThumbShape(enabledThumbRadius: 5.5),
                                overlayShape: const RoundSliderOverlayShape(overlayRadius: 10.0),
                              ),
                              child: Slider(
                                value: _penWidth.clamp(1.0, 14.0).toDouble(),
                                min: 1.0,
                                max: 14.0,
                                activeColor: Colors.amber,
                                onChanged: (v) => setState(() => _penWidth = v),
                              ),
                            ),
                          ),
                          Text(
                            '${_penWidth.toStringAsFixed(1)}',
                            style: const TextStyle(color: Colors.white70, fontSize: 10),
                          ),
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
                              _allowFingerDrawing = false;
                            }),
                            child: Text(_tr('완료', 'Done', '完成', '完了'), style: const TextStyle(color: Colors.amber)),
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

                      IconButton(
                        icon: const Icon(Icons.skip_previous_rounded, color: Colors.white, size: 22),
                        tooltip: '이전 파일로 이동 (같은 그룹)',
                        onPressed: () => _openAdjacentFileInSameGroup(-1),
                      ),
                      IconButton(
                        icon: const Icon(Icons.skip_next_rounded, color: Colors.white, size: 22),
                        tooltip: '다음 파일로 이동 (같은 그룹)',
                        onPressed: () => _openAdjacentFileInSameGroup(1),
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
                            if (!_isMemoMode) _allowFingerDrawing = false;
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

          _buildProgressControlBar(bottomInset),

          if (_useQuickNavTurn && !_isTouchLocked && _totalPages > 1)
            _buildQuickNavButtons(bottomInset),
        ],
      ),
      ),
    );
  }
}
