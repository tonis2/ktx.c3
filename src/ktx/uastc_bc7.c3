// UASTC 4x4 -> BC7 block transcode (docs/basis-rewrite.md phase 3), the
// mapper the decode-then-encode path was standing in for.
//
// UASTC was designed as a BC7 subset: each of its 19 LDR modes has a BC7 mode
// with the same subset count, plane count and weight grid, and its partition
// tables are the ASTC patterns BC7 also has. So a block becomes a block — the
// mode is looked up, the endpoints are requantized into the BC7 mode's own
// precision and the weights are remapped index by index. No pixel is ever
// built, which is what makes this ~100x cheaper than encoding.
//
// It is near-lossless rather than lossless, for three reasons, each bounded:
//   * ASTC interpolates through 16-bit endpoints (`l * 257`) and BC7 through
//     8-bit ones, so the same endpoints and weight differ by at most 1;
//   * BC7 endpoints carry a p-bit shared by all channels of an endpoint (or
//     by a whole subset), so an 8-bit UASTC endpoint lands within 1;
//   * the 4- and 5-bit ASTC weight tables are not BC7's, so modes 0/10/15/18
//     (and the 3-bit modes 5/12, which have no 1-subset BC7 home) pick the
//     nearest BC7 weight, worth up to 2/64 of the endpoint span.
// The transcode hint bits UASTC carries for this are ignored — files this
// library writes leave them zero.
module ktx::uastc_bc7;
import ktx::uastc, ktx::bc7, ktx::parallel;

faultdef INVALID_SIZE;

// BC7 mode per UASTC mode. 1-subset RGB/RGBA -> 6, dual-plane and solid -> 5,
// 2-subset -> 1 (3-bit weights), 3 (RGB) or 7 (with alpha), 3-subset -> 2.
// UASTC mode 7's 2-subset patterns are BC7 3-subset patterns with two subsets
// merged, so it goes to mode 2 as well.
//
// Mode 5 is the odd one: 1 subset of RGB on a 3-bit weight grid, which BC7
// only has in its 2-subset mode 1. It goes there with both subsets given the
// same endpoints — a partition that says nothing, bought for exact weights,
// which beats mode 6's finer endpoints on a grid that does not line up.
const char[19] TO_BC7 = { 6, 6, 1, 2, 3, 1, 5, 2, 5, 7, 6, 5, 6, 5, 6, 6, 7, 5, 6 };

// Third slot of the p-bit dimension below: quantize with no p-bit at all.
const uint QP_NONE = 2;

// [endpoint bits][p-bit 0/1/none][target] -> quantized value and its error.
char[256][3][8] qval @local;
char[256][3][8] qerr @local;

// [BC7 index bits - 2][UASTC weight bits - 1][weight index] -> BC7 index.
char[32][5][3] wremap @local;

// A UASTC partition pattern as a BC7 one: `sub[j]` is the UASTC subset BC7
// subset j takes its endpoints from.
struct PartMap @local
{
	char part;
	char[3] sub;
	bool ok;
}
PartMap[uastc::TOTAL_PATTERNS2] part2 @local;
PartMap[uastc::TOTAL_PATTERNS3] part3 @local;
PartMap[uastc::TOTAL_PATTERNS2_3] part23 @local;

// Solid blocks: the mode-5 colour endpoint pair reproducing each 8-bit level
// at colour index 0 or 1, and how far off it is when none does exactly.
char[256][2] solid_lo @local;
char[256][2] solid_hi @local;
char[256][2] solid_err @local;

bool ready @local;

fn uint astc_weight(uint i, uint bits) @local
{
	switch (bits)
	{
		case 1: return uastc::WEIGHTS1[i];
		case 2: return uastc::WEIGHTS2[i];
		case 3: return uastc::WEIGHTS3[i];
		case 4: return uastc::WEIGHTS4[i];
		default: return uastc::WEIGHTS5[i];
	}
}

<* The BC7 partition (and subset relabeling) matching a 2-subset ASTC pattern. *>
fn PartMap find2(char[] pat) @local
{
	for (uint p = 0; p < 64; p++)
	{
		for (uint swap = 0; swap < 2; swap++)
		{
			bool hit = true;
			for (uint i = 0; i < 16; i++)
			{
				if (pat[i] != (bc7::PARTITION2[p * 16 + i] ^ (char)swap)) { hit = false; break; }
			}
			if (hit) return { .part = (char)p, .sub = { (char)swap, (char)(1 - swap), 0 }, .ok = true };
		}
	}
	return {};
}

<*
 The BC7 3-subset partition matching an ASTC pattern of `labels` subsets. With
 labels == 2 this finds the 3-subset BC7 partitions that collapse onto a
 2-subset ASTC pattern — which is exactly what UASTC mode 7's table is.
*>
fn PartMap find3(char[] pat, uint labels) @local
{
	uint maps = labels * labels * labels;
	for (uint p = 0; p < 64; p++)
	{
		for (uint m = 0; m < maps; m++)
		{
			char[3] sub = { (char)(m % labels), (char)((m / labels) % labels), (char)(m / (labels * labels)) };
			uint used;
			for (uint j = 0; j < 3; j++) used |= 1u << sub[j];
			if (used != (1u << labels) - 1) continue;
			bool hit = true;
			for (uint i = 0; i < 16; i++)
			{
				if (pat[i] != sub[bc7::PARTITION3[p * 16 + i]]) { hit = false; break; }
			}
			if (hit) return { .part = (char)p, .sub = sub, .ok = true };
		}
	}
	return {};
}

<*
 Build the requantization, weight-remap, partition and solid-block tables.
 Called once from `map_image` before it goes parallel; not thread-safe.
*>
fn void init() @local
{
	if (ready) return;

	for (uint bits = 5; bits <= 7; bits++)
	{
		for (uint p = 0; p < 3; p++)
		{
			for (uint t = 0; t < 256; t++)
			{
				uint best;
				uint best_err = 1000;
				for (uint v = 0; v < (1u << bits); v++)
				{
					uint d = p == QP_NONE ? bc7::dequant(v, bits) : bc7::dequant_p(v, p, bits);
					uint err = d > t ? d - t : t - d;
					if (err < best_err) { best_err = err; best = v; }
				}
				qval[bits][p][t] = (char)best;
				qerr[bits][p][t] = (char)best_err;
			}
		}
	}

	for (uint db = 2; db <= 4; db++)
	{
		for (uint sb = 1; sb <= 5; sb++)
		{
			for (uint i = 0; i < (1u << sb); i++)
			{
				uint w = astc_weight(i, sb);
				uint best;
				uint best_err = 1000;
				for (uint j = 0; j < (1u << db); j++)
				{
					uint bw = bc7::weight_val(db, j);
					uint err = bw > w ? bw - w : w - bw;
					if (err < best_err) { best_err = err; best = j; }
				}
				wremap[db - 2][sb - 1][i] = (char)best;
			}
		}
	}

	for (uint k = 0; k < uastc::TOTAL_PATTERNS2; k++) part2[k] = find2(uastc::PATTERNS2[k * 16 : 16]);
	for (uint k = 0; k < uastc::TOTAL_PATTERNS3; k++) part3[k] = find3(uastc::PATTERNS3[k * 16 : 16], 3);
	for (uint k = 0; k < uastc::TOTAL_PATTERNS2_3; k++) part23[k] = find3(uastc::PATTERNS2_3[k * 16 : 16], 2);

	for (uint i = 0; i < 2; i++)
	{
		for (uint t = 0; t < 256; t++) solid_err[i][t] = 255;
		uint w = bc7::WEIGHTS2[i];
		for (uint lo = 0; lo < 128; lo++)
		{
			uint dl = bc7::dequant(lo, 7);
			for (uint hi = 0; hi < 128; hi++)
			{
				uint v = bc7::interp(dl, bc7::dequant(hi, 7), w);
				if (solid_err[i][v] != 0)
				{
					solid_err[i][v] = 0;
					solid_lo[i][v] = (char)lo;
					solid_hi[i][v] = (char)hi;
				}
			}
		}
		// Levels no pair hits exactly take the nearest one that is hit.
		for (uint t = 0; t < 256; t++)
		{
			if (solid_err[i][t] == 0) continue;
			for (uint d = 1; d < 256; d++)
			{
				if (t >= d && solid_err[i][t - d] == 0)
				{
					solid_lo[i][t] = solid_lo[i][t - d];
					solid_hi[i][t] = solid_hi[i][t - d];
					solid_err[i][t] = (char)d;
					break;
				}
				if (t + d < 256 && solid_err[i][t + d] == 0)
				{
					solid_lo[i][t] = solid_lo[i][t + d];
					solid_hi[i][t] = solid_hi[i][t + d];
					solid_err[i][t] = (char)d;
					break;
				}
			}
		}
	}

	ready = true;
}

<*
 Cost of a p-bit choice for one endpoint: the requantization error it leaves
 on each channel, with alpha counted double so an opaque block keeps its 255.
*>
fn uint ep_cost(uint bits, uint p, char[4] v, uint comps) @local
{
	uint sum;
	for (uint c = 0; c < comps; c++) sum += (uint)qerr[bits][p][v[c]] * (c == 3 ? 2u : 1u);
	return sum;
}

fn uint bc7_subset(uint nsub, uint part, uint texel) @local
{
	if (nsub == 1) return 0;
	return nsub == 2 ? bc7::PARTITION2[part * 16 + texel] : bc7::PARTITION3[part * 16 + texel];
}

<*
 ASTC's own interpolation of two 8-bit endpoints — the value the UASTC decoder
 would produce. It runs through 16-bit endpoints where BC7 runs through 8-bit
 ones, which is why a mapped block is near-lossless rather than lossless.
*>
fn uint astc_interp(uint l, uint h, uint w) @local
{
	uint k = (((l << 8) | l) * (64 - w) + ((h << 8) | h) * w + 32) >> 6;
	return k >> 8;
}

<*
 Pick the endpoint pair whose *interpolants* land closest, not the pair whose
 endpoints do. Worth doing where BC7 keeps fewer endpoint bits than UASTC
 spent (modes 1, 2 and 7, at 5 and 6 bits): rounding each endpoint on its own
 can miss the two or four levels a block actually uses by more than a
 neighbouring pair would. A 3x3 neighbourhood is enough — the right answer is
 never further than one step from the rounded one.

 @param count : `Texels using each UASTC weight level, in this BC7 subset.`
*>
fn void refine_subset(bc7::BlockFields* f, char[4] lo, char[4] hi, uint j, uint ebits,
	uint p0, uint p1, uint comps, uint wbits, char[32]* rm, uint[32]* count) @local
{
	uint levels = 1u << wbits;
	uint[32] bw;
	for (uint l = 0; l < levels; l++) bw[l] = bc7::weight_val(bc7::MODE_INDEX_BITS[f.mode], (*rm)[l]);
	uint top = (1u << ebits) - 1;

	for (uint c = 0; c < comps; c++)
	{
		uint[32] target;
		for (uint l = 0; l < levels; l++)
		{
			if ((*count)[l]) target[l] = astc_interp(lo[c], hi[c], astc_weight(l, wbits));
		}
		int n0 = (int)f.ep[j * 2][c];
		int n1 = (int)f.ep[j * 2 + 1][c];
		uint best0 = (uint)n0;
		uint best1 = (uint)n1;
		ulong best_err = ~(ulong)0;
		for (int d0 = -1; d0 <= 1; d0++)
		{
			int q0 = n0 + d0;
			if (q0 < 0 || q0 > (int)top) continue;
			uint a = p0 == QP_NONE ? bc7::dequant((uint)q0, ebits) : bc7::dequant_p((uint)q0, p0, ebits);
			for (int d1 = -1; d1 <= 1; d1++)
			{
				int q1 = n1 + d1;
				if (q1 < 0 || q1 > (int)top) continue;
				uint b = p1 == QP_NONE ? bc7::dequant((uint)q1, ebits) : bc7::dequant_p((uint)q1, p1, ebits);
				ulong err;
				for (uint l = 0; l < levels; l++)
				{
					uint n = (*count)[l];
					if (!n) continue;
					long e = (long)bc7::interp(a, b, bw[l]) - (long)target[l];
					err += (ulong)(e * e) * n;
				}
				if (err < best_err)
				{
					best_err = err;
					best0 = (uint)q0;
					best1 = (uint)q1;
				}
			}
		}
		f.ep[j * 2][c] = (char)best0;
		f.ep[j * 2 + 1][c] = (char)best1;
	}
}

<*
 The single- and multi-subset single-plane modes: BC7 modes 1, 2, 3, 6 and 7.
 False when the block's partition has no BC7 twin, which sends the caller to
 the encode fallback.
*>
fn bool subset_fields(bc7::BlockFields* f, uastc::Unpacked* u) @local
{
	uint part;
	char[3] sub;
	if (u.subsets == 1)
	{
		sub = { 0, 0, 0 };
	}
	else
	{
		PartMap m;
		if (u.subsets == 3)
		{
			m = part3[u.pattern];
		}
		else if (u.mode == 7)
		{
			m = part23[u.pattern];
		}
		else
		{
			m = part2[u.pattern];
		}
		if (!m.ok) return false;
		part = m.part;
		sub = m.sub;
	}

	uint bmode = TO_BC7[u.mode];
	uint nsub = bc7::MODE_SUBSETS[bmode];
	uint ebits = bc7::MODE_COLOR_BITS[bmode];
	uint comps = bc7::MODE_ALPHA_BITS[bmode] != 0 ? 4u : 3u;
	uint ptype = bc7::MODE_PBIT_TYPE[bmode];
	uint ibits = bc7::MODE_INDEX_BITS[bmode];
	f.mode = (char)bmode;
	f.partition = (char)part;

	for (uint j = 0; j < nsub; j++)
	{
		char[4] lo = u.ep[sub[j]][0];
		char[4] hi = u.ep[sub[j]][1];
		uint p0 = QP_NONE;
		uint p1 = QP_NONE;
		if (ptype == bc7::PBIT_SHARED)
		{
			uint c0 = ep_cost(ebits, 0, lo, comps) + ep_cost(ebits, 0, hi, comps);
			uint c1 = ep_cost(ebits, 1, lo, comps) + ep_cost(ebits, 1, hi, comps);
			p0 = c1 < c0 ? 1 : 0;
			p1 = p0;
			f.pbits[j] = (char)p0;
		}
		else if (ptype == bc7::PBIT_PER_ENDPOINT)
		{
			p0 = ep_cost(ebits, 1, lo, comps) < ep_cost(ebits, 0, lo, comps) ? 1 : 0;
			p1 = ep_cost(ebits, 1, hi, comps) < ep_cost(ebits, 0, hi, comps) ? 1 : 0;
			f.pbits[j * 2] = (char)p0;
			f.pbits[j * 2 + 1] = (char)p1;
		}
		for (uint c = 0; c < comps; c++)
		{
			f.ep[j * 2][c] = qval[ebits][p0][lo[c]];
			f.ep[j * 2 + 1][c] = qval[ebits][p1][hi[c]];
		}
	}

	char[32]* rm = &wremap[ibits - 2][u.weight_bits - 1];
	for (uint i = 0; i < 16; i++) f.idx[i] = (*rm)[u.weights[i]];

	if (ebits < 7)
	{
		for (uint j = 0; j < nsub; j++)
		{
			uint[32] count;
			for (uint i = 0; i < 16; i++)
			{
				if (bc7_subset(nsub, part, i) == j) count[u.weights[i]]++;
			}
			uint p0 = ptype == bc7::PBIT_NONE ? QP_NONE : (uint)f.pbits[ptype == bc7::PBIT_SHARED ? j : j * 2];
			uint p1 = ptype == bc7::PBIT_NONE ? QP_NONE : (uint)f.pbits[ptype == bc7::PBIT_SHARED ? j : j * 2 + 1];
			refine_subset(f, u.ep[sub[j]][0], u.ep[sub[j]][1], j, ebits, p0, p1, comps, u.weight_bits, rm, &count);
		}
	}

	// A subset whose anchor texel has the high index bit set is stored the
	// other way round: swap its endpoints and complement its indices.
	uint half = 1u << (ibits - 1);
	uint top = (1u << ibits) - 1;
	uint[3] anchor = { 0, 16, 16 };
	if (nsub == 2) anchor[1] = bc7::ANCHOR_2ND_SUBSET[part];
	if (nsub == 3)
	{
		anchor[1] = bc7::ANCHOR_3RD_SUBSET_1[part];
		anchor[2] = bc7::ANCHOR_3RD_SUBSET_2[part];
	}
	for (uint j = 0; j < nsub; j++)
	{
		if (f.idx[anchor[j]] < half) continue;
		for (uint c = 0; c < 4; c++)
		{
			char t = f.ep[j * 2][c];
			f.ep[j * 2][c] = f.ep[j * 2 + 1][c];
			f.ep[j * 2 + 1][c] = t;
		}
		if (ptype == bc7::PBIT_PER_ENDPOINT)
		{
			char t = f.pbits[j * 2];
			f.pbits[j * 2] = f.pbits[j * 2 + 1];
			f.pbits[j * 2 + 1] = t;
		}
		for (uint i = 0; i < 16; i++)
		{
			if (bc7_subset(nsub, part, i) == j) f.idx[i] = (char)(top - f.idx[i]);
		}
	}
	return true;
}

<*
 The dual-plane modes (6, 11, 13, 17) as BC7 mode 5, whose rotation is the
 same idea: one channel gets its own index plane. The rotated-out channel
 rides in mode 5's 8-bit alpha endpoints, so the component UASTC gave a plane
 of its own is the one BC7 stores exactly.
*>
fn void dual_fields(bc7::BlockFields* f, uastc::Unpacked* u) @local
{
	int ccs = u.ccs;
	f.mode = 5;
	f.rotation = (char)(ccs == 3 ? 0 : ccs + 1);

	char[4] lo = u.ep[0][0];
	char[4] hi = u.ep[0][1];
	for (uint c = 0; c < 3; c++)
	{
		uint src = (int)c == ccs ? 3u : c;
		f.ep[0][c] = qval[7][QP_NONE][lo[src]];
		f.ep[1][c] = qval[7][QP_NONE][hi[src]];
	}
	f.ep[0][3] = lo[ccs];
	f.ep[1][3] = hi[ccs];

	char[32]* rm = &wremap[0][u.weight_bits - 1];
	for (uint i = 0; i < 16; i++)
	{
		f.idx[i] = (*rm)[u.weights[i * 2]];
		f.idx2[i] = (*rm)[u.weights[i * 2 + 1]];
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
}

<*
 Mode 8 (solid) as BC7 mode 5: alpha is exact in mode 5's 8-bit endpoints, and
 the colour comes from a table of endpoint pairs that reproduce each level at
 colour index 0 or 1 — a flat block stays flat and, for almost every colour,
 stays exact.
*>
fn void solid_fields(bc7::BlockFields* f, uastc::Unpacked* u) @local
{
	char[4] c = u.ep[0][0];
	uint e0 = (uint)solid_err[0][c[0]] + solid_err[0][c[1]] + solid_err[0][c[2]];
	uint e1 = (uint)solid_err[1][c[0]] + solid_err[1][c[1]] + solid_err[1][c[2]];
	uint idx = e1 < e0 ? 1 : 0;
	f.mode = 5;
	for (uint k = 0; k < 3; k++)
	{
		f.ep[0][k] = solid_lo[idx][c[k]];
		f.ep[1][k] = solid_hi[idx][c[k]];
	}
	f.ep[0][3] = c[3];
	f.ep[1][3] = c[3];
	for (uint i = 0; i < 16; i++) f.idx[i] = (char)idx;
}

<*
 Map one 16-byte UASTC block onto one 16-byte BC7 block. A block whose
 partition has no BC7 equivalent (none does today, but the tables are
 searched, not hard-coded) falls back to decode + `bc7::encode_block`, and an
 undecodable block writes a zero block, which BC7 reads as transparent black.
*>
fn void map_block(char[] block, char* out)
{
	init();
	uastc::Unpacked u;
	if (@catch(uastc::unpack_block(block, &u)))
	{
		for (uint i = 0; i < 16; i++) out[i] = 0;
		return;
	}
	bc7::BlockFields f;
	if (u.mode == uastc::MODE_SOLID)
	{
		solid_fields(&f, &u);
	}
	else if (u.planes == 2)
	{
		dual_fields(&f, &u);
	}
	else if (!subset_fields(&f, &u))
	{
		char[64] px;
		if (@catch(uastc::decode_block(block, px[..])))
		{
			for (uint i = 0; i < 16; i++) out[i] = 0;
			return;
		}
		bc7::encode_block(&px[0], out, true);
		return;
	}
	bc7::pack_fields(out, &f);
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
 Map a whole UASTC image to BC7: `blocks` is ceil(w/4)*ceil(h/4) 16-byte UASTC
 blocks in raster order, the result the same count of BC7 blocks, allocated
 from `allocator`. Block rows run on `threads` threads (0 = decide from the
 job's size, 1 = inline); the output is identical either way.
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
