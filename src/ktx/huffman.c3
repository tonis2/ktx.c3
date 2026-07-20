// Canonical Huffman coding, format-compatible with basis_universal's
// (basisu_transcoder_internal.h / basisu_enc.cpp) — the entropy coder under
// BasisLZ/ETC1S global data and slices (docs/basis-rewrite.md phases 2 and 5).
//
// Conventions shared with basisu:
// - Streams are LSB-first (ktx::bits); each code is written bit-reversed, so
//   reading one bit at a time yields the canonical code MSB-first.
// - Canonical assignment: codes ordered by (length, symbol index), the
//   standard next_code recurrence.
// - A serialized table is: total_used_syms (14 bits), then a small 3-bit-coded
//   code-length code (21 symbols, sent in a fixed swizzled order), then the
//   RLE-compressed code lengths (literals 0..16, zero runs 17/18, repeats
//   19/20).
module ktx::huffman;
import ktx::bits;
import std::core::mem;

faultdef INVALID_TABLE, INVALID_CODE, BAD_STREAM;

const uint MAX_SYMS_LOG2 = 14;
const uint MAX_SYMS = 1 << MAX_SYMS_LOG2;
const uint MAX_CODE_SIZE = 16;           // longest code allowed in a stream
const uint MAX_INTERNAL_CODE_SIZE = 31;  // longest length out of the length assignment

// The code-length code alphabet (mirrors DEFLATE's idea, different codes).
const uint CODELENGTH_CODES = 21;
const uint SMALL_ZERO_RUN = 17;          // 3..10 zeros, 3 extra bits
const uint BIG_ZERO_RUN = 18;            // 11..138 zeros, 7 extra bits
const uint SMALL_REPEAT = 19;            // repeat prev 3..6 times, 2 extra bits
const uint BIG_REPEAT = 20;              // repeat prev 7..134 times, 7 extra bits
const uint SMALL_ZERO_RUN_MIN = 3;
const uint SMALL_ZERO_RUN_MAX = 10;
const uint SMALL_ZERO_RUN_EXTRA = 3;
const uint BIG_ZERO_RUN_MIN = 11;
const uint BIG_ZERO_RUN_MAX = 138;
const uint BIG_ZERO_RUN_EXTRA = 7;
const uint SMALL_REPEAT_MIN = 3;
const uint SMALL_REPEAT_MAX = 6;
const uint SMALL_REPEAT_EXTRA = 2;
const uint BIG_REPEAT_MIN = 7;
const uint BIG_REPEAT_MAX = 134;
const uint BIG_REPEAT_EXTRA = 7;

// Transmission order of the code-length code's own 3-bit lengths
// (g_huffman_sorted_codelength_codes in basisu).
const char[CODELENGTH_CODES] SORTED_CODELENGTH_ORDER =
	{ 17, 18, 19, 20, 0, 8, 7, 9, 6, 10, 5, 11, 4, 12, 3, 13, 2, 14, 1, 15, 16 };

// ---------------------------------------------------------------- decode ----

<*
 Canonical decode state built from per-symbol code lengths. Decoding walks the
 stream one bit at a time and matches against the per-length code ranges —
 exactly equivalent to basisu's lookup+tree decoder on any valid stream.
*>
struct DecodeTable
{
	Allocator allocator;
	usz total_syms;                        // size of the alphabet (0 = empty table)
	uint[MAX_CODE_SIZE + 1] count;         // codes per length
	uint[MAX_CODE_SIZE + 1] first_code;    // canonical first code per length
	uint[MAX_CODE_SIZE + 1] offset;        // index of first symbol of a length in `sorted`
	ushort[] sorted;                       // symbols ordered by (length, symbol index)
}

<*
 Build a decode table from code lengths (0 = symbol unused). Rejects lengths
 over MAX_CODE_SIZE and any set that is not a full prefix code — except the
 degenerate single-symbol table, which basisu also accepts.
*>
fn DecodeTable? build_decode(Allocator allocator, char[] code_sizes)
{
	if (!code_sizes.len) return {};

	DecodeTable t;
	t.allocator = allocator;
	t.total_syms = code_sizes.len;

	uint used;
	foreach (s : code_sizes)
	{
		if (s > MAX_CODE_SIZE) return INVALID_TABLE~;
		t.count[s]++;
		if (s) used++;
	}
	t.count[0] = 0;
	if (!used) return INVALID_TABLE~;

	// Kraft sum must fill the tree exactly (single-symbol tables exempt).
	ulong total;
	for (uint len = 1; len <= MAX_CODE_SIZE; len++)
	{
		total += (ulong)t.count[len] << (MAX_CODE_SIZE - len);
	}
	if (total != (ulong)1 << MAX_CODE_SIZE && used != 1) return INVALID_TABLE~;

	uint acc;
	for (uint len = 1; len < MAX_CODE_SIZE; len++)
	{
		acc = (acc + t.count[len]) << 1;
		t.first_code[len + 1] = acc;
	}

	uint at;
	for (uint len = 1; len <= MAX_CODE_SIZE; len++)
	{
		t.offset[len] = at;
		at += t.count[len];
	}

	t.sorted = alloc::new_array(allocator, ushort, used);
	uint[MAX_CODE_SIZE + 1] fill = t.offset;
	foreach (i, s : code_sizes)
	{
		if (s) t.sorted[fill[s]++] = (ushort)i;
	}
	return t;
}

fn void DecodeTable.free(&self)
{
	if (self.sorted.len) alloc::free(self.allocator, self.sorted.ptr);
	*self = {};
}

<*
 Decode one symbol. On truncated input the reader zero-pads and latches its
 overflow flag — check `r.ok()` after the last decode of a stream.
*>
fn uint? DecodeTable.decode(&self, bits::Reader* r)
{
	uint code;
	for (uint len = 1; len <= MAX_CODE_SIZE; len++)
	{
		code = (code << 1) | r.read(1);
		if (code >= self.first_code[len] && code - self.first_code[len] < self.count[len])
		{
			return self.sorted[self.offset[len] + (code - self.first_code[len])];
		}
	}
	return INVALID_CODE~;
}

<*
 Read a serialized Huffman table (basisu bitwise_decoder::read_huffman_table).
 A zero-symbol table is valid and returns an empty DecodeTable.
*>
fn DecodeTable? read_table(Allocator allocator, bits::Reader* r)
{
	uint total_used = r.read(MAX_SYMS_LOG2);
	if (!total_used) return {};
	if (total_used > MAX_SYMS) return INVALID_TABLE~;

	uint num_cl = r.read(5);
	if (num_cl < 1 || num_cl > CODELENGTH_CODES) return INVALID_TABLE~;
	char[CODELENGTH_CODES] cl_sizes;
	for (uint i = 0; i < num_cl; i++)
	{
		cl_sizes[SORTED_CODELENGTH_ORDER[i]] = (char)r.read(3);
	}

	DecodeTable cl_table = build_decode(allocator, cl_sizes[..])!;
	defer cl_table.free();

	char[] sizes = alloc::new_array(allocator, char, total_used);
	defer alloc::free(allocator, sizes.ptr);

	uint cur;
	while (cur < total_used)
	{
		uint c = cl_table.decode(r)!;
		if (!r.ok()) return BAD_STREAM~;
		switch
		{
			case c <= MAX_CODE_SIZE:
				sizes[cur++] = (char)c;
			case c == SMALL_ZERO_RUN:
				cur += r.read(SMALL_ZERO_RUN_EXTRA) + SMALL_ZERO_RUN_MIN;
			case c == BIG_ZERO_RUN:
				cur += r.read(BIG_ZERO_RUN_EXTRA) + BIG_ZERO_RUN_MIN;
			default:
				// repeat codes: copy the previous length
				if (!cur) return INVALID_TABLE~;
				uint l = c == SMALL_REPEAT
					? r.read(SMALL_REPEAT_EXTRA) + SMALL_REPEAT_MIN
					: r.read(BIG_REPEAT_EXTRA) + BIG_REPEAT_MIN;
				char prev = sizes[cur - 1];
				if (!prev) return INVALID_TABLE~;
				while (l--)
				{
					if (cur >= total_used) return INVALID_TABLE~;
					sizes[cur++] = prev;
				}
		}
	}
	if (cur != total_used) return INVALID_TABLE~;

	return build_decode(allocator, sizes);
}

// ---------------------------------------------------------------- encode ----

<* Per-symbol codes ready for LSB-first writing (already bit-reversed). *>
struct EncodeTable
{
	Allocator allocator;
	ushort[] codes;
	char[] sizes;   // 0 = symbol unused
}

struct SymFreq @local
{
	uint key;
	ushort sym;
}

// Stable 2-pass byte radix sort by 16-bit key, ascending (basisu
// canonical_huffman_radix_sort_syms). Returns the slice holding the result.
fn SymFreq[] radix_sort_syms(SymFreq[] a, SymFreq[] b) @local
{
	uint[512] hist;
	foreach (s : a)
	{
		hist[s.key & 0xFF]++;
		hist[256 + ((s.key >> 8) & 0xFF)]++;
	}
	uint passes = 2;
	while (passes > 1 && a.len == hist[(passes - 1) * 256]) passes--;

	SymFreq[] cur = a;
	SymFreq[] next = b;
	for (uint pass = 0; pass < passes; pass++)
	{
		uint[] h = hist[pass * 256 : 256];
		uint[256] offsets;
		uint ofs;
		for (uint i = 0; i < 256; i++)
		{
			offsets[i] = ofs;
			ofs += h[i];
		}
		uint shift = pass * 8;
		foreach (s : cur) next[offsets[(s.key >> shift) & 0xFF]++] = s;
		@swap(cur, next);
	}
	return cur;
}

// In-place minimum-redundancy code lengths for freq-ascending syms (Moffat &
// Katajainen, as in basisu). On return every key is a code length.
fn void calculate_minimum_redundancy(SymFreq[] a) @local
{
	int n = (int)a.len;
	if (!n) return;
	if (n == 1)
	{
		a[0].key = 1;
		return;
	}

	a[0].key += a[1].key;
	int s = 2;
	int r = 0;
	int next;
	for (next = 1; next < n - 1; ++next)
	{
		if (s >= n || a[r].key < a[s].key)
		{
			a[next].key = a[r].key;
			a[r].key = (uint)next;
			++r;
		}
		else
		{
			a[next].key = a[s].key;
			++s;
		}
		if (s >= n || (r < next && a[r].key < a[s].key))
		{
			a[next].key += a[r].key;
			a[r].key = (uint)next;
			++r;
		}
		else
		{
			a[next].key += a[s].key;
			++s;
		}
	}
	a[n - 2].key = 0;
	for (next = n - 3; next >= 0; --next)
	{
		a[next].key = 1 + a[(int)a[next].key].key;
	}

	int num_avail = 1;
	int num_used = 0;
	int depth = 0;
	r = n - 2;
	next = n - 1;
	while (num_avail > 0)
	{
		while (r >= 0 && (int)a[r].key == depth)
		{
			++num_used;
			--r;
		}
		while (num_avail > num_used)
		{
			a[next].key = (uint)depth;
			--next;
			--num_avail;
		}
		num_avail = 2 * num_used;
		num_used = 0;
		++depth;
	}
}

// Demote codes longer than max_code_size, keeping the tree full (basisu
// canonical_huffman_enforce_max_code_size).
fn void enforce_max_code_size(int[] num_codes, usz code_list_len, uint max_code_size) @local
{
	if (code_list_len <= 1) return;

	for (uint i = max_code_size + 1; i <= MAX_INTERNAL_CODE_SIZE; i++)
	{
		num_codes[max_code_size] += num_codes[i];
	}
	ulong total;
	for (uint i = max_code_size; i > 0; i--)
	{
		total += (ulong)num_codes[i] << (max_code_size - i);
	}
	while (total != (ulong)1 << max_code_size)
	{
		num_codes[max_code_size]--;
		for (uint i = max_code_size - 1; i > 0; i--)
		{
			if (num_codes[i])
			{
				num_codes[i]--;
				num_codes[i + 1] += 2;
				break;
			}
		}
		total--;
	}
}

<*
 Build length-limited canonical codes from symbol frequencies (0 = unused).
 Matches basisu huffman_encoding_table::init, including the scale-to-16-bit
 step, so identical inputs yield identical tables.
*>
fn EncodeTable? build_encode(Allocator allocator, uint[] freqs, uint max_code_size = MAX_CODE_SIZE)
{
	if (max_code_size > MAX_CODE_SIZE) return INVALID_TABLE~;
	if (!freqs.len || freqs.len > MAX_SYMS) return INVALID_TABLE~;

	uint max_freq;
	usz total_used;
	foreach (f : freqs)
	{
		if (f) total_used++;
		max_freq = max(max_freq, f);
	}
	if (!total_used) return INVALID_TABLE~;

	// Scale frequencies into 1..65534 (16-bit radix sort keys).
	SymFreq[] sf0 = alloc::new_array(allocator, SymFreq, (sz)total_used);
	SymFreq[] sf1 = alloc::new_array(allocator, SymFreq, (sz)total_used);
	defer alloc::free(allocator, sf0.ptr);
	defer alloc::free(allocator, sf1.ptr);
	usz j;
	foreach (i, f : freqs)
	{
		if (!f) continue;
		uint key = f;
		if (max_freq >= 0xFFFF)
		{
			key = (uint)(((ulong)f * 65534 + (ulong)(max_freq >> 1)) / max_freq);
			key = min(max(key, 1u), 65534u);
		}
		sf0[j] = { .key = key, .sym = (ushort)i };
		j++;
	}

	SymFreq[] sorted = radix_sort_syms(sf0, sf1);
	calculate_minimum_redundancy(sorted);

	int[MAX_INTERNAL_CODE_SIZE + 1] num_codes;
	foreach (s : sorted)
	{
		if (s.key > MAX_INTERNAL_CODE_SIZE) return INVALID_TABLE~;
		num_codes[s.key]++;
	}
	enforce_max_code_size(num_codes[..], total_used, max_code_size);

	EncodeTable t;
	t.allocator = allocator;
	t.sizes = alloc::new_array(allocator, char, (sz)freqs.len);
	t.codes = alloc::new_array(allocator, ushort, (sz)freqs.len);

	// Shortest codes go to the highest frequencies (the tail of `sorted`).
	usz k = total_used;
	for (uint i = 1; i <= max_code_size; i++)
	{
		for (int l = num_codes[i]; l > 0; l--)
		{
			k--;
			t.sizes[sorted[k].sym] = (char)i;
		}
	}

	uint[MAX_CODE_SIZE + 1] next_code;
	uint acc;
	for (uint i = 2; i <= max_code_size; i++)
	{
		acc = (acc + (uint)num_codes[i - 1]) << 1;
		next_code[i] = acc;
	}
	foreach (i, size : t.sizes)
	{
		if (!size) continue;
		uint code = next_code[size]++;
		uint rev;
		for (uint l = size; l > 0; l--)
		{
			rev = (rev << 1) | (code & 1);
			code >>= 1;
		}
		t.codes[i] = (ushort)rev;
	}
	return t;
}

fn void EncodeTable.free(&self)
{
	if (self.sizes.len)
	{
		alloc::free(self.allocator, self.codes.ptr);
		alloc::free(self.allocator, self.sizes.ptr);
	}
	*self = {};
}

<* Append one symbol's code to the stream. *>
fn void EncodeTable.put(&self, bits::Writer* w, uint sym)
{
	assert(self.sizes[sym], "symbol %d has no code (zero frequency)", sym);
	w.write(self.codes[sym], self.sizes[sym]);
}

<* Symbols beyond the last one with a code are never transmitted. *>
fn uint EncodeTable.total_used(&self) @local
{
	for (usz i = self.sizes.len; i > 0; i--)
	{
		if (self.sizes[i - 1]) return (uint)i;
	}
	return 0;
}

fn void flush_zero_run(ushort[] syms, usz* n, uint* run) @local
{
	uint r = *run;
	*run = 0;
	if (!r) return;
	switch
	{
		case r < SMALL_ZERO_RUN_MIN:
			while (r--) syms[(*n)++] = 0;
		case r <= SMALL_ZERO_RUN_MAX:
			syms[(*n)++] = (ushort)(SMALL_ZERO_RUN | ((r - SMALL_ZERO_RUN_MIN) << 6));
		default:
			syms[(*n)++] = (ushort)(BIG_ZERO_RUN | ((r - BIG_ZERO_RUN_MIN) << 6));
	}
}

fn void flush_repeat_run(ushort[] syms, usz* n, uint* run, uint len) @local
{
	uint r = *run;
	*run = 0;
	if (!r) return;
	switch
	{
		case r < SMALL_REPEAT_MIN:
			while (r--) syms[(*n)++] = (ushort)len;
		case r <= SMALL_REPEAT_MAX:
			syms[(*n)++] = (ushort)(SMALL_REPEAT | ((r - SMALL_REPEAT_MIN) << 6));
		default:
			syms[(*n)++] = (ushort)(BIG_REPEAT | ((r - BIG_REPEAT_MIN) << 6));
	}
}

<*
 Serialize this table so `read_table` (and basisu) can reconstruct it
 (basisu bitwise_coder::emit_huffman_table).
*>
fn void? EncodeTable.write_table(&self, Allocator allocator, bits::Writer* w)
{
	uint total_used = self.total_used();
	w.write(total_used, MAX_SYMS_LOG2);
	if (!total_used) return;

	// RLE the code lengths into code-length-alphabet symbols; the high bits of
	// an entry carry the run's extra-bits payload.
	ushort[] syms = alloc::new_array(allocator, ushort, (sz)(total_used + 16));
	defer alloc::free(allocator, syms.ptr);
	usz n;
	uint prev = 0xFFFF_FFFF;   // "no previous length" sentinel
	uint zero_run;
	uint repeat_run;
	for (uint i = 0; i <= total_used; ++i)
	{
		uint code_len = i == total_used ? 0xFF : self.sizes[i];
		if (code_len)
		{
			flush_zero_run(syms, &n, &zero_run);
			if (code_len != prev)
			{
				flush_repeat_run(syms, &n, &repeat_run, prev);
				if (code_len != 0xFF) syms[n++] = (ushort)code_len;
			}
			else
			{
				repeat_run++;
				if (repeat_run == BIG_REPEAT_MAX) flush_repeat_run(syms, &n, &repeat_run, prev);
			}
		}
		else
		{
			flush_repeat_run(syms, &n, &repeat_run, prev);
			zero_run++;
			if (zero_run == BIG_ZERO_RUN_MAX) flush_zero_run(syms, &n, &zero_run);
		}
		prev = code_len;
	}

	uint[CODELENGTH_CODES] hist;
	foreach (s : syms[:n]) hist[s & 63]++;
	EncodeTable cl = build_encode(allocator, hist[..], 7)!;
	defer cl.free();

	uint num_cl = CODELENGTH_CODES;
	while (num_cl > 0 && !cl.sizes[SORTED_CODELENGTH_ORDER[num_cl - 1]]) num_cl--;
	assert(num_cl > 0);
	w.write(num_cl, 5);
	for (uint i = 0; i < num_cl; i++)
	{
		w.write(cl.sizes[SORTED_CODELENGTH_ORDER[i]], 3);
	}

	foreach (s : syms[:n])
	{
		uint l = s & 63;
		uint extra = s >> 6;
		cl.put(w, l);
		switch
		{
			case l == SMALL_ZERO_RUN: w.write(extra, SMALL_ZERO_RUN_EXTRA);
			case l == BIG_ZERO_RUN:   w.write(extra, BIG_ZERO_RUN_EXTRA);
			case l == SMALL_REPEAT:   w.write(extra, SMALL_REPEAT_EXTRA);
			case l == BIG_REPEAT:     w.write(extra, BIG_REPEAT_EXTRA);
		}
	}
}
