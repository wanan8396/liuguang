import 'dart:async';
import 'dart:convert';
import 'dart:io' show HandshakeException;
import 'dart:typed_data';

import 'package:dio/dio.dart';

import '../config/config_decoder.dart';
import '../models/models.dart';
import '../network/app_http_client.dart';

/// 常见影视仓配置线路的公开种子入口。
/// 这些只是「候选地址」，未经探测前不产生任何网络副作用。
const List<(String, String)> kSeedLines = [
  ('饭太硬', 'http://www.饭太硬.net/tv'),
  ('饭太硬top', 'http://饭太硬.top/tv'),
  ('饭太硬备用', 'http://www.饭太硬.com/tv'),
  ('摸鱼儿', 'http://我不是.摸鱼儿.com'),
  ('肥猫Panda', 'http://我不是.肥猫.love:63/接口禁止贩卖'),
  ('肥猫', 'http://肥猫.com'),
  ('肥猫live', 'http://肥猫.live'),
  ('神秘哥哥备用', 'http://fty.xxooo.cf/tv'),
  ('毒盒', 'https://毒盒.com/tv/'),
  ('动漫城', 'https://www.yingm.cc/dm/dm.json'),
  ('俊佬', 'http://home.jundie.top:81/top98.json'),
  ('欧歌', 'https://play.iptv365.org/欧歌/api.json'),
  ('小米', 'https://play.iptv365.org/小米/api.json'),
  ('4K云盘', 'https://9xi4o.tk/0725.json'),
  ('巧儿', 'http://pandown.pro/tvbox/tvbox.json'),
  ('胖虎', 'https://notabug.org/imbig66/tv-spider-man/raw/master/配置/0801.json'),
  ('传说', 'https://chuanshuo.77blog.cn/tv.json'),
  ('宝盒接口', 'http://宝盒接口.top'),
  ('高天流云', 'https://raw.githubusercontent.com/gaotianliuyun/gao/master/js.json'),
  ('多多聚合', 'https://raw.liucn.cc/box/dm.txt'),
  ('liucn-m', 'https://raw.liucn.cc/box/m.json'),
  ('gitee自建', 'https://gitee.com/lukei7/lib/raw/Luck/自建.json'),
  ('gitee-bls', 'https://gitee.com/blssss/jk/raw/api/bls.json'),
  ('gitee青龙', 'https://gitee.com/yiwu369/6758/raw/master/青龙/1.json'),
  ('dxawi', 'https://dxawi.github.io/0/0.json'),
  ('kjsc0310', 'https://kjsc0310.github.io/tvy/jk9.json'),
  ('猫技多仓', 'https://agit.ai/ddx/TVBox/raw/branch/master/d.json'),
  ('月光宝盒多仓', 'https://jihulab.com/ygbh1/box/-/raw/main/dcang/dc.json'),
  ('月光影视仓', 'https://jihulab.com/ygbh1/box/-/raw/main/dcang/ygbh.json'),
  ('宝盒多仓2', 'https://jihulab.com/ygbh1/box/-/raw/main/dcang/dc2.json'),
  ('宝盒max多仓', 'https://agit.ai/butterfly/md/raw/branch/master/zYGBHmax'),
  ('多多接口多仓', 'https://jihulab.com/duomv/apps/-/raw/main/fast.json'),
  ('多多多仓', 'https://jihulab.com/duomv/apps/-/raw/main/duo.json'),
  ('影视仓多仓-52bsj', 'http://52bsj.vip:98/xiaohu'),
  ('吾爱仓库', 'http://52bsj.vip:98/wuaihosue'),
  ('小胡软件多仓', 'https://agit.ai/xiaohu/tvbox/raw/branch/main/duocang'),
  ('云星日记仓库', 'https://itvbox.cc/可视TV/云星日记/仓库.json'),
  ('猎狼多仓', 'http://tvbox.lltv8.top'),
  ('多仓-134', 'http://134.122.170.64/dc.json'),
  ('春风影视', 'https://369936.xyz/web119'),
  ('欧哥仓', 'http://tv.nxog.top'),
  ('日后仓', 'http://rihou.cc:66/'),
  ('奇奇多仓', 'https://cn.kstore.space/download/2904/123.txt'),
  ('D佬魔改线路', 'https://download.kstore.space/download/2883/nzk/nzk0722.json'),
  ('蚂蚁线路', 'https://cn.kstore.space/download/2883/0110.txt'),
  ('青龙线路', 'https://6758.kstore.space/1.json'),
  ('fmys', 'http://fmys.top/fmys.json'),
  ('奇奇', 'http://z.qiqiv.cn/123'),
  ('kstore-wex', 'https://9280.kstore.space/wex.json'),
  ('qxys', 'https://7337.kstore.space/qxys/禁止传播.json'),
  ('weixine', 'https://weixine.net/ysc.json'),
  ('zzzzz-tv', 'https://zzzzz.tv/tv/ys.json'),
  ('zzzzz-svip', 'https://zzzzz.tv/tv/svip.json'),
  ('qiaoji8', 'http://cdn.qiaoji8.com/tvbox.json'),
  ('meowcf', 'https://freed.yuanhsing.cf/TVBox/meowcf.json'),
  ('hcr-MMM', 'https://agit.ai/hu/hcr/raw/branch/master/MMM.txt'),
  ('wds-223843', 'https://wds.ecsxs.com/223843.txt'),
];

/// 聚合站页面：从 HTML 正文里再抓一层配置地址。
const List<String> kDiscoveryPages = [
  'https://m.7xz.com/softs/43518.html',
  'https://www.9k9k.com/app/52116.html',
  'https://m.52pk.com/soft/37066zmfvyf.html',
  'https://m.niucoo.cn/app/14651.html',
  'https://shouyou.3dmgame.com/ios/532920.html',
  'https://m.7po.com/rj/11305.html',
  'https://flowus.cn/ahuage/share/0cee252a-9d5e-44bf-9603-67844b5dda2b',
  'https://flowus.cn/share/1f2076ff-183f-4263-a0a2-6234fb89dcf1',
  'https://jihulab.com/ygbh1/box/-/raw/main/dcang/dc2.json',
  'https://jihulab.com/ygbh1/box/-/raw/main/dcang/ygbh.json',
  'https://gitlab.com/ygbh1/666/-/raw/main/dcang/ygbh.json',
  'https://yydsys.top/duo',
  'https://xhdwc.tk/0',
  'https://pastebin.com/raw/5NHaxyGR',
  'https://agit.ai/Yoursmile7/TVBox/raw/branch/master/XC.json',
  'https://agit.ai/relax/adcc/raw/branch/master/tvbox.json',
  'https://codeberg.org/AK47/drpy-js/raw/branch/main/js.json',
  'https://raw.githubusercontent.com/FongMi/CatVodSpider/main/json/config.json',
  'https://raw.githubusercontent.com/gaotianliuyun/gao/master/js.json',
  'https://raw.githubusercontent.com/wxrjck/-YSC-/refs/heads/main/wx.json',
];

const Set<String> _skipSuffixes = {
  '.png', '.jpg', '.jpeg', '.gif', '.webp', '.svg', '.ico', '.css', '.js',
  '.woff', '.woff2', '.ttf', '.eot', '.mp4', '.mp3', '.zip',
};

const List<String> _skipKeywords = [
  'github.com/', 'gitlab.com/', 'gitee.com/', 'zhihu.com', 'bilibili',
  'baidu.com', 'google.com', 'bing.com', 'youtube', 'douyin', 'weibo',
  'taobao', 'jd.com', 'xiaomi.com', '360.cn', 'sohu', '163.com', 'sina.com',
  'cloudflare', 'jsdelivr.net', 'unpkg.com', 'gravatar', 'w3.org',
  'mozilla.org', 'jquery', 'bootstrap', 'miit.gov.cn', 'flowus.cn',
  'allflow.cn', 'staticfile.org',
];

const List<String> _lineKeywords = [
  '/tv', '/box', '/api', '.json', '.txt', '/dc', 'kstore', 'jundie',
  'catvod', 'tvbox', 'yingm', 'liucn', 'nxog', 'tspider', '/dm/', 'dcang',
  '仓库', '线路', '接口', '配置',
];

const String _ua = 'okhttp/4.12.0';

/// 一条待验证的线路，或一个多仓下的子仓。
class ScanNode {
  ScanNode({required this.url, this.name = '', this.depth = 0});
  String url;
  String name;
  final int depth;
  String kind = 'unknown';
  String status = 'pending';
  String? error;
  String note = '';
  int ttfbMs = -1;
  int totalMs = -1;
  double sizeKb = 0;
  String speedLabel = '不可用';
  int siteCount = 0;
  final List<ScanNode> children = [];

  bool get available => status == 'ok';
  bool get multi => kind == 'multi_storehouse' || kind == 'multi_urls';
  String get kindLabel => switch (kind) {
    'single' => '单仓',
    'multi_storehouse' || 'multi_urls' => '多仓',
    _ => '未知',
  };

  Map<String, dynamic> toJson() => {
    'name': name,
    'url': url,
    'kind': kind,
    'status': status,
    'error': error,
    'note': note,
    'ttfbMs': ttfbMs,
    'totalMs': totalMs,
    'sizeKb': sizeKb,
    'speedLabel': speedLabel,
    'siteCount': siteCount,
    'children': children.map((c) => c.toJson()).toList(),
  };
}

class ScanProgress {
  const ScanProgress({
    required this.stage,
    required this.done,
    required this.total,
    this.info = '',
  });
  final String stage;
  final int done;
  final int total;
  final String info;
}

class _Probe {
  _Probe({
    required this.ok,
    Uint8List? bytes,
    this.ttfbMs = -1,
    this.totalMs = -1,
    this.error = '',
  }) : bytes = bytes ?? Uint8List(0);
  final bool ok;
  final Uint8List bytes;
  final int ttfbMs;
  final int totalMs;
  final String error;
  factory _Probe.fail(String error, {int ttfbMs = -1, int totalMs = -1}) =>
      _Probe(ok: false, error: error, ttfbMs: ttfbMs, totalMs: totalMs);
}

/// 并发探测公开线路配置：解码、分类、多仓递归展开，并按实测耗时排序。
///
/// 只接受内置种子和发现页提取出的公网地址；既不读取用户输入的任意 URL，
/// 也拒绝回环与私网目标，避免被当成内网探测工具。
class LineScanner {
  LineScanner({
    Dio? dio,
    this.poolSize = 12,
    this.perHostLimit = 3,
    this.nodeBudget = 400,
    this.deadline = const Duration(seconds: 180),
    this.maxBytes = 3 * 1024 * 1024,
    this.decoder = const ConfigDecoder(),
  }) : _dio =
           dio ??
           Dio(
             BaseOptions(
               connectTimeout: const Duration(seconds: 12),
               followRedirects: true,
               maxRedirects: 5,
               validateStatus: (_) => true,
             ),
           );

  final Dio _dio;
  final int poolSize;
  final int perHostLimit;
  final int nodeBudget;
  final Duration deadline;
  final int maxBytes;
  final ConfigDecoder decoder;

  final List<ScanNode> roots = [];
  final Map<String, ScanNode> _cache = {};
  final Map<String, int> _hostBusy = {};
  final List<ScanNode> _queue = [];
  int _pending = 0;
  int _inFlight = 0;
  int _budget = 0;
  bool _running = false;
  Completer<void>? _done;
  DateTime? _stopAt;
  void Function(ScanProgress)? onProgress;

  bool get running => _running;

  void cancel() {
    _running = false;
    _stopAt = null;
    for (final node in _queue) {
      node.status = 'fail';
      node.error = '已取消';
    }
    _queue.clear();
    final done = _done;
    if (done != null && !done.isCompleted) done.complete();
  }

  /// 释放底层连接池；重复扫描不需要调用，页面销毁时调用一次。
  void dispose() {
    cancel();
    _dio.close(force: true);
  }

  /// 执行一次完整扫描并等待结束。取消后仍返回已完成的部分结果。
  Future<void> start() async {
    if (_running) return;
    _running = true;
    _queue.clear();
    roots.clear();
    _cache.clear();
    _pending = 0;
    _inFlight = 0;
    _completed = 0;
    _budget = nodeBudget;
    _stopAt = DateTime.now().add(deadline);
    final done = Completer<void>();
    _done = done;

    _report('搜索线路', 0, kDiscoveryPages.length + 1, '收集公开入口');
    final candidates = <(String, String)>[...kSeedLines];
    final seen = <String>{};
    for (final seed in kSeedLines) {
      final normalized = _tryNormalize(seed.$2);
      if (normalized != null) seen.add(normalized);
    }

    var pageIndex = 0;
    final pages = kDiscoveryPages.map((page) async {
      final found = await _discover(page);
      candidates.addAll(found);
      pageIndex++;
      _report(
        '搜索线路',
        pageIndex,
        kDiscoveryPages.length + 1,
        found.isEmpty ? page : '${page.split('/').length > 2 ? page.split('/')[2] : page} +${found.length}',
      );
    }).toList();
    await Future.wait(pages);

    for (final candidate in candidates) {
      if (!_running || _budget <= 0) break;
      final normalized = _tryNormalize(candidate.$2);
      if (normalized == null || !seen.add(normalized)) continue;
      _budget--;
      final node = ScanNode(url: normalized, name: candidate.$1);
      roots.add(node);
      _pending++;
      _queue.add(node);
    }

    _report('验证线路', 0, _pending, '共 $_pending 条候选');
    _pump();
    await done.future;
    _running = false;
  }

  void _report(String stage, int done, int total, String info) {
    try {
      onProgress?.call(
        ScanProgress(stage: stage, done: done, total: total, info: info),
      );
    } catch (_) {
      /* 进度回调不得影响扫描 */
    }
  }

  void _pump() {
    while (_running && _queue.isNotEmpty && _inFlight < poolSize) {
      final node = _queue.removeAt(0);
      if (DateTime.now().isAfter(_stopAt!)) {
        node.status = 'fail';
        node.error = '超过总时间预算';
        _pending--;
        continue;
      }
      _inFlight++;
      unawaited(_run(node));
    }
    if (_pending <= 0) {
      final done = _done;
      if (done != null && !done.isCompleted) done.complete();
    }
  }

  Future<void> _run(ScanNode node) async {
    try {
      await _process(node);
    } catch (error) {
      node.status = 'fail';
      node.error = '$error';
    } finally {
      _inFlight--;
      _pending--;
      _emit();
      _pump();
    }
  }

  int _completed = 0;
  void _emit() {
    _completed++;
    _report('验证线路', _completed, _completed + _pending, '');
  }

  Future<void> _process(ScanNode node) async {
    if (!_running) {
      node.status = 'fail';
      node.error = '已取消';
      return;
    }
    final cached = _cache[node.url];
    if (cached != null && cached.available) {
      node
        ..kind = cached.kind
        ..status = cached.status
        ..note = cached.note
        ..ttfbMs = cached.ttfbMs
        ..totalMs = cached.totalMs
        ..sizeKb = cached.sizeKb
        ..speedLabel = cached.speedLabel
        ..siteCount = cached.siteCount;
      node.children.addAll(cached.children);
      return;
    }

    final host = Uri.parse(node.url).host;
    var probe = await _withHostSlot(
      host,
      () => _fetch(node.url, _timeoutFor(node.depth)),
    );
    // 首轮明显偏慢时给一次更宽松的重测机会，避免把抖动当成慢站。
    if (probe.ok && probe.totalMs > 3000 && _running) {
      final retry = await _withHostSlot(host, () => _fetch(node.url, 14000));
      if (retry.ok && (retry.totalMs < probe.totalMs || retry.ttfbMs < probe.ttfbMs)) {
        probe = retry;
      }
    }
    node
      ..ttfbMs = probe.ttfbMs
      ..totalMs = probe.totalMs
      ..sizeKb = probe.bytes.length / 1024;
    if (!probe.ok) {
      node.status = 'fail';
      node.error = probe.error;
      return;
    }

    Map<String, dynamic> raw;
    try {
      raw = decoder.decode(probe.bytes);
    } catch (error) {
      node.status = 'fail';
      node.error = '无法解码：$error';
      return;
    }
    node.kind = classifyConfig(raw);
    node.siteCount = siteCountOf(raw);
    if (node.name.trim().isEmpty) node.name = str(raw['name']);
    if (node.kind == 'unknown') {
      node.status = 'fail';
      node.error = '结构不可识别（非单仓/多仓）';
      return;
    }
    node.status = 'ok';
    node.speedLabel = gradeSpeed(node.totalMs);
    _cache[node.url] = node;

    if (!node.multi) return;
    if (node.depth >= 3) {
      node.note = '超过最大嵌套深度';
      return;
    }
    final children = childrenOf(raw, node.kind);
    for (final child in children.take(100)) {
      if (!_running) break;
      final resolved = _tryNormalize(
        Uri.parse(node.url).resolve(child.$2.trim()).toString(),
      );
      if (resolved == null) continue;
      final sub = ScanNode(
        url: resolved,
        name: child.$1,
        depth: node.depth + 1,
      );
      node.children.add(sub);
    }
    for (final sub in node.children) {
      if (!_running) break;
      if (_budget <= 0) {
        sub.status = 'fail';
        sub.error = '超过节点预算';
        continue;
      }
      _budget--;
      _pending++;
      _queue.add(sub);
    }
  }

  Future<T> _withHostSlot<T>(String host, Future<T> Function() task) async {
    var spins = 0;
    while (_running && (_hostBusy[host] ?? 0) >= perHostLimit) {
      await Future<void>.delayed(const Duration(milliseconds: 80));
      if (++spins > 150) break;
    }
    _hostBusy[host] = (_hostBusy[host] ?? 0) + 1;
    try {
      return await task();
    } finally {
      final left = (_hostBusy[host] ?? 1) - 1;
      if (left <= 0) {
        _hostBusy.remove(host);
      } else {
        _hostBusy[host] = left;
      }
    }
  }

  Future<_Probe> _fetch(String url, int timeoutMs) async {
    final watch = Stopwatch()..start();
    final token = CancelToken();
    try {
      final response = await _dio
          .getUri<ResponseBody>(
            Uri.parse(url),
            cancelToken: token,
            options: Options(
              responseType: ResponseType.stream,
              followRedirects: true,
              maxRedirects: 5,
              validateStatus: (_) => true,
              receiveTimeout: Duration(milliseconds: timeoutMs),
              sendTimeout: Duration(milliseconds: timeoutMs),
              headers: const {'User-Agent': _ua},
            ),
          )
          .timeout(
            Duration(milliseconds: timeoutMs + 2000),
            onTimeout: () {
              token.cancel('probe timeout');
              throw TimeoutException('probe timeout');
            },
          );
      final headersMs = watch.elapsedMilliseconds;
      final body = response.data;
      final status = response.statusCode ?? 0;
      if (body == null) {
        return _Probe.fail('空响应', ttfbMs: headersMs);
      }
      if (status < 200 || status >= 300) {
        await body.stream.listen((_) {}, onError: (_) {}).cancel();
        return _Probe.fail('HTTP $status', ttfbMs: headersMs);
      }
      final builder = BytesBuilder(copy: false);
      var ttfb = headersMs;
      var first = true;
      await for (final chunk in body.stream) {
        if (first) {
          ttfb = watch.elapsedMilliseconds;
          first = false;
        }
        builder.add(chunk);
        if (builder.length > maxBytes) {
          token.cancel('size limit');
          return _Probe.fail('响应超过大小限制', ttfbMs: ttfb);
        }
      }
      return _Probe(
        ok: true,
        bytes: builder.takeBytes(),
        ttfbMs: ttfb,
        totalMs: watch.elapsedMilliseconds,
      );
    } on DioException catch (error) {
      return _Probe.fail(_describe(error));
    } on TimeoutException {
      return _Probe.fail('超时');
    } catch (error) {
      return _Probe.fail('$error');
    }
  }

  String _describe(DioException error) {
    if (error.error is HandshakeException) return 'TLS 握手失败';
    return switch (error.type) {
      DioExceptionType.connectionTimeout => '连接超时',
      DioExceptionType.receiveTimeout => '读取超时',
      DioExceptionType.sendTimeout => '发送超时',
      DioExceptionType.badCertificate => 'TLS 证书错误',
      DioExceptionType.cancel => '已取消',
      _ => '网络错误',
    };
  }

  Future<List<(String, String)>> _discover(String page) async {
    final found = <(String, String)>[];
    if (!_running) return found;
    final host = Uri.parse(page).host;
    final probe = await _withHostSlot(host, () => _fetch(page, 6000));
    if (!probe.ok || probe.bytes.isEmpty) return found;
    String text;
    try {
      text = utf8.decode(probe.bytes, allowMalformed: true);
    } catch (_) {
      return found;
    }
    for (final url in extractConfigUrls(text)) {
      found.add(('', url));
    }
    return found;
  }

  String? _tryNormalize(String value) {
    try {
      final uri = normalizeHttpUrl(value.trim());
      if (uri.host.isEmpty) return null;
      if (!['http', 'https'].contains(uri.scheme.toLowerCase())) return null;
      if (_isPrivateHost(uri.host)) return null;
      return uri.toString();
    } catch (_) {
      return null;
    }
  }

  static int _timeoutFor(int depth) =>
      depth <= 0 ? 9000 : (depth == 1 ? 11000 : 13000);
}

/// 从页面正文里提取像配置入口的地址。
List<String> extractConfigUrls(String text) {
  final out = <String>[];
  if (text.isEmpty) return out;
  final pattern = RegExp(r'''https?://[^\s"'<>()\[\]]+''', caseSensitive: false);
  for (final match in pattern.allMatches(text)) {
    if (out.length >= 60) break;
    final trimmed = match.group(0)!.replaceAll(
      RegExp(r'''[.,;:，。；：、)\]"}>]+$'''),
      '',
    );
    final lower = trimmed.toLowerCase();
    if (!lower.startsWith('http')) continue;
    if (_skipSuffixes.any(lower.endsWith)) continue;
    if (_skipKeywords.any(lower.contains)) continue;
    if (lower.contains('.html') ||
        lower.contains('/app/') ||
        lower.contains('/soft') ||
        lower.contains('/zt')) {
      continue;
    }
    if (!_lineKeywords.any(lower.contains)) continue;
    if (!out.contains(trimmed)) out.add(trimmed);
  }
  return out;
}

bool _isPrivateHost(String host) {
  final value = host.toLowerCase().replaceAll(RegExp(r'^\[|\]$'), '');
  if (value == 'localhost' || value.endsWith('.localhost')) return true;
  if (value == '::1' || value == '0.0.0.0') return true;
  final parts = value.split('.');
  if (parts.length != 4) return false;
  final octets = <int>[];
  for (final part in parts) {
    final parsed = int.tryParse(part);
    if (parsed == null || parsed < 0 || parsed > 255) return false;
    octets.add(parsed);
  }
  final a = octets[0], b = octets[1];
  if (a == 10 || a == 127 || a == 0) return true;
  if (a == 169 && b == 254) return true;
  if (a == 172 && b >= 16 && b <= 31) return true;
  if (a == 192 && b == 168) return true;
  if (a == 100 && b >= 64 && b <= 127) return true;
  return false;
}

String classifyConfig(Map<String, dynamic> raw) {
  final store = raw['storeHouse'];
  if (store is List && store.isNotEmpty) return 'multi_storehouse';
  final urls = raw['urls'];
  if (urls is List && urls.isNotEmpty) return 'multi_urls';
  if (raw.containsKey('sites') ||
      raw.containsKey('lives') ||
      raw.containsKey('parses') ||
      raw.containsKey('spider')) {
    return 'single';
  }
  return 'unknown';
}

int siteCountOf(Map<String, dynamic> raw) {
  final sites = raw['sites'];
  final lives = raw['lives'];
  return (sites is List ? sites.length : 0) +
      (lives is List ? lives.length : 0);
}

/// 多仓展开出来的子入口。
List<(String, String)> childrenOf(Map<String, dynamic> raw, String kind) {
  final out = <(String, String)>[];
  if (kind == 'multi_storehouse') {
    for (final item in jsonList(raw['storeHouse'])) {
      final map = jsonMap(item);
      final name = str(map['sourceName']).isNotEmpty
          ? str(map['sourceName'])
          : str(map['name']);
      final url = str(map['sourceUrl']).isNotEmpty
          ? str(map['sourceUrl'])
          : (str(map['url']).isNotEmpty ? str(map['url']) : str(map['api']));
      if (url.trim().isNotEmpty) out.add((name, url));
    }
  }
  for (final item in jsonList(raw['urls'])) {
    final map = jsonMap(item);
    final name = str(map['name']);
    final url = str(map['url']).isNotEmpty ? str(map['url']) : str(map['api']);
    if (url.trim().isNotEmpty) out.add((name, url));
  }
  return out;
}

String gradeSpeed(int totalMs) {
  if (totalMs < 0) return '不可用';
  if (totalMs < 500) return '快';
  if (totalMs < 2000) return '中';
  if (totalMs < 5000) return '慢';
  return '不可用';
}

/// 把选中的可用线路打包成可直接导入流光的 `urls` 多仓配置。
String buildImportConfig(List<ScanNode> nodes, {String? name}) {
  final urls = <Map<String, String>>[
    for (final node in nodes)
      {'name': node.name.trim().isEmpty ? node.url : node.name.trim(), 'url': node.url},
  ];
  return jsonEncode({
    'name': name ?? '线路发现 ${urls.length} 条',
    'urls': urls,
  });
}
