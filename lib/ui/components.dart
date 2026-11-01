import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:html/parser.dart' as html;

import '../core/app_controller.dart';

String plainText(String text) => html.parseFragment(text).text ?? '';
String timeLabel(Duration value) {
  final seconds = value.inSeconds.clamp(0, 359999);
  final minutes = seconds ~/ 60;
  return '${minutes ~/ 60 > 0 ? '${minutes ~/ 60}:' : ''}${(minutes % 60).toString().padLeft(2, '0')}:${(seconds % 60).toString().padLeft(2, '0')}';
}

/// Generic headers contribute only safe fields; explicit image headers override
/// them. Playback cookies/tokens must not leak to an unrelated poster host.
Map<String, String> imageHeaders(TvConfig? config, Site? site, [Vod? vod]) {
  final result = <String, String>{'User-Agent': 'okhttp/4.9.1'};
  void put(String key, String value) {
    result.removeWhere(
      (existing, _) => existing.toLowerCase() == key.toLowerCase(),
    );
    result[key] = value;
  }

  void merge(dynamic value) {
    try {
      if (value is String) value = jsonDecode(value);
      if (value is Map) {
        for (final entry in value.entries) {
          if (entry.value is String) put(entry.key.toString(), entry.value);
        }
      }
    } catch (_) {
      /* Invalid optional image metadata does not block the list. */
    }
  }

  // Generic request metadata may safely contribute UA, referer and origin only.
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
            put(entry.key.toString(), entry.value);
          }
        }
      }
    } catch (_) {
      /* Optional metadata may use a non-JSON plugin format. */
    }
  }

  mergeSafe(config?.raw['httpHeaders']);
  mergeSafe(config?.raw['headers'] ?? config?.raw['header']);
  mergeSafe(site?.raw['httpHeaders']);
  mergeSafe(site?.raw['headers'] ?? site?.raw['header']);
  final ua = site?.raw['ua'] ?? config?.raw['ua'];
  if (ua is String && ua.isNotEmpty) put('User-Agent', ua);
  final referer = site?.raw['referer'] ?? config?.raw['referer'];
  if (referer is String && referer.isNotEmpty) put('Referer', referer);
  final base = Uri.tryParse(site?.api ?? '');
  if (!result.keys.any((key) => key.toLowerCase() == 'referer') &&
      base != null &&
      (base.scheme == 'http' || base.scheme == 'https') &&
      base.host.isNotEmpty) {
    put('Referer', base.toString());
  }
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
        title: Text(title),
        content: Text(message),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: const Text('取消'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(context, true),
            child: const Text('确认'),
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
            color: Theme.of(context).colorScheme.primaryContainer
                .withValues(alpha: .4),
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
          style: Theme.of(context).textTheme.bodyMedium
              ?.copyWith(color: Theme.of(context).colorScheme.onSurfaceVariant),
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

/// 仅识别图片地址附带的 UA/Referer，避免把令牌发往图片服务器。
({String url, Map<String, String> headers}) posterRequest(
  String input,
  Map<String, String> headers,
) {
  final parts = input.trim().split(
    RegExp(r'@(?=(?:Referer|User-Agent)=)', caseSensitive: false),
  );
  var address = parts.first.trim();
  final merged = Map<String, String>.of(headers);
  for (final part in parts.skip(1)) {
    final equal = part.indexOf('=');
    if (equal <= 0) continue;
    final key = part.substring(0, equal).trim().toLowerCase();
    if (key != 'referer' && key != 'user-agent') continue;
    final value = part.substring(equal + 1).trim();
    if (value.isEmpty || value.contains('\n') || value.contains('\r')) continue;
    merged.removeWhere((k, _) => k.toLowerCase() == key);
    merged[key == 'referer' ? 'Referer' : 'User-Agent'] = value;
  }
  final uri = Uri.tryParse(address);
  String? referer;
  for (final entry in merged.entries) {
    if (entry.key.toLowerCase() == 'referer') referer = entry.value;
  }
  final base = Uri.tryParse(referer ?? '');
  if (uri != null &&
      !uri.hasScheme &&
      base != null &&
      (base.scheme == 'http' || base.scheme == 'https') &&
      base.host.isNotEmpty) {
    address = base.resolveUri(uri).toString();
  }
  final resolved = Uri.tryParse(address);
  if (resolved == null ||
      !['http', 'https'].contains(resolved.scheme.toLowerCase()) ||
      resolved.host.isEmpty) {
    address = '';
  }
  return (url: address, headers: merged);
}

class Poster extends StatelessWidget {
  const Poster({super.key, required this.url, this.headers = const {}});
  final String url;
  final Map<String, String> headers;
  @override
  Widget build(BuildContext context) {
    final request = posterRequest(url, headers);
    final placeholder = Semantics(
      label: '封面不可用',
      child: ColoredBox(
        color: Theme.of(context).colorScheme.surfaceContainerHighest,
        child: Center(
          child: Icon(
            Icons.image_not_supported_outlined,
            size: 30,
            color: Theme.of(context).colorScheme.onSurfaceVariant,
          ),
        ),
      ),
    );
    return ClipRRect(
      borderRadius: BorderRadius.circular(12),
      child: request.url.isEmpty
          ? placeholder
          : Image.network(
              request.url,
              headers: request.headers,
              fit: BoxFit.cover,
              errorBuilder: (_, _, _) => placeholder,
              loadingBuilder: (_, child, progress) =>
                  progress == null ? child : placeholder,
            ),
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
  await showModalBottomSheet<void>(
    context: context,
    isScrollControlled: true,
    showDragHandle: true,
    builder: (sheetContext) => SafeArea(
      child: SizedBox(
        height: MediaQuery.sizeOf(sheetContext).height * .72,
        child: ListenableBuilder(
          listenable: controller,
          builder: (menuContext, _) => ListView(
            padding: const EdgeInsets.fromLTRB(20, 0, 20, 24),
            children: [
              Text('选择内容源', style: Theme.of(context).textTheme.titleLarge),
              const SizedBox(height: 8),
              if (controller.configs.isEmpty)
                const Text('暂无订阅，请到「我的 → 订阅管理」添加。'),
              for (final config in controller.configs)
                ExpansionTile(
                  initiallyExpanded:
                      config.url == controller.currentConfig?.url,
                  tilePadding: EdgeInsets.zero,
                  title: Text(config.name),
                  subtitle: Text('${config.sites.length} 个站点'),
                  children: [
                    for (final site in controller.enabledSites(config))
                      ListTile(
                        leading: Icon(
                          site.key == controller.currentSite?.key &&
                                  config.url == controller.currentConfig?.url
                              ? Icons.radio_button_checked
                              : Icons.radio_button_unchecked,
                        ),
                        title: Text(site.name),
                        subtitle: Text(site.runtime.toUpperCase()),
                        onTap: () async {
                          Navigator.pop(sheetContext);
                          await runUi(context, () async {
                            if (controller.currentConfig?.url != config.url) {
                              await controller.selectConfig(config);
                            }
                            if (controller.currentSite?.key != site.key) {
                              await controller.selectSite(site);
                            }
                          });
                        },
                      ),
                  ],
                ),
            ],
          ),
        ),
      ),
    ),
  );
}
