// Threading tests: ktx::parallel covers every item exactly once, and the
// threaded codec paths (uastc/etc1s/bc7/bcn encode, uastc/bc7/bcn decode,
// the uastc/etc1s to BC7 block mappers)
// produce byte-identical output for any thread count — the searches are
// parallel but all order-sensitive accumulation stays serial by design.
module parallel_testutil;
import ktx::etc1s;

fn bool same(char[] a, char[] b)
{
	if (a.len != b.len) return false;
	foreach (i, v : a)
	{
		if (v != b[i]) return false;
	}
	return true;
}

<* etc1s::encode with a given thread count, all output concatenated. *>
fn char[] etc1s_bytes(Allocator allocator, char[] rgba, uint w, uint h, uint threads)
{
	etc1s::EncSlice[2] slices;
	slices[0] = { .rgba = rgba, .width = w, .height = h, .alpha = false };
	slices[1] = { .rgba = rgba, .width = w, .height = h, .alpha = true };
	etc1s::Encoded enc = etc1s::encode(allocator, slices[..], 90, threads)!!;

	usz total = enc.endpoints_data.len + enc.selectors_data.len + enc.tables_data.len;
	foreach (sl : enc.slices) total += sl.len;
	char[] out = alloc::new_array(allocator, char, (sz)total);
	usz at;
	out[at : enc.endpoints_data.len] = enc.endpoints_data[..];
	at += enc.endpoints_data.len;
	out[at : enc.selectors_data.len] = enc.selectors_data[..];
	at += enc.selectors_data.len;
	out[at : enc.tables_data.len] = enc.tables_data[..];
	at += enc.tables_data.len;
	foreach (sl : enc.slices)
	{
		out[at : sl.len] = sl[..];
		at += sl.len;
	}
	return out;
}

module parallel_tests @test;
import ktx::parallel, ktx::uastc, ktx::bc7, ktx::bcn, ktx::etc1s;
import ktx::uastc_bc7, ktx::etc1s_bc7;
import parallel_testutil, etc1s_enc_testutil;

fn void run_covers_every_item_once()
{
	char[97] hits;
	parallel::run(hits.len, &hits, fn void(void* ctx, usz i) {
		char[97]* h = (char[97]*)ctx;
		(*h)[i]++;
	}, 5);
	foreach (i, h : hits) assert(h == 1, "item %d ran %d times", i, h);
}

fn void uastc_encode_thread_deterministic() => @pool()
{
	// 70x54 is 18x14 blocks with clamped edge blocks.
	char[] img = etc1s_enc_testutil::make_image(tmem, 70, 54);
	char[] one = uastc::encode_image(tmem, img, 70, 54, 1, 1)!!;
	char[] four = uastc::encode_image(tmem, img, 70, 54, 1, 4)!!;
	assert(parallel_testutil::same(one, four), "uastc encode differs across thread counts");
}

fn void uastc_decode_thread_deterministic() => @pool()
{
	char[] img = etc1s_enc_testutil::make_image(tmem, 70, 54);
	char[] blocks = uastc::encode_image(tmem, img, 70, 54)!!;
	char[] one = mem::temp_array(char, 70 * 54 * 4);
	char[] four = mem::temp_array(char, 70 * 54 * 4);
	uastc::decode_image(blocks, one, 70, 54, false, 1)!!;
	uastc::decode_image(blocks, four, 70, 54, false, 4)!!;
	assert(parallel_testutil::same(one, four), "uastc decode differs across thread counts");
}

fn void etc1s_encode_thread_deterministic() => @pool()
{
	char[] img = etc1s_enc_testutil::make_image(tmem, 70, 54);
	char[] one = parallel_testutil::etc1s_bytes(tmem, img, 70, 54, 1);
	char[] four = parallel_testutil::etc1s_bytes(tmem, img, 70, 54, 4);
	assert(parallel_testutil::same(one, four), "etc1s encode differs across thread counts");
}

fn void bcn_encode_thread_deterministic() => @pool()
{
	char[] img = etc1s_enc_testutil::make_image(tmem, 70, 54);
	char[] one = bc7::encode(tmem, img, 70, 54, true, 1)!!;
	char[] four = bc7::encode(tmem, img, 70, 54, true, 4)!!;
	assert(parallel_testutil::same(one, four), "bc7 encode differs across thread counts");

	char[] b3one = bcn::encode(tmem, bcn::BcnFormat.BC3, img, 70, 54, 1)!!;
	char[] b3four = bcn::encode(tmem, bcn::BcnFormat.BC3, img, 70, 54, 4)!!;
	assert(parallel_testutil::same(b3one, b3four), "bc3 encode differs across thread counts");
}

fn void bcn_decode_thread_deterministic() => @pool()
{
	// The decoders split by block row exactly as the encoders do, and 70x54 is
	// the size that would catch it if a partial edge block were assigned by
	// anything other than its own row: 18x14 blocks, clamped on both axes.
	char[] img = etc1s_enc_testutil::make_image(tmem, 70, 54);

	char[] b7 = bc7::encode(tmem, img, 70, 54, true)!!;
	char[] one = bc7::decode(tmem, b7, 70, 54, 1)!!;
	char[] four = bc7::decode(tmem, b7, 70, 54, 4)!!;
	assert(parallel_testutil::same(one, four), "bc7 decode differs across thread counts");

	bcn::BcnFormat[4] formats = { bcn::BcnFormat.BC1, bcn::BcnFormat.BC3, bcn::BcnFormat.BC4, bcn::BcnFormat.BC5 };
	foreach (i, fmt : formats)
	{
		char[] blocks = bcn::encode(tmem, fmt, img, 70, 54)!!;
		char[] serial = bcn::decode(tmem, fmt, blocks, 70, 54, 1)!!;
		char[] threaded = bcn::decode(tmem, fmt, blocks, 70, 54, 4)!!;
		assert(parallel_testutil::same(serial, threaded), "bcn decode differs across thread counts (format %d)", i);
	}
}

<*
 The two Basis-to-BC7 mappers, which split by block row like the codecs do.

 The ETC1S half runs with an alpha slice on purpose: that is the mode-5 path,
 and it has a parallel pass the opaque one does not — the per-(endpoint,
 selector mask) prep, which fills a shared table from several threads and would
 be the place a race showed up.
*>
fn void basis_bc7_map_thread_deterministic() => @pool()
{
	char[] img = etc1s_enc_testutil::make_image(tmem, 70, 54);

	char[] blocks = uastc::encode_image(tmem, img, 70, 54)!!;
	char[] uone = uastc_bc7::map_image(tmem, blocks, 70, 54, 1)!!;
	char[] ufour = uastc_bc7::map_image(tmem, blocks, 70, 54, 4)!!;
	assert(parallel_testutil::same(uone, ufour), "uastc to bc7 differs across thread counts");

	etc1s::EncSlice[2] slices;
	slices[0] = { .rgba = img, .width = 70, .height = 54, .alpha = false };
	slices[1] = { .rgba = img, .width = 70, .height = 54, .alpha = true };
	etc1s::Encoded enc = etc1s::encode(tmem, slices[..], 90)!!;
	etc1s::Codebook cb = etc1s::decode_codebook(tmem, enc.num_endpoints, enc.endpoints_data,
		enc.num_selectors, enc.selectors_data, enc.tables_data)!!;

	char[] eone = etc1s_bc7::map_image(tmem, &cb, enc.slices[0], enc.slices[1], 70, 54, tmem, 1)!!;
	char[] efour = etc1s_bc7::map_image(tmem, &cb, enc.slices[0], enc.slices[1], 70, 54, tmem, 4)!!;
	assert(parallel_testutil::same(eone, efour), "etc1s to bc7 differs across thread counts");

	char[] opaque_one = etc1s_bc7::map_image(tmem, &cb, enc.slices[0], {}, 70, 54, tmem, 1)!!;
	char[] opaque_four = etc1s_bc7::map_image(tmem, &cb, enc.slices[0], {}, 70, 54, tmem, 4)!!;
	assert(parallel_testutil::same(opaque_one, opaque_four),
		"etc1s to bc7 (opaque) differs across thread counts");
}

<*
 The automatic thread count is capped by the work, not only by the core count.

 A mip chain is mostly small levels, and a 4x4 one handed sixteen threads spends
 all of its time in `pthread_create`. `shares` is what keeps that from happening
 and this is the guard on it — an explicit count still means what it says.
*>
fn void shares_scales_with_the_work()
{
	assert(parallel::shares(0, 1024) == 1, "nothing to do still asked for threads");
	assert(parallel::shares(1023, 1024) == 1, "under one share was split");
	assert(parallel::shares(2047, 1024) == 1, "under two shares was split");
	// Capped by the work rather than only by the cores — asserted as a bound
	// and a monotonicity, so a single-core machine reads it the same way.
	assert(parallel::shares(2048, 1024) <= 2, "two shares got more than two threads");
	assert(parallel::shares(1024 * 1024, 1024) >= parallel::shares(2048, 1024), "more work got fewer threads");
	// An explicit request is passed through in both directions.
	assert(parallel::shares(4, 1024, 8) == 8, "an explicit count was overridden");
	assert(parallel::shares(1024 * 1024, 1024, 1) == 1, "threads 1 was not honoured");
}
