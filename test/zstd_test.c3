module ktx_tests @test;
import ktx::zstd;

fn void zstd_roundtrip()
{
	char[] data = "hello hello hello hello hello ktx2 texture data data data".copy(mem);
	defer free(data);

	char[] compressed = zstd::compress(mem, data)!!;
	defer free(compressed);
	assert(compressed.len > 0);

	char[] restored = zstd::decompress(mem, compressed, data.len)!!;
	defer free(restored);
	assert(restored == data);
}
