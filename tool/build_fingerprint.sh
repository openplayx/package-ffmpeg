#!/usr/bin/env bash
# Shared by every build entry point: old libraries cannot hide new codecs.
set -euo pipefail
root="$(cd "$(dirname "$0")/.." && pwd)"
{
  printf '%s\n' "${1:?target required}"
  cat "$root/tool/build_ffmpeg.sh" "$root/tool/build_codec_deps.sh" \
    "$root/tool/codec-deps.tsv" "$root/tool/build_fingerprint.sh"
} | { if command -v sha256sum >/dev/null; then sha256sum; else shasum -a 256; fi; } | cut -d ' ' -f 1
# OPX_NATIVE_BUILD_HELPER: CI uses the result as the package build cache key.
