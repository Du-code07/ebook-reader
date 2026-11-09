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
  required String confirmLabel,
}) {
  return showModalBottomSheet<T>(
    context: context,
    isScrollControlled: true,
    useSafeArea: true,
    builder: (ctx) => _ChoiceSheet<T>(title: title, options: options, current: current, confirmLabel: confirmLabel),
  );
}

class _ChoiceSheet<T> extends StatefulWidget {
  const _ChoiceSheet({required this.title, required this.options, required this.current, required this.confirmLabel});

  final String title;
  final List<ChoiceOption<T>> options;
  final T current;
  final String confirmLabel;

  @override
  State<_ChoiceSheet<T>> createState() => _ChoiceSheetState<T>();
}

class _ChoiceSheetState<T> extends State<_ChoiceSheet<T>> {
  late T _selected = widget.current;

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
                        onTap: () => setState(() => _selected = opt.value),
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
                ],
              ),
            ),
          ),
          Padding(
            padding: const EdgeInsets.fromLTRB(20, 18, 20, 16),
            child: FilledButton(
              style: FilledButton.styleFrom(
                minimumSize: const Size.fromHeight(52),
                textStyle: const TextStyle(fontSize: 17, fontWeight: FontWeight.bold),
              ),
              onPressed: () => Navigator.pop(context, _selected),
              child: Text(widget.confirmLabel),
            ),
          ),
        ],
      ),
    );
  }
}
