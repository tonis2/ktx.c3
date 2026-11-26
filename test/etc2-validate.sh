#!/bin/sh
# Cross-validate the ETC1S -> ETC1/ETC2 mapper and the ETC2/EAC decoder against
# Ericsson's reference decoder, etcdec.cxx, as KTX-Software ships it.
#
# Each input is encoded to ETC1S at three quality levels, with mips, and so is a
# copy whose alpha is the image's green channel, so alpha slices are covered.
# Each is transcoded with `ktx transcode -t etc2` and `-t etc2-rgba`, and every
# level is decoded three ways: by etcdec from the blocks, by this library's ETC2
# decoder (`ktx extract`), and by its ETC1S decoder. The two ETC2 decoders must
# agree pixel for pixel, and the colour must equal the ETC1S decode. Alpha is
# fitted to EAC, so its error against the ETC1S decode is reported.
#
# The mapper writes only differential blocks, so random blocks of every ETC2
# mode, of punch-through alpha, and of EAC A8, R11 and RG11 check the rest of
# the decoder.
#
# usage: sh test/etc2-validate.sh [inputs...]   (default: test/images/*.png)
# needs: a built build/ktx-linux, python3, a C++ compiler ($CXX, default c++),
#   and the path of etcdec.cxx in $ETCDEC:
#     curl -O https://raw.githubusercontent.com/KhronosGroup/KTX-Software/main/external/etcdec/etcdec.cxx
#     ETCDEC=$PWD/etcdec.cxx sh test/etc2-validate.sh
# optional: $BASISU, a basisu binary, adds basisu's own ETC1S -> ETC2 RGBA
#   output as a yardstick: its colour blocks must match ours byte for byte, and
#   its alpha error is reported beside ours.
set -eu
cd "$(dirname "$0")/.."
KTX=build/ktx-linux
CXX=${CXX:-c++}
ETCDEC=${ETCDEC:-}
BASISU=${BASISU:-}
[ -x "$KTX" ] || { echo "build $KTX first (c3c build)"; exit 1; }
[ -f "$ETCDEC" ] || { echo "set ETCDEC to etcdec.cxx (KTX-Software external/etcdec)"; exit 1; }

TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT

# The oracle: whole images through etcdec, written in this library's output
# conventions (R11 as (r, r, r, 255), RG11 as (r, g, 0, 255), the top 8 of 11 bits).
cat > "$TMP/etcref.cxx" <<'EOF'
#include ETCDEC
#include <vector>
#include <cstring>
static unsigned be32(const uint8 *p) { return (unsigned)p[0] << 24 | p[1] << 16 | p[2] << 8 | p[3]; }
int main(int argc, char **argv)
{
	int fmt = atoi(argv[1]), w = atoi(argv[2]), h = atoi(argv[3]);
	FILE *f = fopen(argv[4], "rb");
	std::vector<uint8> in(1 << 26);
	size_t n = fread(in.data(), 1, in.size(), f);
	fclose(f);
	int bw = (w + 3) / 4, bh = (h + 3) / 4;
	int bytes = (fmt == 151 || fmt == 152 || fmt == 155) ? 16 : 8;
	if (n != (size_t)bw * bh * bytes) { fprintf(stderr, "etcref: %zu bytes, want %d\n", n, bw * bh * bytes); return 1; }
	setupAlphaTable();
	std::vector<uint8> out((size_t)w * h * 4);
	for (int by = 0; by < bh; by++)
	for (int bx = 0; bx < bw; bx++)
	{
		const uint8 *b = &in[((size_t)by * bw + bx) * bytes];
		uint8 px[64];
		memset(px, 255, sizeof px);
		switch (fmt)
		{
		case 147: case 148:
			decompressBlockETC2c(be32(b), be32(b + 4), px, 4, 4, 0, 0, 4);
			break;
		case 149: case 150:
			decompressBlockETC21BitAlphaC(be32(b), be32(b + 4), px, NULL, 4, 4, 0, 0, 4);
			break;
		case 151: case 152:
			decompressBlockETC2c(be32(b + 8), be32(b + 12), px, 4, 4, 0, 0, 4);
			decompressBlockAlphaC((uint8 *)b, px + 3, 4, 4, 0, 0, 4);
			break;
		case 153: case 155:
			formatSigned = 0;
			for (int c = 0; c < (fmt == 155 ? 2 : 1); c++)
			{
				uint16 v[16];
				decompressBlockAlpha16bitC((uint8 *)b + 8 * c, (uint8 *)v, 4, 4, 0, 0, 1);
				for (int i = 0; i < 16; i++)
				{
					px[i * 4 + c] = v[i] >> 8;
					if (fmt == 153) px[i * 4 + 1] = px[i * 4 + 2] = v[i] >> 8;
					else px[i * 4 + 2] = 0;
				}
			}
			break;
		default:
			fprintf(stderr, "etcref: vkFormat %d\n", fmt);
			return 1;
		}
		for (int y = 0; y < 4 && by * 4 + y < h; y++)
		for (int x = 0; x < 4 && bx * 4 + x < w; x++)
			memcpy(&out[(((size_t)by * 4 + y) * w + bx * 4 + x) * 4], &px[(y * 4 + x) * 4], 4);
	}
	f = fopen(argv[5], "wb");
	fwrite(out.data(), 1, out.size(), f);
	fclose(f);
	return 0;
}
EOF
"$CXX" -O2 -w -DETCDEC="\"$ETCDEC\"" -o "$TMP/etcref" "$TMP/etcref.cxx"

# Shared Python: PNG read/write, the KTX2 and KTX1 level index, the oracle.
cat > "$TMP/etc2lib.py" <<'EOF'
import os, struct, subprocess, zlib

def png_read(path):
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
    return w, h, bytes(out)

def png_write(path, w, h, rgba):
    def chunk(kind, body):
        return struct.pack('>I', len(body)) + kind + body + struct.pack('>I', zlib.crc32(kind + body))
    raw = b''.join(b'\0' + rgba[y * w * 4:(y + 1) * w * 4] for y in range(h))
    open(path, 'wb').write(b'\x89PNG\r\n\x1a\n' + chunk(b'IHDR', struct.pack('>IIBBBBB', w, h, 8, 6, 0, 0, 0))
                           + chunk(b'IDAT', zlib.compress(raw)) + chunk(b'IEND', b''))

def ktx2_levels(path):
    """vkFormat, width, height, and each level's payload of an unsupercompressed KTX2."""
    d = open(path, 'rb').read()
    fmt, _, w, h, _, _, _, levels, scheme = struct.unpack_from('<9I', d, 12)
    assert scheme == 0, 'transcode with --raw'
    out = []
    for l in range(max(levels, 1)):
        off, n, _ = struct.unpack_from('<3Q', d, 80 + 24 * l)
        out.append(d[off:off + n])
    return fmt, w, h, out

def ktx1_levels(path):
    d = open(path, 'rb').read()
    levels, kv = struct.unpack_from('<2I', d, 56)
    pos, out = 64 + kv, []
    for _ in range(max(levels, 1)):
        n = struct.unpack_from('<I', d, pos)[0]
        out.append(d[pos + 4:pos + 4 + n])
        pos += 4 + n + (-n % 4)
    return out

def oracle(tmp, fmt, blocks, w, h):
    """RGBA8 from etcdec."""
    open(f'{tmp}/oracle.bin', 'wb').write(blocks)
    subprocess.run([f'{tmp}/etcref', str(fmt), str(w), str(h), f'{tmp}/oracle.bin', f'{tmp}/oracle.rgba'], check=True)
    return open(f'{tmp}/oracle.rgba', 'rb').read()

def alpha_stats(got, want, stats):
    """Append the alpha error against the ETC1S decode; opaque levels don't count."""
    if all(v == 255 for v in want[3::4]): return
    errs = [abs(got[i] - want[i]) for i in range(3, len(want), 4)]
    with open(stats, 'a') as f:
        f.write(f'{sum(errs)} {sum(e * e for e in errs)} {max(errs)} {len(errs)}\n')
EOF

# One level: our decode against etcdec's, and the colour against the ETC1S decode.
cat > "$TMP/check.py" <<'EOF'
import sys
tmp = sys.argv[1]
sys.path.insert(0, tmp)
from etc2lib import *
etc2, level, ours_png, want_path, label, stats = sys.argv[2], int(sys.argv[3]), sys.argv[4], sys.argv[5], sys.argv[6], sys.argv[7]
fmt, w, h, levels = ktx2_levels(etc2)
lw, lh = max(w >> level, 1), max(h >> level, 1)
got = oracle(tmp, fmt, levels[level], lw, lh)
pw, ph, ours = png_read(ours_png)
assert (pw, ph) == (lw, lh)
fail = 0
bad = sum(1 for i in range(0, len(got), 4) if got[i:i + 4] != ours[i:i + 4])
if bad:
    print(f'FAIL {label}: our ETC2 decoder differs from etcdec on {bad} of {lw * lh} pixels')
    fail = 1
if want_path != '-':
    want = open(want_path, 'rb').read()
    rgb_bad = sum(1 for i in range(0, len(want), 4) if got[i:i + 3] != want[i:i + 3])
    if rgb_bad:
        print(f'FAIL {label}: colour differs from the ETC1S decode on {rgb_bad} of {lw * lh} pixels')
        fail = 1
    if stats != '-': alpha_stats(got, want, stats)
sys.exit(fail)
EOF

# basisu's ETC2 RGBA of the same ETC1S file: colour blocks must match, alpha error reported.
cat > "$TMP/basisu.py" <<'EOF'
import sys
tmp = sys.argv[1]
sys.path.insert(0, tmp)
from etc2lib import *
etc2, ktx1, wants, label, stats = sys.argv[2], sys.argv[3], sys.argv[4:-2], sys.argv[-2], sys.argv[-1]
fmt, w, h, ours = ktx2_levels(etc2)
theirs = ktx1_levels(ktx1)
fail = 0
for l, want_path in enumerate(wants):
    a, b = ours[l], theirs[l]
    same = sum(1 for i in range(0, len(a), 16) if a[i + 8:i + 16] == b[i + 8:i + 16])
    if len(a) != len(b) or same != len(a) // 16:
        print(f'FAIL {label} l{l}: {len(a) // 16 - same} colour blocks differ from basisu')
        fail = 1
    alpha_stats(oracle(tmp, fmt, b, max(w >> l, 1), max(h >> l, 1)), open(want_path, 'rb').read(), stats)
sys.exit(fail)
EOF

if [ $# -eq 0 ]; then set -- test/images/*.png; fi

# Each input, and a copy whose alpha is its green channel: noisy or smooth
# alpha, beside the one corpus image that has alpha of its own.
python3 -I - "$TMP" "$@" <<'EOF'
import sys, os
sys.path.insert(0, sys.argv[1])
from etc2lib import png_read, png_write
for path in sys.argv[2:]:
    w, h, px = png_read(path)
    name = os.path.splitext(os.path.basename(path))[0]
    png_write(f'{sys.argv[1]}/in_{name}.png', w, h, px)
    a = bytearray(px)
    a[3::4] = px[1::4]
    png_write(f'{sys.argv[1]}/in_{name}_ga.png', w, h, bytes(a))
EOF

fail=0
checked=0
: > "$TMP/ours.stats"
: > "$TMP/basisu.stats"
for input in "$TMP"/in_*.png; do
	name=$(basename "$input" .png)
	name=${name#in_}
	for quality in 10 50 100; do
		src="$TMP/${name}_q$quality.ktx2"
		"$KTX" create --format etc1s --quality $quality --mipmap -o "$src" "$input" >/dev/null
		levels=$(python3 -I -c 'import struct,sys; print(max(struct.unpack_from("<I", open(sys.argv[1],"rb").read(), 40)[0], 1))' "$src")
		wants=""
		level=0
		while [ $level -lt "$levels" ]; do
			"$KTX" extract --raw -l $level -o "$TMP/want_l$level.rgba" "$src" >/dev/null
			wants="$wants $TMP/want_l$level.rgba"
			level=$((level + 1))
		done
		for target in etc2 etc2-rgba; do
			out="$TMP/out_$target.ktx2"
			"$KTX" transcode -t $target --raw -o "$out" "$src" >/dev/null
			# Alpha counts once: from etc2-rgba, which every input gets.
			stats=-
			[ $target = etc2-rgba ] && stats="$TMP/ours.stats"
			level=0
			while [ $level -lt "$levels" ]; do
				"$KTX" extract -l $level -o "$TMP/ours.png" "$out" >/dev/null
				if ! python3 -I "$TMP/check.py" "$TMP" "$out" $level "$TMP/ours.png" "$TMP/want_l$level.rgba" \
					"$name q$quality $target l$level" "$stats"
				then fail=1; fi
				checked=$((checked + 1))
				level=$((level + 1))
			done
		done
		if [ -n "$BASISU" ]; then
			rm -rf "$TMP/bu" && mkdir "$TMP/bu"
			(cd "$TMP/bu" && "$BASISU" -unpack -ktx_only -format_only 1 "$src" >/dev/null 2>&1)
			if ! python3 -I "$TMP/basisu.py" "$TMP" "$TMP/out_etc2-rgba.ktx2" "$TMP"/bu/*ETC2_RGBA*.ktx $wants \
				"$name q$quality" "$TMP/basisu.stats"
			then fail=1; fi
		fi
	done
done

# Random blocks: a flat ETC1S picture transcoded to each block size, its blocks
# replaced, and for R11, RG11 and punch-through the vkFormat relabelled (the
# DFD is left as it is; nothing here reads it).
python3 -I - "$TMP" <<'EOF'
import sys
sys.path.insert(0, sys.argv[1])
from etc2lib import png_write
png_write(f'{sys.argv[1]}/flat.png', 256, 256, bytes([128, 128, 128, 255]) * 65536)
EOF
"$KTX" create --format etc1s -o "$TMP/flat.ktx2" "$TMP/flat.png" >/dev/null
"$KTX" transcode -t etc2 --raw -o "$TMP/flat8.ktx2" "$TMP/flat.ktx2" >/dev/null
"$KTX" transcode -t etc2-rgba --raw -o "$TMP/flat16.ktx2" "$TMP/flat.ktx2" >/dev/null
python3 -I - "$TMP" <<'EOF'
import sys, struct, random
tmp = sys.argv[1]
sys.path.insert(0, tmp)
from etc2lib import ktx2_levels
rng = random.Random(1)

def mode(v, punch):
    """The ETC2 mode a colour block decodes in."""
    if not punch and not (v >> 33) & 1: return 'individual'
    for c, name in ((0, 'T'), (1, 'H'), (2, 'planar')):
        base, d = (v >> (59 - 8 * c)) & 31, (v >> (56 - 8 * c)) & 7
        s = base + (d - 8 if d >= 4 else d)
        if s < 0 or s > 31: return name
    return 'differential'

def colour_blocks(count, punch):
    """Random colour blocks, every mode equally often."""
    modes = ['differential', 'T', 'H', 'planar'] + ([] if punch else ['individual'])
    out = bytearray()
    for i in range(count):
        want = modes[i % len(modes)]
        while True:
            v = rng.getrandbits(64)
            if mode(v, punch) == want: break
        out += v.to_bytes(8, 'big')
    return out

def write(base, fmt, blocks, name):
    d = bytearray(open(f'{tmp}/{base}', 'rb').read())
    _, _, _, levels = ktx2_levels(f'{tmp}/{base}')
    assert len(levels[0]) == len(blocks)
    struct.pack_into('<I', d, 12, fmt)
    off = struct.unpack_from('<Q', d, 80)[0]
    d[off:off + len(blocks)] = blocks
    open(f'{tmp}/{name}', 'wb').write(d)

n = 64 * 64
write('flat8.ktx2', 147, colour_blocks(n, False), 'random_rgb.ktx2')
write('flat8.ktx2', 149, colour_blocks(n, True), 'random_rgb_a1.ktx2')
colour = colour_blocks(n, False)
rgba = bytearray()
for i in range(n):
    rgba += rng.getrandbits(64).to_bytes(8, 'big') + colour[i * 8:i * 8 + 8]
write('flat16.ktx2', 151, rgba, 'random_rgba.ktx2')
write('flat8.ktx2', 153, rng.getrandbits(64 * n).to_bytes(8 * n, 'big'), 'random_r11.ktx2')
write('flat16.ktx2', 155, rng.getrandbits(128 * n).to_bytes(16 * n, 'big'), 'random_rg11.ktx2')
EOF
for kind in rgb rgb_a1 rgba r11 rg11; do
	"$KTX" extract -o "$TMP/ours.png" "$TMP/random_$kind.ktx2" >/dev/null
	if ! python3 -I "$TMP/check.py" "$TMP" "$TMP/random_$kind.ktx2" 0 "$TMP/ours.png" - "random $kind blocks" -
	then fail=1; fi
	checked=$((checked + 1))
done

report() {
	python3 -I -c '
import sys
rows = [list(map(int, l.split())) for l in open(sys.argv[1]) if l.strip()]
s, sq, mx, n = sum(r[0] for r in rows), sum(r[1] for r in rows), max([r[2] for r in rows] or [0]), sum(r[3] for r in rows)
print(f"{sys.argv[2]}: alpha mean abs error {s / max(n, 1):.4f}, mse {sq / max(n, 1):.4f}, max {mx}, over {n} texels")
' "$1" "$2"
}
report "$TMP/ours.stats" "ours  "
[ -z "$BASISU" ] || report "$TMP/basisu.stats" "basisu"
echo "etc2-validate: $checked images checked, $([ $fail = 0 ] && echo 'all identical' || echo 'MISMATCHES above')"
exit $fail
