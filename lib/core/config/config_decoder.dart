import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:json5/json5.dart';
import 'package:pointycastle/export.dart';

class ConfigDecodeException implements Exception {
  const ConfigDecodeException(this.message);
  final String message;
  @override
  String toString() => 'ConfigDecodeException: $message';
}

class ConfigDecoder {
  const ConfigDecoder({
    this.maxDecodedBytes = 16 * 1024 * 1024,
    this.maxLayers = 6,
  });
  final int maxDecodedBytes;
  final int maxLayers;

  Map<String, dynamic> decode(
    List<int> input, {
    void Function(String warning)? onWarning,
  }) {
    var bytes = Uint8List.fromList(input);
    for (var layer = 0; layer < maxLayers; layer++) {
      if (bytes.length > maxDecodedBytes) {
        throw const ConfigDecodeException(
          'Decoded configuration exceeds size limit',
        );
      }
      if (bytes.length > 2 && bytes[0] == 0x1f && bytes[1] == 0x8b) {
        final sink = _BoundedSink(maxDecodedBytes);
        final converter = gzip.decoder.startChunkedConversion(sink);
        converter.add(bytes);
        converter.close();
        bytes = sink.bytes.takeBytes();
        continue;
      }
      if (bytes.length > 1 && bytes[0] == 0x24 && bytes[1] == 0x23) {
        bytes = _decodeAes(bytes);
        continue;
      }
      // Some prefix wrappers are genuine JPEG bytes, not Unicode text. Locate
      // the advertised ** delimiter before text decoding and require a base64 tail.
      Uint8List? prefixed;
      for (
        var marker = _indexOf(bytes, [42, 42], 0);
        marker >= 0;
        marker = _indexOf(bytes, [42, 42], marker + 2)
      ) {
        final tail = bytes.sublist(marker + 2);
        if (tail.any((b) => b > 127)) continue;
        final candidate = ascii.decode(tail).replaceAll(RegExp(r'\s+'), '');
        if (candidate.length < 4 ||
            !RegExp(r'^[A-Za-z0-9+/_=-]+$').hasMatch(candidate)) {
          continue;
        }
        try {
          prefixed = base64.decode(base64.normalize(candidate));
          break;
        } catch (_) {
          /* not a prefix wrapper */
        }
      }
      if (prefixed != null) {
        bytes = prefixed;
        continue;
      }
      var text = decodeConfigText(
        bytes,
        onWarning: onWarning,
      ).replaceFirst('\ufeff', '').trim();
      // Hex containers advertise themselves with the ASCII hex for "$#".
      final compact = text.replaceAll(RegExp(r'\s+'), '');
      if (compact.startsWith('2423') &&
          compact.length.isEven &&
          RegExp(r'^[0-9a-fA-F]+$').hasMatch(compact)) {
        bytes = Uint8List.fromList([
          for (var i = 0; i < compact.length; i += 2)
            int.parse(compact.substring(i, i + 2), radix: 16),
        ]);
        continue;
      }
      if (text.startsWith(r'$#')) {
        bytes = _decodeAes(bytes);
        continue;
      }
      Object? value;
      try {
        value = jsonDecode(text);
      } catch (_) {
        try {
          value = json5Decode(text);
        } catch (_) {
          value = null;
        }
      }
      if (value is Map) return value.map((k, v) => MapEntry(k.toString(), v));
      if (value is String) {
        bytes = Uint8List.fromList(utf8.encode(value));
        continue;
      }
      // TVBox prefix wrappers terminate at **. Do not strip arbitrary JSON fields.
      final marker = text.indexOf('**');
      if (marker >= 0) text = text.substring(marker + 2).trim();
      if (text.startsWith('base64://')) text = text.substring(9);
      final candidate = text.replaceAll(RegExp(r'\s+'), '');
      if (RegExp(r'^[A-Za-z0-9+/_=-]+$').hasMatch(candidate)) {
        try {
          bytes = base64.decode(base64.normalize(candidate));
          continue;
        } catch (_) {
          /* report below */
        }
      }
      throw const ConfigDecodeException(
        'Unsupported or malformed configuration; expected JSON/JSON5, gzip, base64, or AES2423',
      );
    }
    throw ConfigDecodeException(
      'Configuration wrapping exceeds $maxLayers layers',
    );
  }

  Uint8List _decodeAes(Uint8List envelope) {
    // Framing is supplied by the envelope, not inferred from decoded JSON.
    final separator = _indexOf(envelope, ascii.encode(r'#$'), 2);
    if (separator < 0) {
      throw const ConfigDecodeException(r'AES2423 header is missing #$');
    }
    final keyText = envelope.sublist(2, separator);
    if (keyText.isEmpty || keyText.length > 16) {
      throw const ConfigDecodeException('Invalid AES128 key length');
    }
    final key = Uint8List(16)
      ..fillRange(0, 16, 0x30)
      ..setAll(0, keyText);
    final payload = envelope.sublist(separator + 2);
    const ivLength = 13;
    if (payload.length <= ivLength || (payload.length - ivLength) % 16 != 0) {
      throw const ConfigDecodeException('Invalid AES2423 ciphertext length');
    }
    final ciphertext = payload.sublist(0, payload.length - ivLength);
    final ivBytes = payload.sublist(payload.length - ivLength);
    if (ivBytes.any((v) => v > 127)) {
      throw const ConfigDecodeException('AES2423 IV must be ASCII');
    }
    try {
      final iv = Uint8List(16)
        ..fillRange(0, 16, 0x30)
        ..setAll(0, ivBytes);
      final cipher = PaddedBlockCipher('AES/CBC/PKCS7')
        ..init(
          false,
          PaddedBlockCipherParameters(
            ParametersWithIV(KeyParameter(key), iv),
            null,
          ),
        );
      return cipher.process(Uint8List.fromList(ciphertext));
    } catch (_) {
      throw const ConfigDecodeException('Invalid AES2423 PKCS7 padding');
    }
  }
}

int _indexOf(List<int> bytes, List<int> needle, int start) {
  for (var i = start; i <= bytes.length - needle.length; i++) {
    if (List.generate(
      needle.length,
      (j) => bytes[i + j] == needle[j],
    ).every((v) => v)) {
      return i;
    }
  }
  return -1;
}

/// Recover isolated legacy bytes only within positively identified JSON comments.
/// Invalid bytes in strings (URLs, keys) or structure are always fatal.
String decodeConfigText(
  List<int> bytes, {
  void Function(String warning)? onWarning,
}) {
  try {
    return utf8.decode(bytes);
  } on FormatException {
    final out = StringBuffer();
    var lineComment = false, blockComment = false, escaped = false;
    int? quote;
    for (var i = 0; i < bytes.length;) {
      final first = bytes[i];
      final next = i + 1 < bytes.length ? bytes[i + 1] : -1;
      final length = first < 0x80
          ? 1
          : first >= 0xc2 && first <= 0xdf
          ? 2
          : first >= 0xe0 && first <= 0xef
          ? 3
          : first >= 0xf0 && first <= 0xf4
          ? 4
          : 0;
      String? decoded;
      if (length > 0 && i + length <= bytes.length) {
        try {
          decoded = utf8.decode(bytes.sublist(i, i + length));
        } on FormatException {
          /* verify lexical context below */
        }
      }
      if (decoded == null) {
        if (!lineComment && !blockComment) {
          throw ConfigDecodeException(
            'Invalid UTF8 outside a JSON comment at byte $i (0x${first.toRadixString(16)})',
          );
        }
        onWarning?.call(
          'Recovered legacy byte 0x${first.toRadixString(16)} in JSON comment at decoded byte $i',
        );
        out.writeCharCode(first);
        i++;
        continue;
      }
      out.write(decoded);
      if (length == 1) {
        if (lineComment) {
          if (first == 10 || first == 13) lineComment = false;
        } else if (blockComment) {
          if (first == 42 && next == 47) {
            out.write('/');
            i += 2;
            blockComment = false;
            continue;
          }
        } else if (quote != null) {
          if (escaped) {
            escaped = false;
          } else if (first == 92) {
            escaped = true;
          } else if (first == quote) {
            quote = null;
          }
        } else if (first == 34 || first == 39) {
          quote = first;
        } else if (first == 47 && (next == 47 || next == 42)) {
          lineComment = next == 47;
          blockComment = next == 42;
          out.writeCharCode(next);
          i += 2;
          continue;
        }
      }
      i += length;
    }
    return out.toString();
  }
}

class _BoundedSink implements Sink<List<int>> {
  _BoundedSink(this.limit);
  final int limit;
  final bytes = BytesBuilder(copy: false);
  @override
  void add(List<int> data) {
    if (bytes.length + data.length > limit) {
      throw const ConfigDecodeException('Expanded gzip exceeds size limit');
    }
    bytes.add(data);
  }

  @override
  void close() {}
}
