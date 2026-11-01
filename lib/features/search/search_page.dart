import 'dart:async';

import 'package:flutter/material.dart';

import '../../core/app_controller.dart';
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
  bool _all = false, _busy = false, _searched = false;
  int _generation = 0, _done = 0, _total = 0, _page = 1, _pageCount = 1;
  String _keyword = '';
  TvConfig? _config;
  Site? _site;
  void _cancel() {
    _generation++;
    if (_busy) widget.controller.cancelSearch();
    if (mounted) setState(() => _busy = false);
  }

  Future<void> _search({bool more = false}) async {
    if (_input.text.trim().isEmpty) return;
    _cancel();
    final generation = _generation;
    final c = widget.controller;
    if (!more) {
      _items.clear();
      _errors.clear();
      _page = 1;
      _keyword = _input.text.trim();
      _config = c.currentConfig;
      _site = c.currentSite;
    }
    final requestedPage = more ? _page + 1 : 1;
    final targets = <(TvConfig, Site)>[];
    if (_all) {
      for (final config in c.configs) {
        for (final site in c.enabledSites(config)) {
          if (site.searchable) {
            targets.add((config, site));
          }
        }
      }
    } else if (_config != null && _site != null) {
      targets.add((_config!, _site!));
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
          final result = await c.search(
            _keyword,
            site: site,
            config: config,
            page: requestedPage,
          );
          if (!mounted || generation != _generation) return;
          _page = requestedPage;
          _pageCount = result.pageCount;
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

    // Three workers bound network/plugin pressure without losing provenance.
    await Future.wait(
      List.generate(targets.length.clamp(0, 3), (_) => worker()),
    );
    if (mounted && generation == _generation) setState(() => _busy = false);
  }

  @override
  void dispose() {
    _generation++;
    if (_busy) widget.controller.cancelSearch();
    _input.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => Scaffold(
    appBar: AppBar(
      title: TextField(
        controller: _input,
        autofocus: true,
        textInputAction: TextInputAction.search,
        onSubmitted: (_) => _search(),
        decoration: const InputDecoration(
          hintText: '搜索电影、剧集、综艺',
          isDense: true,
        ),
      ),
      actions: [
        IconButton(
          tooltip: _busy ? '取消搜索' : '搜索',
          onPressed: _busy ? _cancel : _search,
          icon: Icon(_busy ? Icons.close : Icons.search),
        ),
      ],
    ),
    body: Column(
      children: [
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
          child: Row(
            children: [
              Expanded(
                child: SegmentedButton<bool>(
                  segments: const [
                    ButtonSegment(value: false, label: Text('当前源')),
                    ButtonSegment(value: true, label: Text('已启用源聚合')),
                  ],
                  selected: {_all},
                  onSelectionChanged: _busy
                      ? null
                      : (value) => setState(() => _all = value.first),
                ),
              ),
            ],
          ),
        ),
        if (_busy) ...[
          const LinearProgressIndicator(minHeight: 2),
          Padding(
            padding: const EdgeInsets.all(8),
            child: Text(
              '搜索中 $_done / $_total · 最多 3 个并发',
              style: Theme.of(context).textTheme.bodySmall,
            ),
          ),
        ],
        if (_errors.isNotEmpty)
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 16),
            child: ExpansionTile(
              title: Text(
                '${_errors.length} 个站点提示',
                style: TextStyle(color: Theme.of(context).colorScheme.error),
              ),
              children: [
                for (final error in _errors)
                  Padding(
                    padding: const EdgeInsets.all(8),
                    child: SelectableText(error),
                  ),
              ],
            ),
          ),
        Expanded(
          child: !_searched
              ? const Center(
                  child: EmptyState(
                    title: '寻找下一段好时光',
                    message: '输入关键词，搜索当前内容源或聚合所有已启用站点。',
                    icon: Icons.search,
                  ),
                )
              : _items.isEmpty && !_busy
              ? const Center(
                  child: EmptyState(title: '没有找到相关影片', message: '试试其他关键词或内容源。'),
                )
              : CustomScrollView(
                  slivers: [
                    SliverPadding(
                      padding: const EdgeInsets.all(16),
                      sliver: SliverGrid(
                        gridDelegate:
                            const SliverGridDelegateWithFixedCrossAxisCount(
                              crossAxisCount: 3,
                              crossAxisSpacing: 12,
                              mainAxisSpacing: 18,
                              childAspectRatio: .55,
                            ),
                        delegate: SliverChildBuilderDelegate((context, index) {
                          final result = _items[index];
                          return VodTile(
                            vod: result.vod,
                            source: result.site.name,
                            headers: imageHeaders(
                              result.config,
                              result.site,
                              result.vod,
                            ),
                            onTap: () => openDetail(
                              context,
                              widget.controller,
                              result.vod,
                              result.config,
                              result.site,
                            ),
                          );
                        }, childCount: _items.length),
                      ),
                    ),
                    if (!_all &&
                        !_busy &&
                        _items.isNotEmpty &&
                        _page < _pageCount)
                      SliverToBoxAdapter(
                        child: Padding(
                          padding: const EdgeInsets.all(20),
                          child: OutlinedButton(
                            onPressed: () => _search(more: true),
                            child: const Text('加载更多'),
                          ),
                        ),
                      ),
                  ],
                ),
        ),
      ],
    ),
  );
}
