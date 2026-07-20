// UASTC LDR 4x4 block decoder in pure C3 (docs/basis-rewrite.md phase 1).
//
// Port of basis_universal's reference unpack_uastc (basisu_transcoder.cpp) —
// bit-exact against it by construction and verified against golden RGBA32
// dumps in test/uastc_test.c3. A UASTC block is 128 bits: a variable-length
// mode code, transcode hint bits (skipped here), optional partition-pattern /
// dual-plane fields, BISE-packed endpoints, then plain-bit weights filling the
// block to bit 128.
module ktx::uastc;
import ktx::bits, ktx::etc1s, ktx::parallel;

faultdef INVALID_BLOCK, INVALID_SIZE;

const uint MODE_SOLID = 8;
const uint TOTAL_MODES = 19;

// Mode from the low 7 bits of the first byte (g_uastc_huff_modes); 19 marks
// codes reserved for future expansion -> invalid block.
const char[128] HUFF_MODES = {
	11,0,10,3,11,15,12,7,11,18,10,5,11,14,12,9,11,0,10,4,11,16,12,8,11,18,10,6,11,2,12,13,
	11,0,10,3,11,17,12,7,11,18,10,5,11,14,12,9,11,0,10,4,11,1,12,8,11,18,10,6,11,2,12,13,
	11,0,10,3,11,19,12,7,11,18,10,5,11,14,12,9,11,0,10,4,11,16,12,8,11,18,10,6,11,2,12,13,
	11,0,10,3,11,17,12,7,11,18,10,5,11,14,12,9,11,0,10,4,11,1,12,8,11,18,10,6,11,2,12,13,
};

// Huffman code length of each mode code (g_uastc_mode_huff_codes[.][1]).
const char[TOTAL_MODES + 1] MODE_CODE_SIZES = { 4, 6, 5, 5, 5, 5, 5, 5, 5, 5, 3, 2, 3, 5, 5, 7, 6, 6, 4, 7 };

// Per-mode properties (modes 0..18; mode 8 entries unused).
const char[TOTAL_MODES] MODE_WEIGHT_BITS     = { 4, 2, 3, 2, 2, 3, 2, 2,  0,  2, 4, 2, 3, 1, 2,  4, 2, 2,  5 };
const char[TOTAL_MODES] MODE_ENDPOINT_RANGES = { 19, 20, 8, 7, 12, 20, 18, 12,  0,  8, 13, 13, 19, 20, 20,  20, 20, 20,  11 };
const char[TOTAL_MODES] MODE_SUBSETS         = { 1, 1, 2, 3, 2, 1, 1, 2,  0,  2, 1, 1, 1, 1, 1,  1, 2, 1,  1 };
const char[TOTAL_MODES] MODE_PLANES          = { 1, 1, 1, 1, 1, 1, 2, 1,  0,  1, 1, 2, 1, 2, 1,  1, 1, 2,  1 };
const char[TOTAL_MODES] MODE_COMPS           = { 3, 3, 3, 3, 3, 3, 3, 3,  4,  4, 4, 4, 4, 4, 4,  2, 2, 2,  3 };
const char[TOTAL_MODES] MODE_HINT_BITS       = { 15, 15, 15, 15, 15, 15, 15, 15,  0,  23, 17, 17, 17, 23, 23,  23, 23, 23,  15 };

// BISE ranges: bits, trits, quints (g_astc_bise_range_table).
const char[3][21] BISE_RANGE = {
	{ 1, 0, 0 }, { 0, 1, 0 }, { 2, 0, 0 }, { 0, 0, 1 },
	{ 1, 1, 0 }, { 3, 0, 0 }, { 1, 0, 1 }, { 2, 1, 0 },
	{ 4, 0, 0 }, { 2, 0, 1 }, { 3, 1, 0 }, { 5, 0, 0 },
	{ 3, 0, 1 }, { 4, 1, 0 }, { 6, 0, 0 }, { 4, 0, 1 },
	{ 5, 1, 0 }, { 7, 0, 0 }, { 5, 0, 1 }, { 6, 1, 0 },
	{ 8, 0, 0 },
};

// ASTC endpoint unquantization parameters for trit/quint ranges: the bit-swizzle
// pattern B (per the ASTC spec's unquantization table) and multiplier C
// (g_astc_endpoint_unquant_params). '0' in the pattern means a zero bit;
// 'a'..'f' pick bit 0..5 of the packed bits.
const String[21] UNQUANT_B = {
	"", "", "", "",
	"000000000", "", "000000000", "b000b0bb0",
	"", "b0000bb00", "cb000cbcb", "",
	"cb0000cbc", "dcb000dcb", "", "dcb0000dc",
	"edcb000ed", "", "edcb0000e", "fedcb000f",
	"",
};
const char[21] UNQUANT_C = { 0, 0, 0, 0, 204, 0, 113, 93, 0, 54, 44, 0, 26, 22, 0, 13, 11, 0, 6, 5, 0 };

// Weight unquantization tables to 0..64, indexed by weight bit count
// (g_bc7_weights1/2/3, g_astc_weights4/5).
const char[2] WEIGHTS1 = { 0, 64 };
const char[4] WEIGHTS2 = { 0, 21, 43, 64 };
const char[8] WEIGHTS3 = { 0, 9, 18, 27, 37, 46, 55, 64 };
const char[16] WEIGHTS4 = { 0, 4, 8, 12, 17, 21, 25, 29, 35, 39, 43, 47, 52, 56, 60, 64 };
const char[32] WEIGHTS5 = {
	0, 2, 4, 6, 8, 10, 12, 14, 16, 18, 20, 22, 24, 26, 28, 30,
	34, 36, 38, 40, 42, 44, 46, 48, 50, 52, 54, 56, 58, 60, 62, 64,
};

// 2-subset partition patterns shared between ASTC and BC7 (30 x 16 texels)
// and the first texel of each subset (anchors).
const uint TOTAL_PATTERNS2 = 30;
const char[TOTAL_PATTERNS2 * 16] PATTERNS2 = {
	0,0,1,1,0,0,1,1,0,0,1,1,0,0,1,1,  0,0,0,1,0,0,0,1,0,0,0,1,0,0,0,1,
	1,0,0,0,1,0,0,0,1,0,0,0,1,0,0,0,  0,0,0,1,0,0,1,1,0,0,1,1,0,1,1,1,
	1,1,1,1,1,1,1,0,1,1,1,0,1,1,0,0,  0,0,1,1,0,1,1,1,0,1,1,1,1,1,1,1,
	1,1,1,0,1,1,0,0,1,0,0,0,0,0,0,0,  1,1,1,1,1,1,1,0,1,1,0,0,1,0,0,0,
	0,0,0,0,0,0,0,0,0,0,0,1,0,0,1,1,  1,1,0,0,1,0,0,0,0,0,0,0,0,0,0,0,
	0,0,0,0,0,0,0,1,0,1,1,1,1,1,1,1,  1,1,1,1,1,1,1,1,1,1,1,0,1,0,0,0,
	1,1,1,0,1,0,0,0,0,0,0,0,0,0,0,0,  1,1,1,1,1,1,1,1,0,0,0,0,0,0,0,0,
	0,0,0,0,1,1,1,1,1,1,1,1,1,1,1,1,  1,1,1,1,1,1,1,1,1,1,1,1,0,0,0,0,
	1,0,0,0,1,1,1,0,1,1,1,1,1,1,1,1,  1,1,1,1,1,1,1,1,0,1,1,1,0,0,0,1,
	0,1,1,1,0,0,1,1,0,0,0,1,0,0,0,0,  0,0,1,1,0,0,0,1,0,0,0,0,0,0,0,0,
	0,0,0,0,1,0,0,0,1,1,0,0,1,1,1,0,  1,1,1,1,1,1,1,1,0,1,1,1,0,0,1,1,
	1,0,0,0,1,1,0,0,1,1,0,0,1,1,1,0,  0,0,1,1,0,0,0,1,0,0,0,1,0,0,0,0,
	1,1,1,1,0,1,1,1,0,1,1,1,0,0,1,1,  0,1,1,0,0,1,1,0,0,1,1,0,0,1,1,0,
	1,1,1,1,0,0,0,0,0,0,0,0,1,1,1,1,  1,0,1,0,1,0,1,0,1,0,1,0,1,0,1,0,
	1,1,1,1,0,0,0,0,1,1,1,1,0,0,0,0,  1,0,0,1,0,0,1,1,0,1,1,0,1,1,0,0,
};
const char[TOTAL_PATTERNS2 * 2] ANCHORS2 = {
	0,2,  0,3,  1,0,  0,3,  7,0,  0,2,  3,0,  7,0,
	0,11, 2,0,  0,7,  11,0, 3,0,  8,0,  0,4,  12,0,
	1,0,  8,0,  0,1,  0,2,  0,4,  8,0,  1,0,  0,2,
	4,0,  0,1,  4,0,  1,0,  4,0,  1,0,
};

// 3-subset patterns (11 x 16) + anchors.
const uint TOTAL_PATTERNS3 = 11;
const char[TOTAL_PATTERNS3 * 16] PATTERNS3 = {
	0,0,0,0,0,0,0,0,1,1,2,2,1,1,2,2,  1,1,1,1,1,1,1,1,0,0,0,0,2,2,2,2,
	1,1,1,1,0,0,0,0,0,0,0,0,2,2,2,2,  1,1,1,1,2,2,2,2,0,0,0,0,0,0,0,0,
	1,1,2,0,1,1,2,0,1,1,2,0,1,1,2,0,  0,1,1,2,0,1,1,2,0,1,1,2,0,1,1,2,
	0,2,1,1,0,2,1,1,0,2,1,1,0,2,1,1,  2,0,0,0,2,0,0,0,2,1,1,1,2,1,1,1,
	2,0,1,2,2,0,1,2,2,0,1,2,2,0,1,2,  1,1,1,1,0,0,0,0,2,2,2,2,1,1,1,1,
	0,0,2,2,0,0,1,1,0,0,1,1,0,0,2,2,
};
const char[TOTAL_PATTERNS3 * 3] ANCHORS3 = {
	0,8,10,  8,0,12,  4,0,12,  8,0,4,  3,0,2,  0,1,3,  0,2,1,  1,9,0,  1,2,0,  4,0,8,  0,6,2,
};

// Mode 7's 2-subset patterns, common between BC7 3-subset and ASTC 2-subset
// (19 x 16) + anchors.
const uint TOTAL_PATTERNS2_3 = 19;
const char[TOTAL_PATTERNS2_3 * 16] PATTERNS2_3 = {
	0,0,0,0,1,1,1,1,0,0,0,0,0,0,0,0,  0,0,1,0,0,0,1,0,0,0,1,0,0,0,1,0,
	1,1,0,0,1,1,0,0,1,0,0,0,0,0,0,0,  0,0,0,0,0,0,0,1,0,0,1,1,0,0,1,1,
	1,1,1,1,1,1,1,1,0,0,0,0,1,1,1,1,  0,1,0,0,0,1,0,0,0,1,0,0,0,1,0,0,
	0,0,0,1,0,0,1,1,1,1,1,1,1,1,1,1,  0,1,1,1,0,0,1,1,0,0,1,1,0,0,1,1,
	1,1,0,0,0,0,0,0,0,0,1,1,1,1,0,0,  0,1,1,1,0,1,1,1,0,0,0,0,0,0,0,0,
	0,0,0,0,0,0,0,0,1,1,1,0,1,1,1,0,  1,1,0,0,0,0,0,0,0,0,0,0,1,1,0,0,
	0,1,1,1,0,0,1,1,0,0,0,0,0,0,0,0,  0,0,0,0,0,0,0,1,1,1,1,1,1,1,1,1,
	1,1,1,1,1,1,1,1,1,1,1,1,0,1,1,0,  1,1,0,0,1,1,0,0,1,1,0,0,1,0,0,0,
	1,1,1,1,1,1,1,1,1,0,0,0,1,0,0,0,  0,0,1,1,0,1,1,0,1,1,0,0,1,0,0,0,
	1,1,1,1,0,1,1,1,0,0,0,0,0,0,0,0,
};
const char[TOTAL_PATTERNS2_3 * 2] ANCHORS2_3 = {
	0,4,  0,2,  2,0,  0,7,  8,0,  0,1,  0,3,  0,1,  2,0,  0,1,
	0,8,  2,0,  0,1,  0,7,  12,0, 2,0,  9,0,  0,2,  4,0,
};

<*
 Unquantize a BISE-packed ASTC endpoint value to 0..255. `packed` is the raw
 bits in the low bit positions with the trit/quint digit above them, exactly
 as decode_block stores it (basisu unquant_astc_endpoint_val).
*>
fn uint unquant_endpoint(uint packed, uint range) @local
{
	uint nbits = BISE_RANGE[range][0];
	bool trits = BISE_RANGE[range][1] != 0;
	bool quints = BISE_RANGE[range][2] != 0;

	if (!trits && !quints)
	{
		// Plain bits: replicate to 8.
		uint val;
		uint bits_left = 8;
		while (bits_left > 0)
		{
			uint v = packed;
			uint n = min(bits_left, nbits);
			if (n < nbits) v >>= nbits - n;
			val |= v << (bits_left - n);
			bits_left -= n;
		}
		return val;
	}

	uint pb = packed & ((1u << nbits) - 1);
	uint d = packed >> nbits;   // trit (0..2) or quint (0..4) digit
	uint a = (pb & 1) ? 511 : 0;
	uint c = UNQUANT_C[range];
	String bstr = UNQUANT_B[range];

	uint b;
	for (uint i = 0; i < 9; i++)
	{
		b <<= 1;
		char ch = bstr[i];
		if (ch != '0') b |= (pb >> (ch - 'a')) & 1;
	}

	uint val = d * c + b;
	val ^= a;
	return (a & 0x80) | (val >> 2);
}

<* ASTC weighted interpolation of two 8-bit endpoints, weight 0..64. *>
fn char interpolate(uint l, uint h, uint w, bool srgb) @local
{
	if (srgb)
	{
		l = (l << 8) | 0x80;
		h = (h << 8) | 0x80;
	}
	else
	{
		l = (l << 8) | l;
		h = (h << 8) | h;
	}
	uint k = (l * (64 - w) + h * w + 32) >> 6;
	return (char)(k >> 8);
}

fn char weight_scale(uint index, uint weight_bits) @local
{
	switch (weight_bits)
	{
		case 1: return WEIGHTS1[index];
		case 2: return WEIGHTS2[index];
		case 3: return WEIGHTS3[index];
		case 4: return WEIGHTS4[index];
		default: return WEIGHTS5[index];
	}
}

<*
 Decode one 16-byte UASTC block into 16 RGBA8 pixels (row-major 4x4, 64
 bytes). `srgb` selects the interpolation rounding basisu uses for sRGB
 targets; RGBA32 transcodes use false.
*>
fn void? decode_block(char[] block, char[] out, bool srgb = false)
{
	assert(block.len == 16 && out.len == 64);
	bits::Reader r = bits::reader(block);

	uint mode = HUFF_MODES[block[0] & 127];
	if (mode >= TOTAL_MODES) return INVALID_BLOCK~;
	r.skip(MODE_CODE_SIZES[mode]);

	if (mode == MODE_SOLID)
	{
		char cr = (char)r.read(8);
		char cg = (char)r.read(8);
		char cb = (char)r.read(8);
		char ca = (char)r.read(8);
		for (uint i = 0; i < 16; i++)
		{
			out[i * 4] = cr;
			out[i * 4 + 1] = cg;
			out[i * 4 + 2] = cb;
			out[i * 4 + 3] = ca;
		}
		return;
	}

	r.skip(MODE_HINT_BITS[mode]);

	// Partition pattern index for multi-subset modes.
	uint subsets = MODE_SUBSETS[mode];
	uint common_pattern;
	switch (mode)
	{
		case 2:
		case 4:
		case 7:
		case 9:
		case 16:
			common_pattern = r.read(5);
		case 3:
			common_pattern = r.read(4);
		default:
			break;
	}
	switch (mode)
	{
		case 2:
		case 4:
		case 9:
		case 16:
			if (common_pattern >= TOTAL_PATTERNS2) return INVALID_BLOCK~;
		case 3:
			if (common_pattern >= TOTAL_PATTERNS3) return INVALID_BLOCK~;
		case 7:
			if (common_pattern >= TOTAL_PATTERNS2_3) return INVALID_BLOCK~;
		default:
			break;
	}

	// Dual-plane modes: which component the second weight plane drives.
	uint planes = MODE_PLANES[mode];
	int ccs = -1;
	switch (mode)
	{
		case 6:
		case 11:
		case 13:
			ccs = (int)r.read(2);
		case 17:
			ccs = 3;
		default:
			break;
	}

	// --- endpoints: BISE-packed values, trit/quint digits sent in bundles ---
	uint comps = MODE_COMPS[mode];
	uint endpoint_range = MODE_ENDPOINT_RANGES[mode];
	uint total_values = comps * 2 * subsets;
	uint ep_bits = BISE_RANGE[endpoint_range][0];
	bool ep_trits = BISE_RANGE[endpoint_range][1] != 0;
	bool ep_quints = BISE_RANGE[endpoint_range][2] != 0;

	uint total_tqs;
	uint bundle_size;
	uint mul;
	if (ep_trits)
	{
		total_tqs = (total_values + 4) / 5;
		bundle_size = 5;
		mul = 3;
	}
	else if (ep_quints)
	{
		total_tqs = (total_values + 2) / 3;
		bundle_size = 3;
		mul = 5;
	}

	uint[8] tq_values;
	for (uint i = 0; i < total_tqs; i++)
	{
		uint num_bits = ep_trits ? 8 : 7;
		if (i == total_tqs - 1)
		{
			// The last bundle only carries the digits actually used.
			uint num_remaining = total_values - (total_tqs - 1) * bundle_size;
			if (ep_trits)
			{
				switch (num_remaining)
				{
					case 1: num_bits = 2;
					case 2: num_bits = 4;
					case 3: num_bits = 5;
					case 4: num_bits = 7;
					default: break;
				}
			}
			else
			{
				switch (num_remaining)
				{
					case 1: num_bits = 3;
					case 2: num_bits = 5;
					default: break;
				}
			}
		}
		tq_values[i] = r.read(num_bits);
	}

	char[18] endpoints;   // packed values: bits | digit << ep_bits
	uint accum;
	uint accum_remaining;
	uint next_tq;
	for (uint i = 0; i < total_values; i++)
	{
		uint value = r.read(ep_bits);
		if (total_tqs)
		{
			if (!accum_remaining)
			{
				accum = tq_values[next_tq++];
				accum_remaining = bundle_size;
			}
			uint v = accum % mul;
			accum /= mul;
			accum_remaining--;
			value |= v << ep_bits;
		}
		endpoints[i] = (char)value;
	}

	// --- partition pattern + per-subset anchor texels ---
	char[16] zero_pattern;
	char[] pattern = zero_pattern[..];
	uint a0 = 0;
	uint a1 = 16;   // sentinels that never match a texel index
	uint a2 = 16;
	if (subsets == 3)
	{
		pattern = PATTERNS3[common_pattern * 16 : 16];
		a0 = ANCHORS3[common_pattern * 3];
		a1 = ANCHORS3[common_pattern * 3 + 1];
		a2 = ANCHORS3[common_pattern * 3 + 2];
	}
	else if (subsets == 2)
	{
		if (mode == 7)
		{
			pattern = PATTERNS2_3[common_pattern * 16 : 16];
			a0 = ANCHORS2_3[common_pattern * 2];
			a1 = ANCHORS2_3[common_pattern * 2 + 1];
		}
		else
		{
			pattern = PATTERNS2[common_pattern * 16 : 16];
			a0 = ANCHORS2[common_pattern * 2];
			a1 = ANCHORS2[common_pattern * 2 + 1];
		}
	}

	// --- weights: plain bits, anchors store one less bit ---
	uint weight_bits = MODE_WEIGHT_BITS[mode];
	char[32] weights;
	if (planes == 2)
	{
		// Single subset; texel 0's two weights are the anchors.
		for (uint i = 0; i < 32; i++)
		{
			weights[i] = (char)r.read(i < 2 ? weight_bits - 1 : weight_bits);
		}
	}
	else
	{
		for (uint i = 0; i < 16; i++)
		{
			bool anchor = i == a0 || i == a1 || i == a2;
			weights[i] = (char)r.read(anchor ? weight_bits - 1 : weight_bits);
		}
	}
	if (!r.ok()) return INVALID_BLOCK~;

	// --- reconstruct: unquantized endpoint pairs -> per-level colors ---
	char[4][2][3] ep;   // [subset][low/high][rgba]
	for (uint s = 0; s < subsets; s++)
	{
		if (comps == 2)
		{
			// Luminance+alpha: L drives RGB.
			char ll = (char)unquant_endpoint(endpoints[s * 4 + 0], endpoint_range);
			char lh = (char)unquant_endpoint(endpoints[s * 4 + 1], endpoint_range);
			char al = (char)unquant_endpoint(endpoints[s * 4 + 2], endpoint_range);
			char ah = (char)unquant_endpoint(endpoints[s * 4 + 3], endpoint_range);
			ep[s][0] = { ll, ll, ll, al };
			ep[s][1] = { lh, lh, lh, ah };
		}
		else
		{
			for (uint c = 0; c < comps; c++)
			{
				ep[s][0][c] = (char)unquant_endpoint(endpoints[s * comps * 2 + c * 2 + 0], endpoint_range);
				ep[s][1][c] = (char)unquant_endpoint(endpoints[s * comps * 2 + c * 2 + 1], endpoint_range);
			}
			for (uint c = comps; c < 4; c++)
			{
				ep[s][0][c] = 255;
				ep[s][1][c] = 255;
			}
		}
	}

	uint weight_levels = 1u << weight_bits;
	char[4][32][3] colors;   // [subset][weight level][rgba]
	for (uint s = 0; s < subsets; s++)
	{
		for (uint l = 0; l < weight_levels; l++)
		{
			uint w = weight_scale(l, weight_bits);
			for (uint c = 0; c < 4; c++)
			{
				colors[s][l][c] = interpolate(ep[s][0][c], ep[s][1][c], w, srgb);
			}
		}
	}

	// --- write pixels ---
	if (planes == 1)
	{
		for (uint i = 0; i < 16; i++)
		{
			char[4] px = colors[pattern[i]][weights[i]];
			out[i * 4 : 4] = px[..];
		}
	}
	else
	{
		for (uint i = 0; i < 16; i++)
		{
			uint w0 = weights[i * 2];
			uint w1 = weights[i * 2 + 1];
			for (uint c = 0; c < 4; c++)
			{
				out[i * 4 + c] = colors[0][(int)c == ccs ? w1 : w0][c];
			}
		}
	}
}

struct DecodeJob @local
{
	char[] blocks;
	char[] out;
	uint width;
	uint height;
	uint bw;
	bool srgb;
	bool failed;   // only ever written true, so the racing writes are benign
}

fn void decode_row(void* ctx, usz by) @local
{
	DecodeJob* j = (DecodeJob*)ctx;
	char[64] px;
	for (uint bx = 0; bx < j.bw; bx++)
	{
		if (@catch(decode_block(j.blocks[(by * j.bw + bx) * 16 : 16], px[..], j.srgb)))
		{
			j.failed = true;
			return;
		}
		uint copy_w = min(j.width - bx * 4, 4u);
		uint copy_h = min(j.height - (uint)by * 4, 4u);
		for (uint y = 0; y < copy_h; y++)
		{
			usz dst = ((by * 4 + y) * j.width + (usz)bx * 4) * 4;
			j.out[dst : copy_w * 4] = px[y * 16 : copy_w * 4];
		}
	}
}

<*
 Decode a whole UASTC image: `blocks` is ceil(w/4)*ceil(h/4) 16-byte blocks in
 raster order (a KTX2 level payload after supercompression is undone), `out`
 is width*height RGBA8. Edge blocks are cropped. Block rows are decoded on
 `threads` threads (0 = one per core, 1 = inline).
*>
fn void? decode_image(char[] blocks, char[] out, uint width, uint height, bool srgb = false, uint threads = 0)
{
	uint bw = (width + 3) / 4;
	uint bh = (height + 3) / 4;
	if (blocks.len != (usz)bw * bh * 16) return INVALID_SIZE~;
	if (out.len != (usz)width * height * 4) return INVALID_SIZE~;

	DecodeJob job = { .blocks = blocks, .out = out, .width = width, .height = height, .bw = bw, .srgb = srgb };
	parallel::run(bh, &job, &decode_row, threads);
	if (job.failed) return INVALID_BLOCK~;
}

// ===========================================================================
// Encode (docs/basis-rewrite.md phase 4)
//
// Starter mode set = basisu's cPackUASTCLevelFaster list: solid (mode 8) plus
// modes 0/4/6 for RGB, 9/11/12 for RGBA, 15/17 for luminance+alpha; level 0
// restricts to the Fastest subset. Each candidate mode gets a trial encode
// (bbox-diagonal projection + least-squares endpoint refinement, then exact
// reconstruction through the decoder's own unquant/interpolate math to pick
// weights and score MSE); the lowest-error trial is serialized with the same
// bit layout as basisu's pack_uastc. Transcode hint bits are written as
// zeros — a quality-only tradeoff for ETC1/EAC transcode targets — except on
// solid blocks, where the ETC1 hint is authoritative and computed properly.
// ===========================================================================

// Mode Huffman codes for writing, LSB-first (g_uastc_mode_huff_codes[.][0];
// bit lengths in MODE_CODE_SIZES).
const char[TOTAL_MODES + 1] MODE_CODES = {
	0x1, 0x35, 0x1D, 0x3, 0x13, 0xB, 0x1B, 0x7, 0x17, 0xF,
	0x2, 0x0, 0x6, 0x1F, 0xD, 0x5, 0x15, 0x25, 0x9, 0x45,
};

// Per-range endpoint quantization: the packed BISE value (bits | digit<<bits)
// whose unquantized byte is nearest each desired byte. Built on first use;
// init is not thread-safe (call encode once before going parallel).
char[256][21] quant_lut @local;
bool quant_ready @local = false;

fn void init_quant() @local
{
	if (quant_ready) return;
	for (uint range = 0; range < 21; range++)
	{
		uint nbits = BISE_RANGE[range][0];
		uint digits = 1;
		if (BISE_RANGE[range][1] != 0) digits = 3;
		if (BISE_RANGE[range][2] != 0) digits = 5;
		// Trit/quint ranges without unquant params never appear as endpoint
		// ranges (no mode uses them) — skip instead of tripping on them.
		if (digits > 1 && UNQUANT_B[range].len == 0) continue;
		for (uint want = 0; want < 256; want++)
		{
			uint best;
			int best_err = 256;
			for (uint d = 0; d < digits; d++)
			{
				for (uint b = 0; b < (1u << nbits); b++)
				{
					uint packed = b | (d << nbits);
					int err = (int)unquant_endpoint(packed, range) - (int)want;
					if (err < 0) err = -err;
					if (err < best_err)
					{
						best_err = err;
						best = packed;
					}
				}
			}
			quant_lut[range][want] = (char)best;
		}
	}
	quant_ready = true;
}

struct Trial @local
{
	uint mode;
	uint pattern;   // common-pattern index (2/3-subset modes)
	int ccs;        // second-plane component (dual-plane modes), else -1
	ulong err;
	char[18] endpoints;   // packed BISE values, [subset*comps*2 + comp*2 + lo/hi]
	char[32] weights;     // weight indices, [texel*planes + plane]
}

fn void put_bits(char[] buf, uint* ofs, uint val, uint n) @local
{
	for (uint i = 0; i < n; i++)
	{
		if ((val >> i) & 1) buf[(*ofs + i) >> 3] |= (char)(1u << ((*ofs + i) & 7));
	}
	*ofs += n;
}

<* Partition pattern + per-subset anchor texels (16 = no anchor sentinel). *>
fn void pattern_anchors(uint mode, uint subsets, uint idx, char[16]* pattern, uint[3]* anchors) @local
{
	(*anchors)[0] = 0;
	(*anchors)[1] = 16;
	(*anchors)[2] = 16;
	switch (subsets)
	{
		case 3:
			(*pattern)[..] = PATTERNS3[idx * 16 : 16];
			(*anchors)[0] = ANCHORS3[idx * 3];
			(*anchors)[1] = ANCHORS3[idx * 3 + 1];
			(*anchors)[2] = ANCHORS3[idx * 3 + 2];
		case 2:
			if (mode == 7)
			{
				(*pattern)[..] = PATTERNS2_3[idx * 16 : 16];
				(*anchors)[0] = ANCHORS2_3[idx * 2];
				(*anchors)[1] = ANCHORS2_3[idx * 2 + 1];
			}
			else
			{
				(*pattern)[..] = PATTERNS2[idx * 16 : 16];
				(*anchors)[0] = ANCHORS2[idx * 2];
				(*anchors)[1] = ANCHORS2[idx * 2 + 1];
			}
		default:
			*pattern = {};
	}
}

fn float clamp255(float v) @local @inline => v < 0 ? 0 : v > 255 ? 255 : v;

<*
 Fit float low/high endpoints for one subset's texels over the given pixel
 channels: bbox-diagonal projection for initial weights, then least-squares
 refinement with reassignment. Results are indexed by position in `chans`.
*>
fn void fit_endpoints(char[] px, uint[] texels, char[] chans, uint wbits, float[4]* flo, float[4]* fhi) @local
{
	uint nch = (uint)chans.len;
	uint levels = 1u << wbits;

	float[4] lo = { 255, 255, 255, 255 };
	float[4] hi;
	foreach (t : texels)
	{
		for (uint c = 0; c < nch; c++)
		{
			float v = (float)px[t * 4 + chans[c]];
			if (v < lo[c]) lo[c] = v;
			if (v > hi[c]) hi[c] = v;
		}
	}
	float[4] axis;
	float len2;
	for (uint c = 0; c < nch; c++)
	{
		axis[c] = hi[c] - lo[c];
		len2 += axis[c] * axis[c];
	}
	*flo = lo;
	*fhi = hi;
	if (len2 < 0.0001f) return;   // constant subset

	// Initial weight fractions: project on the diagonal, snap to the mode's
	// representable fractions.
	float[16] fw;
	foreach (idx, t : texels)
	{
		float dot;
		for (uint c = 0; c < nch; c++)
		{
			dot += ((float)px[t * 4 + chans[c]] - lo[c]) * axis[c];
		}
		float tt = dot / len2;
		if (tt < 0) tt = 0;
		if (tt > 1) tt = 1;
		uint bl;
		float bd = 2;
		for (uint l = 0; l < levels; l++)
		{
			float f = (float)weight_scale(l, wbits) / 64.0f;
			float d = f > tt ? f - tt : tt - f;
			if (d < bd)
			{
				bd = d;
				bl = l;
			}
		}
		fw[idx] = (float)weight_scale(bl, wbits) / 64.0f;
	}

	float[4] cur_lo = lo;
	float[4] cur_hi = hi;
	for (uint pass = 0; pass < 2; pass++)
	{
		float z00;
		float z01;
		float z11;
		float[4] q0;
		float[4] q1;
		foreach (idx, t : texels)
		{
			float f = fw[idx];
			float omf = 1.0f - f;
			z00 += omf * omf;
			z01 += omf * f;
			z11 += f * f;
			for (uint c = 0; c < nch; c++)
			{
				float v = (float)px[t * 4 + chans[c]];
				q0[c] += omf * v;
				q1[c] += f * v;
			}
		}
		float det = z00 * z11 - z01 * z01;
		if (det > 1e-8f || det < -1e-8f)
		{
			for (uint c = 0; c < nch; c++)
			{
				cur_lo[c] = clamp255((z11 * q0[c] - z01 * q1[c]) / det);
				cur_hi[c] = clamp255((z00 * q1[c] - z01 * q0[c]) / det);
			}
		}
		if (pass == 1) break;   // final selection happens in exact reconstruction

		foreach (idx, t : texels)
		{
			float bd = 1e30f;
			float bf;
			for (uint l = 0; l < levels; l++)
			{
				float f = (float)weight_scale(l, wbits) / 64.0f;
				float e;
				for (uint c = 0; c < nch; c++)
				{
					float d = cur_lo[c] + (cur_hi[c] - cur_lo[c]) * f - (float)px[t * 4 + chans[c]];
					e += d * d;
				}
				if (e < bd)
				{
					bd = e;
					bf = f;
				}
			}
			fw[idx] = bf;
		}
	}
	*flo = cur_lo;
	*fhi = cur_hi;
}

<*
 Exact reconstruction of a trial through the decoder's unquant/interpolate
 math: picks the best weight index per texel (per plane) and returns the total
 squared RGBA error against the source pixels.
*>
fn ulong reconstruct(uint mode, char[16]* pattern, int ccs, char[18]* endpoints, char[32]* weights, char[] px) @local
{
	uint subsets = MODE_SUBSETS[mode];
	uint comps = MODE_COMPS[mode];
	uint range = MODE_ENDPOINT_RANGES[mode];
	uint wbits = MODE_WEIGHT_BITS[mode];
	uint planes = MODE_PLANES[mode];
	uint levels = 1u << wbits;

	char[4][2][3] ep;
	for (uint s = 0; s < subsets; s++)
	{
		if (comps == 2)
		{
			char ll = (char)unquant_endpoint((*endpoints)[s * 4 + 0], range);
			char lh = (char)unquant_endpoint((*endpoints)[s * 4 + 1], range);
			char al = (char)unquant_endpoint((*endpoints)[s * 4 + 2], range);
			char ah = (char)unquant_endpoint((*endpoints)[s * 4 + 3], range);
			ep[s][0] = { ll, ll, ll, al };
			ep[s][1] = { lh, lh, lh, ah };
		}
		else
		{
			for (uint c = 0; c < comps; c++)
			{
				ep[s][0][c] = (char)unquant_endpoint((*endpoints)[s * comps * 2 + c * 2 + 0], range);
				ep[s][1][c] = (char)unquant_endpoint((*endpoints)[s * comps * 2 + c * 2 + 1], range);
			}
			for (uint c = comps; c < 4; c++)
			{
				ep[s][0][c] = 255;
				ep[s][1][c] = 255;
			}
		}
	}

	char[4][32][3] colors;
	for (uint s = 0; s < subsets; s++)
	{
		for (uint l = 0; l < levels; l++)
		{
			uint w = weight_scale(l, wbits);
			for (uint c = 0; c < 4; c++)
			{
				colors[s][l][c] = interpolate(ep[s][0][c], ep[s][1][c], w, false);
			}
		}
	}

	ulong total;
	if (planes == 1)
	{
		for (uint i = 0; i < 16; i++)
		{
			uint s = (*pattern)[i];
			uint best = 0xFFFF_FFFF;
			uint bw;
			for (uint l = 0; l < levels; l++)
			{
				uint e;
				for (uint c = 0; c < 4; c++)
				{
					int d = (int)colors[s][l][c] - (int)px[i * 4 + c];
					e += (uint)(d * d);
				}
				if (e < best)
				{
					best = e;
					bw = l;
				}
			}
			(*weights)[i] = (char)bw;
			total += best;
		}
	}
	else
	{
		for (uint i = 0; i < 16; i++)
		{
			for (uint p = 0; p < 2; p++)
			{
				uint best = 0xFFFF_FFFF;
				uint bw;
				for (uint l = 0; l < levels; l++)
				{
					uint e;
					for (uint c = 0; c < 4; c++)
					{
						if (((int)c == ccs ? 1u : 0u) != p) continue;
						int d = (int)colors[0][l][c] - (int)px[i * 4 + c];
						e += (uint)(d * d);
					}
					if (e < best)
					{
						best = e;
						bw = l;
					}
				}
				(*weights)[i * 2 + p] = (char)bw;
				total += best;
			}
		}
	}
	return total;
}

<* Trial-encode one candidate (mode, pattern, ccs) against the block. *>
fn Trial trial_mode(uint mode, uint pattern_idx, int ccs, char[] px) @local
{
	uint subsets = MODE_SUBSETS[mode];
	uint comps = MODE_COMPS[mode];
	uint range = MODE_ENDPOINT_RANGES[mode];
	uint wbits = MODE_WEIGHT_BITS[mode];
	uint planes = MODE_PLANES[mode];

	char[16] pattern;
	uint[3] anchors;
	pattern_anchors(mode, subsets, pattern_idx, &pattern, &anchors);

	char[4] chans;
	switch (comps)
	{
		case 2:
			chans[0] = 0;
			chans[1] = 3;
		default:
			for (uint c = 0; c < comps; c++) chans[c] = (char)c;
	}

	Trial t = { .mode = mode, .pattern = pattern_idx, .ccs = ccs };

	for (uint s = 0; s < subsets; s++)
	{
		uint[16] texels;
		uint ntex;
		for (uint i = 0; i < 16; i++)
		{
			if (pattern[i] == s) texels[ntex++] = i;
		}

		float[4] mlo;
		float[4] mhi;
		if (planes == 1)
		{
			fit_endpoints(px, texels[:ntex], chans[:comps], wbits, &mlo, &mhi);
		}
		else
		{
			// Plane 1 drives the ccs channel alone; plane 0 fits the rest.
			uint ccs_chan = comps == 2 ? 3u : (uint)ccs;
			char[4] c0;
			uint n0;
			for (uint c = 0; c < comps; c++)
			{
				if (chans[c] != (char)ccs_chan) c0[n0++] = chans[c];
			}
			char[1] c1 = { (char)ccs_chan };
			float[4] plo;
			float[4] phi;
			float[4] slo;
			float[4] shi;
			fit_endpoints(px, texels[:ntex], c0[:n0], wbits, &plo, &phi);
			fit_endpoints(px, texels[:ntex], c1[..], wbits, &slo, &shi);
			uint k;
			for (uint c = 0; c < comps; c++)
			{
				if (chans[c] == (char)ccs_chan)
				{
					mlo[c] = slo[0];
					mhi[c] = shi[0];
				}
				else
				{
					mlo[c] = plo[k];
					mhi[c] = phi[k];
					k++;
				}
			}
		}

		for (uint c = 0; c < comps; c++)
		{
			t.endpoints[s * comps * 2 + c * 2 + 0] = quant_lut[range][(uint)(mlo[c] + 0.5f)];
			t.endpoints[s * comps * 2 + c * 2 + 1] = quant_lut[range][(uint)(mhi[c] + 0.5f)];
		}
	}

	t.err = reconstruct(mode, &pattern, ccs, &t.endpoints, &t.weights, px);
	return t;
}

<*
 Rank the 30 shared 2-subset patterns by a cheap projection error over the
 first `nch` RGBA channels; returns the best two candidates for full trials.
*>
fn void rank_patterns2(char[] px, uint nch, uint* best0, uint* best1) @local
{
	float e0 = 1e30f;
	float e1 = 1e30f;
	*best0 = 0;
	*best1 = 0;
	for (uint p = 0; p < TOTAL_PATTERNS2; p++)
	{
		float err;
		for (uint s = 0; s < 2; s++)
		{
			float[4] lo = { 255, 255, 255, 255 };
			float[4] hi;
			for (uint i = 0; i < 16; i++)
			{
				if (PATTERNS2[p * 16 + i] != s) continue;
				for (uint c = 0; c < nch; c++)
				{
					float v = (float)px[i * 4 + c];
					if (v < lo[c]) lo[c] = v;
					if (v > hi[c]) hi[c] = v;
				}
			}
			float[4] axis;
			float len2;
			for (uint c = 0; c < nch; c++)
			{
				axis[c] = hi[c] - lo[c];
				len2 += axis[c] * axis[c];
			}
			if (len2 < 0.0001f) continue;
			for (uint i = 0; i < 16; i++)
			{
				if (PATTERNS2[p * 16 + i] != s) continue;
				float dot;
				for (uint c = 0; c < nch; c++)
				{
					dot += ((float)px[i * 4 + c] - lo[c]) * axis[c];
				}
				float tt = dot / len2;
				if (tt < 0) tt = 0;
				if (tt > 1) tt = 1;
				for (uint c = 0; c < nch; c++)
				{
					float d = lo[c] + tt * axis[c] - (float)px[i * 4 + c];
					err += d * d;
				}
			}
		}
		if (err < e0)
		{
			e1 = e0;
			*best1 = *best0;
			e0 = err;
			*best0 = p;
		}
		else if (err < e1)
		{
			e1 = err;
			*best1 = p;
		}
	}
}

fn uint argmax_variance_rgb(char[] px) @local
{
	float[3] sum;
	float[3] sum2;
	for (uint i = 0; i < 16; i++)
	{
		for (uint c = 0; c < 3; c++)
		{
			float v = (float)px[i * 4 + c];
			sum[c] += v;
			sum2[c] += v * v;
		}
	}
	uint best;
	float bv = -1;
	for (uint c = 0; c < 3; c++)
	{
		float variance = sum2[c] - sum[c] * sum[c] / 16.0f;
		if (variance > bv)
		{
			bv = variance;
			best = c;
		}
	}
	return best;
}

fn int etc1_solid_val(bool diff, uint inten, uint sel, uint base) @local
{
	int c = diff ? (int)((base >> 2) | (base << 3)) : (int)(base | (base << 4));
	c += etc1s::INTEN_TABLES[inten][sel];
	return c < 0 ? 0 : c > 255 ? 255 : c;
}

<*
 Pack a solid-color block: mode 8 + RGBA + the ETC1 hint. Unlike the other
 modes' hints, the solid ETC1 hint is authoritative (transcoders rebuild the
 ETC1 block straight from it), so search the (diff, inten, selector, base)
 space for the config that reproduces the color best.
*>
fn void pack_solid(char[] px4, char[] out) @local
{
	char[16] buf;
	uint ofs;
	put_bits(buf[..], &ofs, MODE_CODES[MODE_SOLID], MODE_CODE_SIZES[MODE_SOLID]);
	for (uint c = 0; c < 4; c++) put_bits(buf[..], &ofs, px4[c], 8);

	uint best_err = 0xFFFF_FFFF;
	uint bd;
	uint bi;
	uint bs;
	uint[3] bbase;
	for (uint diff = 0; diff < 2; diff++)
	{
		uint limit = diff != 0 ? 32u : 16u;
		for (uint inten = 0; inten < 8; inten++)
		{
			for (uint sel = 0; sel < 4; sel++)
			{
				uint err;
				uint[3] base;
				for (uint c = 0; c < 3; c++)
				{
					uint bc;
					uint bce = 0xFFFF_FFFF;
					for (uint b = 0; b < limit; b++)
					{
						int d = etc1_solid_val(diff != 0, inten, sel, b) - (int)px4[c];
						uint e = (uint)(d * d);
						if (e < bce)
						{
							bce = e;
							bc = b;
						}
					}
					base[c] = bc;
					err += bce;
				}
				if (err < best_err)
				{
					best_err = err;
					bd = diff;
					bi = inten;
					bs = sel;
					bbase = base;
				}
			}
		}
	}
	put_bits(buf[..], &ofs, bd, 1);
	put_bits(buf[..], &ofs, bi, 3);
	put_bits(buf[..], &ofs, bs, 2);
	put_bits(buf[..], &ofs, bbase[0], 5);
	put_bits(buf[..], &ofs, bbase[1], 5);
	put_bits(buf[..], &ofs, bbase[2], 5);
	out[..] = buf[..];
}

<* Serialize a trial with pack_uastc's exact bit layout. *>
fn void pack_block(Trial* t, char[] out) @local
{
	char[16] buf;
	uint ofs;
	uint mode = t.mode;
	uint subsets = MODE_SUBSETS[mode];
	uint comps = MODE_COMPS[mode];
	uint planes = MODE_PLANES[mode];
	uint wbits = MODE_WEIGHT_BITS[mode];

	put_bits(buf[..], &ofs, MODE_CODES[mode], MODE_CODE_SIZES[mode]);

	// Hints: zeros, except the trailing 8-bit ETC2 EAC table/multiplier field
	// of the alpha-carrying modes, where basisu asserts multiplier >= 1.
	uint hint_bits = MODE_HINT_BITS[mode];
	if (comps != 3)
	{
		put_bits(buf[..], &ofs, 0, hint_bits - 8);
		put_bits(buf[..], &ofs, 1u << 4, 8);
	}
	else
	{
		put_bits(buf[..], &ofs, 0, hint_bits);
	}

	switch (mode)
	{
		case 2:
		case 4:
		case 7:
		case 9:
		case 16:
			put_bits(buf[..], &ofs, t.pattern, 5);
		case 3:
			put_bits(buf[..], &ofs, t.pattern, 4);
		default:
			break;
	}
	switch (mode)
	{
		case 6:
		case 11:
		case 13:
			put_bits(buf[..], &ofs, (uint)t.ccs, 2);
		default:
			break;
	}

	char[16] pattern;
	uint[3] anchors;
	pattern_anchors(mode, subsets, t.pattern, &pattern, &anchors);
	char[18] endpoints = t.endpoints;
	char[32] weights = t.weights;
	uint maxw = (1u << wbits) - 1;

	// If an anchor weight's MSB is set, invert that subset's weights in that
	// plane and swap the affected endpoint pairs — the anchor is stored with
	// one less bit, so its MSB must be clear.
	for (uint plane = 0; plane < planes; plane++)
	{
		for (uint s = 0; s < subsets; s++)
		{
			if (((uint)weights[anchors[s] * planes + plane] >> (wbits - 1)) & 1)
			{
				for (uint i = 0; i < 16; i++)
				{
					if (pattern[i] == s) weights[i * planes + plane] = (char)(maxw - weights[i * planes + plane]);
				}
				if (planes == 2)
				{
					for (uint c = 0; c < comps; c++)
					{
						uint comp_plane = comps == 2 ? c : ((int)c == t.ccs ? 1u : 0u);
						if (comp_plane == plane)
						{
							char tmp = endpoints[c * 2];
							endpoints[c * 2] = endpoints[c * 2 + 1];
							endpoints[c * 2 + 1] = tmp;
						}
					}
				}
				else
				{
					for (uint c = 0; c < comps; c++)
					{
						char tmp = endpoints[s * comps * 2 + c * 2];
						endpoints[s * comps * 2 + c * 2] = endpoints[s * comps * 2 + c * 2 + 1];
						endpoints[s * comps * 2 + c * 2 + 1] = tmp;
					}
				}
			}
		}
	}

	// Endpoints: trit/quint digits first, bundled little-endian base-3/5 (the
	// last bundle only carries the digits actually used), then the plain bits.
	uint range = MODE_ENDPOINT_RANGES[mode];
	uint ep_bits = BISE_RANGE[range][0];
	bool trits = BISE_RANGE[range][1] != 0;
	bool quints = BISE_RANGE[range][2] != 0;
	uint total_values = comps * 2 * subsets;

	if (trits || quints)
	{
		uint mul = trits ? 3u : 5u;
		uint flush = trits ? 243u : 125u;
		uint accum;
		uint accum_mul = 1;
		for (uint i = 0; i < total_values; i++)
		{
			accum += ((uint)endpoints[i] >> ep_bits) * accum_mul;
			accum_mul *= mul;
			if (accum_mul == flush)
			{
				put_bits(buf[..], &ofs, accum, trits ? 8 : 7);
				accum = 0;
				accum_mul = 1;
			}
		}
		if (accum_mul > 1)
		{
			uint nb;
			if (trits)
			{
				switch (accum_mul)
				{
					case 3: nb = 2;
					case 9: nb = 4;
					case 27: nb = 5;
					default: nb = 7;
				}
			}
			else
			{
				nb = accum_mul == 5 ? 3 : 5;
			}
			put_bits(buf[..], &ofs, accum, nb);
		}
	}
	for (uint i = 0; i < total_values; i++)
	{
		put_bits(buf[..], &ofs, (uint)endpoints[i] & ((1u << ep_bits) - 1), ep_bits);
	}

	// Weights; anchors get one bit less.
	uint plane_shift = planes == 2 ? 1u : 0u;
	for (uint i = 0; i < 16 * planes; i++)
	{
		uint texel = i >> plane_shift;
		uint nb = wbits;
		for (uint s = 0; s < subsets; s++)
		{
			if (anchors[s] == texel)
			{
				nb = wbits - 1;
				break;
			}
		}
		put_bits(buf[..], &ofs, weights[i], nb);
	}
	assert(ofs <= 128);
	out[..] = buf[..];
}

fn void consider(Trial* best, Trial t) @local
{
	if (t.err < best.err) *best = t;
}

<*
 Encode one 4x4 RGBA8 block (64 bytes, row-major) into a 16-byte UASTC block.
 `level` is the basisu pack level: 0 tries basisu's Fastest mode set, >= 1
 also the 2-subset and dual-plane RGB modes (the Faster set).
*>
fn void encode_block(char[] px, char[] out, uint level = 1)
{
	assert(px.len == 64 && out.len == 16);
	init_quant();

	bool solid = true;
	bool has_alpha = false;
	bool gray = true;
	for (uint i = 0; i < 16; i++)
	{
		if (px[i * 4] != px[0] || px[i * 4 + 1] != px[1] || px[i * 4 + 2] != px[2] || px[i * 4 + 3] != px[3]) solid = false;
		if (px[i * 4 + 3] != 255) has_alpha = true;
		if (px[i * 4] != px[i * 4 + 1] || px[i * 4] != px[i * 4 + 2]) gray = false;
	}
	if (solid)
	{
		pack_solid(px[:4], out);
		assert(packed_err(out, px) == 0, "solid block must decode exactly");
		return;
	}

	Trial best;
	best.err = ~(ulong)0;
	if (!has_alpha)
	{
		consider(&best, trial_mode(0, 0, -1, px));
		if (level >= 1)
		{
			consider(&best, trial_mode(6, 0, (int)argmax_variance_rgb(px), px));
			uint p0;
			uint p1;
			rank_patterns2(px, 3, &p0, &p1);
			consider(&best, trial_mode(4, p0, -1, px));
			if (p1 != p0) consider(&best, trial_mode(4, p1, -1, px));
		}
	}
	else
	{
		consider(&best, trial_mode(12, 0, -1, px));
		consider(&best, trial_mode(11, 0, 3, px));
		if (level >= 1)
		{
			uint p0;
			uint p1;
			rank_patterns2(px, 4, &p0, &p1);
			consider(&best, trial_mode(9, p0, -1, px));
			if (p1 != p0) consider(&best, trial_mode(9, p1, -1, px));
		}
	}
	if (gray && (has_alpha || level >= 1))
	{
		consider(&best, trial_mode(15, 0, -1, px));
		if (level >= 1) consider(&best, trial_mode(17, 0, 3, px));
	}
	pack_block(&best, out);
	assert(packed_err(out, px) == best.err,
		"pack/decode mismatch: mode %d packed err %d, trial err %d",
		best.mode, packed_err(out, px), best.err);
}

<* Squared RGBA error of a packed block against source pixels (assert helper). *>
fn ulong packed_err(char[] blk, char[] px) @local
{
	char[64] back;
	if (@catch(decode_block(blk, back[..]))) return ~(ulong)0;
	ulong e;
	for (uint i = 0; i < 64; i++)
	{
		int d = (int)back[i] - (int)px[i];
		e += (ulong)(d * d);
	}
	return e;
}

struct EncodeJob @local
{
	char[] rgba;
	char[] out;
	uint width;
	uint height;
	uint bw;
	uint level;
}

fn void encode_row(void* ctx, usz by) @local
{
	EncodeJob* j = (EncodeJob*)ctx;
	char[64] px;
	for (uint bx = 0; bx < j.bw; bx++)
	{
		for (uint y = 0; y < 4; y++)
		{
			uint sy = min((uint)by * 4 + y, j.height - 1);
			for (uint x = 0; x < 4; x++)
			{
				uint sx = min(bx * 4 + x, j.width - 1);
				usz src = ((usz)sy * j.width + sx) * 4;
				px[(y * 4 + x) * 4 : 4] = j.rgba[src : 4];
			}
		}
		encode_block(px[..], j.out[(by * j.bw + bx) * 16 : 16], j.level);
	}
}

<*
 Encode an image to UASTC blocks: `rgba` is width*height*4 bytes, the result
 is ceil(w/4)*ceil(h/4) 16-byte blocks in raster order (a KTX2 level image,
 before supercompression). Edge blocks pad by clamping. Block rows are encoded
 on `threads` threads (0 = one per core, 1 = inline); the output is identical
 for any thread count.
*>
fn char[]? encode_image(Allocator allocator, char[] rgba, uint width, uint height, uint level = 1, uint threads = 0)
{
	if (rgba.len != (usz)width * height * 4) return INVALID_SIZE~;
	uint bw = (width + 3) / 4;
	uint bh = (height + 3) / 4;
	char[] out = alloc::new_array(allocator, char, (sz)((usz)bw * bh * 16));

	init_quant();   // the lazy LUT init must not race the workers
	EncodeJob job = { .rgba = rgba, .out = out, .width = width, .height = height, .bw = bw, .level = level };
	parallel::run(bh, &job, &encode_row, threads);
	return out;
}
