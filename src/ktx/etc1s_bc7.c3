// ETC1S -> BC7 block transcode (docs/basis-rewrite.md phase 3).
//
// An ETC1S block is a 5-bit base colour, one of eight intensity tables and a
// 2-bit selector per texel: four palette colours on a line through RGB, and
// an index per texel. BC7 is the same shape — endpoints, a weight grid, an
// index per texel — so the transcode is a rewrite of the fields, never a
// re-encode.
//
// Opaque blocks go to BC7 mode 6, whose 4-bit weight grid is fine enough to
// carry the ETC1 modifier spacing (which is roughly 0, 0.37, 0.63, 1 — not
// BC7's 2-bit 0, 0.33, 0.67, 1). The two interior selectors pick their
// nearest 4-bit weight and the endpoints are then least-squares fitted to the
// four palette colours, which is what absorbs both the grid step and the
// bending the intensity table's clamping puts in the line.
//
// A file with an alpha slice cannot use mode 6: its colour and alpha blocks
// have *different* selectors and mode 6 has one index per texel. Those go to
// mode 5, which carries a second index plane — 2-bit, so the colour side
// leans harder on the endpoint fit, and alpha gets 8-bit endpoints of its own.
module ktx::etc1s_bc7;
import ktx::etc1s, ktx::bc7, ktx::parallel;

faultdef INVALID_SIZE;

// [intensity table][5-bit base][selector] -> the palette value the ETC1S
// decoder produces. The whole codec's per-channel output, 1 KB of it.
char[4][32][8] pal_lut @local;

// Weight 0..64 -> nearest BC7 4-bit index, and 8-bit level -> 7-bit endpoint.
char[65] near4 @local;
char[256] q7 @local;

// The 2-bit weight grid mode 5 is stuck with, and its least-squares normal
// equations (constant, so they are solved once here rather than per block).
const long M5_A = 6386;
const long M5_B = 1806;
const long M5_C = 6386;
const long M5_DET = 37519360;

<* A codebook endpoint prepared as BC7 mode-6 fields: one per entry, not one per block. *>
struct EpM6
{
	char[4] idx;   // BC7 weight index per ETC1S selector
	char[3] lo;
	char[3] hi;
}

<* The same for mode 5, where the weight grid is fixed and only endpoints move. *>
struct EpM5
{
	char[3] lo;
	char[3] hi;
}

bool ready @local;

fn void init() @local
{
	if (ready) return;
	for (uint t = 0; t < 8; t++)
	{
		for (uint b = 0; b < 32; b++)
		{
			int base = (int)((b << 3) | (b >> 2));
			for (uint s = 0; s < 4; s++)
			{
				int v = base + etc1s::INTEN_TABLES[t][s];
				pal_lut[t][b][s] = (char)(v < 0 ? 0 : (v > 255 ? 255 : v));
			}
		}
	}
	for (uint w = 0; w <= 64; w++)
	{
		uint best;
		uint best_err = 1000;
		for (uint j = 0; j < 16; j++)
		{
			uint d = bc7::WEIGHTS4[j] > w ? bc7::WEIGHTS4[j] - w : w - bc7::WEIGHTS4[j];
			if (d < best_err) { best_err = d; best = j; }
		}
		near4[w] = (char)best;
	}
	for (uint t = 0; t < 256; t++)
	{
		uint best;
		uint best_err = 1000;
		for (uint v = 0; v < 128; v++)
		{
			uint d = bc7::dequant(v, 7);
			uint e = d > t ? d - t : t - d;
			if (e < best_err) { best_err = e; best = v; }
		}
		q7[t] = (char)best;
	}
	ready = true;
}

fn int clamp255(long v) @local
{
	return (int)(v < 0 ? 0 : (v > 255 ? 255 : v));
}

fn long nearest(double v) @local
{
	return (long)(v >= 0 ? v + 0.5 : v - 0.5);
}

<* Round a least-squares numerator, which can be negative, to the nearest int. *>
fn long divround(long num, long den) @local
{
	return num >= 0 ? (num + den / 2) / den : (num - den / 2) / den;
}

<*
 The endpoint pair reproducing four palette values at four weights, in the
 least-squares sense. `u` is the weight per selector on BC7's 0..64 scale;
 `a`/`b`/`c`/`det` are that grid's normal equations, passed in because a
 caller with a fixed grid has them as constants.
*>
fn void fit(char[4] pal, uint[4] u, long a, long b, long c, long det, int* lo, int* hi) @local
{
	long p;
	long q;
	for (uint s = 0; s < 4; s++)
	{
		p += (long)(64 - u[s]) * (long)pal[s];
		q += (long)u[s] * (long)pal[s];
	}
	// The normal equations are kept in 0..64 weight units, so the solution
	// comes back scaled down by that; multiply it back out.
	*lo = clamp255(divround((c * p - b * q) * 64, det));
	*hi = clamp255(divround((a * q - b * p) * 64, det));
}

<*
 One channel's mode-6 endpoint pair for a fixed weight placement: the
 least-squares answer, quantized onto the odd 8-bit grid the forced p-bit
 leaves. `refine` settles it against its own neighbours as well, which the
 continuous fit needs often enough to be worth the trials — but only for the
 placement that wins, since the comparison between placements is fair without
 it. Returns the squared error left over the four palette values.
*>
fn ulong fit_channel(char[4] pal, uint[4] u, uint mask, long a, long b, long cq, double inv,
	bool refine, char* lo, char* hi) @local
{
	long p;
	long q;
	for (uint s = 0; s < 4; s++)
	{
		p += (long)(64 - u[s]) * (long)pal[s];
		q += (long)u[s] * (long)pal[s];
	}
	int n0 = min(clamp255(nearest((double)(cq * p - b * q) * inv)) >> 1, 127);
	int n1 = min(clamp255(nearest((double)(a * q - b * p) * inv)) >> 1, 127);
	int reach = refine ? 2 : 0;
	int b0 = n0;
	int b1 = n1;
	ulong best = ~(ulong)0;
	for (int q0 = max(n0 - reach, 0); q0 <= min(n0 + reach, 127); q0++)
	{
		for (int q1 = max(n1 - reach, 0); q1 <= min(n1 + reach, 127); q1++)
		{
			ulong err;
			for (uint s = 0; s < 4; s++)
			{
				if (!((mask >> s) & 1)) continue;
				long e = (long)bc7::interp((uint)q0 * 2 + 1, (uint)q1 * 2 + 1, u[s]) - pal[s];
				err += (ulong)(e * e);
			}
			if (err < best)
			{
				best = err;
				b0 = q0;
				b1 = q1;
			}
		}
	}
	*lo = (char)b0;
	*hi = (char)b1;
	return best;
}

<*
 What one codebook endpoint becomes in BC7 mode 6: where its four palette
 colours sit on BC7's 4-bit weight grid, and the endpoint pair that
 reconstructs them. It depends on the endpoint and on `mask` — which of the
 four selectors the block actually uses, since a colour no texel asks for must
 not pull the fit — and on nothing else, which is why it is worked out once
 per (entry, mask) and then only looked up per block.

 The four palette colours sit at fixed fractions of the block's range —
 roughly 0, 0.37, 0.63, 1, bent wherever the intensity table clamps — and
 BC7's 4-bit grid has no step at 0.37. So this does not simply round to the
 nearest weight: it tries five placements of the four selectors on the grid
 (the full span, then four that pull them inwards so the endpoints extrapolate
 past the palette and the interior pair lands closer), fits endpoints to each,
 and keeps whichever reconstructs the palette best.
*>
fn EpM6 build_m6(etc1s::Endpoint ep, uint mask) @local
{
	char[4][3] pal;
	for (uint c = 0; c < 3; c++) pal[c] = pal_lut[ep.inten5][ep.color5[c]];

	long den;
	int[3] lo0;
	int[3] span;
	for (uint c = 0; c < 3; c++)
	{
		lo0[c] = pal[c][0];
		span[c] = (int)pal[c][3] - pal[c][0];
		den += (long)span[c] * span[c];
	}

	EpM6 out;
	if (den == 0)
	{
		for (uint c = 0; c < 3; c++)
		{
			out.lo[c] = (char)min(lo0[c] >> 1, 127);
			out.hi[c] = out.lo[c];
		}
		return out;
	}

	// Where each selector sits in the block's range, shared across the
	// channels because one index plane serves them all: the channel with the
	// widest range pulls hardest, which is what least squares says.
	long[4] at;
	at[3] = 64;
	for (uint s = 1; s < 3; s++)
	{
		long num;
		for (uint c = 0; c < 3; c++) num += (long)span[c] * ((long)pal[c][s] - lo0[c]);
		long w = divround(num * 64, den);
		at[s] = w < 0 ? 0 : (w > 64 ? 64 : w);
	}

	ulong best = ~(ulong)0;
	uint[4] best_u;
	char[5] widths = { 64, 56, 48, 40, 32 };
	foreach (width : widths)
	{
		uint off = (64 - width) / 2;
		char[4] j;
		uint[4] u;
		long a;
		long b;
		long cq;
		for (uint s = 0; s < 4; s++)
		{
			j[s] = near4[off + (uint)((at[s] * width) / 64)];
			u[s] = bc7::WEIGHTS4[j[s]];
			a += (long)(64 - u[s]) * (long)(64 - u[s]);
			b += (long)(64 - u[s]) * (long)u[s];
			cq += (long)u[s] * (long)u[s];
		}
		long det = a * cq - b * b;
		if (det <= 0) continue;
		double inv = 64.0 / (double)det;
		char[3] lo;
		char[3] hi;
		ulong sse;
		for (uint c = 0; c < 3; c++)
		{
			sse += fit_channel(pal[c], u, mask, a, b, cq, inv, false, &lo[c], &hi[c]);
		}
		if (sse < best)
		{
			best = sse;
			out.idx = j;
			out.lo = lo;
			out.hi = hi;
			best_u = u;
		}
	}

	// The winner, settled: the least-squares answer is continuous and the
	// endpoints are not, and the rounding goes the wrong way often enough.
	long a;
	long b;
	long cq;
	for (uint s = 0; s < 4; s++)
	{
		a += (long)(64 - best_u[s]) * (long)(64 - best_u[s]);
		b += (long)(64 - best_u[s]) * (long)best_u[s];
		cq += (long)best_u[s] * (long)best_u[s];
	}
	double inv = 64.0 / (double)(a * cq - b * b);
	for (uint c = 0; c < 3; c++)
	{
		fit_channel(pal[c], best_u, mask, a, b, cq, inv, true, &out.lo[c], &out.hi[c]);
	}
	return out;
}

<*
 One channel's mode-5 endpoint pair. The 2-bit grid is fixed, so only the
 endpoints can absorb the palette's shape: least squares, quantized (7 bits
 for colour, 8 for alpha), then settled against its neighbours.
*>
fn void fit_channel5(char[4] pal, uint mask, bool seven_bit, char* lo, char* hi) @local
{
	uint[4] u = { 0, 21, 43, 64 };
	int l;
	int h;
	fit(pal, u, M5_A, M5_B, M5_C, M5_DET, &l, &h);
	int top = seven_bit ? 127 : 255;
	int n0 = seven_bit ? q7[l] : l;
	int n1 = seven_bit ? q7[h] : h;
	int b0 = n0;
	int b1 = n1;
	ulong best = ~(ulong)0;
	for (int q0 = max(n0 - 2, 0); q0 <= min(n0 + 2, top); q0++)
	{
		uint a = seven_bit ? bc7::dequant((uint)q0, 7) : (uint)q0;
		for (int q1 = max(n1 - 2, 0); q1 <= min(n1 + 2, top); q1++)
		{
			uint b = seven_bit ? bc7::dequant((uint)q1, 7) : (uint)q1;
			ulong err;
			for (uint s = 0; s < 4; s++)
			{
				if (!((mask >> s) & 1)) continue;
				long e = (long)bc7::interp(a, b, u[s]) - pal[s];
				err += (ulong)(e * e);
			}
			if (err < best)
			{
				best = err;
				b0 = q0;
				b1 = q1;
			}
		}
	}
	*lo = (char)b0;
	*hi = (char)b1;
}

<* One codebook endpoint as mode-5 colour endpoints (7-bit, fixed 2-bit grid). *>
fn EpM5 build_m5(etc1s::Endpoint ep, uint mask) @local
{
	EpM5 out;
	for (uint c = 0; c < 3; c++)
	{
		fit_channel5(pal_lut[ep.inten5][ep.color5[c]], mask, true, &out.lo[c], &out.hi[c]);
	}
	return out;
}

<*
 One codebook endpoint as mode-5 alpha endpoints (8-bit). Alpha slices carry
 the value in the green channel.
*>
fn EpM5 build_m5_alpha(etc1s::Endpoint ep, uint mask) @local
{
	EpM5 out;
	fit_channel5(pal_lut[ep.inten5][ep.color5[1]], mask, false, &out.lo[0], &out.hi[0]);
	return out;
}

<*
 One opaque ETC1S block as BC7 mode 6, from its endpoint's prepared fields and
 its selectors. Both p-bits are 1, which makes alpha exactly 255 and leaves
 the colour endpoints an odd 8-bit grid to sit on.
*>
fn void map_opaque(EpM6* e, etc1s::Selector sel, char* out) @local
{
	bc7::BlockFields f;
	f.mode = 6;
	f.pbits[0] = 1;
	f.pbits[1] = 1;
	f.ep[0][3] = 127;
	f.ep[1][3] = 127;
	for (uint c = 0; c < 3; c++)
	{
		f.ep[0][c] = e.lo[c];
		f.ep[1][c] = e.hi[c];
	}
	for (uint y = 0; y < 4; y++)
	{
		uint row = sel.rows[y];
		for (uint x = 0; x < 4; x++) f.idx[y * 4 + x] = e.idx[(row >> (x * 2)) & 3];
	}
	if (f.idx[0] >= 8)
	{
		for (uint c = 0; c < 4; c++)
		{
			char t = f.ep[0][c];
			f.ep[0][c] = f.ep[1][c];
			f.ep[1][c] = t;
		}
		for (uint i = 0; i < 16; i++) f.idx[i] = (char)(15 - f.idx[i]);
	}
	bc7::pack_fields(out, &f);
}

<*
 One ETC1S block pair (colour slice + alpha slice) as BC7 mode 5: 7-bit colour
 endpoints on the fixed 2-bit grid, 8-bit alpha endpoints on a second index
 plane of its own, and each slice's selectors used directly as its indices.
 Mode 6 is not available here — the two slices have different selectors and
 mode 6 has one index per texel.
*>
fn void map_alpha(EpM5* col, EpM5* alpha, etc1s::Selector sel, etc1s::Selector asel, char* out) @local
{
	bc7::BlockFields f;
	f.mode = 5;
	for (uint c = 0; c < 3; c++)
	{
		f.ep[0][c] = col.lo[c];
		f.ep[1][c] = col.hi[c];
	}
	f.ep[0][3] = alpha.lo[0];
	f.ep[1][3] = alpha.hi[0];
	for (uint y = 0; y < 4; y++)
	{
		uint row = sel.rows[y];
		uint arow = asel.rows[y];
		for (uint x = 0; x < 4; x++)
		{
			f.idx[y * 4 + x] = (char)((row >> (x * 2)) & 3);
			f.idx2[y * 4 + x] = (char)((arow >> (x * 2)) & 3);
		}
	}
	if (f.idx[0] >= 2)
	{
		for (uint c = 0; c < 3; c++)
		{
			char t = f.ep[0][c];
			f.ep[0][c] = f.ep[1][c];
			f.ep[1][c] = t;
		}
		for (uint i = 0; i < 16; i++) f.idx[i] = (char)(3 - f.idx[i]);
	}
	if (f.idx2[0] >= 2)
	{
		char t = f.ep[0][3];
		f.ep[0][3] = f.ep[1][3];
		f.ep[1][3] = t;
		for (uint i = 0; i < 16; i++) f.idx2[i] = (char)(3 - f.idx2[i]);
	}
	bc7::pack_fields(out, &f);
}

struct MapJob @local
{
	etc1s::BlockRef[] rgb;
	etc1s::BlockRef[] alpha;
	EpM6[] m6;
	EpM5[] m5;
	EpM5[] m5a;
	etc1s::Selector[] selectors;
	char[] masks;   // selector index -> its 4-bit mask
	char[] out;
	uint nbx;
	bool has_alpha;
}

<* Which of the four selectors a block uses, as a 4-bit mask (never 0). *>
fn uint sel_mask(etc1s::Selector sel) @local
{
	uint mask;
	for (uint y = 0; y < 4; y++)
	{
		uint row = sel.rows[y];
		for (uint x = 0; x < 4; x++) mask |= 1u << ((row >> (x * 2)) & 3);
	}
	return mask;
}

fn void map_row(void* ctx, usz by) @local
{
	MapJob* j = (MapJob*)ctx;
	for (uint bx = 0; bx < j.nbx; bx++)
	{
		usz i = by * j.nbx + bx;
		etc1s::BlockRef r = j.rgb[i];
		etc1s::Selector sel = j.selectors[r.selector];
		if (j.has_alpha)
		{
			etc1s::BlockRef a = j.alpha[i];
			etc1s::Selector asel = j.selectors[a.selector];
			map_alpha(&j.m5[(usz)r.endpoint * 16 + j.masks[r.selector]],
				&j.m5a[(usz)a.endpoint * 16 + j.masks[a.selector]], sel, asel, &j.out[i * 16]);
		}
		else
		{
			map_opaque(&j.m6[(usz)r.endpoint * 16 + j.masks[r.selector]], sel, &j.out[i * 16]);
		}
	}
}

struct PrepJob @local
{
	etc1s::Endpoint[] endpoints;
	uint[] slots;   // the (endpoint * 16 + mask) slots this image asks for
	EpM6[] m6;
	EpM5[] m5;
	EpM5[] m5a;
	bool alpha_pass;
	bool has_alpha;
}

fn void prep_endpoint(void* ctx, usz i) @local
{
	PrepJob* j = (PrepJob*)ctx;
	uint slot = j.slots[i];
	uint mask = slot & 15;
	usz ep = (usz)(slot >> 4);
	if (!j.has_alpha)
	{
		j.m6[slot] = build_m6(j.endpoints[ep], mask);
	}
	else if (j.alpha_pass)
	{
		j.m5a[slot] = build_m5_alpha(j.endpoints[ep], mask);
	}
	else
	{
		j.m5[slot] = build_m5(j.endpoints[ep], mask);
	}
}

<*
 The distinct (endpoint, selector mask) slots a set of blocks refers to.
 Collected rather than swept, because a deep mip level asks for a handful of
 them out of a codebook's thousands and should not pay for the rest.
*>
fn uint[] wanted_slots(etc1s::BlockRef[] blocks, char[] masks, bool[] seen, Allocator scratch) @local
{
	uint[] slots = alloc::alloc_array(scratch, uint, (sz)blocks.len);
	usz n;
	foreach (r : blocks)
	{
		uint slot = (uint)r.endpoint * 16 + masks[r.selector];
		if (seen[slot]) continue;
		seen[slot] = true;
		slots[n++] = slot;
	}
	return slots[:n];
}

const usz MIN_BLOCKS_PER_THREAD @local = 4096;
const usz MIN_ENDPOINTS_PER_THREAD @local = 256;

<*
 Map one image of an ETC1S file to BC7 blocks. `alpha_slice` is empty for a
 file without one.

 Three passes, and the middle one is the point. The slice streams are one
 Huffman bitstream each with cross-block prediction, so they are walked
 serially into per-block codebook indices first. Then every (endpoint,
 selector mask) the image uses is turned into BC7 fields once — that is all
 the arithmetic there is, and a codebook has orders of magnitude fewer entries
 than an image has blocks. What is left per block is a table lookup and
 sixteen indices, which is what runs across `threads` threads (0 = decide from
 the job's size, 1 = inline).
*>
fn char[]? map_image(Allocator allocator, etc1s::Codebook* cb, char[] rgb_slice, char[] alpha_slice,
	uint width, uint height, Allocator scratch, uint threads = 0)
{
	uint nbx = (width + 3) / 4;
	uint nby = (height + 3) / 4;
	if (!nbx || !nby) return INVALID_SIZE~;
	init();

	usz count = (usz)nbx * nby;
	bool has_alpha = alpha_slice.len != 0;
	etc1s::BlockRef[] rgb = alloc::new_array(scratch, etc1s::BlockRef, (sz)count);
	cb.decode_slice_blocks(rgb_slice, nbx, nby, rgb, scratch)!;
	etc1s::BlockRef[] alpha;
	if (has_alpha)
	{
		alpha = alloc::new_array(scratch, etc1s::BlockRef, (sz)count);
		cb.decode_slice_blocks(alpha_slice, nbx, nby, alpha, scratch)!;
	}

	char[] masks = alloc::alloc_array(scratch, char, (sz)cb.selectors.len);
	foreach (i, sel : cb.selectors) masks[i] = (char)sel_mask(sel);

	sz slot_count = (sz)cb.endpoints.len * 16;
	bool[] seen = alloc::new_array(scratch, bool, slot_count);
	uint[] rgb_slots = wanted_slots(rgb, masks, seen, scratch);
	uint[] alpha_slots;
	EpM6[] m6;
	EpM5[] m5;
	EpM5[] m5a;
	PrepJob prep = { .endpoints = cb.endpoints, .has_alpha = has_alpha };
	if (has_alpha)
	{
		bool[] seen_alpha = alloc::new_array(scratch, bool, slot_count);
		alpha_slots = wanted_slots(alpha, masks, seen_alpha, scratch);
		m5 = alloc::alloc_array(scratch, EpM5, slot_count);
		m5a = alloc::alloc_array(scratch, EpM5, slot_count);
		prep.m5 = m5;
		prep.m5a = m5a;
	}
	else
	{
		m6 = alloc::alloc_array(scratch, EpM6, slot_count);
		prep.m6 = m6;
	}

	prep.slots = rgb_slots;
	parallel::run(rgb_slots.len, &prep, &prep_endpoint,
		parallel::shares(rgb_slots.len, MIN_ENDPOINTS_PER_THREAD, threads));
	if (has_alpha)
	{
		prep.slots = alpha_slots;
		prep.alpha_pass = true;
		parallel::run(alpha_slots.len, &prep, &prep_endpoint,
			parallel::shares(alpha_slots.len, MIN_ENDPOINTS_PER_THREAD, threads));
	}

	char[] out = alloc::new_array(allocator, char, (sz)(count * 16));
	MapJob job = {
		.rgb = rgb, .alpha = alpha, .m6 = m6, .m5 = m5, .m5a = m5a,
		.selectors = cb.selectors, .masks = masks, .out = out, .nbx = nbx, .has_alpha = has_alpha,
	};
	parallel::run(nby, &job, &map_row, parallel::shares(count, MIN_BLOCKS_PER_THREAD, threads));
	return out;
}
