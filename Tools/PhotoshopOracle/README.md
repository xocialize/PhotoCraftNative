# PhotoshopOracle — Adobe Photoshop as the PSD acceptance oracle

photocraft's gap list (G1) names opening our exports in real Photoshop as *the only real oracle* for
PSD acceptance. This package drives the installed **Adobe Photoshop 2026 (27.11.0)** through
ExtendScript and compares what Photoshop reads and renders with what PCPSD reads.

Results, and the operating protocol (pre-screens, quarantine, crash/modal policy): [RESULTS.md](RESULTS.md).

## Why a Swift package with ExtendScript resources

Photoshop is scriptable only through ExtendScript (`do javascript` over Apple events) or UXP. The
checks, though, need PCPSD itself: its layer tree, typed blocks, decoded merged image and layer
channels. So the tool is one Swift executable, `ps-oracle`, that:

- holds the cross-process **lock**, runs every script through `osascript` with a **hard timeout**, and
  **recovers or stops**. After a timeout it pings Photoshop; if Photoshop doesn't answer within 30 s
  (a modal dialog, licence or sign-in prompt, a hang), the run stops and reports instead of looping;
- keeps the ExtendScript as plain `.jsx` resources (`Sources/PSOracleKit/JSX/`), readable and
  editable without touching Swift. `lib.jsx` is prepended to every script;
- reads Photoshop's exports with its own uncompressed-TIFF / Photoshop-Raw reader, so values stay
  exactly as Photoshop wrote them;
- links PCPSD **by path** (`../../Packages/PCPSD`, read-only) and does all comparisons in Swift.

A script set (shell + JSX) would have needed a second program for the comparisons anyway, and it
would have had no shared lock or timeout logic.

## Safety rules the code enforces

- **Paths:** only paths under the data root (`PS_ORACLE_SCRATCH`, default the fixtures root) and
  this package directory are opened or written. `OracleConfig.checked` refuses the rest in Swift, and `PSO.checkPath`
  refuses them again inside Photoshop. Nothing goes through Photoshop's recent-files list or Open
  dialog. Opening a file does add it to Photoshop's own *Open Recent* menu; Photoshop has no way
  to avoid that.
- **No state changes:** every script sets `app.displayDialogs = NO` and restores the previous value.
  Sizes and coordinates always carry explicit pixel units, so the ruler-unit preference is never
  touched. No preference, colour setting or preset is changed: the corpus never defines a pattern,
  style or swatch. Pattern features use the first existing pattern preset by name, read-only.
- **Documents:** every document a script opens or creates is closed with `DONOTSAVECHANGES` in a
  `finally`. Untitled documents are named `pso_*`. `ps-oracle cleanup` closes only documents
  under the allowed roots or named `pso_*`.
- **One user at a time:** every command that talks to Photoshop takes an exclusive `flock` on
  `$PS_ORACLE_SCRATCH/ps-oracle.lock` (`PS_ORACLE_LOCK`). A second invocation prints who holds the
  lock and waits. The kernel releases an flock when its holder dies, so a crash can't wedge the
  lock. The pid note inside the file is cleared on release, and a note naming a dead pid is
  reported as stale and overwritten.
- **Never launches Photoshop.** `osascript … tell application` would start Photoshop if it isn't
  running, and a launch can bring up sign-in, licence or crash-recovery prompts. Every call first
  checks that Photoshop is running and refuses otherwise. The check reads the kernel's process list
  (libproc), because `NSRunningApplication` goes stale in a command-line process.
- **Preflight:** a run starts only when Photoshop is running, answers a script, and has **no
  documents open**.
- **Crashes and modals are expensive** (each one needs the operator): one strike stops the run.
  - Photoshop dies under a script (`-609`/`-600`): the run records the file, quarantines it and
    stops.
  - Any script timeout, or a cancelled-open error (8007 or "cancel"), means a modal dialog may be
    up: the run quarantines the file and stops without sending another script.
  - Every open also checks inside Photoshop that 0 documents are open.
  - The run never goes on to the next file and never relaunches Photoshop.
- **Quarantine:** a file that crashed or hung Photoshop goes into `$PS_ORACLE_SCRATCH/ps-oracle/quarantine.json`
  (by name and SHA-256). Every command refuses quarantined files unless the run is given
  `--allow-quarantined "<hypothesis>"`, which is logged. `ps-oracle quarantine` lists the file, or
  adds to it (`ps-oracle quarantine <file> --reason …`).

## Build and run

```bash
cd "$(git rev-parse --show-toplevel)"   # the repository root: one Package.swift for every package
swift build --product ps-oracle   # Swift 6, tools 6.2, macOS 26; no warnings
B=.build/debug/ps-oracle
$B ping                          # Photoshop version and open documents
```

| Command | What it does |
|---|---|
| `info <file>` | Photoshop opens the file and prints JSON: mode, bits, size, resolution, ICC profile name, channels, and the full layer tree in record order (bottom to top, group ends included). For each layer: name, kind (pixel, group, adjustment class, solid/gradient/pattern fill, text, shape, smart object), visibility, blend mode, opacity, fill opacity, clipping, user/vector/filter mask (enabled, density, feather), effects (type, enabled, present), text contents (and point/paragraph, warp), smart-object filters, knockout, blend-if, advanced-blending flags. Warnings and errors go in the JSON too. |
| `composite <file> <out.tif> [--alpha <a.tif>]` | Photoshop opens the file, flattens a duplicate and saves the composite as an uncompressed, big-endian, interleaved TIFF at the document's mode and depth, with no conversion and the ICC profile embedded. Duotone and Multichannel can't be TIFF, so they go to Photoshop Raw. `--alpha` also saves the composite with transparency, for documents without a background. |
| `accept <dir> [--json out]` | `info` on every PSD/PSB under `<dir>`: opened or failed, with Photoshop's error text. |
| `sweep <dir\|file>... [--out d] [--skip names] [--exclude substr] [--no-layers] [--resume]` | The acceptance sweep. Photoshop opens each file once (`probe.jsx`) for info, the flattened composite, the transparent composite and every pixel layer exported on its own. Then PCPSD reads the file and the sweep compares the tree field by field, the merged image against Photoshop's composite, and each layer's colour/alpha/masked alpha against Photoshop's export. Writes `<name>.json` and `<name>.md`. If Photoshop dies, the sweep records the file, quarantines it and stops (exit 3). After the operator relaunches Photoshop, `--resume` continues from the report. |
| `compare <file> <composite.tif>` | PCPSD's merged image against a composite, without Photoshop. |
| `corpus build [--out d] [--only a,b] [--list]` | Photoshop authors the oracle corpus (below). |
| `corpus read [<dir>]` | PCPSD over the corpus: parse, byte-identical rewrite, model-equal reparse, typed-block round trips, PCPSD linter, tree against Photoshop's own reading, merged image against Photoshop's composite. Writes `pcpsd-read.json` / `.md`. |
| `bisect <file> [--out d]` | Why Photoshop rejects a file. Writes variants: each top-level layer node alone, no layers at all, each global block dropped, each image resource dropped. Then opens each once and lists which open. Run it only on files that were *refused*, never on quarantined (crashing) ones. |
| `quarantine [<file> --reason r]` | List, or add to, the files that are never opened again. |
| `measure m1 [--out d] [--only ids]` | Measurement batch M1: Photoshop as a function oracle. It writes its own PNG inputs (the 64³ lattice, its permutations, a grey ramp; 8 and 16 bit), creates or opens only those, and runs Satin contour, modern Brightness/Contrast, Vibrance, Luminosity/Color/Hue/Saturation and Dissolve probes. Each job saves a PSD and a flattened TIFF; the results go to `$PS_ORACLE_SCRATCH/ps-measure/M1/manifest.json`, with the offline analysis. The jobs are in `JSX/measure-m1.jsx`; the shared job helpers are in `JSX/measure-common.jsx`, and the content helpers in `JSX/builders.jsx` (shared with the corpus). M1's B/C jobs ran in Photoshop 27's Light mode (RESULTS §5c). |
| `measure m2 [--out d] [--only ids] [--probe]` | Measurement batch M2 (RESULTS §5c): modern Brightness/Contrast and its pivot, Satin without anti-aliasing, Dissolve coverage, Vibrance hold-outs, Luminosity at 50 %, and the 12 contour presets rendered through Outer Glow. It runs a one-document B/C read-back check first (`--probe` runs only that). Every job reads back its settings and fails if Photoshop stored anything else. Dissolve and contour-preset jobs save composites only; contour presets are recorded by name, never by curve. |
| `measure m3 [--out d] [--only ids]` | Measurement batch M3 (RESULTS §5d): Photoshop 27's Light-mode Brightness/Contrast. It first records the default Light descriptor and probes each control's accepted range in one unsaved document. Then it sweeps Exposure across that range, Whites/Blacks/Highlights/Shadows at ±50/±100, Contrast −50/50/100, three combinations and one 16-bit job, each read back. |
| `blend-table` | Measure which blend modes Photoshop allows per colour mode and depth, for layers and for groups. It creates small documents only and opens no file, and saves `$PS_ORACLE_SCRATCH/ps-oracle/blend-table.json`. Pre-screen 2 needs this table: re-run it after a Photoshop update. |
| `prescreen <dir\|file>... [--dry-run] [--skip-swept r.json]` | Offline. Quarantines files of a known Photoshop crash or modal class. Pre-screen 1: type-layer EngineData gaps, by PCPSD's `photoshopStructureGaps()`. Pre-screen 2: blend modes outside the measured table, or Pass Through on a non-group. Pre-screen 3: type sizes outside 0.01–1,296 pt (run, style sheet, or size × transform scale), or transform components beyond ±300,000 (`TypeSizeScreen`). Pre-screen 4: PCPSD linter rules of proven refusal classes: `patternTransparencyInUserMask`, `placedLayerWithoutLinkedData`, `placedLayerDataUnreadable`, `linkedFileKindMismatch` (`LinterScreen`). The same checks run in every command before a file is opened. |
| `explain <run.json> <dir>` | Offline. Attributes each refused file of a sweep to the refusal causes proven so far (RESULTS.md); what stays unexplained is a candidate for `bisect`. |
| `structure <file>...` | How a file is laid out: header, colour-mode data, resources, layer-info placement and count sign, global blocks, per-record flags, channels and blocks. Use it to diff a rejected file against one Photoshop wrote. No Photoshop. |
| `eval <script.jsx> [args]` | Runs a script of your own (`lib.jsx` prepended, `ARGS.argv`) under the lock. A debugging aid. |
| `ping`, `cleanup` | Whether Photoshop is answering; close the documents ps-oracle owns. |

Environment: `PS_ORACLE_SCRATCH` (data root; default: PhotoCraftNative's fixtures root, which is
`$PHOTOCRAFT_FIXTURES` when set, else `../PhotoCraftNative-Fixtures` next to `PhotoCraftNative/`; see
its README), `PS_ORACLE_TIMEOUT` (seconds per Photoshop call, default 180), `PS_ORACLE_LOCK`,
`PS_ORACLE_VERBOSE`. `blend-table.json` and `quarantine.json` are read from `<data root>/ps-oracle/`.

### How pixels are compared

Comparisons happen in PCPSD's **stored** domain. Photoshop's exports are mapped back to how a PSD
stores samples:

- CMYK: TIFF ink values become inverted values.
- Lab: TIFF CIELab signed a\*/b\* become offset values.
- Indexed: palette indices are compared, plus a palette check.
- Bitmap: bits are compared.

Equal pixels therefore compare exactly at every depth. Differences are reported per channel in
native units and in **8-bit levels**: 16-bit ÷ 257; 32-bit float × 255. Photoshop stores 16-bit data
internally with 15 bits, so a 16-bit round trip through Photoshop can move by one 16-bit unit
(0.004 levels).

Per-layer exports come from *Duplicate Layer → New Document* with blending neutralised (100 %
opacity and fill, Normal, visible, effects hidden, mask off), saved as TIFF with transparency, then
saved again with the mask on. Photoshop writes these with **associated (premultiplied) alpha**,
ExtraSamples = 1, so colour is compared premultiplied. Photoshop premultiplies Lab a/b in its stored
(offset) form, and CMYK as ink.

## The Photoshop-authored corpus

`corpus.jsx` holds the catalogue: one builder per file, about 160 files. `ps-oracle corpus build`
asks Photoshop for the catalogue, then for each entry:

1. builds it in a new untitled document, using the DOM where it can and Action Manager where it
   can't (fill and adjustment layers, styles, blend-if, masks, smart filters, knockout, advanced
   blending, spot channels, Duotone);
2. saves it with **Maximize Compatibility on** (the `maximizeCompatibility` key of the save
   descriptor, so the preference is untouched), with the ICC profile, as PSD or PSB;
3. reopens the saved file and records Photoshop's reading (`info/<name>.json`) and Photoshop's
   flattened composite (`composites/<name>.tif`, or `.raw`), plus `composites/<name>-alpha.tif`
   when the document has no background;
4. writes `manifest.json`: each file, its features, mode, depth, record count, whether PCPSD sees
   real merged data, the composite paths, build notes (for example which blend modes a mode
   refuses), and the entries Photoshop refused to build, with its error text.

Regenerate everything, or a few entries:

```bash
$B corpus build                                   # → $PS_ORACLE_SCRATCH/ps-corpus
$B corpus build --only blend-multiply,fx-stroke   # rebuild some entries (the manifest is updated in place)
$B corpus build --list                            # the catalogue
$B corpus read                                    # PCPSD over it
```

To add a file, add a `C.add(name, features, description, builder[, 'psb'])` entry to
`corpus.jsx`. The builder receives a `notes` array, must create its document with `C.newDoc`
(so it's named `pso_*`), and returns it. The runner saves and closes it.

## Diagnosing a crash or a refusal

1. **Offline first.** Use `structure`, PCPSD's linter (it is in the sweep report), and the opt-in
   `TypeDiagTests` / `DebugTests`. Compare the file's blocks with the same kind of block Photoshop
   wrote itself (`ps-corpus`).
2. **Then confirm with as few opens as possible.** Write two or three minimal variants (the known-good block
   swapped in; the suspected field fixed; the block dropped) and open each once with `accept`,
   lowest-risk variant first. Stop at the first crash.
3. **Refused, not crashed:** `bisect` does the variant writing and the opening for you.

## Tests

`swift test --filter PSOracleKitTests` runs the reader and comparison unit tests. The diagnostics are opt-in, and those that
read the oracle's data (`TypeDiagTests`, `PatternDiagTests`, `RefusalVariantTests`, most of
`DebugTests`) also skip when the data root is missing. `DebugTests`: with
`PSO_VARIANTS_OUT=<dir under the data root>` it writes controlled variants of rejected PCPSD
files (block order, layer-count sign, HDR toning data) for `ps-oracle accept`. That is how the
acceptance failures in RESULTS.md were bisected.
