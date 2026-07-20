// Phase-3 tests (docs/basis-rewrite.md): BC1/BC3/BC7 transcode targets served
// by C3 RGBA decode + the library's own BCn encoders. Quality gate,
// self-calibrated against the golden data: the BCn re-encode decoded back to
// RGBA must stay within a per-format margin of the RGBA32 transcode's PSNR
// against the true source (the RGBA32 transcode itself is bit-exact to the
// golden dump, so PSNR(golden_rgba, src) IS the RGBA path's quality). The
// margin is the BCn re-encode loss; BC7 loses little, BC1/BC3 are 4/8 bpp.
//
// (Until the phase-6 cutover this compared against basisu's own block-level
// transcoders via FFI; the C3 BC7 path beat them by 2-7 dB, BC1/BC3 stayed
// within ~2 dB — recorded here since the FFI baseline is gone.)
module transcode_bcn_testutil;
import ktx::basis, ktx::bc7, ktx::bcn;
import ktx_testutil;
import std::io, std::io::file;

struct Score
{
	double bcn_db;    // BCn transcode, decoded, vs source
	double rgba_db;   // RGBA32 transcode (== golden dump) vs source
}

fn Score? score(String base, String img, uint tf_format) => @pool()
{
	char[] ktx2 = file::load(tmem, string::tformat("test/golden/%s.ktx2", base))!;
	char[] src = file::load(tmem, string::tformat("test/golden/%s.src.bin", img))!;
	char[] golden = file::load(tmem, string::tformat("test/golden/%s.l0.bin", base))!;

	basis::Transcoded ours = basis::transcode(tmem, ktx2, 0, 0, 0, tf_format,
		tf_format == basis::TF_BC1_RGB ? 8 : 16)!;

	char[] rgba;
	switch (tf_format)
	{
		case basis::TF_BC1_RGB:
			rgba = bcn::decode(tmem, bcn::BcnFormat.BC1, ours.data, ours.width, ours.height)!;
		case basis::TF_BC3_RGBA:
			rgba = bcn::decode(tmem, bcn::BcnFormat.BC3, ours.data, ours.width, ours.height)!;
		default:
			rgba = bc7::decode(tmem, ours.data, ours.width, ours.height)!;
	}
	// BC1 has no alpha; compare against an opaque source copy for it.
	char[] want = src;
	if (tf_format == basis::TF_BC1_RGB)
	{
		char[] opaque = alloc::new_array(tmem, char, (sz)src.len);
		opaque[..] = src[..];
		for (usz i = 3; i < opaque.len; i += 4) opaque[i] = 255;
		want = opaque;
	}
	return { .bcn_db = ktx_testutil::psnr(rgba, want), .rgba_db = ktx_testutil::psnr(golden, src) };
}

module transcode_bcn_tests @test;
import transcode_bcn_testutil;
import ktx::basis;
import std::io;

fn void bcn_targets_quality()
{
	String[2] bases = { "detail-uastc-q90-nomip", "detail-etc1s-q90-nomip" };
	String[3] names = { "BC7", "BC1", "BC3" };
	uint[3] formats = { basis::TF_BC7_RGBA, basis::TF_BC1_RGB, basis::TF_BC3_RGBA };
	// Allowed re-encode loss relative to the RGBA32 path's source PSNR.
	// (BC1 at 4 bpp genuinely loses ~8 dB on the high-detail image; basisu's
	// own BC1 transcode lost about the same when the FFI baseline existed.)
	double[3] margins = { 1.0, 9.0, 9.0 };
	uint checked;
	foreach (base : bases)
	{
		foreach (fi, tf : formats)
		{
			transcode_bcn_testutil::Score? s = transcode_bcn_testutil::score(base, "detail", tf);
			if (catch s) continue;   // goldens not generated
			io::printfn("  %s -> %s: %.2f dB (RGBA path %.2f dB)", base, names[fi], s.bcn_db, s.rgba_db);
			assert(s.bcn_db > s.rgba_db - margins[fi],
				"%s %s: %.2f dB more than %.1f dB below the RGBA path's %.2f dB",
				base, names[fi], s.bcn_db, margins[fi], s.rgba_db);
			checked++;
		}
	}
	assert(checked == 0 || checked == 6, "partial golden set: %d of 6", checked);
}
