<*
 What a KTX2 file says about itself, read from its bytes: the header, the level
 index, the DFD summary and the metadata. Nothing is inflated or decoded, so it
 answers for every file, BasisLZ and formats with no decoder included.
 `ktx info` prints this, and a viewer shows it, so the two cannot disagree.
*>
module ktx::container;
import ktx::dfd, ktx::util;
import std::core::ascii;

<* One row of the level index, as stored. *>
struct LevelEntry
{
	ulong offset;
	ulong length;
	<* Bytes after supercompression is undone. *>
	ulong uncompressed;
}

<* Whether the file has a DFD, and whether it parsed. *>
enum DfdStatus : char
{
	MISSING,
	BAD,
	PARSED,
}

<* A file's self-description. Free with `free()`. *>
struct FileInfo
{
	sz file_size;
	uint vk_format;
	uint type_size;
	uint width;
	uint height;
	uint depth;
	uint layer_count;
	uint face_count;
	<* As stored: 0 means the loader generates the mips. *>
	uint level_count;
	<* The raw supercompressionScheme, which may be one this library can't read. *>
	uint scheme;
	<* The entries that fit in the file, level 0 first. Owned. *>
	LevelEntry[] levels;
	DfdStatus dfd_status;
	<* Valid when dfd_status is PARSED. *>
	dfd::Info dfd;
	<* Owned. Empty when the key/value block is missing or malformed. *>
	KvPair[] kv;
	Allocator allocator;
}

<*
 Read a file's self-description.

 @param [&inout] allocator : "Owns the level index and the metadata"
 @param [in] file : "The whole .ktx2 file"

 @return "The description; free it with free()"
 @return? BAD_IDENTIFIER
*>
fn FileInfo? describe(Allocator allocator, char[] file)
{
	if (file.len < HEADER_SIZE || file[:12] != IDENTIFIER[..]) return BAD_IDENTIFIER~;

	FileInfo info = {
		.file_size = file.len,
		.vk_format = util::rd32(file, 12),
		.type_size = util::rd32(file, 16),
		.width = util::rd32(file, 20),
		.height = util::rd32(file, 24),
		.depth = util::rd32(file, 28),
		.layer_count = util::rd32(file, 32),
		.face_count = util::rd32(file, 36),
		.level_count = util::rd32(file, 40),
		.scheme = util::rd32(file, 44),
		.allocator = allocator,
	};

	// Bounded by the file's length, not by the count it claims.
	uint levels = max(info.level_count, 1u);
	uint fits;
	while (fits < levels && HEADER_SIZE + (sz)(fits + 1) * LEVEL_ENTRY_SIZE <= file.len) fits++;
	info.levels = alloc::new_array(allocator, LevelEntry, fits);
	foreach (l, &entry : info.levels)
	{
		sz at = HEADER_SIZE + l * LEVEL_ENTRY_SIZE;
		*entry = { util::rd64(file, at), util::rd64(file, at + 8), util::rd64(file, at + 16) };
	}

	uint dfd_off = util::rd32(file, 48);
	uint dfd_len = util::rd32(file, 52);
	if (dfd_len && (sz)dfd_off + dfd_len <= file.len)
	{
		info.dfd_status = BAD;
		if (try parsed = dfd::parse(file[dfd_off:dfd_len]))
		{
			info.dfd = parsed;
			info.dfd_status = PARSED;
		}
	}

	uint kvd_off = util::rd32(file, 56);
	uint kvd_len = util::rd32(file, 60);
	if (kvd_len && (sz)kvd_off + kvd_len <= file.len)
	{
		// A Texture is only borrowed here for kv_set's copy-and-replace rules.
		Texture pairs = { .allocator = allocator };
		if (catch read_pairs(&pairs, file[kvd_off:kvd_len])) pairs.free();
		info.kv = pairs.kv;
	}
	return info;
}

fn void? read_pairs(Texture* tex, char[] kvd) @local
{
	sz p = 0;
	while (p + 4 <= kvd.len)
	{
		uint pair_len = util::rd32(kvd, p);
		p += 4;
		if (pair_len == 0 || p + pair_len > kvd.len) return MALFORMED~;
		char[] pair = kvd[p:pair_len];
		sz key_end = 0;
		while (key_end < pair.len && pair[key_end] != 0) ++key_end;
		if (key_end == pair.len) return MALFORMED~;
		tex.kv_set((String)pair[:key_end], pair[key_end + 1..]);
		p += pair_len + util::pad_len(4, pair_len);
	}
}

<* Release the level index and the metadata. *>
fn void FileInfo.free(&self)
{
	if (!self.allocator) return;
	if (self.levels.len) alloc::free(self.allocator, self.levels.ptr);
	Texture pairs = { .kv = self.kv, .allocator = self.allocator };
	pairs.free();
	*self = {};
}

<*
 The value as text: printable and NUL-terminated, which is how KTX2 stores a string.

 @return "The text without its NUL, borrowed from the pair"
 @return? INVALID_ARGUMENT
*>
fn String? KvPair.text(&self)
{
	if (self.value.len == 0 || self.value[^1] != 0) return INVALID_ARGUMENT~;
	String text = (String)self.value[:self.value.len - 1];
	foreach (c : text)
	{
		if (!ascii::is_print(c)) return INVALID_ARGUMENT~;
	}
	return text;
}

<*
 The metadata entry stored under a key, as text.

 @param [in] key : "The key, without its NUL"

 @return "Borrowed from the FileInfo"
 @return? INVALID_ARGUMENT
*>
fn String? FileInfo.text(&self, String key)
{
	foreach (&pair : self.kv)
	{
		if (pair.key == key) return pair.text();
	}
	return INVALID_ARGUMENT~;
}

<* The name of a supercompressionScheme value. *>
fn String scheme_name(uint scheme)
{
	switch (scheme)
	{
		case 0: return "none";
		case 1: return "BasisLZ";
		case 2: return "Zstandard";
		case 3: return "ZLIB";
		default: return "unknown";
	}
}
