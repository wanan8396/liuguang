import 'package:json5/json5.dart';

/// Identifies an imported rule without evaluating any JavaScript. The original
/// source stays in the config so local files also survive backup and restore.
class JsRuleImport {
  const JsRuleImport(this.source, this.title);

  final String source;
  final String? title;

  static JsRuleImport? tryParse(String source, {bool fromJsFile = false}) {
    final text = source.replaceFirst('\ufeff', '').trim();
    if (text.isEmpty || text.startsWith('<')) return null;
    if (!fromJsFile &&
        !RegExp(
          r'\b(?:var|let|const)\s+rule\s*=|\b__JS_SPIDER__\b|\bexport\s+default\b|\b__jsEvalReturn\b',
        ).hasMatch(text)) {
      return null;
    }
    // Read only a small literal title for display; functions, templates and
    // computed properties are intentionally left to the runtime, not import.
    final preview = text.length > 65536 ? text.substring(0, 65536) : text;
    final match = RegExp(
      r'''(?:^|[,{])\s*(?:title|"title"|'title')\s*:\s*("(?:\\.|[^"\\\r\n])*"|'(?:\\.|[^'\\\r\n])*')''',
    ).firstMatch(preview);
    String? title;
    if (match != null) {
      try {
        final value = json5Decode(match.group(1)!);
        if (value is String && value.trim().isNotEmpty) {
          title = value.trim();
        }
      } catch (_) {
        // A title is optional metadata, never a reason to reject a rule.
      }
    }
    return JsRuleImport(source, title);
  }

  Map<String, dynamic> toConfig({required String api, required String name}) =>
      {
        'sites': [
          {
            'key': 'js_import',
            'name': title ?? name,
            'type': 3,
            'api': api,
            'searchable': 1,
            'filterable': 1,
            '_jsSource': source,
          },
        ],
      };
}

bool isJsRuleUrl(String value) =>
    Uri.tryParse(value)?.path.toLowerCase().endsWith('.js') ?? false;

String jsRuleName(String name, String url) {
  final uri = Uri.tryParse(name);
  if (name.trim().isNotEmpty &&
      name != '本地配置' &&
      !['http', 'https'].contains(uri?.scheme)) {
    return name.replaceFirst(RegExp(r'\.js$', caseSensitive: false), '');
  }
  final segments = Uri.tryParse(url)?.pathSegments ?? const <String>[];
  final file = segments.where((segment) => segment.isNotEmpty).lastOrNull;
  return file != null && isJsRuleUrl(url)
      ? file.replaceFirst(RegExp(r'\.js$', caseSensitive: false), '')
      : 'JavaScript 源';
}
