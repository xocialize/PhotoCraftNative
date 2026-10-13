// Port of photocraft-engine (crates/engine/src/layer_nav_cmds.rs tests), MIT OR Apache-2.0, © ArtCraft Team and the PhotoCraft contributors.

import Foundation
import PCDocument
@testable import PCEngine
import Testing

@Suite struct LayerNavTests {
    static let ids = ["layer.selectAbove", "layer.selectBelow", "layer.selectTop", "layer.selectBottom", "layer.addAboveToSelection", "layer.addBelowToSelection"]

    /// Bottom to top: Background, A, Group { B, C }, D. Panel rows: D, Group, C, B, A, Background.
    func session() throws -> (Session, [LayerId]) {
        let s = Session()
        try s.execute("file.new", ["width": 16, "height": 16])
        let bg = try #require(s.active?.doc.layers.first?.id)
        func make(_ name: String) throws -> LayerId {
            LayerId(try #require(try s.execute("layer.new.layer", ["name": .string(name)])["layer"]?.uint64Value))
        }
        let a = try make("A"), b = try make("B"), c = try make("C")
        try s.execute("layer.select", ["layer": .id(b)])
        try s.execute("layer.select", ["layer": .id(c), "mode": "add"])
        try s.execute("layer.groupLayers", [:])
        let group = try #require(s.active?.doc.layers.first(where: \.isGroup)?.id)
        let d = try make("D")
        return (s, [bg, a, group, b, c, d])
    }

    func active(_ s: Session) -> LayerId? { s.active?.activeLayer }

    @Test func stepsFollowThePanelRowsAndStopAtTheEnds() throws {
        let (s, l) = try session()
        let (bg, a, group, b, c, d) = (l[0], l[1], l[2], l[3], l[4], l[5])
        #expect(LayerNavCommands.panelRows(try #require(s.active?.doc)) == [d, group, c, b, a, bg])
        try s.execute("layer.select", ["layer": .id(d)])
        for want in [group, c, b, a, bg, bg] {
            try s.execute("layer.selectBelow")
            #expect(active(s) == want)
        }
        for want in [a, b, c, group, d, d] {
            try s.execute("layer.selectAbove")
            #expect(active(s) == want)
        }
        try s.execute("layer.selectBottom")
        #expect(active(s) == bg)
        #expect(s.active?.selectedLayers == [bg])
        try s.execute("layer.selectTop")
        #expect(active(s) == d)
    }

    @Test func collapsedGroupsAreOneRowAndAddingExtendsTheSelection() throws {
        let (s, l) = try session()
        let (bg, a, group, c, d) = (l[0], l[1], l[2], l[4], l[5])
        try s.edit("collapse") { doc, _ in doc.updateLayer(group) { $0.withGroup { $0.expanded = false } } }
        #expect(LayerNavCommands.panelRows(try #require(s.active?.doc)) == [d, group, a, bg])
        // A layer inside the collapsed group steps from the group's row.
        try s.execute("layer.select", ["layer": .id(c)])
        try s.execute("layer.selectBelow")
        #expect(active(s) == a)
        try s.execute("layer.addAboveToSelection")
        try s.execute("layer.addAboveToSelection")
        #expect(active(s) == d)
        #expect(Set(s.active?.selectedLayers ?? []) == Set([a, group, d]))
        try s.execute("layer.addBelowToSelection")
        #expect(active(s) == group, "the active layer moves; the selection keeps every layer")
        #expect(s.active?.selectedLayers.count == 3)
    }

    @Test func selectingNeverDirtiesAndBadStatesAreErrors() throws {
        let (s, _) = try session()
        try s.updateActive { $0.savedRevision = $0.revision }
        try s.execute("layer.selectTop", ["junk": [1, 2]])
        #expect(s.active?.isDirty == false, "selecting a layer is not an edit")
        let empty = Session()
        for id in Self.ids {
            #expect(!empty.isEnabled(id))
            #expect(throws: EngineError.self) { try empty.execute(id) }
        }
        try empty.execute("file.new", ["width": 4, "height": 4])
        try empty.edit("clear") { doc, active in
            doc.layers = []
            active = nil
        }
        for id in Self.ids {
            #expect(throws: EngineError.self, "\(id): no layers") { try empty.execute(id) }
        }
    }
}
