// Port of photocraft-engine (crates/engine/src/selection_cmds.rs `mod tests`), MIT OR Apache-2.0, © ArtCraft Team and the PhotoCraft contributors.

import Foundation
import PCAlgo
import PCDocument
@testable import PCEngine
import PCFoundation
import PCPlatform
import Testing

@Suite struct SelectionCommandsTests {
    static func rect(_ x0: Int32, _ y0: Int32, _ x1: Int32, _ y1: Int32) -> PixelRect { PixelRect(x0: x0, y0: y0, x1: x1, y1: y1) }

    /// Paints `rect` of layer `index` (top-level) with RGBA `c`.
    static func paint(_ s: Session, _ r: PixelRect, _ c: SIMD4<Float>, layer index: Int = 0) throws {
        try s.edit("paint") { doc, _ in
            let id = doc.layers[index].id
            doc.withRaster(of: id) { $0.fill(r, with: $0.format.components(fromRGBA: c)) }
        }
    }

    /// 40×30 white with two red squares at (5..15, 5..15) and (25..35, 5..15).
    func session() throws -> Session {
        let s = Session()
        try s.execute("file.new", ["width": 40, "height": 30])
        try Self.paint(s, Self.rect(5, 5, 15, 15), SIMD4(1, 0, 0, 1))
        try Self.paint(s, Self.rect(25, 5, 35, 15), SIMD4(1, 0, 0, 1))
        return s
    }

    func coverage(_ s: Session, _ x: Int32, _ y: Int32) -> Float {
        s.active?.doc.selection?.sampleChannel(x: x, y: y, 0) ?? 0
    }

    func clearSelection(_ s: Session) throws {
        if s.active?.doc.selection != nil { try s.execute("select.deselect") }
    }

    func mask(_ s: Session) -> [Float] {
        let doc = s.active!.doc
        return SelectionMath.mask(from: doc.selection, doc.bounds)
    }

    @Test func colorRangeReplaceIsBoundedByExistingSelection() throws {
        for params: JSONValue in [["color": "#ff0000", "fuzziness": 0], ["select": "reds"]] {
            let s = try session()
            // Both red squares match, but only the left is inside the original selection.
            try s.execute("select.rect", ["x": 5, "y": 5, "width": 10, "height": 10])
            try s.execute("select.colorRange", params)
            #expect(coverage(s, 10, 10) == 1)
            #expect(coverage(s, 30, 10) == 0)
            #expect(coverage(s, 2, 2) == 0)
            try s.execute("edit.undo")
            #expect(coverage(s, 10, 10) == 1)
            #expect(coverage(s, 30, 10) == 0)
        }
    }

    @Test func colorRangeInvertAndPartialMasksStayWithinPriorSelection() throws {
        var s = try session()
        try s.execute("select.rect", ["x": 5, "y": 5, "width": 10, "height": 10])
        try s.execute("select.colorRange", ["select": "highlights", "invert": true])
        #expect(coverage(s, 10, 10) == 1, "inverted white excludes the white background")
        #expect(coverage(s, 20, 20) == 0, "invert must not select outside the old boundary")

        s = try session()
        try s.edit("soft selection") { doc, _ in
            var m = [Float](repeating: 0, count: 40 * 30)
            m[10 * 40 + 10] = 128.0 / 255.0
            doc.selection = SelectionMath.surface(m, doc.bounds)
        }
        try s.execute("select.colorRange", ["select": "reds"])
        #expect(abs(coverage(s, 10, 10) - 128.0 / 255.0) < 0.001)
        #expect(coverage(s, 30, 10) == 0)
    }

    @Test func colorRangeEyedropperRespectsSelectionButAddCanExtendIt() throws {
        let s = try session()
        try s.execute("select.rect", ["x": 5, "y": 5, "width": 10, "height": 10])
        let before = mask(s)
        let outside: JSONValue = ["points": [[30, 10]], "fuzziness": 0]
        #expect(throws: EngineError.self) { try s.execute("select.colorRange", outside) }
        do {
            try s.execute("select.colorRange", outside)
        } catch {
            #expect("\(error)".contains("outside the active selection"))
        }
        do {
            _ = try SelectionCommands.ColorRangeSamples(s, outside)
            Issue.record("expected an error")
        } catch {
            #expect("\(error)".contains("outside the active selection"))
        }
        #expect(mask(s) == before)
        try s.execute("select.colorRange", ["points": [[10, 10]], "fuzziness": 0])
        #expect(coverage(s, 10, 10) == 1)
        #expect(coverage(s, 30, 10) == 0)
        // Explicitly adding a matching colour is still allowed to grow the selection.
        try s.execute("select.colorRange", ["points": [[30, 10]], "fuzziness": 0, "mode": "add"])
        #expect(coverage(s, 10, 10) == 1)
        #expect(coverage(s, 30, 10) == 1)
        try clearSelection(s)
        try s.execute("select.colorRange", ["color": "#ff0000", "fuzziness": 0])
        #expect(coverage(s, 30, 10) == 1, "an unbounded color range still searches the canvas")
    }

    @Test func magicWandSelectsTheVisibleAlphaOrMaskNotTheRGB() throws {
        var s = try session()
        // Alpha covers the first red square and the pixels beside it. RGB would stop at the red.
        try s.execute("select.rect", ["x": 0, "y": 0, "width": 20, "height": 20])
        try s.execute("channel.new", ["fill": "selection", "name": "Alpha"])
        let wand: JSONValue = ["x": 7, "y": 7, "tolerance": 0, "antiAlias": false]
        try s.execute("select.magicWand", wand)
        #expect(coverage(s, 7, 7) == 1)
        #expect(coverage(s, 2, 2) == 1, "the white alpha includes pixels that are not the red square")
        #expect(coverage(s, 30, 10) == 0, "outside the alpha stays unselected")
        // Colour channels back on: the wand reads RGB again.
        try s.execute("channel.setVisible", ["channel": "composite", "visible": true])
        try s.execute("channel.setVisible", ["channel": 0, "visible": false])
        try s.execute("select.magicWand", wand)
        #expect(coverage(s, 7, 7) == 1)
        #expect(coverage(s, 2, 2) == 0, "RGB sampling stops at the red square")
        // Eyes off again, Alpha still the picture.
        try s.execute("channel.setVisible", ["channel": 0, "visible": true])
        try s.execute("channel.setVisible", ["channel": "composite", "visible": false])
        try s.execute("select.magicWand", wand)
        #expect(coverage(s, 2, 2) == 1)

        s = try session()
        try s.execute("select.rect", ["x": 0, "y": 0, "width": 20, "height": 20])
        try s.execute("layer.layerMask.revealSelection")
        try s.execute("select.deselect")
        // `view.layerMask {"mode":"gray"}` (mask_view_cmds) sets this view state.
        let layer = try #require(s.active?.activeLayer)
        try s.updateActive { $0.channelView.layerMask = LayerMaskView(layer: layer, mode: .gray) }
        try s.execute("select.magicWand", wand)
        #expect(coverage(s, 2, 2) == 1, "gray mask view selects the mask")
        #expect(coverage(s, 30, 10) == 0)
        try s.updateActive { $0.channelView.layerMask = nil }
        for name in ["red", "green", "blue"] {
            try s.execute("channel.setVisible", ["channel": .string(name), "visible": false])
        }
        try s.execute("select.magicWand", wand)
        #expect(coverage(s, 2, 2) == 1, "a layer mask shown alone is what the wand reads")
        #expect(coverage(s, 30, 10) == 0)
    }

    @Test func magicWandContiguousAndModes() throws {
        let s = try session()
        try s.execute("select.magicWand", ["x": 7, "y": 7, "antiAlias": false])
        #expect(coverage(s, 10, 10) == 1)
        #expect(coverage(s, 30, 10) == 0)
        try s.execute("select.magicWand", ["x": 30, "y": 7, "mode": "add", "antiAlias": false])
        #expect(coverage(s, 30, 10) == 1)
        try s.execute("select.magicWand", ["x": 7, "y": 7, "mode": "subtract", "antiAlias": false])
        #expect(coverage(s, 10, 10) == 0)
        try s.execute("select.magicWand", ["x": 7, "y": 7, "contiguous": false, "antiAlias": false])
        #expect(coverage(s, 30, 10) == 1)
    }

    @Test func colorRangePreparedQueryMatchesTheCommandAtAllDepths() throws {
        for depth in [SampleType.u8, .u16, .f32] {
            for profile in [nil, BuiltinProfile.displayP3.profile.data] as [Data?] {
                var doc = Document.withBackground(name: "samples", size: PixelSize(width: 24, height: 12), mode: .rgb, depth: depth, fill: .white)
                doc.iccProfile = profile.map { [UInt8]($0) }
                let bg = doc.layers[0].id
                doc.withRaster(of: bg) { surf in
                    surf.fill(Self.rect(0, 0, 8, 12), with: surf.format.components(fromRGBA: SIMD4(0.65, 0.3, 0.2, 1)))
                    surf.fill(Self.rect(8, 0, 16, 12), with: surf.format.components(fromRGBA: SIMD4(0.2, 0.3, 0.65, 1)))
                }
                let s = Session()
                s.addDocument(doc)
                for p: JSONValue in [
                    ["points": [[2, 3]], "fuzziness": 0],
                    ["points": [[2, 3], [10, 3]], "subtractPoints": [[10, 3]], "order": ["+", "+", "-"], "fuzziness": 40],
                    ["points": [[2, 3]], "localized": true, "range": 50, "fuzziness": 80],
                ] {
                    try clearSelection(s)
                    let q = try SelectionCommands.ColorRangeSamples(s, p)
                    let d = s.active!.doc
                    let pixels = try s.services.renderer.render(d, region: d.bounds)
                    let preview = q.coverage(pixels.px, width: 24)
                    try s.execute("select.colorRange", p)
                    let actual = mask(s)
                    for (shown, selected) in zip(preview, actual) {
                        let rounded = (min(max(shown, 0), 1) * 255 + 0.5).rounded(.down) / 255
                        #expect(rounded == selected, "\(depth): original-pixel preview and OK differ")
                    }
                }
            }
        }
    }

    @Test func colorRangePreparedQuerySamplesVisibleLayersNotTheActiveLayer() throws {
        let s = try sessionColours()
        let base = try #require(s.active?.doc.layers[0].rasterSurface)
        var blue = base
        blue.fill(Self.rect(0, 0, 40, 30), with: blue.format.components(fromRGBA: SIMD4(0, 0, 1, 1)))
        var green = base
        green.fill(Self.rect(0, 0, 40, 30), with: green.format.components(fromRGBA: SIMD4(0, 1, 0, 1)))
        var hidden = Layer.raster("hidden green", surface: green)
        hidden.visible = false
        try s.edit("layers") { doc, _ in
            doc.layers.append(Layer.raster("blue foreground", surface: blue))
            doc.layers.append(hidden)
        }
        for allLayers in [false, true] {
            try clearSelection(s)
            let p: JSONValue = ["points": [[7, 7]], "sampleAllLayers": .bool(allLayers), "fuzziness": 0]
            let query = try SelectionCommands.ColorRangeSamples(s, p)
            let (area, px) = try SelectionCommands.samplePixels(s, allLayers: allLayers)
            let shown = query.coverage(px, width: area.width)
            try s.execute("select.colorRange", p)
            #expect(shown[7 * 40 + 7] == coverage(s, 7, 7))
            #expect(shown[24 * 40 + 10] == coverage(s, 10, 24))
        }
        for p: JSONValue in [["points": [[-1, 0]]], ["points": [[40, 1]]], ["points": "wrong"], ["points": [[.null, 0]]]] {
            #expect(throws: EngineError.self, "\(p.serialized())") { _ = try SelectionCommands.ColorRangeSamples(s, p) }
        }
    }

    @Test func colorRangeSelectsByColour() throws {
        let s = try session()
        try s.execute("select.colorRange", ["color": "#ff0000", "fuzziness": 40])
        // The sampled colour itself is fully selected (as with Photoshop's eyedropper).
        #expect(coverage(s, 10, 10) == 1)
        #expect(coverage(s, 20, 20) == 0)
        try s.execute("select.colorRange", ["color": "#ff0000", "fuzziness": 100])
        #expect(coverage(s, 10, 10) == 1)
        #expect(coverage(s, 20, 20) == 0)
    }

    @Test func colorRangeComparesInLabLikePhotoshop() throws {
        // Photoshop weighs hue (Lab a/b) three times as much as lightness.
        let s = Session()
        try s.execute("file.new", ["width": 30, "height": 10])
        func v(_ c: Float) -> Float { c / 255 }
        try Self.paint(s, Self.rect(0, 0, 10, 10), SIMD4(v(200), v(140), v(120), 1)) // skin
        try Self.paint(s, Self.rect(10, 0, 20, 10), SIMD4(v(220), v(160), v(140), 1)) // lighter skin
        try Self.paint(s, Self.rect(20, 0, 30, 10), SIMD4(v(220), v(140), v(120), 1)) // redder skin
        try s.execute("select.colorRange", ["points": [[5, 5]], "fuzziness": 40])
        #expect(coverage(s, 5, 5) > 0.98)
        // Both differ from the sample by 20 levels in one RGB channel, yet the lighter one is
        // kept clearly more (about 0.55 vs 0.31).
        let lighter = coverage(s, 15, 5), redder = coverage(s, 25, 5)
        #expect(lighter > redder + 0.15 && redder > 0, "lighter \(lighter), redder \(redder)")
    }

    /// Red squares (from `session`), a blue square, a black and a mid-grey strip on white.
    func sessionColours() throws -> Session {
        let s = try session()
        try Self.paint(s, Self.rect(5, 20, 15, 28), SIMD4(0, 0, 1, 1))
        try Self.paint(s, Self.rect(20, 20, 25, 28), SIMD4(0, 0, 0, 1))
        try Self.paint(s, Self.rect(30, 20, 35, 28), SIMD4(0.5, 0.5, 0.5, 1))
        return s
    }

    @Test func colorRangeSeveralSamplesPointsAndInvert() throws {
        let s = try sessionColours()
        // Several samples span one Lab box: red and blue take both squares, black, grey and
        // white stay out.
        try s.execute("select.colorRange", ["colors": ["#ff0000", "#0000ff"], "fuzziness": 100])
        #expect([coverage(s, 10, 10), coverage(s, 30, 10), coverage(s, 10, 24)] == [1, 1, 1])
        #expect([coverage(s, 2, 2), coverage(s, 22, 24), coverage(s, 32, 24)] == [0, 0, 0])
        // Eyedropper point on the blue square; `invert` flips the result.
        try clearSelection(s)
        try s.execute("select.colorRange", ["points": [[7, 22]], "fuzziness": 100, "invert": true])
        #expect([coverage(s, 10, 24), coverage(s, 10, 10), coverage(s, 2, 2)] == [0, 1, 1])
        // Localized clusters: picked on the left red square, a 25% range (10 px) leaves the right one.
        try clearSelection(s)
        try s.execute("select.colorRange", ["points": [[10, 10]], "fuzziness": 100, "localized": true, "range": 25])
        #expect(coverage(s, 10, 10) == 1)
        #expect(coverage(s, 13, 10) > 0.5)
        #expect(coverage(s, 30, 10) == 0)
        // Undo restores the empty selection that preceded the most recent Color Range.
        try s.execute("edit.undo")
        #expect(coverage(s, 2, 2) == 0)
    }

    @Test func colorRangeSubtractFollowsPhotoshopAndTheClickOrder() throws {
        // Grey strips from dark to light; samples at both ends span the whole run.
        let s = Session()
        try s.execute("file.new", ["width": 50, "height": 10])
        for (i, v) in [Float(0.30), 0.40, 0.50, 0.60, 0.70].enumerated() {
            try Self.paint(s, Self.rect(Int32(i) * 10, 0, Int32(i) * 10 + 10, 10), SIMD4(v, v, v, 1))
        }
        func run(_ extra: JSONValue) throws -> [Float] {
            try clearSelection(s)
            let p = JSONValue.object(["points": [[5, 5], [45, 5]], "fuzziness": 10]).merging(extra)
            try s.execute("select.colorRange", p)
            return (0..<5).map { coverage(s, Int32($0) * 10 + 5, 5) }
        }
        #expect(try run([:]).allSatisfy { $0 > 0.99 }, "both samples span every strip")
        // Subtracting a colour inside the range moves the nearer edge onto it.
        let cut = try run(["subtractPoints": [[15, 5]]])
        #expect(cut[0] < 0.5 && cut[1] > 0.99 && cut[4] > 0.99, "\(cut)")
        // Order matters: adding the dark strip back after the subtraction restores it.
        let readd = try run(["points": [[5, 5], [45, 5], [5, 5]], "subtractPoints": [[15, 5]], "order": ["+", "+", "-", "+"]])
        #expect(readd[0] > 0.99, "\(readd)")
        let subLast = try run(["points": [[5, 5], [45, 5], [5, 5]], "subtractPoints": [[15, 5]], "order": ["+", "+", "+", "-"]])
        #expect(subLast[0] < 0.5, "\(subLast)")
        // A malformed or inconsistent order is an error, never a trap.
        try clearSelection(s)
        for badOrder: JSONValue in [["+"], ["+", "+", "x"], "+-", ["-", "-", "+"]] {
            #expect(throws: EngineError.self) {
                try s.execute("select.colorRange", ["points": [[5, 5], [45, 5]], "subtractPoints": [[15, 5]], "order": badOrder])
            }
        }
    }

    @Test func colorRangePresets() throws {
        let s = try sessionColours()
        try s.execute("select.colorRange", ["select": "reds"])
        #expect([coverage(s, 10, 10), coverage(s, 30, 10)] == [1, 1])
        #expect([coverage(s, 10, 24), coverage(s, 2, 2), coverage(s, 32, 24)] == [0, 0, 0])
        try clearSelection(s)
        try s.execute("select.colorRange", ["select": "blues"])
        #expect([coverage(s, 10, 24), coverage(s, 10, 10)] == [1, 0])
        try clearSelection(s)
        try s.execute("select.colorRange", ["select": "greens"])
        #expect(s.active?.doc.selection == nil || coverage(s, 10, 10) == 0)
        // Tones: black is a shadow, white a highlight, 50% grey (128) a midtone.
        try clearSelection(s)
        try s.execute("select.colorRange", ["select": "shadows"])
        #expect([coverage(s, 22, 24), coverage(s, 2, 2), coverage(s, 32, 24)] == [1, 0, 0])
        try clearSelection(s)
        try s.execute("select.colorRange", ["select": "highlights"])
        #expect([coverage(s, 22, 24), coverage(s, 2, 2)] == [0, 1])
        try clearSelection(s)
        try s.execute("select.colorRange", ["select": "midtones", "fuzziness": 0])
        #expect([coverage(s, 32, 24), coverage(s, 2, 2), coverage(s, 22, 24)] == [1, 0, 0])
        // A wider shadow range takes the grey too.
        try clearSelection(s)
        try s.execute("select.colorRange", ["select": "shadows", "tonalRange": 140, "fuzziness": 0])
        #expect(coverage(s, 32, 24) == 1)
        // Modes combine as for the other selection commands.
        try s.execute("select.colorRange", ["select": "reds", "mode": "add"])
        #expect([coverage(s, 32, 24), coverage(s, 10, 10)] == [1, 1])
    }

    /// photocraft also compares with `view.gamutWarning`'s count (color_cmds, not ported here).
    @Test func colorRangeOutOfGamut() throws {
        let s = try session()
        // Saturated sRGB blue is outside the default CMYK proof; mid grey is inside.
        try Self.paint(s, Self.rect(0, 20, 20, 30), SIMD4(0, 0, 1, 1))
        try Self.paint(s, Self.rect(20, 20, 40, 30), SIMD4(0.5, 0.5, 0.5, 1))
        try s.execute("select.colorRange", ["select": "outOfGamut"])
        #expect([coverage(s, 5, 25), coverage(s, 30, 25)] == [1, 0])
    }

    @Test func colorRangeRejectsBadParams() throws {
        let s = try sessionColours()
        for p: JSONValue in [
            ["select": "skin"],
            ["select": 3],
            ["points": [[100, 2]]],
            ["points": [[1]]],
            ["points": "here"],
            ["colors": "#ff0000"],
            ["localized": true],
            ["select": "midtones", "tonalRange": [200, 100]],
            ["select": "shadows", "tonalRange": 300],
        ] {
            #expect(throws: EngineError.self, "\(p.serialized())") { try s.execute("select.colorRange", p) }
        }
        #expect(s.active?.doc.selection == nil)
    }

    @Test func modifyCommands() throws {
        let s = try session()
        try s.execute("select.rect", ["x": 10, "y": 10, "width": 10, "height": 10])
        try s.execute("select.modify.expand", ["radius": 2])
        #expect(coverage(s, 8, 15) == 1)
        try s.execute("select.modify.contract", ["radius": 4])
        #expect(coverage(s, 11, 15) == 0)
        #expect(coverage(s, 15, 15) == 1)
        try s.execute("select.modify.border", ["radius": 2])
        #expect(coverage(s, 15, 15) == 0)
        try s.execute("select.rect", ["x": 10, "y": 10, "width": 10, "height": 10])
        try s.execute("select.modify.feather", ["radius": 4])
        let e = coverage(s, 10, 15)
        #expect(e > 0.2 && e < 0.8, "\(e)")
        try s.execute("select.modify.smooth", ["radius": 2])
        #expect(s.active?.doc.selection != nil)
        #expect(!s.isEnabled("select.nothing"))
        // Out-of-range or non-finite radii are refused and leave the selection alone.
        for op in ["feather", "smooth", "expand", "contract", "border"] {
            for r in [1e300, 5000, Double.greatestFiniteMagnitude, -5, -0.5, -Double.greatestFiniteMagnitude] {
                #expect(throws: EngineError.self, "\(op) \(r)") { try s.execute("select.modify.\(op)", ["radius": .number(r)]) }
            }
        }
        #expect(s.active?.doc.selection != nil)
    }

    @Test func modifySelectAllHonoursCanvasBounds() throws {
        func all() throws -> Session {
            let s = Session()
            try s.execute("file.new", ["width": 40, "height": 30])
            try s.execute("select.all")
            return s
        }
        // Off (Photoshop's default): the selection continues past the canvas, so the edges stay.
        for op in ["contract", "smooth", "expand", "feather"] {
            let s = try all()
            try s.execute("select.modify.\(op)", ["radius": 4])
            #expect(coverage(s, 0, 15) == 1, "\(op)")
            #expect(coverage(s, 20, 0) == 1, "\(op)")
        }
        // On: the canvas edge is a selection edge (#1277).
        var s = try all()
        try s.execute("select.modify.contract", ["radius": 4, "applyAtCanvasBounds": true])
        #expect(coverage(s, 2, 15) == 0)
        #expect(coverage(s, 20, 28) == 0)
        #expect(coverage(s, 20, 15) == 1)
        s = try all()
        try s.execute("select.modify.feather", ["radius": 4, "applyAtCanvasBounds": true])
        let e = coverage(s, 0, 15)
        #expect(e > 0.2 && e < 0.8, "\(e)")
        #expect(coverage(s, 20, 15) == 1)
        s = try all()
        try s.execute("select.modify.smooth", ["radius": 4, "applyAtCanvasBounds": true])
        #expect(coverage(s, 0, 0) < 1)
        // Border always follows the canvas edge: a band inside it, not an empty selection.
        s = try all()
        try s.execute("select.modify.border", ["radius": 4])
        #expect(coverage(s, 0, 15) > 0)
        #expect(coverage(s, 20, 15) == 0)
    }

    @Test func modifyAwayFromTheCanvasEdgeIgnoresCanvasBounds() throws {
        for at in [false, true] {
            let s = try session()
            try s.execute("select.rect", ["x": 10, "y": 10, "width": 10, "height": 10])
            try s.execute("select.modify.contract", ["radius": 4, "applyAtCanvasBounds": .bool(at)])
            #expect(coverage(s, 11, 15) == 0)
            #expect(coverage(s, 15, 15) == 1)
        }
    }

    @Test func modifyRefusesRadiiBelowTheMinimum() throws {
        let s = try session()
        try s.execute("select.rect", ["x": 10, "y": 10, "width": 10, "height": 10])
        let below: [(String, Double)] = [
            ("border", -5), ("border", 0.5), ("smooth", -5), ("smooth", 0), ("expand", -5), ("expand", 0),
            ("contract", -5), ("contract", 0.9), ("feather", -5), ("feather", 0), ("feather", 0.05),
        ]
        let before = mask(s)
        for (op, r) in below {
            do {
                try s.execute("select.modify.\(op)", ["radius": .number(r)])
                Issue.record("\(op) \(r) accepted")
            } catch let e as EngineError {
                if case .badParams = e {} else { Issue.record("\(op) \(r): \(e)") }
            }
            #expect(mask(s) == before, "\(op) \(r): the selection changed")
        }
        // The minimum itself is still accepted.
        try s.execute("select.modify.feather", ["radius": 0.1])
        try s.execute("select.modify.expand", ["radius": 1])
        #expect(coverage(s, 9, 15) == 1)
    }

    @Test func geometryParamsThatWouldWrapAreRejected() throws {
        let s = try session()
        for x in [4_294_967_346.0, 3_000_000_000.0] {
            do {
                try s.execute("select.rect", ["x": .number(x), "y": 0, "width": 10, "height": 10])
                Issue.record("accepted \(x)")
            } catch {
                #expect("\(error)".contains("32-bit"), "\(error)")
            }
        }
        // In-range coordinates, including negative and past-canvas ones, are unaffected.
        try s.execute("select.rect", ["x": -100, "y": -100, "width": 500, "height": 500])
        try s.execute("document.pixel", ["x": 0, "y": 0])
    }

    @Test func growAndSimilar() throws {
        let s = try session()
        try s.execute("select.rect", ["x": 6, "y": 6, "width": 2, "height": 2])
        try s.execute("select.grow", ["tolerance": 5])
        #expect(coverage(s, 14, 14) == 1)
        #expect(coverage(s, 30, 10) == 0)
        try s.execute("select.similar", ["tolerance": 5])
        #expect(coverage(s, 30, 10) == 1)
        #expect(coverage(s, 20, 20) == 0)
    }

    @Test func lassoPolygon() throws {
        let s = try session()
        try s.execute("select.lasso", ["points": [[0, 0], [20, 0], [0, 20]]])
        #expect(coverage(s, 2, 2) == 1)
        #expect(coverage(s, 18, 18) == 0)
        #expect(throws: EngineError.self) { try s.execute("select.lasso", ["points": [[0, 0], [1, 1]]]) }
        try s.execute("select.lasso", ["points": [[0, 0], [20, 0], [0, 20]], "mode": "subtract"])
        #expect(s.active?.doc.selection == nil)
        try s.execute("edit.undo")
        #expect(coverage(s, 2, 2) == 1)
    }

    /// The previous per-sample padding, kept as the oracle for the row-wise one.
    func oldPadMask(_ m: [Float], _ w: Int, _ h: Int, _ pad: Int, _ outsideEmpty: Bool) -> [Float] {
        let pw = w + 2 * pad
        var out = [Float](repeating: 0, count: pw * (h + 2 * pad))
        for py in 0..<(h + 2 * pad) {
            let insideY = py >= pad && py < pad + h
            if outsideEmpty && !insideY { continue }
            let y = min(max(py - pad, 0), h - 1)
            for px in 0..<pw {
                if outsideEmpty && !(px >= pad && px < pad + w) { continue }
                out[py * pw + px] = m[y * w + min(max(px - pad, 0), w - 1)]
            }
        }
        return out
    }

    @Test func rowWisePadAndCropMatchPerSampleOnes() {
        var seed: UInt64 = 0x2545_f491_4f6c_dd1d
        let w = 37, h = 23
        let m: [Float] = (0..<(w * h)).map { _ in
            seed ^= seed << 13
            seed ^= seed >> 7
            seed ^= seed << 17
            return Float(seed % 1000) / 999
        }
        for pad in [0, 1, 5, 40] {
            for outsideEmpty in [false, true] {
                let padded = SelectionCommands.padMask(m, w, h, pad, outsideEmpty: outsideEmpty)
                #expect(padded == oldPadMask(m, w, h, pad, outsideEmpty), "pad \(pad) \(outsideEmpty)")
                #expect(SelectionCommands.cropMask(padded, w + 2 * pad, pad, w, h) == m, "pad \(pad)")
            }
        }
    }

    /// The direct (per-pixel) distance transform as the oracle for the parabola envelope (PCAlgo's
    /// `Selection.edt`, the CPU reference the Modify commands run).
    @Test func edtMatchesBruteForce() throws {
        let w = 19, h = 13
        var seed: UInt64 = 7
        let inside: [Bool] = (0..<(w * h)).map { _ in
            seed = seed &* 6364136223846793005 &+ 1442695040888963407
            return (seed >> 33) % 11 == 0
        }
        let d = try Selection.edt(inside, w: w, h: h, on: .cpu)
        for y in 0..<h {
            for x in 0..<w {
                var best = Float.infinity
                for yy in 0..<h { for xx in 0..<w where inside[yy * w + xx] {
                    best = min(best, Float(((x - xx) * (x - xx) + (y - yy) * (y - yy))).squareRoot())
                } }
                #expect(abs(d[y * w + x] - best) < 1e-4, "(\(x), \(y))")
            }
        }
        #expect(try Selection.edt([Bool](repeating: false, count: 4), w: 2, h: 2, on: .cpu) == [Float](repeating: 1e10, count: 4))
        #expect(try Selection.edt([true, true], w: 2, h: 1, on: .cpu) == [0, 0])
        #expect(try Selection.edt([true], w: 2, h: 1, on: .cpu).isEmpty)
    }
}
