# Third-party provenance and reproducibility

## Native host

GPLv3 host API sources adapted from:

- Project: https://github.com/FongMi/TV
- Fixed commit: `5e191aaced194e5cac5668cc91908ecb65336222`
- Source archive: https://github.com/FongMi/TV/archive/5e191aaced194e5cac5668cc91908ecb65336222.zip
- Traditional Spider ABI reference: `4d7e16fa237dbea5f5f066429d31b94a5b037301`

Adapted source is committed in `android/source_engine/src/main`. Runtime adapters are part of this project's GPLv3 source. Changes and component licenses are listed in `THIRD_PARTY_NOTICES`.

## QuickJS matched artifact pair

The Java wrapper and ARM native libraries are derived from the same fixed TV commit:

https://github.com/FongMi/TV/tree/5e191aaced194e5cac5668cc91908ecb65336222/quickjs/libs

| Artifact | SHA-256 |
|---|---|
| wrapper JAR | `fde3c352bd4285682da071c998b65dd08a04901b072c390bf4f3b53e2db33ea2` |
| ARM64 library | `6c66fb84471c8b3e6ad3501e7457c6209fbfeef75d966bd3ec2bd2940a1ad516` |
| ARMv7 library | `a474c8b38d8bd0a9a886b49f270172cabb655fbf712536fa8566f4fb1563d154` |

Source project: https://github.com/FongMi/QuickJS (MIT, with separately preserved dependency notices). **The TV artifact metadata does not identify an exact native source revision.** This repository records the original artifacts and hashes, not a claim that an arbitrary QuickJS commit reproduces them. Full native reproducibility remains an open verification item. ARM-only libraries are not evidence of x86 compatibility.

## drpy

- Project: https://github.com/hjdhnx/dr_py
- Fixed commit: `ca23ffdbf5e429c5893ac60158668fc5af7af192`
- Source archive: https://github.com/hjdhnx/dr_py/archive/ca23ffdbf5e429c5893ac60158668fc5af7af192.zip
- Root license: LGPLv3. Upstream README badge differs; the root license and preserved per-file notices are the basis of this record, not a definitive legal conclusion about all upstream components.

Imported JS engine/libraries and host adapter source are included as editable assets. Preserve their notices and LGPL replacement/source obligations when distributing modifications.

## Portable Windows/iOS JavaScript runtime

- Upstream package: [flutter_js 0.8.7](https://pub.dev/packages/flutter_js/versions/0.8.7), [source project](https://github.com/abner/flutter_js).
- Fixed local subset: [package manifest](<../third_party/flutter_js/pubspec.yaml>), [patch/provenance note](<../third_party/flutter_js/LIUGUANG-PATCHES.md>), [MIT license](<../third_party/flutter_js/LICENSE>). Only the upstream Dart/assets and Windows/iOS platform files are retained; Android/macOS/Linux plugin declarations and Android Gradle dependencies are omitted. The retained upstream runtime implementation is unchanged; application bridging is maintained in this project.
- Windows uses the upstream x64 [QuickJS bridge DLL](<../third_party/flutter_js/windows/shared/quickjs_c_bridge.dll>), SHA-256 `e2051274a1d7599d131d45b96c7cc53519a9009bf43a802b922f73031d3d3b4b`. Its CMake rule installs it into the complete release bundle. The fixed package version and checked-in binary establish artifact identity, not proof of a reproducible build from an exact underlying QuickJS source revision.
- iOS uses Apple's system JavaScriptCore through [the native podspec](<../third_party/flutter_js/ios/flutter_js.podspec>); it does not ship the Android QuickJS libraries. macOS-hosted CI tests exercise the system JavaScriptCore FFI runtime, while the iOS application is separately compiled with Xcode.
- Android continues using the original Kotlin/JAR/QuickJS implementation described above; adding this subset does not replace its native engine or add the old upstream Flutter Android plugin.
- JS requests run in dedicated worker isolates; synchronous `req` bridges to asynchronous HTTP(S) via loopback. Timeouts/cancellation dispose workers. This is runtime lifecycle management, not process isolation for untrusted code.
- The per-release Windows/iOS packages include the upstream MIT text as `flutter_js-LICENSE.txt`, alongside this project's license and third-party notices.

## Native WebView player-page discovery

- [flutter_inappwebview 6.1.5](https://pub.dev/packages/flutter_inappwebview/versions/6.1.5), Windows implementation 0.6.0 and iOS implementation 1.1.2, pinned with their pub.dev hashes in `pubspec.lock`. Upstream source: https://github.com/pichillilorenzo/flutter_inappwebview (Apache-2.0); Flutter's generated license registry carries package notices.
- Windows uses installed Microsoft Edge WebView2 Runtime with headless WebView2 and CDP request/response observations. C++ plugin builds fetch the NuGet versions declared by the package: WebView2 SDK 1.0.2792.45, WIL 1.0.231216.1 and nlohmann/json 3.11.2. A system runtime is still required after copying the application bundle.
- iOS uses WKWebView in WebKit. The application-scoped cookie-store adapter targets only the marked headless view, rather than copying secrets into the global persistent WK cookie jar.
- Controlled integration fixtures execute delayed page JavaScript and inspect actual native network observations; ordinary Dart mocks prove lifecycle only. See platform CI for runtime test results.

## Media and build dependencies

Flutter packages are recorded in `pubspec.lock`. media_kit's Dart wrapper is MIT; its libmpv/FFmpeg binaries have additional licenses and source/relinking requirements. Their build provenance is provided by:

- https://github.com/media-kit/media-kit
- https://github.com/media-kit/libmpv-android-video-build

Android dependencies are explicit in the Gradle module. OkHttp must be the **Android** variant; a JVM-only artifact does not carry Android platform adapters.

GitHub Actions are pinned to commit hashes. CI uses no account credentials and produces development-signed Android APKs, unsigned Windows x64 bundles and unsigned iOS arm64 Payload archives, not a signed production release. Windows packaging includes the release MSVC runtime via CMake's `InstallRequiredSystemLibraries`; those Microsoft DLLs retain their applicable Visual Studio redistribution terms. iOS uses CocoaPods with an iOS 15 deployment target and Flutter SwiftPM integration disabled for the current podspec-based plugins. Xcode/CocoaPods follow the hosted runner image; each run records their versions and uploads the resolved pod lockfiles. Native build/download provenance and signing requirements are detailed in the [platform guide](<PLATFORMS.md>).
