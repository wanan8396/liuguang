# Windows 与 iOS 构建、安装及能力说明

## 支持范围

| 项目 | Android | Windows | iOS |
| --- | --- | --- | --- |
| 最低版本 / 架构 | Android 7 / API 24，ARM64 | Windows 10/11，x64 | iOS 15，arm64 |
| Flutter UI、订阅、CMS、直播与播放器 | 保留现有实现 | 使用跨平台实现 | 使用跨平台实现 |
| JavaScript 引擎 | 原 Kotlin/QuickJS 引擎 | QuickJS | 系统 JavaScriptCore |
| drpy `rule`、`__JS_SPIDER__`、单文件 `export default` / `__jsEvalReturn` | 原引擎能力 | 可移植 JS 运行时 | 可移植 JS 运行时 |
| 多文件 ES module `import` | 依原引擎与插件实现 | 发布前先 bundle 成单文件 | 发布前先 bundle 成单文件 |
| HTML / crypto / 代理与 type=1 JSON 解析器 | 原引擎能力 | 跨平台桥接 | 跨平台桥接 |
| 同步 JS `req` | 原引擎能力 | worker → loopback → 异步 HTTP(S) | worker → loopback → 异步 HTTP(S) |
| CatVod JAR 内嵌 JS | 原生加载 | 按显式 manifest 选择 JS 入口 | 按显式 manifest 选择 JS 入口 |
| CatVod DEX/JAR、Android 插件及 type=2/3 解析 | 本机 Android 引擎 | 可选连接同网 Android 执行，非 Windows 本地 DEX | 可选连接同网 Android 执行，非 iOS 本地 DEX |
| 网页嗅探（parse=1 播放页） | Android WebView | 原生 WebView2 执行网页 JS，静态提取兜底 | 原生 WKWebView 执行网页 JS，静态提取兜底 |
| 相机扫码 | Android 插件 | 当前扫码插件无 Windows 原生实现，可手动输入订阅 | iOS 插件，首次主动扫码时申请相机权限 |

能构建、能启动、能导入配置与真实源能播放是不同层级。不同 JS 方言、插件额外宿主 API、网页认证、媒体编解码和第三方服务仍需分别验收；这里没有把跨平台支持等同于任意 Android 插件兼容。同步 JS 请求使用的回环服务属于应用运行时；CI 仅通过受控 loopback fixture 回归 JS HTTP/HTML/crypto 和生命周期，不启动面向局域网的订阅推送服务。

**网页嗅探的验证方式：**Windows 的 WebView2 动态页面验收在 CI 中自动执行（工作流会确保 Microsoft Edge WebView2 Runtime 可用）；iOS 的 WKWebView 验收需要已启动的模拟器与首次 Xcode 模拟器构建，超出托管 runner 的时间预算，属本地 macOS 手动步骤：`xcrun simctl boot <设备>` 后执行 `flutter test integration_test/native_web_sniffer_test.dart -d <设备>`。CI 对 iOS 仍执行 JavaScriptCore 受控测试、设备编译与打包。

**网页嗅探：**Windows 的 WebView2 / iOS 的 WKWebView 真正执行播放页 JS，观察 fetch、XHR、网络响应与已加载的媒体 DOM。导航页自身、HTML 登录页、HTTP 错误、blob/data URL 不作为成功资源；返回播放器的地址携带页面 Referer、User-Agent 和当前资源 Cookie。每个原生操作最多 25 秒，退出/切源取消并释放 view。`type=0` 解析器和 `playUrl` 前缀交给浏览器，`type=1` 保留 JSON 解析。原生组件缺失或未命中时使用静态提取兜底；兜底只取最多两级页面、24 个候选，媒体探测最多读取 1024 字节并停止连接，失败不再凭文件扩展名猜成功。完整解析等待期限为 40 秒。Windows 需要 Microsoft Edge WebView2 Runtime（Windows 10/11 通常随 Edge 预装）；若缺失，原生嗅探在 10 秒内放弃并回退静态提取，不会卡住播放。它是系统依赖，不是另行安装的浏览器自动化服务。带交互登录、人机验证、DRM 或私有播放器协议的页面仍需针对具体源验收。

**JAR 源：**未设置 Android 引擎时，只执行明确声明的内嵌 JS。归档通过中央目录、CRC 和解压限额验证；有 `META-INF/liuguang.json` 时按当前 `site.api` 的映射选择入口，无 manifest 时只兼容根目录精确 `spider.js`，不再执行任意第一个 `.js`。`spider.json` 是元数据或显式入口映射，绝非自动执行的 JS。支持 `site.jar` 优先、仓库 `spider` 回退、相对 URL 与 `;md5;` 校验。归档最多 8 MiB / 2048 条目，单条解压 8 MiB、总解压 32 MiB、JS 4 MiB；超限和损坏均报明确错误。

配置步骤、流式路径与 JAR manifest 格式见 [Android 引擎连接](<ANDROID_ENGINE_BRIDGE.md>)。

**完整 DEX/JAR：**在 Windows/iOS“我的流光 → Android 引擎连接”保存同网 Android 的地址和临时令牌后，JAR 会话、搜索/分类/详情/播放及 type=2/3 解析由该 Android 的原生 CatVod 引擎执行。Windows/iOS 不包含 ART、Android SDK 类库或 JAR 的 JNI 库，桥接不等于本机运行 DEX。需要 Android 同样安装此版本并保持服务页前台；插件弹窗和登录交互发生在 Android，第三方 JAR 的兼容性仍取决于原生 ABI 和所用服务。

**执行期限限制：**固定的 Windows QuickJS DLL 与 iOS JavaScriptCore 桥未暴露可靠的原生硬中断。45 秒是宿主请求的等待期限，不是任意 JS 的硬执行上限；纯 JS 同步死循环不保证被 `Isolate.kill` 打断，极端内容源可能需要重启应用。正常请求取消、正常关闭及受控功能回归已通过，但这不代表硬超时、沙箱隔离或所有脚本兼容。

## 云端构建与下载

[Windows and iOS builds 工作流](<../.github/workflows/desktop-ios.yml>) 在 `main`、`fix/**`、`ci/**` 推送、PR 和手动触发时执行两个独立 job，不依赖本地 MSVC 或 macOS：

- **Windows**：GitHub `windows-2022` runner、Visual Studio 2022 C++ 工具链、Flutter 3.47.8；执行 x64 release 构建。
- **iOS**：GitHub `macos-15` runner、runner 提供的 Xcode 与 CocoaPods、Flutter 3.47.8；执行设备 arm64 release、`--no-codesign`。
- Dart 依赖使用 `flutter pub get --enforce-lockfile`。Xcode/CocoaPods 版本随 runner 镜像更新；日志记录版本，iOS 另上传当次 CocoaPods 锁定结果。当前不宣称原生工具链或远端原生下载制品完全可复现。
- 不安装签名证书，不使用 Apple 账号，不在 CI 中导入真实订阅或播放第三方媒体。构建成功不代表完成 Windows GUI / iPhone 设备测试。

打开对应 Actions run 的 **Artifacts**：

| Artifact 名称 | 主要内容 |
| --- | --- |
| `liuguang-windows-x64-<commit>` | 完整 Windows release zip、zip 的 SHA-256、构建信息 |
| `liuguang-ios-arm64-unsigned-<commit>` | unsigned Payload zip、SHA-256、构建信息、原生依赖及 zip 目录清单 |
| `ios-native-dependencies-<commit>` | 当次 CocoaPods 依赖解析结果，用于排查原生依赖变化 |

下载不等于本地编译。仅使用云端产物时，用户电脑上不需要安装 Flutter、Visual Studio、CocoaPods 或保留源码副本。工作流产物默认保留 14 天。

## Windows 包结构与安装

解压 artifact 内的 `liuguang-windows-x64.zip`，再打开其中的 `liuguang.exe`。**保持整个文件夹完整，不要只复制 EXE**：

```text
liuguang-windows-x64/
  liuguang.exe
  flutter_windows.dll
  msvcp140.dll / vcruntime140*.dll
  ...插件 DLL、mpv 视频库和其他原生资源...
  data/
    app.so
    icudtl.dat
    flutter_assets/
  BUILD.txt
  SHA256SUMS.txt
  LICENSE / THIRD_PARTY_NOTICES / flutter_js-LICENSE.txt / PLATFORMS.md
```

[Windows CMake 配置](<../windows/CMakeLists.txt>) 将 MSVC release runtime、插件 bundled libraries、Flutter 引擎、AOT 数据及 assets 安装到同一个 release 目录。[打包脚本](<../.github/scripts/package-windows.ps1>) 校验必要文件及 mpv DLL 后复制整个目录，生成逐文件及最终 zip SHA-256。Microsoft runtime DLL 遵循 Visual Studio 再分发条款，应用和其他第三方部分遵循各自许可证。

目前没有 Authenticode 代码签名或安装器；Windows 可能显示未知发布者提示。正式交付可在组织签名环境中签署 EXE/DLL 并生成安装器，签名后重新生成校验值。

可选本地构建，需要 Visual Studio 2022 的 **Desktop development with C++**、MSVC 与 Windows SDK：

```powershell
flutter config --enable-windows-desktop
flutter pub get --enforce-lockfile
flutter build windows --release --no-pub
./.github/scripts/package-windows.ps1
```

## iOS：CocoaPods 与未签名产物

工程采用 CocoaPods，不混用 Flutter 自动生成的 SwiftPM 插件包。Flutter 3.47 默认模板包含 SwiftPM 接线；本工程已移除对应工程引用及 scheme prepare 预操作，并在 Flutter 项目配置与 CI 中关闭 SwiftPM。[Podfile](<../ios/Podfile>) 声明 iOS 15，调用 Flutter podhelper 为原生插件接线；[Debug 配置](<../ios/Flutter/Debug.xcconfig>) 与 [Release 配置](<../ios/Flutter/Release.xcconfig>) 先引入 Pods 配置，再引入本机生成的 Flutter 配置。

旧依赖如视频库及可移植 JS 桥仍使用 podspec。Pods、插件软链接、Flutter ephemeral、生成配置、证书与 provisioning profile 都不提交到源码。首次云端构建会解析 pod 依赖，保存锁定证据；审核该结果后可将 CocoaPods 锁定文件纳入版本控制，进一步固定后续原生依赖解析。

可选本地构建只在 macOS + Xcode + CocoaPods 环境中执行：

```bash
flutter config --no-enable-swift-package-manager
flutter pub get --enforce-lockfile
flutter build ios --release --no-codesign --config-only --no-pub
(cd ios && pod install --repo-update)
flutter build ios --release --no-codesign --no-pub
bash .github/scripts/package-ios.sh
```

[iOS 打包脚本](<../.github/scripts/package-ios.sh>) 保留框架软链接，确认 arm64 可执行文件及 Flutter/App framework 后输出：

```text
liuguang-ios-arm64-unsigned.zip
  Payload/
    Runner.app/
      Info.plist
      Runner
      Frameworks/
      ...
  BUILD.txt
  LICENSE / THIRD_PARTY_NOTICES / flutter_js-LICENSE.txt / PLATFORMS.md
```

桌面名称是“流光”，Bundle ID 当前是 `cn.liuguang.tvbox`；内部 target / `.app` 名称保留 `Runner`，这不影响桌面品牌。**unsigned Payload zip 是编译产物，不是可直接安装的已签名 IPA**，重命名扩展名也不会产生有效签名。

### 正式签名与分发

1. 在 macOS 的 Xcode 中打开 [Runner workspace](<../ios/Runner.xcworkspace/contents.xcworkspacedata>) 所在 workspace；选择 Runner → Signing & Capabilities。
2. 设置自己的 Apple Development Team，核对 Bundle ID，并使用与该标识匹配的证书和 provisioning profile。Debug、Release、Profile 的设置需要一致。
3. 真机调试使用开发 profile；Ad Hoc 使用包含目标设备的 profile；TestFlight / App Store 使用相应分发配置。组织内分发应使用对应组织计划与配置。
4. 重新构建并归档，让 Xcode 对应用、嵌入框架和所需 entitlements 一并签名，再由 Organizer 验证和导出；或在已配置签名的构建环境执行：

   ```bash
   flutter build ipa --release --export-options-plist=/path/to/ExportOptions.plist
   ```

5. 核验导出的签名和目标设备安装，再验收相机权限、局域网推送、凭据保存、后台切换、音画及真实源首帧。CI 不保存签名材料；证书/profile 不放进仓库。

发布时还应审核 HTTP 兼容需求和相机/局域网用途描述。后续若引入 iCloud、App Groups、Keychain Sharing 等额外 capability，需要同步更新 entitlements 与 provisioning profile；当前默认凭据存储仅使用应用自己的系统存储范围。

## 权限、网络与品牌

- [Info.plist](<../ios/Runner/Info.plist>) 提供中文相机用途说明及局域网推送说明；没有相册写入或麦克风访问需求，未添加这些权限。无权限时仍可手动输入订阅。
- 用户订阅和媒体可能使用明文 HTTP，因此 ATS 开启 `NSAllowsArbitraryLoads`。这只放宽 URL transport 的协议要求，不关闭 HTTPS 证书校验，不配置例外 CA；正式发布需按实际内容源评估 HTTP 使用并向分发渠道说明。
- iOS 的 system local-network 权限或 Windows 防火墙可能影响主动开启的局域网推送；应用内 loopback 请求与局域网入口分开管理。
- Windows EXE 元数据、窗口标题、ICO、iOS 桌面名称、全部 AppIcon 和 launch images 均使用流光品牌。iOS AppIcon 输出为无 alpha 的 RGB PNG，Windows ICO 包含 16/24/32/48/64/128/256 像素图层。
- [图标生成脚本](<../.github/scripts/generate-platform-icons.py>) 从 [品牌图标](<../assets/brand/liuguang-icon.png>) 和 [品牌标识](<../assets/brand/liuguang-mark.png>) 重建平台资源；可选执行 `python -m pip install Pillow` 后运行 `python .github/scripts/generate-platform-icons.py`。CI 直接使用已提交资源，不要求 Pillow。

## 本次验证边界

本地 Windows 主机没有 MSVC/macOS，已执行的检查仅包括工程配置与图标静态校验、工作流及脚本语法检查、Windows 打包脚本的合成目录回归。Windows C++ 编译、iOS CocoaPods/Xcode 编译与签名导出应以 GitHub Actions 和真机验收结果为准。新增 workflow 不会自行发布 release 或安装产物。
