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
- **Hardware:** H.264 uses `h264_videotoolbox` (Apple) or `h264_mediacodec` (Android) when it actually opens on the device. Software encoding prefers `libx264`, with MPEG-4 Part 2 retained as a fallback for older builds.

## Building FFmpeg

`bash tool/build_ffmpeg.sh <target>` builds the pinned FFmpeg **7.1.1** (sha256 checked) as trimmed **GPL** libraries into `third_party/ffmpeg/<target>` (git-ignored). It first cross-builds the external dependencies for the same target with `tool/build_codec_deps.sh`. Install CMake, pkg-config and the platform compiler/SDK before building. Downloaded source archives and their SHA-256 checksums are pinned in `tool/codec-deps.tsv`; host-installed codec libraries are not used.

The expanded build covers the explicitly enabled codec formats in [allenzhang61/build](https://github.com/allenzhang61/build/blob/master/ffmpeg/build.sh):

| Format | Decode | Encode |
|---|---|---|
| H.264 | FFmpeg native | x264; Apple/Android hardware where available |
| HEVC / H.265 | FFmpeg native | x265 |
| AV1 | libaom | libaom |
| VP8 / VP9 | FFmpeg native | libvpx |
| AAC | FFmpeg native | FFmpeg native (no nonfree FDK dependency) |
| MP3 | FFmpeg native | LAME |
| Opus | FFmpeg native | libopus |

Existing MPEG-4, MPEG-2, VC-1, WMV, JPEG/PNG, AC3/EAC3, DTS, FLAC, Vorbis, TrueHD, ALAC and PCM support is retained. Added containers include WebM, Ogg/Opus, IVF and DASH. DASH XML parsing is compiled with libxml2; the current bridge still refuses secondary opens, so segmented DASH manifests are **not exposed as a supported input or output operation**. A separate gateway/plan implementation is needed to use them. HTTPS/GnuTLS and ZeroMQ in the desktop Build script are transport/control features, not imported codec formats; the bridge continues to accept only local files and host-owned loopback HTTP. That script's optional VVC libraries are not part of its guaranteed build and are not bundled here.

New encoders are reported by `capabilities()` and usable by host-owned `MediaPlan`s; the existing user-facing presets are unchanged except for the H.264 software fallback. Compiled codecs do not automatically add new UI presets.

`BUILDINFO` records the configure line. `BUILD_FINGERPRINT` hashes the target, build recipes and pinned dependency manifest; every build entry point checks it so changing codec support rebuilds stale libraries automatically. Set `OPX_FFMPEG_FORCE_REBUILD=1` to force the FFmpeg build; remove `third_party/deps/<target>/BUILD_FINGERPRINT` to force dependency rebuilding.

| Platform | How it links |
|---|---|
| macOS / iOS / tvOS | The podspec compiles the C ABI. A build phase runs `tool/ensure_ffmpeg_apple.sh`, which builds the missing arch on first build. Only `opx_media_*` is exported (`src/exports.txt`), so libav symbols cannot clash with libVLC. |
| Android / Linux | `src/CMakeLists.txt` links `third_party/ffmpeg/<target>` with a version script that keeps libav symbols private. Without that build it compiles `opx_media_stub.c`, so the app still builds and capabilities report `available: false`. Android needs `ANDROID_NDK_HOME` set for `build_ffmpeg.sh android-<abi>`. |
| Windows | Links MinGW-built FFmpeg DLLs via import libraries; dependency archives are statically linked into those DLLs. Requires MSYS2 make, CMake, pkg-config and MinGW-w64. |

Verified so far: macOS arm64 (host tests, and an integration test inside the sandboxed app bundle). iOS simulator and Android emulator (arm64-v8a, API 37): the app's `ffmpeg_bridge_test` integration test passes; armeabi-v7a and x86_64 link and package. The Linux and Windows scripts exist but are not yet verified.

## Tests

```sh
tool/build_host_lib.sh   # build/host/libopenplayx_ffmpeg.{dylib,so}
flutter test             # real native probe/snapshot/remux/transcode/cancel tests
```

## License

The expanded FFmpeg combination enables `--enable-gpl` because it links x264/x265. It does **not** enable `--enable-nonfree`; AAC uses FFmpeg's native codec instead of libfdk-aac. The Apple pod metadata identifies the GPL combination. Keep the pinned dependency sources, their license notices, FFmpeg source, `BUILDINFO` and applicable GPL/LGPL texts with your distribution compliance materials. See <https://ffmpeg.org/legal.html> and the individual dependencies' licenses.

## Sources and acknowledgements

See [SOURCES.md](SOURCES.md) for upstream sources, build references, pinned
dependencies and the preserved license texts in [LICENSES/](LICENSES/).

Apple TV: `tvos-arm64` builds for hardware and `tvos-sim-arm64` for the Apple Silicon simulator. The dedicated `tvos/` podspec links the real engine through the FlutterTV embedder; iOS binaries are never reused for tvOS.
