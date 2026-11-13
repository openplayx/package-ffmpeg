/// In-process FFmpeg media processing for OpenPlayX.
///
/// Dart → FFI → the package's own `opx_media_*` C ABI → FFmpeg libraries.
/// No ffmpeg/ffprobe executable, child process or command string is used.
library;

export 'src/models.dart';
export 'src/presets.dart';
export 'src/processor.dart' show MediaProcessor, MediaJob;
