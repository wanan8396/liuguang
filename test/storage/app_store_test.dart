import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:tvbox/core/models/models.dart';
import 'package:tvbox/core/storage/app_store.dart';

class MemorySecrets implements SecretStorage {
  final values = <String, String>{};
  @override
  Future<String?> read(String key) async => values[key];
  @override
  Future<void> write(String key, String value) async {
    values[key] = value;
  }
}

LibraryEntry entry(String config, [int position = 0]) => LibraryEntry(
  configUrl: config,
  siteKey: 'site',
  vod: Vod({'vod_id': '42', 'vod_name': '电影'}),
  positionMs: position,
  durationMs: 90000,
  line: 'line',
  episode: '第一集',
  episodeId: 'episode',
);
ImportResult subscription({bool failed = false}) => ImportResult(
  url: 'https://a.test/root',
  nodes: [
    RepoNode(
      url: 'https://a.test/config',
      name: 'config',
      status: failed ? 'error' : 'ready',
      error: failed ? 'HTTP 503' : null,
      config: failed
          ? null
          : TvConfig(
              url: 'https://a.test/config',
              name: 'config',
              raw: {
                'sites': [
                  {'key': 'site'},
                ],
              },
            ),
    ),
  ],
);

void main() {
  late Directory temporary;
  late MemorySecrets secrets;
  late AppStore store;
  setUp(() async {
    temporary = await Directory.systemTemp.createTemp('liuguang_store_test_');
    secrets = MemorySecrets();
    store = AppStore(path: temporary.path, secretStorage: secrets);
    await store.init();
  });
  tearDown(() async {
    await store.close();
    await temporary.delete(recursive: true);
  });
  test(
    'Hive persistence, source-scoped identities and history progress',
    () async {
      await store.setSetting('theme', 'dark');
      await store.saveSubscription(subscription());
      await store.toggleFavorite(entry('configA'));
      await store.toggleFavorite(entry('configB'));
      expect(store.favorites, hasLength(2));
      await store.recordHistory(entry('configA', 10));
      await store.recordHistory(entry('configA', 200));
      expect(store.history.single.positionMs, 200);
      await store.close();
      await store.init();
      expect(store.setting('theme'), 'dark');
      expect(
        store.subscriptions.single.configs.single.sites.single.key,
        'site',
      );
      expect(store.isFavorite(entry('configB').key), isTrue);
      expect(store.history.single.episodeId, 'episode');
      await store.toggleFavorite(entry('configA'));
      expect(store.favorites, hasLength(1));
      await store.removeHistory(entry('configA').key);
      expect(store.history, isEmpty);
      await store.removeSubscription(subscription().url);
      expect(store.subscriptions, isEmpty);
    },
  );
  test('failed refresh keeps last good config and error', () async {
    await store.saveSubscription(subscription());
    await store.saveSubscription(subscription(failed: true));
    expect(store.subscriptions.single.configs, hasLength(1));
    expect(store.subscriptions.single.nodes.single.status, 'stale');
    expect(store.subscriptions.single.nodes.single.error, 'HTTP 503');
    await store.saveSubscription(
      ImportResult(
        url: subscription().url,
        nodes: [
          RepoNode(
            url: subscription().url,
            name: 'root',
            status: 'error',
            error: 'timeout',
          ),
        ],
      ),
    );
    expect(store.subscriptions.single.configs, hasLength(1));
    expect(store.subscriptions.single.nodes.first.error, 'timeout');
  });
  test(
    'failed nested repository preserves its leaves while siblings refresh',
    () async {
      final old = ImportResult(
        url: 'root',
        nodes: [
          RepoNode(
            url: 'branch',
            name: 'branch',
            parentUrl: 'root',
            status: 'repository',
          ),
          RepoNode(
            url: 'leaf',
            name: 'leaf',
            parentUrl: 'branch',
            status: 'ready',
            config: TvConfig(url: 'leaf', name: 'leaf', raw: {'sites': []}),
          ),
          RepoNode(
            url: 'sibling',
            name: 'sibling',
            parentUrl: 'root',
            status: 'ready',
            config: TvConfig(
              url: 'sibling',
              name: 'sibling',
              raw: {'sites': []},
            ),
          ),
        ],
      );
      await store.saveSubscription(old);
      await store.saveSubscription(
        ImportResult(
          url: 'root',
          nodes: [
            RepoNode(
              url: 'branch',
              name: 'branch',
              parentUrl: 'root',
              status: 'error',
              error: 'timeout',
            ),
            RepoNode(
              url: 'sibling',
              name: 'sibling',
              parentUrl: 'root',
              status: 'ready',
              config: TvConfig(url: 'sibling', name: 'new', raw: {'sites': []}),
            ),
          ],
        ),
      );
      expect(store.subscriptions.single.configs, hasLength(2));
      expect(store.subscriptions.single.nodes.last.status, 'stale');
    },
  );
  test(
    'secrets excluded, cache independent and backup restores all user data',
    () async {
      await store.setSetting('theme', 'dark');
      await store.toggleFavorite(entry('configA'));
      await store.recordHistory(entry('configA', 4200));
      await store.saveSubscription(subscription());
      final live = LiveChannel(name: '台', urls: ['https://a.test/live']);
      await store.toggleLiveFavorite(live);
      await store.writeSecret('token', 'SENSITIVE_TOKEN');
      await store.putCache('image', {'bytes': 32});
      final backup = await store.exportBackup();
      expect(backup, isNot(contains('SENSITIVE_TOKEN')));
      expect(backup, isNot(contains('image')));
      expect(await store.clearCache(), 1);
      expect(store.cached('image'), isNull);
      expect(store.setting('theme'), 'dark');
      expect(store.favorites, hasLength(1));
      expect(store.history.single.positionMs, 4200);
      expect(await store.readSecret('token'), 'SENSITIVE_TOKEN');
      await store.clearHistory();
      await store.setSetting('theme', null);
      await store.toggleLiveFavorite(live);
      await store.restoreBackup(backup);
      expect(store.history.single.positionMs, 4200);
      expect(store.liveFavorites.single.name, '台');
      expect(store.setting('theme'), 'dark');
      expect(await store.readSecret('token'), 'SENSITIVE_TOKEN');
    },
  );
  test(
    'backup cannot grant plugin trust and pre-restore snapshot survives cache clear',
    () async {
      await store.setSetting('trustedConfigs', ['local-approved']);
      await store.setSetting('theme', 'dark');
      await store.close();
      await store.init();
      expect(store.setting('trustedConfigs'), ['local-approved']);
      final exported = await store.exportBackup();
      expect(exported, isNot(contains('trustedConfigs')));
      final malicious = jsonDecode(exported) as Map;
      malicious['settings']['trustedConfigs'] = ['attacker'];
      malicious['settings']['theme'] = 'light';
      await store.restoreBackup(jsonEncode(malicious));
      expect(store.setting('trustedConfigs'), isNull);
      expect(store.setting('theme'), 'light');
      await store.clearCache();
      expect(await store.readLastRestoreBackup(), contains('local-approved'));
      await store.restoreLastRestoreBackup();
      expect(store.setting('theme'), 'dark');
      expect(store.setting('trustedConfigs'), ['local-approved']);
    },
  );
  test(
    'invalid restore is atomic; concurrent updates do not lose state',
    () async {
      await Future.wait([
        for (var i = 0; i < 20; i++) store.setSetting('key$i', i),
      ]);
      final before = await store.exportBackup();
      await expectLater(
        store.restoreBackup('{"version":99}'),
        throwsA(isA<StoreException>()),
      );
      final invalid = jsonDecode(before) as Map;
      invalid['favorites'] = [
        {'configUrl': 'x'},
      ];
      await expectLater(
        store.restoreBackup(jsonEncode(invalid)),
        throwsA(isA<StoreException>()),
      );
      expect(await store.exportBackup(), before);
      expect(store.setting('key19'), 19);
    },
  );
}
