import 'dart:async';
import 'package:flutter/services.dart';

class VolumeKeyService {
  static const MethodChannel _methodChannel = MethodChannel('ebook_reader/volume_control');
  static const EventChannel _eventChannel = EventChannel('ebook_reader/volume_events');

  StreamSubscription? _subscription;

  Future<void> startListening({
    required VoidCallback onVolumeUp,
    required VoidCallback onVolumeDown,
    VoidCallback? onVolumeBothUnlock,
    VoidCallback? onSpenSinglePress,
    VoidCallback? onSpenDoublePress,
  }) async {
    await _methodChannel.invokeMethod('setIntercept', {'enabled': true});
    _subscription?.cancel();
    _subscription = _eventChannel.receiveBroadcastStream().listen((event) {
      if (event == 'UP') {
        onVolumeUp();
      } else if (event == 'DOWN') {
        onVolumeDown();
      } else if (event == 'VOL_BOTH_UNLOCK') {
        onVolumeBothUnlock?.call();
      } else if (event == 'SPEN_SINGLE') {
        onSpenSinglePress?.call();
      } else if (event == 'SPEN_DOUBLE') {
        onSpenDoublePress?.call();
      }
    });
  }

  Future<void> stopListening() async {
    await _subscription?.cancel();
    _subscription = null;
    try {
      await _methodChannel.invokeMethod('setIntercept', {'enabled': false});
    } catch (_) {}
  }
}
