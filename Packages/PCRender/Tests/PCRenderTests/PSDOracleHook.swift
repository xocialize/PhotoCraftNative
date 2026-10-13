// The PSD composite-oracle hook (new; photocraft compares its compositor with Photoshop's merged images through psd-tools' corpus). MIT OR Apache-2.0, © ArtCraft Team and the PhotoCraft contributors.
//
// When PCPSD is ready:
//   1. add `.product(name: "PCPSD", package: "PCPSD")` (and `.package(path: "../PCPSD")`) to the
//      PCRenderTests target in Package.swift;
//   2. return a loader below: `{ url in … }` decoding the file into an `OracleCase` — the layered
//      `Document`, and its Image Data section (Photoshop's merged composite) as `reference`:
//      straight-alpha RGBA floats over exactly `document.bounds`, values as stored (8/16-bit
//      normalised to 0…1, 32-bit linear floats as-is; CMYK / Lab / Grayscale converted with
//      `Surface.readRGBA`), alpha 1 when the merged image has no transparency. A merged image
//      matted with white (files with transparency) is either un-matted to straight alpha or
//      returned opaque with `flattenedOver: SIMD3(1, 1, 1)`. Return nil to skip a file;
//   3. run `PCRENDER_PSD_CORPUS=/path/to/psds swift test --filter psdCompositeOracle`
//      (optional thresholds: PCRENDER_ORACLE_MEAN — mean levels, default 1.0;
//      PCRENDER_ORACLE_OFF — fraction of pixels more than 2 levels off, default 0.02).
// The test prints one `oracle:` line per file and backend (max / mean levels, % of pixels off,
// rasterizer misses) and fails a file only past the thresholds.

import Foundation
@testable import PCRender

enum PSDOracleHook {
    /// The PCPSD loader (nil until PCPSD is linked; `CompositeOracle.register` works too).
    static let loader: CompositeOracle.Loader? = nil

    static var active: CompositeOracle.Loader? { loader ?? CompositeOracle.loader }
}
