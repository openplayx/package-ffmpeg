cmake_minimum_required(VERSION 3.10)
set(PROJECT_NAME "openplayx_ffmpeg")
project(${PROJECT_NAME} LANGUAGES C)
add_subdirectory("${CMAKE_CURRENT_SOURCE_DIR}/../src" "${CMAKE_CURRENT_BINARY_DIR}/shared")
# The bridge and the shared FFmpeg (lib/, next to it): the app's one FFmpeg,
# also used by package-media's libmpv.
set(openplayx_ffmpeg_bundled_libraries $<TARGET_FILE:openplayx_ffmpeg> ${OPX_FFMPEG_RUNTIME_LIBS} PARENT_SCOPE)
