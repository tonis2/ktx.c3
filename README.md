# ktx.c3

KTX2 texture encoding/decoding in pure C3 — a game-development-focused port
of [KTX-Software](https://github.com/KhronosGroup/KTX-Software) for
Vulkan-based engines and asset pipelines.

## What it does

- **KTX2 container** read + write, byte-accurate to the Khronos spec
  (header, level index, DFD, key/value metadata, mip padding, level ordering).
  Output validates clean against the official `ktx validate`.
- **Supercompression:** Zstandard and ZLIB (pure C3, stdlib deflate) for
  GPU-ready BCn. **ETC1S + BasisLZ** and **UASTC 4x4 + Zstd** encode (2D, mip
  chains, array layers, cubemaps) plus transcoding to BC7/BC1/ETC2/ASTC are
  provided by bundled `basis_universal` (see below) for small downloads and
  mobile-GPU portability.
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
c3c build                                 # links bundled libbasisu.a (no system libzstd needed)

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

The manifest links the bundled `libbasisu` (which supplies zstd and the
ETC1S/UASTC codec) plus a C++ runtime for you, so a consumer builds out of the
box with no system `libzstd`. Then:

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

No system `libzstd` is needed: the bundled `basis_universal` static lib
(`<target>/libbasisu.a`) provides both zstd and the ETC1S/BasisLZ codec, and the
manifest links it plus a C++ runtime per platform.

## Tests

```sh
c3c test                 # unit tests: round-trips, KATs, alignment, DFD bytes
sh test/cross-validate.sh   # optional: validates output with the official ktx tool
sh test/gen-golden.sh       # regenerate the basis decode oracles in test/golden/
```

`test/images/` holds a small committed corpus (smooth gradient, high-detail,
alpha, normal map — 64x64 each). `test/gen-golden.sh` encodes it across an
ETC1S/UASTC × quality × mips matrix with the basisu-backed build and records
every level's RGBA32 transcode; the in-progress pure-C3 basis codec
(see `docs/basis-rewrite.md`) is diffed bit-exactly against those dumps.

Cross-checks performed during development: all written files pass official
`ktx validate` with zero warnings; files created by the official `ktx create`
read back pixel-exact; BCn/BC7 decoders verified bit-identical against
basis_universal's unpackers.

## ETC1S / UASTC + BasisLZ (via basis_universal)

> A pure-C3 replacement for basis_universal (decode first, then encode) is in
> progress — see `docs/basis-rewrite.md` for the plan and current status.
> Landed so far (phases 0–3): the golden-oracle test harness, `ktx::bits`
> (LSB-first bit I/O), `ktx::huffman` (canonical Huffman, basisu-format
> tables), `ktx::uastc` and `ktx::etc1s` — **all ETC1S/UASTC decoding is now
> pure C3**: RGBA32 transcodes are bit-exact against the basisu transcoder on
> the golden corpus (all 19 UASTC modes, BasisLZ codebooks/slices incl.
> alpha), and BC1/BC3/BC7 targets go through the library's own BCn encoders
> (better PSNR than basisu's fast transcode on BC7, within ~2 dB on BC1/BC3).
> `extract`, the C API and `basis::transcode` use the C3 paths automatically;
> `extract --ffi` forces basisu (how `test/gen-golden.sh` keeps its oracles
> honest). Encoding still uses bundled basisu until phases 4–5 land.

ETC1S and UASTC 4x4 encoding plus BasisLZ/Zstd transcoding are provided by
[basis_universal](https://github.com/BinomialLLC/basis_universal), linked as a
prebuilt static lib (`<target>/libbasisu.a`) and bound in `src/ktx/basis.c3`:

```sh
# ETC1S + BasisLZ: smallest downloads, codebook-based
build/ktx create --format etc1s -o albedo.ktx2 albedo.png

# UASTC 4x4 + Zstd: higher quality, transcodes to BC7/ASTC near-losslessly
build/ktx create --format uastc --quality 95 --effort 4 -o albedo.ktx2 albedo.png

# non-color data (normals, masks) uses the linear variants
build/ktx create --format uastc-linear -o normal.ktx2 normal.png

# mip chains, array layers (N inputs), and cubemaps (--cube, 6 faces) all work
build/ktx create --format etc1s --mipmap -o albedo.ktx2 albedo.png
build/ktx create --format etc1s -o layers.ktx2 l0.png l1.png l2.png
build/ktx create --cube --format uastc -o env.ktx2 px.png nx.png py.png ny.png pz.png nz.png

build/ktx info albedo.ktx2          # reports scheme + DFD model (ETC1S / UASTC)
build/ktx extract -o out.png albedo.ktx2                  # transcode -> RGBA -> PNG
build/ktx extract --level 1 --face 2 -o f.png env.ktx2    # a specific level/layer/face
```

`--quality` (0–100) and `--effort` (0–10) tune the encoder: for ETC1S they map
to codebook size and compression level; for UASTC to the RDO quality and packing
level (quality 100 = no RDO). Both default to `--quality 90 --effort 2`.

basis_universal is C++, so the final binary links a C++ runtime (handled by the
manifest). Its bundled zstd also serves the container's Zstd path, so **no system
libzstd is needed**. The static libs are prebuilt and bundled per platform, so
this works out of the box. basis_universal itself is *not* vendored; to rebuild
the libs from source (only needed to bump basis or add a platform), run the build
script — it fetches basis at a pinned commit into `native/` (gitignored):

```sh
native/build-basisu.sh    # -> <target>/libbasisu.a
```

CI builds every platform this way via `.github/workflows/build-basisu.yml`.

## Releases: prebuilt shared libraries for FFI

`native/build-shared.sh` also builds libktx as a shared library
(`<target>/ktx.{so,dylib,dll}`, C API in `src/capi`) for non-C3 consumers
loading it via FFI — e.g. the Blender glTF addon, which decodes/encodes KTX2
through ctypes. These shared libs are **not** committed; pushing a `v*` tag
runs `.github/workflows/release.yml`, which rebuilds every platform and
attaches the libs to the tag's GitHub release as raw files (no archives),
named per target:

```
ktx-macos-aarch64.dylib   ktx-macos-x64.dylib
ktx-linux-x64.so          ktx-windows-x64.dll   ktx-windows-x64.lib
libbasisu-<triple>.a      basisu-windows-x64.lib
```

so a consumer can fetch exactly one file, e.g.
`https://github.com/tonis2/ktx.c3/releases/latest/download/ktx-macos-aarch64.dylib`.