import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:html/parser.dart' as html;

import '../core/app_controller.dart';
import '../core/network/image_request.dart';
import 'overlays.dart';
export 'overlays.dart';

String plainText(String text) => html.parseFragment(text).text ?? '';
String timeLabel(Duration value) {
  final seconds = value.inSeconds.clamp(0, 359999);
  final minutes = seconds ~/ 60;
  return '${minutes ~/ 60 > 0 ? '${minutes ~/ 60}:' : ''}${(minutes % 60).toString().padLeft(2, '0')}:${(seconds % 60).toString().padLeft(2, '0')}';
}

/// Only explicit image headers are inherited. Playback cookies/tokens must not
/// accidentally be sent to an unrelated poster host.
Map<String, String> imageHeaders(TvConfig? config, Site? site, [Vod? vod]) {
  final result = <String, String>{'User-Agent': 'okhttp/4.9.1'};
  void merge(dynamic value) {
    try {
      if (value is String) value = jsonDecode(value);
      if (value is Map) {
        for (final entry in value.entries) {
          if (entry.value is String) result[entry.key.toString()] = entry.value;
        }
      }
    } catch (_) {
      /* Invalid optional image metadata does not block the list. */
    }
  }

  // Generic request metadata may safely contribute UA and referrer only.
  // Never forward its cookies/authorization to third-party image hosts.
  void mergeSafe(dynamic value) {
    try {
      if (value is String) value = jsonDecode(value);
      if (value is Map) {
        for (final entry in value.entries) {
          if ([
                'user-agent',
                'referer',
                'origin',
              ].contains(entry.key.toString().toLowerCase()) &&
              entry.value is String) {
            result[entry.key.toString()] = entry.value;
          }
        }
      }
    } catch (_) {
      /* Optional metadata may use a non-JSON plugin format. */
    }
  }

  mergeSafe(config?.raw['headers'] ?? config?.raw['header']);
  mergeSafe(site?.raw['headers'] ?? site?.raw['header']);
  final ua = site?.raw['ua'] ?? config?.raw['ua'];
  if (ua is String && ua.isNotEmpty) result['User-Agent'] = ua;
  final referer = site?.raw['referer'] ?? config?.raw['referer'];
  if (referer is String && referer.isNotEmpty) result['Referer'] = referer;
  merge(config?.raw['imageHeaders'] ?? config?.raw['picHeader']);
  merge(site?.raw['imageHeaders'] ?? site?.raw['picHeader']);
  merge(vod?.raw['picHeader'] ?? vod?.raw['vod_pic_header']);
  return result;
}

Future<void> runUi(BuildContext context, Future<void> Function() task) async {
  try {
    await task();
  } catch (error) {
    if (context.mounted) showMessage(context, error.toString());
  }
}

void showMessage(BuildContext context, String text) {
  ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(text)));
}

Future<bool> confirm(
  BuildContext context,
  String title,
  String message,
) async =>
    await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        icon: Container(
          width: 52,
          height: 52,
          alignment: Alignment.center,
          decoration: BoxDecoration(
            color: Theme.of(
              context,
            ).colorScheme.primaryContainer.withValues(alpha: .5),
            borderRadius: BorderRadius.circular(17),
          ),
          child: Icon(
            Icons.help_outline_rounded,
            color: Theme.of(context).colorScheme.primary,
            size: 26,
          ),
        ),
        title: Text(title),
        content: Text(message),
        actions: [
          Row(
            children: [
              Expanded(
                child: FilledButton.tonal(
                  onPressed: () => Navigator.pop(context, false),
                  child: const Text('取消'),
                ),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: FilledButton(
                  onPressed: () => Navigator.pop(context, true),
                  child: const Text('确认'),
                ),
              ),
            ],
          ),
        ],
      ),
    ) ??
    false;

class EmptyState extends StatelessWidget {
  const EmptyState({
    super.key,
    required this.title,
    required this.message,
    this.icon = Icons.video_library_outlined,
    this.action,
    this.actionLabel,
  });
  final String title, message;
  final IconData icon;
  final VoidCallback? action;
  final String? actionLabel;
  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.all(28),
    child: Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        Container(
          padding: const EdgeInsets.all(22),
          decoration: BoxDecoration(
            color: Theme.of(
              context,
            ).colorScheme.primaryContainer.withValues(alpha: .4),
            borderRadius: BorderRadius.circular(28),
          ),
          child: Icon(
            icon,
            size: 38,
            color: Theme.of(context).colorScheme.primary,
          ),
        ),
        const SizedBox(height: 18),
        Text(
          title,
          style: Theme.of(context).textTheme.titleMedium,
          textAlign: TextAlign.center,
        ),
        const SizedBox(height: 8),
        Text(
          message,
          style: Theme.of(context).textTheme.bodyMedium?.copyWith(
            color: Theme.of(context).colorScheme.onSurfaceVariant,
          ),
          textAlign: TextAlign.center,
        ),
        if (action != null) ...[
          const SizedBox(height: 18),
          FilledButton.tonal(
            onPressed: action,
            child: Text(actionLabel ?? '重试'),
          ),
        ],
      ],
    ),
  );
}

class ErrorNotice extends StatelessWidget {
  const ErrorNotice({super.key, required this.error, this.onRetry});
  final String error;
  final VoidCallback? onRetry;
  @override
  Widget build(BuildContext context) => Card(
    color: Theme.of(context).colorScheme.errorContainer,
    child: Padding(
      padding: const EdgeInsets.all(14),
      child: Row(
        children: [
          const Icon(Icons.error_outline, size: 20),
          const SizedBox(width: 10),
          Expanded(child: SelectableText(error)),
          if (onRetry != null)
            IconButton(
              tooltip: '重试',
              onPressed: onRetry,
              icon: const Icon(Icons.refresh),
            ),
        ],
      ),
    ),
  );
}

class Poster extends StatelessWidget {
  const Poster({
    super.key,
    required this.url,
    this.headers = const {},
    this.fallbackUrl = '',
    this.fallbackHeaders = const {},
  });
  final String url;
  final Map<String, String> headers;
  final String fallbackUrl;
  final Map<String, String> fallbackHeaders;
  @override
  Widget build(BuildContext context) {
    final request = ImageRequest.parse(url, headers: headers);
    final placeholder = ColoredBox(
      color: Theme.of(context).colorScheme.surfaceContainerHighest,
      child: Center(
        child: Icon(
          Icons.image_not_supported_outlined,
          size: 30,
          color: Theme.of(context).colorScheme.onSurfaceVariant,
        ),
      ),
    );
    Widget load(ImageRequest image, {Widget? fallback}) => Image.network(
      image.url,
      headers: image.headers,
      fit: BoxFit.cover,
      errorBuilder: (_, _, _) => fallback ?? placeholder,
      loadingBuilder: (_, child, progress) =>
          progress == null ? child : placeholder,
    );
    final backup = ImageRequest.parse(fallbackUrl, headers: fallbackHeaders);
    final fallback = backup.url.isNotEmpty && backup.url != request.url
        ? load(backup)
        : null;
    return ClipRRect(
      borderRadius: BorderRadius.circular(12),
      child: request.url.isEmpty
          ? fallback ?? placeholder
          : load(request, fallback: fallback),
    );
  }
}

class VodTile extends StatelessWidget {
  const VodTile({
    super.key,
    required this.vod,
    required this.onTap,
    this.headers = const {},
    this.source,
  });
  final Vod vod;
  final VoidCallback onTap;
  final Map<String, String> headers;
  final String? source;
  @override
  Widget build(BuildContext context) => Semantics(
    button: true,
    label: vod.name,
    child: InkWell(
      borderRadius: BorderRadius.circular(12),
      onTap: onTap,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Expanded(
            child: Stack(
              fit: StackFit.expand,
              children: [
                Poster(url: vod.pic, headers: headers),
                if (vod.remarks.isNotEmpty)
                  Positioned(
                    bottom: 0,
                    left: 0,
                    right: 0,
                    child: Container(
                      padding: const EdgeInsets.fromLTRB(7, 18, 7, 7),
                      decoration: BoxDecoration(
                        borderRadius: BorderRadius.circular(12),
                        gradient: const LinearGradient(
                          begin: Alignment.topCenter,
                          end: Alignment.bottomCenter,
                          colors: [Colors.transparent, Colors.black87],
                        ),
                      ),
                      child: Text(
                        vod.remarks,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: const TextStyle(
                          color: Colors.white,
                          fontSize: 11,
                        ),
                      ),
                    ),
                  ),
              ],
            ),
          ),
          const SizedBox(height: 8),
          Text(
            vod.name,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: const TextStyle(fontSize: 13, fontWeight: FontWeight.w600),
          ),
          Text(
            source ??
                [vod.year, vod.area].where((e) => e.isNotEmpty).join(' · '),
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: TextStyle(
              fontSize: 11,
              color: Theme.of(context).colorScheme.onSurfaceVariant,
            ),
          ),
        ],
      ),
    ),
  );
}

Future<void> chooseSource(
  BuildContext context,
  AppController controller,
) async {
  final selection = await showAppSheet<(TvConfig, Site)>(
    context,
    builder: (_) => _SourcePicker(controller: controller),
  );
  if (selection == null || !context.mounted) return;
  await runUi(context, () async {
    final (config, site) = selection;
    await controller.selectSource(config, site);
  });
}

class _SourcePicker extends StatefulWidget {
  const _SourcePicker({required this.controller});
  final AppController controller;
  @override
  State<_SourcePicker> createState() => _SourcePickerState();
}

class _SourcePickerState extends State<_SourcePicker> {
  String? _repo;
  String? _subscription;
  String _query = '';
  final _search = TextEditingController();
  @override
  void initState() {
    super.initState();
    _repo =
        widget.controller.currentConfig?.url ??
        widget.controller.configs.firstOrNull?.url;
  }

  @override
  void dispose() {
    _search.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => ListenableBuilder(
    listenable: widget.controller,
    builder: (context, _) {
      final c = widget.controller;
      final colors = Theme.of(context).colorScheme;
      final subscriptions = c.subscriptions;
      final entry = subscriptions
          .where((s) => s.url == _subscription)
          .firstOrNull;
      final entryUrls = entry?.configs.map((r) => r.url).toSet();
      final configs = c.configs
          .where((r) => entryUrls == null || entryUrls.contains(r.url))
          .toList();
      final selected =
          configs.where((r) => r.url == _repo).firstOrNull ??
          configs.firstOrNull;
      final query = _query.trim().toLowerCase();
      final matches = <(TvConfig, Site)>[
        for (final config in configs)
          if (query.isNotEmpty || config.url == selected?.url)
            for (final site in c.enabledSites(config))
              if (query.isEmpty ||
                  '${c.configName(config)} ${site.name}'.toLowerCase().contains(
                    query,
                  ))
                (config, site),
      ];
      return AppSheet(
        title: '选择内容源',
        subtitle: '${configs.length} 个仓库 · 发现更多好内容',
        icon: Icons.video_library_outlined,
        heightFraction: .84,
        child: Column(
          children: [
            if (subscriptions.length > 1)
              Padding(
                padding: const EdgeInsets.fromLTRB(20, 0, 20, 12),
                child: DropdownButtonFormField<String>(
                  initialValue: _subscription ?? '',
                  isExpanded: true,
                  decoration: const InputDecoration(
                    prefixIcon: Icon(Icons.subscriptions_outlined, size: 20),
                    contentPadding: EdgeInsets.symmetric(
                      horizontal: 12,
                      vertical: 8,
                    ),
                  ),
                  items: [
                    const DropdownMenuItem(
                      value: '',
                      child: Text('全部订阅', style: TextStyle(fontSize: 14)),
                    ),
                    for (final s in subscriptions)
                      DropdownMenuItem(
                        value: s.url,
                        child: Text(
                          c.subscriptionName(s.url),
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: const TextStyle(fontSize: 14),
                        ),
                      ),
                  ],
                  onChanged: (value) => setState(() {
                    _subscription = value?.isEmpty == true ? null : value;
                    _repo = null;
                  }),
                ),
              ),
            Padding(
              padding: const EdgeInsets.fromLTRB(20, 0, 20, 16),
              child: TextField(
                controller: _search,
                onChanged: (value) => setState(() => _query = value),
                decoration: InputDecoration(
                  hintText: '搜索仓库或内容源',
                  hintStyle: TextStyle(
                    fontSize: 14,
                    color: colors.onSurfaceVariant,
                  ),
                  prefixIcon: const Icon(Icons.search_rounded, size: 21),
                  suffixIcon: _query.isEmpty
                      ? null
                      : IconButton(
                          tooltip: '清空搜索',
                          icon: const Icon(Icons.close_rounded, size: 18),
                          onPressed: () {
                            _search.clear();
                            setState(() => _query = '');
                          },
                        ),
                  contentPadding: const EdgeInsets.symmetric(vertical: 12),
                ),
              ),
            ),
            Expanded(
              child: configs.isEmpty
                  ? const EmptyState(
                      title: '还没有内容源',
                      message: '添加视频订阅后，就可以在这里切换。',
                    )
                  : Row(
                      crossAxisAlignment: CrossAxisAlignment.stretch,
                      children: [
                        if (query.isEmpty)
                          Container(
                            width: MediaQuery.sizeOf(context).width < 380
                                ? 92
                                : 108,
                            margin: const EdgeInsets.only(left: 12, bottom: 12),
                            decoration: BoxDecoration(
                              color: colors.surfaceContainerLow,
                              borderRadius: BorderRadius.circular(18),
                            ),
                            child: ListView.builder(
                              padding: const EdgeInsets.all(6),
                              itemCount: configs.length,
                              itemBuilder: (context, index) {
                                final config = configs[index];
                                final active = config.url == selected?.url;
                                return Padding(
                                  padding: const EdgeInsets.only(bottom: 4),
                                  child: Material(
                                    color: active
                                        ? colors.surface
                                        : Colors.transparent,
                                    borderRadius: BorderRadius.circular(13),
                                    child: InkWell(
                                      borderRadius: BorderRadius.circular(13),
                                      onTap: () =>
                                          setState(() => _repo = config.url),
                                      child: Semantics(
                                        selected: active,
                                        button: true,
                                        child: Padding(
                                          padding: const EdgeInsets.symmetric(
                                            horizontal: 10,
                                            vertical: 15,
                                          ),
                                          child: Text(
                                            c.configName(config),
                                            maxLines: 2,
                                            overflow: TextOverflow.ellipsis,
                                            style: TextStyle(
                                              fontSize: 13,
                                              fontWeight: active
                                                  ? FontWeight.w700
                                                  : FontWeight.w500,
                                              color: active
                                                  ? colors.primary
                                                  : colors.onSurfaceVariant,
                                            ),
                                          ),
                                        ),
                                      ),
                                    ),
                                  ),
                                );
                              },
                            ),
                          ),
                        Expanded(
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              Padding(
                                padding: const EdgeInsets.fromLTRB(
                                  16,
                                  0,
                                  16,
                                  10,
                                ),
                                child: Text(
                                  query.isEmpty
                                      ? '${c.configName(selected)} · ${matches.length} 个源'
                                      : '找到 ${matches.length} 个内容源',
                                  style: TextStyle(
                                    fontSize: 12,
                                    color: colors.onSurfaceVariant,
                                  ),
                                ),
                              ),
                              Expanded(
                                child: matches.isEmpty
                                    ? Center(
                                        child: Padding(
                                          padding: const EdgeInsets.all(20),
                                          child: Text(
                                            query.isEmpty
                                                ? '此仓库暂无已启用的内容源'
                                                : '没有找到匹配的内容源',
                                            style: TextStyle(
                                              color: colors.onSurfaceVariant,
                                            ),
                                          ),
                                        ),
                                      )
                                    : ListView.builder(
                                        key: ValueKey(
                                          '$query|${selected?.url}',
                                        ),
                                        padding: const EdgeInsets.fromLTRB(
                                          12,
                                          0,
                                          16,
                                          20,
                                        ),
                                        itemCount: matches.length,
                                        itemBuilder: (context, index) {
                                          final (config, site) = matches[index];
                                          return AppChoiceTile(
                                            title: site.name,
                                            subtitle:
                                                c.shortDramaFallback(
                                                      config,
                                                      site,
                                                    ) !=
                                                    null
                                                ? '备用直达 · ${c.shortDramaFallback(config, site)!.name}'
                                                : query.isEmpty
                                                ? null
                                                : c.configName(config),
                                            selected:
                                                config.url ==
                                                    c.currentConfig?.url &&
                                                site.key == c.currentSite?.key,
                                            onTap: () => Navigator.pop(
                                              context,
                                              (config, site),
                                            ),
                                          );
                                        },
                                      ),
                              ),
                            ],
                          ),
                        ),
                      ],
                    ),
            ),
          ],
        ),
      );
    },
  );
}
