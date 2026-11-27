# In-process FFmpeg bridge: compiles the opx_media C ABI against the pinned
# GPL FFmpeg. FFmpeg is one set of shared frameworks (tvos/Frameworks) that
# the app embeds once; package-media's libmpv links the same frameworks.
# package-libvlc's source-built VLCKit links them too. The frameworks (device and
# simulator slices) must exist before CocoaPods integrates them, so they are
# built at `pod install`.
system('bash', File.join(File.realpath(__dir__), '..', 'tool', 'ensure_ffmpeg_apple.sh'), 'tvos') ||
  raise('Building FFmpeg for tvos failed (tool/ensure_ffmpeg_apple.sh tvos)')

Pod::Spec.new do |s|
  s.name = 'openplayx_ffmpeg'
  s.version = '0.1.0'
  s.summary = 'OpenPlayX in-process FFmpeg media processing'
  s.homepage = 'https://github.com/openplayx/package-ffmpeg'
  s.license = { :type => 'GPL-2.0-or-later' }
  s.author = 'OpenPlayX'
  s.source = { :path => '.' }
  s.source_files = 'Classes/**/*'
  s.tvos.deployment_target = '15.0'
  s.frameworks = 'VideoToolbox', 'CoreMedia', 'CoreVideo', 'CoreFoundation', 'Security', 'AudioToolbox'
  s.libraries = 'z', 'c++'
  s.vendored_frameworks = 'Frameworks/*.xcframework'
  s.script_phase = {
    :name => 'Check pinned FFmpeg',
    :script => 'bash "${PODS_TARGET_SRCROOT}/../tool/ensure_ffmpeg_apple.sh"',
    :execution_position => :before_compile,
    :always_out_of_date => '1',
  }
  s.pod_target_xcconfig = {
    'DEFINES_MODULE' => 'YES',
    'FRAMEWORK_SEARCH_PATHS' => '$(inherited) "${PODS_ROOT}/../Flutter"',
    # Headers are identical across slices.
    'HEADER_SEARCH_PATHS[sdk=appletvos*]' => '"${PODS_TARGET_SRCROOT}/../third_party/ffmpeg/tvos-arm64/include"',
    'HEADER_SEARCH_PATHS[sdk=appletvsimulator*]' => '"${PODS_TARGET_SRCROOT}/../third_party/ffmpeg/tvos-sim-arm64/include"',
    # Vendored frameworks are only searched for this target: link them.
    'OTHER_LDFLAGS' => '-framework Avformat -framework Avcodec -framework Avfilter -framework Swscale -framework Swresample -framework Avutil -Wl,-exported_symbols_list,"${PODS_TARGET_SRCROOT}/../src/exports.txt"',
    'GCC_SYMBOLS_PRIVATE_EXTERN' => 'YES',
    'WARNING_CFLAGS' => '-Wno-documentation',
  }
end
