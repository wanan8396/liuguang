import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:isolate';
import 'dart:math';

import 'package:flutter/services.dart';

import '../models/models.dart';
import '../network/app_http_client.dart';
import 'js_worker.dart';
import 'source_engine.dart' show SourceFailure;

/// Windows/iOS single-file JS + drpy runtime. Android retains its native engine.
class JsSourceEngine {
  JsSourceEngine(this.http);
  final AppHttpClient http;
  final _sessions = <String, Future<_JsSession>>{};
  final _instances = <_JsSession>{};
  bool _closed = false;
  int _generation = 0;

  Future<Map<String, dynamic>> call(
    TvConfig config,
    Site site,
    String method,
    List<Object?> args,
  ) async {
    if (_closed) throw const SourceFailure('closed', 'JS 引擎已经关闭');
    final generation = _generation;
    final key = jsonEncode([config.toJson(), site.toJson()]);
    final future = _sessions.putIfAbsent(key, () async {
      final url = Uri.parse(config.url).resolve(site.api).toString();
      final embedded = str(site.raw['_jsSource']);
      final source = embedded.isNotEmpty
          ? embedded
          : utf8.decode(
              (await http.fetch(
                url,
                headers: SourceEngineHeaders.of(config, site),
              )).bytes,
            );
      if (generation != _generation || _closed) {
        throw const SourceFailure('cancelled', 'JS 初始化已取消');
      }
      final session = await _JsSession.open(
        source: source,
        ext: site.ext,
        onCreated: (session) {
          if (generation != _generation || _closed) {
            throw const SourceFailure('cancelled', 'JS 初始化已取消');
          }
          _instances.add(session);
        },
      );
      if (generation != _generation || _closed) {
        await session.close();
        throw const SourceFailure('cancelled', 'JS 初始化已取消');
      }
      return session;
    });
    try {
      final session = await future;
      final value = jsonMap(jsonDecode(await session.call(method, args)));
      if (method == 'home' && jsonList(value['list']).isEmpty) {
        final recommendations = jsonMap(
          jsonDecode(await session.call('homeVod', const [])),
        );
        if (recommendations['list'] is List) {
          value['list'] = recommendations['list'];
        }
      }
      if (generation != _generation || _closed) {
        throw const SourceFailure('cancelled', 'JS 请求已取消');
      }
      return value;
    } catch (error) {
      if (identical(_sessions[key], future)) _sessions.remove(key);
      try {
        await (await future).close();
      } catch (_) {
        /* initialization failed */
      }
      if (error is SourceFailure) rethrow;
      throw SourceFailure('js-runtime', 'JS 源执行失败：$error', error.toString());
    }
  }

  Future<void> closeSessions() async {
    _generation++;
    _sessions.clear();
    final active = _instances.toList();
    _instances.clear();
    await Future.wait(active.map((session) => session.close()));
  }

  Future<void> dispose() async {
    _closed = true;
    await closeSessions();
  }
}

// Kept here to avoid recursively constructing SourceEngine inside JS sessions.
class SourceEngineHeaders {
  static Map<String, String> of(TvConfig config, Site site) {
    final result = <String, String>{};
    final host = Uri.parse(config.url).resolve(site.api).host;
    for (final raw in jsonList(config.raw['headers'])) {
      final item = jsonMap(raw), rule = str(jsonMap(raw)['host']);
      if (rule.isNotEmpty && (host == rule || host.endsWith('.$rule'))) {
        result.addAll(
          jsonMap(item['header']).map((k, v) => MapEntry(k, str(v))),
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
}

class _JsSession {
  _JsSession(this.server, this.token);
  final HttpServer server;
  final String token;
  final _client = HttpClient()..connectionTimeout = const Duration(seconds: 15);
  final _messages = ReceivePort();
  final _ready = Completer<SendPort>();
  final _stopped = Completer<void>();
  final _pending = <int, Completer<String>>{};
  Isolate? _isolate;
  SendPort? _commands;
  int _nextId = 0;
  bool _closed = false;
  String get _base => 'http://127.0.0.1:${server.port}/$token';

  static Future<_JsSession> open({
    required String source,
    dynamic ext,
    required void Function(_JsSession) onCreated,
  }) async {
    final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    final random = Random.secure();
    final token = List.generate(
      24,
      (_) => random.nextInt(256).toRadixString(16).padLeft(2, '0'),
    ).join();
    final session = _JsSession(server, token);
    // Attach the error handler before a concurrent close can cancel startup.
    unawaited(
      session._ready.future.then<void>(
        (_) {},
        onError: (Object _, StackTrace _) {},
      ),
    );
    try {
      onCreated(session);
      final host = await rootBundle.loadString('assets/js/host.js');
      final bundle = await rootBundle.loadString('assets/js/drpy.bundle.js');
      if (session._closed) throw const SourceFailure('cancelled', 'JS 初始化已取消');
      session.server.listen(session._serve);
      session._messages.listen(session._receive);
      session._isolate = await Isolate.spawn(
        runJsWorker,
        {
          'output': session._messages.sendPort,
          'host': host,
          'bundle': bundle,
          'source': source,
          'ext': ext,
          'requestUrl': '${session._base}/request',
          'proxyUrl': '${session._base}/proxy?',
        },
        onError: session._messages.sendPort,
        onExit: session._messages.sendPort,
      );
      session._commands = await session._ready.future.timeout(
        const Duration(seconds: 45),
      );
      return session;
    } catch (_) {
      await session.close();
      rethrow;
    }
  }

  void _receive(dynamic message) {
    if (message == null || message is Map && message['closed'] == true) {
      if (!_stopped.isCompleted) _stopped.complete();
      if (_closed) return;
    }
    if (message is Map && message['ready'] is SendPort) {
      if (!_ready.isCompleted) _ready.complete(message['ready'] as SendPort);
    } else if (message is Map && message.containsKey('id')) {
      final pending = _pending.remove(message['id']);
      if (pending == null) return;
      if (message['error'] != null) {
        pending.completeError(StateError('${message['error']}'));
      } else {
        pending.complete('${message['result']}');
      }
    } else {
      final error = StateError('JS worker exited: $message');
      if (!_ready.isCompleted) _ready.completeError(error);
      for (final pending in _pending.values) {
        pending.completeError(error);
      }
      _pending.clear();
    }
  }

  Future<String> call(String method, List<Object?> args) async {
    if (_closed) throw const SourceFailure('cancelled', 'JS 会话已关闭');
    final id = ++_nextId;
    final result = Completer<String>();
    _pending[id] = result;
    _commands!.send({'id': id, 'method': method, 'args': args});
    try {
      return await result.future.timeout(const Duration(seconds: 45));
    } on TimeoutException {
      await close();
      throw const SourceFailure('js-timeout', 'JS 源执行超时，请切换源重试');
    } finally {
      _pending.remove(id);
    }
  }

  Future<void> _serve(HttpRequest request) async {
    try {
      if (_closed || request.uri.pathSegments.firstOrNull != token) {
        request.response.statusCode = 404;
        await request.response.close();
        return;
      }
      if (request.uri.path == '/$token/request' && request.method == 'POST') {
        final input = <int>[];
        await for (final chunk in request.timeout(
          const Duration(seconds: 30),
        )) {
          input.addAll(chunk);
          if (input.length > 8 * 1024 * 1024) {
            throw StateError('JS request exceeds 8MiB');
          }
        }
        final args = jsonList(jsonDecode(utf8.decode(input)));
        Object envelope;
        try {
          envelope = {
            'result': await _request(
              str(args[0]),
              jsonMap(args[1]),
            ).timeout(const Duration(seconds: 30)),
          };
        } catch (error) {
          envelope = {'error': error.toString()};
        }
        final bytes = utf8.encode(jsonEncode(envelope));
        request.response.headers.contentType = ContentType.json;
        request.response.contentLength = bytes.length;
        request.response.add(bytes);
      } else if (request.uri.path == '/$token/proxy') {
        final raw = jsonDecode(
          await call('proxy', [request.uri.queryParameters]),
        );
        final parts = jsonList(raw);
        if (parts.length < 3) {
          throw StateError('JS proxy returned invalid response');
        }
        request.response.statusCode = intValue(parts[0], 200);
        request.response.headers.set('Content-Type', str(parts[1]));
        if (parts.length > 3 && parts[3] is Map) {
          jsonMap(parts[3]).forEach(
            (name, value) => request.response.headers.set(name, str(value)),
          );
        }
        final body = parts[2];
        final bytes = body is List
            ? body.map((v) => intValue(v)).toList()
            : parts.length > 4 && intValue(parts[4]) == 1
            ? base64Decode(str(body).split('base64,').last)
            : utf8.encode(str(body));
        request.response.contentLength = bytes.length;
        request.response.add(bytes);
      } else {
        request.response.statusCode = 404;
      }
    } catch (_) {
      request.response.statusCode = 502;
    } finally {
      await request.response.close();
    }
  }

  Future<Map<String, dynamic>> _request(
    String url,
    Map<String, dynamic> options,
  ) async {
    var uri = normalizeHttpUrl(url);
    var method = str(options['method']).toUpperCase();
    if (method.isEmpty) method = 'GET';
    var headers = jsonMap(
      options['headers'],
    ).map((k, v) => MapEntry(k, str(v)));
    Object? data = options['data'] ?? options['body'];
    if (data is Map) {
      final contentType =
          headers.entries
              .where((e) => e.key.toLowerCase() == 'content-type')
              .firstOrNull
              ?.value ??
          '';
      data = options['postType'] == 'form' || !contentType.contains('json')
          ? data.entries
                .map(
                  (e) =>
                      '${Uri.encodeQueryComponent('${e.key}')}=${Uri.encodeQueryComponent('${e.value}')}',
                )
                .join('&')
          : jsonEncode(data);
    }
    for (var redirect = 0; ; redirect++) {
      final outgoing = await _client.openUrl(method, uri);
      outgoing.followRedirects = false;
      outgoing.headers.set('User-Agent', 'okhttp/4.9.1');
      headers.forEach((k, v) => outgoing.headers.set(k, v));
      if (method != 'GET' && method != 'HEAD' && data != null) {
        if (!headers.keys.any((k) => k.toLowerCase() == 'content-type')) {
          outgoing.headers.contentType = ContentType(
            'application',
            'x-www-form-urlencoded',
            charset: 'utf-8',
          );
        }
        outgoing.add(utf8.encode(str(data)));
      }
      final response = await outgoing.close();
      final location = response.headers.value('location');
      if ([301, 302, 303, 307, 308].contains(response.statusCode) &&
          location != null &&
          options['redirect'] != 0 &&
          options['redirect'] != false) {
        if (redirect >= 8) {
          await response.drain<void>();
          throw StateError('Too many JS HTTP redirects');
        }
        final next = normalizeHttpUrl(uri.resolve(location).toString());
        if (uri.origin != next.origin) {
          headers = Map.of(headers)
            ..removeWhere(
              (k, _) => {
                'authorization',
                'cookie',
                'proxy-authorization',
              }.contains(k.toLowerCase()),
            );
        }
        if (response.statusCode == 303 ||
            ([301, 302].contains(response.statusCode) && method == 'POST')) {
          method = 'GET';
          data = null;
        }
        await response.drain<void>();
        uri = next;
        continue;
      }
      final bytes = <int>[];
      await for (final chunk in response) {
        bytes.addAll(chunk);
        if (bytes.length > 8 * 1024 * 1024) {
          throw StateError('JS response exceeds 8MiB');
        }
      }
      final buffer = intValue(options['buffer']);
      final encoding =
          Encoding.getByName(
            str(options['charset']).isNotEmpty
                ? str(options['charset'])
                : response.headers.contentType?.charset ?? 'utf-8',
          ) ??
          utf8;
      final responseHeaders = <String, List<String>>{};
      response.headers.forEach(
        (name, values) => responseHeaders[name] = values,
      );
      return {
        'code': response.statusCode,
        'url': uri.toString(),
        'headers': responseHeaders,
        'content': buffer == 1
            ? bytes
            : buffer == 2
            ? base64Encode(bytes)
            : encoding.decode(bytes),
      };
    }
  }

  Future<void> close() async {
    if (_closed) return;
    _closed = true;
    _client.close(force: true);
    await server.close(force: true);
    _commands?.send({'id': 0, 'method': '__close', 'args': <Object?>[]});
    if (_commands != null) {
      try {
        await _stopped.future.timeout(const Duration(milliseconds: 500));
      } on TimeoutException {
        /* blocked source: fall back to isolate cancellation */
      }
    }
    _isolate?.kill(priority: Isolate.immediate);
    _messages.close();
    if (!_ready.isCompleted) {
      _ready.completeError(const SourceFailure('cancelled', 'JS 初始化已取消'));
    }
    final error = const SourceFailure('cancelled', 'JS 会话已关闭');
    for (final pending in _pending.values) {
      if (!pending.isCompleted) pending.completeError(error);
    }
    _pending.clear();
  }
}
