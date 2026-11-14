import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:isolate';
import 'package:flutter/material.dart';
import 'text_select.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/gestures.dart';
import '../services/user_fonts.dart';
import '../services/storage_service.dart';
import 'viewer_dialogs.dart';
import 'package:flutter/services.dart';
import 'package:flutter_inappwebview/flutter_inappwebview.dart';
import '../services/docx_layout_hints.dart';
import 'pop_dialog.dart';

/// Navigation adapter; the surrounding ReaderScreen owns the existing UI.
class HwpReaderController {
  Future<void> Function(String, List<Object?>)? _invoke;

  /// 엑셀: 칸을 길게 눌러 골라 둔 상태 (다음 한 번 누름은 고른 칸만 지우고 메뉴는 열지 않음)
  bool cellSelected = false;

  Future<void> display(String position) async =>
      _invoke?.call('display', [position]);
  Future<void> next() async => _invoke?.call('next', []);
  Future<void> previous() async => _invoke?.call('previous', []);
  Future<void> toProgress(double progress) async =>
      _invoke?.call('progress', [progress]);

  /// Excel navigation operates on the live worksheet, not document pages.
  Future<void> selectSheet(int index) async => _invoke?.call('selectSheet', [index]);
  Future<void> zoomSheet(double factor) async => _invoke?.call('zoomBy', [factor]);
  Future<void> resetSheetZoom() async => _invoke?.call('resetZoom', []);

  /// 한글·워드 스크롤 보기: 전체 중 비율 위치(0~1)로 바로 이동 (오른쪽 회색 막대)
  Future<void> scrollToRatio(double ratio) async => _invoke?.call('scrollToRatio', [ratio]);

  // ── 파일 내 단어 검색 ──
  Future<Object?> Function(String, List<Object?>)? _query;

  /// 찾은 곳 수 (못 찾거나 아직 열리지 않았으면 0)
  /// 마지막으로 찾은 곳들이 있는 쪽 (스크롤 보기에서 그 쪽으로 옮길 때)
  List<int> lastSearchPages = const [];

  Future<int> search(String text) async {
    final result = await _query?.call('search', [text]);
    if (result is Map) {
      final pages = result['pages'];
      lastSearchPages = pages is List ? [for (final p in pages) (p as num?)?.toInt() ?? 0] : const [];
      return (result['count'] as num?)?.toInt() ?? 0;
    }
    lastSearchPages = const [];
    return 0;
  }

  Future<void> showSearchResult(int index) async => _query?.call('showSearchResult', [index]);
  Future<void> clearSearch() async => _query?.call('clearSearch', []);

  /// PPT: 슬라이드 전체 그림(JPEG base64) — 글자가 그림으로만 된 슬라이드의 글자를 읽는 데 씀
  Future<String?> slideImage(int index, {int width = 1800}) async {
    final result = await _query?.call('slideImage', [index, width]);
    return result is String && result.isNotEmpty ? result : null;
  }

  /// 지금 보이는 쪽이 화면에서 차지하는 자리 (0~1 비율). 모르면 null
  /// 모든 쪽의 높이/너비 (스크롤 보기에서 쪽 자리를 먼저 잡아 둘 때). 모르면 null
  Future<List<double>?> pageAspects() async {
    try {
      final r = await _query?.call('pageSizes', []);
      if (r is! List || r.isEmpty) return null;
      final out = <double>[];
      for (final e in r) {
        if (e is! List || e.length < 2) return null;
        final double w = (e[0] as num?)?.toDouble() ?? 0, h = (e[1] as num?)?.toDouble() ?? 0;
        if (w <= 0 || h <= 0) return null;
        out.add(h / w);
      }
      return out;
    } catch (_) {
      return null;
    }
  }

  Future<Rect?> pageRect() async {
    final r = await _query?.call('pageRect', []);
    if (r is! Map) return null;
    double v(Object? x) => (x as num?)?.toDouble() ?? 0;
    final rect = Rect.fromLTWH(v(r['x']), v(r['y']), v(r['w']), v(r['h']));
    return rect.width > 0.05 && rect.height > 0.05 ? rect : null;
  }

  /// 지금 화면에 보이는 글과 위치 [{t, x, y, w, h}] (화면 크기 대비 0~1) — 내보낸 PDF의 글자 층용
  Future<List<Map<String, Object?>>> visibleTextBoxes() async {
    final result = await _query?.call('visibleTextBoxes', []);
    if (result is! List) return const [];
    return [
      for (final b in result)
        if (b is Map) {'t': b['t'], 'x': b['x'], 'y': b['y'], 'w': b['w'], 'h': b['h']},
    ];
  }

  /// 쪽마다의 글 [from, to) — '목차' 쪽 찾기용 (지원하지 않으면 빈 목록)
  Future<List<String>> pageText(int from, int to) async {
    final result = await _query?.call('pageText', [from, to]);
    if (result is! List) return const [];
    return [for (final t in result) (t ?? '').toString()];
  }

  /// 목차 후보: 번호로 시작하거나 굵은 글씨가 있는 짧은 문단들 {title, page(0부터), bold, boldRatio, centered, fs}.
  /// 한글은 [from, to) 쪽만 (워드는 한 번에 전부)
  Future<List<Map<String, Object?>>> headingCandidates(int from, int to) async {
    final result = await _query?.call('headingCandidates', [from, to]);
    if (result is! List) return const [];
    return [
      for (final item in result)
        if (item is Map && item['page'] is num)
          {
            'title': (item['title'] ?? '').toString(),
            'page': (item['page'] as num).toInt(),
            'bold': item['bold'] == true,
            'boldRatio': (item['boldRatio'] as num?)?.toDouble() ?? 0,
            'centered': item['centered'] == true,
            'fs': (item['fs'] as num?)?.toDouble() ?? 0,
            'body': (item['body'] as num?)?.toDouble() ?? 0,
          },
    ];
  }

  /// PPT: [from, to) 슬라이드마다 줄들 {t, y, fs, bold}
  Future<List<List<Map<String, Object?>>>> slideLineData(int from, int to) async {
    final result = await _query?.call('slideLineData', [from, to]);
    if (result is! List) return const [];
    return [
      for (final slide in result)
        [
          if (slide is List)
            for (final l in slide)
              if (l is Map) {'t': (l['t'] ?? '').toString(), 'y': (l['y'] as num?)?.toDouble() ?? 0, 'fs': (l['fs'] as num?)?.toDouble() ?? 0, 'bold': l['bold'] == true},
        ],
    ];
  }
}

class HwpViewer extends StatefulWidget {
  final String filePath;
  final HwpReaderController controller;
  final String? initialPosition;
  final double initialProgress;
  final String theme;
  final bool spread;
  final bool rtl;
  final ValueChanged<int> onLoaded;
  final void Function(int page, int pageCount, String position, double progress)
  onLocation;
  final ValueChanged<String> onError;
  final VoidCallback onCancelled;
  /// 쪽 안의 그림까지 다 그려졌을 때 (워드·한글)
  final ValueChanged<int>? onPageReady;
  /// 파워포인트: 지금 슬라이드에서 남은 애니메이션 단계 수 (위치가 바뀔 때마다)
  final ValueChanged<int>? onStepsLeft;
  final ValueChanged<List<String>>? onSheetNames;

  /// 한글·워드 스크롤 보기: 쪽을 세로로 늘어놓고 문서 화면 안에서 굴림
  final bool vertical;

  /// 스크롤 보기에서 지금 위치·전체 길이·보이는 높이 (오른쪽 회색 막대)
  final void Function(double top, double height, double client)? onScrollMetrics;

  const HwpViewer({
    super.key,
    required this.filePath,
    required this.controller,
    this.initialPosition,
    this.initialProgress = 0,
    required this.theme,
    required this.spread,
    required this.rtl,
    required this.onLoaded,
    required this.onLocation,
    required this.onError,
    required this.onCancelled,
    this.onPageReady,
    this.onStepsLeft,
    this.onSheetNames,
    this.vertical = false,
    this.onScrollMetrics,
  });

  @override
  State<HwpViewer> createState() => _HwpViewerState();
}

class _HwpViewerState extends State<HwpViewer> {
  static const _origin = 'https://appassets.androidplatform.net';
  bool get _isDocx => widget.filePath.toLowerCase().endsWith('.docx');
  bool get _isDoc => widget.filePath.toLowerCase().endsWith('.doc');
  bool get _isWord => _isDocx || _isDoc;
  bool get _isHwp => RegExp(r'\.hwpx?$', caseSensitive: false).hasMatch(widget.filePath);
  // 파워포인트(.ppt/.pptx)도 같은 문서 화면에서 연다
  bool get _isPresentation => RegExp(r'\.pptx?$', caseSensitive: false).hasMatch(widget.filePath);
  bool get _isSpreadsheet => RegExp(r'\.xls[xm]?$', caseSensitive: false).hasMatch(widget.filePath);
  String get _spreadsheetFormat => widget.filePath.split('.').last.toLowerCase();
  String get _presentationFormat => widget.filePath.toLowerCase().endsWith('.pptx') ? 'pptx' : 'ppt';
  String get _format => _isSpreadsheet ? _spreadsheetFormat.toUpperCase() : _isPresentation ? _presentationFormat.toUpperCase() : _isDocx
      ? 'DOCX'
      : _isDoc
      ? 'DOC'
      : 'HWP';
  String get _entry =>
      '$_origin/assets/flutter_assets/assets/${_isSpreadsheet ? 'xlsx' : _isPresentation ? 'ppt' : _isWord ? 'docx' : 'hwp'}/index.html';
  /// 표시 파일을 못 불러왔을 때: 앱 안에 그 파일이 아예 없으면(빌드에 빠짐) 무엇이 빠졌는지 알려 준다
  Future<void> _reportMissingAsset(String url, String description) async {
    // 없어도 되는 글꼴(같은 폭 무료 글꼴·사용자 글꼴)은 못 불러와도 기본 글꼴로 계속 보여 줌
    if (url.contains('/fonts/metric/') || url.contains('/fonts/free/') || url.contains('/userfonts/')) return;
    final marker = '$_origin/assets/flutter_assets/';
    if (url.startsWith(marker)) {
      final asset = Uri.decodeComponent(url.substring(marker.length).split('?').first);
      try {
        await rootBundle.load(asset);
      } catch (_) {
        final folder = asset.contains('/') ? asset.substring(0, asset.lastIndexOf('/')) : asset;
        _reportError('앱 안에 표시 파일($asset)이 없어요\nGitHub에 $folder 폴더가 올라가 있는지, '
            'pubspec.yaml이 새 버전인지 확인한 뒤 다시 빌드해 주세요');
        return;
      }
    }
    _reportError('문서 표시 파일을 불러오지 못했어요: $description');
  }

  String get _jsObject => _isSpreadsheet ? 'freaderXlsx' : _isPresentation ? 'freaderPpt' : _isWord ? 'freaderDocx' : 'freaderHwp';
  Map<String, Object> _docxLayout = {};
  static const _maxBytes = 256 * 1024 * 1024;
  static const _chunkBytes = 192 * 1024;
  InAppWebViewController? _web;
  RandomAccessFile? _file;
  Timer? _timeout;
  bool _started = false;
  bool _loaded = false;
  bool _failed = false;
  bool _passwordOpen = false;
  bool _disposed = false;
  int _generation = 0;

  Map<String, Object?> get _options => {
    'theme': widget.theme,
    // 쪽 뒤 바탕: 한글·워드는 뷰어 배경 설정(라이트=흰색, 다크=검은색)을 따름 (문서 자체 배경색이 있으면 그 색이 먼저)
    if (_isWord || _isHwp) 'backdrop': widget.theme == 'dark' ? '#000000' : '#ffffff',
    'spread': widget.spread,
    'rtl': widget.rtl,
    'position': widget.initialPosition,
    'progress': widget.initialProgress,
    if (_isWord || _isHwp) 'vertical': widget.vertical,
    if (_isWord) 'format': _isDoc ? 'doc' : 'docx',
    if (_isPresentation) 'format': _presentationFormat,
    if (_isSpreadsheet) 'format': _spreadsheetFormat,
    if (_isDocx) 'docxLayout': _docxLayout,
    if (_cacheKey != null) 'cacheKey': _cacheKey,
    if (_userFonts.isNotEmpty) 'userFonts': _userFonts,
  };
  /// 사용자가 넣은 글꼴 (같은 이름의 글꼴 대신 씀)
  List<Map<String, Object>> _userFonts = const [];
  /// 처음 열 때 파일을 넘기는 진행률 (0~1)
  final ValueNotifier<double?> _loadProgress = ValueNotifier<double?>(0);
  /// 파일이 바뀌면 달라지는 열쇠 (변환된 그림 저장소 이름에 사용)
  String? _cacheKey;

  @override
  void initState() {
    super.initState();
    widget.controller._invoke = _navigate;
    widget.controller._query = _ask;
    _armTimeout();
  }

  void _armTimeout() {
    _timeout?.cancel();
    _timeout = Timer(const Duration(minutes: 5), () {
      _reportError(
        '$_format 문서 표시 시간이 초과됐어요\nAndroid System WebView와 파일 상태를 확인해 주세요',
      );
    });
  }

  void _reportError(Object error) {
    if (_disposed || _failed || !mounted) return;
    _failed = true;
    _timeout?.cancel();
    unawaited(_closeFile());
    widget.onError(error.toString());
  }

  Future<void> _closeFile() async {
    final file = _file;
    _file = null;
    if (file != null) {
      try {
        await file.close();
      } catch (_) {
        /* A pending read can finish while closing. */
      }
    }
  }

  Future<void> _invoke(String method, List<Object?> args) async {
    if (_disposed || _failed || _web == null) return;
    try {
      final result = await _web!.callAsyncJavaScript(
        functionBody: 'return await window[viewer][method](...args);',
        arguments: {'viewer': _jsObject, 'method': method, 'args': args},
      );
      if (result?.error != null) throw StateError(result!.error!);
    } catch (error) {
      _reportError(error);
    }
  }

  /// 결과를 돌려받는 호출 (검색). 실패해도 문서 오류로 띄우지 않는다.
  Future<Object?> _ask(String method, List<Object?> args) async {
    if (_disposed || _failed || _web == null || !_loaded) return null;
    try {
      final result = await _web!.callAsyncJavaScript(
        functionBody: 'return await window[viewer][method](...args);',
        arguments: {'viewer': _jsObject, 'method': method, 'args': args},
      );
      return result?.error == null ? result?.value : null;
    } catch (_) {
      return null;
    }
  }

  Future<void> _navigate(String method, List<Object?> args) async {
    // Hardware keys and the existing toolbar can be used during initialization.
    if (!_loaded) return;
    await _invoke(method, args);
  }

  Future<void> _transferDocument() async {
    if (_started || _disposed || _failed) return;
    _started = true;
    final generation = ++_generation;
    try {
      final source = File(widget.filePath);
      final length = await source.length();
      try {
        final modified = (await source.lastModified()).millisecondsSinceEpoch;
        _cacheKey = '${widget.filePath.hashCode.toUnsigned(32)}-$length-$modified';
      } catch (_) {}
      if (length < 1 || length > _maxBytes) {
        throw const FormatException('비어 있거나 256MB를 초과하는 문서예요');
      }
      if (_isDocx) {
        final path = widget.filePath;
        _docxLayout = await Isolate.run(() => DocxLayoutHints.readLayout(path));
      }
      try {
        _userFonts = await UserFonts.forViewer();
      } catch (_) {}
      if (_disposed || !mounted) return;
      await _invoke('beginDocument', [length, _options]);
      if (_failed || _disposed) return;
      final opened = await source.open();
      if (_disposed) {
        await opened.close();
        return;
      }
      _file = opened;
      var offset = 0;
      while (offset < length &&
          !_disposed &&
          !_failed &&
          generation == _generation) {
        final chunk = await opened.read(_chunkBytes);
        if (chunk.isEmpty)
          throw const FormatException('문서를 읽는 중 파일 크기가 바뀌었어요');
        await _invoke('appendChunk', [offset, base64Encode(chunk)]);
        offset += chunk.length;
        _loadProgress.value = 0.9 * offset / length;
        _armTimeout();
      }
      await _closeFile();
      if (!_disposed && !_failed && generation == _generation)
        await _invoke('openDocument', [null]);
    } catch (error) {
      _reportError(error);
    } finally {
      await _closeFile();
    }
  }

  void _event(List<dynamic> args) {
    if (_disposed || _failed || !mounted || args.isEmpty || args.first is! Map)
      return;
    final event = Map<String, dynamic>.from(args.first as Map);
    switch (event['type']) {
      case 'ready':
        unawaited(_transferDocument());
        break;
      // 엑셀: 칸을 길게 눌러 고른 뒤 손을 떼면 그 글을 복사 창으로
      case 'haptic':
        HapticFeedback.selectionClick();
        if (_isSpreadsheet) widget.controller.cellSelected = true;
        break;
      case 'selectionCleared':
        widget.controller.cellSelected = false;
        _cellBar.hide();
        break;
      case 'scrollMetrics':
        double n(Object? v) => v is num ? v.toDouble() : 0;
        widget.onScrollMetrics?.call(n(event['top']), n(event['height']), n(event['client']));
        break;
      // 엑셀: 칸을 길게 눌러 고른 뒤 손을 떼면 [복사 | 모두 선택 | 공유] 막대
      case 'copyText':
        final text = (event['text'] ?? '').toString();
        if (text.trim().isEmpty) break;
        _showCellBar(text, event['x'], event['y']);
        break;
      case 'loaded':
        setState(() => _loaded = true);
        _timeout?.cancel();
        unawaited(_invoke('configure', [_options]));
        widget.onLoaded((event['pageCount'] as num).toInt());
        if (_isSpreadsheet && event['chapters'] is List) {
          widget.onSheetNames?.call([for (final name in event['chapters'] as List) name.toString()]);
        }
        break;
      case 'location':
        if (!_loaded) return;
        final stepCount = event['stepCount'], step = event['step'];
        if (stepCount is num) widget.onStepsLeft?.call((stepCount - (step is num ? step : 0)).toInt());
        widget.onLocation(
          (event['page'] as num).toInt(),
          (event['pageCount'] as num).toInt(),
          event['position'] as String,
          (event['progress'] as num).toDouble(),
        );
        break;
      case 'pageReady':
        if (_loaded) widget.onPageReady?.call((event['page'] as num?)?.toInt() ?? -1);
        break;
      case 'password':
        unawaited(_requestPassword(event['incorrect'] == true));
        break;
      case 'error':
        _reportError(event['message'] ?? '$_format 문서를 표시하지 못했어요');
        break;
    }
  }

  Future<void> _requestPassword(bool incorrect) async {
    if (_passwordOpen || _disposed || !mounted) return;
    _passwordOpen = true;
    _timeout?.cancel();
    final input = TextEditingController();
    final password = await showPopDialog<String>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('문서 비밀번호'),
        content: TextField(
          controller: input,
          obscureText: true,
          autofocus: true,
          autocorrect: false,
          enableSuggestions: false,
          decoration: InputDecoration(
            labelText: '비밀번호',
            errorText: incorrect ? '비밀번호가 일치하지 않아요' : null,
          ),
          onSubmitted: (value) => Navigator.pop(context, value),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: const Text('취소'),
          ),
          TextButton(
            onPressed: () => Navigator.pop(context, input.text),
            child: const Text('열기'),
          ),
        ],
      ),
    );
    // Allow the closing dialog animation to release its TextField first.
    Future<void>.delayed(const Duration(milliseconds: 350), input.dispose);
    _passwordOpen = false;
    if (_disposed || !mounted) return;
    if (password == null) {
      widget.onCancelled();
      return;
    }
    _armTimeout();
    await _invoke('openDocument', [password]);
  }

  @override
  void didUpdateWidget(covariant HwpViewer oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.controller != widget.controller) {
      oldWidget.controller._invoke = null;
      oldWidget.controller._query = null;
      widget.controller._invoke = _navigate;
    widget.controller._query = _ask;
    }
    if (_loaded &&
        (oldWidget.theme != widget.theme ||
            oldWidget.spread != widget.spread ||
            oldWidget.rtl != widget.rtl ||
            oldWidget.vertical != widget.vertical)) {
      unawaited(_invoke('configure', [_options]));
    }
    // 스크롤 보기: 문서 화면 안에서 위아래로 굴릴 수 있게
    if (oldWidget.vertical != widget.vertical) {
      unawaited(_web?.setSettings(settings: InAppWebViewSettings(disableVerticalScroll: false, disableHorizontalScroll: !_isSpreadsheet && !widget.vertical)));
    }
  }

  Orientation? _orientation;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    // 화면을 돌렸을 때: 스크롤 보기 설정을 다시 맞춤 (가로 화면에서도 위아래로 굴러가게)
    final o = MediaQuery.orientationOf(context);
    if (_orientation != null && o != _orientation && _loaded && widget.vertical) {
      unawaited(_web?.setSettings(settings: InAppWebViewSettings(disableVerticalScroll: false, disableHorizontalScroll: false)));
      unawaited(_invoke('configure', [_options]));
    }
    _orientation = o;
  }

  @override
  void dispose() {
    _cellBar.hide();
    _disposed = true;
    _generation++;
    _timeout?.cancel();
    widget.controller._invoke = null;
    widget.controller._query = null;
    unawaited(_closeFile());
    // The platform view owns its controller and releases the WASM heap on close.
    _web = null;
    super.dispose();
  }

  String _tr(String ko, String en, String zh, String ja) =>
      AppI18n.t(StorageService.appLangNotifier.value, ko: ko, en: en, zh: zh, ja: ja);

  final FloatingSelectionBar _cellBar = FloatingSelectionBar();

  /// 엑셀에서 고른 칸들 위에 막대를 띄움 ([x], [y]: 문서 화면 기준 누른 자리, 화면 크기 대비 아님)
  void _showCellBar(String text, Object? x, Object? y) {
    if (!mounted) return;
    final box = context.findRenderObject() as RenderBox?;
    final Offset local = Offset((x as num?)?.toDouble() ?? 0, (y as num?)?.toDouble() ?? 0);
    final Offset global = box == null ? local : box.localToGlobal(local);
    _cellBar.show(
      context,
      global,
      tr: _tr,
      onCopy: () {
        _cellBar.hide();
        copyText(context, text, _tr);
      },
      onSelectAll: () {
        _cellBar.hide();
        unawaited(_invoke('selectAllCells', []));
      },
      onShare: () {
        _cellBar.hide();
        shareText(text);
      },
    );
  }

  Future<void> _clearSelection() async {
    try {
      await _web?.evaluateJavascript(source: 'try{window.getSelection().removeAllRanges()}catch(e){}');
    } catch (_) {}
  }

  @override
  Widget build(BuildContext context) {
    return Stack(
      fit: StackFit.expand,
      children: [
        InAppWebView(
          // Excel owns two-dimensional pan and pinch; the outer reader still owns its toolbar.
          // 한글·워드: 글을 길게 누르면 문서 화면이 바로 받아 글을 고를 수 있게 (EPUB과 같은 방식)
          // 엑셀·한글/워드 스크롤 보기: 손가락이 닿자마자 문서 화면이 받아 직접 굴림
          // (Flutter가 세로 밀기인지 판단할 때까지 터치를 붙잡아 두면 가로 화면·화면 가장자리에서 스크롤이 잘 안 됐음.
          //  화면 누르기(메뉴)는 바깥 Listener가 따로 받음)
          // 주의: WebView는 처음 만들 때 받은 목록을 계속 써서 (나중에 목록을 바꿔도 반영 안 됨)
          // 슬라이드→스크롤로 바꾸면 스크롤이 먹통이 됐었음. 그래서 목록은 그대로 두고, 누를 때마다 지금 보기 방식을 확인함
          gestureRecognizers: {
            Factory<OneSequenceGestureRecognizer>(() => _ModeEagerRecognizer(() => mounted && (_isSpreadsheet || widget.vertical))),
            Factory<LongPressGestureRecognizer>(() => LongPressGestureRecognizer(duration: const Duration(milliseconds: 350))),
          },
          initialUrlRequest: URLRequest(url: WebUri(_entry)),
          initialSettings: InAppWebViewSettings(
            javaScriptEnabled: true,
            transparentBackground: true,
            supportZoom: false,
            // Android consumes ACTION_MOVE when both flags are true. That
            // prevents the canvas from receiving either drag or pinch events.
            // Excel controls its own viewport; CSS prevents page scrolling.
            disableHorizontalScroll: !_isSpreadsheet && !widget.vertical,
            disableVerticalScroll: !_isSpreadsheet && !widget.vertical,
            horizontalScrollBarEnabled: false,
            verticalScrollBarEnabled: false,
            allowFileAccess: false,
            allowContentAccess: false,
            javaScriptHandlersForMainFrameOnly: true,
            javaScriptHandlersOriginAllowList: {_origin},
            useShouldOverrideUrlLoading: true,
            webViewAssetLoader: WebViewAssetLoader(
              pathHandlers: [
                AssetsPathHandler(path: '/assets/'),
                if (UserFonts.cachedDirPath != null)
                  InternalStoragePathHandler(path: UserFonts.urlPath, directory: UserFonts.cachedDirPath!),
              ],
            ),
          ),
          // 글을 길게 눌러 고르면 휴대폰 기본 메뉴(복사 | 모두 선택 | 공유)와 형광펜 칠하기
          contextMenu: ContextMenu(
            settings: ContextMenuSettings(hideDefaultSystemContextMenuItems: false),
            menuItems: [
              ContextMenuItem(
                id: 1,
                title: _tr('형광펜 칠하기', 'Highlight', '荧光笔', 'マーカー'),
                action: () async {
                  await _invoke('highlightSelection', []);
                  await _clearSelection();
                },
              ),
            ],
          ),
          onWebViewCreated: (controller) {
            _web = controller;
            controller.addJavaScriptHandler(
              handlerName: _jsObject,
              callback: (args) {
                _event(args);
                return null;
              },
            );
          },
          onLoadStop: (controller, url) async {
            // Recover a missed platform-ready event without re-opening a document.
            try {
              final ready = await controller.evaluateJavascript(
                source: 'window.$_jsObject?.getState().ready === true',
              );
              if (ready == true) unawaited(_transferDocument());
            } catch (error) {
              _reportError(error);
            }
          },
          shouldOverrideUrlLoading: (controller, action) async =>
              action.request.url?.toString() == _entry
              ? NavigationActionPolicy.ALLOW
              : NavigationActionPolicy.CANCEL,
          onReceivedError: (controller, request, error) {
            if (request.isForMainFrame == true ||
                request.url.toString().startsWith('$_origin/assets/')) {
              unawaited(_reportMissingAsset(request.url.toString(), error.description));
            }
          },
          onReceivedHttpError: (controller, request, response) {
            if ((response.statusCode ?? 0) >= 400)
              _reportError('문서 표시 파일 오류 (${response.statusCode})');
          },
          onRenderProcessGone: (controller, detail) async {
            _reportError('문서 표시 프로세스가 종료됐어요\n문서를 다시 열어 주세요');
          },
        ),
        // 처음 열 때: 돌아가는 원 + '파일 여는 중 n%' (파일을 넘기는 동안 진행률)
        if (!_loaded)
          ValueListenableBuilder<double?>(
            valueListenable: _loadProgress,
            builder: (context, p, _) => FileLoadingView(label: AppI18n.t(StorageService.appLangNotifier.value, ko: '파일 여는 중', en: 'Opening file', zh: '正在打开文件', ja: 'ファイルを開いています'), progress: p, background: widget.theme == 'dark' ? const Color(0xFF1E1E1E) : Colors.white),
          ),
      ],
    );
  }
}

/// 켜져 있을 때만 손가락이 닿자마자 문서 화면(WebView)이 터치를 바로 가져가게 함 (스크롤 보기·엑셀)
class _ModeEagerRecognizer extends OneSequenceGestureRecognizer {
  _ModeEagerRecognizer(this.active);
  final bool Function() active;

  @override
  bool isPointerAllowed(PointerDownEvent event) => active() && super.isPointerAllowed(event);

  @override
  void addAllowedPointer(PointerDownEvent event) {
    super.addAllowedPointer(event);
    resolve(GestureDisposition.accepted);
    stopTrackingPointer(event.pointer);
  }

  @override
  String get debugDescription => 'mode eager';

  @override
  void didStopTrackingLastPointer(int pointer) {}

  @override
  void handleEvent(PointerEvent event) {}
}
