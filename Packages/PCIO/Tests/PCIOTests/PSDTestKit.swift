// Helpers of the PSD-structure test ports: photocraft-psd's synthetic file generator (`testgen`),
// photocraft's builder record shape, the strict block-layout check, PCPSD's linter, and the
// PCRender composite ("flatten") the photocraft tests compare against.
// Port of photocraft-io (crates/io/tests/common/mod.rs: strict_block_errors, max_diff), MIT OR
// Apache-2.0, © ArtCraft Team and the PhotoCraft contributors. The generator is PCPSD's
// `PSDTestGen` (product `PCPSDTestSupport`, the port of photocraft-psd testgen.rs).

import Foundation
import PCDocument
import PCFoundation
import PCIOCore
import PCPSD
import PCPSDTestSupport
import PCRender
import Testing
@testable import PCIO

enum PSDKit {
    // MARK: Options

    /// `false`: photocraft's own record shape (`photocraftOptions()`); `true`: Photoshop's (the default).
    static let conventions: [Bool] = [false, true]

    static func options(_ photoshop: Bool) -> IOOptions {
        var o = IOOptions()
        o.photoshopRecordConventions = photoshop
        return o
    }

    static func exportOptions(_ photoshop: Bool) -> PSDExportOptions {
        PSDExportOptions(compositor: RenderCompositor.shared, photoshopRecordConventions: photoshop)
    }

    /// photocraft `document_to_psd`: the file model of `d` (merged image from PCRender), checked
    /// with PCPSD's linter.
    static func documentToPSD(_ d: Document, photoshop: Bool = false, sourceLocation: SourceLocation = #_sourceLocation) -> PSDFile {
        let f = PSDExport.file(d, options: exportOptions(photoshop)).file
        let e = f.compatibilityIssues(decodeChannels: true).filter { $0.severity == .error }.map(\.description)
        #expect(e.isEmpty, "document_to_psd: linter: \(e.prefix(4))", sourceLocation: sourceLocation)
        return f
    }

    /// photocraft `psd_to_document` (never fails; throws only when cancelled).
    static func psdToDocument(_ f: PSDFile) throws -> (document: Document, warnings: [String]) {
        try PSDImport.document(f)
    }

    /// photocraft `import`.
    static func importFile(_ name: String, _ bytes: [UInt8], photoshop: Bool = true) throws -> ImportResult {
        try DocumentIO.importFile(name: name, bytes: bytes, options: options(photoshop))
    }

    /// photocraft `export`; every PSD/PSB written also passes PCPSD's linter (unless `lint` is
    /// false, for a caller that checks it under a known issue).
    static func export(_ d: Document, _ name: String, _ o: IOOptions = IOOptions(), lint: Bool = true,
                       sourceLocation: SourceLocation = #_sourceLocation) throws -> ExportResult {
        let r = try DocumentIO.export(d, as: name, options: o)
        if lint, DocumentIO.isPSD(r.bytes) { expectLintClean(r.bytes, name, sourceLocation: sourceLocation) }
        return r
    }

    /// PCPSD's linter errors for a written file (empty: Photoshop is expected to open it).
    static func lintErrors(_ bytes: [UInt8]) -> [String] {
        do {
            return try PSDFile(bytes: bytes).compatibilityIssues(decodeChannels: true).filter { $0.severity == .error }.map(\.description)
        } catch {
            return ["parse: \(error)"]
        }
    }

    static func expectLintClean(_ bytes: [UInt8], _ ctx: String, sourceLocation: SourceLocation = #_sourceLocation) {
        let e = lintErrors(bytes)
        #expect(e.isEmpty, "\(ctx): linter: \(e.prefix(4))", sourceLocation: sourceLocation)
    }

    /// Re-saves `f` through a document (photocraft `via_doc` / `reexport`).
    static func viaDocBytes(_ f: PSDFile, photoshop: Bool, sourceLocation: SourceLocation = #_sourceLocation) throws -> [UInt8] {
        let bytes = [UInt8](try f.serialized())
        let imp = try DocumentIO.importFile(name: "t.psd", bytes: bytes, options: options(photoshop))
        return try export(imp.document, "t.psd", options(photoshop), sourceLocation: sourceLocation).bytes
    }

    static func viaDoc(_ f: PSDFile, photoshop: Bool, sourceLocation: SourceLocation = #_sourceLocation) throws -> PSDFile {
        try PSDFile(bytes: try viaDocBytes(f, photoshop: photoshop, sourceLocation: sourceLocation))
    }

    // MARK: Compositing (photocraft-compose `flatten` → PCRender)

    final class Flattener: @unchecked Sendable {
        let compositor = RenderCompositor()
        let lock = NSLock()
        func flatten(_ d: Document) throws -> [SIMD4<Float>] {
            try lock.withLock { try compositor.compositor.flatten(d).px }
        }
    }

    static let flattener = Flattener()

    /// The composite of `d` as straight RGBA, row-major (photocraft `flatten(d).px`).
    static func flatten(_ d: Document) throws -> [SIMD4<Float>] { try flattener.flatten(d) }

    /// The composite of `d` through `compositor` (a test-local instance, not shared).
    static func flatten(_ d: Document, compositor: RenderCompositor) throws -> [SIMD4<Float>] { try compositor.compositor.flatten(d).px }

    /// A rasterizer that only knows the coverage of one axis-aligned rectangle (exact area
    /// coverage per pixel), for vector-mask tests: the default `PlaceholderRasterizer` has no path
    /// coverage (PCPlatform supplies it), so its vector masks reveal everything.
    struct RectCoverageRasterizer: LayerRasterizer {
        func rasterize(_ layer: Layer, in document: Document) -> Surface? { nil }
        func renderShape(_ shape: ShapeLayer, format: PixelFormat, clip: PixelRect) -> Surface? { nil }
        func coverage(of path: VectorPath, in rect: PixelRect) -> [Float]? {
            guard path.subpaths.count == 1, let sp = path.subpaths.first, sp.knots.count == 4 else { return nil }
            let xs = Set(sp.knots.map(\.anchor.x)), ys = Set(sp.knots.map(\.anchor.y))
            guard xs.count == 2, ys.count == 2, let x0 = xs.min(), let x1 = xs.max(), let y0 = ys.min(), let y1 = ys.max() else { return nil }
            var out = [Float](repeating: 0, count: rect.area)
            var i = 0
            for y in rect.y0 ..< rect.y1 {
                for x in rect.x0 ..< rect.x1 {
                    let cx = max(0, min(Double(x) + 1, x1) - max(Double(x), x0))
                    let cy = max(0, min(Double(y) + 1, y1) - max(Double(y), y0))
                    let c = Float(cx * cy)
                    out[i] = path.inverted ? 1 - c : c
                    i += 1
                }
            }
            return out
        }
    }

    /// The result of work run on another thread.
    final class ResultBox<T>: @unchecked Sendable {
        var result: Result<T, any Error>?
    }

    /// Runs `body` on a thread of `stackSize` bytes and waits for it (deep group trees recurse
    /// in the importer; photocraft's Rust test threads have 2 MiB stacks).
    static func onThread<T>(stackSize: Int, _ body: @escaping @Sendable () throws -> T) throws -> T {
        let box = ResultBox<T>()
        let done = DispatchSemaphore(value: 0)
        let t = Thread {
            box.result = Result { try body() }
            done.signal()
        }
        t.stackSize = stackSize
        t.start()
        done.wait()
        guard let r = box.result else { throw PCIOError.io("thread produced no result") }
        return try r.get()
    }

    /// Max per-channel difference over pixels where either is not fully transparent, colour
    /// premultiplied (photocraft `max_diff`).
    static func maxDiff(_ a: [SIMD4<Float>], _ b: [SIMD4<Float>]) -> Float {
        var m: Float = 0
        for (p, q) in zip(a, b) {
            if p.w <= 0 && q.w <= 0 { continue }
            for c in 0 ..< 4 {
                let (x, y) = c < 3 ? (p[c] * p.w, q[c] * q.w) : (p[c], q[c])
                m = max(m, abs(x - y))
            }
        }
        return m
    }

    /// Pixels of `fmt` (interleaved, `fmt.channels` each) as straight RGBA (photocraft `to_rgba`).
    static func toRGBA(_ fmt: PixelFormat, _ vals: [Float]) -> [SIMD4<Float>] {
        let n = vals.count / max(fmt.channels, 1)
        guard n > 0 else { return [] }
        var s = Surface(format: fmt)
        let r = PixelRect(x0: 0, y0: 0, x1: Int32(n), y1: 1)
        s.writeRegion(r, vals)
        return s.readRGBA(r)
    }

    // MARK: Strict block layout (photocraft common::strict_block_errors, #200)

    /// Every tagged block re-parses with its section sizes matching, laid out as Photoshop writes
    /// it: no unparsed bytes after the layer section, layer info padded to 4, global blocks padded
    /// to 4, layer blocks of even length with no pad outside it, inner lengths consistent.
    static func strictBlockErrors(_ bytes: [UInt8]) -> [String] {
        let file: PSDFile
        do { file = try PSDFile(bytes: bytes) } catch { return ["parse: \(error)"] }
        let v = file.header.version
        var errs: [String] = []
        if !file.layerMaskTrailing.isEmpty {
            errs.append("\(file.layerMaskTrailing.count) unparsed bytes at the end of the layer and mask section")
        }
        if let li = file.layerInfo {
            let body = (try? li.unpaddedLength(v)) ?? 1
            let pad = li.padding.map { UInt64($0.count) } ?? body % 2
            if (body + pad) % 4 != 0 { errs.append("layer info: \(body) bytes + \(pad) padding is not a multiple of 4") }
        }
        for b in file.globalBlocks {
            let pad = b.padding?.count ?? (4 - b.data.count % 4) % 4
            if (b.data.count + pad) % 4 != 0 {
                errs.append("global \(b.key.string): \(b.data.count) data bytes + \(pad) padding is not a multiple of 4")
            }
            do { try b.checkStructure() } catch { errs.append("global \(b.key.string): \(error)") }
        }
        for (i, l) in file.layers.enumerated() {
            for b in l.blocks {
                if b.data.count % 2 != 0 || (b.padding.map { !$0.isEmpty } ?? false) {
                    errs.append("layer \(i) \(b.key.string): \(b.data.count) data bytes with padding outside the length")
                }
                do { try b.checkStructure() } catch { errs.append("layer \(i) \(b.key.string): \(error)") }
            }
        }
        return errs
    }

    // MARK: photocraft's builder

    /// A `PSDBuilder` writing photocraft's builder records (`luni`, `lyid`, `iOpa` only; no
    /// Photoshop default resources).
    static func builder(_ w: Int, _ h: Int, mode: PSDColorMode = .rgb, depth: UInt16 = 8, version: PSDVersion = .psd) -> PSDBuilder {
        var b = PSDBuilder(width: w, height: h, colorMode: mode, depth: depth, version: version)
        b.photoshopLayerBlocks = false
        b.photoshopDefaultResources = false
        return b
    }

    // MARK: testgen (PCPSD's `PSDTestGen`, the port of photocraft-psd testgen.rs)

    /// A legacy Pascal name: printable ASCII kept, anything else `?`, at most 255 bytes.
    static func legacyName(_ s: String) -> [UInt8] { PSDLayerRecord.legacyName(s) }
    static func patternPlane(_ w: Int, _ h: Int, _ depth: UInt16, _ seed: UInt32) -> [UInt8] { PSDTestGen.patternPlane(w, h, depth, seed) }
    static func modeChannels(_ m: PSDColorMode) -> UInt16 { PSDTestGen.modeChannels(m) }
    static func modeDepths(_ m: PSDColorMode) -> [UInt16] { PSDTestGen.modeDepths(m) }
    static func colorModeData(_ m: PSDColorMode) -> Data { PSDTestGen.colorModeData(m) }
    static func baseResources() -> [PSDImageResource] { PSDTestGen.baseResources() }
    static func encodeChannel(_ id: Int16, _ c: PSDCompression, _ plane: [UInt8], _ w: Int, _ h: Int, _ depth: UInt16, _ v: PSDVersion) throws -> PSDChannel {
        PSDTestGen.encodeChannel(id, c, plane, w, h, depth, v)
    }
    static func mergedOnly(_ v: PSDVersion, _ mode: PSDColorMode, _ depth: UInt16, _ c: PSDCompression, _ w: UInt32, _ h: UInt32) throws -> PSDFile {
        PSDTestGen.mergedOnly(v, mode, depth, c, w, h)
    }
    static func rasterLayer(header: PSDHeader, compression: PSDCompression, rect: PSDRect, name: String, blend: PSDBlendMode,
                            mask: PSDLayerMask?, seed: UInt32) throws -> PSDLayerRecord {
        PSDTestGen.rasterLayer(header: header, compression: compression, rect: rect, name: name, blend: blend, mask: mask, seed: seed)
    }
    static func groupRecord(_ header: PSDHeader, _ name: String, _ kind: PSDSectionType, _ blend: PSDBlendMode, _ id: UInt32) -> PSDLayerRecord {
        PSDTestGen.groupRecord(header, name, kind, blend, id)
    }
    static func sampleDescriptor() -> PSDVersionedDescriptor { PSDTestGen.sampleDescriptor() }
    static func extraBlocks(_ seed: UInt32) -> [PSDTaggedBlock] { PSDTestGen.extraBlocks(seed) }
    /// photocraft's generated file, valid for Photoshop by default (`invalidBlendModes`: every
    /// blend key as photocraft's generator gives it, unknown and pass-through ones included).
    static func layered(_ v: PSDVersion, _ mode: PSDColorMode, _ depth: UInt16, _ c: PSDCompression, invalidBlendModes: Bool = false) throws -> PSDFile {
        PSDTestGen.layered(v, mode, depth, c, invalidBlendModes: invalidBlendModes)
    }
    static func small(_ v: PSDVersion, _ c: PSDCompression) throws -> PSDFile { PSDTestGen.small(v, c) }

    // MARK: Small conveniences

    static func be16(_ b: [UInt8], _ i: Int) -> UInt16 { UInt16(b[2 * i]) << 8 | UInt16(b[2 * i + 1]) }

    static func be32(_ b: [UInt8], _ at: Int) -> UInt32 {
        UInt32(b[at]) << 24 | UInt32(b[at + 1]) << 16 | UInt32(b[at + 2]) << 8 | UInt32(b[at + 3])
    }

    /// Thread-safe recorder for progress callbacks.
    final class Recorder<T: Sendable>: @unchecked Sendable {
        private var items: [T] = []
        private let lock = NSLock()
        func append(_ v: T) { lock.withLock { items.append(v) } }
        var values: [T] { lock.withLock { items } }
    }

    /// A thread-safe flag.
    final class Flag: @unchecked Sendable {
        private var v = false
        private let lock = NSLock()
        func set() { lock.withLock { v = true } }
        var value: Bool { lock.withLock { v } }
    }
}
