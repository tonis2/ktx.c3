<*
 BC7 (BPTC) block compression encoder + decoder.

 Decoder: all 8 modes, bit-exact per the Khronos Data Format / D3D11 functional
 spec (validated against the basis_universal bc7 unpacker).
 Encoder: modes 1, 5 and 6 (bc7enc16-style), quality-oriented:
   - mode 6 always evaluated (PCA + least-squares refinement, both p-bits),
   - mode 1 for opaque blocks (64-partition estimation, full eval of the best
     candidates),
   - mode 5 (rotation 0) for blocks with non-constant/non-opaque alpha.

 Tables extracted from basis_universal (Apache-2.0).
*>
module ktx::bc7;
import std::math;
import ktx::parallel;

faultdef INVALID_SIZE;

// ---------------------------------------------------------------------------
// Tables (ground truth: basis_universal / BC7 spec)
// ---------------------------------------------------------------------------

// Interpolation weights; formula: (a*(64-w) + b*w + 32) >> 6
const uint[4]  WEIGHTS2 = { 0, 21, 43, 64 };
const uint[8]  WEIGHTS3 = { 0, 9, 18, 27, 37, 46, 55, 64 };
const uint[16] WEIGHTS4 = { 0, 4, 9, 13, 17, 21, 26, 30, 34, 38, 43, 47, 51, 55, 60, 64 };

// Mode parameter table, modes 0-7.
const char PBIT_NONE = 0;         // no p-bits
const char PBIT_PER_ENDPOINT = 1; // one p-bit per endpoint
const char PBIT_SHARED = 2;       // one p-bit shared per subset

const char[8] MODE_SUBSETS        = { 3, 2, 3, 2, 1, 1, 1, 2 };
const char[8] MODE_PARTITION_BITS = { 4, 6, 6, 6, 0, 0, 0, 6 };
const char[8] MODE_ROTATION_BITS  = { 0, 0, 0, 0, 2, 2, 0, 0 };
const char[8] MODE_INDEX_SEL_BITS = { 0, 0, 0, 0, 1, 0, 0, 0 };
const char[8] MODE_COLOR_BITS     = { 4, 6, 5, 7, 5, 7, 7, 5 };
const char[8] MODE_ALPHA_BITS     = { 0, 0, 0, 0, 6, 8, 7, 5 };
const char[8] MODE_PBIT_TYPE      = { PBIT_PER_ENDPOINT, PBIT_SHARED, PBIT_NONE, PBIT_PER_ENDPOINT,
                                      PBIT_NONE, PBIT_NONE, PBIT_PER_ENDPOINT, PBIT_PER_ENDPOINT };
const char[8] MODE_INDEX_BITS     = { 3, 3, 2, 2, 2, 2, 4, 2 };
const char[8] MODE_INDEX2_BITS    = { 0, 0, 0, 0, 3, 2, 0, 0 };

// 2-subset partition patterns (64 patterns x 16 texels).
const char[1024] PARTITION2 =
{
	0,0,1,1,0,0,1,1,0,0,1,1,0,0,1,1,
	0,0,0,1,0,0,0,1,0,0,0,1,0,0,0,1,
	0,1,1,1,0,1,1,1,0,1,1,1,0,1,1,1,
	0,0,0,1,0,0,1,1,0,0,1,1,0,1,1,1,
	0,0,0,0,0,0,0,1,0,0,0,1,0,0,1,1,
	0,0,1,1,0,1,1,1,0,1,1,1,1,1,1,1,
	0,0,0,1,0,0,1,1,0,1,1,1,1,1,1,1,
	0,0,0,0,0,0,0,1,0,0,1,1,0,1,1,1,
	0,0,0,0,0,0,0,0,0,0,0,1,0,0,1,1,
	0,0,1,1,0,1,1,1,1,1,1,1,1,1,1,1,
	0,0,0,0,0,0,0,1,0,1,1,1,1,1,1,1,
	0,0,0,0,0,0,0,0,0,0,0,1,0,1,1,1,
	0,0,0,1,0,1,1,1,1,1,1,1,1,1,1,1,
	0,0,0,0,0,0,0,0,1,1,1,1,1,1,1,1,
	0,0,0,0,1,1,1,1,1,1,1,1,1,1,1,1,
	0,0,0,0,0,0,0,0,0,0,0,0,1,1,1,1,
	0,0,0,0,1,0,0,0,1,1,1,0,1,1,1,1,
	0,1,1,1,0,0,0,1,0,0,0,0,0,0,0,0,
	0,0,0,0,0,0,0,0,1,0,0,0,1,1,1,0,
	0,1,1,1,0,0,1,1,0,0,0,1,0,0,0,0,
	0,0,1,1,0,0,0,1,0,0,0,0,0,0,0,0,
	0,0,0,0,1,0,0,0,1,1,0,0,1,1,1,0,
	0,0,0,0,0,0,0,0,1,0,0,0,1,1,0,0,
	0,1,1,1,0,0,1,1,0,0,1,1,0,0,0,1,
	0,0,1,1,0,0,0,1,0,0,0,1,0,0,0,0,
	0,0,0,0,1,0,0,0,1,0,0,0,1,1,0,0,
	0,1,1,0,0,1,1,0,0,1,1,0,0,1,1,0,
	0,0,1,1,0,1,1,0,0,1,1,0,1,1,0,0,
	0,0,0,1,0,1,1,1,1,1,1,0,1,0,0,0,
	0,0,0,0,1,1,1,1,1,1,1,1,0,0,0,0,
	0,1,1,1,0,0,0,1,1,0,0,0,1,1,1,0,
	0,0,1,1,1,0,0,1,1,0,0,1,1,1,0,0,
	0,1,0,1,0,1,0,1,0,1,0,1,0,1,0,1,
	0,0,0,0,1,1,1,1,0,0,0,0,1,1,1,1,
	0,1,0,1,1,0,1,0,0,1,0,1,1,0,1,0,
	0,0,1,1,0,0,1,1,1,1,0,0,1,1,0,0,
	0,0,1,1,1,1,0,0,0,0,1,1,1,1,0,0,
	0,1,0,1,0,1,0,1,1,0,1,0,1,0,1,0,
	0,1,1,0,1,0,0,1,0,1,1,0,1,0,0,1,
	0,1,0,1,1,0,1,0,1,0,1,0,0,1,0,1,
	0,1,1,1,0,0,1,1,1,1,0,0,1,1,1,0,
	0,0,0,1,0,0,1,1,1,1,0,0,1,0,0,0,
	0,0,1,1,0,0,1,0,0,1,0,0,1,1,0,0,
	0,0,1,1,1,0,1,1,1,1,0,1,1,1,0,0,
	0,1,1,0,1,0,0,1,1,0,0,1,0,1,1,0,
	0,0,1,1,1,1,0,0,1,1,0,0,0,0,1,1,
	0,1,1,0,0,1,1,0,1,0,0,1,1,0,0,1,
	0,0,0,0,0,1,1,0,0,1,1,0,0,0,0,0,
	0,1,0,0,1,1,1,0,0,1,0,0,0,0,0,0,
	0,0,1,0,0,1,1,1,0,0,1,0,0,0,0,0,
	0,0,0,0,0,0,1,0,0,1,1,1,0,0,1,0,
	0,0,0,0,0,1,0,0,1,1,1,0,0,1,0,0,
	0,1,1,0,1,1,0,0,1,0,0,1,0,0,1,1,
	0,0,1,1,0,1,1,0,1,1,0,0,1,0,0,1,
	0,1,1,0,0,0,1,1,1,0,0,1,1,1,0,0,
	0,0,1,1,1,0,0,1,1,1,0,0,0,1,1,0,
	0,1,1,0,1,1,0,0,1,1,0,0,1,0,0,1,
	0,1,1,0,0,0,1,1,0,0,1,1,1,0,0,1,
	0,1,1,1,1,1,1,0,1,0,0,0,0,0,0,1,
	0,0,0,1,1,0,0,0,1,1,1,0,0,1,1,1,
	0,0,0,0,1,1,1,1,0,0,1,1,0,0,1,1,
	0,0,1,1,0,0,1,1,1,1,1,1,0,0,0,0,
	0,0,1,0,0,0,1,0,1,1,1,0,1,1,1,0,
	0,1,0,0,0,1,0,0,0,1,1,1,0,1,1,1
};

// 3-subset partition patterns (64 patterns x 16 texels).
const char[1024] PARTITION3 =
{
	0,0,1,1,0,0,1,1,0,2,2,1,2,2,2,2,
	0,0,0,1,0,0,1,1,2,2,1,1,2,2,2,1,
	0,0,0,0,2,0,0,1,2,2,1,1,2,2,1,1,
	0,2,2,2,0,0,2,2,0,0,1,1,0,1,1,1,
	0,0,0,0,0,0,0,0,1,1,2,2,1,1,2,2,
	0,0,1,1,0,0,1,1,0,0,2,2,0,0,2,2,
	0,0,2,2,0,0,2,2,1,1,1,1,1,1,1,1,
	0,0,1,1,0,0,1,1,2,2,1,1,2,2,1,1,
	0,0,0,0,0,0,0,0,1,1,1,1,2,2,2,2,
	0,0,0,0,1,1,1,1,1,1,1,1,2,2,2,2,
	0,0,0,0,1,1,1,1,2,2,2,2,2,2,2,2,
	0,0,1,2,0,0,1,2,0,0,1,2,0,0,1,2,
	0,1,1,2,0,1,1,2,0,1,1,2,0,1,1,2,
	0,1,2,2,0,1,2,2,0,1,2,2,0,1,2,2,
	0,0,1,1,0,1,1,2,1,1,2,2,1,2,2,2,
	0,0,1,1,2,0,0,1,2,2,0,0,2,2,2,0,
	0,0,0,1,0,0,1,1,0,1,1,2,1,1,2,2,
	0,1,1,1,0,0,1,1,2,0,0,1,2,2,0,0,
	0,0,0,0,1,1,2,2,1,1,2,2,1,1,2,2,
	0,0,2,2,0,0,2,2,0,0,2,2,1,1,1,1,
	0,1,1,1,0,1,1,1,0,2,2,2,0,2,2,2,
	0,0,0,1,0,0,0,1,2,2,2,1,2,2,2,1,
	0,0,0,0,0,0,1,1,0,1,2,2,0,1,2,2,
	0,0,0,0,1,1,0,0,2,2,1,0,2,2,1,0,
	0,1,2,2,0,1,2,2,0,0,1,1,0,0,0,0,
	0,0,1,2,0,0,1,2,1,1,2,2,2,2,2,2,
	0,1,1,0,1,2,2,1,1,2,2,1,0,1,1,0,
	0,0,0,0,0,1,1,0,1,2,2,1,1,2,2,1,
	0,0,2,2,1,1,0,2,1,1,0,2,0,0,2,2,
	0,1,1,0,0,1,1,0,2,0,0,2,2,2,2,2,
	0,0,1,1,0,1,2,2,0,1,2,2,0,0,1,1,
	0,0,0,0,2,0,0,0,2,2,1,1,2,2,2,1,
	0,0,0,0,0,0,0,2,1,1,2,2,1,2,2,2,
	0,2,2,2,0,0,2,2,0,0,1,2,0,0,1,1,
	0,0,1,1,0,0,1,2,0,0,2,2,0,2,2,2,
	0,1,2,0,0,1,2,0,0,1,2,0,0,1,2,0,
	0,0,0,0,1,1,1,1,2,2,2,2,0,0,0,0,
	0,1,2,0,1,2,0,1,2,0,1,2,0,1,2,0,
	0,1,2,0,2,0,1,2,1,2,0,1,0,1,2,0,
	0,0,1,1,2,2,0,0,1,1,2,2,0,0,1,1,
	0,0,1,1,1,1,2,2,2,2,0,0,0,0,1,1,
	0,1,0,1,0,1,0,1,2,2,2,2,2,2,2,2,
	0,0,0,0,0,0,0,0,2,1,2,1,2,1,2,1,
	0,0,2,2,1,1,2,2,0,0,2,2,1,1,2,2,
	0,0,2,2,0,0,1,1,0,0,2,2,0,0,1,1,
	0,2,2,0,1,2,2,1,0,2,2,0,1,2,2,1,
	0,1,0,1,2,2,2,2,2,2,2,2,0,1,0,1,
	0,0,0,0,2,1,2,1,2,1,2,1,2,1,2,1,
	0,1,0,1,0,1,0,1,0,1,0,1,2,2,2,2,
	0,2,2,2,0,1,1,1,0,2,2,2,0,1,1,1,
	0,0,0,2,1,1,1,2,0,0,0,2,1,1,1,2,
	0,0,0,0,2,1,1,2,2,1,1,2,2,1,1,2,
	0,2,2,2,0,1,1,1,0,1,1,1,0,2,2,2,
	0,0,0,2,1,1,1,2,1,1,1,2,0,0,0,2,
	0,1,1,0,0,1,1,0,0,1,1,0,2,2,2,2,
	0,0,0,0,0,0,0,0,2,1,1,2,2,1,1,2,
	0,1,1,0,0,1,1,0,2,2,2,2,2,2,2,2,
	0,0,2,2,0,0,1,1,0,0,1,1,0,0,2,2,
	0,0,2,2,1,1,2,2,1,1,2,2,0,0,2,2,
	0,0,0,0,0,0,0,0,0,0,0,0,2,1,1,2,
	0,0,0,2,0,0,0,1,0,0,0,2,0,0,0,1,
	0,2,2,2,1,2,2,2,0,2,2,2,1,2,2,2,
	0,1,0,1,2,2,2,2,2,2,2,2,2,2,2,2,
	0,1,1,1,2,0,1,1,2,2,0,1,2,2,2,0
};

// Anchor index of the second subset for 2-subset modes.
const char[64] ANCHOR_2ND_SUBSET =
{
	15,15,15,15,15,15,15,15,15,15,15,15,15,15,15,15,
	15,2,8,2,2,8,8,15,2,8,2,2,8,8,2,2,
	15,15,6,8,2,8,15,15,2,8,2,2,2,15,15,6,
	6,2,6,8,15,15,2,2,15,15,15,15,15,2,2,15
};

// Anchor index of the second subset for 3-subset modes.
const char[64] ANCHOR_3RD_SUBSET_1 =
{
	3,3,15,15,8,3,15,15,8,8,6,6,6,5,3,3,
	3,3,8,15,3,3,6,10,5,8,8,6,8,5,15,15,
	8,15,3,5,6,10,8,15,15,3,15,5,15,15,15,15,
	3,15,5,5,5,8,5,10,5,10,8,13,15,12,3,3
};

// Anchor index of the third subset for 3-subset modes.
const char[64] ANCHOR_3RD_SUBSET_2 =
{
	15,8,8,3,15,15,3,8,15,15,15,15,15,15,15,8,
	15,8,15,3,15,8,15,8,3,15,6,10,15,15,10,8,
	15,3,15,10,10,8,9,10,6,15,8,15,3,6,6,8,
	15,3,15,15,15,15,15,15,15,15,15,15,3,15,15,8
};

// ---------------------------------------------------------------------------
// Public API
// ---------------------------------------------------------------------------

<*
 Size in bytes of the BC7 encoding of a width x height image
 (ceil-div to 4x4 blocks, 16 bytes per block).
*>
fn sz encoded_size(uint width, uint height)
{
	return (sz)((width + 3) / 4) * (sz)((height + 3) / 4) * 16;
}

<*
 Encode a tightly packed RGBA8 image to BC7 blocks.
 If has_alpha is false the alpha channel of the input is ignored and the
 image is encoded as opaque. Non-multiple-of-4 dimensions are handled by
 replicating edge pixels into partial blocks.

 `fast` stops after mode 6 instead of also trying mode 1 or mode 5, which is
 roughly five times quicker. It is meant for a source that has already been
 quantised — transcoding an ETC1S or UASTC texture, where the two-subset modes
 have nothing left to recover — and not for encoding full-precision pixels.
*>
fn char[]? encode(Allocator allocator, char[] rgba, uint width, uint height, bool has_alpha = true, uint threads = 0, bool fast = false)
{
	if (rgba.len != (sz)width * (sz)height * 4) return INVALID_SIZE~;
	if (width == 0 || height == 0)
	{
		char[] empty;
		return empty;
	}
	char[] out = alloc::new_array(allocator, char, encoded_size(width, height));
	uint bw = (width + 3) / 4;
	uint bh = (height + 3) / 4;
	EncodeJob job = { .rgba = rgba, .out = out, .width = width, .height = height, .bw = bw, .has_alpha = has_alpha, .fast = fast };
	parallel::run(bh, &job, &encode_row, threads);
	return out;
}

struct EncodeJob @private
{
	char[] rgba;
	char[] out;
	uint width;
	uint height;
	uint bw;
	bool has_alpha;
	bool fast;
}

fn void encode_row(void* ctx, usz by) @private
{
	EncodeJob* j = (EncodeJob*)ctx;
	char[64] px;
	for (uint bx = 0; bx < j.bw; bx++)
	{
		extract_block(j.rgba, j.width, j.height, bx, (uint)by, j.has_alpha, &px[0]);
		encode_block(&px[0], j.out.ptr + (by * j.bw + bx) * 16, j.fast);
	}
}

// A decoded block costs roughly a tenth of a microsecond and a spawned thread
// tens of one, so a thread has to be handed a thousand blocks before it pays for
// itself. Chosen against the sizes an import actually meets: a 256x256 level and
// up spreads across cores (2.4x there, 7x at 2048x2048), a 128x128 one runs
// inline and is not made slower by asking.
const usz MIN_BLOCKS_PER_THREAD @local = 1024;

<*
 Decode BC7 blocks to a tightly packed RGBA8 image. blocks.len must equal
 encoded_size(width, height); partial edge blocks are clipped.

 Block rows are decoded on `threads` threads (0 = as many as the work is worth,
 1 = inline), the same split `encode` uses and safe for the same reason: a row
 owns its band of `out` and reads nothing another row writes, so the result is
 identical for any thread count. Unlike an encode, a small image asking for 0
 gets one thread — see `parallel::shares`.
*>
fn char[]? decode(Allocator allocator, char[] blocks, uint width, uint height, uint threads = 0)
{
	if (blocks.len != encoded_size(width, height)) return INVALID_SIZE~;
	if (width == 0 || height == 0)
	{
		char[] empty;
		return empty;
	}
	char[] out = alloc::new_array(allocator, char, (sz)width * (sz)height * 4);
	uint bw = (width + 3) / 4;
	uint bh = (height + 3) / 4;
	DecodeJob job = { .blocks = blocks, .out = out, .width = width, .height = height, .bw = bw };
	parallel::run(bh, &job, &decode_row, parallel::shares((usz)bw * bh, MIN_BLOCKS_PER_THREAD, threads));
	return out;
}

struct DecodeJob @private
{
	char[] blocks;
	char[] out;
	uint width;
	uint height;
	uint bw;
}

fn void decode_row(void* ctx, usz by) @private
{
	DecodeJob* j = (DecodeJob*)ctx;
	char[64] px;
	uint row = (uint)by;
	uint ymax = math::min(4u, j.height - row * 4);
	for (uint bx = 0; bx < j.bw; bx++)
	{
		decode_block(j.blocks.ptr + ((sz)by * (sz)j.bw + (sz)bx) * 16, &px[0]);
		uint xmax = math::min(4u, j.width - bx * 4);
		for (uint y = 0; y < ymax; y++)
		{
			for (uint x = 0; x < xmax; x++)
			{
				sz dst = ((sz)(row * 4 + y) * (sz)j.width + (sz)(bx * 4 + x)) * 4;
				uint src = (y * 4 + x) * 4;
				j.out[dst] = px[src];
				j.out[dst + 1] = px[src + 1];
				j.out[dst + 2] = px[src + 2];
				j.out[dst + 3] = px[src + 3];
			}
		}
	}
}

// ---------------------------------------------------------------------------
// Bit stream helpers (BC7 blocks are packed LSB-first)
// ---------------------------------------------------------------------------

struct BitReader
{
	char* data;
	uint pos;
}

fn uint BitReader.read(&self, uint nbits)
{
	uint v = 0;
	for (uint i = 0; i < nbits; i++)
	{
		uint bit = ((uint)self.data[self.pos >> 3] >> (self.pos & 7)) & 1;
		v |= bit << i;
		self.pos++;
	}
	return v;
}

struct BitWriter
{
	char* data;
	uint pos;
}

fn void BitWriter.put(&self, uint v, uint nbits)
{
	for (uint i = 0; i < nbits; i++)
	{
		if ((v >> i) & 1) self.data[self.pos >> 3] |= (char)(1 << (self.pos & 7));
		self.pos++;
	}
}

// ---------------------------------------------------------------------------
// Decoder
// ---------------------------------------------------------------------------

// Dequantize an endpoint value with a p-bit appended.
fn uint dequant_p(uint val, uint pbit, uint bits)
{
	uint total = bits + 1;
	uint v = (val << 1) | pbit;
	v <<= (8 - total);
	v |= v >> total;
	return v;
}

// Dequantize an endpoint value without a p-bit.
fn uint dequant(uint val, uint bits)
{
	uint v = val << (8 - bits);
	v |= v >> bits;
	return v;
}

// BC7 interpolation; w is a weight value from one of the WEIGHTS tables.
fn uint interp(uint a, uint b, uint w)
{
	return (a * (64 - w) + b * w + 32) >> 6;
}

fn uint weight_val(uint nbits, uint i)
{
	switch (nbits)
	{
		case 2: return WEIGHTS2[i];
		case 3: return WEIGHTS3[i];
		default: return WEIGHTS4[i];
	}
}

<*
 Decode one 16-byte BC7 block into 64 bytes of RGBA8 (row-major 4x4).
 A block whose first byte is zero (no mode bit in the 8 LSBs) decodes to
 transparent black, per spec.
*>
fn void decode_block(char* blk, char* px)
{
	uint first = blk[0];
	if (first == 0)
	{
		for (uint i = 0; i < 64; i++) px[i] = 0;
		return;
	}
	uint mode = 0;
	while ((first & (1u << mode)) == 0) mode++;
	switch (mode)
	{
		case 0: decode_mode0_2(0, blk, px);
		case 1: decode_mode1_3_7(1, blk, px);
		case 2: decode_mode0_2(2, blk, px);
		case 3: decode_mode1_3_7(3, blk, px);
		case 4: decode_mode4_5(4, blk, px);
		case 5: decode_mode4_5(5, blk, px);
		case 6: decode_mode6(blk, px);
		default: decode_mode1_3_7(7, blk, px);
	}
}

// Modes 0 and 2: three subsets, RGB only.
fn void decode_mode0_2(uint mode, char* blk, char* px) @private
{
	BitReader r = { blk, 0 };
	r.read(mode + 1);
	uint ebits = mode == 0 ? 4 : 5;
	uint wbits = mode == 0 ? 3 : 2;
	uint npbits = mode == 0 ? 6 : 0;
	uint part = r.read(mode == 0 ? 4 : 6);

	uint[18] ep; // [endpoint * 3 + channel], endpoints s0lo,s0hi,s1lo,s1hi,s2lo,s2hi
	for (uint c = 0; c < 3; c++)
	{
		for (uint e = 0; e < 6; e++) ep[e * 3 + c] = r.read(ebits);
	}
	uint[6] pbits;
	for (uint p = 0; p < npbits; p++) pbits[p] = r.read(1);

	uint anchor1 = ANCHOR_3RD_SUBSET_1[part];
	uint anchor2 = ANCHOR_3RD_SUBSET_2[part];
	uint[16] widx;
	for (uint i = 0; i < 16; i++)
	{
		bool anchored = i == 0 || i == anchor1 || i == anchor2;
		widx[i] = r.read(anchored ? wbits - 1 : wbits);
	}

	for (uint e = 0; e < 6; e++)
	{
		for (uint c = 0; c < 3; c++)
		{
			uint v = ep[e * 3 + c];
			ep[e * 3 + c] = npbits > 0 ? dequant_p(v, pbits[e], ebits) : dequant(v, ebits);
		}
	}

	uint nlev = 1u << wbits;
	uint[96] pal; // [subset * 32 + level * 4 + channel]
	for (uint s = 0; s < 3; s++)
	{
		for (uint i = 0; i < nlev; i++)
		{
			uint w = weight_val(wbits, i);
			for (uint c = 0; c < 3; c++)
			{
				pal[s * 32 + i * 4 + c] = interp(ep[(s * 2) * 3 + c], ep[(s * 2 + 1) * 3 + c], w);
			}
			pal[s * 32 + i * 4 + 3] = 255;
		}
	}

	for (uint i = 0; i < 16; i++)
	{
		uint s = PARTITION3[part * 16 + i];
		for (uint c = 0; c < 4; c++) px[i * 4 + c] = (char)pal[s * 32 + widx[i] * 4 + c];
	}
}

// Modes 1, 3 and 7: two subsets. Mode 7 carries alpha endpoints.
fn void decode_mode1_3_7(uint mode, char* blk, char* px) @private
{
	BitReader r = { blk, 0 };
	r.read(mode + 1);
	uint comps = mode == 7 ? 4 : 3;
	uint ebits = mode == 7 ? 5 : (mode == 1 ? 6 : 7);
	uint wbits = mode == 1 ? 3 : 2;
	uint npbits = mode == 1 ? 2 : 4;
	bool shared = mode == 1;
	uint part = r.read(6);

	uint[16] ep; // [endpoint * 4 + channel], endpoints s0lo,s0hi,s1lo,s1hi
	for (uint c = 0; c < comps; c++)
	{
		for (uint e = 0; e < 4; e++) ep[e * 4 + c] = r.read(ebits);
	}
	uint[4] pbits;
	for (uint p = 0; p < npbits; p++) pbits[p] = r.read(1);

	uint anchor = ANCHOR_2ND_SUBSET[part];
	uint[16] widx;
	for (uint i = 0; i < 16; i++)
	{
		bool anchored = i == 0 || i == anchor;
		widx[i] = r.read(anchored ? wbits - 1 : wbits);
	}

	for (uint e = 0; e < 4; e++)
	{
		uint pb = pbits[shared ? e >> 1 : e];
		for (uint c = 0; c < comps; c++) ep[e * 4 + c] = dequant_p(ep[e * 4 + c], pb, ebits);
		if (comps == 3) ep[e * 4 + 3] = 255;
	}

	uint nlev = 1u << wbits;
	uint[64] pal; // [subset * 32 + level * 4 + channel]
	for (uint s = 0; s < 2; s++)
	{
		for (uint i = 0; i < nlev; i++)
		{
			uint w = weight_val(wbits, i);
			for (uint c = 0; c < comps; c++)
			{
				pal[s * 32 + i * 4 + c] = interp(ep[(s * 2) * 4 + c], ep[(s * 2 + 1) * 4 + c], w);
			}
			if (comps == 3) pal[s * 32 + i * 4 + 3] = 255;
		}
	}

	for (uint i = 0; i < 16; i++)
	{
		uint s = PARTITION2[part * 16 + i];
		for (uint c = 0; c < 4; c++) px[i * 4 + c] = (char)pal[s * 32 + widx[i] * 4 + c];
	}
}

// Modes 4 and 5: single subset, separate color/alpha index planes,
// channel rotation; mode 4 additionally has an index-selection bit.
fn void decode_mode4_5(uint mode, char* blk, char* px) @private
{
	BitReader r = { blk, 0 };
	r.read(mode + 1);
	uint cbits = mode == 4 ? 5 : 7;
	uint abits = mode == 4 ? 6 : 8;
	uint awbits = mode == 4 ? 3 : 2; // second index plane width
	uint rot = r.read(2);
	uint isel = mode == 4 ? r.read(1) : 0;

	uint[8] ep; // [endpoint * 4 + channel]
	for (uint c = 0; c < 4; c++)
	{
		for (uint e = 0; e < 2; e++) ep[e * 4 + c] = r.read(c == 3 ? abits : cbits);
	}

	// The 2-bit index plane is always stored first; the index-selection bit
	// swaps which plane addresses color vs alpha.
	uint[16] cw;
	uint[16] aw;
	for (uint i = 0; i < 16; i++)
	{
		uint v = r.read(i == 0 ? 1 : 2);
		if (isel != 0) { aw[i] = v; } else { cw[i] = v; }
	}
	for (uint i = 0; i < 16; i++)
	{
		uint v = r.read(i == 0 ? awbits - 1 : awbits);
		if (isel != 0) { cw[i] = v; } else { aw[i] = v; }
	}
	uint cwbits = isel != 0 ? awbits : 2; // color index width
	uint awbits2 = isel != 0 ? 2 : awbits; // alpha index width

	for (uint e = 0; e < 2; e++)
	{
		for (uint c = 0; c < 4; c++) ep[e * 4 + c] = dequant(ep[e * 4 + c], c == 3 ? abits : cbits);
	}

	uint[32] cpal; // [level * 4 + channel] (rgb)
	for (uint i = 0; i < (1u << cwbits); i++)
	{
		uint w = weight_val(cwbits, i);
		for (uint c = 0; c < 3; c++) cpal[i * 4 + c] = interp(ep[c], ep[4 + c], w);
	}
	uint[8] apal;
	for (uint i = 0; i < (1u << awbits2); i++)
	{
		apal[i] = interp(ep[3], ep[7], weight_val(awbits2, i));
	}

	for (uint i = 0; i < 16; i++)
	{
		uint[4] v;
		for (uint c = 0; c < 3; c++) v[c] = cpal[cw[i] * 4 + c];
		v[3] = apal[aw[i]];
		if (rot >= 1)
		{
			uint t = v[3];
			v[3] = v[rot - 1];
			v[rot - 1] = t;
		}
		for (uint c = 0; c < 4; c++) px[i * 4 + c] = (char)v[c];
	}
}

// Mode 6: single subset, RGBA 7.7.7.7 with per-endpoint p-bits, 4-bit indices.
fn void decode_mode6(char* blk, char* px) @private
{
	BitReader r = { blk, 0 };
	r.read(7);
	uint[8] ep; // [endpoint * 4 + channel]
	for (uint c = 0; c < 4; c++)
	{
		for (uint e = 0; e < 2; e++) ep[e * 4 + c] = r.read(7);
	}
	uint p0 = r.read(1);
	uint p1 = r.read(1);
	uint[16] widx;
	for (uint i = 0; i < 16; i++) widx[i] = r.read(i == 0 ? 3 : 4);

	uint[64] pal; // [level * 4 + channel]
	for (uint i = 0; i < 16; i++)
	{
		uint w = WEIGHTS4[i];
		for (uint c = 0; c < 4; c++)
		{
			pal[i * 4 + c] = interp((ep[c] << 1) | p0, (ep[4 + c] << 1) | p1, w);
		}
	}
	for (uint i = 0; i < 16; i++)
	{
		for (uint c = 0; c < 4; c++) px[i * 4 + c] = (char)pal[widx[i] * 4 + c];
	}
}


// ---------------------------------------------------------------------------
// Block assembly (used by the Basis block transcoders in ktx::uastc_bc7 /
// ktx::etc1s_bc7, which build BC7 blocks field by field instead of encoding)
// ---------------------------------------------------------------------------

<*
 A BC7 block as its fields — exactly what `decode_block` reads back out.
 `ep` holds endpoints already in the mode's own quantization, indexed
 `[subset * 2 + low/high][channel]`; `idx` is the primary index plane and
 `idx2` the second one modes 4 and 5 carry. On mode 4 the *first* written
 plane is the 2-bit one whatever `index_selector` points it at, so a caller
 fills `idx`/`idx2` by plane width, not by meaning.

 Anchor indices must already have their high bit clear: the packer drops that
 bit rather than checking it. Swapping a subset's two endpoints and
 complementing its indices is what makes that always arrangeable, and it is
 lossless because every BC7 weight table is symmetric.
*>
struct BlockFields
{
	char mode;
	char partition;
	char rotation;
	char index_selector;
	char[4][6] ep;
	char[6] pbits;
	char[16] idx;
	char[16] idx2;
}

fn void put_bits(ulong[2]* acc, uint* pos, uint v, uint n) @private
{
	if (!n) return;
	ulong val = (ulong)v & ((1UL << n) - 1);
	uint p = *pos;
	if (p < 64)
	{
		(*acc)[0] |= val << p;
		if (p + n > 64) (*acc)[1] |= val >> (64 - p);
	}
	else
	{
		(*acc)[1] |= val << (p - 64);
	}
	*pos = p + n;
}

<* Pack one BlockFields into 16 bytes, LSB-first, per the BC7 bit layout. *>
fn void pack_fields(char* out, BlockFields* f)
{
	ulong[2] acc;
	uint pos;
	uint mode = f.mode;
	put_bits(&acc, &pos, 1u << mode, mode + 1);
	if (MODE_ROTATION_BITS[mode] != 0) put_bits(&acc, &pos, (uint)f.rotation, 2);
	if (MODE_INDEX_SEL_BITS[mode] != 0) put_bits(&acc, &pos, (uint)f.index_selector, 1);
	if (MODE_PARTITION_BITS[mode] != 0) put_bits(&acc, &pos, (uint)f.partition, (uint)MODE_PARTITION_BITS[mode]);

	uint subsets = MODE_SUBSETS[mode];
	uint ne = subsets * 2;
	uint cbits = MODE_COLOR_BITS[mode];
	uint abits = MODE_ALPHA_BITS[mode];
	uint comps = abits != 0 ? 4 : 3;
	for (uint c = 0; c < comps; c++)
	{
		uint bits = c == 3 ? abits : cbits;
		for (uint e = 0; e < ne; e++) put_bits(&acc, &pos, (uint)f.ep[e][c], bits);
	}
	switch (MODE_PBIT_TYPE[mode])
	{
		case PBIT_PER_ENDPOINT:
			for (uint e = 0; e < ne; e++) put_bits(&acc, &pos, (uint)f.pbits[e], 1);
		case PBIT_SHARED:
			for (uint s = 0; s < subsets; s++) put_bits(&acc, &pos, (uint)f.pbits[s], 1);
		default:
			break;
	}

	uint ibits = MODE_INDEX_BITS[mode];
	uint i2bits = MODE_INDEX2_BITS[mode];
	if (i2bits != 0)
	{
		for (uint i = 0; i < 16; i++) put_bits(&acc, &pos, (uint)f.idx[i], i == 0 ? ibits - 1 : ibits);
		for (uint i = 0; i < 16; i++) put_bits(&acc, &pos, (uint)f.idx2[i], i == 0 ? i2bits - 1 : i2bits);
	}
	else
	{
		uint a1 = 16;
		uint a2 = 16;
		if (subsets == 2) a1 = ANCHOR_2ND_SUBSET[f.partition];
		if (subsets == 3)
		{
			a1 = ANCHOR_3RD_SUBSET_1[f.partition];
			a2 = ANCHOR_3RD_SUBSET_2[f.partition];
		}
		for (uint i = 0; i < 16; i++)
		{
			bool anchor = i == 0 || i == a1 || i == a2;
			put_bits(&acc, &pos, (uint)f.idx[i], anchor ? ibits - 1 : ibits);
		}
	}

	for (uint i = 0; i < 8; i++)
	{
		out[i] = (char)(acc[0] >> (i * 8));
		out[8 + i] = (char)(acc[1] >> (i * 8));
	}
}

// ---------------------------------------------------------------------------
// Encoder
// ---------------------------------------------------------------------------

fn void extract_block(char[] rgba, uint width, uint height, uint bx, uint by, bool has_alpha, char* px) @private
{
	for (uint y = 0; y < 4; y++)
	{
		uint sy = math::min(by * 4 + y, height - 1);
		for (uint x = 0; x < 4; x++)
		{
			uint sx = math::min(bx * 4 + x, width - 1);
			sz src = ((sz)sy * (sz)width + (sz)sx) * 4;
			uint dst = (y * 4 + x) * 4;
			px[dst] = rgba[src];
			px[dst + 1] = rgba[src + 1];
			px[dst + 2] = rgba[src + 2];
			px[dst + 3] = has_alpha ? rgba[src + 3] : (char)255;
		}
	}
}

fn ulong block_sse(char* a, char* b) @private
{
	ulong total = 0;
	for (uint i = 0; i < 64; i++)
	{
		int d = (int)a[i] - (int)b[i];
		total += (ulong)(d * d);
	}
	return total;
}

<*
 Encode one 4x4 RGBA8 block (64 bytes, row-major) into a 16-byte BC7 block.
 Mode 6 is always evaluated; mode 1 is added for opaque blocks and mode 5
 for blocks with non-opaque alpha. The winner is picked by squared error
 against the actual decoded block.
*>
fn void encode_block(char* px, char* dst, bool fast = false)
{
	bool opaque = true;
	for (uint i = 0; i < 16; i++)
	{
		if (px[i * 4 + 3] != 255)
		{
			opaque = false;
			break;
		}
	}

	char[16] cand;
	char[64] dec;

	encode_mode6(px, &cand[0]);
	decode_block(&cand[0], &dec[0]);
	ulong best_err = block_sse(px, &dec[0]);
	for (uint i = 0; i < 16; i++) dst[i] = cand[i];
	if (best_err == 0) return;
	// Mode 6 alone, for a caller whose source is already block-quantised.
	if (fast) return;

	char[16] cand2;
	if (opaque)
	{
		encode_mode1(px, &cand2[0]);
	}
	else
	{
		encode_mode5(px, &cand2[0]);
	}
	decode_block(&cand2[0], &dec[0]);
	ulong err2 = block_sse(px, &dec[0]);
	if (err2 < best_err)
	{
		for (uint i = 0; i < 16; i++) dst[i] = cand2[i];
	}
}

// --- shared encoder helpers -------------------------------------------------

// PCA (power iteration on the covariance matrix) initial endpoints for a
// subset of texels; falls back to the bounding-box diagonal, then to the mean.
fn void initial_endpoints(char* px, uint* texels, uint ntex, bool use_alpha, double* lo, double* hi) @private
{
	uint comps = use_alpha ? 4 : 3;
	double[4] mean;
	for (uint j = 0; j < ntex; j++)
	{
		uint t = texels[j];
		for (uint c = 0; c < comps; c++) mean[c] += (double)px[t * 4 + c];
	}
	for (uint c = 0; c < comps; c++) mean[c] /= (double)ntex;

	double[16] cov;
	for (uint j = 0; j < ntex; j++)
	{
		uint t = texels[j];
		double[4] d;
		for (uint c = 0; c < comps; c++) d[c] = (double)px[t * 4 + c] - mean[c];
		for (uint a = 0; a < comps; a++)
		{
			for (uint b = 0; b < comps; b++) cov[a * 4 + b] += d[a] * d[b];
		}
	}

	// Power iteration, seeded with the per-channel variances.
	double[4] axis;
	for (uint c = 0; c < 4; c++) axis[c] = cov[c * 4 + c];
	bool ok = false;
	for (uint it = 0; it < 8; it++)
	{
		double[4] nv;
		for (uint a = 0; a < comps; a++)
		{
			double s = 0;
			for (uint b = 0; b < comps; b++) s += cov[a * 4 + b] * axis[b];
			nv[a] = s;
		}
		double m = 0;
		for (uint c = 0; c < comps; c++) m = math::max(m, math::abs(nv[c]));
		if (m < 1e-10)
		{
			ok = false;
			break;
		}
		for (uint c = 0; c < comps; c++) axis[c] = nv[c] / m;
		ok = true;
	}
	if (!ok)
	{
		// Fall back to the bounding box diagonal.
		double[4] bmin = { 255, 255, 255, 255 };
		double[4] bmax;
		for (uint j = 0; j < ntex; j++)
		{
			uint t = texels[j];
			for (uint c = 0; c < comps; c++)
			{
				double v = (double)px[t * 4 + c];
				bmin[c] = math::min(bmin[c], v);
				bmax[c] = math::max(bmax[c], v);
			}
		}
		for (uint c = 0; c < comps; c++) axis[c] = bmax[c] - bmin[c];
	}
	double len = 0;
	for (uint c = 0; c < comps; c++) len += axis[c] * axis[c];
	len = math::sqrt(len);
	if (len < 1e-10)
	{
		// Solid block: both endpoints at the mean.
		for (uint c = 0; c < 4; c++)
		{
			lo[c] = mean[c];
			hi[c] = mean[c];
		}
		if (!use_alpha)
		{
			lo[3] = 255;
			hi[3] = 255;
		}
		return;
	}
	for (uint c = 0; c < comps; c++) axis[c] /= len;

	double dmin = 1e30;
	double dmax = -1e30;
	for (uint j = 0; j < ntex; j++)
	{
		uint t = texels[j];
		double d = 0;
		for (uint c = 0; c < comps; c++) d += ((double)px[t * 4 + c] - mean[c]) * axis[c];
		dmin = math::min(dmin, d);
		dmax = math::max(dmax, d);
	}
	for (uint c = 0; c < comps; c++)
	{
		lo[c] = math::clamp(mean[c] + dmin * axis[c], 0.0, 255.0);
		hi[c] = math::clamp(mean[c] + dmax * axis[c], 0.0, 255.0);
	}
	if (!use_alpha)
	{
		lo[3] = 255;
		hi[3] = 255;
	}
}

// Assign to each texel the palette level with least squared error.
// pal holds nlev entries of 4 channels; idx is written by list position.
fn ulong assign_indices(char* px, uint* texels, uint ntex, uint* pal, uint nlev, bool use_alpha, uint* idx) @private
{
	uint comps = use_alpha ? 4 : 3;
	ulong total = 0;
	for (uint j = 0; j < ntex; j++)
	{
		uint t = texels[j];
		ulong best = ulong::max;
		uint best_l = 0;
		for (uint l = 0; l < nlev; l++)
		{
			ulong e = 0;
			for (uint c = 0; c < comps; c++)
			{
				int d = (int)pal[l * 4 + c] - (int)px[t * 4 + c];
				e += (ulong)(d * d);
			}
			if (e < best)
			{
				best = e;
				best_l = l;
			}
		}
		idx[j] = best_l;
		total += best;
	}
	return total;
}

// Least-squares endpoint refinement from the current index assignment
// (normal equations). Returns false if the system is singular.
fn bool ls_refine(char* px, uint* texels, uint ntex, uint* idx, uint wbits, double* lo, double* hi) @private
{
	double z00 = 0;
	double z01 = 0;
	double z11 = 0;
	double[4] b0;
	double[4] b1;
	for (uint j = 0; j < ntex; j++)
	{
		uint t = texels[j];
		double f = (double)weight_val(wbits, idx[j]) / 64.0;
		double a = 1.0 - f;
		z00 += a * a;
		z01 += a * f;
		z11 += f * f;
		for (uint c = 0; c < 4; c++)
		{
			double p = (double)px[t * 4 + c];
			b0[c] += a * p;
			b1[c] += f * p;
		}
	}
	double det = z00 * z11 - z01 * z01;
	if (math::abs(det) < 1e-8) return false;
	double inv = 1.0 / det;
	for (uint c = 0; c < 4; c++)
	{
		lo[c] = math::clamp((z11 * b0[c] - z01 * b1[c]) * inv, 0.0, 255.0);
		hi[c] = math::clamp((z00 * b1[c] - z01 * b0[c]) * inv, 0.0, 255.0);
	}
	return true;
}

// --- mode 6 ------------------------------------------------------------------

// Best 7-bit endpoint value for target t given p-bit p (decoded value 2v+p).
fn uint quant7p(double t, uint p) @private
{
	int v = (int)math::round((t - (double)p) * 0.5);
	return (uint)math::clamp(v, 0, 127);
}

// Quantize float endpoints for mode 6 (tries all four p-bit combinations),
// assign 4-bit indices against the decoded palette, return the squared error.
fn ulong quantize6(double* lo, double* hi, char* px, uint* texels, uint* q0, uint* q1, uint* p0, uint* p1, uint* idx) @private
{
	ulong best = ulong::max;
	for (uint pa = 0; pa < 2; pa++)
	{
		for (uint pb = 0; pb < 2; pb++)
		{
			uint[4] c0;
			uint[4] c1;
			for (uint c = 0; c < 4; c++)
			{
				c0[c] = quant7p(lo[c], pa);
				c1[c] = quant7p(hi[c], pb);
			}
			uint[64] pal;
			for (uint l = 0; l < 16; l++)
			{
				uint w = WEIGHTS4[l];
				for (uint c = 0; c < 4; c++)
				{
					pal[l * 4 + c] = interp((c0[c] << 1) | pa, (c1[c] << 1) | pb, w);
				}
			}
			uint[16] tidx;
			ulong err = assign_indices(px, texels, 16, &pal[0], 16, true, &tidx[0]);
			if (err < best)
			{
				best = err;
				for (uint c = 0; c < 4; c++)
				{
					q0[c] = c0[c];
					q1[c] = c1[c];
				}
				*p0 = pa;
				*p1 = pb;
				for (uint i = 0; i < 16; i++) idx[i] = tidx[i];
			}
		}
	}
	return best;
}

fn void pack_mode6(char* out, uint* q0, uint* q1, uint p0, uint p1, uint* idx) @private
{
	BitWriter w = { out, 0 };
	w.put(64, 7); // mode bits
	for (uint c = 0; c < 4; c++)
	{
		w.put(q0[c], 7);
		w.put(q1[c], 7);
	}
	w.put(p0, 1);
	w.put(p1, 1);
	for (uint i = 0; i < 16; i++) w.put(idx[i], i == 0 ? 3 : 4);
}

fn void encode_mode6(char* px, char* out) @private
{
	uint[16] texels;
	for (uint i = 0; i < 16; i++) texels[i] = i;

	double[4] lo;
	double[4] hi;
	initial_endpoints(px, &texels[0], 16, true, &lo[0], &hi[0]);

	uint[4] q0;
	uint[4] q1;
	uint p0;
	uint p1;
	uint[16] idx;
	uint[4] bq0;
	uint[4] bq1;
	uint bp0;
	uint bp1;
	uint[16] bidx;
	ulong best = ulong::max;
	for (uint it = 0; it < 4; it++)
	{
		ulong err = quantize6(&lo[0], &hi[0], px, &texels[0], &q0[0], &q1[0], &p0, &p1, &idx[0]);
		if (err < best)
		{
			best = err;
			for (uint c = 0; c < 4; c++)
			{
				bq0[c] = q0[c];
				bq1[c] = q1[c];
			}
			bp0 = p0;
			bp1 = p1;
			for (uint i = 0; i < 16; i++) bidx[i] = idx[i];
		}
		if (best == 0 || it == 3) break;
		if (!ls_refine(px, &texels[0], 16, &idx[0], 4, &lo[0], &hi[0])) break;
	}

	// Anchor rule: texel 0 index MSB must be 0.
	if (bidx[0] >= 8)
	{
		for (uint c = 0; c < 4; c++)
		{
			uint t = bq0[c];
			bq0[c] = bq1[c];
			bq1[c] = t;
		}
		uint t = bp0;
		bp0 = bp1;
		bp1 = t;
		for (uint i = 0; i < 16; i++) bidx[i] = 15 - bidx[i];
	}
	pack_mode6(out, &bq0[0], &bq1[0], bp0, bp1, &bidx[0]);
}

// --- mode 1 ------------------------------------------------------------------

// Best 6-bit endpoint value for target t given shared p-bit p.
fn uint quant6p(double t, uint p) @private
{
	uint best_v = 0;
	double best_e = 1e30;
	for (uint v = 0; v < 64; v++)
	{
		double d = (double)dequant_p(v, p, 6) - t;
		double e = d * d;
		if (e < best_e)
		{
			best_e = e;
			best_v = v;
		}
	}
	return best_v;
}

// Cheap per-partition error estimate: per-subset bounding-box diagonal fit
// with 3-bit index quantization (no endpoint quantization).
fn double estimate_partition2(char* px, uint part) @private
{
	double err = 0;
	for (uint s = 0; s < 2; s++)
	{
		double[3] bmin = { 255, 255, 255 };
		double[3] bmax;
		for (uint i = 0; i < 16; i++)
		{
			if (PARTITION2[part * 16 + i] != s) continue;
			for (uint c = 0; c < 3; c++)
			{
				double v = (double)px[i * 4 + c];
				bmin[c] = math::min(bmin[c], v);
				bmax[c] = math::max(bmax[c], v);
			}
		}
		double[3] d;
		double len2 = 0;
		for (uint c = 0; c < 3; c++)
		{
			d[c] = bmax[c] - bmin[c];
			len2 += d[c] * d[c];
		}
		for (uint i = 0; i < 16; i++)
		{
			if (PARTITION2[part * 16 + i] != s) continue;
			if (len2 < 1e-10)
			{
				for (uint c = 0; c < 3; c++)
				{
					double e = (double)px[i * 4 + c] - bmin[c];
					err += e * e;
				}
				continue;
			}
			double t = 0;
			for (uint c = 0; c < 3; c++) t += ((double)px[i * 4 + c] - bmin[c]) * d[c];
			t = math::clamp(t / len2, 0.0, 1.0);
			uint k = (uint)(t * 7.0 + 0.5);
			double f = (double)WEIGHTS3[k] / 64.0;
			for (uint c = 0; c < 3; c++)
			{
				double e = bmin[c] + d[c] * f - (double)px[i * 4 + c];
				err += e * e;
			}
		}
	}
	return err;
}

// Quantize a mode 1 subset (RGB 6.6.6, shared p-bit, 3-bit indices); tries
// both p-bit values, assigns indices against the decoded palette.
fn ulong quantize1(double* lo, double* hi, char* px, uint* texels, uint ntex, uint* q0, uint* q1, uint* pbit, uint* idx) @private
{
	ulong best = ulong::max;
	for (uint p = 0; p < 2; p++)
	{
		uint[3] c0;
		uint[3] c1;
		for (uint c = 0; c < 3; c++)
		{
			c0[c] = quant6p(lo[c], p);
			c1[c] = quant6p(hi[c], p);
		}
		uint[32] pal;
		for (uint l = 0; l < 8; l++)
		{
			uint w = WEIGHTS3[l];
			for (uint c = 0; c < 3; c++)
			{
				pal[l * 4 + c] = interp(dequant_p(c0[c], p, 6), dequant_p(c1[c], p, 6), w);
			}
		}
		uint[16] tidx;
		ulong err = assign_indices(px, texels, ntex, &pal[0], 8, false, &tidx[0]);
		if (err < best)
		{
			best = err;
			for (uint c = 0; c < 3; c++)
			{
				q0[c] = c0[c];
				q1[c] = c1[c];
			}
			*pbit = p;
			for (uint j = 0; j < ntex; j++) idx[j] = tidx[j];
		}
	}
	return best;
}

fn ulong encode_subset_m1(char* px, uint* texels, uint ntex, uint* bq0, uint* bq1, uint* bp, uint* bidx) @private
{
	double[4] lo;
	double[4] hi;
	initial_endpoints(px, texels, ntex, false, &lo[0], &hi[0]);

	uint[3] q0;
	uint[3] q1;
	uint p;
	uint[16] idx;
	ulong best = ulong::max;
	for (uint it = 0; it < 3; it++)
	{
		ulong err = quantize1(&lo[0], &hi[0], px, texels, ntex, &q0[0], &q1[0], &p, &idx[0]);
		if (err < best)
		{
			best = err;
			for (uint c = 0; c < 3; c++)
			{
				bq0[c] = q0[c];
				bq1[c] = q1[c];
			}
			*bp = p;
			for (uint j = 0; j < ntex; j++) bidx[j] = idx[j];
		}
		if (best == 0 || it == 2) break;
		if (!ls_refine(px, texels, ntex, &idx[0], 3, &lo[0], &hi[0])) break;
	}
	return best;
}

fn void pack_mode1(char* out, uint part, uint* ep, uint* pb, uint* idx16) @private
{
	// ep: [endpoint * 3 + channel], endpoints s0lo,s0hi,s1lo,s1hi
	BitWriter w = { out, 0 };
	w.put(2, 2); // mode bits
	w.put(part, 6);
	for (uint c = 0; c < 3; c++)
	{
		for (uint e = 0; e < 4; e++) w.put(ep[e * 3 + c], 6);
	}
	w.put(pb[0], 1);
	w.put(pb[1], 1);
	uint anchor = ANCHOR_2ND_SUBSET[part];
	for (uint i = 0; i < 16; i++)
	{
		bool anchored = i == 0 || i == anchor;
		w.put(idx16[i], anchored ? 2 : 3);
	}
}

fn void encode_mode1(char* px, char* out) @private
{
	// Cheap error estimate for all 64 partitions, keep the best candidates.
	const uint NCAND = 8;
	uint[NCAND] cand;
	double[NCAND] cerr;
	for (uint i = 0; i < NCAND; i++) cerr[i] = 1e30;
	for (uint part = 0; part < 64; part++)
	{
		double e = estimate_partition2(px, part);
		// Insertion into the sorted candidate list.
		uint at = NCAND;
		while (at > 0 && e < cerr[at - 1]) at--;
		if (at == NCAND) continue;
		for (uint j = NCAND - 1; j > at; j--)
		{
			cerr[j] = cerr[j - 1];
			cand[j] = cand[j - 1];
		}
		cerr[at] = e;
		cand[at] = part;
	}

	ulong best = ulong::max;
	for (uint ci = 0; ci < NCAND; ci++)
	{
		uint part = cand[ci];
		uint[16] tex0;
		uint[16] tex1;
		uint n0 = 0;
		uint n1 = 0;
		for (uint i = 0; i < 16; i++)
		{
			if (PARTITION2[part * 16 + i] == 0)
			{
				tex0[n0++] = i;
			}
			else
			{
				tex1[n1++] = i;
			}
		}

		uint[3] q00;
		uint[3] q01;
		uint pb0;
		uint[16] idx0;
		uint[3] q10;
		uint[3] q11;
		uint pb1;
		uint[16] idx1;
		ulong err = encode_subset_m1(px, &tex0[0], n0, &q00[0], &q01[0], &pb0, &idx0[0]);
		err += encode_subset_m1(px, &tex1[0], n1, &q10[0], &q11[0], &pb1, &idx1[0]);
		if (err >= best) continue;
		best = err;

		// Merge subset indices into texel order.
		uint[16] idx16;
		for (uint j = 0; j < n0; j++) idx16[tex0[j]] = idx0[j];
		for (uint j = 0; j < n1; j++) idx16[tex1[j]] = idx1[j];

		// Anchor fix-ups: the anchored texel of each subset must have its
		// index MSB clear; otherwise swap that subset's endpoints and invert
		// its indices (the shared p-bit is unaffected).
		uint[12] ep; // [endpoint * 3 + channel]
		for (uint c = 0; c < 3; c++)
		{
			ep[0 * 3 + c] = q00[c];
			ep[1 * 3 + c] = q01[c];
			ep[2 * 3 + c] = q10[c];
			ep[3 * 3 + c] = q11[c];
		}
		uint anchor1 = ANCHOR_2ND_SUBSET[part];
		if (idx16[0] >= 4)
		{
			for (uint c = 0; c < 3; c++)
			{
				uint t = ep[0 * 3 + c];
				ep[0 * 3 + c] = ep[1 * 3 + c];
				ep[1 * 3 + c] = t;
			}
			for (uint j = 0; j < n0; j++) idx16[tex0[j]] = 7 - idx16[tex0[j]];
		}
		if (idx16[anchor1] >= 4)
		{
			for (uint c = 0; c < 3; c++)
			{
				uint t = ep[2 * 3 + c];
				ep[2 * 3 + c] = ep[3 * 3 + c];
				ep[3 * 3 + c] = t;
			}
			for (uint j = 0; j < n1; j++) idx16[tex1[j]] = 7 - idx16[tex1[j]];
		}
		uint[2] pb = { pb0, pb1 };
		for (uint i = 0; i < 16; i++) out[i] = 0;
		pack_mode1(out, part, &ep[0], &pb[0], &idx16[0]);
	}
}

// --- mode 5 ------------------------------------------------------------------

// Best 7-bit endpoint value (no p-bit) for target t.
fn uint quant7(double t) @private
{
	uint best_v = 0;
	double best_e = 1e30;
	for (uint v = 0; v < 128; v++)
	{
		double d = (double)dequant(v, 7) - t;
		double e = d * d;
		if (e < best_e)
		{
			best_e = e;
			best_v = v;
		}
	}
	return best_v;
}

fn ulong quantize5c(double* lo, double* hi, char* px, uint* texels, uint* q0, uint* q1, uint* idx) @private
{
	for (uint c = 0; c < 3; c++)
	{
		q0[c] = quant7(lo[c]);
		q1[c] = quant7(hi[c]);
	}
	uint[16] pal;
	for (uint l = 0; l < 4; l++)
	{
		uint w = WEIGHTS2[l];
		for (uint c = 0; c < 3; c++)
		{
			pal[l * 4 + c] = interp(dequant(q0[c], 7), dequant(q1[c], 7), w);
		}
	}
	return assign_indices(px, texels, 16, &pal[0], 4, false, idx);
}

fn void pack_mode5(char* out, uint* q0, uint* q1, uint a0, uint a1, uint* cidx, uint* aidx) @private
{
	BitWriter w = { out, 0 };
	w.put(32, 6); // mode bits
	w.put(0, 2);  // rotation 0
	for (uint c = 0; c < 3; c++)
	{
		w.put(q0[c], 7);
		w.put(q1[c], 7);
	}
	w.put(a0, 8);
	w.put(a1, 8);
	for (uint i = 0; i < 16; i++) w.put(cidx[i], i == 0 ? 1 : 2);
	for (uint i = 0; i < 16; i++) w.put(aidx[i], i == 0 ? 1 : 2);
}

fn void encode_mode5(char* px, char* out) @private
{
	uint[16] texels;
	for (uint i = 0; i < 16; i++) texels[i] = i;

	// Color endpoints (7.7.7, 2-bit indices).
	double[4] lo;
	double[4] hi;
	initial_endpoints(px, &texels[0], 16, false, &lo[0], &hi[0]);
	uint[3] q0;
	uint[3] q1;
	uint[16] cidx;
	uint[3] bq0;
	uint[3] bq1;
	uint[16] bcidx;
	ulong cbest = ulong::max;
	for (uint it = 0; it < 3; it++)
	{
		ulong err = quantize5c(&lo[0], &hi[0], px, &texels[0], &q0[0], &q1[0], &cidx[0]);
		if (err < cbest)
		{
			cbest = err;
			for (uint c = 0; c < 3; c++)
			{
				bq0[c] = q0[c];
				bq1[c] = q1[c];
			}
			for (uint i = 0; i < 16; i++) bcidx[i] = cidx[i];
		}
		if (cbest == 0 || it == 2) break;
		if (!ls_refine(px, &texels[0], 16, &cidx[0], 2, &lo[0], &hi[0])) break;
	}

	// Alpha endpoints (8-bit, 2-bit indices), scalar fit.
	double alo = 255;
	double ahi = 0;
	for (uint i = 0; i < 16; i++)
	{
		double a = (double)px[i * 4 + 3];
		alo = math::min(alo, a);
		ahi = math::max(ahi, a);
	}
	uint qa0 = 0;
	uint qa1 = 0;
	uint[16] aidx;
	uint bqa0 = 0;
	uint bqa1 = 0;
	uint[16] baidx;
	ulong abest = ulong::max;
	for (uint it = 0; it < 3; it++)
	{
		qa0 = (uint)math::clamp((int)math::round(alo), 0, 255);
		qa1 = (uint)math::clamp((int)math::round(ahi), 0, 255);
		uint[4] apal;
		for (uint l = 0; l < 4; l++) apal[l] = interp(qa0, qa1, WEIGHTS2[l]);
		ulong err = 0;
		for (uint i = 0; i < 16; i++)
		{
			uint a = px[i * 4 + 3];
			ulong best_e = ulong::max;
			uint best_l = 0;
			for (uint l = 0; l < 4; l++)
			{
				int d = (int)apal[l] - (int)a;
				ulong e = (ulong)(d * d);
				if (e < best_e)
				{
					best_e = e;
					best_l = l;
				}
			}
			aidx[i] = best_l;
			err += best_e;
		}
		if (err < abest)
		{
			abest = err;
			bqa0 = qa0;
			bqa1 = qa1;
			for (uint i = 0; i < 16; i++) baidx[i] = aidx[i];
		}
		if (abest == 0 || it == 2) break;
		// Scalar least squares on alpha.
		double z00 = 0;
		double z01 = 0;
		double z11 = 0;
		double b0 = 0;
		double b1 = 0;
		for (uint i = 0; i < 16; i++)
		{
			double f = (double)WEIGHTS2[aidx[i]] / 64.0;
			double a = 1.0 - f;
			double p = (double)px[i * 4 + 3];
			z00 += a * a;
			z01 += a * f;
			z11 += f * f;
			b0 += a * p;
			b1 += f * p;
		}
		double det = z00 * z11 - z01 * z01;
		if (math::abs(det) < 1e-8) break;
		double inv = 1.0 / det;
		alo = math::clamp((z11 * b0 - z01 * b1) * inv, 0.0, 255.0);
		ahi = math::clamp((z00 * b1 - z01 * b0) * inv, 0.0, 255.0);
	}

	// Anchor fix-ups (texel 0, per index plane).
	if (bcidx[0] >= 2)
	{
		for (uint c = 0; c < 3; c++)
		{
			uint t = bq0[c];
			bq0[c] = bq1[c];
			bq1[c] = t;
		}
		for (uint i = 0; i < 16; i++) bcidx[i] = 3 - bcidx[i];
	}
	if (baidx[0] >= 2)
	{
		uint t = bqa0;
		bqa0 = bqa1;
		bqa1 = t;
		for (uint i = 0; i < 16; i++) baidx[i] = 3 - baidx[i];
	}
	pack_mode5(out, &bq0[0], &bq1[0], bqa0, bqa1, &bcidx[0], &baidx[0]);
}
