// Port of photocraft-engine (crates/engine/src/sample_cmds.rs tests), MIT OR Apache-2.0, © ArtCraft Team and the PhotoCraft contributors.

import PCDocument
@testable import PCEngine
import PCFoundation
import Testing

@Suite struct SampleTests {
    typealias S = SampleCommands

    /// A `w`×`h` document of `mode`/`depth` whose background is `px(x, y)` (RGBA, converted to the
    /// document's channels).
    func doc(_ w: Int, _ h: Int, _ mode: ColorMode, _ depth: SampleType, _ px: (Int32, Int32) -> SIMD4<Float>) -> Document {
        // The managed CMYK conversion every Session installs (photocraft's is always on): set up
        // before any pixel is converted, whichever suite runs first.
        ColorSetup.ensureInstalled()
        var d = Document(name: "t", size: PixelSize(width: w, height: h), mode: mode, depth: depth)
        var bg = Layer.raster("Background", format: d.pixelFormat)
        _ = bg.withRaster { s in
            let fmt = s.format
            for y in 0..<Int32(h) { for x in 0..<Int32(w) { s.setPixel(x: x, y: y, fmt.components(fromRGBA: px(x, y))) } }
        }
        d.layers.append(bg)
        return d
    }

    func close(_ a: SIMD4<Float>, _ b: SIMD4<Float>, _ tol: Float) -> Bool {
        let d = a - b
        return abs(d.x) <= tol && abs(d.y) <= tol && abs(d.z) <= tol && abs(d.w) <= tol
    }

    @Test func sampleRectCentresTheSquareAndClipsToTheCanvas() {
        let canvas = PixelRect(x0: 0, y0: 0, x1: 20, y1: 10)
        #expect(S.sampleRect(5.5, 5.5, 1, canvas) == PixelRect(x0: 5, y0: 5, x1: 6, y1: 6))
        #expect(S.sampleRect(5.9, 5.1, 3, canvas) == PixelRect(x0: 4, y0: 4, x1: 7, y1: 7))
        #expect(S.sampleRect(10, 5, 5, canvas) == PixelRect(x0: 8, y0: 3, x1: 13, y1: 8))
        // Corners and edges: the square is clipped.
        #expect(S.sampleRect(0, 0, 5, canvas) == PixelRect(x0: 0, y0: 0, x1: 3, y1: 3))
        #expect(S.sampleRect(19.5, 9.5, 11, canvas) == PixelRect(x0: 14, y0: 4, x1: 20, y1: 10))
        #expect(S.sampleRect(10, 5, 101, canvas) == canvas)
        // Off the canvas, non-finite, or not a Photoshop size: nothing.
        #expect(S.sampleRect(-0.5, 3, 3, canvas) == nil)
        #expect(S.sampleRect(20, 3, 3, canvas) == nil)
        #expect(S.sampleRect(.nan, 3, 3, canvas) == nil)
        #expect(S.sampleRect(1e300, 3, 3, canvas) == nil)
        #expect(S.sampleRect(3, 3, 4, canvas) == nil)
        #expect(S.sampleRect(3, 3, 0, canvas) == nil)
        // At the Int32 limits the square saturates rather than overflowing.
        let huge = PixelRect(x0: .max - 4, y0: .max - 4, x1: .max, y1: .max)
        #expect(S.sampleRect(Double(Int32.max - 1), Double(Int32.max - 1), 101, huge) == huge)
    }

    @Test func averageWeightsByAlphaAndIgnoresGarbage() {
        let px: [SIMD4<Float>] = [SIMD4(1, 0, 0, 1), SIMD4(0, 0, 1, 1), SIMD4(0, 1, 0, 0), SIMD4(.nan, 0, 0, 1)]
        let a = S.average(px, .rgb, .f32)
        #expect(close(a, SIMD4(0.5, 0, 0.5, 0.5), 1e-6), "\(a)")
        // Half-transparent red next to opaque blue: red counts half.
        let b = S.average([SIMD4(1, 0, 0, 0.5), SIMD4(0, 0, 1, 1)], .rgb, .f32)
        #expect(close(b, SIMD4(1.0 / 3, 0, 2.0 / 3, 0.75), 1e-6), "\(b)")
        #expect(S.average([], .rgb, .u8) == .zero)
        #expect(S.average([SIMD4(0.3, 0.3, 0.3, 0)], .rgb, .u8) == .zero)
    }

    @Test func averageRoundsToTheDocumentDepth() {
        // 0, 0.1, 1 averages to 0.3667: 94/255 at 8 bit, 24030/65535 at 16 bit, the float at 32.
        let px: [SIMD4<Float>] = [SIMD4(0, 0, 0, 1), SIMD4(0.1, 0.1, 0.1, 1), SIMD4(1, 1, 1, 1)]
        let a8 = S.average(px, .rgb, .u8)
        #expect(a8.x == 94.0 / 255)
        let a16 = S.average(px, .rgb, .u16)
        #expect(a16.x == 24030.0 / 65535)
        let a32 = S.average(px, .rgb, .f32)
        #expect(abs(a32.x - 1.1 / 3) < 1e-6)
        #expect(a8.x != a32.x && a16.x != a32.x)
    }

    @Test func averageIsTakenInTheDocumentColourModel() {
        // The managed CMYK conversion a Session installs (photocraft's is always on).
        ColorSetup.ensureInstalled()
        // Gray: the mean of the gray values.
        let g = S.average([SIMD4(0.2, 0.2, 0.2, 1), SIMD4(0.6, 0.6, 0.6, 1)], .grayscale, .f32)
        #expect(close(g, SIMD4(0.4, 0.4, 0.4, 1), 1e-5), "\(g)")
        // CMYK and Lab: the mean of the CMYK / Lab values, not of the RGB ones.
        let (red, blue) = (SIMD4<Float>(1, 0, 0, 1), SIMD4<Float>(0, 0, 1, 1))
        for mode in [ColorMode.cmyk, .lab] {
            let fmt = PixelFormat(mode: mode, sample: .f32, alpha: false)
            let (r, b) = (fmt.components(fromRGBA: red), fmt.components(fromRGBA: blue))
            let mean = zip(r, b).map { ($0 + $1) / 2 }
            let want = PixelCodec.toRGBA(fmt, mean)
            let got = S.average([red, blue], mode, .f32)
            #expect(close(got, want, 1e-5), "\(mode): \(got) vs \(want)")
            #expect(!close(got, SIMD4(0.5, 0, 0.5, 1), 0.02), "\(mode) averaged in RGB: \(got)")
        }
    }

    @Test func averagesUseTheDocumentModelExceptCMYK() {
        func model(_ mode: ColorMode) -> ColorMode { S.averagingModel(Document(name: "m", size: PixelSize(width: 1, height: 1), mode: mode, depth: .u8)) }
        #expect(model(.rgb) == .rgb)
        #expect(model(.grayscale) == .grayscale)
        #expect(model(.lab) == .lab)
        #expect(model(.bitmap) == .grayscale)
        #expect(model(.cmyk) == .rgb)
    }

    /// A 9×9 document: white, except a black 3×3 block at (0..3, 0..3).
    func block(_ mode: ColorMode, _ depth: SampleType) -> Document {
        doc(9, 9, mode, depth) { x, y in x < 3 && y < 3 ? SIMD4(0, 0, 0, 1) : SIMD4(1, 1, 1, 1) }
    }

    @Test func sampleSizesAverageTheSquareAroundThePixelAtEveryDepthAndMode() {
        for mode in [ColorMode.rgb, .grayscale, .cmyk, .lab] {
            for depth in SampleType.allCases {
                let d = block(mode, depth)
                let tol: Float = depth == .u8 ? 1.5 / 255 : 2e-3
                // Point Sample: the composite pixel itself (black, as the document shows it).
                let p = S.sampleColor(d, nil, 1.5, 1.5, 1, .all)
                let white = S.sampleColor(d, nil, 7, 7, 1, .all)
                #expect(p.x < 0.05 && p.w == 1, "\(mode) \(depth) point \(p)")
                // 3×3 at (3, 3): one black pixel of nine. Gray, RGB: 8/9 white.
                let s = S.sampleColor(d, nil, 3.5, 3.5, 3, .all)
                let want = S.sampleColor(d, nil, 3.5, 3.5, 1, .all)
                #expect(s.x < want.x && s.w == 1, "\(mode) \(depth) 3x3 \(s)")
                if mode == .rgb || mode == .grayscale {
                    #expect(close(s, SIMD4(8.0 / 9, 8.0 / 9, 8.0 / 9, 1), tol), "\(mode) \(depth) 3x3 \(s)")
                }
                // 5×5 at the corner: clipped to 3×3, all black.
                let c = S.sampleColor(d, nil, 0, 0, 5, .all)
                #expect(close(c, p, tol), "\(mode) \(depth) corner \(c) vs \(p)")
                // 101×101 covers the canvas: 9 of 81 black.
                if mode == .rgb || mode == .grayscale {
                    let w = S.sampleColor(d, nil, 4, 4, 101, .all)
                    #expect(close(w, SIMD4(72.0 / 81, 72.0 / 81, 72.0 / 81, 1), tol), "\(mode) \(depth) 101 \(w)")
                }
                // A uniform area averages to its own colour (round trips through the model).
                let u = S.sampleColor(d, nil, 7, 7, 3, .all)
                #expect(close(u, white, tol), "\(mode) \(depth) uniform \(u) vs \(white)")
                // Off the canvas: nothing.
                #expect(S.sampleColor(d, nil, -1, 4, 11, .all) == .zero)
            }
        }
    }

    @Test func currentAndBelowKeepsAnActiveGroupsContents() {
        // A white background and a group holding a red layer; the group is the active layer.
        var d = doc(3, 3, .rgb, .u8) { _, _ in SIMD4(1, 1, 1, 1) }
        var red = Layer.raster("red", format: d.pixelFormat)
        _ = red.withRaster { $0.fill(PixelRect(x0: 0, y0: 0, x1: 3, y1: 3), with: [1, 0, 0, 1]) }
        let group = Layer.group("group", [red])
        let gid = group.id
        d.layers.append(group)
        for which in [S.SampleLayers.currentAndBelow, .currentAndBelowNoAdjustments] {
            let c = S.sampleColor(d, gid, 1.5, 1.5, 1, which)
            #expect(close(c, SIMD4(1, 0, 0, 1), 1.5 / 255), "\(which): \(c)")
        }
    }

    @Test func sampleLayersChooseWhatIsAveraged() {
        // Background white; a red 3x3 layer in the middle; an Invert adjustment on top.
        var d = doc(9, 9, .rgb, .u8) { _, _ in SIMD4(1, 1, 1, 1) }
        let bg = d.layers[0].id
        var redL = Layer.raster("red", format: d.pixelFormat)
        _ = redL.withRaster { $0.fill(PixelRect(x0: 3, y0: 3, x1: 6, y1: 6), with: [1, 0, 0, 1]) }
        let red = d.insertAbove(bg, redL)
        let inv = d.insertAbove(red, Layer(name: "invert", content: .adjustment(.invert)))
        func s(_ d: Document, _ active: LayerId?, _ which: S.SampleLayers) -> SIMD4<Float> { S.sampleColor(d, active, 4.5, 4.5, 5, which) }
        func close8(_ a: SIMD4<Float>, _ b: SIMD4<Float>) -> Bool { close(a, b, 1.5 / 255) }
        // Current Layer = the red layer alone: red, 9/25 covered.
        let cur = s(d, red, .current)
        #expect(close8(cur, SIMD4(1, 0, 0, 9.0 / 25)), "\(cur)")
        // Current & Below: red over white, not inverted.
        let below = s(d, red, .currentAndBelow)
        #expect(close8(below, SIMD4(1, 16.0 / 25, 16.0 / 25, 1)), "\(below)")
        // All Layers: inverted (cyan over black).
        let all = s(d, red, .all)
        #expect(close8(all, SIMD4(0, 9.0 / 25, 9.0 / 25, 1)), "\(all)")
        // No Adjustments: as if the Invert were hidden.
        #expect(close8(s(d, red, .allNoAdjustments), below))
        #expect(close8(s(d, inv, .currentAndBelowNoAdjustments), below))
        #expect(close8(s(d, inv, .currentAndBelow), all))
        // Current Layer with an adjustment layer or no active layer: nothing to sample.
        #expect(s(d, inv, .current) == .zero)
        #expect(s(d, nil, .current) == .zero)
        #expect(s(d, nil, .currentAndBelow) == .zero)
        // Current Layer ignores how the composite shows the layer: hidden, 50% opacity, Multiply.
        _ = d.updateLayer(red) { l in
            l.visible = false
            l.opacity = 0.5
            l.blend = .multiply
        }
        #expect(close8(s(d, red, .current), cur))
    }

    @Test func theCommandValidatesItsParams() throws {
        let s = Session()
        #expect(throws: EngineError.self, "no document") { try s.execute("document.sampleColor", ["x": 1, "y": 1]) }
        try s.execute("file.new", ["width": 8, "height": 8, "background": "white"])
        #expect(try s.execute("document.sampleColor", ["x": 4, "y": 4, "size": 3]) == [1, 1, 1, 1])
        #expect(try s.execute("document.sampleColor", ["x": 4, "y": 4, "size": "point", "sampleLayer": "current"]) == [1, 1, 1, 1])
        #expect(try s.execute("document.sampleColor", ["x": -40, "y": 4, "size": 101]) == [0, 0, 0, 0])
        let bads: [JSONValue] = [
            [:], ["x": 1], ["x": "a", "y": 1], ["x": 1, "y": 1, "size": 4], ["x": 1, "y": 1, "size": -3], ["x": 1, "y": 1, "size": "huge"],
            ["x": 1, "y": 1, "size": 1e40], ["x": 1, "y": 1, "sampleLayer": "below"], ["x": 1, "y": 1, "sampleLayer": 3], [1, 2],
        ]
        for bad in bads {
            do {
                try s.execute("document.sampleColor", bad)
                Issue.record("\(bad): expected an error")
            } catch EngineError.badParams {
            } catch {
                Issue.record("\(bad): \(error)")
            }
        }
    }
}
