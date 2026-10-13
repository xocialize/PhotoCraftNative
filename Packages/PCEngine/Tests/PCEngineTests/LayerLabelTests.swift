// Port of photocraft-engine (crates/engine/src/layer_label_cmds/tests.rs), MIT OR Apache-2.0, © ArtCraft Team and the PhotoCraft contributors.

import Foundation
import PCDocument
@testable import PCEngine
import Testing

@Suite struct LayerLabelTests {
    let id = "layer.setLabelColor"

    /// Outer { Inner (collapsed) { "Hidden, locked" (blue label) } }, Other. Outer is active.
    func fixture(_ depth: Int) throws -> (Session, [LayerId]) {
        let s = Session()
        try s.execute("file.new", ["width": 4, "height": 4, "depth": .int(depth)])
        let ids = try s.edit("Fixture") { doc, _ -> [LayerId] in
            var leaf = Layer.raster("Hidden, locked", format: doc.pixelFormat)
            leaf.visible = false
            leaf.locks.all = true
            leaf.label = .blue
            var inner = Layer.group("Inner", [leaf])
            inner.withGroup { $0.expanded = false }
            let outer = Layer.group("Outer", [inner])
            let other = Layer.raster("Other", format: doc.pixelFormat)
            doc.layers = [outer, other]
            return [outer.id, inner.id, leaf.id, other.id]
        }
        try s.selectLayer(ids[0])
        return (s, ids)
    }

    @Test func groupsAndOverlappingSelectionAreOneUndoStep() throws {
        for depth in [8, 16, 32] {
            let (s, l) = try fixture(depth)
            let (outer, inner, leaf, other) = (l[0], l[1], l[2], l[3])
            try LayerMulti.setSelection(s, [outer, leaf], active: leaf, anchor: outer)
            let before = try #require(s.active?.doc)
            let selected = s.active?.selectedLayers
            let past = try #require(s.active?.history.pastCount)
            let r = try s.execute(id, ["color": "seafoam"])
            #expect(r["layers"] == .ids([outer, inner, leaf]))
            #expect(s.active?.history.pastCount == past + 1)
            #expect(s.active?.selectedLayers == selected)
            #expect(s.active?.lastDamage == .empty)
            let after = try #require(s.active?.doc)
            for x in [outer, inner, leaf] { #expect(after.layer(x)?.label == .seafoam) }
            #expect(after.layer(other) == before.layer(other))
            var expected = before
            for x in [outer, inner, leaf] { expected.updateLayer(x) { $0.label = .seafoam } }
            #expect(after == expected, "only labels change at depth \(depth)")
            #expect(Inspect.layer(try #require(after.layer(leaf)))["labelColor"] == "seafoam")
            #expect(s.undo())
            #expect(s.active?.doc == before)
            #expect(s.redo())
            #expect(s.active?.doc == after)
            let past2 = s.active?.history.pastCount
            let revision = s.active?.revision
            #expect(try s.execute(id, ["color": "seafoam"])["changed"] == false)
            #expect(s.active?.history.pastCount == past2)
            #expect(s.active?.revision == revision)
        }
    }

    @Test func everyColorAndResetTargetOnlyTheRequestedLayer() throws {
        let (s, l) = try fixture(8)
        let (outer, leaf, other) = (l[0], l[2], l[3])
        for color in LabelColor.all {
            try s.execute(id, ["color": .string(color.id), "layer": .id(other)])
            let d = try #require(s.active?.doc)
            #expect(d.layer(other)?.label == color)
            #expect(d.layer(outer)?.label == LabelColor.none)
            #expect(d.layer(leaf)?.label == .blue)
        }
        try s.execute(id, ["color": "none", "layer": .id(outer)])
        #expect(s.active?.doc.walk().allSatisfy { $0.layer.label == LabelColor.none || $0.layer.id == other } == true)
        try s.execute(id, ["color": "green", "layer": .id(outer)])
        try s.selectLayer(leaf)
        try s.execute("layer.new.layer", ["name": "Created later"])
        let st = try #require(s.active)
        #expect(st.activeLayer.flatMap { st.doc.layer($0)?.label } == LabelColor.none)
        #expect(st.doc.layer(outer)?.isGroup == true)
        #expect(st.doc.depth == .u8)
    }

    @Test func invalidParamsNeverChangeTheDocumentOrHistory() throws {
        let (s, _) = try fixture(8)
        let bad: [JSONValue] = [
            .null, [], [:], ["color": "unknown"], ["color": 1], ["color": "red", "layer": "1"], ["color": "red", "layer": -1],
            ["color": "red", "layer": 1.5], ["color": "red", "layer": .null], ["color": "red", "layer": .number(Double(UInt64.max))],
        ]
        for p in bad {
            let st = try #require(s.active)
            let before = (st.doc, st.revision, st.history.pastCount)
            #expect(throws: EngineError.self, "\(p)") { try s.execute(id, p) }
            let after = try #require(s.active)
            #expect(after.doc == before.0 && after.revision == before.1 && after.history.pastCount == before.2)
        }
        let empty = Session()
        #expect(!empty.isEnabled(id))
        #expect(throws: EngineError.self) { try empty.execute(id, ["color": "red"]) }
        try empty.execute("file.new", ["width": 2, "height": 2])
        try empty.edit("Empty") { doc, active in
            doc.layers = []
            active = nil
        }
        #expect(!empty.isEnabled(id))
        #expect(throws: EngineError.self) { try empty.execute(id, ["color": "red"]) }
    }
}
