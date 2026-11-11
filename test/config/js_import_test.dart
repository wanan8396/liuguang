import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:tvbox/core/config/config_decoder.dart';
import 'package:tvbox/core/config/subscription_repository.dart';
import 'package:tvbox/core/models/models.dart';
import 'package:tvbox/core/network/app_http_client.dart';

import 'config_test.dart' show Adapter, body;

void main() {
  late Adapter adapter;
  late AppHttpClient client;
  late SubscriptionRepository repository;

  setUp(() {
    adapter = Adapter((_) => throw StateError('Unexpected network request'));
    client = AppHttpClient(adapter: adapter);
    repository = SubscriptionRepository(client);
  });
  tearDown(() => client.close());

  group('local JavaScript imports', () {
    for (final declaration in ['var', 'let', 'const']) {
      test(
        '$declaration rule is stored verbatim without executing it',
        () async {
          final source =
              '\ufeff// imported fixture\n$declaration rule = '
              '{title: "离线规则", host: "https://fixture.test/"};\n'
              'throw new Error("Import must not execute this");';
          final result = await repository.loadText(
            source,
            baseUrl: 'https://local.invalid/imports/fixture/',
          );
          expect(result.nodes.single.status, 'ready');
          final config = result.configs.single;
          expect(config.name, '离线规则');
          final site = config.sites.single;
          expect(site.name, '离线规则');
          expect(site.type, 3);
          expect(site.runtime, 'js');
          expect(site.api, 'https://local.invalid/imports/fixture/rule.js');
          expect(site.raw['_jsSource'], source);
          expect(adapter.requests, isEmpty);
          final restored = ImportResult.fromJson(
            jsonDecode(jsonEncode(result.toJson())) as Map<String, dynamic>,
          );
          expect(restored.configs.single.sites.single.raw['_jsSource'], source);
        },
      );
    }

    for (final source in [
      'globalThis.__JS_SPIDER__ = {title: "Spider"};',
      'export default {title: "ES module"};',
      'var __jsEvalReturn = {home: function() { throw new Error("later"); }};',
    ]) {
      test('recognizes ${source.split(' ').take(2).join(' ')}', () async {
        final result = await repository.loadText(source);
        expect(result.configs.single.sites.single.runtime, 'js');
        expect(result.configs.single.sites.single.raw['_jsSource'], source);
        expect(adapter.requests, isEmpty);
      });
    }

    test('JS filename is accepted and supplies the fallback name', () async {
      final result = await repository.loadText(
        'function home() { return "{}"; }',
        name: 'custom.JS',
      );
      expect(result.configs.single.name, 'custom');
      expect(
        result.configs.single.sites.single.api,
        'https://local.invalid/rule.js',
      );
    });

    test(
      'literal titles decode escapes while computed titles are ignored',
      () async {
        final literal = await repository.loadText(
          r'''const rule = {'title': '离线\u89c4则'};''',
        );
        expect(literal.configs.single.sites.single.name, '离线规则');
        final computed = await repository.loadText(
          'var rule = {title: (() => {throw new Error("no eval");})()};',
          name: 'fallback.js',
        );
        expect(computed.configs.single.sites.single.name, 'fallback');
      },
    );

    test(
      'JSON with JS markers stays JSON and keeps resource resolution',
      () async {
        final result = await repository.loadText(
          jsonEncode({
            'sites': [
              {
                'key': 'existing',
                'api': './spider.js',
                'ext': 'var rule = {title: "not an import"};',
              },
            ],
          }),
          name: 'config.js',
          baseUrl: 'https://local.invalid/config/',
        );
        expect(result.configs.single.name, 'config.js');
        final site = result.configs.single.sites.single;
        expect(site.key, 'existing');
        expect(site.api, 'https://local.invalid/config/spider.js');
        expect(site.raw.containsKey('_jsSource'), false);
      },
    );

    test('invalid text and oversize JS remain import diagnostics', () async {
      final invalid = await repository.loadText('this is not a subscription');
      expect(invalid.configs, isEmpty);
      expect(invalid.nodes.single.status, 'error');
      final oversized = await SubscriptionRepository(
        client,
        decoder: const ConfigDecoder(maxDecodedBytes: 10),
      ).loadText('var rule = {title: "too large"};');
      expect(oversized.configs, isEmpty);
      expect(oversized.nodes.single.error, contains('size limit'));
      expect(adapter.requests, isEmpty);
    });
  });

  group('remote JavaScript imports', () {
    test('redirected JS keeps the final URL and original body', () async {
      const source = 'export default {title: "远程源"};';
      client.close();
      adapter = Adapter(
        (o) => o.uri.path == '/start'
            ? body('', 302, {
                'location': ['/rules/final.js?version=2'],
              })
            : body(source),
      );
      client = AppHttpClient(adapter: adapter);
      final result = await SubscriptionRepository(
        client,
      ).load('https://repo.test/start');
      final config = result.configs.single;
      expect(config.url, 'https://repo.test/rules/final.js?version=2');
      expect(config.sites.single.api, config.url);
      expect(config.sites.single.runtime, 'js');
      expect(config.sites.single.raw['_jsSource'], source);
      expect(config.sites.single.name, '远程源');
      expect(adapter.requests, hasLength(2));
    });

    test(
      'JS URL redirected to an extensionless URL still has JS runtime',
      () async {
        client.close();
        client = AppHttpClient(
          adapter: Adapter(
            (o) => o.uri.path == '/rule.js'
                ? body('', 302, {
                    'location': ['/download?token=fixture'],
                  })
                : body('function home() { return "{}"; }'),
          ),
        );
        final result = await SubscriptionRepository(
          client,
        ).load('https://repo.test/rule.js');
        final site = result.configs.single.sites.single;
        expect(site.api, 'https://repo.test/download?token=fixture');
        expect(site.runtime, 'js');
      },
    );

    test(
      'mixed JSON repository traverses JS and preserves sibling errors',
      () async {
        client.close();
        client = AppHttpClient(
          adapter: Adapter(
            (o) => body(switch (o.uri.path) {
              '/root' =>
                '{urls:[{name:"JS",url:"./rule.js"},{url:"./json"},{url:"./bad.js"}]}',
              '/rule.js' => 'let rule = {title: "规则"};',
              '/json' => '{sites:[{key:"json",api:"csp_Test"}]}',
              _ => '<html>404</html>',
            }),
          ),
        );
        final result = await SubscriptionRepository(
          client,
        ).load('https://repo.test/root');
        expect(result.configs, hasLength(2));
        expect(result.configs.first.sites.single.runtime, 'js');
        expect(result.configs.last.sites.single.runtime, 'jar');
        expect(
          result.nodes.where((node) => node.status == 'error'),
          hasLength(1),
        );
        expect(result.nodes.first.status, 'repository');
      },
    );
  });
}
