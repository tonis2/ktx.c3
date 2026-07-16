#!/bin/sh
# Cross-validate ktx.c3 output against the official Khronos `ktx` tool.
# Usage: sh test/cross-validate.sh [path-to-official-ktx]
# Builds the official tool from KTX-Software if not given and not in PATH:
#   cmake -S KTX-Software -B build -DKTX_FEATURE_TOOLS=ON && cmake --build build --target ktxtools
set -e
cd "$(dirname "$0")/.."

KTX_OFFICIAL="${1:-$(command -v ktx || true)}"
if [ -z "$KTX_OFFICIAL" ]; then
    echo "official ktx tool not found; pass its path as the first argument" >&2
    exit 1
fi

c3c build
TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT

# Test image (checker + gradient), via ImageMagick or Python/PIL.
if command -v magick > /dev/null; then
    magick -size 64x64 gradient:red-blue -depth 8 "PNG32:$TMP/in.png"
else
    python3 -c "
from PIL import Image
img = Image.new('RGBA', (64, 64))
for y in range(64):
    for x in range(64):
        img.putpixel((x, y), (x*4, y*4, 255-x*4, 255))
img.save('$TMP/in.png')"
fi

fail=0
for fmt in rgba8-srgb rgb8 bc1-srgb bc3-srgb bc4 bc5 bc7-srgb; do
    for extra in "--raw" "" "--zlib"; do
        out="$TMP/$fmt$extra.ktx2"
        build/ktx create --format "$fmt" --mipmap $extra -o "$out" "$TMP/in.png" > /dev/null
        if "$KTX_OFFICIAL" validate "$out" > "$TMP/log" 2>&1; then
            echo "OK   $fmt ${extra:-—zstd}"
        else
            echo "FAIL $fmt ${extra:-—zstd}"; cat "$TMP/log"; fail=1
        fi
    done
done
exit $fail
