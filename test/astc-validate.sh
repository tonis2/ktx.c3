#!/bin/sh
# Cross-validate the UASTC -> ASTC 4x4 mapper against Arm's reference decoder.
#
# Each input is encoded to UASTC (or used as is, if it is a .ktx2), transcoded
# with `ktx transcode -t astc`, and every level and layer is decoded twice: by
# astcenc from the ASTC blocks, and by this library's own UASTC decoder. The
# mapper is lossless, so the two must be identical pixel for pixel.
#
# usage: sh test/astc-validate.sh [inputs...]   (default: test/images/*.png)
# needs: astcenc on $PATH or in $ASTCENC, python3, and a built build/ktx-linux.
set -eu
cd "$(dirname "$0")/.."
KTX=build/ktx-linux
ASTCENC=${ASTCENC:-$(command -v astcenc-native || command -v astcenc-avx2 || command -v astcenc || true)}
[ -x "$KTX" ] || { echo "build $KTX first (c3c build)"; exit 1; }
[ -n "$ASTCENC" ] || { echo "set ASTCENC to an astcenc binary (github.com/ARM-software/astc-encoder)"; exit 1; }

TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT

if [ $# -eq 0 ]; then
	# The encoder reaches about half of UASTC's nineteen modes on the corpus,
	# so the default run adds a file of random valid blocks, every mode equally
	# often: a 256x256 UASTC made from a flat picture, its blocks replaced.
	python3 -I - "$TMP/flat.png" <<'EOF'
import sys, zlib, struct
w = h = 256
raw = b''.join(b'\0' + bytes([128, 128, 128, 255]) * w for _ in range(h))
def chunk(kind, body):
    return struct.pack('>I', len(body)) + kind + body + struct.pack('>I', zlib.crc32(kind + body))
png = b'\x89PNG\r\n\x1a\n' + chunk(b'IHDR', struct.pack('>IIBBBBB', w, h, 8, 6, 0, 0, 0))
open(sys.argv[1], 'wb').write(png + chunk(b'IDAT', zlib.compress(raw)) + chunk(b'IEND', b''))
EOF
	"$KTX" create --format uastc-linear -o "$TMP/flat.ktx2" "$TMP/flat.png" >/dev/null
	python3 -I - "$TMP/flat.ktx2" "$TMP/random_modes.ktx2" <<'EOF'
import sys, struct, random
# uastc.c3's HUFF_MODES, MODE_CODE_SIZES and MODE_HINT_BITS, and the pattern
# field each multi-subset mode carries: (bits, patterns in its table).
HUFF = [11,0,10,3,11,15,12,7,11,18,10,5,11,14,12,9,11,0,10,4,11,16,12,8,11,18,10,6,11,2,12,13,
        11,0,10,3,11,17,12,7,11,18,10,5,11,14,12,9,11,0,10,4,11,1,12,8,11,18,10,6,11,2,12,13,
        11,0,10,3,11,19,12,7,11,18,10,5,11,14,12,9,11,0,10,4,11,16,12,8,11,18,10,6,11,2,12,13,
        11,0,10,3,11,17,12,7,11,18,10,5,11,14,12,9,11,0,10,4,11,1,12,8,11,18,10,6,11,2,12,13]
CODE = [4, 6, 5, 5, 5, 5, 5, 5, 5, 5, 3, 2, 3, 5, 5, 7, 6, 6, 4]
HINT = [15, 15, 15, 15, 15, 15, 15, 15, 0, 23, 17, 17, 17, 23, 23, 23, 23, 23, 15]
PATTERN = {2: (5, 30), 3: (4, 11), 4: (5, 30), 7: (5, 19), 9: (5, 30), 16: (5, 30)}
d = bytearray(open(sys.argv[1], 'rb').read())
w, h = struct.unpack_from('<II', d, 20)
rng = random.Random(1)
blocks = bytearray()
for i in range(((w + 3) // 4) * ((h + 3) // 4)):
    mode = i % 19
    v = rng.getrandbits(128) & ~0x7F | rng.choice([b for b in range(128) if HUFF[b] == mode])
    if mode in PATTERN:
        bits, count = PATTERN[mode]
        at = CODE[mode] + HINT[mode]
        p = (v >> at) & ((1 << bits) - 1)
        v = v & ~(((1 << bits) - 1) << at) | (p % count) << at
    blocks += v.to_bytes(16, 'little')
# One level, stored raw at the end of the file.
struct.pack_into('<I', d, 44, 0)
d += bytes(-len(d) % 16)
struct.pack_into('<QQQ', d, 80, len(d), len(blocks), len(blocks))
open(sys.argv[2], 'wb').write(d + blocks)
EOF
	set -- test/images/*.png "$TMP/random_modes.ktx2"
fi

fail=0
checked=0
for input in "$@"; do
	name=$(basename "$input")
	case "$input" in
		*.ktx2) sources="$input" ;;
		*)
			# Every encoder level, with mips: the levels pick different modes.
			sources=""
			for level in 0 2 4; do
				out="$TMP/${name%.*}_q$level.ktx2"
				"$KTX" create --format uastc-linear --mipmap --effort "$level" -o "$out" "$input" >/dev/null
				sources="$sources $out"
			done
			;;
	esac
	for src in $sources; do
		"$KTX" transcode -t astc --raw -o "$TMP/astc.ktx2" "$src" >/dev/null
		info=$(python3 -I - "$src" <<'EOF'
import struct, sys
d = open(sys.argv[1], 'rb').read()
w, h, _, layers, faces, levels = struct.unpack_from('<6I', d, 20)
print(w, h, max(layers, 1), levels)
EOF
)
		set -- $info
		w=$1; h=$2; layers=$3; levels=$4
		layer=0
		while [ $layer -lt "$layers" ]; do
			level=0
			while [ $level -lt "$levels" ]; do
				"$KTX" extract --raw -a $layer -l $level -o "$TMP/blocks.bin" "$TMP/astc.ktx2" >/dev/null
				"$KTX" extract --raw -a $layer -l $level -o "$TMP/want.rgba" "$src" >/dev/null
				lw=$(( w >> level )); [ $lw -ge 1 ] || lw=1
				lh=$(( h >> level )); [ $lh -ge 1 ] || lh=1
				python3 -I - "$TMP/blocks.bin" "$TMP/in.astc" $lw $lh <<'EOF'
import struct, sys
blocks = open(sys.argv[1], 'rb').read()
w, h = int(sys.argv[3]), int(sys.argv[4])
hdr = struct.pack('<I3B', 0x5CA1AB13, 4, 4, 1) + w.to_bytes(3, 'little') + h.to_bytes(3, 'little') + (1).to_bytes(3, 'little')
open(sys.argv[2], 'wb').write(hdr + blocks)
EOF
				"$ASTCENC" -dl "$TMP/in.astc" "$TMP/got.png" -decode_unorm8 -silent
				if ! python3 -I - "$TMP/got.png" "$TMP/want.rgba" "$src l$level a$layer" <<'EOF'
import sys, zlib, struct
def png_rgba(path):
    d = open(path, 'rb').read()
    pos, idat, w, h, ct = 8, b'', 0, 0, 0
    while pos < len(d):
        n, kind = struct.unpack_from('>I4s', d, pos)
        body = d[pos + 8:pos + 8 + n]
        if kind == b'IHDR': w, h, _, ct = struct.unpack_from('>IIBB', body)
        if kind == b'IDAT': idat += body
        pos += 12 + n
    bpp = {6: 4, 2: 3}[ct]
    raw, out, prev = zlib.decompress(idat), bytearray(), bytearray(w * bpp)
    for y in range(h):
        f, row = raw[y * (w * bpp + 1)], bytearray(raw[y * (w * bpp + 1) + 1:(y + 1) * (w * bpp + 1)])
        for i in range(len(row)):
            a = row[i - bpp] if i >= bpp else 0
            b, c = prev[i], prev[i - bpp] if i >= bpp else 0
            if f == 1: row[i] = (row[i] + a) & 255
            elif f == 2: row[i] = (row[i] + b) & 255
            elif f == 3: row[i] = (row[i] + (a + b) // 2) & 255
            elif f == 4:
                p = a + b - c; pa, pb, pc = abs(p - a), abs(p - b), abs(p - c)
                row[i] = (row[i] + (a if pa <= pb and pa <= pc else b if pb <= pc else c)) & 255
        out += row if bpp == 4 else b''.join(bytes(row[i:i + 3]) + b'\xff' for i in range(0, len(row), 3))
        prev = row
    return bytes(out)
got, want = png_rgba(sys.argv[1]), open(sys.argv[2], 'rb').read()
bad = sum(1 for i in range(0, len(want), 4) if got[i:i + 4] != want[i:i + 4])
if bad:
    print(f'FAIL {sys.argv[3]}: {bad} of {len(want) // 4} pixels differ')
    sys.exit(1)
EOF
				then fail=1; fi
				checked=$((checked + 1))
				level=$((level + 1))
			done
			layer=$((layer + 1))
		done
	done
done
echo "astc-validate: $checked images checked, $([ $fail = 0 ] && echo 'all identical' || echo 'MISMATCHES above')"
exit $fail
