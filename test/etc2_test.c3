// The ETC2/EAC decoder and the ETC1S -> ETC1/ETC2 mapper. The independent
// oracle is Ericsson's etcdec, run by test/etc2-validate.sh; these pin blocks
// it decoded, and what the mapper promises, without needing it.
module etc2_testutil;
import ktx::etc1s, ktx::etc2, ktx::basis;
import std::math;

<* An EAC block with every texel on one index. *>
fn char[8] eac_block(char base, uint mul, uint table, uint idx)
{
	char[8] b;
	b[0] = base;
	b[1] = (char)(mul << 4 | table);
	ulong bits;
	for (uint i = 0; i < 16; i++) bits = bits << 3 | idx;
	for (uint i = 0; i < 6; i++) b[2 + i] = (char)(bits >> (40 - 8 * i));
	return b;
}

<* The level ETC1S decodes selector `s` of an endpoint's channel `c` to. *>
fn int level(etc1s::Endpoint ep, uint c, uint s)
{
	int v = (ep.color5[c] << 3 | ep.color5[c] >> 2) + etc1s::INTEN_TABLES[ep.inten5][s];
	return v < 0 ? 0 : (v > 255 ? 255 : v);
}

<* A selector that uses exactly the selectors in `mask`, each in turn along the rows. *>
fn etc1s::Selector selector_for(uint mask)
{
	uint[4] used;
	uint n;
	for (uint s = 0; s < 4; s++)
	{
		if ((mask >> s) & 1) used[n++] = s;
	}
	etc1s::Selector sel;
	for (uint i = 0; i < 16; i++) sel.rows[i / 4] |= (char)(used[i % n] << ((i % 4) * 2));
	return sel;
}

fn uint sel_at(etc1s::Selector sel, uint x, uint y) => (sel.rows[y] >> (x * 2)) & 3;

<*
 Check one level's ETC2 RGBA and ETC1 transcodes against its RGBA32 one: the
 colour exact, ETC1 the colour half of each RGBA block, an opaque file's alpha
 255. Adds the alpha error of a file with alpha to the totals.
*>
fn void compare_level(char[] ktx2, uint level, ulong* err_sum, usz* texels, int* worst) => @pool()
{
	basis::Transcoded want = basis::transcode(tmem, ktx2, level, 0, 0, basis::TF_RGBA32, 4)!!;
	basis::Transcoded rgba = basis::transcode(tmem, ktx2, level, 0, 0, basis::TF_ETC2_RGBA, 16)!!;
	basis::Transcoded rgb = basis::transcode(tmem, ktx2, level, 0, 0, basis::TF_ETC1_RGB, 8)!!;
	char[] got = etc2::decode(tmem, RGBA, rgba.data, want.width, want.height)!!;
	bool has_alpha = basis::info(ktx2)!!.alpha;
	for (usz i = 0; i < got.len; i += 4)
	{
		assert(got[i : 3] == want.data[i : 3], "level %d texel %d: colour differs", level, i / 4);
		int e = (int)got[i + 3] - want.data[i + 3];
		if (!has_alpha) assert(got[i + 3] == 255, "level %d texel %d: an opaque file's alpha", level, i / 4);
		*err_sum += (ulong)(e < 0 ? -e : e);
		*worst = max(*worst, e < 0 ? -e : e);
	}
	if (has_alpha) *texels += got.len / 4;
	// ETC1 is the colour half of each RGBA block.
	for (usz b = 0; b < rgb.data.len / 8; b++)
	{
		assert(rgb.data[b * 8 : 8] == rgba.data[b * 16 + 8 : 8], "level %d block %d", level, b);
	}
}

<* Root mean square difference over channels `lo` to `hi` of two RGBA8 images. *>
fn double rmse(char[] a, char[] b, uint lo, uint hi)
{
	double sum;
	usz n;
	for (usz i = 0; i < a.len; i += 4)
	{
		for (uint c = lo; c <= hi; c++)
		{
			double d = (double)a[i + c] - (double)b[i + c];
			sum += d * d;
			n++;
		}
	}
	return math::sqrt(sum / (double)n);
}

module etc2_tests @test;
import etc2_testutil;
import ktx::etc2, ktx::etc1s, ktx::etc1s_etc2, ktx::basis, ktx::dfd, ktx::vk, ktx::codec, ktx::container, ktx::cli;
import image;
import std::io;

struct Kat
{
	etc2::Layout layout;
	char[] block;
	char[] rgba;
}

// Random blocks of each mode, and what etcdec decodes them to.
const Kat[16] KATS = {
	{ RGB, x"f2a74de452e6b438", x"ffd973fffffffbff277ce2ff1166ccffd07b15ff480000ff1d72d8ff3388eeffd07b15ffd07b15ff3388eeff1d72d8fffffffbffd07b15ff277ce2ff3388eeff" }, // individual
	{ RGB, x"6513270e269e0d37", x"6b1829ff5b0819ff745342ff573625ff5b0819ff6b1829ff3d1c0bff3d1c0bff5b0819ff651223ff200000ff573625ff610e1fff610e1fff745342ff573625ff" }, // differential
	{ RGB, x"14f4733f3e7d1bfb", x"370000ff370000ffb77373ff370000ffb77373ff370000ff370000ff773333ff773333ff370000ff773333ff88ff44ff370000ffb77373ff370000ff88ff44ff" }, // T
	{ RGB, x"230d977ee2257159", x"02cedfff24469bff24469bff24469bff6486dbff42ffffff42ffffff02cedfff42ffffff24469bff6486dbff02cedfff24469bff6486dbff6486dbff42ffffff" }, // H, first colour the larger
	{ RGB, x"9c1caaf75e8766ed", x"2c2cc5ff5cc2c2ff5cc2c2ff7e7effff7e7effff0a7070ff2c2cc5ff0a7070ff2c2cc5ff0a7070ff2c2cc5ff2c2cc5ff0a7070ff2c2cc5ff7e7effff5cc2c2ff" }, // H, second colour the larger
	{ RGB, x"3908f227c59db916", x"718951ff689871ff5fa790ff56b6b0ff829953ff79a873ff70b792ff67c6b2ff94a955ff8bb875ff82c794ff79d6b4ffa5b957ff9cc877ff93d796ff8ae6b6ff" }, // planar
	{ RGB_A1, x"8aa4248e8857f9a4", x"7a930fff7a930fffc6ae2affc6ae2aff7a930fffc8e15dffa9910dffc6ae2aff506900ff7a930fffa9910dffc6ae2aff9eb733ffc8e15dff725a00ff725a00ff" }, // differential, opaque
	{ RGB_A1, x"80b0c089c7702420", x"84b5c6ff000000000000000084b5c6ff84b5c6ff48798aff00000000c0f1ffff84b5c6ff000000006798a9ff0000000084b5c6ff84b5c6ff84b5c6ff00000000" }, // differential, transparent texels
	{ RGB_A1, x"f979d048f47aebdd", x"f4175bffc6002dfff4175bff000000000000000000000000f4175bffc6002dfff4175bffc6002dff00000000c6002dffc6002dfff4175bfff4175bffc6002dff" }, // T, transparent texels
	{ RGB_A1, x"330698a1c0093492", x"00000000565645ff767665ff565645ff565645ff767665ff767665ff565645ff767665ff767665ff565645ff0000000000000000565645ff767665ff00000000" }, // H, transparent texels
	{ RGB_A1, x"988af3f9d39630d6", x"300a5dff623c79ff946f94ffc5a1b0ff56295cff885c78ffb98e93ffebc0afff7c495bffad7b77ffdfad92ffffdfaeffa1685affd39a76ffffcc91ffffffadff" }, // planar, opaque bit clear
	{ RGBA, x"796f74adfaf55496effddeeaa842bc19", x"ffffff43ffffff9df0f0d7a9ffffeb4fc0d0af91ffffffa9f0f0d791cacab14fffffff5bc0d0afa9ffffeb4ff0f0d74fffffff4fffffff4fcacab191cacab19d" }, // EAC A8
	{ RGBA, x"2709e06f59b44e92b9f3635cf88c422b", x"d8ff8327c4ff6f27c86262276a040427d8ff8327d8ff8327ffeaea276a040427b2f65d27c4ff6f27c8626227000000279ee24927b2f65d276a0404276a040427" }, // EAC A8, multiplier 0
	{ R11, x"1a4f44f9a6511445", x"000000ff222222ff000000ff000000ff060606ff323232ff222222ff060606ff060606ff222222ff000000ff0e0e0eff3a3a3aff323232ff060606ff2a2a2aff" }, // R11
	{ R11, x"bf0efc1586ce03f9", x"c0c0c0ffbebebeffc0c0c0ffbebebeffc0c0c0ffc0c0c0ffbebebeffc0c0c0ffbfbfbfffbfbfbfffbfbfbfffc0c0c0ffbebebeffc0c0c0ffbfbfbfffbebebeff" }, // R11, multiplier 0
	{ RG11, x"23a5ef88ef02090bfc8e80b36f0e2289", x"87ff00ff37cc00ff05dc00ff37cc00ff00dc00ff00ff00ff05b400ff37bc00ff87cc00ff5fff00ff37ff00ff00cc00ff05b400ff87ff00ff05bc00ff00cc00ff" }, // RG11
};

fn void every_mode_decodes_as_etcdec_does()
{
	foreach (i, kat : KATS)
	{
		char[] got = etc2::decode(mem, kat.layout, kat.block, 4, 4)!!;
		defer free(got);
		assert(got == kat.rgba, "case %d (%s) decoded differently", i, kat.layout);
	}
}

fn void r11_values_follow_the_spec()
{
	// Unsigned: base * 8 + 4, plus the modifier times multiplier * 8, or plain with multiplier 0.
	test::eq(etc2::decode_r11_block(etc2_testutil::eac_block(0x10, 0, 13, 5)[..])[0], 133);
	test::eq(etc2::decode_r11_block(etc2_testutil::eac_block(0xFF, 15, 0, 7)[..])[5], 2047);
	test::eq(etc2::decode_r11_block(etc2_testutil::eac_block(0x00, 1, 0, 3)[..])[15], 0);
	// Signed: -128 reads as -127, and the result is held to -1023..1023.
	test::eq(etc2::decode_signed_r11_block(etc2_testutil::eac_block(0x80, 0, 13, 4)[..])[0], -1016);
	test::eq(etc2::decode_signed_r11_block(etc2_testutil::eac_block(0x80, 0, 13, 3)[..])[0], -1023);
	test::eq(etc2::decode_signed_r11_block(etc2_testutil::eac_block(0x7F, 15, 0, 7)[..])[0], 1023);
	test::eq(etc2::decode_signed_r11_block(etc2_testutil::eac_block(0xFF, 2, 0, 0)[..])[0], -56);
}

fn void a_partial_block_is_cropped()
{
	// Four blocks, decoded whole and as a 6x5 image.
	char[32] blocks;
	foreach (i, &b : blocks) *b = (char)(i * 37 + 11);
	char[] whole = etc2::decode(mem, RGB, blocks[..], 8, 8)!!;
	defer free(whole);
	char[] part = etc2::decode(mem, RGB, blocks[..], 6, 5)!!;
	defer free(part);
	for (uint y = 0; y < 5; y++)
	{
		assert(part[y * 24 : 24] == whole[y * 32 : 24], "row %d", y);
	}
}

fn void a_bad_size_payload_is_refused()
{
	char[16] one;
	test::@error(etc2::decode(mem, RGB, one[:7], 4, 4), etc2::INVALID_SIZE);
	test::@error(etc2::decode(mem, RGBA, one[:8], 4, 4), etc2::INVALID_SIZE);
	test::@error(etc2::decode(mem, RGB, one[..], 4, 4), etc2::INVALID_SIZE);
	test::@error(etc2::decode(mem, RGB, one[:8], 0, 4), etc2::INVALID_SIZE);
	etc1s::Codebook cb;
	test::@error(etc1s_etc2::map_image(mem, &cb, one[..], {}, 0, 4, ETC1_RGB, mem), etc1s_etc2::INVALID_SIZE);
	// The signed formats have no RGBA8 decode.
	test::@error(codec::decode_image(mem, vk::EAC_R11_SNORM, one[:8], 4, 4), codec::UNSUPPORTED_INPUT);
}

<* Colour blocks decode to the ETC1S texels: every level, table and selector, each channel its own. *>
fn void colour_blocks_decode_to_the_etc1s_texels()
{
	etc1s::Selector[3] sels = { { { 0x1B, 0xE4, 0x4E, 0xB1 } }, { { 0x00, 0x55, 0xAA, 0xFF } }, { { 0xC6, 0x39, 0x93, 0x6C } } };
	for (uint v = 0; v < 32; v++)
	{
		for (uint t = 0; t < 8; t++)
		{
			etc1s::Endpoint ep = { .color5 = { (char)v, (char)(31 - v), (char)(v * 7 % 32) }, .inten5 = (char)t };
			foreach (sel : sels)
			{
				char[8] block;
				etc1s_etc2::map_colour_block(ep, sel, &block[0]);
				char[64] px;
				etc2::decode_rgb_block(block[..], &px);
				for (uint i = 0; i < 16; i++)
				{
					uint s = etc2_testutil::sel_at(sel, i % 4, i / 4);
					for (uint c = 0; c < 3; c++)
					{
						assert(px[i * 4 + c] == etc2_testutil::level(ep, c, s), "level %d table %d texel %d", v, t, i);
					}
				}
			}
		}
	}
}

<* One colour block as written: differential, zero delta, one table twice, no flip. basisu writes the same. *>
fn void colour_block_is_the_recorded_one()
{
	etc1s::Endpoint ep = { .color5 = { 3, 17, 30 }, .inten5 = 5 };
	etc1s::Selector sel = { { 0x1B, 0xE4, 0x4E, 0xB1 } };
	char[8] block;
	etc1s_etc2::map_colour_block(ep, sel, &block[0]);
	assert(block[..] == x"18 88 f0 b6 55 aa 3c c3", "got %s", block);
}

// The squared error summed over every alpha key, at its optimum: what an
// exhaustive search over every base, table and multiplier finds.
const ulong OPTIMUM_SSE = 1278;
// The largest error any key's optimum leaves on one level, so on any texel.
const int WORST_LEVEL_ERROR = 3;

<* Every (level, table, selectors used) key gets its optimal EAC block. *>
fn void alpha_fit_is_optimal_for_every_key()
{
	ulong total;
	int worst;
	uint exact;
	for (uint g = 0; g < 32; g++)
	{
		for (uint t = 0; t < 8; t++)
		{
			etc1s::Endpoint ep = { .color5 = { 0, (char)g, 0 }, .inten5 = (char)t };
			for (uint mask = 1; mask < 16; mask++)
			{
				etc1s::Selector sel = etc2_testutil::selector_for(mask);
				char[8] block;
				etc1s_etc2::map_alpha_block(ep, sel, &block[0]);
				char[64] px;
				etc2::decode_alpha_block(block[..], &px);
				// Each selector used once: its other texels decode the same.
				ulong sse;
				uint seen;
				for (uint i = 0; i < 16; i++)
				{
					uint s = etc2_testutil::sel_at(sel, i % 4, i / 4);
					if ((seen >> s) & 1) continue;
					seen |= 1u << s;
					int e = (int)px[i * 4 + 3] - etc2_testutil::level(ep, 1, s);
					sse += (ulong)(e * e);
					worst = max(worst, e < 0 ? -e : e);
				}
				total += sse;
				if (!sse) exact++;
			}
		}
	}
	io::printfn("  alpha keys: %d of 3840 exact, total squared error %d, worst level %d", exact, total, worst);
	test::eq(total, OPTIMUM_SSE);
	test::eq(worst, WORST_LEVEL_ERROR);
}

<* One alpha block as written: etcdec decodes it to 24, 84, 129, 189 where the levels are 27, 83, 131, 187. *>
fn void alpha_block_is_the_recorded_one()
{
	etc1s::Endpoint ep = { .color5 = { 0, 13, 0 }, .inten5 = 5 };
	etc1s::Selector sel = { { 0x1B, 0xE4, 0x4E, 0xB1 } };
	char[8] block;
	etc1s_etc2::map_alpha_block(ep, sel, &block[0]);
	assert(block[..] == x"72 f3 ca 08 32 11 65 84", "got %s", block);
}

<*
 Every level of the corpus, as is and with its green channel as alpha, maps to
 colour exactly the ETC1S decode's and to alpha within the per-key bound.
*>
fn void corpus_levels_map_exactly() => @pool()
{
	String[5] images = { "gradient", "detail", "alpha", "gray", "normal" };
	CInt[2] qualities = { 10, 90 };
	ulong err_sum;
	usz texels;
	int worst;
	foreach (name : images)
	{
		image::Image src = cli::load_image(tmem, string::tformat("test/images/%s.png", name))!!;
		char[] green_alpha = alloc::clone_slice(tmem, src.pixels);
		for (usz i = 0; i < green_alpha.len; i += 4) green_alpha[i + 3] = green_alpha[i + 1];
		char[][2] variants = { src.pixels, green_alpha };
		foreach (pixels : variants)
		{
			char[][1] imgs = { pixels };
			foreach (q : qualities)
			{
				char[] ktx2 = basis::encode(tmem, basis::ETC1S, imgs[..], src.width, src.height,
					basis::TexType.D2, { .quality = q, .effort = 2, .srgb = true, .mipmaps = true })!!;
				uint levels = basis::levels(ktx2)!!;
				for (uint l = 0; l < levels; l++) etc2_testutil::compare_level(ktx2, l, &err_sum, &texels, &worst);
			}
		}
	}
	double mean = (double)err_sum / (double)texels;
	io::printfn("  alpha over %d texels: mean error %.4f, worst %d", texels, mean, worst);
	assert(worst <= WORST_LEVEL_ERROR, "worst alpha error %d", worst);
	assert(mean < 0.25, "mean alpha error %.4f", mean);
}

<* Alpha included, so the EAC search runs across threads as well as the block rows. *>
fn void threads_do_not_change_the_blocks() => @pool()
{
	char[64 * 64 * 4] rgba;
	foreach (i, &c : rgba) *c = (char)((i * 2654435761) >> 13);
	char[] ktx2 = basis::encode_etc1s(tmem, rgba[..], 64, 64, { .quality = 50, .effort = 2, .srgb = false, .mipmaps = false })!!;
	assert(basis::info(ktx2)!!.alpha);
	basis::Transcoded[] one = basis::transcode_levels(tmem, ktx2, 0, 0, basis::TF_ETC2_RGBA, 1)!!;
	basis::Transcoded[] many = basis::transcode_levels(tmem, ktx2, 0, 0, basis::TF_ETC2_RGBA, 8)!!;
	assert(one[0].data == many[0].data);
}

fn void uastc_refuses_the_etc_targets() => @pool()
{
	char[8 * 8 * 4] rgba;
	foreach (i, &c : rgba) *c = (char)(i * 5);
	char[][1] imgs = { rgba[..] };
	char[] ktx2 = basis::encode(tmem, basis::UASTC_4X4, imgs[..], 8, 8, basis::TexType.D2, { .quality = 90, .effort = 2 })!!;
	test::@error(basis::transcode(tmem, ktx2, 0, 0, 0, basis::TF_ETC1_RGB, 8), basis::UNSUPPORTED_TARGET);
	test::@error(basis::transcode(tmem, ktx2, 0, 0, 0, basis::TF_ETC2_RGBA, 16), basis::UNSUPPORTED_TARGET);
}

fn void info_reports_alpha() => @pool()
{
	char[8 * 8 * 4] opaque;
	foreach (i, &c : opaque) *c = i % 4 == 3 ? 255 : (char)(i * 5);
	char[8 * 8 * 4] alpha = opaque;
	alpha[3] = 7;
	foreach (fmt : (uint[2]){ basis::ETC1S, basis::UASTC_4X4 })
	{
		char[][1] o = { opaque[..] };
		char[][1] a = { alpha[..] };
		char[] without = basis::encode(tmem, fmt, o[..], 8, 8, basis::TexType.D2, { .quality = 90, .effort = 2 })!!;
		char[] with = basis::encode(tmem, fmt, a[..], 8, 8, basis::TexType.D2, { .quality = 90, .effort = 2 })!!;
		assert(!basis::info(without)!!.alpha, "format %d without alpha", fmt);
		assert(basis::info(with)!!.alpha, "format %d with alpha", fmt);
	}
}

struct DfdWant
{
	uint format;
	char[] bytes;
}

<* The DFDs KTX-Software's createDFDCompressed writes for these formats. *>
fn void etc2_dfds_match_ktx_software()
{
	DfdWant[4] wants = {
		{ vk::ETC2_R8G8B8_SRGB, x"2c000000 00000000 02002800 a1010200 03030000 08000000 00000000
			00003f02 00000000 00000000 ffffffff" },
		{ vk::ETC2_R8G8B8A1_UNORM, x"3c000000 00000000 02003800 a1010100 03030000 08000000 00000000
			00003f02 00000000 00000000 ffffffff 00003f0f 00000000 00000000 ffffffff" },
		{ vk::ETC2_R8G8B8A8_SRGB, x"3c000000 00000000 02003800 a1010200 03030000 10000000 00000000
			00003f1f 00000000 00000000 ffffffff 40003f02 00000000 00000000 ffffffff" },
		{ vk::EAC_R11G11_SNORM, x"3c000000 00000000 02003800 a1010100 03030000 10000000 00000000
			00003f40 00000000 00000080 ffffff7f 40003f41 00000000 00000080 ffffff7f" },
	};
	foreach (w : wants)
	{
		char[] d = dfd::create(mem, w.format)!!;
		defer free(d);
		assert(d == w.bytes, "%s", vk::name(w.format));
	}
}

fn void an_etc2_file_describes_itself()
{
	container::Texture tex = container::create(mem, { .vk_format = vk::ETC2_R8G8B8A8_SRGB, .width = 8, .height = 8 })!!;
	defer tex.free();
	char[] file = container::write(mem, &tex)!!;
	defer free(file);
	container::FileInfo info = container::describe(mem, file)!!;
	defer info.free();
	test::eq(vk::name(info.vk_format), "ETC2_R8G8B8A8_SRGB");
	test::eq(dfd::model_name(info.dfd.model), "ETC2");
	test::eq(info.dfd.sample_count, 2u);
	test::eq(info.levels[0].uncompressed, 64ul);
}

<*
 The direct encoder against an ETC1S encode of the same pixels, both read back
 through the ETC2 decoder. A block fitted on its own should not lose to one
 sharing a codebook, and it gets there without the clustering.
*>
fn void encoded_colour_is_no_worse_than_an_etc1s_file() => @pool()
{
	String[4] images = { "gradient", "detail", "gray", "normal" };
	foreach (name : images)
	{
		image::Image src = cli::load_image(tmem, string::tformat("test/images/%s.png", name))!!;
		char[] blocks = etc1s_etc2::encode_image(tmem, src.pixels, src.width, src.height, ETC1_RGB, tmem)!!;
		char[] got = etc2::decode(tmem, RGB, blocks, src.width, src.height)!!;

		char[][1] imgs = { src.pixels };
		char[] ktx2 = basis::encode(tmem, basis::ETC1S, imgs[..], src.width, src.height, basis::TexType.D2,
			{ .quality = 100, .effort = 2, .srgb = true, .mipmaps = false })!!;
		char[] file = basis::transcode(tmem, ktx2, 0, 0, 0, basis::TF_RGBA32, 4)!!.data;

		double mine = etc2_testutil::rmse(got, src.pixels, 0, 2);
		double theirs = etc2_testutil::rmse(file, src.pixels, 0, 2);
		io::printfn("  %s %dx%d: direct rmse %.3f, ETC1S q100 %.3f", name, src.width, src.height, mine, theirs);
		assert(mine <= theirs * 1.02, "%s: the direct fit is %.3f off, an ETC1S file %.3f", name, mine, theirs);
	}
}

<*
 EAC alpha from pixels: near the picture's own alpha, and exactly 255 in a block
 that is opaque. 30x18 so the last column and row of blocks are partial.
*>
fn void encoded_alpha_follows_the_pixels() => @pool()
{
	const uint W = 30;
	const uint H = 18;
	char[W * H * 4] rgba;
	for (uint y = 0; y < H; y++)
	{
		for (uint x = 0; x < W; x++)
		{
			usz at = ((usz)y * W + x) * 4;
			rgba[at + 0] = (char)(x * 8);
			rgba[at + 1] = (char)(y * 13);
			rgba[at + 2] = (char)(255 - x * 4 - y * 3);
			// Blocks from x = 16 on are opaque.
			rgba[at + 3] = x >= 16 ? 255 : (char)(x * 15 + y * 2);
		}
	}
	char[] blocks = etc1s_etc2::encode_image(tmem, rgba[..], W, H, ETC2_RGBA, tmem)!!;
	assert(blocks.len == 8 * 5 * 16, "%d bytes for 8x5 blocks", blocks.len);
	char[] got = etc2::decode(tmem, RGBA, blocks, W, H)!!;

	// The gradients are steeper than one ETC1S colour a block follows, so both are
	// held to what an ETC1S file of the same pixels decodes to.
	char[][1] imgs = { rgba[..] };
	char[] ktx2 = basis::encode(tmem, basis::ETC1S, imgs[..], W, H, basis::TexType.D2,
		{ .quality = 100, .effort = 2, .srgb = true, .mipmaps = false })!!;
	char[] file = basis::transcode(tmem, ktx2, 0, 0, 0, basis::TF_RGBA32, 4)!!.data;

	double colour = etc2_testutil::rmse(got, rgba[..], 0, 2);
	double alpha = etc2_testutil::rmse(got, rgba[..], 3, 3);
	double file_colour = etc2_testutil::rmse(file, rgba[..], 0, 2);
	double file_alpha = etc2_testutil::rmse(file, rgba[..], 3, 3);
	io::printfn("  30x18: colour rmse %.3f (ETC1S %.3f), alpha rmse %.3f (ETC1S %.3f)", colour, file_colour, alpha, file_alpha);
	assert(colour <= file_colour * 1.02, "colour rmse %.3f against ETC1S's %.3f", colour, file_colour);
	// EAC carries the alpha within 3 of ETC1S's levels.
	assert(alpha <= file_alpha + 3, "alpha rmse %.3f against ETC1S's %.3f", alpha, file_alpha);
	for (uint y = 0; y < H; y++)
	{
		for (uint x = 16; x < W; x++) assert(got[((usz)y * W + x) * 4 + 3] == 255, "texel %d,%d of an opaque block", x, y);
	}
}

<* Alpha included, so the EAC search runs across threads as well as the block rows. *>
fn void encode_threads_do_not_change_the_blocks() => @pool()
{
	char[64 * 64 * 4] rgba;
	foreach (i, &c : rgba) *c = (char)((i * 2654435761) >> 13);
	char[] one = etc1s_etc2::encode_image(tmem, rgba[..], 64, 64, ETC2_RGBA, tmem, 1)!!;
	char[] many = etc1s_etc2::encode_image(tmem, rgba[..], 64, 64, ETC2_RGBA, tmem, 8)!!;
	assert(one == many);
}
