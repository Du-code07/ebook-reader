import 'package:flutter/material.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../screens/pro_screen.dart';

/// 이리ERI 프로: 유료 기능(문서 스캔·이미지 합치기·PDF 합치기, 앞으로 추가되는 유료 기능)
/// - 무료 제공 기간(2027년 3월 1일 전)에는 모두 무료 (약관 제5조)
/// - 이 버전에는 결제 기능이 없음: 판매는 2027년 3월 1일 전에 나오는 업데이트부터
///   (그 뒤에도 이 버전을 쓰면 유료 기능이 잠기고 업데이트를 안내함)
class Pro {
  /// 무료 제공 기간: 이 날(2027년 3월 1일) 전까지는 유료 기능을 모두 무료로 (판매·체험 없음, 약관 제5조)
  static final DateTime freeUntil = DateTime(2027, 3, 1);

  /// 지금이 무료 제공 기간인지
  static bool get freePeriod => DateTime.now().isBefore(freeUntil);

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

  /// 앱 시작 때: 유료 기능 숨기기 설정을 읽음
  static Future<void> init() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      hidePaid.value = prefs.getBool(_kHidePaid) ?? false;
    } catch (_) {}
  }

  /// 유료 기능 숨기기를 쓸 수 있는지 (무료 제공 기간에는 유료 기능이 항상 보임)
  static bool get canHidePaid => !freePeriod;

  /// 파일 추가 메뉴에서 유료 기능을 숨기는지
  static bool get hidesPaid => hidePaid.value && canHidePaid;

  /// 유료 기능을 지금 쓸 수 있는지
  static bool get canUse => freePeriod;

  /// 유료 기능을 누를 때: 쓸 수 있으면 true, 아니면 이리ERI 프로 화면(업데이트 안내)을 띄움
  static Future<bool> ensure(BuildContext context, String lang) async {
    if (canUse) return true;
    await Navigator.of(context).push(MaterialPageRoute(builder: (_) => ProScreen(lang: lang)));
    return canUse;
  }
}
