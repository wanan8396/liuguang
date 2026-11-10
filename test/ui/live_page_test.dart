import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:tvbox/core/app_controller.dart';
import 'package:tvbox/features/live/live_page.dart';
import 'package:tvbox/ui/components.dart';

class _Controller extends AppController {
  @override
  Future<void> loadLive() async {}
}

void main() {
  testWidgets('电视直播页只显示直播错误，首页插件失败不遮挡频道', (tester) async {
    final controller = _Controller()
      ..error = '荐片：Expected BEGIN_OBJECT but was STRING'
      ..liveChannels = [
        LiveChannel(name: '测试频道', urls: ['https://media.invalid/channel.m3u8']),
      ];
    await tester.pumpWidget(
      MaterialApp(home: LivePage(controller: controller)),
    );
    await tester.pumpAndSettle();
    expect(find.text('测试频道'), findsOneWidget);
    expect(find.byType(ErrorNotice), findsNothing);
    expect(find.text(controller.error!), findsNothing);

    controller.liveError = '直播列表连接失败';
    controller.refreshLibrary();
    await tester.pump();
    expect(find.text(controller.liveError!), findsNothing);
    expect(find.text('来源状态'), findsOneWidget);
    expect(find.text(controller.error!), findsNothing);
    expect(find.text('测试频道'), findsOneWidget);
    await tester.tap(find.text('来源状态'));
    await tester.pumpAndSettle();
    expect(find.text(controller.liveError!), findsOneWidget);

    await tester.pumpWidget(const SizedBox());
    await controller.disposeAsync();
  });
}
