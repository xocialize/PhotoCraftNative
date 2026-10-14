# PCAlgo — port notes

Port of **photocraft-algo** (`crates/algo/src`, Rust, MIT OR Apache-2.0, © ArtCraft Team and the
PhotoCraft contributors) to Swift 6 + Metal: Photoshop's Filter menu and the image algorithms
behind it. Every filter is a `Filter` with Codable parameters mirroring photocraft's
`FilterParams`, a halo, a **Swift CPU reference on `FloatImage`** (the spec: photocraft's maths,
order of operations and edge semantics) and a **Metal compute path that must match it**.

## Status (2026-10-12)

* **73 filter types** registered in `AnyFilter` (every Filter-menu filter photocraft-algo implements,
  plus Camera Raw, Lens Correction and Filter Gallery as filters; Filter Gallery covers all **47**
  effects) and **~45 non-filter operations** (resampling and transforms, Liquify, mesh /
  perspective / puppet / wide-angle warps, selection and segmentation, inpainting and content-aware
  fill, seam carving, alignment / panorama / pyramid blending, stack modes, retouch, tone analysis,
  procedural render).
* **GPU paths are parity-tested against their CPU references:** 266 parity records, 165 of them
  bit-exact, 240 ≤ 1e-6; worst 1.03e-4 (Feather’s cosine series), then GMM data costs 6.2e-5,
  `Lens.correct` dense 4.3e-5, Lighting Effects 4.1e-5. Tolerance 1/255.
* `swift build` / `swift test` from `Packages/PCAlgo`: **665 tests in 101 suites pass**, no known
  issues, no warnings (Debug, ~10 min for the full run on a loaded machine). Stress
  (`PCALGO_STRESS=1`), perf (`PCALGO_PERF=1`) and probe (`PCALGO_PROBE=1`) suites are opt-in.
* 121 Swift files + 43 MSL files (251 `pca_` kernels), ~45 k lines; ~14 k lines of tests.

## Public API

| Entry point | What it does |
|---|---|
| `protocol Filter` (`Codable, Sendable`) | `label`, `halo(bounds:)`, `cpu(_:out:ctx:)`, `encodeGPU(_:)`, `gpuChannels`, `supportsGPU(_:channels:)`, `processesWholeArea` |
| `FilterEngine.apply(_:to: FloatImage, output:context:coverage:on:)` | One filter over a float image (source = output grown by the halo; samples outside read 0), mixed with the original by a per-pixel selection coverage; `on: .cpu / .gpu / .auto` |
| `FilterEngine.apply(_:to: inout Surface, area:bounds:selection:extent:on:tile:)` | Surface-level convenience: reads the halo'd region (repeating the canvas `extent`'s edge, as Photoshop does for layers), runs per tile (whole area for running-sum blurs on the CPU and for global filters), mixes by the selection's channel 0, writes back (photocraft `apply` / `apply_in`) |
| `FilterEngine.applyMeasured` / `FilterRunStats` | Same, with wall-clock and GPU command-buffer time |
| `FilterEngine.outputArea(_:content:bounds:selectionBounds:)` | photocraft `output_area` |
| `FilterEngine.mixSelection(original:filtered:coverage:alpha:)` | photocraft `mix_selection` (premultiplied where the filter changed alpha) |
| `AnyFilter` | photocraft's tagged `FilterParams` JSON (`{"filter":"gaussianBlur","radius":2}`) for every registered filter |
| `FilterContext(bounds:mode:alpha:)`, `Halo`, `Backend`, `GPUChannels`, `FilterError` | the contract types |
| `AlgoGPU.shared()`, `GPUPass` (+ `GPUPass.synthetic`) | the shader library / pipeline / texture caches and the per-plane encoder filters and non-filter operations use |
| Non-filter APIs | `Resample`, `Transform`/`Homography`, `MeshWarp`, `PerspectiveMap`, `Liquify`; `ToneKit` (replace/match colour, HDR toning, shadows/highlights, HDR merge/tone map, Camera Raw `develop`), `RgbHistogram`, `Quantize`; `Poisson`, `Retouch`, `Selection` (wand, ranges, modify, feather, lasso, marquee), `SeamCarving`, `QuickSelection`, Segment (`SelectSubject`/`SelectSky`/`FocusArea`/`GrabCut`/`SLIC`/`Matting`/`MagneticLasso`/`MagicEraser`/`PaintBucket`), `InpaintKit` (content-aware fill, completion, proximity match, remove, create texture), `LensCorrection`/`Lens`, `WideAngle`, `Puppet`, `VanishingPoint`, `Pyramid`, `Features`, `DirectAlign`, `Panorama`, `ScanCrop`, `Exif`, `Stack`, `Trap`, `Vectorscope`, `GradientTool`, `RedEye`, `RenderProc` (Flame, Picture Frame, Tree) |

## Design

* **Planes.** The GPU works on `rgba32Float` planes: up to three colour channels in `.xyz` with
  alpha in `.w`, or four colour channels without alpha. CMYK + alpha is two planes, each carrying
  alpha, so channel-independent filters (`.perChannel`) run for any channel count; filters that
  use colour channels together (`.joint`: luma, hue, thresholds across channels) need one plane of
  a Gray- or RGB-like model and fall back to the CPU otherwise under `.auto`.
* **Frame.** Every kernel gets `pca_frame` (source/output/bounds rectangles in document
  coordinates, alpha flag, model, plane channels) at buffer 0; `pca_get` reads 0 outside the
  source exactly as photocraft's `Image::get`; `pca_sample` is `Image::sample` (premultiplied
  bilinear with edge policies); `pca_hash01` is photocraft's coordinate hash bit for bit, so seeded
  noise is identical on both backends and independent of tiling.
* **Arithmetic parity.** The library is compiled with `mathMode = .safe`, **precise**
  transcendental functions, and `#pragma METAL fp contract(off)` (`.safe` still fuses `a*b + c`
  into FMA, which the Swift references never do). Angles use Rust's `std::f32::consts` values
  (`PCAMath.pi` — Swift's `Float.pi` is one ulp low). MSL's `fmod` is replaced by an exact one.
  Running sums on the GPU are TwoSum-compensated (photocraft sums several of them in f64), so they
  return exactly to zero after bright runs instead of leaving colour garbage under ~0 alpha; row
  prefix sums (Shape / Lens Blur) are compensated float pairs (~48 bits, photocraft uses f64).
  Many kernels are bit-exact (parity 0).
* **Other colour models.** CMYK + alpha splits into two planes for channel-independent filters.
  Filters whose reference works in straight sRGB (`to_rgba` in, `from_rgba` out — 16 of them,
  each verified by `RGBAEquivalenceTests`) declare `rgbaEquivalent`; CMYK and Lab documents then
  run on the GPU as their sRGB conversion (converted on the CPU with the same functions the
  reference calls, including the installed ColorSync CMYK converter).
* **Sources.** A source that doesn't cover the output grown by the halo is padded with
  transparency by the engine (the documented "reads outside are 0" contract), so direct callers get
  the same numbers on both backends.
* **Memory.** Intermediates come from a per-pass pool and a cross-run cache (fresh private
  textures must be zero-filled by the OS, which cost more than most kernels); staging buffers are
  reused; uploads/readbacks are parallel copies. A 4096² RGBA float image round-trips in ~3–5 ms.
* **CPU.** References run rows in parallel (`DispatchQueue.concurrentPerform`), results never
  depend on scheduling, and they are bit-identical whatever the tiling (photocraft's contract,
  tested at tile sizes 7 and 256). The GPU is tile-independent to float rounding (≤ 2e-6).

## Filters

Parity = worst max |GPU − CPU| of premultiplied samples over Gray, Gray+A, RGB, RGBA and CMYK+A
deterministic 8-bit images and several parameter sets (tolerance 1/255 ≈ 3.9e-3); 0 means
bit-identical. Release timings follow the table.

| Area | Filter / operation | photocraft source | Swift | MSL kernels | Parity | Notes |
|---|---|---|---|---|---|---|
| Blur | Gaussian Blur | blur.rs `gaussian`, `conv_sep`, `boxes_for_gauss`, `box_blur` | Blur/BlurCore.swift, GaussianBox.swift | pca_conv_h/v, pca_box_pass, pca_box_direct | 8.34e-07 | σ ≤ 4 exact kernel; above, three Kovesi box passes with repeated edges (whole area at once on the CPU, as `apply_box_blur`) |
| Blur | Box Blur | blur.rs `boxed` | Blur/GaussianBox.swift | pca_conv_h/v, pca_box_pass, pca_box_direct | 4.77e-07 | running sums above radius 4 |
| Blur | Blur / Blur More | engine filters.rs presets | Blur/GaussianBox.swift | (Gaussian) | 0 | Gaussian σ 0.6 / 1.4 |
| Blur | Motion Blur | blur.rs `motion`, `motion_offsets` (motion_fft.rs = CPU-only speed path) | Blur/MotionRadial.swift | pca_motion_blur | 0 | merged bilinear taps in first-seen order |
| Blur | Radial Blur (spin/zoom, draft/good/best) | blur.rs `radial`, `average_samples`; blur/radial.rs `Plan` | Blur/MotionRadial.swift | pca_radial_blur | 0 | CPU-built sin/cos tables shared by both paths |
| Blur | Surface Blur | blur.rs `surface`, `surface_direct` (8-bit/ranked paths agree ≤1e-5) | Blur/SurfaceBlur.swift | pca_surface_blur(_tg) | 0 | threadgroup-tiled for r ≤ 8 |
| Blur | Smart Blur (normal/edge only/overlay) | blur2.rs `smart_blur` | Blur/SmartAverage.swift | pca_smart_blur | 0 | joint (threshold across colour channels) |
| Blur | Average | engine extra_cmds.rs `average` | Blur/SmartAverage.swift | pca_average_partial/total/fill | 5.96e-08 | alpha-weighted mean (CMYK/Lab through the sRGB round trip) |
| Blur | Lens Blur (iris, specular boost, depth, noise) | blur2.rs `lens_blur`, `Spans`, `Prefix` | Blur/ShapeLens.swift | pca_row_prefix, pca_lens_boost, pca_lens_blur | 4.77e-07 | compensated float-pair prefix sums (photocraft: f64) |
| Blur | Shape Blur (9 shapes, ≤1000 px) | shape_blur.rs, blur2.rs `shape_inside` | Blur/ShapeLens.swift | pca_row_prefix, pca_shape_blur | 1.19e-07 |  |
| Blur Gallery | Tilt-Shift | gallery.rs `tilt_shift`, `variable_blur` | Blur/Gallery.swift | pca_premul_copy, pca_gal_sigma, pca_gal_accum (+ box passes) | 5.96e-08 | 7-level σ stack; trimmed levels proven bit-identical |
| Blur Gallery | Iris Blur | gallery.rs `iris`, `PreparedIris` | Blur/Gallery.swift | same | 1.79e-07 |  |
| Blur Gallery | Field Blur | gallery.rs `field` | Blur/Gallery.swift | same | 5.96e-08 |  |
| Blur Gallery | Spin Blur | gallery.rs `spin`, gallery/spin_plan.rs | Blur/Gallery.swift | pca_spin_blur | 0 |  |
| Blur Gallery | Path Blur | gallery.rs `path` | Blur/Gallery.swift | pca_path_blur | 0 |  |
| Sharpen | Unsharp Mask | sharpen.rs `unsharp`, `with_blur` | Sharpen/Sharpen.swift | pca_conv_h/v, pca_sharpen_combine | 0 |  |
| Sharpen | Smart Sharpen (basic) | sharpen.rs `smart` | Sharpen/Sharpen.swift | same | 1.19e-07 |  |
| Sharpen | Sharpen / Sharpen More / Sharpen Edges | engine filters.rs presets | Sharpen/Sharpen.swift | same | 0 | USM 60/0.5/0, 150/0.6/0, 100/0.8/6 |
| Other | High Pass | sharpen.rs `high_pass` | Sharpen/Sharpen.swift | same | 0 |  |
| Other | Minimum / Maximum (square, round) | other.rs `min_max`, `min_max_round`, `running_extreme` | Other/Other.swift | MPSImageAreaMin/Max; pca_minmax_round (pca_minmax_h/v fallback) | 0 | exact |
| Other | Offset | other.rs `offset` | Other/Other.swift | pca_offset | 0 | exact |
| Other | Custom (5×5) | other2.rs `custom` | Other/Other.swift | pca_custom | 0 |  |
| Noise | Add Noise (uniform/gaussian, mono) | noise.rs `add`, `hash01` | Noise/Noise.swift | pca_add_noise | 4.77e-07 | hash bit-identical |
| Noise | Median | noise.rs `median_ranked`, `median_direct` | Noise/Noise.swift | MPSImageMedian (r 1, no alpha); pca_median_tg / pca_median (total-order bisection) | 0 | exact (same sample) |
| Noise | Dust & Scratches | noise.rs `median` + threshold | Noise/Noise.swift | same + pca_median_threshold | 0 | exact |
| Noise | Despeckle | engine preset (Surface Blur 2/12) | Noise/Noise.swift | (Surface Blur) | 0 |  |
| Noise | Reduce Noise | denoise.rs `reduce_noise`, `guided` | Noise/ReduceNoise.swift | pca_rn_decompose/jpeg/moments/ab/apply/sharpen/compose (+ box passes) | 2.09e-07 | Gray/RGB/Lab on GPU; CMYK via sRGB on CPU |
| Distort | Twirl / Pinch / Spherize | distort.rs `twirl`, `pinch`, `spherize`, `remap` | Distort/Distort.swift, DistortKit.swift | pca_dis_twirl, _pinch, _spherize | 5.13e-06 / 3.99e-06 / 3.81e-06 | global (bounds); `Image::sample` remap |
| Distort | Wave / Ripple / Polar Coordinates | distort.rs `wave`, `ripple`, `polar` | Distort/Distort.swift | pca_dis_wave, _ripple, _polar | 9.51e-06 / 5.96e-06 / 3.49e-06 | exact fmod / atan2 / sqrt twins for hard edges |
| Distort | Displace / Shear / ZigZag | distort2.rs | Distort/Distort2.swift | pca_dis_displace, _shear, _zigzag | 0 / 0 / 7.51e-06 | map supplied by the caller (not encoded) |
| Render | Fibers / Lens Flare / Lighting Effects | render.rs | Render/Render.swift | pca_ren_fibers, _lens_flare, _lighting | 0 / 2.5e-06 / 4.1e-05 | joint: Gray/RGB on GPU |
| Render | Clouds / Difference Clouds | engine extra_cmds.rs `clouds_value` | Render/Clouds.swift | pca_ren_clouds | 0 |  |
| Render | Relight | relight.rs | Render/Relight.swift | pca_ren_relight_luma, _shade | 3.58e-07 | bounds-dependent halo |
| Stylize | Mosaic / Emboss / Find Edges / Solarize / Invert / Desaturate | stylize.rs | Stylize/StylizeBasic.swift | pca_sty_mosaic_*, _emboss, _find_edges, _per_pixel, _desaturate | 2.65e-06 / 0 / 0 / 0 / 0 / 0 |  |
| Stylize | Diffuse / Tiles / Trace Contour / Wind | stylize2.rs, stylize2/wind.rs | Stylize/Stylize2.swift, Wind.swift | pca_sty_diffuse, _tiles, _trace_contour, _wind* | 0 / 0 / 0 / 0 |  |
| Stylize | Extrude | stylize2/extrude.rs | Stylize/Extrude.swift | pca_sty_extrude_* | 0 | each cell once |
| Stylize | Oil Paint | oil.rs | Stylize/OilPaint.swift | pca_sty_oil_*, pca_sty_box_ff | 3.58e-06 | float-float blurs (strokes follow thresholds) |
| Stylize | Glowing Edges | artistic_fx.rs `GlowingEdges` | Stylize/GlowingEdges.swift | pca_sty_glow_* | 5.96e-08 | bit-identical to the gallery's Glowing Edges |
| Pixelate | Color Halftone / Crystallize / Facet / Fragment / Mezzotint / Pointillize | pixelate.rs (+ facet, screen) | Stylize/Pixelate.swift | pca_sty_halftone*, _crystal_*, _facet*, _fragment, _mezzotint, _pointillize | 0 / 0 / 0 / 0 / 0 / 0 | per-cell work once |
| Filter Gallery | 47 effects (Artistic, Brush Strokes, Distort, Sketch, Stylize, Texture) as a stack | artistic.rs, artistic_fx.rs | Gallery/*.swift | pca_gfx_* | 2.15e-06 (worst of 49 cases) | float-float line blurs keep thresholds identical |
| Other / Tone | HSB/HSL, De-Interlace, NTSC Colors, Color to Alpha | other2.rs, video.rs, color_to_alpha.rs | Tone/HsbHsl.swift, Video.swift, ColorToAlpha.swift | pca_tone_hsbhsl, _deinterlace, _ntsc, _color_to_alpha | 0 / 0 / 0 / 0 |  |
| Tone | Replace Color, Match Color, HDR Toning, Shadows/Highlights | tone.rs, tone/shadows_highlights.rs | Tone/ToneAdjustments.swift, ShadowsHighlights.swift | pca_tone_replace_color, _match_color, _hdr_*, _sh_* | 0 / 4.21e-06 / 1.61e-06 / 4.77e-07 | statistics on the CPU where small |
| Tone | Camera Raw develop (per-pixel stages) | camera_raw.rs; the sliders Photoshop's, fitted (AB-T-0241, below) | Tone/CameraRaw*.swift | pca_tone_camera_raw | PARITY | one lattice of the colour stages; Dehaze/Clarity/Texture/Detail stages CPU |
| Analysis | Histogram, Vectorscope | histogram.rs, vectorscope.rs | Tone/Histogram.swift, Misc/Vectorscope.swift | pca_tone_rgb_hist, pca_misc_vectorscope | 0 / 0 | atomic bins, exact |
| HDR | Merge to HDR, tone mapping (4 methods) | hdr.rs | Tone/HDR.swift, HDRGPU.swift | pca_tone_hdr_merge, _ghost_*, _tm_* | 2.91e-07 / 1.25e-06 | response recovery / MTB on CPU |
| Quantize | Palettes, nearest colour, dithering, Bitmap | quantize.rs, quantize/nearest.rs | Tone/Quantize*.swift | pca_tone_quantize, _bitmap | 0 / 0 | error diffusion / palette building CPU |
| Resample | Image Size: nearest, bilinear, bicubic (+smoother/sharper/automatic), Lanczos, Preserve Details | resample.rs | Resample/ResampleKernels.swift, ResamplePass.swift, ResampleSharpen.swift | pca_rs_resample_h/v, pca_rs_unsharp | 0 / 0 / 0 | f64 tap tables from the CPU |
| Transform | Free Transform (nearest/bilinear/bicubic), Mesh/Perspective Warp, Liquify | transform.rs, warp.rs, perspective.rs, liquify.rs | Resample/Transform.swift, MeshWarp.swift, PerspectiveMap.swift, Liquify.swift | pca_rs_warp, pca_rs_mesh, pca_rs_liquify(_field) | 3.58e-07 / 2.98e-07 / 3.93e-06 | emulated-f64 coordinate maps |
| Geometry | Lens Correction, Adaptive Wide Angle, Puppet Warp, Vanishing Point paste | lens.rs, wideangle.rs, puppet.rs, vanishing.rs | Geometry/*.swift | pca_geo_lens_map, pca_geo_lens (+ mesh warp) | 6.36e-06 / 2.98e-07 / 3.58e-07 / 3.58e-07 | solves (CGLS, ARAP) on the CPU |
| Selection | Magic Wand, Color/Hue/Tone Range, Expand/Contract/Border (EDT), Smooth, Feather, Lasso, Marquee | selection.rs, selection_blur.rs, selection/* | Selection/*.swift | pca_sel_* | 0 / 0 / 0 / 0 / 0 / 0.000103 | `.auto` = CPU for host-array APIs (transfers dominate) |
| Selection | Content-Aware Scale (seam carving), Quick Selection | seam.rs, segment/quick.rs, segment/maxflow.rs | Selection/SeamCarving.swift, QuickSelection.swift, MaxFlow.swift | pca_sel_seam_energy | 0 | DP and max-flow on the CPU |
| Segment | Select Subject/Sky, Focus Area, GrabCut, SLIC, Refine Edge (matting), Magnetic Lasso, Magic Eraser, Paint Bucket | segment/*, matting.rs (+ matting/*), magnetic.rs, erase.rs, paint.rs | Segment/*.swift | pca_seg_slic_assign, _box_*, _guided_*, _gmm_costs, _laplacian | 0 / 7.15e-07 / 6.56e-06 / 6.16e-05 / 5.96e-08 | `.auto` = CPU |
| Inpaint | Content-Aware Fill, completion (EM + PatchMatch), Proximity Match, Remove tool (non-local), Create Texture | inpaint.rs, content_aware.rs, remove.rs, nonlocal.rs | Inpaint/*.swift | pca_inp_costs, _transforms, _vote, _source_moments, _proximity | 0 / 0 | PatchMatch/onion peel/non-local on the CPU |
| Retouch | Healing (Poisson seamless clone / membrane), Dodge/Burn/Sponge/Blur/Sharpen tool kernels | poisson.rs, retouch.rs | Retouch/Poisson.swift, Retouch.swift | — (CPU) | CPU only | sequential SOR; per-dab kernels |
| Misc | Stack Mode statistics, Trap, Gradient tool, Red Eye | stack.rs, trap.rs, paint.rs (gradient), redeye.rs | Misc/*.swift | pca_misc_stack, _trap_*, _gradient | 2.98e-07 / 2.38e-07 / 0 (Trap, bit-exact) | Red Eye CPU (≤512² click window) |
| Photo | Auto-Blend (Burt–Adelson pyramids, focus stacks), Harris corners | pyramid.rs, features.rs | Photo/Pyramid*.swift, Features*.swift | pca_pho_reduce_*, _expand_*, _sobel, _box_line, … | 0 (blend, fuse, stack weights, identical corners); halo fuse 4.8e-7 | descriptors/matching/RANSAC on the CPU |
| Photo | Photomerge (panorama), Auto-Align (direct), Crop and Straighten, EXIF | panorama.rs, direct.rs, scancrop.rs, exif.rs | Photo/Panorama*.swift, DirectAlign.swift, ScanCrop.swift, Exif.swift | multiband push-pull/band kernels | 0 (multiband) | Nelder–Mead in f64 on the CPU (no f64 on the GPU) |

### Release timings

4096 × 4096 RGBA float unless the operation names a size; best of 3 after a warm-up;
`swift test -c release -Xswiftc -enable-testing` with `PCALGO_PERF=1`, one suite at a time
(`PerfTests`, `DistortPerfTests`, … `RenderProcPerfTests`). CPU = the parallel Swift reference;
GPU wall = upload + kernels + readback through `FilterEngine.apply` (or the area API); GPU kernels =
command-buffer time. Measured on an Apple-silicon Mac shared with other agents' builds (load
average 35–75), so CPU columns are pessimistic and both vary by ~±20 % run to run.

| Suite | Operation | CPU ms | GPU wall ms | GPU kernels ms | CPU / GPU wall | Notes |
|---|---|---|---|---|---|---|
| Core | GaussianBlur r2 | 159.7 | 8.8 | 5.2 | 18.1× |  |
| Core | GaussianBlur r20 | 81.7 | 12.8 | 9.1 | 6.4× |  |
| Core | BoxBlur r50 | 45.7 | 8.8 | 5.4 | 5.2× |  |
| Core | MotionBlur 30deg d40 | 178.1 | 15.3 | 11.9 | 11.6× |  |
| Core | RadialBlur spin 10 good | 9920.1 | 109.4 | 100.1 | 90.7× |  |
| Core | SurfaceBlur r5 t15 | 1015.8 | 29.8 | 26.2 | 34.1× |  |
| Core | ShapeBlur r20 hexagon | 388.4 | 30.3 | 27.0 | 12.8× |  |
| Core | LensBlur r15 | 423.9 | 20.0 | 16.7 | 21.2× |  |
| Core | SmartBlur r5 t25 | 1895.3 | 16.8 | 13.5 | 112.8× |  |
| Core | IrisBlur 15 | 1155.7 | 38.5 | 35.0 | 30.0× |  |
| Core | TiltShift 15 | 741.7 | 38.7 | 35.3 | 19.2× |  |
| Core | SpinBlur 15deg | 531.1 | 14.0 | 10.8 | 37.9× |  |
| Core | UnsharpMask r3 | 207.7 | 13.6 | 10.4 | 15.3× |  |
| Core | AddNoise gaussian | 38.9 | 7.9 | 4.8 | 4.9× |  |
| Core | Median r3 | 312.9 | 47.4 | 44.1 | 6.6× |  |
| Core | Maximum r5 round | 464.2 | 13.7 | 10.4 | 33.9× |  |
| Core | Minimum r10 square | 187.2 | 13.7 | 8.4 | 13.7× |  |
| Core | ReduceNoise default | 879.8 | 66.6 | 61.3 | 13.2× |  |
| Distort | Twirl 50 | 41.4 | 8.1 | 3.2 | 5.1× |  |
| Distort | Wave 5 gens | 133.3 | 8.2 | 3.5 | 16.3× |  |
| Distort | Lighting Effects 3 lights + bump | 116.8 | 10.1 | 4.1 | 11.6× |  |
| Distort | Relight | 283.4 | 25.5 | 21.1 | 11.1× |  |
| Tone | HsbHsl rgb→hsl | 29.3 | 8.9 | 3.6 | 3.3× |  |
| Tone | ShadowsHighlights default | 315.5 | 30.2 | 25.3 | 10.4× |  |
| Tone | HdrToning default | 135.3 | 13.8 | 9.5 | 9.8× |  |
| Tone | CameraRaw per-pixel | 287.3 | 15.1 | 10.1 | 19.0× |  |
| Resample | Resample bicubic ×0.5 | 115.9 | 36.1 |  | 3.2× |  |
| Resample | Resample lanczos ×1.5 | 337.4 | 59.5 |  | 5.7× |  |
| Resample | Transform bicubic rotate | 125.8 | 43.8 |  | 2.9× |  |
| Resample | MeshWarp bilinear wave | 109.4 | 90.6 |  | 1.2× |  |
| Resample | MeshWarp bicubic ×0.3 bend (subsampled) | 81.0 | 49.8 |  | 1.6× |  |
| Resample | Liquify forward warp | 79.2 | 9.8 |  | 8.1× |  |
| Stylize | Mosaic 10 | 16.6 | 11.4 | 6.7 | 1.5× |  |
| Stylize | Emboss | 37.8 | 9.1 | 4.2 | 4.2× |  |
| Stylize | Extrude blocks 30/30 | 121.6 | 13.1 | 7.9 | 9.3× |  |
| Stylize | Extrude blocks 2/255 | — (not timed) | 73.3 | 69.1 |  |  |
| Stylize | Wind blast | 247.0 | 10.5 | 6.5 | 23.5× |  |
| Stylize | Oil Paint | 884.9 | 89.7 | 83.4 | 9.9× |  |
| Stylize | Glowing Edges | 192.8 | 17.0 | 12.8 | 11.3× |  |
| Stylize | Color Halftone r8 | 119.8 | 13.3 | 8.5 | 9.0× |  |
| Stylize | Crystallize 10 | 78.5 | 25.1 | 18.6 | 3.1× |  |
| Stylize | Crystallize 300 | 84.6 | 37.5 | 30.9 | 2.3× |  |
| Stylize | Facet | 99.8 | 9.6 | 4.8 | 10.4× |  |
| Stylize | Pointillize 5 | 84.2 | 10.1 | 5.2 | 8.3× |  |
| GalleryFX | Gallery dryBrush | 217.0 | 42.3 | 36.9 | 5.1× |  |
| GalleryFX | Gallery watercolor | 286.1 | 27.7 | 23.0 | 10.3× |  |
| GalleryFX | Gallery angledStrokes | 294.7 | 36.9 | 31.5 | 8.0× |  |
| GalleryFX | Gallery smudgeStick | 134.4 | 16.2 | 11.5 | 8.3× |  |
| GalleryFX | Gallery glass | 139.8 | 9.7 | 5.7 | 14.4× |  |
| GalleryFX | Gallery stainedGlass | 117.6 | 9.4 | 5.3 | 12.5× |  |
| GalleryFX | Gallery craquelure | 128.6 | 17.1 | 11.4 | 7.5× |  |
| GalleryFX | Gallery notePaper | 148.4 | 41.3 | 35.9 | 3.6× |  |
| GalleryFX | Gallery glowingEdges | 522.2 | 17.8 | 13.3 | 29.3× |  |
| Geometry | LensCorrection distortion+CA+vignette | 209.5 | 14.3 | 9.6 | 14.7× |  |
| Geometry | LensCorrection perspective+angle | 201.7 | 12.8 | 9.2 | 15.8× |  |
| Geometry | AdaptiveWideAngle solve | 159.8 |  |  |  |  |
| Geometry | AdaptiveWideAngle render (bicubic) | 224.3 | 95.7 |  | 2.3× |  |
| Geometry | PuppetWarp mesh+solve | 31.5 |  |  |  | 505 verts |
| Geometry | PuppetWarp render (bicubic) | 241.4 | 92.4 |  | 2.6× |  |
| Selection | magic wand contiguous tol 40 | 13.1 | 65.5 |  | 0.2× |  |
| Selection | color range | 8.0 | 24.8 |  | 0.3× |  |
| Selection | expand 10 | 66.3 | 67.9 |  | 1.0× |  |
| Selection | smooth 8 | 7.9 | 14.5 |  | 0.5× |  |
| Selection | feather 4 | 24.3 | 18.7 |  | 1.3× |  |
| Selection | feather 25 | 23.3 | 20.5 |  | 1.1× |  |
| Selection | feather 100 | 28.8 | 38.6 |  | 0.7× |  |
| Selection | seam energy 2048x1536 | 1.4 | 4.3 |  | 0.3× |  |
| Selection | one seam DP 2048x1536 | 0.6 |  |  |  |  |
| Selection | carve 2048x1536 -> 1948x1536 (100 seams) | 156.1 |  |  |  |  |
| Selection | quick select click 2000x2000 | 26.0 |  |  |  |  |
| Selection | quick select drag 2000x2000 | 293.5 |  |  |  |  |
| Segment | guided filter colour r=8 1 MP | 54.9 | 18.0 |  | 3.0× |  |
| Segment | focus energy 1 MP | 3.1 | 4.1 |  | 0.8× |  |
| Segment | SLIC 1 MP 2000 sp | 289.4 | 147.7 |  | 2.0× |  |
| Segment | GMM data costs 1 MP | 16.7 | 4.2 |  | 4.0× |  |
| Photo | Pyramid.fuseStack halo 2.0 3× 4096x3072x4 | 599.9 | 89.0 |  | 6.7× |  |
| Photo | Pyramid.fuseStack halo 0.0 3× 4096x3072x4 | 543.9 | 79.5 |  | 6.8× |  |
| Photo | Pyramid.blend 3× 4096x3072x4 | 336.2 | 72.5 |  | 4.6× |  |
| Photo | Pyramid.stackWeights 3× 4096x3072 | 146.1 | 36.1 |  | 4.0× |  |
| Photo | Panorama.multiband 3× 2400x1900 → 6000x2000x3 | 319.3 | 92.0 |  | 3.5× |  |
| Photo | Features.harris 1200x800 | 8.0 | 4.1 |  | 2.0× |  |
| Photo | Features.describe 415 corners | 1.2 |  |  |  |  |
| Photo | Panorama.matchPairs 4 images | 6.9 |  |  |  |  |
| Photo | DirectAlign.cost one evaluation 2048x1365 | 3.2 |  |  |  |  |
| Photo | DirectAlign.register similarity 2048x1365 | 517.2 |  |  |  |  |
| Photo | ScanCrop.findPhotos 2400x1800 | 28.9 |  |  |  |  |
| RenderProc | Render flame multiple | 36.7 | 29.1 |  | 1.3× | 27051 prims, generate 2.6 ms |
| RenderProc | Render flame 1500 fine | 21.9 | 22.8 |  | 1.0× | 10086 prims, generate 1.0 ms |
| RenderProc | Render tree oak | 37.9 | 37.8 |  | 1.0× | 7800 prims, generate 0.5 ms |
| RenderProc | Render tree willow | 36.7 | 39.8 |  | 0.9× | 7804 prims, generate 0.6 ms |
| RenderProc | Render frame vine | 32.4 | 32.8 |  | 1.0× | 6112 prims, generate 0.1 ms |

Selection rows are 4096² masks through the host-array APIs (`.auto` picks the CPU there: transfers
cost more than the kernels); Segment rows are 1 MP; RenderProc composites the generated primitives
into a 6000 × 4000 RGBA8 `Surface`, where the Surface writes dominate both backends.

## Camera Raw: Photoshop's sliders, fitted (AB-T-0241)

A deliberate departure from photocraft (AB-D-0139). White balance, Exposure, Contrast, Highlights,
Shadows, Whites, Blacks, Saturation, Vibrance, the parametric curve (at its default dividers), the
Color Mixer and Color Grading are no longer photocraft's formulas but Photoshop's Camera Raw Filter's
behaviour, fitted; Calibration (the primaries' hue and saturation) is new. photocraft's Dehaze,
Clarity, Texture, point curves, Detail, vignette and grain are unchanged.

* **The model** (`Tone/CameraRawModel.swift`): each slider stop is one stage on linear ProPhoto RGB —
  a 3×3 matrix, a hue map (hue shift, saturation and value scales at 24 hues weighted by saturation,
  the DNG HueSatMap's form), a tone stage (one grey curve through the DNG SDK's hue-preserving RGB
  tone, per channel and as a luminance gain with a saturation exponent, mixed) and a tint keyed by
  lightness, each optional per slider. Between stops a slider blends its two stops' results (four for
  Temperature × Tint, and for Contrast, Highlights and Shadows, which read the picture's brightness:
  `CameraRawStatistics`, measured from the pixels unless the settings carry it). The slider logic
  (stop grids, Balance as a share of saturation, the order the stages compose in) follows
  Compositor's `CameraRawTables` (MIT).
* **The parameters** (`Tone/CameraRawModel.json`, 63,498 numbers over 698 stops, about 0.6 % of the tables' 11.2 M) are fitted values and 1-D
  curves, not colour tables (AB-D-0130). They were fitted (`Tools/CameraRawFit`) to Compositor's
  Photoshop-captured tables — 763 tables of a 17³ grid, one slider at one stop each — which no
  longer ship anywhere.
* **The run.** The colour stages compose over a 33³ lattice per develop, looked up by tetrahedral
  interpolation, the same lattice on the CPU and in Metal (`pca_tone_camera_raw` now applies the
  lattice, vignette and grain). Dehaze, Texture and Clarity sit between Calibration / Exposure / white
  balance and the rest. Float documents keep values past 1, with Exposure as a gain in linear light
  there. `ToneKit.cameraRawColors` runs the stages exactly on given colours, for a caller composing its
  own lookup (PixelAgencyEditor's panel).
* **Fit.** Measured as the gap was before fitting (AB-R-0532: every table stop, every channel of every grid colour,
  8-bit levels, through `develop` itself), p99 before → after: white balance 202 → 23.5, Exposure 204 → 6.4, Contrast
  90 → 8.4, Highlights 81 → 19.5, Shadows 40 → 10.4, Whites 66 → 15.2, Blacks 33 → 5.2, Saturation 80 → 13.5,
  Vibrance 121 → 8.5, Mixer hue 30–113 → 3.4–5.4, saturation 30–103 → 4.9–11.4, luminance 40–106 → 14–37,
  Calibration 96–129 → 14–18, parametric curve 45–99 → 6–11, grading wheels 69–86 → 13–22, grading luminance
  54–78 → 1.9; means 0.2–2.9 levels. Only the grading luminance sliders are within AB-D-0139's 2 levels: the error
  concentrates in saturated colours at the sRGB gamut's edge, and Highlights and Shadows are local in Photoshop, so
  a per-pixel model of them is an approximation (AB-L-0271 found both). The 65³ lattice adds a p99 of about 2 levels
  between its points (33³ would add 6). Receipts: AB-R-0532 (before), AB-R-0538 (after).
* **What went.** photocraft's white-balance gains, sine Contrast, local-Laplacian Highlights/Shadows
  (`camera_raw/local_tone.rs`), Photoshop-25.4 Whites/Blacks curves (`camera_raw/whites_blacks.rs`),
  Vibrance/Saturation, parametric bumps, HSL bands and grading tints, with their ported tests; the
  remaining photocraft tests say where the fitted model holds them differently.

## Native frameworks

* **Metal** compute for every GPU path; **Metal Performance Shaders**: `MPSImageAreaMin/Max` for
  square Minimum/Maximum and `MPSImageMedian` for radius-1 Median on images without alpha — both
  measured bit-identical to the reference (min/max/median select samples, no arithmetic). MPS
  median does not filter alpha (photocraft does), so alpha images use the MSL kernel.
* **Not used, by measurement or semantics:** `MPSImageGaussianBlur` (photocraft runs σ > 4 as three
  Kovesi box passes with repeated edges — up to 0.02 from a true Gaussian), `MPSImageBox` (re-clamps
  every pass at the texture edge, whereas photocraft extends each pass from the previous one's
  extended line), `MPSImageMedian` beyond radius 1 (square kernels ≤ 9; photocraft's are discs);
  vImage convolution (its summation order / FMA and edge models would make the CPU path stop being
  photocraft's arithmetic, and the CPU path is the parity reference).
* **Dispatch** for CPU parallelism; **ColorSync** (through PCFoundation's `ColorConvert`) for CMYK.

## What's left

* **CPU by design** (sequential, order-dependent or tiny): PatchMatch propagation, onion peel and the
  non-local solver (Inpaint), max-flow / GrabCut / Quick Selection, seam DP, Poisson SOR (healing),
  Nelder–Mead direct alignment (f64 cost cancellation), descriptors / matching / RANSAC / bundle
  adjustment, error diffusion and palette building, HDR response recovery and MTB, Camera Raw's
  spatial stages (Dehaze, Clarity/Texture, Detail) and its picture brightness when the settings don't
  carry it, red-eye, retouch dab kernels, magnetic lasso, polygon rasterisation, procedural primitive
  generation (Flame / Tree / Frame).
* **CPU under `.auto` for some models:** filters that read native CMYK/Lab channels jointly (Smart
  Blur on CMYK+A, Diffuse/Wind/Facet/Extrude on CMYK, Oil Paint on CMYK+A, Color Halftone /
  Mezzotint on Lab, NTSC Colors, Color to Alpha on CMYK+A, Reduce Noise on CMYK, Lighting Effects).
  Sixteen filters whose references work in straight sRGB run CMYK/Lab on the GPU through an sRGB
  round trip (`Filter.rgbaEquivalent`, verified per filter). A ColorSync-managed CMYK conversion
  cannot run on the GPU bit-exactly; a LUT route would trade exactness for coverage.
* **`.auto` = CPU for the host-array selection/segment APIs** (masks in, masks out): transfers cost
  more than the kernels save; `.gpu` reaches the kernels. A GPU-resident mask type would change that.
* **Interop:** photocraft stores smart filters as *engine command* params; `AnyFilter` reads the
  `FilterParams` shape (plus Camera Raw's and Lens Correction's command shapes). A port of the
  engine's `params_for` belongs with the engine port.
* **Consolidation:** several areas carry private copies of Rust-semantics helpers (SplitMix64/xorshift
  RNGs, `div_euclid`/`powi`/binary search, float-float sums, least-squares solvers, max-flow/EDT in
  Inpaint). Behaviour is identical; moving them into Core is housekeeping.
* `FilterEngine.apply(_:to: FloatImage…)` handles up to 16384 px per side on the GPU (larger falls
  back to the CPU under `.auto`); the Surface-level runner tiles.

## Foundation change requests

1. **`FloatImage.mixed(with:coverage:)`** is a straight lerp. photocraft's `mix_selection`
   interpolates premultiplied wherever the filter changed alpha (otherwise hidden colour leaks into
   feathered edges). PCAlgo uses `FilterEngine.mixSelection`; foundation's helper should match it.
2. **`FloatImage.unpremultiply`** zeroes colour only at α = 0; photocraft's threshold is α ≤ 1e-7.
3. **`MetalContext.library`** should accept `MTLCompileOptions` (PCAlgo compiles its own library to
   get `mathFloatingPointFunctions = .precise`), and **PCBlend.metal** should start with
   `#pragma METAL fp contract(off)`: `.safe` math mode still fuses `a*b + c` into `fmuladd`, so the
   `pc_*` blend maths can round differently from `Blend` in Swift.
4. **`writeSample(.u8/.u16)`** traps on NaN (`UInt8(NaN)`); photocraft writes 0.
5. **`Surface`** debug performance: `contentBounds`, `prune`, `writeRegion` and per-sample
   `readSample` dominate the test suite in Debug; bulk byte comparisons and `memcpy` row paths
   (and a fast RGBA8/float row reader) would help every package.
6. Consider moving PCAlgo's GPU plumbing into `MetalContext`: the cross-run private-texture cache
   (fresh private textures are zero-filled by the OS — a 256 MB allocation costs more than most
   kernels), staging-buffer reuse, and parallel upload/readback copies.
7. Documentation: Apple GPUs flush subnormals to zero, and MSL `fmod`, `atan2(y, ±0)` and `sqrt` are
   not libm-exact (PCAlgo's common MSL has exact `pca_fmod`, `pca_sqrt`; Distort has an exact atan2).
