# 接口助手直播接入与搜索并发

- APK SHA-256: `116caaa3fb0d37d1773e7ad761b886aeaed772d2350da16df57983cdbb213ab0`。原APK未修改。
- 直播页点击“接口助手直播源”，可选15组列表，默认不自动启用，可添加推荐2组。保留已有TVBox lives和独立订阅，直连优先、候选失败切换。第三方代理在界面注明。
- 首页右上角“播放历史”打开已有历史/续播页面；没有重复建立历史数据库。
- 搜索并发8/16/32可选，默认16，重启保留；单源30秒超时、取消和迟到结果隔离。原生线程池16；同会话插件锁仍保留，因此32个UI任务不代表32个原生插件同时执行。超时不保证底层请求立即终止。
- 加载中改变订阅会开始新代次，旧结果不能覆盖新状态。

## 验证边界

本机 Dart 3.13.7 arm64语法解析及git diff --check通过。四个公开直播列表GET返回200，但未验证媒体播放。Flutter分析、离线测试、原生测试和APK构建交由Android CI执行；尚未实机验收，不应将列表可获取当作频道可播。

## 回归

```sh
flutter pub get --enforce-lockfile
flutter analyze --no-pub
flutter test --no-pub
flutter build apk --release --split-per-abi --target-platform android-arm64
```

实机检查：无订阅时选择助手直播源；切换频道；已有TVBox动态源不受影响；右上角历史可打开并续播；超过16源搜索可取消；修改并发后重启保留。
