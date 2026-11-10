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

  Future<void> _showSources() => showAppSheet<void>(
    context,
    builder: (context) => AppSheet(
      title: '直播来源状态',
      subtitle: '已显示 ${c.liveChannels.length} 个频道，失败来源不影响其他频道',
      icon: Icons.info_outline_rounded,
      child: ListView(
        padding: const EdgeInsets.all(20),
        children: [SelectableText(c.liveError ?? '全部来源加载完成')],
      ),
    ),
  );

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
    await showAppSheet<void>(
      context,
      builder: (context) => AppSheet(
        title: '节目单',
        subtitle: channel.name,
        icon: Icons.calendar_today_rounded,
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
                      TimeOfDay.fromDateTime(
                        programme.start.toLocal(),
                      ).format(context),
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
    );
  }

  @override
  Widget build(BuildContext context) => ListenableBuilder(
    listenable: c,
    builder: (context, _) {
      if (_group != '全部' &&
          _group != '收藏' &&
          !c.liveChannels.any((channel) => channel.group == _group)) {
        _group = '全部';
      }
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
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 4),
              child: Row(
                children: [
                  Expanded(
                    child: Text(
                      _loading
                          ? '已发现 ${c.liveChannels.length} 个频道 · 来源 ${c.liveSourcesLoaded}/${c.liveSourceCount}'
                          : '全部订阅 · ${c.liveChannels.length} 个频道',
                    ),
                  ),
                  if (c.liveError != null)
                    TextButton(
                      onPressed: _showSources,
                      child: const Text('来源状态'),
                    ),
                ],
              ),
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
                            message:
                                '支持 M3U / TXT / JSON 直播订阅。\n在「我的 → 直播订阅」添加地址后刷新。',
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
                                        color: Theme.of(
                                          context,
                                        ).colorScheme.primary,
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
