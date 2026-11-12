import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/services.dart';
import 'package:xml/xml.dart';

import '../models/models.dart';
import '../network/app_http_client.dart';
import 'source_engine_api.g.dart';
import 'android_engine_bridge.dart';
import 'jar_compat.dart';
import 'native_web_sniffer.dart';
import 'js_source_engine.dart';
import 'web_sniffer.dart';

class SourceFailure implements Exception {
  const SourceFailure(this.code, this.message, [this.details]);
  final String code;
  final String message;
  final Object? details;
  @override
  String toString() => '$message [$code]';
}

class SourceEngine {
  SourceEngine(
    this.http, {
    SourceEngineApi? native,
    bool? isAndroid,
    NativeWebSniffer? webSniffer,
  }) : _native = native ?? SourceEngineApi(),
       _isAndroid = isAndroid ?? Platform.isAndroid,
       _webSniffer = webSniffer ?? NativeWebSniffer();

  final AppHttpClient http;
  final SourceEngineApi _native;
  final bool _isAndroid;
  final NativeWebSniffer _webSniffer;
  AndroidEngineBridgeApi? _androidBridge;
  String? get androidBridgeEndpoint => _androidBridge?.endpointUrl;

  /// Changes the execution host explicitly. JARs are local embedded JS by
  /// default; a configured bridge runs their DEX/Android ABI on that device.
  bool _bridgeChanging = false;
  Future<void> _bridgeChange = Future.value();

  Future<void> configureAndroidBridge(AndroidEngineBridgeApi? bridge) {
    _bridgeChanging = true;
    final next = _bridgeChange.then((_) async {
      if (_disposed) {
        await bridge?.dispose();
        throw const SourceFailure('closed', '源引擎已经关闭');
      }
      final previous = _androidBridge;
      if (identical(previous, bridge)) return;
      await closeSessions();
      if (_disposed) {
        await bridge?.dispose();
        throw const SourceFailure('closed', '源引擎已经关闭');
      }
      _androidBridge = bridge;
      await previous?.dispose();
    });
    final barrier = next.catchError((Object _) {});
    _bridgeChange = barrier;
    return next.whenComplete(() {
      if (identical(_bridgeChange, barrier)) _bridgeChanging = false;
    });
  }

  SourceEngineApi get _executionApi =>
      _isAndroid ? _native : _androidBridge ?? _native;
  late final JsSourceEngine _js = JsSourceEngine(http);
  final Map<String, Future<String>> _sessions = {};
  int _sessionGeneration = 0;
  int _requestGeneration = 0;
  bool _disposed = false;
  Future<Map<String, String>> Function(TvConfig config)? loadCredentials;

  String _key(TvConfig config, Site site) =>
      jsonEncode([config.toJson(), site.toJson()]);

  bool _isNative(Site site) =>
      site.runtime == 'jar' || (site.runtime == 'js' && _isAndroid);

  bool _isPortableJs(Site site) => site.runtime == 'js' && !_isAndroid;

  /// A JAR cannot run without Android's DEX loader. Some archives ship an
  /// embedded JavaScript spider, which the portable engine can execute; others
  /// are reported explicitly instead of failing later as a network error.
  bool _isPortableJar(Site site) =>
      site.runtime == 'jar' && !_isAndroid && _androidBridge == null;

  final Map<String, Future<Site>> _jarSites = {};

  Future<Site> _portableJarSite(TvConfig config, Site site) async {
    final key = _key(config, site);
    final generation = _sessionGeneration;
    final future = _jarSites.putIfAbsent(key, () async {
      final reference = site.jar.trim().isNotEmpty ? site.jar : config.spider;
      if (reference.trim().isEmpty) {
        throw const SourceFailure('jar-missing', '站点和仓库均未配置 JAR 地址');
      }
      final parts = reference.split(';md5;');
      if (parts.length > 2) {
        throw const SourceFailure('jar-checksum', 'JAR MD5 配置格式无效');
      }
      final target = Uri.parse(
        config.url,
      ).resolve(parts.first.trim()).toString();
      Map<String, String> headersFor(String url) =>
          SourceEngineHeaders.of(config, Site({...site.raw, 'api': url}));
      final headers = headersFor(target);
      String? expected = parts.length == 2 ? parts[1].trim() : null;
      if (expected != null &&
          {'http', 'https'}.contains(Uri.tryParse(expected)?.scheme)) {
        expected = utf8
            .decode(
              (await http.fetchPrefix(
                expected,
                headers: headersFor(expected),
                maxBytes: 1024,
              )).bytes,
            )
            .trim()
            .split(RegExp(r'\s+'))
            .first;
      }
      final JarInspection inspection;
      try {
        inspection = await JarCompat(
          http,
        ).inspect(target, headers, spider: site.api, expectedMd5: expected);
      } on JarInspectError catch (error) {
        throw SourceFailure('jar-unavailable', error.message, target);
      }
      if (_disposed || generation != _sessionGeneration) {
        throw const SourceFailure('cancelled', 'JAR 初始化已取消');
      }
      final script = inspection.embeddedJs;
      if (script == null || script.trim().isEmpty) {
        throw SourceFailure(
          'jar-android-required',
          inspection.hasDex
              ? '此 JAR 含 Android DEX，请在“Android 引擎连接”中连接同网设备执行'
              : '此 JAR 没有为当前站点声明 JS 入口，请配置 Android 引擎连接',
          target,
        );
      }
      return Site({
        ...site.raw,
        'api': Uri.parse(
          target,
        ).resolve(inspection.selectedEntry ?? 'spider.js').toString(),
        '_jsSource': script,
      });
    });
    try {
      final result = await future;
      if (_disposed || generation != _sessionGeneration) {
        throw const SourceFailure('cancelled', 'JAR 初始化已取消');
      }
      return result;
    } catch (_) {
      if (identical(_jarSites[key], future)) _jarSites.remove(key);
      rethrow;
    }
  }

  /// Runs one portable call against a JAR site's embedded script, if any.
  Future<Site> _jarBackedSite(TvConfig config, Site site) =>
      _portableJarSite(config, site);

  Future<String> _session(TvConfig config, Site site) async {
    if (_disposed) throw const SourceFailure('closed', '源引擎已经关闭');
    if (_bridgeChanging) {
      throw const SourceFailure('bridge-changing', '引擎连接切换中，请稍后重试');
    }
    if (!_isAndroid && _androidBridge == null) {
      throw const SourceFailure('platform', '请先连接同网 Android 引擎');
    }
    final api = _executionApi;
    final key = _key(config, site);
    final existing = _sessions[key];
    if (existing != null) return existing;
    final generation = _sessionGeneration;
    final future = () async {
      final credentials =
          await loadCredentials?.call(config) ?? <String, String>{};
      if (_disposed || generation != _sessionGeneration) {
        throw const SourceFailure('cancelled', '源初始化已取消');
      }
      final payload = {
        ...config.toJson(),
        if (credentials.isNotEmpty) '_privateCredentials': credentials,
      };
      final id = await _invoke(
        () => api.openSession(jsonEncode(payload), jsonEncode(site.toJson())),
      );
      if (_disposed || generation != _sessionGeneration) {
        await _invoke(() => api.closeSession(id));
        throw const SourceFailure('cancelled', '源初始化已取消');
      }
      return id;
    }();
    _sessions[key] = future;
    try {
      return await future;
    } catch (_) {
      if (identical(_sessions[key], future)) _sessions.remove(key);
      rethrow;
    }
  }

  Future<T> _invoke<T>(Future<T> Function() call) async {
    try {
      return await call();
    } on PlatformException catch (error) {
      throw SourceFailure(
        error.code,
        error.message ?? '原生源引擎执行失败',
        error.details,
      );
    } on MissingPluginException {
      throw const SourceFailure('engine-missing', '当前安装包未包含 Android 源引擎');
    }
  }

  Future<T> _dispatch<T>(
    TvConfig config,
    Site site,
    Future<T> Function(String id) call,
  ) async {
    final generation = _requestGeneration;
    final id = await _session(config, site);
    if (_disposed || generation != _requestGeneration) {
      throw const SourceFailure('cancelled', '源请求已取消');
    }
    final result = await _invoke(() => call(id));
    if (_disposed || generation != _requestGeneration) {
      throw const SourceFailure('cancelled', '源请求已取消');
    }
    return result;
  }

  Future<VodPage> home(TvConfig config, Site site) async {
    _checkSite(site);
    if (_isPortableJar(site)) {
      return home(config, await _jarBackedSite(config, site));
    }
    if (_isPortableJs(site)) {
      return VodPage.fromJson(await _js.call(config, site, 'home', [true]));
    }
    if (_isNative(site)) {
      return VodPage.fromJson(
        _parseObject(
          await _dispatch(config, site, (id) => _executionApi.home(id, true)),
        ),
      );
    }
    final result = await _request(
      config,
      site,
      site.type == 4 ? {'filter': 'true'} : {'ac': 'list'},
    );
    return VodPage.fromJson(result);
  }

  Future<VodPage> category(
    TvConfig config,
    Site site,
    String tid, {
    int page = 1,
    Map<String, dynamic> filters = const {},
  }) async {
    _checkSite(site);
    if (_isPortableJar(site)) {
      return category(
        config,
        await _jarBackedSite(config, site),
        tid,
        page: page,
        filters: filters,
      );
    }
    if (_isPortableJs(site)) {
      return VodPage.fromJson(
        await _js.call(config, site, 'category', [tid, page, true, filters]),
      );
    }
    if (_isNative(site)) {
      return VodPage.fromJson(
        _parseObject(
          await _dispatch(
            config,
            site,
            (id) => _executionApi.category(id, tid, page, jsonEncode(filters)),
          ),
        ),
      );
    }
    final params = <String, String>{'ac': 'detail', 't': tid, 'pg': '$page'};
    if (site.type == 4) {
      params['filter'] = 'true';
      params['extend'] = base64Encode(utf8.encode(jsonEncode(filters)));
    }
    return VodPage.fromJson(await _request(config, site, params));
  }

  Future<VodPage> search(
    TvConfig config,
    Site site,
    String keyword, {
    int page = 1,
  }) async {
    if (!site.searchable) {
      throw const SourceFailure('not-searchable', '此站点没有声明搜索能力');
    }
    _checkSite(site);
    if (_isPortableJar(site)) {
      return search(
        config,
        await _jarBackedSite(config, site),
        keyword,
        page: page,
      );
    }
    if (_isPortableJs(site)) {
      return VodPage.fromJson(
        await _js.call(config, site, 'search', [keyword, false, page]),
      );
    }
    if (_isNative(site)) {
      return VodPage.fromJson(
        _parseObject(
          await _dispatch(
            config,
            site,
            (id) => _executionApi.search(id, keyword, page),
          ),
        ),
      );
    }
    return VodPage.fromJson(
      await _request(config, site, {
        'ac': 'detail',
        'wd': keyword,
        'pg': '$page',
        if (site.type == 4) 'quick': 'false',
      }),
    );
  }

  Future<VodDetail> detail(TvConfig config, Site site, String id) async {
    _checkSite(site);
    if (_isPortableJar(site)) {
      return detail(config, await _jarBackedSite(config, site), id);
    }
    final Map<String, dynamic> result;
    if (_isPortableJs(site)) {
      result = await _js.call(config, site, 'detail', [id]);
    } else if (_isNative(site)) {
      result = _parseObject(
        await _dispatch(
          config,
          site,
          (session) => _executionApi.detail(session, id),
        ),
      );
    } else {
      result = await _request(config, site, {'ac': 'detail', 'ids': id});
    }
    final items = jsonList(result['list']);
    if (items.isEmpty) throw const SourceFailure('empty-detail', '源返回的详情为空');
    return VodDetail.fromVod(Vod(jsonMap(items.first)));
  }

  Future<Playback> play(
    TvConfig config,
    Site site,
    String flag,
    String id,
  ) async {
    _checkSite(site);
    if (_isPortableJar(site)) {
      return play(config, await _jarBackedSite(config, site), flag, id);
    }
    var result = <String, dynamic>{};
    if (_isPortableJs(site)) {
      result = await _js.call(config, site, 'play', [flag, id, config.flags]);
    } else if (_isNative(site)) {
      result = _parseObject(
        await _dispatch(
          config,
          site,
          (session) => _executionApi.play(session, flag, id),
        ),
      );
    } else if (site.type == 4) {
      result = await _request(config, site, {'play': id, 'flag': flag});
    } else {
      result = {'url': id, 'parse': _looksLikeMedia(id) ? 0 : 1, 'flag': flag};
    }
    if (str(result['url']).isEmpty) {
      throw const SourceFailure('empty-playback', '源未返回播放地址');
    }
    result['flag'] ??= flag;
    final playback = Playback.fromJson(result);
    final isLocal = _isLoopback(playback.url);
    final usesAndroidBridge =
        !_isAndroid && _androidBridge != null && site.runtime == 'jar';
    final requiresResolution =
        result['url'] is List ||
        playback.parse ||
        intValue(result['jx']) != 0 ||
        str(result['playUrl']).isNotEmpty ||
        isLocal ||
        // Android's proxy owns HTTP headers, redirects and HLS subrequests even
        // when the source already returned a direct media URL (parse=0).
        ((_isAndroid || usesAndroidBridge) &&
            {'http', 'https'}.contains(Uri.tryParse(playback.url)?.scheme));
    if (requiresResolution && !_isAndroid && !usesAndroidBridge) {
      return _resolvePortable(config, result);
    }
    if (requiresResolution) {
      final resolved = _parseObject(
        await _dispatch(
          config,
          site,
          (session) => _executionApi.resolve(
            session,
            jsonEncode(result),
            jsonEncode(config.parses),
          ),
        ),
      );
      final finalResult = Playback.fromJson(resolved);
      if (finalResult.parse || finalResult.url.isEmpty) {
        throw const SourceFailure('unresolved', '解析器尚未返回可播放地址');
      }
      _validatePlaybackUrl(finalResult.url);
      return finalResult;
    }
    _validatePlaybackUrl(playback.url);
    return playback;
  }

  Future<Playback> _resolvePortable(
    TvConfig config,
    Map<String, dynamic> raw,
  ) async {
    final generation = _requestGeneration;
    var expired = false;
    void check() {
      if (expired || _disposed || generation != _requestGeneration) {
        throw const SourceFailure('cancelled', '播放解析已取消');
      }
    }

    return _resolvePortableImpl(config, raw, check).timeout(
      const Duration(seconds: 40),
      onTimeout: () {
        expired = true;
        unawaited(_webSniffer.cancel());
        throw const SourceFailure('resolve-timeout', '播放解析超过 40 秒，请切换线路');
      },
    );
  }

  Future<Playback> _resolvePortableImpl(
    TvConfig config,
    Map<String, dynamic> raw,
    void Function() check,
  ) async {
    check();
    var result = Map<String, dynamic>.of(raw);
    if (result['url'] is List) {
      final choices = jsonList(result['url']);
      if (choices.isEmpty || choices.length.isOdd) {
        throw const SourceFailure('quality-list', '清晰度列表必须是名称和地址对');
      }
      final urls = <String>[];
      for (var i = 1; i < choices.length; i += 2) {
        final uri = Uri.tryParse(str(choices[i]));
        if (uri == null || !{'http', 'https'}.contains(uri.scheme)) {
          throw const SourceFailure('quality-list', '清晰度列表含无效地址');
        }
        urls.add(uri.toString());
      }
      result['url'] = urls.first;
    }
    var playback = Playback.fromJson(result);
    if (!playback.parse &&
        intValue(result['jx']) == 0 &&
        str(result['playUrl']).isEmpty) {
      _validatePlaybackUrl(playback.url);
      return playback;
    }

    // Android parser plugins run on an explicitly connected Android host.
    if (_androidBridge != null &&
        config.parses.any((p) => {2, 3}.contains(intValue(p['type'])))) {
      final resolved = _parseObject(
        await _dispatch(
          config,
          Site({'key': '__portable_parser__', 'api': config.url, 'type': 4}),
          (session) => _executionApi.resolve(
            session,
            jsonEncode(result),
            jsonEncode(config.parses),
          ),
        ),
      );
      check();
      final parsed = Playback.fromJson(resolved);
      if (!parsed.parse && parsed.url.isNotEmpty) {
        _validatePlaybackUrl(parsed.url);
        return parsed;
      }
    }

    // JSON parsers and browser parsers are distinct. An HTML parse=0 parser
    // prefix must not be fetched as JSON then accidentally discarded.
    for (final parser in config.parses) {
      if (intValue(parser['type']) != 1 || str(parser['url']).isEmpty) continue;
      check();
      try {
        final response = await http.fetch(
          '${parser['url']}${playback.url}',
          headers: playback.headers,
        );
        check();
        final parsed = jsonMap(jsonDecode(utf8.decode(response.bytes)));
        final data = parsed['data'] is Map ? jsonMap(parsed['data']) : parsed;
        if (str(data['url']).isEmpty) continue;
        final headers = <String, String>{
          ...playback.headers,
          ...jsonMap(
            data['header'] ?? data['headers'],
          ).map((key, value) => MapEntry(key, str(value))),
        };
        result = {...result, ...data, 'header': headers, 'playUrl': ''};
        result['parse'] = data['parse'] ?? 0;
        result['jx'] = data['jx'] ?? 0;
        playback = Playback.fromJson(result);
        if (!playback.parse && intValue(result['jx']) == 0) {
          _validatePlaybackUrl(playback.url);
          return playback;
        }
        break;
      } on SourceFailure {
        rethrow;
      } catch (_) {
        /* another configured parser may be available */
      }
    }

    final pages = <String>{
      if (str(result['playUrl']).isNotEmpty)
        '${result['playUrl']}${playback.url}',
      for (final parser in config.parses)
        if (intValue(parser['type']) == 0 && str(parser['url']).isNotEmpty)
          '${parser['url']}${playback.url}',
      playback.url,
    };
    for (final page in pages) {
      check();
      final uri = Uri.tryParse(page);
      if (uri == null || !{'http', 'https'}.contains(uri.scheme)) continue;
      if (_looksLikeMedia(page)) {
        return Playback(url: page, headers: playback.headers);
      }
      final hit = await _webSniffer.sniff(page, playback.headers);
      check();
      final discovered =
          hit ?? await WebSniffer(http).sniff(page, playback.headers);
      check();
      if (discovered == null) continue;
      _validatePlaybackUrl(discovered.url);
      return Playback.fromJson({
        ...result,
        'url': discovered.url,
        'parse': 0,
        'jx': 0,
        'playUrl': '',
        'header': discovered.headers,
      });
    }
    throw const SourceFailure(
      'unresolved',
      '网页嗅探和解析器未找到可播放地址；可切换线路或连接 Android 引擎',
    );
  }

  Future<Playback> playLive(
    TvConfig? config,
    Site? site,
    LiveChannel channel, {
    int index = 0,
  }) async {
    if (index < 0 || index >= channel.urls.length) {
      throw const SourceFailure('missing-live-line', '该频道没有对应的播放线路');
    }
    final url = channel.urls[index];
    _validatePlaybackUrl(url);
    final uri = Uri.parse(url);
    final explicitWebPage =
        uri.path.endsWith('.html') || uri.path.endsWith('.htm');
    if (!_isLoopback(url) && !explicitWebPage) {
      return Playback(url: url, headers: channel.headers);
    }
    final selectedConfig =
        config ?? TvConfig(url: url, name: '直播', raw: const {});
    final selectedSite = _isLoopback(url) && site != null
        ? site
        : Site({'key': '__live__', 'api': url, 'type': 4});
    final result = {
      'url': url,
      'header': channel.headers,
      'parse': _isLoopback(url) ? 0 : 1,
      'flag': 'live',
    };
    if (!_isAndroid) return _resolvePortable(selectedConfig, result);
    final resolved = Playback.fromJson(
      _parseObject(
        await _dispatch(
          selectedConfig,
          selectedSite,
          (session) => _executionApi.resolve(
            session,
            jsonEncode(result),
            jsonEncode(selectedConfig.parses),
          ),
        ),
      ),
    );
    if (resolved.parse || resolved.url.isEmpty) {
      throw const SourceFailure('unresolved-live', '频道尚未解析出可播放地址');
    }
    _validatePlaybackUrl(resolved.url);
    return resolved;
  }

  Future<String> fetchLocal(TvConfig config, Site site, String url) async {
    if (!_isLoopback(url)) {
      throw const SourceFailure('not-local', '只允许访问当前源的本机代理地址');
    }
    if (_isPortableJs(site) || _isPortableJar(site)) {
      return utf8.decode((await http.fetch(url)).bytes);
    }
    return _dispatch(
      config,
      site,
      (session) => _executionApi.fetchLocal(session, url),
    );
  }

  Future<void> cancel() async {
    _requestGeneration++;
    _sessionGeneration++;
    _jarSites.clear();
    final api = _executionApi;
    final sessions = List<Future<String>>.of(_sessions.values);
    await Future.wait([_js.closeSessions(), _webSniffer.cancel()]);
    await Future.wait(
      sessions.map((future) async {
        try {
          final id = await future;
          await _invoke(() => api.cancel(id));
        } catch (_) {
          // Failed initialization has no live native session to cancel.
        }
      }),
    );
  }

  Future<void> closeSessions() async {
    _requestGeneration++;
    _sessionGeneration++;
    _jarSites.clear();
    final api = _executionApi;
    final sessions = List<Future<String>>.of(_sessions.values);
    _sessions.clear();
    await Future.wait([_js.closeSessions(), _webSniffer.cancel()]);
    await Future.wait(
      sessions.map((future) async {
        try {
          final id = await future;
          await _invoke(() => api.closeSession(id));
        } catch (_) {
          // Closing other sessions must continue after one plugin has crashed.
        }
      }),
    );
  }

  Future<Map<String, dynamic>> capabilities() async => _isAndroid
      ? _parseObject(await _invoke(_executionApi.capabilities))
      : {
          'platform': Platform.operatingSystem,
          'cms': true,
          'remote': true,
          'jar': _androidBridge != null,
          'jarExecution': _androidBridge == null
              ? 'embedded-js'
              : 'android-bridge',
          'jarEmbeddedJs': true,
          'js': Platform.isWindows || Platform.isIOS || Platform.isMacOS,
          'jsModules': 'single-file',
          'sniffer': true,
          'webView': Platform.isWindows || Platform.isIOS || Platform.isMacOS,
        };

  Future<void> dispose() async {
    _disposed = true;
    await _bridgeChange;
    await closeSessions();
    await _js.dispose();
    await _webSniffer.dispose();
    await _androidBridge?.dispose();
    _androidBridge = null;
  }

  void _checkSite(Site site) {
    if (_disposed) throw const SourceFailure('closed', '源引擎已经关闭');
    if (_bridgeChanging) {
      throw const SourceFailure('bridge-changing', '引擎连接切换中，请稍后重试');
    }
    if (site.api.isEmpty) {
      throw const SourceFailure('missing-api', '站点没有配置 API');
    }
    if (!{'jar', 'js', 'cms', 'remote'}.contains(site.runtime)) {
      throw SourceFailure(
        'unsupported-runtime',
        '尚未实现此源运行协议：${site.runtime}',
        site.api,
      );
    }
  }

  Map<String, dynamic> _parseObject(String value) {
    try {
      final parsed = jsonDecode(value);
      if (parsed is! Map) throw const FormatException('not an object');
      return jsonMap(parsed);
    } catch (error) {
      throw SourceFailure(
        'invalid-source-result',
        '源返回了无法识别的数据',
        error.toString(),
      );
    }
  }

  Future<Map<String, dynamic>> _request(
    TvConfig config,
    Site site,
    Map<String, String> params,
  ) async {
    final uri = Uri.parse(config.url).resolve(site.api);
    if (uri.scheme != 'https' && uri.scheme != 'http') {
      throw const SourceFailure('invalid-api', '远程接口必须使用 HTTP 或 HTTPS');
    }
    final query = <String, dynamic>{...uri.queryParametersAll, ...params};
    final response = await http.fetch(
      uri.replace(queryParameters: query).toString(),
      headers: requestHeaders(config, site),
    );
    final text = utf8.decode(response.bytes).trim();
    if (site.type == 0 || text.startsWith('<?xml') || text.startsWith('<rss')) {
      return parseCmsXml(text);
    }
    return _parseObject(text);
  }

  static Map<String, String> requestHeaders(TvConfig config, Site site) {
    final result = <String, String>{};
    final host = Uri.tryParse(site.api)?.host ?? '';
    for (final item in jsonList(config.raw['headers'])) {
      final entry = jsonMap(item);
      final rule = str(entry['host']);
      if (rule.isNotEmpty && (host == rule || host.endsWith('.$rule'))) {
        result.addAll(
          jsonMap(entry['header']).map((k, v) => MapEntry(k, str(v))),
        );
      }
    }
    result.addAll(
      jsonMap(
        site.raw['header'] ?? site.raw['headers'],
      ).map((k, v) => MapEntry(k, str(v))),
    );
    return result;
  }

  static bool _looksLikeMedia(String value) =>
      RegExp(
        r'\.(m3u8|mp4|mkv|flv|mpd|ts|m4v|mp3|aac)([?#]|$)',
        caseSensitive: false,
      ).hasMatch(value) ||
      value.startsWith('rtsp://') ||
      value.startsWith('rtmp://');

  static bool _isLoopback(String value) {
    final host = Uri.tryParse(value)?.host;
    return host == 'localhost' ||
        host == '127.0.0.1' ||
        host == '::1' ||
        host == '[::1]';
  }

  static void _validatePlaybackUrl(String url) {
    final uri = Uri.tryParse(url);
    if (uri == null ||
        !{'http', 'https', 'rtmp', 'rtsp', 'rtp', 'udp'}.contains(uri.scheme)) {
      throw const SourceFailure('invalid-playback', '源返回的播放协议不受支持');
    }
  }
}

Map<String, dynamic> parseCmsXml(String text) {
  final doc = XmlDocument.parse(text);
  final classes = <Map<String, dynamic>>[];
  for (final element in doc.findAllElements('class')) {
    for (final type in element.findElements('ty')) {
      classes.add({
        'type_id': type.getAttribute('id') ?? '',
        'type_name': type.innerText,
      });
    }
  }
  final lists = doc.findAllElements('list');
  final listNode = lists.isEmpty ? null : lists.first;
  final videos = <Map<String, dynamic>>[];
  for (final video in doc.findAllElements('video')) {
    String value(String key) => video.getElement(key)?.innerText ?? '';
    final names = <String>[];
    final links = <String>[];
    for (final dd in video.findAllElements('dd')) {
      names.add(dd.getAttribute('flag') ?? '播放');
      links.add(dd.innerText);
    }
    videos.add({
      'vod_id': value('id'),
      'vod_name': value('name'),
      'vod_pic': value('pic'),
      'vod_remarks': value('note'),
      'vod_content': value('des'),
      'vod_year': value('year'),
      'vod_area': value('area'),
      'vod_actor': value('actor'),
      'vod_director': value('director'),
      'vod_play_from': names.join(r'$$$'),
      'vod_play_url': links.join(r'$$$'),
    });
  }
  return {
    'class': classes,
    'list': videos,
    'page': intValue(listNode?.getAttribute('page'), 1),
    'pagecount': intValue(listNode?.getAttribute('pagecount'), 1),
    'total': intValue(listNode?.getAttribute('recordcount'), videos.length),
  };
}
