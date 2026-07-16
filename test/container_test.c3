module container_test_util;
import ktx::container, ktx::vk;

<* Deterministic byte pattern so every level/layer/face differs. *>
fn void fill_pattern(char[] buf, uint seed)
{
	uint state = seed * 747796405u + 2891336453u;
	foreach (i, &b : buf)
	{
		state = state * 1664525u + 1013904223u;
		*b = (char)(state >> 24);
	}
}

fn container::Texture make_2d(uint format, uint w, uint h, uint levels)
{
	container::Texture tex = container::create(mem, {
		.vk_format = format,
		.width = w,
		.height = h,
		.level_count = levels,
	})!!;
	for (uint l = 0; l < levels; ++l)
	{
		fill_pattern(tex.levels[l], l + 1);
	}
	return tex;
}

module container_tests @test;
import ktx::container, ktx::vk, ktx::util, ktx::dfd;
import container_test_util;

alias make_2d = container_test_util::make_2d;
alias fill_pattern = container_test_util::fill_pattern;

fn void roundtrip_none()
{
	container::Texture tex = make_2d(vk::R8G8B8A8_SRGB, 8, 8, 4);
	defer tex.free();

	char[] data = container::write(mem, &tex)!!;
	defer free(data);

	// Header spot checks.
	assert(util::rd32(data, 12) == vk::R8G8B8A8_SRGB);
	assert(util::rd32(data, 16) == 1);            // typeSize
	assert(util::rd32(data, 40) == 4);            // levelCount
	assert(util::rd32(data, 44) == 0);            // scheme NONE

	container::Texture back = container::read(mem, data)!!;
	defer back.free();
	assert(back.width == 8 && back.height == 8);
	assert(back.level_count() == 4);
	assert(back.scheme == container::Scheme.NONE);
	for (uint l = 0; l < 4; ++l) assert(back.levels[l] == tex.levels[l]);

	// Level data is stored smallest level first, base level last.
	ulong off_base = util::rd64(data, 80);
	ulong off_smallest = util::rd64(data, 80 + 3 * 24);
	assert(off_smallest < off_base);
	// levels must be aligned to lcm(texelBlockSize=4, 4) = 4 for scheme NONE.
	assert(off_base % 4 == 0 && off_smallest % 4 == 0);
}

fn void roundtrip_zstd()
{
	container::Texture tex = make_2d(vk::R8G8B8A8_UNORM, 16, 16, 3);
	defer tex.free();
	// Make the base level compressible so the size assertion below is meaningful
	// (random noise does not shrink under zstd).
	foreach (i, &b : tex.levels[0]) *b = (char)(i % 16);

	char[] data = container::write(mem, &tex, { .scheme = container::Scheme.ZSTD })!!;
	defer free(data);

	assert(util::rd32(data, 44) == 2);   // scheme ZSTD
	assert(util::rd32(data, 16) == 1);   // typeSize forced to 1
	// Since spec 2.0.4 bytesPlane0 keeps its real value when supercompressed.
	uint dfd_off = util::rd32(data, 48);
	assert(util::rd32(data, (sz)dfd_off + 20) == 4);
	// byteLength != uncompressedByteLength for at least the base level.
	assert(util::rd64(data, 88) < util::rd64(data, 96));

	container::Texture back = container::read(mem, data)!!;
	defer back.free();
	assert(back.scheme == container::Scheme.ZSTD);
	for (uint l = 0; l < 3; ++l) assert(back.levels[l] == tex.levels[l]);
}

fn void roundtrip_zlib()
{
	container::Texture tex = make_2d(vk::R16G16B16A16_UNORM, 4, 4, 1);
	defer tex.free();

	char[] data = container::write(mem, &tex, { .scheme = container::Scheme.ZLIB })!!;
	defer free(data);
	assert(util::rd32(data, 44) == 3);

	container::Texture back = container::read(mem, data)!!;
	defer back.free();
	assert(back.levels[0] == tex.levels[0]);
	assert(back.type_size == 1);   // typeSize 1 in supercompressed file
}

fn void rgb8_mip_alignment()
{
	// RGB8 has a 3-byte texel block; mipPadding must align levels to lcm(3,4)=12.
	container::Texture tex = make_2d(vk::R8G8B8_UNORM, 5, 3, 2);
	defer tex.free();
	assert(tex.levels[0].len == 45 && tex.levels[1].len == 6);

	char[] data = container::write(mem, &tex)!!;
	defer free(data);
	ulong off0 = util::rd64(data, 80);
	ulong off1 = util::rd64(data, 80 + 24);
	assert(off0 % 12 == 0 && off1 % 12 == 0);

	container::Texture back = container::read(mem, data)!!;
	defer back.free();
	assert(back.levels[0] == tex.levels[0] && back.levels[1] == tex.levels[1]);
}

fn void cubemap_faces()
{
	container::Texture tex = container::create(mem, {
		.vk_format = vk::BC1_RGB_UNORM,
		.width = 8,
		.height = 8,
		.face_count = 6,
		.level_count = 2,
	})!!;
	defer tex.free();

	// 8x8 BC1 → 4 blocks × 8 bytes = 32 bytes per face.
	assert(tex.image_size(0)!! == 32);
	assert(tex.levels[0].len == 6 * 32);
	char[32] face_data;
	for (uint f = 0; f < 6; ++f)
	{
		fill_pattern(face_data[..], f + 100);
		tex.set_image(0, 0, f, face_data[..])!!;
	}

	char[] data = container::write(mem, &tex, { .scheme = container::Scheme.ZSTD })!!;
	defer free(data);
	assert(util::rd32(data, 36) == 6);   // faceCount

	container::Texture back = container::read(mem, data)!!;
	defer back.free();
	for (uint f = 0; f < 6; ++f)
	{
		fill_pattern(face_data[..], f + 100);
		assert(back.image(0, 0, f)!! == face_data[..]);
	}
}

fn void kv_metadata()
{
	container::Texture tex = make_2d(vk::R8_UNORM, 4, 4, 1);
	defer tex.free();
	tex.kv_set("ZZCustom", "world\0");
	tex.kv_set("AACustom", "hello\0");

	char[] data = container::write(mem, &tex)!!;
	defer free(data);

	container::Texture back = container::read(mem, data)!!;
	defer back.free();
	assert(back.kv_get("AACustom")!! == "hello\0");
	assert(back.kv_get("ZZCustom")!! == "world\0");
	// KTXwriter added automatically.
	char[] writer = back.kv_get("KTXwriter")!!;
	assert(writer.len > 0);

	// Keys must be sorted in the serialized KVD: AACustom < KTXwriter < ZZCustom.
	uint kvd_off = util::rd32(data, 56);
	uint first_len = util::rd32(data, kvd_off);
	assert(data[kvd_off + 4:8] == "AACustom");
}

fn void generate_mipmaps_flag()
{
	container::Texture tex = container::create(mem, {
		.vk_format = vk::R8G8B8A8_UNORM,
		.width = 16,
		.height = 16,
		.generate_mipmaps = true,
	})!!;
	defer tex.free();

	char[] data = container::write(mem, &tex)!!;
	defer free(data);
	assert(util::rd32(data, 40) == 0);   // levelCount 0 == generate at load

	container::Texture back = container::read(mem, data)!!;
	defer back.free();
	assert(back.generate_mipmaps);
	assert(back.level_count() == 1);
}

fn void dfd_bytes_canonical()
{
	// R8G8B8A8_SRGB canonical DFD: 92 bytes, 4 samples, alpha marked linear.
	char[] d = dfd::create(mem, vk::R8G8B8A8_SRGB)!!;
	defer free(d);
	assert(d.len == 92);
	assert(util::rd32(d, 0) == 92);
	dfd::Info info = dfd::parse(d)!!;
	assert(info.model == dfd::MODEL_RGBSDA);
	assert(info.transfer == dfd::TRANSFER_SRGB);
	assert(info.sample_count == 4);
	assert(info.bytes_plane0 == 4);
	assert(info.block_w == 1 && info.block_h == 1);
	// Sample 3 (alpha): channel id 15 | DATATYPE_LINEAR(16) at bits 24-31.
	uint s3 = util::rd32(d, 28 + 3 * 16);
	assert(s3 >> 24 == (15 | 16));

	// BC7 DFD: one 128-bit sample, 4x4 block, 16 bytes/block.
	char[] b = dfd::create(mem, vk::BC7_SRGB)!!;
	defer free(b);
	assert(b.len == 44);
	dfd::Info binfo = dfd::parse(b)!!;
	assert(binfo.model == dfd::MODEL_BC7);
	assert(binfo.block_w == 4 && binfo.block_h == 4);
	assert(binfo.bytes_plane0 == 16);
	assert((util::rd32(b, 28) >> 16 & 0xFF) == 127);   // bitLength-1
}

fn void reads_reference_file()
{
	// Minimal hand-made KTX2 shipped with image.c3l (4x4 R8, no DFD).
	container::Texture tex = container::read_file(mem, "lib/image.c3l/test/test_gray.ktx2")!!;
	defer tex.free();
	assert(tex.vk_format == vk::R8_UNORM);
	assert(tex.width == 4 && tex.height == 4);
	assert(tex.level_count() == 1);
	assert(tex.levels[0].len == 16);
}

fn void rejects_bad_input()
{
	assert(@catch(container::read(mem, "not a ktx file at all............")));
	// Valid-looking header but BasisLZ scheme → unsupported.
	char[] hdr = alloc::new_array(mem, char, 104);
	defer free(hdr);
	hdr[:12] = container::IDENTIFIER[..];
	util::wr32(hdr, 20, 4);    // width
	util::wr32(hdr, 36, 1);    // faceCount
	util::wr32(hdr, 40, 1);    // levelCount
	util::wr32(hdr, 44, 1);    // scheme BASIS_LZ
	assert(@catch(container::read(mem, hdr)));
}
