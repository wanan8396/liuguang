import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:tvbox/core/search/search_concurrency.dart';
import 'package:tvbox/core/storage/app_store.dart';

void main() {
  test('search concurrency persists across store reopen', () async {
    final dir = await Directory.systemTemp.createTemp('search_concurrency_');
    final store = AppStore(path: dir.path);
    try {
      await store.init();
      expect(
        SearchConcurrency.fromSetting(
          store.setting(SearchConcurrency.settingKey),
        ),
        16,
      );
      await store.setSetting(SearchConcurrency.settingKey, 32);
      await store.close();
      final reopened = AppStore(path: dir.path);
      try {
        await reopened.init();
        expect(
          SearchConcurrency.fromSetting(
            reopened.setting(SearchConcurrency.settingKey),
          ),
          32,
        );
      } finally {
        await reopened.close();
      }
    } finally {
      await store.close();
      await dir.delete(recursive: true);
    }
  });
  test('invalid concurrency falls back to 16', () {
    for (final value in [null, 3, 0, -1, 'bad']) {
      expect(SearchConcurrency.fromSetting(value), 16);
    }
  });
}
