// Port of photocraft-engine (crates/engine/src/image_cmds.rs `mod tests`), MIT OR Apache-2.0, © ArtCraft Team and the PhotoCraft contributors.
//
// Every photocraft test is ported (the resampling ones run PCAlgo's resampler).

import Foundation
import PCDocument
@testable import PCEngine
import PCFoundation
import Testing

@Suite struct ImageCommandsTests {
    /// 40 × 20, a layer with a red square (10, 5)–(20, 15), a reveal-all mask and a drop shadow.
    func session() throws -> Session {
        let s = Session()
        try s.execute("file.new", ["width": 40, "height": 20])
        try s.execute("layer.new.layer")
        try s.edit("paint") { doc, active in
            guard let id = active else { return }
            doc.updateLayer(id) { l in
                l.withRaster { $0.fill(PixelRect(x0: 10, y0: 5, x1: 20, y1: 15), with: [1, 0, 0, 1]) }
                l.mask = .revealAll()
                l.effects.items.append(.defaultDropShadow())
            }
        }
        return s
    }

    func doc(_ s: Session) -> Document { s.active!.doc }

    /// A document with a white Background and a layer holding a red pixel at (12, 8) and a blue
    /// one at (30, 3).
    func marked(_ mode: String, _ depth: Int) throws -> Session {
        let s = Session()
        try s.execute("file.new", ["width": 40, "height": 20, "mode": .string(mode), "depth": .int(depth), "background": "white"])
        try s.execute("layer.new.layer")
        try s.edit("paint") { doc, active in
            guard let id = active else { return }
            doc.withRaster(of: id) { surf in
                surf.writeRGBA(PixelRect(x0: 12, y0: 8, x1: 13, y1: 9), [SIMD4(1, 0, 0, 1)])
                surf.writeRGBA(PixelRect(x0: 30, y0: 3, x1: 31, y1: 4), [SIMD4(0, 0, 1, 1)])
            }
        }
        return s
    }

    func layerRGBA(_ s: Session, _ layer: Int, _ x: Int32, _ y: Int32) -> SIMD4<Float> {
        doc(s).layers[layer].surface!.rgba(x: x, y: y)
    }

    /// The largest per-channel difference of two colours.
    func maxDiff(_ a: SIMD4<Float>, _ b: SIMD4<Float>) -> Float {
        let d = a - b
        return max(max(abs(d.x), abs(d.y)), max(abs(d.z), abs(d.w)))
    }

    @Test func cropRejectsRectanglesThatWouldWrap() throws {
        let s = try session()
        do {
            try s.execute("image.crop", ["x": .number(4_294_967_396), "y": 0, "width": 10, "height": 10])
            Issue.record("expected an error")
        } catch {
            #expect("\(error)".contains("32-bit"))
        }
        try s.execute("image.crop", ["x": -10, "y": -10, "width": 1000, "height": 1000])
    }

    /// #959: crops whose translation to the origin can't be represented in Int32 are rejected
    /// before anything changes.
    @Test func cropRejectsOriginsThatCannotMoveToZero() throws {
        let mn = Double(Int32.min), mx = Double(Int32.max)
        let cases: [JSONValue] = [
            ["x": .number(mn), "y": 0, "width": 1, "height": 1],
            ["x": 0, "y": .number(mn), "width": 1, "height": 1],
            ["x": .number(mn), "y": .number(mn), "width": 1, "height": 1],
            ["x": .number(mn), "y": 0, "width": 1, "height": 1, "deleteCroppedPixels": false],
            ["x": .number(mx - 5), "y": 0, "width": 10, "height": 1],
            ["x": 0, "y": .number(mx - 5), "width": 1, "height": 10],
            ["x": .number(mn + 1), "y": 0, "width": 1, "height": 1, "deleteCroppedPixels": false],
            ["x": 0, "y": .number(mn + 1), "width": 1, "height": 1, "deleteCroppedPixels": false],
        ]
        for p in cases {
            let s = try session()
            let before = doc(s)
            let (rev, steps) = (s.active!.revision, s.active!.history.entries.count)
            do {
                try s.execute("image.crop", p)
                Issue.record("\(p): expected an error")
            } catch let e as EngineError {
                guard case .badParams = e else { Issue.record("\(p): \(e)"); continue }
                #expect(e.description.contains("32-bit"), "\(p): \(e)")
            }
            let st = s.active!
            #expect(st.doc == before, "\(p): document changed")
            #expect(st.doc.size == PixelSize(width: 40, height: 20))
            #expect(st.doc.layers[1].surface!.contentBounds == PixelRect(x0: 10, y0: 5, x1: 20, y1: 15))
            #expect(st.revision == rev && st.history.entries.count == steps, "\(p): history step recorded")
        }
        // A legal negative origin past the canvas still crops (and extends) the canvas.
        let s = try session()
        try s.execute("image.crop", ["x": -10, "y": -5, "width": 60, "height": 30])
        #expect(doc(s).size == PixelSize(width: 60, height: 30))
        #expect(doc(s).layers[1].surface!.pixel(x: 20, y: 10) == [1, 0, 0, 1])
        // A far-off crop that deletes the (non-overlapping) pixels has nothing left to move.
        let t = try session()
        try t.execute("image.crop", ["x": .number(mn + 1), "y": 0, "width": 1, "height": 1])
        #expect(doc(t).size == PixelSize(width: 1, height: 1))
    }

    @Test func imageSizeScalesEverything() throws {
        for resample in ["bicubic", "bicubicSmoother", "bicubicSharper", "bicubicAutomatic", "automatic", "bilinear", "nearest", "lanczos", "preserveDetails"] {
            let s = try session()
            try s.execute("image.imageSize", ["width": 80, "resample": .string(resample)])
            let d = doc(s)
            #expect(d.size == PixelSize(width: 80, height: 40), "\(resample)")
            let l = d.layers[1]
            let b = l.surface!.contentBounds
            #expect(abs(b.x0 - 20) <= 1 && abs(b.x1 - 40) <= 1, "\(resample) \(b)")
            guard case .dropShadow(let sh) = l.effects.items[0] else { Issue.record("\(resample): no drop shadow"); continue }
            #expect(sh.distance == 10)
            #expect(l.mask?.surface.defaultPixelValue == [1])
        }
    }

    /// #1544: 64 x 48 to 300000 x 300000 is refused before any allocation and the document is
    /// untouched; a change of resolution only, and an ordinary resize, still work.
    @Test func imageSizeRefusesARasterPastTheBudget() throws {
        let s = Session()
        try s.execute("file.new", ["width": 64, "height": 48])
        let (size, past) = (doc(s).size, s.active!.history.pastCount)
        do {
            try s.execute("image.imageSize", ["width": 300_000, "height": 300_000])
            Issue.record("expected an error")
        } catch {
            #expect("\(error)".contains("megapixels"), "\(error)")
        }
        #expect(doc(s).size == size && s.active!.history.pastCount == past)
        try s.execute("image.imageSize", ["width": 300_000, "height": 300_000, "resample": "none", "resolution": 300])
        try s.execute("image.imageSize", ["width": 128, "height": 96])
        #expect(doc(s).size == PixelSize(width: 128, height: 96))
    }

    /// The canvas border stays opaque after Image Size, and a full alpha channel stays full (the selection
    /// itself goes, as Photoshop's Image Size drops it: AB-T-0308).
    @Test func imageSizeKeepsCanvasEdgesOpaque() throws {
        for depth in [8, 16, 32] {
            for (w, resample) in [(60, "bicubic"), (41, "lanczos"), (15, "bilinear"), (77, "preserveDetails"), (21, "bicubicSharper"),
                                  (47, "automatic"), (9, "bicubicAutomatic")] {
                let s = Session()
                try s.execute("file.new", ["width": 30, "height": 20, "depth": .int(depth), "background": "#336699"])
                try s.execute("select.all")
                try s.execute("select.saveSelection")
                try s.execute("image.imageSize", ["width": .int(w), "resample": .string(resample)])
                let d = doc(s)
                let px = try s.services.renderer.render(d, region: d.bounds).px
                let (fw, fh) = (d.size.width, d.size.height)
                let mid = px[(fh / 2) * fw + fw / 2]
                #expect(abs(mid.w - 1) < 1e-3, "\(depth) \(resample): \(mid)")
                let worst = px.map { maxDiff($0, mid) }.max() ?? 0
                #expect(worst < 0.01, "\(depth) \(resample) \(w): \(worst)")
                #expect(d.selection == nil, "\(depth) \(resample): Image Size deselects")
                let channel = try #require(d.channels.last?.surface)
                let (x1, y1) = (Int32(fw - 1), Int32(fh - 1))
                for (x, y) in [(Int32(0), Int32(0)), (x1, 0), (0, y1), (x1, y1)] {
                    #expect(channel.pixel(x: x, y: y)[0] > 0.99, "\(depth) \(resample): alpha channel at (\(x),\(y))")
                }
            }
        }
    }

    @Test func resolutionOnlyChange() throws {
        let s = try session()
        let r = try s.execute("image.imageSize", ["resolution": 300, "resample": "none", "width": 999])
        #expect(doc(s).size == PixelSize(width: 40, height: 20))
        #expect(doc(s).resolutionDpi == 300)
        // #1815: the result is the size the document has, not the ignored request.
        #expect(r == ["width": 40, "height": 20])
    }

    @Test func imageSizeReportsTheSizeItApplied() throws {
        // #1815: every path reports the document's size afterwards, at every depth.
        for depth in [8, 16, 32] {
            let s = Session()
            try s.execute("file.new", ["width": 64, "height": 48, "depth": .int(depth)])
            let params: [JSONValue] = [
                ["width": 999, "height": 777, "resample": "none", "resolution": 150],
                ["width": 32],
                ["height": 96, "resample": "nearest"],
                ["width": 96, "height": 72, "resample": "none"],
                [:],
            ]
            for p in params {
                let r = try s.execute("image.imageSize", p)
                #expect(r == ["width": .int(doc(s).size.width), "height": .int(doc(s).size.height)], "\(depth)-bit \(p)")
            }
            // 64×48 → (none) → 32×24 → 128×96 (aspect kept) → (none) → unchanged.
            #expect(doc(s).size == PixelSize(width: 128, height: 96), "\(depth)-bit")
        }
    }

    /// #1114: nearest neighbor reduction keeps source values without averaging.
    @Test func nearestNeighborReductionKeepsSourceValues() throws {
        let s = Session()
        try s.execute("file.new", ["width": 8, "height": 8])
        try s.execute("tools.setColors", ["foreground": "#000000", "background": "#ffffff"])
        for y in 0..<8 {
            for x in 0..<8 where (x + y) % 2 == 0 {
                try s.execute("select.rect", ["x": .int(x), "y": .int(y), "width": 1, "height": 1])
                try s.execute("edit.fill", ["contents": "foreground"])
            }
        }
        try s.execute("select.deselect")
        let before = doc(s).layers[0].surface!.rgba(x: 0, y: 0)
        #expect(before.x < 0.01, "setup: (0,0) should be black, got \(before)")
        try s.execute("image.imageSize", ["width": 4, "height": 4, "resample": "nearest"])
        let surf = doc(s).layers[0].surface!
        for (x, y) in [(Int32(0), Int32(0)), (1, 1), (2, 3)] {
            let v = surf.rgba(x: x, y: y).x
            #expect(v.isFinite && !(0.01...0.99).contains(v), "nearest produced an averaged value \(v) at (\(x),\(y))")
        }
    }

    @Test func canvasSizeAnchorsAndExtendsBackground() throws {
        let s = try session()
        try s.execute("image.canvasSize", ["width": 60, "height": 30, "anchor": "topLeft", "extensionColor": "#00ff00"])
        let d = doc(s)
        #expect(d.size == PixelSize(width: 60, height: 30))
        #expect(d.layers[1].surface!.contentBounds == PixelRect(x0: 10, y0: 5, x1: 20, y1: 15))
        let bg = d.layers[0].surface!
        #expect(bg.pixel(x: 50, y: 25) == [0, 1, 0, 1])
        #expect(bg.pixel(x: 5, y: 5) == [1, 1, 1, 1])
        let t = try session()
        try t.execute("image.canvasSize", ["width": 20, "height": 10, "relative": true, "anchor": "center"])
        #expect(doc(t).layers[1].surface!.contentBounds == PixelRect(x0: 20, y0: 10, x1: 30, y1: 20))
    }

    @Test func canvasSizeAnchorOffsetsAndRejectsUnlisted() throws {
        let expected: [(String, [Int])] = [
            ("topLeft", [0, 0]), ("top", [18, 0]), ("topRight", [36, 0]), ("left", [0, 16]), ("center", [18, 16]), ("right", [36, 16]),
            ("bottomLeft", [0, 32]), ("bottom", [18, 32]), ("bottomRight", [36, 32]),
        ]
        func fresh() throws -> Session {
            let s = Session()
            try s.execute("file.new", ["width": 64, "height": 48, "background": "white"])
            return s
        }
        for (anchor, off) in expected {
            let r = try fresh().execute("image.canvasSize", ["width": 100, "height": 80, "anchor": .string(anchor)])
            #expect(r["offset"] == .array(off.map { .int($0) }), "anchor \(anchor)")
        }
        #expect(try fresh().execute("image.canvasSize", ["width": 100, "height": 80])["offset"] == [18, 16])
        for anchor in ["topleft", "TopLeft", "TOPLEFT", "bottomleft", "bottomright", "middle", "", "NOPE"] {
            do {
                try fresh().execute("image.canvasSize", ["width": 100, "height": 80, "anchor": .string(anchor)])
                Issue.record("anchor \(anchor) must be rejected")
            } catch let e as EngineError {
                guard case .badParams = e else { Issue.record("\(anchor): \(e)"); continue }
                #expect(e.description.contains("anchor"))
            }
        }
    }

    @Test func cropToSelectionAndTrim() throws {
        let s = try session()
        #expect(throws: EngineError.self) { try s.execute("image.crop") }
        try s.execute("select.rect", ["x": 5, "y": 2, "width": 20, "height": 10])
        try s.execute("image.crop")
        let d = doc(s)
        #expect(d.size == PixelSize(width: 20, height: 10))
        #expect(d.selection == nil)
        #expect(d.layers[1].surface!.contentBounds == PixelRect(x0: 5, y0: 3, x1: 15, y1: 10))
        // Trim transparent: hide the background, trim to the red square.
        let t = try session()
        try t.execute("layer.setProps", ["layer": .id(doc(t).layers[0].id), "visible": false])
        try t.execute("image.trim", ["basedOn": "transparent"])
        // The red square (10×10) plus its drop shadow (distance 5, size 5).
        let size = doc(t).size
        #expect(size.width > 10 && size.width < 30 && size.height > 10 && size.height < 25, "\(size)")
    }

    @Test func cropToExplicitRectCanExtendCanvas() throws {
        let s = try session()
        try s.execute("image.crop", ["x": 10, "y": 5, "width": 10, "height": 10])
        #expect(doc(s).size == PixelSize(width: 10, height: 10))
        #expect(doc(s).layers[1].surface!.pixel(x: 0, y: 0) == [1, 0, 0, 1])
        let t = try session()
        try t.execute("image.crop", ["x": -10, "y": 0, "width": 60, "height": 20])
        #expect(doc(t).size == PixelSize(width: 60, height: 20))
        #expect(doc(t).layers[1].surface!.pixel(x: 20, y: 5) == [1, 0, 0, 1])
    }

    @Test func cropExtensionFillsTheBackgroundWithTheBackgroundColour() throws {
        let shrink = Session()
        try shrink.execute("file.new", ["width": 16, "height": 16, "background": "#ff0000"])
        try shrink.execute("image.crop", ["x": 2, "y": 0, "width": 12, "height": 16])
        var layer = doc(shrink).layers[0]
        #expect(layer.name == "Background", "a shrink-only crop keeps the Background")
        #expect(layer.locks.transparency && layer.locks.position)

        let s = Session()
        try s.execute("file.new", ["width": 16, "height": 16, "background": "#ff0000"])
        s.tools.background = SIMD4(0, 1, 0, 1)
        try s.execute("image.crop", ["x": -4, "y": 0, "width": 20, "height": 16])
        layer = doc(s).layers[0]
        #expect(layer.name == "Background", "an extending crop keeps the Background (#3081)")
        #expect(layer.locks.transparency && layer.locks.position)
        #expect(layer.surface!.rgba(x: 1, y: 8) == SIMD4(0, 1, 0, 1), "the added border takes the background colour")
        #expect(layer.surface!.rgba(x: 8, y: 8) == SIMD4(1, 0, 0, 1), "the original pixels stay")
        // The extended border is real pixels (photocraft fills it with Edit › Fill here).
        try s.edit("fill") { doc, _ in
            let b = doc.bounds
            doc.updateBackground { $0.withRaster { $0.fill(b, with: [0, 0, 1, 1]) } }
        }
        #expect(doc(s).layers[0].surface!.rgba(x: 1, y: 8) == SIMD4(0, 0, 1, 1))
        #expect(s.undo() && s.undo())
        layer = doc(s).layers[0]
        #expect(doc(s).size == PixelSize(width: 16, height: 16))
        #expect(layer.surface!.rgba(x: 8, y: 8) == SIMD4(1, 0, 0, 1))
        #expect(layer.surface!.contentBounds == PixelRect(x0: 0, y0: 0, x1: 16, y1: 16), "undo removes the filled border")

        // A normal layer gets transparent pixels in the added area.
        let t = Session()
        try t.execute("file.new", ["width": 16, "height": 16, "background": "#ff0000"])
        try t.edit("Layer from Background") { doc, _ in doc.updateBackground { LayerOps.unlockBackground(&$0) } }
        try t.execute("image.crop", ["x": -4, "y": 0, "width": 20, "height": 16])
        #expect(doc(t).layers[0].surface!.rgba(x: 1, y: 8) == .zero)
    }

    /// #1792: a frame turned 90° clockwise crops what Image Rotation › Arbitrary 90° CCW and a
    /// plain crop give, in one undo step that restores the document, at 8, 16 and 32 bits.
    @Test func cropAt90DegreesIsRotateThenCropInOneStep() throws {
        for depth in [8, 16, 32] {
            let s = try marked("rgb", depth)
            let before = doc(s)
            let past = s.active!.history.pastCount
            // The 10 × 20 frame at (10, 0), turned 90° about (15, 10), covers x 5..25, y 5..15.
            let r = try s.execute("image.crop", ["x": 10, "y": 0, "width": 10, "height": 20, "angle": 90])
            #expect(r["angle"] == 90.0, "\(depth)")
            #expect(doc(s).size == PixelSize(width: 10, height: 20), "\(depth)")
            #expect(s.active!.history.pastCount == past + 1, "\(depth): one undo step")
            // (12, 8) is 2.5 left of and 1.5 above the centre: in the upright frame, 1.5 left of
            // and 2.5 below its centre (5, 10).
            let red = layerRGBA(s, 1, 3, 12)
            #expect(red.x > 0.9 && red.y < 0.1 && red.w > 0.9, "\(depth): \(red)")
            let reference = try marked("rgb", depth)
            try reference.execute("image.rotation.arbitrary", ["angle": 90, "direction": "ccw"])
            try reference.execute("image.crop", ["x": 5, "y": 15, "width": 10, "height": 20])
            var worst: Float = 0
            for l in 0..<2 {
                for y in Int32(0)..<20 { for x in Int32(0)..<10 { worst = max(worst, maxDiff(layerRGBA(s, l, x, y), layerRGBA(reference, l, x, y))) } }
            }
            #expect(worst < 1e-3, "\(depth): \(worst)")
            try s.execute("edit.undo")
            let d = doc(s)
            #expect(d.size == before.size && d.depth == before.depth, "\(depth)")
            var same = true
            for y in Int32(0)..<20 { for x in Int32(0)..<40 where layerRGBA(s, 1, x, y) != before.layers[1].surface!.rgba(x: x, y: y) { same = false } }
            #expect(same, "\(depth): undo restores the pixels")
        }
    }

    /// A slightly turned frame keeps its own size, the pixel under its centre and the Background's
    /// colour; the turn's sign matters (a counter-clockwise frame is a negative angle).
    @Test func cropAtASmallAngleKeepsTheFrameSizeInEveryMode() throws {
        for (mode, depth) in [("rgb", 8), ("rgb", 16), ("rgb", 32), ("grayscale", 16), ("cmyk", 8), ("lab", 16)] {
            for angle in [5.0, -7.5, 365.0] {
                let s = try marked(mode, depth)
                try s.execute("image.crop", ["x": 2, "y": 1, "width": 21, "height": 15, "angle": .number(angle)])
                let d = doc(s)
                #expect(d.size == PixelSize(width: 21, height: 15), "\(mode) \(depth) \(angle)")
                #expect(d.depth.bytes * 8 == depth, "\(mode) \(depth)")
                #expect("\(d.mode)" == mode, "\(mode) \(depth)")
                #expect(d.layers.count == 2)
                // The frame's centre (12.5, 8.5) is the red pixel (the layer's only paint nearby);
                // it stays at the centre, its colour kept.
                let want = layerRGBA(try marked(mode, depth), 1, 12, 8)
                let red = layerRGBA(s, 1, 10, 7)
                #expect(red.w > 0.5 && (0..<3).allSatisfy { abs(red[$0] - want[$0]) < 0.2 }, "\(mode) \(depth) \(angle): \(red) vs \(want)")
                // The Background stays opaque white inside the canvas it came from.
                let bg = layerRGBA(s, 0, 10, 7)
                #expect((0..<4).allSatisfy { abs(bg[$0] - 1) < 0.02 }, "\(mode) \(depth) \(angle): \(bg)")
            }
        }
    }

    /// Angle 0 (or a whole turn) is the plain crop: no resampling, the same document.
    @Test func cropAtAngleZeroIsThePlainCrop() throws {
        let plain = try marked("rgb", 16)
        try plain.execute("image.crop", ["x": 3, "y": 2, "width": 30, "height": 10])
        for angle: JSONValue in [0, 0.0, 360, -720, .null] {
            let s = try marked("rgb", 16)
            let r = try s.execute("image.crop", ["x": 3, "y": 2, "width": 30, "height": 10, "angle": angle])
            #expect(r["angle"] == nil, "\(angle): \(r)")
            #expect(doc(s).size == PixelSize(width: 30, height: 10))
            for l in 0..<2 {
                for y in Int32(0)..<10 { for x in Int32(0)..<30 { #expect(layerRGBA(s, l, x, y) == layerRGBA(plain, l, x, y)) } }
            }
        }
    }

    /// Bad angles fail cleanly, before anything changes.
    @Test func cropAngleRejectsBadValuesWithoutChangingTheDocument() throws {
        let bad: [JSONValue] = [
            ["x": 0, "y": 0, "width": 10, "height": 10, "angle": "NaN"],
            ["x": 0, "y": 0, "width": 10, "height": 10, "angle": "12"],
            ["x": 0, "y": 0, "width": 10, "height": 10, "angle": [1]],
            ["x": 0, "y": 0, "width": 10, "height": 10, "angle": true],
            ["x": 0, "y": 0, "width": 10, "height": 10, "angle": 1e308],
            ["x": 0, "y": 0, "width": 10, "height": 10, "angle": -3601],
            ["x": 0, "y": 0, "width": 10, "height": 10, "angle": .number(Double.greatestFiniteMagnitude)],
            ["angle": 10],
            ["x": 0, "y": 0, "width": 0, "height": 10, "angle": 10],
            ["x": 0, "y": 0, "width": 300_001, "height": 10, "angle": 10],
            ["x": .number(Double(Int32.max) - 5), "y": 0, "width": 10, "height": 10, "angle": 10],
        ]
        for p in bad {
            let s = try marked("rgb", 8)
            try s.execute("select.all")
            let before = doc(s)
            let past = s.active!.history.pastCount
            #expect(throws: EngineError.self, "\(p)") { try s.execute("image.crop", p) }
            #expect(doc(s).size == before.size)
            #expect(s.active!.history.pastCount == past)
        }
        // Far-off but representable frames turn and crop without trapping.
        for (x, y) in [(-1_000_000, 0), (0, 1_000_000), (Int(Int32.min / 4), Int(Int32.max / 4))] {
            let s = try marked("rgb", 8)
            try s.execute("image.crop", ["x": .int(x), "y": .int(y), "width": 4, "height": 3, "angle": 33.3])
            #expect(doc(s).size == PixelSize(width: 4, height: 3))
        }
    }

    @Test func cropRefusesACanvasSidePastTheNewDocumentLimit() throws {
        for (w, h) in [(100_000_000, 100_000_000), (300_001, 10), (10, 300_001)] {
            let s = try session()
            let (size, past) = (doc(s).size, s.active!.history.pastCount)
            do {
                try s.execute("image.crop", ["x": 0, "y": 0, "width": .int(w), "height": .int(h)])
                Issue.record("\(w) x \(h): expected an error")
            } catch {
                #expect("\(error)".contains("300000 px limit"), "\(w) x \(h): \(error)")
            }
            #expect(doc(s).size == size && s.active!.history.pastCount == past)
        }
        let s = try session()
        try s.execute("image.crop", ["x": 0, "y": 0, "width": 300_000, "height": 2])
        #expect(doc(s).size == PixelSize(width: 300_000, height: 2))
    }

    /// #2443: the Crop tool's W x H x Resolution crops, resamples the cropped area to exactly the
    /// target size and sets the resolution, in one undo step, at 8 and 16 bits.
    @Test func cropToATargetSizeAndResolutionIsOneStep() throws {
        for depth in [8, 16] {
            let s = Session()
            try s.execute("file.new", ["width": 400, "height": 300, "resolution": 72, "depth": .int(depth)])
            try s.execute("layer.new.layer")
            try s.edit("paint") { doc, active in
                doc.withRaster(of: active!) { $0.fill(PixelRect(x0: 100, y0: 100, x1: 200, y1: 225), with: [1, 0, 0, 1]) }
            }
            let past = s.active!.history.pastCount
            // 4 x 5 in at 300 ppi from a 100 x 125 px frame.
            let r = try s.execute("image.crop", ["x": 100, "y": 100, "width": 100, "height": 125, "targetWidth": 1200, "targetHeight": 1500, "resolution": 300])
            #expect(r["documentWidth"] == 1200 && r["documentHeight"] == 1500, "\(depth): \(r)")
            #expect(r["resolution"] == 300, "\(depth)")
            let d = doc(s)
            #expect(d.size == PixelSize(width: 1200, height: 1500), "\(depth)")
            #expect(d.resolutionDpi == 300, "\(depth)")
            #expect(d.layers[0].surface!.format.sample == (depth == 8 ? .u8 : .u16))
            // The red frame filled the crop; it fills the result.
            let red = d.layers[1].surface!
            for (x, y) in [(Int32(0), Int32(0)), (600, 750), (1199, 1499)] {
                #expect(red.pixel(x: x, y: y) == [1, 0, 0, 1], "\(depth): (\(x), \(y))")
            }
            #expect(s.active!.history.pastCount == past + 1, "\(depth): one history step")
            try s.execute("edit.undo")
            #expect(doc(s).size == PixelSize(width: 400, height: 300) && doc(s).resolutionDpi == 72, "\(depth): undo restores the original")
        }
    }

    @Test func cropTargetResamplesAfterATurnedCrop() throws {
        let s = try session()
        let past = s.active!.history.pastCount
        try s.execute("image.crop", ["x": 10, "y": 0, "width": 10, "height": 20, "angle": 90, "targetWidth": 30, "targetHeight": 60, "resample": "nearest"])
        #expect(doc(s).size == PixelSize(width: 30, height: 60))
        #expect(s.active!.history.pastCount == past + 1, "rotate, crop and resample: one step")
    }

    @Test func cropResolutionAloneKeepsThePixels() throws {
        let s = try session()
        let r = try s.execute("image.crop", ["x": 2, "y": 3, "width": 30, "height": 10, "resolution": 150])
        #expect(doc(s).size == PixelSize(width: 30, height: 10) && doc(s).resolutionDpi == 150)
        #expect(r["documentWidth"] == 30 && r["documentHeight"] == 10 && r["resolution"] == 150)
    }

    @Test func cropTargetRejectsBadParamsWithoutChangingTheDocument() throws {
        let bad: [JSONValue] = [
            ["targetWidth": 100], ["targetHeight": 100], ["targetWidth": 0, "targetHeight": 10], ["targetWidth": -5, "targetHeight": 10],
            ["targetWidth": 10.5, "targetHeight": 10], ["targetWidth": "10", "targetHeight": 10], ["targetWidth": 300_001, "targetHeight": 10],
            ["targetWidth": .number(4_294_967_306), "targetHeight": 10], ["targetWidth": 300_000, "targetHeight": 300_000],
            ["targetWidth": 10, "targetHeight": 10, "resample": "none"], ["targetWidth": 10, "targetHeight": 10, "resample": 3],
            ["resolution": 0], ["resolution": -72], ["resolution": 1e9], ["resolution": "300"],
        ]
        for extra in bad {
            let s = try session()
            let (size, dpi, past) = (doc(s).size, doc(s).resolutionDpi, s.active!.history.pastCount)
            let p = JSONValue.object(["x": 0, "y": 0, "width": 10, "height": 10]).merging(extra)
            #expect(throws: EngineError.self, "\(p)") { try s.execute("image.crop", p) }
            #expect(doc(s).size == size && doc(s).resolutionDpi == dpi && s.active!.history.pastCount == past, "\(p): nothing changed")
        }
    }

    @Test func trimBasedOnTopLeftColour() throws {
        let s = try session()
        try s.edit("no fx") { doc, _ in doc.updateLayer(at: [1]) { $0.effects.items.removeAll() } }
        try s.execute("image.trim", ["basedOn": "topLeft"])
        #expect(doc(s).size == PixelSize(width: 10, height: 10))
    }

    @Test func thirtyTwoBitHoldsLinearLight() throws {
        // Photoshop 27.11: an 8-bit sRGB grey 128 becomes 0.2159 in 32 bits (and 32 → 0.0144), and
        // comes back unchanged; alpha keeps its value.
        let s = Session()
        try s.execute("file.new", ["width": 4, "height": 1, "background": "white"])
        try s.execute("layer.new.layer")
        try s.edit("paint") { doc, active in
            doc.withRaster(of: active!) { $0.fill(PixelRect(x0: 0, y0: 0, x1: 2, y1: 1), with: [128.0 / 255, 32.0 / 255, 1, 0.5]) }
        }
        try s.execute("image.mode.bits32")
        var px = doc(s).layers[1].surface!.pixel(x: 0, y: 0)
        let want1: [Float] = [0.2159, 0.0144, 1, 128.0 / 255]
        for (got, want) in zip(px, want1) { #expect(abs(got - want) < 2e-4, "\(px)") }
        try s.execute("image.mode.bits8")
        px = doc(s).layers[1].surface!.pixel(x: 0, y: 0)
        let want2: [Float] = [128.0 / 255, 32.0 / 255, 1, 128.0 / 255]
        for (got, want) in zip(px, want2) { #expect(abs(got - want) < 0.6 / 255, "\(px)") }
    }

    @Test func modeAndDepthConversions() throws {
        let s = try session()
        try s.execute("image.mode.grayscale")
        #expect(doc(s).mode == .grayscale)
        #expect(doc(s).layers[1].surface!.format.mode == .grayscale)
        try s.execute("image.mode.bits16")
        #expect(doc(s).depth == .u16)
        #expect(doc(s).layers[1].surface!.format.sample == .u16)
        #expect(doc(s).layers[1].mask!.surface.format.sample == .u16)
        try s.execute("image.mode.cmyk")
        try s.execute("image.mode.bits32")
        try s.execute("image.mode.lab")
        try s.execute("image.mode.rgb")
        try s.execute("image.mode.bits8")
        #expect(doc(s).mode == .rgb && doc(s).depth == .u8)
        try s.execute("edit.undo")
        #expect(doc(s).depth == .f32)
        let revision = s.active!.revision
        try s.execute("image.mode.bits32")
        #expect(s.active!.revision == revision, "an unchanged bit depth must preserve the history branch")
        #expect(s.redo(), "selecting the current depth must not discard the undone conversion")
        #expect(doc(s).depth == .u8)
    }

    @Test func duplicateDocument() throws {
        let s = try session()
        let r = try s.execute("image.duplicate", ["mergedOnly": true])
        #expect(r["document"] == 1)
        #expect(s.documents.count == 2)
        #expect(doc(s).layers.count == 1)
        #expect(doc(s).name.hasSuffix("copy"))
        // The merged copy shows what the original showed.
        let original = s.documents[0].doc
        let a = try s.services.renderer.render(original, region: original.bounds).px
        let b = try s.services.renderer.render(doc(s), region: doc(s).bounds).px
        #expect(zip(a, b).allSatisfy { p, q in let d = p - q; return (d * d).max() < 1.1e-5 })
        #expect(doc(s).layers[0].id != original.layers[0].id)
    }
}
