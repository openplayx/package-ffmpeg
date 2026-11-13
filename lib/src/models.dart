/// Error categories surfaced to hosts. Hosts map them to user/model text;
/// no raw FFmpeg log, path or media content is ever attached.
enum MediaErrorCode {
  invalidArgument(false),
  inputUnavailable(true),
  inputUnsupported(false),
  encoderUnavailable(false),
  presetIncompatible(false),
  noSpace(true),
  nativeFailure(true),
  timeout(true),
  cancelled(true),
  accessDenied(false),
  interrupted(true),
  unavailable(false);

  const MediaErrorCode(this.retryable);
  final bool retryable;

  static MediaErrorCode fromNative(int code) => switch (code) {
    1 => invalidArgument,
    2 => inputUnavailable,
    3 => inputUnsupported,
    4 => encoderUnavailable,
    5 => presetIncompatible,
    6 => noSpace,
    8 => timeout,
    9 => cancelled,
    10 => accessDenied,
    _ => nativeFailure,
  };
}

class MediaException implements Exception {
  const MediaException(this.code, [this.reason]);
  final MediaErrorCode code;

  /// Short machine-readable detail such as `hdr_not_supported`.
  final String? reason;
  @override
  String toString() =>
      'MediaException(${code.name}${reason == null ? '' : ': $reason'})';
}

class MediaStreamInfo {
  MediaStreamInfo.fromJson(Map<String, dynamic> j)
    : index = j['index'] as int,
      type = j['type'] as String,
      codec = j['codec'] as String,
      decodable = j['decodable'] as bool? ?? false,
      durationUs = j['duration_us'] as int? ?? 0,
      width = j['width'] as int? ?? 0,
      height = j['height'] as int? ?? 0,
      fpsNum = j['fps_num'] as int? ?? 0,
      fpsDen = j['fps_den'] as int? ?? 0,
      avgFpsNum = j['avg_fps_num'] as int? ?? 0,
      avgFpsDen = j['avg_fps_den'] as int? ?? 0,
      rotation = j['rotation'] as int? ?? 0,
      attachedPicture = j['attached_pic'] as bool? ?? false,
      colorTransfer = j['color_transfer'] as String? ?? 'unknown',
      pixelFormat = j['pixel_format'] as String? ?? 'unknown',
      sampleRate = j['sample_rate'] as int? ?? 0,
      channels = j['channels'] as int? ?? 0,
      language = j['language'] as String? ?? '',
      title = j['title'] as String? ?? '',
      isDefault = j['default'] as bool? ?? false;

  final int index;
  final String type;
  final String codec;
  final bool decodable;
  final int durationUs;
  final int width, height;
  final int fpsNum, fpsDen, avgFpsNum, avgFpsDen;
  final int rotation;
  final bool attachedPicture;
  final String colorTransfer;
  final String pixelFormat;
  final int sampleRate, channels;
  final String language;
  final String title;
  final bool isDefault;

  bool get isVideo => type == 'video' && !attachedPicture;
  bool get isAudio => type == 'audio';
  bool get isSubtitle => type == 'subtitle';
  bool get isHdr =>
      colorTransfer == 'smpte2084' || colorTransfer == 'arib-std-b67';
  double get fps => fpsDen == 0 ? 0 : fpsNum / fpsDen;

  /// Variable frame rate heuristic: real and average rates disagree.
  bool get variableFrameRate {
    if (fpsDen == 0 || avgFpsDen == 0 || avgFpsNum == 0) return false;
    final avg = avgFpsNum / avgFpsDen;
    return (fps - avg).abs() / fps > 0.05;
  }
}

class MediaProbe {
  MediaProbe.fromJson(Map<String, dynamic> j)
    : container = j['container'] as String? ?? '',
      durationUs = j['duration_us'] as int? ?? 0,
      bitRate = j['bit_rate'] as int? ?? 0,
      streams = [
        for (final s in j['streams'] as List? ?? const [])
          MediaStreamInfo.fromJson(s as Map<String, dynamic>),
      ];
  final String container;
  final int durationUs;
  final int bitRate;
  final List<MediaStreamInfo> streams;

  Duration? get duration =>
      durationUs > 0 ? Duration(microseconds: durationUs) : null;
  Iterable<MediaStreamInfo> get video => streams.where((s) => s.isVideo);
  Iterable<MediaStreamInfo> get audio => streams.where((s) => s.isAudio);
  Iterable<MediaStreamInfo> get subtitles => streams.where((s) => s.isSubtitle);

  MediaStreamInfo? stream(int index) =>
      streams.where((s) => s.index == index).firstOrNull;

  /// The default/first decodable video (cover art excluded).
  MediaStreamInfo? get primaryVideo =>
      video.where((s) => s.decodable && s.isDefault).firstOrNull ??
      video.where((s) => s.decodable).firstOrNull;

  MediaStreamInfo? get primaryAudio =>
      audio.where((s) => s.isDefault).firstOrNull ?? audio.firstOrNull;
}

class MediaCapabilities {
  MediaCapabilities.fromJson(Map<String, dynamic> j)
    : available = j['available'] as bool? ?? true,
      ffmpegVersion = j['ffmpeg'] as String? ?? '',
      encoders = {...(j['encoders'] as List? ?? const []).cast<String>()},
      muxers = {...(j['muxers'] as List? ?? const []).cast<String>()},
      decoders = {...(j['decoders'] as List? ?? const []).cast<String>()};
  const MediaCapabilities.unavailable()
    : available = false,
      ffmpegVersion = '',
      encoders = const {},
      muxers = const {},
      decoders = const {};

  final bool available;
  final String ffmpegVersion;

  /// Encoders that actually opened on this device (hardware included).
  final Set<String> encoders;
  final Set<String> muxers;
  final Set<String> decoders;

  static const hardwareH264 = ['h264_videotoolbox', 'h264_mediacodec'];
  String? get hardwareVideoEncoder =>
      hardwareH264.where(encoders.contains).firstOrNull;
}

enum MediaJobState {
  queued,
  preparing,
  running,
  finalizing,
  succeeded,
  failed,
  cancelling,
  cancelled,
  interrupted;

  bool get terminal =>
      this == succeeded ||
      this == failed ||
      this == cancelled ||
      this == interrupted;

  static MediaJobState fromNative(int state) => switch (state) {
    1 => preparing,
    2 => running,
    3 => finalizing,
    4 => succeeded,
    5 => failed,
    6 => cancelled,
    _ => queued,
  };
}

class MediaJobProgress {
  const MediaJobProgress(
    this.state, {
    this.processed = Duration.zero,
    this.total,
    this.error,
  });
  final MediaJobState state;
  final Duration processed;

  /// Null when the effective duration is unknown (indeterminate progress).
  final Duration? total;
  final MediaErrorCode? error;

  double? get fraction {
    final t = total;
    if (t == null || t.inMicroseconds <= 0) return null;
    return (processed.inMicroseconds / t.inMicroseconds).clamp(0.0, 1.0);
  }
}

class MediaJobResult {
  const MediaJobResult(this.state, {this.outputPath, this.error, this.bytes});
  final MediaJobState state;

  /// Final (validated) file; only set on success.
  final String? outputPath;
  final MediaErrorCode? error;
  final int? bytes;
  bool get succeeded => state == MediaJobState.succeeded;
}
