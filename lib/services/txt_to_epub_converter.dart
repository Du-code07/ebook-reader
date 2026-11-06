import 'dart:convert';
import 'dart:io';
import 'package:archive/archive.dart';

class TxtToEpubConverter {
  /// .txt 파일을 열 때 즉시 표준 EPUB 파일로 패키징하여 동일한 리더기 기능을 제공
  static Future<File> convertTxtToEpub(File txtFile) async {
    final outPath = '${txtFile.path}.converted.epub';
    final outFile = File(outPath);
    if (await outFile.exists()) return outFile;

    final rawText = await txtFile.readAsString();
    final title = txtFile.path.split(Platform.pathSeparator).last.replaceAll('.txt', '');
    final lines = const LineSplitter().convert(rawText);

    final bodyBuffer = StringBuffer();
    for (final line in lines) {
      final escaped = const HtmlEscape().convert(line.trim());
      if (escaped.isNotEmpty) {
        bodyBuffer.writeln('<p>$escaped</p>');
      }
    }

    final archive = Archive();
    final mimeBytes = utf8.encode('application/epub+zip');
    archive.addFile(ArchiveFile.noCompress('mimetype', mimeBytes.length, mimeBytes));

    const containerXml = '''<?xml version="1.0" encoding="UTF-8"?>
<container version="1.0" xmlns="urn:oasis:names:tc:opendocument:xmlns:container">
  <rootfiles>
    <rootfile full-path="OEBPS/content.opf" media-type="application/oebps-package+xml"/>
  </rootfiles>
</container>''';
    archive.addFile(ArchiveFile('META-INF/container.xml', containerXml.length, utf8.encode(containerXml)));

    final xhtml = '''<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE html>
<html xmlns="http://www.w3.org/1999/xhtml" xml:lang="ko" lang="ko">
<head><title>$title</title></head>
<body><h1>$title</h1>${bodyBuffer.toString()}</body>
</html>''';
    final xhtmlBytes = utf8.encode(xhtml);
    archive.addFile(ArchiveFile('OEBPS/chap1.xhtml', xhtmlBytes.length, xhtmlBytes));

    final opf = '''<?xml version="1.0" encoding="UTF-8"?>
<package xmlns="http://www.idpf.org/2007/opf" unique-identifier="BookId" version="2.0">
  <metadata xmlns:dc="http://purl.org/dc/elements/1.1/">
    <dc:title>$title</dc:title>
    <dc:language>ko</dc:language>
    <dc:identifier id="BookId">urn:uuid:txt-converted-book</dc:identifier>
  </metadata>
  <manifest>
    <item id="ncx" href="toc.ncx" media-type="application/x-dtbncx+xml"/>
    <item id="chap1" href="chap1.xhtml" media-type="application/xhtml+xml"/>
  </manifest>
  <spine toc="ncx"><itemref idref="chap1"/></spine>
</package>''';
    archive.addFile(ArchiveFile('OEBPS/content.opf', opf.length, utf8.encode(opf)));

    final ncx = '''<?xml version="1.0" encoding="UTF-8"?>
<ncx xmlns="http://www.daisy.org/z3986/2005/ncx/" version="2005-1">
  <head><meta name="dtb:uid" content="urn:uuid:txt-converted-book"/></head>
  <docTitle><text>$title</text></docTitle>
  <navMap>
    <navPoint id="nav1" playOrder="1">
      <navLabel><text>$title</text></navLabel>
      <content src="chap1.xhtml"/>
    </navPoint>
  </navMap>
</ncx>''';
    archive.addFile(ArchiveFile('OEBPS/toc.ncx', ncx.length, utf8.encode(ncx)));

    final zipped = ZipEncoder().encode(archive);
    await outFile.writeAsBytes(zipped!);
    return outFile;
  }
}
