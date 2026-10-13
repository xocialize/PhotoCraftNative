// Port of photocraft-io (crates/io/tests/psd_vertical_type.rs), MIT OR Apache-2.0, © ArtCraft Team and the PhotoCraft contributors.
// Vertical type (#199): orientation survives a PSD round trip (descriptor `Ornt` and the engine
// data's writing direction), point and paragraph text, through whole-file export and import (the
// TySh-level half is PCIOTextTests' PSDTextTests.psdTyShRoundTripsOrientationAndWritingDirection).
// Not ported: the glyph checks (the rendered ink is taller than wide; re-rendering the imported
// model lands on the same pixels): PCIO has no font renderer (it is injected; none here).

import Foundation
import PCDocument
import PCFoundation
import PCIOCore
import Testing
@testable import PCIO

@Suite struct PSDVerticalTypeTests {
    init() { ExportSweep.install() }
    static func docWith(_ shape: TextShape) -> Document {
        var doc = Document(name: "v", size: PixelSize(width: 300, height: 400), mode: .rgb, depth: .u8)
        let text = "Vertical type\nColumns"
        var t = TextLayer(text: text)
        t.runs = [TextRun(len: text.utf8.count, style: CharStyle(fontFamily: "Inter", sizePt: 24))]
        t.orientation = .vertical
        t.shape = shape
        t.transform = .translate(250, 20)
        t.syncSummary()
        doc.layers.append(Layer(name: "v", content: .text(t)))
        return doc
    }

    static func text(_ doc: Document) throws -> TextLayer {
        guard case let .text(t)? = doc.layers.first?.content else { throw PCIOError.unsupported("not text") }
        return t
    }

    @Test(arguments: [false, true]) func verticalOrientationRoundTripsThroughPSD(_ photoshop: Bool) throws {
        let o = MapsKit.options(photoshop: photoshop)
        for shape in [TextShape.point, .box(.init(x: -200, y: 0, width: 220, height: 300))] {
            let doc = Self.docWith(shape)
            let out = try MapsKit.export(doc, "v.psd", options: o)
            let back = try MapsKit.importFile(out.bytes, "v.psd", options: o).document
            let t = try Self.text(back)
            #expect(t.orientation == .vertical, "\(shape)")
            #expect(t.shape == shape)
            #expect(t.text == (try Self.text(doc)).text)
            // A second trip keeps it.
            let out2 = try MapsKit.export(back, "v.psd", options: o)
            #expect(try Self.text(MapsKit.importFile(out2.bytes, "v.psd", options: o).document).orientation == .vertical)
        }
        // Horizontal stays horizontal.
        var doc = Self.docWith(.point)
        doc.layers[0].withText {
            $0.orientation = .horizontal
            $0.psdRaw = nil
        }
        let out = try MapsKit.export(doc, "h.psd", options: o)
        #expect(try Self.text(MapsKit.importFile(out.bytes, "h.psd", options: o).document).orientation == .horizontal)
    }
}
