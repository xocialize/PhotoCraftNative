// Port of photocraft-io (crates/io/tests/cancel.rs), MIT OR Apache-2.0, © ArtCraft Team and the PhotoCraft contributors.
//
// Background opens (#210): an import with an `Interrupt` stops when cancelled and reports progress.
//
// Not ported: `cancelled_brush_import_fails` (photocraft `abr_map::read_abr_with`; PCIO does not
// port abr_map.rs, see PORT-NOTES).

import Foundation
import PCDocument
import PCFoundation
import PCIOCore
import Testing
@testable import PCIO

@Suite struct CancelTests {
    init() { ExportSweep.install() }
    static func layeredPSD() throws -> [UInt8] {
        var d = Document(name: "t", size: PixelSize(width: 32, height: 24), mode: .rgb, depth: .u8)
        for i in 0 ..< 5 {
            var s = Surface(format: d.pixelFormat)
            s.fill(rect(Int32(i), Int32(i), 20 + Int32(i), 16 + Int32(i)), with: [0.2 * Float(i), 0.5, 0.7, 1])
            d.layers.append(Layer(name: "L\(i)", content: .raster(s)))
        }
        return try PSDKit.export(d, "t.psd").bytes
    }

    @Test func cancelledImportFailsWithCancelled() throws {
        let bytes = try CancelTests.layeredPSD()
        var o = IOOptions()
        o.interrupt = .cancelOnly { true }
        #expect(throws: PCIOError.cancelled) { try DocumentIO.importFile(name: "t.psd", bytes: bytes, options: o) }
    }

    @Test func importReportsMonotonicProgressPerLayer() throws {
        let bytes = try CancelTests.layeredPSD()
        let seen = PSDKit.Recorder<Float>()
        var o = IOOptions()
        o.interrupt = Interrupt(cancel: { false }, progress: { seen.append($0) })
        let r = try DocumentIO.importFile(name: "t.psd", bytes: bytes, options: o)
        let v = seen.values
        #expect(r.document.layers.count == 5)
        #expect(zip(v, v.dropFirst()).allSatisfy { $0 <= $1 }, "progress went backwards: \(v)")
        #expect(v.last == 1)
        #expect(v.count >= 6, "one report per layer plus stages: \(v)")
        // Same document as the plain import.
        let plain = try DocumentIO.importFile(name: "t.psd", bytes: bytes)
        #expect(plain.document.layers.count == r.document.layers.count)
    }
}
