import 'package:flutter/material.dart';

import '../services/storage_service.dart';
import '../widgets/app_colors.dart';

typedef TapZoneTr = String Function(String ko, String en, String zh, String ja);

/// 탭 영역: 파일 화면을 3×3 칸으로 나눠, 칸마다 누르면 할 일(이전·다음·메뉴·없음)을 정함
/// 칸을 누를 때마다 이전 → 다음 → 메뉴 → 없음 순서로 바뀜
class TapZoneScreen extends StatefulWidget {
  const TapZoneScreen({super.key, required this.t});
  final TapZoneTr t;

  @override
  State<TapZoneScreen> createState() => _TapZoneScreenState();
}

class _TapZoneScreenState extends State<TapZoneScreen> {
  static const List<String> _cycle = ['P', 'N', 'M', 'X'];
  late String _zones = StorageService.tapZones.value;

  String _t(String ko, String en, String zh, String ja) => widget.t(ko, en, zh, ja);

  void _save(String zones) {
    setState(() => _zones = zones);
    StorageService.setTapZones(zones);
  }

  void _tapCell(int i) {
    final String cur = _zones[i];
    final String next = _cycle[(_cycle.indexOf(cur) + 1) % _cycle.length];
    // 메뉴 칸이 하나도 없으면 도구 모음을 열 수 없으므로 마지막 메뉴 칸은 바꾸지 않음
    if (cur == 'M' && 'M'.allMatches(_zones).length == 1) {
      ScaffoldMessenger.of(context)
        ..hideCurrentSnackBar()
        ..showSnackBar(SnackBar(
          content: Text(_t('메뉴 칸은 하나 이상 있어야 해요', 'At least one cell must be Menu', '至少需要一个菜单格', 'メニューのマスは1つ以上必要です')),
          duration: const Duration(seconds: 2),
        ));
      return;
    }
    _save(_zones.replaceRange(i, i + 1, next));
  }

  ({Color bg, Color fg, IconData icon, String label, bool sig}) _look(BuildContext context, String z) {
    final cs = Theme.of(context).colorScheme;
    final Color sig = AppColors.of(context);
    return switch (z) {
      'P' => (bg: sig.withValues(alpha: 0.38), fg: cs.onSurface, icon: Icons.chevron_left_rounded, label: _t('이전', 'Previous', '上一页', '前へ'), sig: false),
      'N' => (bg: sig, fg: Colors.white, icon: Icons.chevron_right_rounded, label: _t('다음', 'Next', '下一页', '次へ'), sig: true),
      'M' => (bg: cs.surfaceContainerHighest, fg: cs.onSurfaceVariant, icon: Icons.menu_rounded, label: _t('메뉴', 'Menu', '菜单', 'メニュー'), sig: false),
      _ => (bg: Colors.transparent, fg: cs.outline, icon: Icons.remove_rounded, label: _t('없음', 'None', '无', 'なし'), sig: false),
    };
  }

  Widget _cell(BuildContext context, int i) {
    final cs = Theme.of(context).colorScheme;
    final look = _look(context, _zones[i]);
    final List<Shadow>? shadows = look.sig ? AppColors.sigShadows(context) : null;
    return Material(
      color: Colors.transparent,
      child: InkWell(
        borderRadius: BorderRadius.circular(10),
        onTap: () => _tapCell(i),
        child: AnimatedContainer(
          duration: const Duration(milliseconds: 160),
          decoration: BoxDecoration(
            color: look.bg,
            borderRadius: BorderRadius.circular(10),
            border: _zones[i] == 'X' ? Border.all(color: cs.outlineVariant, width: 1.2) : null,
          ),
          child: Column(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              Icon(look.icon, color: look.fg, size: 24, shadows: shadows),
              const SizedBox(height: 2),
              Text(look.label, style: TextStyle(color: look.fg, fontSize: 13, fontWeight: FontWeight.w700, shadows: shadows)),
            ],
          ),
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final Size screen = MediaQuery.sizeOf(context);
    // 미리보기 휴대폰: 화면 비율 그대로 (가로 화면이면 세로 휴대폰 비율로)
    final double ratio = screen.width < screen.height ? screen.width / screen.height : screen.height / screen.width;
    final double phoneH = (screen.height * 0.52).clamp(300.0, 520.0);
    final double phoneW = phoneH * ratio;
    final bool isDefault = _zones == StorageService.tapZonesDefault;
    return Scaffold(
      appBar: AppBar(title: Text(_t('탭 영역', 'Tap Zones', '点击区域', 'タップ領域'))),
      body: SafeArea(
        child: ListView(
          padding: const EdgeInsets.fromLTRB(20, 12, 20, 28),
          children: [
            const SizedBox(height: 8),
            // 휴대폰 모양 미리보기 + 3×3 칸
            Center(
              child: Container(
                width: phoneW,
                height: phoneH,
                padding: const EdgeInsets.all(8),
                decoration: BoxDecoration(
                  color: cs.surface,
                  borderRadius: BorderRadius.circular(26),
                  border: Border.all(color: cs.outline, width: 2),
                ),
                child: Column(
                  children: [
                    for (int r = 0; r < 3; r++)
                      Expanded(
                        child: Padding(
                          padding: EdgeInsets.only(top: r == 0 ? 0 : 3),
                          child: Row(
                            children: [
                              for (int c = 0; c < 3; c++)
                                Expanded(
                                  child: Padding(
                                    padding: EdgeInsets.only(left: c == 0 ? 0 : 3),
                                    child: _cell(context, r * 3 + c),
                                  ),
                                ),
                            ],
                          ),
                        ),
                      ),
                  ],
                ),
              ),
            ),
            const SizedBox(height: 12),
            Text(
              _t('칸을 누를 때마다 이전 → 다음 → 메뉴 → 없음 순서로 바뀌어요',
                  'Each tap on a cell switches Previous → Next → Menu → None',
                  '每点一下格子，按 上一页 → 下一页 → 菜单 → 无 的顺序切换',
                  'マスを押すたびに 前へ → 次へ → メニュー → なし の順に変わります'),
              textAlign: TextAlign.center,
              style: TextStyle(color: cs.onSurfaceVariant, fontSize: 13),
            ),
            const SizedBox(height: 20),
            Center(
              child: OutlinedButton.icon(
                onPressed: isDefault ? null : () => _save(StorageService.tapZonesDefault),
                icon: const Icon(Icons.refresh_rounded),
                label: Text(_t('기본값으로 되돌리기', 'Restore Default', '恢复默认', 'デフォルトに戻す')),
                style: OutlinedButton.styleFrom(
                  foregroundColor: cs.onSurface,
                  padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 12),
                  shape: const StadiumBorder(),
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}
