// Port of photocraft-io (crates/io/tests/lab16.rs), MIT OR Apache-2.0, © ArtCraft Team and the PhotoCraft contributors.
//
// 16-bit Lab PSDs: Photoshop stores a*/b* as `32768 + 256·a` (0...65280 spans −128...127), not on
// the full 0...65535 range. Layer pixels, the merged image and patterns use that scale, and the
// documents' a*/b* stay on the 8-bit scale `(a + 128) / 255` at every depth.

import Foundation
import PCDocument
import PCFoundation
import PCPSD
import Testing
@testable import PCIO

@Suite struct Lab16Tests {
    init() { ExportSweep.install() }
    /// a* = 52.29, b* = −85.08 (a gradient stop of psd-tools 4x4_16bit_lab) on the document scale.
    static let a: Float = (52.29 + 128) / 255
    static let b: Float = (-85.08 + 128) / 255

    static func labDoc(_ depth: SampleType) -> Document {
        var d = Document(name: "lab", size: PixelSize(width: 3, height: 2), mode: .lab, depth: depth)
        var s = Surface(format: PixelFormat(mode: .lab, sample: depth, alpha: true))
        s.writeRegion(rect(0, 0, 3, 2), (0 ..< 6).flatMap { _ in [0.1907, a, b, 1] })
        d.layers.append(Layer(name: "px", content: .raster(s)))
        return d
    }

    @Test(arguments: PSDKit.conventions) func lab16ChromaUsesPhotoshopsScale(_ photoshop: Bool) throws {
        let out = try PSDKit.export(Lab16Tests.labDoc(.u16), "x.psd", PSDKit.options(photoshop))
        let file = try PSDFile(bytes: out.bytes)
        #expect(file.header.depth == 16)
        // Merged image: planes L, a, b.
        let m = try file.decodeMerged()
        let n = 6
        let a = PSDKit.be16(m, n), b = PSDKit.be16(m, 2 * n)
        #expect(abs(Int(a) - (32768 + Int((256 * Float(52.29)).rounded()))) <= 1, "a = \(a)")
        #expect(abs(Int(b) - (32768 - Int((256 * Float(85.08)).rounded()))) <= 1, "b = \(b)")
        // Layer channel 1 (a*) the same.
        let plane = try file.layers[0].decodeChannel(1, depth: 16, version: file.header.version)
        #expect(abs(Int(PSDKit.be16(plane, 0)) - Int(a)) <= 1)
        // And back: the document values survive.
        let back = try PSDKit.importFile("x.psd", out.bytes, photoshop: photoshop).document
        let p = try #require(back.layers.first?.surface).pixel(x: 1, y: 1)
        #expect(abs(p[1] - Lab16Tests.a) < 2e-5 && abs(p[2] - Lab16Tests.b) < 2e-5, "\(p)")
    }

    @Test(arguments: PSDKit.conventions) func labRoundTripsAtEveryDepth(_ photoshop: Bool) throws {
        for depth in [SampleType.u8, .u16, .f32] {
            let doc = Lab16Tests.labDoc(depth)
            let out = try PSDKit.export(doc, "x.psd", PSDKit.options(photoshop), lint: true)
            if depth == .f32 {
                // Photoshop has no 32-bit Lab mode: the file is written at 16 bits, with a warning
                // (photocraft writes a 32-bit Lab file Photoshop refuses).
                #expect(try PSDFile(bytes: out.bytes).header.depth == 16)
                #expect(out.warnings.contains { $0.contains("no 32-bit Lab") }, "\(out.warnings)")
            }
            let back = try PSDKit.importFile("x.psd", out.bytes, photoshop: photoshop).document
            let p = try #require(back.layers.first?.surface).pixel(x: 2, y: 0)
            let tol: Float = depth == .u8 ? 0.5 / 255 + 1e-6 : 2e-5
            #expect(abs(p[1] - Lab16Tests.a) <= tol && abs(p[2] - Lab16Tests.b) <= tol, "\(depth): \(p)")
            let (x, y) = (try PSDKit.flatten(doc), try PSDKit.flatten(back))
            for (u, v) in zip(x, y) {
                #expect((0 ..< 4).allSatisfy { abs(u[$0] - v[$0]) <= 1 / 255 }, "\(depth): \(u) vs \(v)")
            }
        }
    }
}
