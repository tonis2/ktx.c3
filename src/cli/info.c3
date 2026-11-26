// `ktx info` — dump the header, level index, DFD summary and metadata.
module ktx::cli;
import ktx::container, ktx::vk, ktx::dfd;
import std::io, std::io::file;

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
	container::FileInfo? described = container::describe(tmem, data);
	if (catch err = described)
	{
		io::eprintn("not a KTX2 file");
		return err~;
	}
	container::FileInfo info = described;

	io::printfn("%s: %d bytes", path, info.file_size);
	io::printfn("  vkFormat:          %s (%d)", vk::name(info.vk_format), info.vk_format);
	io::printfn("  typeSize:          %d", info.type_size);
	io::printfn("  dimensions:        %d x %d x %d", info.width, info.height, info.depth);
	io::printfn("  layers:            %d", info.layer_count);
	io::printfn("  faces:             %d", info.face_count);
	io::printfn("  levels:            %d%s", info.level_count, info.level_count == 0 ? " (generate at load)" : "");
	io::printfn("  supercompression:  %s (%d)", container::scheme_name(info.scheme), info.scheme);

	io::printn("  level index:");
	foreach (l, level : info.levels)
	{
		io::printfn("    level %d: offset %d, %d bytes (%d uncompressed)", l, level.offset, level.length, level.uncompressed);
	}

	switch (info.dfd_status)
	{
		case PARSED:
			dfd::Info d = info.dfd;
			io::printfn("  DFD:               model %s, transfer %s, block %dx%dx%d, bytesPlane0 %d, %d sample%s",
				dfd::model_name(d.model),
				d.transfer == dfd::TRANSFER_SRGB ? "sRGB" : "linear",
				d.block_w, d.block_h, d.block_d,
				d.bytes_plane0, d.sample_count, d.sample_count == 1 ? "" : "s");
		case BAD:
			io::printn("  DFD:               (malformed)");
		case MISSING:
			io::printn("  DFD:               (missing)");
	}

	if (!info.kv.len) return;
	io::printn("  metadata:");
	foreach (&pair : info.kv)
	{
		if (try text = pair.text())
		{
			io::printfn("    %s: %s", pair.key, text);
		}
		else
		{
			io::printfn("    %s: (%d bytes)", pair.key, pair.value.len);
		}
	}
}
