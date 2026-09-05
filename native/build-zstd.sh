#!/usr/bin/env bash
# Build zstd into a static library and drop it in the per-target directory
# this repo's manifest.json / project.json link from (e.g.
# lib/macos-aarch64/libzstd.a, lib/windows-x64/zstd.lib). This replaced
# build-basisu.sh at the basis-rewrite phase-6 cutover (docs/basis-rewrite.md):
# the ETC1S/UASTC codec is pure C3 now, so zstd — plain C, no runtime deps —
# is the only native dependency left (src/ktx/zstd.c3 binds ZSTD_compress/
# decompress/compressBound/isError).
#
# zstd is NOT vendored; this fetches the pinned release tarball on demand into
# native/ (gitignored). The resulting archives ARE committed, so this only
# needs running to bump ZSTD_VERSION or add a platform — CI links the
# committed ones. .github/workflows/zstd.yml runs this for every platform on
# manual dispatch; download its artifacts and commit them.
#
# Usage:  native/build-zstd.sh [target-triple]
#   target-triple defaults to the host (macos-aarch64 / macos-x64 /
#   linux-x64 / linux-aarch64 / windows-x64). windows-x64 needs MSVC (cl/lib)
#   on PATH and is normally built on a Windows runner.
set -euo pipefail

ZSTD_VERSION="1.5.7"
ZSTD_URL="https://github.com/facebook/zstd/releases/download/v$ZSTD_VERSION/zstd-$ZSTD_VERSION.tar.gz"

REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
SRC="native/zstd-$ZSTD_VERSION"     # relative: MSVC under git-bash mangles absolute unix paths
BUILD="native/build-zstd"

cd "$REPO_ROOT"

triple="${1:-}"
if [ -z "$triple" ]; then
  case "$(uname -s)" in
    Darwin)             os=macos ;;
    Linux)              os=linux ;;
    MINGW*|MSYS*|CYGWIN*) os=windows ;;
    *) echo "unsupported OS $(uname -s); pass a target triple explicitly" >&2; exit 1 ;;
  esac
  case "$(uname -m)" in
    arm64|aarch64) arch=aarch64 ;;
    x86_64)        arch=x64 ;;
    *) echo "unsupported arch $(uname -m)" >&2; exit 1 ;;
  esac
  triple="${os}-${arch}"
fi
OUT="lib/$triple"

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

# Only lib/ is extracted: the tarball's tests/ holds symlinks that Windows tar
# cannot create (and nothing here compiles from outside lib/).
if [ ! -d "$SRC" ]; then
  mkdir -p native
  curl -fsSL "$ZSTD_URL" | tar xz -C native "zstd-$ZSTD_VERSION/lib"
fi

rm -rf "$BUILD"
mkdir -p "$BUILD" "$OUT"

# ASM disabled for uniform behavior across targets; single-threaded, since
# src/ktx/zstd.c3 binds only the simple one-shot API.
if [ "$triple" = "windows-x64" ]; then
  # MSVC options in dash form: git-bash mangles //X:... arguments.
  # -GS- because /GS-compiled objects reference __report_gsfailure, whose CRT
  # definition collides with the stub c3c's runtime ships when lld-link builds
  # ktx.dll against this archive.
  rm -f "$OUT/zstd.lib"
  cl -nologo -O2 -MD -GS- -DZSTD_DISABLE_ASM -DZSTD_MULTITHREAD=0 \
    -I "$SRC/lib" -I "$SRC/lib/common" \
    -c "$SRC"/lib/common/*.c "$SRC"/lib/compress/*.c "$SRC"/lib/decompress/*.c \
    -Fo"$BUILD/"
  lib -nologo "-OUT:$OUT/zstd.lib" "$BUILD"/*.obj
  echo "wrote $OUT/zstd.lib ($(du -h "$OUT/zstd.lib" | cut -f1))"
  exit 0
fi

# PIC because the archive links into both the CLI (PIE) and the libktx shared
# library.
CFLAGS="-O3 -fPIC -DZSTD_DISABLE_ASM -DZSTD_MULTITHREAD=0 $CFLAGS_EXTRA"
for f in "$SRC"/lib/common/*.c "$SRC"/lib/compress/*.c "$SRC"/lib/decompress/*.c; do
  "${CC:-cc}" $CFLAGS -I"$SRC/lib" -I"$SRC/lib/common" -c "$f" -o "$BUILD/$(basename "${f%.c}").o"
done

rm -f "$OUT/libzstd.a"
ar rc "$OUT/libzstd.a" "$BUILD"/*.o
ranlib "$OUT/libzstd.a" 2>/dev/null || true

echo "wrote $OUT/libzstd.a ($(du -h "$OUT/libzstd.a" | cut -f1))"
