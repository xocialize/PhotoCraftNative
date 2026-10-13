# What isn't native yet — evaluation

The port set out to "convert as much of photocraft to native Metal and Swift as can be done, then
evaluate what isn't possible". This is that evaluation, as of 2026-10-12. Sources are each package's
`PORT-NOTES.md`, `PORT-STATUS.md`, `Tools/PhotoshopOracle/RESULTS.md` and the bridge records cited.

## Where the port stands

| Measure | Result |
|---|---|
| photocraft engine commands | 892 of 892 registered; **887 implemented**; 5 `plugin.*` stubbed |
| Library crates | every one except `plugins` ported or replaced by a native framework (ColorSync, ImageIO, CIRAWFilter, CoreText, CoreGraphics, PDFKit, Vision, NSEvent) |
| Tests | about 3,900 across 11 packages, CPU and Metal parity throughout |
| Photoshop opens our PSDs | PCIO exports **1,524 / 1,524 (100 %)**, 0 refused, 0 crashed (AB-R-0515; was 80 % before the fixes); PSD-writer builder files 149 / 150 (AB-R-0513) |
| Our compositor vs Photoshop's own composite | **141 / 150** Photoshop-authored files; Unity corpus 36 / 36 |
| GPU speed-ups (Release, 4096²) | filters 18–110× (Gaussian 18×, Radial Blur 91×, Smart Blur 112×), painting ~20×, compositing 24–36× |

The code is committed in `xocialize/PhotoCraftNative` (private; split out of MetalPlayground on 2026-10-13), and the
Compositor v1.5 merge (`94f5c46`) is on `xocialize/Compositor` `main`.

## 1. Possible natively, not built yet

These are work, not blockers. Ordered by size.

| Item | photocraft size | Native path | Notes |
|---|---:|---|---|
| **App shell** (`ui-egui` + `apps/desktop`) | 165,867 + 7,210 lines | SwiftUI + AppKit + MTKView, starting from Compositor v1.5's shell, DesignScaffold tokens, MetalToolBox's `EnhancedMetalView` | The biggest remaining piece. It owns 144 menu ids the engine doesn't (View 55, Window 61, Type 14, Edit 7, File 6, Select and Mask), every tool's interaction, dialogs, panels, i18n and the `ui.*` control API. The engine's `Session` / `CanvasRenderer` / damage-limited redraw API is ready for it |
| **Plug-in host** (`crates/plugins` + engine `plugin_cmds`) | 1,093 + 286 lines | A WebAssembly runtime: **WasmKit** (pure Swift) or JavaScriptCore's WebAssembly | ABI v1 is small: import-free modules (no WASI), one `pc_filter` export over f32 pixels, a JSON manifest. The sandbox is the hard part: photocraft meters fuel (50 M + 4,000 per sample), caps memory at 512 MiB and recursion at 1,024, and has a 60 s deadline. **Needs a spike** to confirm WasmKit (or JSC) can enforce those limits and run fast enough; JSC has no fuel metering |
| **Model tiers** | — | ForgeCore engine providers, injected by the host app | No package links ForgeCore (by design: the Kits stay MLX-free). Colorize, Smart Portrait, Super Resolution and Photo Restoration's face and scratch stages need a model and light up once the app injects providers. Ask AB-A-0165 to mlx-forge covers the Kit seams |
| **Small leftovers** | — | native | `.kys` shortcut import; `Surface.converted(to:)` across colour models; typed Preferences validation; PDF text imported as editable type; Indexed / Duotone / Bitmap / Multichannel PSD *writing*; `lrFX` write-back; `TextWarp` rendering (a CoreGraphics path warp); vector pattern paints; Color Lookup with a table (no Photoshop-authored reference possible by script: Photoshop records the file name but never stores the table; would need one made by hand); a bundled spelling word list (today NSSpellChecker) |

## 2. Native, but the Apple API falls short

Each is working today, approximated or warned. The question is whether to close the gap.

| Area | Gap | Recommendation |
|---|---|---|
| **Camera Raw** (CIRAWFilter) | No Dehaze; Clarity and Texture approximated with unsharp masks; positive Highlights can't brighten; no demosaic choice; no XMP sidecars; DNGs under ~200 px refused | **Close it:** PCAlgo's Camera Raw *filter* already runs Dehaze, Clarity and Texture on the CPU. Demosaic with CIRAWFilter, then hand the linear image to PCAlgo for those controls |
| **ColorSync** | Black-point compensation shifts neutrals; absolute intent uses a v2 profile's D65 white | Already worked around at the PCS (≤ 1 level, AB-L-0249). Leave |
| **CMYK on the GPU** | ColorSync's conversion can't be reproduced bit-exactly in a shader | CPU fallback for those paths. Leave |
| **Half-float images** | `SampleType` has no `f16`; EXR / TIFF half floats widen to f32 | A breaking enum change across every package. Do it before the app ships, not now |
| **Codecs** (ImageIO) | EXR writes one part, no deep / Cryptomatte, refuses DWAA / DWAB / HTJ2K; JPEG XL read-only; JPEG 2000 8-bit only; DDS can't be written; WebP via webp-swift is 8-bit sRGB without metadata | Check media-bridge `ImageBridge` for each before writing codecs; otherwise accept |
| **Text** (CoreText) | No optical kerning (saved as Metrics); no hinting-style anti-alias modes; no Japanese punctuation squeeze | Optical kerning would need our own glyph-outline spacing model. Low priority |

## 3. Not possible, or not wanted

| Item | Why |
|---|---|
| **The wasm web app** (`apps/web`, 1,209 lines) | A browser build of the egui app; a native Mac app replaces it. No equivalent intended |
| **Photoshop's exact Dissolve pattern** | Copying it would mean embedding thresholds taken from Photoshop's output. Your decision AB-D-0130: match its coverage only (done, within 0.0015 at every opacity) |
| **Generative Fill** | No provider exists: the fleet's edit models (FLUX.2-klein, Z-Image) have no ForgeCore adapter, so an inpaint model stands in and the prompt is ignored. **Decided:** asked mlx-forge for an adapter behind PCIntelligence's `GenerativeFillProvider` seam (ask AB-A-0166) |
| **32-bit CMYK / Lab PSDs** | Photoshop has no such modes; we write 16-bit, as Photoshop would |
| **Rust-only test mechanisms** | Allocation-failure injection, lock poisoning, unwinding: nothing to port |

## 4. Photoshop fidelity still open

The compositor misses 9 of 150 Photoshop composites:

- **Light-mode Highlights / Shadows:** Photoshop 27's new Brightness/Contrast mode applies these *locally*, so no tone curve reproduces them. Fixing them needs another measurement batch aimed at the local operator.
- **Adjustment stacks:** five files where several fitted adjustments compound. Light-mode Contrast's pivot also moves with image content.
- **CMYK Darker / Lighter Color:** needs a 5-channel CMYK compositing path.
- **The Lab Dissolve band:** limited by the coverage-only Dissolve, per AB-D-0130.

All other measured behaviour is fitted and filed on the bridge (AB-L-0253 to 0271).

## Recommended next steps

1. **Make the tests portable, then commit.** *Done:* tests and the oracle tool read data from `PHOTOCRAFT_FIXTURES` (default `../PhotoCraftNative-Fixtures`), skip cleanly without it, and write oracle drop files only when `PCIO_EXPORT_DIR` / `PCPSD_FIXTURES` is set. Committed on branch `claude/photocraft-native`.
2. **Wave 3: the app shell**, on Compositor v1.5 and DesignScaffold. Start with canvas, layers panel, tools and menus driving the existing `Session`.
3. **Plug-in host spike:** WasmKit, with photocraft's fuel, memory and deadline limits. Take the result back as a go/no-go.
4. **Camera Raw:** route Dehaze, Clarity and Texture through PCAlgo after CIRAWFilter's demosaic.
5. **Generative Fill:** asked mlx-forge for an edit-model adapter (AB-A-0166); register it when they reply with a tag.
6. **Housekeeping:** a notes-sync pass. The gap survey found 12 places where package notes contradict each other or the code (for example `abr_map` and `.cube` LUTs are ported but still listed as missing). The Photoshop-built corpora and measurements now live in `../PhotoCraftNative-Fixtures/` (2.3 GB, outside git, with a README).
