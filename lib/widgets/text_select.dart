import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

// 길게 눌러 글 고르기: 고른 글 위에 뜨는 [복사 | 모두 선택 | 공유] 막대와,
// 글자 위치를 아는 쪽(PDF)에서 글을 고르는 층 (손잡이로 범위 조절)

const MethodChannel _channel = MethodChannel('ebook_reader/pdf_renderer');

/// 고른 글·손잡이 색 (쪽은 대부분 흰 종이라 잘 보이는 파란색)
const Color kTextSelectColor = Color(0xFF1A73E8);

/// 글을 다른 앱으로 보내기 (안드로이드 공유 창)
Future<void> shareText(String text) async {
  if (text.trim().isEmpty) return;
  try {
    await _channel.invokeMethod('shareText', {'text': text});
  } catch (_) {}
}

/// 글을 클립보드에 복사하고 짧게 알림
Future<void> copyText(BuildContext context, String text, String Function(String ko, String en, String zh, String ja) tr) async {
  if (text.isEmpty) return;
  await Clipboard.setData(ClipboardData(text: text));
  if (!context.mounted) return;
  ScaffoldMessenger.of(context)
    ..hideCurrentSnackBar()
    ..showSnackBar(SnackBar(content: Text(tr('복사했어요', 'Copied', '已复制', 'コピーしました')), duration: const Duration(milliseconds: 1400)));
}

/// 고른 글 위에 뜨는 어두운 막대: 복사 | 모두 선택 | 공유
class SelectionActionBar extends StatelessWidget {
  const SelectionActionBar({super.key, required this.tr, required this.onCopy, required this.onSelectAll, required this.onShare, this.onHighlight});

  final String Function(String ko, String en, String zh, String ja) tr;
  final VoidCallback onCopy;
  final VoidCallback? onSelectAll;
  final VoidCallback onShare;

  /// 형광펜 칠하기 (문서에서만)
  final VoidCallback? onHighlight;

  @override
  Widget build(BuildContext context) {
    Widget button(String label, VoidCallback onTap) => InkWell(
          onTap: onTap,
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 18, vertical: 12),
            child: Text(label, style: const TextStyle(color: Colors.white, fontSize: 16, fontWeight: FontWeight.w600)),
          ),
        );
    Widget divider() => Container(width: 1, height: 22, color: Colors.white.withValues(alpha: 0.28));
    return Material(
      color: const Color(0xFF303034),
      elevation: 3,
      shadowColor: Colors.black54,
      borderRadius: BorderRadius.circular(14),
      clipBehavior: Clip.antiAlias,
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          button(tr('복사', 'Copy', '复制', 'コピー'), onCopy),
          if (onSelectAll != null) ...[divider(), button(tr('모두 선택', 'Select all', '全选', 'すべて選択'), onSelectAll!)],
          divider(),
          button(tr('공유', 'Share', '分享', '共有'), onShare),
          if (onHighlight != null) ...[divider(), button(tr('형광펜', 'Highlight', '荧光笔', 'マーカー'), onHighlight!)],
        ],
      ),
    );
  }
}

/// 화면 어디에나 띄우는 막대 (엑셀처럼 글 고르기를 문서 화면이 직접 하는 경우)
class FloatingSelectionBar {
  OverlayEntry? _entry;

  bool get shown => _entry != null;

  void show(BuildContext context, Offset globalAnchor, {
    required String Function(String ko, String en, String zh, String ja) tr,
    required VoidCallback onCopy,
    VoidCallback? onSelectAll,
    required VoidCallback onShare,
  }) {
    hide();
    final overlay = Overlay.of(context, rootOverlay: true);
    _entry = OverlayEntry(
      builder: (ctx) {
        final Size screen = MediaQuery.sizeOf(ctx);
        // 누른 곳 조금 위, 화면 밖으로 나가지 않게
        final double top = (globalAnchor.dy - 72).clamp(MediaQuery.paddingOf(ctx).top + 8, screen.height - 80).toDouble();
        return Positioned(
          top: top,
          left: 0,
          right: 0,
          child: Center(
            child: SelectionActionBar(tr: tr, onCopy: onCopy, onSelectAll: onSelectAll, onShare: onShare),
          ),
        );
      },
    );
    overlay.insert(_entry!);
  }

  void hide() {
    _entry?.remove();
    _entry = null;
  }
}

/// 쪽 위 한 줄의 글과 자리 (층 기준 좌표)
class SelLine {
  const SelLine(this.text, this.rect);
  final String text;
  final Rect rect;
}

/// 글자 위치를 아는 쪽(PDF)에서 길게 눌러 글 고르기
class PageTextSelection extends ChangeNotifier {
  List<SelLine> lines = const [];

  /// 막대가 놓인 띠 (층이 그릴 때 정함) — 이 안이나 손잡이 근처를 누르면 고른 글을 지우지 않음
  Rect? barBand;

  bool hitsControls(Offset p) {
    if (!active) return false;
    if (barBand?.contains(p) ?? false) return true;
    if ((p - startHandle).distance < 36 || (p - endHandle).distance < 36) return true;
    return hitsSelection(p);
  }

  /// 고른 글(파란 바탕) 위를 눌렀는지
  bool hitsSelection(Offset p) => highlightRects.any((r) => r.inflate(10).contains(p));

  /// 고른 글을 잡고 끌 때 움직일 손잡이 (true: 앞, false: 뒤)
  bool? _bodyStart;

  /// 고른 글을 잡고 끌기 시작: 누른 곳에서 가까운 손잡이를 잡음
  void beginBodyDrag(Offset p) {
    if (!active) return;
    _bodyStart = (p - startHandle).distance < (p - endHandle).distance;
  }

  /// 고른 글을 잡고 끄는 중: 잡은 손잡이를 손가락 자리로
  void bodyDragTo(Offset p) {
    final b = _bodyStart;
    if (b == null || !active) return;
    moveHandle(b, p);
    // 앞 손잡이를 뒤 손잡이 너머로 끌면 순서가 바뀌므로 다시 고름
    final (sl, sc, el, ec) = _range;
    final h = hit(p);
    if (h != null) {
      if (h.$1 == sl && h.$2 == sc) _bodyStart = true;
      if (h.$1 == el && h.$2 == ec) _bodyStart = false;
    }
  }

  void endBodyDrag() => _bodyStart = null;

  /// 낱말 상자들(읽는 순서)을 줄로 묶음: 같은 높이에서 오른쪽으로 이어지는 낱말은 한 줄
  static List<SelLine> linesFromWords(List<SelLine> words) {
    final out = <SelLine>[];
    String text = '';
    Rect? cur;
    for (final w in words) {
      if (w.text.trim().isEmpty || w.rect.isEmpty) continue;
      final c = cur;
      if (c != null) {
        final double h = math.max(1.0, c.height);
        final bool sameRow = (w.rect.center.dy - c.center.dy).abs() < h * 0.5;
        final double gap = w.rect.left - c.right;
        if (sameRow && gap > -h * 0.5 && gap < h * 3) {
          text += gap > h * 0.12 ? ' ${w.text}' : w.text;
          cur = c.expandToInclude(w.rect);
          continue;
        }
        out.add(SelLine(text, c));
      }
      text = w.text;
      cur = w.rect;
    }
    if (cur != null) out.add(SelLine(text, cur));
    return out;
  }
  int _aLine = -1, _aChar = 0, _bLine = -1, _bChar = 0;

  bool get active => _aLine >= 0 && lines.isNotEmpty;

  // 앞·뒤 순서로 정리한 범위
  (int, int, int, int) get _range {
    final bool forward = _aLine < _bLine || (_aLine == _bLine && _aChar <= _bChar);
    return forward ? (_aLine, _aChar, _bLine, _bChar) : (_bLine, _bChar, _aLine, _aChar);
  }

  void clear() {
    if (_aLine < 0) return;
    _aLine = _bLine = -1;
    notifyListeners();
  }

  /// [p]에 가장 가까운 줄과 그 줄 안의 글자 자리
  (int, int)? hit(Offset p) {
    if (lines.isEmpty) return null;
    int best = -1;
    double bestD = double.infinity;
    for (int i = 0; i < lines.length; i++) {
      final r = lines[i].rect;
      final double dy = p.dy < r.top ? r.top - p.dy : (p.dy > r.bottom ? p.dy - r.bottom : 0);
      final double dx = p.dx < r.left ? r.left - p.dx : (p.dx > r.right ? p.dx - r.right : 0);
      final double d = dy * 3 + dx; // 위아래로 먼 줄보다 같은 높이의 줄을 먼저
      if (d < bestD) {
        bestD = d;
        best = i;
      }
    }
    if (best < 0) return null;
    final r = lines[best].rect;
    final int len = lines[best].text.length;
    final int c = r.width <= 0 ? 0 : ((p.dx - r.left) / r.width * len).round().clamp(0, len);
    return (best, c);
  }

  static bool _isWordChar(String ch) => !RegExp(r'[\s.,;:!?·、。，()\[\]{}<>"' "'" r'“”‘’]').hasMatch(ch);

  /// 누른 곳의 낱말을 고름. 글이 없는 곳이면 false
  bool selectWordAt(Offset p) {
    final h = hit(p);
    if (h == null) return false;
    final r = lines[h.$1].rect;
    // 글에서 너무 먼 곳은 고르지 않음
    if (!r.inflate(math.max(24.0, r.height)).contains(p)) return false;
    final String t = lines[h.$1].text;
    if (t.isEmpty) return false;
    int s = h.$2.clamp(0, t.length - 1), e = s;
    if (!_isWordChar(t[s]) && s > 0 && _isWordChar(t[s - 1])) s = e = s - 1;
    while (s > 0 && _isWordChar(t[s - 1])) {
      s--;
    }
    while (e < t.length && _isWordChar(t[e])) {
      e++;
    }
    if (e == s) e = math.min(t.length, s + 1);
    _aLine = _bLine = h.$1;
    _aChar = s;
    _bChar = e;
    notifyListeners();
    return true;
  }

  void selectAll() {
    if (lines.isEmpty) return;
    _aLine = 0;
    _aChar = 0;
    _bLine = lines.length - 1;
    _bChar = lines.last.text.length;
    notifyListeners();
  }

  /// 손잡이 끌기: [start]면 앞 손잡이, 아니면 뒤 손잡이를 [p]로
  void moveHandle(bool start, Offset p) {
    if (!active) return;
    final h = hit(p);
    if (h == null) return;
    final (sl, sc, el, ec) = _range;
    if (start) {
      _aLine = h.$1;
      _aChar = h.$2;
      _bLine = el;
      _bChar = ec;
    } else {
      _aLine = sl;
      _aChar = sc;
      _bLine = h.$1;
      _bChar = h.$2;
    }
    notifyListeners();
  }

  /// 길게 누른 채로 끌기: 처음 고른 낱말의 앞을 고정하고 끝을 옮김
  void extendTo(Offset p) {
    if (!active) return;
    final h = hit(p);
    if (h == null) return;
    _bLine = h.$1;
    _bChar = h.$2;
    notifyListeners();
  }

  String get selectedText {
    if (!active) return '';
    final (sl, sc, el, ec) = _range;
    final out = StringBuffer();
    for (int i = sl; i <= el; i++) {
      final t = lines[i].text;
      final int a = i == sl ? sc.clamp(0, t.length) : 0;
      final int b = i == el ? ec.clamp(0, t.length) : t.length;
      if (b > a) out.write(t.substring(a, b));
      if (i != el) out.write('\n');
    }
    return out.toString();
  }

  double _xAt(int line, int c) {
    final l = lines[line];
    final int len = math.max(1, l.text.length);
    return l.rect.left + l.rect.width * (c.clamp(0, len) / len);
  }

  /// 고른 부분의 네모들 (줄마다 하나)
  List<Rect> get highlightRects {
    if (!active) return const [];
    final (sl, sc, el, ec) = _range;
    final out = <Rect>[];
    for (int i = sl; i <= el; i++) {
      final r = lines[i].rect;
      final double l = i == sl ? _xAt(i, sc) : r.left;
      final double rr = i == el ? _xAt(i, ec) : r.right;
      if (rr > l) out.add(Rect.fromLTRB(l, r.top, rr, r.bottom));
    }
    return out;
  }

  /// 앞 손잡이 자리 (글 아래 왼쪽) / 뒤 손잡이 자리 (글 아래 오른쪽)
  Offset get startHandle {
    final (sl, sc, _, _) = _range;
    return Offset(_xAt(sl, sc), lines[sl].rect.bottom);
  }

  Offset get endHandle {
    final (_, _, el, ec) = _range;
    return Offset(_xAt(el, ec), lines[el].rect.bottom);
  }
}

/// [PageTextSelection]을 그리는 층: 고른 글 바탕, 손잡이 두 개, 막대
class PageTextSelectLayer extends StatelessWidget {
  const PageTextSelectLayer({super.key, required this.sel, required this.tr, this.onDone, this.onHighlight});

  /// 형광펜 칠하기: 고른 부분의 네모들(이 층 기준)을 받음. 없으면 단추를 숨김
  final void Function(List<Rect> rects)? onHighlight;

  final PageTextSelection sel;
  final String Function(String ko, String en, String zh, String ja) tr;

  /// 복사·공유를 누른 뒤
  final VoidCallback? onDone;

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: sel,
      builder: (context, _) {
        if (!sel.active) return const SizedBox.shrink();
        final rects = sel.highlightRects;
        if (rects.isEmpty) return const SizedBox.shrink();
        final Rect bounds = rects.reduce((a, b) => a.expandToInclude(b));
        final Offset s = sel.startHandle, e = sel.endHandle;
        const double hr = 11; // 손잡이 반지름

        Widget handle(bool start, Offset at) => Positioned(
              left: at.dx - (start ? hr * 2 : 0) - 8,
              top: at.dy - 8,
              child: GestureDetector(
                behavior: HitTestBehavior.opaque,
                onPanUpdate: (d) {
                  final box = context.findRenderObject() as RenderBox?;
                  if (box == null) return;
                  // 손가락이 손잡이를 가리지 않게 조금 위의 글자를 기준으로
                  sel.moveHandle(start, box.globalToLocal(d.globalPosition) - const Offset(0, 28));
                },
                child: Padding(
                  padding: const EdgeInsets.all(8),
                  child: CustomPaint(size: const Size(hr * 2, hr * 2), painter: _HandlePainter(start)),
                ),
              ),
            );

        return LayoutBuilder(builder: (context, c) {
          // 막대: 고른 글 위 (자리가 없으면 아래)
          final double barTop = bounds.top - 60 > 8 ? bounds.top - 60 : math.min(c.maxHeight - 56, bounds.bottom + 30);
          sel.barBand = Rect.fromLTWH(0, barTop - 6, c.maxWidth, 60);
          return Stack(
            clipBehavior: Clip.none,
            children: [
              IgnorePointer(child: CustomPaint(size: Size.infinite, painter: _HighlightPainter(rects))),
              // 고른 글(파란 바탕)을 잡고 끌면 가까운 쪽 손잡이가 따라와 범위를 고침 (지우지 않음)
              Positioned.fill(
                key: const ValueKey('sel-body'),
                child: GestureDetector(
                  behavior: HitTestBehavior.deferToChild,
                  onPanStart: (d) {
                    final box = context.findRenderObject() as RenderBox?;
                    if (box != null) sel.beginBodyDrag(box.globalToLocal(d.globalPosition));
                  },
                  onPanUpdate: (d) {
                    final box = context.findRenderObject() as RenderBox?;
                    if (box != null) sel.bodyDragTo(box.globalToLocal(d.globalPosition));
                  },
                  onPanEnd: (_) => sel.endBodyDrag(),
                  onPanCancel: sel.endBodyDrag,
                  // 고른 글 자리만 손가락을 받음 (나머지 화면은 그대로 아래로 전달)
                  child: CustomPaint(size: Size.infinite, painter: _BodyHit([for (final r in rects) r.inflate(10)])),
                ),
              ),
              handle(true, s),
              handle(false, e),
              Positioned(
                top: barTop,
                left: 0,
                right: 0,
                child: Center(
                  child: SelectionActionBar(
                    tr: tr,
                    onCopy: () async {
                      final t = sel.selectedText;
                      sel.clear();
                      await copyText(context, t, tr);
                      onDone?.call();
                    },
                    onSelectAll: sel.selectAll,
                    onShare: () {
                      final t = sel.selectedText;
                      sel.clear();
                      shareText(t);
                      onDone?.call();
                    },
                    onHighlight: onHighlight == null
                        ? null
                        : () {
                            final r = sel.highlightRects;
                            sel.clear();
                            onHighlight!(r);
                            onDone?.call();
                          },
                  ),
                ),
              ),
            ],
          );
        });
      },
    );
  }
}

class _BodyHit extends CustomPainter {
  _BodyHit(this.rects);
  final List<Rect> rects;

  @override
  void paint(Canvas canvas, Size size) {}

  @override
  bool hitTest(Offset position) => rects.any((r) => r.contains(position));

  @override
  bool shouldRepaint(covariant _BodyHit old) => false;
}

class _HighlightPainter extends CustomPainter {
  _HighlightPainter(this.rects);
  final List<Rect> rects;

  @override
  void paint(Canvas canvas, Size size) {
    final p = Paint()..color = kTextSelectColor.withValues(alpha: 0.30);
    for (final r in rects) {
      canvas.drawRect(r, p);
    }
  }

  @override
  bool shouldRepaint(covariant _HighlightPainter old) => old.rects != rects;
}

/// 물방울 모양 손잡이: 앞 손잡이는 오른쪽 위 모서리, 뒤 손잡이는 왼쪽 위 모서리가 뾰족함
class _HandlePainter extends CustomPainter {
  _HandlePainter(this.start);
  final bool start;

  @override
  void paint(Canvas canvas, Size size) {
    final double r = size.width / 2;
    final p = Paint()..color = kTextSelectColor;
    canvas.drawCircle(Offset(r, r), r, p);
    canvas.drawRect(start ? Rect.fromLTWH(r, 0, r, r) : Rect.fromLTWH(0, 0, r, r), p);
  }

  @override
  bool shouldRepaint(covariant _HandlePainter old) => old.start != start;
}
