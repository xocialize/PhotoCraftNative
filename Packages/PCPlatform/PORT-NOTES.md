# PCPlatform — port notes

> **Measured:** 2026-10-12 on macOS 27.2 (Darwin 27.2.0), Apple M5 Max, Xcode 27 / Swift 6.4.
> **Build:** `swift build` / `swift test` from `Packages/PCPlatform` — 88 Swift Testing tests in 9
> suites, all passing, no warnings from this package. Every number below is printed by the tests
> with a `MEASURE` prefix (`swift test 2>&1 | grep MEASURE`), except the Release timings in §11.
>
> **Revision 2 (same day):** text and vector now render **PCDocument's** model directly, as
> photocraft's `text` and `vector` crates depend on `doc` — see §10.
>
> **Revision 3 (same day):** PCEngine's six change requests — cached, concurrent font lookups;
> manual kerning; photocraft's vertical type; trailing whitespace; far path coordinates; WebP
> quality on libwebp's scale — see §11.

PCPlatform replaces photocraft's hand-written pure-Rust platform subsystems with the macOS
frameworks that already do the job. It depends on `PCFoundation` and `PCDocument` (paths) and, by versioned URL
(AB-D-0023), on the fleet's image packages: **media-bridge 0.40.0** (`ImageBridge`, `MediaMeasure`)
and **webp-swift 0.1.0** (`WebPSwift`, libwebp 1.6.0 from source). Both resolved from GitHub
without trouble; `Package.resolved` pins them.

## 1. Replacement map

| photocraft crate | Rust retired (src / with tests) | Native replacement | Swift written (src) |
|---|---:|---|---:|
| `crates/cms` (own ICC engine) | 4 420 / 5 314 | ColorSync (`ColorSyncTransformCreate/Convert`), CGColorSpace, AppKit `NSScreen.colorSpace`, Metal 3D texture | Color/ 1 327 |
| `crates/codecs` (18 codecs incl. own VP8 encoder) + `crates/heif` | 11 524 / 18 554 | ImageIO (`CGImageSource`/`CGImageDestination`, `CGImageMetadata`), vImage; **webp-swift** for WebP write; media-bridge `ImageBridge` probe/8-bit decode and `MediaMeasure` SSIMULACRA2 | Codecs/ 1 639 + Support/ 388 |
| `crates/raw` (clean-room DNG/CR2/NEF/… decode, demosaic, develop) | 9 849 / 11 989 | Core Image `CIRAWFilter` (934 camera models + any DNG), media-bridge `RawDecodeOptions` | Raw/ 294 |
| `crates/text` (fontique/parley/skrifa/HarfRust, own rasteriser) | 9 987 / 10 074 | CoreText (`CTFontManager`, `CTTypesetter`, `CTLine`, `CTFontCreatePathForGlyph`) into CGContext bitmaps, over PCDocument's `TextLayer` | Text/ 851 |
| `crates/vector` (scanline rasteriser, stroker, dashes, flattening, gradient paint, hit test) | 3 743 / 3 765 | CoreGraphics (CGContext fill/stroke, `copy(strokingWithWidth:)`, `copy(dashingWithPhase:)`, `CGPath.union/intersection/subtracting/symmetricDifference`) over PCDocument's `VectorPath`/`ShapeLayer`/`VectorMask`/`LiveShape`; gradient `Paint` ported | Vector/ 717 |
| `crates/tablet` (AppKit monitor via unsafe FFI, X11/XI2) | 968 / 1 019 | AppKit `NSEvent` read directly (pressure, tilt, rotation, proximity, subtypes) | Input/ 297 |
| — gap **G15** (no ML runtime) | — | Vision (horizon, rectangles, document, text, saliency) + Core Image perspective/straighten | Vision/ 183 |
| — gap **#2541 / FILE-215-10** (no PDF read, raster-only write) | — | CoreGraphics PDF (`CGPDFDocument`, `CGPDFScanner`, PDF `CGContext`) + PDFKit | PDF/ 301 |
| **Total** | **40 491 / 50 715** | | **6 023 src + 1 695 tests** |

Ported rather than replaced (small, and no framework does them): photocraft's JPEG quality
estimator and WebP lossless/lossy reader (`source_settings.rs` → `SourceSettings.swift`), its PCX
reader, FITS reader/writer, the Netpbm binary writer (P5/P6/P7/PF/Pf) and P4 reader, a flat RGBE
(Radiance) writer, a QOI codec (from the spec), the PostScript-name guesser, the pen state machine
(`appkit.rs`), live-shape path generation (`shapes.rs`) and photocraft-vector's gradient `Paint`
(midpoints, opacity stops, whole-pixel snapping, dither). The path and text *models* are PCDocument's.
The bundled `photocraft-coated-cmyk.icc` is photocraft-cms's own CC0 profile, so CMYK conversions use
the same characterisation photocraft does.

## 2. Format capability matrix

Shape of photocraft's `docs/file-format-parity.md`. **Native** = this package on macOS 27.2;
read/write sets come from `CGImageSourceCopyTypeIdentifiers()` (61 types) and
`CGImageDestinationCopyTypeIdentifiers()` (22 types) at run time, depths/layouts from the round-trip
tests (`CodecTests`).

| Format | Photoshop | photocraft R | photocraft W | Native R | Native W | Native fidelity (measured) |
|---|---|---|---|---|---|---|
| PSD (flattened) | R/W | yes (layers) | yes (layers) | yes (ImageIO composite) | yes (ImageIO, flattened) | 8/16-bit Gray/RGB/CMYK lossless; **alpha unusable** (colour comes back × alpha). Layers are PCPSD's area |
| PSB | R/W | yes | yes | no | no | PCPSD |
| TIFF | R/W | yes | yes | yes | yes | u8/u16/f16/f32, Gray/RGB/CMYK ± alpha (CMYK+α 8-bit) lossless; multi-page R/W; compression none/LZW/PackBits/Deflate honoured; ICC/EXIF/XMP/DPI/text |
| JPEG | R/W | yes | yes | yes | yes | 8-bit Gray/RGB/CMYK (ink convention kept); ICC/EXIF/XMP/DPI; progressive; Save-at-own-quality via ported DQT estimator + ImageIO calibration (30→30, 50→49, 75→74, 85→85, 90→90, 95→95) |
| PNG / APNG | R/W | yes (APNG 1st frame) | yes | yes, all frames | yes, APNG with delays | 8/16-bit Gray/RGB ± α lossless; ICC/EXIF/XMP/DPI/text |
| GIF | R/W | yes | yes | yes, all frames | yes, animated with delays | palette 8-bit, alpha binarised |
| BMP | R/W | yes | yes | yes | yes | 8-bit RGB ± α |
| WebP | R/W | yes | yes (own VP8) | yes (ImageIO) | yes (**webp-swift**/libwebp) | lossless exact (8-bit RGBA) or lossy; 8-bit sRGB only, no ICC/EXIF/XMP in the bitstream, ≤ 16 383 px |
| AVIF | R/W | **no** | feature-gated | **yes** | **yes** | 8/10-bit RGB ± α, ICC/EXIF/XMP |
| HEIF/HEIC | R/W | yes (heic-rs) | **no** | yes | **yes** | 8/10-bit RGB ± α (10-bit packed decoded via CoreGraphics fallback); ICC/EXIF/XMP |
| HEIF sequence (HEICS) | — | no | no | **yes** | **yes** | animated, delays |
| JPEG XL | R/W | inside DNG only | no | **yes** | no | ImageIO decode (UTI listed; no encoder exists to make a fixture) |
| JPEG 2000 | R/W | **no** (#1047) | no | **yes** | **yes** | 8-bit only (16-bit written as 8) |
| OpenEXR | R/W | yes (+deep, Cryptomatte, multi-part) | yes | yes (first part) | yes | f16/f32 Gray/RGBA (writer always adds A to RGB); written as scene-linear; ~1e-5 abs drift from ImageIO's chromaticity round trip; no deep/multi-part/Cryptomatte |
| Radiance HDR | R/W | yes | yes | yes | yes (ported flat RGBE) | f32 RGB; 0.75 % of pixel max |
| Netpbm PBM/PGM/PPM/PAM/PFM | R/W | yes | yes | yes (+ ported P4) | yes (ported binary writer) | 8/16/f32 Gray/RGB ± α lossless |
| FITS | R/W (plug-in) | yes | yes | yes (ported) | yes (ported) | 8/16/f32 Gray/RGB, header cards kept |
| Targa | R/W | yes | yes | yes | yes | 8-bit Gray/RGB/RGBA |
| ICO | — | yes | yes | yes | yes | RGBA, square ≤ 256 |
| QOI | — | yes | yes | yes (ported) | yes (ported) | lossless |
| PCX | R/W | yes | no | yes (ported) | no | |
| Photoshop PDF | R/W | **no** (#2541) | raster, 1 page | **yes**: any page at any DPI, 8/16/f32, transparent or on white; vector import as paths; text extraction | **yes**: multi-page, raster and/or **vector** pages | |
| Camera raw | R | partial (no CR3, many "preview only") | — | **yes**: 934 models incl. CR3, every vendor UTI | — | 16-bit ProPhoto / float linear; see §4 |
| DICOM | R/W | no | no | **yes** | no | ImageIO (UTI listed; not exercised — no fixture) |
| PICT | R | no | no | **yes** | no | legacy (UTI listed; not exercised) |
| MPO (stereo) | R/W | no | no | **yes** | no | ImageIO (UTI listed; not exercised) |
| SGI, CUR, ICNS, DDS, ASTC, KTX/KTX2, PVR, ATX | — | no | no | yes (listed) | ICNS measured (16/32/48/256 px squares); ASTC/KTX/PVR/ATX listed; DDS listed but every write measured fails | |
| Generic EPS / AI, DPX/Cineon, IFF, PCX write, Scitex, Pixar, WBMP | various | no | no | no | no | not native |
| Paint.NET, OpenRaster, Affinity, `.pcraft` | — | yes | some | no | no | photocraft-specific containers (other areas) |

**Headline.** Natively readable that photocraft cannot read: AVIF, HEIF sequences, JPEG XL, JPEG 2000,
Photoshop PDF, CR3 and ~900 more raw bodies, DICOM, PICT, MPO, SGI, CUR, ICNS, DDS, GPU texture
containers. Natively writable that photocraft cannot write: AVIF (default build), HEIF/HEIC, HEIF
sequences, JPEG 2000, multi-page and vector PDF, ICNS and texture containers. photocraft keeps over
the native port: layered PSD/PSB (PCPSD), deep / multi-part / Cryptomatte EXR, BigTIFF and layered
TIFF specifics, Paint.NET / OpenRaster / Affinity import, PSD-with-alpha composites, WebP metadata
and >8-bit WebP input, and its own clean-room raw decoder's per-file "camera look" fitting.

## 3. Colour: measured against photocraft-cms's test expectations

ColorSync runs photocraft's assertions (`crates/cms/tests/cms.rs`) with the **same** CMYK profile
bytes (the CC0 coated CMYK) and macOS's own RGB/gray/Lab profiles.

| photocraft expectation | photocraft tolerance | ColorSync (measured) |
|---|---|---|
| sRGB red/green/blue → Lab D50 vs (54.29, 80.80, 69.89) / (87.82, −79.29, 80.99) / (29.57, 68.30, −112.03) | ΔE76 0.15 / 0.3 / 0.3 | **0.012 / 0.019 / 0.010** |
| 50 % gray neutral in sRGB, P3, Adobe RGB, ProPhoto, linear sRGB, Rec.2020 | \|a\|,\|b\| < 0.02 | 1.5e-5 |
| sRGB→Lab→sRGB float round trip | < 1e-4 | 7.2e-6 |
| 8-bit integer path vs exact float (sRGB → Adobe/ProPhoto/P3/linear) | ≤ 0.6 level | **≤ 1.0 level** (ColorSync's integer path; float path exact) |
| sRGB→sRGB 8-bit identity (BPC on) | exact | exact |
| coated CMYK paper (relative) vs L* 100 | ΔE < 0.5 | 0.39 |
| coated CMYK paper (absolute) vs (95, 0, −2) | ΔE < 0.6 | 0.37 |
| Lab → CMYK → Lab, in-gamut | ΔE < 2 | 0.35 |
| sRGB gray ramp → CMYK: TAC, neutrality | ≤ 3.02, \|a\|,\|b\| < 3 | 2.69, 0.53 |
| CMYK black point L* | 4…20 | 7.39 |
| BPC keeps shadow detail (L* gap 0 → 0.08) | > 1.5 | 3.85 (without BPC 0.92) |
| darkest CMYK → sRGB with BPC | G < 0.03 | 0.018 (without 0.097) |
| perceptual vs relative separations differ | Σ\|Δ\| > 0.03 | 0.56; saturation = perceptual |
| proof: gray stays neutral; paper sim darkens white | R < 0.97 | (0.934, 0.940, 0.954) |
| 33³ display LUT sRGB→P3 vs exact | < 2/255 | 0.12/255 |
| sGray → sRGB | < 1e-3 | 1.2e-7 |
| HDR (4, 2, 0.5) linear sRGB → Rec.2020 → back | < 1e-3 rel | 1.8e-7 |
| system profiles parse and convert | all | 21 / 21 |

Findings that shaped the code (each has a test):

* **ColorSync's black-point compensation shifts neutrals.** With `kColorSyncBlackPointCompensation`
  on the source profile, sRGB 50 % gray → coated CMYK lands at b* −7.8 (Apple's own Generic CMYK:
  −8.9), against ±0.6 without it — it fails photocraft's gray-ramp neutrality test by 3×. PCPlatform
  therefore never sets the flag: BPC splits the transform at the PCS and applies Adobe's neutral,
  Y-only black-point scaling in XYZ between two ColorSync legs (photocraft's formulation). Result:
  worst |a*|,|b*| 0.53 with BPC.
* **ColorSync's absolute colorimetric uses a v2 display profile's D65 `wtpt`**, which renders
  photocraft's slightly blue paper (Lab 95/0/−2) *yellow* on sRGB (0.99, 0.93, 0.83) and refuses some
  pairs outright (ROMM RGB → Lab). Absolute colorimetric is done as relative + media-white scaling
  with display-class whites taken as D50 (ICC v4 / photocraft / Photoshop semantics).
* ColorSync's 32-bit float Lab encoding is L/100 and (a − 0.5)·255 (not v4's (a + 128)/255);
  `LabEncoding` converts.
* `ColorConvert.cmyk` (PCFoundation's slot): the **batch** methods (`cmykToRGB(batch:)`,
  `rgbToCMYK(batch:)`, which `Surface.readRGBA` uses for CMYK) are one exact ColorSync conversion
  per call (measured identical to per-colour ColorSync). The per-colour methods are served from
  17⁴ / 33³ grids filled by one batched ColorSync call: mean error 0.13/255 (CMYK→sRGB) and 0.30/255
  (sRGB→CMYK) over 4 000 random colours, maxima 5.6/255 and 15/255 at gamut-clipping kinks.
* The gray "Dot Gain 20 %" (Photoshop's default gray space) and "sGray" are written by a small ICC v2
  gray-TRC writer; Dot Gain 20 % is a parabolic TVI with ideal ink (50 % → L* 61.7), an
  approximation of Adobe's profile.
* The monitor profile is read from `NSScreen.colorSpace` directly (measured: the attached Odyssey
  G95NC's profile) — photocraft shells out to `osascript`.

## 4. Camera raw (CIRAWFilter)

A synthetic Bayer DNG generated in-test (Apple's decoder refuses DNGs much under 200 px a side:
256×192 is refused, 300×200 accepted) develops colorimetrically: the 0.30 gray patch comes back at
0.296 in scene-linear float, +1 EV doubles it (×2.01), and our 16-bit sRGB render quantised to 8-bit
equals media-bridge's ImageBridge raw decode exactly (mean |Δ| 0/255).

| photocraft develop parameter | Native mapping |
|---|---|
| exposure (EV), white balance (temperature/tint), boost, decoder version, raw NR on/off | ImageBridge's `RawDecodeOptions`, applied as ImageBridge applies it |
| demosaic choice (AHD, Malvar, X-Trans) | the decoder's own (v8 classical; v9 neural demosaic + denoise) — not selectable |
| luminance/colour NR, sharpness, contrast, detail, moiré, local tone map, lens correction, gamut mapping, EDR, draft scale, orientation | `CIRAWFilter` properties (reported when unsupported for the file/decoder) |
| Shadows / Highlights | `CIHighlightShadowAdjust` after decode (positive Highlights cannot brighten — warned) |
| Clarity / Texture | large/medium-radius `CIUnsharpMask` (approximation, warned) |
| Dehaze | **none** (warned) |
| fit_look (camera-JPEG colour fitting) | none; Apple's per-camera calibration instead |
| output 16-bit ProPhoto | `.proPhoto16` (default); also ProPhoto float, scene-linear float (boost 0), sRGB16, P3-16 |

## 5. Text, vector, input, Vision, PDF

* **Text (CoreText).** Input is PCDocument's `TextLayer` (`TextEngine.layout(layer, dpi:)`,
  `rasterize(layer, dpi:, format:)`, `rasterizeCoverage`, `outlines` → PCDocument `VectorPath`,
  `renderLayer(&layer, …)` refreshing `layer.cache` like photocraft's `render_layer`). 179 families enumerated; PostScript ⇄ family/style (photocraft's guesser
  ported: `TimesNewRomanPS-BoldItalicMT` → Times New Roman 700 italic); variable axes (Skia wght
  0.48…3.2 changes ink ×5.5). Photoshop's layout rules on CTTypesetter lines: point/box text, auto
  and explicit leading, space before/after, indents, 7 alignments incl. justification, tracking
  (`kCTTracking`), metrics kerning on/off and manual kerning (replacing the pair's metrics kerning,
  §11), baseline shift, faux bold (photocraft's
  0.018 em dilation; ink gain constant across sizes 1.48/1.47), faux italic (12°), all caps, small
  caps (`smcp` or synthesised at 70 %), underline, strikethrough, photocraft's vertical type (§11).
  Font lookups are cached and safe from any thread (§11). Coverage at
  u8/u16/f32 agrees (CoreGraphics anti-aliases in 8-bit steps, so f32 = u8 exactly); ink ∝ scale²
  (×4.06 at 2×). Glyph outlines vs rendered coverage IoU 0.98. AA modes: None is hard-edged; Sharp
  disables subpixel positioning; Strong adds a 1 % stroke; Smooth/Crisp differ only in subpixel
  quantisation (CoreText has no Photoshop-equivalent hinting modes). Optical kerning falls back to
  metrics. Text warp is not ported (PCRender/PCAlgo can bend `TextEngine.outlines`).
* **Vector (CoreGraphics).** Input is PCDocument's model: `VectorPath.cgPath`, `LiveShape.path`,
  `StrokeStyle(ShapeStroke)`, `VectorRasterizer.coverage(of: VectorMask, rect:)`,
  `rasterize(ShapeLayer, format:, clip:)` / `renderCache(&shape, …)` with solid and gradient paints
  (photocraft's `Paint` ported; pattern paints transparent, as in photocraft-vector). Photoshop path operations folded with CGPath booleans (combine /
  subtract / intersect / exclude exact to 0.5 px² on squares; `join` holes; even-odd; inversion);
  strokes with caps/joins/miter limit/dashes, inside/outside alignment exact (256 / 384 px² on a
  20 px square, stroke 4). CoreGraphics anti-aliasing is quantised to 1/255 even into float bitmaps
  (an exact 0.5 edge reads 0.498); `supersample:` restores exact areas (100.0 vs 99.92) for 16/32-bit
  masks. Hit testing: fill/stroke containment, anchors and handles, nearest segment point.
* **Input (AppKit).** `PointerEvent` exactly as architecture §4.3 (`posDoc, pressure, tilt, twist,
  timeMicros, buttons, mods, kind`), photocraft's pen state machine ported with its tests, real
  NSEvents built from CGEvents with tablet fields convert correctly (pressure 0.6, tilt 30°, twist
  45°). `PointerCoalescer` batches samples per frame, merges duplicates, collapses hovers, keeps a
  lift's stroke pressure, and resamples to even spacing; `setAppKitCoalescing(false)` delivers every
  tablet sample. No unsafe FFI.
* **Vision (gap G15, geometry/text only).** Horizon 5.9° on a 6° synthetic horizon (Vision reports
  it with the opposite sign; normalised); rectangle corners within 1.2 px; document segmentation;
  OCR reads "PHOTOCRAFT NATIVE" at confidence 1.0 from CoreText-rendered text; attention and
  objectness saliency peak on the subject; crop suggestion; Core Image perspective crop and
  straighten. Unlocks in photocraft's menus: Image ▸ Straighten / Ruler "Straighten Layer" (auto),
  Perspective Crop (auto-detected corners), Crop "content-aware" suggestion, Edit ▸ Find text /
  searchable text layers from scans. **Subject/person segmentation is out of scope by decision:**
  ExtractKit (Tier 1 = `VNGenerateForegroundInstanceMaskRequest`) and MaskKit own Select Subject /
  Remove Background; no wrapper was written here, so nothing is superseded.
* **PDF (gap #2541).** Read: page count/sizes, any page rasterised at any DPI to 8/16/f32 on white
  or transparent (identical to media-bridge's rasteriser at 8-bit: mean |Δ| 0/255), vector import
  (`CGPDFScanner`: paths, fills, strokes, gray/RGB/CMYK incl. `cs`/`scn`, `q/Q/cm`) as PCDocument
  `VectorPath`s (`PDFVectorShape.shapeLayer` gives a document `ShapeLayer`), text via PDFKit. Write:
  multi-page PDFs of raster pages (lossless round trip) and PCDocument `ShapeLayer`s — solid paints
  stay vectors (inside/outside strokes via CGPath booleans), gradient/pattern paints are placed
  rasterised.

## 6. media-bridge and webp-swift: what was reused, and their limits

* `ImageBridge.probe(url:)` → `ImageCodecs.probe(url:)` (format, size, depth, alpha mode, ICC, DPI,
  orientation, frames and delays). `ImageBridge` decode → `ImageCodecs.decodeDisplay8(url:)` and
  `PDFDocumentIO.rasterizeViaImageBridge(url:)`, the fast 8-bit path.
* Limits found: ImageBridge's decoders render everything through a CIContext pinned to sRGB into
  **8-bit BGRA** (`StillMetadata.isLinear` always false; raw "P1 narrows to 8-bit display-referred
  BGRA"), so CMYK, Lab, 16-bit and float documents cannot go through it; `RawDecoderImpl` and
  `PDFRasterizer` are internal and the public `ImageBridgeFactory.makeDecoder` takes no
  `RawDecodeOptions`; decoders are URL-only (no `Data`); the encoder takes BGRA CVPixelBuffers
  (8-bit, ICC re-tagged, no EXIF/XMP). PCPlatform therefore keeps its own native-depth ImageIO
  path and reuses ImageBridge's types (`RawDecodeOptions`, `StillMetadata`) and 8-bit paths, and
  cross-checks against them in tests.
* `MediaMeasure.ImageQualityTarget` drives `ImageCodecs.encodeToQualityTarget` (JPEG/HEIF/AVIF/WebP
  at the lowest quality meeting a SSIMULACRA2 score; JPEG 0.66 → 70.2, HEIF 0.61 → 70.0, WebP 0.92 →
  74.4 on a 128×96 test image).
* `WebPStillEncoder` (webp-swift) is the WebP writer. Limits: 8-bit sRGB only (wider inputs are
  colour-managed and quantised), no ICC/EXIF/XMP chunks, 16 383 px per side. libwebp's quality
  scale differs from photocraft's VP8 encoder, and webp-swift exposes no quantiser → quality inverse,
  so `SourceSettings.webpQuality` inverts libwebp's mapping itself (§11); `webpEncoding` still
  carries the raw base quantiser.

## 7. Not possible natively (or not done)

* ImageIO cannot write WebP (webp-swift does), Radiance, PCX, FITS, QOI, PAM/PFM or binary PBM (the
  last five ported); DDS writing is listed but always fails; JPEG 2000 writes 8-bit only; JPEG XL is
  read-only; PSD is flattened (and its alpha unusable); EXR is single-part, never deep, RGB always
  gains an alpha channel; raw EXIF bytes and Photoshop image resources (8BIM) are not exposed (EXIF is
  dictionaries + XMP).
* Core Image: no demosaic choice, no Dehaze, no camera-look fitting, no raw for files the OS doesn't
  list; DNGs below ~200 px are refused.
* CoreText: no Photoshop optical kerning, hinting-based AA modes, text warp, or EngineData (PSD text
  serialisation is PCPSD's). Not ported from photocraft's layout: the vertical-type punctuation
  squeeze (JIS X 4051), and dropping horizontal box lines whose baseline passes the box bottom
  (vertical columns past the left edge are dropped).
* CoreGraphics: draws nothing for path points ~1e9 px from the bitmap (clipped first, §11); 8-bit
  anti-aliasing quantisation (supersample for precision); boolean ops on
  near-tangent curves can differ from photocraft's coverage-level combination by ~1 px² (the
  union identity error measured 0.98 px² on a square ∪ circle).
* ColorSync: BPC and absolute-intent behaviour as above (worked around); no `mpet`/DeviceN.
* Not implemented: XMP sidecars for raw, ICC profile *editing*, FITS tile compression, EXR
  Cryptomatte/deep, `.cube` LUT files (photocraft `lutfile.rs` — PCAlgo territory), PDF text import
  as editable type.

## 8. Public entry points

`ICCProfile`, `BuiltinProfile`, `ColorTransform` (`.proof`, `.cached`), `GamutCheck`, `DisplayLUT`
(`.canvas`, `makeTexture`), `DisplayProfiles` (@MainActor), `ColorManagement.install()`,
`ColorMath`, `LabEncoding`, `GridLUT`; `ImageFormat` (+ `caps`, `photocraftSupport`, `detect`),
`ImageCodecs` (`decode`, `frames`, `decodeAllFrames`, `encode`, `encodeFrames`, `fidelityWarnings`,
`probe`, `decodeDisplay8`, `encodeToQualityTarget`), `ImageMetadata`, `SourceSettings`
(`jpegQuality`, `webpEncoding`, `imageIOQuality(forIJG:)`), `SurfaceBridge`, `RasterBuffer`;
`RawDeveloper` (`develop`, `embeddedPreview`, `isSupported`), `RawDevelopSettings`; `FontCatalog`
(`resolveFace(CharStyle)`, `invalidateCaches`), `TextEngine` (`layout`, `rasterize`,
`rasterizeCoverage`, `outlines`, `renderLayer` — all on PCDocument `TextLayer`), `TextLayout`
(`hitTest`, `caret`, `caretSegment`, `toText`/`toLine`, `isVertical`), `LineInfo`
(`trailingWhitespace`), `PlacedGlyph.orientation` / `GlyphOrientation`; `SourceSettings.webpQuality`,
`libwebpQuantizer(quality:)`; PCDocument `VectorPath.cgPath` / `init(cgPath:)`,
`LiveShape.path`, `StrokeStyle`, `ShapePaint`, `VectorGeometry`, `VectorRasterizer` (`coverage(of:
VectorMask)`, `rasterize(ShapeLayer)`, `renderCache`), `PathBoolean`, `PathHitTest`;
`PointerEvent`, `TabletState`, `PointerInput`, `PointerCoalescer`; `VisionGeometry`;
`PDFDocumentIO`.

## 9. Foundation change requests

1. **`SampleType.f16`** — EXR/TIFF half floats are widened to f32 on decode
   (`DecodeWarning.depthWidened`). *Deferred by the coordinator until the other ports finish.*
2. ~~`PixelFormat` clash with Accelerate~~ — **done** (`PCPixelFormat` typealias; used in
   `SurfaceBridge`).
3. ~~Batch `CMYKConverter`~~ — **done** in PCFoundation; implemented here as one exact ColorSync
   transform per call (§3).
4. ~~Shared vector and text models~~ — **done**: PCPlatform now renders PCDocument's (§10).
5. `ColorConvert.d50.z` 0.82521 vs ICC 0.8249 — **kept** at photocraft's value for parity
   (measured impact ΔE 0.002).

## 10. Revision 2: PCDocument's model

PCPlatform depends on `../PCDocument` and has no document-level model of its own. Removed:
`Vector/VectorPath.swift` (`VectorPath`, `Subpath`, `PathKnot`, `PathOperation`, `PathFillRule`,
`LiveShape`) and `Text/TextModel.swift` (`TextBlock`, `TextCharStyle`, `TextParagraphStyle`,
`TextRun`, `ParagraphRun`, `TextShape`, `TextOrientation`, `TextAntiAlias`, `TextAlign`,
`TextDirection`, `TextKerning`, `TextCaps`, `FontFeature`, `FontVariation`), plus
`LineCap`/`LineJoin`/`StrokeAlign` and `ShapeAppearance`. In their place:

* `Vector/VectorPath+CG.swift` — CG bridges on PCDocument's `VectorPath`/`Subpath` (straight
  segments as lines so joins and caps are true), `VectorPath(cgPath:)` (one shape component, holes
  kept), `LiveShape.path`, `LiveShape.clampRadii`.
* `Vector/ShapePaint.swift` — photocraft-vector's gradient `Paint` over PCDocument's `Fill`.
* `VectorRasterizer.coverage(of: VectorMask, …)`, `.rasterize(ShapeLayer, …)`, `.renderCache`,
  `StrokeStyle(ShapeStroke)` (dashes from widths to pixels, photocraft `stroke_style`).
* `TextEngine` takes `TextLayer` + `dpi`; an internal `TextBlock` holds the layer's normalised
  `charRuns()`/`paragraphRuns()`. Paragraph `direction` now sets CoreText's base writing direction.
* All exact-area, path-operation, stroke, live-shape, hit-test, text and PDF tests run on the
  document types unchanged in their expectations, plus new ones (gradient shape fill, pattern =
  transparent, disabled/inverted-empty vector masks, `renderLayer` / `renderCache` refreshing caches,
  PDF gradient shapes placed rasterised).

### PCDocument change requests (nothing edited there)

1. **`TextLayer` has no resolution.** photocraft passes `dpi` beside the layer; so does
   `TextEngine` here. A `Document.resolution` (or `TextLayer` carrying the ppi it was set at) would
   let callers stop threading it.
2. **`TextWarp` is stored but nothing renders it** (photocraft-text's `warp.rs` bends outlines);
   `TextEngine.outlines` gives the vectors a warp can be applied to — a warp evaluator belongs with
   PCDocument's `Warp` maths or PCRender.
3. **Photoshop character/paragraph fields CoreText could use but the model lacks:** super/subscript
   (`FontBaseline`), tate-chū-yoko and upright-in-vertical (CoreText
   `kCTHorizontalInVerticalForms`), no-break, the Justification settings (word/letter spacing,
   glyph scaling — CoreText's justification factor), tab stops, hanging punctuation. photocraft's
   doc lacks them too; listed for when PSD text import needs them.
4. **`ShapeStroke`/`Fill` have no pattern table access in the vector layer**: pattern paints render
   transparent (photocraft's behaviour); rendering them needs `Document.patterns` passed in or a
   resolved pattern surface on `Fill.pattern`.

## 11. Revision 3: PCEngine's change requests

PCEngine's PORT-NOTES ("Change requests for other packages") filed six requests against PCPlatform.
Each is fixed (or, for 4, answered) with a test and checked against photocraft. Release timings come
from a scratch benchmark over the public API (`swift build -c release`; one 137-character box
paragraph, four families, idle machine); Debug numbers are the tests' `MEASURE` lines.

**1. Font lookups: cached, and safe for concurrent readers** (`Text/FontCatalog.swift`). Faces are
cached per family, faces and descriptors per PostScript name (misses too), the resolved face per
character style, CTFonts per instance (size, matrix, variations), OpenType feature sets and vertical
alternates per face. A lookup holds a `Mutex` only to read its table; a miss is computed under one
recursive lock, so the font registry still sees one query at a time. `register(fontData:)`, the
system's `kCTFontManagerRegisteredFontsChangedNotification` and `invalidateCaches()` clear
everything. Sampling then found a second, process-wide lock: `NSAttributedString(string:attributes:)`
uniques its attribute dictionary under one unfair lock (`+[NSAttributeDictionary
newWithDictionary:]`, UIFoundation), and `TextEngine.paragraph` made one per character, which held
8 threads to one thread's throughput. It now appends one string per run of equal attributes and
looks the font up only where the style changes.

| Release, Apple M5 Max | before | after |
|---|---:|---:|
| `FontCatalog.resolveFace` | 35.9 µs | 0.05 µs |
| `FontCatalog.ctFont(for:sizePx:)` | 41.1 µs | 0.13 µs |
| `TextEngine.layout` (137 characters, 1 thread) | 4.44 ms | 0.079–0.093 ms |
| Parallel layouts/s at 1 / 8 / 16 / 32 threads | 308 / 487 / 468 / 458 (worst single layout 5 / 34 / 140 / 194 ms) | 11 700 / 38 000 / 45 700 / 52 600 (worst 0.2 / 2 / 25 / 107 ms) |

Test: `fontCatalogCachesAndServesConcurrentReaders` (Debug: a cached `resolveFace` 0.5 µs against
29 µs for one family's faces from the registry; 16 threads laying out mixed families, CJK and
vertical layers from cold caches produce exactly the single-threaded glyphs). PCEngine:
`TypeCommands.textLock` is removed and `fonts(_:)` is a pass-through (call sites unchanged); its full
suite passes without the lock.

**2. Manual kerning replaces the pair's metrics kerning** (`TextEngine.paragraph`, `pairKerning`).
photocraft confirms it (`crates/text/src/layout.rs` `feature_list`: "Optical and manual kerning
replace the font's kerning table; a character with a manual kern is manually kerned whatever its
mode"). CoreText, measured with Helvetica Neue 40 px "AV": V sits at 24.08 with metrics kerning and
25.92 unkerned; a non-zero `kCTKern` of −4 puts it at 20.08, so it is *added* to the pair kerning;
`kCTKern = 0` turns kerning off on both sides of the character; the OpenType `kern = 0` feature
setting changes nothing for this font. So the pair's own kerning is measured (where the next
character's glyphs start with `kCTKern = ε` and with `0`) and `kCTKern = manual − pair` is set. Glyph
positions are used rather than `CTLineGetOffsetForStringIndex`, because the caret between a kerned
pair carries only half the kern (−0.92 of −1.84 px). One deviation: photocraft's run split also drops
the metrics kerning of the pair *before* the kerned character, but here that pair keeps it, as in
Photoshop. Test: `manualKerningReplacesThePairsMetricsKerning` (photocraft
`manual_kerning_moves_the_next_glyph` ported; "AV" with −50 at 100 px lands at unkerned − 5 in
Metrics, Off and Optical; "VAV" keeps V·A), plus the updated `trackingKerningCapsAndFeatures`.

**3. Vertical type follows photocraft's semantics** (`crates/text/src/layout.rs`,
`vertical_tests.rs`). Lines are laid out in line space and turned 90° clockwise into text space.
* **Columns.** Point text's first column is centred on x = 0 and starts at y = 0; later columns
  move left by their leading. Box text's columns run along the box **height** from the box **top**,
  with the first column's right edge on the box's right edge. A column past the box's left edge is
  dropped, with everything after it.
* **Glyph orientation.** CJK (photocraft's `vertical_class`, ported) is upright, through CoreText's
  vertical forms: `vert` alternates, `vmtx` advances, and `VORG` origins. A vertical-forms run reports
  `pos = (−advance/2, vt.y − pen)`. Brackets, dashes and ー are upright only when the face has an
  alternate. Everything else is rotated and centred on the column by (ascent − descent)/2.
  `PlacedGlyph.position` is the text-space origin, and the new `orientation` says which case applies.
* **Drawing.** Columns are drawn glyph by glyph (`CTFontDrawGlyphs`, with fill and stroke from the
  run, so faux bold is kept). Outlines and ink bounds follow the same transforms. The underline sits
  right of the column and the strikethrough on its centre line. Baseline shift moves glyphs right.
* **Geometry API.** `LineInfo` for a column: `x` is the centre line, `baseline` the top, `width` the
  length down the column, and `ascent`/`descent` the half widths (what PCEngine's
  `TypeCommands.Layout` reads). `ClusterInfo.x` and `caret` are in line space; `caretSegment`,
  `toText`, `toLine` and `isVertical` are new; `hitTest` uses photocraft's closest-line rule.
* **Hostile input.** Boxes with non-finite fields lay out as 0, and ink beyond ±2³⁰ px is clamped.

Not ported: the punctuation squeeze. Upright advances are the font's vertical advances, where
photocraft uses the horizontal ones (they are the same for full-width CJK). Tests: ten ported from
`vertical_tests.rs` (classes, rotated Latin, rotated ink, carets and hit tests, box columns and
alignment, horizontal unchanged, upright CJK with alternates and outline IoU 0.99, manual kerning
along the column, decorations and faux bold, hostile input). PCEngine's
`verticalPointAndParagraphConversionKeepTheColumnsInPlace` is enabled and passes.

**4. `LineInfo.width` and trailing spaces: no change, because photocraft does the reverse of what the
request says.** photocraft's line extent is `x1 = x0 + adv + extra − trailing_tabs` with
`adv = m.advance − m.trailing_whitespace` (`layout.rs:716`, `:1010`). In parley 0.11.1,
`LineMetrics.advance` includes trailing whitespace and `trailing_whitespace` is its share
(`layout/line_break.rs` `commit_line` / `finish_line`). photocraft's tests say so too: "a trailing
tab is whitespace outside the line's extent" (`tests.rs:137`). `width` already matched. Added,
additively: `LineInfo.trailingWhitespace`, so `width + trailingWhitespace` gives the full advance
directly (PCEngine's `TypeCommands.Layout` widens `x1` to its last cluster to get the same thing).
Test: `trailingWhitespaceHangsOutsideTheLineExtent` (width, carets and hit tests past the spaces,
right-aligned point and box text).

**5. Far path coordinates** (`Vector/VectorRasterizer.swift`, "Far coordinates"). Measured on macOS
27.2: a fill or stroke across the bitmap is exact with its points 5e8 px away and draws **nothing**
at 1e9, 3e9 and 1e12. The limit is in device space: a small shape 1e12 px away in user space draws
fine once the CTM brings it near. A path with any point non-finite or more than 1e7 px from the
rendered rectangle is now restricted to it before CoreGraphics sees it:
* **Flattening.** Curves are flattened adaptively. Where a curve's control polygon misses the
  window, it becomes its chord; the curve and chord bound only area outside, so winding numbers
  inside are unchanged.
* **Fills.** Sutherland–Hodgman clips per subpath, so path operations and fill rules hold.
* **Strokes.** Liang–Barsky cuts strokes into pieces at a window wider than the stroke's reach, so
  the cut caps fall out of sight. Closed loops are walked from an outside point, so no join inside
  is cut. Dash phases carry the arc length (Gauss–Legendre for chorded curves).

It applies to `coverage(CGPath)`, `fillCoverage` (and so vector masks), `strokeCoverage`,
`coverageSurface` and `bounds(of:)` (so `rasterize` and `renderCache`). Paths within 1e7 px are
untouched. Test: `farCoordinatesAreClippedBeforeCoreGraphics`. At ±1e8, ±3e9 and ±1e12 a half-plane
covers its exact 1280 px², where CoreGraphics alone gives 0; also checked are a diagonal, a
subtract, a circle of radius 1e12, open and closed strokes, the dash phase, a shape layer, a coverage
surface and a NaN point.

**6. WebP quality on libwebp's scale** (`SourceSettings.webpQuality(_:)`, additive;
`.lossy(baseQuantizer:)` unchanged). photocraft inverts its own encoder's quality → index map by
nearest search (`source_settings.rs` `vp8_quality`). webp-swift has no inverse; it exposes only
`encode(_:quality:)`, which is always lossy (its rule 1). So libwebp 1.6.0's map is inverted here:
* **Forward map** (`quant_enc.c` `QualityToCompression`, `VP8SetSegmentParams`): index =
  ⌊127·(1 − c)⌋ with c = linear^⅓, linear = ⅔·q below 0.75 and 2q − 1 above.
* **Segments.** libwebp quantises each segment at c_base^(1 − amp·αᵢ). The unclipped αᵢ have a
  macroblock-weighted mean of 0 and span exactly 255 (`analysis_enc.c` `SetSegmentAlphas`). The
  weights come from the header's segment-map probabilities (`frame_enc.c` `SetSegmentProbas`).
* **Estimate.** Without clipping, ln c_base is the weighted mean of ln cᵢ. When one extreme segment
  is clipped at ±127 (most macroblocks alike), the two constraints solve for it. No SNS strength is
  assumed.

The plain weighted mean was off by up to 4 on half-flat images; the clipped solve brings that to 1.
Measured: within ±1 of the quality written, 5…100 in steps of 5, on seven image kinds (140 encodes).
100 reads back as 99 (index 0 covers ≈ 98.8–100). The top of the knob stays lossy: q 100 is a `VP8 `
chunk, as the fleet lesson requires. Test: `webpQualityIsRecoveredOnLibwebpsScale` (the forward map,
its inverse at every quality, five images × nine qualities within ±2). **PCEngine still needs one
line**: `EngineIO.fileEncoding` sets `webpQuality = 75` for every lossy WebP, and should use
`SourceSettings.webpQuality(data) ?? 75`. That is outside this revision's PCEngine scope (the lock
and the vertical test).
