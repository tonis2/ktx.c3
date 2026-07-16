module mipgen_tests @test;
import ktx::mipgen;

fn void chain_length_matches_spec()
{
	assert(mipgen::chain_length(1, 1) == 1);
	assert(mipgen::chain_length(2, 2) == 2);
	assert(mipgen::chain_length(64, 64) == 7);
	assert(mipgen::chain_length(64, 4) == 7);
	assert(mipgen::chain_length(5, 3) == 3);   // 5x3 -> 2x1 -> 1x1
}

fn void box_filter_averages()
{
	// 2x2 -> 1x1: plain average in linear (non-srgb) mode.
	char[16] src = {
		10, 0, 0, 255,   20, 0, 0, 255,
		30, 0, 0, 255,   40, 0, 0, 255,
	};
	char[] mip = mipgen::next_level(mem, src[..], 2, 2);
	defer free(mip);
	assert(mip.len == 4);
	assert(mip[0] == 25 && mip[3] == 255);   // (10+20+30+40+2)/4 = 25
}

fn void srgb_filtering_brightens_midpoint()
{
	// Averaging 0 and 255 in sRGB space must NOT give 127 (linear average)
	// but ~188 (the sRGB encoding of linear 0.5).
	char[16] src = {
		0, 0, 0, 255,   255, 255, 255, 255,
		255, 255, 255, 255,   0, 0, 0, 255,
	};
	char[] linear_mip = mipgen::next_level(mem, src[..], 2, 2);
	defer free(linear_mip);
	char[] srgb_mip = mipgen::next_level(mem, src[..], 2, 2, { .srgb = true });
	defer free(srgb_mip);
	assert(linear_mip[0] == 128 || linear_mip[0] == 127);
	assert(srgb_mip[0] >= 186 && srgb_mip[0] <= 190);
	// Alpha stays linearly averaged either way.
	assert(srgb_mip[3] == 255);
}

fn void renormalize_keeps_unit_length()
{
	// Two opposing tilted normals average to a shortened vector; with
	// renormalize the result must be unit length again (encoded 0.5 bias).
	char[16] src = {
		255, 128, 128, 255,   // +X
		128, 255, 128, 255,   // +Y
		255, 128, 128, 255,
		128, 255, 128, 255,
	};
	char[] mip = mipgen::next_level(mem, src[..], 2, 2, { .renormalize = true });
	defer free(mip);
	float nx = (float)mip[0] * (2.0f / 255.0f) - 1.0f;
	float ny = (float)mip[1] * (2.0f / 255.0f) - 1.0f;
	float nz = (float)mip[2] * (2.0f / 255.0f) - 1.0f;
	float len2 = nx * nx + ny * ny + nz * nz;
	assert(len2 > 0.9f && len2 < 1.1f);
}

fn void odd_dimensions_clamp()
{
	// 3x1 -> 1x1 uses clamped sampling; must not read out of bounds.
	char[12] src = { 100, 0, 0, 255, 200, 0, 0, 255, 50, 0, 0, 255 };
	char[] mip = mipgen::next_level(mem, src[..], 3, 1);
	defer free(mip);
	assert(mip.len == 4);
	assert(mip[0] == 150);   // (100+200+100+200+2)/4
}
