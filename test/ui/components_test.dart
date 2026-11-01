import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:tvbox/core/models/models.dart';
import 'package:tvbox/ui/components.dart';

void main() {
  test(
    'explicit image headers override safe defaults without leaking cookies',
    () {
      final config = TvConfig(
        url: 'https://repo.test/config',
        name: '仓库',
        raw: {
          'imageHeaders': {'Referer': 'https://image.test/'},
          'ua': 'CustomAgent',
          'headers': {'Cookie': 'private-token'},
        },
      );
      final site = Site({
        'key': 'a',
        'picHeader': '{"Origin":"https://site.test"}',
      });
      final vod = Vod({
        'vod_pic_header': {'Referer': 'https://video.test/'},
      });
      final result = imageHeaders(config, site, vod);
      expect(result['User-Agent'], 'CustomAgent');
      expect(result['Referer'], 'https://video.test/');
      expect(result['Origin'], 'https://site.test');
      expect(result.containsKey('Cookie'), false);
    },
  );
  test('plain text and time formatting preserve real metadata', () {
    expect(plainText('<p>剧情 &amp; 简介</p>'), '剧情 & 简介');
    expect(timeLabel(const Duration(seconds: 65)), '01:05');
    expect(timeLabel(const Duration(seconds: 3661)), '1:01:01');
  });
  testWidgets('empty state action is bound', (tester) async {
    var clicked = 0;
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: EmptyState(
            title: '没有订阅',
            message: '添加真实订阅',
            actionLabel: '添加',
            action: () => clicked++,
          ),
        ),
      ),
    );
    await tester.tap(find.text('添加'));
    expect(clicked, 1);
    expect(find.text('没有订阅'), findsOneWidget);
  });
  testWidgets(
    'poster without image uses honest placeholder and tile has no playable badge',
    (tester) async {
      var clicked = false;
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: SizedBox(
              width: 130,
              height: 220,
              child: VodTile(
                vod: Vod({'vod_name': '真实名称', 'vod_remarks': '更新至3集'}),
                source: '测试来源',
                onTap: () => clicked = true,
              ),
            ),
          ),
        ),
      );
      expect(find.byIcon(Icons.image_not_supported_outlined), findsOneWidget);
      expect(find.byIcon(Icons.play_circle), findsNothing);
      expect(find.text('测试来源'), findsOneWidget);
      await tester.tap(find.text('真实名称'));
      expect(clicked, true);
    },
  );
  testWidgets('error message and retry are visible', (tester) async {
    var count = 0;
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: ErrorNotice(error: '真实网络错误', onRetry: () => count++),
        ),
      ),
    );
    expect(find.text('真实网络错误'), findsOneWidget);
    await tester.tap(find.byTooltip('重试'));
    expect(count, 1);
  });
}
