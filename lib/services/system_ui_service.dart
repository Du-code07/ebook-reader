import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter/services.dart';

/// 화면 위쪽 상태표시줄(시계·날짜·배터리 등)을 손가락으로 내렸을 때 상단바를 그만큼 내려 겹치지 않게 한다.
///
/// 앱은 평소 상태표시줄을 숨겨 두고, 위 끝에서 아래로 밀면 상태표시줄이 잠깐 화면 위에 겹쳐 보였다가
/// 저절로 다시 올라간다. 이때 안드로이드는 앱에 '상태표시줄이 보인다'고 알려 주지 않으므로,
/// 위 끝에서 아래로 미는 손짓을 직접 알아채서 상태표시줄이 보이는 동안 [statusBarTop]을 그 높이로 둔다.
/// (안드로이드는 상태표시줄을 약 2.3초 뒤, 또는 화면의 다른 곳을 누르면 곧바로 다시 올린다)
class SystemUiService {
  static const MethodChannel _channel = MethodChannel('ebook_reader/system_ui');

  /// 상단바를 내릴 높이(논리 픽셀). 상태표시줄이 숨겨져 있으면 0.
  static final ValueNotifier<double> statusBarTop = ValueNotifier<double>(0);

  static double _stable = 0; // 상태표시줄 본래 높이
  static double _shown = 0; // 상태표시줄이 실제로 보일 때 안드로이드가 알려 준 높이
  static bool _transient = false; // 손가락으로 잠깐 내린 상태
  static Timer? _hideTimer;

  // 위 끝에서 시작한 손짓
  static int? _edgePointer;
  static double _edgeStartY = 0;
  static Duration _edgeStartTime = Duration.zero;

  static const Duration _autoHide = Duration(milliseconds: 2300); // 아무것도 안 하면 다시 올라가는 시간
  static const Duration _touchHide = Duration(milliseconds: 350); // 다른 곳을 누르면 다시 올라가는 시간

  static double get _dpr =>
      PlatformDispatcher.instance.views.isNotEmpty ? PlatformDispatcher.instance.views.first.devicePixelRatio : 1.0;

  static void init() {
    _channel.setMethodCallHandler((call) async {
      if (call.method == 'statusBar') _apply(call.arguments);
      return null;
    });
    // 앱이 뜨기 전에 보낸 알림은 놓쳤을 수 있으므로 한 번 물어본다
    scheduleMicrotask(() async {
      try {
        _apply(await _channel.invokeMethod<Object?>('query'));
      } catch (_) {}
    });
  }

  static void _apply(Object? args) {
    if (args is! Map) return;
    final double dpr = _dpr <= 0 ? 1.0 : _dpr;
    final double top = (args['top'] as num?)?.toDouble() ?? 0;
    final double stable = (args['stable'] as num?)?.toDouble() ?? 0;
    _shown = args['visible'] == true ? top / dpr : 0;
    if (stable > 0) _stable = stable / dpr;
    _update();
  }

  static void _update() {
    final double v = _shown > 0 ? _shown : (_transient ? _stable : 0);
    if (statusBarTop.value != v) statusBarTop.value = v;
  }

  static void _showTransient() {
    _transient = true;
    _update();
    _scheduleHide(_autoHide);
  }

  static void _scheduleHide(Duration after) {
    _hideTimer?.cancel();
    _hideTimer = Timer(after, () {
      _transient = false;
      _update();
    });
  }

  /// 앱 전체를 감싼 Listener에서 호출
  static void onPointerDown(PointerDownEvent e) {
    if (_transient) {
      // 상태표시줄이 내려와 있는 동안 화면의 다른 곳을 누르면 안드로이드가 곧 다시 올린다
      _scheduleHide(_touchHide);
      return;
    }
    if (_stable <= 0 || _shown > 0) return;
    if (e.position.dy <= _stable + 4) {
      _edgePointer = e.pointer;
      _edgeStartY = e.position.dy;
      _edgeStartTime = e.timeStamp;
    }
  }

  static void onPointerMove(PointerMoveEvent e) {
    if (_edgePointer != e.pointer) return;
    if (e.timeStamp - _edgeStartTime > const Duration(milliseconds: 700)) {
      _edgePointer = null;
      return;
    }
    // 위 끝에서 아래로 충분히 밀었으면 안드로이드가 상태표시줄을 내린다
    if (e.position.dy - _edgeStartY >= (_stable * 0.7).clamp(14.0, 40.0)) {
      _edgePointer = null;
      _showTransient();
    }
  }

  static void onPointerEnd(PointerEvent e) {
    if (_edgePointer == e.pointer) _edgePointer = null;
  }
}
