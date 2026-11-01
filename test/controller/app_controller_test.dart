import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:tvbox/core/app_controller.dart';
import 'package:tvbox/core/engine/source_engine.dart';
import 'package:tvbox/core/network/app_http_client.dart';
import 'package:tvbox/core/storage/app_store.dart';

class MemorySecrets implements SecretStorage {
  final values = <String, String>{};
  @override
  Future<String?> read(String key) async => values[key];
  @override
  Future<void> write(String key, String value) async {
    values[key] = value;
  }
}

class TestEngine extends SourceEngine {
  TestEngine(super.http);
  final homes = <String, Completer<VodPage>>{};
  int closeCount = 0;
  @override
  Future<VodPage> home(TvConfig config, Site site) async =>
      homes[site.key]?.future ??
      Future.value(
        VodPage(
          items: [
            Vod({'vod_id': site.key, 'vod_name': site.name}),
          ],
        ),
      );
  @override
  Future<void> closeSessions() async {
    closeCount++;
  }

  @override
  Future<void> dispose() async {
    await closeSessions();
  }
}

void main() {
  late Directory directory;
  late AppStore store;
  late AppHttpClient http;
  late TestEngine engine;
  late AppController controller;
  late MemorySecrets secrets;
  final config = TvConfig(
    url: 'https://repo.invalid/config',
    name: 'test',
    raw: {
      'spider': 'https://repo.invalid/fixture.jar',
      'sites': [
        {'key': 'a', 'name': 'A', 'api': 'csp_A', 'type': 3},
        {'key': 'b', 'name': 'B', 'api': 'csp_B', 'type': 3},
      ],
    },
  );

  setUp(() async {
    directory = await Directory.systemTemp.createTemp('liuguang-controller-');
    secrets = MemorySecrets();
    store = AppStore(path: directory.path, secretStorage: secrets);
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
    http = AppHttpClient();
    engine = TestEngine(http);
    controller = AppController(store: store, http: http, engine: engine);
    await controller.initialize();
  });
  tearDown(() async {
    await controller.disposeAsync();
    await directory.delete(recursive: true);
  });

  test('首次加载不暗中执行源，选源后才取得首页', () async {
    expect(controller.currentConfig?.url, config.url);
    expect(controller.homePage, isNull);
    await controller.refreshHome();
    expect(controller.homePage?.items.single.name, 'A');
  });

  test('慢的旧源结果不能覆盖较快的新源', () async {
    engine.homes['a'] = Completer<VodPage>();
    final old = controller.selectSite(config.sites.first);
    await Future<void>.delayed(Duration.zero);
    await controller.selectSite(config.sites.last);
    engine.homes['a']!.complete(
      VodPage(
        items: [
          Vod({'vod_id': 'old', 'vod_name': '旧结果'}),
        ],
      ),
    );
    await old;
    expect(controller.currentSite?.key, 'b');
    expect(controller.homePage?.items.single.name, 'B');
  });

  test('站点启停与排序持久化且停用当前源自动换源', () async {
    await controller.reorderSites(['b', 'a']);
    expect(controller.enabledSites().map((site) => site.key), ['b', 'a']);
    await controller.setSiteEnabled(config.sites.first, false);
    expect(controller.currentSite?.key, 'b');
    expect(controller.enabledSites().map((site) => site.key), ['b']);
    await controller.setSiteEnabled(config.sites.last, false);
    expect(controller.currentSite, isNull);
    expect(controller.enabledSites(), isEmpty);
    expect(controller.error, contains('停用'));
  });

  test('插件信任绑定内容而不是所有仓库永久授权', () async {
    expect(controller.pluginsTrusted, isFalse);
    await controller.trustPlugins(true);
    expect(controller.isConfigTrusted(config), isTrue);
    final changed = TvConfig(
      url: config.url,
      name: config.name,
      raw: {...config.raw, 'spider': 'https://repo.invalid/changed.jar'},
    );
    expect(controller.isConfigTrusted(changed), isFalse);
    await controller.trustPlugins(false);
    expect(controller.isConfigTrusted(config), isFalse);
  });

  test('凭据仅安全存储不导出，更新清理已有会话', () async {
    await controller.saveCredential('quark_cookie.txt', 'secret-value-123');
    expect(await controller.credentialNames(), ['quark_cookie.txt']);
    expect(await store.exportBackup(), isNot(contains('secret-value-123')));
    expect(secrets.values.values.join(), contains('secret-value-123'));
    expect(engine.closeCount, 1);
    await controller.saveCredential('quark_cookie.txt', '');
    expect(await controller.credentialNames(), isEmpty);
    await expectLater(
      controller.saveCredential('../private', 'x'),
      throwsA(isA<FormatException>()),
    );
  });

  test('播放历史精确保存所属源与位置', () async {
    final vod = Vod({'vod_id': 'film', 'vod_name': '节目'});
    const episode = Episode(name: '第2集', id: 'episode-2');
    const line = PlayLine(name: '线路A', episodes: [episode]);
    await controller.recordProgress(
      vod,
      line,
      episode,
      const Duration(seconds: 60),
      const Duration(minutes: 30),
    );
    expect(store.history.single.positionMs, 60000);
    expect(store.history.single.configUrl, config.url);
    expect(store.history.single.siteKey, 'a');
    expect(store.history.single.episodeId, 'episode-2');
    await controller.toggleFavorite(vod);
    expect(controller.isFavorite(vod), isTrue);
  });

  test('主题设置可持久化', () async {
    await controller.setThemeMode(ThemeMode.dark);
    expect(controller.themeMode, ThemeMode.dark);
    expect(store.setting('themeMode'), 'dark');
  });
}
