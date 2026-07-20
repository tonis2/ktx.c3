// LSB-first bit reader/writer over byte slices, the primitive under the
// pure-C3 basis codec (docs/basis-rewrite.md): UASTC/ASTC 128-bit blocks and
// basisu's Huffman-coded BasisLZ streams are all LSB-first — bit i of the
// stream is bit (i & 7) of byte (i >> 3), and a multi-bit read places the
// first stream bit in the result's LSB.
module ktx::bits;
import std::core::mem;

<*
 Reads bit spans from a byte slice. Reading past the end yields zero bits and
 latches `overflowed` — callers check once at the end instead of per read,
 which keeps decode loops branch-light while still catching truncated input.
*>
struct Reader
{
	char[] data;
	usz pos;          // next bit to read
	bool overflowed;  // a read touched bits past the end of `data`
}

fn Reader reader(char[] data)
{
	return { .data = data, .pos = 0, .overflowed = false };
}

<* Read `n` (0..64) bits, first stream bit in the LSB of the result. *>
fn ulong Reader.read64(&self, uint n)
{
	assert(n <= 64, "read of %d bits", n);
	ulong v = 0;
	uint got = 0;
	while (got < n)
	{
		usz at = self.pos + got;
		usz byte_i = at >> 3;
		if (byte_i >= self.data.len)
		{
			self.overflowed = true;
			break;   // zero-padded tail
		}
		uint bit_i = (uint)(at & 7);
		uint take = min(8 - bit_i, n - got);
		uint chunk = ((uint)self.data[byte_i] >> bit_i) & ((1u << take) - 1);
		v |= (ulong)chunk << got;
		got += take;
	}
	self.pos += n;
	return v;
}

<* Read `n` (0..32) bits. *>
fn uint Reader.read(&self, uint n)
{
	assert(n <= 32, "read of %d bits", n);
	return (uint)self.read64(n);
}

<* Look at the next `n` (0..32) bits without consuming them or latching overflow. *>
fn uint Reader.peek(&self, uint n)
{
	usz saved_pos = self.pos;
	bool saved_ovf = self.overflowed;
	uint v = self.read(n);
	self.pos = saved_pos;
	self.overflowed = saved_ovf;
	return v;
}

fn void Reader.skip(&self, usz n)
{
	self.pos += n;
}

<* Bits left before the end of the underlying slice (0 once past it). *>
fn usz Reader.remaining(&self)
{
	usz total = self.data.len * 8;
	return self.pos >= total ? 0 : total - self.pos;
}

<* True while no read has touched bits past the end of the data. *>
fn bool Reader.ok(&self)
{
	return !self.overflowed;
}

<*
 Appends bit spans to a growing allocator-backed buffer. `finish` hands the
 zero-padded byte slice to the caller (allocated from the writer's allocator).
*>
struct Writer
{
	Allocator allocator;
	char* buf;
	usz cap;   // bytes allocated (always > bitpos / 8)
	usz bitpos;
}

fn Writer writer(Allocator allocator, usz initial_cap = 64)
{
	usz cap = max(initial_cap, (usz)16);
	char* buf = alloc::malloc(allocator, (sz)cap);
	mem::clear(buf, (sz)cap);
	return { .allocator = allocator, .buf = buf, .cap = cap, .bitpos = 0 };
}

fn void Writer.ensure(&self, usz bytes_needed)
{
	if (bytes_needed <= self.cap) return;
	usz new_cap = self.cap;
	while (new_cap < bytes_needed) new_cap *= 2;
	self.buf = alloc::realloc(self.allocator, self.buf, (sz)new_cap);
	mem::clear(self.buf + self.cap, (sz)(new_cap - self.cap));
	self.cap = new_cap;
}

<* Append the low `n` (0..64) bits of `value`, LSB first. *>
fn void Writer.write64(&self, ulong value, uint n)
{
	assert(n <= 64, "write of %d bits", n);
	if (n < 64) assert(value < (ulong)1 << n, "value %d does not fit in %d bits", value, n);
	self.ensure((self.bitpos + n + 7) / 8 + 8);
	uint put = 0;
	while (put < n)
	{
		usz at = self.bitpos + put;
		usz byte_i = at >> 3;
		uint bit_i = (uint)(at & 7);
		uint take = min(8 - bit_i, n - put);
		uint chunk = (uint)(value >> put) & ((1u << take) - 1);
		self.buf[byte_i] |= (char)(chunk << bit_i);
		put += take;
	}
	self.bitpos += n;
}

<* Append the low `n` (0..32) bits of `value`. *>
fn void Writer.write(&self, uint value, uint n)
{
	assert(n <= 32, "write of %d bits", n);
	self.write64(value, n);
}

<* Bits written so far. *>
fn usz Writer.bit_count(&self)
{
	return self.bitpos;
}

<*
 The written stream as a byte slice, final partial byte zero-padded. The slice
 is allocated from the writer's allocator and owned by the caller; the writer
 must not be used afterwards.
*>
fn char[] Writer.finish(&self)
{
	usz bytes = (self.bitpos + 7) / 8;
	char* out = alloc::realloc(self.allocator, self.buf, (sz)max(bytes, (usz)1));
	self.buf = null;
	return out[:bytes];
}
