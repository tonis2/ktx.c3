# Plan: pure-C3 ETC1S + UASTC (replacing basis_universal)

Goal: implement UASTC 4x4 LDR and ETC1S/BasisLZ encode + decode in C3 so
`libbasisu.a` / `basisu.lib` and the C++ runtime disappear from the library.
zstd is NOT rewritten — it stays a vendored C static library (pure C, no
runtime deps, trivial to cross-compile; it replaces the copy currently
smuggled in via basisu).

End state:
- `manifest.json` links `zstd` instead of `basisu`; the `-lc++`/`-lstdc++`
  link-args go away.
- `ktx.{so,dylib,dll}` shrinks from ~5 MB to well under 1 MB.
- The public `ktx::basis` API (`encode`, `transcode`, `info`) and the C API
  in `src/capi` keep their exact signatures — CLI, tests, and the Blender
  addon don't change.
- Everything validates against the official `ktx` tool and interops with
  official basisu (they decode our files, we decode theirs).

Estimated size: ~9–12k lines of C3 across phases 1–5 (calibration: bc7.c3 is
1.4k). Phases are ordered so every stage has an oracle to test against, and
the library stays shippable after each phase — basisu is only removed at the
very end.

New modules (flat files in `src/ktx/`, matching the existing layout):

| file | contents |
|---|---|
| `bits.c3` | bit reader/writer over byte slices |
| `huffman.c3` | canonical Huffman: table build, decode, encode |
| `uastc.c3` | UASTC block decode + encode |
| `etc1s.c3` | ETC1S block decode + encode, VQ frontend |
| `basislz.c3` | BasisLZ global-codebook (de)serialization, slice coding |

`basis.c3` keeps its API and becomes the seam: it forwards to the C3
implementation once a phase lands, falling back to the basisu FFI for the
parts not yet written.

---

## Phase 0 — scaffolding and oracles (~3–5 days)

Everything later is diffed against references, so build the harness first,
while basisu is still linked.

- [x] Create a small committed test corpus in `test/images/`: 4–6 crops
      (e.g. 64x64 / 128x128) from `basis_universal/test_files` kodim set —
      one smooth-gradient, one high-detail, one with alpha, one normal-map.
      Small enough to commit, varied enough to catch codec regressions.
- [x] `test/gen-golden.sh`: with the CURRENT basisu-backed build, encode the
      corpus at a settings matrix (etc1s/uastc × quality 10/50/90 × mips
      on/off) into `test/golden/` (gitignored), and dump each one's RGBA32
      transcode as `.bin` next to it. These are the decode oracles.
- [x] Add a PSNR helper to the test utils (RGBA in, dB out) for encoder
      quality tracking.
- [x] `src/ktx/bits.c3`: bit reader/writer + tests (aligned/unaligned reads,
      64-bit spans, write-then-read round trips).
- [x] `src/ktx/huffman.c3`: canonical Huffman decode AND encode (code-length
      assignment, the basis size limits) + round-trip tests. Both later
      phases consume this.

Exit criteria: golden corpus generates reproducibly; bits/huffman tests pass.

## Phase 1 — UASTC decode (~1–2 weeks, ~2k lines)

Spec: Binomial's UASTC spec (in the basis_universal repo) + KTX2 spec.
Fully deterministic, so "done" = bit-exact.

- [x] Mode tables: the 19 LDR modes (+ void-extent), endpoint/weight ranges,
      subset counts, CEM values.
- [x] BISE/trit/quint unquantization tables for endpoints and weights.
- [x] ASTC partition-pattern function for the 2/3-subset modes (UASTC uses
      a fixed small set of seeds — table them, don't port the full hash).
- [x] Block decode: header parse → endpoints → weights → interpolate →
      4x4 RGBA. Include void-extent and the blue-contract/decode quirks the
      spec calls out.
- [x] KTX2 path: level data → zstd decompress (existing `zstd.c3`) →
      per-block decode → image. Wire as the `TF_RGBA32` branch for UASTC in
      `basis.c3` (C3 first, basisu for everything else).
- [x] Differential test: decode every UASTC golden bit-exactly equal to the
      recorded basisu RGBA32 dump.

Exit criteria: bit-exact on the whole golden matrix; `basis_test.c3` +
capi smoke test still green.

## Phase 2 — ETC1S/BasisLZ decode (~1–2 weeks, ~1.5k lines)

Spec: "ETC1S global data" + slice format in the KTX2 spec appendix (Khronos
required full documentation — it is all there).

- [x] ETC1S block decode: 5-bit base color, 3-bit intensity table index,
      2-bit selectors → RGBA (ETC1 differential subset only).
- [x] Parse `supercompressionGlobalData`: endpoint codebook, selector
      codebook, Huffman code-length tables.
- [x] Slice decode: Huffman-coded endpoint/selector indices with the
      delta/repeat (RLE) prediction scheme → block stream.
- [x] Alpha: RGBA files carry a second (alpha) slice per image — decode and
      merge.
- [x] Wire as the ETC1S `TF_RGBA32` branch in `basis.c3`.
- [x] Differential test: bit-exact vs the ETC1S golden RGBA dumps.

Exit criteria: bit-exact on the golden matrix. Decode of ANY basis file is
now pure C3.

## Phase 3 — BCn transcode targets without basisu (~2–3 days)

- [x] Route `TF_BC1/BC3/BC7` through: C3 decode (phases 1–2) → existing
      `bcn.c3`/`bc7.c3` encoders. Correct output, slower than basisu's
      block-level transcoders — fine, and it removes the last *decode-side*
      basisu dependency.
- [x] Compare quality (PSNR) against basisu's direct transcode on the
      corpus; record the numbers in the test output.
- [ ] (Later, optional) dedicated UASTC→BC7 block mapper if transcode speed
      ever matters; UASTC was designed for it.

Exit criteria: all `bt_*` externs unused; transcode tests green.

## Phase 4 — UASTC encode (~2–3 weeks, ~2.5–3k lines)

Compliance is binary (official tools must read it); quality is a dial we
track with PSNR/size tables.

- [x] Pick the starter mode set (what basisu uses at low pack levels:
      void-extent, mode 8, plus ~4–6 workhorse modes covering 1-subset RGB,
      RGBA, and 2-subset). → basisu's Faster set: modes 0/4/6 (RGB), 9/11/12
      (RGBA), 15/17 (LA) + solid; effort maps to pack level like the wasm API,
      level 0 restricts to the Fastest subset.
- [x] Per-mode trial encode: PCA/least-squares endpoint fit, weight
      quantization, pick lowest-MSE mode per block. (Exact reconstruction
      through the decoder's own unquant/interpolate for weight choice + MSE;
      encode_block asserts pack→decode reproduces the trial error.)
- [x] Encode path: blocks → KTX2 level data → zstd supercompress (existing
      writer in `container.c3`), mips via `mipgen.c3`, sRGB/linear DFD via
      `dfd.c3`. (DFD byte-identical to basisu's; `create --ffi` keeps
      gen-golden.sh's oracles on the basisu encoder.)
- [x] Interop gate: `ktx validate` clean (v4.4.0, incl. mips/cube/array);
      official basisu transcodes our files bit-identically to our decoder
      (asserted per level in test/basis_enc_test.c3); phase-1 decoder
      round-trips bit-exact.
- [x] Quality gate on the corpus vs basisu at q90/e2: PSNR within ~1 dB,
      file size within ~25% (no RDO yet — sizes WILL be bigger; record the
      gap, don't block on it). → C3 beats basisu's PSNR on all 5 corpus
      images (+0.1 to +10.5 dB); sizes within ±7% except the smooth gradient
      (+~2x — that's basisu's RDO trading PSNR for size on smooth content).
      Transcode hints are written as zeros (except solid blocks, where the
      authoritative ETC1 hint is computed) — quality-only cost on ETC1/EAC
      transcode targets.
- [ ] Thread per-block encoding (embarrassingly parallel) once correct.
- [x] Swap `basis.c3` UASTC encode to C3.
- [ ] (Later, optional) RDO pass for zstd-friendlier blocks to close the
      size gap.

Exit criteria: addon/CLI produce valid UASTC KTX2 with no basisu encoder
involvement.

## Phase 5 — ETC1S encode (~3–5 weeks, ~3.5–4.5k lines) — the hard one

Working first, competitive later. Ship correctness, then iterate quality.

- [x] ETC1S single-block encoder: best base color + intensity index +
      selectors for a 4x4 block (exhaustive over intensity tables, fast
      color fit). (Generalized to arbitrary pixel sets for cluster refits.)
- [x] Frontend v1: k-means endpoint clustering + selector clustering to
      fixed-size codebooks (quality 0–100 → codebook size mapping copied
      from basisu's curve). (Deterministic quantile seeding + Lloyd
      iterations, per-cluster refits, exact per-block selector reassignment,
      unused-entry pruning, delta-friendly codebook ordering.)
- [x] Backend: serialize codebooks + Huffman tables + delta/RLE index
      streams into spec-conformant global data + slices (mirror of phase 2 —
      reuse its tables/structs). (Endpoint deltas with the 3 context models,
      selector palette raw or XOR-delta-coded — whichever is smaller —
      left/upper/upper-left predictors, pred-symbol repeat runs, selector
      history buffer with RLE; encode→decode round-trip unit-tested incl.
      1x1..5x5 slices.)
- [x] Alpha slice support. (Alpha encoded as ETC1S gray in a second slice
      per image, shared codebooks, per the format.)
- [x] Interop gate: `ktx validate` clean (v4.4.0 incl. mips/cube); official
      basisu decodes our files bit-identically to our decoder (asserted per
      level in test/basis_enc_test.c3); our phase-2 decoder round-trips.
- [x] Quality tracking table on the corpus: size + PSNR, ours vs basisu at
      q10/50/90. First pass will lose — the table makes the gap visible and
      every tuning commit measurable. → q10: PSNR −1.7..+1.9 dB, size −4..+10%;
      q90: PSNR −0.7..+0.7 dB, size +6..+32% (worst on the tiny gradient
      image where we are also +0.7 dB ahead). capi etc1s mad improved from
      2.43 (basisu) to 2.17.
- [ ] Iterate frontend (cluster refinement passes, better seeding) until
      size-at-quality is within ~15% of basisu, or consciously accept the
      gap. (q10/q50 are within; q90 runs +6..32% — cluster-merge iteration
      still to do.)

Exit criteria: interop gates pass; quality gap known and documented.

## Phase 6 — cutover (~1 week)

- [x] CI: new `build-zstd.sh` + workflow job producing `libzstd.a` /
      `zstd.lib` per platform from the zstd release amalgamation (pure C —
      this is build-basisu.sh minus all the pain). Commit per-platform libs
      like today's basisu ones (a fraction of the size). (zstd 1.5.7 pinned,
      compiled directly — no cmake; macos-aarch64 built locally at 604K vs
      libbasisu's 5.5M; other platforms come from
      `.github/workflows/zstd.yml` on the next CI run.)
- [x] `manifest.json`: `linked-libraries: ["zstd"]`, drop `basisu` and the
      `-lc++`/`-lstdc++`/`-lm`/`-lpthread` C++ baggage per target.
- [x] Delete `basis.c3` FFI externs; delete basisu fetch/build from
      `build-basisu.sh` and the workflow (keep the zstd job). (basis.c3 is
      pure C3 now — `info` parses the header directly, `transcode` faults on
      unsupported targets; the CLI `--ffi` flags are gone; gen-golden.sh is
      frozen with a pre-cutover-binary guard; the FFI-based test gates were
      migrated to golden-file-calibrated ones first and stayed green through
      the cut.)
- [x] Full test suite + `cross-validate.sh` + capi smoke on all platforms.
      (Green on macos-aarch64: 95 tests, cross-validate incl. etc1s/uastc,
      capi smoke on the zstd-linked ktx.dylib — 933K, down from 4.9M. Other
      platforms verified by the CI workflow's smoke step.)
- [ ] Tag a release: assets shrink to the new small `ktx-<triple>.*` — no
      addon changes needed (same C ABI). (Ready — tag after the CI matrix
      has produced the per-platform libzstd/ktx artifacts.)
- [x] Update README (bundling section, size table) and delete this file's
      basisu references… by deleting basisu.

---

## Standing rules

- Never remove a basisu path before its C3 replacement passes the
  differential tests — `basis.c3` switches per-format, per-direction.
- Decode phases are done when BIT-EXACT. Encode phases are done when
  INTEROPERABLE + VALIDATED; quality is tracked, not gated (except the
  phase-4 PSNR sanity check).
- Every phase leaves `main` shippable.
- Rough overall: phases 0–3 ≈ a month → all decoding is pure C3.
  Phases 4–5 ≈ 5–8 weeks → encoding too. Phase 6 ≈ days.
