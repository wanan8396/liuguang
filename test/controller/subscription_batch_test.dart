import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:tvbox/core/app_controller.dart';
import 'package:tvbox/core/network/app_http_client.dart';
import 'package:tvbox/core/storage/app_store.dart';
import '../config/config_test.dart' show Adapter, body;
import 'app_controller_test.dart' show MemorySecrets, TestEngine;

void main() {
  test(
    'batch URLs skip empty lines and duplicates and reject invalid input',
    () {
      expect(
        subscriptionUrls(
          ' https://one.test/a\n\nhttps://two.test/b\r\nhttps://one.test/a ',
        ),
        ['https://one.test/a', 'https://two.test/b'],
      );
      expect(
        () => subscriptionUrls('https://one.test\nfile:///bad'),
        throwsFormatException,
      );
      expect(() => subscriptionUrls(''), throwsFormatException);
    },
  );

  test(
    'multiple subscriptions persist, a failed entry does not stop the queue, removal keeps others',
    () async {
      final directory = await Directory.systemTemp.createTemp(
        'subscription-batch-',
      );
      final secrets = MemorySecrets();
      final http = AppHttpClient(
        adapter: Adapter(
          (options) => options.uri.path == '/bad'
              ? body('unavailable', 500)
              : body(
                  '{"sites":[{"key":"${options.uri.path}","name":"测试源","api":"csp_Fixture"}]}',
                ),
        ),
      );
      final c = AppController(
        store: AppStore(path: directory.path, secretStorage: secrets),
        http: http,
        engine: TestEngine(http),
      );
      try {
        await c.initialize();
        await c.importSubscriptions([
          'https://repo.test/one',
          'https://repo.test/bad',
          'https://repo.test/two',
          'https://repo.test/one',
        ]);
        expect(c.importQueue.map((i) => i.status), ['ready', 'error', 'ready']);
        expect(
          c.configs.map((r) => r.url),
          containsAll(['https://repo.test/one', 'https://repo.test/two']),
        );
        expect(c.currentConfig?.url, 'https://repo.test/one');
        await c.renameSubscription('https://repo.test/two', '第二订阅');
        expect(c.subscriptionName('https://repo.test/two'), '第二订阅');
        await c.importSubscription('https://repo.test/two');
        expect(
          c.subscriptions.where((s) => s.url == 'https://repo.test/two'),
          hasLength(1),
        );
        await c.removeSubscription('https://repo.test/one');
        expect(c.configs.single.url, 'https://repo.test/two');
        await c.disposeAsync();
        final store = AppStore(path: directory.path, secretStorage: secrets);
        await store.init();
        expect(
          store.subscriptions.where((s) => s.configs.isNotEmpty).single.url,
          'https://repo.test/two',
        );
        expect(store.setting('subscriptionName:https://repo.test/two'), '第二订阅');
        await store.close();
      } finally {
        await c.disposeAsync();
        await directory.delete(recursive: true);
      }
    },
  );

  test('cancel stops queued subscriptions before they are requested', () async {
    final directory = await Directory.systemTemp.createTemp(
      'subscription-cancel-',
    );
    final c = AppController(
      store: AppStore(path: directory.path, secretStorage: MemorySecrets()),
    );
    await c.initialize();
    void cancel() {
      if (c.batchImporting) c.cancelImport();
    }

    c.addListener(cancel);
    try {
      await c.importSubscriptions([
        'https://unused.invalid/a',
        'https://unused.invalid/b',
      ]);
      expect(c.importQueue.map((i) => i.status), ['cancelled', 'cancelled']);
      expect(c.subscriptions, isEmpty);
      expect(c.batchImporting, isFalse);
    } finally {
      c.removeListener(cancel);
      await c.disposeAsync();
      await directory.delete(recursive: true);
    }
  });
}
