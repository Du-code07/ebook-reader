import 'dart:async';
import 'dart:io';
import 'dart:math' as math;
import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_epub_viewer/flutter_epub_viewer.dart';
import 'package:path_provider/path_provider.dart';
import '../services/txt_to_epub_converter.dart';
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
  static const MethodChannel _pdfChannel = MethodChannel('ebook_reader/pdf_renderer');
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
  bool _useShakeLock = true;
  bool _useVolumeComboLock = true;
  bool _useSwipeTurn = true;
  bool _useVolumeTurn = true;
  bool _useQuickNavTurn = false;
  bool _useSpenTurn = false;
  bool? _forcedLandscape;
  int _manualQuarterTurns = 0;
  Offset? _lastEraserPos;
  final Set<int> _activeTouchPointerIds = {};
  final TransformationController _epubZoomController = TransformationController();
  double _epubZoomScale = 1.0;

  // 1 & 3. S펜 전용 페이지별 필기 및 지우개 상태 (필기 모드에서 S펜이 닿으면 화면 이동 100% 차단 + 해당 페이지에서만 필기 표시)
  bool _isMemoMode = false;
  bool _isEraserMode = false;
  bool _allowFingerDrawing = false;
  bool _isStylusDown = false;
  String _currentPageLocationKey = 'page_0';
  List<MemoStroke> _epubStrokes = [];
  final List<Offset> _activeStrokePoints = [];
  Color _penColor = Colors.amber;
  double _penWidth = 2.0;
  String _bookMemoNote = '';

  String _footerInfoMode = 'both';
  String _progressBarPos = 'right';
  double _progress = 0.0;
  bool _hasRestoredInitialPosition = false;

  Offset? _pointerDownPosition;
  DateTime? _pointerDownTime;

  String _tr(String ko, String en, String zh, String ja) =>
      AppI18n.t(StorageService.appLangNotifier.value, ko: ko, en: en, zh: zh, ja: ja);

  String _computeLocationKey(String? cfi, double prog) {
    if (cfi != null && cfi.trim().isNotEmpty) {
      return cfi.trim();
    }
    return 'prog_${(prog * 1000).round()}';
  }

  Future<File> _getTranslatedEpubFile({String? sourceLang, String? targetLang}) async {
    final tgt = targetLang ?? await StorageService.getAppLanguage();
    final src = sourceLang ?? 'ja';
    final outPath = widget.filePath.replaceAll(
      RegExp(r'\.epub$', caseSensitive: false),
      '_${src}_to_${tgt}_translated.epub',
    );
    return File(outPath);
  }

  @override
  void initState() {
    super.initState();
    _activeFilePath = widget.filePath;
    WidgetsBinding.instance.addObserver(this);
    BatchTranslationService.translationCompletedEvent.addListener(_onBackgroundTranslationFinished);
    SystemChrome.setEnabledSystemUIMode(SystemUiMode.immersiveSticky);
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

  Future<void> _onBackgroundTranslationFinished() async {
    if (!mounted) return;
    final translatedFile = await _getTranslatedEpubFile();
    if (await translatedFile.exists() && !_isTranslatedFileActive) {
      setState(() {
        _isLoading = true;
        _activeFilePath = translatedFile.path;
        _isTranslatedFileActive = true;
        _initialCfi = _currentCfi;
        _hasRestoredInitialPosition = false;
      });
      await Future.delayed(const Duration(milliseconds: 100));
      if (mounted) {
        setState(() => _isLoading = false);
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text(_tr('백그라운드 번역이 완료되어 번역본으로 전환되었습니다.', 'Background translation finished; switched to translated book.', '后台翻译已完成，已切换为译本。', 'バックグラウンド翻訳が完了し、翻訳版に切り替わりました。')),
            duration: const Duration(seconds: 2),
          ),
        );
      }
    }
  }

  void _toggleTouchScreenLock({required bool byVolume}) {
    if (!mounted) return;
    if (!_isTouchLocked) return;
    if (byVolume && !_useVolumeComboLock) return;
    if (!byVolume && !_useShakeLock) return;

    setState(() {
      _isTouchLocked = false;
    });
    ScaffoldMessenger.of(context).clearSnackBars();
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(
          byVolume
              ? _tr('음량 버튼 동시 입력으로 화면 잠금이 해제되었습니다.', 'Screen unlocked via volume buttons.', '已通过同时按音量键解锁屏幕。', '音量ボタン同時押しで画面ロックを解除しました。')
              : _tr('흔들기 감지로 화면 잠금이 해제되었습니다.', 'Screen unlocked by shake.', '已通过摇晃解锁屏幕。', 'シェイクで画面ロックを解除しました。'),
        ),
        duration: const Duration(seconds: 1),
      ),
    );
  }

  Future<void> _toggleScreenOrientation() async {
    final Size beforeSize = MediaQuery.of(context).size;
    final bool isPhysicallyLandscape = beforeSize.width > beforeSize.height;
    final bool isEffectivelyLandscape = (_manualQuarterTurns % 2 == 1)
        ? !isPhysicallyLandscape
        : isPhysicallyLandscape;
    final bool nextLandscape = !isEffectivelyLandscape;
    _forcedLandscape = nextLandscape;

    try {
      await _pdfChannel.invokeMethod('setScreenOrientation', {
        'mode': nextLandscape ? 'landscape' : 'portrait',
      });
    } catch (_) {}

    await Future.delayed(const Duration(milliseconds: 220));
    if (!mounted) return;
    final Size afterSize = MediaQuery.of(context).size;
    final bool nowPhysicallyLandscape = afterSize.width > afterSize.height;
    setState(() {
      if (nowPhysicallyLandscape == nextLandscape) {
        _manualQuarterTurns = 0;
      } else {
        _manualQuarterTurns = (_manualQuarterTurns == 0) ? 1 : 0;
      }
    });
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
    final currentPath = widget.filePath.replaceAll(RegExp(r'(\.v2)?\.converted\.epub$'), '');
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

    final curIdx = allFiles.indexWhere((f) => f.path == currentPath);
    if (curIdx == -1 || allFiles.length <= 1) {
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

    final nextFile = allFiles[(curIdx + step + allFiles.length * 10) % allFiles.length];
    if (!mounted) return;

    final nextName = nextFile.path.split(Platform.pathSeparator).last;
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
          builder: (_) => ReaderScreen(filePath: nextFile.path, bookTitle: nextName),
        ),
      );

    } else if (docConvertExts.contains(nextExt)) {
      final epubFile = await TxtToEpubConverter.convertDocumentToEpub(nextFile);
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
            files: [nextFile],
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
      final targetList = siblingImages.length > 1 ? siblingImages : [nextFile];
      final bookKey = targetList.first.path;
      final clickedIdx = targetList.indexWhere((f) => f.path == nextFile.path);
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
            files: [nextFile],
            title: nextName,
            isPdf: false,
          ),
        ),
      );
    }
  }

  void _lockTouchScreen() {
    setState(() {
      _isTouchLocked = true;
      _showControls = false;
      _isMemoMode = false;
      _isStylusDown = false;
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
    final shakeLock = await StorageService.getUseShakeLock();
    final volComboLock = await StorageService.getUseVolumeComboLock();
    final volTurn = await StorageService.getUseVolumeTurn();
    final quickTurn = await StorageService.getUseQuickNavTurn();
    final swipeTurn = await StorageService.getUseSwipeTurn();
    final spenTurn = await StorageService.getUseSpenTurn();
    final memo = await StorageService.getPageMemoNote(widget.filePath, 0);

    final initLocKey = _computeLocationKey(savedCfi, savedProg);
    final strokes = await StorageService.getEpubLocationStrokes(widget.filePath, initLocKey);

    final translatedFile = await _getTranslatedEpubFile();
    final bool hasTranslated = await translatedFile.exists();

    _bindHardwareButtons();

    if (!mounted) return;
    setState(() {
      if (hasTranslated) {
        _activeFilePath = translatedFile.path;
        _isTranslatedFileActive = true;
      }
      _initialCfi = savedCfi;
      _currentCfi = savedCfi;
      _previousJumpCfi = prevCfi;
      _progress = savedProg.clamp(0.0, 1.0).toDouble();
      _currentPageLocationKey = initLocKey;
      _enableTwoPageInLandscape = twoPage;
      _isMangaRtlMode = isRtl;
      _epubBgTheme = savedBg.isNotEmpty ? savedBg : (isDark ? 'dark' : 'white');
      _footerInfoMode = footerMode;
      _progressBarPos = barPos;
      _useShakeLock = shakeLock;
      _useVolumeComboLock = volComboLock;
      _useVolumeTurn = volTurn;
      _useQuickNavTurn = quickTurn;
      _useSwipeTurn = swipeTurn;
      _useSpenTurn = spenTurn;
      _bookMemoNote = memo;
      _epubStrokes = strokes;
      _isLoading = false;
    });
  }

  void _turnNext() {
    setState(() => _activeStrokePoints.clear());
    if (_isMangaRtlMode) {
      _epubController.prev();
    } else {
      _epubController.next();
    }
  }

  void _turnPrev() {
    setState(() => _activeStrokePoints.clear());
    if (_isMangaRtlMode) {
      _epubController.next();
    } else {
      _epubController.prev();
    }
  }

  void _jumpToFirstPage() {
    if (_currentCfi != null) {
      setState(() {
        _previousJumpCfi = _currentCfi;
        _progress = 0.0;
        _activeStrokePoints.clear();
      });
    }
    _epubController.toProgressPercentage(0.0);
  }

  void _jumpToLastPage() {
    if (_currentCfi != null) {
      setState(() {
        _previousJumpCfi = _currentCfi;
        _progress = 1.0;
        _activeStrokePoints.clear();
      });
    }
    _epubController.toProgressPercentage(1.0);
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

  double _distToEraserSegment(Offset p, Offset a, Offset b) {
    final ab = b - a;
    final lenSq = ab.dx * ab.dx + ab.dy * ab.dy;
    if (lenSq < 0.0001) return (p - a).distance;
    final t = (((p.dx - a.dx) * ab.dx + (p.dy - a.dy) * ab.dy) / lenSq).clamp(0.0, 1.0);
    final proj = Offset(a.dx + ab.dx * t, a.dy + ab.dy * t);
    return (p - proj).distance;
  }

  /// 2 & 5. 삼성 노트 스타일 초고속 캡슐 지우개 (드래그 중 디스크 I/O 제거)
  void _eraseEpubStrokeAt(Offset localPos, double drawWidth, double drawHeight) {
    if (_epubStrokes.isEmpty || drawWidth <= 0 || drawHeight <= 0) {
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

    for (final s in _epubStrokes) {
      if (s.dxList.isEmpty) continue;

      double sMinX = double.infinity, sMaxX = double.negativeInfinity;
      double sMinY = double.infinity, sMaxY = double.negativeInfinity;
      for (int i = 0; i < s.dxList.length; i++) {
        final px = s.dxList[i] * drawWidth;
        final py = s.dyList[i] * drawHeight;
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
        final p0 = Offset(s.dxList[i] * drawWidth, s.dyList[i] * drawHeight);
        densePts.add(p0);
        if (i + 1 < s.dxList.length) {
          final p1 = Offset(s.dxList[i + 1] * drawWidth, s.dyList[i + 1] * drawHeight);
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
        nextStrokes.add(
          MemoStroke(
            dxList: compact.map((p) => (p.dx / drawWidth).clamp(0.0, 1.0).toDouble()).toList(),
            dyList: compact.map((p) => (p.dy / drawHeight).clamp(0.0, 1.0).toDouble()).toList(),
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
      setState(() => _epubStrokes = nextStrokes);
    }
  }

  Future<void> _exportDocumentWithAnnotations() async {
    try {
      final appDir = await getApplicationDocumentsDirectory();
      final now = DateTime.now();
      final dateStr = '${now.year}${now.month.toString().padLeft(2, '0')}${now.day.toString().padLeft(2, '0')}_${now.hour.toString().padLeft(2, '0')}${now.minute.toString().padLeft(2, '0')}';
      final baseTitle = widget.bookTitle.replaceAll(RegExp(r'\.[^.]+$'), '');
      final exportFileName = '${baseTitle}_메모포함_$dateStr.pdf';
      final exportFile = File('${appDir.path}/$exportFileName');

      final blocks = <Map<String, dynamic>>[
        {
          'type': 'paragraph',
          'text': '📖 ${widget.bookTitle}',
          'fontSizePt': 16.0,
          'bold': true,
        },
      ];
      if (_bookMemoNote.trim().isNotEmpty) {
        blocks.add({
          'type': 'paragraph',
          'text': '📝 [메모 내용]\n${_bookMemoNote.trim()}',
          'fontSizePt': 11.5,
          'bold': false,
        });
      }
      if (_epubStrokes.isNotEmpty) {
        blocks.add({
          'type': 'paragraph',
          'text': '✏️ [현재 위치 필기 선 ${_epubStrokes.length}개 포함]',
          'fontSizePt': 10.5,
          'italic': true,
        });
      }

      final resPath = await _pdfChannel.invokeMethod<String>('renderStructuredDocToPdf', {
        'outputPath': exportFile.path,
        'blocks': blocks,
      });

      if (resPath != null && File(resPath).existsSync()) {
        await StorageService.setBookGroup(resPath, 'PDF/문서');
        try {
          await _pdfChannel.invokeMethod<String>('saveFileToDownloads', {
            'sourcePath': resPath,
            'fileName': exportFileName,
          });
        } catch (_) {}
      }

      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text(
              _tr(
                '메모 포함 PDF가 서재 및 기기 다운로드(Download) 폴더에 저장되었습니다: $exportFileName',
                'Saved annotated PDF to Bookshelf & Downloads: $exportFileName',
                '已将包含笔记的 PDF 保存至书架和下载文件夹：$exportFileName',
                'メモ付きPDFが書斎とダウンロードフォルダに保存されました: $exportFileName',
              ),
            ),
            duration: const Duration(seconds: 4),
          ),
        );
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('내보내기 오류: $e')),
        );
      }
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
                final locKey = _currentPageLocationKey;
                await StorageService.saveEpubLocationStrokes(widget.filePath, locKey, []);
                await StorageService.savePageMemoNote(widget.filePath, 0, '');
                setState(() {
                  _epubStrokes = [];
                  _bookMemoNote = '';
                });
                if (ctx.mounted) Navigator.pop(ctx);
              },
              child: const Text('현재 페이지 필기/메모 지우기', style: TextStyle(color: Colors.redAccent)),
            ),
          TextButton(onPressed: () => Navigator.pop(ctx), child: Text(_tr('취소', 'Cancel', '取消', 'キャンセル'))),
          ElevatedButton(
            onPressed: () async {
              final text = ctrl.text.trim();
              await StorageService.savePageMemoNote(widget.filePath, 0, text);
              setState(() => _bookMemoNote = text);
              if (ctx.mounted) Navigator.pop(ctx);
            },
            child: Text(_tr('저장', 'Save', '保存', '保存')),
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
                Text(
                  _tr('뷰어 표시 설정', 'Viewer Display Settings', '阅读器显示设置', '뷰어表示設定'),
                  style: const TextStyle(fontSize: 16, fontWeight: FontWeight.bold),
                ),
                const SizedBox(height: 12),
                Row(
                  mainAxisAlignment: MainAxisAlignment.spaceBetween,
                  children: [
                    Text(
                      _tr('글자 크기', 'Font Size', '字体大小', '文字サイズ'),
                      style: const TextStyle(fontSize: 13, fontWeight: FontWeight.w600),
                    ),
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
                Text(
                  _tr('배경 색상', 'Background Color', '背景颜色', '背景色'),
                  style: const TextStyle(fontSize: 13, fontWeight: FontWeight.w600),
                ),
                const SizedBox(height: 6),
                Wrap(
                  spacing: 8,
                  runSpacing: 6,
                  children: [
                    ChoiceChip(
                      label: Text(_tr('흰색', 'White', '白色', '白')),
                      selected: _epubBgTheme == 'white',
                      onSelected: (_) async {
                        await _setEpubThemeMode('white');
                        setModalState(() {});
                      },
                    ),
                    ChoiceChip(
                      label: Text(_tr('종이색', 'Sepia', '羊皮纸色', 'セピア')),
                      selected: _epubBgTheme == 'sepia',
                      onSelected: (_) async {
                        await _setEpubThemeMode('sepia');
                        setModalState(() {});
                      },
                    ),
                    ChoiceChip(
                      label: Text(_tr('다크', 'Dark', '深色', 'ダーク')),
                      selected: _epubBgTheme == 'dark',
                      onSelected: (_) async {
                        await _setEpubThemeMode('dark');
                        setModalState(() {});
                      },
                    ),
                  ],
                ),
                const Divider(height: 16),
                Text(
                  _tr('화면 잠금 끄기 설정 (동시 사용 가능)', 'Screen Unlock Settings (Multiple allowed)', '解除屏幕锁定设置 (可同时启用)', '画面ロック解除設定 (同時使用可)'),
                  style: const TextStyle(fontSize: 13, fontWeight: FontWeight.w600),
                ),
                const SizedBox(height: 6),
                Wrap(
                  spacing: 8,
                  runSpacing: 6,
                  children: [
                    FilterChip(
                      label: Text(_tr('흔들어서 끄기', 'Shake to Unlock', '摇晃关闭锁定', '振って解除')),
                      selected: _useShakeLock,
                      onSelected: (val) async {
                        await StorageService.setUseShakeLock(val);
                        setState(() => _useShakeLock = val);
                        setModalState(() {});
                      },
                    ),
                    FilterChip(
                      label: Text(_tr('음량 버튼 동시에 눌러서 끄기', 'Press Both Volume Keys to Unlock', '同时按音量键关闭锁定', '音量ボタン同時押しで解除')),
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
                      label: Text(_tr('옆으로 밀기', 'Swipe to Turn', '横向滑动翻页', '横にスワイプ')),
                      selected: _useSwipeTurn,
                      onSelected: (val) async {
                        await StorageService.setUseSwipeTurn(val);
                        setState(() => _useSwipeTurn = val);
                        setModalState(() {});
                      },
                    ),
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

  /// 1 & 4. Google ML Kit 공식 번역 라이브러리로 설정 언어(targetLang)로 백그라운드 번역
  Future<void> _handleBatchTranslateBook({bool forceRetranslate = false}) async {
    if (BatchTranslationService.isBookTranslating(widget.filePath)) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(
            _tr(
              '현재 백그라운드에서 번역이 진행 중입니다. (뒤로가기를 눌러도 계속 번역됩니다)',
              'Pre-translation is currently running in the background.',
              '后台正在进行翻译。（返回书架后仍会继续）',
              '現在バックグラウンドで翻訳が進行中です。(戻っても継続します)',
            ),
          ),
          duration: const Duration(seconds: 2),
        ),
      );
      return;
    }

    final targetLang = await StorageService.getAppLanguage();
    final translatedFile = await _getTranslatedEpubFile(targetLang: targetLang);

    if (_isTranslatedFileActive && !forceRetranslate) {
      setState(() {
        _isLoading = true;
        _activeFilePath = widget.filePath;
        _isTranslatedFileActive = false;
        _initialCfi = _currentCfi;
        _hasRestoredInitialPosition = false;
      });
      await Future.delayed(const Duration(milliseconds: 100));
      if (mounted) setState(() => _isLoading = false);
      return;
    }

    if (!forceRetranslate && await translatedFile.exists()) {
      setState(() {
        _isLoading = true;
        _activeFilePath = translatedFile.path;
        _isTranslatedFileActive = true;
        _initialCfi = _currentCfi;
        _hasRestoredInitialPosition = false;
      });
      await Future.delayed(const Duration(milliseconds: 100));
      if (mounted) setState(() => _isLoading = false);
      return;
    }

    String selectedSource = 'ja';

    if (!mounted) return;
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (ctx) => StatefulBuilder(
        builder: (ctx, setModalState) => AlertDialog(
          title: Text(_tr('번역', 'Translation', '翻译', '翻訳')),
          content: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                _tr(
                  '원본 언어를 선택하면 현재 앱 설정 언어로 번역합니다:',
                  'Select source language to translate into App Language:',
                  '选择原文语言后将翻译为当前应用设置语言：',
                  '原文言語を選択すると現在のアプリ設定言語に翻訳します：',
                ),
                style: const TextStyle(fontSize: 13),
              ),
              const SizedBox(height: 12),
              Builder(
                builder: (context) {
                  final allOptions = <Map<String, String>>[
                    {'code': 'ja', 'label': _tr('일본어 (Japanese)', 'Japanese', '日语 (Japanese)', '日本語 (Japanese)')},
                    {'code': 'zh', 'label': _tr('중국어 (Chinese)', 'Chinese', '中文 (Chinese)', '中国語 (Chinese)')},
                    {'code': 'en', 'label': _tr('영어 (English)', 'English', '英语 (English)', '英語 (English)')},
                    {'code': 'ko', 'label': _tr('한국어 (Korean)', 'Korean', '韩语 (Korean)', '韓国語 (Korean)')},
                  ];
                  final availableOptions = allOptions.where((opt) => opt['code'] != targetLang).toList();
                  if (!availableOptions.any((opt) => opt['code'] == selectedSource) && availableOptions.isNotEmpty) {
                    selectedSource = availableOptions.first['code']!;
                  }
                  return Wrap(
                    spacing: 8,
                    runSpacing: 6,
                    children: availableOptions.map((opt) {
                      final code = opt['code']!;
                      final label = opt['label']!;
                      return ChoiceChip(
                        label: Text(label),
                        selected: selectedSource == code,
                        onSelected: (_) => setModalState(() => selectedSource = code),
                      );
                    }).toList(),
                  );
                },
              ),
            ],
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(ctx, false),
              child: Text(_tr('취소', 'Cancel', '取消', 'キャンセル')),
            ),
            ElevatedButton.icon(
              icon: const Icon(Icons.translate, size: 18),
              label: Text(_tr('번역 시작', 'Start Translation', '开始翻译', '翻訳開始')),
              onPressed: () => Navigator.pop(ctx, true),
            ),
          ],
        ),
      ),
    );

    if (confirmed != true || !mounted) return;

    final targetOutFile = await _getTranslatedEpubFile(
      sourceLang: selectedSource,
      targetLang: targetLang,
    );
    if (forceRetranslate && await targetOutFile.exists()) {
      try {
        await targetOutFile.delete();
      } catch (_) {}
    }

    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(
          _tr(
            '백그라운드 번역을 시작했습니다. 뒤로가기를 눌러도 유지됩니다.',
            'Background pre-translation started. Continues even if you go back.',
            '后台翻译已开始，返回书架后仍会继续。',
            'バックグラウンド翻訳を開始しました。戻っても継続します。',
          ),
        ),
        duration: const Duration(seconds: 2),
      ),
    );

    unawaited(
      BatchTranslationService.preTranslateWholeEpub(
        sourceEpub: File(widget.filePath),
        sourceLang: selectedSource,
        targetLang: targetLang,
      ),
    );
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
              title: Text(_tr('북마크 목록', 'Bookmarks', '书签列表', 'ブックマーク一覧'), style: const TextStyle(fontWeight: FontWeight.bold)),
              trailing: ElevatedButton.icon(
                icon: const Icon(Icons.bookmark_add, size: 18),
                label: Text(_tr('현재 페이지 북마크', 'Bookmark This Page', '添加当前页书签', '現在ページをブックマーク')),
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
              Padding(
                padding: const EdgeInsets.all(24.0),
                child: Text(_tr('저장된 북마크가 없습니다.', 'No saved bookmarks.', '暂无保存的书签。', '保存されたブックマークはありません。')),
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
    if (_isMemoMode &&
        (event.kind == PointerDeviceKind.stylus ||
            event.kind == PointerDeviceKind.invertedStylus)) {
      if (!_isStylusDown) {
        setState(() => _isStylusDown = true);
      }
      return;
    }
    _pointerDownPosition = event.position;
    _pointerDownTime = DateTime.now();
  }

  void _handlePointerUp(PointerUpEvent event, Size screenSize) {
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

    if (distance < 24.0 && duration < 380) {
      _toggleControls();
    }
    _pointerDownPosition = null;
    _pointerDownTime = null;
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
    final String cssBg = _epubBgTheme == 'dark'
        ? '#1E1E1E'
        : (_epubBgTheme == 'sepia' ? '#FBF0D9' : '#FFFFFF');
    final String cssFg = _epubBgTheme == 'dark'
        ? '#D4D4D4'
        : (_epubBgTheme == 'sepia' ? '#3B2F2F' : '#000000');

    return EpubTheme.custom(
      backgroundDecoration: BoxDecoration(
        color: _getBgColor(),
      ),
      foregroundColor: _getFgColor(),
      customCss: {
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
    await StorageService.setEpubBgTheme(mode);
    setState(() {
      _initialCfi = _currentCfi;
      _epubBgTheme = mode;
    });
    try {
      _epubController.updateTheme(theme: _buildTheme());
    } catch (_) {}
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

  /// 6. 진행도 UI의 화살표를 맨 처음(0.0)과 맨 마지막(1.0)으로 즉시 이동하는 용도로 변경!
  /// + 하단 배치 시 우측 하단 페이지 이동 버튼과 절대 겹치지 않도록 슬림/컴팩트 사이즈로 축소 및 여백 확보!
  Widget _buildEpubProgressBar(double bottomInset) {
    if (!_showControls || _isTouchLocked || _progressBarPos == 'hidden' || (_chapters.length <= 1 && _progress <= 0.0)) {
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
        left: 14.0,
        // 페이지 이동 버튼(우측 12.0, 너비 약 88px -> 우측 100px 차지)과 겹치지 않도록 118px 여유 간격 확보
        right: _useQuickNavTurn ? 118.0 : 14.0,
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
                  icon: const Icon(Icons.first_page, color: Colors.white, size: 18),
                  tooltip: '처음으로 이동',
                  visualDensity: VisualDensity.compact,
                  padding: EdgeInsets.zero,
                  constraints: const BoxConstraints(minWidth: 28, minHeight: 28),
                  onPressed: _jumpToFirstPage,
                ),
                Expanded(
                  child: SliderTheme(
                    data: SliderTheme.of(context).copyWith(
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
                        if (_currentCfi != null) {
                          setState(() => _previousJumpCfi = _currentCfi);
                        }
                        _epubController.toProgressPercentage(v);
                      },
                    ),
                  ),
                ),
                Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 2),
                  child: Text(
                    '${(_progress * 100).toStringAsFixed(0)}%',
                    style: const TextStyle(fontSize: 10.5, fontWeight: FontWeight.bold, color: Colors.white),
                  ),
                ),
                IconButton(
                  icon: const Icon(Icons.last_page, color: Colors.white, size: 18),
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

    return Positioned(
      key: ValueKey('epub_progress_bar_$_progressBarPos'),
      top: 76.0,
      bottom: _useQuickNavTurn && _progressBarPos == 'right' ? (baseBottom + 48.0) : (baseBottom + 8.0),
      left: _progressBarPos == 'left' ? 8.0 : null,
      right: _progressBarPos == 'right' ? 8.0 : null,
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
                icon: const Icon(Icons.vertical_align_top, color: Colors.white, size: 18),
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
                        if (_currentCfi != null) {
                          setState(() => _previousJumpCfi = _currentCfi);
                        }
                        _epubController.toProgressPercentage(v);
                      },
                    ),
                  ),
                ),
              ),
              Text(
                '${(_progress * 100).toStringAsFixed(0)}%',
                style: const TextStyle(fontSize: 9.5, fontWeight: FontWeight.bold, color: Colors.white),
              ),
              IconButton(
                icon: const Icon(Icons.vertical_align_bottom, color: Colors.white, size: 18),
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
                onPressed: _turnPrev,
              ),
              Container(width: 1, height: 18, color: Colors.white24),
              IconButton(
                icon: const Icon(Icons.arrow_forward, color: Colors.amber, size: 19),
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
    BatchTranslationService.translationCompletedEvent.removeListener(_onBackgroundTranslationFinished);
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

    return PopScope(
      onPopInvokedWithResult: (didPop, _) {
        if (_isTouchLocked) {
          _isTouchLocked = false;
        }
      },
      child: Scaffold(
      key: _scaffoldKey,
      backgroundColor: bgColor,
      drawer: Drawer(
        child: SafeArea(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Padding(
                padding: const EdgeInsets.all(16.0),
                child: Text(_tr('목차', 'Contents', '目录', '目次'), style: const TextStyle(fontSize: 18, fontWeight: FontWeight.bold)),
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
          fit: StackFit.expand,
          children: [
            // 1. EPUB 뷰어 본문 (Listener를 EpubViewer에만 감싸서 우측 하단 페이지 이동 버튼 클릭 시 상단/하단 UI가 뜨지 않도록 완벽 분리!)
            Positioned.fill(
              child: Padding(
                padding: EdgeInsets.only(
                  top: 12.0,
                  bottom: (bottomPadding > 0 ? bottomPadding : 8.0) + 20.0,
                ),
                child: IgnorePointer(
                  ignoring: _isTouchLocked || (_isMemoMode && (_isStylusDown || _allowFingerDrawing)),
                  child: Listener(
                    behavior: HitTestBehavior.translucent,
                    onPointerDown: _handlePointerDown,
                    onPointerUp: (event) => _handlePointerUp(event, screenSize),
                    onPointerCancel: (event) {
                      if (_isStylusDown) {
                        setState(() => _isStylusDown = false);
                      }
                    },
                    child: InteractiveViewer(
                      transformationController: _epubZoomController,
                      panEnabled: !_isMemoMode && _epubZoomScale > 1.03,
                      scaleEnabled: !_isTouchLocked && (!_isMemoMode || !_allowFingerDrawing),
                      minScale: 1.0,
                      maxScale: 4.5,
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
                      child: GestureDetector(
                        behavior: HitTestBehavior.translucent,
                        onHorizontalDragUpdate: !_useSwipeTurn ? (_) {} : null,
                        child: EpubViewer(
                          key: ValueKey('${_activeFilePath}_${spreadSetting}_$_epubBgTheme'),
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
                    onRelocated: (value) async {
                      if (!_hasRestoredInitialPosition &&
                          _initialCfi != null &&
                          value.progress < 0.01 &&
                          _progress > 0.05) {
                        return;
                      }
                      _hasRestoredInitialPosition = true;
                      _currentCfi = value.startCfi;
                      final double clampedProg = value.progress.clamp(0.0, 1.0).toDouble();
                      final String newLocKey = _computeLocationKey(value.startCfi, clampedProg);

                      StorageService.saveLastPosition(widget.filePath, value.startCfi);
                      StorageService.saveProgress(widget.filePath, clampedProg);

                      // 3. 페이지 이동 시 해당 페이지(CFI)에 저장된 필기만 불러와서 표시!
                      final pageStrokes = await StorageService.getEpubLocationStrokes(
                        widget.filePath,
                        newLocKey,
                      );
                      if (mounted) {
                        setState(() {
                          _progress = clampedProg;
                          _currentPageLocationKey = newLocKey;
                          _epubStrokes = pageStrokes;
                          _activeStrokePoints.clear();
                        });
                      }
                    },
                    ),
                      ),
                    ),
                  ),
                ),
              ),
            ),

            // 2. S펜 전용 페이지별 필기/지우개 오버레이 (EagerStylusPanGestureRecognizer로 S펜 이동 시 화면 움직임 100% 차단 + 손가락은 페이지 스와이프)
            if (_epubStrokes.isNotEmpty || _isMemoMode)
              Positioned.fill(
                child: LayoutBuilder(
                  builder: (context, constraints) {
                    final double drawWidth = constraints.maxWidth;
                    final double drawHeight = constraints.maxHeight;
                    return StylusOnlyDrawingLayer(
                      enabled: _isMemoMode,
                      allowTouch: _allowFingerDrawing,
                      onStylusDown: (event) {
                        if (!_isStylusDown) {
                          setState(() => _isStylusDown = true);
                        }
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
                      onStylusMove: (event) {
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
                      onStylusUp: (event) async {
                        _lastEraserPos = null;
                        if (_isStylusDown) {
                          setState(() => _isStylusDown = false);
                        }
                        final bool useEraser =
                            _isEraserMode || event.kind == PointerDeviceKind.invertedStylus;
                        if (useEraser) {
                          final locKey = _currentPageLocationKey;
                          await StorageService.saveEpubLocationStrokes(widget.filePath, locKey, _epubStrokes);
                        } else if (_activeStrokePoints.isNotEmpty &&
                            drawWidth > 0 &&
                            drawHeight > 0) {
                          final locKey = _currentPageLocationKey;
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
                          await StorageService.saveEpubLocationStrokes(
                            widget.filePath,
                            locKey,
                            list,
                          );
                        }
                      },
                      onStylusCancel: (_) {
                        setState(() {
                          _isStylusDown = false;
                          _activeStrokePoints.clear();
                        });
                      },
                      child: CustomPaint(
                        painter: _EpubMemoPainter(
                          strokes: _epubStrokes,
                          currentPoints: _activeStrokePoints,
                          currentColor: _penColor,
                          currentWidth: _penWidth,
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

            // 4. 백그라운드 번역 진행 중일 때 뷰어 내 미니 진행 표시줄 (항상 Positioned가 Stack의 직계 자식이 되도록 배치!)
            Positioned(
              left: 16,
              bottom: math.max<double>(bottomPadding + 24.0, 28.0) + (_showControls && _progressBarPos == 'bottom' ? 46.0 : 0.0),
              child: ValueListenableBuilder<Map<String, TranslationTaskInfo>>(
                valueListenable: BatchTranslationService.activeTasks,
                builder: (context, tasks, _) {
                  final task = tasks[widget.filePath];
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
                            '${_tr("번역", "Trans", "翻译", "翻訳")} ${(task.progress * 100).toStringAsFixed(0)}% (${task.current}/${task.total})',
                            style: const TextStyle(color: Colors.white, fontSize: 11),
                          ),
                        ],
                      ),
                    ),
                  );
                },
              ),
            ),

            // S펜 필기 모드 상단 미니 툴바 (펜 색상 + 지우개 버튼 포함)
            if (_isMemoMode && !_isTouchLocked)
              Positioned(
                top: (_showControls ? 54.0 : 8.0) + MediaQuery.of(context).padding.top,
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
                                Icons.touch_app,
                                color: _allowFingerDrawing ? Colors.white : Colors.amber,
                                size: 20,
                              ),
                              tooltip: _tr('손으로 글씨 쓰기', 'Finger Writing', '手指书写', '指で手書き'),
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
                              tooltip: _tr('지우개', 'Eraser', '橡皮擦', '消しゴム'),
                              onPressed: () => setState(() => _isEraserMode = !_isEraserMode),
                            ),
                            IconButton(
                              icon: const Icon(Icons.note_alt_outlined, color: Colors.white, size: 18),
                              tooltip: '텍스트 메모 입력',
                              onPressed: _showEpubMemoDialog,
                            ),
                            IconButton(
                              icon: const Icon(Icons.delete_sweep_outlined, color: Colors.redAccent, size: 18),
                              tooltip: _tr('필기 전체 지우기', 'Clear All Strokes', '清空全部手写', '手書きを全消去'),
                              onPressed: () async {
                                final locKey = _currentPageLocationKey;
                                setState(() => _epubStrokes = []);
                                await StorageService.saveEpubLocationStrokes(widget.filePath, locKey, []);
                              },
                            ),
                            TextButton(
                              onPressed: () => setState(() {
                                _isMemoMode = false;
                                _isEraserMode = false;
                                _allowFingerDrawing = false;
                                _isStylusDown = false;
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

            // 상단 컨트롤 바
            if (_showControls && !_isTouchLocked)
              Positioned(
                top: 0,
                left: 0,
                right: 0,
                child: Material(
                  color: Colors.black87,
                  child: SafeArea(
                    bottom: false,
                    child: Padding(
                      padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 4),
                      child: LayoutBuilder(
                        builder: (context, barConstraints) {
                          final bool isWide = barConstraints.maxWidth >= 680;
                          const btnConstraints = BoxConstraints(minWidth: 38, minHeight: 40);
                          const btnPadding = EdgeInsets.symmetric(horizontal: 6, vertical: 4);

                          final actionButtons = <Widget>[
                            IconButton(
                              visualDensity: VisualDensity.compact,
                              padding: btnPadding,
                              constraints: btnConstraints,
                              icon: const Icon(Icons.list, color: Colors.white, size: 20),
                              tooltip: _tr('목차', 'Contents', '目录', '目次'),
                              onPressed: () => _scaffoldKey.currentState?.openDrawer(),
                            ),
                            IconButton(
                              visualDensity: VisualDensity.compact,
                              padding: btnPadding,
                              constraints: btnConstraints,
                              icon: const Icon(Icons.skip_previous_rounded, color: Colors.white, size: 22),
                              tooltip: _tr('이전 파일로 이동', 'Previous File', '上一个文件', '前のファイル'),
                              onPressed: () => _openAdjacentFileInSameGroup(-1),
                            ),
                            IconButton(
                              visualDensity: VisualDensity.compact,
                              padding: btnPadding,
                              constraints: btnConstraints,
                              icon: const Icon(Icons.skip_next_rounded, color: Colors.white, size: 22),
                              tooltip: _tr('다음 파일로 이동', 'Next File', '下一个文件', '次のファイル'),
                              onPressed: () => _openAdjacentFileInSameGroup(1),
                            ),
                            IconButton(
                              visualDensity: VisualDensity.compact,
                              padding: btnPadding,
                              constraints: btnConstraints,
                              icon: const Icon(Icons.lock_outline, color: Colors.white, size: 19),
                              tooltip: _tr('화면 잠금', 'Lock Screen', '锁定屏幕', '画面ロック'),
                              onPressed: () {
                                setState(() {
                                  _isTouchLocked = true;
                                  _showControls = false;
                                  _isMemoMode = false;
                                  _allowFingerDrawing = false;
                                  _isStylusDown = false;
                                });
                                ScaffoldMessenger.of(context).clearSnackBars();
                                ScaffoldMessenger.of(context).showSnackBar(
                                  SnackBar(
                                    content: Text(
                                      _tr(
                                        '화면이 잠겼습니다. (흔들어서 끄기 또는 음량 버튼 동시에 눌러서 끄기)',
                                        'Screen locked. (Shake or press Vol Up+Down to unlock)',
                                        '屏幕已锁定。（摇晃或同时按音量键即可关闭锁定）',
                                        '画面をロックしました。(振るか音量ボタン同時押しで解除)',
                                      ),
                                    ),
                                    duration: const Duration(seconds: 2),
                                  ),
                                );
                              },
                            ),
                            IconButton(
                              visualDensity: VisualDensity.compact,
                              padding: btnPadding,
                              constraints: btnConstraints,
                              icon: const Icon(Icons.screen_rotation, color: Colors.white, size: 19),
                              tooltip: _tr('화면 가로/세로 전환', 'Rotate Screen', '横/竖屏切换', '画面縦横切替'),
                              onPressed: _toggleScreenOrientation,
                            ),
                            IconButton(
                              visualDensity: VisualDensity.compact,
                              padding: btnPadding,
                              constraints: btnConstraints,
                              icon: Icon(
                                Icons.draw_outlined,
                                color: _isMemoMode ? Colors.amber : Colors.white,
                                size: 20,
                              ),
                              tooltip: _tr('메모', 'Memo', '笔记', 'メモ'),
                              onPressed: () {
                                setState(() {
                                  _isMemoMode = !_isMemoMode;
                                  _isEraserMode = false;
                                  if (!_isMemoMode) _allowFingerDrawing = false;
                                  _isStylusDown = false;
                                });
                              },
                            ),
                            IconButton(
                              visualDensity: VisualDensity.compact,
                              padding: btnPadding,
                              constraints: btnConstraints,
                              icon: Icon(
                                _enableTwoPageInLandscape ? Icons.menu_book : Icons.stay_current_portrait,
                                color: _enableTwoPageInLandscape ? Colors.amber : Colors.white,
                                size: 20,
                              ),
                              tooltip: _tr('가로 모드 2페이지 보기', '2-Page Spread in Landscape', '横屏双页显示', '横画面2ページ表示'),
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
                              visualDensity: VisualDensity.compact,
                              padding: btnPadding,
                              constraints: btnConstraints,
                              icon: _buildDualDirectionIcon(),
                              tooltip: _isMangaRtlMode
                                  ? _tr('읽기 방향 전환 (우 → 좌)', 'Reading Direction (R → L)', '切换阅读方向 (右 → 左)', '読書方向切替 (右 → 左)')
                                  : _tr('읽기 방향 전환 (좌 → 우)', 'Reading Direction (L → R)', '切换阅读方向 (左 → 右)', '読書方向切替 (左 → 右)'),
                              onPressed: () async {
                                final nextRtl = !_isMangaRtlMode;
                                await StorageService.setReadingDirectionRtl(nextRtl);
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
                                          const Icon(Icons.arrow_forward_rounded, color: Colors.white, size: 16),
                                          Text(nextRtl ? _tr(' 좌)', ' L)', ' 左)', ' 左)') : _tr(' 우)', ' R)', ' 右)', ' 右)')),
                                        ],
                                      ),
                                      duration: const Duration(milliseconds: 900),
                                    ),
                                  );
                                }
                              },
                            ),
                            IconButton(
                              visualDensity: VisualDensity.compact,
                              padding: btnPadding,
                              constraints: btnConstraints,
                              icon: Icon(
                                _isTranslatedFileActive ? Icons.chat_bubble : Icons.translate,
                                color: _isTranslatedFileActive ? Colors.amber : Colors.white,
                                size: 20,
                              ),
                              tooltip: _tr('번역', 'Translate', '翻译', '翻訳'),
                              onPressed: () => _handleBatchTranslateBook(forceRetranslate: false),
                            ),
                            if (_isTranslatedFileActive)
                              IconButton(
                                visualDensity: VisualDensity.compact,
                                padding: btnPadding,
                                constraints: btnConstraints,
                                icon: const Icon(Icons.refresh, color: Colors.white70, size: 19),
                                tooltip: _tr('다시 번역', 'Retranslate', '重新翻译', '再翻訳'),
                                onPressed: () => _handleBatchTranslateBook(forceRetranslate: true),
                              ),
                            IconButton(
                              visualDensity: VisualDensity.compact,
                              padding: btnPadding,
                              constraints: btnConstraints,
                              icon: const Icon(Icons.ios_share, color: Colors.white, size: 19),
                              tooltip: _tr('파일 내보내기', 'Export File', '导出文件', 'ファイル出力'),
                              onPressed: _exportDocumentWithAnnotations,
                            ),
                            IconButton(
                              visualDensity: VisualDensity.compact,
                              padding: btnPadding,
                              constraints: btnConstraints,
                              icon: const Icon(Icons.bookmarks_outlined, color: Colors.white, size: 20),
                              tooltip: _tr('북마크', 'Bookmarks', '书签', 'ブックマーク'),
                              onPressed: _openBookmarkSheet,
                            ),
                            IconButton(
                              visualDensity: VisualDensity.compact,
                              padding: btnPadding,
                              constraints: btnConstraints,
                              icon: const Icon(Icons.tune, color: Colors.white, size: 20),
                              tooltip: _tr('뷰어 표시 설정', 'Viewer Settings', '阅读器显示设置', 'ビューア表示設定'),
                              onPressed: _showViewerSettingsSheet,
                            ),
                          ];

                          return Row(
                            children: [
                              IconButton(
                                visualDensity: VisualDensity.compact,
                                padding: btnPadding,
                                constraints: btnConstraints,
                                icon: const Icon(Icons.arrow_back, color: Colors.white, size: 20),
                                onPressed: () => Navigator.pop(context),
                              ),
                              if (isWide)
                                Expanded(
                                  child: Padding(
                                    padding: const EdgeInsets.symmetric(horizontal: 6),
                                    child: Text(
                                      widget.bookTitle,
                                      style: const TextStyle(color: Colors.white, fontSize: 14),
                                      overflow: TextOverflow.ellipsis,
                                    ),
                                  ),
                                ),
                              if (isWide)
                                ...actionButtons
                              else
                                Expanded(
                                  child: SingleChildScrollView(
                                    scrollDirection: Axis.horizontal,
                                    physics: const BouncingScrollPhysics(),
                                    child: Row(
                                      mainAxisSize: MainAxisSize.min,
                                      children: actionButtons,
                                    ),
                                  ),
                                ),
                            ],
                          );
                        },
                      ),
                    ),
                  ),
                ),
              ),

            _buildEpubProgressBar(bottomPadding),

            if (_useQuickNavTurn && !_isTouchLocked)
              _buildQuickNavButtons(bottomPadding),
          ],
        ),
      ),
    );
  }
}
