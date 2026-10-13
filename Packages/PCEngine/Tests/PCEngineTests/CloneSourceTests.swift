// Port of photocraft-engine (crates/engine/src/presets/clone_source.rs `mod tests`), MIT OR Apache-2.0, © ArtCraft Team and the PhotoCraft contributors.

import Foundation
import PCDocument
@testable import PCEngine
import PCFoundation
import PCPaint
import Testing

@Suite struct CloneSourceTests {
    @Test func sourceRectClampsHugeSources() {
        // A 3e9 source with a rotation makes the mapping a resample, so sourceRect sees mapped
        // coordinates far outside Int32: they clamp, the rect stays ordered.
        for sx in [3_000_000_000.0, -3_000_000_000.0] {
            let m = CloneMapping(source: SIMD2(sx, 0), anchor: SIMD2(10, 10), m: CloneSourceCommands.transformMatrix(SIMD2(100, 100), 45, false, false))
            let r = m.sourceRect(PixelRect(x0: 0, y0: 0, x1: 24, y1: 16))
            #expect(r.x0 <= r.x1 && r.y0 <= r.y1, "rect must stay ordered: \(r)")
        }
    }

    @Test func sourceRectNormalCaseUnchanged() {
        let m = CloneMapping(source: SIMD2(200, 0), anchor: SIMD2(10, 10), m: SIMD4(1, 0, 0, 1))
        #expect(m.sourceRect(PixelRect(x0: 0, y0: 0, x1: 24, y1: 16)) == PixelRect(x0: 188, y0: -12, x1: 216, y1: 8))
    }

    @Test func linkedWidthAndHeightKeepTheirRatio() throws {
        let s = Session()
        try s.execute("cloneSource.set", ["width": 50, "height": 200])
        try s.execute("cloneSource.set", ["width": 100])
        #expect(s.state[CloneSourceCommands.SourcesKey.self].activeSlot.scale == SIMD2(100, 200), "unlinked: H stays")
        let r = try s.execute("cloneSource.set", ["linked": true, "width": 150])
        #expect(r["width"]?.doubleValue == 150 && r["height"]?.doubleValue == 300 && r["linked"]?.boolValue == true)
        try s.execute("cloneSource.set", ["height": 60])
        #expect(s.state[CloneSourceCommands.SourcesKey.self].activeSlot.scale == SIMD2(30, 60), "linked: W follows H")
    }

    @Test func overlayBlendModesMixWithTheImageUnderTheBrush() {
        let src = SIMD4<Float>(0.8, 0.2, 0.5, 1), dst = SIMD4<Float>(0.3, 0.6, 0.5, 1)
        func close(_ a: SIMD4<Float>, _ b: SIMD4<Float>) -> Bool { (0..<4).allSatisfy { abs(a[$0] - b[$0]) < 1e-6 } }
        #expect(CloneSourceCommands.overlayBlend("normal", src, dst) == src)
        #expect(close(CloneSourceCommands.overlayBlend("darken", src, dst), SIMD4(0.3, 0.2, 0.5, 1)))
        #expect(close(CloneSourceCommands.overlayBlend("lighten", src, dst), SIMD4(0.8, 0.6, 0.5, 1)))
        #expect(close(CloneSourceCommands.overlayBlend("difference", src, dst), SIMD4(0.5, 0.4, 0, 1)))
        #expect(CloneSourceCommands.overlayBlend("difference", src, SIMD4(0.3, 0.6, 0.5, 0)) == src, "a transparent image leaves the source as is")
    }

    /// Not a photocraft test: the slot commands' JSON and the aligned anchor the strokes keep.
    @Test func slotsSelectResetAndOverlay() throws {
        let s = Session()
        let r = try s.execute("cloneSource.set", ["index": 2, "source": [8, 9], "rotation": 270, "flipH": true])
        #expect(r["index"]?.intValue == 2 && r["rotation"]?.doubleValue == -90 && r["offset"] == .null)
        #expect(try s.execute("cloneSource.list")["active"]?.intValue == 2)
        let o = try s.execute("cloneSource.set", ["offset": [4, -2]])
        #expect(o["source"] == [12, 7] && o["anchor"] == [8, 9] && o["offset"] == [4, -2])
        let t = try s.execute("cloneSource.resetTransform")
        #expect(t["rotation"]?.doubleValue == 0 && t["flipH"]?.boolValue == false)
        try s.execute("cloneSource.select", ["index": 0])
        #expect(throws: EngineError.self) { try s.execute("cloneSource.select", ["index": 5]) }
        #expect(throws: EngineError.self) { try s.execute("cloneSource.set", ["offset": [1, 1]]) }
        #expect(throws: EngineError.self) { try s.execute("cloneSource.overlay", ["opacity": 40, "blend": "multiply"]) }
        let ov = try s.execute("cloneSource.overlay", ["blend": "darken", "autoHide": false])
        #expect(ov["blend"] == "darken" && ov["opacity"]?.doubleValue == 40 && ov["auto_hide"] == false)
        // An aligned stroke from the slot pairs the anchor; the next stroke keeps it.
        try s.execute("file.new", ["width": 32, "height": 32])
        try s.execute("cloneSource.set", ["source": [4, 4]])
        let a = try s.execute("paint.cloneStamp", ["points": [[20, 20]], "size": 4])
        #expect(a["offset"] == [-16, -16])
        let b = try s.execute("paint.cloneStamp", ["points": [[24, 20]], "size": 4])
        #expect(b["offset"] == [-16, -16])
        #expect(s.state[CloneSourceCommands.SourcesKey.self].activeSlot.anchor == SIMD2(20, 20))
    }
}
