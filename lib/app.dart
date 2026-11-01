import 'package:flutter/material.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'core/app_controller.dart';
import 'features/shell/app_shell.dart';

final appControllerProvider = Provider<AppController>((ref) {
  throw StateError('AppController must be initialized before mounting the app');
});

class LiuguangApp extends ConsumerWidget {
  const LiuguangApp({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final controller = ref.watch(appControllerProvider);
    return ListenableBuilder(
      listenable: controller,
      builder: (context, _) => MaterialApp(
        title: '流光',
        debugShowCheckedModeBanner: false,
        locale: const Locale('zh', 'CN'),
        supportedLocales: const [Locale('zh', 'CN'), Locale('en')],
        localizationsDelegates: GlobalMaterialLocalizations.delegates,
        theme: _theme(Brightness.light),
        darkTheme: _theme(Brightness.dark),
        themeMode: controller.themeMode,
        home: AppShell(controller: controller),
      ),
    );
  }
}

ThemeData _theme(Brightness brightness) {
  final dark = brightness == Brightness.dark;
  final colors = ColorScheme.fromSeed(
    seedColor: const Color(0xFF2797F3),
    brightness: brightness,
    surface: dark ? const Color(0xFF131820) : const Color(0xFFFFFFFF),
  );
  return ThemeData(
    useMaterial3: true,
    colorScheme: colors,
    scaffoldBackgroundColor: dark
        ? const Color(0xFF0C1119)
        : const Color(0xFFF4F7FB),
    appBarTheme: AppBarTheme(
      backgroundColor: dark ? const Color(0xFF0C1119) : Colors.white,
      surfaceTintColor: Colors.transparent,
      elevation: 0,
      centerTitle: false,
      titleTextStyle: TextStyle(
        color: colors.onSurface,
        fontSize: 21,
        fontWeight: FontWeight.w700,
      ),
    ),
    cardTheme: CardThemeData(
      color: colors.surface,
      elevation: 0,
      margin: EdgeInsets.zero,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(18)),
    ),
    inputDecorationTheme: InputDecorationTheme(
      filled: true,
      fillColor: dark ? const Color(0xFF1D2531) : const Color(0xFFF0F3F7),
      border: OutlineInputBorder(
        borderRadius: BorderRadius.circular(14),
        borderSide: BorderSide.none,
      ),
      contentPadding: const EdgeInsets.symmetric(horizontal: 16, vertical: 14),
    ),
    navigationBarTheme: NavigationBarThemeData(
      backgroundColor: colors.surface,
      surfaceTintColor: Colors.transparent,
      indicatorColor: colors.primaryContainer,
      height: 70,
      labelBehavior: NavigationDestinationLabelBehavior.alwaysShow,
    ),
    filledButtonTheme: FilledButtonThemeData(
      style: FilledButton.styleFrom(
        minimumSize: const Size(48, 46),
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(13)),
      ),
    ),
    dividerTheme: DividerThemeData(
      color: colors.outlineVariant.withValues(alpha: 0.5),
      thickness: 0.5,
    ),
  );
}
