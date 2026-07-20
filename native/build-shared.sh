#!/usr/bin/env bash
# Build the libktx shared library (C API from src/capi + library modules from
# src/ktx) for the host target, linking the prebuilt <target>/libzstd.a.
# The result lands next to it: <target>/libktx.so / libktx.dylib.
#
# Consumers (e.g. the Blender glTF exporter addon) load it via ctypes/FFI —
# see src/capi/capi.c3 for the exported functions.
#
# Requires <target>/libzstd.a built WITH PIC (native/build-zstd.sh does
# this). Usage:  native/build-shared.sh [target-triple]
#
# The triple names match c3c --list-targets, so a non-host triple simply
# cross-compiles (used in CI for macos-x64: c3c ships no x86_64 mac binary).
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"

case "$(uname -s)" in
  Darwin) host_os=macos ;;
  Linux)  host_os=linux ;;
  *) echo "unsupported OS $(uname -s); run on macOS/Linux" >&2; exit 1 ;;
esac
case "$(uname -m)" in
  arm64|aarch64) host_arch=aarch64 ;;
  x86_64)        host_arch=x64 ;;
  *) echo "unsupported arch $(uname -m)" >&2; exit 1 ;;
esac
host="${host_os}-${host_arch}"

triple="${1:-$host}"
TARGET_ARGS=()
if [ "$triple" != "$host" ]; then
  TARGET_ARGS=(--target "$triple")
fi
OUT="$REPO_ROOT/$triple"

if [ ! -f "$OUT/libzstd.a" ]; then
  echo "$OUT/libzstd.a missing — run native/build-zstd.sh $triple first" >&2
  exit 1
fi

cd "$REPO_ROOT"
c3c dynamic-lib src/ktx/*.c3 src/capi/*.c3 \
  -O2 --reloc=PIC \
  -L "$OUT" -l zstd \
  --no-headers ${TARGET_ARGS[@]+"${TARGET_ARGS[@]}"} \
  -o "$OUT/ktx"

# c3c 0.8.2 ignores --no-headers for the standalone dynamic-lib command and
# mirrors the output path under headers/ — drop the clutter.
rm -rf "$REPO_ROOT/headers"

ls -l "$OUT"/libktx.* 2>/dev/null || ls -l "$OUT"/ktx.*
echo "wrote $triple shared library"
