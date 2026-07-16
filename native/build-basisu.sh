#!/usr/bin/env bash
# Build basis_universal's encoder + transcoder + C API into a single static
# library (libbasisu.a) and drop it in the per-target directory this repo's
# manifest.json / project.json link from (e.g. macos-aarch64/libbasisu.a).
#
# basis_universal is NOT vendored (it's large and only needed to rebuild the
# lib). This script fetches it at a pinned commit on demand — into native/, which
# is gitignored. Run it locally or in CI (.github/workflows/build-basisu.yml).
# The C API (bu_* encode, bt_* transcode) is bound from src/ktx/basis.c3. basis
# bundles a full zstd that also satisfies the container's ZSTD_* calls, so the
# final binary needs no separate system libzstd.
#
# Usage:  native/build-basisu.sh [target-triple]
#   target-triple defaults to the host (macos-aarch64 / macos-x64 /
#   linux-x64 / linux-aarch64). Windows is built via CMake+MSVC in CI.
set -euo pipefail

BASIS_REPO="https://github.com/BinomialLLC/basis_universal.git"
BASIS_COMMIT="1b33fd5098c6e7b58324146b8f5518cbb4cdfb72"

REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
SRC="$REPO_ROOT/native/basis_universal"
BUILD="$REPO_ROOT/native/build"

# Resolve the c3c target triple for the host unless one was given.
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
OUT="$REPO_ROOT/$triple"

# Fetch basis_universal at the pinned commit (blobless partial clone keeps it
# lighter). Re-run is cheap: it just checks out the pinned commit again.
if [ ! -d "$SRC/.git" ]; then
  git clone --filter=blob:none "$BASIS_REPO" "$SRC"
fi
git -C "$SRC" fetch --depth 1 origin "$BASIS_COMMIT"
git -C "$SRC" checkout -q "$BASIS_COMMIT"

# Build the encoder static lib (bundles the transcoder + zstd; no examples/OpenCL).
cmake -S "$SRC" -B "$BUILD" -DCMAKE_BUILD_TYPE=Release \
  -DBASISU_EXAMPLES=OFF -DBASISU_OPENCL=OFF -DBASISU_STATIC=ON
cmake --build "$BUILD" --target basisu_encoder -j"$(getconf _NPROCESSORS_ONLN 2>/dev/null || echo 4)"

# Compile the two C-API wrappers with the encoder's flags and archive everything
# into one libbasisu.a.
CXXFLAGS="-std=c++17 -O2 -fno-exceptions -fno-rtti -DBASISD_SUPPORT_KTX2_ZSTD=1"
INCLUDES="-I$SRC -I$SRC/encoder -I$SRC/transcoder -I$SRC/zstd"
"${CXX:-c++}" $CXXFLAGS $INCLUDES -c "$SRC/encoder/basisu_wasm_api.cpp"            -o "$BUILD/bu_api.o"
"${CXX:-c++}" $CXXFLAGS $INCLUDES -c "$SRC/encoder/basisu_wasm_transcoder_api.cpp" -o "$BUILD/bt_api.o"

mkdir -p "$OUT"
cp "$BUILD/libbasisu_encoder.a" "$OUT/libbasisu.a"
ar r "$OUT/libbasisu.a" "$BUILD/bu_api.o" "$BUILD/bt_api.o"
ranlib "$OUT/libbasisu.a" 2>/dev/null || true

echo "wrote $OUT/libbasisu.a ($(du -h "$OUT/libbasisu.a" | cut -f1))"
