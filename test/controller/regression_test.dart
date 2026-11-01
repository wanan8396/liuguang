import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:tvbox/core/app_controller.dart';
import 'package:tvbox/core/engine/source_engine.dart';
import 'package:tvbox/core/network/app_http_client.dart';
import 'package:tvbox/core/storage/app_store.dart';

class _Secrets implements SecretStorage {
  final data = <String, String>{};
  @override
  Future<String?> read(String key) async => data[key];
  @override
  Future<void> write(String key, String value) async { data[key] = value; }
}

class _Http extends AppHttpClient {
  final responses = <String, Future<FetchResult>>{};
  @override
  Future<FetchResult> fetch(String url, {Map<String, String> headers = const {}}) async {
    final response = responses[url];
    if (response == null) throw AppHttpException('test-missing', 'No fixture', url: url);
    return response;
  }
}

FetchResult _response(String url, String text) => FetchResult(
  bytes: Uint8List.fromList(utf8.encode(text)), finalUrl: url, statusCode: 200, headers: const {});

class _Engine extends SourceEngine {
  _Engine(super.http);
  @override
  Future<VodPage> home(TvConfig config, Site site) async => VodPage();
  @override
  Future<String> fetchLocal(TvConfig config, Site site, String url) async =>
    throw const SourceFailure('proxy-failure', 'fixture proxy unavailable');
  @override
  Future<void> closeSessions() async {}
  @override
  Future<void> dispose() async {}
}

void main() {
  late Directory temp;
  late AppStore store;
  late _Http http;
  late AppController controller;
  final original = TvConfig(url: 'https://test.invalid/config', name: '旧仓', raw: {
    'sites': [{'key': 'a', 'name': '测试', 'api': 'csp_Fixture', 'type': 3}],
  });
  setUp(() async {
    temp = await Directory.systemTemp.createTemp('liuguang-regression-');
    store = AppStore(path: temp.path, secretStorage: _Secrets());
    await store.init();
    await store.saveSubscription(ImportResult(url: original.url, nodes: [
      RepoNode(url: original.url, name: original.name, config: original, status: 'ready'),
    ]));
    http = _Http();
    controller = AppController(store: store, http: http, engine: _Engine(http));
    await controller.initialize();
  });
  tearDown(() async {
    await controller.disposeAsync();
    await temp.delete(recursive: true);
  });

  test('取消刷新不保存迟到响应，不删除旧仓', () async {
    final pending = Completer<FetchResult>();
    http.responses[original.url] = pending.future;
    final importing = controller.importSubscription(original.url);
    await Future<void>.delayed(Duration.zero);
    controller.cancelImport();
    pending.complete(_response(original.url, '{"sites":[]}'));
    await importing;
    expect(store.subscriptions.single.configs.single.sites.single.key, 'a');
    expect(controller.importing, isFalse);
  });

  test('单个直播代理失败不影响其他频道与独立直播订阅', () async {
    controller.currentConfig = TvConfig(url: original.url, name: original.name, raw: {
      ...original.raw,
      'lives': [
        {'name': '坏代理', 'url': 'http://127.0.0.1:5266/iptv.m3u'},
        {'name': '直接列表', 'url': 'https://test.invalid/live.m3u'},
      ],
    });
    http.responses['https://test.invalid/live.m3u'] = Future.value(
      _response('https://test.invalid/live.m3u', '#EXTM3U\n#EXTINF:-1,频道甲\nhttps://media.invalid/a.m3u8'));
    http.responses['https://test.invalid/extra.txt'] = Future.value(
      _response('https://test.invalid/extra.txt', '频道乙,https://media.invalid/b.m3u8'));
    await store.setSetting('liveSubscriptions', ['https://test.invalid/extra.txt']);
    await controller.loadLive();
    expect(controller.liveChannels.map((channel) => channel.name), ['频道甲', '频道乙']);
    expect(controller.error, contains('proxy'));
  });

  test('撤销信任在第一处await之前立即生效', () async {
    await controller.trustPlugins(true);
    expect(controller.isConfigTrusted(original), isTrue);
    final revoke = controller.trustPlugins(false);
    expect(controller.isConfigTrusted(original), isFalse);
    await revoke;
    expect(controller.pluginsTrusted, isFalse);
  });
}
