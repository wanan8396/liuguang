import 'dart:async';
import 'dart:typed_data';

import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:tvbox/core/network/app_http_client.dart';

class _Adapter implements HttpClientAdapter {
  _Adapter(this.body);
  final ResponseBody body;
  @override
  Future<ResponseBody> fetch(
    RequestOptions options,
    Stream<Uint8List>? data,
    Future<void>? cancelFuture,
  ) async => body;
  @override
  void close({bool force = false}) {}
}

void main() {
  test(
    'prefix cancels huge ignored-Range response after first kilobyte',
    () async {
      var cancelled = false;
      final source = StreamController<Uint8List>(
        onCancel: () {
          cancelled = true;
        },
      );
      final client = AppHttpClient(
        adapter: _Adapter(
          ResponseBody(
            source.stream,
            200,
            headers: {
              'content-length': ['1073741824'],
            },
          ),
        ),
      );
      final pending = client.fetchPrefix('https://media.invalid/large.mp4');
      source.add(Uint8List.fromList(List.filled(2048, 65)));
      final result = await pending;
      expect(result.bytes.length, 1024);
      await Future<void>.delayed(Duration.zero);
      expect(cancelled, true);
      client.close();
      await source.close();
    },
  );
  test('ordinary full fetch still enforces content-length bound', () async {
    final client = AppHttpClient(
      adapter: _Adapter(
        ResponseBody.fromBytes(
          [1, 2, 3],
          200,
          headers: {
            'content-length': ['1073741824'],
          },
        ),
      ),
    );
    await expectLater(
      client.fetch('https://media.invalid/large.mp4'),
      throwsA(
        isA<AppHttpException>().having((e) => e.code, 'code', 'size_limit'),
      ),
    );
    client.close();
  });
  test('prefix retains redirects, final URL, and MIME', () async {
    final client = AppHttpClient(
      adapter: _Adapter(
        ResponseBody.fromString(
          '#EXTM3U\n',
          200,
          headers: {
            'content-type': ['application/vnd.apple.mpegurl'],
          },
        ),
      ),
    );
    final result = await client.fetchPrefix('https://media.invalid/stream');
    expect(
      result.headers['content-type']!.single,
      'application/vnd.apple.mpegurl',
    );
    expect(result.finalUrl, 'https://media.invalid/stream');
    client.close();
  });
}
