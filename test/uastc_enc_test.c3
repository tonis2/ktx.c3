// Phase-4 unit tests (docs/basis-rewrite.md): C3 UASTC encoder. Round-trips
// through our own (golden-verified) decoder: solid blocks must be exact, the
// other synthetic blocks must reconstruct within a sane PSNR. The KTX2-level
// interop gates (basisu transcodes our files identically, ktx validate) live
// in basis_enc_test.c3.
module uastc_enc_testutil;
import ktx::uastc;
import ktx_testutil;

fn double roundtrip_db(char[] px, uint level = 1)
{
	char[16] blk;
	char[64] back;
	uastc::encode_block(px, blk[..], level);
	uastc::decode_block(blk[..], back[..])!!;
	return ktx_testutil::psnr(px, back[..]);
}

module uastc_enc_tests @test;
import ktx::uastc;
import uastc_enc_testutil, ktx_testutil;
import std::io;

fn void solid_block_is_exact()
{
	char[64] px;
	for (uint i = 0; i < 16; i++)
	{
		px[i * 4] = 17;
		px[i * 4 + 1] = 250;
		px[i * 4 + 2] = 3;
		px[i * 4 + 3] = 128;
	}
	char[16] blk;
	char[64] back;
	uastc::encode_block(px[..], blk[..]);
	uastc::decode_block(blk[..], back[..])!!;
	assert(back == px, "solid block must round-trip exactly");
}

fn void gradient_block_roundtrips()
{
	// Smooth RGB gradient: single-subset mode territory.
	char[64] px;
	for (uint y = 0; y < 4; y++)
	{
		for (uint x = 0; x < 4; x++)
		{
			uint i = (y * 4 + x) * 4;
			px[i] = (char)(40 + x * 12 + y * 3);
			px[i + 1] = (char)(90 + x * 8);
			px[i + 2] = (char)(200 - y * 10);
			px[i + 3] = 255;
		}
	}
	double db = uastc_enc_testutil::roundtrip_db(px[..]);
	assert(db > 36.0, "gradient block: %.2f dB", db);
}

fn void alpha_block_roundtrips()
{
	char[64] px;
	for (uint i = 0; i < 16; i++)
	{
		px[i * 4] = (char)(10 + i * 15);
		px[i * 4 + 1] = (char)(240 - i * 12);
		px[i * 4 + 2] = 77;
		px[i * 4 + 3] = (char)(i * 17);
	}
	double db = uastc_enc_testutil::roundtrip_db(px[..]);
	assert(db > 26.0, "alpha block: %.2f dB", db);
}

fn void gray_alpha_block_roundtrips()
{
	// r==g==b with an alpha ramp: LA-mode territory.
	char[64] px;
	for (uint i = 0; i < 16; i++)
	{
		char l = (char)(30 + i * 14);
		px[i * 4] = l;
		px[i * 4 + 1] = l;
		px[i * 4 + 2] = l;
		px[i * 4 + 3] = (char)(255 - i * 13);
	}
	double db = uastc_enc_testutil::roundtrip_db(px[..]);
	assert(db > 27.0, "gray+alpha block: %.2f dB", db);
}

fn void two_tone_block_prefers_subsets()
{
	// Hard partition: left half red-ish, right half blue-ish. Level 1 (with
	// 2-subset mode 4) must beat level 0 (single-subset only) or match it.
	char[64] px;
	for (uint y = 0; y < 4; y++)
	{
		for (uint x = 0; x < 4; x++)
		{
			uint i = (y * 4 + x) * 4;
			if (x < 2)
			{
				px[i] = (char)(200 + y * 5);
				px[i + 1] = 30;
				px[i + 2] = (char)(20 + x * 6);
			}
			else
			{
				px[i] = 25;
				px[i + 1] = (char)(40 + y * 4);
				px[i + 2] = (char)(190 + x * 8);
			}
			px[i + 3] = 255;
		}
	}
	double db0 = uastc_enc_testutil::roundtrip_db(px[..], 0);
	double db1 = uastc_enc_testutil::roundtrip_db(px[..], 1);
	assert(db1 + 0.01 >= db0, "level 1 (%.2f dB) must not lose to level 0 (%.2f dB)", db1, db0);
	assert(db1 > 25.0, "two-tone block: %.2f dB", db1);
}

fn void image_roundtrip_psnr() => @pool()
{
	// 20x18 (edge-block coverage) mixed content.
	uint w = 20;
	uint h = 18;
	char[] img = mem::temp_array(char, (usz)w * h * 4);
	for (uint y = 0; y < h; y++)
	{
		for (uint x = 0; x < w; x++)
		{
			usz i = ((usz)y * w + x) * 4;
			img[i] = (char)(x * 12 + y);
			img[i + 1] = (char)(y * 13);
			img[i + 2] = (char)(255 - x * 9);
			img[i + 3] = (char)(x < 10 ? 255 : 128 + x);
		}
	}
	char[] blocks = uastc::encode_image(tmem, img, w, h)!!;
	char[] back = mem::temp_array(char, (usz)w * h * 4);
	uastc::decode_image(blocks, back, w, h)!!;
	double db = ktx_testutil::psnr(img, back);
	io::printfn("  uastc encode image round-trip: %.2f dB", db);
	assert(db > 32.0, "image round-trip: %.2f dB", db);
}
