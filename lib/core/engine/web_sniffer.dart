import 'dart:convert';
import 'dart:typed_data';

import 'package:html/parser.dart' as html_parser;

import '../network/app_http_client.dart';

/// A playable resource discovered on a player page.
class WebSniffHit {
  const WebSniffHit(this.url, this.headers);
  final String url;
  final Map<String, String> headers;
}

/// Portable, dependency-free page sniffer used where no native WebView exists.
///
/// It mirrors the Android WebView contract closely enough for static players:
/// the page URL itself is never returned, only a distinct resource that is
/// either declared by the document or by an embedded player script, and every
/// candidate is verified by a ranged request before it is accepted.
class WebSniffer {
  WebSniffer(this.http, {this.maxCandidates = 24, this.maxPages = 2});
  final AppHttpClient http;
  final int maxCandidates;
  final int maxPages;

  static final _media = RegExp(
    r'\.(?:m3u8|mp4|m4v|mpd|flv|mkv|webm|ts|m4a|mp3|aac)(?:$|[?#])',
    caseSensitive: false,
  );

  Future<WebSniffHit?> sniff(
    String pageUrl,
    Map<String, String> headers,
  ) async {
    final visited = <String>{};
    var current = pageUrl;
    for (var depth = 0; depth < maxPages; depth++) {
      if (!visited.add(current)) break;
      final String body;
      try {
        final response = await http.fetch(current, headers: headers);
        current = response.finalUrl;
        body = utf8.decode(response.bytes, allowMalformed: true);
      } on AppHttpException {
        return null;
      }
      final candidates = extract(body, current).take(maxCandidates).toList();
      for (final candidate in candidates) {
        final verified = await _verify(candidate, current, headers);
        if (verified != null) return verified;
      }
      final nested = _iframe(body, current, visited);
      if (nested == null) return null;
      current = nested;
    }
    return null;
  }

  /// Ordered candidates: document declarations first, then player script data.
  List<String> extract(String body, String pageUrl) {
    final declared = <String>[];
    final scripted = <String>[];
    void add(List<String> target, String? raw) {
      final value = _absolute(raw, pageUrl);
      if (value == null || value == pageUrl) return;
      if (!target.contains(value)) target.add(value);
    }

    try {
      final document = html_parser.parse(body);
      for (final element in document.querySelectorAll('video,audio,source')) {
        for (final attribute in const [
          'src',
          'data-src',
          'data-url',
          'data-video',
          'data-playurl',
        ]) {
          add(declared, element.attributes[attribute]);
        }
        for (final child in element.querySelectorAll('source')) {
          add(declared, child.attributes['src']);
        }
      }
      for (final meta in document.querySelectorAll('meta')) {
        final key = (meta.attributes['property'] ?? '').toLowerCase();
        if (key.contains('video') || key.contains('player')) {
          add(declared, meta.attributes['content']);
        }
      }
      for (final element in document.querySelectorAll(
        '[data-src],[data-url]',
      )) {
        add(declared, element.attributes['data-src']);
        add(declared, element.attributes['data-url']);
      }
    } catch (_) {
      // A malformed document still yields useful script matches below.
    }

    final unescaped = body.replaceAll(r'\/', '/').replaceAll(r'\u002F', '/');
    for (final match in RegExp(
      r'''https?://[^\s"'<>()\\]+''',
    ).allMatches(unescaped)) {
      final raw = match.group(0)!;
      if (_media.hasMatch(raw)) add(scripted, raw);
    }
    for (final match in RegExp(
      r'''(?:"|'|\\")((?:https?:)?//[^\s"'<>\\]+\.(?:m3u8|mp4|m4v|mpd|flv|mkv|webm)[^\s"'<>\\]*)''',
      caseSensitive: false,
    ).allMatches(unescaped)) {
      add(scripted, match.group(1));
    }
    for (final match in RegExp(
      r'''(?:"|')(/(?!/)[^\s"'<>\\]+\.(?:m3u8|mp4|m4v|mpd|flv|mkv|webm)[^\s"'<>\\]*)''',
      caseSensitive: false,
    ).allMatches(unescaped)) {
      add(scripted, match.group(1));
    }
    // HLS playlists are the most common parse=1 target and cheapest to verify.
    scripted.sort((a, b) => _rank(a).compareTo(_rank(b)));
    declared.sort((a, b) => _rank(a).compareTo(_rank(b)));
    return [...declared, ...scripted];
  }

  static int _rank(String url) {
    final lower = url.toLowerCase();
    if (lower.contains('.m3u8')) return 0;
    if (lower.contains('.mpd')) return 1;
    return 2;
  }

  String? _iframe(String body, String pageUrl, Set<String> visited) {
    try {
      final document = html_parser.parse(body);
      for (final frame in document.querySelectorAll('iframe[src]')) {
        final value = _absolute(frame.attributes['src'], pageUrl);
        if (value != null && !visited.contains(value)) return value;
      }
    } catch (_) {
      // No usable nested document.
    }
    return null;
  }

  static String? _absolute(String? raw, String pageUrl) {
    final value = raw?.trim();
    if (value == null ||
        value.isEmpty ||
        value.startsWith('javascript:') ||
        value.startsWith('data:') ||
        value.startsWith('blob:') ||
        value.startsWith('#')) {
      return null;
    }
    final resolved = Uri.tryParse(pageUrl)?.resolve(value);
    if (resolved == null || !{'http', 'https'}.contains(resolved.scheme)) {
      return null;
    }
    return resolved.toString();
  }

  Future<WebSniffHit?> _verify(
    String url,
    String pageUrl,
    Map<String, String> headers,
  ) async {
    final requestHeaders = Map<String, String>.of(headers);
    requestHeaders.removeWhere(
      (key, _) => {'referer', 'range'}.contains(key.toLowerCase()),
    );
    requestHeaders['Referer'] = pageUrl;
    try {
      final probe = await http.fetchPrefix(
        url,
        headers: {...requestHeaders, 'Range': 'bytes=0-1023'},
        maxBytes: 1024,
      );
      final types = probe.headers['content-type'] ?? const <String>[];
      final type = (types.isEmpty ? '' : types.first)
          .split(';')
          .first
          .trim()
          .toLowerCase();
      final sniffed = _isMediaBytes(probe.bytes, type);
      if (!sniffed) return null;
      return WebSniffHit(
        probe.finalUrl.isEmpty ? url : probe.finalUrl,
        requestHeaders,
      );
    } on AppHttpException {
      return null;
    }
  }

  static bool _isMediaBytes(Uint8List bytes, String contentType) {
    if (contentType.startsWith('video/') ||
        contentType.startsWith('audio/') ||
        contentType.contains('mpegurl') ||
        contentType.contains('dash+xml') ||
        contentType == 'application/mp4') {
      return true;
    }
    if (bytes.isEmpty) return false;
    final head = String.fromCharCodes(
      bytes.take(512).where((b) => b < 128),
    ).trimLeft();
    if (head.startsWith('#EXTM3U')) return true;
    if (head.startsWith('<MPD') || head.contains('<MPD ')) return true;
    if (bytes.length >= 12 &&
        String.fromCharCodes(bytes.sublist(4, 8)) == 'ftyp') {
      return true;
    }
    return bytes.length >= 188 && bytes[0] == 0x47;
  }
}
