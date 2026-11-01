import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:media_kit/media_kit.dart';

import 'app.dart';
import 'core/app_controller.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  MediaKit.ensureInitialized();
  final controller = AppController();
  try {
    await controller.initialize();
    runApp(
      ProviderScope(
        overrides: [appControllerProvider.overrideWithValue(controller)],
        child: const LiuguangApp(),
      ),
    );
  } catch (error) {
    runApp(
      MaterialApp(
        home: Scaffold(
          body: SafeArea(
            child: Center(
              child: Padding(
                padding: const EdgeInsets.all(24),
                child: SelectableText(
                  '流光启动失败\n\n$error\n\n请保留数据后重新启动，不需要清除收藏与历史。',
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}
