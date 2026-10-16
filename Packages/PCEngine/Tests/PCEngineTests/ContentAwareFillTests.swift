// Edit › Content-Aware Fill's two gaps PixelAgencyEditor worked around (AB-T-0299 item 3): a selection that leaves
// nothing to sample from is refused, and the default colour adaptation leaves a plain fill plain.

import Foundation
import PCDocument
@testable import PCEngine
import PCFoundation
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
}
