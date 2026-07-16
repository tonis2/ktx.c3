// ZLIB stream format (RFC 1950) on top of the stdlib's raw DEFLATE,
// used for KTX2 ZLIB supercompression (scheme 3).
module ktx::zlib;
import std::compression::deflate;
import std::hash::adler32;

faultdef BAD_HEADER, CHECKSUM_MISMATCH;

fn char[]? compress(Allocator allocator, char[] src)
{
	char[] raw = deflate::compress(allocator, src)!;
	defer alloc::free(allocator, raw.ptr);
	char[] output = alloc::new_array(allocator, char, raw.len + 6);
	// CMF/FLG: deflate, 32K window, default level; (0x78 << 8 | 0x9c) % 31 == 0.
	output[0] = 0x78;
	output[1] = 0x9c;
	output[2:raw.len] = raw[..];
	uint checksum = adler32::hash(src);
	output[^4] = (char)(checksum >> 24);
	output[^3] = (char)(checksum >> 16);
	output[^2] = (char)(checksum >> 8);
	output[^1] = (char)checksum;
	return output;
}

fn char[]? decompress(Allocator allocator, char[] src)
{
	// 2-byte header, 4-byte trailer, method must be deflate, no preset dictionary.
	if (src.len < 6) return BAD_HEADER~;
	if ((src[0] & 0x0f) != 8 || ((uint)src[0] << 8 | src[1]) % 31 != 0 || (src[1] & 0x20) != 0) return BAD_HEADER~;
	char[] output = deflate::decompress(allocator, src[2..^5])!;
	uint expected = (uint)src[^4] << 24 | (uint)src[^3] << 16 | (uint)src[^2] << 8 | src[^1];
	if (adler32::hash(output) != expected)
	{
		alloc::free(allocator, output.ptr);
		return CHECKSUM_MISMATCH~;
	}
	return output;
}
