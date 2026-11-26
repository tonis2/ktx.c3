#!/bin/sh
# Cross-validate ktx.c3 output against the official Khronos `ktx` tool.
# Usage: sh test/cross-validate.sh [path-to-official-ktx]
# Builds the official tool from KTX-Software if not given and not in PATH:
#   cmake -S KTX-Software -B build -DKTX_FEATURE_TOOLS=ON && cmake --build build --target ktxtools
set -e
cd "$(dirname "$0")/.."

# Lookup order: explicit arg, PATH, then a local stash (e.g. the prebuilt
# KTX-Software release tools unpacked into native/ktxtools/, with
# libktx.4.dylib placed next to the binary).
KTX_OFFICIAL="${1:-$(command -v ktx || true)}"
[ -z "$KTX_OFFICIAL" ] && [ -x native/ktxtools/ktx ] && KTX_OFFICIAL=native/ktxtools/ktx
if [ -z "$KTX_OFFICIAL" ]; then
    echo "official ktx tool not found; pass its path as the first argument" >&2
    exit 1
fi

# The CLI target per platform (project.json): macOS links its own zstd.
case $(uname) in
    Darwin) TARGET=ktx ;;
    *) TARGET=ktx-linux ;;
esac
c3c build $TARGET
KTX=build/$TARGET
TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT

# Test image (checker + gradient) via ImageMagick or Python/PIL; without
# either, the committed corpus alpha image works just as well.
if command -v magick > /dev/null; then
    magick -size 64x64 gradient:red-blue -depth 8 "PNG32:$TMP/in.png"
elif python3 -c "import PIL" 2> /dev/null; then
    python3 -c "
from PIL import Image
img = Image.new('RGBA', (64, 64))
for y in range(64):
    for x in range(64):
        img.putpixel((x, y), (x*4, y*4, 255-x*4, 255))
img.save('$TMP/in.png')"
else
    cp test/images/alpha.png "$TMP/in.png"
fi

fail=0
for fmt in rgba8-srgb rgb8 bc1-srgb bc3-srgb bc4 bc5 bc7-srgb; do
    for extra in "--raw" "" "--zlib"; do
        out="$TMP/$fmt$extra.ktx2"
        "$KTX" create --format "$fmt" --mipmap $extra -o "$out" "$TMP/in.png" > /dev/null
        if "$KTX_OFFICIAL" validate "$out" > "$TMP/log" 2>&1; then
            echo "OK   $fmt ${extra:-—zstd}"
        else
            echo "FAIL $fmt ${extra:-—zstd}"; cat "$TMP/log"; fail=1
        fi
    done
done
# Basis formats pick their own supercompression (Zstd for UASTC — pure-C3
# encoder — and BasisLZ for ETC1S via bundled basisu).
for fmt in uastc etc1s; do
    out="$TMP/$fmt.ktx2"
    "$KTX" create --format "$fmt" --mipmap -o "$out" "$TMP/in.png" > /dev/null
    if "$KTX_OFFICIAL" validate "$out" > "$TMP/log" 2>&1; then
        echo "OK   $fmt"
    else
        echo "FAIL $fmt"; cat "$TMP/log"; fail=1
    fi
done
# Transcoded files: a DFD per target, sRGB and linear, with and without alpha.
cp test/images/alpha.png "$TMP/alpha.png"
for src in in alpha; do
    for basis in etc1s etc1s-linear uastc uastc-linear; do
        "$KTX" create --format "$basis" --mipmap -o "$TMP/$src-$basis.ktx2" "$TMP/$src.png" > /dev/null
        case $basis in
            etc1s*) targets="etc2 etc2-rgba bc7 rgba8" ;;
            *) targets="astc bc7 rgba8" ;;
        esac
        for target in $targets; do
            out="$TMP/$src-$basis-$target.ktx2"
            "$KTX" transcode -t "$target" -o "$out" "$TMP/$src-$basis.ktx2" > /dev/null
            if "$KTX_OFFICIAL" validate "$out" > "$TMP/log" 2>&1; then
                echo "OK   $src $basis -> $target"
            else
                echo "FAIL $src $basis -> $target"; cat "$TMP/log"; fail=1
            fi
        done
    done
done
exit $fail
