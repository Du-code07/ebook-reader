import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'app_colors.dart';

/// 도구 모음 항목
class QuickToolItem {
  const QuickToolItem({
    required this.icon,
    required this.tooltip,
    required this.onTap,
    this.closeAfterTap = false,
    this.enabled = true,
  });

  /// 잠긴 기능(쓸 수 없을 때)은 투명하게 보이고 눌리지 않음
  final bool enabled;

  final Widget icon;
  final String tooltip;
  final VoidCallback onTap;

  /// 누른 뒤 메뉴를 닫을지 여부 (파일 이동처럼 화면이 바뀌는 기능)
  final bool closeAfterTap;
}

/// [trigger] 값이 바뀔 때마다 아이콘을 살짝 흔든다 (눌렀다는 반응 표시)
class WiggleOnChange extends StatefulWidget {
  const WiggleOnChange({super.key, required this.trigger, required this.child});

  final int trigger;
  final Widget child;

  @override
  State<WiggleOnChange> createState() => _WiggleOnChangeState();
}

class _WiggleOnChangeState extends State<WiggleOnChange> with SingleTickerProviderStateMixin {
  late final AnimationController _ctrl = AnimationController(vsync: this, duration: Anim.ms(520));

  @override
  void didUpdateWidget(WiggleOnChange oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.trigger != widget.trigger) {
      _ctrl.duration = Anim.ms(520);
      _ctrl.forward(from: 0.0);
    }
  }

  @override
  void dispose() {
    _ctrl.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return AnimatedBuilder(
      animation: _ctrl,
      child: widget.child,
      builder: (context, child) {
        final double t = _ctrl.value;
        // 회전 방향으로 한 번 크게(약 25°), 되돌아오며 점점 작게 흔들림
        final double angle = math.sin(t * math.pi * 3) * (1.0 - t) * 0.45;
        return Transform.rotate(angle: angle, child: child);
      },
    );
  }
}

/// 도구 모음: 화면 아래에 둥근 가로 막대로 아이콘을 한 줄로 늘어놓음
/// (아이콘이 많으면 옆으로 밀어서 봄). 누르면 그 기능을 바로 실행
class QuickToolBar extends StatelessWidget {
  const QuickToolBar({super.key, required this.items, this.onClose, this.pinned});

  final List<QuickToolItem> items;

  /// 맨 오른쪽에 고정되는 항목 (옆으로 밀어도 움직이지 않음, 예: 뷰어 설정)
  final QuickToolItem? pinned;

  /// 누른 항목이 메뉴를 닫는 항목일 때 부름 (상단바·진행바도 함께 숨김)
  final VoidCallback? onClose;

  @override
  Widget build(BuildContext context) {
    return Container(
      height: 52,
      decoration: BoxDecoration(
        color: const Color(0xEE1C1C1E),
        borderRadius: BorderRadius.circular(22),
        border: Border.all(color: Colors.white.withValues(alpha: 0.10)),
        boxShadow: const [BoxShadow(color: Colors.black38, blurRadius: 10, offset: Offset(0, 3))],
      ),
      child: LayoutBuilder(
        builder: (context, c) {
          // 아이콘 사이를 좁게 (한 칸 40), 화면보다 길면 옆으로 밀어서 봄
          const double slot = 40;
          Widget button(QuickToolItem it) => SizedBox(
                width: slot,
                height: 52,
                child: IconButton(
                  padding: EdgeInsets.zero,
                  icon: Opacity(
                    opacity: it.enabled ? 1 : 0.3,
                    child: IconTheme.merge(data: const IconThemeData(color: Colors.white, size: 20), child: it.icon),
                  ),
                  tooltip: it.tooltip,
                  onPressed: it.enabled
                      ? () {
                          it.onTap();
                          if (it.closeAfterTap) onClose?.call();
                        }
                      : null,
                ),
              );
          final row = Row(mainAxisSize: MainAxisSize.min, children: [for (final it in items) button(it)]);
          final scroller = ClipRRect(
            borderRadius: BorderRadius.horizontal(left: const Radius.circular(22), right: Radius.circular(pinned == null ? 22 : 0)),
            child: SingleChildScrollView(
              scrollDirection: Axis.horizontal,
              padding: EdgeInsets.only(left: 8, right: pinned == null ? 8 : 2),
              child: row,
            ),
          );
          if (pinned == null) return scroller;
          // 고정 항목: 밀리는 아이콘들과 가는 세로줄로 나눔
          return Row(mainAxisSize: MainAxisSize.min, children: [
            Flexible(child: scroller),
            Container(width: 1, height: 24, color: Colors.white.withValues(alpha: 0.18)),
            Padding(padding: const EdgeInsets.only(left: 2, right: 8), child: button(pinned!)),
          ]);
        },
      ),
    );
  }
}
