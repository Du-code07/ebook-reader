import 'package:flutter/services.dart';

/// 서재(첫 화면)에서는 상태표시줄(과 버튼식 내비게이션 바)을 늘 보이고,
/// 파일을 열어 보는 동안에는 모두 숨긴다.
/// 뷰어가 다른 뷰어로 바뀔 때(다음 파일 열기)도 숨김이 유지되도록 열린 뷰어 수를 센다.
class SystemBars {
  static const _channel = MethodChannel('ebook_reader/pdf_renderer');
  static int _viewers = 0;
  static bool _status = false;

  static Future<void> _set(bool library) async {
    try {
      await _channel.invokeMethod('setLibraryBars', {'on': library});
    } catch (_) {}
  }

  /// 뷰어 화면이 열릴 때 (initState)
  static void enterViewer() {
    _viewers++;
    _status = false;
    if (_viewers == 1) _set(false);
  }

  /// 뷰어 화면이 닫힐 때 (dispose)
  static void leaveViewer() {
    if (_viewers > 0) _viewers--;
    if (_viewers == 0) {
      _status = false;
      _set(true);
    }
  }

  /// 파일 열람 중 메뉴(위아래 막대)를 띄운 동안에는 상태표시줄도 보임. 같은 값이면 다시 보내지 않음
  static void viewerStatus(bool show) {
    if (_viewers == 0 || show == _status) return;
    _status = show;
    () async {
      try {
        await _channel.invokeMethod('setViewerStatusBar', {'show': show});
      } catch (_) {}
    }();
  }
}
