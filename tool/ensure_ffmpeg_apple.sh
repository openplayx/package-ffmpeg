#!/usr/bin/env bash
# Builds the pinned FFmpeg for an Apple platform when missing or stale (the
# first build takes minutes). Called by the podspecs at `pod install` (with
# the platform as argument) and by their Xcode build phase (PLATFORM_NAME).
#   macOS: both architectures as shared libraries, wrapped as universal
#          xcframeworks in macos/Frameworks (tool/make_apple_frameworks.sh).
#   iOS/tvOS: static libraries for the architectures being linked.
set -euo pipefail
root="$(cd "$(dirname "$0")/.." && pwd)"
platform_name="${1:-${PLATFORM_NAME:-macosx}}"
case "$platform_name" in
  macos|macosx) prefix=macos ;;
  iphoneos) prefix=ios ;;
  iphonesimulator) prefix=ios-sim ;;
  appletvos) prefix=tvos ;;
  appletvsimulator) prefix=tvos-sim ;;
  *) echo "unsupported platform $platform_name" >&2; exit 1 ;;
esac
archs="${ARCHS:-arm64}"
library=libavformat.a
if [ "$prefix" = macos ]; then archs="arm64 x86_64"; library=libavformat.dylib; fi
for arch in $archs; do
  target="$prefix-$arch"
  expected="$(bash "$root/tool/build_fingerprint.sh" "$target")"
  stamp="$root/third_party/ffmpeg/$target/BUILD_FINGERPRINT"
  if [ ! -e "$root/third_party/ffmpeg/$target/lib/$library" ] || [ ! -f "$stamp" ] || [ "$(cat "$stamp")" != "$expected" ]; then
    # Xcode's environment would leak SDK settings into FFmpeg's configure.
    env -i PATH="/usr/bin:/bin:/usr/sbin:/sbin:/opt/homebrew/bin:/usr/local/bin" \
      HOME="$HOME" DEVELOPER_DIR="${DEVELOPER_DIR:-}" \
      bash "$root/tool/build_ffmpeg.sh" "$target"
  fi
done
if [ "$prefix" = macos ]; then
  bash "$root/tool/make_apple_frameworks.sh" macos
fi
