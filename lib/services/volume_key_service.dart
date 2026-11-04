import 'dart:async';
import 'package:flutter/services.dart';

class VolumeKeyService {
  static const MethodChannel _methodChannel = MethodChannel('ebook_reader/volume_control');
  static const EventChannel _eventChannel = EventChannel('ebook_reader/volume_events');

  StreamSubscription? _subscription;
  DateTime _lastTriggered = DateTime.now();

  Future<void> startListening({
    required VoidCallback onVolumeUp,
    required VoidCallback onVolumeDown,
    int cooldownMs = 250,
  }) async {
    try {
      await _methodChannel.invokeMethod('setIntercept', {'enabled': true});
      _subscription = _eventChannel.receiveBroadcastStream().listen((event) {
        final now = DateTime.now();
        if (now.difference(_lastTriggered).inMilliseconds < cooldownMs) return;
        _lastTriggered = now;

        if (event == 'UP') {
          onVolumeUp();
        } else if (event == 'DOWN') {
          onVolumeDown();
        }
      });
    } on PlatformException catch (_) {}
  }

  Future<void> stopListening() async {
    await _subscription?.cancel();
    _subscription = null;
    try {
      await _methodChannel.invokeMethod('setIntercept', {'enabled': false});
    } on PlatformException catch (_) {}
  }
}
