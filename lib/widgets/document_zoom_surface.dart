import 'package:flutter/widgets.dart';

/// The document paints its zoom in the WebView. Cancel InteractiveViewer's
/// transform BEFORE UiUnscale and any clipped viewport, in the same coordinate
/// space as InteractiveViewer. Cancelling inside UiUnscale leaves an unwanted
/// translation on tablets and lets intermediate clips discard visible content.
class DocumentZoomSurface extends StatelessWidget {
  const DocumentZoomSurface({
    super.key,
    required this.enabled,
    required this.controller,
    required this.child,
  });

  final bool enabled;
  final TransformationController controller;
  final Widget child;

  @override
  Widget build(BuildContext context) => AnimatedBuilder(
        animation: controller,
        builder: (context, child) => Transform(
          transform: enabled
              ? Matrix4.inverted(controller.value)
              : Matrix4.identity(),
          child: child,
        ),
        child: child,
      );
}

/// InteractiveViewer uses the enlarged UI's logical units. UiUnscale restores
/// the WebView to physical logical pixels; only translation needs conversion.
/// Keep the original matrix for the Flutter annotation layer.
Matrix4 documentViewMatrix(Matrix4 view, double uiScale) {
  final result = view.clone();
  result.storage[12] *= uiScale;
  result.storage[13] *= uiScale;
  return result;
}
