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
  final homeRequests = <(String, String)>[];
  VodPage? homeResult;
  final categoryRequests = <String>[];
  final categoryResults = <String, VodPage>{};
  final categoryErrors = <String, Object>{};
  Object? homeError;
  int closeCount = 0;
  @override
  Future<VodPage> home(TvConfig config, Site site) async {
    homeRequests.add((config.url, site.key));
    if (homeError != null) throw homeError!;
    if (homeResult != null) return homeResult!;
    return homes[site.key]?.future ??
        Future.value(
          VodPage(
            items: [
              Vod({'vod_id': site.key, 'vod_name': site.name}),
            ],
          ),
        );
  }

  @override
  Future<VodPage> category(
    TvConfig config,
    Site site,
    String tid, {
    int page = 1,
    Map<String, dynamic> filters = const {},
  }) async {
    categoryRequests.add(tid);
    if (categoryErrors.containsKey(tid)) throw categoryErrors[tid]!;
    return categoryResults[tid] ?? VodPage();
  }

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

  test('导入成功后的插件错误不会污染订阅诊断', () async {
    engine.homeError = const SourceFailure('plugin', 'Fixture plugin failed');
    await controller.importText(
      '{"sites":[{"key":"fixture","api":"csp_Fixture"}]}',
    );
    expect(controller.importNodes.single.status, 'ready');
    expect(controller.importError, isNull);
    expect(controller.currentConfig?.url, config.url);
    await controller.selectConfig(controller.subscriptions.last.configs.single);
    expect(controller.error, contains('Fixture plugin failed'));
    expect(controller.subscriptions, hasLength(2));
  });

  test('导入失败显示独立诊断，下次成功导入清除诊断', () async {
    await store.removeSubscription(config.url);
    await controller.importText('invalid configuration');
    expect(controller.importNodes.single.status, 'error');
    expect(controller.importError, contains('没有可加载'));
    await controller.importText(
      '{"sites":[{"key":"fixture","api":"csp_Fixture"}]}',
    );
    expect(controller.importNodes.single.status, 'ready');
    expect(controller.importError, isNull);
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

  test('空首页自动加载首个有资源分类，同时保留分类导航和筛选', () async {
    engine.homeResult = VodPage(
      categories: [
        Category(id: 'empty', name: '空分类'),
        Category(id: 'movie', name: '电影'),
      ],
      filters: {
        'movie': ['filter'],
      },
    );
    engine.categoryResults['movie'] = VodPage(
      items: [
        Vod({'vod_id': 'film'}),
      ],
    );
    await controller.refreshHome();
    expect(engine.categoryRequests, ['empty', 'movie']);
    expect(controller.homeCategory, 'movie');
    expect(controller.homePage?.categories, hasLength(2));
    expect(controller.homePage?.filters['movie'], ['filter']);
    expect(controller.currentPage?.items.single.id, 'film');
    expect(controller.error, isNull);
  });

  test('分类网络失败显示真实错误，已有首页不额外请求分类', () async {
    await controller.refreshHome();
    expect(engine.categoryRequests, isEmpty);
    engine.homeResult = VodPage(
      categories: [Category(id: 'movie', name: '电影')],
    );
    engine.categoryErrors['movie'] = const SourceFailure('network', 'HTTP 403');
    await controller.refreshHome();
    expect(controller.error, contains('HTTP 403'));
    expect(controller.homePage?.categories, hasLength(1));
  });

  test('跨仓库直接选择目标源，慢请求完成后仓库、站点和存储仍匹配', () async {
    final other = TvConfig(
      url: 'https://other.test/config',
      name: '另一仓库',
      raw: {
        'sites': [
          {'key': 'default', 'api': 'csp_Default'},
          {'key': 'target', 'api': 'csp_Target'},
        ],
      },
    );
    engine.homes['a'] = Completer<VodPage>();
    final old = controller.selectSource(config, config.sites.first);
    while (engine.homeRequests.isEmpty) {
      await Future<void>.delayed(Duration.zero);
    }
    await controller.selectSource(other, other.sites.last);
    engine.homes['a']!.complete(
      VodPage(
        items: [
          Vod({'vod_id': 'old'}),
        ],
      ),
    );
    await old;
    expect(engine.homeRequests, [(config.url, 'a'), (other.url, 'target')]);
    expect(controller.currentConfig?.url, other.url);
    expect(controller.currentSite?.key, 'target');
    expect(controller.homePage?.items.single.id, 'target');
    expect(store.setting('currentConfig'), other.url);
    expect(store.setting('currentSite'), 'target');
    expect(store.setting('site:${config.url}'), 'a');
    expect(store.setting('site:${other.url}'), 'target');
  });

  test('存储尚未完成时连续切仓，只加载最后一次选择且拒绝错配站点', () async {
    final other = TvConfig(
      url: 'https://other.test/config',
      name: 'other',
      raw: {
        'sites': [
          {'key': 'target', 'api': 'csp_Target'},
        ],
      },
    );
    await Future.wait([
      controller.selectSource(config, config.sites.first),
      controller.selectSource(other, other.sites.first),
    ]);
    expect(engine.homeRequests, [(other.url, 'target')]);
    await expectLater(
      controller.selectSource(other, config.sites.first),
      throwsA(
        isA<SourceFailure>().having((e) => e.code, 'code', 'site-mismatch'),
      ),
    );
    expect(controller.currentConfig?.url, other.url);
    expect(controller.currentSite?.key, 'target');
    expect(store.setting('currentConfig'), other.url);
    expect(store.setting('currentSite'), 'target');
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
