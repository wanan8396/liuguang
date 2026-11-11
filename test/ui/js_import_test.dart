import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:tvbox/core/app_controller.dart';
import 'package:tvbox/core/network/app_http_client.dart';
import 'package:tvbox/core/storage/app_store.dart';
import 'package:tvbox/features/profile/subscriptions_page.dart';

import '../config/config_test.dart' show Adapter;
import '../controller/app_controller_test.dart' show MemorySecrets, TestEngine;

void main() {
  testWidgets('Windows hides scanner and keeps file/text import actions', (
    tester,
  ) async {
    debugDefaultTargetPlatformOverride = TargetPlatform.windows;
    addTearDown(() => debugDefaultTargetPlatformOverride = null);
    final controller = AppController();
    await tester.pumpWidget(
      MaterialApp(home: SubscriptionsPage(controller: controller)),
    );
    expect(find.byTooltip('扫码填写地址'), findsNothing);
    expect(find.byType(ScannerPage), findsNothing);
    expect(find.byTooltip('粘贴配置或 JS'), findsOneWidget);
    expect(find.byTooltip('导入本地配置'), findsOneWidget);
    await tester.pumpWidget(const SizedBox());
    await controller.disposeAsync();
    debugDefaultTargetPlatformOverride = null;
  });

  testWidgets('iOS retains scanner and JS import actions', (tester) async {
    debugDefaultTargetPlatformOverride = TargetPlatform.iOS;
    addTearDown(() => debugDefaultTargetPlatformOverride = null);
    final controller = AppController();
    await tester.pumpWidget(
      MaterialApp(home: SubscriptionsPage(controller: controller)),
    );
    expect(find.byTooltip('扫码填写地址'), findsOneWidget);
    expect(find.byTooltip('粘贴配置或 JS'), findsOneWidget);
    expect(find.byType(ScannerPage), findsNothing);
    await tester.pumpWidget(const SizedBox());
    await controller.disposeAsync();
    debugDefaultTargetPlatformOverride = null;
  });

  testWidgets('file selector accepts JavaScript alongside existing JSON/text', (
    tester,
  ) async {
    const channel = MethodChannel('plugins.flutter.io/file_selector');
    MethodCall? selection;
    tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(channel, (
      call,
    ) async {
      selection = call;
      return null;
    });
    addTearDown(
      () => tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
        channel,
        null,
      ),
    );
    final controller = AppController();
    await tester.pumpWidget(
      MaterialApp(home: SubscriptionsPage(controller: controller)),
    );
    await tester.tap(find.byTooltip('导入本地配置'));
    await tester.pumpAndSettle();
    expect(selection?.method, 'openFile');
    final arguments = selection!.arguments as Map;
    final group = (arguments['acceptedTypeGroups'] as List).single as Map;
    expect(group['extensions'], containsAll(['json', 'txt', 'js']));
    expect(group['mimeTypes'], contains('application/javascript'));
    expect(
      group['uniformTypeIdentifiers'],
      contains('com.netscape.javascript-source'),
    );
    expect(controller.subscriptions, isEmpty);
    await tester.pumpWidget(const SizedBox());
    await controller.disposeAsync();
  });

  testWidgets(
    'paste dialog imports JS and local source is not remotely refreshed',
    (tester) async {
      tester.view.physicalSize = const Size(1000, 1200);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      late Directory directory;
      late AppController controller;
      final adapter = Adapter((_) => throw StateError('Unexpected HTTP'));
      final client = AppHttpClient(adapter: adapter);
      await tester.runAsync(() async {
        directory = await Directory.systemTemp.createTemp('js-import-ui-');
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
      await tester.runAsync(() => tester.tap(find.byTooltip('粘贴配置或 JS')));
      await tester.pumpAndSettle();
      final input = find.descendant(
        of: find.byType(AlertDialog),
        matching: find.byType(TextField),
      );
      expect(tester.widget<TextField>(input).maxLines, 12);
      expect(
        tester
            .widget<FilledButton>(find.widgetWithText(FilledButton, '导入'))
            .onPressed,
        isNull,
      );
      const source =
          'const rule = {title: "粘贴规则", host: "https://fixture.test"};';
      await tester.enterText(input, source);
      await tester.pump();
      await tester.runAsync(() async {
        await tester.tap(find.widgetWithText(FilledButton, '导入'));
        await Future<void>.delayed(Duration.zero);
        for (
          var attempt = 0;
          controller.importing && attempt < 100;
          attempt++
        ) {
          await Future<void>.delayed(const Duration(milliseconds: 10));
        }
        expect(controller.importing, false);
      });
      await tester.pumpAndSettle();
      expect(find.byType(AlertDialog), findsNothing);
      expect(controller.subscriptions, hasLength(1));
      expect(controller.currentSite?.raw['_jsSource'], source);
      expect(controller.currentSite?.name, '粘贴规则');
      expect(controller.importError, isNull);
      expect(find.text('全部刷新'), findsNothing);
      await tester.tap(find.byType(ExpansionTile));
      await tester.pumpAndSettle();
      expect(find.text('粘贴规则'), findsOneWidget);
      expect(
        tester
            .widget<TextButton>(find.widgetWithText(TextButton, '本地导入'))
            .onPressed,
        isNull,
      );
      expect(adapter.requests, isEmpty);
      await tester.pumpWidget(const SizedBox());
      await tester.runAsync(() async {
        await controller.disposeAsync();
        await directory.delete(recursive: true);
      });
    },
  );
}
