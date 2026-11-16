import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math' as math;
import 'dart:ui' as ui;
import 'package:flutter/rendering.dart';
import 'package:flutter/scheduler.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_epub_viewer/flutter_epub_viewer.dart';
import 'package:path_provider/path_provider.dart';
import '../services/library_nav.dart';
import '../services/storage_service.dart';
import '../services/system_bars.dart';
import '../services/txt_page_document.dart';
import '../services/toc_page_parser.dart';
import '../services/heading_rules.dart';
import '../services/outline_cache.dart';
import '../widgets/outline_progress.dart';
import '../widgets/text_copy_sheet.dart';
import '../widgets/text_select.dart';
import '../services/page_snapshot_service.dart';
import '../services/user_fonts.dart';
import '../services/epub_validation.dart';
import '../widgets/hwp_viewer.dart';
import '../widgets/spreadsheet_tab_bar.dart';
import '../widgets/txt_paged_viewer.dart';
import '../services/volume_key_service.dart';
import '../widgets/quick_tool_bar.dart';
import '../widgets/viewer_dialogs.dart';
import '../widgets/app_colors.dart';
import '../widgets/morph_icons.dart';
import '../widgets/word_selection_layer.dart';
import '../widgets/ui_scale.dart';
import '../widgets/sheet_pull_to_close.dart';
import '../services/file_share.dart';
import '../widgets/memo_tools.dart';
import '../widgets/after_route_transition.dart';
import '../widgets/direction_arrow_icon.dart';
import '../widgets/find_in_file_bar.dart';
import 'pdf_and_image_viewer.dart';
import '../widgets/pop_dialog.dart';
import '../widgets/group_jump_menu.dart';
import '../widgets/page_curl.dart';
import '../widgets/bookmark_ribbon.dart';

/// 메모 좌표(0~1) ↔ 화면 자리.
/// 문서는 보이는 쪽들을 여백까지 포함한 쪽 전체 크기로 왼쪽부터 이어 붙인 판이 0~1 —
/// 쪽마다 따로 맞추므로 화면을 돌리거나 여백 줄이기로 잘린 폭이 달라져도 메모가 글자 위에 그대로 있음
class _MemoMap {
  _MemoMap(this.pages, this.hits, {this.transform, this.shift = Offset.zero})
      : _sumW = pages.fold(0.0, (a, r) => a + r.width),
        _maxH = pages.isEmpty ? 0 : pages.map((r) => r.height).reduce(math.max);
  _MemoMap.rect(Rect r, {Matrix4? transform}) : this([r], [r], transform: transform);

  /// 쪽 전체 자리 (화면 왼쪽부터, 확대 전 좌표)
  final List<Rect> pages;

  /// 보이는 쪽 자리 (그린 곳이 어느 쪽인지 고를 때)
  final List<Rect> hits;
  final Matrix4? transform;
  final Offset shift;
  final double _sumW, _maxH;

  bool get valid => pages.isNotEmpty && _sumW > 0 && _maxH > 0;
  double get _scale => transform?.getMaxScaleOnAxis() ?? 1;

  /// 굵기 기준 너비 (화면 px, 확대 포함)
  double get unit => _sumW * _scale;

  _MemoMap shifted(Offset d) => _MemoMap(pages, hits, transform: transform, shift: shift + d);

  Offset toLocal(double fx, double fy) {
    final double vx = fx * _sumW;
    double o = 0;
    int i = 0;
    for (; i < pages.length - 1; i++) {
      if (vx < o + pages[i].width) break;
      o += pages[i].width;
    }
    final Rect r = pages[i];
    Offset p = Offset(r.left + vx - o, r.top + fy * _maxH);
    if (transform != null) p = MatrixUtils.transformPoint(transform!, p);
    return p + shift;
  }

  Offset toFrac(Offset local) {
    Offset p = local - shift;
    if (transform != null) {
      final inv = Matrix4.tryInvert(transform!);
      if (inv != null) p = MatrixUtils.transformPoint(inv, p);
    }
    int i = 0;
    double best = double.infinity;
    for (int j = 0; j < hits.length && j < pages.length; j++) {
      final h = hits[j];
      final double d = p.dx < h.left ? h.left - p.dx : (p.dx > h.right ? p.dx - h.right : 0.0);
      if (d < best) {
        best = d;
        i = j;
      }
    }
    double o = 0;
    for (int j = 0; j < i; j++) {
      o += pages[j].width;
    }
    return Offset((o + p.dx - pages[i].left) / _sumW, (p.dy - pages[i].top) / _maxH);
  }
}

class _MemoPainter extends CustomPainter {
  final List<MemoStroke> strokes;
  final List<Offset> currentPoints;
  final Color currentColor;
  final double currentWidth;

  /// 저장된 획의 0~1 좌표가 가리키는 자리 (문서는 쪽들, 그 밖은 화면). 없으면 그리는 곳 전체
  final _MemoMap? map;

  _MemoPainter({
    required this.strokes,
    required this.currentPoints,
    required this.currentColor,
    required this.currentWidth,
    this.map,
  });

  @override
  void paint(Canvas canvas, Size size) {
    final _MemoMap m = (map != null && map!.valid) ? map! : _MemoMap.rect(Offset.zero & size);
    for (final s in strokes) {
      if (s.dxList.isEmpty) continue;
      final paint = Paint()
        ..color = Color(s.colorValue)
        ..strokeWidth = s.widthOn(m.unit)
        ..strokeCap = StrokeCap.round
        ..strokeJoin = StrokeJoin.round
        ..style = PaintingStyle.stroke;

      final path = Path();
      final first = m.toLocal(s.dxList.first, s.dyList.first);
      path.moveTo(first.dx, first.dy);
      for (int i = 1; i < s.dxList.length; i++) {
        final p = m.toLocal(s.dxList[i], s.dyList[i]);
        path.lineTo(p.dx, p.dy);
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
  bool shouldRepaint(covariant _MemoPainter oldDelegate) => true;
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

class _ReaderScreenState extends State<ReaderScreen> with WidgetsBindingObserver, TickerProviderStateMixin {
  static const MethodChannel _pdfChannel = MethodChannel('ebook_reader/pdf_renderer');
  final GlobalKey<ScaffoldState> _scaffoldKey = GlobalKey<ScaffoldState>();
  final EpubController _epubController = EpubController();

  // ── TXT / 워드(DOC·DOCX) / 한글(HWP·HWPX): EPUB과 같은 화면·메모·북마크를 쓰고 본문만 각자의 뷰어로 표시 ──
  final HwpReaderController _hwpController = HwpReaderController(); // DOC·DOCX·HWP·HWPX (WebView)
  final TxtPageController _txtController = TxtPageController(); // TXT (종이 쪽 단위)
  final GlobalKey _txtCaptureKey = GlobalKey(); // TXT 화면 그림 (책처럼 넘기기)용
  bool get _isTxt => widget.filePath.toLowerCase().endsWith('.txt');
  bool get _isEpub => !_isOfflineDocument;
  bool get _isPaperTheme => _isEpub && _epubBgTheme == 'sepia';
  bool get _isOfflineDocument => RegExp(r'\.(hwp|hwpx|docx|doc|txt|pptx|ppt|xlsx|xlsm|xls)$', caseSensitive: false).hasMatch(widget.filePath);
  bool get _isPresentation => RegExp(r'\.pptx?$', caseSensitive: false).hasMatch(widget.filePath);
  bool get _isSpreadsheet => RegExp(r'\.xls[xm]?$', caseSensitive: false).hasMatch(widget.filePath);
  bool get _isHwpFile => RegExp(r'\.hwpx?$', caseSensitive: false).hasMatch(widget.filePath);
  String get _documentPositionPrefix {
    final lower = widget.filePath.toLowerCase();
    if (_isTxt) return 'txt';
    if (_isSpreadsheet) return lower.split('.').last;
    if (lower.endsWith('.pptx')) return 'pptx';
    if (lower.endsWith('.ppt')) return 'ppt';
    if (lower.endsWith('.docx')) return 'docx';
    if (lower.endsWith('.doc')) return 'doc';
    return 'hwp';
  }

  int _docPage = 0; // 문서의 현재 쪽 (0부터)
  int _docPageCount = 0; // 문서 전체 쪽 수
  int _docLoadedPages = 0; // 다 읽어 들인 뒤의 전체 쪽 수 (1쪽뿐이면 두 페이지 보기를 쓰지 않음)
  int _docRelocation = 0;
  double _initialProgress = 0.0;
  final VolumeKeyService _volumeKeyService = VolumeKeyService();

  late String _activeFilePath;

  String? _initialCfi;
  String? _currentCfi;
  String? _selectedCfiRange;
  String _selectedText = '';
  bool _isLoading = true;
  String _epubBgTheme = 'white'; // 'white', 'sepia', 'dark'
  // 파일 안 테마 '편안한 모드' (EPUB·PPT·엑셀 제외): 라이트로 그리고 화면 위에 따뜻한 색을 덮음
  bool _docComfort = false;
  bool get _docComfortAllowed => !_isEpub && !_isPresentation && !_isSpreadsheet;
  // 페이지 표시: 'one' / 'two' / 'auto'(화면이 넓으면 두 페이지)
  String _pageDisplay = 'one';
  // 사용자가 고른 EPUB 본문 글꼴 (없으면 책의 글꼴)
  UserFontEntry? _epubFont;
  // 페이지 모드: 탭(누른 자리로 넘김) / 스크롤(세로로 이어 보기) / 슬라이드(= _useSwipeTurn)
  bool _pageModeTap = true;
  bool _storedPageModeScroll = false; // 저장된 스크롤 설정 (PPT는 스크롤 대신 슬라이드로 보여 줌)
  bool _pageModeScroll = false;
  final ContinuousPageController _scrollCtrl = ContinuousPageController();

  /// 두 쪽을 나란히 보여 줄 때인가 (스크롤 모드는 쪽이 바뀌지 않음, EPUB은 늘 한 페이지, 쪽이 하나뿐인 문서도 한 페이지)
  bool _spreadFor(bool isLandscape) =>
      !_isEpub && !_isSpreadsheet && _docLoadedPages != 1 && !_pageModeScroll && !_slideShow && (_pageDisplay == 'two' || (_pageDisplay == 'auto' && isLandscape));
  bool _isMangaRtlMode = false;
  int _fontSize = 18;
  List<EpubChapter> _chapters = [];
  List<int> _chapterLevels = const []; // 워드·한글·PPT 목차 항목의 단계 (들여쓰기용, 비어 있으면 단계 없음)

  // ── 본문 로딩 감시: 책이 끝내 그려지지 않아 흰 화면만 남는 상황을 복구 ──
  Timer? _epubLoadWatchdog;
  String? _epubWatchKey;
  bool _epubDisplayed = false;
  bool _epubReadySignalResent = false;
  int _epubViewerGeneration = 0;
  bool _epubRetriedWithoutCfi = false;
  bool _epubLoadFailureShown = false;

  // WebView가 epubView.js 준비 신호(readyToLoad)를 Flutter 쪽 핸들러 등록 전에 보내 버리면
  // 책 로딩이 영원히 시작되지 않는다. 아직 한 번도 로딩되지 않았을 때만 신호를 다시 보낸다.
  static const String _epubReadyRecoveryJs =
      "(function(){try{if(typeof loadBook==='function'&&typeof currentLoadToken!=='undefined'&&"
      "currentLoadToken===0&&window.flutter_inappwebview&&"
      "typeof window.flutter_inappwebview.callHandler==='function'){"
      "window.flutter_inappwebview.callHandler('readyToLoad');}}catch(e){}})()";

  void _startEpubLoadWatchdog(String key) {
    if (_epubWatchKey == key) return;
    _epubWatchKey = key;
    if (mounted) {
      setState(() => _epubDisplayed = false);
    } else {
      _epubDisplayed = false;
    }
    _epubReadySignalResent = false;
    _epubLoadWatchdog?.cancel();
    final started = DateTime.now();
    _epubLoadWatchdog = Timer.periodic(const Duration(seconds: 2), (timer) {
      if (!mounted || _epubDisplayed || _epubWatchKey != key) {
        timer.cancel();
        return;
      }
      final int secs = DateTime.now().difference(started).inSeconds;
      if (secs >= 5 && !_epubReadySignalResent) {
        _epubReadySignalResent = true;
        _epubController.webViewController
            ?.callMethod('eval', [_epubReadyRecoveryJs])
            .catchError((_) => null);
      }
      if (secs >= 16 && secs < 18 && _epubViewerGeneration == 0) {
        // 책 로딩이 아예 시작되지 않은 채 WebView가 멈춘 경우에만 뷰어를 한 번 새로 만들어 다시 시도
        // (큰 책을 정상적으로 읽어 들이는 중이면 그대로 기다림)
        _epubController.webViewController
            ?.callMethod('eval', [
              "(function(){return (typeof currentLoadToken==='undefined')?-1:currentLoadToken;})()"
            ])
            .then((value) {
              final int token = (value is num) ? value.toInt() : -1;
              if (!mounted || _epubDisplayed || _epubWatchKey != key) return;
              if (token <= 0) {
                timer.cancel();
                setState(() => _epubViewerGeneration++);
              }
            })
            .catchError((_) => null);
        return;
      }
      if (secs >= 90) {
        timer.cancel();
        _handleEpubLoadError(_tr(
          '본문 표시 시간이 초과됐어요',
          'Timed out while displaying the document',
          '显示正文超时',
          '本文の表示がタイムアウトしました',
        ));
      }
    });
  }

  void _handleEpubLoadError(String message) {
    if (!mounted) return;
    _epubLoadWatchdog?.cancel();
    // 예전에 저장된 읽던 위치(CFI)가 지금 파일과 맞지 않으면 열기에 실패할 수 있으므로
    // 메모·책갈피는 그대로 두고 처음부터 한 번 다시 연다.
    if (!_isOfflineDocument && !_epubRetriedWithoutCfi && (_initialCfi?.isNotEmpty ?? false)) {
      setState(() {
        _epubRetriedWithoutCfi = true;
        _initialCfi = null;
        _hasRestoredInitialPosition = true;
        _epubViewerGeneration++;
      });
      return;
    }
    if (_epubLoadFailureShown) return;
    _epubLoadFailureShown = true;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text('${_tr('문서를 표시하지 못했어요', 'Could not display the document', '无法显示文档', '文書を表示できませんでした')}: $message'),
        duration: const Duration(seconds: 8),
      ),
    );
  }

  bool _showControls = false;
  bool _isTouchLocked = false;
  bool _useShakeLock = false;
  bool _useVolumeComboLock = true;
  bool _useSwipeTurn = true;
  bool _useVolumeTurn = true;
  bool _useQuickNavTurn = false;
  bool _useSpenTurn = false;
  Offset? _lastEraserPos;
  final TransformationController _epubZoomController = TransformationController();

  // ── 한글·워드 확대를 선명하게 ──
  // 화면 그림을 키우기만 하면 글씨가 뭉개져서, 확대가 멈추면 문서 화면이 그 배율로 쪽을 다시 그리게 하고(JS)
  // 문서 화면에는 그만큼 되돌리는 변환을 걸어 보이는 자리는 그대로 둠. 바꾸는 순간은 가만히 읽던 때의 화면 그림으로 가림
  // 한글·워드·PPT 확대: 화면 그림을 늘리지 않고 문서가 직접 그 배율로 그림 (움직이는 동안에도 늘 선명)
  // 문서가 지금 그려 보여 주는 확대 (메모·책갈피가 글과 같은 순간에 따라가게)
  final ValueNotifier<Matrix4> _docShownView = ValueNotifier<Matrix4>(Matrix4.identity());
  bool _viewSending = false;
  Matrix4? _viewPending;
  double _epubZoomScale = 1.0;

  // 1 & 3. S펜 전용 페이지별 필기 및 지우개 상태 (필기 모드에서 S펜이 닿으면 화면 이동 100% 차단 + 해당 페이지에서만 필기 표시)
  bool _isMemoMode = false;
  bool _isEraserMode = false;
  bool _allowFingerDrawing = false;
  bool _isStylusDown = false;
  String _currentPageLocationKey = 'page_0';
  // 메모 자리 이름(쪽 위치). 실제 저장 이름은 보기 방식(한 쪽/두 쪽)·화면 방향을 붙인 [_currentPageLocationKey]
  String _memoBase = 'page_0';
  int _memoLoadSeq = 0;
  bool _memoSyncQueued = false;
  // 문서(워드·한글·PPT) 지금 화면에 놓인 쪽 네모들 (보는 곳 대비 0~1). 메모·책갈피를 쪽에 붙임
  List<DocPageSlot>? _pageSlots; // 문서가 잰 쪽 자리들 (보이는 자리·쪽 전체·여백 줄이기 네모)
  Size? _fracsStage; // [_pageSlots]를 잴 때의 책 화면 크기
  List<Size>? _docPageSizes; // 모든 쪽 크기 (메모를 쪽마다 나눠 저장할 때 씀)
  int _framesSeq = 0;
  Size? _framesForSize;
  Timer? _framesTimer;
  final GlobalKey _memoLayerKey = GlobalKey();
  // 지금 쪽 메모를 불러오는 중 (넘기는 종이 그림에 메모를 넣기 전에 기다림)
  Future<List<MemoStroke>>? _memoLoading;
  List<MemoStroke> _memoStrokes = [];
  final List<Offset> _activeStrokePoints = [];
  Color _penColor = kMemoPenColors.first; // 기본: 빨강
  double _penWidth = 2.0;

  // 메모: 되돌리기/다시 실행 기록(페이지 위치별), 지우개 종류, 지우개 드래그 시작 시점의 필기
  final MemoHistory _memoHistory = MemoHistory();
  String _eraserType = 'area';
  List<MemoStroke>? _eraseStartStrokes;

  String _footerInfoMode = 'none';
  String _progressBarPosSetting = 'bottom';
  /// 실제 진행바 위치: 1쪽짜리 문서는 설정과 상관없이 숨김 (다른 버튼 배치도 숨김 기준으로)
  // 쪽 수를 알기 전(문서는 다 읽기 전, EPUB은 첫 위치 알림 전)에도 숨겨 두어 1쪽짜리에서 잠깐 보였다 사라지지 않게
  String get _progressBarPos => ((_isOfflineDocument && _docPageCount <= 1) || (!_isOfflineDocument && (!_epubLocated || _epubSinglePage)))
      ? 'hidden'
      : _progressBarPosSetting;
  bool _epubLocated = false; // EPUB 첫 위치 알림을 받았는지
  bool _epubAtStart = false; // EPUB 책의 첫 화면인지
  bool _epubAtEnd = false; // EPUB 책의 마지막 화면인지
  int _pptStepsLeft = 0; // PPT 지금 슬라이드에 남은 애니메이션 단계 수
  bool _epubSinglePage = false; // EPUB 전체가 한 화면(장 1개, 화면 1쪽)
  String _memoToolbarPos = 'bottom'; // 메모 도구모음 위치
  String _quickMenuSide = 'right'; // 왼손잡이('left'): 스크롤 막대를 왼쪽에
  int _rotateTapCount = 0; // 화면 회전 아이콘 흔들림 애니메이션용
  List<BookmarkItem> _bookmarks = [];

  /// 북마크는 한글·워드·PPT 문서에서만 (EPUB·TXT는 쓰지 않음)
  bool get _bookmarksOn => _isOfflineDocument && !_isTxt;

  /// 지금 쪽이 북마크돼 있는지 (한 쪽·두 쪽·스크롤 보기마다 따로: 그 보기에서 한 북마크만)
  bool get _isCurrentPageBookmarked {
    if (_bookmarks.isEmpty || !mounted) return false;
    final String? pos = _currentCfi;
    if (pos == null || pos.isEmpty) return false;
    return _isBookmarkedAt(pos);
  }

  bool _isBookmarkedAt(String pos) {
    final bool spread = !_pageModeScroll && _bookmarkSpreadNow;
    return _bookmarks.any((bm) => bm.position == pos && bm.spread == spread && bm.scroll == _pageModeScroll);
  }

  /// 북마크할 자리: 스크롤 보기는 화면에 절반 이상(가장 많이) 보이는 쪽, 그 밖은 지금 쪽
  Future<String?> _bookmarkTarget() async {
    if (_pageModeScroll && _docVertical) {
      final int? p = await _hwpController.mostVisiblePage();
      if (p != null && p >= 0) return '$_documentPositionPrefix:$p';
    }
    return _currentCfi;
  }

  /// 스크롤 보기 북마크의 쪽 번호들 (쪽에 책갈피를 붙임)
  Set<int> get _scrollMarkPages => {
        for (final bm in _bookmarks)
          if (bm.scroll)
            if (RegExp(r'^[a-z]+:(\d+)$').firstMatch(bm.position) case final m?) int.parse(m.group(1)!),
      };
  String _marksSent = '';

  /// 한글·워드 스크롤 보기: 북마크한 쪽 책갈피를 문서 화면에 알림 (바뀐 때만)
  void _syncScrollMarks() {
    if (!_docVertical) return;
    final pages = _scrollMarkPages.toList()..sort();
    final String sig = '$_docPageCount|${pages.join(',')}';
    if (sig == _marksSent) return;
    _marksSent = sig;
    _hwpController.setScrollMarks(pages);
  }

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
    if (val == _pageModeScroll || (val && (_isPresentation || _isSpreadsheet))) return;
    setState(() => _mutateScrollMode(val));
    await StorageService.setPageModeTap(_pageModeTap);
    await StorageService.setPageModeScroll(_pageModeScroll);
    await StorageService.setUseSwipeTurn(_useSwipeTurn);
    _onPageModeChanged();
  }

  String _buildLockScreenMessage() {
    if (_useShakeLock && _useVolumeComboLock) {
      return _tr(
        '화면 잠금 (흔들어서 끄기 또는 음량 버튼 동시에 눌러서 끄기)',
        'Screen Lock (Shake or press both volume keys to unlock)',
        '屏幕锁定 (摇晃或同时按音量键关闭)',
        '画面ロック (振るか音量ボタン同時押しで解除)',
      );
    } else if (_useShakeLock) {
      return _tr(
        '화면 잠금 (흔들어서 끄기)',
        'Screen Lock (Shake to unlock)',
        '屏幕锁定 (摇晃关闭)',
        '画面ロック (振って解除)',
      );
    } else if (_useVolumeComboLock) {
      return _tr(
        '화면 잠금 (음량 버튼 동시에 눌러서 끄기)',
        'Screen Lock (Press both volume keys to unlock)',
        '屏幕锁定 (同时按音量键关闭)',
        '画面ロック (音量ボタン同時押しで解除)',
      );
    } else {
      return _tr('화면 잠금', 'Screen Lock', '屏幕锁定', '画面ロック');
    }
  }

  double _progress = 0.0;
  bool _hasRestoredInitialPosition = false;

  Offset? _pointerDownPosition;
  DateTime? _pointerDownTime;

  String _tr(String ko, String en, String zh, String ja) =>
      AppI18n.t(StorageService.appLangNotifier.value, ko: ko, en: en, zh: zh, ja: ja);

  @override
  void initState() {
    super.initState();
    ComfortTint.viewerOpened(); // 파일을 보는 동안 편안한 모드 덮개를 걷음
    _epubZoomController.addListener(_onZoomMatrixChanged);
    SystemBars.enterViewer(); // 파일 열람 중에는 상태표시줄·내비게이션 바를 모두 숨김
    _activeFilePath = widget.filePath;
    _loadNeighborFiles();
    WidgetsBinding.instance.addObserver(this);
    _startOutlineCacheRead(); // 저장해 둔 목차를 문서가 열리는 동안 미리 읽어 둠
    _initReader();
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

  void _toggleTouchScreenLock({required bool byVolume}) {
    if (!mounted) return;
    if (!_isTouchLocked) return;
    final bool neitherEnabled = !_useShakeLock && !_useVolumeComboLock;
    if (byVolume && !_useVolumeComboLock && !neitherEnabled) return;
    if (!byVolume && !_useShakeLock && !neitherEnabled) return;

    setState(() {
      _isTouchLocked = false;
    });
    ScaffoldMessenger.of(context).clearSnackBars();
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(_tr('화면 잠금 해제', 'Screen Unlocked', '屏幕锁定已解除', '画面ロック解除')),
        duration: const Duration(seconds: 1),
      ),
    );
  }

  /// 뷰어 설정의 '페이지 모드'(탭·스크롤·슬라이드)와 '페이지 전환 버튼'
  /// 스크롤은 탭·슬라이드와 함께 켤 수 없음 (스크롤을 켜면 둘 다 꺼짐). 탭과 슬라이드는 함께 사용 가능
  List<Widget> _pageModeSettings(StateSetter setModalState) {
    Future<void> apply(VoidCallback change) async {
      setState(change);
      setModalState(() {});
      // 스크롤로 설정된 채 PPT를 보는 중: 여기서 바꾼 것은 이 파일에서만 (다른 파일은 다시 스크롤)
      if (_isPresentation && _storedPageModeScroll) {
        _onPageModeChanged();
        return;
      }
      await StorageService.setPageModeTap(_pageModeTap);
      await StorageService.setPageModeScroll(_pageModeScroll);
      await StorageService.setUseSwipeTurn(_useSwipeTurn);
      _onPageModeChanged();
    }

    return [
      _settingsHeader(Icons.swipe_outlined, _tr('페이지 모드', 'Page Mode', '翻页模式', 'ページモード')),
      const SizedBox(height: 4),
      Text(
        _tr('스크롤은 탭·슬라이드와 함께 쓸 수 없어요\n탭과 슬라이드는 함께 쓸 수 있어요', 'Scroll cannot be combined with Tap or Slide\nTap and Slide can be used together', '滚动不能与点击、滑动同时使用；点击和滑动可以同时使用', 'スクロールはタップ・スライドと併用できません\nタップとスライドは併用できます'),
        style: TextStyle(fontSize: 12, color: Theme.of(context).colorScheme.onSurfaceVariant),
      ),
      const SizedBox(height: 6),
      SettingGroup(
        children: [
          SettingToggle(
            label: Text(_tr('탭', 'Tap', '点击', 'タップ')),
            selected: _pageModeTap,
            onSelected: (val) => apply(() {
              _pageModeTap = val;
              if (val) _pageModeScroll = false;
            }),
          ),
          SettingToggle(
            label: Text(_tr('슬라이드', 'Slide', '滑动', 'スライド')),
            selected: _useSwipeTurn,
            onSelected: (val) => apply(() {
              _useSwipeTurn = val;
              if (val) _pageModeScroll = false;
            }),
          ),
          // 슬라이드를 고르면 바로 밑에: 책처럼 넘기기 (PPT·엑셀은 쓰지 않으므로 숨김)
          if (_useSwipeTurn && !_isPresentation && !_isSpreadsheet)
            SettingToggle(
              label: Text(_tr('책처럼 넘기기', 'Book page turn', '书本翻页', '本のようにめくる')),
              selected: StorageService.pageCurl,
              onSelected: (val) => apply(() {
                StorageService.setPageCurl(val);
                _syncCurlSwipe();
              }),
            ),
          // PPT는 스크롤 보기 없음 (슬라이드 단위로 넘김)
          if (!_isPresentation)
          SettingToggle(
            label: Text(_tr('스크롤', 'Scroll', '滚动', 'スクロール')),
            selected: _pageModeScroll,
            onSelected: (val) => apply(() => _mutateScrollMode(val)),
          ),
          // 스크롤을 고르면 바로 밑에: 오른쪽(왼손잡이는 왼쪽) 회색 스크롤 막대 끄기
          if (_pageModeScroll)
            SettingToggle(
              label: Text(_tr('스크롤바 끄기', 'Hide scroll bar', '隐藏滚动条', 'スクロールバーを隠す')),
              selected: ScrollThumbBar.off.value,
              onSelected: (val) => apply(() {
                ScrollThumbBar.off.value = val;
                StorageService.setScrollBarOff(val);
              }),
            ),
        ],
      ),
      const SizedBox(height: 26),
      // EPUB 스크롤 보기에서는 버튼이 챕터를 넘김
      _settingsHeader(Icons.smart_button_outlined, _isEpub && _pageModeScroll
          ? _tr('챕터 넘김 버튼 (동시 사용 가능)', 'Chapter Turn Buttons (Multiple allowed)', '翻章按钮 (可同时启用)', '章めくりボタン (同時使用可)')
          : _tr('페이지 전환 버튼 (동시 사용 가능)', 'Page Switch Buttons (Multiple allowed)', '翻页按钮 (可同时启用)', 'ページ切替ボタン (同時使用可)')),
      const SizedBox(height: 6),
      SettingGroup(
        children: [
          SettingToggle(
            label: Text(_tr('음량 버튼', 'Volume Keys', '音量键', '音量ボタン')),
            selected: _useVolumeTurn,
            onSelected: (val) async {
              await StorageService.setUseVolumeTurn(val);
              setState(() => _useVolumeTurn = val);
              setModalState(() {});
            },
          ),
          SettingToggle(
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
    ];
  }

  void _setPageDisplay(String mode) {
    if (!mounted || mode == _pageDisplay) return;
    setState(() {
      _initialCfi = _currentCfi;
      _pageDisplay = mode;
    });
  }

  /// 뷰어 설정 초기화: 음량 버튼 동시에 눌러 끄기 / 탭 + 슬라이드 / 음량 버튼 / 진행도 하단 / 메모 도구 모음 하단 / 정보 표시 없음
  Future<void> _resetViewerSettings(StateSetter setModalState) async {
    final bool scrollWas = _pageModeScroll;
    setState(() {
      _useVolumeComboLock = true;
      _useShakeLock = false;
      _pageModeTap = !_isSpreadsheet;
      _useSwipeTurn = true;
      _pageModeScroll = false;
      _useVolumeTurn = true;
      _useSpenTurn = false;
      _progressBarPosSetting = 'bottom';
      _memoToolbarPos = 'bottom';
      _footerInfoMode = 'none';
      _quickMenuSide = 'right'; // 왼손잡이 끔
    });
    ScrollThumbBar.leftHanded.value = false;
    ScrollThumbBar.off.value = false;
    setModalState(() {});
    await StorageService.setUseVolumeComboLock(true);
    await StorageService.setUseShakeLock(false);
    await StorageService.setPageModeTap(true);
    await StorageService.setUseSwipeTurn(true);
    await StorageService.setPageModeScroll(false);
    await StorageService.setUseVolumeTurn(true);
    await StorageService.setUseSpenTurn(false);
    await StorageService.setProgressBarPosition('bottom');
    await StorageService.setMemoToolbarPosition('bottom');
    await StorageService.setFooterInfoMode('none');
    await StorageService.setQuickMenuSide('right');
    await StorageService.setScrollBarOff(false);
    await StorageService.setPageCurl(true);
    _syncCurlSwipe();
    _storedPageModeScroll = false;
    if (scrollWas) {
      _onPageModeChanged();
    } else if (!_isOfflineDocument) {
      try {
        _epubController.setSwipeEnabled(_useSwipeTurn && !_curlOn);
      } catch (_) {}
    }
  }

  /// 페이지 모드가 바뀌었을 때: 보던 자리에서 다시 보여 줌 (EPUB은 넘김/스크롤 방식이 바뀌어 다시 염)
  void _onPageModeChanged() {
    if (!mounted) return;
    setState(() {
      _initialCfi = _currentCfi;
      // 스크롤 보기에서는 메모를 쓰지 않음
      if (_pageModeScroll) {
        _isMemoMode = false;
        _isEraserMode = false;
        _allowFingerDrawing = false;
        _isStylusDown = false;
      }
    });
    // 스크롤을 끄면 스크롤에서 보던 쪽을 그대로 이어서
    if (!_pageModeScroll && _isOfflineDocument && !_isTxt && !_isSpreadsheet && _docPageCount > 0) {
      unawaited(_hwpController.display('$_documentPositionPrefix:$_docPage'));
    }
    if (!_isOfflineDocument) {
      try {
        _epubController.setSwipeEnabled(_useSwipeTurn && !_pageModeScroll && !_curlOn);
      } catch (_) {}
    }
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


  /// 8. 같은 그룹 내의 이전(step: -1) 또는 다음(step: 1) 파일로 즉시 이동
  // 이전·다음 파일: 서재 목록을 한 줄로 세워(정렬 설정 그대로) 앞뒤 파일이 있을 때만 이동. 없으면 단추가 잠김
  String? _prevFilePath, _nextFilePath;

  Future<void> _loadNeighborFiles() async {
    final currentPath = widget.filePath.replaceAll(RegExp(r'(_v25_converted|\.v2\.converted|\.converted)\.epub$'), '');
    final prev = await LibraryNav.neighbor(currentPath, -1);
    final next = await LibraryNav.neighbor(currentPath, 1);
    if (!mounted) return;
    setState(() {
      _prevFilePath = prev;
      _nextFilePath = next;
    });
  }

  Future<void> _openAdjacentFileInSameGroup(int step) async {
    final String? target = step < 0 ? _prevFilePath : _nextFilePath;
    if (target == null || !File(target).existsSync()) return;
    final nextFile = File(target);
    if (!mounted) return;

    final nextName = nextFile.path.split(Platform.pathSeparator).last;
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
          builder: (_) => ReaderScreen(filePath: nextFile.path, bookTitle: nextName),
        ),
      );

    } else if (nextExt == 'pdf') {
      Navigator.pushReplacement(
        context,
        MaterialPageRoute(
          builder: (_) => UniversalMediaReaderScreen(
            files: [nextFile],
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
            files: [nextFile],
            title: nextName,
            isPdf: false,
          ),
        ),
      );
    }
  }

  Future<void> _initReader() async {
    if (!_isOfflineDocument) {
      // 깨진 EPUB은 화면을 띄우기 전에 알기 쉬운 오류로 알려 준다
      try {
        await EpubValidation.validate(File(_activeFilePath));
      } catch (e) {
        if (mounted) {
          setState(() => _isLoading = false);
          _handleEpubLoadError(e.toString());
        }
        return;
      }
    }
    final savedCfi = await StorageService.getLastPosition(widget.filePath);
    // 페이지 기억하기를 끄면 처음부터
    final savedProg = StorageService.rememberPage ? await StorageService.getProgress(widget.filePath) : 0.0;
    final pageDisplay = await StorageService.getPageDisplay();
    UserFontEntry? epubFont;
    try {
      epubFont = await UserFonts.epubFont();
    } catch (_) {}
    final pageModeTap = await StorageService.getPageModeTap();
    final pageModeScroll = await StorageService.getPageModeScroll();
    // 읽기 방향: 직접 정한 적이 없으면 모든 파일 좌→우로 시작
    final bool isRtl = await StorageService.getBookReadingDirectionRtlOrNull(widget.filePath) ?? false;
    final savedBg = await StorageService.getEpubBgTheme();
    final bool savedDocComfort = await StorageService.getDocComfort();
    final footerMode = await StorageService.getFooterInfoMode();
    final barPos = await StorageService.getProgressBarPosition();
    final memoBarPos = await StorageService.getMemoToolbarPosition();
    final quickSide = await StorageService.getQuickMenuSide();
    final shakeLock = await StorageService.getUseShakeLock();
    final volComboLock = await StorageService.getUseVolumeComboLock();
    final volTurn = await StorageService.getUseVolumeTurn();
    final quickTurn = await StorageService.getUseQuickNavTurn();
    final swipeTurn = await StorageService.getUseSwipeTurn();
    final eraserType = await StorageService.getMemoEraserType();
    final spenTurn = await StorageService.getUseSpenTurn();

    // 문서(TXT·워드·한글)는 저장된 위치(예: txt:12) 자체가 그 쪽의 메모 열쇠, EPUB은 CFI(없으면 진행률)
    final String initLocKey = (_isOfflineDocument && savedCfi != null && savedCfi.isNotEmpty)
        ? savedCfi
        : _computeLocationKey(savedCfi, savedProg);
    final List<MemoStroke> strokes = await _getMemo(initLocKey);
    // 북마크: 열자마자 책갈피를 보여 주려고 미리 읽어 둠
    final List<BookmarkItem> initBookmarks = _bookmarksOn ? await StorageService.getBookmarks(widget.filePath) : const [];

    _bindHardwareButtons();
    ScrollThumbBar.off.value = await StorageService.getScrollBarOff();

    if (!mounted) return;
    setState(() {
      _initialCfi = savedCfi;
      _currentCfi = savedCfi;
      _progress = savedProg.clamp(0.0, 1.0).toDouble();
      _initialProgress = _progress;
      _currentPageLocationKey = initLocKey;
      _memoBase = initLocKey;
      _bookmarks = initBookmarks;
      _pageDisplay = pageDisplay;
      _epubFont = epubFont;
      _pageModeScroll = pageModeScroll && !_isSpreadsheet && !_isPresentation; // 엑셀은 뷰어 설정 없이 끌어서 이동, PPT는 스크롤 없음
      _storedPageModeScroll = pageModeScroll;
      // 스크롤은 탭과 함께 쓰지 않음
      _pageModeTap = pageModeTap && !_pageModeScroll;
      _isMangaRtlMode = isRtl && !_isTxt; // TXT는 읽기 방향 전환 없음
      // 기본값은 라이트. 종이색은 EPUB에서만 쓰므로 다른 문서에서는 라이트로 보여 준다.
      _epubBgTheme = savedBg.isEmpty || (savedBg == 'sepia' && !_isEpub) || _isPresentation || _isSpreadsheet ? 'white' : savedBg; // PPT는 배경 색상을 적용하지 않음
      _docComfort = savedDocComfort && _docComfortAllowed;
      if (_docComfort) _epubBgTheme = 'white';
      ComfortTint.fileOn = _docComfort;
      _footerInfoMode = footerMode;
      _progressBarPosSetting = barPos;
      _memoToolbarPos = memoBarPos;
      _quickMenuSide = quickSide;
      ScrollThumbBar.leftHanded.value = quickSide == 'left';
      _useShakeLock = shakeLock;
      _useVolumeComboLock = volComboLock;
      _useVolumeTurn = volTurn;
      _useQuickNavTurn = quickTurn;
      // PPT는 스크롤이 없으므로, 스크롤로 설정돼 있으면 이 파일만 슬라이드로 (다른 파일은 그대로 스크롤)
      _useSwipeTurn = (swipeTurn || (_isPresentation && pageModeScroll)) && !_pageModeScroll;
      _eraserType = eraserType;
      _useSpenTurn = spenTurn;
      _memoStrokes = strokes;
      _isLoading = false;
    });
    unawaited(_snapInit());
    // 파일을 열 때마다 탭 존 가이드라인 (앱 설정에서 끌 수 있음)
    if (!StorageService.tapGuideOff) {
      _showTapGuide();
    }
  }

  OverlayEntry? _tapGuide;

  // ── 페이지 이동: EPUB이면 EPUB 뷰어, TXT·워드·한글이면 각 문서 뷰어로 보낸다 ──
  /// 스크롤 모드의 TXT: 쪽 목록을 한 화면씩 움직임 (한글·워드는 문서 화면 안에서 굴림)
  bool get _docScrollActive => _pageModeScroll && _isTxt;

  void _readerNext() {
    _navDir = 1;
    if (_docScrollActive) {
      _scrollCtrl.scrollByScreen(1);
      return;
    }
    if (_isTxt) {
      _txtController.next();
    } else if (_isOfflineDocument) {
      _snapShow(_docPage + _snapStep);
      _hwpController.next();
    } else if (_pageModeScroll) {
      // EPUB 스크롤 보기: 넘김 버튼(음량·S펜)은 다음 챕터로
      _goEpubChapter(1);
    } else {
      _epubController.next();
    }
  }

  void _goEpubChapter(int dir) {
    if (dir > 0 ? _chLast : _chFirst) return;
    setState(() {
      _chAtStart = false;
      _chAtEnd = false;
    });
    _epubController.goChapter(dir);
  }

  void _readerPrevious() {
    _navDir = -1;
    if (_docScrollActive) {
      _scrollCtrl.scrollByScreen(-1);
      return;
    }
    if (_isTxt) {
      _txtController.previous();
    } else if (_isOfflineDocument) {
      _snapShow(_docPage - _snapStep);
      _hwpController.previous();
    } else if (_pageModeScroll) {
      _goEpubChapter(-1);
    } else {
      _epubController.prev();
    }
  }

  void _readerProgress(double value) {
    if (_isTxt) {
      _txtController.toProgress(value);
    } else if (_isOfflineDocument) {
      _hwpController.toProgress(value);
    } else {
      _epubController.toProgressPercentage(value);
    }
  }

  void _readerDisplay(String position) {
    if (_docScrollActive) {
      final m = RegExp(r':(\d+)$').firstMatch(position);
      if (m != null) {
        _scrollCtrl.jumpToPage(int.parse(m.group(1)!));
        return;
      }
    }
    if (_isTxt) {
      _txtController.display(position);
    } else if (_isOfflineDocument) {
      final m = RegExp(r':(\d+)$').firstMatch(position);
      if (m != null) _snapShow(int.parse(m.group(1)!));
      _hwpController.display(position);
    } else {
      _epubController.display(cfi: position);
    }
  }

  // ── 목차 (워드·한글·PPT) ──
  // 1) 파일 안에 '목차'(Contents) 쪽이 있으면 그 항목만
  // 2) 없으면 번호(Ⅰ. / 1. / 1) / (1))로 시작하는 굵은 글씨 줄만 (같은 제목은 한 번)
  // 3) 그래도 없으면 목차 칸에 '표시할 목차가 없어요.' (쪽 번호 목록은 보여 주지 않음)
  // 글자가 그림으로만 된 PPT는 그림 속 글자를 읽어(OCR, 기기 안에서) 같은 규칙을 쓴다.
  // 만든 목차는 파일마다 저장해 두어 다음에 열 때는 다시 분석하지 않고 바로 보여 준다.
  Future<Map<int, List<Map<String, Object?>>>>? _outlineCacheFuture;
  Map<int, List<Map<String, Object?>>>? _cachedOutlines;

  void _startOutlineCacheRead() {
    if (_isTxt || _isSpreadsheet || !_isOfflineDocument || _outlineCacheFuture != null) return;
    _outlineCacheFuture = OutlineCache.read(widget.filePath).then((all) => _cachedOutlines = all);
  }

  /// 목차를 만드는 중이면 진행률(0~1), 아니면 null — 목차 칸에 '목차 만드는 중… n%'로 보임
  double? _outlineProgress;

  void _setOutlineProgress(double? p) {
    if (!mounted) return;
    if (p != null && _outlineProgress != null && (p - _outlineProgress!).abs() < 0.01 && p < 1) return;
    setState(() => _outlineProgress = p);
  }

  Future<void> _loadDocumentOutline(int pageCount) async {
    if (!mounted || _isTxt || _isSpreadsheet) return;
    final cached = (await (_outlineCacheFuture ?? Future.value(const <int, List<Map<String, Object?>>>{})))[pageCount];
    if (!mounted || _docPageCount != pageCount) return;
    if (cached != null) {
      _applyDocumentOutline(cached, pageCount);
      return;
    }
    _setOutlineProgress(0);
    try {
      final items = await _buildDocumentOutline(pageCount);
      if (items == null || !mounted || _docPageCount != pageCount) return; // 중간에 닫힘: 다음에 이어서
      final cleaned = [for (final e in items) {...e, 'title': (e['title'] ?? '').toString().replaceAll(RegExp(r'\s+'), ' ').trim()}];
      await OutlineCache.write(widget.filePath, pageCount, cleaned);
      (_cachedOutlines ??= {})[pageCount] = cleaned;
      _setOutlineProgress(null);
      _applyDocumentOutline(cleaned, pageCount);
    } finally {
      if (mounted && _outlineProgress != null) _setOutlineProgress(null);
    }
  }

  /// 목차 만들기. 1) 파일 안 목차 쪽 → 2) 한글·워드: 번호 줄 → 굵은 글씨 줄 / PPT: 슬라이드 제목·부제목
  Future<List<Map<String, Object?>>?> _buildDocumentOutline(int pageCount) async {
    bool alive() => mounted && _docPageCount == pageCount;
    // 첫 화면을 그리는 데 방해되지 않도록 잠시 뒤에 분석
    await Future<void>.delayed(const Duration(milliseconds: 500));
    if (!alive()) return null;
    final int scan = math.min(pageCount, 400); // 아주 긴 문서는 앞 400쪽까지만
    final head = await _hwpController.pageText(0, math.min(pageCount, TocPageParser.searchPages));
    if (!alive()) return null;
    _setOutlineProgress(0.05);
    // 글을 [from, to) 조각으로 나눠 읽으며 진행률 표시
    Future<List<T>> chunked<T>(Future<List<T>> Function(int from, int to) read, int total, double p0, double p1, {int step = 20}) async {
      final out = <T>[];
      for (int from = 0; from < total; from += step) {
        out.addAll(await read(from, math.min(total, from + step)));
        if (!alive()) return out;
        _setOutlineProgress(p0 + (p1 - p0) * math.min(1, (from + step) / total));
      }
      return out;
    }

    // 1) 목차 쪽
    if (TocPageParser.parse(head, pageCount) != null) {
      final all = await chunked<String>((f, t) => _hwpController.pageText(f, t), scan, 0.05, 0.95);
      if (!alive()) return null;
      return TocPageParser.parse(all.length < head.length ? head : all, pageCount) ?? const [];
    }
    if (_isPresentation) {
      final letters = head.fold<int>(0, (n, t) => n + RegExp(r'[가-힣A-Za-z]').allMatches(t).length);
      // 글자가 거의 없는 PPT(슬라이드가 그림으로만 된 경우): 그림 속 글자를 읽음
      if (head.isNotEmpty && letters < head.length * 15) return _ocrOutline(pageCount);
      final lines = await chunked<List<Map<String, Object?>>>((f, t) => _hwpController.slideLineData(f, t), pageCount, 0.05, 0.95, step: 10);
      if (!alive()) return null;
      return HeadingRules.slides(lines);
    }
    // 번호·굵은 글씨 줄은 문서 끝까지 찾음 (약전처럼 아주 긴 문서도 뒤쪽 항목까지)
    final int all = math.min(pageCount, 5000);
    final cands = _isHwpFile
        ? await chunked<Map<String, Object?>>((f, t) => _hwpController.headingCandidates(f, t), all, 0.05, 0.95)
        : await _hwpController.headingCandidates(0, all);
    if (!alive()) return null;
    return HeadingRules.build(cands);
  }

  /// 슬라이드 그림 속 글자를 읽어 목차를 만든다. 슬라이드마다 읽은 결과는 바로바로 저장 (중간에 닫으면 null)
  Future<List<Map<String, Object?>>?> _ocrOutline(int pageCount) async {
    final path = widget.filePath;
    final slides = await OutlineCache.readOcr(path);
    final tmp = Directory('${(await getTemporaryDirectory()).path}/ppt_ocr');
    await tmp.create(recursive: true);
    int fresh = 0;
    // 슬라이드 하나를 [width] 너비로 그려 글자를 읽음
    Future<List<Map<String, Object?>>> readSlide(int page, int width) async {
      final lines = <Map<String, Object?>>[];
      final b64 = await _hwpController.slideImage(page, width: width);
      if (b64 == null) return lines;
      final img = File('${tmp.path}/slide_$page.jpg');
      try {
        await img.writeAsBytes(base64Decode(b64), flush: true);
        final raw = await _pdfChannel.invokeMethod<List<Object?>>('ocrLines', {'path': img.path}) ?? const [];
        for (final e in raw) {
          if (e is! Map) continue;
          final t = (e['t'] ?? '').toString().trim();
          if (t.isEmpty) continue;
          lines.add({'t': t, 'y': e['y'], 'h': e['h']});
        }
      } catch (_) {
      } finally {
        try {
          await img.delete();
        } catch (_) {}
      }
      return lines;
    }

    for (int page = 0; page < pageCount; page++) {
      if (slides.containsKey(page)) continue;
      if (!mounted || _docPageCount != pageCount) {
        if (fresh > 0) await OutlineCache.writeOcr(path, slides);
        return null;
      }
      slides[page] = await readSlide(page, 1800);
      _setOutlineProgress(0.05 + 0.9 * (page + 1) / pageCount);
      if (++fresh % 5 == 0) await OutlineCache.writeOcr(path, slides);
      // 읽는 화면이 버벅이지 않게 슬라이드 사이에 잠깐 쉼
      await Future<void>.delayed(const Duration(milliseconds: 120));
    }
    if (!mounted || _docPageCount != pageCount) return null;
    List<String> textsOf() => [for (int p = 0; p < pageCount; p++) [for (final l in slides[p] ?? const <Map<String, Object?>>[]) l['t']].join('\n')];
    // 목차 슬라이드가 있으면 그것만, 없으면 슬라이드마다 제목(가장 큰 글자)과 그 바로 아래 부제목
    var toc = TocPageParser.parse(textsOf(), pageCount);
    if (toc != null) {
      // 목차 슬라이드는 글자가 작아 잘못 읽기 쉬움: 크기를 바꿔 여러 번 읽고, 같은 항목끼리 비교해 고름
      final tocPage = TocPageParser.tocPageOf(textsOf(), toc);
      final variants = <List<Map<String, Object>>>[];
      if (tocPage != null && mounted) {
        final original = slides[tocPage] ?? const <Map<String, Object?>>[];
        for (final w in const [2400, 3200, 1400]) {
          if (!mounted) break;
          final again = await readSlide(tocPage, w);
          if (again.isEmpty) continue;
          slides[tocPage] = again;
          final v = TocPageParser.parse(textsOf(), pageCount);
          if (v != null) variants.add(v);
        }
        slides[tocPage] = original;
      }
      final base = toc;
      toc = [
        for (final e in base)
          {
            ...e,
            'title': TocPageParser.chooseTitle(
              '${e['title']}',
              [
                for (final v in variants)
                  for (final x in v)
                    if (x['page'] == e['page'] && (x['level'] == e['level']) && _sameTocEntry('${x['title']}', '${e['title']}')) '${x['title']}',
              ],
              // 연결된 슬라이드(와 바로 다음 슬라이드)의 제목·부제목: 큰 글씨라 더 정확히 읽힘
              [
                for (final p in [e['page'] as int, (e['page'] as int) + 1])
                  if (p < pageCount)
                    for (final l in slides[p] ?? const <Map<String, Object?>>[]) '${l['t']}',
              ],
            ),
          },
      ];
    }
    final List<Map<String, Object?>> items = toc ??
        HeadingRules.slides([for (int p = 0; p < pageCount; p++) slides[p] ?? const <Map<String, Object?>>[]], ocr: true);
    await OutlineCache.clearOcr(path);
    return items;
  }

  /// 다른 크기로 다시 읽은 목차 항목이 같은 항목인가 (번호가 같거나 글이 꽤 비슷)
  static bool _sameTocEntry(String a, String b) {
    final na = RegExp(r'^\(?(\d{1,3}(?:[.\-]\d{1,3})?)').firstMatch(a.trim())?.group(1);
    final nb = RegExp(r'^\(?(\d{1,3}(?:[.\-]\d{1,3})?)').firstMatch(b.trim())?.group(1);
    if (na != null && nb != null) return na == nb;
    final x = a.replaceAll(RegExp(r'\s+'), ''), y = b.replaceAll(RegExp(r'\s+'), '');
    if (x.isEmpty || y.isEmpty) return false;
    int same = 0;
    for (final ch in x.split('')) {
      if (y.contains(ch)) same++;
    }
    return same >= x.length * 0.6;
  }

  void _applyDocumentOutline(List<Map<String, Object?>> items, int pageCount) {
    if (!mounted || items.isEmpty || _docPageCount != pageCount) return;
    final chapters = <EpubChapter>[];
    final levels = <int>[];
    for (final item in items) {
      final int page = (item['page'] as int).clamp(0, math.max(0, pageCount - 1)).toInt();
      final String title = (item['title'] as String).trim();
      if (title.isEmpty) continue;
      chapters.add(EpubChapter(
        title: title,
        href: '$_documentPositionPrefix:$page',
        id: '$_documentPositionPrefix:$page#${chapters.length}',
        subitems: const [],
      ));
      levels.add((item['level'] as int).clamp(1, 6).toInt());
    }
    if (chapters.isEmpty) return;
    setState(() {
      _chapters = chapters;
      _chapterLevels = levels;
    });
  }

  /// 문서를 다 읽어 들였을 때: 저장해 둔 목차가 있으면 바로 그것을, 없으면 분석한다 (목차가 없으면 '표시할 목차가 없어요.')
  void _onDocumentLoaded(int pageCount) {
    if (!mounted) return;
    _marksSent = ''; // 문서를 다시 열면 스크롤 보기 책갈피도 다시 알림
    setState(() {
      _chapterLevels = const [];
      _docPageCount = pageCount;
      _docLoadedPages = pageCount;
      _chapters = const [];
    });
    if (_isTxt || _isSpreadsheet) return;
    // 쪽 크기: 두 쪽 보기 메모를 쪽마다 나눌 때 씀 (받은 뒤 두 쪽 보기면 메모를 다시 읽음)
    _hwpController.pageSizes().then((sizes) {
      if (!mounted || sizes == null) return;
      _docPageSizes = sizes;
      if (_memoPageAnchored && _bookmarkSpreadNow) setState(() => _currentPageLocationKey = '');
    });
    final cached = _cachedOutlines?[pageCount];
    if (cached != null && cached.isNotEmpty) {
      _applyDocumentOutline(cached, pageCount); // 같은 프레임에 바로 바뀜 (쪽 목록이 보였다 바뀌지 않음)
      return;
    }
    if (cached != null) return; // 목차 없음으로 저장된 문서
    _loadDocumentOutline(pageCount);
  }

  double _sheetZoom = 1;

  void _onSheetNames(List<String> names) {
    if (!mounted || !_isSpreadsheet) return;
    setState(() {
      _chapterLevels = const [];
      _chapters = [
        for (int i = 0; i < names.length; i++)
          EpubChapter(title: names[i], href: '$_documentPositionPrefix:$i',
              id: '$_documentPositionPrefix:$i', subitems: const []),
      ];
    });
  }

  /// 문서의 쪽이 바뀌었을 때: 위치 저장 + 그 쪽의 필기 불러오기
  Future<void> _onDocumentLocation(int page, int pageCount, String position, double progress) async {
    if (!mounted) return;
    final waiter = _relocateWaiter;
    if (waiter != null && !waiter.isCompleted) waiter.complete();
    final relocation = ++_docRelocation;
    if (page != _docPage) {
      _lastReadyPage = -1;
      _onPositionChanging();
    } else {
      _dropIdleShot();
    }
    if (_snapShownPage != null && _snapShownPage != page) _snapShow(page);
    if (page != _docPage) _docSel.clear();
    final String memoKey = _memoKeyFor(position);
    setState(() {
      _docPage = page;
      _docPageCount = pageCount;
      if (_isSpreadsheet) {
        final parts = position.split(':');
        _sheetZoom = parts.length == 5 ? double.tryParse(parts.last) ?? 1 : 1;
      }
      _currentCfi = position;
      _memoBase = position;
      _currentPageLocationKey = memoKey;
      _progress = progress.clamp(0.0, 1.0).toDouble();
      _hasRestoredInitialPosition = true;
      _activeStrokePoints.clear();
      _memoStrokes = [];
    });
    await StorageService.saveLastPosition(widget.filePath, position);
    await StorageService.saveProgress(widget.filePath, progress);
    await StorageService.savePageLabel(widget.filePath, _progressPageLabel());
    if (_isSpreadsheet) return; // No page-anchored drawing layer over the live grid.
    final int seq = ++_memoLoadSeq;
    final Future<List<MemoStroke>> load = _getMemo(memoKey);
    _memoLoading = load;
    final strokes = await load;
    if (mounted && relocation == _docRelocation && seq == _memoLoadSeq && memoKey == _currentPageLocationKey) setState(() => _memoStrokes = strokes);
  }

  Widget _buildDocumentViewer(bool isLandscape) {
    if (_isTxt) {
      return RepaintBoundary(
        key: _txtCaptureKey,
        child: TxtPagedViewer(
          key: ValueKey('text:${widget.filePath}'),
          filePath: widget.filePath,
          controller: _txtController,
          initialPosition: _currentCfi ?? _initialCfi,
          initialProgress: _initialProgress,
          theme: _epubBgTheme,
          spread: _spreadFor(isLandscape),
          rtl: _isMangaRtlMode,
          scroll: _pageModeScroll,
          scrollController: _scrollCtrl,
          onLoaded: _onDocumentLoaded,
          onLocation: _onDocumentLocation,
          onError: _handleEpubLoadError,
        ),
      );
    }
    final shown = _snapShown;
    return Stack(
      fit: StackFit.expand,
      children: [
        // 스크롤 보기 그림이 다 덮고 있거나 목차를 여닫는 동안: 문서 화면(WebView)을 잠시 숨겨 움직임이 끊기지 않게
        Offstage(
          offstage: _tocFreeze != null,
          // 확대·이동은 문서가 직접 그 배율로 그리므로, 화면 확대(InteractiveViewer)는 문서 화면에 걸리지 않게 그대로 되돌림
          // (그림을 늘려 보이지 않아 움직이는 동안에도 글씨가 흐려지지 않음)
          child: AnimatedBuilder(
          animation: _epubZoomController,
          builder: (context, child) {
            final Matrix4 m = _epubZoomController.value;
            return Transform(transform: !_docLiveZoom || _sameMatrix(m, Matrix4.identity()) ? Matrix4.identity() : Matrix4.inverted(m), child: child);
          },
          child: HwpViewer(
          key: ValueKey('document:${widget.filePath}'),
          filePath: widget.filePath,
          controller: _hwpController,
          initialPosition: _currentCfi ?? _initialCfi,
          initialProgress: _initialProgress,
          theme: _epubBgTheme,
          spread: _spreadFor(isLandscape),
          rtl: _isMangaRtlMode,
          // 한글·워드 스크롤 보기: 쪽을 세로로 늘어놓음 (내보내는 동안은 쪽 넘김 화면으로)
          vertical: _docVertical,
          onScrollMetrics: (top, height, client) => _docScrollMetrics.value = [top, height, client],
          onLoaded: _onDocumentLoaded,
          onLocation: _onDocumentLocation,
          onPageReady: _onDocumentPageReady,
          onPasswordNeeded: _onDocPasswordNeeded,
          onStepsLeft: (n) => _pptStepsLeft = n,
          onSheetNames: _onSheetNames,
          onError: _handleEpubLoadError,
          onCancelled: () {
            if (mounted) Navigator.of(context).pop();
          },
        ),
        ),
        ),
        if (_tocFreeze != null && !_pageModeScroll)
          Positioned.fill(child: IgnorePointer(child: Image.memory(_tocFreeze!, fit: BoxFit.fill, gaplessPlayback: true))),
        // 한 번 본 쪽: 실제 쪽(특히 사진)이 다 준비될 때까지 저장해 둔 화면을 먼저 보여 줌
        if (shown != null && !_pageModeScroll)
          Positioned.fill(
            child: IgnorePointer(
              child: Image.file(shown, fit: BoxFit.fill, gaplessPlayback: true, filterQuality: FilterQuality.medium),
            ),
          ),
        // 한글·워드 스크롤 보기: 오른쪽 회색 막대 (끌면 바로 그 자리로)
        if (_docVertical && _tocFreeze == null)
          Positioned.fill(
            child: ValueListenableBuilder<List<double>>(
              valueListenable: _docScrollMetrics,
              builder: (context, m, _) {
                final double top = m[0], height = m[1], client = m[2];
                if (height <= client + 1 || client <= 0) return const SizedBox.shrink();
                return ScrollThumbBar(
                  ratio: top / (height - client),
                  viewFraction: client / height,
                  onDragRatio: (r) {
                    _docScrollMetrics.value = [r * (height - client), height, client];
                    _hwpController.scrollToRatio(r);
                  },
                );
              },
            ),
          ),
      ],
    );
  }

  Completer<int>? _pageReadyWaiter;

  // 한글·워드 스크롤 보기는 문서 화면(WebView) 안에서 쪽을 세로로 늘어놓아 바로 보여 줌
  bool get _isWordOrHwp => _isOfflineDocument && !_isTxt && !_isSpreadsheet && !_isPresentation;
  bool get _docVertical => _pageModeScroll && _isWordOrHwp;
  // 문서 화면 안 스크롤 위치 [지금 위치, 전체 길이, 보이는 높이] (오른쪽 회색 막대)
  final ValueNotifier<List<double>> _docScrollMetrics = ValueNotifier(const [0, 0, 0]);

  // ── 쪽 화면 저장·미리 띄우기 (워드·한글) ──
  // 비밀번호가 걸린 문서는 쪽 화면을 저장해 두지도, 먼저 띄우지도 않음 (다음에 열 때 비밀번호 전에 내용이 보이던 문제)
  bool _docProtected = false;
  bool get _snapEligible => _isOfflineDocument && !_isTxt && !_isPresentation && !_isSpreadsheet && !_docProtected;

  void _onDocPasswordNeeded() {
    if (!_docProtected) {
      _snapHide();
      setState(() => _docProtected = true);
      unawaited(StorageService.markProtectedDoc(widget.filePath));
      unawaited(() async {
        try {
          final dir = await PageSnapshotService.documentDir(widget.filePath);
          if (dir != null && dir.existsSync()) dir.deleteSync(recursive: true);
        } catch (_) {}
      }());
    }
  }
  Directory? _snapDir;
  File? _snapShown;
  int? _snapShownPage;
  Timer? _snapHideTimer;
  bool get _snapSpread {
    final size = MediaQuery.sizeOf(context);
    return _spreadFor(size.width > size.height);
  }
  int _snapCaptureSerial = 0;
  int get _snapStep => _snapSpread ? 2 : 1;

  Future<void> _snapInit() async {
    if (await StorageService.isProtectedDoc(widget.filePath)) {
      if (mounted) setState(() => _docProtected = true);
      return;
    }
    if (!_snapEligible) return;
    final dir = await PageSnapshotService.documentDir(widget.filePath);
    if (!mounted || dir == null) return;
    _snapDir = dir;
    // 처음 열 때: 마지막으로 보던 쪽(없으면 첫 쪽)을 먼저 보여 준다
    if (_docPageCount == 0) {
      final m = RegExp(r':(\d+)$').firstMatch(_currentCfi ?? _initialCfi ?? '');
      WidgetsBinding.instance.addPostFrameCallback((_) => _snapShow(m != null ? int.parse(m.group(1)!) : 0));
    }
  }

  File? _snapFile(int page) {
    final dir = _snapDir;
    final box = _epubViewRectKey.currentContext?.size;
    if (dir == null || box == null || box.isEmpty) return null;
    final name = PageSnapshotService.fileName(
      page: page,
      width: box.width.round(),
      height: box.height.round(),
      spread: _snapSpread,
      rtl: _isMangaRtlMode,
      theme: _epubBgTheme,
    );
    return File('${dir.path}/$name');
  }

  void _snapShow(int page) {
    // 스크롤 보기는 저장해 둔 쪽 화면을 쓰지 않음
    if (!_snapEligible || !mounted || _docVertical) return;
    if (page < 0 || (_docPageCount > 0 && page >= _docPageCount) || _epubZoomScale > 1.03) {
      _snapHide();
      return;
    }
    final file = _snapFile(page);
    if (file == null || !file.existsSync()) {
      _snapHide();
      return;
    }
    _snapHideTimer?.cancel();
    _snapHideTimer = Timer(const Duration(seconds: 8), _snapHide); // 혹시 준비 알림이 안 와도 가린 채 두지 않음
    setState(() {
      _snapShown = file;
      _snapShownPage = page;
    });
  }

  void _snapHide() {
    _snapHideTimer?.cancel();
    if (_snapShown == null || !mounted) return;
    setState(() {
      _snapShown = null;
      _snapShownPage = null;
    });
  }

  /// 쪽 안 그림까지 다 그려졌을 때: 미리 띄운 화면을 걷어 내고, 저장된 화면이 없으면 지금 화면을 저장
  int _lastReadyPage = -1; // 사진까지 다 그려진 마지막 쪽 (넘긴 쪽 그림을 찍을 때 기다림)

  void _onDocumentPageReady(int page) {
    _lastReadyPage = page;
    _refreshPageFrames();
    if (!_book.busy) _scheduleIdleShot();
    final readyWaiter = _pageReadyWaiter;
    if (readyWaiter != null && !readyWaiter.isCompleted) {
      _pageReadyWaiter = null;
      readyWaiter.complete(page);
    }
    // 스크롤 보기에서는 화면을 그림으로 저장하지 않음 (굴리는 동안 화면 저장이 끼어들면 버벅임)
    if (!mounted || !_snapEligible || _docVertical) return;
    if (page != _docPage) return;
    if (_snapShownPage == page) {
      // 실제 쪽이 화면에 그려질 시간을 한 프레임 준 뒤 걷어 냄
      WidgetsBinding.instance.addPostFrameCallback((_) => _snapHide());
    }
    // 다음 쪽 저장 화면을 미리 풀어 두면 넘기는 순간 바로 보인다
    final ahead = _snapFile(page + _snapStep);
    if (ahead != null && ahead.existsSync()) unawaited(precacheImage(FileImage(ahead), context).catchError((_) {}));
    final file = _snapFile(page);
    if (file == null || file.existsSync()) return;
    final serial = ++_snapCaptureSerial;
    Future<void>.delayed(const Duration(milliseconds: 400), () async {
      // 책처럼 넘기는 중에는 화면 저장이 끼어들면 버벅이므로 다 넘어간 뒤에 저장
      for (int i = 0; i < 12 && mounted && _book.busy; i++) {
        await Future<void>.delayed(const Duration(milliseconds: 250));
      }
      if (!mounted || serial != _snapCaptureSerial || page != _docPage || _book.busy) return;
      // 넘기는 중·확대 중·필기 중·다른 화면이 덮고 있을 때는 저장하지 않음
      if (_snapShown != null) return;
      if (_epubZoomScale > 1.03 || _isStylusDown || _activeStrokePoints.isNotEmpty || _slideShow || _findOpen) return;
      try {
        final bytes = await _pdfChannel.invokeMethod<Uint8List>(
          'snapshotWebView',
          // 화면이 깨끗하면 보이는 그대로 GPU 복사 (화면이 멈추지 않음)
          {'background': _getBgColor().toARGB32(), 'scale': 1.0, 'gpu': _screenCleanForShot, 'untint': ComfortTint.untint},
        );
        if (bytes == null || bytes.length < 1024 || !mounted || page != _docPage) return;
        final again = _snapFile(page); // 저장하는 사이 화면 크기가 바뀌었을 수 있음
        if (again == null || again.path != file.path) return;
        final tmp = File('${file.path}.tmp');
        await tmp.writeAsBytes(bytes, flush: true);
        await tmp.rename(file.path);
      } catch (_) {}
    });
  }

  // 탭 칸·음량 버튼·S펜: 읽기 방향(우→좌)과 상관없이 늘 읽는 순서로 다음/이전
  void _turnNext() {
    setState(() => _activeStrokePoints.clear());
    _readerNext();
  }

  void _turnPrev() {
    setState(() => _activeStrokePoints.clear());
    _readerPrevious();
  }

  void _jumpToFirstPage() {
    if (_currentCfi != null) {
      setState(() {
        _progress = 0.0;
        _activeStrokePoints.clear();
      });
    }
    _readerProgress(0.0);
  }

  void _jumpToLastPage() {
    if (_currentCfi != null) {
      setState(() {
        _progress = 1.0;
        _activeStrokePoints.clear();
      });
    }
    _readerProgress(1.0);
  }

  void _bindHardwareButtons() {
    _volumeKeyService.startListening(
      onVolumeUp: () {
        if (_useVolumeTurn) _turnPrev();
      },
      onVolumeDown: () {
        if (_useVolumeTurn) _turnNext();
      },
      onVolumeBothUnlock: () => _toggleTouchScreenLock(byVolume: true),
      onShakeToggle: () => _toggleTouchScreenLock(byVolume: false),
      onSpenSinglePress: () {
        if (_useSpenTurn) _turnNext();
      },
      onSpenDoublePress: () {
        if (_useSpenTurn) _turnPrev();
      },
      onSpenDoubleRevert: () {
        if (_useSpenTurn) {
          // 첫 번째 클릭에서 이미 1페이지 앞으로 이동했으므로 2페이지 뒤로 이동하여 '이전 페이지'로 즉시 전환!
          _turnPrev();
          Future.delayed(const Duration(milliseconds: 50), () {
            if (mounted) _turnPrev();
          });
        }
      },
    );
  }

  // 읽기 방향 아이콘: ↔ (지금 방향 쪽 화살촉만 노란색)
  Widget _buildDualDirectionIcon() => DirectionArrowIcon(rightToLeft: _isMangaRtlMode, size: 22);

  double _distToEraserSegment(Offset p, Offset a, Offset b) {
    final ab = b - a;
    final lenSq = ab.dx * ab.dx + ab.dy * ab.dy;
    if (lenSq < 0.0001) return (p - a).distance;
    final t = (((p.dx - a.dx) * ab.dx + (p.dy - a.dy) * ab.dy) / lenSq).clamp(0.0, 1.0);
    final proj = Offset(a.dx + ab.dx * t, a.dy + ab.dy * t);
    return (p - proj).distance;
  }

  // ── 메모 되돌리기 / 다시 실행 (현재 보고 있는 페이지 위치 기준) ──
  Future<void> _applyMemoStrokes(String locKey, List<MemoStroke> strokes) async {
    if (locKey == _currentPageLocationKey) {
      setState(() => _memoStrokes = List<MemoStroke>.of(strokes));
    }
    await _saveMemo(locKey, strokes);
  }

  Future<void> _undoMemo() async {
    final r = _memoHistory.undo([_currentPageLocationKey], (_) => _memoStrokes);
    if (r != null) await _applyMemoStrokes(r.$1 as String, r.$2);
  }

  Future<void> _redoMemo() async {
    final r = _memoHistory.redo([_currentPageLocationKey], (_) => _memoStrokes);
    if (r != null) await _applyMemoStrokes(r.$1 as String, r.$2);
  }

  /// 지우개로 문지르기를 끝냈을 때, 실제로 지워진 게 있으면 되돌리기 기록에 남김
  void _finishEraseHistory() {
    final start = _eraseStartStrokes;
    _eraseStartStrokes = null;
    if (start == null) return;
    if (!identical(_memoStrokes, start)) {
      setState(() => _memoHistory.record(_currentPageLocationKey, start));
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
      // 펜: 누르면 펜 선택, 선택된 상태에서 한 번 더 누르면 선 굵기·색상 설정 창
      MemoToolButton(
        // 깃털 펜 + 잉크병 (잉크병 안 색 = 지금 펜 색)
        iconBuilder: (c) => QuillInkIcon(color: c, ink: _penColor, size: 22),
        label: _tr('펜 (한 번 더 누르면 굵기·색상)', 'Pen (tap again: size & color)', '笔 (再点一次: 粗细·颜色)', 'ペン (もう一度タップ: 太さ・色)'),
        active: !_isEraserMode,
        onTap: () => setState(() => _isEraserMode = false),
        onReselect: (_) => _openPenSettings(),
      ),
      // 지우개: 누르면 지우개 선택, 선택된 상태에서 한 번 더 누르면 획/영역 지우개 선택
      MemoToolButton(
        iconBuilder: (c) => EraserIcon(color: c),
        label: _eraserType == 'stroke'
            ? _tr('획 지우개 (한 번 더 누르면 종류 선택)', 'Stroke Eraser (tap again: type)', '笔画橡皮擦 (再点一次: 类型)', 'ストローク消しゴム (もう一度タップ: 種類)')
            : _tr('영역 지우개 (한 번 더 누르면 종류 선택)', 'Area Eraser (tap again: type)', '区域橡皮擦 (再点一次: 类型)', '部分消しゴム (もう一度タップ: 種類)'),
        active: _isEraserMode,
        onTap: () => setState(() => _isEraserMode = true),
        onReselect: _chooseEraserType,
      ),
      // 되돌리기 / 다시 실행
      MemoToolButton(
        icon: Icons.undo,
        label: _tr('되돌리기', 'Undo', '撤销', '元に戻す'),
        enabled: _memoHistory.canUndo([_currentPageLocationKey]),
        onTap: _undoMemo,
      ),
      MemoToolButton(
        icon: Icons.redo,
        label: _tr('다시 실행', 'Redo', '重做', 'やり直し'),
        enabled: _memoHistory.canRedo([_currentPageLocationKey]),
        onTap: _redoMemo,
      ),
      MemoToolButton(
        icon: Icons.delete_sweep_outlined,
        color: Colors.redAccent,
        label: _tr('전체 지우기', 'Clear All Strokes', '清空全部手写', '手書きを全消去'),
        onTap: () async {
          final locKey = _currentPageLocationKey;
          if (_memoStrokes.isNotEmpty) _memoHistory.record(locKey, _memoStrokes);
          setState(() => _memoStrokes = []);
          await _saveMemo(locKey, []);
        },
      ),
      MemoDoneButton(
        label: _tr('완료', 'Done', '完成', '完了'),
        onTap: () => setState(() {
          _isMemoMode = false;
          _isEraserMode = false;
          _allowFingerDrawing = false;
          _isStylusDown = false;
        }),
      ),
    ];
  }

  /// 메모 도구모음 배치: 하단(기본) / 상단 / 왼쪽 / 오른쪽
  Widget _buildMemoToolbar(double bottomInset) {
    final List<Widget> items = _memoToolItems();
    final double topInset = MediaQuery.paddingOf(context).top;
    final double baseBottom = math.max<double>(bottomInset + 24.0, 28.0);
    final double bottomBarSpace = (((_showControls && _progressBarPos == 'bottom') || _useQuickNavTurn) ? 46.0 : 0.0);
    final double topOffset = topInset + (_showControls ? 64.0 : 16.0);
    switch (_memoToolbarPos) {
      case 'top':
        return Positioned(
          key: const ValueKey('memo_toolbar_top'),
          top: topOffset,
          left: 12 + _safeSides.left,
          right: 12 + _safeSides.right,
          child: Center(child: MemoToolbar(children: items)),
        );
      case 'left':
      case 'right':
        final bool isLeft = _memoToolbarPos == 'left';
        // 같은 쪽에 세로 진행바가 있으면 그 안쪽으로 비켜서 배치
        final double edge = ((_showControls && _progressBarPos == _memoToolbarPos) ? 56.0 : 12.0) + (isLeft ? _safeSides.left : _safeSides.right);
        // 아래쪽 진행바·도구 모음과 겹치지 않도록
        final double bottomLimit = _memoBarToFloorLandscape
            // 5. 가로 모드: 바닥까지 (오른쪽 아래 페이지 이동 버튼이 있으면 그 위까지)
            ? baseBottom + ((_useQuickNavTurn && _memoToolbarPos == 'right') ? 46.0 : 0.0)
            : baseBottom + bottomBarSpace + (_showControls ? 52.0 : 8.0);
        return Positioned(
          key: ValueKey('memo_toolbar_$_memoToolbarPos'),
          top: topOffset,
          bottom: bottomLimit,
          left: isLeft ? edge : null,
          right: isLeft ? null : edge,
          child: Center(widthFactor: 1, child: MemoToolbar(vertical: true, children: items)),
        );
      default:
        return Positioned(
          key: const ValueKey('memo_toolbar_bottom'),
          bottom: baseBottom + bottomBarSpace,
          left: 12 + _safeSides.left,
          right: 12 + _safeSides.right,
          child: Center(child: MemoToolbar(children: items)),
        );
    }
  }

  /// EPUB·TXT 본문이 시작하는 높이: 상단바(위 여백 + 버튼 줄 48) 아래로 살짝 띄움
  double get _readerTextTop {
    // 메뉴를 열 때 상태표시줄이 나타나도 본문 자리가 그대로이도록 (바뀌면 책 화면이 다시 그려지며 깜빡임)
    final double barBottom = SystemBars.stableTop(context) + 48.0;
    // TXT는 화면 안쪽에 자체 여백(32)이 있어 그만큼 덜 내린다
    if (_isTxt) return math.max(12.0, barBottom + 10.0 - TxtPageDocument.margin);
    // EPUB: 빈 곳을 줄이려고 상단바와 겹치더라도 상태표시줄 바로 아래에서 시작
    // (책 화면 안쪽 위 여백도 8로 줄여 첫 줄이 상단바 아랫부분쯤에 옴)
    return SystemBars.stableTop(context);
  }

  /// 6. 카메라(디스플레이 컷아웃)·시스템 영역 여백. 떠 있는 UI가 카메라를 가리지 않도록 좌우에 더한다.
  EdgeInsets get _safeSides => MediaQuery.viewPaddingOf(context);

  bool get _isLandscapeNow {
    final Size sz = MediaQuery.sizeOf(context);
    return sz.width > sz.height;
  }

  /// 가로 모드에서 메모 도구모음이 왼쪽/오른쪽(세로)에 있을 때:
  /// 세로 공간이 좁으므로 메모 도구모음은 바닥까지 길게 내려온다.
  bool get _memoBarToFloorLandscape =>
      _isMemoMode &&
      !_isTouchLocked &&
      _showControls &&
      _isLandscapeNow &&
      (_memoToolbarPos == 'left' || _memoToolbarPos == 'right');

  /// 5. 가로 모드 + 하단 진행바: 진행바를 메모 도구모음 쪽에서 줄인다
  /// (오른쪽 아래 페이지 이동 버튼이 있으면 그쪽은 이미 비어 있으므로 제외)
  bool get _memoBarBesideProgress =>
      _memoBarToFloorLandscape && _progressBarPos == 'bottom' && !(_useQuickNavTurn && _memoToolbarPos == 'right');

  /// 5. 위 상황에서 진행바가 메모 도구모음 쪽에서 비켜 주는 폭 (메모 도구모음 폭 48 + 간격 8)
  static const double _memoBarSideInset = 54.0;

  Future<void> _openPenSettings() {
    return showPenSettingsPanel(
      context: context,
      color: _penColor,
      width: _penWidth,
      onColorChanged: (c) => setState(() {
        _penColor = c;
        _isEraserMode = false;
      }),
      onWidthChanged: (w) => setState(() => _penWidth = w),
      tr: _tr,
    );
  }

  Future<void> _chooseEraserType(BuildContext buttonContext) async {
    final v = await showEraserTypeMenu(buttonContext, _eraserType, _tr, barPos: _memoToolbarPos);
    if (v == null || !mounted) return;
    setState(() {
      _eraserType = v;
      _isEraserMode = true;
    });
    await StorageService.setMemoEraserType(v);
  }

  /// 2 & 5. 삼성 노트 스타일 초고속 캡슐 지우개 (드래그 중 디스크 I/O 제거)
  void _eraseStrokeAt(Offset localPos, _MemoMap map) {
    if (_memoStrokes.isEmpty || !map.valid) {
      _lastEraserPos = localPos;
      return;
    }

    final Offset prevPos = _lastEraserPos ?? localPos;
    _lastEraserPos = localPos;

    final double hitRadius = math.max<double>(15.0, _penWidth * 3.2);
    final double minEraserX = math.min(prevPos.dx, localPos.dx) - hitRadius;
    final double maxEraserX = math.max(prevPos.dx, localPos.dx) + hitRadius;
    final double minEraserY = math.min(prevPos.dy, localPos.dy) - hitRadius;
    final double maxEraserY = math.max(prevPos.dy, localPos.dy) + hitRadius;

    bool modifiedAny = false;
    final nextStrokes = <MemoStroke>[];

    for (final s in _memoStrokes) {
      if (s.dxList.isEmpty) continue;

      double sMinX = double.infinity, sMaxX = double.negativeInfinity;
      double sMinY = double.infinity, sMaxY = double.negativeInfinity;
      for (int i = 0; i < s.dxList.length; i++) {
        final Offset q = map.toLocal(s.dxList[i], s.dyList[i]);
        final px = q.dx, py = q.dy;
        if (px < sMinX) sMinX = px;
        if (px > sMaxX) sMaxX = px;
        if (py < sMinY) sMinY = py;
        if (py > sMaxY) sMaxY = py;
      }
      if (sMaxX < minEraserX || sMinX > maxEraserX || sMaxY < minEraserY || sMinY > maxEraserY) {
        nextStrokes.add(s);
        continue;
      }

      final densePts = <Offset>[];
      for (int i = 0; i < s.dxList.length; i++) {
        final p0 = map.toLocal(s.dxList[i], s.dyList[i]);
        densePts.add(p0);
        if (i + 1 < s.dxList.length) {
          final p1 = map.toLocal(s.dxList[i + 1], s.dyList[i + 1]);
          final dist = (p1 - p0).distance;
          if (dist > 4.0) {
            final steps = (dist / 4.0).ceil();
            for (int k = 1; k < steps; k++) {
              final t = k / steps;
              densePts.add(Offset(p0.dx + (p1.dx - p0.dx) * t, p0.dy + (p1.dy - p0.dy) * t));
            }
          }
        }
      }

      bool anyHit = false;
      for (final pt in densePts) {
        if (_distToEraserSegment(pt, prevPos, localPos) <= hitRadius) {
          anyHit = true;
          break;
        }
      }

      if (!anyHit) {
        nextStrokes.add(s);
        continue;
      }

      modifiedAny = true;
      // 획 지우개: 닿은 획은 통째로 지움
      if (_eraserType == 'stroke') continue;
      List<Offset> currentRun = [];
      void flushRun() {
        if (currentRun.isEmpty) return;
        if (currentRun.length == 1) {
          currentRun.add(currentRun.first + const Offset(0.2, 0.2));
        }
        final compact = <Offset>[currentRun.first];
        for (int i = 1; i < currentRun.length - 1; i++) {
          if ((currentRun[i] - compact.last).distance >= 2.2) {
            compact.add(currentRun[i]);
          }
        }
        compact.add(currentRun.last);
        final fracs = [for (final p in compact) map.toFrac(p)];
        nextStrokes.add(
          MemoStroke(
            dxList: [for (final f in fracs) f.dx],
            dyList: [for (final f in fracs) f.dy],
            colorValue: s.colorValue,
            strokeWidth: s.strokeWidth,
          ),
        );
        currentRun = [];
      }

      for (final pt in densePts) {
        if (_distToEraserSegment(pt, prevPos, localPos) <= hitRadius) {
          flushRun();
        } else {
          currentRun.add(pt);
        }
      }
      flushRun();
    }

    if (modifiedAny) {
      setState(() => _memoStrokes = nextStrokes);
    }
  }

  /// 뷰어 표시 설정 (PDF 뷰어와 같은 UI + EPUB 글자 크기·다크 모드 설정 포함)
  /// 뷰어 표시 설정 항목 제목: 관련 아이콘 + 문구 (줄바꿈돼도 아이콘이 문구 앞에 붙어 있음)
  Widget _settingsHeader(IconData icon, String text, {bool isTitle = false}) {
    if (isTitle) return Text(text, style: const TextStyle(fontSize: 22, fontWeight: FontWeight.w800));
    // 구역 이름: 아이콘 + 굵은 글씨를 옅은 띠 위에 두어, 아래 설정이 어느 기능의 것인지 한눈에 보이게
    final cs = Theme.of(context).colorScheme;
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 9),
      decoration: BoxDecoration(color: cs.surfaceContainerHighest, borderRadius: BorderRadius.circular(12)),
      child: Row(
        children: [
          Icon(icon, size: 18, color: cs.onSurface),
          const SizedBox(width: 8),
          Expanded(child: Text(text, style: TextStyle(fontSize: 15, fontWeight: FontWeight.w800, color: cs.onSurface))),
        ],
      ),
    );
  }

  /// 탭 존 가이드라인 띄우기 (앞에 떠 있던 것은 지움)
  void _showTapGuide() {
    if (_tapGuide?.mounted ?? false) _tapGuide!.remove();
    _tapGuide = null;
    unawaited(showTapZoneGuide(context, tapTurn: () => _pageModeTap && !_slideShow && !_isSpreadsheet, tr: _tr).then((e) {
      if (!mounted) {
        if (e?.mounted ?? false) e!.remove();
      } else {
        _tapGuide = e;
      }
    }));
  }

  Future<void> _showViewerSettingsSheet() async {
    // 뷰어 설정에서 탭을 켜고 나가면 탭 존 가이드라인을 보여 줌
    final bool tapBefore = _pageModeTap;
    try {
      await _showViewerSettingsSheetInner();
    } finally {
      if (mounted && !tapBefore && _pageModeTap && !StorageService.tapGuideOff) _showTapGuide();
    }
  }

  Future<void> _showViewerSettingsSheetInner() async {
    // 내용이 맨 위일 때 아래로 끌면 창이 따라 내려오고, 충분히 내리면 닫힘
    final sheetCtrl = BottomSheet.createAnimationController(this)
      ..duration = Anim.ms(250)
      ..reverseDuration = Anim.ms(200);
    await showModalBottomSheet(
      sheetAnimationStyle: Anim.off.value ? AnimationStyle.noAnimation : null,
      context: context,
      isScrollControlled: true,
      // 화면의 2/3까지만 가림 (나머지는 스크롤)
      constraints: BoxConstraints(maxHeight: MediaQuery.of(context).size.height * 2 / 3),
      enableDrag: false,
      transitionAnimationController: sheetCtrl,
      builder: (ctx) => SheetPullToClose(
        controller: sheetCtrl,
        builder: (ctx, sheetScroll, sheetPhysics) => StatefulBuilder(
        builder: (ctx, setModalState) => SafeArea(
          child: SingleChildScrollView(
            controller: sheetScroll,
            physics: sheetPhysics,
            padding: const EdgeInsets.fromLTRB(24, 8, 24, 12),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                // 위쪽 가운데 회색 막대 (앱 설정 창처럼)
                Center(
                  child: Container(
                    width: 40,
                    height: 4,
                    margin: const EdgeInsets.only(bottom: 14),
                    decoration: BoxDecoration(color: Theme.of(context).colorScheme.onSurfaceVariant.withValues(alpha: 0.4), borderRadius: BorderRadius.circular(2)),
                  ),
                ),
                _settingsHeader(Icons.tune, _tr('뷰어 설정', 'Viewer Settings', '阅读器设置', 'ビューア設定'), isTitle: true),
                const SizedBox(height: 12),
                // 글자 크기 (EPUB): 구역 이름 띠는 남은 너비만큼 (예전에는 띠가 끝없이 넓어지려 해 줄 전체가 안 보였음)
                if (!_isOfflineDocument)
                Row(
                  mainAxisAlignment: MainAxisAlignment.spaceBetween,
                  children: [
                    Expanded(child: _settingsHeader(Icons.format_size, _tr('글자 크기', 'Font Size', '字体大小', '文字サイズ'))),
                    const SizedBox(width: 8),
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
                const SizedBox(height: 26),
                _settingsHeader(Icons.lock_open_outlined, _tr('화면 잠금 끄기 설정 (동시 사용 가능)', 'Screen Unlock Settings (Multiple allowed)', '解除屏幕锁定设置 (可同时启用)', '画面ロック解除設定 (同時使用可)')),
                const SizedBox(height: 8),
                SettingGroup(
                  children: [
                    SettingToggle(
                      label: Text(_tr('음량 버튼 동시에 눌러서 끄기', 'Press Both Volume Keys to Unlock', '同时按音量键关闭锁定', '音量ボタン同時押しで解除')),
                      selected: _useVolumeComboLock,
                      onSelected: (val) async {
                        await StorageService.setUseVolumeComboLock(val);
                        setState(() => _useVolumeComboLock = val);
                        setModalState(() {});
                      },
                    ),
                    SettingToggle(
                      label: Text(_tr('흔들어서 끄기', 'Shake to Unlock', '摇晃关闭锁定', '振って解除')),
                      selected: _useShakeLock,
                      onSelected: (val) async {
                        await StorageService.setUseShakeLock(val);
                        setState(() => _useShakeLock = val);
                        setModalState(() {});
                      },
                    ),
                  ],
                ),
                const SizedBox(height: 26),
                ..._pageModeSettings(setModalState),

                const SizedBox(height: 26),
                _settingsHeader(Icons.linear_scale, _tr('진행도 UI 위치', 'Progress Bar Position', '进度条位置', '進行度バーの位置')),
                const SizedBox(height: 8),
                SettingGroup(
                  children: [
                    SettingOption(
                      label: Text(_tr('하단', 'Bottom', '底部', '下部')),
                      selected: _progressBarPosSetting == 'bottom',
                      onSelected: (_) async {
                        await StorageService.setProgressBarPosition('bottom');
                        setState(() => _progressBarPosSetting = 'bottom');
                        setModalState(() {});
                      },
                    ),
                    SettingOption(
                      label: Text(_tr('오른쪽', 'Right', '右侧', '右')),
                      selected: _progressBarPosSetting == 'right',
                      onSelected: (_) async {
                        await StorageService.setProgressBarPosition('right');
                        setState(() => _progressBarPosSetting = 'right');
                        setModalState(() {});
                      },
                    ),
                    SettingOption(
                      label: Text(_tr('왼쪽', 'Left', '左侧', '左')),
                      selected: _progressBarPosSetting == 'left',
                      onSelected: (_) async {
                        await StorageService.setProgressBarPosition('left');
                        setState(() => _progressBarPosSetting = 'left');
                        setModalState(() {});
                      },
                    ),
                    SettingOption(
                      label: Text(_tr('숨김', 'Hidden', '隐藏', '非表示')),
                      selected: _progressBarPosSetting == 'hidden',
                      onSelected: (_) async {
                        await StorageService.setProgressBarPosition('hidden');
                        setState(() => _progressBarPosSetting = 'hidden');
                        setModalState(() {});
                      },
                    ),
                  ],
                ),
                const SizedBox(height: 26),
                _settingsHeader(Icons.draw_outlined, _tr('메모 도구 모음 위치', 'Memo Toolbar Position', '笔记工具栏位置', 'メモツールバーの位置')),
                const SizedBox(height: 8),
                SettingGroup(
                  children: [
                    for (final opt in <(String, String)>[
                      ('bottom', _tr('하단', 'Bottom', '底部', '下部')),
                      ('top', _tr('상단', 'Top', '顶部', '上部')),
                      ('left', _tr('왼쪽', 'Left', '左侧', '左')),
                      ('right', _tr('오른쪽', 'Right', '右侧', '右')),
                    ])
                      SettingOption(
                        label: Text(opt.$2),
                        selected: _memoToolbarPos == opt.$1,
                        onSelected: (_) async {
                          await StorageService.setMemoToolbarPosition(opt.$1);
                          setState(() => _memoToolbarPos = opt.$1);
                          setModalState(() {});
                        },
                      ),
                  ],
                ),
                const SizedBox(height: 26),
                // 왼손잡이: 스크롤 막대를 왼쪽에 (끄면 오른쪽)
                _settingsHeader(Icons.back_hand_outlined, _tr('왼손잡이', 'Left-handed', '左手模式', '左利き')),
                const SizedBox(height: 8),
                SettingGroup(
                  children: [
                    SettingToggle(
                      label: Text(_tr('스크롤 막대를 왼쪽으로', 'Scroll bar on the left', '滚动条放在左侧', 'スクロールバーを左に')),
                      selected: _quickMenuSide == 'left',
                      onSelected: (val) async {
                        final side = val ? 'left' : 'right';
                        await StorageService.setQuickMenuSide(side);
                        ScrollThumbBar.leftHanded.value = val;
                        setState(() => _quickMenuSide = side);
                        setModalState(() {});
                      },
                    ),
                  ],
                ),
                const SizedBox(height: 26),
                _settingsHeader(Icons.info_outline, _tr('하단 정보 표시', 'Footer Info Display', '底部信息显示', '下部情報表示')),
                const SizedBox(height: 8),
                SettingGroup(
                  children: [
                    SettingOption(
                      label: Text(_tr('정보 표시 없음', 'None', '不显示', '表示なし')),
                      selected: _footerInfoMode == 'none',
                      onSelected: (_) async {
                        await StorageService.setFooterInfoMode('none');
                        setState(() => _footerInfoMode = 'none');
                        setModalState(() {});
                      },
                    ),
                    SettingOption(
                      label: Text(_tr('페이지 번호', 'Page Number', '页码', 'ページ番号')),
                      selected: _footerInfoMode == 'page',
                      onSelected: (_) async {
                        await StorageService.setFooterInfoMode('page');
                        setState(() => _footerInfoMode = 'page');
                        setModalState(() {});
                      },
                    ),
                  ],
                ),
                // 초기화: 기본값으로 (화면 잠금 끄기·페이지 모드·페이지 전환 버튼·진행도 UI·메모 도구 모음·도구 모음 형태·하단 정보)
                SettingDoneButton(label: _tr('초기화', 'Reset', '重置', 'リセット'), onPressed: () => _resetViewerSettings(setModalState)),
              ],
            ),
          ),
        ),
      ),
      ),
    );
    disposeSheetControllerWhenDone(sheetCtrl);
  }

  // EPUB: 지금 장의 처음/끝에 닿았는지, 첫/마지막 장인지
  bool _chAtStart = false, _chAtEnd = false, _chFirst = true, _chLast = false;

  /// 장 이동 버튼 높이: 아래 진행바·도구 모음 바·필기 도구 막대가 있으면 그 위에
  double _chapterButtonsBottom(double bottomPadding) {
    double b = math.max<double>(bottomPadding + 16.0, 20.0) + 8.0;
    if ((_showControls && _progressBarPos == 'bottom') || _useQuickNavTurn) b += 44.0;
    if (_isMemoMode && _memoToolbarPos == 'bottom') b += 60.0;
    if (_showControls) b += 62.0; // 도구 모음
    return b;
  }

  Widget _buildChapterButtons() {
    final bool dark = _getBgColor().computeLuminance() < 0.4;
    // 종이색: 흰 단추가 튀지 않게, 종이보다 조금 진한 갈색 단추로 (잘 보이게)
    final bool paper = _epubBgTheme == 'sepia';
    final Color bg = dark ? const Color(0xFF111111) : paper ? const Color(0xFFE6D3AE) : const Color(0xFFF1F1F4);
    final Color fg = dark ? Colors.white : paper ? const Color(0xFF4A3A28) : const Color(0xFF222222);
    final Color border = dark ? Colors.white24 : paper ? const Color(0x806B4E2A) : Colors.black12;
    Widget button(String label, IconData icon, bool enabled, int dir) => Opacity(
          opacity: enabled ? 1 : 0.35,
          child: Material(
            color: bg,
            shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16), side: BorderSide(color: border)),
            child: InkWell(
              borderRadius: BorderRadius.circular(16),
              onTap: enabled
                  ? () {
                      HapticFeedback.selectionClick();
                      setState(() {
                        _chAtStart = false;
                        _chAtEnd = false;
                      });
                      _epubController.goChapter(dir);
                    }
                  : null,
              child: Padding(
                padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 12),
                child: Row(mainAxisSize: MainAxisSize.min, children: [
                  Icon(icon, size: 20, color: fg),
                  const SizedBox(width: 8),
                  Text(label, style: TextStyle(fontSize: 15, fontWeight: FontWeight.w600, color: fg)),
                ]),
              ),
            ),
          ),
        );
    return Row(
      mainAxisAlignment: MainAxisAlignment.center,
      children: [
        button(_tr('이전 챕터', 'Prev chapter', '上一章', '前の章'), Icons.keyboard_arrow_up_rounded, !_chFirst, -1),
        const SizedBox(width: 12),
        button(_tr('다음 챕터', 'Next chapter', '下一章', '次の章'), Icons.keyboard_arrow_down_rounded, !_chLast, 1),
      ],
    );
  }

  /// 목차 열기: 책 화면을 그림으로 잠시 바꿔 두고 열어 움직임이 끊기지 않게
  Uint8List? _tocFreeze;
  // EPUB 스크롤 보기: [지금 위치, 장 전체 길이, 보이는 높이] (오른쪽 회색 막대)
  final ValueNotifier<List<double>> _epubScrollMetrics = ValueNotifier(const [0, 0, 0]);
  Future<void> _openToc() async {
    final bool docScroll = _pageModeScroll && _isOfflineDocument;
    if (!docScroll && _tocFreeze == null) {
      try {
        final bytes = await _pdfChannel.invokeMethod<Uint8List>('snapshotWebView', {
          'background': _isPaperTheme ? 0 : _getBgColor().toARGB32(), // 종이색: 질감이 그대로 보이게 투명
          'scale': 1.0,
        }).timeout(const Duration(milliseconds: 600));
        if (mounted && bytes != null && bytes.length > 512) {
          setState(() => _tocFreeze = bytes);
          await WidgetsBinding.instance.endOfFrame;
        }
      } catch (_) {}
    }
    if (!mounted) return;
    _scaffoldKey.currentState?.openDrawer();
  }

  /// 지금 가로 모드 2페이지로 보고 있는가
  bool get _bookmarkSpreadNow {
    final size = MediaQuery.sizeOf(context);
    return _spreadFor(size.width > size.height) && (!_isOfflineDocument || _docPageCount > 1);
  }

  /// 북마크 이름: 쪽 번호 ('12페이지', 2페이지 보기면 '12, 13페이지')
  String _bookmarkPageLabel(bool spread) {
    final int total = math.max(1, _docPageCount);
    final int page = (_docPage + 1).clamp(1, total).toInt();
    if (spread && page + 1 <= total) return '$page, ${page + 1}페이지';
    return '$page페이지';
  }

  /// 북마크 이름: 저장된 쪽 번호로 보여 줌
  String _bookmarkTitle(BookmarkItem bm) {
    final m = RegExp(r'^[a-z]+:(\d+)$').firstMatch(bm.position);
    if (m != null) {
      final int page = int.parse(m.group(1)!) + 1;
      return bm.spread && (page + 1 <= _docPageCount || _docPageCount == 0) ? '$page, ${page + 1}페이지' : '$page페이지';
    }
    return bm.label;
  }

  /// 북마크로 이동: 북마크할 때의 화면 회전·페이지 표시·페이지 모드로 돌려놓은 뒤 그 자리를 보여 줌
  Future<void> _openBookmark(BookmarkItem bm) async {
    setState(() => _initialCfi = bm.position);
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
      if (mounted) setState(() => _initialCfi = bm.position);
      await Future<void>.delayed(const Duration(milliseconds: 900));
      if (!mounted) return;
    }
    _readerDisplay(bm.position);
  }

  Future<void> _openBookmarkSheet() async {
    final bookmarks = await StorageService.getBookmarks(widget.filePath);
    if (mounted) {
      setState(() => _bookmarks = bookmarks);
    }
    final String? target = await _bookmarkTarget();
    if (!mounted) return;
    final bool already = target != null && _isBookmarkedAt(target);

    showModalBottomSheet(
      sheetAnimationStyle: Anim.off.value ? AnimationStyle.noAnimation : null,
      context: context,
      builder: (ctx) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            ListTile(
              title: Text(_tr('북마크 목록', 'Bookmarks', '书签列表', 'ブックマーク一覧'), style: const TextStyle(fontWeight: FontWeight.w800)),
              // 같은 쪽(같은 보기 방식)은 한 번만 북마크
              trailing: ElevatedButton.icon(
                icon: Icon(already ? Icons.bookmark_added : Icons.bookmark_add, size: 16),
                label: Text(already
                    ? _tr('북마크한 페이지예요', 'Already bookmarked', '已添加书签', 'ブックマーク済みです')
                    : _tr('현재 페이지 북마크', 'Bookmark This Page', '添加当前页书签', '現在ページをブックマーク')),
                onPressed: already || target == null ? null : () async {
                  final now = DateTime.now();
                  final bool spread = !_pageModeScroll && _bookmarkSpreadNow;
                  await StorageService.addBookmark(
                    widget.filePath,
                    BookmarkItem(
                      id: now.millisecondsSinceEpoch.toString(),
                      label: _bookmarkPageLabel(spread),
                      position: target,
                      createdAt: '${now.month}/${now.day} ${now.hour}:${now.minute.toString().padLeft(2, '0')}',
                      spread: spread,
                      rotation: _rotationModeNow,
                      landscape: MediaQuery.sizeOf(context).width > MediaQuery.sizeOf(context).height,
                      display: _pageDisplay,
                      scroll: _pageModeScroll,
                    ),
                  );
                  if (ctx.mounted) Navigator.pop(ctx);
                  _openBookmarkSheet();
                },
              ),
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
                    return ListTile(
                      leading: Icon(bm.spread ? Icons.menu_book : Icons.bookmark, color: Colors.amber),
                      title: Text(_bookmarkTitle(bm)),
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
                        _openBookmark(bm);
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
  }

  // ── 파일 내 단어 검색 (한글·워드) ──
  bool _findOpen = false;

  // 파일 내 단어 찾기 (한글·워드): 스크롤 보기에서도 그 쪽으로 옮기고 쪽 그림 위에 형광펜
  String _findQuery = '';
  Future<int> _docFindSearch(String q) async {
    final n = await _hwpController.search(q);
    if (mounted) setState(() => _findQuery = n > 0 ? q : '');
    return n;
  }

  Future<void> _docFindGoto(int index) async {
    await _hwpController.showSearchResult(index);
  }

  void _closeFind() {
    if (_findQuery.isNotEmpty) setState(() => _findQuery = '');
    if (_isTxt) {
      _txtController.clearSearch();
    } else {
      unawaited(_hwpController.clearSearch());
    }
    setState(() => _findOpen = false);
  }

  // ── PPT 슬라이드 쇼: 가로 전체 화면, 검은 바탕, 화면을 누르거나 밀어서 넘김 ──
  bool _slideShow = false;
  bool _slideShowExitVisible = false;
  Timer? _slideShowExitTimer;
  double _slideShowDragDx = 0;

  Future<void> _startSlideShow() async {
    // 슬라이드 쇼는 항상 첫 슬라이드부터 시작한다
    final first = '$_documentPositionPrefix:0';
    setState(() {
      _slideShow = true;
      _showControls = false;
      _isMemoMode = false;
      _initialCfi = first;
    });
    _readerDisplay(first);
    _showSlideShowExit();
    try {
      await _pdfChannel.invokeMethod('setScreenOrientation', {'mode': 'landscape'});
    } catch (_) {}
  }

  Future<void> _endSlideShow() async {
    _slideShowExitTimer?.cancel();
    setState(() {
      _slideShow = false;
      _slideShowExitVisible = false;
      _initialCfi = _currentCfi;
    });
    final bool? want = StorageService.desiredLandscapeNotifier.value;
    try {
      await _pdfChannel.invokeMethod('setScreenOrientation', {
        'mode': want == null ? 'unspecified' : (want ? 'landscape' : 'portrait'),
      });
    } catch (_) {}
  }

  void _showSlideShowExit() {
    _slideShowExitTimer?.cancel();
    setState(() => _slideShowExitVisible = true);
    _slideShowExitTimer = Timer(const Duration(seconds: 3), () {
      if (mounted) setState(() => _slideShowExitVisible = false);
    });
  }

  /// 슬라이드 쇼 화면 맨 위: 누르거나 밀어 넘기기, 위쪽을 누르면 끝내기 버튼
  Widget _buildSlideShowLayer() {
    return Positioned.fill(
      child: LayoutBuilder(
        builder: (context, box) => GestureDetector(
          behavior: HitTestBehavior.opaque,
          onTapUp: (d) {
            if (d.localPosition.dy < box.maxHeight * 0.15) {
              _showSlideShowExit();
            } else if (d.localPosition.dx < box.maxWidth * 0.3) {
              _readerPrevious();
            } else {
              _readerNext();
            }
          },
          onHorizontalDragStart: (_) => _slideShowDragDx = 0,
          onHorizontalDragUpdate: (d) => _slideShowDragDx += d.delta.dx,
          onHorizontalDragEnd: (d) {
            final v = d.primaryVelocity ?? 0;
            if (_slideShowDragDx < -40 || v < -400) _readerNext();
            if (_slideShowDragDx > 40 || v > 400) _readerPrevious();
          },
          child: Align(
            alignment: Alignment.topRight,
            child: AnimatedOpacity(
              opacity: _slideShowExitVisible ? 1 : 0,
              duration: Anim.ms(200),
              child: IgnorePointer(
                ignoring: !_slideShowExitVisible,
                child: SafeArea(
                  child: Padding(
                    padding: const EdgeInsets.all(12),
                    child: Material(
                      color: Colors.black54,
                      borderRadius: BorderRadius.circular(20),
                      child: InkWell(
                        borderRadius: BorderRadius.circular(20),
                        onTap: _endSlideShow,
                        child: Padding(
                          padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 8),
                          child: Row(
                            mainAxisSize: MainAxisSize.min,
                            children: [
                              const Icon(Icons.close, color: Colors.white, size: 16),
                              const SizedBox(width: 6),
                              Text(_tr('슬라이드 쇼 끝내기', 'End Slide Show', '结束幻灯片放映', 'スライドショー終了'),
                                  style: const TextStyle(color: Colors.white, fontSize: 13)),
                            ],
                          ),
                        ),
                      ),
                    ),
                  ),
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }

  Completer<void>? _relocateWaiter;

  // 본문 전체 영역과 WebView 영역 위치 (종이 질감·화면 그림 자리)
  final GlobalKey _epubBodyKey = GlobalKey();
  final GlobalKey _epubViewRectKey = GlobalKey();

  /// 넘길 수 있는지 (책처럼 넘기기): 마지막(첫) 쪽에서는 더 넘길 곳이 없음
  bool _canTurnSwipe(int dir) {
    if (_isOfflineDocument && _docPageCount > 0) {
      // 파워포인트는 마지막 슬라이드에도 애니메이션 단계가 남아 있을 수 있다 (남은 단계가 없으면 더 넘길 곳 없음)
      if (_isPresentation) {
        return dir > 0 ? _docPage < _docPageCount - 1 || _pptStepsLeft > 0 : _docPage > 0 || _posOrder(_currentCfi) % 100000 > 0;
      }
      // 두 쪽 보기는 두 쪽씩 넘어가므로, 다음 두 쪽의 첫 쪽이 있어야 넘길 수 있음
      final int step = _bookmarkSpreadNow ? 2 : 1;
      return dir > 0 ? _docPage + step <= _docPageCount - 1 : _docPage > 0;
    }
    if (!_isOfflineDocument) {
      // EPUB: 책의 마지막(첫) 화면에서는 더 넘길 곳이 없다
      return dir > 0 ? !_epubAtEnd : !_epubAtStart;
    }
    return true;
  }

  /// 쪽 위치 알림을 기다린다. 문서는 쪽 번호가 [until]을 만족할 때까지(다른 알림은 건너뜀).
  Future<bool> _vWaitRelocate(void Function() action, bool Function() until) async {
    final deadline = DateTime.now().add(const Duration(milliseconds: 1500));
    action();
    while (true) {
      if (_isOfflineDocument && until()) return true;
      final left = deadline.difference(DateTime.now());
      if (left <= Duration.zero) return _isOfflineDocument && until();
      final waiter = Completer<void>();
      _relocateWaiter = waiter;
      bool got = true;
      await waiter.future.timeout(left, onTimeout: () => got = false);
      if (identical(_relocateWaiter, waiter)) _relocateWaiter = null;
      if (!_isOfflineDocument) return got;
      if (!got) return until();
    }
  }

  Future<bool> _vTurnAndWait(int dir) {
    // 쪽 번호가 같아도 위치가 바뀌면 넘어간 것 (파워포인트 애니메이션 단계)
    final String? before = _currentCfi;
    final int beforePage = _docPage;
    return _vWaitRelocate(dir > 0 ? _readerNext : _readerPrevious, () => _docPage != beforePage || _currentCfi != before);
  }

  /// 문서 위치('docx:3', 'pptx:3:2' 등)를 앞뒤 비교용 숫자로 (쪽×100000 + 단계)
  int _posOrder(String? pos) {
    final m = RegExp(r'^[a-z]+:(\d+)(?::(\d+))?$').firstMatch(pos ?? '');
    if (m == null) return _docPage * 100000;
    return int.parse(m.group(1)!) * 100000 + int.parse(m.group(2) ?? '0');
  }

  // ── 종이처럼 말아 넘기기 (슬라이드) ──

  bool get _curlOn =>
      // PPT·엑셀은 책처럼 넘기지 않음. '애니메이션 멈추기'를 켜도 책처럼 넘기기는 그대로
      StorageService.pageCurl && _useSwipeTurn && !_pageModeScroll && !_isSpreadsheet && !_slideShow && !_isPresentation;

  /// 종이처럼 넘기기 설정이 바뀌면 EPUB 책 화면 스스로의 밀어 넘기기를 끄고/켬
  void _syncCurlSwipe() {
    if (_isOfflineDocument) return;
    try {
      _epubController.setSwipeEnabled(_useSwipeTurn && !_pageModeScroll && !_curlOn);
    } catch (_) {}
  }

  // 손가락이 닿을 때 미리 찍어 둔 화면 (밀고 뗐을 때 바로 말기 시작하게)
  Future<ui.Image?>? _curlPre;
  // 두 쪽 보기: 책처럼 넘기기 (손가락을 따라 모서리부터 말려 넘어감)
  late final BookCurlDrag _book = BookCurlDrag(
    vsync: this,
    capture: _captureForCurl,
    turn: (dir) {
      _hasTextSelection = false;
      return _vTurnAndWait(dir);
    },
    isRtl: () => _isMangaRtlMode,
    // 마지막(첫) 쪽에서는 넘기는 모습도 보이지 않음
    canTurn: _canTurnSwipe,
    paperOf: _curlPaper,
    // 넘긴 새 쪽이 늦게 그려지면(EPUB 장 바뀜·한글·워드) 다 그려진 뒤에 덮개를 걷음 → 검은·흰 화면이 비치지 않게
    waitForPage: () => true,
    beforeAfterCapture: _waitTurnedPageReady,
    // 새 쪽 그림을 찍어 붙이지 않고, 넘겨 둔 실제 화면이 다 그려지면 그대로 비쳐 보이게 (부드럽고 바로 보임)
    liveReady: _curlLiveReady,
    // 이전 쪽으로 되돌아올 때: 다음 쪽으로 넘어오며 떠나온 쪽 그림을 바로 씀 (글이 깜빡이지 않게)
    reverseFront: _takeBackShot,
  )..addListener(_onBookCurlChanged);

  // 지나온 쪽 그림들 (최근 10장, 한 장에 화면 한 장 크기 메모리). key = 그 쪽에서 다음 쪽으로 넘어가 도착한 쪽의 자리
  final List<({ui.Image image, String? key})> _backShots = [];
  int _navDir = 0; // 마지막 넘김 방향 (1 다음 쪽, -1 이전 쪽, 0 그 밖의 이동)
  String? _posKey; // 지금 쪽의 자리 (마지막으로 찍어 둔 그림 기준)

  /// 쪽이 바뀌기 직전: 다음 쪽으로 가면 지금 쪽 그림을 '되돌아올 때 쓸 그림'으로 보관, 이전 쪽으로 가면 다 쓴 것을 버림
  void _onPositionChanging() {
    final shot = _idleShot;
    final key = _idleShotKey ?? _posKey;
    if (_navDir > 0 && shot != null && _idleShotKey != null) {
      // 자리를 아직 못 적은 것(아주 빨리 넘김)은 버림
      _backShots.removeWhere((b) {
        if (b.key != null) return false;
        b.image.dispose();
        return true;
      });
      _backShots.add((image: shot, key: null));
      _idleShot = null; // 그림은 보관함으로 넘김
      while (_backShots.length > 10) {
        _backShots.removeAt(0).image.dispose();
      }
    } else if (_navDir < 0) {
      if (_backShots.isNotEmpty && key != null && _backShots.last.key == key) _backShots.removeLast().image.dispose();
    } else {
      _dropBackShots();
    }
    _navDir = 0;
    _dropIdleShot();
  }

  void _setIdleShot(ui.Image img, String key, List<Rect>? frames) {
    _idleShot?.dispose();
    _idleShot = img;
    _idleShotKey = key;
    _idleFrames = frames;
    _posKey = key;
    // 방금 다음 쪽으로 넘어와 자리를 못 적은 그림: 이 쪽이 도착한 쪽
    if (_backShots.isNotEmpty && _backShots.last.key == null) {
      final b = _backShots.removeLast();
      _backShots.add((image: b.image, key: key));
    }
  }

  ui.Image? _takeBackShot() {
    if (_backShots.isEmpty) return null;
    final last = _backShots.last;
    if (last.key == null || last.key != _curlShotKey()) return null;
    return last.image.clone();
  }

  void _dropBackShots() {
    for (final b in _backShots) {
      b.image.dispose();
    }
    _backShots.clear();
  }

  /// 넘겨 둔 실제 화면이 다 그려질 때까지 기다림
  Future<void> _curlLiveReady() async {
    if (_isTxt) {
      await SchedulerBinding.instance.endOfFrame;
      return;
    }
    if (_isOfflineDocument) {
      await _waitTurnedPageReady();
    } else {
      await SchedulerBinding.instance.endOfFrame;
      await Future<void>.delayed(const Duration(milliseconds: 40));
    }
    // 책 화면이 지금 쪽을 실제로 그릴 준비가 될 때까지 (아직 그려지지 않은 흰 빈 곳이 비치지 않게)
    try {
      await _pdfChannel.invokeMethod('webVisualReady').timeout(const Duration(milliseconds: 900));
    } catch (_) {}
    await SchedulerBinding.instance.endOfFrame;
  }

  // ── 손가락을 대자마자 넘기기 시작하도록: 가만히 읽는 동안 지금 쪽을 미리 찍어 둠 ──
  ui.Image? _idleShot;
  String? _idleShotKey;
  List<Rect>? _idleFrames;
  Timer? _idleShotTimer;
  bool _bookWasBusy = false;

  String _curlShotKey() {
    if (!mounted) return '';
    final size = MediaQuery.sizeOf(context);
    return '${_currentCfi ?? ''}|$_docPage|${size.width.round()}x${size.height.round()}|${_getBgColor().toARGB32()}|$_bookmarkSpreadNow|$_lastReadyPage|$_isCurrentPageBookmarked|${_memoStrokes.length}|$_currentPageLocationKey';
  }

  void _dropIdleShot() {
    _idleShotTimer?.cancel();
    _idleShot?.dispose();
    _idleShot = null;
    _idleShotKey = null;
    _idleFrames = null;
  }

  /// 문서가 확대를 직접 그리는 파일 (한글·워드 쪽 넘김 보기. PPT는 슬라이드가 그림이라 제외)
  bool get _docLiveZoom => _isOfflineDocument && !_isTxt && !_isSpreadsheet && !_isPresentation && !_pageModeScroll && !_docVertical;

  static bool _sameMatrix(Matrix4 a, Matrix4 b) {
    for (int i = 0; i < 16; i++) {
      if ((a.storage[i] - b.storage[i]).abs() > 0.01) return false;
    }
    return true;
  }

  bool get _docViewNone => _sameMatrix(_docShownView.value, Matrix4.identity());

  /// 확대·이동이 바뀔 때마다 문서에 그 배율·자리를 알려 직접 그리게 함 (한 번에 하나씩, 밀린 것은 마지막 것만)
  void _onZoomMatrixChanged() {
    if (!_docLiveZoom) return;
    final Matrix4 m = _epubZoomController.value.clone();
    if (_viewSending) {
      _viewPending = m;
      return;
    }
    _sendDocView(m);
  }

  Future<void> _sendDocView(Matrix4 m) async {
    _viewSending = true;
    final double s = m.getMaxScaleOnAxis();
    final t = m.getTranslation();
    final Matrix4 shown = s < 1.001 ? Matrix4.identity() : m;
    try {
      await _hwpController.setView(s < 1.001 ? 1 : s, s < 1.001 ? 0 : t.x, s < 1.001 ? 0 : t.y);
    } catch (_) {}
    _viewSending = false;
    if (!mounted) return;
    _docShownView.value = shown;
    final Matrix4? next = _viewPending;
    _viewPending = null;
    if (next != null && !_sameMatrix(next, m)) _sendDocView(next);
  }

  void _scheduleIdleShot() {
    _dropIdleShot();
    // 책처럼 넘기기용
    if (!_curlOn || _isTxt) return;
    _idleShotTimer = Timer(const Duration(milliseconds: 380), () async {
      if (!mounted || !_curlOn || _book.busy) return;
      if (_epubZoomScale > 1.03 || !_docViewNone) return; // 확대해 둔 동안은 찍지 않음
      if (_isOfflineDocument && _lastReadyPage != _docPage) return; // 다 그려지면 다시 불림
      final key = _curlShotKey();
      final img = await _captureForCurl(screen: true);
      List<Rect>? frames;
      if (_isOfflineDocument) {
        frames = await _hwpController.pageFrames().timeout(const Duration(milliseconds: 300), onTimeout: () => const <Rect>[]);
      }
      if (!mounted || _book.busy || key != _curlShotKey() || img == null) {
        img?.dispose();
        return;
      }
      _setIdleShot(img, key, (frames == null || frames.isEmpty) ? null : frames);
    });
  }

  void _onBookCurlChanged() {
    final bool busy = _book.busy;
    if (_bookWasBusy && !busy) {
      _scheduleIdleShot(); // 다 넘어간 뒤 새 쪽을 찍어 둠
    }
    _bookWasBusy = busy;
  }

  /// 한글·워드: 넘긴 쪽의 그림까지 다 그려졌다는 알림(pageReady)을 기다림
  Future<void> _waitTurnedPageReady() async {
    if (!_isOfflineDocument || _isTxt) return;
    final end = DateTime.now().add(const Duration(milliseconds: 1500));
    while (mounted && _lastReadyPage != _docPage && DateTime.now().isBefore(end)) {
      await Future<void>.delayed(const Duration(milliseconds: 30));
    }
  }

  /// 넘어가는 쪽(종이)의 자리: 워드·한글·PPT는 화면에 놓인 쪽 네모 (빈 여백은 넘어가지 않음).
  /// EPUB·TXT는 화면 전체가 종이
  Future<BookPaper?> _curlPaper(bool spread, bool fromRight, Size size) async {
    if (!_isOfflineDocument || _isTxt) return null;
    final cached = (_idleFrames != null && _idleShotKey == _curlShotKey()) ? _idleFrames! : null;
    final frames = cached ?? await _hwpController.pageFrames().timeout(const Duration(milliseconds: 300), onTimeout: () => const <Rect>[]);
    if (frames.isEmpty) return null;
    Rect px(Rect f) => Rect.fromLTWH(f.left * size.width, f.top * size.height, f.width * size.width, f.height * size.height);
    final pages = frames.map(px).toList();
    if (!spread) {
      final r = pages.first;
      return BookPaper(r, fromRight ? r.left : r.right);
    }
    // 두 쪽 보기: 책등은 두 쪽 사이 (한 쪽만 남은 마지막이면 그 쪽의 안쪽 가장자리)
    final double spine = pages.length >= 2
        ? (pages[0].right + pages[1].left) / 2
        : (pages[0].center.dx < size.width / 2 ? pages[0].right + 4 : pages[0].left - 4);
    final cand = pages.where((r) => fromRight ? r.center.dx > spine : r.center.dx < spine);
    if (cand.isEmpty) return null;
    return BookPaper(cand.first, spine);
  }


  // ── 글 고르기 ──
  final FloatingSelectionBar _pageBar = FloatingSelectionBar();

  // 워드·한글: 휴대폰 기본 글 선택은 여러 겹으로 놓인 글(한글은 SVG)에서 엉뚱한 곳부터 잡히고 튀어서,
  // 화면의 낱말 자리를 받아 앱이 직접 고름 (0.45초 누르면 낱말, 그대로 끌면 범위, 손잡이로 고침)
  final PageTextSelection _docSel = PageTextSelection();
  final GlobalKey _docSelKey = GlobalKey();
  Timer? _docPressTimer;
  bool _docPressSelecting = false;
  bool _docDownOnControls = false;

  bool get _docSelectable => _isOfflineDocument && !_isTxt && !_isSpreadsheet && !_isPresentation;

  Offset? _docLocal(Offset global) {
    final box = _docSelKey.currentContext?.findRenderObject() as RenderBox?;
    if (box == null || !box.hasSize) return null;
    return box.globalToLocal(global);
  }

  // 길게 누르기는 넘기기·스와이프 상태와 따로 셈 (그쪽 상태가 남아 있어도 글 고르기가 막히지 않게)
  Offset? _docPressAt;
  bool _docPressMoved = false;

  void _docSelDown(PointerDownEvent e) {
    _docPressTimer?.cancel();
    _docPressSelecting = false;
    _docPressMoved = false;
    _docPressAt = e.position;
    if (!_docSelectable || _isMemoMode || _isTouchLocked) return;
    final local = _docLocal(e.position);
    _docDownOnControls = local != null && _docSel.hitsControls(local);
    if (_docDownOnControls) return;
    final Offset at = e.position;
    _docPressTimer = Timer(const Duration(milliseconds: 450), () {
      if (!mounted || _docPressAt == null || _docPressMoved || _swipeActivePointers != 1 || _book.tracking) return;
      _docPressSelecting = true;
      _startDocSelect(at);
    });
  }

  Future<void> _startDocSelect(Offset global, {bool retry = true}) async {
    final box = _docSelKey.currentContext?.findRenderObject() as RenderBox?;
    if (box == null || !box.hasSize) return;
    final size = box.size;
    final raw = await _hwpController.visibleTextBoxes();
    if (!mounted) return;
    double v(Object? x) => (x as num?)?.toDouble() ?? 0;
    final words = <SelLine>[
      for (final b in raw)
        SelLine('${b['t'] ?? ''}', Rect.fromLTWH(v(b['x']) * size.width, v(b['y']) * size.height, v(b['w']) * size.width, v(b['h']) * size.height)),
    ];
    _docSel.lines = PageTextSelection.linesFromWords(words);
    final local = box.globalToLocal(global);
    if (_docSel.selectWordAt(local)) {
      HapticFeedback.selectionClick();
      return;
    }
    // 글 자리를 아직 못 받았으면 한 번 더 받아 봄
    if (retry) {
      await Future<void>.delayed(const Duration(milliseconds: 150));
      if (mounted) return _startDocSelect(global, retry: false);
    }
    _docPressSelecting = false;
  }

  /// 손을 떼지 않고 끌면 범위를 늘림 (스크롤 보기는 화면이 같이 움직이므로 손잡이로만)
  bool _docSelMove(PointerMoveEvent e) {
    final start = _swipeStartPos;
    final pressAt = _docPressAt;
    if (pressAt != null && (e.position - pressAt).distance > 12) _docPressMoved = true;
    if (_docPressSelecting) {
      final l = _docLocal(e.position);
      if (l != null && !_pageModeScroll && _docSel.active) _docSel.extendTo(l);
      return true;
    }
    if (_docPressMoved) _docPressTimer?.cancel();
    if (_docSel.active) {
      if (_docDownOnControls) return true; // 손잡이를 끄는 중
      // 다른 곳을 밀면(넘기기·스크롤) 고른 글은 지움
      if (start != null && (e.position - start).distance > 12) _docSel.clear();
    }
    return false;
  }

  void _docHighlight(List<Rect> rects) {
    final box = _docSelKey.currentContext?.findRenderObject() as RenderBox?;
    if (box == null || !box.hasSize) return;
    final s = box.size;
    _hwpController.highlightBoxes([for (final r in rects) Rect.fromLTWH(r.left / s.width, r.top / s.height, r.width / s.width, r.height / s.height)]);
  }

  /// EPUB [모두 선택]: 지금 보이는 쪽의 글 전체를 골라 [복사 | 공유] 막대를 띄움
  Future<void> _epubSelectAllPage() async {
    _clearEpubSelection();
    String text = '';
    try {
      text = (await _epubController.extractCurrentPageText()).text?.trim() ?? '';
    } catch (_) {}
    if (!mounted || text.isEmpty) return;
    final size = MediaQuery.sizeOf(context);
    _pageBar.show(
      context,
      Offset(size.width / 2, size.height * 0.3),
      tr: _tr,
      onCopy: () {
        _pageBar.hide();
        copyText(context, text, _tr);
      },
      onShare: () {
        _pageBar.hide();
        shareText(text);
      },
    );
  }

  /// 손가락이 가로로 끌리기 시작하면 책처럼 손가락을 따라 넘김
  void _bookTrackMove(PointerMoveEvent e) {
    if (_book.tracking) {
      _book.update(e.position);
      return;
    }
    final start = _swipeStartPos, t0 = _swipeStartTime;
    if (start == null || t0 == null || _book.busy || _docSel.active || _docPressSelecting) return;
    if (!_curlOn || _swipeMultiTouch || _swipeActivePointers != 1) return;
    if (_isTouchLocked || _epubZoomScale > 1.03 || _hasTextSelection) return;
    if (_isMemoMode && (_isStylusEvent(e) || _allowFingerDrawing)) return;
    final Offset d = e.position - start;
    // 옆으로 움직이기 시작하면 그때 지금 화면을 찍어 둠 (그냥 누르기만 할 때는 찍지 않아 배터리·버벅임 절약)
    if (_curlPre == null && d.dx.abs() >= 5 && d.dx.abs() > d.dy.abs()) _curlPrecapture();
    if (d.dx.abs() < 16 || d.dx.abs() < d.dy.abs() * 1.2) return;
    if (DateTime.now().difference(t0).inMilliseconds > 400) return; // 길게 눌러 끄는 건 글 선택
    final pre = _curlPre;
    _curlPre = null;
    _book.begin(start, e.position, pre, spread: _bookmarkSpreadNow);
  }

  /// 화면에 다른 것(메뉴·안내·고른 글 막대 등)이 덮여 있지 않아 보이는 그대로 찍어도 됨
  bool get _screenCleanForShot =>
      mounted &&
      !_showControls &&
      !(_tapGuide?.mounted ?? false) &&
      !_bgMenuOpen &&
      !_book.busy &&
      !_docSel.active &&
      !_hasTextSelection &&
      _activeStrokePoints.isEmpty &&
      !_findOpen &&
      _epubZoomScale <= 1.03;

  /// 문서 화면 자리에 보이는 그대로를 GPU로 복사 (책 화면을 다시 그리지 않아 화면이 멈추지 않음)
  Future<ui.Image?> _screenShot() async {
    if (_isTxt || !_screenCleanForShot) return null;
    try {
      // 편안한 모드의 덮개 색은 걷어내고 받음 (넘기는 그림 위에 덮개가 또 덮여 색이 진해지지 않게)
      final r = await _pdfChannel.invokeMethod<Map>('pixelCopyRaw', {'untint': ComfortTint.untint}).timeout(const Duration(milliseconds: 800));
      if (r == null || !mounted) return null;
      final int w = (r['w'] as num).toInt(), h = (r['h'] as num).toInt();
      final Uint8List px = r['px'] as Uint8List;
      if (w <= 0 || h <= 0 || px.length < w * h * 4) return null;
      final done = Completer<ui.Image>();
      ui.decodeImageFromPixels(px, w, h, ui.PixelFormat.rgba8888, done.complete);
      final img = await done.future.timeout(const Duration(milliseconds: 1000));
      // 이 기기에서 화면 복사가 안 되면 검은 그림이 나옴 → 예전 방법으로
      if (await BookCurlDrag.looksBlank(img)) {
        img.dispose();
        return null;
      }
      return img;
    } catch (_) {
      return null;
    }
  }

  /// [screen]: 넘기기 막이 아직 덮이지 않았을 때(손가락을 대기 전·가만히 읽는 중) 보이는 그대로 복사해도 됨
  Future<ui.Image?> _captureForCurl({bool screen = false}) async {
    if (screen) {
      final shot = await _screenShot();
      if (shot != null) return shot;
    }
    // 아래 방법들은 문서 화면만 찍혀 그 위에 그린 메모·책갈피가 빠짐 → 같은 자리에 그려 넣음
    final ui.Image? img = await _captureBookOnly();
    return img == null ? null : _withPageMarks(img);
  }

  Future<ui.Image?> _captureBookOnly() async {
    // 워드·한글·EPUB: 문서 화면의 화소를 압축 없이 그대로 받음 (빠르고, 종이 질감 위의 투명한 곳도 살아 있음)
    if (!_isTxt) {
      final raw = await _rawWebViewShot();
      if (raw != null) {
        if (_isOfflineDocument || !await BookCurlDrag.looksBlank(raw)) return raw;
        raw.dispose(); // EPUB은 네이티브 그리기로 빈 그림이 나올 때가 있어 아래 방법으로
      }
    }
    if (!_isOfflineDocument) {
      // EPUB: 책 화면(WebView)이 직접 찍은 그림
      try {
        final bytes = await _epubController.takeScreenshot().timeout(const Duration(milliseconds: 900));
        if (bytes != null && bytes.isNotEmpty && mounted) {
          final codec = await ui.instantiateImageCodec(bytes, targetWidth: (MediaQuery.sizeOf(context).width * MediaQuery.devicePixelRatioOf(context)).round());
          return (await codec.getNextFrame()).image;
        }
      } catch (_) {}
    }
    return _snapshotScreenFallback();
  }

  /// 책 화면 그림에 지금 쪽의 메모와 책갈피를 화면과 같은 자리에 그려 넣음
  /// (넘기는 종이에 메모가 찍혔다 안 찍혔다 하지 않게: 쪽을 막 넘겼으면 그 쪽 메모를 다 불러올 때까지 잠깐 기다림)
  Future<ui.Image> _withPageMarks(ui.Image img) async {
    try {
      await _memoLoading?.timeout(const Duration(milliseconds: 350));
    } catch (_) {}
    if (!mounted) return img;
    final stageBox = _book.layerKey.currentContext?.findRenderObject() as RenderBox?;
    if (stageBox == null || !stageBox.hasSize || stageBox.size.isEmpty) return img;
    final Size stage = stageBox.size;
    final List<MemoStroke> strokes = _memoStrokes;
    final bool ribbon = !_pageModeScroll && _isCurrentPageBookmarked && _epubZoomScale <= 1.03;
    if (strokes.isEmpty && !ribbon) return img;
    final rec = ui.PictureRecorder();
    final canvas = Canvas(rec);
    canvas.drawImage(img, Offset.zero, Paint());
    canvas.scale(img.width / stage.width, img.height / stage.height);
    if (strokes.isNotEmpty) {
      _MemoPainter(strokes: strokes, currentPoints: const [], currentColor: _penColor, currentWidth: _penWidth, map: _memoMap(stage)).paint(canvas, stage);
    }
    if (ribbon) {
      final Rect page = _ribbonPage(stage);
      paintBookmarkRibbon(canvas, Offset(page.left + math.min(18.0, page.width * 0.05), page.top));
    }
    final ui.Image out = await rec.endRecording().toImage(img.width, img.height);
    img.dispose();
    return out;
  }

  /// 마지막 방법: 지금 화면 그림 (TXT는 화면 그림, 그 밖은 책 화면을 직접 그림으로)
  Future<ui.Image?> _snapshotScreenFallback() async {
    try {
      if (_isTxt) {
        final boundary = _txtCaptureKey.currentContext?.findRenderObject() as RenderRepaintBoundary?;
        if (boundary == null) return null;
        return await boundary.toImage(pixelRatio: MediaQuery.devicePixelRatioOf(context));
      }
      final bytes = await _pdfChannel.invokeMethod<Uint8List>(
        'snapshotWebView',
        {'background': _isPaperTheme ? 0 : _getBgColor().toARGB32(), 'scale': 1.0},
      );
      if (bytes == null) return null;
      final codec = await ui.instantiateImageCodec(bytes);
      return (await codec.getNextFrame()).image;
    } catch (_) {
      return null;
    }
  }


  Future<ui.Image?> _rawWebViewShot() async {
    try {
      final r = await _pdfChannel
          .invokeMethod<Map>('snapshotWebViewRaw', {'background': _isPaperTheme ? 0 : _getBgColor().toARGB32()})
          .timeout(const Duration(milliseconds: 1500));
      if (r == null) return null;
      final int w = (r['w'] as num).toInt(), h = (r['h'] as num).toInt();
      final Uint8List px = r['px'] as Uint8List;
      if (w <= 0 || h <= 0 || px.length < w * h * 4) return null;
      final done = Completer<ui.Image>();
      ui.decodeImageFromPixels(px, w, h, ui.PixelFormat.rgba8888, done.complete);
      return await done.future.timeout(const Duration(milliseconds: 1500));
    } catch (_) {
      return null;
    }
  }

  /// 손가락이 닿으면 미리 지금 화면을 찍어 둠 (종이처럼 넘기기가 켜져 있을 때만)
  void _curlPrecapture() {
    if (!_curlOn || _book.busy) return;
    final old = _curlPre;
    final shot = _idleShot;
    // 미리 찍어 둔 지금 쪽이 있으면 바로 씀 (찍는 동안 기다리지 않음)
    final key = _curlShotKey();
    _curlPre = (shot != null && _idleShotKey == key)
        ? Future<ui.Image?>.value(shot.clone())
        : _captureForCurl(screen: true).then((img) {
            // 새로 찍은 지금 쪽도 보관 (되돌아올 때 쓸 그림의 자리를 적는 데도 씀)
            if (img != null && mounted && key == _curlShotKey()) _setIdleShot(img.clone(), key, null);
            return img;
          });
    old?.then((i) => i?.dispose());
  }

  /// 손가락으로 끌지 않고 빠르게 밀었을 때: 한 번에 책처럼 넘김
  void _curlTurn(double dx) {
    final pre = _curlPre;
    _curlPre = null;
    if (_book.busy || !mounted) {
      pre?.then((i) => i?.dispose());
      return;
    }
    final size = MediaQuery.sizeOf(context);
    _book.autoTurn(dx, pre, Offset(dx < 0 ? size.width * 0.9 : size.width * 0.1, size.height * 0.8), spread: _bookmarkSpreadNow);
  }

  /// 본문 + 책처럼 넘기기 막 + (워드·한글) 글 고르기 막
  // EPUB 메모 자리 이름: 쪽 첫 CFI (없으면 진행률)
  String _computeLocationKey(String? cfi, double prog) {
    if (cfi != null && cfi.trim().isNotEmpty) {
      return cfi.trim();
    }
    return 'prog_${(prog * 1000).round()}';
  }

  /// 메모를 쪽에 붙이는 문서 (워드·한글·PPT 넘겨 보기)
  bool get _memoPageAnchored => _isOfflineDocument && !_isTxt && !_isSpreadsheet && !_pageModeScroll;

  /// 메모 보기 이름. 문서(넘겨 보기)는 'view:쪽|2p|r' — 실제 저장은 쪽마다 ('pg:쪽')라 한 쪽·두 쪽 보기,
  /// 가로·세로 어디서 보든 같은 메모가 글자 위 같은 자리에 보임 (삼성 노트처럼).
  /// EPUB·TXT는 쪽 위치 + 두 쪽 보기('|2p') + (글이 다시 흐르므로) 가로 화면('|L')
  String _memoKeyFor(String base) {
    if (!mounted) return base;
    final size = MediaQuery.sizeOf(context);
    if (_memoPageAnchored) {
      final m = RegExp(r':(\d+)$').firstMatch(base);
      if (m != null) {
        final bool spread = _bookmarkSpreadNow;
        return 'view:${m.group(1)}${spread ? '|2p' : ''}${spread && _isMangaRtlMode ? '|r' : ''}';
      }
    }
    String k = base;
    if (!_pageModeScroll && _bookmarkSpreadNow) k += '|2p';
    if ((_isEpub || _isTxt) && size.width > size.height) k += '|L';
    return k;
  }

  static final RegExp _viewKeyRe = RegExp(r'^view:(\d+)(\|2p)?(\|r)?$');

  /// 'view:…' 보기에 보이는 쪽들 (화면 왼쪽부터)과 그 크기
  (List<int>, List<Size>)? _viewPagesOf(String key) {
    final m = _viewKeyRe.firstMatch(key);
    if (m == null) return null;
    final int p = int.parse(m.group(1)!);
    final List<int> pages = [p, if (m.group(2) != null && (_docPageCount <= 0 || p + 1 < _docPageCount)) p + 1];
    final List<int> order = m.group(3) != null ? pages.reversed.toList() : pages;
    Size sizeOf(int i) {
      final s = _docPageSizes;
      final Size z = (s != null && i >= 0 && i < s.length) ? s[i] : Size.zero;
      return (z.width > 0 && z.height > 0) ? z : const Size(1, 1.414);
    }

    return (order, [for (final i in order) sizeOf(i)]);
  }

  /// 메모 읽기: 문서 보기는 보이는 쪽들의 메모를 모아 보기 좌표로
  Future<List<MemoStroke>> _getMemo(String key) async {
    final v = _viewPagesOf(key);
    if (v == null) return StorageService.getLocationStrokes(widget.filePath, key);
    final (pages, sizes) = v;
    final double sumW = sizes.fold(0.0, (a, z) => a + z.width), maxH = sizes.map((z) => z.height).reduce(math.max);
    final out = <MemoStroke>[];
    double o = 0;
    for (int i = 0; i < pages.length; i++) {
      final double w = sizes[i].width, h = sizes[i].height;
      for (final s in await StorageService.getLocationStrokes(widget.filePath, 'pg:${pages[i]}')) {
        out.add(MemoStroke(
          dxList: [for (final x in s.dxList) (o + x * w) / sumW],
          dyList: [for (final y in s.dyList) y * h / maxH],
          colorValue: s.colorValue,
          strokeWidth: s.strokeWidth < 0.5 ? s.strokeWidth * w / sumW : s.strokeWidth,
        ));
      }
      o += w;
    }
    return out;
  }

  /// 메모 저장: 문서 보기는 획마다 시작한 쪽에 그 쪽 좌표로 나눠 저장
  Future<void> _saveMemo(String key, List<MemoStroke> strokes) async {
    final v = _viewPagesOf(key);
    if (v == null) return StorageService.saveLocationStrokes(widget.filePath, key, strokes);
    final (pages, sizes) = v;
    final double sumW = sizes.fold(0.0, (a, z) => a + z.width), maxH = sizes.map((z) => z.height).reduce(math.max);
    final List<List<MemoStroke>> per = [for (final _ in pages) <MemoStroke>[]];
    for (final s in strokes) {
      if (s.dxList.isEmpty) continue;
      final double vx = s.dxList.first * sumW;
      int i = 0;
      double o = 0;
      for (; i < pages.length - 1; i++) {
        if (vx < o + sizes[i].width) break;
        o += sizes[i].width;
      }
      final double w = sizes[i].width, h = sizes[i].height;
      per[i].add(MemoStroke(
        dxList: [for (final x in s.dxList) (x * sumW - o) / w],
        dyList: [for (final y in s.dyList) y * maxH / h],
        colorValue: s.colorValue,
        strokeWidth: s.strokeWidth < 0.5 ? s.strokeWidth * sumW / w : s.strokeWidth,
      ));
    }
    for (int i = 0; i < pages.length; i++) {
      await StorageService.saveLocationStrokes(widget.filePath, 'pg:${pages[i]}', per[i]);
    }
  }

  /// 보기 방식·화면 방향이 바뀌면 그 보기의 메모로 바꿔 보여 줌. 화면 크기가 바뀌면 쪽 네모도 다시 받음
  void _queueMemoSync() {
    if (_memoSyncQueued) return;
    _memoSyncQueued = true;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _memoSyncQueued = false;
      if (!mounted) return;
      _syncScrollMarks();
      final Size size = MediaQuery.sizeOf(context);
      if (_framesForSize != size && _memoPageAnchored) {
        _framesForSize = size;
        _framesTimer?.cancel();
        _framesTimer = Timer(const Duration(milliseconds: 300), _refreshPageFrames);
      }
      final String k = _memoKeyFor(_memoBase);
      if (k == _currentPageLocationKey) return;
      _currentPageLocationKey = k;
      final int seq = ++_memoLoadSeq;
      setState(() {
        _memoStrokes = [];
        _activeStrokePoints.clear();
      });
      _getMemo(k).then((strokes) {
        if (mounted && seq == _memoLoadSeq && k == _currentPageLocationKey) setState(() => _memoStrokes = strokes);
      });
    });
  }

  /// 문서 화면의 쪽 자리를 다시 받음 (쪽이 다 그려졌을 때·화면 크기가 바뀐 뒤)
  Future<void> _refreshPageFrames() async {
    if (!_isOfflineDocument || _isTxt || _isSpreadsheet) return;
    // 쪽 자리는 확대하지 않은 화면에서만 잼 (확대 중 값은 메모·책갈피 자리를 틀리게 함)
    if (_epubZoomScale > 1.03 || !_docViewNone) return;
    final int seq = ++_framesSeq;
    final f = await _hwpController.pageSlots().timeout(const Duration(milliseconds: 500), onTimeout: () => const <DocPageSlot>[]);
    if (!mounted || seq != _framesSeq || f.isEmpty) return;
    final stageBox = _book.layerKey.currentContext?.findRenderObject() as RenderBox?;
    setState(() {
      _pageSlots = f;
      _fracsStage = stageBox != null && stageBox.hasSize ? stageBox.size : null;
    });
  }

  /// 책 화면 크기 [stage]에서의 쪽 자리들 (px, 화면 왼쪽부터, 실제 쪽만): (보이는 자리, 쪽 전체 자리).
  /// 화면을 돌려 크기가 바뀌었으면 문서가 다시 재 주기를 기다리지 않고 문서와 같은 규칙
  /// (여백 줄이기 네모가 화면에 꽉 차게, 가운데, 쪽 사이 8/3)으로 바로 계산 → 메모·책갈피가 늦게 따라오지 않음
  (List<Rect>, List<Rect>)? _layoutFor(Size stage) {
    final f = _pageSlots, old = _fracsStage;
    if (f == null || f.isEmpty || old == null || old.isEmpty) return null;
    Rect px(Rect r, Size z) => Rect.fromLTWH(r.left * z.width, r.top * z.height, r.width * z.width, r.height * z.height);
    final List<int> order = List<int>.generate(f.length, (i) => i)..sort((a, b) => f[a].frame.left.compareTo(f[b].frame.left));
    final frames = <Rect>[], pages = <Rect>[];
    if ((old.width - stage.width).abs() < 0.5 && (old.height - stage.height).abs() < 0.5) {
      for (final i in order) {
        if (!f[i].real) continue;
        frames.add(px(f[i].frame, stage));
        pages.add(px(f[i].page, stage));
      }
      return frames.isEmpty ? null : (frames, pages);
    }
    const double gap = 8 / 3;
    final int n = f.length;
    final List<double> w = [for (final e in f) e.page.width * old.width], h = [for (final e in f) e.page.height * old.height];
    final List<double> bw = [for (int i = 0; i < n; i++) f[i].box.width * w[i]], bh = [for (int i = 0; i < n; i++) f[i].box.height * h[i]];
    final double sumBw = bw.fold(0.0, (a, b) => a + b), maxBh = bh.reduce(math.max);
    if (sumBw <= 0 || maxBh <= 0) return null;
    final bool trimming = f.any((e) => e.box.width < 0.999 || e.box.height < 0.999);
    final double pad = trimming ? 0.96 : 1;
    final double availW = stage.width - gap * (n - 1), availH = stage.height;
    final double k = math.max(0.0001, math.min(availW * pad / sumBw, availH * pad / maxBh));
    double clamp(double v, double lo) => math.min(0, math.max(lo, v));
    final List<double> slotW = [for (int i = 0; i < n; i++) math.min(w[i] * k, availW * bw[i] / sumBw)];
    double x = (stage.width - (slotW.fold(0.0, (a, b) => a + b) + gap * (n - 1))) / 2;
    for (final i in order) {
      final double sw = slotW[i], sh = math.min(h[i] * k, availH);
      final double tx = clamp((sw - bw[i] * k) / 2 - f[i].box.left * w[i] * k, sw - w[i] * k);
      final double ty = clamp((sh - bh[i] * k) / 2 - f[i].box.top * h[i] * k, sh - h[i] * k);
      final double top = (stage.height - sh) / 2;
      if (f[i].real) {
        frames.add(Rect.fromLTWH(x, top, sw, sh));
        pages.add(Rect.fromLTWH(x + tx, top + ty, w[i] * k, h[i] * k));
      }
      x += sw + gap;
    }
    return frames.isEmpty ? null : (frames, pages);
  }

  /// 메모 좌표 자리 (책 화면 안 좌표): 문서는 보이는 쪽들 (쪽 전체 크기 기준), 그 밖은 책 화면 전체.
  /// 확대·이동한 만큼 함께 옮김 (삼성 노트처럼 메모가 쪽에 붙어 같이 커지고 움직임)
  _MemoMap _memoMap(Size stage) {
    // 한글·워드·PPT는 문서가 실제로 그려 보여 주는 확대를 따라 (글과 메모가 같은 순간에 움직이게)
    final Matrix4 m = _docLiveZoom ? _docShownView.value : _epubZoomController.value;
    final bool moved = (m.getMaxScaleOnAxis() - 1).abs() >= 0.001 || m.getTranslation().length2 >= 0.01;
    final l = _memoPageAnchored ? _layoutFor(stage) : null;
    if (l != null && l.$2.every((r) => r.width > 4 && r.height > 4)) {
      return _MemoMap(l.$2, l.$1, transform: moved ? m : null);
    }
    return _MemoMap.rect(Offset.zero & stage, transform: moved ? m : null);
  }

  /// [_memoMap]을 메모 그리는 층(화면 전체) 좌표로
  _MemoMap _memoMapInLayer(Size layerSize) {
    final stageBox = _book.layerKey.currentContext?.findRenderObject() as RenderBox?;
    final layerBox = _memoLayerKey.currentContext?.findRenderObject() as RenderBox?;
    if (stageBox == null || layerBox == null || !stageBox.attached || !layerBox.attached || !stageBox.hasSize || !layerBox.hasSize) {
      return _MemoMap.rect(Offset.zero & layerSize);
    }
    return _memoMap(stageBox.size).shifted(layerBox.globalToLocal(stageBox.localToGlobal(Offset.zero)));
  }

  /// 책갈피를 다는 쪽 (책 화면 안 좌표): 문서는 왼쪽 쪽의 보이는 자리, 그 밖은 책 화면
  Rect _ribbonPage(Size stage) {
    final l = (_isOfflineDocument && !_isTxt && !_pageModeScroll) ? _layoutFor(stage) : null;
    if (l != null) return l.$1.first; // 화면 왼쪽 쪽 (우→좌 읽기여도)
    return Offset.zero & stage;
  }

  Widget _curlStage(Widget content) {
    _queueMemoSync();
    return Stack(
      fit: StackFit.expand,
      clipBehavior: Clip.none,
      children: [
        content,
        // 저장된 메모: 넘기는 종이 밑 (넘길 때 함께 넘어가고, 새 쪽 메모는 드러나는 만큼만 보임)
        if (_memoStrokes.isNotEmpty)
          Positioned.fill(
            child: IgnorePointer(
              child: LayoutBuilder(
                builder: (context, box) => AnimatedBuilder(
                  animation: Listenable.merge([_epubZoomController, _docShownView]), // 확대·이동하면 메모도 함께
                  builder: (context, _) => CustomPaint(
                    size: Size.infinite,
                    painter: _MemoPainter(
                      strokes: _memoStrokes,
                      currentPoints: const [],
                      currentColor: _penColor,
                      currentWidth: _penWidth,
                      map: _memoMap(box.biggest),
                    ),
                  ),
                ),
              ),
            ),
          ),
        // 북마크한 쪽: 쪽 왼쪽 위에 책갈피 (두 쪽 보기는 왼쪽 쪽에만)
        if (!_pageModeScroll && _isCurrentPageBookmarked && _epubZoomScale <= 1.03)
          Positioned.fill(
            child: IgnorePointer(
              child: LayoutBuilder(builder: (context, box) {
                final Rect page = _ribbonPage(box.biggest);
                return Stack(clipBehavior: Clip.none, children: [
                  // 쪽 테두리 안쪽 (테두리 위로 넘어가지 않게)
                  Positioned(left: page.left + math.min(18.0, page.width * 0.05), top: page.top, child: const BookmarkRibbon()),
                ]);
              }),
            ),
          ),
        Positioned.fill(
          child: BookCurlLayer(
            drag: _book,
            // 넘어가는 종이 뒷면·빈 곳 색: 지금 보는 배경색 (세피아면 세피아. 앱이 다크여도 검게 보이지 않게)
            paper: _getBgColor(),
            texture: _isPaperTheme ? BookCurlLayer.paperTexture(() => mounted ? setState(() {}) : null) : null,
            // 한 쪽 보기 종이 뒷면: 파일 안 테마를 따름 (라이트 = 흰 종이, 다크 = 검은 종이, 세피아 = 종이 질감)
            backside: _epubBgTheme == 'dark' ? _getBgColor() : (_isPaperTheme ? null : Colors.white),
            textureKey: _epubBodyKey,
            keepOverlay: _curlOn && !_isTxt,
          ),
        ),
        // 워드·한글: 길게 눌러 고른 글 — 바탕·손잡이·[복사 | 모두 선택 | 공유 | 형광펜] 막대
        if (_docSelectable)
          Positioned.fill(
            child: SizedBox.expand(
              key: _docSelKey,
              child: PageTextSelectLayer(sel: _docSel, tr: _tr, onHighlight: _docHighlight),
            ),
          ),
      ],
    );
  }

  // ── 스와이프 페이지 넘김 보강 ──
  // WebView(epub.js)의 스와이프 인식은 (1) 빠른 튕김은 위쪽 확대 제스처에 빼앗기고,
  // (2) 손가락이 세로로 50px 이상 흔들리면 무시된다. 이 두 경우만 Flutter가 직접 넘겨
  // 한 번의 스와이프에 한 페이지만 넘어가도록 한다.
  int _swipeActivePointers = 0;
  bool _swipeMultiTouch = false;
  bool _swipeHandledByDrag = false;
  bool _swipeScaleStarted = false;
  Offset? _swipeStartPos;
  DateTime? _swipeStartTime;
  DateTime? _swipeFirstMoveTime;
  double _flickDx = 0.0;
  bool _hasTextSelection = false;

  bool get _swipeFlutterOwned =>
      !_isSpreadsheet && _useSwipeTurn && !_isTouchLocked && _epubZoomScale <= 1.03;

  bool _isStylusEvent(PointerEvent e) =>
      e.kind == PointerDeviceKind.stylus || e.kind == PointerDeviceKind.invertedStylus;

  void _swipeTrackDown(PointerDownEvent e) {
    if (_isSpreadsheet) return;
    if (_isMemoMode && _isStylusEvent(e)) return;
    _swipeActivePointers++;
    if (_swipeActivePointers == 1) {
      _docSelDown(e);
      // 지난 손동작에서 찍어 두고 쓰지 않은 그림은 버림 (새 그림은 손가락이 옆으로 움직이기 시작할 때 찍음)
      final stale = _curlPre;
      _curlPre = null;
      stale?.then((i) => i?.dispose());
      _swipeMultiTouch = false;
      _swipeHandledByDrag = false;
      _swipeScaleStarted = false;
      _swipeStartPos = e.position;
      _swipeStartTime = DateTime.now();
      _swipeFirstMoveTime = null;
    } else {
      _swipeMultiTouch = true;
      _docPressTimer?.cancel();
      if (_book.tracking) _book.end(cancel: true); // 두 손가락: 넘기기 취소
    }
  }

  void _swipeTrackMove(PointerMoveEvent e) {
    if (_docSelMove(e)) return; // 글 고르는 중: 넘기지 않음
    _bookTrackMove(e);
    final start = _swipeStartPos;
    if (start == null || _swipeFirstMoveTime != null) return;
    if ((e.position - start).distance > 12.0) {
      _swipeFirstMoveTime = DateTime.now();
    }
  }

  void _swipeTrackUp(PointerEvent e, {bool cancelled = false}) {
    if (_isSpreadsheet) return;
    if (_isMemoMode && _isStylusEvent(e)) return;
    if (_swipeActivePointers > 0) _swipeActivePointers--;
    if (_swipeActivePointers > 0) return;

    final start = _swipeStartPos;
    final startTime = _swipeStartTime;
    _swipeStartPos = null;
    _swipeStartTime = null;
    _docPressTimer?.cancel();
    _docPressAt = null;
    if (_docPressSelecting || _docDownOnControls) {
      // 길게 눌러 고른 뒤 손을 뗌 / 손잡이를 놓음: 넘기지 않음
      _docPressSelecting = false;
      _docDownOnControls = false;
      return;
    }
    if (_book.tracking) {
      // 책처럼 넘기는 중: 손을 뗀 곳에 따라 넘기거나 되돌림
      _book.end(cancel: cancelled || _swipeMultiTouch);
      return;
    }
    if (cancelled || start == null || startTime == null) return;
    if (_swipeMultiTouch || _swipeHandledByDrag) return;
    if (_isTouchLocked || _epubZoomScale > 1.03 || _hasTextSelection) return;

    // 길게 누른 뒤 끄는 동작(문장 선택 등)은 스와이프로 보지 않음
    final int holdMs = (_swipeFirstMoveTime ?? DateTime.now()).difference(startTime).inMilliseconds;
    if (holdMs > 400) return;

    final Offset d = e.position - start;
    final double adx = d.dx.abs();
    final double ady = d.dy.abs();

    if (!_useSwipeTurn) return;
    final bool isSwipe = adx >= 40.0 && adx > ady * 1.2;
    if (!isSwipe) return;

    if (_isOfflineDocument) {
      // TXT·워드·한글 화면은 스스로 스와이프를 처리하지 않으므로 항상 여기서 넘긴다
      _turnBySwipeDirection(d.dx);
      return;
    }
    if (_curlOn) {
      // 종이처럼 넘기기: EPUB도 책 화면 스스로 넘기지 않고 여기서 말아 넘김
      _turnBySwipeDirection(d.dx);
      return;
    }
    if (_swipeScaleStarted) {
      // 확대 제스처가 터치를 가져가 WebView가 못 받은 스와이프
      _turnBySwipeDirection(d.dx);
      return;
    }
    // WebView가 받은 스와이프: epub.js 기준(가로 50px 초과 & 세로 흔들림 50px 미만)을 통과하면
    // epub.js가 넘기므로 건드리지 않고, 기준에 걸려 무시되는 경우만 대신 넘긴다. 경계값 근처는 중복 방지를 위해 보류.
    final bool jsWouldTurn = adx > 55.0 && ady < 45.0;
    final bool nearJsBoundary = (adx > 45.0 && adx <= 55.0) || (ady >= 45.0 && ady < 55.0 && adx > 55.0);
    if (!jsWouldTurn && !nearJsBoundary) {
      _turnBySwipeDirection(d.dx);
    }
  }

  /// EPUB에서 길게 눌러 고른 글의 선택 표시를 지움
  void _clearEpubSelection() {
    _hasTextSelection = false;
    _selectedText = '';
    try {
      if (!_isOfflineDocument) _epubController.clearSelection();
    } catch (_) {}
  }

  // 왼쪽으로 밀면 다음, 오른쪽으로 밀면 이전. 읽기 방향이 우→좌(세로쓰기 책·만화)면 반대로
  void _turnBySwipeDirection(double dx) {
    _hasTextSelection = false;
    setState(() => _activeStrokePoints.clear());
    if (_curlOn) {
      _curlTurn(dx);
      return;
    }
    if ((dx < 0) != _isMangaRtlMode) {
      _readerNext();
    } else {
      _readerPrevious();
    }
  }

  void _onFlickStart(DragStartDetails details) {
    _swipeHandledByDrag = true;
    _flickDx = 0.0;
  }

  void _onFlickUpdate(DragUpdateDetails details) {
    _flickDx += details.primaryDelta ?? details.delta.dx;
  }

  void _onFlickEnd(DragEndDetails details) {
    if (_swipeMultiTouch || _hasTextSelection) return;
    final double vx = details.velocity.pixelsPerSecond.dx;
    if (vx.abs() >= 300.0) {
      _turnBySwipeDirection(vx);
    } else if (_flickDx.abs() >= 30.0) {
      _turnBySwipeDirection(_flickDx);
    }
  }

  void _handlePointerDown(PointerDownEvent event) {
    if (_isTouchLocked) return;
    if (_isMemoMode &&
        (event.kind == PointerDeviceKind.stylus ||
            event.kind == PointerDeviceKind.invertedStylus)) {
      if (!_isStylusDown) {
        setState(() => _isStylusDown = true);
      }
      return;
    }
    // 이미 다른 손가락이 닿아 있으면(두 손가락) 그 동작은 탭이 아님
    if (_pointerDownPosition != null && _pointerDownTime != null && _tapPointers > 0) {
      _swipeMultiTouch = true;
    }
    _tapPointers++;
    _pointerDownPosition = event.position;
    _pointerDownTime = DateTime.now();
  }
  int _tapPointers = 0;

  void _handlePointerUp(PointerUpEvent event, Size screenSize) {
    if (_tapPointers > 0) _tapPointers--;
    // 두 손가락 중 하나를 먼저 뗀 경우: 나머지를 뗄 때까지 기다림 (탭으로 처리하지 않음)
    if (_tapPointers > 0) return;
    if (_isStylusDown &&
        (event.kind == PointerDeviceKind.stylus ||
            event.kind == PointerDeviceKind.invertedStylus)) {
      setState(() => _isStylusDown = false);
      return;
    }
    if (_isTouchLocked || _pointerDownPosition == null || _pointerDownTime == null) return;
    if (_isMemoMode &&
        (event.kind == PointerDeviceKind.stylus ||
            event.kind == PointerDeviceKind.invertedStylus)) {
      return;
    }
    final distance = (event.position - _pointerDownPosition!).distance;
    final duration = DateTime.now().difference(_pointerDownTime!).inMilliseconds;

    // 그림 위에서 글을 골라 둔 상태: 탭은 메뉴를 열지 않고 고른 글만 지움 (복사 버튼은 먼저 처리됨)
    // 워드·한글에서 글을 골라 둔 상태 / 모두 선택 막대: 탭은 메뉴를 열지 않고 고른 것만 지움
    if (_docSel.active || _pageBar.shown) {
      final local = _docLocal(event.position);
      if (distance < 24.0 && duration < 380 && !(local != null && _docSel.hitsControls(local))) {
        _docSel.clear();
        _pageBar.hide();
        _docPressSelecting = false;
        _docDownOnControls = false;
      }
      _pointerDownPosition = null;
      _pointerDownTime = null;
      return;
    }
    if (WordSelectionLayer.active.value) {
      if (distance < 24.0 && duration < 380 && !WordSelectionLayer.containsGlobal(event.position)) {
        WordSelectionLayer.clearAll();
      }
      _pointerDownPosition = null;
      _pointerDownTime = null;
      return;
    }
    // PPT: 길게 누르면 지금 쪽의 글을 고르고 복사하는 창 (한글·워드·EPUB·TXT는 글을 직접 길게 눌러 고름)
    if (distance < 18.0 && duration >= 550 && _isPresentation && !_isMemoMode && !_slideShow) {
      HapticFeedback.selectionClick();
      _openTextCopySheet();
      _pointerDownPosition = null;
      _pointerDownTime = null;
      return;
    }
    // 두 손가락(확대·축소)을 쓴 동작은 탭으로 보지 않음
    final bool multiTouch = _swipeMultiTouch || _tapPointers > 0;
    // 엑셀: 길게 눌러 골라 둔 칸이 있으면 이번 누름은 그 표시만 지움 (메뉴는 그대로)
    if (_isSpreadsheet && _hwpController.cellSelected && distance < 24.0 && duration < 380 && !multiTouch) {
      _hwpController.cellSelected = false;
      _pointerDownPosition = null;
      _pointerDownTime = null;
      return;
    }
    if (distance < 24.0 && duration < 380 && !multiTouch) {
      if (_hasTextSelection && !_isOfflineDocument) {
        // 글이 선택된 상태에서 화면을 누르면 선택 표시만 지움
        _clearEpubSelection();
      } else {
        _tapOrDoubleTap(event.position);
      }
    }
    _pointerDownPosition = null;
    _pointerDownTime = null;
  }

  // 확대·축소한 화면을 빠르게 두 번 누르면 원래 크기로 (확대·축소돼 있을 때만 한 번 누름을 잠깐 기다려 봄)
  // 스크롤 보기도 모두: EPUB·TXT·한글·워드(문서가 직접 확대·축소)
  Timer? _tapTimer;
  DateTime? _lastTapAt;
  Offset _lastTapPos = Offset.zero;
  bool get _anyZoomed => _epubZoomScale > 1.03 || _scrollCtrl.zoomed || (_docVertical && (_hwpController.scrollZoom - 1).abs() > 0.01);

  void _resetAnyZoom() {
    if (_epubZoomScale > 1.0001) {
      _epubZoomController.value = Matrix4.identity();
      setState(() => _epubZoomScale = 1.0);
    }
    _scrollCtrl.resetZoom();
    if (_docVertical && (_hwpController.scrollZoom - 1).abs() > 0.01) _hwpController.resetScrollZoom();
  }

  void _tapOrDoubleTap(Offset pos) {
    final now = DateTime.now();
    if (_tapTimer != null && _lastTapAt != null && now.difference(_lastTapAt!).inMilliseconds < 320 && (pos - _lastTapPos).distance < 60) {
      _tapTimer!.cancel();
      _tapTimer = null;
      _lastTapAt = null;
      HapticFeedback.selectionClick();
      _resetAnyZoom();
      return;
    }
    if (!_anyZoomed) {
      _onReaderTap(pos);
      return;
    }
    _lastTapAt = now;
    _lastTapPos = pos;
    _tapTimer?.cancel();
    _tapTimer = Timer(const Duration(milliseconds: 300), () {
      _tapTimer = null;
      if (mounted) _onReaderTap(pos);
    });
  }

  /// 화면을 한 번 눌렀을 때: 탭 모드면 위쪽은 메뉴, 아래 왼쪽·오른쪽은 이전·다음 쪽
  /// (메뉴가 떠 있거나 필기 중이면 메뉴만 닫음. '이전'·'다음' 칸은 읽기 방향과 상관없이 그대로)
  void _onReaderTap(Offset global) {
    if (!_pageModeTap || _showControls || _isMemoMode || _slideShow) {
      _toggleControls();
      return;
    }
    switch (tapZoneAt(uiScaledPosition(context, global), MediaQuery.sizeOf(context))) {
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
      // 스크롤 모드: 원래 순서대로 한 화면씩 (TXT는 쪽 목록, 한글·워드·EPUB은 문서 화면이 직접 굴림)
      if (_docScrollActive) {
        _scrollCtrl.scrollByScreen(dir);
      } else if (dir > 0) {
        _readerNext();
      } else {
        _readerPrevious();
      }
      return;
    }
    if (dir > 0) {
      _turnNext();
    } else {
      _turnPrev();
    }
  }

  Color _getBgColor() {
    if (_epubBgTheme == 'dark') return const Color(0xFF1E1E1E);
    if (_epubBgTheme == 'sepia') return const Color(0xFFFBF0D9);
    return const Color(0xFFFFFFFF);
  }

  Color _getFgColor() {
    if (_epubBgTheme == 'dark') return const Color(0xFFD4D4D4);
    if (_epubBgTheme == 'sepia') return const Color(0xFF3B2F2F);
    return const Color(0xFF000000);
  }

  EpubTheme _buildTheme() {
    // 종이색: 화면 뒤에 종이 질감 그림을 깔고 책 바탕은 투명하게
    final String cssBg = _epubBgTheme == 'dark'
        ? '#1E1E1E'
        : (_epubBgTheme == 'sepia' ? 'transparent' : '#FFFFFF');
    final String cssFg = _epubBgTheme == 'dark'
        ? '#D4D4D4'
        : (_epubBgTheme == 'sepia' ? '#3B2F2F' : '#000000');

    return EpubTheme.custom(
      backgroundDecoration: _isPaperTheme ? null : BoxDecoration(color: _getBgColor()),
      foregroundColor: _getFgColor(),
      customCss: {
        // 책 자체 CSS가 html에 여백을 주면 쪽(단) 경계가 어긋나 글이 두 쪽에 걸쳐 보인다 → 여백 제거
        'html': {
          'padding': '0 !important',
          'margin': '0 !important',
        },
        ':root, html, body': {
          'color-scheme': _epubBgTheme == 'dark' ? 'dark !important' : 'light !important',
          'background': '$cssBg !important',
          'background-color': '$cssBg !important',
          'color': '$cssFg !important',
        },
        'p, div, section, article, span, main, h1, h2, h3, h4, h5, h6, li, td, th, blockquote': {
          'background-color': 'transparent !important',
          'color': '$cssFg !important',
          'word-break': 'keep-all',
          // 글자를 크게 해서 한 단어(띄어쓰기 없는 긴 글)가 쪽 너비보다 길어지면 그때만 줄을 바꿈 (옆 쪽으로 넘치지 않게)
          'overflow-wrap': 'break-word',
          'line-height': '1.75',
          'text-align': 'justify',
        },
        // 책 화면 위 여백: 기본 20 → 8 (첫 줄이 위쪽에서 바로 시작하게)
        'html body': {
          'padding-top': '8px !important',
        },
        'pre, code': {
          'white-space': 'pre-wrap !important',
          'overflow-wrap': 'anywhere',
        },
        'img, svg, video, table': {
          'max-width': '100% !important',
        },
        '::selection': {
          'background': 'rgba(255, 215, 0, 0.35)',
        },
        // 사용자가 고른 EPUB 글꼴 (앱 저장소의 글꼴 파일을 같은 주소에서 읽음)
        if (_epubFont != null) ...{
          '@font-face': {
            'font-family': "'FReaderEpubFont'",
            'src': "url('https://appassets.androidplatform.net/userfonts/${_epubFont!.file}')",
          },
          'body, p, div, section, article, span, main, h1, h2, h3, h4, h5, h6, li, td, th, blockquote, a, em, strong, b, i': {
            'font-family': "'FReaderEpubFont' !important",
          },
        },
      },
    );
  }

  /// 파일 안 '편안한 모드': 화면 전체(상단바·목차 포함) 위에 앱의 편안한 모드와 같은 따뜻한 색
  Widget _withDocComfort(Widget child) {
    if (!_docComfort) return child;
    return Stack(
      fit: StackFit.expand,
      children: [
        child,
        const Positioned.fill(child: IgnorePointer(child: ColoredBox(color: ComfortTint.color))),
      ],
    );
  }

  /// 상단바 달 모양: EPUB은 라이트·다크·세피아, 다른 파일은 라이트·다크·편안한 모드 중 고르기
  Future<void> _pickBgTheme(BuildContext btnCtx) async {
    final box = btnCtx.findRenderObject() as RenderBox?;
    final overlay = Overlay.of(context).context.findRenderObject() as RenderBox?;
    if (box == null || overlay == null) return;
    final Offset tl = box.localToGlobal(Offset.zero, ancestor: overlay);
    setState(() => _bgMenuOpen = true);
    // 꾹 눌러 뜨는 메뉴와 같은 움직임: 누른 단추에서 커져 나옴
    final picked = await Navigator.of(context).push<String>(GroupJumpMenuRoute<String>(
      anchor: tl & box.size,
      barrierLabel: MaterialLocalizations.of(context).modalBarrierDismissLabel,
      selected: _docComfort ? 'comfort' : _epubBgTheme,
      items: [
        ('white', _tr('라이트', 'Light', '浅色', 'ライト'), Icons.light_mode_outlined, null),
        ('dark', _tr('다크', 'Dark', '深色', 'ダーク'), Icons.dark_mode_outlined, null),
        // 세피아: 옛날 종이 모양 (선으로만)
        if (_isEpub) ('sepia', _tr('세피아', 'Sepia', '棕褐色', 'セピア'), Icons.description_outlined, null),
        if (!_isEpub) ('comfort', _tr('편안한 모드', 'Comfort mode', '护眼模式', '目に優しいモード'), Icons.wb_incandescent_outlined, null),
      ],
      leadingFor: (v) => v == 'sepia' ? ParchmentIcon(size: 17, color: Theme.of(context).colorScheme.onSurfaceVariant) : null,
    ));
    if (mounted) setState(() => _bgMenuOpen = false);
    if (picked == null || !mounted) return;
    if (!_isEpub) {
      final bool comfort = picked == 'comfort';
      if (comfort != _docComfort) {
        await StorageService.setDocComfort(comfort);
        ComfortTint.fileOn = comfort;
        setState(() => _docComfort = comfort);
      }
      final String mode = comfort ? 'white' : picked;
      if (mode != _epubBgTheme) await _setEpubThemeMode(mode);
      return;
    }
    if (picked != _epubBgTheme) await _setEpubThemeMode(picked);
  }

  /// 배경 색상 메뉴가 열려 있는 동안 (아이콘 움직임)
  bool _bgMenuOpen = false;

  Future<void> _setEpubThemeMode(String mode) async {
    await StorageService.setEpubBgTheme(mode);
    setState(() {
      _initialCfi = _currentCfi;
      _epubBgTheme = mode;
    });
    try {
      if (!_isOfflineDocument) _epubController.updateTheme(theme: _buildTheme());
    } catch (_) {}
  }

  void _changeFontSize(int delta) {
    setState(() => _fontSize = (_fontSize + delta).clamp(12, 32).toInt());
    if (!_isOfflineDocument) _epubController.setFontSize(fontSize: _fontSize.toDouble());
  }

  /// 1. 뷰어 표시에서 페이지 번호를 누르고 숫자를 입력하면 해당 페이지로 이동 (설정에서 페이지 번호가 활성화된 경우만 작동)
  Future<void> _showJumpToPageDialog({bool fromProgressBar = false}) async {
    final bool allowed = fromProgressBar
        ? (_footerInfoMode == 'page' || _footerInfoMode == 'both' || _footerInfoMode == 'none')
        : (_footerInfoMode == 'page' || _footerInfoMode == 'both');
    if (_isTouchLocked || !allowed) return;
    final int totalEstPages = _isOfflineDocument ? math.max(1, _docPageCount) : (_chapters.isNotEmpty ? _chapters.length * 10 : 100);
    final int curEstPage = _isOfflineDocument
        ? (_docPage + 1).clamp(1, totalEstPages).toInt()
        : ((_progress * totalEstPages).round()).clamp(1, totalEstPages).toInt();
    final ctrl = TextEditingController(text: '$curEstPage');
    ctrl.selection = TextSelection(baseOffset: 0, extentOffset: ctrl.text.length);

    final targetPageOneBased = await showPopDialog<int>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text(
          _tr(
            '페이지 이동 (1 ~ $totalEstPages)',
            'Go to Page (1 - $totalEstPages)',
            '跳转到页码 (1 ~ $totalEstPages)',
            'ページ移動 (1 ~ $totalEstPages)',
          ),
        ),
        content: TextField(
          controller: ctrl,
          autofocus: true,
          keyboardType: TextInputType.number,
          inputFormatters: [FilteringTextInputFormatter.digitsOnly],
          decoration: InputDecoration(
            hintText: '1 ~ $totalEstPages',
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
      final int clamped = targetPageOneBased.clamp(1, totalEstPages).toInt();
      final double targetProg = totalEstPages <= 1
          ? 0.0
          : _isOfflineDocument
              ? ((clamped - 1) / (totalEstPages - 1)).clamp(0.0, 1.0).toDouble() // 문서: 정확히 그 쪽으로
              : ((clamped - 1) / totalEstPages).clamp(0.0, 1.0).toDouble();
      setState(() {
        _progress = targetProg;
        _activeStrokePoints.clear();
      });
      _readerProgress(targetProg);
    }
  }

  /// 진행바에 표시할 '지금 쪽/전체 쪽' (페이지 이동 창·하단 정보 표시와 같은 계산)
  String _progressPageLabel([double? progress]) {
    final int totalEstPages = _isOfflineDocument ? math.max(1, _docPageCount) : (_chapters.isNotEmpty ? _chapters.length * 10 : 100);
    final int curEstPage = _isOfflineDocument
        ? (_docPage + 1).clamp(1, totalEstPages).toInt()
        : (((progress ?? _progress) * totalEstPages).round()).clamp(1, totalEstPages).toInt();
    return '$curEstPage/$totalEstPages';
  }

  String _formatEpubFooterText() {
    if (_footerInfoMode == 'none') return '';
    final int totalEstPages = _isOfflineDocument ? math.max(1, _docPageCount) : (_chapters.isNotEmpty ? _chapters.length * 10 : 100);
    final int curEstPage = _isOfflineDocument
        ? (_docPage + 1).clamp(1, totalEstPages).toInt()
        : ((_progress * totalEstPages).round()).clamp(1, totalEstPages).toInt();
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

  /// 6. 진행도 UI의 화살표를 맨 처음(0.0)과 맨 마지막(1.0)으로 즉시 이동하는 용도로 변경!
  /// + 하단 배치 시 우측 하단 페이지 이동 버튼과 절대 겹치지 않도록 슬림/컴팩트 사이즈로 축소 및 여백 확보!
  Widget _buildEpubProgressBar(double bottomInset) {
    if (!_showControls || _isTouchLocked || _progressBarPos == 'hidden' || (!_isOfflineDocument && _chapters.length <= 1 && _progress <= 0.0)) {
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
    final double baseBottom = math.max<double>(bottomInset + 24.0, 28.0);

    if (_progressBarPos == 'bottom') {
      return Positioned(
        key: const ValueKey('epub_progress_bar_bottom'),
        left: 14.0 + _safeSides.left + ((_memoBarBesideProgress && _memoToolbarPos == 'left') ? _memoBarSideInset : 0.0),
        // 페이지 이동 버튼(우측 12.0, 너비 약 88px -> 우측 100px 차지)과 겹치지 않도록 118px 여유 간격 확보
        right: (_useQuickNavTurn ? 118.0 : 14.0) + _safeSides.right + ((_memoBarBesideProgress && _memoToolbarPos == 'right') ? _memoBarSideInset : 0.0),
        bottom: baseBottom,
        height: 38.0,
        child: Material(
          elevation: 5,
          color: Colors.black87,
          borderRadius: BorderRadius.circular(19),
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
                  onPressed: _jumpToFirstPage,
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
                      value: val,
                      min: 0.0,
                      max: 1.0,
                      onChanged: (v) => setState(() => _progress = v),
                      onChangeEnd: (v) {
                        _readerProgress(v);
                      },
                    ),
                  ),
                ),
                GestureDetector(
                  behavior: HitTestBehavior.opaque,
                  onTap: (_footerInfoMode == 'page' || _footerInfoMode == 'both' || _footerInfoMode == 'none')
                      ? () => _showJumpToPageDialog(fromProgressBar: true)
                      : null,
                  child: Padding(
                    padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 4),
                    child: Text(
                      _progressPageLabel(),
                      style: const TextStyle(fontSize: 10.5, fontWeight: FontWeight.bold, color: Colors.white),
                    ),
                  ),
                ),
                IconButton(
                  icon: const Icon(Icons.last_page, color: Colors.white, size: 16),
                  tooltip: '마지막으로 이동',
                  visualDensity: VisualDensity.compact,
                  padding: EdgeInsets.zero,
                  constraints: const BoxConstraints(minWidth: 28, minHeight: 28),
                  onPressed: _jumpToLastPage,
                ),
              ],
            ),
          ),
        ),
      );
    }

    final double topInset = MediaQuery.paddingOf(context).top;
    final bool memoBarVisible = _isMemoMode && !_isTouchLocked;
    // 메모 도구모음이 상단/하단에 있으면 세로 진행바가 그만큼 비켜 준다
    final double safeTopOffset = topInset + (_showControls ? 64.0 : 16.0) + ((memoBarVisible && _memoToolbarPos == 'top') ? 52.0 : 0.0);
    final double safeBottomOffset = baseBottom + ((memoBarVisible && _memoToolbarPos == 'bottom') ? 96.0 : (_useQuickNavTurn && _progressBarPos == 'right' ? 48.0 : 8.0));
    return Positioned(
      key: ValueKey('epub_progress_bar_$_progressBarPos'),
      top: safeTopOffset,
      bottom: safeBottomOffset,
      left: _progressBarPos == 'left' ? 8.0 + _safeSides.left : null,
      right: _progressBarPos == 'right' ? 8.0 + _safeSides.right : null,
      width: 40.0,
      child: Material(
        elevation: 5,
        color: Colors.black87,
        borderRadius: BorderRadius.circular(20),
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
                onPressed: _jumpToFirstPage,
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
                      value: val,
                      min: 0.0,
                      max: 1.0,
                      onChanged: (v) => setState(() => _progress = v),
                      onChangeEnd: (v) {
                        _readerProgress(v);
                      },
                    ),
                  ),
                ),
              ),
              GestureDetector(
                behavior: HitTestBehavior.opaque,
                onTap: (_footerInfoMode == 'page' || _footerInfoMode == 'both' || _footerInfoMode == 'none')
                    ? () => _showJumpToPageDialog(fromProgressBar: true)
                    : null,
                child: Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 2, vertical: 4),
                  // 세로 진행바는 폭이 좁아 긴 쪽 번호는 글자를 줄여서 표시
                  child: FittedBox(
                    fit: BoxFit.scaleDown,
                    child: Text(
                      _progressPageLabel(),
                      style: const TextStyle(fontSize: 9.5, fontWeight: FontWeight.bold, color: Colors.white),
                    ),
                  ),
                ),
              ),
              IconButton(
                icon: const Icon(Icons.vertical_align_bottom, color: Colors.white, size: 16),
                tooltip: '마지막으로 이동',
                visualDensity: VisualDensity.compact,
                padding: EdgeInsets.zero,
                constraints: const BoxConstraints(minWidth: 30, minHeight: 30),
                onPressed: _jumpToLastPage,
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildQuickNavButtons(double bottomInset) {
    return Positioned(
      right: 12.0 + _safeSides.right,
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
                icon: const Icon(Icons.arrow_back, color: Colors.amber, size: 17),
                tooltip: '이전 페이지',
                visualDensity: VisualDensity.compact,
                constraints: const BoxConstraints(minWidth: 34, minHeight: 34),
                padding: EdgeInsets.zero,
                onPressed: _turnPrev,
              ),
              Container(width: 1, height: 18, color: Colors.white24),
              IconButton(
                icon: const Icon(Icons.arrow_forward, color: Colors.amber, size: 17),
                tooltip: '다음 페이지',
                visualDensity: VisualDensity.compact,
                constraints: const BoxConstraints(minWidth: 34, minHeight: 34),
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
    _framesTimer?.cancel();
    ComfortTint.viewerClosed();
    ComfortTint.fileOn = false;
    _epubZoomController.removeListener(_onZoomMatrixChanged);
    _docShownView.dispose();
    _dropIdleShot();
    _dropBackShots();
    if (_tapGuide?.mounted ?? false) _tapGuide!.remove();
    SystemBars.leaveViewer();
    _snapHideTimer?.cancel();
    _slideShowExitTimer?.cancel();
    if (_slideShow) {
      // 슬라이드 쇼 중에 나가면 화면 방향을 원래대로
      final bool? want = StorageService.desiredLandscapeNotifier.value;
      _pdfChannel.invokeMethod('setScreenOrientation', {
        'mode': want == null ? 'unspecified' : (want ? 'landscape' : 'portrait'),
      }).catchError((_) => null);
    }
    _book.dispose();
    _docPressTimer?.cancel();
    _docSel.dispose();
    _pageBar.hide();
    if (_shakeListeningSent == true) VolumeKeyService.setShakeListening(false);
    _epubLoadWatchdog?.cancel();
    WidgetsBinding.instance.removeObserver(this);
    _volumeKeyService.stopListening();
    super.dispose();
  }

  // 흔들기 센서는 화면 잠금 중(그리고 흔들기 해제가 허용될 때)에만 켠다
  bool? _shakeListeningSent;
  void _syncShakeListening() {
    final bool want = _isTouchLocked && (_useShakeLock || !_useVolumeComboLock);
    if (_shakeListeningSent == want) return;
    _shakeListeningSent = want;
    VolumeKeyService.setShakeListening(want);
  }

  // 도구 모음(화면 아래 가로 막대)에 들어가는 기능들
  List<QuickToolItem> _buildQuickMenuItems() {
    return [
      QuickToolItem(
        icon: const Icon(Icons.skip_previous_rounded, color: Colors.white, size: 19),
        tooltip: _tr('이전 파일로 이동', 'Previous File', '上一个文件', '前のファイル'),
        onTap: () => _openAdjacentFileInSameGroup(-1),
        enabled: _prevFilePath != null,
        closeAfterTap: true,
      ),
      QuickToolItem(
        icon: const Icon(Icons.skip_next_rounded, color: Colors.white, size: 19),
        tooltip: _tr('다음 파일로 이동', 'Next File', '下一个文件', '次のファイル'),
        onTap: () => _openAdjacentFileInSameGroup(1),
        enabled: _nextFilePath != null,
        closeAfterTap: true,
      ),
      QuickToolItem(
        icon: const Icon(Icons.lock_outline, color: Colors.white, size: 17),
        tooltip: _tr('화면 잠금', 'Lock Screen', '锁定屏幕', '画面ロック'),
        onTap: () {
          setState(() {
            _isTouchLocked = true;
            _showControls = false;
            _volumeKeyService.ensureInterceptActive();
            _isMemoMode = false;
            _allowFingerDrawing = false;
            _isStylusDown = false;
          });
          ScaffoldMessenger.of(context).clearSnackBars();
          ScaffoldMessenger.of(context)
              .showSnackBar(SnackBar(content: Text(_buildLockScreenMessage()), duration: const Duration(seconds: 2)));
        },
        closeAfterTap: true,
      ),
      QuickToolItem(
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
      // TXT는 읽기 방향 전환을 쓰지 않음
      if (!_isTxt)
      QuickToolItem(
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
          await StorageService.setBookReadingDirectionRtl(widget.filePath, nextRtl);
          setState(() => _isMangaRtlMode = nextRtl);
          if (!_isOfflineDocument) {
            try {
              _epubController.setSwipeReversed(nextRtl);
            } catch (_) {}
          }
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
        icon: QuillInkIcon(color: _isMemoMode ? Colors.amber : Colors.white, size: 22),
        tooltip: _tr('메모', 'Memo', '笔记', 'メモ'),
        onTap: () {
          // 스크롤 모드는 쪽이 이어져 있어 메모를 쓰지 않음 (읽기 방향 전환과 같은 안내)
          if (_pageModeScroll) {
            ScaffoldMessenger.of(context)
              ..clearSnackBars()
              ..showSnackBar(SnackBar(
                content: Text(_tr('스크롤 모드에서는 메모를 쓸 수 없어요\n탭·슬라이드 모드에서 쓸 수 있어요',
                    'Memos are not available in scroll mode\nUse them in tap/slide mode',
                    '滚动模式下不能写笔记，请在点击/滑动模式下使用',
                    'スクロールモードではメモを使えません\nタップ・スライドモードで使えます')),
                duration: const Duration(seconds: 2),
              ));
            return;
          }
          setState(() {
            _isMemoMode = !_isMemoMode;
            _isEraserMode = false;
            if (!_isMemoMode) _allowFingerDrawing = false;
          _isStylusDown = false;
          });
        },
        closeAfterTap: true,
      ),
      QuickToolItem(
        icon: const Icon(Icons.copy_all_outlined, color: Colors.white, size: 17),
        tooltip: _tr('글자 복사', 'Copy Text', '复制文字', '文字をコピー'),
        onTap: _openTextCopySheet,
        closeAfterTap: true,
      ),
      if (_bookmarksOn)
      QuickToolItem(
        icon: Icon(
          _isCurrentPageBookmarked ? Icons.bookmarks : Icons.bookmarks_outlined,
          color: _isCurrentPageBookmarked ? Colors.amber : Colors.white,
          size: 17,
        ),
        tooltip: _tr('북마크', 'Bookmarks', '书签', 'ブックマーク'),
        onTap: _openBookmarkSheet,
        closeAfterTap: true,
      ),
    ];
  }

  /// 지금 보고 있는 쪽(2페이지 보기면 두 쪽)의 글을 보여 주고 복사할 수 있게 함
  Future<void> _openTextCopySheet() async {
    String text = '';
    try {
      if (_isTxt) {
        text = _txtController.visibleText;
      } else if (_isOfflineDocument) {
        final n = _snapSpread ? 2 : 1;
        text = (await _hwpController.pageText(_docPage, math.min(_docPageCount, _docPage + n))).join('\n\n');
      } else {
        text = (await _epubController.extractCurrentPageText()).text ?? '';
      }
    } catch (_) {}
    if (!mounted) return;
    await showTextCopySheet(context, text: text, tr: _tr);
  }

  /// Excel has a two-dimensional viewport. Do not wrap it in the book reader's
  /// InteractiveViewer, page-swipe recognizers, tap zones or annotation layers.
  Widget _buildSpreadsheetReader(bool isLandscape) {
    return PopScope(
      canPop: !_findOpen,
      onPopInvokedWithResult: (didPop, _) {
        if (!didPop && _findOpen) _closeFind();
      },
      child: Scaffold(
        key: _scaffoldKey,
        backgroundColor: _getBgColor(),
        body: SafeArea(
          top: false,
          child: Column(
            key: _epubBodyKey,
            children: [
              if (_findOpen)
                FindInFileBar(
                  onSearch: _hwpController.search,
                  onGoto: _hwpController.showSearchResult,
                  onClose: _closeFind,
                  tr: _tr,
                )
              else
                Material(
                  color: Colors.black87,
                  child: SafeArea(
                    bottom: false,
                    child: SizedBox(
                      height: 48,
                      child: Row(children: [
                        IconButton(
                          icon: const Icon(Icons.arrow_back, color: Colors.white, size: 20),
                          onPressed: () => Navigator.pop(context),
                        ),
                        Expanded(child: Text(widget.bookTitle,
                            style: const TextStyle(color: Colors.white, fontSize: 14),
                            overflow: TextOverflow.ellipsis, maxLines: 1)),
                        IconButton(
                          icon: const Icon(Icons.search, color: Colors.white, size: 21),
                          tooltip: _tr('파일 내 단어 검색', 'Find in File', '在文件中查找', 'ファイル内検索'),
                          onPressed: _docPageCount > 0 ? () => setState(() => _findOpen = true) : null,
                        ),
                        // 엑셀은 끌어서 움직이면 되므로 뷰어 설정 없음
                        const SizedBox(width: 4),
                      ]),
                    ),
                  ),
                ),
              Expanded(
                child: AfterRouteTransition(
                  builder: (_) => UiUnscale(child: _buildDocumentViewer(isLandscape)),
                ),
              ),
              // 아래 막대: 시트 목록 + 확대·축소 (서재 위 그룹 칩과 같은 모양)
              Material(
                color: Theme.of(context).colorScheme.surface,
                child: Container(
                  decoration: BoxDecoration(border: Border(top: BorderSide(color: Theme.of(context).dividerColor))),
                  child: Row(children: [
                    Expanded(
                      child: SpreadsheetTabBar(
                        names: [for (final chapter in _chapters) chapter.title],
                        selectedIndex: _docPage,
                        onSelected: (index) => _hwpController.selectSheet(index),
                        atBottom: true,
                      ),
                    ),
                    Container(width: 1, height: 28, color: Theme.of(context).dividerColor),
                    Padding(
                      padding: const EdgeInsets.fromLTRB(10, 8, 12, 8),
                      child: Material(
                        type: MaterialType.transparency,
                        shape: RoundedRectangleBorder(
                          borderRadius: BorderRadius.circular(8),
                          side: BorderSide(color: Theme.of(context).colorScheme.outlineVariant),
                        ),
                        clipBehavior: Clip.antiAlias,
                        child: SizedBox(
                          height: 32,
                          child: Row(mainAxisSize: MainAxisSize.min, children: [
                            IconButton(
                              visualDensity: VisualDensity.compact,
                              padding: EdgeInsets.zero,
                              constraints: const BoxConstraints(minWidth: 36, minHeight: 32),
                              icon: const Icon(Icons.remove, size: 18),
                              tooltip: _tr('축소', 'Zoom out', '缩小', '縮小'),
                              onPressed: _docPageCount > 0 && _sheetZoom > .25 ? () => _hwpController.zoomSheet(1 / 1.25) : null,
                            ),
                            InkWell(
                              onTap: _docPageCount > 0 ? () => _hwpController.resetSheetZoom() : null,
                              child: SizedBox(
                                width: 46,
                                height: 32,
                                child: Center(
                                  child: Text('${(_sheetZoom * 100).round()}%',
                                      style: const TextStyle(fontSize: 13, fontWeight: FontWeight.w600)),
                                ),
                              ),
                            ),
                            IconButton(
                              visualDensity: VisualDensity.compact,
                              padding: EdgeInsets.zero,
                              constraints: const BoxConstraints(minWidth: 36, minHeight: 32),
                              icon: const Icon(Icons.add, size: 18),
                              tooltip: _tr('확대', 'Zoom in', '放大', '拡大'),
                              onPressed: _docPageCount > 0 && _sheetZoom < 4 ? () => _hwpController.zoomSheet(1.25) : null,
                            ),
                          ]),
                        ),
                      ),
                    ),
                  ]),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    _syncShakeListening();
    // 메뉴를 띄운 동안에는 상태표시줄도 함께 보임
    SystemBars.viewerStatus(_showControls && !_isTouchLocked);
    if (_isLoading) {
      return Scaffold(body: FileLoadingView(label: _tr('파일 여는 중…', 'Opening file…', '正在打开文件', 'ファイルを開いています')));
    }

    // 키보드(페이지 이동 창 등)가 올라올 때 화면 전체가 매 프레임 다시 그려지지 않도록 필요한 값만 구독
    final screenSize = MediaQuery.sizeOf(context);
    final bottomPadding = MediaQuery.viewPaddingOf(context).bottom;
    final bool isLandscape = screenSize.width > screenSize.height;
    if (_isSpreadsheet) return _buildSpreadsheetReader(isLandscape);
    final EpubSpread spreadSetting =
        _spreadFor(isLandscape) ? EpubSpread.always : EpubSpread.none;

    final String epubViewerKey =
        '${_activeFilePath}_${spreadSetting}_${_epubBgTheme}_${_pageModeScroll ? 'scroll' : 'page'}_$_epubViewerGeneration';
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted && !_isOfflineDocument) _startEpubLoadWatchdog(epubViewerKey);
    });

    // 쪽 뒤 바탕: 한글·워드·TXT는 뷰어 배경 설정(라이트=흰색, 다크=검은색),
    // PPT·엑셀은 앱 테마(라이트=흰색, 다크·밝은 다크=검은색), EPUB은 책 배경색 그대로
    final bgColor = (_isWordOrHwp || _isTxt)
        ? viewerThemeBackdrop(_epubBgTheme)
        : (_isPresentation || _isSpreadsheet)
            ? viewerBackdrop(context)
            : _getBgColor();
    final footerTextColor = _epubBgTheme == 'dark' ? Colors.white54 : Colors.black54;
    final footerText = _formatEpubFooterText();

    return PopScope(
      canPop: !_slideShow && !_findOpen,
      onPopInvokedWithResult: (didPop, _) {
        if (!didPop && _findOpen) {
          _closeFind(); // 뒤로 가기: 검색만 닫음
          return;
        }
        if (!didPop && _slideShow) {
          _endSlideShow(); // 뒤로 가기: 슬라이드 쇼만 끝냄
          return;
        }
        if (_isTouchLocked) {
          _isTouchLocked = false;
        }
      },
      child: _withDocComfort(Scaffold(
      // 페이지 이동 창의 키보드가 올라와도 뒤의 책 화면은 줄이지 않는다 (줄어드는 동안 버벅임)
      resizeToAvoidBottomInset: false,
      key: _scaffoldKey,
      backgroundColor: _slideShow ? Colors.black : bgColor,
      onDrawerChanged: (open) {
        if (!open && _tocFreeze != null) {
          // 닫히는 움직임이 끝난 뒤 실제 화면으로
          WidgetsBinding.instance.addPostFrameCallback((_) {
            if (mounted) setState(() => _tocFreeze = null);
          });
        }
      },
      // TXT·PPT는 목차 없음. 화면 왼쪽 끝을 밀어 목차가 열리지 않게 (목차는 위 단추로만)
      drawerEnableOpenDragGesture: false,
      drawer: _isTxt || _isPresentation ? null : Drawer(
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
                child: _outlineProgress != null
                    ? OutlineProgressView(
                        progress: _outlineProgress!,
                        label: _tr('목차 만드는 중', 'Building contents', '正在生成目录', '目次を作成中'),
                        hint: _tr('처음 한 번만 만들고, 다음부터는 바로 보여요', 'Only the first time — next time it opens instantly', '仅首次生成，下次直接显示', '初回のみ作成し、次回からはすぐ表示されます'),
                      )
                    : _chapters.isEmpty
                        ? NoTocView(label: _tr('표시할 목차가 없어요', 'No contents to show', '没有可显示的目录', '表示できる目次がありません'))
                        : ListView.builder(
                  itemCount: _chapters.length,
                  itemBuilder: (context, index) {
                    final chapter = _chapters[index];
                    final int level = index < _chapterLevels.length ? _chapterLevels[index] : 1;
                    return ListTile(
                      // 제목 단계만큼 들여쓰기, 큰 제목은 굵게
                      contentPadding: EdgeInsets.only(left: 16.0 + (level - 1).clamp(0, 4) * 18.0, right: 16),
                      title: Text(
                        chapter.title.trim(),
                        style: _chapterLevels.isEmpty
                            ? null
                            : TextStyle(
                                fontSize: level <= 1 ? 15.5 : 14,
                                fontWeight: level <= 1 ? FontWeight.w700 : FontWeight.w400,
                              ),
                      ),
                      // 목차 항목이 있는 쪽 번호
                      trailing: _chapterLevels.isEmpty
                          ? null
                          : Text(
                              '${(int.tryParse(chapter.href.split(':').last) ?? 0) + 1}',
                              style: TextStyle(fontSize: 12.5, color: Theme.of(context).colorScheme.onSurfaceVariant),
                            ),
                      onTap: () {
                        Navigator.pop(context);
                        _readerDisplay(chapter.href);
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
          key: _epubBodyKey,
          fit: StackFit.expand,
          children: [
            // 종이색: 화면 전체에 종이 질감
            if (_isPaperTheme)
              const Positioned.fill(
                child: IgnorePointer(
                  child: Image(image: AssetImage('assets/textures/paper.jpg'), fit: BoxFit.cover, gaplessPlayback: true),
                ),
              ),
            // 1. EPUB 뷰어 본문 (Listener를 EpubViewer에만 감싸서 우측 하단 페이지 이동 버튼 클릭 시 상단/하단 UI가 뜨지 않도록 완벽 분리!)
            Positioned.fill(
              child: Padding(
                padding: _slideShow
                    ? EdgeInsets.zero
                    : EdgeInsets.only(
                        // EPUB·TXT: 글이 상단바에 가리지 않도록 상단바 높이보다 살짝 아래에서 시작
                        // 쪽이 있는 문서(워드·한글·PPT): 쪽 위아래 빈 곳이 같도록 위 여백을 아래와 같게
                        top: (_isEpub || _isTxt)
                            ? _readerTextTop
                            : (_isSpreadsheet ? 12.0 : (bottomPadding > 0 ? bottomPadding : 8.0) + 20.0),
                        bottom: (bottomPadding > 0 ? bottomPadding : 8.0) + 20.0,
                      ),
                child: IgnorePointer(
                  key: _epubViewRectKey,
                  ignoring: _isTouchLocked || (_isMemoMode && (_isStylusDown || _allowFingerDrawing)),
                  child: Listener(
                    behavior: HitTestBehavior.translucent,
                    onPointerDown: (event) {
                      _swipeTrackDown(event);
                      _handlePointerDown(event);
                    },
                    onPointerMove: (event) {
                      _swipeTrackMove(event);
                    },
                    onPointerUp: (event) {
                      _swipeTrackUp(event);
                      _handlePointerUp(event, screenSize);
                    },
                    onPointerCancel: (event) {
                      if (_tapPointers > 0) _tapPointers--;
                      if (_tapPointers == 0) {
                        _pointerDownPosition = null;
                        _pointerDownTime = null;
                      }
                      _swipeTrackUp(event, cancelled: true);
                      if (_isStylusDown) {
                        setState(() => _isStylusDown = false);
                      }
                    },
                    child: _curlStage(
                      InteractiveViewer(
                      transformationController: _epubZoomController,
                      // 문서 스크롤 보기는 목록이 직접 확대·이동을 맡음 (겹치면 확대가 잘 안 됨)
                      // 메모 중에도 (손으로 그리기가 아니면) 손가락으로 확대한 쪽을 옮김 (삼성 노트처럼: 펜은 쓰고 손가락은 움직임)
                      panEnabled: !_isSpreadsheet && !_docScrollActive && (!_isMemoMode || !_allowFingerDrawing) && _epubZoomScale > 1.03,
                      scaleEnabled: !_isSpreadsheet && !(_pageModeScroll && _isOfflineDocument) && !_isTouchLocked && (!_isMemoMode || !_allowFingerDrawing),
                      minScale: 1.0,
                      maxScale: 4.5,
                      onInteractionStart: (_) {
                        // 확대/이동 제스처가 터치를 가져가면 WebView는 스와이프를 받지 못함
                        _swipeScaleStarted = true;
                      },
                      onInteractionUpdate: (_) {
                        final s = _epubZoomController.value.getMaxScaleOnAxis();
                        if ((s - _epubZoomScale).abs() > 0.02) {
                          setState(() => _epubZoomScale = s);
                        }
                      },
                      onInteractionEnd: (_) {
                        final s = _epubZoomController.value.getMaxScaleOnAxis();
                        if (s < 1.03) {
                          _epubZoomController.value = Matrix4.identity();
                          if (_epubZoomScale != 1.0) {
                            setState(() => _epubZoomScale = 1.0);
                          }
                        } else if ((s - _epubZoomScale).abs() > 0.01) {
                          setState(() => _epubZoomScale = s);
                        }
                      },
                      child: RawGestureDetector(
                        behavior: HitTestBehavior.translucent,
                        // 빠르게 튕기는 스와이프는 WebView보다 먼저 Flutter가 받아 직접 페이지를 넘긴다.
                        // 손가락 한 개일 때만 (두 손가락이면 확대·축소가 가져가게), 스크롤 모드에서는 쓰지 않음
                        gestures: {
                          if (_swipeFlutterOwned && !_pageModeScroll)
                            _OneFingerHorizontalDrag: GestureRecognizerFactoryWithHandlers<_OneFingerHorizontalDrag>(
                              () => _OneFingerHorizontalDrag(),
                              (r) => r
                                ..onStart = _onFlickStart
                                ..onUpdate = _onFlickUpdate
                                ..onEnd = _onFlickEnd,
                            ),
                        },
                        child: AfterRouteTransition(builder: (_) => UiUnscale(child: _isOfflineDocument ? _buildDocumentViewer(isLandscape) : Stack(fit: StackFit.expand, children: [
// 목차를 여닫는 동안에는 책 화면(WebView)을 잠시 그림으로 바꿔 끊김 없이
Offstage(offstage: _tocFreeze != null, child: EpubViewer(
                          key: ValueKey(epubViewerKey),
                          epubController: _epubController,
                    epubSource: EpubSource.fromFile(File(_activeFilePath)),
                    // 프로젝트에 포함한 EPUB 뷰어(vendor)는 안드로이드에서 같은 출처의 https 주소로
                    // 장(chapter)을 필요할 때마다 파일에서 읽어 보여 준다 (책 전체를 한 번에 넘기지 않음)
                    useLocalServer: true,
                    initialCfi: _initialCfi,
                    onEpubLoaded: () {
                      if (mounted && !_epubDisplayed) setState(() => _epubDisplayed = true);
                      _epubDisplayed = true;
                      _epubController.setSwipeReversed(_isMangaRtlMode);
                      _epubController.setSwipeEnabled(_useSwipeTurn && !_pageModeScroll && !_curlOn);
                      _epubLoadWatchdog?.cancel();
                    },
                    onLoadError: (error) => _handleEpubLoadError(error.message),
                    displaySettings: EpubDisplaySettings(
                      // 스크롤 모드: 장을 이어 붙여 세로로 / 그 외: 쪽 넘김
                      flow: _pageModeScroll ? EpubFlow.scrolled : EpubFlow.paginated,
                      snap: !_pageModeScroll,
                      spread: spreadSetting,
                      fontSize: _fontSize,
                      theme: _buildTheme(),
                    ),
                    // 글을 길게 눌러 고르면: 휴대폰 기본 메뉴(복사 | 모두 선택 | 공유)와 형광펜 칠하기
                    // 휴대폰 기본 메뉴는 기기마다 'false'·'앱 관리' 같은 엉뚱한 항목이 섞여 나와서 직접 만든 메뉴만 씀
                    selectionContextMenu: EpubContextMenu(
                      hideDefaultSystemItems: true,
                      items: [
                        EpubContextMenuItem(
                          id: 2,
                          title: _tr('복사', 'Copy', '复制', 'コピー'),
                          action: () {
                            final t = _selectedText;
                            _clearEpubSelection();
                            copyText(context, t, _tr);
                          },
                        ),
                        EpubContextMenuItem(
                          id: 3,
                          title: _tr('모두 선택', 'Select all', '全选', 'すべて選択'),
                          action: () => _epubSelectAllPage(),
                        ),
                        EpubContextMenuItem(
                          id: 4,
                          title: _tr('공유', 'Share', '分享', '共有'),
                          action: () {
                            final t = _selectedText;
                            _clearEpubSelection();
                            shareText(t);
                          },
                        ),
                        EpubContextMenuItem(
                          id: 1,
                          title: _tr('형광펜 칠하기', 'Highlight', '荧光笔', 'マーカー'),
                          action: () {
                            if (_selectedCfiRange != null) {
                              _epubController.addHighlight(
                                cfi: _selectedCfiRange!,
                                color: Colors.amber,
                              );
                            }
                            _clearEpubSelection();
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
                            _readerProgress(_progress);
                          });
                        }
                      }
                    },
                    onTextSelected: (epubTextSelection) {
                      _selectedCfiRange = epubTextSelection.selectionCfi;
                      _selectedText = epubTextSelection.selectedText;
                      _hasTextSelection = true;
                    },
                    onDeselection: () {
                      _hasTextSelection = false;
                    },
                    onScrollMetrics: (top, height, client) => _epubScrollMetrics.value = [top, height, client],
                    onChapterEdge: (atStart, atEnd, first, last) {
                      if (!mounted) return;
                      if (atStart != _chAtStart || atEnd != _chAtEnd || first != _chFirst || last != _chLast) {
                        setState(() {
                          _chAtStart = atStart;
                          _chAtEnd = atEnd;
                          _chFirst = first;
                          _chLast = last;
                        });
                      }
                    },
                    onRelocated: (value) async {
                      if (!_epubDisplayed && mounted) setState(() => _epubDisplayed = true);
                      _hasTextSelection = false;
                      final waiter = _relocateWaiter;
                      if (waiter != null && !waiter.isCompleted) waiter.complete();
                      if (!_hasRestoredInitialPosition &&
                          _initialCfi != null &&
                          value.progress < 0.01 &&
                          _progress > 0.05) {
                        return;
                      }
                      _hasRestoredInitialPosition = true;
                      if (value.startCfi != _currentCfi) _onPositionChanging();
                      _currentCfi = value.startCfi;
                      if (!_book.busy) _scheduleIdleShot();
                      _epubAtStart = value.atStart;
                      _epubAtEnd = value.atEnd;
                      final double clampedProg = value.progress.clamp(0.0, 1.0).toDouble();
                      final String newLocKey = _computeLocationKey(value.startCfi, clampedProg);

                      StorageService.saveLastPosition(widget.filePath, value.startCfi);
                      StorageService.saveProgress(widget.filePath, clampedProg);
                      StorageService.savePageLabel(widget.filePath, _progressPageLabel(clampedProg));

                      // 3. 페이지 이동 시 해당 페이지(CFI)에 저장된 필기만 불러와서 표시 (보기 방식·화면 방향별)
                      final String memoKey = _memoKeyFor(newLocKey);
                      final int memoSeq = ++_memoLoadSeq;
                      final Future<List<MemoStroke>> load = _getMemo(memoKey);
                      _memoLoading = load;
                      final pageStrokes = await load;
                      if (mounted && memoSeq == _memoLoadSeq) {
                        setState(() {
                          _epubSinglePage = _chapters.length <= 1 && value.chapterTotalPages == 1;
                          _epubLocated = true;
                          _progress = clampedProg;
                          _memoBase = newLocKey;
                          _currentPageLocationKey = memoKey;
                          _memoStrokes = pageStrokes;
                          _activeStrokePoints.clear();
                        });
                      }
                    },
                    )),
                          if (_tocFreeze != null)
                            Positioned.fill(child: IgnorePointer(child: Image.memory(_tocFreeze!, fit: BoxFit.fill, gaplessPlayback: true))),
                          // 스크롤 보기: 오른쪽 회색 막대 (끌면 장 안에서 바로 이동)
                          if (_pageModeScroll && _tocFreeze == null && _epubDisplayed)
                            Positioned.fill(
                              child: ValueListenableBuilder<List<double>>(
                                valueListenable: _epubScrollMetrics,
                                builder: (context, m, _) {
                                  final double top = m[0], height = m[1], client = m[2];
                                  if (height <= client + 1 || client <= 0) return const SizedBox.shrink();
                                  return ScrollThumbBar(
                                    // 세피아: 종이 질감 위에서도 잘 보이게 진한 갈색
                                    color: _isPaperTheme ? const Color(0xFF6B4A22) : null,
                                    ratio: top / (height - client),
                                    viewFraction: client / height,
                                    onDragRatio: (r) {
                                      _epubScrollMetrics.value = [r * (height - client), height, client];
                                      _epubController.scrollToRatio(r);
                                    },
                                  );
                                },
                              ),
                            ),
                          // 처음 열 때: 돌아가는 원 + '파일 여는 중'
                          if (!_epubDisplayed)
                            Positioned.fill(
                              child: IgnorePointer(
                                // 종이색: 단색으로 덮지 않고 뒤의 종이 질감이 그대로 보이게
                                child: ColoredBox(
                                  color: _isPaperTheme ? Colors.transparent : _getBgColor(),
                                  child: FileLoadingView(label: _tr('파일 여는 중…', 'Opening file…', '正在打开文件', 'ファイルを開いています'), background: _getBgColor()),
                                ),
                              ),
                            ),
                        ]))),
                      ),
                    ),
                    ),
                  ),
                ),
              ),
            ),

            // 2. S펜 전용 페이지별 필기/지우개 오버레이 (EagerStylusPanGestureRecognizer로 S펜 이동 시 화면 움직임 100% 차단 + 손가락은 페이지 스와이프)
            // (저장된 메모는 책 화면 안(넘기는 종이 밑)에 그림: 쪽을 넘길 때 새 쪽 메모가 미리 보이지 않게)
            if (_isMemoMode)
              Positioned.fill(
                child: KeyedSubtree(
                  key: _memoLayerKey,
                  child: LayoutBuilder(
                  builder: (context, constraints) {
                    final double drawWidth = constraints.maxWidth;
                    final double drawHeight = constraints.maxHeight;
                    return StylusOnlyDrawingLayer(
                      enabled: _isMemoMode,
                      allowTouch: _allowFingerDrawing,
                      passThroughTouch: true,
                      onStylusDown: (event) {
                        if (!_isStylusDown) {
                          setState(() => _isStylusDown = true);
                        }
                        final bool useEraser =
                            _isEraserMode || event.kind == PointerDeviceKind.invertedStylus;
                        if (useEraser) {
                          _eraseStartStrokes = _memoStrokes;
                          _eraseStrokeAt(event.localPosition, _memoMapInLayer(Size(drawWidth, drawHeight)));
                        } else {
                          setState(() {
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
                          _eraseStrokeAt(event.localPosition, _memoMapInLayer(Size(drawWidth, drawHeight)));
                        } else {
                          setState(() {
                            _activeStrokePoints.add(event.localPosition);
                          });
                        }
                      },
                      onStylusUp: (event) async {
                        _lastEraserPos = null;
                        if (_isStylusDown) {
                          setState(() => _isStylusDown = false);
                        }
                        final bool useEraser =
                            _isEraserMode || event.kind == PointerDeviceKind.invertedStylus;
                        if (useEraser) {
                          _finishEraseHistory();
                          final locKey = _currentPageLocationKey;
                          await _saveMemo(locKey, _memoStrokes);
                        } else if (_activeStrokePoints.isNotEmpty &&
                            drawWidth > 0 &&
                            drawHeight > 0) {
                          final locKey = _currentPageLocationKey;
                          // 문서: 쪽 네모 기준으로 저장 (가로·세로로 돌려도 쪽 위 같은 자리에 같은 크기로)
                          if (_memoPageAnchored && (_pageSlots?.isEmpty ?? true)) await _refreshPageFrames();
                          if (!mounted) return;
                          final _MemoMap map = _memoMapInLayer(Size(drawWidth, drawHeight));
                          final fracs = [for (final p in _activeStrokePoints) map.toFrac(p)];
                          final stroke = MemoStroke(
                            dxList: [for (final f in fracs) f.dx],
                            dyList: [for (final f in fracs) f.dy],
                            colorValue: _penColor.toARGB32(),
                            // 굵기는 쪽 너비에 대한 비율 (펜 굵기는 쪽 기준이라 확대하면 함께 굵어지고 화면을 돌려도 쪽과 같이)
                            strokeWidth: _penWidth * _epubZoomController.value.getMaxScaleOnAxis() / map.unit,
                          );
                          _memoHistory.record(locKey, _memoStrokes);
                          final list = List<MemoStroke>.from(_memoStrokes)..add(stroke);
                          setState(() {
                            _memoStrokes = list;
                            _activeStrokePoints.clear();
                          });
                          await _saveMemo(locKey, list);
                        }
                      },
                      onStylusCancel: (_) {
                        _lastEraserPos = null;
                        _finishEraseHistory();
                        setState(() {
                          _isStylusDown = false;
                          _activeStrokePoints.clear();
                        });
                      },
                      child: CustomPaint(
                        painter: _MemoPainter(
                          strokes: const [],
                          currentPoints: _activeStrokePoints,
                          currentColor: _penColor,
                          currentWidth: _penWidth * _epubZoomController.value.getMaxScaleOnAxis(), // 확대한 만큼 굵게 (쪽 기준 굵기)
                        ),
                      ),
                    );
                  },
                ),
                ),
              ),

            if (footerText.isNotEmpty && !_slideShow)
              Positioned(
                left: 20 + _safeSides.left,
                right: 20 + _safeSides.right,
                bottom: math.max<double>(bottomPadding + 4.0, 8.0),
                child: IgnorePointer(
                  ignoring: _isTouchLocked || !(_footerInfoMode == 'page' || _footerInfoMode == 'both'),
                  child: Align(
                    alignment: Alignment.centerRight,
                    child: GestureDetector(
                      behavior: HitTestBehavior.opaque,
                      onTap: (_footerInfoMode == 'page' || _footerInfoMode == 'both')
                          ? _showJumpToPageDialog
                          : null,
                      child: Padding(
                        padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 4),
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
                ),
              ),

            // S펜 필기 모드 하단 미니 툴바 (진행바 UI 위에 위치 + 색상과 선 굵기 사이에 지우개 배치 + 선 굵기 숫자 터치 입력)
            if (_isMemoMode && !_isTouchLocked) _buildMemoToolbar(bottomPadding),

            // 파일 내 단어 검색 막대
            if (_findOpen && !_isTouchLocked)
              Positioned(
                top: 0,
                left: 0,
                right: 0,
                child: FindInFileBar(
                  onSearch: _isTxt ? _txtController.search : _docFindSearch,
                  onGoto: _isTxt ? _txtController.showSearchResult : _docFindGoto,
                  onClose: _closeFind,
                  tr: _tr,
                ),
              ),
            // 상단 컨트롤 바
            if (_showControls && !_isTouchLocked && !_findOpen)
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

                          final actionButtons = <Widget>[
                            // TXT·PPT는 목차 없음
                            if (!_isTxt && !_isPresentation)
                            IconButton(
                              visualDensity: VisualDensity.compact,
                              padding: btnPadding,
                              constraints: btnConstraints,
                              icon: const Icon(Icons.list, color: Colors.white, size: 17),
                              tooltip: _tr('목차', 'Contents', '目录', '目次'),
                              onPressed: _openToc,
                            ),
                            // 파일 내 단어 검색 (한글·워드·PPT·TXT)
                            if (_snapEligible || _isPresentation || _isTxt)
                              IconButton(
                                visualDensity: VisualDensity.compact,
                                padding: btnPadding,
                                constraints: btnConstraints,
                                icon: const Icon(Icons.search, color: Colors.white, size: 18),
                                tooltip: _tr('파일 내 단어 검색', 'Find in File', '在文件中查找', 'ファイル内検索'),
                                onPressed: () => setState(() {
                                  _findOpen = true;
                                  _showControls = false;
                                }),
                              ),
                            // 공유: 이 파일을 형식 그대로 다른 앱으로 (파일 내 검색 오른쪽)
                            IconButton(
                              visualDensity: VisualDensity.compact,
                              padding: btnPadding,
                              constraints: btnConstraints,
                              icon: const Icon(Icons.share_outlined, color: Colors.white, size: 18),
                              tooltip: _tr('공유', 'Share', '分享', '共有'),
                              onPressed: () => shareFile(context, widget.filePath, title: widget.bookTitle),
                            ),
                            // PPT에서만: 슬라이드 쇼
                            if (_isPresentation)
                              IconButton(
                                visualDensity: VisualDensity.compact,
                                padding: btnPadding,
                                constraints: btnConstraints,
                                icon: const Icon(Icons.slideshow, color: Colors.white, size: 17),
                                tooltip: _tr('슬라이드 쇼', 'Slide Show', '幻灯片放映', 'スライドショー'),
                                onPressed: _startSlideShow,
                              ),
                            // 배경 색상 (라이트·다크, EPUB은 종이색도): 뷰어 설정 왼쪽 달 모양
                            if (!_isPresentation && !_isSpreadsheet)
                              Builder(
                                builder: (btnCtx) => IconButton(
                                  visualDensity: VisualDensity.compact,
                                  padding: btnPadding,
                                  constraints: btnConstraints,
                                  // 바뀔 때 [전체] 그룹 아이콘과 같은 느낌으로 움직임 (기본 움직임)
                                  // 메뉴가 열려 있는 동안 달 그림자(또는 양피지)가 미끄러지듯 바뀜
                                  icon: MorphIcon(
                                    child: _epubBgTheme == 'sepia'
                                        ? ParchmentIcon(key: const ValueKey('bg-sepia'), size: 19, open: _bgMenuOpen, color: Colors.white)
                                        : MoonMorphIcon(
                                            key: const ValueKey('bg-moon'),
                                            size: 19,
                                            filled: _epubBgTheme == 'dark',
                                            open: _bgMenuOpen,
                                            color: Colors.white),
                                  ),
                                  tooltip: _tr('배경 색상', 'Background Color', '背景颜色', '背景色'),
                                  onPressed: () => _pickBgTheme(btnCtx),
                                ),
                              ),
                            IconButton(
                              visualDensity: VisualDensity.compact,
                              padding: btnPadding,
                              constraints: btnConstraints,
                              icon: const Icon(Icons.tune, color: Colors.white, size: 17),
                              tooltip: _tr('뷰어 설정', 'Viewer Settings', '阅读器设置', 'ビューア設定'),
                              onPressed: _showViewerSettingsSheet,
                            ),
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
                                    widget.bookTitle,
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

            _buildEpubProgressBar(bottomPadding),

            if (_useQuickNavTurn && !_isTouchLocked && !_slideShow)
              _buildQuickNavButtons(bottomPadding),

            // EPUB (스크롤·탭·슬라이드·책처럼 넘기기): 메뉴(도구 모음)를 연 동안만 '이전 챕터 / 다음 챕터' (읽는 동안 글자를 가리지 않게)
            if (_isEpub && _showControls && !_slideShow && !_isTouchLocked)
              Positioned(
                left: 16.0 + _safeSides.left,
                right: 16.0 + _safeSides.right,
                bottom: _chapterButtonsBottom(bottomPadding),
                child: _buildChapterButtons(),
              ),

            // 도구 모음: 화면 아래 가로 막대 (상단바·진행바와 함께 보였다 사라짐)
            if (_showControls && !_isTouchLocked)
              Positioned(
                left: 12.0 + _safeSides.left,
                right: 12.0 + _safeSides.right,
                bottom: math.max<double>(bottomPadding + 16.0, 20.0) + 8.0 +
                    ((_progressBarPos == 'bottom' || _useQuickNavTurn) ? 44.0 : 0.0) +
                    ((_isMemoMode && _memoToolbarPos == 'bottom') ? 56.0 : 0.0),
                child: Center(child: QuickToolBar(items: _buildQuickMenuItems())),
              ),
            // PPT 슬라이드 쇼: 맨 위에서 모든 터치를 받는다
            if (_slideShow) _buildSlideShowLayer(),
          ],
        ),
      )),
    );
  }
}

/// 손가락 한 개로 가로로 미는 동작만 받는 인식기 (두 번째 손가락이 닿으면 물러나 확대·축소가 이기게)
class _OneFingerHorizontalDrag extends HorizontalDragGestureRecognizer {
  int _down = 0;

  @override
  void addAllowedPointer(PointerDownEvent event) {
    _down++;
    if (_down > 1) {
      resolve(GestureDisposition.rejected);
      return;
    }
    super.addAllowedPointer(event);
  }

  @override
  void didStopTrackingLastPointer(int pointer) {
    _down = 0;
    super.didStopTrackingLastPointer(pointer);
  }

  @override
  void rejectGesture(int pointer) {
    _down = 0;
    super.rejectGesture(pointer);
  }
}

