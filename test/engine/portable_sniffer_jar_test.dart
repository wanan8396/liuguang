import 'dart:async';
import 'dart:convert';
import 'dart:io' show ZLibEncoder;
import 'dart:typed_data';

import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:tvbox/core/engine/jar_compat.dart';
import 'package:tvbox/core/engine/web_sniffer.dart';
import 'package:tvbox/core/network/app_http_client.dart';

class _Adapter implements HttpClientAdapter {
  _Adapter(this.handler);
  final FutureOr<ResponseBody> Function(RequestOptions) handler;
  final requests = <RequestOptions>[];
  @override
  Future<ResponseBody> fetch(
    RequestOptions options,
    Stream<Uint8List>? requestStream,
    Future<void>? cancelFuture,
  ) async {
    requests.add(options);
    return handler(options);
  }

  @override
  void close({bool force = false}) {}
}

ResponseBody _bytes(
  List<int> value, {
  int status = 200,
  Map<String, List<String>> headers = const {},
}) =>
    ResponseBody.fromBytes(Uint8List.fromList(value), status, headers: headers);

ResponseBody _text(
  String value, {
  int status = 200,
  Map<String, List<String>> headers = const {},
}) => _bytes(utf8.encode(value), status: status, headers: headers);

/// Minimal ZIP writer: enough for stored/deflated entries and the local header
/// walk in [JarCompat]; it deliberately omits a central directory.
List<int> _zip(List<(String, String, bool)> entries) {
  final out = BytesBuilder();
  for (final (name, content, deflate) in entries) {
    final nameBytes = utf8.encode(name);
    final data = utf8.encode(content);
    final payload = deflate
        ? Uint8List.fromList(ZLibEncoder(raw: true).convert(data))
        : Uint8List.fromList(data);
    final header = ByteData(30);
    header.setUint32(0, 0x04034b50, Endian.little);
    header.setUint16(4, 20, Endian.little);
    header.setUint16(6, 0, Endian.little);
    header.setUint16(8, deflate ? 8 : 0, Endian.little);
    header.setUint32(18, payload.length, Endian.little);
    header.setUint32(22, data.length, Endian.little);
    header.setUint16(26, nameBytes.length, Endian.little);
    header.setUint16(28, 0, Endian.little);
    out.add(header.buffer.asUint8List());
    out.add(nameBytes);
    out.add(payload);
  }
  return out.toBytes();
}

void main() {
  group('portable page sniffer', () {
    test('finds declared and scripted media, never the page URL', () async {
      final adapter = _Adapter((options) {
        final url = options.uri.toString();
        if (url == 'https://site.invalid/play/1') {
          return _text('''
<html><head><meta property="og:video" content="//cdn.invalid/meta.m3u8"></head>
<body>
<video src="/media/movie.mp4" poster="/poster.jpg"></video>
<iframe src="https://player.invalid/embed/1"></iframe>
<script>var p={url:"https:\\/\\/cdn.invalid\\/script\\/index.m3u8"};</script>
</body></html>''');
        }
        if (url == 'https://cdn.invalid/meta.m3u8' ||
            url == 'https://site.invalid/media/movie.mp4') {
          return _bytes(
            utf8.encode('#EXTM3U\n#EXT-X-VERSION:3\n'),
            headers: {
              'content-type': ['application/vnd.apple.mpegurl'],
            },
          );
        }
        return _text('not media', status: 404);
      });
      final client = AppHttpClient(adapter: adapter);
      final hit = await WebSniffer(
        client,
      ).sniff('https://site.invalid/play/1', {'User-Agent': 'fixture'});
      expect(hit?.url, 'https://cdn.invalid/meta.m3u8');
      expect(hit?.headers['User-Agent'], 'fixture');
      expect(hit?.headers['Referer'], 'https://cdn.invalid/');
      expect(
        adapter.requests.map((r) => r.uri.toString()),
        contains('https://site.invalid/play/1'),
      );
      expect(
        hit?.url,
        isNot('https://site.invalid/play/1'),
        reason: 'the navigation URL itself is never a hit',
      );
      client.close();
    });

    test(
      'falls back to the embedded player page when nothing is declared',
      () async {
        final adapter = _Adapter((options) {
          final url = options.uri.toString();
          if (url == 'https://site.invalid/watch/2') {
            return _text(
              '<html><body><iframe src="/embed/2"></iframe></body></html>',
            );
          }
          if (url == 'https://site.invalid/embed/2') {
            return _text(
              "<script>jw.setup({file:'/hls/master.m3u8'})</script>",
            );
          }
          return _bytes(
            utf8.encode('#EXTM3U\n'),
            headers: {
              'content-type': ['application/x-mpegurl'],
            },
          );
        });
        final client = AppHttpClient(adapter: adapter);
        final hit = await WebSniffer(
          client,
        ).sniff('https://site.invalid/watch/2', const {});
        expect(hit?.url, 'https://site.invalid/hls/master.m3u8');
        client.close();
      },
    );

    test(
      'rejects candidates that fail verification and report no hit',
      () async {
        final adapter = _Adapter(
          (options) => options.uri.path == '/page'
              ? _text('<video src="/broken.mp4"></video>')
              : _text(
                  '<html>login required</html>',
                  status: 200,
                  headers: {
                    'content-type': ['text/html'],
                  },
                ),
        );
        final client = AppHttpClient(adapter: adapter);
        expect(
          await WebSniffer(client).sniff('https://site.invalid/page', const {}),
          isNull,
        );
        client.close();
      },
    );
  });

  group('JAR compatibility inspection', () {
    test('extracts a deflated embedded JavaScript rule', () async {
      final jar = _zip([
        ('META-INF/MANIFEST.MF', 'Manifest-Version: 1.0\n', true),
        ('classes.dex', 'dex\n035\u0000', false),
        (
          'spider.js',
          "var rule={title:'embedded',host:'https://a.invalid'};",
          true,
        ),
      ]);
      final adapter = _Adapter((_) => _bytes(jar));
      final client = AppHttpClient(adapter: adapter);
      final result = await JarCompat(
        client,
      ).inspect('https://site.invalid/spider.jar', const {});
      expect(result.hasDex, isTrue);
      expect(result.isRunnable, isTrue);
      expect(result.embeddedJs, contains("title:'embedded'"));
      client.close();
    });

    test(
      'reports a DEX-only JAR as not runnable instead of guessing',
      () async {
        final jar = _zip([('classes.dex', 'dex\n035\u0000', true)]);
        final client = AppHttpClient(adapter: _Adapter((_) => _bytes(jar)));
        final result = await JarCompat(
          client,
        ).inspect('https://site.invalid/only.jar', const {});
        expect(result.hasDex, isTrue);
        expect(result.isPortableWithoutJs, isTrue);
        expect(result.embeddedJs, isNull);
        client.close();
      },
    );

    test('rejects non-ZIP payloads with a specific error', () async {
      final client = AppHttpClient(
        adapter: _Adapter((_) => _text('<html>error page</html>')),
      );
      await expectLater(
        JarCompat(client).inspect('https://site.invalid/x.jar', const {}),
        throwsA(
          isA<JarInspectError>().having(
            (e) => e.message,
            'message',
            contains('JAR'),
          ),
        ),
      );
      client.close();
    });
  });
}
