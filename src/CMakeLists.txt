# Shared by Android, Linux and Windows. Links the pinned FFmpeg static
# libraries from tool/build_ffmpeg.sh when present; otherwise builds the
# stub so the host app still builds and reports the module as unavailable.
cmake_minimum_required(VERSION 3.10)
project(openplayx_ffmpeg_library VERSION 0.1.0 LANGUAGES C)

if(ANDROID)
  set(OPX_FFMPEG_TARGET "android-${ANDROID_ABI}")
elseif(WIN32)
  set(OPX_FFMPEG_TARGET "windows-x86_64")
elseif(CMAKE_SYSTEM_PROCESSOR MATCHES "aarch64|arm64")
  set(OPX_FFMPEG_TARGET "linux-arm64")
else()
  set(OPX_FFMPEG_TARGET "linux-x86_64")
endif()
set(OPX_FFMPEG_PREFIX "${CMAKE_CURRENT_SOURCE_DIR}/../third_party/ffmpeg/${OPX_FFMPEG_TARGET}"
    CACHE PATH "Pinned FFmpeg install prefix")

if(EXISTS "${OPX_FFMPEG_PREFIX}/lib/libavformat.a")
  add_library(openplayx_ffmpeg SHARED "opx_media.c")
  target_include_directories(openplayx_ffmpeg PRIVATE "${OPX_FFMPEG_PREFIX}/include")
  set(libs avformat avcodec swscale swresample avutil)
  foreach(lib ${libs})
    target_link_libraries(openplayx_ffmpeg PRIVATE "${OPX_FFMPEG_PREFIX}/lib/lib${lib}.a")
  endforeach()
  target_link_libraries(openplayx_ffmpeg PRIVATE z m)
  if(ANDROID)
    target_link_libraries(openplayx_ffmpeg PRIVATE log mediandk android)
    target_link_options(openplayx_ffmpeg PRIVATE "-Wl,-z,max-page-size=16384")
  else()
    target_link_libraries(openplayx_ffmpeg PRIVATE pthread)
  endif()
  if(NOT WIN32)
    # Keep libav symbols private (no clash with libVLC's copy).
    target_link_options(openplayx_ffmpeg PRIVATE
      "-Wl,--version-script=${CMAKE_CURRENT_SOURCE_DIR}/exports.map"
      "-Wl,-Bsymbolic")
  endif()
else()
  message(WARNING "openplayx_ffmpeg: no FFmpeg at ${OPX_FFMPEG_PREFIX}; building unavailable stub")
  add_library(openplayx_ffmpeg SHARED "opx_media_stub.c")
endif()
set_target_properties(openplayx_ffmpeg PROPERTIES
  OUTPUT_NAME "openplayx_ffmpeg" C_VISIBILITY_PRESET hidden)
target_compile_definitions(openplayx_ffmpeg PUBLIC DART_SHARED_LIB)
