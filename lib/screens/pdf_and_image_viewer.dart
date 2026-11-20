import 'dart:async';
import 'dart:io';
import 'dart:math' as math;
import 'dart:ui' as ui;
import 'package:flutter/rendering.dart' show RenderRepaintBoundary;
import 'package:archive/archive.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:path_provider/path_provider.dart';
import '../services/library_nav.dart';
import '../services/storage_service.dart';
import '../services/system_bars.dart';
import '../services/pdf_outline_service.dart';
import '../widgets/morph_icons.dart';
import '../widgets/outline_progress.dart';
import '../widgets/text_copy_sheet.dart';
import '../services/volume_key_service.dart';
import '../widgets/quick_tool_bar.dart';
import '../widgets/toolbar_settings.dart';
import '../widgets/bar_drag.dart';
import '../widgets/viewer_dialogs.dart';
import '../widgets/app_colors.dart';
import '../widgets/ui_scale.dart';
import '../widgets/memo_tools.dart';
import '../widgets/direction_arrow_icon.dart';
import '../widgets/find_in_file_bar.dart';
import 'reader_screen.dart';
import '../widgets/pop_dialog.dart';
import '../widgets/page_curl.dart';
import '../widgets/bookmark_ribbon.dart';
import '../widgets/text_select.dart';

/// S펜 전용 즉시 승리 제스처 인식기 (Eager Stylus Gesture Recognizer):
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

  /// 손가락 필기를 쓰지 않을 때 손가락 터치를 아래(본문)로 그대로 넘김
  /// (본문 위에 덮인 필기 그림이 터치를 막아 화면 누르기·밀어서 넘기기가 안 되던 문제)
  final bool passThroughTouch;

  const StylusOnlyDrawingLayer({
    this.passThroughTouch = false,
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
      child: (passThroughTouch && !allowTouch) ? IgnorePointer(child: child) : child,
    );
  }
}

class _MemoCanvasPainter extends CustomPainter {
  final List<MemoStroke> strokes;
  final List<Offset> currentPoints;

  _MemoCanvasPainter({required this.strokes, required this.currentPoints});

  @override
  void paint(Canvas canvas, Size size) {
    paintMemoStrokes(canvas, strokes, toLocal: (x, y) => Offset(x * size.width, y * size.height), unit: size.width);
    if (currentPoints.isNotEmpty) paintMemoActive(canvas, currentPoints);
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

class _UniversalMediaReaderScreenState extends State<UniversalMediaReaderScreen>
    with WidgetsBindingObserver, TickerProviderStateMixin {
  static const MethodChannel _pdfChannel = MethodChannel('ebook_reader/pdf_renderer');
  PageController? _pageController;
  final VolumeKeyService _volumeKeyService = VolumeKeyService();

  List<File> _imagePages = [];

  /// PDF 쪽 자체의 배경색 (쪽 가장자리가 한 가지 색이면). 앱 테마 색보다 먼저 씀
  Color? _fileBackdrop;
  Color _backdrop(BuildContext context) => _fileBackdrop ?? viewerBackdrop(context);

  /// 첫 쪽 가장자리 색을 살펴 문서 배경색을 찾음 (흰 바탕이면 앱 테마 색 그대로)
  Future<void> _detectPageBackdrop() async {
    if (!_isPdfFile || _imagePages.isEmpty) return;
    try {
      final codec = await ui.instantiateImageCodec(await _imagePages.first.readAsBytes(), targetWidth: 24);
      final img = (await codec.getNextFrame()).image;
      final data = await img.toByteData(format: ui.ImageByteFormat.rawRgba);
      final int w = img.width, h = img.height;
      img.dispose();
      if (data == null || w < 4 || h < 4) return;
      final px = <List<int>>[];
      for (int x = 0; x < w; x++) {
        for (final y in [0, 1, h - 2, h - 1]) {
          final o = (y * w + x) * 4;
          px.add([data.getUint8(o), data.getUint8(o + 1), data.getUint8(o + 2)]);
        }
      }
      for (int y = 2; y < h - 2; y++) {
        for (final x in [0, 1, w - 2, w - 1]) {
          final o = (y * w + x) * 4;
          px.add([data.getUint8(o), data.getUint8(o + 1), data.getUint8(o + 2)]);
        }
      }
      final avg = List.generate(3, (c) => px.map((p) => p[c]).reduce((a, b) => a + b) / px.length);
      final double spread = px.map((p) => [0, 1, 2].map((c) => (p[c] - avg[c]).abs()).reduce(math.max)).reduce(math.max);
      final bool white = avg.every((v) => v > 240);
      // 가장자리가 고르게 한 가지 색이고 흰색이 아닐 때만 문서 배경색으로 봄
      if (spread < 40 && !white && mounted) {
        setState(() => _fileBackdrop = Color.fromARGB(255, avg[0].round(), avg[1].round(), avg[2].round()));
      }
    } catch (_) {}
  }
  final Map<int, Size> _pageImageSizes = {};
  bool _isPreparingPages = true;
  int _currentPage = 0;
  int _totalPages = 1;
  bool _showControls = false;
  bool _isMangaRtlMode = false;
  // 페이지 표시: 'one' / 'two' / 'auto'(화면이 넓으면 두 페이지)
  String _pageDisplay = 'one';
  // 페이지 모드: 탭(누른 자리로 넘김) / 스크롤(쪽을 이어 붙여 세로로) / 슬라이드(= _useSwipeTurn)
  bool _pageModeTap = true;
  OverlayEntry? _tapGuide;
  bool _pageModeScroll = false;
  final ContinuousPageController _scrollCtrl = ContinuousPageController();
  final Map<int, Size> _scrollSizes = {};
  bool _lastIsSpreadMode = false;


  bool _useSwipeTurn = true;

  /// 한 번 넘기면 갈 쪽. 두 쪽 보기에서는 다음(이전) 두 쪽 묶음의 첫 쪽이고, 그런 묶음이 없으면 지금 쪽 그대로
  /// (예전: 2쪽짜리 파일에서 0쪽 → 1쪽으로 '넘어가' 같은 두 쪽을 한 번 더 넘겨 보여 줌)
  int _stepTarget(int dir) {
    if (_lastIsSpreadMode) {
      final int first = (_currentPage ~/ 2) * 2;
      final int t = first + dir * 2;
      if (t < 0 || t > _totalPages - 1) return _currentPage;
      return t;
    }
    return (_currentPage + dir).clamp(0, _totalPages - 1).toInt();
  }

  bool _canStepPage(int dir) => _totalPages > 1 && _stepTarget(dir) != _currentPage;

  /// 앞뒤 쪽 그림을 미리 읽어 둠: 처음 넘기는 쪽도 넘기는 순간 바로 그려져
  /// (책처럼 넘기기에서 아직 안 읽은 쪽이 비어 투명하게 보이던 문제)
  void _precacheAround(int page) {
    if (!mounted || _imagePages.isEmpty) return;
    final int step = _lastIsSpreadMode ? 2 : 1;
    final int base = _lastIsSpreadMode ? (page ~/ 2) * 2 : page;
    for (int i = base - step; i < base + step * 2; i++) {
      if (i < 0 || i >= _imagePages.length) continue;
      _ensurePageDimensionLoaded(i);
      precacheImage(FileImage(_imagePages[i]), context).catchError((_) {});
    }
  }

  Future<void> _stepPageInstant(int dir) async {
    _goToPage(_stepTarget(dir), smoothAnimation: false);
    // 새 쪽이 실제로 그려진 뒤에 제자리로 돌려야 이전 쪽이 잠깐 비치지 않는다
    await WidgetsBinding.instance.endOfFrame;
    await WidgetsBinding.instance.endOfFrame;
  }
  bool _useVolumeTurn = false;
  Offset? _lastEraserPos;
  final Set<int> _activeTouchPointerIds = {};
  final TransformationController _zoomController = TransformationController();

  // ── 확대해서 볼 때 선명하게: 보이는 부분만 지금 확대 배율·화면 해상도로 다시 그려 쪽 위에 덮음 (PDF만) ──
  /// 쪽 번호 → (쪽 안의 자리 0~1, 그림 파일)
  final Map<int, (Rect, String)> _sharpTiles = {};
  /// 쪽이 확대 전 화면(InteractiveViewer 안)에서 차지하는 자리
  final Map<int, Rect> _pageRectInStage = {};
  Size _stageSize = Size.zero;
  Timer? _sharpTimer;
  int _sharpSeq = 0;
  double _currentZoomScale = 1.0;

  bool _isMemoMode = false;
  bool _isEraserMode = false;
  bool _allowFingerDrawing = false;
  bool _isStylusDown = false;
  int _activeDrawingPageIndex = 0;
  final Map<int, List<MemoStroke>> _memoStrokesByPage = {};
  final List<Offset> _activeStrokePoints = [];

  // 메모: 되돌리기/다시 실행 기록, 지우개 드래그 시작 시점의 필기 (펜·형광펜·테이프·지우개 설정은 [MemoTools])
  final MemoHistory _memoHistory = MemoHistory();
  List<MemoStroke>? _eraseStartStrokes;

  String _progressBarPosSetting = 'bottom';
  /// 실제 진행바 위치: 1쪽짜리 문서는 설정과 상관없이 숨김 (다른 버튼 배치도 숨김 기준으로)
  String get _progressBarPos => (_totalPages <= 1 || _progressBarHidden) ? 'hidden' : _progressBarPosSetting;
  bool _progressBarHidden = false; // 도구 모음 설정의 진행바 숨기기
  String _memoToolbarPos = 'bottom'; // 메모 도구모음 위치
  int _rotateTapCount = 0; // 화면 회전 아이콘 흔들림 애니메이션용
  List<BookmarkItem> _bookmarks = [];

  /// 지금 쪽이 북마크돼 있는지 (한 쪽·두 쪽·스크롤 보기마다 따로: 그 보기에서 한 북마크만)
  bool get _isCurrentPageBookmarked {
    if (_bookmarks.isEmpty) return false;
    final bool isSpreadNow = _isSpreadActive(context);
    final int firstPage = isSpreadNow ? ((_currentPage ~/ 2) * 2) : _currentPage;
    return _isBookmarkedAt(firstPage, isSpreadNow, scroll: _pageModeScroll);
  }

  bool _isBookmarkedAt(int firstPage, bool spread, {bool scroll = false}) =>
      _bookmarks.any((bm) => bm.spread == spread && bm.scroll == scroll && int.tryParse(bm.position) == firstPage);

  /// 스크롤 보기 북마크의 쪽들 (쪽 왼쪽 위에 책갈피)
  Set<int> get _scrollMarkPages => {
        for (final bm in _bookmarks)
          if (bm.scroll)
            if (int.tryParse(bm.position) case final p?) p,
      };

  /// 페이지 모드를 스크롤(true) / 탭·슬라이드(false)로 바꿈 (뷰어 설정의 '스크롤'과 같음)
  void _mutateScrollMode(bool val) {
    _pageModeScroll = val;
    if (val) {
      // 켜기 직전의 탭·슬라이드를 기억해 두었다가 스크롤을 다시 끄면 되돌림
      if (_pageModeTap || _useSwipeTurn) {
        PageModeMemory.tap = _pageModeTap;
        PageModeMemory.slide = _useSwipeTurn;
      }
      _useSwipeTurn = false;
      _pageModeTap = false;
    } else {
      _pageModeTap = PageModeMemory.tap;
      _useSwipeTurn = PageModeMemory.slide;
    }
  }

  Future<void> _setScrollModeTo(bool val) async {
    if (val == _pageModeScroll) return;
    setState(() {
      _mutateScrollMode(val);
    });
    await StorageService.setPageModeTap(_pageModeTap);
    await StorageService.setPageModeScroll(_pageModeScroll);
    await StorageService.setUseSwipeTurn(_useSwipeTurn);
    _onPageModeChanged();
  }

  String get _bookKey => widget.customBookKey ?? widget.files.first.path;

  String _tr(String ko, String en, String zh, String ja) =>
      AppI18n.t(StorageService.appLangNotifier.value, ko: ko, en: en, zh: zh, ja: ja);

  @override
  void initState() {
    super.initState();
    _tintHold.open(); // 파일을 보는 동안 편안한 모드 덮개를 걷음
    _zoomController.addListener(_onZoomMoved);
    ToolbarLayout.current.addListener(_onToolbarLayout); // 도구 모음 설정에서 아이콘 배치를 바꾸면 바로 다시 그림
    MemoTools.changed.addListener(_onToolbarLayout); // 메모 도구 설정(테이프 숨기기 등)이 바뀌면 다시 그림
    SystemBars.enterViewer(); // 파일 열람 중에는 상태표시줄·내비게이션 바를 모두 숨김
    WidgetsBinding.instance.addObserver(this);
    _loadNeighborFiles();
    _initMedia();
  }

  final ViewerTintHold _tintHold = ViewerTintHold();

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _tintHold.watch(context);
  }

  /// 페이지 이동 고르기 (도구 모음): 음량 버튼 / 탭 / 슬라이드(책처럼 넘기기) / 스크롤(스크롤바 끄기). 창을 닫을 때 적용
  Future<void> _pickPageMode() async {
    final r = await showPageModeDialog(
      context,
      tr: _tr,
      current: (volume: _useVolumeTurn, tap: _pageModeTap, slide: _useSwipeTurn, scroll: _pageModeScroll, curl: StorageService.pageCurl, barOff: ScrollThumbBar.off.value),
    );
    if (r == null || !mounted) return;
    if (r.volume != _useVolumeTurn) {
      setState(() => _useVolumeTurn = r.volume);
      await StorageService.setUseVolumeTurn(r.volume);
      if (!mounted) return;
    }
    final bool tapBefore = _pageModeTap;
    final bool modeChanged = r.tap != _pageModeTap || r.slide != _useSwipeTurn || r.scroll != _pageModeScroll;
    setState(() {
      if (r.scroll != _pageModeScroll) _mutateScrollMode(r.scroll);
      if (!r.scroll) {
        _pageModeTap = r.tap;
        _useSwipeTurn = r.slide;
      }
    });
    if (r.curl != StorageService.pageCurl) {
      await StorageService.setPageCurl(r.curl);
      _syncCurlSwipe();
    }
    if (r.barOff != ScrollThumbBar.off.value) {
      ScrollThumbBar.off.value = r.barOff;
      await StorageService.setScrollBarOff(r.barOff);
    }
    if (modeChanged) {
      await StorageService.setPageModeTap(_pageModeTap);
      await StorageService.setPageModeScroll(_pageModeScroll);
      await StorageService.setUseSwipeTurn(_useSwipeTurn);
      _onPageModeChanged();
    }
    // 탭을 켜면 탭 영역 안내를 보여 줌
    if (mounted && !tapBefore && _pageModeTap && !StorageService.tapGuideOff) _showTapGuide();
  }

  void _setPageDisplay(String mode) {
    if (!mounted) return;
    setState(() => _pageDisplay = mode);
  }

  /// 도구 모음 설정 초기화: 아이콘 배치·숨김, 진행바 보이기, 음량 버튼 끄기 (길게 눌러 옮긴 도구 모음·메모 도구 모음·진행바·스크롤 막대도 처음 자리로)
  Future<void> _resetViewerSettings() async {
    setState(() {
      _useVolumeTurn = false;
      _progressBarPosSetting = 'bottom';
      _progressBarHidden = false;
      _memoToolbarPos = 'bottom';
      _toolbarPos = 'bottom';
    });
    ScrollThumbBar.leftHanded.value = false;
    await ToolbarLayout.save(ToolbarLayout.defaults());
    await StorageService.setUseVolumeTurn(false);
    await StorageService.setProgressBarPosition('bottom');
    await StorageService.setProgressBarHidden(false);
    await StorageService.setMemoToolbarPosition('bottom');
    await StorageService.setToolbarPosition('bottom');
    await StorageService.setQuickMenuSide('right');
  }

  /// 페이지 모드가 바뀌었을 때: 스크롤로 바꾸면 쪽 크기를 미리 다 알아 둠 (한 번에 이어 붙여 끊김 없이)
  void _onPageModeChanged() {
    if (!mounted) return;
    if (_pageModeScroll) _prepareScrollSizes();
    _zoomController.value = Matrix4.identity();
    setState(() => _currentZoomScale = 1.0);
    // 쪽 모드로 돌아오면 보던 쪽을 그대로
    if (!_pageModeScroll) WidgetsBinding.instance.addPostFrameCallback((_) => _syncControllerToCurrentPage(animate: false));
  }

  void _prepareScrollSizes({bool retry = true}) {
    for (int i = 0; i < _imagePages.length; i++) {
      if (_scrollSizes.containsKey(i)) continue;
      final known = _pageImageSizes[i];
      // 화면을 다시 그릴 때마다 모든 쪽 파일을 다시 읽지 않게: 한 번 못 읽은 쪽은 [retry]일 때만 다시 (쪽이 많은 파일에서 버벅임)
      if (known == null && !retry && _scrollSizeTried.contains(i)) continue;
      _scrollSizeTried.add(i);
      final sz = known ?? readImageSizeSync(_imagePages[i].path);
      if (sz != null && sz.width > 0 && sz.height > 0) _scrollSizes[i] = sz;
    }
  }

  /// 크기를 읽어 본 쪽 (못 읽었어도 화면을 그릴 때마다 다시 읽지 않음)
  final Set<int> _scrollSizeTried = <int>{};

  /// 스크롤 모드에서 [i]쪽의 높이/너비 (모르면 첫 쪽과 같게)
  double _scrollAspect(int i) {
    final sz = _scrollSizes[i] ?? _scrollSizes[0] ?? const Size(1000, 1414);
    return (sz.height / sz.width).clamp(0.2, 8.0).toDouble();
  }

  /// 화면 회전 고르기 (자동 / 세로 고정 / 가로 고정)
  Future<void> _pickRotation() async {
    final bool? want = StorageService.desiredLandscapeNotifier.value;
    final current = want == null ? 'auto' : (want ? 'landscape' : 'portrait');
    final picked = await showRotationDialog(context, current: current, tr: _tr);
    if (picked == null || !mounted) return;
    await _applyRotation(picked);
  }

  Future<void> _applyRotation(String mode) async {
    _resetAnyZoom(); // 확대한 채로 돌리면 원래 크기로 보여 주며 돌림
    StorageService.desiredLandscapeNotifier.value = mode == 'auto' ? null : mode == 'landscape';
    setState(() => _rotateTapCount++);
    try {
      await _pdfChannel.invokeMethod('setScreenOrientation', {'mode': mode == 'auto' ? 'unspecified' : mode});
    } catch (_) {}
    if (mounted) setState(() {});
  }

  /// 지금 화면 회전 설정 아이콘
  String get _rotationModeNow {
    final bool? want = StorageService.desiredLandscapeNotifier.value;
    return want == null ? 'auto' : (want ? 'landscape' : 'portrait');
  }

  /// 페이지 표시 고르기 (한 페이지 / 두 페이지 / 자동)
  Future<void> _pickPageDisplay() async {
    await showPageDisplayDialog(
      context,
      current: _pageDisplay,
      tr: _tr,
      scrollMode: _pageModeScroll,
      onChanged: (mode) {
        StorageService.setPageDisplay(mode);
        _setPageDisplay(mode);
      },
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

  /// 같은 그룹 내의 이전(step: -1) 또는 다음(step: 1) 파일로 즉시 이동
  // 이전·다음 파일: 서재 목록을 한 줄로 세워(정렬 설정 그대로) 앞뒤 파일이 있을 때만 이동. 없으면 단추가 잠김
  String? _prevFilePath, _nextFilePath;

  Future<void> _loadNeighborFiles() async {
    final String path = widget.files.first.path;
    final prev = await LibraryNav.neighbor(path, -1);
    final next = await LibraryNav.neighbor(path, 1);
    if (!mounted) return;
    setState(() {
      _prevFilePath = prev;
      _nextFilePath = next;
    });
  }

  Future<void> _openAdjacentFileInSameGroup(int step) async {
    final String? target = step < 0 ? _prevFilePath : _nextFilePath;
    final File? targetFile = target == null ? null : File(target);
    if (targetFile == null || !mounted) return;

    final nextName = targetFile.path.split(Platform.pathSeparator).last;
    final nextExt = nextName.split('.').last.toLowerCase();

    ScaffoldMessenger.of(context).clearSnackBars();
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(nextName),
        duration: const Duration(milliseconds: 900),
      ),
    );

    if (const ['epub', 'txt', 'docx', 'doc', 'hwpx', 'hwp', 'pptx', 'ppt', 'xlsx', 'xlsm', 'xls'].contains(nextExt)) {
      Navigator.pushReplacement(
        context,
        MaterialPageRoute(
          builder: (_) => ReaderScreen(filePath: targetFile.path, bookTitle: nextName),
        ),
      );

    } else if (nextExt == 'pdf') {
      Navigator.pushReplacement(
        context,
        MaterialPageRoute(
          builder: (_) => UniversalMediaReaderScreen(
            files: [targetFile],
            title: nextName,
            isPdf: true,
          ),
        ),
      );
    } else {
      Navigator.pushReplacement(
        context,
        MaterialPageRoute(
          builder: (_) => UniversalMediaReaderScreen(
            files: [targetFile],
            title: nextName,
            isPdf: false,
          ),
        ),
      );
    }
  }

  Future<void> _initMedia() async {
    try {
      _pageDisplay = await StorageService.getPageDisplay();
      _pageModeTap = await StorageService.getPageModeTap();
      _pageModeScroll = await StorageService.getPageModeScroll();
      if (_pageModeScroll) _pageModeTap = false; // 스크롤은 탭과 함께 쓰지 않음
      _isMangaRtlMode = await StorageService.getBookReadingDirectionRtl(_bookKey);
      _useVolumeTurn = await StorageService.getUseVolumeTurn();
      _useSwipeTurn = await StorageService.getUseSwipeTurn() && !_pageModeScroll;
      _progressBarPosSetting = await StorageService.getProgressBarPosition();
      _progressBarHidden = await StorageService.getProgressBarHidden();
      _memoToolbarPos = await StorageService.getMemoToolbarPosition();
      _toolbarPos = await StorageService.getToolbarPosition();
      ScrollThumbBar.leftHanded.value = (await StorageService.getQuickMenuSide()) == 'left';
      ScrollThumbBar.off.value = await StorageService.getScrollBarOff();
      _bookmarks = await StorageService.getBookmarks(_bookKey);
      // 파일을 열 때마다 탭 존 가이드라인 (앱 설정에서 끌 수 있음)
      if (!StorageService.tapGuideOff && mounted) {
        _showTapGuide();
      }

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
      }

      _totalPages = _imagePages.isNotEmpty ? _imagePages.length : 1;
      unawaited(_detectPageBackdrop());

      final savedPos = await StorageService.getLastPosition(_bookKey);
      if (savedPos != null) {
        final savedPage = int.tryParse(savedPos) ?? 0;
        _currentPage = savedPage.clamp(0, _totalPages - 1).toInt();
      }
      // 파일 목록에 보여 줄 '지금 쪽/전체 쪽' (열기만 하고 넘기지 않아도 남김)
      unawaited(StorageService.savePageLabel(_bookKey, '${_currentPage + 1}/$_totalPages'));
      // 목차: 첫 화면을 그린 뒤 잠시 있다가 분석
      if (_isPdfFile) Future<void>.delayed(const Duration(milliseconds: 600), _loadPdfOutline);

      _pageController = PageController(initialPage: _currentPage);

      if (_imagePages.isNotEmpty) {
        _pageImageSizes[_currentPage] = await _getImageDimension(_imagePages[_currentPage]);
        if (_currentPage + 1 < _imagePages.length) {
          _ensurePageDimensionLoaded(_currentPage + 1);
        }
        WidgetsBinding.instance.addPostFrameCallback((_) => _precacheAround(_currentPage));
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

    // 필기 및 메모 데이터 비동기 로드
    if (mounted) await _loadMemoStrokes();
    if (mounted && _memoStrokesByPage.isNotEmpty) {
      setState(() {});
    }
  }

  /// 음량 버튼: 위는 이전 쪽, 아래는 다음 쪽
  void _bindHardwareButtons() {
    _volumeKeyService.startListening(
      onVolumeUp: () {
        if (_useVolumeTurn) _stepPage(-1);
      },
      onVolumeDown: () {
        if (_useVolumeTurn) _stepPage(1);
      },
    );
  }

  bool _isSpreadActive(BuildContext context) {
    final size = MediaQuery.sizeOf(context);
    final bool isLandscapeNow = size.width > size.height;
    if (_pageModeScroll || _totalPages <= 1) return false; // 스크롤 모드는 쪽이 바뀌지 않음
    return _pageDisplay == 'two' || (_pageDisplay == 'auto' && isLandscapeNow);
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
        duration: Anim.ms(220),
        curve: Curves.easeOutCubic,
      );
    } else {
      ctrl.jumpToPage(targetViewIdx);
    }
  }

  void _stepPage(int direction, {bool fastResponse = false}) {
    if (!_canStepPage(direction)) return;
    final int target = _stepTarget(direction);
    _goToPage(
      target,
      smoothAnimation: true,
      animDurationMs: fastResponse ? 140 : 250,
    );
  }

  // ── 파일 내 단어 검색 (PDF만) ──
  // ── 목차 (PDF) ──
  final GlobalKey<ScaffoldState> _scaffoldKey = GlobalKey<ScaffoldState>();
  List<Map<String, Object>> _pdfToc = const [];

  /// PDF 목차: 파일 속 책갈피(목차)가 있을 때만. 없으면 목차 칸에 '표시할 목차가 없어요.'
  Future<void> _loadPdfOutline() async {
    if (!mounted || _totalPages <= 0) return;
    var items = await PdfOutlineService.read(widget.files.first.path);
    if (!mounted) return;
    // '슬라이드 1', 'Page 2'처럼 쪽 번호만 적힌 책갈피(발표 자료를 PDF로 저장할 때 생김)는 목차로 쓰지 않음
    if (items.isNotEmpty &&
        items.every((e) => RegExp(r'^\s*(슬라이드|slide|페이지|page|쪽)?\s*\d+\s*(쪽|페이지)?\s*$', caseSensitive: false).hasMatch('${e['title']}'))) {
      items = const [];
    }
    if (items.isNotEmpty) setState(() => _pdfToc = items);
  }

  /// 쪽마다 {aspect, 줄들 {t, x0, x1, y, h, (sw: 글자 획 굵기 비율)}} (지원하지 않는 기기에서는 빈 목록)
  Future<List<_PdfPageLines>> _pdfLines(String path, int from, int to, bool bold) async {
    try {
      final r = await _pdfChannel.invokeMethod<List<Object?>>('pdfLines', {'path': path, 'from': from, 'to': to, 'bold': bold});
      return [
        for (final page in r ?? const [])
          if (page is Map)
            _PdfPageLines(
              (page['aspect'] as num?)?.toDouble() ?? 1,
              [
                if (page['lines'] is List)
                  for (final l in page['lines'] as List)
                    if (l is Map && l['x0'] is num && l['x1'] is num) l.cast<String, Object?>(),
              ],
            ),
      ];
    } catch (_) {
      return const [];
    }
  }

  Widget _buildTocDrawer() {
    final cs = Theme.of(context).colorScheme;
    final bool outline = _pdfToc.isNotEmpty;
    return Drawer(
      child: SafeArea(
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Padding(
              padding: const EdgeInsets.all(16.0),
              child: Text(_tr('목차', 'Contents', '目录', '目次'), style: const TextStyle(fontSize: 18, fontWeight: FontWeight.w800)),
            ),
            const Divider(height: 1),
            Expanded(
              child: !outline
                  ? NoTocView(label: _tr('표시할 목차가 없어요', 'No contents to show', '没有可显示的目录', '表示できる目次がありません'))
                  : ListView.builder(
                itemCount: _pdfToc.length,
                itemBuilder: (context, index) {
                  final item = _pdfToc[index]; // 목차가 없으면 위에서 '표시할 목차가 없어요'를 보여 줌
                  final int page = item['page'] as int;
                  final int level = item['level'] as int;
                  return ListTile(
                    contentPadding: EdgeInsets.only(left: 16.0 + (level - 1).clamp(0, 4) * 18.0, right: 16),
                    title: Text(
                      item['title'] as String,
                      style: outline ? TextStyle(fontSize: level <= 1 ? 15.5 : 14, fontWeight: level <= 1 ? FontWeight.w700 : FontWeight.w400) : null,
                    ),
                    trailing: outline ? Text('${page + 1}', style: TextStyle(fontSize: 12.5, color: cs.onSurfaceVariant)) : null,
                    onTap: () {
                      Navigator.pop(context);
                      _goToPage(page, smoothAnimation: false);
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

  bool get _isPdfFile => widget.isPdf || widget.files.first.path.toLowerCase().endsWith('.pdf');
  bool _findOpen = false;
  List<({int page, List<Rect> rects})> _findHits = const [];
  int _findCurrent = -1;

  Future<void> _openFind() async {
    // 글자 정보가 없는 PDF(스캔본 등)나 검색을 못 하는 기기도 쪽 그림에서 글자를 읽어 찾음
    if (!mounted) return;
    setState(() {
      _findOpen = true;
      _showControls = false;
    });
  }

  void _closeFind() {
    setState(() {
      _findOpen = false;
      _findHits = const [];
      _findCurrent = -1;
    });
  }

  // 쪽 그림에서 읽은 글자 (스캔본 검색용, 한 번 읽은 쪽은 기억)
  final Map<int, List<Map>> _ocrCache = {};

  /// 띄어쓰기·대소문자를 무시하고 줄들에서 찾기: 줄 {t, x0, x1, y, h} (0~1)
  static List<Rect> _matchLines(List<Map> lines, String query) {
    final q = query.replaceAll(RegExp(r'\s+'), '').toLowerCase();
    final out = <Rect>[];
    if (q.isEmpty) return out;
    for (final l in lines) {
      final t = '${l['t'] ?? ''}';
      final x0 = (l['x0'] as num?)?.toDouble(), x1 = (l['x1'] as num?)?.toDouble();
      final y = (l['y'] as num?)?.toDouble(), h = (l['h'] as num?)?.toDouble();
      if (t.isEmpty || x0 == null || x1 == null || y == null || h == null) continue;
      // 공백을 뺀 글과 원래 글자 위치 대응
      final idx = <int>[];
      final buf = StringBuffer();
      for (int i = 0; i < t.length; i++) {
        if (t[i].trim().isEmpty) continue;
        idx.add(i);
        buf.write(t[i].toLowerCase());
      }
      final norm = buf.toString();
      for (int at = norm.indexOf(q); at >= 0; at = norm.indexOf(q, at + q.length)) {
        final a = idx[at] / t.length, b = (idx[at + q.length - 1] + 1) / t.length;
        out.add(Rect.fromLTRB(x0 + (x1 - x0) * a, y, x0 + (x1 - x0) * b, y + h));
      }
    }
    return out;
  }

  /// PDF 글자 정보로 못 찾으면: 줄 단위(띄어쓰기 무시) → 글자 정보가 없는 쪽은 쪽 그림에서 글자를 읽어 찾음
  Future<List<({int page, List<Rect> rects})>> _findFallback(String query) async {
    final hits = <({int page, List<Rect> rects})>[];
    final path = widget.files.first.path;
    final noText = <int>[];
    for (int from = 0; from < _totalPages; from += 20) {
      final to = math.min(_totalPages, from + 20);
      final pages = await _pdfLines(path, from, to, false);
      for (int i = from; i < to; i++) {
        final k = i - from;
        final lines = k < pages.length ? pages[k].lines : const <Map<String, Object?>>[];
        if (lines.isEmpty) {
          noText.add(i);
          continue;
        }
        for (final r in _matchLines(lines, query)) {
          hits.add((page: i, rects: [r]));
        }
      }
      if (!mounted || !_findOpen) return hits;
    }
    // 스캔본: 너무 오래 걸리지 않게 앞쪽 120쪽까지
    for (final i in noText.take(120)) {
      if (!mounted || !_findOpen || i >= _imagePages.length) break;
      var lines = _ocrCache[i];
      if (lines == null) {
        try {
          final raw = await _pdfChannel.invokeMethod<List<Object?>>('ocrLines', {'path': _imagePages[i].path}) ?? const [];
          lines = [
            for (final e in raw)
              if (e is Map && e['x'] is num && e['w'] is num)
                {'t': e['t'], 'x0': e['x'], 'x1': (e['x'] as num) + (e['w'] as num), 'y': e['y'], 'h': e['h']},
          ];
        } catch (_) {
          lines = const [];
        }
        _ocrCache[i] = lines;
      }
      for (final r in _matchLines(lines, query)) {
        hits.add((page: i, rects: [r]));
      }
    }
    return hits;
  }

  Future<int> _findSearch(String query) async {
    try {
      List<dynamic>? raw;
      try {
        raw = await _pdfChannel.invokeMethod<List<dynamic>>('pdfSearch', {'path': widget.files.first.path, 'query': query});
      } catch (_) {
        raw = null;
      }
      var hits = <({int page, List<Rect> rects})>[];
      for (final item in raw ?? const []) {
        if (item is! Map) continue;
        final page = (item['page'] as num?)?.toInt();
        final flat = (item['rects'] as List?)?.map((v) => (v as num).toDouble()).toList() ?? const <double>[];
        if (page == null || flat.length < 4) continue;
        final rects = <Rect>[for (int i = 0; i + 3 < flat.length; i += 4) Rect.fromLTRB(flat[i], flat[i + 1], flat[i + 2], flat[i + 3])];
        hits.add((page: page, rects: rects));
      }
      if (hits.isEmpty) hits = await _findFallback(query);
      if (mounted) {
        setState(() {
          _findHits = hits;
          _findCurrent = hits.isEmpty ? -1 : 0;
        });
      }
      return hits.length;
    } catch (_) {
      return 0;
    }
  }

  Future<void> _findGoto(int index) async {
    if (index < 0 || index >= _findHits.length) return;
    setState(() => _findCurrent = index);
    final page = _findHits[index].page;
    if (page != _currentPage && !(_lastIsSpreadMode && page ~/ 2 == _currentPage ~/ 2)) {
      _goToPage(page, smoothAnimation: false);
    }
  }

  /// 쪽 그림 위에 찾은 단어를 노란 형광펜으로
  Widget? _findMarks(int pageIndex, double left, double top, double width, double height) {
    if (_findHits.isEmpty) return null;
    final all = <Rect>[], current = <Rect>[];
    for (int i = 0; i < _findHits.length; i++) {
      final hit = _findHits[i];
      if (hit.page != pageIndex) continue;
      (i == _findCurrent ? current : all).addAll(hit.rects);
    }
    if (all.isEmpty && current.isEmpty) return null;
    return Positioned(
      left: left,
      top: top,
      width: width,
      height: height,
      child: IgnorePointer(child: CustomPaint(painter: _FindMarkPainter(all, current))),
    );
  }

  void _goToPage(
    int page, {
    bool smoothAnimation = true,
    int animDurationMs = 250,
  }) {
    if (page < 0 || page >= _totalPages) return;
    setState(() => _currentPage = page);
    // 스크롤 모드: 그 쪽이 화면 맨 위에 오게
    if (_pageModeScroll) _scrollCtrl.jumpToPage(page);
    _ensurePageDimensionLoaded(page);
    if (page + 1 < _totalPages) _ensurePageDimensionLoaded(page + 1);

    StorageService.saveLastPosition(_bookKey, page.toString());
    if (_totalPages > 0) {
      StorageService.saveProgress(_bookKey, (page + 1) / _totalPages);
      StorageService.savePageLabel(_bookKey, '${page + 1}/$_totalPages');
    }

    final ctrl = _pageController;
    if (ctrl != null && ctrl.hasClients) {
      final int targetViewIdx = _lastIsSpreadMode ? (page ~/ 2) : page;
      final int currentViewIdx = ctrl.page?.round() ?? targetViewIdx;
      if (smoothAnimation && (targetViewIdx - currentViewIdx).abs() <= 2) {
        ctrl.animateToPage(
          targetViewIdx,
          duration: Anim.ms(animDurationMs),
          curve: Curves.easeOutCubic,
        );
      } else {
        ctrl.jumpToPage(targetViewIdx);
      }
    }
  }

  /// 화면을 한 번 눌렀을 때: 탭 모드면 위쪽은 메뉴, 아래 왼쪽·오른쪽은 이전·다음 쪽
  /// (메뉴가 떠 있거나 필기 중이면 메뉴만 닫음. '이전'·'다음' 칸은 읽기 방향과 상관없이 그대로)
  // 두 손가락(확대·축소) 동작 중이었는지: 그 끝에 손가락을 떼는 것은 탭이 아님
  bool _pinchSeen = false;

  // 확대한 화면을 빠르게 두 번 누르면 확대를 처음으로 (확대돼 있을 때만 한 번 누름을 잠깐 기다려 봄)
  Timer? _tapTimer;
  DateTime? _lastTapAt;
  Offset _lastTapPos = Offset.zero;

  void _onViewerTap(Offset local) {
    if (_pinchSeen) return;
    // 글을 골라 둔 상태면 누르기는 고른 것을 지우기만 함
    if (_textSel.active) {
      _textSel.clear();
      return;
    }
    final bool zoomed = _currentZoomScale > 1.03 || (_pageModeScroll && _scrollCtrl.zoomed);
    final now = DateTime.now();
    if (_tapTimer != null && _lastTapAt != null && now.difference(_lastTapAt!).inMilliseconds < 320 && (local - _lastTapPos).distance < 60) {
      _tapTimer!.cancel();
      _tapTimer = null;
      _lastTapAt = null;
      HapticFeedback.selectionClick();
      _resetAnyZoom();
      return;
    }
    if (zoomed) {
      _lastTapAt = now;
      _lastTapPos = local;
      _tapTimer?.cancel();
      _tapTimer = Timer(const Duration(milliseconds: 300), () {
        _tapTimer = null;
        if (mounted) _onViewerTapNow(local);
      });
      return;
    }
    _onViewerTapNow(local);
  }

  void _onViewerTapNow(Offset local) {
    if (!_pageModeTap || _showControls || _isMemoMode) {
      _toggleControls();
      return;
    }
    switch (tapZoneAt(local, MediaQuery.sizeOf(context))) {
      case TapZone.menu:
        _toggleControls();
      case TapZone.left:
        _tapTurn(-1);
      case TapZone.right:
        _tapTurn(1);
      case TapZone.none:
        break; // 탭 영역에서 '없음'으로 둔 칸
    }
  }

  void _tapTurn(int dir) {
    if (_pageModeScroll) {
      _scrollCtrl.scrollByScreen(dir);
      return;
    }
    _stepPage(dir); // 읽기 방향(우→좌)과 상관없이 '이전'·'다음' 칸 그대로
  }

  /// 스크롤 모드: 모든 쪽을 세로로 늘어놓고 쪽 사이를 살짝 띄워 보여 줌 (쪽 그림은 이미 다 만들어 둔 것)
  Widget _buildScrollPages() {
    if (_scrollSizes.length < _imagePages.length) _prepareScrollSizes(retry: false);
    final double dpr = MediaQuery.devicePixelRatioOf(context);
    final double w = MediaQuery.sizeOf(context).width;
    return ContinuousPageList(
      controller: _scrollCtrl,
      count: _imagePages.length,
      aspectOf: _scrollAspect,
      initialPage: _currentPage,
      // 쪽 그대로 세로로 늘어놓고 쪽 사이는 살짝 띄움 (슬라이드 보기의 쪽을 세로로, 간격 줄은 예전 12의 절반)
      gap: 6,
      markedPages: _scrollMarkPages,
      // 쪽 뒤 바탕은 앱 테마(또는 PDF 자체 배경색), 쪽 사이 간격 줄은 고정 색
      background: _backdrop(context),
      gapColor: kViewerGapColor,
      onPageChanged: (p) {
        setState(() => _currentPage = p);
        StorageService.saveLastPosition(_bookKey, p.toString());
        StorageService.saveProgress(_bookKey, (p + 1) / _totalPages);
        StorageService.savePageLabel(_bookKey, '${p + 1}/$_totalPages');
      },
      pageBuilder: (ctx, i) {
        final img = Image.file(
          _imagePages[i],
          fit: BoxFit.fill,
          cacheWidth: math.min(4096, (w * dpr).round()),
          gaplessPlayback: true,
          filterQuality: FilterQuality.medium,
        );
        // 라이트·편안한 모드: 한글·워드처럼 쪽마다 옅은 회색 테두리
        final Widget page = Theme.of(ctx).brightness == Brightness.light
            ? DecoratedBox(
                position: DecorationPosition.foreground,
                decoration: const BoxDecoration(border: Border.fromBorderSide(BorderSide(color: Color(0xFFC4C4CA), width: 1))),
                child: img,
              )
            : img;
        // 스크롤 보기에서도 찾은 단어를 형광펜으로
        final all = <Rect>[], current = <Rect>[];
        for (int k = 0; k < _findHits.length; k++) {
          if (_findHits[k].page == i) (k == _findCurrent ? current : all).addAll(_findHits[k].rects);
        }
        // 메모: 넘겨 보기와 같은 메모를 쪽에 붙여 함께 움직이게 (쓰고 지우기도 그대로)
        final strokes = _memoStrokesByPage[i] ?? const <MemoStroke>[];
        final bool memo = strokes.isNotEmpty || _isMemoMode;
        if (all.isEmpty && current.isEmpty && !memo) return page;
        return Stack(fit: StackFit.expand, children: [
          page,
          if (all.isNotEmpty || current.isNotEmpty) IgnorePointer(child: CustomPaint(painter: _FindMarkPainter(all, current))),
          if (memo) LayoutBuilder(builder: (ctx, c) => _pageMemoLayer(i, c.maxWidth, c.maxHeight, strokes)),
        ]);
      },
    );
  }

  void _toggleControls() {
    setState(() => _showControls = !_showControls);
  }

  // 읽기 방향 아이콘: ↔ (지금 방향 쪽 화살촉만 노란색)
  Widget _buildDualDirectionIcon() => DirectionArrowIcon(rightToLeft: _isMangaRtlMode, size: 20);

  // ── 메모 되돌리기 / 다시 실행 ──
  List<int> _visibleMemoPages() {
    // 스크롤 보기: 보고 있는 쪽과 그 앞뒤 쪽 (화면에 함께 보일 수 있어서)
    if (_pageModeScroll) return [for (int p = _currentPage - 1; p <= _currentPage + 1; p++) if (p >= 0 && p < _totalPages) p];
    final bool isSpreadNow = _isSpreadActive(context);
    if (!isSpreadNow) return [_currentPage];
    final int firstPage = (_currentPage ~/ 2) * 2;
    return [firstPage, if (firstPage + 1 < _totalPages) firstPage + 1];
  }

  // 메모는 쪽마다 하나 (한 쪽·두 쪽 보기, 가로·세로 어디서 보든 같은 메모)
  int _memoLoadSeq = 0;

  Future<void> _loadMemoStrokes() async {
    final int seq = ++_memoLoadSeq;
    final Map<int, List<MemoStroke>> next = {};
    for (int i = 0; i < _imagePages.length; i++) {
      final strokes = await StorageService.getPageMemoStrokes(_bookKey, i);
      if (strokes.isNotEmpty) next[i] = strokes;
    }
    if (!mounted || seq != _memoLoadSeq) return;
    setState(() {
      _memoStrokesByPage
        ..clear()
        ..addAll(next);
      _activeStrokePoints.clear();
    });
  }

  Future<void> _applyMemoStrokes(int page, List<MemoStroke> strokes) async {
    setState(() {
      if (strokes.isEmpty) {
        _memoStrokesByPage.remove(page);
      } else {
        _memoStrokesByPage[page] = List<MemoStroke>.of(strokes);
      }
    });
    await StorageService.savePageMemoStrokes(_bookKey, page, strokes);
  }

  Future<void> _undoMemo() async {
    final r = _memoHistory.undo(_visibleMemoPages(), (k) => _memoStrokesByPage[k as int] ?? const []);
    if (r != null) await _applyMemoStrokes(r.$1 as int, r.$2);
  }

  Future<void> _redoMemo() async {
    final r = _memoHistory.redo(_visibleMemoPages(), (k) => _memoStrokesByPage[k as int] ?? const []);
    if (r != null) await _applyMemoStrokes(r.$1 as int, r.$2);
  }

  /// 지우개로 문지르기를 끝냈을 때, 실제로 지워진 게 있으면 되돌리기 기록에 남김
  void _finishEraseHistory(int pageIndex) {
    final start = _eraseStartStrokes;
    _eraseStartStrokes = null;
    if (start == null) return;
    final cur = _memoStrokesByPage[pageIndex] ?? const <MemoStroke>[];
    if (!identical(cur, start)) {
      setState(() => _memoHistory.record(pageIndex, start));
    }
  }

  /// 메모 도구모음 항목: 모두 같은 크기 칸(MemoToolButton)이라 간격이 똑같다
  List<Widget> _memoToolItems() {
    return [
      MemoToolButton(
        // 손가락 끝에서 선이 그어지는 모양 (펜 아이콘과 같은 높이)
        iconBuilder: (c) => FingerDrawIcon(color: c, size: 22),
        label: _tr('손으로 그리기', 'Finger Writing', '手指书写', '指で手書き'),
        active: _allowFingerDrawing,
        onTap: () => setState(() => _allowFingerDrawing = !_allowFingerDrawing),
      ),
      ..._memoDrawTools(),
      // 되돌리기 / 다시 실행
      MemoToolButton(
        icon: Icons.undo,
        label: _tr('되돌리기', 'Undo', '撤销', '元に戻す'),
        enabled: _memoHistory.canUndo(_visibleMemoPages()),
        onTap: _undoMemo,
      ),
      MemoToolButton(
        icon: Icons.redo,
        label: _tr('다시 실행', 'Redo', '重做', 'やり直し'),
        enabled: _memoHistory.canRedo(_visibleMemoPages()),
        onTap: _redoMemo,
      ),
      MemoDoneButton(
        label: _tr('완료', 'Done', '完成', '完了'),
        onTap: () => setState(() {
          _isMemoMode = false;
          _isEraserMode = false;
          _allowFingerDrawing = false;
        }),
      ),
    ];
  }

  /// 메모 도구모음 배치: 하단(기본) / 상단 / 왼쪽 / 오른쪽
  Widget _buildMemoToolbar(double bottomInset) {
    final List<Widget> items = _memoToolItems();
    // 끄는 동안 손가락을 따라가는 모양 (가장자리 근처에서는 그 자리의 가로·세로 모양)
    Widget mover(Widget bar) => MemoToolbarMover(
          current: _memoToolbarPos,
          onDrop: _moveMemoToolbar,
          feedback: (side) {
            final bool v = side == 'left' || side == 'right';
            return ConstrainedBox(
              constraints: BoxConstraints(maxWidth: v ? 60 : barDragMaxLength(context, vertical: false), maxHeight: v ? barDragMaxLength(context, vertical: true) : 60),
              child: MemoToolbar(vertical: v, children: items),
            );
          },
          child: bar,
        );
    final double topInset = MediaQuery.paddingOf(context).top;
    final double baseBottom = math.max<double>(bottomInset + 24.0, 28.0);
    final double bottomBarSpace = (_showControls && _progressBarPos == 'bottom') ? 46.0 : 0.0;
    final double topOffset = topInset + (_showControls ? 64.0 + _topBarsSpace : 16.0);
    switch (_memoToolbarPos) {
      case 'top':
        return Positioned(
          key: const ValueKey('memo_toolbar'),
          top: topOffset,
          left: 12 + _safeSides.left,
          right: 12 + _safeSides.right,
          child: Center(child: mover(MemoToolbar(children: items))),
        );
      case 'left':
      case 'right':
        final bool isLeft = _memoToolbarPos == 'left';
        // 같은 쪽에 세로 진행바가 있으면 그 안쪽으로 비켜서 배치
        final double edge = ((_showControls && _progressBarPos == _memoToolbarPos) ? 56.0 : 12.0) + (isLeft ? _safeSides.left : _safeSides.right);
        // 아래쪽 진행바·도구 모음과 겹치지 않도록
        final double bottomLimit = _memoBarToFloorLandscape
            // 가로 모드: 바닥까지
            ? baseBottom
            : baseBottom + bottomBarSpace + (_showControls ? 52.0 : 8.0);
        return Positioned(
          key: const ValueKey('memo_toolbar'),
          top: topOffset,
          bottom: bottomLimit,
          left: isLeft ? edge : null,
          right: isLeft ? null : edge,
          child: Center(widthFactor: 1, child: mover(MemoToolbar(vertical: true, children: items))),
        );
      default:
        return Positioned(
          key: const ValueKey('memo_toolbar'),
          // 파일 도구 모음이 보이면 그 위에 (도구 모음 높이 52 + 사이 8)
          bottom: baseBottom + bottomBarSpace + ((_showControls && _toolbarPos != 'top') ? 60.0 : 0.0),
          left: 12 + _safeSides.left,
          right: 12 + _safeSides.right,
          child: Center(child: mover(MemoToolbar(children: items))),
        );
    }
  }

  /// 메모 도구 모음을 길게 눌러 끌어 놓은 곳(가까운 가장자리)으로 옮기고 기억
  Future<void> _moveMemoToolbar(String pos) async {
    if (pos == _memoToolbarPos) return;
    setState(() => _memoToolbarPos = pos);
    await StorageService.setMemoToolbarPosition(pos);
  }

  /// 카메라(디스플레이 컷아웃)·시스템 영역 여백. 떠 있는 UI가 카메라를 가리지 않도록 좌우에 더한다.
  EdgeInsets get _safeSides => MediaQuery.viewPaddingOf(context);

  bool get _isLandscapeNow {
    final Size sz = MediaQuery.sizeOf(context);
    return sz.width > sz.height;
  }

  /// 가로 모드에서 메모 도구모음이 왼쪽/오른쪽(세로)에 있을 때:
  /// 세로 공간이 좁으므로 메모 도구모음은 바닥까지 길게 내려온다.
  bool get _memoBarToFloorLandscape =>
      _isMemoMode &&
      _showControls &&
      _isLandscapeNow &&
      (_memoToolbarPos == 'left' || _memoToolbarPos == 'right');

  /// 가로 모드 + 하단 진행바: 진행바를 메모 도구모음 쪽에서 줄인다
  bool get _memoBarBesideProgress =>
      _memoBarToFloorLandscape && _progressBarPos == 'bottom';

  /// 위 상황에서 진행바가 메모 도구모음 쪽에서 비켜 주는 폭 (메모 도구모음 폭 48 + 간격 8)
  static const double _memoBarSideInset = 54.0;

  /// 펜·형광펜·테이프·지우개 단추 (고른 것을 한 번 더 누르면 설정 창)
  List<Widget> _memoDrawTools() {
    final st = MemoTools.s;
    Widget tool(String kind, String label) => MemoToolButton(
          iconBuilder: (c) => MemoToolIcon(kind: kind, color: c, accent: st.colorOf(kind).withValues(alpha: 1), size: 22),
          label: label,
          active: !_isEraserMode && st.tool == kind,
          onTap: () {
            setState(() {
              _isEraserMode = false;
              st.tool = kind;
            });
            MemoTools.save();
          },
          onReselect: (_) => _openMemoToolPanel(kind),
        );
    return [
      tool('pen', _tr('펜 (한 번 더 누르면 설정)', 'Pen (tap again: settings)', '笔 (再点一次: 设置)', 'ペン (もう一度タップ: 設定)')),
      tool('hl', _tr('형광펜 (한 번 더 누르면 설정)', 'Highlighter (tap again: settings)', '荧光笔 (再点一次: 设置)', '蛍光ペン (もう一度タップ: 設定)')),
      tool('tape', _tr('테이프 (한 번 더 누르면 설정)', 'Tape (tap again: settings)', '胶带 (再点一次: 设置)', 'テープ (もう一度タップ: 設定)')),
      MemoToolButton(
        iconBuilder: (c) => EraserIcon(color: c),
        label: _tr('지우개 (한 번 더 누르면 설정)', 'Eraser (tap again: settings)', '橡皮擦 (再点一次: 设置)', '消しゴム (もう一度タップ: 設定)'),
        active: _isEraserMode,
        onTap: () => setState(() => _isEraserMode = true),
        onReselect: (_) => _openEraserPanel(),
      ),
    ];
  }

  Future<void> _openMemoToolPanel(String kind) async {
    await showMemoToolPanel(context: context, kind: kind, tr: _tr);
    if (mounted) setState(() => _isEraserMode = false);
  }

  Future<void> _openEraserPanel() => showEraserPanel(
        context: context,
        tr: _tr,
        onClearLines: () => _clearMemos((s) => s.kind != 'tape'),
        onClearTapes: () => _clearMemos((s) => s.kind == 'tape'),
      );

  /// 보고 있는 쪽(두 쪽 보기면 두 쪽)의 메모 가운데 [which]에 드는 것을 모두 지움 (되돌리기 가능)
  Future<void> _clearMemos(bool Function(MemoStroke s) which) async {
    final bool isSpreadNow = _isSpreadActive(context);
    final int firstPage = isSpreadNow ? ((_currentPage ~/ 2) * 2) : _currentPage;
    final Set<int> pages = {_currentPage, firstPage, if (isSpreadNow && firstPage + 1 < _totalPages) firstPage + 1};
    for (final pg in pages) {
      final before = _memoStrokesByPage[pg];
      if (before == null || !before.any(which)) continue;
      final after = [for (final s in before) if (!which(s)) s];
      _memoHistory.record(pg, before);
      setState(() => _memoStrokesByPage[pg] = after);
      await StorageService.savePageMemoStrokes(_bookKey, pg, after);
    }
  }

  /// 지우개: 이전 좌표~지금 좌표를 이은 캡슐에 닿은 부분을 지움 (드래그 중에는 저장하지 않음)
  void _eraseStrokeAt(int pageIndex, Offset localPos, double drawWidth, double drawHeight) {
    final strokes = _memoStrokesByPage[pageIndex];
    final Offset prevPos = _lastEraserPos ?? localPos;
    _lastEraserPos = localPos;
    if (strokes == null || strokes.isEmpty || drawWidth <= 0 || drawHeight <= 0) return;
    // 지우개 크기는 화면 기준 (확대해도 화면에서 같은 크기)
    final next = eraseMemoStrokes(
      strokes,
      prevPos,
      localPos,
      toLocal: (x, y) => Offset(x * drawWidth, y * drawHeight),
      toFrac: (p) => Offset((p.dx / drawWidth).clamp(0.0, 1.0), (p.dy / drawHeight).clamp(0.0, 1.0)),
      unit: drawWidth,
      hitRadius: math.max<double>(15.0, MemoTools.s.penWidth * 3.2) / math.max(1.0, _currentZoomScale),
    );
    if (next != null) setState(() => _memoStrokesByPage[pageIndex] = next);
  }

  /// 탭 존 가이드라인 띄우기 (앞에 떠 있던 것은 지움)
  void _showTapGuide() {
    if (_tapGuide?.mounted ?? false) _tapGuide!.remove();
    _tapGuide = null;
    unawaited(showTapZoneGuide(context, tapTurn: () => _pageModeTap, tr: _tr).then((e) {
      if (!mounted) {
        if (e?.mounted ?? false) e!.remove();
      } else {
        _tapGuide = e;
      }
    }));
  }


  void _onToolbarLayout() {
    if (mounted) setState(() {});
  }

  /// 도구 모음 설정 (화면 가운데 창): 상단바·도구 모음 아이콘 배치, 진행바 숨기기
  Future<void> _showViewerSettingsSheet() async {
    await showToolbarSettingsDialog(
      context,
      tr: _tr,
      items: _barItems(),
      progressHidden: _progressBarHidden,
      onProgressHidden: (val) {
        StorageService.setProgressBarHidden(val);
        setState(() => _progressBarHidden = val);
      },
      onReset: _resetViewerSettings,
    );
  }

  /// 한 화면(1쪽 또는 2쪽 펼침)에 들어갈 페이지 내용
  /// 확대·이동이 멈추고 잠시 뒤 보이는 부분을 선명하게 다시 그림 (원래 크기로 돌아오면 덮은 그림을 치움)
  void _onZoomMoved() {
    _sharpTimer?.cancel();
    if (!_isPdfFile || _pageModeScroll) return;
    if (_zoomController.value.getMaxScaleOnAxis() < 1.15) {
      _sharpSeq++;
      if (_sharpTiles.isNotEmpty) _clearSharp();
      return;
    }
    _sharpTimer = Timer(const Duration(milliseconds: 250), _renderSharp);
  }

  void _clearSharp({bool rebuild = true}) {
    _sharpSeq++;
    final old = _sharpTiles.values.map((e) => e.$2).toList();
    if (rebuild && mounted) {
      setState(_sharpTiles.clear);
    } else {
      _sharpTiles.clear();
    }
    _deleteSharpFiles(old);
  }

  void _deleteSharpFiles(Iterable<String> paths) {
    for (final p in paths) {
      final f = File(p);
      FileImage(f).evict();
      f.delete().catchError((_) => f);
    }
  }

  Future<void> _renderSharp() async {
    if (!mounted || !_isPdfFile || _pageModeScroll || _stageSize.isEmpty) return;
    final Matrix4 m = _zoomController.value;
    final double scale = m.getMaxScaleOnAxis();
    if (scale < 1.15) return;
    // 지금 화면에 보이는 곳 (확대 전 좌표)
    final Matrix4 inv = Matrix4.inverted(m);
    final Rect visible = Rect.fromPoints(
      MatrixUtils.transformPoint(inv, Offset.zero),
      MatrixUtils.transformPoint(inv, Offset(_stageSize.width, _stageSize.height)),
    );
    final bool spread = _isSpreadActive(context);
    final int first = spread ? (_currentPage ~/ 2) * 2 : _currentPage;
    final List<int> pages = [first, if (spread && first + 1 < _totalPages) first + 1];
    final double dpr = MediaQuery.devicePixelRatioOf(context);
    final int seq = ++_sharpSeq;
    final String dir = (await getTemporaryDirectory()).path;
    final Map<int, (Rect, String)> made = {};
    for (final int p in pages) {
      final Rect? pr = _pageRectInStage[p];
      if (pr == null || pr.isEmpty) continue;
      final Rect region = pr.intersect(visible);
      if (region.width < 2 || region.height < 2) continue;
      final Rect norm = Rect.fromLTRB(
        (region.left - pr.left) / pr.width,
        (region.top - pr.top) / pr.height,
        (region.right - pr.left) / pr.width,
        (region.bottom - pr.top) / pr.height,
      );
      // 보이는 크기 그대로의 화소 수 (너무 크면 메모리를 위해 줄임: 긴 변 4096, 1200만 화소까지)
      double w = region.width * scale * dpr;
      double h = region.height * scale * dpr;
      final double k = math.min(1.0, math.min(4096 / math.max(w, h), math.sqrt(12e6 / (w * h))));
      w *= k;
      h *= k;
      try {
        final String? path = await _pdfChannel.invokeMethod<String>('renderPdfRegion', {
          'path': widget.files.first.path,
          'page': p,
          'l': norm.left, 't': norm.top, 'r': norm.right, 'b': norm.bottom,
          'w': w.round(), 'h': h.round(),
          'out': '$dir/pdf_zoom_${seq}_$p.jpg',
        });
        if (path != null) made[p] = (norm, path);
      } catch (_) {}
      if (seq != _sharpSeq) break;
    }
    if (!mounted || seq != _sharpSeq) {
      _deleteSharpFiles(made.values.map((e) => e.$2));
      return;
    }
    final old = _sharpTiles.values.map((e) => e.$2).toList();
    setState(() => _sharpTiles
      ..clear()
      ..addAll(made));
    // 새 그림이 그려진 뒤에 지난 그림을 지움 (깜빡이지 않게)
    WidgetsBinding.instance.addPostFrameCallback((_) => _deleteSharpFiles(old));
  }

  Widget _buildViewPageContent(int viewIdx, bool isSpread) {
    if (!isSpread) return _buildSinglePagePanel(viewIdx);
    final int firstPage = viewIdx * 2;
    final int secondPage = firstPage + 1;
    final Widget leftPanel = _isMangaRtlMode
        ? (secondPage < _totalPages ? _buildSinglePagePanel(secondPage, spreadSide: -1) : const SizedBox.expand())
        : _buildSinglePagePanel(firstPage, spreadSide: -1);
    final Widget rightPanel = _isMangaRtlMode
        ? _buildSinglePagePanel(firstPage, spreadSide: 1)
        : (secondPage < _totalPages ? _buildSinglePagePanel(secondPage, spreadSide: 1) : const SizedBox.expand());
    return Row(
      children: [
        Expanded(child: leftPanel),
        Expanded(child: rightPanel),
      ],
    );
  }

  /// 쪽 화면 + 책처럼 넘기기 막 + 글 고르기 막
  Widget _buildPageStage(BuildContext context, Widget pages) {
    final List<Widget> children = [RepaintBoundary(key: _curlKey, child: pages)];
    children.add(Positioned.fill(child: BookCurlLayer(drag: _book, paper: _backdrop(context), backsideFromPaper: true /* 한 쪽 보기 종이 뒷면: 앱 테마와 상관없이 쪽의 종이 색(흰색·검은색·세피아) */)));
    // 길게 눌러 고른 글: 바탕·손잡이·[복사 | 모두 선택 | 공유] 막대
    children.add(Positioned.fill(child: SizedBox.expand(key: _textLayerKey, child: PageTextSelectLayer(sel: _textSel, tr: _tr))));
    return Stack(fit: StackFit.expand, clipBehavior: Clip.hardEdge, children: children);
  }

  // ── 종이처럼 말아 넘기기 (슬라이드) ──
  final GlobalKey _curlKey = GlobalKey();

  // 두 쪽 보기: 책처럼 넘기기 (손가락을 따라 모서리부터 말려 넘어감)
  late final BookCurlDrag _book = BookCurlDrag(
    vsync: this,
    capture: _curlCapture,
    turn: (dir) async {
      if (!_canStepPage(dir)) return false;
      await _stepPageInstant(dir);
      return true;
    },
    isRtl: () => _isMangaRtlMode,
    canTurn: _canStepPage,
    paperOf: (spread, fromRight, size) async => _curlPaper(spread, fromRight, size),
  )..wantPaperTone = true; // 한 쪽 보기 종이 뒷면 = 쪽의 종이 색

  /// 넘어가는 쪽(종이)의 자리: 쪽 그림이 화면에 맞춰 놓인 네모 (빈 여백은 넘어가지 않음)
  /// 쪽 그림이 [box] 안에 맞춰 놓인 네모 ([side] -1: 두 쪽 보기 왼쪽, 1: 오른쪽, 0: 가운데)
  Rect? _pageRectIn(int index, Rect box, int side) {
    final s = _pageImageSizes[index];
    if (s == null || s.width <= 0 || s.height <= 0) return null;
    final f = applyBoxFit(BoxFit.contain, s, box.size).destination;
    final double top = box.top + (box.height - f.height) / 2;
    // 두 쪽 보기: 왼쪽 쪽은 가운데 쪽(오른쪽)으로, 오른쪽 쪽은 가운데 쪽(왼쪽)으로 2만큼 띄워 붙음
    final double left = side == -1
        ? box.right - f.width - 2.0
        : side == 1
            ? box.left + 2.0
            : box.left + (box.width - f.width) / 2;
    return Rect.fromLTWH(left, top, f.width, f.height);
  }

  /// 지금 화면에 보이는 쪽들 (쪽 번호, 화면 위 자리)
  List<(int, Rect)> _visiblePageRects(Size size) {
    if (!_lastIsSpreadMode) {
      final r = _pageRectIn(_currentPage, Offset.zero & size, 0);
      return r == null ? const [] : [(_currentPage, r)];
    }
    final double half = size.width / 2;
    final int first = (_currentPage ~/ 2) * 2;
    final int leftIdx = _isMangaRtlMode ? first + 1 : first;
    final int rightIdx = _isMangaRtlMode ? first : first + 1;
    final out = <(int, Rect)>[];
    // 읽는 순서대로 (오른쪽→왼쪽 책은 오른쪽 쪽부터)
    final order = _isMangaRtlMode ? [(rightIdx, 1), (leftIdx, -1)] : [(leftIdx, -1), (rightIdx, 1)];
    for (final (idx, side) in order) {
      if (idx < 0 || idx >= _totalPages) continue;
      final r = _pageRectIn(idx, side == -1 ? Rect.fromLTWH(0, 0, half, size.height) : Rect.fromLTWH(half, 0, half, size.height), side);
      if (r != null) out.add((idx, r));
    }
    return out;
  }

  // ── 길게 눌러 글 고르기 (PDF, 내보낸 PDF 포함) ──
  final PageTextSelection _textSel = PageTextSelection();
  final GlobalKey _textLayerKey = GlobalKey();
  final Map<int, List<Map<String, Object?>>> _textLineCache = {};
  int _textSelGen = 0;

  Offset? _textLocal(Offset global) {
    final box = _textLayerKey.currentContext?.findRenderObject() as RenderBox?;
    if (box == null || !box.hasSize) return null;
    return box.globalToLocal(global);
  }

  Future<void> _startTextSelect(Offset global) async {
    if (_isMemoMode || _activeTouchPointerIds.length >= 2 || _currentZoomScale > 1.03 || _pageModeScroll) return;
    final box = _textLayerKey.currentContext?.findRenderObject() as RenderBox?;
    if (box == null || !box.hasSize) return;
    final int gen = ++_textSelGen;
    final pages = _visiblePageRects(box.size);
    final lines = <SelLine>[];
    for (final (idx, rect) in pages) {
      var ls = _textLineCache[idx];
      if (ls == null) {
        final got = await _pdfLines(widget.files.first.path, idx, idx + 1, false);
        ls = got.isEmpty ? const <Map<String, Object?>>[] : got.first.lines;
        _textLineCache[idx] = ls;
      }
      for (final l in ls) {
        double v(String k) => (l[k] as num?)?.toDouble() ?? 0;
        final String t = '${l['t'] ?? ''}';
        if (t.trim().isEmpty) continue;
        lines.add(SelLine(t, Rect.fromLTRB(rect.left + v('x0') * rect.width, rect.top + v('y') * rect.height, rect.left + v('x1') * rect.width, rect.top + (v('y') + v('h')) * rect.height)));
      }
    }
    if (!mounted || gen != _textSelGen) return;
    final local = _textLocal(global);
    _textSel.lines = lines;
    if (local != null && _textSel.selectWordAt(local)) {
      HapticFeedback.selectionClick();
      return;
    }
    // 글자 정보가 없는 쪽(그림·스캔본)이나 지원하지 않는 기기: 그림 속 글자를 읽어 복사하는 창
    HapticFeedback.selectionClick();
    _openTextCopySheet();
  }

  BookPaper? _curlPaper(bool spread, bool fromRight, Size size) {
    Rect? fit(int index, Rect box, int side) => _pageRectIn(index, box, side);

    if (!spread) {
      final r = fit(_currentPage, Offset.zero & size, 0);
      if (r == null) return null;
      return BookPaper(r, fromRight ? r.left : r.right);
    }
    final double half = size.width / 2;
    final int first = (_currentPage ~/ 2) * 2;
    // 읽기 방향이 오른쪽→왼쪽이면 오른쪽에 앞 쪽
    final int leftIdx = _isMangaRtlMode ? first + 1 : first;
    final int rightIdx = _isMangaRtlMode ? first : first + 1;
    final r = fromRight ? fit(rightIdx, Rect.fromLTWH(half, 0, half, size.height), 1) : fit(leftIdx, Rect.fromLTWH(0, 0, half, size.height), -1);
    if (r == null) return null;
    return BookPaper(r, half);
  }

  void _curlTrackMove(PointerMoveEvent e) {
    if (_book.tracking) {
      _book.update(e.position);
      return;
    }
    final start = _curlDownPos, t0 = _curlDownTime;
    if (start == null || t0 == null || _curlMulti || _book.busy) return;
    if (!_curlOn || _textSel.active) return;
    if (_currentZoomScale > 1.03) return;
    if (_isMemoMode && (e.kind == PointerDeviceKind.stylus || e.kind == PointerDeviceKind.invertedStylus || _allowFingerDrawing)) return;
    final Offset d = e.position - start;
    // 옆으로 움직이기 시작하면 그때 지금 쪽을 찍어 둠 (그냥 누르기만 할 때는 찍지 않음)
    if (_curlPre == null && d.dx.abs() >= 5 && d.dx.abs() > d.dy.abs()) _curlPre = _curlCapture();
    if (d.dx.abs() < 16 || d.dx.abs() < d.dy.abs() * 1.2) return;
    // 길게 누르기(글 고르기, 0.5초)와 겹치지 않게
    if (DateTime.now().difference(t0).inMilliseconds > 450) return;
    final pre = _curlPre;
    _curlPre = null;
    _book.begin(start, e.position, pre, spread: _lastIsSpreadMode);
  }
  Future<ui.Image?>? _curlPre;
  Offset? _curlDownPos;
  DateTime? _curlDownTime;
  bool _curlMulti = false;

  // '애니메이션 멈추기'를 켜도 책처럼 넘기기는 그대로
  bool get _curlOn => StorageService.pageCurl && _useSwipeTurn && !_pageModeScroll;

  void _syncCurlSwipe() => setState(() {});

  void _curlTrackDown(PointerDownEvent e) {
    if (_activeTouchPointerIds.isNotEmpty) {
      // 두 번째 손가락: 확대·축소이므로 넘기지 않음
      _curlMulti = true;
      if (_book.tracking) _book.end(cancel: true);
      return;
    }
    _curlMulti = false;
    _curlDownPos = e.position;
    _curlDownTime = DateTime.now();
    // 지난 손동작에서 찍어 두고 쓰지 않은 그림은 버림 (새 그림은 손가락이 옆으로 움직이기 시작할 때 찍음)
    final stale = _curlPre;
    _curlPre = null;
    stale?.then((i) => i?.dispose());
  }

  Future<ui.Image?> _curlCapture() async {
    try {
      final boundary = _curlKey.currentContext?.findRenderObject() as RenderRepaintBoundary?;
      return await boundary?.toImage(pixelRatio: MediaQuery.devicePixelRatioOf(context));
    } catch (_) {
      return null;
    }
  }

  void _curlTrackUp(PointerUpEvent e) {
    final start = _curlDownPos, t0 = _curlDownTime;
    _curlDownPos = null;
    if (_book.tracking) {
      // 책처럼 넘기는 중: 손을 뗀 곳에 따라 넘기거나 되돌림
      _book.end(cancel: _curlMulti);
      return;
    }
    if (start == null || t0 == null || _curlMulti || !_curlOn) return;
    if (_currentZoomScale > 1.03) return;
    if (_isMemoMode && (e.kind == PointerDeviceKind.stylus || e.kind == PointerDeviceKind.invertedStylus || _allowFingerDrawing)) return;
    // 길게 누르기(글 고르기, 0.5초)와 겹치지 않게
    if (DateTime.now().difference(t0).inMilliseconds > 450) return;
    final Offset d = e.position - start;
    if (d.dx.abs() < 40 || d.dx.abs() < d.dy.abs() * 1.2) return;
    _curlTurn(d.dx);
  }

  /// 손가락으로 끌지 않고 빠르게 밀었을 때: 한 번에 책처럼 넘김
  void _curlTurn(double dx) {
    final pre = _curlPre;
    _curlPre = null;
    final int dir = ((dx < 0) != _isMangaRtlMode) ? 1 : -1;
    if (_book.busy || !_canStepPage(dir)) {
      pre?.then((i) => i?.dispose());
      return;
    }
    final size = MediaQuery.sizeOf(context);
    _book.autoTurn(dx, pre, Offset(dx < 0 ? size.width * 0.9 : size.width * 0.1, size.height * 0.8), spread: _lastIsSpreadMode);
  }

  /// 한 쪽의 메모 층: 그 쪽 크기([drawWidth]×[drawHeight]) 안에서 쓰고 지움 (넘겨 보기·스크롤 보기 함께 씀)
  Widget _pageMemoLayer(int pageIndex, double drawWidth, double drawHeight, List<MemoStroke> strokes) {
    return StylusOnlyDrawingLayer(
        enabled: _isMemoMode,
        allowTouch: _allowFingerDrawing,
        onStylusDown: (event) {
          final bool useEraser =
              _isEraserMode || event.kind == PointerDeviceKind.invertedStylus;
          if (useEraser) {
            _lastEraserPos = event.localPosition;
            _eraseStartStrokes = _memoStrokesByPage[pageIndex] ?? const <MemoStroke>[];
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
          _lastEraserPos = null;
          final bool useEraser =
              _isEraserMode || event.kind == PointerDeviceKind.invertedStylus;
          if (useEraser) {
            _finishEraseHistory(pageIndex);
            final list = _memoStrokesByPage[pageIndex] ?? [];
            await StorageService.savePageMemoStrokes(_bookKey, pageIndex, list);
          } else if (_activeStrokePoints.isNotEmpty &&
              drawWidth > 0 &&
              drawHeight > 0) {
            final st = MemoTools.s;
            // 직선 자동 보정 → 쪽 좌표(0~1)
            final List<Offset> frac = [
              for (final p in finishMemoPoints(_activeStrokePoints))
                Offset((p.dx / drawWidth).clamp(0.0, 1.0), (p.dy / drawHeight).clamp(0.0, 1.0)),
            ];
            final double width = st.width / drawWidth; // 쪽 너비에 대한 비율 (확대·화면 회전에도 쪽과 같이)
            final stroke = MemoStroke(
              dxList: [for (final f in frac) f.dx],
              dyList: [for (final f in frac) f.dy],
              colorValue: st.color.toARGB32(),
              strokeWidth: width,
              kind: st.tool,
            );
            final before = _memoStrokesByPage[pageIndex] ?? const <MemoStroke>[];
            final list = List<MemoStroke>.from(before)..add(stroke);
            _memoHistory.record(pageIndex, before);
            setState(() {
              _memoStrokesByPage[pageIndex] = list;
              _activeStrokePoints.clear();
            });
            await StorageService.savePageMemoStrokes(_bookKey, pageIndex, list);
          }
        },
        onStylusCancel: (_) async {
          _lastEraserPos = null;
          _finishEraseHistory(pageIndex);
          setState(() => _activeStrokePoints.clear());
          final list = _memoStrokesByPage[pageIndex] ?? [];
          await StorageService.savePageMemoStrokes(_bookKey, pageIndex, list);
        },
        child: RepaintBoundary(
          child: CustomPaint(
            painter: _MemoCanvasPainter(
              strokes: strokes,
              currentPoints: pageIndex == _activeDrawingPageIndex ? _activeStrokePoints : const [],
            ),
          ),
        ),
      );
  }

  Widget _buildSinglePagePanel(int pageIndex, {int spreadSide = 0}) {
    if (pageIndex < 0 || pageIndex >= _imagePages.length) {
      return const SizedBox.expand();
    }

    final strokes = _memoStrokesByPage[pageIndex] ?? [];
    // 쪽 크기를 아직 모르면 그림 파일 머리만 읽어 바로 앎 (쪽 테두리·책갈피가 처음부터 쪽에 맞게)
    Size? imgSize = _pageImageSizes[pageIndex];
    if (imgSize == null && pageIndex >= 0 && pageIndex < _imagePages.length) {
      final sz = readImageSizeSync(_imagePages[pageIndex].path);
      if (sz != null && sz.width > 0 && sz.height > 0) imgSize = _pageImageSizes[pageIndex] = sz;
    }

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
          // 2페이지 보기 모드에서 왼쪽 페이지는 중앙 쪽(우측)으로, 오른쪽 페이지는 중앙 쪽(좌측)으로 붙여 가운데 여백 최소화!
          if (spreadSide == -1) {
            drawLeft = (constraints.maxWidth - drawWidth - 2.0).clamp(0.0, constraints.maxWidth);
          } else if (spreadSide == 1) {
            drawLeft = 2.0.clamp(0.0, math.max<double>(0.0, constraints.maxWidth - drawWidth));
          } else {
            drawLeft = (constraints.maxWidth - drawWidth) / 2.0;
          }
          drawTop = (constraints.maxHeight - drawHeight) / 2.0;
        } else {
          _ensurePageDimensionLoaded(pageIndex);
        }

        // 확대 전 화면에서 이 쪽의 자리 (두 쪽 보기의 오른쪽 칸은 왼쪽 칸 너비만큼 옆)
        if (imgSize != null) {
          _pageRectInStage[pageIndex] = Rect.fromLTWH((spreadSide == 1 ? constraints.maxWidth : 0.0) + drawLeft, drawTop, drawWidth, drawHeight);
        }
        final (Rect, String)? sharp = imgSize == null ? null : _sharpTiles[pageIndex];

        final Alignment pageAlign = spreadSide == -1
            ? Alignment.centerRight
            : (spreadSide == 1 ? Alignment.centerLeft : Alignment.center);

        return Stack(
          fit: StackFit.expand,
          children: [
            RepaintBoundary(
              child: Padding(
                padding: EdgeInsets.only(
                  right: spreadSide == -1 ? 2.0 : 0.0,
                  left: spreadSide == 1 ? 2.0 : 0.0,
                ),
                child: Image.file(
                  _imagePages[pageIndex],
                  fit: BoxFit.contain,
                  alignment: pageAlign,
                  gaplessPlayback: true,
                  filterQuality: FilterQuality.medium,
                  width: constraints.maxWidth,
                  height: constraints.maxHeight,
                ),
              ),
            ),
            // 확대해서 볼 때: 보이는 부분을 선명하게 다시 그린 그림
            if (sharp != null)
              Positioned(
                left: drawLeft + sharp.$1.left * drawWidth,
                top: drawTop + sharp.$1.top * drawHeight,
                width: sharp.$1.width * drawWidth,
                height: sharp.$1.height * drawHeight,
                child: IgnorePointer(
                  child: Image.file(File(sharp.$2), fit: BoxFit.fill, gaplessPlayback: true, filterQuality: FilterQuality.medium),
                ),
              ),
            // 라이트·편안한 모드: 흰 쪽이 흰 바탕에 묻히지 않게 쪽마다 옅은 회색 테두리
            if (imgSize != null && Theme.of(context).brightness == Brightness.light)
              Positioned(
                left: drawLeft,
                top: drawTop,
                width: drawWidth,
                height: drawHeight,
                child: const IgnorePointer(child: DecoratedBox(decoration: BoxDecoration(border: Border.fromBorderSide(BorderSide(color: Color(0xFFC4C4CA), width: 1)))))),
            // 파일 내 단어 검색: 찾은 곳 형광펜
            ?_findMarks(pageIndex, drawLeft, drawTop, drawWidth, drawHeight),
            // 북마크한 쪽: 쪽 왼쪽 위에 책갈피 (두 쪽 보기는 화면 왼쪽 쪽에만)
            // (쪽 테두리 안쪽에 두고, 확대하면 잠시 숨김)
            if (spreadSide != 1 && _currentZoomScale <= 1.03 && _isBookmarkedAt(spreadSide == 0 ? pageIndex : (pageIndex ~/ 2) * 2, spreadSide != 0))
              Positioned(left: drawLeft + math.min(18.0, drawWidth * 0.05), top: drawTop, child: const BookmarkRibbon()),
            // S펜 필기 레이어: EagerStylusPanGestureRecognizer를 통해 S펜이 닿는 즉시 제스처 아레나를 독점하여
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
                child: _pageMemoLayer(pageIndex, drawWidth, drawHeight, strokes),
              ),

          ],
        );
      },
    );
  }

  Future<void> _showBookmarkSheet() async {
    var bookmarks = await StorageService.getBookmarks(_bookKey);
    if (mounted) {
      setState(() => _bookmarks = bookmarks);
    }
    if (!mounted) return;
    // 북마크할 쪽: 스크롤 보기는 화면에 절반 이상(가장 많이) 보이는 쪽, 두 쪽 보기는 두 쪽 중 앞쪽
    final bool spreadNow = _isSpreadActive(context);
    final int target = _pageModeScroll
        ? (_scrollCtrl.mostVisiblePage ?? _currentPage).clamp(0, math.max(0, _totalPages - 1)).toInt()
        : (spreadNow ? (_currentPage ~/ 2) * 2 : _currentPage);
    bool already = _isBookmarkedAt(target, spreadNow, scroll: _pageModeScroll);
    // 북마크 목록: 페이지 모드 창처럼 가운데에 뜸. 더하거나 지우면 창 안만 다시 그림
    Future<void> reload(StateSetter set) async {
      final b = await StorageService.getBookmarks(_bookKey);
      if (!mounted) return;
      setState(() => _bookmarks = b);
      set(() {
        bookmarks = b;
        already = _isBookmarkedAt(target, spreadNow, scroll: _pageModeScroll);
      });
    }

    await showCenterPanel<void>(
      context,
      builder: (ctx, set) => Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            bookmarkSheetHeader(
              ctx,
              tr: _tr,
              already: already,
              canClear: bookmarks.isNotEmpty,
              addLabel: _tr('현재 페이지 북마크', 'Bookmark This Page', '添加当前页书签', '現在ページをブックマーク'),
              onClearAll: () async {
                if (!await confirmClearBookmarks(ctx, _tr)) return;
                await StorageService.clearBookmarks(_bookKey);
                await reload(set);
              },
              onAdd: () async {
                final now = DateTime.now();
                final bool spread = spreadNow;
                final int first = target;
                await StorageService.addBookmark(
                  _bookKey,
                  BookmarkItem(
                    id: now.millisecondsSinceEpoch.toString(),
                    label: spread && first + 1 < _totalPages ? '${first + 1}, ${first + 2}페이지' : '${first + 1}페이지',
                    position: first.toString(),
                    createdAt: '${now.month}/${now.day} ${now.hour}:${now.minute.toString().padLeft(2, '0')}',
                    spread: spread,
                    rotation: _rotationModeNow,
                    landscape: MediaQuery.sizeOf(context).width > MediaQuery.sizeOf(context).height,
                    display: _pageDisplay,
                    scroll: _pageModeScroll,
                    mode: bookmarkModeOf(scroll: _pageModeScroll, tap: _pageModeTap, slide: _useSwipeTurn),
                  ),
                );
                await reload(set);
              },
            ),
            const Divider(height: 1),
            if (bookmarks.isEmpty)
              Padding(
                padding: const EdgeInsets.all(24.0),
                child: Text(_tr('저장된 북마크가 없어요', 'No saved bookmarks', '暂无保存的书签', '保存されたブックマークはありません')),
              )
            else
              Flexible(
                child: ListView.builder(
                  shrinkWrap: true,
                  itemCount: bookmarks.length,
                  itemBuilder: (_, idx) {
                    final bm = bookmarks[idx];
                    final int bp = int.tryParse(bm.position) ?? 0;
                    return ListTile(
                      leading: Icon(bm.spread ? Icons.menu_book : Icons.bookmark, color: Colors.amber),
                      title: Text(pagesLabel(bp + 1, bm.spread && bp + 1 < _totalPages ? bp + 2 : null, _tr)),
                      subtitle: bookmarkSubtitle(ctx, bm, _tr),
                      trailing: IconButton(
                        icon: const TrashLidIcon(open: false),
                        onPressed: () async {
                          await StorageService.removeBookmark(_bookKey, bm.id);
                          await reload(set);
                        },
                      ),
                      onTap: () async {
                        Navigator.pop(ctx);
                        final target = int.tryParse(bm.position) ?? 0;
                        // 북마크할 때의 화면 회전·페이지 표시로 돌려놓은 뒤 그 쪽으로
                        if (bm.display != null || bm.rotation != null) {
                          if (await restoreBookmarkView(bm,
                              context: context,
                              display: _pageDisplay,
                              rotation: _rotationModeNow,
                              scroll: _pageModeScroll,
                              setDisplay: (d) async {
                                await StorageService.setPageDisplay(d);
                                _setPageDisplay(d);
                              },
                              setRotation: _applyRotation,
                              setScroll: _setScrollModeTo)) {
                            await Future<void>.delayed(const Duration(milliseconds: 700));
                            if (!mounted) return;
                          }
                        // 예전 북마크: 2페이지 보기에서 저장했으면 가로 모드 2페이지 보기로
                        } else if (bm.spread && !_pageModeScroll && !_isSpreadActive(context)) {
                          if (_pageDisplay == 'one') {
                            await StorageService.setPageDisplay('auto');
                            if (!mounted) return;
                            setState(() => _pageDisplay = 'auto');
                          }
                          final size = MediaQuery.sizeOf(context);
                          if (size.height >= size.width && _pageDisplay == 'auto') await _applyRotation('landscape');
                          await Future<void>.delayed(const Duration(milliseconds: 700));
                          if (!mounted) return;
                        }
                        _goToPage(target, smoothAnimation: false);
                      },
                    );
                  },
                ),
              ),
          ],
        ),
    );
  }

  /// 뷰어 표시에서 페이지 번호를 누르고 숫자를 입력하면 해당 페이지로 이동 (설정에서 페이지 번호가 활성화된 경우만 작동)
  Future<void> _showJumpToPageDialog() async {
    final ctrl = TextEditingController(text: '${_currentPage + 1}');
    ctrl.selection = TextSelection(baseOffset: 0, extentOffset: ctrl.text.length);

    final targetPageOneBased = await showPopDialog<int>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text(
          _tr(
            '페이지 이동 (1 ~ $_totalPages)',
            'Go to Page (1 - $_totalPages)',
            '跳转到页码 (1 ~ $_totalPages)',
            'ページ移動 (1 ~ $_totalPages)',
          ),
        ),
        content: TextField(
          controller: ctrl,
          autofocus: true,
          keyboardType: TextInputType.number,
          inputFormatters: [FilteringTextInputFormatter.digitsOnly],
          decoration: InputDecoration(
            hintText: '1 ~ $_totalPages',
            border: const OutlineInputBorder(),
          ),
          onSubmitted: (val) {
            final parsed = int.tryParse(val.trim());
            Navigator.pop(ctx, parsed);
          },
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx),
            child: Text(_tr('취소', 'Cancel', '取消', 'キャンセル')),
          ),
          ElevatedButton(
            onPressed: () {
              final parsed = int.tryParse(ctrl.text.trim());
              Navigator.pop(ctx, parsed);
            },
            child: Text(_tr('이동', 'Go', '跳转', '移動')),
          ),
        ],
      ),
    );

    if (targetPageOneBased != null && mounted) {
      final clampedPage = (targetPageOneBased - 1).clamp(0, _totalPages - 1).toInt();
      _goToPage(clampedPage, smoothAnimation: false);
    }
  }

  /// 진행바를 길게 눌러 끌어 옮기기 (놓으면 아래·왼쪽·오른쪽 중 가까운 가장자리로, 기억해 둠)
  bool _barMoving = false;
  int _pageAtBarDown = 0;
  Widget _movableBar(Widget Function() horizontalBody, Widget Function() verticalBody, Positioned p) => Positioned(
        key: p.key,
        left: p.left,
        top: p.top,
        right: p.right,
        bottom: p.bottom,
        width: p.width,
        height: p.height,
        child: HoldToMove(
          sides: const ['bottom', 'top', 'left', 'right'],
          current: _progressBarPosSetting,
          // 끄는 동안 손가락을 따라가는 진행바 (가장자리 근처에서는 그 자리 모양)
          feedback: (side) {
            final bool v = side == 'left' || side == 'right';
            return SizedBox(
              width: v ? 40.0 : barDragMaxLength(context, vertical: false),
              height: v ? barDragMaxLength(context, vertical: true) : 38.0,
              child: v ? verticalBody() : horizontalBody(),
            );
          },
          onDown: () => _pageAtBarDown = _currentPage,
          onHoldStart: () {
            _barMoving = true;
            // 누른 순간 진행바가 쪽을 옮겼으면 되돌림
            if (_currentPage != _pageAtBarDown) _goToPage(_pageAtBarDown, smoothAnimation: false);
          },
          // 손을 뗀 순간 진행바 안의 슬라이더가 받는 '끝' 처리보다 늦게 풂
          onEnd: () => Future.microtask(() => _barMoving = false),
          onDrop: (side) async {
            setState(() => _progressBarPosSetting = side);
            await StorageService.setProgressBarPosition(side);
          },
          child: p.child,
        ),
      );

  /// 진행도 UI의 화살표를 맨 처음(0페이지)과 맨 마지막(_totalPages - 1 페이지)으로 즉시 이동하는 용도로 변경!
  Widget _buildProgressControlBar(double bottomInset) {
    if (!_showControls || _totalPages <= 1 || _progressBarPos == 'hidden') {
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

    // 진행바 몸통: 가로(아래·위) / 세로(왼쪽·오른쪽). 끄는 동안 손가락을 따라가는 모양에도 씀
    Widget horizontalBody() => Material(
          color: Colors.black87,
          borderRadius: BorderRadius.circular(19),
          elevation: 5,
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
            child: Row(
              children: [
                IconButton(
                  icon: const Icon(Icons.first_page, color: Colors.white, size: 16),
                  tooltip: '처음으로 이동',
                  visualDensity: VisualDensity.compact,
                  padding: EdgeInsets.zero,
                  constraints: const BoxConstraints(minWidth: 28, minHeight: 28),
                  onPressed: () => _goToPage(0, smoothAnimation: false),
                ),
                Expanded(
                  child: SliderTheme(
                    data: SliderTheme.of(context).copyWith(
                      // 라이트·편안한 모드: 게이지(지나온 부분)는 시그니처 색
                      activeTrackColor: Theme.of(context).brightness == Brightness.light ? AppColors.signature : null,
                      thumbColor: Theme.of(context).brightness == Brightness.light ? AppColors.signatureDeep : null,
                      trackHeight: 2.8,
                      thumbShape: const RoundSliderThumbShape(enabledThumbRadius: 6.0),
                      overlayShape: const RoundSliderOverlayShape(overlayRadius: 11.0),
                    ),
                    child: Slider(
                      value: sliderVal,
                      min: 0.0,
                      max: sliderMax,
                      onChanged: (v) {
                        if (!_barMoving) _goToPage(v.round(), smoothAnimation: false);
                      },
                    ),
                  ),
                ),
                GestureDetector(
                  behavior: HitTestBehavior.opaque,
                  onTap: () => _showJumpToPageDialog(),
                  child: Padding(
                    padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 4),
                    child: Text(
                      '$displayedPageNum/$_totalPages',
                      style: const TextStyle(color: Colors.white, fontSize: 10.5, fontWeight: FontWeight.bold),
                    ),
                  ),
                ),
                IconButton(
                  icon: const Icon(Icons.last_page, color: Colors.white, size: 16),
                  tooltip: '마지막으로 이동',
                  visualDensity: VisualDensity.compact,
                  padding: EdgeInsets.zero,
                  constraints: const BoxConstraints(minWidth: 28, minHeight: 28),
                  onPressed: () => _goToPage(_totalPages - 1, smoothAnimation: false),
                ),
              ],
            ),
          ),
        );
    Widget verticalBody() => Material(
        color: Colors.black87,
        borderRadius: BorderRadius.circular(20),
        elevation: 5,
        child: Padding(
          padding: const EdgeInsets.symmetric(vertical: 6),
          child: Column(
            children: [
              IconButton(
                icon: const Icon(Icons.vertical_align_top, color: Colors.white, size: 16),
                tooltip: '처음으로 이동',
                visualDensity: VisualDensity.compact,
                padding: EdgeInsets.zero,
                constraints: const BoxConstraints(minWidth: 30, minHeight: 30),
                onPressed: () => _goToPage(0, smoothAnimation: false),
              ),
              Expanded(
                child: RotatedBox(
                  quarterTurns: 1,
                  child: SliderTheme(
                    data: SliderTheme.of(context).copyWith(
                      // 라이트·편안한 모드: 게이지(지나온 부분)는 시그니처 색
                      activeTrackColor: Theme.of(context).brightness == Brightness.light ? AppColors.signature : null,
                      thumbColor: Theme.of(context).brightness == Brightness.light ? AppColors.signatureDeep : null,
                      trackHeight: 2.8,
                      thumbShape: const RoundSliderThumbShape(enabledThumbRadius: 6.0),
                      overlayShape: const RoundSliderOverlayShape(overlayRadius: 11.0),
                    ),
                    child: Slider(
                      value: sliderVal,
                      min: 0.0,
                      max: sliderMax,
                      onChanged: (v) {
                        if (!_barMoving) _goToPage(v.round(), smoothAnimation: false);
                      },
                    ),
                  ),
                ),
              ),
              GestureDetector(
                behavior: HitTestBehavior.opaque,
                onTap: () => _showJumpToPageDialog(),
                child: Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 2, vertical: 4),
                  child: Text(
                    '$displayedPageNum/$_totalPages',
                    style: const TextStyle(color: Colors.white, fontSize: 9.5, fontWeight: FontWeight.bold),
                  ),
                ),
              ),
              IconButton(
                icon: const Icon(Icons.vertical_align_bottom, color: Colors.white, size: 16),
                tooltip: '마지막으로 이동',
                visualDensity: VisualDensity.compact,
                padding: EdgeInsets.zero,
                constraints: const BoxConstraints(minWidth: 30, minHeight: 30),
                onPressed: () => _goToPage(_totalPages - 1, smoothAnimation: false),
              ),
            ],
          ),
        ),
      );

    // 아래·위: 가로 막대 (위면 상단바 바로 아래)
    if (_progressBarPos == 'bottom' || _progressBarPos == 'top') {
      return _movableBar(horizontalBody, verticalBody, Positioned(
        key: const ValueKey('progress_bar'),
        left: 14.0 + _safeSides.left + ((_memoBarBesideProgress && _memoToolbarPos == 'left') ? _memoBarSideInset : 0.0),
        right: 14.0 + _safeSides.right + ((_memoBarBesideProgress && _memoToolbarPos == 'right') ? _memoBarSideInset : 0.0),
        top: _progressBarPos == 'top' ? _topBarsTop : null,
        bottom: _progressBarPos == 'top' ? null : baseBottom,
        height: 38.0,
        child: horizontalBody(),
      ));
    }

    final double topInset = MediaQuery.paddingOf(context).top;
    final bool memoBarVisible = _isMemoMode;
    // 메모 도구모음이 상단/하단에 있으면 세로 진행바가 그만큼 비켜 준다
    final double safeTopOffset = topInset + (_showControls ? 64.0 + _topBarsSpace : 16.0) + ((memoBarVisible && _memoToolbarPos == 'top') ? 52.0 : 0.0);
    final double safeBottomOffset = baseBottom + ((memoBarVisible && _memoToolbarPos == 'bottom') ? 96.0 : 8.0);
    return _movableBar(horizontalBody, verticalBody, Positioned(
      key: const ValueKey('progress_bar'),
      top: safeTopOffset,
      bottom: safeBottomOffset,
      left: _progressBarPos == 'left' ? 8.0 + _safeSides.left : null,
      right: _progressBarPos == 'right' ? 8.0 + _safeSides.right : null,
      width: 40.0,
      child: verticalBody(),
    ));
  }

  @override
  void dispose() {
    ToolbarLayout.current.removeListener(_onToolbarLayout);
    MemoTools.changed.removeListener(_onToolbarLayout);
    _tintHold.dispose();
    _sharpTimer?.cancel();
    _zoomController.removeListener(_onZoomMoved);
    _clearSharp(rebuild: false);
    if (_tapGuide?.mounted ?? false) _tapGuide!.remove();
    SystemBars.leaveViewer();
    _book.dispose();
    _textSel.dispose();
    // 서재로 완전히 복귀할 때 방향이 초기화됨
    _zoomController.dispose();
    WidgetsBinding.instance.removeObserver(this);
    _volumeKeyService.stopListening();
    _pageController?.dispose();
    // 닫으면 이 파일의 쪽 그림을 메모리에서 내림 (서재·다른 파일이 쓸 메모리를 비움)
    for (final f in _imagePages) {
      FileImage(f).evict().catchError((_) => false);
    }
    super.dispose();
  }

  // 도구 모음(화면 아래 가로 막대)에 들어가는 기능들
  /// 도구 모음 자리 ('bottom' / 'top' / 'left' / 'right', 길게 눌러 끌어 옮김)
  String _toolbarPos = 'bottom';

  /// 상단바 바로 아래 (위쪽에 둔 진행바·도구 모음이 놓이는 곳)
  double get _topBarsTop => MediaQuery.paddingOf(context).top + 64.0;

  /// 위쪽에 둔 진행바(38 + 간격)·도구 모음(52 + 간격)이 차지하는 높이 (그 밑의 것들이 비켜 줌)
  double get _topBarsSpace => _showControls ? (_progressBarPos == 'top' ? 44.0 : 0.0) + (_toolbarPos == 'top' ? 60.0 : 0.0) : 0.0;

  Widget _buildQuickToolBar(double bottomInset) {
    final bool vertical = _toolbarPos == 'left' || _toolbarPos == 'right';
    final List<QuickToolItem> barItems = ToolbarLayout.current.value.barFor(_barItems());
    // 도구 모음 설정: 맨 끝에 고정
    final QuickToolItem pinned = QuickToolItem(
      icon: const Icon(Icons.tune, color: Colors.white, size: 18),
      tooltip: _tr('도구 모음 설정', 'Toolbar Settings', '工具栏设置', 'ツールバー設定'),
      onTap: _showViewerSettingsSheet,
    );
    final Widget bar = HoldToMove(
      sides: const ['bottom', 'top', 'left', 'right'],
      current: _toolbarPos,
      // 끄는 동안 손가락을 따라가는 도구 모음 (가장자리 근처에서는 그 자리 모양)
      feedback: (side) {
        final bool v = side == 'left' || side == 'right';
        return ConstrainedBox(
          constraints: BoxConstraints(maxWidth: v ? 64 : barDragMaxLength(context, vertical: false), maxHeight: v ? barDragMaxLength(context, vertical: true) : 64),
          child: QuickToolBar(vertical: v, items: barItems, pinned: pinned),
        );
      },
      // 아이콘을 길게 누르면 뜨는 이름 풍선은 옮기기 시작할 때 닫음
      onHoldStart: () => Tooltip.dismissAllToolTips(),
      onDrop: (side) async {
        setState(() => _toolbarPos = side);
        await StorageService.setToolbarPosition(side);
      },
      child: QuickToolBar(vertical: vertical, items: barItems, pinned: pinned),
    );
    final double bottom = math.max<double>(bottomInset + 16.0, 20.0) + 8.0 + (_progressBarPos == 'bottom' ? 44.0 : 0.0);
    // 위·아래: 가로 (위면 상단바 아래, 위쪽 진행바가 있으면 그 밑)
    if (!vertical) {
      final bool top = _toolbarPos == 'top';
      return Positioned(
        key: const ValueKey('quick_tool_bar'),
        left: 12.0 + _safeSides.left,
        right: 12.0 + _safeSides.right,
        top: top ? _topBarsTop + (_progressBarPos == 'top' ? 44.0 : 0.0) : null,
        bottom: top ? null : bottom,
        child: Center(child: bar),
      );
    }
    // 세로: 상단바 아래부터 진행바 위까지, 같은 쪽에 세로 진행바가 있으면 그 안쪽으로
    final bool left = _toolbarPos == 'left';
    final double side = 10.0 + (left ? _safeSides.left : _safeSides.right) + (_progressBarPos == _toolbarPos ? 48.0 : 0.0);
    return Positioned(
      key: const ValueKey('quick_tool_bar'),
      left: left ? side : null,
      right: left ? null : side,
      top: _topBarsTop + (_progressBarPos == 'top' ? 44.0 : 0.0),
      bottom: bottom - 8.0,
      child: Center(child: bar),
    );
  }

  /// 상단바·도구 모음에 둘 수 있는 모든 아이콘 (이 파일에서 쓸 수 있는 것만). 어디에 어떤 순서로 둘지는 [ToolbarLayout]
  Map<String, QuickToolItem> _barItems() {
    final list = <QuickToolItem>[
      QuickToolItem(
        id: 'prev',
        icon: const Icon(Icons.skip_previous_rounded, color: Colors.white, size: 19),
        tooltip: _tr('이전 파일로 이동', 'Previous File', '上一个文件', '前のファイル'),
        onTap: () => _openAdjacentFileInSameGroup(-1),
        enabled: _prevFilePath != null,
        closeAfterTap: true,
      ),
      QuickToolItem(
        id: 'next',
        icon: const Icon(Icons.skip_next_rounded, color: Colors.white, size: 19),
        tooltip: _tr('다음 파일로 이동', 'Next File', '下一个文件', '次のファイル'),
        onTap: () => _openAdjacentFileInSameGroup(1),
        enabled: _nextFilePath != null,
        closeAfterTap: true,
      ),
      QuickToolItem(
        id: 'rotate',
        // 누르면 살짝 흔들리고, 가로로 돌려 둔 상태면 노란색
        // 누르면 회전 설정 창 (자동 / 세로 고정 / 가로 고정). 아이콘은 고른 설정 모양, 고정이면 노란색
        icon: WiggleOnChange(
          trigger: _rotateTapCount,
          // 설정 창에서 고른 것과 같은 아이콘
          child: rotationGlyph(
            _rotationModeNow,
            color: StorageService.desiredLandscapeNotifier.value != null ? Colors.amber : Colors.white,
            size: 17,
          ),
        ),
        tooltip: _tr('화면 회전', 'Rotate Screen', '旋转屏幕', '画面回転'),
        onTap: _pickRotation,
        closeAfterTap: true,
      ),
      QuickToolItem(
        id: 'display',
        // 페이지 표시 (한 페이지 / 두 페이지 / 자동)
        // 설정 창에서 고른 것과 같은 아이콘
        icon: pageDisplayGlyph(
          _pageDisplay,
          color: _pageDisplay != 'one' ? Colors.amber : Colors.white,
          size: 17,
        ),
        tooltip: _tr('페이지 표시', 'Page Display', '页面显示', 'ページ表示'),
        onTap: _pickPageDisplay,
        closeAfterTap: true,
      ),
      // 페이지 모드 (탭 / 슬라이드 / 스크롤): 지금 모드 아이콘
      QuickToolItem(
        id: 'mode',
        icon: PageModeIcon(mode: _pageModeScroll ? 'scroll' : (_pageModeTap && _useSwipeTurn ? 'tap+slide' : (_useSwipeTurn ? 'slide' : 'tap')), color: Colors.white, size: 19),
        tooltip: _tr('페이지 이동', 'Page Turning', '翻页', 'ページ移動'),
        onTap: _pickPageMode,
        closeAfterTap: true,
      ),
      QuickToolItem(
        id: 'direction',
        label: _tr('읽기 방향', 'Reading Direction', '阅读方向', '読む方向'),
        icon: _buildDualDirectionIcon(),
        tooltip: _isMangaRtlMode
            ? _tr('읽기 방향 전환 (우 → 좌)', 'Reading Direction (R → L)', '切换阅读方向 (右 → 左)', '読書方向切替 (右 → 左)')
            : _tr('읽기 방향 전환 (좌 → 우)', 'Reading Direction (L → R)', '切换阅读方向 (左 → 右)', '読書方向切替 (左 → 右)'),
        onTap: () async {
          // 스크롤 모드는 원본 순서 그대로라 읽기 방향을 바꾸지 않음
          if (_pageModeScroll) {
            ScaffoldMessenger.of(context)
              ..clearSnackBars()
              ..showSnackBar(SnackBar(
                content: Text(_tr('스크롤 모드에서는 읽기 방향이 바뀌지 않아요\n탭·슬라이드 모드에서 바꿀 수 있어요',
                    'Reading direction does not change in scroll mode\nChange it in tap/slide mode',
                    '滚动模式下不能切换阅读方向，请在点击/滑动模式下切换',
                    'スクロールモードでは読書方向は変わりません\nタップ・スライドモードで変更できます')),
                duration: const Duration(seconds: 2),
              ));
            return;
          }
          final nextRtl = !_isMangaRtlMode;
          await StorageService.setBookReadingDirectionRtl(_bookKey, nextRtl);
          setState(() => _isMangaRtlMode = nextRtl);
          if (mounted) {
            ScaffoldMessenger.of(context).clearSnackBars();
            ScaffoldMessenger.of(context).showSnackBar(
              SnackBar(
                content: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Text(_tr('읽기 방향 전환 (', 'Reading Direction (', '切换阅读方向 (', '読書方向切替 (')),
                    Text(nextRtl ? _tr('우 ', 'R ', '右 ', '右 ') : _tr('좌 ', 'L ', '左 ', '左 ')),
                    // 알림 바탕이 밝아지는 다크·밝은 다크 테마에서는 검은 화살표
                    Icon(Icons.arrow_forward_rounded, color: Theme.of(context).colorScheme.onInverseSurface, size: 14),
                    Text(nextRtl ? _tr(' 좌)', ' L)', ' 左)', ' 左)') : _tr(' 우)', ' R)', ' 右)', ' 右)')),
                  ],
                ),
                duration: const Duration(milliseconds: 900),
              ),
            );
          }
        },
      ),
      QuickToolItem(
        id: 'memo',
        icon: MemoToolIcon(kind: 'memo', color: _isMemoMode ? Colors.amber : Colors.white, size: 22),
        tooltip: _tr('메모', 'Memo', '笔记', 'メモ'),
        onTap: () {
          // 스크롤 모드에서도 쪽마다 같은 메모 (넘겨 보기와 함께 씀)
          setState(() {
            _isMemoMode = !_isMemoMode;
            _isEraserMode = false;
            if (!_isMemoMode) _allowFingerDrawing = false;
          });
        },
        closeAfterTap: true,
      ),
      if (_isPdfFile)
        QuickToolItem(
        id: 'copy',
          icon: const Icon(Icons.copy_all_outlined, color: Colors.white, size: 17),
          tooltip: _tr('글자 복사', 'Copy Text', '复制文字', '文字をコピー'),
          onTap: _openTextCopySheet,
          closeAfterTap: true,
        ),
      QuickToolItem(
        id: 'bookmark',
        icon: Icon(
          _isCurrentPageBookmarked ? Icons.bookmarks : Icons.bookmarks_outlined,
          color: _isCurrentPageBookmarked ? Colors.amber : Colors.white,
          size: 17,
        ),
        tooltip: _tr('북마크', 'Bookmarks', '书签', 'ブックマーク'),
        onTap: _showBookmarkSheet,
        closeAfterTap: true,
      ),
      // 상단바에 있던 것들 (도구 모음 설정에서 어디에 둘지 고름)
      if (_isPdfFile)
        QuickToolItem(
          id: 'find',
          icon: const Icon(Icons.search, color: Colors.white, size: 18),
          tooltip: _tr('파일 내 단어 검색', 'Find in File', '在文件中查找', 'ファイル内検索'),
          label: _tr('단어 검색', 'Find in File', '在文件中查找', 'ファイル内検索'),
          onTap: _openFind,
        ),
      if (_isPdfFile)
        QuickToolItem(
          id: 'toc',
          icon: const Icon(Icons.list, color: Colors.white, size: 17),
          tooltip: _tr('목차', 'Contents', '目录', '目次'),
          onTap: () => _scaffoldKey.currentState?.openDrawer(),
        ),
    ];
    return {for (final it in list) it.id: it};
  }

  /// 지금 보고 있는 쪽(2페이지 보기면 두 쪽)의 글을 보여 주고 복사할 수 있게 함
  Future<void> _openTextCopySheet() async {
    final bool spread = _isSpreadActive(context);
    final int first = spread ? (_currentPage ~/ 2) * 2 : _currentPage;
    final pages = await _pdfLines(widget.files.first.path, first, math.min(_totalPages, first + (spread ? 2 : 1)), false);
    if (!mounted) return;
    var text = pages.map((p) => p.lines.map((l) => l['t']).join('\n')).join('\n\n');
    if (text.trim().isEmpty) {
      // 글자 정보가 없는 쪽(그림으로 된 쪽·스캔본): 쪽 그림에서 글자를 읽어 옴
      final parts = <String>[];
      for (int i = first; i < math.min(_totalPages, first + (spread ? 2 : 1)); i++) {
        if (i >= _imagePages.length) break;
        try {
          final raw = await _pdfChannel.invokeMethod<List<Object?>>('ocrLines', {'path': _imagePages[i].path}) ?? const [];
          final ls = [for (final e in raw) if (e is Map && '${e['t'] ?? ''}'.trim().isNotEmpty) e]
            ..sort((a, b) => ((a['y'] as num?) ?? 0).compareTo((b['y'] as num?) ?? 0));
          parts.add(ls.map((e) => '${e['t']}'.trim()).join('\n'));
        } catch (_) {}
      }
      text = parts.where((t) => t.isNotEmpty).join('\n\n');
    }
    if (!mounted) return;
    await showTextCopySheet(context, text: text, tr: _tr);
  }

  void _resetAnyZoom() {
    if (_currentZoomScale > 1.0001) {
      _zoomController.value = Matrix4.identity();
      setState(() => _currentZoomScale = 1.0);
    }
    _scrollCtrl.resetZoom();
  }

  Orientation? _zoomOrientation;

  /// 확대한 채로 화면을 돌리면 원래 크기로 돌려놓고 돌림
  void _resetZoomOnRotate(BuildContext context) {
    final Orientation o = MediaQuery.orientationOf(context);
    final Orientation? prev = _zoomOrientation;
    _zoomOrientation = o;
    if (prev == null || prev == o) return;
    if (!(_currentZoomScale > 1.0001 || _scrollCtrl.zoomed)) return;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) _resetAnyZoom();
    });
  }

  @override
  Widget build(BuildContext context) {
    _resetZoomOnRotate(context);
    // 메뉴를 띄운 동안에는 상태표시줄도 함께 보임
    SystemBars.viewerStatus(_showControls);
    if (_isPreparingPages || _pageController == null) {
      return Scaffold(
        backgroundColor: _backdrop(context),
        body: FileLoadingView(label: _tr('파일 여는 중…', 'Opening file…', '正在打开文件', 'ファイルを開いています'), dark: Theme.of(context).brightness == Brightness.dark),
      );
    }

    // 키보드(페이지 이동 창 등)가 올라올 때 화면 전체가 매 프레임 다시 그려지지 않도록 필요한 값만 구독
    final double bottomInset = MediaQuery.viewPaddingOf(context).bottom;
    final bool isSpread = _isSpreadActive(context);

    if (isSpread != _lastIsSpreadMode) {
      _lastIsSpreadMode = isSpread;
      final int targetViewIdx = isSpread ? (_currentPage ~/ 2) : _currentPage;
      _pageController?.dispose();
      _pageController = PageController(initialPage: targetViewIdx);
    }

    final int viewItemCount = isSpread ? ((_totalPages + 1) ~/ 2) : _totalPages;

    return PopScope(
      canPop: !_findOpen,
      onPopInvokedWithResult: (didPop, _) {
        if (!didPop && _findOpen) {
          _closeFind(); // 뒤로 가기: 검색만 닫음
          return;
        }
      },
      child: Scaffold(
      key: _scaffoldKey,
      drawer: _isPdfFile ? _buildTocDrawer() : null,
      drawerEnableOpenDragGesture: false,
      // 페이지 이동 창의 키보드가 올라와도 뒤의 책 화면은 줄이지 않는다 (줄어드는 동안 버벅임)
      resizeToAvoidBottomInset: false,
      backgroundColor: _backdrop(context),
      body: Stack(
        fit: StackFit.expand,
        children: [
          Positioned.fill(
            child: Listener(
                behavior: HitTestBehavior.translucent,
                onPointerDown: (event) {
                  _curlTrackDown(event); // (손가락 목록에 넣기 전에 확인)
                  if (event.kind == PointerDeviceKind.touch) {
                    if (_activeTouchPointerIds.isEmpty) _pinchSeen = false;
                    _activeTouchPointerIds.add(event.pointer);
                    if (_activeTouchPointerIds.length >= 2) {
                      _pinchSeen = true;
                      setState(() {});
                    }
                  }
                  if (_isMemoMode &&
                      (event.kind == PointerDeviceKind.stylus ||
                          event.kind == PointerDeviceKind.invertedStylus)) {
                    if (!_isStylusDown) {
                      setState(() => _isStylusDown = true);
                    }
                  }
                },
                onPointerMove: (event) {
                  _curlTrackMove(event);
                },
                onPointerUp: (event) {
                  _curlTrackUp(event);
                  if (_activeTouchPointerIds.remove(event.pointer)) {
                    setState(() {});
                  }
                  if (_isStylusDown &&
                      (event.kind == PointerDeviceKind.stylus ||
                          event.kind == PointerDeviceKind.invertedStylus)) {
                    setState(() => _isStylusDown = false);
                  }
                },
                onPointerCancel: (event) {
                  if (_book.tracking) _book.end(cancel: true);
                  _curlDownPos = null;
                  if (_activeTouchPointerIds.remove(event.pointer)) {
                    setState(() {});
                  }
                  if (_isStylusDown) {
                    setState(() => _isStylusDown = false);
                  }
                },
                child: GestureDetector(
                  behavior: HitTestBehavior.translucent,
                  onTapUp: (d) => _onViewerTap(d.localPosition),
                  // PDF: 길게 누르면 그 쪽의 글을 고르고 복사하는 창 (그림으로만 된 쪽은 그림 속 글자를 읽음)
                  // PDF: 길게 누르면 그 자리의 낱말을 고르고 손잡이로 범위를 조절 → [복사 | 모두 선택 | 공유]
                  // (글자 정보가 없는 쪽은 그림 속 글자를 읽어 복사하는 창)
                  onLongPressStart: _isPdfFile ? (d) {
                    if (_isMemoMode || _activeTouchPointerIds.length >= 2 || _currentZoomScale > 1.03) return;
                    if (_pageModeScroll) {
                      HapticFeedback.selectionClick();
                      _openTextCopySheet();
                      return;
                    }
                    _startTextSelect(d.globalPosition);
                  } : null,
                  onLongPressMoveUpdate: _isPdfFile ? (d) {
                    final local = _textLocal(d.globalPosition);
                    if (local != null && _textSel.active) _textSel.extendTo(local);
                  } : null,
                  // PDF·CBZ 쪽은 원래 크기·선명도 그대로 (앱 화면을 크게 보여 줄 때도)
                  child: UiUnscale(child: _pageModeScroll ? _buildScrollPages() : _buildPageStage(context,
                    PageView.builder(
                    key: ValueKey('pageview_spread_$isSpread'),
                    controller: _pageController,
                    reverse: _isMangaRtlMode,
                    physics: (!_useSwipeTurn ||
                            _curlOn ||
                            _activeTouchPointerIds.length >= 2 ||
                            _currentZoomScale > 1.03 ||
                            (_isMemoMode && (_isStylusDown || _allowFingerDrawing)))
                        ? const NeverScrollableScrollPhysics()
                        : const BouncingScrollPhysics(),
                  itemCount: viewItemCount,
                  onPageChanged: (viewIdx) {
                    int actualPage = isSpread ? (viewIdx * 2) : viewIdx;
                    if (isSpread && viewIdx == viewItemCount - 1) {
                      actualPage = (_totalPages - 1).clamp(0, _totalPages - 1).toInt();
                    }
                    _zoomController.value = Matrix4.identity();
                    _textSel.clear();
                    _clearSharp(rebuild: false);
                    setState(() {
                      _currentZoomScale = 1.0;
                      _currentPage = actualPage;
                    });
                    _ensurePageDimensionLoaded(actualPage);
                    if (actualPage + 1 < _totalPages) _ensurePageDimensionLoaded(actualPage + 1);
                    _precacheAround(actualPage);
                    StorageService.saveLastPosition(_bookKey, actualPage.toString());
                    StorageService.saveProgress(_bookKey, (actualPage + 1) / _totalPages);
                    StorageService.savePageLabel(_bookKey, '${actualPage + 1}/$_totalPages');
                  },
                  itemBuilder: (context, viewIdx) {
                    final Widget pageChild = _buildViewPageContent(viewIdx, isSpread);

                    return LayoutBuilder(builder: (context, stage) {
                    _stageSize = stage.biggest;
                    return InteractiveViewer(
                      transformationController: _zoomController,
                      // 메모 중에도 (손으로 그리기가 아니면) 손가락으로 확대한 쪽을 옮김 (삼성 노트처럼: 펜은 쓰고 손가락은 움직임)
                      panEnabled: (!_isMemoMode || !_allowFingerDrawing) && (_currentZoomScale > 1.03 || _activeTouchPointerIds.length >= 2),
                      scaleEnabled: (!_isMemoMode || !_allowFingerDrawing),
                      minScale: 1.0,
                      maxScale: 5.0,
                      onInteractionUpdate: (_) {
                        final s = _zoomController.value.getMaxScaleOnAxis();
                        if ((s - _currentZoomScale).abs() > 0.02) {
                          setState(() => _currentZoomScale = s);
                        }
                      },
                      onInteractionEnd: (_) {
                        final s = _zoomController.value.getMaxScaleOnAxis();
                        if (s < 1.03) {
                          _zoomController.value = Matrix4.identity();
                          if (_currentZoomScale != 1.0) {
                            setState(() => _currentZoomScale = 1.0);
                          }
                        } else if ((s - _currentZoomScale).abs() > 0.01) {
                          setState(() => _currentZoomScale = s);
                        }
                      },
                      child: pageChild,
                    );
                    });
                  },
                  ),
                  )),
                ),
              ),
          ),

          if (_findOpen)
            Positioned(
              top: 0,
              left: 0,
              right: 0,
              child: FindInFileBar(onSearch: _findSearch, onGoto: _findGoto, onClose: _closeFind, tr: _tr),
            ),
          if (_showControls && !_findOpen)
            Positioned(
              top: 0,
              left: 0,
              right: 0,
              child: AnnotatedRegion<SystemUiOverlayStyle>(
                // 메뉴와 함께 보이는 상태표시줄: 검은 막대 위라 흰 아이콘
                value: SystemUiOverlayStyle.light.copyWith(statusBarColor: Colors.transparent),
                child: Material(
                color: Colors.black87,
                child: SafeArea(
                  bottom: false,
                  child: Padding(
                    padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 4),
                    child: LayoutBuilder(
                      builder: (context, barConstraints) {
                        const btnConstraints = BoxConstraints(minWidth: 38, minHeight: 40);
                        const btnPadding = EdgeInsets.symmetric(horizontal: 6, vertical: 4);

                        // 기본 순서: 파일 내 단어 검색 · 목차 (도구 모음 설정은 도구 모음 맨 오른쪽)
                        final actionButtons = <Widget>[
                          // 도구 모음 설정에서 상단바에 둔 아이콘 (왼쪽부터)
                          for (final it in ToolbarLayout.current.value.topFor(_barItems()))
                            topBarButton(it, padding: btnPadding, constraints: btnConstraints),
                        ];

                        return Row(
                          children: [
                            IconButton(
                              visualDensity: VisualDensity.compact,
                              padding: btnPadding,
                              constraints: btnConstraints,
                              icon: const Icon(Icons.arrow_back, color: Colors.white, size: 17),
                              onPressed: () => Navigator.pop(context),
                            ),
                            // 파일 이름은 화면 방향과 상관없이 항상 표시 (남는 공간을 모두 사용)
                            Expanded(
                              child: Padding(
                                padding: const EdgeInsets.symmetric(horizontal: 6),
                                child: Text(
                                  widget.title,
                                  style: const TextStyle(color: Colors.white, fontSize: 14),
                                  overflow: TextOverflow.ellipsis,
                                  maxLines: 1,
                                ),
                              ),
                            ),
                            ...actionButtons,
                          ],
                        );
                      },
                    ),
                  ),
                ),
              )),
            ),

          _buildProgressControlBar(bottomInset),

          // 도구 모음: 아래(가로) 또는 왼쪽·오른쪽(세로). 길게 눌러 끌어 옮김 (상단바·진행바와 함께 보였다 사라짐)
          if (_showControls) _buildQuickToolBar(bottomInset),
          // 메모 도구 모음: 파일 도구 모음보다 위에 (아래에 둘 때는 도구 모음 바로 위)
          if (_isMemoMode) _buildMemoToolbar(bottomInset),
        ],
      ),
      ),
    );
  }
}

/// 찾은 단어 형광펜 (쪽 크기 대비 0~1 좌표의 사각형)
class _FindMarkPainter extends CustomPainter {
  _FindMarkPainter(this.all, this.current);
  final List<Rect> all;
  final List<Rect> current;

  @override
  void paint(Canvas canvas, Size size) {
    void draw(List<Rect> rects, Color color) {
      final paint = Paint()
        ..color = color
        ..blendMode = BlendMode.multiply;
      for (final r in rects) {
        canvas.drawRect(Rect.fromLTRB(r.left * size.width, r.top * size.height, r.right * size.width, r.bottom * size.height), paint);
      }
    }
    draw(all, const Color(0x99FFEB3B));
    draw(current, const Color(0xE6FFC107));
  }

  @override
  bool shouldRepaint(_FindMarkPainter old) => old.all != all || old.current != current;
}

/// PDF 한 쪽의 모양(가로÷세로)과 줄들
class _PdfPageLines {
  const _PdfPageLines(this.aspect, this.lines);
  final double aspect;
  final List<Map<String, Object?>> lines;
}
