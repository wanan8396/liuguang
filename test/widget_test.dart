import 'package:flutter_test/flutter_test.dart';
import 'package:tvbox/core/models/models.dart';

void main() {
  test('站点执行类型不等同于可播放状态', () {
    expect(Site({'key': 'a', 'type': 3, 'api': 'csp_Test'}).runtime, 'jar');
    expect(Site({'key': 'b', 'type': 3, 'api': './drpy2.js'}).runtime, 'js');
    expect(
      Site({'key': 'c', 'type': 4, 'api': 'https://test.invalid/api'}).runtime,
      'remote',
    );
    expect(Site({'key': 'd', 'type': 1}).runtime, 'cms');
    expect(Site({'key': 'e', 'type': 3, 'api': 'custom'}).runtime, 'unknown');
  });

  test('多线路选集只按首个美元符号拆开名称和地址', () {
    final detail = VodDetail.fromVod(
      Vod({
        'vod_id': '42',
        'vod_name': '测试节目',
        'vod_play_from': r'线路一$$$线路二',
        'vod_play_url':
            r'第一集$https://video.invalid/1.m3u8?token=a$b#第二集$opaque-id$$$正片$https://video.invalid/film.mp4',
      }),
    );
    expect(detail.lines.length, 2);
    expect(detail.lines.first.episodes.length, 2);
    expect(
      detail.lines.first.episodes.first.id,
      r'https://video.invalid/1.m3u8?token=a$b',
    );
    expect(detail.lines.last.episodes.single.name, '正片');
  });

  test('收藏键包含仓库及站点，跨仓同ID不能互相覆盖', () {
    final vod = Vod({'vod_id': '1', 'vod_name': '测试'});
    final first = LibraryEntry(
      configUrl: 'https://a.invalid/',
      siteKey: 'same',
      vod: vod,
    );
    final second = LibraryEntry(
      configUrl: 'https://b.invalid/',
      siteKey: 'same',
      vod: vod,
    );
    expect(first.key, isNot(second.key));
    expect(LibraryEntry.fromJson(first.toJson()).key, first.key);
  });

  test('播放返回保留请求头和解析标记', () {
    final result = Playback.fromJson({
      'url': 'https://example.invalid/page',
      'parse': '1',
      'header': '{"User-Agent":"test","Referer":"https://example.invalid/"}',
    });
    expect(result.parse, isTrue);
    expect(result.headers['User-Agent'], 'test');
  });

  test('仓库导入状态可持久化且错误节点不伪造配置', () {
    final result = ImportResult(
      url: 'https://example.invalid/index',
      nodes: [
        RepoNode(
          url: 'https://example.invalid/missing',
          name: '缺失',
          status: 'error',
          error: 'HTTP 404',
        ),
        RepoNode(
          url: 'https://example.invalid/config',
          name: '单仓',
          status: 'ready',
          config: TvConfig(
            url: 'https://example.invalid/config',
            name: '单仓',
            raw: {
              'sites': [
                {
                  'key': 's',
                  'api': 'csp_Test',
                  'type': 3,
                  'ext': {
                    'nested': ['a', 'b'],
                  },
                },
              ],
            },
          ),
        ),
      ],
    );
    final restored = ImportResult.fromJson(result.toJson());
    expect(restored.nodes.length, 2);
    expect(restored.configs.length, 1);
    expect(restored.nodes.first.error, 'HTTP 404');
    expect(restored.configs.single.sites.single.ext, {
      'nested': ['a', 'b'],
    });
  });
}
