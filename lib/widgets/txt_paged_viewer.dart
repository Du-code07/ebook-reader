import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:path_provider/path_provider.dart';

import '../services/txt_page_document.dart';
import 'viewer_dialogs.dart';
import '../services/storage_service.dart';

class TxtPageController {
  Future<void> Function(String, Object?)? _invoke;
  Future<void> next() async => _invoke?.call('next', null);
  Future<void> previous() async => _invoke?.call('previous', null);
  Future<void> display(String position) async =>
      _invoke?.call('display', position);
  Future<void> toProgress(double progress) async =>
      _invoke?.call('progress', progress);

  String Function()? _visible;

  /// 지금 화면에 보이는 쪽의 글 (글자 복사용)
  String get visibleText => _visible?.call() ?? '';
}

/// Keeps the existing ReaderScreen toolbar, gestures, bookmarks and memos.
/// TXT is still the document's identity; only its display uses fixed paper pages.
class TxtPagedViewer extends StatefulWidget {
  final String filePath;
  final TxtPageController controller;
  final String? initialPosition;
  final double initialProgress;
  final String theme;
  final bool spread;
  final bool rtl;

  /// 스크롤 모드: 쪽을 간격 없이 세로로 이어 보여 줌
  final bool scroll;
  final ContinuousPageController? scrollController;
  final ValueChanged<int> onLoaded;
  final void Function(int, int, String, double) onLocation;
  final ValueChanged<String> onError;

  const TxtPagedViewer({
    super.key,
    required this.filePath,
    required this.controller,
    this.initialPosition,
    this.initialProgress = 0,
    required this.theme,
    required this.spread,
    required this.rtl,
    this.scroll = false,
    this.scrollController,
    required this.onLoaded,
    required this.onLocation,
    required this.onError,
  });

  @override
  State<TxtPagedViewer> createState() => _TxtPagedViewerState();
}

class _TxtPagedViewerState extends State<TxtPagedViewer> {
  TxtPageDocument? _document;
  List<String> _visibleText = const [];
  int _page = 0;
  int _request = 0;
  final Map<int, Future<String>> _scrollCache = {};
  bool _disposed = false;

  @override
  void initState() {
    super.initState();
    widget.controller._invoke = _navigate;
    widget.controller._visible = () => _visibleText.join('\n\n');
    unawaited(_load());
  }

  Future<void> _load() async {
    try {
      final cache = await getTemporaryDirectory();
      if (_disposed) return;
      final doc = await TxtPageDocument.open(
        File(widget.filePath),
        cache,
        cancelled: () => _disposed,
      );
      if (_disposed) {
        await doc.dispose();
        return;
      }
      _document = doc;
      final saved = RegExp(
        r'^txt:(\d+)$',
      ).firstMatch(widget.initialPosition ?? '');
      final page = saved != null
          ? int.parse(saved[1]!)
          : (widget.initialProgress.clamp(0.0, 1.0) * (doc.pageCount - 1))
                .round();
      widget.onLoaded(doc.pageCount);
      await _show(page);
    } on TxtPaginationCancelled {
      // Leaving the reader cancels preparation and removes its temporary files.
    } catch (error) {
      if (!_disposed && mounted) widget.onError(error.toString());
    }
  }

  Future<void> _show(int requested) async {
    final doc = _document;
    if (doc == null || _disposed) return;
    final request = ++_request;
    var page = requested.clamp(0, doc.pageCount - 1).toInt();
    if (widget.spread) page = page ~/ 2 * 2;
    _page = page; // Rapid hardware keys advance from the latest requested page.
    try {
      final text = [await doc.readPage(page)];
      if (widget.spread && page + 1 < doc.pageCount) {
        text.add(await doc.readPage(page + 1));
      }
      if (_disposed || !mounted || request != _request) return;
      setState(() => _visibleText = text);
      final lastVisible = widget.spread && page + 1 < doc.pageCount
          ? page + 1
          : page;
      widget.onLocation(
        page,
        doc.pageCount,
        'txt:$page',
        doc.pageCount <= 1 ? 0 : lastVisible / (doc.pageCount - 1),
      );
    } catch (error) {
      if (!_disposed && mounted && request == _request)
        widget.onError(error.toString());
    }
  }

  Future<void> _navigate(String method, Object? value) async {
    final doc = _document;
    if (doc == null) return;
    final step = widget.spread ? 2 : 1;
    switch (method) {
      case 'next':
        await _show(_page + step);
      case 'previous':
        await _show(_page - step);
      case 'display':
        final match = RegExp(r'^txt:(\d+)$').firstMatch(value.toString());
        if (match != null && widget.scroll) {
          widget.scrollController?.jumpToPage(int.parse(match[1]!));
          return;
        }
        if (match != null) await _show(int.parse(match[1]!));
      case 'progress':
        await _show(
          ((value as double).clamp(0.0, 1.0) * (doc.pageCount - 1)).round(),
        );
    }
  }

  @override
  void didUpdateWidget(covariant TxtPagedViewer oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.spread != widget.spread || oldWidget.scroll != widget.scroll) unawaited(_show(_page));
  }

  @override
  void dispose() {
    _disposed = true;
    widget.controller._invoke = null;
    final doc = _document;
    if (doc != null) unawaited(doc.dispose());
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final background = widget.theme == 'dark'
        ? const Color(0xff1e1e1e)
        : widget.theme == 'sepia'
        ? const Color(0xfffbf0d9)
        : Colors.white;
    final foreground = widget.theme == 'dark'
        ? const Color(0xffd4d4d4)
        : widget.theme == 'sepia'
        ? const Color(0xff3b2f2f)
        : Colors.black;
    Widget paper(String text) => FittedBox(
      fit: BoxFit.contain,
      alignment: Alignment.topCenter,
      child: SizedBox.fromSize(
        size: TxtPageDocument.paperSize,
        child: CustomPaint(painter: _TxtPaperPainter(text, foreground)),
      ),
    );
    if (widget.scroll && _document != null) return _buildScroll(background, foreground, paper);
    final children = _visibleText
        .map((text) => Expanded(child: paper(text)))
        .toList();
    if (widget.spread && children.length == 1)
      children.add(const Expanded(child: SizedBox()));
    return ColoredBox(
      color: background,
      child: _visibleText.isEmpty
          ? FileLoadingView(label: AppI18n.t(StorageService.appLangNotifier.value, ko: '파일 여는 중', en: 'Opening file', zh: '正在打开文件', ja: 'ファイルを開いています'))
          : Row(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: widget.rtl && widget.spread
                  ? children.reversed.toList()
                  : children,
            ),
    );
  }
}

extension on _TxtPagedViewerState {
  /// 스크롤 모드: 종이 쪽들을 세로로 이어 붙임 (보이는 쪽 근처만 그때그때 읽어 둠)
  Widget _buildScroll(Color background, Color foreground, Widget Function(String) paper) {
    final doc = _document!;
    final double aspect = TxtPageDocument.paperSize.height / TxtPageDocument.paperSize.width;
    return ContinuousPageList(
      controller: widget.scrollController,
      count: doc.pageCount,
      aspectOf: (_) => aspect,
      initialPage: _page,
      background: background,
      zoomable: false,
      onPageChanged: (p) {
        _page = p;
        widget.onLocation(p, doc.pageCount, 'txt:$p', doc.pageCount <= 1 ? 0 : p / (doc.pageCount - 1));
      },
      pageBuilder: (ctx, i) => ColoredBox(
        color: background,
        child: FutureBuilder<String>(
          future: _scrollText(i),
          builder: (ctx, snap) => snap.hasData ? paper(snap.data!) : const SizedBox.expand(),
        ),
      ),
    );
  }

  Future<String> _scrollText(int i) {
    final cache = _scrollCache;
    final hit = cache[i];
    if (hit != null) return hit;
    if (cache.length > 40) cache.remove(cache.keys.first);
    return cache[i] = _document!.readPage(i);
  }
}

class _TxtPaperPainter extends CustomPainter {
  final String text;
  final Color color;
  _TxtPaperPainter(this.text, this.color);

  @override
  void paint(Canvas canvas, Size size) {
    final layout = TxtPageDocument.painter(text, color: color);
    layout.paint(
      canvas,
      const Offset(TxtPageDocument.margin, TxtPageDocument.margin),
    );
    layout.dispose();
  }

  @override
  bool shouldRepaint(covariant _TxtPaperPainter oldDelegate) =>
      text != oldDelegate.text || color != oldDelegate.color;
}
