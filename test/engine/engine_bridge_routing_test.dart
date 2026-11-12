import 'dart:async';
import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:tvbox/core/engine/android_engine_bridge.dart';
import 'package:tvbox/core/engine/source_engine.dart';
import 'package:tvbox/core/models/models.dart';
import 'package:tvbox/core/network/app_http_client.dart';

class _Bridge extends AndroidEngineBridgeApi {
  _Bridge(this.name) : super(endpoint: 'http://127.0.0.1:9', token: 'fixture');
  final String name;
  final sessions = <String>[];
  int closed = 0;
  bool disposed = false;
  Completer<void>? closing;
  @override
  Future<String> openSession(String configJson, String siteJson) async {
    final id = '$name-${sessions.length}';
    sessions.add(id);
    return id;
  }

  @override
  Future<String> home(String sessionId, bool filter) async {
    expect(sessionId, startsWith('$name-'));
    return jsonEncode({
      'class': [
        {'type_id': '1', 'type_name': name},
      ],
      'list': [],
    });
  }

  @override
  Future<void> closeSession(String sessionId) async {
    expect(sessionId, startsWith('$name-'));
    closed++;
    await closing?.future;
  }

  @override
  Future<void> dispose() async {
    disposed = true;
    await super.dispose();
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  final config = TvConfig(
    url: 'https://repo.invalid/config',
    name: 'fixture',
    raw: {},
  );
  final site = Site({'key': 'jar', 'type': 3, 'api': 'csp_Fixture'});
  test(
    'bridge switch blocks new sessions until old host teardown completes',
    () async {
      final http = AppHttpClient();
      final engine = SourceEngine(http, isAndroid: false);
      final a = _Bridge('a');
      final b = _Bridge('b');
      try {
        await engine.configureAndroidBridge(a);
        expect((await engine.home(config, site)).categories.single.name, 'a');
        a.closing = Completer<void>();
        final switching = engine.configureAndroidBridge(b);
        await expectLater(
          engine.home(config, site),
          throwsA(
            isA<SourceFailure>().having(
              (e) => e.code,
              'code',
              'bridge-changing',
            ),
          ),
        );
        await Future<void>.delayed(Duration.zero);
        expect(a.closed, 1);
        a.closing!.complete();
        await switching;
        expect(a.disposed, true);
        expect((await engine.home(config, site)).categories.single.name, 'b');
        expect(a.sessions.length, 1);
        expect(b.sessions.length, 1);
      } finally {
        await engine.dispose();
        http.close();
      }
    },
  );
  test(
    'dispose racing a switch never installs a new bridge after disposal',
    () async {
      final http = AppHttpClient();
      final engine = SourceEngine(http, isAndroid: false);
      final a = _Bridge('a');
      final b = _Bridge('b');
      await engine.configureAndroidBridge(a);
      await engine.home(config, site);
      a.closing = Completer<void>();
      final switching = engine.configureAndroidBridge(b);
      final assertion = expectLater(switching, throwsA(isA<SourceFailure>()));
      final disposing = engine.dispose();
      a.closing!.complete();
      await assertion;
      await disposing;
      expect(b.disposed, true);
      expect(engine.androidBridgeEndpoint, isNull);
      http.close();
    },
  );
}
