// Runs against the real bridge built by tool/build_host_lib.sh:
//   OPX_FFMPEG_LIBRARY=$PWD/build/host/libopenplayx_ffmpeg.dylib flutter test
import 'dart:io';
import 'dart:math';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:openplayx_ffmpeg/openplayx_ffmpeg.dart';

String _hostLib() {
  final env = Platform.environment['OPX_FFMPEG_LIBRARY'];
  if (env != null) return env;
  final ext = Platform.isMacOS ? 'dylib' : 'so';
  return File('build/host/libopenplayx_ffmpeg.$ext').absolute.path;
}

/// 3 s, 44.1 kHz stereo sine as 16-bit PCM WAV.
File _writeWav(Directory dir) {
  const rate = 44100, seconds = 3, channels = 2;
  final samples = rate * seconds;
  final data = ByteData(44 + samples * channels * 2);
  void ascii(int o, String s) {
    for (var i = 0; i < s.length; i++) {
      data.setUint8(o + i, s.codeUnitAt(i));
    }
  }

  ascii(0, 'RIFF');
  data.setUint32(4, 36 + samples * channels * 2, Endian.little);
  ascii(8, 'WAVEfmt ');
  data.setUint32(16, 16, Endian.little);
  data.setUint16(20, 1, Endian.little);
  data.setUint16(22, channels, Endian.little);
  data.setUint32(24, rate, Endian.little);
  data.setUint32(28, rate * channels * 2, Endian.little);
  data.setUint16(32, channels * 2, Endian.little);
  data.setUint16(34, 16, Endian.little);
  ascii(36, 'data');
  data.setUint32(40, samples * channels * 2, Endian.little);
  for (var i = 0; i < samples; i++) {
    final v = (sin(2 * pi * 440 * i / rate) * 12000).round();
    for (var c = 0; c < channels; c++) {
      data.setInt16(44 + (i * channels + c) * 2, v, Endian.little);
    }
  }
  return File('${dir.path}/tone.wav')
    ..writeAsBytesSync(data.buffer.asUint8List());
}

void main() {
  final lib = _hostLib();
  final skip = File(lib).existsSync() ? null : 'run tool/build_host_lib.sh';
  late MediaProcessor processor;
  late Directory tmp;
  final video = File('test/fixtures/test_video.mp4').absolute.path;

  setUp(() {
    processor = MediaProcessor(
      libraryPath: lib,
      pollInterval: const Duration(milliseconds: 20),
    );
    tmp = Directory.systemTemp.createTempSync('opx_media_test');
  });
  tearDown(() {
    processor.dispose();
    tmp.deleteSync(recursive: true);
  });

  Future<MediaJobResult> run(
    MediaPreset preset,
    String input, [
    PlanRequest request = const PlanRequest(),
  ]) async {
    final caps = await processor.capabilities();
    final probe = await processor.probe(input);
    final plan = MediaPlanner.plan(preset, probe, caps, request);
    final job = processor.submit(
      plan,
      input: input,
      output: '${tmp.path}/out.${plan.extension}',
    );
    return job.done;
  }

  test('capabilities report measured encoders', () async {
    final caps = await processor.capabilities();
    expect(caps.available, isTrue);
    expect(caps.encoders, containsAll(['aac', 'mjpeg', 'pcm_s16le']));
    expect(caps.muxers, contains('mp4'));
    expect(caps.ffmpegVersion, startsWith('9.1'));
    // ignore: avoid_print
    print('encoders: ${caps.encoders}');
  }, skip: skip);

  test('probe returns sanitized stream summary', () async {
    final probe = await processor.probe(video);
    expect(probe.container, contains('mp4'));
    expect(probe.durationUs, greaterThan(0));
    expect(probe.primaryVideo, isNotNull);
    expect(probe.primaryVideo!.width, greaterThan(0));
  }, skip: skip);

  test(
    'expanded build exposes the Build codec and container formats',
    () async {
      final caps = await processor.capabilities();
      expect(
        caps.encoders,
        containsAll([
          'libx264',
          'libx265',
          'libaom-av1',
          'libvpx',
          'libvpx-vp9',
          'libmp3lame',
          'libopus',
          'aac',
        ]),
      );
      expect(
        caps.decoders,
        containsAll([
          // AV1 is decoded by dav1d; libaom only encodes.
          'libdav1d',
          'h264',
          'hevc',
          'vp8',
          'vp9',
          'mp3',
          'opus',
          'aac',
        ]),
      );
      expect(
        caps.muxers,
        containsAll(['mp4', 'webm', 'ogg', 'opus', 'ivf', 'dash']),
      );
      final probe = await processor.probe(video);
      final plan = MediaPlanner.plan(
        MediaPreset.mobile720p,
        probe,
        caps,
        const PlanRequest(hardware: HardwarePreference.software),
      );
      expect(plan.values['video_codec'], 'libx264');
    },
    skip: skip,
  );

  for (final entry in {
    'libx264': ('h264', 'mp4'),
    'libx265': ('hevc', 'mp4'),
    'libaom-av1': ('av1', 'mp4'),
    'libvpx': ('vp8', 'webm'),
    'libvpx-vp9': ('vp9', 'webm'),
    'libmp3lame': ('mp3', 'mp3'),
    'libopus': ('opus', 'opus'),
  }.entries) {
    test(
      '${entry.key} encodes and its output decodes',
      () async {
        final audio = entry.key == 'libmp3lame' || entry.key == 'libopus';
        final input = audio ? _writeWav(tmp).path : video;
        final probe = await processor.probe(input);
        final (codec, extension) = entry.value;
        final output = '${tmp.path}/encoded.$extension';
        final plan = MediaPlan(
          MediaPreset.mobile720p,
          extension,
          {
            'operation': 'transcode',
            'format': extension,
            'video_stream': audio ? -1 : probe.primaryVideo!.index,
            'audio_stream': audio ? probe.primaryAudio!.index : -1,
            'subtitle_stream': -1,
            'video_mode': audio ? 'none' : 'encode',
            'audio_mode': audio ? 'encode' : 'none',
            'subtitle_mode': 'none',
            if (audio) 'audio_codec': entry.key else 'video_codec': entry.key,
            'sample_rate': 48000,
            'channels': 2,
            'start_us': 0,
            'end_us': 500000,
            'timeout_ms': 120000,
          },
          expects: {audio ? 'audio' : 'video'},
        );
        final result = await processor
            .submit(plan, input: input, output: output)
            .done;
        expect(result.succeeded, isTrue, reason: '${result.error}');
        final encoded = await processor.probe(output);
        final stream = audio ? encoded.primaryAudio : encoded.primaryVideo;
        expect(stream?.codec, codec);
        expect(stream?.decodable, isTrue);
        // Decode real output pixels, rather than just trusting codec registration.
        if (!audio) {
          final snap = await run(
            MediaPreset.imagePreview,
            output,
            const PlanRequest(time: Duration.zero),
          );
          expect(snap.succeeded, isTrue, reason: '${snap.error}');
        } else {
          final decoded = await run(MediaPreset.speechWav, output);
          expect(decoded.succeeded, isTrue, reason: '${decoded.error}');
        }
      },
      skip: skip,
      timeout: const Timeout(Duration(minutes: 3)),
    );
  }

  test('snapshot writes a JPEG at the requested time', () async {
    final probe = await processor.probe(video);
    final result = await run(
      MediaPreset.imagePreview,
      video,
      PlanRequest(time: Duration(microseconds: probe.durationUs ~/ 2)),
    );
    expect(result.succeeded, isTrue, reason: '${result.error}');
    final bytes = File(result.outputPath!).readAsBytesSync();
    expect(bytes.sublist(0, 2), [0xFF, 0xD8]);
    expect(File('${result.outputPath}.part').existsSync(), isFalse);
  }, skip: skip);

  test('remux copies tracks into mp4', () async {
    final result = await run(MediaPreset.remuxMp4, video);
    expect(result.succeeded, isTrue, reason: '${result.error}');
    final out = await processor.probe(result.outputPath!);
    final src = await processor.probe(video);
    expect(out.primaryVideo!.codec, src.primaryVideo!.codec);
  }, skip: skip);

  test('720p transcode produces a playable mp4', () async {
    final result = await run(MediaPreset.mobile720p, video);
    expect(result.succeeded, isTrue, reason: '${result.error}');
    final out = await processor.probe(result.outputPath!);
    final v = out.primaryVideo!;
    expect(v.width <= 1280 && v.height <= 1280, isTrue);
    expect(out.durationUs, greaterThan(0));
  }, skip: skip);

  test('audio speech wav and original copy', () async {
    final wav = _writeWav(tmp).path;
    final speech = await run(MediaPreset.speechWav, wav);
    expect(speech.succeeded, isTrue, reason: '${speech.error}');
    final probe = await processor.probe(speech.outputPath!);
    expect(probe.primaryAudio!.sampleRate, 16000);
    expect(probe.primaryAudio!.channels, 1);
    File(speech.outputPath!).deleteSync();

    final original = await run(
      MediaPreset.audioOriginal,
      wav,
      const PlanRequest(start: Duration(seconds: 1)),
    );
    expect(original.succeeded, isTrue, reason: '${original.error}');
    expect(original.outputPath, endsWith('.mka'));
  }, skip: skip);

  test('reads host-owned loopback streams with range requests', () async {
    final bytes = File(video).readAsBytesSync();
    final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    server.listen((req) async {
      final res = req.response;
      res.headers.set('accept-ranges', 'bytes');
      final range = req.headers.value('range');
      var start = 0, end = bytes.length - 1;
      final m = range == null
          ? null
          : RegExp(r'bytes=(\d+)-(\d*)').firstMatch(range);
      if (m != null) {
        start = int.parse(m[1]!);
        if (m[2]!.isNotEmpty) end = int.parse(m[2]!);
        res.statusCode = 206;
        res.headers.set('content-range', 'bytes $start-$end/${bytes.length}');
      }
      res.contentLength = end - start + 1;
      res.add(bytes.sublist(start, end + 1));
      await res.close();
    });
    try {
      final url = 'http://127.0.0.1:${server.port}/session/video.mp4';
      final probe = await processor.probe(url);
      final result = await run(
        MediaPreset.imagePreview,
        url,
        PlanRequest(time: Duration(microseconds: probe.durationUs ~/ 3)),
      );
      expect(result.succeeded, isTrue, reason: '${result.error}');
    } finally {
      await server.close(force: true);
    }
  }, skip: skip);

  test('rejects remote, relative and nested inputs', () async {
    for (final input in [
      'http://example.com/a.mp4',
      'relative.mp4',
      'file:///etc/passwd',
      'concat:/a|/b',
    ]) {
      await expectLater(
        processor.probe(input),
        throwsA(
          isA<MediaException>().having(
            (e) => e.code,
            'code',
            MediaErrorCode.accessDenied,
          ),
        ),
      );
    }
  }, skip: skip);

  test('incompatible remux is reported, not re-encoded', () async {
    final wav = _writeWav(tmp).path;
    final caps = await processor.capabilities();
    final probe = await processor.probe(wav);
    expect(
      () => MediaPlanner.plan(
        MediaPreset.remuxMp4,
        probe,
        caps,
        const PlanRequest(),
      ),
      throwsA(
        isA<MediaException>().having(
          (e) => e.reason,
          'reason',
          'audio_not_mp4_compatible:pcm_s16le',
        ),
      ),
    );
  }, skip: skip);

  test('cancel converges and leaves no output', () async {
    final caps = await processor.capabilities();
    final probe = await processor.probe(video);
    final plan = MediaPlanner.plan(
      MediaPreset.mobile720p,
      probe,
      caps,
      const PlanRequest(),
    );
    final first = processor.submit(
      plan,
      input: video,
      output: '${tmp.path}/a.mp4',
    );
    final queued = processor.submit(
      plan,
      input: video,
      output: '${tmp.path}/b.mp4',
    );
    queued.cancel();
    first.cancel();
    final a = await first.done;
    final b = await queued.done;
    expect(b.state, MediaJobState.cancelled);
    expect([
      MediaJobState.cancelled,
      MediaJobState.succeeded,
    ], contains(a.state));
    if (a.state == MediaJobState.cancelled) {
      expect(File('${tmp.path}/a.mp4').existsSync(), isFalse);
    }
    expect(File('${tmp.path}/a.mp4.part').existsSync(), isFalse);
  }, skip: skip);

  test('never overwrites an existing output', () async {
    final caps = await processor.capabilities();
    final probe = await processor.probe(video);
    final plan = MediaPlanner.plan(
      MediaPreset.remuxMp4,
      probe,
      caps,
      const PlanRequest(),
    );
    final existing = File('${tmp.path}/x.mp4')..writeAsStringSync('keep');
    final r = await processor
        .submit(plan, input: video, output: existing.path)
        .done;
    expect(r.state, MediaJobState.failed);
    expect(existing.readAsStringSync(), 'keep');
  }, skip: skip);

  test('planner rejects HDR, ranges and bad tracks', () {
    final caps = MediaCapabilities.fromJson({
      'encoders': ['mpeg4', 'aac', 'mjpeg', 'pcm_s16le'],
      'muxers': ['mp4', 'wav', 'matroska'],
    });
    final hdr = MediaProbe.fromJson({
      'container': 'matroska',
      'duration_us': 10000000,
      'streams': [
        {
          'index': 0,
          'type': 'video',
          'codec': 'hevc',
          'decodable': true,
          'color_transfer': 'smpte2084',
          'width': 3840,
          'height': 2160,
        },
      ],
    });
    MediaException failure(MediaPreset p, PlanRequest r) {
      try {
        MediaPlanner.plan(p, hdr, caps, r);
      } on MediaException catch (e) {
        return e;
      }
      throw StateError("expected failure");
    }

    expect(
      failure(MediaPreset.mobile720p, const PlanRequest()).reason,
      'hdr_not_supported',
    );
    expect(
      failure(
        MediaPreset.remuxMp4,
        const PlanRequest(start: Duration(seconds: 20)),
      ).reason,
      'range_outside_media',
    );
    expect(
      failure(MediaPreset.remuxMp4, const PlanRequest(audioStream: 3)).reason,
      'audio_track_not_found',
    );
    expect(
      MediaPlanner.availability(caps)
          .firstWhere((a) => a.preset == MediaPreset.mobile720p)
          .available,
      isTrue,
    );
  });
}
