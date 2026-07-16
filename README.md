# ktx.c3

KTX2 texture encoding/decoding in pure C3 — a game-development-focused port
of [KTX-Software](https://github.com/KhronosGroup/KTX-Software) for
Vulkan-based engines and asset pipelines.

## What it does

- **KTX2 container** read + write, byte-accurate to the Khronos spec
  (header, level index, DFD, key/value metadata, mip padding, level ordering).
  Output validates clean against the official `ktx validate`.
- **Supercompression:** Zstandard (via system `libzstd`) and ZLIB (pure C3,
  stdlib deflate). BasisLZ files are rejected by design — for a Vulkan engine,
  BCn + Zstd gives GPU-ready data without a transcode step.
- **GPU block compression, encoders + decoders in pure C3:**
  - **BC1, BC3, BC4, BC5** — decoders bit-identical to the basis_universal
    reference; encoders use bbox + least-squares refinement (stb_dxt approach).
  - **BC7** (modes 1/5/6 encode, all 8 modes decode) — cross-validated
    byte-for-byte against basis_universal on thousands of blocks.
- **Mipmap generation:** box filter, sRGB-correct (filters in linear space),
  optional renormalization for normal maps.
- **CLI** built on `getopt.c3l`, images in/out via `image.c3l` (PNG/JPEG).

## CLI

```sh
git submodule update --init --recursive   # fetch getopt.c3l + image.c3l
c3c build                                  # needs libzstd installed (brew install zstd)

# color texture: BC7 + full mip chain + Zstd (default) supercompression
build/ktx create --format bc7-srgb --mipmap -o albedo.ktx2 albedo.png

# normal map: BC5 two-channel, renormalized mips
build/ktx create --format bc5 --normal-map --mipmap -o normal.ktx2 normal.png

# cubemap from 6 faces (+X -X +Y -Y +Z -Z), array textures from N inputs
build/ktx create --cube --format bc7-srgb -o env.ktx2 px.png nx.png py.png ny.png pz.png nz.png

# inspect / decode back to PNG
build/ktx info albedo.ktx2
build/ktx extract --level 2 -o mip2.png albedo.ktx2
build/ktx formats            # list encodable formats
```

Supercompression defaults to `--zstd 3`; use `--zstd 18` for maximum
compression in shipping builds, `--raw` to disable.

## Format guidance for a Vulkan engine

| Use case            | Format          | Why                                        |
|---------------------|-----------------|--------------------------------------------|
| Albedo / color      | `bc7-srgb`      | Best LDR quality, 1 byte/px, alpha support |
| Normal maps         | `bc5`           | Two-channel XY, reconstruct Z in shader    |
| Masks / roughness   | `bc4`           | Single channel, 0.5 byte/px                |
| Grayscale+alpha     | `bc3`           | Legacy fallback                            |
| UI / exact pixels   | `rgba8-srgb`    | Uncompressed, still Zstd-supercompressed   |

## Using the library from another C3 project (e.g. a glTF exporter)

The `ktx::*` modules have no dependency on the CLI or on `image`/`getopt` —
they use only the standard library. This repo ships a `manifest.json`, so you
can add it as a normal C3 library dependency: drop it in a directory named
`ktx.c3l` on your `dependency-search-paths` (e.g. as a git submodule at
`lib/ktx.c3l`) and list `"ktx"` in your `dependencies`:

```json
"dependency-search-paths": [ "lib" ],
"dependencies": [ "ktx" ]
```

The manifest links `libzstd` for you (including Homebrew's path on macOS), then:

```c3
import ktx::container, ktx::vk, ktx::bc7, ktx::mipgen;

// encode RGBA8 pixels into a BC7+Zstd KTX2 blob for KHR_texture_basisu-style embedding
container::Texture tex = container::create(mem, {
    .vk_format = vk::BC7_SRGB, .width = w, .height = h, .level_count = levels })!;
tex.set_image(0, 0, 0, bc7::encode(mem, rgba, w, h)!)!;
char[] ktx2_bytes = container::write(mem, &tex, { .scheme = container::Scheme.ZSTD })!;
```

On the engine side, `container::read` hands back inflated, GPU-ready level
payloads (`tex.image(level, layer, face)`) to feed straight into
`vkCmdCopyBufferToImage`, `vk_format` matching `VkFormat` numerically.

You still need `libzstd` installed on the system (`brew install zstd`,
`apt install libzstd-dev`, etc.); the manifest handles the linker wiring.

## Tests

```sh
c3c test                 # 55 unit tests: round-trips, KATs, alignment, DFD bytes
sh test/cross-validate.sh   # optional: validates output with the official ktx tool
```

Cross-checks performed during development: all written files pass official
`ktx validate` with zero warnings; files created by the official `ktx create`
read back pixel-exact; BCn/BC7 decoders verified bit-identical against
basis_universal's unpackers.

## Scope / not implemented

- BasisLZ/ETC1S and UASTC transcoding (huge C++ dependency; out of scope)
- ASTC/ETC2 encoding (files with those formats can be read/inspected/extracted raw)
- KTX v1 files, BC6H encode (HDR pipeline), 16-bit PNG input

Ported from KTX-Software and basis_universal (both Apache-2.0).
