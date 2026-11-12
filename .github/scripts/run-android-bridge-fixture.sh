#!/usr/bin/env bash
set -euo pipefail
: "${ANDROID_SDK_ROOT:?Android SDK is required}"
project_root="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/../.." && pwd -P)"
cd "$project_root"
work="$(mktemp -d "${TMPDIR:-/tmp}/liuguang-bridge.XXXXXXXX")"
trap 'rm -rf -- "$work"' EXIT
# The DEX fixture is authored in this repo and rebuilt by build-fixture.sh.
python3 - "$work/defines.json" <<'PY'
import base64, json, pathlib, sys
fixture = pathlib.Path('android/source_engine/src/androidTest/assets/controlled.png')
if not fixture.is_file():
    raise SystemExit('Controlled DEX fixture must be rebuilt before this test')
pathlib.Path(sys.argv[1]).write_text(json.dumps({
    'CONTROLLED_DEX_BASE64': base64.b64encode(fixture.read_bytes()).decode('ascii')
}), encoding='utf-8')
PY
# CI emulator build deliberately omits ARM-only QuickJS, but retains DEX/ART.
export ORG_GRADLE_PROJECT_ciEmulator=true
flutter test integration_test/android_jar_bridge_test.dart -d emulator-5554 \
  --no-pub --dart-define-from-file="$work/defines.json" --timeout 180s
