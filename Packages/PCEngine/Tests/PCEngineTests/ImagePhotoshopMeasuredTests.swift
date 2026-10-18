// PhotoCraftNative's own tests (AB-T-0308): Canvas Size and Image Size against Photoshop 27.11's behaviour, measured
// through its scripting interface (the measurements are in the AB-T-0308 record and PORT-NOTES).

import PCDocument
@testable import PCEngine
import PCFoundation
import Testing

@Suite struct ImagePhotoshopMeasuredTests {
    /// A transparent `side` x `side` document with a layer holding a black square at (10, 10)–(20, 20).
    func squareSession(_ side: Int) throws -> (Session, LayerId) {
        let s = Session()
        try s.execute("file.new", ["width": .int(side), "height": .int(side), "background": "transparent"])
        let id = try #require(s.active?.activeLayer)
        try s.edit("paint") { doc, _ in
            doc.withRaster(of: id) { $0.fill(PixelRect(x0: 10, y0: 10, x1: 20, y1: 20), with: [0, 0, 0, 1]) }
        }
        return (s, id)
    }

    /// Photoshop truncates a centred Canvas Size's offset toward zero on both axes.
    @Test func aCentredOddChangeTruncatesTheOffsetTowardZero() throws {
        // (old side, new side, Photoshop's offset), measured.
        let cases = [(64, 69, 2), (64, 65, 0), (64, 66, 1), (64, 59, -2), (64, 63, 0), (64, 61, -1),
                     (65, 70, 2), (65, 64, 0), (65, 66, 0), (63, 64, 0), (64, 165, 50)]
        for (old, new, offset) in cases {
            let (s, id) = try squareSession(old)
            let r = try s.execute("image.canvasSize", ["width": .int(new), "height": .int(new)])
            #expect(r["offset"] == [.int(offset), .int(offset)], "\(old) → \(new)")
            let bounds = try #require(s.active?.doc.layer(id)?.surface?.contentBounds)
            #expect(bounds == PixelRect(x0: Int32(10 + offset), y0: Int32(10 + offset), x1: Int32(20 + offset), y1: Int32(20 + offset)), "\(old) → \(new)")
        }
        // The edge anchors move by the whole difference, as before.
        let (s, _) = try squareSession(64)
        #expect(try s.execute("image.canvasSize", ["width": 69, "height": 59, "anchor": "bottomRight"])["offset"] == [5, -5])
    }

    /// Only a Background takes the extension colour; a layer's new canvas is transparent (with or without a
    /// Background below it). A Background can't take a transparent extension: Photoshop's scripted Canvas Size
    /// opens its dialog instead.
    @Test func theExtensionColorIsTheBackgroundsAndATransparentOneIsRefusedThere() throws {
        let s = Session()
        try s.execute("file.new", ["width": 64, "height": 64, "background": "white"])
        try s.execute("layer.new.layer")
        let layer = try #require(s.active?.activeLayer)
        try s.edit("paint") { doc, _ in doc.withRaster(of: layer) { $0.fill(PixelRect(x0: 0, y0: 0, x1: 64, y1: 64), with: [1, 0, 0, 1]) } }
        try s.execute("image.canvasSize", ["width": 80, "height": 80, "extensionColor": "#00ff00"])
        let doc = try #require(s.active?.doc)
        #expect(doc.layer(layer)?.surface?.contentBounds == PixelRect(x0: 8, y0: 8, x1: 72, y1: 72), "the layer's new canvas is transparent")
        let bg = try #require(doc.background?.surface)
        #expect(bg.pixel(x: 1, y: 1) == [0, 1, 0, 1])
        #expect(bg.pixel(x: 40, y: 40) == [1, 1, 1, 1])

        let steps = try #require(s.active?.history.entries.count)
        for size in [96, 48] {
            do {
                try s.execute("image.canvasSize", ["width": .int(size), "height": .int(size), "extensionColor": "transparent"])
                Issue.record("a transparent extension on a Background (\(size)) must be refused")
            } catch let e as EngineError {
                guard case .badParams = e else { Issue.record("\(e)"); continue }
                #expect(e.description.contains("Background"))
            }
        }
        #expect(s.active?.history.entries.count == steps)
        #expect(s.active?.doc.background != nil, "the Background stays a Background")

        // Without a Background a colour is accepted and the new canvas is transparent.
        let (t, id) = try squareSession(64)
        try t.execute("image.canvasSize", ["width": 80, "height": 80, "extensionColor": "#00ff00"])
        #expect(t.active?.doc.layer(id)?.surface?.contentBounds == PixelRect(x0: 18, y0: 18, x1: 28, y1: 28))
        try t.execute("image.canvasSize", ["width": 90, "height": 90, "extensionColor": "transparent"])
    }

    /// Photoshop's Canvas Size and Image Size both drop the selection, inside their own step.
    @Test func canvasSizeAndImageSizeDeselect() throws {
        for (cmd, params) in [("image.canvasSize", ["width": 70, "height": 70] as JSONValue), ("image.imageSize", ["width": 96, "height": 96, "resample": "nearest"])] {
            let (s, _) = try squareSession(64)
            try s.execute("select.rect", ["x": 8, "y": 8, "width": 32, "height": 16])
            let steps = try #require(s.active?.history.entries.count)
            try s.execute(cmd, params)
            #expect(s.active?.doc.selection == nil, "\(cmd)")
            #expect(s.active?.history.entries.count == steps + 1, "\(cmd)")
            try s.execute("edit.undo")
            #expect(s.active?.doc.selection != nil, "\(cmd): undo brings the selection back")
        }
    }

    /// Hard vertical stripes in a layer mask and an alpha channel.
    func stripedSession() throws -> (Session, LayerId) {
        let s = Session()
        try s.execute("file.new", ["width": 64, "height": 8, "background": "white"])
        try s.execute("layer.new.layer")
        let id = try #require(s.active?.activeLayer)
        var stripes = Surface(format: .gray8, defaultPixel: [0])
        for (a, b) in [(3, 4), (7, 9), (12, 15), (18, 22), (27, 28), (30, 33), (37, 39), (41, 42), (45, 50), (55, 56), (58, 61)] {
            stripes.fill(PixelRect(x0: Int32(a), y0: 0, x1: Int32(b), y1: 8), with: [1])
        }
        try s.edit("paint") { doc, _ in
            doc.updateLayer(id) { l in
                l.withRaster { $0.fill(PixelRect(x0: 0, y0: 0, x1: 64, y1: 8), with: [1, 0, 0, 1]) }
                l.mask = LayerMask(surface: stripes)
            }
            doc.channels.append(AlphaChannel(name: "Stripes", surface: stripes))
        }
        return (s, id)
    }

    func values(_ surf: Surface, _ width: Int) -> [Float] {
        (0..<width).map { surf.pixel(x: Int32($0), y: 4)[0] }
    }

    /// Layer masks and alpha channels resample with Image Size's method (Photoshop's, measured per method):
    /// Nearest Neighbor keeps them hard, Bilinear blends; Preserve Details and Automatic resample them as
    /// Bicubic Automatic does (Smoother enlarging, Sharper reducing).
    @Test func masksAndChannelsResampleWithTheChosenMethod() throws {
        func run(_ resample: String, _ width: Int) throws -> (mask: [Float], channel: [Float]) {
            let (s, id) = try stripedSession()
            try s.execute("image.imageSize", ["width": .int(width), "height": 8, "resample": .string(resample)])
            let doc = try #require(s.active?.doc)
            let mask = try #require(doc.layer(id)?.mask?.surface)
            let channel = try #require(doc.channels.last?.surface)
            return (values(mask, width), values(channel, width))
        }
        for width in [96, 40] {
            let nearest = try run("nearest", width)
            #expect(nearest.mask.allSatisfy { $0 == 0 || $0 == 1 }, "Nearest Neighbor keeps a mask hard (\(width))")
            #expect(nearest.channel == nearest.mask)
            let bilinear = try run("bilinear", width)
            #expect(bilinear.mask.contains { $0 > 0.01 && $0 < 0.99 }, "Bilinear blends a mask's edges (\(width))")
            #expect(bilinear.mask != nearest.mask)
            let automatic = try run("bicubicAutomatic", width)
            #expect(try run("preserveDetails", width) == automatic, "Preserve Details' masks are Bicubic Automatic's (\(width))")
            #expect(try run("automatic", width) == automatic, "Automatic's masks are Bicubic Automatic's (\(width))")
            #expect(try run(width > 64 ? "bicubicSmoother" : "bicubicSharper", width) == automatic)
        }
    }

    /// Past 300,000 px Photoshop clamps both commands' sides (DOM and Action Manager alike, measured), as the engine does.
    @Test func anOversizedSideIsClampedTo300000() throws {
        let s = Session()
        try s.execute("file.new", ["width": 10, "height": 1, "background": "white"])
        #expect(try s.execute("image.canvasSize", ["width": 400_000, "height": 1, "anchor": "topLeft"])["width"] == 300_000)
        let t = Session()
        try t.execute("file.new", ["width": 10, "height": 1, "background": "white"])
        #expect(try t.execute("image.imageSize", ["width": 400_000, "height": 1, "resample": "nearest"])["width"] == 300_000)
    }
}
