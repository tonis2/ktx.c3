// Shared helpers for the ktx CLI: friendly format names, image loading
// via image.c3l, and the RGBA8 → target-format encode pipeline.
module ktx::cli;
import ktx::container, ktx::vk, ktx::bcn, ktx::bc7, ktx::mipgen;
import image;
import image::png;
import image::jpeg;
import std::io, std::io::file;

faultdef UNKNOWN_FORMAT, UNSUPPORTED_INPUT, INPUT_MISMATCH, BAD_ARGUMENTS;

struct FormatAlias @local
{
	String alias_name;
	uint format;
}

const FormatAlias[] ALIASES @local = {
	{ "r8", vk::R8_UNORM },
	{ "r8-srgb", vk::R8_SRGB },
	{ "rg8", vk::R8G8_UNORM },
	{ "rg8-srgb", vk::R8G8_SRGB },
	{ "rgb8", vk::R8G8B8_UNORM },
	{ "rgb8-srgb", vk::R8G8B8_SRGB },
	{ "rgba8", vk::R8G8B8A8_UNORM },
	{ "rgba8-srgb", vk::R8G8B8A8_SRGB },
	{ "r16", vk::R16_UNORM },
	{ "rg16", vk::R16G16_UNORM },
	{ "rgba16", vk::R16G16B16A16_UNORM },
	{ "bc1", vk::BC1_RGB_UNORM },
	{ "bc1-srgb", vk::BC1_RGB_SRGB },
	{ "bc3", vk::BC3_UNORM },
	{ "bc3-srgb", vk::BC3_SRGB },
	{ "bc4", vk::BC4_UNORM },
	{ "bc5", vk::BC5_UNORM },
	{ "bc7", vk::BC7_UNORM },
	{ "bc7-srgb", vk::BC7_SRGB },
};

<* Resolve a friendly alias ("bc7-srgb") or exact VkFormat name ("BC7_SRGB"). *>
fn uint? parse_format(String name)
{
	foreach (a : ALIASES)
	{
		if (a.alias_name == name) return a.format;
	}
	// Exact names, case-sensitive scan over the supported id range.
	for (uint f = 1; f <= vk::ASTC_12X12_SRGB; ++f)
	{
		vk::FormatInfo? fi = vk::info(f);
		if (try fi && fi.name == name) return f;
	}
	return UNKNOWN_FORMAT~;
}

fn void print_formats()
{
	io::printn("encodable formats (aliases):");
	foreach (a : ALIASES)
	{
		io::printfn("  %-12s -> %s", a.alias_name, vk::name(a.format));
	}
}

<* Load a PNG or JPEG (detected by magic bytes) as an 8-bit RGBA image. *>
fn image::Image? load_image(Allocator allocator, String path)
{
	char[] data = file::load(tmem, path)!;
	image::Image img;
	if (data.len > 8 && data[:4] == { 0x89, 'P', 'N', 'G' })
	{
		img = png::load_bytes(data, tmem)!;
	}
	else if (data.len > 3 && data[0] == 0xFF && data[1] == 0xD8)
	{
		img = jpeg::load_bytes(data, tmem)!;
	}
	else
	{
		return UNSUPPORTED_INPUT~;
	}
	if (img.bit_depth != 8)
	{
		return UNSUPPORTED_INPUT~;   // 16-bit PNG input not wired up yet
	}
	char[] rgba = img.to_rgba(allocator);
	return { .width = img.width, .height = img.height, .bit_depth = 8, .format = image::PixelFormat.RGBA, .pixels = rgba, .allocator = allocator };
}

<* Encode one RGBA8 image into the texture's VkFormat representation. *>
fn char[]? encode_image(Allocator allocator, uint format, char[] rgba, uint w, uint h)
{
	vk::FormatInfo fi = vk::info(format)!;
	sz pixels = (sz)w * h;
	switch (format)
	{
		case vk::BC1_RGB_UNORM:
		case vk::BC1_RGB_SRGB:
			return bcn::encode(allocator, bcn::BcnFormat.BC1, rgba, w, h);
		case vk::BC3_UNORM:
		case vk::BC3_SRGB:
			return bcn::encode(allocator, bcn::BcnFormat.BC3, rgba, w, h);
		case vk::BC4_UNORM:
			return bcn::encode(allocator, bcn::BcnFormat.BC4, rgba, w, h);
		case vk::BC5_UNORM:
			return bcn::encode(allocator, bcn::BcnFormat.BC5, rgba, w, h);
		case vk::BC7_UNORM:
		case vk::BC7_SRGB:
			bool has_alpha = false;
			for (sz i = 3; i < rgba.len; i += 4)
			{
				if (rgba[i] != 255)
				{
					has_alpha = true;
					break;
				}
			}
			return bc7::encode(allocator, rgba, w, h, has_alpha);
		default:
			break;
	}
	switch (fi.kind)
	{
		case U8:
			// Channel extraction from RGBA8.
			uint c = fi.channels;
			char[] out = alloc::new_array(allocator, char, pixels * c);
			for (sz p = 0; p < pixels; ++p)
			{
				for (uint k = 0; k < c; ++k)
				{
					uint src = k;
					if (fi.bgr && (k == 0 || k == 2)) src = 2 - k;
					out[p * c + k] = rgba[p * 4 + src];
				}
			}
			return out;
		case U16:
			// Upscale 8-bit source to 16-bit little-endian (v * 257).
			uint c = fi.channels;
			char[] out = alloc::new_array(allocator, char, pixels * c * 2);
			for (sz p = 0; p < pixels; ++p)
			{
				for (uint k = 0; k < c; ++k)
				{
					ushort v = (ushort)rgba[p * 4 + k] * 257;
					out[(p * c + k) * 2] = (char)v;
					out[(p * c + k) * 2 + 1] = (char)(v >> 8);
				}
			}
			return out;
		default:
			return UNSUPPORTED_INPUT~;
	}
}

<* Decode one image of the texture back to RGBA8 (for extract). *>
fn char[]? decode_image(Allocator allocator, uint format, char[] data, uint w, uint h)
{
	vk::FormatInfo fi = vk::info(format)!;
	sz pixels = (sz)w * h;
	switch (format)
	{
		case vk::BC1_RGB_UNORM:
		case vk::BC1_RGB_SRGB:
		case vk::BC1_RGBA_UNORM:
		case vk::BC1_RGBA_SRGB:
			return bcn::decode(allocator, bcn::BcnFormat.BC1, data, w, h);
		case vk::BC3_UNORM:
		case vk::BC3_SRGB:
			return bcn::decode(allocator, bcn::BcnFormat.BC3, data, w, h);
		case vk::BC4_UNORM:
			return bcn::decode(allocator, bcn::BcnFormat.BC4, data, w, h);
		case vk::BC5_UNORM:
			return bcn::decode(allocator, bcn::BcnFormat.BC5, data, w, h);
		case vk::BC7_UNORM:
		case vk::BC7_SRGB:
			return bc7::decode(allocator, data, w, h);
		default:
			break;
	}
	switch (fi.kind)
	{
		case U8:
			uint c = fi.channels;
			if (data.len < pixels * c) return UNSUPPORTED_INPUT~;
			char[] out = alloc::new_array(allocator, char, pixels * 4);
			for (sz p = 0; p < pixels; ++p)
			{
				char[4] px = { 0, 0, 0, 255 };
				for (uint k = 0; k < c; ++k)
				{
					uint dst = k;
					if (fi.bgr && (k == 0 || k == 2)) dst = 2 - k;
					px[dst] = data[p * c + k];
				}
				if (c == 1)
				{
					px[1] = px[0];
					px[2] = px[0];   // grayscale expand
				}
				out[p * 4:4] = px[..];
			}
			return out;
		case U16:
			uint c = fi.channels;
			if (data.len < pixels * c * 2) return UNSUPPORTED_INPUT~;
			char[] out = alloc::new_array(allocator, char, pixels * 4);
			for (sz p = 0; p < pixels; ++p)
			{
				char[4] px = { 0, 0, 0, 255 };
				for (uint k = 0; k < c; ++k)
				{
					px[k] = data[(p * c + k) * 2 + 1];   // high byte ≈ 8-bit value
				}
				if (c == 1)
				{
					px[1] = px[0];
					px[2] = px[0];
				}
				out[p * 4:4] = px[..];
			}
			return out;
		default:
			return UNSUPPORTED_INPUT~;
	}
}
