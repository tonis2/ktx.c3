// ETC1S/BasisLZ decoder in pure C3 (docs/basis-rewrite.md phase 2): the
// global endpoint/selector codebooks, the Huffman/RLE-coded slice streams,
// and ETC1S block reconstruction to RGBA — a port of basis_universal's
// basisu_lowlevel_etc1s_transcoder (decode_palettes / decode_tables /
// transcode_slice), bit-exact against it on the golden corpus.
//
// An ETC1S "block" is a constrained ETC1 block: one 5:5:5 base color, one
// 3-bit intensity table for both subblocks, and 16 2-bit selectors. A slice
// codes per-block (endpoint index, selector index) pairs with spatial
// prediction, delta coding and a selector move-to-front history buffer.
module ktx::etc1s;
import ktx::bits, ktx::huffman;
import std::core::mem;

faultdef INVALID_STREAM, INVALID_DIMENSIONS;

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
