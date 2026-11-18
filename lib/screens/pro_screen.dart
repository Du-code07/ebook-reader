import 'package:flutter/material.dart';

import '../services/pro.dart';
import '../services/storage_service.dart';
import '../widgets/app_colors.dart';

/// FReader 프로 구매 화면: 유료 기능, 무료 체험 상태, 구매 전 안내(청약철회 제한), 구매·구매 복원
class ProScreen extends StatefulWidget {
  const ProScreen({super.key, required this.lang});
  final String lang;

  @override
  State<ProScreen> createState() => _ProScreenState();
}

class _ProScreenState extends State<ProScreen> {
  bool _busy = false;

  String _t(String ko, String en, String zh, String ja) => AppI18n.t(widget.lang, ko: ko, en: en, zh: zh, ja: ja);

  @override
  void initState() {
    super.initState();
    // 가격·구매 여부를 다시 확인 (화면에 맞는 값으로)
    Pro.refresh().then((_) {
      if (mounted) setState(() {});
    });
  }

  void _snack(String msg) {
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(msg)));
  }

  String get _unavailableMsg => _t('지금은 Google Play 결제를 쓸 수 없어요\nPlay 스토어에서 설치한 앱인지, 인터넷에 연결돼 있는지 확인해 주세요',
      'Google Play billing is not available right now\nCheck that the app was installed from the Play Store and that you are online',
      '目前无法使用 Google Play 结算\n请确认应用是从 Play 商店安装的，并已连接网络',
      '現在 Google Play の決済を利用できません\nPlay ストアからインストールしたアプリか、インターネットに接続しているか確認してください');

  Future<void> _buy() async {
    setState(() => _busy = true);
    final status = await Pro.buy();
    if (!mounted) return;
    setState(() => _busy = false);
    switch (status) {
      case 'purchased':
      case 'owned':
        _snack(_t('FReader 프로를 구매했어요', 'You purchased FReader Pro', '已购买 FReader 专业版', 'FReader プロを購入しました'));
        break;
      case 'pending':
        _snack(_t('결제가 끝나면 기능이 열려요', 'Features unlock when the payment is complete', '付款完成后即可使用功能', '支払いが完了すると機能が使えます'));
        break;
      case 'canceled':
        break;
      case 'unavailable':
        _snack(_unavailableMsg);
        break;
      default:
        _snack(_t('결제하지 못했어요', 'The purchase could not be completed', '无法完成付款', '決済できませんでした'));
    }
  }

  Future<void> _restore() async {
    setState(() => _busy = true);
    final owned = await Pro.refresh();
    if (!mounted) return;
    setState(() => _busy = false);
    if (owned == null) {
      _snack(_unavailableMsg);
    } else if (owned) {
      _snack(_t('구매를 복원했어요', 'Your purchase was restored', '已恢复购买', '購入を復元しました'));
    } else {
      _snack(_t('이 Google 계정으로 구매한 기록이 없어요', 'No purchase was found for this Google account', '此 Google 账号没有购买记录', 'この Google アカウントの購入履歴がありません'));
    }
  }

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final Color sig = AppColors.of(context);
    final bool dark = Theme.of(context).brightness == Brightness.dark;
    final Color tile = sig.withValues(alpha: dark ? 0.32 : 0.18);
    final Color tileIcon = dark ? Colors.white : Color.lerp(sig, Colors.black, 0.35)!;

    Widget feature(IconData icon, String text) => Padding(
          padding: const EdgeInsets.symmetric(vertical: 7),
          child: Row(children: [
            Container(
              width: 40,
              height: 40,
              decoration: BoxDecoration(color: tile, borderRadius: BorderRadius.circular(12)),
              child: Icon(icon, size: 22, color: tileIcon),
            ),
            const SizedBox(width: 14),
            Expanded(child: Text(text, style: TextStyle(fontSize: 16, fontWeight: FontWeight.w700, color: cs.onSurface))),
          ]),
        );

    Widget note(String text) => Padding(
          padding: const EdgeInsets.only(bottom: 8),
          child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Padding(
              padding: const EdgeInsets.only(top: 7, right: 8),
              child: Container(width: 4, height: 4, decoration: BoxDecoration(color: cs.onSurfaceVariant, shape: BoxShape.circle)),
            ),
            Expanded(child: Text(text, style: TextStyle(fontSize: 13.5, height: 1.45, color: cs.onSurfaceVariant))),
          ]),
        );

    return Scaffold(
      appBar: AppBar(title: Text(_t('FReader 프로', 'FReader Pro', 'FReader 专业版', 'FReader プロ'), style: const TextStyle(fontWeight: FontWeight.w800))),
      body: SafeArea(
        child: ValueListenableBuilder<bool>(
          valueListenable: Pro.owned,
          builder: (context, owned, _) => ValueListenableBuilder<String?>(
            valueListenable: Pro.price,
            builder: (context, price, _) {
              final int left = Pro.trialDaysLeft;
              final String status = owned
                  ? _t('구매했어요. 모든 유료 기능을 쓸 수 있어요', 'Purchased. All paid features are unlocked', '已购买，所有付费功能均可使用', '購入済みです。すべての有料機能を使えます')
                  : left > 0
                      ? _t('무료 체험이 $left일 남았어요', '$left day(s) left in your free trial', '免费试用还剩 $left 天', '無料体験の残りは$left日です')
                      : _t('무료 체험이 끝났어요', 'Your free trial has ended', '免费试用已结束', '無料体験は終了しました');
              return ListView(
                padding: const EdgeInsets.fromLTRB(24, 8, 24, 24),
                children: [
                  Text(
                    _t('한 번 구매하면 아래 기능을 계속 쓸 수 있어요', 'Buy once to keep using these features', '一次购买即可持续使用以下功能', '一度購入すると、以下の機能をずっと使えます'),
                    style: TextStyle(fontSize: 17, fontWeight: FontWeight.w800, color: cs.onSurface),
                  ),
                  const SizedBox(height: 14),
                  feature(Icons.document_scanner_outlined, _t('문서 스캔', 'Scan Document', '扫描文档', '文書スキャン')),
                  feature(Icons.photo_library_outlined, _t('이미지 합치기', 'Merge Images', '合并图片', '画像結合')),
                  feature(Icons.picture_as_pdf_outlined, _t('PDF 합치기', 'Merge PDFs', '合并 PDF', 'PDF結合')),
                  feature(Icons.add_circle_outline, _t('앞으로 추가되는 유료 기능', 'Paid features added in the future', '今后新增的付费功能', '今後追加される有料機能')),
                  const SizedBox(height: 18),
                  Text(status, style: TextStyle(fontSize: 15, fontWeight: FontWeight.w700, color: cs.onSurface)),
                  const SizedBox(height: 18),
                  // 구매 전 안내 (약관 제5조: 가격·1회 구매·체험·청약철회 제한을 구매 전에 명확히 표시)
                  Container(
                    padding: const EdgeInsets.fromLTRB(16, 14, 16, 8),
                    decoration: BoxDecoration(color: cs.surfaceContainerHigh, borderRadius: BorderRadius.circular(16)),
                    child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                      Text(_t('구매 전에 확인해 주세요', 'Please check before buying', '购买前请确认', '購入前にご確認ください'),
                          style: TextStyle(fontSize: 14.5, fontWeight: FontWeight.w800, color: cs.onSurface)),
                      const SizedBox(height: 10),
                      if (price != null)
                        note(_t('가격: $price (1회 구매, 운영자가 앱을 제공하는 동안 계속 이용)', 'Price: $price (one-time purchase, usable for as long as the app is provided)',
                            '价格：$price（一次性购买，在应用提供期间可持续使用）', '価格：$price（買い切り。アプリの提供期間中ずっと利用できます）')),
                      note(_t('설치 후 ${Pro.trialDays}일 동안 유료 기능을 무료로 써 볼 수 있어요', 'You can try the paid features free for ${Pro.trialDays} days after installing',
                          '安装后 ${Pro.trialDays} 天内可免费试用付费功能', 'インストール後${Pro.trialDays}日間、有料機能を無料で試せます')),
                      note(_t('구매 후 7일 이내에 청약철회를 요청할 수 있어요. 다만 무료 체험을 제공하므로, 구매와 함께 유료 기능이 열리면 디지털 콘텐츠의 제공이 시작된 것으로 보아 청약철회가 제한될 수 있어요',
                          'You may request withdrawal within 7 days of purchase. However, as a free trial is provided, withdrawal may be limited once the paid features are unlocked, because supply of the digital content has begun',
                          '购买后 7 天内可申请撤销。但由于提供了免费试用，购买后付费功能一经开放即视为数字内容已开始提供，撤销可能受到限制',
                          '購入後7日以内に申込みの撤回を求められます。ただし無料体験を提供しているため、購入と同時に有料機能が使えるようになると、デジタルコンテンツの提供が始まったものとして撤回が制限される場合があります')),
                      note(_t('같은 Google 계정으로 앱을 다시 설치하면 구매가 복원돼요', 'Your purchase is restored when you reinstall the app with the same Google account',
                          '使用同一 Google 账号重新安装应用即可恢复购买', '同じ Google アカウントでアプリを再インストールすると購入が復元されます')),
                      note(_t('결제·환불은 Google Play에서 처리돼요. 문의: dudu.dev.pr@gmail.com', 'Payments and refunds are handled by Google Play. Contact: dudu.dev.pr@gmail.com',
                          '付款和退款由 Google Play 处理。咨询：dudu.dev.pr@gmail.com', '決済・返金は Google Play が処理します。お問い合わせ：dudu.dev.pr@gmail.com')),
                    ]),
                  ),
                  const SizedBox(height: 22),
                  if (!owned)
                    SizedBox(
                      height: 54,
                      child: FilledButton(
                        onPressed: _busy ? null : _buy,
                        child: _busy
                            ? const SizedBox(width: 22, height: 22, child: CircularProgressIndicator(strokeWidth: 2.4))
                            : Text(price == null
                                ? _t('구매하기', 'Buy', '购买', '購入する')
                                : _t('$price에 구매하기', 'Buy for $price', '以 $price 购买', '$priceで購入する'),
                                style: const TextStyle(fontSize: 16.5)),
                      ),
                    ),
                  const SizedBox(height: 6),
                  Center(
                    child: TextButton(
                      onPressed: _busy ? null : _restore,
                      child: Text(_t('구매 복원', 'Restore Purchase', '恢复购买', '購入を復元'),
                          style: TextStyle(fontWeight: FontWeight.w700, color: cs.onSurface)),
                    ),
                  ),
                ],
              );
            },
          ),
        ),
      ),
    );
  }
}
