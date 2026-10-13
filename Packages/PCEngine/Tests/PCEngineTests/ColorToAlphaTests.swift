// Port of photocraft-engine (crates/engine/src/color_to_alpha_cmds.rs `mod tests`), MIT OR Apache-2.0, © ArtCraft Team and the PhotoCraft contributors.

import Foundation
import PCAlgo
import PCDocument
@testable import PCEngine
import PCFoundation
import Testing

@Suite struct ColorToAlphaTests {
    static let id = ColorToAlphaCommands.id
    static let w: Int32 = 24
    static let h: Int32 = 16

    /// A document with a white Background and, when `layer`, a pixel layer on top; both filled
    /// with a black-to-white ramp (column 0 black, last column white).
    func session(_ depth: Int, _ mode: String, _ layer: Bool) throws -> Session {
        let s = Session()
        try s.execute("file.new", ["width": .int(Int(Self.w)), "height": .int(Int(Self.h)), "depth": .int(depth), "mode": .string(mode)])
        if layer { try s.execute("layer.new.layer", [:]) }
        try s.edit("ramp") { doc, active in
            guard let id = active else { return }
            _ = doc.withRaster(of: id) { surf in
                for x in 0..<Self.w {
                    let v = Float(x) / Float(Self.w - 1)
                    surf.fill(PixelRect(x0: x, y0: 0, x1: x + 1, y1: Self.h), with: surf.format.components(fromRGBA: SIMD4(v, v, v, 1)))
                }
            }
        }
        return s
    }

    func rgba(_ s: Session, _ x: Int32, _ y: Int32) -> SIMD4<Float> {
        guard let d = s.active, let id = d.activeLayer, let surf = d.doc.layer(id)?.surface else { return SIMD4(-1, -1, -1, -1) }
        return surf.rgba(x: x, y: y)
    }

    func pixels(_ s: Session) -> [Float] {
        guard let d = s.active, let id = d.activeLayer, let surf = d.doc.layer(id)?.surface else { return [] }
        return surf.readRegion(PixelRect(x0: 0, y0: 0, x1: Self.w, y1: Self.h))
    }

    @Test func removesWhiteAtEveryDepthAndUndoesInOneStep() throws {
        for (depth, mode) in [(8, "rgb"), (16, "rgb"), (32, "rgb"), (8, "gray"), (16, "gray"), (32, "gray")] {
            let s = try session(depth, mode, true)
            let before = pixels(s)
            let steps = s.active?.history.pastCount ?? -1
            let r = try s.execute(Self.id, [:])
            #expect(r["filter"]?["filter"] == "colorToAlpha", "\(r)")
            #expect(s.active?.history.pastCount == steps + 1)
            #expect(s.active?.history.undoLabel == "Color to Alpha")
            let tol: Float = depth == 8 ? 3 / 255 : 2e-3
            #expect(rgba(s, Self.w - 1, 3).w <= tol, "\(depth) \(mode): white is transparent")
            #expect(rgba(s, 0, 3) == SIMD4(0, 0, 0, 1), "\(depth) \(mode): black is kept")
            // A grey becomes black with the grey's darkness as opacity.
            let x = Self.w / 2
            let v = Float(x) / Float(Self.w - 1)
            let p = rgba(s, x, 3)
            #expect(abs(p.w - (1 - v)) <= tol && p.x <= tol, "\(depth) \(mode): \(p)")
            try s.execute("edit.undo", [:])
            #expect(pixels(s) == before, "\(depth) \(mode): undo")
        }
    }

    @Test func thresholdsAndColourParamsApply() throws {
        let s = try session(16, "rgb", true)
        try s.execute(Self.id, ["color": "#000000", "transparencyThreshold": 0.25, "opacityThreshold": 0.75])
        // Black key: dark greys (opacity ≤ 0.25) vanish, light ones (≥ 0.75) stay as they were.
        #expect(rgba(s, 2, 0).w == 0)
        #expect(rgba(s, Self.w - 2, 0).w == 1)
        let mid = rgba(s, Self.w / 2, 0)
        #expect(mid.w > 0 && mid.w < 1, "\(mid)")
        // The array form of the colour works too.
        let t = try session(8, "rgb", true)
        try t.execute(Self.id, ["color": [1.0, 1.0, 1.0]])
        #expect(rgba(t, Self.w - 1, 0).w < 0.02)
    }

    @Test func respectsTheSelection() throws {
        let s = try session(8, "rgb", true)
        try s.execute("select.rect", ["x": .int(Int(Self.w / 2)), "y": 0, "width": .int(Int(Self.w / 2)), "height": .int(Int(Self.h / 2))])
        try s.execute(Self.id, [:])
        #expect(rgba(s, Self.w - 1, 0).w < 0.02, "inside the selection")
        #expect(rgba(s, Self.w - 1, Self.h - 1).w == 1, "outside the selection")
    }

    @Test func theBackgroundBecomesANormalLayerAndUndoRestoresIt() throws {
        let s = try session(8, "rgb", false)
        #expect(s.isEnabled(Self.id))
        try s.execute(Self.id, [:])
        func name() -> String? { s.active.flatMap { d in d.activeLayer.flatMap { d.doc.layer($0)?.name } } }
        #expect(name() == "Layer 0")
        #expect(rgba(s, Self.w - 1, 0).w < 0.02, "the Background really became transparent")
        try s.execute("edit.undo", [:])
        #expect(name() == "Background")
        let d = try #require(s.active)
        let active = try #require(d.activeLayer)
        #expect(d.doc.isBackground(active))
    }

    @Test func lockedLayersAndUnsupportedDocumentsAreRefused() throws {
        let s = try session(8, "rgb", true)
        try s.execute("layer.lockLayers", ["transparency": true])
        #expect(!s.isEnabled(Self.id))
        let before = pixels(s)
        #expect(throws: (any Error).self) { try s.execute(Self.id, [:]) }
        #expect(pixels(s) == before)
        // Even when the menu check is bypassed (Last Filter), the filter refuses the lock.
        #expect(throws: (any Error).self) { try FilterCommands.runFilter(s, Self.id, [:]) }
        #expect(pixels(s) == before)

        let s2 = try session(8, "rgb", true)
        try s2.execute("layer.lockLayers", ["pixels": true])
        #expect(!s2.isEnabled(Self.id))

        for mode in ["cmyk", "lab"] {
            let t = Session()
            try t.execute("file.new", ["width": 8, "height": 8, "mode": .string(mode)])
            try t.execute("layer.new.layer", [:])
            #expect(!t.isEnabled(Self.id), "\(mode)")
        }
        let s3 = Session()
        #expect(!s3.isEnabled(Self.id))
        try s3.execute("file.new", ["width": 8, "height": 8])
        try s3.execute("layer.newAdjustmentLayer.invert", [:])
        #expect(!s3.isEnabled(Self.id))
    }

    /// photocraft's list minus `null`: PCEngine's dispatcher treats null params as none (`{}`),
    /// so `null` runs the filter with its defaults instead of failing.
    @Test func badParamsAreRejectedWithoutChanges() throws {
        let s = try session(8, "rgb", true)
        let before = pixels(s)
        let cases: [JSONValue] = [
            7, "white", ["color": "white"], ["color": "#12"], ["color": "#zzzzzz"], ["color": [1.0, 1.0]], ["color": [1.0, 2.0, 0.0]],
            ["color": [1.0, "a", 0.0]], ["color": 16_777_215], ["transparencyThreshold": -0.1], ["opacityThreshold": 1.5],
            ["opacityThreshold": "1"], ["transparencyThreshold": 1e308],
        ]
        for p in cases {
            do {
                try s.execute(Self.id, p)
                Issue.record("accepted \(p)")
            } catch {
                if case .badParams? = error as? EngineError {} else { Issue.record("\(p): \(error)") }
            }
        }
        #expect(pixels(s) == before)
    }

    @Test func smartObjectsGetASmartFilterAndLastFilterRepeats() throws {
        let s = try session(8, "rgb", true)
        try GalleryTests.makeSmartObject(s)
        try s.execute(Self.id, ["color": "#ffffff"])
        let d = try #require(s.active)
        guard case .smart(let sm)? = d.doc.layer(try #require(d.activeLayer))?.content else {
            Issue.record("not a smart object")
            return
        }
        #expect(sm.smartFilters.count == 1)
        #expect(sm.smartFilters.first?.command == Self.id)
        #expect((sm.cache?.rgba(x: Self.w - 1, y: 0).w ?? 1) < 0.02, "the cache was re-rendered")

        let t = try session(8, "rgb", true)
        try t.execute(Self.id, ["opacityThreshold": 0.5])
        let once = pixels(t)
        try t.execute("filter.lastFilter", [:])
        #expect(pixels(t) != once, "Last Filter ran Color to Alpha again")
    }

    @Test func lenientMappingClampsRecordedParams() {
        let a = ColorToAlphaCommands.params(["color": [2.0, -1.0, 0.5], "transparencyThreshold": -3, "opacityThreshold": 9])
        #expect(a == ColorToAlpha(color: SIMD4(1, 0, 0.5, 1), transparencyThreshold: 0, opacityThreshold: 1))
        #expect(ColorToAlphaCommands.params(.null) == ColorToAlpha(color: ColorToAlphaCommands.white, transparencyThreshold: 0, opacityThreshold: 1))
    }
}
