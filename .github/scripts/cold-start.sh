#!/usr/bin/env bash
set -euo pipefail
: "${1:?Usage: cold-start.sh APK_PATH [ARTIFACT_DIRECTORY]}"
apk="$1"
out="${2:-artifacts/startup}"
package='cn.liuguang.tvbox'
activity="$package/.MainActivity"
mkdir -p "$out"
collect() {
  adb logcat -d -v threadtime > "$out/logcat.txt" 2>&1 || true
  adb logcat -b crash -d > "$out/crash.txt" 2>&1 || true
  adb shell dumpsys activity activities > "$out/activities.txt" 2>&1 || true
  adb shell dumpsys package "$package" > "$out/package.txt" 2>&1 || true
  adb exec-out screencap -p > "$out/screenshot.png" 2>/dev/null || true
}
trap collect EXIT
adb wait-for-device
adb install -r "$apk"
adb shell am force-stop "$package"
adb logcat -c
adb logcat -b crash -c
adb shell am start -W -n "$activity" | tee "$out/launch.txt"
first_frame=0
for attempt in $(seq 1 30); do
  if adb logcat -d -s LiuguangStartup:I '*:S' | grep -q flutter_first_frame; then
    first_frame=1
    break
  fi
  if adb logcat -b crash -d | grep -Eq "Process: $package|>>> $package <<<"; then
    printf 'Cold-start failed: crash buffer names the app.\n' >&2
    exit 1
  fi
  sleep 2
done
if [[ "$first_frame" != 1 ]]; then
  printf 'Cold-start failed: Flutter first-frame marker was not observed.\n' >&2
  exit 1
fi
first_pid="$(adb shell pidof "$package" | tr -d '\r')"
if [[ -z "$first_pid" ]]; then
  printf 'Cold-start failed: process absent after first frame.\n' >&2
  exit 1
fi
sleep 30
last_pid="$(adb shell pidof "$package" | tr -d '\r')"
if [[ "$last_pid" != "$first_pid" ]]; then
  printf 'Cold-start failed: process exited or restarted during stability window.\n' >&2
  exit 1
fi
adb shell dumpsys activity activities > "$out/activities.txt"
if ! grep -E 'mResumedActivity|topResumedActivity|ResumedActivity' "$out/activities.txt" | grep -q "$package"; then
  printf 'Cold-start failed: app is not the resumed activity.\n' >&2
  exit 1
fi
adb shell uiautomator dump /sdcard/liuguang-startup.xml >/dev/null
adb pull /sdcard/liuguang-startup.xml "$out/ui.xml"
if grep -q '启动失败' "$out/ui.xml"; then
  printf 'Cold-start failed: startup-error UI displayed.\n' >&2
  exit 1
fi
if ! grep -Eq '首页|电视|我的' "$out/ui.xml"; then
  printf 'Cold-start failed: home navigation not present in accessibility tree.\n' >&2
  exit 1
fi
adb logcat -b crash -d > "$out/crash.txt"
if grep -Eq "Process: $package|>>> $package <<<" "$out/crash.txt"; then
  printf 'Cold-start failed: app crash recorded.\n' >&2
  exit 1
fi
printf 'PASS: complete release APK reached Flutter first frame and home navigation; stable PID for 30 seconds.\n' | tee "$out/result.txt"
