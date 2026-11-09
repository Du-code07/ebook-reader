import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:path_provider/path_provider.dart';

import 'storage_service.dart';

typedef ExportTr = String Function(String ko, String en, String zh, String ja);

/// PDF 내보내기 (메모 포함) 공통 처리
class PdfExportService {
  static const MethodChannel _channel = MethodChannel('ebook_reader/pdf_renderer');

  /// 파일 이름: "원래 이름_메모 포함.pdf" (확장자 제거)
  static String exportFileName(String title, ExportTr tr) {
    String base = title.trim();
    final dot = base.lastIndexOf('.');
    if (dot > 0 && base.length - dot <= 6) base = base.substring(0, dot);
    if (base.isEmpty) base = 'FReader';
    return '${base}_${tr('메모 포함', 'with notes', '含笔记', 'メモ付き')}.pdf';
  }

  /// 페이지 그림 + 필기 + 텍스트 메모를 PDF로 만들어 다운로드/FReader 폴더에 저장.
  /// [pages] 각 항목: {'image': 그림 경로, 'strokes': [{x,y,c,w}], 'refWidth': 필기를 그린 화면 폭, 'note': 텍스트 메모}
  /// 돌려주는 값: 저장된 위치 (예: Download/FReader/xxx.pdf)
  static Future<String> buildPdf({
    required List<Map<String, Object?>> pages,
    required String fileName,
    void Function(int current, int total)? onProgress,
  }) async {
    _channel.setMethodCallHandler((call) async {
      if (call.method == 'onPdfExportProgress' && onProgress != null) {
        final args = Map<String, dynamic>.from(call.arguments as Map);
        onProgress((args['current'] as num).toInt(), (args['total'] as num).toInt());
      }
      return null;
    });
    try {
      final fallbackDir = (await getApplicationDocumentsDirectory()).path;
      final saved = await _channel.invokeMethod<String>('exportPdfWithMemos', {
        'pages': pages,
        'fileName': fileName,
        'fallbackDir': fallbackDir,
      });
      return saved ?? fileName;
    } finally {
      _channel.setMethodCallHandler(null);
    }
  }

  static Map<String, Object?> strokeToMap(MemoStroke s) => {'x': s.dxList, 'y': s.dyList, 'c': s.colorValue, 'w': s.strokeWidth};
}

/// 내보내기 진행 상황 창
class ExportProgressController {
  final ValueNotifier<String> status = ValueNotifier<String>('');
  final ValueNotifier<double?> ratio = ValueNotifier<double?>(null);
  bool cancelled = false;
  BuildContext? _dialogContext;

  void update(String text, double? value) {
    status.value = text;
    ratio.value = value;
  }

  void close() {
    final ctx = _dialogContext;
    _dialogContext = null;
    if (ctx != null && ctx.mounted) Navigator.of(ctx).pop();
  }
}

/// 진행 창을 띄운다. [cancelable]이면 '취소' 버튼이 생긴다.
ExportProgressController showExportProgress(BuildContext context, ExportTr tr, {bool cancelable = false}) {
  final ctrl = ExportProgressController();
  showDialog<void>(
    context: context,
    barrierDismissible: false,
    builder: (ctx) {
      ctrl._dialogContext = ctx;
      return PopScope(
        canPop: false,
        child: StatefulBuilder(
          builder: (ctx, setLocal) => AlertDialog(
            title: Row(
              children: [
                const Icon(Icons.picture_as_pdf_outlined, size: 22),
                const SizedBox(width: 8),
                Expanded(child: Text(tr('PDF로 내보내는 중', 'Exporting to PDF', '正在导出为 PDF', 'PDFに書き出し中'))),
              ],
            ),
            content: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                ValueListenableBuilder<double?>(
                  valueListenable: ctrl.ratio,
                  builder: (_, v, __) => LinearProgressIndicator(value: v),
                ),
                const SizedBox(height: 12),
                ValueListenableBuilder<String>(
                  valueListenable: ctrl.status,
                  builder: (_, v, __) => Text(v, style: const TextStyle(fontSize: 13)),
                ),
              ],
            ),
            actions: [
              if (cancelable)
                TextButton(
                  onPressed: ctrl.cancelled
                      ? null
                      : () => setLocal(() {
                            ctrl.cancelled = true;
                            ctrl.status.value = tr('취소하는 중…', 'Cancelling…', '正在取消…', 'キャンセル中…');
                          }),
                  child: Text(tr('취소', 'Cancel', '取消', 'キャンセル')),
                ),
            ],
          ),
        ),
      );
    },
  );
  return ctrl;
}
