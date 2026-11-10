import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:xml/xml.dart';

import '../config/config_decoder.dart';
import '../models/models.dart';
import '../network/app_http_client.dart';

class LiveException implements Exception {
  const LiveException(this.message);
  final String message;
  @override
  String toString() => 'LiveException: $message';
}

class LiveRepository {
  LiveRepository(this.client, {this.maxDepth = 6});
  final AppHttpClient client;
  final int maxDepth;

  Future<List<LiveChannel>> load(
    List<dynamic> lives, {
    String? baseUrl,
    Future<String> Function(String url)? localFetcher,
    void Function(String message)? onError,
  }) async {
    final output = <LiveChannel>[];
    await _entries(
      lives,
      output,
      baseUrl,
      '默认分组',
      const {},
      '',
      localFetcher,
      {},
      0,
      onError: onError,
    );
    return _merge(output);
  }

  Future<List<LiveChannel>> loadUrl(String url) => load([
    {'url': url},
  ]);

  Future<void> _entries(
    List<dynamic> entries,
    List<LiveChannel> out,
    String? base,
    String group,
    Map<String, String> headers,
    String epg,
    Future<String> Function(String)? localFetcher,
    Set<String> visited,
    int depth, {
    bool channelEntries = false,
    void Function(String message)? onError,
  }) async {
    if (depth > maxDepth) {
      throw LiveException('Playlist depth limit ($maxDepth) exceeded');
    }
    for (final value in entries) {
      try {
        if (value is String) {
          if (value.contains('\n') || value.startsWith('#EXTM3U')) {
            out.addAll(
              parse(
                value,
                baseUrl: base,
                group: group,
                headers: headers,
                epg: epg,
              ),
            );
          } else {
            await _playlist(
              value,
              out,
              base,
              group,
              headers,
              epg,
              localFetcher,
              visited,
              depth,
              onError: onError,
            );
          }
          continue;
        }
        if (value is! Map) {
          throw const LiveException(
            'Live entry must be an object or playlist URL',
          );
        }
        final raw = jsonMap(value);
        final name = str(raw['name']);
        final nextHeaders = {
          ...headers,
          ..._headers(raw['header'] ?? raw['headers']),
        };
        if (str(raw['ua']).isNotEmpty) {
          nextHeaders['User-Agent'] = str(raw['ua']);
        }
        final nextEpg = str(raw['epg']).isEmpty
            ? epg
            : _resolve(str(raw['epg']), base);
        final channels = raw['channels'] ?? raw['groups'] ?? raw['lives'];
        if (channels is List) {
          await _entries(
            channels,
            out,
            base,
            name.isEmpty ? group : name,
            nextHeaders,
            nextEpg,
            localFetcher,
            visited,
            depth + 1,
            channelEntries: raw['channels'] is List,
            onError: onError,
          );
        } else if (channelEntries && str(raw['url']).isNotEmpty) {
          final source = _source(str(raw['url']), base);
          out.add(
            LiveChannel(
              name: name.isEmpty ? '未命名频道' : name,
              urls: [source.$1],
              group: str(raw['group']).isEmpty ? group : str(raw['group']),
              logo: _resolve(str(raw['logo'] ?? raw['tvg-logo']), base),
              tvgId: str(raw['tvgId'] ?? raw['tvg-id']),
              epg: nextEpg,
              headers: {...nextHeaders, ...source.$2},
            ),
          );
        } else if (raw['urls'] is List) {
          final urls = <String>[];
          final channelHeaders = Map.of(nextHeaders);
          for (final item in raw['urls'] as List) {
            final source = _source(str(item), base);
            urls.add(source.$1);
            channelHeaders.addAll(source.$2);
          }
          if (urls.isNotEmpty) {
            out.add(
              LiveChannel(
                name: name.isEmpty ? '未命名频道' : name,
                urls: urls,
                group: str(raw['group']).isEmpty ? group : str(raw['group']),
                logo: _resolve(str(raw['logo'] ?? raw['tvg-logo']), base),
                tvgId: str(raw['tvgId'] ?? raw['tvg-id']),
                epg: nextEpg,
                headers: channelHeaders,
              ),
            );
          }
        } else if (str(raw['url']).isNotEmpty) {
          await _playlist(
            str(raw['url']),
            out,
            base,
            name.isEmpty ? group : name,
            nextHeaders,
            nextEpg,
            localFetcher,
            visited,
            depth + 1,
            onError: onError,
          );
        } else {
          throw LiveException('Live entry "$name" has no channels or URL');
        }
      } catch (failure) {
        if (onError == null) rethrow;
        final name = value is Map
            ? str(value['name'] ?? value['url'])
            : str(value);
        onError('$name: $failure');
      }
    }
  }

  Future<void> _playlist(
    String reference,
    List<LiveChannel> out,
    String? base,
    String group,
    Map<String, String> headers,
    String epg,
    Future<String> Function(String)? localFetcher,
    Set<String> visited,
    int depth, {
    void Function(String message)? onError,
  }) async {
    if (depth > maxDepth) {
      throw LiveException('Playlist depth limit ($maxDepth) exceeded');
    }
    var url = _resolve(reference, base);
    if (url.startsWith('proxy://')) {
      final arguments = url.substring('proxy://'.length).replaceFirst('?', '&');
      var ext = Uri.splitQueryString(arguments)['ext'];
      if (ext == null) throw const LiveException('Proxy playlist has no ext');
      try {
        ext = utf8.decode(base64.decode(base64.normalize(ext)));
      } catch (_) {
        /* plain ext URL */
      }
      url = _resolve(ext!, base);
    }
    if (!visited.add(url)) throw LiveException('Playlist cycle detected: $url');
    try {
      String text;
      var finalUrl = url;
      final uri = Uri.parse(url);
      if (_isLoopback(uri)) {
        if (localFetcher == null) {
          throw const LiveException(
            'Plugin loopback playlist requires localFetcher',
          );
        }
        text = await localFetcher(url);
      } else {
        final response = await client.fetch(url, headers: headers);
        finalUrl = response.finalUrl;
        text = decodeConfigText(_expandGzip(response.bytes));
      }
      final trimmed = text.trimLeft();
      if (trimmed.startsWith('{') || trimmed.startsWith('[')) {
        final decoded = trimmed.startsWith('[')
            ? jsonDecode(trimmed)
            : const ConfigDecoder().decode(utf8.encode(text));
        final entries = decoded is List
            ? decoded
            : decoded['lives'] ?? decoded['groups'] ?? decoded['channels'];
        if (entries is! List) {
          throw const LiveException(
            'JSON playlist has no lives/groups/channels',
          );
        }
        await _entries(
          entries,
          out,
          finalUrl,
          group,
          headers,
          epg,
          localFetcher,
          visited,
          depth + 1,
          channelEntries: decoded is List || decoded['channels'] is List,
          onError: onError,
        );
      } else {
        out.addAll(
          parse(
            text,
            baseUrl: finalUrl,
            group: group,
            headers: headers,
            epg: epg,
          ),
        );
      }
    } finally {
      visited.remove(url);
    }
  }

  List<LiveChannel> parse(
    String text, {
    String? baseUrl,
    String group = '默认分组',
    Map<String, String> headers = const {},
    String epg = '',
  }) {
    final trimmed = text.replaceFirst('\ufeff', '').trim();
    return _merge(
      trimmed.startsWith('#EXTM3U') || trimmed.contains('#EXTINF:')
          ? _m3u(trimmed, baseUrl, group, headers, epg)
          : _txt(trimmed, baseUrl, group, headers, epg),
    );
  }

  List<LiveChannel> _m3u(
    String text,
    String? base,
    String group,
    Map<String, String> headers,
    String epg,
  ) {
    final out = <LiveChannel>[];
    var info = <String, String>{};
    var name = '', currentGroup = group, guide = epg;
    var itemHeaders = Map.of(headers);
    for (final original in const LineSplitter().convert(text)) {
      final line = original.trim();
      if (line.startsWith('#EXTM3U')) {
        final attrs = _attributes(line);
        guide = _resolve(attrs['x-tvg-url'] ?? attrs['url-tvg'] ?? epg, base);
      } else if (line.startsWith('#EXTINF:')) {
        info = _attributes(line);
        name = _afterComma(line);
        itemHeaders = Map.of(headers);
      } else if (line.startsWith('#EXTGRP:')) {
        currentGroup = line.substring(8).trim();
      } else if (line.startsWith('#EXTVLCOPT:')) {
        final option = line.substring(11);
        final split = option.indexOf('=');
        if (split >= 0) {
          final key = option.substring(0, split).toLowerCase();
          final field = {
            'http-user-agent': 'User-Agent',
            'http-referrer': 'Referer',
            'http-referer': 'Referer',
            'http-cookie': 'Cookie',
            'http-origin': 'Origin',
          }[key];
          if (field != null) itemHeaders[field] = option.substring(split + 1);
        }
      } else if (line.startsWith(
        '#KODIPROP:inputstream.adaptive.stream_headers=',
      )) {
        itemHeaders.addAll(
          _queryHeaders(line.substring(line.indexOf('=') + 1)),
        );
      } else if (line.isNotEmpty && !line.startsWith('#')) {
        final source = _source(line, base);
        out.add(
          LiveChannel(
            name: name.isEmpty ? info['tvg-name'] ?? '未命名频道' : name,
            urls: [source.$1],
            group: info['group-title'] ?? currentGroup,
            logo: _resolve(info['tvg-logo'] ?? '', base),
            tvgId: info['tvg-id'] ?? '',
            epg: guide,
            headers: {...itemHeaders, ...source.$2},
          ),
        );
        name = '';
        info = {};
        itemHeaders = Map.of(headers);
      }
    }
    return out;
  }

  List<LiveChannel> _txt(
    String text,
    String? base,
    String group,
    Map<String, String> headers,
    String epg,
  ) {
    final out = <LiveChannel>[];
    var currentGroup = group;
    for (final original in const LineSplitter().convert(text)) {
      final line = original.trim();
      if (line.isEmpty || line.startsWith('#') || line.startsWith('//')) {
        continue;
      }
      final comma = line.indexOf(',');
      if (comma < 1) continue;
      final name = line.substring(0, comma).trim();
      final value = line.substring(comma + 1).trim();
      if (value.toLowerCase() == '#genre#') {
        currentGroup = name;
        continue;
      }
      final channelHeaders = Map.of(headers);
      final urls = <String>[];
      for (final part in value.split('#')) {
        if (part.trim().isEmpty) continue;
        final source = _source(part.trim(), base);
        urls.add(source.$1);
        channelHeaders.addAll(source.$2);
      }
      if (urls.isNotEmpty) {
        out.add(
          LiveChannel(
            name: name,
            urls: urls,
            group: currentGroup,
            headers: channelHeaders,
            epg: epg,
          ),
        );
      }
    }
    if (out.isEmpty && text.isNotEmpty) {
      throw const LiveException('No channels found in TXT/M3U playlist');
    }
    return out;
  }

  Future<EpgGuide> loadEpg(
    String url, {
    Map<String, String> headers = const {},
  }) async {
    final response = await client.fetch(url, headers: headers);
    return parseEpg(decodeConfigText(_expandGzip(response.bytes)));
  }

  EpgGuide parseEpg(String text) {
    if (text.trimLeft().startsWith('{')) {
      final raw = jsonMap(jsonDecode(text));
      final channel = str(raw['channel_name'] ?? raw['channel']);
      final date = str(raw['date']);
      final list = jsonList(raw['epg_data']);
      final programs = <EpgProgramme>[];
      for (final value in list) {
        final item = jsonMap(value);
        final start = DateTime.parse(
          '${date}T${item['start']}:00+08:00',
        ).toUtc();
        var end = DateTime.parse('${date}T${item['end']}:00+08:00').toUtc();
        if (!end.isAfter(start)) end = end.add(const Duration(days: 1));
        programs.add(
          EpgProgramme(
            channel: channel,
            start: start,
            end: end,
            title: str(item['title']),
            description: str(item['desc']),
          ),
        );
      }
      return EpgGuide(channels: {channel: channel}, programmes: programs);
    }
    final document = XmlDocument.parse(text);
    final channels = <String, String>{};
    for (final channel in document.findAllElements('channel')) {
      channels[channel.getAttribute('id') ?? ''] =
          channel.getElement('display-name')?.innerText ?? '';
    }
    final programs = <EpgProgramme>[];
    for (final element in document.findAllElements('programme')) {
      final start = _xmlTime(element.getAttribute('start') ?? '');
      final end = _xmlTime(element.getAttribute('stop') ?? '');
      if (start == null || end == null || !end.isAfter(start)) continue;
      programs.add(
        EpgProgramme(
          channel: element.getAttribute('channel') ?? '',
          start: start,
          end: end,
          title: element.getElement('title')?.innerText ?? '',
          description: element.getElement('desc')?.innerText ?? '',
        ),
      );
    }
    programs.sort((a, b) => a.start.compareTo(b.start));
    return EpgGuide(channels: channels, programmes: programs);
  }
}

class EpgProgramme {
  const EpgProgramme({
    required this.channel,
    required this.start,
    required this.end,
    required this.title,
    this.description = '',
  });
  final String channel;
  final DateTime start;
  final DateTime end;
  final String title;
  final String description;
}

class EpgGuide {
  EpgGuide({
    required Map<String, String> channels,
    required List<EpgProgramme> programmes,
  }) : channels = Map.unmodifiable(channels),
       programmes = List.unmodifiable(programmes);
  final Map<String, String> channels;
  final List<EpgProgramme> programmes;
  List<EpgProgramme> forChannel(String id) =>
      programmes.where((p) => p.channel == id).toList();
  EpgProgramme? now(String id, {DateTime? at}) {
    final time = at ?? DateTime.now();
    for (final p in forChannel(id)) {
      if (!time.isBefore(p.start) && time.isBefore(p.end)) return p;
    }
    return null;
  }

  EpgProgramme? next(String id, {DateTime? at}) {
    final time = at ?? DateTime.now();
    final future = forChannel(id).where((p) => p.start.isAfter(time)).toList()
      ..sort((a, b) => a.start.compareTo(b.start));
    return future.isEmpty ? null : future.first;
  }
}

bool _isLoopback(Uri uri) =>
    ['localhost', '::1', '0.0.0.0'].contains(uri.host.toLowerCase()) ||
    uri.host.startsWith('127.');
String _resolve(String value, String? base) => value.isEmpty || base == null
    ? value
    : Uri.parse(base).resolve(value).toString();
Map<String, String> _headers(Object? value) {
  if (value is String) {
    try {
      value = jsonDecode(value);
    } catch (_) {
      return _queryHeaders(str(value));
    }
  }
  return value is Map
      ? value.map((k, v) => MapEntry(k.toString(), str(v)))
      : {};
}

Map<String, String> _queryHeaders(String value) {
  try {
    return Uri.splitQueryString(value);
  } catch (_) {
    return {};
  }
}

(String, Map<String, String>) _source(String value, String? base) {
  final split = value.indexOf('|');
  return (
    _resolve(split < 0 ? value : value.substring(0, split), base),
    split < 0 ? {} : _queryHeaders(value.substring(split + 1)),
  );
}

Map<String, String> _attributes(String line) => {
  for (final m in RegExp(
    r'''([\w-]+)\s*=\s*(?:"([^"]*)"|'([^']*)')''',
  ).allMatches(line))
    m[1]!: m[2] ?? m[3] ?? '',
};
String _afterComma(String line) {
  String? quote;
  for (var i = 0; i < line.length; i++) {
    final c = line[i];
    if (c == quote) {
      quote = null;
    } else if (quote == null && (c == '"' || c == "'")) {
      quote = c;
    } else if (c == ',' && quote == null) {
      return line.substring(i + 1).trim();
    }
  }
  return '';
}

List<LiveChannel> _merge(List<LiveChannel> channels) {
  final result = <String, LiveChannel>{};
  for (final channel in channels) {
    final key = jsonEncode([
      channel.group,
      channel.name,
      channel.tvgId,
      channel.headers,
    ]);
    final previous = result[key];
    result[key] = previous == null
        ? channel
        : LiveChannel(
            name: previous.name,
            urls: {...previous.urls, ...channel.urls}.toList(),
            group: previous.group,
            logo: previous.logo.isEmpty ? channel.logo : previous.logo,
            tvgId: previous.tvgId,
            epg: previous.epg.isEmpty ? channel.epg : previous.epg,
            headers: previous.headers,
          );
  }
  return result.values.toList();
}

List<int> _expandGzip(List<int> input) {
  if (input.length < 2 || input[0] != 0x1f || input[1] != 0x8b) return input;
  final sink = _LiveByteSink();
  final decoder = gzip.decoder.startChunkedConversion(sink)..add(input);
  decoder.close();
  return sink.bytes.takeBytes();
}

class _LiveByteSink implements Sink<List<int>> {
  final bytes = BytesBuilder(copy: false);
  @override
  void add(List<int> data) {
    if (bytes.length + data.length > 32 * 1024 * 1024) {
      throw const LiveException('Expanded playlist/EPG exceeds 32 MiB');
    }
    bytes.add(data);
  }

  @override
  void close() {}
}

DateTime? _xmlTime(String value) {
  final m = RegExp(
    r'^(\d{4})(\d{2})(\d{2})(\d{2})(\d{2})(\d{2})?(?:\s*([+-])(\d{2})(\d{2}))?',
  ).firstMatch(value);
  if (m == null) return null;
  final date = DateTime.utc(
    int.parse(m[1]!),
    int.parse(m[2]!),
    int.parse(m[3]!),
    int.parse(m[4]!),
    int.parse(m[5]!),
    int.parse(m[6] ?? '0'),
  );
  final offset = Duration(
    hours: int.parse(m[8] ?? '0'),
    minutes: int.parse(m[9] ?? '0'),
  );
  return m[7] == '-' ? date.add(offset) : date.subtract(offset);
}
