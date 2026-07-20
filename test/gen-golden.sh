#!/bin/sh
# Golden decode oracles for the pure-C3 basis rewrite (docs/basis-rewrite.md,
# phase 0). Encodes the committed corpus in test/images/ with the bundled
# basis_universal encoder across a settings matrix, then records every mip
# level's RGBA32 transcode next to the .ktx2 as <name>.l<level>.bin. Later
# phases diff the C3 decoders bit-exactly against these dumps.
#
# The dumps are taken with `extract --ffi` and files are encoded with
# `create --ffi` so the oracle is ALWAYS basisu, even after `basis::transcode`
# and `basis::encode` start routing through the C3 codec.
#
# Output lands in test/golden/ (gitignored) — a local artifact, regenerated
# any time with this script while basisu is still linked.
set -e
cd "$(dirname "$0")/.."

KTX=build/ktx
[ -x "$KTX" ] || c3c build

rm -rf test/golden
mkdir -p test/golden

dump_levels() # <base>
{
	levels=$($KTX info "$1.ktx2" | awk '/^  levels:/ { print $2 }')
	l=0
	while [ "$l" -lt "$levels" ]; do
		$KTX extract --raw --ffi --level "$l" -o "$1.l$l.bin" "$1.ktx2" > /dev/null
		l=$((l + 1))
	done
}

for img in gradient detail alpha gray normal; do
	# non-color data (the normal map) uses the linear variants
	case $img in
		normal) fmts="etc1s-linear uastc-linear" ;;
		*)      fmts="etc1s uastc" ;;
	esac

	# Raw source pixels, so encoder tests can score PSNR against the true
	# source (the test binary has no PNG decoder).
	$KTX create -f rgba8-srgb --raw -o test/golden/tmp-src.ktx2 "test/images/$img.png" > /dev/null
	$KTX extract --raw -o "test/golden/$img.src.bin" test/golden/tmp-src.ktx2 > /dev/null
	rm -f test/golden/tmp-src.ktx2
	for fmt in $fmts; do
		for q in 10 50 90; do
			for mip in nomip mip; do
				base="test/golden/$img-$fmt-q$q-$mip"
				set -- --ffi -f "$fmt" --quality "$q" -o "$base.ktx2" "test/images/$img.png"
				[ "$mip" = mip ] && set -- -m "$@"
				$KTX create "$@" > /dev/null
				dump_levels "$base"
			done
		done

		# Max effort, no RDO: the encoder evaluates its full mode set, giving
		# the decoders much broader mode coverage than the fast profiles.
		base="test/golden/$img-$fmt-q100e10-nomip"
		$KTX create -f "$fmt" --quality 100 --effort 10 -o "$base.ktx2" "test/images/$img.png" > /dev/null
		dump_levels "$base"
	done
done

count=$(ls test/golden/*.ktx2 | wc -l | tr -d ' ')
bins=$(ls test/golden/*.bin | wc -l | tr -d ' ')
echo "generated $count golden ktx2 files, $bins RGBA32 dumps in test/golden/"
