import 'package:flutter/material.dart';

/// 고르기 창의 선택지
class ChoiceOption<T> {
  const ChoiceOption(this.value, this.label, {this.icon});

  final T value;
  final String label;
  final IconData? icon;
}

/// 아래에서 올라오는 '하나 고르기' 창.
/// 제목 + 선택지 목록(고른 줄은 강조, 오른쪽 동그라미) + 아래 '확인' 버튼.
/// '확인'을 눌러야 고른 값이 돌아오고, 그냥 닫으면 null.
Future<T?> showChoiceSheet<T>({
  required BuildContext context,
  required String title,
  required List<ChoiceOption<T>> options,
  required T current,
  String confirmLabel = '',
}) async {
  final r = await showModalBottomSheet<(T, bool)>(
    context: context,
    isScrollControlled: true,
    useSafeArea: true,
    builder: (ctx) => _ChoiceSheet<T>(title: title, options: options, current: current, confirmLabel: confirmLabel),
  );
  return r?.$1;
}

/// 하나 고르기 + 아래에 켜기/끄기 스위치 한 줄이 함께 있는 창.
/// '확인'을 누르면 (고른 값, 스위치 값)을 돌려준다. 그냥 닫으면 null.
Future<(T, bool)?> showChoiceSheetWithToggle<T>({
  required BuildContext context,
  required String title,
  required List<ChoiceOption<T>> options,
  required T current,
  required String toggleLabel,
  String? toggleSubtitle,
  IconData? toggleIcon,
  required bool toggleValue,
  String confirmLabel = '',
  /// 고르거나 스위치를 바꿀 때마다 바로 불림 (확인 버튼 없이 바로 적용)
  ValueChanged<(T, bool)>? onChanged,
}) {
  return showModalBottomSheet<(T, bool)>(
    context: context,
    isScrollControlled: true,
    useSafeArea: true,
    builder: (ctx) => _ChoiceSheet<T>(
      title: title,
      options: options,
      current: current,
      confirmLabel: confirmLabel,
      toggleLabel: toggleLabel,
      toggleSubtitle: toggleSubtitle,
      toggleIcon: toggleIcon,
      toggleValue: toggleValue,
      onChanged: onChanged,
    ),
  );
}

class _ChoiceSheet<T> extends StatefulWidget {
  const _ChoiceSheet({
    required this.title,
    required this.options,
    required this.current,
    required this.confirmLabel,
    this.toggleLabel,
    this.toggleSubtitle,
    this.toggleIcon,
    this.toggleValue = false,
    this.onChanged,
  });

  final String title;
  final List<ChoiceOption<T>> options;
  final T current;
  final String confirmLabel;
  final String? toggleLabel;
  final String? toggleSubtitle;
  final IconData? toggleIcon;
  final bool toggleValue;
  final ValueChanged<(T, bool)>? onChanged;

  @override
  State<_ChoiceSheet<T>> createState() => _ChoiceSheetState<T>();
}

class _ChoiceSheetState<T> extends State<_ChoiceSheet<T>> {
  late T _selected = widget.current;
  late bool _toggle = widget.toggleValue;

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    return SafeArea(
      top: false,
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(24, 22, 24, 14),
            child: Text(widget.title, style: const TextStyle(fontSize: 21, fontWeight: FontWeight.bold)),
          ),
          Flexible(
            child: SingleChildScrollView(
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  for (final opt in widget.options)
                    Material(
                      color: opt.value == _selected ? cs.secondaryContainer.withValues(alpha: 0.55) : Colors.transparent,
                      child: InkWell(
                        // 누르면 바로 적용: 고르기만 있는 창은 바로 닫히고, 스위치가 함께 있는 창은 열린 채로 적용
                        onTap: () {
                          setState(() => _selected = opt.value);
                          widget.onChanged?.call((_selected, _toggle));
                          if (widget.toggleLabel == null) Navigator.pop(context, (_selected, _toggle));
                        },
                        child: Padding(
                          padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 16),
                          child: Row(
                            children: [
                              if (opt.icon != null) ...[
                                Icon(opt.icon, size: 22, color: opt.value == _selected ? cs.primary : cs.onSurfaceVariant),
                                const SizedBox(width: 14),
                              ],
                              Expanded(
                                child: Text(
                                  opt.label,
                                  style: TextStyle(
                                    fontSize: 17,
                                    fontWeight: FontWeight.w600,
                                    color: opt.value == _selected ? cs.primary : cs.onSurface,
                                  ),
                                ),
                              ),
                              Icon(
                                opt.value == _selected ? Icons.radio_button_checked : Icons.radio_button_unchecked,
                                size: 26,
                                color: opt.value == _selected ? cs.primary : cs.outline,
                              ),
                            ],
                          ),
                        ),
                      ),
                    ),
                  if (widget.toggleLabel != null) ...[
                    const Divider(height: 16, indent: 24, endIndent: 24),
                    InkWell(
                      onTap: () {
                        setState(() => _toggle = !_toggle);
                        widget.onChanged?.call((_selected, _toggle));
                      },
                      child: Padding(
                        padding: const EdgeInsets.fromLTRB(24, 8, 16, 8),
                        child: Row(
                          children: [
                            if (widget.toggleIcon != null) ...[
                              Icon(widget.toggleIcon, size: 22, color: cs.onSurfaceVariant),
                              const SizedBox(width: 14),
                            ],
                            Expanded(
                              child: Column(
                                crossAxisAlignment: CrossAxisAlignment.start,
                                children: [
                                  Text(widget.toggleLabel!, style: const TextStyle(fontSize: 16, fontWeight: FontWeight.w600)),
                                  if (widget.toggleSubtitle != null)
                                    Text(widget.toggleSubtitle!, style: TextStyle(fontSize: 13, color: cs.onSurfaceVariant)),
                                ],
                              ),
                            ),
                            Switch(
                              value: _toggle,
                              onChanged: (v) {
                                setState(() => _toggle = v);
                                widget.onChanged?.call((_selected, _toggle));
                              },
                            ),
                          ],
                        ),
                      ),
                    ),
                  ],
                ],
              ),
            ),
          ),
          const SizedBox(height: 16),
        ],
      ),
    );
  }
}
