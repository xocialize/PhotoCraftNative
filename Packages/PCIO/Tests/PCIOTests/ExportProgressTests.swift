// Port of photocraft-io (crates/io/tests/export_progress.rs), MIT OR Apache-2.0, © ArtCraft Team and the PhotoCraft contributors.
//
// #3389: a background save's export reports its progress (so the status bar and the tab title can
// read "Saving NN%") and can be cancelled, without changing a byte of what it writes. Progress and
// cancellation are PCIOCore's `Interrupt`.

import Foundation
import PCDocument
import PCFoundation
import PCIOCore
import Testing
@testable import PCIO

@Suite struct ExportProgressTests {
    init() { ExportSweep.install() }
    /// Three pixel layers (two in a group) of noise-like pixels at `depth`.
    static func layered(_ depth: SampleType) -> Document {
        var d = Document(name: "progress", size: PixelSize(width: 300, height: 200), mode: .rgb, depth: depth)
        let fmt = d.pixelFormat
        func layer(_ name: String, _ seed: Int, _ r: PixelRect) -> Layer {
            let n = r.area * fmt.bytesPerPixel
            let px = (0 ..< n).map { UInt8(($0 * 31 + seed * 17 + $0 / 7) % 251) }
            return Layer(name: name, content: .raster(Surface(format: fmt, rect: r, interleaved: px)))
        }
        d.layers.append(layer("Back", 1, d.bounds))
        d.layers.append(Layer.group("Group", [layer("A", 2, rect(10, 10, 200, 150)), layer("B", 3, rect(50, 40, 290, 190))]))
        return d
    }

    /// Exports `doc` as `name` with progress recorded: the bytes and every fraction reported.
    static func exportRecorded(_ doc: Document, _ name: String, _ opts: IOOptions) throws -> ([UInt8], [Float]) {
        let seen = PSDKit.Recorder<Float>()
        var o = opts
        o.interrupt = Interrupt(cancel: { false }, progress: { seen.append($0) })
        let r = try PSDKit.export(doc, name, o)
        return (r.bytes, seen.values)
    }

    static func tiffLayers() -> IOOptions {
        var o = IOOptions()
        o.tiffLayers = true
        return o
    }

    /// Per layer record (3 layers + the group) and per composite band, then the bytes.
    static let cases: [(name: String, layeredTIFF: Bool, minReports: Int)] = [
        ("a.psd", false, 6), ("a.psb", false, 6), ("a.tif", true, 6), ("a.pcraft", false, 3), ("a.png", false, 2), ("a.jpg", false, 2),
    ]

    static func isFlat(_ name: String) -> Bool { name.hasSuffix(".png") || name.hasSuffix(".jpg") }

    @Test(arguments: [SampleType.u8, .u16], cases.indices) func exportReportsMonotonicProgressAndWritesTheSameBytes(_ depth: SampleType, _ i: Int) throws {
        let (name, layeredTIFF, minReports) = ExportProgressTests.cases[i]
        if depth == .u16 && name.hasSuffix(".jpg") { return }
        let opts = layeredTIFF ? ExportProgressTests.tiffLayers() : IOOptions()
        let doc = ExportProgressTests.layered(depth)
        let (bytes, seen) = try ExportProgressTests.exportRecorded(doc, name, opts)
        let plain = try DocumentIO.export(doc, as: name, options: opts).bytes
        // .pcraft bundles carry a save time, so only the formats without one compare exactly.
        if !name.hasSuffix(".pcraft") { #expect(bytes == plain, "\(name) \(depth): progress reporting changed the bytes") }
        #expect(zip(seen, seen.dropFirst()).allSatisfy { $0 <= $1 }, "\(name) \(depth): progress went backwards: \(seen)")
        #expect(seen.allSatisfy { (0 ... 1).contains($0) }, "\(name) \(depth): \(seen)")
        #expect(seen.last == 1, "\(name) \(depth): ends at 100%")
        #expect(seen.count >= minReports, "\(name) \(depth): only \(seen.count) reports: \(seen)")
        #expect(seen.contains { $0 > 0 && $0 < 1 }, "\(name) \(depth): something between 0 and 100%: \(seen)")
    }

    @Test func psdProgressMovesPerLayerBeforeTheComposite() throws {
        let (_, seen) = try ExportProgressTests.exportRecorded(ExportProgressTests.layered(.u8), "a.psd", IOOptions())
        // 4 layer records + the composite (weighing 2) = 6 units, the bytes after 90 %.
        let first = seen.first ?? 0
        #expect(abs(first - 0.9 / 6) < 1e-3, "the first layer is one sixth of the conversion: \(seen)")
        #expect(seen.filter { $0 < 1 }.count >= 5, "\(seen)")
    }

    @Test(arguments: ["a.psd", "a.tif", "a.pcraft", "a.png"]) func aCancelledExportStopsWithCancelled(_ name: String) {
        let doc = ExportProgressTests.layered(.u8)
        // Cancelled from the start, and cancelled after the first progress report.
        var o = ExportProgressTests.tiffLayers()
        o.interrupt = .cancelOnly { true }
        #expect(throws: PCIOError.cancelled, "\(name)") { try DocumentIO.export(doc, as: name, options: o) }
        let stop = PSDKit.Flag()
        o.interrupt = Interrupt(cancel: { stop.value }, progress: { _ in stop.set() })
        #expect(throws: PCIOError.cancelled, "\(name) midway") { try DocumentIO.export(doc, as: name, options: o) }
    }
}
