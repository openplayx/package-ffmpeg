#!/usr/bin/env bash
# Wraps the shared FFmpeg libraries of one Apple platform as xcframeworks, so
# the app embeds a single FFmpeg that both opx_media and libmpv (package-media)
# link against.
#
#   tool/make_apple_frameworks.sh macos|ios|tvos
#
# Input:  third_party/ffmpeg/<target>/lib/lib<name>.<major>.dylib for every
#         target of the platform (built by build_ffmpeg.sh with
#         --install-name-dir=@rpath)
# Output: <platform>/Frameworks/<Name>.xcframework (git-ignored). Slices:
#         macos: universal arm64 + x86_64 (versioned framework bundle)
#         ios:   device arm64; simulator arm64 + x86_64 (flat bundles)
#         tvos:  device arm64; simulator arm64 (flat bundles)
set -euo pipefail
platform="${1:?usage: make_apple_frameworks.sh macos|ios|tvos}"
root="$(cd "$(dirname "$0")/.." && pwd)"
# slices: "name=target[+target...]"
case "$platform" in
  macos) slices=("macos=macos-arm64+macos-x86_64"); min=12.0; plist_min=LSMinimumSystemVersion ;;
  ios) slices=("device=ios-arm64" "simulator=ios-sim-arm64+ios-sim-x86_64"); min=15.0; plist_min=MinimumOSVersion ;;
  tvos) slices=("device=tvos-arm64" "simulator=tvos-sim-arm64"); min=15.0; plist_min=MinimumOSVersion ;;
  *) echo "unsupported platform $platform" >&2; exit 1 ;;
esac
# OPX_FFMPEG_APPLE_TARGETS limits the slices to the targets built.
if [ -n "${OPX_FFMPEG_APPLE_TARGETS:-}" ]; then
  kept=()
  for slice in "${slices[@]}"; do
    IFS=+ read -r -a ts <<< "${slice#*=}"
    sel=()
    for t in "${ts[@]}"; do [[ " $OPX_FFMPEG_APPLE_TARGETS " = *" $t "* ]] && sel+=("$t"); done
    [ ${#sel[@]} -eq 0 ] || kept+=("${slice%%=*}=$(IFS=+; echo "${sel[*]}")")
  done
  slices=("${kept[@]}")
fi
targets=()
for slice in "${slices[@]}"; do IFS=+ read -r -a ts <<< "${slice#*=}"; targets+=("${ts[@]}"); done
libs=(avutil swresample swscale avcodec avformat avfilter)
name() { local l="$1"; case "$l" in sw*) echo "Sw${l#sw}" ;; av*) echo "Av${l#av}" ;; esac; }
dylib() { (cd "$root/third_party/ffmpeg/$1/lib" && ls "lib$2".[0-9]*.dylib | awk -F. 'NF==3' | head -1); }
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
version="$(sed -n 's/^version=//p' "$root/third_party/ffmpeg/${targets[0]}/BUILDINFO")"
[ "$platform" = macos ] && sub=Versions/A/ || sub=''

# Install names of the libraries, mapped to framework paths.
changes=()
for l in "${libs[@]}"; do
  n="$(name "$l")"
  changes+=(-change "@rpath/$(dylib "${targets[0]}" "$l")" "@rpath/$n.framework/$sub$n")
done

for l in "${libs[@]}"; do
  n="$(name "$l")"
  args=()
  for slice in "${slices[@]}"; do
    IFS=+ read -r -a ts <<< "${slice#*=}"
    fw="$work/${slice%%=*}/$n.framework"
    mkdir -p "$fw/${sub}Resources"
    [ -n "$sub" ] || rmdir "$fw/Resources"
    inputs=()
    for t in "${ts[@]}"; do inputs+=("$root/third_party/ffmpeg/$t/lib/$(dylib "$t" "$l")"); done
    lipo -create "${inputs[@]}" -output "$fw/$sub$n"
    install_name_tool -id "@rpath/$n.framework/$sub$n" "${changes[@]}" "$fw/$sub$n"
    info="$fw/${sub:+${sub}Resources/}Info.plist"
    cat > "$info" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
<key>CFBundleExecutable</key><string>$n</string>
<key>CFBundleIdentifier</key><string>org.openplayx.ffmpeg.$l</string>
<key>CFBundleName</key><string>$n</string>
<key>CFBundlePackageType</key><string>FMWK</string>
<key>CFBundleShortVersionString</key><string>$version</string>
<key>CFBundleVersion</key><string>$version</string>
<key>$plist_min</key><string>$min</string>
</dict></plist>
PLIST
    if [ -n "$sub" ]; then
      ln -s A "$fw/Versions/Current"
      ln -s "Versions/Current/$n" "$fw/$n"
      ln -s Versions/Current/Resources "$fw/Resources"
    fi
    codesign --force --sign - "$fw/$sub$n" >/dev/null 2>&1
    args+=(-framework "$fw")
  done
  xcodebuild -create-xcframework "${args[@]}" -output "$out/$n.xcframework" >/dev/null
done
printf '%s\n' "$fingerprint" > "$stamp"
echo "FFmpeg $platform frameworks in $out"
# OPX_NATIVE_BUILD_HELPER: invoked by ensure_ffmpeg_apple.sh and the podspecs.
