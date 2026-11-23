# 来源与致谢

[English](SOURCES.md) | 简体中文

本仓库是 OpenPlayX 的 Flutter FFI 媒体处理桥接包。感谢 FFmpeg 及下列
开源项目的维护者。本文件区分构建参考与实际编译依赖，不为第三方源码重新授权。

## 构建参考

- [allenzhang61/build 的 FFmpeg 构建脚本](https://github.com/allenzhang61/build/blob/master/ffmpeg/build.sh)：
  扩展编码器构建时用于核对 H.264、HEVC、AV1、VP8/VP9、MP3、Opus 等格式覆盖。
  本仓库维护自己的跨平台配方；上游脚本的全部依赖和参数并不自动成为本包的能力。
  此项记录功能与构建方案参考，不声称已取得复制该脚本的额外许可。
- [FFmpegKit](https://github.com/arthenica/ffmpeg-kit)：早期方案中的跨平台构建参考。
  本包的执行接口是 `opx_media_*` C ABI 和 libav 库 API，不依赖 FFmpegKit 的
  命令执行层，也不以 FFmpegKit 的许可替代 FFmpeg 的实际构建许可。

## FFmpeg 上游与固定源码

- 上游：[FFmpeg/FFmpeg](https://github.com/FFmpeg/FFmpeg)。
- 版本：9.1；[源码归档](https://ffmpeg.org/releases/ffmpeg-9.1.tar.xz)。
- SHA-256：`1a4d394ae63d190a526cd052eb4415c156b5c5e2df37efab41a7de0b8fde2433`。
- 本仓库入口：`tool/build_ffmpeg.sh`；桥接实现：`src/opx_media.c`。
- 上游原始许可说明与 GPL/LGPL 文本保存在 [LICENSES/](LICENSES/)。

## 扩展构建依赖

下表记录扩展编码器配方使用的源码。是否实际包含某个库，必须以所用提交的
构建脚本、目标平台和产物中的 `BUILDINFO` 为准；早期 LGPL-only 构建不包含
这里全部编码器。扩展配方使用 `tool/codec-deps.tsv` 固定下载地址与 SHA-256，
使用 `tool/build_codec_deps.sh` 交叉编译，不从宿主机自动发现编码器库。

| 项目 / 上游 | 固定版本或提交 | 用途 | 上游许可材料 |
|---|---|---|---|
| [libaom](https://aomedia.googlesource.com/aom/) | 3.15.3 | AV1 编解码 | BSD 类许可；`LICENSE`、`PATENTS` |
| [Opus](https://opus-codec.org/) | 1.6.1 | Opus 编解码支持 | BSD 类许可；`COPYING` |
| [libvpx](https://github.com/webmproject/libvpx) | 1.17.0 | VP8/VP9 编码 | BSD 类许可；`LICENSE`、`PATENTS` |
| [LAME](https://lame.sourceforge.io/) | 4.0 | MP3 编码 | LGPL；`COPYING`、`LICENSE` |
| [libxml2](https://gitlab.gnome.org/GNOME/libxml2) | 2.15.4 | DASH XML 解析 | MIT 类许可；`Copyright` |
| [x264](https://code.videolan.org/videolan/x264) | `b35605ace3ddf7c1a5d67a2eb553f034aef41d55` | H.264 软件编码 | GPL；`COPYING` 及源码版权声明 |
| [x265](https://bitbucket.org/multicoreware/x265_git/) | 4.2 | HEVC 软件编码 | GPL；`COPYING` 及各子目录声明 |
| [zlib](https://github.com/madler/zlib) | Windows 配方固定为 1.4；其他平台使用平台提供的 zlib | 压缩支持 | zlib 许可，见归档中的 `zlib.h` |

已核对的上游许可原文保存在 [LICENSES/](LICENSES/)。这些是主要依赖的来源清单，
不是所有平台产物的完整物料清单；依赖中的子组件仍需保留其原始声明。

## 构建与分发说明

FFmpeg 的 LGPL-only 构建与启用 `--enable-gpl`、链接 x264/x265 的扩展构建
必须分别记录。扩展配方不启用 `--enable-nonfree`，AAC 使用 FFmpeg 原生实现。
具体条款以实际源码、配置和[FFmpeg 官方许可说明](https://ffmpeg.org/legal.html)为准。

发布时应保存实际提交、固定源码归档、校验值、本地补丁、构建脚本、配置与
`BUILDINFO`，并提供适用许可要求的对应源码及许可材料。只给出主应用仓库或
一个未固定版本的上游链接，不能替代实际构建使用的源码与脚本。

此文件及 FFmpeg 的许可文本不为 OpenPlayX 自有 Dart/C 桥接代码另行授予许可；
应用仓库的 MIT 许可也不会自动覆盖独立维护的桥接包。
