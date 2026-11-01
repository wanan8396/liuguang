import 'dart:async';
import 'dart:typed_data';

import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:tvbox/core/discovery/line_scanner.dart';

class FakeAdapter implements HttpClientAdapter {
  FakeAdapter(this.handler);
  final Future<ResponseBody> Function(RequestOptions) handler;
  @override
  Future<ResponseBody> fetch(
    RequestOptions options,
    Stream<Uint8List>? requestStream,
    Future<void>? cancelFuture,
  ) => handler(options);
  @override
  void close({bool force = false}) {}
}

ResponseBody reply(String text) => ResponseBody.fromString(text, 200);

void main() {
  test('seeds are probed and duplicate discovery URLs are deduplicated', () async {
    final requests = <String>[];
    final dio = Dio()
      ..httpClientAdapter = FakeAdapter((options) async {
        requests.add(options.uri.toString());
        if (kDiscoveryPages.contains(options.uri.toString())) {
          return reply(
            '${kSeedLines.first.$2} https://example.org/config.json https://example.org/config.json',
          );
        }
        return reply('{"sites":[]}');
      });
    final scanner = LineScanner(dio: dio, nodeBudget: 200);
    await scanner.start();
    expect(scanner.roots.where((n) => n.name == kSeedLines.first.$1).length, 1);
    expect(scanner.roots.first.status, 'ok');
    expect(
      scanner.roots
          .where((n) => n.url == 'https://example.org/config.json')
          .length,
      1,
    );
    expect(requests, contains(scanner.roots.first.url));
    scanner.dispose();
  });

  test(
    'cancel and restart isolate late discovery results and callbacks',
    () async {
      final delayed = Completer<ResponseBody>();
      var first = true;
      final dio = Dio()
        ..httpClientAdapter = FakeAdapter((options) {
          if (first) return delayed.future;
          return Future.value(reply('{"sites":[]}'));
        });
      final scanner = LineScanner(dio: dio, nodeBudget: 2);
      final old = scanner.start();
      scanner.cancel();
      first = false;
      await scanner.start();
      final urls = scanner.roots.map((n) => n.url).toList();
      final statuses = scanner.roots.map((n) => n.status).toList();
      delayed.complete(reply('https://late.example.org/config.json'));
      await old;
      await Future<void>.delayed(const Duration(milliseconds: 100));
      expect(scanner.roots.map((n) => n.url).toList(), urls);
      expect(scanner.roots.map((n) => n.status).toList(), statuses);
      expect(scanner.running, isFalse);
      scanner.dispose();
    },
  );

  test('deadline bounds discovery even if adapter never completes', () async {
    final never = Completer<ResponseBody>();
    final dio = Dio()..httpClientAdapter = FakeAdapter((_) => never.future);
    final scanner = LineScanner(
      dio: dio,
      deadline: const Duration(milliseconds: 100),
    );
    await scanner.start().timeout(const Duration(seconds: 2));
    expect(scanner.running, isFalse);
    scanner.dispose();
  });

  test('deadline bounds a stalled response stream', () async {
    final controller = StreamController<Uint8List>();
    final dio = Dio()
      ..httpClientAdapter = FakeAdapter((options) async {
        if (kDiscoveryPages.contains(options.uri.toString())) return reply('');
        return ResponseBody(controller.stream, 200);
      });
    final scanner = LineScanner(
      dio: dio,
      nodeBudget: 1,
      deadline: const Duration(milliseconds: 150),
    );
    await scanner.start().timeout(const Duration(seconds: 2));
    expect(scanner.running, isFalse);
    await controller.close();
    scanner.dispose();
  });
}
