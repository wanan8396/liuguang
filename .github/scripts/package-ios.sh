#!/usr/bin/env bash
set -euo pipefail

app="${1:-build/ios/iphoneos/Runner.app}"
output="${2:-artifacts/ios}"
for required in Info.plist Frameworks/Flutter.framework/Flutter Frameworks/App.framework/App Frameworks/App.framework/flutter_assets; do
  test -e "$app/$required" || { echo "Incomplete iOS release: missing $required" >&2; exit 1; }
done
executable=$(/usr/libexec/PlistBuddy -c 'Print CFBundleExecutable' "$app/Info.plist")
test -f "$app/$executable"
xcrun lipo -archs "$app/$executable" | tr ' ' '\n' | grep -qx arm64
if codesign --verify "$app" >/dev/null 2>&1; then
  echo 'Expected an unsigned application from flutter build ios --no-codesign' >&2
  exit 1
fi

mkdir -p "$output"
output="$(cd "$output" && pwd)"
archive="$output/liuguang-ios-arm64-unsigned.zip"
stage=$(mktemp -d "${TMPDIR:-/tmp}/liuguang-ios-package.XXXXXX")
trap 'rm -rf "$stage"' EXIT
mkdir -p "$stage/Payload"
# ditto preserves framework symlinks; zip -y keeps them as symlinks in the archive.
ditto "$app" "$stage/Payload/Runner.app"
cp LICENSE THIRD_PARTY_NOTICES "$stage/"
cp third_party/flutter_js/LICENSE "$stage/flutter_js-LICENSE.txt"
cp docs/PLATFORMS.md "$stage/PLATFORMS.md"
{
  printf 'commit=%s\nplatform=ios-arm64\nmode=release\nflutter=%s\nsigning=unsigned-no-codesign\nreal-source-playback=not-tested\n' \
    "${GITHUB_SHA:-local-unrecorded}" "${FLUTTER_VERSION:-see toolchain output}"
  printf '\nUnsigned Payload/Runner.app; not an installable signed IPA.\n'
  printf 'Sign and export with an Apple team and matching provisioning profile before device installation.\n'
  xcodebuild -version
  pod --version
  /usr/libexec/PlistBuddy -c 'Print CFBundleIdentifier' "$app/Info.plist"
  /usr/libexec/PlistBuddy -c 'Print MinimumOSVersion' "$app/Info.plist"
} > "$stage/BUILD.txt"
cp "$stage/BUILD.txt" "$output/BUILD.txt"
xcrun otool -L "$app/$executable" > "$output/native-dependencies.txt"
# Remove an old archive first: zip updates otherwise retain stale entries.
rm -f "$archive"
(cd "$stage" && /usr/bin/zip -q -r -y "$archive" Payload BUILD.txt LICENSE THIRD_PARTY_NOTICES flutter_js-LICENSE.txt PLATFORMS.md)
(cd "$output" && shasum -a 256 liuguang-ios-arm64-unsigned.zip > SHA256SUMS.txt)
unzip -Z1 "$archive" > "$output/archive-contents.txt"
grep -q '^Payload/Runner.app/Info.plist$' "$output/archive-contents.txt"
printf 'Packaged unsigned iOS release: %s\n' "$archive"
