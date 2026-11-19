import 'dart:async';
import 'package:flutter/services.dart';

class VolumeKeyService {
  static const MethodChannel _methodChannel = MethodChannel('ebook_reader/volume_control');
  static const EventChannel _eventChannel = EventChannel('ebook_reader/volume_events');

  static int _activeListenerCount = 0;
  StreamSubscription? _subscription;
  bool _isRegistered = false;

  Future<void> startListening({
    required VoidCallback onVolumeUp,
    required VoidCallback onVolumeDown,
  }) async {
    if (!_isRegistered) {
      _isRegistered = true;
      _activeListenerCount++;
    }
    try {
      await _methodChannel.invokeMethod('setIntercept', {'enabled': true});
    } catch (_) {}

    await _subscription?.cancel();
    _subscription = _eventChannel.receiveBroadcastStream().listen((event) {
      if (event == 'UP') {
        onVolumeUp();
      } else if (event == 'DOWN') {
        onVolumeDown();
      }
    });
  }

  Future<void> stopListening() async {
    await _subscription?.cancel();
    _subscription = null;
    if (_isRegistered) {
      _isRegistered = false;
      _activeListenerCount = (_activeListenerCount - 1).clamp(0, 100);
    }
    try {
      if (_activeListenerCount == 0) {
        await _methodChannel.invokeMethod('setIntercept', {'enabled': false});
      } else {
        await _methodChannel.invokeMethod('setIntercept', {'enabled': true});
      }
    } catch (_) {}
  }
}
