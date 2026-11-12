import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:tvbox/core/app_controller.dart';
import 'package:tvbox/core/engine/android_engine_bridge.dart';
import 'package:tvbox/core/engine/source_engine_api.g.dart';
import 'package:tvbox/core/storage/app_store.dart';

class _Secrets implements SecretStorage {
  final values = <String, String>{};
  Future<String?> Function(String key)? onRead;
  Future<void> Function(String key, String value)? beforeWrite;
  final writes = <String>[];
  @override
  Future<String?> read(String key) async =>
      onRead == null ? values[key] : await onRead!(key);
  @override
  Future<void> write(String key, String value) async {
    await beforeWrite?.call(key, value);
    values[key] = value;
    writes.add(value);
  }
}

class _CapabilitiesStub {
  _CapabilitiesStub._(this.server);
  final HttpServer server;
  final entered = Completer<void>();
  final release = Completer<void>();
  String get endpoint => 'http://127.0.0.1:${server.port}';

  static Future<_CapabilitiesStub> start() async {
    final stub = _CapabilitiesStub._(
      await HttpServer.bind(InternetAddress.loopbackIPv4, 0),
    );
    stub.server.listen((request) async {
      final envelope =
          jsonDecode(await utf8.decoder.bind(request).join()) as Map;
      if (!stub.entered.isCompleted) stub.entered.complete();
      await stub.release.future;
      request.response.headers.contentType = ContentType.json;
      request.response.write(
        jsonEncode({'id': envelope['id'], 'result': '{"jar":true}'}),
      );
      await request.response.close();
    });
    return stub;
  }

  Future<void> close() async {
    if (!release.isCompleted) release.complete();
    await server.close(force: true);
  }
}

class _Native extends SourceEngineApi {
  @override
  Future<String> capabilities() async => ' {"jar":true,"webView":true}';
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late Directory directory;
  late AppStore store;
  late AppController controller;
  late _Secrets secrets;
  setUp(() async {
    HttpOverrides.global = null;
    directory = await Directory.systemTemp.createTemp('bridge-settings-');
    secrets = _Secrets();
    store = AppStore(path: directory.path, secretStorage: secrets);
    controller = AppController(store: store);
    await controller.initialize();
  });
  tearDown(() async {
    await controller.disposeAsync();
    await directory.delete(recursive: true);
  });
  test(
    'bridge credentials stored only in secrets and excluded from backup',
    () async {
      final service = AndroidEngineBridgeService(native: _Native());
      await service.start(address: InternetAddress.loopbackIPv4);
      try {
        final token = service.token!;
        await controller.configureAndroidBridge(
          service.addresses.single,
          token,
        );
        expect(
          controller.engine.androidBridgeEndpoint,
          service.addresses.single,
        );
        final saved = jsonDecode(
          secrets.values[AndroidEngineBridgeApi.connectionSecretKey]!,
        );
        expect(saved['token'], token);
        expect(await store.exportBackup(), isNot(contains(token)));
        await controller.clearAndroidBridge();
        expect(controller.engine.androidBridgeEndpoint, isNull);
        expect(secrets.values[AndroidEngineBridgeApi.connectionSecretKey], '');
      } finally {
        await service.stop();
        service.dispose();
      }
    },
  );
  test('saved offline phone never blocks controller initialization', () async {
    secrets.values[AndroidEngineBridgeApi.connectionSecretKey] = jsonEncode({
      'endpoint': 'http://127.0.0.1:9',
      'token': 'offline-fixture-token',
    });
    await controller.initialize().timeout(const Duration(seconds: 2));
    expect(controller.engine.androidBridgeEndpoint, 'http://127.0.0.1:9');
  });
  test('clear wins over an older in-flight capability probe', () async {
    final stub = await _CapabilitiesStub.start();
    addTearDown(stub.close);
    final saving = controller.configureAndroidBridge(
      stub.endpoint,
      'old-token',
    );
    await stub.entered.future;
    await controller.clearAndroidBridge();
    stub.release.complete();
    await saving;
    expect(controller.engine.androidBridgeEndpoint, isNull);
    expect(secrets.values[AndroidEngineBridgeApi.connectionSecretKey], '');
    expect(secrets.writes, ['']);
  });

  test(
    'newer verified save wins while an older probe remains pending',
    () async {
      final old = await _CapabilitiesStub.start();
      final latest = await _CapabilitiesStub.start();
      addTearDown(old.close);
      addTearDown(latest.close);
      final savingOld = controller.configureAndroidBridge(
        old.endpoint,
        'old-token',
      );
      await old.entered.future;
      final savingLatest = controller.configureAndroidBridge(
        latest.endpoint,
        'new-token',
      );
      await latest.entered.future;
      latest.release.complete();
      await savingLatest;
      old.release.complete();
      await savingOld;
      expect(controller.engine.androidBridgeEndpoint, latest.endpoint);
      final saved =
          jsonDecode(
                secrets.values[AndroidEngineBridgeApi.connectionSecretKey]!,
              )
              as Map;
      expect(saved['endpoint'], latest.endpoint);
      expect(saved['token'], 'new-token');
      expect(secrets.writes, hasLength(1));
    },
  );

  test(
    'clear is serialized after a pending secret write and stale save is rolled back',
    () async {
      final stub = await _CapabilitiesStub.start();
      addTearDown(stub.close);
      final entered = Completer<void>();
      final release = Completer<void>();
      var blocked = false;
      secrets.beforeWrite = (key, value) async {
        if (!blocked && value.isNotEmpty) {
          blocked = true;
          entered.complete();
          await release.future;
        }
      };
      final saving = controller.configureAndroidBridge(
        stub.endpoint,
        'stale-token',
      );
      await stub.entered.future;
      stub.release.complete();
      await entered.future;
      final clearing = controller.clearAndroidBridge();
      expect(controller.engine.androidBridgeEndpoint, isNull);
      release.complete();
      await Future.wait([saving, clearing]);
      expect(secrets.values[AndroidEngineBridgeApi.connectionSecretKey], '');
      expect(controller.engine.androidBridgeEndpoint, isNull);
      expect(secrets.writes.last, '');
    },
  );

  test(
    'late initialization read never restores a connection after explicit clear',
    () async {
      final entered = Completer<void>();
      final release = Completer<String?>();
      var blocked = false;
      secrets.onRead = (key) async {
        if (!blocked) {
          blocked = true;
          entered.complete();
          return release.future;
        }
        return secrets.values[key];
      };
      final initializing = controller.initialize();
      await entered.future;
      await controller.clearAndroidBridge();
      release.complete(
        jsonEncode({'endpoint': 'http://127.0.0.1:9', 'token': 'stale-token'}),
      );
      await initializing;
      expect(controller.engine.androidBridgeEndpoint, isNull);
      expect(secrets.values[AndroidEngineBridgeApi.connectionSecretKey], '');
      expect(controller.bridgeError, isNull);
    },
  );

  test(
    'dispose finishes without waiting for a capability probe and ignores its late result',
    () async {
      final stub = await _CapabilitiesStub.start();
      addTearDown(stub.close);
      final saving = controller.configureAndroidBridge(
        stub.endpoint,
        'stale-token',
      );
      await stub.entered.future;
      await controller.disposeAsync().timeout(const Duration(seconds: 2));
      stub.release.complete();
      await saving;
      expect(controller.engine.androidBridgeEndpoint, isNull);
      expect(secrets.writes, isEmpty);
    },
  );

  test(
    'dispose waits for pending persistence rollback before closing resources',
    () async {
      final original = jsonEncode({
        'endpoint': 'http://127.0.0.1:9',
        'token': 'original-token',
      });
      secrets.values[AndroidEngineBridgeApi.connectionSecretKey] = original;
      final stub = await _CapabilitiesStub.start();
      addTearDown(stub.close);
      final entered = Completer<void>();
      final release = Completer<void>();
      var blocked = false;
      secrets.beforeWrite = (key, value) async {
        if (!blocked) {
          blocked = true;
          entered.complete();
          await release.future;
        }
      };
      final saving = controller.configureAndroidBridge(
        stub.endpoint,
        'stale-token',
      );
      await stub.entered.future;
      stub.release.complete();
      await entered.future;
      final disposing = controller.disposeAsync();
      release.complete();
      await Future.wait([saving, disposing]);
      expect(
        secrets.values[AndroidEngineBridgeApi.connectionSecretKey],
        original,
      );
      expect(controller.engine.androidBridgeEndpoint, isNull);
    },
  );

  test(
    'failed persistence rolls back and does not poison a later clear',
    () async {
      final original = jsonEncode({
        'endpoint': 'http://127.0.0.1:9',
        'token': 'original',
      });
      secrets.values[AndroidEngineBridgeApi.connectionSecretKey] = original;
      var failed = false;
      secrets.beforeWrite = (key, value) async {
        if (!failed) {
          failed = true;
          throw StateError('fixture secure storage write failure');
        }
      };
      final stub = await _CapabilitiesStub.start();
      addTearDown(stub.close);
      final saving = controller.configureAndroidBridge(
        stub.endpoint,
        'candidate',
      );
      final checked = expectLater(saving, throwsA(isA<StateError>()));
      await stub.entered.future;
      stub.release.complete();
      await checked;
      expect(
        secrets.values[AndroidEngineBridgeApi.connectionSecretKey],
        original,
      );
      await controller.clearAndroidBridge();
      expect(secrets.values[AndroidEngineBridgeApi.connectionSecretKey], '');
      expect(controller.engine.androidBridgeEndpoint, isNull);
    },
  );

  test(
    'late initialization read never replaces a newer verified save',
    () async {
      final entered = Completer<void>();
      final release = Completer<String?>();
      var blocked = false;
      secrets.onRead = (key) async {
        if (!blocked) {
          blocked = true;
          entered.complete();
          return release.future;
        }
        return secrets.values[key];
      };
      final initializing = controller.initialize();
      await entered.future;
      final stub = await _CapabilitiesStub.start();
      addTearDown(stub.close);
      final saving = controller.configureAndroidBridge(
        stub.endpoint,
        'new-token',
      );
      await stub.entered.future;
      stub.release.complete();
      await saving;
      release.complete(
        jsonEncode({'endpoint': 'http://127.0.0.1:9', 'token': 'stale-token'}),
      );
      await initializing;
      expect(controller.engine.androidBridgeEndpoint, stub.endpoint);
      final saved =
          jsonDecode(
                secrets.values[AndroidEngineBridgeApi.connectionSecretKey]!,
              )
              as Map;
      expect(saved['token'], 'new-token');
    },
  );

  test(
    'malformed saved endpoint reports local message and still launches',
    () async {
      secrets.values[AndroidEngineBridgeApi.connectionSecretKey] = jsonEncode({
        'endpoint': 'http://public.invalid',
        'token': 'fixture',
      });
      await controller.initialize();
      expect(controller.bridgeError, isNotNull);
      expect(controller.engine.androidBridgeEndpoint, isNull);
    },
  );
}
