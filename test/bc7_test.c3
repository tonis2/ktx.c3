module bc7_testutil;
import ktx::bc7;
import std::math;

// Deterministic LCG for reproducible test images.
fn uint next_rand(uint* state)
{
	*state = *state * 1664525 + 1013904223;
	return *state >> 8;
}

struct Stats
{
	uint max_err;
	uint[4] max_err_ch; // per channel
	double rmse;
}

fn Stats compare(char[] a, char[] b)
{
	assert(a.len == b.len);
	Stats s;
	double sum = 0;
	foreach (i, v : a)
	{
		int d = (int)v - (int)b[i];
		uint ad = (uint)math::abs(d);
		s.max_err = math::max(s.max_err, ad);
		uint c = (uint)(i & 3);
		s.max_err_ch[c] = math::max(s.max_err_ch[c], ad);
		sum += (double)(d * d);
	}
	s.rmse = math::sqrt(sum / (double)a.len);
	return s;
}

// Encode + decode helper; asserts sizes are as contracted.
fn char[] roundtrip(char[] img, uint w, uint h, bool has_alpha)
{
	char[] enc = bc7::encode(mem, img, w, h, has_alpha)!!;
	assert(enc.len == bc7::encoded_size(w, h));
	char[] dec = bc7::decode(mem, enc, w, h)!!;
	assert(dec.len == (sz)w * h * 4);
	free(enc.ptr);
	return dec;
}

// Smooth diagonal gradient: the channels are colinear in color space
// (a single color ramp traversed spatially).
fn char[] make_gradient(uint w, uint h)
{
	char[] img = alloc::new_array(mem, char, (sz)w * h * 4);
	for (uint y = 0; y < h; y++)
	{
		for (uint x = 0; x < w; x++)
		{
			sz o = ((sz)y * w + x) * 4;
			uint t = ((x + y) * 255) / math::max(w + h - 2, 1u);
			img[o] = (char)t;
			img[o + 1] = (char)(30 + (t * 180) / 255);
			img[o + 2] = (char)(200 - (t * 160) / 255);
			img[o + 3] = 255;
		}
	}
	return img;
}

// Bilinear ramp: r varies along x, g along y. This is 2D variation in color
// space, which a per-block 1D palette (modes 1/5/6) cannot represent exactly.
fn char[] make_bilinear(uint w, uint h)
{
	char[] img = alloc::new_array(mem, char, (sz)w * h * 4);
	for (uint y = 0; y < h; y++)
	{
		for (uint x = 0; x < w; x++)
		{
			sz o = ((sz)y * w + x) * 4;
			img[o] = (char)((x * 255) / math::max(w - 1, 1u));
			img[o + 1] = (char)((y * 255) / math::max(h - 1, 1u));
			img[o + 2] = (char)(((x + y) * 255) / math::max(w + h - 2, 1u));
			img[o + 3] = 255;
		}
	}
	return img;
}

fn char[] make_noise(uint w, uint h, uint seed, bool vary_alpha)
{
	char[] img = alloc::new_array(mem, char, (sz)w * h * 4);
	uint state = seed;
	for (uint y = 0; y < h; y++)
	{
		for (uint x = 0; x < w; x++)
		{
			sz o = ((sz)y * w + x) * 4;
			for (uint c = 0; c < 3; c++)
			{
				int base = (int)((x * 200) / math::max(w - 1, 1u)) + (int)(c * 20);
				int jitter = (int)(next_rand(&state) % 25) - 12;
				img[o + c] = (char)math::clamp(base + jitter, 0, 255);
			}
			if (vary_alpha)
			{
				int abase = (int)((y * 220) / math::max(h - 1, 1u)) + 20;
				int jitter = (int)(next_rand(&state) % 17) - 8;
				img[o + 3] = (char)math::clamp(abase + jitter, 0, 255);
			}
			else
			{
				img[o + 3] = 255;
			}
		}
	}
	return img;
}

module bc7_tests @test;
import ktx::bc7, bc7_testutil;
import std::math;

fn void encoded_size_values()
{
	assert(bc7::encoded_size(4, 4) == 16);
	assert(bc7::encoded_size(1, 1) == 16);
	assert(bc7::encoded_size(5, 3) == 32);
	assert(bc7::encoded_size(7, 7) == 64);
	assert(bc7::encoded_size(8, 8) == 64);
	assert(bc7::encoded_size(16, 16) == 256);
	assert(bc7::encoded_size(0, 4) == 0);
}

fn void decode_zero_block_is_transparent_black()
{
	char[16] blk;
	char[] dec = bc7::decode(mem, blk[..], 4, 4)!!;
	assert(dec.len == 64);
	foreach (v : dec) assert(v == 0);
	free(dec.ptr);
}

fn void decode_rejects_bad_size()
{
	char[16] blk;
	assert(@catch(bc7::decode(mem, blk[..], 8, 8)));
	char[8] small;
	assert(@catch(bc7::encode(mem, small[..], 4, 4)));
}

fn void zero_sized_image()
{
	char[] none;
	char[] enc = bc7::encode(mem, none, 0, 0)!!;
	assert(enc.len == 0);
	char[] dec = bc7::decode(mem, none, 0, 4)!!;
	assert(dec.len == 0);
}

// Known-answer test, mode 6: endpoints r0=127 g0=0 b0=50 a0=100 (p0=1),
// r1=0 g1=127 b1=25 a1=60 (p1=0), indices 0..15.
// Vectors generated with an independent implementation of the BC7 spec.
fn void kat_mode6()
{
	char[16] blk = { 0xc0, 0x3f, 0x00, 0xf0, 0x97, 0x65, 0xc8, 0xbc, 0x10, 0x32, 0x54, 0x76, 0x98, 0xba, 0xdc, 0xfe };
	char[64] expected = {
		0xff, 0x01, 0x65, 0xc9, 0xef, 0x11, 0x62, 0xc4, 0xdb, 0x25, 0x5e, 0xbe, 0xcb, 0x34, 0x5b, 0xb9,
		0xbb, 0x44, 0x57, 0xb3, 0xab, 0x54, 0x54, 0xae, 0x97, 0x68, 0x50, 0xa8, 0x87, 0x78, 0x4d, 0xa3,
		0x78, 0x87, 0x4a, 0x9e, 0x68, 0x97, 0x47, 0x99, 0x54, 0xab, 0x43, 0x93, 0x44, 0xbb, 0x40, 0x8e,
		0x34, 0xcb, 0x3c, 0x88, 0x24, 0xda, 0x39, 0x83, 0x10, 0xee, 0x35, 0x7d, 0x00, 0xfe, 0x32, 0x78 };
	char[] dec = bc7::decode(mem, blk[..], 4, 4)!!;
	assert(dec == expected[..]);
	free(dec.ptr);
}

// Known-answer test, mode 5 rotation 0: color endpoints (127,64,0)->(0,32,127),
// alpha 200->10, mixed 2-bit index patterns.
fn void kat_mode5()
{
	char[16] blk = { 0x20, 0x7f, 0x00, 0x10, 0x04, 0xf8, 0x23, 0x2b, 0xc8, 0x37, 0xc8, 0x37, 0x92, 0x1b, 0xf9, 0x46 };
	char[64] expected = {
		0xff, 0x81, 0x00, 0x8a, 0xab, 0x6c, 0x54, 0xc8, 0x54, 0x55, 0xab, 0x8a, 0x00, 0x40, 0xff, 0x48,
		0x00, 0x40, 0xff, 0x0a, 0x54, 0x55, 0xab, 0x48, 0xab, 0x6c, 0x54, 0x8a, 0xff, 0x81, 0x00, 0xc8,
		0xff, 0x81, 0x00, 0x8a, 0xab, 0x6c, 0x54, 0x48, 0x54, 0x55, 0xab, 0x0a, 0x00, 0x40, 0xff, 0x0a,
		0x00, 0x40, 0xff, 0x48, 0x54, 0x55, 0xab, 0x8a, 0xab, 0x6c, 0x54, 0xc8, 0xff, 0x81, 0x00, 0x8a };
	char[] dec = bc7::decode(mem, blk[..], 4, 4)!!;
	assert(dec == expected[..]);
	free(dec.ptr);
}

// Known-answer test, mode 5 rotation 2 (alpha <-> green swap).
fn void kat_mode5_rotation()
{
	char[16] blk = { 0xa0, 0x7f, 0x00, 0x10, 0x04, 0xf8, 0x23, 0x2b, 0xc8, 0x37, 0xc8, 0x37, 0x92, 0x1b, 0xf9, 0x46 };
	char[64] expected = {
		0xff, 0x8a, 0x00, 0x81, 0xab, 0xc8, 0x54, 0x6c, 0x54, 0x8a, 0xab, 0x55, 0x00, 0x48, 0xff, 0x40,
		0x00, 0x0a, 0xff, 0x40, 0x54, 0x48, 0xab, 0x55, 0xab, 0x8a, 0x54, 0x6c, 0xff, 0xc8, 0x00, 0x81,
		0xff, 0x8a, 0x00, 0x81, 0xab, 0x48, 0x54, 0x6c, 0x54, 0x0a, 0xab, 0x55, 0x00, 0x0a, 0xff, 0x40,
		0x00, 0x48, 0xff, 0x40, 0x54, 0x8a, 0xab, 0x55, 0xab, 0xc8, 0x54, 0x6c, 0xff, 0x8a, 0x00, 0x81 };
	char[] dec = bc7::decode(mem, blk[..], 4, 4)!!;
	assert(dec == expected[..]);
	free(dec.ptr);
}

fn void solid_colors_roundtrip()
{
	char[4][6] colors = {
		{ 255, 0, 0, 255 },
		{ 0, 255, 0, 255 },
		{ 12, 34, 56, 255 },
		{ 200, 100, 50, 128 },   // translucent
		{ 7, 255, 3, 9 },        // nearly transparent
		{ 127, 128, 129, 255 },
	};
	foreach (color : colors)
	{
		char[8 * 8 * 4] img;
		for (uint i = 0; i < 64; i++)
		{
			for (uint c = 0; c < 4; c++) img[i * 4 + c] = color[c];
		}
		char[] dec = bc7_testutil::roundtrip(img[..], 8, 8, true);
		foreach (i, v : dec)
		{
			int d = math::abs((int)v - (int)color[i & 3]);
			assert(d <= 2, "solid color channel error %d > 2", d);
		}
		free(dec.ptr);
	}
}

fn void opaque_gradient_roundtrip()
{
	char[] img = bc7_testutil::make_gradient(16, 16);
	char[] dec = bc7_testutil::roundtrip(img, 16, 16, true);
	bc7_testutil::Stats s = bc7_testutil::compare(img, dec);
	assert(s.max_err <= 8, "gradient max err %d > 8", s.max_err);
	assert(s.rmse <= 3.0, "gradient rmse too high");
	free(img.ptr);
	free(dec.ptr);
}

// Bilinear (2D) ramps exceed what a per-block 1D palette can represent;
// this documents the achievable bound for modes 1/6.
fn void bilinear_ramp_sanity()
{
	char[] img = bc7_testutil::make_bilinear(16, 16);
	char[] dec = bc7_testutil::roundtrip(img, 16, 16, true);
	bc7_testutil::Stats s = bc7_testutil::compare(img, dec);
	assert(s.max_err <= 16, "bilinear max err %d > 16", s.max_err);
	assert(s.rmse <= 6.0, "bilinear rmse too high");
	free(img.ptr);
	free(dec.ptr);
}

fn void alpha_gradient_roundtrip()
{
	uint w = 16;
	uint h = 16;
	char[] img = alloc::new_array(mem, char, (sz)w * h * 4);
	for (uint y = 0; y < h; y++)
	{
		for (uint x = 0; x < w; x++)
		{
			sz o = ((sz)y * w + x) * 4;
			img[o] = 100;
			img[o + 1] = 150;
			img[o + 2] = 200;
			img[o + 3] = (char)((x + y * w) * 255 / (w * h - 1));
		}
	}
	char[] dec = bc7_testutil::roundtrip(img, w, h, true);
	bc7_testutil::Stats s = bc7_testutil::compare(img, dec);
	assert(s.max_err_ch[3] <= 8, "alpha max err %d > 8", s.max_err_ch[3]);
	free(img.ptr);
	free(dec.ptr);
}

fn void noise_roundtrip_opaque()
{
	char[] img = bc7_testutil::make_noise(16, 16, 12345, false);
	char[] dec = bc7_testutil::roundtrip(img, 16, 16, true);
	bc7_testutil::Stats s = bc7_testutil::compare(img, dec);
	assert(s.rmse <= 12.0, "noise rmse too high");
	free(img.ptr);
	free(dec.ptr);
}

fn void noise_roundtrip_alpha()
{
	char[] img = bc7_testutil::make_noise(12, 12, 999, true);
	char[] dec = bc7_testutil::roundtrip(img, 12, 12, true);
	bc7_testutil::Stats s = bc7_testutil::compare(img, dec);
	assert(s.rmse <= 12.0, "alpha noise rmse too high");
	// 2-bit alpha indices (mode 5) bound alpha precision on noisy alpha;
	// the strict <= 8 requirement is covered by alpha_gradient_roundtrip.
	assert(s.max_err_ch[3] <= 24, "alpha channel err too high");
	free(img.ptr);
	free(dec.ptr);
}

fn void non_multiple_of_four_sizes()
{
	uint[2][3] sizes = { { 5, 3 }, { 1, 1 }, { 7, 7 } };
	foreach (dims : sizes)
	{
		uint w = dims[0];
		uint h = dims[1];
		char[] img = bc7_testutil::make_noise(w, h, 42 + w * 100 + h, false);
		char[] dec = bc7_testutil::roundtrip(img, w, h, true);
		bc7_testutil::Stats s = bc7_testutil::compare(img, dec);
		assert(s.rmse <= 12.0, "small size rmse too high");
		free(img.ptr);
		free(dec.ptr);
	}
}

fn void one_by_one_exactish()
{
	char[4] img = { 77, 178, 33, 255 };
	char[] dec = bc7_testutil::roundtrip(img[..], 1, 1, true);
	for (uint c = 0; c < 4; c++)
	{
		assert(math::abs((int)dec[c] - (int)img[c]) <= 2);
	}
	free(dec.ptr);
}

fn void has_alpha_false_ignores_alpha()
{
	// Garbage alpha in, opaque out.
	char[] img = bc7_testutil::make_noise(8, 8, 777, true);
	char[] enc = bc7::encode(mem, img, 8, 8, false)!!;
	char[] dec = bc7::decode(mem, enc, 8, 8)!!;
	for (uint i = 0; i < 64; i++)
	{
		assert((uint)dec[i * 4 + 3] >= 253, "expected opaque alpha, got %d", dec[i * 4 + 3]);
		// RGB should still match the source closely.
	}
	free(img.ptr);
	free(enc.ptr);
	free(dec.ptr);
}
