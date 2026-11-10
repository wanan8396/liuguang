import 'package:flutter/material.dart';

/// Pointer cancellation after recognition does not emit onLongPressEnd.
class PlaybackHoldRegion extends StatelessWidget {
  const PlaybackHoldRegion({
    super.key,
    required this.enabled,
    required this.onStart,
    required this.onEnd,
    required this.child,
  });

  final bool enabled;
  final VoidCallback onStart, onEnd;
  final Widget child;

  @override
  Widget build(BuildContext context) => Listener(
    onPointerCancel: (_) => onEnd(),
    child: GestureDetector(
      behavior: HitTestBehavior.opaque,
      onLongPressStart: enabled ? (_) => onStart() : null,
      onLongPressEnd: (_) => onEnd(),
      onLongPressCancel: onEnd,
      child: child,
    ),
  );
}
