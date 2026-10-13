# PCFoundation — port notes

Port of **photocraft-geom** (rects, tiles), **photocraft-color** and **photocraft-raster**
(photocraft revision `184c226a`, 2026-10-12), MIT OR Apache-2.0, © ArtCraft Team and the PhotoCraft
contributors. The other packages' change requests landed here on 2026-10-12; this file records
what changed and why. `swift build` / `swift test` are clean (no warnings): **28 tests in 10
suites**.

## Requests done (2026-10-12)

1. **`TileCoord.rect` saturates** (PCEngine 1) like photocraft's `Rect::from_xywh`: the last tile
   column/row before `Int32.max` (pixels from 2 147 483 392) ends at `Int32.max` instead of
   trapping. `contentBounds` saturates the same way for a pixel at `x = Int32.max`.
   `TileOverflowTests` ports photocraft #963's selections (most negative corner, origin,
   `Int32.max − 2`).
2. **`Surface.converted(to:)` adds or drops alpha** (PCEngine 2), with photocraft `convert`'s
   same-model semantics: colour channels convert as they are, an added alpha is 1, a removed one is
   dropped without compositing; the default pixel converts the same way and tiles shared across
   coordinates convert once. A colour-model change still traps (`precondition`): those go through
   RGBA (`readRGBA` / `writeRGBA`, PCEngine's `convertedAny`, PCIO's own mappers).
3. **Shared solid-tile fill** (PCEngine 3, photocraft #705). `fill` puts one copy-on-write tile at
   every whole tile it covers. Tiles it covers in part are written and keep their other pixels;
   where such a tile was missing, the rest is the default pixel, so missing edge tiles with the
   same filled part share one tile too. A 65 536² fill holds one buffer; a later edit copies only
   the tile it touches (`SharedFillTests`).
   *Generation stamps:* a stamp changes on every mutation and copies of a tile keep it, so "same
   stamp ⇒ same bytes" holds wherever the tile sits. Every cache keyed by stamp was checked:
   PCRender's residency and fingerprints key by (coordinate, stamp), `ContentBounds` and PCIO's
   content-hash cache by stamp alone (bytes identical, so a shared tile is scanned or hashed once),
   PCHistory's ledger counts a shared tile once, `TilePatch.changes` compares per coordinate.
4. **Debug speed** (PCEngine 4, PCAlgo 5). `contentBounds` and `prune` compare rows with `memcmp`
   against a default-pixel row (and scan a tile shared across coordinates once); region reads and
   writes, `pixel`, `setPixel`, `fill`, `readInterleaved`, `converted`, `writeRGBA` / `readRGBA` and
   `FloatImage`'s clamped read, `bilinear`, `mixed`, `premultiply` / `unpremultiply` run on raw
   pointers with one format switch per row (`SampleRun`). Decoding uses exact tables
   (`Float(i) / 255`, `Float(i) / 65535`), f32 rows are `memcpy`, encoding repeats `writeSample`'s
   arithmetic without generic `min`/`max`. Values are bit-identical to the per-sample code:
   `FastPathTests` checks every 8- and 16-bit code, awkward floats (NaN, ±0, ±∞, rounding edges),
   random regions over 11 formats, bounds and prune against the per-sample definitions.
   Timings below.
5. **Scoped CMYK converter** (PCEngine's PCPaint/colour request, photocraft `with_cmyk_space`):
   `ColorConvert.withCMYK(_:_:)` (sync and async) binds a task-local converter that
   `cmykToRGB` / `rgbToCMYK` (single and batch) consult before the process-wide `ColorConvert.cmyk`;
   `nil` inside a scope means the process-wide one again; `activeCMYK` is the one in force.
   Task-local rather than photocraft's thread-local: it follows child tasks, but work handed to a
   `DispatchQueue` or `Task.detached` must enter it itself (`CMYKScopeTests`, four parallel tasks).

6. **`ColorConvert.mul` is public** (PCIO request 3). The other half of that request,
   `converted(to:)` across colour models, is still open (see 2).

## Debug `swift test` wall time (M5 Max, before → after)

`swift build --build-tests`, then a timed `swift test` (wall clock, including the no-op build
check). "Before" ran on a copy of the three packages taken before any change. The machine was
shared (other agents' builds, Photoshop; load average 30–48), so PCAlgo is given as the range of two
runs each:

| Package (Debug) | Before | After | Tests before → after |
|---|---:|---:|---|
| PCFoundation | 3.9 s | 4.2 s (≈ 3 s of it the new `FastPathTests`' per-sample reference loops) | 15 → 28 |
| PCDocument | 5.6 s | 3.1 s | 146 → 154 (156 with the run-length tests) |
| PCAlgo | 482–519 s | 324–344 s | 665 → 665 |

PCPaint's suite went from ~90 s to ~50 s in passing. A 20 s `sample` of PCAlgo's tests after the
change shows PCFoundation in under 1 % of the stacks: what is left is PCAlgo's own CPU references
(the generic `FilterEngine.run`, `ResampleKit.runCPU`'s nested closures, `parallelChunks`) and the
Swift runtime's tuple and generic metadata lookups (`swift_getTupleTypeMetadata`,
`IndexingIterator.next`) that unspecialised generic code costs in Debug.
