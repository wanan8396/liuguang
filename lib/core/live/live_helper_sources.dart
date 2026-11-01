/// Optional public playlist groups extracted from 接口助手 3.0.
/// Nothing is selected automatically. Proxy URLs are fallbacks, not extra lists.
class LiveHelperSource {
  const LiveHelperSource({
    required this.id,
    required this.name,
    required this.urls,
  });
  final String id;
  final String name;
  final List<String> urls;
  bool get hasProxy => urls.any((url) => Uri.parse(url).host == 'gh-proxy.com');
  String get description =>
      '${Uri.parse(urls.first).host} · 直连优先'
      '${hasProxy ? '；失败可经第三方 gh-proxy.com 代理' : ''}';
}

const liveHelperSettingKey = 'liveHelperSources';
const liveHelperHeaders = <String, String>{
  'User-Agent': 'okhttp/4.12.0',
  'Accept': '*/*',
  // Dio/IO negotiates and decompresses gzip; do not force Accept-Encoding.
};

const liveHelperSources = <LiveHelperSource>[
  LiveHelperSource(
    id: 'source-01',
    name: '高天流云 TXT',
    urls: [
      'https://raw.githubusercontent.com/gaotianliuyun/gao/master/list.txt',
      'https://gh-proxy.com/raw.githubusercontent.com/gaotianliuyun/gao/master/list.txt',
    ],
  ),
  LiveHelperSource(
    id: 'source-02',
    name: 'suxuang IPv4',
    urls: [
      'https://raw.githubusercontent.com/suxuang/myIPTV/main/ipv4.m3u',
      'https://gh-proxy.com/raw.githubusercontent.com/suxuang/myIPTV/main/ipv4.m3u',
    ],
  ),
  LiveHelperSource(
    id: 'source-03',
    name: 'vbskycn IPv4',
    urls: [
      'https://raw.githubusercontent.com/vbskycn/iptv/master/tv/iptv4.txt',
      'https://gh-proxy.com/raw.githubusercontent.com/vbskycn/iptv/master/tv/iptv4.txt',
    ],
  ),
  LiveHelperSource(
    id: 'source-04',
    name: 'iptv-org 中国流',
    urls: [
      'https://raw.githubusercontent.com/iptv-org/iptv/master/streams/cn.m3u',
      'https://gh-proxy.com/raw.githubusercontent.com/iptv-org/iptv/master/streams/cn.m3u',
    ],
  ),
  LiveHelperSource(
    id: 'source-05',
    name: 'Kimentanm APTV',
    urls: [
      'https://raw.githubusercontent.com/Kimentanm/aptv/master/m3u/iptv.m3u',
      'https://gh-proxy.com/raw.githubusercontent.com/Kimentanm/aptv/master/m3u/iptv.m3u',
    ],
  ),
  LiveHelperSource(
    id: 'source-06',
    name: 'CCSH IPTV',
    urls: [
      'https://raw.githubusercontent.com/CCSH/IPTV/master/live.m3u',
      'https://gh-proxy.com/raw.githubusercontent.com/CCSH/IPTV/master/live.m3u',
    ],
  ),
  LiveHelperSource(
    id: 'source-07',
    name: 'zipsoon 中国合集',
    urls: [
      'https://raw.githubusercontent.com/zipsoon/iptv-sources/master/cn_all.m3u8',
      'https://raw.githubusercontent.com/zipsoon/iptv-sources/master/cn_cctv.m3u8',
      'https://gh-proxy.com/raw.githubusercontent.com/zipsoon/iptv-sources/master/cn_all.m3u8',
      'https://gh-proxy.com/raw.githubusercontent.com/zipsoon/iptv-sources/master/cn_cctv.m3u8',
    ],
  ),
  LiveHelperSource(
    id: 'source-08',
    name: 'cs3306 合集',
    urls: [
      'https://raw.githubusercontent.com/cs3306/IPTV-Sources/main/data/output/iptv_collection.m3u',
      'https://gh-proxy.com/raw.githubusercontent.com/cs3306/IPTV-Sources/main/data/output/iptv_collection.m3u',
    ],
  ),
  LiveHelperSource(
    id: 'source-09',
    name: '直播电视 IPv4 M3U',
    urls: ['https://live.zbds.top/tv/iptv4.m3u'],
  ),
  LiveHelperSource(
    id: 'source-10',
    name: '直播电视 IPv4 TXT',
    urls: ['https://live.zbds.top/tv/iptv4.txt'],
  ),
  LiveHelperSource(
    id: 'source-11',
    name: '91直播 TXT',
    urls: ['https://91zhibo.net/iptv/live.txt'],
  ),
  LiveHelperSource(
    id: 'source-12',
    name: 'iptv-org 中国',
    urls: ['https://iptv-org.github.io/iptv/countries/cn.m3u'],
  ),
  LiveHelperSource(
    id: 'source-13',
    name: 'iptv-org 香港',
    urls: ['https://iptv-org.github.io/iptv/countries/hk.m3u'],
  ),
  LiveHelperSource(
    id: 'source-14',
    name: 'iptv-org 台湾',
    urls: ['https://iptv-org.github.io/iptv/countries/tw.m3u'],
  ),
  LiveHelperSource(
    id: 'source-15',
    name: 'iptv-org 澳门',
    urls: ['https://iptv-org.github.io/iptv/countries/mo.m3u'],
  ),
];

/// Ignore unknown IDs from backups and collapse duplicate imports.
List<String> liveHelperSelection(Iterable<String> ids) {
  final selected = ids.toSet();
  return [
    for (final source in liveHelperSources)
      if (selected.contains(source.id)) source.id,
  ];
}
