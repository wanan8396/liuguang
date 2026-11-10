import 'dart:math' as math;

import 'package:flutter/material.dart';

const playbackRates = [.5, .75, 1.0, 1.25, 1.5, 1.75, 2.0, 3.0];

class PlaybackSpeedButton extends StatelessWidget {
  const PlaybackSpeedButton({
    super.key,
    required this.rate,
    required this.onPressed,
  });

  final double rate;
  final VoidCallback onPressed;

  @override
  Widget build(BuildContext context) => Tooltip(
    message: '调整播放速度，当前 ${rate}x',
    child: TextButton.icon(
      onPressed: onPressed,
      icon: const Icon(Icons.speed_rounded, size: 14),
      label: Text('${rate}x', maxLines: 1),
      style: TextButton.styleFrom(
        foregroundColor: Colors.white,
        backgroundColor: Colors.white.withValues(alpha: .12),
        padding: const EdgeInsets.symmetric(horizontal: 8),
        minimumSize: const Size(0, 28),
        tapTargetSize: MaterialTapTargetSize.padded,
        visualDensity: VisualDensity.standard,
        textStyle: const TextStyle(fontSize: 12, fontWeight: FontWeight.w600),
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(8),
          side: BorderSide(color: Colors.white.withValues(alpha: .16)),
        ),
      ),
    ),
  );
}

/// [anchor] and [viewport] use global logical pixels, as returned by
/// RenderBox.localToGlobal. The picker stays within the video viewport.
Future<double?> showPlaybackSpeedPicker(
  BuildContext context, {
  required double rate,
  required bool live,
  required Rect anchor,
  required Rect viewport,
}) {
  final navigator = Navigator.of(context, rootNavigator: true);
  final overlay = navigator.overlay!.context.findRenderObject()! as RenderBox;
  Rect local(Rect rect) => Rect.fromPoints(
    overlay.globalToLocal(rect.topLeft),
    overlay.globalToLocal(rect.bottomRight),
  );
  final localAnchor = local(anchor);
  final localViewport = local(viewport);
  final theme = Theme.of(context);
  final textScaler = MediaQuery.textScalerOf(context);
  return showGeneralDialog<double>(
    context: context,
    barrierDismissible: true,
    barrierLabel: '关闭倍速选择',
    barrierColor: Colors.transparent,
    transitionDuration: const Duration(milliseconds: 120),
    transitionBuilder: (_, animation, _, child) =>
        FadeTransition(opacity: animation, child: child),
    pageBuilder: (context, _, _) => Theme(
      data: theme,
      child: MediaQuery(
        data: MediaQuery.of(context).copyWith(textScaler: textScaler),
        child: LayoutBuilder(
          builder: (context, constraints) => CustomSingleChildLayout(
            delegate: _SpeedPickerPosition(
              anchor: localAnchor,
              viewport: localViewport,
              screen: Offset.zero & constraints.biggest,
              width: math.max(248, textScaler.scale(12) * 14 + 80),
            ),
            child: PlaybackSpeedPicker(rate: rate, live: live),
          ),
        ),
      ),
    ),
  );
}

class _SpeedPickerPosition extends SingleChildLayoutDelegate {
  const _SpeedPickerPosition({
    required this.anchor,
    required this.viewport,
    required this.screen,
    required this.width,
  });

  final Rect anchor, viewport, screen;
  final double width;

  Rect get bounds {
    final visible = viewport.intersect(screen);
    final area = visible.isEmpty ? screen : visible;
    return area.deflate(math.min(8, math.min(area.width, area.height) / 4));
  }

  @override
  BoxConstraints getConstraintsForChild(BoxConstraints constraints) {
    final size = bounds.size;
    return BoxConstraints(
      minWidth: math.min(width, size.width),
      maxWidth: math.min(width, size.width),
      maxHeight: size.height,
    );
  }

  @override
  Offset getPositionForChild(Size size, Size childSize) {
    final area = bounds;
    return Offset(
      (anchor.right - childSize.width).clamp(
        area.left,
        area.right - childSize.width,
      ),
      (anchor.top - childSize.height - 6).clamp(
        area.top,
        area.bottom - childSize.height,
      ),
    );
  }

  @override
  bool shouldRelayout(covariant _SpeedPickerPosition oldDelegate) =>
      anchor != oldDelegate.anchor ||
      viewport != oldDelegate.viewport ||
      screen != oldDelegate.screen ||
      width != oldDelegate.width;
}

class PlaybackSpeedPicker extends StatelessWidget {
  const PlaybackSpeedPicker({super.key, required this.rate, this.live = false});

  final double rate;
  final bool live;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final colors = theme.colorScheme;
    return Material(
      color: colors.surface,
      elevation: 10,
      shadowColor: Colors.black54,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(14),
        side: BorderSide(color: colors.outlineVariant.withValues(alpha: .5)),
      ),
      clipBehavior: Clip.antiAlias,
      child: SingleChildScrollView(
        padding: const EdgeInsets.all(8),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              '播放速度',
              style: theme.textTheme.labelMedium?.copyWith(
                fontWeight: FontWeight.w700,
              ),
            ),
            const SizedBox(height: 6),
            LayoutBuilder(
              builder: (context, constraints) {
                final width = math.max(0.0, (constraints.maxWidth - 18) / 4);
                return Wrap(
                  spacing: 6,
                  runSpacing: 6,
                  children: [
                    for (final value in playbackRates)
                      SizedBox(
                        width: width,
                        child: Semantics(
                          selected: value == rate,
                          button: true,
                          label: '播放速度 ${value}x',
                          child: Material(
                            color: value == rate
                                ? colors.primaryContainer
                                : colors.surfaceContainerLow,
                            shape: RoundedRectangleBorder(
                              borderRadius: BorderRadius.circular(8),
                              side: BorderSide(
                                color: value == rate
                                    ? colors.primary
                                    : colors.outlineVariant.withValues(
                                        alpha: .4,
                                      ),
                              ),
                            ),
                            clipBehavior: Clip.antiAlias,
                            child: InkWell(
                              onTap: () => Navigator.pop(context, value),
                              child: ConstrainedBox(
                                constraints: const BoxConstraints(
                                  minHeight: 48,
                                ),
                                child: Padding(
                                  padding: const EdgeInsets.symmetric(
                                    horizontal: 4,
                                    vertical: 8,
                                  ),
                                  child: Center(
                                    child: FittedBox(
                                      fit: BoxFit.scaleDown,
                                      child: Row(
                                        mainAxisSize: MainAxisSize.min,
                                        children: [
                                          if (value == rate) ...[
                                            Icon(
                                              Icons.check_rounded,
                                              size: 12,
                                              color: colors.onPrimaryContainer,
                                            ),
                                            const SizedBox(width: 2),
                                          ],
                                          Text(
                                            '${value}x',
                                            maxLines: 1,
                                            style: theme.textTheme.labelMedium
                                                ?.copyWith(
                                                  color: value == rate
                                                      ? colors
                                                            .onPrimaryContainer
                                                      : colors.onSurface,
                                                  fontWeight: value == rate
                                                      ? FontWeight.w700
                                                      : FontWeight.w500,
                                                ),
                                          ),
                                        ],
                                      ),
                                    ),
                                  ),
                                ),
                              ),
                            ),
                          ),
                        ),
                      ),
                  ],
                );
              },
            ),
            if (live) ...[
              const SizedBox(height: 6),
              Text(
                '直播建议 1.0x，倍速受频道缓冲限制',
                style: theme.textTheme.labelSmall?.copyWith(
                  color: colors.onSurfaceVariant,
                ),
              ),
            ],
          ],
        ),
      ),
    );
  }
}
