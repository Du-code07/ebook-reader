import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart' show HapticFeedback;

import 'app_colors.dart';

/// 길게 눌러 끌어 옮기는 막대 (도구 모음·진행바·메모 도구 모음)가 함께 쓰는 끌기
/// - 끄는 동안: 막대가 손가락을 따라 움직임 (원래 자리는 비워 둠)
/// - 옮길 수 있는 가장자리 근처에 가면: 그 자리에 맞는 모양(가로·세로)으로만 바뀌고, 손가락은 계속 따라감
/// - 놓으면: 가장 가까운 가장자리로 자석처럼 빨려 들어가 붙음 (중간에 멈추지 않음)
mixin BarDragMixin<T extends StatefulWidget> on State<T>, TickerProvider {
  /// 옮길 수 있는 가장자리 ('top' · 'bottom' · 'left' · 'right')
  List<String> get dragSides;

  /// 지금 놓인 가장자리
  String get dragCurrent;

  /// [side]에 놓였을 때의 막대 모양 (끄는 동안 손가락을 따라 그려짐)
  Widget dragFeedback(String side);

  /// 근처에서 놓았을 때
  void dragDrop(String side);

  /// 끄는 중인지 (원래 자리의 막대는 이 동안 보이지 않음)
  bool barDragging = false;

  OverlayEntry? _entry;
  Offset _pos = Offset.zero; // 막대 가운데 (화면 기준)
  Offset _grab = Offset.zero; // 잡은 자리에서 막대 가운데까지
  String? _hover; // 손가락이 가까이 간 가장자리
  String _shape = 'bottom'; // 지금 그리는 모양의 가장자리
  bool _settling = false;
  AnimationController? _settle;
  // 모양이 바뀔 때 손가락과 막대 가운데 사이 간격도 서서히 바뀜 (막대가 툭 튀지 않게)
  AnimationController? _morph;
  Offset _finger = Offset.zero;
  Offset _offFrom = Offset.zero, _offTo = Offset.zero;

  Offset get _offset {
    final m = _morph;
    if (m == null || !m.isAnimating) return _offTo;
    return Offset.lerp(_offFrom, _offTo, Curves.easeOutCubic.transform(m.value))!;
  }

  void _placeAtFinger() {
    _pos = _finger + _offset;
    _entry?.markNeedsBuild();
  }

  static bool _vertical(String side) => side == 'left' || side == 'right';

  Rect? _ownRect() {
    final RenderObject? ro = context.findRenderObject();
    if (ro is! RenderBox || !ro.hasSize || !ro.attached) return null;
    return ro.localToGlobal(Offset.zero) & ro.size;
  }

  /// 손가락 가까이에 있는 (옮길 수 있는) 가장자리. 없으면 null
  String? _nearSide(Offset p) {
    final Size size = MediaQuery.sizeOf(context);
    final double tv = (size.height * 0.18).clamp(100.0, 170.0).toDouble();
    final double th = (size.width * 0.2).clamp(70.0, 130.0).toDouble();
    String? best;
    double bestRatio = 1.0;
    for (final side in dragSides) {
      final double d = switch (side) { 'left' => p.dx, 'right' => size.width - p.dx, 'top' => p.dy, _ => size.height - p.dy };
      final double r = d / (_vertical(side) ? th : tv);
      if (r < bestRatio) {
        bestRatio = r;
        best = side;
      }
    }
    return best;
  }

  /// 손가락에서 가장 가까운 가장자리 (멀리 있어도)
  String _closestSide(Offset p) {
    final Size size = MediaQuery.sizeOf(context);
    final Map<String, double> dist = {
      for (final side in dragSides)
        side: switch (side) { 'left' => p.dx, 'right' => size.width - p.dx, 'top' => p.dy, _ => size.height - p.dy },
    };
    return dist.entries.reduce((a, b) => a.value <= b.value ? a : b).key;
  }

  void dragStart(Offset finger) {
    final Rect? r = _ownRect();
    if (r == null) return;
    _settle?.stop();
    _entry?.remove();
    _grab = r.center - finger;
    _pos = r.center;
    _finger = finger;
    _offFrom = _offTo = _grab;
    _morph?.stop();
    _hover = null;
    _shape = dragCurrent;
    _settling = false;
    HapticFeedback.mediumImpact();
    _entry = OverlayEntry(builder: _buildFeedback);
    Overlay.of(context).insert(_entry!);
    setState(() => barDragging = true);
  }

  void dragMove(Offset finger) {
    if (_entry == null || _settling) return;
    final String? near = _nearSide(finger);
    _finger = finger;
    if (near != _hover) {
      _hover = near;
      final String shape = near ?? dragCurrent;
      if (_vertical(shape) != _vertical(_shape)) {
        HapticFeedback.selectionClick();
        // 모양이 처음과 같으면 잡은 자리 그대로, 바뀌었으면 손가락이 막대 가운데에 오게 (서서히 옮겨 감)
        _offFrom = _offset;
        _offTo = _vertical(shape) == _vertical(dragCurrent) ? _grab : Offset.zero;
        _morph ??= AnimationController(vsync: this)..addListener(_placeAtFinger);
        _morph!
          ..duration = Anim.ms(260)
          ..forward(from: 0);
      }
      _shape = shape;
    }
    _placeAtFinger();
  }

  /// 손을 뗐을 때 (취소면 [cancel]): 중간에서 멈추지 않고 가장 가까운 가장자리로 빨려 들어감 (취소면 원래 자리로)
  void dragEnd({bool cancel = false}) {
    if (_entry == null || _settling) return;
    final String? side = cancel ? null : (_hover ?? _closestSide(_finger));
    _settling = true;
    if (side != null && side != dragCurrent) dragDrop(side);
    // 새 자리가 그려진 뒤 그 자리를 알아내 빨려 들어감
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted || _entry == null) return;
      _morph?.stop();
      final Rect? target = _ownRect();
      _shape = dragCurrent;
      if (target == null) {
        _finish();
        return;
      }
      final Offset from = _pos;
      _settle ??= AnimationController(vsync: this);
      _settle!
        ..duration = Anim.ms(170)
        ..value = 0;
      void tick() {
        _pos = Offset.lerp(from, target.center, Curves.easeOutCubic.transform(_settle!.value))!;
        _entry?.markNeedsBuild();
      }
      _settle!.addListener(tick);
      _settle!.forward().whenComplete(() {
        _settle?.removeListener(tick);
        _finish();
      });
    });
  }

  void _finish() {
    _entry?.remove();
    _entry = null;
    _settling = false;
    _hover = null;
    if (mounted) setState(() => barDragging = false);
  }

  void disposeBarDrag() {
    _entry?.remove();
    _entry = null;
    _settle?.dispose();
    _settle = null;
    _morph?.dispose();
    _morph = null;
  }

  Widget _buildFeedback(BuildContext ctx) {
    final RenderObject? overlayBox = Overlay.maybeOf(context)?.context.findRenderObject();
    final Offset local = overlayBox is RenderBox && overlayBox.attached ? overlayBox.globalToLocal(_pos) : _pos;
    final bool vertical = _vertical(_shape);
    return Positioned.fill(
      child: IgnorePointer(
        child: CustomSingleChildLayout(
          delegate: _CenterAt(local),
          child: Material(
            type: MaterialType.transparency,
            child: AnimatedScale(
              scale: _settling ? 1.0 : 1.04,
              duration: Anim.ms(140),
              child: AnimatedOpacity(
                opacity: _settling ? 1.0 : 0.9,
                duration: Anim.ms(140),
                // 가로↔세로가 바뀔 때: 나가는 모양은 길이 쪽으로 줄어들며 흐려지고, 들어오는 모양은 늘어나며 또렷해짐
                child: AnimatedSwitcher(
                  duration: Anim.ms(260),
                  switchInCurve: Curves.easeOutCubic,
                  switchOutCurve: Curves.easeInCubic,
                  layoutBuilder: (current, previous) => Stack(alignment: Alignment.center, children: [...previous, if (current != null) current]),
                  transitionBuilder: (child, anim) {
                    final bool v = (child.key as ValueKey<bool>?)?.value ?? false;
                    return FadeTransition(
                      opacity: anim,
                      child: AnimatedBuilder(
                        animation: anim,
                        child: child,
                        builder: (context, c) {
                          final double long = 0.35 + 0.65 * anim.value, short = 0.8 + 0.2 * anim.value;
                          return Transform(
                            alignment: Alignment.center,
                            transform: Matrix4.diagonal3Values(v ? short : long, v ? long : short, 1),
                            child: c,
                          );
                        },
                      ),
                    );
                  },
                  child: KeyedSubtree(key: ValueKey(vertical), child: dragFeedback(_shape)),
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}

/// 자식을 느슨하게 재고, 가운데가 [center]에 오게 놓음
class _CenterAt extends SingleChildLayoutDelegate {
  _CenterAt(this.center);
  final Offset center;

  @override
  BoxConstraints getConstraintsForChild(BoxConstraints constraints) => constraints.loosen();

  @override
  Offset getPositionForChild(Size size, Size childSize) =>
      Offset(center.dx - childSize.width / 2, center.dy - childSize.height / 2);

  @override
  bool shouldRelayout(_CenterAt old) => old.center != center;
}

/// 끄는 동안 막대 모양의 크기 (화면 안에서): 가로 막대는 [maxWidth]까지, 세로 막대는 [maxHeight]까지
double barDragMaxLength(BuildContext context, {required bool vertical}) {
  final Size s = MediaQuery.sizeOf(context);
  final EdgeInsets p = MediaQuery.paddingOf(context);
  return vertical ? math.max(120.0, s.height - p.top - p.bottom - 160.0) : math.max(160.0, s.width - 28.0);
}
