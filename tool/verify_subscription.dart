import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:tvbox/core/config/config_decoder.dart';
import 'package:tvbox/core/config/subscription_repository.dart';
import 'package:tvbox/core/network/app_http_client.dart';

/// Downloads configuration documents only. Never loads/executes source engines,
/// spiders, scripts, playlists, EPG or media. Run with an empty output directory.
Future<void> main(List<String> args) async {
  if (args.length < 2) {
    stderr.writeln(
      'Usage: dart run tool/verify_subscription.dart OUTPUT_DIR ENTRY_URL [DELAY_MS]',
    );
    exitCode = 64;
    return;
  }
  final directory = Directory(args[0]).absolute;
  if (directory.existsSync() && directory.listSync().isNotEmpty) {
    throw ArgumentError('Output directory must be new or empty');
  }
  directory.createSync(recursive: true);
  final entry = args[1];
  final delay = Duration(
    milliseconds: args.length > 2 ? int.parse(args[2]) : 800,
  );
  if (delay.inMilliseconds < 250) {
    throw ArgumentError('Minimum request spacing is 250 ms');
  }
  final client = AppHttpClient(timeout: const Duration(seconds: 30));
  const decoder = ConfigDecoder();
  final report = <String, dynamic>{
    'entry': entry,
    'startedAt': DateTime.now().toUtc().toIso8601String(),
    'nodes': [],
  };
  final nodes = report['nodes'] as List;
  final digests = <String, String>{};
  final seen = <String>{};
  var sequence = 0;
  Future<void> saveReport() => File(
    '${directory.path}/report.json',
  ).writeAsString(const JsonEncoder.withIndent('  ').convert(report));
  Future<void> visit(String url, String name, int depth) async {
    if (depth > 8 || sequence >= 256 || !seen.add(url)) return;
    if (sequence > 0) await Future<void>.delayed(delay);
    final nodeDirectory = Directory(
      '${directory.path}/${(++sequence).toString().padLeft(3, '0')}',
    )..createSync();
    final node = <String, dynamic>{'name': name, 'url': url, 'depth': depth};
    nodes.add(node);
    try {
      final fetched = await client.fetch(url);
      await File('${nodeDirectory.path}/body.bin').writeAsBytes(fetched.bytes);
      final warnings = <String>[];
      final raw = decoder.decode(fetched.bytes, onWarning: warnings.add);
      final resolved = resolveConfigResources(raw, fetched.finalUrl);
      final canonical = _canonical(resolved);
      final digest = sha256
          .convert(utf8.encode(jsonEncode(canonical)))
          .toString();
      final mirror = digests[digest];
      digests[digest] = mirror ?? fetched.finalUrl;
      await File(
        '${nodeDirectory.path}/decoded.json',
      ).writeAsString(const JsonEncoder.withIndent('  ').convert(raw));
      await File(
        '${nodeDirectory.path}/resolved.json',
      ).writeAsString(const JsonEncoder.withIndent('  ').convert(resolved));
      final sites = raw['sites'] is List ? raw['sites'] as List : [];
      final counts = <String, int>{};
      for (final site in sites.whereType<Map>()) {
        final type = site['type'];
        final api = '${site['api'] ?? ''}';
        final runtime = '$type' == '4'
            ? 'type4'
            : api.startsWith('csp_')
            ? 'csp'
            : api.contains('.js')
            ? 'js'
            : 'other';
        counts[runtime] = (counts[runtime] ?? 0) + 1;
      }
      node.addAll({
        'finalUrl': fetched.finalUrl,
        'statusCode': fetched.statusCode,
        'bytes': fetched.bytes.length,
        'sha256': sha256.convert(fetched.bytes).toString(),
        'configDigest': digest,
        'sites': sites.length,
        'runtimeCounts': counts,
        'warnings': warnings,
        'status': mirror == null ? 'ok' : 'mirror',
        'mirrorOf': ?mirror,
      });
      stdout.writeln(
        '${sequence.toString().padLeft(3, '0')} ${node['status']} $name sites=${sites.length} $counts${warnings.isEmpty ? '' : ' warnings=$warnings'}',
      );
      await saveReport();
      if (mirror == null) {
        final children = [
          ...?raw['urls'] as List?,
          ...?raw['storeHouse'] as List?,
        ];
        for (final child in children) {
          final reference = child is String
              ? child
              : '${(child as Map)['url'] ?? ''}';
          if (reference.isEmpty) continue;
          final childName = child is Map
              ? '${child['name'] ?? reference}'
              : reference;
          await visit(
            Uri.parse(fetched.finalUrl).resolve(reference).toString(),
            childName,
            depth + 1,
          );
        }
      }
    } catch (e) {
      node.addAll({'status': 'error', 'error': '$e'});
      stdout.writeln('${sequence.toString().padLeft(3, '0')} error $name $e');
      await saveReport();
    }
  }

  try {
    await visit(entry, '入口', 0);
    report['finishedAt'] = DateTime.now().toUtc().toIso8601String();
    report['uniqueConfigs'] = nodes
        .where((n) => n['status'] == 'ok' && (n['sites'] as int? ?? 0) > 0)
        .length;
    report['totalUniqueSites'] = nodes
        .where((n) => n['status'] == 'ok')
        .fold<int>(0, (sum, n) => sum + (n['sites'] as int? ?? 0));
    await saveReport();
    stdout.writeln(
      'REPORT ${directory.path}/report.json uniqueConfigs=${report['uniqueConfigs']} uniqueSites=${report['totalUniqueSites']}',
    );
  } finally {
    client.close();
  }
}

Object? _canonical(Object? value) {
  if (value is Map) {
    final keys = value.keys.map((k) => '$k').toList()..sort();
    return {for (final key in keys) key: _canonical(value[key])};
  }
  if (value is List) return value.map(_canonical).toList();
  return value;
}
