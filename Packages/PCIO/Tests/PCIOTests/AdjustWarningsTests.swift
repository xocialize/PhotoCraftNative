// Port of photocraft-io (crates/io/tests/adjust_warnings.rs), MIT OR Apache-2.0, © ArtCraft Team and the PhotoCraft contributors.
// Opening a file whose adjustment layer can't be read warns, naming the layer and the reason,
// instead of opening it silently without its effect (#1763). The reason strings themselves are
// checked at block level in PCIOMapsTests' AdjustBlockRoundTripTests.

import Foundation
import PCDocument
import PCFoundation
import PCIOCore
import Testing
@testable import PCIO

@Suite struct AdjustWarningsTests {
    init() { ExportSweep.install() }
    static func reopen(_ adj: Adjustment, _ path: String, _ options: IOOptions) throws -> (Document, [String]) {
        var d = Document(name: "a", size: PixelSize(width: 16, height: 16), mode: .rgb, depth: .u8)
        d.layers.append(Layer(name: "Teal Look", content: .adjustment(adj)))
        let r = try MapsKit.export(d, path, options: options)
        let imp = try MapsKit.importFile(r.bytes, path, options: options)
        return (imp.document, imp.warnings)
    }

    static func unsupported(_ a: Adjustment) -> Bool { if case .unsupported = a { true } else { false } }

    @Test func unreadableAdjustmentsWarnOnOpen() throws {
        // A Color Lookup that uses a profile, not a LUT file: kept verbatim, not applied.
        let profile = Adjustment.unsupported(psdKey: "clrL", raw: [0, 2, 0, 0])
        var psb = MapsKit.options()
        psb.forcePSB = true
        for (path, opts) in [("x.psd", MapsKit.options()), ("x.psb", psb)] {
            // A stand-in block, not Photoshop data: not swept.
            let (doc, warnings) = try ExportSweep.excluded { try Self.reopen(profile, path, opts) }
            #expect(doc.layers[0].adjustment.map(Self.unsupported) == true, "\(path)")
            let w = warnings.filter { $0.contains("Teal Look") }
            #expect(w.count == 1, "\(path): \(warnings)")
            if let first = w.first {
                #expect(first.contains("Color Lookup") && first.contains("version 2") && first.contains("no effect"), "\(path): \(first)")
            }
        }
        // Another kind without a specific reason still names the layer and the adjustment. (A
        // truncated Levels block, damaged on purpose: Photoshop opens it as a pixel layer.)
        let (_, warnings) = try ExportSweep.excluded { try Self.reopen(.unsupported(psdKey: "levl", raw: [0, 9]), "x.psd", MapsKit.options()) }
        #expect(warnings.contains { $0.contains("Teal Look") && $0.contains("Levels settings could not be read;") }, "\(warnings)")
    }

    @Test func readableAdjustmentsOpenWithoutWarnings() throws {
        let lut: [Float] = (0 ..< 8).flatMap { i in [Float(i & 1), Float((i >> 1) & 1), Float((i >> 2) & 1)] }
        let lookup = Adjustment.colorLookup(.init(name: "id.cube", lut: lut, size: 2, tetrahedral: false, dither: false))
        for adj in [lookup, .invert] {
            let (doc, warnings) = try Self.reopen(adj, "x.psd", MapsKit.options())
            #expect(doc.layers[0].adjustment.map(Self.unsupported) == false)
            #expect(!warnings.contains { $0.contains("Teal Look") }, "\(warnings)")
        }
    }
}
