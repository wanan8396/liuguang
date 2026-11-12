import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:tvbox/core/engine/android_engine_bridge.dart';
import 'package:tvbox/core/engine/source_engine_api.g.dart';

class _Native extends SourceEngineApi {
  String mediaUrl = '';
  String homeResult = '{"list":[]}';
  Completer<String>? delayedCapabilities;
  Completer<String>? delayedHome;
  final calls = <String>[];
  final closed = <String>[];
  Completer<String>? delayedOpen;
  Completer<void>? openStarted;
  int next = 0;

  @override
  Future<String> openSession(String configJson, String siteJson) async {
    calls.add('open:$configJson:$siteJson');
    openStarted?.complete();
    return delayedOpen?.future ?? 'native-${++next}';
  }

  @override
  Future<String> home(String sessionId, bool filter) async {
    calls.add('home:$sessionId:$filter');
    return delayedHome?.future ?? homeResult;
  }

  @override
  Future<String> category(
    String sessionId,
    String tid,
    int page,
    String filtersJson,
  ) async => jsonEncode([sessionId, tid, page, filtersJson]);
  @override
  Future<String> search(String sessionId, String keyword, int page) async =>
      jsonEncode([sessionId, keyword, page]);
  @override
  Future<String> detail(String sessionId, String id) async {
    if (id == 'error') {
      throw PlatformException(
        code: 'native-code',
        message: 'native message',
        details: {'reason': 'fixture'},
      );
    }
    return jsonEncode([sessionId, id]);
  }

  @override
  Future<String> play(String sessionId, String flag, String id) async =>
      jsonEncode([sessionId, flag, id]);
  @override
  Future<String> resolve(
    String sessionId,
    String resultJson,
    String parserJson,
  ) async => jsonEncode({
    'url': mediaUrl,
    'parse': 0,
    'header': {'native-secret': 'kept-on-android'},
  });
  @override
  Future<String> fetchLocal(String sessionId, String url) async =>
      'native-local:$sessionId:$url';
  @override
  Future<void> cancel(String sessionId) async {
    calls.add('cancel:$sessionId');
  }

  @override
  Future<void> closeSession(String sessionId) async {
    closed.add(sessionId);
  }

  @override
  Future<String> capabilities() async =>
      delayedCapabilities?.future ?? '{"jar":true,"js":true,"fixture":true}';
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late HttpOverrides? previousOverrides;
  late _Native native;
  late AndroidEngineBridgeService service;
  late AndroidEngineBridgeApi client;
  late HttpClient raw;
  HttpServer? nativeMedia;

  Future<HttpClientResponse> mediaGet(
    String url, {
    String? range,
    String method = 'GET',
  }) async {
    final request = await raw.openUrl(method, Uri.parse(url));
    if (range != null) request.headers.set('Range', range);
    return request.close();
  }

  Future<(int, Map<String, dynamic>)> rpc(
    String method,
    List<Object?> args, {
    String? token,
    String? origin,
    String? host,
    String? payload,
  }) async {
    final request = await raw.postUrl(
      Uri.parse('${service.addresses.single}/rpc'),
    );
    request.headers.contentType = ContentType.json;
    request.headers.set('Authorization', 'Bearer ${token ?? service.token}');
    if (origin != null) request.headers.set('Origin', origin);
    if (host != null) request.headers.set('Host', host);
    request.write(
      payload ?? jsonEncode({'id': 77, 'method': method, 'args': args}),
    );
    final response = await request.close();
    return (
      response.statusCode,
      Map<String, dynamic>.from(
        jsonDecode(await utf8.decoder.bind(response).join()) as Map,
      ),
    );
  }

  setUp(() async {
    previousOverrides = HttpOverrides.current;
    HttpOverrides.global = null;
    native = _Native();
    service = AndroidEngineBridgeService(native: native);
    await service.start(address: InternetAddress.loopbackIPv4);
    client = AndroidEngineBridgeApi(
      endpoint: service.addresses.single,
      token: service.token!,
    );
    raw = HttpClient()..findProxy = (_) => 'DIRECT';
  });
  tearDown(() async {
    await client.dispose();
    await service.stop();
    service.dispose();
    await nativeMedia?.close(force: true);
    nativeMedia = null;
    raw.close(force: true);
    HttpOverrides.global = previousOverrides;
  });

  test('endpoint accepts only literal private / loopback IPv4 origins', () {
    for (final endpoint in [
      'http://127.0.0.1:80',
      'https://192.168.5.2',
      'http://10.0.0.3:1515',
      'http://172.31.2.3',
      'http://localhost:123',
    ]) {
      expect(
        AndroidEngineBridgeApi.validateEndpoint(endpoint),
        startsWith('http'),
      );
    }
    for (final endpoint in [
      'http://8.8.8.8',
      'http://0.0.0.0',
      'http://169.254.1.2',
      'http://172.32.0.1',
      'https://lan.example',
      'file:///tmp',
      'http://user:token@192.168.1.1',
      'http://192.168.1.1/rpc',
      'http://192.168.1.1?token=x',
      'http://192.168.1.1#token',
      'http://[::1]',
    ]) {
      expect(
        () => AndroidEngineBridgeApi.validateEndpoint(endpoint),
        throwsFormatException,
        reason: endpoint,
      );
    }
  });

  test(
    'service only binds private IPv4, token has at least 256 random bits',
    () async {
      expect(base64Url.decode('${service.token!}='), hasLength(32));
      await service.stop();
      await expectLater(
        service.start(address: InternetAddress.anyIPv4),
        throwsFormatException,
      );
    },
  );

  test(
    'complete RPC API delegates to native and wraps native session IDs',
    () async {
      final session = await client.openSession(
        '{"private":"credentials"}',
        '{"api":"csp_Test"}',
      );
      expect(session, isNot(startsWith('native-')));
      expect(await client.home(session, true), '{"list":[]}');
      expect(jsonDecode(await client.category(session, 'movie', 2, '{}')), [
        'native-1',
        'movie',
        2,
        '{}',
      ]);
      expect(jsonDecode(await client.search(session, 'word', 3)), [
        'native-1',
        'word',
        3,
      ]);
      expect(jsonDecode(await client.detail(session, 'vod')), [
        'native-1',
        'vod',
      ]);
      expect(jsonDecode(await client.play(session, 'flag', 'ep')), [
        'native-1',
        'flag',
        'ep',
      ]);
      expect(
        await client.fetchLocal(session, 'http://127.0.0.1/proxy'),
        contains('native-local:native-1'),
      );
      expect(
        jsonDecode(await client.capabilities()),
        containsPair('jar', true),
      );
      await client.cancel(session);
      expect(native.calls, contains('cancel:native-1'));
      await client.closeSession(session);
      expect(native.closed, ['native-1']);
      await expectLater(
        client.home(session, true),
        throwsA(
          isA<PlatformException>().having((e) => e.code, 'code', 'session'),
        ),
      );
    },
  );

  test('native error envelope preserves code message and details', () async {
    final session = await client.openSession('{}', '{}');
    await expectLater(
      client.detail(session, 'error'),
      throwsA(
        isA<PlatformException>()
            .having((e) => e.code, 'code', 'native-code')
            .having((e) => e.message, 'message', 'native message')
            .having((e) => e.details, 'details', {'reason': 'fixture'}),
      ),
    );
  });

  test(
    'wrong token, Host, Origin, unknown method and wrong args are rejected',
    () async {
      final wrong = AndroidEngineBridgeApi(
        endpoint: service.addresses.single,
        token: 'wrong',
      );
      try {
        await expectLater(
          wrong.capabilities(),
          throwsA(
            isA<PlatformException>().having(
              (e) => e.code,
              'code',
              'authentication',
            ),
          ),
        );
      } finally {
        await wrong.dispose();
      }
      expect(
        (await rpc('capabilities', [], origin: 'https://outside.invalid')).$1,
        403,
      );
      expect((await rpc('capabilities', [], host: 'outside.invalid')).$1, 403);
      expect((await rpc('anythingElse', [])).$1, 405);
      expect((await rpc('home', [1, false])).$1, 400);
      expect((await rpc('home', ['native-1', true])).$1, 404);
      expect(native.calls, isEmpty);
    },
  );

  test('RPC rejects input and output above 2 MiB', () async {
    final oversized = 'x' * (2 * 1024 * 1024 + 1);
    native.homeResult = oversized;
    final session = await client.openSession('{}', '{}');
    await expectLater(
      client.home(session, true),
      throwsA(
        isA<PlatformException>().having((e) => e.code, 'code', 'too-large'),
      ),
    );
    final response = await rpc('capabilities', [], payload: oversized);
    expect(response.$1, 413);
    expect(response.$2['error']['code'], 'too-large');
    await expectLater(
      client.openSession(oversized, '{}'),
      throwsA(
        isA<PlatformException>().having((e) => e.code, 'code', 'too-large'),
      ),
    );
  });

  test(
    'resolve HLS uses opaque gateway, recursive playlists keys segments keep Range',
    () async {
      final seenRanges = <String, String?>{};
      nativeMedia = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      final origin = 'http://127.0.0.1:${nativeMedia!.port}';
      nativeMedia!.listen((request) async {
        final path = request.uri.path;
        seenRanges[path] = request.headers.value('Range');
        final response = request.response;
        if (path == '/master.m3u8') {
          response.headers.contentType = ContentType(
            'application',
            'vnd.apple.mpegurl',
          );
          response.write(
            '#EXTM3U\n#EXT-X-STREAM-INF:BANDWIDTH=1\n$origin/variant.m3u8?native=private\n',
          );
        } else if (path == '/variant.m3u8') {
          response.headers.contentType = ContentType(
            'application',
            'vnd.apple.mpegurl',
          );
          response.write(
            '#EXTM3U\n#EXT-X-KEY:METHOD=AES-128,URI="$origin/key?native=private"\n#EXT-X-MAP:URI="init.mp4",BYTERANGE="4@0"\n#EXTINF:1,\n#EXT-X-BYTERANGE:4@2\n$origin/segment.ts?native=private\n',
          );
        } else {
          final bytes = utf8.encode('0123456789');
          response.headers.set('Accept-Ranges', 'bytes');
          response.headers.contentType = ContentType('video', 'mp2t');
          if (request.headers.value('Range') == 'bytes=2-5') {
            response.statusCode = 206;
            response.headers.set('Content-Range', 'bytes 2-5/10');
            response.contentLength = 4;
            if (request.method != 'HEAD') response.add(bytes.sublist(2, 6));
          } else {
            response.contentLength = bytes.length;
            if (request.method != 'HEAD') response.add(bytes);
          }
        }
        await response.close();
      });
      native.mediaUrl = '$origin/master.m3u8?native=private';
      final session = await client.openSession('{}', '{}');
      final result =
          jsonDecode(await client.resolve(session, '{}', '[]')) as Map;
      final resolved = result['url'] as String;
      expect(resolved, startsWith('${service.addresses.single}/media/'));
      expect(resolved, isNot(contains(service.token!)));
      expect(
        base64Url.decode(Uri.parse(resolved).pathSegments.last),
        hasLength(24),
      );
      expect(result['header'], isEmpty);
      final first = await utf8.decoder.bind(await mediaGet(resolved)).join();
      expect(first, isNot(contains('native=private')));
      final variant = first
          .split('\n')
          .firstWhere((line) => line.startsWith('/media/'));
      final second = await utf8.decoder
          .bind(await mediaGet('${service.addresses.single}$variant'))
          .join();
      expect(second, contains('#EXT-X-BYTERANGE:4@2'));
      expect(second, contains('BYTERANGE="4@0"'));
      expect(second, isNot(contains(origin)));
      final key = RegExp(r'URI="([^"]+)"').firstMatch(second)![1]!;
      final segment = second
          .split('\n')
          .firstWhere((line) => line.startsWith('/media/'));
      for (final path in [key, segment]) {
        final response = await mediaGet(
          '${service.addresses.single}$path',
          range: 'bytes=2-5',
        );
        expect(response.statusCode, 206);
        expect(response.headers.value('Content-Range'), 'bytes 2-5/10');
        expect(response.headers.contentType?.mimeType, 'video/mp2t');
        expect(response.contentLength, 4);
        expect(await utf8.decoder.bind(response).join(), '2345');
      }
      expect(seenRanges['/key'], 'bytes=2-5');
      expect(seenRanges['/segment.ts'], 'bytes=2-5');
      final head = await mediaGet(
        '${service.addresses.single}$segment',
        method: 'HEAD',
      );
      expect(head.contentLength, 10);
      await head.drain<void>();
      await client.closeSession(session);
      final revoked = await mediaGet(resolved);
      expect(revoked.statusCode, 404);
      await revoked.drain<void>();
    },
  );

  test(
    'gateway accepts no arbitrary URL and HLS foreign loopback origin is not mapped',
    () async {
      nativeMedia = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      nativeMedia!.listen((request) async {
        request.response.headers.contentType = ContentType(
          'application',
          'vnd.apple.mpegurl',
        );
        request.response.write('#EXTM3U\nhttp://127.0.0.1:1/private-secret\n');
        await request.response.close();
      });
      native.mediaUrl = 'http://127.0.0.1:${nativeMedia!.port}/playlist';
      final session = await client.openSession('{}', '{}');
      final result =
          jsonDecode(await client.resolve(session, '{}', '[]')) as Map;
      final response = await mediaGet(result['url'] as String);
      expect(response.statusCode, 502);
      await response.drain<void>();
      final arbitrary = await mediaGet(
        '${service.addresses.single}/media/${'A' * 32}?url=http://127.0.0.1:1',
      );
      expect(arbitrary.statusCode, 400);
      await arbitrary.drain<void>();
    },
  );

  test('media begins streaming before upstream body completes', () async {
    final finish = Completer<void>();
    nativeMedia = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    nativeMedia!.listen((request) async {
      request.response.headers.contentType = ContentType('video', 'mp4');
      request.response.bufferOutput = false;
      request.response.add(utf8.encode('first-chunk'));
      await request.response.flush();
      await finish.future;
      request.response.add(utf8.encode('-last'));
      await request.response.close();
    });
    native.mediaUrl = 'http://127.0.0.1:${nativeMedia!.port}/video';
    final session = await client.openSession('{}', '{}');
    final result = jsonDecode(await client.resolve(session, '{}', '[]')) as Map;
    final response = await mediaGet(
      result['url'] as String,
    ).timeout(const Duration(seconds: 2));
    final chunks = StreamIterator<List<int>>(response);
    try {
      expect(await chunks.moveNext().timeout(const Duration(seconds: 2)), true);
      expect(utf8.decode(chunks.current), 'first-chunk');
    } finally {
      finish.complete();
      await chunks.cancel();
    }
  });

  test(
    'upstream media response timeout aborts the native HTTP request',
    () async {
      await service.stop();
      service.dispose();
      service = AndroidEngineBridgeService(
        native: native,
        requestTimeout: const Duration(milliseconds: 150),
      );
      await service.start(address: InternetAddress.loopbackIPv4);
      await client.dispose();
      client = AndroidEngineBridgeApi(
        endpoint: service.addresses.single,
        token: service.token!,
      );
      final aborted = Completer<void>();
      final stalled = await ServerSocket.bind(InternetAddress.loopbackIPv4, 0);
      final sockets = <Socket>[];
      stalled.listen((socket) {
        sockets.add(socket);
        socket.listen(
          (_) {},
          onDone: () {
            if (!aborted.isCompleted) aborted.complete();
          },
          onError: (Object _) {
            if (!aborted.isCompleted) aborted.complete();
          },
        );
      });
      try {
        native.mediaUrl = 'http://127.0.0.1:${stalled.port}/never-responds';
        final id = await client.openSession('{}', '{}');
        final result = jsonDecode(await client.resolve(id, '{}', '[]')) as Map;
        final response = await mediaGet(result['url'] as String);
        expect(response.statusCode, 502);
        await response.drain<void>();
        await aborted.future.timeout(const Duration(seconds: 2));
      } finally {
        for (final socket in sockets) {
          socket.destroy();
        }
        await stalled.close();
      }
    },
  );

  test(
    'client shorter total timeout expires server lease and closes late open',
    () async {
      final shorter = AndroidEngineBridgeApi(
        endpoint: service.addresses.single,
        token: service.token!,
        timeout: const Duration(milliseconds: 200),
      );
      native.delayedOpen = Completer<String>();
      try {
        await expectLater(
          shorter.openSession('{}', '{}'),
          throwsA(
            isA<PlatformException>().having(
              (e) => e.code,
              'code',
              'bridge-timeout',
            ),
          ),
        );
        native.delayedOpen!.complete('client-timeout-native');
        await Future<void>(() async {
          while (!native.closed.contains('client-timeout-native')) {
            await Future<void>.delayed(Duration.zero);
          }
        }).timeout(const Duration(seconds: 2));
        expect(native.closed, contains('client-timeout-native'));
      } finally {
        await shorter.dispose();
      }
    },
  );

  test(
    'client dispose while native open is in flight closes its returned session',
    () async {
      native.delayedOpen = Completer<String>();
      native.openStarted = Completer<void>();
      final opening = client.openSession('{}', '{}');
      final failed = expectLater(
        opening,
        throwsA(
          isA<PlatformException>().having(
            (e) => e.code,
            'code',
            'bridge-closed',
          ),
        ),
      );
      await native.openStarted!.future;
      final closing = client.dispose();
      native.delayedOpen!.complete('dispose-native');
      await failed;
      await closing;
      expect(native.closed, contains('dispose-native'));
    },
  );

  test(
    'stop closes all native sessions and rotates credentials on restart',
    () async {
      final oldToken = service.token;
      final first = await client.openSession('{}', '{}');
      await client.openSession('{}', '{}');
      await service.stop();
      expect(native.closed.toSet(), {'native-1', 'native-2'});
      expect(service.running, false);
      expect(service.token, null);
      await service.start(address: InternetAddress.loopbackIPv4);
      expect(service.token, isNot(oldToken));
      final response = await rpc('home', [first, true]);
      expect(response.$2['error']['code'], 'session');
    },
  );

  test(
    'open returning after service stop closes orphan native session',
    () async {
      native.delayedOpen = Completer<String>();
      native.openStarted = Completer<void>();
      final opening = client.openSession('{}', '{}');
      final failed = expectLater(opening, throwsA(isA<PlatformException>()));
      await native.openStarted!.future;
      await service.stop();
      native.delayedOpen!.complete('late-native');
      await failed;
      // Wait for the close event, not a timing assumption.
      await Future<void>(() async {
        while (!native.closed.contains('late-native')) {
          await Future<void>.delayed(Duration.zero);
        }
      }).timeout(const Duration(seconds: 2));
      expect(native.closed, contains('late-native'));
    },
  );

  test('timed out existing native operation is cancelled', () async {
    final shorter = AndroidEngineBridgeApi(
      endpoint: service.addresses.single,
      token: service.token!,
      timeout: const Duration(milliseconds: 300),
    );
    try {
      final id = await shorter.openSession('{}', '{}');
      native.delayedHome = Completer<String>();
      await expectLater(
        shorter.home(id, true),
        throwsA(
          isA<PlatformException>().having(
            (e) => e.code,
            'code',
            'bridge-timeout',
          ),
        ),
      );
      expect(native.calls, contains('cancel:native-1'));
      native.delayedHome!.complete('{}');
    } finally {
      await shorter.dispose();
    }
  });

  test(
    'total RPC timeout closes late native open and error is bounded',
    () async {
      await service.stop();
      service.dispose();
      service = AndroidEngineBridgeService(
        native: native,
        requestTimeout: const Duration(milliseconds: 80),
      );
      await service.start(address: InternetAddress.loopbackIPv4);
      await client.dispose();
      client = AndroidEngineBridgeApi(
        endpoint: service.addresses.single,
        token: service.token!,
        timeout: const Duration(seconds: 2),
      );
      native.delayedOpen = Completer<String>();
      final failed = expectLater(
        client.openSession('{}', '{}'),
        throwsA(
          isA<PlatformException>().having(
            (e) => e.code,
            'code',
            'bridge-timeout',
          ),
        ),
      );
      await failed;
      native.delayedOpen!.complete('timeout-native');
      await Future<void>(() async {
        while (!native.closed.contains('timeout-native')) {
          await Future<void>.delayed(Duration.zero);
        }
      }).timeout(const Duration(seconds: 2));
      expect(native.closed, contains('timeout-native'));
    },
  );

  test('idle expiry closes native sessions without a keepalive', () async {
    await service.stop();
    service.dispose();
    service = AndroidEngineBridgeService(
      native: native,
      idleTimeout: const Duration(milliseconds: 100),
    );
    await service.start(address: InternetAddress.loopbackIPv4);
    await client.dispose();
    client = AndroidEngineBridgeApi(
      endpoint: service.addresses.single,
      token: service.token!,
    );
    await client.openSession('{}', '{}');
    final stopped = Completer<void>();
    service.addListener(() {
      if (!service.running && !stopped.isCompleted) stopped.complete();
    });
    await stopped.future.timeout(const Duration(seconds: 2));
    expect(native.closed, contains('native-1'));
  });
}
