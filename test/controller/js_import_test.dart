import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:tvbox/core/app_controller.dart';
import 'package:tvbox/core/network/app_http_client.dart';
import 'package:tvbox/core/storage/app_store.dart';

import '../config/config_test.dart' show Adapter;
import 'app_controller_test.dart' show MemorySecrets, TestEngine;

void main() {
  late Directory directory;
  late AppController controller;
  late Adapter adapter;
  late TestEngine engine;

  setUp(() async {
    directory = await Directory.systemTemp.createTemp('js-import-');
    adapter = Adapter(
      (_) => throw StateError('No HTTP during local JS import'),
    );
    final client = AppHttpClient(adapter: adapter);
    engine = TestEngine(client);
    controller = AppController(
      store: AppStore(path: directory.path, secretStorage: MemorySecrets()),
      http: client,
      engine: engine,
    );
    await controller.initialize();
  });
  tearDown(() async {
    await controller.disposeAsync();
    await directory.delete(recursive: true);
  });

  test(
    'local JS identities append and duplicate import preserves selection',
    () async {
      const first = 'var rule = {title: "first"};';
      const second = 'const rule = {title: "second"};';
      await controller.importText(first);
      final selectedUrl = controller.currentConfig!.url;
      final home = controller.homePage;
      expect(engine.homeRequests, hasLength(1));
      await controller.importText(second, name: 'second.js');
      expect(controller.subscriptions, hasLength(2));
      expect(controller.currentConfig!.url, selectedUrl);
      expect(identical(controller.homePage, home), true);
      expect(engine.homeRequests, hasLength(1));
      final sites = controller.configs
          .map((config) => config.sites.single)
          .toList();
      expect(sites.map((site) => site.runtime), ['js', 'js']);
      expect(sites.map((site) => site.api).toSet(), hasLength(2));
      expect(sites.every((site) => site.api.endsWith('/rule.js')), true);
      expect(sites.map((site) => site.raw['_jsSource']), [first, second]);
      await controller.importText(second, name: 'second.js');
      expect(controller.subscriptions, hasLength(2));
      expect(controller.importError, isNull);
      expect(adapter.requests, isEmpty);
      expect(
        directory
            .listSync(recursive: true)
            .where((file) => file.path.endsWith('.js')),
        isEmpty,
      );
    },
  );

  test('backup and restore preserve JS source inside the config', () async {
    const source =
        'export default {title: "backup", home: () => ({list: []})};';
    await controller.importText(source, name: 'backup.js');
    await controller.store.setSetting('trustedConfigs', ['existing-trust']);
    final backup = await controller.store.exportBackup();
    final decoded = jsonDecode(backup) as Map<String, dynamic>;
    final subscription = (decoded['subscriptions'] as List).single as Map;
    final node = (subscription['nodes'] as List).single as Map;
    final config = node['config'] as Map;
    final site = ((config['raw'] as Map)['sites'] as List).single as Map;
    expect(site['_jsSource'], source);
    expect(backup, isNot(contains('existing-trust')));
    await controller.store.removeSubscriptions(
      controller.subscriptions.map((item) => item.url),
    );
    expect(controller.store.subscriptions, isEmpty);
    await controller.store.restoreBackup(backup);
    await controller.reloadAfterRestore();
    expect(controller.currentSite?.raw['_jsSource'], source);
    expect(controller.currentSite?.runtime, 'js');
    expect(controller.store.setting('trustedConfigs'), isNull);
    expect(adapter.requests, isEmpty);
  });
}
