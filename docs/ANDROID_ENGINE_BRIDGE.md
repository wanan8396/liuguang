# Windows / iOS 使用 Android JAR 引擎

## 两种不同能力

- **本机 JS**：Windows QuickJS / iOS JavaScriptCore 运行单文件 JS，或从 JAR 显式入口提取的 JS；不需要手机。
- **Android DEX/JAR**：完整 CatVod JAR、其 Android API / JNI 和 type=2/3 解析依赖 Android。Windows / iOS 通过同网 Android 的流光引擎服务调用，不在本机安装 Java 就能获得 Android ABI。

## 连接步骤

1. Android 和 Windows / iPhone 都安装此版本，连接同一个 Wi-Fi。
2. Android 打开“我的流光 → Android 引擎连接”，显式启动服务。复制显示的局域网地址和完整临时令牌。
3. Windows / iPhone 打开同一入口，填写地址、令牌，测试并保存。连接保存在系统加密凭据存储中，不进入普通备份。
4. 回到视频订阅，选择原来的 `csp_*` JAR 站点；首页、分类、搜索、详情、播放会话由手机执行，媒体通过只属于该会话的流式路径传回。
5. Android 保持服务页面前台。离开页面、切后台、停止服务或 10 分钟无请求会结束服务，全部会话与媒体路径随之失效。重新开启会生成新令牌，另一端需更新。

这是需要两台设备的显式连接；应用不自动搜索局域网，不默认监听。HTTP 局域网连接为明文，只在自己的网络使用。地址仅接受私有/loopback IPv4 HTTP(S) origin，服务 token 只放 Authorization header，不放 URL。媒体 URL 使用随机短期 capability，不是 token；请把它也视为临时秘密。

## 流式与生命周期

- RPC 只允许已定义的方法，JSON 请求/结果各 2 MiB；服务 40 秒、客户端 45 秒请求等待期限。
- Android 原生解析器已返回的本机媒体地址被映射为 `/media/<opaque>`；客户端不提交任意远端地址给网关。
- 视频不整段缓冲；Range、HEAD、Content-Range 等保留。HLS 的子清单、密钥和分片只重写已确认的原生代理 origin 地址。
- 切换连接、取消请求、停止服务和退出应用会回收会话；迟到的初始化结果会关闭。
- Cookie/Token、插件窗口和设备权限仍属于 Android 侧。可能要在手机处理插件登录或弹窗。

## JAR 内嵌 JS 发布格式

无 Android 设备时，可把单文件 JS 放在归档中，用 UTF-8 `META-INF/liuguang.json` 明确映射：

```json
{
  "version": 1,
  "spiders": {
    "csp_Example": { "entry": "spiders/example.js" },
    "csp_Other": { "entry": "spiders/other.js" }
  }
}
```

站点 `api` 精确匹配映射 key。入口应是归档内普通相对 `.js` 路径；不支持 `..`、绝对路径、多文件 import 或外部入口。无 manifest 时仅兼容根目录 `spider.js`。有 manifest 却没有当前站点时直接报错，不猜测其他 JS。`spider.json` 可用相同版本化映射格式作为兼容入口；普通 descriptor 只是元数据，不作为源码。

支持 stored/deflate 和 data descriptor。中央目录、local header、CRC、条目重叠及解压限额都会检查。归档限 8 MiB / 2048 项，单项展开限 8 MiB，总展开限 32 MiB，JS 限 4 MiB；不支持分卷、ZIP64、加密归档。`site.jar` 优先于仓库 `spider`，支持相对 URL 和 `;md5;<32位hex或HTTP(S)校验文件>`。

## 验证层级

离线 HTTP Stub 覆盖认证、RPC、HLS、Range、超时和撤销，不等同于执行真实 DEX。CI 另外从仓库 Java 源码重建受控 DEX，在 Android 模拟器上跑 HTTP → Pigeon → DexClassLoader → fixture → HTTP 的整链测试；Windows/iOS 使用同一个 Dart RPC 客户端。测试不下载第三方订阅 JAR，不承诺任意插件兼容。
