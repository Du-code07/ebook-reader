import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../services/pro.dart';
import '../services/storage_service.dart';
import '../widgets/app_colors.dart';

/// 이리ERI 프로 화면: 유료 기능과 무료 제공 기간 안내
/// (이 버전에는 결제 기능이 없음. 무료 제공 기간이 끝난 뒤에는 업데이트를 안내)
class ProScreen extends StatelessWidget {
  const ProScreen({super.key, required this.lang});
  final String lang;

  static const _ch = MethodChannel('ebook_reader/pdf_renderer');

  String _t(String ko, String en, String zh, String ja) => AppI18n.t(lang, ko: ko, en: en, zh: zh, ja: ja);

  /// Play 스토어의 이리ERI 페이지 (스토어 앱이 없으면 웹으로)
  Future<void> _openStore() async {
    bool ok = false;
    try {
      ok = await _ch.invokeMethod<bool>('openUrl', {'url': 'market://details?id=com.dudu.eri'}) ?? false;
    } catch (_) {}
    if (ok) return;
    try {
      await _ch.invokeMethod<bool>('openUrl', {'url': 'https://play.google.com/store/apps/details?id=com.dudu.eri'});
    } catch (_) {}
  }

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final Color sig = AppColors.of(context);
    final bool dark = Theme.of(context).brightness == Brightness.dark;
    final Color tile = sig.withValues(alpha: dark ? 0.32 : 0.18);
    final Color tileIcon = dark ? Colors.white : Color.lerp(sig, Colors.black, 0.35)!;
    final bool free = Pro.freePeriod;

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
      appBar: AppBar(title: Text(_t('이리ERI 프로', '이리ERI Pro', '이리ERI 专业版', '이리ERI プロ'), style: const TextStyle(fontWeight: FontWeight.w800))),
      body: SafeArea(
        child: ListView(
          padding: const EdgeInsets.fromLTRB(24, 8, 24, 24),
          children: [
            Text(
              free
                  ? _t('2027년 3월 1일까지 아래 기능을 모두 무료로 쓸 수 있어요', 'You can use all of these features free until March 1, 2027',
                      '2027年3月1日前可免费使用以下全部功能', '2027年3月1日まで、以下の機能をすべて無料で使えます')
                  : _t('무료 제공 기간이 끝났어요', 'The free period has ended', '免费提供期间已结束', '無料提供期間は終了しました'),
              style: TextStyle(fontSize: 17, fontWeight: FontWeight.w800, color: cs.onSurface),
            ),
            const SizedBox(height: 14),
            feature(Icons.document_scanner_outlined, _t('문서 스캔', 'Scan Document', '扫描文档', '文書スキャン')),
            feature(Icons.photo_library_outlined, _t('이미지 합치기', 'Merge Images', '合并图片', '画像結合')),
            feature(Icons.picture_as_pdf_outlined, _t('PDF 합치기', 'Merge PDFs', '合并 PDF', 'PDF結合')),
            feature(Icons.add_circle_outline, _t('앞으로 추가되는 유료 기능', 'Paid features added in the future', '今后新增的付费功能', '今後追加される有料機能')),
            const SizedBox(height: 18),
            Container(
              padding: const EdgeInsets.fromLTRB(16, 14, 16, 8),
              decoration: BoxDecoration(color: cs.surfaceContainerHigh, borderRadius: BorderRadius.circular(16)),
              child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                Text(free ? _t('무료 제공 안내', 'About the free period', '免费提供说明', '無料提供のご案内') : _t('업데이트 안내', 'About updating', '更新说明', 'アップデートのご案内'),
                    style: TextStyle(fontSize: 14.5, fontWeight: FontWeight.w800, color: cs.onSurface)),
                const SizedBox(height: 10),
                if (free) ...[
                  note(_t('지금은 판매하지 않아요. 결제 없이 모든 유료 기능을 쓸 수 있어요', 'Nothing is for sale right now. You can use all paid features without paying',
                      '目前不出售。无需付款即可使用全部付费功能', '現在は販売していません。支払いなしで有料機能をすべて使えます')),
                  note(_t('2027년 3월 1일부터 이리ERI 프로(1회 구매)로 판매할 예정이에요. 판매를 시작하기 전에 앱 안에서 미리 알려 드려요',
                      '이리ERI Pro is planned to go on sale as a one-time purchase from March 1, 2027. You will be notified in the app before sales begin',
                      '计划从2027年3月1日起以 이리ERI 专业版（一次性购买）出售。开始出售前会在应用内提前通知', '2027年3月1日から이리ERI プロ（買い切り）として販売する予定です。販売開始前にアプリ内でお知らせします')),
                ] else
                  note(_t('이 버전에서는 이리ERI 프로를 구매할 수 없어요. 앱을 업데이트하면 구매할 수 있어요',
                      '이리ERI Pro cannot be bought in this version. Update the app to buy it',
                      '此版本无法购买 이리ERI 专业版。更新应用后即可购买', 'このバージョンでは이리ERI プロを購入できません。アプリをアップデートすると購入できます')),
                note(_t('무료로 쓰는 동안 스캔·합치기로 만든 파일은 판매가 시작된 뒤에도 그대로 쓸 수 있어요', 'Files you create by scanning or merging during the free period stay usable after sales begin',
                    '免费期间通过扫描·合并生成的文件，在开始出售后仍可照常使用', '無料期間中にスキャン・結合で作ったファイルは、販売開始後もそのまま使えます')),
                note(_t('문의: dudu.dev.pr@gmail.com', 'Contact: dudu.dev.pr@gmail.com', '咨询：dudu.dev.pr@gmail.com', 'お問い合わせ：dudu.dev.pr@gmail.com')),
              ]),
            ),
            if (!free) ...[
              const SizedBox(height: 22),
              SizedBox(
                height: 54,
                child: FilledButton(
                  onPressed: _openStore,
                  child: Text(_t('Play 스토어에서 업데이트', 'Update on Play Store', '在 Play 商店更新', 'Play ストアでアップデート'),
                      style: const TextStyle(fontSize: 16.5)),
                ),
              ),
            ],
          ],
        ),
      ),
    );
  }
}
