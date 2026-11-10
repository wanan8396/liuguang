import 'dart:convert';

/// TVBox posters can append request headers after the image URL.
/// Keep ordinary URL @ characters (userinfo, filenames, CDN transforms) intact.
class ImageRequest {
  const ImageRequest(this.url, this.headers);
  final String url;
  final Map<String, String> headers;

  factory ImageRequest.parse(
    String value, {
    Map<String, String> headers = const {},
  }) {
    var url = value.trim();
    final result = <String, String>{};
    void merge(String name, String value) {
      if (!RegExp(r'^[!#$%&\x27*+.^_`|~0-9A-Za-z-]+$').hasMatch(name) ||
          RegExp(r'[\r\n\x00]').hasMatch(value)) {
        return;
      }
      result.removeWhere((key, _) => key.toLowerCase() == name.toLowerCase());
      result[name] = value;
    }

    headers.forEach(merge);
    final marker = RegExp(
      r'[@|](?:Headers|User-Agent|Referer|Origin|Cookie|Authorization)=',
      caseSensitive: false,
    ).firstMatch(url);
    if (marker != null) {
      final metadata = url.substring(marker.start + 1);
      final queryStyle = url[marker.start] == '|';
      url = url.substring(0, marker.start).trim();
      try {
        if (metadata.toLowerCase().startsWith('headers=')) {
          var json = metadata.substring(metadata.indexOf('=') + 1);
          if (json.startsWith('%')) json = Uri.decodeComponent(json);
          final values = jsonDecode(json);
          if (values is Map) {
            for (final entry in values.entries) {
              if (entry.value is String) {
                merge(entry.key.toString(), entry.value);
              }
            }
          }
        } else if (queryStyle) {
          Uri.splitQueryString(metadata).forEach(merge);
        } else {
          final parts = metadata.split(
            RegExp(
              r'@(?=(?:User-Agent|Referer|Origin|Cookie|Authorization)=)',
              caseSensitive: false,
            ),
          );
          for (final part in parts) {
            final split = part.indexOf('=');
            if (split > 0) {
              merge(part.substring(0, split), part.substring(split + 1));
            }
          }
        }
      } on FormatException {
        // A malformed optional header must not corrupt the original image path.
      }
    }
    if (url.startsWith('//')) url = 'https:$url';
    return ImageRequest(url, Map.unmodifiable(result));
  }
}
