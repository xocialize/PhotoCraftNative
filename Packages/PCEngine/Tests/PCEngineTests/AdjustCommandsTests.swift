// Port of photocraft-engine (crates/engine/src/adjust_cmds/tests.rs), MIT OR Apache-2.0, © ArtCraft Team and the PhotoCraft contributors.

import Foundation
import PCDocument
@testable import PCEngine
import PCFoundation
import Testing

private let depths = [8, 16, 32]
private let modes = ["rgb", "gray", "cmyk", "lab"]

/// A 48×32 document of `mode` and `depth` whose layer holds a colour gradient.
private func session(_ depth: Int, _ mode: String) throws -> Session {
    let s = Session()
    try s.execute("file.new", ["width": 48, "height": 32, "depth": .int(depth), "mode": .string(mode)])
    try paint(s) { x, y in SIMD4(0.1 + Float(x) / 60, 0.2 + Float(y) / 50, 0.6 - Float(x) / 120, 1) }
    return s
}

private func paint(_ s: Session, _ f: @escaping (Int32, Int32) -> SIMD4<Float>) throws {
    try s.edit("setup") { doc, active in
        guard let id = active else { throw EngineError.other("no active layer") }
        let b = doc.bounds
        doc.withRaster(of: id) { surf in
            var data: [Float] = []
            for y in b.y0..<b.y1 { for x in b.x0..<b.x1 { data += surf.format.components(fromRGBA: f(x, y)) } }
            surf.writeRegion(b, data)
        }
    }
}

private func rgba(_ s: Session, _ x: Int32, _ y: Int32) -> SIMD4<Float> {
    guard let d = s.active, let id = d.activeLayer, let surf = d.doc.layer(id)?.surface else { return SIMD4(repeating: .nan) }
    return surf.rgba(x: x, y: y)
}

private func changed(_ a: SIMD4<Float>, _ b: SIMD4<Float>) -> Float { max(abs(a.x - b.x), abs(a.y - b.y), abs(a.z - b.z)) }

private func steps(_ s: Session) -> Int { s.active?.history.pastCount ?? -1 }

private func adjustment(_ s: Session, _ id: LayerId) -> Adjustment? {
    if case .adjustment(let a)? = s.active?.doc.layer(id)?.content { return a }
    return nil
}

private func maskAt(_ s: Session, _ x: Int32, _ y: Int32) -> Float {
    guard let d = s.active, let id = d.activeLayer, let m = d.doc.layer(id)?.mask else { return .nan }
    return m.surface.sampleChannel(x: x, y: y, 0)
}

@Suite struct AdjustCommandsTests {
    /// Every id of the ported modules keeps photocraft's label, menu path, shortcut and params.
    @Test func specsMatchPhotocraftsCatalogue() throws {
        let r = CommandRegistry.standard()
        for module in ["adjust_cmds", "history_cmds", "comps_cmds"] {
            let ids = PhotocraftCatalog.commands.filter { $0.module == module }
            #expect(!ids.isEmpty)
            for c in ids {
                let spec = try #require(r.spec(c.id), "\(c.id) is registered")
                #expect(spec.module == module, "\(c.id)")
                #expect(spec.label == c.label && spec.menu == c.menu && spec.shortcut == c.shortcut && spec.params == c.params, "\(c.id)")
            }
        }
    }

    @Test func destructiveAdjustmentsAllDepthsAndModesOneUndoStep() throws {
        let cases: [(String, JSONValue)] = [
            ("image.adjustments.shadowsHighlights", ["shadowAmount": 80, "blackClip": 0, "whiteClip": 0]),
            ("image.adjustments.replaceColor", ["color": "#4d66cc", "fuzziness": 200, "hue": 90, "saturation": 30]),
            ("image.adjustments.matchColor", ["neutralize": true, "intensity": 50]),
            ("image.adjustments.hdrToning", ["strength": 2, "exposure": 0.5]),
        ]
        for depth in depths {
            for mode in modes {
                let s = try session(depth, mode)
                for (id, params) in cases {
                    let before = rgba(s, 3, 3)
                    let n = steps(s)
                    try s.execute(id, params)
                    let after = rgba(s, 3, 3)
                    // Gray documents can't show hue changes from Replace Color at a gray pixel.
                    if !(mode == "gray" && (id.hasSuffix("replaceColor") || id.hasSuffix("matchColor"))) {
                        #expect(changed(before, after) > 1e-3, "\(id) \(depth) \(mode): \(before) → \(after)")
                    }
                    #expect(steps(s) == n + 1, "\(id): one history step")
                    try s.execute("edit.undo")
                    #expect(changed(before, rgba(s, 3, 3)) < 1e-6, "\(id) undo")
                }
            }
        }
    }

    /// photocraft checks this with Shadows/Highlights; Replace Color blends through the selection
    /// the same way.
    @Test func destructiveAdjustmentsRespectSelection() throws {
        for (id, params): (String, JSONValue) in [("image.adjustments.shadowsHighlights", ["shadowAmount": 100, "blackClip": 0, "whiteClip": 0]),
                                                  ("image.adjustments.replaceColor", ["color": "#4d66cc", "fuzziness": 200, "hue": 90])] {
            let s = try session(8, "rgb")
            try s.edit("sel") { doc, _ in
                var sel = Surface(format: .gray8)
                sel.writeRegion(PixelRect(x: 0, y: 0, width: 10, height: 32), [Float](repeating: 1, count: 320))
                doc.selection = sel
            }
            let outside = rgba(s, 30, 5)
            let inside = rgba(s, 5, 5)
            try s.execute(id, params)
            #expect(changed(inside, rgba(s, 5, 5)) > 1e-3, "\(id)")
            #expect(outside == rgba(s, 30, 5), "\(id)")
        }
    }

    @Test func matchColorFromAnotherDocument() throws {
        let s = try session(8, "rgb")
        try s.execute("file.new", ["width": 16, "height": 16, "background": "#e05010"])
        // The target is document 0.
        try s.execute("document.activate", ["document": 0])
        let before = rgba(s, 10, 10)
        try s.execute("image.adjustments.matchColor", ["source": 1])
        let after = rgba(s, 10, 10)
        #expect(after.x > before.x && after.z < before.z, "\(before) → \(after)")
        // Fade 100 is a no-op; a bad source index is an error.
        try s.execute("edit.undo")
        try s.execute("image.adjustments.matchColor", ["source": 1, "fade": 100])
        #expect(changed(before, rgba(s, 10, 10)) < 2 / 255)
        #expect(throws: EngineError.self) { try s.execute("image.adjustments.matchColor", ["source": 7]) }
        // Source "None" with default options is a no-op.
        let now = rgba(s, 10, 10)
        try s.execute("image.adjustments.matchColor")
        #expect(changed(now, rgba(s, 10, 10)) < 2 / 255)
    }

    @Test func hdrToningFlattens() throws {
        let s = try session(16, "rgb")
        try s.execute("layer.new.layer")
        #expect(s.active?.doc.layers.count == 2)
        try s.execute("image.adjustments.hdrToning")
        #expect(s.active?.doc.layers.count == 1)
        #expect(s.active?.doc.layers.first?.name == "Background")
        #expect(s.active?.doc.background != nil)
    }

    @Test func disabledWithoutPixels() throws {
        let s = try session(8, "rgb")
        try s.execute("layer.newAdjustmentLayer.invert")
        for id in ["image.adjustments.shadowsHighlights", "image.adjustments.replaceColor", "image.adjustments.matchColor"] {
            #expect(!s.isEnabled(id), "\(id)")
        }
        #expect(s.disabledReason("image.adjustments.replaceColor")?.contains("an Adjustment layer") == true)
        #expect(s.isEnabled("image.adjustments.hdrToning"))
        #expect(!Session().isEnabled("image.adjustments.hdrToning"))
    }

    @Test func selectiveColorLayerAndDestructive() throws {
        for depth in depths {
            for mode in ["rgb", "cmyk", "lab"] {
                let s = try session(depth, mode)
                try paint(s) { _, _ in SIMD4(0.9, 0.1, 0.1, 1) }
                let before = rgba(s, 1, 1)
                // Reds: +60 % black (absolute) darkens.
                try s.execute("image.adjustments.selectiveColor", ["method": "absolute", "reds": [0, 0, 0, 60]])
                let after = rgba(s, 1, 1)
                #expect(after.x < before.x - 0.05, "\(depth) \(mode): \(before) → \(after)")
            }
        }
        let s = try session(8, "rgb")
        let r = try s.execute("layer.newAdjustmentLayer.selectiveColor", ["colors": "blues", "yellow": 40])
        let id = LayerId(try #require(r["layer"]?.uint64Value))
        func get() -> (Bool, [SIMD4<Float>])? {
            if case .selectiveColor(let sc)? = adjustment(s, id) { return (sc.relative, sc.adjustments) }
            return nil
        }
        #expect(get()?.1[4] == SIMD4(0, 0, 40, 0))
        // Properties edits merge one range at a time.
        try s.execute("layer.setAdjustment", ["layer": .id(id), "colors": "neutrals", "black": -20, "method": "absolute"])
        let (rel, a) = try #require(get())
        #expect(!rel)
        #expect(a[4][2] == 40)
        #expect(a[7][3] == -20)
        // No parameters: reset.
        try s.execute("layer.setAdjustment", ["layer": .id(id)])
        let reset = try #require(get())
        #expect(reset.0 && reset.1 == [SIMD4<Float>](repeating: .zero, count: 9))
    }

    @Test func colorLookupBuiltinDataAndErrors() throws {
        var s = try session(8, "rgb")
        let r = try s.execute("layer.newAdjustmentLayer.colorLookup", ["lut": "dayForNight"])
        let id = LayerId(try #require(r["layer"]?.uint64Value))
        let d = try #require(s.active)
        let px = try #require(try s.services.renderer.render(d.doc, region: PixelRect(x: 40, y: 30, width: 1, height: 1)).px.first)
        #expect(px.z > px.x, "night is blue: \(px)")
        // Switching interpolation keeps the table.
        try s.execute("layer.setAdjustment", ["layer": .id(id), "interpolation": "tetrahedral", "dither": true])
        if case .colorLookup(let cl)? = adjustment(s, id) {
            #expect(cl.lut != nil && cl.size == 33 && cl.tetrahedral && cl.dither && cl.name == "Day for Night")
        } else { Issue.record("expected Color Lookup") }
        // Embedded .cube text (an inverting LUT) applied destructively, at every depth.
        var cube = "LUT_3D_SIZE 2\n"
        for b in 0..<2 { for g in 0..<2 { for r in 0..<2 { cube += "\(1 - r) \(1 - g) \(1 - b)\n"; _ = b } } }
        for depth in depths {
            let s = try session(depth, "rgb")
            let before = rgba(s, 5, 5)
            try s.execute("image.adjustments.colorLookup", ["data": .string(cube), "fileName": "invert.cube"])
            let after = rgba(s, 5, 5)
            for c in 0..<3 { #expect(abs(after[c] - (1 - before[c])) < 2 / 255, "\(depth): \(before) \(after)") }
        }
        s = try session(8, "rgb")
        #expect(throws: EngineError.self) { try s.execute("image.adjustments.colorLookup", ["lut": "nope"]) }
        // A custom input domain is rejected with the reason instead of silently shifting the look.
        let domained = "TITLE \"d\"\nDOMAIN_MIN 0.1 0.1 0.1\nDOMAIN_MAX 0.9 0.9 0.9\nLUT_3D_SIZE 2\n0 0 0\n0 0 1\n0 1 0\n0 1 1\n1 0 0\n1 0 1\n1 1 0\n1 1 1\n"
        do {
            try s.execute("image.adjustments.colorLookup", ["data": .string(domained), "fileName": "log.cube"])
            Issue.record("a custom domain was accepted")
        } catch {
            #expect("\(error)".contains("DOMAIN_MIN"), "\(error)")
            #expect("\(error)".contains("[0.1, 0.1, 0.1]"), "\(error)")
        }
        #expect(throws: EngineError.self) { try s.execute("image.adjustments.colorLookup", ["data": "LUT_3D_SIZE 3\n0 0 0\n"]) }
        #expect(throws: EngineError.self) { try s.execute("layer.newAdjustmentLayer.colorLookup", ["file": "/nonexistent/x.cube"]) }
        let looks = try s.execute("image.adjustments.colorLookup.list")
        #expect(looks.arrayValue?.count == 8)
        #expect(looks[5]?["id"] == "dayForNight" && looks[5]?["label"] == "Day for Night")
    }

    @Test func colorLookupReadsFiles() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("pcengine-lut-\(ProcessInfo.processInfo.processIdentifier)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let path = dir.appendingPathComponent("grade.cube").path
        try "TITLE \"x\"\nLUT_3D_SIZE 2\n0 0 0\n1 0 0\n0 1 0\n1 1 0\n0 0 1\n1 0 1\n0 1 1\n1 1 1\n".write(toFile: path, atomically: true, encoding: .utf8)
        let s = try session(8, "rgb")
        let r = try s.execute("layer.newAdjustmentLayer.colorLookup", ["file": .string(path)])
        let id = LayerId(try #require(r["layer"]?.uint64Value))
        if case .colorLookup(let cl)? = adjustment(s, id) {
            #expect(cl.name == "grade.cube" && cl.size == 2 && cl.lut?.count == 24)
        } else { Issue.record("expected Color Lookup") }
    }

    @Test func selectiveColorAndColorLookupRejectWrongTypedParams() throws {
        let cube = "LUT_3D_SIZE 2\n0 0 0\n1 0 0\n0 1 0\n1 1 0\n0 0 1\n1 0 1\n0 1 1\n1 1 1\n"
        // (kind, params, the key the error must name)
        let cases: [(String, JSONValue, String)] = [
            ("selectiveColor", ["method": 5], "method"), ("selectiveColor", ["method": "sideways"], "method"),
            ("selectiveColor", ["relative": "yes"], "relative"), ("selectiveColor", ["reds": "not-an-array"], "reds"),
            ("selectiveColor", ["blues": [10, 20]], "blues"), ("selectiveColor", ["neutrals": [10, "20", 0, 0]], "neutrals"),
            ("selectiveColor", ["colors": 3, "cyan": 50], "colors"), ("selectiveColor", ["colors": "purples", "cyan": 50], "purples"),
            ("selectiveColor", ["colors": "reds", "cyan": "50"], "cyan"), ("selectiveColor", ["colors": "blacks", "black": [1]], "black"),
            ("colorLookup", ["lut": 42], "lut"), ("colorLookup", ["interpolation": 5], "interpolation"),
            ("colorLookup", ["interpolation": "bicubic"], "interpolation"), ("colorLookup", ["tetrahedral": 1], "tetrahedral"),
            ("colorLookup", ["dither": "yes"], "dither"), ("colorLookup", ["data": 42], "data"),
            ("colorLookup", ["data": .string(cube), "fileName": 7], "fileName"), ("colorLookup", ["file": 42], "file"),
        ]
        func named(_ what: String, _ key: String, _ body: () throws -> Void) {
            do {
                try body()
                Issue.record("\(what): expected BadParams naming `\(key)`")
            } catch let e as EngineError {
                if case .badParams = e { #expect("\(e)".contains(key), "\(what): \(e)") } else { Issue.record("\(what): \(e)") }
            } catch {
                Issue.record("\(what): \(error)")
            }
        }
        // One document per depth and mode: every case must leave it unchanged.
        for depth in depths {
            for mode in ["rgb", "cmyk", "lab"] {
                let s = try session(depth, mode)
                let (layers, n, px) = (s.active?.doc.layers.count, steps(s), rgba(s, 3, 3))
                for (kind, p, key) in cases {
                    let what = "\(kind) \(p) \(depth) \(mode)"
                    named(what, key) { try s.execute("image.adjustments.\(kind)", p) }
                    named(what, key) { try s.execute("layer.newAdjustmentLayer.\(kind)", p) }
                    #expect(s.active?.doc.layers.count == layers, "\(what): no layer added")
                    #expect(steps(s) == n, "\(what): no history step")
                    #expect(rgba(s, 3, 3) == px, "\(what): pixels unchanged")
                }
            }
        }
        // An update with a wrong-typed key fails and keeps every existing value.
        let s = try session(8, "rgb")
        let made: [(String, JSONValue)] = [
            ("selectiveColor", ["method": "absolute", "reds": [10, -20, 30, -40], "colors": "blues", "yellow": 40]),
            ("colorLookup", ["lut": "warm", "interpolation": "tetrahedral", "dither": true]),
        ]
        for (kind, p) in made {
            let id = LayerId(try #require(try s.execute("layer.newAdjustmentLayer.\(kind)", p)["layer"]?.uint64Value))
            let before = adjustment(s, id)
            for (k, p, key) in cases where k == kind {
                let q = p.setting("layer", .id(id))
                named("setAdjustment \(k) \(q)", key) { try s.execute("layer.setAdjustment", q) }
                #expect(adjustment(s, id) == before, "\(q)")
            }
            // Null still means "not given": the update keeps everything.
            let nulls: JSONValue = ["layer": .id(id), "method": nil, "reds": nil, "colors": nil, "lut": nil, "interpolation": nil, "dither": nil]
            try s.execute("layer.setAdjustment", nulls)
            #expect(adjustment(s, id) == before, "\(kind): nulls")
        }
        // Well-typed values reach the model.
        let layers = try #require(s.active).doc.layers
        if case .selectiveColor(let sc)? = adjustment(s, layers[1].id) {
            #expect(!sc.relative && sc.adjustments[0] == SIMD4(10, -20, 30, -40) && sc.adjustments[4] == SIMD4(0, 0, 40, 0))
        } else { Issue.record("expected Selective Color") }
        if case .colorLookup(let cl)? = adjustment(s, layers[2].id) {
            #expect(cl.lut != nil && cl.tetrahedral && cl.dither)
        } else { Issue.record("expected Color Lookup") }
    }

    /// With the layer mask targeted, Invert (⌘I) inverts the mask, past the canvas too, and leaves
    /// the layer's pixels alone; one history step.
    @Test func invertWithTheMaskTargetedInvertsTheMask() throws {
        for depth in depths {
            let s = try session(depth, "rgb")
            try s.execute("select.rect", ["x": 24, "y": 0, "width": 24, "height": 32])
            try s.execute("layer.layerMask.revealSelection")
            try s.execute("select.deselect")
            let (pixels, offCanvas) = (rgba(s, 3, 3), maskAt(s, -500, 3))
            let n = steps(s)
            try s.execute("image.adjustments.invert", ["target": "mask"])
            #expect(maskAt(s, 3, 3) == 1 && maskAt(s, 30, 3) == 0, "depth \(depth)")
            #expect(maskAt(s, -500, 3) == 1 - offCanvas, "the mask's untouched area inverts too")
            #expect(rgba(s, 3, 3) == pixels, "the layer is untouched")
            #expect(steps(s) == n + 1)
            // Through a selection, only the selected part.
            try s.execute("select.rect", ["x": 0, "y": 0, "width": 10, "height": 32])
            try s.execute("image.adjustments.invert", ["target": "mask"])
            #expect(maskAt(s, 3, 3) == 0 && maskAt(s, 12, 3) == 1 && maskAt(s, 30, 3) == 0)
            for _ in 0..<3 { s.undo() } // invert, select, invert
            #expect(maskAt(s, 3, 3) == 0 && maskAt(s, 30, 3) == 1 && maskAt(s, -500, 3) == offCanvas)
        }
    }

    // MARK: Image › Adjustments as smart filters

    /// A painted pixel layer converted to a smart object, over the painted Background.
    private func smartSession() throws -> Session {
        let s = try session(8, "rgb")
        try s.execute("layer.new.layer")
        try paint(s) { x, y in SIMD4(0.1 + Float(x) / 60, 0.2 + Float(y) / 50, 0.6 - Float(x) / 120, 1) }
        try s.execute("layer.smartObjects.convertToSmartObject")
        return s
    }

    private func flatten(_ s: Session) throws -> [SIMD4<Float>] {
        let d = try #require(s.active)
        return try s.services.renderer.render(d.doc, region: d.doc.bounds).px
    }

    private func maxDiff(_ a: [SIMD4<Float>], _ b: [SIMD4<Float>]) -> Float {
        zip(a, b).map { p, q in (0..<4).map { abs(p[$0] - q[$0]) }.max() ?? 0 }.max() ?? 0
    }

    private func smartFilters(_ s: Session) -> [SmartFilter] {
        guard let d = s.active, let id = d.activeLayer, case .smart(let sm)? = d.doc.layer(id)?.content else { return [] }
        return sm.smartFilters
    }

    /// FILE-215-4: Image › Adjustments on a smart object record a smart filter (Photoshop) instead
    /// of baking into a copy of the pixels: it renders exactly what the destructive command would
    /// bake in, and can be hidden, re-edited and undone, each in one history step.
    @Test func adjustmentsOnASmartObjectRecordASmartFilter() throws {
        let s = try smartSession()
        let original = try flatten(s)
        // The destructive result on the same pixels: the smart filter must match it exactly.
        let plain = try session(8, "rgb")
        try plain.execute("image.adjustments.invert")
        let baked = try flatten(plain)
        #expect(maxDiff(original, baked) > 0.5, "the control changes the pixels")
        #expect(s.isEnabled("image.adjustments.invert"), "an adjustment runs on a smart object")
        let n = steps(s)
        try s.execute("image.adjustments.invert")
        #expect(steps(s) == n + 1, "one history step")
        let sf = smartFilters(s)
        #expect(sf.count == 1)
        #expect(sf.first?.command == "image.adjustments.invert")
        #expect(sf.first.map { $0.visible && $0.opacity == 1 && $0.blend == .normal } == true)
        #expect(sf.first?.params["__kind"] == nil, "the engine's private key is not recorded")
        #expect(maxDiff(try flatten(s), baked) == 0, "the smart filter renders the destructive result")
        // Hiding the filter shows the original exactly.
        try s.execute("layer.smartFilter.setVisible", ["index": 0])
        #expect(try flatten(s) == original)
        s.undo()
        #expect(maxDiff(try flatten(s), baked) == 0, "undo restores the filtered pixels")
        // Re-editing the recorded params re-renders; the same params give the same pixels.
        try s.execute("layer.smartFilter.setParams", ["index": 0, "params": .object([:])])
        #expect(maxDiff(try flatten(s), baked) == 0, "the same params render the same pixels")
        // The setParams step, then the filter itself, undo away.
        s.undo()
        s.undo()
        #expect(smartFilters(s).isEmpty, "the filter is gone")
        #expect(try flatten(s) == original)
    }

    /// A selection becomes the smart filter's mask, and the adjustment with its own command
    /// (Shadows/Highlights) records a filter too.
    @Test func adjustmentSmartFiltersTakeASelectionAsTheirMask() throws {
        let s = try smartSession()
        let original = try flatten(s)
        try s.execute("select.rect", ["x": 0, "y": 0, "width": 24, "height": 32])
        try s.execute("image.adjustments.shadowsHighlights", ["shadowAmount": 100, "blackClip": 0, "whiteClip": 0])
        let d = try #require(s.active)
        guard case .smart(let sm)? = d.doc.layer(try #require(d.activeLayer))?.content else {
            Issue.record("not smart")
            return
        }
        #expect(sm.smartFilters.count == 1)
        #expect(sm.smartFilters.first?.command == "image.adjustments.shadowsHighlights")
        #expect(sm.filterMask != nil, "the selection became the filter mask")
        let now = try flatten(s)
        func at(_ px: [SIMD4<Float>], _ x: Int, _ y: Int) -> SIMD4<Float> { px[y * 48 + x] }
        #expect(changed(at(original, 5, 16), at(now, 5, 16)) > 1e-3, "inside the selection the shadows lifted")
        #expect(at(now, 40, 16) == at(original, 40, 16), "outside the mask the composite is unchanged")
    }

    /// A wrong-typed value errors before anything is recorded (never a trap), and the adjustments
    /// that can't re-render from a source (Replace Color, Match Color) stay off a smart object.
    @Test func aBadAdjustmentParamOnASmartObjectIsAnError() throws {
        let s = try smartSession()
        let (filters, n, flat) = (smartFilters(s).count, steps(s), try flatten(s))
        do {
            try s.execute("image.adjustments.colorLookup", ["lut": 42])
            Issue.record("accepted a numeric lut")
        } catch {
            #expect("\(error)".contains("lut"), "\(error)")
        }
        #expect(smartFilters(s).count == filters, "nothing recorded")
        #expect(steps(s) == n, "no history step")
        #expect(try flatten(s) == flat, "pixels untouched")
        #expect(!s.isEnabled("image.adjustments.replaceColor"), "only adjustments that re-render become smart filters")
        #expect(!s.isEnabled("image.adjustments.matchColor"), "only adjustments that re-render become smart filters")
    }

    /// Not a photocraft test: the recorded params re-run through `adjustAsFilter`, which refuses
    /// bad params; masks and channels edit pixels instead, and other layers aren't smart objects.
    @Test func adjustAsFilterRerunsRecordedParams() throws {
        let s = try smartSession()
        let plain = try session(8, "rgb")
        let cache = try #require(plain.active?.doc.layers.first?.surface)
        let r = PixelRect(x: 0, y: 0, width: 48, height: 32)
        let inv = try #require(AdjustCommands.adjustAsFilter("invert", .object([:]), cache))
        #expect(inv.readRegion(r) != cache.readRegion(r))
        #expect(try !AdjustCommands.adjustAsSmartFilter(s, kind: "invert", label: "Invert", ["target": "mask"]))
        #expect(try !AdjustCommands.adjustAsSmartFilter(plain, kind: "invert", label: "Invert", .object([:])))
        let sh = try #require(AdjustCommands.adjustAsFilter("shadowsHighlights", ["shadowAmount": 100, "blackClip": 0, "whiteClip": 0], cache))
        #expect(sh.readRegion(r) != cache.readRegion(r), "Shadows/Highlights re-runs from its params")
        #expect(AdjustCommands.adjustAsFilter("levels", ["inBlack": "x"], cache) == nil)
        #expect(s.isEnabled("image.adjustments.colorLookup"))
    }

    @Test func updateAdjustmentMergesSelectiveColorAndColorLookup() throws {
        let sc = try AdjustCommands.selectiveFromParams(["reds": [10, 0, 0, 0]], base: nil)
        let merged = try #require(try AdjustCommands.updateAdjustment(sc, ["blues": [0, 5, 0, 0]]))
        if case .selectiveColor(let m) = merged { #expect(m.adjustments[0].x == 10 && m.adjustments[4].y == 5) } else { Issue.record("\(merged)") }
        let reset = try #require(try AdjustCommands.updateAdjustment(sc, ["layer": 3]))
        #expect(reset == .selectiveColor(.init()))
        #expect(try AdjustCommands.updateAdjustment(.invert, .object([:])) == nil)
    }
}
