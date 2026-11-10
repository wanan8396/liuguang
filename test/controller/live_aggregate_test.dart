import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';
import 'package:flutter_test/flutter_test.dart';
import 'package:tvbox/core/app_controller.dart';
import 'package:tvbox/core/network/app_http_client.dart';
import 'package:tvbox/core/storage/app_store.dart';
import 'app_controller_test.dart' show MemorySecrets, TestEngine;

class _Http extends AppHttpClient {
  final responses = <String, Future<FetchResult> Function()>{};
  @override
  Future<FetchResult> fetch(
    String url, {
    Map<String, String> headers = const {},
  }) async =>
      responses[url]?.call() ??
      (throw const AppHttpException('timeout', 'fixture timeout'));
}

class _Engine extends TestEngine {
  _Engine(super.http);
  String? playedConfig, playedSite;
  @override
  Future<Playback> playLive(
    TvConfig? config,
    Site? site,
    LiveChannel channel, {
    int index = 0,
  }) async {
    playedConfig = config?.url;
    playedSite = site?.key;
    return Playback(url: channel.urls[index]);
  }
}

void main() {
  late Directory directory;
  late AppStore store;
  late _Http http;
  late _Engine engine;
  late AppController controller;
  TvConfig config(String name, dynamic entry) => TvConfig(
    url: 'https://repo.test/$name',
    name: name,
    raw: {
      'sites': [
        {'key': name, 'name': name, 'type': 3, 'api': 'csp_$name'},
      ],
      'lives': [entry],
    },
  );
  final first = config('first', {'url': 'https://live.test/slow'});
  final second = config('second', {
    'name': '跨仓频道',
    'urls': ['http://127.0.0.1:9978/proxy?do=live'],
  });
  setUp(() async {
    directory = await Directory.systemTemp.createTemp('live-aggregate-');
    store = AppStore(path: directory.path, secretStorage: MemorySecrets());
    await store.init();
    await store.saveSubscription(
      ImportResult(
        url: 'https://repo.test/all',
        nodes: [
          for (final c in [first, second])
            RepoNode(url: c.url, name: c.name, config: c, status: 'ready'),
        ],
      ),
    );
    http = _Http();
    engine = _Engine(http);
    controller = AppController(store: store, http: http, engine: engine);
    await controller.initialize();
  });
  tearDown(() async {
    await controller.disposeAsync();
    await directory.delete(recursive: true);
  });
  test('汇总全部仓库并增量显示，慢来源不阻塞频道，保留原播放会话归属', () async {
    final pending = Completer<FetchResult>();
    http.responses['https://live.test/slow'] = () => pending.future;
    final loading = controller.loadLive();
    await Future<void>.delayed(Duration.zero);
    expect(controller.liveChannels.single.name, '跨仓频道');
    expect(controller.liveChannels.single.configUrl, second.url);
    final restored = LiveChannel.fromJson(
      controller.liveChannels.single.toJson(),
    );
    await controller.playLive(restored);
    expect(engine.playedConfig, second.url);
    expect(engine.playedSite, 'second');
    await controller.selectSource(second, second.sites.single);
    expect(controller.liveChannels.single.name, '跨仓频道');
    pending.completeError(const AppHttpException('timeout', 'slow failed'));
    await loading;
    expect(controller.liveChannels.single.name, '跨仓频道');
    expect(controller.liveError, contains('slow failed'));
    expect(controller.liveSourcesLoaded, 2);
  });
  test('刷新失败保留该来源上次有效频道，其他仓库照常加载', () async {
    http.responses['https://live.test/slow'] = () async => FetchResult(
      bytes: Uint8List.fromList(
        utf8.encode('缓存频道,https://media.test/live.m3u8'),
      ),
      finalUrl: 'https://live.test/slow',
      statusCode: 200,
      headers: {},
    );
    await controller.loadLive();
    http.responses.clear();
    await controller.loadLive();
    expect(
      controller.liveChannels.map((c) => c.name),
      containsAll(['缓存频道', '跨仓频道']),
    );
    expect(controller.liveError, contains('fixture timeout'));
  });
}
