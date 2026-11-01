import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';

import 'package:flutter/foundation.dart';

class PushRequest {
  const PushRequest({
    required this.url,
    required this.remoteAddress,
    required this.receivedAt,
  });
  final String url;
  final String remoteAddress;
  final DateTime receivedAt;
  String get type => 'subscription';
}

class PairingService extends ChangeNotifier {
  PairingService({required this.onSubscription});
  final Future<void> Function(String url) onSubscription;
  HttpServer? _server;
  Timer? _timer;
  String? code;
  DateTime? expiresAt;
  PushRequest? pending;
  String? error;
  bool accepting = false;
  List<String> addresses = [];
  final Map<String, List<DateTime>> _attempts = {};
  bool _disposed = false;
  bool get running => _server != null;

  Future<void> start({
    InternetAddress? address,
    Duration lifetime = const Duration(minutes: 10),
  }) async {
    if (_disposed) throw StateError('PairingService is closed');
    if (running) return;
    final bind = address ?? await _lanAddress();
    if (!bind.isLoopback && !_privateV4(bind.address)) {
      throw const FormatException('数据推送仅能在本机或局域网地址启用');
    }
    _server = await HttpServer.bind(bind, 0, shared: false);
    _server!.idleTimeout = const Duration(seconds: 10);
    code = (Random.secure().nextInt(900000) + 100000).toString();
    expiresAt = DateTime.now().add(lifetime);
    addresses = ['http://${bind.address}:${_server!.port}'];
    error = null;
    _attempts.clear();
    _timer = Timer(lifetime, () => unawaited(stop()));
    _server!.listen(
      (request) => unawaited(_handle(request)),
      onError: (Object failure) {
        error = failure.toString();
        _notify();
      },
    );
    _notify();
  }

  Future<InternetAddress> _lanAddress() async {
    final interfaces = await NetworkInterface.list(
      type: InternetAddressType.IPv4,
    );
    for (final interface in interfaces) {
      for (final address in interface.addresses) {
        if (!address.isLoopback && _privateV4(address.address)) return address;
      }
    }
    throw const SocketException('请先连接 Wi-Fi 局域网再启用数据推送');
  }

  static bool _privateV4(String address) {
    final bytes = address.split('.').map(int.tryParse).toList();
    if (bytes.length != 4 || bytes.any((b) => b == null || b < 0 || b > 255)) {
      return false;
    }
    return bytes[0] == 10 ||
        (bytes[0] == 192 && bytes[1] == 168) ||
        (bytes[0] == 172 && bytes[1]! >= 16 && bytes[1]! <= 31);
  }

  Future<void> _handle(HttpRequest request) async {
    try {
      request.response.headers.set('Cache-Control', 'no-store');
      request.response.headers.set('X-Content-Type-Options', 'nosniff');
      request.response.headers.set(
        'Content-Security-Policy',
        "default-src 'none'; style-src 'unsafe-inline'; form-action 'self'; frame-ancestors 'none'; base-uri 'none'",
      );
      final server = _server;
      if (server == null ||
          expiresAt == null ||
          DateTime.now().isAfter(expiresAt!)) {
        await _reply(request, HttpStatus.gone, '配对已结束');
        return;
      }
      final remote = request.connectionInfo?.remoteAddress;
      if (remote == null ||
          (!remote.isLoopback && !_privateV4(remote.address))) {
        await _reply(request, HttpStatus.forbidden, '仅接受局域网请求');
        return;
      }
      final host = request.headers.value('host');
      final expectedHost = '${server.address.address}:${server.port}';
      if (host != expectedHost) {
        await _reply(request, HttpStatus.forbidden, 'Host 不匹配');
        return;
      }
      if (request.method == 'GET' && request.uri.path == '/') {
        request.response.headers.contentType = ContentType.html;
        request.response.write(_page);
        await request.response.close();
        return;
      }
      if (request.method != 'POST' || request.uri.path != '/push') {
        await _reply(request, HttpStatus.notFound, '不存在的接口');
        return;
      }
      final origin = request.headers.value('origin');
      if (origin != null && origin != 'http://$expectedHost') {
        await _reply(request, HttpStatus.forbidden, '不接受跨站请求');
        return;
      }
      final now = DateTime.now();
      _attempts.removeWhere(
        (_, times) =>
            times.every((time) => now.difference(time).inMinutes >= 1),
      );
      final attempts = _attempts.putIfAbsent(remote.address, () => []);
      attempts.removeWhere((time) => now.difference(time).inMinutes >= 1);
      if (attempts.length >= 5 || _attempts.length > 64) {
        await _reply(request, HttpStatus.tooManyRequests, '请求过于频繁，请稍后再试');
        return;
      }
      attempts.add(now);
      if (request.contentLength > 8192) {
        await _reply(request, HttpStatus.requestEntityTooLarge, '请求过大');
        return;
      }
      final bytes = <int>[];
      await for (final chunk in request.timeout(const Duration(seconds: 10))) {
        bytes.addAll(chunk);
        if (bytes.length > 8192) throw const FormatException('请求超过 8 KB');
      }
      final text = utf8.decode(bytes);
      final Object? parsed =
          request.headers.contentType?.mimeType == 'application/json'
          ? jsonDecode(text)
          : Uri.splitQueryString(text);
      if (parsed is! Map || parsed['code'] != code) {
        await _reply(request, HttpStatus.unauthorized, '配对码错误');
        return;
      }
      if (parsed['type'] != null && parsed['type'] != 'subscription') {
        await _reply(request, HttpStatus.badRequest, '本接口仅接收订阅地址');
        return;
      }
      final url = parsed['url']?.toString().trim() ?? '';
      final uri = Uri.tryParse(url);
      if (uri == null ||
          !{'http', 'https'}.contains(uri.scheme) ||
          uri.host.isEmpty ||
          uri.userInfo.isNotEmpty ||
          url.length > 2048) {
        await _reply(request, HttpStatus.badRequest, '请输入有效的 HTTP/HTTPS 订阅地址');
        return;
      }
      if (pending != null || accepting) {
        await _reply(request, HttpStatus.conflict, '手机上还有待确认的订阅');
        return;
      }
      pending = PushRequest(
        url: url,
        remoteAddress: remote.address,
        receivedAt: now,
      );
      _notify();
      await _reply(request, HttpStatus.accepted, '已送达，请在手机上确认导入');
    } catch (failure) {
      try {
        await _reply(request, HttpStatus.badRequest, '请求无效：$failure');
      } catch (_) {
        // The sender may close the connection while the bounded body is read.
      }
    }
  }

  Future<void> _reply(HttpRequest request, int status, String message) async {
    request.response.statusCode = status;
    request.response.headers.contentType = ContentType.json;
    request.response.write(jsonEncode({'message': message}));
    await request.response.close();
  }

  Future<void> approvePending() async {
    final request = pending;
    if (request == null || accepting) return;
    pending = null;
    accepting = true;
    error = null;
    _notify();
    try {
      await onSubscription(request.url);
    } catch (failure) {
      error = failure.toString();
      rethrow;
    } finally {
      accepting = false;
      _notify();
    }
  }

  void rejectPending() {
    pending = null;
    _notify();
  }

  Future<void> stop() async {
    _timer?.cancel();
    _timer = null;
    final server = _server;
    _server = null;
    code = null;
    expiresAt = null;
    pending = null;
    addresses = [];
    _attempts.clear();
    await server?.close(force: true);
    _notify();
  }

  void _notify() {
    if (!_disposed) notifyListeners();
  }

  @override
  void dispose() {
    if (_disposed) return;
    _disposed = true;
    unawaited(stop());
    super.dispose();
  }
}

const _page =
    '''<!doctype html><html lang="zh-CN"><meta charset="utf-8"><meta name="viewport" content="width=device-width, initial-scale=1"><title>流光 · 订阅推送</title><style>body{font:16px system-ui;background:#f4f7fb;color:#172b42;max-width:460px;margin:8vh auto;padding:24px}form{background:white;padding:28px;border-radius:20px}h1{font-size:26px}label{display:block;margin-top:22px}input,button{box-sizing:border-box;width:100%;padding:14px;margin-top:8px;border:1px solid #ccd8e5;border-radius:10px;font:inherit}button{background:#2797f3;color:white;border:0;margin-top:26px}p{line-height:1.7;color:#62748a}</style><form method="post" action="/push"><h1>流光 · 订阅推送</h1><p>输入手机上显示的配对码。送达后仍需要在手机上确认导入。</p><input type="hidden" name="type" value="subscription"><label>配对码<input name="code" inputmode="numeric" pattern="[0-9]{6}" maxlength="6" required autocomplete="off"></label><label>订阅地址<input name="url" type="url" maxlength="2048" placeholder="https://example.com/config.json" required></label><button type="submit">发送到手机</button></form></html>''';
