import 'dart:async';
import 'dart:collection';
import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:flutter_inappwebview/flutter_inappwebview.dart';

import 'web_sniffer.dart';

/// Network requests are candidates, not proof that a URL is playable.
enum NativeWebSniffEventKind {
  navigation,
  request,
  resource,
  response,
  dom,
  error,
}

/// Plugin-independent observation; injectable views can be tested without a GPU.
class NativeWebSniffEvent {
  const NativeWebSniffEvent(
    this.url, {
    this.kind = NativeWebSniffEventKind.request,
    this.mimeType,
    this.statusCode,
    this.isMainFrame = false,
    this.headers = const {},
    this.pageUrl,
  });

  final String url;
  final NativeWebSniffEventKind kind;
  final String? mimeType;
  final int? statusCode;
  final bool isMainFrame;
  final Map<String, String> headers;
  final String? pageUrl;
}

/// One owned native view per sniff. A view must release late-created resources
/// when [dispose] races [start], and must not bypass certificate validation.
abstract interface class NativeWebSnifferView {
  Future<void> start({
    required String pageUrl,
    required Map<String, String> headers,
    required void Function(NativeWebSniffEvent event) onEvent,
  });

  Future<Map<String, String>> playbackHeaders(String resourceUrl);
  Future<void> dispose();
}

typedef NativeWebSnifferViewFactory = NativeWebSnifferView Function();

/// Optional view capability: surfacing a non-fatal platform limitation (for
/// example an unavailable DevTools connection) without failing the sniff.
abstract interface class NativeWebSnifferDiagnostics {
  String? get diagnostic;
}

/// Executes player JavaScript in a headless WKWebView / WebView2.
///
/// Each invocation has one wall-clock budget, including startup, cookies and
/// cleanup. Missing native channels/runtime produce null, allowing the caller to
/// use its static fallback. [cancel] cancels all active invocations but permits
/// reuse; [dispose] permanently closes this instance. No extra HTTP probes or
/// external fixture hosts are used.
class NativeWebSniffer {
  NativeWebSniffer({
    NativeWebSnifferViewFactory? viewFactory,
    Duration timeout = const Duration(seconds: 25),
  }) : _viewFactory = viewFactory ?? _InAppWebSnifferView.new,
       timeout = timeout > const Duration(seconds: 25)
           ? const Duration(seconds: 25)
           : timeout;

  final NativeWebSnifferViewFactory _viewFactory;
  final Duration timeout;
  final Set<_SniffOperation> _operations = {};
  bool _disposed = false;

  /// Last native startup/lifecycle failure. A no-hit result is normal, but this
  /// keeps a missing WebView2 Runtime or a plugin error explainable in logs.
  String? lastError;

  Future<WebSniffHit?> sniff(String pageUrl, Map<String, String> headers) {
    final uri = Uri.tryParse(pageUrl);
    if (_disposed ||
        timeout <= Duration.zero ||
        uri == null ||
        !{'http', 'https'}.contains(uri.scheme) ||
        uri.host.isEmpty) {
      return Future.value();
    }
    final operation = _SniffOperation(pageUrl, Map.of(headers));
    _operations.add(operation);
    // The timer begins before factory creation, cookie setup or native startup.
    operation.timer = Timer(
      timeout,
      () => operation.finish(null, immediate: true),
    );
    unawaited(_start(operation));
    return operation.result.future.whenComplete(() {
      _operations.remove(operation);
    });
  }

  Future<void> _start(_SniffOperation operation) async {
    try {
      operation.view = _viewFactory();
      if (operation.closed) {
        await operation.release();
        return;
      }
      await operation.view!.start(
        pageUrl: operation.pageUrl,
        headers: operation.headers,
        onEvent: (event) => _observe(operation, event),
      );
      if (operation.view case final NativeWebSnifferDiagnostics view) {
        lastError = view.diagnostic ?? lastError;
      }
    } catch (error) {
      // MissingPluginException, absent WebView2 and unsupported host platforms
      // are ordinary no-hit results. Never return the navigation URL instead.
      lastError = error.toString();
      await operation.finish(null);
    }
  }

  void _observe(_SniffOperation operation, NativeWebSniffEvent event) {
    if (operation.closed) return;
    final url = _httpUrl(event.url, event.pageUrl ?? operation.pageUrl);
    if (url == null) return;
    if (event.kind == NativeWebSniffEventKind.navigation || event.isMainFrame) {
      operation.pages.add(_withoutFragment(url));
      return;
    }
    if (operation.pages.contains(_withoutFragment(url))) return;
    if (event.kind == NativeWebSniffEventKind.error) {
      operation.failed.add(url);
      return;
    }
    if (event.headers.isNotEmpty) {
      operation.requestHeaders[url] = event.headers;
    }
    if (operation.failed.contains(url)) return;
    final type = (event.mimeType ?? '').split(';').first.trim().toLowerCase();
    if ((event.statusCode != null &&
            (event.statusCode! < 200 || event.statusCode! >= 300)) ||
        type.contains('html') ||
        type == 'application/json') {
      operation.failed.add(url);
      return;
    }
    final confirmed = switch (event.kind) {
      NativeWebSniffEventKind.response =>
        _mediaMime(type) || (_mediaUrl.hasMatch(url) && type.isNotEmpty),
      NativeWebSniffEventKind.dom => true,
      // ResourceTiming carries neither status nor MIME on these plugin versions.
      // A completed .mp4 may still be a login page; keep it as a candidate.
      NativeWebSniffEventKind.resource => false,
      _ => false,
    };
    if (!confirmed || operation.resolving) return;
    operation.resolving = true;
    unawaited(_accept(operation, event, url));
  }

  Future<void> _accept(
    _SniffOperation operation,
    NativeWebSniffEvent event,
    String url,
  ) async {
    final resultHeaders = Map<String, String>.of(operation.headers);
    if (Uri.parse(url).host != Uri.parse(operation.pageUrl).host) {
      // Caller cookies belong to the page; only the native URL-scoped jar may
      // supply cookies for a different CDN host.
      resultHeaders.removeWhere((key, _) => key.toLowerCase() == 'cookie');
    }
    _mergeHeaders(resultHeaders, {
      'Referer': event.pageUrl ?? operation.pageUrl,
    });
    _mergeHeaders(resultHeaders, operation.requestHeaders[url] ?? const {});
    try {
      _mergeHeaders(resultHeaders, await operation.view!.playbackHeaders(url));
    } catch (_) {
      // Supplied cookies/UA remain available if the native cookie API is absent.
    }
    if (operation.closed) return;
    if (operation.failed.contains(url)) {
      operation.resolving = false;
      return;
    }
    await operation.finish(WebSniffHit(url, Map.unmodifiable(resultHeaders)));
  }

  Future<void> cancel() async {
    await Future.wait([
      for (final operation in _operations.toList())
        operation.finish(null, immediate: true),
    ]);
  }

  Future<void> dispose() async {
    _disposed = true;
    await cancel();
  }

  static final _mediaUrl = RegExp(
    r'\.(?:m3u8|mp4|m4v|mpd|flv|mkv|webm|m4a|mp3|aac|ogg|ogv)(?:$|[?#])',
    caseSensitive: false,
  );

  static bool _mediaMime(String type) =>
      type.startsWith('video/') ||
      type.startsWith('audio/') ||
      type.contains('mpegurl') ||
      type == 'application/dash+xml' ||
      type == 'application/mp4';
}

class _SniffOperation {
  _SniffOperation(this.pageUrl, this.headers)
    : pages = {_withoutFragment(pageUrl)};

  final String pageUrl;
  final Map<String, String> headers;
  final Set<String> pages;
  final failed = <String>{};
  final requestHeaders = <String, Map<String, String>>{};
  final result = Completer<WebSniffHit?>();
  NativeWebSnifferView? view;
  Timer? timer;
  bool closed = false;
  bool resolving = false;
  Future<void>? _release;

  Future<void> release() => _release ??= () async {
    try {
      await view?.dispose();
    } catch (_) {
      // Teardown must not replace the sniff result with a platform exception.
    }
  }();

  Future<void> finish(WebSniffHit? hit, {bool immediate = false}) async {
    closed = true;
    if (immediate && !result.isCompleted) result.complete(null);
    await release();
    if (!result.isCompleted) result.complete(hit);
    timer?.cancel();
  }
}

/// Adapter verified against flutter_inappwebview 6.1.5, Windows 0.6.0 and iOS
/// 1.1.2 implementations. Windows exposes CDP response events, not a generic
/// native onLoadResource MIME callback; WKWebView exposes navigation responses.
class _InAppWebSnifferView
    implements NativeWebSnifferView, NativeWebSnifferDiagnostics {
  HeadlessInAppWebView? _view;
  InAppWebViewController? _controller;
  bool _runPending = false;
  Future<void>? _releasing;
  bool _closed = false;
  void Function(NativeWebSniffEvent)? _onEvent;
  final _requests = <String, Map<String, String>>{};
  final _cdpListeners = <String>[];
  String _pageUrl = '';
  String? _diagnostic;

  @override
  String? get diagnostic => _diagnostic;
  String? _userAgent;
  final String _cookieScope = 'liuguang-native-sniff-${_nextCookieScope++}';
  static int _nextCookieScope = 0;
  static const _cookieChannel = MethodChannel(
    'liuguang/native_web_sniffer_cookies',
  );

  @override
  Future<void> start({
    required String pageUrl,
    required Map<String, String> headers,
    required void Function(NativeWebSniffEvent event) onEvent,
  }) async {
    _pageUrl = pageUrl;
    _onEvent = onEvent;
    _userAgent = _header(headers, 'User-Agent');
    final windows = defaultTargetPlatform == TargetPlatform.windows && !kIsWeb;
    if (!windows && defaultTargetPlatform != TargetPlatform.iOS) return;
    // Seed only this private view's cookie store, never WK's global default.
    final cookie = _header(headers, 'Cookie');
    if (_closed) return;
    final ready = Completer<InAppWebViewController>();
    _view = HeadlessInAppWebView(
      // Do not navigate until handlers/CDP subscriptions have been installed.
      initialSettings: InAppWebViewSettings(
        javaScriptEnabled: true,
        incognito: true,
        userAgent: _userAgent ?? '',
        mediaPlaybackRequiresUserGesture: false,
        allowsInlineMediaPlayback: true,
        useOnLoadResource: true,
        useShouldInterceptRequest: true,
        useOnNavigationResponse: true,
        disableContextMenu: true,
        javaScriptCanOpenWindowsAutomatically: false,
      ),
      initialUserScripts: UnmodifiableListView([
        UserScript(
          source: '/*$_cookieScope*/\n$_observerScript',
          injectionTime: UserScriptInjectionTime.AT_DOCUMENT_START,
          forMainFrameOnly: false,
        ),
      ]),
      onWebViewCreated: (controller) {
        _controller = controller;
        controller.addJavaScriptHandler(
          handlerName: _handlerName,
          callback: (arguments) {
            if (!_closed && arguments.isNotEmpty) _jsEvent(arguments.first);
            return null;
          },
        );
        if (!ready.isCompleted) ready.complete(controller);
      },
      onLoadStart: (_, url) {
        if (url == null || url.toString() == 'about:blank') return;
        _pageUrl = url.toString();
        _emit(
          NativeWebSniffEvent(
            url.toString(),
            kind: NativeWebSniffEventKind.navigation,
          ),
        );
      },
      onLoadStop: (controller, _) {
        if (!_closed) unawaited(_scan(controller));
      },
      onLoadResource: (_, resource) {
        _emit(
          NativeWebSniffEvent(
            resource.url?.toString() ?? '',
            kind: NativeWebSniffEventKind.resource,
            pageUrl: _pageUrl,
          ),
        );
      },
      shouldInterceptRequest: (_, request) async {
        _emit(
          NativeWebSniffEvent(
            request.url.toString(),
            headers: request.headers ?? const {},
            isMainFrame: request.isForMainFrame == true,
            pageUrl: _pageUrl,
          ),
        );
        return null; // Observe only: let WebView perform its normal request.
      },
      onNavigationResponse: (_, navigation) async {
        final response = navigation.response;
        _emit(
          NativeWebSniffEvent(
            response?.url?.toString() ?? '',
            kind: NativeWebSniffEventKind.response,
            mimeType: response?.mimeType,
            statusCode: response?.statusCode,
            isMainFrame: navigation.isForMainFrame,
            pageUrl: _pageUrl,
          ),
        );
        return NavigationResponseAction.ALLOW;
      },
      onReceivedError: (_, request, error) {
        _emit(
          NativeWebSniffEvent(
            request.url.toString(),
            kind: NativeWebSniffEventKind.error,
            isMainFrame: request.isForMainFrame == true,
          ),
        );
      },
      onReceivedHttpError: (_, request, response) {
        _emit(
          NativeWebSniffEvent(
            request.url.toString(),
            kind: NativeWebSniffEventKind.error,
            statusCode: response.statusCode,
            isMainFrame: request.isForMainFrame == true,
          ),
        );
      },
      // null maps to .performDefaultHandling in iOS. PROCEED would create a
      // trust exception. Windows keeps the WebView2 default TLS validation.
      onReceivedServerTrustAuthRequest: (_, challenge) async {
        // Keep OS trust evaluation, but record an exposed certificate failure.
        if (challenge.protectionSpace.sslError != null) {
          _emit(
            NativeWebSniffEvent(
              _pageUrl,
              kind: NativeWebSniffEventKind.error,
              isMainFrame: true,
            ),
          );
        }
        return null;
      },
      onCreateWindow: (_, _) async => false,
      onPermissionRequest: (_, request) async => PermissionResponse(
        resources: request.resources,
        action: PermissionResponseAction.DENY,
      ),
    );
    _runPending = true;
    try {
      await _view!.run();
      _runPending = false;
      if (_closed) return;
      // A missing WebView2 Runtime, or a host that cannot create the view,
      // never completes onWebViewCreated. Bound it so the caller falls back to
      // static extraction quickly instead of burning the whole budget.
      final InAppWebViewController controller;
      try {
        controller = await ready.future.timeout(const Duration(seconds: 10));
      } on TimeoutException {
        _diagnostic = windows
            ? 'native view not created: Microsoft Edge WebView2 Runtime missing?'
            : 'native view not created';
        return;
      }
      if (_closed) return;
      if (windows) {
        // CDP is the preferred MIME source on WebView2, but it is an optional
        // accelerator: a host that does not route DevTools commands must still
        // observe the page, so its failure never aborts the navigation.
        try {
          await _enableWindowsNetwork(controller);
        } catch (error) {
          _diagnostic = 'cdp: $error';
        }
        if (cookie != null) {
          for (final part in cookie.split(';')) {
            if (_closed) return;
            final split = part.indexOf('=');
            if (split <= 0) continue;
            try {
              await controller.callDevToolsProtocolMethod(
                methodName: 'Network.setCookie',
                parameters: {
                  'url': pageUrl,
                  'name': part.substring(0, split).trim(),
                  'value': part.substring(split + 1).trim(),
                  'path': '/',
                  'secure': Uri.parse(pageUrl).scheme == 'https',
                },
              );
            } catch (error) {
              _diagnostic = 'cdn-cookie: $error';
              break;
            }
          }
        }
      } else if (cookie != null && cookie.isNotEmpty) {
        await _cookieChannel.invokeMethod<void>('setCookies', {
          'scope': _cookieScope,
          'url': pageUrl,
          'cookie': cookie,
        });
      }
      if (_closed) return;
      await controller.loadUrl(
        urlRequest: URLRequest(url: WebUri(pageUrl), headers: headers),
      );
    } finally {
      _runPending = false;
      // Plugin dispose() is a no-op while run() is pending. Explicitly retry
      // after run settles so a cancel during native creation never leaks a view.
      if (_closed) await _releaseNative();
    }
  }

  Future<void> _enableWindowsNetwork(InAppWebViewController controller) async {
    for (final name in [
      'Network.requestWillBeSent',
      'Network.responseReceived',
      'Network.loadingFailed',
    ]) {
      if (_closed) return;
      await controller.addDevToolsProtocolEventListener(
        eventName: name,
        callback: (raw) {
          if (_closed) return;
          final data = _stringMap(raw);
          final requestId = data['requestId']?.toString() ?? '';
          if (name == 'Network.loadingFailed') {
            final request = _requests[requestId];
            _emit(
              NativeWebSniffEvent(
                request?[':url'] ?? '',
                kind: NativeWebSniffEventKind.error,
              ),
            );
            return;
          }
          final item = _stringMap(
            data[name == 'Network.requestWillBeSent' ? 'request' : 'response'],
          );
          final url = item['url']?.toString() ?? '';
          final document = data['type'] == 'Document';
          if (name == 'Network.requestWillBeSent') {
            final requestHeaders = _headers(item['headers']);
            _requests[requestId] = {...requestHeaders, ':url': url};
            _emit(
              NativeWebSniffEvent(
                url,
                headers: requestHeaders,
                isMainFrame: document,
                pageUrl: _pageUrl,
              ),
            );
          } else {
            final requestHeaders = Map<String, String>.of(
              _requests[requestId] ?? {},
            )..remove(':url');
            _emit(
              NativeWebSniffEvent(
                url,
                kind: NativeWebSniffEventKind.response,
                mimeType: item['mimeType']?.toString(),
                statusCode: (item['status'] as num?)?.toInt(),
                headers: requestHeaders,
                isMainFrame: document,
                pageUrl: _pageUrl,
              ),
            );
            _requests.remove(requestId);
          }
        },
      );
      _cdpListeners.add(name);
    }
    if (!_closed) {
      await controller.callDevToolsProtocolMethod(methodName: 'Network.enable');
    }
  }

  void _emit(NativeWebSniffEvent event) {
    if (!_closed) _onEvent?.call(event);
  }

  void _jsEvent(dynamic raw) {
    final data = _stringMap(raw);
    final kind = switch (data['kind']) {
      'response' => NativeWebSniffEventKind.response,
      'dom' => NativeWebSniffEventKind.dom,
      'resource' => NativeWebSniffEventKind.resource,
      _ => NativeWebSniffEventKind.request,
    };
    final url = data['url'];
    if (url is! String) return;
    _emit(
      NativeWebSniffEvent(
        url,
        kind: kind,
        mimeType: data['mime'] as String?,
        statusCode: (data['status'] as num?)?.toInt(),
        headers: _headers(data['headers']),
        pageUrl: data['page'] as String? ?? _pageUrl,
      ),
    );
  }

  Future<void> _scan(InAppWebViewController controller) async {
    try {
      await controller.evaluateJavascript(
        source: 'window.__liuguangSniffScan && window.__liuguangSniffScan();',
      );
    } catch (_) {
      // Navigation/disposal can invalidate the previous JavaScript context.
    }
  }

  @override
  Future<Map<String, String>> playbackHeaders(String resourceUrl) async {
    final result = <String, String>{};
    final controller = _controller;
    if (_closed || controller == null) return result;
    _userAgent ??= (await controller.evaluateJavascript(
      source: 'navigator.userAgent',
    ))?.toString();
    if (_userAgent?.isNotEmpty == true) result['User-Agent'] = _userAgent!;
    if (defaultTargetPlatform == TargetPlatform.windows && !kIsWeb) {
      final data = _stringMap(
        await controller.callDevToolsProtocolMethod(
          methodName: 'Network.getCookies',
          parameters: {
            'urls': [resourceUrl],
          },
        ),
      );
      final cookies = data['cookies'];
      if (cookies is List && cookies.isNotEmpty) {
        result['Cookie'] = cookies
            .map((raw) {
              final cookie = _stringMap(raw);
              return '${cookie['name']}=${cookie['value']}';
            })
            .join('; ');
      }
    } else {
      final cookie = await _cookieChannel.invokeMethod<String>('getCookies', {
        'scope': _cookieScope,
        'url': resourceUrl,
      });
      if (cookie?.isNotEmpty == true) result['Cookie'] = cookie!;
    }
    return result;
  }

  @override
  Future<void> dispose() async {
    _closed = true;
    _onEvent = null;
    // Do not await a pending run(): its finally block owns late cleanup. This
    // also keeps cancellation and the operation's total timeout bounded.
    if (!_runPending) await _releaseNative();
  }

  Future<void> _releaseNative() => _releasing ??= () async {
    final controller = _controller;
    if (controller != null) {
      for (final event in _cdpListeners) {
        try {
          await controller
              .removeDevToolsProtocolEventListener(eventName: event)
              .timeout(const Duration(seconds: 1));
        } catch (_) {
          // A lost platform channel must not prevent native dispose below.
        }
      }
      try {
        await controller.stopLoading().timeout(const Duration(seconds: 1));
      } catch (_) {
        // The native view may already have been torn down.
      }
    }
    try {
      await _view?.dispose().timeout(const Duration(seconds: 1));
    } finally {
      _controller?.dispose();
      _view = null;
      _controller = null;
      _requests.clear();
    }
  }();
}

String? _header(Map<String, String> headers, String name) {
  for (final entry in headers.entries) {
    if (entry.key.toLowerCase() == name.toLowerCase()) return entry.value;
  }
  return null;
}

void _mergeHeaders(Map<String, String> target, Map<String, String> source) {
  for (final entry in source.entries) {
    if (entry.key.startsWith(':')) continue;
    target.removeWhere(
      (key, _) => key.toLowerCase() == entry.key.toLowerCase(),
    );
    target[entry.key] = entry.value;
  }
}

String? _httpUrl(String raw, String base) {
  if (raw.trim().isEmpty || raw.startsWith('#')) return null;
  try {
    final uri = Uri.parse(base).resolve(raw.trim());
    if (!{'http', 'https'}.contains(uri.scheme) || uri.host.isEmpty) {
      return null;
    }
    return uri.toString();
  } on FormatException {
    return null;
  }
}

String _withoutFragment(String url) =>
    Uri.parse(url).replace(fragment: '').toString();

Map<String, dynamic> _stringMap(dynamic value) {
  if (value is String) {
    try {
      value = jsonDecode(value);
    } on FormatException {
      return {};
    }
  }
  return value is Map
      ? value.map((key, value) => MapEntry(key.toString(), value))
      : {};
}

Map<String, String> _headers(dynamic value) =>
    _stringMap(value).map((key, value) => MapEntry(key, value.toString()));

const _handlerName = 'liuguangNativeSniff';

// Runs at document start in every frame, including dynamic players. Queues
// observations until the plugin bridge is ready; no requests are created here.
const _observerScript = r'''
(function () {
  if (window.__liuguangSniffScan) return;
  var queue = [], seen = Object.create(null);
  function flush() {
    var bridge = window.flutter_inappwebview;
    if (!bridge || typeof bridge.callHandler !== 'function') return;
    var pending = queue.splice(0);
    pending.forEach(function (event) {
      try { var p = bridge.callHandler('liuguangNativeSniff', event); if (p && p.catch) p.catch(function () {}); } catch (_) {}
    });
  }
  function emit(kind, value, mime, status, headers) {
    try {
      var url = new URL(String(value || ''), document.baseURI).href;
      if (!/^https?:/i.test(url) || url.split('#')[0] === location.href.split('#')[0]) return;
      var key = kind + '\n' + url + '\n' + (mime || '');
      if (seen[key]) return;
      seen[key] = true;
      queue.push({kind:kind,url:url,mime:mime || '',status:status,page:location.href,headers:headers || {}});
      if (queue.length > 256) queue.shift();
      flush();
    } catch (_) {}
  }
  function headerObject(input) {
    var out = {};
    try { new Headers(input || {}).forEach(function(v,k) { out[k] = v; }); } catch (_) {}
    return out;
  }
  if (window.fetch) {
    var originalFetch = window.fetch;
    window.fetch = function (input, init) {
      var url = typeof input === 'string' ? input : input && input.url;
      var headers = headerObject((init && init.headers) || (input && input.headers));
      emit('request', url, '', null, headers);
      return originalFetch.apply(this, arguments).then(function (response) {
        emit('response', response.url || url, response.headers.get('content-type'), response.status, headers);
        return response;
      });
    };
  }
  if (window.XMLHttpRequest) {
    var originalOpen = XMLHttpRequest.prototype.open;
    var originalSend = XMLHttpRequest.prototype.send;
    var originalHeader = XMLHttpRequest.prototype.setRequestHeader;
    XMLHttpRequest.prototype.open = function (method, url) {
      this.__lgUrl = url; this.__lgHeaders = {};
      return originalOpen.apply(this, arguments);
    };
    XMLHttpRequest.prototype.setRequestHeader = function (name, value) {
      (this.__lgHeaders || (this.__lgHeaders = {}))[name] = value;
      return originalHeader.apply(this, arguments);
    };
    XMLHttpRequest.prototype.send = function () {
      var xhr = this;
      emit('request', xhr.__lgUrl, '', null, xhr.__lgHeaders);
      xhr.addEventListener('load', function () {
        emit('response', xhr.responseURL || xhr.__lgUrl, xhr.getResponseHeader('content-type'), xhr.status, xhr.__lgHeaders);
      });
      return originalSend.apply(this, arguments);
    };
  }
  function scan() {
    document.querySelectorAll('video,audio').forEach(function (node) {
      var src = node.currentSrc || node.src || node.getAttribute('src');
      // An untested src can point at an HTML login/error page. Only the native
      // decoder's loaded metadata confirms a DOM-only candidate as media.
      if (src) emit(node.readyState >= 1 && !node.error ? 'dom' : 'request', src, '');
      node.querySelectorAll('source[src]').forEach(function (source) {
        emit('request', source.src, source.type || '');
      });
    });
    flush();
  }
  window.__liuguangSniffScan = scan;
  document.addEventListener('DOMContentLoaded', scan);
  document.addEventListener('loadedmetadata', scan, true);
  document.addEventListener('loadeddata', scan, true);
  document.addEventListener('error', scan, true);
  document.addEventListener('loadstart', scan, true);
  window.addEventListener('flutterInAppWebViewPlatformReady', flush);
  new MutationObserver(scan).observe(document, {subtree:true,childList:true,attributes:true,attributeFilter:['src']});
  try {
    new PerformanceObserver(function (list) {
      list.getEntries().forEach(function (entry) { emit('resource', entry.name); });
    }).observe({entryTypes:['resource']});
  } catch (_) {}
  scan();
})();
''';
