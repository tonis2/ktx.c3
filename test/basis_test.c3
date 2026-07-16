module basis_tests @test;
import ktx::basis;

// Encode RGBA -> ETC1S/BasisLZ KTX2 via basis_universal, then transcode it back
// to RGBA32 and check the container is well-formed and dimensions survive.
fn void etc1s_roundtrip()
{
	uint w = 16;
	uint h = 16;
	char[16 * 16 * 4] rgba;
	for (usz i = 0; i < rgba.len; i += 4)
	{
		rgba[i] = 200;
		rgba[i + 1] = 100;
		rgba[i + 2] = 50;
		rgba[i + 3] = 255;
	}

	char[] ktx2 = basis::encode_etc1s(mem, rgba[..], w, h)!!;
	defer free(ktx2);
	assert(ktx2.len > 12);
	assert(ktx2[0] == 0xAB);   // KTX2 identifier
	assert(ktx2[1] == 0x4B);   // 'K'

	basis::Transcoded t = basis::transcode(mem, ktx2, 0, 0, 0, basis::TF_RGBA32, 4)!!;
	defer free(t.data);
	assert(t.width == w);
	assert(t.height == h);
	assert(t.data.len == (usz)w * h * 4);

	// Also transcode straight to a GPU block format (BC7: 16 bytes/block).
	basis::Transcoded bc7 = basis::transcode(mem, ktx2, 0, 0, 0, basis::TF_BC7_RGBA, 16)!!;
	defer free(bc7.data);
	assert(bc7.data.len == (usz)(w / 4) * (h / 4) * 16);
}
