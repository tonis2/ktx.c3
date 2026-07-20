// ETC1S/UASTC + BasisLZ encode and transcode, pure C3 (docs/basis-rewrite.md).
// Encode produces a complete KTX2 blob (codecs in ktx::uastc / ktx::etc1s,
// container + Zstd via ktx::container); transcode turns an ETC1S/UASTC KTX2
// into RGBA32 or a BCn block format via the library's own encoders. The
// bundled basis_universal FFI that used to live here was removed at the
// phase-6 cutover — the golden corpus recorded from it still pins the
// decoders' bit-exactness (test/gen-golden.sh's header explains how to
// regenerate from the pre-cutover revision).
module ktx::basis;
import ktx::container, ktx::dfd, ktx::util, ktx::uastc, ktx::etc1s, ktx::bc7, ktx::bcn, ktx::mipgen;
import std::core::mem;

faultdef ENCODE_FAILED, OPEN_FAILED, TRANSCODE_FAILED, UNSUPPORTED_TARGET;

// Encoder output formats (basis_tex_format).
const uint ETC1S      = 0;
const uint UASTC_4X4  = 1;

// Transcoder target texture formats (TF_*).
const uint TF_BC1_RGB  = 2;
const uint TF_BC3_RGBA = 3;
const uint TF_BC7_RGBA = 6;
const uint TF_RGBA32   = 13;

// How the extra source images are interpreted by the encoder.
enum TexType : int
{
	D2,      // single 2D image (extra images would be precomputed mips)
	ARRAY,   // one image per array layer
	CUBE,    // six images: +X -X +Y -Y +Z -Z
}

struct EncodeOptions
{
	CInt quality;   // 0..100 (ETC1S codebook size / UASTC RDO; 100 = best quality)
	CInt effort;    // 0..10  (ETC1S compression level / UASTC pack level)
	bool srgb;
	bool mipmaps;
}

<*
 Encode one or more RGBA8 images (each w*h*4 bytes) into an ETC1S or UASTC KTX2
 blob. `fmt` is ETC1S or UASTC_4X4; `type` decides whether the images are a
 single 2D texture, array layers, or the six faces of a cubemap. ETC1S is
 BasisLZ-supercompressed; UASTC is Zstd-supercompressed. The returned slice is
 allocated from `allocator`.
*>
fn char[]? encode(Allocator allocator, uint fmt, char[][] images, uint w, uint h, TexType type, EncodeOptions opts)
{
	if (fmt == UASTC_4X4) return encode_uastc_c3(allocator, images, w, h, type, opts);
	return encode_etc1s_c3(allocator, images, w, h, type, opts);
}

<*
 Pure-C3 UASTC KTX2 encode: per-image mip chains via ktx::mipgen, blocks via
 ktx::uastc, Zstd-supercompressed levels via ktx::container. Matches the
 basisu KTX2 output shape: vkFormat 0, typeSize 1, UASTC DFD (model 166).
 `opts.effort` maps to the basisu pack level like the wasm API does
 (round(effort/10*4)); `opts.quality` is accepted but unused (it only tunes
 RDO, which the C3 encoder doesn't do yet).
*>
fn char[]? encode_uastc_c3(Allocator allocator, char[][] images, uint w, uint h, TexType type, EncodeOptions opts) @local => @pool()
{
	if (!images.len) return ENCODE_FAILED~;
	if (type == TexType.CUBE && (images.len != 6 || w != h)) return ENCODE_FAILED~;
	foreach (img : images)
	{
		if (img.len != (usz)w * h * 4) return ENCODE_FAILED~;
	}
	uint pack_level = ((uint)opts.effort * 4 + 5) / 10;   // round(effort/10*4), like the wasm API

	bool has_alpha;
	foreach (img : images)
	{
		for (usz i = 3; i < img.len; i += 4)
		{
			if (img[i] != 255)
			{
				has_alpha = true;
				break;
			}
		}
		if (has_alpha) break;
	}

	uint levels = opts.mipmaps ? mipgen::chain_length(w, h) : 1;

	container::Texture tex = {
		.vk_format = 0,   // VK_FORMAT_UNDEFINED, as required for UASTC + supercompression
		.type_size = 1,
		.width = w,
		.height = h,
		.layer_count = type == TexType.ARRAY ? (uint)images.len : 0,
		.face_count = type == TexType.CUBE ? 6 : 1,
		.dfd = uastc_dfd(tmem, opts.srgb, has_alpha),
		.allocator = tmem,
	};
	tex.levels = alloc::new_array(tmem, char[], levels);

	// Blocks per level, all images of a level concatenated (layer-major, then
	// face — same as the KTX2 level layout).
	uint image_count = (uint)images.len;
	for (uint l = 0; l < levels; ++l)
	{
		uint lw = max(w >> l, 1u);
		uint lh = max(h >> l, 1u);
		usz img_blocks = (usz)((lw + 3) / 4) * (usz)((lh + 3) / 4) * 16;
		tex.levels[l] = alloc::new_array(tmem, char, (sz)(img_blocks * image_count));
	}
	foreach (idx, img : images)
	{
		char[] mip = img;
		uint lw = w;
		uint lh = h;
		for (uint l = 0; l < levels; ++l)
		{
			if (l > 0)
			{
				mip = mipgen::next_level(tmem, mip, lw, lh, { .srgb = opts.srgb });
				lw = max(lw >> 1, 1u);
				lh = max(lh >> 1, 1u);
			}
			char[] blocks = uastc::encode_image(tmem, mip, lw, lh, pack_level) ?? ENCODE_FAILED~!;
			usz img_blocks = blocks.len;
			tex.levels[l][(usz)idx * img_blocks : img_blocks] = blocks[..];
		}
	}

	return container::write(allocator, &tex, { .scheme = container::Scheme.ZSTD });
}

<*
 Pure-C3 ETC1S/BasisLZ KTX2 encode: mips via ktx::mipgen, global codebooks +
 slice streams via ktx::etc1s, BasisLZ supercompression global data assembled
 here, container written by ktx::container. Matches basisu's output shape:
 vkFormat 0, typeSize 1, ETC1S DFD (model 163), RGB slice (+ alpha slice when
 any input has alpha) per image, sliced per mip level.
*>
fn char[]? encode_etc1s_c3(Allocator allocator, char[][] images, uint w, uint h, TexType type, EncodeOptions opts) @local => @pool()
{
	if (!images.len) return ENCODE_FAILED~;
	if (type == TexType.CUBE && (images.len != 6 || w != h)) return ENCODE_FAILED~;
	foreach (img : images)
	{
		if (img.len != (usz)w * h * 4) return ENCODE_FAILED~;
	}

	bool has_alpha;
	foreach (img : images)
	{
		for (usz i = 3; i < img.len; i += 4)
		{
			if (img[i] != 255)
			{
				has_alpha = true;
				break;
			}
		}
		if (has_alpha) break;
	}

	uint levels = opts.mipmaps ? mipgen::chain_length(w, h) : 1;
	uint image_count = (uint)images.len;
	uint num_images = levels * image_count;
	uint slices_per_image = has_alpha ? 2 : 1;

	// Mip chains per input image, then slices in imageDesc order
	// (level-major, image within level, RGB before alpha).
	char[][] mips = alloc::new_array(tmem, char[], (sz)((usz)levels * image_count));
	foreach (idx, img : images)
	{
		char[] mip = img;
		uint lw = w;
		uint lh = h;
		for (uint l = 0; l < levels; ++l)
		{
			if (l > 0)
			{
				mip = mipgen::next_level(tmem, mip, lw, lh, { .srgb = opts.srgb });
				lw = max(lw >> 1, 1u);
				lh = max(lh >> 1, 1u);
			}
			mips[(usz)l * image_count + (usz)idx] = mip;
		}
	}

	etc1s::EncSlice[] slices = alloc::new_array(tmem, etc1s::EncSlice, (sz)((usz)num_images * slices_per_image));
	for (uint l = 0; l < levels; ++l)
	{
		uint lw = max(w >> l, 1u);
		uint lh = max(h >> l, 1u);
		for (uint i = 0; i < image_count; ++i)
		{
			char[] mip = mips[(usz)l * image_count + i];
			usz si = ((usz)l * image_count + i) * slices_per_image;
			slices[si] = { .rgba = mip, .width = lw, .height = lh, .alpha = false };
			if (has_alpha)
			{
				slices[si + 1] = { .rgba = mip, .width = lw, .height = lh, .alpha = true };
			}
		}
	}

	etc1s::Encoded enc = etc1s::encode(tmem, slices, (uint)opts.quality) ?? ENCODE_FAILED~!;

	// Level payloads: concatenated slice streams, offsets recorded per image.
	char[][] level_payloads = alloc::new_array(tmem, char[], (sz)levels);
	uint[] rgb_offs = alloc::new_array(tmem, uint, (sz)num_images);
	uint[] alpha_offs = alloc::new_array(tmem, uint, (sz)num_images);
	for (uint l = 0; l < levels; ++l)
	{
		usz total;
		for (uint i = 0; i < image_count; ++i)
		{
			usz si = ((usz)l * image_count + i) * slices_per_image;
			rgb_offs[(usz)l * image_count + i] = (uint)total;
			total += enc.slices[si].len;
			if (has_alpha)
			{
				alpha_offs[(usz)l * image_count + i] = (uint)total;
				total += enc.slices[si + 1].len;
			}
		}
		char[] payload = alloc::new_array(tmem, char, (sz)total);
		usz at;
		for (uint i = 0; i < image_count; ++i)
		{
			usz si = ((usz)l * image_count + i) * slices_per_image;
			payload[at : enc.slices[si].len] = enc.slices[si][..];
			at += enc.slices[si].len;
			if (has_alpha)
			{
				payload[at : enc.slices[si + 1].len] = enc.slices[si + 1][..];
				at += enc.slices[si + 1].len;
			}
		}
		level_payloads[l] = payload;
	}

	// supercompressionGlobalData.
	usz sgd_len = 20 + (usz)num_images * 20
		+ enc.endpoints_data.len + enc.selectors_data.len + enc.tables_data.len;
	char[] sgd = alloc::new_array(tmem, char, (sz)sgd_len);
	sgd[0] = (char)(enc.num_endpoints & 0xFF);
	sgd[1] = (char)(enc.num_endpoints >> 8);
	sgd[2] = (char)(enc.num_selectors & 0xFF);
	sgd[3] = (char)(enc.num_selectors >> 8);
	util::wr32(sgd, 4, (uint)enc.endpoints_data.len);
	util::wr32(sgd, 8, (uint)enc.selectors_data.len);
	util::wr32(sgd, 12, (uint)enc.tables_data.len);
	util::wr32(sgd, 16, 0);   // extendedByteLength
	for (uint img = 0; img < num_images; ++img)
	{
		uint l = img / image_count;
		uint i = img % image_count;
		usz si = ((usz)l * image_count + i) * slices_per_image;
		sz at = 20 + (sz)img * 20;
		util::wr32(sgd, at, 0);   // imageFlags
		util::wr32(sgd, at + 4, rgb_offs[img]);
		util::wr32(sgd, at + 8, (uint)enc.slices[si].len);
		util::wr32(sgd, at + 12, has_alpha ? alpha_offs[img] : 0);
		util::wr32(sgd, at + 16, has_alpha ? (uint)enc.slices[si + 1].len : 0);
	}
	usz sec = 20 + (usz)num_images * 20;
	sgd[sec : enc.endpoints_data.len] = enc.endpoints_data[..];
	sec += enc.endpoints_data.len;
	sgd[sec : enc.selectors_data.len] = enc.selectors_data[..];
	sec += enc.selectors_data.len;
	sgd[sec : enc.tables_data.len] = enc.tables_data[..];

	container::Texture tex = {
		.vk_format = 0,
		.type_size = 1,
		.width = w,
		.height = h,
		.layer_count = type == TexType.ARRAY ? image_count : 0,
		.face_count = type == TexType.CUBE ? 6 : 1,
		.dfd = etc1s_dfd(tmem, opts.srgb, has_alpha),
		.allocator = tmem,
		.levels = level_payloads,
	};
	return container::write(allocator, &tex, { .scheme = container::Scheme.BASIS_LZ, .sgd = sgd });
}

<*
 Canonical DFD bytes for an ETC1S KTX2, byte-identical to basisu's: model 163,
 4x4 blocks, bytesPlane0 8, one 64-bit RGB sample — plus a second 64-bit
 alpha-channel sample (and bytesPlane1 8) when the file carries alpha slices.
*>
fn char[] etc1s_dfd(Allocator allocator, bool srgb, bool alpha) @local
{
	uint samples = alpha ? 2 : 1;
	uint size = 24 + samples * 16 + 4;
	char[] d = alloc::new_array(allocator, char, (sz)size);
	util::wr32(d, 0, size);
	util::wr32(d, 8, 2 | ((24 + samples * 16) << 16));
	d[12] = (char)dfd::MODEL_ETC1S;
	d[13] = (char)dfd::PRIMARIES_BT709;
	d[14] = (char)(srgb ? dfd::TRANSFER_SRGB : dfd::TRANSFER_LINEAR);
	d[16] = 3;   // 4x4 blocks
	d[17] = 3;
	d[20] = 8;   // bytesPlane0
	if (alpha) d[21] = 8;
	d[30] = 63;                              // sample 0: 64-bit RGB
	util::wr32(d, 40, 0xFFFF_FFFF);
	if (alpha)
	{
		d[44] = 64;                          // sample 1: 64-bit alpha at bit 64
		d[46] = 63;
		d[47] = (char)dfd::CHANNEL_ALPHA;
		util::wr32(d, 56, 0xFFFF_FFFF);
	}
	return d;
}

<*
 Canonical DFD bytes for a UASTC KTX2, byte-identical to what basisu's KTX2
 writer produces: model 166, BT709 primaries, 4x4 blocks, bytesPlane0 16, one
 128-bit sample with channel 0 (RGB) or 3 (RGBA).
*>
fn char[] uastc_dfd(Allocator allocator, bool srgb, bool alpha) @local
{
	char[] d = alloc::new_array(allocator, char, 44);
	util::wr32(d, 0, 44);                    // dfdTotalSize
	util::wr32(d, 8, 2 | (40 << 16));        // versionNumber 2, descriptorBlockSize 40
	d[12] = (char)dfd::MODEL_UASTC;
	d[13] = (char)dfd::PRIMARIES_BT709;
	d[14] = (char)(srgb ? dfd::TRANSFER_SRGB : dfd::TRANSFER_LINEAR);
	d[16] = 3;                               // texelBlockDimension0 (4-1)
	d[17] = 3;
	d[20] = 16;                              // bytesPlane0
	d[30] = 127;                             // sample bitLength (128-1)
	d[31] = alpha ? 3 : 0;                   // channelType: RGBA / RGB
	util::wr32(d, 40, 0xFFFF_FFFF);          // sampleUpper
	return d;
}

<*
 Encode a single RGBA8 image (w*h*4 bytes) into an ETC1S KTX2 blob (BasisLZ
 supercompressed). Convenience wrapper over `encode`.
*>
fn char[]? encode_etc1s(Allocator allocator, char[] rgba, uint w, uint h, EncodeOptions opts = { .quality = 90, .effort = 2, .srgb = true, .mipmaps = false })
{
	char[][1] imgs = { rgba };
	return encode(allocator, ETC1S, imgs[..], w, h, TexType.D2, opts);
}

struct Transcoded
{
	char[] data;
	uint width;
	uint height;
}

<* DFD color model of a KTX2 blob (dfd::MODEL_UASTC / MODEL_ETC1S for basis files). *>
fn uint dfd_model(char[] ktx2) @local
{
	if (ktx2.len < container::HEADER_SIZE) return 0;
	uint dfd_off = util::rd32(ktx2, 48);
	uint dfd_len = util::rd32(ktx2, 52);
	if (!dfd_len || (sz)dfd_off + dfd_len > ktx2.len) return 0;
	dfd::Info? info = dfd::parse(ktx2[dfd_off:dfd_len]);
	if (catch info) return 0;
	return info.model;
}

<*
 Pure-C3 RGBA32 transcode of one image of a UASTC KTX2 blob
 (docs/basis-rewrite.md phase 1): container read (undoing Zstd
 supercompression) -> per-block UASTC decode. Bit-exact with basisu's
 transcoder, which test/uastc_test.c3 checks against golden dumps.
*>
fn Transcoded? transcode_uastc_rgba32(Allocator allocator, char[] ktx2, uint level, uint layer, uint face) @local => @pool()
{
	container::Texture tex = container::read(tmem, ktx2)!;
	if (level >= tex.level_count()) return TRANSCODE_FAILED~;
	if (layer >= tex.layers() || face >= tex.face_count) return TRANSCODE_FAILED~;

	uint w = tex.level_width(level);
	uint h = tex.level_height(level);
	// vkFormat is 0 for basis files, so Texture.image() can't size the images;
	// slice the level payload by block count directly.
	usz img_size = (usz)((w + 3) / 4) * (usz)((h + 3) / 4) * 16;
	usz offset = ((usz)layer * tex.face_count + face) * img_size;
	char[] level_data = tex.levels[level];
	if (offset + img_size > level_data.len) return TRANSCODE_FAILED~;

	char* buf = alloc::malloc(allocator, (sz)((usz)w * h * 4));
	char[] rgba = buf[:(usz)w * h * 4];
	if (catch err = uastc::decode_image(level_data[offset:img_size], rgba, w, h))
	{
		alloc::free(allocator, buf);
		return err~;
	}
	return { .data = rgba, .width = w, .height = h };
}

<*
 Transcode one image (level/layer/face) of an ETC1S/UASTC KTX2 blob to the
 given TF_* target. `unit_bytes` is the target's bytes-per-block (16 for
 BC7/BC3, 8 for BC1/BC4) or bytes-per-pixel (4 for TF_RGBA32). The returned
 slice is allocated from `allocator`.

 Supported targets: TF_RGBA32, TF_BC1_RGB, TF_BC3_RGBA, TF_BC7_RGBA
 (`unit_bytes` is kept for API stability; it is no longer consulted).
*>
fn Transcoded? transcode(Allocator allocator, char[] ktx2, uint level, uint layer, uint face, uint tf_format, uint unit_bytes)
{
	uint model = dfd_model(ktx2);
	if (model != dfd::MODEL_UASTC && model != dfd::MODEL_ETC1S) return OPEN_FAILED~;
	switch (tf_format)
	{
		case TF_RGBA32:
			return model == dfd::MODEL_UASTC
				? transcode_uastc_rgba32(allocator, ktx2, level, layer, face)
				: transcode_etc1s_rgba32(allocator, ktx2, level, layer, face);
		case TF_BC1_RGB:
		case TF_BC3_RGBA:
		case TF_BC7_RGBA:
			return transcode_bcn(allocator, ktx2, level, layer, face, tf_format, model);
		default:
			return UNSUPPORTED_TARGET~;
	}
}

<*
 BC1/BC3/BC7 targets without basisu (docs/basis-rewrite.md phase 3): pure-C3
 RGBA decode, then the library's own BCn encoders. Correct output rather than
 basisu's specialized block-level transcode — quality tracked by
 test/transcode_bcn_test.c3.
*>
fn Transcoded? transcode_bcn(Allocator allocator, char[] ktx2, uint level, uint layer, uint face, uint tf_format, uint model) @local => @pool()
{
	Transcoded src = model == dfd::MODEL_UASTC
		? transcode_uastc_rgba32(tmem, ktx2, level, layer, face)!
		: transcode_etc1s_rgba32(tmem, ktx2, level, layer, face)!;

	char[] blocks;
	switch (tf_format)
	{
		case TF_BC1_RGB:  blocks = bcn::encode(allocator, bcn::BcnFormat.BC1, src.data, src.width, src.height)!;
		case TF_BC3_RGBA: blocks = bcn::encode(allocator, bcn::BcnFormat.BC3, src.data, src.width, src.height)!;
		default:          blocks = bc7::encode(allocator, src.data, src.width, src.height)!;
	}
	return { .data = blocks, .width = src.width, .height = src.height };
}

<*
 Pure-C3 RGBA32 transcode of one image of an ETC1S/BasisLZ KTX2 blob
 (docs/basis-rewrite.md phase 2). The BasisLZ level payloads are not
 Zstd-compressed (the slices themselves are the compression), so this parses
 the level index and supercompressionGlobalData directly instead of going
 through container::read.
*>
fn Transcoded? transcode_etc1s_rgba32(Allocator allocator, char[] ktx2, uint level, uint layer, uint face) @local => @pool()
{
	if (ktx2.len < container::HEADER_SIZE) return OPEN_FAILED~;
	uint width = util::rd32(ktx2, 20);
	uint height = util::rd32(ktx2, 24);
	uint layers = max(util::rd32(ktx2, 32), 1u);
	uint face_count = max(util::rd32(ktx2, 36), 1u);
	uint level_count = max(util::rd32(ktx2, 40), 1u);
	ulong sgd_off = util::rd64(ktx2, 64);
	ulong sgd_len = util::rd64(ktx2, 72);
	if (level >= level_count || layer >= layers || face >= face_count) return TRANSCODE_FAILED~;
	if (!sgd_len || sgd_off + sgd_len > ktx2.len) return OPEN_FAILED~;

	// supercompressionGlobalData: counts/lengths header, per-image slice
	// descs, then the endpoint / selector / Huffman-table sections.
	char[] sgd = ktx2[(sz)sgd_off:(sz)sgd_len];
	if (sgd.len < 20) return OPEN_FAILED~;
	uint num_endpoints = util::rd16(sgd, 0);
	uint num_selectors = util::rd16(sgd, 2);
	ulong endpoints_len = util::rd32(sgd, 4);
	ulong selectors_len = util::rd32(sgd, 8);
	ulong tables_len = util::rd32(sgd, 12);
	uint num_images = level_count * layers * face_count;
	usz descs_end = 20 + (usz)num_images * 20;
	if (descs_end + endpoints_len + selectors_len + tables_len > sgd.len) return OPEN_FAILED~;
	char[] endpoints_data = sgd[descs_end : (sz)endpoints_len];
	char[] selectors_data = sgd[descs_end + (sz)endpoints_len : (sz)selectors_len];
	char[] tables_data = sgd[descs_end + (sz)endpoints_len + (sz)selectors_len : (sz)tables_len];

	usz desc = 20 + ((usz)level * layers * face_count + (usz)layer * face_count + face) * 20;
	uint rgb_off = util::rd32(sgd, (sz)desc + 4);
	uint rgb_len = util::rd32(sgd, (sz)desc + 8);
	uint alpha_off = util::rd32(sgd, (sz)desc + 12);
	uint alpha_len = util::rd32(sgd, (sz)desc + 16);

	ulong level_off = util::rd64(ktx2, container::HEADER_SIZE + (sz)level * container::LEVEL_ENTRY_SIZE);
	ulong level_len = util::rd64(ktx2, container::HEADER_SIZE + (sz)level * container::LEVEL_ENTRY_SIZE + 8);
	if (level_off + level_len > ktx2.len) return OPEN_FAILED~;
	char[] level_data = ktx2[(sz)level_off:(sz)level_len];
	if ((ulong)rgb_off + rgb_len > level_data.len) return OPEN_FAILED~;
	if (alpha_len && (ulong)alpha_off + alpha_len > level_data.len) return OPEN_FAILED~;

	etc1s::Codebook cb = etc1s::decode_codebook(tmem, num_endpoints, endpoints_data,
		num_selectors, selectors_data, tables_data)!;

	uint w = max(width >> level, 1u);
	uint h = max(height >> level, 1u);
	char* buf = alloc::malloc(allocator, (sz)((usz)w * h * 4));
	char[] rgba = buf[:(usz)w * h * 4];
	bool ok;
	defer if (!ok) alloc::free(allocator, buf);

	if (alpha_len)
	{
		cb.decode_slice(level_data[alpha_off:alpha_len], w, h, rgba, etc1s::Pass.ALPHA, tmem)!;
		cb.decode_slice(level_data[rgb_off:rgb_len], w, h, rgba, etc1s::Pass.RGB, tmem)!;
	}
	else
	{
		cb.decode_slice(level_data[rgb_off:rgb_len], w, h, rgba, etc1s::Pass.RGB_OPAQUE, tmem)!;
	}
	ok = true;
	return { .data = rgba, .width = w, .height = h };
}

struct Info
{
	uint width;
	uint height;
	uint levels;   // >= 1
	uint layers;   // array layers (0 for a plain 2D texture)
	uint faces;    // 6 for a cubemap, else 1
}

<* Dimensions and level/layer/face counts of an ETC1S/UASTC KTX2 blob. *>
fn Info? info(char[] ktx2)
{
	if (ktx2.len < container::HEADER_SIZE) return OPEN_FAILED~;
	if (ktx2[:12] != container::IDENTIFIER[..]) return OPEN_FAILED~;
	uint model = dfd_model(ktx2);
	if (model != dfd::MODEL_UASTC && model != dfd::MODEL_ETC1S) return OPEN_FAILED~;
	uint n = util::rd32(ktx2, 40);
	uint faces = util::rd32(ktx2, 36);
	return {
		.width  = util::rd32(ktx2, 20),
		.height = util::rd32(ktx2, 24),
		.levels = n < 1 ? 1 : n,
		.layers = util::rd32(ktx2, 32),
		.faces  = faces < 1 ? 1 : faces,
	};
}

<* Number of mip levels in an ETC1S/UASTC KTX2 blob (>= 1). *>
fn uint? levels(char[] ktx2)
{
	return info(ktx2).levels;
}
