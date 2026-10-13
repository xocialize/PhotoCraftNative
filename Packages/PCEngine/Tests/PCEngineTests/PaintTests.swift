// Port of photocraft-engine (crates/engine/src/paint_cmds.rs tests, with photocraft-algo paint.rs tests), MIT OR Apache-2.0, © ArtCraft Team and the PhotoCraft contributors.

import PCAlgo
import PCDocument
@testable import PCEngine
import PCFoundation
import Testing

@Suite struct PaintTests {
    typealias K = PaintTestKit
    typealias P = PaintCommands

    func session() throws -> Session { try K.session(20, 10, background: "white") }

    func px(_ s: Session, _ x: Int32, _ y: Int32) -> [Float] {
        guard let d = s.active, let id = d.activeLayer, let surf = d.doc.layer(id)?.surface else { return [] }
        return surf.pixel(x: x, y: y)
    }

    /// A visible wall on the Background with an empty, active layer above it.
    func bucketLayers(_ depth: Int) throws -> (Session, LayerId) {
        let s = try K.session(20, 10, background: "white", depth: depth)
        let bottom = try #require(s.active?.activeLayer)
        try s.edit("wall") { doc, _ in _ = doc.withRaster(of: bottom) { $0.fill(PixelRect(x0: 10, y0: 0, x1: 11, y1: 10), with: $0.format.components(fromRGBA: SIMD4(0, 0, 0, 1))) } }
        try s.execute("layer.new.layer")
        return (s, bottom)
    }

    /// A "Diagonal Lines" pattern in the document (the session pattern library belongs to the
    /// patterns port).
    func addDiagonalLines(_ s: Session) throws {
        var surf = Surface(format: .rgba8)
        for y in Int32(0)..<8 {
            for x in Int32(0)..<8 { surf.setPixel(x: x, y: y, (x + y) % 8 < 2 ? [0, 0, 0, 1] : [1, 1, 1, 1]) }
        }
        try s.edit("pattern") { doc, _ in doc.patterns.append(PCDocument.Pattern(name: "Diagonal Lines", surface: surf, width: 8, height: 8)) }
    }

    @Test func bucketSampleAllLayersUsesVisibleBoundariesAtAllDepths() throws {
        for depth in [8, 16, 32] {
            for all: Bool? in [nil, false, true] {
                let (s, bottom) = try bucketLayers(depth)
                let before = s.active?.doc.layer(bottom)
                var p: JSONValue = ["x": 2, "y": 2, "color": "#ff0000", "antiAlias": false, "tolerance": 0]
                if let all { p = p.setting("sampleAllLayers", .bool(all)) }
                #expect(try s.execute("paint.bucket", p)["filled"] == true)
                #expect(px(s, 5, 5) == [1, 0, 0, 1], "depth \(depth), all \(String(describing: all))")
                let beyond: [Float] = all == true ? [0, 0, 0, 0] : [1, 0, 0, 1]
                #expect(px(s, 15, 5) == beyond, "depth \(depth), all \(String(describing: all)): sample flag controls the boundary")
                #expect(s.active?.doc.layer(bottom) == before, "only the active layer is written")
                if all == true {
                    #expect(px(s, 10, 5) == [0, 0, 0, 0], "wall itself is untouched")
                    #expect(s.undo())
                    try s.execute("paint.bucket", p.setting("contiguous", false))
                    #expect(px(s, 15, 5) == [1, 0, 0, 1], "noncontiguous finds both white regions")
                    #expect(px(s, 10, 5) == [0, 0, 0, 0])
                    #expect(s.undo())
                    #expect(try s.execute("paint.bucket", ["x": -1, "y": 2, "sampleAllLayers": true])["filled"] == false)
                    #expect(px(s, 5, 5) == [0, 0, 0, 0], "an off-canvas sample does not fill the layer")
                }
            }
        }
    }

    @Test func bucketSampleAllLayersIgnoresHiddenLayers() throws {
        let (s, _) = try bucketLayers(8)
        try s.edit("hidden wall") { doc, active in
            guard let id = active else { return }
            _ = doc.updateLayer(id) { l in
                _ = l.withRaster { $0.fill(PixelRect(x0: 4, y0: 0, x1: 5, y1: 10), with: [0, 0, 0, 1]) }
                l.visible = false
            }
        }
        try s.execute("layer.new.layer")
        try s.execute("paint.bucket", ["x": 2, "y": 2, "color": "#ff0000", "antiAlias": false, "tolerance": 0, "sampleAllLayers": true])
        #expect(px(s, 4, 5) == [1, 0, 0, 1], "hidden wall does not bound the fill")
        #expect(px(s, 8, 5) == [1, 0, 0, 1])
        #expect(px(s, 15, 5) == [0, 0, 0, 0], "visible wall still bounds the fill")
    }

    @Test func bucketSampleAllLayersKeepsSelectionOpacityAndHistory() throws {
        for depth in [8, 16, 32] {
            let (s, _) = try bucketLayers(depth)
            try s.execute("select.rect", ["x": 0, "y": 2, "width": 20, "height": 6])
            try s.edit("feather") { doc, _ in doc.selection?.fill(PixelRect(x0: 0, y0: 2, x1: 4, y1: 8), with: [0.5]) }
            let selection = s.active?.doc.selection
            try s.execute("paint.bucket", ["x": 2, "y": 5, "color": "#ff0000", "antiAlias": false, "tolerance": 0, "opacity": 50, "sampleAllLayers": true])
            let (feathered, full) = (px(s, 2, 5), px(s, 6, 5))
            #expect(abs(feathered[3] - 0.25) < 0.005 && abs(full[3] - 0.5) < 0.005, "depth \(depth): selection coverage multiplies opacity")
            #expect(Array(full[..<3]) == [1, 0, 0])
            #expect(px(s, 6, 1) == [0, 0, 0, 0], "outside selection")
            #expect(px(s, 15, 5) == [0, 0, 0, 0], "outside sampled region")
            #expect(s.active?.history.undoLabel == "Paint Bucket")
            #expect(s.undo())
            #expect(px(s, 2, 5) == [0, 0, 0, 0])
            #expect(s.active?.doc.selection == selection)
            #expect(s.redo())
            #expect(px(s, 2, 5) == feathered)
            #expect(px(s, 6, 5) == full)
            #expect(s.active?.doc.selection == selection)
        }
    }

    @Test func bucketSampleAllLayersPatternUsesTheSameRegion() throws {
        let (s, _) = try bucketLayers(8)
        try addDiagonalLines(s)
        try s.execute("paint.bucket", ["x": 2, "y": 2, "contents": "pattern", "pattern": "Diagonal Lines", "antiAlias": false, "tolerance": 0,
                                       "sampleAllLayers": true])
        let left = (0..<10).map { px(s, Int32($0), 0)[0] }
        #expect(left.contains { $0 < 0.3 } && left.contains { $0 > 0.9 }, "pattern varies inside the region: \(left)")
        #expect(px(s, 10, 5) == [0, 0, 0, 0], "wall untouched")
        #expect(px(s, 15, 5) == [0, 0, 0, 0], "region past the wall untouched")
    }

    @Test func bucketSampleAllLayersMaskAndChannelTargetsKeepTheirOwnBoundaries() throws {
        for target: JSONValue in ["mask", ["channel": 0], "quickMask"] {
            for all in [false, true] {
                let (s, _) = try bucketLayers(8)
                switch Channels.targetOf(["target": target]) {
                case .mask:
                    try s.execute("layer.layerMask.revealAll")
                case .alpha:
                    try s.edit("New Channel") { doc, _ in
                        doc.channels.append(AlphaChannel(name: "Alpha 1", surface: Surface(format: Channels.channelFormat(doc), defaultPixel: [1])))
                    }
                case .quickMask:
                    try s.edit("Quick Mask") { doc, _ in
                        doc.quickMask = AlphaChannel(name: "Quick Mask", surface: Surface(format: Channels.channelFormat(doc), defaultPixel: [0]))
                    }
                default:
                    Issue.record("expected a grayscale target")
                }
                let p: JSONValue = ["x": 2, "y": 2, "color": "#000000", "antiAlias": false, "tolerance": 0, "target": target, "sampleAllLayers": .bool(all)]
                try s.edit("target wall") { doc, active in
                    let area = doc.bounds
                    try Channels.withTargetSurface(&doc, layer: active, p) { surf, _ in
                        surf.fill(area, with: [1])
                        surf.fill(PixelRect(x0: 5, y0: 0, x1: 6, y1: 10), with: [0])
                    }
                }
                try s.execute("paint.bucket", p)
                let d = try #require(s.active)
                let surf = try Channels.readTargetSurface(d.doc, layer: d.activeLayer, p)
                #expect(surf.sampleChannel(x: 2, y: 5, 0) == 0, "\(target), all \(all): filled target")
                #expect(surf.sampleChannel(x: 7, y: 5, 0) == 1, "\(target), all \(all): stopped at target wall")
                #expect(px(s, 2, 5) == [0, 0, 0, 0], "layer pixels remain untouched")
            }
        }
    }

    @Test func bucketFillContiguous() throws {
        let s = try session()
        try s.edit("wall") { doc, _ in _ = doc.withRaster(of: doc.layers[0].id) { $0.fill(PixelRect(x0: 10, y0: 0, x1: 11, y1: 10), with: [0, 0, 0, 1]) } }
        try s.execute("paint.bucket", ["x": 2, "y": 2, "color": "#ff0000", "antiAlias": false])
        #expect(px(s, 5, 5) == [1, 0, 0, 1])
        #expect(px(s, 15, 5) == [1, 1, 1, 1])
        try s.execute("paint.bucket", ["x": 2, "y": 2, "color": "#0000ff", "contiguous": false, "antiAlias": false, "tolerance": 0])
        #expect(px(s, 5, 5) == [0, 0, 1, 1])
    }

    @Test func bucketFillsWithAPattern() throws {
        // Paint Bucket with contents="pattern" flood-fills the region with a pattern, not a colour.
        let s = try session()
        try s.edit("wall") { doc, _ in _ = doc.withRaster(of: doc.layers[0].id) { $0.fill(PixelRect(x0: 10, y0: 0, x1: 11, y1: 10), with: [0, 0, 0, 1]) } }
        try addDiagonalLines(s)
        try s.execute("paint.bucket", ["x": 2, "y": 2, "contents": "pattern", "pattern": "Diagonal Lines", "antiAlias": false, "tolerance": 0])
        let left = (0..<10).map { px(s, Int32($0), 0)[0] }
        #expect(left.contains { $0 < 0.3 } && left.contains { $0 > 0.9 }, "pattern varies in the fill: \(left)")
        #expect(px(s, 15, 5) == [1, 1, 1, 1], "region past the wall untouched")
        #expect(throws: EngineError.self, "an unknown pattern") { try s.execute("paint.bucket", ["x": 2, "y": 2, "contents": "pattern", "pattern": "Nope"]) }
    }

    @Test func gradientToolWithSelectionAndReverse() throws {
        let s = try session()
        try s.execute("paint.gradient", ["from": [0, 0], "to": [20, 0], "colors": ["#000000", "#ffffff"]])
        #expect(px(s, 0, 5)[0] < 0.05 && px(s, 19, 5)[0] > 0.95)
        try s.execute("paint.gradient", ["from": [0, 0], "to": [20, 0], "colors": ["#000000", "#ffffff"], "reverse": true])
        #expect(px(s, 0, 5)[0] > 0.95)
        try s.execute("select.rect", ["x": 0, "y": 0, "width": 5, "height": 10])
        try s.execute("paint.gradient", ["from": [0, 0], "to": [0, 10], "colors": ["#ff0000"]])
        #expect(Array(px(s, 2, 5)[..<3]) == [1, 0, 0])
        #expect(px(s, 10, 5)[1] > 0.4, "outside the selection untouched")
        #expect(throws: EngineError.self) { try s.execute("paint.gradient", ["from": [0, 0]]) }
    }

    @Test func gradientDitherBreaksBanding() throws {
        // A flat gradient is perfectly smooth with dither off, and gains per-pixel noise with dither on.
        func run(_ dither: Bool) throws -> [Float] {
            let s = try session()
            try s.execute("paint.gradient", ["from": [0, 0], "to": [19, 0], "colors": [[0.5, 0.5, 0.5, 1.0], [0.5, 0.5, 0.5, 1.0]], "dither": .bool(dither)])
            return (0..<19).map { px(s, Int32($0), 5)[0] }
        }
        let smooth = try run(false)
        #expect(smooth.allSatisfy { $0 == smooth[0] }, "no dither: perfectly flat")
        let noisy = try run(true)
        #expect(zip(noisy, noisy.dropFirst()).contains { $0 != $1 }, "dither: per-pixel variation")
    }

    @Test func gradientStopsPresetsAndTransparency() throws {
        // `stops`, a Basics preset by name and `transparency` (photocraft presets/gradients.rs).
        let s = try K.session(20, 10)
        try s.execute("paint.gradient", ["from": [0, 0], "to": [20, 0], "stops": [[0, "#ff0000"], [1, "#0000ff"]], "dither": false])
        #expect(px(s, 0, 5)[0] > 0.95 && px(s, 19, 5)[2] > 0.9)
        try s.execute("tools.setColors", ["foreground": "#00ff00"])
        try s.execute("edit.clear")
        try s.execute("paint.gradient", ["from": [0, 0], "to": [20, 0], "gradient": "Foreground to Transparent", "dither": false])
        #expect(px(s, 0, 5)[3] > 0.9 && px(s, 19, 5)[3] < 0.1 && px(s, 0, 5)[1] > 0.95)
        #expect(throws: EngineError.self) { try s.execute("paint.gradient", ["from": [0, 0], "to": [20, 0], "gradient": "Nope"]) }
        #expect(throws: EngineError.self) { try s.execute("paint.gradient", ["from": [0, 0], "to": [20, 0], "stops": [[0, "#ff0000"]]]) }
        #expect(throws: EngineError.self) { try s.execute("paint.gradient", ["from": [0, 0], "to": [20, 0], "transparency": "x"]) }
    }

    // photocraft-algo paint.rs tests (the bucket and the gradient's t are PCAlgo's `PaintBucket` and
    // `GradientTool`; the gradient composite is the engine's `paintGradient`)

    @Test func gradientTShapes() {
        let (f, t) = (SIMD2<Float>(0, 0), SIMD2<Float>(10, 0))
        #expect(GradientTool.t(.linear, from: f, to: t, x: 5, y: 3) == 0.5)
        #expect(GradientTool.t(.linear, from: f, to: t, x: -5, y: 0) == 0)
        #expect(GradientTool.t(.radial, from: f, to: t, x: 0, y: 5) == 0.5)
        #expect(GradientTool.t(.reflected, from: f, to: t, x: -5, y: 0) == 0.5)
        #expect(GradientTool.t(.diamond, from: f, to: t, x: 2.5, y: 2.5) == 0.5)
        #expect(abs(GradientTool.t(.angle, from: f, to: t, x: 0, y: 5) - 0.25) < 1e-5)
    }

    @Test func gradientPaintsRampWithinSelection() {
        var s = Surface(format: .rgba8)
        let a = PixelRect(x0: 0, y0: 0, x1: 11, y1: 2)
        var sel = Surface(format: .gray8)
        sel.fill(PixelRect(x0: 0, y0: 0, x1: 11, y1: 1), with: [1])
        P.paintGradient(&s, a, from: SIMD2(0.5, 0), to: SIMD2(10.5, 0), shape: .linear, stops: [(0, SIMD4(0, 0, 0, 1)), (1, SIMD4(1, 1, 1, 1))],
                        reverse: false, opacity: 1, mode: .normal, dither: false, selection: sel, lockTransparency: false)
        #expect(s.pixel(x: 0, y: 0)[0] < 0.01 && s.pixel(x: 10, y: 0)[0] > 0.99)
        #expect(abs(s.pixel(x: 5, y: 0)[0] - 0.5) < 0.01)
        #expect(s.pixel(x: 5, y: 1)[3] == 0, "outside the selection")
    }

    @Test func bucketFillsContiguousRegion() {
        var s = Surface(format: .rgba8)
        let a = PixelRect(x0: 0, y0: 0, x1: 10, y1: 10)
        s.fill(a, with: [1, 1, 1, 1])
        s.fill(PixelRect(x0: 5, y0: 0, x1: 6, y1: 10), with: [0, 0, 0, 1])
        #expect(PaintBucket.fill(&s, area: a, seed: (1, 1), tolerance: 10, contiguous: true, antiAlias: false, color: SIMD4(1, 0, 0, 1), opacity: 1))
        #expect(s.pixel(x: 2, y: 2) == [1, 0, 0, 1])
        #expect(s.pixel(x: 8, y: 2) == [1, 1, 1, 1])
        #expect(!PaintBucket.fill(&s, area: a, seed: (50, 1), tolerance: 10, contiguous: true, antiAlias: false, color: SIMD4(1, 0, 0, 1), opacity: 1))
    }

    @Test func bucketRegionUsesDocumentCoordinatesAndMultipliesCoverage() {
        var s = Surface(format: .rgba8)
        let region = SelectionRegion(bbox: PixelRect(x0: -3, y0: 4, x1: 0, y1: 5), mask: [255, 128, 255])
        var selection = Surface(format: .gray8)
        selection.fill(PixelRect(x0: -3, y0: 4, x1: -1, y1: 5), with: [0.5])
        PaintBucket.fill(&s, region: region, opacity: 0.5, selection: selection, lockTransparency: false) { _, _ in SIMD4(1, 0, 0, 1) }
        #expect(abs(s.rgba(x: -3, y: 4).w - 0.25) < 0.005)
        #expect(abs(s.rgba(x: -2, y: 4).w - 0.125) < 0.005)
        #expect(s.rgba(x: -1, y: 4) == .zero, "outside the selection")
        #expect(s.rgba(x: -4, y: 4) == .zero, "outside the region")
    }
}
