import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:tvbox/core/app_controller.dart';
import 'package:tvbox/core/discovery/line_scanner.dart';
import 'package:tvbox/core/network/app_http_client.dart';
import 'package:tvbox/core/storage/app_store.dart';
import 'package:tvbox/features/discovery/line_discovery_page.dart';

import '../config/config_test.dart' show Adapter, body;
import '../controller/app_controller_test.dart' show MemorySecrets, TestEngine;

class _Scanner extends LineScanner {
  @override
  Future<void> start() async {
    roots.clear();
    for (final key in ['a', 'b']) {
      roots.add(
        ScanNode(url: 'https://repo.test/$key', name: '仓$key')
          ..status = 'ok'
          ..kind = 'single'
          ..speedLabel = '快'
          ..siteCount = 1
          ..totalMs = 10,
      );
    }
    onProgress?.call(const ScanProgress(stage: '验证线路', done: 2, total: 2));
  }
}

void main() {
  for (final changedToHtml in [false, true]) {
    testWidgets('发现线路追加时保留已有订阅，后续网页响应=$changedToHtml', (tester) async {
      tester.view.physicalSize = const Size(1000, 1000);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      late Directory directory;
      final adapter = Adapter(
        (o) => o.uri.path == '/b' && changedToHtml
            ? body('<html>接口已失效</html>')
            : body('{"sites":[{"key":"${o.uri.path}","api":"csp_Fixture"}]}'),
      );
      final client = AppHttpClient(adapter: adapter);
      late AppController controller;
      await tester.runAsync(() async {
        directory = await Directory.systemTemp.createTemp('discovery-ui-');
        controller = AppController(
          store: AppStore(path: directory.path, secretStorage: MemorySecrets()),
          http: client,
          engine: TestEngine(client),
        );
        await controller.initialize();
        await controller.importSubscriptions(['https://repo.test/a']);
      });
      final originalHome = controller.homePage;
      await tester.pumpWidget(
        MaterialApp(
          home: Builder(
            builder: (context) => Scaffold(
              body: TextButton(
                onPressed: () => Navigator.push(
                  context,
                  MaterialPageRoute<void>(
                    builder: (_) => LineDiscoveryPage(
                      controller: controller,
                      scanner: _Scanner(),
                    ),
                  ),
                ),
                child: const Text('发现'),
              ),
            ),
          ),
        ),
      );
      await tester.tap(find.text('发现'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('全网搜索并测速'));
      await tester.pumpAndSettle();
      await tester.runAsync(() async {
        await tester.tap(find.text('追加所选 2 条订阅'));
        await Future<void>.delayed(const Duration(milliseconds: 200));
      });
      await tester.pumpAndSettle();
      expect(controller.currentConfig!.url, 'https://repo.test/a');
      expect(identical(controller.homePage, originalHome), true);
      expect(adapter.requests.where((r) => r.uri.path == '/a'), hasLength(1));
      expect(
        controller.subscriptions.any((s) => s.url == 'https://repo.test/a'),
        true,
      );
      expect(
        find.textContaining(
          '已追加 ${changedToHtml ? 0 : 1} 条 · 已有 1 条 · 失败 ${changedToHtml ? 1 : 0} 条',
        ),
        findsOneWidget,
      );
      if (changedToHtml) {
        expect(find.byType(LineDiscoveryPage), findsOneWidget);
        expect(find.textContaining('ConfigDecodeException'), findsOneWidget);
      } else {
        expect(
          controller.subscriptions.where((s) => s.configs.isNotEmpty),
          hasLength(2),
        );
        expect(find.byType(LineDiscoveryPage), findsNothing);
      }
      await tester.pumpWidget(const SizedBox());
      await tester.runAsync(() async {
        await controller.disposeAsync();
        await directory.delete(recursive: true);
      });
    });
  }
}
