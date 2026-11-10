import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:tvbox/core/live/live_repository.dart';
import 'package:tvbox/core/network/app_http_client.dart';

class LiveAdapter implements HttpClientAdapter {
  LiveAdapter(this.handler);
  final ResponseBody Function(RequestOptions) handler;
  final requests = <RequestOptions>[];
  @override
  Future<ResponseBody> fetch(
    RequestOptions o,
    Stream<Uint8List>? stream,
    Future<void>? cancel,
  ) async {
    requests.add(o);
    return handler(o);
  }

  @override
  void close({bool force = false}) {}
}

void main() {
  late AppHttpClient client;
  late LiveRepository repository;
  late LiveAdapter adapter;
  setUp(() {
    adapter = LiveAdapter(
      (_) => throw StateError('Unexpected network request'),
    );
    client = AppHttpClient(adapter: adapter);
    repository = LiveRepository(client);
  });
  tearDown(() {
    client.close();
  });
  test('M3U metadata, headers, relative paths and multi-line merge', () {
    final channels = repository.parse('''#EXTM3U x-tvg-url="./epg.xml"
#EXTINF:-1 tvg-id="cctv1" tvg-logo="./logo.png" group-title="央视,高清",CCTV1
#EXTVLCOPT:http-user-agent=TVAgent
#EXTVLCOPT:http-referrer=https://refer.test/
./one.m3u8|Cookie=a%3Db
#EXTINF:-1 tvg-id="cctv1" group-title="央视,高清",CCTV1
#EXTVLCOPT:http-user-agent=TVAgent
#EXTVLCOPT:http-referrer=https://refer.test/
./two.m3u8|Cookie=a%3Db
''', baseUrl: 'https://a.test/dir/list.m3u');
    expect(channels, hasLength(1));
    final channel = channels.single;
    expect(channel.urls, [
      'https://a.test/dir/one.m3u8',
      'https://a.test/dir/two.m3u8',
    ]);
    expect(channel.logo, 'https://a.test/dir/logo.png');
    expect(channel.group, '央视,高清');
    expect(channel.epg, 'https://a.test/dir/epg.xml');
    expect(channel.headers, {
      'User-Agent': 'TVAgent',
      'Referer': 'https://refer.test/',
      'Cookie': 'a=b',
    });
  });
  test('TXT groups, source alternatives and header parsing', () {
    final channels = repository.parse(
      '央视,#genre#\nCCTV1,./one#https://b.test/two\n卫视,#genre#\n湖南,https://c.test/live|User-Agent=okhttp%2F4.9.1',
      baseUrl: 'https://a.test/list.txt',
    );
    expect(channels, hasLength(2));
    expect(channels.first.group, '央视');
    expect(channels.first.urls, ['https://a.test/one', 'https://b.test/two']);
    expect(channels.last.headers['User-Agent'], 'okhttp/4.9.1');
  });
  test('JSON nested groups and ext headers preserve stream URL', () async {
    final channels = await repository.load([
      {
        'name': '本地',
        'epg': './epg.xml',
        'header': {'User-Agent': 'agent'},
        'channels': [
          {
            'name': '频道',
            'urls': ['./stream.m3u8'],
            'logo': './a.png',
            'tvg-id': 'id',
          },
        ],
      },
    ], baseUrl: 'https://a.test/dir/config.json');
    expect(channels.single.group, '本地');
    expect(channels.single.headers['User-Agent'], 'agent');
    expect(channels.single.urls.single, 'https://a.test/dir/stream.m3u8');
    expect(channels.single.tvgId, 'id');
    expect(adapter.requests, isEmpty);
    final direct = await repository.load([
      {
        'name': '组',
        'channels': [
          {'name': '单URL', 'url': './direct.m3u8'},
        ],
      },
    ], baseUrl: 'https://a.test/list.json');
    expect(direct.single.urls, ['https://a.test/direct.m3u8']);
    expect(adapter.requests, isEmpty);
  });
  test('嵌套列表中坏节点不会丢失前后有效频道', () async {
    final errors = <String>[];
    final channels = await repository.load([
      {
        'name': '组',
        'channels': [
          {'name': '甲', 'url': 'https://a.test/a.m3u8'},
          {'name': '无地址'},
          {'name': '乙', 'url': 'https://a.test/b.m3u8'},
        ],
      },
    ], onError: errors.add);
    expect(channels.map((c) => c.name), ['甲', '乙']);
    expect(errors.single, contains('无地址'));
  });
  test('loopback requires plugin fetcher and never reaches HTTP', () async {
    await expectLater(
      repository.load([
        {'url': 'http://127.0.0.1:9978/live'},
      ]),
      throwsA(isA<LiveException>()),
    );
    final channels = await repository.load(
      [
        {'url': 'http://localhost:9978/live'},
      ],
      localFetcher: (url) async {
        expect(url, 'http://localhost:9978/live');
        return '分组,#genre#\n频道,https://a.test/stream';
      },
    );
    expect(channels.single.name, '频道');
    expect(adapter.requests, isEmpty);
  });
  test(
    'proxy base64 ext resolves playlist, follows final base, cycle guard',
    () async {
      client.close();
      adapter = LiveAdapter((o) {
        if (o.uri.path == '/list') {
          return ResponseBody.fromString(
            '',
            302,
            headers: {
              'location': ['/dir/final'],
            },
          );
        }
        return ResponseBody.fromString(
          '{"channels":[{"name":"台","urls":["./live"]}]}',
          200,
        );
      });
      client = AppHttpClient(adapter: adapter);
      repository = LiveRepository(client);
      final ext = base64.encode(utf8.encode('https://a.test/list'));
      final channels = await repository.load([
        {'url': 'proxy://do=live&type=txt&ext=$ext'},
      ]);
      expect(channels.single.urls.single, 'https://a.test/dir/live');
      client.close();
      client = AppHttpClient(
        adapter: LiveAdapter(
          (_) => ResponseBody.fromString('{"lives":[{"url":"./cycle"}]}', 200),
        ),
      );
      repository = LiveRepository(client);
      await expectLater(
        repository.loadUrl('https://a.test/cycle'),
        throwsA(isA<LiveException>()),
      );
    },
  );
  test('gzip EPG, XML timezone and now/next programme API', () async {
    const xml =
        '<tv><channel id="id"><display-name>央视</display-name></channel>'
        '<programme channel="id" start="20261101100000 +0800" stop="20261101110000 +0800"><title>新闻</title><desc>介绍</desc></programme>'
        '<programme channel="id" start="20261101110000 +0800" stop="20261101120000 +0800"><title>电影</title></programme></tv>';
    final guide = repository.parseEpg(xml);
    expect(guide.channels['id'], '央视');
    expect(guide.now('id', at: DateTime.utc(2026, 11, 1, 2, 30))!.title, '新闻');
    expect(guide.next('id', at: DateTime.utc(2026, 11, 1, 2, 30))!.title, '电影');
    expect(guide.now('id', at: DateTime.utc(2026, 11, 1, 3))!.title, '电影');
    client.close();
    client = AppHttpClient(
      adapter: LiveAdapter(
        (_) => ResponseBody.fromBytes(gzip.encode(utf8.encode(xml)), 200),
      ),
    );
    repository = LiveRepository(client);
    expect(
      (await repository.loadEpg('https://a.test/epg.gz')).programmes,
      hasLength(2),
    );
  });
  test('JSON EPG crosses midnight and missing channel lookup is empty', () {
    final guide = repository.parseEpg(
      '{"channel_name":"CCTV1","date":"2026-11-01","epg_data":[{"start":"23:00","end":"01:00","title":"夜间"}]}',
    );
    expect(
      guide.programmes.single.end.difference(guide.programmes.single.start),
      const Duration(hours: 2),
    );
    expect(guide.forChannel('missing'), isEmpty);
    expect(guide.now('missing'), isNull);
  });
}
