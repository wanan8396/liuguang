import 'dart:convert';

Map<String, dynamic> jsonMap(Object? value) {
  if (value is String && value.trim().isNotEmpty) {
    return jsonMap(jsonDecode(value));
  }
  if (value is Map) {
    return value.map((key, value) => MapEntry(key.toString(), value));
  }
  return <String, dynamic>{};
}

List<dynamic> jsonList(Object? value) => value is List ? value : const [];
int intValue(Object? value, [int fallback = 0]) =>
    value is num ? value.toInt() : int.tryParse('$value') ?? fallback;
String str(Object? value) => value?.toString() ?? '';

class Site {
  Site(Map<String, dynamic> raw) : raw = Map.unmodifiable(raw);
  final Map<String, dynamic> raw;
  String get key => str(raw['key']);
  String get name => str(raw['name']).isEmpty ? key : str(raw['name']);
  int get type => intValue(raw['type'], 3);
  String get api => str(raw['api']);
  dynamic get ext => raw['ext'];
  String get jar => str(raw['jar']);
  bool get searchable => intValue(raw['searchable'], 1) != 0;
  bool get filterable => intValue(raw['filterable'], 1) != 0;
  String get runtime => type == 4
      ? 'remote'
      : type == 0 || type == 1
      ? 'cms'
      : api.startsWith('csp_')
      ? 'jar'
      : api.contains('.js') || str(raw['_jsSource']).trim().isNotEmpty
      ? 'js'
      : api.contains('.py')
      ? 'python'
      : 'unknown';
  Map<String, dynamic> toJson() => Map.of(raw);
}

class TvConfig {
  TvConfig({
    required this.url,
    required this.name,
    required Map<String, dynamic> raw,
  }) : raw = Map.unmodifiable(raw);
  final String url;
  final String name;
  final Map<String, dynamic> raw;
  List<Site> get sites =>
      jsonList(raw['sites']).map((e) => Site(jsonMap(e))).toList();
  String get spider => str(raw['spider']);
  List<Map<String, dynamic>> get parses =>
      jsonList(raw['parses']).map(jsonMap).toList();
  List<dynamic> get lives => jsonList(raw['lives']);
  List<String> get flags => jsonList(raw['flags']).map(str).toList();
  Map<String, dynamic> toJson() => {'url': url, 'name': name, 'raw': raw};
  factory TvConfig.fromJson(Map<String, dynamic> json) => TvConfig(
    url: str(json['url']),
    name: str(json['name']),
    raw: jsonMap(json['raw']),
  );
}

class RepoNode {
  RepoNode({
    required this.url,
    required this.name,
    this.parentUrl,
    this.status = 'pending',
    this.error,
    this.config,
    this.digest,
    this.mirrorOf,
  });
  final String url;
  final String name;
  final String? parentUrl;
  final String status;
  final String? error;
  final TvConfig? config;
  final String? digest;
  final String? mirrorOf;
  Map<String, dynamic> toJson() => {
    'url': url,
    'name': name,
    'parentUrl': parentUrl,
    'status': status,
    'error': error,
    'config': config?.toJson(),
    'digest': digest,
    'mirrorOf': mirrorOf,
  };
  factory RepoNode.fromJson(Map<String, dynamic> json) => RepoNode(
    url: str(json['url']),
    name: str(json['name']),
    parentUrl: json['parentUrl'] as String?,
    status: str(json['status']),
    error: json['error'] as String?,
    digest: json['digest'] as String?,
    mirrorOf: json['mirrorOf'] as String?,
    config: json['config'] == null
        ? null
        : TvConfig.fromJson(jsonMap(json['config'])),
  );
}

class ImportResult {
  ImportResult({required this.url, required this.nodes, DateTime? checkedAt})
    : checkedAt = checkedAt ?? DateTime.now();
  final String url;
  final List<RepoNode> nodes;
  final DateTime checkedAt;
  List<TvConfig> get configs =>
      nodes.where((n) => n.config != null).map((n) => n.config!).toList();
  Map<String, dynamic> toJson() => {
    'url': url,
    'checkedAt': checkedAt.toIso8601String(),
    'nodes': nodes.map((n) => n.toJson()).toList(),
  };
  factory ImportResult.fromJson(Map<String, dynamic> json) => ImportResult(
    url: str(json['url']),
    checkedAt: DateTime.tryParse(str(json['checkedAt'])),
    nodes: jsonList(
      json['nodes'],
    ).map((n) => RepoNode.fromJson(jsonMap(n))).toList(),
  );
}

class Category {
  Category({required this.id, required this.name});
  final String id;
  final String name;
  factory Category.fromJson(Map<String, dynamic> json) => Category(
    id: str(json['type_id'] ?? json['id']),
    name: str(json['type_name'] ?? json['name']),
  );
}

class Vod {
  Vod(Map<String, dynamic> raw) : raw = Map.unmodifiable(raw);
  final Map<String, dynamic> raw;
  String get id => str(raw['vod_id'] ?? raw['id']);
  String get name => str(raw['vod_name'] ?? raw['name']);
  String get pic => str(raw['vod_pic'] ?? raw['pic']);
  String get remarks => str(raw['vod_remarks'] ?? raw['remarks']);
  String get content => str(raw['vod_content'] ?? raw['content']);
  String get score => str(raw['vod_score'] ?? raw['vod_douban_score']);
  String get year => str(raw['vod_year']);
  String get area => str(raw['vod_area']);
  String get actor => str(raw['vod_actor']);
  String get director => str(raw['vod_director']);
  Map<String, dynamic> toJson() => Map.of(raw);
}

class VodPage {
  VodPage({
    this.items = const [],
    this.categories = const [],
    this.filters = const {},
    this.page = 1,
    this.pageCount = 1,
    this.total = 0,
  });
  final List<Vod> items;
  final List<Category> categories;
  final Map<String, dynamic> filters;
  final int page;
  final int pageCount;
  final int total;
  factory VodPage.fromJson(Map<String, dynamic> json) => VodPage(
    items: jsonList(json['list']).map((v) => Vod(jsonMap(v))).toList(),
    categories: jsonList(
      json['class'],
    ).map((c) => Category.fromJson(jsonMap(c))).toList(),
    filters: jsonMap(json['filters']),
    page: intValue(json['page'], 1),
    pageCount: intValue(json['pagecount'], 1),
    total: intValue(json['total']),
  );
}

class Episode {
  const Episode({required this.name, required this.id});
  final String name;
  final String id;
}

class PlayLine {
  const PlayLine({required this.name, required this.episodes});
  final String name;
  final List<Episode> episodes;
}

class VodDetail {
  VodDetail({required this.vod, required this.lines});
  final Vod vod;
  final List<PlayLine> lines;
  factory VodDetail.fromVod(Vod vod) {
    final names = str(vod.raw['vod_play_from']).split(r'$$$');
    final groups = str(vod.raw['vod_play_url']).split(r'$$$');
    final lines = <PlayLine>[];
    for (var i = 0; i < groups.length; i++) {
      final episodes = <Episode>[];
      for (final entry in groups[i].split('#')) {
        if (entry.trim().isEmpty) continue;
        final split = entry.indexOf(r'$');
        episodes.add(
          Episode(
            name: split < 0 ? '播放' : entry.substring(0, split),
            id: split < 0 ? entry : entry.substring(split + 1),
          ),
        );
      }
      if (episodes.isNotEmpty) {
        lines.add(
          PlayLine(
            name: i < names.length && names[i].isNotEmpty
                ? names[i]
                : '线路 ${i + 1}',
            episodes: episodes,
          ),
        );
      }
    }
    return VodDetail(vod: vod, lines: lines);
  }
}

class Playback {
  Playback({
    required this.url,
    this.headers = const {},
    this.subtitle,
    this.parse = false,
    this.raw = const {},
  });
  final String url;
  final Map<String, String> headers;
  final String? subtitle;
  final bool parse;
  final Map<String, dynamic> raw;

  /// Upstream headers remain available for subtitles and the source proxy.
  /// The local media request must not look like a cross-origin browser request.
  Map<String, String> get mediaHeaders {
    final host = Uri.tryParse(url)?.host;
    if (!{'localhost', '127.0.0.1', '::1', '[::1]'}.contains(host)) {
      return headers;
    }
    return Map.fromEntries(
      headers.entries.where((entry) => entry.key.toLowerCase() != 'origin'),
    );
  }

  factory Playback.fromJson(Map<String, dynamic> json) {
    var header = json['header'] ?? json['headers'];
    if (header is String && header.trim().startsWith('{')) {
      header = jsonDecode(header);
    }
    return Playback(
      url: str(json['url']),
      headers: jsonMap(
        header is Map ? header : null,
      ).map((key, value) => MapEntry(key, str(value))),
      subtitle: json['subt'] as String?,
      parse: intValue(json['parse']) != 0,
      raw: Map.of(json),
    );
  }
}

class LiveChannel {
  LiveChannel({
    required this.name,
    required this.urls,
    this.group = '默认分组',
    this.logo = '',
    this.tvgId = '',
    this.epg = '',
    this.headers = const {},
    this.configUrl = '',
    this.siteKey = '',
    this.sourceName = '',
  });
  final String name;
  final List<String> urls;
  final String group;
  final String logo;
  final String tvgId;
  final String epg;
  final Map<String, String> headers;
  final String configUrl, siteKey, sourceName;
  Map<String, dynamic> toJson() => {
    'name': name,
    'urls': urls,
    'group': group,
    'logo': logo,
    'tvgId': tvgId,
    'epg': epg,
    'headers': headers,
    'configUrl': configUrl,
    'siteKey': siteKey,
    'sourceName': sourceName,
  };
  factory LiveChannel.fromJson(Map<String, dynamic> json) => LiveChannel(
    name: str(json['name']),
    urls: jsonList(json['urls']).map(str).toList(),
    group: str(json['group']),
    logo: str(json['logo']),
    tvgId: str(json['tvgId']),
    epg: str(json['epg']),
    headers: jsonMap(json['headers']).map((k, v) => MapEntry(k, str(v))),
    configUrl: str(json['configUrl']),
    siteKey: str(json['siteKey']),
    sourceName: str(json['sourceName']),
  );
}

class LibraryEntry {
  LibraryEntry({
    required this.configUrl,
    required this.siteKey,
    required this.vod,
    this.line = '',
    this.episode = '',
    this.episodeId = '',
    this.positionMs = 0,
    this.durationMs = 0,
    DateTime? updatedAt,
  }) : updatedAt = updatedAt ?? DateTime.now();
  final String configUrl;
  final String siteKey;
  final Vod vod;
  final String line;
  final String episode;
  final String episodeId;
  final int positionMs;
  final int durationMs;
  final DateTime updatedAt;
  String get key => jsonEncode([configUrl, siteKey, vod.id]);
  Map<String, dynamic> toJson() => {
    'configUrl': configUrl,
    'siteKey': siteKey,
    'vod': vod.toJson(),
    'line': line,
    'episode': episode,
    'episodeId': episodeId,
    'positionMs': positionMs,
    'durationMs': durationMs,
    'updatedAt': updatedAt.toIso8601String(),
  };
  factory LibraryEntry.fromJson(Map<String, dynamic> json) => LibraryEntry(
    configUrl: str(json['configUrl']),
    siteKey: str(json['siteKey']),
    vod: Vod(jsonMap(json['vod'])),
    line: str(json['line']),
    episode: str(json['episode']),
    episodeId: str(json['episodeId']),
    positionMs: intValue(json['positionMs']),
    durationMs: intValue(json['durationMs']),
    updatedAt: DateTime.tryParse(str(json['updatedAt'])),
  );
}
