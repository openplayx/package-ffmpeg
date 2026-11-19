#!/usr/bin/env bash
# Xcode build phase: builds the pinned FFmpeg for each arch being linked,
# only when its static libraries are missing (first build takes minutes).
set -euo pipefail
root="$(cd "$(dirname "$0")/.." && pwd)"
case "${PLATFORM_NAME:-macosx}" in
  macosx) prefix=macos ;;
  iphoneos) prefix=ios ;;
  iphonesimulator) prefix=ios-sim ;;
  *) echo "unsupported platform $PLATFORM_NAME" >&2; exit 1 ;;
esac
for arch in ${ARCHS:-arm64}; do
  target="$prefix-$arch"
  expected="$(bash "$root/tool/build_fingerprint.sh" "$target")"
  stamp="$root/third_party/ffmpeg/$target/BUILD_FINGERPRINT"
  if [ ! -f "$root/third_party/ffmpeg/$target/lib/libavformat.a" ] || [ ! -f "$stamp" ] || [ "$(cat "$stamp")" != "$expected" ]; then
    # Xcode's environment would leak SDK settings into FFmpeg's configure.
    env -i PATH="/usr/bin:/bin:/usr/sbin:/sbin:/opt/homebrew/bin:/usr/local/bin" \
      HOME="$HOME" DEVELOPER_DIR="${DEVELOPER_DIR:-}" \
      bash "$root/tool/build_ffmpeg.sh" "$target"
  fi
done
