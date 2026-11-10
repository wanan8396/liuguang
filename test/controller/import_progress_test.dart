import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:tvbox/core/app_controller.dart';
import 'package:tvbox/core/network/app_http_client.dart';
import 'package:tvbox/core/storage/app_store.dart';

import '../config/config_test.dart' show Adapter, body;
import 'app_controller_test.dart' show MemorySecrets, TestEngine;

void main() {
  test(
    'redirected repository replaces loading progress with final nodes',
    () async {
      final directory = await Directory.systemTemp.createTemp(
        'import-progress-',
      );
      final store = AppStore(
        path: directory.path,
        secretStorage: MemorySecrets(),
      );
      final http = AppHttpClient(
        adapter: Adapter((options) {
          if (options.uri.path == '/root') {
            return body('{"urls":[{"name":"跳转仓库","url":"./old"}]}');
          }
          if (options.uri.path == '/old') {
            return body('', 302, {
              'location': ['./config'],
            });
          }
          return body('{"sites":[{"key":"a","api":"csp_Fixture"}]}');
        }),
      );
      final controller = AppController(
        store: store,
        http: http,
        engine: TestEngine(http),
      );
      try {
        await controller.initialize();
        await controller.importSubscription('https://repo.invalid/root');
        expect(controller.importNodes, hasLength(2));
        expect(controller.importNodes.map((node) => node.status), [
          'repository',
          'ready',
        ]);
        expect(controller.importNodes.last.url, 'https://repo.invalid/config');
        expect(controller.subscriptions.single.nodes, hasLength(2));
      } finally {
        await controller.disposeAsync();
        await directory.delete(recursive: true);
      }
    },
  );
}
