cmake_minimum_required(VERSION 3.10)
set(PROJECT_NAME "openplayx_ffmpeg")
project(${PROJECT_NAME} LANGUAGES C CXX)
add_subdirectory("${CMAKE_CURRENT_SOURCE_DIR}/../src" "${CMAKE_CURRENT_BINARY_DIR}/shared")
# The FFmpeg DLLs (when built) ship next to the bridge.
set(openplayx_ffmpeg_bundled_libraries $<TARGET_FILE:openplayx_ffmpeg> ${OPX_FFMPEG_RUNTIME_DLLS} PARENT_SCOPE)
