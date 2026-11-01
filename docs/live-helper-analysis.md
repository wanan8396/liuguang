# 影视仓接口助手 3.0：直播功能只读分析

## 结论与范围
这是一个原生 Java + 本地 WebView 的直播列表聚合、探测和 M3U 导出工具，不是提供独立直播后台 API 或内置播放器的客户端。直播入口取自 DEX 中 `LiveEngine.SEEDS`，共 **15 组、19 个候选 URL**；assets/index.html 只承载 UI 与 JS 桥接。
仅解压、静态反汇编和 4 次公开列表 GET；未安装/启动 APK，未请求频道流或分片，未连接付费或认证绕过端点，未修改原 APK 或父计划。公开可访问不代表具备内容转播授权。

## 样本与工具
- 原文件：`/storage/emulated/0/AI工作区/影视仓接口助手_3.0.apk`
- file：Android package (APK), with AndroidManifest.xml, with APK Signing Block。
- SHA-256：`116caaa3fb0d37d1773e7ad761b886aeaed772d2350da16df57983cdbb213ab0`
- 包名 `com.ysc.lineverify`，版本 3.0 / versionCode 3；aapt 与 androguard AXML 解析交叉一致；minSdk 21，targetSdk 27。
- INTERNET、ACCESS_NETWORK_STATE、WAKE_LOCK、FOREGROUND_SERVICE 权限。Manifest 未声明自定义 Application；单个可直接解析的 classes.dex，无 lib/，未见加壳结构。
- 先读取 recon.md 并运行 scripts/doctor.py：static 可用；jadx/apktool 不在 PATH、adb 无设备。使用已有 androguard 解析 manifest 与 DEX，不需要安装工具或动态取证。
- ZIP 清单 `/tmp/liuguang-apk-recon/zip-list.txt`：核心 `assets/index.html` 43,379 字节、`classes.dex` 97,044 字节；没有内置频道列表资源。

## 调用链与证据
以下 DEX 行号对应 `/tmp/liuguang-apk-recon/dex-disassembly.txt`，HTML 行号对应 extracted/assets/index.html。
1. HTML 636–650 `startLive()` → `window.YscAndroid.startLive()`。
2. DEX 6347 起 `MainActivity$Bridge.startLive()` → 构建 `LiveEngine(store,sink)` → `start()` → `run()`（5058 起）。
3. `run()` → `collectSeeds()`（4403），仅遍历静态 `SEEDS`（3697–3851），去重第一候选地址；`fetchList()`（4448）依序尝试组内备选，每个至多两次，404 跳过当前候选；调用 `Http.fetch(url,35000)`，有效文本交给 `Live.parse()`。
4. `Live.parse()`（3271）移除 BOM，出现 #EXTINF 或开头 #EXTM3U 则 M3U，否则 TXT。`parseM3u`（3296）、`parseTxt`（3365）→ `add`（2803）→ 分类与 Entry。
5. URL 去重 → `probeAll` → `probe`（4843）→ `Http.fetch(url,2000)`；仅 http(s) 可探测。检查 HLS 标签、首分片，必要时 `Http.probeSegment(...,3000)`；主列表解析 BANDWIDTH / RESOLUTION 推测质量。**未真正解码视频，不等于能播放；非 HTTP 被标记，直接 TS/FLV 也可能被误判。**
6. `build()`（4021）组织分组与候选，标准频道最多 5 条，其他最多 3 条；`run`（5244）→ `Store.saveLive`，文件名 live.json（9771）；历史为抓取结果快照，不是观看历史。
7. sink 回调 `window.__yscLive`（10421；HTML 327），done → `loadLive()`（HTML 657）→ bridge.getLive → 前端分组、最优选择。
8. HTML 936–946 收集选中 `{name,group,url}` → `exportM3u` → `MainActivity.buildM3u`（6594 附近；以 METHOD 搜索为准）输出 `#EXTM3U` 与 `#EXTINF:-1 tvg-name="..." group-title="...",频道名` + URL；文件名 live_yyyyMMdd.m3u。没有证据表明其提供 REST 直播服务。

### 一个实现缺口
`ConfigDecoder.collectLives`（351）会从 TVBox JSON `lives[]` 读取 `url`（缺省回退 api）；`mergeLiveSeeds`（6683）把发现地址写入 liveseeds.json。但是 `LiveEngine.collectSeeds` **没有调用 loadLiveSeeds**，只读硬编码 SEEDS。因此“点播配置自动发现直播”虽有保存链，当前抓取链实际未消费这些动态种子；接入时不应照抄这个缺口。`lives[].channels` 内联数组也未见此方法支持。

## 请求与解析契约
- 实现为 HttpURLConnection，User-Agent 虽写 okhttp/4.12.0，不代表使用 OkHttp 库。
- 列表/HLS GET：`User-Agent: okhttp/4.12.0`、`Accept: */*`、`Accept-Encoding: gzip`（DEX 1603–1654）。没有发现此请求链设置 Referer、Authorization、Cookie 或签名。
- 分片 GET：同 UA + `Range: bytes=0-1023`（2294–2341）。
- 列表超时实参 35,000ms；连接超时限制为 2,000–6,000ms，读取超时至少 2,000ms；分片连接限制 1,500–4,000ms。列表手动重定向循环并做域名/内网地址检查，不能在新实现中丢掉 SSRF 防护。
- 源抓取与探测共用 160 线程固定池（5058），移植时建议降低并发、限制每主机连接、提供取消与超时，避免照搬过高负载。
- M3U：显示名取 EXTINF 逗号后，回退 tvg-name/tvg-id；支持 group-title、tvg-logo；随后一条非注释 URL 为频道。注释中的 EXTVLCOPT/KODIPROP **不被提取为请求头**，不能保证需要特殊头的源工作。
- TXT：`分组,#genre#`、`频道名,http(s)://...`；以首逗号分割，URL 中 # 后内容截去，没有将 # 多线路拆成多条。支持识别 http/https/rtmp/rtsp/p3p/mitv 前缀，但探测仅 http(s)。
- 内部输出约为 `{ts,per_std:5,per_other:3,total,raw,ok,groups:[{name,ok,items:[{name,url,ok,ttfb?,quality?,bitrate?,note?}]}],lists_ok,lists_total,sources}`。logo 虽进入 Entry，但导出的 buildM3u 未携带 logo。
- 固定分组：央视频道、卫视频道、地方频道、影视频道、体育频道、少儿频道、港澳台、其他。

## 全部可复用直播种子
每行是一组，箭头后为顺序备选（不是同时合并）。分类格式由内容判定，不能只看 .m3u8 扩展名。
1. `https://gh-proxy.com/raw.githubusercontent.com/gaotianliuyun/gao/master/list.txt` → `https://raw.githubusercontent.com/gaotianliuyun/gao/master/list.txt`
2. `https://gh-proxy.com/raw.githubusercontent.com/suxuang/myIPTV/main/ipv4.m3u` → `https://raw.githubusercontent.com/suxuang/myIPTV/main/ipv4.m3u`
3. `https://gh-proxy.com/raw.githubusercontent.com/vbskycn/iptv/master/tv/iptv4.txt` → `https://raw.githubusercontent.com/vbskycn/iptv/master/tv/iptv4.txt`
4. `https://gh-proxy.com/raw.githubusercontent.com/iptv-org/iptv/master/streams/cn.m3u`
5. `https://gh-proxy.com/raw.githubusercontent.com/Kimentanm/aptv/master/m3u/iptv.m3u`
6. `https://gh-proxy.com/raw.githubusercontent.com/CCSH/IPTV/master/live.m3u`
7. `https://gh-proxy.com/raw.githubusercontent.com/zipsoon/iptv-sources/master/cn_all.m3u8` → `https://gh-proxy.com/raw.githubusercontent.com/zipsoon/iptv-sources/master/cn_cctv.m3u8`
8. `https://gh-proxy.com/raw.githubusercontent.com/cs3306/IPTV-Sources/main/data/output/iptv_collection.m3u`
9. `https://live.zbds.top/tv/iptv4.m3u`
10. `https://live.zbds.top/tv/iptv4.txt`
11. `https://91zhibo.net/iptv/live.txt`
12. `https://iptv-org.github.io/iptv/countries/cn.m3u`
13. `https://iptv-org.github.io/iptv/countries/hk.m3u`
14. `https://iptv-org.github.io/iptv/countries/tw.m3u`
15. `https://iptv-org.github.io/iptv/countries/mo.m3u`

## 公开列表 GET 验证
时间：2026-11-01 16:34 UTC 左右（设备时间）。每个仅一次 GET，无认证，不跟随重定向，最多 1MiB、超时受限；不持久化正文/潜在查询凭据、不请求其中媒体。

| 列表 | HTTP | 大小 bytes | 格式证据 | 耗时 s |
|---|---:|---:|---|---:|
| `https://raw.githubusercontent.com/gaotianliuyun/gao/master/list.txt` | 200 | 16038 | EXTINF=0, genre=3 | 2.34 |
| `https://raw.githubusercontent.com/suxuang/myIPTV/main/ipv4.m3u` | 200 | 268591 | EXTINF=1273, genre=0 | 1.31 |
| `https://raw.githubusercontent.com/vbskycn/iptv/master/tv/iptv4.txt` | 200 | 48921 | EXTINF=0, genre=11 | 2.37 |
| `https://iptv-org.github.io/iptv/countries/cn.m3u` | 200 | 31743 | EXTINF=155, genre=0 | 1.04 |

四个列表均 HTTP 200 且可识别为直播列表；这是**列表可获取验证**，不是频道可播率、内容授权或长期稳定性证明。其余 11 组未在线验证，代理域也未请求。M3U EXTINF 数与独立 http 行数不同，可能存在其他协议/格式，不能直接视为有效频道数。

## 接入建议与产物
优先直接使用已验证的 iptv-org countries/cn.m3u（155 个 EXTINF）与 suxuang/myIPTV（1273 个 EXTINF），支持用户导入 TXT/M3U 与备选源。优先直连公开源，第三方 gh-proxy 仅作为可选回退，不必把 APK 原有代理优先策略照搬。
新代码应区分“列表获取成功 / HLS结构有效 / 首分片可达 / 实际解码成功”，请求头按源隔离，避免把令牌或头跨域转发。节目源可能涉及区域、IPv6、运营商与授权限制，本报告不进行任何绕过。

- 工作目录：`/tmp/liuguang-apk-recon`
- 完整重用配置：同目录 `live_sources.json`（15组候选及请求头）
- 验证记录：同目录 `get_validation.json`（含响应体 hash，不含正文与密钥）
- 证据：`zip-list.txt`、`classes.txt`、`dex-disassembly.txt`、`extracted/assets/index.html`
- 持久交付副本：报告同目录 `liuguang_live_sources.json`、`liuguang_live_get_validation.json`。

## 未完成与限制
未进行设备运行、媒体分片或播放器实测，未对点播/解析/付费业务端点发请求。没有关于真实频道可播率的结论。静态证据来自 androguard 指令输出，并非 JADX 高级反编译；行号仅对本工作目录的输出有效。

原 APK 分析后 SHA-256 复核一致：`116caaa3fb0d37d1773e7ad761b886aeaed772d2350da16df57983cdbb213ab0`。
