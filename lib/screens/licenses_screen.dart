import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../services/asset_licenses.dart';
import '../services/storage_service.dart';
import '../widgets/push_aside_route.dart';

/// 도움말 '오픈소스 라이선스': 이름을 누르면 원본 주소(프로젝트·패키지 페이지)로, 오른쪽 아이콘은 라이선스 전문
class LicensesScreen extends StatefulWidget {
  const LicensesScreen({super.key, required this.appLang});
  final String appLang;

  @override
  State<LicensesScreen> createState() => _LicensesScreenState();
}

class _LicensesScreenState extends State<LicensesScreen> {
  static const MethodChannel _channel = MethodChannel('ebook_reader/pdf_renderer');
  // 패키지 이름 → 그 패키지의 라이선스 글들
  List<MapEntry<String, List<String>>>? _packages;

  String _tr(String ko, String en, String zh, String ja) => AppI18n.t(widget.appLang, ko: ko, en: en, zh: zh, ja: ja);

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    final map = <String, List<String>>{};
    await for (final entry in LicenseRegistry.licenses) {
      final text = entry.paragraphs.map((p) => '${'  ' * p.indent.clamp(0, 8)}${p.text}').join('\n\n');
      for (final pkg in entry.packages) {
        // 같은 엔진 파일을 PPT·엑셀에 함께 등록해 둔 경우 같은 전문이 두 번 나오지 않게
        final bucket = map[pkg] ??= [];
        if (!bucket.contains(text)) bucket.add(text);
      }
    }
    final list = map.entries.toList()..sort((a, b) => a.key.toLowerCase().compareTo(b.key.toLowerCase()));
    if (mounted) setState(() => _packages = list);
  }

  /// 라이선스 글에서 종류를 짐작해 짧게 (MIT · Apache 2.0 · BSD · Boost · MPL 2.0 · OFL 1.1 …)
  /// 고지 모음 글은 들어 있는 라이선스를 모두 (줄바꿈·공백을 하나로 모아 비교)
  static String _kind(List<String> texts) {
    final kinds = <String>{};
    for (final t in texts) {
      kinds.addAll(licenseKindsOf(t));
    }
    return kinds.join(' · ');
  }

  Future<void> _open(String name, List<String> texts) async {
    final link = licenseLink(name);
    if (link == null) {
      _showText(name, texts);
      return;
    }
    bool ok = false;
    try {
      ok = await _channel.invokeMethod<bool>('openUrl', {'url': link}) ?? false;
    } catch (_) {}
    if (!ok && mounted) {
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(_tr('링크를 열 수 없어요', 'Could not open the link', '无法打开链接', 'リンクを開けません'))));
    }
  }

  void _showText(String name, List<String> texts) {
    Navigator.of(context).push(PushAsideRoute(
      builder: (ctx) => Scaffold(
        appBar: AppBar(title: Text(name, style: const TextStyle(fontWeight: FontWeight.w800))),
        body: SafeArea(
          child: SelectionArea(
            child: ListView(
              padding: const EdgeInsets.fromLTRB(20, 8, 20, 32),
              children: [
                for (int i = 0; i < texts.length; i++) ...[
                  if (i > 0) const Divider(height: 40),
                  Text(texts[i], style: const TextStyle(fontSize: 13, height: 1.5)),
                ],
              ],
            ),
          ),
        ),
      ),
    ));
  }

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final list = _packages;
    return Scaffold(
      appBar: AppBar(title: Text(_tr('오픈소스 라이선스', 'Open Source Licenses', '开源许可', 'オープンソースライセンス'), style: const TextStyle(fontWeight: FontWeight.w800))),
      body: SafeArea(
        child: list == null
            ? const Center(child: CircularProgressIndicator())
            : ListView.builder(
                padding: const EdgeInsets.only(bottom: 24),
                itemCount: list.length + 1,
                itemBuilder: (context, i) {
                  if (i == 0) {
                    return Padding(
                      padding: const EdgeInsets.fromLTRB(20, 4, 20, 10),
                      child: Text(
                        _tr('이리ERI에 들어 있는 오픈소스 소프트웨어와 글꼴이에요\n이름을 누르면 원본 페이지가 열리고, 오른쪽 아이콘으로 라이선스 전문을 볼 수 있어요',
                            'Open source software and fonts included in 이리ERI\nTap a name to open its original page, or the icon on the right to read the full license',
                            '이리ERI 中包含的开源软件和字体\n点击名称打开原始页面，点击右侧图标查看许可全文',
                            '이리ERIに含まれるオープンソースソフトウェアとフォントです\n名前をタップすると元のページが開き、右のアイコンでライセンス全文を見られます'),
                        style: TextStyle(fontSize: 13.5, height: 1.45, color: cs.onSurfaceVariant),
                      ),
                    );
                  }
                  final e = list[i - 1];
                  final bool linked = licenseLink(e.key) != null;
                  final String kind = _kind(e.value);
                  return ListTile(
                    contentPadding: const EdgeInsets.only(left: 20, right: 8),
                    title: Row(
                      children: [
                        Flexible(child: Text(e.key, style: const TextStyle(fontSize: 15.5, fontWeight: FontWeight.w700), overflow: TextOverflow.ellipsis)),
                        if (linked) ...[
                          const SizedBox(width: 6),
                          Icon(Icons.open_in_new, size: 15, color: cs.onSurfaceVariant),
                        ],
                      ],
                    ),
                    subtitle: kind.isEmpty ? null : Text(kind, style: TextStyle(fontSize: 12.5, color: cs.onSurfaceVariant)),
                    trailing: IconButton(
                      icon: const Icon(Icons.description_outlined),
                      tooltip: _tr('라이선스 전문', 'Full License', '许可全文', 'ライセンス全文'),
                      onPressed: () => _showText(e.key, e.value),
                    ),
                    onTap: () => _open(e.key, e.value),
                  );
                },
              ),
      ),
    );
  }
}

/// 라이선스 글 하나에 들어 있는 라이선스 종류들 (고지 모음 글은 여러 개)
/// - 부스트·폰트(OFL) 라이선스에도 'Permission is hereby granted, free of charge'가 있어 MIT는 MIT 고유 문장으로만 봄
/// - MPL 2.0 본문의 '1.1.' 같은 항 번호를 1.1판으로 오해하지 않게 판 번호까지 함께 봄
List<String> licenseKindsOf(String text) {
  final u = text.toUpperCase().replaceAll(RegExp(r'\s+'), ' ');
  bool has(List<String> keys) => keys.any(u.contains);
  final out = <String>[];
  if (u.contains('PERMISSION IS HEREBY GRANTED, FREE OF CHARGE, TO ANY PERSON OBTAINING A COPY OF THIS SOFTWARE') || RegExp(r'\bMIT\b').hasMatch(u)) out.add('MIT');
  if (has(['APACHE LICENSE', 'APACHE-2.0'])) out.add('Apache 2.0');
  if (has(['REDISTRIBUTION AND USE IN SOURCE AND BINARY FORMS', 'BSD-STYLE LICENSE', 'BSD-3-CLAUSE', 'BSD-2-CLAUSE'])) out.add('BSD');
  if (has(['BOOST SOFTWARE LICENSE', 'BSL-1.0'])) out.add('Boost 1.0');
  if (has(['MOZILLA PUBLIC LICENSE VERSION 2.0', 'MOZILLA PUBLIC LICENSE, V. 2.0', 'MPL-2.0', 'MPL 2.0'])) out.add('MPL 2.0');
  if (has(['MOZILLA PUBLIC LICENSE VERSION 1.1', 'MOZILLA PUBLIC LICENSE, VERSION 1.1', 'MPL-1.1', 'MPL 1.1'])) out.add('MPL 1.1');
  if (has(['OPEN FONT LICENSE', 'SIL-OFL', 'OFL-1.1'])) out.add('OFL 1.1');
  if (has(['GUST FONT LICENSE'])) out.add('GUST');
  if (has(['UNICODE-3.0', 'UNICODE LICENSE']) || (u.contains('UNICODE') && u.contains('DATA FILES'))) out.add('Unicode');
  if (has(['PERMISSION TO USE, COPY, MODIFY, AND/OR DISTRIBUTE', 'PERMISSION TO USE, COPY, MODIFY, AND DISTRIBUTE'])) out.add('ISC');
  if (has(['PNG REFERENCE LIBRARY', 'LIBPNG LICENSE'])) out.add('libpng');
  if (has(['ALTERED SOURCE VERSIONS MUST BE PLAINLY MARKED'])) out.add('zlib');
  if (has(['FREETYPE PROJECT'])) out.add('FreeType');
  if (has(['PUBLIC DOMAIN', 'DEDICATE ANY AND ALL COPYRIGHT INTEREST'])) out.add('Public Domain');
  if (u.contains('GOOGLE') && u.contains('NOT OPEN SOURCE')) out.add('Google Terms');
  return out;
}
