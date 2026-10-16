// paint.blur's and paint.sharpen's optional Radius (AB-T-0299 item 1): the Gaussian's sigma in pixels, whatever the
// brush's size, as PixelAgencyEditor's Blur tool sets it. Without one, each keeps the sigma it had.

import Foundation
import PCDocument
@testable import PCEngine
import PCFoundation
import Testing

@Suite struct FocusRadiusTests {
    /// An 80 × 40 layer, black left of x = 40 and white from it, stroked down the edge by `cmd` with `extra`.
    func stroked(_ cmd: String, _ extra: JSONValue, size: Double = 30) throws -> [Float] {
        let s = Session()
        try s.execute("file.new", ["width": 80, "height": 40, "background": "transparent"])
        try s.edit("Edge") { doc, a in
            doc.withRaster(of: a!) { sf in
                sf.fill(PixelRect(x: 0, y: 0, width: 40, height: 40), with: [0, 0, 0, 1])
                sf.fill(PixelRect(x: 40, y: 0, width: 40, height: 40), with: [1, 1, 1, 1])
            }
        }
        var p: JSONValue = ["points": [[40, 2], [40, 38]], "size": .number(size), "hardness": 100, "strength": 100]
        for (k, v) in extra.objectValue ?? [:] { p = p.setting(k, v) }
        try s.execute(cmd, p)
        return s.active!.doc.layer(s.active!.activeLayer!)!.rasterSurface!.readRegion(PixelRect(x: 0, y: 0, width: 80, height: 40))
    }

    /// Red at (x, 20).
    func red(_ px: [Float], _ x: Int) -> Float { px[(20 * 80 + x) * 4] }

    @Test func blurRadiusSetsHowFarItSoftens() throws {
        let narrow = try stroked("paint.blur", ["radius": 1]), wide = try stroked("paint.blur", ["radius": 6])
        // Five pixels into the white, the dabs of a 1 px blur have barely reached (they compound along the stroke);
        // a 6 px one's have softened it by a third.
        #expect(red(narrow, 45) > 0.9, "radius 1 at 5 px: \(red(narrow, 45))")
        #expect(red(wide, 45) < 0.8, "radius 6 at 5 px: \(red(wide, 45))")
        #expect(red(wide, 34) > red(narrow, 34) + 0.2, "and on the black side: \(red(wide, 34)) against \(red(narrow, 34))")
        // Outside the brush, nothing changes.
        #expect(red(wide, 60) == 1 && red(wide, 20) == 0)
    }

    @Test func withoutARadiusEachKeepsItsSigma() throws {
        // Blur's sigma follows the brush: 3 % of 100 px.
        #expect(try stroked("paint.blur", [:], size: 100) == stroked("paint.blur", ["radius": 3], size: 100))
        #expect(try stroked("paint.blur", [:], size: 100) != stroked("paint.blur", ["radius": 1.5], size: 100))
        // Sharpen's unsharp mask is 1 px.
        #expect(try stroked("paint.sharpen", ["protectDetail": false]) == stroked("paint.sharpen", ["protectDetail": false, "radius": 1]))
        #expect(try stroked("paint.sharpen", ["protectDetail": false]) != stroked("paint.sharpen", ["protectDetail": false, "radius": 4]))
    }

    @Test func aBadRadiusIsRefused() throws {
        for bad: JSONValue in [-1, 0, "wide", .number(.infinity)] {
            #expect(throws: EngineError.self, "\(bad)") { try stroked("paint.blur", ["radius": bad]) }
        }
        #expect(throws: EngineError.self) { try stroked("paint.sharpen", ["radius": -2]) }
    }
}
