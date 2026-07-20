// `ktx create` — build a KTX2 texture from PNG/JPEG images.
module ktx::cli;
import ktx::container, ktx::vk, ktx::mipgen, ktx::basis, ktx::codec;
import image;
import opt;
import std::io, std::io::file;

const CREATE_HELP = `usage: ktx create [options] -o <output.ktx2> <input.png|jpg> [more inputs]

Creates a KTX2 texture. Multiple inputs become array layers, or the six
faces (+X -X +Y -Y +Z -Z) of a cubemap with --cube.

options:
  -f, --format <name>   target format (see 'ktx formats'), default rgba8-srgb
                        'etc1s'/'uastc' (+ '-linear') use basis_universal
  -m, --mipmap          generate a full mip chain
  -n, --normal-map      inputs are normal maps: mips are renormalized
                        (pairs well with --format bc5)
  -c, --cube            treat exactly 6 inputs as cubemap faces
      --quality <0-100> etc1s/uastc encode quality (default 90)
      --effort <0-10>   etc1s/uastc encode effort (default 2)
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
	int quality = 90;
	int effort = 2;

	int? end = opt::@parse(args,
		"f", "format", &format_name,
		"m", "mipmap", &mipmap,
		"n", "normal-map", &normal_map,
		"c", "cube", &cube,
		null, "quality", &quality,
		null, "effort", &effort,
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

	// ETC1S/UASTC + BasisLZ is produced by basis_universal, which builds the whole
	// KTX2 (encode + container + supercompression) itself, so it bypasses the
	// VkFormat per-level pipeline below.
	uint bfmt;
	bool bsrgb;
	if (codec::is_basis_format(format_name, &bfmt, &bsrgb))
	{
		basis::TexType type = cube
			? basis::TexType.CUBE
			: (inputs.len > 1 ? basis::TexType.ARRAY : basis::TexType.D2);
		basis::EncodeOptions opts = { .quality = quality, .effort = effort, .srgb = bsrgb, .mipmaps = mipmap };
		if (catch err = create_basis(inputs, output, format_name, bfmt, type, opts))
		{
			io::eprintfn("error: %s", err);
			return 1;
		}
		return 0;
	}

	uint? format = codec::parse_format(format_name);
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
			char[] encoded = codec::encode_image(tmem, format, rgba, lw, lh)!;
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

<* Encode one or more images to an ETC1S/UASTC + BasisLZ KTX2 via basis_universal. *>
fn void? create_basis(String[] inputs, String output, String format_name, uint fmt, basis::TexType type, basis::EncodeOptions opts) @local => @pool()
{
	// Load every input up front and check they agree on dimensions.
	image::Image[] images = alloc::new_array(tmem, image::Image, inputs.len);
	char[][] pixels = alloc::new_array(tmem, char[], inputs.len);
	foreach (i, path : inputs)
	{
		images[i] = load_image(tmem, path)!;
		if (images[i].width != images[0].width || images[i].height != images[0].height)
		{
			io::eprintfn("input %s is %dx%d, expected %dx%d",
				path, images[i].width, images[i].height, images[0].width, images[0].height);
			return INPUT_MISMATCH~;
		}
		pixels[i] = images[i].pixels;
	}

	uint w = images[0].width;
	uint h = images[0].height;
	char[] ktx2 = basis::encode(tmem, fmt, pixels, w, h, type, opts)!;
	file::save(output, ktx2)!;

	String scheme = fmt == basis::UASTC_4X4 ? "Zstd" : "BasisLZ";
	String shape;
	switch (type)
	{
		case CUBE:  shape = "cubemap (6 faces)";
		case ARRAY: shape = "array";
		default:    shape = "2D";
	}
	io::printfn("wrote %s: %s + %s %dx%d, %s%s", output, format_name, scheme, w, h,
		opts.mipmaps ? "mipmapped " : "", shape);
}
