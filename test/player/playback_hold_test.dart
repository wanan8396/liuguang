import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:tvbox/features/player/playback_hold_region.dart';
import 'package:tvbox/features/player/playback_rate_controller.dart';

void main() {
  test('松手恢复选择的速度，包括慢放和3倍速', () async {
    for (final rate in [.5, 1.0, 1.5, 3.0]) {
      final writes = <double>[];
      final control = PlaybackRateController(
        (value) async => writes.add(value),
      );
      await control.select(rate);
      await control.beginHold();
      await control.beginHold();
      expect(control.effective, 2);
      expect(control.selected, rate);
      await control.endHold();
      await control.endHold();
      expect(control.effective, rate);
      expect(writes, [rate, 2, rate]);
    }
  });

  test('快速松手时按顺序等待2倍速写入，再恢复，不能停留在2倍', () async {
    final writes = <double>[];
    final applying = Completer<void>();
    final control = PlaybackRateController((value) async {
      writes.add(value);
      if (value == 2) await applying.future;
    });
    await control.select(1.25);
    final press = control.beginHold();
    await Future<void>.delayed(Duration.zero);
    final release = control.endHold();
    expect(writes, [1.25, 2]);
    expect(control.holding, false);
    applying.complete();
    await Future.wait([press, release]);
    expect(writes, [1.25, 2, 1.25]);
  });

  test('引擎拒绝倍速后仍可继续操作，关闭后不再调用播放器', () async {
    final writes = <double>[];
    final control = PlaybackRateController((value) async {
      if (value == 2) throw StateError('rate unavailable');
      writes.add(value);
    });
    await control.select(1.5);
    await expectLater(control.beginHold(), throwsStateError);
    expect(control.holding, false);
    expect(control.effective, 1.5);
    await expectLater(control.select(2), throwsStateError);
    expect(control.selected, 1.5);
    await control.select(1);
    await control.close();
    await control.beginHold();
    await control.select(3);
    expect(writes, [1.5, 1]);
  });

  Future<void> mount(
    WidgetTester tester,
    PlaybackRateController control, {
    bool enabled = true,
    VoidCallback? onTap,
  }) async {
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: PlaybackHoldRegion(
            enabled: enabled,
            onStart: () => unawaited(control.beginHold()),
            onEnd: () => unawaited(control.endHold()),
            child: GestureDetector(
              onTap: onTap,
              onHorizontalDragUpdate: (_) {},
              child: const SizedBox(
                width: 320,
                height: 180,
                child: ColoredBox(color: Colors.black),
              ),
            ),
          ),
        ),
      ),
    );
  }

  testWidgets('按住画面才加速，松手及系统取消均恢复', (tester) async {
    final writes = <double>[];
    final control = PlaybackRateController((value) async => writes.add(value));
    await control.select(1.5);
    await mount(tester, control);
    for (final cancel in [false, true]) {
      final touch = await tester.startGesture(const Offset(160, 90));
      await tester.pump(const Duration(milliseconds: 600));
      expect(control.holding, true);
      expect(control.effective, 2);
      if (cancel) {
        await touch.cancel();
      } else {
        await touch.up();
      }
      await tester.pump();
      expect(control.holding, false);
      expect(control.effective, 1.5);
    }
    expect(writes, [1.5, 2, 1.5, 2, 1.5]);
  });

  testWidgets('短按、横向手势和禁用状态不触发临时倍速', (tester) async {
    final writes = <double>[];
    var taps = 0;
    final control = PlaybackRateController((value) async => writes.add(value));
    await mount(tester, control, onTap: () => taps++);
    await tester.tapAt(const Offset(160, 90));
    await tester.pump();
    expect(taps, 1);
    await tester.dragFrom(const Offset(100, 90), const Offset(100, 0));
    await tester.pump(const Duration(milliseconds: 600));
    expect(writes, isEmpty);
    await mount(tester, control, enabled: false);
    await tester.longPressAt(const Offset(160, 90));
    await tester.pump();
    expect(writes, isEmpty);
  });
}
