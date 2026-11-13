#!/usr/bin/env bash
# Builds the pinned, feature-trimmed LGPL FFmpeg static libraries used by the
# in-process media bridge. Never downloads executables at app runtime and
# never builds ffmpeg/ffprobe programs.
#
#   tool/build_ffmpeg.sh <target>
#
# targets: macos-arm64 macos-x86_64 ios-arm64 ios-sim-arm64
#          android-arm64-v8a android-armeabi-v7a android-x86_64
#          linux-x86_64 linux-arm64
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
demuxers=mov,matroska,avi,mpegts,mpegps,flv,asf,wav,mp3,aac,flac,ogg,h264,hevc
decoders=h264,hevc,mpeg4,mpeg2video,mpeg1video,vp8,vp9,vc1,wmv3,msmpeg4v3,mjpeg,png,aac,aac_latm,ac3,eac3,mp3,mp2,flac,opus,vorbis,dca,truehd,alac,wmav2,pcm_s16le,pcm_s24le,pcm_f32le
encoders=png,mjpeg,aac,pcm_s16le,mpeg4
muxers=mp4,ipod,matroska,wav,mp3,flac
parsers=h264,hevc,aac,mpegaudio,ac3,flac,vp8,vp9,mpeg4video,mpegvideo,vc1,opus,vorbis,dca,mjpeg,png
bsfs=aac_adtstoasc,h264_mp4toannexb,hevc_mp4toannexb,extract_extradata,vp9_superframe
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
  --enable-avformat --enable-avcodec --enable-swscale --enable-swresample
  --enable-network
  --enable-demuxer="$demuxers" --enable-decoder="$decoders"
  --enable-encoder="$encoders" --enable-muxer="$muxers"
  --enable-parser="$parsers" --enable-bsf="$bsfs"
  --enable-protocol="$protocols"
)
extra=()
case "$target" in
  macos-*|ios-*)
    arch="${target##*-}"
    case "$target" in
      macos-*) sdk=macosx; min="-mmacosx-version-min=12.0" ;;
      ios-sim-*) sdk=iphonesimulator; min="-mios-simulator-version-min=15.0" ;;
      ios-*) sdk=iphoneos; min="-miphoneos-version-min=15.0" ;;
    esac
    sysroot="$(xcrun --sdk "$sdk" --show-sdk-path)"
    cc="$(xcrun --sdk "$sdk" -f clang)"
    flags="-arch $arch -isysroot $sysroot $min"
    extra+=(--enable-cross-compile --target-os=darwin --arch="$arch" --cc="$cc"
      --extra-cflags="$flags" --extra-ldflags="$flags"
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
      --extra-ldflags="-Wl,-z,max-page-size=16384"
      --enable-jni --enable-mediacodec --enable-encoder=h264_mediacodec)
    [ "$arch" = x86_64 ] && extra+=(--disable-x86asm)
    ;;
  linux-*)
    command -v nasm >/dev/null || extra+=(--disable-x86asm)
    ;;
  *) echo "unknown target $target" >&2; exit 1 ;;
esac

build="$work/build/$target"
rm -rf "$build" "$prefix"
mkdir -p "$build"
cd "$build"
"$src/configure" "${common[@]}" "${extra[@]}" > configure.log
make -j"$(sysctl -n hw.ncpu 2>/dev/null || nproc)" > make.log
make install > install.log
{
  echo "version=$FFMPEG_VERSION"
  echo "sha256=$FFMPEG_SHA256"
  echo "target=$target"
  echo "configure=${common[*]} ${extra[*]}"
} > "$prefix/BUILDINFO"
echo "FFmpeg $FFMPEG_VERSION installed to $prefix"
