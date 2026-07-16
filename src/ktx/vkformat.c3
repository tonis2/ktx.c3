// VkFormat constants and per-format properties needed by the KTX2
// container: texel block dimensions, block byte size, header typeSize,
// transfer function and channel layout.
//
// Values match Vulkan core (vkformat_enum.h in KTX-Software).
module ktx::vk;

// --- Uncompressed 8-bit ---
const uint R8_UNORM            = 9;
const uint R8_SRGB             = 15;
const uint R8G8_UNORM          = 16;
const uint R8G8_SRGB           = 22;
const uint R8G8B8_UNORM        = 23;
const uint R8G8B8_SRGB         = 29;
const uint B8G8R8_UNORM        = 30;
const uint B8G8R8_SRGB         = 36;
const uint R8G8B8A8_UNORM      = 37;
const uint R8G8B8A8_SRGB       = 43;
const uint B8G8R8A8_UNORM      = 44;
const uint B8G8R8A8_SRGB       = 50;

// --- Uncompressed 16/32-bit ---
const uint R16_UNORM           = 70;
const uint R16_SFLOAT          = 76;
const uint R16G16_UNORM        = 77;
const uint R16G16_SFLOAT       = 83;
const uint R16G16B16A16_UNORM  = 91;
const uint R16G16B16A16_SFLOAT = 97;
const uint R32_SFLOAT          = 100;
const uint R32G32_SFLOAT       = 103;
const uint R32G32B32A32_SFLOAT = 109;

// --- Block-compressed: BC (desktop GPUs) ---
const uint BC1_RGB_UNORM       = 131;
const uint BC1_RGB_SRGB        = 132;
const uint BC1_RGBA_UNORM      = 133;
const uint BC1_RGBA_SRGB       = 134;
const uint BC2_UNORM           = 135;
const uint BC2_SRGB            = 136;
const uint BC3_UNORM           = 137;
const uint BC3_SRGB            = 138;
const uint BC4_UNORM           = 139;
const uint BC4_SNORM           = 140;
const uint BC5_UNORM           = 141;
const uint BC5_SNORM           = 142;
const uint BC6H_UFLOAT         = 143;
const uint BC6H_SFLOAT         = 144;
const uint BC7_UNORM           = 145;
const uint BC7_SRGB            = 146;

// --- Block-compressed: ETC2/EAC and ASTC (read/info support only) ---
const uint ETC2_R8G8B8_UNORM   = 147;
const uint ETC2_R8G8B8_SRGB    = 148;
const uint ETC2_R8G8B8A1_UNORM = 149;
const uint ETC2_R8G8B8A1_SRGB  = 150;
const uint ETC2_R8G8B8A8_UNORM = 151;
const uint ETC2_R8G8B8A8_SRGB  = 152;
const uint EAC_R11_UNORM       = 153;
const uint EAC_R11_SNORM       = 154;
const uint EAC_R11G11_UNORM    = 155;
const uint EAC_R11G11_SNORM    = 156;
const uint ASTC_4X4_UNORM      = 157;
const uint ASTC_12X12_SRGB     = 184;

faultdef UNSUPPORTED_FORMAT;

// How samples are stored for uncompressed formats.
enum PixelKind : char
{
	U8,     // 8-bit unorm/srgb channels
	U16,    // 16-bit unorm channels
	F16,    // half floats
	F32,    // 32-bit floats
	BLOCK,  // block-compressed, data is opaque blocks
}

struct FormatInfo
{
	String name;
	PixelKind kind;
	uint channels;     // color channels for uncompressed; nominal decoded channels for blocks
	uint block_w;      // texel block width  (1 for uncompressed)
	uint block_h;      // texel block height (1 for uncompressed)
	uint block_bytes;  // bytes per block, or per texel when uncompressed
	uint type_size;    // KTX2 header typeSize (1 for bytes/blocks, 2/4 for 16/32-bit types)
	bool srgb;
	bool bgr;          // B and R swapped in memory order (BGRA style)
}

<*
 Properties for a supported VkFormat; UNSUPPORTED_FORMAT for anything
 not in the table.
*>
fn FormatInfo? info(uint format)
{
	switch (format)
	{
		case R8_UNORM:            return { "R8_UNORM", U8, 1, 1, 1, 1, 1, false, false };
		case R8_SRGB:             return { "R8_SRGB", U8, 1, 1, 1, 1, 1, true, false };
		case R8G8_UNORM:          return { "R8G8_UNORM", U8, 2, 1, 1, 2, 1, false, false };
		case R8G8_SRGB:           return { "R8G8_SRGB", U8, 2, 1, 1, 2, 1, true, false };
		case R8G8B8_UNORM:        return { "R8G8B8_UNORM", U8, 3, 1, 1, 3, 1, false, false };
		case R8G8B8_SRGB:         return { "R8G8B8_SRGB", U8, 3, 1, 1, 3, 1, true, false };
		case B8G8R8_UNORM:        return { "B8G8R8_UNORM", U8, 3, 1, 1, 3, 1, false, true };
		case B8G8R8_SRGB:         return { "B8G8R8_SRGB", U8, 3, 1, 1, 3, 1, true, true };
		case R8G8B8A8_UNORM:      return { "R8G8B8A8_UNORM", U8, 4, 1, 1, 4, 1, false, false };
		case R8G8B8A8_SRGB:       return { "R8G8B8A8_SRGB", U8, 4, 1, 1, 4, 1, true, false };
		case B8G8R8A8_UNORM:      return { "B8G8R8A8_UNORM", U8, 4, 1, 1, 4, 1, false, true };
		case B8G8R8A8_SRGB:       return { "B8G8R8A8_SRGB", U8, 4, 1, 1, 4, 1, true, true };
		case R16_UNORM:           return { "R16_UNORM", U16, 1, 1, 1, 2, 2, false, false };
		case R16_SFLOAT:          return { "R16_SFLOAT", F16, 1, 1, 1, 2, 2, false, false };
		case R16G16_UNORM:        return { "R16G16_UNORM", U16, 2, 1, 1, 4, 2, false, false };
		case R16G16_SFLOAT:       return { "R16G16_SFLOAT", F16, 2, 1, 1, 4, 2, false, false };
		case R16G16B16A16_UNORM:  return { "R16G16B16A16_UNORM", U16, 4, 1, 1, 8, 2, false, false };
		case R16G16B16A16_SFLOAT: return { "R16G16B16A16_SFLOAT", F16, 4, 1, 1, 8, 2, false, false };
		case R32_SFLOAT:          return { "R32_SFLOAT", F32, 1, 1, 1, 4, 4, false, false };
		case R32G32_SFLOAT:       return { "R32G32_SFLOAT", F32, 2, 1, 1, 8, 4, false, false };
		case R32G32B32A32_SFLOAT: return { "R32G32B32A32_SFLOAT", F32, 4, 1, 1, 16, 4, false, false };
		case BC1_RGB_UNORM:       return { "BC1_RGB_UNORM", BLOCK, 3, 4, 4, 8, 1, false, false };
		case BC1_RGB_SRGB:        return { "BC1_RGB_SRGB", BLOCK, 3, 4, 4, 8, 1, true, false };
		case BC1_RGBA_UNORM:      return { "BC1_RGBA_UNORM", BLOCK, 4, 4, 4, 8, 1, false, false };
		case BC1_RGBA_SRGB:       return { "BC1_RGBA_SRGB", BLOCK, 4, 4, 4, 8, 1, true, false };
		case BC2_UNORM:           return { "BC2_UNORM", BLOCK, 4, 4, 4, 16, 1, false, false };
		case BC2_SRGB:            return { "BC2_SRGB", BLOCK, 4, 4, 4, 16, 1, true, false };
		case BC3_UNORM:           return { "BC3_UNORM", BLOCK, 4, 4, 4, 16, 1, false, false };
		case BC3_SRGB:            return { "BC3_SRGB", BLOCK, 4, 4, 4, 16, 1, true, false };
		case BC4_UNORM:           return { "BC4_UNORM", BLOCK, 1, 4, 4, 8, 1, false, false };
		case BC4_SNORM:           return { "BC4_SNORM", BLOCK, 1, 4, 4, 8, 1, false, false };
		case BC5_UNORM:           return { "BC5_UNORM", BLOCK, 2, 4, 4, 16, 1, false, false };
		case BC5_SNORM:           return { "BC5_SNORM", BLOCK, 2, 4, 4, 16, 1, false, false };
		case BC6H_UFLOAT:         return { "BC6H_UFLOAT", BLOCK, 3, 4, 4, 16, 1, false, false };
		case BC6H_SFLOAT:         return { "BC6H_SFLOAT", BLOCK, 3, 4, 4, 16, 1, false, false };
		case BC7_UNORM:           return { "BC7_UNORM", BLOCK, 4, 4, 4, 16, 1, false, false };
		case BC7_SRGB:            return { "BC7_SRGB", BLOCK, 4, 4, 4, 16, 1, true, false };
		case ETC2_R8G8B8_UNORM:   return { "ETC2_R8G8B8_UNORM", BLOCK, 3, 4, 4, 8, 1, false, false };
		case ETC2_R8G8B8_SRGB:    return { "ETC2_R8G8B8_SRGB", BLOCK, 3, 4, 4, 8, 1, true, false };
		case ETC2_R8G8B8A1_UNORM: return { "ETC2_R8G8B8A1_UNORM", BLOCK, 4, 4, 4, 8, 1, false, false };
		case ETC2_R8G8B8A1_SRGB:  return { "ETC2_R8G8B8A1_SRGB", BLOCK, 4, 4, 4, 8, 1, true, false };
		case ETC2_R8G8B8A8_UNORM: return { "ETC2_R8G8B8A8_UNORM", BLOCK, 4, 4, 4, 16, 1, false, false };
		case ETC2_R8G8B8A8_SRGB:  return { "ETC2_R8G8B8A8_SRGB", BLOCK, 4, 4, 4, 16, 1, true, false };
		case EAC_R11_UNORM:       return { "EAC_R11_UNORM", BLOCK, 1, 4, 4, 8, 1, false, false };
		case EAC_R11_SNORM:       return { "EAC_R11_SNORM", BLOCK, 1, 4, 4, 8, 1, false, false };
		case EAC_R11G11_UNORM:    return { "EAC_R11G11_UNORM", BLOCK, 2, 4, 4, 16, 1, false, false };
		case EAC_R11G11_SNORM:    return { "EAC_R11G11_SNORM", BLOCK, 2, 4, 4, 16, 1, false, false };
		default:
			// ASTC LDR family: consecutive UNORM/SRGB pairs, all 16-byte blocks.
			if (format >= ASTC_4X4_UNORM && format <= ASTC_12X12_SRGB)
			{
				uint[<2>] dim = astc_block_dim(format);
				bool srgb = (format - ASTC_4X4_UNORM) % 2 == 1;
				return { "ASTC", BLOCK, 4, dim[0], dim[1], 16, 1, srgb, false };
			}
			return UNSUPPORTED_FORMAT~;
	}
}

fn uint[<2>] astc_block_dim(uint format) @local
{
	switch ((format - ASTC_4X4_UNORM) / 2)
	{
		case 0: return { 4, 4 };
		case 1: return { 5, 4 };
		case 2: return { 5, 5 };
		case 3: return { 6, 5 };
		case 4: return { 6, 6 };
		case 5: return { 8, 5 };
		case 6: return { 8, 6 };
		case 7: return { 8, 8 };
		case 8: return { 10, 5 };
		case 9: return { 10, 6 };
		case 10: return { 10, 8 };
		case 11: return { 10, 10 };
		case 12: return { 12, 10 };
		default: return { 12, 12 };
	}
}

fn String name(uint format)
{
	FormatInfo? fi = info(format);
	if (catch fi) return "UNKNOWN";
	return fi.name;
}

<*
 Bytes needed for one image plane of `width` x `height` texels
 (one face/layer/depth-slice), rounding up to whole blocks.
*>
fn sz image_size(uint format, uint width, uint height)
{
	FormatInfo? fi = info(format);
	if (catch fi) return 0;
	sz bx = (sz)((width + fi.block_w - 1) / fi.block_w);
	sz by = (sz)((height + fi.block_h - 1) / fi.block_h);
	return bx * by * fi.block_bytes;
}
