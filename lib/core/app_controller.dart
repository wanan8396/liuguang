import 'dart:async';
import 'dart:convert';

import 'package:crypto/crypto.dart';
import 'package:flutter/material.dart';

import 'config/subscription_repository.dart';
import 'config/subscription_batch.dart';
export 'config/subscription_batch.dart';
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
  String? homeCategory;
  VodPage? currentPage;
  bool busy = false;
  bool importing = false;
  bool batchImporting = false;
  List<SubscriptionImportItem> importQueue = [];
  int _batchGeneration = 0;
  String? error;
  String? sourceNotice;
  String? liveError;
  String? importError;
  List<RepoNode> importNodes = [];
  List<LiveChannel> liveChannels = [];
  final _liveLists = <String, List<LiveChannel>>{};
  int liveSourcesLoaded = 0, liveSourceCount = 0;
  ThemeMode themeMode = ThemeMode.system;
  int _generation = 0;
  int _searchGeneration = 0;
  int _liveGeneration = 0;
  int _importGeneration = 0;
  int _selectionGeneration = 0;
  bool _disposed = false;

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
    final disabled = jsonList(
      store.setting('disabled:${selected.url}'),
    ).map(str).toSet();
    final order = jsonList(
      store.setting('siteOrder:${selected.url}'),
    ).map(str).toList();
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
        !jsonList(
          store.setting('disabled:${selected.url}'),
        ).map(str).contains(site.key);
  }

  /// This published short-drama endpoint redirects to an unavailable server.
  /// Keep the original subscription intact and bind all data to a real sibling
  /// source, so details, playback and history never reuse another source's IDs.
  Site? shortDramaFallback(TvConfig config, Site site) {
    final uri = Uri.tryParse(site.api);
    if (site.type != 4 ||
        uri?.host != '38.76.197.172' ||
        uri?.port != 15151 ||
        uri?.path != '/duanju.php' ||
        uri?.queryParameters['type'] != 'dquark') {
      return null;
    }
    final available = enabledSites(config);
    for (final api in [
      'csp_HBmengyaCAT',
      'csp_HBhaokanCAT',
      'csp_HBQimaoCAT',
      'csp_HBWeiguanCAT',
    ]) {
      final fallback = available
          .where((s) => s.type == 3 && s.api == api)
          .firstOrNull;
      if (fallback != null) return fallback;
    }
    return null;
  }

  Future<void> setSiteEnabled(
    Site site,
    bool enabled, {
    TvConfig? config,
  }) async {
    final selected = config ?? currentConfig;
    if (selected == null) return;
    final disabled = jsonList(
      store.setting('disabled:${selected.url}'),
    ).map(str).toSet();
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
    return jsonMap(
      jsonDecode(stored),
    ).map((key, value) => MapEntry(key, str(value)));
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
          enabledSites(
            currentConfig,
          ).where((site) => site.key == siteKey).firstOrNull ??
          enabledSites(currentConfig).firstOrNull;
    }
    _notify();
  }

  Future<void> startHome() async {
    // No bundled subscription: nothing is fetched until the user adds a source.
    if (currentConfig != null && homePage == null) await refreshHome();
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
    liveError = null;
    error = null;
    busy = false;
    await initialize();
    if (currentSite != null) await refreshHome();
  }

  Future<void> importSubscription(String url) async {
    if (importing || batchImporting) return;
    importQueue = [];
    await _importSubscription(url);
  }

  Future<void> importSubscriptions(
    Iterable<String> addresses, {
    bool addOnly = false,
  }) async {
    if (importing || batchImporting) return;
    final urls = subscriptionUrls(addresses.join('\n'));
    final generation = ++_batchGeneration;
    batchImporting = true;
    importQueue = [for (final url in urls) SubscriptionImportItem(url)];
    _notify();
    try {
      for (var i = 0; i < urls.length; i++) {
        if (_disposed || generation != _batchGeneration) break;
        final existing = subscriptions
            .where((item) => item.url == urls[i])
            .firstOrNull;
        if (addOnly && existing != null && existing.configs.isNotEmpty) {
          importQueue[i] = SubscriptionImportItem(
            urls[i],
            status: 'existing',
            repositories: existing.configs.length,
          );
          _notify();
          continue;
        }
        importQueue[i] = SubscriptionImportItem(urls[i], status: 'loading');
        _notify();
        try {
          final result = await _importSubscription(urls[i]);
          if (_disposed || generation != _batchGeneration) break;
          final failed =
              result?.nodes.where((n) => n.error != null).length ?? 0;
          final count = result?.configs.length ?? 0;
          final diagnostics =
              result?.nodes
                  .where((node) => node.error != null)
                  .map((node) => node.error!)
                  .take(3)
                  .join('\n') ??
              '';
          importQueue[i] = SubscriptionImportItem(
            urls[i],
            status: count == 0
                ? 'error'
                : failed > 0
                ? 'partial'
                : 'ready',
            repositories: count,
            error: count == 0
                ? diagnostics.isNotEmpty
                      ? diagnostics
                      : importError ?? '没有可用仓库，请查看导入诊断'
                : failed > 0
                ? '$failed 个节点加载失败'
                : null,
          );
        } catch (failure) {
          if (_disposed || generation != _batchGeneration) break;
          importQueue[i] = SubscriptionImportItem(
            urls[i],
            status: 'error',
            error: failure.toString(),
          );
        }
        _notify();
      }
    } finally {
      importQueue = [
        for (final item in importQueue)
          if (item.status == 'queued' || item.status == 'loading')
            SubscriptionImportItem(item.url, status: 'cancelled')
          else
            item,
      ];
      batchImporting = false;
      _notify();
    }
  }

  String subscriptionName(String url) {
    final name = str(store.setting('subscriptionName:$url')).trim();
    final host = Uri.tryParse(url)?.host ?? '';
    return name.isNotEmpty
        ? name
        : host.isNotEmpty
        ? host
        : '本地订阅';
  }

  String configName(TvConfig? config) {
    if (config == null) return '未命名仓库';
    for (final value in [
      store.setting('subscriptionName:${config.url}'),
      config.name,
      config.raw['name'],
    ]) {
      final name = str(value).trim();
      if (name.isNotEmpty &&
          !RegExp(r'^https?://', caseSensitive: false).hasMatch(name)) {
        return name;
      }
    }
    return subscriptionName(config.url);
  }

  Future<void> renameSubscription(String url, String name) async {
    await store.setSetting(
      'subscriptionName:$url',
      name.trim().isEmpty ? null : name.trim(),
    );
    _notify();
  }

  Future<ImportResult?> _importSubscription(
    String url, {
    bool activate = true,
  }) async {
    final generation = ++_importGeneration;
    importing = true;
    importError = null;
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
      if (_disposed || generation != _importGeneration) return null;
      importNodes = result.nodes;
      await _acceptImport(result, activate: activate);
      return result;
    } catch (failure) {
      if (_disposed || generation != _importGeneration) return null;
      importError = failure.toString();
      rethrow;
    } finally {
      importing = false;
      _notify();
    }
  }

  Future<void> importText(String text, {String name = '本地配置'}) async {
    if (importing || batchImporting) return;
    final generation = ++_importGeneration;
    importing = true;
    importError = null;
    importNodes = [];
    _notify();
    try {
      final identity = sha256.convert(utf8.encode(text.trim())).toString();
      final result = await _subscriptions.loadText(
        text,
        name: name,
        baseUrl: 'https://local.invalid/imports/$identity/',
      );
      if (_disposed || generation != _importGeneration) return;
      importNodes = result.nodes;
      await _acceptImport(result);
    } catch (failure) {
      if (_disposed || generation != _importGeneration) return;
      importError = failure.toString();
      rethrow;
    } finally {
      importing = false;
      _notify();
    }
  }

  Future<void> _acceptImport(
    ImportResult result, {
    bool activate = true,
  }) async {
    await store.saveSubscription(result);
    if (result.configs.isEmpty) {
      importError = '没有可加载的单仓配置，请查看入口诊断';
    }
    if (!activate) return;
    final chosen =
        configs
            .where((config) => config.url == currentConfig?.url)
            .firstOrNull ??
        result.configs.firstOrNull ??
        configs.firstOrNull;
    if (chosen != null) {
      // Adding another subscription should preserve the current source and not
      // re-run its plugin initialization/login dialogs if its config is unchanged.
      if (!result.configs.any((config) => config.url == currentConfig?.url) &&
          currentConfig?.url == chosen.url &&
          jsonEncode(currentConfig?.toJson()) == jsonEncode(chosen.toJson()) &&
          currentSite != null) {
        currentConfig = chosen;
        _notify();
      } else {
        await selectConfig(chosen);
      }
    } else {
      importError = '没有可加载的单仓配置，请查看入口诊断';
    }
  }

  void cancelImport() {
    _batchGeneration++;
    _importGeneration++;
    _subscriptions.cancel();
  }

  Future<void> removeSubscription(String url) async {
    await removeSubscriptions([url]);
  }

  Future<void> removeSubscriptions(Iterable<String> urls) async {
    final removed = urls.toSet();
    if (removed.isEmpty) return;
    await store.removeSubscriptions(removed);
    _selectionGeneration++;
    final remaining = configs
        .where((config) => config.url == currentConfig?.url)
        .firstOrNull;
    if (remaining == null) {
      _generation++;
      _liveGeneration++;
      currentConfig = null;
      currentSite = null;
      homePage = null;
      homeCategory = null;
      currentPage = null;
      liveChannels = [];
      liveError = null;
      error = null;
      busy = false;
      await engine.closeSessions();
      if (configs.isNotEmpty) await selectConfig(configs.first);
    }
    _notify();
  }

  Future<void> selectConfig(TvConfig config) async {
    final siteKey = str(store.setting('site:${config.url}'));
    final site =
        enabledSites(config).where((site) => site.key == siteKey).firstOrNull ??
        enabledSites(config).firstOrNull;
    if (site != null) {
      await selectSource(config, site);
    } else {
      _selectionGeneration++;
      _generation++;
      currentConfig = config;
      currentSite = null;
      homePage = null;
      currentPage = null;
      busy = false;
      error = '此仓库没有可选择的站点';
      _notify();
      await store.setSettings({'currentConfig': config.url, 'currentSite': ''});
    }
  }

  Future<void> selectSite(Site site) async {
    final config = currentConfig;
    if (config == null) throw const SourceFailure('no-source', '请先选择仓库');
    await selectSource(config, site);
  }

  /// Bind the repository and its site before any storage or network await.
  /// A superseded selection must never resume against a newer repository.
  Future<void> selectSource(TvConfig config, Site site) async {
    final requested = enabledSites(
      config,
    ).where((candidate) => candidate.key == site.key).firstOrNull;
    if (requested == null) {
      throw const SourceFailure('site-mismatch', '此内容源不属于所选仓库或已停用');
    }
    final fallback = shortDramaFallback(config, requested);
    final selected = fallback ?? requested;
    final selection = ++_selectionGeneration;
    _generation++;
    currentConfig = config;
    currentSite = selected;
    homePage = null;
    homeCategory = null;
    currentPage = null;
    busy = true;
    error = null;
    sourceNotice = fallback == null
        ? null
        : '全网短剧服务暂不可用，已切换同仓备用：${fallback.name}';
    _notify();
    await store.setSettings({
      'currentConfig': config.url,
      'currentSite': selected.key,
      'site:${config.url}': selected.key,
    });
    if (selection != _selectionGeneration || _disposed) return;
    await refreshHome();
  }

  Future<void> refreshHome() async {
    final config = currentConfig;
    final site = currentSite;
    if (config == null || site == null) return;
    if (shortDramaFallback(config, site) != null) {
      await selectSource(config, site);
      return;
    }
    final generation = ++_generation;
    busy = true;
    error = null;
    homeCategory = null;
    _notify();
    try {
      final page = await engine.home(config, site);
      if (generation != _generation || _disposed) return;
      homePage = page;
      currentPage = page;
      if (page.items.isEmpty && page.categories.isNotEmpty) {
        Object? categoryError;
        var loaded = false;
        // Many TVBox sites only implement categoryContent. Their empty home
        // recommendation is not evidence that the repository has no videos.
        _notify();
        for (final category in page.categories.take(3)) {
          try {
            final videos = await engine.category(config, site, category.id);
            if (generation != _generation || _disposed) return;
            loaded = true;
            currentPage = videos;
            homeCategory = category.id;
            if (videos.items.isNotEmpty) break;
          } catch (failure) {
            if (generation != _generation || _disposed) return;
            categoryError = failure;
          }
        }
        if (!loaded && categoryError != null) error = categoryError.toString();
      }
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

  Future<void> loadLive() async {
    final generation = ++_liveGeneration;
    liveError = null;
    liveSourcesLoaded = 0;
    final repositories = {for (final config in configs) config.url: config};
    if (currentConfig != null) {
      repositories[currentConfig!.url] = currentConfig!;
    }
    final jobs =
        <
          ({
            String key,
            TvConfig? config,
            Site? site,
            dynamic entry,
            String label,
          })
        >[];
    for (final config in repositories.values) {
      final sites = enabledSites(config);
      final site =
          config.url == currentConfig?.url && currentSite?.runtime == 'jar'
          ? currentSite
          : sites
                    .where(
                      (s) =>
                          s.key == str(store.setting('site:${config.url}')) &&
                          s.runtime == 'jar',
                    )
                    .firstOrNull ??
                sites.where((s) => s.runtime == 'jar').firstOrNull;
      for (final entry in config.lives) {
        if (entry is Map && entry.isEmpty) continue;
        final name = entry is Map
            ? str(entry['name'] ?? entry['url'])
            : str(entry);
        jobs.add((
          key: jsonEncode([config.url, entry]),
          config: config,
          site: site,
          entry: entry,
          label: '${configName(config)} · $name',
        ));
      }
    }
    for (final url in jsonList(
      store.setting('liveSubscriptions'),
    ).map(str).toSet()) {
      jobs.add((
        key: 'subscription:$url',
        config: null,
        site: null,
        entry: {'url': url},
        label: '直播订阅',
      ));
    }
    liveSourceCount = jobs.length;
    final activeKeys = jobs.map((job) => job.key).toSet();
    _liveLists.removeWhere((key, _) => !activeKeys.contains(key));
    final results = <String, List<LiveChannel>>{};
    final failures = <String>[];
    void publish() {
      if (generation != _liveGeneration || _disposed) return;
      final unique = <String, LiveChannel>{};
      for (final job in jobs) {
        for (final channel
            in results[job.key] ?? _liveLists[job.key] ?? <LiveChannel>[]) {
          final key = jsonEncode([
            channel.name,
            channel.group,
            channel.urls,
            channel.headers,
            channel.urls.any(
                  (url) => [
                    '127.0.0.1',
                    'localhost',
                    '::1',
                  ].contains(Uri.tryParse(url)?.host),
                )
                ? channel.configUrl
                : '',
          ]);
          unique.putIfAbsent(key, () => channel);
        }
      }
      liveChannels = unique.values.toList();
      liveError = failures.isEmpty ? null : failures.join('\n');
      _notify();
    }

    publish();
    _notify();
    var next = 0;
    Future<void> worker() async {
      while (next < jobs.length) {
        if (generation != _liveGeneration || _disposed) return;
        final job = jobs[next++];
        final issues = <String>[];
        try {
          final raw = job.entry is Map
              ? jsonMap(job.entry)
              : <String, dynamic>{};
          final url = str(raw['url']);
          if (Uri.decodeFull(url).contains('切换成你自己的地址')) {
            throw const LiveException('此来源只提供了占位地址，未配置频道列表');
          }
          final loaded = await _live
              .load(
                [job.entry],
                baseUrl: job.config?.url,
                localFetcher: job.config == null || job.site == null
                    ? null
                    : (url) => engine.fetchLocal(job.config!, job.site!, url),
                onError: issues.add,
              )
              .timeout(const Duration(seconds: 35));
          if (generation != _liveGeneration || _disposed) return;
          final channels = loaded
              .map(
                (channel) => LiveChannel(
                  name: channel.name,
                  urls: channel.urls,
                  group: channel.group,
                  logo: channel.logo,
                  tvgId: channel.tvgId,
                  epg: channel.epg,
                  headers: channel.headers,
                  configUrl: job.config?.url ?? '',
                  siteKey: job.site?.key ?? '',
                  sourceName: job.label,
                ),
              )
              .toList();
          if (channels.isNotEmpty || issues.isEmpty) {
            results[job.key] = channels;
            _liveLists[job.key] = channels;
          }
          failures.addAll(issues.map((issue) => '${job.label}: $issue'));
        } catch (failure) {
          if (generation != _liveGeneration || _disposed) return;
          failures.add('${job.label}: $failure');
        }
        liveSourcesLoaded++;
        publish();
      }
    }

    await Future.wait(List.generate(jobs.length.clamp(0, 4), (_) => worker()));
  }

  Future<Playback> playLive(LiveChannel channel, {int index = 0}) {
    final config = channel.configUrl.isEmpty
        ? currentConfig
        : configs
              .where((config) => config.url == channel.configUrl)
              .firstOrNull;
    final site = channel.siteKey.isEmpty
        ? null
        : config?.sites
              .where((site) => site.key == channel.siteKey)
              .firstOrNull;
    return engine.playLive(
      config,
      site ?? (channel.configUrl.isEmpty ? currentSite : null),
      channel,
      index: index,
    );
  }

  Future<void> addLiveSubscription(String url) =>
      addLiveSubscriptions([url]).then((_) {});

  Future<int> addLiveSubscriptions(Iterable<String> addresses) async {
    final urls = jsonList(store.setting('liveSubscriptions')).map(str).toSet();
    final before = urls.length;
    urls.addAll(subscriptionUrls(addresses.join('\n')));
    final added = urls.length - before;
    if (added > 0) {
      await store.setSetting('liveSubscriptions', urls.toList());
      await loadLive();
    }
    return added;
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
