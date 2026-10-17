# PCIntelligence: port notes

PCIntelligence is the AI tier of the PhotoCraft native port. photocraft planned an `ml` crate (SAM2, matting, depth, sky,
inpainting; `docs/architecture.md` §2) and never built it, so its AI dimension sits at about 10% (gap **G15**,
`docs/gaps.md`; `docs/target-app-parity.md` rates "AI / generative" at 10%). This package does not train or port
any model. It slots in the fleet's finished image Kits. Each Kit's model-free tier runs by default, and the host app
injects the engine-backed (MLX) providers from ForgeCore into a registry with one slot per capability.

photocraft revision `184c226a` (2026-10-12). MIT OR Apache-2.0, © ArtCraft Team and the PhotoCraft contributors.

**Status:** complete for the requested scope. `swift build` and `swift test` are clean with no warnings: **45 test
functions** in 6 suites, about 5 s. The tests run the model-free tiers end
to end on generated images and use no network, weights or user files.

## Dependencies

| Package | How | Products used |
|---|---|---|
| PCFoundation, PCDocument | `.package(path:)` (siblings in this repo) | `PCFoundation`, `PCDocument`, `PCHistory` |
| MaskKit | URL `from: "0.4.1"` (resolved 0.4.1) | `MaskKit`: `PromptMaskProvider`, `MaskPrompt` |
| ExtractKit | URL `from: "0.1.1"` (0.1.1) | `ExtractKit`: `ForegroundExtractor`, `MatteProvider`, `ExtractQuality` |
| EraseKit | URL `from: "0.2.0"` (0.2.0) | `EraseKit`: `Eraser`, `ClassicalInpainter`, `MaskOps`, `InpaintProvider` |
| ColorizeKit | URL `from: "0.1.1"` (0.1.1) | `ColorizeKit`: `Colorizer`, `ColorizeProvider` |
| ForgeRestoreKit | URL `from: "0.11.0"` (0.11.0) | `RestoreTier0` (guided filter, Immerkaer σ), `RestoreTier2` (`FrameRestoreProvider`) |
| ForgeLightKit | URL `from: "0.3.0"` (0.3.0) | `LightTier0` (illuminant, Bradford, inverse tone mapping, PQ) |

All of these are Category A: no MLX and no weights. The transitive packages are media-bridge 0.40.0,
ForgePixelBridge 0.1.0 and matroska-swift 0.2.0. Every Kit floor is macOS 14 and Swift 6, below this package's
macOS 26. **PCIntelligence never depends on ForgeCore**, because the fleet rule is that Category A never depends on
Category B.

## Layout

| File | Contents |
|---|---|
| `Bridging/KitBridge.swift` | Surface ⇄ CGImage at 8, 16 and 32-bit float depth. Picks the colour space per document (embedded RGB profile, else sRGB, or extended sRGB at 32 bits). Converts through RGB for Gray, CMYK and Lab. Reads raw when the layout is known, otherwise draws (and converts). Decodes masks raw (coverage is never colour-managed) and resamples bilinearly. Also PNG encode and decode for RestoreTier2's byte seam. |
| `Bridging/CoverageMask.swift` | A coverage plane in document space. Converts to Gray surfaces at any depth (pruned), to Kit mask images, and back. Combines with the selection by photocraft's `SelectionMode` (replace, add, subtract, intersect). |
| `Registry/Capability.swift` | `Capability` (11 slots), `IntelligenceTier` (classical, vision, model), `CapabilityStatus`, `TierReceipt`, progress, `IntelligenceError` |
| `Registry/Providers.swift` | Seams no Kit names yet (generative fill, face restore, defect mask, upscale, white balance, HDR expansion), plus a closure adapter for each |
| `Registry/ProviderRegistry.swift` | The injection seam: one `Mutex`-guarded slot per capability, typed `register(…)` methods, per-capability and per-restore-job status |
| `Tiers/VisionInstances.swift` | Tier 1 for Object Selection: Vision's foreground instances behind MaskKit's `PromptMaskProvider`, picked by click, exclusion click or box. Also the analysis behind the hover preview. |
| `Tiers/ClassicalTiers.swift` | Model-free jobs built from Tier-0 Kit parts: guided-filter denoise (RestoreTier0), shades-of-grey + Bradford white balance, and the BT.2408 SDR → HDR chain (LightTier0) |
| `Services/PCIntelligence.swift` | The service object, `PixelSource` (layer, composite, surface) with an injected `Compositor`, shared checks, and the outcome types |
| `Services/Selection.swift` | Select Subject, Object Selection, Object Finder (hover), Remove Background |
| `Services/Fill.swift` | Content-Aware Fill, the Remove tool, Generative Fill, and Photoshop's sampling window |
| `Services/PixelCommit.swift` | Turns computed pixels into `paintTiles` or `insertLayer` transactions (outputs current, new, duplicate and masked) |
| `Services/NeuralFilters.swift` | Colorize, Photo Restoration, JPEG Artifacts Removal, Smart Portrait (face restore) |
| `Services/LightAndScale.swift` | Auto White Balance, SDR → HDR, the upscale primitive, Super Resolution |
| `Commands/IntelligenceCommands.swift` | The 14 operations as photocraft-shaped command data, plus the enabled-predicate evaluator |

## Feature table

"photocraft" is what the Rust app has today (`docs/target-app-parity.md` and the engine sources). "Model-free tier"
is what runs with nothing injected. "ForgeCore provider" is what a host registers for the model tier.

| Photoshop feature | photocraft status | Kit and model-free tier | ForgeCore provider for the model tier | Command id |
|---|---|---|---|---|
| Select ▸ Subject | classical heuristic (superpixels, saliency, GrabCut), 559 ms p50 on 24 MP | ExtractKit `ForegroundExtractor`, **Vision** (`VNGenerateForegroundInstanceMaskRequest`) | `EngineMatteProvider` (BiRefNet fast/best) | `select.subject` (reused) |
| Object Selection (click, box) | `select.object`: GrabCut in a rect | MaskKit `PromptMaskProvider` seam. **Vision** instances via `VisionInstanceMaskProvider` (this package; MaskKit ships no Tier 1) | `EnginePromptMaskProvider` (EdgeTAM; `model: .promptMaskQuality` = SAM 2.1-S) | `select.object` (reused; points and box added) |
| Object Selection hover (Object Finder, auto-select) | none | **Vision** instances computed once per image, then a lookup per pointer move | none (MaskKit's seam has no "all objects" query) | `select.objectFinder` (new, query) |
| Remove Background (Quick Action) | `layer.removeBackground`: Select Subject + refine → layer mask | ExtractKit, **Vision** | `EngineMatteProvider` | `layer.removeBackground` (reused) |
| Remove tool | `paint.remove`: non-local patch completion | EraseKit `Eraser`, **classical** diffusion (`ClassicalInpainter`) | `EngineInpaintProvider` (LaMa best / MI-GAN fast) | `paint.remove` (reused) |
| Content-Aware Fill | `edit.contentAwareFill`: PatchMatch (Wexler) | EraseKit, **classical** diffusion | `EngineInpaintProvider` | `edit.contentAwareFill` (reused) |
| Generative Fill | missing | none: unavailable | none yet. Stand-in: `EngineInpaintProvider` (prompt ignored, recorded in the receipt). See below. | `edit.generativeFill` (new) |
| Neural Filters ▸ Colorize | missing | ColorizeKit: none (macOS has no colorizer), so unavailable | `EngineColorizeProvider` (DDColor) | `filter.neuralFilters.colorize` (new) |
| Neural Filters ▸ Photo Restoration | missing | scratches: none. Noise: **classical** (RestoreTier0 guided filter). Face: none. A stage without its model is skipped and named in the receipt. | `DefectMaskClosure` → BOPBTL (`.defectDetect`) + `EngineInpaintProvider`; `EngineFrameRestoreProvider` (denoise → NAFNet); `FaceRestoreClosure` → GFPGAN / RestoreFormer++ | `filter.neuralFilters.photoRestoration` (new) |
| Neural Filters ▸ JPEG Artifacts Removal (denoise) | classical `filter.noise.reduceNoise` only | **classical**: RestoreTier0 guided filter, ε = (k·σ_Immerkaer)², on luma and chroma | `EngineFrameRestoreProvider` `.denoise` (NAFNet `.signage`) | `filter.neuralFilters.jpegArtifactsRemoval` (new) |
| Neural Filters ▸ Smart Portrait (face restore) | missing | none: unavailable | `FaceRestoreClosure` → GFPGAN v1.4 (`.faceRestore`) or RestoreFormer++ (`.faceRestoreVQ`) | `filter.neuralFilters.smartPortrait` (new) |
| Super Resolution / Image Size ▸ Preserve Details 2.0 | classical resamplers only (`preserveDetails` is not 2.0) | none: unavailable | `UpscaleClosure` → `EngineImageEnhancer.upscaleReporting` (NERVE fast, RealPLKSR best; Real-ESRGAN via an external registration) | `image.superResolution` (new). The engine routes `image.imageSize` `"resample":"preserveDetails2"` to `PCIntelligence.upscale`. |
| Auto White Balance | `image.autoColor` (Photoshop's classical Auto Color) | **classical**: LightTier0 shades-of-grey p = 6 in linear light, Bradford to neutral; receipt carries kelvin and tint | none (LightTier2 is not built; `WhiteBalanceProvider` slot ready) | `image.autoWhiteBalance` (new) |
| SDR → HDR | `image.mode.bits32` (depth change only) | **classical**: LightTier0 deband → BT.2408 direct mapping (diffuse white 80–10000 cd/m², default 203) → dither once → decoded to linear | none (`HDRExpansionProvider` slot ready) | `image.sdrToHdr` (new) |
| Image Size ▸ enlarger method (PixelAgencyEditor's Line art) | missing (per-axis resamplers only) | none: unavailable, and Image Size runs its Resample alone | not ForgeCore: anime4k-metal's `Anime4KUpscaler` through `CGImageEnlarger` (AB-T-0293) | `image.imageSize` `"enlarger":true` (PCEngine; AB-T-0292) |

Every operation returns a `TierReceipt` (capability, tier, engine name, notes, metrics) for each stage that ran.

## Host injection (the app links ForgeCore; this package doesn't)

The snippet below is written against ForgeCore v0.38.0's public API. It is **not compiled here**, because
PCIntelligence must not depend on ForgeCore, so check it the first time an app builds it. The five Kit-seam
providers register in one line each. The three seams ForgeCore has no Kit adapter for (face, defect, upscale) take
one closure each. `ForgeEngineService` and its adapters are `@MainActor`.

```swift
import ForgeCore            // Category B: MLX lives in the app, never in PCIntelligence
import ForgeOptimizerKit    // UpscaleFactor / UpscaleTier for EngineImageEnhancer
import MLXToolKit           // engine request types for the closure seams
import PCIntelligence

struct EngineUnavailable: Error {}

@MainActor
func makeIntelligence(models: URL, compositor: @escaping Compositor) async -> PCIntelligence {
    let svc = ForgeEngineService()                      // .permissiveOnly + .blocking
    await svc.attachModelStore(root: models)            // before registerAll
    await svc.registerAll()
    let ai = PCIntelligence(compositor: compositor)     // PCRender's composite, for Sample All Layers
    let r = ai.registry
    r.register(matte: EngineMatteProvider(service: svc))            // BiRefNet: Select Subject, Remove Background
    r.register(promptMask: EnginePromptMaskProvider(service: svc))  // EdgeTAM (SAM 2.1: model: .promptMaskQuality)
    r.register(inpaint: EngineInpaintProvider(service: svc))        // LaMa / MI-GAN: Remove, Content-Aware Fill
    r.register(colorize: EngineColorizeProvider(service: svc))      // DDColor
    r.register(restore: EngineFrameRestoreProvider(service: svc))   // NAFNet / Restormer
    let enhancer = EngineImageEnhancer(service: svc)
    r.register(upscale: UpscaleClosure("RealPLKSR") { img, f in
        try await enhancer.upscaleReporting(img, factor: f >= 4 ? .x4 : .x2, tier: .best).image })
    r.register(faceRestore: FaceRestoreClosure("GFPGAN") { img, strength in
        guard let id = await svc.packageID(for: .faceRestore) else { throw EngineUnavailable() }
        let out = try await svc.engine.run(ImageRestoreRequest(image: EngineImageCoding.pngImage(from: img), strength: strength), package: id)
        return try EngineImageCoding.cgImage(from: (out as! ImageRestoreResponse).image) })
    r.register(scratchDetect: DefectMaskClosure("BOPBTL") { img in
        guard let id = await svc.packageID(for: .defectDetect) else { throw EngineUnavailable() }
        let out = try await svc.engine.run(DefectDetectRequest(image: EngineImageCoding.pngImage(from: img)), package: id)
        return try EngineImageCoding.cgImage(fromEncoded: (out as! DefectDetectResponse).mask.data) })
    return ai
}
```

How the slots behave:

- **Tier per registration.** `register(…, tier:)` defaults to `.model`. A classical backer registers with
  `tier: .classical`. `unregister(_:)` returns a capability to its model-free tier, or makes it unavailable.
- **Built-in tiers.** `setBuiltIn(inpaint:)` puts a classical backer *under* the inpaint slot: it runs while the
  slot is empty, a registered provider overrides it, and `unregister(.inpaint)` / `removeAll()` leave it. PCEngine
  puts PCAlgo's PatchMatch there, which beats EraseKit's diffusion on large holes. It used to be registered *in*
  the slot, so PixelAgencyEditor's models module, emptying the slot while LaMa wasn't ready, turned every later
  fill into EraseKit's smooth membrane, still reported as classical (AB-T-0304). `status` reports a built-in tier
  with `injected: false`.
- **Restore is per job.** `status(of: RestoreJob)` asks the provider's `engineName(for:)`. ForgeCore answers
  `"unavailable"` for a job whose backer failed registration, so that job stays unavailable (deblur) or classical
  (denoise). Deblur is never faked with sharpening.
- **Inpaint options.** EraseKit's `InpaintProvider.inpaint(_:mask:quality:)` takes no options, so the seam has an
  additive refinement here: `OptionsInpaintProvider` adds `inpaint(_:mask:quality:options:)` with `InpaintOptions`
  (sampling: window / auto / a window-sized source mask; colour and rotation adaptation, scale, mirror, seed:
  photocraft's `FillOptions`). Its extension implements the plain Kit requirement with the default options, so an
  adopter registers through `register(inpaint:)` like any provider. Content-Aware Fill passes
  `ContentAwareFillOptions.inpaint` (default: the Remove tool's options); the fill binds them to the provider when
  it adopts the protocol and calls other providers unchanged (`inpaintOptionsReachAnOptionsProvider`).
- **Generative Fill** is available when a `GenerativeFillProvider` is registered. With only an inpaint model
  registered, that model stands in: the receipt says "prompt ignored". With neither, it is unavailable.
- **Enlarger (AB-T-0292).** `register(enlarger:)` fills `.enlarge` with an `ImageEnlarger`: `name`, `availability`
  (`.available` by default, `.unavailable(reason:)` when it can't run here) and `enlarge(_ surface:, rect:) async
  throws -> Surface`, which returns `rect`'s pixels ×2 exactly, at `rect` doubled, in the input's format (model,
  depth, alpha). `CGImageEnlarger(name, availability:) { cgImage in … }` adapts a CGImage ×2 (anime4k-metal's
  `Anime4KUpscaler.upscale(_:)`) in one statement: pixels cross through `KitBridge` at the surface's depth in
  sRGB (extended at 32 bits) both ways, straight alpha travels when the region has transparency, an opaque
  region stays opaque. `ImageEnlargerClosure` takes a surface closure. There's no model-free tier. An empty slot,
  one emptied by `unregister(.enlarge)` / `removeAll()`, or an unavailable provider reports `unavailable(reason)`
  and `PCIntelligence.enlarger` is nil, so PCEngine's Image Size uses the chosen Resample alone and says why.
  `enlarge(_:rect:passes:)` runs the chain's passes and checks each result: the input's format, nothing outside
  the doubled rect.
- **Thread safety.** The registry is a `Sendable` final class over `Mutex`. An operation resolves its provider when
  it starts.

## Semantics kept from photocraft

- **Selections.** The canvas is analysed. The found region combines by `replace|add|subtract|intersect`, quantised
  to the GRAY8 grid and pruned, with nil meaning nothing selected (`crates/algo/src/selection.rs`
  `combine_region`). Finding nothing leaves the selection alone and returns `changed == false` with no transaction
  (`smartselect_cmds::apply`). Select Subject defaults to the composite (`sampleAllLayers: true`). Masks come out as
  Gray coverage surfaces at 8, 16 or 32 bits (`maskSample`, GRAY8 by default), positioned in document space,
  default 0.
- **Remove Background.** Adds a layer mask without touching pixels and drops the selection. The Background becomes
  "Layer 0", unlocked. "No subject found" is an error and nothing changes (`cutout_cmds.rs`). The transaction is
  `replaceLayer` + `setSelection(nil)` and undoes exactly; this is tested.
- **Content-Aware Fill.** The hole is selection coverage > 0, and the sampling window is Photoshop's
  (`content_aware::sampling_window`, mirrored and tested). The fill is blended in by coverage, so only selected
  pixels change, at the layer's own depth and colour model. A 16-bit or CMYK layer keeps every unselected sample
  bit-exact; this is tested. Output can be `current|new|duplicate`; a new layer carries alpha × coverage.
- **Remove.** The hole grows 2 px (`GROW`, through EraseKit's `maskDilation`). The window is the hole plus ¾ of its
  larger side, clamped to 32–512 px. The selection limits what changes. `newLayer` and `sampleAllLayers` (via
  `source`) are supported. The engine renders strokes and closes loops (PCPaint and PCAlgo `close_loops`) before
  calling.
- **Filters** (neural, white balance). They run on canvas ∩ layer content ∩ selection bounds, are blended by
  selection coverage, preserve alpha, and leave off-canvas layer pixels untouched (tested). Output can be the
  current layer, a new layer, or a new layer masked by the selection.
- **Locks and refusals.** Not-a-pixel-layer and locked pixels are refused with Photoshop's messages (photocraft
  `check_pixels_unlocked`).
- **Jobs.** Operations read a snapshot and return data plus an `EditTransaction`. They run async, report progress
  (monotonic, ending at 1), and are cancellable: task cancellation is checked between stages and propagated out of
  providers as `CancellationError`, never as a provider failure (tested). Transactions address layers by id, so they
  rebase onto a newer document (PCHistory).

## Deliberate deviations

1. **Kit fills ignore PatchMatch knobs.** Content-Aware Fill's `colorAdaptation`, `rotationAdaptation`, `scale`,
   `mirror`, `seed` and the auto source mask steer PatchMatch, which PCAlgo owns; they travel as `InpaintOptions`
   to an `OptionsInpaintProvider` (PCEngine sets PCAlgo's PatchMatch as the built-in classical tier under the `inpaint` slot).
   EraseKit and the model providers fill from the whole window.
2. **Transparent layers.** The Kits fill colour only, so alpha inside the hole is filled by EraseKit's classical
   diffusion on the alpha plane (tested), and the receipt notes it.
3. **Colour encoding.** Pixels cross to the Kits in the document's colour space: the embedded RGB profile, else sRGB,
   or extended sRGB at 32 bits. White balance and SDR → HDR assume an sRGB-like tone curve for the stored values. A
   linear-profile document (for example an EXR import) would want a ColorSync linearisation from PCPlatform.
4. **SDR → HDR and Super Resolution return new documents**, as Photoshop's Merge to HDR Pro and Enhance do. SDR →
   HDR output is 32-bit RGB tagged linear sRGB, where 1.0 is the BT.2408 HDR reference white (203 cd/m²).
5. **Select Subject has no result cache.** photocraft's `SubjectCache` (keyed by tile pointers) belongs in the
   engine. Tile generations make the same key.
6. **Smart Portrait is face restoration only.** The expression, age and gaze sliders are generative and not in
   scope.

## What's still missing

- **Generative Fill needs a model the fleet doesn't wire yet.** Clearly finished candidates in the bridge-indexed
  MLXEngine model registry (`mlx-engine-swift/docs/model-registry.md`; Home `image/PROD`, published, in-app
  validated):
  - **FLUX.2-klein-4B** (`flux2-klein-swift` v0.5.0, Apache-2.0; only the 4B; the 9B is non-commercial)
  - **Z-Image 6B** (`z-image-swift` v0.3.0, Apache-2.0)

  Both are `textToImage / imageEdit` models, not mask-conditioned inpainters. A provider would edit the window and
  composite through the selection, and neither has a ForgeCore adapter yet. Qwen-Image-Edit-2511 is only partially
  validated (🟡), and the Moebius diffusion inpainter is still WIP. `ERASE-PLAN.md` keeps diffusion Generative Fill
  as a separate, license-sensitive track.
- No ExtractKit classical subject tier. Its Tier 0 is compositing (`ControlMaskEncoder`), not detection, so
  without Vision, Select Subject has nothing. photocraft's heuristic subject (PCAlgo) could register as a
  `.classical` `MatteProvider`.
- Not covered: Select Sky, Sky Replacement, Depth Blur, Super Zoom, Generative Expand, Refine Edge (matting is
  PCAlgo's), video variants (the Kits have them), and PSD smart-filter persistence of neural filters.

## Change requests

**PCDocument**
1. Add a `DocumentOp.setLayerMask(LayerId, LayerMask?)`. Remove Background currently has to `replaceLayer` the
   whole node (cheap with copy-on-write, but it also overwrites content and properties if the transaction rebases
   onto a newer document).
2. Move `PixelFormat.components(fromRGBA:)` to PCFoundation and add a bulk `Surface.writeRGBA(_:_:)`, the inverse
   of `readRGBA`. `KitBridge.native` mirrors it per pixel today.

**PCFoundation / PCPlatform**
3. Add a ColorSync-backed "document → `CGColorSpace` + linearise/encode" hook in PCPlatform, so the bridge and the
   light tiers stop assuming an sRGB curve when a document has no profile or a linear one.

**For the lead to route to the Kit owners** (not filed; this task makes no AgentBridge records)
4. MaskKit: ship a Tier-1 Vision `PromptMaskProvider` (`VisionInstanceMaskProvider` here is the shape) and an
   "all instances" query for hover UIs.
5. ExtractKit: a mask-only entry point. `ForegroundExtractor.extract` always renders the cutout, which Select
   Subject throws away.
6. ForgeRestoreKit: name a Tier-0 `denoise` job (the guided filter + Immerkaer σ assembly here).
7. ForgeCore: adapters for face restore, defect detection and still upscaling that conform to a net-clean seam.
   Today the host needs closures, as in the snippet above.
