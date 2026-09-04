// Minimal fork-join helper for the codecs' data-parallel loops (bc7/bcn/uastc
// block rows, etc1s k-means searches). Work items are assigned interleaved
// (thread t takes items t, t+N, t+2N, ...) so spatially clustered cost —
// detailed vs flat regions of an image — spreads evenly across threads
// without a work queue or any synchronization beyond spawn/join.
module ktx::parallel;
import std::thread;
import std::thread::cpu;

alias ItemFn = fn void(void* ctx, usz item);

const uint MAX_THREADS = 64;

struct Shard @local
{
	ItemFn func;
	void* ctx;
	usz count;
	usz stride;
	usz first;
}

fn int shard_main(void* arg) @local
{
	Shard* s = (Shard*)arg;
	for (usz i = s.first; i < s.count; i += s.stride) s.func(s.ctx, i);
	return 0;
}

<*
 What `run`'s "one per core" should actually be for `count` cheap items.

 `run` alone is the right call for an *encoder*: a BC7 block row is milliseconds
 of search, so a thread that costs tens of microseconds to spawn and join
 disappears into it. A *decoder* is the opposite case — a block unpacks in about
 a tenth of a microsecond — and giving every row of a small texture its own
 thread makes the decode several times slower than the loop it replaced. A mip
 chain is mostly small levels, so that case is the common one, not the corner.

 So the cores are capped by the work: `count / min_per_thread` shares, and below
 two of them 1, which `run` executes inline with no thread at all. Only the
 automatic count is adjusted — an explicit `threads` is a request and is passed
 through, which is what makes a pinned thread count testable.

 @param min_per_thread : `Items one thread must get before a second is worth spawning.`
 @param threads : `The caller's request. Returned as-is unless it is 0, which asks this to decide.`
 @return `A thread count for run, at least 1.`
*>
fn uint shares(usz count, usz min_per_thread, uint threads = 0)
{
	if (threads != 0) return threads;
	// Decided before `native_cpu` is asked, and that order is the point: the query
	// costs microseconds here, which is most of what decoding a 32x32 texture
	// costs in the first place. The small case must not pay to be told how many
	// cores it is not going to use.
	usz worth = min_per_thread ? count / min_per_thread : count;
	if (worth < 2) return 1;
	int n = cpu::native_cpu();
	uint cores = n < 1 ? 1 : (uint)n;
	return (usz)cores > worth ? (uint)worth : cores;
}

<*
 Run func(ctx, i) for every i in [0, count). `threads` 0 uses the machine's
 core count, 1 runs inline. func must only write state owned by its item and
 must not allocate from a shared allocator (including the caller's tmem).
 Threads that fail to spawn have their share run on the calling thread, so
 every item completes regardless.
*>
fn void run(usz count, void* ctx, ItemFn func, uint threads = 0)
{
	if (threads == 0)
	{
		int n = cpu::native_cpu();
		threads = n < 1 ? 1 : (uint)n;
	}
	if (threads > MAX_THREADS) threads = MAX_THREADS;
	if ((usz)threads > count) threads = (uint)count;
	if (threads <= 1)
	{
		for (usz i = 0; i < count; i++) func(ctx, i);
		return;
	}

	Shard[MAX_THREADS] shards;
	Thread[MAX_THREADS] workers;
	bool[MAX_THREADS] live;
	for (uint t = 1; t < threads; t++)
	{
		shards[t] = { .func = func, .ctx = ctx, .count = count, .stride = threads, .first = t };
		live[t] = true;
		if (@catch(workers[t].create(&shard_main, &shards[t]))) live[t] = false;
	}

	Shard own = { .func = func, .ctx = ctx, .count = count, .stride = threads, .first = 0 };
	shard_main(&own);

	for (uint t = 1; t < threads; t++)
	{
		if (live[t])
		{
			workers[t].join();
		}
		else
		{
			shard_main(&shards[t]);
		}
	}
}
