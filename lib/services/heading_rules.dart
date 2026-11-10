/// 목차 쪽이 없을 때의 목차 규칙: 번호로 시작하고 굵은 글씨인 줄만 제목으로 본다 (그 밖의 글은 넣지 않음).
///
/// 번호 모양: 로마 숫자(Ⅰ. / I.), 1. 제목, 1) 제목, (1) 제목 — 1.1 / 2-1 처럼 이어진 번호도 같은 갈래로 본다.
/// 단계는 번호 모양이 문서에서 처음 나온 순서대로 깊어지고, 같은 제목이 여러 번 나오면 처음 것만 남긴다.
class HeadingRules {
  static final RegExp _letter = RegExp(r'[가-힣A-Za-z]');

  static final List<(String, RegExp)> _patterns = [
    ('roman', RegExp(r'^(?:[ⅠⅡⅢⅣⅤⅥⅦⅧⅨⅩⅪⅫ]+\s*[.)]?|[IVX]{1,5}\s*[.)])\s*')),
    ('paren', RegExp(r'^\(\s*\d{1,3}\s*\)\s*')),
    ('multi', RegExp(r'^\d{1,3}(?:[.\-]\d{1,3})+(?:\.\s*|\s+)')),
    ('dot', RegExp(r'^\d{1,3}\.(?!\d)\s*')),
    ('half', RegExp(r'^\d{1,3}\)\s*')),
  ];

  /// 번호 모양의 갈래 (번호로 시작하지 않으면 null). 이어진 번호(1.1, 2-1-3)는 깊이까지 나눈다
  static String? kindOf(String title) {
    final t = title.trim();
    for (final (kind, re) in _patterns) {
      final m = re.firstMatch(t);
      if (m == null) continue;
      final rest = t.substring(m.end).trim();
      if (_letter.allMatches(rest).length < 2) return null;
      if (kind == 'multi') {
        final depth = RegExp(r'[.\-]\d').allMatches(m.group(0)!).length + 1;
        return 'multi$depth';
      }
      return kind;
    }
    return null;
  }

  static String norm(String s) => s.replaceAll(RegExp(r'\s+'), '').toLowerCase();

  /// [candidates]: {title, page, bold} — 앞에서부터 차례로.
  /// 결과: {title, level, page}. 해당하는 줄이 없으면 빈 목록
  static List<Map<String, Object?>> build(List<Map<String, Object?>> candidates) {
    final seen = <String>{};
    final order = <String>[];
    final out = <Map<String, Object?>>[];
    for (final c in candidates) {
      if (c['bold'] != true) continue;
      final title = (c['title'] ?? '').toString().replaceAll(RegExp(r'\s+'), ' ').trim();
      if (title.length > 80) continue;
      final kind = kindOf(title);
      if (kind == null) continue;
      if (!seen.add(norm(title))) continue; // 같은 제목은 한 번만
      if (!order.contains(kind)) order.add(kind);
      out.add({'title': title, 'level': (order.indexOf(kind) + 1).clamp(1, 4), 'page': c['page']});
      if (out.length >= 500) break;
    }
    return out;
  }
}
