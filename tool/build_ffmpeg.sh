#!/usr/bin/env bash
# Builds the pinned, feature-trimmed GPL FFmpeg static libraries used by the
# in-process media bridge. Never downloads executables at app runtime and
# never builds ffmpeg/ffprobe programs.
#
#   tool/build_ffmpeg.sh <target>
#
# targets: macos-arm64 macos-x86_64 ios-arm64 ios-sim-arm64
#          android-arm64-v8a android-armeabi-v7a android-x86_64
#          linux-x86_64 linux-arm64
#          windows-x86_64  (MSYS2 bash/make + MinGW-w64 gcc; shared DLLs whose import
#                           libraries the MSVC-built plugin links, so C runtimes
#                           are never mixed inside one module)
#
# Output: third_party/ffmpeg/<target>/{include,lib}  (git-ignored)
set -euo pipefail

FFMPEG_VERSION=7.1.1
FFMPEG_SHA256=733984395e0dbbe5c046abda2dc49a5544e7e0e1e2366bba849222ae9e3a03b1
FFMPEG_URL="https://ffmpeg.org/releases/ffmpeg-${FFMPEG_VERSION}.tar.xz"

target="${1:?usage: build_ffmpeg.sh <target>}"
root="$(cd "$(dirname "$0")/.." && pwd)"
work="$root/third_party/ffmpeg"
src="$work/src/ffmpeg-$FFMPEG_VERSION"
prefix="$work/$target"
tarball="$work/src/ffmpeg-$FFMPEG_VERSION.tar.xz"
mkdir -p "$work/src"
fingerprint="$(bash "$root/tool/build_fingerprint.sh" "$target")"
if [ -f "$prefix/lib/libavformat.a" ] || [ -d "$prefix/bin" ]; then
  if [ -f "$prefix/BUILD_FINGERPRINT" ] && [ "$(cat "$prefix/BUILD_FINGERPRINT")" = "$fingerprint" ] && [ "${OPX_FFMPEG_FORCE_REBUILD:-0}" != 1 ]; then
    echo "FFmpeg $target is current"
    exit 0
  fi
fi
# All external codecs are pinned and built for this target, never discovered
# from the host's Homebrew installation. x264/x265 make this a GPL build.
bash "$root/tool/build_codec_deps.sh" "$target"
deps="$root/third_party/deps/$target"
export PKG_CONFIG_LIBDIR="$deps/lib/pkgconfig"
export PKG_CONFIG_PATH="$PKG_CONFIG_LIBDIR"

if [ ! -f "$tarball" ]; then
  curl -fL --retry 3 -o "$tarball.part" "$FFMPEG_URL"
  mv "$tarball.part" "$tarball"
fi
actual="$(shasum -a 256 "$tarball" 2>/dev/null || sha256sum "$tarball")"
if [ "${actual%% *}" != "$FFMPEG_SHA256" ]; then
  echo "FFmpeg tarball checksum mismatch" >&2
  exit 1
fi
if [ ! -d "$src" ]; then
  tar -xJf "$tarball" -C "$work/src"
fi

# Only what the implemented presets need. Keep this list in sync with
# lib/src/presets.dart; capabilities are discovered at runtime regardless.
demuxers=mov,matroska,avi,mpegts,mpegps,flv,asf,wav,mp3,aac,flac,ogg,h264,hevc,av1,ivf,dash
decoders=h264,hevc,mpeg4,mpeg2video,mpeg1video,vp8,vp9,libaom_av1,vc1,wmv3,msmpeg4v3,mjpeg,png,aac,aac_latm,ac3,eac3,mp3,mp2,flac,opus,vorbis,dca,truehd,alac,wmav2,pcm_s16le,pcm_s24le,pcm_f32le
encoders=png,mjpeg,aac,pcm_s16le,mpeg4,libx264,libx265,libaom_av1,libvpx_vp8,libvpx_vp9,libmp3lame,libopus
muxers=mp4,ipod,matroska,webm,wav,mp3,flac,ogg,opus,ivf,dash
parsers=h264,hevc,av1,aac,mpegaudio,ac3,flac,vp8,vp9,mpeg4video,mpegvideo,vc1,opus,vorbis,dca,mjpeg,png
bsfs=aac_adtstoasc,h264_mp4toannexb,hevc_mp4toannexb,av1_frame_merge,av1_frame_split,extract_extradata,vp9_superframe
# Loopback session streams only; the bridge additionally whitelists
# file/http/tcp per open and rejects non-loopback hosts.
protocols=file,http,tcp

common=(
  --prefix="$prefix"
  --enable-static --disable-shared --enable-pic
  --disable-programs --disable-doc --disable-debug
  --disable-autodetect --enable-zlib
  --disable-avdevice --disable-avfilter --disable-postproc
  --disable-everything
  --enable-gpl --enable-libaom --enable-libx264 --enable-libx265
  --enable-libvpx --enable-libmp3lame --enable-libopus --enable-libxml2
  --pkg-config-flags=--static
  --enable-avformat --enable-avcodec --enable-swscale --enable-swresample
  --enable-network
  --enable-demuxer="$demuxers" --enable-decoder="$decoders"
  --enable-encoder="$encoders" --enable-muxer="$muxers"
  --enable-parser="$parsers" --enable-bsf="$bsfs"
  --enable-protocol="$protocols"
)
extra=()
case "$target" in
  macos-*|ios-*|tvos-*)
    arch="${target##*-}"
    case "$target" in
      macos-*) sdk=macosx; min="-mmacosx-version-min=12.0" ;;
      tvos-sim-*) sdk=appletvsimulator; min="-target $arch-apple-tvos15.0-simulator" ;;
      tvos-*) sdk=appletvos; min="-target $arch-apple-tvos15.0" ;;
      ios-sim-*) sdk=iphonesimulator; min="-mios-simulator-version-min=15.0" ;;
      ios-*) sdk=iphoneos; min="-miphoneos-version-min=15.0" ;;
    esac
    sysroot="$(xcrun --sdk "$sdk" --show-sdk-path)"
    cc="$(xcrun --sdk "$sdk" -f clang)"
    flags="-arch $arch -isysroot $sysroot $min"
    extra+=(--enable-cross-compile --target-os=darwin --arch="$arch" --cc="$cc"
      --extra-cflags="$flags -I$deps/include" --extra-ldflags="$flags -L$deps/lib"
      --enable-videotoolbox --enable-encoder=h264_videotoolbox)
    [ "$arch" = x86_64 ] && ! command -v nasm >/dev/null && extra+=(--disable-x86asm)
    ;;
  android-*)
    abi="${target#android-}"
    ndk="${ANDROID_NDK_HOME:?set ANDROID_NDK_HOME}"
    tc="$ndk/toolchains/llvm/prebuilt/$(uname -s | tr A-Z a-z)-x86_64/bin"
    api=24
    case "$abi" in
      arm64-v8a) arch=aarch64; triple=aarch64-linux-android ;;
      armeabi-v7a) arch=arm; triple=armv7a-linux-androideabi ;;
      x86_64) arch=x86_64; triple=x86_64-linux-android ;;
      *) echo "unknown ABI $abi" >&2; exit 1 ;;
    esac
    # 16 KB page compatibility for Android 15+ devices.
    extra+=(--enable-cross-compile --target-os=android --arch="$arch"
      --cc="$tc/${triple}${api}-clang" --cxx="$tc/${triple}${api}-clang++"
      --ar="$tc/llvm-ar" --nm="$tc/llvm-nm" --ranlib="$tc/llvm-ranlib"
      --strip="$tc/llvm-strip"
      --extra-cflags="-I$deps/include" --extra-ldflags="-L$deps/lib -Wl,-z,max-page-size=16384" --extra-libs=-lc++_static
      --enable-jni --enable-mediacodec --enable-encoder=h264_mediacodec)
    [ "$arch" = x86_64 ] && extra+=(--disable-x86asm)
    ;;
  linux-*)
    extra+=(--extra-cflags="-I$deps/include" --extra-ldflags="-L$deps/lib" --extra-libs=-lstdc++)
    command -v nasm >/dev/null || extra+=(--disable-x86asm)
    ;;
  windows-x86_64)
    # zlib (PNG codecs) is not part of MinGW-w64: build a pinned static copy.
    ZLIB_VERSION=1.3.1
    ZLIB_SHA256=9a93b2b7dfdac77ceba5a558a580e74667dd6fede4585b91eefb60f03b72df23
    zlib_tar="$work/src/zlib-$ZLIB_VERSION.tar.gz"
    zlib_prefix="$work/build/zlib-$target"
    if [ ! -f "$zlib_prefix/lib/libz.a" ]; then
      [ -f "$zlib_tar" ] || curl -fL --retry 3 -o "$zlib_tar" \
        "https://github.com/madler/zlib/releases/download/v$ZLIB_VERSION/zlib-$ZLIB_VERSION.tar.gz"
      zsum="$(sha256sum "$zlib_tar" 2>/dev/null || shasum -a 256 "$zlib_tar")"
      [ "${zsum%% *}" = "$ZLIB_SHA256" ] || { echo "zlib tarball checksum mismatch" >&2; exit 1; }
      rm -rf "$work/build/zlib-src" && mkdir -p "$work/build/zlib-src"
      tar -xzf "$zlib_tar" -C "$work/build/zlib-src" --strip-components=1
      (cd "$work/build/zlib-src" && mingw32-make -f win32/Makefile.gcc libz.a >/dev/null &&
        mkdir -p "$zlib_prefix/lib" "$zlib_prefix/include" &&
        cp libz.a "$zlib_prefix/lib/" && cp zlib.h zconf.h "$zlib_prefix/include/")
    fi
    # Shared instead of static (see header); libgcc/winpthread linked in statically.
    common=("${common[@]/--enable-static/--disable-static}")
    common=("${common[@]/--disable-shared/--enable-shared}")
    # The native compiler needs C:/... paths; Git Bash tools keep /c/... paths.
    zlib_native="$zlib_prefix"
    command -v cygpath >/dev/null 2>&1 && zlib_native="$(cygpath -m "$zlib_prefix")"
    extra+=(--target-os=mingw32 --arch=x86_64 --cc=gcc
      --extra-cflags="-I$zlib_native/include -I$deps/include"
      --extra-ldflags="-L$zlib_native/lib -L$deps/lib -static-libgcc -static" --extra-libs=-lstdc++)
    command -v nasm >/dev/null || extra+=(--disable-x86asm)
    # Preferred: MSYS2 bash + make (FFmpeg's documented Windows setup). Without a
    # Unix make, mingw32-make is native and needs C:/... paths in the generated
    # Makefiles (configure derives its source path with pwd: rewritten afterwards).
    if ! command -v make >/dev/null 2>&1; then
      common=("${common[@]/--prefix=$prefix/--prefix=$(cygpath -m "$prefix")}")
      native_src="$(cygpath -m "$src")"
    fi
    ;;
  *) echo "unknown target $target" >&2; exit 1 ;;
esac
case "$target" in macos-*|ios-*|tvos-*) extra+=(--extra-libs=-lc++) ;; esac

build="$work/build/$target"
rm -rf "$build" "$prefix"
mkdir -p "$build"
cd "$build"
"$src/configure" "${common[@]}" "${extra[@]}" > configure.log
if [ -n "${native_src:-}" ]; then
  sed -i "s#$src#$native_src#g" Makefile ffbuild/config.mak
fi
make_cmd=make
command -v make >/dev/null 2>&1 || make_cmd=mingw32-make
"$make_cmd" -j"$(sysctl -n hw.ncpu 2>/dev/null || nproc)" > make.log
"$make_cmd" install > install.log
# Link entry points use one prefix on every platform. Preserve dependency
# sources/builds separately, but publish their static archives beside libav.
cp "$deps"/lib/*.a "$prefix/lib/"
{
  echo "version=$FFMPEG_VERSION"
  echo "sha256=$FFMPEG_SHA256"
  echo "target=$target"
  echo "configure=${common[*]} ${extra[*]}"
} > "$prefix/BUILDINFO"
printf '%s\n' "$fingerprint" > "$prefix/BUILD_FINGERPRINT"
echo "FFmpeg $FFMPEG_VERSION installed to $prefix"
