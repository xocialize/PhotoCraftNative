// Port of photocraft-engine (crates/engine/src/fx_visibility_cmds.rs tests), MIT OR Apache-2.0, © ArtCraft Team and the PhotoCraft contributors.
//
// The fixtures add effects directly (the Layer Style commands that photocraft's tests use belong
// to another module).

import Foundation
import PCDocument
import PCEngine
import PCFoundation
import Testing

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

fileprivate func colorOverlay(_ c: PCColor, opacity: Float = 1) -> Effect { .colorOverlay(Effect.ColorOverlay(common: FxCommon(.normal, opacity), color: c)) }

@Suite struct FxVisibilityTests {
    let id = "layer.setEffectsVisible"

    /// A red layer with a drop shadow and a blue colour overlay, and the background (no effects).
    func session() throws -> (Session, LayerId, LayerId) {
        let s = Session()
        try s.execute("file.new", ["width": 32, "height": 32])
        let bg = try #require(s.active?.doc.layers.first?.id)
        let a = try newLayer(s, "a")
        try s.execute("select.rect", ["x": 8, "y": 8, "width": 16, "height": 16])
        try s.edit("fill") { doc, _ in
            let r = PixelRect(x0: 8, y0: 8, x1: 24, y1: 24)
            doc.withRaster(of: a) { $0.writeRegion(r, PixelCodec.fromRGBA($0.format, rgba: [SIMD4<Float>](repeating: SIMD4(1, 0, 0, 1), count: r.area))) }
        }
        try s.execute("select.deselect")
        try addEffects(s, a, [Effect.defaultDropShadow(), colorOverlay(.rgb(0, 0, 1))])
        return (s, a, bg)
    }

    func state(_ s: Session, _ id: LayerId) -> (Bool, [Bool]) {
        let fx = s.active?.doc.layer(id)?.effects
        return (fx?.enabled ?? false, fx?.items.map(\.isEnabled) ?? [])
    }

    func steps(_ s: Session) -> Int { s.active?.history.pastCount ?? -1 }

    func flat(_ s: Session) throws -> [SIMD4<Float>] {
        let doc = try #require(s.active?.doc)
        return try s.services.renderer.render(doc, region: doc.bounds).px
    }

    @Test func theEffectsRowEyeHidesAndShowsTheWholeList() throws {
        let (s, a, _) = try session()
        let n = steps(s)
        #expect(try s.execute(id, ["layer": .id(a)]) == ["layer": .id(a), "index": .null, "visible": false])
        #expect(state(s, a) == (false, [true, true]), "each effect keeps its own state")
        #expect(steps(s) == n + 1, "one history step")
        #expect(s.active?.history.undoLabel == "Hide Layer Effects")
        // The active layer is the default target.
        #expect(try s.execute(id, [:])["visible"] == true)
        #expect(state(s, a) == (true, [true, true]))
        #expect(s.active?.history.undoLabel == "Show Layer Effects")
    }

    @Test func oneEffectEyeHidesOnlyThatEffectAndUndoes() throws {
        let (s, a, _) = try session()
        #expect(try s.execute(id, ["layer": .id(a), "index": 1])["visible"] == false)
        #expect(state(s, a) == (true, [true, false]))
        #expect(s.active?.history.undoLabel == "Hide Color Overlay")
        try s.execute("edit.undo")
        #expect(state(s, a) == (true, [true, true]))
        try s.execute("edit.redo")
        #expect(state(s, a) == (true, [true, false]))
        try s.execute(id, ["layer": .id(a), "index": 1, "visible": true])
        #expect(state(s, a) == (true, [true, true]))
    }

    @Test func hidingChangesTheCompositeAndKeepsTheSettings() throws {
        let (s, a, _) = try session()
        let before = s.active?.doc.layer(a)?.effects.items
        let shown = try flat(s)
        try s.execute(id, ["layer": .id(a), "visible": false])
        #expect(try flat(s) != shown, "hidden effects are not drawn")
        try s.execute(id, ["layer": .id(a), "visible": true])
        #expect(try flat(s) == shown)
        #expect(s.active?.doc.layer(a)?.effects.items == before)
    }

    @Test func askingForTheCurrentStateAddsNoHistoryStep() throws {
        let (s, a, _) = try session()
        let n = steps(s)
        #expect(try s.execute(id, ["layer": .id(a), "visible": true])["visible"] == true)
        #expect(try s.execute(id, ["layer": .id(a), "index": 0, "visible": true])["visible"] == true)
        #expect(steps(s) == n)
    }

    @Test func badParamsFailGracefully() throws {
        let (s, a, bg) = try session()
        let before = state(s, a)
        let bad: [JSONValue] = [
            ["layer": .id(bg)], ["layer": 9999], ["layer": "x"], ["layer": -1], ["layer": .id(a), "index": 2], ["layer": .id(a), "index": -1],
            ["layer": .id(a), "index": 1.5], ["layer": .id(a), "index": "0"], ["layer": .id(a), "index": .number(Double(UInt64.max))],
            ["layer": .id(a), "visible": "yes"], ["layer": .id(a), "visible": 1],
        ]
        for p in bad {
            #expect(throws: EngineError.self, "\(p)") { try s.execute(id, p) }
        }
        #expect(state(s, a) == before, "a refused call changes nothing")
        let empty = Session()
        #expect(throws: EngineError.self) { try empty.execute(id, [:]) }
        try empty.execute("file.new", ["width": 8, "height": 8])
        #expect(throws: EngineError.self, "no effects: disabled") { try empty.execute(id, [:]) }
    }
}
