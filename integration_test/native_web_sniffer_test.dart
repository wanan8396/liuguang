import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:tvbox/core/engine/native_web_sniffer.dart';

// Real WebView acceptance, not a method-channel mock. Run on an installed build:
// flutter test integration_test/native_web_sniffer_test.dart -d windows
// flutter test integration_test/native_web_sniffer_test.dart -d <ios-simulator>
// All page/JS/media traffic is served by this process's loopback HttpServer.
class _Fixture {
  late HttpServer server;
  final requests =
      <({String path, String? cookie, String? referer, String? agent})>[];
  final loaded = <String, Completer<void>>{};

  String page(String name) => 'http://127.0.0.1:${server.port}/page/$name';

  Future<void> start() async {
    server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    server.listen((request) async {
      requests.add((
        path: request.uri.path,
        cookie: request.headers.value('cookie'),
        referer: request.headers.value('referer'),
        agent: request.headers.value('user-agent'),
      ));
      final response = request.response;
      response.headers.set('Cache-Control', 'no-store');
      if (request.uri.path.startsWith('/page/')) {
        final mode = request.uri.pathSegments.last;
        response.headers.contentType = ContentType.html;
        // The JS fixture has no dependency on a real media/CDN/ad endpoint.
        // CSP prevents accidental non-loopback requests from this document.
        response.headers.set(
          'Content-Security-Policy',
          "default-src 'self' 'unsafe-inline'; connect-src 'self'; media-src 'self'; img-src 'none'; frame-src 'none'",
        );
        response.cookies.add(Cookie('fixture', 'from-page')..path = '/');
        response.write(
          '''<!doctype html><html><head><link rel="icon" href="data:,"></head><body>
<script>
setTimeout(function () {
  var mode = '$mode';
  if (mode === 'idle') return;
  var path = ['/stream/', mode, '-', String(Date.now())].join('');
  if (mode === 'dom') {
    var video = document.createElement('video');
    video.preload = 'metadata';
    video.src = path + '.mp4';
    document.body.appendChild(video);
  } else if (mode === 'xhr') {
    var xhr = new XMLHttpRequest(); xhr.open('GET', path); xhr.send();
  } else if (mode === 'html') {
    var fake = document.createElement('video'); fake.preload = 'metadata';
    fake.src = '/fake/login.mp4'; document.body.appendChild(fake);
    fetch('/fake/login.mp4').then(function(r) { return r.text(); });
  } else {
    fetch(path, {credentials:'include'}).then(function(r) { return r.text(); });
  }
}, 250);
</script></body></html>''',
        );
        await response.close();
        final signal = loaded[mode];
        if (signal != null && !signal.isCompleted) signal.complete();
        return;
      }
      if (request.uri.path == '/fake/login.mp4') {
        response.headers.contentType = ContentType.html;
        response.write('<html><body>fixture sign-in required</body></html>');
      } else if (request.uri.path.startsWith('/stream/')) {
        // No valid codec needed: acceptance tests JS/network discovery and MIME,
        // not playback. No playlist entry references a second network source.
        response.headers.set('Content-Type', 'application/vnd.apple.mpegurl');
        response.cookies.add(
          Cookie('mediaSession', 'http-only-value')
            ..httpOnly = true
            ..path = '/',
        );
        if (request.uri.path.startsWith('/stream/dom-')) {
          // A tiny valid PCM WAV lets WKWebView confirm loadedmetadata even in
          // a video element. The misleading .mp4 suffix is not the evidence.
          response.headers.set('Content-Type', 'audio/wav');
          response.add(_waveFixture());
        } else {
          response.write('#EXTM3U\n#EXT-X-VERSION:3\n#EXT-X-ENDLIST\n');
        }
      } else {
        response.statusCode = HttpStatus.notFound;
      }
      await response.close();
    });
  }

  Future<void> close() => server.close(force: true);
}

Uint8List _waveFixture() {
  final bytes = Uint8List(44 + 1600);
  final data = ByteData.sublistView(bytes);
  void text(int offset, String value) =>
      bytes.setRange(offset, offset + value.length, value.codeUnits);
  text(0, 'RIFF');
  data.setUint32(4, bytes.length - 8, Endian.little);
  text(8, 'WAVE');
  text(12, 'fmt ');
  data.setUint32(16, 16, Endian.little);
  data.setUint16(20, 1, Endian.little);
  data.setUint16(22, 1, Endian.little);
  data.setUint32(24, 8000, Endian.little);
  data.setUint32(28, 16000, Endian.little);
  data.setUint16(32, 2, Endian.little);
  data.setUint16(34, 16, Endian.little);
  text(36, 'data');
  data.setUint32(40, 1600, Endian.little);
  return bytes;
}

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();
  final supported = Platform.isWindows || Platform.isIOS;

  testWidgets(
    'real headless WebView executes delayed fetch and preserves session',
    (tester) async {
      await tester.pumpWidget(const SizedBox());
      await tester.runAsync(() async {
        final fixture = _Fixture();
        await fixture.start();
        final sniffer = NativeWebSniffer();
        try {
          for (final mode in ['fetchOne', 'fetchTwo', 'xhr']) {
            final url = fixture.page(mode);
            final hit = await sniffer.sniff(url, const {
              'User-Agent': 'Liuguang-Native-Fixture/1.0',
              'Cookie': 'injected=caller-session',
            });
            expect(
              hit,
              isNotNull,
              reason: 'Requires installed native WebView runtime: $mode',
            );
            final uri = Uri.parse(hit!.url);
            expect(uri.host, '127.0.0.1');
            expect(uri.path, startsWith('/stream/$mode-'));
            expect(
              uri.path,
              isNot(contains('.m3u8')),
              reason: 'response MIME, not filename matching',
            );
            expect(hit.url, isNot(url));
            expect(hit.headers['Referer'], url);
            expect(hit.headers['User-Agent'], 'Liuguang-Native-Fixture/1.0');
            expect(hit.headers['Cookie'], contains('injected=caller-session'));
            expect(hit.headers['Cookie'], contains('fixture=from-page'));
            expect(
              hit.headers['Cookie'],
              contains('mediaSession=http-only-value'),
            );
            final network = fixture.requests.where((r) => r.path == uri.path);
            expect(
              network,
              isNotEmpty,
              reason: 'a real WebView requested the generated URL',
            );
            expect(network.first.cookie, contains('injected=caller-session'));
            expect(network.first.agent, 'Liuguang-Native-Fixture/1.0');
            expect(network.first.referer, url);
          }
          // A new private view gets only its supplied session, not the cookie
          // injected into the previous disposed view on the same loopback host.
          final clean = await sniffer.sniff(
            fixture.page('withoutSeed'),
            const {},
          );
          expect(clean, isNotNull);
          expect(
            clean!.headers['Cookie'],
            isNot(contains('injected=caller-session')),
          );
          final cleanRequest = fixture.requests.firstWhere(
            (r) => r.path == Uri.parse(clean.url).path,
          );
          expect(
            cleanRequest.cookie,
            isNot(contains('injected=caller-session')),
          );
        } finally {
          await sniffer.dispose();
          await fixture.close();
        }
      });
    },
    skip: !supported,
    timeout: const Timeout(Duration(minutes: 3)),
  );

  testWidgets(
    'real JS inserts a different media DOM URL after document load',
    (tester) async {
      await tester.pumpWidget(const SizedBox());
      await tester.runAsync(() async {
        final fixture = _Fixture();
        await fixture.start();
        final sniffer = NativeWebSniffer();
        try {
          final url = fixture.page('dom');
          final hit = await sniffer.sniff(url, const {});
          expect(hit, isNotNull);
          expect(Uri.parse(hit!.url).path, startsWith('/stream/dom-'));
          expect(hit.url, endsWith('.mp4'));
          expect(hit.headers['Referer'], url);
        } finally {
          await sniffer.dispose();
          await fixture.close();
        }
      });
    },
    skip: !supported,
    timeout: const Timeout(Duration(minutes: 1)),
  );

  testWidgets(
    'real response HTML at mp4 URL produces no false positive',
    (tester) async {
      await tester.pumpWidget(const SizedBox());
      await tester.runAsync(() async {
        final fixture = _Fixture();
        await fixture.start();
        final sniffer = NativeWebSniffer(timeout: const Duration(seconds: 4));
        try {
          expect(await sniffer.sniff(fixture.page('html'), const {}), isNull);
          expect(
            fixture.requests.map((r) => r.path),
            contains('/fake/login.mp4'),
          );
        } finally {
          await sniffer.dispose();
          await fixture.close();
        }
      });
    },
    skip: !supported,
    timeout: const Timeout(Duration(minutes: 1)),
  );

  testWidgets(
    'cancel a live view, then create another and dispose permanently',
    (tester) async {
      await tester.pumpWidget(const SizedBox());
      await tester.runAsync(() async {
        final fixture = _Fixture();
        await fixture.start();
        final sniffer = NativeWebSniffer();
        try {
          final loaded = fixture.loaded['idle'] = Completer<void>();
          final pending = sniffer.sniff(fixture.page('idle'), const {});
          await loaded.future.timeout(const Duration(seconds: 20));
          await sniffer.cancel();
          expect(await pending, isNull);
          expect(
            await sniffer.sniff(fixture.page('fetchAfterCancel'), const {}),
            isNotNull,
          );
          await sniffer.dispose();
          final count = fixture.requests.length;
          expect(
            await sniffer.sniff(fixture.page('fetchAfterDispose'), const {}),
            isNull,
          );
          expect(fixture.requests, hasLength(count));
        } finally {
          await sniffer.dispose();
          await fixture.close();
        }
      });
    },
    skip: !supported,
    timeout: const Timeout(Duration(minutes: 2)),
  );
}
