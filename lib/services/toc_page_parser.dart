/// 파일 안에 '목차'(차례, Contents)라고 적힌 쪽이 있으면 그 쪽의 항목들로 목차를 만든다.
///
/// 항목 한 줄은 "제목 ……… 쪽번호" 꼴이다. 쪽번호는 인쇄된 번호라 실제 쪽과 다를 수 있으므로,
/// 목차 쪽 뒤에서 같은 제목이 처음 나오는 쪽을 찾아 붙이고, 못 찾으면 찾은 항목들의 차이(인쇄 번호↔실제 쪽)로 맞춘다.
class TocPageParser {
  /// 목차 제목으로 보는 글 (띄어쓰기 없이, 소문자)
  static const _headings = {'목차', '차례', '목록', 'contents', 'tableofcontents', '목차contents', 'contents목차'};

  /// 목차 쪽을 찾을 범위 (앞쪽 몇 쪽)
  static const int searchPages = 15;

  static String _norm(String s) => s.replaceAll(RegExp(r'\s+'), '').toLowerCase();

  static final RegExp _leaders = RegExp(r'[\s.·…‥・_\-–—─•∙⋯]+$');
  // "제목 ……… 12" / "제목  12" / "제목12"
  static final RegExp _entry = RegExp(r'^(.*?\S)[\s.·…‥・_\-–—─•∙⋯]*?(\d{1,4})$');
  static final RegExp _letter = RegExp(r'[가-힣A-Za-z]');

  /// 한 줄이 목차 항목이면 (제목, 인쇄 쪽번호)
  static (String, int)? _parseEntry(String raw) {
    final line = raw.replaceAll('\t', ' ').trim();
    if (line.length < 3 || line.length > 120) return null;
    final m = _entry.firstMatch(line);
    if (m == null) return null;
    final title = m.group(1)!.replaceAll(_leaders, '').trim();
    final page = int.parse(m.group(2)!);
    if (title.length < 2 || title.length > 90 || !_letter.hasMatch(title)) return null;
    if (_headings.contains(_norm(title))) return null;
    return (title, page);
  }

  /// 번호 모양의 종류 (없으면 null)
  static String? _kind(String title) {
    final t = title.trim();
    if (RegExp(r'^제\s*\d+\s*[편부]').hasMatch(t)) return 'part';
    if (RegExp(r'^제\s*\d+\s*장').hasMatch(t)) return 'chapter';
    if (RegExp(r'^제\s*\d+\s*절').hasMatch(t)) return 'section';
    if (RegExp(r'^([ⅠⅡⅢⅣⅤⅥⅦⅧⅨⅩ]+|[IVX]+\.)').hasMatch(t)) return 'roman';
    if (RegExp(r'^\d+\.\d+\.\d+').hasMatch(t)) return 'dec3';
    if (RegExp(r'^\d+\.\d+').hasMatch(t)) return 'dec2';
    if (RegExp(r'^\d+\.').hasMatch(t)) return 'dec1';
    if (RegExp(r'^[가-하]\.').hasMatch(t)) return 'hangul';
    if (RegExp(r'^\(\d+\)').hasMatch(t)) return 'paren';
    if (RegExp(r'^\d+\)').hasMatch(t)) return 'halfparen';
    if (RegExp(r'^[가-하]\)').hasMatch(t)) return 'hangulparen';
    return null;
  }

  /// 단계: 번호 모양이 처음 나온 순서대로 깊어진다 (예: Ⅰ. → 1. → 가. → (1)). 번호 없는 제목은 1단계
  static List<int> _levels(List<String> titles) {
    final order = <String>[];
    return [
      for (final t in titles)
        () {
          final k = _kind(t);
          if (k == null) return 1;
          if (!order.contains(k)) order.add(k);
          return (order.indexOf(k) + 1).clamp(1, 4);
        }(),
    ];
  }

  /// 번호를 뗀 제목 (찾기용)
  static String _core(String title) => title
      .replaceFirst(RegExp(r'^(제\s*\d+\s*[장절편부]|[ⅠⅡⅢⅣⅤⅥⅦⅧⅨⅩ]+\.?|[IVX]+\.|\d+(\.\d+)*\.?|\(\d+\)|\d+\)|[가-하][.)])\s*'), '')
      .trim();

  /// [pageTexts]: 앞에서부터 쪽마다의 글 (줄은 \n). 전체 쪽 수보다 짧아도 된다.
  /// 목차 쪽이 없으면 null.
  static List<Map<String, Object>>? parse(List<String> pageTexts, int totalPages) {
    if (totalPages <= 0) return null;
    int tocStart = -1;
    for (int i = 0; i < pageTexts.length && i < searchPages; i++) {
      final lines = pageTexts[i].split('\n');
      final hasHeading = lines.any((l) => _headings.contains(_norm(l)));
      if (!hasHeading) continue;
      if (lines.where((l) => _parseEntry(l) != null).length >= 3) {
        tocStart = i;
        break;
      }
    }
    if (tocStart < 0) return null;

    // 목차가 여러 쪽에 이어질 수 있음 (항목이 대부분인 쪽까지)
    final entries = <(String, int)>[];
    int tocEnd = tocStart;
    for (int i = tocStart; i < pageTexts.length && i < tocStart + 4; i++) {
      final lines = pageTexts[i].split('\n').map((l) => l.trim()).where((l) => l.isNotEmpty).toList();
      final parsed = [for (final l in lines) _parseEntry(l)].whereType<(String, int)>().toList();
      if (i > tocStart && (parsed.length < 3 || parsed.length < lines.length * 0.5)) break;
      entries.addAll(parsed);
      tocEnd = i;
    }
    // 인쇄 쪽번호가 거꾸로 가는 항목(본문 속 숫자 등)은 뺀다
    final ordered = <(String, int)>[];
    for (final e in entries) {
      if (e.$2 > totalPages * 3 + 20) continue;
      if (ordered.isNotEmpty && e.$2 < ordered.last.$2) continue;
      ordered.add(e);
    }
    if (ordered.length < 2) return null;

    // 실제 쪽 찾기: 목차 쪽 뒤에서, 앞 항목을 찾은 쪽부터 차례로
    final normPages = [for (final t in pageTexts) _norm(t)];
    final found = <int?>[];
    int from = tocEnd + 1;
    for (final (title, _) in ordered) {
      final full = _norm(title), core = _norm(_core(title));
      int? hit;
      for (int p = from; p < normPages.length; p++) {
        if (normPages[p].contains(full) || (core.length >= 3 && normPages[p].contains(core))) {
          hit = p;
          break;
        }
      }
      found.add(hit);
      if (hit != null) from = hit;
    }
    // 인쇄 번호 ↔ 실제 쪽 차이 (찾은 항목들의 가운데 값)
    final diffs = <int>[for (int i = 0; i < ordered.length; i++) if (found[i] != null) found[i]! - (ordered[i].$2 - 1)]..sort();
    final int offset = diffs.isEmpty ? 0 : diffs[diffs.length ~/ 2];
    final levels = _levels([for (final e in ordered) e.$1]);
    return [
      for (int i = 0; i < ordered.length; i++)
        {
          'title': ordered[i].$1,
          'level': levels[i],
          'page': (found[i] ?? (ordered[i].$2 - 1 + offset)).clamp(0, totalPages - 1),
        },
    ];
  }
}
