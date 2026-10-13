# PCAffinity — port notes

Swift port of **photocraft-affinity** (`crates/affinity`, MIT OR Apache-2.0, © ArtCraft Team and the
PhotoCraft contributors): a bounded, read-only reader for native Affinity documents (`.af`, and
`.afdesign`/`.afphoto`/`.afpub` from Affinity 1 and 2, container versions 8–12). It reads the archive,
the tagged object stream in `doc.dat`, the document model (spreads, artboards, layers, curves,
parametric shapes, paints, text, pixels, masks) and the embedded PNG preview. It writes nothing.
Mapping the model to PhotoCraft layers (photocraft's `crates/io/src/affinity.rs`) is a later step.

Standalone: Apple SDK only (Compression for DEFLATE, Foundation/Darwin). No other package.

## Public entry points

| Swift | photocraft |
|---|---|
| `Affinity.read(_ bytes: [UInt8], limits: Affinity.Limits = .default) throws(AffinityError) -> Affinity.Document` | `read(bytes, limits)` |
| `Affinity.preview(_:) throws(AffinityError) -> Affinity.Preview` (PNG bytes, their range in the file, width, height) | `preview(bytes)` |
| `Affinity.isAffinity(_:)`, `Affinity.header(_:)`, `Affinity.magic`, `Affinity.versions` | `is_affinity`, `container::header`, `MAGIC`, `VERSIONS` |
| `Affinity.Archive(_:limits:)`, `.read(_:)`, `.entry(_:)`, `.entryNames`, `.extracted`, `.revisions`, `.header` | `Archive::open` and its methods |
| `Affinity.Stream.parse(_:)`, `Stream.objects/root`, typed accessors (`obj`, `objs`, `f64`, `int`, `bool`, `str`, `enumeration`, `floats(_:_:count:)`, `bytes`, `entry`, `positional`, `isClass`, `classTag`) | `stream::parse`, `access.rs` |
| Model: `Document`, `Spread`, `Node` (`Node.Kind`), `Path`/`SubPath`/`Segment`, `Affine`, `Point`, `Rect`, `Blend`, `Text` (`Text.Align`), `TextRun`, `Image`, `Pixels` | `model.rs` |
| Paint: `Paint`, `Color`, `Gradient` (`.Kind`, `.Stop`, `halfPoint`), `Stroke` (`.Cap`, `.Join`, `.Align`) | `paint.rs` |
| `AffinityError` (`.malformed`, `.unsupported`, `.limit`; same messages and `description` prefixes) | `Error` |
| Product **PCAffinitySynth**: `Synth.stream`, `Synth.container`, `Synth.F`, `Synth.Method`, `Synth.zlib`, `Synth.zstd`, `Synth.crc32` | `synth.rs` (cargo feature `synth`) |

Everything lives in the `Affinity` namespace (PCFoundation also has `Blend`, SwiftUI has `Text`/`Path`/`Color`).

## File map

| photocraft (`crates/affinity/src`) | Swift (`Sources/PCAffinity`) | Notes |
|---|---|---|
| `lib.rs` | `Affinity.swift` | namespace, `AffinityError`, Rust-semantics numeric helpers (saturating casts, NaN-preserving clamp, `rem_euclid`) |
| `container.rs` | `Container.swift` | header, FAT chain, entries, predictors, `ByteCursor` |
| `container.rs` (flate2) | `Zlib.swift` | zlib wrapper checked in Swift, raw DEFLATE through Compression, output capped at size + 1 |
| `container.rs` (ruzstd) | `Zstd.swift` | Zstandard decoder written from RFC 8878 (Compression has no zstd) |
| `container.rs`/`preview.rs` (crc32fast) | `Checksums.swift` | CRC-32 (slice-by-8), Adler-32, XXH64 |
| `stream.rs` | `Stream.swift` | iterative parser (see below) |
| `access.rs` | `Access.swift` | |
| `preview.rs` | `Preview.swift` | |
| `model.rs` | `Model.swift` | iterative layer-tree walk (see below) |
| `geometry.rs` | `Geometry.swift` | |
| `shapes.rs` | `Shapes.swift` | |
| `paint.rs` | `Paint.swift` | |
| `raster.rs` | `Raster.swift` | |
| `text.rs` | `Text.swift` | |
| `synth.rs` | `Sources/PCAffinitySynth/Synth.swift` | separate product, like the cargo feature |
| `tests.rs` | `Tests/PCAffinityTests/{PreviewTests,ArchiveTests}.swift` | every test ported; proptests become seeded loops (same case counts) |
| photocraft-io `tests/affinity.rs` (`mod native`), `tests/affinity_artboards.rs`, `tests/support/current_affinity.rs` | `ModelTests.swift` (`NativeDocumentTests`) | same synthetic documents, asserted on the model instead of PhotoCraft layers |
| fuzz targets (`stream`, `preview`) | mutation tests in each suite | |
| `tests/real_files.rs` (public corpus) | — | not ported: needs the pinned public files, which are not fetched here |

## Tests — 55 in 7 suites (`swift test`, ~10 s debug, also pass with `-c release`)

- **PreviewTests** (9): every `mod preview` test, plus the two proptests.
- **ArchiveTests** (10): every `mod archive` test (all three methods round-trip, shared objects and links, CRC/size/budget enforcement, declared-size bombs, libraries, FAT cycles, hostile streams incl. 2000-deep nesting, the 2^27-bool and 2^24+1-byte value bombs, mutation proptest) plus predictors and old (`#FT2`) multi-revision tables.
- **ChecksumTests** (2), **ZlibTests** (3): known vectors; CPython-made fixed and dynamic Huffman streams (`Fixtures/zlib`); wrapper/Adler failures.
- **ZstdTests** (7): 29 frames made by the reference `zstd` 1.5.7 CLI over synthetic content (`Fixtures/zstd`: seeded random words from the public-domain `/usr/share/dict/words` list, random and patterned bytes, 16-bit ramps; levels `--fast=5` to `-19`, `--long`, the btultra2 strategy, stdin streams without content size, checksums on/off, two frames in one entry, a small-alphabet input for direct Huffman weights, a small-vocabulary text for RLE and repeat-mode sequence tables), each checked by size and CRC-32; a hand-made RLE-literals frame; framing errors (skippable, dictionary, reserved bit, block type, window > 64 MiB, content size, checksum, trailing data, empty frame, size overrun); truncations; 1,200 mutated frames. Together these reach every decoder path (raw/RLE/compressed blocks, raw/RLE/Huffman/treeless literals, 1 and 4 streams, FSE and direct weights, predefined/RLE/FSE/repeat sequence tables, all repeat-offset cases, checksums, window descriptors).
- **NativeDocumentTests** (6), **ModelTests** (18): artboards (legacy `ABEn`, current `phrp`/`aprp`, other property classes), curves with handles and live corners, every parametric shape kind (and an unknown one), gradients, strokes (absolute width, alignment, caps, dash, behind), colour models, artistic text, pixel layers (crop, planar tiles, fill states), placed images, pixel and vector masks, blend modes, warnings and their counts, limits, metadata, facing pages, and the hostile-reference cases below.

Verified outside the suite during the port: the zstd decoder decoded 176 CLI frames of up to 2.5 MB (every level, strategies 1–9) byte-exact, at ~160 MB/s release on the M5 Max; ~420,000 mutated frames (release) and 7,700 (debug) decoded or failed without a trap; `Synth.zstd`/`Synth.zlib` output decodes with `zstd -d` and CPython `zlib`; the iterative stream parser matched a copy of the recursive one on 200,000 random and mutated streams (objects, ids and error messages identical).

## Limits (all kept from photocraft; attacker-facing input)

| Limit | Value |
|---|---|
| Entry size / total extracted (`Limits`) | 256 MiB / 1 GiB, checked before allocation; decoded length must equal the declared size |
| Allocation tables (saves) | 4096, cycles rejected |
| zstd window | 64 MiB (single-segment frames: their content size) |
| Stream nesting / values / objects / class chain | 384 / 2^24 / 8,000,000 / 64 |
| Layer depth / layers | 128 (deeper reported) / 500,000 |
| Curve nodes per object | 4,000,000 |
| Polygon/star sides | 10,000 |
| Gradient stops | 1024 |
| Text characters per node | 2^20 |
| Pixels per layer | 64 MP |
| Preview | 16 MiB, 1–4096 px a side, strict single-PNG chunk layout, every CRC |
| Compound nesting (**new**) | 32 |
| Spot-colour indirection (**new**) | 8 |

## Deliberate differences from photocraft

1. **No deep recursion.** photocraft parses the object stream and walks the layer tree recursively; a
   document at the nesting limits needs 1–2 MB of stack in a Swift debug build (fine in release), more
   than a secondary thread has. Both are explicit-stack loops here, with reads, budgets, object ids,
   warnings and errors in photocraft's order. The deepest allowed documents read on a 256 KiB thread
   (`theDeepestAllowedDocumentsNeedLittleStack`).
2. **Hazards in photocraft that are bounded here** (worth fixing upstream):
   - a compound (`Comp`) listing itself among its operands (a shared object linked back into its own
     `Chld`) recurses in `geometry::outline` until the stack overflows — `node()`'s self-containment
     guard does not cover outlines. Here: depth 32, warning "compound shapes nested too deeply (or
     containing themselves)";
   - a spot colour (`Pant`) whose `srgb`/`base` refers to itself recurses in `paint::color` the same
     way. Here: depth 8;
   - pie angles: `while end < start { end += TAU }` with far-apart finite angles (`AngS` 1e300) loops
     effectively forever. Here: up to 64 turns as photocraft, then the remainder in one step (identical
     results for real angles). `ShSg` uses the same helper (its angles were already range-limited).
3. **zlib** goes through Compression, which consumes the whole input, so the Adler-32 trailer is read
   as the entry's last four bytes: a zlib entry with bytes after its trailer, or without one, fails
   where flate2 would accept it (the CRC-32 check covers integrity either way). The `size + 1` cap and
   "archive entry size mismatch" behaviour match.
4. **zstd** follows the RFC where ruzstd is lenient: content checksums and declared content sizes are
   verified, Huffman tables are limited to 11 bits, bitstreams must be consumed exactly, 4-stream
   literal segments must have their RFC sizes. Valid frames decode identically; errors keep
   photocraft's two messages ("corrupt compressed entry", "archive entry size mismatch").
5. **Entries sharing a name** under different ids: photocraft keeps whichever its hash map yields last;
   here the higher id wins, every run.
6. **API shape**: `Preview` holds a copy of the PNG plus its `range` (photocraft borrows); Rust's
   `class`/`is`/`floats::<N>` become `classTag`/`isClass`/`floats(_:_:count:)`; `[Point; 3]` is
   `Segment(c1, c2, end)`; `Affine` has named coefficients `a…f` (kurbo order) and `coefficients`.

## Not covered

- The public-document corpus test (`tests/real_files.rs`, `cargo xtask corpus --affinity`) and the
  thumbnail-comparison corpus in photocraft-io: no real Affinity files are fetched or used here.
- The PhotoCraft layer mapping, the preview's PNG pixel decode (ImageIO, 4096² cap, in PCPlatform) and
  the "open the preview when the native document fails" fallback: photocraft-io's job, a later step.
