// The PSD composite oracle: a PSD file's layered document next to Photoshop's own merged image,
// for comparing a compositor's rendering of the layers with Photoshop's (photocraft architecture
// §7.4; photocraft's io `merged_composite` + compose oracle tests). Feeds PCRender's
// `CompositeOracle` hook.
// New in the port (photocraft runs its oracle through `crates/io/tests/corpus.rs`), MIT OR
// Apache-2.0, © ArtCraft Team and the PhotoCraft contributors.

import Foundation
import PCDocument
import PCFoundation
import PCIOCore
import PCPSD
import PCRender

public enum PSDCompositeOracle {
    /// The oracle case of a PSD/PSB file: the imported layered document, and Photoshop's merged
    /// image over exactly `document.bounds` as straight RGBA floats (8/16-bit normalised, 32-bit as
    /// stored; CMYK, Lab and Gray through `Surface.readRGBA`). A merged image with transparency is
    /// white-matted by Photoshop: it is returned as stored, opaque, with `flattenedOver: (1, 1, 1)`
    /// (exact, unlike un-matting 8-bit values). nil when the file has no usable merged image
    /// (Multichannel, a placeholder composite, layers that could not be imported).
    public static func oracleCase(contentsOf url: URL, renderer: (any LayerContentRenderer)? = nil) throws -> OracleCase? {
        let file: PSDFile
        do { file = try PSDFile(contentsOf: url) } catch { throw PCIOError.wrap(error) }
        if file.hasRealMergedData == false { return nil }
        let doc = try DocumentIO.importPSD(url.lastPathComponent, file, IOOptions(compositor: StoredPixelsCompositor(), renderer: renderer)).document
        guard doc.mode != .multichannel, !doc.layers.isEmpty, let reference = try reference(file, doc) else { return nil }
        return OracleCase(name: url.lastPathComponent, document: doc, reference: reference.buffer, flattenedOver: reference.flattened)
    }

    /// Photoshop's merged image of `file` in `doc`'s geometry (see `oracleCase`).
    public static func reference(_ file: PSDFile, _ doc: Document) throws -> (buffer: RGBABuffer, flattened: SIMD3<Float>?)? {
        let h = file.header
        guard Int(h.width) == doc.size.width, Int(h.height) == doc.size.height else { return nil }
        let fmt = doc.pixelFormat
        let cc = fmt.mode.colorChannels
        let n = doc.size.width * doc.size.height
        let all: [UInt8]
        do { all = try file.decodeMerged(lenient: true) } catch { return nil }
        let plane = h.rowBytes * Int(h.height)
        guard cc * plane <= all.count, Int(h.depth) == fmt.sample.bits || (h.depth == 1 && fmt.sample == .u8) else { return nil }
        if h.depth == 1 { return nil }
        let alpha = file.mergedHasAlpha
        var planes: [[UInt8]?] = (0 ..< cc).map { Array(all[$0 * plane ..< ($0 + 1) * plane]) }
        planes.append(nil)
        var fill = [[UInt8]](repeating: PSDPixels.zeroSample(fmt.sample), count: cc)
        fill.append(PSDPixels.maxSample(fmt.sample))
        var bytes = PSDPixels.interleave(planes, fill, n, fmt.sample, [Bool](repeating: fmt.mode == .cmyk, count: cc) + [false])
        if fmt.mode == .lab, fmt.sample == .u16 { PSDPixels.lab16Chroma(&bytes, cc + 1, toDoc: true) }
        let s = Surface(format: fmt, rect: doc.bounds, interleaved: bytes)
        let px = s.readRGBA(doc.bounds)
        return (RGBABuffer(rect: doc.bounds, px: px), alpha ? SIMD3(1, 1, 1) : nil)
    }

    /// Installs `oracleCase` as PCRender's `CompositeOracle` loader (for PCRender's own
    /// `psdCompositeOracle` test with `PCRENDER_PSD_CORPUS`).
    public static func register(renderer: (any LayerContentRenderer)? = nil) {
        CompositeOracle.register { url in try PSDCompositeOracle.oracleCase(contentsOf: url, renderer: renderer) }
    }

    /// One file's comparison on `backend`.
    public static func compare(_ c: OracleCase, compositor: PCRender.DocumentCompositor, backend: PCRender.DocumentCompositor.Backend) throws -> OracleComparison {
        try CompositeOracle.compare(c, compositor: compositor, backend: backend)
    }
}
