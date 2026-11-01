import 'dart:async';
import 'dart:convert';
import 'dart:io' show HandshakeException;
import 'dart:typed_data';

import 'package:dio/dio.dart';

class FetchResult {
  const FetchResult({
    required this.bytes,
    required this.finalUrl,
    required this.statusCode,
    required this.headers,
  });
  final Uint8List bytes;
  final String finalUrl;
  final int statusCode;
  final Map<String, List<String>> headers;
}

class AppHttpException implements Exception {
  const AppHttpException(
    this.code,
    this.message, {
    this.url,
    this.statusCode,
    this.cause,
  });
  final String code;
  final String message;
  final String? url;
  final int? statusCode;
  final Object? cause;
  @override
  String toString() =>
      'AppHttpException[$code] $message${url == null ? '' : ' ($url)'}';
}

/// A bounded configuration/text client. Inject Dio or an adapter for offline tests.
class AppHttpClient {
  AppHttpClient({
    Dio? dio,
    HttpClientAdapter? adapter,
    this.timeout = const Duration(seconds: 25),
    this.maxBytes = 8 * 1024 * 1024,
    this.maxRedirects = 8,
  }) : _dio = dio ?? Dio() {
    if (adapter != null) _dio.httpClientAdapter = adapter;
    if (maxBytes <= 0 || maxRedirects < 0 || timeout <= Duration.zero) {
      throw ArgumentError('Invalid HTTP limits');
    }
  }
  final Dio _dio;
  final Duration timeout;
  final int maxBytes;
  final int maxRedirects;
  bool _closed = false;

  Future<FetchResult> fetch(
    String url, {
    Map<String, String> headers = const {},
  }) async {
    if (_closed) {
      throw const AppHttpException('closed', 'HTTP client is closed');
    }
    final token = CancelToken();
    try {
      return await _fetch(url, headers, token).timeout(
        timeout,
        onTimeout: () {
          token.cancel('total timeout');
          throw AppHttpException(
            'timeout',
            'Request exceeded ${timeout.inMilliseconds} ms',
            url: url,
          );
        },
      );
    } on AppHttpException {
      rethrow;
    } on DioException catch (e) {
      final code = e.error is HandshakeException
          ? 'tls'
          : switch (e.type) {
              DioExceptionType.connectionTimeout ||
              DioExceptionType.receiveTimeout ||
              DioExceptionType.sendTimeout => 'timeout',
              DioExceptionType.badCertificate => 'tls',
              DioExceptionType.cancel => 'cancelled',
              _ => 'network',
            };
      throw AppHttpException(
        code,
        '${e.message ?? 'HTTP request failed'}${e.error == null ? '' : ': ${e.error}'}',
        url: url,
        cause: e,
      );
    } catch (e) {
      throw AppHttpException(
        'network',
        'HTTP request failed: $e',
        url: url,
        cause: e,
      );
    }
  }

  Future<FetchResult> _fetch(
    String url,
    Map<String, String> headers,
    CancelToken token,
  ) async {
    var current = normalizeHttpUrl(url);
    final visited = <String>{};
    var requestHeaders = <String, String>{
      if (!headers.keys.any((k) => k.toLowerCase() == 'user-agent'))
        'User-Agent': 'okhttp/4.9.1',
      ...headers,
    };
    for (var redirects = 0; ; redirects++) {
      if (!visited.add(current.toString())) {
        throw AppHttpException(
          'redirect_loop',
          'Redirect cycle detected',
          url: current.toString(),
        );
      }
      final response = await _dio.getUri<ResponseBody>(
        current,
        cancelToken: token,
        options: Options(
          responseType: ResponseType.stream,
          followRedirects: false,
          validateStatus: (_) => true,
          receiveTimeout: timeout,
          sendTimeout: timeout,
          headers: requestHeaders,
        ),
      );
      final body = response.data;
      final status = response.statusCode ?? 0;
      final location = response.headers.value('location');
      if ([301, 302, 303, 307, 308].contains(status) && location != null) {
        if (body != null) await body.stream.listen((_) {}).cancel();
        if (redirects >= maxRedirects) {
          throw AppHttpException(
            'redirect_limit',
            'Too many redirects (limit $maxRedirects)',
            url: url,
          );
        }
        final next = normalizeHttpUrl(current.resolve(location).toString());
        if (next.origin != current.origin) {
          requestHeaders = Map.of(requestHeaders)
            ..removeWhere(
              (k, _) => [
                'authorization',
                'cookie',
                'proxy-authorization',
              ].contains(k.toLowerCase()),
            );
        }
        current = next;
        continue;
      }
      if (status < 200 || status >= 300) {
        if (body != null) await body.stream.listen((_) {}).cancel();
        throw AppHttpException(
          'http_status',
          'Server returned HTTP $status',
          url: current.toString(),
          statusCode: status,
        );
      }
      if (body == null) {
        throw AppHttpException(
          'empty_response',
          'Missing response body',
          url: url,
        );
      }
      final length = int.tryParse(
        response.headers.value('content-length') ?? '',
      );
      if (length != null && length > maxBytes) {
        await body.stream.listen((_) {}).cancel();
        throw AppHttpException(
          'size_limit',
          'Response exceeds $maxBytes bytes',
          url: url,
        );
      }
      final bytes = BytesBuilder(copy: false);
      await for (final chunk in body.stream) {
        if (bytes.length + chunk.length > maxBytes) {
          token.cancel('response size limit');
          throw AppHttpException(
            'size_limit',
            'Response exceeds $maxBytes bytes',
            url: url,
          );
        }
        bytes.add(chunk);
      }
      return FetchResult(
        bytes: bytes.takeBytes(),
        finalUrl: response.realUri.toString(),
        statusCode: status,
        headers: response.headers.map,
      );
    }
  }

  Future<Map<String, dynamic>> getJson(
    String url, {
    Map<String, String> headers = const {},
  }) async {
    final result = await fetch(url, headers: headers);
    try {
      final value = jsonDecode(utf8.decode(result.bytes));
      if (value is! Map) throw const FormatException('Expected a JSON object');
      return Map<String, dynamic>.from(value);
    } catch (e) {
      throw AppHttpException(
        'invalid_json',
        'Response is not a JSON object: $e',
        url: result.finalUrl,
        cause: e,
      );
    }
  }

  void close() {
    _closed = true;
    _dio.close(force: true);
  }
}

/// RFC 3492 host conversion; Uri handles Unicode path/query escaping separately.
Uri normalizeHttpUrl(String value) {
  try {
    var uri = Uri.parse(value.trim());
    if (!['http', 'https'].contains(uri.scheme.toLowerCase()) ||
        uri.host.isEmpty) {
      throw const FormatException('Only absolute HTTP(S) URLs are supported');
    }
    final host = Uri.decodeComponent(uri.host).replaceAll(RegExp('[。．｡]'), '.');
    final ascii = host
        .split('.')
        .map(
          (label) => label.runes.any((r) => r > 127)
              ? 'xn--${_punycode(label.toLowerCase())}'
              : label.toLowerCase(),
        )
        .join('.');
    uri = uri.replace(host: ascii).removeFragment();
    return uri;
  } catch (e) {
    throw AppHttpException(
      'invalid_url',
      'Invalid HTTP URL: $e',
      url: value,
      cause: e,
    );
  }
}

String _punycode(String input) {
  final points = input.runes.toList();
  final output = StringBuffer();
  for (final p in points.where((p) => p < 128)) {
    output.writeCharCode(p);
  }
  var handled = points.where((p) => p < 128).length;
  final basic = handled;
  if (basic > 0) output.write('-');
  var n = 128, delta = 0, bias = 72;
  int adapt(int d, int count, bool first) {
    d = first ? d ~/ 700 : d ~/ 2;
    d += d ~/ count;
    var k = 0;
    while (d > 455) {
      d ~/= 35;
      k += 36;
    }
    return k + (36 * d ~/ (d + 38));
  }

  String digit(int d) => String.fromCharCode(d < 26 ? 97 + d : 22 + d);
  while (handled < points.length) {
    final m = points.where((p) => p >= n).reduce((a, b) => a < b ? a : b);
    delta += (m - n) * (handled + 1);
    n = m;
    for (final p in points) {
      if (p < n) delta++;
      if (p == n) {
        var q = delta;
        for (var k = 36; ; k += 36) {
          final t = k <= bias
              ? 1
              : k >= bias + 26
              ? 26
              : k - bias;
          if (q < t) break;
          output.write(digit(t + ((q - t) % (36 - t))));
          q = (q - t) ~/ (36 - t);
        }
        output.write(digit(q));
        bias = adapt(delta, handled + 1, handled == basic);
        delta = 0;
        handled++;
      }
    }
    delta++;
    n++;
  }
  return output.toString();
}
