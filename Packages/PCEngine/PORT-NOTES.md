# PCEngine — port notes

Port of **photocraft-engine** (`crates/engine`), **photocraft-automation** (`crates/automation`) and
**photocraft-cli** (`apps/photocraft-cli`) to Swift 6 (photocraft revision `184c226a`, 2026-10-12).
MIT OR Apache-2.0, © ArtCraft Team and the PhotoCraft contributors. photocraft's behaviour is the
spec: command ids, labels, menu paths, shortcuts, params notation, history step names, result JSON
and error messages are kept verbatim, and photocraft's tests are ported one for one.

## Status

All 892 command ids of photocraft's catalogue are registered with photocraft's label, menu path,
shortcut and params notation: **887 implemented, 5 stubbed** (`plugin.*`, the WebAssembly plug-in
host), **0 not registered**. 20 more ids are registered that photocraft's engine doesn't have: the
seven File-menu ids its app shell owns (`file.open`, `file.save`, `file.saveAs`,
`file.export.exportAs`, `file.export.quickExportAsPng`, `file.clearRecent`, `file.removeRecent`),
nine PCIntelligence commands, and the four filter adjustment layers (AB-T-0258:
`layer.newAdjustmentLayer.grain`, `.addNoise`, `.gaussianBlur`, `.motionBlur`, created with
Compositor's settings and edited by `layer.setAdjustment`; Grain's and Add Noise's `seed` defaults
to one derived from the new layer's id, and a reset keeps it). Files go through PCIO (PSD, PSB, .pcraft, OpenRaster, layered
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
  `file.clearRecent`, `file.removeRecent`), so every frontend opens and saves the same way.
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
  commands (jobs with receipts). PCAlgo's PatchMatch is registered in the `inpaint` slot as
  `.classical`; Content-Aware Fill passes photocraft's sampling and adaptation options to it
  through PCIntelligence's `OptionsInpaintProvider` seam (`ContentAwareFillOptions.inpaint`).
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
