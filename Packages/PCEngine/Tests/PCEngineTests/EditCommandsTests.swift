// Port of photocraft-engine (crates/engine/src/edit_cmds.rs tests and channel_clip/tests.rs), MIT OR Apache-2.0, © ArtCraft Team and the PhotoCraft contributors.
//
// Skipped: the `injected_*_failure` tests (photocraft's allocation-failure injection has no Swift
// counterpart), `copy_a_smart_object_layer` / `paste_a_smart_object_into_another_document` (Convert to Smart
// Object is smart_cmds'), the type/shape parts of `copy_reads_any_layer_that_shows_pixels` and
// `copy_paste_keeps_type_shape_and_group_layers` (type.create / shape.create are other modules';
// the group parts are kept). The Channels panel target,
// alpha channels and the mask view are set directly where photocraft runs channel_cmds'
// commands.

import Foundation
import PCDocument
@testable import PCEngine
import PCFormat
import PCFoundation
import Testing

@Suite struct EditCommandsTests {
    /// A 100×100 document with a pixel layer holding a red rectangle at (10,10)–(50,30).
    func session() throws -> Session {
        let s = Session()
        try s.execute("file.new", ["width": 100, "height": 100])
        try s.execute("layer.new.layer")
        try paint(s, PixelRect(x0: 10, y0: 10, x1: 50, y1: 30), [1, 0, 0, 1])
        return s
    }

    func paint(_ s: Session, _ r: PixelRect, _ c: [Float], layer: LayerId? = nil) throws {
        try s.edit("paint") { doc, a in
            guard let id = layer ?? a else { throw EngineError.other("no layer") }
            doc.withRaster(of: id) { $0.fill(r, with: c) }
        }
    }

    func activeBounds(_ s: Session) -> PixelRect {
        guard let st = s.active, let id = st.activeLayer else { return .empty }
        return st.doc.layer(id)?.surface?.contentBounds ?? .empty
    }

    func clip(_ s: Session) -> EditCommands.Clip? { EditCommands.clipboard(s) }

    func layerId(_ v: JSONValue) throws -> LayerId { LayerId(try #require(v["layer"]?.uint64Value)) }

    /// #368: the clipboard as a document of its own, at every depth.
    @Test func newFromClipboardAndPasteWithNoDocument() throws {
        for depth in [8, 16, 32] {
            let s = Session()
            #expect(!s.isEnabled("file.newFromClipboard") && !s.isEnabled("edit.paste"), "nothing copied yet")
            #expect(throws: (any Error).self) { try s.execute("file.newFromClipboard") }
            try s.execute("file.new", ["width": 100, "height": 100, "depth": .int(depth)])
            try s.execute("edit.fill", ["color": "#ff0000"])
            try s.execute("select.rect", ["x": 10, "y": 20, "width": 30, "height": 15])
            try s.execute("edit.copy")
            let r = try s.execute("file.newFromClipboard")
            #expect(r["width"]?.intValue == 30 && r["height"]?.intValue == 15, "\(r.serialized())")
            #expect(s.documents.count == 2)
            let d = try #require(s.active?.doc)
            #expect(d.size.width == 30 && d.size.height == 15 && d.layers.count == 1)
            #expect(d.pixelFormat.sample == s.documents[0].doc.pixelFormat.sample, "\(depth)-bit kept")
            #expect(activeBounds(s) == PixelRect(x0: 0, y0: 0, x1: 30, y1: 15))
            let px = try #require(d.layers[0].surface).rgba(x: 0, y: 0)
            #expect(px.x > 0.99 && px.y < 0.01 && px.w > 0.99, "\(px)")
            // With nothing open, Paste makes the document too.
            while s.active != nil { try s.execute("file.close") }
            #expect(s.isEnabled("edit.paste") && !s.isEnabled("edit.pasteSpecial.pasteInPlace"))
            try s.execute("edit.paste")
            #expect(s.documents.count == 1)
            #expect(activeBounds(s) == PixelRect(x0: 0, y0: 0, x1: 30, y1: 15))
            try s.execute("edit.pasteSpecial.pasteInPlace")
        }
    }

    @Test func copyPasteInPlaceAndCentred() throws {
        let s = try session()
        try s.execute("select.rect", ["x": 10, "y": 10, "width": 20, "height": 20])
        try s.execute("edit.copy")
        try s.execute("edit.pasteSpecial.pasteInPlace")
        #expect(activeBounds(s) == PixelRect(x0: 10, y0: 10, x1: 30, y1: 30))
        #expect(s.active?.doc.selection == nil)
        try s.execute("edit.paste", ["center": [70, 70]])
        #expect(activeBounds(s) == PixelRect(x0: 60, y0: 60, x1: 80, y1: 80))
        #expect(s.active?.doc.layers.count == 4)
    }

    @Test func pasteWithMalformedCenterDoesNotTrap() throws {
        let s = try session()
        try s.execute("select.rect", ["x": 10, "y": 10, "width": 20, "height": 20])
        try s.execute("edit.copy")
        for center: JSONValue in [[5], [], "nope", [1, 2, 3]] {
            try s.execute("edit.paste", ["center": center])
        }
    }

    @Test func copyPasteBetweenDocuments() throws {
        let s = try session()
        try s.execute("select.rect", ["x": 10, "y": 10, "width": 40, "height": 20])
        try s.execute("edit.copy")
        try s.execute("file.new", ["width": 200, "height": 200])
        #expect(s.activeIndex == 1)
        let before = s.active?.doc.layers.count ?? 0
        try s.execute("edit.paste")
        #expect(s.activeIndex == 1, "paste stays in the second tab")
        let d = try #require(s.active?.doc)
        #expect(d.layers.count == before + 1)
        let pasted = try #require(d.layers.last?.surface)
        let cb = pasted.contentBounds
        let px = pasted.rgba(x: cb.x0 + Int32(cb.width / 2), y: cb.y0 + Int32(cb.height / 2))
        #expect(px.x > 0.9 && px.y < 0.1 && px.z < 0.1, "pasted content is red: \(px)")
    }

    /// #2901: Paste, Paste in Place and Paste Into damage only where the pasted layer draws.
    @Test func pasteDamagesOnlyThePastedLayer() throws {
        func render(_ s: Session) throws -> [SIMD4<Float>] {
            let doc = try #require(s.active?.doc)
            return try s.services.renderer.renderCPU(doc, region: doc.bounds).px
        }
        for depth in [8, 16, 32] {
            let s = Session()
            try s.execute("file.new", ["width": 60, "height": 50, "depth": .int(depth), "background": "white"])
            try s.execute("layer.new.layer")
            try s.execute("select.rect", ["x": 5, "y": 5, "width": 10, "height": 8])
            try s.execute("edit.fill", ["color": "#3366cc"])
            try s.execute("edit.copy")
            try s.execute("layer.setProps", ["opacity": 0.5])
            let cases: [(String, JSONValue)] = [("edit.paste", ["center": [40, 30]]), ("edit.pasteSpecial.pasteInPlace", [:]),
                                                ("edit.pasteSpecial.pasteInto", ["center": [40, 30]])]
            for (id, p) in cases {
                try s.execute("select.rect", ["x": 36, "y": 27, "width": 6, "height": 4])
                let shown = try render(s)
                try s.execute(id, p)
                let st = try #require(s.active)
                let lid = try #require(st.activeLayer)
                let area = try #require(st.doc.layer(lid)?.surface).contentBounds
                let damage = try #require(st.lastDamage, "\(depth)-bit \(id): bounded damage")
                #expect(!damage.isEmpty && damage.intersect(area) == damage, "\(depth)-bit \(id): \(damage) within \(area)")
                let now = try render(s)
                #expect(now != shown, "\(depth)-bit \(id): the paste shows")
                for (i, (a, b)) in zip(shown, now).enumerated() where !damage.contains(x: Int32(i % 60), y: Int32(i / 60)) {
                    #expect(a == b, "\(depth)-bit \(id): pixel \(i) outside the damage changed")
                }
                try s.execute("edit.undo")
                #expect(try render(s) == shown, "\(depth)-bit \(id): undo")
            }
        }
    }

    // MARK: Masks and channels (#1035, #2928)

    /// A `depth`-bit document with a blue-grey square copied from layer `src` (at (5,5)–(15,15))
    /// and an active layer `m` above it with a hide-all mask.
    func maskTargetSession(_ depth: Int) throws -> (Session, LayerId, LayerId) {
        let s = Session()
        try s.execute("file.new", ["width": 40, "height": 40, "depth": .int(depth)])
        let src = try layerId(try s.execute("layer.new.layer", ["name": "src"]))
        try s.execute("select.rect", ["x": 5, "y": 5, "width": 10, "height": 10])
        try s.execute("edit.fill", ["color": "#3366cc"])
        try s.execute("edit.copy")
        try s.execute("select.deselect")
        let m = try layerId(try s.execute("layer.new.layer", ["name": "m"]))
        try s.execute("layer.layerMask.hideAll")
        return (s, src, m)
    }

    func luminosity(_ s: Session, _ src: LayerId, _ x: Int32, _ y: Int32) -> Float {
        guard let p = s.active?.doc.layer(src)?.surface?.rgba(x: x, y: y) else { return -1 }
        return ColorConvert.rgbToGray(SIMD3(p.x, p.y, p.z))
    }

    func maskAt(_ s: Session, _ id: LayerId, _ x: Int32, _ y: Int32) -> Float {
        s.active?.doc.layer(id)?.mask?.value(x: x, y: y) ?? -1
    }

    func paintMask(_ s: Session, _ m: LayerId) throws {
        try s.edit("paint mask") { doc, _ in
            doc.updateLayer(m) { l in l.mask?.surface.fill(PixelRect(x0: 6, y0: 6, x1: 16, y1: 12), with: [0.75]) }
        }
    }

    @Test func pasteIntoATargetedMaskWritesTheLuminosityInOneStep() throws {
        for depth in [8, 16, 32] {
            let (s, src, m) = try maskTargetSession(depth)
            let lum = luminosity(s, src, 10, 10)
            #expect(lum > 0.05 && lum < 0.95, "\(depth)-bit: a mid grey (\(lum))")
            let layers = s.active?.doc.layerCount, steps = s.active?.history.pastCount ?? 0
            try s.execute("edit.pasteSpecial.pasteInPlace", ["target": "mask"])
            let st = try #require(s.active)
            #expect(st.doc.layerCount == layers, "\(depth)-bit: no new layer")
            #expect(st.history.pastCount == steps + 1, "\(depth)-bit: one history step")
            #expect(st.activeLayer == m)
            #expect(abs(maskAt(s, m, 10, 10) - lum) < 2.0 / 255, "\(depth)-bit: \(maskAt(s, m, 10, 10)) vs \(lum)")
            #expect(maskAt(s, m, 20, 20) == 0, "\(depth)-bit: the mask outside the paste is unchanged")
            #expect(st.doc.layer(m)?.surface?.contentBounds.isEmpty == true, "\(depth)-bit: the pixels are untouched")
            try s.execute("edit.undo")
            #expect(maskAt(s, m, 10, 10) == 0, "\(depth)-bit: undo restores the mask")
        }
    }

    @Test func copyWithTheMaskTargetedTakesTheMaskAsGrayscale() throws {
        for depth in [8, 16, 32] {
            let (s, _, m) = try maskTargetSession(depth)
            try paintMask(s, m)
            let steps = s.active?.history.pastCount
            let r = try s.execute("edit.copy", ["target": "mask"])
            #expect(r["bounds"] == [0, 0, 40, 40], "\(depth)-bit: a mask copies whole, as in Photoshop")
            #expect(s.active?.history.pastCount == steps, "\(depth)-bit: copy adds no history step")
            let c = try #require(clip(s))
            let px = c.surface.rgba(x: 10, y: 10)
            #expect(abs(px.x - 0.75) < 2.0 / 255, "\(depth)-bit: \(px.x) vs 0.75")
            #expect(c.surface.rgba(x: 30, y: 30).x < 0.01, "\(depth)-bit: the hidden area copies as black")
            #expect(px.w > 0.99, "\(depth)-bit: the copy is opaque")
            let m2 = try layerId(try s.execute("layer.new.layer", ["name": "m2"]))
            try s.execute("layer.layerMask.revealAll")
            try s.execute("edit.pasteSpecial.pasteInPlace", ["target": "mask"])
            #expect(abs(maskAt(s, m2, 10, 10) - 0.75) < 2.0 / 255, "\(depth)-bit: the copied mask lands")
            #expect(maskAt(s, m2, 30, 30) < 0.01, "\(depth)-bit: the copied black replaces the reveal-all")
        }
    }

    @Test func anUntouchedMaskCopiesTheWholeCanvasAtItsDefault() throws {
        let (s, _, _) = try maskTargetSession(8)
        try s.execute("layer.layerMask.revealAll")
        let r = try s.execute("edit.copy", ["target": "mask"])
        #expect(r["bounds"] == [0, 0, 40, 40], "a plain Reveal All mask still transfers")
        #expect((clip(s)?.surface.rgba(x: 20, y: 20).x ?? 0) > 0.99)
    }

    @Test func maskCopyTakesOnlyTheSelection() throws {
        let (s, _, m) = try maskTargetSession(8)
        try paintMask(s, m)
        try s.execute("select.rect", ["x": 8, "y": 8, "width": 4, "height": 4])
        let r = try s.execute("edit.copy", ["target": "mask"])
        #expect(r["bounds"] == [8, 8, 4, 4])
        let c = try #require(clip(s))
        #expect(abs(c.surface.rgba(x: 9, y: 9).x - 0.75) < 2.0 / 255)
        #expect(c.surface.rgba(x: 5, y: 5).w < 0.01, "nothing outside the selection")
    }

    @Test func maskCopyNeedsAMaskAndFailsGracefully() throws {
        let s = Session()
        #expect(throws: (any Error).self, "no document") { try s.execute("edit.copy", ["target": "mask"]) }
        try s.execute("file.new", ["width": 20, "height": 20])
        #expect(throws: (any Error).self, "the layer has no mask") { try s.execute("edit.copy", ["target": "mask"]) }
        #expect(clip(s) == nil, "a refused copy leaves the clipboard alone")
        try s.execute("layer.layerMask.revealAll")
        try s.execute("edit.copy", ["target": "mask"])
        // An adjustment layer has no pixels of its own: Copy is only enabled while its mask is targeted.
        try s.execute("file.new", ["width": 20, "height": 20])
        // (photocraft runs layer.newAdjustmentLayer.levels, which waits on adjust_params here.)
        let a = try s.edit("New Levels") { doc, active -> LayerId in
            let id = doc.insertAbove(active, Layer(name: "Levels 1", content: .adjustment(.levels(.init()))))
            active = id
            return id
        }
        try s.execute("layer.select", ["layer": .id(a)])
        #expect(!s.isEnabled("edit.copy"), "no pixels to copy")
        try s.execute("layer.layerMask.revealAll")
        #expect(s.isEnabled("edit.copy", ["target": "mask"]), "the mask can be copied")
    }

    @Test func aCopiedMaskTravelsToAnotherDocument() throws {
        let (s, _, m) = try maskTargetSession(8)
        try paintMask(s, m)
        try s.execute("edit.copy", ["target": "mask"])
        try s.execute("file.new", ["width": 40, "height": 40])
        let n = try layerId(try s.execute("layer.new.layer"))
        try s.execute("layer.layerMask.revealAll")
        try s.execute("edit.pasteSpecial.pasteInPlace", ["target": "mask"])
        #expect(abs(maskAt(s, n, 10, 10) - 0.75) < 2.0 / 255, "the mask arrived in the second document")
        #expect(maskAt(s, n, 30, 30) < 0.01, "it replaced the reveal-all mask there")
    }

    @Test func pasteFollowsTheMaskViewAndIsPlacedLikeAPaste() throws {
        let (s, src, m) = try maskTargetSession(8)
        let lum = luminosity(s, src, 10, 10)
        // ⌥-click the mask thumbnail: the canvas shows the mask, and pasting targets it.
        try s.updateActive { $0.channelView.layerMask = LayerMaskView(layer: m, mode: .gray) }
        let r = try s.execute("edit.paste", ["center": [30, 30]])
        #expect(r["offset"] == [20, 20])
        #expect(abs(maskAt(s, m, 30, 30) - lum) < 2.0 / 255)
        #expect(maskAt(s, m, 10, 10) == 0)
        #expect(s.active?.doc.layers.count == 3, "Background, src, m")
    }

    @Test func pasteIntoAndOutsideATargetedMaskKeepToTheSelection() throws {
        let (s, src, m) = try maskTargetSession(16)
        let lum = luminosity(s, src, 10, 10)
        try s.execute("select.rect", ["x": 8, "y": 8, "width": 4, "height": 4])
        try s.execute("edit.pasteSpecial.pasteInto", ["target": "mask"])
        #expect(abs(maskAt(s, m, 9, 9) - lum) < 2.0 / 255)
        #expect(maskAt(s, m, 7, 7) == 0, "pasted, but outside the selection")
        #expect(s.active?.doc.selection == nil)
        #expect(s.active?.doc.layers.count == 3, "no new layer")
        try s.execute("layer.layerMask.hideAll")
        try s.execute("select.rect", ["x": 8, "y": 8, "width": 4, "height": 4])
        try s.execute("edit.pasteSpecial.pasteOutside", ["target": "mask"])
        #expect(maskAt(s, m, 9, 9) == 0, "Paste Outside leaves the selection alone")
        #expect(abs(maskAt(s, m, 7, 7) - lum) < 2.0 / 255)
    }

    func addChannel(_ s: Session, fill: Float = 0) throws {
        try s.edit("New Channel") { doc, _ in
            var surf = Surface(format: Channels.channelFormat(doc), defaultPixel: [fill])
            surf.prune()
            doc.channels.append(AlphaChannel(name: "Alpha \(doc.channels.count + 1)", surface: surf))
        }
    }

    @Test func pasteFollowsATargetedAlphaChannel() throws {
        let (s, src, _) = try maskTargetSession(8)
        let lum = luminosity(s, src, 10, 10)
        try addChannel(s)
        try s.execute("edit.pasteSpecial.pasteInPlace", ["target": ["channel": 0]])
        let c = try #require(s.active?.doc.channels.first).surface
        #expect(abs(c.sampleChannel(x: 10, y: 10, 0) - lum) < 2.0 / 255)
        #expect(s.active?.doc.layers.count == 3, "no new layer")
    }

    @Test func pasteIntoAMissingMaskOrChannelIsAnError() throws {
        let (s, _, m) = try maskTargetSession(8)
        try s.edit("drop mask") { doc, _ in doc.updateLayer(m) { $0.mask = nil } }
        let layers = s.active?.doc.layerCount
        for target: JSONValue in ["mask", ["channel": 7], "quickMask"] {
            for id in ["edit.paste", "edit.pasteSpecial.pasteInPlace"] {
                #expect(throws: (any Error).self, "\(id) \(target.serialized())") { try s.execute(id, ["target": target]) }
            }
        }
        #expect(s.active?.doc.layerCount == layers, "nothing pasted as a layer")
    }

    @Test func pasteBetweenDifferentColorModes() throws {
        let s = try session()
        try s.execute("select.rect", ["x": 10, "y": 10, "width": 40, "height": 20])
        try s.execute("edit.copy")
        try s.execute("file.new", ["width": 120, "height": 120, "mode": "gray"])
        try s.execute("edit.paste")
        let d = try #require(s.active?.doc)
        #expect(d.mode == .grayscale)
        let pasted = try #require(d.layers.last?.surface)
        #expect(pasted.format.mode == .grayscale, "pasted layer is grayscale")
        #expect(!pasted.contentBounds.isEmpty, "pasted content exists")
    }

    // MARK: Cut, Layer via Copy / Cut

    @Test func cutAndClearOnTheBackgroundFillWithTheBackgroundColour() throws {
        func fresh() throws -> Session {
            let s = Session()
            try s.execute("file.new", ["width": 40, "height": 30])
            s.tools.background = SIMD4(1, 0, 0, 1)
            try s.execute("select.rect", ["x": 5, "y": 5, "width": 10, "height": 10])
            return s
        }
        func px(_ s: Session, _ i: Int, _ x: Int32, _ y: Int32) -> [Float] { s.active?.doc.layers[i].surface?.pixel(x: x, y: y) ?? [] }
        for cmd in ["edit.cut", "edit.clear", "layer.new.layerViaCut"] {
            let s = try fresh()
            try s.execute(cmd)
            let d = try #require(s.active?.doc)
            #expect(d.isBackground(d.layers[0].id), "\(cmd): still the Background")
            #expect(px(s, 0, 8, 8) == [1, 0, 0, 1], "\(cmd): cut area is the background colour")
            #expect(px(s, 0, 30, 20) == [1, 1, 1, 1], "\(cmd): outside untouched")
        }
        // Layer via Cut still lifts the original pixels onto the new layer.
        let s = try fresh()
        try s.execute("layer.new.layerViaCut")
        #expect(px(s, 1, 8, 8) == [1, 1, 1, 1])
        // Once it's a normal layer, cutting makes transparency again.
        let s2 = try fresh()
        try s2.execute("layer.new.layerFromBackground")
        try s2.execute("edit.clear")
        #expect(px(s2, 0, 8, 8).last == 0)
    }

    @Test func layerViaCopyOfABackgroundKeepsColourAndPartialSelection() throws {
        for depth in [8, 16, 32] {
            let s = Session()
            try s.execute("file.new", ["width": 40, "height": 30, "depth": .int(depth), "background": "#336699"])
            try s.edit("partial selection") { doc, _ in
                var m = Surface(format: .gray8)
                m.fill(PixelRect(x0: 5, y0: 5, x1: 15, y1: 15), with: [1])
                m.fill(PixelRect(x0: 15, y0: 5, x1: 20, y1: 15), with: [0.5])
                doc.selection = m
            }
            let id = try layerId(try s.execute("layer.new.layerViaCopy"))
            let surf = try #require(s.active?.doc.layer(id)?.surface)
            #expect(surf.format.alpha, "@\(depth)")
            let full = surf.readRegion(PixelRect(x0: 6, y0: 6, x1: 7, y1: 7))
            let half = surf.readRegion(PixelRect(x0: 16, y0: 6, x1: 17, y1: 7))
            for (got, want) in zip(full, [Float(0.2), 0.4, 0.6, 1.0]) { #expect(abs(got - want) < 0.01, "@\(depth): \(full)") }
            #expect(abs(half[3] - 0.5) < 0.01 && abs(half[0] - 0.2) < 0.01, "@\(depth): \(half)")
            #expect(surf.contentBounds == PixelRect(x0: 5, y0: 5, x1: 20, y1: 15), "@\(depth)")
        }
    }

    @Test func cutClearsAndLayerViaCopyCut() throws {
        let s = try session()
        try s.execute("select.rect", ["x": 10, "y": 10, "width": 10, "height": 20])
        try s.execute("edit.cut")
        #expect(activeBounds(s) == PixelRect(x0: 20, y0: 10, x1: 50, y1: 30))
        let s2 = try session()
        try s2.execute("select.rect", ["x": 10, "y": 10, "width": 10, "height": 20])
        try s2.execute("layer.new.layerViaCut")
        #expect(activeBounds(s2) == PixelRect(x0: 10, y0: 10, x1: 20, y1: 30))
        #expect(s2.active?.doc.layers[1].surface?.contentBounds == PixelRect(x0: 20, y0: 10, x1: 50, y1: 30))
        // Without a selection ⌘J duplicates the layer.
        let s3 = try session()
        try s3.execute("layer.new.layerViaCopy")
        let d = try #require(s3.active?.doc)
        #expect(d.layers.count == 3)
        #expect(d.layers[2].name.hasSuffix("copy"))
    }

    /// #1096: Layer via Copy and Cut deselect in one step.
    @Test func layerViaCopyAndCutDeselectInOneStep() throws {
        for cmd in ["layer.new.layerViaCopy", "layer.new.layerViaCut"] {
            let s = try session()
            try s.execute("select.rect", ["x": 10, "y": 10, "width": 10, "height": 20])
            let layers = s.active?.doc.layers.count ?? 0, steps = s.active?.history.pastCount ?? 0
            try s.execute(cmd)
            let st = try #require(s.active)
            #expect(st.doc.selection == nil, "\(cmd): deselected")
            #expect(st.doc.layers.count == layers + 1 && st.history.pastCount == steps + 1, "\(cmd)")
            #expect(s.undo())
            #expect(s.active?.doc.layers.count == layers, "\(cmd): undo removes the layer")
            #expect(s.active?.doc.selection != nil, "\(cmd): and restores the selection")
        }
    }

    /// #2777: several layers selected and no pixel selection: Layer via Copy copies each one.
    @Test func layerViaCopyDuplicatesEverySelectedLayer() throws {
        let s = try session()
        let a = try #require(s.active?.activeLayer)
        let b = try layerId(try s.execute("layer.new.layer"))
        try s.execute("layer.select", ["layer": .id(a)])
        try s.execute("layer.select", ["layer": .id(b), "mode": "toggle"])
        let steps = s.active?.history.pastCount ?? 0
        try s.execute("layer.new.layerViaCopy")
        let st = try #require(s.active)
        let ids = st.doc.layers.map(\.id)
        #expect(ids.count == 5, "background, a, a copy, b, b copy")
        #expect(ids[1] == a && ids[3] == b, "each copy sits above its original")
        #expect(Set(st.selectedLayers) == Set([ids[2], ids[4]]), "the copies become the selection")
        #expect(st.history.pastCount == steps + 1, "one undo step")
        #expect(s.undo())
        try s.execute("layer.select", ["layer": .id(b)])
        try s.execute("layer.select", ["layer": .id(a), "mode": "toggle"])
        try s.execute("select.rect", ["x": 10, "y": 10, "width": 10, "height": 10])
        try s.execute("layer.new.layerViaCopy")
        #expect(s.active?.doc.layers.count == 4, "a pixel selection copies one layer's pixels")
    }

    // MARK: Whole-layer copies

    /// #2478: several selected layers copy whole and paste as one step.
    @Test func copyAndPasteSeveralSelectedLayers() throws {
        let s = try session()
        let a = try #require(s.active?.activeLayer)
        let b = try layerId(try s.execute("layer.new.layer"))
        try paint(s, PixelRect(x0: 60, y0: 60, x1: 80, y1: 90), [0, 0, 1, 1], layer: b)
        try s.execute("layer.select", ["layer": .id(a)])
        try s.execute("layer.select", ["layer": .id(b), "mode": "toggle"])
        #expect(s.isEnabled("edit.copy"))
        #expect(try s.execute("edit.copy")["bounds"] == [10, 10, 70, 80], "both layers' pixels")
        let before = s.active?.doc.layers.count ?? 0, steps = s.active?.history.pastCount ?? 0
        try s.execute("edit.pasteSpecial.pasteInPlace")
        let st = try #require(s.active)
        #expect(st.doc.layers.count == before + 2, "every selected layer is pasted")
        #expect(st.history.pastCount == steps + 1, "one undo step")
        let n = st.doc.layers.count
        #expect(st.doc.layers[n - 2].surface?.contentBounds == PixelRect(x0: 10, y0: 10, x1: 50, y1: 30), "the lower layer first")
        #expect(st.doc.layers[n - 1].surface?.contentBounds == PixelRect(x0: 60, y0: 60, x1: 80, y1: 90))
        #expect(s.undo())
        #expect(s.active?.doc.layers.count == before)
        // A pixel selection takes the active layer's selected pixels, as a single layer.
        try s.execute("layer.select", ["layer": .id(a)])
        try s.execute("select.rect", ["x": 0, "y": 0, "width": 30, "height": 30])
        try s.execute("edit.copy")
        try s.execute("edit.pasteSpecial.pasteInPlace")
        #expect(s.active?.doc.layers.count == before + 1)
    }

    /// #2478, #3588: several layers copied in one document paste into another at its bit depth.
    @Test func pasteSeveralLayersIntoAnotherDocument() throws {
        for depth in [16, 32] {
            let s = try session()
            let a = try #require(s.active?.activeLayer)
            let b = try layerId(try s.execute("layer.new.layer"))
            try paint(s, PixelRect(x0: 60, y0: 60, x1: 80, y1: 90), [0, 0, 1, 1], layer: b)
            try s.execute("layer.select", ["layer": .id(a)])
            try s.execute("layer.select", ["layer": .id(b), "mode": "toggle"])
            try s.execute("edit.copy")
            try s.execute("file.new", ["width": 120, "height": 120, "depth": .int(depth)])
            #expect(s.activeIndex == 1)
            let before = s.active?.doc.layers.count ?? 0, steps = s.active?.history.pastCount ?? 0
            try s.execute("edit.pasteSpecial.pasteInPlace")
            let st = try #require(s.active)
            #expect(st.doc.layers.count == before + 2, "\(depth)-bit: both layers arrive")
            #expect(st.history.pastCount == steps + 1, "\(depth)-bit: one undo step")
            let n = st.doc.layers.count
            let pa = try #require(st.doc.layers[n - 2].surface), pb = try #require(st.doc.layers[n - 1].surface)
            #expect(pa.format.sample == st.doc.depth && pb.format.sample == st.doc.depth, "\(depth)-bit: converted to the target depth")
            #expect(pa.contentBounds == PixelRect(x0: 10, y0: 10, x1: 50, y1: 30), "\(depth)-bit: the lower layer first")
            #expect(pb.contentBounds == PixelRect(x0: 60, y0: 60, x1: 80, y1: 90))
            let red = pa.rgba(x: 20, y: 20), blue = pb.rgba(x: 70, y: 70)
            #expect(red.x > 0.9 && red.y < 0.1 && red.z < 0.1, "\(depth)-bit: red kept: \(red)")
            #expect(blue.z > 0.9 && blue.x < 0.1 && blue.y < 0.1, "\(depth)-bit: blue kept: \(blue)")
            #expect(s.undo())
            #expect(s.active?.doc.layers.count == before, "\(depth)-bit: undo removes both")
            #expect(s.documents.count == 2)
        }
    }

    /// #2478: the Background in a multi-layer copy pastes as an ordinary, unlocked layer.
    @Test func copyingTheBackgroundWithAnotherLayerPastesAnOrdinaryLayer() throws {
        let s = try session()
        let a = try #require(s.active?.activeLayer)
        let bg = try #require(s.active?.doc.layers.first?.id)
        try s.execute("layer.select", ["layer": .id(a)])
        try s.execute("layer.select", ["layer": .id(bg), "mode": "toggle"])
        try s.execute("edit.copy")
        try s.execute("edit.pasteSpecial.pasteInPlace")
        let st = try #require(s.active)
        #expect(st.doc.layers.count == 4)
        let pasted = st.doc.layers[st.doc.layers.count - 2]
        #expect(!st.doc.isBackground(pasted.id))
        #expect(pasted.locks == Locks())
        #expect(st.doc.isBackground(st.doc.layers[0].id), "the real Background is untouched")
    }

    /// #2670 (group part): with no selection a group copies whole; with Select All it has no pixels.
    @Test func copyTakesAGroupWholeWithoutASelection() throws {
        let s = try session()
        try s.execute("layer.groupLayers")
        #expect(s.isEnabled("edit.copy"), "no selection: the group is copied whole")
        try s.execute("select.all")
        #expect(!s.isEnabled("edit.copy"))
    }

    /// #2670 (group part): a copied group pastes into another document as a group with fresh ids,
    /// in that document's bit depth.
    @Test func copyPasteKeepsGroupLayers() throws {
        let s = try session()
        try s.execute("layer.groupLayers")
        let src = try #require(s.active.flatMap { st in st.activeLayer.flatMap { st.doc.layer($0) } })
        #expect(src.isGroup)
        try s.execute("edit.copy")
        try s.execute("file.new", ["width": 60, "height": 40, "depth": 16])
        try s.execute("edit.paste")
        let g = try #require(s.active.flatMap { st in st.activeLayer.flatMap { st.doc.layer($0) } })
        let children = try #require(g.children)
        #expect(children.count == 1)
        if case .raster = children[0].content {} else { Issue.record("the child stays a pixel layer") }
        #expect(children[0].id != src.children?.first?.id, "fresh ids")
        #expect(children[0].surface?.format.sample == s.active?.doc.depth, "converted to 16 bits")
    }

    // MARK: Merge Visible, Auto, Toggle Last State

    @Test func mergeVisibleKeepsHiddenLayers() throws {
        let s = try session()
        let red = try #require(s.active?.activeLayer)
        try s.execute("layer.new.layer")
        let hidden = try #require(s.active?.activeLayer)
        try s.execute("layer.setProps", ["layer": .id(hidden), "visible": false])
        // The active layer must be shown (below).
        try s.execute("layer.select", ["layer": .id(red)])
        try s.execute("layer.mergeVisible")
        let d = try #require(s.active?.doc)
        #expect(d.layers.count == 2)
        #expect(d.layers[0].name == "Background")
        #expect(d.layers[1].id == hidden)
        #expect(Array(d.layers[0].surface?.pixel(x: 20, y: 20).prefix(3) ?? []) == [1, 0, 0])
    }

    /// A session whose document holds exactly `layers` (bottom to top), `active` being the layer of that name.
    func stack(_ layers: [Layer], active: String) throws -> Session {
        let s = Session()
        try s.execute("file.new", ["width": 40, "height": 40])
        try s.edit("stack") { doc, a in
            doc.layers = layers
            a = doc.walk().first { $0.layer.name == active }?.layer.id
        }
        return s
    }

    /// A pixel layer with a 4 px square of `color` at (`x`, 0).
    func square(_ name: String, x: Int32, _ color: [Float], visible: Bool = true) -> Layer {
        var surface = Surface(format: PixelFormat(mode: .rgb, sample: .u8, alpha: true))
        surface.fill(PixelRect(x0: x, y0: 0, x1: x + 4, y1: 4), with: color)
        var l = Layer.raster(name, surface: surface)
        l.visible = visible
        return l
    }

    func names(_ s: Session) -> [String] { s.active?.doc.layers.map { $0.visible ? $0.name : "\($0.name) (hidden)" } ?? [] }

    /// Photoshop 27.11 (AB-T-0343): every shown layer merges into the active one, which gives the result its name
    /// and its place among the hidden layers. A, B (hidden), C, D bottom to top.
    @Test func mergeVisibleMergesIntoTheActiveLayer() throws {
        func layers() -> [Layer] {
            [square("A", x: 0, [1, 0, 0, 1]), square("B", x: 8, [0, 1, 0, 1], visible: false), square("C", x: 16, [0, 0, 1, 1]), square("D", x: 24, [1, 1, 0, 1])]
        }
        for (active, expected) in [("D", ["B (hidden)", "D"]), ("C", ["B (hidden)", "C"]), ("A", ["A", "B (hidden)"])] {
            let s = try stack(layers(), active: active)
            try s.execute("layer.mergeVisible")
            #expect(names(s) == expected, "active \(active)")
            let d = try #require(s.active)
            let merged = try #require(d.doc.layers.first { $0.name == active })
            #expect(d.activeLayer == merged.id)
            // A, C and D are in it; the hidden B is not.
            #expect(merged.surface?.pixel(x: 1, y: 1) == [1, 0, 0, 1])
            #expect(merged.surface?.pixel(x: 17, y: 1) == [0, 0, 1, 1])
            #expect(merged.surface?.pixel(x: 25, y: 1) == [1, 1, 0, 1])
            #expect(merged.surface?.pixel(x: 9, y: 1)[3] == 0)
            #expect(s.active?.doc.layers.first { !$0.visible }?.surface?.pixel(x: 9, y: 1) == [0, 1, 0, 1])
        }
    }

    /// A hidden layer inside a shown folder stays, lifted out of the folder: A, G{g1, g2 hidden} with g1 active gives
    /// g1, g2 (hidden); with the folder active the result takes the folder's name.
    @Test func mergeVisibleKeepsHiddenLayersInShownFolders() throws {
        func layers() -> [Layer] {
            [square("A", x: 0, [1, 0, 0, 1]), .group("G", [square("g1", x: 8, [0, 1, 0, 1]), square("g2", x: 16, [0, 0, 1, 1], visible: false)])]
        }
        let s = try stack(layers(), active: "g1")
        try s.execute("layer.mergeVisible")
        #expect(names(s) == ["g1", "g2 (hidden)"])
        let merged = try #require(s.active?.doc.layers.first)
        #expect(merged.surface?.pixel(x: 1, y: 1) == [1, 0, 0, 1] && merged.surface?.pixel(x: 9, y: 1) == [0, 1, 0, 1])
        #expect(merged.surface?.pixel(x: 17, y: 1)[3] == 0)
        #expect(s.active?.doc.layers.last?.surface?.pixel(x: 17, y: 1) == [0, 0, 1, 1])

        let folder = try stack(layers(), active: "G")
        try folder.execute("layer.mergeVisible")
        #expect(Set(names(folder)) == ["G", "g2 (hidden)"])
        // One step.
        try folder.execute("edit.undo")
        #expect(names(folder) == ["A", "G"])
    }

    /// A shown Background takes the merge, whichever layer is active.
    @Test func mergeVisibleGoesIntoAShownBackground() throws {
        let s = try session()
        let d0 = try #require(s.active)
        #expect(d0.doc.background != nil && d0.activeLayer != d0.doc.background?.id)
        try s.execute("layer.mergeVisible")
        let d = try #require(s.active)
        #expect(d.doc.layers.count == 1 && d.doc.background?.id == d.doc.layers[0].id && d.activeLayer == d.doc.layers[0].id)
        #expect(Array(d.doc.layers[0].surface?.pixel(x: 20, y: 20).prefix(3) ?? []) == [1, 0, 0])
    }

    /// Not available with the active layer hidden, or with only one layer shown.
    @Test func mergeVisibleIsRefusedAsPhotoshopRefusesIt() throws {
        let hiddenActive = try stack([square("A", x: 0, [1, 0, 0, 1]), square("B", x: 8, [0, 1, 0, 1]), square("C", x: 16, [0, 0, 1, 1], visible: false)],
                                     active: "C")
        #expect(throws: (any Error).self) { try hiddenActive.execute("layer.mergeVisible") }
        #expect(names(hiddenActive) == ["A", "B", "C (hidden)"])
        let one = try stack([square("A", x: 0, [1, 0, 0, 1]), square("B", x: 8, [0, 1, 0, 1], visible: false)], active: "A")
        #expect(throws: (any Error).self) { try one.execute("layer.mergeVisible") }
        // A layer inside a hidden folder is not shown.
        let inHidden = try stack([square("A", x: 0, [1, 0, 0, 1]), {
            var g = Layer.group("G", [square("g1", x: 8, [0, 1, 0, 1])])
            g.visible = false
            return g
        }()], active: "A")
        #expect(throws: (any Error).self) { try inHidden.execute("layer.mergeVisible") }
        #expect(names(inHidden) == ["A", "G (hidden)"])
    }

    @Test func autoToneStretchesALowContrastLayer() throws {
        let s = Session()
        try s.execute("file.new", ["width": 64, "height": 64])
        try s.edit("grey ramp") { doc, _ in
            guard let id = doc.layers.first?.id else { return }
            doc.withRaster(of: id) { surf in
                for x in Int32(0)..<64 {
                    let v = 0.3 + 0.4 * Float(x) / 63
                    surf.fill(PixelRect(x0: x, y0: 0, x1: x + 1, y1: 64), with: [v, v * 0.9, v * 0.8, 1])
                }
            }
        }
        for cmd in ["image.autoTone", "image.autoContrast", "image.autoColor"] {
            try s.execute(cmd)
            let surf = try #require(s.active?.doc.layers.first?.surface)
            let (a, b) = (surf.pixel(x: 0, y: 0), surf.pixel(x: 63, y: 0))
            // Auto Contrast keeps colour (shared points): only the extreme channels reach 0 and 1.
            let (lo, hi) = cmd == "image.autoContrast" ? (a[2], b[0]) : (a[0], b[0])
            #expect(lo < 0.05 && hi > 0.95, "\(cmd): \(a) \(b)")
            s.undo()
        }
    }

    @Test func toggleLastState() throws {
        let s = try session()
        try s.execute("edit.fill", ["color": "#0000ff"])
        #expect(activeBounds(s) == PixelRect(x0: 0, y0: 0, x1: 100, y1: 100))
        try s.execute("edit.toggleLastState")
        #expect(activeBounds(s) == PixelRect(x0: 10, y0: 10, x1: 50, y1: 30))
        try s.execute("edit.toggleLastState")
        #expect(activeBounds(s) == PixelRect(x0: 0, y0: 0, x1: 100, y1: 100))
    }

    @Test func transformScaleGrowsContent() throws {
        let s = try session() // red rect (10,10)-(50,30): 40x20
        try s.execute("edit.transform", ["matrix": [2, 0, 0, 2, 0, 0]])
        let cb = try #require(s.active?.doc.layers.last?.surface?.contentBounds)
        // Scaled ~2x about the origin (≈ 80x40 at ≈ (20,20)); allow ~1px bilinear edge bleed.
        #expect(abs(cb.x0 - 20) <= 2 && abs(cb.y0 - 20) <= 2, "origin ~ (20,20): \(cb)")
        #expect(abs(cb.width - 80) <= 3 && abs(cb.height - 40) <= 3, "size ~ 80x40: \(cb)")
    }

    /// #352: ⌥⇧⌘T steps and repeats: each press adds a copy one transform further on, and each
    /// is one undo step.
    @Test func transformAgainOnACopyStepsAndRepeats() throws {
        let s = try session()
        #expect(throws: (any Error).self, "nothing to repeat yet") { try s.execute("edit.transform.againCopy") }
        #expect(s.active?.doc.layers.count == 2, "a refusal leaves no copy")
        try s.execute("edit.transform", ["matrix": [1, 0, 0, 1, 10, 0]])
        let steps = s.active?.history.pastCount ?? 0
        for (i, x) in [Int32(30), 40].enumerated() {
            try s.execute("edit.transform.againCopy")
            #expect(s.active?.doc.layers.count == 3 + i)
            #expect(activeBounds(s) == PixelRect(x0: x, y0: 10, x1: x + 40, y1: 30), "the copy moved one step further")
            #expect(s.active?.history.pastCount == steps + 1 + i, "one history step per press")
        }
        #expect(s.active?.history.undoLabel == "Transform Again")
        // The original and the first copy stay where they were.
        let d = try #require(s.active?.doc)
        #expect(d.layers[1].surface?.contentBounds == PixelRect(x0: 20, y0: 10, x1: 60, y1: 30))
        #expect(d.layers[2].surface?.contentBounds == PixelRect(x0: 30, y0: 10, x1: 70, y1: 30))
        // Undo removes the copy and its move together.
        s.undo()
        #expect(s.active?.doc.layers.count == 3)
        #expect(activeBounds(s) == PixelRect(x0: 30, y0: 10, x1: 70, y1: 30))
        // A copy that can't move (position locked) is taken back.
        let id = try #require(s.active?.activeLayer)
        try s.execute("layer.setProps", ["layer": .id(id), "locks": ["position": true]])
        let layers = s.active?.doc.layers.count
        do {
            try s.execute("edit.transform.againCopy")
            Issue.record("no error")
        } catch {
            #expect("\(error)".contains("locked"), "\(error)")
        }
        #expect(s.active?.doc.layers.count == layers)
        #expect(s.active?.history.canRedo == false, "nothing to redo")
    }

    @Test func toggleLastStateAndTransformAgain() throws {
        let s = try session()
        try s.execute("edit.transform", ["matrix": [1, 0, 0, 1, 10, 0]])
        try s.execute("edit.transform.again")
        #expect(activeBounds(s) == PixelRect(x0: 30, y0: 10, x1: 70, y1: 30))
        try s.execute("edit.toggleLastState")
        #expect(activeBounds(s) == PixelRect(x0: 20, y0: 10, x1: 60, y1: 30))
        try s.execute("edit.toggleLastState")
        #expect(activeBounds(s) == PixelRect(x0: 30, y0: 10, x1: 70, y1: 30))
        // Added: a quad transform (with its frame) repeats on the active layer's own frame.
        try s.execute("edit.transform", ["rect": [30, 10, 70, 30], "quad": [[30, 10], [110, 10], [110, 30], [30, 30]], "interpolation": "nearest"])
        #expect(activeBounds(s) == PixelRect(x0: 30, y0: 10, x1: 110, y1: 30))
        try s.execute("edit.transform.again")
        #expect(activeBounds(s) == PixelRect(x0: 30, y0: 10, x1: 190, y1: 30))
        // Without its frame a quad can't be repeated (photocraft needs `rect` and `quad`).
        try s.execute("edit.transform", ["quad": [[30, 10], [190, 10], [190, 30], [30, 30]]])
        #expect(throws: (any Error).self) { try s.execute("edit.transform.again") }
    }

    @Test func transformAgainIdsMatchPhotocraft() throws {
        let s = Session()
        for id in ["edit.transform.again", "edit.transform.againCopy"] {
            let spec = try #require(s.registry.spec(id))
            let pc = try #require(PhotocraftCatalog.byId[id])
            #expect(spec.isAvailable)
            #expect(spec.module == pc.module && spec.label == pc.label && spec.menu == pc.menu && spec.shortcut == pc.shortcut && spec.params == pc.params, "\(id)")
        }
    }

    // MARK: Guides

    @Test func guidesAreUndoable() throws {
        let s = try session()
        try s.execute("view.newGuide", ["orientation": "vertical", "position": 40])
        try s.execute("view.newGuide", ["orientation": "horizontal", "position": 12.5])
        try s.execute("view.moveGuide", ["orientation": "vertical", "index": 0, "position": 60])
        let g = try #require(s.active?.doc.guides)
        #expect(g.vertical == [60] && g.horizontal == [12.5])
        try s.execute("view.deleteGuide", ["orientation": "horizontal", "index": 0])
        s.undo()
        #expect(s.active?.doc.guides.horizontal == [12.5])
        try s.execute("view.clearGuides")
        #expect(s.active?.doc.guides.vertical.isEmpty == true)
        #expect(throws: (any Error).self) { try s.execute("view.moveGuide", ["orientation": "vertical", "index": 3, "position": 1]) }
    }

    func newGuide(_ s: Session, _ orientation: String, _ position: JSONValue) throws -> Double {
        try s.execute("view.newGuide", ["orientation": .string(orientation), "position": position])
        let g = try #require(s.active?.doc.guides)
        return try #require(orientation == "vertical" ? g.vertical.last : g.horizontal.last)
    }

    @Test func guidePositionsTakePhotoshopUnits() throws {
        let s = Session()
        // 4 × 2 inches at 100 ppi.
        try s.execute("file.new", ["width": 400, "height": 200, "resolution": 100])
        #expect(try newGuide(s, "vertical", "50%") == 200)
        #expect(try newGuide(s, "horizontal", "50%") == 100)
        for oneInch in ["1in", "1 in", "2.54cm", "25.4 mm", "72pt", "6pc", "100px", "100", "1,0 inch"] {
            #expect(abs(try newGuide(s, "vertical", .string(oneInch)) - 100) < 1e-3, "\(oneInch)")
        }
        #expect(try newGuide(s, "horizontal", "12.5px") == 12.5)
        #expect(try newGuide(s, "vertical", "-10px") == -10)
        #expect(try newGuide(s, "vertical", 40) == 40)
        // Points and picas follow Units & Rulers › Point Size.
        try s.execute("prefs.set", ["path": "unitsAndRulers.pointSize", "value": "traditional"])
        #expect(abs(try newGuide(s, "vertical", "72.27pt") - 100) < 1e-3)
        try s.execute("view.moveGuide", ["orientation": "horizontal", "index": 0, "position": "25%"])
        #expect(s.active?.doc.guides.horizontal.first == 50)
    }

    @Test func newGuidesKeepTheirOwnColourThroughMovesDeletesAndUndo() throws {
        let s = Session()
        try s.execute("file.new", ["width": 400, "height": 200])
        func color(_ vertical: Bool, _ p: Double) -> SIMD3<UInt8>? { s.active?.doc.guides.color(vertical: vertical, position: p) }
        try s.execute("view.newGuide", ["orientation": "vertical", "position": 10])
        #expect(color(true, 10) == nil)
        #expect(s.active?.doc.guides.colors.isEmpty == true)
        try s.execute("view.newGuide", ["orientation": "vertical", "position": 20, "color": "magenta"])
        try s.execute("view.newGuide", ["orientation": "horizontal", "position": 20, "color": "#123456"])
        try s.execute("view.newGuide", ["orientation": "vertical", "position": 30, "color": "LightBlue"])
        #expect(color(true, 20) == SIMD3(0xff, 0x00, 0xff))
        #expect(color(false, 20) == SIMD3(0x12, 0x34, 0x56), "the same position across is a different guide")
        #expect(color(true, 30) == SIMD3(0x33, 0x66, 0xff), "names are case-insensitive")
        try s.execute("view.moveGuide", ["orientation": "vertical", "index": 1, "position": 25])
        #expect(color(true, 20) == nil && color(true, 25) == SIMD3(0xff, 0x00, 0xff))
        s.undo()
        #expect(color(true, 20) == SIMD3(0xff, 0x00, 0xff) && color(true, 25) == nil)
        try s.execute("view.deleteGuide", ["orientation": "vertical", "index": 2])
        #expect(color(true, 30) == nil)
        #expect(s.active?.doc.guides.colors.count == 2)
        try s.execute("view.clearGuides")
        #expect(s.active?.doc.guides.colors.isEmpty == true)
    }

    @Test func movingOneOfTwoColouredGuidesAtOnePositionLeavesTheOtherItsColour() throws {
        let s = Session()
        try s.execute("file.new", ["width": 400, "height": 200])
        for _ in 0..<2 { try s.execute("view.newGuide", ["orientation": "vertical", "position": 50, "color": "green"]) }
        try s.execute("view.moveGuide", ["orientation": "vertical", "index": 0, "position": 60])
        let g = try #require(s.active?.doc.guides)
        #expect(g.color(vertical: true, position: 50) == SIMD3(0x33, 0xff, 0x33) && g.color(vertical: true, position: 60) == SIMD3(0x33, 0xff, 0x33))
    }

    @Test func cyanIsTheDefaultGuideColourSoRulerGuidesReadAsCyan() throws {
        let def = try #require(Preferences()["guidesGridAndSlices.guideColor"]?.stringValue)
        let cyan = EditCommands.guideColors.first { $0.0 == "cyan" }?.1
        #expect(cyan == EditCommands.parseHexRGB(def))
    }

    @Test func badGuideColoursAreRefusedWithoutAGuide() throws {
        let s = Session()
        try s.execute("file.new", ["width": 400, "height": 200])
        let undoBefore = s.active?.history.canUndo
        for bad: JSONValue in ["puce", "#12345", "#gggggg", "", 7, .null, ["cyan"]] {
            #expect(throws: (any Error).self, "\(bad.serialized())") {
                try s.execute("view.newGuide", ["orientation": "vertical", "position": 10, "color": bad])
            }
        }
        let g = try #require(s.active?.doc.guides)
        #expect(g.vertical.isEmpty && g.colors.isEmpty)
        #expect(s.active?.history.canUndo == undoBefore)
    }

    @Test func badGuidePositionsAreRefusedWithoutAGuide() throws {
        let s = Session()
        try s.execute("file.new", ["width": 400, "height": 200, "resolution": 100])
        let undoBefore = s.active?.history.canUndo
        for bad: JSONValue in ["abc", "50 furlongs", "", "%", "NaN", "inf", "1e400", "2000000px", 1e300, true, [1]] {
            #expect(throws: (any Error).self, "\(bad.serialized())") { try s.execute("view.newGuide", ["orientation": "vertical", "position": bad]) }
        }
        #expect(throws: (any Error).self, "no position") { try s.execute("view.newGuide", ["orientation": "vertical"]) }
        let g = try #require(s.active?.doc.guides)
        #expect(g.vertical.isEmpty && g.horizontal.isEmpty)
        #expect(s.active?.history.canUndo == undoBefore, "a refused guide records no history step")
    }

    /// Guides keep their exact place (#2918): 1 cm at 300 ppi through New Guide and .pcraft, and
    /// a 1/32 px PSD position past 2^19 px, where Float has no 1/32 steps left.
    @Test func guidesKeepSubPixelPositionsThroughPcraftAndPsd() throws {
        let (cm, far) = (300.0 / 2.54, 600_000.031_25)
        let s = try session()
        try s.execute("view.newGuide", ["orientation": "horizontal", "position": .number(cm)])
        try s.execute("view.newGuide", ["orientation": "vertical", "position": .number(far)])
        let doc = try #require(s.active?.doc)
        #expect(doc.guides.horizontal.first == cm && doc.guides.vertical.first == far)
        let back = try PcraftFormat.load(try PcraftFormat.save(doc)).guides
        #expect(back.horizontal.first == cm && back.vertical.first == far)
        let psd = try EngineIO.export(doc, as: "psd", services: s.services).bytes
        let fromPSD = try EngineIO.importFile(name: "g.psd", bytes: psd, services: s.services).document.guides
        #expect(fromPSD.vertical.first == far, "1032 stores 1/32 px")
    }

    /// Every id of edit_cmds, extra_cmds and fill_key_cmds (and edit.fill) is registered with
    /// photocraft's label, menu path, shortcut and params notation.
    @Test func registeredWithPhotocraftsMetadata() {
        let r = CommandRegistry.standard()
        let mine = PhotocraftCatalog.commands.filter { ["edit_cmds", "extra_cmds", "fill_key_cmds"].contains($0.module) || $0.id == "edit.fill" }
        #expect(mine.count == 58)
        for c in mine {
            guard let spec = r.spec(c.id) else { Issue.record("\(c.id) not registered"); continue }
            #expect(spec.label == c.label && spec.menu == c.menu && spec.shortcut == c.shortcut, "\(c.id)")
            // The catalogue's scanner couldn't expand Paste Into's `concat!` params.
            if !c.params.contains("see photocraft source") { #expect(spec.params == c.params, "\(c.id): \(spec.params)") }
        }
    }

    // MARK: Channel clipboard (channel_clip/tests.rs)

    static let w: Int32 = 40, h: Int32 = 20

    /// A white document whose left half is #336699: red 0.2, green 0.4, blue 0.6 there.
    func channelSession(_ depth: Int) throws -> Session {
        let s = Session()
        try s.execute("file.new", ["width": .int(Int(Self.w)), "height": .int(Int(Self.h)), "depth": .int(depth)])
        try s.execute("select.rect", ["x": 0, "y": 0, "width": .int(Int(Self.w / 2)), "height": .int(Int(Self.h))])
        try s.execute("edit.fill", ["color": "#336699"])
        try s.execute("select.deselect")
        return s
    }

    func target(_ s: Session, _ t: ChannelTarget) throws { try s.updateActive { $0.channelView.target = t } }

    func px(_ s: Session, _ x: Int32, _ y: Int32) -> [Float] {
        guard let st = s.active, let id = st.activeLayer else { return [] }
        return st.doc.layer(id)?.surface?.pixel(x: x, y: y) ?? []
    }

    func near(_ a: [Float], _ b: [Float]) -> Bool { a.count == b.count && zip(a, b).allSatisfy { abs($0 - $1) < 1e-3 } }

    @Test func copyRedPasteIntoBlue() throws {
        for depth in [8, 16, 32] {
            let s = try channelSession(depth)
            let (left, right) = (px(s, 5, 5), px(s, 30, 5))
            try target(s, .color(0))
            try s.execute("edit.copy")
            let c = try #require(clip(s))
            #expect(c.surface.format.mode == .grayscale, "depth \(depth): a channel copies as grayscale")
            #expect(c.bounds == PixelRect(x0: 0, y0: 0, x1: Self.w, y1: Self.h), "no selection: the whole channel")
            let n = s.active?.doc.walk().count
            try target(s, .color(2))
            try s.execute("edit.paste")
            #expect(s.active?.doc.walk().count == n, "depth \(depth): no new layer")
            #expect(near(px(s, 5, 5), [left[0], left[1], left[0], 1]), "depth \(depth): blue = old red, \(px(s, 5, 5))")
            #expect(near(px(s, 30, 5), right))
            #expect(s.active?.doc.selection == nil)
            s.undo()
            #expect(near(px(s, 5, 5), left), "depth \(depth): one undoable step")
        }
    }

    @Test func alphaChannelsCopyAndPasteIntoColourChannels() throws {
        let s = try channelSession(8)
        // Alpha 1: white on the top half.
        try s.edit("New Channel") { doc, _ in
            var surf = Surface(format: Channels.channelFormat(doc))
            surf.fill(PixelRect(x0: 0, y0: 0, x1: Self.w, y1: Self.h / 2), with: [1])
            doc.channels.append(AlphaChannel(name: "Alpha 1", surface: surf))
        }
        try target(s, .alpha(0))
        try s.execute("edit.copy")
        let c = try #require(clip(s)).surface
        #expect(c.pixel(x: 30, y: 2) == [1, 1] && c.pixel(x: 30, y: 15) == [0, 1], "the alpha channel's values")
        try target(s, .color(1))
        try s.execute("edit.paste")
        #expect(near(px(s, 30, 2), [1, 1, 1, 1]))
        #expect(near(px(s, 30, 15), [1, 0, 1, 1]), "green = Alpha 1, \(px(s, 30, 15))")
        // With the composite targeted, Paste still makes a layer (grey, from the grayscale clip).
        try target(s, .composite)
        let n = s.active?.doc.walk().count ?? 0
        try s.execute("edit.paste")
        #expect(s.active?.doc.walk().count == n + 1)
        #expect(near(px(s, 30, 15), [0, 0, 0, 1]))
    }

    @Test func copyAnAlphaChannelWithoutAPixelLayer() throws {
        let s = try channelSession(8)
        try addChannel(s, fill: 1)
        try target(s, .alpha(0))
        try s.edit("no pixel layer") { _, active in active = nil }
        #expect(s.isEnabled("edit.copy"), "an alpha channel needs no pixel layer")
        try s.execute("edit.copy")
        #expect(clip(s)?.surface.pixel(x: 3, y: 3) == [1, 1])
    }

    @Test func pasteIntoAColourChannelKeepsToTheSelection() throws {
        let s = try channelSession(16)
        try s.execute("select.rect", ["x": 0, "y": 0, "width": 10, "height": .int(Int(Self.h))])
        try target(s, .color(0))
        try s.execute("edit.copy")
        try target(s, .color(1))
        let n = s.active?.doc.walk().count
        try s.execute("edit.pasteSpecial.pasteInto")
        #expect(s.active?.doc.walk().count == n, "no new layer or mask")
        let (inside, outside) = (px(s, 5, 5), px(s, 15, 5))
        #expect(near(inside, [0.2, 0.2, 0.6, 1]), "green = red inside, \(inside)")
        #expect(near(outside, [0.2, 0.4, 0.6, 1]), "untouched outside, \(outside)")
    }

    @Test func copyingAndPastingChannelsFailCleanly() throws {
        let s = try channelSession(8)
        try target(s, .color(0))
        // An empty selection copies nothing and leaves the clipboard alone.
        try s.edit("empty selection") { doc, _ in doc.selection = Surface(format: .gray8) }
        #expect(throws: (any Error).self) { try s.execute("edit.copy") }
        #expect(clip(s) == nil)
        // A pixel-locked layer refuses the paste and keeps its pixels.
        try s.execute("select.deselect")
        try s.execute("edit.copy")
        let id = try #require(s.active?.activeLayer)
        try s.edit("lock") { doc, _ in doc.updateLayer(id) { $0.locks.pixels = true } }
        let before = px(s, 5, 5)
        try target(s, .color(2))
        #expect(throws: (any Error).self) { try s.execute("edit.paste") }
        #expect(px(s, 5, 5) == before)
    }

    @Test func cutAColourChannelClearsOnlyThatChannel() throws {
        let s = try channelSession(8)
        let (left, right) = (px(s, 5, 5), px(s, 30, 5))
        s.tools.background = SIMD4(0.8, 0.1, 0.9, 1)
        try target(s, .color(0))
        try s.execute("select.rect", ["x": 2, "y": 2, "width": 10, "height": 10])
        try s.execute("edit.cut")
        let c = try #require(clip(s))
        #expect(c.surface.format.mode == .grayscale, "the red channel copies as grayscale")
        #expect(near(c.surface.pixel(x: 5, y: 5), [left[0], 1]), "the clip holds the old red, \(c.surface.pixel(x: 5, y: 5))")
        // Red takes the background colour's red; green, blue and transparency stay.
        #expect(abs(px(s, 5, 5)[0] - 0.8) < 2.0 / 255 && near(Array(px(s, 5, 5).dropFirst()), Array(left.dropFirst())), "\(px(s, 5, 5))")
        #expect(near(px(s, 15, 5), left), "outside the selection")
        #expect(near(px(s, 30, 5), right))
        s.undo()
        #expect(near(px(s, 5, 5), left), "one undoable step")
    }
}
