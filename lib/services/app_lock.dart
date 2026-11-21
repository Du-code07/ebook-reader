import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'storage_service.dart';

/// 사생활 보호: 앱 잠금·모든 파일 잠금 (파일 자체의 비밀번호와는 별개)
/// 비밀번호(PIN)나 패턴, 지문·얼굴 인식으로 풂. 비밀번호·패턴은 소금을 섞은 SHA-256 값만 저장
class AppLock {
  static const MethodChannel _native = MethodChannel('ebook_reader/pdf_renderer');
  static const String _kApp = 'lock_app_launch', _kFiles = 'lock_files', _kMethod = 'lock_method';
  static const String _kHash = 'lock_hash', _kSalt = 'lock_salt', _kLen = 'lock_len', _kBio = 'lock_bio';

  /// 앱을 열 때 잠금
  static final ValueNotifier<bool> appLock = ValueNotifier<bool>(false);

  /// 파일을 열 때 잠금 (모든 파일)
  static final ValueNotifier<bool> fileLock = ValueNotifier<bool>(false);

  /// 'pin' 또는 'pattern'
  static final ValueNotifier<String> method = ValueNotifier<String>('pin');

  /// 지문·얼굴 인식으로도 풂
  static final ValueNotifier<bool> biometric = ValueNotifier<bool>(false);

  /// 지금 앱 화면이 잠겨 있음 (앱 전체를 덮는 잠금 화면을 보임)
  static final ValueNotifier<bool> locked = ValueNotifier<bool>(false);

  /// 비밀번호 자릿수 (다 누르면 바로 확인)
  static int pinLength = 0;
  static bool hasSecret = false;

  static DateTime? _leftAt;

  /// 앱을 나갔다가 이만큼 지나 돌아오면 다시 잠금 (파일 고르기·공유 창처럼 잠깐 다녀오는 것은 그대로)
  static const Duration relockAfter = Duration(minutes: 1);

  // 틀린 횟수가 많으면 잠시 기다리게
  static int _wrong = 0;
  static DateTime? waitUntil;

  static Future<void> init() async {
    final p = await SharedPreferences.getInstance();
    hasSecret = (p.getString(_kHash) ?? '').isNotEmpty;
    appLock.value = hasSecret && (p.getBool(_kApp) ?? false);
    fileLock.value = hasSecret && (p.getBool(_kFiles) ?? false);
    method.value = p.getString(_kMethod) == 'pattern' ? 'pattern' : 'pin';
    biometric.value = hasSecret && (p.getBool(_kBio) ?? false);
    pinLength = p.getInt(_kLen) ?? 0;
    locked.value = appLock.value;
    WidgetsBinding.instance.addObserver(_Observer());
  }

  static void _onLifecycle(AppLifecycleState state) {
    if (state == AppLifecycleState.paused || state == AppLifecycleState.hidden) {
      _leftAt ??= DateTime.now();
    } else if (state == AppLifecycleState.resumed) {
      final left = _leftAt;
      _leftAt = null;
      if (left == null || DateTime.now().difference(left) < relockAfter) return;
      if (appLock.value) locked.value = true;
    }
  }

  static Future<String> _hash(String salt, String secret) async =>
      await _native.invokeMethod<String>('lockHash', {'text': '$salt:$secret'}) ?? '';

  /// 새 비밀번호·패턴 저장 ([kind]: 'pin' / 'pattern')
  static Future<void> setSecret(String kind, String secret) async {
    final p = await SharedPreferences.getInstance();
    final rnd = math.Random.secure();
    final String salt = List.generate(16, (_) => rnd.nextInt(256).toRadixString(16).padLeft(2, '0')).join();
    await p.setString(_kSalt, salt);
    await p.setString(_kHash, await _hash(salt, secret));
    await p.setString(_kMethod, kind);
    await p.setInt(_kLen, kind == 'pin' ? secret.length : 0);
    method.value = kind;
    pinLength = kind == 'pin' ? secret.length : 0;
    hasSecret = true;
  }

  /// 맞는지 확인 (맞으면 틀린 횟수를 지움, 5번 틀리면 30초 기다리기)
  static Future<bool> verify(String secret) async {
    final p = await SharedPreferences.getInstance();
    final bool ok = (p.getString(_kHash) ?? '') == await _hash(p.getString(_kSalt) ?? '', secret);
    if (ok) {
      _wrong = 0;
      waitUntil = null;
    } else if (++_wrong >= 5) {
      _wrong = 0;
      waitUntil = DateTime.now().add(const Duration(seconds: 30));
    }
    return ok;
  }

  static Future<void> setAppLock(bool on) async {
    appLock.value = on;
    await (await SharedPreferences.getInstance()).setBool(_kApp, on);
  }

  static Future<void> setFileLock(bool on) async {
    fileLock.value = on;
    await (await SharedPreferences.getInstance()).setBool(_kFiles, on);
  }

  static Future<void> setBiometric(bool on) async {
    biometric.value = on;
    await (await SharedPreferences.getInstance()).setBool(_kBio, on);
  }

  /// 0 = 이 기기에서 쓸 수 없음, 1 = 쓸 수 있음, 2 = 등록된 지문·얼굴이 없음
  static Future<int> biometricStatus() async {
    try {
      return await _native.invokeMethod<int>('biometricStatus') ?? 0;
    } catch (_) {
      return 0;
    }
  }

  static Future<bool> biometricAuth() async {
    String tr(String ko, String en, String zh, String ja) => AppI18n.t(StorageService.appLangNotifier.value, ko: ko, en: en, zh: zh, ja: ja);
    try {
      return await _native.invokeMethod<bool>('biometricAuth', {
            'title': tr('잠금 해제', 'Unlock', '解锁', 'ロック解除'),
            'cancel': tr('취소', 'Cancel', '取消', 'キャンセル'),
          }) ??
          false;
    } catch (_) {
      return false;
    }
  }

  /// 앱 잠금을 풂
  static void unlocked() => locked.value = false;

  /// 파일을 열기 전에: 모든 파일 잠금이면 열 때마다 잠금 화면을 띄움. 풀었으면 true
  static Future<bool> unlockForFile(BuildContext context, Widget Function() lockPage) async {
    if (!fileLock.value || !hasSecret) return true;
    final bool? ok = await Navigator.of(context).push<bool>(PageRouteBuilder<bool>(
      opaque: true,
      transitionDuration: const Duration(milliseconds: 180),
      reverseTransitionDuration: const Duration(milliseconds: 140),
      pageBuilder: (_, __, ___) => lockPage(),
      transitionsBuilder: (_, a, __, child) => FadeTransition(opacity: a, child: child),
    ));
    return ok == true;
  }
}

class _Observer with WidgetsBindingObserver {
  @override
  void didChangeAppLifecycleState(AppLifecycleState state) => AppLock._onLifecycle(state);

  // 앱 잠금 화면에서 뒤로 가기: 뒤에 가려진 화면을 닫지 않고 앱을 나감
  @override
  Future<bool> didPopRoute() async {
    if (!AppLock.locked.value) return false;
    await SystemNavigator.pop();
    return true;
  }

  @override
  bool handleStartBackGesture(PredictiveBackEvent backEvent) => AppLock.locked.value;

  @override
  void handleCommitBackGesture() {
    if (AppLock.locked.value) SystemNavigator.pop();
  }
}
