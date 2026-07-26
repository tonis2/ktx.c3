// C ABI for using ktx as a shared library (Python ctypes, other FFI).
// Built by native/build-shared.sh into <target>/libktx.{so,dylib,dll} from
// src/ktx/** + this file — no image.c3l/getopt, callers pass raw RGBA8.
//
// All functions return 0 on success; on failure they return 1 and
// ktx_last_error() describes what went wrong. Buffers handed out via out
// pointers are heap allocations the caller must release with ktx_free().
module ktx::capi;
import ktx::container, ktx::codec, ktx::mipgen, ktx::basis, ktx::vk, ktx::util;
import std::core::string;

char[256] g_err;

// FFI callers (Python executors, thread pools) invoke these entry points from
// arbitrary threads, where C3 never auto-creates the thread-local temp
// allocator — the first @pool()/tmem use would abort the whole host process.
// Every exported function that allocates therefore runs inside @pool_init,
// which creates a scoped temp allocator (and tears it down on return) no
// matter which thread calls in. 256KB starting size; it grows on demand.
const sz FFI_POOL_SIZE = 256 * 1024;

fn void set_err(String msg) @local
{
	sz n = msg.len > 255 ? 255 : msg.len;
	g_err[:n] = msg[:n];
	g_err[n] = 0;
}

fn void set_fault(String ctx, fault err) @local => @pool()
{
	set_err(string::tformat("%s: %s", ctx, err));
}

<* Message for the most recent failure ("" if none yet). Static storage. *>
fn ZString ktx_last_error() @export("ktx_last_error")
{
	return (ZString)&g_err[0];
}

<* Release a buffer returned through an out pointer. *>
fn void ktx_free(void* p) @export("ktx_free")
{
	if (p) free(p);
}

<*
 Encode one RGBA8 image (w*h*4 bytes) into a complete KTX2 blob.

 `format` takes the same names as `ktx create -f`: "bc7-srgb", "bc5",
 "rgba8-srgb", ... plus "etc1s"/"uastc" ("-linear" variants for non-color).
 mipmaps: generate a full mip chain. normal_map: renormalize mips (BCn path).
 quality (0..100) / effort (0..10) apply to etc1s/uastc only.
 zstd_level: <0 = no supercompression, 0 = default (3), 1..22 = level
 (BCn/uncompressed path only; basis picks its own supercompression).
*>
fn CInt ktx_encode(char* rgba, uint w, uint h, ZString format,
	CInt mipmaps, CInt normal_map, CInt quality, CInt effort, CInt zstd_level,
	char** out_data, sz* out_len) @export("ktx_encode") => @pool_init(mem, FFI_POOL_SIZE)
{
	*out_data = null;
	*out_len = 0;
	if (!rgba || w == 0 || h == 0)
	{
		set_err("bad arguments: null pixels or zero size");
		return 1;
	}
	String name = format.str_view();
	char[] pixels = rgba[:(sz)w * h * 4];

	uint bfmt;
	bool bsrgb;
	if (codec::is_basis_format(name, &bfmt, &bsrgb))
	{
		basis::EncodeOptions opts = { .quality = quality, .effort = effort, .srgb = bsrgb, .mipmaps = mipmaps != 0 };
		char[][1] imgs = { pixels };
		char[]? blob = basis::encode(mem, bfmt, imgs[..], w, h, basis::TexType.D2, opts);
		if (catch err = blob)
		{
			set_fault("basis encode", err);
			return 1;
		}
		*out_data = blob.ptr;
		*out_len = blob.len;
		return 0;
	}

	uint? vkfmt = codec::parse_format(name);
	if (catch err = vkfmt)
	{
		set_fault("unknown format", err);
		return 1;
	}
	char[]? blob = encode_vk(pixels, w, h, vkfmt, mipmaps != 0, normal_map != 0, zstd_level);
	if (catch err = blob)
	{
		set_fault("encode", err);
		return 1;
	}
	*out_data = blob.ptr;
	*out_len = blob.len;
	return 0;
}

<* The VkFormat pipeline: mip chain -> per-level encode -> container. *>
fn char[]? encode_vk(char[] pixels, uint w, uint h, uint format,
	bool mipmaps, bool normal_map, CInt zstd_level) @local => @pool()
{
	vk::FormatInfo fi = vk::info(format)!;
	uint levels = mipmaps ? mipgen::chain_length(w, h) : 1;
	container::Texture tex = container::create(mem, {
		.vk_format = format,
		.width = w,
		.height = h,
		.face_count = 1,
		.level_count = levels,
	})!;
	defer tex.free();

	mipgen::Options mip_opts = { .srgb = fi.srgb, .renormalize = normal_map };
	char[] rgba = pixels;
	uint lw = w;
	uint lh = h;
	for (uint l = 0; l < levels; ++l)
	{
		if (l > 0)
		{
			rgba = mipgen::next_level(tmem, rgba, lw, lh, mip_opts);
			lw = max(lw >> 1, 1u);
			lh = max(lh >> 1, 1u);
		}
		char[] encoded = codec::encode_image(tmem, format, rgba, lw, lh)!;
		tex.set_image(l, 0, 0, encoded)!;
	}

	container::Scheme scheme = zstd_level < 0 ? container::Scheme.NONE : container::Scheme.ZSTD;
	return container::write(mem, &tex, { .scheme = scheme, .zstd_level = zstd_level > 0 ? zstd_level : 0 });
}

<*
 Encode six RGBA8 cube faces into one KTX2 cubemap blob.

 `faces` is an array of six pointers in KTX face order (+X -X +Y -Y +Z -Z),
 each holding size*size*4 bytes. Every other argument means what it does in
 ktx_encode. The result has faceCount 6, so it satisfies consumers that
 require a cubemap texture type (glTF KHR_environment_map, for one).
*>
fn CInt ktx_encode_cube(char** faces, uint size, ZString format,
	CInt mipmaps, CInt normal_map, CInt quality, CInt effort, CInt zstd_level,
	char** out_data, sz* out_len) @export("ktx_encode_cube") => @pool_init(mem, FFI_POOL_SIZE)
{
	*out_data = null;
	*out_len = 0;
	if (!faces || size == 0)
	{
		set_err("bad arguments: null faces or zero size");
		return 1;
	}
	char[][6] imgs;
	for (uint f = 0; f < 6; ++f)
	{
		if (!faces[f])
		{
			set_err("bad arguments: null cube face");
			return 1;
		}
		imgs[f] = faces[f][:(sz)size * size * 4];
	}
	String name = format.str_view();

	uint bfmt;
	bool bsrgb;
	if (codec::is_basis_format(name, &bfmt, &bsrgb))
	{
		basis::EncodeOptions opts = { .quality = quality, .effort = effort, .srgb = bsrgb, .mipmaps = mipmaps != 0 };
		char[]? blob = basis::encode(mem, bfmt, imgs[..], size, size, basis::TexType.CUBE, opts);
		if (catch err = blob)
		{
			set_fault("basis encode", err);
			return 1;
		}
		*out_data = blob.ptr;
		*out_len = blob.len;
		return 0;
	}

	uint? vkfmt = codec::parse_format(name);
	if (catch err = vkfmt)
	{
		set_fault("unknown format", err);
		return 1;
	}
	char[]? blob = encode_vk_cube(imgs[..], size, vkfmt, mipmaps != 0, normal_map != 0, zstd_level);
	if (catch err = blob)
	{
		set_fault("encode", err);
		return 1;
	}
	*out_data = blob.ptr;
	*out_len = blob.len;
	return 0;
}

<*
 Cubemap twin of encode_vk. Each face carries its own mip chain — filtering
 stops at the face edge rather than reaching across the seam, which is what
 every other offline encoder does at this quality level.
*>
fn char[]? encode_vk_cube(char[][] imgs, uint size, uint format,
	bool mipmaps, bool normal_map, CInt zstd_level) @local => @pool()
{
	vk::FormatInfo fi = vk::info(format)!;
	uint levels = mipmaps ? mipgen::chain_length(size, size) : 1;
	container::Texture tex = container::create(mem, {
		.vk_format = format,
		.width = size,
		.height = size,
		.face_count = 6,
		.level_count = levels,
	})!;
	defer tex.free();

	mipgen::Options mip_opts = { .srgb = fi.srgb, .renormalize = normal_map };
	char[][6] rgba;
	for (uint f = 0; f < 6; ++f) rgba[f] = imgs[f];
	uint lw = size;
	for (uint l = 0; l < levels; ++l)
	{
		if (l > 0)
		{
			for (uint f = 0; f < 6; ++f) rgba[f] = mipgen::next_level(tmem, rgba[f], lw, lw, mip_opts);
			lw = max(lw >> 1, 1u);
		}
		for (uint f = 0; f < 6; ++f)
		{
			char[] encoded = codec::encode_image(tmem, format, rgba[f], lw, lw)!;
			tex.set_image(l, 0, f, encoded)!;
		}
	}

	container::Scheme scheme = zstd_level < 0 ? container::Scheme.NONE : container::Scheme.ZSTD;
	return container::write(mem, &tex, { .scheme = scheme, .zstd_level = zstd_level > 0 ? zstd_level : 0 });
}

<*
 Decode one image (level/layer/face) of a KTX2 blob to RGBA8 (w*h*4 bytes,
 written to out_rgba/out_w/out_h). Handles both the VkFormat container path
 (BC1/BC3/BC4/BC5/BC7 + uncompressed) and ETC1S/UASTC basis payloads.
*>
fn CInt ktx_decode(char* data, sz len, uint level, uint layer, uint face,
	char** out_rgba, uint* out_w, uint* out_h) @export("ktx_decode") => @pool_init(mem, FFI_POOL_SIZE)
{
	*out_rgba = null;
	*out_w = 0;
	*out_h = 0;
	if (!data || len < container::HEADER_SIZE)
	{
		set_err("bad arguments: null or truncated data");
		return 1;
	}
	char[] bytes = data[:len];
	if (bytes[:12] != container::IDENTIFIER[..])
	{
		set_err("not a KTX2 file");
		return 1;
	}

	// vkFormat == 0 marks an ETC1S/UASTC basis payload — transcode to RGBA32.
	if (util::rd32(bytes, 12) == 0)
	{
		basis::Transcoded? t = basis::transcode(mem, bytes, level, layer, face, basis::TF_RGBA32, 4);
		if (catch err = t)
		{
			set_fault("basis transcode", err);
			return 1;
		}
		*out_rgba = t.data.ptr;
		*out_w = t.width;
		*out_h = t.height;
		return 0;
	}

	if (catch err = decode_vk(bytes, level, layer, face, out_rgba, out_w, out_h))
	{
		set_fault("decode", err);
		return 1;
	}
	return 0;
}

fn void? decode_vk(char[] bytes, uint level, uint layer, uint face,
	char** out_rgba, uint* out_w, uint* out_h) @local => @pool()
{
	container::Texture tex = container::read(tmem, bytes)!;
	char[] img = tex.image(level, layer, face)!;
	uint w = tex.level_width(level);
	uint h = tex.level_height(level);
	char[] rgba = codec::decode_image(mem, tex.vk_format, img, w, h)!;
	*out_rgba = rgba.ptr;
	*out_w = w;
	*out_h = h;
}
