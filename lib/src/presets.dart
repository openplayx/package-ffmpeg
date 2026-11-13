import 'models.dart';

enum MediaOperation { transcode, extractAudio, snapshot }

/// Host-defined, controlled execution plans. Callers choose a preset and a
/// few explicit parameters; FFmpeg options are never passed through.
class MediaPreset {
  const MediaPreset._(this.id, this.revision, this.operation, this.summary);
  final String id;
  final int revision;
  final MediaOperation operation;
  final String summary;

  static const mobile720p = MediaPreset._(
    'video.mobile.720p',
    1,
    MediaOperation.transcode,
    'Scale down to fit 1280x720 (never upscale) and encode H.264 (or MPEG-4 Part 2 without an H.264 encoder) + AAC into MP4.',
  );
  static const remuxMp4 = MediaPreset._(
    'video.remux.mp4',
    1,
    MediaOperation.transcode,
    'Copy compatible video/audio (and mov_text subtitle) tracks into MP4 without re-encoding.',
  );
  static const audioOriginal = MediaPreset._(
    'audio.extract.original',
    1,
    MediaOperation.extractAudio,
    'Copy the selected audio track into a matching audio container.',
  );
  static const speechWav = MediaPreset._(
    'audio.speech.wav',
    1,
    MediaOperation.extractAudio,
    'Decode and resample the selected audio to 16 kHz mono 16-bit PCM WAV.',
  );
  static const imagePreview = MediaPreset._(
    'image.preview',
    1,
    MediaOperation.snapshot,
    'Decode one frame at the given time, fit within 1280x720, honour rotation, save as JPEG.',
  );

  static const all = [
    mobile720p,
    remuxMp4,
    audioOriginal,
    speechWav,
    imagePreview,
  ];

  static MediaPreset? byId(String id) =>
      all.where((p) => p.id == id).firstOrNull;
}

/// A validated plan; input/output are bound later by the processor.
class MediaPlan {
  const MediaPlan(this.preset, this.extension, this.values, {this.expects});
  final MediaPreset preset;

  /// Output file extension without dot (e.g. `mp4`, `jpg`).
  final String extension;
  final Map<String, Object> values;

  /// Stream types the validated output must contain.
  final Set<String>? expects;

  Map<String, Object> bind(String input, String output) => {
    ...values,
    'input': input,
    'output': output,
  };
}

class PlanRequest {
  const PlanRequest({
    this.start,
    this.end,
    this.time,
    this.audioStream,
    this.subtitleStream,
    this.hardware = HardwarePreference.auto,
  });
  final Duration? start;
  final Duration? end;
  final Duration? time;
  final int? audioStream;
  final int? subtitleStream;
  final HardwarePreference hardware;
}

enum HardwarePreference { auto, hardware, software }

class PresetAvailability {
  const PresetAvailability(this.preset, this.available, [this.reason]);
  final MediaPreset preset;
  final bool available;
  final String? reason;
}

/// Pure planning: compatibility checks from the probe and the device's
/// measured capabilities. Throws [MediaException] with a short reason
/// instead of silently re-encoding or dropping tracks.
abstract final class MediaPlanner {
  static const _mp4Video = {'h264', 'hevc', 'mpeg4', 'av1', 'vp9'};
  static const _mp4Audio = {
    'aac',
    'mp3',
    'ac3',
    'eac3',
    'flac',
    'opus',
    'alac',
  };
  static const _mp4Subtitle = {'mov_text'};

  /// Presets usable with this build/device (and with [probe] when given).
  static List<PresetAvailability> availability(
    MediaCapabilities caps, {
    MediaProbe? probe,
  }) => [
    for (final preset in MediaPreset.all)
      () {
        final missing = _missingCapability(preset, caps);
        if (missing != null) return PresetAvailability(preset, false, missing);
        if (probe == null) return PresetAvailability(preset, true);
        try {
          plan(
            preset,
            probe,
            caps,
            preset.operation == MediaOperation.snapshot
                ? PlanRequest(
                    time: Duration(microseconds: probe.durationUs ~/ 2),
                  )
                : const PlanRequest(),
          );
          return PresetAvailability(preset, true);
        } on MediaException catch (e) {
          return PresetAvailability(preset, false, e.reason ?? e.code.name);
        }
      }(),
  ];

  static String? _missingCapability(MediaPreset p, MediaCapabilities c) {
    if (!c.available) return 'module_unavailable';
    switch (p.id) {
      case 'video.mobile.720p':
        if (!c.muxers.contains('mp4')) return 'muxer_unavailable';
        if (!c.encoders.contains('aac')) return 'encoder_unavailable:aac';
        if (_videoEncoder(c, HardwarePreference.auto) == null) {
          return 'encoder_unavailable:video';
        }
      case 'video.remux.mp4':
        if (!c.muxers.contains('mp4')) return 'muxer_unavailable';
      case 'audio.extract.original':
        if (!c.muxers.contains('matroska')) return 'muxer_unavailable';
      case 'audio.speech.wav':
        if (!c.muxers.contains('wav')) return 'muxer_unavailable';
        if (!c.encoders.contains('pcm_s16le')) {
          return 'encoder_unavailable:pcm_s16le';
        }
      case 'image.preview':
        if (!c.encoders.contains('mjpeg')) return 'encoder_unavailable:mjpeg';
    }
    return null;
  }

  static String? _videoEncoder(MediaCapabilities c, HardwarePreference pref) {
    final hw = c.hardwareVideoEncoder;
    return switch (pref) {
      HardwarePreference.hardware => hw,
      HardwarePreference.software =>
        c.encoders.contains('mpeg4') ? 'mpeg4' : null,
      HardwarePreference.auto =>
        hw ?? (c.encoders.contains('mpeg4') ? 'mpeg4' : null),
    };
  }

  static MediaPlan plan(
    MediaPreset preset,
    MediaProbe probe,
    MediaCapabilities caps,
    PlanRequest request,
  ) {
    final missing = _missingCapability(preset, caps);
    if (missing != null) {
      throw MediaException(
        missing == 'module_unavailable'
            ? MediaErrorCode.unavailable
            : missing.startsWith('encoder')
            ? MediaErrorCode.encoderUnavailable
            : MediaErrorCode.presetIncompatible,
        missing,
      );
    }
    final range = _range(probe, request);
    return switch (preset.id) {
      'video.mobile.720p' => _mobile(preset, probe, caps, request, range),
      'video.remux.mp4' => _remux(preset, probe, request, range),
      'audio.extract.original' => _audioCopy(preset, probe, request, range),
      'audio.speech.wav' => _speech(preset, probe, request, range),
      'image.preview' => _snapshot(preset, probe, request),
      _ => throw const MediaException(MediaErrorCode.invalidArgument),
    };
  }

  static Map<String, Object> _range(MediaProbe probe, PlanRequest r) {
    final start = r.start?.inMicroseconds ?? 0;
    final end = r.end?.inMicroseconds ?? 0;
    final duration = probe.durationUs;
    if (start < 0 || end < 0 || (end > 0 && end <= start)) {
      throw const MediaException(
        MediaErrorCode.invalidArgument,
        'invalid_range',
      );
    }
    if (duration > 0 && (start >= duration || end > duration + 1000000)) {
      throw const MediaException(
        MediaErrorCode.invalidArgument,
        'range_outside_media',
      );
    }
    return {'start_us': start, if (end > 0) 'end_us': end};
  }

  static MediaStreamInfo? _audio(MediaProbe probe, PlanRequest r) {
    if (r.audioStream == null) return probe.primaryAudio;
    final s = probe.stream(r.audioStream!);
    if (s == null || !s.isAudio) {
      throw const MediaException(
        MediaErrorCode.invalidArgument,
        'audio_track_not_found',
      );
    }
    return s;
  }

  static MediaPlan _mobile(
    MediaPreset preset,
    MediaProbe probe,
    MediaCapabilities caps,
    PlanRequest r,
    Map<String, Object> range,
  ) {
    final video = probe.primaryVideo;
    if (video == null) {
      throw const MediaException(
        MediaErrorCode.presetIncompatible,
        'no_decodable_video',
      );
    }
    if (video.isHdr) {
      // No tone mapping chain is implemented; an SDR file from HDR input
      // would look wrong.
      throw const MediaException(
        MediaErrorCode.presetIncompatible,
        'hdr_not_supported',
      );
    }
    if (r.subtitleStream != null) {
      throw const MediaException(
        MediaErrorCode.presetIncompatible,
        'subtitle_burn_in_not_supported',
      );
    }
    final encoder = _videoEncoder(caps, r.hardware);
    if (encoder == null) {
      throw MediaException(
        MediaErrorCode.encoderUnavailable,
        r.hardware == HardwarePreference.hardware
            ? 'hardware_encoder_unavailable'
            : 'encoder_unavailable:video',
      );
    }
    final audio = _audio(probe, r);
    if (audio != null && !audio.decodable) {
      throw const MediaException(
        MediaErrorCode.inputUnsupported,
        'audio_not_decodable',
      );
    }
    return MediaPlan(
      preset,
      'mp4',
      {
        'operation': 'transcode',
        'format': 'mp4',
        'video_stream': video.index,
        'video_mode': 'encode',
        'video_codec': encoder,
        'video_bitrate': encoder == 'mpeg4' ? 3500000 : 2500000,
        'max_long': 1280,
        'max_short': 720,
        if (audio != null) ...{
          'audio_stream': audio.index,
          'audio_mode': 'encode',
          'audio_codec': 'aac',
          'audio_bitrate': 128000,
          'channels': 2,
        },
        ...range,
      },
      expects: {'video', if (audio != null) 'audio'},
    );
  }

  static MediaPlan _remux(
    MediaPreset preset,
    MediaProbe probe,
    PlanRequest r,
    Map<String, Object> range,
  ) {
    final video = probe.primaryVideo ?? probe.video.firstOrNull;
    final audio = _audio(probe, r);
    MediaStreamInfo? subtitle;
    if (r.subtitleStream != null) {
      subtitle = probe.stream(r.subtitleStream!);
      if (subtitle == null || !subtitle.isSubtitle) {
        throw const MediaException(
          MediaErrorCode.invalidArgument,
          'subtitle_track_not_found',
        );
      }
      if (!_mp4Subtitle.contains(subtitle.codec)) {
        throw MediaException(
          MediaErrorCode.presetIncompatible,
          'subtitle_not_mp4_compatible:${subtitle.codec}',
        );
      }
    }
    if (video == null && audio == null) {
      throw const MediaException(
        MediaErrorCode.presetIncompatible,
        'no_tracks',
      );
    }
    if (video != null && !_mp4Video.contains(video.codec)) {
      throw MediaException(
        MediaErrorCode.presetIncompatible,
        'video_not_mp4_compatible:${video.codec}',
      );
    }
    if (audio != null && !_mp4Audio.contains(audio.codec)) {
      throw MediaException(
        MediaErrorCode.presetIncompatible,
        'audio_not_mp4_compatible:${audio.codec}',
      );
    }
    return MediaPlan(
      preset,
      'mp4',
      {
        'operation': 'remux',
        'format': 'mp4',
        if (video != null) ...{
          'video_stream': video.index,
          'video_mode': 'copy',
        },
        if (audio != null) ...{
          'audio_stream': audio.index,
          'audio_mode': 'copy',
        },
        if (subtitle != null) ...{
          'subtitle_stream': subtitle.index,
          'subtitle_mode': 'copy',
        },
        ...range,
      },
      expects: {if (video != null) 'video', if (audio != null) 'audio'},
    );
  }

  static MediaStreamInfo _requireAudio(MediaProbe probe, PlanRequest r) {
    final audio = _audio(probe, r);
    if (audio == null) {
      throw const MediaException(
        MediaErrorCode.presetIncompatible,
        'no_audio_track',
      );
    }
    return audio;
  }

  static MediaPlan _audioCopy(
    MediaPreset preset,
    MediaProbe probe,
    PlanRequest r,
    Map<String, Object> range,
  ) {
    final audio = _requireAudio(probe, r);
    final (format, ext) = switch (audio.codec) {
      'aac' || 'alac' => ('ipod', 'm4a'),
      'mp3' => ('mp3', 'mp3'),
      'flac' => ('flac', 'flac'),
      _ => ('matroska', 'mka'),
    };
    return MediaPlan(
      preset,
      ext,
      {
        'operation': 'remux',
        'format': format,
        'audio_stream': audio.index,
        'audio_mode': 'copy',
        ...range,
      },
      expects: {'audio'},
    );
  }

  static MediaPlan _speech(
    MediaPreset preset,
    MediaProbe probe,
    PlanRequest r,
    Map<String, Object> range,
  ) {
    final audio = _requireAudio(probe, r);
    if (!audio.decodable) {
      throw const MediaException(
        MediaErrorCode.inputUnsupported,
        'audio_not_decodable',
      );
    }
    return MediaPlan(
      preset,
      'wav',
      {
        'operation': 'transcode',
        'format': 'wav',
        'audio_stream': audio.index,
        'audio_mode': 'encode',
        'audio_codec': 'pcm_s16le',
        'sample_rate': 16000,
        'channels': 1,
        ...range,
      },
      expects: {'audio'},
    );
  }

  static MediaPlan _snapshot(
    MediaPreset preset,
    MediaProbe probe,
    PlanRequest r,
  ) {
    final video = probe.primaryVideo;
    if (video == null) {
      throw const MediaException(
        MediaErrorCode.presetIncompatible,
        'no_decodable_video',
      );
    }
    final time = r.time?.inMicroseconds;
    if (time == null || time < 0) {
      throw const MediaException(MediaErrorCode.invalidArgument, 'time');
    }
    if (probe.durationUs > 0 && time >= probe.durationUs) {
      throw const MediaException(
        MediaErrorCode.invalidArgument,
        'time_outside_media',
      );
    }
    return MediaPlan(preset, 'jpg', {
      'operation': 'snapshot',
      'video_stream': video.index,
      'time_us': time,
      'image_codec': 'mjpeg',
      'image_quality': 3,
      'max_long': 1280,
      'max_short': 720,
      'timeout_ms': 60000,
    });
  }
}
