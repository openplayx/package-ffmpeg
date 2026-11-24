#!/usr/bin/env bash
# Wraps the shared FFmpeg libraries of one Apple platform as xcframeworks, so
# the app embeds a single FFmpeg that both opx_media and libmpv (package-media)
# link against.
#
#   tool/make_apple_frameworks.sh macos
#
# Input:  third_party/ffmpeg/macos-{arm64,x86_64}/lib/lib<name>.<major>.dylib
#         (built by build_ffmpeg.sh with --install-name-dir=@rpath)
# Output: macos/Frameworks/<Name>.xcframework (git-ignored), universal binary,
#         install names @rpath/<Name>.framework/Versions/A/<Name>
set -euo pipefail
platform="${1:?usage: make_apple_frameworks.sh macos}"
root="$(cd "$(dirname "$0")/.." && pwd)"
case "$platform" in
  macos) targets=(macos-arm64 macos-x86_64); min=12.0 ;;
  *) echo "unsupported platform $platform" >&2; exit 1 ;;
esac
libs=(avutil swresample swscale avcodec avformat avfilter)
name() { local l="$1"; case "$l" in sw*) echo "Sw${l#sw}" ;; av*) echo "Av${l#av}" ;; esac; }
out="$root/$platform/Frameworks"
stamp="$out/.fingerprint"
fingerprint="$(for t in "${targets[@]}"; do cat "$root/third_party/ffmpeg/$t/BUILD_FINGERPRINT"; done; cat "$0")"
if [ -f "$stamp" ] && [ "$(cat "$stamp")" = "$fingerprint" ]; then
  echo "FFmpeg $platform frameworks are current"
  exit 0
fi
work="$root/third_party/ffmpeg/frameworks/$platform"
rm -rf "$work" "$out"
mkdir -p "$work" "$out"

# lib<name>.<major>.dylib of the first target defines the install names to map.
first="$root/third_party/ffmpeg/${targets[0]}/lib"
declare -a changes=()
for l in "${libs[@]}"; do
  file="$(cd "$first" && ls "lib$l".[0-9]*.dylib | awk -F. 'NF==3' | head -1)"
  [ -n "$file" ] || { echo "missing lib$l in $first" >&2; exit 1; }
  n="$(name "$l")"
  changes+=(-change "@rpath/$file" "@rpath/$n.framework/Versions/A/$n")
done

for l in "${libs[@]}"; do
  n="$(name "$l")"
  fw="$work/$n.framework"
  mkdir -p "$fw/Versions/A/Resources"
  inputs=()
  for t in "${targets[@]}"; do
    dir="$root/third_party/ffmpeg/$t/lib"
    inputs+=("$dir/$(cd "$dir" && ls "lib$l".[0-9]*.dylib | awk -F. 'NF==3' | head -1)")
  done
  lipo -create "${inputs[@]}" -output "$fw/Versions/A/$n"
  install_name_tool -id "@rpath/$n.framework/Versions/A/$n" "${changes[@]}" "$fw/Versions/A/$n"
  version="$(sed -n 's/^version=//p' "$root/third_party/ffmpeg/${targets[0]}/BUILDINFO")"
  cat > "$fw/Versions/A/Resources/Info.plist" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
<key>CFBundleExecutable</key><string>$n</string>
<key>CFBundleIdentifier</key><string>org.openplayx.ffmpeg.$l</string>
<key>CFBundleName</key><string>$n</string>
<key>CFBundlePackageType</key><string>FMWK</string>
<key>CFBundleShortVersionString</key><string>$version</string>
<key>CFBundleVersion</key><string>$version</string>
<key>LSMinimumSystemVersion</key><string>$min</string>
</dict></plist>
EOF
  ln -s A "$fw/Versions/Current"
  ln -s "Versions/Current/$n" "$fw/$n"
  ln -s Versions/Current/Resources "$fw/Resources"
  codesign --force --sign - "$fw/Versions/A/$n" >/dev/null 2>&1
  xcodebuild -create-xcframework -framework "$fw" -output "$out/$n.xcframework" >/dev/null
done
printf '%s\n' "$fingerprint" > "$stamp"
echo "FFmpeg $platform frameworks in $out"
# OPX_NATIVE_BUILD_HELPER: invoked by ensure_ffmpeg_apple.sh and the podspec.
