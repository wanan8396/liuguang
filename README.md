# 流光 Liuguang

Flutter Android 多仓视频播放器。首页／电视／我的三栏，包含订阅管理、搜索、选集播放、直播节目单、收藏历史、扫码导入、备份恢复和局域网订阅推送。

> 开发中。配置能导入、测试通过、APK 构建成功和真实源能播放是不同的验证层级。当前不能承诺所有第三方插件或外部服务可用。

## 云端编译与测试

本项目使用 [GitHub Actions](https://github.com/wanan8396/liuguang/actions/workflows/android-ci.yml) 编译与测试，无需在用户电脑上编译。

每次推送或 PR 自动运行：

1. Flutter 静态分析与离线单元／组件测试。
2. Android JVM 回归测试和 ARM64 APK 构建、签名校验、SHA-256。
3. x86_64 Android 模拟器上的受控 DEX、初始化／关闭、端口冲突测试。

运行成功后，从对应 Actions run 的 **Artifacts** 下载 `liuguang-arm64-<commit>`。包内包含 APK、校验值和构建元数据。

- Android 7.0 / API 24 及以上，ARM64。
- CI 产物使用临时开发签名，**不是正式发布签名**。不同 runner 的测试包可能无法直接覆盖安装；先导出个人数据，再根据 Android 提示处理签名冲突。
- x86_64 模拟器不执行 ARM-only QuickJS 测试，跳过状态在报告中明确展示。
- CI 不抓取真实订阅、不执行第三方远程插件、不访问账号或媒体；不能将 CI 绿灯当成真实源播放验收。

固定工具链：Flutter 3.47.8 / Dart 3.13.7、JDK21、Android SDK36、NDK28.2.13676358、Gradle wrapper 9.3.1。依赖由 `pubspec.lock` 和 Android 构建配置锁定。

## 使用

1. 在“我的 → 视频订阅”输入单仓或多仓地址并导入。
2. 选择仓库和站点；使用远程插件前确认信任来源。
3. 浏览分类或搜索，进入详情选择线路与集数。
4. 需要账号的源，在“源管理与凭据”配置对应名称的 Cookie/Token；应用不自动注册、付费或绕过服务端授权。
5. 数据推送需要主动开启，同 Wi-Fi 设备输入配对码，手机确认后才导入，超时自动关闭。

无可用源、缺凭据、外部 HTTP/TLS 故障和插件异常会分别显示，失败不会被伪装成空列表成功。

## 功能与结构

- `lib/core/config`：宽松 JSON、gzip、Base64、Hex/AES 包装、多仓／单仓、循环与镜像识别。
- `lib/core/network`：有界请求、中文域名、UA、重定向和资源引用解析。
- `lib/core/engine`、`pigeons`：CMS/远程接口、类型化原生通道和播放调度。
- `android/source_engine`：CatVod/JAR、QuickJS/drpy、WebView、流式回环代理。
- `lib/core/live`：M3U/TXT/JSON、XMLTV/JSON 节目单。
- `lib/core/storage`：Hive、安全凭据、恢复前快照。
- `lib/features`：真实数据驱动的界面和 media_kit 播放控制。

## 端口兼容与已知限制

动态回环代理是常规路径。旧插件可能硬编码 9978、9997 或 5266；这些端口的兼容能力与插件初始化分别管理，不应因为一个不相关端口绑定失败阻断所有源。

- 固定端口无法占用时，不连接或接管其他进程服务，也不终止其他应用。
- 硬依赖被占端口的插件仍可能失败，需要具体端口诊断，不能保证透明迁移任意 JAR 的硬编码请求。
- `5266/iptv.m3u` 特定客户端聚合服务尚未完整实现。
- 任意 JS 方言、旧 QuickJS 字节码、自定义 JAR jsapi、Python/Node 可选运行时未全部覆盖。
- 真实第三方插件、网页认证、音画、首帧、手势和续播仍需 ARM64 设备验收。

## 隐私与插件信任

远程 JAR/JS 在应用权限下执行，不是安全沙箱。仅添加可信订阅；MD5 可检查制品一致性，但不证明作者身份或安全性。

凭据使用系统安全存储，不进入普通备份。恢复备份不会恢复插件信任。默认媒体代理只绑定 loopback；局域网推送是独立、限时、需要配对确认的服务。TLS 校验不会因兼容问题被关闭。

## 许可与供应商代码

GPLv3，详见 `LICENSE`、`THIRD_PARTY_NOTICES` 和 `docs/DEPENDENCIES.md`。第三方代码、包装器与原生库遵循各自许可证；没有复制无明确许可证的站点 Spider 示例。

QuickJS wrapper/native pair 固定到可追溯的上游制品提交和哈希，但上游未提供可确认的底层二进制精确源码修订，因此**不宣称已验证完整可复现构建**。相关边界在依赖说明中记录。

应用不内置影片，内容及账户权限由各源提供方决定。
