import 'dart:async';
import 'dart:io';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:tvbox/core/app_controller.dart';
import 'package:tvbox/core/search/search_concurrency.dart';
import 'package:tvbox/core/storage/app_store.dart';
import 'package:tvbox/features/profile/library_page.dart';
import 'package:tvbox/features/detail/detail_page.dart';
import 'package:tvbox/features/search/search_page.dart';
import 'package:tvbox/features/shell/app_shell.dart';

class _MemorySettings extends AppStore {
  final values = <String, Object?>{};
  @override
  Object? setting(String key) => values[key];
  @override
  Future<void> setSetting(String key, Object? value) async {
    values[key] = value;
  }
}

class _FakeController extends AppController {
  _FakeController({bool sources = false, int sourceCount = 5, AppStore? store})
    : super(store: store) {
    if (sources) {
      repositories = [
        for (var i = 0; i < sourceCount; i++)
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
    'default 16 I/O concurrency, cancel stops queue and isolates old responses',
    (tester) async {
      final controller = _FakeController(sources: true, sourceCount: 40)
        ..delayed = true;
      await tester.pumpWidget(
        MaterialApp(home: SearchPage(controller: controller)),
      );
      await tester.tap(find.text('全部'));
      await tester.enterText(find.byType(TextField), '旧搜索');
      await tester.tap(find.byTooltip('搜索'));
      await tester.pump();
      expect(controller.requests.length, 16);
      expect(controller.maxActive, 16);
      await tester.tap(find.byTooltip('取消搜索'));
      await tester.pump();
      expect(controller.cancelled, 1);
      final oldRequests = controller.pending.toList();
      await tester.enterText(find.byType(TextField), '新搜索');
      await tester.tap(find.byTooltip('搜索'));
      await tester.pump();
      expect(controller.requests.length, 32);
      // Old success and failure cannot mutate the new run or start queued work.
      oldRequests.first.completeError(StateError('旧搜索错误'));
      for (final request in oldRequests.skip(1)) {
        request.complete(
          VodPage(
            items: [
              Vod({'vod_name': '迟到结果'}),
            ],
          ),
        );
      }
      await tester.pump();
      expect(controller.requests.length, 32);
      expect(find.text('迟到结果'), findsNothing);
      expect(find.text('1 个站点提示'), findsNothing);
      expect(find.text('搜索(0/40)'), findsOneWidget);
      await tester.tap(find.byTooltip('取消搜索'));
      for (final request in controller.pending.skip(16)) {
        request.complete(VodPage(items: []));
      }
      await tester.pumpAndSettle();
      expect(controller.requests.length, 32);
      expect(controller.cancelled, 2);
      await tester.pumpWidget(const SizedBox());
      await controller.disposeAsync();
    },
  );
  testWidgets('source error and timeout do not discard successful results', (
    tester,
  ) async {
    final controller = _FakeController(sources: true)..delayed = true;
    await tester.pumpWidget(
      MaterialApp(home: SearchPage(controller: controller)),
    );
    await tester.tap(find.text('全部'));
    await tester.enterText(find.byType(TextField), '影片');
    await tester.tap(find.byTooltip('搜索'));
    await tester.pump();
    controller.pending[0].completeError(StateError('单源失败'));
    for (final request in controller.pending.skip(1).take(3)) {
      request.complete(
        VodPage(
          items: [
            Vod({'vod_name': '成功影片'}),
          ],
        ),
      );
    }
    await tester.pump();
    expect(find.text('搜索(4/5)'), findsOneWidget);
    await tester.pump(SearchConcurrency.sourceTimeout);
    await tester.pumpAndSettle();
    expect(find.text('搜索(5/5)'), findsOneWidget);
    expect(find.text('2 个站点提示'), findsOneWidget);
    expect(find.text('成功影片'), findsWidgets);
    expect(find.byTooltip('取消搜索'), findsNothing);
    controller.pending.last.complete(
      VodPage(
        items: [
          Vod({'vod_name': '超时迟到'}),
        ],
      ),
    );
    await tester.pumpAndSettle();
    expect(find.text('超时迟到'), findsNothing);
    await tester.pumpWidget(const SizedBox());
    await controller.disposeAsync();
  });
  testWidgets('concurrency selector saves and reloads 8 and 32', (
    tester,
  ) async {
    final store = _MemorySettings();
    final controller = _FakeController(store: store);
    for (final value in [8, 32]) {
      await tester.pumpWidget(
        MaterialApp(home: SearchPage(controller: controller)),
      );
      await tester.tap(find.byKey(const ValueKey('search-concurrency')));
      await tester.pumpAndSettle();
      await tester.tap(find.text('$value').last);
      await tester.pumpAndSettle();
      expect(store.setting(SearchConcurrency.settingKey), value);
      await tester.pumpWidget(const SizedBox());
      await tester.pumpWidget(
        MaterialApp(home: SearchPage(controller: controller)),
      );
      final selector = tester.widget<DropdownButton<int>>(
        find.byKey(const ValueKey('search-concurrency')),
      );
      expect(selector.value, value);
    }
    await tester.pumpWidget(const SizedBox());
    await controller.disposeAsync();
  });
  testWidgets('saved limit controls queued source starts', (tester) async {
    for (final limit in [8, 32]) {
      final store = _MemorySettings()
        ..values[SearchConcurrency.settingKey] = limit;
      final controller = _FakeController(
        store: store,
        sources: true,
        sourceCount: 40,
      )..delayed = true;
      await tester.pumpWidget(
        MaterialApp(home: SearchPage(controller: controller)),
      );
      await tester.tap(find.text('全部'));
      await tester.enterText(find.byType(TextField), '影片');
      await tester.tap(find.byTooltip('搜索'));
      await tester.pump();
      expect(controller.requests.length, limit);
      expect(controller.maxActive, limit);
      controller.pending.first.complete(VodPage(items: []));
      await tester.pump();
      expect(controller.requests.length, limit + 1);
      await tester.tap(find.byTooltip('取消搜索'));
      for (final request in controller.pending.skip(1)) {
        request.complete(VodPage(items: []));
      }
      await tester.pumpAndSettle();
      expect(controller.requests.length, limit + 1);
      await tester.pumpWidget(const SizedBox());
      await controller.disposeAsync();
    }
  });
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
        loader.addFont(
          Future.value(ByteData.sublistView(font.readAsBytesSync())),
        );
        await loader.load();
      }
      final flutterRoot = Platform.environment['FLUTTER_ROOT']?.trim();
      if (flutterRoot != null && flutterRoot.isNotEmpty) {
        final iconPath =
            '$flutterRoot/bin/cache/artifacts/material_fonts/MaterialIcons-Regular.otf';
        final font = File(iconPath);
        if (!font.existsSync()) {
          throw StateError(
            'Flutter Material Icons font does not exist: $iconPath',
          );
        }
        final icons = FontLoader('MaterialIcons');
        icons.addFont(
          Future.value(ByteData.sublistView(font.readAsBytesSync())),
        );
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
              fontFamily: chineseFontPath != null && chineseFontPath.isNotEmpty
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
      // Reuse the existing top-right action, rather than adding another entry.
      expect(find.byTooltip('播放历史'), findsOneWidget);
      await tester.tap(find.byTooltip('播放历史'));
      await tester.pumpAndSettle();
      expect(find.byType(LibraryPage), findsOneWidget);
      expect(
        tester.widget<LibraryPage>(find.byType(LibraryPage)).history,
        isTrue,
      );
      expect(find.text('还没有观看记录'), findsOneWidget);
      expect(find.text('播放后的进度会保存在这里。'), findsOneWidget);
      expect(find.byTooltip('清空观看历史'), findsNothing);
      await tester.pageBack();
      await tester.pumpAndSettle();
      expect(find.text('把喜欢的内容装进流光'), findsOneWidget);
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
