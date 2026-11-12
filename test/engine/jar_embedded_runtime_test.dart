import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:archive/archive.dart';
import 'package:crypto/crypto.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:tvbox/core/engine/source_engine.dart';
import 'package:tvbox/core/models/models.dart';
import 'package:tvbox/core/network/app_http_client.dart';

Uint8List _archive(Map<String, String> files) {
  final archive = Archive();
  for (final file in files.entries) {
    archive.add(ArchiveFile.string(file.key, file.value));
  }
  return Uint8List.fromList(ZipEncoder().encode(archive));
}

String _spider(String identity) =>
    '''
export default {
  init(ext){this.label=ext.label;this.calls=0;},
  home(){this.calls++;return {
    class:[{type_id:'movie',type_name:'$identity 分类'}],
    list:[{vod_id:'$identity-home',vod_name:'$identity '+this.label+' '+this.calls}]
  };},
  category(tid,pg,filter,extend){return {page:pg,list:[
    {vod_id:tid,vod_name:'$identity '+extend.label+' '+this.label}
  ]};},
  detail(id){return {list:[{
    vod_id:id,vod_name:'$identity 详情',vod_play_from:'$identity line',
    vod_play_url:'正片\u0024https://media.invalid/$identity/movie.mp4'
  }]};},
  play(flag,id){return {parse:0,url:id,header:{'X-Spider':'$identity','X-Ext':this.label}};}
};
''';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  HttpOverrides.global = null;
  final supported = Platform.isWindows || Platform.isMacOS;
  late HttpServer origin;
  late AppHttpClient http;
  late SourceEngine engine;
  late String base;
  late Map<String, Uint8List> fixtures;
  late Map<String, int> hits;

  setUp(() async {
    if (!supported) return;
    origin = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    base = 'http://127.0.0.1:${origin.port}';
    fixtures = {};
    hits = {};
    origin.listen((request) async {
      final path = request.uri.path;
      hits[path] = (hits[path] ?? 0) + 1;
      final bytes = fixtures[path];
      if (bytes == null) {
        request.response.statusCode = 404;
      } else {
        request.response.headers.contentType = ContentType.binary;
        request.response.add(bytes);
      }
      await request.response.close();
    });
    http = AppHttpClient();
    engine = SourceEngine(http, isAndroid: false);
  });

  tearDown(() async {
    if (!supported) return;
    await engine.dispose();
    http.close();
    await origin.close(force: true);
  });

  test(
    'manifest csp_ selector runs real JS home/category/detail/play per site',
    () async {
      fixtures['/repo/rules.jar'] = _archive({
        'lib/first.js': 'throw Error("library must never execute");',
        'spider.js': 'throw Error("unselected default must never execute");',
        'classes.dex': 'dex fixture only',
        'META-INF/liuguang.json': jsonEncode({
          'version': 1,
          'spiders': {
            'csp_A': {'entry': 'spiders/a.js'},
            'csp_B': {'entry': 'spiders/b.js'},
          },
        }),
        'spiders/a.js': _spider('A'),
        'spiders/b.js': _spider('B'),
      });
      final config = TvConfig(
        url: '$base/repo/config.json',
        name: 'JAR fixture',
        raw: {
          'spider':
              'rules.jar;md5;${md5.convert(fixtures['/repo/rules.jar']!)}',
        },
      );
      for (final identity in ['A', 'B']) {
        final site = Site({
          'key': 'jar-$identity',
          'type': 3,
          'api': 'csp_$identity',
          'ext': {'label': '$identity-ext'},
        });
        final home = await engine.home(config, site);
        expect(home.categories.single.name, '$identity 分类');
        expect(home.items.single.name, '$identity $identity-ext 1');
        final category = await engine.category(
          config,
          site,
          'movie',
          page: 3,
          filters: {'label': '分类内容'},
        );
        expect(category.page, 3);
        expect(category.items.single.name, '$identity 分类内容 $identity-ext');
        final detail = await engine.detail(config, site, 'id-$identity');
        expect(detail.vod.name, '$identity 详情');
        expect(detail.lines.single.name, '$identity line');
        final episode = detail.lines.single.episodes.single;
        expect(episode.id, 'https://media.invalid/$identity/movie.mp4');
        final playback = await engine.play(
          config,
          site,
          detail.lines.single.name,
          episode.id,
        );
        expect(playback.parse, isFalse);
        expect(playback.url, episode.id);
        expect(playback.headers['X-Spider'], identity);
        expect(playback.headers['X-Ext'], '$identity-ext');
        // JAR inspection and the JS runtime are cached within one site.
        expect(
          (await engine.home(config, site)).items.single.name,
          '$identity $identity-ext 2',
        );
      }
      expect(hits, {'/repo/rules.jar': 2});
    },
    skip: !supported,
  );

  test(
    'site JAR wins over global JAR and exact spider.js remains compatible',
    () async {
      fixtures['/repo/own.jar'] = _archive({'spider.js': _spider('own')});
      final config = TvConfig(
        url: '$base/repo/config.json',
        name: 'fixture',
        raw: {'spider': 'missing-global.jar'},
      );
      final site = Site({
        'key': 'own',
        'api': 'csp_Own',
        'jar': 'own.jar',
        'ext': {'label': 'local'},
      });
      expect(
        (await engine.home(config, site)).items.single.name,
        'own local 1',
      );
      expect(hits, {'/repo/own.jar': 1});
    },
    skip: !supported,
  );

  test(
    'unknown csp_ mapping and pure DEX never execute an unrelated script',
    () async {
      fixtures['/repo/mapped.jar'] = _archive({
        'META-INF/liuguang.json': jsonEncode({
          'version': 1,
          'spiders': {
            'csp_A': {'entry': 'a.js'},
          },
        }),
        'a.js': 'throw Error("wrong mapping executed");',
        'spider.js': 'throw Error("default executed");',
      });
      fixtures['/repo/dex.jar'] = _archive({'classes.dex': 'dex fixture only'});
      final config = TvConfig(
        url: '$base/repo/config.json',
        name: 'fixture',
        raw: const {},
      );
      for (final jar in ['mapped.jar', 'dex.jar']) {
        await expectLater(
          engine.home(
            config,
            Site({'key': jar, 'api': 'csp_Unknown', 'jar': jar}),
          ),
          throwsA(
            isA<SourceFailure>().having(
              (error) => error.code,
              'code',
              'jar-android-required',
            ),
          ),
        );
      }
    },
    skip: !supported,
  );
}
