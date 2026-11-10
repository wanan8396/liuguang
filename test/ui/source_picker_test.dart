import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:tvbox/core/app_controller.dart';
import 'package:tvbox/ui/components.dart';

class _SourceController extends AppController {
  final repositories = [
    TvConfig(
      url: 'https://one.test/',
      name: '日光仓库',
      raw: {
        'sites': [
          {'key': 'first', 'name': '电影精选', 'api': 'csp_First', 'type': 3},
        ],
      },
    ),
    TvConfig(
      url: 'https://two.test/',
      name: '月光仓库',
      raw: {
        'sites': [
          {'key': 'second', 'name': '音乐现场', 'api': 'csp_Second', 'type': 3},
        ],
      },
    ),
  ];
  @override
  List<TvConfig> get configs => repositories;
  @override
  List<Site> enabledSites([TvConfig? config]) =>
      (config ?? currentConfig)!.sites;
  @override
  Future<void> selectConfig(TvConfig config) async {
    currentConfig = config;
    currentSite = config.sites.first;
    notifyListeners();
  }

  @override
  Future<void> selectSource(TvConfig config, Site site) async {
    currentConfig = config;
    currentSite = site;
    notifyListeners();
  }

  @override
  String configName(TvConfig? config) =>
      config?.url == 'https://two.test/' ? '月光仓库' : super.configName(config);
}

void main() {
  testWidgets(
    'source picker searches across repositories and selects the matching source',
    (tester) async {
      tester.view.physicalSize = const Size(360, 780);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      final controller = _SourceController();
      // Original imported name may still be a URL; the saved name is displayed.
      controller.repositories[1] = TvConfig(
        url: controller.repositories[1].url,
        name: controller.repositories[1].url,
        raw: controller.repositories[1].raw,
      );
      addTearDown(controller.dispose);
      await controller.selectConfig(controller.repositories.first);
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: Builder(
              builder: (context) => TextButton(
                onPressed: () => chooseSource(context, controller),
                child: const Text('选择来源'),
              ),
            ),
          ),
        ),
      );
      await tester.tap(find.text('选择来源'));
      await tester.pumpAndSettle();
      expect(find.text('电影精选'), findsOneWidget);
      await tester.tap(find.text('月光仓库'));
      await tester.pumpAndSettle();
      expect(find.text('音乐现场'), findsOneWidget);
      // Searching includes a source outside the browsed repository.
      await tester.enterText(find.byType(TextField), '电影');
      await tester.pumpAndSettle();
      expect(find.text('电影精选'), findsOneWidget);
      expect(find.text('音乐现场'), findsNothing);
      await tester.enterText(find.byType(TextField), '不存在');
      await tester.pumpAndSettle();
      expect(find.text('没有找到匹配的内容源'), findsOneWidget);
      await tester.enterText(find.byType(TextField), '音乐');
      await tester.pumpAndSettle();
      await tester.tap(find.text('音乐现场'));
      await tester.pumpAndSettle();
      expect(controller.currentConfig?.url, 'https://two.test/');
      expect(controller.currentSite?.key, 'second');
      expect(find.text('选择内容源'), findsNothing);
      expect(tester.takeException(), isNull);
    },
  );
}
