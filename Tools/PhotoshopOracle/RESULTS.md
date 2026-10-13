# Photoshop oracle — results

Adobe Photoshop 2026 **27.11.0** on macOS 27.2 (M5 Max), driven by `ps-oracle` (README.md),
2026-10-12. Every number comes from the JSON reports in the fixtures root (`$PHOTOCRAFT_FIXTURES`, the
oracle's default data root; copied there from the session scratch folder they were made in):

- `$PHOTOCRAFT_FIXTURES/ps-oracle/<run>/<run>.json`
- `$PHOTOCRAFT_FIXTURES/ps-corpus/pcpsd-read.json` and `manifest.json`
- `$PHOTOCRAFT_FIXTURES/ps-oracle/quarantine.json`
- `$PHOTOCRAFT_FIXTURES/ps-oracle/blend-table.json`

Each section names the command that reproduces it.

## Summary

| Set | Files | Opens in Photoshop | Layer tree matches PCPSD | Pixels |
|---|---:|---|---|---|
| **A. Photoshop-authored corpus, read by PCPSD** (`ps-corpus`) | 153 | — (Photoshop wrote them) | 149/153 (4: colour-overlay bug B1) | merged = Photoshop's composite exactly in 147/153; the other 6 differ inside Photoshop |
| **B. PCPSD builder files** (`pcpsd-fixtures`: builder, TestGen merged-only, ImageIO-written) | 151 | **116/151** (builder 96/128; all 32 rejects are F1) | 116/116 | 672 per-layer checks: every layer as PCPSD wrote it, worst 0.012 levels |
| **B′. PCPSD builder files, regenerated** (F1 fixed in the builder) | 150 | **149/150** (builder 128/128; merged-only 14/15, only F3 left; ImageIO 7/7) | 149/149 | 896 per-layer checks, worst 0.012 levels, including the 32 transparent 16/32-bit files F1 blocked |
| **C. PCIO exports, before fixes** (non-fuzz, snapshot of 1,335) | 1,335 | **1,074** (80 %). 231 refused, 29 never opened (pre-screened), 3 crashed Photoshop | 1,006/1,074 (41 B1; 20 adjustment layers Photoshop reads as pixel layers; 7 other) | Photoshop round trips: composite exact except Photoshop-internal differences |
| **C′. PCIO exports, after fixes** (non-fuzz, snapshot of 1,333) | 1,313 | **1,302** (99.2 %). 7 refused (no known cause left), 4 never opened (pre-screened; one after the TS modal), 0 crashed | 1,204/1,302 (89 of the 98 mismatches: adjustment layers Photoshop reads as pixel layers) | composite exact 697 (C: 665); `ps-corpus` round trips as before |
| **C″. PCIO exports, regenerated again** (non-fuzz, snapshot of 1,501) | 1,481 | **1,475** (99.6 %). 6 refused (the bisected test fixtures), 0 pre-screened, 0 crashed | 1,461/1,475 (7 files: Color Lookups with a table read as pixel layers; 6 artboards Pass Through → Normal; 1 as before) | composite exact 690 |
| **C‴. PCIO exports, after the writer follow-ups** (non-fuzz, snapshot of 1,544) | 1,524 | **1,524** (100 %). 0 refused, 0 pre-screened, 0 crashed | 1,515/1,524 (7 files: Color Lookups with a table; 1 stale PCEngine artboard export; 1 as before) | composite exact 709 |
| **D. Structural fuzz** (`testgen*`, PCPSD's randomised fixtures) | 20 | deferred: 9 opened before the pre-screens existed were all refused, and one raised a modal; the pre-screens catch 18/20 | | |

**Top bugs Photoshop exposed**, with the fix and where it goes:

| # | Bug | Effect in Photoshop | Where | Fix |
|---|---|---|---|---|
| F1 | `Lr16`/`Lr32` written before `Mt16`/`Mt32` | file refused | PCPSD `Builder.swift:430,436`; PCIO `PSDExport.swift:1582–1583` | emit the matte block first and place the layer info after it, as Photoshop does. This makes 32 builder files openable, plus every PCIO round trip of a transparent 16/32-bit Photoshop file (6/6 refused) |
| T1 | type layer whose EngineData lacks Photoshop's structures, written verbatim from `psdRaw` | **Photoshop crashes** (null read in `app.open`), 3 times | PCIO `PSDExport.swift:1026–1028` | run a preserved `TySh` through `PSDText.buildTySh`/`buildEngineData` unless it is complete. PCPSD now has the check (`photoshopStructureGaps()`) |
| BM | blend mode not allowed for the document's mode/depth; Pass Through on a non-group | refused, or a **modal** ("unsupported blending mode") that blocks scripting | PCIO `PSDExport.swift:902`, `:1370`; PCPSD builder has no guard | map to an allowed mode with a warning, per the measured table (§5) |
| GM | `grdm` (Gradient Map) block length not a multiple of 4 | file refused | PCIO `AdjustMap.swift:509–545` | zero-pad the block data to a multiple of 4, inside the length |
| TX | `Txt2` written by PCIO | file refused ("General Photoshop error") | PCIO `PSDTextWrite.buildTxt2` (`:223`) | the files open without it; which field is wrong is still open |
| PT | pattern data written by PCIO (`Patt`/`Pat2`/`Pat3`) with the transparency in the user-mask array (slot 24) | file refused even with no layers; a pattern fill without pattern data is refused too | PCIO PatternMap | store transparency in the sheet-mask array (slot 25) as Photoshop does; PCPSD's linter rule `patternTransparencyInUserMask` flags all 40 refused files and none of the 2,064 opened (AB-L-0258); pre-screen 4 |
| B1 | `"Sofi"` instead of `"SoFi"` | none: PCPSD's `effects` silently drops colour overlays | PCPSD `Effects.swift:19` | `"SoFi"` |
| B2 | `Txt2` 8-bit strings re-encoded as UTF-16 | `Txt2` not byte-identical (0/10) | PCPSD `EngineData.swift:205, 342–345` | keep each literal's encoding |
| B3 | `userMask()` returns a vector mask's rasterisation | a consumer would duplicate the vector mask as a raster mask | PCPSD `Pixels.swift:248–250` | skip −2 when the mask record `cameFromRendering` |
| TS | type layer with a size Photoshop cannot read (1e30 pt; `Double.greatestFiniteMagnitude` pt and transform). Deliberately hostile test fixtures, not a writer bug | the type layer becomes an empty pixel layer; one file raised the **modal** "Some of the type layers in this document were rasterized because an error prevented them from being read" | PCIO `PSDTypeBoundsTests.swift:270` (and a 0 pt layer from `RoundTripTests.swift:200`) | none needed in the writer. Pre-screen 3 (§C′) keeps them away from Photoshop; PCPSD's linter could flag them (it does not now) |
| F2/F3 | test fixtures: 32-bit without `hdrt`; Duotone with placeholder data | refused | PCPSD `TestGen.swift:51–56` | `PSDHDRToning.colorModeData(depth:)`; a real duotone spec |

## A. The Photoshop-authored corpus, read by PCPSD

```bash
ps-oracle corpus build      # $PHOTOCRAFT_FIXTURES/ps-corpus: 153 files + composites/ + info/ + manifest.json (~5 min)
ps-oracle corpus read       # PCPSD over it → pcpsd-read.json / .md
```

Two files were added later, outside the tables below (their PCPSD read is not yet in
`pcpsd-read.json`):
- `adj-brightnessContrast-b25c35.psd`: modern B/C with Brightness 25 applied (§5c);
- `artboard-blend.psd`: Photoshop's own artboards (§C′).

`ps-corpus` now holds 155 files.

Every file was built by script in a new document and saved with Maximize Compatibility on, so
PCPSD sees real merged data in 153/153. Each was then reopened, and Photoshop's own reading
(`info/`) and flattened composite (`composites/`, plus `-alpha.tif` for the 5 documents without
a background) were saved beside it.

| Family | Files | Covers |
|---|---:|---|
| `mode-*` | 18 | RGB 8/16/32, Gray 8/16/32, CMYK 8/16, Lab 8/16 (layers, a 60 % multiply ellipse, a soft transparent ramp); RGB 8/32 and Gray 32 background-only; Bitmap; Indexed (and with a transparent index); Multichannel 8/16 |
| `transparent-*` | 5 | no background, partially transparent merged image (white matte): RGB 8/16/32, Gray 16, CMYK 8 |
| `blend-*` | 32 | all 27 modes, one file each (RGB 8); one file per colour mode with 27 bands, one layer per mode: RGB 16, RGB 32, CMYK 8, Lab 8, Gray 8 |
| `group-*`, `clipping-*` | 7 | pass-through vs normal, group opacity, nested groups, hidden layers; clipping (incl. a clipped adjustment, "blend clipped layers as group" off) |
| `mask-*` | 9 | raster, soft, density, feather, disabled, vector, vector with feather and density, raster + vector, mask on a group |
| `adj-*` | 21 | all 16 adjustment kinds scripting can create, plus a stack of every kind in RGB 16, RGB 32, CMYK 8, Lab 8, Gray 16 |
| `fill-*` | 8 | solid, solid with mask, linear/radial/angle gradients, pattern; fill vs opacity; the special-eight modes at 50 % fill |
| `fx-*` | 17 | each of the 10 styles, all together, multi-instance, disabled, hidden, on a group, in CMYK, in 16-bit |
| `knockout-*`, `blendif-*`, `advanced-*` | 6 | shallow and deep knockout; blend-if (gray, split; channels); channel restrictions; blend interior, transparency shapes, layer mask hides effects |
| `text-*` | 7 | point, paragraph, three style runs, warp, effects, vertical, CMYK |
| `shape-*` | 5 | live rectangle, rounded rectangle with stroke, ellipse with gradient fill, stroke only, CMYK |
| `smart-*` | 6 | embedded, transformed, Gaussian Blur smart filter, three smart filters, 16-bit Emboss, nested |
| `channels-*`, `hidden-*` | 3 | alpha + spot channel, CMYK spot, hidden and locked layers |
| `psb-*` | 5 | PSB: layers + mask + text + group, 16-bit adjustments, smart filter, CMYK, 32-bit |
| `combined-*` | 4 | everything together in RGB 8, CMYK 8, RGB 16, RGB 32 |

**Feature claims are checked.** The manifest's 498 feature tags break down as:

- **440** confirmed by Photoshop's reading of the saved file;
- **11** confirmed in its Photoshop-written blocks (knockout, blend-if and advanced-blending flags,
  which Action Manager's layer descriptor does not report);
- **47** not visible to either (shape geometry, style runs, a smart object's transform, locks);
- **0** unconfirmed.

This check caught four bugs in my own builders during development; all four were fixed and the
corpus was rebuilt from clean. In the first build, all 27 blend files had an empty blend layer. If
you used that build (PCIO's PORT-NOTES "Composite oracle on it, 109/148"), re-run on the current
one.

**Photoshop refused to build 5 entries** (listed under `skipped` in the manifest, with its error):

- CMYK-32 and Lab-32: Photoshop has no such modes.
- Three Duotone entries: Image › Mode › Duotone is not scriptable. 31 Convert Mode descriptor
  shapes were refused with "The parameters for command “Convert Mode” are not currently valid",
  and the DOM has no Duotone conversion.

### PCPSD's reading

| Check | Result |
|---|---|
| Parse | 153/153 |
| Byte-identical rewrite and model-equal reparse | **153/153** |
| Typed-block round trips | every typed parser reproduces Photoshop's bytes **except `Txt2`, 0/10** (B2) |
| Layer tree vs Photoshop's reading | 149/153; the 4 failures are colour overlays (B1) |
| Merged image vs Photoshop's exported composite | **147/153 exact** |
| Merged alpha vs Photoshop's transparent composite | 5/5 exact |
| Pre-screens (EngineData, blend table) | 0/153 flagged (calibration) |

Typed round trips (Photoshop's bytes → PCPSD model → bytes):

- Effects: lfx2 51/51, lrFX 53/53, lfxs 1/1, lmfx 1/1.
- Adjustments: levl 8, curv 8, hue2 8, brit 6, blnc 5, expA 5, grdm 5, nvrt 5, phfl 5, post 5,
  thrs 5, clrL 5, mixr 4, selc 4, blwh 3, vibA 2 (all clean).
- Fills: SoCo 5, GdFl 5, PtFl 1.
- Vectors: vmsk 8, vogk 6, vscg 2, vsms 2, vstk 2.
- Smart objects: PlLd 9, SoLd 9, FEid 5, lnk2 8, lnk3 1, lnkE 9.
- Text: TySh 10, EngineData 10.
- Metadata: shmd 714.
- Resources: 1005, 1032, 1050, 1057, 1082, 1083 (153 each), 1088 (8).
- **Txt2: 0/10.**

The full table is in Appendix B.

**The 6 merged-image differences are inside Photoshop:**

| File | Max difference (levels) | Pixels affected |
|---|---:|---:|
| `adj-stack-rgb-16` | 194 | 190 of 6,144 |
| `adj-stack-cmyk-8` | 13 | 23 |
| `adj-gradientMap` | 1 | 20 |
| `adj-stack-gray-16` | ≤ 0.008 | — |
| `mode-lab-16` | ≤ 0.004 | — |
| `psb-rgb-32` | float rounding | — |

ImageIO, an independent decoder, reads the stored merged image identically to PCPSD (0
difference). So Photoshop's saved merged image differs from its own recomposite on reopen. The
large values come from Threshold and Posterize, which turn a one-unit difference into a full
level step. **For the compositor oracle, use `composites/<name>.tif`, not the stored merged
image.**

The **Unity corpus** (36 Photoshop files) passes both pre-screens, and PCIO's round trips of it open
72/72.

## B. PCPSD builder files

```bash
ps-oracle sweep $PHOTOCRAFT_FIXTURES/pcpsd-fixtures --name acceptance-final     # 151 files, ~6 min, with per-layer exports
```

| Family | Files | Open | Tree | Layer checks: worst (levels) | Composite vs merged |
|---|---:|---:|---:|---|---|
| builder, opaque (RGB/Gray 8/16/32, CMYK 8/16, Lab 8/16 × PSD/PSB × 4 compressions) | 80 | 80 | 80 | 560 checks: 0 at 8 and 32 bits, ≤ 0.012 at 16 bits | ‡ |
| builder, partial transparency, 8-bit (RGB, Gray) | 16 | 16 | 16 | 112 checks: 0 | ‡ |
| builder, partial transparency, 16/32-bit (RGB, Gray) | 32 | **0 (F1)** | – | – | – |
| merged-only (TestGen), 15 modes and depths | 15 | 12 (F2 ×2, F3 ×1) | 12 | – | 0 at 8 bits, ≤ 0.004 at 16 bits |
| written by ImageIO (not the port) | 8 | 8 | 8 | – | 0, or 255 where ImageIO's own writer damaged the layers † |

‡ The builder fixtures' merged image is an independent pattern (`ImageIOOracleTests.swift:65`), so
Photoshop's recomposite can't match it (168–232 levels, identical across compressions). The
per-layer column is the real result: every pixel layer, its transparency and its mask reach
Photoshop exactly as PCPSD wrote them, in every mode, depth, container and compression.
† ImageIO's writer corrupts layer channels; Photoshop composites the damage without a word.

**F1, bisected** (`DebugTests`, `PSO_VARIANTS_OUT`). Photoshop's own transparent 16-bit file writes
`Mt16`, then `Lr16` (positive count). Variants of the rejected builder files:

| Variant | Photoshop |
|---|---|
| `Lr16` then `Mt16` (as written) | refused |
| same order, positive count | refused |
| `Mt16` first, either sign | **opens** |
| no `Mt16` at all, either sign | **opens** |

The opening variants match the tree and every layer to 0.01 levels.

**F2:** adding `hdrt` colour-mode data makes the merged-only 32-bit files open, and their composite
then equals the merged image exactly. PCPSD's linter already flags this (`Compatibility.swift:38`).

**F3:** Duotone colour-mode data of 24 placeholder bytes, and also a 516-byte `.ado`-layout
attempt, are refused. A real duotone specification is needed, and Duotone can't be scripted to
learn one from.

The full per-file table is in Appendix A.

## B′. PCPSD builder files, regenerated

PCPSD regenerated its fixtures (150 files; the ImageIO-written `imageio-rgbf32` is gone) after
fixing F1 (matte block first) and adding `hdrt` at 32 bits. All four pre-screens pass all 150.

```bash
ps-oracle sweep $PHOTOCRAFT_FIXTURES/pcpsd-fixtures --name pcpsd-b2     # with per-layer exports
```

| Family | Files | Open (B) | Tree | Layer checks: worst (levels) | Composite vs merged |
|---|---:|---:|---:|---|---|
| builder, opaque | 80 | 80 (80) | 80 | 560 checks: 0 at 8 and 32 bits, ≤ 0.012 at 16 bits | ‡ |
| builder, partial transparency, 8-bit | 16 | 16 (16) | 16 | 112 checks: 0 | ‡ |
| builder, partial transparency, 16/32-bit | 32 | **32 (0)** | 32 | 224 checks: 0 at 32 bits, ≤ 0.012 at 16 bits | ‡ |
| merged-only (TestGen) | 15 | 14 (12) | 14 | – | 0 at 8 and 32 bits, ≤ 0.004 at 16 bits |
| written by ImageIO | 7 | 7 (8) | 7 | – | as in B (†) |
| **all** | **150** | **149 (116/151)** | **149** | **896 checks, worst 0.012** | |

- **F1 is fixed:** all 32 transparent 16/32-bit builder files open, and every layer, its
  transparency and its mask match what PCPSD wrote.
- **F2 is fixed:** `merged-Grayscale-32` and `merged-RGB-32` open, and their composite equals the
  merged image exactly.
- **Still refused:** `merged-Duotone-8` (F3, placeholder duotone data; a test fixture).
- No crash, modal or timeout. The only PCPSD linter finding is "no version info resource (1057)"
  on the 7 ImageIO files.

## C. PCIO exports (before fixes)

PCIO's tests wrote their outputs to `pcio-exports` (now `$PHOTOCRAFT_FIXTURES/pcio-exports`). A snapshot of 1,355 files (copied
17:39) was swept with both pre-screens. The 20 `testgen*` fuzz files are in §D; the rest are here.

```bash
ps-oracle prescreen $PHOTOCRAFT_FIXTURES/ps-oracle/pcio-snapshot             # offline: quarantines known crash/modal classes
ps-oracle sweep $PHOTOCRAFT_FIXTURES/ps-oracle/pcio-snapshot --name pcio --no-layers
ps-oracle explain $PHOTOCRAFT_FIXTURES/ps-oracle/pcio/pcio.json $PHOTOCRAFT_FIXTURES/ps-oracle/pcio-snapshot   # offline: proven refusal causes
```

| Source | Files | Opened | Refused | Never opened (pre-screened) | Crashed Photoshop | Tree match | Composite exact |
|---|---:|---:|---:|---:|---:|---:|---:|
| round trips of `ps-corpus` (direct + via `.pcraft`) | 306 | 300 | 6 (F1) | 0 | 0 | 292 | 268 |
| round trips of the Unity corpus (direct + via `.pcraft`) | 72 | 72 | 0 | 0 | 0 | 68 | 72 |
| synthetic documents (PCIO unit tests) | 957 | 702 | 225 | 29 | 3 | 646 | 325 |
| **all** | **1,335** | **1,074** | **231** | **29** | **3** | **1,006** | **665** |

(Two of the three crashers are listed as "never opened" in the sweep report because they were
quarantined after crashing.)

**The round trips are what matter for users.**

- **300/306 of Photoshop's own files survive a PCIO round trip and open.** The 6 that don't are
  the transparent 16/32-bit documents, all F1: PCIO keeps Photoshop's `Mt16`/`Mt32` and puts
  `Lr16`/`Lr32` in front of it.
- Every tree mismatch is B1 on PCPSD's reading side. PCIO maps `SoFi` correctly.
- Composite differences repeat the originals' Photoshop-internal ones, except Indexed (238 levels)
  and Bitmap (255). There, PCIO's converted layer equals Photoshop's original composite exactly,
  and only the merged image is wrong. That comes from the round-trip test helper `mergedPixels`
  (`PCIO/Tests/PCIOTests/TestSupport.swift:445–457`), which feeds the stored index/bit plane to
  `FixedCompositor` as if it were RGB/Gray. It's a test artefact; real exports composite through
  PCRender.

**Why the synthetic files fail.** `ps-oracle explain` attributes 175 of the 231 refusals to causes
proven with minimal variants; per test, see Appendix C. In order of size:

- **Blend mode invalid for the document's mode/depth:** 66 files (Screen at 32 bits, Darken in Lab,
  Darker Color in Gray). This is the PCIO writer (BM). It comes from the shared kitchen-sink test
  document, but the writer has no guard. No non-fuzz export puts Pass Through on a layer.
- **`grdm` length not a multiple of 4:** 56 files (GM).
  - Proven with three opens: Photoshop's own block transplanted in opens; PCIO's block upgraded
    to v3 + `Smoo`, with or without smoothness 4096, is still refused; PCIO's unchanged v1 block
    plus 2 zero bytes opens.
  - All 12,949 layer blocks Photoshop wrote (ps-corpus + Unity) have 4-aligned lengths.
- **The 4-byte `selc` test fixture:** 47 files.
  - `TestSupport.swift:235`, `.unsupported(psdKey: "selc", raw: [0, 1, 0, 0])`; Photoshop's is
    84 bytes. Found by `ps-oracle bisect`.
  - It also shows that PCIO writes `.unsupported` raw blocks unchecked.
- **`Txt2` written by PCIO:** 12 files (TX). Bisect: the files open once `Txt2` is dropped.
- **Placeholder raw blocks preserved verbatim:** a fake `CAI `, an unreadable `Anno`, 6-byte
  `FMsk`. (A 2-byte `Patt` holding `01 02` is not a cause: Photoshop opened 6 exports carrying it.) These are test fixtures, but they show the general rule: a damaged copy of
  a block Photoshop parses makes the whole file unopenable.
- **Pattern data** written by PCIO: 40 files (PT). PCIO's `Patt` is refused even in a file with no
  layers, and a pattern-fill layer without its pattern data is refused too (two opens). The cause,
  found afterwards with PCPSD (AB-L-0258): PCIO stored each pattern's transparency in the user-mask
  array (slot 24); Photoshop keeps it in the sheet-mask array (slot 25) and never writes slot 24.
  PCPSD's `patternTransparencyInUserMask` flags all 40 refused files and none of the 2,064 opened.
- **Unexplained:** 12 files (`independentUnavailableLinkRetainsSeparatePreservedRecord` ×7, `lnk2`
  records; `textShapeSmartRawBlocksSurvive` ×1; `placedLayerBlocksKeepTheirKeys` ×2 and
  `vectorRenderedMaskNotDoubledOnShapes` ×2, first put down to their 2-byte `Patt`; 6 opened
  exports carry it too, and the C′ versions are still refused with no global block at all). Candidates for `ps-oracle bisect` (refused, never modal).

**The crashes (T1).** Three files crashed Photoshop: EXC_BAD_ACCESS, a null read under
`do javascript` → `app.open`, the same frames each time.

- `hostileTypeSizes…-95aa4129d8`
- `importedTypeLayersKeepTheirFullBounds…-026de9dd90`
- `postscriptFontNamesResolveToTheInstalledFamilyOnImport…-02e3cf61e4`

All three carry a `TySh` hand-built by PCIO's tests (`PSDTypeBoundsTests.swift:46–95` and
siblings). Its EngineData lacks every structure that all 478 type layers Photoshop opened carry:

- `DocumentResources`;
- `Rendered.Version`, `Shapes.WritingDirection`;
- per shape: `Lines`, `Procession`, `Cookie.Photoshop.Base`;
- `AntiAlias`, `UseFractionalGlyphWidths`;
- `ParagraphSheet.DefaultStyleSheet`;
- `FontSet[].FontType`.

PCIO writes a preserved `psdRaw` verbatim (`PSDExport.swift:1026–1028`), skipping the normaliser
that photocraft and PCIO's own `buildEngineData` apply. Evidence:

- **Offline:** the 474 opened type layers all have these structures; the crashers have none.
- **Two opens:** the crasher with a PCIO-generated `TySh` opens. The crasher's `TySh` with just
  the structural keys no longer crashes; it is refused instead, because its style data is still
  incomplete.

Not a cause: the missing `Txt2` (8 PCIO type-layer files without one opened).

The pre-screen now finds **28 of the 174 PCIO type-layer files (16 %)** in this class. The 25
that never crashed Photoshop were never opened.

## C′. PCIO exports after the fixes

PCIO's regenerated exports (`$PHOTOCRAFT_FIXTURES/pcio-exports`, snapshot of 1,333 files in
`ps-oracle/pcio-snapshot-c2`) were swept with every pre-screen, `testgen*` excluded:

```bash
ps-oracle prescreen --dry-run $PHOTOCRAFT_FIXTURES/ps-oracle/pcio-snapshot-c2   # 0 of 1,333 before the run; 5 with pre-screen 3
ps-oracle sweep $PHOTOCRAFT_FIXTURES/ps-oracle/pcio-snapshot-c2 --name pcio-c2 --no-layers
ps-oracle explain $PHOTOCRAFT_FIXTURES/ps-oracle/pcio-c2/pcio-c2.json $PHOTOCRAFT_FIXTURES/ps-oracle/pcio-snapshot-c2
```

The run was stopped once, at 988 of 1,313, by the TS modal (below). It was resumed with
`--resume` after pre-screen 3 was added.

| Source | Files | Opened | Refused | Never opened (pre-screened) | Crashed | Tree match | Composite exact (worst, levels) |
|---|---:|---:|---:|---:|---:|---:|---:|
| round trips of `ps-corpus` via `.pcraft` | 153 | 153 | 0 | 0 | 0 | 153 | 136 (255) |
| round trips of `ps-corpus` direct | 153 | 153 | 0 | 0 | 0 | 153 | 136 (255) |
| round trips of the Unity corpus via `.pcraft` | 36 | 36 | 0 | 0 | 0 | 36 | 36 |
| round trips of the Unity corpus direct | 36 | 36 | 0 | 0 | 0 | 36 | 36 |
| PCEngine command exports | 28 | 28 | 0 | 0 | 0 | 27 | 25 (32) |
| synthetic documents (PCIO unit tests) | 907 | 896 | 7 | 4 | 0 | 799 | 328 (416) |
| **all** | **1,313** | **1,302** | **7** | **4** | **0** | **1,204** | **697** |
| *C, before the fixes* | *1,335* | *1,074* | *231* | *29* | *3* | *1,006* | *665* |

**What the fixes changed.**
- Every `ps-corpus` file survives a round trip and opens: 306/306, against 300/306. The 6
  transparent 16/32-bit files that F1 blocked open and match the tree.
- Every round trip's tree matches (378/378). The 41 colour-overlay mismatches of C (B1, on
  PCPSD's reading side) are gone.
- The round trips' composites equal the old sweep's file for file, and the 6 newly opened files
  match exactly. The worst cases are the Photoshop-internal differences and the Indexed/Bitmap
  test-helper artefact described in §C.
- No refusal has a known cause any more (`explain`: 0 of 7).
  - BM, GM, the `selc` fixture, generated `Txt2`, PT and F1 are all gone.
  - The watched sets all open with a matching tree: `patternFillSurvives…InEveryMode` 24/24,
    `matteBlockPrecedesTheLayerInfo` 12/12, `transparent-{rgb-16,rgb-32,grayscale-16}` 6/6, and
    `incompleteEngineDataIsRebuiltOnExport` 2/2.
- **Transparent patterns in the sheet mask (slot 25) open at every depth.** The snapshot has 145
  transparent patterns, all in slot 25: 57 in `Patt` (8-bit documents), 56 in `Pat2` (16-bit) and
  32 in `Pat3` (32-bit). All the files that carry them opened with a matching tree:
  `layerBlocksAreFourByteAligned` 12/12 (PSD and PSB), `patternFillSurvives…` 24/24 and
  `vectorMaskedPatternFillSurvivesPSD` 4/4. The pattern samples themselves are 8-bit in every
  case: PCIO stores 8-bit pattern data even in `Pat3`. No export, and no Photoshop-written file
  here, has 32-bit pattern samples, so that case stays untested.

**The 7 refusals** ("open options are incorrect") are all in the class left unexplained in §C:
- `independentUnavailableLinkRetainsSeparatePreservedRecord` ×2 (`lnk2` records);
- `placedLayerBlocksKeepTheirKeys` ×2;
- `vectorRenderedMaskNotDoubledOnShapes` ×2;
- `textShapeSmartRawBlocksSurvive` ×1.

All are refusals; none raised a modal.

**Bisected afterwards** with PCIO's single-edit variants, written offline. An unedited rewrite of
each source is byte-identical, so every variant differs only by its edit. Variants were opened
lowest-risk first, stopping each family at the first that opened (`ps-oracle try-variants`;
`RefusalVariantTests`). Every family opened at its first variant. The same edit on the sibling
file opened too: 7 opens in all, no modal.

| Family (files) | Opening variant | What it proves |
|---|---|---|
| `placedLayerBlocksKeepTheirKeys` (2) | A1: the placed layer's record (#4) deleted | the refusal is in that record (`PlLd`/`SoLd` for uuid `5b0c0b42…` with no `lnk2` linked data). A2/A3, adding Photoshop's `liFD` item and `SoLd`, were not needed and would narrow it further |
| `vectorRenderedMaskNotDoubledOnShapes` (2) | B1: the shape layer's 0-byte `SoCo` and 8-byte version-0 `vmsk` dropped. Then, on one file: **B2** (Photoshop's 112-byte `SoCo` from `shape-rect.psd`, version-0 `vmsk` kept) **opens**, and B3 (empty `SoCo` kept, Photoshop's `vmsk`) is refused | **the 0-byte `SoCo`**; the 8-byte version-0 `vmsk` is tolerated |
| `textShapeSmartRawBlocksSurvive` (1) | C1: the stand-in `PlLd` (`01020304`) dropped from #41 | the 4-byte `PlLd`, exactly |
| `independentUnavailableLink…` (2) | D1: `liFD` restored at bytes 8–12 of both `lnk2` items | the `liFE` relabel of an embedded item, exactly |

All four are hand-built or damaged test fixtures, not PCIO writer output.

**Follow-ups to the tree mismatches.**
- **Path-less `vmsk`:** the tree check now treats a `vmsk` with no path records as no vector mask,
  as Photoshop does (`Facts.swift`). All 217 vector masks Photoshop wrote (ps-corpus + Unity)
  have path records.
- **Artboard reference:** new corpus file `artboard-blend.psd` (`corpus build --only
  artboard-blend`), made as specified:
  - RGB 8-bit, 300 × 200.
  - "Artboard 1" at (0,0)–(100,100), default settings, holding "Red" (Normal) under "Mul"
    (Multiply).
  - "Artboard 2" at (150,0)–(250,100), blend set to Normal (accepted), holding "Blue".
  - A Pass Through group "Group" outside them, holding "Gray".

  What Photoshop reports and writes:

  | Layer | `mode` | `layerKind` | `artboardEnabled` | record blend | `lsct` |
  |---|---|---|---|---|---|
  | Artboard 1 (default) | normal | 7 | true | `norm` | type 2, `norm` |
  | Artboard 2 (set Normal) | normal | 7 | true | `norm` | type 1, `norm` |
  | Group | passThrough | 7 | false | `norm` | type 1, `pass` |
  | Red, Mul, Blue, Gray | normal, multiply, normal, normal | 1 | false | — | — |
  | section ends | passThrough | 13 | false | `norm` | type 3 |

  **Photoshop's artboards are Normal by default**, so PCIO's Pass Through artboards are not what
  Photoshop writes.

  Two building notes:
  - The canvas of an artboard document is the bounding box of its content (Photoshop refits
    it), so "Gray" spans the bottom of the canvas to keep 300 × 200.
  - An artboard made from layers takes their bounds: the rect passed with `Mk artboardSection`, or
    a later `editArtboardEvent`, lands offset. So "Red" and "Blue" fill their artboards exactly.

**Never opened (4).** `hostileTypeSizes…-6639470508` was quarantined after the modal. The other
three are pre-screen 3 hits: `hostileTypeSizes…-7eca2591d2`, `…-e3a378b9c9` and
`textLayerRoundtripWithTySh-7f7ce94a65`.

**Tree mismatches (98 of the 1,302 opened).**
- **89:** an adjustment layer PCPSD reads that Photoshop reports as a pixel layer. The kinds are
  `hue2`, `vibA`, `clrL`, `nvrt`, `thrs`, `post`, `expA`, `blwh`, `selc`, `mixr`, `grdm` and
  `levl`. 59 come from tests whose files were refused before the fixes, so this is mostly
  newly visible rather than new. PCIO has this finding. It also
  confounds the synthetic composites: the worst (416 levels, Gray 32-bit kitchen-sink documents)
  are among these files.
- **6:** an artboard written as Pass Through reads back as Normal. The corpora have no artboard
  Photoshop wrote to compare against.
- **1:** `rasterLayerBlocksPreserved`: a 12-byte `vmsk` (no path) is not a vector mask to
  Photoshop.
- **1:** `editedAdjustmentRegeneratesBlockUneditedKeepsRaw`: 41 records against 42 written, and
  "General Photoshop error" on layer 42, as before the fixes.
- **1:** the type layer of `hostileTypeSizes…-08e3aaeee0` was rasterized (TS).

**The modal (TS, new class).** Row 988, `hostileTypeSizesWithoutPixelsImportWithoutAHugeRender-08e3aaeee0`
(one style run at 1e30 pt, identity transform), opened in 20.3 s with its type layer turned into an
empty pixel layer and no dialog. The next file, `…-6639470508` (`Double.greatestFiniteMagnitude` pt
and the same value on the transform's diagonal), opened, and its info and both composites were
written (20:33:36, 30 s in), but the call never returned. The operator found "Some of the type
layers in this document were rasterized because an error prevented them from being read." [OK]
up; the lead stopped the run, and the file is quarantined. So, despite `DialogModes.NO`, the
notice surfaced after the saves (at close or when the script ended), not during `app.open`.

Offline diagnosis (`TypeDiagTests`: `typeValueRanges`, `typeMetricEnvelopes`,
`typeSizeScreenCalibration`, `typeSizeHitsUnderPCPSD`):
- Both files pass PCPSD's `photoshopStructureGaps()` (no gaps). `compatibilityIssues()` is empty
  for `08e3` and flags only a `TySh` length of 4854 (not 4-aligned) for `6639`. That is not the
  cause: two other C′ files with a 4454-byte `TySh` opened and kept their type.
- Their fonts (`Inter-Regular`) are fonts Photoshop has opened in other PCIO files.
- What differs is the size. The 74 type layers Photoshop wrote (ps-corpus 10 files, Unity
  13 files) use run sizes of 10–130 pt and a transform scale (√|det|) of 0.47–1.36. All
  1,299 type layers Photoshop opened and kept as type (those 74 plus 1,225 written by PCIO) stay
  within 10–130 pt, an effective size (size × scale) of 5.5–123 pt, and transform components of at
  most 311. The two files have 1e30 pt and 1.8e308 pt.

**Pre-screen 3 (type sizes),** `TypeSizeScreen.swift`, in `admit()` and `prescreen`. A type layer
fails if:
- a transform component is non-finite or beyond ±300,000 (Photoshop's largest canvas side);
- a style-run or style-sheet FontSize is outside Photoshop's type-size range of 0.01–1,296 pt;
- or a run's effective size (FontSize × transform scale) is outside that range.

The reason recorded is "type size outside Photoshop's range (type-layer rasterize modal class)".

| Set | Files | Type layers | Hits |
|---|---:|---:|---:|
| ps-corpus + Unity corpus (Photoshop wrote them) | 189 | 74 | **0** |
| every file Photoshop opened and kept as type (both PCIO sweeps + corpora) | 2,201 | 1,299 | **0** |
| C′ snapshot | 1,333 | 618 | **5** |

The 5 C′ hits:
- `hostileTypeSizes…-08e3aaeee0` (1e30 pt): already opened, type rasterized.
- `hostileTypeSizes…-6639470508` (1.8e308): quarantined (the modal).
- `hostileTypeSizes…-7eca2591d2` (12 pt × scale 1100 = 13,200 pt): not opened.
- `hostileTypeSizes…-e3a378b9c9` (12 pt × scale 1e12): not opened.
- `textLayerRoundtripWithTySh-7f7ce94a65`, layer #41 (0 pt): not opened.

Only 1e30 and 1.8e308 are proven. The 1,296 pt, 0 pt and ±300,000 bounds are Photoshop's
documented limits, not measured here, and a transformed layer can legitimately exceed 1,296 pt
effective. The screen is therefore deliberately conservative: it would turn away such a file rather
than risk a modal.

## C″. PCIO exports, regenerated again

PCIO regenerated its exports after the adjustment-availability fixes. A snapshot of
`$PHOTOCRAFT_FIXTURES/pcio-exports` (1,501 files: PCIO's 1,473 plus 28 PCEngine command exports) was copied to
`ps-oracle/pcio-snapshot-c3` and swept with all four pre-screens, `testgen*` excluded:

```bash
ps-oracle prescreen --dry-run $PHOTOCRAFT_FIXTURES/ps-oracle/pcio-snapshot-c3   # 0 of 1,501 caught
ps-oracle sweep $PHOTOCRAFT_FIXTURES/ps-oracle/pcio-snapshot-c3 --name pcio-c3 --no-layers
```

| | Files | Opened | Refused | Pre-screened | Crashed | Tree match | Composite exact |
|---|---:|---:|---:|---:|---:|---:|---:|
| C″ | 1,481 | **1,475** (99.6 %) | 6 | 0 | 0 | 1,461 | 690 |
| C′ | 1,313 | 1,302 | 7 | 4 | 0 | 1,204 | 697 |

- **No modal, timeout or crash.** Photoshop was left with 0 documents.
- **The 6 refusals** are the four fixtures bisected in §C′, still in the exports:
  - `placedLayerBlocksKeepTheirKeys` ×2 (placed layer without linked data);
  - `vectorRenderedMaskNotDoubledOnShapes` ×2 (0-byte `SoCo` + 8-byte `vmsk`);
  - `textShapeSmartRawBlocksSurvive` ×1 (4-byte `PlLd`);
  - one `independentUnavailableLink…` (both `lnk2` items labelled `liFE`; its sibling, with `liFD`, opens).
- **Adjustment layers:** **0 come back as pixel layers apart from Color Lookups with a table.**
  - All 15 Color Lookup layers carrying a table (`clrL` 580–3,748 bytes, in 7 files) read as
    pixel layers: the known gap (Photoshop's table layers carry a colour profile PCIO doesn't
    write).
  - All 29 table-less Color Lookups (Photoshop's 24-byte block) stay adjustments.
  - C′ had 89 files with adjustment-as-pixel layers.
- **The other tree mismatches:** 6 artboards written as Pass Through read back as Normal. The new
  `artboard-blend.psd` shows Photoshop's artboards are Normal. Plus
  `editedAdjustmentRegeneratesBlockUneditedKeepsRaw` (41 of 42 records), as before.
- **Tests:** the new ones (`unofferedKindsWarnAndStillRoundTrip`,
  `generatedDocumentsHoldOnlyOfferedAdjustments`) all open. The hostile type-size, 0 pt type,
  path-less `vmsk` and unreadable-adjustment fixtures are no longer exported.

## C‴. PCIO exports after the writer follow-ups

PCIO regenerated its exports again after the C″ follow-ups (artboards written Normal, linked-file
kinds, sanitised kept blocks). A snapshot of `$PHOTOCRAFT_FIXTURES/pcio-exports` (1,544 files: PCIO's 1,516
plus 28 PCEngine) was copied to `ps-oracle/pcio-snapshot-c4` and swept with all four pre-screens
(dry run: 0 of 1,544 caught), `testgen*` excluded.

| | Files | Opened | Refused | Pre-screened | Crashed | Tree match | Composite exact |
|---|---:|---:|---:|---:|---:|---:|---:|
| C‴ | 1,524 | **1,524** (100 %) | 0 | 0 | 0 | 1,515 | 709 |
| C″ | 1,481 | 1,475 | 6 | 0 | 0 | 1,461 | 690 |

- **No refusal, modal, timeout or crash.** Photoshop was left with 0 documents.
  - The bisected fixtures are no longer exported.
  - The independent-link test and the new `mislabelledLinkedItemsGetTheirOwnKind` open (4/4,
    2/2).
- **Round trips:** every `ps-corpus` round trip opens with a matching tree: 310/310, including
  the two new corpus files, whose composites are exact. Unity: 72/72.
- **Artboards match** now that PCIO writes them Normal: `exportedArtboardIndices…` 2/2,
  `syntheticPSDRoundtripAllDepths` 3/3, and the new `artboardsAreWrittenAsPhotoshopWritesThem` and
  `photoshopArtboardsRoundTrip`.
  - The one artboard mismatch left is `pcengine-artboards-to-files.psd`. PCEngine wrote it at
    22:34, before PCIO's regeneration at 23:01, so it needs a PCEngine re-export.
- **Remaining tree mismatches:**
  - the 15 Color Lookups with a table in 7 files (known gap; the 29 without a table stay
    adjustments);
  - `editedAdjustmentRegeneratesBlockUneditedKeepsRaw`: its deliberately truncated Levels block,
    41 of 42 records, as before.
- **New:** `photoshopArtboardsRoundTrip` opens with a matching tree, but its merged image differs
  from Photoshop's composite in exactly the 55 × 55 Multiply square. The difference (12, 141, 225)
  is Normal minus Multiply of "Mul" over "Red", so the merged image draws "Mul" as Normal there.
  PCIO's direct re-export of the same file is exact, so this is likely the test's merged-image
  helper (as with Indexed/Bitmap in §C), not the writer.

**Color Lookup references with a table: not made yet.** These would be Photoshop-authored files
for PCIO's `clrL` diff. The bundled presets were copied read-only to `ps-presets/3DLUTs` in the
session scratch folder (AB-D-0130: the data stays there; it is not in the fixtures root). One probe
document (`ps-oracle lut-probe`, nothing saved) set a Color Lookup to `Candlelight.CUBE` by `lookupType` 3DLUT + `LUT3DFileName` +
`LUTFormat` + name + dither off. There was no dialog and no error. Photoshop's read-back holds
`lookupType` 3DLUT, `name`, `dither` false, `LUTFormat` CUBE, `dataOrder` rgbOrder (added by
Photoshop), `tableOrder` bgrOrder (added by Photoshop) and `LUT3DFileName`. It has **no
`LUT3DFileData` and no `profile`**: by this route the file name is recorded but no table is
loaded. Settled with the same document saved (`ps-measure/lut-probe/lut-probe-cube.psd` + `.tif`):
- its `clrL` is 24 bytes, Photoshop's table-less block;
- its composite equals Base over Background exactly (0 levels; `LUTProbeTests`).

The earlier route, passing `LUT3DFileData` from a script, was refused. **Color Lookup tables stay a
known gap**, unless the operator makes one by hand. The corpus items (`adj-colorLookup-cube`,
`-3dl`, `-look`, `-cube-16`) are written and refuse to save a layer without a table. They are not
built, and a full corpus build records them as not buildable.

## D. Structural fuzz fixtures (deferred)

The 20 `synthetic-testgenStructureSurvives-*` files are PCPSD's randomised structure tests, not
export-quality documents.

- Before the pre-screens existed, 9 were opened. All were refused ("open options are incorrect"),
  and one raised the modal "This file uses an unsupported blending mode. Substitute normal mode?"
  despite `DialogModes.NO`. The operator had to cancel it.
- The pre-screens now catch **18/20**: 12 put Pass Through on a pixel layer (the modal class) and
  6 use modes invalid for their depth.
- The 2 that pass were deliberately not opened: low value against the cost of another
  operator-facing dialog.
- `sweep` excludes `testgen*` unless given `--fuzz`.

## 5. Blend modes Photoshop allows

```bash
ps-oracle blend-table       # new 8×8 documents only, no file opened; → $PHOTOCRAFT_FIXTURES/ps-oracle/blend-table.json
```

For each colour mode and depth Photoshop allows, the probe creates a document with a pixel layer
and a group, and sets each of the 27 modes plus Pass Through on both through Action Manager.
Photoshop throws "The command “Set” is not currently available" for a mode it doesn't allow.

| Mode (key) | RGB 8 | RGB 16 | RGB 32 | Gray 8 | Gray 16 | Gray 32 | CMYK 8 | CMYK 16 | Lab 8 | Lab 16 |
|---|:---:|:---:|:---:|:---:|:---:|:---:|:---:|:---:|:---:|:---:|
| normal `norm`, dissolve `diss`, multiply `mul `, linearDodge `lddg` | ✓ | ✓ | ✓ | ✓ | ✓ | ✓ | ✓ | ✓ | ✓ | ✓ |
| darken `dark`, lighten `lite`, difference `diff`, subtract `fsub`, divide `fdiv` | ✓ | ✓ | ✓ | ✓ | ✓ | ✓ | ✓ | ✓ | – | – |
| colorBurn `idiv`, colorDodge `div `, exclusion `smud` | ✓ | ✓ | – | ✓ | ✓ | – | ✓ | ✓ | – | – |
| linearBurn `lbrn`, screen `scrn`, overlay `over`, softLight `sLit`, hardLight `hLit`, vividLight `vLit`, linearLight `lLit`, pinLight `pLit`, hardMix `hMix` | ✓ | ✓ | – | ✓ | ✓ | – | ✓ | ✓ | ✓ | ✓ |
| darkerColor `dkCl`, lighterColor `lgCl`, hue `hue `, saturation `sat `, color `colr`, luminosity `lum ` | ✓ | ✓ | ✓ | – | – | – | ✓ | ✓ | ✓ | ✓ |
| passThrough `pass` | groups only | groups only | groups only | groups only | groups only | groups only | groups only | groups only | groups only | groups only |

Bitmap, Indexed and Multichannel documents cannot hold layers ("The command “Make” is not currently
available"). Groups allow the same modes as layers, plus Pass Through.

What happens with a file outside the table:

- A layer mode outside its column: Photoshop refuses the file. All 64 such PCIO files that were
  opened were refused.
- Pass Through on a non-group record: a modal that blocks scripting until someone answers it.

Calibration: 0 false positives on ps-corpus (153, including Photoshop's own Lab, Gray and RGB-32
blend bands), the Unity corpus (36) and pcpsd-fixtures (151).

## 5b. Measurement batch M1 (function oracle for PCRender's fits)

```bash
ps-oracle measure m1        # → $PHOTOCRAFT_FIXTURES/ps-measure/M1: inputs/, psd/, tif/, manifest.json (76 jobs, ~3 min)
```

Photoshop only created documents or opened the PNG inputs ps-oracle wrote; no PSD was opened. All
76 jobs succeeded (no refusal, modal or crash), and Photoshop was left with 0 documents open.

- **Working space:** colour settings "North America General Purpose 2". Every job document is sRGB
  IEC61966-2.1. The PNG inputs open untagged and are assigned sRGB, which leaves pixel values
  unchanged.
- **Identity:** the 8-bit round trip is exact (0 differing samples). At 16 bits, values come back
  within ±2/65535 (Photoshop's 15-bit storage), so `tif/identity-rgb16.tif` is the effective 16-bit
  input. Modern Brightness/Contrast at 0/0 is an exact identity.
- **Satin:** 14 variants, each with a raw map (Fill 0 % over black, white Normal 100 % Satin).
  Every contour name resolved to Photoshop's preset; the stored curve points are recorded per job.
- **Dissolve:** deterministic, with the pattern anchored to the canvas.
  - Two identical builds are identical (100 %).
  - With the layer offset by (37, 53), the dots match the same canvas coordinates (100 %), not
    the layer-shifted positions (49.9 %, i.e. chance).
  - Coverage is 51.0 % at 50 % opacity.
- **Correction (found in M2): the `bc-*` jobs are not modern Brightness/Contrast.** Photoshop 27
  makes RGB 8/16-bit B/C layers in **Light mode** (`brightnessMode` = `brightnessModeLight`, layer
  name "Light 1"), which replaces Brightness with Exposure/Whites/Blacks/Highlights/Shadows and
  ignores `Brgh`. Every M1 B/C document stores `Brgh` 0: the 20 jobs are Light-mode Contrast
  −50/0/50/100 at Exposure 0, five times over, and the 16-bit job is an identity. §5c has the cause,
  the fix and the modern-mode measurements.

## 5c. Measurement batch M2 (PCRender phase 5)

```bash
ps-oracle measure m2 --probe   # the one-document B/C check: makes a layer, reads it back, saves nothing
ps-oracle measure m2           # → $PHOTOCRAFT_FIXTURES/ps-measure/M2: inputs/, psd/, tif/, manifest.json (102 jobs, ~4 min)
ps-oracle corpus build --only adj-brightnessContrast-b25c35
```

Photoshop only created documents or opened the PNG inputs ps-oracle wrote; no PSD was opened. All
102 jobs succeeded (no refusal, modal, timeout or crash), and Photoshop was left with 0 documents.
Working space as in M1: colour settings "North America General Purpose 2", job documents sRGB
IEC61966-2.1, 8-bit identity exact, 16-bit within ±2/65535.

**The Brightness bug (M1 and the corpus).**
- **Cause:** Photoshop 27.11's B/C descriptor has a mode, `brightnessMode`
  (`brightnessModeType`: `brightnessModeLegacy`, `brightnessModeModern`, `brightnessModeLight`).
  In RGB 8- and 16-bit documents a new B/C layer is made in Light mode. Light mode's controls are
  `brightnessExposure`, `brightnessWhites`, `brightnessBlacks`, `brightnessHighlights` and
  `brightnessShadows`, and it drops `Brgh` (stored 0) while keeping `Cntr`. The builders sent
  `Brgh`, `Cntr` and `useLegacy` false, with no mode.
- **Where it bit:** ps-corpus `adj-brightnessContrast` (Light, `Brgh` 0, Contrast 35) and
  `adj-stack-rgb-16` (the same), and every M1 B/C job. CMYK 8, Lab 8, Gray 16 and RGB 32 documents
  have no Light mode; the stacks there stored Brightness 25 correctly.
- **Fix:** `C.bcSettings(b, c, mode)` and `C.makeAdjustment` set `brightnessMode` =
  `brightnessModeModern` when the layer is made, then set Brightness and Contrast.
  - Confirmed with one created document, nothing saved: brightness 25, center (Contrast) 35,
    `brightnessModeModern`.
  - Every M2 B/C file stores the asked Brgh/Cntr and the Modern mode (the 0/0 job stores no
    mode key).
- **Standing assertion:** every adjustment the builders make is read back (`executeActionGet`, the
  layer's `adjustment`). If any asked-for value was not stored, the job fails ("did not store
  what was asked"). Keys that a document mode may legitimately lack (`brightnessMode`,
  `presetKind`) are exempt. The corpus stacks re-raise this failure rather than recording it as
  "unavailable".
- **New corpus file:** `adj-brightnessContrast-b25c35.psd`, laid out as `adj-brightnessContrast`
  with Modern Brightness 25 / Contrast 35, stored as asked (composite in `composites/`). The
  existing files are untouched: they remain Photoshop's ground truth for Light mode.
- **For readers:** `brightnessMode` must be honoured. A Light-mode layer is a different adjustment
  from modern B/C.
  - PCRender's phase-4 fit of the M1 data (ProPhoto, DNG-style hue-preserving curve) is a fit of
    Light-mode Contrast.
  - M2's `bcm-b0-c*` jobs give modern Contrast at the same amounts, for comparison.

**Jobs.**

| Group | Jobs | What |
|---|---:|---|
| Modern B/C | 24 | Brightness −150/−50/50/150 × Contrast −50/0/50/100; Brightness 0 × Contrast −50/−25/0/25/50/75/100; 50/50 at 16-bit |
| B/C pivot | 9 | Contrast 50 over flat greys 32…224 (each with the ramp strip), the lattice × 0.5, and the lattice with its left half black |
| Satin | 12 | Cone, Ring, Gaussian with Anti-aliased off; Linear at 30° and at sizes 7 and 15 (anti-aliased, as M1); each with its raw-map twin |
| Dissolve coverage | 23 | full-canvas red on white, opacity 1–99 %; Fill 50 %; a 50 %-grey mask; one 4096 × 64 canvas |
| Vibrance | 5 | ±25, ±75 at Saturation 0; 100 at 16-bit |
| Luminosity | 2 | 50 % opacity, both M1 permutations |
| Contour presets | 25 | Outer Glow (Precise, size 120, spread 0, range 100 %, jitter 0, white Normal 100 %) round a 256 × 256 Fill-0 % square on 640 × 640 black, for each of the 12 presets, Anti-aliased off and on, plus Linear at Range 50 % |

Every Satin, Outer Glow, Vibrance, B/C, blend and Dissolve job reads its settings back and fails if
they differ (none did). All but Outer Glow also record the read-back as `stored`.

**What the files say without fitting.**
- **The B/C pivot is not stored:** every B/C file stores `means` 127, whatever the input (flat 32
  to 224, half lattice, half-black lattice). Any image-adaptive pivot must be computed at render
  time.
- **Dissolve** (aggregate only):
  - Coverage per opacity (stored byte → coverage):

    | Opacity | 1 % (3) | 5 % (13) | 10 % (26) | 20 % (51) | 25 % (64) | 30 % (77) | 40 % (102) |
    |---|---|---|---|---|---|---|---|
    | Coverage | 1.49 % | 5.32 % | 10.70 % | 20.59 % | 25.92 % | 30.90 % | 40.47 % |

    | Opacity | 50 % (128) | 60 % (153) | 70 % (179) | 75 % (191) | 80 % (204) | 90 % (230) | 99 % (252) |
    |---|---|---|---|---|---|---|---|
    | Coverage | 51.00 % | 60.79 % | 70.87 % | 75.42 % | 80.32 % | 90.19 % | 98.69 % |

    The rest are in the manifest. Every composite is binary (red or white).
  - The opacity patterns are nested: o45 ⊂ o50 ⊂ o55 (every pixel that differs does so in that
    direction), i.e. one noise field thresholded by opacity.
  - Fill 50 % and the 50 %-grey mask (stored value 128) give the same coverage (50.98 %, 50.96 %)
    but patterns unrelated to Opacity 50 %'s (50 % equal, chance).
  - The 4096 × 64 canvas has no period up to 2048 columns (every shift about 50 % equal; per-512
    block coverage 50.6–51.3 %). Its first 512 columns equal the 512 × 512 job's top rows exactly,
    so the field is a fixed function of canvas position, independent of document size.
- **Contour presets:** composites only. The manifest names each preset and holds no curve. No
  contour curve was read from Photoshop or any file, and these jobs saved no PSD.

## 5d. Measurement batch M3 (Light-mode Brightness/Contrast)

```bash
ps-oracle measure m3    # → $PHOTOCRAFT_FIXTURES/ps-measure/M3: inputs/, psd/, tif/, manifest.json (32 jobs, ~1 min)
```

Photoshop only created documents or opened the PNG inputs ps-oracle wrote; no PSD was opened. All
32 jobs succeeded (no refusal, modal, timeout or crash), and Photoshop was left with 0 documents.
Working space as in M1/M2.

**The Light-mode descriptor** (`manifest.json` → `lightModeDescriptor`). It is the default B/C
layer of a new RGB 8-bit document; ranges were probed in one document that was not saved.

| Key (stringID / charID) | Type | Default | Range (beyond it: clamped silently, no error) |
|---|---|---:|---|
| `brightnessExposure` | double | 0 | −5 … +5 |
| `center` / `Cntr` (Contrast) | integer | 0 | −100 … +100 (modern mode allows −50 … +100) |
| `brightnessWhites` | integer | 0 | −100 … +100 |
| `brightnessBlacks` | integer | 0 | −100 … +100 |
| `brightnessHighlights` | integer | 0 | −100 … +100 |
| `brightnessShadows` | integer | 0 | −100 … +100 |
| `brightnessMode` | enum `brightnessModeType` | `brightnessModeLight` | `brightnessModeLegacy`, `brightnessModeModern`, `brightnessModeLight` |
| `useLegacy` | boolean | false | |

In the file (`CgEd`, descriptor version 16), Photoshop also writes `Vrsn` 1, `Brgh` 0, `means`
127, `Lab ` false and `Auto` false.

**Jobs.** Every job reads its layer back and fails unless the mode is Light and every control is
stored as asked; all matched, in the read-back and in the saved `CgEd`.

| Group | Jobs |
|---|---|
| default (all controls 0) | 1: an exact identity (0 differing samples) |
| Exposure | −5, −2.5, −1.25, 1.25, 2.5, 5 (ends, halves, quarters of the range); 1.25 at 16-bit |
| Whites, Blacks, Highlights, Shadows | ±50, ±100 each (16) |
| Contrast at Exposure 0 | −50, 50, 100 (M1's `bc-*` jobs were these settings) |
| combinations | Exposure 1.25 + Contrast 50; Highlights −50 + Shadows +50; Exposure 0.625, Whites 25, Blacks −25, Highlights −30, Shadows 30 |

## 6. Incidents

| When | What | Cause | Cost | What changed |
|---|---|---|---|---|
| 17:56 | Photoshop crashed opening `hostileTypeSizes…-95aa` | T1 | crash dialog for the operator | — |
| 17:56 | the next queued run's `tell application` **relaunched Photoshop** | AppleScript launches a target that isn't running | none, luckily (no prompt) | ps-oracle never talks to a Photoshop that isn't running (kernel process list) |
| 18:04 | crashed on `importedTypeLayers…-026de` | T1 | crash dialog + manual relaunch | quarantine; the run stops on a crash; stale-lock handling |
| 18:21 | crashed on `postscriptFontNames…-02e3` | T1 | crash dialog + manual relaunch | **offline EngineData pre-screen** before every open |
| ~18:30 | modal "unsupported blending mode" on `testgen…-1e1567f7a7`, then on each next fuzz file | Pass Through on a pixel layer | the operator cancelled repeatedly; the lead killed the run | **blend pre-screen**; any timeout or cancelled-open stops the run; `testgen` excluded |
| 18:38 | sweep stopped with "Photoshop not running" while it was running | `NSRunningApplication` is stale in a CLI | none (stopped safely) | libproc-based check |
| 20:33 | C′: modal "Some of the type layers in this document were rasterized…" on `hostileTypeSizes…-6639470508`, after its composites were saved | type size 1.8e308 pt (TS) | the operator clicked OK; the lead stopped the run | quarantine; **type-size pre-screen 3** |

## 7. PCRender composite oracle — deferred

Not run: PCIO isn't finished (its PORT-NOTES still has a `@@LEFT@@` marker; PORT-STATUS says "in
progress"). For the follow-up:

- Use `composites/<name>.tif` as the reference, not the stored merged image (§A), read with
  `PSOracleKit.ReferenceImageReader`.
- PCIO's `PSDCompositeOracle.oracleCase(contentsOf:)` can feed `PSDOracleHook.loader`.
- PCIO's own "109/148" run used the first corpus build, whose blend files were empty: re-run it.

## 8. What could not be scripted

- **Duotone** (above).
- **Color Lookup with a LUT:** `LUT3DFileData` is refused, so the corpus has a Color Lookup layer
  without one.
- **Pattern definition:** never done, to leave the preset library untouched. The existing preset
  "Tree Tile 4" is used read-only.
- **Collapsed groups.**
- **Photoshop's own warnings on open:** invisible with dialogs off. The tree comparison catches
  their effect.
- **Open Recent:** every file opened is added to Photoshop's *Open Recent* list. Only files under
  the data root were opened.

Photoshop was left running with 0 documents open. No preference, colour setting or preset was
changed.

## Protocol (for a skill)

**Setup.**
- `swift build --product ps-oracle` from the repository root; the binary is `.build/debug/ps-oracle`.
- The operator starts Photoshop by hand. ps-oracle never launches it.
- Every command takes the lock (`ps-oracle.lock` in the data root), and the kernel releases it if the
  holder dies.
- Every Photoshop run preflights: Photoshop must be running, answering, and have 0 documents open.

**Before opening any file: four offline pre-screens**, run inside `admit()` for `info`,
`composite`, `accept`, `sweep` and `bisect` (or by hand with `ps-oracle prescreen <dir> [--dry-run]`).

1. **EngineData (crash class).** Every type layer's `TySh` must pass PCPSD's
   `PSDTypeTool.photoshopStructureGaps()`. A failure quarantines the file as "incomplete EngineData
   (known Photoshop crash class)".
2. **Blend modes (modal class).** Every record's blend key must be in the measured table for the
   document's mode and depth. Pass Through is allowed only on groups, and Bitmap, Indexed and
   Multichannel documents may not have layers. A failure quarantines the file as "blend mode
   invalid for document mode/depth (modal)".
3. **Type sizes (rasterize-modal class).** Every type layer's transform components must be finite
   and within ±300,000. Its run and style-sheet FontSizes, and each run's size × transform scale,
   must be within 0.01–1,296 pt (`TypeSizeScreen`). A failure quarantines the file as "type size
   outside Photoshop's range (type-layer rasterize modal class)".
4. **PCPSD linter, proven refusal classes.** `compatibilityIssues()` must not report any of:
   - `patternTransparencyInUserMask` (pattern transparency in the user-mask array, slot 24;
     AB-L-0258);
   - `placedLayerWithoutLinkedData`, `placedLayerDataUnreadable` or `linkedFileKindMismatch` (the
     causes the C′ bisect proved).

   The warning-level `fillLayerDataUnreadable` and `vectorMaskWithoutPaths` are not screened. On
   the C″ snapshot the dry run now catches exactly the 4 refused files those three errors cover
   (both `placedLayerBlocksKeepTheirKeys`, `textShapeSmartRawBlocksSurvive`, and the `liFE`
   `independentUnavailableLink…`). It catches 0 in ps-corpus (155), Unity and pcpsd-fixtures.
   `patternTransparencyInUserMask` flags 0 of the 189 Photoshop-written files, 40 of the old PCIO
   snapshot (the 40 refused for pattern data), and 0 of the C′ snapshot and of the regenerated
   builder fixtures (`LinterScreen`).

Without a measured table, `admit()` refuses to open anything. Regenerate the table with
`ps-oracle blend-table` after a Photoshop update; it creates documents only.

**Quarantine.** `$PHOTOCRAFT_FIXTURES/ps-oracle/quarantine.json` matches files by name and SHA-256. A crash,
timeout or modal adds the file automatically. Quarantined files are never opened unless the run is
given `--allow-quarantined "<hypothesis>"`, which is logged. `ps-oracle quarantine` lists the
entries.

**Crash and modal policy: one strike.**
- **Crash** (`-609`/`-600`, or Photoshop gone): record the file, quarantine it, stop.
- **Any script timeout** (a modal may be up): quarantine the file and stop. No ping or other
  script is sent into a possibly open dialog.
- **A cancelled-open error** (8007 or "cancel") means a modal was shown and dismissed: quarantine
  and stop.
- Never go on to the next file, and never relaunch. Report, and resume with `--resume` once the
  operator confirms Photoshop is clear.

**Runs.**

- PSDs the port wrote:
  `sweep <dir> --name <run>` (add `--no-layers` for big sets; `--exclude a,b`; `--fuzz` for
  `testgen*`).
- Photoshop-authored references:
  `corpus build` then `corpus read`.
- Single files:
  `info <file>` and `composite <file> <out.tif>`.
- Refusals:
  `explain <run.json> <dir>` (offline, proven causes), then `bisect <file>` for what remains;
  bisect only refused files, never crashing ones.

**Diagnosing a new crash.** Work offline first:
- `structure`, PCPSD's linter, and the `TypeDiagTests`/`DebugTests` key-set diffs against blocks
  Photoshop wrote.
- Then two or three minimal variants (known-good block swapped in, field fixed, block dropped),
  each opened once, lowest risk first. Stop at the first crash.

## Appendix A: PCPSD fixtures, per file

| File | Opens | Tree match | Composite vs PCPSD merged: max / mean (levels) | Layers vs PCPSD (worst, levels) |
|---|---|---|---|---|
| builder-CMYK-16-psb-RLE-opaque.psb | yes | yes | 232.53 / 111.73 | 0.012 |
| builder-CMYK-16-psb-Raw-opaque.psb | yes | yes | 232.53 / 111.73 | 0.012 |
| builder-CMYK-16-psb-ZIP-opaque.psb | yes | yes | 232.53 / 111.73 | 0.012 |
| builder-CMYK-16-psb-ZIPpprediction-opaque.psb | yes | yes | 232.53 / 111.73 | 0.012 |
| builder-CMYK-16-psd-RLE-opaque.psd | yes | yes | 232.53 / 111.73 | 0.012 |
| builder-CMYK-16-psd-Raw-opaque.psd | yes | yes | 232.53 / 111.73 | 0.012 |
| builder-CMYK-16-psd-ZIP-opaque.psd | yes | yes | 232.53 / 111.73 | 0.012 |
| builder-CMYK-16-psd-ZIPpprediction-opaque.psd | yes | yes | 232.53 / 111.73 | 0.012 |
| builder-CMYK-8-psb-RLE-opaque.psb | yes | yes | 232 / 111.73 | 0 |
| builder-CMYK-8-psb-Raw-opaque.psb | yes | yes | 232 / 111.73 | 0 |
| builder-CMYK-8-psb-ZIP-opaque.psb | yes | yes | 232 / 111.73 | 0 |
| builder-CMYK-8-psb-ZIPpprediction-opaque.psb | yes | yes | 232 / 111.73 | 0 |
| builder-CMYK-8-psd-RLE-opaque.psd | yes | yes | 232 / 111.73 | 0 |
| builder-CMYK-8-psd-Raw-opaque.psd | yes | yes | 232 / 111.73 | 0 |
| builder-CMYK-8-psd-ZIP-opaque.psd | yes | yes | 232 / 111.73 | 0 |
| builder-CMYK-8-psd-ZIPpprediction-opaque.psd | yes | yes | 232 / 111.73 | 0 |
| builder-Grayscale-16-psb-RLE-opaque.psb | yes | yes | 168 / 111.73 | 0.008 |
| builder-Grayscale-16-psb-RLE-partial.psb | **no** — “Cannot open the file because the open options are incorrect” | – | – | – |
| builder-Grayscale-16-psb-Raw-opaque.psb | yes | yes | 168 / 111.73 | 0.008 |
| builder-Grayscale-16-psb-Raw-partial.psb | **no** — “Cannot open the file because the open options are incorrect” | – | – | – |
| builder-Grayscale-16-psb-ZIP-opaque.psb | yes | yes | 168 / 111.73 | 0.008 |
| builder-Grayscale-16-psb-ZIP-partial.psb | **no** — “Cannot open the file because the open options are incorrect” | – | – | – |
| builder-Grayscale-16-psb-ZIPpprediction-opaque.psb | yes | yes | 168 / 111.73 | 0.008 |
| builder-Grayscale-16-psb-ZIPpprediction-partial.psb | **no** — “Cannot open the file because the open options are incorrect” | – | – | – |
| builder-Grayscale-16-psd-RLE-opaque.psd | yes | yes | 168 / 111.73 | 0.008 |
| builder-Grayscale-16-psd-RLE-partial.psd | **no** — “Cannot open the file because the open options are incorrect” | – | – | – |
| builder-Grayscale-16-psd-Raw-opaque.psd | yes | yes | 168 / 111.73 | 0.008 |
| builder-Grayscale-16-psd-Raw-partial.psd | **no** — “Cannot open the file because the open options are incorrect” | – | – | – |
| builder-Grayscale-16-psd-ZIP-opaque.psd | yes | yes | 168 / 111.73 | 0.008 |
| builder-Grayscale-16-psd-ZIP-partial.psd | **no** — “Cannot open the file because the open options are incorrect” | – | – | – |
| builder-Grayscale-16-psd-ZIPpprediction-opaque.psd | yes | yes | 168 / 111.73 | 0.008 |
| builder-Grayscale-16-psd-ZIPpprediction-partial.psd | **no** — “Cannot open the file because the open options are incorrect” | – | – | – |
| builder-Grayscale-32-psb-RLE-opaque.psb | yes | yes | 168.00 / 111.73 | 0.000 |
| builder-Grayscale-32-psb-RLE-partial.psb | **no** — “Cannot open the file because the open options are incorrect” | – | – | – |
| builder-Grayscale-32-psb-Raw-opaque.psb | yes | yes | 168.00 / 111.73 | 0.000 |
| builder-Grayscale-32-psb-Raw-partial.psb | **no** — “Cannot open the file because the open options are incorrect” | – | – | – |
| builder-Grayscale-32-psb-ZIP-opaque.psb | yes | yes | 168.00 / 111.73 | 0.000 |
| builder-Grayscale-32-psb-ZIP-partial.psb | **no** — “Cannot open the file because the open options are incorrect” | – | – | – |
| builder-Grayscale-32-psb-ZIPpprediction-opaque.psb | yes | yes | 168.00 / 111.73 | 0.000 |
| builder-Grayscale-32-psb-ZIPpprediction-partial.psb | **no** — “Cannot open the file because the open options are incorrect” | – | – | – |
| builder-Grayscale-32-psd-RLE-opaque.psd | yes | yes | 168.00 / 111.73 | 0.000 |
| builder-Grayscale-32-psd-RLE-partial.psd | **no** — “Cannot open the file because the open options are incorrect” | – | – | – |
| builder-Grayscale-32-psd-Raw-opaque.psd | yes | yes | 168.00 / 111.73 | 0.000 |
| builder-Grayscale-32-psd-Raw-partial.psd | **no** — “Cannot open the file because the open options are incorrect” | – | – | – |
| builder-Grayscale-32-psd-ZIP-opaque.psd | yes | yes | 168.00 / 111.73 | 0.000 |
| builder-Grayscale-32-psd-ZIP-partial.psd | **no** — “Cannot open the file because the open options are incorrect” | – | – | – |
| builder-Grayscale-32-psd-ZIPpprediction-opaque.psd | yes | yes | 168.00 / 111.73 | 0.000 |
| builder-Grayscale-32-psd-ZIPpprediction-partial.psd | **no** — “Cannot open the file because the open options are incorrect” | – | – | – |
| builder-Grayscale-8-psb-RLE-opaque.psb | yes | yes | 168 / 111.73 | 0 |
| builder-Grayscale-8-psb-RLE-partial.psb | yes | yes | 168 / 109.11 | 0 |
| builder-Grayscale-8-psb-Raw-opaque.psb | yes | yes | 168 / 111.73 | 0 |
| builder-Grayscale-8-psb-Raw-partial.psb | yes | yes | 168 / 109.11 | 0 |
| builder-Grayscale-8-psb-ZIP-opaque.psb | yes | yes | 168 / 111.73 | 0 |
| builder-Grayscale-8-psb-ZIP-partial.psb | yes | yes | 168 / 109.11 | 0 |
| builder-Grayscale-8-psb-ZIPpprediction-opaque.psb | yes | yes | 168 / 111.73 | 0 |
| builder-Grayscale-8-psb-ZIPpprediction-partial.psb | yes | yes | 168 / 109.11 | 0 |
| builder-Grayscale-8-psd-RLE-opaque.psd | yes | yes | 168 / 111.73 | 0 |
| builder-Grayscale-8-psd-RLE-partial.psd | yes | yes | 168 / 109.11 | 0 |
| builder-Grayscale-8-psd-Raw-opaque.psd | yes | yes | 168 / 111.73 | 0 |
| builder-Grayscale-8-psd-Raw-partial.psd | yes | yes | 168 / 109.11 | 0 |
| builder-Grayscale-8-psd-ZIP-opaque.psd | yes | yes | 168 / 111.73 | 0 |
| builder-Grayscale-8-psd-ZIP-partial.psd | yes | yes | 168 / 109.11 | 0 |
| builder-Grayscale-8-psd-ZIPpprediction-opaque.psd | yes | yes | 168 / 111.73 | 0 |
| builder-Grayscale-8-psd-ZIPpprediction-partial.psd | yes | yes | 168 / 109.11 | 0 |
| builder-Lab-16-psb-RLE-opaque.psb | yes | yes | 229.61 / 113.73 | 0.008 |
| builder-Lab-16-psb-Raw-opaque.psb | yes | yes | 229.61 / 113.73 | 0.008 |
| builder-Lab-16-psb-ZIP-opaque.psb | yes | yes | 229.61 / 113.73 | 0.008 |
| builder-Lab-16-psb-ZIPpprediction-opaque.psb | yes | yes | 229.61 / 113.73 | 0.008 |
| builder-Lab-16-psd-RLE-opaque.psd | yes | yes | 229.61 / 113.73 | 0.008 |
| builder-Lab-16-psd-Raw-opaque.psd | yes | yes | 229.61 / 113.73 | 0.008 |
| builder-Lab-16-psd-ZIP-opaque.psd | yes | yes | 229.61 / 113.73 | 0.008 |
| builder-Lab-16-psd-ZIPpprediction-opaque.psd | yes | yes | 229.61 / 113.73 | 0.008 |
| builder-Lab-8-psb-RLE-opaque.psb | yes | yes | 229 / 113.73 | 0 |
| builder-Lab-8-psb-Raw-opaque.psb | yes | yes | 229 / 113.73 | 0 |
| builder-Lab-8-psb-ZIP-opaque.psb | yes | yes | 229 / 113.73 | 0 |
| builder-Lab-8-psb-ZIPpprediction-opaque.psb | yes | yes | 229 / 113.73 | 0 |
| builder-Lab-8-psd-RLE-opaque.psd | yes | yes | 229 / 113.73 | 0 |
| builder-Lab-8-psd-Raw-opaque.psd | yes | yes | 229 / 113.73 | 0 |
| builder-Lab-8-psd-ZIP-opaque.psd | yes | yes | 229 / 113.73 | 0 |
| builder-Lab-8-psd-ZIPpprediction-opaque.psd | yes | yes | 229 / 113.73 | 0 |
| builder-RGB-16-psb-RLE-opaque.psb | yes | yes | 168 / 113.35 | 0.012 |
| builder-RGB-16-psb-RLE-partial.psb | **no** — “Cannot open the file because the open options are incorrect” | – | – | – |
| builder-RGB-16-psb-Raw-opaque.psb | yes | yes | 168 / 113.35 | 0.012 |
| builder-RGB-16-psb-Raw-partial.psb | **no** — “Cannot open the file because the open options are incorrect” | – | – | – |
| builder-RGB-16-psb-ZIP-opaque.psb | yes | yes | 168 / 113.35 | 0.012 |
| builder-RGB-16-psb-ZIP-partial.psb | **no** — “Cannot open the file because the open options are incorrect” | – | – | – |
| builder-RGB-16-psb-ZIPpprediction-opaque.psb | yes | yes | 168 / 113.35 | 0.012 |
| builder-RGB-16-psb-ZIPpprediction-partial.psb | **no** — “Cannot open the file because the open options are incorrect” | – | – | – |
| builder-RGB-16-psd-RLE-opaque.psd | yes | yes | 168 / 113.35 | 0.012 |
| builder-RGB-16-psd-RLE-partial.psd | **no** — “Cannot open the file because the open options are incorrect” | – | – | – |
| builder-RGB-16-psd-Raw-opaque.psd | yes | yes | 168 / 113.35 | 0.012 |
| builder-RGB-16-psd-Raw-partial.psd | **no** — “Cannot open the file because the open options are incorrect” | – | – | – |
| builder-RGB-16-psd-ZIP-opaque.psd | yes | yes | 168 / 113.35 | 0.012 |
| builder-RGB-16-psd-ZIP-partial.psd | **no** — “Cannot open the file because the open options are incorrect” | – | – | – |
| builder-RGB-16-psd-ZIPpprediction-opaque.psd | yes | yes | 168 / 113.35 | 0.012 |
| builder-RGB-16-psd-ZIPpprediction-partial.psd | **no** — “Cannot open the file because the open options are incorrect” | – | – | – |
| builder-RGB-32-psb-RLE-opaque.psb | yes | yes | 168.00 / 113.36 | 0.000 |
| builder-RGB-32-psb-RLE-partial.psb | **no** — “Cannot open the file because the open options are incorrect” | – | – | – |
| builder-RGB-32-psb-Raw-opaque.psb | yes | yes | 168.00 / 113.36 | 0.000 |
| builder-RGB-32-psb-Raw-partial.psb | **no** — “Cannot open the file because the open options are incorrect” | – | – | – |
| builder-RGB-32-psb-ZIP-opaque.psb | yes | yes | 168.00 / 113.36 | 0.000 |
| builder-RGB-32-psb-ZIP-partial.psb | **no** — “Cannot open the file because the open options are incorrect” | – | – | – |
| builder-RGB-32-psb-ZIPpprediction-opaque.psb | yes | yes | 168.00 / 113.36 | 0.000 |
| builder-RGB-32-psb-ZIPpprediction-partial.psb | **no** — “Cannot open the file because the open options are incorrect” | – | – | – |
| builder-RGB-32-psd-RLE-opaque.psd | yes | yes | 168.00 / 113.36 | 0.000 |
| builder-RGB-32-psd-RLE-partial.psd | **no** — “Cannot open the file because the open options are incorrect” | – | – | – |
| builder-RGB-32-psd-Raw-opaque.psd | yes | yes | 168.00 / 113.36 | 0.000 |
| builder-RGB-32-psd-Raw-partial.psd | **no** — “Cannot open the file because the open options are incorrect” | – | – | – |
| builder-RGB-32-psd-ZIP-opaque.psd | yes | yes | 168.00 / 113.36 | 0.000 |
| builder-RGB-32-psd-ZIP-partial.psd | **no** — “Cannot open the file because the open options are incorrect” | – | – | – |
| builder-RGB-32-psd-ZIPpprediction-opaque.psd | yes | yes | 168.00 / 113.36 | 0.000 |
| builder-RGB-32-psd-ZIPpprediction-partial.psd | **no** — “Cannot open the file because the open options are incorrect” | – | – | – |
| builder-RGB-8-psb-RLE-opaque.psb | yes | yes | 168 / 113.35 | 0 |
| builder-RGB-8-psb-RLE-partial.psb | yes | yes | 169 / 110.71 | 0 |
| builder-RGB-8-psb-Raw-opaque.psb | yes | yes | 168 / 113.35 | 0 |
| builder-RGB-8-psb-Raw-partial.psb | yes | yes | 169 / 110.71 | 0 |
| builder-RGB-8-psb-ZIP-opaque.psb | yes | yes | 168 / 113.35 | 0 |
| builder-RGB-8-psb-ZIP-partial.psb | yes | yes | 169 / 110.71 | 0 |
| builder-RGB-8-psb-ZIPpprediction-opaque.psb | yes | yes | 168 / 113.35 | 0 |
| builder-RGB-8-psb-ZIPpprediction-partial.psb | yes | yes | 169 / 110.71 | 0 |
| builder-RGB-8-psd-RLE-opaque.psd | yes | yes | 168 / 113.35 | 0 |
| builder-RGB-8-psd-RLE-partial.psd | yes | yes | 169 / 110.71 | 0 |
| builder-RGB-8-psd-Raw-opaque.psd | yes | yes | 168 / 113.35 | 0 |
| builder-RGB-8-psd-Raw-partial.psd | yes | yes | 169 / 110.71 | 0 |
| builder-RGB-8-psd-ZIP-opaque.psd | yes | yes | 168 / 113.35 | 0 |
| builder-RGB-8-psd-ZIP-partial.psd | yes | yes | 169 / 110.71 | 0 |
| builder-RGB-8-psd-ZIPpprediction-opaque.psd | yes | yes | 168 / 113.35 | 0 |
| builder-RGB-8-psd-ZIPpprediction-partial.psd | yes | yes | 169 / 110.71 | 0 |
| imageio-cmyk8.psd | yes | yes | 0 / 0 | – |
| imageio-gray16.psd | yes | yes | 0.004 / 0.002 | – |
| imageio-gray8.psd | yes | yes | 0 / 0 | – |
| imageio-rgb16.psd | yes | yes | 0.004 / 0.002 | – |
| imageio-rgb8.psd | yes | yes | 0 / 0 | – |
| imageio-rgba16.psd | yes | yes | 255 / 54.04 | – (PCPSD cannot decode: decompression failed: corrupt deflate data) |
| imageio-rgba8.psd | yes | yes | 255 / 61.02 | – (PCPSD cannot decode: decompression failed: PackBits run overflows row) |
| imageio-rgbf32.psd | yes | yes | 255 / 167.57 | – (PCPSD cannot decode: decompression failed: corrupt deflate data) |
| merged-Bitmap-1.psd | yes | yes | 0 / 0 | – |
| merged-CMYK-16.psd | yes | yes | 0.004 / 0.002 | – |
| merged-CMYK-8.psd | yes | yes | 0 / 0 | – |
| merged-Duotone-8.psd | **no** — “Cannot open the file because the open options are incorrect” | – | – | – |
| merged-Grayscale-16.psd | yes | yes | 0.004 / 0.002 | – |
| merged-Grayscale-32.psd | **no** — “Cannot open the file because the open options are incorrect” | – | – | – |
| merged-Grayscale-8.psd | yes | yes | 0 / 0 | – |
| merged-Indexed-8.psd | yes | yes | 0 / 0 | – |
| merged-Lab-16.psd | yes | yes | 0.004 / 0.002 | – |
| merged-Lab-8.psd | yes | yes | 0 / 0 | – |
| merged-Multichannel-16.psd | yes | yes | 0.004 / 0.002 | – |
| merged-Multichannel-8.psd | yes | yes | 0 / 0 | – |
| merged-RGB-16.psd | yes | yes | 0.004 / 0.002 | – |
| merged-RGB-32.psd | **no** — “Cannot open the file because the open options are incorrect” | – | – | – |
| merged-RGB-8.psd | yes | yes | 0 / 0 | – |

## Appendix B: the Photoshop-authored corpus read by PCPSD, per file

| File | Features | Parse | Rewrite identical | Typed blocks | Tree vs Photoshop | Merged vs PS composite (max / mean levels) | Alpha | Notes |
|---|---|---|---|---|---|---|---|---|
| adj-blackAndWhite.psd | adjustment:blackAndWhite, mode:RGB, depth:8 | ok | yes | ok (11) | match | 0 / 0 | – |  |
| adj-brightnessContrast.psd | adjustment:brightnessContrast, mode:RGB, depth:8 | ok | yes | ok (11) | match | 0 / 0 | – |  |
| adj-channelMixer.psd | adjustment:channelMixer, mode:RGB, depth:8 | ok | yes | ok (11) | match | 0 / 0 | – |  |
| adj-colorBalance.psd | adjustment:colorBalance, mode:RGB, depth:8 | ok | yes | ok (11) | match | 0 / 0 | – |  |
| adj-colorLookup.psd | adjustment:colorLookup, mode:RGB, depth:8 | ok | yes | ok (11) | match | 0 / 0 | – |  |
| adj-curves.psd | adjustment:curves, mode:RGB, depth:8 | ok | yes | ok (11) | match | 0 / 0 | – |  |
| adj-exposure.psd | adjustment:exposure, mode:RGB, depth:8 | ok | yes | ok (11) | match | 0 / 0 | – |  |
| adj-gradientMap.psd | adjustment:gradientMap, mode:RGB, depth:8 | ok | yes | ok (11) | match | 1 / 0.001 | – |  |
| adj-hueSaturation.psd | adjustment:hueSaturation, mode:RGB, depth:8 | ok | yes | ok (11) | match | 0 / 0 | – |  |
| adj-invert.psd | adjustment:invert, mode:RGB, depth:8 | ok | yes | ok (11) | match | 0 / 0 | – |  |
| adj-levels.psd | adjustment:levels, mode:RGB, depth:8 | ok | yes | ok (11) | match | 0 / 0 | – |  |
| adj-photoFilter.psd | adjustment:photoFilter, mode:RGB, depth:8 | ok | yes | ok (11) | match | 0 / 0 | – |  |
| adj-posterize.psd | adjustment:posterize, mode:RGB, depth:8 | ok | yes | ok (11) | match | 0 / 0 | – |  |
| adj-selectiveColor.psd | adjustment:selectiveColor, mode:RGB, depth:8 | ok | yes | ok (11) | match | 0 / 0 | – |  |
| adj-stack-cmyk-8.psd | adjustment:stack, mode:CMYK, depth:8 | ok | yes | ok (34) | match | 13 / 0.002 | – |  |
| adj-stack-gray-16.psd | adjustment:stack, mode:Grayscale, depth:16 | ok | yes | ok (24) | match | 0.01 / 0.000 | – | linter: warning: layer info not padded to a multiple of 4 (psd-tools misreads following blocks) |
| adj-stack-lab-8.psd | adjustment:stack, mode:Lab, depth:8 | ok | yes | ok (30) | match | 0 / 0 | – |  |
| adj-stack-rgb-16.psd | adjustment:stack, mode:RGB, depth:16 | ok | yes | ok (40) | match | 194.21 / 0.030 | – | linter: warning: layer info not padded to a multiple of 4 (psd-tools misreads following blocks) |
| adj-stack-rgb-32.psd | adjustment:stack, mode:RGB, depth:32 | ok | yes | ok (30) | match | 0 / 0 | – | linter: warning: layer info not padded to a multiple of 4 (psd-tools misreads following blocks) |
| adj-threshold.psd | adjustment:threshold, mode:RGB, depth:8 | ok | yes | ok (11) | match | 0 / 0 | – |  |
| adj-vibrance.psd | adjustment:vibrance, mode:RGB, depth:8 | ok | yes | ok (11) | match | 0 / 0 | – |  |
| advanced-channels.psd | advanced:channels, brst | ok | yes | ok (11) | match | 0 / 0 | – |  |
| advanced-flags.psd | advanced:blendInterior, advanced:transparencyShapes, advanced:layerMaskAsGlobal, mask:raster, effect:innerGlow | ok | yes | ok (11) | **1 diff** | 0 / 0 | – | #2 effects: Photoshop colorOverlay,innerGlow vs PCPSD innerGlow |
| blend-bands-cmyk-8.psd | blend:all, mode:CMYK, depth:8 | ok | yes | ok (35) | match | 0 / 0 | – |  |
| blend-bands-grayscale-8.psd | blend:all, mode:Grayscale, depth:8 | ok | yes | ok (35) | match | 0 / 0 | – |  |
| blend-bands-lab-8.psd | blend:all, mode:Lab, depth:8 | ok | yes | ok (35) | match | 0 / 0 | – |  |
| blend-bands-rgb-16.psd | blend:all, mode:RGB, depth:16 | ok | yes | ok (35) | match | 0 / 0 | – | linter: warning: layer info not padded to a multiple of 4 (psd-tools misreads following blocks) |
| blend-bands-rgb-32.psd | blend:all, mode:RGB, depth:32 | ok | yes | ok (35) | match | 0 / 0 | – |  |
| blend-blendDivide.psd | blend:blendDivide, mode:RGB, depth:8 | ok | yes | ok (9) | match | 0 / 0 | – |  |
| blend-blendSubtraction.psd | blend:blendSubtraction, mode:RGB, depth:8 | ok | yes | ok (9) | match | 0 / 0 | – |  |
| blend-color.psd | blend:color, mode:RGB, depth:8 | ok | yes | ok (9) | match | 0 / 0 | – |  |
| blend-colorBurn.psd | blend:colorBurn, mode:RGB, depth:8 | ok | yes | ok (9) | match | 0 / 0 | – |  |
| blend-colorDodge.psd | blend:colorDodge, mode:RGB, depth:8 | ok | yes | ok (9) | match | 0 / 0 | – |  |
| blend-darken.psd | blend:darken, mode:RGB, depth:8 | ok | yes | ok (9) | match | 0 / 0 | – |  |
| blend-darkerColor.psd | blend:darkerColor, mode:RGB, depth:8 | ok | yes | ok (9) | match | 0 / 0 | – |  |
| blend-difference.psd | blend:difference, mode:RGB, depth:8 | ok | yes | ok (9) | match | 0 / 0 | – |  |
| blend-dissolve.psd | blend:dissolve, mode:RGB, depth:8 | ok | yes | ok (9) | match | 0 / 0 | – |  |
| blend-exclusion.psd | blend:exclusion, mode:RGB, depth:8 | ok | yes | ok (9) | match | 0 / 0 | – |  |
| blend-hardLight.psd | blend:hardLight, mode:RGB, depth:8 | ok | yes | ok (9) | match | 0 / 0 | – |  |
| blend-hardMix.psd | blend:hardMix, mode:RGB, depth:8 | ok | yes | ok (9) | match | 0 / 0 | – |  |
| blend-hue.psd | blend:hue, mode:RGB, depth:8 | ok | yes | ok (9) | match | 0 / 0 | – |  |
| blend-lighten.psd | blend:lighten, mode:RGB, depth:8 | ok | yes | ok (9) | match | 0 / 0 | – |  |
| blend-lighterColor.psd | blend:lighterColor, mode:RGB, depth:8 | ok | yes | ok (9) | match | 0 / 0 | – |  |
| blend-linearBurn.psd | blend:linearBurn, mode:RGB, depth:8 | ok | yes | ok (9) | match | 0 / 0 | – |  |
| blend-linearDodge.psd | blend:linearDodge, mode:RGB, depth:8 | ok | yes | ok (9) | match | 0 / 0 | – |  |
| blend-linearLight.psd | blend:linearLight, mode:RGB, depth:8 | ok | yes | ok (9) | match | 0 / 0 | – |  |
| blend-luminosity.psd | blend:luminosity, mode:RGB, depth:8 | ok | yes | ok (9) | match | 0 / 0 | – |  |
| blend-multiply.psd | blend:multiply, mode:RGB, depth:8 | ok | yes | ok (9) | match | 0 / 0 | – |  |
| blend-normal.psd | blend:normal, mode:RGB, depth:8 | ok | yes | ok (9) | match | 0 / 0 | – |  |
| blend-overlay.psd | blend:overlay, mode:RGB, depth:8 | ok | yes | ok (9) | match | 0 / 0 | – |  |
| blend-pinLight.psd | blend:pinLight, mode:RGB, depth:8 | ok | yes | ok (9) | match | 0 / 0 | – |  |
| blend-saturation.psd | blend:saturation, mode:RGB, depth:8 | ok | yes | ok (9) | match | 0 / 0 | – |  |
| blend-screen.psd | blend:screen, mode:RGB, depth:8 | ok | yes | ok (9) | match | 0 / 0 | – |  |
| blend-softLight.psd | blend:softLight, mode:RGB, depth:8 | ok | yes | ok (9) | match | 0 / 0 | – |  |
| blend-vividLight.psd | blend:vividLight, mode:RGB, depth:8 | ok | yes | ok (9) | match | 0 / 0 | – |  |
| blendif-channels.psd | blend-if, blend-if:channels | ok | yes | ok (11) | match | 0 / 0 | – |  |
| blendif-gray.psd | blend-if, blend-if:gray, blend-if:split | ok | yes | ok (11) | match | 0 / 0 | – |  |
| channels-alpha-spot.psd | channel:alpha, channel:spot | ok | yes | ok (8) | match | 0 / 0 | – |  |
| channels-spot-cmyk.psd | channel:spot, mode:CMYK, depth:8 | ok | yes | ok (8) | match | 0 / 0 | – |  |
| clipping-adjustment.psd | clipping, adjustment:hue2 | ok | yes | ok (11) | match | 0 / 0 | – |  |
| clipping-basic.psd | clipping | ok | yes | ok (11) | match | 0 / 0 | – |  |
| clipping-blend-clipped-off.psd | clipping, advanced:blendClipped | ok | yes | ok (12) | match | 0 / 0 | – |  |
| combined-cmyk.psd | combined, mode:CMYK, depth:8, mask:raster, adjustment:levels, effect:dropShadow, text:point, group, clipping | ok | yes | **1 fail** | match | 0 / 0 | – | Txt2: re-serialised bytes differ (13147 bytes) |
| combined-kitchen-sink.psd | combined, group, group:pass-through, clipping, mask:raster, mask:vector, adjustment:curves, adjustment:hueSaturation, effect:dropShadow, effect:stroke, text:point, shape, smart-object:embedded, smart-filter:gaussianBlur, fill:gradient, blend:multiply, blend:overlay | ok | yes | **1 fail** | match | 0 / 0 | – | Txt2: re-serialised bytes differ (13168 bytes) |
| combined-rgb-16.psd | combined, mode:RGB, depth:16, mask:raster, adjustment:levels, effect:stroke, blend:softLight, clipping | ok | yes | ok (14) | match | 0 / 0 | – | linter: warning: layer info not padded to a multiple of 4 (psd-tools misreads following blocks) |
| combined-rgb-32.psd | combined, mode:RGB, depth:32, adjustment:exposure, smart-object:embedded, mask:raster | ok | yes | ok (16) | match | 0 / 0 | – | linter: warning: layer info not padded to a multiple of 4 (psd-tools misreads following blocks) |
| fill-gradient-angle.psd | fill:gradient, gradient:angle | ok | yes | ok (10) | match | 0 / 0 | – |  |
| fill-gradient-linear.psd | fill:gradient, gradient:linear, gradient:transparency | ok | yes | ok (10) | match | 0 / 0 | – |  |
| fill-gradient-radial.psd | fill:gradient, gradient:radial | ok | yes | ok (10) | match | 0 / 0 | – |  |
| fill-pattern.psd | fill:pattern | ok | yes | ok (10) | match | 0 / 0 | – |  |
| fill-solid-masked.psd | fill:solid, mask:raster | ok | yes | ok (10) | match | 0 / 0 | – |  |
| fill-solid.psd | fill:solid | ok | yes | ok (10) | match | 0 / 0 | – |  |
| fill-special-modes.psd | fill-opacity, blend:colorBurn, blend:linearDodge, blend:vividLight, blend:hardMix, blend:difference | ok | yes | ok (38) | match | 0 / 0 | – |  |
| fill-vs-opacity.psd | fill-opacity, opacity, effect:dropShadow, effect:stroke | ok | yes | ok (14) | match | 0 / 0 | – |  |
| fx-all.psd | effect:dropShadow, effect:innerShadow, effect:outerGlow, effect:innerGlow, effect:bevelEmboss, effect:satin, effect:colorOverlay, effect:gradientOverlay, effect:stroke | ok | yes | ok (11) | **1 diff** | 0 / 0 | – | #2 effects: Photoshop bevelEmboss,colorOverlay,dropShadow,gradientOverlay,innerGlow,innerShadow,outerGlow,satin,stroke vs PCPSD bevelEmboss,dropShadow,gradientOverlay,innerGlow,innerShadow,outerGlow,satin,stroke |
| fx-bevel-emboss.psd | effect:bevelEmboss | ok | yes | ok (11) | match | 0 / 0 | – |  |
| fx-cmyk.psd | effect:dropShadow, effect:outerGlow, effect:stroke, mode:CMYK, depth:8 | ok | yes | ok (11) | match | 0 / 0 | – |  |
| fx-color-overlay.psd | effect:colorOverlay | ok | yes | ok (11) | **1 diff** | 0 / 0 | – | #2 effects: Photoshop colorOverlay vs PCPSD  |
| fx-disabled.psd | effect:disabled, effect:stroke | ok | yes | ok (11) | match | 0 / 0 | – |  |
| fx-drop-shadow.psd | effect:dropShadow | ok | yes | ok (11) | match | 0 / 0 | – |  |
| fx-gradient-overlay.psd | effect:gradientOverlay | ok | yes | ok (11) | match | 0 / 0 | – |  |
| fx-group.psd | effect:on-group, effect:stroke, effect:dropShadow, group | ok | yes | ok (14) | match | 0 / 0 | – |  |
| fx-hidden.psd | effect:hidden-all | ok | yes | ok (11) | match | 0 / 0 | – |  |
| fx-inner-glow.psd | effect:innerGlow | ok | yes | ok (11) | match | 0 / 0 | – |  |
| fx-inner-shadow.psd | effect:innerShadow | ok | yes | ok (11) | match | 0 / 0 | – |  |
| fx-multi.psd | effect:multi, effect:dropShadow, effect:stroke, effect:colorOverlay | ok | yes | ok (11) | **1 diff** | 0 / 0 | – | #2 effects: Photoshop colorOverlay,dropShadow,dropShadow,stroke,stroke vs PCPSD dropShadow,dropShadow,stroke,stroke |
| fx-outer-glow.psd | effect:outerGlow | ok | yes | ok (11) | match | 0 / 0 | – |  |
| fx-pattern-overlay.psd | effect:patternOverlay | ok | yes | ok (11) | match | 0 / 0 | – |  |
| fx-rgb-16.psd | effect:dropShadow, effect:bevelEmboss, effect:gradientOverlay, mode:RGB, depth:16 | ok | yes | ok (11) | match | 0 / 0 | – | linter: warning: layer info not padded to a multiple of 4 (psd-tools misreads following blocks) |
| fx-satin.psd | effect:satin | ok | yes | ok (11) | match | 0 / 0 | – |  |
| fx-stroke.psd | effect:stroke | ok | yes | ok (11) | match | 0 / 0 | – |  |
| group-nested.psd | group, group:nested, group:pass-through, group:normal, group:hidden-child | ok | yes | ok (19) | match | 0 / 0 | – |  |
| group-normal.psd | group, group:normal | ok | yes | ok (14) | match | 0 / 0 | – |  |
| group-opacity.psd | group, group:normal, group:opacity | ok | yes | ok (14) | match | 0 / 0 | – |  |
| group-passthrough.psd | group, group:pass-through | ok | yes | ok (14) | match | 0 / 0 | – |  |
| hidden-and-locked.psd | visibility:hidden, lock:transparency, lock:all | ok | yes | ok (11) | match | 0 / 0 | – |  |
| knockout-deep.psd | knockout:deep, fill-opacity, group:nested | ok | yes | ok (17) | match | 0 / 0 | – |  |
| knockout-shallow.psd | knockout:shallow, fill-opacity, group | ok | yes | ok (14) | match | 0 / 0 | – |  |
| mask-both.psd | mask:raster, mask:vector | ok | yes | ok (11) | match | 0 / 0 | – |  |
| mask-density.psd | mask:raster, mask:density | ok | yes | ok (9) | match | 0 / 0 | – |  |
| mask-disabled.psd | mask:raster, mask:disabled | ok | yes | ok (9) | match | 0 / 0 | – |  |
| mask-feather.psd | mask:raster, mask:feather | ok | yes | ok (9) | match | 0 / 0 | – |  |
| mask-group.psd | mask:raster, group, mask:on-group | ok | yes | ok (11) | match | 0 / 0 | – |  |
| mask-raster.psd | mask:raster | ok | yes | ok (9) | match | 0 / 0 | – |  |
| mask-soft.psd | mask:raster, mask:gray-values | ok | yes | ok (9) | match | 0 / 0 | – |  |
| mask-vector-feather.psd | mask:vector, mask:density, mask:feather | ok | yes | ok (11) | match | 0 / 0 | – |  |
| mask-vector.psd | mask:vector | ok | yes | ok (11) | match | 0 / 0 | – |  |
| mode-bitmap-1.psd | mode:Bitmap, depth:1 | ok | yes | ok (6) | match | 0 / 0 | – |  |
| mode-cmyk-16.psd | mode:CMYK, depth:16, layers, partial-alpha-layer, blend:multiply, opacity | ok | yes | ok (12) | match | 0 / 0 | – | linter: warning: layer info not padded to a multiple of 4 (psd-tools misreads following blocks) |
| mode-cmyk-8.psd | mode:CMYK, depth:8, layers, partial-alpha-layer, blend:multiply, opacity | ok | yes | ok (12) | match | 0 / 0 | – |  |
| mode-gray-32-flat.psd | mode:Grayscale, depth:32, background-only | ok | yes | ok (6) | match | 0 / 0 | – |  |
| mode-grayscale-16.psd | mode:Grayscale, depth:16, layers, partial-alpha-layer, blend:multiply, opacity | ok | yes | ok (12) | match | 0 / 0 | – |  |
| mode-grayscale-32.psd | mode:Grayscale, depth:32, layers, partial-alpha-layer, blend:multiply, opacity | ok | yes | ok (12) | match | 0 / 0 | – | linter: warning: layer info not padded to a multiple of 4 (psd-tools misreads following blocks) |
| mode-grayscale-8.psd | mode:Grayscale, depth:8, layers, partial-alpha-layer, blend:multiply, opacity | ok | yes | ok (12) | match | 0 / 0 | – |  |
| mode-indexed-8-transparent.psd | mode:Indexed, depth:8, transparent-index | ok | yes | ok (6) | match | 0 / 0 | – |  |
| mode-indexed-8.psd | mode:Indexed, depth:8 | ok | yes | ok (6) | match | 0 / 0 | – |  |
| mode-lab-16.psd | mode:Lab, depth:16, layers, partial-alpha-layer, blend:multiply, opacity | ok | yes | ok (12) | match | 0.00 / 0.001 | – | linter: warning: layer info not padded to a multiple of 4 (psd-tools misreads following blocks) |
| mode-lab-8.psd | mode:Lab, depth:8, layers, partial-alpha-layer, blend:multiply, opacity | ok | yes | ok (12) | match | 0 / 0 | – |  |
| mode-multichannel-16.psd | mode:Multichannel, depth:16 | ok | yes | ok (6) | match | 0 / 0 | – |  |
| mode-multichannel-8.psd | mode:Multichannel, depth:8 | ok | yes | ok (6) | match | 0 / 0 | – |  |
| mode-rgb-16.psd | mode:RGB, depth:16, layers, partial-alpha-layer, blend:multiply, opacity | ok | yes | ok (12) | match | 0 / 0 | – | linter: warning: layer info not padded to a multiple of 4 (psd-tools misreads following blocks) |
| mode-rgb-32-flat.psd | mode:RGB, depth:32, background-only | ok | yes | ok (6) | match | 0 / 0 | – |  |
| mode-rgb-32.psd | mode:RGB, depth:32, layers, partial-alpha-layer, blend:multiply, opacity | ok | yes | ok (12) | match | 0 / 0 | – | linter: warning: layer info not padded to a multiple of 4 (psd-tools misreads following blocks) |
| mode-rgb-8-flat.psd | mode:RGB, depth:8, background-only | ok | yes | ok (6) | match | 0 / 0 | – |  |
| mode-rgb-8.psd | mode:RGB, depth:8, layers, partial-alpha-layer, blend:multiply, opacity | ok | yes | ok (12) | match | 0 / 0 | – |  |
| psb-cmyk-8.psb | format:psb, mode:CMYK, depth:8, layers | ok | yes | ok (9) | match | 0 / 0 | – |  |
| psb-rgb-16-adjust.psb | format:psb, mode:RGB, depth:16, adjustment:curves, adjustment:hueSaturation | ok | yes | ok (12) | match | 0 / 0 | – | linter: warning: layer info not padded to a multiple of 4 (psd-tools misreads following blocks) |
| psb-rgb-32.psb | format:psb, mode:RGB, depth:32, layers | ok | yes | ok (9) | match | 0.00 / 0.000 | – | linter: warning: layer info not padded to a multiple of 4 (psd-tools misreads following blocks) |
| psb-rgb-8-layers.psb | format:psb, mode:RGB, depth:8, layers, mask:raster, text:point, group | ok | yes | **1 fail** | match | 0 / 0 | – | Txt2: re-serialised bytes differ (13107 bytes) |
| psb-smart-filter.psb | format:psb, smart-object:embedded, smart-filter:gaussianBlur | ok | yes | ok (14) | match | 0 / 0 | – |  |
| shape-cmyk.psd | shape, mode:CMYK, depth:8 | ok | yes | ok (13) | match | 0 / 0 | – |  |
| shape-ellipse-gradient.psd | shape, shape:ellipse, shape:gradient-fill, live-shape | ok | yes | ok (13) | match | 0 / 0 | – |  |
| shape-rect.psd | shape, shape:rectangle, live-shape | ok | yes | ok (13) | match | 0 / 0 | – |  |
| shape-rounded-stroke.psd | shape, shape:rounded-rectangle, shape:stroke, live-shape | ok | yes | ok (14) | match | 0 / 0 | – |  |
| shape-stroke-only.psd | shape, shape:stroke, shape:no-fill, live-shape | ok | yes | ok (14) | match | 0 / 0 | – |  |
| smart-filter-blur.psd | smart-object:embedded, smart-filter:gaussianBlur, smart-filter:mask | ok | yes | ok (14) | match | 0 / 0 | – |  |
| smart-filter-emboss-16.psd | smart-object:embedded, smart-filter:emboss, mode:RGB, depth:16 | ok | yes | ok (14) | match | 0 / 0 | – |  |
| smart-filter-stack.psd | smart-object:embedded, smart-filter:unsharpMask, smart-filter:motionBlur, smart-filter:minimum, smart-filter:mask | ok | yes | ok (14) | match | 0 / 0 | – |  |
| smart-object-nested.psd | smart-object:embedded, smart-object:nested | ok | yes | ok (13) | match | 0 / 0 | – |  |
| smart-object-transformed.psd | smart-object:embedded, smart-object:transform | ok | yes | ok (13) | match | 0 / 0 | – |  |
| smart-object.psd | smart-object:embedded | ok | yes | ok (13) | match | 0 / 0 | – |  |
| text-cmyk.psd | text:point, mode:CMYK, depth:8 | ok | yes | **1 fail** | match | 0 / 0 | – | Txt2: re-serialised bytes differ (13157 bytes) |
| text-effects.psd | text:point, effect:stroke, effect:dropShadow | ok | yes | **1 fail** | match | 0 / 0 | – | Txt2: re-serialised bytes differ (13094 bytes) |
| text-paragraph.psd | text:paragraph | ok | yes | **1 fail** | match | 0 / 0 | – | Txt2: re-serialised bytes differ (16724 bytes) |
| text-point.psd | text:point | ok | yes | **1 fail** | match | 0 / 0 | – | Txt2: re-serialised bytes differ (13268 bytes) |
| text-styled.psd | text:point, text:styled-runs | ok | yes | **1 fail** | match | 0 / 0 | – | Txt2: re-serialised bytes differ (14903 bytes) |
| text-vertical.psd | text:point, text:vertical | ok | yes | **1 fail** | match | 0 / 0 | – | Txt2: re-serialised bytes differ (13011 bytes) |
| text-warp.psd | text:point, text:warp | ok | yes | **1 fail** | match | 0 / 0 | – | Txt2: re-serialised bytes differ (13249 bytes) |
| transparent-cmyk-8.psd | mode:CMYK, depth:8, no-background, merged-alpha, matte | ok | yes | ok (9) | match | 0 / 0 | 0 / 0 |  |
| transparent-grayscale-16.psd | mode:Grayscale, depth:16, no-background, merged-alpha, matte | ok | yes | ok (9) | match | 0 / 0 | 0 / 0 | linter: warning: layer info not padded to a multiple of 4 (psd-tools misreads following blocks) |
| transparent-rgb-16.psd | mode:RGB, depth:16, no-background, merged-alpha, matte | ok | yes | ok (9) | match | 0 / 0 | 0 / 0 | linter: warning: layer info not padded to a multiple of 4 (psd-tools misreads following blocks) |
| transparent-rgb-32.psd | mode:RGB, depth:32, no-background, merged-alpha, matte | ok | yes | ok (9) | match | 0 / 0 | 0 / 0 | linter: warning: layer info not padded to a multiple of 4 (psd-tools misreads following blocks) |
| transparent-rgb-8.psd | mode:RGB, depth:8, no-background, merged-alpha, matte | ok | yes | ok (9) | match | 0 / 0 | 0 / 0 |  |

## Appendix C: PCIO exports not opened, by source and cause

| Source (PCIO test, or round trip of a Photoshop file) | Not opened / files | Cause | Where |
|---|---:|---|---|
| gradientMapsWithCMYKLabGrayStopsImportAndKeepTheirSpace | 40/46 | grdm length not 4-aligned | PCIO `AdjustMap.swift:509` |
| emptyLayerAndMaskChannelsUseRawWithoutAPayload | 16/24 | 4-byte selc fixture, blend mode invalid for mode/depth | PCIO `PSDExport.swift:902/1370`; test fixture (`TestSupport.swift:235`) |
| emptyLayerAndMaskChannelsUseRawWithoutAPayload | 8/24 | 4-byte selc fixture | test fixture (`TestSupport.swift:235`) |
| patternFillSurvivesPSDAndLayeredTIFFInEveryMode | 24/24 | pattern transparency in the user-mask array, slot 24 (AB-L-0258) | PCIO PatternMap |
| rtCase | 12/26 | 4-byte selc fixture, blend mode invalid for mode/depth | PCIO `PSDExport.swift:902/1370`; test fixture (`TestSupport.swift:235`) |
| rtCase | 8/26 | 4-byte selc fixture | test fixture (`TestSupport.swift:235`) |
| rtCase | 2/26 | blend mode invalid for mode/depth | PCIO `PSDExport.swift:902/1370` |
| importedTypeLayersKeepTheirFullBounds | 15/16 | EngineData gaps (pre-screened, never opened) | PCIO `PSDExport.swift:1026` + test TySh |
| importedTypeLayersKeepTheirFullBounds | 1/16 | blend mode invalid for mode/depth (pre-screened, never opened) | PCIO `PSDExport.swift:902/1370` |
| psdICCRoundtripByteExact | 14/26 | blend mode invalid for mode/depth | PCIO `PSDExport.swift:902/1370` |
| exportOracle | 6/14 | 4-byte selc fixture, blend mode invalid for mode/depth | PCIO `PSDExport.swift:902/1370`; test fixture (`TestSupport.swift:235`) |
| exportOracle | 4/14 | 4-byte selc fixture | test fixture (`TestSupport.swift:235`) |
| exportOracle | 2/14 | blend mode invalid for mode/depth | PCIO `PSDExport.swift:902/1370` |
| layerBlocksAreFourByteAligned | 12/12 | pattern transparency in the user-mask array, slot 24 (AB-L-0258) | PCIO PatternMap |
| everyAdjustmentKindRoundTrips16bit | 8/56 | grdm length not 4-aligned | PCIO `AdjustMap.swift:509` |
| everyAdjustmentKindRoundTrips16bit | 2/56 | 4-byte selc fixture | test fixture (`TestSupport.swift:235`) |
| everyAdjustmentKindRoundTrips8bit | 8/56 | grdm length not 4-aligned | PCIO `AdjustMap.swift:509` |
| everyAdjustmentKindRoundTrips8bit | 2/56 | 4-byte selc fixture | test fixture (`TestSupport.swift:235`) |
| layered32BitExportLayout | 4/8 | 4-byte selc fixture, blend mode invalid for mode/depth | PCIO `PSDExport.swift:902/1370`; test fixture (`TestSupport.swift:235`) |
| layered32BitExportLayout | 4/8 | blend mode invalid for mode/depth | PCIO `PSDExport.swift:902/1370` |
| independentUnavailableLinkRetainsSeparatePreservedRecord | 7/14 | unexplained (lnk2 linked-file records); open | – |
| tiffAndPSDOpenAsTheSameDocument | 4/6 | 4-byte selc fixture | test fixture (`TestSupport.swift:235`) |
| tiffAndPSDOpenAsTheSameDocument | 2/6 | blend mode invalid for mode/depth (pre-screened, never opened) | PCIO `PSDExport.swift:902/1370` |
| hostileTypeSizesWithoutPixelsImportWithoutAHugeRender | 3/4 | EngineData gaps (pre-screened, never opened) | PCIO `PSDExport.swift:1026` + test TySh |
| hostileTypeSizesWithoutPixelsImportWithoutAHugeRender | 1/4 | blend mode invalid for mode/depth (pre-screened, never opened) | PCIO `PSDExport.swift:902/1370` |
| layered32BitExportReimportsRenderEqual | 4/4 | 4-byte selc fixture, blend mode invalid for mode/depth | PCIO `PSDExport.swift:902/1370`; test fixture (`TestSupport.swift:235`) |
| txt2ExtrasSurviveAResaveOfUnchangedText | 4/4 | PCIO-written Txt2 | PCIO `PSDTextWrite.buildTxt2` (:223) |
| vectorMaskedPatternFillSurvivesPSD | 4/4 | pattern transparency in the user-mask array, slot 24 (AB-L-0258) | PCIO PatternMap |
| duplicatePreservedTextIndicesGetDistinctTxt2Objects | 2/2 | PCIO-written Txt2 | PCIO `PSDTextWrite.buildTxt2` (:223) |
| freshMetricsTextWritesNoTxt2Block | 2/4 | PCIO-written Txt2 | PCIO `PSDTextWrite.buildTxt2` (:223) |
| globalBlocksArePaddedToFour | 2/2 | fake CAI fixture | test fixture |
| hostileTextIndexNeverSizesTheSave | 2/2 | PCIO-written Txt2 | PCIO `PSDTextWrite.buildTxt2` (:223) |
| opticalKerningRoundTripsThroughPSD | 2/2 | PCIO-written Txt2 | PCIO `PSDTextWrite.buildTxt2` (:223) |
| placedLayerBlocksKeepTheirKeys | 2/2 | unexplained: no pattern in the file; its 2-byte `Patt` (`01 02`) is ruled out (6 exports carrying it opened, and the C′ versions, with no global block at all, are still refused) | – |
| psdToPNGToPSDChain | 2/7 | 4-byte selc fixture | test fixture (`TestSupport.swift:235`) |
| resourcesAndGlobalBlocksSurviveASave | 2/2 | placeholder global block (FMsk 6 bytes; Photoshop writes 12); probable | test fixture |
| roundTripReachesAFixedPoint | 2/2 | 4-byte selc fixture | test fixture (`TestSupport.swift:235`) |
| stylesFromSheetsSurviveARoundTrip | 2/2 | EngineData gaps (pre-screened, never opened) | PCIO `PSDExport.swift:1026` + test TySh |
| typeLayersWithoutPixelsAreRenderedOnImport | 2/2 | EngineData gaps (pre-screened, never opened) | PCIO `PSDExport.swift:1026` + test TySh |
| unlinkedRunsKeepTheirInheritedStyleOnExport | 2/2 | EngineData gaps (pre-screened, never opened) | PCIO `PSDExport.swift:1026` + test TySh |
| vectorRenderedMaskNotDoubledOnShapes | 2/2 | unexplained: no pattern in the file; its 2-byte `Patt` (`01 02`) is ruled out (6 exports carrying it opened, and the C′ versions, with no global block at all, are still refused) | – |
| transparent-grayscale-16 (round trip) | 2/2 | F1 matte order (Lr16/Lr32 before Mt16/Mt32) | PCIO `PSDExport.swift:1582` |
| transparent-rgb-16 (round trip) | 2/2 | F1 matte order (Lr16/Lr32 before Mt16/Mt32) | PCIO `PSDExport.swift:1582` |
| transparent-rgb-32 (round trip) | 2/2 | F1 matte order (Lr16/Lr32 before Mt16/Mt32) | PCIO `PSDExport.swift:1582` |
| anUnreadableAnnoBlockWarnsAndSurvivesASave | 1/2 | unreadable Anno fixture (bisect: opens without Anno) | test fixture |
| documentToPSDDirectAPI | 1/1 | 4-byte selc fixture | test fixture (`TestSupport.swift:235`) |
| gradientAndPatternFillsRoundtrip | 1/1 | pattern fill without pattern data | PCIO PatternMap |
| postscriptFontNamesResolveToTheInstalledFamilyOnImport | 1/1 | EngineData gaps: CRASHED Photoshop | PCIO `PSDExport.swift:1026` + test TySh |
| psbRoundtrip | 1/1 | 4-byte selc fixture | test fixture (`TestSupport.swift:235`) |
| psdRawResourcesAndGlobalBlocksPreserved | 1/1 | placeholder global blocks: a 6-byte `Patt` (`07` × 6) that does not parse (PCPSD `patternDataUnreadable`) and a 2-byte `lnk2`; probable, not isolated | test fixture |
| textLayerRoundtripWithTySh | 1/1 | EngineData gaps (pre-screened, never opened) | PCIO `PSDExport.swift:1026` + test TySh |
| textShapeSmartRawBlocksSurvive | 1/1 | unexplained; open | – |
