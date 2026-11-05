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

  // 화면 터치 잠금 (음량 버튼 2개 동시 누름 시 해제)
  bool _isTouchLocked = false;

  // 페이지 전환 설정 3가지 (동시 사용 가능)
  bool _useVolumeTurn = true;
  bool _useQuickNavTurn = false;
  bool _useSpenTurn = true;

  // S펜 간단 메모 모드 상태
  bool _isMemoMode = false;
  final Map<int, List<MemoStroke>> _memoStrokesByPage = {};
  final Map<int, String> _memoNotesByPage = {};
  final List<Offset> _activeStrokePoints = [];
  Color _penColor = Colors.amber;
  final double _penWidth = 3.2;

  // 하단 정보 표시 설정 & 진행도 UI 위치 설정 ('right', 'left', 'bottom', 'hidden')
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
    if (_isTouchLocked || _isMemoMode) return;
    setState(() => _showControls = !_showControls);
    SystemChrome.setEnabledSystemUIMode(SystemUiMode.immersiveSticky);
  }

  /// 3. 두 화살표 간격을 좁히고, 색상은 왼쪽 아이콘과 동일한 Colors.amber로 맞춘 방향 아이콘
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

  /// 6. S펜 간단 텍스트 메모 다이얼로그 및 펜 지우개 옵션
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

  /// 7 & 8. 뷰어 표시 설정 (페이지 전환 설정 3가지 동시 선택 + 진행도 UI 위치 숨김 포함 + 하단 정보 표시)
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

  /// 5. 세로로 된 일본어 말풍선도 말풍선 크기에 맞춰 가로로 한글을 조판하며,
  /// 배경이 검은색(b.isDarkBg)이면 흰색 글씨로 표시!
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

            // 6. S펜 필기 레이어 표시 및 드로잉 입력
            if (strokes.isNotEmpty || (_isMemoMode && pageIndex == _currentPage))
              Positioned(
                left: drawLeft,
                top: drawTop,
                width: drawWidth,
                height: drawHeight,
                child: GestureDetector(
                  behavior: _isMemoMode ? HitTestBehavior.opaque : HitTestBehavior.translucent,
                  onPanStart: _isMemoMode
                      ? (details) {
                          setState(() {
                            _activeStrokePoints
                              ..clear()
                              ..add(details.localPosition);
                          });
                        }
                      : null,
                  onPanUpdate: _isMemoMode
                      ? (details) {
                          setState(() {
                            _activeStrokePoints.add(details.localPosition);
                          });
                        }
                      : null,
                  onPanEnd: _isMemoMode
                      ? (_) async {
                          if (_activeStrokePoints.isNotEmpty && drawWidth > 0 && drawHeight > 0) {
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
                        }
                      : null,
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

            // 페이지에 저장된 텍스트 메모 스티커 표시
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

    final double sliderVal = _currentPage.toDouble().clamp(0.0, math.max<double>(0.0, (_totalPages - 1).toDouble())).toDouble();
    final double sliderMax = math.max<double>(1.0, (_totalPages - 1).toDouble());

    if (_progressBarPos == 'bottom') {
      return Positioned(
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

  /// 7. 화면 이동 버튼 (오른쪽 하단에 위·아래 화살표가 양옆으로 나란히 붙어 있는 버튼)
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
                  physics: (_isTouchLocked || _isMemoMode)
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

          // S펜 필기 모드 상단 미니 툴바
          if (_isMemoMode && !_isTouchLocked)
            Positioned(
              top: 12,
              left: 16,
              right: 16,
              child: Center(
                child: Material(
                  color: Colors.black87,
                  borderRadius: BorderRadius.circular(24),
                  elevation: 6,
                  child: Padding(
                    padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 4),
                    child: Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        const Icon(Icons.draw, color: Colors.amber, size: 18),
                        const SizedBox(width: 6),
                        const Text('S펜 필기 모드', style: TextStyle(color: Colors.white, fontSize: 12)),
                        const SizedBox(width: 8),
                        ...[Colors.amber, Colors.redAccent, Colors.lightBlueAccent, Colors.greenAccent]
                            .map((c) => GestureDetector(
                                  onTap: () => setState(() => _penColor = c),
                                  child: Container(
                                    margin: const EdgeInsets.symmetric(horizontal: 3),
                                    width: 18,
                                    height: 18,
                                    decoration: BoxDecoration(
                                      color: c,
                                      shape: BoxShape.circle,
                                      border: Border.all(
                                        color: _penColor == c ? Colors.white : Colors.transparent,
                                        width: 2,
                                      ),
                                    ),
                                  ),
                                )),
                        IconButton(
                          icon: const Icon(Icons.note_alt_outlined, color: Colors.white, size: 18),
                          tooltip: '텍스트 메모 입력',
                          onPressed: _showMemoTextDialog,
                        ),
                        IconButton(
                          icon: const Icon(Icons.undo, color: Colors.white, size: 18),
                          tooltip: '한 획 취소',
                          onPressed: () async {
                            final list = _memoStrokesByPage[_currentPage];
                            if (list != null && list.isNotEmpty) {
                              setState(() => list.removeLast());
                              await StorageService.savePageMemoStrokes(_bookKey, _currentPage, list);
                            }
                          },
                        ),
                        TextButton(
                          onPressed: () => setState(() => _isMemoMode = false),
                          child: const Text('완료', style: TextStyle(color: Colors.amber)),
                        ),
                      ],
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
                      // 1 & 2. 화면 터치 잠금 버튼 (음량 버튼 2개 동시 누름으로 해제)
                      IconButton(
                        icon: const Icon(Icons.screen_lock_portrait, color: Colors.white, size: 20),
                        tooltip: '화면 터치 잠금',
                        onPressed: _lockTouchScreen,
                      ),
                      // 6. S펜 필기/메모 버튼
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
                            if (_isMemoMode) _showControls = false;
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
                      // 3. 방향 전환 버튼 (방향 상태 영구 기억 + 간격 축소 + 왼쪽 아이콘과 동일한 Colors.amber 색상)
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

          if (_showControls && !_isTouchLocked && _totalPages > 1 && _progressBarPos != 'hidden')
            _buildProgressControlBar(),

          // 7. 오른쪽 하단 화면 이동 버튼 (위·아래 화살표 양옆 배치, 페이지 전환 설정에서 켜면 상시 작동)
          if (_useQuickNavTurn && !_isTouchLocked && _totalPages > 1)
            _buildQuickNavButtons(bottomInset),
        ],
      ),
    );
  }
}
