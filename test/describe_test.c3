module describe_tests @test;
import ktx::container, ktx::vk, ktx::dfd, ktx::basis;

fn void describe_reads_header_levels_dfd_and_metadata()
{
	container::Texture tex = container::create(mem, { .vk_format = vk::BC7_SRGB, .width = 16, .height = 8, .layer_count = 2, .level_count = 3 })!!;
	defer tex.free();
	tex.kv_set("three.layers", "srgb rgb=basecolor\0");
	char[] file = container::write(mem, &tex, { .scheme = ZSTD })!!;
	defer free(file);

	container::FileInfo info = container::describe(mem, file)!!;
	defer info.free();
	test::eq(info.file_size, file.len);
	test::eq(info.vk_format, vk::BC7_SRGB);
	test::eq(info.width, 16u);
	test::eq(info.height, 8u);
	test::eq(info.layer_count, 2u);
	test::eq(info.face_count, 1u);
	test::eq(info.level_count, 3u);
	test::eq(container::scheme_name(info.scheme), "Zstandard");
	test::eq(info.levels.len, 3);
	// Level 0 of a 16x8 BC7 array: 4x2 blocks of 16 bytes, two layers.
	test::eq(info.levels[0].uncompressed, 256ul);
	test::eq(info.dfd_status, container::DfdStatus.PARSED);
	test::eq(info.dfd.model, dfd::MODEL_BC7);
	test::eq(info.text("three.layers")!!, "srgb rgb=basecolor");
	test::eq(info.text("KTXwriter")!!, container::LIB_ID);
	test::@error(info.text("missing"), container::INVALID_ARGUMENT);
}

fn void describe_reads_basislz_metadata_that_read_refuses()
{
	char[64 * 4] rgba;
	foreach (i, &c : rgba) *c = (char)(i * 7);
	char[] file = basis::encode_etc1s(mem, rgba[..], 8, 8)!!;
	defer free(file);
	test::@error(container::read(mem, file), container::UNSUPPORTED_SCHEME);

	container::FileInfo info = container::describe(mem, file)!!;
	defer info.free();
	test::eq(container::scheme_name(info.scheme), "BasisLZ");
	test::eq(info.dfd.model, dfd::MODEL_ETC1S);
	test::eq(info.text("KTXwriter")!!, container::LIB_ID);
}

fn void describe_refuses_what_is_not_ktx2()
{
	char[100] junk;
	test::@error(container::describe(mem, junk[..]), container::BAD_IDENTIFIER);
	test::@error(container::describe(mem, container::IDENTIFIER[..]), container::BAD_IDENTIFIER);
}

fn void binary_values_are_not_text()
{
	container::KvPair pair = { "k", { 'a', 1, 0 } };
	test::@error(pair.text(), container::INVALID_ARGUMENT);
	container::KvPair unterminated = { "k", "ab" };
	test::@error(unterminated.text(), container::INVALID_ARGUMENT);
	container::KvPair empty = { "k", {} };
	test::@error(empty.text(), container::INVALID_ARGUMENT);
}
