# PCEngine — port notes

Port of **photocraft-engine** (`crates/engine`), **photocraft-automation** (`crates/automation`) and
**photocraft-cli** (`apps/photocraft-cli`) to Swift 6 (photocraft revision `184c226a`, 2026-10-12).
MIT OR Apache-2.0, © ArtCraft Team and the PhotoCraft contributors. photocraft's behaviour is the
spec: command ids, labels, menu paths, shortcuts, params notation, history step names, result JSON
and error messages are kept verbatim, and photocraft's tests are ported one for one.

## Status

All 892 command ids of photocraft's catalogue are registered with photocraft's label, menu path,
shortcut and params notation: **887 implemented, 5 stubbed** (`plugin.*`, the WebAssembly plug-in
host), **0 not registered**. 21 more ids are registered that photocraft's engine doesn't have: the
seven File-menu ids its app shell owns (`file.open`, `file.save`, `file.saveAs`,
`file.export.exportAs`, `file.export.quickExportAsPng`, `file.clearRecent`, `file.removeRecent`),
nine PCIntelligence commands, `layer.layerMask.copy` (AB-T-0324, the Layers panel's mask drag), and the four filter adjustment layers (AB-T-0258:
`layer.newAdjustmentLayer.grain`, `.addNoise`, `.gaussianBlur`, `.motionBlur`, created with
Compositor's settings and edited by `layer.setAdjustment`; Grain's and Add Noise's `seed` defaults
to one derived from the new layer's id, and a reset keeps it; a PSD/PSB save bakes them into pixel
layers through `EngineRenderer.bakeFilterLayer`, AB-D-0143). Files go through PCIO (PSD, PSB, .pcraft, OpenRaster, layered
TIFF, Krita/Paint.NET/Affinity import, SVG, EXR parts) with the engine's compositor and PCPlatform's
text, vector and image codecs injected; smart objects re-render from their sources. `pccli`, the
control channel and MCP read and write every format.

## Layout

| Target | What it is |
|---|---|
| `PCEngine` (library) | `Session`, the command registry and every command module, jobs, events, view-models, preferences, display colour, and the glue between the finished packages |
| `PCAutomation` (library) | the headless JSON control channel (`control` / `serve`), the bridge to a running app, the MCP server (stdio and in-process), the CLI implementation, authorized workspaces (capability-scoped reads and writes), file I/O through `EngineIO` |
| `pccli` (executable) | `convert`, `info`, `run <in> --cmd <id> --params '<json>' … --out <file>`, `batch`, `droplet`, `commands [--json]`, `mcp`, `serve`, `control`, `coverage [--json|--markdown]`; reads and writes every format PCIO and PCPlatform handle (PSD/PSB/.pcraft/OpenRaster/layered TIFF and the flat formats) |

Dependencies (by path): PCFoundation, PCDocument (+ PCHistory), PCRender, PCPaint, PCPlatform,
PCIntelligence, PCAlgo, PCIO (+ PCIOCore, PCFormat, PCIOFormats, PCIOSmart, PCIOMaps), PCPSD (Photoshop preset codecs PCIO leaves to
the engine, e.g. `.shc`; tests read PSD bytes with it); ExtractKit / EraseKit / ColorizeKit (the
option types PCIntelligence's operations take); the official MCP `swift-sdk` 0.12.1 (PCAutomation).

### Module map

`Sources/PCEngine/`:

* **`Core/`** — `Session.swift` (documents, targeting, dispatch, `edit`/`commit`, undo/redo,
  snapshots), `SessionFiles.swift` (open/save/Save As/recent files/crash recovery), `CommandSpec.swift` / `CommandRegistry.swift` (specs, `DispatchHooks`, modules),
  `ParamSchema.swift` (photocraft's params notation → JSON Schema), `Jobs.swift` (background jobs:
  progress, cancel, document lock, rebase), `Transactions.swift` (before/after → PCHistory
  `DocumentOp`s, damage), `DocState.swift` (per-document state, `StateKey` module state),
  `Events.swift` (`SessionEvent`, `EventHub`, `SnapshotStore`), `ChannelTargets.swift` (Channels
  panel targets: masks, alpha channels, Quick Mask), `Preferences.swift` + `PersistedPreferences.swift`,
  `Services.swift` (file system, clipboard, clock, renderer, intelligence), `Inspect.swift`, `JSON.swift`,
  `EngineError.swift`.
* **`Glue/`** — `PlatformRasterizer.swift` (PCPlatform `TextEngine`/`VectorRasterizer` as PCRender's
  `LayerRasterizer`), `EngineRenderer.swift` (PCRender's `DocumentCompositor` as canvas, export and
  AI compositor), `DisplayColor.swift` (ColorSync install, `DisplayLUT` → PCRender's display path),
  `PatchMatchInpaint.swift` (PCAlgo's PatchMatch as PCIntelligence's classical inpaint tier),
  `DocumentCMYK.swift` (a document's own CMYK profile as PCFoundation's scoped converter),
  `EngineIO.swift` (PCIO's injected services, and the engine's import/export entry points).
* **`Pixels/`** — shared pixel helpers (`Pixels`, `SurfaceOps`, `LayerOps`, `ClipGroup`,
  `CanvasGeometry`, `SelectionMath`, `Parallel`).
* **`Commands/`** — one `CommandModule` per photocraft module, named after it
  (`layer_menu_cmds.rs` → `LayerMenuCommands.swift`; `commands.rs` → `CoreCommands.swift`,
  `layer_multi_cmds.rs` → `LayerMultiCommands.swift` (`LayerMulti`), `filters.rs` →
  `FilterCommands.swift`, `jobs.rs` → `JobsCommands.swift`, `prefs.rs` → `PrefsCommands` in
  `Preferences.swift`). Every file's first line names its photocraft source; big modules are split
  into `Name+Part.swift` files. `EngineModules.swift` lists them in photocraft's registration order;
  `StubCommands.swift` registers every photocraft id nothing implements as `unavailable(reason)`
  (only `plugin.*` is left); `IntelligenceBridge.swift` registers PCIntelligence's descriptors as
  commands; `FileMenuCommands.swift` registers the File-menu ids photocraft's app shell owns
  (`file.open`, `file.save`, `file.saveAs`, `file.export.exportAs`, `file.export.quickExportAsPng`,
  `file.clearRecent`, `file.removeRecent`), so every frontend opens and saves the same way;
  `LayerMaskCopyCommands.swift` (`layer_mask_copy_cmds`, PhotoCraftNative's own) is the Layers panel's drag of a
  mask thumbnail (AB-T-0324).
* **`Data/`** — `PhotocraftCatalog.swift` (generated: all 892 photocraft commands with label, menu,
  shortcut, params and module — the coverage reference) and `MenuCatalog.swift` (photocraft's menus).
* **`ViewModels/`** — Layers / History / Channels / Paths / Properties models and the thumbnail cache.

## Session and registry API (for the app)

```swift
let session = Session()                                  // registry: .standard(), services: EngineServices()
try session.execute("file.new", ["width": 1920, "height": 1080])
try session.execute("filter.blur.gaussianBlur", ["radius": 2])     // id + JSON params, like menus/CLI/MCP
session.isEnabled("edit.undo"); session.disabledReason("layer.mergeDown")
let started = try session.start("filter.blur.lensBlur", p)        // .done(result) | .job(id): background
session.pollJobs(); session.cancelJob(id); try await session.awaitJob(id)
for await e in session.events() { … }      // documentChanged(id, revision, damage), jobProgress, toast, …
session.snapshots.active                   // Mutex-published DocSnapshot, readable from any thread
session.viewModels()                       // layers, history, channels, paths, properties
session.prefsValue() / loadPrefs(_:)       // the one persisted preferences JSON (presets, swatches, …)
CommandRegistry.standard().specs           // id, label, menu, shortcut, params, schema, kind, preview

// Files (also as commands: file.open {path}, file.save {path?}, file.saveAs {path}, …)
let (index, warnings, colorReport) = try session.openFile("/path/a.psd")  // PCIO import + Color Settings policy
let out = try session.saveDocument(to: "/path/a.psd")  // SaveOutcome {path, warnings, copy, assets}
let job = try session.saveJob(to: "/path/a.pcraft")    // the same save in parts: a snapshot, taken here,
let written = try job.run()                            // written on any thread,
try session.finishSave(job, written)                   // its bookkeeping back on the session's
try await session.executeAsync("file.save")            // or as a background job (file.save, file.saveAs)
session.recentFiles; session.enableRecovery(dir); session.autosaveDirty()
session.recoverableDocuments(); try session.restore(entry)
let r = try EngineIO.export(doc, as: "x.png", services: session.services)   // bytes + warnings
let i = try EngineIO.importFile(name: "x.psd", bytes: bytes, services: session.services)
```

* **Isolation.** `Session` is a non-`Sendable` class confined to one isolation domain: the app's main
  actor, the MCP server's `EngineHost` actor, or the CLI thread. Readers elsewhere use
  `session.snapshots`; background work runs as jobs whose results apply on the session's domain
  (`pollJobs`, or `awaitJob`/`executeAsync`).
* **Everything is a command.** Menus, the palette, shortcuts, actions, the CLI, the control channel
  and MCP dispatch the same ids. A command runs `enabled(session, params)` (nil = enabled, else the
  reason), then `run`; an edit commits one `EditTransaction` (ops by layer id, so a job's edit
  rebases onto a document that changed meanwhile) and one history step; `journal` records it for
  Actions and replay. `kind` (instant / dialog / interactive) and `preview` tell the UI how to
  present it.
* **Adding commands later** (the plug-in host): a module conforming to `CommandModule` registers
  specs with the same ids; `CommandRegistry.add` replaces the `unavailable` stub by id.
* **Files.** Without a path, the app shows its own picker and calls back with one (the commands
  take explicit paths; the CLI, control channel and MCP pass them). A save becomes the document's
  file unless it is a flat file that can't hold it (photocraft `saves_copy`: layers, or a layered
  original), which writes a copy; a save to its own file discards its crash-recovery data and runs
  the Save Document script event and Image Assets. All reads and writes go through
  `services.fileSystem` (crash-safe writes for the local one).
* **Saving off the session's thread (AB-T-0259).** `saveDocument` is `saveJob` (on the session's
  thread: what to write, and the document as a snapshot), `SaveJob.run` (any thread) and
  `finishSave` (the session's thread again: the file becomes the document's, the recovery data
  goes, Save Document and Image Assets run). An edit made while a job runs stays unsaved, and the
  document stays dirty. `file.save` and `file.saveAs` are jobs (`runJob`, not locking the
  document): `start` or `executeAsync` writes the file on a worker. A document's package writer and
  its last `.pcraft` previews live in its `SaveSlot`, whose lock its jobs take one at a time, so two
  saves never write one package at once; closing the document drops it. The previews come from one
  reduced composite (PCIO's `pcraftPreviews`), which the slot keeps with the document it shows:
  - unchanged while nothing they show changed (`SaveSlot.unseen`: the document equal but for its
    name, identity, selection, guides, notes and work path; unchanged tiles are shared, so only
    edits are compared);
  - after an edit, only the reduction's cells meeting what the edit can have changed are composited
    again: the damage of `TransactionBuilder.transaction(from:to:)` between the two, effects'
    reach included (the canvas's own invalidation), else the whole;
  - for a `.pcraft` just opened (`openFile`), the previews the file holds stand for the last ones
    (`SaveSlot.opened`), read at its first save, unless the file has changed since it was opened
    (`FileStamp`) or the document has a profile of its own (its previews are converted to sRGB).

* **Live strokes.** `BrushCommands.LiveStroke` (Brush, Pencil) and `LiveRetouchStroke` (Smudge,
  Blur, Sharpen, Sponge, Clone Stamp; AB-T-0299) draw a stroke onto a copy of the active document
  as its points come: `begin(session, cmd, params)`, `push(points)`, then show `doc`. Each push
  costs what its new points cost. `BrushCommands.offerLiveStroke` / `LiveRetouchStroke.offer` hand
  the finished stroke to the command that commits it. That command takes its pixels
  (`"fromLive": true`) when the params, points and document revision match, so the preview is the
  commit. Unoffered, the command gives the same pixels (`LiveRetouchTests`, at 8, 16 and 32 bits).
  The live Smudge, Blur, Sharpen and Sponge run only the new dabs, on a working copy that grows
  with the stroke. What finishing would add (a click's dab, Smoothing's catch-up) is drawn from a
  copy of the part it reaches. Clone Stamp is PCPaint's `LiveRetouch`, with the command's own
  sampler for the composite. Not live yet: the Healing Brush (its Poisson solve covers the whole
  stroke), Dodge and Burn (they remember each pixel's first colour), Liquify.

  Timings (`LiveRetouchTimingTests`, opt-in; release, no other build running, 2026-10-16): a
  2000 × 1500 layer, a 60 px brush at hardness 50, a 600 px stroke at a point a pixel. Each cell is
  a rerun of the whole stroke against one live push of the next 10 px:

  | Tool | 150 px | 300 px | 450 px | 600 px | Pen-up: rerun / offer + commit taking it |
  |---|---|---|---|---|---|
  | Smudge (spacing 1.7 %) | 19.9 / 1.3 ms | 38.7 / 1.3 | 57.9 / 1.3 | 76.7–78.6 / 1.2 | 78–80 / 1.0 + 0.4 ms |
  | Blur (radius 4) | 29.4–30.1 / 2.2 | 56.5–56.7 / 2.3 | 84–86 / 2.1–3.0 | 112–113 / 2.2 | 112–114 / 2.5 + 0.3 |
  | Clone Stamp | 0.7–0.8 / 0.4 | 1.2–1.4 / 0.3 | 1.7–1.9 / 0.3 | 2.4–2.5 / 0.9 | 2.3–2.4 / 0.0 + 0.3 |

## Glue

* **Rasterizer.** PCRender's compositor renders type, shapes, vector masks and smart-object caches
  through `PlatformRasterizer` (PCPlatform's CoreText/CoreGraphics engines), at the document's dpi.
* **Compositor.** `EngineRenderer.shared` (PCRender's `DocumentCompositor` with the PCPlatform
  rasterizer: one Metal device, one leaf cache, CPU reference fallback) serves the canvas, merges and
  stamps, thumbnails, PCIntelligence's Sample-All-Layers sources, and is PCIO's
  `PCIOCore.DocumentCompositor`, so the merged image, previews and thumbnails of every export render
  type, shapes, vector masks, fill layers and smart objects. Colour Settings' *Blend Text Colors
  Using Gamma* sets its text gamma.
* **PCIO.** `EngineIO.options(services)` gives PCIO the engine's compositor, a
  `PlatformContentRenderer` (PCIO's `LayerContentRenderer`: shapes through `VectorRasterizer`, text
  through `TextEngine` behind the type lock, fill layers through the compositor, font lookups
  through `FontCatalog`), a `PlatformImageCodec` (PCIO's `FlatImageCodec` on PCPlatform's
  `ImageCodecs`: every format PCPlatform reads, at native depth, with EXIF/XMP/ICC/text read as
  PCIO's own reader does; metadata-bearing writes through PCIO's ImageIO writer) and the smart-object
  placer (`MeshWarp.placeSource[Projective]`). `EngineIO.importFile` / `export` are photocraft's
  `file_cmds::import` / `save_doc`: layered formats and PNG/JPEG/TIFF through PCIO, other flat formats
  (WebP, GIF, BMP, TGA at 24/32 bits, …) through `ImageCodecs`; a JPEG or WebP keeps the encoding
  it was opened with unless a quality is given (photocraft `file_encoding`). Recovery autosaves
  go through PCFormat's `RecoveryStore`.
* **Colour.** `ColorManagement.install()` runs at session start; `DisplayColor` builds PCRender's
  display LUT from PCPlatform's (`ColorCommands.canvasDisplay` adds proofing and 32-bit previews).
  `paint.*` commands and live strokes run inside the document's own CMYK profile
  (`DocumentCMYK`, PCFoundation `ColorConvert.withCMYK`; photocraft `with_cmyk_space`).
  `document.pixel`, the Eyedropper / Color Sampler and the adjustment eyedroppers read the
  composite with float accumulation (`EngineRenderer.renderExact`): PCRender's display path
  composites a plain 8-bit stack in half floats by design.
* **Intelligence.** `session.intelligence` is PCIntelligence's registry; its 14 descriptors are real
  commands (jobs with receipts). PCAlgo's PatchMatch is the registry's built-in classical
  inpaint tier (`setBuiltIn(inpaint:)`, under the slot, on a host's PCIntelligence too), so a host that
  empties the `inpaint` slot leaves it in place rather than EraseKit's diffusion (AB-T-0304); Content-Aware Fill passes photocraft's sampling and adaptation options to it
  through PCIntelligence's `OptionsInpaintProvider` seam (`ContentAwareFillOptions.inpaint`).
  Image Size's `"enlarger"` runs PCIntelligence's enlarger slot (AB-T-0292; see Decisions).
* **Filters.** `FilterCommands` is the runner every Filter-menu module uses: `paramsFor` maps a
  command id and dialog-unit params to a PCAlgo filter (photocraft `params_for`, chained through
  filters_ext, color_to_alpha and gallery), `runFilter` runs it on the target (layer, mask, alpha
  channel or Quick Mask; selection; locks) as a cancellable background job, and smart objects record
  a smart filter (`applyFilterToSurface` re-renders recorded ones).

## Coverage

From `pccli coverage --markdown` (implemented = registered and available; stubbed = registered as
`unavailable(reason)`):

| photocraft module | commands | implemented | stubbed (`unavailable`) | not registered |
|---|---:|---:|---:|---:|
| `actions_cmds` | 9 | 9 | 0 | 0 |
| `adjust_cmds` | 5 | 5 | 0 | 0 |
| `align_cmds` | 2 | 2 | 0 | 0 |
| `analysis_cmds` | 18 | 18 | 0 | 0 |
| `artboard_cmds` | 8 | 8 | 0 | 0 |
| `automate_cmds` | 6 | 6 | 0 | 0 |
| `background_cmds` | 1 | 1 | 0 | 0 |
| `brush_cmds` | 11 | 11 | 0 | 0 |
| `brush_key_cmds` | 5 | 5 | 0 | 0 |
| `brush_preset_cmds` | 5 | 5 | 0 | 0 |
| `channel_cmds` | 28 | 28 | 0 | 0 |
| `color_cmds` | 8 | 8 | 0 | 0 |
| `color_to_alpha_cmds` | 1 | 1 | 0 | 0 |
| `commands` | 83 | 83 | 0 | 0 |
| `comps_cmds` | 14 | 14 | 0 | 0 |
| `cutout_cmds` | 1 | 1 | 0 | 0 |
| `distort_cmds` | 5 | 5 | 0 | 0 |
| `document_preset_cmds` | 6 | 6 | 0 | 0 |
| `edit_cmds` | 19 | 19 | 0 | 0 |
| `edit_menu_cmds` | 14 | 14 | 0 | 0 |
| `eraser_cmds` | 2 | 2 | 0 | 0 |
| `exr_cmds` | 2 | 2 | 0 | 0 |
| `extra_cmds` | 33 | 33 | 0 | 0 |
| `file_cmds` | 21 | 21 | 0 | 0 |
| `fill_key_cmds` | 5 | 5 | 0 | 0 |
| `filters` | 31 | 31 | 0 | 0 |
| `filters_ext` | 32 | 32 | 0 | 0 |
| `float_cmds` | 2 | 2 | 0 | 0 |
| `frame_cmds` | 2 | 2 | 0 | 0 |
| `fx_view_cmds` | 1 | 1 | 0 | 0 |
| `fx_visibility_cmds` | 1 | 1 | 0 | 0 |
| `gallery_cmds` | 48 | 48 | 0 | 0 |
| `gradient_fill_cmds` | 4 | 4 | 0 | 0 |
| `group_view_cmds` | 1 | 1 | 0 | 0 |
| `history_cmds` | 8 | 8 | 0 | 0 |
| `image_cmds` | 12 | 12 | 0 | 0 |
| `installed_profiles` | 1 | 1 | 0 | 0 |
| `jobs` | 2 | 2 | 0 | 0 |
| `layer_copy_cmds` | 1 | 1 | 0 | 0 |
| `layer_label_cmds` | 1 | 1 | 0 | 0 |
| `layer_mask_props_cmds` | 1 | 1 | 0 | 0 |
| `layer_menu_cmds` | 29 | 29 | 0 | 0 |
| `layer_multi_cmds` | 24 | 24 | 0 | 0 |
| `layer_nav_cmds` | 6 | 6 | 0 | 0 |
| `layer_style` | 14 | 14 | 0 | 0 |
| `lens_cmds` | 4 | 4 | 0 | 0 |
| `magnetic_cmds` | 1 | 1 | 0 | 0 |
| `mask_view_cmds` | 2 | 2 | 0 | 0 |
| `migrate_cmds` | 1 | 1 | 0 | 0 |
| `mode_cmds` | 5 | 5 | 0 | 0 |
| `multichannel_cmds` | 1 | 1 | 0 | 0 |
| `notes_cmds` | 5 | 5 | 0 | 0 |
| `paint_cmds` | 2 | 2 | 0 | 0 |
| `path_edit_cmds` | 6 | 6 | 0 | 0 |
| `pattern_cmds` | 8 | 8 | 0 | 0 |
| `pattern_fill_cmds` | 1 | 1 | 0 | 0 |
| `perspective_crop_cmds` | 1 | 1 | 0 | 0 |
| `photo_cmds` | 3 | 3 | 0 | 0 |
| `pick_cmds` | 2 | 2 | 0 | 0 |
| `plugin_cmds` | 5 | 0 | 5 | 0 |
| `prefs` | 24 | 24 | 0 | 0 |
| `preset_import_cmds` | 2 | 2 | 0 | 0 |
| `presets` | 32 | 32 | 0 | 0 |
| `print_cmds` | 4 | 4 | 0 | 0 |
| `proof_sim` | 9 | 9 | 0 | 0 |
| `rasterize_style_cmds` | 1 | 1 | 0 | 0 |
| `redeye_cmds` | 1 | 1 | 0 | 0 |
| `render_cmds` | 3 | 3 | 0 | 0 |
| `retouch_cmds` | 14 | 14 | 0 | 0 |
| `sample_cmds` | 1 | 1 | 0 | 0 |
| `sampler_cmds` | 5 | 5 | 0 | 0 |
| `select_extra_cmds` | 3 | 3 | 0 | 0 |
| `selection_cmds` | 10 | 10 | 0 | 0 |
| `slice_cmds` | 10 | 10 | 0 | 0 |
| `smart_cmds` | 24 | 24 | 0 | 0 |
| `smartselect_cmds` | 5 | 5 | 0 | 0 |
| `solid_fill_cmds` | 1 | 1 | 0 | 0 |
| `stamp_cmds` | 2 | 2 | 0 | 0 |
| `swatch_cmds` | 12 | 12 | 0 | 0 |
| `symmetry_cmds` | 3 | 3 | 0 | 0 |
| `timeline_cmds` | 7 | 7 | 0 | 0 |
| `transform_cmds` | 1 | 1 | 0 | 0 |
| `trap_cmds` | 1 | 1 | 0 | 0 |
| `type_caret_cmds` | 3 | 3 | 0 | 0 |
| `type_cmds` | 10 | 10 | 0 | 0 |
| `type_extra_cmds` | 31 | 31 | 0 | 0 |
| `type_mask_cmds` | 1 | 1 | 0 | 0 |
| `type_spell_cmds` | 2 | 2 | 0 | 0 |
| `type_styles_cmds` | 18 | 18 | 0 | 0 |
| `variables_cmds` | 6 | 6 | 0 | 0 |
| `vector_cmds` | 38 | 38 | 0 | 0 |
| `video_cmds` | 15 | 15 | 0 | 0 |
| `vp_cmds` | 1 | 1 | 0 | 0 |
| `warp_cmds` | 7 | 7 | 0 | 0 |
| `web_cmds` | 4 | 4 | 0 | 0 |
| `wia_cmds` | 1 | 1 | 0 | 0 |
| **total** | **892** | **887** | **5** | **0** |

## Tests

**1 512 tests pass** (`swift test` from `Packages/PCEngine`, Swift Testing, Debug, ≈ 3 min on
2026-10-12): 1 361 in 110 suites for PCEngine and 151 in 11 suites for PCAutomation. One test carries a
`withKnownIssue` (5 expectations): `LayerStyleTests.contourPresetsMatchPhotoshop`'s Satin checks,
against PCRender's changed Satin (see the change requests). No compiler warnings.

* photocraft's engine, automation and CLI tests are ported one for one into the test file of the
  module they test (`<Module>Tests.swift`); each file's header names its source and lists what is
  skipped or adapted and why.
* `LitmusTests` runs a multi-command edit, undo/redo and journal replay, then a PSD round trip
  through `file.saveAs` / `file.open` and a lossless `.pcraft` check; `CLITests` /
  `CLIPortTests` convert PSDs, `.pcraft`, OpenRaster and layered TIFF through `pccli`. With
  `PCIO_EXPORT_DIR` set (as for PCIO's tests, e.g. `$PHOTOCRAFT_FIXTURES/pcio-exports`), every PSD a
  test writes is also dropped there (`pcengine-*.psd`, 28 files) for the Photoshop oracle agent.
  Unset, nothing is dropped.
* Each module's tests check its ids against `PhotocraftCatalog` (label, menu, shortcut, params);
  `pccli coverage` reports the whole catalogue.

## Decisions and deviations

* **History.** Edits commit fine-grained transactions; history keeps snapshots (PCHistory). Guides,
  paths, slices, notes and the canvas size commit as `setDocumentProperties` (the changed fields
  only), so they rebase like layer ops; `replaceDocument` is left for reorders, mode/profile
  changes and the other document fields. Damage comes from the ops: tile patches give the exact
  changed pixels (also on undo), layer properties their layer's bounds, selections, names, guides,
  paths, slices and notes nothing.
* **Big canvases.** File › New builds its Background with `Document.withBackground`, whose
  `Surface.fill` shares one tile per whole tile and per missing edge shape, so a 300 000² document
  costs a few tiles, as photocraft's shared `Arc` tile.
* **Smart objects.** Sources (embedded, linked, PSD placed-layer data) decode through PCIO and are
  flattened by a private CPU compositor per decode (rendering from inside the shared renderer could
  deadlock on its lock); decoded sources and smart-filter stages are cached (SHA-256 keys instead of
  blake3); linked files are watched by size + content hash (the file service has no stat).
* **Retouching gaps PixelAgencyEditor worked around (AB-T-0299).**
  - Spot Healing's Content-Aware rebuilds the spot with PCAlgo's `InpaintKit.patchFill` (Compositor's
    PatchPixels.c, ported) and lays it in by coverage, without the Poisson blend. photocraft's
    completion is now only its fallback, used when there's nothing to copy from. On the editor's ridge
    fixture (`SpotHealingCurveTests`: a red disc on a curved skyline, 56 px brush), Content-Aware is off
    by 10.8 levels (seeds 1…424242: 9.6–11.3). With the completion it was off by 26.3, and Proximity
    Match is off by 43.3.
  - Content-Aware Fill's precondition refuses a selection that leaves no 7 × 7 patch of unselected
    pixels in the window the fill samples from (it filled the layer black). Its colour adaptation keeps
    gain 1 for a flat source (PCAlgo's `fit`), so a plain fill stays exact at Default: it gave
    (51,153,214) for (51,153,204).
  - `paint.blur` and `paint.sharpen` take `"radius"` (the Gaussian's σ, 0.1…100 px). Without one, Blur's
    σ follows the brush (3 % of its size, 1…4) and Sharpen's is 1.
  - Smudge reads a halo the width of its carried colour's radius (photocraft's halo is 0). Its first
    pick-up used to be clamped to the stroke's bounding box, so pixels near that box's edge change. The
    change lets a live stroke, which can't know the box, give the command's pixels.
* **Image Size's enlarger (AB-T-0292, AB-D-0119's chain).** `image.imageSize` takes `"enlarger": true`
  (default false). It applies only when the slot holds an available `ImageEnlarger` and the target is larger
  than the image on both axes.
  - Each pixel layer's pixels (its content bounds, groups included) run the provider's ×2 the fewest times that
    reach the target on both axes. Then the chosen `resample` fits them to the exact size; there's no fit when
    the passes land on it. Automatic fits with Bicubic Sharper.
  - Masks, channels, the selection and Quick Mask resample bilinearly, as in any Image Size. Type, shape and
    smart object layers resample and re-render as today, so the provider never sees a smart object's source.
    Effects scale as below. It's all one step named "Image Size".
  - The intermediate canvas is held to the target's budget (8 GiB at the document's depth). When it would pass
    that, the chain takes fewer passes and the fit enlarges the rest ("fitsUp"); with no pass possible, it falls
    back. Passes are capped at 8.
  - The result gains `enlarger`: `{used: true, engine, passes, intermediate: [w, h], fit, fitsUp, layers,
    chain}`, e.g. `chain: "Anime4K (VL) ×4 (2 passes of ×2) → 1000 x 800 (lanczos)"`. A fallback to the Resample
    alone reports `{used: false, reason}` with the slot's own reason (empty, emptied by the host, unavailable),
    "not larger on both axes", Resample off, or the budget. Without the flag the result is unchanged.
  - It runs as an async job (`runAsyncJob`, document locked, cancellable between layers and passes, rebasing like
    `editJob`). `start` / `executeAsync` run it in the background: `executeAsync` from the main actor completes
    even with a provider that hops to the main actor (`executeAsyncRunsTheChainAsABackgroundJob`). A plain
    `execute` blocks its thread until the job finishes, so a host must not call it on a thread the provider needs.
    The Color Sampler map is set when the job applies, not when it starts.
* **Image Size scales effects itself.** `resampleDocument` (Image Size, and Crop with a target size) scales
  every layer's effects with the pixels: shown or hidden, active or not, inside groups, by k = (sx + sy) / 2, in
  the same step. This is Photoshop's Image Size with Scale Styles on; there's no off switch. `"resample":"none"`
  leaves them. A host must not scale them again. PixelAgencyEditor's AB-T-0271 dropped its own pass
  (`EngineEffects.scaled`), which used the geometric mean √(sx·sy): the two agree for a proportional resize.
* **Style commands' target layer (AB-T-0300).** `layer.layerStyle.scaleEffects` takes `{"layer":id?}` (photocraft's
  params have only `scale`; the catalogue test lists the extension). Its enabled check reads that layer, else the
  active one, and accepts a layer whose effects are all hidden, as Photoshop's Scale Effects does.
  `layer.layerStyle.createLayer`'s check reads `"layer"` too and wants an effect showing, with the layer's
  effects on (what its body needs). `Session.disabledReason` / `isEnabled(id, params)` now check a command that
  documents `"layer":id` on the layer it names, as `dispatch` already did, so asking and running agree.
* **Copying and moving a layer mask (AB-T-0324).** `layer.layerMask.copy {"from":id? (default active),"to":id,
  "move":bool=false}` is Photoshop's drag (move) and ⌥-drag (copy) of a mask thumbnail onto another layer. photocraft
  has no counterpart, and Photoshop has no menu item, so the command has no menu path.
  - The target gets the source's `LayerMask` whole: its surface where it sits on the document (masks are
    document-space), the value outside its content (a Hide All mask's black), density, feather, enabled and linked.
    Any mask the target had is replaced; asking first is the host's job, as Photoshop's "Replace layer mask?" is.
  - `move` deletes the source's mask in the same step. One history step: "Copy Layer Mask", "Move Layer Mask", or
    "Replace Layer Mask" when the target had one (PixelAgencyEditor's and Compositor's names; Photoshop's own step
    names were not checked, Photoshop not being up).
  - Folders take the mask, as in Photoshop; the Background becomes "Layer 0" first, as Add Layer Mask makes it.
    Refused: no mask on `from`, `from` = `to`, a missing layer. Vector masks are out of scope.
  - The target becomes the active, only selected layer; the Channels target is left alone. The result is
    `{layer, replaced, moved}`. The enabled check reads `from`/`to`, so `isEnabled(id, params)` answers a drop.
* **Remove Background on a smart object (AB-T-0309).** `layer.removeBackground` takes a smart object and leaves it
  one, as Photoshop's Quick Action does: PCIntelligence samples its rendered placement (or the composite with
  `sampleAllLayers`) and the step only adds its mask ("Remove Background", one step). `paint.remove`,
  `edit.contentAwareFill` and the pixel filters still refuse it. It runs on the Vision tier with every slot emptied
  (`RemoveBackgroundSmartTests`, a PNG placed with `file.placeEmbedded`).
* **Deep nesting.** Debug builds recurse through `Equatable` on 100 nested groups (photocraft's cap);
  the tests that build them run on an 8 MB thread. Release frames are far smaller.

## What's left

* **The plug-in host** (photocraft-plugins, WebAssembly): the five `plugin.*` ids stay
  `unavailable`.
* **Consolidation.** Some modules keep local CPU ports of photocraft-algo helpers written before
  PCAlgo existed (listed in each file's header); they match photocraft and are tested, but should
  call PCAlgo. Some early test files still build their setup with direct edits where photocraft runs
  another module's command (their headers say so); the behaviour is covered, the setup could now use
  the real commands.
* **Preferences** accept any value for a known key; photocraft's typed preferences refuse values
  outside their allowed set or range (Export Preferences validates its own section).
* **Skipped tests** (each file's header lists them): benchmarks marked `#[ignore]`, tests of Rust
  mechanisms with no Swift counterpart (allocation-failure injection, lock poisoning, unwinding),
  tests that read the egui shell's source, ICC profiles synthesised with photocraft-cms's writer,
  and the CLI test that spawns the binary (`serveIO` covers the wire in process).

## Change requests for other packages

* **PCFoundation**
  1. ~~`TileCoord.rect` overflows (traps) for the last tile row/column before `Int32.max` (pixels at
     x ≥ 2 147 483 392); photocraft's #963 test puts a selection there.~~ Done: it saturates like
     photocraft's `Rect::from_xywh`; `contentAwareHugeExtentIsAnError` uses photocraft's
     `Int32.max - 2` again and `layerSliceOutsetsSaturate…` both of photocraft's offsets.
  2. ~~`Surface.converted(to:)` traps when the target format changes alpha (Define Pattern strips
     alpha by hand meanwhile).~~ Done: adds an opaque alpha or drops it (photocraft `convert`);
     Define Pattern calls it.
  3. ~~A shared solid-tile fill (`Surface.fill` that puts one copy-on-write tile at every whole
     tile), so `Document.withBackground` doesn't allocate every tile of a huge canvas (the engine
     does this itself in File › New).~~ Done: `Surface.fill` shares one tile per whole tile and
     per missing edge shape; File › New uses `Document.withBackground`; `fillSharingTiles` removed.
  4. ~~Debug-build speed of `contentBounds` / `prune` / `writeRegion` / per-sample reads dominates
     every package's tests (PCAlgo's request 5 too).~~ Done: raw-pointer row loops, `memcmp`
     scans, exact decode tables (values unchanged); see PCFoundation's notes for the timings.
* **PCDocument**
  1. ~~`DocumentOp.setDocumentProperties` (guides, paths, slices, notes, canvas size as rebaseable
     ops): today such edits commit as one `replaceDocument` op, exact but not rebaseable.~~ Done:
     `TransactionBuilder` emits it for those fields (`DocumentProperties`, changed fields only).
  2. ~~`Document.withBackground` should use the shared-tile fill above.~~ Done.
  3. ~~`resolvedSlices()` is quadratic (≈ 17 s for 10 000 slices in Debug).~~ Done: a band sweep
     with identical output; three 10 000-slice documents resolve in 0.4–0.6 s together in Debug.
* **PCPlatform**
  1. ~~`FontCatalog` asks the font daemon on every character lookup; parallel callers stall on it
     (TypeCommands serialises text work behind a lock). Cache faces per family.~~ Done: faces,
     descriptors, styles and CTFonts cached; misses serialised inside PCPlatform (Release
     `resolveFace` 35.9 → 0.05 µs, layout 4.44 → 0.08 ms, 8 threads 487 → 38 000 layouts/s).
     `TypeCommands.textLock` removed; `fonts(_:)` is a pass-through (PCPlatform PORT-NOTES §11).
  2. ~~Manual kerning adds to the font's pair kerning instead of replacing it.~~ Done: the pair's
     metrics kerning is measured and replaced (photocraft `feature_list`).
  3. ~~Vertical type: cluster/glyph positions, `caret` and `hitTest` are wrong, and vertical box text
     takes the box width as the column length and ignores the box origin.~~ Done: photocraft's
     vertical layout (columns along the box height from its top, right edge first; upright CJK,
     rotated Latin; line-space clusters and carets, `caretSegment`, `toText`/`toLine`);
     `verticalPointAndParagraphConversionKeepTheColumnsInPlace` enabled.
  4. ~~`LineInfo.width` leaves out trailing spaces (photocraft's line extent includes them).~~
     Done (no change needed): photocraft's extent excludes them (`adv = m.advance −
     m.trailing_whitespace`, layout.rs:716), as `width` does; the new `LineInfo.trailingWhitespace`
     gives their advance.
  5. ~~CoreGraphics silently draws nothing for path coordinates around 3e9 (fine to 1e8);
     `VectorRasterizer` should clip to the canvas first (VectorCommands does for its own renders).~~
     Done: paths reaching past 1e7 px are clipped to the rendered rect (fills, strokes, dashes,
     bounds); CoreGraphics measured empty from 1e9.
* **PCRender**: ~~the Metal path composites a plain layer stack at half precision (0.5996 for 0.6)
  where the CPU reference is exact.~~ Done (resolved as by-design): `AccumulatorPrecision.automatic`
  is PCRender's measured policy (PCRender PORT-NOTES "Parity", AB-L-0248; 0.1 of an 8-bit level).
  The engine's exact reads ask for float accumulation (`EngineRenderer.renderExact`), and the
  Levels eyedropper test compares exactly again.
* **PCPaint / colour**: ~~no per-document CMYK profile scope for strokes (photocraft
  `with_cmyk_space`); strokes use the process-wide converter.~~ Done: PCFoundation
  `ColorConvert.withCMYK` (task-local, consulted before the process-wide converter); `paint.*`
  commands and live strokes enter `DocumentCMYK` (`DocumentCMYKTests`).
* **PCIntelligence**: ~~`InpaintProvider` carries only an image and a mask, so the engine passes
  Content-Aware Fill's PatchMatch options as a task-local; an options parameter on the seam would
  be cleaner.~~ Done: `OptionsInpaintProvider` / `InpaintOptions` (default options for plain
  calls); `PatchMatchInpaintProvider` adopts it and the task-local is gone.
* **PCIO**
  1. ~~Export `PCIOFormats`, `PCIOSmart` and `PCIOMaps` as products: the engine uses `SVGImport`,
     `Linked`, `SmartMap`, `PatternMap` and `DisplaceMap` through implicit imports (SwiftPM builds
     them, but they are not declared dependencies).~~ Done: declared dependencies of `PCEngine`
     (all three) and `PCEngineTests` (`PCIOSmart`).
  2. ~~The flat import does not record `Document.fileEncoding` (photocraft `io::flat` sets it from
     the file's JPEG tables / WebP chunk); `EngineIO.importFile` fills it in meanwhile.~~ Done:
     PCIO records it; the stopgap and `EngineIO.fileEncoding` are removed. The engine still sets a
     lossy WebP's quality after the import (`SourceSettings.webpQuality`, ±1; PCIO doesn't link
     PCPlatform and records photocraft's 75): `aReopenedLossyWebPSavesAtItsOwnQuality`.
* **PCPlatform** (files)
  6. ~~`SourceSettings.webpEncoding` keeps a lossy WebP's base quantiser, not a quality on libwebp's
     scale, so a reopened lossy WebP saves at photocraft's default 75.~~ Done:
     `SourceSettings.webpQuality(_:)` inverts libwebp's quality → quantiser map (within ±1, top
     stays lossy); `EngineIO.importFile` uses `SourceSettings.webpQuality(data) ?? 75`.
* **PCRender**: Satin changed today (`EffectMaps.satinMap` / `satinLUT`): it differences the offset
  copies, blurs, and reads the contour directly, fitted to PCRender's own Photoshop corpus. photocraft's
  `contour_presets_match_photoshop` (measured in Photoshop 27.11: Cone and Cone − Inverted Satins
  are identical; Gaussian reads 0.36 at 0.5 through Satin) assumes photocraft's reversed `|v − end|`
  transfer, and fails against the new LUT. The two measurements disagree; PCRender should settle it
  against Photoshop. The five Satin expectations are a `withKnownIssue` in `LayerStyleTests`.
