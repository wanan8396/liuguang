import 'dart:async';
import 'dart:convert';

import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:tvbox/core/config/subscription_repository.dart';
import 'package:tvbox/core/discovery/line_scanner.dart';
import 'package:tvbox/core/network/app_http_client.dart';

import '../config/config_test.dart' show Adapter, body;

void main() {
  LineScanner scanner(
    Adapter adapter, {
    List<(String, String)> seeds = const [],
    List<String> pages = const [],
  }) => LineScanner(
    dio: Dio()..httpClientAdapter = adapter,
    seeds: seeds,
    discoveryPages: pages,
    deadline: const Duration(seconds: 2),
  );

  test('内置入口会被探测，并在发现页尚未返回时提供结果', () async {
    final page = Completer<ResponseBody>();
    final adapter = Adapter(
      (o) => o.uri.path == '/page'
          ? page.future
          : body('{"sites":[{"key":"a","api":"csp_A"}]}'),
    );
    final scan = scanner(
      adapter,
      seeds: [('源甲', 'https://repo.test/config')],
      pages: ['https://repo.test/page'],
    );
    addTearDown(scan.dispose);
    final scanning = scan.start();
    await Future<void>.delayed(const Duration(milliseconds: 30));
    expect(scan.verifiedLines.single.name, '源甲');
    expect(scan.running, true);
    page.complete(body('<p>没有额外链接</p>'));
    await scanning;
    expect(adapter.requests.map((o) => o.uri.path), contains('/config'));
    expect(scan.verifiedLines, hasLength(1));
  });

  test('发现页本身为多仓时保留原入口，相对地址和别名可再次导入', () async {
    final fixtures = {
      '/root': jsonEncode({
        'storeHouse': [
          {'sourceName': '仓甲', 'sourceUrl': './a'},
          {'name': '仓乙', 'api': './b'},
          './a',
          {'name': '坏仓', 'url': './html'},
        ],
      }),
      '/a': '{"sites":[{"key":"a","api":"csp_A","ext":"./a.json"}]}',
      '/b': '{"sites":[{"key":"b","api":"csp_B"}]}',
      '/html': '<html>不是TVBox配置</html>',
    };
    final adapter = Adapter((o) => body(fixtures[o.uri.path]!));
    final scan = scanner(adapter, pages: ['https://repo.test/root']);
    addTearDown(scan.dispose);
    await scan.start();
    expect(scan.roots.single.multi, true);
    expect(scan.verifiedLines.map((n) => n.name), containsAll(['仓甲', '仓乙']));
    expect(scan.verifiedLines, hasLength(2));
    final client = AppHttpClient(
      adapter: Adapter((o) => body(fixtures[o.uri.path]!)),
    );
    addTearDown(client.close);
    final result = await SubscriptionRepository(
      client,
    ).load(scan.roots.single.url);
    expect(result.configs.map((c) => c.name), containsAll(['仓甲', '仓乙']));
    expect(result.configs.first.sites.single.ext, 'https://repo.test/a.json');
  });

  test('仅解析服务、网页和错误JSON不冒充可导入TVBox配置', () async {
    final adapter = Adapter(
      (o) => body(switch (o.uri.path) {
        '/parse' =>
          '{"parses":[{"url":"https://parse.test"}],"spider":"x.jar"}',
        '/html' => '<html>download tvbox</html>',
        _ => '{"code":403,"message":"forbidden","sites":"blocked"}',
      }),
    );
    final scan = scanner(
      adapter,
      seeds: [
        ('解析', 'https://repo.test/parse'),
        ('网页', 'https://repo.test/html'),
        ('错误', 'https://repo.test/error'),
      ],
    );
    addTearDown(scan.dispose);
    await scan.start();
    expect(scan.verifiedLines, isEmpty);
    expect(scan.roots.every((node) => node.status == 'fail'), true);
  });

  test('取消后立即重扫，旧响应不能覆盖新结果或触发后续请求', () async {
    final old = Completer<ResponseBody>();
    var request = 0;
    final adapter = Adapter(
      (_) => ++request == 1
          ? old.future
          : body('{"sites":[{"key":"fresh","api":"csp_Fresh"}]}'),
    );
    final scan = scanner(adapter, seeds: [('新仓', 'https://repo.test/a')]);
    addTearDown(scan.dispose);
    final first = scan.start();
    await Future<void>.delayed(const Duration(milliseconds: 20));
    scan.cancel();
    await first;
    await scan.start();
    old.complete(body('{"urls":[{"url":"https://old.test/should-not-run"}]}'));
    await Future<void>.delayed(const Duration(milliseconds: 20));
    expect(adapter.requests, hasLength(2));
    expect(scan.verifiedLines.single.url, 'https://repo.test/a');
    expect(scan.running, false);
  });

  test('页面实体编码、原始仓库地址和速度标签不破坏有效地址', () {
    expect(
      extractConfigUrls('''
      <a href="https://repo.test/config.json?a=1&amp;b=2">配置</a>
      <p>https://gitlab.com/user/box/-/raw/main/api.json</p>
      <a href="https://repo.test/logo.png">图片</a>
    '''),
      [
        'https://gitlab.com/user/box/-/raw/main/api.json',
        'https://repo.test/config.json?a=1&b=2',
      ],
    );
    expect(gradeSpeed(8000), '很慢');
  });
}
