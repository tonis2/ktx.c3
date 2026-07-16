module basis_testutil;
import ktx::basis;

// A solid-color w*h RGBA8 image.
fn char[] solid(uint w, uint h, char r, char g, char b)
{
	char[] px = alloc::new_array(mem, char, (usz)w * h * 4);
	for (usz i = 0; i < px.len; i += 4)
	{
		px[i] = r;
		px[i + 1] = g;
		px[i + 2] = b;
		px[i + 3] = 255;
	}
	return px;
}

module basis_tests @test;
import ktx::basis;
import basis_testutil;

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

// UASTC 4x4 + Zstd encode, then transcode back to RGBA32 and BC7.
fn void uastc_roundtrip()
{
	uint w = 16;
	uint h = 16;
	char[] rgba = basis_testutil::solid(w, h, 40, 160, 220);
	defer free(rgba);

	char[][1] imgs = { rgba };
	basis::EncodeOptions opts = { .quality = 100, .effort = 2, .srgb = true, .mipmaps = false };
	char[] ktx2 = basis::encode(mem, basis::UASTC_4X4, imgs[..], w, h, basis::TexType.D2, opts)!!;
	defer free(ktx2);
	assert(ktx2[0] == 0xAB && ktx2[1] == 0x4B);

	basis::Info bi = basis::info(ktx2)!!;
	assert(bi.width == w && bi.height == h);

	basis::Transcoded t = basis::transcode(mem, ktx2, 0, 0, 0, basis::TF_RGBA32, 4)!!;
	defer free(t.data);
	assert(t.width == w && t.height == h);
	assert(t.data.len == (usz)w * h * 4);

	basis::Transcoded bc7 = basis::transcode(mem, ktx2, 0, 0, 0, basis::TF_BC7_RGBA, 16)!!;
	defer free(bc7.data);
	assert(bc7.data.len == (usz)(w / 4) * (h / 4) * 16);
}

// Two-layer ETC1S array: each layer is a distinct color; transcode both and
// confirm the layer index selects the right image.
fn void array_roundtrip()
{
	uint w = 16;
	uint h = 16;
	char[] l0 = basis_testutil::solid(w, h, 220, 30, 30);
	char[] l1 = basis_testutil::solid(w, h, 30, 30, 220);
	defer free(l0);
	defer free(l1);

	char[][2] imgs = { l0, l1 };
	basis::EncodeOptions opts = { .quality = 90, .effort = 4, .srgb = true, .mipmaps = false };
	char[] ktx2 = basis::encode(mem, basis::ETC1S, imgs[..], w, h, basis::TexType.ARRAY, opts)!!;
	defer free(ktx2);

	basis::Info bi = basis::info(ktx2)!!;
	assert(bi.layers == 2, "expected 2 array layers, got %d", bi.layers);

	basis::Transcoded t0 = basis::transcode(mem, ktx2, 0, 0, 0, basis::TF_RGBA32, 4)!!;
	basis::Transcoded t1 = basis::transcode(mem, ktx2, 0, 1, 0, basis::TF_RGBA32, 4)!!;
	defer free(t0.data);
	defer free(t1.data);
	// Layer 0 is red-dominant, layer 1 is blue-dominant (allow lossy slack).
	assert(t0.data[0] > t0.data[2], "layer 0 should be red-dominant");
	assert(t1.data[2] > t1.data[0], "layer 1 should be blue-dominant");
}

// Six-face ETC1S cubemap: confirm faceCount and per-face transcode.
fn void cube_roundtrip()
{
	uint w = 16;
	uint h = 16;
	char[][6] faces;
	for (uint f = 0; f < 6; f++)
	{
		faces[f] = basis_testutil::solid(w, h, (char)(30 + f * 30), 80, 80);
	}
	defer { for (uint f = 0; f < 6; f++) free(faces[f]); }

	basis::EncodeOptions opts = { .quality = 90, .effort = 2, .srgb = true, .mipmaps = false };
	char[] ktx2 = basis::encode(mem, basis::ETC1S, faces[..], w, h, basis::TexType.CUBE, opts)!!;
	defer free(ktx2);

	basis::Info bi = basis::info(ktx2)!!;
	assert(bi.faces == 6, "expected 6 cube faces, got %d", bi.faces);

	for (uint f = 0; f < 6; f++)
	{
		basis::Transcoded t = basis::transcode(mem, ktx2, 0, 0, f, basis::TF_RGBA32, 4)!!;
		defer free(t.data);
		assert(t.width == w && t.height == h);
	}
}
