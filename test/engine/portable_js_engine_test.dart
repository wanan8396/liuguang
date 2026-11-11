import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:tvbox/core/engine/source_engine.dart';
import 'package:tvbox/core/models/models.dart';
import 'package:tvbox/core/network/app_http_client.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  // This suite intentionally exercises only a loopback fixture, not live sites.
  HttpOverrides.global = null;
  final supported = Platform.isWindows || Platform.isMacOS;
  late HttpServer origin;
  late AppHttpClient http;
  late SourceEngine engine;
  late String base;
  late TvConfig config;

  setUp(() async {
    if (!supported) return;
    origin = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    base = 'http://127.0.0.1:${origin.port}';
    origin.listen((request) async {
      if (request.uri.path == '/redirect') {
        request.response.statusCode = 302;
        request.response.headers.set('Location', '$base/data');
      } else if (request.uri.path == '/post') {
        final body = await utf8.decoder.bind(request).join();
        request.response.write(
          jsonEncode({'method': request.method, 'body': body}),
        );
      } else {
        request.response.headers.contentType = ContentType.json;
        request.response.write(
          jsonEncode({
            'list': [
              {
                'vod_id': '1',
                'vod_name': '测试影片',
                'vod_pic': '$base/1.jpg',
                'vod_remarks': '完结',
              },
            ],
          }),
        );
      }
      await request.response.close();
    });
    http = AppHttpClient();
    engine = SourceEngine(http, isAndroid: false);
    config = TvConfig(url: '$base/config.json', name: 'fixture', raw: const {});
  });
  tearDown(() async {
    if (!supported) return;
    await engine.dispose();
    http.close();
    await origin.close(force: true);
  });

  test(
    'portable single-file spider: HTTP, HTML, crypto, detail, play and proxy',
    () async {
      final site = Site({
        'key': 'module',
        'type': 3,
        'api': '$base/source.js',
        '_jsSource':
            '''
// export default example -- comments must remain untouched.
export default {
  init(){local.set('test','key','已初始化');},
  home(){
    let recovered=false;
    try { req('file:///fixture-network-error'); } catch(error) { recovered=true; }
    if(!recovered) throw Error('JS network fallback failed');
    const value = req('$base/redirect');
    if(value.code!==200 || !value.url.endsWith('/data')) throw Error('redirect failed');
    if(local.get('test','key')!=='已初始化') throw Error('local failed');
    if(md5('abc')!=='900150983cd24fb0d6963f7d28e17f72') throw Error('crypto failed');
    if(base64Decode(base64Encode('中文'))!=='中文') throw Error('base64 failed');
    const html='<div><a href="/1">  影片一 </a><a href="/2">影片二</a></div>';
    if(pdfa(html,'div&&a').length!==2) throw Error('pdfa failed');
    if(pdfh(html,'a:eq(1)&&Text')!=='影片二') throw Error('pdfh failed');
    if(pd(html,'a&&href','$base/')!=='$base/1') throw Error('pd failed');
    return {class:[{type_id:'1',type_name:'电影'}],list:JSON.parse(value.content).list};
  },
  category(tid,pg,filter,extend){return {page:pg,list:[{vod_id:tid,vod_name:extend.label}]};},
  search(wd,quick,pg){
    const r=JSON.parse(req('$base/post',{method:'POST',data:{wd:wd},postType:'form'}).content);
    if(r.method!=='POST'||r.body!=='wd=hello')throw Error('POST failed');
    return {page:pg,list:[{vod_id:wd,vod_name:'搜索'}]};
  },
  detail(id){return {list:[{vod_id:id,vod_name:'详情',vod_play_from:'line',vod_play_url:'正片\u0024https://media.invalid/video.mp4'}]};},
  play(flag,id){return {parse:0,url:id==='proxy'?getProxy()+'action=test':id,header:{Referer:'$base/'}};},
  proxy(params){return [200,'text/plain','代理正文',{},0];}
};
''',
      });
      expect((await engine.home(config, site)).items.single.name, '测试影片');
      final category = await engine.category(
        config,
        site,
        '2',
        page: 3,
        filters: {'label': '分类'},
      );
      expect(category.page, 3);
      expect(category.items.single.name, '分类');
      expect(
        (await engine.search(config, site, 'hello')).items.single.id,
        'hello',
      );
      final detail = await engine.detail(config, site, '1');
      expect(
        detail.lines.single.episodes.single.id,
        'https://media.invalid/video.mp4',
      );
      final playback = await engine.play(
        config,
        site,
        'line',
        'https://media.invalid/video.mp4',
      );
      expect(playback.parse, false);
      expect(playback.headers['Referer'], '$base/');
      final proxy = await engine.play(config, site, 'line', 'proxy');
      expect(utf8.decode((await http.fetch(proxy.url)).bytes), '代理正文');
    },
    skip: !supported,
  );

  test(
    'traditional drpy source uses real network and bundled JSON selectors',
    () async {
      final site = Site({
        'key': 'rule',
        'type': 3,
        'api': '$base/rule.js',
        '_jsSource':
            '''
var rule={title:'drpy fixture',host:'$base',homeUrl:'/data',url:'/data?tid=fyclass&pg=fypage',
class_name:'电影&剧集',class_url:'1&2',
推荐:'json:list;vod_name;vod_pic;vod_remarks;vod_id',
一级:'json:list;vod_name;vod_pic;vod_remarks;vod_id',
搜索:'json:list;vod_name;vod_pic;vod_remarks;vod_id',searchUrl:'/data?wd=**',
二级:'*',play_parse:false};
''',
      });
      final home = await engine.home(config, site);
      expect(home.categories.map((v) => v.name), ['电影', '剧集']);
      expect(home.items.single.name, '测试影片');
      expect(
        (await engine.category(config, site, '1')).items.single.name,
        '测试影片',
      );
      expect(
        (await engine.search(config, site, 'test')).items.single.name,
        '测试影片',
      );
    },
    skip: !supported,
  );

  test(
    'source errors surface and worker can be reopened after cancellation',
    () async {
      final bad = Site({
        'key': 'bad',
        'type': 3,
        'api': '$base/bad.js',
        '_jsSource':
            "export default {home(){throw Error('fixture failure');}};",
      });
      await expectLater(
        engine.home(config, bad),
        throwsA(isA<SourceFailure>()),
      );
      final good = Site({
        'key': 'good',
        'type': 3,
        'api': '$base/good.js',
        '_jsSource':
            "var __JS_SPIDER__={home(){return {class:[{type_id:'1',type_name:'test'}]}}};",
      });
      expect((await engine.home(config, good)).categories.single.name, 'test');
      await engine.cancel();
      expect((await engine.home(config, good)).categories.single.name, 'test');
    },
    skip: !supported,
  );
}
