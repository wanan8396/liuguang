import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:tvbox/core/engine/android_engine_bridge.dart';
import 'package:tvbox/core/engine/source_engine.dart';
import 'package:tvbox/core/models/models.dart';
import 'package:tvbox/core/network/app_http_client.dart';

/// Real HTTP -> Pigeon -> ART/DexClassLoader -> authored fixture -> HTTP.
/// The same Dart client used by Windows/iOS runs on an Android test host here;
/// this proves actual DEX invocation, not that iOS itself executes DEX.
void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();
  testWidgets(
    'Android bridge invokes the controlled DEX through RPC and streams its proxy',
    (tester) async {
      const encoded = String.fromEnvironment('CONTROLLED_DEX_BASE64');
      expect(
        encoded,
        isNotEmpty,
        reason: 'CI must rebuild the authored DEX fixture',
      );
      final bytes = base64Decode(encoded);
      HttpOverrides.global = null;
      await tester.pumpWidget(
        const MaterialApp(home: Scaffold(body: Text('JAR bridge fixture'))),
      );
      final jar = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      jar.listen((request) async {
        request.response.headers.contentType = ContentType.binary;
        request.response.add(bytes);
        await request.response.close();
      });
      final service = AndroidEngineBridgeService();
      AndroidEngineBridgeApi? api;
      final http = AppHttpClient();
      final engine = SourceEngine(http, isAndroid: false);
      try {
        await service.start(address: InternetAddress.loopbackIPv4);
        api = AndroidEngineBridgeApi(
          endpoint: service.addresses.single,
          token: service.token!,
        );
        expect(jsonDecode(await api.capabilities())['jar'], true);
        await engine.configureAndroidBridge(api);
        final config = TvConfig(
          url: 'http://127.0.0.1:${jar.port}/config.json',
          name: 'fixture',
          raw: {'spider': 'http://127.0.0.1:${jar.port}/controlled.jar'},
        );
        final site = Site({
          'key': 'bridge-controlled',
          'type': 3,
          'api': 'csp_Controlled',
          'ext': 'bridge-verified',
        });
        final home = await engine.home(config, site);
        expect(home.categories.single.name, 'Controlled');
        expect(home.items.single.name, 'Fixture');
        expect((await engine.category(config, site, '1', page: 2)).page, 2);
        expect((await engine.search(config, site, 'fixture', page: 3)).page, 3);
        final detail = await engine.detail(config, site, 'one');
        expect(detail.lines.single.episodes.single.name, 'One');
        final playback = await engine.play(config, site, 'fixture', 'one');
        expect(playback.parse, false);
        expect(playback.url, startsWith('${service.addresses.single}/media/'));

        // A separate real native session lets the fixture's proxy text exercise
        // gateway streaming without contacting example.invalid media.
        final session = await api.openSession(
          jsonEncode(config.toJson()),
          jsonEncode(site.toJson()),
        );
        final resolved =
            jsonDecode(
                  await api.resolve(
                    session,
                    jsonEncode({
                      'url': 'http://127.0.0.1:9997/proxy?do=jar&kind=hls',
                      'parse': 0,
                    }),
                    '[]',
                  ),
                )
                as Map;
        final proxy = resolved['url'] as String;
        expect(proxy, startsWith('${service.addresses.single}/media/'));
        expect(
          utf8.decode((await http.fetch(proxy)).bytes),
          startsWith('#EXTM3U'),
        );
        expect(
          await api.fetchLocal(session, 'http://127.0.0.1:9997/proxy?do=jar'),
          'controlled-proxy',
        );
        await api.closeSession(session);
        await expectLater(http.fetch(proxy), throwsA(isA<AppHttpException>()));
      } finally {
        await engine.dispose();
        await service.stop();
        service.dispose();
        http.close();
        await jar.close(force: true);
      }
    },
    skip: !Platform.isAndroid,
    timeout: const Timeout(Duration(minutes: 3)),
  );
}
