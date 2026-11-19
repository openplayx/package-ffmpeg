# Sources and acknowledgements

English | [简体中文](SOURCES.zh-CN.md)

This repository is OpenPlayX's Flutter FFI media processing bridge. We thank
FFmpeg and the open-source projects below. This document distinguishes build
references from compiled dependencies and does not relicense third-party source.

## Build references

- [The FFmpeg build script in allenzhang61/build](https://github.com/allenzhang61/build/blob/master/ffmpeg/build.sh):
  used to compare format coverage for the expanded encoder build, including
  H.264, HEVC, AV1, VP8/VP9, MP3 and Opus. This repository maintains its own
  cross-platform recipes; the upstream script's complete dependency list and
  options do not automatically become this package's capabilities. This records
  a functional and build approach reference, without claiming additional
  permission to copy that script.
- [FFmpegKit](https://github.com/arthenica/ffmpeg-kit): a cross-platform build
  reference in early planning. This package uses the `opx_media_*` C ABI and
  libav APIs, without depending on FFmpegKit's command execution layer.
  FFmpegKit's license does not replace the license of the actual FFmpeg build.

## FFmpeg upstream and pinned source

- Upstream: [FFmpeg/FFmpeg](https://github.com/FFmpeg/FFmpeg).
- Version: 7.1.1; [source archive](https://ffmpeg.org/releases/ffmpeg-7.1.1.tar.xz).
- SHA-256: `733984395e0dbbe5c046abda2dc49a5544e7e0e1e2366bba849222ae9e3a03b1`.
- Build entry point: `tool/build_ffmpeg.sh`; bridge implementation: `src/opx_media.c`.
- Original upstream licensing notes and GPL/LGPL texts are preserved in [LICENSES/](LICENSES/).

## Expanded build dependencies

The table below records sources used by the expanded encoder recipes. Actual
library inclusion must be determined from the selected revision's build scripts,
target platform and artifact `BUILDINFO`. Earlier LGPL-only builds do not contain
all of these encoders. The expanded recipes pin download URLs and SHA-256 hashes
in `tool/codec-deps.tsv` and cross-compile with `tool/build_codec_deps.sh`, without
automatically discovering encoder libraries installed on the host.

| Project / upstream | Pinned version or commit | Purpose | Upstream license materials |
|---|---|---|---|
| [libaom](https://aomedia.googlesource.com/aom/) | 3.3.0 | AV1 encoding and decoding | BSD-style; `LICENSE`, `PATENTS` |
| [Opus](https://opus-codec.org/) | 1.5.2 | Opus codec support | BSD-style; `COPYING` |
| [libvpx](https://github.com/webmproject/libvpx) | 1.14.1 | VP8/VP9 encoding | BSD-style; `LICENSE`, `PATENTS` |
| [LAME](https://lame.sourceforge.io/) | 3.100 | MP3 encoding | LGPL; `COPYING`, `LICENSE` |
| [libxml2](https://gitlab.gnome.org/GNOME/libxml2) | 2.12.10 | DASH XML parsing | MIT-style; `Copyright` |
| [x264](https://code.videolan.org/videolan/x264) | `31e19f92f00c7003fa115047ce50978bc98c3a0d` | H.264 software encoding | GPL; `COPYING` and source copyright notices |
| [x265](https://bitbucket.org/multicoreware/x265_git/) | 3.6 | HEVC software encoding | GPL; `COPYING` and notices in subdirectories |
| [zlib](https://github.com/madler/zlib) | Windows recipe pins 1.3.1; other platforms use platform-provided zlib | Compression support | zlib license in the archive's `zlib.h` |

Verified original upstream license texts are preserved in [LICENSES/](LICENSES/).
This is an inventory of major dependency sources, not a complete bill of materials
for every platform artifact. Subcomponents retain their own original notices.

## Build and distribution notes

Record FFmpeg's LGPL-only builds separately from expanded builds that enable
`--enable-gpl` and link x264/x265. The expanded recipes do not enable
`--enable-nonfree`; AAC uses FFmpeg's native implementation. Consult the actual
source, configuration and [FFmpeg's official licensing notes](https://ffmpeg.org/legal.html)
for the applicable terms.

For releases, retain the actual revision, pinned source archives, checksums,
local patches, build scripts, configuration and `BUILDINFO`, and provide the
corresponding source and license materials required by the applicable licenses.
A link to only the main application repository or an unpinned upstream does not
replace the source and scripts actually used for a build.

This document and FFmpeg's license texts do not separately grant a license to
OpenPlayX's own Dart/C bridge code. The application repository's MIT license also
does not automatically cover this independently maintained bridge package.
