import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:tvbox/core/config/subscription_repository.dart';
import 'package:tvbox/core/network/app_http_client.dart';

import 'config_test.dart' show Adapter, body;

void main() {
  test(
    'malformed child URL does not abort later repository branches',
    () async {
      final adapter = Adapter(
        (options) => body(
          options.uri.path == '/root'
              ? jsonEncode({
                  'urls': [
                    {'name': '坏链接', 'url': 'http://[broken'},
                    {'name': '正常仓库', 'url': './good'},
                  ],
                })
              : '{"sites":[{"key":"good","api":"csp_Fixture"}]}',
        ),
      );
      final client = AppHttpClient(adapter: adapter);
      addTearDown(client.close);
      final result = await SubscriptionRepository(
        client,
      ).load('https://a.test/root');
      expect(result.configs.map((config) => config.name), ['正常仓库']);
      final failed = result.nodes
          .where((node) => node.status == 'error')
          .single;
      expect(failed.name, '坏链接');
      expect(failed.parentUrl, 'https://a.test/root');
      expect(result.nodes.first.status, 'repository');
    },
  );
}
