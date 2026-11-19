import 'package:flutter/material.dart';

import '../services/pro.dart';
import '../services/storage_service.dart';
import '../widgets/app_colors.dart';

/// FReader 프로 구매 화면: 유료 기능, 무료 체험 상태, 구매 전 안내(청약철회 제한), 구매·구매 복원
class ProScreen extends StatefulWidget {
  const ProScreen({super.key, required this.lang, this.fromFeature = false});
  final String lang;

  /// 유료 기능을 누르다 열린 경우: 무료 체험을 시작하거나 사면 바로 닫고 그 기능으로 돌아감
  final bool fromFeature;

  @override
  State<ProScreen> createState() => _ProScreenState();
}

class _ProScreenState extends State<ProScreen> {
  bool _busy = false;

  /// Play 스토어에서 가격을 불러오는 중인지 (가격을 모르면 구매 버튼을 잠금 — 약관 제5조: 결제 전 가격 표시)
  bool _priceLoading = true;

  String _t(String ko, String en, String zh, String ja) => AppI18n.t(widget.lang, ko: ko, en: en, zh: zh, ja: ja);

  void _onTrial() {
    if (mounted) setState(() {});
  }

  @override
  void dispose() {
    Pro.trialChanged.removeListener(_onTrial);
    super.dispose();
  }

  @override
  void initState() {
    super.initState();
    Pro.trialChanged.addListener(_onTrial);
    // 가격·구매 여부를 다시 확인 (화면에 맞는 값으로)
    _loadPrice();
  }

  Future<void> _loadPrice() async {
    if (mounted) setState(() => _priceLoading = true);
    await Pro.refresh();
    if (mounted) setState(() => _priceLoading = false);
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
        if (widget.fromFeature) Navigator.of(context).pop();
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

  Future<void> _startTrial() async {
    final String len = Pro.durationText(widget.lang, Pro.trialLength);
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text(_t('무료 체험 시작', 'Start Free Trial', '开始免费试用', '無料体験を開始')),
        content: Text(_t('지금부터 $len 동안 유료 기능을 무료로 쓸 수 있어요\n무료 체험은 기기마다 한 번만 할 수 있어요',
            'You can use the paid features free for $len from now\nThe free trial is available once per device',
            '从现在起可免费使用付费功能 $len\n每台设备只能试用一次', '今から$lenの間、有料機能を無料で使えます\n無料体験は端末ごとに1回だけです')),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx, false), child: Text(_t('취소', 'Cancel', '取消', 'キャンセル'))),
          FilledButton(onPressed: () => Navigator.pop(ctx, true), child: Text(_t('시작', 'Start', '开始', '開始'))),
        ],
      ),
    );
    if (ok != true || !mounted) return;
    await Pro.startTrial();
    if (!mounted) return;
    _snack(_t('무료 체험을 시작했어요', 'Your free trial has started', '免费试用已开始', '無料体験を開始しました'));
    if (widget.fromFeature) {
      Navigator.of(context).pop();
    } else {
      setState(() {});
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
              final bool trial = Pro.trialActive;
              final String left = Pro.durationText(widget.lang, Pro.trialLeft);
              final String trialLen = Pro.durationText(widget.lang, Pro.trialLength);
              final String status = owned
                  ? _t('구매했어요. 모든 유료 기능을 쓸 수 있어요', 'Purchased. All paid features are unlocked', '已购买，所有付费功能均可使用', '購入済みです。すべての有料機能を使えます')
                  : !Pro.trialStarted
                      ? _t('$trialLen 동안 무료로 써 볼 수 있어요', 'You can try it free for $trialLen', '可免费试用 $trialLen', '$trialLenの間、無料で試せます')
                      : trial
                          ? _t('무료 체험이 $left 남았어요', '$left left in your free trial', '免费试用还剩 $left', '無料体験の残りは$leftです')
                          : _t('무료 체험이 끝났어요', 'Your free trial has ended', '免费试用已结束', '無料体験は終了しました');
              final bool canTrial = !owned && !Pro.trialStarted;
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
                      note(price != null
                          ? _t('가격: $price (1회 구매, 운영자가 앱을 제공하는 동안 계속 이용)', 'Price: $price (one-time purchase, usable for as long as the app is provided)',
                              '价格：$price（一次性购买，在应用提供期间可持续使用）', '価格：$price（買い切り。アプリの提供期間中ずっと利用できます）')
                          : _priceLoading
                              ? _t('가격: 확인하는 중이에요', 'Price: checking', '价格：正在确认', '価格：確認中です')
                              : _t('가격: 불러오지 못했어요. 가격을 확인해야 구매할 수 있어요', 'Price: could not be loaded. You can buy once the price is shown',
                                  '价格：无法加载。显示价格后才能购买', '価格：読み込めませんでした。価格が表示されると購入できます')),
                      note(_t('[무료 체험]을 누르면 $trialLen 동안 유료 기능을 무료로 써 볼 수 있어요 (기기마다 한 번)', 'Tap [Free Trial] to try the paid features free for $trialLen (once per device)',
                          '点击 [免费试用] 可免费试用付费功能 $trialLen（每台设备一次）', '[無料体験]を押すと$trialLenの間、有料機能を無料で試せます（端末ごとに1回）')),
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
                      child: Row(children: [
                        // 무료 체험 (기기마다 한 번, 시작 전에만)
                        if (canTrial) ...[
                          Expanded(
                            flex: 2,
                            child: OutlinedButton(
                              style: OutlinedButton.styleFrom(
                                side: BorderSide(color: sig, width: 2),
                                foregroundColor: cs.onSurface,
                                shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(27)),
                                padding: const EdgeInsets.symmetric(horizontal: 10),
                                minimumSize: const Size(0, 54),
                              ),
                              onPressed: _busy ? null : _startTrial,
                              child: FittedBox(
                                fit: BoxFit.scaleDown,
                                child: Text(_t('무료 체험', 'Free Trial', '免费试用', '無料体験'),
                                    style: const TextStyle(fontSize: 16.5, fontWeight: FontWeight.w700)),
                              ),
                            ),
                          ),
                          const SizedBox(width: 10),
                        ],
                        Expanded(
                          flex: 3,
                          child: SizedBox(
                            height: 54,
                            child: FilledButton(
                              onPressed: (_busy || price == null) ? null : _buy,
                              child: _busy
                                  ? const SizedBox(width: 22, height: 22, child: CircularProgressIndicator(strokeWidth: 2.4))
                                  : FittedBox(
                                      fit: BoxFit.scaleDown,
                                      child: Text(price == null
                                          ? (_priceLoading ? _t('가격 확인 중', 'Checking price', '正在确认价格', '価格を確認中') : _t('가격을 불러오지 못했어요', 'Price unavailable', '无法加载价格', '価格を読み込めません'))
                                          : _t('$price에 구매하기', 'Buy for $price', '以 $price 购买', '$priceで購入する'),
                                          style: const TextStyle(fontSize: 16.5)),
                                    ),
                            ),
                          ),
                        ),
                      ]),
                    ),
                  if (!owned && price == null && !_priceLoading)
                    Center(
                      child: TextButton(
                        onPressed: _busy ? null : _loadPrice,
                        child: Text(_t('가격 다시 불러오기', 'Reload Price', '重新加载价格', '価格を再読み込み'),
                            style: TextStyle(fontWeight: FontWeight.w700, color: cs.onSurface)),
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
