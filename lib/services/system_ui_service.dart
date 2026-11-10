import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

/// 화면 위쪽 상태표시줄(시계·배터리 등)을 손가락으로 내렸을 때, 그 높이를 앱에 알려 준다.
/// 앱은 평소 상태표시줄을 숨기고, 내리면 잠깐 화면 위에 겹쳐 보였다가 다시 숨겨지는데
/// 그동안 앱은 높이를 모르므로 상단바가 가려진다. 이 값만큼 상단바를 내려 겹치지 않게 한다.
class SystemUiService {
  static const MethodChannel _channel = MethodChannel('ebook_reader/system_ui');

  /// 상태표시줄이 보이는 동안의 높이(논리 픽셀). 숨겨지면 0.
  static final ValueNotifier<double> statusBarTop = ValueNotifier<double>(0);

  static void init() {
    _channel.setMethodCallHandler((call) async {
      if (call.method == 'statusBar') {
        final args = call.arguments;
        if (args is Map) {
          final bool visible = args['visible'] == true;
          final double px = (args['top'] as num?)?.toDouble() ?? 0;
          final double dpr = PlatformDispatcher.instance.views.isNotEmpty
              ? PlatformDispatcher.instance.views.first.devicePixelRatio
              : 1.0;
          statusBarTop.value = visible && dpr > 0 ? px / dpr : 0;
        }
      }
      return null;
    });
  }
}
