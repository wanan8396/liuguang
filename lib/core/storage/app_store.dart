import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:hive_ce/hive.dart';
import 'package:path_provider/path_provider.dart';

import '../models/models.dart';

abstract interface class SecretStorage {
  Future<String?> read(String key);
  Future<void> write(String key, String value);
}

class PlatformSecretStorage implements SecretStorage {
  const PlatformSecretStorage();
  static const _storage = FlutterSecureStorage();
  @override
  Future<String?> read(String key) => _storage.read(key: key);
  @override
  Future<void> write(String key, String value) =>
      _storage.write(key: key, value: value);
}

class StoreException implements Exception {
  const StoreException(this.message);
  final String message;
  @override
  String toString() => 'StoreException: $message';
}

class AppStore {
  AppStore({this.path, SecretStorage? secretStorage})
    : _secrets = secretStorage ?? const PlatformSecretStorage();
  final String? path;
  final SecretStorage _secrets;
  Box<String>? _box;
  Box<String>? _cache;
  Map<String, dynamic> _data = _empty();
  Future<void> _pending = Future.value();
  static Map<String, dynamic> _empty() => {
    'version': 1,
    'settings': <String, dynamic>{},
    'subscriptions': <dynamic>[],
    'favorites': <dynamic>[],
    'history': <dynamic>[],
    'liveFavorites': <dynamic>[],
  };

  Future<void> init() async {
    if (_box != null) return;
    final directory =
        path ??
        '${(await getApplicationDocumentsDirectory()).path}${Platform.pathSeparator}liuguang';
    await Directory(directory).create(recursive: true);
    _box = await Hive.openBox<String>('liuguang_state', path: directory);
    _cache = await Hive.openBox<String>('liuguang_cache', path: directory);
    final saved = _box!.get('state');
    if (saved != null) _data = _validate(saved);
  }

  void _requireOpen() {
    if (_box == null || !_box!.isOpen) {
      throw const StoreException('Call init() before using AppStore');
    }
  }

  Future<void> _update(
    void Function(Map<String, dynamic>) update, {
    bool snapshot = false,
  }) {
    final operation = _pending.then((_) async {
      _requireOpen();
      final next = jsonMap(jsonDecode(jsonEncode(_data)));
      update(next);
      final encoded = jsonEncode(next);
      if (snapshot) {
        await _box!.put('before_restore', jsonEncode(_data));
        await _box!.flush();
      }
      await _box!.put('state', encoded);
      await _box!.flush();
      _data = next;
    });
    _pending = operation.catchError((Object _) {});
    return operation;
  }

  List<ImportResult> get subscriptions => jsonList(
    _data['subscriptions'],
  ).map((v) => ImportResult.fromJson(jsonMap(v))).toList();

  Future<void> saveSubscription(ImportResult result) => _update((data) {
    final list = jsonList(
      data['subscriptions'],
    ).map((v) => ImportResult.fromJson(jsonMap(v))).toList();
    final index = list.indexWhere((v) => v.url == result.url);
    var saved = result;
    if (index >= 0) {
      final old = list[index];
      final nodes = result.nodes.toList();
      final oldConfigs = {
        for (final n in old.nodes.where((n) => n.config != null)) n.url: n,
      };
      for (var i = 0; i < nodes.length; i++) {
        final n = nodes[i];
        final previous = oldConfigs[n.url];
        if (n.status == 'error' && previous?.config != null) {
          nodes[i] = RepoNode(
            url: n.url,
            name: n.name,
            parentUrl: n.parentUrl,
            status: 'stale',
            error: n.error,
            config: previous!.config,
            digest: previous.digest,
          );
        }
      }
      // Preserve descendants of failed repository branches even when siblings
      // refresh successfully. Removed, healthy branches are not resurrected.
      final failed = result.nodes
          .where((n) => n.status == 'error')
          .map((n) => n.url)
          .toSet();
      final oldByUrl = {for (final n in old.nodes) n.url: n};
      final present = nodes
          .where((n) => n.config != null)
          .map((n) => n.url)
          .toSet();
      bool affected(RepoNode node) {
        var current = node.url;
        final seen = <String>{};
        while (seen.add(current)) {
          if (failed.contains(current)) return true;
          final parent = oldByUrl[current]?.parentUrl;
          if (parent == null) break;
          current = parent;
        }
        return result.configs.isEmpty && failed.isNotEmpty;
      }

      for (final n in oldConfigs.values.where(
        (n) => !present.contains(n.url) && affected(n),
      )) {
        nodes.add(
          RepoNode(
            url: n.url,
            name: n.name,
            parentUrl: n.parentUrl,
            status: 'stale',
            config: n.config,
            digest: n.digest,
            error: 'Refresh failed; last-known-good configuration retained',
          ),
        );
      }
      saved = ImportResult(
        url: result.url,
        nodes: nodes,
        checkedAt: result.checkedAt,
      );
      list[index] = saved;
    } else {
      list.add(saved);
    }
    data['subscriptions'] = list.map((v) => v.toJson()).toList();
  });
  Future<void> removeSubscription(String url) => _update((data) {
    jsonList(
      data['subscriptions'],
    ).removeWhere((v) => jsonMap(v)['url'] == url);
  });

  Object? setting(String key) => jsonMap(_data['settings'])[key];
  Future<void> setSetting(String key, Object? value) => _update((data) {
    final settings = jsonMap(data['settings']);
    if (value == null) {
      settings.remove(key);
    } else {
      settings[key] = value;
    }
    data['settings'] = settings;
  });

  List<LibraryEntry> get favorites => jsonList(
    _data['favorites'],
  ).map((v) => LibraryEntry.fromJson(jsonMap(v))).toList();
  List<LibraryEntry> get history => jsonList(
    _data['history'],
  ).map((v) => LibraryEntry.fromJson(jsonMap(v))).toList();
  bool isFavorite(String key) => favorites.any((v) => v.key == key);
  Future<void> toggleFavorite(LibraryEntry entry) => _update((data) {
    final list = jsonList(data['favorites']);
    final index = list.indexWhere(
      (v) => LibraryEntry.fromJson(jsonMap(v)).key == entry.key,
    );
    if (index >= 0) {
      list.removeAt(index);
    } else {
      list.insert(0, entry.toJson());
    }
  });
  Future<void> recordHistory(LibraryEntry entry) => _update((data) {
    final list = jsonList(data['history']);
    list.removeWhere((v) => LibraryEntry.fromJson(jsonMap(v)).key == entry.key);
    list.insert(0, entry.toJson());
    if (list.length > 1000) list.removeRange(1000, list.length);
  });
  Future<void> removeHistory(String key) => _update((data) {
    jsonList(
      data['history'],
    ).removeWhere((v) => LibraryEntry.fromJson(jsonMap(v)).key == key);
  });
  Future<void> clearHistory() => _update((data) {
    data['history'] = <dynamic>[];
  });
  List<LiveChannel> get liveFavorites => jsonList(
    _data['liveFavorites'],
  ).map((v) => LiveChannel.fromJson(jsonMap(v))).toList();
  Future<void> toggleLiveFavorite(LiveChannel channel) => _update((data) {
    final list = jsonList(data['liveFavorites']);
    String identity(LiveChannel c) =>
        jsonEncode([c.group, c.name, c.tvgId, c.urls]);
    final index = list.indexWhere(
      (v) => identity(LiveChannel.fromJson(jsonMap(v))) == identity(channel),
    );
    if (index >= 0) {
      list.removeAt(index);
    } else {
      list.insert(0, channel.toJson());
    }
  });

  Future<String> exportBackup() async {
    await _pending;
    _requireOpen();
    final exported = jsonMap(jsonDecode(jsonEncode(_data)));
    final settings = jsonMap(exported['settings'])..remove('trustedConfigs');
    exported['settings'] = settings;
    return jsonEncode(exported);
  }

  Future<void> restoreBackup(String text) async {
    final restored = _validate(text, imported: true);
    await _update((data) {
      data
        ..clear()
        ..addAll(restored);
    }, snapshot: true);
  }

  /// The pre-restore snapshot lives in the state box, never the disposable cache.
  Future<String?> readLastRestoreBackup() async {
    await _pending;
    _requireOpen();
    return _box!.get('before_restore');
  }

  Future<void> restoreLastRestoreBackup() async {
    final previous = await readLastRestoreBackup();
    if (previous == null) {
      throw const StoreException('No pre-restore snapshot exists');
    }
    final restored = _validate(previous);
    await _update((data) {
      data
        ..clear()
        ..addAll(restored);
    });
  }

  static Map<String, dynamic> _validate(String text, {bool imported = false}) {
    try {
      if (utf8.encode(text).length > 32 * 1024 * 1024) {
        throw const FormatException('Backup too large');
      }
      final value = jsonDecode(text);
      if (value is! Map || value['version'] != 1 || value['settings'] is! Map) {
        throw const FormatException(
          'Unsupported backup version or missing settings',
        );
      }
      for (final field in [
        'subscriptions',
        'favorites',
        'history',
        'liveFavorites',
      ]) {
        if (value[field] is! List ||
            (value[field] as List).any((v) => v is! Map)) {
          throw FormatException('Invalid $field');
        }
      }
      final map = Map<String, dynamic>.from(value);
      for (final item in jsonList(map['subscriptions'])) {
        final subscription = ImportResult.fromJson(jsonMap(item));
        if (subscription.url.isEmpty || jsonMap(item)['nodes'] is! List) {
          throw const FormatException('Invalid subscription');
        }
      }
      for (final field in ['favorites', 'history']) {
        for (final item in jsonList(map[field])) {
          final entry = LibraryEntry.fromJson(jsonMap(item));
          if (entry.configUrl.isEmpty ||
              entry.siteKey.isEmpty ||
              entry.vod.id.isEmpty) {
            throw FormatException('Invalid $field identity');
          }
        }
      }
      for (final item in jsonList(map['liveFavorites'])) {
        final channel = LiveChannel.fromJson(jsonMap(item));
        if (channel.name.isEmpty || channel.urls.isEmpty) {
          throw const FormatException('Invalid live channel');
        }
      }
      if (imported) {
        map['settings'] = jsonMap(map['settings'])..remove('trustedConfigs');
      }
      // An allowlist excludes accidental backup injection into secure/cache namespaces.
      return {for (final k in _empty().keys) k: map[k]};
    } catch (e) {
      throw StoreException('Backup validation failed: $e');
    }
  }

  Future<void> putCache(String key, Object value) async {
    _requireOpen();
    await _cache!.put(key, jsonEncode(value));
  }

  Object? cached(String key) {
    _requireOpen();
    final value = _cache!.get(key);
    return value == null ? null : jsonDecode(value);
  }

  Future<int> clearCache() async {
    _requireOpen();
    return _cache!.clear();
  }

  Future<String?> readSecret(String key) => _secrets.read(key);
  Future<void> writeSecret(String key, String value) =>
      _secrets.write(key, value);
  Future<void> close() async {
    await _pending;
    await _cache?.close();
    await _box?.close();
    _cache = null;
    _box = null;
  }
}
