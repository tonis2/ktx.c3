// Shared helpers for the ktx CLI: image loading via image.c3l. The format
// name table and RGBA8 <-> VkFormat pipeline live in ktx::codec.
module ktx::cli;
import ktx::vk, ktx::codec;
import image;
import image::png;
import image::jpeg;
import std::io, std::io::file;

faultdef UNSUPPORTED_INPUT, INPUT_MISMATCH, BAD_ARGUMENTS;

fn void print_formats()
{
	io::printn("encodable formats (aliases):");
	foreach (a : codec::ALIASES)
	{
		io::printfn("  %-12s -> %s", a.alias_name, vk::name(a.format));
	}
	io::printn("basis_universal (transcode to BC7/BC1/ETC2/ASTC at load; '-linear' for non-color):");
	io::printn("  etc1s        -> ETC1S + BasisLZ  (smallest; codebook-based)");
	io::printn("  uastc        -> UASTC 4x4 + Zstd (higher quality; larger)");
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
