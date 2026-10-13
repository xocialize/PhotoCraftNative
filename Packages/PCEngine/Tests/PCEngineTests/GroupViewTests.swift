// Port of photocraft-engine (crates/engine/src/group_view_cmds.rs tests), MIT OR Apache-2.0, © ArtCraft Team and the PhotoCraft contributors.

import Foundation
import PCDocument
import PCEngine
import Testing

@Suite struct GroupViewTests {
    let id = "layer.setExpanded"

    func session() throws -> (Session, LayerId, LayerId) {
        let s = Session()
        try s.execute("file.new", ["width": 32, "height": 32])
        try s.execute("layer.new.layer", ["name": "deep"])
        let inner = LayerId(try #require(try s.execute("layer.groupLayers", ["name": "inner"])["layer"]?.uint64Value))
        let outer = LayerId(try #require(try s.execute("layer.groupLayers", ["layer": .id(inner), "name": "outer"])["layer"]?.uint64Value))
        return (s, inner, outer)
    }

    func expanded(_ s: Session, _ id: LayerId) -> Bool { s.active?.doc.layer(id)?.group?.expanded == true }

    @Test func togglesOneGroupWithoutHistoryOrDirtying() throws {
        let (s, inner, outer) = try session()
        try s.updateActive { $0.savedRevision = $0.revision }
        let steps = s.active?.history.entries.count
        #expect(expanded(s, inner) && expanded(s, outer))
        #expect(try s.execute(id, ["layer": .id(inner)])["expanded"] == false)
        #expect(!expanded(s, inner) && expanded(s, outer))
        #expect(s.active?.history.entries.count == steps, "no history step")
        #expect(s.active?.savedRevision == s.active?.revision, "still clean")
        try s.execute(id, ["layer": .id(inner), "expanded": true])
        #expect(expanded(s, inner))
        // The inspect JSON reports it.
        try s.execute(id, ["layer": .id(outer), "expanded": false])
        #expect(try s.execute("document.inspect")["layers"]?[0]?["expanded"] == false)
    }

    @Test func allSetsEveryGroup() throws {
        let (s, inner, outer) = try session()
        try s.execute(id, ["layer": .id(outer), "all": true])
        #expect(!expanded(s, inner) && !expanded(s, outer))
        #expect(try s.execute(id, ["all": true])["groups"] == 2)
        #expect(expanded(s, inner) && expanded(s, outer))
    }

    @Test func badParamsFailGracefully() throws {
        let (s, _, _) = try session()
        let bg = try #require(s.active?.doc.layers.first?.id)
        let bad: [JSONValue] = [["layer": .id(bg)], ["layer": 9999], ["layer": "x"], ["layer": -1], ["expanded": "yes", "all": true], ["all": 3]]
        for p in bad {
            #expect(throws: EngineError.self, "\(p)") { try s.execute(id, p) }
        }
        let empty = Session()
        #expect(throws: EngineError.self) { try empty.execute(id, [:]) }
        try empty.execute("file.new", ["width": 8, "height": 8])
        #expect(throws: EngineError.self, "no groups: disabled") { try empty.execute(id, ["all": true]) }
    }
}
