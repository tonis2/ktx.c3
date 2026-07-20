// Phase-1 differential tests (docs/basis-rewrite.md): the pure-C3 UASTC
// decoder must reproduce basisu's RGBA32 transcode bit-exactly on the whole
// golden matrix. Goldens are produced by test/gen-golden.sh (gitignored);
// when absent (fresh clone) these tests skip quietly.
module uastc_testutil;
import ktx::basis;
import std::io, std::io::file;

fn bool check_golden(String base, uint levels)
{
	char[]? ktx2 = file::load(mem, string::tformat("test/golden/%s.ktx2", base));
	if (catch ktx2)
	{
		return false;   // goldens not generated
	}
	defer free(ktx2);

	for (uint l = 0; l < levels; l++)
	{
		char[] want = file::load(mem, string::tformat("test/golden/%s.l%d.bin", base, l))!!;
		defer free(want);

		basis::Transcoded t = basis::transcode(mem, ktx2, l, 0, 0, basis::TF_RGBA32, 4)!!;
		defer free(t.data);

		uint dim = 64u >> l;
		if (dim == 0) dim = 1;
		assert(t.width == dim && t.height == dim, "%s level %d: got %dx%d", base, l, t.width, t.height);
		assert(t.data.len == want.len, "%s level %d: %d bytes vs %d", base, l, t.data.len, want.len);
		foreach (i, b : want)
		{
			assert(t.data[i] == b, "%s level %d differs at byte %d: got %d want %d",
				base, l, i, t.data[i], b);
		}
	}
	return true;
}

module uastc_tests @test;
import uastc_testutil;
import std::io;

fn void uastc_bit_exact_vs_golden()
{
	String[5] images = { "gradient", "detail", "alpha", "gray", "normal" };
	uint checked;
	foreach (img : images)
	{
		String fmt = img == "normal" ? "uastc-linear" : "uastc";
		uint[3] qualities = { 10, 50, 90 };
		foreach (q : qualities)
		{
			if (uastc_testutil::check_golden(string::tformat("%s-%s-q%d-nomip", img, fmt, q), 1)) checked++;
			if (uastc_testutil::check_golden(string::tformat("%s-%s-q%d-mip", img, fmt, q), 7)) checked++;
		}
		// max-effort profile: exercises the encoder's full mode set
		if (uastc_testutil::check_golden(string::tformat("%s-%s-q100e10-nomip", img, fmt), 1)) checked++;
	}
	if (!checked)
	{
		io::printn("(uastc golden files missing - run test/gen-golden.sh to enable the differential test)");
		return;
	}
	// If goldens exist at all, the full matrix must be there and bit-exact —
	// a partial run must not quietly pass.
	assert(checked == 35, "expected 35 golden files, checked %d", checked);
}
