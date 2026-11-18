import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

/// 앱에 함께 넣은 문서 엔진·글꼴의 라이선스를 '오픈소스 라이선스' 화면에 올림
/// (pub 패키지 라이선스는 Flutter가 따로 모아 보여 줌)
void registerAssetLicenses() {
  const entries = <(List<String>, String)>[
    (['rhwp (HWP·HWPX engine)'], 'assets/hwp/LICENSE'),
    (['HOP'], 'assets/hwp/HOP-LICENSE'),
    (['FReader HWP·HWPX reader notices'], 'assets/hwp/THIRD_PARTY_NOTICES.txt'),
    (['Noto Sans KR'], 'assets/hwp/fonts/NotoSansKR-OFL.txt'),
    (['Noto Serif KR'], 'assets/hwp/fonts/NotoSerifKR-OFL.txt'),
    (['Latin Modern Math'], 'assets/hwp/fonts/GUST-FONT-LICENSE.txt'),
    (['OpenDocument.core (Word engine)'], 'assets/docx/engine/LICENSE'),
    (['Word metafile renderer'], 'assets/docx/metafile/LICENSE'),
    (['FReader Word reader notices'], 'assets/docx/THIRD_PARTY_NOTICES.txt'),
    (['Noto Sans'], 'assets/docx/fonts/notosans-OFL.txt'),
    (['Noto Serif'], 'assets/docx/fonts/notoserif-OFL.txt'),
    (['Korean document fonts'], 'assets/docx/fonts/free/LICENSES.txt'),
    (['Metric-compatible document fonts'], 'assets/docx/fonts/metric/LICENSES.txt'),
    (['@silurus/ooxml (PowerPoint·Excel engine)'], 'assets/ppt/engine/LICENSE'),
    (['@silurus/ooxml notices'], 'assets/ppt/engine/THIRD_PARTY_NOTICES.md'),
    (['@silurus/ooxml-legacy-office (PPT·XLS engine)'], 'assets/ppt/legacy/LICENSE'),
    (['@silurus/ooxml-legacy-office notices'], 'assets/ppt/legacy/THIRD_PARTY_NOTICES.md'),
    (['FReader PowerPoint viewer notices'], 'assets/ppt/THIRD_PARTY_NOTICES.txt'),
    (['FReader Excel viewer notices'], 'assets/xlsx/THIRD_PARTY_NOTICES.txt'),
    (['epub.js'], 'assets/txt/epubjs-LICENSE.txt'),
    (['FReader TXT·EPUB notices'], 'assets/txt/THIRD_PARTY_NOTICES.txt'),
  ];
  LicenseRegistry.addLicense(() async* {
    for (final (packages, path) in entries) {
      try {
        yield LicenseEntryWithLineBreaks(packages, await rootBundle.loadString(path));
      } catch (_) {
        // 파일이 빠졌어도 다른 라이선스는 계속 보여 줌
      }
    }
  });
}
