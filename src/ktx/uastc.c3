// UASTC LDR 4x4 block decoder in pure C3 (docs/basis-rewrite.md phase 1).
//
// Port of basis_universal's reference unpack_uastc (basisu_transcoder.cpp) —
// bit-exact against it by construction and verified against golden RGBA32
// dumps in test/uastc_test.c3. A UASTC block is 128 bits: a variable-length
// mode code, transcode hint bits (skipped here), optional partition-pattern /
// dual-plane fields, BISE-packed endpoints, then plain-bit weights filling the
// block to bit 128.
module ktx::uastc;
import ktx::bits;

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

<*
 Decode a whole UASTC image: `blocks` is ceil(w/4)*ceil(h/4) 16-byte blocks in
 raster order (a KTX2 level payload after supercompression is undone), `out`
 is width*height RGBA8. Edge blocks are cropped.
*>
fn void? decode_image(char[] blocks, char[] out, uint width, uint height, bool srgb = false)
{
	uint bw = (width + 3) / 4;
	uint bh = (height + 3) / 4;
	if (blocks.len != (usz)bw * bh * 16) return INVALID_SIZE~;
	if (out.len != (usz)width * height * 4) return INVALID_SIZE~;

	char[64] px;
	for (uint by = 0; by < bh; by++)
	{
		for (uint bx = 0; bx < bw; bx++)
		{
			decode_block(blocks[((usz)by * bw + bx) * 16 : 16], px[..], srgb)!;
			uint copy_w = min(width - bx * 4, 4u);
			uint copy_h = min(height - by * 4, 4u);
			for (uint y = 0; y < copy_h; y++)
			{
				usz dst = ((usz)(by * 4 + y) * width + (usz)bx * 4) * 4;
				out[dst : copy_w * 4] = px[y * 16 : copy_w * 4];
			}
		}
	}
}
