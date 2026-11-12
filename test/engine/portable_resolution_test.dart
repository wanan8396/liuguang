import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:archive/archive.dart';
import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:tvbox/core/engine/native_web_sniffer.dart';
import 'package:tvbox/core/engine/source_engine.dart';
import 'package:tvbox/core/engine/web_sniffer.dart';
import 'package:tvbox/core/models/models.dart';
import 'package:tvbox/core/network/app_http_client.dart';

class _Adapter implements HttpClientAdapter {
  _Adapter(this.handler);
  final FutureOr<ResponseBody> Function(RequestOptions) handler;
  @override
  Future<ResponseBody> fetch(
    RequestOptions options,
    Stream<Uint8List>? data,
    Future<void>? cancelFuture,
  ) async => handler(options);
  @override
  void close({bool force = false}) {}
}

class _Browser extends NativeWebSniffer {
  final pages = <String>[];
  final headers = <Map<String, String>>[];
  Completer<WebSniffHit?>? pending;
  WebSniffHit? hit = const WebSniffHit('https://cdn.invalid/dynamic.m3u8', {
    'Cookie': 'fixture=yes',
  });
  int cancelled = 0;
  @override
  Future<WebSniffHit?> sniff(String pageUrl, Map<String, String> input) async {
    pages.add(pageUrl);
    headers.add(input);
    return pending == null ? hit : pending!.future;
  }

  @override
  Future<void> cancel() async {
    cancelled++;
    if (pending != null && !pending!.isCompleted) pending!.complete(null);
  }

  @override
  Future<void> dispose() async => cancel();
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  final site = Site({
    'key': 'remote',
    'api': 'https://api.invalid/vod',
    'type': 4,
  });
  final config = TvConfig(
    url: 'https://repo.invalid/config',
    name: 'fixture',
    raw: {},
  );
  late AppHttpClient http;
  late _Browser browser;
  late SourceEngine engine;
  setUp(() {
    http = AppHttpClient(
      adapter: _Adapter(
        (options) => ResponseBody.fromString(
          jsonEncode({'url': 'https://page.invalid/watch/1', 'parse': 1}),
          200,
        ),
      ),
    );
    browser = _Browser();
    engine = SourceEngine(http, isAndroid: false, webSniffer: browser);
  });
  tearDown(() async {
    await engine.dispose();
    http.close();
  });

  test('type=0 parser prefix actually opens in browser', () async {
    final parsed = TvConfig(
      url: config.url,
      name: 'parser',
      raw: {
        'parses': [
          {'type': 0, 'url': 'https://parser.invalid/?url='},
        ],
      },
    );
    final playback = await engine.play(parsed, site, 'line', 'episode');
    expect(browser.pages, [
      'https://parser.invalid/?url=https://page.invalid/watch/1',
    ]);
    expect(playback.url, 'https://cdn.invalid/dynamic.m3u8');
    expect(playback.headers['Cookie'], 'fixture=yes');
    expect(playback.parse, false);
  });
  test(
    'source playUrl prefix opens its browser document, not original page',
    () async {
      http.close();
      http = AppHttpClient(
        adapter: _Adapter(
          (_) => ResponseBody.fromString(
            jsonEncode({
              'url': 'https://page.invalid/watch/1',
              'parse': 1,
              'playUrl': 'https://parser.invalid/player?u=',
            }),
            200,
          ),
        ),
      );
      await engine.dispose();
      browser = _Browser();
      engine = SourceEngine(http, isAndroid: false, webSniffer: browser);
      await engine.play(config, site, 'line', 'episode');
      expect(
        browser.pages.first,
        'https://parser.invalid/player?u=https://page.invalid/watch/1',
      );
    },
  );
  test(
    'Windows and iOS HTML live channel uses portable browser path',
    () async {
      final playback = await engine.playLive(
        null,
        null,
        LiveChannel(
          name: 'web',
          urls: ['https://page.invalid/channel.html'],
          headers: {'User-Agent': 'fixture'},
        ),
      );
      expect(browser.pages, ['https://page.invalid/channel.html']);
      expect(browser.headers.single['User-Agent'], 'fixture');
      expect(playback.parse, false);
    },
  );
  test(
    'cancelled browser result never continues into static fallback',
    () async {
      browser.pending = Completer<WebSniffHit?>();
      final pending = engine.play(config, site, 'line', 'episode');
      final assertion = expectLater(
        pending,
        throwsA(
          isA<SourceFailure>().having((e) => e.code, 'code', 'cancelled'),
        ),
      );
      while (browser.pages.isEmpty) {
        await Future<void>.delayed(Duration.zero);
      }
      await engine.cancel();
      await assertion;
      expect(browser.cancelled, greaterThan(0));
    },
  );
  test(
    'global spider reference is used and arbitrary library is not executed',
    () async {
      final zip = Archive()
        ..addFile(
          ArchiveFile('classes.dex', 8, [100, 101, 120, 10, 48, 51, 53, 0]),
        );
      final data = ZipEncoder().encode(zip);
      http.close();
      http = AppHttpClient(
        adapter: _Adapter((options) {
          expect(options.uri.toString(), 'https://repo.invalid/engine.jar');
          return ResponseBody.fromBytes(data, 200);
        }),
      );
      await engine.dispose();
      browser = _Browser();
      engine = SourceEngine(http, isAndroid: false, webSniffer: browser);
      final jarConfig = TvConfig(
        url: config.url,
        name: 'jar',
        raw: {'spider': 'engine.jar'},
      );
      final jarSite = Site({'key': 'jar', 'api': 'csp_Fixture', 'type': 3});
      await expectLater(
        engine.home(jarConfig, jarSite),
        throwsA(
          isA<SourceFailure>().having(
            (e) => e.code,
            'code',
            'jar-android-required',
          ),
        ),
      );
    },
  );
  test('JAR waiting for download cannot start after cancellation', () async {
    final delayed = Completer<ResponseBody>();
    http.close();
    http = AppHttpClient(adapter: _Adapter((_) => delayed.future));
    await engine.dispose();
    browser = _Browser();
    engine = SourceEngine(http, isAndroid: false, webSniffer: browser);
    final jarConfig = TvConfig(
      url: config.url,
      name: 'jar',
      raw: {'spider': 'engine.jar'},
    );
    final pending = engine.home(
      jarConfig,
      Site({'key': 'jar', 'api': 'csp_Fixture', 'type': 3}),
    );
    final assertion = expectLater(
      pending,
      throwsA(isA<SourceFailure>().having((e) => e.code, 'code', 'cancelled')),
    );
    await engine.cancel();
    final archive = Archive()
      ..addFile(ArchiveFile.string('spider.js', 'var rule={};'));
    delayed.complete(ResponseBody.fromBytes(ZipEncoder().encode(archive), 200));
    await assertion;
  });
}
