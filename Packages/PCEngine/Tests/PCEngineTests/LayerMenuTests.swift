// Port of photocraft-engine (crates/engine/src/layer_menu_cmds/tests.rs), MIT OR Apache-2.0, © ArtCraft Team and the PhotoCraft contributors.
//
// Effects are added directly (the Layer Style commands photocraft's tests use belong to another
// module); `photocraft_compose::flatten` is the engine renderer's composite.

import Foundation
import PCDocument
@testable import PCEngine
import PCFormat
import PCFoundation
import Testing

@Suite struct LayerMenuTests {
    static let depths = [8, 16, 32]

    func session(_ depth: Int, _ mode: String) throws -> Session {
        let s = Session()
        try s.execute("file.new", ["width": 40, "height": 30, "depth": .int(depth), "mode": .string(mode), "background": "transparent"])
        return s
    }

    func doc(_ s: Session) throws -> Document { try #require(s.active?.doc) }
    func active(_ s: Session) throws -> Layer {
        let d = try #require(s.active)
        return try #require(d.activeLayer.flatMap { d.doc.layer($0) })
    }

    func paint(_ s: Session, _ f: (Int32, Int32) -> SIMD4<Float>) throws {
        try s.edit("setup") { doc, active in
            let b = doc.bounds
            guard let id = active else { return }
            var px: [SIMD4<Float>] = []
            for y in b.y0..<b.y1 { for x in b.x0..<b.x1 { px.append(f(x, y)) } }
            doc.withRaster(of: id) { surf in
                surf.writeRegion(b, PixelCodec.fromRGBA(surf.format, rgba: px))
                surf.prune()
            }
        }
    }

    /// A red disc with a soft, dark-contaminated edge on transparency.
    static func disc(_ x: Int32, _ y: Int32) -> SIMD4<Float> {
        let d = Float((x - 20) * (x - 20) + (y - 15) * (y - 15)).squareRoot()
        let a = min(max(10 - d, 0), 1)
        // Edge pixels were matted on black: colour scaled by alpha.
        return SIMD4(0.9 * (a < 1 ? a : 1), 0.1 * min(a, 1), 0.1 * min(a, 1), a)
    }

    func selectLeftHalf(_ s: Session) throws {
        try s.edit("sel") { doc, _ in
            var sel = Surface(format: .gray8)
            sel.writeRegion(PixelRect(x0: 0, y0: 0, x1: 20, y1: 30), [Float](repeating: 1, count: 600))
            doc.selection = sel
        }
    }

    func flatten(_ s: Session) throws -> [SIMD4<Float>] {
        let d = try doc(s)
        return try s.services.renderer.render(d, region: d.bounds).px
    }

    func at(_ px: [SIMD4<Float>], _ x: Int, _ y: Int, width: Int = 40) -> SIMD4<Float> { px[y * width + x] }

    func addEffects(_ s: Session, _ fx: [Effect]) throws {
        try s.edit("Layer Style") { doc, active in
            guard let id = active else { return }
            doc.updateLayer(id) { l in
                l.effects.items += fx
                l.effects.enabled = true
            }
        }
    }

    @Test func maskApplyFromTransparencyHideSelection() throws {
        for depth in Self.depths {
            let s = try session(depth, "rgb")
            try paint(s) { _, _ in SIMD4(0.2, 0.4, 0.6, 1) }
            #expect(!s.isEnabled("layer.layerMask.apply"))
            try selectLeftHalf(s)
            try s.execute("layer.layerMask.hideSelection", [:])
            #expect(try doc(s).selection == nil)
            let m = try #require(try active(s).mask)
            #expect(m.value(x: 5, y: 5) == 0 && m.value(x: 30, y: 5) == 1)
            try s.execute("layer.layerMask.apply", [:])
            #expect(try active(s).mask == nil)
            let surf = try #require(try active(s).surface)
            #expect(surf.rgba(x: 5, y: 5).w == 0)
            #expect(surf.rgba(x: 30, y: 5).w == 1)
            // From Transparency: alpha moves into the mask, pixels become opaque.
            try s.execute("layer.layerMask.fromTransparency", [:])
            let l = try active(s)
            #expect(l.mask?.value(x: 5, y: 5) == 0)
            #expect(l.mask?.value(x: 30, y: 5) == 1)
            #expect(l.surface?.rgba(x: 30, y: 5).w == 1)
            // The composite looks the same.
            #expect(try s.services.renderer.render(try doc(s), region: PixelRect(x: 5, y: 5, width: 1, height: 1)).px[0].w == 0)
            try s.execute("edit.undo", [:])
            #expect(try active(s).mask == nil)
        }
    }

    @Test func mattingCommandsFixDarkFringes() throws {
        for depth in Self.depths {
            let s = try session(depth, "rgb")
            try paint(s, Self.disc)
            func rgba(_ x: Int32) throws -> SIMD4<Float> { try #require(try active(s).surface).rgba(x: x, y: 17) }
            var edge: Int32?
            for x in Int32(0)..<40 {
                let a = try rgba(x).w
                if a > 0.05 && a < 0.95 { edge = x; break }
            }
            let ex = try #require(edge, "an antialiased edge pixel")
            let before = try rgba(ex)
            try s.execute("layer.matting.removeBlackMatte", [:])
            let after = try rgba(ex)
            #expect(after.x > before.x + 0.05, "\(depth): \(before) → \(after)")
            #expect(abs(after.w - before.w) < 1e-2, "alpha kept")
            try s.execute("edit.undo", [:])
            try s.execute("layer.matting.defringe", ["width": 2])
            let d = try rgba(ex)
            #expect(d.x > 0.8, "\(depth): defringed edge takes the core red: \(d)")
            try s.execute("edit.undo", [:])
            try s.execute("layer.matting.colorDecontaminate", ["amount": 100])
            let c = try rgba(ex)
            #expect(c.x > before.x, "\(depth): \(before) → \(c)")
            try s.execute("edit.undo", [:])
            try s.execute("layer.matting.removeWhiteMatte", [:])
        }
    }

    @Test func defringePureFunction() {
        // 5×1: transparent, fringe (blue), core red ×3.
        var px: [SIMD4<Float>] = [SIMD4(0, 0, 0, 0), SIMD4(0, 0, 1, 0.5), SIMD4(1, 0, 0, 1), SIMD4(1, 0, 0, 1), SIMD4(1, 0, 0, 1)]
        LayerMenuCommands.Algo.defringe(&px, 5, 1, 1)
        #expect(px[1] == SIMD4(1, 0, 0, 0.5))
        #expect(px[0].w == 0)
    }

    @Test func edtMatchesBruteForce() {
        let (w, h) = (7, 5)
        let inside = (0..<(w * h)).map { ($0 * 7) % 11 == 0 }
        let d = LayerMenuCommands.Algo.edt(inside, w, h)
        for y in 0..<h {
            for x in 0..<w {
                var best = Float.infinity
                for j in 0..<(w * h) where inside[j] {
                    let (dx, dy) = (Float(x - j % w), Float(y - j / w))
                    best = min(best, (dx * dx + dy * dy).squareRoot())
                }
                #expect(abs(d[y * w + x] - best) < 1e-5, "\(x),\(y)")
            }
        }
    }

    @Test func globalLightBlendingOptionsScaleEffects() throws {
        let s = try session(8, "rgb")
        try paint(s, Self.disc)
        try s.execute("layer.layerStyle.globalLight", ["angle": 200, "altitude": 45])
        #expect(try doc(s).globalLight.angle == -160 && doc(s).globalLight.altitude == 45)
        try s.execute("layer.layerStyle.blendingOptions", ["blend": "Multiply", "opacity": 50, "fillOpacity": 25])
        let l = try active(s)
        #expect(l.blend == .multiply && l.opacity == 0.5 && l.fillOpacity == 0.25)
        #expect(throws: EngineError.self) { try s.execute("layer.layerStyle.blendingOptions", ["blend": "nope"]) }
        #expect(throws: EngineError.self) { try s.execute("layer.layerStyle.blendingOptions", ["blend": "Pass Through"]) }
        #expect(!s.isEnabled("layer.layerStyle.scaleEffects"))
        try addEffects(s, [.dropShadow(Shadow(common: FxCommon(.multiply, 0.75), distance: 10, size: 4))])
        try s.execute("layer.layerStyle.scaleEffects", ["scale": 200])
        guard case .dropShadow(let sh)? = try active(s).effects.items.first else {
            Issue.record("expected a drop shadow")
            return
        }
        #expect(sh.distance == 20 && sh.size == 8)
    }

    @Test func blendingOptionsBlendIf() throws {
        for depth in Self.depths {
            let s = try session(depth, "rgb")
            // Black on the left, white on the right.
            try paint(s) { x, _ in x < 20 ? SIMD4(0, 0, 0, 1) : SIMD4(repeating: 1) }
            // Gray › This Layer: black point 50 hides the black half.
            try s.execute("layer.layerStyle.blendingOptions", ["blendIf": ["channel": "gray", "thisLayer": [50, 255]]])
            #expect(at(try flatten(s), 5, 5).w == 0, "depth \(depth)")
            #expect(at(try flatten(s), 30, 5) == SIMD4(repeating: 1), "depth \(depth)")
            let full = BlendRange.full
            #expect(try active(s).blendIf.get(0) == BlendRangePair(BlendRange(black: SIMD2(50, 50), white: SIMD2(255, 255)), full))
            // Setting the other slider pair keeps this one; split points are 4 values.
            try s.execute("layer.layerStyle.blendingOptions", ["blendIf": [
                ["channel": "gray", "underlying": [0, 10, 245, 255]], ["channel": "blue", "thisLayer": [0, 200]],
            ]])
            let bi = try active(s).blendIf
            #expect(bi.get(0).this.black == SIMD2(50, 50))
            #expect(bi.get(0).underlying == BlendRange(black: SIMD2(0, 10), white: SIMD2(245, 255)))
            #expect(bi.get(3).this == BlendRange(black: SIMD2(0, 0), white: SIMD2(200, 200)))
            // Blending options without `blendIf` leave it alone.
            try s.execute("layer.layerStyle.blendingOptions", ["opacity": 90])
            #expect(try !active(s).blendIf.isDefault)
            // One undo step per call.
            try s.execute("edit.undo", [:])
            try s.execute("edit.undo", [:])
            #expect(try active(s).blendIf.get(0).underlying == full)
            #expect(try active(s).blendIf.get(0).this.black == SIMD2(50, 50))
            // null resets everything.
            try s.execute("layer.layerStyle.blendingOptions", ["blendIf": .null])
            #expect(try active(s).blendIf.isDefault)
            #expect(at(try flatten(s), 5, 5) == SIMD4(0, 0, 0, 1))
        }
    }

    @Test func blendIfRejectsBadParams() throws {
        let s = try session(8, "rgb")
        try paint(s, Self.disc)
        let steps = s.active?.history.pastCount
        let bad: [JSONValue] = [
            ["channel": "cyan", "thisLayer": [10, 255]], ["channel": 4, "thisLayer": [10, 255]], ["channel": "gray", "thisLayer": [200, 100]],
            ["channel": "gray", "thisLayer": [0, 300]], ["channel": "gray", "thisLayer": [0, 10, 5, 255]], ["channel": "gray", "underlying": [1, 2, 3]],
            ["channel": "gray", "underlying": "dark"], "gray",
        ]
        for b in bad {
            #expect(throws: EngineError.self, "\(b)") { try s.execute("layer.layerStyle.blendingOptions", ["blendIf": b]) }
        }
        #expect(try active(s).blendIf.isDefault)
        #expect(s.active?.history.pastCount == steps)
    }

    @Test func blendingOptionsAdvancedBlending() throws {
        for depth in Self.depths {
            let s = try session(depth, "rgb")
            try paint(s) { x, _ in x < 20 ? SIMD4(0, 0, 1, 1) : SIMD4(repeating: 0) }
            #expect(try active(s).advanced.isDefault)
            try s.execute("layer.layerStyle.blendingOptions", [
                "knockout": "deep", "fillOpacity": 0, "blendInteriorEffectsAsGroup": true, "blendClippedLayersAsGroup": false,
                "transparencyShapesLayer": false, "layerMaskHidesEffects": true, "vectorMaskHidesEffects": true, "channels": [true, false, true],
            ])
            let l = try active(s)
            #expect(l.advanced == AdvancedBlending(knockout: .deep, blendInterior: true, blendClipped: false, transparencyShapes: false,
                                                   layerMaskHidesEffects: true, vectorMaskHidesEffects: true))
            #expect(l.excludedChannels == 0b010)
            // A deep knockout at fill 0 with no Background reveals transparency where the layer has
            // pixels.
            let p = at(try flatten(s), 5, 5)
            #expect(p.w < 2.0 / 255, "\(depth): \(p)")
            // Omitted keys keep their values; one undo step each.
            try s.execute("layer.layerStyle.blendingOptions", ["knockout": "Shallow"])
            #expect(try active(s).advanced.knockout == .shallow)
            #expect(try !active(s).advanced.blendClipped)
            try s.execute("edit.undo", [:])
            #expect(try active(s).advanced.knockout == .deep)
            try s.execute("edit.undo", [:])
            #expect(try active(s).advanced.isDefault)
            #expect(try active(s).excludedChannels == 0)
        }
    }

    @Test func blendingOptionsAdvancedRejectsBadParams() throws {
        let s = try session(8, "rgb")
        try paint(s) { _, _ in SIMD4(repeating: 1) }
        let steps = s.active?.history.pastCount
        let bad: [JSONValue] = [
            ["knockout": "medium"], ["knockout": 2], ["knockout": true], ["blendInteriorEffectsAsGroup": "yes"], ["blendClippedLayersAsGroup": 1],
            ["transparencyShapesLayer": []], ["layerMaskHidesEffects": [:]], ["vectorMaskHidesEffects": 0.5],
            ["channels": [true, true, true, true, true]], ["channels": [1, 0, 1]], ["channels": "rgb"],
            // A bad key fails the whole call: nothing else is applied.
            ["fillOpacity": 10, "knockout": "nope"],
        ]
        for b in bad {
            #expect(throws: EngineError.self, "\(b)") { try s.execute("layer.layerStyle.blendingOptions", b) }
        }
        #expect(try active(s).advanced.isDefault)
        #expect(try active(s).fillOpacity == 1)
        #expect(s.active?.history.pastCount == steps)
        // `null` keeps the current value.
        try s.execute("layer.layerStyle.blendingOptions", ["knockout": .null, "channels": .null])
        #expect(try active(s).advanced.isDefault)
    }

    @Test func blendIfChannelNamesFollowTheMode() throws {
        let s = try session(8, "cmyk")
        try s.execute("layer.layerStyle.blendingOptions", ["blendIf": ["channel": "black", "underlying": [0, 128]]])
        #expect(try active(s).blendIf.get(4).underlying.white == SIMD2(128, 128))
        #expect(throws: EngineError.self) { try s.execute("layer.layerStyle.blendingOptions", ["blendIf": ["channel": "red", "underlying": [0, 128]]]) }
        // A grayscale document's Gray is its one channel.
        let g = try session(16, "grayscale")
        try g.execute("layer.layerStyle.blendingOptions", ["blendIf": ["channel": "gray", "thisLayer": [30, 255]]])
        #expect(try active(g).blendIf.get(1).this.black == SIMD2(30, 30))
        #expect(try active(g).blendIf.get(0) == .full)
    }

    @Test func createLayerSplitsEffectsAndKeepsTheLook() throws {
        let s = try session(8, "rgb")
        try s.execute("layer.new.layer", [:])
        try paint(s) { x, y in (10..<30).contains(x) && (8..<22).contains(y) ? SIMD4(0.2, 0.5, 0.9, 1) : SIMD4(repeating: 0) }
        try addEffects(s, [
            .dropShadow(Shadow(common: FxCommon(.normal, 0.6), distance: 4, size: 2)),
            .colorOverlay(Effect.ColorOverlay(common: FxCommon(.normal, 0.5), color: .rgb(1, 128.0 / 255, 0))),
        ])
        let id = try active(s).id
        let before = try flatten(s)
        let n0 = try doc(s).layers.count
        let r = try s.execute("layer.layerStyle.createLayer", [:])
        #expect(r["layers"] == 2)
        let d = try doc(s)
        #expect(d.layers.count == n0 + 2)
        let i = try #require(d.layers.firstIndex { $0.id == id })
        #expect(d.layers[i - 1].name.hasSuffix("Drop Shadow") && !d.layers[i - 1].clipped)
        #expect(d.layers[i + 1].name.hasSuffix("Color Overlay") && d.layers[i + 1].clipped)
        #expect(d.layers[i].effects.items.isEmpty)
        let after = try flatten(s)
        let worst = zip(before, after).map { a, b in (0..<4).map { abs(a[$0] - b[$0]) }.max() ?? 0 }.max() ?? 0
        #expect(worst < 3.0 / 255, "composite changed by \(worst * 255)")
        #expect(!s.isEnabled("layer.layerStyle.createLayer"))
        try s.execute("edit.undo", [:])
        #expect(try doc(s).layers.count == n0)
    }

    @Test func contentOptionsReportsTheEditor() throws {
        let s = try session(8, "rgb")
        #expect(!s.isEnabled("layer.layerContentOptions"))
        try s.edit("New Levels Layer") { doc, active in
            active = doc.insertAbove(active, Layer(name: "Levels 1", content: .adjustment(.levels(Adjustment.Levels()))))
        }
        #expect(try s.execute("layer.layerContentOptions", [:])["editor"] == "adjustment:levels")
        try s.execute("layer.newFillLayer.solidColor", [:])
        #expect(try s.execute("layer.layerContentOptions", [:])["editor"] == "fill")
    }

    @Test func exportLayerTrimsToItsPixels() throws {
        let s = try session(16, "rgb")
        try paint(s) { x, y in (5..<15).contains(x) && (4..<10).contains(y) ? SIMD4(1, 0, 0, 1) : SIMD4(repeating: 0) }
        let d = try LayerMenuCommands.layerDocument(try doc(s), try active(s).id)
        #expect(d.size.width == 10 && d.size.height == 6)
        #expect(d.layers.first?.surface?.rgba(x: 0, y: 0) == SIMD4(1, 0, 0, 1))
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("pc-layer-export-\(ProcessInfo.processInfo.processIdentifier)-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let png = dir.appendingPathComponent("layer.png").path
        let r = try s.execute("layer.quickExportAsPng", ["path": .string(png)])
        #expect(r["width"] == 10 && r["height"] == 6)
        let bytes = try Data(contentsOf: URL(fileURLWithPath: png))
        #expect(Array(bytes.prefix(4)) == [0x89, 0x50, 0x4E, 0x47])
        let jpg = dir.appendingPathComponent("layer.jpg").path
        #expect(try s.execute("layer.exportAs", ["path": .string(jpg)])["width"] == 10)
        // Scaling runs Image › Image Size, which waits on PCAlgo's resampler in this build.
        if s.registry.spec("image.imageSize")?.isAvailable == true {
            #expect(try s.execute("layer.exportAs", ["path": .string(jpg), "scale": 200])["width"] == 20)
        } else {
            #expect(throws: EngineError.self) { try s.execute("layer.exportAs", ["path": .string(jpg), "scale": 200]) }
        }
        #expect(throws: EngineError.self) { try s.execute("layer.quickExportAsPng", ["path": .string(jpg)]) }
        #expect(throws: EngineError.self) { try s.execute("layer.exportAs", [:]) }
    }

    @Test func revealInFinderDryRunAndEnabled() throws {
        let s = try session(8, "rgb")
        #expect(!s.isEnabled("layer.smartObjects.revealInFinder"))
        try s.edit("linked") { doc, active in
            let l = Layer(name: "linked", content: .smart(SmartObject(source: .linked(path: "/tmp/pics/a.png"), transform: .identity, cache: nil)))
            active = doc.insertAbove(active, l)
        }
        #expect(s.isEnabled("layer.smartObjects.revealInFinder"))
        let r = try s.execute("layer.smartObjects.revealInFinder", ["dryRun": true])
        let (prog, args) = LayerMenuCommands.revealCommand("/tmp/pics/a.png")
        #expect(r["program"] == .string(prog))
        #expect(r["args"] == .strings(args))
    }

    @Test func layerMasksInGrayCmykLab() throws {
        for mode in ["gray", "cmyk", "lab"] {
            let s = try session(16, mode)
            try paint(s, Self.disc)
            try s.execute("layer.layerMask.fromTransparency", [:])
            try s.execute("layer.layerMask.apply", [:])
            try s.execute("layer.matting.defringe", ["width": 1])
            try s.execute("layer.matting.removeBlackMatte", [:])
            #expect(try #require(try active(s).surface).rgba(x: 20, y: 15).w > 0.99, "\(mode)")
        }
    }

    @Test func transferEffectsMovesOrCopiesBetweenLayers() throws {
        let s = try session(8, "rgb")
        func newLayer() throws -> LayerId {
            try s.execute("layer.new.layer", [:])
            return try active(s).id
        }
        func layer(_ id: LayerId) throws -> Layer { try #require(try doc(s).layer(id)) }
        func labels(_ l: Layer) -> [String] { l.effects.items.map(\.label) }
        let a = try newLayer()
        try addEffects(s, [Effect.defaultDropShadow(), .colorOverlay(Effect.ColorOverlay(common: FxCommon(.normal, 1), color: .rgb(1, 0.5, 0)))])
        let b = try newLayer()
        let both = labels(try layer(a))
        #expect(both.count == 2)
        // Alt-drag of the whole fx row copies: both layers have the style.
        try s.execute("layer.layerStyle.transferEffects", ["from": .id(a), "to": .id(b), "copy": true])
        #expect(labels(try layer(a)) == both)
        #expect(labels(try layer(b)) == both)
        // Dragging one effect row moves just that effect.
        let c = try newLayer()
        try s.execute("layer.layerStyle.transferEffects", ["from": .id(a), "to": .id(c), "effect": 1])
        #expect(labels(try layer(a)) == Array(both[..<1]))
        #expect(labels(try layer(c)) == Array(both[1...]))
        // Dragging the whole fx row moves everything and leaves the source without a style.
        try s.execute("layer.layerStyle.transferEffects", ["from": .id(b), "to": .id(a)])
        #expect(try layer(b).effects.items.isEmpty)
        #expect(labels(try layer(a)) == both)
        // One history step per drop.
        let steps = try #require(s.active?.history.pastCount)
        try s.execute("layer.layerStyle.transferEffects", ["from": .id(a), "to": .id(b)])
        #expect(s.active?.history.pastCount == steps + 1)
        try s.execute("edit.undo", [:])
        #expect(labels(try layer(a)) == both)
        #expect(try layer(b).effects.items.isEmpty)
        // Bad input is an error and changes nothing.
        let bad: [JSONValue] = [
            ["from": .id(a), "to": .id(a)], ["from": .id(a)], ["from": .id(a), "to": 9999], ["from": .id(a), "to": .id(b), "effect": 7],
            ["from": .id(a), "to": .id(b), "effect": -1], ["from": .id(b), "to": .id(a)],
        ]
        for p in bad {
            #expect(throws: EngineError.self, "\(p)") { try s.execute("layer.layerStyle.transferEffects", p) }
        }
        #expect(s.active?.history.pastCount == steps)
    }

    @Test func applyingAFeatheredMaskPreservesItsSoftComposite() throws {
        for depth in Self.depths {
            let s = try session(depth, "rgb")
            try paint(s) { _, _ in SIMD4(1, 0, 0, 1) }
            try s.edit("mask fixture") { doc, active in
                var mask = LayerMask.hideAll()
                mask.surface.fill(PixelRect(x0: 0, y0: 0, x1: 20, y1: 30), with: [1])
                mask.feather = 2
                if let id = active { doc.updateLayer(id) { $0.mask = mask } }
            }
            let before = try flatten(s)
            #expect(before[15 * 40 + 19].w > 0 && before[15 * 40 + 19].w < 1, "mask must start with a soft edge")
            try s.execute("layer.layerMask.apply", [:])
            #expect(try active(s).mask == nil, "Apply removes the pixel mask")
            let after = try flatten(s)
            for (a, b) in zip(before, after) {
                #expect(abs(a.w - b.w) <= 1.0 / 255 + 1e-5, "depth \(depth): alpha \(a) became \(b)")
            }
            #expect(s.undo())
            #expect(try active(s).mask?.feather == 2)
        }
    }

    @Test func applyingADisabledFeatheredMaskDoesNotHidePixels() throws {
        let s = try session(8, "rgb")
        try paint(s) { _, _ in SIMD4(0.7, 0.2, 0.1, 1) }
        try s.edit("disabled mask") { doc, active in
            var mask = LayerMask.hideAll()
            mask.feather = 3
            mask.enabled = false
            if let id = active { doc.updateLayer(id) { $0.mask = mask } }
        }
        try s.execute("layer.layerMask.apply", [:])
        #expect(try #require(try active(s).surface).rgba(x: 20, y: 15).w == 1)
    }

    @Test func fromTransparencyPreservesMaskCoverageOutsideTheCanvas() throws {
        for depth in Self.depths {
            let s = try session(depth, "rgb")
            try paint(s) { _, _ in SIMD4(1, 0, 0, 0.5) }
            let before = try flatten(s)
            try s.execute("layer.translate", ["dx": 20])
            try s.execute("layer.layerMask.fromTransparency", [:])
            let mask = try #require(try active(s).mask)
            #expect(abs(mask.value(x: 50, y: 10) - 0.5) < 1.0 / 255 + 1e-6, "off-canvas mask at depth \(depth)")
            try s.execute("layer.translate", ["dx": -20])
            let after = try flatten(s)
            for (a, b) in zip(before, after) {
                #expect(abs(a.w - b.w) <= 1.0 / 255 + 1e-6, "alpha changed at depth \(depth): \(a) -> \(b)")
            }
        }
    }

    @Test func applyingAFeatheredMaskKeepsOffCanvasPixelsItReveals() throws {
        let s = try session(8, "rgb")
        try paint(s) { _, _ in SIMD4(1, 0, 0, 1) }
        try s.execute("layer.translate", ["dx": 20])
        try s.edit("mask fixture") { doc, active in
            // Reveal the whole layer, including the 20 px now past the right edge.
            var mask = LayerMask.hideAll()
            mask.surface.fill(PixelRect(x0: 0, y0: 0, x1: 60, y1: 30), with: [1])
            mask.feather = 2
            if let id = active { doc.updateLayer(id) { $0.mask = mask } }
        }
        try s.execute("layer.layerMask.apply", [:])
        #expect(try #require(try active(s).surface).rgba(x: 52, y: 15).w == 1, "off-canvas pixel stays visible")
    }

    @Test func maskAllObjectsMasksTheSubject() throws {
        let s = try session(8, "rgb")
        try paint(s) { x, y in
            let inside = Float((x - 20) * (x - 20) + (y - 15) * (y - 15)).squareRoot() < 8
            return inside ? SIMD4(0.9, 0.2, 0.1, 1) : SIMD4(0.95, 0.95, 0.95, 1)
        }
        do {
            let r = try s.execute("layer.maskAllObjects")
            let m = try #require(try active(s).mask)
            #expect(m.value(x: 20, y: 15) > m.value(x: 1, y: 1), "subject revealed, background hidden")
            #expect(r["bounds"]?.arrayValue?.count == 4)
        } catch {
            // The segmentation may decline tiny images; then nothing changes.
            #expect(try active(s).mask == nil, "\(error)")
        }
    }

    @Test func everyCommandIsAvailable() throws {
        let s = try session(8, "rgb")
        for spec in s.registry.specs where spec.module == "layer_menu_cmds" {
            #expect(spec.isAvailable, "\(spec.id)")
        }
        // Stack Mode needs a smart object.
        for id in ["layer.smartObjects.stackMode.median", "layer.smartObjects.stackMode.none"] {
            #expect(s.disabledReason(id) == "the active layer is not a smart object")
            #expect(throws: EngineError.self) { try s.execute(id, [:]) }
        }
    }

    @Test func stackModesRenderFromTheNestedLayers() throws {
        let s = try session(8, "rgb")
        // Three frames: the same gray, one with a bright outlier pixel.
        let services = s.services
        try s.edit("frames") { doc, active in
            let fmt = doc.pixelFormat
            var kids: [Layer] = []
            for k in 0..<3 {
                var l = Layer.raster("f\(k)", format: fmt)
                let v: Float = k == 2 ? 1 : 0.4
                l.withRaster { surf in
                    surf.fill(PixelRect(x0: 0, y0: 0, x1: 40, y1: 30), with: fmt.components(fromRGBA: SIMD4(0.4, 0.4, 0.4, 1)))
                    surf.fill(PixelRect(x0: 3, y0: 3, x1: 4, y1: 4), with: fmt.components(fromRGBA: SIMD4(v, v, v, 1)))
                }
                kids.append(l)
            }
            let g = Layer(name: "stack", content: .group(LayerGroup(children: kids, expanded: true, artboard: nil)))
            let smart = try SmartCommands.layerToSmart(doc, g, services: services)
            doc.layers = [smart]
            active = smart.id
        }
        func at(_ x: Int32, _ y: Int32) throws -> SIMD4<Float> {
            guard case .smart(let sm) = try active(s).content, let c = sm.cache else { throw EngineError.other("not smart") }
            return c.rgba(x: x, y: y)
        }
        #expect(try at(3, 3).x > 0.9, "normal composite shows the top frame")
        try s.execute("layer.smartObjects.stackMode.median")
        #expect(abs(try at(3, 3).x - 0.4) < 2.0 / 255, "median removes the outlier")
        try s.execute("layer.smartObjects.stackMode.maximum")
        #expect(try at(3, 3).x > 0.99)
        try s.execute("layer.smartObjects.stackMode.range")
        #expect(try at(10, 10).x < 1.0 / 255)
        for m in StackMode.allCases {
            let r = try s.execute("layer.smartObjects.stackMode.\(m.id)")
            #expect(r == ["stackMode": .string(m.id)])
            guard case .smart(let sm) = try active(s).content else { Issue.record("smart"); continue }
            #expect(sm.stackMode == m)
            #expect(s.active?.history.undoLabel == "Stack Mode: \(m.label)")
        }
        #expect(try s.execute("layer.smartObjects.stackMode.none") == ["stackMode": .null])
        #expect(try at(3, 3).x > 0.9)
        // The stack mode survives .pcraft.
        try s.execute("layer.smartObjects.stackMode.mean")
        let back = try PcraftFormat.load(try PcraftFormat.save(try doc(s)))
        guard case .smart(let sm)? = back.layers.first?.content else { Issue.record("smart after .pcraft"); return }
        #expect(sm.stackMode == .mean)
    }

    /// Export As writes layered formats through PCIO (one-layer documents).
    @Test func exportLayerWritesLayeredFormats() throws {
        let s = try session(16, "rgb")
        try paint(s) { x, y in (5..<15).contains(x) && (4..<10).contains(y) ? SIMD4(1, 0, 0, 1) : SIMD4(repeating: 0) }
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("pc-layer-export-psd-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        for ext in ["psd", "pcraft"] {
            let path = dir.appendingPathComponent("layer.\(ext)").path
            let r = try s.execute("layer.exportAs", ["path": .string(path)])
            #expect(r["width"] == 10 && r["height"] == 6, "\(ext)")
            let back = try EngineIO.importPath(path, services: s.services).document
            #expect(back.size.width == 10 && back.size.height == 6 && back.depth == .u16, "\(ext)")
            #expect(back.layers.first?.surface?.rgba(x: 0, y: 0) == SIMD4(1, 0, 0, 1), "\(ext)")
            if ext == "psd" { dropForOracle(URL(fileURLWithPath: path), as: "layerMenu-exportAs.psd") }
        }
    }

    /// Every command of this agent's modules is registered with photocraft's id, label, menu
    /// path, shortcut and params, under its photocraft module.
    @Test func registrationsMatchPhotocraftsCatalogue() throws {
        let modules: Set<String> = ["layer_menu_cmds", "layer_nav_cmds", "layer_copy_cmds", "layer_label_cmds", "layer_mask_props_cmds", "mask_view_cmds",
                                    "group_view_cmds", "fx_view_cmds", "fx_visibility_cmds", "background_cmds", "stamp_cmds", "rasterize_style_cmds"]
        let r = CommandRegistry.standard()
        let expected = PhotocraftCatalog.commands.filter { modules.contains($0.module) }
        #expect(expected.count > 0)
        for c in expected {
            let spec = try #require(r.spec(c.id), "\(c.id)")
            #expect(spec.module == c.module, "\(c.id)")
            #expect(spec.label == c.label, "\(c.id)")
            #expect(spec.menu == c.menu, "\(c.id)")
            #expect(spec.shortcut == c.shortcut, "\(c.id)")
            #expect(spec.params == PhotocraftExtensions.expected(c), "\(c.id)")
        }
        for spec in r.specs where modules.contains(spec.module) {
            #expect(PhotocraftCatalog.byId[spec.id]?.module == spec.module, "\(spec.id) is not a photocraft command of its module")
        }
    }
}
