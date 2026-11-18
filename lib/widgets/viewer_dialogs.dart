import 'dart:async';
import 'dart:math' as math;
import 'dart:io';

import 'package:flutter/foundation.dart' show listEquals;
import 'package:flutter/material.dart';
import 'package:flutter/gestures.dart' show DeviceGestureSettings, EagerGestureRecognizer;
import 'package:flutter/scheduler.dart';
import 'app_colors.dart';
import 'bookmark_ribbon.dart';
import 'morph_icons.dart';
import 'pop_dialog.dart';
import '../services/storage_service.dart';

typedef ViewerTr = String Function(String ko, String en, String zh, String ja);

/// 탭 모드에서 누른 자리: 위쪽은 메뉴, 아래 왼쪽은 이전 쪽, 아래 오른쪽은 다음 쪽.
/// 세로·가로 모두 위 2/3가 메뉴 자리, 아래 1/3이 이전/다음 쪽.
enum TapZone { menu, left, right, none }

/// 탭 영역 칸 하나의 뜻 (P = 이전, N = 다음, M = 메뉴, X = 없음)
TapZone tapZoneOfCode(String code) => switch (code) {
      'P' => TapZone.left,
      'N' => TapZone.right,
      'X' => TapZone.none,
      _ => TapZone.menu,
    };

/// 누른 자리의 구역: 화면을 3×3 칸으로 나눠 앱 설정의 탭 영역대로 (기본: 위 6칸 메뉴, 아래 줄 왼쪽 칸 이전, 나머지 다음)
TapZone tapZoneAt(Offset local, Size size) {
  final String zones = StorageService.tapZones.value;
  if (zones.length != 9 || size.width <= 0 || size.height <= 0) return TapZone.menu;
  final int col = (local.dx / (size.width / 3)).floor().clamp(0, 2);
  final int row = (local.dy / (size.height / 3)).floor().clamp(0, 2);
  return tapZoneOfCode(zones[row * 3 + col]);
}

/// 가운데에 뜨는 둥근 창 (페이지 표시·화면 회전 등 짧은 고르기)
/// 고르기 창이 열리고 닫히는 시간 (도구 모음 단추로 여는 창: 빠르게)
Duration get _dialogDur => Anim.ms(80);

/// 바꾼 것이 있을 때만: 닫히는 움직임이 끝난 뒤에 적용 (화면 회전·쪽 다시 배치가 닫히는 움직임과 겹쳐 끊기지 않게)
Future<void> _afterDialogClosed() async {
  final d = _dialogDur;
  if (d > Duration.zero) await Future<void>.delayed(d);
}

Future<T?> _centerDialog<T>(BuildContext context, Widget Function(BuildContext) builder) async {
  final Offset? popFrom = TapOrigin.last; // 연 자리 (그쪽에서 살짝 다가오듯 열리고, 그쪽으로 살짝 물러나듯 닫힘)
  // 도구 모음이 닫히며 화면을 다시 그리는 프레임과 겹치지 않게, 그 프레임이 끝난 뒤 창을 띄움 (뜰 때 덜 버벅임)
  await WidgetsBinding.instance.endOfFrame;
  if (!context.mounted) return null;
  final Duration dur = _dialogDur;
  final T? result = await showGeneralDialog<T>(
    context: context,
    barrierDismissible: true,
    barrierLabel: 'close',
    barrierColor: Colors.black54,
    transitionDuration: dur,
    pageBuilder: (ctx, _, __) => SafeArea(child: Center(child: builder(ctx))),
    transitionBuilder: (ctx, anim, _, child) => _softDialogTransition(ctx, anim, child, popFrom),
  );
  return result;
}

/// 고르기 창이 열리고 닫히는 움직임: 크게 튀지 않고, 연 자리 쪽에서 살짝 다가오며 커지고 서서히 또렷해짐.
/// 닫힐 때는 같은 길을 되돌아가며 뒤 배경 어두움과 같은 빠르기로 함께 사라짐 (창만 먼저 없어지지 않게)
Widget _softDialogTransition(BuildContext context, Animation<double> animation, Widget child, Offset? from) {
  final scale = CurvedAnimation(parent: animation, curve: Curves.easeOutCubic, reverseCurve: Curves.easeInCubic);
  final fade = CurvedAnimation(parent: animation, curve: const Interval(0, 0.7, curve: Curves.easeOut), reverseCurve: Curves.easeIn);
  final Size screen = MediaQuery.sizeOf(context);
  final Offset center = screen.center(Offset.zero);
  // 연 자리 쪽으로 1/4만 치우쳐 (멀리서 날아오지 않게)
  final Offset origin = ((from ?? center) - center) * 0.25;
  return FadeTransition(
    opacity: fade,
    child: AnimatedBuilder(
      animation: scale,
      child: RepaintBoundary(child: child),
      builder: (context, child) => Transform.scale(scale: 0.86 + 0.14 * scale.value, origin: origin, child: child),
    ),
  );
}

/// 고르기 창 (페이지 표시·화면 회전): 제목 + 설명 + 아이콘 카드 목록. 누르면 고르고, 창이 닫힐 때 적용
Widget _choiceDialogBody<T>(
  BuildContext context, {
  required String title,
  String? subtitle,
  required List<(T, Widget, String, String)> options,
  required T selected,
  required ValueChanged<T> onTap,
  /// 여러 개를 함께 고를 수 있을 때 (페이지 모드: 탭·슬라이드): 켜져 있는지
  bool Function(T value)? isOn,
  /// 고른 카드 바로 밑에 붙는 것 (예: 슬라이드 → 책처럼 넘기기)
  Widget? Function(T value)? below,
}) {
  final cs = Theme.of(context).colorScheme;
  final bool dark = Theme.of(context).brightness == Brightness.dark;
  final Color sig = AppColors.of(context);
  // 고른 카드: 테마 대표 색을 옅게 / 아이콘 칸은 조금 더 진하게. 고르지 않은 카드는 밝은 바탕
  final Color selFill = Color.alphaBlend(sig.withValues(alpha: dark ? 0.55 : 0.32), cs.surfaceContainerHigh);
  final Color selTile = Color.alphaBlend(sig.withValues(alpha: dark ? 0.8 : 0.6), cs.surfaceContainerHigh);
  final Color offFill = dark ? cs.surfaceContainer : Color.alphaBlend(Colors.white.withValues(alpha: 0.6), cs.surfaceContainerLow);
  final Color offTile = Color.alphaBlend(sig.withValues(alpha: dark ? 0.25 : 0.14), cs.surfaceContainerHigh);
  final Color ink = cs.primary; // 테두리·체크 (라이트는 진한 색, 다크는 밝은 색)
  final Size screen = MediaQuery.sizeOf(context);
  // 휴대폰 가로처럼 높이가 낮으면: 카드를 옆으로 나란히 놓아 창 높이를 줄임
  final bool wide = screen.height < 560 && screen.width > screen.height;

  Widget check(bool on) => AnimatedContainer(
        // 고르면 진한 동그라미 안에 체크, 아니면 빈 동그라미
        duration: Anim.ms(160),
        width: wide ? 26 : 30,
        height: wide ? 26 : 30,
        decoration: BoxDecoration(
          shape: BoxShape.circle,
          color: on ? ink : Colors.transparent,
          border: Border.all(color: ink, width: 2.2),
        ),
        child: on ? Icon(Icons.check, size: wide ? 17 : 19, color: cs.onPrimary) : null,
      );

  Widget card(T value, Widget icon, String label, String desc) {
    final bool on = isOn?.call(value) ?? value == selected;
    final Widget tile = Container(
      width: wide ? 48 : 54,
      height: wide ? 48 : 54,
      decoration: BoxDecoration(color: on ? selTile : offTile, borderRadius: BorderRadius.circular(wide ? 14 : 16)),
      alignment: Alignment.center,
      child: IconTheme(data: IconThemeData(size: wide ? 26 : 28, color: cs.onSurface), child: icon),
    );
    final Widget body = wide
        ? Padding(
            padding: const EdgeInsets.fromLTRB(12, 12, 12, 12),
            child: Stack(
              children: [
                // 가로 배치: 아이콘·이름·설명을 카드 가운데에
                SizedBox(
                  width: double.infinity,
                  child: Column(
                  mainAxisSize: MainAxisSize.min,
                  crossAxisAlignment: CrossAxisAlignment.center,
                  children: [
                    tile,
                    const SizedBox(height: 8),
                    Text(label, textAlign: TextAlign.center, style: TextStyle(fontSize: 16, fontWeight: FontWeight.w800, color: cs.onSurface)),
                    const SizedBox(height: 2),
                    Text(desc, textAlign: TextAlign.center, maxLines: 2, overflow: TextOverflow.ellipsis, style: TextStyle(fontSize: 12.5, height: 1.3, color: cs.onSurfaceVariant)),
                  ],
                ),
                ),
                Positioned(top: 0, right: 0, child: check(on)),
              ],
            ),
          )
        : Padding(
            padding: const EdgeInsets.fromLTRB(14, 14, 16, 14),
            child: Row(
              children: [
                tile,
                const SizedBox(width: 16),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(label, style: TextStyle(fontSize: 18, fontWeight: FontWeight.w800, color: cs.onSurface)),
                      const SizedBox(height: 2),
                      Text(desc, style: TextStyle(fontSize: 14, color: cs.onSurfaceVariant)),
                    ],
                  ),
                ),
                const SizedBox(width: 10),
                check(on),
              ],
            ),
          );
    final Widget m = Material(
      color: on ? selFill : offFill,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(22),
        side: on ? BorderSide(color: ink, width: 2.2) : BorderSide(color: cs.outlineVariant.withValues(alpha: 0.7), width: 1),
      ),
      clipBehavior: Clip.antiAlias,
      child: InkWell(onTap: () => onTap(value), child: SizedBox(width: double.infinity, child: body)),
    );
    final Widget? extra = below?.call(value);
    if (extra == null) return m;
    return Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.stretch, children: [m, extra]);
  }

  final Widget dialog = Material(
    color: cs.surfaceContainerHigh,
    shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(wide ? 28 : 32)),
    clipBehavior: Clip.antiAlias,
    elevation: 8,
    child: ConstrainedBox(
      constraints: BoxConstraints(maxWidth: math.min(wide ? 680 : 460, screen.width - 40)),
      child: Padding(
        padding: wide ? const EdgeInsets.fromLTRB(20, 20, 20, 18) : const EdgeInsets.fromLTRB(22, 28, 22, 10),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Padding(
              padding: const EdgeInsets.only(left: 6),
              child: Text(title, style: TextStyle(fontSize: wide ? 21 : 24, fontWeight: FontWeight.w800, color: cs.onSurface)),
            ),
            if (subtitle != null)
              Padding(
                padding: EdgeInsets.only(left: 6, top: wide ? 4 : 8),
                child: Text(
                  wide ? subtitle.replaceAll('\n', ' ') : subtitle,
                  style: TextStyle(fontSize: wide ? 13.5 : 15, height: 1.4, color: cs.onSurfaceVariant),
                ),
              ),
            SizedBox(height: wide ? 14 : 18),
            if (wide)
              IntrinsicHeight(
                child: Row(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    for (int i = 0; i < options.length; i++) ...[
                      if (i > 0) const SizedBox(width: 10),
                      Expanded(child: card(options[i].$1, options[i].$2, options[i].$3, options[i].$4)),
                    ],
                  ],
                ),
              )
            else
              for (final (value, icon, label, desc) in options)
                Padding(padding: const EdgeInsets.only(bottom: 12), child: card(value, icon, label, desc)),
          ],
        ),
      ),
    ),
  );
  // 그래도 화면보다 크면 창 전체를 줄여서 다 보이게
  return FittedBox(fit: BoxFit.scaleDown, child: dialog);
}

/// 자동 (페이지 표시): 귀퉁이가 접힌 문서 + 줄 + 오른쪽 아래 톱니
class _AutoPageIcon extends StatelessWidget {
  const _AutoPageIcon({this.size, this.color});
  final double? size;
  final Color? color;

  @override
  Widget build(BuildContext context) {
    final it = IconTheme.of(context);
    final double sz = size ?? it.size ?? 24;
    return CustomPaint(size: Size.square(sz), painter: _AutoPagePainter(color ?? it.color ?? Theme.of(context).colorScheme.onSurface));
  }
}

class _AutoPagePainter extends CustomPainter {
  _AutoPagePainter(this.color);
  final Color color;

  @override
  void paint(Canvas canvas, Size size) {
    final double u = size.width / 24; // 24칸 기준
    final stroke = Paint()
      ..color = color
      ..style = PaintingStyle.stroke
      ..strokeWidth = 1.8 * u
      ..strokeJoin = StrokeJoin.round
      ..strokeCap = StrokeCap.round;
    canvas.saveLayer(Offset.zero & size, Paint());
    // 문서: 오른쪽 위 귀퉁이가 접힘
    final doc = Path()
      ..moveTo(5 * u, 3 * u)
      ..lineTo(13.5 * u, 3 * u)
      ..lineTo(18.5 * u, 8 * u)
      ..lineTo(18.5 * u, 20 * u)
      ..quadraticBezierTo(18.5 * u, 21 * u, 17.5 * u, 21 * u)
      ..lineTo(6 * u, 21 * u)
      ..quadraticBezierTo(5 * u, 21 * u, 5 * u, 20 * u)
      ..lineTo(5 * u, 4 * u)
      ..quadraticBezierTo(5 * u, 3 * u, 6 * u, 3 * u);
    canvas.drawPath(doc, stroke);
    final fold = Path()
      ..moveTo(13.5 * u, 3 * u)
      ..lineTo(13.5 * u, 8 * u)
      ..lineTo(18.5 * u, 8 * u);
    canvas.drawPath(fold, stroke);
    // 글줄
    for (final (double y, double x2) in [(11.0, 15.5), (14.5, 13.0), (18.0, 11.0)]) {
      canvas.drawLine(Offset(8 * u, y * u), Offset(x2 * u, y * u), stroke);
    }
    // 톱니 자리 비우기 (문서 선과 겹치지 않게)
    final Offset c = Offset(18.2 * u, 18.2 * u);
    canvas.drawCircle(c, 5.6 * u, Paint()..blendMode = BlendMode.clear);
    // 톱니: 둥근 몸통 + 이 8개 + 가운데 구멍
    final fill = Paint()..color = color;
    final double rBody = 3.4 * u;
    for (int i = 0; i < 8; i++) {
      canvas.save();
      canvas.translate(c.dx, c.dy);
      canvas.rotate(i * math.pi / 4);
      canvas.drawRRect(RRect.fromRectAndRadius(Rect.fromCenter(center: Offset(0, -rBody - 0.6 * u), width: 2.1 * u, height: 2.4 * u), Radius.circular(0.5 * u)), fill);
      canvas.restore();
    }
    canvas.drawCircle(c, rBody, fill);
    canvas.drawCircle(c, 1.4 * u, Paint()..blendMode = BlendMode.clear);
    canvas.restore();
  }

  @override
  bool shouldRepaint(_AutoPagePainter old) => old.color != color;
}

/// 세로 고정·가로 고정: 휴대폰 테두리 + 위 스피커 + 아래 동그라미
class _PhoneIcon extends StatelessWidget {
  const _PhoneIcon({required this.mode, this.size, this.color});
  final String mode; // 'portrait' / 'landscape' / 'auto'
  final double? size;
  final Color? color;

  @override
  Widget build(BuildContext context) {
    final it = IconTheme.of(context);
    final double sz = size ?? it.size ?? 24;
    return CustomPaint(size: Size.square(sz), painter: _PhonePainter(color ?? it.color ?? Theme.of(context).colorScheme.onSurface, mode));
  }
}

class _PhonePainter extends CustomPainter {
  _PhonePainter(this.color, this.mode);
  final Color color;
  final String mode;

  /// 자물쇠 모양을 뚫음 (몸통 + 고리), [c] 가운데, [k] 크기 배율
  void _lockHole(Canvas canvas, double u, Offset c, double k) {
    final clear = Paint()..blendMode = BlendMode.clear;
    canvas.drawRRect(
        RRect.fromRectAndRadius(Rect.fromCenter(center: c + Offset(0, 2.0 * k * u), width: 6.6 * k * u, height: 5.2 * k * u), Radius.circular(1.0 * k * u)), clear);
    final double r = 2.05 * k * u, top = c.dy - 1.6 * k * u;
    canvas.drawPath(
        Path()
          ..moveTo(c.dx - r, c.dy + 0.6 * k * u)
          ..lineTo(c.dx - r, top)
          ..arcTo(Rect.fromCircle(center: Offset(c.dx, top), radius: r), math.pi, math.pi, false)
          ..lineTo(c.dx + r, c.dy + 0.6 * k * u),
        Paint()
          ..blendMode = BlendMode.clear
          ..style = PaintingStyle.stroke
          ..strokeWidth = 1.55 * k * u);
  }

  @override
  void paint(Canvas canvas, Size size) {
    final double u = size.width / 24;
    final fill = Paint()..color = color;
    final Offset c = size.center(Offset.zero);
    if (mode == 'auto') {
      // 자동: 가운데 기운 휴대폰(채움) + 둘레를 시계 방향으로 도는 화살표 두 개
      canvas.save();
      canvas.translate(c.dx, c.dy);
      canvas.rotate(-math.pi / 4);
      canvas.drawRRect(RRect.fromRectAndRadius(Rect.fromCenter(center: Offset.zero, width: 6.2 * u, height: 9.6 * u), Radius.circular(1.6 * u)), fill);
      canvas.restore();
      final stroke = Paint()
        ..color = color
        ..style = PaintingStyle.stroke
        ..strokeWidth = 1.8 * u
        ..strokeCap = StrokeCap.round;
      final double r = 9.3 * u;
      final rect = Rect.fromCircle(center: c, radius: r);
      for (final double start in [205.0, 25.0]) {
        final double a0 = start * math.pi / 180, sweep = 128 * math.pi / 180;
        canvas.drawArc(rect, a0, sweep, false, stroke);
        // 화살촉(채운 세모): 호 끝에서 도는 방향으로
        final double a1 = a0 + sweep;
        final Offset end = c + Offset(math.cos(a1), math.sin(a1)) * r;
        final Offset out = Offset(math.cos(a1), math.sin(a1)); // 바깥 방향
        final Offset fwd = Offset(-math.sin(a1), math.cos(a1)); // 도는 방향
        canvas.drawPath(
            Path()
              ..moveTo((end + out * 2.7 * u).dx, (end + out * 2.7 * u).dy)
              ..lineTo((end - out * 2.7 * u).dx, (end - out * 2.7 * u).dy)
              ..lineTo((end + fwd * 3.4 * u).dx, (end + fwd * 3.4 * u).dy)
              ..close(),
            fill);
      }
      return;
    }
    // 세로 고정: 채운 휴대폰에 자물쇠를 뚫음 / 가로 고정: 같은 휴대폰을 눕힘 (자물쇠는 똑바로)
    canvas.saveLayer(Offset.zero & size, Paint());
    final bool land = mode == 'landscape';
    final Rect body = land ? Rect.fromLTRB(2.5 * u, 6 * u, 21.5 * u, 18 * u) : Rect.fromLTRB(6 * u, 2.5 * u, 18 * u, 21.5 * u);
    canvas.drawRRect(RRect.fromRectAndRadius(body, Radius.circular(2.6 * u)), fill);
    _lockHole(canvas, u, land ? c + Offset(0, -0.4 * u) : c + Offset(0, -0.6 * u), land ? 0.82 : 1.0);
    canvas.restore();
  }

  @override
  bool shouldRepaint(_PhonePainter old) => old.color != color || old.mode != mode;
}

/// 페이지 표시: 한 페이지 / 두 페이지 / 자동. 누르면 고르고, 창이 닫힐 때 바뀌었으면 적용 ([onChanged])
Future<void> showPageDisplayDialog(
  BuildContext context, {
  required String current,
  required ViewerTr tr,
  required ValueChanged<String> onChanged,
  bool scrollMode = false,
}) async {
  String selected = current;
  await _centerDialog<void>(context, (ctx) {
    return StatefulBuilder(
      builder: (ctx, setState) => _choiceDialogBody<String>(
        ctx,
        title: tr('페이지 표시', 'Page Display', '页面显示', 'ページ表示'),
        subtitle: tr('탭·슬라이드 모드에서 적용돼요\n(스크롤 모드는 유지)', 'Applies in tap/slide mode\n(scroll mode stays the same)', '在点击/滑动模式下生效\n（滚动模式保持不变）', 'タップ・スライドモードで適用されます\n(スクロールモードはそのまま)'),
        options: [
          ('one', pageDisplayGlyph('one'), tr('한 페이지', 'One Page', '单页', '1ページ'), tr('한 번에 한 쪽씩 보기', 'One page at a time', '一次看一页', '1ページずつ表示')),
          ('two', pageDisplayGlyph('two'), tr('두 페이지', 'Two Pages', '双页', '2ページ'), tr('양쪽 두 페이지를 나란히 보기', 'Two pages side by side', '两页并排显示', '2ページを並べて表示')),
          ('auto', pageDisplayGlyph('auto'), tr('자동', 'Auto', '自动', '自動'), tr('화면이 넓으면 두 페이지, 좁으면 한 페이지', 'Two pages on wide screens, one on narrow', '屏幕宽时双页，窄时单页', '画面が広いと2ページ、狭いと1ページ')),
        ],
        selected: selected,
        onTap: (v) => setState(() => selected = v),
      ),
    );
  });
  if (selected != current) {
    await _afterDialogClosed();
    onChanged(selected);
  }
}

/// 페이지 모드 창에서 고른 것 (창을 닫을 때 바뀌었으면 돌려줌)
typedef PageModeChoice = ({bool tap, bool slide, bool scroll, bool curl, bool barOff});

/// 페이지 모드: 탭 / 슬라이드 / 스크롤 (탭과 슬라이드는 함께, 스크롤은 혼자)
/// 슬라이드를 고르면 밑에 [책처럼 넘기기], 스크롤을 고르면 밑에 [스크롤바 끄기]가 나옴.
/// 누를 때는 고르기만 하고, 창을 닫을 때 바뀐 것이 있으면 돌려줌
Future<PageModeChoice?> showPageModeDialog(
  BuildContext context, {
  required ViewerTr tr,
  required PageModeChoice current,
  bool allowScroll = true,
  bool allowCurl = true,
}) async {
  PageModeChoice c = current;
  await _centerDialog<void>(context, (ctx) {
    return StatefulBuilder(builder: (ctx, setState) {
      final cs = Theme.of(ctx).colorScheme;
      // 카드 밑에 붙는 켜기/끄기 한 줄
      Widget sub(String label, bool value, ValueChanged<bool> onChanged) => Padding(
            padding: const EdgeInsets.fromLTRB(18, 6, 4, 0),
            child: InkWell(
              borderRadius: BorderRadius.circular(14),
              onTap: () => onChanged(!value),
              child: Padding(
                padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 2),
                child: Row(children: [
                  Icon(Icons.subdirectory_arrow_right_rounded, size: 20, color: cs.onSurfaceVariant),
                  const SizedBox(width: 8),
                  Expanded(child: Text(label, style: TextStyle(fontSize: 15.5, fontWeight: FontWeight.w700, color: cs.onSurface))),
                  Switch(value: value, onChanged: onChanged),
                ]),
              ),
            ),
          );
      return _choiceDialogBody<String>(
        ctx,
        title: tr('페이지 모드', 'Page Mode', '翻页模式', 'ページモード'),
        subtitle: tr('스크롤은 탭·슬라이드와 함께 쓸 수 없어요\n탭과 슬라이드는 함께 쓸 수 있어요', 'Scroll cannot be combined with Tap or Slide\nTap and Slide can be used together', '滚动不能与点击、滑动同时使用\n点击和滑动可以同时使用', 'スクロールはタップ・スライドと併用できません\nタップとスライドは併用できます'),
        options: [
          ('tap', const PageModeIcon(mode: 'tap'), tr('탭', 'Tap', '点击', 'タップ'), tr('화면 양옆을 눌러 넘기기', 'Tap the sides of the screen to turn', '点击屏幕两侧翻页', '画面の左右をタップしてめくる')),
          ('slide', const PageModeIcon(mode: 'slide'), tr('슬라이드', 'Slide', '滑动', 'スライド'), tr('옆으로 밀어 넘기기', 'Swipe sideways to turn', '左右滑动翻页', '横にスワイプしてめくる')),
          if (allowScroll)
            ('scroll', const PageModeIcon(mode: 'scroll'), tr('스크롤', 'Scroll', '滚动', 'スクロール'), tr('쪽을 위아래로 이어 보기', 'Pages flow top to bottom', '页面上下连续显示', 'ページを上下に続けて表示')),
        ],
        selected: '',
        isOn: (v) => switch (v) { 'tap' => c.tap, 'slide' => c.slide, _ => c.scroll },
        below: (v) {
          if (v == 'slide' && c.slide && allowCurl) {
            return sub(tr('책처럼 넘기기', 'Book page turn', '书本翻页', '本のようにめくる'), c.curl, (b) => setState(() => c = (tap: c.tap, slide: c.slide, scroll: c.scroll, curl: b, barOff: c.barOff)));
          }
          if (v == 'scroll' && c.scroll) {
            return sub(tr('스크롤바 끄기', 'Hide scroll bar', '隐藏滚动条', 'スクロールバーを隠す'), c.barOff, (b) => setState(() => c = (tap: c.tap, slide: c.slide, scroll: c.scroll, curl: c.curl, barOff: b)));
          }
          return null;
        },
        onTap: (v) => setState(() {
          switch (v) {
            case 'scroll':
              // 스크롤을 켜면 탭·슬라이드는 꺼짐 (끄면 탭으로)
              c = c.scroll ? (tap: true, slide: c.slide, scroll: false, curl: c.curl, barOff: c.barOff) : (tap: false, slide: false, scroll: true, curl: c.curl, barOff: c.barOff);
            case 'tap':
              final bool tap = !c.tap;
              // 하나는 남겨 둠 (모두 끄면 넘길 수 없음)
              if (!tap && !c.slide && !c.scroll) return;
              c = (tap: tap, slide: c.slide, scroll: false, curl: c.curl, barOff: c.barOff);
            default:
              final bool slide = !c.slide;
              if (!slide && !c.tap && !c.scroll) return;
              c = (tap: c.tap, slide: slide, scroll: false, curl: c.curl, barOff: c.barOff);
          }
        }),
      );
    });
  });
  if (c == current) return null;
  await _afterDialogClosed();
  return c;
}

/// 화면 회전: 자동 / 세로 고정 / 가로 고정 ('auto' / 'portrait' / 'landscape'). 누르면 고르고, 창이 닫힐 때 바뀌었으면 돌려줌
Future<String?> showRotationDialog(BuildContext context, {required String current, required ViewerTr tr}) async {
  String selected = current;
  await _centerDialog<void>(context, (ctx) {
    return StatefulBuilder(
      builder: (ctx, setState) => _choiceDialogBody<String>(
        ctx,
        title: tr('화면 회전', 'Screen Rotation', '屏幕旋转', '画面回転'),
        options: [
          for (final value in const ['auto', 'portrait', 'landscape'])
            (
              value,
              rotationGlyph(value),
              rotationLabel(value, tr),
              switch (value) {
                'portrait' => tr('세로 화면으로 유지', 'Stays in portrait', '保持竖屏', '縦画面のまま'),
                'landscape' => tr('가로 화면으로 유지', 'Stays in landscape', '保持横屏', '横画面のまま'),
                _ => tr('기기 방향에 맞춰 회전', 'Rotates with the device', '随设备方向旋转', '端末の向きに合わせて回転'),
              },
            ),
        ],
        selected: selected,
        onTap: (v) => setState(() => selected = v),
      ),
    );
  });
  if (selected == current) return null;
  await _afterDialogClosed();
  return selected;
}

/// 쪽 번호 이름: '12페이지' · '12, 13페이지'
String pagesLabel(int page, int? next, ViewerTr tr) => next == null
    ? tr('$page페이지', 'Page $page', '第$page页', '${page}ページ')
    : tr('$page, $next페이지', 'Pages $page, $next', '第$page、$next页', '$page、${next}ページ');

/// 북마크할 때의 페이지 모드 이름 ('tap' · 'slide' · 'tap+slide' · 'scroll')
String bookmarkModeOf({required bool scroll, required bool tap, required bool slide}) =>
    scroll ? 'scroll' : (tap && slide ? 'tap+slide' : (slide ? 'slide' : 'tap'));

/// 북마크한 때의 보기 방식: 화면 회전·페이지 표시(스크롤 모드 말고)·페이지 모드의 아이콘과 이름
List<(Widget Function(double size, Color color), String)> _bookmarkModes(BookmarkItem bm, ViewerTr tr) => [
      if (bm.rotation != null)
        ((sz, c) => rotationGlyph(bm.rotation!, size: sz, color: c), switch (bm.rotation) {
          'portrait' => tr('세로 고정', 'Portrait lock', '锁定竖屏', '縦に固定'),
          'landscape' => tr('가로 고정', 'Landscape lock', '锁定横屏', '横に固定'),
          _ => tr('자동 회전', 'Auto-rotate', '自动旋转', '自動回転'),
        }),
      if (!bm.scroll && bm.display != null)
        ((sz, c) => pageDisplayGlyph(bm.display!, size: sz, color: c), switch (bm.display) {
          'one' => tr('한 페이지', 'One page', '单页', '1ページ'),
          'two' => tr('두 페이지', 'Two pages', '双页', '2ページ'),
          _ => tr('자동 표시', 'Auto display', '自动显示', '自動表示'),
        }),
      if ((bm.mode ?? (bm.scroll ? 'scroll' : null)) case final String m)
        ((sz, c) => PageModeIcon(mode: m, size: sz, color: c), switch (m) {
          'scroll' => tr('스크롤', 'Scroll', '滚动', 'スクロール'),
          'slide' => tr('슬라이드', 'Slide', '滑动', 'スライド'),
          'tap+slide' => tr('탭·슬라이드', 'Tap & slide', '点击·滑动', 'タップ・スライド'),
          _ => tr('탭', 'Tap', '点击', 'タップ'),
        }),
    ];

/// 북마크 목록 한 줄 아래쪽: 보기 방식(아이콘만, 이름은 길게 누르면)과 저장 시각
Widget bookmarkSubtitle(BuildContext context, BookmarkItem bm, ViewerTr tr) {
  final Color c = Theme.of(context).colorScheme.onSurfaceVariant;
  final modes = _bookmarkModes(bm, tr);
  final saved = Text(tr('저장 시각: ${bm.createdAt}', 'Saved: ${bm.createdAt}', '保存时间：${bm.createdAt}', '保存日時: ${bm.createdAt}'));
  if (modes.isEmpty) return saved;
  return Column(crossAxisAlignment: CrossAxisAlignment.start, mainAxisSize: MainAxisSize.min, children: [
    Padding(
      padding: const EdgeInsets.only(top: 3, bottom: 2),
      child: Wrap(spacing: 12, runSpacing: 2, children: [
        for (final (icon, label) in modes)
          Tooltip(message: label, child: icon(18, c)),
      ]),
    ),
    saved,
  ]);
}

/// 북마크 목록 위 줄: 북마크 아이콘 + 제목, [모두 지우기], [현재 페이지 북마크] (아이콘만)
Widget bookmarkSheetHeader(BuildContext context,
    {required ViewerTr tr, required bool already, required bool canClear, required String addLabel, VoidCallback? onAdd, required VoidCallback onClearAll}) {
  return ListTile(
    title: Row(children: [
      Icon(Icons.bookmarks_outlined, size: 22, color: Theme.of(context).colorScheme.onSurface),
      const SizedBox(width: 8),
      Flexible(child: Text(tr('북마크 목록', 'Bookmarks', '书签列表', 'ブックマーク一覧'), style: const TextStyle(fontWeight: FontWeight.w800, fontSize: 18))),
    ]),
    trailing: Row(mainAxisSize: MainAxisSize.min, children: [
      TextButton.icon(
        style: TextButton.styleFrom(foregroundColor: Colors.redAccent, visualDensity: VisualDensity.compact, padding: const EdgeInsets.symmetric(horizontal: 8)),
        icon: TrashLidIcon(open: false, size: 16, color: canClear ? Colors.redAccent : Theme.of(context).disabledColor),
        label: Text(tr('모두 지우기', 'Clear All', '全部删除', 'すべて削除')),
        onPressed: canClear ? onClearAll : null,
      ),
      const SizedBox(width: 4),
      // 같은 쪽(같은 보기 방식)은 한 번만 북마크
      Tooltip(
        message: already ? tr('북마크한 페이지예요', 'Already bookmarked', '已添加书签', 'ブックマーク済みです') : addLabel,
        child: ElevatedButton(
          style: ElevatedButton.styleFrom(minimumSize: const Size(52, 40), padding: const EdgeInsets.symmetric(horizontal: 14)),
          onPressed: already ? null : onAdd,
          child: Icon(already ? Icons.bookmark_added : Icons.bookmark_add, size: 20),
        ),
      ),
    ]),
  );
}

/// 북마크를 모두 지울지 물어봄
Future<bool> confirmClearBookmarks(BuildContext context, ViewerTr tr) async {
  final ok = await showPopDialog<bool>(
    context: context,
    builder: (ctx) => AlertDialog(
      title: Text(tr('모두 지우기', 'Clear All', '全部删除', 'すべて削除')),
      content: Text(tr('이 파일의 북마크를 모두 지울까요?', 'Delete all bookmarks in this file?', '要删除此文件的所有书签吗？', 'このファイルのブックマークをすべて削除しますか？')),
      actions: [
        TextButton(onPressed: () => Navigator.pop(ctx, false), child: Text(tr('취소', 'Cancel', '取消', 'キャンセル'))),
        TextButton(onPressed: () => Navigator.pop(ctx, true), child: Text(tr('지우기', 'Delete', '删除', '削除'), style: const TextStyle(color: Colors.redAccent))),
      ],
    ),
  );
  return ok == true;
}

/// 화면 회전 아이콘 (설정 창과 도구 모음이 같은 모양): 자동 / 세로 고정 / 가로 고정
Widget rotationGlyph(String mode, {double? size, Color? color}) =>
    _PhoneIcon(mode: mode == 'portrait' || mode == 'landscape' ? mode : 'auto', size: size, color: color);

String rotationLabel(String mode, ViewerTr tr) => switch (mode) {
      'portrait' => tr('세로 고정', 'Portrait Lock', '锁定竖屏', '縦に固定'),
      'landscape' => tr('가로 고정', 'Landscape Lock', '锁定横屏', '横に固定'),
      _ => tr('자동', 'Auto', '自动', '自動'),
    };

/// 페이지 표시 아이콘 (설정 창과 도구 모음이 같은 모양): 한 페이지 / 두 페이지 / 자동
Widget pageDisplayGlyph(String mode, {double? size, Color? color}) => switch (mode) {
      'two' => Icon(Icons.menu_book_outlined, size: size, color: color),
      'auto' => _AutoPageIcon(size: size, color: color),
      _ => Icon(Icons.insert_drive_file_outlined, size: size, color: color),
    };

/// 페이지 모드 아이콘: 탭(쪽 + 누른 자리) / 슬라이드(쪽 + 아래 양쪽 화살) / 스크롤(쪽 + 오른쪽 위아래 화살), 'tap+slide'는 슬라이드 귀퉁이에 누른 자리
class PageModeIcon extends StatelessWidget {
  const PageModeIcon({super.key, required this.mode, this.size, this.color});
  final String mode; // 'tap' / 'slide' / 'scroll' / 'tap+slide'(슬라이드 아이콘 귀퉁이에 탭 표시)
  final double? size;
  final Color? color;

  @override
  Widget build(BuildContext context) {
    final it = IconTheme.of(context);
    final double sz = size ?? it.size ?? 24;
    final Color c = color ?? it.color ?? Theme.of(context).colorScheme.onSurface;
    return CustomPaint(size: Size.square(sz), painter: _PageModePainter(c, mode));
  }
}

class _PageModePainter extends CustomPainter {
  _PageModePainter(this.color, this.mode);
  final Color color;
  final String mode;

  @override
  void paint(Canvas canvas, Size size) {
    final double u = size.width / 24; // 24칸 기준
    final stroke = Paint()
      ..color = color
      ..style = PaintingStyle.stroke
      ..strokeWidth = 1.8 * u
      ..strokeCap = StrokeCap.round
      ..strokeJoin = StrokeJoin.round;
    void chevron(List<double> p) => canvas.drawPath(
        Path()
          ..moveTo(p[0] * u, p[1] * u)
          ..lineTo(p[2] * u, p[3] * u)
          ..lineTo(p[4] * u, p[5] * u),
        stroke);
    void page(Rect r, List<(double, double, double)> lines) {
      canvas.drawRRect(RRect.fromRectAndRadius(Rect.fromLTRB(r.left * u, r.top * u, r.right * u, r.bottom * u), Radius.circular(1.8 * u)), stroke);
      for (final (y, x1, x2) in lines) {
        canvas.drawLine(Offset(x1 * u, y * u), Offset(x2 * u, y * u), stroke);
      }
    }

    // 양쪽 화살 (가로: 쪽 아래 / 세로: 쪽 오른쪽)
    void hArrow(double y, double x1, double x2) {
      chevron([x1, y, x2, y, x2, y]);
      chevron([x1 + 2.7, y - 2.5, x1, y, x1 + 2.7, y + 2.5]);
      chevron([x2 - 2.7, y - 2.5, x2, y, x2 - 2.7, y + 2.5]);
    }
    void vArrow(double x, double y1, double y2) {
      chevron([x, y1, x, y2, x, y2]);
      chevron([x - 2.5, y1 + 2.7, x, y1, x + 2.5, y1 + 2.7]);
      chevron([x - 2.5, y2 - 2.7, x, y2, x + 2.5, y2 - 2.7]);
    }

    switch (mode) {
      case 'slide':
        // 쪽 한 장 + 아래에 양쪽 화살 (옆으로 밀어 넘김)
        page(const Rect.fromLTRB(6, 2, 18, 16.5), [(6, 9, 15), (9.5, 9, 15), (13, 9, 12)]);
        hArrow(20.5, 3.5, 20.5);
      case 'tap+slide':
        // 탭+슬라이드: 슬라이드 아이콘(아래 화살은 짧게) + 오른쪽 아래 귀퉁이에 탭처럼 누른 자리
        canvas.saveLayer(Offset.zero & size, Paint());
        page(const Rect.fromLTRB(5, 2, 17, 16.5), [(6, 8, 14), (9.5, 8, 14), (13, 8, 11)]);
        hArrow(20.5, 2.5, 13);
        final Offset c = Offset(18.6 * u, 18.6 * u);
        canvas.drawCircle(c, 5.6 * u, Paint()..blendMode = BlendMode.clear);
        canvas.drawCircle(c, 4.1 * u, stroke);
        canvas.drawCircle(c, 1.8 * u, Paint()..color = color);
        canvas.restore();
      case 'scroll':
        // 쪽 한 장 + 오른쪽에 위아래 화살 (위아래로 이어 봄)
        page(const Rect.fromLTRB(3, 3, 14.5, 21), [(7.5, 6, 11.5), (11, 6, 11.5), (14.5, 6, 9)]);
        vArrow(20.5, 3.5, 20.5);
      default:
        // 탭: 쪽 한 장 + 오른쪽 아래를 누른 자리(점과 둘레) — '자동 표시'의 톱니처럼 귀퉁이에 얹음
        canvas.saveLayer(Offset.zero & size, Paint());
        page(const Rect.fromLTRB(4, 2.5, 16.5, 19.5), [(7, 7, 13.5), (10.5, 7, 12.5), (14, 7, 10)]);
        final Offset c = Offset(17.2 * u, 17.2 * u);
        canvas.drawCircle(c, 6.4 * u, Paint()..blendMode = BlendMode.clear);
        canvas.drawCircle(c, 4.7 * u, stroke);
        canvas.drawCircle(c, 2.1 * u, Paint()..color = color);
        canvas.restore();
    }
  }

  @override
  bool shouldRepaint(_PageModePainter old) => old.color != color || old.mode != mode;
}

/// 스크롤 모드: 쪽들을 간격 없이 세로로 이어 붙여 보여 주는 목록
class ContinuousPageController {
  _ContinuousPageListState? _state;

  /// [page]가 화면 맨 위에 오게
  void jumpToPage(int page) => _state?._jumpTo(page);

  /// 한 화면만큼 아래(+1)/위(-1)로 부드럽게
  void scrollByScreen(int dir) => _state?._scrollByScreen(dir);

  /// 확대돼 있는지
  bool get zoomed => ((_state?._scale ?? 1) - 1).abs() > 0.03;

  /// 확대를 처음(1배)으로 (보던 자리는 그대로)
  void resetZoom() => _state?._resetZoom();

  /// 화면에 가장 많이(비율로) 보이는 쪽 (스크롤 보기 북마크)
  int? get mostVisiblePage => _state?._mostVisible();
}

/// 뷰어 설정 페이지 모드: 스크롤을 켜기 직전의 탭·슬라이드 (스크롤을 다시 끄면 이대로 되돌림, 기억이 없으면 기본값 탭 + 슬라이드)
class PageModeMemory {
  static bool tap = true;
  static bool slide = true;
}

/// 스크롤 보기 오른쪽의 회색 막대: 지금 위치를 보여 주고, 끌면 그 비율 위치로 바로 이동
/// [ratio]: 0(처음)~1(끝), [viewFraction]: 화면에 보이는 부분 / 전체 (막대 길이)
class ScrollThumbBar extends StatefulWidget {
  const ScrollThumbBar({super.key, required this.ratio, required this.viewFraction, required this.onDragRatio, this.onDragStart, this.onDragEnd, this.left, this.color});

  /// 막대 색 (세피아처럼 회색이 잘 안 보이는 바탕에서 바꿈)
  final Color? color;

  /// 왼손잡이: 막대를 왼쪽에 (null이면 앱 설정 [leftHanded]를 따름)
  final bool? left;

  /// 뷰어 설정의 '왼손잡이' (스크롤 막대·도구 모음을 왼쪽에)
  static final ValueNotifier<bool> leftHanded = ValueNotifier<bool>(false);

  /// 뷰어 설정의 '스크롤바 끄기'
  static final ValueNotifier<bool> off = ValueNotifier<bool>(false);
  final double ratio;
  final double viewFraction;
  final ValueChanged<double> onDragRatio;
  final VoidCallback? onDragStart;
  final VoidCallback? onDragEnd;

  @override
  State<ScrollThumbBar> createState() => _ScrollThumbBarState();
}

class _ScrollThumbBarState extends State<ScrollThumbBar> {
  bool _dragging = false;
  double _dragRatio = 0;
  int? _dragPointer;

  @override
  Widget build(BuildContext context) {
    return ValueListenableBuilder<bool>(
      valueListenable: ScrollThumbBar.off,
      builder: (context, off, _) {
        if (off) return const SizedBox.shrink();
        if (widget.left != null) return _build(context, widget.left!);
        return ValueListenableBuilder<bool>(
          valueListenable: ScrollThumbBar.leftHanded,
          builder: (context, left, _) => _build(context, left),
        );
      },
    );
  }

  Widget _build(BuildContext context, bool left) {
    return LayoutBuilder(builder: (context, c) {
      final double h = c.maxHeight;
      if (!h.isFinite || h <= 0) return const SizedBox.shrink();
      final double thumb = (h * widget.viewFraction).clamp(44.0, math.max(44.0, h * 0.5)).toDouble();
      final double track = math.max(1, h - thumb);
      final double ratio = (_dragging ? _dragRatio : widget.ratio).clamp(0.0, 1.0).toDouble();
      void end() {
        if (!_dragging) return;
        setState(() => _dragging = false);
        widget.onDragEnd?.call();
      }

      return Stack(children: [
        // 위치 알림은 띄엄띄엄 오므로 그 사이를 이어 그려 막대가 부드럽게 따라오게 (끄는 중에는 손가락 그대로)
        AnimatedPositioned(
          duration: _dragging ? Duration.zero : Anim.ms(110),
          curve: Curves.linear,
          left: left ? 0 : null,
          right: left ? null : 0,
          top: ratio * track,
          width: 28, // 누르기 쉬운 범위 (보이는 막대는 가늘게)
          height: thumb,
          // 손가락이 닿자마자 이 막대가 잡음 (아래 화면의 끌기·확대 동작이 가로채지 못하게)
          child: RawGestureDetector(
            behavior: HitTestBehavior.opaque,
            gestures: <Type, GestureRecognizerFactory>{
              EagerGestureRecognizer: GestureRecognizerFactoryWithHandlers<EagerGestureRecognizer>(
                EagerGestureRecognizer.new,
                (_) {},
              ),
            },
            child: Listener(
              behavior: HitTestBehavior.opaque,
              onPointerDown: (e) {
                if (_dragPointer != null) return;
                _dragPointer = e.pointer;
                widget.onDragStart?.call();
                setState(() {
                  _dragging = true;
                  _dragRatio = widget.ratio.clamp(0.0, 1.0).toDouble();
                });
              },
              onPointerMove: (e) {
                if (e.pointer != _dragPointer) return;
                setState(() => _dragRatio = (_dragRatio + e.delta.dy / track).clamp(0.0, 1.0).toDouble());
                widget.onDragRatio(_dragRatio);
              },
              onPointerUp: (e) {
                if (e.pointer != _dragPointer) return;
                _dragPointer = null;
                end();
              },
              onPointerCancel: (e) {
                if (e.pointer != _dragPointer) return;
                _dragPointer = null;
                end();
              },
              child: Align(
                alignment: left ? Alignment.centerLeft : Alignment.centerRight,
                child: AnimatedContainer(
                  key: const ValueKey('thumb'),
                  duration: Anim.ms(120),
                  margin: EdgeInsets.only(left: left ? 3 : 0, right: left ? 0 : 3),
                  width: _dragging ? 9 : 6,
                  decoration: BoxDecoration(
                    color: (widget.color ?? Colors.grey).withValues(alpha: _dragging ? 0.95 : (widget.color == null ? 0.65 : 0.8)),
                    borderRadius: BorderRadius.circular(4),
                  ),
                ),
              ),
            ),
          ),
        ),
      ]);
    });
  }
}

class ContinuousPageList extends StatefulWidget {
  const ContinuousPageList({
    super.key,
    required this.count,
    required this.aspectOf,
    required this.pageBuilder,
    required this.initialPage,
    required this.onPageChanged,
    this.controller,
    this.background = Colors.black,
    this.gapColor,
    this.zoomable = true,
    this.gap = 0,
    this.onLongPressPage,
    this.markedPages = const {},
  });

  /// 북마크한 쪽: 쪽 왼쪽 위(테두리 선에서 시작)에 책갈피를 붙여 둠 (쪽과 함께 움직이고 확대·축소돼도 보임)
  final Set<int> markedPages;

  /// 쪽 사이 간격 줄 색 (없으면 바탕색 그대로). 바탕은 앱 테마 색, 간격 줄은 따로 고정된 색
  final Color? gapColor;

  /// 길게 누른 쪽 번호 (글자 복사 창 등)
  final ValueChanged<int>? onLongPressPage;

  final int count;

  /// 쪽의 높이/너비
  final double Function(int index) aspectOf;
  final Widget Function(BuildContext context, int index) pageBuilder;
  final int initialPage;
  final ValueChanged<int> onPageChanged;
  final ContinuousPageController? controller;
  final Color background;
  final bool zoomable;

  /// 쪽과 쪽 사이 빈칸 (확대 1배 기준)
  final double gap;

  @override
  State<ContinuousPageList> createState() => _ContinuousPageListState();
}

class _ContinuousPageListState extends State<ContinuousPageList> with SingleTickerProviderStateMixin {
  // 쪽 위치(확대 1배, 너비 = 화면 너비 기준). _tops[i]는 i번째 쪽의 위쪽 끝
  double _width = 0;
  double _height = 0;
  List<double> _tops = const [];
  int _current = -1;

  // 지금 보이는 자리: 확대 배율과 왼쪽 위 좌표(확대된 좌표)
  double _scale = 1;
  double _ox = 0;
  double _oy = 0;
  bool _placed = false;

  // 손가락 두 개로 벌리고 오므리기 / 한 손가락으로 끌기 (둘 다 여기서 직접 처리)
  double _startScale = 1;
  Offset _startContent = Offset.zero;
  int _pointers = 0;

  // 손을 뗀 뒤 미끄러지기·부드러운 이동
  late final Ticker _ticker = createTicker(_tick);
  Simulation? _simX, _simY;
  Duration _simStart = Duration.zero;
  bool _simStarted = false;

  @override
  void initState() {
    super.initState();
    widget.controller?._state = this;
  }

  @override
  void didUpdateWidget(covariant ContinuousPageList oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.controller != widget.controller) {
      oldWidget.controller?._state = null;
      widget.controller?._state = this;
    }
    if (oldWidget.count != widget.count) _tops = const [];
  }

  @override
  void dispose() {
    if (widget.controller?._state == this) widget.controller?._state = null;
    _ticker.dispose();
    super.dispose();
  }

  double get _maxScale => widget.zoomable ? 5 : 1;
  // 두 손가락으로 오므려 화면보다 작게도 볼 수 있음 (가운데에 놓임)
  double get _minScale => widget.zoomable ? 0.5 : 1;
  double get _contentHeight => (_tops.isEmpty ? 0 : _tops.last) * _scale;
  double get _maxX => math.max(0, _width * _scale - _width);
  double get _maxY => math.max(0, _contentHeight - _height);

  /// 쪽이 화면보다 짧으면(1쪽짜리 등) 위아래 가운데에 (슬라이드 보기처럼)
  double _padYFor(double scale) => math.max(0, (_height - (_tops.isEmpty ? 0 : _tops.last) * scale) / 2);

  void _clamp() {
    // 화면보다 작게 줄였으면 쪽을 가로 가운데에
    _ox = _scale < 1 ? -(_width - _width * _scale) / 2 : _ox.clamp(0.0, _maxX).toDouble();
    _oy = _oy.clamp(0.0, _maxY).toDouble();
  }

  void _layout(double width, double height) {
    final bool sameWidth = width == _width && _tops.length == widget.count + 1;
    _height = height;
    if (sameWidth) {
      _clamp();
      return;
    }
    // 화면 너비가 바뀌면(회전 등) 보던 쪽을 그대로
    final int page = _placed && _tops.length > 1 ? _pageAt(_oy) : widget.initialPage.clamp(0, math.max(0, widget.count - 1)).toInt();
    final double within = _placed && _tops.length > 1 ? ((_oy / _scale) - _tops[page]) / math.max(1, _tops[page + 1] - _tops[page]) : 0;
    _width = width;
    final tops = List<double>.filled(widget.count + 1, 0);
    for (int i = 0; i < widget.count; i++) {
      tops[i + 1] = tops[i] + width * widget.aspectOf(i) + (i < widget.count - 1 ? widget.gap : 0);
    }
    _tops = tops;
    if (widget.count > 0) {
      final double h = tops[page + 1] - tops[page];
      _oy = (tops[page] + within * h) * _scale;
    }
    _placed = true;
    _clamp();
    _current = page;
  }

  /// 화면 위쪽 1/3 지점에 걸친 쪽 (oy: 확대된 좌표)
  int _mostVisible() {
    if (_tops.length < 2) return _current;
    final double padY = _padYFor(_scale);
    final double y0 = (_oy - padY) / _scale, y1 = (_oy - padY + _height) / _scale;
    int best = _current;
    double bestF = -1;
    for (int i = math.max(0, _pageAt(_oy) - 2); i < widget.count && _tops[i] < y1; i++) {
      final double top = _tops[i], bottom = _tops[i + 1];
      final double seen = math.min(bottom, y1) - math.max(top, y0);
      final double f = seen / math.max(1.0, bottom - top);
      if (f > bestF + 0.001) {
        bestF = f;
        best = i;
      }
    }
    return best;
  }

  int _pageAt(double oy) {
    if (_tops.length < 2) return 0;
    final double y = (oy + _height / 3) / _scale;
    int lo = 0, hi = widget.count - 1;
    while (lo < hi) {
      final mid = (lo + hi + 1) >> 1;
      if (_tops[mid] <= y) {
        lo = mid;
      } else {
        hi = mid - 1;
      }
    }
    return lo;
  }

  void _moved() {
    _clamp();
    final p = _pageAt(_oy);
    if (p != _current && _tops.length > 1) {
      _current = p;
      widget.onPageChanged(p);
    }
    setState(() {});
  }

  void _stopSim() {
    if (_ticker.isActive) _ticker.stop();
    _simX = _simY = null;
  }

  void _tick(Duration elapsed) {
    if (!_simStarted) {
      _simStart = elapsed;
      _simStarted = true;
    }
    final double t = (elapsed - _simStart).inMicroseconds / 1e6;
    bool done = true;
    if (_simX != null) {
      _ox = _simX!.x(t);
      if (!_simX!.isDone(t)) done = false;
    }
    if (_simY != null) {
      _oy = _simY!.x(t);
      if (!_simY!.isDone(t)) done = false;
    }
    final double ox = _ox, oy = _oy;
    _moved();
    // 끝에 닿으면 멈춤
    if (_simX != null && (ox != _ox)) _simX = null;
    if (_simY != null && (oy != _oy)) _simY = null;
    if (done || (_simX == null && _simY == null)) _stopSim();
  }

  void _runSim({Simulation? x, Simulation? y}) {
    _stopSim();
    _simX = x;
    _simY = y;
    if (x == null && y == null) return;
    _simStarted = false;
    _ticker.start();
  }

  void _animateTo(double ox, double oy) {
    _runSim(
      x: (ox - _ox).abs() < 0.5 ? null : _EaseSimulation(_ox, ox, 0.26),
      y: (oy - _oy).abs() < 0.5 ? null : _EaseSimulation(_oy, oy, 0.26),
    );
  }

  // ── 오른쪽 회색 스크롤 막대: 끌면 문서 전체를 빠르게 이동 ──
  Widget? _scrollBar() {
    if (_tops.length < 2 || _maxY < 1 || _height <= 0 || _contentHeight <= 0) return null;
    return ScrollThumbBar(
      ratio: _oy / _maxY,
      viewFraction: _height / _contentHeight,
      onDragStart: _stopSim,
      onDragRatio: (r) {
        _oy = r * _maxY;
        _moved();
      },
    );
  }

  void _jumpTo(int page) {
    if (_tops.length < 2) return;
    _stopSim();
    final p = page.clamp(0, widget.count - 1).toInt();
    _oy = _tops[p] * _scale;
    _moved();
  }

  void _scrollByScreen(int dir) {
    if (_tops.length < 2) return;
    final double target = (_oy + dir * _height * 0.9).clamp(0.0, _maxY).toDouble();
    _animateTo(_ox, target);
  }

  Offset? _downLocal; // 손가락이 처음 닿은 자리

  void _resetZoom() {
    if ((_scale - 1).abs() < 0.0001 || _height <= 0) return;
    _stopSim();
    final double cy = (_oy + _height / 2 - _padYFor(_scale)) / _scale;
    _scale = 1;
    _ox = 0;
    _oy = cy - _height / 2 + _padYFor(1);
    _moved();
  }

  void _onScaleStart(ScaleStartDetails d) {
    _stopSim();
    _startScale = _scale;
    // 한 손가락 끌기: 손가락이 처음 닿은 자리를 기준으로 (움직이기 시작한 거리만큼 버리지 않고 그대로 따라오게)
    final Offset f = d.pointerCount <= 1 && _downLocal != null ? _downLocal! : d.localFocalPoint;
    _startContent = Offset((_ox + f.dx) / _scale, (_oy + f.dy - _padYFor(_scale)) / _scale);
    _pointers = d.pointerCount;
  }

  void _onScaleUpdate(ScaleUpdateDetails d) {
    // 손가락 수가 바뀌면 기준을 다시 잡아 튀지 않게
    if (d.pointerCount != _pointers) {
      _pointers = d.pointerCount;
      _startScale = _scale / (d.scale == 0 ? 1 : d.scale);
      _startContent = Offset((_ox + d.localFocalPoint.dx) / _scale, (_oy + d.localFocalPoint.dy - _padYFor(_scale)) / _scale);
    }
    final double ns = (_startScale * d.scale).clamp(_minScale, _maxScale).toDouble();
    _scale = ns;
    _ox = _startContent.dx * ns - d.localFocalPoint.dx;
    _oy = _startContent.dy * ns - d.localFocalPoint.dy + _padYFor(ns);
    _moved();
  }

  void _onScaleEnd(ScaleEndDetails d) {
    final v = d.velocity.pixelsPerSecond;
    // 거의 원래 크기면 딱 맞춤
    if (_scale > 0.97 && _scale < 1.03 && _scale != 1) {
      _scale = 1;
      _moved();
    }
    _runSim(
      x: v.dx.abs() > 60 && _maxX > 0 ? ClampingScrollSimulation(position: _ox, velocity: -v.dx) : null,
      y: v.dy.abs() > 60 ? ClampingScrollSimulation(position: _oy, velocity: -v.dy) : null,
    );
  }

  @override
  Widget build(BuildContext context) {
    return ColoredBox(
      color: widget.background,
      child: LayoutBuilder(
        builder: (context, c) {
          _layout(c.maxWidth, c.maxHeight);
          final children = <Widget>[];
          if (_tops.length > 1) {
            final double s = _scale;
            final double padY = _padYFor(s);
            // 화면 앞뒤로 한 화면 반씩 더 그려 두어 움직일 때 비어 보이지 않게
            final double from = (_oy - _height * 1.5) / s, to = (_oy + _height * 2.5) / s;
            int i = _pageAt(math.max(0, _oy - _height * 1.5));
            while (i > 0 && _tops[i] > from) {
              i--;
            }
            for (; i < widget.count && _tops[i] < to; i++) {
              final double h = (_tops[i + 1] - _tops[i] - (i < widget.count - 1 ? widget.gap : 0)) * s;
              children.add(Positioned(
                key: ValueKey(i),
                left: -_ox,
                top: _tops[i] * s - _oy + padY,
                width: _width * s,
                height: h,
                child: RepaintBoundary(child: widget.pageBuilder(context, i)),
              ));
              if (widget.markedPages.contains(i)) {
                children.add(Positioned(
                  key: ValueKey('bm$i'),
                  left: -_ox + math.min(18.0, _width * s * 0.05),
                  top: _tops[i] * s - _oy + padY,
                  child: const IgnorePointer(child: BookmarkRibbon()),
                ));
              }
              // 쪽 사이 간격 줄 (화면 너비 전체)
              if (widget.gapColor != null && widget.gap > 0 && i < widget.count - 1) {
                children.add(Positioned(
                  key: ValueKey('gap$i'),
                  // 화면보다 작게 줄였을 때는 쪽 너비만큼만
                  left: s < 1 ? -_ox : 0,
                  width: s < 1 ? _width * s : c.maxWidth,
                  top: _tops[i] * s - _oy + padY + h,
                  height: widget.gap * s,
                  child: ColoredBox(color: widget.gapColor!),
                ));
              }
            }
          }
          final mq = MediaQuery.of(context);
          final Widget? bar = _scrollBar();
          // 끌기가 빨리 시작되게 (기본은 손가락이 꽤 움직여야 시작돼 화면이 끈적하게 느껴짐). 쪽 안의 다른 동작은 원래 값 그대로
          final Widget list = MediaQuery(
            data: mq.copyWith(gestureSettings: const DeviceGestureSettings(touchSlop: 6)),
            child: Listener(
            onPointerDown: (e) => _downLocal = e.localPosition,
            child: GestureDetector(
            behavior: HitTestBehavior.opaque,
            onScaleStart: _onScaleStart,
            onScaleUpdate: _onScaleUpdate,
            onScaleEnd: _onScaleEnd,
            onLongPressStart: widget.onLongPressPage == null
                ? null
                : (d) {
                    if (_tops.length < 2) return;
                    final double y = (_oy + d.localPosition.dy - _padYFor(_scale)) / _scale;
                    int p = 0;
                    while (p < widget.count - 1 && _tops[p + 1] <= y) {
                      p++;
                    }
                    widget.onLongPressPage!(p);
                  },
            child: MediaQuery(data: mq, child: ClipRect(child: Stack(clipBehavior: Clip.hardEdge, children: children))),
          ),
            ),
          );
          if (bar == null) return list;
          return Stack(fit: StackFit.expand, children: [list, bar]);
        },
      ),
    );
  }
}

/// 정해진 시간 동안 부드럽게 a → b
class _EaseSimulation extends Simulation {
  _EaseSimulation(this.a, this.b, this.seconds);
  final double a, b, seconds;

  @override
  double x(double time) => a + (b - a) * Curves.easeOutCubic.transform((time / seconds).clamp(0.0, 1.0).toDouble());

  @override
  double dx(double time) => 0;

  @override
  bool isDone(double time) => time >= seconds;
}

/// 그림 파일의 크기를 머리 부분만 읽어 빠르게 알아냄 (PNG·JPEG·WebP). 모르면 null
Size? readImageSizeSync(String path) {
  RandomAccessFile? f;
  try {
    f = File(path).openSync();
    final b = f.readSync(256 * 1024);
    if (b.length < 24) return null;
    // PNG
    if (b[0] == 0x89 && b[1] == 0x50 && b[2] == 0x4E && b[3] == 0x47) {
      final w = (b[16] << 24) | (b[17] << 16) | (b[18] << 8) | b[19];
      final h = (b[20] << 24) | (b[21] << 16) | (b[22] << 8) | b[23];
      return w > 0 && h > 0 ? Size(w.toDouble(), h.toDouble()) : null;
    }
    // JPEG: SOFn 표지 찾기
    if (b[0] == 0xFF && b[1] == 0xD8) {
      int i = 2;
      while (i + 9 < b.length) {
        if (b[i] != 0xFF) {
          i++;
          continue;
        }
        final m = b[i + 1];
        if (m == 0xD8 || m == 0x01 || (m >= 0xD0 && m <= 0xD7) || m == 0xFF) {
          i += m == 0xFF ? 1 : 2;
          continue;
        }
        final len = (b[i + 2] << 8) | b[i + 3];
        if (m >= 0xC0 && m <= 0xCF && m != 0xC4 && m != 0xC8 && m != 0xCC) {
          final h = (b[i + 5] << 8) | b[i + 6];
          final w = (b[i + 7] << 8) | b[i + 8];
          return w > 0 && h > 0 ? Size(w.toDouble(), h.toDouble()) : null;
        }
        i += 2 + len;
      }
      return null;
    }
    // WebP
    if (b[0] == 0x52 && b[1] == 0x49 && b[8] == 0x57 && b[9] == 0x45 && b.length >= 30) {
      final chunk = String.fromCharCodes(b.sublist(12, 16));
      if (chunk == 'VP8X') {
        final w = 1 + (b[24] | (b[25] << 8) | (b[26] << 16));
        final h = 1 + (b[27] | (b[28] << 8) | (b[29] << 16));
        return Size(w.toDouble(), h.toDouble());
      }
      if (chunk == 'VP8 ') {
        final w = (b[26] | (b[27] << 8)) & 0x3FFF;
        final h = (b[28] | (b[29] << 8)) & 0x3FFF;
        return w > 0 && h > 0 ? Size(w.toDouble(), h.toDouble()) : null;
      }
      if (chunk == 'VP8L') {
        final bits = b[21] | (b[22] << 8) | (b[23] << 16) | (b[24] << 24);
        return Size(((bits & 0x3FFF) + 1).toDouble(), (((bits >> 14) & 0x3FFF) + 1).toDouble());
      }
    }
    return null;
  } catch (_) {
    return null;
  } finally {
    try {
      f?.closeSync();
    } catch (_) {}
  }
}

// ── 설정 창 모양 (정렬 및 보기 창처럼): 고르기는 테두리 상자, 켜고 끄기는 스위치 줄 ──

/// 하나 고르기 상자 (ChoiceChip 자리). 고른 것은 굵은 테두리
class SettingOption extends StatelessWidget {
  const SettingOption({super.key, required this.label, required this.selected, this.onSelected});
  final Widget label;
  final bool selected;
  final ValueChanged<bool>? onSelected;

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    // 고른 상자: 연두색 바탕에 흰 글씨
    final Color sig = AppColors.of(context);
    return Material(
      color: selected ? sig : Colors.transparent,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(14),
        side: BorderSide(color: selected ? (Theme.of(context).brightness == Brightness.dark ? const Color(0xFFC8C8CF) : sig) : cs.outlineVariant, width: selected ? (Theme.of(context).brightness == Brightness.dark ? 1.8 : 1.5) : 1),
      ),
      child: InkWell(
        borderRadius: BorderRadius.circular(14),
        onTap: onSelected == null ? null : () => onSelected!(!selected),
        child: ConstrainedBox(
          constraints: const BoxConstraints(minHeight: 46),
          child: Center(
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
              child: DefaultTextStyle.merge(
                textAlign: TextAlign.center,
                style: TextStyle(
                  fontSize: 15,
                  fontWeight: selected ? FontWeight.w800 : FontWeight.w500,
                  color: selected ? AppColors.onSig(context) : cs.onSurfaceVariant,
                  shadows: selected ? AppColors.sigShadows(context) : null,
                ),
                child: label,
              ),
            ),
          ),
        ),
      ),
    );
  }
}

/// 켜고 끄기 줄 (FilterChip 자리): 왼쪽 이름, 오른쪽 스위치
class SettingToggle extends StatelessWidget {
  const SettingToggle({super.key, required this.label, required this.selected, this.onSelected});
  final Widget label;
  final bool selected;
  final ValueChanged<bool>? onSelected;

  @override
  Widget build(BuildContext context) {
    return InkWell(
      onTap: onSelected == null ? null : () => onSelected!(!selected),
      child: Padding(
        padding: const EdgeInsets.symmetric(vertical: 6),
        child: Row(
          children: [
            Expanded(child: DefaultTextStyle.merge(style: const TextStyle(fontSize: 16, fontWeight: FontWeight.w600), child: label)),
            Switch(value: selected, onChanged: onSelected),
          ],
        ),
      ),
    );
  }
}

/// 설정 묶음: 켜고 끄기 줄이면 세로로, 고르기 상자면 한 줄(3개까지) 또는 두 줄로 나란히
class SettingGroup extends StatelessWidget {
  const SettingGroup({super.key, required this.children});
  final List<Widget> children;

  @override
  Widget build(BuildContext context) {
    if (children.isEmpty) return const SizedBox.shrink();
    if (children.every((c) => c is SettingToggle)) {
      return Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: children);
    }
    final int perRow = children.length == 4 ? 2 : math.min(3, children.length);
    final rows = <Widget>[];
    for (int i = 0; i < children.length; i += perRow) {
      final part = children.sublist(i, math.min(children.length, i + perRow));
      rows.add(Padding(
        padding: EdgeInsets.only(top: i == 0 ? 0 : 10),
        child: Row(
          children: [
            for (int k = 0; k < perRow; k++) ...[
              if (k > 0) const SizedBox(width: 10),
              Expanded(child: k < part.length ? part[k] : const SizedBox.shrink()),
            ],
          ],
        ),
      ));
    }
    return Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: rows);
  }
}

/// 설정 창 맨 아래 '완료' 버튼
class SettingDoneButton extends StatelessWidget {
  const SettingDoneButton({super.key, required this.label, required this.onPressed});
  final String label;
  final VoidCallback onPressed;

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    return Padding(
      padding: const EdgeInsets.only(top: 18, bottom: 6),
      child: SizedBox(
        width: double.infinity,
        height: 52,
        child: FilledButton(
          style: FilledButton.styleFrom(
            backgroundColor: cs.onSurface,
            foregroundColor: cs.surface,
            shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
          ),
          onPressed: onPressed,
          child: Text(label, style: const TextStyle(fontSize: 16, fontWeight: FontWeight.w700)),
        ),
      ),
    );
  }
}

/// 파일을 처음 열 때 가운데에 뜨는 로딩: 돌아가는 원 + 문구 (+ 진행률)
class FileLoadingView extends StatelessWidget {
  const FileLoadingView({super.key, required this.label, this.progress, this.sublabel, this.dark = false, this.background});
  final String label;

  /// 0~1 (모르면 null: 문구에 %를 붙이지 않음)
  final double? progress;
  final String? sublabel;

  /// 어두운 바탕 위인가 (사진·PDF 화면)
  final bool dark;

  /// 뒤 바탕색 (알려 주면 앱 테마와 관계없이 바탕에 맞춰 잘 보이는 글자색)
  final Color? background;

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final Color? bg = background;
    final bool onDark = bg != null ? bg.computeLuminance() < 0.4 : dark;
    final Color fg = bg != null ? (onDark ? Colors.white : Colors.black) : (dark ? Colors.white : cs.onSurface);
    final p = progress;
    return Center(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          SizedBox(
            width: 46,
            height: 46,
            child: CircularProgressIndicator(
              strokeWidth: 4.5,
              strokeCap: StrokeCap.round,
              color: AppColors.signature,
              backgroundColor: fg.withValues(alpha: 0.12),
            ),
          ),
          const SizedBox(height: 16),
          Text(
            p == null ? label : '$label ${(p.clamp(0.0, 1.0) * 100).round()}%',
            style: TextStyle(fontSize: 14.5, fontWeight: FontWeight.w600, color: fg.withValues(alpha: 0.85)),
          ),
          if (sublabel != null) ...[
            const SizedBox(height: 4),
            Text(sublabel!, style: TextStyle(fontSize: 12, color: fg.withValues(alpha: 0.55))),
          ],
        ],
      ),
    );
  }
}

/// 탭 존 가이드라인: 파일을 열 때 화면을 누르는 구역을 보여 줌 (화면을 누르면 닫힘)
/// [tapTurn]: 탭으로 넘기는 보기면 앱 설정의 3×3 탭 영역대로 (아니면 화면 전체 = 메뉴)
class TapZoneGuide extends StatefulWidget {
  const TapZoneGuide({super.key, required this.tapTurn, required this.onClose, required this.tr});
  final bool tapTurn;
  final VoidCallback onClose;
  final String Function(String ko, String en, String zh, String ja) tr;

  @override
  State<TapZoneGuide> createState() => _TapZoneGuideState();
}

class _TapZoneGuideState extends State<TapZoneGuide> {
  bool _closing = false;

  void _close() {
    if (_closing) return;
    setState(() => _closing = true);
    Future<void>.delayed(const Duration(milliseconds: 180), widget.onClose);
  }

  Widget _label(BuildContext context, String text, {IconData? before, IconData? after}) => Container(
        padding: const EdgeInsets.symmetric(horizontal: 18, vertical: 9),
        // 메뉴·이전·다음 표시는 시그니쳐 색 바탕에 흰 글자
        decoration: BoxDecoration(color: AppColors.of(context), borderRadius: BorderRadius.circular(18)),
        child: Row(mainAxisSize: MainAxisSize.min, children: [
          if (before != null) Padding(padding: const EdgeInsets.only(right: 4), child: Icon(before, color: AppColors.onSig(context), size: 20, shadows: AppColors.sigShadows(context))),
          Text(text, style: TextStyle(color: AppColors.onSig(context), fontSize: 19, fontWeight: FontWeight.w800, shadows: AppColors.sigShadows(context))),
          if (after != null) Padding(padding: const EdgeInsets.only(left: 4), child: Icon(after, color: AppColors.onSig(context), size: 20, shadows: AppColors.sigShadows(context))),
        ]),
      );

  /// 3×3 칸을 같은 뜻끼리 이어진 덩어리로 묶어 그림: 덩어리가 네모면 한 칸처럼 크게, 아니면 칸마다 이름표
  List<Widget> _zoneCells(BuildContext context, String zones, Size size,
      {required String menu, required String prevLabel, required String nextLabel, required Color line}) {
    final double cw = size.width / 3, ch = size.height / 3;
    final List<int> group = List<int>.filled(9, -1);
    int groups = 0;
    for (int i = 0; i < 9; i++) {
      if (group[i] >= 0) continue;
      final stack = <int>[i];
      group[i] = groups;
      while (stack.isNotEmpty) {
        final int k = stack.removeLast();
        final int r = k ~/ 3, col = k % 3;
        for (final int n in [if (r > 0) k - 3, if (r < 2) k + 3, if (col > 0) k - 1, if (col < 2) k + 1]) {
          if (group[n] < 0 && zones[n] == zones[i]) {
            group[n] = groups;
            stack.add(n);
          }
        }
      }
      groups++;
    }
    Color fill(String z) => switch (z) {
          'M' => const Color(0x8CE8EAF6),
          'P' => const Color(0x8CF6F1E6),
          'N' => const Color(0x8CE3ECF6),
          _ => const Color(0x33000000),
        };
    Widget? label(String z) => switch (z) {
          'M' => _label(context, menu),
          'P' => _label(context, prevLabel, before: Icons.chevron_left_rounded),
          'N' => _label(context, nextLabel, after: Icons.chevron_right_rounded),
          _ => null,
        };
    // 바탕: 칸 경계에 옅은 줄이 생기지 않게 한 번에 (가장자리 흐림 없이) 칠함
    final out = <Widget>[
      Positioned.fill(child: CustomPaint(painter: _ZoneFillPainter([for (int i = 0; i < 9; i++) fill(zones[i])]))),
    ];
    // 이름표는 덩어리마다 하나: 꽉 찬 네모면 그 가운데, 아니면 덩어리 한가운데에 가장 가까운 칸에
    for (int g = 0; g < groups; g++) {
      final cells = [for (int i = 0; i < 9; i++) if (group[i] == g) i];
      final Widget? lb = label(zones[cells.first]);
      if (lb == null) continue;
      final int r0 = cells.map((i) => i ~/ 3).reduce(math.min), r1 = cells.map((i) => i ~/ 3).reduce(math.max);
      final int c0 = cells.map((i) => i % 3).reduce(math.min), c1 = cells.map((i) => i % 3).reduce(math.max);
      final bool rect = (r1 - r0 + 1) * (c1 - c0 + 1) == cells.length;
      Rect rc;
      if (rect) {
        rc = Rect.fromLTRB(c0 * cw, r0 * ch, (c1 + 1) * cw, (r1 + 1) * ch);
      } else {
        final double mr = cells.map((i) => (i ~/ 3).toDouble()).reduce((a, b) => a + b) / cells.length;
        final double mc = cells.map((i) => (i % 3).toDouble()).reduce((a, b) => a + b) / cells.length;
        double d2(int i) => math.pow(i ~/ 3 - mr, 2) + math.pow(i % 3 - mc, 2).toDouble();
        int best = cells.first;
        for (final i in cells) {
          if (d2(i) < d2(best) - 1e-9) best = i;
        }
        rc = Rect.fromLTWH((best % 3) * cw, (best ~/ 3) * ch, cw, ch);
      }
      out.add(Positioned.fromRect(rect: rc, child: Center(child: FittedBox(fit: BoxFit.scaleDown, child: lb))));
    }
    // 뜻이 다른 칸 사이에만 선
    for (int i = 0; i < 9; i++) {
      final int r = i ~/ 3, col = i % 3;
      if (col < 2 && group[i] != group[i + 1]) {
        out.add(Positioned(left: (col + 1) * cw - 1, top: r * ch, width: 2, height: ch, child: ColoredBox(color: line)));
      }
      if (r < 2 && group[i] != group[i + 3]) {
        out.add(Positioned(left: col * cw, top: (r + 1) * ch - 1, width: cw, height: 2, child: ColoredBox(color: line)));
      }
    }
    return out;
  }

  @override
  Widget build(BuildContext context) {
    final tr = widget.tr;
    const line = Color(0xFF9E9E9E);
    final String prev = tr('이전', 'Previous', '上一页', '前へ'), next = tr('다음', 'Next', '下一页', '次へ');
    // 읽기 방향(우→좌)과 상관없이 '이전' 칸은 이전, '다음' 칸은 다음
    return TweenAnimationBuilder<double>(
      tween: Tween<double>(begin: 0, end: _closing ? 0 : 1),
      duration: Anim.ms(180),
      builder: (context, t, child) => Opacity(opacity: t, child: child),
      // 화면 위에 따로 띄우는 것이라 Material로 감싸야 글자 밑에 노란 줄이 생기지 않음
      child: Material(
        type: MaterialType.transparency,
        child: GestureDetector(
        behavior: HitTestBehavior.opaque,
        onTap: _close,
        child: LayoutBuilder(builder: (context, c) {
          // 탭으로 넘기면 앱 설정의 3×3 탭 영역대로, 아니면 화면 전체 = 메뉴
          final String zones = widget.tapTurn ? StorageService.tapZones.value : 'MMMMMMMMM';
          return Stack(children: [
            ..._zoneCells(context, zones, c.biggest, menu: tr('메뉴', 'Menu', '菜单', 'メニュー'), prevLabel: prev, nextLabel: next, line: line),
            // 위쪽 안내 문구
            Positioned(
              left: 16,
              right: 16,
              top: MediaQuery.paddingOf(context).top + 14,
              child: Center(
                child: Container(
                  padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
                  decoration: BoxDecoration(color: const Color(0xE6222222), borderRadius: BorderRadius.circular(14)),
                  child: Text(
                    tr('탭 가이드라인은 앱 설정에서 끌 수 있어요\n화면을 누르면 닫혀요',
                        'You can turn off this tap guide in app settings\nTap to close',
                        '可在应用设置中关闭点击指引\n点击屏幕关闭',
                        'タップガイドはアプリ設定でオフにできます\n画面をタップすると閉じます'),
                    textAlign: TextAlign.center,
                    style: const TextStyle(color: Colors.white, fontSize: 14, height: 1.4, fontWeight: FontWeight.w600),
                  ),
                ),
              ),
            ),
          ]);
        }),
      ),
      ),
    );
  }
}

class _ZoneFillPainter extends CustomPainter {
  _ZoneFillPainter(this.colors);
  final List<Color> colors;

  @override
  void paint(Canvas canvas, Size size) {
    final double cw = size.width / 3, ch = size.height / 3;
    for (int i = 0; i < 9; i++) {
      final int r = i ~/ 3, c = i % 3;
      // 끝 칸은 화면 끝까지 (나눗셈 오차로 틈이 생기지 않게)
      final rect = Rect.fromLTRB(c * cw, r * ch, c == 2 ? size.width : (c + 1) * cw, r == 2 ? size.height : (r + 1) * ch);
      canvas.drawRect(rect, Paint()..color = colors[i]..isAntiAlias = false);
    }
  }

  @override
  bool shouldRepaint(_ZoneFillPainter old) => !listEquals(old.colors, colors);
}

/// 파일 화면이 다 열린 뒤(열리는 움직임이 끝난 뒤) 탭 존 가이드라인을 화면 위에 띄움. 닫히거나 화면을 나가면 사라짐
/// 돌려주는 OverlayEntry는 화면이 사라질 때 remove 해야 함
Future<OverlayEntry?> showTapZoneGuide(
  BuildContext context, {
  required bool Function() tapTurn,
  required String Function(String ko, String en, String zh, String ja) tr,
}) async {
  final anim = ModalRoute.of(context)?.animation;
  if (anim != null && anim.status != AnimationStatus.completed) {
    final done = Completer<void>();
    void listener(AnimationStatus s) {
      if (s == AnimationStatus.completed && !done.isCompleted) done.complete();
    }
    anim.addStatusListener(listener);
    await done.future.timeout(const Duration(seconds: 2), onTimeout: () {});
    anim.removeStatusListener(listener);
  }
  // 탭으로 넘기지 않는 보기(스크롤·슬라이드만 등)에서는 띄우지 않음
  if (!context.mounted || !tapTurn()) return null;
  final overlay = Overlay.maybeOf(context);
  if (overlay == null) return null;
  late OverlayEntry entry;
  entry = OverlayEntry(
    builder: (ctx) => TapZoneGuide(
      tapTurn: tapTurn(),
      tr: tr,
      onClose: () {
        if (entry.mounted) entry.remove();
      },
    ),
  );
  overlay.insert(entry);
  return entry;
}

/// 북마크할 때의 보기(페이지 모드·페이지 표시·화면 회전)로 돌려놓음. 바뀐 게 있으면 true (다시 그려질 때까지 기다리게)
/// 회전이 '자동'이었으면 지금 방향이 그때와 다를 때만 그 방향으로 돌림
Future<bool> restoreBookmarkView(
  BookmarkItem bm, {
  required BuildContext context,
  required String display,
  required String rotation,
  required bool scroll,
  required Future<void> Function(String display) setDisplay,
  required Future<void> Function(String rotation) setRotation,
  required Future<void> Function(bool scroll) setScroll,
}) async {
  bool changed = false;
  if (bm.scroll != scroll) {
    await setScroll(bm.scroll);
    changed = true;
  }
  final String? d = bm.display;
  if (d != null && d != display) {
    await setDisplay(d);
    changed = true;
  }
  final String? r = bm.rotation;
  if (r != null && context.mounted) {
    final size = MediaQuery.sizeOf(context);
    final bool landNow = size.width > size.height;
    String target = r;
    if (r == 'auto') target = bm.landscape == null || bm.landscape == landNow ? rotation : (bm.landscape! ? 'landscape' : 'portrait');
    if (target != rotation) {
      await setRotation(target);
      changed = true;
    }
  }
  return changed;
}
