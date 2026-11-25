#!/usr/bin/env bash
# Cross-build static PIC codec libraries for the same target as FFmpeg.
# No host Homebrew codec libraries can leak into mobile builds.
set -euo pipefail
target="${1:?target required}"
root="$(cd "$(dirname "$0")/.." && pwd)"
work="$root/third_party/deps"
prefix="$work/$target"
fingerprint="$(bash "$root/tool/build_fingerprint.sh" "$target")"
if [ -f "$prefix/BUILD_FINGERPRINT" ] && [ "$(cat "$prefix/BUILD_FINGERPRINT")" = "$fingerprint" ]; then
  exit 0
fi
command -v cmake >/dev/null || { echo 'cmake is required' >&2; exit 1; }
command -v meson >/dev/null || { echo 'meson is required (dav1d)' >&2; exit 1; }
command -v pkg-config >/dev/null || { echo 'pkg-config is required' >&2; exit 1; }
jobs="${OPX_BUILD_JOBS:-$(sysctl -n hw.ncpu 2>/dev/null || getconf _NPROCESSORS_ONLN)}"
mkdir -p "$work/downloads" "$prefix/lib/pkgconfig"
cmake_args=(-DCMAKE_BUILD_TYPE=Release -DCMAKE_POLICY_VERSION_MINIMUM=3.5
  -DCMAKE_INSTALL_PREFIX="$prefix" -DCMAKE_INSTALL_LIBDIR=lib
  -DCMAKE_POSITION_INDEPENDENT_CODE=ON -DBUILD_SHARED_LIBS=OFF)
cc=cc; cxx=c++; ar=ar; ranlib=ranlib; cflags=-fPIC; ldflags=''
host=''; vpx_target=generic-gnu; x264_extra=()
# Meson (dav1d) cross description: system, CPU family and CPU.
meson_system=''; meson_family=''; meson_cpu=''; strip_tool=strip
case "$target" in
  macos-*|ios-*|tvos-*)
    arch="${target##*-}"
    case "$target" in
      macos-*) sdk=macosx; system=Darwin; min=12.0; deployment=-mmacosx-version-min=$min ;;
      tvos-sim-*) sdk=appletvsimulator; system=tvOS; min=15.0; deployment="-target $arch-apple-tvos$min-simulator" ;;
      tvos-*) sdk=appletvos; system=tvOS; min=15.0; deployment="-target $arch-apple-tvos$min" ;;
      ios-sim-*) sdk=iphonesimulator; system=iOS; min=15.0; deployment=-mios-simulator-version-min=$min ;;
      ios-*) sdk=iphoneos; system=iOS; min=15.0; deployment=-miphoneos-version-min=$min ;;
    esac
    sysroot="$(xcrun --sdk "$sdk" --show-sdk-path)"
    cc="$(xcrun --sdk "$sdk" -f clang)"; cxx="$(xcrun --sdk "$sdk" -f clang++)"
    ar="$(xcrun --sdk "$sdk" -f ar)"; ranlib="$(xcrun --sdk "$sdk" -f ranlib)"
    cflags="-fPIC -arch $arch -isysroot $sysroot $deployment"
    ldflags="$cflags"
    cmake_args+=(-DCMAKE_SYSTEM_NAME="$system" -DCMAKE_OSX_SYSROOT="$sysroot"
      -DCMAKE_OSX_ARCHITECTURES="$arch" -DCMAKE_OSX_DEPLOYMENT_TARGET="$min"
      -DCMAKE_C_COMPILER="$cc" -DCMAKE_CXX_COMPILER="$cxx")
    host="$arch-apple-darwin"
    [ "$arch" != arm64 ] || host=aarch64-apple-darwin
    strip_tool="$(xcrun --sdk "$sdk" -f strip)"
    meson_system=darwin; meson_cpu="$arch"
    if [ "$arch" = arm64 ]; then meson_family=aarch64; else meson_family=x86_64; fi
    # generic-gnu uses portable C; mobile builds must not invoke host assemblers.
    ;;
  android-*)
    abi="${target#android-}"
    ndk="${ANDROID_NDK_HOME:?set ANDROID_NDK_HOME}"
    tc="$ndk/toolchains/llvm/prebuilt/$(uname -s | tr A-Z a-z)-x86_64/bin"
    case "$abi" in
      arm64-v8a) triple=aarch64-linux-android; host=aarch64-linux-android ;;
      armeabi-v7a) triple=armv7a-linux-androideabi; host=arm-linux-androideabi ;;
      x86_64) triple=x86_64-linux-android; host=x86_64-linux-android ;;
      *) exit 1 ;;
    esac
    cc="$tc/${triple}24-clang"; cxx="$tc/${triple}24-clang++"
    ar="$tc/llvm-ar"; ranlib="$tc/llvm-ranlib"; strip_tool="$tc/llvm-strip"
    meson_system=android
    case "$abi" in
      arm64-v8a) meson_family=aarch64; meson_cpu=aarch64 ;;
      armeabi-v7a) meson_family=arm; meson_cpu=armv7 ;;
      x86_64) meson_family=x86_64; meson_cpu=x86_64 ;;
    esac
    ldflags='-Wl,-z,max-page-size=16384'
    cmake_args+=(-DCMAKE_TOOLCHAIN_FILE="$ndk/build/cmake/android.toolchain.cmake"
      -DANDROID_ABI="$abi" -DANDROID_PLATFORM=android-24 -DANDROID_STL=c++_static)
    ;;
  linux-*)
    # A matching native builder is required, as for the existing FFmpeg build.
    case "$target/$(uname -m)" in linux-arm64/aarch64|linux-arm64/arm64|linux-x86_64/x86_64) ;; *) echo "Use a native $target builder" >&2; exit 1 ;; esac
    ;;
  windows-x86_64)
    cc=gcc; cxx=g++; host=x86_64-w64-mingw32
    cmake_args+=(-G 'MSYS Makefiles' -DCMAKE_SYSTEM_NAME=Windows)
    ;;
  *) echo "unsupported target $target" >&2; exit 1 ;;
esac
export CC="$cc" CXX="$cxx" AR="$ar" RANLIB="$ranlib" CFLAGS="$cflags" CXXFLAGS="$cflags" LDFLAGS="$ldflags"
# Autoconf's preprocessing checks do not use CFLAGS. Apple SDK headers (and
# Android target headers) must also be visible to CPP, or LAME misdetects libc.
export CPP="$cc -E $cflags"
export PKG_CONFIG_LIBDIR="$prefix/lib/pkgconfig"
export PKG_CONFIG_PATH="$PKG_CONFIG_LIBDIR"
make_cmd=make
command -v make >/dev/null || make_cmd=mingw32-make
build_cmake() {
  cmake -S "$source_dir${1:-}" -B "$build_dir" "${cmake_args[@]}" "${@:2}"
  cmake --build "$build_dir" --parallel "$jobs"
  cmake --install "$build_dir"
}
common_recipe="$(sed '/^while read -r name checksum url; do/,$d' "$0")"
while read -r name checksum url; do
  [[ "$name" = \#* || -z "$name" ]] && continue
  archive="$work/downloads/$checksum.tar"
  if [ ! -f "$archive" ]; then
    curl -fL --retry 3 "$url" -o "$archive.part"
    mv "$archive.part" "$archive"
  fi
  actual="$(sha256sum "$archive" 2>/dev/null || shasum -a 256 "$archive")"
  [ "${actual%% *}" = "$checksum" ] || { echo "$name checksum mismatch" >&2; exit 1; }
  source_dir="$work/src/$target/$name"
  build_dir="$work/build/$target/$name"
  # Checkpoint each dependency separately. A recipe fix for one codec need
  # not recompile every other codec after a partial build failure.
  recipe="$(awk -v package="$name" '$0 ~ "^      " package "\\)" {copy=1} copy {print; if ($0 ~ /;;$/) exit}' "$0")"
  key="$(printf '%s\n' "$target" "$checksum" "$common_recipe" "$recipe" | { if command -v sha256sum >/dev/null; then sha256sum; else shasum -a 256; fi; } | cut -d ' ' -f 1)"
  if [ -f "$prefix/lib/lib$name.a" ] && [ -f "$build_dir/SUCCESS" ] && [ "$(cat "$build_dir/SUCCESS")" = "$key" ]; then continue; fi
  mkdir -p "$source_dir" "$build_dir"
  # A failed build is restarted from clean source, with logs kept per dependency.
  rm -rf "$source_dir" "$build_dir"
  mkdir -p "$source_dir" "$build_dir"
  tar xf "$archive" -C "$source_dir" --strip-components=1
  echo "Building $name for $target (log: $build_dir/build.log)"
  # Do not put this subshell on the left of ||: Bash would disable errexit
  # inside every configure/build function, hiding intermediate failures.
  set +e
  (
    set -e
    case "$name" in
      aom)
        # libaom 3.x moved aomenc/aomdec behind ENABLE_APPS; Apple targets
        # cannot install them as app bundles.
        build_cmake '' -DENABLE_DOCS=OFF -DENABLE_APPS=OFF -DENABLE_EXAMPLES=OFF -DENABLE_TESTS=OFF -DENABLE_TOOLS=OFF \
          -DCONFIG_PIC=1 -DAOM_TARGET_CPU=generic ;;
      opus)
        build_cmake '' -DOPUS_BUILD_PROGRAMS=OFF -DOPUS_BUILD_TESTING=OFF -DOPUS_INSTALL_PKG_CONFIG_MODULE=ON ;;
      xml2)
        build_cmake '' -DLIBXML2_WITH_PROGRAMS=OFF -DLIBXML2_WITH_TESTS=OFF \
          -DLIBXML2_WITH_PYTHON=OFF -DLIBXML2_WITH_ICONV=OFF -DLIBXML2_WITH_ICU=OFF \
          -DLIBXML2_WITH_LZMA=OFF -DLIBXML2_WITH_ZLIB=OFF -DLIBXML2_WITH_HTTP=OFF \
          -DLIBXML2_WITH_FTP=OFF ;;
      x265)
        # Upstream's explicit OLD policies were removed by CMake 4. Keep
        # this source adjustment reproducible with the pinned archive.
        sed -e 's/SET CMP0025 OLD/SET CMP0025 NEW/' -e 's/SET CMP0054 OLD/SET CMP0054 NEW/' \
          "$source_dir/source/CMakeLists.txt" > "$source_dir/source/CMakeLists.txt.patched"
        mv "$source_dir/source/CMakeLists.txt.patched" "$source_dir/source/CMakeLists.txt"
        build_cmake /source -DENABLE_SHARED=OFF -DENABLE_CLI=OFF -DENABLE_ASSEMBLY=OFF \
          -DENABLE_LIBNUMA=OFF -DENABLE_HDR10_PLUS=OFF
        case "$target" in
          android-*)
            # x265's old pkg-config generator prefixes NDK's -l:libunwind.a
            # twice and names a host libc++; use the actual static NDK runtime.
            sed 's/^Libs.private:.*/Libs.private: -lc++_static -lc++abi -lm -ldl/' \
              "$prefix/lib/pkgconfig/x265.pc" > "$build_dir/x265.pc"
            cp "$build_dir/x265.pc" "$prefix/lib/pkgconfig/x265.pc" ;;
        esac
        ;;
      vpx)
        cd "$build_dir"
        "$source_dir/configure" --prefix="$prefix" --target="$vpx_target" \
          --enable-pic --disable-shared --enable-static --disable-examples \
          --disable-tools --disable-docs --disable-unit-tests --enable-vp9-highbitdepth
        "$make_cmd" -j"$jobs"
        "$make_cmd" install ;;
      x264)
        cd "$source_dir"
        args=(--prefix="$prefix" --enable-static --enable-pic --disable-cli --disable-opencl --disable-asm)
        [ -z "$host" ] || args+=(--host="$host")
        ./configure "${args[@]}"
        "$make_cmd" -j"$jobs"
        "$make_cmd" install ;;
      dav1d)
        # AV1 decoding for playback (faster than libaom's decoder).
        args=(--prefix="$prefix" --libdir=lib --buildtype=release --default-library=static
          -Db_staticpic=true -Denable_tools=false -Denable_tests=false -Denable_examples=false)
        if [ -n "$meson_system" ]; then
          # Cross description instead of CFLAGS: meson ignores them for the host.
          quote() { local out='' w; for w in $1; do out="$out'$w', "; done; printf '[%s]' "${out%, }"; }
          {
            echo "[binaries]"
            echo "c = '$cc'"; echo "ar = '$ar'"; echo "strip = '$strip_tool'"; echo "pkg-config = 'pkg-config'"
            echo "[built-in options]"
            echo "c_args = $(quote "$cflags")"; echo "c_link_args = $(quote "$cflags $ldflags")"
            echo "[host_machine]"
            echo "system = '$meson_system'"; echo "cpu_family = '$meson_family'"
            echo "cpu = '$meson_cpu'"; echo "endian = 'little'"
          } > "$build_dir/cross.txt"
          args+=(--cross-file "$build_dir/cross.txt")
          unset CC CXX CFLAGS CXXFLAGS LDFLAGS CPP
        fi
        # x86 assembly needs nasm; without it dav1d uses its C code.
        case "$target" in *x86_64*) command -v nasm >/dev/null || args+=(-Denable_asm=false) ;; esac
        meson setup "$build_dir/meson" "$source_dir" "${args[@]}"
        meson compile -C "$build_dir/meson" -j "$jobs"
        meson install -C "$build_dir/meson" ;;
      openmpt)
        # Tracker modules (MOD, XM, IT, S3M, DMF, GDM, IMF, SFX ...) for
        # FFmpeg's libopenmpt demuxer. Only the library: no player, no
        # optional decoders for samples inside modules (zlib, mpg123, Ogg).
        cd "$build_dir"
        args=(--prefix="$prefix" --disable-shared --enable-static --with-pic --disable-dependency-tracking
          --disable-openmpt123 --disable-examples --disable-tests --disable-doxygen-doc
          --without-zlib --without-mpg123 --without-ogg --without-vorbis --without-vorbisfile
          --without-portaudio --without-portaudiocpp --without-pulseaudio --without-sndfile --without-flac)
        [ -z "$host" ] || args+=(--host="$host")
        "$source_dir/configure" "${args[@]}"
        "$make_cmd" -j"$jobs"
        "$make_cmd" install
        # Its pkg-config file leaves Libs.private empty: static links need
        # libm, and on Android NDK's static C++ runtime (as for x265).
        private=-lm
        case "$target" in android-*) private='-lc++_static -lc++abi -lm -ldl' ;; esac
        sed "s/^Libs.private:.*/Libs.private: $private/" "$prefix/lib/pkgconfig/libopenmpt.pc" > "$build_dir/libopenmpt.pc"
        cp "$build_dir/libopenmpt.pc" "$prefix/lib/pkgconfig/libopenmpt.pc" ;;
      gme)
        # Game console music (NSF, GYM, SPC, VGM, GBS, HES, KSS, SAP, AY) for
        # FFmpeg's libgme demuxer. Without zlib: no compressed VGZ.
        build_cmake '' -DGME_BUILD_SHARED=OFF -DGME_BUILD_STATIC=ON -DGME_BUILD_TESTING=OFF \
          -DGME_BUILD_EXAMPLES=OFF -DGME_ZLIB=OFF -DGME_ENABLE_UBSAN=OFF
        case "$target" in
          android-*)
            # Its pkg-config file names the shared C++ runtime (-lc++); use
            # NDK's static one, as for x265.
            sed 's/^Libs.private:.*/Libs.private: -lc++_static -lc++abi -lm -ldl/' "$prefix/lib/pkgconfig/libgme.pc" > "$build_dir/libgme.pc"
            cp "$build_dir/libgme.pc" "$prefix/lib/pkgconfig/libgme.pc" ;;
        esac
        ;;
      mp3lame)
        cd "$build_dir"
        # LAME 4 requires libmpg123 for its optional decoder; FFmpeg only uses
        # LAME to encode and decodes MP3 natively.
        args=(--prefix="$prefix" --disable-shared --enable-static --disable-frontend --disable-decoder
          --disable-analyzer-hooks --disable-dependency-tracking --with-pic)
        [ -z "$host" ] || args+=(--host="$host")
        "$source_dir/configure" "${args[@]}"
        "$make_cmd" -j"$jobs"
        "$make_cmd" install ;;
    esac
  ) > "$build_dir/build.log" 2>&1
  status=$?
  set -e
  if [ "$status" != 0 ]; then tail -60 "$build_dir/build.log" >&2; exit "$status"; fi
  printf '%s\n' "$key" > "$build_dir/SUCCESS"
done < "$root/tool/codec-deps.tsv"
if [[ "$target" = android-* ]]; then
  # Bionic supplies pthread in libc; older upstream .pc generators still
  # advertise a separate libpthread which does not exist in the Android NDK.
  for pc in "$prefix"/lib/pkgconfig/*.pc; do
    sed 's/ -lpthread//g' "$pc" > "$pc.patched"
    mv "$pc.patched" "$pc"
  done
fi
printf '%s\n' "$fingerprint" > "$prefix/BUILD_FINGERPRINT"
# OPX_NATIVE_BUILD_HELPER: invoked by build_ffmpeg.sh, not a standalone artifact.
