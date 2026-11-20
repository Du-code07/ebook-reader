import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../screens/pro_screen.dart';
import 'storage_service.dart';

/// 이리ERI 프로: 유료 기능(문서 스캔·이미지 합치기·PDF 합치기, 앞으로 추가되는 유료 기능)을 여는 1회 구매
/// - Google Play 결제 (Play Console의 1회성 상품 ID: [productId])
/// - 구매 화면의 [무료 체험] 버튼을 누른 때부터 [trialLength] 동안 무료 체험 (기기마다 한 번, 시작일은 Block Store에도 기록)
class Pro {
  static const String productId = 'eri_pro';
  /// 무료 제공 기간: 이 날(2027년 3월 1일) 전까지는 유료 기능을 모두 무료로 (판매·체험 없음, 약관 제5조)
  static final DateTime freeUntil = DateTime(2027, 3, 1);

  /// 지금이 무료 제공 기간인지
  static bool get freePeriod => DateTime.now().isBefore(freeUntil);

  /// 무료 체험 기간: 3일 (가격은 Play 스토어에 등록한 값을 그대로 보여 줌 — 5,500원)
  static const Duration trialLength = Duration(days: 3);

  static const _ch = MethodChannel('ebook_reader/pdf_renderer');
  static const _kOwned = 'pro_owned_v1';
  static const _kTrialStart = 'pro_trial_start_v3';
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
      // 무료 체험은 앱을 켤 때 시작하지 않음 (구매 화면의 [무료 체험] 버튼으로 시작)
      final ms = prefs.getInt(_kTrialStart);
      _trialStart = ms == null ? null : DateTime.fromMillisecondsSinceEpoch(ms);
    } catch (_) {}
    unawaited(_syncTrialStart());
    unawaited(refresh());
  }

  /// 체험 시작일을 Google Play 서비스(Block Store)와 맞춤: 둘 다 있으면 더 이른 날을 씀
  /// (앱을 지웠다 다시 깔거나 데이터를 지워도 같은 기기에서 이미 시작한 체험은 이어서 계산)
  static Future<void> _syncTrialStart() async {
    try {
      final int? local = _trialStart?.millisecondsSinceEpoch;
      final int? remote = await _ch.invokeMethod<int>('trialStartGet');
      final bool remoteOk = remote != null && remote > 0;
      if (local == null && !remoteOk) return; // 아직 체험을 시작한 적 없음
      final int start = (remoteOk && (local == null || remote < local)) ? remote : local!;
      if (start != local) {
        _trialStart = DateTime.fromMillisecondsSinceEpoch(start);
        final prefs = await SharedPreferences.getInstance();
        await prefs.setInt(_kTrialStart, start);
        trialChanged.value++;
      }
      if (!remoteOk || remote != start) {
        await _ch.invokeMethod('trialStartSet', {'ms': start});
      }
    } catch (_) {}
  }

  /// 무료 체험을 시작했는지 (끝난 경우 포함)
  static bool get trialStarted => _trialStart != null;

  /// 구매 화면의 [무료 체험] 버튼: 지금부터 체험 시작 (이미 시작했으면 그대로)
  static Future<void> startTrial() async {
    if (_trialStart != null) return;
    final now = DateTime.now();
    _trialStart = now;
    trialChanged.value++;
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setInt(_kTrialStart, now.millisecondsSinceEpoch);
    } catch (_) {}
    try {
      await _ch.invokeMethod('trialStartSet', {'ms': now.millisecondsSinceEpoch});
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
    if (start == null) return Duration.zero; // 시작 전
    final left = start.add(trialLength).difference(DateTime.now());
    if (left.isNegative) return Duration.zero;
    return left > trialLength ? trialLength : left;
  }

  static bool get trialActive => trialLeft > Duration.zero;

  /// 유료 기능 숨기기를 쓸 수 있는지 (구매했거나 무료 체험 중이면 쓸 수 없음 — 유료 기능이 항상 보임)
  static bool get canHidePaid => !freePeriod && !owned.value && !trialActive;

  /// 파일 추가 메뉴에서 유료 기능을 숨기는지
  static bool get hidesPaid => hidePaid.value && canHidePaid;

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
  static bool get canUse => freePeriod || owned.value || trialActive;

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

  /// 유료 기능을 누를 때: 쓸 수 있으면 true, 아니면 이리ERI 프로 화면을 띄우고 사거나 무료 체험을 시작한 뒤에만 true
  static Future<bool> ensure(BuildContext context, String lang) async {
    if (canUse) return true;
    await Navigator.of(context).push(MaterialPageRoute(builder: (_) => ProScreen(lang: lang, fromFeature: true)));
    return canUse; // 산 경우뿐 아니라 그 화면에서 무료 체험을 시작한 경우도
  }
}
