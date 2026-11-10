import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:tvbox/core/app_controller.dart';
import 'package:tvbox/features/profile/subscriptions_page.dart';
import 'package:tvbox/ui/components.dart';
import 'package:tvbox/core/network/app_http_client.dart';
import 'package:tvbox/core/storage/app_store.dart';

import '../config/config_test.dart' show Adapter, body;
import '../controller/app_controller_test.dart' show MemorySecrets, TestEngine;

void main() {
  testWidgets('单地址逐次追加、重复跳过，成功清空，失败保留输入', (tester) async {
    tester.view.physicalSize = const Size(1000, 1200);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    late Directory directory;
    final client = AppHttpClient(
      adapter: Adapter(
        (o) => body(
          o.uri.path == '/bad'
              ? 'not a config'
              : '{"sites":[{"key":"${o.uri.path}","api":"csp_Fixture"}]}',
        ),
      ),
    );
    late AppController controller;
    await tester.runAsync(() async {
      directory = await Directory.systemTemp.createTemp('single-subscription-');
      controller = AppController(
        store: AppStore(path: directory.path, secretStorage: MemorySecrets()),
        http: client,
        engine: TestEngine(client),
      );
      await controller.initialize();
    });
    await tester.pumpWidget(
      MaterialApp(home: SubscriptionsPage(controller: controller)),
    );
    final field = find.byType(TextField);
    expect(find.byTooltip('全网发现线路'), findsNothing);
    expect(find.text('内置 · 奇奇多仓'), findsNothing);
    expect(find.text(defaultSubscription), findsNothing);
    expect(tester.widget<TextField>(field).maxLines, 1);
    expect(tester.widget<TextField>(field).keyboardType, TextInputType.url);
    Future<void> append(String url) async {
      await tester.enterText(field, url);
      await tester.runAsync(() async {
        await tester.tap(find.widgetWithText(FilledButton, '追加订阅'));
        while (controller.batchImporting || controller.importing) {
          await Future<void>.delayed(const Duration(milliseconds: 10));
        }
      });
      await tester.pumpAndSettle();
    }

    await append('https://repo.test/first');
    expect(tester.widget<TextField>(field).controller!.text, isEmpty);
    await append('https://repo.test/second');
    expect(controller.subscriptions.map((s) => s.url), [
      'https://repo.test/first',
      'https://repo.test/second',
    ]);
    expect(controller.currentConfig?.url, 'https://repo.test/first');
    expect(tester.widget<TextField>(field).controller!.text, isEmpty);
    await append('https://repo.test/second');
    expect(controller.subscriptions, hasLength(2));
    expect(tester.widget<TextField>(field).controller!.text, isEmpty);
    await append('https://repo.test/bad');
    expect(
      tester.widget<TextField>(field).controller!.text,
      'https://repo.test/bad',
    );
    expect(controller.importError, isNotNull);
    await tester.pumpWidget(const SizedBox());
    await tester.runAsync(() async {
      await controller.disposeAsync();
      await directory.delete(recursive: true);
    });
  });

  testWidgets(
    'video subscription page does not label a plugin error as an import error',
    (tester) async {
      final controller = AppController()
        ..error = 'DexNative.getSpider: plugin incompatible';
      await tester.pumpWidget(
        MaterialApp(home: SubscriptionsPage(controller: controller)),
      );
      expect(find.byType(ErrorNotice), findsNothing);
      expect(controller.error, contains('DexNative.getSpider'));
      await tester.pumpWidget(const SizedBox());
      await controller.disposeAsync();
    },
  );

  testWidgets('video subscription import errors remain visible', (
    tester,
  ) async {
    final controller = AppController()
      ..error = 'Unrelated playback error'
      ..importError = '没有可加载的单仓配置，请查看入口诊断';
    await tester.pumpWidget(
      MaterialApp(home: SubscriptionsPage(controller: controller)),
    );
    expect(find.text(controller.importError!), findsOneWidget);
    expect(find.text(controller.error!), findsNothing);
    await tester.pumpWidget(const SizedBox());
    await controller.disposeAsync();
  });
}
