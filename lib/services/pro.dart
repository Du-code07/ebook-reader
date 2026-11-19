import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../screens/pro_screen.dart';
import 'storage_service.dart';

/// FReader 프로: 유료 기능(문서 스캔·이미지 합치기·PDF 합치기, 앞으로 추가되는 유료 기능)을 여는 1회 구매
/// - Google Play 결제 (Play Console의 1회성 상품 ID: [productId])
/// - 설치 후 처음 실행한 때부터 [trialLength] 동안 무료 체험 (시작일은 Block Store에도 기록)
class Pro {
  static const String productId = 'freader_pro';
  /// 무료 체험 기간. 출시용은 3일(Duration(days: 3)) — 지금은 체험이 끝나는 흐름을 확인하려고 30분
  static const Duration trialLength = Duration(minutes: 30);

  static const _ch = MethodChannel('ebook_reader/pdf_renderer');
  static const _kOwned = 'pro_owned_v1';
  static const _kTrialStart = 'pro_trial_start_v2';
  static const _kHidePaid = 'pro_hide_paid_v1';

  /// 앱 설정 > 유료 기능 숨기기: 파일 추가 메뉴에서 스캔·PDF 합치기·이미지 합치기를 숨김
  static final ValueNotifier<bool> hidePaid = ValueNotifier(false);

  static Future<void> setHidePaid(bool v) async {
    hidePaid.value = v;
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setBool(_kHidePaid, v);
    } catch (_) {}
  }

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
      hidePaid.value = prefs.getBool(_kHidePaid) ?? false;
      final ms = prefs.getInt(_kTrialStart);
      if (ms == null) {
        final now = DateTime.now();
        await prefs.setInt(_kTrialStart, now.millisecondsSinceEpoch);
        _trialStart = now;
      } else {
        _trialStart = DateTime.fromMillisecondsSinceEpoch(ms);
      }
    } catch (_) {}
    unawaited(_syncTrialStart());
    unawaited(refresh());
  }

  /// 체험 시작일을 Google Play 서비스(Block Store)와 맞춤: 둘 중 더 이른 날을 씀
  /// (앱을 지웠다 다시 깔거나 데이터를 지워도 같은 기기에서는 체험이 처음부터 다시 시작되지 않게)
  static Future<void> _syncTrialStart() async {
    try {
      final local = _trialStart?.millisecondsSinceEpoch ?? DateTime.now().millisecondsSinceEpoch;
      final remote = await _ch.invokeMethod<int>('trialStartGet');
      final start = (remote != null && remote > 0 && remote < local) ? remote : local;
      if (start != local) {
        _trialStart = DateTime.fromMillisecondsSinceEpoch(start);
        final prefs = await SharedPreferences.getInstance();
        await prefs.setInt(_kTrialStart, start);
        trialChanged.value++;
      }
      if (remote == null || remote != start) {
        await _ch.invokeMethod('trialStartSet', {'ms': start});
      }
    } catch (_) {}
  }

  /// 체험 시작일이 Block Store 값으로 바뀌면 화면이 다시 그리도록
  static final ValueNotifier<int> trialChanged = ValueNotifier(0);

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

  /// 무료 체험이 남은 시간 (Duration.zero면 끝남)
  static Duration get trialLeft {
    final start = _trialStart;
    if (start == null) return trialLength;
    final left = start.add(trialLength).difference(DateTime.now());
    if (left.isNegative) return Duration.zero;
    return left > trialLength ? trialLength : left;
  }

  static bool get trialActive => trialLeft > Duration.zero;

  /// 기간을 '3일'·'5시간'·'20분'처럼 (남은 시간은 올림)
  static String durationText(String lang, Duration d) {
    final int m = d.inSeconds <= 0 ? 0 : (d.inSeconds / 60).ceil();
    if (m >= 24 * 60) {
      final n = (m / (24 * 60)).ceil();
      return AppI18n.t(lang, ko: '$n일', en: '$n day(s)', zh: '$n 天', ja: '$n日');
    }
    if (m >= 60) {
      final n = (m / 60).ceil();
      return AppI18n.t(lang, ko: '$n시간', en: '$n hour(s)', zh: '$n 小时', ja: '$n時間');
    }
    final n = m < 1 ? 1 : m;
    return AppI18n.t(lang, ko: '$n분', en: '$n min', zh: '$n 分钟', ja: '$n分');
  }

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
