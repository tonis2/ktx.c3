// `ktx extract` — pull one image out of a KTX2 file as PNG or raw bytes.
module ktx::cli;
import ktx::container, ktx::vk;
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
	container::Texture tex = container::read_file(tmem, input)!;
	if (level >= tex.level_count())
	{
		io::eprintfn("level %d out of range (file has %d)", level, tex.level_count());
		return BAD_ARGUMENTS~;
	}
	char[] data = tex.image(level, layer, face)!;

	if (raw_flag)
	{
		file::save(output, data)!;
		io::printfn("wrote %s (%d bytes raw %s)", output, data.len, vk::name(tex.vk_format));
		return;
	}

	uint w = tex.level_width(level);
	uint h = tex.level_height(level);
	char[] rgba = decode_image(tmem, tex.vk_format, data, w, h)!;
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
