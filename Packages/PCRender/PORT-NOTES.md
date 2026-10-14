# PCRender — port notes

Port of **photocraft-compose** (`crates/compose/src/*.rs`) and **photocraft-gpu**
(`crates/gpu/src/{lib,plan,fx}.rs`, `compose.wgsl`) to Swift + Metal, photocraft revision
`184c226a` (2026-10-12). MIT OR Apache-2.0, © ArtCraft Team and the PhotoCraft contributors.
photocraft's maths is the spec. Metal structure and the display reduction chain take ideas from
**Compositor v1.5** (MIT, © 2026 Wonder Assembly LLC; credited in `Display/CanvasRenderer.swift`
and `Shaders/PCR7Display.metal`, the only adapted code).

Status: phases 1–5 complete. `swift build` / `swift test` clean (no warnings), **194 tests in 22
suites** (18 need Photoshop's measurement batches: `PCRENDER_M1_DIR` / `PCRENDER_M2_DIR` /
`PCRENDER_M3_DIR`, default `$PHOTOCRAFT_FIXTURES/ps-measure/M1|M2|M3`, skipped when absent; the
fixtures root is resolved in `Tests/PCRenderTests/Fixtures.swift`; 4 known issues: Light's
Highlights / Shadows, which are local in Photoshop): 52 kernel
/ op / display tests (phase 1), the end-to-end document tests (phases 2–5) and the Photoshop
function-oracle fits (phases 4–5); every document rendered by the CPU reference **and** Metal with a
parity check.

## Architecture

```
PCDocument ──DocumentPlanner──▶ RenderPlan (DrawOp stack program) + DocumentRenderSource (leaves)
                                     │                                   │
                       CPUCompositor (256² tiles, parallel)      MetalCompositor (page cells,
                       = the correctness oracle                   compute kernels, residency)
                                     └──────────── DocumentCompositor ───┘  (+ bands, reductions,
                                                                             surfaces, PSD oracle)
```

* **One plan, two executors.** All Photoshop layer semantics live in the planner; both executors
  interpret the same `DrawOp`s, so they cannot diverge on semantics, only on arithmetic.
* **DrawOp protocol** (`Plan/RenderPlan.swift`): a stack of straight-alpha RGBA buffers over the
  region. `pushGroup/popGroup` (isolated | pass-through with opacity × mask), `pushTransparent`,
  `pick/drop/swap/remove`, `drawTiles(leaf, mask)`, `fill`, `pushMaskShape`, `mask`, `composite`
  (blend_into_fill: special-eight fill, Dissolve, text gamma), `clipped` (atop), `adjust`,
  `filter` and `backdropFilter` (filter adjustment layers, below), `adjustMix` (with `coverage` for
  the blurs), `quantize`, `finishLayer` (channels + Blend If), `effect(spec, atop:)`,
  `saveFloor/pushFloor/dropFloor`, `knockoutBegin/End`, `mixBy`, `addDifference`, `restrictTo`.
  `RenderPlan.validate()` checks stack discipline.
* **Leaves** come from a `RenderSource` (`leaf`, `leafVersion`, `pattern`): `.surface` (tiled
  document pixels, GPU-resident per (leaf, tile-aligned cell) and re-uploaded per tile when
  `Tile.generation` changes) or `.image` (derived pixels with a version).

## File map

| Swift | photocraft | Contents |
|---|---|---|
| `Plan/RenderPlan.swift` | compose lib.rs semantics, gpu plan.rs | DrawOp, LeafID/roles, RenderLeaf, RenderSource, MaskSpec, LayerBlend, RenderContext, validation |
| `Plan/DocumentPlanner.swift` | compose lib.rs `composite_stack_at`, `composite_layer*`, `composite_atop*`, `render_content`; advanced.rs; gpu plan.rs `plan` | `DocumentPlanner.plan(document:region:) -> [DrawOp]`, `build(…) -> DocumentPlan`, `PlanOptions` (text gamma, layer comp, occlusion pruning) |
| `Plan/DocumentSource.swift` | compose `effect_shape`, multichannel.rs, gradient_fill.rs `render_cmyk_fill`, pattern.rs `pattern_rgba`, shape_split.rs; vector `CompiledVectorMask` | `DocumentRenderSource`, `DocumentLeafCache`, derived leaves, `fit_stroke` |
| `Plan/LayerGeometry.swift` | compose lib.rs bounds / predicates, bounds.rs, advanced.rs | `ContentBounds` (per-tile cached scan, fingerprints), `layer_bounds`, `effect_source_bounds`, `empty_in`, `shapeless_stroke_bounds`, `transparent_outside`, `composite_bounds`, `change_bounds`, `fill_frame`, `channel_weights`, `blend_if_active`, `occludes_below`, `effect_outline`, `paint_bounds` |
| `Plan/LayerRasterizer.swift` | compose `render_content` / shape_split entry points, vector `path_coverage` | `LayerRasterizer` protocol, `PlaceholderRasterizer`, `RasterMiss` |
| `Plan/PathCoverage.swift` | vector raster.rs | exact-area path coverage (vector masks, effect outlines) when the rasterizer has none |
| `Plan/NativeSpace.swift` | compose native.rs (`flatten_cmyk`), extended | Lab / CMYK plans in the document's own channels: colour, pixel and pattern conversion, plane-safe adjustments, merging for display |
| `Plan/FillLayerRenderer.swift` | compose `render_fill_content`, gradient_fill.rs `render_cmyk_fill` | public: a fill layer's stored pixels in any format |
| `DocumentCompositor.swift` | compose `render`, `render_bands`, `band_rows_for`, `composite_to_surface`, `render_reduced*`, `thumbnail*` | façade (Metal with CPU fallback), bands, reductions, surfaces, `CompositeOracle` |
| `CPU/CPUCompositor.swift` | compose lib.rs, advanced.rs | CPU executor (tiles, effect-map and mask caches), `Compose`, `FillRender` |
| `CPU/PSBlend.swift` | compose psblend.rs | Photoshop blend variants, fill, text gamma, Lab mixing, HDR |
| `CPU/Adjust.swift` | compose adjust.rs | every adjustment incl. Gray / CMYK / Lab tone spaces, LUTs |
| `CPU/GradientMath.swift` | compose effects.rs, fill_layout.rs, gradient_fill.rs | gradient geometry, ramps, dither |
| `CPU/Masks.swift` | compose masks.rs, lib.rs `mask_vals` | `LeafReader`, combined (feathered) masks, Blend If weight |
| `CPU/RGBABuffer.swift` | compose `Buffer` | buffers, parallel helpers |
| `CPU/Filters.swift` | (new; Compositor's grain / noise hashes, MIT, © 2026 Wonder Assembly LLC) | filter adjustment layers: `FilterMath` (patterns, kernels, reach), the CPU reference `FilterCPU` |
| `Effects/*.swift` | compose effects.rs, gpu fx.rs | distance fields, effect maps, `composite_with_effects` |
| `Params/PatternTile.swift` | compose pattern.rs | pattern tiles and placement |
| `Metal/MetalCompositor.swift` | gpu lib.rs `Compositor`, `run_cell` | cells, back-to-back command buffers, op encoding |
| `Metal/MetalEffects.swift` | gpu fx.rs, plan.rs `effects`, lib.rs `sync_fx` | GPU effect maps, feathered masks, effect composite |
| `Metal/Residency.swift` | gpu lib.rs residency | tile-generation residency cache with LRU budget |
| `Metal/GPUAdjustment.swift` | gpu plan.rs `adjustment_program` | adjustment → specialised kernel |
| `Metal/MetalFilters.swift`, `Shaders/PCR8Filters.metal` | (new) | filter adjustment layers on the GPU: Grain / Add Noise kernels, a blur's backdrop program rendered and blurred before the cells |
| `Metal/MetalKernels.swift` | gpu lib.rs pipelines | `PCROp` (288 B), pipelines, `AccumulatorPrecision`, `TexturePool` |
| `Metal/CanvasMemory.swift` | (new) | GPU footprint (`CompositorFootprint`, `DisplayFootprint`), `memoryBudget` caps, views (`RenderView`), the `relieve` ladder (`ReliefLevel`, `ReliefReason`, `Relief`) |
| `Shaders/PCR0–6*.metal` | compose.wgsl | `pcr_` kernels: compose, adjust, fill, maps, effects, masks |
| `Display/CanvasRenderer.swift`, `Shaders/PCR7Display.metal` | gpu display sink; Compositor v1.5 level selection | zoom / pan, checkerboard, nearest ≥ 100 %, premultiplied halving chain below 50 %, 33³ LUT pass, MTKView / CAMetalLayer |
| `Bench/BenchmarkDocuments.swift` | (new) | procedural `effects4` / `realistic20` scenes |
| `Tests/PCRenderTests/PhotoshopM1Tests.swift` | (new) | Photoshop 27.11 function-oracle fits (batches M1, M2), PCIO's phase-4 requests, B/C modes |
| `Sources/PCRenderBench/main.swift` | (new) | `swift run -c release PCRenderBench` |
| `Sources/PCRenderBench/MemoryBench.swift` | (new) | `PCRenderBench --memory`: accessors against the device's count, `relieve` timing, the 16 GB tier, an admission against closed documents' pages |

## Phase 2: planner and leaves

* **Semantics covered** (each with end-to-end tests): pass-through vs isolated groups (fill < 100 %
  or effects isolate; opacity / masks mix the pass-through result back), clipping groups (atop the
  base content; hidden base hides them; Blend Clipped as Group off), layers clipped to a
  pass-through group (`addDifference`), fill vs opacity (special eight), Blend If (this / underlying,
  split sliders, per channel, Gray docs, adjustment and clipped layers), channel restrictions,
  knockout shallow / deep (floors, Background found by its locks, isolated groups stop deep
  knockouts), masks (density, feather, vector coverage with density / feather, masks hiding
  effects), adjustment layers (apply to everything below inside their group, depth quantisation
  after each), fill layers (solid, gradient incl. dither, pattern in the document mode, Photoshop
  fill caches while they match, native CMYK gradients), hidden layers, artboards, Multichannel inks,
  type / shape / smart-object caches, shape fill / stroke split, effects (all kinds, groups, clipped,
  Transparency Shapes Layer off, Blend Interior), layer comps (`PlanOptions.comp`: visibility +
  appearance; positions are an engine edit), root occlusion pruning (not in Lab).
* **Leaves.** Raster / cached pixels are served straight from their `Surface` (Metal residency keyed
  by tile generation). Derived leaves — vector-mask coverage, effect shapes (group shapes rendered
  by a nested CPU plan, as photocraft's `effect_shape`), Multichannel inks, native CMYK fills — carry
  a plan-time version fingerprint and are built lazily (per-leaf locks) and cached across renders in
  `DocumentLeafCache`: a warm render costs fingerprints, not rebuilds. Planning a 20-layer 4096²
  document takes 0.1 ms warm.
* **`LayerRasterizer`** (PCPlatform implements): `rasterize(layer, in:)` for uncached type / shape /
  smart layers, `coverage(of: path, in:)` for vector masks and filled-shape effect outlines,
  `renderShape(_, format:, clip:)` for the fill / stroke split. `PlaceholderRasterizer` returns nil
  and records misses; layers then draw empty, vector masks reveal all, outlines fall back to pixels,
  and `DocumentPlan.misses` lists them. Tests use a CoreGraphics rasterizer (`DocumentSupport.swift`).

## Parity (GPU vs CPU, M5 Max)

| Area | Fixtures | rgba32Float | rgba16Float |
|---|---|---|---|
| Blend modes (33 modes × opacity / fill / text gamma × RGB, Lab, 32-bit) | phase 1 | 0.002 levels | ≤ 0.6 levels except amplifying modes (Hard Mix 215, Glow 9.3, Vivid Light 4.0, Dodge / Burn 2.4, Reflect 1.2) |
| Adjustments (36 variants × 8/16/32-bit × RGB/Lab) | phase 1 | 0.010 levels | threshold / posterize steps flip |
| Effects (48 stacks, plain and atop) | phase 1 | 0.002 levels | 0.61 levels |
| Masks (pixel, density, feather, vector, both) | phase 1 | 0 | 0.30 levels |
| Gradient / pattern fills | phase 1 | 0 | 0.12 levels |
| Display (zoom levels, LUT) | phase 1 | ≤ 1/255 | — |
| End-to-end documents (582 renders in 116 tests) | phase 2 | max **0.89 levels** (one quantisation flip), all others ≤ 0.44 | — |
| `realistic20` at 4096² | bench | max 2 levels at 7 px (4·10⁻⁵ %), mean 1·10⁻⁵ levels | — |

`AccumulatorPrecision.automatic` therefore uses rgba16Float only for 8-bit plans without adjustment
layers or amplifying blend modes (Color Dodge / Burn, Vivid Light, Divide, Hard Mix, Dissolve,
Reflect, Glow); everything else composites in rgba32Float. The remaining differences are level
flips where an adjustment rounds to whole levels (photocraft's depth quantisation) and float
evaluation order differs; subsequent level-stretching adjustments can widen a flip to 2 levels.

## Timings (Release, warm GPU, Apple M5 Max 18-core, `swift run -c release PCRenderBench`)

| Scene (4096²) | CPU cold | CPU warm | Metal cold | Metal warm (wall / GPU) | Speed-up |
|---|---|---|---|---|---|
| `effects4`: 4 layers, drop shadow + stroke, outer glow + inner shadow (Multiply), bevel + overlay | 1006 ms | 125 ms | 813 ms | **3.4 / 3.1 ms** | 36× |
| `realistic20`: 20 layers (see `BenchmarkDocuments`) | 1202 ms | 613 ms | 413 ms | **25.9 / 25.0 ms** (16.6 ms if half floats were forced) | 24× |

Warm = maps / shapes cached, min over the last half of back-to-back renders into a reused target
(allocating a fresh 4096² float target costs ~5 ms of page mapping per render). Cold includes
effect maps (distance fields stay on the CPU, as in photocraft-gpu) and effect shapes. CPU encoding
is ≤ 1 ms per render; planning 0.1 ms.

## PSD composite-oracle hook

`Tests/PCRenderTests/PSDOracleHook.swift` + `DocumentPipelineTests.psdCompositeOracle`. Expects a
loader `(URL) throws -> OracleCase?` (in `PSDOracleHook.loader`, or `CompositeOracle.register`)
returning the layered `Document` and Photoshop's merged image as `reference`: straight RGBA floats
over exactly `document.bounds` (8/16-bit normalised, 32-bit as stored; non-RGB modes via
`Surface.readRGBA`; opaque when the merged image has no alpha; white-matted composites either
un-matted or returned opaque with `flattenedOver: (1,1,1)`). With `PCRENDER_PSD_CORPUS=<dir>` set,
every .psd / .psb under it is composited on CPU and Metal and compared premultiplied in 8-bit
levels (`OracleComparison`: max, mean, pixels > 2 levels, rasterizer misses); thresholds
`PCRENDER_ORACLE_MEAN` (default 1.0) and `PCRENDER_ORACLE_OFF` (default 0.02).

## Deliberate deviations

1. **Noise floor** `EffectMath.noiseFloor = 1e-5`: photocraft speckles at `v <= 0`, which reads f64
   blur residues (~1e-16) as coverage; GPU f32 leaves ~1e-8.
2. π rounded to nearest (`piF`); Swift's `Float.pi` rounds toward zero.
3. Accumulator precision policy above (photocraft-gpu uses one format).
4. Not ported: proxy thumbnails for > 16 MP (`thumbnail` always reduces the exact composite), the
   Transparency-Shapes-off band clipping of effect regions (maps cover the whole region; same
   pixels, more memory on very tall pages), layer-comp positions. (`native::flatten_cmyk` is now
   ported and extended, see phase 3.)
5. Multichannel inks and native CMYK fills are computed over region ∪ canvas; nested effect-shape
   renders reaching past it read their outside value.
6. Tests not ported: Normal-kernel bit-exactness (Rust kernel internals), rayon deadlock and
   thread-flag tests (no equivalent), proxy thumbnails, `shape_layer_gradients_match_fill_layers`
   (needs photocraft-vector), Photoshop reference tables already ported in phase 1
   (`AdjustmentReferenceTests`, `BlendParityTests`).

## Phase 3: Photoshop's composites as the oracle

PCIO's `CompositeOracleTests` composite every file of the Photoshop-authored ps-corpus (153 files,
148 with a usable merged image) on CPU and Metal against Photoshop's own composite, at the
thresholds above. A scratch tool compared against `composites/<name>.tif` (Photoshop's exported
recomposite) as well as the stored merged image: they agree except in the six files the oracle
agent lists (Photoshop-internal); adj-stack-rgb-16 is the only one where the numbers move (mean
3.023 vs 3.045, 5.05 % vs 5.06 % off).

| | Unity (36) | ps-corpus CPU | ps-corpus Metal |
|---|---|---|---|
| before | 36/36 | 109/148 | 109/148 |
| after | 36/36 | 134/148 | 134/148 |

Fixes, each measured on the corpus (photocraft is the spec unless Photoshop disagrees):

1. **Native Lab and CMYK compositing** (`NativeSpace`). Lab plans run on the stored channels with
   Photoshop's Lab rules (`PSBlend.blendLab`, fitted on blend-bands-lab-8: Multiply/Screen on L
   with a/b `t_b + t_s(1 − |t_b|)`, Linear Dodge/Burn add a/b, Hue/Saturation by Chebyshev
   chroma, Darker/Lighter by L; 8-bit Soft/Hard/Linear Light and a/b of Vivid Light take 128 as
   the middle, Vivid Light's L ½); CMYK as two plans over ink brightness (C, M, Y and K), the RGB
   formulas per ink, non-separable modes keep the base K (Luminosity takes the source's), merged
   and converted only for display. CMYK stays in RGB when an adjustment mixes channels
   (`planeSafe`). Native results round to document levels before display; no text gamma in
   native spaces (it cost 14 levels in text-cmyk). Metal uses float accumulators for native
   8-bit plans (half: mode-lab-8 4.6 % off on Metal vs 1.0 % CPU).
2. **Vector masks**: exact-area coverage (`PathCoverage`) when the rasterizer has none (PCIO's
   reports came from that: `PlaceholderRasterizer` had no coverage); vector-mask feather is an
   exact Gaussian σ = feather (photocraft's 3-box: mask-vector-feather off).
3. **Soft Light** is the W3C formula; 8-bit Linear/Hard/Soft Light use 128 as the middle level;
   32-bit Subtract is unclipped and the non-separable modes skip ClipColor (blend-bands-rgb-32).
4. **Blend If**: gray = round(0.30 R + 0.59 G + 0.11 B) in 8-bit, a split ramps over
   hi − lo + 1 levels ((v − lo + 1)/(hi − lo + 1)): blendif-gray 9.1 % → 0.08 % off.
5. **Selective Color**: each range pulls towards its own clamped result, Absolute ink and Black
   combine as (1 + ink)(1 + black) − 1 (photocraft: unclamped sum scaled by min(2v, 1)):
   1.24 → 0.14 mean. The phase-1 Photoshop table still matches.
6. **Hard Mix ties** (b + s = 1, where Vivid Light is exactly ½): Photoshop gives 1 when the blend
   value is below ½ and 0 above it (ps-corpus blend-hardMix: 75 of 75 tie samples; photocraft
   gives 1 on every tie). blend-hardMix: 38 → 0 ties off, 23 → 0 partly transparent pixels off.
   Found by AB-T-0239's `.comp` parity work.
7. **Soft effects**: spread/choke blur width = size − round(size × spread), not size × (1 − spread)
   (fx-drop-shadow, fx-outer-glow, fx-multi, fx-rgb-16, fx-cmyk, text-effects now 0–1.3 % off).
   Shadow / outer-glow knockout `(1 − a)/(1 − fill·a)`.
8. **Satin**: the offset copies are XORed then blurred, and the contour is read like every other
   (photocraft reads it from the far end; equal only for symmetric contours): fx-all max 26.8 → 7.2.
9. **Outside strokes** split a covered pixel: the stroke takes 1 − a over the exterior result, the
   layer takes a blended against the exterior result *without* the stroke (combined-rgb-16: Soft
   Light under a gradient mask, 18.5 % → 0 % off). photocraft draws the stroke beneath and blends
   the layer with it. Type keeps the old order (its gamma-blended edges; text-effects).
10. **Transparency Shapes off + Blend Interior as Group**: grouped interior effects are drawn
   atop the content (advanced-flags 32 % → 0 %; photocraft paints them over the whole layer).
11. **Fill layers render at the document's depth** (every channel rounded to the stored depth,
    CPU and Metal), and `FillLayerRenderer.render(_:fill:canvas:patterns:format:)` gives a PSD
    writer exactly the pixels the compositor draws (`FillLayerTests`: live = baked ≤ 1e-6 in RGB,
    CMYK, Lab, Gray at 8/16 bits).

Phase 3 left 14 files failing (CPU and Metal alike); phase 4 below fixes four of them and revises
the list.

## Phase 4: Photoshop 27.11 as a function oracle (measurement batch M1)

ps-oracle's batch M1 (`Tools/PhotoshopOracle/RESULTS.md` §5b; 76 jobs, flattened TIFFs at document
depth) isolates each remaining fit: a 64³ RGB lattice plus a grey ramp through adjustments and
blends, raw Satin maps (shape Fill 0 % over black, white Normal Satin), and Dissolve.
`Tests/PCRenderTests/PhotoshopM1Tests.swift` rebuilds every job (`PCRENDER_M1_DIR=<batch>`, default
`$PHOTOCRAFT_FIXTURES/ps-measure/M1`; skipped without it; `PCRENDER_M1_LOG=1` prints the fits), renders it on CPU and Metal and compares with
Photoshop's TIFF. Numbers: max / mean levels / pixels > 2 levels off, before → after.

1. **Satin** (`EffectMath.satinMap`, `contourSupersampled`; GPU `pcr_m_contour_aa`). Photoshop blurs
   *each* offset copy (two box passes of the size, as photocraft did), puts each through the contour
   and takes |C(a) − C(b)|; Invert is 1 − that. Phase 3's "XOR, then blur, then contour" fitted one
   corpus file, but on the raw maps it was 70–120 levels off along edges parallel to the offset even
   for Linear. An **anti-aliased** contour (every M1 job and the corpus: `AntA` true) is the mean of
   C over 3 × 3 bilinear samples at +0, ⅓, ⅔ px — a grid anchored at the pixel, so the contoured map
   sits ⅓ px up-left (a fitted shift of the copies came out at (−0.33, −0.33) px for every contour;
   Linear, which has no LUT, has none). Without anti-aliasing the contour is read once per pixel
   (unmeasured). M1's stored contours carry no `Cnty`, i.e. Photoshop's Cone / Cone − Inverted are
   smooth splines (PCEngine's built-in Cone marks its peak as a corner).

   | raw map (a19 d11 s14 unless noted) | phase 3 | phase 4 |
   |---|---|---|
   | Linear / inverted | 71 / 0.99 / 4.8 % · 70 / 1.00 / 4.2 % | 2 / 0.30 / 0 · 2 / 0.39 / 0 |
   | Linear a90 · d30 s5 | 120 / 1.94 / 5.9 % · 114 / 0.38 / 1.0 % | 2 / 0.35 / 0 · 1 / 0.15 / 0 |
   | Gaussian / inverted | 89 / 9.1 / 32 % · 135 / 5.7 / 26 % | 2 / 0.27 / 0 · 2 / 0.40 / 0 |
   | Cone, Cone − Inverted (each ± invert) | 254–255 / 14–187 / 44–99 % | 2 / 0.36–0.51 / 0 |
   | Cone a90 · d30 s5 | 255 / 19.2 / 57 % · 253 / 5.0 / 24 % | 3 / 0.64 / 0.12 % · 2 / 0.16 / 0 |
   | Ring / inverted | 255 / 18.1 / 55 % · 251 / 15.5 / 50 % | 5 / 0.77 / 5.2 % · 5 / 0.75 / 7.6 % |

   The 28 composites (raw and Multiply 50 % over grey) are ≤ 3 levels, ≤ 1.3 % off. Ring's residual
   is its curve: a free 33-knot contour fitted to the Ring maps sits up to 0.015 below the natural
   spline through Ring's points (0.38 mean), so Photoshop's contour spline is not quite
   `curveLUT`'s. **Verdict on photocraft's `contour_presets_match_photoshop`:** its observations
   hold — Photoshop's Cone and Cone − Inverted satins are identical (≤ 2 levels apart in M1), and
   a Gaussian satin reads 0.36 where one copy is at 0.5 and the other fully inside — because the
   satin is |C(a) − C(b)|, invariant under C → 1 − C; photocraft's reversed `|lut − end|` transfer
   reproduces only those one-sided pixels. PCEngine's `contourPresetsMatchPhotoshop` now checks
   exactly that (`satinLUT` of Cone + Cone − Inverted = 1; |G(0.5) − G(1)| = 0.36) instead of five
   known issues.

2. **Light-mode Contrast** — *corrected in phase 5: this item first called it "Modern"* — (`AdjustMath.photoshopContrast`,
   `proPhotoTone`; GPU kind 5 `pcr_prophoto_tone`). M1's B/C layers were made in Photoshop 27's
   default Light mode (`brightnessModeLight`, AB-L-0269), which drops `Brgh` (stored 0, as in the
   corpus file: Light, Contrast 35), so M1 measures Light Contrast −50, 50, 100 (the 16-bit job is an
   identity). Contrast is not per channel:
   the grey curve is applied the DNG SDK's hue-preserving way (largest and smallest channel through
   the curve, the middle one kept between them) **in ProPhoto**, channels sRGB-encoded for that
   interpolation, then back to sRGB, clipped. The grey curve is a cubic Hermite S in ProPhoto's γ 1.8
   encoding through (0, 0), (0.55, 0.55), (1, 1), end slope 1 − c/136.4, pivot slope 1 + c/131.1
   (c ≥ 0) or 1 + c/168.9 (c < 0) — 0.36–0.43 levels rms on the ramps (8-bit rounding alone: 0.29).
   Lattice: c −50 82 / 17.6 / 95 % → 23 / 1.17 / 11.3 %; c 50 72 / 16.8 / 96 % → 26 / 1.24 / 10.9 %;
   c 100 106 / 26.2 / 99 % → 38 / 1.95 / 23.5 %. Not exact: saturated colours keep a residual that
   depends on (max, min) of the ProPhoto channels (up to 3 levels in γ 1.8; a fitted primaries matrix
   only took it from 0.79 to 0.60 rms), which dark blues near the sRGB boundary amplify. **The pivot
   is image-adaptive:** ps-corpus adj-brightnessContrast (Contrast 35) pivots near sRGB 124
   (γ 1.8 0.41), the lattice at 157 (0.55), though both store `means` 127; no simple image mean
   explains both. PCRender uses the lattice's pivot, so that file is now 69.7 % off (phase 3's
   per-channel curve, pivot ½: 49.6 %). (Phase 5: Light ignores Brightness; Modern is fitted
   separately.)

3. **Vibrance** (`AdjustMath.vibranceLinear`, `vibranceBoost`, `vibranceLift`, `vibranceSkinFit`,
   `vibranceDark`; GPU `pcr_vibrance_lin`). Photoshop's Vibrance is a per-pixel scale about a grey in
   linear sRGB, a function of linear HSV saturation and value (hue kept to 0.2°) — photocraft's form.
   Positive amounts refitted on Vibrance 50 / 100, Saturation 0 (boost constants, a brightness lift
   0.248 instead of ¼, a dark roll-off × mx / (mx + 0.0058)) and a new skin protection: full below
   hue 30°, none from 45° to 298°, and saturation-dependent, w · min(1, (0.776 + 1.050 (1 − v))
   (1 − t)^0.927), so saturated skin tones still move (the 0.64 v^1.6 rule, even with refitted
   hue ramps, was 2.8 rms on skin hues; this is 0.83). Negative amounts keep photocraft's form (a dark roll-off there cut max error but
   raised the mean 0.1 → 0.6). The Saturation slider (grey 0.288 R + 0.712 G) refits to the same
   weights. The ±50 Saturation jobs were held out of the fit.

   | Vibrance / Saturation | before | after |
   |---|---|---|
   | 50 / −50, 0, +50 | 12 / 0.81 / 5.6 % · 12 / 2.29 / 33 % · 35 / 1.22 / 12.6 % | 2 / 0.30 / 0 · 3 / 0.55 / 0.02 % · 21 / 0.50 / 4.7 % |
   | 100 / −50, 0, +50 | 34 / 1.38 / 15 % · 34 / 5.49 / 54 % · 45 / 1.62 / 16 % | 8 / 0.24 / 0.73 % · 8 / 0.50 / 1.9 % · 27 / 0.38 / 4.0 % |
   | −50, −100 (all) | ≤ 24 / ≤ 0.14 / ≤ 1.4 % | unchanged |

   Saturation +50 amplifies the Vibrance stage's 1–3-level misses where a colour's smallest channel
   lands near 0 (e.g. (247, 247, 166): Photoshop's Vibrance gives blue 153, ours 151, which
   Saturation +50 turns into 25 vs 2).

4. **Hue, Saturation, Color, Luminosity at 8 bits** (`PSBlend.nonSeparable8`, `lum8`, `setSat8`,
   `setLum8`; GPU `pcr_nonsep8`). Photoshop works on whole levels: luminosity is
   (4915 R + 9667 G + 1802 B + 8192) >> 14 (0.30 / 0.59 / 0.11 in 14-bit fixed point, rounded:
   this, and no other rounding or weight set, reproduces every one of 318 190 unclipped pixels),
   SetLum shifts by a whole number of levels, SetSat rounds to levels, ClipColor rounds half up.
   Unclipped pixels are exact; clipped ones are within 1 level (Photoshop's clipped results run
   about +1 level high in a pattern no tested rounding / bound variant reproduces). Max / mean /
   off, both permutations: Luminosity 3–4 / 0.52–0.76 / 0.34–0.38 % → 1 / 0.32–0.43 / 0; Color 3–4 →
   1 / 0.41–0.43 / 0; Hue 3–4 → 1 / 0.39–0.43 / 0; Saturation 9 / 0.50 / 0.64 % → 1 / 0.19 / 0.
   16-bit Luminosity already matched the float W3C formulas (0.04 levels: Photoshop's 15-bit
   storage, v >> 1 read back as round(v₁₅ · 65535 / 32768)).

5. **Dissolve: characterised, not reproduced.** Photoshop's pattern is a function of canvas
   coordinates only (two builds identical; a layer offset by (37, 53) on a 320² canvas keeps the
   dots at the same canvas pixels; the 256² and 320² canvases agree where they overlap, so it does
   not depend on the canvas width either). It does not tile: agreement with the pattern shifted by
   every (dx, dy) up to 128, and by 256 in x and y (the offset document reaches 309), stays at
   0.486–0.514, i.e. chance. It is white noise: P(red | left neighbour red) = 0.512 against 0.510
   coverage, run lengths 0.498, 0.251, 0.128, 0.061, … (Bernoulli: 0.5ᵏ), no bias by x or y mod 2, 4,
   8, 16. Coverage at 50 % opacity is 51.04 % (and 50.93 % over the offset layer): 5σ above 50 %,
   consistent with an integer threshold compared as ≤ (e.g. 130 / 255 = 50.98 %), but one opacity
   cannot pin the threshold distribution or its relation to opacity. PCRender's hash
   (`PSBlend.dissolveNoise`) gives 50.19 % and agrees with Photoshop on 50.1 % of pixels. Options for
   the operator: (a) keep the hash (statistically equivalent white noise, not pixel-identical);
   (b) measure coverage at many opacities (aggregate numbers only) and shape our threshold
   distribution to match Photoshop's coverage curve, still not pixel-identical, no table embedded;
   (c) reconstruct Photoshop's per-pixel threshold ranks from an opacity sweep and embed them —
   pixel-identical within the measured extent, but that is a table extracted from Photoshop's output
   (licensing decision, not taken). A generator derived from scratch (a known PRNG reproducing the
   bits) would avoid the table, but nothing in M1 points to one.

6. **PCIO requests.** Grayscale (and Duotone, Bitmap) documents draw fill-layer colours as their grey
   (`NativeConvert.grayFill`, `ColorConvert.rgbToGray`, in the planner and in `FillLayerRenderer`,
   so live and written pixels stay identical) and Selective Color's result as its grey (CPU and GPU
   kind 18). Gradient Map reads Photoshop's luminosity 0.30 / 0.59 / 0.11
   (`AdjustMath.gradientMapInput`; ps-corpus adj-gradientMap with PCIO's Oklab smooth bake: max 1,
   mean 0.03). Tests: `Phase4RequestTests`.

ps-corpus after phase 4: **139/148 on CPU and on Metal** (phase 3: 134; 135 after PCIO's Gradient
Map bake). Newly passing: fx-satin (9.9 % → 0 %, mean 0.08), fx-all (5.6 % → 1.3 %),
blend-luminosity (3.1 % → 0 %), adj-vibrance (3.7 % → 0.05 %). The measurements phase 4 asked for
became batch M2 (phase 5).

## Phase 5: Brightness/Contrast modes, Dissolve coverage, contour presets (batch M2)

Batch M2 (`Tools/PhotoshopOracle/RESULTS.md` §5c, 102 jobs; every adjustment read back after it was
set) and `Tests/PCRenderTests/PhotoshopM1Tests.swift` › `PhotoshopM2Tests` (`PCRENDER_M2_DIR`; the
Satin jobs also need `PCRENDER_M1_DIR` for the contour points).

1. **Brightness/Contrast has three modes** (AB-L-0269), end to end:
   - **PCDocument** `Adjustment.BrightnessContrast` gains `mode` (`.legacy` / `.modern` / `.light`)
     and Light's `exposure`, `whites`, `blacks`, `highlights`, `shadows`; `legacy` becomes a computed
     property, `init(brightness:contrast:legacy:)` stays, JSON is unchanged except for Light.
   - **PCIO** reads `brightnessMode` (`brightnessModeLegacy|Modern|Light`) and Light's keys from
     `CgEd` and writes Photoshop's layouts (Light: `Vrsn`, `brightnessExposure`, `Brgh`, `Cntr`, the
     four tone keys, `means`, `Lab `, `brightnessMode`, `useLegacy`, `Auto`; Modern adds only
     `brightnessMode`); a file without the key keeps `useLegacy`'s mapping.
   - **PCEngine**'s B/C command takes `mode` (default: Modern, Legacy when `legacy` is true; an
     edit keeps the adjustment's mode) and Light's controls.
   - **PCRender** dispatches: Legacy photocraft's; **Light** (Brightness ignored) Exposure,
     Contrast, Whites, Blacks fitted on batch M3 (item 6 below; Highlights / Shadows identity);
     **Modern** (`modernToneLUT`, `modernBrightnessPS`; GPU kind 7)
     fitted here. CMYK ink planes and Lab take the curve per channel (Photoshop has no Light mode
     there).

   **Modern** is one curve per channel (the 64³ lattice is exactly per channel), Contrast after
   Brightness (composing the measured curves reproduces each B × C job tried within 1 level), and the
   same for every image (Contrast 50 over flat greys 32–224, the half and half-black lattices:
   identical curves; Photoshop stores `means` 127 regardless). Contrast is photocraft's cubic S
   about ½ (`modernContrast`: ≤ 1 level on −50, −25, 25, 50, 75, 100). Brightness was refitted:
   a straight line from black with slope 1.3776^(b/50) rolling into white as a normalised soft
   minimum, y = m(s x)/m(s), m(v) = (v⁻ᵖ + 1)^(−1/p), p(b) = 4.161 + 17.36 e^(−|b|/10.68); negative
   Brightness is the inverse of the positive curve (Photoshop's ±50, ±150 curves invert each other
   to 0.16 / 0.73 levels). Lattice + ramp, 24 jobs: photocraft's modern curves worst 48 levels, 90.6 %
   > 2 levels, mean of means 4.04 → **worst 5 levels (Brightness −150), 8.9 % (−150 with Contrast
   100), means 0.25–1.13**; 16-bit 50 / 50: 0.9 / 0.58 / 0. The −50 / −150 curves were held out of the
   fit (0.58 / 0.70 rms). p(b) took ps-corpus adj-brightnessContrast-b25c35 (Modern 25 / 35) as its
   third point: with a constant p (4.2) that file was 16.2 % off (3 levels at its highlights); it
   passes now (max 1, mean 0.15), but is no longer a hold-out.

2. **Dissolve: Photoshop's coverage, our noise** (operator decision AB-D-0130; `PSBlend.dissolveDraws`,
   `dissolveThreshold`, `dissolveCoverage`; GPU `pcr_dissolve_draws`). A pixel is drawn when each of
   opacity, Fill and the source's coverage (mask × pixel alpha) is under Photoshop's measured coverage
   curve on its own noise field (photocraft's hash, three seeds; the opacity field is the old one).
   Photoshop's three fields are mutually unrelated (pairwise 49.97–50.06 % equal at 50 %, joint
   coverage 0.260) and each is one field thresholded (o45 ⊂ o50 ⊂ o55). The curve is linear between
   the 20 measured opacities (aggregate coverage only; no per-pixel data is used): ours matches every
   M2 job within 0.0015 (o50 0.5112 vs 0.5100; Fill 50 % 0.5090 vs 0.5098; mask 50 % 0.5108 vs 0.5096).
   blend-dissolve still fails per pixel, by design.

3. **Contour presets re-measured** (AB-D-0130; PCEngine `LayerStyleCommands.contours`). M2 item 7
   renders each preset as a Precise Outer Glow (size 120, Range 100 %) round a square. Precise glow's
   coverage is ½ (1 − (d + ½)/121) (Range 100 % Linear: exact along the sides; Range 50 %: within
   1 level, so the Range maps v → min(v / r, 1) as `rangedLUT` does), so each side pixel reads the
   contour once: 121 samples per preset, no spread along the sides. Two limits:
   - **Range 100 % only shows the contour on 0…½** (the glow's coverage outside the shape tops out
     at ½: Cone reads 255 at the edge). Above ½ PCEngine keeps photocraft's Satin-based curve,
     shifted by the constant that best matches the new lower half (Satin cannot see a constant:
     Rounded Steps' old curve sat 0.23 high; the others moved ≤ 0.017).
   - **Precise glow fades out its outer ~29 px**: output = min(C(v), E(d)) with E falling 8.75
     levels per pixel to 0 at d = size (identical in every preset where C is large there), which
     hides C below v ≈ 0.09 for Cone − Inverted, Cove − Deep / Shallow and Rolling Slope; there the old
     curve (shifted) stays too. PCRender's Precise glow has no such fade yet.
   Cross-checks (not used for the fit): the measured lower halves sit within 0.3–0.6 level (mean) of
   the natural spline through the control points M1's PSDs stored for Cone, Gaussian and Ring; the
   old table was off there by up to 6 (Cone), 8 (Ring), 14 (Ring − Double), 12 (Sawtooth 1) and, for
   Rounded Steps, 68 levels. On the M1 Satin maps the new table is worse than those stored points
   for Cone / Ring (1.0–1.3 levels mean against 0.5–0.8), all of it from the old upper half (the new
   lower half with the stored-point upper half: 0.57 / 0.88). Cone is smooth now, as Photoshop
   stores it. Off the diagonals Photoshop's Precise distance runs up to ~2 px longer than the
   Euclidean one (an approximate distance transform; Range 50 % corners up to 7 levels).

4. **Satin, Anti-aliased off: the contour once per pixel** (phase 4's `!antiAlias` branch). Raw maps:
   Cone 2 / 0.51 / 0, Gaussian 2 / 0.27 / 0, Ring 4 / 0.78 / 5.4 % (Ring's curve, as in phase 4); the
   3 × 3 anti-aliased model would be 16–50 levels off. So M1's ⅓-px shift is the anti-aliasing,
   confirmed. Linear at 30° needs the offset (−10, 6): sin 30° · 11 = 5.5 rounds away from 0, which
   `EffectMath.offset`'s Float evaluation already gives (Double gives 5.4999…, 5 levels mean off).
   Sizes 7 and 15 (odd box widths): raw 1 / 0.20 / 0 and 1 / 0.31 / 0. All 12 composites ≤ 4 levels,
   ≤ 0.92 % off.

5. **Vibrance hold-outs** (no refit): −75 13 / 0.09 / 1.19 %, −25 7 / 0.05 / 0.66 %, +25 2 / 0.37 / 0,
   +75 4 / 0.53 / 0.46 %; Vibrance 100 at 16 bits 7.7 / 0.48 / 2.5 % (8-bit: 8 / 0.50 / 1.9 %).
   **Luminosity at 50 % opacity**: max 1, means 0.27 / 0.19, 0 % — the whole-level result is mixed
   at the layer's opacity afterwards, as implemented.

6. **Light mode's controls (batch M3**, `RESULTS.md` §5d, 32 jobs over M2's lattice + ramp;
   `PhotoshopM3Tests`, `PCRENDER_M3_DIR`). Photoshop 27's ranges (`lightModeDescriptor`, clamped
   silently): Exposure −5…5 (a double), Contrast −100…100 (Modern −50…100), Whites / Blacks /
   Highlights / Shadows −100…100 — PCDocument clamps to them (`BrightnessContrast.exposureRange`,
   `toneRange`, `lightContrastRange`), PCEngine's command takes them, PCIO reads every M3 PSD as
   stored (`PhotoshopLightModeTests`, `PCIO_M3_DIR`). Every control is one grey curve applied in
   ProPhoto (`AdjustMath.lightStages` / `lightTone`; GPU kind 5, four stage LUTs), in Photoshop's
   order Exposure → Contrast → Whites → Blacks; Exposure then Contrast composes exactly on greys.
   Ramp (tone) and lattice (colour) fits, max / mean levels / % > 2:
   - **Exposure** is a gain in a fixed scene domain: y = ψ⁻¹(ψ(x) + EV) (`lightPsiPositive`,
     `lightPsiNegative`, 27 samples each). Evidence: ±1.25 twice equals ±2.5 and ±2.5 twice ±5
     within 2 levels; m1.25 then +1.25 is identity within 3. Positive EVs share one ψ that never
     reaches white (a long shoulder: +5 leaves 252 at level 80); negative EVs darken white too
     (−5: 255 → 56), so they get their own ψ with a finite top — the two agree below level ~224.
     Ψ was fitted by least squares on the ramps; with +2.5 held out it predicts +2.5 at max 2, mean
     0.99. Ramp: +1.25 / +2.5 / +5 max 2 (means 0.57 / 0.79 / 0.79); −5 / −2.5 / −1.25 max 7 / 9 / 11
     (−1.25's top 15 levels: its white, 241, is not what −2.5 implies). 16-bit +1.25: max 1.5, mean
     0.56. Colours: the RGB tone on *linear* ProPhoto (lattice means 0.57–4.43; with Photoshop's own
     grey curves the γ 1.8-encoded tone was 0.08–0.17 better at −2.5 / −1.25, and it and the
     sRGB-encoded one 0.6–1.1 worse at +1.25 / +2.5; per-channel 12–53, Lab L only 17–46, ratio-preserving 13–110);
     Photoshop desaturates the most saturated colours more (sRGB (150, 0, 0) at +1.25: (235, 26, 26),
     ours (236, 1, 1)) — the error grows with saturation (0.45 grey → 7.3 at full).
   - **Contrast** is phase 4's model unchanged; M3's ramps (an independent check) −50 / 50 / 100:
     max 2 / 1 / 2, lattice means 1.20 / 1.28 / 2.01. Below −50 the slopes are extrapolated.
   - **Whites and Blacks** are flows: amount t maps x to χ⁻¹(χ(x) ± (|t|/100)^γ), one χ and γ per
     control and direction (`AdjustMath.LightFlow`); a flow needs the ±50 and ±100 curves to
     commute, and they do (0.34–0.62 levels mean; Whites + 1.76). Not a fixed curve scaled by t:
     Whites +50 twice is 23 levels mean off +100, Blacks −50 twice 15. Ramps: Whites −100 / −50 / 50
     / 100 max 2 / 3 / 7 / 4 (means 0.72 / 0.87 / 2.39 / 0.58), Blacks max 2 / 3 / 1 / 1 (means 0.31 /
     0.65 / 0.39 / 0.34). Colours: Whites + and Blacks − (contrast-raising) take the linear RGB tone,
     Whites − and Blacks + (contrast-lowering) keep chroma — the curve's change at the mean of the
     sRGB-encoded ProPhoto channels added to all three. Lattice means 6.5 / 4.6 / 9.0 / 12.2 (Whites)
     and 4.8 / 2.4 / 4.6 / 8.1 (Blacks), against 18 / 13 / 24 / 93 and 51 / 17 / 11 / 19 for identity;
     even Photoshop's exact grey curves, through any of the colour rules tried, stay 4–12 off.
   - **Highlights and Shadows are local** (spatially varying): the ramp rows of one job differ where
     they meet the lattice, and the lattice's own greys differ from the ramp's by up to 56 levels.
     No grey curve reproduces them; they stay identity (known issues in
     `BrightnessContrastModeTests.lightHighlightsShadowsAreIdentity` and
     `PhotoshopM3Tests.lightCombinations`).
   - **Combinations (held out of every fit)**: Exposure 1.25 + Contrast 50 ramp max 2, mean 0.54
     (lattice mean 5.8); Highlights −50 + Shadows 50 ramp 19 / 6.5 (identity); all five (Exposure
     0.625, Whites 25, Blacks −25, Highlights −30, Shadows 30) ramp 11 / 4.15, lattice 5.94 / 89 %
     (H / S missing; γ < 1 / > 1 for amounts under 50 is untested otherwise).
   M3's Contrast jobs use the M1 lattice again, so Light Contrast's adaptive pivot is still open.

ps-corpus (PCIO `CompositeOracleTests`; 155 files, 5 without a usable merged image, so 150
compared): **141/150 on CPU and on Metal** (unchanged by M3: the corpus's Light layers are Contrast
only); Unity corpus 36/36. Largest Metal − CPU gap of per-file means: 0.076.

Still failing (the same 9 on CPU and Metal):

* **adj-brightnessContrast** (Light, 69.7 %, mean 2.1): Light Contrast's pivot moves with the image
  (sRGB 124 here, 157 on the M1 lattice; `means` 127 in both); its statistic is unknown, and
  computing it needs a whole-image pass below the adjustment. M3 measured Contrast on the same
  lattice only, so it does not tell.
* **adj-stack-*** (rgb-16 2.05 %, gray-16 3.37 %, lab-8, rgb-32, cmyk-8): rgb-16's B/C is Light
  (above); gray-16 / lab-8 / rgb-32 / cmyk-8 store Modern 25 / 35 — Modern is per channel in RGB,
  unmeasured in Gray, Lab, CMYK and 32-bit (gray-16 went 2.67 → 3.37 % with the new curve); and the
  rest of each stack (CMYK cross-channel adjustments on inks, Lab and 32-bit chains) is unfitted.
* **blend-dissolve**, and the Dissolve band of blend-bands-lab-8 (2.09 %): coverage only (item 2).
* **blend-bands-cmyk-8** (4.4 %): Darker/Lighter Color choose a whole CMYK colour; the two-plane
  path decides per plane (needs all four inks in one stack: a 5-channel CMYK path).

Batch M3 settled Light's Exposure, Whites and Blacks on greys (item 6). Open: Highlights and
Shadows (local), how Light reaches saturated colours, and Contrast's adaptive pivot.

Measurements that would settle more:

* **Contour presets above ½**: item 7 again at Range 50 % (or 25 %), Anti-aliased off — the glow's
  coverage then spans the whole contour.
* **Light Contrast's pivot**: Light Contrast 50 over M2's nine pivot inputs (flat greys 32–224, the
  half and half-black lattices).
* **Modern B/C outside RGB 8/16**: Gray 16, Lab 8, CMYK 8, RGB 32 lattices / ramps at Modern 25 / 35.
* **Precise glow's fade and distance**: Linear at size 30 and 120, Range 100 %, round a circle.
* **Light Highlights / Shadows' neighbourhood**: Highlights 100 and Shadows 100 over flat greys
  (32, 64, …, 224: the response with no neighbourhood), over a 50 % grey with one 64 px white /
  black square (the radius and falloff of the effect from an edge), and over the ramp alone (no
  lattice).
* **Light on saturated colours**: Exposure +1.25, Whites ±50, Blacks ±50 over a hue ring at full
  and half saturation (sRGB and ProPhoto primaries) at three levels — where the colour rules here
  are 5–12 levels off.
* **Light amounts below 50**: Whites / Blacks ±10, ±25 ramps (γ of each flow is set by ±50 and
  ±100 alone), Exposure ±0.5, and Contrast −100 (extrapolated below −50).

## Canvas memory: a declarable GPU tenant (AB-T-0251)

A host (PixelAgencyEditor, AB-T-0253) declares the canvas to its model engine as one external GPU
tenant (AB-A-0169 §2). PCRender stays engine-free: it reports bytes and sheds by level; the host
maps them onto its engine's declaration. ForgeCanvasUI's `CanvasPressurePolicy` is the precedent
(AB-R-0315).

* **Footprint.** `MetalCompositor.footprint` (waits for a render in flight), `lastFootprint` (never
  waits) and `onFootprintChange` (after every render, shrink, purge and budget change, outside the
  lock) give a `CompositorFootprint`: pages, leaf images, gather pages, effect maps, masks, patterns
  and pool heaps, of which `visiblePages` / `visibleEffects`, plus `transient`. Then
  `persistent`, `sheddableOnRun = persistent − visible`, `declared = persistent + transient`.
  `CanvasRenderer.footprint` gives the composite, its reduction chain and the LUT (read it where the
  canvas is driven; a shrink never takes it). Bytes are Metal's allocation sizes, recorded when each
  texture is made (logical area × bpp misses alignment: masks by 11 %, the 3-D LUT by 74 %).
  Eviction still counts logical bytes, as before.
* **Visible** is what the views' last renders used. `render(…, view:)` records a view's pages, leaf
  images, effect maps and masks, and `CanvasRenderer.show` passes `renderView` (itself).
  `forgetView` drops one without waiting (a deinit'd canvas forgets itself).
* **Transient** is the next view render's peak above persistent: its output texture (the next
  `show` allocates one), the accumulators the pool would have to regrow, and map building, which
  is one effect set's intermediates (an edit) or, when effect maps or masks the view used are gone,
  all of them rebuilt at once. `transientEstimate(region:outputFormat:)` and
  `DocumentCompositor.bandTransient(width:)` give an export or flatten band's.
* **Budget.** `memoryBudget` (an engine's `memoryBudgetBytes`) caps residency at 25 %, effect maps
  and masks at 10 %, and keeps at most 2 idle accumulator heaps. Under a budget, eviction never takes
  a visible page or map. nil, the default, leaves every cap and behaviour as before.
* **Shrink.** `relieve(_ level:)` sheds every rung up to `level`; `relieve(requested:reason:)` walks
  them in order and stops once the request is met. It runs under the compositor's lock on the
  calling thread, so it waits out a render in flight and nothing it drops is in use. It never
  touches `CanvasRenderer` or the main thread. The rungs:
  1. `scratch`: the pool's heaps;
  2. `patterns`;
  3. `offscreen`: pages, leaf images, gather pages, effect maps and masks no view's last render
     used. From here until `pressureCleared()` the caches are capped at what is left, so panning
     evicts instead of growing;
  4. `lowFootprint`: render in `lowFootprintCell` (512²) cells. Accumulators shrink with the cell's
     area, pages stay put, and the pixels are identical;
  5. `effects`: every effect map and mask. The next frame rebuilds the visible ones, which the
     transient then counts, so this rung pays only while the canvas doesn't draw. The ladder
     skips it when it can't pay.

  `.run` stops at `offscreen`, so the next frame uploads no tile and rebuilds no map (AB-R-0303).
  `pressureCleared()` brings the caps and cells back lazily.
* **Release (AB-T-0260).** A rung takes entries out of the caches under the lock, so the footprint
  and `Relief.freed` fall at once. It lets go of their textures and heaps afterwards, on a utility
  queue (`MetalCompositor.releases`). Releasing them is Metal's deallocation, about 9 ms per GB of
  pages: 2.6 GB of closed documents' pages had held the lock up to 110 ms. Phys follows tens of ms
  later, and the engine credits the declared drop at once (AB-A-0169 §2). `waitForReleases()` waits
  for the queue (benches, tests). A new cache that a rung sheds must hand its old contents to
  `shed`'s `dropped`, or its deallocation is back under the lock.
* **CPU caches.** `MemoryPressureRelay` (PCFoundation) relays the system's memory-pressure events to
  registered trims: CPUCompositor's maps and masks, `DocumentLeafCache`, PCAlgo's reusable textures
  and PCEngine's smart-object stages. A warning trims each to half; critical empties them. Nothing
  listens until a host calls `MemoryPressureRelay.shared.start()`.

Measured on realistic20 at 4096² (Apple M5 Max, Release, `PCRenderBench --memory --runs 200`):

| | |
|---|---|
| Accessors after a whole-document view (pages 378.2, effect maps 99.6, masks 6.5, gather 2.4, pool 514.0, composite 128.5, levels 42.9, LUT 2.1 MiB) | 1,174.1 MiB vs the device's `currentAllocatedSize` delta 1,175.4 MiB (−0.11 %) |
| Each rung's reported shed vs the device count's fall (scratch 514.0, offscreen 316.1, effects 74.5 MiB) | equal (0.00 %) |
| `relieve` per level, no render in flight, p99 (max) | scratch 0.0, patterns 0.0, offscreen 2.4, lowFootprint 6.4 (8.5), effects 6.8 ms |
| Ladders, p99 (max) | `.run` 8.4 (8.6) ms, `.admission` 8.4 (12.3) ms |
| A run-level shrink, then the next viewport frame | 0 tiles uploaded, no map rebuilt |
| Transient vs a sampled peak (warm frame) | declared 242.7 MiB, peak 128.6 MiB (the rest is one effect set's rebuild allowance) |
| 16 GB tier (budget 12.7 GB), whole document visible, after an admission shrink | floor 657.7 MiB (visible pages 378.2, visible effects 106.0, display 173.5) + transient 274.8 = **932.6 MiB**; the next frame peaks 160.8 MiB above its settled count |
| Low-footprint frames (512² cells) | 46.0 ms warm vs 39.9 ms normal; the composite is identical |

The 16 GB-tier ladder takes `lowFootprint` (481.9 MiB of transient) and skips `effects`: with the
whole document on screen, its rebuild (maps 106 MiB plus every effect set's intermediates at once)
would cost more than it frees. At 1024² cells the same shrink leaves 1,029 MiB, which is why the
low-footprint cell is 512². Warm render speed is unchanged: 35.7 ms wall vs 35.9 ms at 0.2.0 on
the same machine.

Outside this declaration: PCAlgo's cross-run texture cache (`AlgoGPU.cachedBytes`, capped at
min(4 GiB, ¼ of `recommendedMaxWorkingSetSize`), so roughly 2.7 GB on a 16 GB Mac, an estimate not
measured here) is GPU memory too. It trims on memory
pressure, and a host can add it to its declaration and call `trimCaches(.critical)` from its
shedder (its own lock, never the compositor's).

### Releasing after the lock (AB-T-0260)

PixelAgencyEditor's tenant drill (AB-T-0253) closed seven of eight 4096² documents. An admission
asking for 107 MiB then dropped all 2.65 GB of their off-screen pages in the `offscreen` rung. That
held the lock 21–28 ms on a quiet machine and 65 ms while two builds compiled. The time was Metal's
deallocation, so it grew with the bytes dropped. `PCRenderBench --memory --closed-only` rebuilds the
case: 7 closed and 1 open realistic20 4096² documents at the 16 GB tier leave 2,664 MiB of
off-screen pages. `relieve(requested: 128 MiB, .admission)` then takes `offscreen`. That rung frees
3,406.6 MiB of declaration, or 3,920.7 MiB of persistent memory counting the 514 MiB of heaps the
next frame regrows. The device count falls by exactly that once released.

Time under the lock, 20 runs each, Apple M5 Max, Release, 0.3.0 and the fix run back to back. The
load is the 1-minute load average; the machine ran other sessions' test suites throughout:

| Load | 0.3.0, p50 / max | Fix, p50 / max | Fix: release left after the lock, p50 / max |
|---|---|---|---|
| 26–40 | 12.3 / 24.0 ms | 0.2 / 0.2 ms | 14.7 / 29.3 ms |
| ~45 | 19.2 / 49.7 ms | 0.2 / 0.2 ms | 23.8 / 34.5 ms |
| 74–100 (plus two SwiftPM builds) | 34.9 / **109.9** ms | 0.2 / 0.2 ms | 37.3 / 61.3 ms |

The rest of `--memory --runs 200`, back to back at load 26–45:
- **Rungs and ladders under the lock:** with the fix, every rung and both ladders take p99 0.1 ms
  (max ≤ 0.8 ms). 0.3.0 took offscreen p99 8.4 ms (max 11.2), effects 13.0 ms, `.run` 11.9 ms (max
  15.2) and `.admission` 8.0 ms (max 12.0).
- **Unchanged:** accessors −0.11 % against the device count, and each rung's shed equal to the
  device count's fall. A run-level shrink still uploads 0 tiles on the next frame. The 16 GB tier
  is still 932.6 MiB floor + transient, and low-footprint pixels are still identical. A warm
  whole-document render took 42.3 ms vs 0.3.0's 42.0 ms.

No quiet-machine figure: the load never fell below 18 during this work. Nothing left under the lock
scales with bytes, so the quiet case is expected at or under the 0.2 ms seen at every load. To
re-measure: `swift run -c release PCRenderBench --memory --closed-only`.

## Filter adjustment layers (AB-T-0258)

`Adjustment.filter` (PCDocument): Compositor's Grain, Add Noise, Gaussian Blur and Motion Blur
adjustment layers, a filter over the composite beneath them, live. They act like any adjustment
layer: within their group (or on their clipping base), inside their mask, at their opacity and in
their blend mode, with the depth quantisation after them. New; no photocraft counterpart.

* **Semantics (Compositor's, as `ImageExporter.render(_ snapshot:)` draws them).** Grain and Add
  Noise are Compositor's patterns (`adjust_grain`, `noise_add_at`: the same hashes, lattice and
  Box–Muller, in Float), fixed in document space by their seed: Grain's field at each pixel's
  centre in document pixels, Add Noise per document pixel. Gaussian Blur is a Gaussian of sigma =
  radius over ±⌈3σ⌉ (`CIGaussianBlur`'s, measured); Motion Blur a Gaussian along the line of sigma
  distance / √12 (the spread of an even streak; what `CIMotionBlur` with Compositor's radius
  measures on its axes), its taps read bilinearly. Both on premultiplied colour, with the backdrop
  clear past the canvas, so an opaque picture thins at the canvas edge as in Compositor (its blurs
  are deliberately not clamped there). In Normal, `AdjustMix.coverage` mixes premultiplied colour
  and coverage, so a blur spreads into clear pixels; the other modes blend colours and keep the
  backdrop's coverage (Compositor blends at full coverage and restores the alpha). Clipped to a
  base, a blur keeps the base's coverage (atop) and takes its colours from the base's own pixels;
  Compositor blurs the base made opaque, so it darkens towards the outline where this doesn't.
  `LayerGeometry.filterReach` is how far a change beneath the blurs can spread: PCEngine's damage
  grows by it.
* **Plan.** Grain and Add Noise are `.filter(FilterSpec)` on a copy of the backdrop, per pixel. A
  blur needs its backdrop past each tile and cell, so it is a `.backdropFilter(BackdropFilter)`
  carrying the backdrop's own program: the ops so far, then `.remove` / `.dropFloor` until the
  backdrop is alone. Each render runs that program once, over the region plus the blur's reach
  within the canvas, blurs the whole of it, and every tile or cell reads its part. On the root stack
  (the usual case) the program replaces the ops that made the backdrop (`pushesBackdrop`), so the
  layers below are composited once; inside a group they are composited twice. Nested blurs nest
  programs. The planner keeps layers within the document's blur reaches added up
  (`LayerGeometry.filterReach`) past the region, and a group's bounds grow by its blurs' reach.
* **Executors.** CPU: `prepare` renders each program (its tiles in parallel) and filters it.
  Metal: `prepare` renders each program first by a nested render in the plan's accumulator format
  (it waits, so everything it builds is complete), then premultiplies and blurs over the region
  (`pcr_blur_h` / `pcr_blur_v`, or `pcr_blur_motion` with taps precomputed as whole steps and
  fractions, so where a render starts never changes a sample), and cells read the result through
  `pcr_draw_leaf`. A `.filter` blur (never planned) is CPU-only.
* **Parity, GPU vs CPU** (`FilterAdjustmentTests`, 143 renders: 11 settings × 8/16/32-bit, masked,
  four blend modes, isolated and pass-through groups, clipped, three filters stacked, Lab): every
  blur, Grain and uniform Add Noise render is **identical** (0). Gaussian Add Noise takes libm's
  log and cos against Metal's precise ones, an ulp apart: a pixel on a rounding edge flips one 8-bit
  level (2 of the 143 renders), one 16-bit step at 16 bits, 8·10⁻⁵ levels at 32. In Lab documents Grain and Add Noise go through display RGB
  and back, where PCRender's CPU and GPU Lab conversions differ (cbrt and pow): up to 2.6 levels,
  against 3.8 for Hue/Saturation on the same document. Any region, band, tile or cell equals the
  same pixels of the whole canvas's render, exactly.
* **Against Compositor** (PCIO's `CompCorpusTests`, its own 64² oracles, premultiplied 8-bit):
  Add Noise 0 levels, Grain 1, Gaussian Blur 2.54 (30 px over 2: `CIGaussianBlur`'s approximation),
  Motion Blur 1.83, and the motion set 1.52 (0°) and 2.00 (90°). Off the axes `CIMotionBlur` is not
  a Gaussian streak (an impulse sums to 0.91–1.13 instead of 1 and spreads across the line), so
  short diagonal streaks differ most at sharp edges: 45°/20 px 13 levels (115 px over 2), −30°/25 px
  7 (76 px), 60°/4 px 34 (806 px); means ≤ 1.03 levels.
* **Cost** (release, warm, M5 Max, `PCRENDER_FILTER_BENCH=1 swift test -c release --filter
  FilterAdjustmentTests/bench`; a 4096² two-layer document, 11.8 ms on the GPU without a filter):
  Grain +4.4 ms, Gaussian Add Noise +2.3 ms, Gaussian Blur radius 10 +37 ms, radius 50 +79 ms,
  Motion Blur 45°, 40 px +41 ms; the CPU reference over 1024², 3 ms bare: +3, +10, +19, +81, +21 ms.
  A blur allocates its backdrop, premultiplied and intermediate textures (rgba32Float, the region
  plus its reach) per render, outside `CanvasMemory`'s accounting: transient, but a pooled set
  would save their page mapping (about 5 ms per 4096² texture).
* **Levels of detail (AB-T-0256).** `FilterSpec.scale` is plan pixels per document pixel: blur
  lengths and reach multiply by it, Grain reads its field in document units at level pixel centres,
  Add Noise hashes level pixels with a seed of the level and scales its spread by it (a level pixel
  averages 1/scale² document pixels). When `RenderPlan.atLevel` lands, `DrawOp.atLevel` maps
  `.filter(f)` to `f.atLevel(level)`, and `.backdropFilter(b)` to its spec `atLevel` with its
  program's ops mapped too.

## For the next phase

* PCPlatform: implement `LayerRasterizer` (CoreText / vector engine); pass it to
  `DocumentCompositor(rasterizer:)`. Misses are reported, so integration can be verified.
* PCIO's `PSDCompositeOracle.register()` fills the oracle hook; the ps-corpus results above are
  the baseline.
* ~~PCFoundation: `Blend.rgb`'s Soft Light, 32-bit ClipColor / Subtract and Blend If gray differ
  from Photoshop; PCDocument's `BlendRange.weight` ramp likewise.~~ Done 2026-10-12: foundation's
  `Blend` (Swift and PCBlend.metal) and `BlendRange.weight` / `BlendRange.gray8` now follow these
  measurements. PCRender's `PSBlend` / `PCR0Common.metal` keep their own copies because they add
  the 8-bit specifics (mid-128 Hard/Linear/Soft Light, and since phase 4 the whole-level
  Hue / Saturation / Color / Luminosity of `PSBlend.nonSeparable8`); they could delegate the shared
  cases. Foundation's 8-bit callers (painting with these modes) would want `nonSeparable8` too.
* ~~PCEngine: the built-in Cone contour marks its middle point as a corner.~~ Done in phase 5 with
  the re-measured presets (Cone smooth); their upper halves await a Range 50 % render.
* PCRender's Precise glow: Photoshop's outer ~29 px fade (min(C(v), E(d)), phase 5 item 3) and its
  approximate distance off the diagonals.
* Engine: drive `DocumentCompositor` (or `MetalCompositor.render(into:)` for a reused display
  texture) and `CanvasRenderer`; damage-limited redraws via `LayerGeometry.changeBounds` and
  `renderReduced(damage:)`.
