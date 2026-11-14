import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../services/storage_service.dart';
import '../widgets/app_colors.dart';

/// 앱을 처음 시작할 때 언어·테마 다음에 보여 주는 '앱 접근 권한 안내'
/// 모든 권한은 선택이라 허용하지 않아도 그 기능 말고는 그대로 쓸 수 있음
class PermissionGuideScreen extends StatelessWidget {
  const PermissionGuideScreen({super.key, required this.lang, required this.onDone});

  final String lang;
  final VoidCallback onDone;

  static const MethodChannel _channel = MethodChannel('ebook_reader/pdf_renderer');

  String t(String ko, String en, String zh, String ja) => AppI18n.t(lang, ko: ko, en: en, zh: zh, ja: ja);

  Future<void> _continue() async {
    // 카메라(와 안드로이드 12 이하의 저장소 읽기) 허용을 묻고, 이어서 '모든 파일 접근' 설정 화면을 엶 (돌아오면 다음으로)
    try {
      await _channel.invokeMethod('requestStartupPermissions');
    } catch (_) {}
    await StorageService.markPermissionGuideShown();
    onDone();
  }

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final Color sig = AppColors.of(context);
    final bool dark = Theme.of(context).brightness == Brightness.dark;
    // 아이콘 칸 바탕: 대표 색을 옅게
    final Color tile = sig.withValues(alpha: dark ? 0.32 : 0.18);
    final Color tileIcon = dark ? Colors.white : Color.lerp(sig, Colors.black, 0.35)!;

    Widget item(IconData icon, String title, String desc) => Padding(
          padding: const EdgeInsets.only(bottom: 22),
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Container(
                width: 56,
                height: 56,
                decoration: BoxDecoration(color: tile, borderRadius: BorderRadius.circular(16)),
                child: Icon(icon, size: 28, color: tileIcon),
              ),
              const SizedBox(width: 18),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    const SizedBox(height: 2),
                    Text(title, style: TextStyle(fontSize: 18, fontWeight: FontWeight.w800, color: cs.onSurface)),
                    const SizedBox(height: 4),
                    Text(desc, style: TextStyle(fontSize: 15, height: 1.4, color: cs.onSurfaceVariant)),
                  ],
                ),
              ),
            ],
          ),
        );

    return Scaffold(
      body: SafeArea(
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Expanded(
              child: ListView(
                padding: const EdgeInsets.fromLTRB(28, 48, 28, 16),
                children: [
                  // 앱 표시: 대표 색 동그라미 안에 펼친 책
                  Center(
                    child: Container(
                      width: 96,
                      height: 96,
                      decoration: BoxDecoration(color: sig, shape: BoxShape.circle),
                      child: Icon(Icons.auto_stories_rounded, size: 48, color: Colors.white, shadows: AppColors.sigShadows(context)),
                    ),
                  ),
                  const SizedBox(height: 18),
                  Center(
                    child: Text('FReader', style: TextStyle(fontSize: 34, fontWeight: FontWeight.w900, letterSpacing: -0.5, color: cs.onSurface)),
                  ),
                  const SizedBox(height: 44),
                  Text(t('앱 접근 권한 안내', 'App Permissions', '应用访问权限说明', 'アプリのアクセス権限について'),
                      style: TextStyle(fontSize: 22, fontWeight: FontWeight.w900, color: cs.onSurface)),
                  const SizedBox(height: 8),
                  Text(
                    t('FReader 서비스 제공을 위해 다음 권한을 사용해요', 'FReader uses the following permissions to provide its features',
                        'FReader 为提供服务会使用以下权限', 'FReaderはサービス提供のため次の権限を使います'),
                    style: TextStyle(fontSize: 15, color: cs.onSurfaceVariant),
                  ),
                  const SizedBox(height: 36),
                  Text(t('선택적 접근권한', 'Optional Permissions', '可选权限', '任意のアクセス権限'),
                      style: TextStyle(fontSize: 18, fontWeight: FontWeight.w900, color: cs.onSurface)),
                  const SizedBox(height: 18),
                  item(
                    Icons.folder_open_rounded,
                    t('파일 열람', 'Files', '文件访问', 'ファイルの閲覧'),
                    t('기기에 있는 문서·글꼴 파일을 찾아 열고 가져오는 데 사용해요', 'Used to find, open and import documents and fonts on your device',
                        '用于查找、打开和导入设备中的文档和字体文件', '端末内の文書・フォントファイルを探して開き、取り込むのに使います'),
                  ),
                  item(
                    Icons.photo_camera_rounded,
                    t('카메라', 'Camera', '相机', 'カメラ'),
                    t('문서를 스캔하는 데 사용해요', 'Used to scan documents', '用于扫描文档', '文書のスキャンに使います'),
                  ),
                  const SizedBox(height: 4),
                  Row(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Padding(
                        padding: const EdgeInsets.only(top: 1),
                        child: Icon(Icons.info_outline_rounded, size: 18, color: cs.onSurfaceVariant.withValues(alpha: 0.8)),
                      ),
                      const SizedBox(width: 8),
                      Expanded(
                        child: Text(
                          t('선택적 접근권한에 동의하지 않아도 해당 기능 외 앱 서비스를 이용할 수 있어요',
                              'You can use the rest of the app even if you don\'t allow optional permissions',
                              '即使不同意可选权限，也可以使用该功能以外的应用服务', '任意の権限に同意しなくても、その機能以外のサービスは利用できます'),
                          style: TextStyle(fontSize: 13.5, height: 1.4, color: cs.onSurfaceVariant.withValues(alpha: 0.85)),
                        ),
                      ),
                    ],
                  ),
                ],
              ),
            ),
            Padding(
              padding: const EdgeInsets.fromLTRB(24, 8, 24, 20),
              child: SizedBox(
                height: 58,
                child: FilledButton(
                  style: FilledButton.styleFrom(
                    backgroundColor: sig,
                    foregroundColor: Colors.white,
                    shape: const StadiumBorder(),
                  ),
                  onPressed: _continue,
                  child: Text(
                    t('계속', 'Continue', '继续', '続ける'),
                    style: TextStyle(fontSize: 19, fontWeight: FontWeight.w800, color: Colors.white, shadows: AppColors.sigShadows(context)),
                  ),
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}
