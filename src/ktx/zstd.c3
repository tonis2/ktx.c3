// Minimal binding to the system libzstd, used for KTX2 Zstandard
// supercompression (scheme 2). Linked via "linked-libraries": ["zstd"].
module ktx::zstd;

extern fn sz __compress_bound(sz src_size) @cname("ZSTD_compressBound");
extern fn sz __compress(void* dst, sz dst_capacity, void* src, sz src_size, CInt level) @cname("ZSTD_compress");
extern fn sz __decompress(void* dst, sz dst_capacity, void* src, sz src_size) @cname("ZSTD_decompress");
extern fn CUInt __is_error(sz code) @cname("ZSTD_isError");

faultdef COMPRESS_FAILED, DECOMPRESS_FAILED, SIZE_MISMATCH;

<*
 Compress `src` at the given level (1..22; 3 matches the libktx default).
 Returns a newly allocated buffer sized to the compressed data.
*>
fn char[]? compress(Allocator allocator, char[] src, int level = 3)
{
	sz bound = __compress_bound(src.len);
	char* buf = alloc::malloc(allocator, bound);
	sz written = __compress(buf, bound, src.ptr, src.len, level);
	if (__is_error(written))
	{
		alloc::free(allocator, buf);
		return COMPRESS_FAILED~;
	}
	buf = alloc::realloc(allocator, buf, written);
	return buf[:written];
}

<*
 Decompress `src` into a buffer of exactly `uncompressed_size` bytes
 (the KTX2 level index records the expected size, so it is always known).
*>
fn char[]? decompress(Allocator allocator, char[] src, sz uncompressed_size)
{
	char* buf = alloc::malloc(allocator, uncompressed_size);
	sz written = __decompress(buf, uncompressed_size, src.ptr, src.len);
	if (__is_error(written))
	{
		alloc::free(allocator, buf);
		return DECOMPRESS_FAILED~;
	}
	if (written != uncompressed_size)
	{
		alloc::free(allocator, buf);
		return SIZE_MISMATCH~;
	}
	return buf[:uncompressed_size];
}
