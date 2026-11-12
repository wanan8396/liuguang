import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:flutter_inappwebview/flutter_inappwebview.dart';
// Use the real federated adapter to exercise an absent host method channel.
// ignore: depend_on_referenced_packages
import 'package:flutter_inappwebview_windows/flutter_inappwebview_windows.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:tvbox/core/engine/native_web_sniffer.dart';

class _View implements NativeWebSnifferView {
  void Function(NativeWebSniffEvent)? emit;
  Future<void> Function()? onStart;
  Future<Map<String, String>> Function()? onHeaders;
  Future<void> Function()? onDispose;
  int disposals = 0;
  String? page;
  Map<String, String>? headers;

  @override
  Future<void> start({
    required String pageUrl,
    required Map<String, String> headers,
    required void Function(NativeWebSniffEvent event) onEvent,
  }) async {
    page = pageUrl;
    this.headers = headers;
    emit = onEvent;
    await onStart?.call();
  }

  @override
  Future<Map<String, String>> playbackHeaders(String resourceUrl) async =>
      await onHeaders?.call() ?? const {};

  @override
  Future<void> dispose() async {
    disposals++;
    await onDispose?.call();
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  const page = 'https://player.invalid/watch';
  const media = 'https://cdn.invalid/stream';

  test(
    'response MIME finds extensionless media and merges session headers',
    () async {
      final view = _View()
        ..onHeaders = () async => {
          'User-Agent': 'native-agent',
          'Cookie': 'session=updated; httpOnly=retained',
        };
      final sniffer = NativeWebSniffer(viewFactory: () => view);
      final input = {
        'user-agent': 'input-agent',
        'Cookie': 'session=input',
        'X-Key': 'key',
      };
      final pending = sniffer.sniff(page, input);
      view.emit!(
        const NativeWebSniffEvent(
          media,
          headers: {'Referer': page, 'X-Resource': 'kept'},
        ),
      );
      view.emit!(
        const NativeWebSniffEvent(
          media,
          kind: NativeWebSniffEventKind.response,
          mimeType: 'application/vnd.apple.mpegurl; charset=utf-8',
          statusCode: 200,
        ),
      );
      final hit = await pending;
      expect(hit?.url, media);
      expect(hit?.headers, {
        'User-Agent': 'native-agent',
        'Cookie': 'session=updated; httpOnly=retained',
        'Referer': page,
        'X-Key': 'key',
        'X-Resource': 'kept',
      });
      expect(input['Cookie'], 'session=input');
      expect(view.page, page);
      expect(view.headers, input);
      expect(view.disposals, 1);
      await sniffer.dispose();
      expect(view.disposals, 1);
    },
  );

  test(
    'page itself, redirects, fragments, blob and data are never hits',
    () async {
      final view = _View();
      final sniffer = NativeWebSniffer(viewFactory: () => view);
      final pending = sniffer.sniff(page, const {});
      for (final url in [
        page,
        '$page#fragment',
        'blob:$page/id',
        'data:video/mp4;base64,AA==',
        'javascript:alert(1)',
        'file:///movie.mp4',
      ]) {
        view.emit!(NativeWebSniffEvent(url, kind: NativeWebSniffEventKind.dom));
      }
      view.emit!(
        const NativeWebSniffEvent(
          'https://player.invalid/redirect.mp4',
          kind: NativeWebSniffEventKind.navigation,
        ),
      );
      view.emit!(
        const NativeWebSniffEvent(
          'https://player.invalid/redirect.mp4',
          kind: NativeWebSniffEventKind.response,
          mimeType: 'video/mp4',
          statusCode: 200,
        ),
      );
      view.emit!(
        const NativeWebSniffEvent(
          '/movie.mp4',
          kind: NativeWebSniffEventKind.dom,
        ),
      );
      expect((await pending)?.url, 'https://player.invalid/movie.mp4');
      expect(view.disposals, 1);
    },
  );

  test(
    'requests/resource extensions alone and HTML/errors are not media proof',
    () async {
      final view = _View();
      final sniffer = NativeWebSniffer(viewFactory: () => view);
      final pending = sniffer.sniff(page, const {});
      view.emit!(
        const NativeWebSniffEvent('https://cdn.invalid/only-request.mp4'),
      );
      view.emit!(
        const NativeWebSniffEvent(
          'https://cdn.invalid/login.mp4',
          kind: NativeWebSniffEventKind.resource,
        ),
      );
      view.emit!(
        const NativeWebSniffEvent(
          'https://cdn.invalid/login.mp4',
          kind: NativeWebSniffEventKind.response,
          mimeType: 'text/html',
          statusCode: 200,
        ),
      );
      view.emit!(
        const NativeWebSniffEvent(
          'https://cdn.invalid/broken.mp4',
          kind: NativeWebSniffEventKind.response,
          mimeType: 'video/mp4',
          statusCode: 403,
        ),
      );
      view.emit!(
        const NativeWebSniffEvent(
          'https://cdn.invalid/tls.mp4',
          kind: NativeWebSniffEventKind.error,
        ),
      );
      view.emit!(
        const NativeWebSniffEvent(
          'https://cdn.invalid/tls.mp4',
          kind: NativeWebSniffEventKind.dom,
        ),
      );
      view.emit!(
        const NativeWebSniffEvent(
          media,
          kind: NativeWebSniffEventKind.response,
          mimeType: 'video/mp4',
          statusCode: 206,
        ),
      );
      expect((await pending)?.url, media);
      await sniffer.dispose();
    },
  );

  test(
    'nested page referer is retained rather than media CDN origin',
    () async {
      final view = _View();
      final sniffer = NativeWebSniffer(viewFactory: () => view);
      final pending = sniffer.sniff(page, {'User-Agent': 'fixture'});
      view.emit!(
        const NativeWebSniffEvent(
          '/nested/movie.m3u8',
          kind: NativeWebSniffEventKind.dom,
          pageUrl: 'https://embed.invalid/frame',
        ),
      );
      final hit = await pending;
      expect(hit?.url, 'https://embed.invalid/nested/movie.m3u8');
      expect(hit?.headers['Referer'], 'https://embed.invalid/frame');
      expect(hit?.headers['User-Agent'], 'fixture');
    },
  );

  test('page cookie is not forwarded to an unrelated CDN host', () async {
    final view = _View();
    final sniffer = NativeWebSniffer(viewFactory: () => view);
    final pending = sniffer.sniff(page, {
      'Cookie': 'pageOnly=secret',
      'User-Agent': 'fixture',
    });
    view.emit!(
      const NativeWebSniffEvent(media, kind: NativeWebSniffEventKind.dom),
    );
    final hit = await pending;
    expect(hit?.headers.containsKey('Cookie'), isFalse);
    expect(hit?.headers['User-Agent'], 'fixture');
  });

  test('missing plugin is a null result and releases the owned view', () async {
    final view = _View()
      ..onStart = () async => throw MissingPluginException('fixture');
    final sniffer = NativeWebSniffer(viewFactory: () => view);
    expect(await sniffer.sniff(page, const {}), isNull);
    expect(view.disposals, 1);
    await sniffer.dispose();
  });

  test(
    'Windows host skips native observation unless explicitly enabled',
    () async {
      debugDefaultTargetPlatformOverride = TargetPlatform.windows;
      final sniffer = NativeWebSniffer();
      try {
        expect(sniffer.enabled, isFalse);
        expect(await sniffer.sniff(page, const {}), isNull);
      } finally {
        await sniffer.dispose();
      }
    },
  );

  test('real Windows adapter with missing method channel returns null', () async {
    debugDefaultTargetPlatformOverride = TargetPlatform.windows;
    final previous = InAppWebViewPlatform.instance;
    WindowsInAppWebViewPlatform.registerWith();
    var calls = 0;
    const channel = MethodChannel(
      'com.pichillilorenzo/flutter_headless_inappwebview',
    );
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, (call) async {
          calls++;
          // Returning null from the messenger (not a successful method result) is
          // how a host with no registered native plugin answers the real adapter.
          throw MissingPluginException('No native host installed');
        });
    final sniffer = NativeWebSniffer(enabled: true);
    try {
      expect(await sniffer.sniff(page, const {}), isNull);
      expect(calls, 1);
    } finally {
      await sniffer.dispose();
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(channel, null);
      if (previous != null) InAppWebViewPlatform.instance = previous;
      debugDefaultTargetPlatformOverride = null;
    }
  });

  test('real adapter disposes a view created after cancellation', () async {
    debugDefaultTargetPlatformOverride = TargetPlatform.windows;
    final previous = InAppWebViewPlatform.instance;
    WindowsInAppWebViewPlatform.registerWith();
    const manager = MethodChannel(
      'com.pichillilorenzo/flutter_headless_inappwebview',
    );
    final run = Completer<bool>();
    var id = '';
    var disposed = 0;
    final messenger =
        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
    messenger.setMockMethodCallHandler(manager, (call) async {
      id = (call.arguments as Map)['id'] as String;
      messenger.setMockMethodCallHandler(
        MethodChannel('com.pichillilorenzo/flutter_headless_inappwebview_$id'),
        (call) async {
          if (call.method == 'dispose') disposed++;
          return null;
        },
      );
      return run.future;
    });
    final sniffer = NativeWebSniffer(enabled: true);
    try {
      final pending = sniffer.sniff(page, const {});
      await Future<void>.delayed(Duration.zero);
      expect(id, isNotEmpty);
      await sniffer.cancel();
      expect(await pending, isNull);
      expect(disposed, 0, reason: 'native run has not completed yet');
      run.complete(true);
      await Future<void>.delayed(Duration.zero);
      await Future<void>.delayed(Duration.zero);
      expect(
        disposed,
        1,
        reason: 'late native creation has an explicit finally owner',
      );
    } finally {
      await sniffer.dispose();
      messenger.setMockMethodCallHandler(manager, null);
      if (id.isNotEmpty) {
        messenger.setMockMethodCallHandler(
          MethodChannel(
            'com.pichillilorenzo/flutter_headless_inappwebview_$id',
          ),
          null,
        );
      }
      if (previous != null) InAppWebViewPlatform.instance = previous;
      debugDefaultTargetPlatformOverride = null;
    }
  });

  test(
    'cancel releases every concurrent view and ignores late events',
    () async {
      final views = <_View>[];
      final sniffer = NativeWebSniffer(
        viewFactory: () {
          final view = _View();
          views.add(view);
          return view;
        },
      );
      final first = sniffer.sniff(page, const {});
      final second = sniffer.sniff('$page/2', const {});
      await sniffer.cancel();
      expect(await first, isNull);
      expect(await second, isNull);
      expect(views.map((view) => view.disposals), [1, 1]);
      views.first.emit!(
        const NativeWebSniffEvent(media, kind: NativeWebSniffEventKind.dom),
      );
      final next = sniffer.sniff(page, const {});
      views.last.emit!(
        const NativeWebSniffEvent(media, kind: NativeWebSniffEventKind.dom),
      );
      expect((await next)?.url, media, reason: 'cancel permits subsequent use');
      await sniffer.dispose();
      expect(await sniffer.sniff(page, const {}), isNull);
      expect(views, hasLength(3));
    },
  );

  test(
    'cancel during pending startup returns immediately and owns teardown',
    () async {
      final startup = Completer<void>();
      final view = _View()..onStart = () => startup.future;
      final sniffer = NativeWebSniffer(viewFactory: () => view);
      final pending = sniffer.sniff(page, const {});
      await sniffer.cancel();
      expect(await pending, isNull);
      expect(view.disposals, 1);
      startup.complete();
      await Future<void>.delayed(Duration.zero);
      expect(view.disposals, 1);
      await sniffer.dispose();
    },
  );

  test(
    'one total budget also covers pending startup/header lookup/cleanup',
    () async {
      for (final stage in ['start', 'headers', 'cleanup']) {
        final gate = Completer<void>();
        final view = _View();
        if (stage == 'start') view.onStart = () => gate.future;
        if (stage == 'headers') {
          view.onHeaders = () async {
            await gate.future;
            return {};
          };
        }
        if (stage == 'cleanup') view.onDispose = () => gate.future;
        final sniffer = NativeWebSniffer(
          viewFactory: () => view,
          timeout: const Duration(milliseconds: 20),
        );
        final pending = sniffer.sniff(page, const {});
        if (stage != 'start') {
          view.emit!(
            const NativeWebSniffEvent(media, kind: NativeWebSniffEventKind.dom),
          );
        }
        expect(
          await pending.timeout(const Duration(seconds: 1)),
          isNull,
          reason: stage,
        );
        expect(view.disposals, 1);
        gate.complete();
        await sniffer.dispose();
      }
      expect(
        NativeWebSniffer(timeout: const Duration(minutes: 1)).timeout,
        const Duration(seconds: 25),
      );
    },
  );

  test(
    'factory/dispose exceptions are no-hit and invalid pages create no view',
    () async {
      var created = 0;
      final sniffer = NativeWebSniffer(
        viewFactory: () {
          created++;
          throw StateError('fixture');
        },
      );
      for (final value in [
        '',
        'data:text/html,fixture',
        'blob:$page',
        'file:///fixture',
      ]) {
        expect(await sniffer.sniff(value, const {}), isNull);
      }
      expect(created, 0);
      expect(await sniffer.sniff(page, const {}), isNull);
      expect(created, 1);
      final view = _View()..onDispose = () async => throw StateError('fixture');
      final owned = NativeWebSniffer(viewFactory: () => view);
      final pending = owned.sniff(page, const {});
      await owned.dispose();
      expect(await pending, isNull);
    },
  );
}
