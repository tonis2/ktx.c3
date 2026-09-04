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
  chains, array layers, cubemaps) plus transcoding to RGBA32/BC1/BC3/BC7 —
  implemented in pure C3 (see below) for small downloads and mobile-GPU
  portability.
- **GPU block compression, encoders + decoders in pure C3:**
  - **BC1, BC3, BC4, BC5** — decoders bit-identical to the basis_universal
    reference; encoders use bbox + least-squares refinement (stb_dxt approach).
  - **BC7** (modes 1/5/6 encode, all 8 modes decode) — cross-validated
    byte-for-byte against basis_universal on thousands of blocks.
- **Mipmap generation:** box filter, sRGB-correct (filters in linear space),
  optional renormalization for normal maps.
- **Multithreaded encoding and decoding** (`std::thread`, no extra
  dependencies): block encoders and decoders and the ETC1S clustering fan out
  across all cores by default, with byte-identical output at any thread count.
  1024x1024 on a 10-core machine: ETC1S 169s→33s, BC7 21s→3.5s, UASTC 3.6s→1.0s
  encoding; on a 16-core machine, BC7 decode 5.9ms→1.1ms and BC3 1.7ms→0.5ms.
- **CLI** built on `getopt.c3l`, images in/out via `image.c3l` (PNG/JPEG).

## CLI

```sh
git submodule update --init --recursive   # fetch getopt.c3l + image.c3l
c3c build                                 # links bundled libzstd.a (no system libzstd needed)

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

The manifest links the bundled `libzstd` for you — the ETC1S/UASTC codec is
pure C3 — so a consumer builds out of the box with no system `libzstd` and no
C++ runtime. Then:

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

No system `libzstd` is needed: a prebuilt `libzstd.a` is bundled per platform
(`lib/<target>/libzstd.a`, built by `native/build-zstd.sh`) and the manifest
links it — the only native code in the library.

## Tests

```sh
c3c test                 # unit tests: round-trips, KATs, alignment, DFD bytes
sh test/cross-validate.sh   # optional: validates output with the official ktx tool
sh test/gen-golden.sh       # regenerate the basis decode oracles in test/golden/
```

`test/images/` holds a small committed corpus (smooth gradient, high-detail,
alpha, normal map — 64x64 each). `test/gen-golden.sh` encoded it across an
ETC1S/UASTC × quality × mips matrix with basis_universal and recorded every
level's RGBA32 transcode plus the raw source pixels; the pure-C3 basis codec
(see `docs/basis-rewrite.md`) is diffed bit-exactly against those dumps, and
the C3 encoders' PSNR/size is gated against the recorded basisu files. The
script is frozen: it needs a `ktx` binary from the last pre-cutover revision
(basisu is no longer linked), but the golden files it produced remain valid
oracles for today's code. `cross-validate.sh` picks up the official tool from
`$PATH` or a prebuilt KTX-Software release unpacked into `native/ktxtools/`.

Cross-checks performed during development: all written files pass official
`ktx validate` with zero warnings; files created by the official `ktx create`
read back pixel-exact; BCn/BC7 decoders verified bit-identical against
basis_universal's unpackers.

## ETC1S / UASTC + BasisLZ

> The pure-C3 rewrite of basis_universal is complete (`docs/basis-rewrite.md`,
> phases 0–6): codecs, container assembly and Zstd linkage no longer involve
> basisu at all. How it was proven, while basisu was still linked: decoding is
> bit-exact against the basisu transcoder on a recorded golden corpus (all 19
> UASTC modes, BasisLZ codebooks/slices incl. alpha), and basisu's transcoder
> decoded C3-encoded files bit-identically to ours across every format, shape
> and mip level. Quality vs basisu at q90/e2: UASTC beats basisu's PSNR on the
> whole corpus (no RDO — smooth-content files run larger, ~2x worst case;
> ETC1/EAC transcode hints are zeroed except solid blocks); ETC1S is within
> ~0.7 dB (ahead on some images), sizes −4..+10% at q10 and +6..32% at q90
> (frontend iteration ongoing). Everything passes official `ktx validate`.

All ETC1S/UASTC encoding and decoding is pure C3 (`src/ktx/{uastc,etc1s}.c3`,
assembled into KTX2 by `src/ktx/basis.c3`) — no
[basis_universal](https://github.com/BinomialLLC/basis_universal) is linked;
its recorded output remains the test oracle (see Tests):

```sh
# ETC1S + BasisLZ: smallest downloads, codebook-based
build/ktx create --format etc1s -o albedo.ktx2 albedo.png

# UASTC 4x4 + Zstd: higher quality, transcodes to BC7 near-losslessly
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

`--quality` (0–100) and `--effort` (0–10) tune the encoder: for ETC1S
`--quality` sets the codebook-size targets (following basisu's quality curve;
`--effort` currently has no effect there); for UASTC `--effort` picks the
packing level (mode-set size) while `--quality` has no effect (it tuned
basisu's RDO, which the C3 encoder doesn't do yet). Both default to
`--quality 90 --effort 2`.

Encoding and decoding both use every core by default (`ktx::parallel`, a small
fork-join helper over `std::thread`): UASTC/BC7/BCn encode *and* decode block
rows in parallel and the ETC1S k-means/reassignment searches are parallel too.
Only the searches run concurrently — order-sensitive accumulation stays serial —
so **output is byte-identical for any thread count**. Library callers can pass
`threads: 1` (any of `uastc::encode_image`, `etc1s::encode`, `bc7::encode`,
`bcn::encode`, `uastc::decode_image`, `bc7::decode`, `bcn::decode`) to force
single-threaded operation.

The decoders are cheap enough per block that spawning a thread can cost more
than the work, so their automatic thread count is capped by the size of the job
(`parallel::shares`): a small texture decodes inline rather than being made
slower by the split. An explicit `threads` is always obeyed. ETC1S is the one
payload that stays serial on the way in — its slices are a single Huffman
bitstream with cross-block endpoint prediction, so there is nothing to split.

Transcode targets are RGBA32, BC1, BC3 and BC7 (BCn via the library's own
encoders). The only native dependency is zstd — prebuilt per platform as
`lib/<target>/libzstd.a`, so this works out of the box with **no system libzstd
and no C++ runtime**. zstd is *not* vendored; to rebuild the lib (only needed
to bump zstd or add a platform), run the build script — it fetches the pinned
release into `native/` (gitignored):

```sh
native/build-zstd.sh    # -> lib/<target>/libzstd.a
```

CI builds every platform this way via `.github/workflows/build-zstd.yml`.

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
libzstd-<triple>.a        zstd-windows-x64.lib
ktx-cli-<triple>          ktx-cli-windows-x64.exe
```

so a consumer can fetch exactly one file, e.g.
`https://github.com/tonis2/ktx.c3/releases/latest/download/ktx-macos-aarch64.dylib`.

The `ktx-cli-*` assets are the standalone CLI — download one, `chmod +x` it
(macOS/Linux) and run `ktx-cli-<triple> create/extract/info` directly, no
build needed.