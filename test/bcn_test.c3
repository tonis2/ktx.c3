// Helper module: @test modules cannot contain functions with parameters.
module bcn_util;
import ktx::bcn;
import std::math;

struct Lcg
{
	ulong state;
}

fn char Lcg.next_byte(&self)
{
	self.state = self.state * 6364136223846793005UL + 1442695040888963407UL;
	return (char)(self.state >> 33);
}

fn char[] make_noise(uint width, uint height, ulong seed)
{
	char[] img = alloc::new_array(mem, char, (sz)width * height * 4);
	Lcg rng = { seed };
	foreach (&p : img) *p = rng.next_byte();
	return img;
}

fn char[] make_solid(uint width, uint height, char r, char g, char b, char a)
{
	char[] img = alloc::new_array(mem, char, (sz)width * height * 4);
	for (sz i = 0; i < (sz)width * height; i++)
	{
		img[i * 4] = r;
		img[i * 4 + 1] = g;
		img[i * 4 + 2] = b;
		img[i * 4 + 3] = a;
	}
	return img;
}

// Horizontal gradient in all four channels (alpha inverted).
fn char[] make_gradient(uint width, uint height)
{
	char[] img = alloc::new_array(mem, char, (sz)width * height * 4);
	for (uint y = 0; y < height; y++)
	{
		for (uint x = 0; x < width; x++)
		{
			sz i = ((sz)y * width + x) * 4;
			char v = width > 1 ? (char)((x * 255) / (width - 1)) : (char)0;
			char w = height > 1 ? (char)((y * 255) / (height - 1)) : (char)0;
			img[i] = v;
			img[i + 1] = w;
			img[i + 2] = (char)((v + w) / 2);
			img[i + 3] = (char)(255 - v);
		}
	}
	return img;
}

// Max abs error and RMSE over the channels a format actually carries.
fn void channel_mask(BcnFormat fmt, bool[4]* mask)
{
	switch (fmt)
	{
		case BC1: *mask = { true, true, true, false };
		case BC3: *mask = { true, true, true, true };
		case BC4: *mask = { true, false, false, false };
		case BC5: *mask = { true, true, false, false };
	}
}

fn void diff_stats(BcnFormat fmt, char[] a, char[] b, int* max_err, double* rmse)
{
	assert(a.len == b.len);
	bool[4] mask;
	channel_mask(fmt, &mask);
	long sum_sq = 0;
	long n = 0;
	int worst = 0;
	for (sz i = 0; i < a.len; i++)
	{
		if (!mask[i % 4]) continue;
		int d = (int)a[i] - (int)b[i];
		if (d < 0) d = -d;
		if (d > worst) worst = d;
		sum_sq += (long)d * d;
		n++;
	}
	*max_err = worst;
	*rmse = n > 0 ? math::sqrt((double)sum_sq / (double)n) : 0.0;
}

fn void roundtrip(BcnFormat fmt, char[] img, uint w, uint h, int* max_err, double* rmse)
{
	char[] enc = bcn::encode(mem, fmt, img, w, h)!!;
	defer free(enc.ptr);
	assert(enc.len == bcn::encoded_size(fmt, w, h), "encoded size mismatch");
	char[] dec = bcn::decode(mem, fmt, enc, w, h)!!;
	defer free(dec.ptr);
	assert(dec.len == (sz)w * h * 4, "decoded size mismatch");
	diff_stats(fmt, img, dec, max_err, rmse);
}

fn int abs_diff(char a, char b)
{
	int d = (int)a - (int)b;
	return d < 0 ? -d : d;
}

// Slow gradient: ~8 levels of change per 4x4 block in every channel.
fn char[] make_gentle_gradient(uint width, uint height)
{
	char[] img = alloc::new_array(mem, char, (sz)width * height * 4);
	for (uint y = 0; y < height; y++)
	{
		for (uint x = 0; x < width; x++)
		{
			sz i = ((sz)y * width + x) * 4;
			img[i] = (char)(40 + x * 4);
			img[i + 1] = (char)(80 + y * 4);
			img[i + 2] = (char)(60 + x * 2 + y * 2);
			img[i + 3] = (char)(200 + x * 2);
		}
	}
	return img;
}

// Random base color per 4x4 block plus per-pixel jitter of +/-24.
fn char[] make_clustered_noise(uint width, uint height, ulong seed)
{
	char[] img = alloc::new_array(mem, char, (sz)width * height * 4);
	Lcg rng = { seed };
	for (uint by = 0; by < (height + 3) / 4; by++)
	{
		for (uint bx = 0; bx < (width + 3) / 4; bx++)
		{
			int[4] base;
			foreach (&c : base) *c = 24 + (int)(rng.next_byte() % 208);
			for (uint y = by * 4; y < by * 4 + 4 && y < height; y++)
			{
				for (uint x = bx * 4; x < bx * 4 + 4 && x < width; x++)
				{
					sz i = ((sz)y * width + x) * 4;
					for (uint c = 0; c < 4; c++)
					{
						int v = base[c] + (int)(rng.next_byte() % 49) - 24;
						if (v < 0) v = 0;
						if (v > 255) v = 255;
						img[i + c] = (char)v;
					}
				}
			}
		}
	}
	return img;
}

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------
module bcn_tests @test;
import ktx::bcn, bcn_util;

// ---------------------------------------------------------------------------
// encoded_size
// ---------------------------------------------------------------------------

fn void encoded_size_exact()
{
	assert(bcn::encoded_size(BcnFormat.BC1, 4, 4) == 8);
	assert(bcn::encoded_size(BcnFormat.BC3, 4, 4) == 16);
	assert(bcn::encoded_size(BcnFormat.BC4, 4, 4) == 8);
	assert(bcn::encoded_size(BcnFormat.BC5, 4, 4) == 16);
	assert(bcn::encoded_size(BcnFormat.BC1, 8, 4) == 16);
	assert(bcn::encoded_size(BcnFormat.BC1, 5, 3) == 2 * 1 * 8);   // ceil-div
	assert(bcn::encoded_size(BcnFormat.BC3, 1, 1) == 16);
	assert(bcn::encoded_size(BcnFormat.BC5, 7, 7) == 2 * 2 * 16);
	assert(bcn::encoded_size(BcnFormat.BC1, 256, 256) == 64 * 64 * 8);
}

// ---------------------------------------------------------------------------
// Decoder known-answer tests
// ---------------------------------------------------------------------------

// All-zero BC1 block: c0 == c1 == 0 -> 3-color mode, index 0 -> black, opaque.
fn void bc1_decode_zero_block()
{
	char[8] block;
	char[] dec = bcn::decode(mem, BcnFormat.BC1, &block, 4, 4)!!;
	defer free(dec.ptr);
	for (uint i = 0; i < 16; i++)
	{
		assert(dec[i * 4] == 0 && dec[i * 4 + 1] == 0 && dec[i * 4 + 2] == 0);
		assert(dec[i * 4 + 3] == 255);
	}
}

// BC1 endpoints white (0xFFFF) / black (0x0000), one selector byte per row:
// row0 all index 0 (white), row1 all index 1 (black),
// row2 all index 2 -> (2*255+0)/3 = 170, row3 all index 3 -> 255/3 = 85.
fn void bc1_decode_black_white()
{
	char[8] block = { 0xFF, 0xFF, 0x00, 0x00, 0b00000000, 0b01010101, 0b10101010, 0b11111111 };
	char[] dec = bcn::decode(mem, BcnFormat.BC1, &block, 4, 4)!!;
	defer free(dec.ptr);
	char[4] expect = { 255, 0, 170, 85 };
	for (uint y = 0; y < 4; y++)
	{
		for (uint x = 0; x < 4; x++)
		{
			sz i = (sz)(y * 4 + x) * 4;
			assert(dec[i] == expect[y], "row %d x %d: got %d want %d", y, x, dec[i], expect[y]);
			assert(dec[i + 1] == expect[y] && dec[i + 2] == expect[y]);
			assert(dec[i + 3] == 255);
		}
	}
}

// BC1 punchthrough mode: c0 <= c1, index 3 -> transparent black,
// index 2 -> (c0+c1)/2.
fn void bc1_decode_punchthrough()
{
	// c0 = 0x0000 (black), c1 = 0xFFFF (white): c0 <= c1 -> 3-color mode.
	char[8] block = { 0x00, 0x00, 0xFF, 0xFF, 0b11111111, 0b10101010, 0, 0 };
	char[] dec = bcn::decode(mem, BcnFormat.BC1, &block, 4, 4)!!;
	defer free(dec.ptr);
	for (uint x = 0; x < 4; x++)
	{
		// Row 0: index 3 -> (0,0,0,0).
		sz i = (sz)x * 4;
		assert(dec[i] == 0 && dec[i + 1] == 0 && dec[i + 2] == 0 && dec[i + 3] == 0);
		// Row 1: index 2 -> (0+255)/2 = 127, opaque.
		sz j = (sz)(4 + x) * 4;
		assert(dec[j] == 127 && dec[j + 1] == 127 && dec[j + 2] == 127 && dec[j + 3] == 255);
	}
}

// BC1 565 expansion: c0 = r5=16,g6=32,b5=8 -> r=(16<<3)|(16>>2)=132,
// g=(32<<2)|(32>>4)=130, b=(8<<3)|(8>>2)=66. c1 = 0 -> 4-color (c0 > c1),
// all indices 0.
fn void bc1_decode_565_expansion()
{
	ushort c0 = (16 << 11) | (32 << 5) | 8;
	char[8] block = { (char)(c0 & 0xFF), (char)(c0 >> 8), 0, 0, 0, 0, 0, 0 };
	char[] dec = bcn::decode(mem, BcnFormat.BC1, &block, 4, 4)!!;
	defer free(dec.ptr);
	assert(dec[0] == 132 && dec[1] == 130 && dec[2] == 66 && dec[3] == 255);
}

// BC4 8-value mode (e0 > e1): e0=255, e1=0.
// Values: v0=255, v1=0, vN=(255*(8-N))/7 for N=2..7 -> 218,182,145,109,72,36.
// Indices 0..7 in first 8 texels, rest index 0. Also exercises the 48-bit
// little-endian selector packing.
fn void bc4_decode_known_answer()
{
	ulong bits = 0;
	for (uint i = 0; i < 8; i++) bits |= (ulong)i << (i * 3);
	char[8] block;
	block[0] = 255;
	block[1] = 0;
	for (uint i = 0; i < 6; i++) block[2 + i] = (char)((bits >> (i * 8)) & 0xFF);

	char[] dec = bcn::decode(mem, BcnFormat.BC4, &block, 4, 4)!!;
	defer free(dec.ptr);
	char[8] expect = { 255, 0, 218, 182, 145, 109, 72, 36 };
	for (uint i = 0; i < 8; i++)
	{
		assert(dec[i * 4] == expect[i], "texel %d: got %d want %d", i, dec[i * 4], expect[i]);
		// BC4 decodes to (r,r,r,255).
		assert(dec[i * 4 + 1] == expect[i] && dec[i * 4 + 2] == expect[i]);
		assert(dec[i * 4 + 3] == 255);
	}
	for (uint i = 8; i < 16; i++) assert(dec[i * 4] == 255);
}

// BC4 6-value + 0/255 mode (e0 <= e1): e0=0, e1=255.
// v0=0, v1=255, vN=(255*(N-1))/5 for N=2..5 -> 51,102,153,204; v6=0, v7=255.
fn void bc4_decode_six_value_mode()
{
	ulong bits = 0;
	for (uint i = 0; i < 8; i++) bits |= (ulong)i << (i * 3);
	char[8] block;
	block[0] = 0;
	block[1] = 255;
	for (uint i = 0; i < 6; i++) block[2 + i] = (char)((bits >> (i * 8)) & 0xFF);

	char[] dec = bcn::decode(mem, BcnFormat.BC4, &block, 4, 4)!!;
	defer free(dec.ptr);
	char[8] expect = { 0, 255, 51, 102, 153, 204, 0, 255 };
	for (uint i = 0; i < 8; i++)
	{
		assert(dec[i * 4] == expect[i], "texel %d: got %d want %d", i, dec[i * 4], expect[i]);
	}
}

// BC5 output layout: (r, g, 0, 255).
fn void bc5_decode_layout()
{
	char[16] block;
	block[0] = 200; // R block: e0=200, e1=100, all indices 0 -> r = 200
	block[1] = 100;
	block[8] = 40;  // G block: e0=40, e1=10, all indices 0 -> g = 40
	block[9] = 10;
	char[] dec = bcn::decode(mem, BcnFormat.BC5, &block, 4, 4)!!;
	defer free(dec.ptr);
	for (uint i = 0; i < 16; i++)
	{
		assert(dec[i * 4] == 200 && dec[i * 4 + 1] == 40);
		assert(dec[i * 4 + 2] == 0 && dec[i * 4 + 3] == 255);
	}
}

// BC3: alpha block first (BC4-style), then BC1 color block.
fn void bc3_decode_layout()
{
	char[16] block;
	block[0] = 128;                 // alpha e0=128, e1=0, indices 0 -> a=128
	block[1] = 0;
	block[8] = 0xFF; block[9] = 0xFF; // color0 = white
	block[10] = 0; block[11] = 0;     // color1 = black, all indices 0 -> white
	char[] dec = bcn::decode(mem, BcnFormat.BC3, &block, 4, 4)!!;
	defer free(dec.ptr);
	for (uint i = 0; i < 16; i++)
	{
		assert(dec[i * 4] == 255 && dec[i * 4 + 1] == 255 && dec[i * 4 + 2] == 255);
		assert(dec[i * 4 + 3] == 128);
	}
}

// ---------------------------------------------------------------------------
// Solid-color round-trips (exact within 565 quantization)
// ---------------------------------------------------------------------------

fn void solid_colors_roundtrip()
{
	char[3][4] colors = { { 0, 0, 0 }, { 255, 255, 255 }, { 128, 128, 128 }, { 255, 0, 128 } };
	BcnFormat[4] fmts = { BcnFormat.BC1, BcnFormat.BC3, BcnFormat.BC4, BcnFormat.BC5 };
	foreach (fmt : fmts)
	{
		foreach (c : colors)
		{
			char[] img = bcn_util::make_solid(8, 8, c[0], c[1], c[2], 200);
			defer free(img.ptr);
			int max_err;
			double rmse;
			bcn_util::roundtrip(fmt, img, 8, 8, &max_err, &rmse);
			// BC4/BC5/BC3-alpha are exact for flat blocks; BC1 color is
			// within 565 quantization (<= 8 per channel; 0/255/128 are <= 4).
			assert(max_err <= 8, "%s solid (%d,%d,%d): max_err %d", fmt, c[0], c[1], c[2], max_err);
		}
	}
}

fn void solid_black_white_exact()
{
	// 0 and 255 survive 565 round-trip exactly; alpha 255 is exact in BC3.
	char[] img = bcn_util::make_solid(4, 4, 255, 255, 255, 255);
	defer free(img.ptr);
	int max_err;
	double rmse;
	bcn_util::roundtrip(BcnFormat.BC3, img, 4, 4, &max_err, &rmse);
	assert(max_err == 0, "white BC3 max_err %d", max_err);

	char[] img2 = bcn_util::make_solid(4, 4, 0, 0, 0, 255);
	defer free(img2.ptr);
	bcn_util::roundtrip(BcnFormat.BC1, img2, 4, 4, &max_err, &rmse);
	assert(max_err == 0, "black BC1 max_err %d", max_err);
}

// ---------------------------------------------------------------------------
// Gradients
// ---------------------------------------------------------------------------

fn void gradient_bc1()
{
	char[] img = bcn_util::make_gradient(32, 32);
	defer free(img.ptr);
	int max_err;
	double rmse;
	bcn_util::roundtrip(BcnFormat.BC1, img, 32, 32, &max_err, &rmse);
	assert(max_err <= 20, "BC1 gradient max_err %d", max_err);
	assert(rmse <= 8.0, "BC1 gradient rmse %f", rmse);
}

fn void gradient_bc3()
{
	char[] img = bcn_util::make_gradient(32, 32);
	defer free(img.ptr);
	int max_err;
	double rmse;
	bcn_util::roundtrip(BcnFormat.BC3, img, 32, 32, &max_err, &rmse);
	assert(max_err <= 20, "BC3 gradient max_err %d", max_err);
	assert(rmse <= 8.0, "BC3 gradient rmse %f", rmse);
}

fn void gradient_bc4_bc5()
{
	char[] img = bcn_util::make_gradient(32, 32);
	defer free(img.ptr);
	int max_err;
	double rmse;
	bcn_util::roundtrip(BcnFormat.BC4, img, 32, 32, &max_err, &rmse);
	assert(max_err <= 4, "BC4 gradient max_err %d", max_err);
	bcn_util::roundtrip(BcnFormat.BC5, img, 32, 32, &max_err, &rmse);
	assert(max_err <= 4, "BC5 gradient max_err %d", max_err);
}

// ---------------------------------------------------------------------------
// Random noise (deterministic LCG)
// ---------------------------------------------------------------------------

// Full-range isotropic RGB noise. For BC1/BC3 color the *theoretical* floor
// is ~57-60 RMSE (4 collinear palette colors cannot capture the variance
// perpendicular to the best-fit line, which is ~2/3 of an isotropic
// distribution), so the sanity bound there is 64; single-channel BC4/BC5
// quantize the full range into 8 levels and must stay under 24.
fn void noise_roundtrip_all_formats()
{
	BcnFormat[4] fmts = { BcnFormat.BC1, BcnFormat.BC3, BcnFormat.BC4, BcnFormat.BC5 };
	foreach (fmt : fmts)
	{
		char[] img = bcn_util::make_noise(64, 64, 0xC0FFEE ^ (ulong)fmt.ordinal);
		defer free(img.ptr);
		int max_err;
		double rmse;
		bcn_util::roundtrip(fmt, img, 64, 64, &max_err, &rmse);
		double bound = (fmt == BcnFormat.BC1 || fmt == BcnFormat.BC3) ? 64.0 : 24.0;
		assert(rmse <= bound, "%s noise rmse %f", fmt, rmse);
	}
}

// Block-correlated noise (random base color per 4x4 block + per-pixel jitter
// of +/-24): representable content, so every format must stay under RMSE 24.
fn void clustered_noise_rmse()
{
	uint w = 64;
	uint h = 64;
	BcnFormat[4] fmts = { BcnFormat.BC1, BcnFormat.BC3, BcnFormat.BC4, BcnFormat.BC5 };
	foreach (fmt : fmts)
	{
		char[] img = bcn_util::make_clustered_noise(w, h, 0xBADC0DE ^ (ulong)fmt.ordinal);
		defer free(img.ptr);
		int max_err;
		double rmse;
		bcn_util::roundtrip(fmt, img, w, h, &max_err, &rmse);
		assert(rmse <= 24.0, "%s clustered noise rmse %f", fmt, rmse);
	}
}

// ---------------------------------------------------------------------------
// Non-multiple-of-4 sizes
// ---------------------------------------------------------------------------

// Uses a gentle gradient (small per-block value range) so the quality bounds
// stay meaningful; a full 0..255 ramp over 5 pixels would put a 2D color
// spread inside one block that no BC1 palette can represent.
fn void odd_sizes_roundtrip()
{
	uint[2][4] sizes = { { 5, 3 }, { 1, 1 }, { 7, 7 }, { 9, 2 } };
	BcnFormat[4] fmts = { BcnFormat.BC1, BcnFormat.BC3, BcnFormat.BC4, BcnFormat.BC5 };
	foreach (s : sizes)
	{
		foreach (fmt : fmts)
		{
			char[] img = bcn_util::make_gentle_gradient(s[0], s[1]);
			defer free(img.ptr);
			int max_err;
			double rmse;
			bcn_util::roundtrip(fmt, img, s[0], s[1], &max_err, &rmse);
			int bound = (fmt == BcnFormat.BC4 || fmt == BcnFormat.BC5) ? 4 : 20;
			assert(max_err <= bound, "%s %dx%d max_err %d", fmt, s[0], s[1], max_err);
		}
	}
}

// Edge replication: a 5-wide image where column 4 differs from column 0-3
// must still decode column 4 correctly (it sits in a partial block).
fn void odd_size_edge_content()
{
	char[] img = bcn_util::make_solid(5, 4, 10, 20, 30, 255);
	defer free(img.ptr);
	// Make the rightmost column bright.
	for (uint y = 0; y < 4; y++)
	{
		sz i = ((sz)y * 5 + 4) * 4;
		img[i] = 250;
		img[i + 1] = 240;
		img[i + 2] = 230;
	}
	char[] enc = bcn::encode(mem, BcnFormat.BC1, img, 5, 4)!!;
	defer free(enc.ptr);
	assert(enc.len == 2 * 8);
	char[] dec = bcn::decode(mem, BcnFormat.BC1, enc, 5, 4)!!;
	defer free(dec.ptr);
	for (uint y = 0; y < 4; y++)
	{
		sz i = ((sz)y * 5 + 4) * 4;
		// The partial block holds a single (replicated) color; expect it back
		// within 565 quantization.
		assert(bcn_util::abs_diff(dec[i], 250) <= 8 && bcn_util::abs_diff(dec[i + 1], 240) <= 8 && bcn_util::abs_diff(dec[i + 2], 230) <= 8);
	}
}

// ---------------------------------------------------------------------------
// Input validation
// ---------------------------------------------------------------------------

fn void bad_inputs_fault()
{
	char[16] tiny;
	assert(@catch(bcn::encode(mem, BcnFormat.BC1, &tiny, 4, 4)));  // wrong pixel count
	assert(@catch(bcn::encode(mem, BcnFormat.BC1, &tiny, 0, 0)));  // zero dims
	assert(@catch(bcn::decode(mem, BcnFormat.BC1, &tiny, 12, 4))); // wrong block count
}

// BC1 encoder must always emit c0 > c1 (4-color mode) or equal endpoints;
// never c0 < c1 (which would flip the decoder into punchthrough mode) and,
// when endpoints are equal, never index 3.
fn void bc1_encoder_mode_invariant()
{
	Lcg rng = { 42 };
	for (uint t = 0; t < 200; t++)
	{
		char[64] img;
		foreach (&p : img) *p = rng.next_byte();
		char[] enc = bcn::encode(mem, BcnFormat.BC1, &img, 4, 4)!!;
		defer free(enc.ptr);
		uint c0 = (uint)enc[0] | ((uint)enc[1] << 8);
		uint c1 = (uint)enc[2] | ((uint)enc[3] << 8);
		assert(c0 >= c1, "trial %d: c0 %d < c1 %d", t, c0, c1);
		if (c0 == c1)
		{
			for (uint y = 0; y < 4; y++)
			{
				uint row = enc[4 + y];
				for (uint x = 0; x < 4; x++)
				{
					assert(((row >> (x * 2)) & 3) != 3, "punchthrough index with equal endpoints");
				}
			}
		}
	}
}

// BC4 encoder emits only e0 >= e1; decoder handles both modes regardless.
fn void bc4_encoder_mode_invariant()
{
	Lcg rng = { 1234 };
	for (uint t = 0; t < 200; t++)
	{
		char[64] img;
		foreach (&p : img) *p = rng.next_byte();
		char[] enc = bcn::encode(mem, BcnFormat.BC4, &img, 4, 4)!!;
		defer free(enc.ptr);
		assert(enc[0] >= enc[1], "trial %d: e0 %d < e1 %d", t, enc[0], enc[1]);
	}
}
