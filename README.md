# PhotoCraftNative — photocraft on Swift and Metal

A conversion of [photocraft](../../photocraft) (Rust, MIT OR Apache-2.0, ~480K lines) to native Swift and Metal on
macOS 26+, Apple Silicon. Two rules decide each crate:

- **Replace with the macOS framework** where one already does the job: ColorSync for photocraft's own ICC engine,
  ImageIO for its codecs, `CIRAWFilter` for its RAW decoder, CoreText for its shaping/layout stack, CoreGraphics for
  vector rasterisation, `NSEvent` for its pen FFI, Vision for the ML it doesn't have.
- **Port to Swift + Metal** where nothing native exists or where Photoshop semantics must match exactly: PSD,
  blend/compositing rules, layer effects, adjustments, filters, the brush engine, the document model. Every Metal
  kernel keeps a Swift CPU reference and a parity test (≤ 1/255 at 8-bit), as photocraft does for wgpu.

The PSD port also takes PhotoDemon's decode breadth (all nine colour modes, 1–32 bit, spec errata; BSD-2-Clause)
on top of photocraft's structure, tagged blocks and writer, and adds a check photocraft lacks: every PSD the writer
produces must open in Apple's ImageIO with the same composite.

## Layout

Separate SwiftPM packages mirror photocraft's crate layers (`docs/architecture.md` §3), so each builds and tests on
its own:

| Layer | Package | photocraft crates | Approach |
|---|---|---|---|
| L0 | `Packages/PCFoundation` | geom, color, raster (+ the wgpu device setup) | Port; Swift arrays give the tiles copy-on-write; one `MetalContext` |
| L0 | `Packages/PCPSD` | psd | Port, standalone (no workspace deps, as photocraft requires) |
| L0 | `Packages/PCPlatform` | cms, codecs, heif, raw, text, vector, tablet | Replace with ColorSync, ImageIO (+ fleet `media-bridge` ImageBridge, `webp-swift`), CIRAWFilter, CoreText, CoreGraphics, NSEvent, Vision, PDFKit |
| L1–L2 | `Packages/PCDocument` | doc, ops | Port |
| L2 | `Packages/PCAlgo` | algo | Port to Metal kernels + Swift CPU reference |
| L2 | `Packages/PCPaint` | paint | Port; Metal dab rendering + CPU reference |
| L3 | `Packages/PCRender` | compose, gpu (wgpu + WGSL) | Port CPU compositor; WGSL → MSL on Metal |
| L4–L5 | `Packages/PCEngine` (wave 2) | io, engine, format, affinity | Port |
| L6–L7 | App (wave 3) | ui-egui, apps, automation | SwiftUI + AppKit + MTKView |

Status per crate, test counts, parity numbers and what is left: [PORT-STATUS.md](PORT-STATUS.md). Each package's
`PORT-NOTES.md` has its file-by-file map.

## Build

```bash
cd Packages/PCFoundation && swift test
```

Each package builds the same way from its own directory. Metal shaders ship as `.metal` resources compiled at first
use (`MetalContext.library(bundle:key:)`), so `swift build` and Xcode build the same sources.

## Attribution

photocraft: © 2026 ArtCraft Team and the PhotoCraft contributors, MIT OR Apache-2.0. PhotoDemon: © 2026 Tanner
Helland and contributors, BSD-2-Clause. Compositor (prior art read for structure): © 2026 Wonder Assembly LLC, MIT.
Every ported file names its source file and licence in its header.
