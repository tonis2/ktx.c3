// Phase-4/5 differential tests (docs/basis-rewrite.md): the pure-C3 UASTC and
// ETC1S encoders behind basis::encode, gated against the recorded golden data:
//  - every mip level of a C3-encoded file must transcode through the C3
//    decoder (whose bit-exactness against basisu is proven separately by
//    uastc_test.c3 / etc1s_test.c3 on the golden files);
//  - level-0 PSNR vs the true source must stay within a margin of what
//    basisu's own q90/e2 encode achieved on the same image;
//  - sizes are printed with loose bounds (no RDO / no cluster-merge yet).
// Pre-cutover these also asserted that basisu's transcoder decodes our files
// bit-identically to ours (it did, for every format/shape/level); that FFI
// oracle is gone since phase 6. Needs test/golden/ (see gen-golden.sh); skips
// quietly when absent, but never accepts a partial set.
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

fn Result? check(String img, String golden_base, bool srgb, uint dim, uint fmt) => @pool()
{
	char[] src = file::load(tmem, string::tformat("test/golden/%s.src.bin", img))!;
	char[] golden_ktx2 = file::load(tmem, string::tformat("test/golden/%s.ktx2", golden_base))!;
	char[] golden_rgba = file::load(tmem, string::tformat("test/golden/%s.l0.bin", golden_base))!;

	// C3 encode with mips (matches the q90/e2 defaults).
	char[][1] imgs = { src };
	char[] ktx2 = basis::encode(tmem, fmt, imgs[..], dim, dim, basis::TexType.D2,
		{ .quality = 90, .effort = 2, .srgb = srgb, .mipmaps = true })!;

	// Every level must transcode; ETC1S/BasisLZ files are rejected by
	// container::read by design, so only parse UASTC ones.
	uint levels = 7;
	if (fmt == basis::UASTC_4X4)
	{
		container::Texture tex = container::read(tmem, ktx2)!;
		assert(tex.vk_format == 0 && tex.level_count() == levels, "%s: bad container shape", img);
	}
	for (uint l = 0; l < levels; l++)
	{
		basis::Transcoded t = basis::transcode(tmem, ktx2, l, 0, 0, basis::TF_RGBA32, 4)!;
		assert(t.width == max(dim >> l, 1u), "%s level %d: wrong width %d", img, l, t.width);
	}

	basis::Transcoded l0 = basis::transcode(tmem, ktx2, 0, 0, 0, basis::TF_RGBA32, 4)!;
	return {
		.c3_db = ktx_testutil::psnr(l0.data, src),
		.basisu_db = ktx_testutil::psnr(golden_rgba, src),
		.c3_size = ktx2.len,
		.basisu_size = golden_ktx2.len,
	};
}

<*
 Cube/array shapes must round-trip per image. UASTC block encoding is a pure
 per-image function, so a cube face must decode identically to the same image
 encoded as a 2D texture; ETC1S codebooks are global per file, so its faces
 are only checked for a sane PSNR.
*>
fn void? check_shapes(char[] src, uint dim) => @pool()
{
	char[][6] faces = { src, src, src, src, src, src };
	char[][1] single = { src };
	basis::EncodeOptions opts = { .quality = 90, .effort = 2, .srgb = true, .mipmaps = false };

	char[] ucube = basis::encode(tmem, basis::UASTC_4X4, faces[..], dim, dim, basis::TexType.CUBE, opts)!;
	char[] u2d = basis::encode(tmem, basis::UASTC_4X4, single[..], dim, dim, basis::TexType.D2, opts)!;
	basis::Transcoded a = basis::transcode(tmem, ucube, 0, 0, 5, basis::TF_RGBA32, 4)!;
	basis::Transcoded b = basis::transcode(tmem, u2d, 0, 0, 0, basis::TF_RGBA32, 4)!;
	assert(a.data == b.data, "uastc cube face 5 must decode like the 2D encode of the same image");

	char[][2] layers = { src, src };
	char[] uarr = basis::encode(tmem, basis::UASTC_4X4, layers[..], dim, dim, basis::TexType.ARRAY, opts)!;
	basis::Transcoded c = basis::transcode(tmem, uarr, 0, 1, 0, basis::TF_RGBA32, 4)!;
	assert(c.data == b.data, "uastc array layer 1 must decode like the 2D encode of the same image");

	char[] ecube = basis::encode(tmem, basis::ETC1S, faces[..], dim, dim, basis::TexType.CUBE, opts)!;
	basis::Transcoded e = basis::transcode(tmem, ecube, 0, 0, 5, basis::TF_RGBA32, 4)!;
	double db = ktx_testutil::psnr(e.data, src);
	assert(db > 25.0, "etc1s cube face 5: %.2f dB", db);
}

module basis_enc_tests @test;
import basis_enc_testutil;
import ktx::basis;
import std::io, std::io::file;

fn void uastc_encode_quality()
{
	String[5] imgs = { "gradient", "detail", "alpha", "gray", "normal" };
	String[5] bases = {
		"gradient-uastc-q90-mip", "detail-uastc-q90-mip", "alpha-uastc-q90-mip",
		"gray-uastc-q90-mip", "normal-uastc-linear-q90-mip",
	};
	uint checked;
	foreach (i, img : imgs)
	{
		basis_enc_testutil::Result? r = basis_enc_testutil::check(img, bases[i], img != "normal", 64, basis::UASTC_4X4);
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

fn void etc1s_encode_quality()
{
	String[5] imgs = { "gradient", "detail", "alpha", "gray", "normal" };
	String[5] bases = {
		"gradient-etc1s-q90-mip", "detail-etc1s-q90-mip", "alpha-etc1s-q90-mip",
		"gray-etc1s-q90-mip", "normal-etc1s-linear-q90-mip",
	};
	uint checked;
	foreach (i, img : imgs)
	{
		basis_enc_testutil::Result? r = basis_enc_testutil::check(img, bases[i], img != "normal", 64, basis::ETC1S);
		if (catch r) continue;   // goldens not generated
		io::printfn("  %s: C3 %.2f dB %d B, basisu q90 %.2f dB %d B",
			img, r.c3_db, r.c3_size, r.basisu_db, r.basisu_size);
		// The v1 frontend loses a little PSNR on some images and some size
		// everywhere (no cluster-merge iteration yet); both bounds are the
		// plan's "record, don't block" tracking numbers.
		assert(r.c3_db > r.basisu_db - 2.0,
			"%s: C3 %.2f dB more than 2 dB below basisu %.2f dB", img, r.c3_db, r.basisu_db);
		assert(r.c3_size < r.basisu_size * 3 / 2,
			"%s: C3 size %d larger than 1.5x basisu %d", img, r.c3_size, r.basisu_size);
		checked++;
	}
	assert(checked == 0 || checked == 5, "partial golden set: %d of 5", checked);
}

fn void encode_cube_and_array()
{
	char[]? src = file::load(mem, "test/golden/detail.src.bin");
	if (catch src) return;   // goldens not generated
	defer free(src.ptr);
	basis_enc_testutil::check_shapes(src, 64)!!;
}
