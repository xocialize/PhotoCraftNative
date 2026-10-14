# PCIO — port notes

PCIO is the bridge between the document model (PCDocument) and files: the Swift port of
photocraft's `crates/io` (document ⇄ PSD/PSB and the other layered formats) and `crates/format`
(the native `.pcraft` bundle), photocraft revision 184c226a, MIT OR Apache-2.0, © ArtCraft Team and
the PhotoCraft contributors. Swift 6.2 tools, Swift 6 language mode, macOS 26, Swift Testing, Apple
SDK frameworks plus the local packages PCFoundation, PCDocument, PCPSD, PCRender and PCAffinity
(no URL dependencies, no PCPlatform dependency).

## Targets and public entry points

| Target | Role | Main API |
|---|---|---|
| `PCIOCore` | shared helpers and the injected services | `DocumentCompositor`, `LayerContentRenderer`, `FlatImageCodec` (+ `ImageIOCodec`, `DecodedImage`, `FlatMetadata`), `SourceEncoding`, `PCIOError`, `ImportResult`, `ExportResult`, `Interrupt`, `Blocks`, `PSDPixels`, `GradientBake`, `BEReader`/`BEWriter`, `Deflate`, `CRC32`, `ZipReader`/`ZipWriter`, `BLAKE3`, `RawBlockList` |
| `PCIOText` | type layers ⇄ `TySh`/EngineData/`Txt2`, text styles | `PSDText`, `PSDStyles`, `TextStylesMap` |
| `PCIOMaps` | block ⇄ model mappings | `AdjustMap`, `EffectsMap`, `VectorMap`, `PatternMap`, `ChannelMap`, `CompsMap`, `SlicesMap`, `AnnotationsMap` |
| `PCIOSmart` | smart objects and smart filters | `SmartMap`, `Linked`, `DisplaceMap`, `CameraRawMap` |
| `PCFormat` | `.pcraft` | `PcraftFormat` (`save`, `load` from bytes/URL/`ByteSource`, `readManifest`, `readThumbnail`, `atomicWrite`, `listRecovery`/`recover`/`discardRecovery`), `SaveOptions`, `LoadOptions`, `FormatError`, `PcraftWriter`, `Autosaver`, `RecoveryStore`, the manifest model |
| `PCIOFormats` | other layered formats | `OpenRaster`, `Krita`, `PaintDotNet`, `EXRParts`, `LayeredTIFF`, `PSDTIFF`, `SVGImport`, `CompImport` (Compositor `.comp`, import only) |
| `PCIOAffinity` | Affinity documents (on PCAffinity's reader) | `AffinityImport` |
| `PCIO` | PSD/PSB import/export, dispatch, default compositor | `DocumentIO.importFile(name:bytes:options:)`, `DocumentIO.importFile(contentsOf:options:)`, `DocumentIO.export(_:as:options:)`, `IOOptions`, `PSDImport.document(_:options:)`, `PSDExport.file(_:options:)`, `PSDExport.export(_:options:)`, `PSDExportOptions`, `RenderCompositor`, `PSDCompositeOracle`, `FlatOrientation` |

Library products: `PCIO`, `PCFormat`, `PCIOCore`, and (for the engine) `PCIOFormats`, `PCIOSmart`,
`PCIOMaps`.

The PSD mapping never composites by itself (photocraft's rule): the merged image, previews and
thumbnails come from an injected `PCIOCore.DocumentCompositor`
(`func composite(_ document: Document, rect: PixelRect) throws -> [Float]`, interleaved samples in
the document's pixel format). The default is `RenderCompositor.shared`, PCRender's compositor
(`.automatic` backend: Metal when it can run the plan, else the CPU reference); the engine can pass
`RenderCompositor(PCRender.DocumentCompositor)` with PCPlatform's `LayerRasterizer` for text/shape
layers without pixels. Note the name clash: PCRender also has a `DocumentCompositor` (a class), so
code importing both writes `PCIOCore.DocumentCompositor` / `PCRender.DocumentCompositor`.

## File map

photocraft `crates/io/src` → Swift (`Sources/<Target>/…`):

| photocraft | Swift |
|---|---|
| `lib.rs` (import/export dispatch, options, errors, `merged_composite`) | `PCIO/DocumentIO.swift`, `PCIOCore/Errors.swift`, `PCIO/MergedImage.swift` |
| `psd_import.rs` | `PCIO/PSDImport.swift` |
| `psd_export.rs` | `PCIO/PSDExport.swift`, `PCIO/MergedImage.swift` (merged planes) |
| `psd_thumbnail.rs` | `PCIO/MergedImage.swift` (`PSDThumbnail`) |
| `multichannel_map.rs` | `PCIO/Multichannel.swift` |
| `tiff_layers.rs` | `PCIO/TIFFLayers.swift` |
| `text_import.rs` | `PCIO/DocumentIO.swift` (`TextImport`) |
| `flat.rs` (`image_to_document`, `import_flat`, `export_flat`) | `PCIO/DocumentIO.swift`; codecs `orientation.rs` → `PCIO/FlatOrientation.swift`; codecs `resolution.rs`/`orientation.rs` metadata → `PCIO/MetadataExport.swift`; codecs png/jpeg/webp/tiff metadata readers → `PCIOCore/FlatMetadata.swift` |
| `blocks.rs`, effects_map blend tables | `PCIOCore/Blocks.swift` |
| `pixels.rs` | `PCIOCore/Pixels.swift` |
| `gradient_bake.rs` | `PCIOCore/GradientBake.swift` |
| `adjust_map.rs` (+ cms `lutfile.rs` parts) | `PCIOMaps/AdjustEffects/AdjustMap.swift`, `AdjustLutFile.swift` |
| `effects_map.rs` | `PCIOMaps/AdjustEffects/EffectsMap.swift` |
| `vector_map.rs`, `pattern_map.rs`, `channel_map.rs`, `comps_map.rs`, `slices_map.rs`, `annotations_map.rs` | `PCIOMaps/DocumentMaps/*.swift` (same names, UpperCamelCase) |
| `smart_map.rs` | `PCIOSmart/SmartMap.swift`, `SmartPlaced.swift` |
| `linked.rs`, `displace_map.rs`, `camera_raw_map.rs` | `PCIOSmart/Linked.swift`, `DisplaceMap.swift`, `CameraRawMap.swift` |
| `text_styles_map.rs`; text crate `psd.rs`, `psd_styles.rs`, `engine_data.rs`, `fonts.rs` | `PCIOText/*.swift` |
| `ora.rs` | `PCIOFormats/Containers/OpenRaster.swift` |
| `kra.rs` | `PCIOFormats/Containers/Krita.swift` |
| `pdn.rs`, `pdn/nrbf.rs` | `PCIOFormats/Containers/PaintDotNet.swift`, `PaintDotNetNRBF.swift` |
| `exr_parts.rs` (+ codecs `exr.rs` reader) | `PCIOFormats/Containers/EXRParts.swift`, `EXRFile.swift`, `EXRCompression.swift` |
| `svg.rs` | `PCIOFormats/TIFFSVG/SVG*.swift` |
| psd `tiff.rs`; codecs `tiff.rs` Photoshop tags | `PCIOFormats/TIFFSVG/PSDTIFF*.swift`, `LayeredTIFF.swift` |
| `affinity.rs` (+ compose gradient handles) | `PCIOAffinity/*.swift` |
| — (new) | `PCIO/RenderCompositor.swift`, `PCIO/CompositeOracle.swift`, `PCIOCore/Services.swift`, `PCIOCore/BLAKE3.swift`, `PCIOCore/RawBlocks.swift`, `PCIOCore/ByteIO.swift` |
| — (new; Compositor's IO/ProjectStore.swift, MIT, © 2026 Wonder Assembly LLC) | `PCIOFormats/Compositor/CompManifest.swift` (manifest + version gates), `CompImport.swift` (package, assets, layer tree, clipping), `CompPixels.swift` (placement, masks), `CompMap.swift` (blend modes, adjustments, effects, text, shapes) |

photocraft `crates/format/src` → `Sources/PCFormat/`: `lib.rs` → `PcraftFormat.swift`, `Errors.swift`;
`manifest.rs` → `Manifest.swift`, `ManifestJSON.swift`; `store.rs` → `Store.swift`, `Codec.swift`,
`JSONTree.swift`; `convert.rs` → `Convert.swift`; `migrate.rs` → `Migrate.swift`; `read.rs` →
`FileRead.swift`; `finite.rs` → `Finite.swift`; `atomic.rs` → `AtomicSave.swift`, `FS.swift`;
`autosave.rs` → `Autosave.swift`; `zip.rs` → `PCIOCore/Zip.swift`; ruzstd's encoder/XXH64 →
`ZstdEncoder.swift`, `ZstdTables.swift`, `XXH64.swift`. Decoding is PCAffinity's `ZstdDecoder`
(see the `.pcraft` section).

Not ported: `abr_map.rs` (`.abr` brushes → `photocraft_paint::BrushPreset`; needs the brush
package's preset model, which PCIO does not depend on) and `raw.rs` (camera raw development;
needs photocraft-raw/cms, PCPlatform's domain).

## PSD fidelity (levels 1–7)

"Corpus" means measured on the 36 Photoshop-authored files (all RGB 8-bit; 449 layers); "synthetic"
means covered by generated documents in every mode/depth (the ported photocraft tests). Import
never fails on a readable file: what it can't map becomes a warning and is kept raw.

| Level | What | Import | Export | Status |
|---|---|---|---|---|
| 1 | Flattened image: merged data of every mode (Bitmap, Gray, Indexed, RGB, CMYK, Multichannel, Duotone, Lab) and depth 1/8/16/32, white matte removed | done | done: merged image from the injected compositor (PCRender by default), banded, white-matted, RLE (raw at 32-bit), thumbnails (1036), PSB when needed or asked | corpus + synthetic |
| 2 | Raster layers, user masks (density, feather, linked, disabled, default colour), blend mode, opacity, fill, visibility, names (`luni` + legacy), locks (`lspf`), colour labels (`lclr`), layer ids | done | done | corpus + synthetic |
| 3 | Groups (open/closed, pass-through), clipping, Blend If (blending ranges), knockout and the other Advanced Blending flags (`knko infx clbl tsly lmgm vmgm`), channel restrictions (`brst`), link groups (1026), effects reference point (`fxrp`) | done | done; divider records keep their own blocks | corpus + synthetic |
| 4 | Adjustment layers (every key photocraft maps; unknown or unreadable kept raw with a warning) and fill layers (`SoCo GdFl PtFl`, fill caches; pixels written with PCRender's `FillLayerRenderer`, equal to the live composite); layer effects (`lfx2`/`lfxs` typed, multi-instance, `lrFX` read; the original block kept while unchanged) | done | done | corpus (6 adjustment, 43 effects blocks) + synthetic |
| 5 | Type: `TySh` + EngineData + document `Txt2` to the typed model, original descriptors kept byte-identical while unchanged and complete, rebuilt in Photoshop's layout when edited or incomplete; the document `Txt2` kept only while the text is unchanged, never generated (see the oracle findings); styles (character/paragraph sheets) | done; layers without pixels are rendered through the injected renderer | done | corpus (64 type layers, 13 `Txt2` byte-exact) + synthetic; rendering needs PCPlatform's renderer |
| 6 | Smart objects: embedded/linked sources (`lnk2 lnk3 lnkD lnkE`), placed transform, warp, perspective quad, contents identity, the smart-filter stack (14 filters mapped, the rest verbatim), filter mask (`FEid`); vector masks (`vmsk`/`vsms`) and shape layers (`vscg vstk vogk`) | done | done (`.pcraft` sources are converted to nested PSD/PSB) | corpus (98 `SoLd`, 207 shape layers byte-identical) + synthetic |
| 7 | Layer comps (1065 + `cmls`), slices (1050), guides and grid (1032), alpha and spot channels (1006/1045/1077, Quick Mask 1022), ICC, XMP and EXIF (normalised: orientation 1, saved resolution, no stale thumbnail), resolution (1005), annotations (`Anno`, measurement scale), saved/work/clipping paths, patterns (`Patt`/`Pat2`/`Pat3`, transparency in Photoshop's array; placeholders for missing ones), artboards | done | done | corpus for guides/slices/paths/ICC/XMP/EXIF/resolution; synthetic for the rest (no comps, artboards, notes or alpha channels in the corpus) |

Mapped resources whose spelling Photoshop varies (1005 display units, 1032 grid, 1026, channel
names/options for the merged transparency) are also kept raw and written back while they still
describe the document; copies that add nothing (equal to what the export writes) are dropped on
import so a document → PSD → document round trip returns the same document.


## Other layered formats

| Format | Import | Export | Notes |
|---|---|---|---|
| OpenRaster (`.ora`) | layers, groups, blend modes (`svg:*` and Krita `krita:*` ids), opacity, visibility, offsets, `edit-locked`; `stack.xml` through `XMLParser` with external entities off | layers as PNG (non-raster layers rendered by the compositor, then masked as photocraft does), merged image, thumbnail | `OpenRaster` |
| Krita (`.kra`) | the merged PNG as an editable raster layer (photocraft's scope: not Krita's layer tree) | — (photocraft never writes `.kra`) | `Krita` |
| Paint.NET (`.pdn`, PDN3) | layers, blend modes, opacity, visibility (NRBF reader per MS-NRBF) | — (photocraft is import-only) | `PaintDotNet` |
| Layered TIFF | Photoshop tags 37724/34377 transcoded to a PSD model in either byte order, then the PSD importer; the TIFF's own ICC/resolution/XMP win | the PSD exporter's layer section and resources in the file's byte order next to the composite; Gray/RGB/CMYK 8/16/32, BigTIFF when needed; Lab and Multichannel save flat with a warning | `TIFFLayers`, `LayeredTIFF`, `PSDTIFF`; corpus: all 36 PSDs transcode to TIFF and back byte-identically in both orders |
| Multi-part EXR | parts and channel groups listed (`entries`), chosen ones imported as layers with an optional additive precomp; Cryptomatte listing; decoders for NONE/RLE/ZIPS/ZIP/PIZ/PXR24/B44/B44A (DWAA/DWAB/HTJ2K listed but refused) | — | `EXRParts`; NONE/ZIPS/ZIP/PXR24 checked bit-exact against ImageIO on real files |
| SVG / SVGZ | groups and shape layers (Bézier knots, fill, stroke, gradients), text outlined with CoreText, what shapes can't hold (clip paths, masks, filters, patterns, images, markers) rasterised by CoreSVG with a warning | — | `SVGImport`; photocraft parses with usvg and rasterises with resvg, here XMLParser + CoreGraphics/CoreSVG: a shape's own opacity goes on its layer (no wrapping "Group N"), markers and text on a path are rasterised, CSS is a selector subset, reflect/repeat gradient spreads and nesting past ~256 levels are CoreSVG's limits |
| Compositor (`.comp`, v1–v13) | the package directory: 8/16-bit PNG and OpenEXR layers, transforms, masks, folders, clipping, the 24 blend modes, the 12 adjustment kinds (Grain, Add Noise and the blurs as filter adjustment layers), the 6 effects, text and shape metadata, guides, resolution (section below) | — (import only, AB-D-0131; `sourceReadOnly`) | `CompImport`; dispatched by `DocumentIO.importFile(contentsOf:)` for a directory |
| Affinity (`.af`, `.afdesign`, `.afphoto`, `.afpub`) | spreads/artboards, groups, shapes (incl. clipping shapes), text, images as embedded smart objects, pixel layers, layer and vector masks, blend modes; the embedded preview with a warning when the native data can't be read | — (refused by name, as in photocraft) | `AffinityImport` on `Affinity.read`/`Affinity.preview` |
| Flat images | through the injected `FlatImageCodec` (default `ImageIOCodec`): straight alpha, Gray+alpha, 8/16-bit and half/full float read from the image's own samples, EXIF/XMP/text from the container, EXIF/TIFF orientation applied, EXIF/XMP resolution fallback, linear profile for EXR/HDR, multi-part EXR opened at its most colourful part; `Document.fileEncoding` from the file (JPEG quality from its quantisation tables, WebP lossless/lossy at 75: photocraft `file_encoding`, `SourceEncoding`) | PNG/JPEG/TIFF through the codec (photocraft `export_flat`): a plain single layer at its own model and depth, else the composite (CMYK/Lab as sRGB); alpha dropped when opaque; JPEG matted over white; EXIF/XMP/text/resolution embedded, normalised | the full codec matrix (WebP/AVIF/JPEG XL writing, GIF frames, TGA alpha channel, BMP palettes, JPEG quality estimate, camera raw) is PCPlatform's |

## Compositor `.comp` import (AB-T-0239)

`.comp` stays an import format (bridge decision AB-D-0131): Compositor's document package
(`manifest.json` + `images/`), versions 1–13, read as Compositor's `ProjectStore` reads it. A
document opened from one saves as `.pcraft` or PSD (`ImportResult.sourceReadOnly`).
`DocumentIO.importFile(contentsOf:)` takes it when the URL is a directory named `.comp` or holding a
`com.compositor.project` manifest; `CompImport.importDocument(_:codec:interrupt:)` takes a
`CompImport.Package` (a directory, or files in memory). Refusals are
`PCIOError.format("Compositor", …)` naming the rule.

**Checks, as `ProjectStore`:** the header first (format, then version, so a newer file reports its
number), then every gate of `validate`: opacity/blend modes v3, layer masks v4, clipping v5, folder
masks v6, adjustments v7, folder opacity and guides v8, the neighbouring-pixel kinds v9,
per-letter colours v10 and faces v11, 16-bit PNG v12, OpenEXR v13; image and mask names
`<id>.png|.exr|.mask.png`, masks 8-bit gray without alpha, the hierarchy (64 levels, no cycles) and
the clipping graph (no folders or adjustments as sources, chains under 256); every file inside
the package, a plain file, not a symbolic link, ≤ 4 MiB manifest / 512 MiB per asset; 30,000 px a
side, 10,000 layers, 800 MP of images and of masks.

**Mapping:**

| Compositor | PCDocument |
|---|---|
| layer PNG/EXR + transform (box, clockwise rotation, flips, sampling) | a pixel layer copied exactly when the grid sits one-to-one on whole pixels. Otherwise (scaled, turned, flipped or at a fractional position) a **smart object** (AB-D-0140, AB-T-0275): the layer's full-resolution image, decoded to the document's format and embedded losslessly (`<layer name>.png` at 8 or 16 bits, `.tif` float in a 32-bit document, with the document's profile), `SmartObject.transform` = `pixelToDocument` (quarter turns exact), and as its rendered appearance the pixels drawn as `LayerRenderer.draw` draws them (same CTM, interpolation and antialiasing) into a 16-bit context (half float for HDR). A transform back to 100 % re-renders the image itself (PCAlgo's `placeSource` is an exact shift there); a Nearest layer re-renders bicubic when its transform changes (warned). `CompImport.TransformedLayers.pixels` keeps the drawn pixels alone, warned, as before. Type and shape layers keep the drawn pixels as their cache. CoreGraphics' 32-bit float contexts are avoided: scaled with interpolation off they repeat a row's first pixel along the last row |
| 8-bit / 16-bit PNG / OpenEXR | an 8-bit document; any 16-bit layer makes it 16-bit; an OpenEXR passing white makes it 32-bit linear sRGB (OpenEXR holds linear light) with 8/16-bit layers decoded to linear, warned; an OpenEXR within white is a 16-bit layer, as Compositor loads it |
| folders | Pass Through groups with their opacity and mask (the mask hides beyond the folder's box). Compositor multiplies a folder's opacity and mask into each layer inside; Photoshop applies them to the folder's result, so overlapping layers inside differ (warned when the folder holds more than one) |
| layer masks (1×1 uniform, linked, unlinked `maskPlacement`, disabled) | `LayerMask` at the document's depth; beyond its box an unlinked mask keeps the value most of its edge has (`LayerMask.background`) |
| clipping (`maskSourceID`) | a run of visible layers clipped to the visible layer right below them in the same folder is a Photoshop clipping group (Compositor composites such a run as one stack in the base's mode, as Photoshop's default "Blend Clipped Layers as Group"); hidden layers clipped to the same base may sit in the run. Any other link (base not directly below, hidden or in another folder) has no Photoshop form: the source's coverage (its alpha × effective opacity × its own mask × its own source) is baked into the clipped layer's mask, warned. A clipped adjustment outside a stack is never drawn by Compositor: imported hidden, warned |
| the 24 blend modes | by name (Compositor uses Photoshop's) |
| Hue/Saturation (master, six ranges with their bands, colorize) | `.hueSaturation`; "invert range" has no equivalent (warned) |
| Levels, Exposure, Invert, Black & White (+ tint), Color Balance, Gradient Map | the same adjustment; a tint becomes Photoshop's tint colour (HSL at ½ lightness); Gradient Map reads brightness with Photoshop's weights (warned: Compositor's are Rec. 709's) |
| Curves | pencil curves holding the 256 levels Compositor's monotone Hermite curves evaluate to (exact at 8 bits; the handles are not kept, warned) |
| Grain, Add Noise, Gaussian Blur, Motion Blur | filter adjustment layers (`Adjustment.filter`, AB-T-0258) with Compositor's settings and seeds; PCRender draws them (no Photoshop adjustment layer: a PSD save writes them as empty pixel layers, below) |
| stroke, drop shadow, inner shadow, outer glow, inner glow, colour overlay | Photoshop layer styles in Normal (Compositor's renderer), sizes scaled from layer pixels to document pixels; Compositor's own effect shapes differ (its outside stroke is a square dilation) |
| text metadata | a type layer: runs from the UTF-16 colour/face runs, size and leading in points at the document's resolution, tracking in 1/1000 em, box or point text placed as Compositor lays it out (12 px padding); Compositor's PNG is its rendered pixels until edited |
| shape metadata | a shape layer (live rectangle/ellipse/line when upright) with Compositor's PNG as its pixels |
| guides, resolution | `Document.guides`, `resolutionDpi` (72 when missing) |

**Transformed layers as smart objects (AB-T-0275, AB-D-0140).** `PCEngineTests/CompSmartObjectTests`
imports a package of layers scaled to 25 % (a 300 × 220 image, more than one tile), turned 30°,
flipped at 200 % from a fractional origin, and turned a quarter and flipped, at 8 and 16 bits:
- every one is a smart object whose embedded file decodes to the layer's image exactly;
- a `.pcraft` save (package and single file) and reopen keeps the file, the transform and the
  rendered pixels exactly;
- a PSD or PSB save writes them as placed layers (`PlLd`/`SoLd`, the file in `lnk2`), and PCPSD's
  re-read keeps the file and the rendered pixels exactly, and the transform exactly except the 30°
  turn's, which comes back within an ulp of each term (a placed layer stores the corners the source
  lands on, not the matrix);
- after every round trip, a Free Transform back to 100 % at a whole pixel re-renders each image
  pixel for pixel (PCEngine's `snapAffine` and PCAlgo's exact shift);
- PCRender composites them (their rendered pixels) on the GPU within 2 levels of the CPU reference,
  at full resolution and at levels 1 and 2.

Photoshop 27.11 (`ps-oracle sweep`, 2026-10-14, after the offline pre-screens) opens the 8- and
16-bit PSDs of that document with the layer tree matching, the four layers as smart objects
(`layerKind` 5), and its composite within 1 level (mean 0.003) at 8 bits and 0.012 levels at 16.

**Parity with Compositor's own oracle** (`PCIOTests/CompCorpusTests`): every file of the
CanvasFixtureGenerator set (`PCIO_COMP_FIXTURES`, default `<fixtures>/comp-fixtures`; 43
documents, 165 files, plus 5 motion fixtures) imports, and PCRender's composite (CPU and Metal) is
compared with the PNG Compositor exported, premultiplied at 8 bits:

| Set | Fixtures | Max levels (CPU / Metal) | Notes |
|---|---|---|---|
| blend | 24 | 19 modes ≤ 1 / ≤ 2 | Hue 3, Saturation 9, Color 4, Hard Mix 255 (74 px), Vivid Light 255 (2 px): the oracle's engine is not Photoshop's (below) |
| opacity | 1 | 1 / 1 | |
| mask | 2 | 1 / 2 | |
| clip | 1 | 1 / 1 | |
| folder | 1 | 21 / 21 | Pass Through by design; with its opacity and mask pushed into its layers (Compositor's way) 3 levels |
| effects | 1 | 197 / 197 | layer-style shapes |
| adjust | 13 | 0 for Curves, Invert, B&W, Add Noise; 1 Grain; 1.83 Motion Blur; 2.54 Gaussian Blur (30 px over 2); 3–4 Hue/Sat, Levels, Exposure; 28 Gradient Map (luminance weights); 53 Color Balance (Photoshop's algorithm) | the four filter kinds held to their bounds (`filterBounds`) |
| motion | 5 | 1.52 at 0°, 2.00 at 90°; 13 at 45°/20 px (115 px over 2), 7 at −30°/25 px (76 px), 34 at 60°/4 px (806 px) | Motion Blur adjustment layers, held to these bounds: off the axes `CIMotionBlur` isn't a Gaussian streak (PCRender PORT-NOTES) |

Compositor's oracle blends through CoreGraphics (14 modes) and Core Image pinned to sRGB (10).
Run on the layers of Photoshop 27.11's own ps-corpus `blend-*.psd` files
(`CompCorpusTests.oracleEnginesAgainstPhotoshop`), those engines miss Photoshop by: Hue 4,
Saturation 8, Color 3, Luminosity 6 (CoreGraphics; PCRender ≤ 1.0 on the same files), Hard Mix 255
(Core Image gives 0 on every b + s = 255 tie; Photoshop gives 255 when s ≤ 127, 75/75 ties), Vivid
Light 25, Color Dodge 25 (Core Image); every other mode ≤ 2. The fixtures that miss 2 levels are
exactly those; the test pins them at what they measure. Measuring them also found PCRender's Hard
Mix tie rule wrong against Photoshop (fixed in PCRender: blend-hardMix.psd ties 38 → 0 off). Vivid
Light's two 0/0 ends (base 0 under blend 255, base 255 under blend 0) have no Photoshop sample in
the corpus; PCRender follows photocraft's psblend expectations there.

## Corpus round trip (36 Photoshop files)

`Tests/PCIOTests/CorpusRoundTripTests.swift`, corpus at `PCPSD_CORPUS` (default
`<fixtures>/psd-corpus`, see Tests; skipped when absent):
PSD import → Document → export (default options; the merged image passed in through a
`FixedCompositor` holding Photoshop's own composite) → re-import, plus a second generation. Release
build, 2026-10-12:

| Check | Result |
|---|---|
| files / layers | 36 / 449 |
| re-imported document equals the first import (`DocDiff`: every layer field, pixels, masks, effects, raw blocks, metadata after EXIF/XMP normalisation, resources and global blocks in order) | 36/36 |
| layer blocks byte-identical to Photoshop's (all but the regenerated `luni lyid lsct lsdk iOpa lspf lclr`) | 4068/4068 |
| global blocks kept / image resources kept byte-identical (thumbnails, version info, layer state, XMP/EXIF excepted: regenerated by design) | 36/36 / 36/36 |
| ImageIO opens the export | 36/36 |
| ImageIO's composite = the stored merged data (premultiplied 8-bit) | 36/36, max difference 0 |
| merged image = the composite passed in | 36/36 |
| PCPSD linter (`compatibilityIssues(decodeChannels: true)`): errors / warnings | 0 / 0 on 36/36 |
| second generation: layer records identical | 36/36 |

Sibling measurements on the same corpus: 64/64 type-layer EngineData and 13/13 `Txt2` rewritten
byte-exactly, 98/98 `SoLd` parse and resolve, 207/207 unedited shape layers keep their vector blocks,
all 36 files transcode to layered TIFF and back byte-identically in both byte orders.


## Photoshop-generated corpus (`<fixtures>/ps-corpus`, `PCIO_PS_CORPUS`)

153 PSD/PSB files written by Photoshop 27.11 for this port (every mode and depth, all blend modes,
adjustment and fill layers, effects, type, shapes, smart objects and smart filters, masks, channels,
PSB), measured with the same tests (release, 2026-10-12), reported separately:

| Check | Result |
|---|---|
| files / layers | 153 / 706, none failed to import or export |
| re-import equal | 150/153 (the 3 others are Bitmap/Indexed files, written as Grayscale/RGB by design, warned) |
| layer blocks byte-identical | 4011/4011 |
| global blocks / resources kept | 153/153 / 153/153 |
| ImageIO opens (modes it reads) | 147/147; RGB composite exact 128/128 |
| merged image = composite passed in | 152/153 (16-bit Lab: 0.003 off, chroma rounding) |
| linter clean | 153/153, 0 warnings |
| second generation identical | 153/153 |
| PSD → `.pcraft` → document / → PSD | 153/153 equal; 4011/4011 layer blocks kept |
| flattened files (no layer records) | 6, saved with their Background as a layer record |

Found and fixed with it: smart objects with an all-white filter mask lost their original
`PlLd`/`SoLd` and the document's `FEid`; layers whose effects Photoshop wrote only as `lmfx`
gained an `lfx2`; spot-ink channel options turned CMYK inks into RGB; Multichannel resources lost
their order; the slices' group name was lost through `.pcraft`.

Composite oracle on it (PCRender CPU / Metal, same thresholds; 2026-10-13, with PCRender's later
fixes and the Smooth gradient bake): **135/148 pass on both** (109/148 at first), 5
files without a usable merged image, 0 rasterizer misses, mean of per-file means 1.29 levels,
largest Metal−CPU gap 0.076. The 13 failures are compositor fidelity (PCRender's, listed in its
PORT-NOTES): Dissolve, the CMYK and Lab blend bands, Luminosity, Brightness/Contrast, Vibrance,
Satin (alone and in `fx-all`), the five adjustment stacks. `adj-gradientMap` passes now (max 2, mean 0.21, 0.05 % off; was
25.6 % off). Per-file lines: `ORACLE ps-corpus <file>: …`.

## Composite oracle (PCRender vs Photoshop's merged image)

`PSDCompositeOracle.oracleCase(contentsOf:)` imports a PSD and pairs the layered document with
Photoshop's merged image over `document.bounds` as straight RGBA (8/16-bit normalised, 32-bit as
stored, CMYK/Lab/Gray through `Surface.readRGBA`, `flattenedOver: (1, 1, 1)` when Photoshop matted
it white); `PSDCompositeOracle.register()` installs it as PCRender's `CompositeOracle` loader.
`CompositeOracleTests` composites every corpus file with PCRender on the CPU and on Metal
(`PlaceholderRasterizer`: cached rasters only, misses counted). Thresholds are PCRender's: mean ≤ 1
level and ≤ 2 % of pixels more than 2 levels off (premultiplied 8-bit levels). Release build:

- **CPU 36/36 pass, Metal 36/36 pass**; mean of per-file means 0.009 levels; worst per-file max
  0.5 (CPU) / 0.6 (Metal) levels; 0.00 % of pixels > 2 levels off in every file.
- Rasterizer misses: 2 (both in `GraphGroup.psd`, layers without a cached raster; the file passes).
- Largest |Metal − CPU| difference of per-file means: 0.054 levels.
- Per-file lines are printed as `ORACLE <file>: cpu max … mean … | metal max … mean …`. The corpus
  is 36 small RGB 8-bit files (Unity package icons), not photocraft's 256-file oracle set, so these
  numbers are not comparable to photocraft's 133/256.


## Photoshop 27.11 oracle findings and fixes

The oracle agent opened PCIO's exports in Photoshop 27.11
(`Tools/PhotoshopOracle/RESULTS.md`). Every cause it found in PCIO is fixed; photocraft 184c226a
has each gap too (lines below). The tests now write and check all of them (`compatibilityIssues`
has a rule for each, PCPSD's).

| # | Photoshop | Cause | Fix | Regression tests |
|---|---|---|---|---|
| T1 | **crashes** on open | a type layer's `TySh` written verbatim from `psdRaw` whose EngineData lacks structures Photoshop needs (test fixtures, hand-built files; photocraft `psd_export.rs:570`) | `psdRaw` is trusted only when `PSDTypeTool.missingPhotoshopStructures()` is empty (PCPSD); otherwise `buildTySh` rebuilds it fresh; the test sweep checks every exported type layer with `photoshopStructureGaps()` | `TypeLayerEngineDataTests` |
| BM | refuses, or a modal | a blend mode Photoshop doesn't offer in the document's mode/depth; Pass Through on a non-group (photocraft `psd_export.rs:474`, `:964`) | `PSDBlendMode.nearestAllowed` (PCPSD's measured table) for layers and groups, with a warning naming the layer and both modes | `BlendModeAcceptanceTests` |
| GM | refuses | `grdm` length not a multiple of 4 (photocraft writes 126/146 bytes and pads only odd → even) | every generated layer block is 4-aligned (`PSDTaggedBlock.fourAligned()`, pad inside the length; `shmd` per item); blocks kept from a file keep their bytes | `LayerBlockAlignmentTests` |
| F1 | refuses | `Lr16`/`Lr32` written before the file's `Mt16`/`Mt32` (photocraft `psd_export.rs:1630`: layer info at index 0, a kept matte block after it, negative layer count) | Photoshop's layout: an empty `Mt16`/`Mt32` first when a 16/32-bit document with layers has merged transparency, the layer info next with a positive count; kept matte blocks (`Mtrn`/`Mt16`/`Mt32`) are dropped and regenerated | `MatteBlockOrderTests` |
| TX | refuses ("General Photoshop error") | a `Txt2` generated by `PSDText.buildTxt2` (photocraft does the same); the files open once it is dropped, and type files without `Txt2` open fine | no generated `Txt2`: the file's own block is kept only while regenerating it gives back its bytes (text unchanged); otherwise dropped with a warning. Optical kerning (only `Txt2` can say it) is written as Metrics with a warning. **Open:** which field Photoshop rejects (PCIO's block has only `/98`, an empty `/0` and the text objects; Photoshop's carries the document resources under `/0`) — for the oracle to bisect | `PSDKerningTests` |
| PT | refuses, even with no layers | pattern data PCIO wrote: transparency in the *user mask* array (index 24). All 23 transparent patterns Photoshop 2026 ships (312 in its `.pat` presets) keep it in the *sheet mask* array (index 25) and leave index 24 unwritten; PCPSD and photocraft (`patterns.rs:383`) use 24 | the written bytes are rearranged (`PatternMap.photoshopBlock`/`photoshopPatFile`) until PCPSD writes index 25; `Pat2` at 16 bits; a kept pattern block that doesn't parse is dropped with a warning; a pattern fill or style whose pattern the document lacks (also refused) gets a grey placeholder of that name, with a warning | `PatternMapTests`, `RoundTripTests.missingPatternsAreWrittenAsPlaceholders` |

**Second pass (C′, 1,302 of 1,313 exports opened, 0 crashes).** Adjustment layers that came back
as pixel layers, 254 layers in 89 files:

- **Cause: Photoshop doesn't offer that adjustment in the document's mode/depth.** The ps-corpus
  builder's own notes record Photoshop 27.11 refusing to create them ("Could not complete the
  command because that content type is not supported for this color mode"): CMYK has no Black &
  White, Exposure, Vibrance; Lab no Black & White, Channel Mixer, Exposure, Selective Color,
  Vibrance; Grayscale no Hue/Saturation, Color Balance, Black & White, Channel Mixer, Photo
  Filter, Selective Color, Vibrance, Color Lookup; 32-bit no Gradient Map, Invert, Posterize,
  Threshold, Vibrance. **Proof** (`AdjustmentAvailabilityTests.photoshopOracleRunAgreesWithTheTable`,
  over the run's JSON and snapshot): of the 1,826 adjustment layers in the files Photoshop opened,
  all 224 of those kinds came back as pixel layers, every one of the other 1,572 stayed an
  adjustment except the Color Lookups below and one truncated Levels fixture.
  `AdjustMap.photoshopOffers(_:mode:depth:)` holds the table; the export warns per layer
  ("Photoshop has no Invert adjustment in 32-bit RGB documents; it opens the layer as an empty
  pixel layer") and still writes the block, so PCIO reads it back. The generated test document
  holds only offered kinds; the rest are exercised outside the acceptance set.
- **Color Lookup (29 layers, RGB 8/16).** With no table chosen PCIO wrote a 2³ identity cube;
  it now writes Photoshop's own 24-byte block (version 1, an empty descriptor), which every
  Photoshop-written lookup in ps-corpus is, and reads it back as a lookup without a table. With a
  table (`LUT3DFileData`, empty `profile`) Photoshop still opens a pixel layer: its own table
  layers carry the colour profile it builds from the table (the oracle's scripted
  `LUT3DFileData` was refused too). The export warns; writing that profile is open.
- **Fixtures out of the acceptance set** (`ExportSweep.excluded`): the hostile type sizes
  (1e30 pt, Double.max, 12 pt × 1e12, 12 × 1,100; also passed as `knownLintIssue` now that
  PCPSD's `typeSizeOutOfRange` flags them), the 0 pt type layer, the truncated adjustments, the
  stand-in `clrL`/`CAI `/`Anno`/`Txt2`/`vmsk` blocks, and adjustments in a mode Photoshop doesn't
  offer them.
- **A path-less, version-0 `vmsk`** (`rasterLayerBlocksPreserved`): Photoshop doesn't read it as a
  vector mask. The writer keeps it (it doesn't drop data it was given; Photoshop opens the file
  and ignores the block); the test says so and stays out of the acceptance set.
- **Artboards.** Photoshop's reference (`ps-corpus/artboard-blend.psd`, made by the oracle):
  an artboard's record and `lsct` both say Normal (`lsct` type 1/2, `8BIM`, `norm`, sub-type 0),
  `lnsr` is `artb`, and `artb` comes before `fxrp`; a plain Pass Through group keeps `pass` in
  its `lsct` and writes Normal in its record. PCIO now writes both that way
  (`ArtboardGuideOrderTests`), and a Pass Through artboard (the model's default) is written as
  Normal with a warning. Photoshop also writes a document `artd` block, which PCIO doesn't
  (Photoshop opens the files without it), and no `lnsr` on its plain group records, where
  PCIO's fresh groups carry `lset`.
- **Artboard composites (C‴):** PCRender composites an artboard's children with their own
  modes: `ArtboardCompositeTests` matches Photoshop's composite of `artboard-blend.psd`
  (`composites/artboard-blend.tif`) within 2 levels everywhere on the CPU and on Metal, and the
  Multiply square within 1. The one export whose merged image showed "Mul" as Normal came from a
  test that exported with `StoredPixelsCompositor` (a Normal-only stand-in); it now uses the
  default compositor. Other tests still export with that stand-in, so their merged images ignore
  modes, adjustments and effects (their composite comparisons in the oracle say nothing about
  PCRender).
- **Kept blocks Photoshop refuses a file for** (bisected by the oracle: a bare `SoLd` whose
  file no `lnk2` item carries, a `PlLd` that doesn't parse, an `lnk2` item labelled `liFE` with
  an `liFD` layout, a 0-byte `SoCo`): the export re-checks them with PCPSD's rules
  (`placedLayerWithoutLinkedData`, `placedLayerDataUnreadable`, `linkedFileKindMismatch`,
  `fillLayerDataUnreadable`) and repairs or drops them with a warning
  (`PSDExport.sanitizeKnownRefusals`): the item is relabelled with the kind it reads as, a bare
  `SoLd` is completed with Photoshop's placement keys (`SmartMap.completedPlacedData`; it then
  opens as a missing link), unreadable placed data and fill data are dropped.
- **Color Lookup with a table** (15 still pixel layers): no Photoshop-written lookup with a
  table exists in ps-corpus (the builder's scripted `LUT3DFileData` was refused), so its
  `profile` can't be diffed yet; the file needed is in the report to the lead.

Byte comparison against Photoshop's own patterns (ps-corpus `fill-pattern.psd`,
`fx-pattern-overlay.psd`: one indexed 946² "Tree Tile 4"; the Photoshop 2026 preset `.pat` files,
read only): header, name (UTF-16 with its NUL), id, rectangle, channel count 24, 26 arrays with
4-byte empty slots, per-array depth/rectangle/depth/compression and the pad to 4 all match. Other
differences, none known to matter: Photoshop stores most 8-bit channels raw where PCPSD uses
RLE (its own files have both); its PackBits runs differ from PCPSD's (both decode the same); an
indexed pattern has 4 bytes after the palette (`01 00 00 ff` in 25 of 26 presets, `00 83 00 82`
in one: likely colour count and last/transparent index) that PCPSD skips on read and doesn't write
(PCIO writes indexed patterns as RGB, so only PCPSD's own rewrite is affected). Candidate fields
for the oracle if pattern files are still refused: the alpha array index (24/25), the pattern
depth in 16/32-bit documents (PCIO writes the pattern's own depth; every Photoshop pattern seen is
8-bit), RLE vs raw, the post-palette bytes.

Test fixtures that were not Photoshop data (the oracle flagged them; the files were refused for
them, not for PCIO): the generated document's truncated `selc` (now a real Selective Color),
6-byte `FMsk` (now 12 bytes), garbage `Patt`/`lnk2` in the raw-preservation test (now the empty
`Patt` Photoshop writes and a 12-byte `FMsk`). Fixtures that are damaged on purpose (a truncated
adjustment kept verbatim, an unreadable `Anno`, stand-in `CAI ` bytes, a PCIO-built `Txt2`) are
no longer saved to `pcio-exports` (`ExportSweep.knownRefused`). PCPSD's `PSDTestGen.small` still
carries a 2-byte `Patt`; PCIO's export now drops it as unreadable.

### Requested by PCRender and PCEngine (same delivery)

- **Gradient Map smoothness (PCRender `adj-gradientMap`, 25.6 % of pixels off).** The model has no
  smoothness or interpolation method (`Adjustment.GradientMap` holds stops, reverse, dither;
  PCDocument), so the bake was fixed instead. Solving Photoshop's output colours for the stop
  weights showed a linear scheme in Oklab, and the fit is exact to a level:
  Smooth = Catmull-Rom through the stops *and* each segment's midpoint (the average of its stops,
  at the midpoint location), end tangents 0.7 × the end chords, every channel clamped to its
  segment's range (`GradientBake.smoothKnots`/`smoothEval`; also used for Smooth gradient fills
  and styles). On ps-corpus `adj-gradientMap.psd` through PCRender: **25.5 % → 0.0 %** of pixels
  more than 2 levels off (max 8 → 2, mean 0.58 levels). With Photoshop's own luminance for the map
  input (0.30/0.59/0.11; PCRender uses `ColorConvert.rgbToGray`, 0.299/0.587/0.114) it is max 1,
  mean 0.09. The two-stop easing photocraft measured is reproduced within 0.005.
- **Fill layers through `FillLayerRenderer`.** PSD export writes a fill layer's pixels with
  PCRender's `FillLayerRenderer.render(_:fill:canvas:patterns:format:)` (unless Photoshop's own
  cache is still valid); the injected renderer's `renderFill` is no longer asked (the protocol
  requirement stays for source compatibility; PCEngine's `EngineIO.renderFill` can go), and the
  test kits' own fill rasterisers are gone. A solid colour's alpha is the layer's fill opacity
  (`SoCo` has no alpha), so its pixels are the opaque colour, as Photoshop's are: before, the
  alpha was applied twice once PCRender started compositing the fill cache (CMYK 0.7 → 0.49).
  `FillLayerPixelsTests`: the stored pixels composite like the live fill (solid, linear, radial,
  pattern) within 1e-6 in RGB, CMYK, Lab and Gray at 8 and 16 bits — 16-bit Lab within 5e-5,
  because PSD's a*/b* scale has 65280 steps to the document's 65535.
- **Library products** `PCIOFormats`, `PCIOSmart`, `PCIOMaps`.
- **Patterns:** PCPSD writes transparency in the sheet-mask array now; PCIO's byte rearranging
  (`PatternMap.photoshopBlock`/`photoshopPatFile`) is gone.
- **Per-document CMYK** (`IOOptions.cmykConverter`, a `CMYKConverterFactory`): import and export of
  a CMYK document run inside `ColorConvert.withCMYK` with the converter built from its ICC
  profile, so fill colours are separated, and gradient-map stops read, through the document's own
  profile. PCIO has no ICC engine of its own; the engine injects PCPlatform's ColorSync converter
  (the tests a ColorSync one). Without one, the process-wide conversion is used, as before.
- **HEIC metadata:** for containers FlatMetadata doesn't parse, `ImageIOCodec` takes EXIF from
  ImageIO's properties (serialised through a one-pixel JPEG's APP1, with the real pixel size) and
  XMP from `CGImageSourceCopyMetadataAtIndex` (when it holds more than ImageIO's EXIF/TIFF
  mirror), so a HEIC's metadata reaches the document and an exported JPEG has Orientation 1.
- **`Document.fileEncoding` on flat import** (`SourceEncoding.fileEncoding`, ported from
  photocraft `source_settings.rs`/`flat.rs`): the same values PCEngine's `EngineIO` computes today
  (a lossy WebP gets 75, as there), so its stopgap can be removed.
- PCRender gaps met on the way (reported, not changed): in a Grayscale document the live
  compositor draws an RGB fill colour, and Selective Color, in colour (the written pixels and the
  merged image are grey); the generated test document therefore uses Selective Color only in the
  colour modes.


## photocraft's Photoshop-exchange issues, and what the Swift path does about them

The issue bodies are not in the repository; `docs/gaps.md` (G1) lists their titles, and
photocraft's own code comments record the refusal causes it measured in Photoshop 27.11. PCIO does
not drive Photoshop: acceptance rests on PCPSD's linter (`compatibilityIssues`), ImageIO, byte
identity with the records Photoshop itself wrote, and the Photoshop oracle agent's opens of
`$SCRATCH/pcio-exports` (next section).

- **#1281 "Photoshop 26.6 cannot reopen our files" and #2469 "PSD not opening in Photoshop".**
  Causes photocraft found and fixed one by one: an `8B64` block inside a PSD ("not compatible with
  this version"); extra-channel name resources one entry short ("unexpected end-of-file"); odd
  block lengths without the pad (#200); a regenerated `Txt2` for unchanged type (#2374). What
  photocraft still does at 184c226a: every record is written in its own minimal shape (only the
  blocks it models; no `lnsr`/`clbl`/`infx`/`knko`/`lspf`/`lclr`/`fxrp`, flags without bit 3, cc+1
  blending ranges where Photoshop writes cc+2, 12-byte folder `lsct` without sub-type), a shape no
  Photoshop-written file has; and
  it still rewrites `Txt2`: a style that leaves out the auto-kern mode `/11` (Photoshop omits the
  default, Metrics) is re-emitted with `/11 1`, so 12 of the corpus's 13 `Txt2` blocks change on an
  unmodified re-save. The Swift path:
  1. writes every record in Photoshop's measured shape by default
     (`photoshopRecordConventions`): block set and order measured on the corpus (content blocks,
     then `luni lnsr lyid iOpa clbl infx knko lsct lspf lclr shmd PlLd SoLd vstk sn2P fxrp lyvr`),
     Photoshop's defaults, flags `0x08`/`0x18`, cc+2 blending ranges, 16-byte folder `lsct` with
     sub-type 0, divider records with their own blocks (kept in the synthetic `PcDv` block), image
     resources in Photoshop's order with its IPTC/print-output defaults; photocraft's shape stays
     available (`photoshopRecordConventions = false`) and is what the ported photocraft tests use;
  2. keeps everything it doesn't model byte-identical and keeps a modelled block's original bytes
     while they still decode to the model (corpus: 4068/4068 layer blocks, all global blocks and
     resources, 64/64 EngineData and 13/13 `Txt2` byte-identical; the `/11` default is read as
     Metrics and left out, fixed in PCIOText);
  3. keeps photocraft's fixes (`8B64`→`8BIM` in PSD, complete channel-name lists, pads,
     never-zero-sized headers);
  4. runs PCPSD's linter on every export in the tests: 0 errors and 0 warnings on all 36 corpus
     round trips and on every synthetic export.
- **#2465 "a CS2-era smart object unavailable".** CS2 placed layers carry only `PlLd` (no `SoLd`)
  and their file in a global link block found through the `PlLd` uuid. The importer takes a smart
  object from `SoLd`, `PlLd` or `SoLE`, reads uuid and transform from whichever exists
  (`Blocks.parseSmart`), and PCPSD's link reader resolves `PlLd`-only items; unchanged placements
  are written back with their original `PlLd`.
- **#1764 "PSB smart object blank".** A PSB stores link blocks under `8B64`/long lengths and may
  nest PSB sources. PCPSD reads long-length keys by table with a probing fallback for writers that
  disagree; `Linked` reads/writes PSB link items; the exporter converts a `.pcraft` source to a
  nested PSB when it is too big for PSD and keeps an embedded source's bytes as they are. Covered by
  synthetic tests only (the corpus has no PSB).
- **#579 "perspective placed layers flattened".** An affine-only model drops the fourth corner of a
  Distort/Perspective placement, and a re-save then rewrites it as a parallelogram. The importer
  keeps the quad (`SmartObject.perspective`, `Blocks.parseSmartPerspective`) and the warp; an
  unchanged placement (transform, warp, perspective, filter stack) keeps its original
  `SoLd`/`PlLd` bytes and Photoshop's cached pixels; a regenerated `SoLd` writes the quad
  (`PlacedSpec.perspective`), and re-rendering a filter mask goes through the injected
  `placeSource` (PCAlgo's `warp::place_source`). Rendering a *stale* perspective placement is the
  compositor's job (PCRender/PCAlgo), not PCIO's.
- Also met on the way: #200 (pads, kept), #2374 (`Txt2`, see above, fixed further), #375 (PSB over
  4 GB on Windows: not applicable, files are memory-mapped on macOS and sizes are 64-bit
  throughout).


## `.pcraft` (PCFormat)

Layout, manifest, migrations, tile store, previews, atomic save, autosave and recovery are
photocraft-format's, so bundles go both ways:

- **Content addressing — BLAKE3.** photocraft names every tile and blob by the BLAKE3 hash of its
  uncompressed bytes and verifies it on load. The SDK has no BLAKE3 (CryptoKit is SHA-2 only), so
  `PCIOCore.BLAKE3` implements it (SIMD state, unrolled compression, incremental API; checked
  against the specification's vectors and against blake3-wasm on 35 lengths). 64 MiB hash in
  105–150 ms on one thread, 9–11 ms on all cores.
- **Decoding — PCAffinity's zstd, no second decoder.** Tiles (size known from the manifest) decode
  through `PCAffinity.ZstdDecoder.decompress(_:expectedSize:maxWindow:)`; blobs (photocraft
  records no blob length and ruzstd writes frames without a content size) through
  `decompress(_:maxSize:maxWindow:)`, bounded by `LoadOptions.maxBlobBytes` (past it:
  `limitExceeded`). PCAffinity refuses a frame with empty content (Affinity never stores one), so
  an empty blob is recognised from its frame header alone (`PcraftCodec.isEmptyFrame`: header, one
  last raw/RLE block of size 0, the checksum of nothing). The interim `BoundedZstd` decoder is gone.
- **Writing — real zstd frames (chosen).** Options were (a) photocraft-compatible zstd, (b) a
  native variant photocraft can't read (LZFSE objects flagged in the manifest), (c) raw/RLE-only
  zstd frames. `ZstdEncoder` writes (a): zstd's "fast" LZ77, Huffman literals, FSE sequences, RLE
  and raw blocks, XXH64 checksums. Measured on a 4096² RGBA8 layer in 256 tiles (release, Apple
  Silicon): raw/RLE frames 61.0 MiB; ZstdEncoder 32.6 MiB, 310 ms on one core / 23–32 ms on all
  (libzstd level 1: 33.1 MiB, ≈ 270 ms), decoded by PCAffinity in 450–460 ms on one core; LZFSE
  28.5 MiB but ≈ 940 ms to write and unreadable by photocraft.
  Whole-document save 93–116 ms, load 34–40 ms. libzstd decodes our frames; both decoders read
  libzstd's frames at every level.
- **photocraft-saved files open.** No photocraft binary or toolchain is available, so the
  evidence is a bundle built exactly as photocraft writes it (`Tests/PCFormatTests/PhotocraftBundle*`:
  serde_json's manifest shape — field order, `null`s, `1.0` floats, internally tagged content —,
  frames without a content size, names from the reference BLAKE3): it loads, and re-saving it
  yields the same object names. All 115 photocraft-format tests are ported (117 tests pass).
- **Through the dispatch** (`Tests/PCIOTests/PcraftDispatchTests.swift`): every mode/depth of
  the generated document round-trips; previews are written at 256 px (thumbnail) and 1024 px
  (composite); all 36 corpus files survive PSD → `.pcraft` → document unchanged (36/36 equal),
  and a PSD saved from the reopened document keeps 4068/4068 layer blocks.
- Deviations (format porter): manifest keys written sorted; tile hashes cached by tile
  generation; hashing/decoding in parallel with errors surfacing in photocraft's order; layers
  coded iteratively (a 100-deep tree in 512 KiB of stack); directory bundles fall back to `fsync`
  where `F_FULLFSYNC` is refused (SMB), which photocraft fails on; a directory save fully flushes
  once, with its manifest, where photocraft's `write_bundle_file` flushes every object (AB-T-0259).

### Format 3: filter adjustment layers (AB-T-0258)

- `pcraftFormatVersion` is 3. A document holding a filter adjustment layer (`Adjustment.filter`:
  Grain, Add Noise, Gaussian Blur, Motion Blur; anywhere in the tree, hidden or not) is written as
  format 3, in either container (format 3 allows ZIP64). The manifest stores it as
  `{"Filter":{"GaussianBlur":{"radius":10}}}` (serde's externally tagged form), seeds included.
- Every other document is still written as format 1 (or 2 for a ZIP64 single file), so
  photocraft keeps opening what it could.
- A reader that doesn't know the kind must reject the file, and the version makes it: photocraft
  and PhotoCraftNative 0.3 (format 2) refuse it as "written by a newer version" instead of failing
  on an unknown adjustment. Version 2 manifests migrate to 3 unchanged.
- PSD/PSB has no such layer: each is written as an empty pixel layer (its name, mask, opacity, blend
  mode and clipping kept) with a warning naming it, and the merged image shows the filters
  (`FilterAdjustmentPSDTests`, both record conventions, PCPSD's linter clean). Rasterizing them
  instead would stamp the filtered backdrop as pixels, which needs the backdrop of each layer
  rendered inside PSD export; not done.
- **Photoshop 27.11 opens them** (receipt AB-R-0539, `ps-oracle sweep`): the four
  `filter-adjustments-*.psd` the test drops (8 and 16 bits, both conventions) and PCEngine's Save a
  Copy, 5 of 5, with no dialog. Trees match: each filter layer reads as an empty pixel layer with its
  name, blend mode, opacity, mask and clipping. Layer pixels are within 0.012 levels. Photoshop's
  composite equals the layers without the filters (0 levels at 8 bits, 0.01 at 16), 209 levels off
  our merged image, which keeps them.

### Format 2: ZIP64, the package type, Save (AB-T-0240, AB-D-0131)

- **Two forms.** The package (directory) form is the editor's default Save. It is incremental (only
  new tiles are written; every other object file keeps its inode and modification time) and has no
  size limit. The single-file (ZIP) form is for sharing.
- **ZIP64 when needed, and only then.** `ZipWriter` writes ZIP64 records only when an archive
  outgrows classic ZIP: 65,535 entries, or 4 GiB for an entry, an offset or the central directory.
  Every archive that fits is byte for byte the classic layout. `ZipReader` reads ZIP64 from any
  writer, checked both ways against Info-ZIP (`zip -fz`, `unzip -t`). A missing ZIP64 field reads
  as its classic value, as Info-ZIP and Python read it.
- **Manifest version.** Format 2 (`pcraftZip64FormatVersion`), and version 1 migrates to 2
  unchanged (and on to 3, above). Format 2 changes the container, not the document schema. A
  writer writes 1 (photocraft's) unless the single file needs ZIP64, so photocraft opens every
  package and every single file it could open before. A ZIP64 single file says 2, and photocraft can't open it either way. New objects are
  compressed and checksummed on all cores.
- **Streamed, never whole (AB-T-0249).** `PcraftWriter.save(_:to:as: .singleFile)` writes the
  archive into the atomic save's temporary file entry by entry (`ZipStreamWriter` over a file
  sink), compressing 32 MiB of objects on all cores while the previous batch is written. The
  manifest goes first as format 1 and is rewritten in place as format 2, the same length, when the
  archive turns out to need ZIP64. The bytes are `saveZip`'s, and 2e24b80's: 36 saves compared by
  hash, covering classic, forced ZIP64, 66,000 entries, several batches, previews and resaves.
  `PcraftFormat.load(contentsOf:)` reads a single file through `ZipFileReader`: the end records and
  central directory, then each entry with `pread`, from all cores. The ZIP-mode object cache keeps
  at most `setZipCacheBudget` (64 MiB by default, 256 bytes counted per entry); one-off saves keep
  none. PCEngine's Save, Save a Copy and Open of a local single file use these paths; other file
  systems still go through whole bytes.
- **Saves without the wait (AB-T-0259).** At 0.3.0 a package save of PCRender's realistic20 at
  4096² spent 4.45 s on its previews alone in PixelAgencyEditor (a full-resolution composite each,
  averaged on one core), and a first save seconds more flushing each of its 1,235 objects to stable
  storage. Now:
  - **One reduced composite.** `DocumentCompositor.reduced(_:width:height:)` (PCIOCore) is the
    canvas area-averaged to a size. PCRender's `renderReduced` gives it for an RGB document
    (`RenderCompositor`, and PCEngine's `EngineRenderer`), whose composite reads back as rendered;
    the default composites a band at a time and reads it as `Surface.readRGBA` does (CMYK, Lab,
    Gray). `pcraftPreviews` renders the 1024 px composite once and reduces the 256 px thumbnail from
    it (`ReducedComposite.reduce(_:width:height:of:to:_:)`: exact where the cells fall on each
    other, as from 4096² to 1024² and 256²). The PSD thumbnail resource (160 px) is unchanged.
  - **Updated, not redrawn.** `pcraftPreviews(_:options:updating:)` takes the last previews
    (`PcraftPreviews`, which keep their reduction before sRGB) and the pixels an edit can have
    changed, and composites again only the cells meeting them
    (`DocumentCompositor.reduced(_:width:height:damage:)`: PCRender's `renderReduced(damage:)`, the
    same values the whole reduction gives them). PCEngine's `SaveSlot` keeps the previews, reuses
    them while nothing they show changes, and takes the damage from its transaction builder;
    `PcraftPreviews(stored:of:)` lets a just-opened file's own previews (`PcraftFormat.readPreviews`)
    stand in. The writer keeps the last previews' PNG bytes.
  - **One full flush per save.** `saveDir` checks existing objects and writes new ones on all
    cores. Each new object or preview goes through a temporary file flushed to the drive (`fsync`)
    and a rename; the folders are synced once; the manifest's own `F_FULLFSYNC`, before its rename,
    then empties the drive's cache, so the manifest still never names an object that isn't on
    stable storage. Measured on the first save of realistic20 at 0.3.0: 4.83 s of the 6.33 s it
    spent on objects was the per-object full flush (≈ 3.9 ms × 1,238 files: 1,235 objects, 2
    previews, the manifest).
  - Measured in release (`PCRAFT_SAVE_BENCH=1 swift test -c release --filter
    PCEngineTests.SaveTimingTests`: realistic20 at 4096², 1,211 tiles, opened from a PSD as
    PixelAgencyEditor's `openAndSaveAt4096` does; M5 Max, 2026-10-14, other sessions loading the
    Mac to 35–73; receipt AB-R-0542 of AB-T-0259):

    | | 0.3.0 (9922820) | AB-T-0259 |
    |---|---|---|
    | the previews alone | 3,517 ms | 408 ms first, 225 ms again |
    | first package save | 8,312 ms | 457–499 ms |
    | unchanged package save | 2,962–2,984 ms | 62–103 ms |
    | save after a stroke (3 tiles) | 3,006 ms | 127–163 ms |
    | the package reopened, a stroke, save | 3,933 ms | 389 ms |
    | the same, once composited for display | 3,523 ms | 287–360 ms |

    The previews are 0.3.0's within a level (max 1, mean 0.019 thumbnail and 0.031 composite).
- **Types** (`DocumentTypes.swift`). The package is `com.xocialize.pcraft.package`, conforming to
  `com.apple.package` and `public.composite-content`; the app exports it. The single file is
  photocraft's `ai.storyteller.photocraft.document` (`public.data`, `public.image`); the app imports
  it. That is iWork's pattern for one extension in two forms. A type's conformance exists only
  where an Info.plist declares it. So `exportedTypeDeclaration`, `importedTypeDeclaration` and
  `documentTypeDeclarations` are data for the app's Info.plist, and `declarationProblems(in:)`
  checks a bundle's copy against them.
- **Save** (PCEngine `SessionSave.swift`). `Session.savePlan` covers each case:
  - untitled, or a flat or import-only source: a `.pcraft` package;
  - a `.pcraft` keeps its own form;
  - PSD, PSB and ORA save back to themselves, with warnings. PSD export now also names the
    Timeline, Variables and Data Sets, and video layers, which it doesn't keep.

  Automation sessions (`Headless`) write new `.pcraft` files as single files. A file system without
  local folders always does.
- **The >4 GiB receipt** is opt-in: `PCRAFT_ZIP64_BIG=1 swift test -c release --filter
  PCFormatTests.Zip64BigTests`. It holds the 4.5 GiB document twice (saved and reloaded), about
  10 GB, and deletes its temp file afterwards. `PCRAFT_ZIP64_BIG_SIDE`, `_KEEP`, `_LOAD` and
  `_REPORT` pick the size, keep the file for a load in a fresh process, and log JSON
  (`Zip64BigTests.swift`).
  Receipt, 2026-10-13 (AB-R-0526): a 4,835,768,048-byte (4.50 GiB) single file of 9,217 entries
  (96 × 96 tiles of RGBA16 noise, 512 KiB each, incompressible). Save took 2.54 s, load 1.63 s
  (reopened equal), and Info-ZIP's `unzip -t` 14.8 s (all CRCs good).
  Memory, 2026-10-14 (AB-T-0249), release, the same Mac:

  | file | save: peak over the RSS with the document loaded (6 runs) | load in a fresh process: peak over the loaded document |
  |---|---|---|
  | 0.50 GiB | 173–225 MB (2e24b80: 1,692 MB) | 0 MB |
  | 4.50 GiB | 212–248 MB (2e24b80: 15,074 MB) | 0 MB (2e24b80: 4,903 MB) |
  | 12.51 GiB | 249–293 MB | 0 MB |

  About 190 MB is fixed: two 32 MiB batches, the 64 MiB cache and the codec buffers. The rest
  grows with the tile count, about 2–3 KB per tile, and comes from building the manifest, which the
  archive's first entry must hold whole (Foundation's `JSONEncoder` per layer, then `JSONTree`).
  Heap in use after a save is back where it started (+0.1 MB). Process peak at 4.50 GiB is 10.1 GB
  (was 20.1 GB).


## Tests

`swift build --build-tests` and `swift test` in `Packages/PCIO` (debug and release): zero warnings.
879 tests in 8 targets (2026-10-14, after AB-T-0259's saves; zero warnings):

| Target | Tests | Content |
|---|---|---|
| `PCIOCoreTests` | 68 | ZIP (ZIP64 written only when needed, read from any writer, Info-ZIP interop both ways; the streaming writer and the file reader agree with the in-memory ones, damaged archives included), deflate/CRC, BLAKE3 vectors, blocks/pixels/gradient bake (Smooth against Photoshop's composite), `ImageIOCodec` (straight alpha, Gray+alpha, 16-bit, float), container metadata, source encoding (JPEG quality, WebP) |
| `PCIOTextTests` | 52 | TySh/EngineData/Txt2 read/write, styles, corpus (64/64 EngineData, 13/13 `Txt2` byte-exact) |
| `PCIOMapsTests` | 91 | adjustment/effects/vector/pattern/channel/comps/slices/annotation maps + corpus |
| `PCIOSmartTests` | 37 | smart maps, linked files, displace, Camera Raw + corpus (98 `SoLd`) |
| `PCFormatTests` | 139 | all 115 photocraft-format tests, photocraft-shaped bundle, corruption, autosave/recovery, empty-blob frames, format 2 (versions per form, migration, forced ZIP64, package types, only new tiles written), streamed single files (the in-memory archive's bytes, format 2 decided at the end, a bounded cache, a failed save changes nothing, file loads fail as memory loads), package saves on all cores (damaged objects among many rewritten, unchanged previews not encoded again, previews read back); the >4 GiB round trip and the load measurement are opt-in |
| `PCIOFormatsTests` | 139 | ORA, KRA, PDN, EXR (every compression), layered TIFF transcoder (corpus both byte orders), SVG, Compositor `.comp` (every version gate, deep/HDR layers, transforms, masks, clipping, adjustments, text/shapes) |
| `PCIOAffinityTests` | 45 | `affinity.rs` and `affinity_artboards.rs` import tests on `PCAffinitySynth` inputs |
| `PCIOTests` | 308 | photocraft's `crates/io/tests` (roundtrip, psd_structure, block layout/alignment, 32-bit, modes, multichannel, lab16, channels, banded, large PSB (29000² opt-in), thumbnails, progress/cancel, composite, adjust/effects/vector/comps/annotations/patterns, smart objects, type, tiff_layers/pages/corpus, flat/orientation/metadata/resolution/colour/HEIF, container dispatch, Affinity export halves), the inline tests of the PCIO-owned modules, Compositor's `.comp` fixtures against its own oracle, Photoshop record conventions, both corpora (round trip, oracle, `.pcraft`), EXR part selection, flat export, the Photoshop oracle's findings (type-layer completeness, blend modes per mode/depth, 4-alignment, matte order, `Txt2`, patterns), fill pixels against the live composite, adjustment availability per mode/depth (with the oracle run's proof), per-document CMYK, the `.pcraft` previews from one reduced composite (within a level of 0.3.0's two, damaged cells, stored previews) |

Every PSD/PSB a test exports is checked with PCPSD's linter (`compatibilityIssues(decodeChannels:)`,
no errors), and, when `PCIO_EXPORT_DIR` is set, saved there for the
Photoshop oracle agent: corpus re-exports as `<corpus-file>.reexport.psd` and
`<corpus-file>.pcraft-reexport.psd`, everything else as `synthetic-<test>-<content hash>.psd|psb`
(1,300+ files per full run).

**Fixture data** (outside git, `PhotoCraftNative-Fixtures/`) is found as every package finds it,
through one helper per test target (`Tests/<Target>/Fixtures.swift`): the root is
`PHOTOCRAFT_FIXTURES`, else `<PhotoCraftNative>/../PhotoCraftNative-Fixtures` when it exists, else
none, and a test that needs data is `.enabled(if:)` on it and skips with the reason. The
variables, each overriding one folder:

| Variable | Default | Used by |
|---|---|---|
| `PHOTOCRAFT_FIXTURES` | `<PhotoCraftNative>/../PhotoCraftNative-Fixtures` when it exists | everything below |
| `PCPSD_CORPUS` | `<fixtures>/psd-corpus` (the Unity PSDs) | corpus round trips, text/smart/vector/maps/TIFF corpus tests, composite oracle |
| `PCIO_PS_CORPUS` | `<fixtures>/ps-corpus` (Photoshop-authored) | ps-corpus round trips, oracle, matte/artboard/adjustment references |
| `PCIO_M3_DIR` | `<fixtures>/ps-measure/M3` | `PhotoshopLightModeTests` |
| `PCIO_PS_ORACLE` | `<fixtures>/ps-oracle` | `AdjustmentAvailabilityTests.photoshopOracleRunAgreesWithTheTable` |
| `PCIO_COMP_FIXTURES` | `<fixtures>/comp-fixtures` (Compositor's CanvasFixtureGenerator output) | `CompCorpusTests` |
| `PCIO_EXPORT_DIR` | none: nothing written | the oracle drop (set it to write; `none` also disables) |
| `PCIO_EXR_FIXTURES`, `PCIO_EXR_DIR`, `KRITA_TEST_DIR`, `PDN_TEST_DIR`, `PCIO_BIG_PSB` | none | external corpora and the 12 GB PSB test, opt-in |

Every export the oracle may receive is composited by PCRender (`MapsKit.compositor`, the CPU
reference); `StoredPixelsCompositor` remains only for imports, flat and `.pcraft` exports, and
exports kept out of the sweep.

Known issues (`withKnownIssue`; 49 at first): 32-bit CMYK quantised by the 16-bit PSD it is
written as (12, by design), the hostile type sizes PCPSD's linter flags (3, on purpose), CMYK
colour in PCRender's compositor outside the document scope, TIFF page selection and BigTIFF
orientation (codec layer), a truncated HEIC ImageIO decodes without an error (codec layer). The
document-profile CMYK and HEIC metadata issues are fixed (above).
Skipped with a reason: photocraft's external corpora (psd-tools, ag-psd, krita, pdn, …), its
glyph-raster checks (no font renderer in PCIO), TGA/BMP/QOI/FITS/GIF-frames/camera-raw codec
tests (PCPlatform), `abr_map` cancellation.


## Deviations from photocraft (fixes beyond the port)

- PSD records in Photoshop's measured shape by default; resources in Photoshop's order with its
  IPTC/print-output defaults; mapped resources kept raw while they still describe the document
  (and dropped on import when they add nothing).
- 32-bit CMYK and Lab are written as 16-bit PSDs with a warning (Photoshop has no such modes;
  photocraft writes files Photoshop refuses).
- `Txt2`: a missing `/11` is Metrics (photocraft rewrites 12 of 13 corpus blocks); an empty type
  layer keeps its style run (photocraft drops it) and its `Txt2` object; no generated `Txt2` is
  written (Photoshop refuses it), so Optical kerning is saved as Metrics with a warning.
- Smooth gradients: Catmull-Rom through stops and segment midpoints in Oklab (fitted on Photoshop's
  composite) instead of photocraft's per-segment easing table; fill-layer pixels from PCRender's
  `FillLayerRenderer` by default (photocraft needs its fill renderer; PCIO wrote fills empty
  without an injected renderer), with a solid colour's alpha only in the fill opacity.
- The Photoshop oracle's refusal causes (table above): EngineData completeness, blend modes per
  mode/depth, 4-aligned layer blocks, matte block before `Lr16`/`Lr32`, pattern transparency in
  the sheet mask array, placeholders for missing patterns, damaged pattern blocks dropped.
- The PSD layer tree is built iteratively (photocraft-style recursion overflowed a 512 KB thread at
  the 100-group cap).
- Smart objects whose filter mask is all white keep their original `PlLd`/`SoLd`/`FEid`.
- Effects Photoshop wrote only as `lmfx` (multiple instances) stay that way: no `lfx2` is added.
- Channel resources (1006/1045/1077) are kept verbatim while they still describe the channels, so
  spot inks keep Photoshop's own colour space (CMYK) instead of becoming RGB.
- `.pcraft`: the slices' group name survives a save without slices (photocraft drops it; its
  reader accepts both).
- Flat import/export through `ImageIOCodec`: straight alpha, Gray+alpha, exact ICC bytes, EXIF/XMP/
  text, exact PNG resolution, truncation/frames/pages warnings, multi-part EXR part choice, palette
  PNG for Indexed, inks for Duotone, photocraft's fidelity warnings; flat TIFF through PCIO's own
  TIFF writer (CMYK + alpha, every depth).

## What's left

- **Photoshop itself.** The fixes for the oracle's first pass are in; its re-run over the new
  `$SCRATCH/pcio-exports` (C′) is the next input. Open: which `Txt2` field Photoshop rejects
  (until then no generated `Txt2`, Optical kerning saved as Metrics); whether the pattern fix is
  the whole story (candidate fields above); the `lnk2` files the oracle couldn't explain
  (`independentUnavailableLinkRetainsSeparatePreservedRecord`, `textShapeSmartRawBlocksSurvive`).
- **Kept raw blocks are written unchecked.** A damaged copy of a block Photoshop parses gets the
  whole file refused; only pattern blocks are validated today. A general rule (drop or warn on a
  kept block PCPSD's parser rejects) needs a parser per key.
- **Composite fidelity outside RGB** is PCRender's: CMYK documents composite in RGB (see the
  ps-corpus oracle), fills render at full precision, CMYK conversions ignore the document profile.
- **Codec layer (PCPlatform):** WebP/AVIF/JPEG XL/GIF frames/TGA/BMP palettes/QOI/FITS, camera raw
  (`raw.rs`), TIFF page selection, HEIC metadata, JPEG quality estimation. PCIO uses the injected
  `FlatImageCodec`; `ImageIOCodec` is a capable default, not the full matrix.
- **Not ported:** `abr_map.rs` (needs the brush package's `BrushPreset`), `raw.rs`.
- **Text/shape rendering** of layers without pixels needs the engine's `LayerContentRenderer` /
  PCRender `LayerRasterizer` (PCPlatform); without them those layers stay empty with a warning.
- **Bitmap/Indexed/Duotone PSD export** writes Grayscale/RGB (photocraft's behaviour, warned).
- **Flattened PSDs** (no layer records) are re-saved with their Background as a layer record.
- **`.comp` in the engine:** `EngineIO.importPath` reads a file's bytes, so opening a `.comp`
  package (a directory) from PCEngine needs a directory branch calling
  `DocumentIO.importFile(contentsOf:)`, and `comp` in its openable lists.
- **`.comp` adjustments without a Photoshop form** (Grain, Add Noise, Gaussian/Motion Blur) are left
  out; baking them would need PCAlgo's filters over the composite below.
- **Vivid Light's 0/0 ends** want one Photoshop measurement (base 0 under 255, base 255 under 0).

## Change requests for other packages

1. **PCAffinity:** done (`decompress(_:maxSize:maxWindow:)`, now used for blobs). Still open:
   accept a frame with empty content (PCFormat recognises empty blobs from the header meanwhile).
2. **PCRender:** composite CMYK (and Lab) documents in their own space, as Photoshop blends them;
   `PlaceholderRasterizer` path coverage for vector masks; parallel workers entering the caller's
   `ColorConvert.withCMYK` scope (PCIO's fill and import paths run in it); Gray documents: draw RGB fill colours
   and Selective Color in grey; Gradient Map input luminance 0.30/0.59/0.11 (Photoshop's; error
   mean 0.58 → 0.09 levels). Done: fills at the document's depth, the public fill renderer
   (`FillLayerRenderer`, now used).
3. **PCFoundation:** `Surface.converted(to:)` across colour models (traps today); public
   `ColorConvert.mul`. Done: the per-task CMYK scope (`withCMYK`, now used).
4. **PCPSD:** done (NaN, NUL-terminated linked names, `MIB8`/`46B8`, public readers/writers —
   PCIOFormats now uses them —, `PCPSDTestSupport`, the type-layer gap check, the blend table,
   `fourAligned()`, the matte linter rule). New:
   - `PSDPattern.write`: put transparency in the sheet mask array (index count + 1), as Photoshop
     does (PCIO rearranges the bytes meanwhile; the step becomes a no-op once PCPSD does it). Done by PCPSD; PCIO's step removed.
   - `PSDPattern` indexed patterns: keep the 4 bytes after the palette on read and write them
     back (Photoshop: `01 00 00 ff`), so a rewrite of Photoshop's pattern is byte-faithful.
   - `PSDTestGen.small`: the 2-byte `Patt` placeholder → Photoshop's empty `Patt`.
   - A linter rule for pattern blocks (transparency in the user mask; unparseable data).
     (Sheet-mask slot 25: done by PCPSD.)
   - A linter rule for adjustments Photoshop doesn't offer in the document's mode/depth (the
     table in `AdjustMap.photoshopOffers`), and the oracle's facts treating a `vmsk` without path
     records as no vector mask, as Photoshop does.
5. **PCDocument:** public `remEuclid`; `TextRun.len`/`ParagraphRun.len` decoded saturating.
6. **Engine/PCPlatform:** inject `ImageCodecs` as `FlatImageCodec`, and its text/shape rasterizer
   into `RenderCompositor` / `LayerContentRenderer`. PCEngine can drop its `fileEncoding`
   stopgap and `EngineIO.renderFill` (PCIO does both now).

