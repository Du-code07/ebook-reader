import 'package:flutter/material.dart';

/// 서재에서 파일 이름 앞에 보이는 형식 아이콘.
/// 워드·엑셀·파워포인트·PDF·한글은 종이 모양 안에 글자(W·X·P·P·ㅎ)를 넣고 형식별 색으로 보여 준다.
class FileTypeIcon extends StatelessWidget {
  const FileTypeIcon({super.key, required this.ext, this.size = 24, this.fallbackColor = Colors.indigo});

  final String ext;
  final double size;
  final Color fallbackColor;

  /// 글자 아이콘을 쓰는 형식: (글자, 색)
  static (String, Color)? lettered(String ext) {
    switch (ext.toLowerCase()) {
      case 'pdf':
        return ('P', const Color(0xFFE53935)); // 빨강
      case 'doc':
      case 'docx':
        return ('W', const Color(0xFF1E6FD9)); // 파랑
      case 'xls':
      case 'xlsx':
        return ('X', const Color(0xFF1E8E3E)); // 초록
      case 'ppt':
      case 'pptx':
        return ('P', const Color(0xFFF57C00)); // 주황
      case 'hwp':
      case 'hwpx':
        return ('ㅎ', const Color(0xFF29B6F6)); // 한글: 하늘색
    }
    return null;
  }

  static IconData _plainIcon(String ext) {
    switch (ext.toLowerCase()) {
      case 'epub':
      case 'txt':
        return Icons.menu_book;
      case 'cbz':
        return Icons.auto_stories;
    }
    return Icons.image;
  }

  @override
  Widget build(BuildContext context) {
    final mark = lettered(ext);
    if (mark == null) return Icon(_plainIcon(ext), size: size, color: fallbackColor);
    final (letter, color) = mark;
    // 한글 자모(ㅎ)는 글자 상자 안에서 작게 그려지므로 조금 크게
    final bool jamo = letter == 'ㅎ';
    return SizedBox(
      width: size,
      height: size,
      child: Stack(
        alignment: Alignment.center,
        children: [
          Icon(Icons.insert_drive_file_outlined, size: size, color: color),
          // 종이 모양 안쪽(접힌 귀 아래) 가운데에 글자
          Positioned(
            left: 0,
            right: 0,
            top: size * (jamo ? 0.27 : 0.33),
            child: Text(
              letter,
              textAlign: TextAlign.center,
              textScaler: TextScaler.noScaling,
              style: TextStyle(
                color: color,
                fontSize: size * (jamo ? 0.56 : 0.42),
                height: 1.0,
                fontWeight: FontWeight.w900,
                letterSpacing: 0,
              ),
            ),
          ),
        ],
      ),
    );
  }
}
