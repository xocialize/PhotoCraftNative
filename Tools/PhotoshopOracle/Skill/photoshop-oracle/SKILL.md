---
name: photoshop-oracle
description: Safely use real Adobe Photoshop as the acceptance oracle for PSD/PSB files — does Photoshop open what our code wrote, does its layer tree and composite match, why did it refuse or crash. Covers the ps-oracle harness (research/MetalPlayground/PhotoCraftNative/Tools/PhotoshopOracle), the offline pre-screens that keep known crash/modal classes away from Photoshop, the one-strike crash/modal policy, the catalogue of measured Photoshop rejection causes, and how to diagnose a new one. Use it whenever a task involves opening files in Photoshop, scripting Photoshop (osascript, `do javascript`, ExtendScript, Action Manager), checking a PSD writer's output against Photoshop, generating Photoshop-authored test PSDs, comparing a compositor against Photoshop's composite, or reacting to a Photoshop crash report or "open options are incorrect" / "unsupported blending mode" dialog — even if the user only says "check it in Photoshop" or "why won't Photoshop open this".
---

# Photoshop oracle

Real Photoshop is the only trustworthy judge of whether a PSD we wrote is acceptable (photocraft's own
gap list says the same). It is also fragile under automation and shares the operator's screen: every
crash leaves Adobe's crash-report dialog and needs a manual relaunch, and every modal blocks until a
human clicks. One bad sweep on 2026-10-12 cost the operator three crash dialogs and a run of modals
they had to click through. So the whole approach is: **learn as much as possible offline, open as
little as possible, and stop at the first sign of trouble.**

The harness is `ps-oracle` in `research/MetalPlayground/PhotoCraftNative/Tools/PhotoshopOracle`
(README.md there for every command; RESULTS.md for the measured findings). It links PCPSD, so its
checks read files the same way our writer's tests do.

## Ground rules (the operator's machine, the operator's Photoshop)

- **Never launch Photoshop.** `osascript … tell application` would start it, and a launch can raise
  sign-in, licence, or crash-recovery prompts. Ask the operator to start it; check it's up.
- **Never sign in, accept terms, change preferences or colour settings, define presets, or install
  anything.** If an Adobe account/licence/terms prompt appears, stop and tell the operator.
- **Only open files under the data/tool roots** (the harness enforces `allowedRoots`; the data root is
  `PS_ORACLE_SCRATCH`, default the fixtures root `$PHOTOCRAFT_FIXTURES`). Never browse
  the operator's documents or Photoshop's recent-files list. Every open still lands in Photoshop's
  *Open Recent* list — mention that in your report; the operator can clear it (File ▸ Open Recent ▸
  Clear Recent File List). Don't clear it yourself (that's a preference).
- **One driver.** All Photoshop access goes through ps-oracle's `flock` (`$PHOTOCRAFT_FIXTURES/ps-oracle.lock`);
  a lock note naming a dead pid is stale and is taken over. If several agents are working, exactly one
  owns Photoshop; others hand it files (e.g. a drop folder) instead of scripting it.
- **Close every document with `DONOTSAVECHANGES`.** Leave Photoshop running with 0 documents open.

## Before any open: preflight + four offline pre-screens

Every command that opens a file (`info`, `composite`, `accept`, `sweep`, `bisect`) runs `admit()`:

1. **Preflight:** Photoshop running (checked via the kernel process list — `NSRunningApplication` goes
   stale in a CLI), answering a trivial script, **0 documents open**.
2. **Pre-screen #1 — EngineData (crash class).** Every type layer's `TySh` must pass PCPSD's
   `PSDTypeTool.photoshopStructureGaps()`. Missing any of nine structures crashes Photoshop on open;
   missing `FontSet[].FontType` makes it refuse. Failures are quarantined, never opened.
3. **Pre-screen #2 — blend modes (refusal/modal class).** Every record's blend key must be allowed for
   the document's mode and depth (measured table, `$PHOTOCRAFT_FIXTURES/ps-oracle/blend-table.json`; regenerate
   with `ps-oracle blend-table` after any Photoshop update — it only creates new documents). `pass`
   is valid only on groups; Bitmap/Indexed/Multichannel documents can't have layers.

4. **Pre-screen #3 — type sizes (rasterize-modal class).** A type layer whose run size, size ×
   transform scale, or transform components fall outside Photoshop's range (0.01–1,296 pt;
   ±300,000) is quarantined. Photoshop turns such layers into empty pixel layers and can raise a
   modal *after* the open, which `DialogModes.NO` doesn't stop.

5. **Pre-screen #4 — linter (`LinterScreen.rules`).** Listed PCPSD `compatibilityIssues()` rules
   whose files Photoshop is proven to refuse block the open (`patternTransparencyInUserMask` and the four smart-object/link rules; errors only).
   When a new cause is proven and linted, add its rule to that list, calibrated on Photoshop-written
   files first.

Run them by hand with `ps-oracle prescreen <dir|file>... [--skip-swept <report.json>]` (offline, no Photoshop). Calibrate any new pre-screen on
Photoshop-authored files first — it must have 0 false positives there, or it's wrong.

Keep fuzz/structure fixtures (`testgen*`) out of acceptance sweeps (`--fuzz` opts in, as its own
section): they test format structure, not Photoshop acceptance, and they trip modals.

## One-strike policy

- **Crash** (`-609` "Connection is invalid", `-600`, or Photoshop gone): record the file, quarantine
  it, **stop the run**.
- **Any script timeout:** a modal may be up. Quarantine the file and stop. Send *no* further scripts —
  not even a ping — into a possibly open dialog.
- **A cancelled-open error** (8007 / "cancel"): a modal was shown and dismissed. Quarantine and stop.
- Never advance to the next file after any of these, and never relaunch. Report to the operator, wait
  until they confirm Photoshop is clear, then `--resume`.

Why so strict: `app.displayDialogs = DialogModes.NO` does **not** suppress open-time modals ("This
file uses an unsupported blending mode…"), and a sweep that advances after a Cancel shows the operator
the same modal again for the next file, indefinitely.

Quarantine lives in `$PHOTOCRAFT_FIXTURES/ps-oracle/quarantine.json` (name + SHA-256). Re-opening a quarantined
file requires `--allow-quarantined "<hypothesis>"`, which is logged — only when testing a fix.

## Known Photoshop 27.11 rejection causes (measured)

Check new failures against these first; each has an offline detector in PCPSD's
`compatibilityIssues()` (run it on every export).

| Symptom | Cause | Detector / record |
|---|---|---|
| **Crash on open** (null deref, main thread) | type layer's EngineData lacks Photoshop's nine required structures (writer re-emitted a minimal/third-party `TySh` verbatim) | `typeLayerEngineDataCrashesPhotoshop`; bridge AB-L-0245 |
| Refused ("open options are incorrect") | EngineData lacks `FontSet[].FontType`/`Synthetic` or full style sheets | `typeLayerEngineDataBlocksPhotoshop`; AB-L-0245 |
| Refused | blend mode not allowed for the document's mode/depth (e.g. Screen in 32-bit, Darken in Lab, Darker Color in Gray) | `blendModeInvalidForDocument`; AB-L-0250 |
| **Modal** "unsupported blending mode" | `pass` on a non-group record | `passThroughOnNonGroup`; AB-L-0250 |
| Refused | a layer tagged block's length not a multiple of 4 (`grdm` proven; Photoshop 4-aligns all 12,949 blocks it writes) | `layerBlockNotFourAligned`; AB-L-0251 |
| Refused | `Lr16`/`Lr32` written before `Mt16`/`Mt32` — Photoshop writes an empty `Mt16`/`Mt32` first, then `Lr16`/`Lr32` (transparent 16/32-bit files) | `layerInfoBeforeMatteBlock`; AB-L-0252 |
| Refused | 32-bit document without HDR-toning colour-mode data (`hdrt`) | `hdrToningMissingAt32Bit` (PCPSD writers always add `hdrt` at 32-bit); AB-L-0252 |
| Refused, opens with `Txt2` dropped | a *generated* `Txt2` (offending field still open) — don't emit generated `Txt2` | RESULTS.md bug 5 |
| Refused | smart-object/link blocks that don't hang together: a `PlLd`/`SoLd` whose uuid no `lnk2` item carries; a `PlLd` that doesn't parse; an `lnk2` item labelled `liFE` with an embedded (`liFD`) layout; a 0-byte `SoCo` (a version-0 path-less `vmsk` is tolerated) | `placedLayerWithoutLinkedData`, `placedLayerDataUnreadable`, `linkedFileKindMismatch`, `fillLayerDataUnreadable` (errors only), all in pre-screen 4; AB-L-0270 |
| Adjustment opens as a pixel layer (no refusal) | adjustment kind Photoshop doesn't offer for the mode/depth (e.g. Vibrance in CMYK/Lab/Gray/32-bit), or a Color Lookup carrying a table without its `profile` | PCIO `AdjustMap.photoshopOffers`; AB-L-0268 |
| Artboard reads back Normal | Pass Through written on an artboard; Photoshop's artboards are Normal | AB-L-0270 |
| Type layer opens as an empty pixel layer; sometimes a **modal** "…type layers … were rasterized…" *after* the open (at close/script end) | type size Photoshop can't read (1e30 pt, `Double.greatestFiniteMagnitude`); deliberately hostile fixtures, not a writer bug | pre-screen 3 (`TypeSizeScreen`: size outside 0.01–1,296 pt, transform beyond ±300,000); AB-L-0262 |
| Refused, even with no layers | pattern data (`Patt`/`Pat2`/`Pat3`) with transparency in the user-mask array (slot 24); Photoshop uses the sheet mask (slot 25). A pattern fill/style whose pattern is missing is refused too | `patternTransparencyInUserMask`; AB-L-0258 |

Two oddities worth knowing: Photoshop's *saved* merged image can differ from its own recomposite (up to
194 levels with Threshold/Posterize) — compare compositors against `ps-oracle composite` output, not
the embedded merged image; and 16-bit values round-trip through Photoshop's 15-bit storage (≤ 0.012
levels).

## Diagnosing a new failure

1. **Offline first.** `ps-oracle structure <file>`, PCPSD's linter, and a byte-level diff of the
   suspect blocks against the same blocks *Photoshop wrote* (the Photoshop-authored corpus in
   `$PHOTOCRAFT_FIXTURES/ps-corpus`, built by `ps-oracle corpus build`, with `manifest.json` and
   `composites/*.tif`). Form one hypothesis.
2. **Then confirm with 2–3 minimal variants**, each opened once, lowest-risk first: the known-good
   Photoshop block transplanted in; the suspected field fixed; the block dropped. Stop at the first
   crash. (The type-layer crash and the `grdm` refusal were each pinned this way in 2–4 opens.)
3. For **refusals** (not crashes) of unclear cause, `ps-oracle explain <run.json> <dir>` applies the
   proven causes offline; `ps-oracle bisect <file>` narrows the rest. Never bisect a crashing file.
4. When a cause is proven, add an offline detector (PCPSD linter rule or pre-screen), calibrate it on
   Photoshop-authored files (0 false positives), and file a bridge lesson with the measurement
   (`bridge file --type lesson … --source <path:line>`), linked to AB-L-0246.

## Measuring a Photoshop function (when one corpus file can't pin a model)

When a compositor or filter is off Photoshop and the corpus file alone can't separate candidate
models, measure the function itself (`ps-oracle measure m1` is the worked example, RESULTS.md §5b):

- **Inputs:** a lattice the harness writes with ImageIO as a plain PNG. For example, the 64³ RGB lattice in a
  512 × 512 image plus a grey ramp. For a two-input operation (blend modes), stack the lattice on fixed
  permutations of itself so the pairs cover the cube. Photoshop opening a plain PNG/TIFF, or creating
  documents by script, is the low-risk class: no PSD of ours is opened.
- **Sweep the parameters** on a grid (e.g. brightness × contrast) and hold some settings out, so
  a fitted model is tested on settings it didn't see. A per-lattice lookup table is not a model.
- **Save** a PSD (Maximize Compatibility) plus a flattened uncompressed TIFF at the document's depth,
  and a manifest with every parameter and the working space. Untagged inputs get sRGB assigned,
  which leaves the values unchanged.
- **At 16 bits** Photoshop stores 15 bits, so fit against Photoshop's own round trip of the input
  (`identity-rgb16.tif`), not the PNG you wrote.
- **Read back every setting** after creating an adjustment or effect (`executeActionGet` on the
  layer) and fail the job if anything differs. Photoshop silently substitutes. In RGB 8/16,
  Brightness/Contrast defaults to the new Light mode, which drops Brightness, so a whole batch
  measured the wrong mode before the read-back existed (AB-L-0269). Set modes explicitly.
- **For effects** (layer styles), also save a raw-map twin: the shape at Fill 0 % with a white effect on
  black, so the effect's map reads directly instead of through its blend.

Data extracted this way describes Photoshop's behaviour. Shipping a *table* lifted from its output
(e.g. Dissolve's dither pattern) is a licensing question for the operator, not an engineering one.
The operator's standing answer (AB-D-0130) is no. Fitted models and aggregate curves are fine,
while per-pixel tables and the preset control points Photoshop stores are not copied. Contour
presets are re-measured from rendered output, and Dissolve matches coverage, not the pattern.

## Reporting

Report per run: files opened / refused / crashed / quarantined (with reasons), tree match, composite
difference (max / mean levels vs Photoshop's own composite), any new cause with its proof (which
variants opened), and whether Photoshop was left running with 0 documents. Keep the split between
Photoshop-authored reads, our builder's files, our exporter's files, and fuzz fixtures — mixing them
hides which writer is at fault.

Related bridge records: AB-L-0245 (EngineData), AB-L-0246 (automation protocol), AB-L-0250 (blend
table), AB-L-0251 (4-alignment), AB-L-0252 (matte order, 32-bit `hdrt`), AB-L-0253 (blend maths),
AB-L-0258 (pattern sheet mask), AB-L-0259 (byte-faithful rewrites need stored PackBits).
