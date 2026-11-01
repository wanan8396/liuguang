import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:tvbox/core/app_controller.dart';
import 'package:tvbox/core/engine/source_engine.dart';
import 'package:tvbox/core/live/live_repository.dart';
import 'package:tvbox/core/network/app_http_client.dart';
import 'package:tvbox/core/storage/app_store.dart';

class _Http extends AppHttpClient {
  final requests = <String>[];
  final requestHeaders = <Map<String, String>>[];
  Future<FetchResult> Function(String)? handler;
  @override
  Future<FetchResult> fetch(
    String url, {
    Map<String, String> headers = const {},
  }) async {
    requests.add(url);
    requestHeaders.add(Map.of(headers));
    if (handler == null) throw StateError('Unexpected request: $url');
    return handler!(url);
  }
}

FetchResult _text(String url, String text) => FetchResult(
  bytes: Uint8List.fromList(utf8.encode(text)),
  finalUrl: url,
  statusCode: 200,
  headers: const {},
);

class _Secrets implements SecretStorage {
  final values = <String, String>{};
  @override
  Future<String?> read(String key) async => values[key];
  @override
  Future<void> write(String key, String value) async {
    values[key] = value;
  }
}

class _Engine extends SourceEngine {
  _Engine(super.http);
  @override
  Future<void> closeSessions() async {}
  @override
  Future<void> dispose() async {}
  @override
  Future<String> fetchLocal(TvConfig config, Site site, String url) async =>
      '动态频道,https://media.invalid/dynamic.m3u8';
}

void main() {
  late _Http http;
  late LiveRepository repository;
  setUp(() {
    http = _Http();
    repository = LiveRepository(http);
  });
  tearDown(() => http.close());

  test(
    '15 groups, direct before proxy, selection is optional and deduplicated',
    () {
      expect(liveHelperSources, hasLength(15));
      expect(liveHelperSources.map((s) => s.id).toSet(), hasLength(15));
      for (final source in liveHelperSources) {
        expect(source.urls.first, isNot(contains('gh-proxy.com')));
        expect(source.urls.toSet().length, source.urls.length);
        if (source.hasProxy) expect(source.description, contains('第三方'));
      }
      expect(liveHelperSelection([]), isEmpty);
      expect(liveHelperSelection(['source-12', 'missing', 'source-12']), [
        'source-12',
      ]);
    },
  );

  test('failed and empty candidates fall through to first valid TXT, no media request', () async {
    const source = LiveHelperSource(
      id: 'fixture',
      name: '测试',
      urls: [
        'https://list.invalid/fail',
        'https://list.invalid/empty',
        'https://list.invalid/good',
        'https://list.invalid/unused',
      ],
    );
    http.handler = (url) async {
      if (url.endsWith('fail')) {
        throw const AppHttpException('network', 'offline');
      }
      if (url.endsWith('empty')) return _text(url, '#EXTM3U\n');
      return _text(
        url,
        '\ufeff央视频道,#genre#\nCCTV1,https://media.invalid/one.m3u8',
      );
    };
    final result = await repository.loadHelperSource(source);
    expect(result.single.name, 'CCTV1');
    expect(result.single.group, '央视频道');
    expect(result.single.headers['User-Agent'], 'okhttp/4.12.0');
    expect(http.requests, source.urls.take(3).toList());
    expect(http.requestHeaders.every((h) => h['Accept'] == '*/*'), isTrue);
    expect(
      http.requestHeaders.every((h) => !h.containsKey('Accept-Encoding')),
      isTrue,
    );
  });

  test('M3U metadata and relative URL parsing reuse repository', () async {
    final source = liveHelperSources.first;
    http.handler = (url) async => _text(
      url,
      '#EXTM3U\n#EXTINF:-1 tvg-id="one" group-title="央视",一台\n./one.m3u8\n',
    );
    final result = await repository.loadHelperSource(source);
    expect(result.single.tvgId, 'one');
    expect(result.single.group, '央视');
    expect(
      result.single.urls.single,
      Uri.parse(source.urls.first).resolve('./one.m3u8').toString(),
    );
    expect(http.requests, [source.urls.first]);
    expect(repository.mergeChannels([...result, ...result]), hasLength(1));
  });

  test(
    'concurrent group loads share work; all failures permit later retry',
    () async {
      final source = liveHelperSources.last;
      final pending = Completer<FetchResult>();
      http.handler = (_) => pending.future;
      final first = repository.loadHelperSource(source);
      final second = repository.loadHelperSource(source);
      expect(identical(first, second), isTrue);
      pending.complete(_text(source.urls.first, ''));
      await expectLater(first, throwsA(isA<LiveException>()));
      http.handler = (url) async =>
          _text(url, '重试,https://media.invalid/retry');
      expect(await repository.loadHelperSource(source), hasLength(1));
      expect(http.requests, hasLength(2));
    },
  );

  group('controller persistence without changing the store', () {
    late Directory temp;
    late AppStore store;
    late AppController controller;
    setUp(() async {
      temp = await Directory.systemTemp.createTemp('live-helper-test-');
      store = AppStore(path: temp.path, secretStorage: _Secrets());
      await store.init();
      controller = AppController(
        store: store,
        http: http,
        engine: _Engine(http),
      );
    });
    tearDown(() async {
      await controller.disposeAsync();
      await temp.delete(recursive: true);
    });

    test('no config and no selection make no requests; helper works without config', () async {
      await controller.loadLive();
      expect(http.requests, isEmpty);
      http.handler = (url) async => _text(url, '频道,https://media.invalid/one');
      await controller.setLiveHelperSources([
        'source-12',
        'source-12',
        'unknown',
      ]);
      expect(controller.currentConfig, isNull);
      expect(controller.liveChannels, hasLength(1));
      expect(store.setting(liveHelperSettingKey), ['source-12']);
      await controller.setLiveHelperSources(['source-12']);
      expect(http.requests, hasLength(1));
    });

    test(
      'subscriptions survive selection; repeated imports do not load again',
      () async {
        http.handler = (url) async =>
            _text(url, '频道,https://media.invalid/one');
        await controller.addLiveSubscription(' https://user.invalid/list ');
        await controller.addLiveSubscription('https://user.invalid/list');
        expect(http.requests, hasLength(1));
        await controller.setLiveHelperSources(['source-12']);
        expect(store.setting('liveSubscriptions'), [
          'https://user.invalid/list',
        ]);
        expect(
          controller.liveChannels,
          hasLength(2),
        ); // Different request headers stay isolated.
        await controller.setLiveHelperSources([]);
        expect(controller.liveChannels, hasLength(1));
        expect(store.setting('liveSubscriptions'), [
          'https://user.invalid/list',
        ]);
      },
    );

    test('concurrent controller refreshes share requests', () async {
      await store.setSetting('liveSubscriptions', [
        'https://user.invalid/list',
      ]);
      final pending = Completer<FetchResult>();
      http.handler = (_) => pending.future;
      final first = controller.loadLive();
      final second = controller.loadLive();
      expect(identical(first, second), isTrue);
      pending.complete(
        _text('https://user.invalid/list', '频道,https://media.invalid/one'),
      );
      await Future.wait([first, second]);
      expect(http.requests, hasLength(1));
    });

    test(
      'changed subscriptions start new load and stale completion cannot win',
      () async {
        final old = Completer<FetchResult>();
        http.handler = (url) => url.contains('old')
            ? old.future
            : Future.value(_text(url, '新频道,https://media.invalid/new'));
        await store.setSetting('liveSubscriptions', [
          'https://old.invalid/list',
        ]);
        final first = controller.loadLive();
        await store.setSetting('liveSubscriptions', [
          'https://new.invalid/list',
        ]);
        await controller.loadLive();
        expect(controller.liveChannels.single.name, '新频道');
        old.complete(
          _text('https://old.invalid/list', '旧频道,https://media.invalid/old'),
        );
        await first;
        expect(controller.liveChannels.single.name, '新频道');
        expect(http.requests, hasLength(2));
      },
    );
    test(
      'saved dynamic TVBox lives still use localFetcher alongside helper',
      () async {
        final config = TvConfig(
          url: 'https://config.invalid/tvbox',
          name: '动态',
          raw: {
            'sites': [
              {'key': 'a', 'name': '插件', 'api': 'csp_Test', 'type': 3},
            ],
            'lives': [
              {'name': '动态直播', 'url': 'http://127.0.0.1:9978/live'},
            ],
          },
        );
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
        controller.currentConfig = store.subscriptions.first.nodes.first.config;
        controller.currentSite = config.sites.first;
        http.handler = (url) async =>
            _text(url, '助手频道,https://media.invalid/helper');
        await controller.setLiveHelperSources(['source-12']);
        expect(
          controller.liveChannels.map((c) => c.name),
          containsAll(['动态频道', '助手频道']),
        );
        expect(http.requests, [liveHelperSources[11].urls.first]);
      },
    );
  });
}
