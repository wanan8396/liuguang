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

## Media and build dependencies

Flutter packages are recorded in `pubspec.lock`. media_kit's Dart wrapper is MIT; its libmpv/FFmpeg binaries have additional licenses and source/relinking requirements. Their build provenance is provided by:

- https://github.com/media-kit/media-kit
- https://github.com/media-kit/libmpv-android-video-build

Android dependencies are explicit in the Gradle module. OkHttp must be the **Android** variant; a JVM-only artifact does not carry Android platform adapters.

GitHub Actions are pinned to commit hashes. CI uses no account credentials and only creates development-signed APK artifacts, not a production release.
