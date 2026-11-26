<*
 ETC2 and EAC blocks decoded to RGBA8, as the Khronos Data Format spec defines
 them: how `ktx extract`, a viewer, or a GPU without ETC2 reads such a file.
 ktx::etc1s_etc2 writes them.

 A block is one big-endian 64-bit word (two for RGBA and RG11). Texel (x, y)
 is number x * 4 + y in it: indices run down the columns.
*>
module ktx::etc2;
import ktx::parallel;

excuse INVALID_SIZE;

<* An ETC2/EAC block layout, with its bytes per 4x4 block. *>
enum Layout : char (uint block_bytes)
{
	RGB { 8 },
	// One index value marks a transparent texel unless the block is opaque.
	RGB_A1 { 8 },
	// EAC A8, then ETC2 RGB.
	RGBA { 16 },
	R11 { 8 },
	// Red block, then green.
	RG11 { 16 },
}

<* Intensity modifiers per table codeword, by pixel index as stored: (msb << 1) | lsb. *>
const int[4][8] INTENSITY = {
	{ 2, 8, -2, -8 }, { 5, 17, -5, -17 }, { 9, 29, -9, -29 }, { 13, 42, -13, -42 },
	{ 18, 60, -18, -60 }, { 24, 80, -24, -80 }, { 33, 106, -33, -106 }, { 47, 183, -47, -183 },
};

<* The T and H modes' distance between paint colours. *>
const int[8] DISTANCE = { 3, 6, 11, 16, 23, 32, 41, 64 };

<* EAC modifiers per table, by 3-bit index. *>
const int[8][16] EAC_MODIFIERS = {
	{ -3, -6, -9, -15, 2, 5, 8, 14 },
	{ -3, -7, -10, -13, 2, 6, 9, 12 },
	{ -2, -5, -8, -13, 1, 4, 7, 12 },
	{ -2, -4, -6, -13, 1, 3, 5, 12 },
	{ -3, -6, -8, -12, 2, 5, 7, 11 },
	{ -3, -7, -9, -11, 2, 6, 8, 10 },
	{ -4, -7, -8, -11, 3, 6, 7, 10 },
	{ -3, -5, -8, -11, 2, 4, 7, 10 },
	{ -2, -6, -8, -10, 1, 5, 7, 9 },
	{ -2, -5, -8, -10, 1, 4, 7, 9 },
	{ -2, -4, -8, -10, 1, 3, 7, 9 },
	{ -2, -5, -7, -10, 1, 4, 6, 9 },
	{ -3, -4, -7, -10, 2, 3, 6, 9 },
	{ -1, -2, -3, -10, 0, 1, 2, 9 },
	{ -4, -6, -8, -9, 3, 5, 7, 8 },
	{ -3, -5, -7, -9, 2, 4, 6, 8 },
};

fn ulong word(char[] b) @local
{
	ulong w;
	for (uint i = 0; i < 8; i++) w = w << 8 | b[i];
	return w;
}

<* `n` bits of `w` starting at bit `lo`. *>
fn int field(ulong w, uint lo, uint n) @local @inline => (int)((w >> lo) & ((1ul << n) - 1));

fn char clamp255(int v) @local @inline => (char)(v < 0 ? 0 : (v > 255 ? 255 : v));

fn int expand4(int v) @local @inline => v << 4 | v;
fn int expand5(int v) @local @inline => v << 3 | v >> 2;
fn int expand6(int v) @local @inline => v << 2 | v >> 4;
fn int expand7(int v) @local @inline => v << 1 | v >> 6;

<* The 2-bit pixel index of texel (x, y): msb plane at bit 16, lsb plane at bit 0. *>
fn int pixel_index(ulong w, uint x, uint y) @local @inline
{
	uint i = x * 4 + y;
	return field(w, 16 + i, 1) << 1 | field(w, i, 1);
}

fn void put(char[64]* px, uint x, uint y, int r, int g, int b, char a) @local @inline
{
	uint at = (y * 4 + x) * 4;
	(*px)[at] = clamp255(r);
	(*px)[at + 1] = clamp255(g);
	(*px)[at + 2] = clamp255(b);
	(*px)[at + 3] = a;
}

<* T and H blocks: four paint colours picked per texel; with `punch`, index 2 is transparent black. *>
fn void decode_paint(ulong w, int[3][4] paint, bool punch, char[64]* px) @local
{
	for (uint y = 0; y < 4; y++)
	{
		for (uint x = 0; x < 4; x++)
		{
			int i = pixel_index(w, x, y);
			if (punch && i == 2)
			{
				put(px, x, y, 0, 0, 0, 0);
				continue;
			}
			put(px, x, y, paint[i][0], paint[i][1], paint[i][2], 255);
		}
	}
}

fn void decode_t(ulong w, bool punch, char[64]* px) @local
{
	int[3] c1 = { field(w, 59, 2) << 2 | field(w, 56, 2), field(w, 52, 4), field(w, 48, 4) };
	int[3] c2 = { field(w, 44, 4), field(w, 40, 4), field(w, 36, 4) };
	int d = DISTANCE[field(w, 34, 2) << 1 | field(w, 32, 1)];
	int[3][4] paint;
	for (uint c = 0; c < 3; c++)
	{
		paint[0][c] = expand4(c1[c]);
		paint[1][c] = expand4(c2[c]) + d;
		paint[2][c] = expand4(c2[c]);
		paint[3][c] = expand4(c2[c]) - d;
	}
	decode_paint(w, paint, punch, px);
}

fn void decode_h(ulong w, bool punch, char[64]* px) @local
{
	int[3] c1 = { field(w, 59, 4), field(w, 56, 3) << 1 | field(w, 52, 1), field(w, 51, 1) << 3 | field(w, 47, 3) };
	int[3] c2 = { field(w, 43, 4), field(w, 39, 4), field(w, 35, 4) };
	// The distance's low bit is which colour is the larger, as 12-bit RGB444.
	int larger = (c1[0] << 8 | c1[1] << 4 | c1[2]) >= (c2[0] << 8 | c2[1] << 4 | c2[2]) ? 1 : 0;
	int d = DISTANCE[field(w, 34, 1) << 2 | field(w, 32, 1) << 1 | larger];
	int[3][4] paint;
	for (uint c = 0; c < 3; c++)
	{
		paint[0][c] = expand4(c1[c]) + d;
		paint[1][c] = expand4(c1[c]) - d;
		paint[2][c] = expand4(c2[c]) + d;
		paint[3][c] = expand4(c2[c]) - d;
	}
	decode_paint(w, paint, punch, px);
}

fn void decode_planar(ulong w, char[64]* px) @local
{
	int[3] o = {
		expand6(field(w, 57, 6)),
		expand7(field(w, 56, 1) << 6 | field(w, 49, 6)),
		expand6(field(w, 48, 1) << 5 | field(w, 43, 2) << 3 | field(w, 39, 3)),
	};
	int[3] h = { expand6(field(w, 34, 5) << 1 | field(w, 32, 1)), expand7(field(w, 25, 7)), expand6(field(w, 19, 6)) };
	int[3] v = { expand6(field(w, 13, 6)), expand7(field(w, 6, 7)), expand6(field(w, 0, 6)) };
	for (uint y = 0; y < 4; y++)
	{
		for (uint x = 0; x < 4; x++)
		{
			int[3] c;
			for (uint k = 0; k < 3; k++)
			{
				c[k] = ((int)x * (h[k] - o[k]) + (int)y * (v[k] - o[k]) + 4 * o[k] + 2) >> 2;
			}
			put(px, x, y, c[0], c[1], c[2], 255);
		}
	}
}

<*
 An ETC2 colour block. `punch` reads bit 33 as the opaque flag: the individual
 mode is gone, and a block that is not opaque has transparent texels.
*>
fn void decode_colour(ulong w, bool punch, char[64]* px) @local
{
	bool diff = field(w, 33, 1) != 0;
	bool transparent = punch && !diff;
	int[3] c1;
	int[3] c2;
	if (!punch && !diff)
	{
		for (uint c = 0; c < 3; c++)
		{
			c1[c] = expand4(field(w, 60 - 8 * c, 4));
			c2[c] = expand4(field(w, 56 - 8 * c, 4));
		}
	}
	else
	{
		// A second colour outside 0..31 selects another mode: red T, green H, blue planar.
		int[3] sum;
		for (uint c = 0; c < 3; c++)
		{
			int base = field(w, 59 - 8 * c, 5);
			int delta = field(w, 56 - 8 * c, 3);
			sum[c] = base + (delta >= 4 ? delta - 8 : delta);
			c1[c] = expand5(base);
			c2[c] = expand5(sum[c] & 31);
		}
		if (sum[0] < 0 || sum[0] > 31)
		{
			decode_t(w, transparent, px);
			return;
		}
		if (sum[1] < 0 || sum[1] > 31)
		{
			decode_h(w, transparent, px);
			return;
		}
		if (sum[2] < 0 || sum[2] > 31)
		{
			decode_planar(w, px);
			return;
		}
	}

	bool flip = field(w, 32, 1) != 0;
	int[2] table = { field(w, 37, 3), field(w, 34, 3) };
	for (uint y = 0; y < 4; y++)
	{
		for (uint x = 0; x < 4; x++)
		{
			int i = pixel_index(w, x, y);
			if (transparent && i == 2)
			{
				put(px, x, y, 0, 0, 0, 0);
				continue;
			}
			bool second = flip ? y >= 2 : x >= 2;
			// A non-opaque block drops its small modifiers: index 0 adds nothing.
			int m = transparent && i == 0 ? 0 : INTENSITY[table[second ? 1 : 0]][i];
			int[3] base = second ? c2 : c1;
			put(px, x, y, base[0] + m, base[1] + m, base[2] + m, 255);
		}
	}
}

<*
 One ETC2 RGB block as 16 RGBA texels, row by row, alpha 255.

 @param [in] block : "The 8-byte block"
 @param [out] px : "Texel (x, y) at (y * 4 + x) * 4"
 @require block.len >= 8 : "Block too short"
*>
fn void decode_rgb_block(char[] block, char[64]* px) => decode_colour(word(block), false, px);

<*
 One ETC2 RGB block with punch-through alpha: a transparent texel is (0, 0, 0, 0).

 @param [in] block : "The 8-byte block"
 @param [out] px : "Texel (x, y) at (y * 4 + x) * 4"
 @require block.len >= 8 : "Block too short"
*>
fn void decode_rgb_a1_block(char[] block, char[64]* px) => decode_colour(word(block), true, px);

<*
 One EAC A8 block into the alpha bytes of 16 RGBA texels; the colour bytes are left alone.

 @param [in] block : "The 8-byte block"
 @param [inout] px : "Texel (x, y) at (y * 4 + x) * 4"
 @require block.len >= 8 : "Block too short"
*>
fn void decode_alpha_block(char[] block, char[64]* px)
{
	ulong w = word(block);
	int base = field(w, 56, 8);
	int mul = field(w, 52, 4);
	int[8] mods = EAC_MODIFIERS[field(w, 48, 4)];
	for (uint i = 0; i < 16; i++)
	{
		(*px)[((i % 4) * 4 + i / 4) * 4 + 3] = clamp255(base + mods[field(w, 45 - 3 * i, 3)] * mul);
	}
}

<* The 11-bit values of an EAC R11 block; a zero multiplier steps by one eighth. *>
fn int[16] decode_eac11(char[] block, bool signed) @local
{
	ulong w = word(block);
	int base = field(w, 56, 8);
	if (signed) base = base >= 128 ? max(base - 256, -127) : base;
	int mul = field(w, 52, 4);
	int[8] mods = EAC_MODIFIERS[field(w, 48, 4)];
	int lo = signed ? -1023 : 0;
	int hi = signed ? 1023 : 2047;
	int[16] out;
	for (uint i = 0; i < 16; i++)
	{
		int m = mods[field(w, 45 - 3 * i, 3)];
		int v = base * 8 + (signed ? 0 : 4) + (mul ? m * mul * 8 : m);
		out[(i % 4) * 4 + i / 4] = v < lo ? lo : (v > hi ? hi : v);
	}
	return out;
}

<*
 The unsigned 11-bit values (0..2047) of an EAC R11 block, row by row.

 @param [in] block : "The 8-byte block"
 @require block.len >= 8 : "Block too short"
 @return "Texel (x, y) at y * 4 + x"
*>
fn int[16] decode_r11_block(char[] block) => decode_eac11(block, false);

<*
 The signed 11-bit values (-1023..1023) of an EAC signed R11 block, row by row.

 @param [in] block : "The 8-byte block"
 @require block.len >= 8 : "Block too short"
 @return "Texel (x, y) at y * 4 + x"
*>
fn int[16] decode_signed_r11_block(char[] block) => decode_eac11(block, true);

<* One block of any layout as 16 RGBA texels. R11 gives (r, r, r, 255) and RG11 (r, g, 0, 255), as BC4 and BC5 do. *>
fn void decode_block(Layout layout, char[] block, char[64]* px) @local
{
	switch (layout)
	{
		case RGB:
			decode_rgb_block(block, px);
		case RGB_A1:
			decode_rgb_a1_block(block, px);
		case RGBA:
			decode_rgb_block(block[8:8], px);
			decode_alpha_block(block[:8], px);
		case R11:
			int[16] r = decode_r11_block(block);
			for (uint i = 0; i < 16; i++)
			{
				char v = (char)(r[i] >> 3);
				(*px)[i * 4] = v;
				(*px)[i * 4 + 1] = v;
				(*px)[i * 4 + 2] = v;
				(*px)[i * 4 + 3] = 255;
			}
		case RG11:
			int[16] r = decode_r11_block(block[:8]);
			int[16] g = decode_r11_block(block[8:8]);
			for (uint i = 0; i < 16; i++)
			{
				(*px)[i * 4] = (char)(r[i] >> 3);
				(*px)[i * 4 + 1] = (char)(g[i] >> 3);
				(*px)[i * 4 + 2] = 0;
				(*px)[i * 4 + 3] = 255;
			}
	}
}

struct DecodeJob @local
{
	char[] blocks;
	char[] out;
	Layout layout;
	uint width;
	uint height;
	uint bw;
}

fn void decode_row(void* ctx, usz by) @local
{
	DecodeJob* j = (DecodeJob*)ctx;
	uint bytes = j.layout.block_bytes;
	char[64] px;
	for (uint bx = 0; bx < j.bw; bx++)
	{
		decode_block(j.layout, j.blocks[((sz)by * j.bw + bx) * bytes : bytes], &px);
		for (uint y = 0; y < 4 && by * 4 + y < j.height; y++)
		{
			uint row_texels = min(4u, j.width - bx * 4);
			sz at = ((sz)(by * 4 + y) * j.width + (sz)bx * 4) * 4;
			j.out[at : row_texels * 4] = px[y * 16 : row_texels * 4];
		}
	}
}

const usz MIN_BLOCKS_PER_THREAD @local = 4096;

<*
 Decode an image of row-major blocks to tightly packed RGBA8, cropping the
 blocks at the right and bottom edges.

 @param [&inout] allocator : "Where the pixels are allocated"
 @param layout : "The blocks' layout"
 @param [in] blocks : "ceil(width / 4) * ceil(height / 4) blocks"
 @param threads : "Block rows' thread count: 0 decides from the job's size, 1 runs inline"
 @return "width * height * 4 bytes"
 @return? INVALID_SIZE
*>
fn char[]? decode(Allocator allocator, Layout layout, char[] blocks, uint width, uint height, uint threads = 0)
{
	uint bw = (width + 3) / 4;
	uint bh = (height + 3) / 4;
	if (!bw || !bh || blocks.len != (sz)bw * bh * layout.block_bytes) return INVALID_SIZE~;
	char[] out = alloc::new_array(allocator, char, (sz)width * height * 4);
	DecodeJob job = { .blocks = blocks, .out = out, .layout = layout, .width = width, .height = height, .bw = bw };
	parallel::run(bh, &job, &decode_row, parallel::shares((usz)bw * bh, MIN_BLOCKS_PER_THREAD, threads));
	return out;
}
