import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../services/app_lock.dart';
import '../services/storage_service.dart';
import '../widgets/app_colors.dart';

String _tr(String ko, String en, String zh, String ja) => AppI18n.t(StorageService.appLangNotifier.value, ko: ko, en: en, zh: zh, ja: ja);

/// 잠금 해제 화면: 앱을 열 때(앱 전체를 덮음) 또는 파일을 열 때(화면으로 띄워 결과를 돌려줌)
class LockScreen extends StatefulWidget {
  const LockScreen({super.key, this.asRoute = false, this.title, this.onCheck});

  /// 화면으로 띄웠으면 풀었을 때 true를 돌려주며 닫힘 (뒤로 가면 false)
  final bool asRoute;

  /// 위 문구 (기본: 잠금을 해제해 주세요)
  final String? title;

  /// 맞게 입력했을 때 따로 할 일 (설정을 바꾸기 전 확인 등). 없으면 잠금을 풂
  final VoidCallback? onCheck;

  @override
  State<LockScreen> createState() => _LockScreenState();
}

class _LockScreenState extends State<LockScreen> {
  String? _msg;
  bool _bioBusy = false;

  bool get _bioOn => AppLock.biometric.value;

  @override
  void initState() {
    super.initState();
    // 생체 인식을 켰으면 화면이 뜨자마자 바로 물어봄
    if (_bioOn) WidgetsBinding.instance.addPostFrameCallback((_) => _bio());
  }

  Future<void> _bio() async {
    if (_bioBusy || !mounted) return;
    _bioBusy = true;
    final bool ok = await AppLock.biometricAuth();
    _bioBusy = false;
    if (ok && mounted) _done();
  }

  void _done() {
    HapticFeedback.selectionClick();
    if (widget.onCheck != null) {
      widget.onCheck!();
    } else {
      AppLock.unlocked();
    }
    if (widget.asRoute && mounted) Navigator.of(context).pop(true);
  }

  /// 잠시 기다려야 하면 그 안내 (아니면 null)
  String? _waitMsg() {
    final until = AppLock.waitUntil;
    if (until == null || !until.isAfter(DateTime.now())) return null;
    final int sec = until.difference(DateTime.now()).inSeconds + 1;
    return _tr('여러 번 틀려서 $sec초 뒤에 다시 할 수 있어요', 'Too many tries, try again in $sec s', '错误次数过多，请 $sec 秒后再试', '何度も間違えたため $sec 秒後にもう一度お試しください');
  }

  Future<bool> _check(String secret) async {
    final wait = _waitMsg();
    if (wait != null) {
      setState(() => _msg = wait);
      return false;
    }
    if (await AppLock.verify(secret)) {
      _done();
      return true;
    }
    HapticFeedback.heavyImpact();
    if (mounted) {
      setState(() => _msg = _waitMsg() ??
          (AppLock.method.value == 'pin'
              ? _tr('비밀번호가 맞지 않아요', 'Wrong PIN', '密码不正确', '暗証番号が違います')
              : _tr('패턴이 맞지 않아요', 'Wrong pattern', '图案不正确', 'パターンが違います')));
    }
    return false;
  }

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final bool pin = AppLock.method.value == 'pin';
    final Widget page = Material(
      color: Theme.of(context).scaffoldBackgroundColor,
      child: SafeArea(
        child: LayoutBuilder(
          builder: (context, box) => SingleChildScrollView(
            child: ConstrainedBox(
              constraints: BoxConstraints(minHeight: box.maxHeight, minWidth: box.maxWidth), // 넓은 화면에서도 가운데로
              child: Column(
                mainAxisAlignment: MainAxisAlignment.spaceBetween,
                children: [
                  Padding(
                    padding: const EdgeInsets.only(top: 56),
                    child: Column(children: [
                      Icon(Icons.lock_rounded, size: 44, color: cs.onSurface),
                      const SizedBox(height: 18),
                      Text(widget.title ?? _tr('잠금을 해제해 주세요', 'Unlock to continue', '请解锁', 'ロックを解除してください'),
                          style: const TextStyle(fontSize: 20, fontWeight: FontWeight.w800)),
                      const SizedBox(height: 10),
                      SizedBox(
                        height: 20,
                        child: Text(_msg ?? '', style: TextStyle(fontSize: 14, color: cs.error, fontWeight: FontWeight.w600)),
                      ),
                    ]),
                  ),
                  Padding(
                    padding: const EdgeInsets.symmetric(vertical: 24),
                    child: pin ? PinPad(length: AppLock.pinLength, onDone: _check) : PatternPad(onDone: _check),
                  ),
                  Padding(
                    padding: const EdgeInsets.only(bottom: 36),
                    child: _bioOn
                        ? SigPillButton(
                            icon: Icons.fingerprint,
                            label: _tr('생체 인식으로 해제', 'Unlock with biometrics', '使用生物识别解锁', '生体認証で解除'),
                            onTap: _bio,
                          )
                        : const SizedBox(height: 48),
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
    if (!widget.asRoute) return page;
    return Scaffold(
      appBar: AppBar(backgroundColor: Colors.transparent, elevation: 0, scrolledUnderElevation: 0),
      extendBodyBehindAppBar: true,
      body: page,
    );
  }
}

/// 새 비밀번호·패턴 정하기: 두 번 같게 넣으면 저장하고 true를 돌려줌
class LockSetupPage extends StatefulWidget {
  const LockSetupPage({super.key, required this.kind});

  /// 'pin' / 'pattern'
  final String kind;

  @override
  State<LockSetupPage> createState() => _LockSetupPageState();
}

class _LockSetupPageState extends State<LockSetupPage> {
  String? _first;
  String? _msg;
  int _round = 0; // 입력 칸을 새로 그리게

  bool get _pin => widget.kind == 'pin';

  Future<bool> _entered(String secret) async {
    if (_first == null) {
      setState(() {
        _first = secret;
        _msg = null;
        _round++;
      });
      return true;
    }
    if (_first != secret) {
      HapticFeedback.heavyImpact();
      setState(() {
        _first = null;
        _msg = _tr('처음 것과 달라요, 처음부터 다시 해 주세요', 'They did not match, start again', '两次不一致，请重新开始', '1回目と違います、最初からやり直してください');
        _round++;
      });
      return false;
    }
    await AppLock.setSecret(widget.kind, secret);
    if (mounted) Navigator.of(context).pop(true);
    return true;
  }

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final String title = _first == null
        ? (_pin
            ? _tr('새 비밀번호를 입력해 주세요', 'Enter a new PIN', '请输入新密码', '新しい暗証番号を入力してください')
            : _tr('새 패턴을 그려 주세요', 'Draw a new pattern', '请绘制新图案', '新しいパターンを描いてください'))
        : (_pin
            ? _tr('한 번 더 입력해 주세요', 'Enter it once more', '请再输入一次', 'もう一度入力してください')
            : _tr('한 번 더 그려 주세요', 'Draw it once more', '请再画一次', 'もう一度描いてください'));
    final String hint = _pin
        ? _tr('숫자 4~8자리', '4–8 digits', '4~8 位数字', '数字4〜8桁')
        : _tr('점을 4개 이상 이어 주세요', 'Connect at least 4 dots', '请连接至少 4 个点', '点を4つ以上つないでください');
    return Scaffold(
      appBar: AppBar(title: Text(_pin ? _tr('비밀번호', 'PIN', '密码', '暗証番号') : _tr('패턴', 'Pattern', '图案', 'パターン'), style: const TextStyle(fontWeight: FontWeight.w800))),
      body: SafeArea(
        child: LayoutBuilder(
          builder: (context, box) => SingleChildScrollView(
            child: ConstrainedBox(
              constraints: BoxConstraints(minHeight: box.maxHeight, minWidth: box.maxWidth), // 넓은 화면에서도 가운데로
              child: Column(
                mainAxisAlignment: MainAxisAlignment.spaceEvenly,
                children: [
                  Column(children: [
                    const SizedBox(height: 12),
                    Text(title, style: const TextStyle(fontSize: 20, fontWeight: FontWeight.w800)),
                    const SizedBox(height: 8),
                    Text(_msg ?? hint, style: TextStyle(fontSize: 14, fontWeight: FontWeight.w600, color: _msg != null ? cs.error : cs.onSurfaceVariant)),
                  ]),
                  Padding(
                    padding: const EdgeInsets.symmetric(vertical: 24),
                    child: _pin
                        ? PinPad(key: ValueKey(_round), onDone: _entered)
                        : PatternPad(key: ValueKey(_round), onDone: _entered),
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}

/// 대표 색 알약 단추 (흰 글씨, 밝은 테마는 옅은 그림자)
class SigPillButton extends StatelessWidget {
  const SigPillButton({super.key, required this.icon, required this.label, required this.onTap});
  final IconData icon;
  final String label;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final shadows = AppColors.sigShadows(context);
    return Material(
      color: AppColors.of(context),
      shape: const StadiumBorder(),
      clipBehavior: Clip.antiAlias,
      child: InkWell(
        onTap: onTap,
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 26, vertical: 13),
          child: Row(mainAxisSize: MainAxisSize.min, children: [
            Icon(icon, color: Colors.white, size: 22, shadows: shadows),
            const SizedBox(width: 10),
            Text(label, style: TextStyle(color: Colors.white, fontSize: 16, fontWeight: FontWeight.w700, shadows: shadows)),
          ]),
        ),
      ),
    );
  }
}

/// 비밀번호 숫자판. [length]가 있으면 그만큼 누르는 즉시 확인, 없으면(새로 정할 때) 4~8자리 + 확인 단추
class PinPad extends StatefulWidget {
  const PinPad({super.key, this.length = 0, required this.onDone});
  final int length;
  final Future<bool> Function(String pin) onDone;

  @override
  State<PinPad> createState() => _PinPadState();
}

class _PinPadState extends State<PinPad> {
  String _pin = '';
  bool _busy = false;

  bool get _fixed => widget.length > 0;

  Future<void> _submit() async {
    if (_busy) return;
    _busy = true;
    final bool ok = await widget.onDone(_pin);
    _busy = false;
    if (mounted && !ok) setState(() => _pin = '');
  }

  void _press(String d) {
    if (_busy || _pin.length >= 8) return;
    HapticFeedback.selectionClick();
    setState(() => _pin += d);
    if (_fixed && _pin.length >= widget.length) _submit();
  }

  void _back() {
    if (_busy || _pin.isEmpty) return;
    HapticFeedback.selectionClick();
    setState(() => _pin = _pin.substring(0, _pin.length - 1));
  }

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final Color sig = AppColors.mark(context);
    final int dots = _fixed ? widget.length : (_pin.length < 4 ? 4 : _pin.length);
    Widget key(Widget child, VoidCallback? onTap) => SizedBox(
          width: 84,
          height: 64,
          child: onTap == null
              ? Center(child: child)
              : Material(
                  color: Colors.transparent,
                  shape: const CircleBorder(),
                  clipBehavior: Clip.antiAlias,
                  child: InkWell(onTap: onTap, child: Center(child: child)),
                ),
        );
    Widget digit(String d) => key(Text(d, style: const TextStyle(fontSize: 26, fontWeight: FontWeight.w600)), () => _press(d));
    return Column(mainAxisSize: MainAxisSize.min, children: [
      Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          for (int i = 0; i < dots; i++)
            AnimatedContainer(
              duration: const Duration(milliseconds: 120),
              margin: const EdgeInsets.symmetric(horizontal: 7),
              width: 14,
              height: 14,
              decoration: BoxDecoration(
                shape: BoxShape.circle,
                color: i < _pin.length ? sig : Colors.transparent,
                border: Border.all(color: i < _pin.length ? sig : cs.outline, width: 1.6),
              ),
            ),
        ],
      ),
      const SizedBox(height: 30),
      for (final row in const [
        ['1', '2', '3'],
        ['4', '5', '6'],
        ['7', '8', '9'],
      ])
        Row(mainAxisSize: MainAxisSize.min, children: [for (final d in row) digit(d)]),
      Row(mainAxisSize: MainAxisSize.min, children: [
        // 새로 정할 때: 4자리 이상이면 확인
        _fixed
            ? key(const SizedBox.shrink(), null)
            : key(Icon(Icons.check_rounded, size: 28, color: _pin.length >= 4 ? sig : cs.outlineVariant), _pin.length >= 4 ? _submit : null),
        digit('0'),
        key(Icon(Icons.backspace_outlined, size: 24, color: cs.onSurfaceVariant), _back),
      ]),
    ]);
  }
}

/// 패턴 판: 3×3 점을 손가락으로 이어 그림 (점 4개 이상). 비밀값은 이은 점 번호를 '-'로 이은 글
class PatternPad extends StatefulWidget {
  const PatternPad({super.key, required this.onDone});
  final Future<bool> Function(String pattern) onDone;

  @override
  State<PatternPad> createState() => _PatternPadState();
}

class _PatternPadState extends State<PatternPad> {
  static const double _size = 270;
  final List<int> _dots = [];
  Offset? _finger;
  bool _error = false;
  bool _busy = false;
  Timer? _clear;

  Offset _center(int i) => Offset((i % 3 + 0.5) * _size / 3, (i ~/ 3 + 0.5) * _size / 3);

  void _hit(Offset p) {
    for (int i = 0; i < 9; i++) {
      if (_dots.contains(i) || (p - _center(i)).distance > 30) continue;
      // 두 점 사이를 건너뛰면 가운데 점도 이음 (휴대폰 패턴처럼)
      if (_dots.isNotEmpty) {
        final int a = _dots.last;
        final int mid = (a + i) ~/ 2;
        if ((a + i) % 2 == 0 && (a % 3 + i % 3) % 2 == 0 && (a ~/ 3 + i ~/ 3) % 2 == 0 && !_dots.contains(mid)) _dots.add(mid);
      }
      _dots.add(i);
      HapticFeedback.selectionClick();
      break;
    }
  }

  @override
  void dispose() {
    _clear?.cancel();
    super.dispose();
  }

  Future<void> _end() async {
    final List<int> got = List.of(_dots);
    setState(() => _finger = null);
    if (got.isEmpty || _busy) return;
    if (got.length < 4) {
      _fail();
      return;
    }
    _busy = true;
    final bool ok = await widget.onDone(got.join('-'));
    _busy = false;
    if (!mounted) return;
    if (ok) {
      setState(_dots.clear);
    } else {
      _fail();
    }
  }

  void _fail() {
    HapticFeedback.heavyImpact();
    setState(() => _error = true);
    _clear?.cancel();
    _clear = Timer(const Duration(milliseconds: 700), () {
      if (mounted) {
        setState(() {
          _error = false;
          _dots.clear();
        });
      }
    });
  }

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    return GestureDetector(
      onPanStart: (d) {
        if (_busy) return;
        _clear?.cancel();
        setState(() {
          _error = false;
          _dots.clear();
          _finger = d.localPosition;
          _hit(d.localPosition);
        });
      },
      onPanUpdate: (d) {
        if (_busy) return;
        setState(() {
          _finger = d.localPosition;
          _hit(d.localPosition);
        });
      },
      onPanEnd: (_) => _end(),
      child: CustomPaint(
        size: const Size.square(_size),
        painter: _PatternPainter(
          dots: List.of(_dots),
          finger: _finger,
          center: _center,
          line: _error ? cs.error : AppColors.mark(context),
          dot: cs.onSurface,
          ring: cs.onSurface.withValues(alpha: 0.12),
        ),
      ),
    );
  }
}

class _PatternPainter extends CustomPainter {
  _PatternPainter({required this.dots, required this.finger, required this.center, required this.line, required this.dot, required this.ring});
  final List<int> dots;
  final Offset? finger;
  final Offset Function(int) center;
  final Color line, dot, ring;

  @override
  void paint(Canvas canvas, Size size) {
    final pLine = Paint()
      ..color = line.withValues(alpha: 0.85)
      ..strokeWidth = 7
      ..strokeCap = StrokeCap.round
      ..strokeJoin = StrokeJoin.round
      ..style = PaintingStyle.stroke;
    if (dots.isNotEmpty) {
      final path = Path()..moveTo(center(dots.first).dx, center(dots.first).dy);
      for (final i in dots.skip(1)) {
        path.lineTo(center(i).dx, center(i).dy);
      }
      if (finger != null) path.lineTo(finger!.dx, finger!.dy);
      canvas.drawPath(path, pLine);
    }
    for (int i = 0; i < 9; i++) {
      final bool on = dots.contains(i);
      canvas.drawCircle(center(i), 22, Paint()..color = on ? line.withValues(alpha: 0.25) : ring);
      canvas.drawCircle(center(i), on ? 9 : 7, Paint()..color = on ? line : dot);
    }
  }

  @override
  bool shouldRepaint(_PatternPainter old) => true;
}
