// Phase-3 tests (docs/basis-rewrite.md): the ETC1S -> BC7 block mapper.
//
// The gate is the same shape as the UASTC one: bc7::decode of the mapped
// blocks against the RGBA32 transcode of the same level, over the corpus,
// with and without mips and including an alpha image and a normal map. The
// decode-then-encode route the mapper replaces is measured alongside, since
// what the mapper has to be is faster *and* no worse.
module etc1s_bc7_testutil;
import ktx::basis, ktx::bc7;
import ktx_testutil;

struct Score
{
	double mapped_db;
	double encoded_db;
	usz texels;
}

<* One level, mapped and (for comparison) decoded-then-encoded. *>
fn Score? level_score(char[] ktx2, uint level, Allocator scratch)
{
	basis::Transcoded want = basis::transcode(scratch, ktx2, level, 0, 0, basis::TF_RGBA32, 4)!;
	basis::Transcoded blocks = basis::transcode(scratch, ktx2, level, 0, 0, basis::TF_BC7_RGBA, 16)!;
	char[] mapped = bc7::decode(scratch, blocks.data, blocks.width, blocks.height)!;
	char[] re = bc7::encode(scratch, want.data, want.width, want.height, true, 0, true)!;
	char[] encoded = bc7::decode(scratch, re, want.width, want.height)!;
	return {
		.mapped_db = ktx_testutil::psnr(mapped, want.data),
		.encoded_db = ktx_testutil::psnr(encoded, want.data),
		.texels = (usz)want.width * want.height,
	};
}

module etc1s_bc7_tests @test;
import etc1s_bc7_testutil;
import ktx::basis, ktx::cli;
import image;
import std::io;

<*
 Every level of an ETC1S encode of every corpus image maps to BC7 blocks that
 decode back to what the RGBA32 transcode produces.
*>
fn void corpus_levels_map() => @pool()
{
	String[5] images = { "gradient", "detail", "alpha", "gray", "normal" };
	bool[2] mip_modes = { false, true };
	double worst_base = 1e9;
	foreach (name : images)
	{
		bool srgb = name != "normal";
		image::Image src = cli::load_image(tmem, string::tformat("test/images/%s.png", name))!!;
		char[][1] imgs = { src.pixels };
		foreach (mips : mip_modes)
		{
			char[] ktx2 = basis::encode(tmem, basis::ETC1S, imgs[..], src.width, src.height,
				basis::TexType.D2, { .quality = 90, .effort = 2, .srgb = srgb, .mipmaps = mips })!!;
			uint levels = basis::levels(ktx2)!!;
			double worst = 1e9;
			double worst_enc = 1e9;
			for (uint l = 0; l < levels; l++)
			{
				etc1s_bc7_testutil::Score s = etc1s_bc7_testutil::level_score(ktx2, l, tmem)!!;
				if (l == 0 && s.mapped_db < worst_base) worst_base = s.mapped_db;
				// Per level, not just at the end: the mapper is allowed to
				// trail a real encode, never to fall away from it. (It is
				// ahead by 4 to 22 dB on the two images with alpha slices,
				// where mode 5 carries what a mode-6 encode cannot.) Only
				// levels of 64 texels and up — below that a single endpoint
				// is most of the mean square and the comparison is noise.
				assert(s.texels < 64 || s.mapped_db > s.encoded_db - 3.0,
					"%s level %d: mapped %.2f dB vs encoded %.2f dB", name, l, s.mapped_db, s.encoded_db);
				if (s.mapped_db < worst) worst = s.mapped_db;
				if (s.encoded_db < worst_enc) worst_enc = s.encoded_db;
			}
			io::printfn("  %s %s: %d levels, mapped %.2f dB (encode %.2f dB)",
				name, mips ? "mip" : "nomip", levels, worst, worst_enc);
		}
	}
	assert(worst_base > 45.0, "worst level-0 PSNR %.2f dB", worst_base);
}
