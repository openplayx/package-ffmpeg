#!/usr/bin/env bash
# Builds the bridge as a plain shared library for `flutter test` on the
# development machine (macOS/Linux). Output: build/host/libopenplayx_ffmpeg.*
set -euo pipefail
root="$(cd "$(dirname "$0")/.." && pwd)"
case "$(uname -s)-$(uname -m)" in
  Darwin-arm64) target=macos-arm64 ;;
  Darwin-x86_64) target=macos-x86_64 ;;
  Linux-x86_64) target=linux-x86_64 ;;
  Linux-aarch64) target=linux-arm64 ;;
  *) echo "unsupported host" >&2; exit 1 ;;
esac
prefix="$root/third_party/ffmpeg/$target"
bash "$root/tool/build_ffmpeg.sh" "$target"
mkdir -p "$root/build/host"
libs="-L$prefix/lib -lavformat -lavcodec -lswscale -lswresample -lavutil -laom -lx264 -lx265 -lvpx -lmp3lame -lopus -lxml2 -lz"
if [ "$(uname -s)" = Darwin ]; then
  # macOS FFmpeg is shared (see build_ffmpeg.sh): link the dylibs, found at
  # run time through the build prefix.
  libs="-L$prefix/lib -lavformat -lavcodec -lswscale -lswresample -lavutil -Wl,-rpath,$prefix/lib"
  out="$root/build/host/libopenplayx_ffmpeg.dylib"
  clang -O2 -Wall -fvisibility=hidden -shared -I"$prefix/include" \
    "$root/src/opx_media.c" $libs \
    -framework VideoToolbox -framework CoreMedia -framework CoreVideo \
    -framework CoreFoundation -framework CoreServices -framework Security \
    -framework AudioToolbox -lc++ \
    -Wl,-exported_symbols_list,"$root/src/exports.txt" -o "$out"
else
  out="$root/build/host/libopenplayx_ffmpeg.so"
  cc -O2 -Wall -fPIC -fvisibility=hidden -shared -I"$prefix/include" \
    "$root/src/opx_media.c" $libs -lm -lpthread -lstdc++ \
    -Wl,--version-script="$root/src/exports.map" -Wl,-Bsymbolic -o "$out"
fi
echo "$out"
