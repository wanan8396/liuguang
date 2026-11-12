import 'dart:async';
import 'dart:convert';
import 'dart:io' show ZLibEncoder;
import 'dart:typed_data';

import 'package:archive/archive.dart' show getCrc32;
import 'package:crypto/crypto.dart' show md5;
import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:tvbox/core/engine/jar_compat.dart';
import 'package:tvbox/core/network/app_http_client.dart';

class _Entry {
  _Entry(
    this.name,
    String text, {
    this.deflate = false,
    this.descriptor = false,
    this.signedDescriptor = true,
    this.declaredSize,
    this.crc,
    this.flags = 0,
  }) : data = Uint8List.fromList(utf8.encode(text));
  final String name;
  final Uint8List data;
  final bool deflate;
  final bool descriptor;
  final bool signedDescriptor;
  final int? declaredSize;
  final int? crc;
  final int flags;
}

/// Self-created fixtures only: valid central directory, local headers, CRCs,
/// and optional signed/signatureless streaming data descriptors.
Uint8List _zip(List<_Entry> entries) {
  final out = BytesBuilder();
  final central = BytesBuilder();
  for (final entry in entries) {
    final name = utf8.encode(entry.name);
    final payload = entry.deflate
        ? ZLibEncoder(raw: true).convert(entry.data)
        : entry.data;
    final offset = out.length;
    final flags = 0x800 | entry.flags | (entry.descriptor ? 8 : 0);
    final crc = entry.crc ?? getCrc32(entry.data);
    final size = entry.declaredSize ?? entry.data.length;
    final local = ByteData(30)
      ..setUint32(0, 0x04034b50, Endian.little)
      ..setUint16(4, 20, Endian.little)
      ..setUint16(6, flags, Endian.little)
      ..setUint16(8, entry.deflate ? 8 : 0, Endian.little)
      ..setUint32(14, entry.descriptor ? 0 : crc, Endian.little)
      ..setUint32(18, entry.descriptor ? 0 : payload.length, Endian.little)
      ..setUint32(22, entry.descriptor ? 0 : size, Endian.little)
      ..setUint16(26, name.length, Endian.little);
    out
      ..add(local.buffer.asUint8List())
      ..add(name)
      ..add(payload);
    if (entry.descriptor) {
      final descriptor = ByteData(entry.signedDescriptor ? 16 : 12);
      final at = entry.signedDescriptor ? 4 : 0;
      if (entry.signedDescriptor) {
        descriptor.setUint32(0, 0x08074b50, Endian.little);
      }
      descriptor
        ..setUint32(at, crc, Endian.little)
        ..setUint32(at + 4, payload.length, Endian.little)
        ..setUint32(at + 8, size, Endian.little);
      out.add(descriptor.buffer.asUint8List());
    }
    final header = ByteData(46)
      ..setUint32(0, 0x02014b50, Endian.little)
      ..setUint16(4, 20, Endian.little)
      ..setUint16(6, 20, Endian.little)
      ..setUint16(8, flags, Endian.little)
      ..setUint16(10, entry.deflate ? 8 : 0, Endian.little)
      ..setUint32(16, crc, Endian.little)
      ..setUint32(20, payload.length, Endian.little)
      ..setUint32(24, size, Endian.little)
      ..setUint16(28, name.length, Endian.little)
      ..setUint32(42, offset, Endian.little);
    central
      ..add(header.buffer.asUint8List())
      ..add(name);
  }
  final start = out.length;
  final centralBytes = central.takeBytes();
  final end = ByteData(22)
    ..setUint32(0, 0x06054b50, Endian.little)
    ..setUint16(8, entries.length, Endian.little)
    ..setUint16(10, entries.length, Endian.little)
    ..setUint32(12, centralBytes.length, Endian.little)
    ..setUint32(16, start, Endian.little);
  return (out
        ..add(centralBytes)
        ..add(end.buffer.asUint8List()))
      .takeBytes();
}

int _centralStart(Uint8List bytes) =>
    ByteData.sublistView(bytes).getUint32(bytes.length - 6, Endian.little);

String _manifest(Map<String, String> spiders) => jsonEncode({
  'version': 1,
  'spiders': spiders.map((api, entry) => MapEntry(api, {'entry': entry})),
});

Matcher _error([String? message]) => throwsA(
  message == null
      ? isA<JarInspectError>()
      : isA<JarInspectError>().having(
          (error) => error.message,
          'message',
          contains(message),
        ),
);

class _Adapter implements HttpClientAdapter {
  _Adapter(this.bytes);
  final Uint8List bytes;
  RequestOptions? request;
  @override
  Future<ResponseBody> fetch(
    RequestOptions options,
    Stream<Uint8List>? requestStream,
    Future<void>? cancelFuture,
  ) async {
    request = options;
    return ResponseBody.fromBytes(bytes, 200);
  }

  @override
  void close({bool force = false}) {}
}

void main() {
  group('portable JAR bounded ZIP reader', () {
    for (final deflate in [false, true]) {
      for (final descriptor in [false, true]) {
        test(
          'reads deflated=$deflate streamed=$descriptor with central CRC',
          () {
            final jar = _zip([
              _Entry('classes.dex', 'dex\n035\u0000', deflate: deflate),
              _Entry(
                'spider.js',
                "var rule={title:'fixture'};\n//# sourceMappingURL=private.map",
                deflate: deflate,
                descriptor: descriptor,
              ),
            ]);
            final result = JarCompat.inspectBytes(jar, spider: 'csp_Fixture');
            expect(result.hasDex, isTrue);
            expect(result.isRunnable, isTrue);
            expect(result.requiresAndroid, isFalse);
            expect(result.selectedEntry, 'spider.js');
            expect(result.embeddedJs, contains("title:'fixture'"));
            expect(result.embeddedJs, isNot(contains('private.map')));
          },
        );
      }
    }

    test('reads signatureless data descriptors followed by another entry', () {
      final result = JarCompat.inspectBytes(
        _zip([
          _Entry(
            'spider.js',
            'var rule={};',
            deflate: true,
            descriptor: true,
            signedDescriptor: false,
          ),
          _Entry('classes2.dex', 'dex'),
        ]),
      );
      expect(result.isRunnable, isTrue);
      expect(result.hasDex, isTrue);
    });

    test('rejects CRC corruption in selected or unrelated entries', () {
      for (final name in ['spider.js', 'library.bin']) {
        expect(
          () => JarCompat.inspectBytes(_zip([_Entry(name, 'fixture', crc: 0)])),
          _error('CRC'),
        );
      }
    });

    test('parses descriptors and rejects descriptor CRC/size disagreement', () {
      for (final field in [4, 8, 12]) {
        final jar = _zip([
          _Entry('spider.js', 'var rule={};', descriptor: true),
        ]);
        final position = _centralStart(jar) - 16;
        final view = ByteData.sublistView(jar);
        view.setUint32(position + field, 123, Endian.little);
        expect(() => JarCompat.inspectBytes(jar), _error('descriptor'));
      }
    });

    test(
      'rejects local-only archives and every truncated central structure',
      () {
        final jar = _zip([_Entry('spider.js', 'var rule={};', deflate: true)]);
        for (final cut in [1, 5, 21, 22, 40]) {
          expect(
            () => JarCompat.inspectBytes(
              Uint8List.sublistView(jar, 0, jar.length - cut),
            ),
            _error(),
          );
        }
        expect(
          () => JarCompat.inspectBytes(
            Uint8List.sublistView(jar, 0, _centralStart(jar)),
          ),
          _error(),
        );
      },
    );

    test('rejects entry size, local offset, name and method disagreement', () {
      for (final field in [20, 42]) {
        final jar = _zip([_Entry('spider.js', 'var rule={};')]);
        ByteData.sublistView(
          jar,
        ).setUint32(_centralStart(jar) + field, 0xffffff, Endian.little);
        expect(() => JarCompat.inspectBytes(jar), _error());
      }
      for (final field in [8, 30]) {
        final jar = _zip([_Entry('spider.js', 'var rule={};')]);
        jar[field] ^= 1;
        expect(() => JarCompat.inspectBytes(jar), _error());
      }
    });

    test(
      'rejects truncated final deflate block even with matching output CRC',
      () {
        final jar = _zip([_Entry('spider.js', 'var rule={};', deflate: true)]);
        final central = _centralStart(jar);
        final view = ByteData.sublistView(jar);
        final compressed = view.getUint32(18, Endian.little);
        // Remove the final compressed byte but retain a valid central directory.
        final cut = central - 1;
        final changed = Uint8List(jar.length - 1)
          ..setRange(0, cut, jar)
          ..setRange(cut, jar.length - 1, jar, cut + 1);
        final data = ByteData.sublistView(changed);
        data
          ..setUint32(18, compressed - 1, Endian.little)
          ..setUint32(central - 1 + 20, compressed - 1, Endian.little)
          ..setUint32(changed.length - 6, central - 1, Endian.little);
        expect(() => JarCompat.inspectBytes(changed), _error());
      },
    );

    test('rejects truncated stored data and data descriptor bytes', () {
      for (final descriptor in [false, true]) {
        final jar = _zip([
          _Entry('spider.js', 'var rule={};', descriptor: descriptor),
        ]);
        final central = _centralStart(jar);
        final cut = central - (descriptor ? 8 : 1);
        final changed = Uint8List(jar.length - 1)
          ..setRange(0, cut, jar)
          ..setRange(cut, jar.length - 1, jar, cut + 1);
        ByteData.sublistView(
          changed,
        ).setUint32(changed.length - 6, central - 1, Endian.little);
        expect(() => JarCompat.inspectBytes(changed), _error());
      }
    });

    test(
      'accepts central-directory order independent of local entry order',
      () {
        final jar = _zip([
          _Entry('spider.js', 'var rule={};'),
          _Entry('data.txt', 'text'),
        ]);
        final central = _centralStart(jar);
        final middle = central + 46 + 'spider.js'.length;
        final end = jar.length - 22;
        final reordered = Uint8List.fromList(jar)
          ..setRange(central, central + end - middle, jar, middle)
          ..setRange(central + end - middle, end, jar, central);
        expect(JarCompat.inspectBytes(reordered).isRunnable, isTrue);
      },
    );

    test(
      'rejects duplicate paths, traversal, encryption and overlapping data',
      () {
        expect(
          () => JarCompat.inspectBytes(
            _zip([_Entry('spider.js', 'a'), _Entry('spider.js', 'b')]),
          ),
          _error('duplicate'),
        );
        for (final path in [
          '../spider.js',
          '/spider.js',
          r'a\spider.js',
          'a/../spider.js',
        ]) {
          expect(
            () => JarCompat.inspectBytes(_zip([_Entry(path, 'a')])),
            _error(),
          );
        }
        expect(
          () => JarCompat.inspectBytes(
            _zip([_Entry('spider.js', 'a', flags: 1)]),
          ),
          _error('Encrypted'),
        );
        final overlap = _zip([_Entry('a.js', 'x'), _Entry('b.js', 'x')]);
        final second = _centralStart(overlap) + 46 + 'a.js'.length;
        ByteData.sublistView(overlap).setUint32(second + 42, 0, Endian.little);
        expect(() => JarCompat.inspectBytes(overlap), _error('Overlapping'));
      },
    );

    test(
      'enforces archive bytes, entry count, entry and total expanded limits',
      () {
        expect(
          () => JarCompat.inspectBytes(Uint8List(JarCompat.maximumBytes + 1)),
          _error('8 MiB archive'),
        );
        expect(
          () => JarCompat.inspectBytes(
            _zip(
              List.generate(
                JarCompat.maximumEntries + 1,
                (i) => _Entry('$i', ''),
              ),
            ),
          ),
          _error('2048'),
        );
        expect(
          () => JarCompat.inspectBytes(
            _zip([
              _Entry(
                'bomb',
                '',
                deflate: true,
                declaredSize: JarCompat.maximumEntryBytes + 1,
              ),
            ]),
          ),
          _error('8 MiB expanded'),
        );
        expect(
          () => JarCompat.inspectBytes(
            _zip(
              List.generate(
                5,
                (i) => _Entry(
                  '$i',
                  '',
                  deflate: true,
                  declaredSize: JarCompat.maximumEntryBytes,
                ),
              ),
            ),
          ),
          _error('32 MiB total'),
        );
      },
    );

    test('stops actual inflate when central size is forged small', () {
      final jar = _zip([
        _Entry(
          'spider.js',
          'x' * (256 * 1024),
          deflate: true,
          declaredSize: 64,
        ),
      ]);
      expect(jar.length, lessThan(2048));
      expect(() => JarCompat.inspectBytes(jar), _error('actual expanded'));
    });

    test(
      'enforces selected JS and descriptor byte limits without truncating',
      () {
        expect(
          () => JarCompat.inspectBytes(
            _zip([
              _Entry(
                'spider.js',
                'x' * (JarCompat.maximumJsBytes + 1),
                deflate: true,
              ),
            ]),
          ),
          _error('4 MiB'),
        );
        expect(
          () => JarCompat.inspectBytes(
            _zip([
              _Entry(
                'spider.json',
                ' ' * (JarCompat.maximumDescriptorBytes + 1),
                deflate: true,
              ),
            ]),
          ),
          _error('1 MiB'),
        );
      },
    );

    test('distinguishes pure DEX, no-JS and empty archives', () {
      final dex = JarCompat.inspectBytes(_zip([_Entry('classes.dex', 'dex')]));
      expect(dex.requiresAndroid, isTrue);
      expect(dex.isRunnable, isFalse);
      final noJs = JarCompat.inspectBytes(_zip([_Entry('readme.txt', 'text')]));
      expect(noJs.requiresAndroid, isFalse);
      expect(noJs.hasDex, isFalse);
      expect(noJs.isRunnable, isFalse);
      expect(JarCompat.inspectBytes(_zip([])).isRunnable, isFalse);
    });
  });

  group('portable JAR manifest selector', () {
    test(
      'selects exact per-site API, independent of library/ZIP entry order',
      () {
        final jar = _zip([
          _Entry('lib/first.js', 'throw "library";'),
          _Entry('spider.js', 'throw "default";'),
          _Entry(
            JarManifest.path,
            _manifest({'csp_A': 'spiders/a.js', 'csp_B': 'spiders/b.js'}),
          ),
          _Entry('spiders/b.js', 'var rule={title:"B"};', deflate: true),
          _Entry('spiders/a.js', 'var rule={title:"A"};'),
        ]);
        final a = JarCompat.inspectBytes(jar, spider: 'csp_A');
        final b = JarCompat.inspectBytes(jar, spider: 'csp_B');
        expect(a.selectedEntry, 'spiders/a.js');
        expect(a.embeddedJs, contains('"A"'));
        expect(b.selectedEntry, 'spiders/b.js');
        expect(b.embeddedJs, contains('"B"'));
        for (final api in [null, 'csp_Unknown', 'A', 'csp_a']) {
          expect(JarCompat.inspectBytes(jar, spider: api).embeddedJs, isNull);
        }
      },
    );

    test('never treats an arbitrary JS/library or spider.json as a spider', () {
      final result = JarCompat.inspectBytes(
        _zip([
          _Entry('lib/library.js', 'var rule={};'),
          _Entry('nested/spider.js', 'var rule={};'),
          _Entry('Spider.js', 'var rule={};'),
          _Entry(
            'spider.json',
            '{"name":"metadata only","entry":"lib/library.js"}',
          ),
        ]),
        spider: 'csp_Fixture',
      );
      expect(result.embeddedJs, isNull);
      expect(result.parsedDescriptor?['name'], 'metadata only');
      expect(result.descriptor, contains('metadata only'));
      expect(result.manifest, isNull);
    });

    test('supports explicit versioned spider.json mappings', () {
      final result = JarCompat.inspectBytes(
        _zip([
          _Entry('spider.json', _manifest({'csp_Fixture': 'fixture.js'})),
          _Entry('fixture.js', 'var rule={};'),
        ]),
        spider: 'csp_Fixture',
      );
      expect(result.selectedEntry, 'fixture.js');
      expect(result.manifest?.entryFor('csp_Fixture'), 'fixture.js');
    });

    test('preferred manifest wins over spider.json mappings', () {
      final result = JarCompat.inspectBytes(
        _zip([
          _Entry(JarManifest.path, _manifest({'csp_Fixture': 'preferred.js'})),
          _Entry('spider.json', _manifest({'csp_Fixture': 'legacy.js'})),
          _Entry('preferred.js', 'preferred'),
          _Entry('legacy.js', 'legacy'),
        ]),
        spider: 'csp_Fixture',
      );
      expect(result.embeddedJs, 'preferred');
    });

    test(
      'rejects malformed descriptors instead of silently running a default',
      () {
        for (final descriptor in [
          'not json',
          '[]',
          '{"version":2,"spiders":{}}',
          '{"version":1,"spiders":{}}',
          '{"version":1,"spiders":{"csp_A":{"entry":"../x.js"}}}',
          '{"version":1,"spiders":{"csp_A":{"entry":"x.json"}}}',
          _manifest({'csp_A': 'missing.js'}),
        ]) {
          expect(
            () => JarCompat.inspectBytes(
              _zip([
                _Entry(JarManifest.path, descriptor),
                _Entry('spider.js', 'default'),
              ]),
            ),
            _error(),
          );
        }
        expect(
          () =>
              JarCompat.inspectBytes(_zip([_Entry('spider.json', 'not json')])),
          _error(),
        );
      },
    );

    test('empty mapped JS is not runnable', () {
      final result = JarCompat.inspectBytes(
        _zip([
          _Entry(JarManifest.path, _manifest({'csp_Fixture': 'empty.js'})),
          _Entry('empty.js', ' \n'),
        ]),
        spider: 'csp_Fixture',
      );
      expect(result.isRunnable, isFalse);
    });
  });

  group('portable JAR HTTP and checksum contract', () {
    test(
      'passes headers and selector and supports legacy call shape',
      () async {
        final adapter = _Adapter(_zip([_Entry('spider.js', 'var rule={};')]));
        final client = AppHttpClient(adapter: adapter);
        addTearDown(client.close);
        final result = await JarCompat(
          client,
        ).inspect('https://fixture.invalid/rules.jar', {'X-Fixture': 'yes'});
        expect(adapter.request?.headers['X-Fixture'], 'yes');
        expect(result.isRunnable, isTrue);
        expect(JarCompat.maximumBytes, client.maxBytes);
      },
    );

    test(
      'HTTP client may impose a tighter cap and reports a JAR error',
      () async {
        final client = AppHttpClient(
          adapter: _Adapter(_zip([_Entry('spider.js', 'var rule={};')])),
          maxBytes: 64,
        );
        addTearDown(client.close);
        await expectLater(
          JarCompat(client).inspect('https://fixture.invalid/rules.jar', {}),
          _error('JAR'),
        );
      },
    );

    test('retains the archive cap with a larger HTTP client limit', () async {
      for (final oversize in [false, true]) {
        final adapter = _Adapter(
          oversize
              ? Uint8List(JarCompat.maximumBytes + 1)
              : _zip([_Entry('spider.js', 'var rule={};')]),
        );
        final client = AppHttpClient(
          adapter: adapter,
          maxBytes: 16 * 1024 * 1024,
        );
        addTearDown(client.close);
        final future = JarCompat(
          client,
        ).inspect('https://fixture.invalid/rules.jar', {});
        if (oversize) {
          await expectLater(future, _error('8 MiB archive'));
        } else {
          expect((await future).isRunnable, isTrue);
        }
      }
    });

    test(
      'verifies expected MD5 and rejects malformed or mismatching values',
      () {
        final bytes = _zip([_Entry('spider.js', 'var rule={};')]);
        final digest = md5.convert(bytes).toString().toUpperCase();
        expect(
          JarCompat.inspectBytes(bytes, expectedMd5: digest).isRunnable,
          isTrue,
        );
        for (final expected in ['bad', '0' * 32]) {
          expect(
            () => JarCompat.inspectBytes(bytes, expectedMd5: expected),
            _error('MD5'),
          );
        }
      },
    );
  });
}
