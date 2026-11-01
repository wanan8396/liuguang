import 'dart:convert';

import 'package:crypto/crypto.dart';

import '../models/models.dart';
import '../network/app_http_client.dart';
import 'config_decoder.dart';

class SubscriptionRepository {
  SubscriptionRepository(
    this.client, {
    this.maxDepth = 8,
    this.maxNodes = 256,
    this.decoder = const ConfigDecoder(),
  });
  final AppHttpClient client;
  final int maxDepth;
  final int maxNodes;
  final ConfigDecoder decoder;
  int _generation = 0;

  Future<ImportResult> load(
    String url, {
    void Function(RepoNode node)? onProgress,
  }) async {
    final state = _ImportState(++_generation, url, onProgress);
    await _visit(state, url, url, null, 0, const {});
    return ImportResult(url: url, nodes: state.nodes);
  }

  Future<ImportResult> loadText(
    String content, {
    String name = '本地配置',
    String baseUrl = 'https://local.invalid/',
  }) async {
    final state = _ImportState(++_generation, baseUrl, null);
    await _visit(
      state,
      baseUrl,
      name,
      null,
      0,
      const {},
      content: utf8.encode(content),
    );
    return ImportResult(url: baseUrl, nodes: state.nodes);
  }

  void cancel() {
    _generation++;
  }

  Future<void> _visit(
    _ImportState state,
    String url,
    String name,
    String? parent,
    int depth,
    Set<String> ancestors, {
    List<int>? content,
  }) async {
    if (state.generation != _generation) return;
    if (state.nodes.length >= maxNodes) {
      if (!state.limitReported) {
        state.limitReported = true;
        state.add(
          RepoNode(
            url: url,
            name: name,
            parentUrl: parent,
            status: 'error',
            error: 'Repository node limit ($maxNodes) exceeded',
          ),
        );
      }
      return;
    }
    var finalUrl = url;
    void error(Object e) => state.add(
      RepoNode(
        url: url,
        name: name,
        parentUrl: parent,
        status: 'error',
        error: e.toString(),
      ),
    );
    try {
      final normalized = normalizeHttpUrl(url).toString();
      if (ancestors.contains(normalized)) {
        error('Repository cycle detected: $url');
        return;
      }
      if (depth > maxDepth) {
        error('Repository depth limit ($maxDepth) exceeded');
        return;
      }
      if (state.seenUrls.containsKey(normalized)) {
        state.add(
          RepoNode(
            url: url,
            name: name,
            parentUrl: parent,
            status: 'mirror',
            mirrorOf: state.seenUrls[normalized],
          ),
        );
        return;
      }
      state.seenUrls[normalized] = normalized;
      state.progress(
        RepoNode(url: url, name: name, parentUrl: parent, status: 'loading'),
      );
      if (state.generation != _generation) return;
      if (content == null) {
        final response = await client.fetch(url);
        content = response.bytes;
        finalUrl = response.finalUrl;
      }
      if (state.generation != _generation) return;
      final finalNormalized = normalizeHttpUrl(finalUrl).toString();
      if (ancestors.contains(finalNormalized)) {
        error('Repository redirect cycle: $finalUrl');
        return;
      }
      final warnings = <String>[];
      final raw = decoder.decode(content, onWarning: warnings.add);
      final resolvedRaw = resolveConfigResources(raw, finalUrl);
      final digest = sha256
          .convert(utf8.encode(jsonEncode(_canonical(resolvedRaw))))
          .toString();
      final previous = state.digests[digest];
      if (previous != null) {
        state.add(
          RepoNode(
            url: finalUrl,
            name: name,
            parentUrl: parent,
            status: 'mirror',
            digest: digest,
            mirrorOf: previous,
          ),
        );
        return;
      }
      state.digests[digest] = finalUrl;
      state.seenUrls[finalNormalized] = finalUrl;
      final isConfig = raw['sites'] is List || raw['lives'] is List;
      final config = isConfig
          ? TvConfig(url: finalUrl, name: name, raw: resolvedRaw)
          : null;
      final children = <dynamic>[
        if (raw['urls'] is List) ...raw['urls'] as List,
        if (raw['storeHouse'] is List) ...raw['storeHouse'] as List,
      ];
      if (!isConfig && children.isEmpty) {
        error('No sites, lives, urls, or storeHouse entries found');
        return;
      }
      state.add(
        RepoNode(
          url: finalUrl,
          name: name,
          parentUrl: parent,
          status: config == null
              ? 'repository'
              : warnings.isEmpty
              ? 'ready'
              : 'warning',
          error: warnings.isEmpty ? null : warnings.join('; '),
          digest: digest,
          config: config,
        ),
      );
      final chain = {...ancestors, normalized, finalNormalized};
      for (final child in children) {
        if (state.generation != _generation) break;
        final map = child is Map ? jsonMap(child) : <String, dynamic>{};
        final reference = child is String
            ? child
            : str(map['url'] ?? map['source']);
        final childName = str(map['name']);
        if (reference.trim().isEmpty) {
          state.add(
            RepoNode(
              url: finalUrl,
              name: childName,
              parentUrl: finalUrl,
              status: 'error',
              error: 'Repository entry has no URL',
            ),
          );
          continue;
        }
        final resolved = Uri.parse(
          finalUrl,
        ).resolve(reference.trim()).toString();
        await _visit(
          state,
          resolved,
          childName.isEmpty ? reference : childName,
          finalUrl,
          depth + 1,
          chain,
        );
      }
    } catch (e) {
      if (state.generation == _generation) error(e);
    }
  }
}

Object? _canonical(Object? value) {
  if (value is Map) {
    final keys = value.keys.map((k) => k.toString()).toList()..sort();
    return {for (final k in keys) k: _canonical(value[k])};
  }
  if (value is List) return value.map(_canonical).toList();
  return value;
}

class _ImportState {
  _ImportState(this.generation, this.root, this.onProgress);
  final int generation;
  final String root;
  final void Function(RepoNode)? onProgress;
  final nodes = <RepoNode>[];
  final digests = <String, String>{};
  final seenUrls = <String, String>{};
  bool limitReported = false;
  void progress(RepoNode node) {
    onProgress?.call(node);
  }

  void add(RepoNode node) {
    nodes.add(node);
    progress(node);
  }
}

/// Resolve resource references only, never executable identifiers, rule strings,
/// HTTP header values, or pipe-delimited extension protocols.
Map<String, dynamic> resolveConfigResources(
  Map<String, dynamic> raw,
  String baseUrl,
) {
  String resolve(String value, {bool resource = false}) {
    if (value.isEmpty || value.contains('|') || value.startsWith('csp_')) {
      return value;
    }
    final uri = Uri.tryParse(value);
    if (uri == null ||
        (uri.hasScheme && !['http', 'https'].contains(uri.scheme))) {
      return value;
    }
    if (uri.hasScheme) return value;
    if (value.startsWith('//') ||
        value.startsWith('./') ||
        value.startsWith('../') ||
        value.startsWith('/') ||
        (resource && !value.startsWith('{') && !value.startsWith('['))) {
      // jar checksums are metadata, not part of the referenced path.
      final suffixAt = value.indexOf(';md5;');
      final path = suffixAt < 0 ? value : value.substring(0, suffixAt);
      final suffix = suffixAt < 0 ? '' : value.substring(suffixAt);
      return '${Uri.parse(baseUrl).resolve(path)}$suffix';
    }
    return value;
  }

  Object? visit(Object? value, String key, {bool resource = false}) {
    if (value is Map) {
      return value.map((k, v) {
        final field = k.toString();
        if (['header', 'headers', 'rules'].contains(field)) {
          return MapEntry(field, v);
        }
        final isResource = [
          'url',
          'urls',
          'logo',
          'epg',
          'icon',
          'wallpaper',
          'spider',
          'jar',
          'file',
        ].contains(field);
        return MapEntry(field, visit(v, field, resource: isResource));
      });
    }
    if (value is List) {
      return value.map((v) => visit(v, key, resource: resource)).toList();
    }
    if (value is String) {
      if (key == 'api' &&
          !value.contains('/') &&
          !value.endsWith('.js') &&
          !value.endsWith('.py')) {
        return value;
      }
      if (key == 'ext') {
        return resolve(
          value,
          resource: RegExp(
            r'\.(json|js|txt|m3u8?|php)([?;].*)?$',
            caseSensitive: false,
          ).hasMatch(value),
        );
      }
      return resource || key == 'api' ? resolve(value, resource: true) : value;
    }
    return value;
  }

  return Map<String, dynamic>.from(visit(raw, '') as Map);
}
