// Port of photocraft-engine (crates/engine/src/type_mask_cmds.rs `mod tests`), MIT OR Apache-2.0, © ArtCraft Team and the PhotoCraft contributors.

import Foundation
@testable import PCEngine
import PCDocument
import PCFoundation
import Testing

@Suite struct TypeMaskTests {
    func session() throws -> Session {
        let s = Session()
        try s.execute("file.new", ["width": 300, "height": 300])
        return s
    }

    func bounds(_ s: Session) -> PixelRect? { s.active?.doc.selection.map(\.contentBounds) }

    @Test func typedTextSelectsItsGlyphsWithoutALayer() throws {
        var s = try session()
        let layers = s.active?.doc.layers.count
        let text: JSONValue = ["text": "I", "x": 40, "y": 120, "size": 48]
        try s.execute("type.createSelection", text)
        let sel = try #require(bounds(s), "the glyph is selected")
        #expect(s.active?.doc.layers.count == layers, "no layer added")
        // The same text as a type layer covers the same pixels.
        try s.execute("edit.undo", [:])
        #expect(bounds(s) == nil, "one undo step")
        let r = try s.execute("type.create", text)
        let b = try #require(r["bounds"]?.arrayValue).compactMap(\.intValue)
        #expect([Int(sel.x0), Int(sel.y0), Int(sel.x1), Int(sel.y1)] == b)

        // Vertical: the word runs down the column, so its selection is taller than wide.
        s = try session()
        try s.execute("type.createSelection", ["text": "HELLO", "x": 150, "y": 40, "size": 48, "orientation": "vertical"])
        let v = try #require(bounds(s))
        #expect(v.height > 2 * v.width, "\(v)")
    }

    /// The Type Mask tools' commit: the temporary layer goes in the same step as the selection.
    @Test func removeLayerCommitsInOneStep() throws {
        let s = try session()
        let id = try #require(try s.execute("type.create", ["text": "T", "x": 40, "y": 120, "size": 48])["layer"]?.uint64Value)
        let layers = s.active?.doc.layers.count ?? 0
        let r = try s.execute("type.createSelection", ["layer": .number(Double(id)), "removeLayer": true, "operation": "add"])
        #expect(r["selected"] == true)
        #expect(s.active?.doc.layer(LayerId(id)) == nil)
        #expect(s.active?.doc.layers.count == layers - 1)
        #expect(s.active?.history.label == "Type Mask")
        #expect(s.undo())
        #expect(s.active?.doc.layer(LayerId(id)) != nil && bounds(s) == nil)
    }

    @Test func badParamsAreErrors() throws {
        let s = try session()
        for p: JSONValue in [["layer": "x"], ["removeLayer": true], ["operation": 3], ["antialias": "blurry"], ["layer": 999]] {
            #expect(throws: EngineError.self, "\(p)") { try s.execute("type.createSelection", p) }
        }
        #expect(throws: EngineError.self) { try Session().execute("type.createSelection", ["text": "I"]) }
    }
}
