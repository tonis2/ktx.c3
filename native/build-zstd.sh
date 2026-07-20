#!/usr/bin/env bash
# Build zstd into a static library (libzstd.a) and drop it in the per-target
# directory this repo's manifest.json / project.json link from
# (e.g. lib/macos-aarch64/libzstd.a). This replaced build-basisu.sh at the
# basis-rewrite phase-6 cutover (docs/basis-rewrite.md): the ETC1S/UASTC codec
# is pure C3 now, so zstd — plain C, no runtime deps — is the only native
# dependency left (src/ktx/zstd.c3 binds ZSTD_compress/decompress/
# compressBound/isError).
#
# zstd is NOT vendored; this fetches the pinned release tarball on demand into
# native/ (gitignored). Run locally or in CI (.github/workflows/build-zstd.yml).
#
# Usage:  native/build-zstd.sh [target-triple]
#   target-triple defaults to the host (macos-aarch64 / macos-x64 /
#   linux-x64 / linux-aarch64). Windows (zstd.lib) is built with MSVC in CI.
set -euo pipefail

ZSTD_VERSION="1.5.7"
ZSTD_URL="https://github.com/facebook/zstd/releases/download/v$ZSTD_VERSION/zstd-$ZSTD_VERSION.tar.gz"

REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
SRC="$REPO_ROOT/native/zstd-$ZSTD_VERSION"
BUILD="$REPO_ROOT/native/build-zstd"

triple="${1:-}"
if [ -z "$triple" ]; then
  case "$(uname -s)" in
    Darwin) os=macos ;;
    Linux)  os=linux ;;
    *) echo "unsupported OS $(uname -s); pass a target triple explicitly" >&2; exit 1 ;;
  esac
  case "$(uname -m)" in
    arm64|aarch64) arch=aarch64 ;;
    x86_64)        arch=x64 ;;
    *) echo "unsupported arch $(uname -m)" >&2; exit 1 ;;
  esac
  triple="${os}-${arch}"
fi
OUT="$REPO_ROOT/lib/$triple"

# On macOS, pin a low deployment target (see build-shared.sh) and the arch from
# the triple — CI cross-compiles macos-x64 on arm64 runners.
CFLAGS_EXTRA=""
if [ "${triple%%-*}" = "macos" ]; then
  case "${triple##*-}" in
    x64)     mac_arch=x86_64 ;;
    aarch64) mac_arch=arm64 ;;
    *) echo "unknown macos arch in triple $triple" >&2; exit 1 ;;
  esac
  CFLAGS_EXTRA="-mmacosx-version-min=11.0 -arch $mac_arch"
  export MACOSX_DEPLOYMENT_TARGET=11.0
fi

if [ ! -d "$SRC" ]; then
  mkdir -p "$REPO_ROOT/native"
  curl -fsSL "$ZSTD_URL" | tar xz -C "$REPO_ROOT/native"
fi

# Compile the library sources directly (no cmake/make needed). ASM disabled for
# uniform behavior across targets; PIC because the archive links into both the
# CLI (PIE) and the libktx shared library.
rm -rf "$BUILD"
mkdir -p "$BUILD"
CFLAGS="-O3 -fPIC -DZSTD_DISABLE_ASM -DZSTD_MULTITHREAD=0 $CFLAGS_EXTRA"
for f in "$SRC"/lib/common/*.c "$SRC"/lib/compress/*.c "$SRC"/lib/decompress/*.c; do
  "${CC:-cc}" $CFLAGS -I"$SRC/lib" -I"$SRC/lib/common" -c "$f" -o "$BUILD/$(basename "${f%.c}").o"
done

mkdir -p "$OUT"
rm -f "$OUT/libzstd.a"
ar rc "$OUT/libzstd.a" "$BUILD"/*.o
ranlib "$OUT/libzstd.a" 2>/dev/null || true

echo "wrote $OUT/libzstd.a ($(du -h "$OUT/libzstd.a" | cut -f1))"
