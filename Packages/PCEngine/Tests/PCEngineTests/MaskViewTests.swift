// Port of photocraft-engine (crates/engine/src/mask_view_cmds/tests.rs), MIT OR Apache-2.0, © ArtCraft Team and the PhotoCraft contributors.

import Foundation
import PCDocument
import PCEngine
import PCFoundation
import Testing

/// Fills the whole canvas of the active pixel layer with `c` (photocraft's `edit.fill` without a
/// selection).
fileprivate func fillActive(_ s: Session, _ c: SIMD4<Float>) throws {
    try s.edit("fill") { doc, active in
        guard let id = active else { return }
        let b = doc.bounds
        doc.withRaster(of: id) { $0.writeRegion(b, PixelCodec.fromRGBA($0.format, rgba: [SIMD4<Float>](repeating: c, count: b.area))) }
    }
}

@Suite struct MaskViewTests {
    let id = "view.layerMask"
    let overlay = "layer.toggleMaskOverlay"

    /// 40×20 document: Background, then "Masked" (red, mask hiding the left half) on top.
    func session() throws -> (Session, LayerId, LayerId) {
        let s = Session()
        try s.execute("file.new", ["width": 40, "height": 20])
        let bg = try #require(s.active?.doc.layers.first?.id)
        let masked = LayerId(try #require(try s.execute("layer.new.layer", ["name": "Masked"])["layer"]?.uint64Value))
        try fillActive(s, SIMD4(1, 0, 0, 1))
        try s.execute("select.rect", ["x": 20, "y": 0, "width": 20, "height": 20])
        try s.execute("layer.layerMask.revealSelection")
        try s.execute("select.deselect")
        try s.updateActive { $0.savedRevision = $0.revision }
        return (s, masked, bg)
    }

    /// The view as `document.inspect` reports it.
    func view(_ s: Session) throws -> JSONValue { try s.execute("document.inspect")["layerMaskView"] ?? .null }

    @Test func modesToggleAndShowInInspectWithoutHistory() throws {
        let (s, masked, _) = try session()
        let steps = s.active?.history.entries.count
        #expect(try view(s) == .null)
        #expect(try s.execute(id, [:])["mode"] == "gray", "no mode: toggle the grayscale view")
        #expect(try view(s) == ["layer": .id(masked), "mode": "gray"])
        #expect(try s.execute(id, ["mode": "toggleGray"])["mode"] == "off", "⌥-click again returns")
        #expect(try s.execute(id, ["layer": .id(masked), "mode": "overlay"])["mode"] == "overlay")
        #expect(s.active?.channelView.layerMask?.mode == .overlay)
        #expect(try s.execute(id, ["mode": "toggleGray"])["mode"] == "gray", "overlay → gray")
        #expect(try s.execute(id, ["mode": "off"])["mode"] == "off")
        let st = try #require(s.active)
        #expect(st.history.entries.count == steps, "view changes are not history steps")
        #expect(!st.isDirty, "a clean document stays clean")
        #expect(st.lastDamage == .empty, "no recomposite")
    }

    @Test func aMaskViewNeverAltersPixels() throws {
        let (s, masked, _) = try session()
        let before = try #require(s.active?.doc)
        func px() throws -> [SIMD4<Float>] { try s.services.renderer.render(try #require(s.active?.doc), region: PixelRect(x0: 0, y0: 0, x1: 40, y1: 20)).px }
        let composite = try px()
        for mode in ["gray", "overlay", "toggleOverlay", "toggleGray", "off"] {
            try s.execute(id, ["layer": .id(masked), "mode": .string(mode)])
            #expect(s.active?.doc == before, "\(mode): the document is untouched")
            #expect(try px() == composite, "\(mode): same composite")
        }
    }

    @Test func theViewEndsWithItsLayerOrMask() throws {
        let (s, masked, bg) = try session()
        try s.execute(id, ["mode": "gray"])
        try s.execute("layer.select", ["layer": .id(bg)])
        #expect(try view(s) == .null, "selecting another layer leaves mask view")
        #expect(s.active?.channelView.layerMask == nil)
        // ⌥-clicking a mask of an unselected layer selects it.
        try s.execute(id, ["layer": .id(masked), "mode": "overlay"])
        #expect(s.active?.activeLayer == masked)
        try s.execute("layer.layerMask.delete")
        #expect(s.active?.channelView.layerMask == nil, "deleting the mask ends the view")
        s.undo()
        #expect(s.active?.channelView.layerMask == nil, "undo doesn't bring a stale view back")
    }

    @Test func badParamsAndNoMaskFailGracefully() throws {
        let (s, masked, bg) = try session()
        let bad: [JSONValue] = [
            ["layer": .id(bg), "mode": "gray"], ["layer": .id(bg)], ["layer": 999_999, "mode": "gray"], ["layer": "x"], ["layer": -1],
            ["mode": 3], ["mode": "sideways"], ["layer": .id(masked), "mode": ["gray"]],
        ]
        for p in bad {
            #expect(throws: EngineError.self, "\(p) should fail") { try s.execute(id, p) }
        }
        #expect(try view(s) == .null, "failures change nothing")
        // "off" is always fine, even for a layer without a mask, and leaves another view alone.
        try s.execute(id, ["layer": .id(masked), "mode": "gray"])
        #expect(try s.execute(id, ["layer": .id(bg), "mode": "off"])["mode"] == "off")
        #expect(try view(s)["mode"] == "gray")
        let empty = Session()
        #expect(throws: EngineError.self) { try empty.execute(id, ["mode": "gray"]) }
    }

    /// #1765: `\` shows the active layer's mask as a rubylith and hides it again; without a mask
    /// (or a document) it is disabled and errors.
    @Test func backslashCommandTogglesTheOverlay() throws {
        let (s, masked, bg) = try session()
        let steps = s.active?.history.entries.count
        #expect(s.isEnabled(overlay))
        #expect(try s.execute(overlay, [:])["mode"] == "overlay")
        #expect(try view(s) == ["layer": .id(masked), "mode": "overlay"])
        #expect(try s.execute(overlay, .null)["mode"] == "off", "again: back to the composite")
        #expect(try view(s) == .null)
        // From the grayscale view it switches to the overlay.
        try s.execute(id, ["mode": "gray"])
        #expect(try s.execute(overlay, ["mode": "gray"])["mode"] == "overlay", "`mode` is ignored")
        try s.execute(overlay, [:])
        let st = try #require(s.active)
        #expect(st.history.entries.count == steps, "not a history step")
        #expect(!st.isDirty)
        try s.execute("layer.select", ["layer": .id(bg)])
        #expect(!s.isEnabled(overlay))
        #expect(throws: EngineError.self) { try s.execute(overlay, [:]) }
        #expect(throws: EngineError.self) { try s.execute(overlay, ["layer": .id(bg)]) }
        #expect(throws: EngineError.self) { try s.execute(overlay, ["layer": "x"]) }
        #expect(throws: EngineError.self) { try s.execute(overlay, [1]) }
        #expect(try view(s) == .null)
        let empty = Session()
        #expect(!empty.isEnabled(overlay))
        #expect(throws: EngineError.self) { try empty.execute(overlay, [:]) }
    }
}
