# openplayx_ffmpeg

OpenPlayX's in-process FFmpeg media processing package (Flutter FFI plugin).

Public repository: [openplayx/package-ffmpeg](https://github.com/openplayx/package-ffmpeg).
The Dart package name remains `openplayx_ffmpeg`. Clone into `ffmpeg-package`
next to the app to preserve its existing pubspec path and CI checkout name:

```sh
git clone https://github.com/openplayx/package-ffmpeg.git ffmpeg-package
```

```
Dart (MediaProcessor) → dart:ffi → opx_media_* C ABI (src/opx_media.c)
                      → libavformat / libavcodec / libswscale / libswresample
```

It never runs the `ffmpeg`/`ffprobe` programs, a child process, a shell or a command string. Probing and planning use the library APIs directly.

## App-facing API

```dart
final processor = MediaProcessor();            // one per process; jobs run one at a time
final caps = await processor.capabilities();   // encoders that really open on this device
final probe = await processor.probe(input);    // bounded, runs on a worker isolate
final plan = MediaPlanner.plan(MediaPreset.mobile720p, probe, caps, const PlanRequest());
final job = processor.submit(plan, input: input, output: '/app/artifacts/x.mp4');
job.progress.listen(...);                      // queued → preparing → running → finalizing → …
job.cancel();                                  // cooperative; reports `cancelling` until it stops
final result = await job.done;                 // validated output, or a MediaErrorCode
```

- **Inputs:** an absolute local path, or a loopback `http://127.0.0.1:<port>/…` URL owned by the host (for example the app's stream gateway). Any other URL, relative path or protocol is refused natively. Every secondary open (playlists, references, nested protocols) is blocked by a guarded `io_open`.
- **Outputs:** written to `<output>.part`, re-probed, then renamed. An existing file is never overwritten. Failed or cancelled jobs delete the partial file.
- **Presets** (`lib/src/presets.dart`): `video.mobile.720p`, `video.remux.mp4`, `audio.extract.original`, `audio.speech.wav`, `image.preview`. These are host-defined plans; no free FFmpeg options are accepted. Incompatible inputs fail with a short reason (`hdr_not_supported`, `audio_not_mp4_compatible:pcm_s16le`, …). They are never re-encoded or dropped silently.
- **Hardware:** H.264 uses `h264_videotoolbox` (Apple) or `h264_mediacodec` (Android) when it actually opens on the device. Otherwise it falls back to software MPEG-4 Part 2 (LGPL build, no x264).

## Building FFmpeg

`tool/build_ffmpeg.sh <target>` builds the pinned FFmpeg **7.1.1** (sha256 checked) as trimmed LGPL static libraries into `third_party/ffmpeg/<target>` (git-ignored). The build includes only the demuxers, decoders, encoders, muxers and protocols (`file,http,tcp`) the presets need. `BUILDINFO` records the configure line.

| Platform | How it links |
|---|---|
| macOS / iOS | The podspec compiles the C ABI. A build phase runs `tool/ensure_ffmpeg_apple.sh`, which builds the missing arch on first build. Only `opx_media_*` is exported (`src/exports.txt`), so libav symbols cannot clash with libVLC. |
| Android / Linux | `src/CMakeLists.txt` links `third_party/ffmpeg/<target>` with a version script that keeps libav symbols private. Without that build it compiles `opx_media_stub.c`, so the app still builds and capabilities report `available: false`. Android needs `ANDROID_NDK_HOME` set for `build_ffmpeg.sh android-<abi>`. |
| Windows | Builds the stub until a Windows FFmpeg build is added. |

Verified so far: macOS arm64 (host tests, and an integration test inside the sandboxed app bundle). iOS simulator and Android emulator (arm64-v8a, API 37): the app's `ffmpeg_bridge_test` integration test passes; armeabi-v7a and x86_64 link and package. The Linux and Windows scripts exist but are not yet verified.

## Tests

```sh
tool/build_host_lib.sh   # build/host/libopenplayx_ffmpeg.{dylib,so}
flutter test             # real native probe/snapshot/remux/transcode/cancel tests
```

## License

The bundled FFmpeg is built LGPL-only (no `--enable-gpl` or `--enable-nonfree`). When distributing, ship the FFmpeg source for the pinned version, the configure line from `BUILDINFO` and the LGPL text. See <https://ffmpeg.org/legal.html>.
