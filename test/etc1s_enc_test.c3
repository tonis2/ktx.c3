// Phase-5 unit tests (docs/basis-rewrite.md): the C3 ETC1S encoder round-trips
// through our own golden-verified decoder (decode_codebook + decode_slice).
// KTX2-level interop gates (basisu decodes our files identically, ktx
// validate) live in basis_enc_test.c3.
module etc1s_enc_testutil;
import ktx::etc1s, ktx::mipgen, ktx::cli;
import ktx_testutil;
import image;
import std::io;

fn double roundtrip_db(char[] rgba, uint w, uint h, uint quality, bool with_alpha, usz* total_size = null) => @pool()
{
	etc1s::EncSlice[2] slices;
	slices[0] = { .rgba = rgba, .width = w, .height = h, .alpha = false };
	uint count = 1;
	if (with_alpha)
	{
		slices[1] = { .rgba = rgba, .width = w, .height = h, .alpha = true };
		count = 2;
	}
	etc1s::Encoded enc = etc1s::encode(tmem, slices[:count], quality)!!;

	if (total_size)
	{
		usz t = enc.endpoints_data.len + enc.selectors_data.len + enc.tables_data.len;
		foreach (sl : enc.slices) t += sl.len;
		*total_size = t;
	}

	etc1s::Codebook cb = etc1s::decode_codebook(tmem, enc.num_endpoints, enc.endpoints_data,
		enc.num_selectors, enc.selectors_data, enc.tables_data)!!;

	char[] out = mem::temp_array(char, (usz)w * h * 4);
	if (with_alpha)
	{
		cb.decode_slice(enc.slices[1], w, h, out, etc1s::Pass.ALPHA, tmem)!!;
		cb.decode_slice(enc.slices[0], w, h, out, etc1s::Pass.RGB, tmem)!!;
	}
	else
	{
		cb.decode_slice(enc.slices[0], w, h, out, etc1s::Pass.RGB_OPAQUE, tmem)!!;
	}

	if (!with_alpha)
	{
		// Compare RGB + forced-opaque alpha against an opaque copy of the source.
		char[] src = mem::temp_array(char, rgba.len);
		src[..] = rgba[..];
		for (usz i = 3; i < src.len; i += 4) src[i] = 255;
		return ktx_testutil::psnr(src, out);
	}
	return ktx_testutil::psnr(rgba, out);
}

fn char[] make_image(Allocator allocator, uint w, uint h)
{
	char[] img = alloc::new_array(allocator, char, (sz)((usz)w * h * 4));
	for (uint y = 0; y < h; y++)
	{
		for (uint x = 0; x < w; x++)
		{
			usz i = ((usz)y * w + x) * 4;
			img[i] = (char)(x * 5 + y * 2);
			img[i + 1] = (char)(80 + ((x * x + y) & 63));
			img[i + 2] = (char)(255 - y * 4);
			img[i + 3] = (char)(x < w / 2 ? 255 : 120 + y);
		}
	}
	return img;
}

<* What the alpha slices of one encode read through red and green. *>
struct GreyAlpha
{
	usz blocks;
	<* Blocks whose endpoint's red, green and blue are not all equal. *>
	usz non_grey;
	<* Texels whose red, green or blue differs from the alpha decode (which reads green). *>
	usz mismatched;
}

<*
 Encode an image and its sRGB mip chain to ETC1S with an alpha slice per level,
 laid out as basis.c3 lays them out, and check every alpha slice. basisu's BC3,
 BC4, BC7 and ETC2 transcoders read alpha from red, ours from green.
*>
fn GreyAlpha grey_alpha(char[] rgba, uint w, uint h, uint quality) => @pool()
{
	uint levels = 1;
	for (uint d = max(w, h); d > 1; d >>= 1) levels++;
	etc1s::EncSlice[] slices = mem::temp_array(etc1s::EncSlice, (usz)levels * 2);
	char[] mip = rgba;
	uint lw = w;
	uint lh = h;
	for (uint l = 0; l < levels; l++)
	{
		slices[l * 2] = { .rgba = mip, .width = lw, .height = lh, .alpha = false };
		slices[l * 2 + 1] = { .rgba = mip, .width = lw, .height = lh, .alpha = true };
		if (l + 1 == levels) break;
		mip = mipgen::next_level(tmem, mip, lw, lh, { .srgb = true });
		lw = max(lw >> 1, 1u);
		lh = max(lh >> 1, 1u);
	}
	etc1s::Encoded enc = etc1s::encode(tmem, slices, quality)!!;
	etc1s::Codebook cb = etc1s::decode_codebook(tmem, enc.num_endpoints, enc.endpoints_data,
		enc.num_selectors, enc.selectors_data, enc.tables_data)!!;

	GreyAlpha r;
	foreach (i, s : slices)
	{
		if (!s.alpha) continue;
		uint nbx = (s.width + 3) / 4;
		uint nby = (s.height + 3) / 4;
		etc1s::BlockRef[] refs = mem::temp_array(etc1s::BlockRef, (usz)nbx * nby);
		cb.decode_slice_blocks(enc.slices[i], nbx, nby, refs, tmem)!!;
		foreach (ref : refs)
		{
			char[3] c = cb.endpoints[ref.endpoint].color5;
			if (c[0] != c[1] || c[1] != c[2]) r.non_grey++;
		}
		r.blocks += refs.len;

		// The RGB pass on an alpha slice gives each texel's red, green and blue.
		char[] as_alpha = mem::temp_array(char, (usz)s.width * s.height * 4);
		char[] as_rgb = mem::temp_array(char, (usz)s.width * s.height * 4);
		cb.decode_slice(enc.slices[i], s.width, s.height, as_alpha, etc1s::Pass.ALPHA, tmem)!!;
		cb.decode_slice(enc.slices[i], s.width, s.height, as_rgb, etc1s::Pass.RGB, tmem)!!;
		for (usz p = 0; p < as_alpha.len; p += 4)
		{
			char a = as_alpha[p + 3];
			if (as_rgb[p] != a || as_rgb[p + 1] != a || as_rgb[p + 2] != a) r.mismatched++;
		}
	}
	return r;
}

<*
 Every alpha endpoint of every corpus image is grey at `quality`: the alpha
 image as it is, and each image with its green as alpha (noisy, smooth and
 flat alpha), as test/etc2-validate.sh feeds them.
*>
fn void assert_grey_alpha(uint quality) => @pool()
{
	String[5] names = { "gradient", "detail", "alpha", "gray", "normal" };
	usz blocks;
	foreach (name : names)
	{
		image::Image src = cli::load_image(tmem, string::tformat("test/images/%s.png", name))!!;
		char[] green = mem::temp_array(char, src.pixels.len);
		green[..] = src.pixels[..];
		for (usz i = 0; i < green.len; i += 4) green[i + 3] = green[i + 1];
		char[][2] inputs = { src.pixels, green };
		foreach (k, rgba : inputs)
		{
			GreyAlpha r = grey_alpha(rgba, src.width, src.height, quality);
			assert(r.non_grey == 0 && r.mismatched == 0,
				"%s%s q%d: %d of %d alpha blocks not grey, %d texels read differently through red and green",
				name, k ? " (green as alpha)" : "", quality, r.non_grey, r.blocks, r.mismatched);
			blocks += r.blocks;
		}
	}
	char[] img = make_image(tmem, 70, 54);
	GreyAlpha r = grey_alpha(img, 70, 54, quality);
	assert(r.non_grey == 0 && r.mismatched == 0, "make_image q%d: %d of %d alpha blocks not grey, %d texels read differently",
		quality, r.non_grey, r.blocks, r.mismatched);
	io::printfn("  q%d: %d alpha blocks, all grey", quality, blocks + r.blocks);
}

module etc1s_enc_tests @test;
import etc1s_enc_testutil;
import ktx::etc1s;
import std::io;

fn void rgb_roundtrip() => @pool()
{
	char[] img = etc1s_enc_testutil::make_image(tmem, 40, 28);
	double db = etc1s_enc_testutil::roundtrip_db(img, 40, 28, 90, false);
	io::printfn("  etc1s rgb round-trip q90: %.2f dB", db);
	assert(db > 30.0, "rgb round-trip: %.2f dB", db);
}

fn void alpha_roundtrip() => @pool()
{
	char[] img = etc1s_enc_testutil::make_image(tmem, 32, 32);
	double db = etc1s_enc_testutil::roundtrip_db(img, 32, 32, 90, true);
	io::printfn("  etc1s rgba round-trip q90: %.2f dB", db);
	assert(db > 28.0, "rgba round-trip: %.2f dB", db);
}

fn void quality_scales_size() => @pool()
{
	char[] img = etc1s_enc_testutil::make_image(tmem, 64, 64);
	usz size10;
	usz size90;
	double db10 = etc1s_enc_testutil::roundtrip_db(img, 64, 64, 10, false, &size10);
	double db90 = etc1s_enc_testutil::roundtrip_db(img, 64, 64, 90, false, &size90);
	io::printfn("  etc1s q10: %.2f dB %d B, q90: %.2f dB %d B", db10, size10, db90, size90);
	assert(size10 < size90, "q10 (%d B) should be smaller than q90 (%d B)", size10, size90);
	assert(db10 <= db90 + 0.01, "q10 (%.2f dB) should not beat q90 (%.2f dB)", db10, db90);
}

fn void tiny_slices_roundtrip() => @pool()
{
	// 1x1 .. 5x5: exercises single-block slices and odd group geometry.
	for (uint d = 1; d <= 5; d++)
	{
		char[] img = etc1s_enc_testutil::make_image(tmem, d, d);
		double db = etc1s_enc_testutil::roundtrip_db(img, d, d, 50, true);
		assert(db > 20.0, "%dx%d round-trip: %.2f dB", d, d, db);
	}
}

fn void alpha_endpoints_are_grey_at_low_quality() => etc1s_enc_testutil::assert_grey_alpha(10);

fn void alpha_endpoints_are_grey_at_high_quality() => etc1s_enc_testutil::assert_grey_alpha(90);

<*
 A flat 2048x2048 white image: all 262144 blocks land in one endpoint cluster,
 and the fit's channel sums (four million texels) must not wrap.
*>
fn void flat_large_image_keeps_its_colour() => @pool()
{
	const uint SIZE = 2048;
	char[] img = mem::temp_array(char, (usz)SIZE * SIZE * 4);
	img[..] = 255;
	etc1s::EncSlice[1] slices = { { .rgba = img, .width = SIZE, .height = SIZE } };
	etc1s::Encoded enc = etc1s::encode(tmem, slices[..], 10)!!;
	etc1s::Codebook cb = etc1s::decode_codebook(tmem, enc.num_endpoints, enc.endpoints_data,
		enc.num_selectors, enc.selectors_data, enc.tables_data)!!;
	char[] out = mem::temp_array(char, img.len);
	cb.decode_slice(enc.slices[0], SIZE, SIZE, out, etc1s::Pass.RGB_OPAQUE, tmem)!!;
	usz off;
	foreach (v : out) if (v != 255) off++;
	assert(off == 0, "%d of %d bytes decode below 255 (first texel %d %d %d)", off, out.len, out[0], out[1], out[2]);
}
