import 'dart:convert';
import 'dart:io' show ZLibDecoder;
import 'dart:typed_data';

import '../network/app_http_client.dart';

/// Result of inspecting a CatVod/CatVodSpider JAR on a non-Android host.
///
/// Android loads these artifacts with `DexClassLoader`; Windows and iOS have no
/// DEX runtime, so only two things are portable: an embedded JavaScript rule
/// shipped inside the archive, or an explicit "not runnable here" diagnosis
/// instead of a generic network error.
class JarInspection {
  const JarInspection({required this.hasDex, this.embeddedJs, this.descriptor});

  final bool hasDex;
  final String? embeddedJs;
  final String? descriptor;

  bool get isRunnable => embeddedJs != null;

  /// True when the archive needs Android's DEX loader and ships no JS rule.
  bool get isPortableWithoutJs => hasDex && embeddedJs == null;
}

class JarCompat {
  JarCompat(this.http);
  final AppHttpClient http;

  static const maximumBytes = 32 * 1024 * 1024;

  Future<JarInspection> inspect(String url, Map<String, String> headers) async {
    final Uint8List bytes;
    try {
      final response = await http.fetch(url, headers: headers);
      bytes = response.bytes;
    } on AppHttpException catch (error) {
      throw JarInspectError('无法下载 JAR：${error.message}');
    }
    if (bytes.length > maximumBytes) {
      throw const JarInspectError('JAR 超过 32 MiB 限制');
    }
    if (bytes.length < 4 || bytes[0] != 0x50 || bytes[1] != 0x4B) {
      throw const JarInspectError('该地址不是有效的 JAR/ZIP 文件');
    }
    try {
      return _read(bytes);
    } on FormatException catch (error) {
      throw JarInspectError('JAR 结构无法解析：${error.message}');
    }
  }

  static JarInspection _read(Uint8List bytes) {
    final view = ByteData.sublistView(bytes);
    var offset = 0;
    var hasDex = false;
    String? descriptorName;
    String? descriptorText;
    String? jsText;
    while (offset + 30 <= bytes.length) {
      if (view.getUint32(offset, Endian.little) != 0x04034b50) break;
      final flags = view.getUint16(offset + 6, Endian.little);
      final method = view.getUint16(offset + 8, Endian.little);
      final compressed = view.getUint32(offset + 18, Endian.little);
      final nameLength = view.getUint16(offset + 26, Endian.little);
      final extraLength = view.getUint16(offset + 28, Endian.little);
      final nameStart = offset + 30;
      final dataStart = nameStart + nameLength + extraLength;
      if (nameStart + nameLength > bytes.length ||
          dataStart + compressed > bytes.length) {
        break;
      }
      final name = utf8.decode(
        bytes.sublist(nameStart, nameStart + nameLength),
        allowMalformed: true,
      );
      final lower = name.toLowerCase();
      if (lower.endsWith('classes.dex') || lower.endsWith('.dex')) {
        hasDex = true;
      }
      final wanted =
          (lower.endsWith('.json') && lower.contains('spider')) ||
          lower.endsWith('spider.json');
      final isJs = lower.endsWith('.js') && !lower.contains('meta-inf');
      if ((wanted && descriptorText == null) || (isJs && jsText == null)) {
        if ((flags & 0x1) == 0 && (method == 0 || method == 8)) {
          final raw = bytes.sublist(dataStart, dataStart + compressed);
          final Uint8List data;
          if (method == 0) {
            data = raw;
          } else {
            try {
              data = Uint8List.fromList(ZLibDecoder(raw: true).convert(raw));
            } on FormatException {
              offset = dataStart + compressed;
              continue;
            }
          }
          final text = utf8.decode(data, allowMalformed: true);
          if (wanted) {
            descriptorName = name;
            descriptorText = text.length > 1024 * 1024
                ? text.substring(0, 1024 * 1024)
                : text;
          } else {
            jsText = text.length > 4 * 1024 * 1024
                ? text.substring(0, 4 * 1024 * 1024)
                : text;
          }
        }
      }
      offset = dataStart + compressed;
      if (flags & 0x8 != 0) break; // streamed sizes are not trustworthy here.
    }
    return JarInspection(
      hasDex: hasDex,
      embeddedJs: jsText == null ? null : _stripSourceMapping(jsText),
      descriptor: descriptorText ?? descriptorName,
    );
  }

  /// Inline `//# sourceMappingURL=` would otherwise leak a stale path into logs.
  static String _stripSourceMapping(String source) =>
      source.replaceAll(RegExp(r'//[#@]\s*sourceMappingURL=\S+'), '');
}

class JarInspectError implements Exception {
  const JarInspectError(this.message);
  final String message;
  @override
  String toString() => 'JarInspectError: $message';
}
