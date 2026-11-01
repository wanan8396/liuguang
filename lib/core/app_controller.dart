import 'dart:async';
import 'dart:convert';

import 'package:crypto/crypto.dart';
import 'package:flutter/material.dart';

import 'config/subscription_repository.dart';
import 'engine/source_engine.dart';
import 'live/live_repository.dart';
import 'models/models.dart';
import 'network/app_http_client.dart';
import 'pairing/pairing_service.dart';
import 'storage/app_store.dart';

export 'models/models.dart';

class AppController extends ChangeNotifier {
  AppController({AppStore? store, AppHttpClient? http, SourceEngine? engine})
    : store = store ?? AppStore(),
      http = http ?? AppHttpClient() {
    this.engine = engine ?? SourceEngine(this.http);
    this.engine.isTrusted = isConfigTrusted;
    this.engine.loadCredentials = _loadCredentials;
    _subscriptions = SubscriptionRepository(this.http);
    _live = LiveRepository(this.http);
    pairing = PairingService(onSubscription: importSubscription);
  }

  final AppStore store;
  final AppHttpClient http;
  late final SourceEngine engine;
  late final SubscriptionRepository _subscriptions;
  late final LiveRepository _live;
  late final PairingService pairing;
  TvConfig? currentConfig;
  Site? currentSite;
  VodPage? homePage;
  VodPage? currentPage;
  bool busy = false;
  bool importing = false;
  String? error;
  List<RepoNode> importNodes = [];
  List<LiveChannel> liveChannels = [];
  ThemeMode themeMode = ThemeMode.system;
  int _generation = 0;
  int _searchGeneration = 0;
  int _liveGeneration = 0;
  int _importGeneration = 0;
  bool _disposed = false;
  final Set<String> _revokedTrust = {};

  List<ImportResult> get subscriptions => store.subscriptions;
  List<TvConfig> get configs {
    final byUrl = <String, TvConfig>{};
    for (final subscription in subscriptions) {
      for (final config in subscription.configs) {
        byUrl[config.url] = config;
      }
    }
    return byUrl.values.toList();
  }

  List<Site> enabledSites([TvConfig? config]) {
    final selected = config ?? currentConfig;
    if (selected == null) return [];
    final disabled = jsonList(store.setting('disabled:${selected.url}'))
        .map(str)
        .toSet();
    final order = jsonList(store.setting('siteOrder:${selected.url}'))
        .map(str)
        .toList();
    final ordered = <Site>[];
    final byKey = {for (final site in selected.sites) site.key: site};
    for (final key in order) {
      final site = byKey.remove(key);
      if (site != null && !disabled.contains(key)) ordered.add(site);
    }
    ordered.addAll(byKey.values.where((site) => !disabled.contains(site.key)));
    return ordered;
  }

  bool isSiteEnabled(Site site, [TvConfig? config]) {
    final selected = config ?? currentConfig;
    return selected != null &&
        !jsonList(store.setting('disabled:${selected.url}'))
            .map(str)
            .contains(site.key);
  }

  Future<void> setSiteEnabled(
    Site site,
    bool enabled, {
    TvConfig? config,
  }) async {
    final selected = config ?? currentConfig;
    if (selected == null) return;
    final disabled = jsonList(store.setting('disabled:${selected.url}'))
        .map(str)
        .toSet();
    enabled ? disabled.remove(site.key) : disabled.add(site.key);
    await store.setSetting('disabled:${selected.url}', disabled.toList());
    if (!enabled &&
        currentConfig?.url == selected.url &&
        currentSite?.key == site.key) {
      final replacement = enabledSites(selected).firstOrNull;
      if (replacement != null) {
        await selectSite(replacement);
      } else {
        _generation++;
        currentSite = null;
        homePage = null;
        currentPage = null;
        error = '当前仓库的站点均已停用，请在订阅管理中启用站点';
      }
    }
    _notify();
  }

  Future<void> reorderSites(List<String> keys, {TvConfig? config}) async {
    final selected = config ?? currentConfig;
    if (selected == null) return;
    final existing = selected.sites.map((site) => site.key).toSet();
    await store.setSetting(
      'siteOrder:${selected.url}',
      keys.where(existing.contains).toSet().toList(),
    );
    _notify();
  }

  String _credentialKey(TvConfig config) =>
      'sourceCredentials:${sha256.convert(utf8.encode(config.url))}';

  Future<Map<String, String>> _loadCredentials(TvConfig config) async {
    final stored = await store.readSecret(_credentialKey(config));
    if (stored == null || stored.isEmpty) return {};
    return jsonMap(jsonDecode(stored))
        .map((key, value) => MapEntry(key, str(value)));
  }

  Future<List<String>> credentialNames({TvConfig? config}) async {
    final selected = config ?? currentConfig;
    return selected == null
        ? []
        : (await _loadCredentials(selected)).keys.toList();
  }

  Future<void> saveCredential(
    String name,
    String value, {
    TvConfig? config,
  }) async {
    final selected = config ?? currentConfig;
    if (selected == null) throw const SourceFailure('no-source', '请先选择仓库');
    if (!RegExp(r'^[A-Za-z0-9_.-]{1,64}$').hasMatch(name) ||
        name == '.' ||
        name == '..') {
      throw const FormatException('凭据名称只可包含字母、数字、点、下划线和短横线，最多64字符');
    }
    if (value.length > 32768) throw const FormatException('凭据内容超过32KB');
    final credentials = await _loadCredentials(selected);
    if (value.isEmpty) {
      credentials.remove(name);
    } else {
      credentials[name] = value;
    }
    await store.writeSecret(_credentialKey(selected), jsonEncode(credentials));
    await engine.closeSessions();
    _notify();
  }

  String _trustId(TvConfig config) =>
      sha256.convert(utf8.encode(jsonEncode(config.toJson()))).toString();

  bool isConfigTrusted(TvConfig config) =>
      !_revokedTrust.contains(_trustId(config)) &&
      jsonList(store.setting('trustedConfigs')).contains(_trustId(config));
  bool get pluginsTrusted =>
      currentConfig != null && isConfigTrusted(currentConfig!);

  Future<void> initialize() async {
    await store.init();
    final theme = str(store.setting('themeMode'));
    themeMode =
        ThemeMode.values.where((value) => value.name == theme).firstOrNull ??
        ThemeMode.system;
    final configUrl = str(store.setting('currentConfig'));
    currentConfig =
        configs.where((config) => config.url == configUrl).firstOrNull ??
        configs.firstOrNull;
    if (currentConfig != null) {
      final siteKey = str(store.setting('currentSite'));
      currentSite =
          enabledSites(currentConfig)
              .where((site) => site.key == siteKey)
              .firstOrNull ??
          enabledSites(currentConfig).firstOrNull;
    }
    _notify();
  }

  Future<void> reloadAfterRestore() async {
    _generation++;
    _searchGeneration++;
    _liveGeneration++;
    cancelImport();
    await engine.closeSessions();
    currentConfig = null;
    currentSite = null;
    homePage = null;
    currentPage = null;
    liveChannels = [];
    error = null;
    busy = false;
    await initialize();
    if (currentSite != null) await refreshHome();
  }

  Future<void> importSubscription(String url) async {
    if (importing) return;
    final generation = ++_importGeneration;
    importing = true;
    error = null;
    importNodes = [];
    _notify();
    try {
      final result = await _subscriptions.load(
        url.trim(),
        onProgress: (node) {
          if (_disposed || generation != _importGeneration) return;
          importNodes = [...importNodes.where((n) => n.url != node.url), node];
          _notify();
        },
      );
      if (_disposed || generation != _importGeneration) return;
      await _acceptImport(result);
    } catch (failure) {
      if (_disposed || generation != _importGeneration) return;
      error = failure.toString();
      rethrow;
    } finally {
      importing = false;
      _notify();
    }
  }

  Future<void> importText(String text, {String name = '本地配置'}) async {
    if (importing) return;
    final generation = ++_importGeneration;
    importing = true;
    error = null;
    _notify();
    try {
      final result = await _subscriptions.loadText(text, name: name);
      if (_disposed || generation != _importGeneration) return;
      importNodes = result.nodes;
      await _acceptImport(result);
    } catch (failure) {
      if (_disposed || generation != _importGeneration) return;
      error = failure.toString();
      rethrow;
    } finally {
      importing = false;
      _notify();
    }
  }

  Future<void> _acceptImport(ImportResult result) async {
    await store.saveSubscription(result);
    final chosen =
        configs
            .where((config) => config.url == currentConfig?.url)
            .firstOrNull ??
        result.configs.firstOrNull ??
        configs.firstOrNull;
    if (chosen != null) {
      await selectConfig(chosen);
    } else {
      error = '没有可加载的单仓配置，请查看入口诊断';
    }
  }

  void cancelImport() {
    _importGeneration++;
    _subscriptions.cancel();
  }

  Future<void> removeSubscription(String url) async {
    await store.removeSubscription(url);
    final remaining = configs
        .where((config) => config.url == currentConfig?.url)
        .firstOrNull;
    if (remaining == null) {
      _generation++;
      currentConfig = null;
      currentSite = null;
      homePage = null;
      currentPage = null;
      liveChannels = [];
      await engine.closeSessions();
      if (configs.isNotEmpty) await selectConfig(configs.first);
    }
    _notify();
  }

  Future<void> selectConfig(TvConfig config) async {
    currentConfig = config;
    final siteKey = str(store.setting('site:${config.url}'));
    final site =
        enabledSites(config).where((site) => site.key == siteKey).firstOrNull ??
        enabledSites(config).firstOrNull;
    liveChannels = [];
    _liveGeneration++;
    await store.setSetting('currentConfig', config.url);
    if (site != null) {
      await selectSite(site);
    } else {
      _generation++;
      currentSite = null;
      homePage = null;
      currentPage = null;
      error = '此仓库没有可选择的站点';
      _notify();
    }
  }

  Future<void> selectSite(Site site) async {
    currentSite = site;
    homePage = null;
    currentPage = null;
    await store.setSetting('currentSite', site.key);
    if (currentConfig != null) {
      await store.setSetting('site:${currentConfig!.url}', site.key);
    }
    await refreshHome();
  }

  Future<void> refreshHome() async {
    final config = currentConfig;
    final site = currentSite;
    if (config == null || site == null) return;
    final generation = ++_generation;
    busy = true;
    error = null;
    _notify();
    try {
      final page = await engine.home(config, site);
      if (generation != _generation || _disposed) return;
      homePage = page;
      currentPage = page;
    } catch (failure) {
      if (generation == _generation) error = failure.toString();
    } finally {
      if (generation == _generation) {
        busy = false;
        _notify();
      }
    }
  }

  Future<void> loadCategory(
    String tid, {
    int page = 1,
    Map<String, dynamic> filters = const {},
  }) async {
    final config = currentConfig;
    final site = currentSite;
    if (config == null || site == null) return;
    final generation = ++_generation;
    busy = true;
    error = null;
    _notify();
    try {
      final result = await engine.category(
        config,
        site,
        tid,
        page: page,
        filters: filters,
      );
      if (generation != _generation || _disposed) return;
      currentPage = page > 1 && currentPage != null
          ? VodPage(
              items: [...currentPage!.items, ...result.items],
              categories: result.categories,
              filters: result.filters,
              page: result.page,
              pageCount: result.pageCount,
              total: result.total,
            )
          : result;
    } catch (failure) {
      if (generation == _generation) error = failure.toString();
    } finally {
      if (generation == _generation) {
        busy = false;
        _notify();
      }
    }
  }

  Future<void> trustPlugins(bool trusted) async {
    final config = currentConfig;
    if (config == null) return;
    final id = _trustId(config);
    final ids = jsonList(store.setting('trustedConfigs')).map(str).toSet();
    if (trusted) {
      ids.add(id);
      await store.setSetting('trustedConfigs', ids.toList());
      _revokedTrust.remove(id);
    } else {
      _revokedTrust.add(id);
      ids.remove(id);
      try {
        await store.setSetting('trustedConfigs', ids.toList());
      } finally {
        await engine.closeSessions();
      }
    }
    await refreshHome();
  }

  Future<void> setThemeMode(ThemeMode mode) async {
    themeMode = mode;
    await store.setSetting('themeMode', mode.name);
    _notify();
  }

  Future<VodPage> search(
    String keyword, {
    Site? site,
    TvConfig? config,
    int page = 1,
  }) async {
    final selectedConfig = config ?? currentConfig;
    final selectedSite = site ?? currentSite;
    if (selectedConfig == null || selectedSite == null) {
      throw const SourceFailure('no-source', '请先添加订阅并选择站点');
    }
    final generation = _searchGeneration;
    final result = await engine.search(
      selectedConfig,
      selectedSite,
      keyword.trim(),
      page: page,
    );
    if (_disposed || generation != _searchGeneration) {
      throw const SourceFailure('cancelled', '搜索已取消');
    }
    return result;
  }

  void cancelSearch() {
    _searchGeneration++;
    unawaited(engine.cancel());
  }

  Future<VodDetail> detail(Vod vod, {Site? site, TvConfig? config}) {
    final selectedConfig = config ?? currentConfig;
    final selectedSite = site ?? currentSite;
    if (selectedConfig == null || selectedSite == null) {
      throw const SourceFailure('no-source', '此影片所属订阅或站点已不可用');
    }
    return engine.detail(selectedConfig, selectedSite, vod.id);
  }

  Future<Playback> play(
    PlayLine line,
    Episode episode, {
    Site? site,
    TvConfig? config,
  }) {
    final selectedConfig = config ?? currentConfig;
    final selectedSite = site ?? currentSite;
    if (selectedConfig == null || selectedSite == null) {
      throw const SourceFailure('no-source', '请先选择可播放的源');
    }
    return engine.play(selectedConfig, selectedSite, line.name, episode.id);
  }

  Future<void>? _liveLoading;
  String? _liveLoadingKey;
  int? _liveLoadingGeneration;
  List<String> get selectedLiveHelperSources => liveHelperSelection(
    jsonList(store.setting(liveHelperSettingKey)).map(str),
  );

  /// Replaces only the optional helper selection, never user subscriptions.
  Future<void> setLiveHelperSources(Iterable<String> ids) async {
    final next = liveHelperSelection(ids);
    if (jsonEncode(next) == jsonEncode(selectedLiveHelperSources)) return;
    await store.setSetting(liveHelperSettingKey, next);
    await loadLive();
  }

  Future<void> loadLive() {
    final key = jsonEncode([
      currentConfig?.url,
      currentSite?.key,
      store.setting('liveSubscriptions'),
      selectedLiveHelperSources,
    ]);
    if (_liveLoading != null &&
        _liveLoadingKey == key &&
        _liveLoadingGeneration == _liveGeneration) {
      return _liveLoading!;
    }
    late final Future<void> pending;
    pending = _loadLive().whenComplete(() {
      if (identical(_liveLoading, pending)) {
        _liveLoading = null;
        _liveLoadingKey = null;
      }
    });
    _liveLoadingKey = key;
    _liveLoadingGeneration = _liveGeneration;
    return _liveLoading = pending;
  }

  Future<void> _loadLive() async {
    final config = currentConfig;
    final site = currentSite;
    final generation = ++_liveGeneration;
    error = null;
    _notify();
    try {
      final channels = <LiveChannel>[];
      final failures = <String>[];
      if (config != null) {
        for (final entry in config.lives) {
          if (generation != _liveGeneration || _disposed) return;
          try {
            channels.addAll(
              await _live.load(
                [entry],
                baseUrl: config.url,
                localFetcher: site == null
                    ? null
                    : (url) => engine.fetchLocal(config, site, url),
              ),
            );
          } catch (failure) {
            final name = entry is Map
                ? str(entry['name'] ?? entry['url'])
                : str(entry);
            failures.add('$name: $failure');
          }
        }
      }
      for (final url in jsonList(
        store.setting('liveSubscriptions'),
      ).map(str).where((url) => url.trim().isNotEmpty).toSet()) {
        if (generation != _liveGeneration || _disposed) return;
        try {
          channels.addAll(await _live.loadUrl(url));
        } catch (failure) {
          failures.add('$url: $failure');
        }
      }
      if (generation != _liveGeneration || _disposed) return;
      // Helper groups are opt-in and loaded sequentially (never all 15 by default).
      for (final source in liveHelperSources) {
        if (!selectedLiveHelperSources.contains(source.id)) continue;
        if (generation != _liveGeneration || _disposed) return;
        try {
          channels.addAll(await _live.loadHelperSource(source));
        } catch (failure) {
          failures.add(failure.toString());
        }
      }
      if (generation != _liveGeneration || _disposed) return;
      liveChannels = _live.mergeChannels(channels);
      if (failures.isNotEmpty) error = failures.join('\n');
    } catch (failure) {
      if (generation == _liveGeneration) error = failure.toString();
    }
    _notify();
  }

  Future<Playback> playLive(LiveChannel channel, {int index = 0}) =>
      engine.playLive(currentConfig, currentSite, channel, index: index);

  Future<void> addLiveSubscription(String url) async {
    final value = url.trim();
    if (value.isEmpty) return;
    final urls = jsonList(store.setting('liveSubscriptions')).map(str).toSet();
    if (!urls.add(value)) return;
    await store.setSetting('liveSubscriptions', urls.toList());
    await loadLive();
  }

  Future<void> toggleFavorite(Vod vod, {Site? site, TvConfig? config}) async {
    final entry = _entry(vod, config: config, site: site);
    await store.toggleFavorite(entry);
    _notify();
  }

  bool isFavorite(Vod vod, {Site? site, TvConfig? config}) =>
      store.isFavorite(_entry(vod, config: config, site: site).key);

  Future<void> recordProgress(
    Vod vod,
    PlayLine line,
    Episode episode,
    Duration position,
    Duration duration, {
    Site? site,
    TvConfig? config,
  }) async {
    await store.recordHistory(
      _entry(
        vod,
        config: config,
        site: site,
        line: line.name,
        episode: episode.name,
        episodeId: episode.id,
        positionMs: position.inMilliseconds,
        durationMs: duration.inMilliseconds,
      ),
    );
    _notify();
  }

  LibraryEntry _entry(
    Vod vod, {
    Site? site,
    TvConfig? config,
    String line = '',
    String episode = '',
    String episodeId = '',
    int positionMs = 0,
    int durationMs = 0,
  }) => LibraryEntry(
    configUrl: (config ?? currentConfig)?.url ?? '',
    siteKey: (site ?? currentSite)?.key ?? '',
    vod: vod,
    line: line,
    episode: episode,
    episodeId: episodeId,
    positionMs: positionMs,
    durationMs: durationMs,
  );

  void refreshLibrary() => _notify();

  void _notify() {
    if (!_disposed) notifyListeners();
  }

  Future<void>? _cleanup;

  Future<void> disposeAsync() {
    dispose();
    return _cleanup!;
  }

  Future<void> _closeResources() async {
    await pairing.stop();
    pairing.dispose();
    await engine.dispose();
    http.close();
    await store.close();
  }

  @override
  void dispose() {
    if (_disposed) return;
    _disposed = true;
    _generation++;
    _searchGeneration++;
    _liveGeneration++;
    cancelImport();
    _cleanup = _closeResources();
    super.dispose();
  }
}
