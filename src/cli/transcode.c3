// `ktx transcode` — an ETC1S/UASTC KTX2 to a plain one in a format a GPU samples.
module ktx::cli;
import ktx::container, ktx::vk, ktx::basis, ktx::dfd, ktx::util;
import opt;
import std::io, std::io::file;

const TRANSCODE_HELP = `usage: ktx transcode -t <target> [options] -o <out.ktx2> <in.ktx2>

Transcodes every level, layer and face of an ETC1S or UASTC KTX2 into a plain
KTX2. The input's sRGB or linear transfer and its metadata carry over.

targets:
  astc       ASTC 4x4, for GPUs without BC7 (UASTC inputs only; lossless)
  bc7        BC7
  etc2       ETC2 RGB, or ETC2 RGBA when the input has alpha, for GPUs without
             BC7 (ETC1S inputs only; colour lossless, alpha fitted to EAC)
  etc2-rgba  ETC2 RGBA even for an opaque input (alpha 255)
  rgba8      uncompressed RGBA8

options:
  -t, --target <name>
      --zstd <level>    Zstd supercompression level 1..22 (default: 3)
      --raw             no supercompression
  -o, --output <path>   output file (required)
  -h, --help            this help`;

fn int cmd_transcode(String[] args)
{
	String target;
	String output;
	int zstd_level = 3;
	bool raw_flag;

	int? end = opt::@parse(args,
		"t", "target", &target,
		null, "zstd", &zstd_level,
		null, "raw", &raw_flag,
		"o", "output", &output,
		"h*", "help", null);
	if (catch err = end)
	{
		if (err == opt::HELP_REQUESTED)
		{
			io::printn(TRANSCODE_HELP);
			return 0;
		}
		io::eprintfn("error: bad arguments (%s)", err);
		return 1;
	}

	String[] inputs = args[end..];
	if (inputs.len != 1 || !output.len || !target.len)
	{
		io::eprintn("error: need -t <target>, exactly one input file and -o <output>");
		io::printn(TRANSCODE_HELP);
		return 1;
	}

	container::Scheme scheme = raw_flag ? container::Scheme.NONE : container::Scheme.ZSTD;
	if (catch err = transcode_file(inputs[0], output, target, scheme, zstd_level))
	{
		io::eprintfn("error: %s", err);
		return 1;
	}
	return 0;
}

fn void? transcode_file(String input, String output, String target, container::Scheme scheme, int zstd_level) @local => @pool()
{
	char[] data = file::load(tmem, input)!;
	basis::Info? bi = basis::info(data);
	if (catch bi)
	{
		io::eprintn("not an ETC1S or UASTC KTX2");
		return BAD_ARGUMENTS~;
	}

	dfd::Info df = dfd::parse(data[util::rd32(data, 48):util::rd32(data, 52)])!;
	bool srgb = df.transfer == dfd::TRANSFER_SRGB;
	uint tf;
	uint format;
	switch (target)
	{
		case "astc":
			tf = basis::TF_ASTC_4X4_RGBA;
			format = srgb ? vk::ASTC_4X4_SRGB : vk::ASTC_4X4_UNORM;
		case "bc7":
			tf = basis::TF_BC7_RGBA;
			format = srgb ? vk::BC7_SRGB : vk::BC7_UNORM;
		case "etc2":
			if (bi.alpha) nextcase "etc2-rgba";
			// Opaque ETC1S is ETC1, which Vulkan names as ETC2 RGB.
			tf = basis::TF_ETC1_RGB;
			format = srgb ? vk::ETC2_R8G8B8_SRGB : vk::ETC2_R8G8B8_UNORM;
		case "etc2-rgba":
			tf = basis::TF_ETC2_RGBA;
			format = srgb ? vk::ETC2_R8G8B8A8_SRGB : vk::ETC2_R8G8B8A8_UNORM;
		case "rgba8":
			tf = basis::TF_RGBA32;
			format = srgb ? vk::R8G8B8A8_SRGB : vk::R8G8B8A8_UNORM;
		default:
			io::eprintfn("unknown target '%s' (astc, bc7, etc2, etc2-rgba or rgba8)", target);
			return BAD_ARGUMENTS~;
	}
	if (tf == basis::TF_ASTC_4X4_RGBA && df.model != dfd::MODEL_UASTC)
	{
		io::eprintn("astc needs a UASTC input; ETC1S has no ASTC mapper");
		return BAD_ARGUMENTS~;
	}
	if ((tf == basis::TF_ETC1_RGB || tf == basis::TF_ETC2_RGBA) && df.model != dfd::MODEL_ETC1S)
	{
		io::eprintn("etc2 needs an ETC1S input; UASTC maps to astc instead");
		return BAD_ARGUMENTS~;
	}

	container::Texture tex = container::create(tmem, {
		.vk_format = format,
		.width = bi.width,
		.height = bi.height,
		.face_count = bi.faces,
		.layer_count = bi.layers,
		.level_count = bi.levels,
	})!;

	// ETC1S is BasisLZ, which `container::read` does not inflate; its metadata
	// stays behind.
	if (try source = container::read(tmem, data))
	{
		// Except the writer, which is this tool now.
		foreach (pair : source.kv)
		{
			if (pair.key != "KTXwriter") tex.kv_set(pair.key, pair.value);
		}
	}

	for (uint layer = 0; layer < max(bi.layers, 1u); layer++)
	{
		for (uint face = 0; face < bi.faces; face++)
		{
			basis::Transcoded[] levels = basis::transcode_levels(tmem, data, layer, face, tf)!;
			foreach (l, level : levels) tex.set_image((uint)l, layer, face, level.data)!;
		}
	}

	container::write_file(&tex, output, { .scheme = scheme, .zstd_level = zstd_level })!;
	io::printfn("wrote %s: %s %dx%d, %d level%s, %d layer(s), %d face(s)", output, vk::name(format),
		bi.width, bi.height, bi.levels, bi.levels == 1 ? "" : "s", max(bi.layers, 1u), bi.faces);
}
