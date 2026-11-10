import 'dart:io';
import 'package:flutter_test/flutter_test.dart';
import 'package:tvbox/core/app_controller.dart';
import 'package:tvbox/core/network/app_http_client.dart';
import 'package:tvbox/core/storage/app_store.dart';
import 'app_controller_test.dart' show MemorySecrets, TestEngine;

void main() {
  late Directory directory;
  late AppStore store;
  late AppController controller;
  late TestEngine engine;
  final original = {
    'key': '全网',
    'name': '全网|短剧',
    'type': 4,
    'api': 'http://38.76.197.172:15151/duanju.php?type=dquark',
  };
  final config = TvConfig(
    url: 'https://repo.invalid/short-drama',
    name: '小虎斑',
    raw: {
      'sites': [
        original,
        {'key': 'xingya', 'name': '星芽|短剧', 'type': 3, 'api': 'csp_HBmengyaCAT'},
        {'key': 'haokan', 'name': '好看|短剧', 'type': 3, 'api': 'csp_HBhaokanCAT'},
      ],
    },
  );
  setUp(() async {
    directory = await Directory.systemTemp.createTemp('short-drama-');
    store = AppStore(path: directory.path, secretStorage: MemorySecrets());
    await store.init();
    await store.saveSubscription(
      ImportResult(
        url: config.url,
        nodes: [
          RepoNode(
            url: config.url,
            name: config.name,
            status: 'ready',
            config: config,
          ),
        ],
      ),
    );
    final http = AppHttpClient();
    engine = TestEngine(http);
    controller = AppController(store: store, http: http, engine: engine);
    await controller.initialize();
  });
  tearDown(() async {
    await controller.disposeAsync();
    await directory.delete(recursive: true);
  });

  test('全网短剧入口直接使用同仓备用，详情和历史绑定实际站点', () async {
    await controller.selectSource(config, config.sites.first);
    expect(engine.homeRequests, [(config.url, 'xingya')]);
    expect(controller.currentSite!.key, 'xingya');
    expect(store.setting('currentSite'), 'xingya');
    expect(store.setting('site:${config.url}'), 'xingya');
    expect(controller.sourceNotice, contains('星芽|短剧'));
    expect(
      store.subscriptions.single.configs.single.sites.first.api,
      original['api'],
    );
    await controller.selectSource(config, config.sites.last);
    expect(controller.sourceNotice, isNull);
  });

  test('旧版保存的全网短剧在首次刷新迁移到备用', () async {
    controller.currentConfig = config;
    controller.currentSite = config.sites.first;
    await controller.refreshHome();
    expect(engine.homeRequests, [(config.url, 'xingya')]);
    expect(controller.busy, isFalse);
    expect(controller.error, isNull);
  });

  test('尊重用户停用，只选当前仓库的备用', () async {
    await store.setSetting('disabled:${config.url}', ['xingya']);
    await controller.selectSource(config, config.sites.first);
    expect(controller.currentSite!.key, 'haokan');
    await store.setSetting('disabled:${config.url}', ['xingya', 'haokan']);
    expect(controller.shortDramaFallback(config, config.sites.first), isNull);
  });

  test('不同接口和上游更新后的地址不会被替换', () {
    for (final api in [
      'http://38.76.197.172:15151/duanju.php?type=other',
      'https://new.example/duanju.php?type=dquark',
    ]) {
      expect(
        controller.shortDramaFallback(config, Site({...original, 'api': api})),
        isNull,
      );
    }
  });
}
