import 'dart:async';
import 'dart:convert';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:tvbox/core/engine/source_engine.dart';
import 'package:tvbox/core/engine/source_engine_api.g.dart';
import 'package:tvbox/core/models/models.dart';
import 'package:tvbox/core/network/app_http_client.dart';

class TestNativeApi extends SourceEngineApi {
  int opened = 0;
  int closed = 0;
  int cancelled = 0;
  int resolved = 0;
  Map<String, dynamic>? resolutionInput;
  String result = jsonEncode({
    'url': 'https://media.invalid/video.m3u8',
    'parse': 0,
    'header': {'Referer': 'https://origin.invalid/'},
  });
  bool failHome = false;

  @override
  Future<String> openSession(String configJson, String siteJson) async {
    opened++;
    expect(jsonDecode(configJson)['url'], 'https://repo.invalid/config');
    return 'session-$opened';
  }

  @override
  Future<String> home(String sessionId, bool filter) async {
    if (failHome) {
      throw PlatformException(code: 'plugin-failed', message: '插件异常');
    }
    return '{"class":[{"type_id":"1","type_name":"电影"}],"list":[]}';
  }

  @override
  Future<String> search(String sessionId, String keyword, int page) async =>
      jsonEncode({
        'list': [
          {'vod_id': keyword, 'vod_name': keyword},
        ],
        'page': page,
      });
  @override
  Future<String> detail(String sessionId, String id) async => jsonEncode({
    'list': [
      {
        'vod_id': id,
        'vod_name': '详情',
        'vod_play_from': '线路',
        'vod_play_url': r'正片$https://media.invalid/video.m3u8',
      },
    ],
  });
  @override
  Future<String> play(String sessionId, String flag, String id) async => result;
  @override
  Future<String> resolve(
    String sessionId,
    String resultJson,
    String parserJson,
  ) async {
    resolved++;
    resolutionInput = jsonDecode(resultJson) as Map<String, dynamic>;
    return '{"url":"https://media.invalid/resolved.m3u8","parse":0,"header":{"Cookie":"session=test"}}';
  }

  @override
  Future<void> cancel(String sessionId) async {
    cancelled++;
  }

  @override
  Future<void> closeSession(String sessionId) async {
    closed++;
  }
}

void main() {
  late AppHttpClient http;
  late TestNativeApi native;
  late SourceEngine engine;
  final config = TvConfig(
    url: 'https://repo.invalid/config',
    name: 'fixture',
    raw: {'spider': 'https://repo.invalid/plugin.jar'},
  );
  final site = Site({'key': 'fixture', 'api': 'csp_Fixture', 'type': 3});

  setUp(() {
    http = AppHttpClient();
    native = TestNativeApi();
    engine = SourceEngine(http, native: native, isAndroid: true);
  });
  tearDown(() async {
    await engine.dispose();
    http.close();
  });

  test('取消等待凭据的初始化不会执行插件', () async {
    final credentials = Completer<Map<String, String>>();
    engine.loadCredentials = (_) => credentials.future;
    final pending = engine.home(config, site);
    final assertion = expectLater(
      pending,
      throwsA(isA<SourceFailure>().having((e) => e.code, 'code', 'cancelled')),
    );
    final cancellation = engine.cancel();
    credentials.complete({});
    await assertion;
    await cancellation;
    expect(native.opened, 0);
  });
  test('多清晰度URL数组从主程序传给原生解析，不把数组误当网址', () async {
    final urls = [
      '1080P',
      'https://media.invalid/1080.mp4',
      '720P',
      'https://media.invalid/720.mp4',
    ];
    native.result = jsonEncode({'url': urls, 'parse': 0});
    final playback = await engine.play(config, site, 'line', 'episode');
    expect(native.resolved, 1);
    expect(native.resolutionInput!['url'], urls);
    expect(playback.url, 'https://media.invalid/resolved.m3u8');
  });

  test('等待凭据时关闭会话不能继续打开插件', () async {
    final credentials = Completer<Map<String, String>>();
    engine.loadCredentials = (_) => credentials.future;
    final pending = engine.home(config, site);
    final assertion = expectLater(pending, throwsA(isA<SourceFailure>()));
    final closing = engine.closeSessions();
    credentials.complete({});
    await assertion;
    await closing;
    expect(native.opened, 0);
  });

  test('UDP及无扩展名直播不依赖点播插件', () async {
    for (final url in [
      'udp://239.1.2.3:1234',
      'rtp://239.1.2.4:1234',
      'http://media.invalid/udp/channel',
    ]) {
      final playback = await engine.playLive(
        null,
        null,
        LiveChannel(name: '频道', urls: [url], headers: {'User-Agent': 'test'}),
      );
      expect(playback.url, url);
      expect(playback.headers['User-Agent'], 'test');
    }
    expect(native.opened, 0);
  });

  test('JAR 和 JS 插件默认自动加载，无需手动信任', () async {
    for (final api in ['csp_Fixture', 'https://repo.invalid/rule.js']) {
      final automatic = Site({'key': api, 'api': api, 'type': 3});
      final page = await engine.home(config, automatic);
      expect(page.categories.single.name, '电影');
    }
    expect(native.opened, 2);
  });

  test('配置更新后自动打开新的插件会话', () async {
    await engine.home(config, site);
    final updated = TvConfig(
      url: config.url,
      name: config.name,
      raw: {'spider': 'https://repo.invalid/updated.jar'},
    );
    await engine.home(updated, site);
    expect(native.opened, 2);
  });

  test('并发调用共享同一初始化而不是多次加载插件', () async {
    final pages = await Future.wait([
      engine.home(config, site),
      engine.home(config, site),
    ]);
    expect(native.opened, 1);
    expect(pages.first.categories.single.name, '电影');
    expect(pages.first.items, isEmpty);
  });

  test('搜索详情播放传递真实结构及请求头', () async {
    final search = await engine.search(config, site, '测试');
    final detail = await engine.detail(config, site, search.items.single.id);
    final playback = await engine.play(
      config,
      site,
      detail.lines.single.name,
      detail.lines.single.episodes.single.id,
    );
    expect(search.items.single.name, '测试');
    expect(detail.lines.single.episodes.single.name, '正片');
    expect(
      jsonMap(native.resolutionInput?['header'])['Referer'],
      'https://origin.invalid/',
    );
    expect(playback.headers['Cookie'], 'session=test');
    expect(native.resolved, 1);
    expect(playback.url, 'https://media.invalid/resolved.m3u8');
  });

  test('页面结果经过原生解析而不是直接送播放器', () async {
    native.result = '{"url":"https://page.invalid/watch/1","parse":1}';
    final playback = await engine.play(config, site, 'line', 'id');
    expect(native.resolved, 1);
    expect(playback.url, 'https://media.invalid/resolved.m3u8');
    expect(playback.headers['Cookie'], 'session=test');
  });

  test('原生插件异常不能伪装成空列表成功', () async {
    native.failHome = true;
    await expectLater(
      engine.home(config, site),
      throwsA(
        isA<SourceFailure>().having(
          (failure) => failure.code,
          'code',
          'plugin-failed',
        ),
      ),
    );
  });

  test('取消与关闭会通知原生会话', () async {
    await engine.home(config, site);
    await engine.cancel();
    await engine.closeSessions();
    expect(native.cancelled, 1);
    expect(native.closed, 1);
  });

  test('空播放地址和危险本地协议被拒绝', () async {
    native.result = '{"url":"","parse":0}';
    await expectLater(
      engine.play(config, site, 'line', 'id'),
      throwsA(isA<SourceFailure>()),
    );
    native.result = '{"url":"file:///data/private","parse":0}';
    await expectLater(
      engine.play(config, site, 'line', 'id'),
      throwsA(
        isA<SourceFailure>().having(
          (failure) => failure.code,
          'code',
          'invalid-playback',
        ),
      ),
    );
  });

  test('XML CMS 支持分页、分类和多线路', () {
    final page = VodPage.fromJson(
      parseCmsXml('''<?xml version="1.0"?><rss>
<class><ty id="1">电影</ty></class><list page="2" pagecount="3" recordcount="6">
<video><id>7</id><name>测试片</name><pic>https://img.invalid/1.jpg</pic><note>正片</note>
<dl><dd flag="lineA"><![CDATA[正片\$https://media.invalid/1.m3u8]]></dd>
<dd flag="lineB"><![CDATA[正片\$https://media.invalid/1.mp4]]></dd></dl></video>
</list></rss>'''),
    );
    expect(page.page, 2);
    expect(page.pageCount, 3);
    expect(page.categories.single.name, '电影');
    expect(VodDetail.fromVod(page.items.single).lines.length, 2);
  });
}
