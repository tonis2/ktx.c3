// BC1/BC3/BC4/BC5 (S3TC/RGTC) block-compression encoders and decoders.
//
// Decode semantics are bit-exact with the basis_universal reference
// unpackers (basisu_gpu_texture.cpp): 565->888 expansion by bit
// replication, BC1 interpolants (2*a+b)/3 with truncating division,
// BC4 interpolants (a*(8-N)+b*(N-1))/7 (8-value mode) and
// (a*(6-N)+b*(N-1))/5 plus 0/255 (6-value mode), truncating division.
module ktx::bcn;
import std::core::mem;

faultdef INVALID_SIZE, INVALID_INPUT;

enum BcnFormat : int
{
	BC1, // RGB, opaque 4-color mode only, 8 bytes / 4x4 block
	BC3, // RGBA: BC4-style alpha block + BC1 color block, 16 bytes
	BC4, // single channel (R), 8 bytes
	BC5, // two channels (R, G), 16 bytes
}

<*
 Bytes needed to hold the encoded image: ceil(width/4) * ceil(height/4)
 blocks, 8 bytes per block for BC1/BC4 and 16 for BC3/BC5.
*>
fn sz encoded_size(BcnFormat fmt, uint width, uint height)
{
	sz bx = ((sz)width + 3) / 4;
	sz by = ((sz)height + 3) / 4;
	return bx * by * block_bytes(fmt);
}

<*
 Encode a tightly-packed RGBA8 image (4 bytes per pixel, rgba.len must be
 width*height*4) into row-major 4x4 blocks. For images whose dimensions are
 not multiples of 4, edge pixels are replicated into the partial blocks.
 Channels used: BC1 = RGB, BC3 = RGBA, BC4 = R, BC5 = RG.
 Returns a buffer of exactly encoded_size(fmt, width, height) bytes.
*>
fn char[]? encode(Allocator allocator, BcnFormat fmt, char[] rgba, uint width, uint height)
{
	if (width == 0 || height == 0) return INVALID_SIZE~;
	if (rgba.len != (sz)width * height * 4) return INVALID_INPUT~;

	char[] out = alloc::new_array(allocator, char, encoded_size(fmt, width, height));
	sz bb = block_bytes(fmt);
	uint bx_count = (width + 3) / 4;
	uint by_count = (height + 3) / 4;

	char[64] px; // 16 texels RGBA, edge-replicated
	for (uint by = 0; by < by_count; by++)
	{
		for (uint bx = 0; bx < bx_count; bx++)
		{
			fetch_block(rgba, width, height, bx * 4, by * 4, &px);
			char* dst = &out[((sz)by * bx_count + bx) * bb];
			switch (fmt)
			{
				case BC1:
					encode_bc1_block(&px, dst);
				case BC3:
					encode_bc4_block(&px, 3, dst);      // alpha
					encode_bc1_block(&px, dst + 8);     // color
				case BC4:
					encode_bc4_block(&px, 0, dst);
				case BC5:
					encode_bc4_block(&px, 0, dst);
					encode_bc4_block(&px, 1, dst + 8);
			}
		}
	}
	return out;
}

<*
 Decode row-major 4x4 blocks back to tightly-packed RGBA8.
 blocks.len must equal encoded_size(fmt, width, height); block texels that
 fall outside width/height are clipped. Output per format:
 BC1 -> (r,g,b,255) in 4-color mode, punchthrough texels give (0,0,0,0);
 BC3 -> (r,g,b,a); BC4 -> (r,r,r,255); BC5 -> (r,g,0,255).
*>
fn char[]? decode(Allocator allocator, BcnFormat fmt, char[] blocks, uint width, uint height)
{
	if (width == 0 || height == 0) return INVALID_SIZE~;
	if (blocks.len != encoded_size(fmt, width, height)) return INVALID_INPUT~;

	char[] out = alloc::new_array(allocator, char, (sz)width * height * 4);
	sz bb = block_bytes(fmt);
	uint bx_count = (width + 3) / 4;
	uint by_count = (height + 3) / 4;

	char[64] px;
	for (uint by = 0; by < by_count; by++)
	{
		for (uint bx = 0; bx < bx_count; bx++)
		{
			char* src = &blocks[((sz)by * bx_count + bx) * bb];
			switch (fmt)
			{
				case BC1:
					decode_bc1_block(src, &px);
				case BC3:
					decode_bc1_block(src + 8, &px);
					decode_bc4_block(src, 3, &px);
				case BC4:
					fill_default(&px);
					decode_bc4_block(src, 0, &px);
					copy_r_to_gb(&px);
				case BC5:
					fill_default(&px);
					decode_bc4_block(src, 0, &px);
					decode_bc4_block(src + 8, 1, &px);
			}
			store_block(out, width, height, bx * 4, by * 4, &px);
		}
	}
	return out;
}

// ---------------------------------------------------------------------------
// Shared helpers
// ---------------------------------------------------------------------------

fn sz block_bytes(BcnFormat fmt) @private
{
	switch (fmt)
	{
		case BC1: return 8;
		case BC4: return 8;
		case BC3: return 16;
		case BC5: return 16;
	}
}

// Gather a 4x4 RGBA block at (x0,y0), replicating edge pixels when the
// block extends past the image.
fn void fetch_block(char[] rgba, uint width, uint height, uint x0, uint y0, char[64]* px) @private
{
	for (uint y = 0; y < 4; y++)
	{
		uint sy = x0y0_clamp(y0 + y, height);
		for (uint x = 0; x < 4; x++)
		{
			uint sx = x0y0_clamp(x0 + x, width);
			sz s = ((sz)sy * width + sx) * 4;
			sz d = (sz)(y * 4 + x) * 4;
			(*px)[d] = rgba[s];
			(*px)[d + 1] = rgba[s + 1];
			(*px)[d + 2] = rgba[s + 2];
			(*px)[d + 3] = rgba[s + 3];
		}
	}
}

fn uint x0y0_clamp(uint v, uint limit) @private
{
	return v < limit ? v : limit - 1;
}

// Scatter a decoded 4x4 block, clipping texels outside the image.
fn void store_block(char[] out, uint width, uint height, uint x0, uint y0, char[64]* px) @private
{
	for (uint y = 0; y < 4; y++)
	{
		if (y0 + y >= height) break;
		for (uint x = 0; x < 4; x++)
		{
			if (x0 + x >= width) break;
			sz d = ((sz)(y0 + y) * width + (sz)(x0 + x)) * 4;
			sz s = (sz)(y * 4 + x) * 4;
			out[d] = (*px)[s];
			out[d + 1] = (*px)[s + 1];
			out[d + 2] = (*px)[s + 2];
			out[d + 3] = (*px)[s + 3];
		}
	}
}

fn void fill_default(char[64]* px) @private
{
	for (uint i = 0; i < 16; i++)
	{
		(*px)[i * 4] = 0;
		(*px)[i * 4 + 1] = 0;
		(*px)[i * 4 + 2] = 0;
		(*px)[i * 4 + 3] = 255;
	}
}

fn void copy_r_to_gb(char[64]* px) @private
{
	for (uint i = 0; i < 16; i++)
	{
		(*px)[i * 4 + 1] = (*px)[i * 4];
		(*px)[i * 4 + 2] = (*px)[i * 4];
	}
}

// ---------------------------------------------------------------------------
// BC1 (color block, 8 bytes: u16 color0 LE, u16 color1 LE, 16 x 2-bit indices)
// ---------------------------------------------------------------------------

// 565 -> 888 by bit replication (matches basisu / D3D reference).
fn void expand565(uint c, uint* r, uint* g, uint* b) @private
{
	uint r5 = (c >> 11) & 31;
	uint g6 = (c >> 5) & 63;
	uint b5 = c & 31;
	*r = (r5 << 3) | (r5 >> 2);
	*g = (g6 << 2) | (g6 >> 4);
	*b = (b5 << 3) | (b5 >> 2);
}

// Round 8-bit channels to nearest 565 lattice point.
fn uint to565(uint r, uint g, uint b) @private
{
	uint r5 = (r * 31 + 128) / 255;
	uint g6 = (g * 63 + 128) / 255;
	uint b5 = (b * 31 + 128) / 255;
	return (r5 << 11) | (g6 << 5) | b5;
}

// Build the 4-entry palette for endpoints c0 > c1 (4-color mode),
// exactly as the decoder computes it.
fn void bc1_palette4(uint c0, uint c1, uint[4]* pr, uint[4]* pg, uint[4]* pb) @private
{
	uint r0; uint g0; uint b0;
	uint r1; uint g1; uint b1;
	expand565(c0, &r0, &g0, &b0);
	expand565(c1, &r1, &g1, &b1);
	(*pr)[0] = r0; (*pg)[0] = g0; (*pb)[0] = b0;
	(*pr)[1] = r1; (*pg)[1] = g1; (*pb)[1] = b1;
	(*pr)[2] = (r0 * 2 + r1) / 3; (*pg)[2] = (g0 * 2 + g1) / 3; (*pb)[2] = (b0 * 2 + b1) / 3;
	(*pr)[3] = (r0 + r1 * 2) / 3; (*pg)[3] = (g0 + g1 * 2) / 3; (*pb)[3] = (b0 + b1 * 2) / 3;
}

// Assign every texel to the nearest palette entry; returns indices.
fn void bc1_assign(char[64]* px, uint[4]* pr, uint[4]* pg, uint[4]* pb, char[16]* idx) @private
{
	for (uint i = 0; i < 16; i++)
	{
		int r = (*px)[i * 4];
		int g = (*px)[i * 4 + 1];
		int b = (*px)[i * 4 + 2];
		uint best = 0;
		int best_err = 0x7fffffff;
		for (uint k = 0; k < 4; k++)
		{
			int dr = r - (int)(*pr)[k];
			int dg = g - (int)(*pg)[k];
			int db = b - (int)(*pb)[k];
			int e = dr * dr + dg * dg + db * db;
			if (e < best_err)
			{
				best_err = e;
				best = k;
			}
		}
		(*idx)[i] = (char)best;
	}
}

// Least-squares endpoint refinement from a fixed index assignment
// (the stb_dxt / rygDXT approach). Palette entry k contributes weights
// (a,b) on (c0,c1): 0->(1,0), 1->(0,1), 2->(2/3,1/3), 3->(1/3,2/3).
// Returns false when the system is degenerate (all texels on one endpoint
// combination), in which case the endpoints are left untouched.
fn bool bc1_refine(char[64]* px, char[16]* idx, uint* c0, uint* c1) @private
{
	const double[4] WA = { 1.0, 0.0, 2.0 / 3.0, 1.0 / 3.0 };
	double ata = 0;
	double atb = 0;
	double btb = 0;
	double[3] ax;
	double[3] bx;
	for (uint i = 0; i < 16; i++)
	{
		double a = WA[(*idx)[i]];
		double b = 1.0 - a;
		ata += a * a;
		atb += a * b;
		btb += b * b;
		for (uint c = 0; c < 3; c++)
		{
			double v = (double)(*px)[i * 4 + c];
			ax[c] += a * v;
			bx[c] += b * v;
		}
	}
	double det = ata * btb - atb * atb;
	if (det < 1e-8 && det > -1e-8) return false;

	uint[3] e0;
	uint[3] e1;
	for (uint c = 0; c < 3; c++)
	{
		double v0 = (btb * ax[c] - atb * bx[c]) / det;
		double v1 = (ata * bx[c] - atb * ax[c]) / det;
		e0[c] = clamp255d(v0);
		e1[c] = clamp255d(v1);
	}
	*c0 = to565(e0[0], e0[1], e0[2]);
	*c1 = to565(e1[0], e1[1], e1[2]);
	return true;
}

fn uint clamp255d(double v) @private
{
	if (v <= 0) return 0;
	if (v >= 255) return 255;
	return (uint)(v + 0.5);
}

fn void encode_bc1_block(char[64]* px, char* dst) @private
{
	// RGB bounding box.
	uint[3] lo = { 255, 255, 255 };
	uint[3] hi = { 0, 0, 0 };
	for (uint i = 0; i < 16; i++)
	{
		for (uint c = 0; c < 3; c++)
		{
			uint v = (*px)[i * 4 + c];
			if (v < lo[c]) lo[c] = v;
			if (v > hi[c]) hi[c] = v;
		}
	}

	// Inset the box by 1/16 of its extent to reduce endpoint overshoot.
	uint[3] emax;
	uint[3] emin;
	for (uint c = 0; c < 3; c++)
	{
		uint inset = (hi[c] - lo[c]) / 16;
		emin[c] = lo[c] + inset;
		emax[c] = hi[c] - inset;
	}

	uint c0 = to565(emax[0], emax[1], emax[2]);
	uint c1 = to565(emin[0], emin[1], emin[2]);

	uint[4] pr; uint[4] pg; uint[4] pb;
	char[16] idx;

	// Initial assignment + 2 rounds of least-squares refinement.
	for (uint iter = 0;; iter++)
	{
		if (c0 == c1)
		{
			// Degenerate: any index in {0,1,2} decodes to the same color in
			// 3-color mode; use 0 everywhere (index 3 would be punchthrough).
			idx[..] = 0;
			break;
		}
		if (c0 < c1)
		{
			uint t = c0;
			c0 = c1;
			c1 = t;
		}
		bc1_palette4(c0, c1, &pr, &pg, &pb);
		bc1_assign(px, &pr, &pg, &pb, &idx);
		if (iter == 2) break;
		if (!bc1_refine(px, &idx, &c0, &c1)) break;
	}

	dst[0] = (char)(c0 & 0xFF);
	dst[1] = (char)(c0 >> 8);
	dst[2] = (char)(c1 & 0xFF);
	dst[3] = (char)(c1 >> 8);
	for (uint y = 0; y < 4; y++)
	{
		uint row = 0;
		for (uint x = 0; x < 4; x++)
		{
			row |= (uint)idx[y * 4 + x] << (x * 2);
		}
		dst[4 + y] = (char)row;
	}
}

// Decode one BC1 block into 16 RGBA texels. Handles both modes:
// c0 > c1 -> 4-color opaque; c0 <= c1 -> 3-color + punchthrough (0,0,0,0).
fn void decode_bc1_block(char* src, char[64]* px) @private
{
	uint c0 = (uint)src[0] | ((uint)src[1] << 8);
	uint c1 = (uint)src[2] | ((uint)src[3] << 8);

	uint r0; uint g0; uint b0;
	uint r1; uint g1; uint b1;
	expand565(c0, &r0, &g0, &b0);
	expand565(c1, &r1, &g1, &b1);

	char[4][4] pal; // [entry][rgba]
	pal[0] = { (char)r0, (char)g0, (char)b0, 255 };
	pal[1] = { (char)r1, (char)g1, (char)b1, 255 };
	if (c0 > c1)
	{
		pal[2] = { (char)((r0 * 2 + r1) / 3), (char)((g0 * 2 + g1) / 3), (char)((b0 * 2 + b1) / 3), 255 };
		pal[3] = { (char)((r0 + r1 * 2) / 3), (char)((g0 + g1 * 2) / 3), (char)((b0 + b1 * 2) / 3), 255 };
	}
	else
	{
		pal[2] = { (char)((r0 + r1) / 2), (char)((g0 + g1) / 2), (char)((b0 + b1) / 2), 255 };
		pal[3] = { 0, 0, 0, 0 };
	}

	for (uint y = 0; y < 4; y++)
	{
		uint row = src[4 + y];
		for (uint x = 0; x < 4; x++)
		{
			uint k = (row >> (x * 2)) & 3;
			sz d = (sz)(y * 4 + x) * 4;
			(*px)[d] = pal[k][0];
			(*px)[d + 1] = pal[k][1];
			(*px)[d + 2] = pal[k][2];
			(*px)[d + 3] = pal[k][3];
		}
	}
}

// ---------------------------------------------------------------------------
// BC4 (single-channel block, 8 bytes: e0, e1, 16 x 3-bit indices in 48 bits LE)
// Also used for the BC3 alpha block and both halves of BC5.
// ---------------------------------------------------------------------------

// Palette for both BC4 modes, matching basisu truncating arithmetic.
fn void bc4_palette(uint e0, uint e1, uint[8]* pal) @private
{
	(*pal)[0] = e0;
	(*pal)[1] = e1;
	if (e0 > e1)
	{
		for (uint n = 2; n < 8; n++)
		{
			(*pal)[n] = (e0 * (8 - n) + e1 * (n - 1)) / 7;
		}
	}
	else
	{
		for (uint n = 2; n < 6; n++)
		{
			(*pal)[n] = (e0 * (6 - n) + e1 * (n - 1)) / 5;
		}
		(*pal)[6] = 0;
		(*pal)[7] = 255;
	}
}

fn void bc4_assign(char[64]* px, uint channel, uint[8]* pal, char[16]* idx) @private
{
	for (uint i = 0; i < 16; i++)
	{
		int v = (*px)[i * 4 + channel];
		uint best = 0;
		int best_err = 0x7fffffff;
		for (uint k = 0; k < 8; k++)
		{
			int d = v - (int)(*pal)[k];
			int e = d * d;
			if (e < best_err)
			{
				best_err = e;
				best = k;
			}
		}
		(*idx)[i] = (char)best;
	}
}

// One least-squares refinement pass for the 8-value mode.
// Index k weights on (e0,e1): 0->(1,0), 1->(0,1), k->((8-k)/7, (k-1)/7).
fn bool bc4_refine(char[64]* px, uint channel, char[16]* idx, uint* e0, uint* e1) @private
{
	const double[8] WA = { 1.0, 0.0, 6.0 / 7.0, 5.0 / 7.0, 4.0 / 7.0, 3.0 / 7.0, 2.0 / 7.0, 1.0 / 7.0 };
	double ata = 0;
	double atb = 0;
	double btb = 0;
	double av = 0;
	double bv = 0;
	for (uint i = 0; i < 16; i++)
	{
		double a = WA[(*idx)[i]];
		double b = 1.0 - a;
		double v = (double)(*px)[i * 4 + channel];
		ata += a * a;
		atb += a * b;
		btb += b * b;
		av += a * v;
		bv += b * v;
	}
	double det = ata * btb - atb * atb;
	if (det < 1e-8 && det > -1e-8) return false;
	uint n0 = clamp255d((btb * av - atb * bv) / det);
	uint n1 = clamp255d((ata * bv - atb * av) / det);
	if (n0 < n1)
	{
		uint t = n0;
		n0 = n1;
		n1 = t;
	}
	if (n0 == n1) return false;
	*e0 = n0;
	*e1 = n1;
	return true;
}

fn void encode_bc4_block(char[64]* px, uint channel, char* dst) @private
{
	uint lo = 255;
	uint hi = 0;
	for (uint i = 0; i < 16; i++)
	{
		uint v = (*px)[i * 4 + channel];
		if (v < lo) lo = v;
		if (v > hi) hi = v;
	}

	uint e0 = hi;
	uint e1 = lo;
	uint[8] pal;
	char[16] idx;

	if (e0 == e1)
	{
		// Flat block: equal endpoints select 6-value mode, entry 0 == value.
		idx[..] = 0;
	}
	else
	{
		// e0 > e1 -> 8-interpolant mode.
		bc4_palette(e0, e1, &pal);
		bc4_assign(px, channel, &pal, &idx);
		// One least-squares refinement pass, then re-assign.
		if (bc4_refine(px, channel, &idx, &e0, &e1))
		{
			bc4_palette(e0, e1, &pal);
			bc4_assign(px, channel, &pal, &idx);
		}
	}

	dst[0] = (char)e0;
	dst[1] = (char)e1;
	ulong bits = 0;
	for (uint i = 0; i < 16; i++)
	{
		bits |= (ulong)idx[i] << (i * 3);
	}
	for (uint i = 0; i < 6; i++)
	{
		dst[2 + i] = (char)((bits >> (i * 8)) & 0xFF);
	}
}

// Decode one BC4 block into the given channel of 16 RGBA texels.
// Handles both the 8-value (e0 > e1) and 6-value + 0/255 (e0 <= e1) modes.
fn void decode_bc4_block(char* src, uint channel, char[64]* px) @private
{
	uint[8] pal;
	bc4_palette(src[0], src[1], &pal);

	ulong bits = 0;
	for (uint i = 0; i < 6; i++)
	{
		bits |= (ulong)src[2 + i] << (i * 8);
	}
	for (uint i = 0; i < 16; i++)
	{
		uint k = (uint)((bits >> (i * 3)) & 7);
		(*px)[i * 4 + channel] = (char)pal[k];
	}
}
