import 'dart:convert';
import 'dart:typed_data';

import 'package:archive/archive.dart';
import 'package:crypto/crypto.dart' show md5;

import '../network/app_http_client.dart';
import 'jar_manifest.dart';

export 'jar_manifest.dart';

/// Result of inspecting a JAR on a host without Android's DEX loader.
class JarInspection {
  const JarInspection({
    required this.hasDex,
    this.embeddedJs,
    this.descriptor,
    this.parsedDescriptor,
    this.manifest,
    this.selectedEntry,
  });

  final bool hasDex;
  final String? embeddedJs;

  /// Original root spider.json text, retained for existing consumers.
  final String? descriptor;
  final Map<String, dynamic>? parsedDescriptor;
  final JarManifest? manifest;
  final String? selectedEntry;

  bool get isRunnable => embeddedJs != null;
  bool get requiresAndroid => hasDex && !isRunnable;

  /// Historical name had the opposite meaning. Use [requiresAndroid].
  @Deprecated('Use requiresAndroid; this legacy name is misleading')
  bool get isPortableWithoutJs => requiresAndroid;
}

class JarCompat {
  JarCompat(this.http);
  final AppHttpClient http;

  // Match AppHttpClient's default; a caller may impose an even smaller cap.
  static const maximumBytes = 8 * 1024 * 1024;
  static const maximumEntries = 2048;
  static const maximumEntryBytes = 8 * 1024 * 1024;
  static const maximumExpandedBytes = 32 * 1024 * 1024;
  static const maximumJsBytes = 4 * 1024 * 1024;
  static const maximumDescriptorBytes = 1024 * 1024;

  /// [spider] is the site's exact API (for example csp_Fixture), never a class
  /// suffix guess. Without it, a manifest archive is inspected but not selected.
  /// Archives without a manifest may use the exact root entry `spider.js`.
  Future<JarInspection> inspect(
    String url,
    Map<String, String> headers, {
    String? spider,
    String? expectedMd5,
  }) async {
    final Uint8List bytes;
    try {
      final response = http.maxBytes > maximumBytes
          ? await http.fetchPrefix(
              url,
              headers: headers,
              maxBytes: maximumBytes + 1,
            )
          : await http.fetch(url, headers: headers);
      bytes = response.bytes;
    } on AppHttpException catch (error) {
      throw JarInspectError('JAR download failed: ${error.message}');
    }
    return inspectBytes(bytes, spider: spider, expectedMd5: expectedMd5);
  }

  /// Inspects only in-memory data; never extracts or evaluates archive content.
  /// Limits and CRC checks apply to every entry, including unselected libraries.
  static JarInspection inspectBytes(
    Uint8List bytes, {
    String? spider,
    String? expectedMd5,
  }) {
    if (bytes.length > maximumBytes) {
      throw const JarInspectError('JAR exceeds the 8 MiB archive limit');
    }
    if (expectedMd5 != null) {
      if (!RegExp(r'^[a-fA-F0-9]{32}$').hasMatch(expectedMd5)) {
        throw const JarInspectError('Invalid expected JAR MD5');
      }
      if (md5.convert(bytes).toString() != expectedMd5.toLowerCase()) {
        throw const JarInspectError('JAR MD5 mismatch');
      }
    }
    try {
      return _read(bytes, spider);
    } on JarInspectError {
      rethrow;
    } on FormatException catch (error) {
      throw JarInspectError('Invalid JAR structure: ${error.message}');
    } on RangeError catch (error) {
      throw JarInspectError('Truncated JAR structure: $error');
    }
  }

  static JarInspection _read(Uint8List bytes, String? spider) {
    final view = ByteData.sublistView(bytes);
    final end = _directoryBounds(view);
    final directory = ZipDirectory();
    final entries = <ZipFileHeader>[];
    final names = <String>{};
    var declaredTotal = 0;
    // Do not let the package materialize an unbounded list of directory entries.
    for (final header in directory.headers(
      InputMemoryStream(bytes),
      verify: true,
      files: false,
      filenameEncoding: utf8,
    )) {
      if (entries.length >= maximumEntries) {
        throw const FormatException('JAR entry count exceeds 2048');
      }
      if (directory.filePosition != end.offset ||
          directory.centralDirectoryOffset != end.start ||
          directory.centralDirectorySize != end.size) {
        throw const FormatException('JAR central directory bounds disagree');
      }
      final name = header.filename;
      if (!JarManifest.isArchivePath(name, directory: name.endsWith('/')) ||
          !names.add(name)) {
        throw const FormatException('Invalid or duplicate JAR entry path');
      }
      if (header.diskNumberStart != 0 ||
          header.compressedSize < 0 ||
          header.uncompressedSize < 0 ||
          header.localHeaderOffset < 0) {
        throw const FormatException('Invalid JAR entry bounds');
      }
      if ((header.generalPurposeBitFlag & ~0x080e) != 0 ||
          ![0, 8].contains(header.compressionMethod)) {
        throw const FormatException('Encrypted or unsupported JAR entry');
      }
      // No ZIP64 is needed under our archive/entry limits. Reject it explicitly.
      _checkExtra(header.extraField);
      final mode = (header.externalFileAttributes >> 16) & 0xf000;
      if (mode != 0 && mode != 0x8000 && mode != 0x4000) {
        throw const FormatException('Special JAR filesystem entry');
      }
      if (header.uncompressedSize > maximumEntryBytes) {
        throw const FormatException('JAR entry exceeds 8 MiB expanded limit');
      }
      declaredTotal += header.uncompressedSize;
      if (declaredTotal > maximumExpandedBytes) {
        throw const FormatException('JAR exceeds 32 MiB total expanded limit');
      }
      entries.add(header);
    }
    if (entries.length != end.count ||
        directory.filePosition != end.offset ||
        directory.centralDirectoryOffset != end.start) {
      throw const FormatException('JAR central directory is incomplete');
    }

    // Central-directory offsets, not local-header walking, define entry data.
    // Forbid overlaps/aliasing even when each individual slice looks in bounds.
    entries.sort((a, b) => a.localHeaderOffset.compareTo(b.localHeaderOffset));
    var lastEnd = 0;
    var actualTotal = 0;
    var hasDex = false;
    final texts = <String, String>{};
    for (final header in entries) {
      if (header.localHeaderOffset < lastEnd) {
        throw const FormatException('Overlapping JAR entry data');
      }
      final data = _entryBounds(view, header, end.start);
      lastEnd = data.end;
      final output = _BoundedOutput(header.uncompressedSize);
      final payload = Uint8List.sublistView(bytes, data.start, data.stop);
      if (header.compressionMethod == 0) {
        output.writeBytes(payload);
      } else {
        // archive's portable lazy inflater checks the final block, unlike native
        // raw inflate which can accept a cut stream. Our output enforces limits
        // at each literal/back-reference/write, before allocating expanded data.
        final inflate = Inflate.lazy(
          InputMemoryStream(payload),
          output: output,
        );
        while (inflate.inflateBlock()) {}
        if (!inflate.isFinished) {
          throw const FormatException('Truncated JAR deflate stream');
        }
      }
      final content = output.getBytes();
      if (content.length != header.uncompressedSize) {
        throw const FormatException('JAR expanded size mismatch');
      }
      actualTotal += content.length;
      if (actualTotal > maximumExpandedBytes) {
        throw const FormatException('JAR exceeds 32 MiB actual expanded limit');
      }
      if (getCrc32(content) != header.crc32) {
        throw FormatException('JAR CRC mismatch: ${header.filename}');
      }
      final name = header.filename;
      if (name.endsWith('/')) {
        if (content.isNotEmpty) {
          throw const FormatException('JAR directory contains file data');
        }
        continue;
      }
      hasDex |= name.toLowerCase().endsWith('.dex');
      if (name == JarManifest.path || name == 'spider.json') {
        if (content.length > maximumDescriptorBytes) {
          throw const FormatException('JAR descriptor exceeds 1 MiB limit');
        }
        texts[name] = utf8.decode(content);
      } else if (name.toLowerCase().endsWith('.js') &&
          content.length <= maximumJsBytes) {
        // Only manifests select execution candidates; remembering bounded text
        // here does not imply any script is an executable spider.
        texts[name] = utf8.decode(content, allowMalformed: true);
      }
    }

    Map<String, dynamic>? parsedDescriptor;
    final descriptor = texts['spider.json'];
    if (descriptor != null) {
      final parsed = jsonDecode(descriptor);
      if (parsed is! Map<String, dynamic>) {
        throw const FormatException('JAR spider.json must be an object');
      }
      parsedDescriptor = Map.unmodifiable(parsed);
    }
    JarManifest? manifest;
    final manifestText = texts[JarManifest.path];
    if (manifestText != null) {
      manifest = JarManifest.parse(manifestText);
    } else if (parsedDescriptor != null &&
        parsedDescriptor.containsKey('spiders')) {
      manifest = JarManifest.fromJson(parsedDescriptor);
    }
    if (manifest != null) {
      // Broken mappings are a descriptor error, including mappings for another
      // site: never quietly execute a default script instead.
      for (final path in manifest.spiders.values) {
        if (!names.contains(path)) {
          throw FormatException('JAR manifest entry is missing: $path');
        }
        if (!texts.containsKey(path)) {
          throw FormatException('JAR JavaScript entry exceeds 4 MiB: $path');
        }
      }
    }
    final entry = manifest != null
        ? (spider == null ? null : manifest.entryFor(spider))
        : (names.contains('spider.js') ? 'spider.js' : null);
    if (entry != null && !texts.containsKey(entry)) {
      throw const FormatException('JAR JavaScript entry exceeds 4 MiB limit');
    }
    final source = entry == null ? null : texts[entry];
    return JarInspection(
      hasDex: hasDex,
      embeddedJs: source == null || source.trim().isEmpty
          ? null
          : _stripSourceMapping(source),
      descriptor: descriptor,
      parsedDescriptor: parsedDescriptor,
      manifest: manifest,
      selectedEntry: entry,
    );
  }

  static ({int offset, int start, int size, int count}) _directoryBounds(
    ByteData view,
  ) {
    final length = view.lengthInBytes;
    if (length < 22) throw const FormatException('JAR end record is missing');
    final first = length > 65557 ? length - 65557 : 0;
    for (var at = length - 22; at >= first; at--) {
      if (view.getUint32(at, Endian.little) != 0x06054b50 ||
          at + 22 + view.getUint16(at + 20, Endian.little) != length) {
        continue;
      }
      final count = view.getUint16(at + 10, Endian.little);
      final size = view.getUint32(at + 12, Endian.little);
      final start = view.getUint32(at + 16, Endian.little);
      if (view.getUint16(at + 4, Endian.little) != 0 ||
          view.getUint16(at + 6, Endian.little) != 0 ||
          view.getUint16(at + 8, Endian.little) != count ||
          count == 0xffff ||
          start == 0xffffffff ||
          size == 0xffffffff) {
        throw const FormatException('Multi-disk/ZIP64 JAR is unsupported');
      }
      if (count > maximumEntries) {
        throw const FormatException('JAR entry count exceeds 2048');
      }
      if (start > at || size != at - start || count * 46 > size) {
        throw const FormatException('JAR central directory is truncated');
      }
      return (offset: at, start: start, size: size, count: count);
    }
    throw const FormatException('JAR end record is missing or truncated');
  }

  static ({int start, int stop, int end}) _entryBounds(
    ByteData view,
    ZipFileHeader header,
    int directoryStart,
  ) {
    final at = header.localHeaderOffset;
    if (at > directoryStart - 30 ||
        view.getUint32(at, Endian.little) != 0x04034b50) {
      throw const FormatException('JAR local header is truncated');
    }
    final flags = view.getUint16(at + 6, Endian.little);
    final method = view.getUint16(at + 8, Endian.little);
    final nameLength = view.getUint16(at + 26, Endian.little);
    final extraLength = view.getUint16(at + 28, Endian.little);
    final nameStart = at + 30;
    final start = nameStart + nameLength + extraLength;
    final stop = start + header.compressedSize;
    if (start > directoryStart || stop > directoryStart) {
      throw const FormatException('JAR entry data is truncated');
    }
    final bytes = view.buffer.asUint8List(
      view.offsetInBytes,
      view.lengthInBytes,
    );
    final localName = utf8.decode(
      Uint8List.sublistView(bytes, nameStart, nameStart + nameLength),
    );
    if (flags != header.generalPurposeBitFlag ||
        method != header.compressionMethod ||
        localName != header.filename) {
      throw const FormatException('JAR local/central headers disagree');
    }
    _checkExtra(Uint8List.sublistView(bytes, nameStart + nameLength, start));
    if (method == 0 && header.compressedSize != header.uncompressedSize) {
      throw const FormatException('Stored JAR entry size mismatch');
    }
    final crc = view.getUint32(at + 14, Endian.little);
    final compressed = view.getUint32(at + 18, Endian.little);
    final expanded = view.getUint32(at + 22, Endian.little);
    if (flags & 8 == 0) {
      if (crc != header.crc32 ||
          compressed != header.compressedSize ||
          expanded != header.uncompressedSize) {
        throw const FormatException('JAR local size/CRC disagrees');
      }
      return (start: start, stop: stop, end: stop);
    }
    if ((crc != 0 && crc != header.crc32) ||
        (compressed != 0 && compressed != header.compressedSize) ||
        (expanded != 0 && expanded != header.uncompressedSize)) {
      throw const FormatException('JAR streamed local size/CRC disagrees');
    }
    // The data descriptor is parsed, not skipped by scanning for a signature.
    // Signatureless descriptors are valid even if their CRC is 0x08074b50.
    bool matches(int offset) =>
        offset <= directoryStart - 12 &&
        view.getUint32(offset, Endian.little) == header.crc32 &&
        view.getUint32(offset + 4, Endian.little) == header.compressedSize &&
        view.getUint32(offset + 8, Endian.little) == header.uncompressedSize;
    if (matches(stop)) return (start: start, stop: stop, end: stop + 12);
    if (stop <= directoryStart - 16 &&
        view.getUint32(stop, Endian.little) == 0x08074b50 &&
        matches(stop + 4)) {
      return (start: start, stop: stop, end: stop + 16);
    }
    throw const FormatException(
      'JAR data descriptor is truncated or mismatched',
    );
  }

  static void _checkExtra(Uint8List? extra) {
    if (extra == null) return;
    final view = ByteData.sublistView(extra);
    var at = 0;
    while (at < extra.length) {
      if (at + 4 > extra.length) {
        throw const FormatException('Truncated JAR extra field');
      }
      final id = view.getUint16(at, Endian.little);
      final size = view.getUint16(at + 2, Endian.little);
      if (id == 1 || at + 4 + size > extra.length) {
        throw const FormatException('ZIP64 or truncated JAR extra field');
      }
      at += 4 + size;
    }
  }

  static String _stripSourceMapping(String source) =>
      source.replaceAll(RegExp(r'//[#@]\s*sourceMappingURL=\S+'), '');
}

/// Enforces the declared, pre-checked expanded size before every allocation.
/// With Inflate.lazy the decoder uses this stream directly, including LZ77
/// back-references, so a lying central-directory size cannot inflate unboundedly.
class _BoundedOutput extends OutputMemoryStream {
  _BoundedOutput(this.limit) : super(size: limit < 1024 ? limit : 1024);
  final int limit;

  void _check(int count) {
    if (count < 0 || count > limit - length) {
      throw const JarInspectError(
        'JAR actual expanded data exceeds entry limit',
      );
    }
  }

  @override
  void reserve(int total) {
    _check(total > length ? total - length : 0);
    super.reserve(total);
  }

  @override
  void writeByte(int value) {
    _check(1);
    super.writeByte(value);
  }

  @override
  void writeBytes(List<int> bytes, {int? length}) {
    _check(length ?? bytes.length);
    super.writeBytes(bytes, length: length);
  }

  @override
  void writeStream(InputStream stream) {
    _check(stream.length);
    super.writeStream(stream);
  }

  @override
  void writeBackReference(int distance, int count) {
    _check(count);
    super.writeBackReference(distance, count);
  }
}

class JarInspectError implements Exception {
  const JarInspectError(this.message);
  final String message;
  @override
  String toString() => 'JarInspectError: $message';
}
