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

  setUp(() async {
    directory = await Directory.systemTemp.createTemp('subscription-append-');
    adapter = Adapter(
      (o) => body(
        o.uri.host == 'live.test'
            ? '频道,http://media.test/a.m3u8'
            : '{"sites":[{"key":"${o.uri.path}","api":"csp_Fixture"}]}',
      ),
    );
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

  test('追加第二个地址保留首个订阅、当前源和首页；重复地址不重新请求', () async {
    await controller.importSubscriptions([
      'https://repo.test/a',
    ], addOnly: true);
    final originalHome = controller.homePage;
    final original = controller.currentConfig;
    await controller.importSubscriptions([
      'https://repo.test/a',
      'https://repo.test/b',
    ], addOnly: true);
    expect(controller.subscriptions.map((s) => s.url), [
      'https://repo.test/a',
      'https://repo.test/b',
    ]);
    expect(controller.importQueue.map((i) => i.status), ['existing', 'ready']);
    expect(adapter.requests, hasLength(2));
    expect(controller.currentConfig?.url, original?.url);
    expect(identical(controller.homePage, originalHome), true);
    await controller.importSubscription('https://repo.test/a');
    expect(adapter.requests, hasLength(3));
    expect(controller.subscriptions, hasLength(2));
  });

  test('已导入的发现线路立即使用保存名称，更新后仍保留且可重命名', () async {
    const url = 'https://repo.test/a';
    await controller.importSubscriptions([url], addOnly: true);
    await controller.renameSubscription(url, '嗷呜');
    expect(controller.configName(controller.currentConfig), '嗷呜');
    await controller.importSubscription(url);
    expect(controller.configName(controller.configs.single), '嗷呜');
    await controller.renameSubscription(url, '我的影视仓');
    expect(controller.configName(controller.currentConfig), '我的影视仓');
    final child = TvConfig(
      url: 'https://repo.test/child',
      name: '子仓名称',
      raw: {},
    );
    expect(controller.configName(child), '子仓名称');
  });

  test('两次本地或发现配置使用独立身份，同一内容重复添加不重复存储', () async {
    const first = '{"sites":[{"key":"a","api":"csp_A"}]}';
    const second = '{"sites":[{"key":"b","api":"csp_B"}]}';
    await controller.importText(first, name: '第一次发现');
    final home = controller.homePage;
    final originalUrl = controller.currentConfig!.url;
    await controller.importText(second, name: '第二次发现');
    expect(controller.subscriptions, hasLength(2));
    expect(controller.configs.map((c) => c.sites.single.key), ['a', 'b']);
    expect(controller.currentConfig!.url, originalUrl);
    expect(identical(controller.homePage, home), true);
    await controller.importText(second, name: '第二次发现');
    expect(controller.subscriptions, hasLength(2));
  });

  test('直播批量追加只刷新一次，已有地址去重保留', () async {
    await controller.store.setSetting('liveSubscriptions', [
      'https://live.test/a',
    ]);
    expect(
      await controller.addLiveSubscriptions([
        'https://live.test/a',
        'https://live.test/b',
        'https://live.test/c',
      ]),
      2,
    );
    expect(controller.store.setting('liveSubscriptions'), [
      'https://live.test/a',
      'https://live.test/b',
      'https://live.test/c',
    ]);
    expect(adapter.requests, hasLength(3));
    expect(await controller.addLiveSubscriptions(['https://live.test/b']), 0);
    expect(adapter.requests, hasLength(3));
  });
}
