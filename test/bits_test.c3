module bits_tests @test;
import ktx::bits;

// LSB-first convention against hand-computed bytes: bit i of the stream is
// bit (i & 7) of byte (i >> 3).
fn void read_known_pattern()
{
	// 0xB4 = 1011 0100 -> stream bits 0,0,1,0,1,1,0,1
	// 0x5A = 0101 1010 -> stream bits 0,1,0,1,1,0,1,0
	char[2] data = { 0xB4, 0x5A };
	bits::Reader r = bits::reader(data[..]);
	assert(r.read(4) == 4, "bits 0010 LSB-first = 4");
	assert(r.read(7) == 43, "bits 1101 010 LSB-first = 43");
	assert(r.read(5) == 11, "bits 1101 0 LSB-first = 11");
	assert(r.ok());
	assert(r.remaining() == 0);
}

fn void read_aligned_bytes()
{
	char[4] data = { 0x12, 0x34, 0x56, 0x78 };
	bits::Reader r = bits::reader(data[..]);
	assert(r.read(8) == 0x12);
	assert(r.read(8) == 0x34);
	assert(r.read(16) == 0x7856, "16-bit read is little-endian");
	assert(r.ok());
}

fn void read_64bit_spans()
{
	char[16] data = { 1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11, 12, 13, 14, 15, 16 };
	bits::Reader r = bits::reader(data[..]);
	// Byte-aligned 64-bit read = little-endian u64.
	assert(r.read64(64) == 0x0807060504030201, "got %x", r.read64(0));

	// Unaligned: skip 4 bits into the second half.
	r = bits::reader(data[..]);
	r.skip(4);
	ulong v = r.read64(64);
	assert(v == 0x9080706050403020, "got %x", v);
	assert(r.ok());
}

fn void read_zero_bits()
{
	char[1] data = { 0xFF };
	bits::Reader r = bits::reader(data[..]);
	assert(r.read(0) == 0);
	assert(r.read64(0) == 0);
	assert(r.pos == 0 && r.ok());
}

fn void read_past_end_zero_pads_and_flags()
{
	char[1] data = { 0xFF };
	bits::Reader r = bits::reader(data[..]);
	assert(r.read(6) == 0x3F);
	// 2 valid bits left; the upper 6 read as zero.
	assert(r.read(8) == 0x03);
	assert(!r.ok(), "overflow must latch");
	assert(r.remaining() == 0);
	assert(r.read(32) == 0);
}

fn void peek_does_not_advance()
{
	char[2] data = { 0xAB, 0xCD };
	bits::Reader r = bits::reader(data[..]);
	r.skip(3);
	uint p = r.peek(7);
	assert(p == r.read(7));
	assert(r.pos == 10);

	// Peek past the end must not latch overflow either.
	bits::Reader r2 = bits::reader(data[..]);
	r2.peek(32);
	assert(r2.ok());
}

fn void write_known_pattern()
{
	bits::Writer w = bits::writer(mem);
	w.write(0b101, 3);
	w.write(0b01, 2);
	w.write(0b1, 1);
	char[] out = w.finish();
	defer free(out);
	// bits 1,0,1 | 1,0 | 1 -> 0b00101101 = 0x2D, zero-padded
	assert(out.len == 1);
	assert(out[0] == 0x2D, "got %x", out[0]);
}

fn void write_aligned_bytes()
{
	bits::Writer w = bits::writer(mem);
	w.write(0x12, 8);
	w.write(0x7856, 16);
	w.write64(0x0807060504030201, 64);
	char[] out = w.finish();
	defer free(out);
	assert(out.len == 11);
	assert(out[0] == 0x12 && out[1] == 0x56 && out[2] == 0x78);
	assert(out[3] == 1 && out[10] == 8);
}

// Deterministic pseudo-random (value, width) sequence written then read back,
// long enough to force several buffer growths past the tiny initial capacity.
fn void write_read_roundtrip()
{
	const COUNT = 4000;
	bits::Writer w = bits::writer(mem, 16);
	ulong state = 0x9E3779B97F4A7C15;
	for (int i = 0; i < COUNT; i++)
	{
		state ^= state << 13;
		state ^= state >> 7;
		state ^= state << 17;
		uint n = (uint)(state % 65);   // 0..64
		ulong v = n == 64 ? state : state & (((ulong)1 << n) - 1);
		w.write64(v, n);
	}
	char[] out = w.finish();
	defer free(out);

	bits::Reader r = bits::reader(out);
	state = 0x9E3779B97F4A7C15;
	for (int i = 0; i < COUNT; i++)
	{
		state ^= state << 13;
		state ^= state >> 7;
		state ^= state << 17;
		uint n = (uint)(state % 65);
		ulong want = n == 64 ? state : state & (((ulong)1 << n) - 1);
		ulong got = r.read64(n);
		assert(got == want, "item %d (%d bits): got %x want %x", i, n, got, want);
	}
	assert(r.ok());
	assert(r.remaining() < 8, "only byte padding may remain");
}

fn void writer_empty_finish()
{
	bits::Writer w = bits::writer(mem);
	char[] out = w.finish();
	defer free(out);
	assert(out.len == 0);
}
