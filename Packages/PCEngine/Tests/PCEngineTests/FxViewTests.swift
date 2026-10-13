// Port of photocraft-engine (crates/engine/src/fx_view_cmds.rs tests), MIT OR Apache-2.0, © ArtCraft Team and the PhotoCraft contributors.
//
// The fixtures add effects directly (the Layer Style commands that photocraft's tests use belong
// to another module).

import Foundation
import PCDocument
import PCEngine
import PCFoundation
import Testing

fileprivate func fillActive(_ s: Session, _ c: SIMD4<Float>) throws {
    try s.edit("fill") { doc, active in
        guard let id = active else { return }
        let b = doc.bounds
        doc.withRaster(of: id) { $0.writeRegion(b, PixelCodec.fromRGBA($0.format, rgba: [SIMD4<Float>](repeating: c, count: b.area))) }
    }
}

fileprivate func addEffects(_ s: Session, _ id: LayerId, _ fx: [Effect]) throws {
    try s.edit("Layer Style") { doc, _ in
        doc.updateLayer(id) { l in
            l.effects.items += fx
            l.effects.enabled = true
        }
    }
}

fileprivate func newLayer(_ s: Session, _ name: String) throws -> LayerId {
    LayerId(try #require(try s.execute("layer.new.layer", ["name": .string(name)])["layer"]?.uint64Value))
}

fileprivate let stroke = Effect.stroke(StrokeFx(common: FxCommon(.normal, 1), size: 3, position: .outside, paint: .color(.black)))

@Suite struct FxViewTests {
    let id = "layer.setEffectsExpanded"

    func session() throws -> (Session, LayerId, LayerId) {
        let s = Session()
        try s.execute("file.new", ["width": 32, "height": 32])
        let a = try newLayer(s, "a")
        try fillActive(s, SIMD4(1, 0, 0, 1))
        try addEffects(s, a, [Effect.defaultDropShadow()])
        let b = try newLayer(s, "b")
        try fillActive(s, SIMD4(0, 1, 0, 1))
        try addEffects(s, b, [stroke])
        return (s, a, b)
    }

    func open(_ s: Session, _ id: LayerId) -> Bool { !(s.active?.view[FxCollapsedKey.self].contains(id) ?? false) }

    @Test func togglesOneLayerOrAllWithoutHistory() throws {
        let (s, a, b) = try session()
        try s.updateActive { $0.savedRevision = $0.revision }
        let steps = s.active?.history.entries.count
        #expect(open(s, a) && open(s, b), "effects lists start open")
        #expect(try s.execute(id, ["layer": .id(a)])["expanded"] == false)
        #expect(!open(s, a) && open(s, b))
        #expect(s.active?.history.entries.count == steps, "no history step")
        #expect(s.active?.savedRevision == s.active?.revision, "still clean")
        try s.execute(id, ["layer": .id(a), "all": true])
        #expect(open(s, a) && open(s, b), "toggling an open-and-closed set from a closed layer opens all")
        try s.execute(id, ["all": true, "expanded": false])
        #expect(!open(s, a) && !open(s, b))
        try s.execute(id, ["layer": .id(b), "expanded": true])
        #expect(!open(s, a) && open(s, b))
        #expect(s.active?.view[FxCollapsedKey.self].count == 1, "no duplicates")
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
        #expect(throws: EngineError.self, "no effects: disabled") { try empty.execute(id, ["all": true]) }
    }
}
