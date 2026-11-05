import 'dart:async';
import 'dart:io';
import 'dart:math' as math;
import 'dart:ui' as ui;
import 'package:archive/archive.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:google_mlkit_text_recognition/google_mlkit_text_recognition.dart';
import 'package:path_provider/path_provider.dart';
import '../services/batch_translation_service.dart';
import '../services/storage_service.dart';
import '../services/volume_key_service.dart';

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
    }
    if (_bubblesByPage.isNotEmpty) {
      _showTranslatedBubbles = true;
    }

    _volumeKeyService.startListening(
      onVolumeUp: () => _stepPage(-1),
      onVolumeDown: () => _stepPage(1),
    );

    if (mounted) {
      setState(() => _isPreparingPages = false);
      WidgetsBinding.instance.addPostFrameCallback((_) {
        _syncControllerToCurrentPage(animate: false);
      });
    }
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
    setState(() => _showControls = !_showControls);
    SystemChrome.setEnabledSystemUIMode(SystemUiMode.immersiveSticky);
  }

  Future<void> _showLanguageAndTranslateDialog({bool forceRetranslate = false}) async {
    final currentGugugoUrl = await StorageService.getGugugoServerUrl();
    final currentHfToken = await StorageService.getGugugoHfToken();
    final urlCtrl = TextEditingController(text: currentGugugoUrl);
    final tokenCtrl = TextEditingController(text: currentHfToken);
    bool showAdvanced = currentGugugoUrl.isNotEmpty || currentHfToken.isNotEmpty;

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
                const Text('원문 언어를 선택하세요 (기본값: 일본어):', style: TextStyle(fontSize: 13)),
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
                const SizedBox(height: 4),
                TextButton.icon(
                  style: TextButton.styleFrom(padding: EdgeInsets.zero),
                  icon: Icon(showAdvanced ? Icons.expand_less : Icons.expand_more, size: 18),
                  label: const Text('Gugugo 서버 / HuggingFace 토큰 설정 (선택사항)', style: TextStyle(fontSize: 12)),
                  onPressed: () => setModalState(() => showAdvanced = !showAdvanced),
                ),
                if (showAdvanced) ...[
                  const SizedBox(height: 6),
                  TextField(
                    controller: urlCtrl,
                    decoration: const InputDecoration(
                      labelText: 'Gugugo Gradio 서버 주소 (선택)',
                      hintText: '예: https://xxxx.gradio.live',
                      isDense: true,
                      border: OutlineInputBorder(),
                    ),
                    style: const TextStyle(fontSize: 12),
                  ),
                  const SizedBox(height: 8),
                  TextField(
                    controller: tokenCtrl,
                    decoration: const InputDecoration(
                      labelText: 'HuggingFace API 토큰 (선택)',
                      hintText: 'hf_...',
                      isDense: true,
                      border: OutlineInputBorder(),
                    ),
                    style: const TextStyle(fontSize: 12),
                  ),
                ],
              ],
            ),
          ),
          actions: [
            TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text('취소')),
            ElevatedButton(
              onPressed: () async {
                await StorageService.setGugugoApiConfig(
                  serverUrl: urlCtrl.text,
                  hfToken: tokenCtrl.text,
                );
                if (ctx.mounted) Navigator.pop(ctx, true);
              },
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

  Widget _buildVerticalKoreanText(BubbleTranslation b, double boxW, double boxH) {
    String clean = b.translatedText
        .replaceAll('\n', ' ')
        .replaceAll(RegExp(r'\s+'), ' ')
        .trim();
    if (clean.isEmpty) return const SizedBox.shrink();

    clean = clean
        .replaceAll('(', '︵')
        .replaceAll(')', '︶')
        .replaceAll('[', '︹')
        .replaceAll(']', '︺')
        .replaceAll('~', '≀')
        .replaceAll('—', '︱')
        .replaceAll('-', '︱');

    final chars = clean.runes.map((r) => String.fromCharCode(r)).toList();
    final int charCount = chars.length;

    final double safeW = math.max<double>(14.0, boxW - 3.0);
    final double safeH = math.max<double>(18.0, boxH - 3.0);
    final double aspect = safeH / safeW;

    int numCols = math.sqrt(charCount / math.max<double>(1.2, aspect * 0.85)).round();
    numCols = numCols.clamp(1, math.max<int>(1, charCount)).toInt();
    int charsPerCol = (charCount / numCols).ceil();
    if (charsPerCol < 2) charsPerCol = 2;
    numCols = (charCount / charsPerCol).ceil();

    final List<String> columns = [];
    for (int i = 0; i < charCount; i += charsPerCol) {
      final end = (i + charsPerCol < charCount) ? i + charsPerCol : charCount;
      columns.add(chars.sublist(i, end).join('\n'));
    }

    final double colW = safeW / columns.length;
    final double rowH = safeH / charsPerCol;
    final double fontSize = math.min<double>(colW * 0.82, rowH * 0.78).clamp(6.0, 20.0).toDouble();

    return FittedBox(
      fit: BoxFit.scaleDown,
      alignment: Alignment.center,
      child: Directionality(
        textDirection: TextDirection.rtl,
        child: Row(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: columns.map((colStr) {
            return Padding(
              padding: const EdgeInsets.symmetric(horizontal: 1.2),
              child: Text(
                colStr,
                textAlign: TextAlign.center,
                style: TextStyle(
                  color: const Color(0xFF111111),
                  fontSize: fontSize,
                  fontWeight: b.isBold ? FontWeight.w800 : FontWeight.w600,
                  fontFamily: b.isSerif ? 'serif' : 'sans-serif',
                  height: 1.05,
                ),
              ),
            );
          }).toList(),
        ),
      ),
    );
  }

  Widget _buildHorizontalKoreanText(BubbleTranslation b, double boxW, double boxH) {
    final double safeW = math.max<double>(16.0, boxW - 3.0);
    final double safeH = math.max<double>(12.0, boxH - 2.0);
    final double area = safeW * safeH;
    final double estFont = math.sqrt(area / math.max<int>(1, b.translatedText.length * 1.8)).clamp(6.5, 20.0).toDouble();

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
            color: const Color(0xFF111111),
            fontSize: estFont,
            fontWeight: b.isBold ? FontWeight.w800 : FontWeight.w600,
            fontFamily: b.isSerif ? 'serif' : 'sans-serif',
            height: 1.15,
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

                final bool renderVertically = b.isVertical && (boxH >= boxW * 1.05);

                return Positioned(
                  left: boxLeft,
                  top: boxTop,
                  width: boxW,
                  height: boxH,
                  child: Container(
                    padding: const EdgeInsets.all(1.0),
                    decoration: BoxDecoration(
                      color: Colors.white.withOpacity(0.96),
                      borderRadius: BorderRadius.circular(
                        renderVertically ? math.min<double>(boxW, boxH) * 0.15 : 4.0,
                      ),
                    ),
                    alignment: Alignment.center,
                    clipBehavior: Clip.hardEdge,
                    child: renderVertically
                        ? _buildVerticalKoreanText(b, boxW, boxH)
                        : _buildHorizontalKoreanText(b, boxW, boxH),
                  ),
                );
              }),
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
    final String pageIndicatorText = isSpread && (_currentPage + 1 < _totalPages)
        ? '${_currentPage + 1}-${_currentPage + 2} / $_totalPages 페이지'
        : '${_currentPage + 1} / $_totalPages 페이지';

    return Scaffold(
      backgroundColor: Colors.black,
      body: Stack(
        children: [
          Positioned.fill(
            child: GestureDetector(
              onTap: _toggleControls,
              child: PageView.builder(
                key: ValueKey('pageview_spread_$isSpread'),
                controller: _pageController,
                reverse: _isMangaRtlMode,
                physics: const BouncingScrollPhysics(),
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

          Positioned(
            left: 20,
            right: 20,
            bottom: math.max<double>(bottomInset + 4.0, 8.0),
            child: IgnorePointer(
              child: Align(
                alignment: Alignment.centerRight,
                child: Text(
                  pageIndicatorText,
                  style: const TextStyle(
                    color: Colors.white70,
                    fontSize: 12,
                    shadows: [Shadow(color: Colors.black, blurRadius: 4)],
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
                          style: const TextStyle(color: Colors.white, fontSize: 15),
                          overflow: TextOverflow.ellipsis,
                        ),
                      ),
                      if (_previousJumpPage != null)
                        IconButton(
                          icon: const Icon(Icons.restore, color: Colors.amber),
                          tooltip: '이전 페이지(${_previousJumpPage! + 1}p)로 돌아가기',
                          onPressed: () {
                            final target = _previousJumpPage!;
                            _previousJumpPage = null;
                            _goToPage(target, recordHistory: false, smoothAnimation: true);
                          },
                        ),
                      IconButton(
                        icon: Icon(
                          _enableTwoPageInLandscape ? Icons.menu_book : Icons.stay_current_portrait,
                          color: _enableTwoPageInLandscape ? Colors.amber : Colors.white,
                        ),
                        tooltip: '가로 모드 2페이지 보기 설정',
                        onPressed: () async {
                          final nextVal = !_enableTwoPageInLandscape;
                          await StorageService.setTwoPageLandscape(nextVal);
                          setState(() => _enableTwoPageInLandscape = nextVal);
                        },
                      ),
                      IconButton(
                        icon: Icon(
                          _isMangaRtlMode ? Icons.arrow_back : Icons.arrow_forward,
                          color: _isMangaRtlMode ? Colors.amber : Colors.white,
                        ),
                        tooltip: '방향',
                        onPressed: () {
                          setState(() => _isMangaRtlMode = !_isMangaRtlMode);
                          ScaffoldMessenger.of(context).showSnackBar(
                            const SnackBar(
                              content: Text('방향'),
                              duration: Duration(milliseconds: 800),
                            ),
                          );
                        },
                      ),
                      GestureDetector(
                        onLongPress: () => _showLanguageAndTranslateDialog(forceRetranslate: true),
                        child: IconButton(
                          icon: Icon(
                            _showTranslatedBubbles ? Icons.chat_bubble : Icons.translate,
                            color: _showTranslatedBubbles ? Colors.amber : Colors.white,
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
                          icon: const Icon(Icons.refresh, color: Colors.white70, size: 20),
                          tooltip: '다시 번역',
                          onPressed: () => _showLanguageAndTranslateDialog(forceRetranslate: true),
                        ),
                      IconButton(
                        icon: const Icon(Icons.bookmarks_outlined, color: Colors.white),
                        tooltip: '북마크',
                        onPressed: _showBookmarkSheet,
                      ),
                    ],
                  ),
                ),
              ),
            ),

          if (_showControls && _totalPages > 1)
            Positioned(
              top: 72.0,
              bottom: 48.0,
              right: 8.0,
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
                            value: _currentPage.toDouble().clamp(0.0, math.max<double>(0.0, (_totalPages - 1).toDouble())).toDouble(),
                            min: 0.0,
                            max: math.max<double>(1.0, (_totalPages - 1).toDouble()),
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
            ),
        ],
      ),
    );
  }
}
