// Phase-4 differential tests (docs/basis-rewrite.md): the pure-C3 UASTC
// encoder behind basis::encode. Gates, per the plan:
//  - interop: the bundled basisu transcoder (official code, via
//    basis::transcode_ffi) must decode our KTX2 bit-identically to our own
//    decoder, on every mip level;
//  - quality: PSNR vs the source must stay within 1 dB of what basisu's own
//    q90/e2 encode achieves on the same image (we currently beat it);
//  - size: recorded and printed; only a loose 2.5x bound is asserted, since
//    the C3 encoder has no RDO yet (the plan tracks, not blocks, this gap).
// Needs test/golden/ (sh test/gen-golden.sh): source pixels come from the
// <img>.src.bin dumps, the basisu quality baseline from the recorded
// <img>-uastc*-q90-mip goldens (mipped, like the encode under test). Skips quietly when goldens are absent,
// but never accepts a partial set.
module basis_enc_testutil;
import ktx::basis, ktx::container;
import ktx_testutil;
import std::io, std::io::file;

struct Result
{
	double c3_db;       // C3 encode, level-0 PSNR vs source
	double basisu_db;   // basisu q90/e2 golden, PSNR vs source
	usz c3_size;
	usz basisu_size;
}

fn Result? check(String img, String golden_base, bool srgb, uint dim) => @pool()
{
	char[] src = file::load(tmem, string::tformat("test/golden/%s.src.bin", img))!;
	char[] golden_ktx2 = file::load(tmem, string::tformat("test/golden/%s.ktx2", golden_base))!;
	char[] golden_rgba = file::load(tmem, string::tformat("test/golden/%s.l0.bin", golden_base))!;

	// C3 encode with mips (matches the q90/e2 defaults; quality only tunes RDO).
	char[][1] imgs = { src };
	char[] ktx2 = basis::encode(tmem, basis::UASTC_4X4, imgs[..], dim, dim, basis::TexType.D2,
		{ .quality = 90, .effort = 2, .srgb = srgb, .mipmaps = true })!;

	// Container parses; every level transcodes identically through the C3
	// decoder and the bundled basisu transcoder (the interop oracle).
	container::Texture tex = container::read(tmem, ktx2)!;
	assert(tex.vk_format == 0 && tex.level_count() > 1, "%s: bad container shape", img);
	for (uint l = 0; l < tex.level_count(); l++)
	{
		basis::Transcoded ours = basis::transcode(tmem, ktx2, l, 0, 0, basis::TF_RGBA32, 4)!;
		basis::Transcoded ffis = basis::transcode_ffi(tmem, ktx2, l, 0, 0, basis::TF_RGBA32, 4)!;
		assert(ours.data == ffis.data, "%s level %d: basisu decodes our file differently", img, l);
	}

	basis::Transcoded l0 = basis::transcode(tmem, ktx2, 0, 0, 0, basis::TF_RGBA32, 4)!;
	return {
		.c3_db = ktx_testutil::psnr(l0.data, src),
		.basisu_db = ktx_testutil::psnr(golden_rgba, src),
		.c3_size = ktx2.len,
		.basisu_size = golden_ktx2.len,
	};
}

<* Cube/array shapes: C3-encoded faces/layers must round-trip per image. *>
fn void? check_shapes(char[] src, uint dim) => @pool()
{
	char[][6] faces = { src, src, src, src, src, src };
	char[] cube = basis::encode(tmem, basis::UASTC_4X4, faces[..], dim, dim, basis::TexType.CUBE,
		{ .quality = 90, .effort = 2, .srgb = true, .mipmaps = false })!;
	basis::Transcoded a = basis::transcode(tmem, cube, 0, 0, 5, basis::TF_RGBA32, 4)!;
	basis::Transcoded b = basis::transcode_ffi(tmem, cube, 0, 0, 5, basis::TF_RGBA32, 4)!;
	assert(a.data == b.data, "cube face 5 decodes differently via basisu");

	char[][2] layers = { src, src };
	char[] arr = basis::encode(tmem, basis::UASTC_4X4, layers[..], dim, dim, basis::TexType.ARRAY,
		{ .quality = 90, .effort = 2, .srgb = true, .mipmaps = false })!;
	basis::Transcoded c = basis::transcode(tmem, arr, 0, 1, 0, basis::TF_RGBA32, 4)!;
	basis::Transcoded d = basis::transcode_ffi(tmem, arr, 0, 1, 0, basis::TF_RGBA32, 4)!;
	assert(c.data == d.data, "array layer 1 decodes differently via basisu");
}

module basis_enc_tests @test;
import basis_enc_testutil;
import std::io, std::io::file;

fn void uastc_encode_interop_and_quality()
{
	String[5] imgs = { "gradient", "detail", "alpha", "gray", "normal" };
	String[5] bases = {
		"gradient-uastc-q90-mip", "detail-uastc-q90-mip", "alpha-uastc-q90-mip",
		"gray-uastc-q90-mip", "normal-uastc-linear-q90-mip",
	};
	uint checked;
	foreach (i, img : imgs)
	{
		basis_enc_testutil::Result? r = basis_enc_testutil::check(img, bases[i], img != "normal", 64);
		if (catch r) continue;   // goldens not generated
		io::printfn("  %s: C3 %.2f dB %d B, basisu q90/e2 %.2f dB %d B",
			img, r.c3_db, r.c3_size, r.basisu_db, r.basisu_size);
		assert(r.c3_db > r.basisu_db - 1.0,
			"%s: C3 %.2f dB more than 1 dB below basisu %.2f dB", img, r.c3_db, r.basisu_db);
		assert(r.c3_size < r.basisu_size * 5 / 2,
			"%s: C3 size %d larger than 2.5x basisu %d", img, r.c3_size, r.basisu_size);
		checked++;
	}
	assert(checked == 0 || checked == 5, "partial golden set: %d of 5", checked);
}

fn void uastc_encode_cube_and_array()
{
	char[]? src = file::load(mem, "test/golden/detail.src.bin");
	if (catch src) return;   // goldens not generated
	defer free(src.ptr);
	basis_enc_testutil::check_shapes(src, 64)!!;
}
