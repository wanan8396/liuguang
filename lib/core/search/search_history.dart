import 'dart:async';

import 'package:flutter/foundation.dart';

import '../storage/app_store.dart';

/// Normalizes persisted recent search terms and limits their storage size.
abstract final class SearchHistory {
  static const settingKey = 'searchHistory';
  static const limit = 20;

  static List<String> read(Object? value) {
    if (value is! List) return [];
    final result = <String>[];
    for (final item in value) {
      if (item is! String) continue;
      final term = item.trim();
      if (term.isNotEmpty && !result.contains(term)) result.add(term);
      if (result.length == limit) break;
    }
    return result;
  }

  static List<String> add(List<String> history, String keyword) {
    final term = keyword.trim();
    if (term.isEmpty) return read(history);
    return read([term, ...history]);
  }
}

/// Shared optimistic state and serialized writes, scoped to a store instance.
class SearchHistorySession extends ChangeNotifier {
  SearchHistorySession._(AppStore store)
    : _store = WeakReference(store),
      _committed = SearchHistory.read(store.setting(SearchHistory.settingKey));

  static final _sessions = Expando<SearchHistorySession>();
  static SearchHistorySession forStore(AppStore store) =>
      _sessions[store] ??= SearchHistorySession._(store);

  final WeakReference<AppStore> _store;
  List<String> _committed;
  final _operations = <_HistoryOperation>[];
  bool _writing = false;

  List<String> get history {
    var result = List<String>.of(_committed);
    for (final operation in _operations) {
      result = operation.apply(result);
    }
    return result;
  }

  Future<void> add(String keyword) =>
      _enqueue((h) => SearchHistory.add(h, keyword));
  Future<void> remove(String keyword) =>
      _enqueue((h) => h.where((item) => item != keyword).toList());
  Future<void> clear() => _enqueue((_) => <String>[]);

  Future<void> _enqueue(List<String> Function(List<String>) apply) {
    final operation = _HistoryOperation(apply);
    _operations.add(operation);
    notifyListeners();
    _drain();
    return operation.done.future;
  }

  Future<void> _drain() async {
    if (_writing) return;
    _writing = true;
    while (_operations.isNotEmpty) {
      final operation = _operations.first;
      final next = operation.apply(List<String>.of(_committed));
      try {
        final store = _store.target;
        if (store == null)
          throw StateError('Search history store is unavailable');
        await store.setSetting(SearchHistory.settingKey, next);
        _committed = next;
        _operations.removeAt(0);
        notifyListeners();
        operation.done.complete();
      } catch (error, stack) {
        _operations.removeAt(0);
        notifyListeners();
        operation.done.completeError(error, stack);
      }
    }
    _writing = false;
  }
}

class _HistoryOperation {
  _HistoryOperation(this.apply);
  final List<String> Function(List<String>) apply;
  final done = Completer<void>();
}
