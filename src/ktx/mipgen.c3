// Mipmap generation for RGBA8 pixel data.
//
// 2x2 box filter with edge clamping. sRGB data is linearized before
// averaging and re-encoded after (alpha always averaged linearly);
// normal maps can be renormalized after filtering so mip levels keep
// unit-length vectors (matters for BC5 two-channel normal storage).
module ktx::mipgen;
import ktx::parallel;
import std::math;

struct Options
{
	bool srgb;          // filter color channels in linear space
	bool renormalize;   // treat RGB as an XYZ unit vector, renormalize after filtering
}

<* Number of levels in a full mip chain for the given base dimensions. *>
fn uint chain_length(uint width, uint height)
{
	uint levels = 1;
	uint m = max(width, height);
	while (m > 1)
	{
		m >>= 1;
		++levels;
	}
	return levels;
}

// An output row is a pow per colour channel, which is two orders of magnitude
// more than a decoded texel, so a thread pays for itself far sooner than in a
// decode. Four thousand pixels is where the spawn disappears into the work.
const usz MIN_PIXELS_PER_THREAD @local = 4096;

struct LevelJob @local
{
	char[] rgba;
	char[] out;
	uint width;
	uint height;
	uint dw;
	Options opts;
}

<*
 Downsample one RGBA8 image to the next mip size
 (max(1, w>>1) x max(1, h>>1)). Returns a newly allocated buffer.

 Output rows are filtered on `threads` threads — 1 inline, 0 as many as the work
 is worth. Each row writes only its own band of the result and reads only the two
 source rows above it, so the bytes are the same whatever the count is.

 @param threads : `The caller's request. 1 is the default because most callers hold a whole image and a chain is mostly small levels; a caller with one large level to filter and the machine to itself asks for more.`
*>
fn char[] next_level(Allocator allocator, char[] rgba, uint width, uint height, Options opts = {}, uint threads = 1)
{
	uint dw = max(width >> 1, 1u);
	uint dh = max(height >> 1, 1u);
	char[] out = alloc::new_array(allocator, char, (sz)dw * dh * 4);

	// Built here rather than inside a row: the table is lazy and a spawned row
	// would race the others to fill it.
	if (opts.srgb) srgb_to_linear(0);

	LevelJob job = { .rgba = rgba, .out = out, .width = width, .height = height, .dw = dw, .opts = opts };
	uint use = parallel::shares((sz)dw * dh, MIN_PIXELS_PER_THREAD, threads);
	usz worth = ((sz)dw * dh) / MIN_PIXELS_PER_THREAD;
	if ((usz)use > worth) use = worth < 1 ? 1 : (uint)worth;
	parallel::run(dh, &job, &level_row, use);
	return out;
}

fn void level_row(void* ctx, usz row) @local
{
	LevelJob* j = (LevelJob*)ctx;
	char[] rgba = j.rgba;
	char[] out = j.out;
	uint width = j.width;
	uint height = j.height;
	uint dw = j.dw;
	Options opts = j.opts;
	uint y = (uint)row;

	// Source rows, clamped for odd/1-pixel dimensions.
	uint sy0 = min(y * 2, height - 1);
	uint sy1 = min(y * 2 + 1, height - 1);
	for (uint x = 0; x < dw; ++x)
	{
		uint sx0 = min(x * 2, width - 1);
		uint sx1 = min(x * 2 + 1, width - 1);
		sz i00 = ((sz)sy0 * width + sx0) * 4;
		sz i10 = ((sz)sy0 * width + sx1) * 4;
		sz i01 = ((sz)sy1 * width + sx0) * 4;
		sz i11 = ((sz)sy1 * width + sx1) * 4;
		sz o = ((sz)y * dw + x) * 4;

		for (uint c = 0; c < 4; ++c)
		{
			if (opts.srgb && c < 3)
			{
				float sum = srgb_to_linear(rgba[i00 + c]) + srgb_to_linear(rgba[i10 + c])
					+ srgb_to_linear(rgba[i01 + c]) + srgb_to_linear(rgba[i11 + c]);
				out[o + c] = linear_to_srgb(sum * 0.25f);
			}
			else
			{
				uint sum = (uint)rgba[i00 + c] + rgba[i10 + c] + rgba[i01 + c] + rgba[i11 + c];
				out[o + c] = (char)((sum + 2) >> 2);
			}
		}

		if (opts.renormalize)
		{
			float nx = (float)out[o] * (2.0f / 255.0f) - 1.0f;
			float ny = (float)out[o + 1] * (2.0f / 255.0f) - 1.0f;
			float nz = (float)out[o + 2] * (2.0f / 255.0f) - 1.0f;
			float len = math::sqrt(nx * nx + ny * ny + nz * nz);
			if (len > 1e-5f)
			{
				nx /= len;
				ny /= len;
				nz /= len;
				out[o] = (char)math::clamp((nx * 0.5f + 0.5f) * 255.0f + 0.5f, 0.0f, 255.0f);
				out[o + 1] = (char)math::clamp((ny * 0.5f + 0.5f) * 255.0f + 0.5f, 0.0f, 255.0f);
				out[o + 2] = (char)math::clamp((nz * 0.5f + 0.5f) * 255.0f + 0.5f, 0.0f, 255.0f);
			}
		}
	}
}

float[256] linear_lut @local;
bool lut_ready @local;

fn float srgb_to_linear(char v) @local
{
	if (!lut_ready)
	{
		for (uint i = 0; i < 256; ++i)
		{
			float f = (float)i / 255.0f;
			linear_lut[i] = f <= 0.04045f ? f / 12.92f : math::pow((f + 0.055f) / 1.055f, 2.4f);
		}
		lut_ready = true;
	}
	return linear_lut[v];
}

fn char linear_to_srgb(float f) @local
{
	f = math::clamp(f, 0.0f, 1.0f);
	float s = f <= 0.0031308f ? f * 12.92f : 1.055f * math::pow(f, 1.0f / 2.4f) - 0.055f;
	return (char)(s * 255.0f + 0.5f);
}
