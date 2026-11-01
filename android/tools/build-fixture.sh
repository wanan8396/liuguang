#!/usr/bin/env bash
set -euo pipefail

# CI must first run :source_engine:compileDebugJavaWithJavac. The resulting
# host Spider classes are the API against which this controlled DEX is built.
: "${ANDROID_SDK_ROOT:?Set ANDROID_SDK_ROOT to the Android SDK}"
: "${JAVA_HOME:?Set JAVA_HOME to JDK 21}"

android_root="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd -P)"
project_root="$(dirname -- "$android_root")"
host_classes="$project_root/build/source_engine/intermediates/javac/debug/compileDebugJavaWithJavac/classes"
android_jar="$ANDROID_SDK_ROOT/platforms/android-36/android.jar"
d8="$ANDROID_SDK_ROOT/build-tools/${ANDROID_BUILD_TOOLS_VERSION:-36.0.0}/d8"
javac="$JAVA_HOME/bin/javac"
jar="$JAVA_HOME/bin/jar"
source="$android_root/tools/fixture-src/com/github/catvod/spider/Controlled.java"
output="$android_root/source_engine/src/androidTest/assets/controlled.png"

if [[ ! -f "$host_classes/com/github/catvod/crawler/Spider.class" ]]; then
  printf 'Missing compiled host classes: %s\nRun :source_engine:compileDebugJavaWithJavac first.\n' "$host_classes" >&2
  exit 1
fi
for file in "$android_jar" "$source"; do
  if [[ ! -f "$file" ]]; then
    printf 'Required file not found: %s\n' "$file" >&2
    exit 1
  fi
done
for executable in "$javac" "$jar" "$d8"; do
  if [[ ! -x "$executable" ]]; then
    printf 'Required executable not found: %s\n' "$executable" >&2
    exit 1
  fi
done

work="$(mktemp -d "${TMPDIR:-/tmp}/tvbox-fixture.XXXXXXXX")"
trap 'rm -rf -- "$work"' EXIT
mkdir -p "$work/classes"
"$javac" -source 8 -target 8 -classpath "$android_jar:$host_classes" -d "$work/classes" "$source"
"$jar" cf "$work/controlled-classes.jar" -C "$work/classes" .
"$d8" --min-api 24 --lib "$android_jar" --classpath "$host_classes" \
  --output "$work/controlled.zip" "$work/controlled-classes.jar"
mkdir -p "$(dirname -- "$output")"
cp -- "$work/controlled.zip" "$output"
sha256sum "$output"
