// Spot Healing's Content-Aware carrying a curved edge through the spot (AB-T-0299 item 4): PixelAgencyEditor's
// `SpotHealingTests.contentAwareCarriesACurvedEdgeThroughTheSpot`, reproduced on the engine.

import Foundation
@testable import PCEngine
import PCFoundation
import PCPaint
import Testing

@Suite struct SpotHealingCurveTests {
    static let (width, height) = (320, 200)
    static func skyline(_ x: Double) -> Double { 110 + 28 * sin(x / 37) }
    static let center = (x: 160.0, y: skyline(160))

    /// The editor's ridge: a sky over a curved, grainy hilltop, with (`disc`) a red disc on the curve. 8-bit levels,
    /// row by row as the editor's fixture draws them (its grain is one LCG run over the image).
    static func ridge(disc: Bool) -> [SIMD3<UInt8>] {
        var out: [SIMD3<UInt8>] = []
        out.reserveCapacity(width * height)
        var seed: UInt32 = 7
        for y in 0..<height {
            for x in 0..<width {
                seed = seed &* 1664525 &+ 1013904223
                let grain = Double(Int(seed >> 28) - 8) * 2
                let sky = Double(y) < skyline(Double(x))
                let dx = Double(x) - center.x, dy = Double(y) - center.y
                let red = disc && dx * dx + dy * dy < 22 * 22
                let c = red ? [220.0, 30, 30] : sky ? [120 + Double(y) * 0.5, 160 + Double(y) * 0.3, 230]
                                                 : [60 + grain, 110 + grain, 50 + grain]
                out.append(SIMD3(c.map { UInt8(max(0, min(255, $0))) }))
            }
        }
        return out
    }

    /// The ridge with its disc healed by `paint.spotHealing` of `type` (the editor's 56 px hard brush, a click), and
    /// the mean difference from the scene without the disc inside the disc, in 8-bit levels.
    static func healError(_ type: String) throws -> Double {
        let s = Session()
        try s.execute("file.new", ["width": .int(width), "height": .int(height), "depth": 8, "mode": "rgb"])
        let damaged = ridge(disc: true)
        try s.edit("setup") { doc, active in
            let b = doc.bounds
            _ = doc.withRaster(of: active!) { surf in
                let fmt = surf.format
                var data: [Float] = []
                data.reserveCapacity(b.area * fmt.channels)
                for c in damaged { data += fromRGBA(fmt, SIMD4(Float(c.x) / 255, Float(c.y) / 255, Float(c.z) / 255, 1)) }
                surf.writeRegion(b, data)
            }
        }
        try s.execute("paint.spotHealing", ["points": [[.number(center.x), .number(center.y)], [.number(center.x + 0.5), .number(center.y)]],
                                            "size": 56, "hardness": 100, "type": .string(type)])
        let surf = try #require(s.active.flatMap { d in d.activeLayer.flatMap { d.doc.layer($0)?.surface } })
        let truth = ridge(disc: false)
        var (sum, count) = (0.0, 0.0)
        for y in 0..<height {
            for x in 0..<width {
                let dx = Double(x) - center.x, dy = Double(y) - center.y
                guard dx * dx + dy * dy < 22 * 22 else { continue }
                let p = surf.rgba(x: Int32(x), y: Int32(y)), t = truth[y * width + x]
                for c in 0..<3 { sum += abs((Double(p[c]) * 255).rounded() - Double(t[c])); count += 1 }
            }
        }
        return sum / count
    }

    /// Content-Aware rebuilds the spot from patches all around it, so the hill's edge carries on through it as a
    /// curve: close to what the disc hid, and far closer than Proximity Match's one copied patch. Compositor's
    /// PatchPixels.c met both bounds; before AB-T-0299 the engine was off by 26.3 levels against Proximity's 43.3.
    @Test func contentAwareCarriesACurvedEdgeThroughTheSpot() throws {
        let contentAware = try Self.healError("contentAware")
        let proximity = try Self.healError("proximityMatch")
        #expect(contentAware < 12, "Content-Aware is close to what the disc hid: off by \(contentAware) levels")
        #expect(contentAware < proximity / 2, "and far closer than one copied patch: \(contentAware) against \(proximity)")
    }
}
