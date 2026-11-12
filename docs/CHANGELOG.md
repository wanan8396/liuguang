# 0.1.7

- Windows WebView2 / iOS WKWebView 原生嗅探：执行网页 JS，观察 fetch/XHR、响应 MIME 和已加载媒体 DOM；保留 UA/Referer/资源 Cookie，排除导航页、HTML 与 HTTP 错误，支持取消、总超时和原生 view 释放。缺少组件时才走静态提取兜底。
- 修正 type=0 解析器和 playUrl 前缀曾被当作 JSON 后丢弃的问题；Windows/iOS HTML 直播接入同一嗅探路径，JSON 解析不强制抹除后续 parse 状态。
- 新增显式 Android 引擎连接：Windows/iOS 的 JAR/DEX 会话和 type=2/3 解析由同网 Android 原生引擎执行；随机令牌、加密保存、严格 RPC allowlist，流式媒体/HLS/Range，停止、退出、超时撤销会话。Android 服务仅前台手动启用。
- JAR 内嵌 JS 改为 manifest 按 csp_* 精确选择或根 spider.js 明确兼容，修复全局 spider 回退，加入 MD5、中央目录/CRC/data descriptor 与解压限额检查，避免把库文件或 JSON 当可执行源码。
- 静态媒体探测最多读取 1024 字节并取消上游连接，保留实际播放页 Referer；网络错误和 HTML 不再凭扩展名猜成功。
- 回归覆盖归档损坏/压缩上限/真实 QuickJS 多入口、原生view生命周期、bridge RPC/HLS/Range/超时、凭据不进入备份，以及切换连接竞态。CI 增加真实 WebView2/WKWebView 动态网页与 ART/DexClassLoader 受控样本验收。

# 0.1.6

- Windows/iOS 新增便携网页嗅探：`parse=1` 播放页会读取 `<video>/<audio>/<source>`、`og:video` 声明和播放器脚本中的媒体地址，跳过页面自身 URL，经带 Range 的探测校验 `Content-Type`、`#EXTM3U`、`<MPD`、`ftyp`、TS 同步字节后才返回，并附带 `Referer` 与源请求头。默认最多两级页面、24 个候选，不执行页面 JavaScript。
- Windows/iOS 新增 JAR 兼容层：下载并解析 JAR，识别 `classes.dex`，提取归档内嵌的 `spider.js` / `spider.json` 规则，交给现有便携 JS 引擎执行；只含 DEX、没有可移植规则的 JAR 明确提示需要 Android，不再退化成网络错误。
- 播放解析在 JSON 解析器和 JAR 都不可用时回退到页面嗅探，仍然失败才报错，错误信息说明各路径的实际结果。
- 修复单文件模块转换误改注释、字符串和正则里 `export` 的问题，网络错误改为在 JS 层抛出以便源脚本 `try/catch`，并封住取消与 `Isolate.spawn` 之间的工作线程泄漏竞态。
- Android 端裸 `__jsEvalReturn` 函数源的选用顺序与跨平台引擎保持一致。

验证：168 项 Flutter 测试通过（含 6 项新增嗅探与 JAR 离线测试、真实 QuickJS 端到端用例），静态分析零问题。Windows/iOS 实际编译与打包由对应 Actions 结果确认。

# 0.1.5

- 增加 Windows x64 和 iOS 15+ 工程与 GitHub Actions release 编译入口：Windows 交付完整 EXE/DLL/data zip，iOS 交付 `--no-codesign` unsigned Payload zip，并附构建信息和 SHA-256；Apple 正式签名与安装流程见 [平台说明](<PLATFORMS.md>)。
- Windows 使用 QuickJS、iOS 使用系统 JavaScriptCore，支持传统 drpy `rule`、`__JS_SPIDER__`、单文件 `export default` / `__jsEvalReturn`，以及 HTTP、HTML、crypto、本地代理和 type=1 JSON 解析器桥接。多文件模块需预先 bundle；JAR/DEX 和网页嗅探当时仍由 Android 原生引擎处理（0.1.6 起 Windows/iOS 已加入便携实现）。
- 固定本地 `flutter_js` 0.8.7 Windows/iOS 子集，Android 保留原 Kotlin/QuickJS/JAR 路径，避开上游旧 Android Gradle 依赖。
- 完善 iOS15 CocoaPods、相机与局域网说明、HTTP 订阅兼容、流光品牌图标和启动页；更新 Windows 品牌元数据及 MSVC runtime 打包。

验证：157 项 Flutter 测试通过，Windows 真实 QuickJS 的受控 HTTP/HTML/crypto、drpy 及取消重开回归通过；新工作流通过 actionlint/ShellCheck，Windows 打包合成正反例及工程/图标静态检查通过。Windows C++ release 与 macOS Xcode/iOS 设备编译以对应 Actions 结果为准，签名分发和真实源设备验收另行完成。

# 0.1.4

- 内置奇奇多仓首次自动展开全部子仓，后续每6小时在后台检查更新；失败保留已有配置，刷新不打断当前播放。
- 订阅管理仅展示自行追加的地址，支持逐条追加、重命名、删除和清理旧订阅。隐藏内置订阅卡片和导入诊断区，移除全网扫描入口。
- 更新“关于流光”介绍并使用新图标；关闭播放器调试转发、宿主日志和 SpiderDebug 输出。
- 电视直播汇总所有已订阅仓库，频道增量显示；失败来源收进状态详情，刷新失败保留当前运行期间的可用频道。频道及收藏记住所属仓库，切换首页不清空电视列表。
- 修复多仓切换时站点与插件错配、部分源有分类却无首页内容、封面请求头、Android 新版重复加载插件失败等问题。
- 播放器倍速移到右下角，使用小型浮层；长按临时2倍速、松手恢复。延长代理响应等待时间，支持多清晰度地址数组和旧版本地 HLS 包装。
- 小虎斑全网短剧旧接口不可用时切到同仓已启用的备用源，显示实际来源；修复七猫与围观短剧的播放兼容问题。

验证：135 项 Flutter 测试、30 项 Android JVM 测试、静态分析、release 签名和36项动态插件ABI检查通过。实机已验证短剧解码、用户确认备用入口可用、电视频道汇总显示；第三方失效服务不能保证恢复，配置有效也不代表每条媒体线路均可播放。
