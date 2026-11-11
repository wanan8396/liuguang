# flutter_js 0.8.7 (pinned subset)

Upstream: https://pub.dev/packages/flutter_js/versions/0.8.7
Source: https://github.com/abner/flutter_js
License: MIT (see LICENSE).

Only lib/, assets/, Windows and iOS platform files are retained. The Android
plugin is intentionally absent: Liuguang keeps its existing Kotlin/FongMi engine
and does not pull the upstream plugin's obsolete Android Gradle dependencies.
No changes are made to the retained upstream Dart/native runtime sources.

Windows ships the upstream x64 quickjs_c_bridge.dll, copied by its CMake install
rule. iOS uses the system JavaScriptCore framework. Application-level timeouts
and cancellation use dedicated worker isolates rather than the UI thread.
The host timeout bounds waiting, not arbitrary synchronous native execution:
infinite JS loops are not guaranteed to stop when isolate cancellation is requested.
