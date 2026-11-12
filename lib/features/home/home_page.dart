import 'package:flutter/material.dart';

import '../../core/app_controller.dart';
import '../../ui/components.dart';
import '../detail/detail_page.dart';
import '../profile/library_page.dart';
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
  String? get _selectedCategory => _category ?? c.homeCategory;
  Future<void> _refresh() => _selectedCategory == null
      ? c.refreshHome()
      : c.loadCategory(_selectedCategory!, filters: _filters);
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
      final filterRows = jsonList(c.homePage?.filters[_selectedCategory]);
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
                        c.currentConfig == null
                            ? '光影随行 · 自由探索'
                            : c.configName(c.currentConfig),
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
              tooltip: '观看历史',
              onPressed: () => Navigator.push(
                context,
                MaterialPageRoute<void>(
                  builder: (_) => LibraryPage(controller: c, history: true),
                ),
              ),
              icon: const Icon(Icons.history),
            ),
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
              if (c.sourceNotice != null)
                SliverToBoxAdapter(
                  child: Padding(
                    padding: const EdgeInsets.fromLTRB(16, 4, 16, 12),
                    child: Container(
                      padding: const EdgeInsets.all(12),
                      decoration: BoxDecoration(
                        color: Theme.of(context).colorScheme.secondaryContainer,
                        borderRadius: BorderRadius.circular(14),
                      ),
                      child: Row(
                        children: [
                          const Icon(Icons.swap_horiz_rounded, size: 20),
                          const SizedBox(width: 8),
                          Expanded(child: Text(c.sourceNotice!)),
                        ],
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
                        if (c.homeCategory == null)
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
                              selected: _selectedCategory == category.id,
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
              if (_selectedCategory != null &&
                  page != null &&
                  page.page < page.pageCount)
                SliverToBoxAdapter(
                  child: Padding(
                    padding: const EdgeInsets.fromLTRB(24, 0, 24, 24),
                    child: OutlinedButton(
                      onPressed: c.busy
                          ? null
                          : () => c.loadCategory(
                              _selectedCategory!,
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
