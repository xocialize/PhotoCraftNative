# PCPaint — port notes

Port of **photocraft-paint** (`crates/paint`, ~7.6 K lines of Rust, MIT OR Apache-2.0, © ArtCraft
Team and the PhotoCraft contributors) to Swift 6 + Metal for macOS 26+. Depends only on
`PCFoundation`.

**Status:** the whole crate is ported: brush model, presets, dynamics, the CPU reference
rasteriser/compositor, the frozen scalar reference, Mixer Brush, Color Replacement, Background
Eraser, retouch machinery, symmetry and cursor outlines. The clone/heal/history sampling sequence
the engine drives on top of `retouch.rs` was added too. A Metal renderer runs the same strokes
**bit-identically** to the CPU reference: same pixels, single pass or symmetry, live tail previews
included. `swift build` and `swift test` are clean (no warnings): 117 tests in 24 suites, ~50 s
wall in debug (2026-10-12, after PCFoundation's Debug-speed work; ~90 s before).

## File map

| Swift (`Sources/PCPaint/`) | photocraft source | Notes |
|---|---|---|
| `Brush.swift`, `BrushCoding.swift` | `brush.rs` | Model plus serde-compatible Codable: camelCase keys, `#[serde(default)]` per section, externally tagged enums, the `pressure_size`/`pressure_opacity` aliases, `square` omitted when off, loaded stored tiles encoded as their bitmap, blend modes as photocraft names (`"LinearDodge"`). |
| `Paint.swift` | `lib.rs` | `StrokePoint`, `Stroke`, `Dab`, `dabs()`, `tipFalloff`, `halfCoverageRadius`, `dabCoverage`, `applyStroke`, `smooth`. |
| `Dynamics.swift` | `dynamics.rs` | Smoother (exponential/time-based/pulled string), PathWalker (spacing, speed spacing, pixel grid, airbrush), DabBuilder/DualBuilder, DabGenerator. |
| `Render.swift` | `render.rs` | BrushContext, `rasterizeInto` (with the computed-tip fast path), CoverageMap, StrokeRenderer (incremental composite, tail preview, `compositeUnionMany/Live`), StrokeCompositor, `renderStroke`. |
| `RenderReference.swift` | `render_reference.rs` | The frozen scalar oracle, kept as frozen. It still uses `maskCombine` for per-tip texture where production uses `textureCombine`; the two differ only for Subtract, Color Dodge/Burn and Height/Linear Height. |
| `MetalStrokeRenderer.swift`, `Shaders/PCPaint.metal` | (new) | GPU dab accumulate and composite kernels. |
| `StrokeSession.swift` | architecture §4.3/§6 | `PointerEvent` → `PaintStroke` → `StrokeUpdate` damage → `StrokeTransaction`. |
| `Presets.swift` | `presets.rs` | 36 built-ins in 4 groups. |
| `Procedural.swift` | `procedural.rs` | Patterns and generated tips. |
| `Tile.swift` | `tile.rs` | GrayTile (base64 LE u16 or float array), StoredTile, Mips, PatternImage, Base64. |
| `RNG.swift` | `rng.rs` | SplitMix64 counter hashes, streams. |
| `Mixer.swift` | `mixer.rs` | |
| `Replace.swift` | `replace.rs` | |
| `BackgroundEraser.swift` | `bg_erase.rs` | |
| `Retouch.swift` | `retouch.rs` | Region, Footprint, strokeCoverage, applyCoverage, applyDabStroke, mixBack, Smudge. |
| `CloneSource.swift` | engine `retouch_cmds.rs`, `presets/clone_source.rs` | CloneMapping (translation or affine resample), CloneSource (aligned anchor), cloneStamp, healingBrush (the Poisson solver is injected), historyBrush, LiveRetouch. |
| `Symmetry.swift` | `symmetry.rs` | |
| `Outline.swift` | `outline.rs` | Plus `tipOutlinePath` → `CGPath` for the cursor overlay. |
| `PixelOps.swift`, `Numerics.swift` | raster `to_rgba`/`from_rgba`, Rust numeric semantics | See "Numerics". |
| `Sources/PCPaintBench/main.swift` | `examples/bench_brush.rs` | Release benchmark. |

Tests (`Tests/PCPaintTests/`): `BrushTests` (all of `brush_tests.rs`), `LibTests` (lib, rng, tile,
procedural, symmetry, outline and presets tests), `RenderReferenceTests`, and `ToolTests`
(retouch, mixer, replace and bg_erase tests) are ports. `MetalParityTests` and `SessionTests` are new.

## Numerics

Rust semantics are spelled out once in `Numerics.swift`, because Swift's own conversions trap where
Rust saturates:

- `clampR`: Rust `f32::clamp`, which lets NaN pass through.
- `minR`/`maxR`: IEEE minNum, which ignores a NaN operand.
- Saturating `as` casts: NaN becomes 0.
- `rem_euclid`/`div_euclid`, saturating `i32` arithmetic, and Rust's `to_degrees`/`to_radians` constants.

The hostile-input tests (NaN or infinite dab fields, huge scatter, far centres) pass. Integer-format
writes go through `Surface.writeRegionSafe`, which stores NaN as 0 the way Rust does (see FCR 1).

## Metal renderer

**Stroke-local tiles.** The stroke buffer is pooled 64×64 `r32Float` tiles in shared `MTLBuffer`s,
one plane each for coverage, wet-edge depth, per-dab native colour and dual-brush coverage. Only
touched tiles exist. Buffers were chosen over `MTLTexture` because they are CPU-visible without a
blit, they grow in place, and access costs the same on unified memory.

**Accumulate (`pcp_accumulate`).**
- Per batch, the CPU builds `PcpDab` records with exactly the per-dab set-up `rasterizeInto` does
  (trig, grid snapping, mip level, rectangle). It also builds per-tile dab bins in stroke order.
- Grid is 4096 × tiles. Each thread owns one pixel and walks its tile's bin in order, applying
  build-up (`c ← c + v·(ceil − c)`), the deepest wet-edge depth and the per-dab colour mix.
- Order is preserved, so there are no atomics and no races. Dual-brush dabs use the same kernel on
  their own pool.

**Composite (`pcp_composite`).**
- The pre-stroke 256² surface tiles (and the selection) are staged into a shared buffer.
- The kernel composites in place for every dirty coverage tile ∩ stroke bounds: stroke masks (wet
  edges, dual, texture), opacity × selection, Dissolve, erase, lock transparency, per-dab colour,
  Normal "over" in native channels or any blend mode via PCBlend's `pc_composite`, then the 8-bit
  dither and quantisation.
- The clipped rows are copied back into the target's tiles.
- Normal, Dissolve and erase run on the GPU in every colour model. Other blend modes run on the GPU
  in RGB and Gray. In CMYK and Lab they composite on the CPU from the GPU coverage
  (`cpuCompositeFallbacks`), because the managed CMYK transform is CPU-only.

**Symmetry.** Up to four passes share the pools, keyed (pass, tile). The kernel merges them per
pixel exactly as `CoverageMap.unionMax` does: first tile whole, later passes where greater, with
their colour, and the deepest depth.

**Live preview (`compositeLive`).**
- Copies the tiles that each pass's smoothing tail touches into scratch slots with a blit, and
  renders the tail dabs there.
- Composites with those slots and restores the previous tail's pixels.
- The result is exactly what `StrokeRenderer.compositeUnionLive` (and so `finish` + composite)
  gives.

**Bit-exactness.** I measured the GPU's float arithmetic against Swift on 1 M random inputs (M5 Max):

| Operation | Mismatches vs Swift |
|---|---|
| `x / y` | 0 (correctly rounded in safe mode) |
| `sqrt` | 32 % differ |
| `precise::sqrt` | 0 |
| `a * b + c` | 26 % differ (contracted to FMA) |
| `a * b + c` with `#pragma METAL fp contract(off)` | 0 |

So PCPaint compiles its library (key `pcpaint.shaders.v2`) as `#pragma METAL fp contract(off)` +
PCBlend.metal + PCPaint.metal, and uses `precise::sqrt`. The kernels also repeat the Swift reference's
operation order and `clamp` (NaN-passing) semantics.

## Parity (GPU vs CPU reference)

`MetalParityTests` renders the same chunked strokes through both renderers and compares the raw
stroke buffers (coverage, depth, colour, dual) and the composited pixels. The brief allowed up to
1/255 at 8-bit; every comparison is exact (difference 0):

- **Brushes (28 configurations).** Soft and hard round, small-tip area sampling, Pencil, 1 px Pencil,
  Block, Shape Dynamics (size/angle/roundness jitter, flips), Tilt Scale + Brush Projection,
  scatter/count, Transfer, sampled tips (normal, tiny, aliased), Noise, Wet Edges, stroke texture at
  scale ≠ 1 and = 1, per-tip Height texture with depth jitter, Dual Brush (round and sampled), Color
  Dynamics, erase, Dissolve, Multiply, Color, smoothing, airbrush, and everything at once.
- **Formats.** RGBA8/16/32f, RGB16 with no alpha, GrayA8, Gray8, Gray32f, CMYKA8, CMYKA32f, LabA8:
  0 differing samples.
- **Selection and lock transparency.** 0 differing.
- **Symmetry.** Dual, vertical and diagonal (rotated) passes, live after every chunk and finished:
  0 differing, including the CMYK CPU-fallback composite.
- **Live tail preview.** Equals finishing the stroke at that point, in both RGBA8 and RGBA32f.
- **Benchmark stroke** (4096² RGBA8): 0 of 67,108,864 bytes differ.
- **Presets.** `metalOneShotRenderEqualsTheCPUReference` renders all 36 built-ins byte-identically.
- **Fast path vs frozen reference.** The CPU fast path matches the frozen scalar reference bit for
  bit (`RenderReferenceTests`, ported).

## Benchmark

Command: `swift run -c release pcpaint-bench 7` (or `.build/out/Products/Release/pcpaint-bench 7`).

Setup: a 2,000-dab stroke with a 200 px soft brush (hardness 0, flow 0.6, Shape Dynamics: size
jitter 35 %, angle jitter 50 %, roundness jitter 40 % / min 60 %) on a materialised 4096² RGBA8
layer, 1,080 points. Times are the minimum of 7 warm runs after a warm-up, on an M5 Max shared with
other builds:

| | CPU reference | Metal | Speed-up |
|---|---|---|---|
| One-shot: dabs + accumulate | 201 ms | 5.4–7.1 ms | |
| One-shot: composite | 43 ms | 5.1–5.6 ms | |
| **One-shot total** | **245 ms** | **10.5–12.7 ms** | **~20×** |
| 16-point chunks, composite after each: total | 264 ms | 25–26 ms | ~10× |
| 16-point chunks: worst chunk | 12.1 ms | 1.9–2.1 ms | |

The first run, taken while other packages were building, measured CPU 460 ms against GPU 13.3 ms.
The GPU's chunked total is dominated by one wait per chunk, which suits a canvas that composites
once per frame.

## Canvas API (how a tool uses it)

```swift
let stroke = try PaintStroke(brush: b, layer: layerSurface, selection: sel, lockTransparency: lock,
                             zoom: viewZoom, symmetry: sym, backend: .auto)   // Metal when available
let u = try stroke.feed(coalescedPointerEvents)  // StrokeUpdate: damage rect + 256² tiles to re-upload
// draw stroke.surface's u.tiles; stroke.smoothingString for the lazy-mouse line
while stroke.wantsTime { try stroke.tick(timeUs: now) }   // airbrush build-up, smoothing catch-up
let txn = try stroke.end()   // StrokeTransaction: before/after tiles (shared storage); undo(&s)/redo(&s)
```

`PointerEvent` carries the architecture §4.3 fields: position, pressure, tilt, twist, time in µs,
buttons, mods and kind. A mouse reports full pressure and no tilt.

Lower-level entry points:

- **Renderers.** `StrokeRenderer` (CPU) and `MetalStrokeRenderer` (GPU), each with
  `push`/`finish`/`composite(all:)`. The CPU renderer also has `compositeUnionLive`; the GPU one has
  `compositeLive` and `push(passes:)`.
- **One-shot.** `renderStroke`, `renderStrokeMetal`, `dabs(Stroke)`.
- **Tools.** `MixerBrush.apply`, `ColorReplacement.apply`, `BackgroundEraser.apply`,
  `Retouch.cloneStamp` / `healingBrush(solver:)` / `historyBrush` / `applyDabStroke` /
  `applyCoverage`, `Smudge`, `LiveRetouch`.
- **Cursor and geometry.** `BrushOutline.tipOutline` / `tipOutlinePath`, `gridSquare` (Pencil
  cursor), `PresetSymmetry` (reflected passes, axis segments), `BrushPresets.builtin()`.

## What's left

- **Sequential-dab tools are CPU only.** These are the Mixer Brush, Color Replacement, Background
  Eraser, Smudge, and `applyDabStroke` for Dodge/Burn/Blur. Each dab reads the previous dab's
  result, so a GPU version needs one dispatch per dab.
- **The Healing Brush needs a solver.** It takes the seamless-clone solve as a closure, because
  photocraft-algo's `poisson::seamless_clone` belongs to PCAlgo.
- **Clone sources.** Clone Source W/H/rotation is supported via `CloneMapping.transformMatrix`; the
  multi-slot Clone Source panel state is engine/tool state.
- **Staging copies.** The GPU composite stages pre-stroke tiles through CPU `memcpy`. A
  layer-resident tile cache (PCRender, keyed by `Tile.generation`) would remove those copies.
- **`PaintStroke.end()`** recomposites the finished stroke from the pre-stroke pixels. That is cheap
  on the GPU (~5 ms for the benchmark) and costs ~40 ms on the CPU.
- **Out of photocraft-paint's scope, so not here:** `.abr` import (photocraft-psd), pressure curves
  (platform/tools), and Photoshop's erodible/bristle tip kinds (not in photocraft either).

## Document CMYK profiles

A stroke converts its colour into a CMYK target through PCFoundation's `ColorConvert`, which now
consults a task-local converter (`ColorConvert.withCMYK`, photocraft `with_cmyk_space`) before the
process-wide one; PCEngine enters the document's own CMYK profile around `paint.*` commands and live
strokes. PCPaint needed no change: it runs on the caller's task (no `DispatchQueue` fan-out that
would lose the scope). `CMYKSpaceTests.parallelStrokesUseTheirTasksConverter` strokes in four
parallel tasks with two converters.

## Foundation change requests

1. **`writeSample` traps on NaN.** For integer formats, `UInt8(Float.nan)` traps, while photocraft's
   `as` saturates (NaN → 0). Please make it saturating. PCPaint routes its writes through
   `Surface.writeRegionSafe` until then.
2. **Compile with `#pragma METAL fp contract(off)`.** Please add it to `MetalContext.library` (or
   expose the compile options), and recommend `precise::sqrt` to MSL ports. Measured: default
   contraction makes 26 % of mul-adds differ from Swift and default `sqrt` 32 %. With both changes,
   ports can be bit-exact rather than within 1/255 (PCBlend's own parity test would tighten too).
3. **raster/geom conveniences.** `Surface.rgba(x,y)`, `sampleChannel`, a resizing
   `readRegion(_:into:)` (it currently requires a pre-sized buffer), and saturating
   `PixelRect.inflate`/`translate`. PCPaint has local extensions for these.

## Credits

Ideas only, from Compositor v1.5 (MIT, © 2026 Wonder Assembly LLC):

- Stroke-local GPU tile storage with no full-canvas allocation, and a replaceable live tail kept
  apart from permanent paint.
- Aligned/non-aligned Clone Stamp behaviour, reviewed against photocraft's clone-source mapping.

No Compositor code was copied. All maths follows photocraft.
