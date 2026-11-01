import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:pointycastle/export.dart';
import 'package:tvbox/core/config/config_decoder.dart';
import 'package:tvbox/core/config/subscription_repository.dart';
import 'package:tvbox/core/network/app_http_client.dart';

class Adapter implements HttpClientAdapter {
  Adapter(this.handler);
  final FutureOr<ResponseBody> Function(RequestOptions) handler;
  final requests = <RequestOptions>[];
  @override
  Future<ResponseBody> fetch(
    RequestOptions options,
    Stream<Uint8List>? requestStream,
    Future<void>? cancelFuture,
  ) async {
    requests.add(options);
    return handler(options);
  }

  @override
  void close({bool force = false}) {}
}

ResponseBody body(
  String value, [
  int status = 200,
  Map<String, List<String>> headers = const {},
]) => ResponseBody.fromBytes(utf8.encode(value), status, headers: headers);
Matcher httpError(String code) =>
    isA<AppHttpException>().having((e) => e.code, 'code', code);

void main() {
  group('HTTP offline transport', () {
    test('Unicode host/path, UA and redirect final URI', () async {
      final adapter = Adapter(
        (o) => o.uri.path == '/tv'
            ? body('', 302, {
                'location': ['./api'],
              })
            : body('{"ok":true}'),
      );
      final client = AppHttpClient(adapter: adapter);
      final result = await client.fetch('http://肥猫.net/tv');
      expect(result.finalUrl, 'http://xn--z7x900a.net/api');
      expect(adapter.requests.first.headers['User-Agent'], 'okhttp/4.9.1');
      expect(
        normalizeHttpUrl('https://例子.中国/目录?q=中文').host,
        'xn--fsqu00a.xn--fiqs8s',
      );
      expect(
        normalizeHttpUrl('https://例子.中国/目录?q=中文').toString(),
        contains('%E7%9B%AE'),
      );
      client.close();
    });
    test('caller headers and safe cross-origin redirects', () async {
      final adapter = Adapter(
        (o) => o.uri.host == 'first.test'
            ? body('', 301, {
                'location': ['https://second.test/final'],
              })
            : body('{}'),
      );
      final client = AppHttpClient(adapter: adapter);
      await client.fetch(
        'https://first.test/',
        headers: {
          'User-Agent': 'custom',
          'Authorization': 'secret',
          'Cookie': 'session',
        },
      );
      expect(adapter.requests.last.headers['User-Agent'], 'custom');
      expect(
        adapter.requests.last.headers.keys.map((k) => k.toLowerCase()),
        isNot(contains('authorization')),
      );
      expect(
        adapter.requests.last.headers.keys.map((k) => k.toLowerCase()),
        isNot(contains('cookie')),
      );
      client.close();
    });
    test(
      'status, redirect loop, invalid URL and malformed JSON are typed',
      () async {
        final client = AppHttpClient(
          adapter: Adapter(
            (o) => switch (o.uri.path) {
              '/loop' => body('', 302, {
                'location': ['/loop'],
              }),
              '/bad' => body('oops'),
              _ => body('', 403),
            },
          ),
        );
        await expectLater(
          client.fetch('https://a.test/403'),
          throwsA(httpError('http_status')),
        );
        await expectLater(
          client.fetch('https://a.test/loop'),
          throwsA(httpError('redirect_loop')),
        );
        await expectLater(
          client.fetch('file:///local'),
          throwsA(httpError('invalid_url')),
        );
        await expectLater(
          client.getJson('https://a.test/bad'),
          throwsA(httpError('invalid_json')),
        );
        client.close();
        await expectLater(
          client.fetch('https://a.test/'),
          throwsA(httpError('closed')),
        );
      },
    );
    test('redirect cap, streamed and declared body limits', () async {
      final client = AppHttpClient(
        maxBytes: 3,
        maxRedirects: 1,
        adapter: Adapter(
          (o) => o.uri.path.startsWith('/redirect')
              ? body('', 302, {
                  'location': ['${o.uri.path}x'],
                })
              : body(
                  '1234',
                  200,
                  o.uri.path == '/length'
                      ? {
                          'content-length': ['4'],
                        }
                      : {},
                ),
        ),
      );
      await expectLater(
        client.fetch('https://a.test/redirect'),
        throwsA(httpError('redirect_limit')),
      );
      await expectLater(
        client.fetch('https://a.test/length'),
        throwsA(httpError('size_limit')),
      );
      await expectLater(
        client.fetch('https://a.test/stream'),
        throwsA(httpError('size_limit')),
      );
      client.close();
    });
    test('whole response and streamed body timeouts', () async {
      final client = AppHttpClient(
        timeout: const Duration(milliseconds: 20),
        adapter: Adapter((_) async {
          await Future<void>.delayed(const Duration(milliseconds: 50));
          return body('{}');
        }),
      );
      await expectLater(
        client.fetch('https://a.test/'),
        throwsA(httpError('timeout')),
      );
      client.close();
      final stream = StreamController<Uint8List>();
      final streamed = AppHttpClient(
        timeout: const Duration(milliseconds: 20),
        adapter: Adapter((_) => ResponseBody(stream.stream, 200)),
      );
      await expectLater(
        streamed.fetch('https://a.test/'),
        throwsA(httpError('timeout')),
      );
      stream.add(Uint8List(0));
      await stream.close();
      streamed.close();
    });
    test('JSON object and TLS errors stay explicit', () async {
      final client = AppHttpClient(
        adapter: Adapter((o) {
          if (o.uri.path == '/tls') {
            throw DioException(
              requestOptions: o,
              type: DioExceptionType.badCertificate,
            );
          }
          return body('{"value":2}');
        }),
      );
      expect(await client.getJson('https://a.test/'), {'value': 2});
      await expectLater(
        client.fetch('https://a.test/tls'),
        throwsA(httpError('tls')),
      );
      client.close();
    });
  });
  group('Configuration decoding', () {
    const decoder = ConfigDecoder();
    const plain =
        '{/* comment */sites:[{key:"中文",api:"csp_Test",},],url:"https://a/b//c",}';
    test('JSON5 retains comment-like text inside strings', () {
      expect(decoder.decode(utf8.encode(plain))['url'], 'https://a/b//c');
    });
    test('gzip, prefix base64 and nested wrappers', () {
      final encoded = '饭太硬**${base64.encode(utf8.encode(plain))}';
      expect(
        decoder.decode(gzip.encode(utf8.encode(encoded)))['sites'][0]['key'],
        '中文',
      );
      expect(
        decoder.decode([
          0xff,
          0xd8,
          0xff,
          0xe0,
          ...ascii.encode('**${base64.encode(utf8.encode(plain))}'),
        ])['sites'][0]['key'],
        '中文',
      );
    });
    test('AES2423 real framing with ASCII0 padding and hex envelope', () {
      for (final keyText in ['671', 'lintech', 'ykc71n3fyjglm']) {
        final key = Uint8List.fromList(ascii.encode(keyText.padRight(16, '0')));
        const ivText = '1234567890123';
        final iv = Uint8List.fromList(ascii.encode(ivText.padRight(16, '0')));
        final cipher = PaddedBlockCipher('AES/CBC/PKCS7')
          ..init(
            true,
            PaddedBlockCipherParameters(
              ParametersWithIV(KeyParameter(key), iv),
              null,
            ),
          );
        final ciphertext = cipher.process(
          Uint8List.fromList(utf8.encode(plain)),
        );
        final envelope = [
          ...ascii.encode('\$#$keyText#\$'),
          ...ciphertext,
          ...ascii.encode(ivText),
        ];
        final hex = envelope
            .map((b) => b.toRadixString(16).padLeft(2, '0'))
            .join();
        expect(decoder.decode(ascii.encode(hex))['sites'][0]['key'], '中文');
      }
    });
    test(
      'isolated invalid comment byte warns; URL and key bytes fail closed',
      () {
        final bytes = [
          ...utf8.encode('{/* 注释'),
          0xa0,
          ...utf8.encode(' */"sites":[{"name":"南风"}]}'),
        ];
        final warnings = <String>[];
        expect(
          decoder.decode(bytes, onWarning: warnings.add)['sites'][0]['name'],
          '南风',
        );
        expect(warnings.single, contains('JSON comment at decoded byte'));
        for (final prefix in [
          '{"url":"https://a.test/',
          '{"key":"',
          '{"sites":',
        ]) {
          expect(
            () => decoder.decode([
              ...utf8.encode(prefix),
              0xa0,
              ...utf8.encode('"}'),
            ]),
            throwsA(isA<ConfigDecodeException>()),
          );
        }
      },
    );
    test('invalid config, padding and expansion limits fail', () {
      expect(
        () => decoder.decode(ascii.encode('not a config')),
        throwsA(isA<ConfigDecodeException>()),
      );
      expect(
        () => decoder.decode(ascii.encode(r'$#671#$garbage')),
        throwsA(isA<ConfigDecodeException>()),
      );
      expect(
        () => const ConfigDecoder(
          maxDecodedBytes: 20,
        ).decode(gzip.encode(List.filled(100, 65))),
        throwsA(isA<ConfigDecodeException>()),
      );
      var wrapped = '{"sites":[]}';
      for (var i = 0; i < 7; i++) {
        wrapped = base64.encode(utf8.encode(wrapped));
      }
      expect(
        () => decoder.decode(utf8.encode(wrapped)),
        throwsA(isA<ConfigDecodeException>()),
      );
    });
  });
  group('Repository traversal', () {
    test(
      'urls/storeHouse, branch isolation, mirror and cycle handling',
      () async {
        final fixtures = {
          '/root':
              '{"storeHouse":[{"name":"child","url":"./repo"},{"url":"./bad"}]}',
          '/repo':
              '{"urls":[{"url":"./one"},{"url":"./mirror"},{"url":"./root"}]}',
          '/one': '{"sites":[{"key":"same","api":"csp_Test"}]}',
          '/mirror': '{"sites":[{"api":"csp_Test","key":"same"}]}',
        };
        final client = AppHttpClient(
          adapter: Adapter((o) => body(fixtures[o.uri.path] ?? 'invalid')),
        );
        final progress = <String>[];
        final result = await SubscriptionRepository(client).load(
          'https://a.test/root',
          onProgress: (n) => progress.add(n.status),
        );
        expect(result.configs, hasLength(1));
        expect(result.nodes.where((n) => n.status == 'mirror'), hasLength(1));
        expect(result.nodes.where((n) => n.status == 'error'), hasLength(2));
        expect(progress, contains('loading'));
        client.close();
      },
    );
    test('redirect base and selective relative resource resolution', () async {
      final client = AppHttpClient(
        adapter: Adapter(
          (o) => o.uri.path == '/old'
              ? body('', 302, {
                  'location': ['/dir/config.json'],
                })
              : body(
                  '{"spider":"../spider.jar;md5;abc","wallpaper":"./bg.jpg","sites":[{"key":"id","api":"./api","ext":{"url":"../rule.json","nested":{"file":"./x.txt"},"selector":"a|b"},"jar":"./custom.jar"},{"key":"csp","api":"csp_XX","ext":"literal|protocol"}]}',
                ),
        ),
      );
      final result = await SubscriptionRepository(
        client,
      ).load('https://a.test/old');
      final raw = result.configs.single.raw;
      expect(result.configs.single.url, 'https://a.test/dir/config.json');
      expect(raw['spider'], 'https://a.test/spider.jar;md5;abc');
      expect(raw['sites'][0]['api'], 'https://a.test/dir/api');
      expect(
        raw['sites'][0]['ext']['nested']['file'],
        'https://a.test/dir/x.txt',
      );
      expect(raw['sites'][0]['ext']['selector'], 'a|b');
      expect(raw['sites'][1]['ext'], 'literal|protocol');
      expect(raw['sites'][1]['api'], 'csp_XX');
      client.close();
    });
    test(
      'relative-resource configs on different origins are not mirrors',
      () async {
        final client = AppHttpClient(
          adapter: Adapter(
            (o) => body(
              o.uri.path == '/root'
                  ? '{"urls":[{"url":"https://one.test/config"},{"url":"https://two.test/config"}]}'
                  : '{"sites":[{"key":"same","name":"../literal","api":"./api","ext":{"selector":"./not-a-resource","url":"./resource"}}]}',
            ),
          ),
        );
        final result = await SubscriptionRepository(
          client,
        ).load('https://a.test/root');
        expect(result.configs, hasLength(2));
        expect(result.configs.first.sites.single.name, '../literal');
        expect(
          result.configs.first.sites.single.ext['selector'],
          './not-a-resource',
        );
        expect(
          result.configs.first.sites.single.ext['url'],
          'https://one.test/resource',
        );
        client.close();
      },
    );
    test('no global site-key collapse and bounded traversal', () async {
      final client = AppHttpClient(
        adapter: Adapter(
          (o) => body(
            o.uri.path == '/root'
                ? '{"urls":[{"url":"./a"},{"url":"./b"}]}'
                : '{"sites":[{"key":"same","name":"${o.uri.path}","api":"csp_X"}]}',
          ),
        ),
      );
      final result = await SubscriptionRepository(
        client,
      ).load('https://a.test/root');
      expect(result.configs, hasLength(2));
      final limited = await SubscriptionRepository(
        client,
        maxDepth: 0,
      ).load('https://a.test/root');
      expect(limited.configs, isEmpty);
      expect(limited.nodes.where((n) => n.status == 'error'), hasLength(2));
      client.close();
    });
    test('loadText and cancellation prevent further requests', () async {
      final adapter = Adapter((_) => body('{"sites":[]}'));
      final client = AppHttpClient(adapter: adapter);
      final repository = SubscriptionRepository(client);
      final local = await repository.loadText(
        '{"sites":[]}',
        baseUrl: 'https://a.test/local',
      );
      expect(local.configs.single.name, '本地配置');
      final cancelled = await repository.load(
        'https://a.test/root',
        onProgress: (n) {
          if (n.status == 'loading') repository.cancel();
        },
      );
      expect(cancelled.nodes, isEmpty);
      expect(adapter.requests, isEmpty);
      client.close();
    });
  });
}
