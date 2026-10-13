// Port of photocraft-engine (crates/engine/src/tests.rs), MIT OR Apache-2.0, © ArtCraft Team and the PhotoCraft contributors.
//
// The core tests that drive several modules at once (Fill, brush strokes, paths, Float, type,
// pattern fills, effects): ported once every module they use was.

import Foundation
@testable import PCEngine
import PCDocument
import PCFoundation
import Testing

@Suite struct CrossModuleTests {
    func layer(_ s: Session, _ id: LayerId) throws -> Layer { try #require(s.active?.doc.layer(id)) }

    func activeId(_ s: Session) throws -> LayerId { try #require(s.active?.activeLayer) }

    @Test func invalidFileNewLeavesAFloatingSelectionUncommitted() throws {
        let s = try sessionWithDoc()
        try s.execute("select.rect", ["x": 0, "y": 0, "width": 4, "height": 4])
        try s.execute("select.float", ["dx": 8])
        let original = try #require(s.active).doc
        let history = try #require(s.active).history.entries
        #expect(throws: EngineError.self) { try s.execute("file.new", ["depth": 12]) }
        #expect(FloatCommands.floating(try #require(s.active)) != nil)
        #expect(s.active?.doc == original)
        #expect(s.active?.history.entries == history)
        #expect(s.documents.count == 1)
    }

    @Test func patternFillLayersAreMaskedByTheSelectionOrRevealAll() throws {
        for depth in [8, 16, 32] {
            let s = Session()
            try s.execute("file.new", ["width": 64, "height": 48, "depth": .int(depth)])
            try s.execute("select.rect", ["x": 8, "y": 8, "width": 16, "height": 16])
            let masked = try layerResult(try s.execute("layer.newFillLayer.pattern", ["pattern": "Checkerboard"]))
            let mask = try #require(try layer(s, masked).mask, "pattern fill at \(depth)-bit: no layer mask")
            #expect(mask.value(x: 10, y: 10) == 1 && mask.value(x: 2, y: 2) == 0)
            #expect(mask.linked && mask.enabled)
            #expect(try px(s, 2, 2) == [1, 1, 1, 1])
            try s.execute("edit.undo")
            #expect(s.active?.doc.layer(masked) == nil)
            try s.execute("select.deselect")
            let history = try #require(s.active).history.entries.count
            let all = try layerResult(try s.execute("layer.newFillLayer.pattern", ["pattern": "Checkerboard"]))
            let m = try #require(try layer(s, all).mask)
            #expect(m.enabled && m.linked && m.surface.tileCount == 0)
            for (x, y): (Int32, Int32) in [(0, 0), (63, 47), (-1, -1), (300_000, 300_000)] { #expect(m.value(x: x, y: y) == 1) }
            #expect(s.active?.history.entries.count == history + 1)
        }
    }

    @Test func newFillAndAdjustmentLayersTakeTheActivePathAsTheirVectorMask() throws {
        // #1419: the path selected in the Paths panel becomes the vector mask of a new fill or
        // adjustment layer and wins over a selection.
        let square: JSONValue = ["subpaths": [["closed": true, "knots": [[8, 8], [24, 8], [24, 24], [8, 24]]]]]
        let rows: [(String, JSONValue, Bool)] = [
            ("layer.newFillLayer.solidColor", ["color": "#000000"], true),
            ("layer.newFillLayer.gradient", ["from": "#000000", "to": "#000000"], true),
            ("layer.newFillLayer.pattern", ["pattern": "Checkerboard"], false),
            ("layer.newAdjustmentLayer.invert", .object([:]), true),
        ]
        for depth in [8, 16, 32] {
            for (id, params, blackens) in rows {
                for name in ["work", "Saved"] {
                    let s = Session()
                    try s.execute("file.new", ["width": 64, "height": 48, "depth": .int(depth)])
                    try s.execute("path.set", ["name": .string(name), "path": square])
                    // A selection elsewhere: the path wins, as in Photoshop.
                    try s.execute("select.rect", ["x": 40, "y": 30, "width": 8, "height": 8])
                    let l = try layerResult(try s.execute(id, params.setting("path", .string(name))))
                    let d = try #require(s.active)
                    let made = try layer(s, l)
                    let vm = try #require(made.vectorMask, "\(id) (\(name)) at \(depth)-bit: no vector mask")
                    let want = name == "work" ? d.doc.workPath : d.doc.paths.first?.path
                    #expect(vm.path == want, "\(id): the vector mask is the path")
                    #expect(made.mask == nil, "\(id): the path wins over the selection")
                    for (x, y) in [(2, 2), (42, 32), (30, 30)] {
                        #expect(try px(s, x, y) == [1, 1, 1, 1], "\(id) (\(name)) at \(depth)-bit changed pixels outside the path at (\(x), \(y))")
                    }
                    if blackens { #expect(try px(s, 16, 16)[..<3] == [0, 0, 0], "\(id) (\(name)) at \(depth)-bit: no effect inside the path") }
                    try s.execute("edit.undo")
                    #expect(s.active?.doc.layer(l) == nil, "\(id): undo keeps the layer")
                }
            }
        }
    }

    @Test func newFillLayerWithAMissingPathFailsWithoutALayer() throws {
        let s = try sessionWithDoc()
        let before = try #require(s.active).doc.layers.count
        let rows: [(String, JSONValue)] = [
            ("layer.newFillLayer.solidColor", ["path": "work"]),
            ("layer.newFillLayer.solidColor", ["path": "Nope"]),
            ("layer.newFillLayer.gradient", ["path": "Nope"]),
            ("layer.newFillLayer.pattern", ["pattern": "Checkerboard", "path": "Nope"]),
            ("layer.newAdjustmentLayer.invert", ["path": "Nope"]),
            ("layer.newFillLayer.solidColor", ["path": 42]),
            ("layer.newFillLayer.solidColor", ["path": ["subpaths": "x"]]),
        ]
        for (id, params) in rows {
            #expect(throws: EngineError.self, "\(id) \(params): no error") { try s.execute(id, params) }
            #expect(s.active?.doc.layers.count == before, "\(id) \(params): added a layer")
        }
    }

    @Test func undoAndRedoRestoreTheTargetedLayers() throws {
        // #495: each history state brings back the layers it targeted when it was created.
        let s = try sessionWithDoc()
        func target() throws -> (LayerId, [LayerId]) { let st = try #require(s.active); return (try #require(st.activeLayer), st.selectedLayers) }
        func select(_ id: LayerId, _ mode: String) throws {
            let steps = pastCount(s)
            try s.execute("layer.select", ["layer": .id(id), "mode": .string(mode)])
            #expect(pastCount(s) == steps, "selecting is not a step")
        }
        let bg = try target().0
        try s.execute("layer.new.layer")
        let new = try target().0
        #expect(s.undo())
        #expect(try target() == (bg, [bg]), "the new document's target")
        #expect(s.redo())
        #expect(try target() == (new, [new]), "redo targets the new layer again")
        // So Fill paints the new layer, not the background.
        try s.execute("edit.fill", ["color": "#ff0000"])
        #expect(try layer(s, new).surface?.contentBounds.isEmpty == false)
        #expect(try layer(s, bg).surface?.pixel(x: 5, y: 5) == [1, 1, 1, 1], "the background is untouched")
        // Selecting another layer doesn't change what a state targets.
        try select(bg, "replace")
        #expect(s.undo())
        #expect(try target() == (new, [new]))
        try select(bg, "replace")
        #expect(s.redo())
        #expect(try target() == (new, [new]), "redo targets the filled layer")
        // Undoing a delete targets the restored layer.
        try s.execute("layer.delete")
        #expect(try target().0 == bg)
        #expect(s.undo())
        #expect(try target() == (new, [new]))
        // A multi-layer target comes back too.
        try select(bg, "add")
        try s.execute("select.all")
        try s.execute("layer.new.layer")
        #expect(s.undo())
        #expect(try target() == (bg, [bg, new]))
        // ...and the copies a multi-layer duplicate selects after its edit.
        try s.execute("layer.duplicate")
        let copies = try target()
        #expect(copies.1.count == 2)
        try select(bg, "replace")
        #expect(s.undo())
        #expect(s.redo())
        #expect(try target() == copies)
    }

    @Test func fillClearAndMasks() throws {
        let s = try sessionWithDoc()
        try s.execute("layer.new.layer")
        try s.execute("edit.fill", ["color": "#00ff00"])
        #expect(try px(s, 5, 5) == [0, 1, 0, 1])
        try s.execute("layer.layerMask.hideAll")
        #expect(try px(s, 5, 5) == [1, 1, 1, 1])
        try s.execute("layer.layerMask.delete")
        try s.execute("select.rect", ["x": 0, "y": 0, "width": 10, "height": 10])
        try s.execute("edit.clear")
        #expect(try px(s, 5, 5) == [1, 1, 1, 1])
        #expect(try px(s, 20, 20) == [0, 1, 0, 1])
    }

    @Test func clippingAndMergeAndFlatten() throws {
        let s = try sessionWithDoc()
        try s.execute("layer.new.layer")
        try s.execute("select.rect", ["x": 0, "y": 0, "width": 10, "height": 48])
        try s.execute("edit.fill", ["color": "#ff0000"])
        try s.execute("select.deselect")
        try s.execute("layer.new.layer")
        try s.execute("edit.fill", ["color": "#0000ff"])
        try s.execute("layer.createClippingMask")
        #expect(try px(s, 5, 5) == [0, 0, 1, 1])
        #expect(try px(s, 30, 5) == [1, 1, 1, 1])
        try s.execute("layer.mergeDown")
        #expect(s.active?.doc.layerCount == 2)
        #expect(try px(s, 5, 5) == [0, 0, 1, 1])
        #expect(try px(s, 30, 5) == [1, 1, 1, 1])
        try s.execute("layer.flattenImage")
        #expect(s.active?.doc.layerCount == 1)
        #expect(try px(s, 5, 5) == [0, 0, 1, 1])
    }

    @Test func canvasFlipsAndRotation() throws {
        let s = Session()
        try s.execute("file.new", ["width": 10, "height": 4])
        try s.execute("select.rect", ["x": 0, "y": 0, "width": 2, "height": 1])
        try s.execute("edit.fill", ["color": "#ff0000"])
        try s.execute("select.deselect")
        try s.execute("image.imageRotation.flipCanvasHorizontal")
        #expect(try px(s, 9, 0) == [1, 0, 0, 1])
        #expect(try px(s, 0, 0) == [1, 1, 1, 1])
        try s.execute("image.imageRotation.flipCanvasVertical")
        #expect(try px(s, 9, 3) == [1, 0, 0, 1])
        try s.execute("image.imageRotation.90cw")
        #expect(s.active?.doc.size == PixelSize(width: 4, height: 10))
        #expect(try px(s, 0, 9) == [1, 0, 0, 1])
        try s.execute("image.imageRotation.90ccw")
        try s.execute("image.imageRotation.180")
        #expect(try px(s, 0, 0) == [1, 0, 0, 1])
    }

    @Test func fillLayerPixelRewritesRefreshTheEffectMaps() throws {
        // A pixel-only rewrite of a fill layer's cache leaves the Fill spec alone; the effect maps
        // must follow the cache surface. Warm render vs. purged render must agree.
        let s = Session()
        try s.execute("file.new", ["width": 64, "height": 48])
        try s.execute("layer.newFillLayer.gradient", ["from": "#000000", "to": "#ffffff", "angle": 0])
        try s.edit("shadow") { doc, active in _ = doc.updateLayer(active!) { $0.effects.items.append(Effect.defaultDropShadow()) } }
        func render() throws -> [SIMD4<Float>] { let d = try #require(s.active); return try s.services.renderer.render(d.doc, region: d.doc.bounds).px }
        try s.edit("cache") { doc, active in
            let fmt = doc.pixelFormat
            _ = try doc.updateLayer(active!) { l in
                guard case .fill(let f) = l.content else { throw EngineError.other("not a fill layer") }
                var surface = Surface(format: fmt)
                surface.fill(PixelRect(x0: 8, y0: 8, x1: 30, y1: 40), with: [0, 0, 1, 1])
                l.fillCache = FillCache(fill: f, surface: surface)
            }
        }
        let warm = try render()
        #expect(try render() == warm, "a warm cache does not change the composite")
        try s.edit("shift") { doc, active in
            _ = doc.updateLayer(active!) { l in
                guard var fc = l.fillCache else { return }
                fc.surface = fc.surface.shifted(dx: 12, dy: 0)
                l.fillCache = fc
            }
        }
        let after = try render()
        #expect(after != warm, "the rewritten cache changes the composite")
        s.services.renderer.purge()
        #expect(try render() == after, "the effect maps track the cache surface, not the Fill spec alone")
    }

    @Test func groupEffectMapsFollowChildVisibilityAndOpacity() throws {
        let s = Session()
        try s.execute("file.new", ["width": 64, "height": 48, "background": "transparent"])
        let a = try newLayer(s)
        try s.execute("paint.pencil", ["points": [[20, 24]], "size": 12, "color": "#ff0000"])
        let b = try newLayer(s)
        try s.execute("paint.pencil", ["points": [[44, 24]], "size": 12, "color": "#0000ff"])
        let g = try layerResult(try s.execute("layer.new.group"))
        for l in [a, b] { try s.execute("layer.moveTo", ["layer": .id(l), "target": .id(g), "position": "into"]) }
        try s.edit("shadow") { doc, _ in _ = doc.updateLayer(g) { $0.effects.items.append(Effect.defaultDropShadow()) } }
        func render() throws -> [SIMD4<Float>] { let d = try #require(s.active); return try s.services.renderer.render(d.doc, region: d.doc.bounds).px }
        var prev = try render()
        let edits: [(String, LayerId, @Sendable (inout Layer) -> Void)] = [("hide", a, { $0.visible = false }), ("opacity", b, { $0.opacity = 0.3 })]
        for (name, child, edit) in edits {
            try s.edit(name) { doc, _ in _ = doc.updateLayer(child, edit) }
            let warm = try render()
            #expect(warm != prev, "\(name): the composite changes")
            s.services.renderer.purge()
            #expect(try render() == warm, "\(name): the group's maps follow its children")
            prev = warm
        }
    }

    /// With no document open, a document command says so instead of only `enabled: false` (#3664).
    @Test func commandListTellsNoDocumentFromOtherPreconditions() throws {
        let s = Session()
        let list = try #require(try s.execute("command.list").arrayValue)
        func find(_ l: [JSONValue], _ id: String) throws -> JSONValue { try #require(l.first { $0["id"] == .string(id) }) }
        for id in ["paint.stroke", "layer.new.layer", "filter.blur.gaussianBlur"] {
            let c = try find(list, id)
            #expect(c["enabled"] == false && c["needsDocument"] == true, "\(id): \(c)")
            #expect(c["disabledReason"]?.stringValue?.hasPrefix("no document") == true, "\(id): \(c)")
        }
        let new = try find(list, "file.new")
        #expect(new["enabled"] == true && new["needsDocument"] == false && new["disabledReason"] == .null)
        // A precondition that isn't the missing document keeps its own reason.
        let paste = try find(list, "file.newFromClipboard")
        #expect(paste["enabled"] == false && paste["needsDocument"] == false)
        #expect(paste["disabledReason"] == "the clipboard is empty")
        // With a document, the same commands run; a missing selection is not a missing document.
        let s2 = try sessionWithDoc()
        let list2 = try #require(try s2.execute("command.list").arrayValue)
        #expect(try find(list2, "paint.stroke")["needsDocument"] == false)
        #expect(try find(list2, "paint.stroke")["disabledReason"] == .null)
        let deselect = try find(list2, "select.deselect")
        #expect(deselect["enabled"] == false && deselect["needsDocument"] == false && deselect["disabledReason"] == "no selection")
    }

    @Test func translateMovesPixelsAndRespectsLocks() throws {
        let s = try sessionWithDoc()
        try s.execute("layer.new.layer")
        try s.execute("select.rect", ["x": 0, "y": 0, "width": 4, "height": 4])
        try s.execute("edit.fill", ["color": "#ff0000"])
        try s.execute("select.deselect")
        try s.execute("layer.translate", ["dx": 10, "dy": 5])
        #expect(try px(s, 11, 6) == [1, 0, 0, 1])
        #expect(try px(s, 1, 1) == [1, 1, 1, 1])
        // The Background is position-locked.
        try s.selectLayer(try #require(s.active).doc.layers[0].id)
        #expect(throws: EngineError.self) { try s.execute("layer.translate", ["dx": 1, "dy": 0]) }
    }

    @Test func editsThatChangeNoPixelsReportEmptyDamage() throws {
        // A new selection must not recomposite the canvas (#1773).
        let s = try sessionWithDoc()
        try s.execute("select.lasso", ["points": [[2, 2], [40, 3], [30, 30], [5, 25]], "mode": "replace"])
        #expect(s.active?.lastDamage == .empty)
        try s.execute("select.inverse")
        #expect(s.active?.lastDamage == .empty)
        try s.execute("select.deselect")
        #expect(s.active?.lastDamage == .empty)
        // A new empty layer draws nothing either (#1771); filling it does recomposite.
        try s.execute("layer.new.layer")
        #expect(s.active?.lastDamage == .empty)
        try s.execute("edit.fill", ["color": "#ff0000"])
        #expect(s.active?.lastDamage != .empty)
    }

    @Test func artboardFromLayersRefusesToNestPastTheGroupDepthCap() throws { try onLargeStack(Self.artboardDepthCapBody) }

    static func artboardDepthCapBody() throws {
        let s = try sessionWithDoc()
        var top = try newLayer(s, "Leaf")
        for _ in 0..<maxGroupDepthLimit { top = try layerResult(try s.execute("layer.groupLayers", ["layer": .id(top)])) }
        #expect(s.active?.doc.maxGroupDepth == maxGroupDepthLimit)
        try s.execute("layer.select", ["layer": .id(top)])
        let past = pastCount(s)
        do {
            try s.execute("layer.new.artboardFromLayers")
            Issue.record("nested past the cap")
        } catch { #expect("\(error)".contains("deeper than"), "\(error)") }
        #expect(s.active?.doc.maxGroupDepth == maxGroupDepthLimit)
        #expect(pastCount(s) == past, "no history step recorded")
    }

    /// ⌥-dragging a Layers panel row: `copy` leaves the layer where it is and drops a duplicate at
    /// the target, as one "Duplicate Layer" step, with the copy active.
    @Test func moveToCopyPlacesADuplicateInOneStep() throws {
        let s = try sessionWithDoc()
        let a = try newLayer(s, "A")
        try s.execute("edit.fill", ["contents": "color", "color": "#ff0000"])
        let b = try newLayer(s, "B")
        let g = try layerResult(try s.execute("layer.new.group", ["name": "G"]))
        let before = pastCount(s)
        let r = try s.execute("layer.moveTo", ["layer": .id(a), "target": .id(b), "position": "above", "copy": true])
        let copy = try layerResult(r)
        #expect(copy != a)
        #expect(names(s) == ["Background", "A", "B", "A copy", "G"])
        #expect(pastCount(s) == before + 1, "one history step")
        #expect(s.active?.history.undoLabel == "Duplicate Layer")
        #expect(s.active?.activeLayer == copy, "the copy is active")
        #expect(try layer(s, a).content == (try layer(s, copy).content), "the pixels are copied")
        try s.execute("layer.moveTo", ["layer": .id(b), "target": .id(a), "position": "below", "copy": true])
        #expect(names(s) == ["Background", "B copy", "A", "B", "A copy", "G"])
        try s.execute("layer.moveTo", ["layer": .id(a), "target": .id(g), "position": "into", "copy": true])
        #expect(try s.execute("document.inspect")["layers"]?[0]?["children"]?[0]?["name"] == "A copy 2")
        try s.execute("layer.moveTo", ["layer": .id(g), "target": .id(g), "position": "above", "copy": true])
        #expect(names(s).last == "G copy")
        let past = pastCount(s)
        #expect(throws: EngineError.self) { try s.execute("layer.moveTo", ["layer": .id(g), "target": .id(g), "position": "into", "copy": true]) }
        #expect(pastCount(s) == past, "a refused copy records nothing")
        let bg = try #require(s.active).doc.layers[0].id
        try s.execute("layer.moveTo", ["layer": .id(bg), "target": .id(b), "position": "above", "copy": true])
        let bgCopy = try #require(s.active?.doc.layers.first { $0.name == "Background copy" })
        #expect(!bgCopy.locks.transparency)
        #expect(s.active?.doc.layers[0].locks.transparency == true, "the Background keeps its lock")
        for _ in 0..<5 { try s.execute("edit.undo") }
        #expect(names(s) == ["Background", "A", "B", "G"])
    }

    @Test func typeEditRerendersCacheToNewText() throws {
        let s = Session()
        try s.execute("file.new", ["width": 800, "height": 400])
        let id = try layerResult(try s.execute("type.create", ["x": 50, "y": 200, "text": "Lorem Ipsum", "size": 48, "coalesce": "k"]))
        func width() throws -> Int { try #require(try layer(s, id).surface).contentBounds.width }
        let w0 = try width()
        try s.execute("type.edit", ["layer": .id(id), "replace": ["start": 0, "end": 11, "text": "Photocraft"], "coalesce": "k"])
        let w1 = try width()
        #expect(w0 > 150 && w1 > 150, "cache widths \(w0) → \(w1)")
    }

    @Test func adjustmentLayerDisabledDiagnosticsUseGrammaticalArticle() throws {
        let s = try sessionWithDoc()
        try s.execute("layer.newAdjustmentLayer.curves")
        for id in ["filter.blur.gaussianBlur", "image.adjustments.equalize", "edit.clear"] {
            do {
                try s.execute(id, id == "filter.blur.gaussianBlur" ? ["radius": 2] : .object([:]))
                Issue.record("\(id) ran on an adjustment layer")
            } catch {
                let e = "\(error)"
                #expect(e.contains("an Adjustment layer") && !e.contains("a Adjustment layer"), "\(id): \(e)")
            }
        }
    }

    @Test func deleteLayerNeighboursFollowGroupRowOrder() throws {
        let s = try sessionWithDoc()
        let background = try activeId(s)
        let lower = try newLayer(s, "Below group")
        let child = try newLayer(s, "Child")
        let group = try layerResult(try s.execute("layer.groupLayers", ["name": "Group"]))
        try s.execute("layer.select", ["layer": .id(child)])
        try s.execute("layer.delete")
        #expect(s.active?.activeLayer == lower, "the next row below a group's final child is outside the group")
        s.undo()
        try s.execute("layer.delete", ["layer": .id(background)])
        try s.execute("layer.setExpanded", ["layer": .id(group), "expanded": false])
        try s.execute("layer.select", ["layer": .id(lower)])
        try s.execute("layer.delete")
        #expect(s.active?.activeLayer == group, "fallback above uses the collapsed group header, not its hidden child")
    }

    @Test func mergeDownOnAGroupMergesTheGroup() throws {
        // #3832: with a group selected, Merge Down is Merge Group: the group's contents become one
        // layer in its place, named after it, and the layer below is untouched.
        let s = try sessionWithDoc()
        let below = try newLayer(s, "Below")
        try s.execute("edit.fill", ["color": "#00ff00"])
        let a = try newLayer(s, "A")
        try s.execute("select.rect", ["x": 0, "y": 0, "width": 10, "height": 48])
        try s.execute("edit.fill", ["color": "#ff0000"])
        try s.execute("select.deselect")
        let b = try newLayer(s, "B")
        try s.execute("select.rect", ["x": 20, "y": 0, "width": 10, "height": 48])
        try s.execute("edit.fill", ["color": "#0000ff"])
        try s.execute("select.deselect")
        try s.execute("layer.select", ["layer": .id(b)])
        try s.execute("layer.select", ["layer": .id(a), "mode": "add"])
        let group = try layerResult(try s.execute("layer.groupLayers", ["name": "Badge"]))
        _ = try? s.execute("layer.setProps", ["layer": .id(group), "opacity": 0.5])
        let before = [try px(s, 5, 5), try px(s, 25, 5), try px(s, 50, 5)]
        let layers = try #require(s.active).doc.layerCount
        try s.execute("layer.select", ["layer": .id(group)])
        try s.execute("layer.mergeLayers")
        let merged = try layer(s, try activeId(s))
        #expect(merged.name == "Badge")
        if case .raster = merged.content {} else { Issue.record("one pixel layer") }
        #expect(s.active?.doc.layer(below) != nil, "the layer below stays")
        #expect(s.active?.doc.layerCount == layers - 2, "group and its two layers became one")
        let after = [try px(s, 5, 5), try px(s, 25, 5), try px(s, 50, 5)]
        for (x, y) in zip(before, after) { #expect(zip(x, y).allSatisfy { abs($0 - $1) < 1.0 / 255 }, "\(before) -> \(after)") }
        try s.execute("edit.undo")
        #expect(s.active?.doc.layer(group) != nil)
    }
}
