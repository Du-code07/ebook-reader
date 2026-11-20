import 'package:flutter/material.dart';

import 'app_colors.dart';

/// 앱 설정에서 전체 화면(가이드·약관·탐색할 폴더 등)을 열 때:
/// 새 화면이 오른쪽에서 들어오면서 그 전 화면(설정 창과 그 뒤 서재)을 왼쪽으로 밀어냄
class PushAside {
  /// 0 = 제자리, 1 = 왼쪽으로 화면 너비만큼 밀려남 (밀려나는 쪽 화면들이 [PushAsideShift]로 따라 움직임)
  static final ValueNotifier<double> shift = ValueNotifier(0);
}

/// 밀려나는 쪽 화면: [PushAside.shift]만큼 왼쪽으로 옮겨 그림
class PushAsideShift extends StatelessWidget {
  const PushAsideShift({super.key, required this.child});
  final Widget child;

  @override
  Widget build(BuildContext context) {
    return ValueListenableBuilder<double>(
      valueListenable: PushAside.shift,
      // 밀리는 동안 화면을 매 장면 다시 그리지 않고 그려 둔 것을 옮기기만 (돌아올 때 덜 버벅임)
      child: RepaintBoundary(child: child),
      builder: (context, t, child) {
        // 밀려나지 않을 때도 같은 모양으로 감싸 둠: 감싸는 위젯이 바뀌면 그 안 화면이 새로 만들어져
        // 설정 창의 스크롤 위치 같은 상태가 사라짐
        final double w = MediaQuery.sizeOf(context).width;
        return Transform.translate(offset: Offset(-w * t.clamp(0.0, 1.0), 0), child: child);
      },
    );
  }
}

/// 밀어내며 들어오는 화면
class PushAsideRoute<T> extends PageRoute<T> {
  PushAsideRoute({required this.builder, super.settings});

  final WidgetBuilder builder;

  /// 바로 아래가 같은 방식의 화면이 아니면(설정 창 위에서 처음 연 화면) 아래 화면 전체를 함께 밀어냄
  bool _drivesShift = false;
  CurvedAnimation? _curve;

  static const Curve _in = Curves.easeOutCubic;
  static const Curve _out = Curves.easeInCubic;

  @override
  Duration get transitionDuration => Anim.off.value ? Duration.zero : const Duration(milliseconds: 320);

  @override
  Duration get reverseTransitionDuration => Anim.off.value ? Duration.zero : const Duration(milliseconds: 280);

  @override
  bool get opaque => true;

  @override
  bool get maintainState => true;

  @override
  Color? get barrierColor => null;

  @override
  String? get barrierLabel => null;

  @override
  void install() {
    super.install();
    _curve = CurvedAnimation(parent: animation!, curve: _in, reverseCurve: _out);
    _curve!.addListener(_sync);
  }

  @override
  void didChangePrevious(Route<dynamic>? previousRoute) {
    super.didChangePrevious(previousRoute);
    _drivesShift = previousRoute is! PushAsideRoute;
  }

  void _sync() {
    if (_drivesShift) PushAside.shift.value = _curve!.value;
  }

  @override
  void dispose() {
    if (_drivesShift) PushAside.shift.value = 0;
    _curve?.removeListener(_sync);
    _curve?.dispose();
    super.dispose();
  }

  @override
  Widget buildPage(BuildContext context, Animation<double> animation, Animation<double> secondaryAnimation) => builder(context);

  @override
  Widget buildTransitions(BuildContext context, Animation<double> animation, Animation<double> secondaryAnimation, Widget child) {
    // 들어올 때: 오른쪽 → 제자리, 위에 같은 방식의 화면이 열리면: 제자리 → 왼쪽
    return SlideTransition(
      position: Tween<Offset>(begin: const Offset(1, 0), end: Offset.zero)
          .animate(CurvedAnimation(parent: animation, curve: _in, reverseCurve: _out)),
      child: SlideTransition(
        position: Tween<Offset>(begin: Offset.zero, end: const Offset(-1, 0))
            .animate(CurvedAnimation(parent: secondaryAnimation, curve: _in, reverseCurve: _out)),
        // 움직이는 동안 파일 화면을 다시 그리지 않고 옮기기만
        child: RepaintBoundary(child: child),
      ),
    );
  }

  @override
  bool canTransitionTo(TransitionRoute<dynamic> nextRoute) => nextRoute is PushAsideRoute;

  /// 아래 화면이 자기 방식의 퇴장 효과(어두워지기 등)를 따로 쓰지 않게: 밀려나는 건 [PushAsideShift]가 맡음
  @override
  bool canTransitionFrom(TransitionRoute<dynamic> previousRoute) => previousRoute is PushAsideRoute;
}
