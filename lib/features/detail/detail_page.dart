import 'package:flutter/material.dart';
import 'package:share_plus/share_plus.dart';

import '../../core/app_controller.dart';
import '../../ui/components.dart';
import '../player/player_page.dart';

Future<void> openDetail(
  BuildContext context,
  AppController controller,
  Vod vod,
  TvConfig config,
  Site site,
) => Navigator.push(
  context,
  MaterialPageRoute<void>(
    builder: (_) => DetailPage(
      controller: controller,
      vod: vod,
      config: config,
      site: site,
    ),
  ),
);

class DetailPage extends StatefulWidget {
  const DetailPage({
    super.key,
    required this.controller,
    required this.vod,
    required this.config,
    required this.site,
  });
  final AppController controller;
  final Vod vod;
  final TvConfig config;
  final Site site;
  @override
  State<DetailPage> createState() => _DetailPageState();
}

class _DetailPageState extends State<DetailPage> {
  VodDetail? _detail;
  String? _error;
  int _line = 0;
  bool _reversed = false, _loading = true;
  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      final detail = await widget.controller.detail(
        widget.vod,
        config: widget.config,
        site: widget.site,
      );
      if (mounted) setState(() => _detail = detail);
    } catch (error) {
      if (mounted) setState(() => _error = error.toString());
    }
    if (mounted) setState(() => _loading = false);
  }

  LibraryEntry? get _history => widget.controller.store.history
      .where(
        (entry) =>
            entry.configUrl == widget.config.url &&
            entry.siteKey == widget.site.key &&
            entry.vod.id == widget.vod.id,
      )
      .firstOrNull;
  Future<void> _play(
    int line,
    int episode, {
    Duration start = Duration.zero,
  }) async {
    final detail = _detail!;
    await Navigator.push(
      context,
      MaterialPageRoute<void>(
        builder: (_) => PlayerPage(
          title: detail.vod.name,
          lines: detail.lines,
          initialLine: line,
          initialEpisode: episode,
          initialPosition: start,
          resolve: (line, episode) => widget.controller.play(
            line,
            episode,
            site: widget.site,
            config: widget.config,
          ),
          onProgress: (line, episode, position, duration) =>
              widget.controller.recordProgress(
                detail.vod,
                line,
                episode,
                position,
                duration,
                site: widget.site,
                config: widget.config,
              ),
        ),
      ),
    );
    if (mounted) setState(() {});
  }

  @override
  Widget build(BuildContext context) {
    final vod = _detail?.vod ?? widget.vod;
    final lines = _detail?.lines ?? <PlayLine>[];
    final history = _history;
    return Scaffold(
      appBar: AppBar(
        title: const Text('影片详情'),
        actions: [
          IconButton(
            tooltip: '分享影片信息',
            icon: const Icon(Icons.ios_share),
            onPressed: () => runUi(context, () async {
              final box = context.findRenderObject() as RenderBox?;
              await SharePlus.instance.share(
                ShareParams(
                  text:
                      '${vod.name}\n来源：${widget.config.name} / ${widget.site.name}\n影片 ID：${vod.id}',
                  sharePositionOrigin: box == null
                      ? null
                      : box.localToGlobal(Offset.zero) & box.size,
                ),
              );
            }),
          ),
        ],
      ),
      body: ListView(
        padding: const EdgeInsets.all(16),
        children: [
          Card(
            child: Padding(
              padding: const EdgeInsets.all(16),
              child: Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  SizedBox(
                    width: 108,
                    height: 154,
                    child: Poster(
                      url: vod.pic,
                      headers: imageHeaders(widget.config, widget.site, vod),
                    ),
                  ),
                  const SizedBox(width: 16),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          vod.name,
                          style: Theme.of(context).textTheme.titleLarge
                              ?.copyWith(fontWeight: FontWeight.bold),
                        ),
                        const SizedBox(height: 8),
                        Text(
                          [
                            vod.year,
                            vod.area,
                            vod.remarks,
                          ].where((s) => s.isNotEmpty).join(' · '),
                        ),
                        if (vod.score.isNotEmpty)
                          Padding(
                            padding: const EdgeInsets.only(top: 8),
                            child: Text(
                              '评分 ${vod.score}',
                              style: TextStyle(
                                color: Theme.of(context).colorScheme.primary,
                              ),
                            ),
                          ),
                        const SizedBox(height: 10),
                        Text(
                          widget.site.name,
                          style: Theme.of(context).textTheme.labelSmall,
                        ),
                        ListenableBuilder(
                          listenable: widget.controller,
                          builder: (context, _) {
                            final favorite = widget.controller.isFavorite(
                              vod,
                              site: widget.site,
                              config: widget.config,
                            );
                            return TextButton.icon(
                              onPressed: () => runUi(
                                context,
                                () => widget.controller.toggleFavorite(
                                  vod,
                                  site: widget.site,
                                  config: widget.config,
                                ),
                              ),
                              icon: Icon(
                                favorite
                                    ? Icons.favorite
                                    : Icons.favorite_border,
                              ),
                              label: Text(favorite ? '已收藏' : '收藏影片'),
                            );
                          },
                        ),
                      ],
                    ),
                  ),
                ],
              ),
            ),
          ),
          const SizedBox(height: 16),
          Card(
            child: Padding(
              padding: const EdgeInsets.all(16),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text('剧情简介', style: Theme.of(context).textTheme.titleMedium),
                  const SizedBox(height: 10),
                  SelectableText(
                    plainText(vod.content).trim().isEmpty
                        ? '此内容源未提供简介。'
                        : plainText(vod.content),
                  ),
                  if (vod.actor.isNotEmpty)
                    Padding(
                      padding: const EdgeInsets.only(top: 12),
                      child: Text('演员：${vod.actor}'),
                    ),
                  if (vod.director.isNotEmpty)
                    Padding(
                      padding: const EdgeInsets.only(top: 6),
                      child: Text('导演：${vod.director}'),
                    ),
                ],
              ),
            ),
          ),
          const SizedBox(height: 16),
          if (_loading)
            const Center(
              child: Padding(
                padding: EdgeInsets.all(24),
                child: CircularProgressIndicator(),
              ),
            ),
          if (_error != null) ErrorNotice(error: _error!, onRetry: _load),
          if (!_loading && _error == null && lines.isEmpty)
            const EmptyState(title: '暂无播放线路', message: '详情已加载，但该内容源没有提供选集信息。'),
          if (lines.isNotEmpty)
            Card(
              child: Padding(
                padding: const EdgeInsets.all(16),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Row(
                      children: [
                        Text(
                          '播放选集',
                          style: Theme.of(context).textTheme.titleMedium,
                        ),
                        const Spacer(),
                        TextButton.icon(
                          onPressed: () =>
                              setState(() => _reversed = !_reversed),
                          icon: const Icon(Icons.sort),
                          label: Text(_reversed ? '倒序' : '正序'),
                        ),
                      ],
                    ),
                    if (history != null)
                      Padding(
                        padding: const EdgeInsets.only(bottom: 12),
                        child: FilledButton.icon(
                          icon: const Icon(Icons.history),
                          label: Text(
                            '继续观看 ${history.episode} · ${timeLabel(Duration(milliseconds: history.positionMs))}',
                          ),
                          onPressed: () {
                            final lineIndex = lines.indexWhere(
                              (line) => line.name == history.line,
                            );
                            final l = lineIndex < 0 ? 0 : lineIndex;
                            final episodeIndex = lines[l].episodes.indexWhere(
                              (episode) => episode.id == history.episodeId,
                            );
                            _play(
                              l,
                              episodeIndex < 0 ? 0 : episodeIndex,
                              start: Duration(milliseconds: history.positionMs),
                            );
                          },
                        ),
                      ),
                    SingleChildScrollView(
                      scrollDirection: Axis.horizontal,
                      child: Row(
                        children: [
                          for (var index = 0; index < lines.length; index++)
                            Padding(
                              padding: const EdgeInsets.only(right: 8),
                              child: ChoiceChip(
                                label: Text(lines[index].name),
                                selected: _line == index,
                                onSelected: (_) =>
                                    setState(() => _line = index),
                              ),
                            ),
                        ],
                      ),
                    ),
                    const SizedBox(height: 12),
                    Wrap(
                      spacing: 8,
                      runSpacing: 8,
                      children: [
                        for (final index in List.generate(
                          lines[_line].episodes.length,
                          (i) => i,
                        ).letReverse(_reversed))
                          OutlinedButton(
                            onPressed: () => _play(_line, index),
                            child: Text(lines[_line].episodes[index].name),
                          ),
                      ],
                    ),
                  ],
                ),
              ),
            ),
          const SizedBox(height: 24),
        ],
      ),
    );
  }
}

extension on List<int> {
  Iterable<int> letReverse(bool reverse) => reverse ? reversed : this;
}
