# Shared by Android, Linux and Windows. Links the pinned FFmpeg static
# libraries from tool/build_ffmpeg.sh when present; otherwise builds the
# stub so the host app still builds and reports the module as unavailable.
cmake_minimum_required(VERSION 3.10)
project(openplayx_ffmpeg_library VERSION 0.1.0 LANGUAGES C CXX)

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

file(GLOB OPX_FFMPEG_WINDOWS_DLLS "${OPX_FFMPEG_PREFIX}/bin/*.dll")
if(WIN32 AND OPX_FFMPEG_WINDOWS_DLLS)
  # FFmpeg DLLs built with MinGW-w64 (tool/build_ffmpeg.sh windows-x86_64); this
  # MSVC-built bridge links their import libraries, and the DLLs are bundled next
  # to the app (see windows/CMakeLists.txt).
  add_library(openplayx_ffmpeg SHARED "opx_media.c")
  target_include_directories(openplayx_ffmpeg PRIVATE "${OPX_FFMPEG_PREFIX}/include")
  foreach(lib avformat avcodec swscale swresample avutil)
    if(EXISTS "${OPX_FFMPEG_PREFIX}/lib/${lib}.lib")
      target_link_libraries(openplayx_ffmpeg PRIVATE "${OPX_FFMPEG_PREFIX}/lib/${lib}.lib")
    else()
      target_link_libraries(openplayx_ffmpeg PRIVATE "${OPX_FFMPEG_PREFIX}/lib/lib${lib}.dll.a")
    endif()
  endforeach()
  get_directory_property(OPX_FFMPEG_HAS_PARENT PARENT_DIRECTORY)
  if(OPX_FFMPEG_HAS_PARENT)
    set(OPX_FFMPEG_RUNTIME_DLLS ${OPX_FFMPEG_WINDOWS_DLLS} PARENT_SCOPE)
  endif()
elseif(NOT WIN32 AND EXISTS "${OPX_FFMPEG_PREFIX}/lib/libavformat.a")
  add_library(openplayx_ffmpeg SHARED "opx_media.c")
  target_include_directories(openplayx_ffmpeg PRIVATE "${OPX_FFMPEG_PREFIX}/include")
  set(libs avformat avcodec swscale swresample avutil aom x264 x265 vpx mp3lame opus xml2)
  foreach(lib ${libs})
    target_link_libraries(openplayx_ffmpeg PRIVATE "${OPX_FFMPEG_PREFIX}/lib/lib${lib}.a")
  endforeach()
  target_link_libraries(openplayx_ffmpeg PRIVATE z m)
  set_target_properties(openplayx_ffmpeg PROPERTIES LINKER_LANGUAGE CXX)
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
