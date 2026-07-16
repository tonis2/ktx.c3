// KTX2 container reader/writer.
//
// Byte-accurate port of the container logic in KTX-Software
// (lib/src/texture2.c, writer2.c, ktxint.h — Apache-2.0), limited to
// the game-development path: uncompressed and block-compressed formats
// with optional Zstd/ZLIB supercompression. BasisLZ (scheme 1) files
// are rejected — use BCn + Zstd for engine-ready textures instead.
//
// File layout (all little-endian):
//   identifier[12] + header fields (80 bytes total)
//   level index: levelCount × 24 bytes (entry 0 = base/largest level)
//   DFD, KVD, [8-byte-aligned SGD]
//   mip padding, then level data written smallest level first
module ktx::container;
import ktx::vk, ktx::dfd, ktx::zstd, ktx::zlib, ktx::util;
import std::io::file;
import std::sort;

const char[12] IDENTIFIER = { 0xAB, 0x4B, 0x54, 0x58, 0x20, 0x32, 0x30, 0xBB, 0x0D, 0x0A, 0x1A, 0x0A };
const sz HEADER_SIZE = 80;
const sz LEVEL_ENTRY_SIZE = 24;
const String WRITER_KEY = "KTXwriter";
const String LIB_ID = "c3ktx v0.1.0";
const uint MAX_LEVELS = 32;   // enough for 2^31 textures; sanity bound on parse

// Ordinals match the KTX2 supercompressionScheme field values.
enum Scheme : uint
{
	NONE,       // 0
	BASIS_LZ,   // 1 (rejected on read/write)
	ZSTD,       // 2
	ZLIB,       // 3
}

faultdef BAD_IDENTIFIER,
	MALFORMED,
	UNSUPPORTED_SCHEME,
	INVALID_ARGUMENT,
	SIZE_MISMATCH;

struct KvPair
{
	String key;      // owned
	char[] value;    // owned; include a trailing NUL yourself for text values
}

struct Texture
{
	uint vk_format;
	uint type_size;        // header typeSize (byte size of the underlying component type)
	uint width;
	uint height;           // 0 for 1D textures
	uint depth;            // 0 unless 3D
	uint layer_count;      // 0 = not an array texture
	uint face_count;       // 1, or 6 for cubemaps
	bool generate_mipmaps; // file said levelCount == 0 (loader should generate)
	Scheme scheme;         // scheme the file was stored with (levels held inflated)
	char[] dfd;            // raw DFD bytes (owned)
	KvPair[] kv;           // owned
	char[][] levels;       // inflated level payloads, [0] = base level (owned)
	Allocator allocator;
}

// -------------------------------------------------------------------------
// Accessors

fn uint Texture.level_count(&self) => (uint)self.levels.len;
fn uint Texture.layers(&self) => self.layer_count > 0 ? self.layer_count : 1;
fn uint Texture.level_width(&self, uint level) => max(self.width >> level, 1u);
fn uint Texture.level_height(&self, uint level) => max(self.height >> level, 1u) ;
fn uint Texture.level_depth(&self, uint level) => self.depth == 0 ? 1 : max(self.depth >> level, 1u);

<* Bytes of one image (one face of one layer, including all depth slices). *>
fn sz? Texture.image_size(&self, uint level)
{
	if (level >= self.levels.len) return INVALID_ARGUMENT~;
	return vk::image_size(self.vk_format, self.level_width(level), self.level_height(level))
		* self.level_depth(level);
}

<* View of one image inside the level payload. *>
fn char[]? Texture.image(&self, uint level, uint layer = 0, uint face = 0)
{
	sz img = self.image_size(level)!;
	if (layer >= self.layers() || face >= self.face_count) return INVALID_ARGUMENT~;
	sz offset = ((sz)layer * self.face_count + face) * img;
	if (offset + img > self.levels[level].len) return SIZE_MISMATCH~;
	return self.levels[level][offset:img];
}

<* Copy `data` over one image inside the level payload. *>
fn void? Texture.set_image(&self, uint level, uint layer, uint face, char[] data)
{
	char[] dst = self.image(level, layer, face)!;
	if (data.len != dst.len) return SIZE_MISMATCH~;
	dst[..] = data[..];
}

fn char[]? Texture.kv_get(&self, String key)
{
	foreach (pair : self.kv)
	{
		if (pair.key == key) return pair.value;
	}
	return INVALID_ARGUMENT~;
}

<* Insert or replace a key/value entry (both copied). *>
fn void Texture.kv_set(&self, String key, char[] value)
{
	foreach (&pair : self.kv)
	{
		if (pair.key == key)
		{
			alloc::free(self.allocator, pair.value.ptr);
			pair.value = copy_bytes(self.allocator, value);
			return;
		}
	}
	KvPair[] grown = alloc::new_array(self.allocator, KvPair, self.kv.len + 1);
	grown[:self.kv.len] = self.kv[..];
	grown[^1] = { key.copy(self.allocator), copy_bytes(self.allocator, value) };
	if (self.kv.len) alloc::free(self.allocator, self.kv.ptr);
	self.kv = grown;
}

fn void Texture.free(&self)
{
	if (!self.allocator) return;
	foreach (level : self.levels)
	{
		if (level.len) alloc::free(self.allocator, level.ptr);
	}
	if (self.levels.len) alloc::free(self.allocator, self.levels.ptr);
	foreach (pair : self.kv)
	{
		alloc::free(self.allocator, pair.key.ptr);
		if (pair.value.len) alloc::free(self.allocator, pair.value.ptr);
	}
	if (self.kv.len) alloc::free(self.allocator, self.kv.ptr);
	if (self.dfd.len) alloc::free(self.allocator, self.dfd.ptr);
	*self = {};
}

fn char[] copy_bytes(Allocator allocator, char[] src) @local
{
	char[] out = alloc::new_array(allocator, char, src.len);
	out[..] = src[..];
	return out;
}

// -------------------------------------------------------------------------
// Creation

struct CreateInfo
{
	uint vk_format;
	uint width;
	uint height;           // 0 for 1D
	uint depth;            // 0 unless 3D
	uint layer_count;      // 0 = not an array
	uint face_count;       // default 1; 6 for cubemaps
	uint level_count;      // default 1
	bool generate_mipmaps;
}

<*
 Create an empty texture with zeroed level payloads sized for the format,
 ready for set_image() calls.
*>
fn Texture? create(Allocator allocator, CreateInfo info)
{
	uint faces = info.face_count == 0 ? 1 : info.face_count;
	uint levels = info.level_count == 0 ? 1 : info.level_count;
	vk::FormatInfo fi = vk::info(info.vk_format) ?? INVALID_ARGUMENT~!;
	if (info.width == 0) return INVALID_ARGUMENT~;
	if (faces != 1 && faces != 6) return INVALID_ARGUMENT~;
	if (faces == 6 && (info.depth != 0 || info.width != info.height)) return INVALID_ARGUMENT~;
	if (info.generate_mipmaps && levels != 1) return INVALID_ARGUMENT~;
	// Every level must be at least one texel.
	if (levels > 1 && max(info.width, max(info.height, info.depth)) >> (levels - 1) == 0) return INVALID_ARGUMENT~;

	Texture tex = {
		.vk_format = info.vk_format,
		.type_size = fi.type_size,
		.width = info.width,
		.height = info.height,
		.depth = info.depth,
		.layer_count = info.layer_count,
		.face_count = faces,
		.generate_mipmaps = info.generate_mipmaps,
		.scheme = Scheme.NONE,
		.allocator = allocator,
	};
	tex.dfd = dfd::create(allocator, info.vk_format)!;
	tex.levels = alloc::new_array(allocator, char[], levels);
	for (uint l = 0; l < levels; ++l)
	{
		sz size = vk::image_size(info.vk_format, tex.level_width(l), tex.level_height(l))
			* tex.level_depth(l) * tex.layers() * faces;
		tex.levels[l] = alloc::new_array(allocator, char, size);
	}
	return tex;
}

// -------------------------------------------------------------------------
// Reading

fn Texture? read_file(Allocator allocator, String path)
{
	char[] data = file::load(allocator, path)!;
	defer alloc::free(allocator, data.ptr);
	return read(allocator, data);
}

fn Texture? read(Allocator allocator, char[] data)
{
	if (data.len < HEADER_SIZE) return MALFORMED~;
	if (data[:12] != IDENTIFIER[..]) return BAD_IDENTIFIER~;

	uint vk_format = util::rd32(data, 12);
	uint type_size = util::rd32(data, 16);
	uint width = util::rd32(data, 20);
	uint height = util::rd32(data, 24);
	uint depth = util::rd32(data, 28);
	uint layer_count = util::rd32(data, 32);
	uint face_count = util::rd32(data, 36);
	uint level_count = util::rd32(data, 40);
	uint scheme_raw = util::rd32(data, 44);
	uint dfd_offset = util::rd32(data, 48);
	uint dfd_len = util::rd32(data, 52);
	uint kvd_offset = util::rd32(data, 56);
	uint kvd_len = util::rd32(data, 60);
	// supercompressionGlobalData (offsets 64/72) only exists for BasisLZ,
	// which we reject below.

	if (width == 0) return MALFORMED~;
	if (face_count != 1 && face_count != 6) return MALFORMED~;
	if (scheme_raw > (uint)Scheme.ZLIB.ordinal) return UNSUPPORTED_SCHEME~;
	Scheme scheme = Scheme::from_ordinal(scheme_raw);
	if (scheme == Scheme.BASIS_LZ) return UNSUPPORTED_SCHEME~;

	uint levels = max(level_count, 1u);
	if (levels > MAX_LEVELS) return MALFORMED~;
	sz index_end = HEADER_SIZE + (sz)levels * LEVEL_ENTRY_SIZE;
	if (data.len < index_end) return MALFORMED~;
	if ((sz)dfd_offset + dfd_len > data.len) return MALFORMED~;
	if ((sz)kvd_offset + kvd_len > data.len) return MALFORMED~;

	Texture tex = {
		.vk_format = vk_format,
		.type_size = type_size,
		.width = width,
		.height = height,
		.depth = depth,
		.layer_count = layer_count,
		.face_count = face_count,
		.generate_mipmaps = level_count == 0,
		.scheme = scheme,
		.allocator = allocator,
	};
	bool ok;
	defer if (!ok) tex.free();

	if (dfd_len) tex.dfd = copy_bytes(allocator, data[dfd_offset:dfd_len]);
	if (kvd_len) parse_kvd(&tex, data[kvd_offset:kvd_len])!;

	tex.levels = alloc::new_array(allocator, char[], levels);
	for (uint l = 0; l < levels; ++l)
	{
		sz at = HEADER_SIZE + l * LEVEL_ENTRY_SIZE;
		ulong offset = util::rd64(data, at);
		ulong length = util::rd64(data, at + 8);
		ulong uncompressed = util::rd64(data, at + 16);
		if (offset + length > data.len) return MALFORMED~;
		char[] raw = data[(sz)offset:(sz)length];
		switch (scheme)
		{
			case NONE:
				if (length != uncompressed) return MALFORMED~;
				tex.levels[l] = copy_bytes(allocator, raw);
			case ZSTD:
				tex.levels[l] = zstd::decompress(allocator, raw, (sz)uncompressed)!;
			case ZLIB:
				char[] inflated = zlib::decompress(allocator, raw)!;
				if (inflated.len != uncompressed)
				{
					alloc::free(allocator, inflated.ptr);
					return SIZE_MISMATCH~;
				}
				tex.levels[l] = inflated;
			default:
				unreachable();
		}
	}
	ok = true;
	return tex;
}

fn void? parse_kvd(Texture* tex, char[] kvd) @local
{
	sz p = 0;
	while (p + 4 <= kvd.len)
	{
		uint pair_len = util::rd32(kvd, p);
		p += 4;
		if (pair_len == 0 || p + pair_len > kvd.len) return MALFORMED~;
		char[] pair = kvd[p:pair_len];
		// Key is NUL-terminated UTF-8; value is the rest.
		sz key_end = 0;
		while (key_end < pair.len && pair[key_end] != 0) ++key_end;
		if (key_end == pair.len) return MALFORMED~;
		tex.kv_set((String)pair[:key_end], pair[key_end + 1..]);
		p += pair_len + util::pad_len(4, pair_len);
	}
}

// -------------------------------------------------------------------------
// Writing

struct WriteOptions
{
	Scheme scheme;         // NONE, ZSTD or ZLIB
	int zstd_level;        // 1..22; 0 → default (3, same as libktx)
}

fn void? write_file(Texture* tex, String path, WriteOptions opts = {}) => @pool()
{
	char[] data = write(tmem, tex, opts)!;
	file::save(path, data)!;
}

<* Serialize the texture to KTX2 file bytes. *>
fn char[]? write(Allocator allocator, Texture* tex, WriteOptions opts = {}) => @pool()
{
	if (opts.scheme == Scheme.BASIS_LZ) return UNSUPPORTED_SCHEME~;
	if (tex.levels.len == 0 || tex.width == 0) return INVALID_ARGUMENT~;
	if (tex.face_count != 1 && tex.face_count != 6) return INVALID_ARGUMENT~;
	if (tex.generate_mipmaps && tex.levels.len != 1) return INVALID_ARGUMENT~;
	uint levels = (uint)tex.levels.len;

	// Expected payload sizes when the format is known.
	uint block_bytes = 4;
	vk::FormatInfo? fi = vk::info(tex.vk_format);
	if (try fi)
	{
		block_bytes = fi.block_bytes;
		for (uint l = 0; l < levels; ++l)
		{
			sz expect = vk::image_size(tex.vk_format, tex.level_width(l), tex.level_height(l))
				* tex.level_depth(l) * tex.layers() * tex.face_count;
			if (tex.levels[l].len != expect) return SIZE_MISMATCH~;
		}
	}

	// DFD: reuse the texture's (round-trip fidelity), else create canonical
	// bytes. Since spec 2.0.4 bytesPlane0 keeps its real value even when
	// supercompressed (zeroing it is deprecated), so restore it if this
	// texture was read from an older file that zeroed it.
	char[] dfd_bytes;
	if (tex.dfd.len)
	{
		dfd_bytes = copy_bytes(tmem, tex.dfd);
		if (try fi && dfd_bytes.len >= 24 && util::rd32(dfd_bytes, 20) == 0)
		{
			util::wr32(dfd_bytes, 20, fi.block_bytes);
		}
	}
	else
	{
		dfd_bytes = dfd::create(tmem, tex.vk_format)!;
	}

	// KVD: KTXwriter is required by the spec; entries sorted by key.
	KvPair[] pairs = alloc::new_array(tmem, KvPair, tex.kv.len + 1);
	sz pair_count;
	foreach (pair : tex.kv) pairs[pair_count++] = pair;
	if (@catch(tex.kv_get(WRITER_KEY)))
	{
		char[] libid = alloc::new_array(tmem, char, LIB_ID.len + 1);
		libid[:LIB_ID.len] = LIB_ID[..];
		pairs[pair_count++] = { WRITER_KEY, libid };
	}
	KvPair[] kv = pairs[:pair_count];
	sort::quicksort(kv, fn int(KvPair a, KvPair b) => compare_to(a.key, b.key));
	sz kvd_len;
	foreach (pair : kv)
	{
		sz entry = pair.key.len + 1 + pair.value.len;
		kvd_len += 4 + entry + util::pad_len(4, entry);
	}

	// Supercompress level payloads (levels stay independent streams).
	char[][] payloads = alloc::new_array(tmem, char[], levels);
	foreach (l, level : tex.levels)
	{
		switch (opts.scheme)
		{
			case NONE: payloads[l] = level;
			case ZSTD: payloads[l] = zstd::compress(tmem, level, opts.zstd_level ?: 3)!;
			case ZLIB: payloads[l] = zlib::compress(tmem, level)!;
			default: unreachable();
		}
	}

	// Layout. Level data goes smallest level first, each level aligned to
	// lcm(blockSize, 4) when not supercompressed (mipPadding), unaligned
	// otherwise.
	sz req_align = opts.scheme == Scheme.NONE ? util::lcm4(block_bytes) : 1;
	sz index_size = (sz)levels * LEVEL_ENTRY_SIZE;
	sz dfd_offset = HEADER_SIZE + index_size;
	sz kvd_offset = dfd_offset + dfd_bytes.len;
	sz cursor = kvd_offset + kvd_len;
	cursor += util::pad_len(req_align, cursor);
	ulong[MAX_LEVELS] level_offsets;
	for (uint l = levels; l > 0; --l)
	{
		uint i = l - 1;   // write order: smallest (last index) first
		cursor += util::pad_len(req_align, cursor);
		level_offsets[i] = (ulong)cursor;
		cursor += payloads[i].len;
	}

	char[] out = alloc::new_array(allocator, char, cursor);   // zero-init covers padding
	out[:12] = IDENTIFIER[..];
	util::wr32(out, 12, tex.vk_format);
	util::wr32(out, 16, opts.scheme != Scheme.NONE ? 1 : tex.type_size);
	util::wr32(out, 20, tex.width);
	util::wr32(out, 24, tex.height);
	util::wr32(out, 28, tex.depth);
	util::wr32(out, 32, tex.layer_count);
	util::wr32(out, 36, tex.face_count);
	util::wr32(out, 40, tex.generate_mipmaps ? 0 : levels);
	util::wr32(out, 44, opts.scheme.ordinal);
	util::wr32(out, 48, (uint)dfd_offset);
	util::wr32(out, 52, (uint)dfd_bytes.len);
	util::wr32(out, 56, kvd_len ? (uint)kvd_offset : 0);
	util::wr32(out, 60, (uint)kvd_len);
	util::wr64(out, 64, 0);   // sgdByteOffset
	util::wr64(out, 72, 0);   // sgdByteLength

	for (uint l = 0; l < levels; ++l)
	{
		sz at = HEADER_SIZE + l * LEVEL_ENTRY_SIZE;
		util::wr64(out, at, level_offsets[l]);
		util::wr64(out, at + 8, payloads[l].len);
		util::wr64(out, at + 16, tex.levels[l].len);
	}

	out[dfd_offset:dfd_bytes.len] = dfd_bytes[..];

	sz p = kvd_offset;
	foreach (pair : kv)
	{
		sz entry = pair.key.len + 1 + pair.value.len;
		util::wr32(out, p, (uint)entry);
		p += 4;
		out[p:pair.key.len] = pair.key[..];
		p += pair.key.len + 1;   // NUL terminator is already zero
		if (pair.value.len) out[p:pair.value.len] = pair.value[..];
		p += pair.value.len + util::pad_len(4, entry);
	}

	foreach (l, payload : payloads)
	{
		if (payload.len) out[(sz)level_offsets[l]:payload.len] = payload[..];
	}
	return out;
}

macro compare_to(String a, String b) @local
{
	// Bytewise comparison, matching libktx's strcmp-based KVD sort.
	sz n = min(a.len, b.len);
	for (sz i = 0; i < n; ++i)
	{
		if (a[i] != b[i]) return a[i] < b[i] ? -1 : 1;
	}
	if (a.len == b.len) return 0;
	return a.len < b.len ? -1 : 1;
}
