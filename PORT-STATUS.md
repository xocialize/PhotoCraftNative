# Port status

Crate by crate: what photocraft has, what the native port does with it, and where it stands. Rust line counts
include in-file tests (`crates/*/src`, measured 2026-10-12 at photocraft `184c226a`).

## Crates

| photocraft crate | Rust lines | Disposition | Package | Status |
|---|---:|---|---|---|
| geom | 1,640 | Port (rects, tiles here; affine/warp/paths in PCDocument) | PCFoundation, PCDocument | **done** |
| color | 1,402 | Port | PCFoundation | done — 33 blend modes, Metal ≤ 1/255 of Swift |
| raster | 1,385 | Port; Swift arrays replace `Arc` copy-on-write | PCFoundation | done |
| gpu (device) | — | wgpu → `MetalContext` | PCFoundation | done |
| psd | 16,101 | Port + PhotoDemon decode breadth + ImageIO acceptance oracle | PCPSD | **done** — 255 tests. Unity corpus (36 Photoshop files) and the Photoshop 27.11-authored corpus (153 files): byte-identical rewrites 36/36 and 153/153, every typed block re-serialises to the original bytes. **In Photoshop** (Tools/PhotoshopOracle/RESULTS.md): reads 149/153 trees exactly (the 4 were the `SoFi` bug, fixed); builder files open 116/151 before the matte-order fix (all 35 rejects were the measured causes, now fixed and linted by `compatibilityIssues()`). 5.2 GB PSB writes in 0.44 s, opens in 0.008 s. Left: layered-TIFF transcoder (→ PCIO) |
| doc | 4,950 | Port | PCDocument | **done** — 120 tests incl. photocraft's 58 + geom's 21; Blend If ramp follows Photoshop's measured `(v − lo + 1)/(hi − lo + 1)` (photocraft's `(v − lo)/(hi − lo)` was 9 % of pixels off) |
| ops | 846 | Port; reversible `DocumentOp`/`EditTransaction` added per architecture §6 | PCDocument (`PCHistory`) | **done** — 26 tests incl. photocraft's 15 |
| algo | 50,072 | Port → Metal kernels + Swift CPU reference | PCAlgo | **done** — 37K Swift + 8.5K MSL (251 kernels), 665 tests. 73 filter types (whole Filter menu, Camera Raw, Lens Correction, all 47 Filter Gallery effects) + ~45 operations (resample, transforms, Liquify, warps, selection/segmentation, inpaint, seam carving, panorama, stacks). 266 GPU-vs-CPU checks: 165 bit-exact, worst 1.03e-4. Release 4096²: Gaussian 160 → 8.8 ms, Radial Blur 9.9 s → 109 ms, Smart Blur 1.9 s → 17 ms. Sequential algorithms (PatchMatch, max-flow, seam DP, Poisson, RANSAC) stay on the CPU by design |
| paint | 7,641 | Port → Metal dabs + CPU reference | PCPaint | **done** — 117 tests; Metal **bit-exact** to CPU over 28 configs × 10 formats × 36 presets; 2,000-dab 200 px stroke at 4096²: 245 ms CPU → 10.5–12.7 ms Metal (Release) |
| compose | 12,802 | Port (CPU reference) | PCRender | **done** — planner + CPU executor; 194 tests (116 end-to-end documents on CPU and Metal; worst 0.89 levels over 582 renders). **Against Photoshop's own composites:** Unity 36/36, Photoshop-authored corpus **141/150** on CPU and Metal. Phase 3: CMYK/Lab-native compositing, Soft Light / 32-bit / Blend If rules, vector-mask coverage. Phases 4–5 (fitted to Photoshop function measurements M1–M3; lessons AB-L-0263…0267, 0269, 0271): Satin, contour presets re-measured, Brightness/Contrast's three modes (Legacy / Modern / Light), Vibrance, integer 8-bit Hue/Sat/Color/Luminosity, Dissolve coverage (own noise, per AB-D-0130). The 9 left: five adjustment stacks, Light's Highlights/Shadows (local operators, not modelled), CMYK Darker/Lighter Color (needs a 5-channel path), Lab band, Dissolve's exact pattern (by decision) |
| gpu (compositor) | 8,239 | WGSL → MSL, wgpu → Metal | PCRender | **done** — 4096², Release, warm: 4 layers + effects 125 ms CPU → 3.4 ms Metal (36×); 20 layers 613 → 25.9 ms (24×). Float accumulators where half drifted (measured 6 levels over 5 adjustment layers) |
| cms | 5,314 | **Replace** with ColorSync | PCPlatform | **done** — photocraft's cms expectations met (sRGB primaries ΔE 0.012–0.019); BPC and absolute intent done at the PCS to avoid two ColorSync defects; 33³ display LUT; monitor profile from `NSScreen` |
| codecs | 18,336 | **Replace** with ImageIO + media-bridge ImageBridge; WebP write via webp-swift | PCPlatform | **done** — native depth/model, ICC/EXIF/XMP/DPI, multi-frame, JPEG re-save at its own quality; QOI, PCX, FITS, Netpbm, Radiance write ported where ImageIO lacks them |
| heif | 218 | **Replace** with ImageIO | PCPlatform | **done** (read and write; photocraft reads only) |
| raw | 11,989 | **Replace** with `CIRAWFilter` | PCPlatform | **done** — 16-bit ProPhoto or scene-linear float; ~934 cameras; Dehaze not native, Clarity/Texture approximated |
| text | 10,074 | **Replace** with CoreText | PCPlatform | **done** — lays out and renders PCDocument's `TextLayer` directly; vertical type (photocraft's layout, caret, hit test), manual kerning replaces pair kerning; per-family font cache + per-run attributed strings: 470 → 52,600 layouts/s at 32 threads (Release) |
| vector | 3,765 | **Replace** with CoreGraphics | PCPlatform | **done** (exact areas; supersampling for 16/32-bit masks); rasterises PCDocument's `VectorPath`/`ShapeLayer`/`VectorMask` directly |
| tablet | 1,019 | **Replace** with `NSEvent` | PCPlatform | **done** — no unsafe FFI |
| affinity | 3,715 | Port (standalone reader) | PCAffinity | **done** — 4,303 Swift lines, 56 tests; iterative parsers (no deep recursion); a bounded **Zstandard decoder** written from RFC 8878 because Compression has none (byte-exact vs zstd 1.5.7 on 176 frames, ~420K corrupt frames without a crash), public as `ZstdDecoder` for `.pcraft` tiles. Found three unbounded-recursion/loop hazards that are also in photocraft |
| format | 6,059 | Port `.pcraft` | PCIO (`PCFormat`) | **done** — photocraft-compatible (zstd tiles via PCAffinity's decoder, BLAKE3 content addressing implemented in Swift); 36/36 and 153/153 corpus documents survive `.pcraft` |
| io | 30,086 | Port doc ⇄ PSD/ORA/KRA/PDN/TIFF-layers mapping | PCIO | **done** — 818 tests (Debug and Release, no warnings). Unity corpus: 36/36 re-import equal, 4068/4068 layer blocks byte-identical. Photoshop-authored corpus (153 files): 150/153 equal (3 Bitmap/Indexed written as Gray/RGB, as photocraft does), 4011/4011 blocks. **Composite oracle** (PCRender vs Photoshop's own composite): Unity 36/36; Photoshop corpus **141/150** (with PCRender phases 4–5). All six Photoshop refusal/crash causes fixed in the writer (EngineData, blend modes per mode/depth, 4-alignment, matte order, no generated `Txt2`, pattern sheet mask); Gradient Map Smooth fitted to Photoshop (Oklab spline: 25.5 % → 0 % of pixels > 2 levels off). Photoshop acceptance 1,475/1,481 (99.6 %, AB-R-0514). `abr_map` is ported in PCEngine (`PresetImportCommands+Abr.swift`). Left: `raw`, which `Txt2` field Photoshop rejects, Color Lookup tables, artboards as Normal (in progress) |
| engine | 103,916 | Port session, command registry, jobs, commands | PCEngine | **done** — all 892 photocraft command ids registered: **887 implemented**, 5 `plugin.*` stubs (WebAssembly host, below); 1,364 + 151 (PCAutomation) tests. Change requests to the other packages are being worked |
| ml (planned, never built) | 0 | **Slot in fleet Kits** (below) | PCIntelligence | **done** — 45 tests on the model-free tiers (Vision ran on every subject test; none skipped); 15 operations, 14 command descriptors (5 reuse photocraft ids); `ProviderRegistry` for ForgeCore's model tiers. Kit-owner asks filed as AB-A-0165 → mlx-forge |
| (PDF, gap G10) | — | **Native**: PDFKit / CGPDF read at any DPI and depth, vector import as paths, multi-page raster or vector write | PCPlatform | **done** |
| automation | 7,072 | JSON-RPC control channel + MCP (official swift-sdk 0.12.1, as ML[X] Image Server uses) | PCEngine (`pccli`, `PCAutomation`) | **done** — `pccli` convert/info/run/batch/droplet/commands/mcp/serve/control/coverage |
| plugins | 1,486 | wasmi → JavaScriptCore's WebAssembly or WasmKit | evaluate | not started |
| ui-egui | 165,867 | **Replace** with SwiftUI + AppKit + MTKView, starting from Compositor's shell | wave 3 | not started |
| apps (desktop, cli, web) | 10,012 | CLI → `pccli` (**done**, in PCEngine); desktop (7,210) → macOS app shell; the wasm web app (1,209) has no native equivalent | PCEngine, wave 3 | CLI done; desktop not started |
| testkit | 266 | Test helpers per package | — | — |

## Fleet components that slot in instead of being rebuilt

Found through AgentBridge (2026-10-12). All are versioned `github.com/xocialize/*` packages; per AB-D-0023 they are
consumed by URL, never by path.

| Need (photocraft gap or crate) | Fleet component | Tier without a model | Model tier (through ForgeCore's engine providers) |
|---|---|---|---|
| Codecs, RAW, PDF raster, metadata (codecs, raw, G10) | media-bridge `ImageBridge` v0.40.0 | ImageIO, CIRAWFilter, CGPDF | — |
| WebP write (ImageIO can't) | webp-swift v0.1.0 (libwebp 1.6.0 from source, BSD-3) | — | — |
| Select Subject, Remove Background (G15) | ExtractKit v0.1.1 | Tier 0 classical, Tier 1 Vision `VNGenerateForegroundInstanceMaskRequest` | `EngineMatteProvider` (BiRefNet) |
| Object Selection tool, click-to-select (G15) | MaskKit v0.4.1 `PromptMaskProvider` | — | `EnginePromptMaskProvider` (EdgeTAM) |
| Remove tool, Content-Aware Fill, Generative Fill (G15) | EraseKit v0.2.0 | Tier 0 classical fill | `EngineInpaintProvider` (LaMa, fixed in mlx-lama-swift v0.3.1, AB-T-0213) |
| Neural Filters: Colorize | ColorizeKit v0.1.1 | none (macOS has no colorizer) | `EngineColorizeProvider` (DDColor) |
| Neural Filters: restoration, denoise, face | ForgeRestoreKit v0.11.0 | Tier 0: hot/dead pixels, noise-aware sharpen, film grain, deinterlace | `EngineFrameRestoreProvider` (NAFNet, SCUNet, DRUNet, Restormer, GFPGAN, RestoreFormer, BOPBTL) |
| Super Resolution (Image Size ▸ Preserve Details 2.0) | ForgeCore upscale adapters | — | Real-ESRGAN, RealPLKSR, NERVE |
| White balance, SDR → HDR | ForgeLightKit v0.3.0 (Metal) | Tier 0 | — |
| Export quality targeting | media-bridge `MediaMeasure` (SSIMULACRA2) | — | — |
| Display view, texture compositing | MetalToolBox 2.2.1 (`EnhancedMetalView`, TCE) | — | — |
| App UI tokens and components | DesignScaffold (the fleet's single design authority, AB-D-0042) | — | — |
| App shell, canvas, tool overlays; a Swift PSD reader/writer to cross-check | Compositor v1.5 (MIT; 53.5K lines of Swift, upstream `robbietilton/Compositor` tag `v1.5` = `1071f4f`). Upstream v1.5 merged into the local `research/Compositor` `main` on 2026-10-12 (merge `94f5c46`, not pushed; signing settings kept; Debug build OK); `Compositor-upstream` is a worktree on the fleet's `fixtures/canvas-p0` branch, not upstream | — | — |

Category rule (forge architecture): the net-clean Kits stay free of MLX. The engine-backed providers live in
ForgeCore (Category B), and the **app** injects them. PCIntelligence therefore depends only on the Kits, so the
library builds without MLX, and the model tiers light up when the host links ForgeCore.

## Open follow-ups

| Item | From | Note |
|---|---|---|
| Half-float `SampleType` (EXR/TIFF half read today widens to f32) | PCPlatform | Breaking enum change; after wave 1 |
| `TextLayer` resolution field; `TextWarp` rendering; super/subscript, tate-chū-yoko, no-break, justification, tabs, hanging punctuation | PCPlatform | photocraft's model lacks these too |
| Generative Fill has only the inpaint stand-in; FLUX.2-klein / Z-Image are edit models with no ForgeCore adapter | PCIntelligence | needs a decision |
| Colour-space hook (document tone curve) for white balance / SDR→HDR on linear documents | PCIntelligence | |
| Pattern fills need `Document.patterns` or a resolved pattern surface on `Fill.pattern` | PCPlatform | |
| `lrFX` written back; Indexed/Duotone/Bitmap/Multichannel PSD writing; edited slices written as v6 only | PCPSD | |
| Three photocraft-affinity hazards (self-referencing compound shape, self-referencing spot colour, pie angles like 1e300) bounded here; upstream photocraft still has them | PCAffinity | could be reported upstream |
| Real Photoshop acceptance check (open our PSDs in Photoshop) | PCPSD, PCIO | **Re-checked 2026-10-12** (receipt AB-R-0513): PCIO exports **1,302/1,313 open (99.2 %**, was 80 %), 0 crashes, all 378 round-trip trees match; PCPSD builder files **149/150** (was 116/151). Left for PCIO: 89 adjustment layers Photoshop reads as pixel layers, 6 artboards (Pass Through → Normal), a path-less `vmsk`, 7 unexplained refusals (lnk2, placed-layer blocks, vector-rendered masks). Harness `Tools/PhotoshopOracle`, skill `photoshop-oracle`, lessons AB-L-0245/0246/0250–0253/0258/0262 |
| ~~PCIO writer follow-ups from Photoshop sweep C″~~ (1,475/1,481 open, AB-R-0514) | PCIO | **done** except Color Lookup tables (waiting on Photoshop-authored references; sweep C‴ of the 1,516 regenerated exports queued). Was: write artboards as Normal (AB-L-0270); re-validate preserved `PlLd`/`SoLd`/`lnk2`/`SoCo` blocks (PCPSD now lints them: `placedLayerWithoutLinkedData`, `placedLayerDataUnreadable`, `linkedFileKindMismatch`); keep the 6 damaged fixtures out of the export set and mark `PSDBlockLayoutTests.placedLayerBlocksKeepTheirKeys`, `PSDStructureTests.vectorRenderedMaskNotDoubledOnShapes` and `SmartContentsIdentityTests.independentUnavailableLink…` `knownLintIssue` (they fail until then, by design: PCPSD's linter now flags their hostile blocks); write Color Lookup's `profile` so table-carrying lookups stay adjustments |
| ~~Brightness/Contrast has three modes in Photoshop 27~~ | PCDocument, PCIO, PCRender, PCEngine | **done** (phase 5): model, PSD mapping, compositor (CPU + Metal), engine params; Modern exact on the new corpus file; Light's Highlights/Shadows are local operators, still identity |
| ~~Satin contour: PCRender's fit vs photocraft's test~~ | PCRender, PCEngine | **settled** by measurement (AB-L-0263): photocraft's observations hold; PCEngine's 5 known issues now pass. Left: PCEngine's built-in Cone preset marks a corner, Photoshop's is smooth |
| ~~Change requests from PCEngine to the shared core and PCPlatform~~ | PCFoundation, PCDocument, PCIntelligence, PCPaint, PCPlatform | **done** 2026-10-12: saturating tile rects (#963), alpha-changing `converted(to:)`, shared copy-on-write fills (a 100,003 × 70,001 background holds 4 tile buffers), rebaseable `setDocumentProperties`, near-linear `resolvedSlices`, `InpaintOptions`, task-local `ColorConvert.withCMYK`, exact 32-bit sampling (`renderExact`); Debug tests PCAlgo 500 → 335 s, PCPaint 90 → 50 s. PCPlatform: font cache, vertical type, kerning, far-coordinate clipping, WebP quality. Lessons AB-L-0254…0257, 0260, 0261. Left: cross-model `converted(to:)` |
