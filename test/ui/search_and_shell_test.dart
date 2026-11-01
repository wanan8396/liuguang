import 'dart:async';
import 'dart:io';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:tvbox/core/app_controller.dart';
import 'package:tvbox/features/detail/detail_page.dart';
import 'package:tvbox/features/search/search_page.dart';
import 'package:tvbox/features/shell/app_shell.dart';

class _FakeController extends AppController {
  _FakeController({bool sources = false}) {
    if (sources) {
      repositories = [
        for (var i = 0; i < 5; i++)
          TvConfig(
            url: 'https://repo.test/$i',
            name: '仓库$i',
            raw: {
              'sites': [
                {'key': 'site$i', 'name': '来源$i', 'type': 1},
              ],
            },
          ),
      ];
      currentConfig = repositories.first;
      currentSite = repositories.first.sites.first;
    }
  }
  List<TvConfig> repositories = [];
  final requests = <(String, String)>[];
  final pending = <Completer<VodPage>>[];
  bool delayed = false;
  int active = 0, maxActive = 0, cancelled = 0;
  (String, String)? detailOrigin;
  @override
  List<TvConfig> get configs => repositories;
  @override
  List<Site> enabledSites([TvConfig? config]) =>
      (config ?? currentConfig)?.sites ?? [];
  @override
  Future<void> refreshHome() async {}
  @override
  Future<void> loadLive() async {}
  @override
  void cancelSearch() {
    cancelled++;
  }

  @override
  Future<VodPage> search(
    String keyword, {
    Site? site,
    TvConfig? config,
    int page = 1,
  }) async {
    requests.add((config!.url, site!.key));
    active++;
    if (active > maxActive) maxActive = active;
    try {
      if (delayed) {
        final result = Completer<VodPage>();
        pending.add(result);
        return await result.future;
      }
      return VodPage(
        items: [
          Vod({'vod_id': 'same-id', 'vod_name': '${site.name}影片'}),
        ],
      );
    } finally {
      active--;
    }
  }

  @override
  Future<VodDetail> detail(Vod vod, {Site? site, TvConfig? config}) async {
    detailOrigin = (config!.url, site!.key);
    return VodDetail(vod: vod, lines: []);
  }
}

void main() {
  testWidgets('aggregated search preserves source when opening detail', (
    tester,
  ) async {
    final controller = _FakeController(sources: true);
    await tester.pumpWidget(
      MaterialApp(home: SearchPage(controller: controller)),
    );
    await tester.tap(find.text('全部'));
    await tester.enterText(find.byType(TextField), '影片');
    await tester.tap(find.byTooltip('搜索'));
    await tester.pumpAndSettle();
    expect(controller.requests.length, 5);
    expect(find.text('来源1影片'), findsOneWidget);
    await tester.tap(find.text('来源1影片'));
    await tester.pumpAndSettle();
    expect(find.byType(DetailPage), findsOneWidget);
    expect(controller.detailOrigin, ('https://repo.test/1', 'site1'));
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox());
    await controller.disposeAsync();
  });

  testWidgets(
    'aggregate search is capped at three and cancellation stops queued work',
    (tester) async {
      final controller = _FakeController(sources: true)..delayed = true;
      await tester.pumpWidget(
        MaterialApp(home: SearchPage(controller: controller)),
      );
      await tester.tap(find.text('全部'));
      await tester.enterText(find.byType(TextField), '影片');
      await tester.tap(find.byTooltip('搜索'));
      await tester.pump();
      expect(controller.requests.length, 3);
      expect(controller.maxActive, 3);
      await tester.tap(find.byTooltip('取消搜索'));
      await tester.pump();
      for (final request in controller.pending) {
        request.complete(
          VodPage(
            items: [
              Vod({'vod_name': '迟到结果'}),
            ],
          ),
        );
      }
      await tester.pumpAndSettle();
      expect(controller.requests.length, 3);
      expect(controller.cancelled, 1);
      expect(find.text('迟到结果'), findsNothing);
      await tester.pumpWidget(const SizedBox());
      await controller.disposeAsync();
    },
  );

  testWidgets(
    'shell renders honest empty state, profile navigation, and screenshot artifacts',
    (tester) async {
      tester.view.physicalSize = const Size(400, 880);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      final chineseFontPath = Platform.environment['CI_CJK_FONT']?.trim();
      if (chineseFontPath != null && chineseFontPath.isNotEmpty) {
        final font = File(chineseFontPath);
        if (!font.existsSync()) {
          throw StateError('CI_CJK_FONT does not exist: $chineseFontPath');
        }
        final loader = FontLoader('UiChinese');
        loader.addFont(Future.value(ByteData.sublistView(font.readAsBytesSync())));
        await loader.load();
      }
      final flutterRoot = Platform.environment['FLUTTER_ROOT']?.trim();
      if (flutterRoot != null && flutterRoot.isNotEmpty) {
        final iconPath =
            '$flutterRoot/bin/cache/artifacts/material_fonts/MaterialIcons-Regular.otf';
        final font = File(iconPath);
        if (!font.existsSync()) {
          throw StateError('Flutter Material Icons font does not exist: $iconPath');
        }
        final icons = FontLoader('MaterialIcons');
        icons.addFont(Future.value(ByteData.sublistView(font.readAsBytesSync())));
        await icons.load();
      }
      final artifactPath = Platform.environment['UI_ARTIFACT_DIR']?.trim();
      final controller = _FakeController();
      final boundaryKey = GlobalKey();
      await tester.pumpWidget(
        RepaintBoundary(
          key: boundaryKey,
          child: MaterialApp(
            debugShowCheckedModeBanner: false,
            theme: ThemeData(
              useMaterial3: true,
              fontFamily:
                  chineseFontPath != null && chineseFontPath.isNotEmpty
                  ? 'UiChinese'
                  : null,
              scaffoldBackgroundColor: const Color(0xfff4f7fb),
              colorScheme: ColorScheme.fromSeed(
                seedColor: const Color(0xff2797f3),
                surface: Colors.white,
              ),
              cardTheme: CardThemeData(
                elevation: 0,
                color: Colors.white,
                shape: RoundedRectangleBorder(
                  borderRadius: BorderRadius.circular(18),
                ),
              ),
            ),
            home: AppShell(controller: controller),
          ),
        ),
      );
      await tester.pumpAndSettle();
      expect(find.text('把喜欢的内容装进流光'), findsOneWidget);
      expect(tester.takeException(), isNull);
      Future<void> capture(String name) async {
        if (artifactPath == null || artifactPath.isEmpty) return;
        final boundary =
            boundaryKey.currentContext!.findRenderObject()!
                as RenderRepaintBoundary;
        await tester.runAsync(() async {
          final image = await boundary.toImage(pixelRatio: 1);
          try {
            final data = await image.toByteData(format: ui.ImageByteFormat.png);
            if (data == null) throw StateError('Unable to encode $name as PNG');
            await Directory(artifactPath).create(recursive: true);
            await File(
              '$artifactPath${Platform.pathSeparator}$name.png',
            ).writeAsBytes(
              data.buffer.asUint8List(data.offsetInBytes, data.lengthInBytes),
            );
          } finally {
            image.dispose();
          }
        });
      }

      await capture('ui-home');
      await tester.tap(find.text('我的'));
      await tester.pumpAndSettle();
      expect(find.text('我的流光'), findsOneWidget);
      expect(find.text('源管理与凭据'), findsOneWidget);
      expect(tester.takeException(), isNull);
      await capture('ui-profile');
      await tester.pumpWidget(const SizedBox());
      await controller.disposeAsync();
    },
  );
}
