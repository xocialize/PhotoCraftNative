// Port of photocraft-engine (crates/engine/src/mode_cmds/tests.rs), MIT OR Apache-2.0, © ArtCraft Team and the PhotoCraft contributors.
//
// Every photocraft test is ported.

import Foundation
import PCDocument
@testable import PCEngine
import PCFormat
import PCFoundation
import PCPlatform
import Testing

@Suite struct ModeCommandsTests {
    func session(_ w: Int, _ h: Int, _ depth: Int, _ mode: String) throws -> Session {
        let s = Session()
        try s.execute("file.new", ["width": .int(w), "height": .int(h), "depth": .int(depth), "mode": .string(mode)])
        try paint(s) { x, y in SIMD4(Float(x) / Float(w), Float(y) / Float(h), 0.5, 1) }
        return s
    }

    func paint(_ s: Session, _ f: (Int32, Int32) -> SIMD4<Float>) throws {
        try s.edit("setup") { doc, active in
            let b = doc.bounds
            var px: [SIMD4<Float>] = []
            for y in b.y0..<b.y1 { for x in b.x0..<b.x1 { px.append(f(x, y)) } }
            doc.withRaster(of: active!) { $0.writeRGBA(b, px) }
        }
    }

    func doc(_ s: Session) -> Document { s.active!.doc }

    func colours(_ d: Document) -> Set<[UInt8]> {
        let surf = d.layers[0].surface!
        var set = Set<[UInt8]>()
        for y in 0..<Int32(d.size.height) {
            for x in 0..<Int32(d.size.width) {
                let c = surf.rgba(x: x, y: y)
                if c.w > 0 { set.insert([c.x, c.y, c.z].map { UInt8(($0 * 255).rounded()) }) }
            }
        }
        return set
    }

    func pixel(_ s: Session, _ x: Int, _ y: Int) throws -> [Float] {
        try s.execute("document.pixel", ["x": .int(x), "y": .int(y)]).arrayValue!.map { $0.floatValue! }
    }

    @Test func rotateArbitraryGrowsCanvasAndKeepsBackground() throws {
        for depth in [8, 16, 32] {
            let s = try session(40, 20, depth, "rgb")
            try s.execute("layer.new.layer")
            try paint(s) { x, y in (15..<25).contains(x) && (5..<15).contains(y) ? SIMD4(1, 0, 0, 1) : .zero }
            try s.execute("tools.setColors", ["background": "#00ff00"])
            let r = try s.execute("image.rotation.arbitrary", ["angle": 90, "direction": "cw"])
            #expect(r["width"] == 20 && r["height"] == 40, "\(r)")
            var d = doc(s)
            #expect(d.layers[0].name == "Background")
            // The red square stays centred.
            #expect(d.layers[1].surface!.rgba(x: 10, y: 20).x > 0.9, "\(depth)")
            try s.execute("edit.undo")
            try s.execute("image.rotation.arbitrary", ["angle": 30, "direction": "ccw"])
            d = doc(s)
            #expect(d.size == ModeCommands.rotatedSize(PixelSize(width: 40, height: 20), 30))
            #expect(d.size.width > 40 && d.size.height > 20)
            // Exposed corners take the background colour on the Background layer.
            let corner = d.layers[0].surface!.rgba(x: 0, y: 0)
            #expect(corner.y > 0.9 && corner.x < 0.1, "\(corner)")
        }
        let s = try session(10, 10, 8, "rgb")
        #expect(throws: EngineError.self) { try s.execute("image.rotation.arbitrary", ["angle": 10, "direction": "up"]) }
        let n = s.active!.history.pastCount
        try s.execute("image.rotation.arbitrary", ["angle": 360])
        #expect(s.active!.history.pastCount == n, "a full turn changes nothing")
    }

    @Test func rotateArbitraryOtherModes() throws {
        for mode in ["gray", "cmyk", "lab"] {
            let s = try session(16, 12, 16, mode)
            try s.execute("image.rotation.arbitrary", ["angle": 45])
            #expect(doc(s).size == ModeCommands.rotatedSize(PixelSize(width: 16, height: 12), 45), "\(mode)")
        }
    }

    @Test func rotateArbitraryRotatesGroupedLockedChildrenAndPreservesLock() throws {
        let s = Session()
        try s.execute("file.new", ["width": 16, "height": 16, "background": "white"])
        try s.execute("layer.new.layer", ["name": "Paint"])
        try s.execute("edit.fill", ["color": "#0000ff"])
        try s.execute("layer.setProps", ["locks": ["position": true]])
        try s.execute("layer.groupLayers")

        // 1. 30 degree rotation succeeds and canvas grows to 22x22.
        let r30 = try s.execute("image.rotation.arbitrary", ["angle": 30, "interpolation": "nearest"])
        #expect(r30["width"] == 22 && r30["height"] == 22, "\(r30)")

        // 2. Child remains position-locked after canvas rotation.
        let d = doc(s)
        let group = d.layers[1]
        let children = try #require(group.children)
        #expect(children.count == 1)
        let child = children[0]
        #expect(child.name == "Paint")
        #expect(child.locks.position, "position lock must be preserved on child")

        // 3. Free Transform of the child alone still refuses with lock error.
        try s.execute("layer.select", ["layer": .id(child.id)])
        do {
            try s.execute("edit.transform", ["matrix": [1, 0, 0, 1, 0, 0]])
            Issue.record("child Free Transform must remain refused")
        } catch {
            #expect("\(error)".contains("locked"), "child Free Transform must remain refused: \(error)")
        }

        // 4. Undo restores 16x16 size.
        try s.execute("edit.undo")
        #expect(doc(s).size == PixelSize(width: 16, height: 16))

        // 5. 90 degree rotation also succeeds and the composite matches the dedicated 90° cw turn.
        let r90 = try s.execute("image.rotation.arbitrary", ["angle": 90, "direction": "cw", "interpolation": "nearest"])
        #expect(r90["width"] == 16 && r90["height"] == 16)
        let arb = doc(s)
        try s.execute("edit.undo")
        try s.execute("image.imageRotation.90cw")
        let a = try s.services.renderer.render(arb, region: arb.bounds).px
        let b = try s.services.renderer.render(doc(s), region: doc(s).bounds).px
        #expect(a == b)
    }

    @Test func flattenedModePixelsMatchTheAllocatingConversionAtEveryChannelCount() {
        let px: [SIMD4<Float>] = [SIMD4(0, 0.25, 0.75, 0), SIMD4(0.9, 0.3, 0.2, 0.2), SIMD4(0.1, 0.7, 0.4, 0.7), SIMD4(repeating: 1)]
        for mode in [ColorMode.indexed, .bitmap, .duotone] {
            var document = Document.withBackground(name: "mode", size: PixelSize(width: 2, height: 2), mode: .rgb, depth: .f32, fill: .white)
            var active: LayerId?
            ModeCommands.singleLayer(&document, &active, mode, px, "result", background: false)
            let fmt = document.pixelFormat
            var expected = Surface(format: fmt)
            expected.writeRegion(document.bounds, px.flatMap { fmt.components(fromRGBA: $0) })
            let actual = document.layers[0].surface!
            #expect(actual.readInterleaved(document.bounds) == expected.readInterleaved(document.bounds), "\(mode)")
            #expect(document.depth == .u8)
            #expect(active == document.layers[0].id)
        }
    }

    @Test func modesRoundTripThroughPcraft() throws {
        let s = try session(12, 12, 8, "rgb")
        try s.execute("image.mode.indexedColor", ["colors": 6])
        let back = try PcraftFormat.load(try PcraftFormat.save(doc(s)))
        #expect(back.colorTable == doc(s).colorTable)
        #expect(back.mode == .indexed)
    }

    @Test func indexedColorRejectsInvalidCountsWithoutEditingTheDocument() throws {
        let s = try session(12, 12, 16, "rgb")
        let before = s.active!.history.pastCount
        for colors: JSONValue in [16.5, 0, 1, 257, 512, -2, "16", .null, true, [], 1e100] {
            #expect(throws: EngineError.self, "\(colors)") { try s.execute("image.mode.indexedColor", ["colors": colors]) }
            #expect(s.active!.history.pastCount == before)
            #expect(doc(s).mode == .rgb && doc(s).depth == .u16)
        }
        try s.execute("image.mode.indexedColor", ["colors": 17.0])
        #expect(doc(s).colorTable!.colors.count <= 17)
    }

    @Test func indexedColorPalettesAndDithers() throws {
        for palette in ["selective", "perceptual", "adaptive", "web", "uniform", "systemMac", "systemWindows"] {
            for dither in ["none", "diffusion", "pattern", "noise"] {
                let s = try session(24, 16, 16, "rgb")
                let r = try s.execute("image.mode.indexedColor", ["palette": .string(palette), "colors": 16, "dither": .string(dither), "forced": "none"])
                let d = doc(s)
                #expect(d.mode == .indexed && d.depth == .u8, "\(palette) \(dither)")
                let table = d.colorTable!
                #expect(r["colors"] == .int(table.colors.count))
                let entries = Set(table.colors.map { [$0.x, $0.y, $0.z] })
                #expect(colours(d).isSubset(of: entries), "\(palette) \(dither): pixels off the table")
                if !["web", "systemMac", "systemWindows"].contains(palette) { #expect(table.colors.count <= 16, "\(palette): \(table.colors.count)") }
            }
        }
    }

    @Test func indexedExactTransparencyAndSources() throws {
        let s = Session()
        try s.execute("file.new", ["width": 8, "height": 8, "background": "transparent"])
        try paint(s) { x, _ in x < 3 ? SIMD4(1, 0, 0, 1) : (x < 6 ? SIMD4(0, 0, 1, 1) : .zero) }
        try s.execute("image.mode.indexedColor", ["palette": "exact", "forced": "none"])
        let d = doc(s)
        let t = d.colorTable!
        #expect(t.colors.count == 3)
        #expect(t.transparent == 2)
        #expect(d.layers[0].name == "Index")
        #expect(d.layers[0].surface!.rgba(x: 7, y: 0).w == 0)
        // Exact fails on a gradient.
        let g = try session(64, 64, 8, "rgb")
        #expect(throws: EngineError.self) { try g.execute("image.mode.indexedColor", ["palette": "exact"]) }
        // Gray, CMYK and Lab sources flatten through the composite.
        var last: Session?
        for mode in ["gray", "cmyk", "lab"] {
            let m = try session(12, 12, 16, mode)
            try m.execute("image.mode.indexedColor", ["colors": 8])
            #expect(doc(m).mode == .indexed, "\(mode)")
            last = m
        }
        // Back to RGB drops the table.
        let l = try #require(last)
        try l.execute("image.mode.indexedColor", ["colors": 8])
        try l.execute("image.mode.rgb")
        #expect(doc(l).colorTable == nil)
        try l.execute("edit.undo")
        #expect(doc(l).colorTable != nil)
    }

    @Test func colorTablePresetsAndEntries() throws {
        let s = try session(16, 16, 8, "rgb")
        #expect(!s.isEnabled("image.mode.colorTable"))
        try s.execute("image.mode.indexedColor", ["palette": "uniform", "colors": 8, "dither": "none", "forced": "none"])
        let before = doc(s).colorTable!
        // No changes: a report, no history step.
        let n = s.active!.history.pastCount
        let r = try s.execute("image.mode.colorTable")
        #expect(r["colors"]?.arrayValue?.count == before.colors.count)
        #expect(s.active!.history.pastCount == n)
        // Replace entry i0: pixels of that index change colour.
        let px0 = doc(s).layers[0].surface!.rgba(x: 0, y: 0)
        let i0 = before.nearest(SIMD3(px0.x, px0.y, px0.z))
        try s.execute("image.mode.colorTable", ["entries": .object(["\(i0)": "#ff00ff"])])
        #expect(doc(s).layers[0].surface!.rgba(x: 0, y: 0) == SIMD4(1, 0, 1, 1))
        try s.execute("image.mode.colorTable", ["table": "blackBody"])
        #expect(doc(s).colorTable!.colors.count == 256)
        try s.execute("image.mode.colorTable", ["transparent": 0])
        #expect(throws: EngineError.self) { try s.execute("image.mode.colorTable", ["table": "nope"]) }
        #expect(throws: EngineError.self) { try s.execute("image.mode.colorTable", ["entries": ["999": "#000000"]]) }
    }

    @Test func clearingColorTableTransparencyRestoresIndexedPixels() throws {
        let s = Session()
        try s.execute("file.new", ["width": 16, "height": 16, "background": "#ff0000"])
        try s.execute("image.mode.indexedColor", ["palette": "exact", "colors": 2, "forced": "none", "dither": "none"])
        #expect(doc(s).colorTable!.colors == [SIMD3(255, 0, 0)])
        #expect(try pixel(s, 5, 8) == [1, 0, 0, 1])
        try s.execute("image.mode.colorTable", ["transparent": 0])
        #expect(try pixel(s, 5, 8) == [0, 0, 0, 0])
        try s.execute("image.mode.colorTable", ["transparent": .null])
        #expect(doc(s).layers[0].surface!.rgba(x: 5, y: 8) == SIMD4(1, 0, 0, 1), "clearing the transparent entry restores the stored pixel")
        #expect(try pixel(s, 5, 8) == [1, 0, 0, 1])
        try s.execute("image.mode.rgb")
        #expect(try pixel(s, 5, 8) == [1, 0, 0, 1])

        let control = Session()
        try control.execute("file.new", ["width": 16, "height": 16, "background": "#ff0000"])
        try control.execute("image.mode.indexedColor", ["palette": "exact", "colors": 2, "forced": "none", "dither": "none"])
        try control.execute("image.mode.colorTable", ["entries": ["0": "#0000ff"]])
        #expect(try pixel(control, 5, 8) == [0, 0, 1, 1])
        try control.execute("image.mode.colorTable", ["transparent": 0])
        try control.execute("edit.undo")
        #expect(try pixel(control, 5, 8) == [0, 0, 1, 1])
    }

    @Test func bitmapMethodsNeedGrayscale() throws {
        let s = try session(32, 32, 16, "rgb")
        #expect(!s.isEnabled("image.mode.bitmap"))
        try s.execute("image.mode.grayscale")
        for method in ["threshold", "pattern", "diffusion", "halftone"] {
            try s.execute("image.mode.bitmap", ["method": .string(method), "frequency": 12, "shape": "diamond"])
            let d = doc(s)
            #expect(d.mode == .bitmap && d.depth == .u8, "\(method)")
            let surf = d.layers[0].surface!
            for y in Int32(0)..<32 { for x in Int32(0)..<32 {
                let v = surf.pixel(x: x, y: y)[0]
                #expect(v == 0 || v == 1, "\(method): \(v)")
            } }
            try s.execute("edit.undo")
        }
        #expect(throws: EngineError.self) { try s.execute("image.mode.bitmap", ["method": "nope"]) }
        // An unlisted halftone shape is a bad-params error, not a silent Round (#507).
        #expect(throws: EngineError.self) { try s.execute("image.mode.bitmap", ["method": "halftone", "shape": "hexagon"]) }
        #expect(doc(s).mode == .grayscale)
        for shape in ["round", "ellipse", "line", "square", "diamond", "cross"] {
            try s.execute("image.mode.bitmap", ["method": "halftone", "shape": .string(shape)])
            try s.execute("edit.undo")
        }
    }

    @Test func duotoneInksAndDisplay() throws {
        let s = try session(16, 8, 8, "gray")
        try paint(s) { x, _ in SIMD4(repeating: min(Float(x) / 15, 1)) }
        #expect(throws: EngineError.self) { try s.execute("image.mode.duotone", ["type": "quintone"]) }
        let r = try s.execute("image.mode.duotone", [
            "type": "duotone",
            "inks": [["name": "Black"], ["name": "Orange", "color": "#ff8000", "curve": [[0, 0], [100, 80]]]],
        ])
        #expect(r["inks"] == ["Black", "Orange"])
        let d = doc(s)
        #expect(d.mode == .duotone)
        #expect(d.duotone!.inks[1].curve.last!.output == 0.8)
        // Display: warm midtones (red > blue) where the gray image is neutral.
        let shown = try #require(ModeCommands.displayDocument(d))
        let px = try s.services.renderer.render(shown, region: PixelRect(x: 8, y: 4, width: 1, height: 1)).px[0]
        #expect(px.x > px.z + 0.05, "\(px)")
        #expect(ModeCommands.displayDocument(Document(name: "x", size: PixelSize(width: 1, height: 1), mode: .grayscale, depth: .u8)) == nil)
        // Tritone defaults and leaving the mode.
        try s.execute("image.mode.duotone", ["type": "tritone"])
        #expect(doc(s).duotone!.inks.count == 3)
        try s.execute("image.mode.grayscale")
        #expect(doc(s).duotone == nil)
        #expect(doc(s).mode == .grayscale)
        #expect(!(try session(4, 4, 8, "rgb")).isEnabled("image.mode.duotone"))
    }

    /// Leaving Duotone for a colour mode keeps the printed look (#2383): the converted pixels are
    /// the displayed ink colours, through the destination profile. Grayscale drops the inks.
    @Test func duotoneToColourModesKeepsTheInkColours() throws {
        let configs: [JSONValue] = [
            ["type": "duotone"],
            ["type": "monotone", "inks": [["name": "Orange", "color": "#ff8000", "curve": [[0, 0], [100, 100]]]]],
            ["type": "quadtone"],
        ]
        for depth in [8, 16, 32] {
            for cfg in configs {
                for mode in ["rgb", "cmyk", "lab", "grayscale"] {
                    let ctx = "\(depth)-bit \(cfg) → \(mode)"
                    let s = try session(16, 2, depth, "gray")
                    // photocraft's default working gray (sGray; see the report on Preferences' default).
                    try s.execute("edit.colorSettings", ["workingGray": "sgray"])
                    try paint(s) { x, _ in let v = Float(x) / 15; return SIMD4(v, v, v, 1) }
                    try s.execute("image.mode.duotone", cfg)
                    let before = doc(s)
                    let gray = (Int32(0)..<16).map { before.layers[0].surface!.pixel(x: $0, y: 1)[0] }
                    let shown = try s.services.renderer.render(ModeCommands.displayDocument(before)!, region: PixelRect(x: 0, y: 1, width: 16, height: 1)).px
                    try s.execute("image.mode.\(mode)")
                    let d = doc(s)
                    #expect(d.duotone == nil, "\(ctx)")
                    let target: ColorMode = ["rgb": .rgb, "cmyk": .cmyk, "lab": .lab][mode] ?? .grayscale
                    #expect(d.mode == target, "\(ctx)")
                    let t = try ColorTransform(source: BuiltinProfile.srgb.profile, destination: ColorCommands.workingProfile(target),
                                               options: TransformOptions(intent: .relativeColorimetric, blackPointCompensation: true))
                    let surf = d.layers[0].surface!
                    for x in 0..<16 {
                        let got = surf.pixel(x: Int32(x), y: 1)
                        let want: [Float] = target == .grayscale ? [gray[x]] : Array(ColorCommands.evalColor(t, [shown[x].x, shown[x].y, shown[x].z]).prefix(target.colorChannels))
                        // The display's gradient map samples the inks at 33 stops; dark CMYK separations
                        // magnify that a little.
                        let tol: Float = target == .cmyk ? 0.03 : 0.02
                        for (g, w) in zip(got, want) { #expect(abs(g - w) < tol, "\(ctx) x=\(x): got \(got), want \(want)") }
                    }
                    // Undo brings back the inks and the gray pixels.
                    try s.execute("edit.undo")
                    let back = doc(s)
                    #expect(back.mode == .duotone && back.duotone == before.duotone, "\(ctx)")
                    #expect(back.layers[0].surface!.pixel(x: 7, y: 1) == before.layers[0].surface!.pixel(x: 7, y: 1), "\(ctx)")
                }
            }
        }
    }

    /// Colours stored in a Duotone document (fill layers) take the ink colours too.
    @Test func duotoneToRGBInksFillLayerColours() throws {
        let s = try session(4, 4, 8, "gray")
        try s.execute("image.mode.duotone", ["type": "monotone", "inks": [["name": "Orange", "color": "#ff8000"]]])
        try s.execute("layer.newFillLayer.solidColor", ["color": "#808080"])
        try s.execute("image.mode.rgb")
        guard case .fill(.solid(let c))? = doc(s).layers.last?.content else { Issue.record("no fill layer"); return }
        #expect(c.mode == .rgb)
        // Gray 0.5 is half-density orange: (1, 0.75, 0.5).
        for (g, w) in zip([c.c.x, c.c.y, c.c.z], [Float(1), 0.75, 0.5]) { #expect(abs(g - w) < 0.02, "\(c)") }
    }

    @Test func quantizeHelpersMatchPhotocraft() {
        typealias Q = ModeCommands.Quantize
        #expect(Q.webPalette().count == 216)
        #expect(Q.macPalette().count == 256)
        #expect(Q.windowsPalette().count == 256)
        #expect(Q.uniformPalette(8).count == 8 && Q.uniformPalette(27).count == 27 && Q.uniformPalette(16).count == 8)
        // The Bayer matrix is balanced around zero.
        let sum = (0..<8).flatMap { y in (0..<8).map { Q.bayer8($0, y) } }.reduce(0, +)
        #expect(abs(sum) < 1e-5)
        // Exact nearest search, ties to the lowest index.
        #expect(Q.nearest([SIMD3(0, 0, 0), SIMD3(2, 0, 0), SIMD3(2, 0, 0)], SIMD3(1, 0, 0)) == 0)
        #expect(Q.nearest([SIMD3(0, 0, 0), SIMD3(2, 0, 0), SIMD3(2, 0, 0)], SIMD3(1.5, 0, 0)) == 1)
    }
}
