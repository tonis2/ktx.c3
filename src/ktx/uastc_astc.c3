// UASTC 4x4 -> ASTC 4x4 block transcode: what a GPU without BC7 (Adreno, Mali,
// Apple) samples a UASTC texture as.
//
// UASTC is a subset of ASTC 4x4 LDR. Every mode is an ASTC block with a 4x4
// weight grid, one colour endpoint mode shared by its subsets, plain-bit
// weights, and an endpoint range that is exactly the one an ASTC decoder
// derives from the bits the block has left. So a block is unpacked and its
// endpoint values and weights are written again in ASTC's layout, unchanged:
// an ASTC decoder builds the pixels `uastc::decode_block` builds. Lossless,
// unlike the BC7 mapper.
//
// Two things are found rather than copied:
//   * ASTC names a partition by a 10-bit seed fed to a hash, UASTC by an index
//     into its pattern tables. `init` searches the seeds once for each pattern
//     and records the hash's subset order, which need not be UASTC's.
//   * ASTC reads an RGB or RGBA endpoint pair whose low end sums brighter than
//     its high end as blue-contracted. A valid UASTC block has none; a pair that
//     does is swapped and its weights inverted, which decodes to the same pixels.
module ktx::uastc_astc;
import ktx::uastc, ktx::parallel;
import std::thread;

excuse INVALID_SIZE;

// Block mode bits for a 4x4 grid per weight bit count (1..5): grid fields
// A = 2, B = 0, and the weight range R with its high-precision bit H.
const ushort[6] BLOCK_MODE = { 0, 0x041, 0x042, 0x053, 0x242, 0x253 };
const ushort DUAL_PLANE = 0x400;

// The colour endpoint mode per UASTC component count: LA, RGB, RGBA direct.
const char[5] CEM = { 0, 0, 4, 8, 12 };

// Trit and quint bits that follow each value in an integer-sequence group.
const char[5] TRIT_BITS = { 2, 2, 1, 2, 1 };
const char[3] QUINT_BITS = { 3, 2, 2 };

<* A UASTC pattern as an ASTC partition: the seed, and the UASTC subset each ASTC subset is. *>
struct Partition
{
	ushort seed;
	char[3] subset;
	bool ok;
}

Partition[uastc::TOTAL_PATTERNS2] part2 @local;
Partition[uastc::TOTAL_PATTERNS3] part3 @local;
Partition[uastc::TOTAL_PATTERNS2_3] part23 @local;

// The 8-bit trit code of five trits and the 7-bit quint code of three quints,
// indexed by the digits read as base-3 / base-5 numbers.
char[243] trit_code @local;
char[125] quint_code @local;

OnceFlag tables_once @local;

fn uint hash52(uint p) @local
{
	p ^= p >> 15;
	p *= 0xEEDE0891;
	p ^= p >> 5;
	p += p << 16;
	p ^= p >> 7;
	p ^= p >> 3;
	p ^= p << 6;
	p ^= p >> 17;
	return p;
}

<*
 The ASTC subset of texel (x, y) in a 4x4 block: the spec's select_partition
 for a block of fewer than 31 texels, with z = 0.

 @require count >= 1 && count <= 4 : "ASTC has 1 to 4 partitions"
*>
fn uint select_partition(uint seed, uint x, uint y, uint count)
{
	x <<= 1;
	y <<= 1;
	seed += (count - 1) * 1024;
	uint rnum = hash52(seed);

	uint[12] s = {
		rnum & 0xF, (rnum >> 4) & 0xF, (rnum >> 8) & 0xF, (rnum >> 12) & 0xF,
		(rnum >> 16) & 0xF, (rnum >> 20) & 0xF, (rnum >> 24) & 0xF, (rnum >> 28) & 0xF,
		(rnum >> 18) & 0xF, (rnum >> 22) & 0xF, (rnum >> 26) & 0xF, ((rnum >> 30) | (rnum << 2)) & 0xF,
	};
	foreach (&v : s) *v *= *v;

	uint sh1;
	uint sh2;
	if (seed & 1)
	{
		sh1 = seed & 2 ? 4 : 5;
		sh2 = count == 3 ? 6 : 5;
	}
	else
	{
		sh1 = count == 3 ? 6 : 5;
		sh2 = seed & 2 ? 4 : 5;
	}
	uint sh3 = seed & 0x10 ? sh1 : sh2;
	for (uint i = 0; i < 8; i++) s[i] >>= i % 2 ? sh2 : sh1;
	for (uint i = 8; i < 12; i++) s[i] >>= sh3;

	uint a = (s[0] * x + s[1] * y + (rnum >> 14)) & 0x3F;
	uint b = (s[2] * x + s[3] * y + (rnum >> 10)) & 0x3F;
	uint c = (s[4] * x + s[5] * y + (rnum >> 6)) & 0x3F;
	uint d = (s[6] * x + s[7] * y + (rnum >> 2)) & 0x3F;
	if (count < 4) d = 0;
	if (count < 3) c = 0;

	if (a >= b && a >= c && a >= d) return 0;
	if (b >= c && b >= d) return 1;
	if (c >= d) return 2;
	return 3;
}

<* The lowest seed whose partition is `pattern` with its subsets relabelled, if any. *>
fn Partition find_seed(char[] pattern, uint count) @local
{
	for (uint seed = 0; seed < 1024; seed++)
	{
		Partition p = { .seed = (ushort)seed, .ok = true };
		char[3] seen;   // 1 + the ASTC subset a UASTC subset took, 0 for none yet
		bool[3] set;
		for (uint i = 0; i < 16 && p.ok; i++)
		{
			uint astc = select_partition(seed, i % 4, i / 4, count);
			char want = pattern[i];
			if (!set[astc])
			{
				set[astc] = true;
				p.subset[astc] = want;
				p.ok = seen[want] == 0;
				seen[want] = (char)(astc + 1);
			}
			else
			{
				p.ok = p.subset[astc] == want;
			}
		}
		if (!p.ok) continue;
		// Every ASTC subset has to stand for one of the pattern's.
		for (uint j = 0; j < count; j++) p.ok = p.ok && set[j];
		if (p.ok) return p;
	}
	return {};
}

<* Five trits out of an 8-bit trit code, as the ASTC spec decodes them. *>
fn uint[5] decode_trits(uint t) @local
{
	uint[5] r;
	uint c;
	if (((t >> 2) & 7) == 7)
	{
		c = ((t >> 5) & 7) << 2 | (t & 3);
		r[4] = 2;
		r[3] = 2;
	}
	else
	{
		c = t & 0x1F;
		if (((t >> 5) & 3) == 3)
		{
			r[4] = 2;
			r[3] = (t >> 7) & 1;
		}
		else
		{
			r[4] = (t >> 7) & 1;
			r[3] = (t >> 5) & 3;
		}
	}
	if ((c & 3) == 3)
	{
		r[2] = 2;
		r[1] = (c >> 4) & 1;
		r[0] = ((c >> 3) & 1) << 1 | ((c >> 2) & 1 & ~(c >> 3));
	}
	else if (((c >> 2) & 3) == 3)
	{
		r[2] = 2;
		r[1] = 2;
		r[0] = c & 3;
	}
	else
	{
		r[2] = (c >> 4) & 1;
		r[1] = (c >> 2) & 3;
		r[0] = ((c >> 1) & 1) << 1 | (c & 1 & ~(c >> 1));
	}
	return r;
}

<* Three quints out of a 7-bit quint code, as the ASTC spec decodes them. *>
fn uint[3] decode_quints(uint q) @local
{
	uint[3] r;
	if (((q >> 1) & 3) == 3 && ((q >> 5) & 3) == 0)
	{
		uint q0 = q & 1;
		r[2] = q0 << 2 | (((q >> 4) & 1) & ~q0) << 1 | (((q >> 3) & 1) & ~q0);
		r[1] = 4;
		r[0] = 4;
		return r;
	}
	uint c;
	if (((q >> 1) & 3) == 3)
	{
		r[2] = 4;
		c = ((q >> 3) & 3) << 3 | (~(q >> 5) & 3) << 1 | (q & 1);
	}
	else
	{
		r[2] = (q >> 5) & 3;
		c = q & 0x1F;
	}
	if ((c & 7) == 5)
	{
		r[1] = 4;
		r[0] = (c >> 3) & 3;
	}
	else
	{
		r[1] = (c >> 3) & 3;
		r[0] = c & 7;
	}
	return r;
}

<*
 Build the partition seeds and the trit and quint codes, once per process, on
 whichever thread asks first: two images can be mapped on two threads at once.
*>
fn void init() @local
{
	tables_once.call(fn void() {
		for (uint i = 0; i < uastc::TOTAL_PATTERNS2; i++) part2[i] = find_seed(uastc::PATTERNS2[i * 16 : 16], 2);
		for (uint i = 0; i < uastc::TOTAL_PATTERNS3; i++) part3[i] = find_seed(uastc::PATTERNS3[i * 16 : 16], 3);
		for (uint i = 0; i < uastc::TOTAL_PATTERNS2_3; i++) part23[i] = find_seed(uastc::PATTERNS2_3[i * 16 : 16], 2);

		// Inverted from the decoders, first code wins: several codes decode to the
		// same digits and any of them is a valid encoding.
		bool[243] have_trit;
		for (uint t = 0; t < 256; t++)
		{
			uint[5] d = decode_trits(t);
			uint i = d[0] + 3 * d[1] + 9 * d[2] + 27 * d[3] + 81 * d[4];
			if (have_trit[i]) continue;
			have_trit[i] = true;
			trit_code[i] = (char)t;
		}
		bool[125] have_quint;
		for (uint q = 0; q < 128; q++)
		{
			uint[3] d = decode_quints(q);
			uint i = d[0] + 5 * d[1] + 25 * d[2];
			if (have_quint[i]) continue;
			have_quint[i] = true;
			quint_code[i] = (char)q;
		}
	});
}

<* The partition `init` found for this block's pattern. *>
fn Partition* partition_of(uastc::Unpacked* u) @local
{
	if (u.subsets == 3) return &part3[u.pattern];
	return u.mode == 7 ? &part23[u.pattern] : &part2[u.pattern];
}

fn void put(char[16]* b, uint* ofs, uint val, uint n) @local
{
	for (uint i = 0; i < n; i++, (*ofs)++)
	{
		if ((val >> i) & 1) (*b)[*ofs >> 3] |= (char)(1 << (*ofs & 7));
	}
}

<* An integer sequence at `range`: plain bits, or groups of five trits or three quints. *>
fn void put_ise(char[16]* b, uint* ofs, char[] values, uint range) @local
{
	uint bits = uastc::BISE_RANGE[range][0];
	bool trits = uastc::BISE_RANGE[range][1] != 0;
	bool quints = uastc::BISE_RANGE[range][2] != 0;
	uint mask = (1u << bits) - 1;
	if (!trits && !quints)
	{
		foreach (v : values) put(b, ofs, v, bits);
		return;
	}

	uint group = trits ? 5 : 3;
	uint radix = trits ? 3 : 5;
	for (sz i = 0; i < values.len; i += group)
	{
		sz n = min(values.len - i, (sz)group);
		// Digits past the end are zero: the group's code still covers them.
		uint index;
		for (sz j = n - 1; j >= 0; j--) index = index * radix + (values[i + j] >> bits);
		uint code = trits ? trit_code[index] : quint_code[index];
		for (sz j = 0; j < n; j++)
		{
			put(b, ofs, values[i + j] & mask, bits);
			uint tq = trits ? TRIT_BITS[j] : QUINT_BITS[j];
			put(b, ofs, code & ((1u << tq) - 1), tq);
			code >>= tq;
		}
	}
}

<* A void-extent block: one colour, no extent, LDR. *>
fn void pack_solid(char[4] rgba, char* out) @local
{
	const char[8] HEADER = { 0xFC, 0xFD, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF };
	out[:8] = HEADER[..];
	for (uint c = 0; c < 4; c++)
	{
		out[8 + c * 2] = rgba[c];
		out[8 + c * 2 + 1] = rgba[c];
	}
}

<*
 Swap the endpoints of every RGB or RGBA subset whose low end is the brighter,
 and invert its weights, so ASTC reads it directly rather than blue-contracted.
*>
fn void avoid_blue_contraction(uastc::Unpacked* u) @local
{
	if (u.comps < 3) return;
	uint top = (1u << u.weight_bits) - 1;
	for (uint s = 0; s < u.subsets; s++)
	{
		uint lo = (uint)u.ep[s][0][0] + u.ep[s][0][1] + u.ep[s][0][2];
		uint hi = (uint)u.ep[s][1][0] + u.ep[s][1][1] + u.ep[s][1][2];
		if (lo <= hi) continue;
		uint base = s * u.comps * 2;
		for (uint c = 0; c < u.comps; c++)
		{
			char v = u.ise[base + c * 2];
			u.ise[base + c * 2] = u.ise[base + c * 2 + 1];
			u.ise[base + c * 2 + 1] = v;
		}
		for (uint i = 0; i < 16 * u.planes; i++)
		{
			if (u.partition[i / u.planes] == s) u.weights[i] = (char)(top - u.weights[i]);
		}
	}
}

<*
 Map one 16-byte UASTC block onto one 16-byte ASTC 4x4 block. An undecodable
 block, or one whose pattern found no seed (none does), becomes transparent
 black, as the BC7 mapper writes it.
*>
fn void map_block(char[] block, char* out)
{
	init();
	uastc::Unpacked u;
	if (@catch(uastc::unpack_block(block, &u)))
	{
		pack_solid({ 0, 0, 0, 0 }, out);
		return;
	}
	if (u.mode == uastc::MODE_SOLID)
	{
		pack_solid(u.ep[0][0], out);
		return;
	}

	Partition single = { .subset = { 0, 1, 2 }, .ok = true };
	Partition* part = u.subsets == 1 ? &single : partition_of(&u);
	if (!part.ok)
	{
		pack_solid({ 0, 0, 0, 0 }, out);
		return;
	}
	avoid_blue_contraction(&u);

	char[16] b;
	uint ofs;
	put(&b, &ofs, BLOCK_MODE[u.weight_bits] | (u.planes == 2 ? DUAL_PLANE : 0), 11);
	put(&b, &ofs, u.subsets - 1, 2);
	if (u.subsets == 1)
	{
		put(&b, &ofs, CEM[u.comps], 4);
	}
	else
	{
		put(&b, &ofs, part.seed, 10);
		// Low two bits zero: every subset shares the one mode.
		put(&b, &ofs, (uint)CEM[u.comps] << 2, 6);
	}

	// The endpoints in ASTC's subset order.
	uint per = u.comps * 2;
	char[18] values;
	for (uint p = 0; p < u.subsets; p++)
	{
		values[p * per : per] = u.ise[part.subset[p] * per : per];
	}
	put_ise(&b, &ofs, values[:u.subsets * per], u.endpoint_range);

	// Weights run down from bit 127, each value's low bit first; the dual-plane
	// component sits just below them.
	uint count = 16 * u.planes;
	uint wbits = count * u.weight_bits;
	for (uint i = 0; i < count; i++)
	{
		for (uint k = 0; k < u.weight_bits; k++)
		{
			uint at = 127 - (i * u.weight_bits + k);
			if ((u.weights[i] >> k) & 1) b[at >> 3] |= (char)(1 << (at & 7));
		}
	}
	if (u.planes == 2)
	{
		uint at = 128 - wbits - 2;
		put(&b, &at, (uint)u.ccs, 2);
	}
	out[:16] = b[..];
}

struct MapJob @local
{
	char[] blocks;
	char[] out;
	uint bw;
}

fn void map_row(void* ctx, usz by) @local
{
	MapJob* j = (MapJob*)ctx;
	for (uint bx = 0; bx < j.bw; bx++)
	{
		usz o = (by * j.bw + bx) * 16;
		map_block(j.blocks[o : 16], &j.out[o]);
	}
}

const usz MIN_BLOCKS_PER_THREAD @local = 4096;

<*
 Map a whole UASTC image to ASTC 4x4: `blocks` is ceil(w/4)*ceil(h/4) 16-byte
 UASTC blocks in raster order, the result the same count of ASTC blocks.

 @param [&inout] allocator : "Where the result is allocated"
 @param [in] blocks : "The UASTC payload of one image"
 @param threads : "Block rows' thread count: 0 decides from the job's size, 1 runs inline. The output is identical either way."
 @return? INVALID_SIZE
*>
fn char[]? map_image(Allocator allocator, char[] blocks, uint width, uint height, uint threads = 0)
{
	uint bw = (width + 3) / 4;
	uint bh = (height + 3) / 4;
	if (blocks.len != (usz)bw * bh * 16) return INVALID_SIZE~;
	init();
	char[] out = alloc::new_array(allocator, char, (sz)blocks.len);
	MapJob job = { .blocks = blocks, .out = out, .bw = bw };
	parallel::run(bh, &job, &map_row, parallel::shares((usz)bw * bh, MIN_BLOCKS_PER_THREAD, threads));
	return out;
}

<* Whether `init` found an ASTC seed for every UASTC pattern. For tests. *>
fn bool every_pattern_has_a_seed()
{
	init();
	foreach (p : part2) if (!p.ok) return false;
	foreach (p : part3) if (!p.ok) return false;
	foreach (p : part23) if (!p.ok) return false;
	return true;
}

<*
 The ASTC partition found for a UASTC pattern. For tests.

 @param count : "2 for the 2-subset table, 3 for the 3-subset one, 0 for mode 7's"
*>
fn Partition partition(uint count, uint pattern)
{
	init();
	switch (count)
	{
		case 2: return part2[pattern];
		case 3: return part3[pattern];
		default: return part23[pattern];
	}
}
