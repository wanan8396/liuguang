import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:tvbox/core/pairing/pairing_service.dart';

void main() {
  late PairingService service;
  late HttpClient client;
  late List<String> imported;

  setUp(() {
    imported = [];
    service = PairingService(onSubscription: (url) async => imported.add(url));
    client = HttpClient();
  });

  tearDown(() async {
    client.close(force: true);
    await service.stop();
    service.dispose();
  });

  Future<int> push(Map<String, dynamic> data, {String? origin}) async {
    final request = await client.postUrl(
      Uri.parse('${service.addresses.single}/push'),
    );
    request.headers.contentType = ContentType.json;
    if (origin != null) request.headers.set('Origin', origin);
    request.write(jsonEncode(data));
    final response = await request.close();
    await response.drain<void>();
    return response.statusCode;
  }

  test('服务默认关闭，配对码不包含在网页内', () async {
    expect(service.running, isFalse);
    await service.start(address: InternetAddress.loopbackIPv4);
    final request = await client.getUrl(Uri.parse(service.addresses.single));
    final response = await request.close();
    final text = await utf8.decoder.bind(response).join();
    expect(response.statusCode, 200);
    expect(text, contains('配对码'));
    expect(text, isNot(contains(service.code!)));
  });

  test('匹配配对码只入队，必须手机确认后才导入', () async {
    await service.start(address: InternetAddress.loopbackIPv4);
    expect(
      await push({
        'code': service.code,
        'url': 'https://example.invalid/sub.json',
      }),
      202,
    );
    expect(imported, isEmpty);
    expect(service.pending?.url, 'https://example.invalid/sub.json');
    await service.approvePending();
    expect(imported, ['https://example.invalid/sub.json']);
    expect(service.pending, isNull);
  });

  test('拒绝错误配对码、跨站和非订阅请求', () async {
    await service.start(address: InternetAddress.loopbackIPv4);
    expect(
      await push({'code': 'wrong', 'url': 'https://example.invalid/config'}),
      401,
    );
    expect(
      await push({
        'code': service.code,
        'url': 'https://example.invalid/config',
      }, origin: 'https://attacker.invalid'),
      403,
    );
    expect(
      await push({'code': service.code, 'url': 'file:///etc/passwd'}),
      400,
    );
    expect(
      await push({
        'code': service.code,
        'type': 'play',
        'url': 'https://example.invalid/v.mp4',
      }),
      400,
    );
    expect(imported, isEmpty);
  });

  test('拒绝待确认队列覆盖，停止后清除配对状态', () async {
    await service.start(address: InternetAddress.loopbackIPv4);
    expect(
      await push({'code': service.code, 'url': 'https://example.invalid/one'}),
      202,
    );
    expect(
      await push({'code': service.code, 'url': 'https://example.invalid/two'}),
      409,
    );
    service.rejectPending();
    expect(service.pending, isNull);
    await service.stop();
    expect(service.running, isFalse);
    expect(service.code, isNull);
    expect(service.addresses, isEmpty);
  });

  test('错误配对码每分钟只允许五次尝试', () async {
    await service.start(address: InternetAddress.loopbackIPv4);
    for (var i = 0; i < 5; i++) {
      expect(
        await push({'code': 'wrong', 'url': 'https://example.invalid/config'}),
        401,
      );
    }
    expect(
      await push({
        'code': service.code,
        'url': 'https://example.invalid/config',
      }),
      429,
    );
  });
}
