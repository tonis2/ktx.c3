// ktx — KTX2 texture tool in C3.
//
// Create, inspect and extract KTX2 textures for Vulkan-based engines:
// BC1/BC3/BC4/BC5/BC7 encoding, mipmap generation, Zstd/ZLIB
// supercompression. Library modules live under ktx::* and can be used
// directly from other C3 projects (e.g. a glTF exporter).
module ktx_main;
import ktx::cli;
import std::io;

const USAGE = `ktx — KTX2 texture tool (C3)

usage: ktx <command> [options]

commands:
  create    build a .ktx2 from PNG/JPEG images (mipmaps, BCn, supercompression)
  extract   decode a level/layer/face back to PNG (or raw bytes)
  info      print header, level index, DFD and metadata
  formats   list encodable formats
  help      this help

run 'ktx <command> --help' for command options.`;

fn int main(String[] args)
{
	if (args.len < 2)
	{
		io::printn(USAGE);
		return 1;
	}
	switch (args[1])
	{
		case "create":  return cli::cmd_create(args[1..]);
		case "extract": return cli::cmd_extract(args[1..]);
		case "info":    return cli::cmd_info(args[1..]);
		case "formats":
			cli::print_formats();
			return 0;
		case "help":
		case "--help":
		case "-h":
			io::printn(USAGE);
			return 0;
		default:
			io::eprintfn("unknown command '%s'", args[1]);
			io::printn(USAGE);
			return 1;
	}
}
