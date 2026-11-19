# In-process FFmpeg bridge: compiles the opx_media C ABI and links the
# pinned, trimmed GPL FFmpeg static libraries into this plugin's framework.
# Only opx_media_* symbols are exported, so libav symbols cannot clash with
# libVLC's bundled copy.
Pod::Spec.new do |s|
  s.name = 'openplayx_ffmpeg'
  s.version = '0.1.0'
  s.summary = 'OpenPlayX in-process FFmpeg media processing'
  s.homepage = 'https://github.com/openplayx/package-ffmpeg'
  s.license = { :type => 'GPL-2.0-or-later' }
  s.author = 'OpenPlayX'
  s.source = { :path => '.' }
  s.source_files = 'Classes/**/*'
  s.ios.deployment_target = '15.0'
  s.dependency 'Flutter'
  s.frameworks = 'VideoToolbox', 'CoreMedia', 'CoreVideo', 'CoreFoundation', 'CoreServices', 'Security', 'AudioToolbox'
  s.libraries = 'z', 'c++'
  s.script_phase = {
    :name => 'Build pinned FFmpeg',
    :script => 'bash "${PODS_TARGET_SRCROOT}/../tool/ensure_ffmpeg_apple.sh"',
    :execution_position => :before_compile,
    :always_out_of_date => '1',
  }
  s.pod_target_xcconfig = {
    'DEFINES_MODULE' => 'YES',
    'LIBRARY_SEARCH_PATHS[sdk=iphoneos*]' => '"${PODS_TARGET_SRCROOT}/../third_party/ffmpeg/ios-arm64/lib"',
    'LIBRARY_SEARCH_PATHS[sdk=iphonesimulator*][arch=arm64]' => '"${PODS_TARGET_SRCROOT}/../third_party/ffmpeg/ios-sim-arm64/lib"',
    'LIBRARY_SEARCH_PATHS[sdk=iphonesimulator*][arch=x86_64]' => '"${PODS_TARGET_SRCROOT}/../third_party/ffmpeg/ios-sim-x86_64/lib"',
    'HEADER_SEARCH_PATHS[sdk=iphoneos*]' => '"${PODS_TARGET_SRCROOT}/../third_party/ffmpeg/ios-arm64/include"',
    'HEADER_SEARCH_PATHS[sdk=iphonesimulator*][arch=arm64]' => '"${PODS_TARGET_SRCROOT}/../third_party/ffmpeg/ios-sim-arm64/include"',
    'HEADER_SEARCH_PATHS[sdk=iphonesimulator*][arch=x86_64]' => '"${PODS_TARGET_SRCROOT}/../third_party/ffmpeg/ios-sim-x86_64/include"',
    'OTHER_LDFLAGS' => '-lavformat -lavcodec -lswscale -lswresample -lavutil -laom -lx264 -lx265 -lvpx -lmp3lame -lopus -lxml2 -Wl,-exported_symbols_list,"${PODS_TARGET_SRCROOT}/../src/exports.txt"',
    'GCC_SYMBOLS_PRIVATE_EXTERN' => 'YES',
    'WARNING_CFLAGS' => '-Wno-documentation',
  }
end
