// ETC1S/BasisLZ codec in pure C3: decoder (docs/basis-rewrite.md phase 2) and
// encoder (phase 5). The decoder is a port of basis_universal's
// basisu_lowlevel_etc1s_transcoder (decode_palettes / decode_tables /
// transcode_slice), bit-exact against it on the golden corpus; the encoder
// (see the Encode section below) produces streams the same decoder — and
// basisu's — read back identically.
//
// An ETC1S "block" is a constrained ETC1 block: one 5:5:5 base color, one
// 3-bit intensity table for both subblocks, and 16 2-bit selectors. A slice
// codes per-block (endpoint index, selector index) pairs with spatial
// prediction, delta coding and a selector move-to-front history buffer.
module ktx::etc1s;
import ktx::bits, ktx::huffman;
import std::core::mem;
import std::sort, std::math;

faultdef INVALID_STREAM, INVALID_DIMENSIONS, INVALID_INPUT;

// ETC1 intensity modifier tables (g_etc1_inten_tables).
const int[4][8] INTEN_TABLES = {
	{ -8, -2, 2, 8 }, { -17, -5, 5, 17 }, { -29, -9, 9, 29 }, { -42, -13, 13, 42 },
	{ -60, -18, 18, 60 }, { -80, -24, 24, 80 }, { -106, -33, 33, 106 }, { -183, -47, 47, 183 },
};

// decode_palettes: which color5 delta model applies, by previous component value.
const int COLOR5_PAL0_PREV_HI = 9;
const int COLOR5_PAL1_PREV_HI = 21;

// transcode_slice stream constants.
const uint ENDPOINT_PRED_REPEAT_LAST_SYMBOL = 256;   // of 257 pred symbols
const uint ENDPOINT_PRED_MIN_REPEAT_COUNT = 3;
const uint ENDPOINT_PRED_COUNT_VLC_BITS = 4;
const uint SELECTOR_HISTORY_BUF_RLE_COUNT_THRESH = 3;
const uint SELECTOR_HISTORY_BUF_RLE_COUNT_TOTAL = 64;

struct Endpoint
{
	char[3] color5;   // 5-bit RGB base color
	char inten5;      // intensity table index (0..7)
}

struct Selector
{
	char[4] rows;   // row y: pixel x's 2-bit selector at bits x*2
}

<* The unpacked BasisLZ global data every slice of a file shares. *>
struct Codebook
{
	Allocator allocator;
	Endpoint[] endpoints;
	Selector[] selectors;
	huffman::DecodeTable endpoint_pred_model;
	huffman::DecodeTable delta_endpoint_model;
	huffman::DecodeTable selector_model;
	huffman::DecodeTable selector_rle_model;
	uint history_buf_size;
}

fn void Codebook.free(&self)
{
	if (self.endpoints.len) alloc::free(self.allocator, self.endpoints.ptr);
	if (self.selectors.len) alloc::free(self.allocator, self.selectors.ptr);
	self.endpoint_pred_model.free();
	self.delta_endpoint_model.free();
	self.selector_model.free();
	self.selector_rle_model.free();
	*self = {};
}

<*
 Unpack the endpoint/selector codebooks and the slice Huffman models from the
 three sections of a KTX2 `supercompressionGlobalData` (basisu decode_palettes
 + decode_tables).
*>
fn Codebook? decode_codebook(Allocator allocator, uint num_endpoints, char[] endpoints_data,
	uint num_selectors, char[] selectors_data, char[] tables_data)
{
	if (!num_endpoints || !num_selectors) return INVALID_STREAM~;

	Codebook cb;
	cb.allocator = allocator;
	bool ok;
	defer if (!ok) cb.free();

	// --- endpoints: delta-coded 5-bit components + intensity indices ---
	bits::Reader r = bits::reader(endpoints_data);
	huffman::DecodeTable color5_delta0 = huffman::read_table(allocator, &r)!;
	defer color5_delta0.free();
	huffman::DecodeTable color5_delta1 = huffman::read_table(allocator, &r)!;
	defer color5_delta1.free();
	huffman::DecodeTable color5_delta2 = huffman::read_table(allocator, &r)!;
	defer color5_delta2.free();
	huffman::DecodeTable inten_delta = huffman::read_table(allocator, &r)!;
	defer inten_delta.free();

	bool grayscale = r.read(1) != 0;

	cb.endpoints = alloc::new_array(allocator, Endpoint, (sz)num_endpoints);
	uint[3] prev_color = { 16, 16, 16 };
	uint prev_inten;
	foreach (&ep : cb.endpoints)
	{
		prev_inten = (inten_delta.decode(&r)! + prev_inten) & 7;
		ep.inten5 = (char)prev_inten;
		for (uint c = 0; c < (grayscale ? 1u : 3u); c++)
		{
			uint delta;
			switch
			{
				case prev_color[c] <= COLOR5_PAL0_PREV_HI: delta = color5_delta0.decode(&r)!;
				case prev_color[c] <= COLOR5_PAL1_PREV_HI: delta = color5_delta1.decode(&r)!;
				default:                                   delta = color5_delta2.decode(&r)!;
			}
			prev_color[c] = (prev_color[c] + delta) & 31;
			ep.color5[c] = (char)prev_color[c];
		}
		if (grayscale)
		{
			ep.color5[1] = ep.color5[0];
			ep.color5[2] = ep.color5[0];
		}
	}
	if (!r.ok()) return INVALID_STREAM~;

	// --- selectors: raw rows, or per-row XOR deltas against the previous ---
	r = bits::reader(selectors_data);
	if (r.read(1)) return INVALID_STREAM~;   // global selector codebooks: unsupported
	if (r.read(1)) return INVALID_STREAM~;   // hybrid codebooks: unsupported
	bool raw = r.read(1) != 0;

	cb.selectors = alloc::new_array(allocator, Selector, (sz)num_selectors);
	if (raw)
	{
		foreach (&sel : cb.selectors)
		{
			for (uint j = 0; j < 4; j++) sel.rows[j] = (char)r.read(8);
		}
	}
	else
	{
		huffman::DecodeTable delta_pal = huffman::read_table(allocator, &r)!;
		defer delta_pal.free();
		char[4] prev_rows;
		foreach (i, &sel : cb.selectors)
		{
			for (uint j = 0; j < 4; j++)
			{
				uint cur = i == 0 ? r.read(8) : delta_pal.decode(&r)! ^ prev_rows[j];
				prev_rows[j] = (char)cur;
				sel.rows[j] = (char)cur;
			}
		}
	}
	if (!r.ok()) return INVALID_STREAM~;

	// --- slice models ---
	r = bits::reader(tables_data);
	cb.endpoint_pred_model = huffman::read_table(allocator, &r)!;
	cb.delta_endpoint_model = huffman::read_table(allocator, &r)!;
	cb.selector_model = huffman::read_table(allocator, &r)!;
	cb.selector_rle_model = huffman::read_table(allocator, &r)!;
	cb.history_buf_size = r.read(13);
	if (!cb.history_buf_size || !r.ok()) return INVALID_STREAM~;

	ok = true;
	return cb;
}

// Variable-length count: chunk_bits payload + continue bit per chunk.
fn uint decode_vlc(bits::Reader* r, uint chunk_bits) @local
{
	uint chunk_size = 1u << chunk_bits;
	uint v;
	uint ofs;
	for (;;)
	{
		uint s = r.read(chunk_bits + 1);
		v |= (s & (chunk_size - 1)) << ofs;
		ofs += chunk_bits;
		if ((s & chunk_size) == 0) break;
		if (ofs >= 32) break;
	}
	return v;
}

fn char clamp255(int v) @local
{
	return (char)(v < 0 ? 0 : (v > 255 ? 255 : v));
}

// The output channel(s) a slice pass writes.
enum Pass : char
{
	RGB_OPAQUE,   // RGB + alpha forced 255 (color slice, no alpha slice in file)
	RGB,          // RGB only, alpha left as-is (color slice, alpha decoded separately)
	ALPHA,        // alpha only, from the slice's green channel
}

struct BlockPred @local
{
	char pred_bits;
	ushort endpoint_index;
}

<*
 Decode one ETC1S slice into `out` (width*height RGBA8, raster order),
 writing the channels `pass` selects (basisu transcode_slice, cRGBA32 /
 cRGB32 / cA32 block formats).
*>
fn void? Codebook.decode_slice(&self, char[] slice_data, uint width, uint height, char[] out, Pass pass, Allocator allocator)
{
	uint nbx = (width + 3) / 4;
	uint nby = (height + 3) / 4;
	if (!nbx || !nby) return INVALID_DIMENSIONS~;
	if (out.len != (usz)width * height * 4) return INVALID_DIMENSIONS~;

	bits::Reader r = bits::reader(slice_data);

	// Approximate move-to-front history of recent selector indices.
	uint[] history = alloc::new_array(allocator, uint, (sz)self.history_buf_size);
	defer alloc::free(allocator, history.ptr);
	uint history_rover = self.history_buf_size / 2;

	// Endpoint predictions for the current and previous block row.
	BlockPred[] preds = alloc::new_array(allocator, BlockPred, (sz)nbx * 2);
	defer alloc::free(allocator, preds.ptr);

	uint selector_rle_count;
	uint cur_pred_bits;
	uint prev_pred_sym;
	uint pred_repeat_count;
	uint prev_endpoint_index;
	uint num_selectors = (uint)self.selectors.len;
	uint history_rle_symbol = num_selectors + self.history_buf_size;

	for (uint by = 0; by < nby; by++)
	{
		uint cur_row = by & 1;
		for (uint bx = 0; bx < nbx; bx++)
		{
			// One pred symbol carries 2-bit predictors for a 2x2 block group.
			if ((bx & 1) == 0)
			{
				if ((by & 1) == 0)
				{
					if (pred_repeat_count)
					{
						pred_repeat_count--;
						cur_pred_bits = prev_pred_sym;
					}
					else
					{
						cur_pred_bits = self.endpoint_pred_model.decode(&r)!;
						if (cur_pred_bits == ENDPOINT_PRED_REPEAT_LAST_SYMBOL)
						{
							pred_repeat_count = decode_vlc(&r, ENDPOINT_PRED_COUNT_VLC_BITS)
								+ ENDPOINT_PRED_MIN_REPEAT_COUNT - 1;
							cur_pred_bits = prev_pred_sym;
						}
						else
						{
							prev_pred_sym = cur_pred_bits;
						}
					}
					preds[(cur_row ^ 1) * nbx + bx].pred_bits = (char)(cur_pred_bits >> 4);
				}
				else
				{
					cur_pred_bits = preds[cur_row * nbx + bx].pred_bits;
				}
			}

			// Endpoint index: left / upper / upper-left / delta-coded.
			uint endpoint_index;
			uint pred = cur_pred_bits & 3;
			cur_pred_bits >>= 2;
			switch (pred)
			{
				case 0:
					if (!bx) return INVALID_STREAM~;
					endpoint_index = prev_endpoint_index;
				case 1:
					if (!by) return INVALID_STREAM~;
					endpoint_index = preds[(cur_row ^ 1) * nbx + bx].endpoint_index;
				case 2:
					if (!bx || !by) return INVALID_STREAM~;
					endpoint_index = preds[(cur_row ^ 1) * nbx + bx - 1].endpoint_index;
				default:
					endpoint_index = self.delta_endpoint_model.decode(&r)! + prev_endpoint_index;
					if (endpoint_index >= self.endpoints.len) endpoint_index -= (uint)self.endpoints.len;
			}
			preds[cur_row * nbx + bx].endpoint_index = (ushort)endpoint_index;
			prev_endpoint_index = endpoint_index;

			// Selector index: direct, or via the history buffer (with RLE runs).
			uint selector_index;
			uint selector_sym;
			if (selector_rle_count > 0)
			{
				selector_rle_count--;
				selector_sym = num_selectors;
			}
			else
			{
				selector_sym = self.selector_model.decode(&r)!;
				if (selector_sym == history_rle_symbol)
				{
					uint run_sym = self.selector_rle_model.decode(&r)!;
					if (run_sym == SELECTOR_HISTORY_BUF_RLE_COUNT_TOTAL - 1)
					{
						selector_rle_count = decode_vlc(&r, 7) + SELECTOR_HISTORY_BUF_RLE_COUNT_THRESH;
					}
					else
					{
						selector_rle_count = run_sym + SELECTOR_HISTORY_BUF_RLE_COUNT_THRESH;
					}
					if (selector_rle_count > nbx * nby) return INVALID_STREAM~;
					selector_sym = num_selectors;
					selector_rle_count--;
				}
			}

			if (selector_sym >= num_selectors)
			{
				uint hist_index = selector_sym - num_selectors;
				if (hist_index >= history.len) return INVALID_STREAM~;
				selector_index = history[hist_index];
				if (hist_index != 0)
				{
					// approximate move-to-front: swap with the halfway slot
					uint tmp = history[hist_index / 2];
					history[hist_index / 2] = history[hist_index];
					history[hist_index] = tmp;
				}
			}
			else
			{
				selector_index = selector_sym;
				history[history_rover++] = selector_index;
				if (history_rover == history.len) history_rover = (uint)history.len / 2;
			}

			if (endpoint_index >= self.endpoints.len || selector_index >= self.selectors.len)
			{
				return INVALID_STREAM~;
			}

			self.write_block(out, width, height, bx, by, endpoint_index, selector_index, pass);
		}
	}
}

// ===========================================================================
// Encode (docs/basis-rewrite.md phase 5)
//
// Frontend: every 4x4 block of every slice gets an initial standalone ETC1S
// fit, then k-means clustering (deterministic quantile seeding + Lloyd
// iterations) builds the global endpoint and selector codebooks, with
// per-cluster refits and a final exact per-block reassignment. Backend: the
// exact inverse of decode_codebook/decode_slice above — delta-coded endpoint
// palette with the three context models, raw selector palette, and slice
// streams using left/upper/upper-left predictors, pred-symbol repeat runs,
// and the selector history buffer with RLE. Two passes per stream: one to
// tally Huffman symbol frequencies, one to write bits.
// ===========================================================================

<* One slice to encode: a color pass, or the alpha channel of the same image. *>
struct EncSlice
{
	char[] rgba;   // width*height*4 source pixels
	uint width;
	uint height;
	bool alpha;    // encode the alpha channel (as ETC1S gray; decoded via Pass.ALPHA)
}

<* A fully encoded file: SGD sections + one slice stream per input slice. *>
struct Encoded
{
	uint num_endpoints;
	uint num_selectors;
	char[] endpoints_data;
	char[] selectors_data;
	char[] tables_data;
	char[][] slices;
}

struct EncBlock @local
{
	char[3][16] px;    // 16 RGB triples (alpha slices: a,a,a)
	float[3] mean;
	char[16] levels;   // chosen per-pixel selector levels for its endpoint
	uint endpoint;     // codebook assignments
	uint selector;
}

<* The 4 level colors an endpoint reconstructs to. *>
fn void endpoint_colors(Endpoint ep, char[3][4]* colors) @local
{
	int[4] inten = INTEN_TABLES[ep.inten5];
	for (uint l = 0; l < 4; l++)
	{
		for (uint c = 0; c < 3; c++)
		{
			int base = (ep.color5[c] << 3) | (ep.color5[c] >> 2);
			(*colors)[l][c] = clamp255(base + inten[l]);
		}
	}
}

<*
 Best (5-bit base color, intensity table) for a set of RGB triples: search the
 8 intensity tables with base colors around the mean (radius 1 per channel),
 assigning each pixel its best of the 4 levels.
*>
fn Endpoint fit_endpoint(char[] rgb) @local
{
	usz n = rgb.len / 3;
	uint[3] sum;
	for (usz i = 0; i < n; i++)
	{
		for (uint c = 0; c < 3; c++) sum[c] += rgb[i * 3 + c];
	}
	int[3] avg5;
	for (uint c = 0; c < 3; c++) avg5[c] = (int)((sum[c] * 31 + (uint)n * 127) / ((uint)n * 255));

	Endpoint best;
	ulong best_err = ~(ulong)0;
	for (uint inten = 0; inten < 8; inten++)
	{
		for (int dr = -1; dr <= 1; dr++)
		{
			for (int dg = -1; dg <= 1; dg++)
			{
				for (int db = -1; db <= 1; db++)
				{
					Endpoint ep = { .inten5 = (char)inten };
					int[3] d = { dr, dg, db };
					for (uint c = 0; c < 3; c++)
					{
						int v = avg5[c] + d[c];
						ep.color5[c] = (char)(v < 0 ? 0 : (v > 31 ? 31 : v));
					}
					char[3][4] colors;
					endpoint_colors(ep, &colors);
					ulong err;
					for (usz i = 0; i < n; i++)
					{
						uint pe = 0xFFFF_FFFF;
						for (uint l = 0; l < 4; l++)
						{
							uint e;
							for (uint c = 0; c < 3; c++)
							{
								int dd = (int)colors[l][c] - (int)rgb[i * 3 + c];
								e += (uint)(dd * dd);
							}
							if (e < pe) pe = e;
						}
						err += pe;
						if (err >= best_err) break;
					}
					if (err < best_err)
					{
						best_err = err;
						best = ep;
					}
				}
			}
		}
	}
	return best;
}

<* Per-pixel best levels for a block against an endpoint; returns the error. *>
fn ulong block_levels(EncBlock* b, Endpoint ep, char[16]* levels) @local
{
	char[3][4] colors;
	endpoint_colors(ep, &colors);
	ulong err;
	for (uint i = 0; i < 16; i++)
	{
		uint pe = 0xFFFF_FFFF;
		uint pl;
		for (uint l = 0; l < 4; l++)
		{
			uint e;
			for (uint c = 0; c < 3; c++)
			{
				int d = (int)colors[l][c] - (int)b.px[i][c];
				e += (uint)(d * d);
			}
			if (e < pe)
			{
				pe = e;
				pl = l;
			}
		}
		(*levels)[i] = (char)pl;
		err += pe;
	}
	return err;
}

fn ulong block_error_with_rows(EncBlock* b, Endpoint ep, char[4] rows) @local
{
	char[3][4] colors;
	endpoint_colors(ep, &colors);
	ulong err;
	for (uint i = 0; i < 16; i++)
	{
		uint l = ((uint)rows[i >> 2] >> ((i & 3) * 2)) & 3;
		for (uint c = 0; c < 3; c++)
		{
			int d = (int)colors[l][c] - (int)b.px[i][c];
			err += (ulong)(d * d);
		}
	}
	return err;
}

fn char[4] levels_to_rows(char[16]* levels) @local
{
	char[4] rows;
	for (uint i = 0; i < 16; i++)
	{
		rows[i >> 2] |= (char)(((uint)(*levels)[i]) << ((i & 3) * 2));
	}
	return rows;
}

<*
 Endpoint/selector codebook size targets for a 0..100 quality, following
 basisu's quality_level curve (basisu_comp.cpp) with quality*2.55 as the
 quality level, capped by the block count.
*>
fn void cluster_targets(uint quality, uint total_blocks, uint* out_endpoints, uint* out_selectors) @local
{
	const uint MAX_CLUSTERS = 16128;
	float q = (float)min(quality, 100u) / 100.0f;
	float total_texels = (float)total_blocks * 16.0f;
	const float MID = 128.0f / 255.0f;

	int max_e = (int)(total_texels / 14.0f);
	uint endpoints;
	if (q <= MID)
	{
		float ceq = 0.5f * pow_f(q / MID, 0.65f);
		max_e = max_e < 256 ? 256 : (max_e > 4800 ? 4800 : max_e);
		if (max_e > (int)total_blocks) max_e = (int)total_blocks;
		if (max_e < 64) max_e = 64;
		endpoints = (uint)(0.5f + 32.0f + ((float)max_e - 32.0f) * ceq);
	}
	else
	{
		float ceq = pow_f((q - MID) / (1.0f - MID), 1.6f);
		max_e = max_e < 256 ? 256 : (max_e > 8192 ? 8192 : max_e);
		if (max_e > (int)total_blocks) max_e = (int)total_blocks;
		if (max_e < 4800) max_e = 4800;
		endpoints = (uint)(0.5f + 4800.0f + ((float)max_e - 4800.0f) * ceq);
	}
	endpoints = min(max(endpoints, 32u), MAX_CLUSTERS);

	int max_s = (int)(total_texels / 14.0f);
	max_s = max_s < 256 ? 256 : (max_s > (int)MAX_CLUSTERS ? (int)MAX_CLUSTERS : max_s);
	if (max_s > (int)total_blocks) max_s = (int)total_blocks;
	if (max_s < 96) max_s = 96;
	float csq = pow_f(q, 2.62f);
	uint selectors = (uint)(0.5f + 96.0f + ((float)max_s - 96.0f) * csq);
	selectors = min(max(selectors, 8u), MAX_CLUSTERS);

	*out_endpoints = min(endpoints, total_blocks);
	*out_selectors = min(selectors, total_blocks);
}

fn float pow_f(float base, float e) @local
{
	return (float)math::pow((double)base, (double)e);
}

// Reconstruct one block's pixels into the raster-order RGBA output, cropped
// at the image edges.
fn void Codebook.write_block(&self, char[] out, uint width, uint height, uint bx, uint by,
	uint endpoint_index, uint selector_index, Pass pass)
{
	Endpoint* ep = &self.endpoints[endpoint_index];
	Selector* sel = &self.selectors[selector_index];
	int[4] inten = INTEN_TABLES[ep.inten5];

	uint max_x = min(4u, width - bx * 4);
	uint max_y = min(4u, height - by * 4);

	if (pass == Pass.ALPHA)
	{
		// Alpha slices carry the value in the green channel.
		int g = (ep.color5[1] << 3) | (ep.color5[1] >> 2);
		char[4] alphas;
		for (uint i = 0; i < 4; i++) alphas[i] = clamp255(g + inten[i]);
		for (uint y = 0; y < max_y; y++)
		{
			uint s = sel.rows[y];
			usz row = ((usz)(by * 4 + y) * width + (usz)bx * 4) * 4;
			for (uint x = 0; x < max_x; x++)
			{
				out[row + (usz)x * 4 + 3] = alphas[(s >> (x * 2)) & 3];
			}
		}
		return;
	}

	char[4][4] colors;   // [level][rgb_]
	for (uint i = 0; i < 4; i++)
	{
		for (uint c = 0; c < 3; c++)
		{
			int base = (ep.color5[c] << 3) | (ep.color5[c] >> 2);
			colors[i][c] = clamp255(base + inten[i]);
		}
	}
	for (uint y = 0; y < max_y; y++)
	{
		uint s = sel.rows[y];
		usz row = ((usz)(by * 4 + y) * width + (usz)bx * 4) * 4;
		for (uint x = 0; x < max_x; x++)
		{
			char[4] c = colors[(s >> (x * 2)) & 3];
			usz px = row + (usz)x * 4;
			out[px] = c[0];
			out[px + 1] = c[1];
			out[px + 2] = c[2];
			if (pass == Pass.RGB_OPAQUE) out[px + 3] = 255;
		}
	}
}

// ---------------------------------------------------------------------------
// Frontend: clustering

<* Deterministic k-means over per-block features; returns cluster count used. *>
fn uint kmeans_endpoints(EncBlock[] blocks, uint k, Allocator scratch) @local
{
	uint n = (uint)blocks.len;
	k = min(k, n);
	if (k == 0) k = 1;

	// Quantile seeding on luma-sorted block means.
	ulong[] order = alloc::new_array(scratch, ulong, (sz)n);
	foreach (i, &b : blocks)
	{
		ulong luma = (ulong)(b.mean[0] + b.mean[1] + b.mean[2]);
		order[i] = (luma << 32) | (ulong)i;
	}
	sort::quicksort(order, fn int(ulong a, ulong b) => a < b ? -1 : (a > b ? 1 : 0));

	float[3][] centers = alloc::new_array(scratch, float[3], (sz)k);
	for (uint c = 0; c < k; c++)
	{
		uint pick = (uint)((ulong)c * (ulong)(n - 1) / (ulong)(k > 1 ? k - 1 : 1));
		centers[c] = blocks[(uint)(order[pick] & 0xFFFF_FFFF)].mean;
	}

	float[3][] sums = alloc::new_array(scratch, float[3], (sz)k);
	uint[] counts = alloc::new_array(scratch, uint, (sz)k);
	for (uint iter = 0; iter < 4; iter++)
	{
		for (uint c = 0; c < k; c++)
		{
			sums[c] = { 0, 0, 0 };
			counts[c] = 0;
		}
		foreach (&b : blocks)
		{
			uint bc;
			float bd = 1e30f;
			for (uint c = 0; c < k; c++)
			{
				float d0 = b.mean[0] - centers[c][0];
				float d1 = b.mean[1] - centers[c][1];
				float d2 = b.mean[2] - centers[c][2];
				float d = d0 * d0 + d1 * d1 + d2 * d2;
				if (d < bd)
				{
					bd = d;
					bc = c;
				}
			}
			b.endpoint = bc;
			sums[bc][0] += b.mean[0];
			sums[bc][1] += b.mean[1];
			sums[bc][2] += b.mean[2];
			counts[bc]++;
		}
		for (uint c = 0; c < k; c++)
		{
			if (!counts[c]) continue;
			centers[c][0] = sums[c][0] / (float)counts[c];
			centers[c][1] = sums[c][1] / (float)counts[c];
			centers[c][2] = sums[c][2] / (float)counts[c];
		}
	}
	return k;
}

fn uint kmeans_selectors(EncBlock[] blocks, uint k, Allocator scratch) @local
{
	uint n = (uint)blocks.len;
	k = min(k, n);
	if (k == 0) k = 1;

	ulong[] order = alloc::new_array(scratch, ulong, (sz)n);
	foreach (i, &b : blocks)
	{
		ulong s;
		for (uint t = 0; t < 16; t++) s += b.levels[t];
		order[i] = (s << 32) | (ulong)i;
	}
	sort::quicksort(order, fn int(ulong a, ulong b) => a < b ? -1 : (a > b ? 1 : 0));

	float[16][] centers = alloc::new_array(scratch, float[16], (sz)k);
	for (uint c = 0; c < k; c++)
	{
		uint pick = (uint)((ulong)c * (ulong)(n - 1) / (ulong)(k > 1 ? k - 1 : 1));
		EncBlock* b = &blocks[(uint)(order[pick] & 0xFFFF_FFFF)];
		for (uint t = 0; t < 16; t++) centers[c][t] = (float)b.levels[t];
	}

	float[16][] sums = alloc::new_array(scratch, float[16], (sz)k);
	uint[] counts = alloc::new_array(scratch, uint, (sz)k);
	for (uint iter = 0; iter < 4; iter++)
	{
		for (uint c = 0; c < k; c++)
		{
			sums[c] = {};
			counts[c] = 0;
		}
		foreach (&b : blocks)
		{
			uint bc;
			float bd = 1e30f;
			for (uint c = 0; c < k; c++)
			{
				float d;
				for (uint t = 0; t < 16; t++)
				{
					float dt = (float)b.levels[t] - centers[c][t];
					d += dt * dt;
				}
				if (d < bd)
				{
					bd = d;
					bc = c;
				}
			}
			b.selector = bc;
			for (uint t = 0; t < 16; t++) sums[bc][t] += (float)b.levels[t];
			counts[bc]++;
		}
		for (uint c = 0; c < k; c++)
		{
			if (!counts[c]) continue;
			for (uint t = 0; t < 16; t++) centers[c][t] = sums[c][t] / (float)counts[c];
		}
	}
	return k;
}

// ---------------------------------------------------------------------------
// Backend: symbol emission (two passes share this via `counting`)

struct SymSink @local
{
	bool counting;
	uint[] pred_freqs;    // 257
	uint[] delta_freqs;   // num_endpoints
	uint[] sel_freqs;     // num_selectors + history_size + 1
	uint[] rle_freqs;     // SELECTOR_HISTORY_BUF_RLE_COUNT_TOTAL
	huffman::EncodeTable* pred_t;
	huffman::EncodeTable* delta_t;
	huffman::EncodeTable* sel_t;
	huffman::EncodeTable* rle_t;
	bits::Writer* w;
}

fn void SymSink.pred(&self, uint sym)
{
	if (self.counting) { self.pred_freqs[sym]++; } else { self.pred_t.put(self.w, sym); }
}
fn void SymSink.delta(&self, uint sym)
{
	if (self.counting) { self.delta_freqs[sym]++; } else { self.delta_t.put(self.w, sym); }
}
fn void SymSink.sel(&self, uint sym)
{
	if (self.counting) { self.sel_freqs[sym]++; } else { self.sel_t.put(self.w, sym); }
}
fn void SymSink.rle(&self, uint sym)
{
	if (self.counting) { self.rle_freqs[sym]++; } else { self.rle_t.put(self.w, sym); }
}
fn void SymSink.vlc(&self, uint v, uint chunk_bits)
{
	if (self.counting) return;
	uint chunk_size = 1u << chunk_bits;
	for (;;)
	{
		uint chunk = v & (chunk_size - 1);
		v >>= chunk_bits;
		self.w.write(chunk | (v ? chunk_size : 0), chunk_bits + 1);
		if (!v) break;
	}
}

<*
 Emit one slice's symbol stream (the exact inverse of decode_slice): per-block
 endpoint predictors packed into 2x2 group symbols with repeat runs, endpoint
 index deltas, and selector symbols through the shared history buffer with RLE.
*>
fn void emit_slice(SymSink* sink, uint[] eps, uint[] sels, uint nbx, uint nby,
	uint num_endpoints, uint num_selectors, uint history_size, uint[] history) @local
{
	uint nblocks = nbx * nby;

	// Predictor code per block: cheapest valid reference, else 3 = delta.
	// (Codes match decode_slice: 0 = left, 1 = upper, 2 = upper-left.)
	char[] pred = alloc::new_array(tmem, char, (sz)nblocks);
	for (uint by = 0; by < nby; by++)
	{
		for (uint bx = 0; bx < nbx; bx++)
		{
			uint i = by * nbx + bx;
			uint e = eps[i];
			char p = 3;
			if (bx > 0 && by > 0 && e == eps[i - nbx - 1]) p = 2;
			if (by > 0 && e == eps[i - nbx]) p = 1;
			if (bx > 0 && e == eps[i - 1]) p = 0;
			pred[i] = p;
		}
	}

	// 2x2 group symbols in read order (even rows, even columns).
	uint gx = (nbx + 1) / 2;
	uint gy = (nby + 1) / 2;
	uint[] gsyms = alloc::new_array(tmem, uint, (sz)gx * gy);
	uint gi;
	for (uint by = 0; by < nby; by += 2)
	{
		for (uint bx = 0; bx < nbx; bx += 2)
		{
			uint sym;
			sym = pred[by * nbx + bx];
			if (bx + 1 < nbx) sym |= (uint)pred[by * nbx + bx + 1] << 2;
			if (by + 1 < nby)
			{
				sym |= (uint)pred[(by + 1) * nbx + bx] << 4;
				if (bx + 1 < nbx) sym |= (uint)pred[(by + 1) * nbx + bx + 1] << 6;
			}
			gsyms[gi++] = sym;
		}
	}

	// Group-symbol events with repeat-run compression: after an emitted
	// symbol, R >= 3 identical ones become REPEAT + vlc(R-3).
	// Event value: sym, or 256 => the reader consumes prev (repeat member).
	uint[] gevent = alloc::new_array(tmem, uint, (sz)gx * gy);   // emitted sym or 0xFFFF_FFFF for run member
	uint[] grun = alloc::new_array(tmem, uint, (sz)gx * gy);     // at run start: vlc value + 1, else 0
	{
		uint i = 0;
		uint total = gx * gy;
		while (i < total)
		{
			gevent[i] = gsyms[i];
			grun[i] = 0;
			uint r = 0;
			while (i + 1 + r < total && gsyms[i + 1 + r] == gsyms[i]) r++;
			if (r >= ENDPOINT_PRED_MIN_REPEAT_COUNT)
			{
				for (uint j = 0; j < r; j++)
				{
					gevent[i + 1 + j] = 0xFFFF_FFFF;
					grun[i + 1 + j] = 0;
				}
				grun[i + 1] = (r - ENDPOINT_PRED_MIN_REPEAT_COUNT) + 1;   // vlc value + 1
				i += 1 + r;
			}
			else
			{
				i++;
			}
		}
	}

	// Walk blocks in decode order, emitting group syms / deltas / selectors.
	for (uint h = 0; h < history_size; h++) history[h] = 0;
	uint history_rover = history_size / 2;
	uint history_rle_symbol = num_selectors + history_size;
	uint prev_endpoint = 0;
	uint sel_rle_remaining = 0;
	uint g = 0;

	for (uint by = 0; by < nby; by++)
	{
		for (uint bx = 0; bx < nbx; bx++)
		{
			uint i = by * nbx + bx;

			if ((bx & 1) == 0 && (by & 1) == 0)
			{
				uint ev = gevent[g];
				if (ev == 0xFFFF_FFFF)
				{
					if (grun[g])
					{
						sink.pred(ENDPOINT_PRED_REPEAT_LAST_SYMBOL);
						sink.vlc(grun[g] - 1, ENDPOINT_PRED_COUNT_VLC_BITS);
					}
					// other run members consume no symbols
				}
				else
				{
					sink.pred(ev);
				}
				g++;
			}

			if (pred[i] == 3)
			{
				uint d = eps[i] >= prev_endpoint
					? eps[i] - prev_endpoint
					: eps[i] + num_endpoints - prev_endpoint;
				sink.delta(d);
			}
			prev_endpoint = eps[i];

			// Selector: RLE run of history[0], history hit, or literal.
			if (sel_rle_remaining > 0)
			{
				sel_rle_remaining--;
				continue;
			}
			uint s = sels[i];
			if (s == history[0])
			{
				uint run = 1;
				while (i + run < nblocks && sels_at(sels, i + run) == s) run++;
				// Runs only make sense within this walk; they always fit.
				if (run >= SELECTOR_HISTORY_BUF_RLE_COUNT_THRESH)
				{
					sink.sel(history_rle_symbol);
					if (run - SELECTOR_HISTORY_BUF_RLE_COUNT_THRESH < SELECTOR_HISTORY_BUF_RLE_COUNT_TOTAL - 1)
					{
						sink.rle(run - SELECTOR_HISTORY_BUF_RLE_COUNT_THRESH);
					}
					else
					{
						sink.rle(SELECTOR_HISTORY_BUF_RLE_COUNT_TOTAL - 1);
						sink.vlc(run - SELECTOR_HISTORY_BUF_RLE_COUNT_THRESH, 7);
					}
					sel_rle_remaining = run - 1;
					continue;
				}
			}
			// History hit?
			uint hit = history_size;
			for (uint h = 0; h < history_size; h++)
			{
				if (history[h] == s)
				{
					hit = h;
					break;
				}
			}
			if (hit < history_size)
			{
				sink.sel(num_selectors + hit);
				if (hit != 0)
				{
					uint tmp = history[hit / 2];
					history[hit / 2] = history[hit];
					history[hit] = tmp;
				}
			}
			else
			{
				sink.sel(s);
				history[history_rover++] = s;
				if (history_rover == history_size) history_rover = history_size / 2;
			}
		}
	}
}

fn uint sels_at(uint[] sels, uint i) @local @inline => sels[i];

<* Build an encode table, padding to >= 2 used symbols so tiny/unused models
   still produce well-formed streams. *>
fn huffman::EncodeTable? build_model(Allocator allocator, uint[] freqs) @local
{
	uint used;
	foreach (f : freqs)
	{
		if (f) used++;
	}
	if (used < 2)
	{
		foreach (i, &f : freqs)
		{
			if (*f == 0)
			{
				*f = 1;
				used++;
				if (used >= 2) break;
			}
		}
	}
	return huffman::build_encode(allocator, freqs);
}

// ---------------------------------------------------------------------------
// Top-level encode

<*
 Encode slices into ETC1S/BasisLZ global codebooks + per-slice streams. All
 slices share the codebooks (that is the format). `quality` 0..100 maps to
 codebook-size targets following basisu's curve. Everything is allocated from
 `allocator`; scratch comes from the temp pool.
*>
fn Encoded? encode(Allocator allocator, EncSlice[] slices, uint quality) => @pool()
{
	if (!slices.len) return INVALID_INPUT~;

	// --- blockize ---
	usz total_blocks;
	foreach (&s : slices)
	{
		if (s.rgba.len != (usz)s.width * s.height * 4) return INVALID_INPUT~;
		if (!s.width || !s.height) return INVALID_INPUT~;
		total_blocks += (usz)((s.width + 3) / 4) * (usz)((s.height + 3) / 4);
	}
	EncBlock[] blocks = alloc::new_array(tmem, EncBlock, (sz)total_blocks);
	usz[] slice_start = alloc::new_array(tmem, usz, (sz)slices.len);
	usz bi;
	foreach (si, &s : slices)
	{
		slice_start[si] = bi;
		uint nbx = (s.width + 3) / 4;
		uint nby = (s.height + 3) / 4;
		for (uint by = 0; by < nby; by++)
		{
			for (uint bx = 0; bx < nbx; bx++)
			{
				EncBlock* b = &blocks[bi++];
				uint[3] sum;
				for (uint y = 0; y < 4; y++)
				{
					uint sy = min(by * 4 + y, s.height - 1);
					for (uint x = 0; x < 4; x++)
					{
						uint sx = min(bx * 4 + x, s.width - 1);
						usz src = ((usz)sy * s.width + sx) * 4;
						uint t = y * 4 + x;
						if (s.alpha)
						{
							char a = s.rgba[src + 3];
							b.px[t] = { a, a, a };
						}
						else
						{
							b.px[t] = { s.rgba[src], s.rgba[src + 1], s.rgba[src + 2] };
						}
						for (uint c = 0; c < 3; c++) sum[c] += b.px[t][c];
					}
				}
				for (uint c = 0; c < 3; c++) b.mean[c] = (float)sum[c] / 16.0f;
			}
		}
	}

	// --- endpoint codebook ---
	uint target_e;
	uint target_s;
	cluster_targets(quality, (uint)total_blocks, &target_e, &target_s);
	uint num_e = kmeans_endpoints(blocks, target_e, tmem);

	Endpoint[] eps = alloc::new_array(tmem, Endpoint, (sz)num_e);
	{
		// Bucket blocks by cluster, refit each over its member pixels.
		uint[] counts = alloc::new_array(tmem, uint, (sz)num_e);
		foreach (&b : blocks) counts[b.endpoint]++;
		usz[] offs = alloc::new_array(tmem, usz, (sz)num_e);
		usz acc;
		for (uint c = 0; c < num_e; c++)
		{
			offs[c] = acc;
			acc += counts[c];
		}
		uint[] members = alloc::new_array(tmem, uint, (sz)total_blocks);
		usz[] fill = alloc::new_array(tmem, usz, (sz)num_e);
		foreach (i, &b : blocks) members[offs[b.endpoint] + fill[b.endpoint]++] = (uint)i;

		char[] scratch = alloc::new_array(tmem, char, (sz)total_blocks * 48);
		for (uint c = 0; c < num_e; c++)
		{
			if (!counts[c]) continue;
			usz n;
			for (usz m = 0; m < counts[c]; m++)
			{
				EncBlock* b = &blocks[members[offs[c] + m]];
				for (uint t = 0; t < 16; t++)
				{
					scratch[n * 3] = b.px[t][0];
					scratch[n * 3 + 1] = b.px[t][1];
					scratch[n * 3 + 2] = b.px[t][2];
					n++;
				}
			}
			eps[c] = fit_endpoint(scratch[:n * 3]);
		}
	}

	// Per-block best levels for the assigned endpoint.
	foreach (&b : blocks)
	{
		block_levels(b, eps[b.endpoint], &b.levels);
	}

	// --- selector codebook ---
	uint num_s = kmeans_selectors(blocks, target_s, tmem);
	Selector[] sels = alloc::new_array(tmem, Selector, (sz)num_s);
	{
		// Refit: per cluster, per texel, the level minimizing member error.
		uint[] counts = alloc::new_array(tmem, uint, (sz)num_s);
		foreach (&b : blocks) counts[b.selector]++;
		ulong[4][16][] err = alloc::new_array(tmem, ulong[4][16], (sz)num_s);
		foreach (&b : blocks)
		{
			char[3][4] colors;
			endpoint_colors(eps[b.endpoint], &colors);
			for (uint t = 0; t < 16; t++)
			{
				for (uint l = 0; l < 4; l++)
				{
					ulong e;
					for (uint c = 0; c < 3; c++)
					{
						int d = (int)colors[l][c] - (int)b.px[t][c];
						e += (ulong)(d * d);
					}
					err[b.selector][t][l] += e;
				}
			}
		}
		for (uint c = 0; c < num_s; c++)
		{
			char[16] levels;
			for (uint t = 0; t < 16; t++)
			{
				ulong be = ~(ulong)0;
				uint bl;
				for (uint l = 0; l < 4; l++)
				{
					if (err[c][t][l] < be)
					{
						be = err[c][t][l];
						bl = l;
					}
				}
				levels[t] = (char)bl;
			}
			sels[c].rows = levels_to_rows(&levels);
		}
	}

	// Exact selector reassignment (skip for very large codebooks).
	if (num_s <= 2048)
	{
		foreach (&b : blocks)
		{
			ulong be = ~(ulong)0;
			uint bs;
			for (uint c = 0; c < num_s; c++)
			{
				ulong e = block_error_with_rows(b, eps[b.endpoint], sels[c].rows);
				if (e < be)
				{
					be = e;
					bs = c;
				}
			}
			b.selector = bs;
		}
	}

	// --- prune unused entries, sort endpoints for delta locality, remap ---
	uint[] e_remap = alloc::new_array(tmem, uint, (sz)num_e);
	uint[] s_remap = alloc::new_array(tmem, uint, (sz)num_s);
	{
		uint[] e_used = alloc::new_array(tmem, uint, (sz)num_e);
		uint[] s_used = alloc::new_array(tmem, uint, (sz)num_s);
		foreach (&b : blocks)
		{
			e_used[b.endpoint] = 1;
			s_used[b.selector] = 1;
		}
		// Order surviving endpoints by luma then inten for smaller deltas.
		ulong[] e_order = alloc::new_array(tmem, ulong, (sz)num_e);
		uint ne;
		for (uint c = 0; c < num_e; c++)
		{
			if (!e_used[c]) continue;
			ulong key = ((ulong)eps[c].color5[0] + eps[c].color5[1] + eps[c].color5[2]) * 8 + eps[c].inten5;
			e_order[ne++] = (key << 32) | c;
		}
		sort::quicksort(e_order[:ne], fn int(ulong a, ulong b) => a < b ? -1 : (a > b ? 1 : 0));
		Endpoint[] eps2 = alloc::new_array(tmem, Endpoint, (sz)ne);
		for (uint c = 0; c < ne; c++)
		{
			uint old = (uint)(e_order[c] & 0xFFFF_FFFF);
			eps2[c] = eps[old];
			e_remap[old] = c;
		}
		eps = eps2;
		num_e = ne;

		// Order surviving selectors by pattern value: similar patterns end up
		// adjacent, which shrinks the XOR-delta palette coding below.
		ulong[] s_order = alloc::new_array(tmem, ulong, (sz)num_s);
		uint ns;
		for (uint c = 0; c < num_s; c++)
		{
			if (!s_used[c]) continue;
			ulong key = ((ulong)sels[c].rows[0] << 24) | ((ulong)sels[c].rows[1] << 16)
				| ((ulong)sels[c].rows[2] << 8) | sels[c].rows[3];
			s_order[ns++] = (key << 32) | c;
		}
		sort::quicksort(s_order[:ns], fn int(ulong a, ulong b) => a < b ? -1 : (a > b ? 1 : 0));
		Selector[] sels2 = alloc::new_array(tmem, Selector, (sz)ns);
		for (uint c = 0; c < ns; c++)
		{
			uint old = (uint)(s_order[c] & 0xFFFF_FFFF);
			sels2[c] = sels[old];
			s_remap[old] = c;
		}
		sels = sels2;
		num_s = ns;
	}
	foreach (&b : blocks)
	{
		b.endpoint = e_remap[b.endpoint];
		b.selector = s_remap[b.selector];
	}

	// --- serialize: endpoints section ---
	bool grayscale = true;
	for (uint c = 0; c < num_e; c++)
	{
		if (eps[c].color5[0] != eps[c].color5[1] || eps[c].color5[0] != eps[c].color5[2])
		{
			grayscale = false;
			break;
		}
	}
	char[] endpoints_data;
	{
		// Tally deltas, build the four models, then write.
		uint[32][3] color_freqs;
		uint[8] inten_freqs;
		uint[3] prev = { 16, 16, 16 };
		uint prev_inten;
		for (uint i = 0; i < num_e; i++)
		{
			inten_freqs[((uint)eps[i].inten5 - prev_inten) & 7]++;
			prev_inten = eps[i].inten5;
			for (uint c = 0; c < (grayscale ? 1u : 3u); c++)
			{
				uint model = prev[c] <= COLOR5_PAL0_PREV_HI ? 0 : (prev[c] <= COLOR5_PAL1_PREV_HI ? 1 : 2);
				color_freqs[model][((uint)eps[i].color5[c] - prev[c]) & 31]++;
				prev[c] = eps[i].color5[c];
			}
		}
		huffman::EncodeTable[3] color_t;
		for (uint m = 0; m < 3; m++) color_t[m] = build_model(tmem, color_freqs[m][..])!;
		huffman::EncodeTable inten_t = build_model(tmem, inten_freqs[..])!;

		bits::Writer w = bits::writer(tmem, 1024);
		for (uint m = 0; m < 3; m++) color_t[m].write_table(tmem, &w)!;
		inten_t.write_table(tmem, &w)!;
		w.write((uint)(grayscale ? 1 : 0), 1);
		prev = { 16, 16, 16 };
		prev_inten = 0;
		for (uint i = 0; i < num_e; i++)
		{
			inten_t.put(&w, ((uint)eps[i].inten5 - prev_inten) & 7);
			prev_inten = eps[i].inten5;
			for (uint c = 0; c < (grayscale ? 1u : 3u); c++)
			{
				uint model = prev[c] <= COLOR5_PAL0_PREV_HI ? 0 : (prev[c] <= COLOR5_PAL1_PREV_HI ? 1 : 2);
				color_t[model].put(&w, ((uint)eps[i].color5[c] - prev[c]) & 31);
				prev[c] = eps[i].color5[c];
			}
		}
		endpoints_data = w.finish();
	}

	// --- selectors section: raw rows, or XOR-delta + Huffman when smaller ---
	char[] selectors_data;
	{
		bits::Writer raw_w = bits::writer(tmem, (usz)num_s * 4 + 8);
		raw_w.write(0, 1);   // no global codebooks
		raw_w.write(0, 1);   // no hybrid codebooks
		raw_w.write(1, 1);   // raw
		for (uint c = 0; c < num_s; c++)
		{
			for (uint j = 0; j < 4; j++) raw_w.write(sels[c].rows[j], 8);
		}
		char[] raw_data = raw_w.finish();

		uint[256] delta_freqs;
		char[4] prev_rows;
		for (uint c = 0; c < num_s; c++)
		{
			for (uint j = 0; j < 4; j++)
			{
				if (c > 0) delta_freqs[sels[c].rows[j] ^ prev_rows[j]]++;
				prev_rows[j] = sels[c].rows[j];
			}
		}
		huffman::EncodeTable delta_t = build_model(tmem, delta_freqs[..])!;
		bits::Writer del_w = bits::writer(tmem, (usz)num_s * 3 + 64);
		del_w.write(0, 1);
		del_w.write(0, 1);
		del_w.write(0, 1);   // delta/Huffman coded
		delta_t.write_table(tmem, &del_w)!;
		prev_rows = {};
		for (uint c = 0; c < num_s; c++)
		{
			for (uint j = 0; j < 4; j++)
			{
				if (c == 0)
				{
					del_w.write(sels[c].rows[j], 8);
				}
				else
				{
					delta_t.put(&del_w, sels[c].rows[j] ^ prev_rows[j]);
				}
				prev_rows[j] = sels[c].rows[j];
			}
		}
		char[] delta_data = del_w.finish();

		selectors_data = delta_data.len < raw_data.len ? delta_data : raw_data;
	}

	// --- slice streams: count symbols, build models, then write ---
	const uint HISTORY_SIZE = 16;
	uint[] history = alloc::new_array(tmem, uint, HISTORY_SIZE);
	SymSink sink = {
		.counting = true,
		.pred_freqs = alloc::new_array(tmem, uint, 257),
		.delta_freqs = alloc::new_array(tmem, uint, (sz)num_e),
		.sel_freqs = alloc::new_array(tmem, uint, (sz)(num_s + HISTORY_SIZE + 1)),
		.rle_freqs = alloc::new_array(tmem, uint, SELECTOR_HISTORY_BUF_RLE_COUNT_TOTAL),
	};

	uint[] slice_eps;
	uint[] slice_sels;
	{
		usz max_blocks;
		foreach (si, &s : slices)
		{
			usz nb = (usz)((s.width + 3) / 4) * (usz)((s.height + 3) / 4);
			max_blocks = max(max_blocks, nb);
		}
		slice_eps = alloc::new_array(tmem, uint, (sz)max_blocks);
		slice_sels = alloc::new_array(tmem, uint, (sz)max_blocks);
	}

	for (uint pass = 0; pass < 2; pass++)
	{
		huffman::EncodeTable pred_t;
		huffman::EncodeTable delta_t;
		huffman::EncodeTable sel_t;
		huffman::EncodeTable rle_t;
		if (pass == 1)
		{
			pred_t = build_model(tmem, sink.pred_freqs)!;
			delta_t = build_model(tmem, sink.delta_freqs)!;
			sel_t = build_model(tmem, sink.sel_freqs)!;
			rle_t = build_model(tmem, sink.rle_freqs)!;
			sink.counting = false;
			sink.pred_t = &pred_t;
			sink.delta_t = &delta_t;
			sink.sel_t = &sel_t;
			sink.rle_t = &rle_t;

			// tables section
			bits::Writer tw = bits::writer(tmem, 512);
			pred_t.write_table(tmem, &tw)!;
			delta_t.write_table(tmem, &tw)!;
			sel_t.write_table(tmem, &tw)!;
			rle_t.write_table(tmem, &tw)!;
			tw.write(HISTORY_SIZE, 13);
			char[] tables_data = tw.finish();

			// results container (filled below)
			char[][] out_slices = alloc::new_array(allocator, char[], (sz)slices.len);
			foreach (si, &s : slices)
			{
				uint nbx = (s.width + 3) / 4;
				uint nby = (s.height + 3) / 4;
				usz nb = (usz)nbx * nby;
				usz start = slice_start[si];
				for (usz j = 0; j < nb; j++)
				{
					slice_eps[j] = blocks[start + j].endpoint;
					slice_sels[j] = blocks[start + j].selector;
				}
				bits::Writer sw = bits::writer(tmem, 1024);
				sink.w = &sw;
				emit_slice(&sink, slice_eps[:nb], slice_sels[:nb], nbx, nby, num_e, num_s, HISTORY_SIZE, history);
				char[] bits_out = sw.finish();
				char[] copy = alloc::new_array(allocator, char, (sz)bits_out.len);
				copy[..] = bits_out[..];
				out_slices[si] = copy;
			}

			char[] e_copy = alloc::new_array(allocator, char, (sz)endpoints_data.len);
			e_copy[..] = endpoints_data[..];
			char[] s_copy = alloc::new_array(allocator, char, (sz)selectors_data.len);
			s_copy[..] = selectors_data[..];
			char[] t_copy = alloc::new_array(allocator, char, (sz)tables_data.len);
			t_copy[..] = tables_data[..];
			return {
				.num_endpoints = num_e,
				.num_selectors = num_s,
				.endpoints_data = e_copy,
				.selectors_data = s_copy,
				.tables_data = t_copy,
				.slices = out_slices,
			};
		}

		// pass 0: counting
		foreach (si, &s : slices)
		{
			uint nbx = (s.width + 3) / 4;
			uint nby = (s.height + 3) / 4;
			usz nb = (usz)nbx * nby;
			usz start = slice_start[si];
			for (usz j = 0; j < nb; j++)
			{
				slice_eps[j] = blocks[start + j].endpoint;
				slice_sels[j] = blocks[start + j].selector;
			}
			emit_slice(&sink, slice_eps[:nb], slice_sels[:nb], nbx, nby, num_e, num_s, HISTORY_SIZE, history);
		}
	}
	unreachable();
}
