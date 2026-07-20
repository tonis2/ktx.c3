// Phase-5 unit tests (docs/basis-rewrite.md): the C3 ETC1S encoder round-trips
// through our own golden-verified decoder (decode_codebook + decode_slice).
// KTX2-level interop gates (basisu decodes our files identically, ktx
// validate) live in basis_enc_test.c3.
module etc1s_enc_testutil;
import ktx::etc1s;
import ktx_testutil;
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

module etc1s_enc_tests @test;
import etc1s_enc_testutil;
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
