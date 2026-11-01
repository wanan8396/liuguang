import 'package:flutter/material.dart';

import '../../core/app_controller.dart';
import '../../ui/components.dart';
import '../detail/detail_page.dart';

class LibraryPage extends StatelessWidget {
  const LibraryPage({
    super.key,
    required this.controller,
    this.history = false,
  });
  final AppController controller;
  final bool history;
  Future<void> _open(BuildContext context, LibraryEntry entry) async {
    final config = controller.configs
        .where((item) => item.url == entry.configUrl)
        .firstOrNull;
    final site = config?.sites
        .where((item) => item.key == entry.siteKey)
        .firstOrNull;
    if (config == null || site == null) {
      showMessage(context, '原仓库或站点已被移除，请重新添加原订阅后观看。');
      return;
    }
    await openDetail(context, controller, entry.vod, config, site);
  }

  @override
  Widget build(BuildContext context) => ListenableBuilder(
    listenable: controller,
    builder: (context, _) {
      final entries = history
          ? controller.store.history
          : controller.store.favorites;
      return Scaffold(
        appBar: AppBar(
          title: Text(history ? '观看历史' : '我的收藏'),
          actions: [
            if (history && entries.isNotEmpty)
              IconButton(
                tooltip: '清空观看历史',
                onPressed: () async {
                  if (await confirm(context, '清空观看历史？', '此操作会删除全部续播记录。') &&
                      context.mounted) {
                    await runUi(context, () async {
                      await controller.store.clearHistory();
                      controller.refreshLibrary();
                    });
                  }
                },
                icon: const Icon(Icons.delete_sweep_outlined),
              ),
          ],
        ),
        body: entries.isEmpty
            ? Center(
                child: EmptyState(
                  title: history ? '还没有观看记录' : '收藏你的心动影片',
                  message: history ? '播放后的进度会保存在这里。' : '在影片详情点击收藏，随时回来继续看。',
                  icon: history ? Icons.history : Icons.favorite_border,
                ),
              )
            : ListView.separated(
                padding: const EdgeInsets.all(16),
                itemCount: entries.length,
                separatorBuilder: (_, _) => const SizedBox(height: 10),
                itemBuilder: (context, index) {
                  final entry = entries[index];
                  final config = controller.configs
                      .where((item) => item.url == entry.configUrl)
                      .firstOrNull;
                  final site = config?.sites
                      .where((item) => item.key == entry.siteKey)
                      .firstOrNull;
                  return Card(
                    child: InkWell(
                      borderRadius: BorderRadius.circular(18),
                      onTap: () => _open(context, entry),
                      child: Padding(
                        padding: const EdgeInsets.all(12),
                        child: Row(
                          children: [
                            SizedBox(
                              width: 64,
                              height: 88,
                              child: Poster(
                                url: entry.vod.pic,
                                headers: imageHeaders(config, site, entry.vod),
                              ),
                            ),
                            const SizedBox(width: 14),
                            Expanded(
                              child: Column(
                                crossAxisAlignment: CrossAxisAlignment.start,
                                children: [
                                  Text(
                                    entry.vod.name,
                                    style: Theme.of(
                                      context,
                                    ).textTheme.titleSmall,
                                  ),
                                  const SizedBox(height: 6),
                                  Text(
                                    site?.name ?? '原内容源已移除',
                                    style: Theme.of(
                                      context,
                                    ).textTheme.bodySmall,
                                  ),
                                  if (history) ...[
                                    const SizedBox(height: 6),
                                    Text(
                                      '${entry.episode} · ${timeLabel(Duration(milliseconds: entry.positionMs))}',
                                      style: Theme.of(
                                        context,
                                      ).textTheme.bodySmall,
                                    ),
                                    if (entry.durationMs > 0)
                                      Padding(
                                        padding: const EdgeInsets.only(top: 8),
                                        child: LinearProgressIndicator(
                                          value:
                                              (entry.positionMs /
                                                      entry.durationMs)
                                                  .clamp(0, 1),
                                          borderRadius: BorderRadius.circular(
                                            4,
                                          ),
                                        ),
                                      ),
                                  ],
                                ],
                              ),
                            ),
                            IconButton(
                              tooltip: history ? '删除记录' : '取消收藏',
                              icon: const Icon(Icons.close),
                              onPressed: () => runUi(context, () async {
                                if (history) {
                                  await controller.store.removeHistory(
                                    entry.key,
                                  );
                                } else {
                                  await controller.store.toggleFavorite(entry);
                                }
                                controller.refreshLibrary();
                              }),
                            ),
                          ],
                        ),
                      ),
                    ),
                  );
                },
              ),
      );
    },
  );
}
