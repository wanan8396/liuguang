import 'dart:async';

import 'package:flutter/material.dart';

import '../../core/app_controller.dart';
import '../../core/search/search_concurrency.dart';
import '../../core/search/search_history.dart';
import '../../ui/components.dart';
import '../detail/detail_page.dart';

class SearchPage extends StatefulWidget {
  const SearchPage({super.key, required this.controller});
  final AppController controller;
  @override
  State<SearchPage> createState() => _SearchPageState();
}

class _SearchResult {
  const _SearchResult(this.vod, this.config, this.site);
  final Vod vod;
  final TvConfig config;
  final Site site;
}

class _SearchPageState extends State<SearchPage> {
  final _input = TextEditingController();
  final _items = <_SearchResult>[];
  final _errors = <String>[];
  bool _busy = false, _searched = false;
  int _generation = 0, _done = 0, _total = 0;
  late SearchHistorySession _historySession;
  List<String> get _history => _historySession.history;
  @override
  void initState() {
    super.initState();
    _historySession = SearchHistorySession.forStore(widget.controller.store);
    _historySession.addListener(_historyChanged);
  }

  @override
  void didUpdateWidget(covariant SearchPage oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (!identical(oldWidget.controller.store, widget.controller.store)) {
      _historySession.removeListener(_historyChanged);
      _historySession = SearchHistorySession.forStore(widget.controller.store);
      _historySession.addListener(_historyChanged);
    }
  }

  void _historyChanged() {
    if (mounted) setState(() {});
  }

  void _saveHistory(Future<void> operation) {
    operation.catchError((Object error) {
      if (mounted) showMessage(context, '保存搜索历史失败：$error');
    });
  }

  String _keyword = '';
  String? _siteFilter;

  void _cancel() {
    _generation++;
    if (_busy) widget.controller.cancelSearch();
    if (mounted) setState(() => _busy = false);
  }

  Future<void> _search() async {
    if (_input.text.trim().isEmpty) return;
    _cancel();
    final generation = _generation;
    final c = widget.controller;
    _items.clear();
    _errors.clear();
    _siteFilter = null;
    _keyword = _input.text.trim();
    _saveHistory(_historySession.add(_keyword));
    final targets = <(TvConfig, Site)>[];
    for (final config in c.configs) {
      for (final site in c.enabledSites(config)) {
        if (site.searchable) targets.add((config, site));
      }
    }
    setState(() {
      _busy = true;
      _searched = true;
      _done = 0;
      _total = targets.length;
    });
    if (targets.isEmpty) _errors.add('没有可搜索的站点，请先添加订阅并选择内容源。');
    var cursor = 0;
    Future<void> worker() async {
      while (cursor < targets.length && generation == _generation) {
        final (config, site) = targets[cursor++];
        try {
          final result = await c
              .search(_keyword, site: site, config: config, page: 1)
              .timeout(SearchConcurrency.sourceTimeout);
          if (!mounted || generation != _generation) return;
          _items.addAll(
            result.items.map((vod) => _SearchResult(vod, config, site)),
          );
        } catch (error) {
          if (!mounted || generation != _generation) return;
          _errors.add('${config.name} / ${site.name}：$error');
        }
        if (!mounted || generation != _generation) return;
        setState(() => _done++);
      }
    }

    // 异步 I/O 并发，不创建 Dart 线程；本次任务使用启动时的并发上限。
    await Future.wait(
      List.generate(
        targets.length.clamp(0, SearchConcurrency.defaultLimit),
        (_) => worker(),
      ),
    );
    if (mounted && generation == _generation) setState(() => _busy = false);
  }

  /// 按来源汇总，供左侧来源筛选栏使用。
  List<(String, int)> get _sources {
    final counts = <String, int>{};
    for (final item in _items) {
      counts[item.site.name] = (counts[item.site.name] ?? 0) + 1;
    }
    final entries = counts.entries.toList()
      ..sort((a, b) => b.value.compareTo(a.value));
    return [for (final e in entries) (e.key, e.value)];
  }

  List<_SearchResult> get _visible => _siteFilter == null
      ? _items
      : _items.where((item) => item.site.name == _siteFilter).toList();

  @override
  void dispose() {
    _generation++;
    if (_busy) widget.controller.cancelSearch();
    _historySession.removeListener(_historyChanged);
    _input.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final sources = _sources;
    final visible = _visible;
    return Scaffold(
      appBar: AppBar(
        titleSpacing: 0,
        title: TextField(
          controller: _input,
          autofocus: true,
          textInputAction: TextInputAction.search,
          onSubmitted: (_) => _search(),
          decoration: InputDecoration(
            hintText: '搜索电影、剧集、综艺',
            isDense: true,
            filled: true,
            fillColor: scheme.surfaceContainerHighest.withValues(alpha: .6),
            contentPadding: const EdgeInsets.symmetric(
              horizontal: 16,
              vertical: 10,
            ),
            border: OutlineInputBorder(
              borderRadius: BorderRadius.circular(22),
              borderSide: BorderSide.none,
            ),
          ),
        ),
        actions: [
          IconButton(
            tooltip: _busy ? '取消搜索' : '搜索',
            onPressed: _busy ? _cancel : _search,
            icon: Icon(_busy ? Icons.close : Icons.search),
          ),
          const SizedBox(width: 4),
        ],
      ),
      body: Column(
        children: [
          if (_busy) const LinearProgressIndicator(minHeight: 2),
          if (_history.isNotEmpty)
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 8, 16, 4),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(
                    children: [
                      const Text('搜索历史'),
                      const Spacer(),
                      TextButton(
                        onPressed: () => _saveHistory(_historySession.clear()),
                        child: const Text('清空历史'),
                      ),
                    ],
                  ),
                  SizedBox(
                    height: 42,
                    child: ListView.separated(
                      scrollDirection: Axis.horizontal,
                      itemCount: _history.length,
                      separatorBuilder: (_, _) => const SizedBox(width: 8),
                      itemBuilder: (context, index) {
                        final keyword = _history[index];
                        return InputChip(
                          label: Text(keyword),
                          onPressed: () {
                            _input.text = keyword;
                            _search();
                          },
                          deleteButtonTooltipMessage: '删除 $keyword',
                          onDeleted: () =>
                              _saveHistory(_historySession.remove(keyword)),
                        );
                      },
                    ),
                  ),
                ],
              ),
            ),
          if (_searched)
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 10, 16, 6),
              child: Align(
                alignment: Alignment.centerLeft,
                child: Text(
                  '搜索($_done/$_total)',
                  style: Theme.of(context).textTheme.titleSmall,
                ),
              ),
            ),
          if (_errors.isNotEmpty)
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 16),
              child: ExpansionTile(
                tilePadding: EdgeInsets.zero,
                title: Text(
                  '${_errors.length} 个站点提示',
                  style: TextStyle(color: scheme.error, fontSize: 13),
                ),
                children: [
                  for (final error in _errors)
                    Padding(
                      padding: const EdgeInsets.all(8),
                      child: SelectableText(
                        error,
                        style: const TextStyle(fontSize: 12),
                      ),
                    ),
                ],
              ),
            ),
          Expanded(
            child: !_searched
                ? const Center(
                    child: EmptyState(
                      title: '寻找下一段好时光',
                      message: '输入关键词，搜索所有已启用的可搜索站点。',
                      icon: Icons.search,
                    ),
                  )
                : visible.isEmpty && !_busy
                ? const Center(
                    child: EmptyState(
                      title: '没有找到相关影片',
                      message: '试试其他关键词或内容源。',
                    ),
                  )
                : Row(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      if (sources.length > 1)
                        _SourceRail(
                          sources: sources,
                          selected: _siteFilter,
                          onSelect: (value) =>
                              setState(() => _siteFilter = value),
                        ),
                      Expanded(
                        child: ListView.separated(
                          padding: const EdgeInsets.fromLTRB(12, 8, 16, 20),
                          itemCount: visible.length,
                          separatorBuilder: (_, _) =>
                              const SizedBox(height: 10),
                          itemBuilder: (context, index) {
                            final result = visible[index];
                            return _ResultCard(
                              result: result,
                              onTap: () => openDetail(
                                context,
                                widget.controller,
                                result.vod,
                                result.config,
                                result.site,
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
    );
  }
}

/// 左侧来源栏：与截图一致的窄列，每项显示来源名与命中数量。
class _SourceRail extends StatelessWidget {
  const _SourceRail({
    required this.sources,
    required this.selected,
    required this.onSelect,
  });
  final List<(String, int)> sources;
  final String? selected;
  final ValueChanged<String?> onSelect;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return SizedBox(
      width: 108,
      child: ListView(
        padding: const EdgeInsets.fromLTRB(12, 8, 0, 20),
        children: [
          _RailItem(
            label: '全部显示',
            count: null,
            active: selected == null,
            color: scheme.primary,
            onTap: () => onSelect(null),
          ),
          for (final (name, count) in sources)
            _RailItem(
              label: name,
              count: count,
              active: selected == name,
              color: scheme.primary,
              onTap: () => onSelect(name),
            ),
        ],
      ),
    );
  }
}

class _RailItem extends StatelessWidget {
  const _RailItem({
    required this.label,
    required this.count,
    required this.active,
    required this.color,
    required this.onTap,
  });
  final String label;
  final int? count;
  final bool active;
  final Color color;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.only(bottom: 8),
    child: Material(
      color: active
          ? color
          : Theme.of(context).colorScheme.surfaceContainerHighest
                .withValues(alpha: .55),
      borderRadius: BorderRadius.circular(10),
      child: InkWell(
        borderRadius: BorderRadius.circular(10),
        onTap: onTap,
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 10),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                label,
                maxLines: 2,
                overflow: TextOverflow.ellipsis,
                style: TextStyle(
                  fontSize: 12,
                  height: 1.25,
                  fontWeight: active ? FontWeight.w600 : FontWeight.w400,
                  color: active
                      ? Theme.of(context).colorScheme.onPrimary
                      : Theme.of(context).colorScheme.onSurface,
                ),
              ),
              if (count != null) ...[
                const SizedBox(height: 3),
                Text(
                  '$count',
                  style: TextStyle(
                    fontSize: 10,
                    color: active
                        ? Theme.of(context).colorScheme.onPrimary
                              .withValues(alpha: .8)
                        : Theme.of(context).colorScheme.onSurfaceVariant,
                  ),
                ),
              ],
            ],
          ),
        ),
      ),
    ),
  );
}

/// 横向图片卡片：左侧海报，右侧标题／更新信息／来源标签。
class _ResultCard extends StatelessWidget {
  const _ResultCard({required this.result, required this.onTap});
  final _SearchResult result;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final vod = result.vod;
    return Card(
      clipBehavior: Clip.antiAlias,
      child: InkWell(
        onTap: onTap,
        child: Padding(
          padding: const EdgeInsets.all(10),
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              SizedBox(
                width: 92,
                height: 130,
                child: Poster(
                  url: vod.pic,
                  headers: imageHeaders(result.config, result.site, vod),
                ),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: SizedBox(
                  height: 130,
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        vod.name,
                        maxLines: 2,
                        overflow: TextOverflow.ellipsis,
                        style: const TextStyle(
                          fontSize: 15,
                          fontWeight: FontWeight.w600,
                        ),
                      ),
                      const SizedBox(height: 6),
                      Text(
                        vod.remarks.isNotEmpty
                            ? vod.remarks
                            : [
                                vod.year,
                                vod.area,
                              ].where((e) => e.isNotEmpty).join(' · '),
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: TextStyle(
                          fontSize: 12,
                          color: scheme.onSurfaceVariant,
                        ),
                      ),
                      const Spacer(),
                      Row(
                        children: [
                          Expanded(
                            child: Text.rich(
                              TextSpan(
                                children: [
                                  TextSpan(
                                    text: '来源：',
                                    style: TextStyle(
                                      fontSize: 12,
                                      color: scheme.onSurfaceVariant,
                                    ),
                                  ),
                                  TextSpan(
                                    text: result.site.name,
                                    style: TextStyle(
                                      fontSize: 12,
                                      fontWeight: FontWeight.w600,
                                      color: scheme.primary,
                                    ),
                                  ),
                                ],
                              ),
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                            ),
                          ),
                          Icon(
                            Icons.chevron_right,
                            size: 18,
                            color: scheme.onSurfaceVariant,
                          ),
                        ],
                      ),
                    ],
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
