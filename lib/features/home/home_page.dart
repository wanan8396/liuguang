import 'package:flutter/material.dart';

import '../../core/app_controller.dart';
import '../../ui/components.dart';
import '../detail/detail_page.dart';
import '../search/search_page.dart';

class HomePage extends StatefulWidget {
  const HomePage({
    super.key,
    required this.controller,
    required this.onSubscriptions,
  });
  final AppController controller;
  final VoidCallback onSubscriptions;
  @override
  State<HomePage> createState() => _HomePageState();
}

class _HomePageState extends State<HomePage> {
  String? _category;
  String _source = '';
  final _filters = <String, dynamic>{};
  AppController get c => widget.controller;
  Future<void> _refresh() => _category == null
      ? c.refreshHome()
      : c.loadCategory(_category!, filters: _filters);
  @override
  Widget build(BuildContext context) => ListenableBuilder(
    listenable: c,
    builder: (context, _) {
      final source = '${c.currentConfig?.url}|${c.currentSite?.key}';
      if (_source != source) {
        _source = source;
        _category = null;
        _filters.clear();
      }
      final page = c.currentPage;
      final filterRows = jsonList(c.homePage?.filters[_category]);
      final plugin =
          c.currentSite?.runtime == 'jar' || c.currentSite?.runtime == 'js';
      return Scaffold(
        appBar: AppBar(
          titleSpacing: 20,
          title: InkWell(
            borderRadius: BorderRadius.circular(12),
            onTap: () => chooseSource(context, c),
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                Flexible(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        c.currentSite?.name ?? '流光',
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                      ),
                      Text(
                        c.currentConfig?.name ?? '光影随行 · 自由探索',
                        maxLines: 1,
                        style: TextStyle(
                          fontSize: 11,
                          color: Theme.of(context).colorScheme.onSurfaceVariant,
                        ),
                      ),
                    ],
                  ),
                ),
                const Icon(Icons.expand_more, size: 21),
              ],
            ),
          ),
          actions: [
            IconButton(
              tooltip: '搜索影片',
              onPressed: () => Navigator.push(
                context,
                MaterialPageRoute<void>(
                  builder: (_) => SearchPage(controller: c),
                ),
              ),
              icon: const Icon(Icons.search),
            ),
            IconButton(
              tooltip: '刷新',
              onPressed: c.busy ? null : _refresh,
              icon: const Icon(Icons.refresh),
            ),
            const SizedBox(width: 6),
          ],
        ),
        body: RefreshIndicator(
          onRefresh: _refresh,
          child: CustomScrollView(
            physics: const AlwaysScrollableScrollPhysics(),
            slivers: [
              SliverToBoxAdapter(
                child: Padding(
                  padding: const EdgeInsets.fromLTRB(16, 12, 16, 8),
                  child: InkWell(
                    borderRadius: BorderRadius.circular(15),
                    onTap: () => Navigator.push(
                      context,
                      MaterialPageRoute<void>(
                        builder: (_) => SearchPage(controller: c),
                      ),
                    ),
                    child: Container(
                      padding: const EdgeInsets.all(14),
                      decoration: BoxDecoration(
                        color: Theme.of(context).colorScheme.surface,
                        borderRadius: BorderRadius.circular(15),
                      ),
                      child: Row(
                        children: [
                          Icon(
                            Icons.search,
                            size: 21,
                            color: Theme.of(context).colorScheme.primary,
                          ),
                          const SizedBox(width: 10),
                          Text(
                            '搜索想看的影片',
                            style: TextStyle(
                              color: Theme.of(
                                context,
                              ).colorScheme.onSurfaceVariant,
                            ),
                          ),
                          const Spacer(),
                          const Icon(Icons.arrow_forward_ios, size: 12),
                        ],
                      ),
                    ),
                  ),
                ),
              ),
              if (c.homePage?.categories.isNotEmpty ?? false)
                SliverToBoxAdapter(
                  child: SizedBox(
                    height: 54,
                    child: ListView(
                      scrollDirection: Axis.horizontal,
                      padding: const EdgeInsets.symmetric(horizontal: 16),
                      children: [
                        Padding(
                          padding: const EdgeInsets.only(right: 8),
                          child: ChoiceChip(
                            label: const Text('推荐'),
                            selected: _category == null,
                            onSelected: (_) {
                              setState(() {
                                _category = null;
                                _filters.clear();
                              });
                              c.refreshHome();
                            },
                          ),
                        ),
                        for (final category in c.homePage!.categories)
                          Padding(
                            padding: const EdgeInsets.only(right: 8),
                            child: ChoiceChip(
                              label: Text(category.name),
                              selected: _category == category.id,
                              onSelected: (_) {
                                setState(() {
                                  _category = category.id;
                                  _filters.clear();
                                });
                                c.loadCategory(category.id);
                              },
                            ),
                          ),
                      ],
                    ),
                  ),
                ),
              if (filterRows.isNotEmpty)
                SliverToBoxAdapter(
                  child: Padding(
                    padding: const EdgeInsets.symmetric(horizontal: 16),
                    child: Card(
                      child: Column(
                        children: [
                          for (final item in filterRows)
                            Builder(
                              builder: (context) {
                                final row = jsonMap(item);
                                final key = str(row['key']);
                                return SizedBox(
                                  height: 46,
                                  child: ListView(
                                    scrollDirection: Axis.horizontal,
                                    padding: const EdgeInsets.symmetric(
                                      horizontal: 10,
                                    ),
                                    children: [
                                      Center(
                                        child: Text(
                                          '${str(row['name'])}  ',
                                          style: Theme.of(
                                            context,
                                          ).textTheme.labelMedium,
                                        ),
                                      ),
                                      for (final v in jsonList(row['value']))
                                        Padding(
                                          padding: const EdgeInsets.symmetric(
                                            horizontal: 3,
                                          ),
                                          child: ChoiceChip(
                                            label: Text(str(jsonMap(v)['n'])),
                                            selected:
                                                str(_filters[key]) ==
                                                str(jsonMap(v)['v']),
                                            onSelected: (_) {
                                              setState(
                                                () => _filters[key] = jsonMap(
                                                  v,
                                                )['v'],
                                              );
                                              _refresh();
                                            },
                                          ),
                                        ),
                                    ],
                                  ),
                                );
                              },
                            ),
                        ],
                      ),
                    ),
                  ),
                ),
              if (plugin && !c.pluginsTrusted)
                SliverToBoxAdapter(
                  child: Padding(
                    padding: const EdgeInsets.all(16),
                    child: Card(
                      child: Padding(
                        padding: const EdgeInsets.all(16),
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            const Row(
                              children: [
                                Icon(Icons.security_outlined),
                                SizedBox(width: 8),
                                Text('此内容源包含可执行插件'),
                              ],
                            ),
                            const SizedBox(height: 8),
                            const Text(
                              '只有信任此仓库后才会运行 JAR / JavaScript。信任绑定当前配置内容，更新后可能需要重新确认。',
                            ),
                            const SizedBox(height: 10),
                            FilledButton.tonal(
                              onPressed: () async {
                                if (await confirm(
                                  context,
                                  '信任当前仓库？',
                                  '插件可以联网并执行代码。仅在确认订阅可信时继续。',
                                )) {
                                  if (context.mounted) {
                                    await runUi(
                                      context,
                                      () => c.trustPlugins(true),
                                    );
                                  }
                                }
                              },
                              child: const Text('信任并加载'),
                            ),
                          ],
                        ),
                      ),
                    ),
                  ),
                ),
              if (c.error != null)
                SliverToBoxAdapter(
                  child: Padding(
                    padding: const EdgeInsets.all(16),
                    child: ErrorNotice(error: c.error!, onRetry: _refresh),
                  ),
                ),
              if (c.busy)
                const SliverToBoxAdapter(
                  child: LinearProgressIndicator(minHeight: 2),
                ),
              if (c.currentConfig == null)
                SliverFillRemaining(
                  hasScrollBody: false,
                  child: Center(
                    child: EmptyState(
                      title: '把喜欢的内容装进流光',
                      message: '添加视频订阅，选择一个内容源开始探索。\n添加订阅后，可浏览分类、搜索与观看。',
                      icon: Icons.auto_awesome_outlined,
                      actionLabel: '添加订阅',
                      action: widget.onSubscriptions,
                    ),
                  ),
                )
              else if (!c.busy && (page?.items.isEmpty ?? true))
                const SliverFillRemaining(
                  hasScrollBody: false,
                  child: Center(
                    child: EmptyState(
                      title: '这里暂时没有内容',
                      message: '可以切换分类、内容源，或通过搜索查找影片。',
                    ),
                  ),
                )
              else
                SliverPadding(
                  padding: const EdgeInsets.fromLTRB(16, 12, 16, 20),
                  sliver: SliverGrid(
                    gridDelegate:
                        const SliverGridDelegateWithFixedCrossAxisCount(
                          crossAxisCount: 3,
                          crossAxisSpacing: 12,
                          mainAxisSpacing: 18,
                          childAspectRatio: .56,
                        ),
                    delegate: SliverChildBuilderDelegate((context, index) {
                      final vod = page!.items[index];
                      return VodTile(
                        vod: vod,
                        headers: imageHeaders(
                          c.currentConfig,
                          c.currentSite,
                          vod,
                        ),
                        onTap: () => openDetail(
                          context,
                          c,
                          vod,
                          c.currentConfig!,
                          c.currentSite!,
                        ),
                      );
                    }, childCount: page?.items.length ?? 0),
                  ),
                ),
              if (_category != null &&
                  page != null &&
                  page.page < page.pageCount)
                SliverToBoxAdapter(
                  child: Padding(
                    padding: const EdgeInsets.fromLTRB(24, 0, 24, 24),
                    child: OutlinedButton(
                      onPressed: c.busy
                          ? null
                          : () => c.loadCategory(
                              _category!,
                              page: page.page + 1,
                              filters: _filters,
                            ),
                      child: Text(
                        c.busy
                            ? '加载中…'
                            : '加载更多 · ${page.page}/${page.pageCount}',
                      ),
                    ),
                  ),
                ),
            ],
          ),
        ),
      );
    },
  );
}
