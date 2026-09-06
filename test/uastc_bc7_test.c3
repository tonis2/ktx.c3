// Phase-3 tests (docs/basis-rewrite.md): the UASTC -> BC7 block mapper.
//
// The mapper never builds pixels, so what it has to be measured against is
// the decoder: bc7::decode of a mapped block versus uastc::decode_block of
// the source block. Two gates:
//   - per mode, over synthetic blocks that cover all 19 of them (the C3
//     encoder only emits eight, so the corpus alone would leave the rest
//     untested), the worst channel difference and the PSNR;
//   - over the real corpus, every mip level of a UASTC encode, PSNR of the
//     mapped blocks against the RGBA32 transcode of the same level.
module uastc_bc7_testutil;
import ktx::uastc, ktx::uastc_bc7, ktx::bc7;

fn uint next_rand(uint* s)
{
	uint x = *s;
	x ^= x << 13;
	x ^= x >> 17;
	x ^= x << 5;
	*s = x;
	return x;
}

struct ModeScore
{
	uint blocks;
	uint max_diff;
	double sse;
	usz samples;
}

<*
 Random blocks of one UASTC mode, mapped and decoded both ways. Any 16 bytes
 whose leading mode code selects `mode` is a valid block of that mode, so the
 payload can just be noise — every field lands in range by construction
 except the partition index, which unpack_block rejects and this skips.
*>
fn ModeScore mode_score(uint mode, uint count, uint seed)
{
	ModeScore r;
	uint state = seed | 1;
	uint code_size = uastc::MODE_CODE_SIZES[mode];
	uint code = uastc::MODE_CODES[mode];
	uint mask = (1u << code_size) - 1;

	for (uint n = 0; n < count; n++)
	{
		char[16] block;
		for (uint i = 0; i < 16; i++) block[i] = (char)next_rand(&state);
		block[0] = (char)((block[0] & ~mask) | code);
		if (uastc::HUFF_MODES[block[0] & 127] != mode) continue;

		char[64] want;
		if (@catch(uastc::decode_block(block[..], want[..]))) continue;

		char[16] mapped;
		uastc_bc7::map_block(block[..], &mapped[0]);
		char[64] got;
		bc7::decode_block(&mapped[0], &got[0]);

		r.blocks++;
		for (uint i = 0; i < 64; i++)
		{
			int d = (int)got[i] - (int)want[i];
			if (d < 0) d = -d;
			if ((uint)d > r.max_diff) r.max_diff = (uint)d;
			r.sse += (double)d * (double)d;
		}
		r.samples += 64;
	}
	return r;
}

module uastc_bc7_tests @test;
import uastc_bc7_testutil;
import ktx::uastc, ktx::uastc_bc7, ktx::bc7, ktx::basis, ktx::cli;
import image;
import ktx_testutil;
import std::io, std::math;

<*
 Every UASTC mode maps to a BC7 block that decodes back to the same picture.
 The bound is per mode because the loss is per mode: 1 from ASTC's 16-bit
 interpolation against BC7's 8-bit one, 1 more where the p-bit forces an
 endpoint off by one, and a weight-table step where UASTC's 3/4/5-bit weight
 grids have no BC7 twin.
*>
fn void every_mode_maps()
{
	// What each mode is allowed to be off by, over blocks whose endpoints are
	// uniformly random — the worst case a mode can be put in, far beyond what
	// an encoder produces. 2 is the floor everywhere: 1 for ASTC's 16-bit
	// interpolation against BC7's 8-bit one, 1 for the endpoint the p-bit
	// pushes off by a level. Modes 3/7/9/16 land on BC7's 5- and 6-bit
	// endpoints and cost 3 more; modes 0/10/12/15 remap a 3- or 4-bit weight
	// grid onto BC7's, worth a 64th of the endpoint span; mode 18 folds a
	// 5-bit grid onto a 4-bit one, worth two. Mode 8 (solid) is exact.
	uint[19] limits = { 6, 3, 5, 8, 3, 5, 3, 7, 0, 8, 7, 3, 6, 2, 3, 6, 7, 3, 10 };
	double worst_db = 1e9;
	for (uint m = 0; m < 19; m++)
	{
		uastc_bc7_testutil::ModeScore s = uastc_bc7_testutil::mode_score(m, 2000, 0x1234 + m * 7919);
		assert(s.blocks > 100, "mode %d: only %d usable blocks", m, s.blocks);
		double mse = s.sse / (double)s.samples;
		double db = mse == 0 ? 1e9 : 10.0 * math::log10(255.0 * 255.0 / mse);
		io::printfn("  mode %2d: %5d blocks, max diff %d, %.1f dB", m, s.blocks, s.max_diff, db);
		assert(s.max_diff <= limits[m], "mode %d: max diff %d over %d", m, s.max_diff, limits[m]);
		if (db < worst_db) worst_db = db;
	}
	assert(worst_db > 42.0, "worst mode PSNR %.2f dB", worst_db);
}

<*
 The corpus end to end: a UASTC encode of each test image, every mip level
 mapped to BC7 and decoded, against the RGBA32 transcode of the same level.
*>
fn void corpus_levels_map() => @pool()
{
	String[5] images = { "gradient", "detail", "alpha", "gray", "normal" };
	double worst_base = 1e9;
	foreach (name : images)
	{
		bool srgb = name != "normal";
		image::Image src = cli::load_image(tmem, string::tformat("test/images/%s.png", name))!!;
		char[][1] imgs = { src.pixels };
		bool[2] mip_modes = { false, true };
		foreach (mips : mip_modes)
		{
			char[] ktx2 = basis::encode(tmem, basis::UASTC_4X4, imgs[..], src.width, src.height,
				basis::TexType.D2, { .quality = 90, .effort = 4, .srgb = srgb, .mipmaps = mips })!!;
			uint levels = basis::levels(ktx2)!!;
			double worst = 1e9;
			for (uint l = 0; l < levels; l++)
			{
				basis::Transcoded want = basis::transcode(tmem, ktx2, l, 0, 0, basis::TF_RGBA32, 4)!!;
				basis::Transcoded blocks = basis::transcode(tmem, ktx2, l, 0, 0, basis::TF_BC7_RGBA, 16)!!;
				char[] got = bc7::decode(tmem, blocks.data, blocks.width, blocks.height)!!;
				double db = ktx_testutil::psnr(got, want.data);
				if (l == 0 && db < worst_base) worst_base = db;
				if (db < worst) worst = db;
			}
			io::printfn("  %s %s: %d levels, worst %.2f dB", name, mips ? "mip" : "nomip", levels, worst);
			// The deepest mips are 4 and 16 texels, where one requantized
			// endpoint is most of the mean square — hence two bars.
			assert(worst > 40.0, "%s: %.2f dB", name, worst);
		}
	}
	assert(worst_base > 45.0, "worst level-0 PSNR %.2f dB", worst_base);
}
