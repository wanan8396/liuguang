import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:tvbox/core/app_controller.dart';
import 'package:tvbox/core/network/app_http_client.dart';
import 'package:tvbox/core/storage/app_store.dart';

import '../config/config_test.dart' show Adapter, body;
import 'app_controller_test.dart' show MemorySecrets, TestEngine;

void main() {
  late Directory directory;
  late AppController controller;
  late Adapter adapter;
  late TestEngine engine;
  var unavailable = false;

  setUp(() async {
    unavailable = false;
    directory = await Directory.systemTemp.createTemp('builtin-subscription-');
    adapter = Adapter((request) {
      if (unavailable) return body('temporarily unavailable', 503);
      if (request.uri.host == 'z.qiqiv.cn') {
        return body(
          '{"urls":[{"name":"仓一","url":"https://source.test/one"},{"name":"仓二","url":"https://source.test/two"}]}',
        );
      }
      return body(
        '{"sites":[{"key":"${request.uri.path}","api":"csp_Fixture"}]}',
      );
    });
    final client = AppHttpClient(adapter: adapter);
    engine = TestEngine(client);
    controller = AppController(
      store: AppStore(path: directory.path, secretStorage: MemorySecrets()),
      http: client,
      engine: engine,
    );
    await controller.initialize();
  });
  tearDown(() async {
    await controller.disposeAsync();
    await directory.delete(recursive: true);
  });

  test('首次自动展开全部子仓，保存成功后再次启动不重复获取', () async {
    await controller.startHome();
    expect(adapter.requests.map((r) => r.uri.toString()), [
      defaultSubscription,
      'https://source.test/one',
      'https://source.test/two',
    ]);
    expect(controller.configs, hasLength(2));
    expect(
      controller.subscriptionName(defaultSubscription),
      defaultSubscriptionName,
    );
    expect(controller.store.setting('builtInSetupComplete'), true);
    expect(controller.loadingBuiltIn, false);
    expect(controller.builtInError, isNull);
    expect(engine.homeRequests, [('https://source.test/one', '/one')]);
    await controller.startHome();
    expect(adapter.requests, hasLength(3));
  });

  test('首次失败可重试，不提前标记完成', () async {
    unavailable = true;
    await controller.startHome();
    expect(controller.builtInError, isNotNull);
    expect(controller.store.setting('builtInSetupComplete'), isNot(true));
    unavailable = false;
    await controller.loadBuiltInSubscription();
    expect(controller.configs, hasLength(2));
    expect(controller.builtInError, isNull);
    expect(controller.store.setting('builtInSetupComplete'), true);
  });

  test('后台更新失败保留旧仓、当前页面且不写入导入日志', () async {
    await controller.startHome();
    final page = controller.homePage;
    final config = controller.currentConfig;
    await controller.store.setSetting(
      'builtInUpdatedAt',
      '2000-01-01T00:00:00',
    );
    unavailable = true;
    await controller.loadBuiltInSubscription();
    expect(controller.configs, hasLength(2));
    expect(identical(controller.currentConfig, config), isTrue);
    expect(identical(controller.homePage, page), isTrue);
    expect(controller.importing, isFalse);
    expect(controller.importNodes, isEmpty);
    expect(controller.importError, isNull);
    expect(controller.error, isNull);
  });

  test('到期静默更新不切换用户当前源', () async {
    await controller.startHome();
    await controller.selectConfig(controller.configs.last);
    final page = controller.homePage;
    await controller.store.setSetting(
      'builtInUpdatedAt',
      '2000-01-01T00:00:00',
    );
    await controller.loadBuiltInSubscription();
    expect(adapter.requests, hasLength(6));
    expect(controller.currentConfig!.url, 'https://source.test/two');
    expect(identical(controller.homePage, page), isTrue);
    expect(controller.importNodes, isEmpty);
    expect(controller.importError, isNull);
  });

  test('清理旧订阅保留内置仓、收藏和历史，主动删除内置仓后不自动恢复', () async {
    await controller.startHome();
    await controller.importSubscriptions([
      'https://source.test/old-a',
      'https://source.test/old-b',
    ], addOnly: true);
    final vod = Vod({'vod_id': 'saved', 'vod_name': '收藏影片'});
    await controller.toggleFavorite(vod);
    await controller.recordProgress(
      vod,
      const PlayLine(name: '线路', episodes: []),
      const Episode(name: '1', id: 'episode'),
      const Duration(seconds: 8),
      const Duration(minutes: 2),
    );
    final before = controller.homePage;
    await controller.removeSubscriptions([
      'https://source.test/old-a',
      'https://source.test/old-b',
    ]);
    expect(controller.subscriptions.single.url, defaultSubscription);
    expect(controller.store.favorites, hasLength(1));
    expect(controller.store.history, hasLength(1));
    expect(identical(controller.homePage, before), true);
    await controller.removeSubscription(defaultSubscription);
    await controller.startHome();
    expect(controller.subscriptions, isEmpty);
    expect(controller.currentConfig, isNull);
  });
}
