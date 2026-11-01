import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:tvbox/core/search/search_concurrency.dart';
import 'package:tvbox/core/search/search_history.dart';
import 'package:tvbox/core/storage/app_store.dart';

void main() {
  test('fixed search concurrency is 16', () {
    expect(SearchConcurrency.defaultLimit, 16);
  });
  test('search history persists across store reopen', () async {
    final dir = await Directory.systemTemp.createTemp('search_history_');
    final store = AppStore(path: dir.path);
    try {
      await store.init();
      await store.setSetting(SearchHistory.settingKey, ['电影', '剧集']);
      await store.close();
      final reopened = AppStore(path: dir.path);
      try {
        await reopened.init();
        expect(SearchHistory.read(reopened.setting(SearchHistory.settingKey)), [
          '电影',
          '剧集',
        ]);
      } finally {
        await reopened.close();
      }
    } finally {
      await store.close();
      await dir.delete(recursive: true);
    }
  });
  test('history normalizes, deduplicates and caps entries', () {
    expect(SearchHistory.read(null), isEmpty);
    expect(SearchHistory.read([' a ', 1, '', 'a', 'b']), ['a', 'b']);
    final entries = [for (var i = 0; i < 30; i++) '$i'];
    expect(SearchHistory.read(entries).length, SearchHistory.limit);
    expect(SearchHistory.add(['a', 'b'], ' b '), ['b', 'a']);
  });
}
