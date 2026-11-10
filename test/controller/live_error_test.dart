import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:tvbox/core/app_controller.dart';
import 'package:tvbox/core/engine/source_engine.dart';
import 'package:tvbox/core/network/app_http_client.dart';
import 'package:tvbox/core/storage/app_store.dart';

import 'app_controller_test.dart' show MemorySecrets, TestEngine;

class _LiveHttp extends AppHttpClient {
  final responses = <String, Future<FetchResult>>{};

  @override
  Future<FetchResult> fetch(
    String url, {
    Map<String, String> headers = const {},
  }) async {
    final response = responses[url];
    if (response == null) {
      throw AppHttpException('fixture', '直播列表不可用', url: url);
    }
    return response;
  }
}

const _playlistUrl = 'https://live.invalid/channels.txt';

FetchResult _playlist(String channel) => FetchResult(
  bytes: Uint8List.fromList(
    utf8.encode('$channel,https://media.invalid/channel.m3u8'),
  ),
  finalUrl: _playlistUrl,
  statusCode: 200,
  headers: const {},
);

void main() {
  late Directory directory;
  late AppStore store;
  late _LiveHttp http;
  late TestEngine engine;
  late AppController controller;
  final config = TvConfig(
    url: 'https://repo.invalid/config',
    name: '当前仓库',
    raw: {
      'sites': [
        {'key': 'a', 'name': '首页站点', 'type': 3, 'api': 'csp_Fixture'},
      ],
      'lives': [
        {'name': '直播列表', 'url': _playlistUrl},
      ],
    },
  );

  setUp(() async {
    directory = await Directory.systemTemp.createTemp('liuguang-live-errors-');
    store = AppStore(path: directory.path, secretStorage: MemorySecrets());
    await store.init();
    await store.saveSubscription(
      ImportResult(
        url: config.url,
        nodes: [
          RepoNode(
            url: config.url,
            name: config.name,
            config: config,
            status: 'ready',
          ),
        ],
      ),
    );
    http = _LiveHttp();
    engine = TestEngine(http);
    controller = AppController(store: store, http: http, engine: engine);
    await controller.initialize();
  });

  tearDown(() async {
    await controller.disposeAsync();
    await directory.delete(recursive: true);
  });

  test('直播先成功、首页后失败时只显示首页错误，刷新直播也不清空首页错误', () async {
    engine.homes['a'] = Completer<VodPage>();
    http.responses[_playlistUrl] = Future.value(_playlist('频道甲'));
    final home = controller.refreshHome();
    await controller.loadLive();
    engine.homes['a']!.completeError(
      const SourceFailure('plugin', 'Expected BEGIN_OBJECT but was STRING'),
    );
    await home;
    expect(controller.error, contains('Expected BEGIN_OBJECT'));
    expect(controller.liveError, isNull);
    expect(controller.liveChannels.single.name, '频道甲');

    await controller.loadLive();
    expect(controller.error, contains('Expected BEGIN_OBJECT'));
    expect(controller.liveError, isNull);
    expect(controller.liveChannels.single.name, '频道甲');
  });

  test('直播后失败不覆盖首页错误，首页重试不清除直播诊断', () async {
    engine.homeError = const SourceFailure('plugin', '首页插件初始化失败');
    final pending = Completer<FetchResult>();
    http.responses[_playlistUrl] = pending.future;
    final live = controller.loadLive();
    await controller.refreshHome();
    pending.completeError(
      const AppHttpException('fixture', '直播连接失败', url: _playlistUrl),
    );
    await live;
    expect(controller.error, contains('首页插件初始化失败'));
    expect(controller.liveError, contains('直播连接失败'));

    engine.homeError = null;
    await controller.refreshHome();
    expect(controller.error, isNull);
    expect(controller.homePage?.items.single.name, '首页站点');
    expect(controller.liveError, contains('直播连接失败'));

    http.responses[_playlistUrl] = Future.value(_playlist('恢复频道'));
    await controller.loadLive();
    expect(controller.liveError, isNull);
    expect(controller.liveChannels.single.name, '恢复频道');
    expect(controller.homePage?.items.single.name, '首页站点');
  });

  for (final action in ['删除当前订阅', '恢复备份']) {
    Future<void> reset() => switch (action) {
      '删除当前订阅' => controller.removeSubscription(config.url),
      _ => controller.reloadAfterRestore(),
    };

    test('$action 清除上一仓库的直播频道与诊断', () async {
      controller.currentConfig = TvConfig(
        url: config.url,
        name: config.name,
        raw: {
          ...config.raw,
          'lives': [
            {
              'name': '已有频道',
              'urls': ['https://media.invalid/channel.m3u8'],
            },
            ...config.lives,
          ],
        },
      );
      await controller.loadLive();
      expect(controller.liveChannels.single.name, '已有频道');
      expect(controller.liveError, contains('直播列表不可用'));

      await reset();
      expect(controller.liveChannels, isEmpty);
      expect(controller.liveError, isNull);
    });

    test('$action 后旧直播请求的频道与失败不能回写', () async {
      controller.currentConfig = TvConfig(
        url: config.url,
        name: config.name,
        raw: {
          ...config.raw,
          'lives': [
            {'name': '已失败列表', 'url': 'https://live.invalid/missing.txt'},
            ...config.lives,
          ],
        },
      );
      final pending = Completer<FetchResult>();
      http.responses[_playlistUrl] = pending.future;
      final live = controller.loadLive();
      await Future<void>.delayed(Duration.zero);
      await reset();
      pending.complete(_playlist('迟到频道'));
      await live;
      expect(controller.liveChannels, isEmpty);
      expect(controller.liveError, isNull);
    });
  }
}
