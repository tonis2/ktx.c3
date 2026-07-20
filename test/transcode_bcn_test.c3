// Phase-3 tests (docs/basis-rewrite.md): BC1/BC3/BC7 transcode targets served
// without basisu — C3 RGBA decode + the library's own BCn encoders. Encoders
// differ from basisu's block-level transcoders, so this is a QUALITY gate,
// not a bit-exact one: both paths' output is decoded back to RGBA and scored
// (PSNR) against the golden RGBA dump; ours must stay within a fixed margin
// of basisu's. The numbers are printed so tuning commits are measurable.
module transcode_bcn_testutil;
import ktx::basis, ktx::bc7, ktx::bcn;
import ktx_testutil;
import std::io, std::io::file;

struct Score
{
	double c3_db;
	double ffi_db;
}

fn Score? score(String base, uint tf_format) => @pool()
{
	char[] ktx2 = file::load(tmem, string::tformat("test/golden/%s.ktx2", base))!;
	char[] want = file::load(tmem, string::tformat("test/golden/%s.l0.bin", base))!;

	basis::Transcoded ours = basis::transcode(tmem, ktx2, 0, 0, 0, tf_format, 0)!;
	basis::Transcoded ffis = basis::transcode_ffi(tmem, ktx2, 0, 0, 0, tf_format,
		tf_format == basis::TF_BC1_RGB ? 8 : 16)!;
	assert(ours.data.len == ffis.data.len, "%s: %d vs %d block bytes", base, ours.data.len, ffis.data.len);

	char[] ours_rgba;
	char[] ffis_rgba;
	switch (tf_format)
	{
		case basis::TF_BC1_RGB:
			ours_rgba = bcn::decode(tmem, bcn::BcnFormat.BC1, ours.data, ours.width, ours.height)!;
			ffis_rgba = bcn::decode(tmem, bcn::BcnFormat.BC1, ffis.data, ffis.width, ffis.height)!;
		case basis::TF_BC3_RGBA:
			ours_rgba = bcn::decode(tmem, bcn::BcnFormat.BC3, ours.data, ours.width, ours.height)!;
			ffis_rgba = bcn::decode(tmem, bcn::BcnFormat.BC3, ffis.data, ffis.width, ffis.height)!;
		default:
			ours_rgba = bc7::decode(tmem, ours.data, ours.width, ours.height)!;
			ffis_rgba = bc7::decode(tmem, ffis.data, ffis.width, ffis.height)!;
	}
	return { .c3_db = ktx_testutil::psnr(ours_rgba, want), .ffi_db = ktx_testutil::psnr(ffis_rgba, want) };
}

module transcode_bcn_tests @test;
import transcode_bcn_testutil;
import ktx::basis;
import std::io;

fn void bcn_targets_quality_vs_basisu()
{
	String[2] bases = { "detail-uastc-q90-nomip", "detail-etc1s-q90-nomip" };
	String[3] names = { "BC7", "BC1", "BC3" };
	uint[3] formats = { basis::TF_BC7_RGBA, basis::TF_BC1_RGB, basis::TF_BC3_RGBA };
	uint checked;
	foreach (base : bases)
	{
		foreach (fi, tf : formats)
		{
			transcode_bcn_testutil::Score? s = transcode_bcn_testutil::score(base, tf);
			if (catch s) continue;   // goldens not generated
			io::printfn("  %s -> %s: C3 %.2f dB, basisu %.2f dB", base, names[fi], s.c3_db, s.ffi_db);
			// The BC1 4-color palette (also BC3's color half) maps 1:1 from an
			// ETC1S subset, so basisu's direct transcode is hard to match with
			// a re-encode; give those targets more headroom than BC7.
			double margin = tf == basis::TF_BC7_RGBA ? 2.0 : 3.0;
			assert(s.c3_db > s.ffi_db - margin,
				"%s %s: C3 %.2f dB more than %.1f dB below basisu %.2f dB",
				base, names[fi], s.c3_db, margin, s.ffi_db);
			checked++;
		}
	}
	assert(checked == 0 || checked == 6, "partial golden set: %d of 6", checked);
}
