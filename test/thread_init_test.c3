// The transcoders' lookup tables (ktx::uastc_bc7, uastc_astc, etc1s_bc7,
// etc1s_etc2, uastc's endpoint quantization, mipgen's sRGB table) are built by
// whichever thread uses them first, so two textures loading at once race to
// build them. The suite runs every test in one process, where an earlier test
// has already built them, so the race only exists in a fresh process: one test
// starts the test binary again to run the child test alone.
module thread_init_testutil;
import ktx::etc1s, ktx::uastc, ktx::uastc_bc7, ktx::uastc_astc, ktx::etc1s_bc7, ktx::etc1s_etc2, ktx::mipgen;
import etc1s_enc_testutil;
import std::thread, std::atomic;

const uint THREADS = 8;
const uint W = 70;
const uint H = 54;

<* Each first use the threads race to, in this order. *>
enum Step
{
	MIPGEN,
	UASTC_ENCODE,
	UASTC_BC7,
	UASTC_ASTC,
	ETC1S_BC7,
	ETC1S_ETC2,
}

<* What every thread reads. Making it touches none of the lazy tables. *>
struct Race
{
	char[] rgba;
	etc1s::Codebook cb;
	char[] rgb_slice;
	char[] alpha_slice;
	<* Threads that reached a step, summed over the steps. *>
	Atomic {uint} arrived;
}

<* One thread's output per step, from the heap. *>
struct Runner
{
	Race* race;
	char[][Step::len] out;
}

<* Hold each thread at a step until all of them are there, so the first uses collide. *>
fn void Race.wait(&self, Step step)
{
	self.arrived.add(1);
	while (self.arrived.load() < (uint)(step.ordinal + 1) * THREADS) thread::yield();
}

<*
 One step on one thread, inline.

 @param [in] uastc_blocks : "This thread's UASTC encode, for the UASTC mappers"
*>
fn char[] run_step(Race* race, Step step, char[] uastc_blocks, Allocator allocator)
{
	switch (step)
	{
		case MIPGEN: return mipgen::next_level(allocator, race.rgba, W, H, { .srgb = true }, 1);
		case UASTC_ENCODE: return uastc::encode_image(allocator, race.rgba, W, H, 1, 1)!!;
		case UASTC_BC7: return uastc_bc7::map_image(allocator, uastc_blocks, W, H, 1)!!;
		case UASTC_ASTC: return uastc_astc::map_image(allocator, uastc_blocks, W, H, 1)!!;
		case ETC1S_BC7:
			return etc1s_bc7::map_image(allocator, &race.cb, race.rgb_slice, race.alpha_slice, W, H, tmem, 1)!!;
		case ETC1S_ETC2:
			return etc1s_etc2::map_image(allocator, &race.cb, race.rgb_slice, race.alpha_slice, W, H,
				ETC2_RGBA, tmem, 1)!!;
	}
}

fn int runner_main(void* arg)
{
	Runner* r = arg;
	@pool_init(mem, 64 * 1024)
	{
		foreach (step : Step::values)
		{
			r.race.wait(step);
			r.out[step.ordinal] = run_step(r.race, step, r.out[Step.UASTC_ENCODE.ordinal], mem);
		}
	};
	return 0;
}

module thread_init_tests @test;
import thread_init_testutil;
import parallel_testutil, etc1s_enc_testutil;
import ktx::etc1s;
import std::thread, std::io, std::os::env, std::os::process;

<*
 Start the test binary again with only the child test below, so the threads
 meet tables nobody has built yet. The "ok" line proves the child ran: a
 filter that matched nothing would also exit 0.
*>
fn void first_use_from_many_threads() => @pool()
{
	$if env::WIN32:
		io::printn("  skipped: the test binary's path is not known on Windows");
	$else
		String exe = env::executable_path() ?? "/proc/self/exe";
		String[*] cmd = { exe, "--test-filter", "race_child_fresh_process", "--test-noleak", "--test-show-output", "--noansi" };
		String[*] vars = { "KTX_FRESH_RACE=1" };
		Process child = process::spawn(cmd[..], NO_PATH_SEARCH | STDERR_TO_STDOUT, vars[..])!!;
		defer (void)child.destroy();
		char[] buf = mem::temp_array(char, 1 << 16);
		sz len;
		while (len < buf.len)
		{
			sz got = child.read_stdout(&buf[len], buf.len - len)!!;
			if (got <= 0) break;
			len += got;
		}
		String output = (String)buf[:len];
		CInt code = child.join()!!;
		assert(code == 0 && output.contains("race child ok"), "child exited %d:\n%s", code, output);
	$endif
}

<*
 THREADS threads take each first use together, from a fresh process, then a
 serial run of every step must give each thread's bytes. Only runs in the child
 the test above starts: here, other tests have built the tables already.
*>
fn void race_child_fresh_process() => @pool()
{
	if (catch env::tget_var("KTX_FRESH_RACE")) return;

	thread_init_testutil::Race race = { .rgba = etc1s_enc_testutil::make_image(tmem, thread_init_testutil::W, thread_init_testutil::H) };
	etc1s::EncSlice[2] slices = {
		{ .rgba = race.rgba, .width = thread_init_testutil::W, .height = thread_init_testutil::H },
		{ .rgba = race.rgba, .width = thread_init_testutil::W, .height = thread_init_testutil::H, .alpha = true },
	};
	etc1s::Encoded enc = etc1s::encode(tmem, slices[..], 90, 1)!!;
	race.cb = etc1s::decode_codebook(tmem, enc.num_endpoints, enc.endpoints_data,
		enc.num_selectors, enc.selectors_data, enc.tables_data)!!;
	race.rgb_slice = enc.slices[0];
	race.alpha_slice = enc.slices[1];

	thread_init_testutil::Runner[thread_init_testutil::THREADS] runners;
	Thread[thread_init_testutil::THREADS] threads;
	foreach (i, &r : runners)
	{
		r.race = &race;
		threads[i].create(&thread_init_testutil::runner_main, r)!!;
	}
	foreach (t : threads) (void)t.join();
	defer foreach (&r : runners) foreach (o : r.out) free(o.ptr);

	char[] uastc_blocks;
	foreach (step : thread_init_testutil::Step::values)
	{
		char[] want = thread_init_testutil::run_step(&race, step, uastc_blocks, tmem);
		if (step == UASTC_ENCODE) uastc_blocks = want;
		foreach (i, &r : runners)
		{
			assert(parallel_testutil::same(r.out[step.ordinal], want), "thread %d: %s differs from a serial run", i, step);
		}
	}
	io::printfn("race child ok: %d threads, %d steps", thread_init_testutil::THREADS, thread_init_testutil::Step::len);
}
