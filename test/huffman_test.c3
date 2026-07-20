module huffman_tests @test;
import ktx::huffman;
import ktx::bits;

// Known canonical assignment: freqs {8,4,2,2} give lengths {1,2,3,3} and
// canonical codes 0, 10, 110, 111 — stored bit-reversed for LSB-first writing.
fn void canonical_codes_known()
{
	uint[4] freqs = { 8, 4, 2, 2 };
	huffman::EncodeTable t = huffman::build_encode(mem, freqs[..])!!;
	defer t.free();
	assert(t.sizes[0] == 1 && t.sizes[1] == 2 && t.sizes[2] == 3 && t.sizes[3] == 3);
	assert(t.codes[0] == 0b0, "got %b", t.codes[0]);
	assert(t.codes[1] == 0b01, "got %b", t.codes[1]);
	assert(t.codes[2] == 0b011, "got %b", t.codes[2]);
	assert(t.codes[3] == 0b111, "got %b", t.codes[3]);
}

// Encode symbols with an EncodeTable, decode with a DecodeTable built directly
// from the same code lengths.
fn void encode_decode_direct()
{
	uint[4] freqs = { 8, 4, 2, 2 };
	huffman::EncodeTable et = huffman::build_encode(mem, freqs[..])!!;
	defer et.free();

	bits::Writer w = bits::writer(mem);
	uint[8] seq = { 0, 1, 2, 3, 0, 0, 3, 1 };
	foreach (s : seq) et.put(&w, s);
	char[] stream = w.finish();
	defer free(stream);

	huffman::DecodeTable dt = huffman::build_decode(mem, et.sizes)!!;
	defer dt.free();
	bits::Reader r = bits::reader(stream);
	foreach (s : seq)
	{
		uint got = dt.decode(&r)!!;
		assert(got == s, "got %d want %d", got, s);
	}
	assert(r.ok());
}

// Fibonacci frequencies over 19 symbols force >16-bit ideal lengths, so the
// max-code-size enforcement kicks in (mirrors basisu's own huffman_test).
// Full pipeline: table serialized + symbols, then read_table + decode.
fn void fibonacci_table_roundtrip()
{
	uint[19] freqs;
	uint a = 1;
	uint b = 1;
	for (uint i = 0; i < 19; i++)
	{
		freqs[i] = b;
		uint next = a + b;
		a = b;
		b = next;
	}
	huffman::EncodeTable et = huffman::build_encode(mem, freqs[..])!!;
	defer et.free();
	for (uint i = 0; i < 19; i++)
	{
		assert(et.sizes[i] >= 1 && et.sizes[i] <= 16);
	}

	bits::Writer w = bits::writer(mem);
	et.write_table(mem, &w)!!;
	for (uint i = 0; i < 19; i++) et.put(&w, i);
	char[] stream = w.finish();
	defer free(stream);

	bits::Reader r = bits::reader(stream);
	huffman::DecodeTable dt = huffman::read_table(mem, &r)!!;
	defer dt.free();
	for (uint i = 0; i < 19; i++)
	{
		uint got = dt.decode(&r)!!;
		assert(got == i, "sym %d decoded as %d", i, got);
	}
	assert(r.ok());
}

// A sparse 256-symbol alphabet exercises the small/big zero-run codes in the
// serialized table.
fn void sparse_alphabet_roundtrip()
{
	uint[256] freqs;
	freqs[0] = 10;
	freqs[7] = 20;
	freqs[100] = 30;
	freqs[200] = 5;
	freqs[255] = 1;
	huffman::EncodeTable et = huffman::build_encode(mem, freqs[..])!!;
	defer et.free();

	bits::Writer w = bits::writer(mem);
	et.write_table(mem, &w)!!;
	uint[10] seq = { 0, 255, 100, 7, 200, 100, 0, 255, 7, 100 };
	foreach (s : seq) et.put(&w, s);
	char[] stream = w.finish();
	defer free(stream);

	bits::Reader r = bits::reader(stream);
	huffman::DecodeTable dt = huffman::read_table(mem, &r)!!;
	defer dt.free();
	foreach (s : seq)
	{
		uint got = dt.decode(&r)!!;
		assert(got == s, "got %d want %d", got, s);
	}
	assert(r.ok());
}

// Long runs of one length exercise the repeat codes (all 64 symbols equally
// likely -> all lengths 6, one big repeat run).
fn void uniform_alphabet_roundtrip()
{
	uint[64] freqs;
	foreach (&f : freqs) *f = 7;
	huffman::EncodeTable et = huffman::build_encode(mem, freqs[..])!!;
	defer et.free();
	for (uint i = 0; i < 64; i++) assert(et.sizes[i] == 6);

	bits::Writer w = bits::writer(mem);
	et.write_table(mem, &w)!!;
	for (uint i = 0; i < 64; i++) et.put(&w, i);
	char[] stream = w.finish();
	defer free(stream);

	bits::Reader r = bits::reader(stream);
	huffman::DecodeTable dt = huffman::read_table(mem, &r)!!;
	defer dt.free();
	for (uint i = 0; i < 64; i++)
	{
		assert(dt.decode(&r)!! == i);
	}
	assert(r.ok());
}

fn void single_symbol_roundtrip()
{
	uint[5] freqs = { 0, 0, 42, 0, 0 };
	huffman::EncodeTable et = huffman::build_encode(mem, freqs[..])!!;
	defer et.free();
	assert(et.sizes[2] == 1 && et.codes[2] == 0);

	bits::Writer w = bits::writer(mem);
	et.write_table(mem, &w)!!;
	et.put(&w, 2);
	et.put(&w, 2);
	char[] stream = w.finish();
	defer free(stream);

	bits::Reader r = bits::reader(stream);
	huffman::DecodeTable dt = huffman::read_table(mem, &r)!!;
	defer dt.free();
	assert(dt.decode(&r)!! == 2);
	assert(dt.decode(&r)!! == 2);
	assert(r.ok());
}

// A skewed pseudo-random stream over a mid-size alphabet, full pipeline.
fn void random_stream_roundtrip()
{
	const COUNT = 2000;
	const ALPHABET = 40;
	char[COUNT] syms;
	ulong state = 0x243F6A8885A308D3;
	uint[ALPHABET] freqs;
	for (uint i = 0; i < COUNT; i++)
	{
		state ^= state << 13;
		state ^= state >> 7;
		state ^= state << 17;
		// skew: square the uniform draw so low symbols dominate
		uint u = (uint)(state % (ALPHABET * ALPHABET));
		char s = (char)((u * u / (ALPHABET * ALPHABET * ALPHABET)) % ALPHABET);
		syms[i] = s;
		freqs[s]++;
	}

	huffman::EncodeTable et = huffman::build_encode(mem, freqs[..])!!;
	defer et.free();
	bits::Writer w = bits::writer(mem);
	et.write_table(mem, &w)!!;
	foreach (s : syms) et.put(&w, s);
	char[] stream = w.finish();
	defer free(stream);

	bits::Reader r = bits::reader(stream);
	huffman::DecodeTable dt = huffman::read_table(mem, &r)!!;
	defer dt.free();
	foreach (i, s : syms)
	{
		uint got = dt.decode(&r)!!;
		assert(got == s, "sym %d: got %d want %d", i, got, s);
	}
	assert(r.ok());
}

fn void invalid_tables_rejected()
{
	// Over-subscribed: three codes of length 1.
	char[3] over = { 1, 1, 1 };
	assert(@catch(huffman::build_decode(mem, over[..])));

	// Incomplete (two symbols, both length 2 — half the tree unused).
	char[2] incomplete = { 2, 2 };
	assert(@catch(huffman::build_decode(mem, incomplete[..])));

	// All-zero lengths.
	char[4] unused = { 0, 0, 0, 0 };
	assert(@catch(huffman::build_decode(mem, unused[..])));

	// But a single symbol (inherently incomplete) is accepted, as in basisu.
	char[3] single = { 0, 3, 0 };
	huffman::DecodeTable dt = huffman::build_decode(mem, single[..])!!;
	dt.free();
}
