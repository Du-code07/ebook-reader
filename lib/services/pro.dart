import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../screens/pro_screen.dart';

/// FReader 프로: 유료 기능(문서 스캔·이미지 합치기·PDF 합치기, 앞으로 추가되는 유료 기능)을 여는 1회 구매
/// - Google Play 결제 (Play Console의 1회성 상품 ID: [productId])
/// - 설치 후 처음 실행한 때부터 [trialDays]일 동안 무료 체험
class Pro {
  static const String productId = 'freader_pro';
  static const int trialDays = 7;

  static const _ch = MethodChannel('ebook_reader/pdf_renderer');
  static const _kOwned = 'pro_owned_v1';
  static const _kTrialStart = 'pro_trial_start_v1';

  /// 샀는지 (Play 스토어에서 확인한 값을 기기에 기억해 두어 인터넷이 없어도 바로 앎)
  static final ValueNotifier<bool> owned = ValueNotifier(false);

  /// Play 스토어가 알려 준 가격 (예: ₩5,500). 연결이 안 되면 null
  static final ValueNotifier<String?> price = ValueNotifier(null);

  static DateTime? _trialStart;

  /// 앱 시작 때: 기억해 둔 구매 여부·체험 시작일을 읽고, Play 스토어 확인은 뒤에서
  static Future<void> init() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      owned.value = prefs.getBool(_kOwned) ?? false;
      final ms = prefs.getInt(_kTrialStart);
      if (ms == null) {
        final now = DateTime.now();
        await prefs.setInt(_kTrialStart, now.millisecondsSinceEpoch);
        _trialStart = now;
      } else {
        _trialStart = DateTime.fromMillisecondsSinceEpoch(ms);
      }
    } catch (_) {}
    unawaited(refresh());
  }

  /// Play 스토어에서 구매 여부·가격을 다시 확인 (구매 복원도 이것). 연결이 안 되면 null
  static Future<bool?> refresh() async {
    try {
      final r = await _ch.invokeMapMethod<String, Object?>('billingQuery', {'product': productId});
      final p = r?['price'];
      if (p is String && p.isNotEmpty) price.value = p;
      final o = r?['owned'];
      if (o is bool) {
        await _setOwned(o);
        return o;
      }
    } catch (_) {}
    return null;
  }

  static Future<void> _setOwned(bool v) async {
    owned.value = v;
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setBool(_kOwned, v);
    } catch (_) {}
  }

  /// 무료 체험이 남은 날 (0이면 끝남)
  static int get trialDaysLeft {
    final start = _trialStart;
    if (start == null) return trialDays;
    final end = start.add(const Duration(days: trialDays));
    final left = end.difference(DateTime.now());
    if (left.isNegative) return 0;
    return (left.inMinutes / (24 * 60)).ceil().clamp(0, trialDays);
  }

  static bool get trialActive => trialDaysLeft > 0;

  /// 유료 기능을 지금 쓸 수 있는지
  static bool get canUse => owned.value || trialActive;

  /// 구매 창을 띄움. 결과: purchased·owned·pending·canceled·unavailable·error
  static Future<String> buy() async {
    String status;
    try {
      status = await _ch.invokeMethod<String>('billingBuy', {'product': productId}) ?? 'error';
    } catch (_) {
      status = 'unavailable';
    }
    if (status == 'purchased' || status == 'owned') await _setOwned(true);
    return status;
  }

  /// 유료 기능을 누를 때: 쓸 수 있으면 true, 아니면 FReader 프로 화면을 띄우고 산 뒤에만 true
  static Future<bool> ensure(BuildContext context, String lang) async {
    if (canUse) return true;
    await Navigator.of(context).push(MaterialPageRoute(builder: (_) => ProScreen(lang: lang)));
    return owned.value;
  }
}
