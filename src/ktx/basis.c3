// FFI bindings to basis_universal's native C API for ETC1S/UASTC + BasisLZ.
// basis_universal is C++; this links its prebuilt static lib (libbasisu) plus a
// C++ runtime. The "wasm" C API returns uint64_t handles that, in native builds,
// are real pointers (malloc cast to uint64_t), so we treat them as addresses.
//
// Encode produces a complete KTX2 blob (BU_COMP_FLAGS_KTX2_OUTPUT); transcode
// turns an ETC1S/UASTC KTX2 into a GPU block format (BC7/BC1/...) or RGBA32.
module ktx::basis;
import std::core::mem;

faultdef ENCODE_FAILED, OPEN_FAILED, START_FAILED, TRANSCODE_FAILED;

// Encoder output formats (basis_tex_format).
const uint ETC1S      = 0;
const uint UASTC_4X4  = 1;

// Transcoder target texture formats (TF_*).
const uint TF_BC1_RGB  = 2;
const uint TF_BC3_RGBA = 3;
const uint TF_BC7_RGBA = 6;
const uint TF_RGBA32   = 13;

// bu_compress_texture flag bits (BU_COMP_FLAGS_* / cFlag* in basisu_comp.h).
const ulong F_THREADED             = (ulong)1 << 9;
const ulong F_KTX2_OUTPUT          = (ulong)1 << 11;
const ulong F_KTX2_UASTC_SUPERCOMP = (ulong)1 << 12;  // Zstd-supercompress UASTC in the KTX2
const ulong F_SRGB                 = (ulong)1 << 13;
const ulong F_GEN_MIPS_CLAMP       = (ulong)1 << 14;

// Texture-type field (bits 25-26): decides whether the extra images passed to
// the encoder are mip levels (2D), array layers, or cubemap faces.
const ulong F_TEX_2D           = (ulong)0 << 25;
const ulong F_TEX_2D_ARRAY     = (ulong)1 << 25;
const ulong F_TEX_CUBEMAP      = (ulong)2 << 25;

// ---- encoder (bu_*) ----
extern fn void  bu_init() @cname("bu_init");
extern fn ulong bu_alloc(ulong size) @cname("bu_alloc");
extern fn void  bu_free(ulong ofs) @cname("bu_free");
extern fn ulong bu_new_comp_params() @cname("bu_new_comp_params");
extern fn uint  bu_delete_comp_params(ulong p) @cname("bu_delete_comp_params");
extern fn uint  bu_comp_params_set_image_rgba32(ulong p, uint idx, ulong img, uint w, uint h, uint pitch) @cname("bu_comp_params_set_image_rgba32");
extern fn uint  bu_compress_texture(ulong p, uint fmt, CInt quality, CInt effort, ulong flags, float rdo) @cname("bu_compress_texture");
extern fn ulong bu_comp_params_get_comp_data_size(ulong p) @cname("bu_comp_params_get_comp_data_size");
extern fn ulong bu_comp_params_get_comp_data_ofs(ulong p) @cname("bu_comp_params_get_comp_data_ofs");

// ---- transcoder (bt_*) ----
extern fn void  bt_init() @cname("bt_init");
extern fn ulong bt_alloc(ulong size) @cname("bt_alloc");
extern fn void  bt_free(ulong ofs) @cname("bt_free");
extern fn ulong bt_ktx2_open(ulong data, uint len) @cname("bt_ktx2_open");
extern fn void  bt_ktx2_close(ulong h) @cname("bt_ktx2_close");
extern fn uint  bt_ktx2_start_transcoding(ulong h) @cname("bt_ktx2_start_transcoding");
extern fn uint  bt_ktx2_get_width(ulong h) @cname("bt_ktx2_get_width");
extern fn uint  bt_ktx2_get_height(ulong h) @cname("bt_ktx2_get_height");
extern fn uint  bt_ktx2_get_levels(ulong h) @cname("bt_ktx2_get_levels");
extern fn uint  bt_ktx2_get_layers(ulong h) @cname("bt_ktx2_get_layers");
extern fn uint  bt_ktx2_get_faces(ulong h) @cname("bt_ktx2_get_faces");
extern fn uint  bt_ktx2_get_level_orig_width(ulong h, uint level, uint layer, uint face) @cname("bt_ktx2_get_level_orig_width");
extern fn uint  bt_ktx2_get_level_orig_height(ulong h, uint level, uint layer, uint face) @cname("bt_ktx2_get_level_orig_height");
extern fn uint  bt_basis_compute_transcoded_image_size_in_bytes(uint fmt, uint w, uint h) @cname("bt_basis_compute_transcoded_image_size_in_bytes");
extern fn uint  bt_ktx2_transcode_image_level(ulong h, uint level, uint layer, uint face, ulong out, uint out_n, uint fmt, uint flags, uint pitch, uint rows, CInt c0, CInt c1, ulong state) @cname("bt_ktx2_transcode_image_level");

bool g_inited @local = false;

// bu_init() also initializes the transcoder; both are idempotent but expensive,
// so call once.
fn void init()
{
	if (!g_inited) { bu_init(); g_inited = true; }
}

// How the extra source images are interpreted by the encoder.
enum TexType : int
{
	D2,      // single 2D image (extra images would be precomputed mips)
	ARRAY,   // one image per array layer
	CUBE,    // six images: +X -X +Y -Y +Z -Z
}

fn ulong TexType.flag(self)
{
	switch (self)
	{
		case ARRAY: return F_TEX_2D_ARRAY;
		case CUBE:  return F_TEX_CUBEMAP;
		default:    return F_TEX_2D;
	}
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
	init();
	if (!images.len) return ENCODE_FAILED~;
	ulong p = bu_new_comp_params();

	foreach (i, rgba : images)
	{
		ulong img = bu_alloc((ulong)rgba.len);
		mem::copy((void*)(uptr)img, rgba.ptr, (sz)rgba.len);
		bu_comp_params_set_image_rgba32(p, (uint)i, img, w, h, w * 4);
		bu_free(img);
	}

	ulong flags = F_KTX2_OUTPUT | F_THREADED | type.flag();
	if (opts.srgb) flags |= F_SRGB;
	if (opts.mipmaps) flags |= F_GEN_MIPS_CLAMP;
	// UASTC blocks are not entropy-coded on their own; ask the KTX2 writer to
	// Zstd them. (Ignored by basis for the already-supercompressed ETC1S.)
	if (fmt == UASTC_4X4) flags |= F_KTX2_UASTC_SUPERCOMP;

	if (bu_compress_texture(p, fmt, opts.quality, opts.effort, flags, (float)0) == 0)
	{
		bu_delete_comp_params(p);
		return ENCODE_FAILED~;
	}

	usz size = (usz)bu_comp_params_get_comp_data_size(p);
	ulong ofs = bu_comp_params_get_comp_data_ofs(p);
	char* buf = alloc::malloc(allocator, (sz)size);
	mem::copy(buf, (void*)(uptr)ofs, (sz)size);
	bu_delete_comp_params(p);
	return buf[:size];
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

<*
 Transcode one image (level/layer/face) of an ETC1S/UASTC KTX2 blob to the
 given TF_* target. `unit_bytes` is the target's bytes-per-block (16 for
 BC7/BC3, 8 for BC1/BC4) or bytes-per-pixel (4 for TF_RGBA32). The returned
 slice is allocated from `allocator`.
*>
fn Transcoded? transcode(Allocator allocator, char[] ktx2, uint level, uint layer, uint face, uint tf_format, uint unit_bytes)
{
	init();
	ulong km = bt_alloc((ulong)ktx2.len);
	mem::copy((void*)(uptr)km, ktx2.ptr, (sz)ktx2.len);

	ulong h = bt_ktx2_open(km, (uint)ktx2.len);
	if (h == 0) { bt_free(km); return OPEN_FAILED~; }
	defer bt_free(km);
	defer bt_ktx2_close(h);

	if (bt_ktx2_start_transcoding(h) == 0) return START_FAILED~;

	uint w = bt_ktx2_get_level_orig_width(h, level, layer, face);
	uint ht = bt_ktx2_get_level_orig_height(h, level, layer, face);
	uint bytes = bt_basis_compute_transcoded_image_size_in_bytes(tf_format, w, ht);

	ulong out = bt_alloc(bytes);
	defer bt_free(out);

	// Pass a null transcode state (last arg 0): the transcoder then uses its own
	// m_def_transcoder_state, which its constructor properly clears. The wasm C
	// API's bt_ktx2_create_transcode_state() leaves m_uncomp_data_level_index at
	// 0 instead of -1, which makes level 0 of a Zstd-supercompressed UASTC skip
	// its decompress step and fail — so we deliberately don't create one.
	uint units = bytes / unit_bytes;
	if (bt_ktx2_transcode_image_level(h, level, layer, face, out, units, tf_format, 0, 0, 0, -1, -1, 0) == 0)
	{
		return TRANSCODE_FAILED~;
	}

	char* buf = alloc::malloc(allocator, (sz)bytes);
	mem::copy(buf, (void*)(uptr)out, (sz)bytes);
	return { .data = buf[:bytes], .width = w, .height = ht };
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
	init();
	ulong km = bt_alloc((ulong)ktx2.len);
	mem::copy((void*)(uptr)km, ktx2.ptr, (sz)ktx2.len);
	defer bt_free(km);
	ulong h = bt_ktx2_open(km, (uint)ktx2.len);
	if (h == 0) return OPEN_FAILED~;
	defer bt_ktx2_close(h);
	uint n = bt_ktx2_get_levels(h);
	return {
		.width  = bt_ktx2_get_width(h),
		.height = bt_ktx2_get_height(h),
		.levels = n < 1 ? 1 : n,
		.layers = bt_ktx2_get_layers(h),
		.faces  = bt_ktx2_get_faces(h),
	};
}

<* Number of mip levels in an ETC1S/UASTC KTX2 blob (>= 1). *>
fn uint? levels(char[] ktx2)
{
	return info(ktx2).levels;
}
