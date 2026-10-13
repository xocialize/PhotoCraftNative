// Port of photocraft-io (crates/io/tests/modes.rs), MIT OR Apache-2.0, © ArtCraft Team and the PhotoCraft contributors.
//
// Indexed Color and Duotone documents in flat exports (photocraft flat.rs `export_flat`: Indexed →
// PNG-8 with its colour table, Duotone → the inks rendered as RGB), through the default
// `ImageIOCodec`.

import Foundation
import PCDocument
import PCFoundation
import Testing
@testable import PCIO

@Suite struct ModesTests {
    init() { ExportSweep.install() }
    static func doc(_ mode: ColorMode) -> Document {
        var d = Document.withBackground(name: "m", size: PixelSize(width: 4, height: 2), mode: .rgb, depth: .u8, fill: .rgb(1, 0, 0, 1))
        d.mode = mode
        return d
    }

    static func isPalettePNG(_ b: [UInt8]) -> Bool {
        // IHDR colour type 3 = indexed; a PLTE chunk follows.
        let plte = Array("PLTE".utf8)
        return b.count > 25 && b[25] == 3 && (0 ... b.count - 4).contains { Array(b[$0 ..< $0 + 4]) == plte }
    }

    @Test func indexedPNGIsPalettePNG() throws {
        var d = ModesTests.doc(.indexed)
        d.colorTable = ColorTable(colors: [SIMD3(0, 0, 0), SIMD3(255, 0, 0)], transparent: nil)
        let r = try PSDKit.export(d, "x.png")
        #expect(ModesTests.isPalettePNG(r.bytes), "colour type \(r.bytes.count > 25 ? r.bytes[25] : 0)")
        #expect(r.warnings.contains("written as an 8-bit palette PNG (2 colours)"), "\(r.warnings)")
        let back = try PSDKit.importFile("x.png", r.bytes).document
        let px = try #require(back.layers.first?.surface).rgba(x: 1, y: 1)
        #expect(px.x == 1 && px.y == 0 && px.z == 0, "\(px)")
        // Other formats keep the expanded pixels.
        #expect(!(try PSDKit.export(d, "x.tif").bytes.isEmpty))
    }

    @Test func duotoneExportsTheInksAsRGB() throws {
        // Mid gray background.
        var d = Document.withBackground(name: "m", size: PixelSize(width: 4, height: 2), mode: .grayscale, depth: .u8, fill: .rgb(0.5, 0.5, 0.5, 1))
        d.mode = .duotone
        d.duotone = Duotone(inks: [DuotoneInk(name: "Black", color: .zero), DuotoneInk(name: "Orange", color: SIMD3(1, 0.5, 0))], psdRaw: nil)
        let r = try PSDKit.export(d, "x.png")
        let back = try PSDKit.importFile("x.png", r.bytes).document
        let px = try #require(back.layers.first?.surface).rgba(x: 0, y: 0)
        #expect(r.warnings.contains { $0.contains("Duotone") }, "\(r.warnings)")
        #expect(px.x > px.z + 0.05, "warm: \(px)")
    }

    /// #3047: the palette PNG lost its pHYs chunk and reopened at 72 ppi.
    @Test func indexedPNGKeepsTheDocumentResolution() throws {
        var d = ModesTests.doc(.indexed)
        d.resolutionDpi = 300
        d.colorTable = ColorTable(colors: [SIMD3(0, 0, 0), SIMD3(255, 0, 0)], transparent: nil)
        let r = try PSDKit.export(d, "x.png")
        #expect(ModesTests.isPalettePNG(r.bytes), "still a palette PNG")
        let back = try PSDKit.importFile("x.png", r.bytes).document
        #expect(abs(back.resolutionDpi - 300) < 0.01, "\(back.resolutionDpi)")
    }
}
