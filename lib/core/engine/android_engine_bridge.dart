import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';
import 'dart:typed_data';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

import 'source_engine_api.g.dart';

const _maxJsonBytes = 2 * 1024 * 1024;
final _secureRandom = Random.secure();
String _opaque(int bytes) => base64UrlEncode(
  List<int>.generate(bytes, (_) => _secureRandom.nextInt(256)),
).replaceAll('=', '');

bool _privateV4(InternetAddress address) {
  if (address.type != InternetAddressType.IPv4) return false;
  final b = address.rawAddress;
  return b[0] == 127 ||
      b[0] == 10 ||
      (b[0] == 172 && b[1] >= 16 && b[1] <= 31) ||
      (b[0] == 192 && b[1] == 168);
}

Uri _endpoint(String value) {
  final parsed = Uri.tryParse(value.trim());
  if (parsed == null ||
      !{'http', 'https'}.contains(parsed.scheme) ||
      parsed.userInfo.isNotEmpty ||
      parsed.hasQuery ||
      parsed.hasFragment ||
      (parsed.path.isNotEmpty && parsed.path != '/') ||
      parsed.port < 1 ||
      parsed.port > 65535) {
    throw const FormatException('引擎地址应为局域网 HTTP(S) origin，不含路径、凭据或查询参数');
  }
  final host = parsed.host.toLowerCase() == 'localhost'
      ? '127.0.0.1'
      : parsed.host;
  final address = InternetAddress.tryParse(host);
  if (address == null || !_privateV4(address)) {
    throw const FormatException('引擎地址仅支持私有局域网或 loopback IPv4');
  }
  return parsed.replace(host: address.address, path: '');
}

bool _constantEquals(String a, String b) {
  var difference = a.length ^ b.length;
  for (var i = 0; i < a.length; i++) {
    difference |= a.codeUnitAt(i) ^ (i < b.length ? b.codeUnitAt(i) : 0);
  }
  return difference == 0;
}

Future<Uint8List> _bounded(Stream<List<int>> stream, int limit) async {
  final builder = BytesBuilder(copy: false);
  await for (final chunk in stream) {
    if (builder.length + chunk.length > limit) {
      throw const _BridgeError('too-large', '请求或结果超过 2 MiB', 413);
    }
    builder.add(chunk);
  }
  return builder.takeBytes();
}

Future<Uint8List> _rpcBody(HttpRequest request) {
  final complete = Completer<Uint8List>();
  final builder = BytesBuilder(copy: false);
  // Keep draining an oversized body until the response closes the connection;
  // cancelling HttpRequest's subscription before replying loses the 413 envelope.
  request.listen(
    (chunk) {
      if (complete.isCompleted) return;
      if (builder.length + chunk.length > _maxJsonBytes) {
        complete.completeError(
          const _BridgeError('too-large', '请求超过 2 MiB', 413),
        );
      } else {
        builder.add(chunk);
      }
    },
    onDone: () {
      if (!complete.isCompleted) complete.complete(builder.takeBytes());
    },
    onError: (Object error, StackTrace stack) {
      if (!complete.isCompleted) complete.completeError(error, stack);
    },
  );
  return complete.future;
}

class _BridgeError implements Exception {
  const _BridgeError(
    this.code,
    this.message, [
    this.status = 400,
    this.details,
  ]);
  final String code;
  final String message;
  final int status;
  final Object? details;
}

/// Transport adapter only: DEX/JAR execution remains in Android's native engine.
/// No token is ever added to a URL, diagnostic message, or application backup.
class AndroidEngineBridgeApi extends SourceEngineApi {
  AndroidEngineBridgeApi({
    required String endpoint,
    required String token,
    this.timeout = const Duration(seconds: 45),
    HttpClient? httpClient,
  }) : endpoint = _endpoint(endpoint),
       _token = token.trim(),
       _http = httpClient ?? HttpClient() {
    if (_token.isEmpty || _token.contains(RegExp(r'[\s\r\n]'))) {
      throw const FormatException('请输入 Android 服务显示的完整令牌');
    }
    _http.findProxy = (_) => 'DIRECT';
    _http.autoUncompress = false;
    _http.connectionTimeout = timeout;
  }

  static const connectionSecretKey = 'androidEngineBridge.connection';
  final Uri endpoint;
  String get endpointUrl => endpoint.origin;
  final String _token;
  final Duration timeout;
  final HttpClient _http;
  final Set<String> _sessions = {};
  final Set<Future<String>> _opening = {};
  bool _closing = false;
  bool _disposed = false;
  int _nextId = 0;

  static String validateEndpoint(String value) => _endpoint(value).origin;

  Future<Object?> _call(String method, List<Object?> args) async {
    if (_disposed) {
      throw PlatformException(
        code: 'bridge-closed',
        message: 'Android 引擎连接已关闭',
      );
    }
    HttpClientRequest? request;
    final id = ++_nextId;
    try {
      return await (() async {
        final bytes = utf8.encode(
          jsonEncode({'id': id, 'method': method, 'args': args}),
        );
        if (bytes.length > _maxJsonBytes) {
          throw PlatformException(code: 'too-large', message: '引擎请求超过 2 MiB');
        }
        request = await _http.postUrl(endpoint.resolve('/rpc'));
        request!.followRedirects = false;
        request!.headers
          ..contentType = ContentType.json
          ..set(HttpHeaders.authorizationHeader, 'Bearer $_token')
          ..set('X-Engine-Timeout-Ms', max(1, timeout.inMilliseconds - 100));
        request!.contentLength = bytes.length;
        request!.add(bytes);
        final response = await request!.close();
        final raw = await _bounded(response, _maxJsonBytes);
        final Object? value;
        try {
          value = jsonDecode(utf8.decode(raw));
        } catch (_) {
          throw PlatformException(
            code: 'bridge-envelope',
            message: 'Android 引擎返回了无效响应',
          );
        }
        if (value is! Map ||
            (value['id'] != id &&
                !(value['id'] == null && value['error'] is Map))) {
          throw PlatformException(
            code: 'bridge-envelope',
            message: 'Android 引擎响应标识不匹配',
          );
        }
        if (value['error'] case final Map error) {
          throw PlatformException(
            code: error['code'] is String
                ? error['code'] as String
                : 'bridge-error',
            message: error['message'] is String
                ? error['message'] as String
                : 'Android 引擎请求失败',
            details: error['details'],
          );
        }
        if (response.statusCode != 200 || !value.containsKey('result')) {
          throw PlatformException(
            code: 'bridge-http',
            message: 'Android 引擎响应状态 ${response.statusCode}',
          );
        }
        return value['result'];
      })().timeout(timeout);
    } on TimeoutException {
      request?.abort();
      throw PlatformException(
        code: 'bridge-timeout',
        message: 'Android 引擎请求超时',
      );
    } on PlatformException {
      rethrow;
    } on _BridgeError catch (error) {
      throw PlatformException(
        code: error.code,
        message: error.message,
        details: error.details,
      );
    } catch (_) {
      request?.abort();
      throw PlatformException(
        code: 'bridge-network',
        message: 'Android 引擎连接中断，请检查同网及前台服务',
      );
    }
  }

  Future<String> _string(String method, List<Object?> args) async {
    final result = await _call(method, args);
    if (result is! String) {
      throw PlatformException(
        code: 'bridge-envelope',
        message: 'Android 引擎结果类型不匹配',
      );
    }
    return result;
  }

  @override
  Future<String> openSession(String configJson, String siteJson) {
    if (_closing || _disposed) {
      return Future.error(
        PlatformException(code: 'bridge-closed', message: 'Android 引擎连接已关闭'),
      );
    }
    late final Future<String> opening;
    opening = (() async {
      try {
        final id = await _string('openSession', [configJson, siteJson]);
        if (_closing || _disposed) {
          try {
            await _call('closeSession', [id]);
          } catch (_) {}
          throw PlatformException(
            code: 'bridge-closed',
            message: 'Android 引擎连接已关闭',
          );
        }
        _sessions.add(id);
        return id;
      } finally {
        _opening.remove(opening);
      }
    })();
    _opening.add(opening);
    return opening;
  }

  @override
  Future<String> home(String sessionId, bool filter) =>
      _string('home', [sessionId, filter]);
  @override
  Future<String> category(
    String sessionId,
    String tid,
    int page,
    String filtersJson,
  ) => _string('category', [sessionId, tid, page, filtersJson]);
  @override
  Future<String> search(String sessionId, String keyword, int page) =>
      _string('search', [sessionId, keyword, page]);
  @override
  Future<String> detail(String sessionId, String id) =>
      _string('detail', [sessionId, id]);
  @override
  Future<String> play(String sessionId, String flag, String id) =>
      _string('play', [sessionId, flag, id]);
  @override
  Future<String> resolve(
    String sessionId,
    String resultJson,
    String parserJson,
  ) async {
    final text = await _string('resolve', [sessionId, resultJson, parserJson]);
    final result = jsonDecode(text);
    if (result is! Map<String, dynamic> || result['url'] is! String) {
      throw PlatformException(
        code: 'bridge-envelope',
        message: 'Android 引擎未返回播放地址',
      );
    }
    final url = Uri.tryParse(result['url'] as String);
    if (url != null &&
        !url.hasScheme &&
        RegExp(r'^/media/[A-Za-z0-9_-]{32}$').hasMatch(url.toString())) {
      result['url'] = endpoint.resolveUri(url).toString();
    } else if (url == null ||
        !{'http', 'https', 'rtmp', 'rtsp', 'rtp', 'udp'}.contains(url.scheme) ||
        _nativeLoopback(url)) {
      throw PlatformException(
        code: 'bridge-media',
        message: 'Android 引擎返回的本机媒体地址尚未桥接',
      );
    }
    return jsonEncode(result);
  }

  @override
  Future<String> fetchLocal(String sessionId, String url) =>
      _string('fetchLocal', [sessionId, url]);
  @override
  Future<void> cancel(String sessionId) async {
    await _call('cancel', [sessionId]);
  }

  @override
  Future<void> closeSession(String sessionId) async {
    try {
      await _call('closeSession', [sessionId]);
    } finally {
      _sessions.remove(sessionId);
    }
  }

  @override
  Future<String> capabilities() => _string('capabilities', []);

  Future<void> dispose() async {
    if (_disposed || _closing) return;
    _closing = true;
    await Future.wait(
      _opening.toList().map((future) async {
        try {
          await future;
        } catch (_) {}
      }),
    );
    await Future.wait(
      _sessions.toList().map((id) async {
        try {
          await closeSession(id);
        } catch (_) {}
      }),
    );
    _disposed = true;
    _http.close(force: true);
  }
}

bool _nativeLoopback(Uri uri) {
  if (!{'http', 'https'}.contains(uri.scheme) ||
      uri.userInfo.isNotEmpty ||
      uri.hasFragment) {
    return false;
  }
  if (uri.host.toLowerCase() == 'localhost' ||
      uri.host == '::1' ||
      uri.host == '[::1]') {
    return true;
  }
  final host = InternetAddress.tryParse(uri.host);
  return host != null &&
      host.type == InternetAddressType.IPv4 &&
      host.rawAddress[0] == 127;
}

class _Session {
  _Session(this.nativeId, this.owner);
  final String nativeId;
  final String owner;
  final Set<String> mediaOrigins = {};
}

class _Media {
  _Media(this.session, this.uri);
  final String session;
  final Uri uri;
}

class _Lease {
  bool active = true;
  String? session;
  String? nativeId;
}

/// Explicit foreground LAN service, backed by the existing Pigeon native API.
/// Passing [native] permits deterministic offline transport tests on a desktop.
class AndroidEngineBridgeService extends ChangeNotifier {
  AndroidEngineBridgeService({
    SourceEngineApi? native,
    this.requestTimeout = const Duration(seconds: 40),
    this.idleTimeout = const Duration(minutes: 10),
    HttpClient? mediaClient,
  }) : _native = native ?? SourceEngineApi(),
       _injected = native != null,
       _mediaHttp = mediaClient ?? HttpClient() {
    _mediaHttp.findProxy = (_) => 'DIRECT';
    _mediaHttp.autoUncompress = false;
    _mediaHttp.connectionTimeout = requestTimeout;
  }

  final SourceEngineApi _native;
  final bool _injected;
  final Duration requestTimeout;
  final Duration idleTimeout;
  final HttpClient _mediaHttp;
  final Map<String, _Session> _sessions = {};
  final Map<String, _Media> _media = {};
  final Map<String, String> _mediaKeys = {};
  final Map<HttpClientRequest, String> _upstream = {};
  HttpServer? _server;
  Timer? _idleTimer;
  String? _token;
  DateTime? _expiresAt;
  int _generation = 0;
  bool _disposed = false;
  bool _starting = false;
  bool get running => _server != null;
  String? get token => _token;
  DateTime? get expiresAt => _expiresAt;
  List<String> get addresses => _server == null
      ? []
      : ['http://${_server!.address.address}:${_server!.port}'];

  static Future<List<InternetAddress>> localAddresses() async => [
    for (final interface in await NetworkInterface.list(
      type: InternetAddressType.IPv4,
      includeLoopback: false,
    ))
      for (final address in interface.addresses)
        if (_privateV4(address) && !address.isLoopback) address,
  ];

  Future<void> start({InternetAddress? address, int port = 0}) async {
    if (_disposed) throw StateError('Bridge service disposed');
    if (running || _starting) return;
    if (!Platform.isAndroid && !_injected) {
      throw const _BridgeError('android-only', '请在 Android 设备开启原生引擎服务');
    }
    _starting = true;
    final generation = ++_generation;
    try {
      final available = address == null
          ? await localAddresses()
          : <InternetAddress>[];
      final bind =
          address ??
          (available.isEmpty ? InternetAddress.loopbackIPv4 : available.first);
      if (!_privateV4(bind)) {
        throw const FormatException('服务仅绑定私有局域网或 loopback IPv4');
      }
      final server = await HttpServer.bind(bind, port, shared: false);
      if (_disposed || generation != _generation) {
        await server.close(force: true);
        return;
      }
      _server = server;
      _token = _opaque(32);
      server.idleTimeout = requestTimeout;
      server.listen((request) {
        unawaited(_handle(request));
      }, onError: (Object _) {});
      _touch();
      _notify();
    } finally {
      _starting = false;
    }
  }

  void _notify() {
    if (!_disposed) notifyListeners();
  }

  void _touch() {
    if (!running) return;
    _idleTimer?.cancel();
    _expiresAt = DateTime.now().add(idleTimeout);
    _idleTimer = Timer(idleTimeout, () {
      unawaited(stop());
    });
  }

  Future<void> stop() async {
    ++_generation;
    _idleTimer?.cancel();
    _idleTimer = null;
    final server = _server;
    _server = null;
    _token = null;
    _expiresAt = null;
    final sessions = _sessions.values.toList();
    _sessions.clear();
    _media.clear();
    _mediaKeys.clear();
    for (final request in _upstream.keys.toList()) {
      request.abort();
    }
    _upstream.clear();
    await server?.close(force: true);
    await Future.wait(
      sessions.map((session) => _closeNative(session.nativeId)),
    );
    _notify();
  }

  Future<void> _closeNative(String id) async {
    try {
      await _native.closeSession(id).timeout(requestTimeout);
    } catch (_) {}
  }

  void _checkRequest(HttpRequest request) {
    final server = _server;
    if (server == null) throw const _BridgeError('stopped', '服务已停止', 503);
    if (request.headers['origin'] != null) {
      throw const _BridgeError('origin', '引擎服务不接受 Origin', 403);
    }
    final hosts = request.headers[HttpHeaders.hostHeader];
    final expected = '${server.address.address}:${server.port}';
    if (hosts == null || hosts.length != 1 || hosts.single != expected) {
      throw const _BridgeError('host', 'Host 与服务绑定地址不匹配', 403);
    }
    final remote = request.connectionInfo?.remoteAddress;
    if (remote == null || !_privateV4(remote)) {
      throw const _BridgeError('peer', '仅接受局域网连接', 403);
    }
    if (request.uri.hasQuery || request.uri.hasFragment) {
      throw const _BridgeError('path', '服务路径不接受查询参数', 400);
    }
  }

  Future<void> _handle(HttpRequest request) async {
    Object? id;
    final lease = _Lease();
    var mediaStarted = false;
    try {
      _checkRequest(request);
      if (request.uri.path.startsWith('/media/')) {
        mediaStarted = true;
        await _serveMedia(request);
        return;
      }
      final requestedTimeout = int.tryParse(
        request.headers.value('X-Engine-Timeout-Ms') ?? '',
      );
      final totalTimeout =
          requestedTimeout != null &&
              requestedTimeout > 0 &&
              requestedTimeout < requestTimeout.inMilliseconds
          ? Duration(milliseconds: requestedTimeout)
          : requestTimeout;
      await (() async {
        if (request.uri.path != '/rpc') {
          throw const _BridgeError('not-found', '路径不存在', 404);
        }
        if (request.method != 'POST') {
          throw const _BridgeError('method', 'RPC 仅接受 POST', 405);
        }
        final auth = request.headers[HttpHeaders.authorizationHeader];
        if (auth == null ||
            auth.length != 1 ||
            !_constantEquals(auth.single, 'Bearer $_token')) {
          throw const _BridgeError('authentication', '引擎令牌不匹配', 401);
        }
        if (request.headers.contentType?.mimeType != 'application/json') {
          throw const _BridgeError('content-type', 'RPC 仅接受 JSON', 415);
        }
        if (request.contentLength > _maxJsonBytes) {
          throw const _BridgeError('too-large', '请求超过 2 MiB', 413);
        }
        final bytes = await _rpcBody(request);
        final Object? decoded;
        try {
          decoded = jsonDecode(utf8.decode(bytes));
        } catch (_) {
          throw const _BridgeError('json', 'JSON 请求格式无效');
        }
        if (decoded is! Map ||
            decoded['id'] is! int ||
            decoded['method'] is! String ||
            decoded['args'] is! List) {
          throw const _BridgeError('envelope', 'RPC envelope 格式无效');
        }
        id = decoded['id'];
        _touch();
        final owner = _token!;
        final result = await _dispatch(
          decoded['method'] as String,
          decoded['args'] as List,
          owner,
          lease,
        );
        if (!lease.active || !running) {
          throw const _BridgeError('stopped', '服务已停止', 503);
        }
        await _json(request.response, 200, {'id': id, 'result': result});
      })().timeout(totalTimeout);
    } catch (error) {
      lease.active = false;
      final created = lease.session;
      if (created != null) {
        final session = _sessions[created];
        _revoke(created);
        if (session != null) unawaited(_closeNative(session.nativeId));
      }
      if (mediaStarted) {
        try {
          request.response.statusCode = 502;
          await request.response.close();
        } catch (_) {}
      } else {
        final _BridgeError failure;
        if (error is _BridgeError) {
          failure = error;
        } else if (error is PlatformException) {
          failure = _BridgeError(
            error.code,
            error.message ?? '原生引擎请求失败',
            400,
            error.details,
          );
        } else if (error is TimeoutException) {
          final nativeId = lease.nativeId;
          if (nativeId != null) {
            unawaited(
              _native
                  .cancel(nativeId)
                  .timeout(requestTimeout)
                  .catchError((Object _) {}),
            );
          }
          failure = const _BridgeError(
            'bridge-timeout',
            'Android 原生引擎请求超时',
            504,
          );
        } else if (error is MissingPluginException) {
          failure = const _BridgeError(
            'engine-missing',
            '安装包未包含 Android 原生引擎',
            503,
          );
        } else {
          failure = const _BridgeError('bridge-error', 'Android 引擎请求失败', 500);
        }
        try {
          await _json(request.response, failure.status, {
            'id': id,
            'error': {
              'code': failure.code,
              'message': failure.message,
              'details': failure.details,
            },
          });
        } catch (_) {}
      }
    } finally {
      lease.active = false;
    }
  }

  Future<void> _json(
    HttpResponse response,
    int status,
    Map<String, Object?> body,
  ) async {
    final bytes = utf8.encode(jsonEncode(body));
    if (bytes.length > _maxJsonBytes) {
      throw const _BridgeError('too-large', '结果超过 2 MiB', 413);
    }
    response.statusCode = status;
    response.headers
      ..contentType = ContentType.json
      ..set(HttpHeaders.cacheControlHeader, 'no-store')
      ..set('X-Content-Type-Options', 'nosniff');
    response.contentLength = bytes.length;
    response.add(bytes);
    await response.close();
  }

  void _args(List args, List<Type> types) {
    if (args.length != types.length) {
      throw const _BridgeError('arguments', 'RPC 参数数量错误');
    }
    for (var i = 0; i < args.length; i++) {
      if ((types[i] == String && args[i] is! String) ||
          (types[i] == int && args[i] is! int) ||
          (types[i] == bool && args[i] is! bool)) {
        throw const _BridgeError('arguments', 'RPC 参数类型错误');
      }
    }
  }

  _Session _session(String id, String owner) {
    final session = _sessions[id];
    if (session == null || !_constantEquals(owner, session.owner)) {
      throw const _BridgeError('session', '引擎会话不存在或已关闭', 404);
    }
    return session;
  }

  Future<Object?> _dispatch(
    String method,
    List args,
    String owner,
    _Lease lease,
  ) async {
    const methods = {
      'openSession': [String, String],
      'home': [String, bool],
      'category': [String, String, int, String],
      'search': [String, String, int],
      'detail': [String, String],
      'play': [String, String, String],
      'resolve': [String, String, String],
      'fetchLocal': [String, String],
      'cancel': [String],
      'closeSession': [String],
      'capabilities': <Type>[],
    };
    final types = methods[method];
    if (types == null) throw const _BridgeError('method', 'RPC 方法未开放', 405);
    _args(args, types);
    if (method == 'capabilities') return _native.capabilities();
    if (method == 'openSession') {
      if (_sessions.length >= 64) {
        throw const _BridgeError('sessions', '活动会话数量已达上限', 429);
      }
      final generation = _generation;
      final nativeId = await _native.openSession(
        args[0] as String,
        args[1] as String,
      );
      if (!lease.active ||
          !running ||
          generation != _generation ||
          owner != _token) {
        await _closeNative(nativeId);
        throw const _BridgeError('stopped', '会话初始化已过期', 503);
      }
      final id = _opaque(24);
      _sessions[id] = _Session(nativeId, owner);
      lease.session = id;
      return id;
    }
    final id = args.first as String;
    final session = _session(id, owner);
    final n = session.nativeId;
    lease.nativeId = n;
    switch (method) {
      case 'home':
        return _native.home(n, args[1] as bool);
      case 'category':
        return _native.category(
          n,
          args[1] as String,
          args[2] as int,
          args[3] as String,
        );
      case 'search':
        return _native.search(n, args[1] as String, args[2] as int);
      case 'detail':
        return _native.detail(n, args[1] as String);
      case 'play':
        return _native.play(n, args[1] as String, args[2] as String);
      case 'fetchLocal':
        return _native.fetchLocal(n, args[1] as String);
      case 'cancel':
        await _native.cancel(n);
        return null;
      case 'closeSession':
        _revoke(id);
        await _native.closeSession(n);
        return null;
      case 'resolve':
        final text = await _native.resolve(
          n,
          args[1] as String,
          args[2] as String,
        );
        _session(id, owner);
        if (!lease.active || !running) {
          throw const _BridgeError('stopped', '解析请求已过期', 503);
        }
        final result = jsonDecode(text);
        if (result is! Map<String, dynamic> || result['url'] is! String) {
          throw const _BridgeError('resolve', '原生引擎未返回有效播放地址');
        }
        final uri = Uri.tryParse(result['url'] as String);
        if (uri != null && _nativeLoopback(uri)) {
          _sessions[id]!.mediaOrigins.add(_normalizeNative(uri).origin);
          result['url'] = _registerMedia(id, uri);
          // Native proxy owns source headers. Never leak its loopback credentials.
          result['header'] = <String, String>{};
          result.remove('headers');
        }
        return jsonEncode(result);
      default:
        throw const _BridgeError('method', 'RPC 方法未开放', 405);
    }
  }

  void _revoke(String id) {
    for (final entry in _upstream.entries.toList()) {
      if (entry.value == id) {
        entry.key.abort();
        _upstream.remove(entry.key);
      }
    }
    _sessions.remove(id);
    _media.removeWhere((_, value) => value.session == id);
    _mediaKeys.removeWhere((key, _) => key.startsWith('$id\n'));
  }

  Uri _normalizeNative(Uri uri) => uri.host.toLowerCase() == 'localhost'
      ? uri.replace(host: '127.0.0.1')
      : uri;

  String _registerMedia(String session, Uri uri) {
    if (!_sessions.containsKey(session) || !_nativeLoopback(uri)) {
      throw const _BridgeError('media', '媒体映射已过期', 404);
    }
    final normalized = _normalizeNative(uri);
    if (!_sessions[session]!.mediaOrigins.contains(normalized.origin)) {
      throw const _BridgeError('media-origin', '媒体地址不是本会话原生代理 origin', 502);
    }
    final key = '$session\n$normalized';
    final existing = _mediaKeys[key];
    if (existing != null) return '/media/$existing';
    if (_media.length >= 16384) {
      throw const _BridgeError('media-limit', '媒体映射数量已达上限', 429);
    }
    final opaque = _opaque(24);
    _media[opaque] = _Media(session, normalized);
    _mediaKeys[key] = opaque;
    return '/media/$opaque';
  }

  String _playlist(String text, _Media media) {
    String rewrite(String raw) {
      final target = _normalizeNative(media.uri.resolve(raw));
      // Only native-origin loopback links discovered in its own playlist enter
      // the table. No RPC/URL parameter can register a caller-selected target.
      if (!_nativeLoopback(target) ||
          !_sessions[media.session]!.mediaOrigins.contains(target.origin)) {
        throw const _BridgeError('media-origin', '播放列表包含非原生代理地址', 502);
      }
      return _registerMedia(media.session, target);
    }

    return text
        .split('\n')
        .map((line) {
          final trimmed = line.trim();
          if (trimmed.isEmpty) return line;
          if (!trimmed.startsWith('#')) return rewrite(trimmed);
          return line.replaceAllMapped(
            RegExp(r'URI="([^"]+)"'),
            (m) => 'URI="${rewrite(m[1]!)}"',
          );
        })
        .join('\n');
  }

  Future<void> _serveMedia(HttpRequest request) async {
    if (request.method != 'GET' && request.method != 'HEAD') {
      throw const _BridgeError('method', '媒体仅接受 GET/HEAD', 405);
    }
    final opaque = request.uri.path.substring('/media/'.length);
    final media = RegExp(r'^[A-Za-z0-9_-]{32}$').hasMatch(opaque)
        ? _media[opaque]
        : null;
    if (media == null || !_sessions.containsKey(media.session)) {
      request.response.statusCode = 404;
      await request.response.close();
      return;
    }
    _touch();
    var openingActive = true;
    final opening = _mediaHttp.openUrl(request.method, media.uri).then((value) {
      if (!openingActive || !_sessions.containsKey(media.session) || !running) {
        value.abort();
      }
      return value;
    });
    final HttpClientRequest upstream;
    try {
      upstream = await opening.timeout(requestTimeout);
    } catch (_) {
      openingActive = false;
      rethrow;
    }
    if (!_sessions.containsKey(media.session) || !running) {
      upstream.abort();
      return;
    }
    _upstream[upstream] = media.session;
    upstream.followRedirects = false;
    for (final header in [
      HttpHeaders.rangeHeader,
      HttpHeaders.ifRangeHeader,
      HttpHeaders.ifNoneMatchHeader,
      HttpHeaders.ifModifiedSinceHeader,
    ]) {
      final value = request.headers[header];
      if (value != null && value.length == 1) {
        upstream.headers.set(header, value.single);
      }
    }
    try {
      final response = await upstream.close().timeout(requestTimeout);
      // Redirects are not followed: Location is neither exposed nor registered.
      if (response.isRedirect) {
        throw const _BridgeError('media-redirect', '原生媒体代理返回了重定向', 502);
      }
      if (!_sessions.containsKey(media.session) || !running) {
        upstream.abort();
        return;
      }
      request.response.statusCode = response.statusCode;
      request.response.bufferOutput = false;
      request.response.headers.set(HttpHeaders.cacheControlHeader, 'no-store');
      final mime =
          response.headers.contentType?.mimeType ?? 'application/octet-stream';
      final iterator = StreamIterator<List<int>>(
        response.timeout(requestTimeout),
      );
      try {
        final prefix = BytesBuilder(copy: false);
        if (request.method != 'HEAD') {
          while (prefix.length < 7 && await iterator.moveNext()) {
            prefix.add(iterator.current);
          }
        }
        final first = prefix.takeBytes();
        final isHls =
            mime.toLowerCase().contains('mpegurl') ||
            media.uri.path.toLowerCase().endsWith('.m3u8') ||
            (first.length >= 7 &&
                ascii.decode(first.take(7).toList(), allowInvalid: true) ==
                    '#EXTM3U');
        if (isHls &&
            request.method != 'HEAD' &&
            response.statusCode >= 200 &&
            response.statusCode < 300) {
          if (response.statusCode != 200) {
            throw const _BridgeError('playlist-range', '部分播放列表响应不可重写', 502);
          }
          final builder = BytesBuilder(copy: false)..add(first);
          while (await iterator.moveNext()) {
            if (builder.length + iterator.current.length > _maxJsonBytes) {
              throw const _BridgeError('too-large', '播放列表超过 2 MiB', 502);
            }
            builder.add(iterator.current);
          }
          if (builder.length > _maxJsonBytes) {
            throw const _BridgeError('too-large', '播放列表超过 2 MiB', 502);
          }
          final rewritten = utf8.encode(
            _playlist(utf8.decode(builder.takeBytes()), media),
          );
          request.response.headers.contentType = ContentType(
            'application',
            'vnd.apple.mpegurl',
          );
          request.response.contentLength = rewritten.length;
          request.response.add(rewritten);
        } else {
          for (final header in [
            HttpHeaders.contentTypeHeader,
            HttpHeaders.contentRangeHeader,
            HttpHeaders.acceptRangesHeader,
            HttpHeaders.etagHeader,
            HttpHeaders.lastModifiedHeader,
            HttpHeaders.contentEncodingHeader,
          ]) {
            final values = response.headers[header];
            if (values != null) request.response.headers.set(header, values);
          }
          if (response.contentLength >= 0) {
            request.response.contentLength = response.contentLength;
          }
          if (request.method != 'HEAD') {
            if (first.isNotEmpty) {
              request.response.add(first);
              await request.response.flush();
            }
            while (await iterator.moveNext()) {
              if (!_sessions.containsKey(media.session) || !running) {
                upstream.abort();
                break;
              }
              _touch();
              request.response.add(iterator.current);
              // Flush provides backpressure rather than buffering entire media.
              await request.response.flush();
            }
          }
        }
        await request.response.close();
      } finally {
        await iterator.cancel();
      }
    } finally {
      upstream.abort();
      _upstream.remove(upstream);
    }
  }

  @override
  void dispose() {
    _disposed = true;
    unawaited(stop());
    _mediaHttp.close(force: true);
    super.dispose();
  }
}
