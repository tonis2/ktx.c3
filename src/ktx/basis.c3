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
import ktx::uastc_bc7, ktx::etc1s_bc7;
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

struct UastcImage @local
{
	char[] blocks;
	uint width;
	uint height;
}

<*
 One image's UASTC block payload out of a container already read. vkFormat is
 0 on a basis file, so Texture.image() cannot size the images itself and the
 level is sliced by block count instead.
*>
fn UastcImage? uastc_slice(container::Texture* tex, uint level, uint layer, uint face) @local
{
	if (level >= tex.level_count()) return TRANSCODE_FAILED~;
	if (layer >= tex.layers() || face >= tex.face_count) return TRANSCODE_FAILED~;

	uint w = tex.level_width(level);
	uint h = tex.level_height(level);
	usz img_size = (usz)((w + 3) / 4) * (usz)((h + 3) / 4) * 16;
	usz offset = ((usz)layer * tex.face_count + face) * img_size;
	char[] level_data = tex.levels[level];
	if (offset + img_size > level_data.len) return TRANSCODE_FAILED~;
	return { .blocks = level_data[offset:img_size], .width = w, .height = h };
}

<*
 One UASTC image at the given target. RGBA32 is the phase-1 per-block decode,
 bit-exact with basisu's transcoder (test/uastc_test.c3 pins it against golden
 dumps); BC7 is the block mapper; BC1/BC3 decode and re-encode.
*>
fn Transcoded? uastc_to(Allocator allocator, UastcImage img, uint tf_format, uint threads = 0) @local => @pool()
{
	if (tf_format == TF_BC7_RGBA)
	{
		char[] blocks = uastc_bc7::map_image(allocator, img.blocks, img.width, img.height, threads)!;
		return { .data = blocks, .width = img.width, .height = img.height };
	}

	Allocator target = tf_format == TF_RGBA32 ? allocator : tmem;
	usz size = (usz)img.width * img.height * 4;
	char* buf = alloc::malloc(target, (sz)size);
	char[] rgba = buf[:size];
	if (catch err = uastc::decode_image(img.blocks, rgba, img.width, img.height))
	{
		alloc::free(target, buf);
		return err~;
	}
	if (tf_format == TF_RGBA32) return { .data = rgba, .width = img.width, .height = img.height };
	return bcn_from_rgba(allocator, rgba, img.width, img.height, tf_format);
}

struct Etc1sFile @local
{
	etc1s::Codebook cb;   // shared by every image in the file
	char[] ktx2;
	char[] sgd;
	uint width;
	uint height;
	uint layers;
	uint faces;
	uint level_count;
}

struct Etc1sImage @local
{
	etc1s::Codebook* cb;
	char[] rgb;
	char[] alpha;   // empty when the file carries no alpha slices
	uint width;
	uint height;
}

<*
 An ETC1S/BasisLZ KTX2 blob's shared parts: the endpoint and selector
 codebooks and the Huffman models every slice in the file is coded against,
 plus what is needed to find any image's slices.

 The BasisLZ level payloads are not Zstd-compressed (the slices themselves are
 the compression), so this parses the level index and
 supercompressionGlobalData directly instead of going through
 container::read.
*>
fn Etc1sFile? etc1s_file(Allocator allocator, char[] ktx2) @local
{
	if (ktx2.len < container::HEADER_SIZE) return OPEN_FAILED~;
	uint layers = max(util::rd32(ktx2, 32), 1u);
	uint face_count = max(util::rd32(ktx2, 36), 1u);
	uint level_count = max(util::rd32(ktx2, 40), 1u);
	ulong sgd_off = util::rd64(ktx2, 64);
	ulong sgd_len = util::rd64(ktx2, 72);
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

	etc1s::Codebook cb = etc1s::decode_codebook(allocator, num_endpoints,
		sgd[descs_end : (sz)endpoints_len],
		num_selectors, sgd[descs_end + (sz)endpoints_len : (sz)selectors_len],
		sgd[descs_end + (sz)endpoints_len + (sz)selectors_len : (sz)tables_len])!;

	return {
		.cb = cb,
		.ktx2 = ktx2,
		.sgd = sgd,
		.width = util::rd32(ktx2, 20),
		.height = util::rd32(ktx2, 24),
		.layers = layers,
		.faces = face_count,
		.level_count = level_count,
	};
}

<* One image's colour and alpha slice payloads out of an opened ETC1S file. *>
fn Etc1sImage? etc1s_slice(Etc1sFile* f, uint level, uint layer, uint face) @local
{
	if (level >= f.level_count || layer >= f.layers || face >= f.faces) return TRANSCODE_FAILED~;

	usz desc = 20 + ((usz)level * f.layers * f.faces + (usz)layer * f.faces + face) * 20;
	uint rgb_off = util::rd32(f.sgd, (sz)desc + 4);
	uint rgb_len = util::rd32(f.sgd, (sz)desc + 8);
	uint alpha_off = util::rd32(f.sgd, (sz)desc + 12);
	uint alpha_len = util::rd32(f.sgd, (sz)desc + 16);

	ulong level_off = util::rd64(f.ktx2, container::HEADER_SIZE + (sz)level * container::LEVEL_ENTRY_SIZE);
	ulong level_len = util::rd64(f.ktx2, container::HEADER_SIZE + (sz)level * container::LEVEL_ENTRY_SIZE + 8);
	if (level_off + level_len > f.ktx2.len) return OPEN_FAILED~;
	char[] level_data = f.ktx2[(sz)level_off:(sz)level_len];
	if ((ulong)rgb_off + rgb_len > level_data.len) return OPEN_FAILED~;
	if (alpha_len && (ulong)alpha_off + alpha_len > level_data.len) return OPEN_FAILED~;

	char[] alpha;
	if (alpha_len) alpha = level_data[alpha_off:alpha_len];
	return {
		.cb = &f.cb,
		.rgb = level_data[rgb_off:rgb_len],
		.alpha = alpha,
		.width = max(f.width >> level, 1u),
		.height = max(f.height >> level, 1u),
	};
}

<*
 One ETC1S image at the given target. RGBA32 is the phase-2 slice decode,
 colour and alpha in the two passes the format keeps them in; BC7 is the block
 mapper; BC1/BC3 decode and re-encode.
*>
fn Transcoded? etc1s_to(Allocator allocator, Etc1sImage* img, uint tf_format, uint threads = 0) @local => @pool()
{
	if (tf_format == TF_BC7_RGBA)
	{
		char[] blocks = etc1s_bc7::map_image(allocator, img.cb, img.rgb, img.alpha,
			img.width, img.height, tmem, threads)!;
		return { .data = blocks, .width = img.width, .height = img.height };
	}

	Allocator target = tf_format == TF_RGBA32 ? allocator : tmem;
	usz size = (usz)img.width * img.height * 4;
	char* buf = alloc::malloc(target, (sz)size);
	char[] rgba = buf[:size];
	bool ok;
	defer if (!ok) alloc::free(target, buf);

	if (img.alpha.len)
	{
		img.cb.decode_slice(img.alpha, img.width, img.height, rgba, etc1s::Pass.ALPHA, tmem)!;
		img.cb.decode_slice(img.rgb, img.width, img.height, rgba, etc1s::Pass.RGB, tmem)!;
	}
	else
	{
		img.cb.decode_slice(img.rgb, img.width, img.height, rgba, etc1s::Pass.RGB_OPAQUE, tmem)!;
	}
	ok = true;
	if (tf_format == TF_RGBA32) return { .data = rgba, .width = img.width, .height = img.height };
	return bcn_from_rgba(allocator, rgba, img.width, img.height, tf_format);
}

<*
 The BC1/BC3 targets, which have no block mapper: decoded pixels through the
 library's own BCn encoders. Quality is tracked by test/transcode_bcn_test.c3.
*>
fn Transcoded? bcn_from_rgba(Allocator allocator, char[] rgba, uint width, uint height, uint tf_format) @local
{
	bcn::BcnFormat fmt = tf_format == TF_BC1_RGB ? bcn::BcnFormat.BC1 : bcn::BcnFormat.BC3;
	char[] blocks = bcn::encode(allocator, fmt, rgba, width, height)!;
	return { .data = blocks, .width = width, .height = height };
}

<*
 Transcode one image (level/layer/face) of an ETC1S/UASTC KTX2 blob to the
 given TF_* target. `unit_bytes` is the target's bytes-per-block (16 for
 BC7/BC3, 8 for BC1/BC4) or bytes-per-pixel (4 for TF_RGBA32). The returned
 slice is allocated from `allocator`.

 Supported targets: TF_RGBA32, TF_BC1_RGB, TF_BC3_RGBA, TF_BC7_RGBA
 (`unit_bytes` is kept for API stability; it is no longer consulted).

 **BC7 is a block mapper** (docs/basis-rewrite.md phase 3): both source
 formats are BC7's own shape — endpoints, a weight grid, an index per texel —
 so ktx::uastc_bc7 and ktx::etc1s_bc7 rewrite each block as a BC7 block and
 never build a pixel. Everything else decodes first.

 A caller wanting a whole mip chain should ask `transcode_levels` for it: this
 reads the file's shared parts — the container index, and for ETC1S the
 codebooks — on every call.
*>
fn Transcoded? transcode(Allocator allocator, char[] ktx2, uint level, uint layer, uint face, uint tf_format, uint unit_bytes) => @pool()
{
	uint model = dfd_model(ktx2);
	if (model != dfd::MODEL_UASTC && model != dfd::MODEL_ETC1S) return OPEN_FAILED~;
	switch (tf_format)
	{
		case TF_RGBA32:
		case TF_BC1_RGB:
		case TF_BC3_RGBA:
		case TF_BC7_RGBA:
			break;
		default:
			return UNSUPPORTED_TARGET~;
	}

	if (model == dfd::MODEL_UASTC)
	{
		container::Texture tex = container::read(tmem, ktx2)!;
		UastcImage img = uastc_slice(&tex, level, layer, face)!;
		return uastc_to(allocator, img, tf_format);
	}
	Etc1sFile file = etc1s_file(tmem, ktx2)!;
	Etc1sImage img = etc1s_slice(&file, level, layer, face)!;
	return etc1s_to(allocator, &img, tf_format);
}

<*
 Every level of one image, transcoded in one pass — level 0 first, one entry
 per level the file carries.

 The same targets `transcode` takes, and the same answers, for a caller that
 wants the whole chain. What it saves is the reading: a UASTC file's levels
 are Zstd-supercompressed as one container, and an ETC1S file's slices are all
 coded against one pair of codebooks, so asking `transcode` level by level
 inflates or Huffman-decodes the shared part again every time — on a 1024x1024
 image with eleven levels, about as much work as the transcode itself.

 The array and every `data` in it are allocated from `allocator`; the caller
 frees each `data` and then the array.

 @param threads : `The block mapper's thread count. 0 decides from the core count; 1 pins it to the calling thread, which is what a caller transcoding several images at once wants.`
*>
fn Transcoded[]? transcode_levels(Allocator allocator, char[] ktx2, uint layer, uint face, uint tf_format, uint threads = 0) => @pool()
{
	uint model = dfd_model(ktx2);
	if (model != dfd::MODEL_UASTC && model != dfd::MODEL_ETC1S) return OPEN_FAILED~;
	Info nfo = info(ktx2)!;
	Transcoded[] out = alloc::new_array(allocator, Transcoded, (sz)nfo.levels);
	uint done;
	defer if (done != nfo.levels)
	{
		for (uint l = 0; l < done; l++) alloc::free(allocator, out[l].data.ptr);
		alloc::free(allocator, out.ptr);
	}

	if (model == dfd::MODEL_UASTC)
	{
		container::Texture tex = container::read(tmem, ktx2)!;
		for (uint l = 0; l < nfo.levels; l++)
		{
			UastcImage img = uastc_slice(&tex, l, layer, face)!;
			out[l] = uastc_to(allocator, img, tf_format, threads)!;
			done++;
		}
		return out;
	}

	Etc1sFile file = etc1s_file(tmem, ktx2)!;
	for (uint l = 0; l < nfo.levels; l++)
	{
		Etc1sImage img = etc1s_slice(&file, l, layer, face)!;
		out[l] = etc1s_to(allocator, &img, tf_format, threads)!;
		done++;
	}
	return out;
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
