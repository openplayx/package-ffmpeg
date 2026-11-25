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

FFMPEG_VERSION=9.1
FFMPEG_SHA256=1a4d394ae63d190a526cd052eb4415c156b5c5e2df37efab41a7de0b8fde2433
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

# One FFmpeg for both users in the app: the media processing bridge
# (src/opx_media.c, presets in lib/src/presets.dart) and playback through
# libmpv (package-media). Playback needs every demuxer, decoder, parser,
# bitstream filter, protocol and filter; processing adds the encoders and
# muxers its presets use. x264/x265 make this a GPL build. AV1 is decoded by
# dav1d; libaom stays for encoding only.
encoders=png,mjpeg,aac,pcm_s16le,mpeg4,libx264,libx265,libaom_av1,libvpx_vp8,libvpx_vp9,libmp3lame,libopus
muxers=mp4,ipod,matroska,webm,wav,mp3,flac,ogg,opus,ivf,dash

common=(
  --prefix="$prefix"
  --enable-static --disable-shared --enable-pic
  --disable-programs --disable-doc --disable-debug
  --disable-autodetect --enable-zlib
  --disable-avdevice --disable-indevs --disable-outdevs
  --enable-avfilter
  --enable-gpl --enable-libaom --enable-libdav1d --enable-libx264 --enable-libx265
  --enable-libvpx --enable-libmp3lame --enable-libopus --enable-libxml2
  --pkg-config-flags=--static
  --enable-network
  --disable-decoder=libaom_av1
  --disable-encoders --enable-encoder="$encoders"
  --disable-muxers --enable-muxer="$muxers"
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
      --enable-videotoolbox --enable-audiotoolbox --enable-securetransport
      --enable-encoder=h264_videotoolbox)
    case "$target" in
      macos-*|ios-*|tvos-*)
        # Shared libraries, one copy in the app for opx_media and libmpv;
        # tool/make_apple_frameworks.sh wraps them as frameworks.
        common=("${common[@]/--enable-static/--disable-static}")
        common=("${common[@]/--disable-shared/--enable-shared}")
        # Room for make_apple_frameworks.sh to rewrite the install names.
        extra+=(--install-name-dir=@rpath --extra-ldflags=-Wl,-headerpad_max_install_names) ;;
    esac
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
    # Shared libraries (unversioned sonames on Android), one copy in the APK
    # for opx_media and libmpv; staged into <prefix>/jniLibs/<abi>.
    common=("${common[@]/--enable-static/--disable-static}")
    common=("${common[@]/--disable-shared/--enable-shared}")
    ;;
  linux-*)
    extra+=(--extra-cflags="-I$deps/include" --extra-ldflags="-L$deps/lib" --extra-libs=-lstdc++)
    command -v nasm >/dev/null || extra+=(--disable-x86asm)
    # Shared libraries bundled next to the app (lib/), one copy for opx_media
    # and libmpv; they find each other through $ORIGIN (set with patchelf
    # below: configure would expand a $ORIGIN passed in LDFLAGS).
    command -v patchelf >/dev/null || { echo 'patchelf is required for Linux' >&2; exit 1; }
    common=("${common[@]/--enable-static/--disable-static}")
    common=("${common[@]/--disable-shared/--enable-shared}")
    ;;
  windows-x86_64)
    # zlib (PNG codecs) is not part of MinGW-w64: build a pinned static copy.
    ZLIB_VERSION=1.4
    ZLIB_SHA256=02dd159783677a749c04adbdd02b55b8a2bcc7e054f51b76b549199a916ad584
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
    # Shared instead of static (see header). libgcc, libstdc++ and winpthread
    # are linked in statically, by name: a global -static would also make the
    # linker take static archives for FFmpeg's own libraries (-lavutil) and
    # find another FFmpeg's in MinGW's lib directory (MSYS2's ffmpeg package).
    # FFmpeg uses Win32 threads (its usual MinGW setup). The codec
    # dependencies still ask for -lpthread (x265's pkg-config, libstdc++),
    # which MinGW resolves to winpthread's DLL import library. A static copy
    # named libpthread.a in the first -L directory is found before it.
    cp "$(gcc -print-file-name=libwinpthread.a)" "$zlib_prefix/lib/libpthread.a"
    common=("${common[@]/--enable-static/--disable-static}")
    common=("${common[@]/--disable-shared/--enable-shared}")
    # The native compiler needs C:/... paths; Git Bash tools keep /c/... paths.
    zlib_native="$zlib_prefix"
    command -v cygpath >/dev/null 2>&1 && zlib_native="$(cygpath -m "$zlib_prefix")"
    extra+=(--target-os=mingw32 --arch=x86_64 --cc=gcc --disable-pthreads --enable-w32threads
      --extra-cflags="-I$zlib_native/include -I$deps/include"
      --extra-ldflags="-L$zlib_native/lib -L$deps/lib -static-libgcc"
      --extra-libs="-Wl,-Bstatic -lstdc++ -Wl,-Bdynamic -lpthread")
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
if [[ "$target" = linux-* ]]; then
  # Real files named by soname (not symlinks), bundled into the app's lib/
  # by linux/CMakeLists.txt.
  rm -rf "$prefix/bundle" && mkdir -p "$prefix/bundle"
  for lib in avutil swresample swscale avcodec avformat avfilter; do
    soname="$(cd "$prefix/lib" && ls "lib$lib.so".[0-9]* | awk -F. 'NF==3' | head -1)"
    cp -L "$prefix/lib/$soname" "$prefix/bundle/$soname"
    patchelf --set-rpath '$ORIGIN' "$prefix/bundle/$soname"
  done
fi
if [[ "$target" = android-* ]]; then
  # Packaged by android/build.gradle (jniLibs). Inside the prefix, so CI caches
  # of third_party/ffmpeg/<target> restore them too.
  jni="$prefix/jniLibs/${target#android-}"
  rm -rf "$jni" && mkdir -p "$jni"
  for lib in avutil swresample swscale avcodec avformat avfilter; do
    cp "$prefix/lib/lib$lib.so" "$jni/"
  done
fi
printf '%s\n' "$fingerprint" > "$prefix/BUILD_FINGERPRINT"
echo "FFmpeg $FFMPEG_VERSION installed to $prefix"
