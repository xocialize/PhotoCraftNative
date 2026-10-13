# PCDocument — port notes

Port of **photocraft-doc** (`crates/doc/src/*.rs`), the warp/affine parts of **photocraft-geom**
(`crates/geom/src/{lib,warp}.rs`) and **photocraft-ops** (`crates/ops/src/{lib,tiles}.rs`), plus
the History snapshots of `crates/engine/src/history_cmds.rs` and the operation/transaction layer
of `docs/architecture.md` §6. photocraft revision `184c226a` (2026-10-12). MIT OR Apache-2.0,
© ArtCraft Team and the PhotoCraft contributors.

Status: complete for the three crates. `swift build` / `swift test` are clean (no warnings):
**156 test functions** (126 in `PCDocumentTests`, 30 in `PCHistoryTests`; 5 history tests are
parameterised over U8/U16/F32), including **all 94 photocraft `#[test]`s** of doc (58), geom
(8 + 13) and ops (15).

## Layout

| Module | Contents | photocraft |
|---|---|---|
| `PCDocument` | document model, layer tree, geometry (affine, points, warps) | `photocraft-doc`, `photocraft-geom` (warp + affine) |
| `PCHistory` | `History`, tile ledger, snapshots, `DocumentOp`/`EditTransaction` | `photocraft-ops` (+ engine snapshots, arch §6) |

Both depend on `../PCFoundation` only. `PCHistory` depends on `PCDocument` (as ops → doc).

## File-by-file map

| photocraft | Swift | Notes |
|---|---|---|
| `doc/src/lib.rs` ids, `ensure_ids_above` | `PCDocument/Ids.swift` | one `Atomic<UInt64>` counter shared by `LayerId`, `SmartContentsId`, `DocId`; JSON = bare number |
| `doc/src/lib.rs` `Locks`, `LabelColor`, `LayerMask`, `Group`, `SmartObject`, `SmartSource`, `SmartFilter`, `LayerContent`, `Layer`, `MAX_GROUP_DEPTH` | `PCDocument/Layer.swift` | + in-place mutators (`withRaster`, `withChildren`, `withGroup`, `withText`, `withShape`, `withSmartObject`) |
| `doc/src/lib.rs` `Effects` | `PCDocument/Effects.swift` | (with effects.rs) |
| `doc/src/lib.rs` `Fill`, `FillCache` | `PCDocument/Fill.swift` | `Fill::gradient(..)` → `GradientFill(stops:angle:scale:style:reverse:)` |
| `doc/src/lib.rs` `TextLayer`, `normalize_runs` | `PCDocument/Text.swift` | (with text.rs) |
| `doc/src/lib.rs` `Guides`, `GuideColor`, `ColorIndicates`, `AlphaChannel`, `Metadata`, `Document`, `FileEncoding`, `LayerPath`, tree helpers | `PCDocument/Document.swift` | `from_rgba` → `PixelFormat.components(fromRGBA:)` |
| (new) | `PCDocument/LayerTree.swift` | id → path index, navigation, placements, insert/move/group/ungroup, `reassignLayerIds` |
| (new) | `PCDocument/LayerProperties.swift` | a layer's pixel-free properties as one value (`SetLayerProps`) |
| `doc/src/adjust.rs` | `PCDocument/Adjust.swift` | curve maps, `lut3d_len`, `HueRange` maths, every `Adjustment` |
| `doc/src/advanced.rs` | `PCDocument/Advanced.swift` | |
| `doc/src/analysis.rs` | `PCDocument/Analysis.swift` | `Measurement` → `MeasurementSettings` |
| `doc/src/blend_if.rs` | `PCDocument/BlendIf.swift` | `[BlendRange; 2]` → `BlendRangePair` |
| `doc/src/comps.rs` | `PCDocument/Comps.swift` | free fns → `Document.captureCompStates()`, `nextCompId()`, `Layer.positionBounds`, `compPosition` |
| `doc/src/effects.rs` | `PCDocument/Effects.swift` | `Gradient` → `StyleGradient` |
| `doc/src/mode.rs` | `PCDocument/Mode.swift` | |
| `doc/src/pattern.rs` | `PCDocument/Pattern.swift` | ids are bit-identical to photocraft's (FNV-1a + Rust `Debug` of the format; cross-checked) |
| `doc/src/slices.rs` | `PCDocument/Slices.swift` | `resolve(doc)` → `Document.resolvedSlices()`, `base_name` → `sliceBaseName` |
| `doc/src/text.rs` | `PCDocument/Text.swift` | `Orientation` → `TextOrientation` |
| `doc/src/text_styles.rs` | `PCDocument/TextStyles.swift` | attribute sets are `[String: JSONValue]` keyed by the serde field names |
| `doc/src/variables.rs` | `PCDocument/Variables.swift` | `Value` → `VariableValue` |
| `doc/src/vector.rs` | `PCDocument/Vector.swift` | `Path` → `VectorPath`; + `Subpath.cgPath`, CG fill-rule/cap/join bridges |
| `doc/src/video.rs` | `PCDocument/Video.swift` | |
| `geom/src/lib.rs` `Point`, `Affine` | `PCDocument/Geometry.swift` | `PCPoint`, `PCAffine` (+ CG/simd bridges); `Rect`/`Size`/`TileCoord` are PCFoundation's, saturating helpers added (`xywh`, `init(size:)`, `translated`, `inflated`) |
| `geom/src/warp.rs` | `PCDocument/Warp.swift` | points `SIMD2<Double>`, boxes `SIMD4<Double>` = `[x0,y0,x1,y1]` |
| serde plumbing | `PCDocument/Coding.swift` | externally tagged enums, defaults, fixed arrays, `JSONValue` (= `serde_json::Value`), `PSDKey` |
| (new) | `PCDocument/Errors.swift` | `DocumentError` (the "never crash" error type) |
| `ops/src/lib.rs` | `PCHistory/History.swift` | + named snapshots from `engine/src/history_cmds.rs` |
| `ops/src/tiles.rs` | `PCHistory/TileLedger.swift` | |
| arch §6 (no photocraft code) | `PCHistory/Ops.swift` | `SurfaceRef`, `TilePatch`, `DocumentOp`, `EditTransaction`, `History.commit` |

## Key entry points

- **Model:** `Document` (`withBackground`, `pixelFormat`, `bounds`, `layers`, channels, selection, …),
  `Layer` (`raster`, `group`, `content`, `surface`, `duplicate`, `properties`), `LayerContent`
  (`raster/group/adjustment/fill/text/shape/smart`), `LayerGroup`, `LayerMask`, `VectorMask`,
  `Effects`/`Effect`, `Adjustment`, `Fill`, `TextLayer`, `ShapeLayer`, `SmartObject`, `Pattern`,
  `LayerComp`, `Artboard`, `Slices`, `Variables`, `Timeline`, `VideoData`, `BlendIf`,
  `AdvancedBlending`, `Warp`/`BezierMesh`, `PCAffine`/`PCPoint`, `VectorPath`.
- **Tree:** `path(of:)` (O(1) after first use), `layer(_:)`, `layer(at:)`, `walk()`, `forEachLayer`,
  `forEachLayerMut`, `updateLayer(_:_:)`, `updateLayer(at:_:)`, `withRaster(of:_:)`,
  `updateBackground`, `parent(of:)`, `children(of:)`, `siblings(of:)`, `ancestors(of:)`,
  `descendants(of:)`, `isDescendant`, `insert(_:at: LayerPlacement)`, `insertAbove`, `remove`,
  `shift`, `move(_:to:)`, `groupLayers`, `ungroup`, `reassignLayerIds`, `effectiveLocks`.
- **History:** `History` (`record`, `undo`, `redo`, `entries`, `state(_:)`, `trim`, `maxStates`,
  `maxBytes`, `pixelBytes`, `uniqueBytes`, `purgeLast`, `clearRedo`, `takeSnapshot`,
  `restoreSnapshot`, `commit`), `LayerTarget`, `DocumentOp`, `EditTransaction`, `TilePatch.changes(from:to:)`.

## Deliberate deviations

1. **Names.** Swift's flat namespace and SwiftUI/Foundation clashes: `Path`→`VectorPath`,
   `effects::Gradient`→`StyleGradient`, `Group`→`LayerGroup`, `Measurement`→`MeasurementSettings`,
   `text::Orientation`→`TextOrientation`, `variables::Value`→`VariableValue`, `Point`→`PCPoint`,
   `Affine`→`PCAffine`, `Color`→`PCColor` (PCFoundation), `MAX_GROUP_DEPTH`→`maxGroupDepthLimit`
   (`Document.maxGroupDepth` is the port of `max_group_depth()`), `Knockout::{to,from}_psd` →
   `psdValue`/`init(psdValue:)`. Methods are camelCase; Rust getters became properties.
2. **Enum payloads.** Variants with several fields carry nested payload structs
   (`Adjustment.Levels`, `Effect.PatternOverlay`, `Contour.CustomContour`, `FxPaint.PatternRef`,
   `TextShape.TextBox`, …) so they can be mutated and passed around; small ones use labelled
   associated values. JSON is serde's (externally tagged `{"Levels":{…}}`, units as `"Invert"`;
   internally tagged `VarKind`/`LiveShape`; adjacently tagged and flattened `DataValue`).
3. **Tuples and fixed arrays.** `(f32, Color)` → `ColorStop`, `(f32, f32)` → `OpacityStop` or
   `SIMD2<Float>`, `(f32, [f32;3])` → `GradientMapStop`, `[BlendRange;2]` → `BlendRangePair`, all
   encoded as JSON arrays like serde; `[T; n]` → SIMD types or arrays whose length is checked on
   decode. `Arc<Vec<u8>>` → `[UInt8]` (copy-on-write); PSD tuples → `PSDLayerBlock`, `PSDResource`,
   `PSDGlobalBlock` (with `PSDKey`), `MetadataText`; `AlphaChannel.spot` → `SpotInk`.
4. **`&mut` access.** Rust's `layer_mut`/`surface_mut`/`children_mut` became closure-based in-place
   mutators. They swap the enum payload out while mutating, so tiles and child arrays stay uniquely
   referenced: an unshared document is edited in place at any depth, and with a snapshot alive only
   the touched tile is copied, once (`editsOfAnUnsharedDocumentHappenInPlace`).
5. **Layer index.** photocraft searches the tree for each lookup; here `Document` caches an
   id → path map, dropped by `layers`' `didSet` and kept by in-place edits that leave the subtree's
   shape unchanged. Copies share it until one changes its tree. It never takes part in `==`.
   Mutating `layers` directly is still allowed (it just costs a rebuild on the next lookup).
6. **Tree helpers beyond photocraft-doc.** `LayerPlacement` insert/move with validation (missing
   targets, cycles, duplicate ids, `maxGroupDepthLimit`; failures leave the document unchanged),
   `groupLayers`/`ungroup`, navigation, and `reassignLayerIds` (the engine's
   `reidentify_copied_layers`, which also remaps variables and layer-based slices here).
7. **Codable scope.** Exactly the serde types are Codable (plus `Effects`, harmless). Types holding
   a `Surface` (`Document`, `Layer`, `LayerContent`, `LayerMask`, `TextLayer`, `ShapeLayer`,
   `SmartObject`, `Pattern`, `AlphaChannel`, `VideoData`, comps) are not, as in photocraft (the
   native `.pcraft` format is `photocraft-format`, not ported here).
8. **Optionals in JSON.** Swift's encoders omit `nil`; serde writes `null`. Both forms decode either
   way. Exception: `CharStyle`/`ParagraphStyle` write `null` explicitly, because text-style
   attribute sets must be able to name (and clear) every field, as photocraft's do.
9. **History values.** `Arc<Document>` → `Document` values (copy = O(1) snapshot). A tile is
   identified by PCFoundation's `Tile.generation` (copied with the tile, renewed on every write)
   instead of an `Arc` address; all 15 accounting tests pass unchanged. The ledger also counts
   fill caches, smart-filter masks and document patterns (photocraft's skips them). `Arc::ptr_eq`
   checks became `==`.
10. **Snapshots** (camera button) live in `History` (`takeSnapshot`, `renameSnapshot`,
    `deleteSnapshot`, `restoreSnapshot` = one undoable state keeping the current id/name), ported
    from the engine's `history_cmds.rs`; "merged layers"/"current layer" snapshot sources need the
    compositor and stay in the engine.
11. **Ops/transactions are new.** photocraft-ops records whole-document snapshots only. Following
    architecture §6, `DocumentOp` (`paintTiles`, `replaceSurface`, `setSelection`,
    `setLayerProperties`, `setLayerMask`, `replaceLayer`, `insertLayer`, `removeLayer`, `moveLayer`,
    `replaceDocument`, `setDocumentProperties`) returns its inverse when applied; `EditTransaction`
    applies atomically; `History.commit` applies and records. Ops address layers by id, so a job's
    transaction rebases onto a newer document or fails with a `DocumentError` (tested). History
    still stores snapshots. `setDocumentProperties(DocumentProperties)` carries only the fields an
    edit changed among the canvas size, guides, the Paths panel (`DocumentPaths`: saved paths, work
    path, clipping path), slices and notes; it replaces each carried field whole (as
    `setLayerProperties` replaces a layer's properties) and leaves layers, selection and the other
    fields alone, so it rebases where `replaceDocument` can't (`DocumentPropertyOpsTests`).
12. **Never crash.** Malformed input returns errors or neutral values instead of trapping: fixed
    array lengths are checked when decoding, warp meshes with bad knots/point counts evaluate to
    zero and refuse splits/drags, rect helpers saturate, `Timeline.step` saturates, indices are
    bounds-checked (`effectiveOp`, `BlendIf.get`, `ColorTable.rgb`).
13. **Small API additions.** Convenience initialisers with Photoshop defaults (`Shadow`, `Glow`,
    `Bevel`, `ShapeStroke`, …), `Effects.hasVisibleEffects`, `Effect.isEnabled` settable,
    `GradientFill.midpoint(_:)`, `SmartObject.perspectiveMatrix`, `Layer.adjustment`/`fill`,
    `TextStyles` subscripts for `char_style_mut`/`para_style_mut`, `Slices[id:]` for `get_mut`.

## PCFoundation change requests

1. **serde-compatible Codable for `ColorMode`, `SampleType`, `BlendMode`, `PCColor`.** They encode
   raw numbers (`"mode":3`, `"blend":1`); photocraft writes names (`"Rgb"`, `"U8"`, `"Normal"`).
   Everything else here matches photocraft's JSON field-for-field, so colours and blend modes are
   the only incompatible fragments (e.g. a `FxCommon` or `Fill.solid` from photocraft won't
   decode). Can't be fixed from this package (no way to override an existing conformance).
2. **`Surface.readRegion(_:into:)` should size `out` itself** (photocraft's `read_region_into`
   resizes); today a short buffer is written out of bounds in release builds.
   `LayerMask.values(_:into:)` sizes it before calling.
3. **A public `Tile` initialiser** (e.g. `Tile(bytes:)` validating the size) so tile patches can be
   built or decoded (native format, history persistence) without painting through a `Surface`.
4. **Saturating `PixelRect` construction/offset** (`init(x:y:width:height:)`, `offsetBy`,
   `PixelSize.rect` trap on Int32 overflow; photocraft saturates). This package adds saturating
   variants and uses them for document bounds.
5. Nice to have: an unsorted tile sequence on `Surface` (history accounting calls `tileCoords`,
   which sorts, for every surface it visits).

## Requests from other packages (done 2026-10-12)

- **PCEngine 1, `setDocumentProperties`:** above (deviation 11); the engine's `TransactionBuilder`
  emits it instead of `replaceDocument` for those fields.
- **PCEngine 2, `withBackground`:** fills through `Surface.fill`, which shares one tile per whole
  tile and per missing edge shape: a 100 003 × 70 001 Background holds 4 tile buffers
  (`BackgroundScaleTests`).
- **PCEngine 3, `resolvedSlices()`:** was ≈ 17 s for 10 000 slices in Debug. `autoSlices` visited
  every grid cell and tested it against every slice (cubic), and every resolved slice looked its
  stored slice up linearly. Now a band sweep keeps a coverage count per column cell in a segment
  tree (`CoverCounts`) and reopens only the free runs next to the columns where a slice starts or
  ends: O((n + output) log n). Output is identical to the grid scan (400 random layouts compared in
  `autoSlicesMatchTheGridScan`); `tenThousandSlicesResolveFast` resolves three 10 000-slice
  documents (a full grid, a grid with 10 201 gaps, random overlaps) in 0.4–0.6 s together, Debug.
- **PCIO 5:** `remEuclid` is public; `TextRun.len` / `ParagraphRun.len` decode saturating
  (`u64` lengths beyond `Int.max` become `Int.max` instead of failing the document).

## Left / out of scope

- Nothing of doc, ops or the warp/affine parts of geom is left out. Rendering of adjustments,
  effects, fills, text and vectors (compose/gpu/text/vector crates), the `.pcraft` format and the
  doc⇄PSD mapping belong to the other ports.
- Engine-level helpers that only touch the model but live in the engine (e.g. `scale_effects`,
  comp application, merged-layer snapshots) were not ported.
- `ops/examples/bench_history_trim.rs` (a micro-benchmark) was not ported.
