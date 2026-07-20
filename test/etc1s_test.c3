// Phase-2 differential tests (docs/basis-rewrite.md): the pure-C3
// ETC1S/BasisLZ decoder must reproduce basisu's RGBA32 transcode bit-exactly
// on the whole golden matrix (test/gen-golden.sh; skips quietly when the
// goldens are absent).
module etc1s_tests @test;
import uastc_testutil;
import std::io;

fn void etc1s_bit_exact_vs_golden()
{
	String[5] images = { "gradient", "detail", "alpha", "gray", "normal" };
	uint checked;
	foreach (img : images)
	{
		String fmt = img == "normal" ? "etc1s-linear" : "etc1s";
		uint[3] qualities = { 10, 50, 90 };
		foreach (q : qualities)
		{
			if (uastc_testutil::check_golden(string::tformat("%s-%s-q%d-nomip", img, fmt, q), 1)) checked++;
			if (uastc_testutil::check_golden(string::tformat("%s-%s-q%d-mip", img, fmt, q), 7)) checked++;
		}
		if (uastc_testutil::check_golden(string::tformat("%s-%s-q100e10-nomip", img, fmt), 1)) checked++;
	}
	if (!checked)
	{
		io::printn("(etc1s golden files missing - run test/gen-golden.sh to enable the differential test)");
		return;
	}
	assert(checked == 35, "expected 35 golden files, checked %d", checked);
}
