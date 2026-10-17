// Edit › Content-Aware Fill's two gaps PixelAgencyEditor worked around (AB-T-0299 item 3): a selection that leaves
// nothing to sample from is refused, and the default colour adaptation leaves a plain fill plain. And PatchMatch stays
// the classical tier when a host empties PCIntelligence's inpaint slot (AB-T-0304).

import Foundation
import PCDocument
@testable import PCEngine
import PCFoundation
import PCIntelligence
import Testing

@Suite struct ContentAwareFillTests {
    /// A `w × h` document whose layer is (51, 153, 204), with a red 12 × 10 patch at (26, 19).
    func plainWithPatch(_ w: Int = 64, _ h: Int = 48) throws -> Session {
        let s = Session()
        try s.execute("file.new", ["width": .int(w), "height": .int(h), "background": "transparent"])
        try s.edit("Plain") { doc, a in
            doc.withRaster(of: a!) { sf in
                sf.fill(PixelRect(x: 0, y: 0, width: w, height: h), with: [51 / 255, 153 / 255, 204 / 255, 1])
                sf.fill(PixelRect(x: 26, y: 19, width: 12, height: 10), with: [1, 0, 0, 1])
            }
        }
        return s
    }

    func layerPixels(_ s: Session, _ r: PixelRect) -> [Float] { s.active!.doc.layer(s.active!.activeLayer!)!.rasterSurface!.readRegion(r) }

    @Test func aSelectionLeavingNothingToSampleIsRefused() throws {
        let s = try plainWithPatch()
        let canvas = PixelRect(x: 0, y: 0, width: 64, height: 48)
        let before = layerPixels(s, canvas)
        try s.execute("select.all")
        let why = try #require(s.disabledReason("edit.contentAwareFill"))
        #expect(why.contains("unselected"), "\(why)")
        #expect(throws: EngineError.self) { try s.execute("edit.contentAwareFill") }
        #expect(throws: EngineError.self) { try s.execute("edit.contentAwareFill", ["sampling": "rectangular"]) }
        #expect(layerPixels(s, canvas) == before, "the layer isn't filled black")
        // A border too thin for a 7 × 7 patch is still nothing to sample from.
        try s.execute("select.rect", ["x": 3, "y": 3, "width": 58, "height": 42])
        #expect(s.disabledReason("edit.contentAwareFill") != nil)
        // Seven columns along one edge are enough.
        try s.execute("select.rect", ["x": 7, "y": 0, "width": 57, "height": 48])
        #expect(s.disabledReason("edit.contentAwareFill") == nil)
        try s.execute("edit.contentAwareFill")
        let c = layerPixels(s, PixelRect(x: 30, y: 22, width: 1, height: 1))
        #expect(abs(c[0] - 51 / 255) < 0.01 && abs(c[2] - 204 / 255) < 0.01, "filled from the strip: \(c)")
    }

    /// The editor's case: a plain layer with a red patch selected comes back plain, at every adaptation level
    /// (Default shifted it to (51, 153, 214), a flat source's variance read as float noise).
    @Test(arguments: [nil, "default", "none", "high", "veryHigh"])
    func aPlainFillStaysExact(_ level: String?) throws {
        let s = try plainWithPatch()
        try s.execute("select.rect", ["x": 26, "y": 19, "width": 12, "height": 10])
        var p: JSONValue = ["seed": 1]
        if let level { p = p.setting("colorAdaptation", .string(level)) }
        try s.execute("edit.contentAwareFill", p)
        let px = layerPixels(s, PixelRect(x: 26, y: 19, width: 12, height: 10))
        var off = 0
        for i in stride(from: 0, to: px.count, by: 4) {
            let got = (0..<3).map { Int((px[i + $0] * 255).rounded()) }
            if got != [51, 153, 204] { off += 1 }
        }
        #expect(off == 0, "\(level ?? "nil"): \(off) of 120 filled pixels aren't (51, 153, 204)")
    }

    /// The editor's stripes (AB-T-0304): 80 × 64, 4 px columns of 51 and 204 gray, a red 12 × 10 patch at (32, 26)
    /// selected, in a session on `services`.
    func stripes(_ services: EngineServices) throws -> Session {
        let s = Session(services: services)
        try s.execute("file.new", ["width": 80, "height": 64, "background": "transparent"])
        try s.edit("Stripes") { doc, a in
            doc.withRaster(of: a!) { sf in
                for x in 0..<80 {
                    let v: Float = (x / 4) % 2 == 0 ? 51 / 255 : 204 / 255
                    sf.fill(PixelRect(x: x, y: 0, width: 1, height: 64), with: [v, v, v, 1])
                }
                sf.fill(PixelRect(x: 32, y: 26, width: 12, height: 10), with: [1, 0, 0, 1])
            }
        }
        try s.execute("select.rect", ["x": 32, "y": 26, "width": 12, "height": 10])
        return s
    }

    /// Row 30 of the filled patch, as 8-bit gray.
    func filledRow(_ s: Session) throws -> [Int] {
        let r = try s.execute("edit.contentAwareFill", ["output": "current", "seed": 1])
        #expect(r["engine"]?.stringValue?.contains("PatchMatch") == true, "\(r)")
        let px = layerPixels(s, PixelRect(x: 32, y: 30, width: 12, height: 1))
        return stride(from: 0, to: px.count, by: 4).map { Int((px[$0] * 255).rounded()) }
    }

    /// PixelAgencyEditor's built-in models module empties the inpaint slot when LaMa isn't ready, the first time
    /// Remove Background or Select › Subject starts it. PatchMatch was registered in that slot, so every fill after it
    /// fell back to EraseKit's diffusion: a smooth membrane (188, 174, 165, 160, 158, …) where the stripes go on, while
    /// the slot's status still read "classical". PatchMatch is PCIntelligence's built-in classical tier now, under the
    /// slot, so emptying the slot, or a model coming and going, leaves it in place.
    @Test func aHostEmptyingTheInpaintSlotKeepsPatchMatch() throws {
        let expected = [51, 51, 51, 51, 204, 204, 204, 204, 51, 51, 51, 51]
        var row: [Int]
        let services = EngineServices()
        let registry = services.intelligence.registry
        row = try filledRow(stripes(services))
        #expect(row == expected, "before the host touches the slot: \(row)")
        registry.unregister(.inpaint)
        #expect(registry.status(of: .inpaint) == .available(tier: .classical, engine: "PatchMatch", injected: false))
        row = try filledRow(stripes(services))
        #expect(row == expected, "after the host empties the slot: \(row)")
        registry.removeAll()
        row = try filledRow(stripes(services))
        #expect(row == expected, "after the host empties every slot: \(row)")
        #expect(registry.injectedCapabilities.isEmpty)
    }

    /// A host that brings its own PCIntelligence gets PatchMatch as its classical inpaint tier too.
    @Test func aHostsOwnIntelligenceGetsPatchMatch() throws {
        let services = EngineServices(intelligence: PCIntelligence())
        #expect(try filledRow(stripes(services)) == [51, 51, 51, 51, 204, 204, 204, 204, 51, 51, 51, 51])
    }
}
