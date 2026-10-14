# Wave 3 plan: the app shell (Compositor UI on the PhotoCraftNative engine)

The point of this document is to decide, before any code moves, what of Compositor we keep, what
PhotoCraftNative replaces, what we combine, and which layered file format is the default. It then lists
what to ask other fleet areas for. Status: **decided** 2026-10-13 (AB-D-0131, AB-D-0132); asks and tasks filed (see the end).

## The short version

- **Compositor's strength is its app layer; PhotoCraftNative's is the engine.** Compositor has a polished
  macOS shell: tabs, a native layers panel, menus, remappable shortcuts, a command palette, floating
  panels, canvas interaction and overlays, and Camera Raw panels. Underneath it is an 8-bit sRGB document,
  Core Image blending in sRGB, 12 adjustment kinds and 6 effects, PSD reading only, and whole-document
  undo snapshots. PhotoCraftNative is the reverse: an engine with 887 photocraft commands, a Metal
  compositor that matches 141 of 150 Photoshop composites, PSD/PSB that Photoshop opens 1,524 of
  1,524 times, and about 3,900 tests. It has no UI.
- **Plan: Compositor's UI over PhotoCraftNative's engine.** Keep the shell and its views. Replace the
  model, renderer, undo, tools' engines, filters, formats and colour management. Rebind the views
  to PCEngine's `Session`.
- **Don't build on Compositor's `main`.** That branch is the reference ("oracle") Forge Canvas
  regenerates its parity fixtures from (`CompositorTests/CanvasFixtureGenerator.swift`; AB-T-0168, run
  from mlx-image; packages in mlx-forge). Its save format and render output must stay as they are.
  Nobody runs Compositor as a product (Forge Canvas PRD:168).
- **Default format: `.pcraft`, saved as a macOS document package. PSD/PSB are first-class for exchange.**

## Keep, replace, or combine

Sizes are approximate. "PCN" means PhotoCraftNative.

| Subsystem | Compositor today | PhotoCraftNative | Decision |
|---|---|---|---|
| Window, tabs, menus, shortcuts, command palette, floating panels | Strong: SwiftUI `Window` + `ProjectWorkspace` tabs, remappable `ShortcutChord`, command palette (~10K lines) | None (engine and `pccli` only) | **Keep.** Generate menus and shortcuts from PCEngine's command registry (892 ids with labels, menu paths and shortcuts) instead of the hand-built menus in `CompositorApp.swift` |
| Layers panel | AppKit `NSTableView`, 1,454 lines | — | **Keep and extend**: rows for adjustment, fill, smart-object, vector-mask and effects state, plus clipping and linking |
| Document model | `CanvasDocument`: flat array, 8-bit sRGB, flags for layer kinds | `PCDocument`: tiled copy-on-write, every mode and depth, smart objects, vector masks, comps, slices | **Replace** with PCDocument |
| Session and state | One `@Observable EditorSession`, 1,074+ lines | PCEngine `Session`, command registry, jobs, preferences | **Replace.** Keep a thin `@Observable` view-model that mirrors PCEngine state for SwiftUI |
| Undo and history | Whole-document snapshots, 100 entries / 256 MB | PCHistory: reversible, rebaseable ops | **Replace** |
| Canvas rendering | Core Image in sRGB on `CAMetalLayer`, plus a Core Graphics fallback; two compositors kept in agreement | PCRender `MetalCompositor` + `CanvasRenderer`, damage-limited redraws, display LUT, CPU/Metal parity | **Combine**: keep Compositor's canvas view, viewport, zoom and pan; draw through PCRender |
| Overlays (transform handles, marching ants, guides, rulers, crop, grid) | Strong | Geometry only, no UI | **Keep**, driven from PCEngine state |
| Brush, eraser, healing, clone | Metal brush; no presets, dynamics or pressure | PCPaint: presets, dynamics, ABR import, pressure and tilt (PCPlatform tablet), Metal bit-exact to CPU | **Replace** the engines; keep the tool rail and options-bar UI |
| Selection | `CGPath` + feather, Vision object select | PCEngine selection masks and Quick Mask, PCIntelligence (Select and Mask is a UI-owned id) | **Replace** the engines; keep the marching-ants and tool UI |
| Transform, distort, liquify | Affine, free distort baked on apply | PCAlgo warps, Liquify, mesh warp, perspective | **Replace** the engines; keep the handles UI |
| Type | `NSLayoutManager` + inline `NSTextView` editor | PCPlatform `TextEngine` (CoreText; vertical type, kerning, paragraph) | **Combine**: Compositor's inline editor over PCPlatform layout and rendering |
| Shapes and vectors | Rasterised with metadata; no pen or paths | PCDocument paths and shapes, PCPlatform `VectorRasterizer` | **Replace**. A pen/path tool UI is new work |
| Filters | 12 destructive filters | PCAlgo: 73 filter types, Filter Gallery, Camera Raw filter | **Replace**; keep the floating filter-panel pattern for dialogs |
| Camera Raw | Panels + 1.25 MB of lookup tables measured from Photoshop's Camera Raw | PCAlgo Camera Raw filter, PCPlatform `CIRAWFilter` develop | **Combine**: keep the panels, use PCAlgo's engine. The tables conflict with AB-D-0130 (see decisions) |
| AI features | Vision select subject; C PatchMatch | PCIntelligence: Vision, Kits, PatchMatch, ForgeCore seams | **Replace** |
| Colour management | sRGB working space, CMYK proof | PCPlatform ColorSync, profiles, proofing, display LUT | **Replace** |
| Native file | `.comp` v13 (8-bit/16-bit/EXR PNG layers, sRGB) | `.pcraft` (PCFormat) | **Replace** as the default. Keep `.comp` **import** for existing Compositor and agent-written files |
| PSD / PSB | Read only, 8-bit, RAW/RLE | PCPSD + PCIO, full read/write; Photoshop opens 100 % | **Replace** |
| Flat import/export, RAW | ImageIO, RAW develop sheet, EXR | PCPlatform codecs, ImageBridge, webp-swift | **Replace** the engines; keep the RAW develop sheet UI |
| Automation | Agents write `.comp` and the app live-reloads | PCEngine control channel + MCP server (`pccli`) | **Replace** with PCEngine's control/MCP. The `.comp` live-reload stays only for imports |
| Preferences | `@AppStorage`, no Settings scene | PCEngine `Preferences` (photocraft's set) | **Combine**: PCEngine as the source of truth, plus a SwiftUI Settings scene |
| Updates | Sparkle, pointed at **upstream's** feed and key | — | **Decide** (identity, below). It can't ship as is |
| C kernels | `AdjustPixels.c` etc., 3.9K lines | PCAlgo / PCRender | **Remove** once replaced |
| Tests | 639 tests + a screenshot UI test | ~3,900 engine tests in the packages | Keep the UI tests that still apply; engine tests stay in the packages |

### Engine work the UI will need first

1. A `@MainActor` view-model adapter over `Session`: active document, layers, selection, tool state, and
   damage notifications for redraw.
2. A canvas view that hosts PCRender's `CanvasRenderer` in Compositor's `CAMetalLayer` view. Viewport
   maths stay Compositor's.
3. Menu and shortcut generation from PCEngine's registry. Some ids are UI-owned (View 55, Window 61,
   Type 14, Edit 7, File 6, Select and Mask) and the shell needs to implement them.
4. A `.comp` importer in PCIO, mapping 8-bit/16-bit/EXR layers, masks, groups, the 12 adjustments and
   6 effects.

## Default layered format

Measured facts are in `Tools/PhotoshopOracle/RESULTS.md`, each package's `PORT-NOTES.md`, and the
format comparison gathered for this plan.

| | Keeps the whole document | Save speed and scale | Opens elsewhere | Status |
|---|---|---|---|---|
| **`.pcraft`** | Yes: 153/153 Photoshop-authored and 36/36 Unity documents round-trip equal; everything except undo history | Incremental, content-addressed 256-px zstd tiles. A whole-document save takes ~0.1 s and a load ~40 ms. 300k px per side. The single file is ZIP64 past 4 GiB or 65,535 entries (format 2, AB-T-0240); the package form has no limit | photocraft only | Read/write done, 118 tests |
| PSD / PSB | Nearly: drops Bitmap/Indexed/Duotone writing, 32-bit CMYK/Lab, timeline, variables and video, and embeds linked smart objects | Whole-file rewrite on every save, fast (a 5.2 GB PSB writes in 0.44 s); PSB to 300k px | Photoshop 1,524/1,524; ImageIO; others unmeasured | Read/write done, 255 + 820 tests |
| `.comp` | No: sRGB 8/16-bit, no vector masks, smart objects or CMYK | Re-encodes every layer (~2.9 s per 24 MP 16-bit layer) | Compositor only | Compositor's |
| OpenRaster / layered TIFF | No / as PSD | Whole rewrite | Krita / Photoshop | Read/write done |
| A new format of our own | — | — | — | Not needed: `.pcraft` already is one, and it's photocraft-compatible |

**Recommendation:** `.pcraft` is the native default, saved as a **macOS document package** (the
directory form). That gives incremental saves, no 4 GiB limit, and atomic replace, and Finder shows it as
one file. The single-file ZIP form is for sharing ("Save a Copy… → single file"). It gets ZIP64 so it
loses its 4 GiB limit, as a `.pcraft` format v2 with a migration from v1.
- **Save** on a document opened from a PSD keeps it a PSD, with a warning when the document holds
  something PSD can't keep. That's photocraft's own behaviour.
- **Open and Save As** handle PSD/PSB first-class.
- **Crash recovery** uses `.pcraft`, as it already does.

`.forgedoc` (Forge Canvas, 16-bit PNG layers) is simpler than either. An importer is optional and later.

## Where the app lives

- **Compositor fork `main`** stays as it is: it tracks upstream and Forge's fixture generator.
- **The app** gets its own repository, created from the Compositor fork's history so the UI code keeps
  its git history and MIT attribution. Its first commit renames it and drops upstream's Sparkle feed, key
  and bundle id.
- **PhotoCraftNative** moves to its own repository with **one root `Package.swift`** that exports every
  package as a product, tagged `0.1.0`. Fleet rule AB-D-0023 requires URL dependencies, and SwiftPM can't
  consume packages from a repo's subfolders. This also lets other areas use PCPSD/PCIO; Pixel Agency is
  planning PSD interop.

## Prerequisites to ask other areas for

| To | What | Why |
|---|---|---|
| agent-bridge | An effort id for this work (e.g. `photocraft`) | No area owns PhotoCraftNative today; asks AB-A-0165/0166 were filed without a home |
| design-scaffold | **Tokens:** a compact row height for dense lists, a panel title style, a dark editor surface. **Components** (a second surface is needed: ForgeCanvasUI or Pixel Agency's editor): an editable numeric field on `LabeledSlider`, a resizable/collapsible `WorkspaceSplit`, a colour well, a layer row, a tool palette | AB-D-0042 makes DesignScaffold the design authority. Compositor's UI doesn't use it yet, and the editor needs these controls |
| mlx-forge | Replies on AB-A-0165 (Kit seams) and AB-A-0166 (Generative Fill). A ForgeCore tag that includes the pending floor raises. Guidance on declaring our Metal canvas as a `ForgeExternalTenant` (GPU tenancy) | The model tiers light up when the app links ForgeCore |
| mlx-image | Confirm that app work happens off the Compositor fork's `main` (in the new repo), so the parity oracle is untouched | They run AB-T-0168 |
| mlx-apps (Pixel Agency) | Coordinate: their planned editor + PSD interop overlaps ours. Offer PCPSD/PCIO as URL packages | Avoid building two PSD stacks |
| ourselves (new effort id) | Tasks: repo split + root `Package.swift` + tag; app repo from the Compositor history; view-model adapter; canvas on PCRender; registry-driven menus; `.comp` importer; `.pcraft` v2 (ZIP64, package UTI) | The build order |

## Decisions (operator, 2026-10-13)

1. **Default format:** `.pcraft` document package, with PSD/PSB first-class. Recorded as **AB-D-0131**.
2. **Where the app lives:** a new app repo from the Compositor history, plus a PhotoCraftNative package
   repo. Compositor's `main` stays Forge's oracle. Recorded as **AB-D-0132**.
3. **Camera Raw tables:** dropped (AB-D-0139, AB-T-0241). PCAlgo's Camera Raw sliders are Photoshop's behaviour, fitted
   (`Packages/PCAlgo/Sources/PCAlgo/Tone/CameraRawModel.swift`, `Tools/CameraRawFit`); the editor's panels draw with them.
4. **Owner:** a new effort id `photocraft` (ask AB-A-0167).

5. **Identity and distribution (AB-D-0133):**
   - Name **PixelAgencyEditor**, bundle id `com.xocialize.pixel-agency-editor`, team **CFZS6RXUCP**.
   - **Mac App Store** for distribution and updates; Sparkle is removed.
   - It follows Pixel Agency's shared app requirements APP-1–10: sandbox, user-chosen working and models
     folders, App Store-ready, MDM-friendly.
   - When Pixel Agency Desktop reaches MVP, PixelAgencyEditor becomes its **editor option**, covering
     Desktop's DESK-1–14 editor requirements on this engine.

Still to settle with mlx-apps (asked on AB-A-0171):
- which generative models are built in (ForgeCore in the app) and which go through the external media
  engines (MES);
- whether `.pcraft` is acceptable as Desktop's editor format. `.pcraft` v2 may add DESK-7 layer
  provenance and DESK-8 saved history (AB-T-0240);
- whether the editor ships as a separate app or as an embeddable module inside Desktop.

## Pixel Agency alignment (operator, 2026-10-13)

**Editor first, embeddable later.** PixelAgencyEditor is built to completion first, as a package-first
app: a `PixelAgencyEditorKit` package holding the editor UI and view model, plus a thin app target. Pixel
Agency Desktop later embeds the kit as its editor option. Brand/project management and the media
engines (MES) are what then make Desktop its own app.

**Documents: a container around `.pcraft`.** `.pcraft` stays the editor's default and stays photocraft-
compatible. Pixel Agency documents wrap it in a package:

```
<name>.<container>/            macOS document package
  container.json               Desktop data, keyed by stable .pcraft layer ids (u64):
                                 DESK-7 provenance (engine, model, licence, params, ticket, brand rev, owners),
                                 DESK-9/10 library version and asset links
  document.pcraft/             the editor's document, untouched by Desktop (directory form)
  history/                     optional DESK-8 journal: serialised PCHistory ops
  preview/                     flattened composite (+ optional per-layer PNGs for Forge Canvas readers)
```

The editor opens the inner `.pcraft` and keeps layer ids stable. `container.json` survives editor saves,
because the editor never writes it. Unknown `.pcraft` keys are dropped on re-save, which is why
Desktop data lives beside the `.pcraft` and not inside it. So `.pcraft` v2 (AB-T-0240) stays small:
ZIP64 and the package UTI only.
- Whether the container is **`.forgedoc` v2** (one library document type across the Forge apps; mlx-forge
  owns `.forgedoc`) or a Pixel Agency type is asked of mlx-forge.

**Built-in generative models.** Generative Fill/Expand should be built in through ForgeCore. The operator
leans towards Mage-Flow. What the fleet has measured (receipts AB-R-0298, 0463, 0464, 0476, 0507; mlx-image
TIERS bench):

| | Fill/expand evidence | Steered by a mask? | Licence | Memory at 1024² | Implied Mac tier |
|---|---|---|---|---|---|
| **FLUX.2-klein-4B** | The Image Engine's fill/extend model (provisional); extend needs a paint guard with LaMa fallback | Follows a painted mark (guarded) | Apache-2.0 | 20.5 GB resident (int4); 13.4 GB with the text encoder unloaded | 16 GB at 768², 24 GB at 1024², 32 GB+ resident |
| **Mage-Flow Edit-Turbo** | **None measured** for fill/expand. Best erase (+3.5 dB over LaMa), strong creative upscale | No: ignores marks and erases by naming the object; port is square-only | MIT | ~17 GB resident; ~10.5 GB with models taking turns (emulated 16 GB) | 32 GB resident; 24 GB measured only at 512² |
| LaMa / MI-GAN | Remove only, no prompt | Yes (mask) | Apache / MIT | ~3 GB | Any Mac |

**Recommendation:**
1. **Tiered features, not one floor.** The app runs on any Mac. Remove/Content-Aware Fill (LaMa/MI-GAN,
   PatchMatch) is always available. Generative features are on-demand downloads (APP-9), enabled by
   memory tier.
2. **Bake-off before choosing the model.** Klein-4B vs Mage-Flow Edit-Turbo on prompted fill and expand,
   using the same mask-composite route. Run at 16 GB (emulated) and on the real 24 GB M5 Pro. Measure
   quality and peak memory (asked of mlx-image).
3. **Mage-Flow's strengths** (erase by name, creative upscale) can be a higher tier or come from an engine
   whatever the bake-off shows.

## Scope: Editor vs Desktop (operator, 2026-10-13)

- **PixelAgencyEditor = image editing and optimization.**
- **Pixel Agency Desktop = collaboration and file management.**

The Pixel Agency PRD is guidance, not a constraint on the editor. **Desktop loses no features:** it adopts the editor's modules instead of building its own. The editor takes over items Desktop
planned, builds them, and hands them back to Desktop as embeddable solutions.

| Moves to PixelAgencyEditor (built here, returned as modules) | Stays with Pixel Agency Desktop |
|---|---|
| Editing: DESK-1…14, including PSD interop (DESK-13) and 16-bit/P3 (DESK-14) | Library, clients, projects, brand kits, collections, rights (CORE) |
| Optimization: OPT-1…8, 12, 13 (analyze, optimize, web delivery, conform, compare stage, batch, receipts, model steps, the built-in ForgeCore set, size-optimized renditions), adopting **ForgeOptimizerKit** v0.24.0 | Optimizer results stored as library variants (OPT-9), brand-kit delivery specs (OPT-10), background optimization driven by the ledger (OPT-11). These call the editor's optimization module |
| The **ForgeCore integration** (D-13 built-in processing, RUN-9 in-process binding), extended with the generative asks (AB-A-0166, AB-A-0173) | Variants (VAR), ownership and the optional server (SHARE), the ticket ledger |
| | MES engine operations (RUN) and engine routing. The editor's AI tools can also use MES engines for premium tiers |

Both apps follow APP-1…10 and the shared models folder (APP-8).

**Desktop has already built the optimization and ForgeCore pieces** (D1.2, D1.3, D1.4 in pixel-agency-desktop's
`docs/BUILD-PLAN.md`). The editor's modules are **extracted from that code, not rewritten**: AB-T-0244 from D1.3's
`OptimizerService`/`OptimizerWorkspace`/`TicketEnhancer` and the copied compare stage; AB-T-0245 from D1.2's normalizer
over a ForgeCore-only catalog on MESInProcess. Desktop then links them back. Its build plans record this
(pixel-agency-desktop 36a05aa).

## Filed on the bridge

| Record | To / owner | What |
|---|---|---|
| AB-A-0167 | agent-bridge | Add the `photocraft` effort id (alias `pixel-agency-editor`) |
| AB-A-0168 | design-scaffold | Editor-density, panel-title and dark-surface tokens; a heads-up on components |
| AB-A-0169 | mlx-forge | The ForgeCore tag to pin (after the floor raises), GPU tenancy for our canvas, the host checklist |
| AB-A-0170 | mlx-image | Confirm the Compositor `main` policy (Forge Canvas parity oracle) |
| AB-A-0171 | mlx-apps | PixelAgencyEditor as Desktop's editor option; the operator's answers sent (built-in generative fill, a container around `.pcraft`, editor first then embedded); PRD reconciliation asked |
| AB-A-0172 | mlx-forge | Is the container `.forgedoc` v2 (with a `.pcraft` payload and a v1 fallback), or a Pixel Agency type? |
| AB-A-0173 | mlx-image | Bake-off: Klein-4B vs Mage-Flow Edit-Turbo for Generative Fill/Expand at 16 GB (emulated) and 24 GB. Blocks the model choice in AB-A-0166 |
| AB-D-0134 | decision | Editor first, package-first (`PixelAgencyEditorKit`); Desktop embeds it later |
| AB-D-0135 | decision | Pixel Agency documents are a container around an untouched `.pcraft` |
| AB-D-0136 | decision | Editor = image editing + optimization; Desktop = collaboration + file management. The editor builds the Forge integration and optimization and returns them as modules |
| ~~AB-T-0243~~ | — | Struck: split into 0245 and 0246, so the external bake-off blocks only the generative part |
| AB-T-0245 (P1) | photocraft | ForgeCore integration module: host setup, the built-in set (OPT-12), memory tiers, GPU tenancy; returned to Desktop (blocked by 0235 only) |
| AB-T-0246 (P2) | photocraft | Built-in Generative Fill/Expand through ForgeCore, memory-tiered (blocked by 0245, AB-A-0173, AB-A-0166) |
| AB-T-0244 (P2) | photocraft | Optimization module on ForgeOptimizerKit (OPT-1…8, 12, 13), compare stage, batch; returned to Desktop (blocked by 0235, 0245) |
| AB-A-0165, AB-A-0166 | mlx-forge | (earlier) Kit seams; Generative Fill provider |
| AB-T-0234 (P1) | photocraft | PhotoCraftNative in its own repo, root `Package.swift`, tag 0.1.0 |
| AB-T-0235 (P1) | photocraft | PixelAgencyEditor repo from the Compositor history; rename; App Store entitlements (APP-1–10); remove Sparkle. **Unblocked** |
| AB-T-0236 (P1) | photocraft | View-model adapter over PCEngine `Session` (blocked by 0234, 0235) |
| AB-T-0237 (P1) | photocraft | Canvas through PCRender `CanvasRenderer` (blocked by 0236) |
| AB-T-0238 (P2) | photocraft | Menus and shortcuts from the command registry; UI-owned ids (blocked by 0235, 0236) |
| AB-T-0239 (P2) | photocraft | PCIO `.comp` importer |
| AB-T-0240 (P1) | photocraft | `.pcraft` v2: ZIP64, package UTI, Save semantics (no provenance or history; those live in the container) |
| AB-T-0241 (P3) | photocraft | Camera Raw tables dropped; PCAlgo's sliders fitted to Photoshop's (AB-D-0139) |
| AB-T-0242 (P2) | photocraft | Adopt DesignScaffold tokens; app-local editor controls (blocked by AB-A-0168, 0235) |

Repos created 2026-10-13 (private): `xocialize/PhotoCraftNative` and `xocialize/PixelAgencyEditor` (GitHub Actions off). Can start now: AB-T-0234 (root `Package.swift` and tag), AB-T-0235 (rename, identity, package-first), AB-T-0239 (`.comp` importer). AB-T-0240
(`.pcraft` v2) can start too; its scope no longer depends on mlx-apps.
