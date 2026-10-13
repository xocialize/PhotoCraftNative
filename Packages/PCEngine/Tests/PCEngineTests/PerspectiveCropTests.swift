// Port of photocraft-engine (crates/engine/src/perspective_crop_cmds.rs tests), MIT OR Apache-2.0, © ArtCraft Team and the PhotoCraft contributors.
//
// Both photocraft tests are ported. Added: masks, alpha channels and type layers go through the
// crop, and the id matches photocraft's metadata.

import Foundation
import PCAlgo
import PCDocument
@testable import PCEngine
import PCFoundation
import Testing

@Suite struct PerspectiveCropTests {
    let cmd = "image.perspectiveCrop"

    func corners(_ q: [(Double, Double)]) -> JSONValue { .array(q.map { [.number($0.0), .number($0.1)] }) }

    /// A document whose Background shows a W x H ramp (red = u / W, green = v / H) seen in
    /// perspective through the quad `q`: pixel (x, y) holds the ramp at the rectified point.
    func skewedRamp(_ depth: SampleType, _ q: [(Double, Double)], _ w: Double, _ h: Double) throws -> Session {
        let toDoc = try #require(Homography.rectToQuad([0, 0, w, h], q.map { SIMD2($0.0, $0.1) }))
        let toOut = try #require(toDoc.inverse())
        var doc = Document.withBackground(name: "ramp", size: PixelSize(width: 160, height: 120), mode: .rgb, depth: depth, fill: .white)
        let fmt = doc.pixelFormat
        var px: [Float] = []
        for y in 0..<120 {
            for x in 0..<160 {
                let (u, v) = toOut.apply(Double(x) + 0.5, Double(y) + 0.5)
                px += fmt.components(fromRGBA: SIMD4(Float(min(max(u / w, 0), 1)), Float(min(max(v / h, 0), 1)), 0.5, 1))
            }
        }
        let id = try #require(doc.layers.first?.id)
        doc.withRaster(of: id) { $0.writeRegion(PixelRect(x: 0, y: 0, width: 160, height: 120), px) }
        let s = Session()
        s.addDocument(doc)
        return s
    }

    /// The ramp comes out straight: every output pixel holds the ramp value of its own position
    /// (within 1 px), at 8 and 16 bits, and one undo restores the document.
    @Test func perspectiveCropRectifiesASkewedRamp() throws {
        let q = [(30.0, 12.0), (140.0, 25.0), (128.0, 110.0), (14.0, 95.0)]
        let (w, h) = (100.0, 80.0)
        for depth in [SampleType.u8, .u16] {
            let s = try skewedRamp(depth, q, w, h)
            let r = try s.execute(cmd, ["corners": corners(q), "width": .number(w), "height": .number(h)])
            #expect(r["width"]?.intValue == 100 && r["height"]?.intValue == 80)
            let doc = try #require(s.active?.doc)
            #expect(doc.size == PixelSize(width: 100, height: 80))
            let surf = try #require(doc.layers.first?.surface)
            let out = surf.readRGBA(PixelRect(x: 0, y: 0, width: 100, height: 80))
            for y in stride(from: 2, to: 78, by: 5) {
                for x in stride(from: 2, to: 98, by: 5) {
                    let p = out[y * 100 + x]
                    let (u, v) = (Double(p.x) * w, Double(p.y) * h)
                    #expect(abs(u - (Double(x) + 0.5)) < 1 && abs(v - (Double(y) + 0.5)) < 1, "\(depth) (\(x), \(y)) shows (\(u), \(v))")
                }
            }
            try s.execute("edit.undo")
            #expect(s.active?.doc.size == PixelSize(width: 160, height: 120), "one undo step")
        }
    }

    /// Bad quads and params are refused with an error, and the document is untouched.
    @Test func perspectiveCropRejectsBadQuads() throws {
        let s = try skewedRamp(.u8, [(0, 0), (160, 0), (160, 120), (0, 120)], 160, 120)
        let sq: JSONValue = [[0, 0], [50, 0], [50, 50], [0, 50]]
        for p: JSONValue in [
            [:],
            ["corners": [[0, 0], [10, 0], [10, 10]]],
            ["corners": [[0, 0], [50, 0], [100, 0], [0, 50]]],
            ["corners": [[0, 0], [50, 50], [50, 0], [0, 50]]],
            ["corners": [[0, 0], [0, 50], [50, 50], [50, 0]]],
            ["corners": [[0, 0], [0.5, 0], [0.5, 0.5], [0, 0.5]]],
            ["corners": [[0, 0], [1e300, 0], [50, 50], [0, 50]]],
            ["corners": [[0, 0], ["a", 0], [50, 50], [0, 50]]],
            ["corners": sq, "width": 0],
            ["corners": sq, "width": 1e9, "height": 10],
            ["corners": sq, "resolution": -3],
            ["corners": sq, "interpolation": 3],
        ] {
            #expect(throws: (any Error).self, "\(p.serialized())") { try s.execute(cmd, p) }
        }
        #expect(s.active?.doc.size == PixelSize(width: 160, height: 120))
    }

    // MARK: Added

    /// Masks and alpha channels are mapped too (what the map uncovers takes their default), the
    /// selection is dropped, the resolution is set, and type is rasterized first.
    @Test func masksChannelsAndTypeGoThroughTheCrop() throws {
        let s = Session()
        try s.execute("file.new", ["width": 100, "height": 80])
        try s.execute("type.create", ["x": 10, "y": 40, "text": "Hi", "size": 20])
        try s.execute("layer.new.layer")
        try s.edit("paint") { doc, a in
            guard let id = a else { throw EngineError.other("no layer") }
            doc.withRaster(of: id) { $0.fill(PixelRect(x0: 20, y0: 20, x1: 60, y1: 50), with: [0, 0, 1, 1]) }
        }
        try s.execute("layer.layerMask.revealAll")
        try s.execute("channel.new")
        try s.edit("paint channel") { doc, _ in doc.channels[0].surface.fill(PixelRect(x0: 20, y0: 20, x1: 40, y1: 40), with: [1]) }
        try s.execute("select.rect", ["x": 0, "y": 0, "width": 10, "height": 10])
        // An exact crop of (20, 20)–(60, 60): a translation by (-20, -20).
        let r = try s.execute(cmd, ["corners": [[20, 20], [60, 20], [60, 60], [20, 60]], "resolution": 300, "interpolation": "nearest"])
        #expect(r["width"]?.intValue == 40 && r["height"]?.intValue == 40 && r["resolution"]?.doubleValue == 300)
        let doc = try #require(s.active?.doc)
        #expect(doc.selection == nil)
        #expect(doc.walk().allSatisfy { e in if case .text = e.layer.content { false } else { true } }, "type is rasterized")
        let activeId = try #require(s.active?.activeLayer)
        let l = try #require(doc.layer(activeId))
        #expect(l.surface?.contentBounds == PixelRect(x0: 0, y0: 0, x1: 40, y1: 30))
        #expect(l.mask?.surface.sampleChannel(x: 39, y: 39, 0) == 1, "the mask still reveals")
        let ch = doc.channels[0].surface
        #expect(ch.sampleChannel(x: 5, y: 5, 0) == 1 && ch.sampleChannel(x: 25, y: 25, 0) == 0)
        // The Background stays opaque over the background colour.
        #expect(doc.layers.first?.surface?.pixel(x: 39, y: 39)[3] == 1)
    }

    @Test func idMatchesPhotocraft() throws {
        let s = Session()
        let spec = try #require(s.registry.spec(cmd))
        let pc = try #require(PhotocraftCatalog.byId[cmd])
        #expect(spec.isAvailable)
        #expect(spec.module == pc.module && spec.label == pc.label && spec.menu == pc.menu && spec.shortcut == pc.shortcut && spec.params == pc.params)
        #expect(PhotocraftCatalog.commands.filter { $0.module == "perspective_crop_cmds" }.map(\.id) == [cmd])
    }
}
