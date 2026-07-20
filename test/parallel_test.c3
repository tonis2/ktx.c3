// Threading tests: ktx::parallel covers every item exactly once, and the
// threaded codec paths (uastc/etc1s/bc7/bcn encode, uastc decode) produce
// byte-identical output for any thread count — the searches are parallel but
// all order-sensitive accumulation stays serial by design.
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
import ktx::parallel, ktx::uastc, ktx::bc7, ktx::bcn;
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
