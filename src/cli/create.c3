// `ktx create` — build a KTX2 texture from PNG/JPEG images.
module ktx::cli;
import ktx::container, ktx::vk, ktx::mipgen, ktx::basis;
import image;
import opt;
import std::io, std::io::file;

const CREATE_HELP = `usage: ktx create [options] -o <output.ktx2> <input.png|jpg> [more inputs]

Creates a KTX2 texture. Multiple inputs become array layers, or the six
faces (+X -X +Y -Y +Z -Z) of a cubemap with --cube.

options:
  -f, --format <name>   target format (see 'ktx formats'), default rgba8-srgb
                        use 'etc1s' for ETC1S + BasisLZ (transcodable)
  -m, --mipmap          generate a full mip chain
  -n, --normal-map      inputs are normal maps: mips are renormalized
                        (pairs well with --format bc5)
  -c, --cube            treat exactly 6 inputs as cubemap faces
      --zstd <level>    Zstd supercompression level 1..22 (default: 3)
      --zlib            ZLIB supercompression instead of Zstd
      --raw             no supercompression
  -o, --output <path>   output file (required)
  -h, --help            this help`;

fn int cmd_create(String[] args)
{
	String format_name = "rgba8-srgb";
	String output;
	bool mipmap;
	bool normal_map;
	bool cube;
	bool zlib_flag;
	bool raw_flag;
	int zstd_level = 0;

	int? end = opt::@parse(args,
		"f", "format", &format_name,
		"m", "mipmap", &mipmap,
		"n", "normal-map", &normal_map,
		"c", "cube", &cube,
		null, "zstd", &zstd_level,
		null, "zlib", &zlib_flag,
		null, "raw", &raw_flag,
		"o", "output", &output,
		"h*", "help", null);
	if (catch err = end)
	{
		if (err == opt::HELP_REQUESTED)
		{
			io::printn(CREATE_HELP);
			return 0;
		}
		io::eprintfn("error: bad arguments (%s)", err);
		return 1;
	}

	String[] inputs = args[end..];
	if (!output.len || !inputs.len)
	{
		io::eprintn("error: need at least one input and -o <output>");
		io::printn(CREATE_HELP);
		return 1;
	}
	if (cube && inputs.len != 6)
	{
		io::eprintfn("error: --cube needs exactly 6 inputs, got %d", inputs.len);
		return 1;
	}

	// ETC1S/BasisLZ is produced by basis_universal, which builds the whole KTX2
	// (encode + container + supercompression) itself, so it bypasses the VkFormat
	// per-level pipeline below.
	if (format_name == "etc1s")
	{
		if (cube || inputs.len != 1)
		{
			io::eprintn("error: --format etc1s currently supports a single 2D image");
			return 1;
		}
		if (catch err = create_etc1s(inputs[0], output, mipmap))
		{
			io::eprintfn("error: %s", err);
			return 1;
		}
		return 0;
	}

	uint? format = parse_format(format_name);
	if (catch format)
	{
		io::eprintfn("error: unknown format '%s' (try 'ktx formats')", format_name);
		return 1;
	}
	vk::FormatInfo fi = vk::info(format)!!;

	container::Scheme scheme = container::Scheme.ZSTD;
	if (raw_flag) scheme = container::Scheme.NONE;
	if (zlib_flag) scheme = container::Scheme.ZLIB;

	if (catch err = create_texture(format, fi, inputs, output, mipmap, normal_map, cube, scheme, zstd_level))
	{
		io::eprintfn("error: %s", err);
		return 1;
	}
	return 0;
}

fn void? create_texture(uint format, vk::FormatInfo fi, String[] inputs, String output,
	bool mipmap, bool normal_map, bool cube, container::Scheme scheme, int zstd_level) @local => @pool()
{
	// Load every input up front and check they agree on dimensions.
	image::Image[] images = alloc::new_array(tmem, image::Image, inputs.len);
	foreach (i, path : inputs)
	{
		images[i] = load_image(tmem, path)!;
		if (images[i].width != images[0].width || images[i].height != images[0].height)
		{
			io::eprintfn("input %s is %dx%d, expected %dx%d",
				path, images[i].width, images[i].height, images[0].width, images[0].height);
			return INPUT_MISMATCH~;
		}
	}

	uint w = images[0].width;
	uint h = images[0].height;
	uint levels = mipmap ? mipgen::chain_length(w, h) : 1;
	if (fi.kind == vk::PixelKind.BLOCK && mipmap)
	{
		// Snap the chain so every level exists; block formats accept any size
		// (partial blocks), so the full chain is fine.
	}

	container::Texture tex = container::create(mem, {
		.vk_format = format,
		.width = w,
		.height = h,
		.face_count = cube ? 6 : 1,
		.layer_count = (!cube && inputs.len > 1) ? (uint)inputs.len : 0,
		.level_count = levels,
	})!;
	defer tex.free();

	mipgen::Options mip_opts = { .srgb = fi.srgb, .renormalize = normal_map };

	foreach (i, img : images)
	{
		uint layer = cube ? 0 : (uint)i;
		uint face = cube ? (uint)i : 0;
		char[] rgba = img.pixels;
		uint lw = w;
		uint lh = h;
		for (uint l = 0; l < levels; ++l)
		{
			if (l > 0)
			{
				char[] next = mipgen::next_level(tmem, rgba, lw, lh, mip_opts);
				rgba = next;
				lw = max(lw >> 1, 1u);
				lh = max(lh >> 1, 1u);
			}
			char[] encoded = encode_image(tmem, format, rgba, lw, lh)!;
			tex.set_image(l, layer, face, encoded)!;
		}
	}

	container::write_file(&tex, output, { .scheme = scheme, .zstd_level = zstd_level })!;
	io::printfn("wrote %s: %s %dx%d, %d level%s, %d %s, %s",
		output, fi.name, w, h, levels, levels == 1 ? "" : "s",
		cube ? 6 : (inputs.len > 1 ? inputs.len : 1),
		cube ? "faces" : "layer(s)",
		scheme == container::Scheme.NONE ? "uncompressed" : (scheme == container::Scheme.ZSTD ? "zstd" : "zlib"));
}

<* Encode a single image to an ETC1S + BasisLZ KTX2 via basis_universal. *>
fn void? create_etc1s(String input, String output, bool mipmap) @local => @pool()
{
	image::Image img = load_image(tmem, input)!;
	basis::EncodeOptions opts = { .quality = 90, .effort = 2, .srgb = true, .mipmaps = mipmap };
	char[] ktx2 = basis::encode_etc1s(tmem, img.pixels, img.width, img.height, opts)!;
	file::save(output, ktx2)!;
	io::printfn("wrote %s: ETC1S + BasisLZ %dx%d, %s", output, img.width, img.height,
		mipmap ? "mipmapped" : "single level");
}
