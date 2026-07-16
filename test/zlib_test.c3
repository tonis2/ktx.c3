module ktx_tests @test;
import ktx::zlib;

fn void zlib_roundtrip()
{
	char[] data = "zlib zlib zlib wrapped deflate stream for ktx2 supercompression".copy(mem);
	defer free(data);

	char[] compressed = zlib::compress(mem, data)!!;
	defer free(compressed);
	assert(compressed.len >= 6);
	assert(compressed[0] == 0x78);

	char[] restored = zlib::decompress(mem, compressed)!!;
	defer free(restored);
	assert(restored == data);
}

fn void zlib_rejects_garbage()
{
	char[] bogus = { 0x12, 0x34, 0x56, 0x78, 0x9a, 0xbc, 0xde };
	assert(@catch(zlib::decompress(mem, bogus[..])));
}
