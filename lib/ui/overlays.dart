import 'dart:math' as math;

import 'package:flutter/material.dart';

Future<T?> showAppSheet<T>(
  BuildContext context, {
  required WidgetBuilder builder,
}) => showModalBottomSheet<T>(
  context: context,
  isScrollControlled: true,
  useSafeArea: true,
  backgroundColor: Colors.transparent,
  barrierColor: Colors.black.withValues(alpha: .42),
  builder: (context) => Padding(
    padding: EdgeInsets.only(bottom: MediaQuery.viewInsetsOf(context).bottom),
    child: builder(context),
  ),
);

class AppSheet extends StatelessWidget {
  const AppSheet({
    super.key,
    required this.title,
    required this.icon,
    required this.child,
    this.subtitle,
    this.heightFraction = .76,
  });

  final String title;
  final String? subtitle;
  final IconData icon;
  final Widget child;
  final double heightFraction;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final colors = theme.colorScheme;
    final available =
        MediaQuery.sizeOf(context).height -
        MediaQuery.viewInsetsOf(context).bottom -
        MediaQuery.paddingOf(context).top;
    return Container(
      height: math.min(760, available * heightFraction),
      clipBehavior: Clip.antiAlias,
      decoration: BoxDecoration(
        color: colors.surface,
        borderRadius: const BorderRadius.vertical(top: Radius.circular(28)),
        border: Border.all(color: colors.outlineVariant.withValues(alpha: .22)),
      ),
      child: SafeArea(
        top: false,
        child: Column(
          children: [
            Container(
              width: 32,
              height: 4,
              margin: const EdgeInsets.only(top: 10, bottom: 18),
              decoration: BoxDecoration(
                color: colors.outlineVariant,
                borderRadius: BorderRadius.circular(8),
              ),
            ),
            Padding(
              padding: const EdgeInsets.fromLTRB(20, 0, 12, 18),
              child: Row(
                children: [
                  Container(
                    width: 44,
                    height: 44,
                    decoration: BoxDecoration(
                      color: colors.primaryContainer.withValues(alpha: .55),
                      borderRadius: BorderRadius.circular(15),
                    ),
                    child: Icon(icon, color: colors.primary, size: 23),
                  ),
                  const SizedBox(width: 12),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          title,
                          style: theme.textTheme.titleLarge?.copyWith(
                            fontSize: 20,
                            fontWeight: FontWeight.w700,
                          ),
                        ),
                        if (subtitle != null) ...[
                          const SizedBox(height: 3),
                          Text(
                            subtitle!,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: theme.textTheme.bodySmall?.copyWith(
                              color: colors.onSurfaceVariant,
                            ),
                          ),
                        ],
                      ],
                    ),
                  ),
                  IconButton(
                    tooltip: '关闭',
                    onPressed: () => Navigator.pop(context),
                    icon: const Icon(Icons.close_rounded, size: 21),
                    style: IconButton.styleFrom(
                      foregroundColor: colors.onSurfaceVariant,
                      backgroundColor: colors.surfaceContainerLow,
                    ),
                  ),
                ],
              ),
            ),
            Expanded(child: child),
          ],
        ),
      ),
    );
  }
}

class AppChoiceTile extends StatelessWidget {
  const AppChoiceTile({
    super.key,
    required this.title,
    required this.selected,
    required this.onTap,
    this.subtitle,
    this.icon,
  });
  final String title;
  final String? subtitle;
  final IconData? icon;
  final bool selected;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    return Padding(
      padding: const EdgeInsets.only(bottom: 8),
      child: Material(
        color: selected
            ? colors.primaryContainer.withValues(alpha: .45)
            : colors.surfaceContainerLow,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(15),
          side: BorderSide(
            color: selected
                ? colors.primary.withValues(alpha: .25)
                : Colors.transparent,
          ),
        ),
        clipBehavior: Clip.antiAlias,
        child: ListTile(
          selected: selected,
          selectedColor: colors.primary,
          contentPadding: const EdgeInsets.symmetric(
            horizontal: 14,
            vertical: 2,
          ),
          minTileHeight: 54,
          leading: icon == null ? null : Icon(icon, size: 21),
          title: Text(
            title,
            maxLines: 2,
            overflow: TextOverflow.ellipsis,
            style: TextStyle(
              fontSize: 14,
              fontWeight: selected ? FontWeight.w600 : FontWeight.w500,
            ),
          ),
          subtitle: subtitle == null
              ? null
              : Text(
                  subtitle!,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(fontSize: 12),
                ),
          trailing: Icon(
            selected ? Icons.check_circle_rounded : Icons.chevron_right_rounded,
            size: selected ? 21 : 19,
            color: selected ? colors.primary : colors.outline,
          ),
          onTap: onTap,
        ),
      ),
    );
  }
}

class SheetSectionLabel extends StatelessWidget {
  const SheetSectionLabel(this.label, {super.key});
  final String label;
  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.fromLTRB(4, 8, 4, 12),
    child: Text(
      label,
      style: Theme.of(context).textTheme.labelMedium?.copyWith(
        color: Theme.of(context).colorScheme.onSurfaceVariant,
        fontWeight: FontWeight.w600,
      ),
    ),
  );
}
