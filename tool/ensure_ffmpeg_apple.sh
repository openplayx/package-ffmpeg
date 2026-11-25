#!/usr/bin/env bash
# Builds the pinned FFmpeg for an Apple platform when missing or stale (the
# first build takes minutes per slice): shared libraries for every slice,
# wrapped as xcframeworks in <platform>/Frameworks by make_apple_frameworks.sh.
# Called by the podspecs at `pod install` (platform argument) and by their
# Xcode build phase (PLATFORM_NAME).
set -euo pipefail
root="$(cd "$(dirname "$0")/.." && pwd)"
# One run at a time: the xcframeworks are rebuilt in place.
# Parallel callers (test processes running pod install or Gradle side by
# side) wait here; the next one then finds the build up to date. A lock left
# by a dead process is taken over.
lock="$root/third_party/.lock-frameworks"
mkdir -p "$root/third_party"
until mkdir "$lock" 2>/dev/null; do
  holder="$(cat "$lock/pid" 2>/dev/null || true)"
  if [ -n "$holder" ] && ! kill -0 "$holder" 2>/dev/null; then rm -rf "$lock"; continue; fi
  sleep 2
done
echo $$ > "$lock/pid"
trap 'rm -rf "$lock"' EXIT
platform_name="${1:-${PLATFORM_NAME:-macosx}}"
case "$platform_name" in
  macos|macosx) platform=macos; targets="macos-arm64 macos-x86_64" ;;
  ios|iphoneos|iphonesimulator) platform=ios; targets="ios-arm64 ios-sim-arm64 ios-sim-x86_64" ;;
  tvos|appletvos|appletvsimulator) platform=tvos; targets="tvos-arm64 tvos-sim-arm64" ;;
  *) echo "unsupported platform $platform_name" >&2; exit 1 ;;
esac
# Every slice of the platform: the xcframeworks exist before CocoaPods knows
# whether the app builds for a device or a simulator. CI release builds can
# limit them (e.g. OPX_FFMPEG_APPLE_TARGETS="ios-arm64" for a device archive).
[ -z "${OPX_FFMPEG_APPLE_TARGETS:-}" ] || targets="$OPX_FFMPEG_APPLE_TARGETS"
for target in $targets; do
  expected="$(bash "$root/tool/build_fingerprint.sh" "$target")"
  stamp="$root/third_party/ffmpeg/$target/BUILD_FINGERPRINT"
  if [ ! -e "$root/third_party/ffmpeg/$target/lib/libavformat.dylib" ] || [ ! -f "$stamp" ] || [ "$(cat "$stamp")" != "$expected" ]; then
    # Xcode's environment would leak SDK settings into FFmpeg's configure.
    env -i PATH="/usr/bin:/bin:/usr/sbin:/sbin:/opt/homebrew/bin:/usr/local/bin" \
      HOME="$HOME" DEVELOPER_DIR="${DEVELOPER_DIR:-}" \
      bash "$root/tool/build_ffmpeg.sh" "$target"
  fi
done
OPX_FFMPEG_APPLE_TARGETS="$targets" bash "$root/tool/make_apple_frameworks.sh" "$platform"
