import 'dart:convert';
import 'dart:io';

import 'package:flutter/services.dart';
import 'package:xml/xml.dart';

import '../models/models.dart';
import '../network/app_http_client.dart';
import 'source_engine_api.g.dart';

class SourceFailure implements Exception {
  const SourceFailure(this.code, this.message, [this.details]);
  final String code;
  final String message;
  final Object? details;
  @override
  String toString() => '$message [$code]';
}

class SourceEngine {
  SourceEngine(this.http, {SourceEngineApi? native, bool? isAndroid})
    : _native = native ?? SourceEngineApi(),
      _isAndroid = isAndroid ?? Platform.isAndroid;

  final AppHttpClient http;
  final SourceEngineApi _native;
  final bool _isAndroid;
  final Map<String, Future<String>> _sessions = {};
  int _sessionGeneration = 0;
  int _requestGeneration = 0;
  bool _disposed = false;
  bool pluginsTrusted = false;
  bool Function(TvConfig config)? isTrusted;
  Future<Map<String, String>> Function(TvConfig config)? loadCredentials;

  String _key(TvConfig config, Site site) =>
      jsonEncode([config.toJson(), site.toJson()]);

  bool _isNative(Site site) => site.runtime == 'jar' || site.runtime == 'js';

  Future<String> _session(TvConfig config, Site site) async {
    if (_disposed) throw const SourceFailure('closed', '源引擎已经关闭');
    if (!_isAndroid) {
      throw const SourceFailure('platform', '该源需要 Android 原生运行引擎');
    }
    if (_isNative(site) && !(isTrusted?.call(config) ?? pluginsTrusted)) {
      throw const SourceFailure('plugin-consent', '请先在订阅管理中确认并信任此订阅的插件来源');
    }
    final key = _key(config, site);
    final existing = _sessions[key];
    if (existing != null) return existing;
    final generation = _sessionGeneration;
    final future = () async {
      final credentials =
          await loadCredentials?.call(config) ?? <String, String>{};
      if (_disposed || generation != _sessionGeneration ||
          (_isNative(site) && !(isTrusted?.call(config) ?? pluginsTrusted))) {
        throw const SourceFailure('cancelled', '源初始化已取消或授权已撤销');
      }
      final payload = {
        ...config.toJson(),
        if (credentials.isNotEmpty) '_privateCredentials': credentials,
      };
      final id = await _invoke(
        () =>
            _native.openSession(jsonEncode(payload), jsonEncode(site.toJson())),
      );
      if (_disposed || generation != _sessionGeneration ||
          (_isNative(site) && !(isTrusted?.call(config) ?? pluginsTrusted))) {
        await _invoke(() => _native.closeSession(id));
        throw const SourceFailure('cancelled', '源初始化已取消或授权已撤销');
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

  Future<T> _dispatch<T>(TvConfig config, Site site, Future<T> Function(String id) call) async {
    final generation = _requestGeneration;
    final id = await _session(config, site);
    if (_disposed || generation != _requestGeneration ||
        (_isNative(site) && !(isTrusted?.call(config) ?? pluginsTrusted))) {
      throw const SourceFailure('cancelled', '源请求已取消或授权已撤销');
    }
    final result = await _invoke(() => call(id));
    if (_disposed || generation != _requestGeneration) {
      throw const SourceFailure('cancelled', '源请求已取消');
    }
    return result;
  }

  Future<VodPage> home(TvConfig config, Site site) async {
    _checkSite(site);
    if (_isNative(site)) {
      return VodPage.fromJson(
        _parseObject(await _dispatch(config, site, (id) => _native.home(id, true))),
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
    if (_isNative(site)) {
      return VodPage.fromJson(
        _parseObject(await _dispatch(config, site,
          (id) => _native.category(id, tid, page, jsonEncode(filters)))),
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
    if (_isNative(site)) {
      return VodPage.fromJson(
        _parseObject(await _dispatch(config, site,
          (id) => _native.search(id, keyword, page))),
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
    final Map<String, dynamic> result;
    if (_isNative(site)) {
      result = _parseObject(await _dispatch(config, site,
        (session) => _native.detail(session, id)));
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
    var result = <String, dynamic>{};
    if (_isNative(site)) {
      result = _parseObject(await _dispatch(config, site,
        (session) => _native.play(session, flag, id)));
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
    final requiresResolution =
        playback.parse ||
        intValue(result['jx']) != 0 ||
        str(result['playUrl']).isNotEmpty ||
        isLocal;
    if (requiresResolution) {
      final resolved = _parseObject(await _dispatch(config, site,
        (session) => _native.resolve(session, jsonEncode(result), jsonEncode(config.parses))));
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
    final explicitWebPage = uri.path.endsWith('.html') || uri.path.endsWith('.htm');
    if (!_isLoopback(url) && !explicitWebPage) {
      return Playback(url: url, headers: channel.headers);
    }
    final selectedConfig =
        config ?? TvConfig(url: url, name: '直播', raw: const {});
    final selectedSite = _isLoopback(url) && site != null
        ? site : Site({'key': '__live__', 'api': url, 'type': 4});
    final result = {
      'url': url,
      'header': channel.headers,
      'parse': _isLoopback(url) ? 0 : 1,
      'flag': 'live',
    };
    final resolved = Playback.fromJson(_parseObject(
      await _dispatch(selectedConfig, selectedSite,
        (session) => _native.resolve(session, jsonEncode(result), jsonEncode(selectedConfig.parses)))));
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
    return _dispatch(config, site, (session) => _native.fetchLocal(session, url));
  }

  Future<void> cancel() async {
    _requestGeneration++;
    _sessionGeneration++;
    final sessions = List<Future<String>>.of(_sessions.values);
    await Future.wait(
      sessions.map((future) async {
        try {
          final id = await future;
          await _invoke(() => _native.cancel(id));
        } catch (_) {
          // Failed initialization has no live native session to cancel.
        }
      }),
    );
  }

  Future<void> closeSessions() async {
    _requestGeneration++;
    _sessionGeneration++;
    final sessions = List<Future<String>>.of(_sessions.values);
    _sessions.clear();
    await Future.wait(
      sessions.map((future) async {
        try {
          final id = await future;
          await _invoke(() => _native.closeSession(id));
        } catch (_) {
          // Closing other sessions must continue after one plugin has crashed.
        }
      }),
    );
  }

  Future<Map<String, dynamic>> capabilities() async => _isAndroid
      ? _parseObject(await _invoke(_native.capabilities))
      : {
          'platform': Platform.operatingSystem,
          'cms': true,
          'remote': true,
          'jar': false,
          'js': false,
        };

  Future<void> dispose() async {
    _disposed = true;
    await closeSessions();
  }

  void _checkSite(Site site) {
    if (_disposed) throw const SourceFailure('closed', '源引擎已经关闭');
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
