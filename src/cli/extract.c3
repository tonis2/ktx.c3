// `ktx extract` — pull one image out of a KTX2 file as PNG or raw bytes.
module ktx::cli;
import ktx::container, ktx::vk, ktx::util, ktx::basis, ktx::codec;
import image;
import image::png;
import opt;
import std::io, std::io::file;

const EXTRACT_HELP = `usage: ktx extract [options] -o <out.png> <input.ktx2>

Decodes one image (level/layer/face) to PNG. BC1/BC3/BC4/BC5/BC7 and the
uncompressed formats decode to RGBA8; ETC2/ASTC payloads only support --raw.

options:
  -l, --level <n>    mip level (default 0)
  -a, --layer <n>    array layer (default 0)
  -f, --face <n>     cubemap face (default 0)
  -r, --raw          write the raw (inflated) image bytes instead of PNG
  -o, --output <path>
  -h, --help         this help`;

fn int cmd_extract(String[] args)
{
	int level;
	int layer;
	int face;
	bool raw_flag;
	String output;

	int? end = opt::@parse(args,
		"l", "level", &level,
		"a", "layer", &layer,
		"f", "face", &face,
		"r", "raw", &raw_flag,
		"o", "output", &output,
		"h*", "help", null);
	if (catch err = end)
	{
		if (err == opt::HELP_REQUESTED)
		{
			io::printn(EXTRACT_HELP);
			return 0;
		}
		io::eprintfn("error: bad arguments (%s)", err);
		return 1;
	}

	String[] inputs = args[end..];
	if (inputs.len != 1 || !output.len)
	{
		io::eprintn("error: need exactly one input file and -o <output>");
		io::printn(EXTRACT_HELP);
		return 1;
	}

	if (catch err = extract(inputs[0], output, (uint)level, (uint)layer, (uint)face, raw_flag))
	{
		io::eprintfn("error: %s", err);
		return 1;
	}
	return 0;
}

fn void? extract(String input, String output, uint level, uint layer, uint face, bool raw_flag) @local => @pool()
{
	char[] data = file::load(tmem, input)!;
	if (data.len < container::HEADER_SIZE || data[:12] != container::IDENTIFIER[..])
	{
		io::eprintn("not a KTX2 file");
		return container::BAD_IDENTIFIER~;
	}

	// vkFormat == VK_FORMAT_UNDEFINED (0) marks an ETC1S/UASTC basis payload
	// (BasisLZ scheme 1 or Zstd scheme 2, with the real format in the DFD).
	// Transcode it via basis_universal rather than the VkFormat decode path,
	// which has no ETC1S/UASTC decoder.
	if (util::rd32(data, 12) == 0)
	{
		extract_basis(data, output, level, layer, face)!;
		return;
	}

	container::Texture tex = container::read(tmem, data)!;
	if (level >= tex.level_count())
	{
		io::eprintfn("level %d out of range (file has %d)", level, tex.level_count());
		return BAD_ARGUMENTS~;
	}
	char[] img_bytes = tex.image(level, layer, face)!;

	if (raw_flag)
	{
		file::save(output, img_bytes)!;
		io::printfn("wrote %s (%d bytes raw %s)", output, img_bytes.len, vk::name(tex.vk_format));
		return;
	}

	uint w = tex.level_width(level);
	uint h = tex.level_height(level);
	char[] rgba = codec::decode_image(tmem, tex.vk_format, img_bytes, w, h)!;
	image::Image img = {
		.width = w,
		.height = h,
		.bit_depth = 8,
		.format = image::PixelFormat.RGBA,
		.pixels = rgba,
	};
	png::save_file(&img, output, tmem)!;
	io::printfn("wrote %s (%dx%d from %s level %d)", output, w, h, vk::name(tex.vk_format), level);
}

<* Transcode one image of an ETC1S/UASTC BasisLZ file to RGBA8 and write it as PNG. *>
fn void? extract_basis(char[] data, String output, uint level, uint layer, uint face) @local
{
	basis::Info bi = basis::info(data)!;
	uint layers = max(bi.layers, 1u);   // KTX2 reports 0 layers for a plain 2D texture
	if (level >= bi.levels)
	{
		io::eprintfn("level %d out of range (file has %d)", level, bi.levels);
		return BAD_ARGUMENTS~;
	}
	if (layer >= layers)
	{
		io::eprintfn("layer %d out of range (file has %d)", layer, layers);
		return BAD_ARGUMENTS~;
	}
	if (face >= bi.faces)
	{
		io::eprintfn("face %d out of range (file has %d)", face, bi.faces);
		return BAD_ARGUMENTS~;
	}
	basis::Transcoded t = basis::transcode(tmem, data, level, layer, face, basis::TF_RGBA32, 4)!;
	image::Image img = {
		.width = t.width,
		.height = t.height,
		.bit_depth = 8,
		.format = image::PixelFormat.RGBA,
		.pixels = t.data,
	};
	png::save_file(&img, output, tmem)!;
	io::printfn("wrote %s (%dx%d from basis level %d, layer %d, face %d)", output, t.width, t.height, level, layer, face);
}
