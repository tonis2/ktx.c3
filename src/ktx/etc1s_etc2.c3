<*
 ETC1S -> ETC1 / ETC2 block transcode: what a GPU without BC7 (Adreno, Mali)
 samples an ETC1S texture as, in place of decoded RGBA8.

 An ETC1S block already is an ETC1 block: differential mode with no delta, one
 colour and one intensity table for both halves. So the colour is rewritten
 field by field and decodes to exactly what `etc1s::Codebook.decode_slice`
 gives. ETC2 RGB reads ETC1 blocks unchanged.

 Alpha goes to EAC A8, which is not always exact: an ETC1S alpha block is four
 levels at a fixed spread around one value, EAC a base, a multiplier, a table
 of eight modifiers and a 3-bit index per texel. The best EAC block depends
 only on the alpha endpoint's level and table and on which of the four
 selectors the block uses, so it is searched once per such key an image asks
 for and looked up per block, as ktx::etc1s_bc7 does for BC7.
*>
module ktx::etc1s_etc2;
import ktx::etc1s, ktx::etc2, ktx::parallel;
import std::thread, std::math;

excuse INVALID_SIZE;

<* What `map_image` writes per block. *>
enum Target : char (uint block_bytes)
{
	// The colour slice alone; an alpha slice is ignored.
	ETC1_RGB { 8 },
	// EAC A8, then that ETC1 block. A file without alpha gets 255.
	ETC2_RGBA { 16 },
}

// ETC1 pixel index per ETC1S selector. The selectors run from the large
// negative modifier up; ETC1 stores +small, +large, -small, -large.
const char[4] ETC1_INDEX @local = { 3, 2, 0, 1 };

// Alpha 255 everywhere: base 255, table 13 (whose index 4 adds 0), multiplier 1.
const char[8] OPAQUE_ALPHA @local = { 0xFF, 0x1D, 0x92, 0x49, 0x24, 0x92, 0x49, 0x24 };

<* An EAC A8 block's fields, and the 3-bit index each ETC1S selector becomes. *>
struct Eac @local
{
	char base;
	<* The multiplier in the high nibble, the table in the low one, as stored. *>
	char table_mul;
	char[4] idx;
}

// [table][multiplier - 1][d + 255] -> the distance from d to the table's nearest
// modifier at that multiplier. What the search asks for every base it tries.
char[511][15][16] nearest @local;
OnceFlag nearest_once @local;

fn void init() @local
{
	nearest_once.call(fn void() {
		for (uint t = 0; t < 16; t++)
		{
			for (int m = 1; m <= 15; m++)
			{
				for (int d = -255; d <= 255; d++)
				{
					int best = 255;
					foreach (o : etc2::EAC_MODIFIERS[t]) best = min(best, math::abs(o * m - d));
					nearest[t][m - 1][d + 255] = (char)best;
				}
			}
		}
	});
}

fn int clamp255(int v) @local @inline => v < 0 ? 0 : (v > 255 ? 255 : v);

<* The alpha levels an ETC1S alpha endpoint decodes to, per selector; non-decreasing. *>
fn char[4] alpha_levels(etc1s::Endpoint ep) @local
{
	int g = ep.color5[1] << 3 | ep.color5[1] >> 2;
	char[4] pal;
	for (uint s = 0; s < 4; s++) pal[s] = (char)clamp255(g + etc1s::INTEN_TABLES[ep.inten5][s]);
	return pal;
}

<*
 The EAC A8 fields closest to four alpha levels, in squared error over the
 selectors in `mask`.

 Every table and multiplier is tried, and every base that could still beat the
 best so far: one that puts the lowest level, or the highest, further away than
 the best total error allows is skipped, as is a table whose modifiers span too
 little to reach both. Clamping at 0 and 255 is a level the block can always
 hit when its modifiers go past the end, which matters for alpha, where 0 and
 255 are the common values.
*>
fn Eac fit_eac(char[4] pal, uint mask) @local
{
	// The distinct levels asked for, ascending since the palette is.
	int[4] v;
	uint k;
	for (uint s = 0; s < 4; s++)
	{
		if (!((mask >> s) & 1) || (k && v[k - 1] == pal[s])) continue;
		v[k++] = pal[s];
	}

	int best_t = 13;
	int best_m = 1;
	int best_b = v[0];
	if (k > 1)
	{
		int span = v[k - 1] - v[0];
		ulong best = ulong::max;
		for SEARCH: (int t = 0; t < 16; t++)
		{
			for (int m = 1; m <= 15; m++)
			{
				int lo = etc2::EAC_MODIFIERS[t][3] * m;
				int hi = etc2::EAC_MODIFIERS[t][7] * m;
				// The lowest and highest levels can't both be reached: their errors add up to gap² / 2 at least.
				int gap = span - (hi - lo);
				if (gap > 0 && best != ulong::max && (ulong)(gap * gap) >= 2 * best) continue;
				int r = best == ulong::max ? 255 : (int)math::sqrt((double)best);
				int b_lo = max(0, v[k - 1] - r - hi);
				int b_hi = min(255, v[0] + r - lo);
				char[511]* near = &nearest[t][m - 1];
				for (int b = b_lo; b <= b_hi; b++)
				{
					bool low = b + lo <= 0;
					bool high = b + hi >= 255;
					ulong err;
					for (uint j = 0; j < k; j++)
					{
						int e = (*near)[v[j] - b + 255];
						e *= e;
						if (low) e = min(e, v[j] * v[j]);
						if (high) e = min(e, (255 - v[j]) * (255 - v[j]));
						err += (ulong)e;
						if (err >= best) break;
					}
					if (err >= best) continue;
					best = err;
					best_t = t;
					best_m = m;
					best_b = b;
					if (!best) break SEARCH;
				}
			}
		}
	}

	Eac out = { .base = (char)best_b, .table_mul = (char)(best_m << 4 | best_t) };
	for (uint s = 0; s < 4; s++)
	{
		int best_e = int::max;
		for (uint i = 0; i < 8; i++)
		{
			int e = math::abs(clamp255(best_b + etc2::EAC_MODIFIERS[best_t][i] * best_m) - pal[s]);
			if (e >= best_e) continue;
			best_e = e;
			out.idx[s] = (char)i;
		}
	}
	return out;
}

<* Which of the four selectors a block uses, as a 4-bit mask (never 0). *>
fn uint sel_mask(etc1s::Selector sel) @local
{
	uint mask;
	for (uint y = 0; y < 4; y++)
	{
		for (uint x = 0; x < 4; x++) mask |= 1u << ((sel.rows[y] >> (x * 2)) & 3);
	}
	return mask;
}

<* A selector as ETC1's two index planes: msb plane << 16 | lsb plane, texel (x, y) at bit x * 4 + y. *>
fn uint etc1_indices(etc1s::Selector sel) @local
{
	uint msb;
	uint lsb;
	for (uint y = 0; y < 4; y++)
	{
		for (uint x = 0; x < 4; x++)
		{
			uint e = ETC1_INDEX[(sel.rows[y] >> (x * 2)) & 3];
			msb |= (e >> 1) << (x * 4 + y);
			lsb |= (e & 1) << (x * 4 + y);
		}
	}
	return msb << 16 | lsb;
}

<* An ETC1 differential block with zero delta: the endpoint in both halves, no flip. *>
fn void pack_etc1(etc1s::Endpoint ep, uint indices, char* out) @local
{
	out[0] = ep.color5[0] << 3;
	out[1] = ep.color5[1] << 3;
	out[2] = ep.color5[2] << 3;
	out[3] = ep.inten5 << 5 | ep.inten5 << 2 | 2;
	out[4] = (char)(indices >> 24);
	out[5] = (char)(indices >> 16);
	out[6] = (char)(indices >> 8);
	out[7] = (char)indices;
}

fn void pack_eac(Eac* e, etc1s::Selector sel, char* out) @local
{
	ulong bits;
	for (uint y = 0; y < 4; y++)
	{
		for (uint x = 0; x < 4; x++)
		{
			bits |= (ulong)e.idx[(sel.rows[y] >> (x * 2)) & 3] << (45 - 3 * (x * 4 + y));
		}
	}
	out[0] = e.base;
	out[1] = e.table_mul;
	for (uint i = 0; i < 6; i++) out[2 + i] = (char)(bits >> (40 - 8 * i));
}

<* The search key of an alpha block: the endpoint's level and table, and the selectors used. *>
fn uint alpha_key(etc1s::Endpoint ep, uint mask) @local => ((uint)ep.color5[1] << 3 | ep.inten5) << 4 | mask;

// 32 levels, 8 tables, 16 selector masks.
const uint KEYS @local = 32 * 8 * 16;

<*
 One ETC1S colour block as an ETC1 block, which decodes to the same texels.

 @param ep : "The block's endpoint"
 @param sel : "The block's selector"
 @param [out] out : "8 bytes"
*>
fn void map_colour_block(etc1s::Endpoint ep, etc1s::Selector sel, char* out)
{
	pack_etc1(ep, etc1_indices(sel), out);
}

<*
 One ETC1S alpha block as the EAC A8 block `map_image` writes for it: the
 closest to its alpha levels, in squared error over the selectors it uses.

 @param ep : "The alpha block's endpoint; its green channel is the alpha"
 @param sel : "The alpha block's selector"
 @param [out] out : "8 bytes"
*>
fn void map_alpha_block(etc1s::Endpoint ep, etc1s::Selector sel, char* out)
{
	init();
	Eac e = fit_eac(alpha_levels(ep), sel_mask(sel));
	pack_eac(&e, sel, out);
}

struct PrepJob @local
{
	uint[] keys;
	Eac[] eac;   // by key
}

fn void prep_key(void* ctx, usz i) @local
{
	PrepJob* j = (PrepJob*)ctx;
	uint key = j.keys[i];
	etc1s::Endpoint ep = { .color5 = { 0, (char)(key >> 7), 0 }, .inten5 = (char)(key >> 4 & 7) };
	j.eac[key] = fit_eac(alpha_levels(ep), key & 15);
}

struct MapJob @local
{
	etc1s::Codebook* cb;
	etc1s::BlockRef[] rgb;
	etc1s::BlockRef[] alpha;   // empty without an alpha slice
	uint[] indices;            // selector index -> its ETC1 index planes
	char[] masks;              // selector index -> its 4-bit mask
	Eac[] eac;                 // alpha key -> its EAC block
	char[] out;
	Target target;
	uint nbx;
}

fn void map_row(void* ctx, usz by) @local
{
	MapJob* j = (MapJob*)ctx;
	uint bytes = j.target.block_bytes;
	for (uint bx = 0; bx < j.nbx; bx++)
	{
		usz i = by * j.nbx + bx;
		char* out = &j.out[i * bytes];
		if (j.target == ETC2_RGBA)
		{
			if (j.alpha.len)
			{
				etc1s::BlockRef a = j.alpha[i];
				pack_eac(&j.eac[alpha_key(j.cb.endpoints[a.endpoint], j.masks[a.selector])], j.cb.selectors[a.selector], out);
			}
			else
			{
				out[:8] = OPAQUE_ALPHA[..];
			}
			out += 8;
		}
		etc1s::BlockRef r = j.rgb[i];
		pack_etc1(j.cb.endpoints[r.endpoint], j.indices[r.selector], out);
	}
}

const usz MIN_BLOCKS_PER_THREAD @local = 4096;
const usz MIN_KEYS_PER_THREAD @local = 16;

<*
 Map one image of an ETC1S file to ETC1 or ETC2 RGBA blocks.

 The slices are walked serially into codebook indices, since each is one
 Huffman stream with cross-block prediction. For RGBA, the EAC search then runs
 once for every alpha key the image uses, across threads; a codebook's keys are
 few next to an image's blocks. What is left per block is a lookup and the
 sixteen indices, which runs across threads by block row.

 @param [&inout] allocator : "Where the blocks are allocated"
 @param [&in] cb : "The file's codebook"
 @param [in] rgb_slice : "The image's colour slice"
 @param [in] alpha_slice : "Its alpha slice, empty when the file has none"
 @param target : "ETC1 colour alone, or EAC alpha and ETC1 colour"
 @param [&inout] scratch : "Holds the codebook indices and the EAC table until the call returns"
 @param threads : "Thread count: 0 decides from the job's size, 1 runs inline. The output is identical either way."
 @return "ceil(width / 4) * ceil(height / 4) blocks of target.block_bytes, row by row"
 @return? INVALID_SIZE, etc1s::INVALID_STREAM, etc1s::INVALID_DIMENSIONS
*>
fn char[]? map_image(Allocator allocator, etc1s::Codebook* cb, char[] rgb_slice, char[] alpha_slice,
	uint width, uint height, Target target, Allocator scratch, uint threads = 0)
{
	uint nbx = (width + 3) / 4;
	uint nby = (height + 3) / 4;
	if (!nbx || !nby) return INVALID_SIZE~;
	usz count = (usz)nbx * nby;

	etc1s::BlockRef[] rgb = alloc::new_array(scratch, etc1s::BlockRef, (sz)count);
	cb.decode_slice_blocks(rgb_slice, nbx, nby, rgb, scratch)!;
	uint[] indices = alloc::alloc_array(scratch, uint, (sz)cb.selectors.len);
	foreach (i, sel : cb.selectors) indices[i] = etc1_indices(sel);

	MapJob job = { .cb = cb, .rgb = rgb, .indices = indices, .target = target, .nbx = nbx };
	if (target == ETC2_RGBA && alpha_slice.len)
	{
		init();
		job.alpha = alloc::new_array(scratch, etc1s::BlockRef, (sz)count);
		cb.decode_slice_blocks(alpha_slice, nbx, nby, job.alpha, scratch)!;
		job.masks = alloc::alloc_array(scratch, char, (sz)cb.selectors.len);
		foreach (i, sel : cb.selectors) job.masks[i] = (char)sel_mask(sel);

		// The keys this image asks for, each once.
		bool[KEYS] seen;
		uint[] keys = alloc::alloc_array(scratch, uint, (sz)KEYS);
		usz n;
		foreach (a : job.alpha)
		{
			uint key = alpha_key(cb.endpoints[a.endpoint], job.masks[a.selector]);
			if (seen[key]) continue;
			seen[key] = true;
			keys[n++] = key;
		}
		job.eac = alloc::alloc_array(scratch, Eac, (sz)KEYS);
		PrepJob prep = { .keys = keys[:n], .eac = job.eac };
		parallel::run(n, &prep, &prep_key, parallel::shares(n, MIN_KEYS_PER_THREAD, threads));
	}

	job.out = alloc::new_array(allocator, char, (sz)(count * target.block_bytes));
	parallel::run(nby, &job, &map_row, parallel::shares(count, MIN_BLOCKS_PER_THREAD, threads));
	return job.out;
}
