import 'dart:convert';

/// The portable-JAR contract, deliberately separate from Java's MANIFEST.MF.
///
/// META-INF/liuguang.json (preferred), or a versioned root spider.json:
/// {"version":1,"spiders":{"csp_Fixture":{"entry":"spiders/fixture.js"}}}
/// A descriptor without this contract is metadata, not executable JavaScript.
class JarManifest {
  const JarManifest._(this.spiders);

  static const path = 'META-INF/liuguang.json';
  static const currentVersion = 1;
  final Map<String, String> spiders;

  factory JarManifest.parse(String text) =>
      JarManifest.fromJson(jsonDecode(text));

  factory JarManifest.fromJson(Object? value) {
    if (value is! Map ||
        value['version'] is! int ||
        value['version'] != currentVersion) {
      throw const FormatException('Expected portable JAR manifest version 1');
    }
    final mappings = value['spiders'];
    if (mappings is! Map || mappings.isEmpty) {
      throw const FormatException(
        'Manifest spiders must be a non-empty object',
      );
    }
    final spiders = <String, String>{};
    for (final mapping in mappings.entries) {
      final api = mapping.key;
      final spec = mapping.value;
      if (api is! String ||
          !RegExp(r'^csp_[^\s/\\:#?]+$').hasMatch(api) ||
          spec is! Map ||
          spec['entry'] is! String) {
        throw const FormatException('Expected csp_*: {entry: relative.js}');
      }
      final entry = spec['entry'] as String;
      if (!isArchivePath(entry) || !entry.toLowerCase().endsWith('.js')) {
        throw FormatException('Invalid JavaScript entry for $api');
      }
      spiders[api] = entry;
    }
    return JarManifest._(Map.unmodifiable(spiders));
  }

  String? entryFor(String api) => spiders[api];

  /// ZIP entries are identifiers, not filesystem or URI paths. No normalization
  /// is performed, so an entry cannot acquire a different meaning at runtime.
  static bool isArchivePath(String path, {bool directory = false}) {
    if (path.isEmpty ||
        path.startsWith('/') ||
        path.contains('\\') ||
        path.contains(':') ||
        path.codeUnits.any((c) => c < 0x20 || c == 0x7f)) {
      return false;
    }
    final value = directory && path.endsWith('/')
        ? path.substring(0, path.length - 1)
        : path;
    return value.isNotEmpty &&
        value
            .split('/')
            .every((part) => part.isNotEmpty && part != '.' && part != '..');
  }
}
