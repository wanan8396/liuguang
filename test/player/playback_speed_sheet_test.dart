import 'dart:io';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:tvbox/features/player/playback_speed_sheet.dart';

const _writePreview = bool.fromEnvironment('WRITE_PLAYER_PREVIEW');

class _PickerHarness extends StatefulWidget {
  const _PickerHarness({required this.viewport, this.scale = 1});

  final Rect viewport;
  final double scale;

  @override
  State<_PickerHarness> createState() => _PickerHarnessState();
}

class _PickerHarnessState extends State<_PickerHarness> {
  final _button = GlobalKey();
  final _video = GlobalKey();
  double rate = 1;

  Rect _rect(GlobalKey key) {
    final box = key.currentContext!.findRenderObject()! as RenderBox;
    return box.localToGlobal(Offset.zero) & box.size;
  }

  @override
  Widget build(BuildContext context) => MaterialApp(
    theme: ThemeData(
      colorSchemeSeed: Colors.teal,
      fontFamily: _writePreview ? 'PreviewFont' : null,
    ),
    builder: (context, child) => MediaQuery(
      data: MediaQuery.of(
        context,
      ).copyWith(textScaler: TextScaler.linear(widget.scale)),
      child: child!,
    ),
    home: Scaffold(
      body: Builder(
        builder: (context) => Stack(
          children: [
            Positioned.fromRect(
              rect: widget.viewport,
              child: ColoredBox(
                key: _video,
                color: Colors.black,
                child: Stack(
                  children: [
                    Positioned(
                      bottom: 4,
                      right: 4,
                      child: PlaybackSpeedButton(
                        key: _button,
                        rate: rate,
                        onPressed: () async {
                          final selected = await showPlaybackSpeedPicker(
                            context,
                            rate: rate,
                            live: true,
                            anchor: _rect(_button),
                            viewport: _rect(_video),
                          );
                          if (selected != null) setState(() => rate = selected);
                        },
                      ),
                    ),
                  ],
                ),
              ),
            ),
          ],
        ),
      ),
    ),
  );
}

void main() {
  setUpAll(() async {
    if (!_writePreview) return;
    await (FontLoader(
      'MaterialIcons',
    )..addFont(rootBundle.load('fonts/MaterialIcons-Regular.otf'))).load();
    final font = File('C:/Windows/Fonts/msyh.ttc');
    if (await font.exists()) {
      final bytes = await font.readAsBytes();
      await (FontLoader(
        'PreviewFont',
      )..addFont(Future.value(ByteData.sublistView(bytes)))).load();
    }
  });
  for (final (size, viewport, scale) in [
    (const Size(400, 800), const Rect.fromLTWH(8, 88, 384, 252), 1.0),
    (const Size(800, 400), const Rect.fromLTWH(12, 16, 776, 348), 1.0),
    (const Size(400, 800), const Rect.fromLTWH(40, 100, 320, 180), 1.0),
    (const Size(320, 568), const Rect.fromLTWH(4, 56, 312, 150), 2.0),
  ]) {
    testWidgets('锚定浮层在 $size、视频 ${viewport.size}、字体 $scale 下不超出边缘', (
      tester,
    ) async {
      tester.view.physicalSize = size;
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      final preview = GlobalKey();
      await tester.pumpWidget(
        RepaintBoundary(
          key: preview,
          child: _PickerHarness(viewport: viewport, scale: scale),
        ),
      );
      expect(find.text('1.0x'), findsOneWidget);
      final buttonSize = tester.getSize(find.byType(TextButton));
      expect(buttonSize.height, greaterThanOrEqualTo(48));
      expect(buttonSize.width, greaterThanOrEqualTo(48));
      if (scale == 1) expect(buttonSize.width, lessThanOrEqualTo(88));
      final anchor = tester.getRect(find.byType(PlaybackSpeedButton));
      await tester.tap(find.byType(PlaybackSpeedButton));
      await tester.pumpAndSettle();
      final picker = find.byType(PlaybackSpeedPicker);
      final bounds = tester.getRect(picker);
      final available = viewport.deflate(8);
      expect(bounds.left, greaterThanOrEqualTo(available.left));
      expect(bounds.top, greaterThanOrEqualTo(available.top));
      expect(bounds.right, lessThanOrEqualTo(available.right));
      expect(bounds.bottom, lessThanOrEqualTo(available.bottom));
      expect(find.text('播放速度'), findsOneWidget);
      expect(find.text('直播建议 1.0x，倍速受频道缓冲限制'), findsOneWidget);
      expect(find.byIcon(Icons.check_rounded), findsOneWidget);
      if (scale == 1) {
        if (viewport.height >= 220) {
          expect(bounds.bottom, lessThanOrEqualTo(anchor.top - 6));
        }
        expect(bounds.width, lessThanOrEqualTo(248));
        expect(bounds.height, lessThan(200));
      }
      final optionRects = <Rect>[];
      for (final rate in [.5, .75, 1.0, 1.25, 1.5, 1.75, 2.0, 3.0]) {
        expect(
          find.descendant(of: picker, matching: find.text('${rate}x')),
          findsOneWidget,
        );
        final optionRect = tester.getRect(
          find.descendant(
            of: picker,
            matching: find.widgetWithText(InkWell, '${rate}x'),
          ),
        );
        optionRects.add(optionRect);
        expect(optionRect.width, greaterThanOrEqualTo(48));
        expect(optionRect.height, greaterThanOrEqualTo(48));
      }
      expect(optionRects.take(4).map((rect) => rect.top).toSet(), hasLength(1));
      expect(optionRects.skip(4).map((rect) => rect.top).toSet(), hasLength(1));
      expect(optionRects.last.top, greaterThan(optionRects.first.top));
      if (viewport.size == const Size(320, 180)) {
        expect(optionRects.last.bottom, lessThanOrEqualTo(bounds.bottom));
        final hint = tester.getRect(find.text('直播建议 1.0x，倍速受频道缓冲限制'));
        expect(hint.bottom, lessThanOrEqualTo(bounds.bottom));
        if (_writePreview) {
          await tester.runAsync(() async {
            final boundary =
                preview.currentContext!.findRenderObject()!
                    as RenderRepaintBoundary;
            final image = await boundary.toImage(pixelRatio: 2);
            final crop = viewport.inflate(12);
            final recorder = ui.PictureRecorder();
            Canvas(recorder).drawImageRect(
              image,
              Rect.fromLTWH(
                crop.left * 2,
                crop.top * 2,
                crop.width * 2,
                crop.height * 2,
              ),
              Rect.fromLTWH(0, 0, crop.width * 2, crop.height * 2),
              Paint(),
            );
            final picture = recorder.endRecording();
            final cropped = await picture.toImage(
              (crop.width * 2).round(),
              (crop.height * 2).round(),
            );
            final data = await cropped.toByteData(
              format: ui.ImageByteFormat.png,
            );
            final file = File(
              'artifacts/stability-20261109/playback-speed-picker-320x180.png',
            );
            await file.parent.create(recursive: true);
            await file.writeAsBytes(data!.buffer.asUint8List());
            image.dispose();
            cropped.dispose();
            picture.dispose();
          });
        }
      }
      await tester.ensureVisible(find.text('3.0x'));
      await tester.tap(find.text('3.0x'));
      await tester.pumpAndSettle();
      expect(find.text('3.0x'), findsOneWidget);
      expect(picker, findsNothing);

      await tester.tap(find.byType(PlaybackSpeedButton));
      await tester.pumpAndSettle();
      await tester.tapAt(Offset(size.width / 2, size.height - 8));
      await tester.pumpAndSettle();
      expect(picker, findsNothing);
      expect(find.text('3.0x'), findsOneWidget);
      expect(tester.takeException(), isNull);
    });
  }
}
