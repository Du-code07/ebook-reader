import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../services/asset_licenses.dart';
import '../services/storage_service.dart';

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
  static String _kind(List<String> texts) {
    final kinds = <String>{};
    for (final t in texts) {
      final u = t.toUpperCase();
      // 부스트 라이선스도 'Permission is hereby granted, free of charge'로 시작해서 MIT보다 먼저 봄
      if (u.contains('BOOST SOFTWARE LICENSE')) {
        kinds.add('Boost 1.0');
      } else if (u.contains('MIT LICENSE') || u.contains('PERMISSION IS HEREBY GRANTED, FREE OF CHARGE')) {
        kinds.add('MIT');
      } else if (u.contains('APACHE LICENSE')) {
        kinds.add('Apache 2.0');
      } else if (u.contains('MOZILLA PUBLIC LICENSE')) {
        kinds.add('MPL 2.0');
      } else if (u.contains('OPEN FONT LICENSE')) {
        kinds.add('OFL 1.1');
      } else if (u.contains('GUST FONT LICENSE')) {
        kinds.add('GUST');
      } else if (u.contains('REDISTRIBUTION AND USE IN SOURCE AND BINARY FORMS')) {
        kinds.add('BSD');
      } else if (u.contains('ZLIB')) {
        kinds.add('zlib');
      }
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
    Navigator.of(context).push(MaterialPageRoute(
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
                        _tr('FReader에 들어 있는 오픈소스 소프트웨어와 글꼴이에요\n이름을 누르면 원본 페이지가 열리고, 오른쪽 아이콘으로 라이선스 전문을 볼 수 있어요',
                            'Open source software and fonts included in FReader\nTap a name to open its original page, or the icon on the right to read the full license',
                            'FReader 中包含的开源软件和字体\n点击名称打开原始页面，点击右侧图标查看许可全文',
                            'FReaderに含まれるオープンソースソフトウェアとフォントです\n名前をタップすると元のページが開き、右のアイコンでライセンス全文を見られます'),
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
