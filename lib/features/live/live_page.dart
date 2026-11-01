import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';

import '../../core/app_controller.dart';
import '../../core/live/live_repository.dart';
import '../../ui/components.dart';
import '../player/player_page.dart';

class LivePage extends StatefulWidget {
  const LivePage({super.key, required this.controller});
  final AppController controller;
  @override
  State<LivePage> createState() => _LivePageState();
}

class _LivePageState extends State<LivePage> {
  String _query = '', _group = '全部';
  bool _loading = false;
  final _guides = <String, Future<EpgGuide>>{};
  AppController get c => widget.controller;
  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) => _load());
  }

  Future<void> _load() async {
    if (_loading) return;
    setState(() {
      _loading = true;
      _guides.clear();
    });
    await runUi(context, c.loadLive);
    if (mounted) setState(() => _loading = false);
  }

  Future<void> _helperSources() async {
    final selected = c.selectedLiveHelperSources.toSet();
    final result = await showDialog<Set<String>>(
      context: context,
      builder: (dialogContext) => StatefulBuilder(
        builder: (context, update) => AlertDialog(
          title: const Text('接口助手直播源'),
          content: SizedBox(
            width: 560,
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                const Text(
                  '可选内置公开列表；不会替换已有订阅。直连失败后尝试备选（含第三方代理）。仅抓取列表，不扫描或验证媒体；可播性及授权请自行确认。',
                ),
                Wrap(
                  spacing: 8,
                  children: [
                    TextButton(
                      onPressed: () => update(() {
                        selected.addAll(['source-02', 'source-12']);
                      }),
                      child: const Text('添加推荐 2 组'),
                    ),
                    TextButton(
                      onPressed: () => update(selected.clear),
                      child: const Text('清空助手选择'),
                    ),
                  ],
                ),
                Flexible(
                  child: SingleChildScrollView(
                    child: Column(
                      children: [
                        for (final source in liveHelperSources)
                          CheckboxListTile(
                            contentPadding: EdgeInsets.zero,
                            title: Text(source.name),
                            subtitle: Text(source.description),
                            value: selected.contains(source.id),
                            onChanged: (value) => update(() {
                              if (value == true) {
                                selected.add(source.id);
                              } else {
                                selected.remove(source.id);
                              }
                            }),
                            secondary: IconButton(
                              tooltip: '仅选此助手源（保留用户订阅）',
                              icon: const Icon(Icons.playlist_add),
                              onPressed: () =>
                                  Navigator.pop(dialogContext, {source.id}),
                            ),
                          ),
                      ],
                    ),
                  ),
                ),
              ],
            ),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(dialogContext),
              child: const Text('取消'),
            ),
            FilledButton(
              onPressed: () => Navigator.pop(dialogContext, selected),
              child: Text('保存并加载（${selected.length} 组）'),
            ),
          ],
        ),
      ),
    );
    if (result == null || !mounted) return;
    setState(() {
      _loading = true;
      _group = '全部';
      _guides.clear();
    });
    await runUi(context, () => c.setLiveHelperSources(result));
    if (mounted) setState(() => _loading = false);
  }

  bool _favorite(LiveChannel channel) => c.store.liveFavorites.any(
    (item) =>
        item.name == channel.name &&
        item.group == channel.group &&
        item.tvgId == channel.tvgId &&
        listEquals(item.urls, channel.urls),
  );
  Future<void> _play(LiveChannel channel) async {
    if (channel.urls.isEmpty) {
      showMessage(context, '该频道没有播放地址');
      return;
    }
    await Navigator.push(
      context,
      MaterialPageRoute<void>(
        builder: (_) => PlayerPage(
          title: channel.name,
          live: true,
          lines: [
            for (var i = 0; i < channel.urls.length; i++)
              PlayLine(
                name: '线路 ${i + 1}',
                episodes: [Episode(name: channel.name, id: channel.urls[i])],
              ),
          ],
          resolve: (line, _) => c.playLive(
            channel,
            index: int.parse(line.name.split(' ').last) - 1,
          ),
        ),
      ),
    );
  }

  String _guideUrl(LiveChannel channel) => channel.epg
      .replaceAll('{name}', Uri.encodeComponent(channel.name))
      .replaceAll('{id}', Uri.encodeComponent(channel.tvgId))
      .replaceAll('{date}', DateTime.now().toIso8601String().substring(0, 10));
  Future<void> _epg(LiveChannel channel) async {
    if (channel.epg.isEmpty) {
      showMessage(context, '该频道未配置节目单');
      return;
    }
    final url = _guideUrl(channel);
    final future = _guides.putIfAbsent(
      url,
      () => LiveRepository(c.http).loadEpg(url, headers: channel.headers),
    );
    await showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      showDragHandle: true,
      builder: (context) => SafeArea(
        child: SizedBox(
          height: MediaQuery.sizeOf(context).height * .7,
          child: FutureBuilder<EpgGuide>(
            future: future,
            builder: (context, snapshot) {
              if (snapshot.hasError) {
                return ErrorNotice(
                  error: '${snapshot.error}',
                  onRetry: () {
                    _guides.remove(url);
                    Navigator.pop(context);
                    _epg(channel);
                  },
                );
              }
              if (!snapshot.hasData) {
                return const Center(child: CircularProgressIndicator());
              }
              final guide = snapshot.data!;
              final id = guide.channels.containsKey(channel.tvgId)
                  ? channel.tvgId
                  : guide.channels.entries
                            .where((entry) => entry.value == channel.name)
                            .map((entry) => entry.key)
                            .firstOrNull ??
                        channel.name;
              final programmes = guide.forChannel(id)
                ..sort((a, b) => a.start.compareTo(b.start));
              final now = guide.now(id), next = guide.next(id);
              return ListView(
                padding: const EdgeInsets.all(20),
                children: [
                  Text(
                    '${channel.name} · 节目单',
                    style: Theme.of(context).textTheme.titleLarge,
                  ),
                  const SizedBox(height: 12),
                  Text('正在播出：${now?.title ?? '暂无信息'}'),
                  Text('即将播出：${next?.title ?? '暂无信息'}'),
                  const Divider(height: 28),
                  if (programmes.isEmpty)
                    const EmptyState(
                      title: '没有匹配的节目',
                      message: '请检查频道的 tvg-id 与节目单数据是否一致。',
                    ),
                  for (final programme in programmes)
                    ListTile(
                      contentPadding: EdgeInsets.zero,
                      leading: Text(
                        TimeOfDay.fromDateTime(programme.start.toLocal())
                            .format(context),
                      ),
                      title: Text(programme.title),
                      subtitle: programme.description.isEmpty
                          ? null
                          : Text(programme.description),
                      trailing: identical(now, programme)
                          ? const Chip(label: Text('正在播出'))
                          : null,
                    ),
                ],
              );
            },
          ),
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) => ListenableBuilder(
    listenable: c,
    builder: (context, _) {
      final channels = _group == '收藏' ? c.store.liveFavorites : c.liveChannels;
      final groups = [
        '全部',
        '收藏',
        ...c.liveChannels.map((item) => item.group).toSet(),
      ];
      final items = channels
          .where(
            (channel) =>
                (_group == '全部' || _group == '收藏' || channel.group == _group) &&
                channel.name.toLowerCase().contains(_query.toLowerCase()),
          )
          .toList();
      return Scaffold(
        appBar: AppBar(
          title: const Text('电视直播'),
          actions: [
            IconButton(
              tooltip: '刷新频道',
              onPressed: _loading ? null : _load,
              icon: const Icon(Icons.refresh),
            ),
          ],
        ),
        body: Column(
          children: [
            ListTile(
              leading: const Icon(Icons.playlist_add),
              title: const Text('接口助手直播源'),
              subtitle: Text(
                '已选 ${c.selectedLiveHelperSources.length}/15 组 · 选择 / 添加 · 不替换已有订阅',
              ),
              trailing: const Icon(Icons.chevron_right),
              onTap: _loading ? null : _helperSources,
            ),
            Padding(
              padding: const EdgeInsets.all(16),
              child: TextField(
                onChanged: (value) => setState(() => _query = value),
                decoration: const InputDecoration(
                  hintText: '搜索频道',
                  prefixIcon: Icon(Icons.search),
                ),
              ),
            ),
            SizedBox(
              height: 48,
              child: ListView(
                scrollDirection: Axis.horizontal,
                padding: const EdgeInsets.symmetric(horizontal: 16),
                children: [
                  for (final group in groups)
                    Padding(
                      padding: const EdgeInsets.only(right: 8),
                      child: ChoiceChip(
                        label: Text(group),
                        selected: _group == group,
                        onSelected: (_) => setState(() => _group = group),
                      ),
                    ),
                ],
              ),
            ),
            if (_loading) const LinearProgressIndicator(minHeight: 2),
            if (c.error != null)
              Padding(
                padding: const EdgeInsets.all(16),
                child: ErrorNotice(error: c.error!, onRetry: _load),
              ),
            Expanded(
              child: RefreshIndicator(
                onRefresh: _load,
                child: items.isEmpty
                    ? ListView(
                        physics: const AlwaysScrollableScrollPhysics(),
                        children: [
                          const SizedBox(height: 40),
                          EmptyState(
                            title: _group == '收藏' ? '还没有收藏频道' : '暂无频道',
                            message: '支持 M3U / TXT / JSON 直播订阅。\n可选择上方助手源，或在「我的 → 直播订阅」添加地址。',
                            icon: Icons.live_tv,
                          ),
                        ],
                      )
                    : ListView.separated(
                        padding: const EdgeInsets.all(16),
                        itemCount: items.length,
                        separatorBuilder: (_, _) => const SizedBox(height: 10),
                        itemBuilder: (context, index) {
                          final channel = items[index];
                          return Card(
                            child: ListTile(
                              contentPadding: const EdgeInsets.fromLTRB(
                                12,
                                6,
                                4,
                                6,
                              ),
                              leading: SizedBox(
                                width: 44,
                                height: 44,
                                child: channel.logo.isEmpty
                                    ? Icon(
                                        Icons.live_tv,
                                        color: Theme.of(context)
                                            .colorScheme
                                            .primary,
                                      )
                                    : Poster(
                                        url: channel.logo,
                                        headers: channel.headers,
                                      ),
                              ),
                              title: Text(channel.name),
                              subtitle: Text(
                                '${channel.group} · ${channel.urls.length} 条线路',
                              ),
                              onTap: () => _play(channel),
                              trailing: Row(
                                mainAxisSize: MainAxisSize.min,
                                children: [
                                  IconButton(
                                    tooltip: '查看节目单',
                                    onPressed: () => _epg(channel),
                                    icon: const Icon(Icons.event_note_outlined),
                                  ),
                                  IconButton(
                                    tooltip: '收藏频道',
                                    onPressed: () => runUi(context, () async {
                                      await c.store.toggleLiveFavorite(channel);
                                      c.refreshLibrary();
                                    }),
                                    icon: Icon(
                                      _favorite(channel)
                                          ? Icons.star
                                          : Icons.star_outline,
                                    ),
                                  ),
                                ],
                              ),
                            ),
                          );
                        },
                      ),
              ),
            ),
          ],
        ),
      );
    },
  );
}
