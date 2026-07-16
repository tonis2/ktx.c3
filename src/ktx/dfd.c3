// Data Format Descriptor (DFD) creation and parsing for KTX2.
//
// Byte-accurate port of the relevant parts of KTX-Software's dfdutils
// (createdfd.c / khr_df.h, Apache-2.0). A DFD is a little-endian u32
// array: word 0 is the total byte size, followed by one Basic DFD block
// of 6 words + 4 words per sample.
module ktx::dfd;
import ktx::vk;
import ktx::util;

faultdef UNSUPPORTED_FORMAT, MALFORMED;

// khr_df.h constants (only what we use).
const uint VENDORID_KHRONOS       = 0;
const uint DESCRIPTORTYPE_BASIC   = 0;
const uint VERSIONNUMBER          = 2;

const uint MODEL_RGBSDA           = 1;
const uint MODEL_BC1A             = 128;
const uint MODEL_BC2              = 129;
const uint MODEL_BC3              = 130;
const uint MODEL_BC4              = 131;
const uint MODEL_BC5              = 132;
const uint MODEL_BC6H             = 133;
const uint MODEL_BC7              = 134;
const uint MODEL_ETC1             = 160;
const uint MODEL_ETC2             = 161;
const uint MODEL_ASTC             = 162;
const uint MODEL_ETC1S            = 163;
const uint MODEL_UASTC            = 166;

const uint PRIMARIES_UNSPECIFIED  = 0;
const uint PRIMARIES_BT709        = 1;
const uint TRANSFER_LINEAR        = 1;
const uint TRANSFER_SRGB          = 2;
const uint FLAG_ALPHA_STRAIGHT    = 0;

const uint CHANNEL_ALPHA          = 15;   // RGBSDA alpha channel id
const uint DATATYPE_LINEAR        = 1 << 4;
const uint DATATYPE_SIGNED        = 1 << 6;
const uint DATATYPE_FLOAT         = 1 << 7;

struct SampleSpec @local
{
	uint bit_offset;
	uint bit_length;   // actual bits, stored as bits-1
	uint channel;      // channel id | qualifier flags
	uint lower;
	uint upper;
}

<*
 Create the canonical DFD bytes for a supported VkFormat, matching
 what libktx/dfdutils produces for the same format.
*>
fn char[]? create(Allocator allocator, uint format)
{
	vk::FormatInfo fi = vk::info(format) ?? UNSUPPORTED_FORMAT~!;

	SampleSpec[8] samples;
	uint sample_count;
	uint model = MODEL_RGBSDA;
	uint primaries = PRIMARIES_BT709;
	uint transfer = fi.srgb ? TRANSFER_SRGB : TRANSFER_LINEAR;

	switch (fi.kind)
	{
		case U8:
		case U16:
		case F16:
		case F32:
			// One sample per channel (little-endian unpacked layout).
			uint bytes = fi.block_bytes / fi.channels;
			uint bits = bytes * 8;
			sample_count = fi.channels;
			for (uint i = 0; i < fi.channels; ++i)
			{
				uint channel = i;
				if (fi.bgr && (channel == 0 || channel == 2)) channel ^= 2;
				if (channel == 3) channel = CHANNEL_ALPHA;
				uint lower = 0;
				uint upper;
				switch (fi.kind)
				{
					case F16:
					case F32:
						channel |= DATATYPE_FLOAT | DATATYPE_SIGNED;
						upper = 0x3F800000;   // 1.0f
						lower = 0xBF800000;   // -1.0f
					default:
						// UNORM/SRGB
						if (fi.srgb && channel == CHANNEL_ALPHA) channel |= DATATYPE_LINEAR;
						upper = bits >= 32 ? 0xFFFFFFFF : (1u << bits) - 1;
				}
				samples[i] = { i * bits, bits, channel, lower, upper };
			}
		case BLOCK:
			uint lower = 0;
			uint upper = 0xFFFFFFFF;
			uint flags = 0;
			// Alpha samples are linear even under an sRGB transfer function
			// (BC2/BC3 below put alpha in sample 0).
			uint alpha = CHANNEL_ALPHA | (fi.srgb ? DATATYPE_LINEAR : 0);
			switch (format)
			{
				case vk::BC4_SNORM:
				case vk::BC5_SNORM:
					flags = DATATYPE_SIGNED;
					upper = 0x7FFFFFFF;
					lower = 0x80000000;
				case vk::BC6H_UFLOAT:
					flags = DATATYPE_FLOAT;
					upper = 0x3F800000;
					lower = 0;
				case vk::BC6H_SFLOAT:
					flags = DATATYPE_FLOAT | DATATYPE_SIGNED;
					upper = 0x3F800000;
					lower = 0xBF800000;
				default:
					break;
			}
			switch (format)
			{
				case vk::BC1_RGB_UNORM:
				case vk::BC1_RGB_SRGB:
					model = MODEL_BC1A;
					sample_count = 1;
					samples[0] = { 0, 64, 0 | flags, lower, upper };
				case vk::BC1_RGBA_UNORM:
				case vk::BC1_RGBA_SRGB:
					model = MODEL_BC1A;
					sample_count = 1;
					samples[0] = { 0, 64, 1 | flags, lower, upper };   // ALPHAPRESENT
				case vk::BC2_UNORM:
				case vk::BC2_SRGB:
					model = MODEL_BC2;
					sample_count = 2;
					samples[0] = { 0, 64, alpha | flags, lower, upper };
					samples[1] = { 64, 64, 0 | flags, lower, upper };
				case vk::BC3_UNORM:
				case vk::BC3_SRGB:
					model = MODEL_BC3;
					sample_count = 2;
					samples[0] = { 0, 64, alpha | flags, lower, upper };
					samples[1] = { 64, 64, 0 | flags, lower, upper };
				case vk::BC4_UNORM:
				case vk::BC4_SNORM:
					model = MODEL_BC4;
					sample_count = 1;
					samples[0] = { 0, 64, 0 | flags, lower, upper };
				case vk::BC5_UNORM:
				case vk::BC5_SNORM:
					model = MODEL_BC5;
					sample_count = 2;
					samples[0] = { 0, 64, 0 | flags, lower, upper };
					samples[1] = { 64, 64, 1 | flags, lower, upper };
				case vk::BC6H_UFLOAT:
				case vk::BC6H_SFLOAT:
					model = MODEL_BC6H;
					sample_count = 1;
					samples[0] = { 0, 128, 0 | flags, lower, upper };
				case vk::BC7_UNORM:
				case vk::BC7_SRGB:
					model = MODEL_BC7;
					sample_count = 1;
					samples[0] = { 0, 128, 0 | flags, lower, upper };
				default:
					// ETC2/ASTC writing not needed (no encoder); reading works
					// because we never regenerate the DFD on read.
					return UNSUPPORTED_FORMAT~;
			}
	}

	sz total = 4 * (1 + 6 + 4 * (sz)sample_count);
	char[] out = alloc::new_array(allocator, char, total);
	util::wr32(out, 0, (uint)total);
	// BDFD word 0: vendor id (17 bits) | descriptor type (15 bits) — both 0.
	util::wr32(out, 4, VENDORID_KHRONOS | DESCRIPTORTYPE_BASIC << 17);
	// BDFD word 1: version | descriptor block size.
	util::wr32(out, 8, VERSIONNUMBER | (uint)(total - 4) << 16);
	// BDFD word 2: model | primaries | transfer | flags.
	util::wr32(out, 12, model | primaries << 8 | transfer << 16 | FLAG_ALPHA_STRAIGHT << 24);
	// BDFD word 3: texel block dimensions, stored as dim-1 (4th dimension always 0).
	util::wr32(out, 16, (fi.block_w - 1) | (fi.block_h - 1) << 8);
	// BDFD word 4: bytesPlane0..3; word 5: bytesPlane4..7.
	util::wr32(out, 20, fi.block_bytes);
	util::wr32(out, 24, 0);
	foreach (i, s : samples[:sample_count])
	{
		sz at = 28 + i * 16;
		util::wr32(out, at, s.bit_offset | (s.bit_length - 1) << 16 | s.channel << 24);
		util::wr32(out, at + 4, 0);   // sample positions
		util::wr32(out, at + 8, s.lower);
		util::wr32(out, at + 12, s.upper);
	}
	return out;
}

// Parsed summary of a basic DFD block, for validation and `ktx info`.
struct Info
{
	uint model;
	uint primaries;
	uint transfer;
	uint flags;
	uint block_w;
	uint block_h;
	uint block_d;
	uint bytes_plane0;
	uint sample_count;
}

fn Info? parse(char[] dfd)
{
	if (dfd.len < 28) return MALFORMED~;
	uint total = util::rd32(dfd, 0);
	if (total > dfd.len || total < 28) return MALFORMED~;
	uint block_size = util::rd32(dfd, 8) >> 16;
	if (block_size < 24 || (block_size - 24) % 16 != 0) return MALFORMED~;
	uint word2 = util::rd32(dfd, 12);
	uint dims = util::rd32(dfd, 16);
	return {
		.model = word2 & 0xFF,
		.primaries = word2 >> 8 & 0xFF,
		.transfer = word2 >> 16 & 0xFF,
		.flags = word2 >> 24,
		.block_w = (dims & 0xFF) + 1,
		.block_h = (dims >> 8 & 0xFF) + 1,
		.block_d = (dims >> 16 & 0xFF) + 1,
		.bytes_plane0 = util::rd32(dfd, 20) & 0xFF,
		.sample_count = (block_size - 24) / 16,
	};
}

fn String model_name(uint model)
{
	switch (model)
	{
		case MODEL_RGBSDA: return "RGBSDA";
		case MODEL_BC1A:   return "BC1A";
		case MODEL_BC2:    return "BC2";
		case MODEL_BC3:    return "BC3";
		case MODEL_BC4:    return "BC4";
		case MODEL_BC5:    return "BC5";
		case MODEL_BC6H:   return "BC6H";
		case MODEL_BC7:    return "BC7";
		case MODEL_ETC1:   return "ETC1";
		case MODEL_ETC2:   return "ETC2";
		case MODEL_ASTC:   return "ASTC";
		case MODEL_ETC1S:  return "ETC1S";
		case MODEL_UASTC:  return "UASTC";
		default:           return "UNKNOWN";
	}
}
