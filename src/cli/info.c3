// `ktx info` — dump the header, level index, DFD summary and metadata.
module ktx::cli;
import ktx::container, ktx::vk, ktx::dfd, ktx::util;
import std::io, std::io::file;
import std::core::ascii;

const INFO_HELP = `usage: ktx info <file.ktx2>`;

fn int cmd_info(String[] args)
{
	if (args.len != 2 || args[1] == "-h" || args[1] == "--help")
	{
		io::printn(INFO_HELP);
		return args.len != 2 ? 1 : 0;
	}
	if (catch err = print_info(args[1]))
	{
		io::eprintfn("error: %s", err);
		return 1;
	}
	return 0;
}

fn void? print_info(String path) @local => @pool()
{
	char[] data = file::load(tmem, path)!;
	if (data.len < container::HEADER_SIZE || data[:12] != container::IDENTIFIER[..])
	{
		io::eprintn("not a KTX2 file");
		return container::BAD_IDENTIFIER~;
	}

	uint format = util::rd32(data, 12);
	uint levels = max(util::rd32(data, 40), 1u);
	uint scheme = util::rd32(data, 44);
	String scheme_name;
	switch (scheme)
	{
		case 0: scheme_name = "none";
		case 1: scheme_name = "BasisLZ";
		case 2: scheme_name = "Zstandard";
		case 3: scheme_name = "ZLIB";
		default: scheme_name = "unknown";
	}

	io::printfn("%s: %d bytes", path, data.len);
	io::printfn("  vkFormat:          %s (%d)", vk::name(format), format);
	io::printfn("  typeSize:          %d", util::rd32(data, 16));
	io::printfn("  dimensions:        %d x %d x %d", util::rd32(data, 20),
		util::rd32(data, 24), util::rd32(data, 28));
	io::printfn("  layers:            %d", util::rd32(data, 32));
	io::printfn("  faces:             %d", util::rd32(data, 36));
	io::printfn("  levels:            %d%s", util::rd32(data, 40),
		util::rd32(data, 40) == 0 ? " (generate at load)" : "");
	io::printfn("  supercompression:  %s (%d)", scheme_name, scheme);

	io::printn("  level index:");
	for (uint l = 0; l < levels; ++l)
	{
		sz at = container::HEADER_SIZE + l * container::LEVEL_ENTRY_SIZE;
		if (at + container::LEVEL_ENTRY_SIZE > data.len) break;
		io::printfn("    level %d: offset %d, %d bytes (%d uncompressed)",
			l, util::rd64(data, at), util::rd64(data, at + 8), util::rd64(data, at + 16));
	}

	uint dfd_off = util::rd32(data, 48);
	uint dfd_len = util::rd32(data, 52);
	if (dfd_len && (sz)dfd_off + dfd_len <= data.len)
	{
		dfd::Info? info = dfd::parse(data[dfd_off:dfd_len]);
		if (try info)
		{
			io::printfn("  DFD:               model %s, transfer %s, block %dx%dx%d, bytesPlane0 %d, %d sample%s",
				dfd::model_name(info.model),
				info.transfer == dfd::TRANSFER_SRGB ? "sRGB" : "linear",
				info.block_w, info.block_h, info.block_d,
				info.bytes_plane0, info.sample_count, info.sample_count == 1 ? "" : "s");
		}
		else
		{
			io::printn("  DFD:               (malformed)");
		}
	}
	else
	{
		io::printn("  DFD:               (missing)");
	}

	// Reuse the container reader for metadata (it inflates levels too, but
	// files are small enough that simplicity wins here).
	container::Texture? tex = container::read(tmem, data);
	if (try tex && tex.kv.len)
	{
		io::printn("  metadata:");
		foreach (pair : tex.kv)
		{
			bool printable = pair.value.len > 0;
			foreach (c : pair.value[:pair.value.len - 1])
			{
				if (!ascii::is_print(c))
				{
					printable = false;
					break;
				}
			}
			if (printable && pair.value[^1] == 0)
			{
				io::printfn("    %s: %s", pair.key, (String)pair.value[:pair.value.len - 1]);
			}
			else
			{
				io::printfn("    %s: (%d bytes)", pair.key, pair.value.len);
			}
		}
	}
}
