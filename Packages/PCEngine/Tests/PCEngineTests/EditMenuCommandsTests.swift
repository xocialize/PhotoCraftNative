// Port of photocraft-engine (crates/engine/src/edit_menu_cmds/tests.rs), MIT OR Apache-2.0, © ArtCraft Team and the PhotoCraft contributors.
//
// photocraft's tests fill with `edit.fill` and make type layers with `type.create`, which other
// modules port; these use `image.adjustments.invert` (fadeable, like Fill), `path.fill` and type
// layers built directly. The Content-Aware Fill tests belong to PCIntelligence.

import Foundation
@testable import PCEngine
import PCDocument
import PCFoundation
import PCPaint
import Testing

fileprivate func session(_ depth: Int) throws -> Session {
    let s = Session()
    try s.execute("file.new", ["width": 64, "height": 48, "depth": .int(depth), "background": "white"])
    return s
}

fileprivate func px(_ s: Session, _ x: Int32, _ y: Int32) throws -> [Float] {
    let st = try #require(s.active)
    let id = try #require(st.activeLayer)
    return try #require(st.doc.layer(id)?.surface).pixel(x: x, y: y)
}

/// A type layer (photocraft's tests use `type.create`).
@discardableResult
fileprivate func addType(_ s: Session, _ text: String, y: Double) throws -> LayerId {
    try s.edit("New Type Layer") { doc, active -> LayerId in
        var t = TextLayer(text: text, sizePt: 12)
        t.transform = .translate(4, y)
        EditMenuCommands.refreshText(doc, &t)
        let id = doc.insertAbove(active, Layer(name: text, content: .text(t)))
        active = id
        return id
    }
}

fileprivate func texts(_ s: Session) throws -> [String] {
    try #require(s.active).doc.walk().compactMap { e in
        if case .text(let t) = e.layer.content { return t.text }
        return nil
    }
}

@Suite struct EditMenuCommandsTests {
    @Test func fadeBlendsLastStepAtAllDepths() throws {
        for depth in [8, 16, 32] {
            let s = try session(depth)
            #expect(!s.isEnabled("edit.fade"), "nothing to fade yet")
            try s.execute("image.adjustments.invert")
            #expect(s.isEnabled("edit.fade"))
            let label = try #require(s.active?.history.undoLabel)
            let undoSteps = try #require(s.active?.history.pastCount)
            try s.execute("edit.fade", ["opacity": 25])
            let v = try px(s, 5, 5)
            #expect(abs(v[0] - 0.75) < 0.01, "depth \(depth): \(v)")
            // One history step, labelled after the faded command, and Fade can't repeat.
            #expect(s.active?.history.pastCount == undoSteps + 1)
            #expect(s.active?.history.undoLabel == "Fade \(label)")
            #expect(!s.isEnabled("edit.fade"))
            s.undo()
            #expect(try px(s, 5, 5)[0] == 0)
        }
    }

    @Test func fadeWithBlendModeAndInvalidation() throws {
        let s = try session(8)
        try s.execute("path.set", ["name": "all", "path": ["subpaths": [["knots": [[0, 0], [64, 0], [64, 48], [0, 48]]]]]])
        try s.execute("path.fill", ["name": "all", "color": "#808080"])
        #expect(!s.isEnabled("edit.fade"), "Fill Path isn't fadeable")
        try s.execute("image.adjustments.invert")
        // Difference of grey and inverted grey at 100%: |0.502 − 0.498| ≈ 0.
        try s.execute("edit.fade", ["opacity": 100, "mode": "difference"])
        #expect(try px(s, 1, 1)[0] < 0.02)
        // Any other edit in between disables Fade.
        try s.execute("image.adjustments.invert")
        try s.execute("layer.new.layer")
        #expect(!s.isEnabled("edit.fade"))
        #expect(throws: EngineError.self) { try s.execute("edit.fade") }
        // Queries don't.
        try s.execute("image.adjustments.invert")
        try s.execute("document.inspect")
        #expect(s.isEnabled("edit.fade"))
        #expect(throws: EngineError.self) { try s.execute("edit.fade", ["mode": "nonsense"]) }
    }

    @Test func purgeCommands() throws {
        let s = try session(8)
        #expect(!s.isEnabled("edit.purge.undo"))
        #expect(s.isEnabled("edit.purge.videoCache"))
        try s.execute("edit.fill", ["color": "#000000"])
        try s.execute("edit.fill", ["color": "#ff0000"])
        let r = try s.execute("edit.purge.undo")
        #expect(r["purged"]?[0] == "undo")
        #expect((r["bytes"]?.uint64Value ?? 0) > 0)
        // One step left to undo (the black fill is gone from history).
        #expect(s.undo())
        #expect(!s.undo())
        try s.execute("select.all")
        try s.execute("edit.copy")
        #expect(s.isEnabled("edit.purge.clipboard"))
        try s.execute("edit.purge.clipboard")
        #expect(s.state[EditCommands.ClipboardKey.self] == nil)
        #expect(!s.isEnabled("edit.purge.clipboard"))
        try s.execute("file.new", ["width": 8, "height": 8])
        try s.execute("edit.fill", ["color": "#000000"])
        try s.execute("edit.purge.histories")
        #expect(s.documents.allSatisfy { !$0.history.canUndo })
        #expect(!s.isEnabled("edit.purge.histories"))
        #expect(try s.execute("edit.purge.videoCache")["bytes"] == 0)
        _ = try? s.execute("edit.purge.all")
    }

    @Test func deleteAndFillSelectionNeedsASelectionAndContentAwareFill() throws {
        let s = try session(8)
        try s.execute("select.rect", ["x": 26, "y": 16, "width": 12, "height": 14])
        let caf = try #require(s.registry.spec("edit.contentAwareFill"))
        if let why = caf.availability.reason {
            #expect(s.disabledReason("edit.deleteAndFillSelection") == why)
        } else {
            #expect(s.isEnabled("edit.deleteAndFillSelection"))
            let r = try s.execute("edit.deleteAndFillSelection", ["output": 7, "sampling": [1]])
            #expect(r["layer"]?.uint64Value == s.active?.activeLayer?.rawValue)
            #expect(s.active?.history.undoLabel == "Delete and Fill Selection")
        }
        try s.execute("select.deselect")
        #expect(s.disabledReason("edit.deleteAndFillSelection") == "make a selection around what to remove")
        #expect(throws: EngineError.self) { try s.execute("edit.deleteAndFillSelection") }
    }

    /// A new pixel layer on `s` painted by `body`.
    func paintLayer(_ s: Session, _ body: (inout Surface) -> Void) throws {
        try s.execute("layer.new.layer")
        try s.edit("paint") { doc, active in doc.withRaster(of: active!, body) }
    }

    func activeSurface(_ s: Session) throws -> Surface {
        let st = try #require(s.active)
        let id = try #require(st.activeLayer)
        return try #require(st.doc.layer(id)?.surface)
    }

    @Test func contentAwareScaleKeepsSubject() throws {
        for depth in [8, 16, 32] {
            let s = try session(depth)
            try paintLayer(s) { surf in
                surf.fill(PixelRect(x0: 0, y0: 0, x1: 64, y1: 48), with: [0.5, 0.5, 0.5, 1])
                for x in Int32(20)..<26 {
                    surf.fill(PixelRect(x0: x, y0: 0, x1: x + 1, y1: 48), with: x % 2 == 0 ? [1, 0, 0, 1] : [0, 0, 1, 1])
                }
            }
            let r = try s.execute("edit.contentAwareScale", ["width": 40])
            #expect(r["to"] == [40, 48])
            let surf = try activeSurface(s)
            #expect(surf.contentBounds == PixelRect(x0: 0, y0: 0, x1: 40, y1: 48), "depth \(depth)")
            let striped = (Int32(0)..<40).filter { x in
                let p = surf.pixel(x: x, y: 10)
                return p[1] < 0.05 && (p[0] > 0.95 || p[2] > 0.95)
            }
            #expect(striped.count == 6, "depth \(depth): the striped subject survives")
            #expect(s.undo())
            #expect(try activeSurface(s).contentBounds.width == 64)
        }
    }

    @Test func contentAwareScaleParams() throws {
        let s = try session(8)
        try paintLayer(s) { $0.fill(PixelRect(x0: 0, y0: 0, x1: 32, y1: 32), with: [0.8, 0.6, 0.5, 1]) }
        let r = try s.execute("edit.contentAwareScale", ["scaleX": 150, "scaleY": 50, "amount": 50, "protectSkinTones": true])
        #expect(r["to"] == [48, 16])
        #expect(throws: EngineError.self) { try s.execute("edit.contentAwareScale", ["width": 0]) }
        #expect(throws: EngineError.self) { try s.execute("edit.contentAwareScale", ["protect": "no such channel"]) }
        let spec = CommandRegistry.standard().spec("edit.contentAwareScale")
        #expect(spec?.module == "edit_menu_cmds" && spec?.shortcut == "Cmd+Alt+Shift+C" && spec?.availability == .available)
    }

    /// The transform box (#3096) moves the result with `x`/`y` and previews it on a reduced copy.
    @Test func contentAwareScalePlacesTheResultAndPreviewsItReduced() throws {
        for depth in [8, 16, 32] {
            let s = try session(depth)
            try paintLayer(s) { $0.fill(PixelRect(x0: 4, y0: 4, x1: 36, y1: 28), with: [0.2, 0.4, 0.6, 1]) }
            let p: JSONValue = ["width": 16, "height": 40, "x": 10, "y": 2]
            let preview = try EditMenuCommands.ContentAwareScalePreview(s, p, maxSide: 10)
            #expect(preview.region == PixelRect(x0: 4, y0: 4, x1: 36, y1: 28))
            let small = try preview.run(JobContext())
            #expect(small.contentBounds == PixelRect(x0: 0, y0: 0, x1: 4, y1: 10), "depth \(depth): the longest side, 40 px, previews at 10")
            let past = s.active!.history.pastCount
            let r = try s.execute("edit.contentAwareScale", p)
            #expect(r["bounds"] == [10, 2, 16, 40])
            #expect(try activeSurface(s).contentBounds == PixelRect(x: 10, y: 2, width: 16, height: 40), "depth \(depth)")
            #expect(s.active!.history.pastCount == past + 1, "depth \(depth): one step")
            for bad: JSONValue in [["x": "left"], ["y": 1e9]] {
                #expect(throws: EngineError.self, "\(bad)") { try s.execute("edit.contentAwareScale", bad) }
                #expect(throws: EngineError.self, "\(bad)") { try EditMenuCommands.ContentAwareScalePreview(s, bad, maxSide: 64) }
            }
        }
    }

    /// A 1 px wide (or tall) layer has no seam to spare: enlarging it repeats its single column (row).
    @Test func contentAwareScaleEnlargesAOnePixelLine() throws {
        let cases: [(PixelRect, JSONValue, [Int])] = [
            (PixelRect(x0: 10, y0: 0, x1: 11, y1: 48), ["width": 5], [5, 48]),
            (PixelRect(x0: 10, y0: 0, x1: 11, y1: 48), ["width": 6, "height": 30], [6, 30]),
            (PixelRect(x0: 0, y0: 7, x1: 64, y1: 8), ["height": 4], [64, 4]),
            (PixelRect(x0: 0, y0: 7, x1: 64, y1: 8), ["width": 20, "height": 3], [20, 3]),
        ]
        for (line, params, to) in cases {
            let s = try session(8)
            try paintLayer(s) { $0.fill(line, with: [1, 0, 0, 1]) }
            let r = try s.execute("edit.contentAwareScale", params)
            #expect(r["to"] == .array(to.map { .int($0) }), "\(params)")
            let b = try activeSurface(s).contentBounds
            #expect([b.width, b.height] == to, "\(params)")
            #expect(try px(s, b.x0 + Int32(b.width) - 1, b.y0 + Int32(b.height) - 1) == [1, 0, 0, 1], "\(params)")
        }
    }

    @Test func defineCustomShapeAndPresetManager() throws {
        let s = try session(8)
        #expect(!s.isEnabled("edit.defineCustomShape"))
        try s.edit("path") { doc, _ in doc.workPath = VectorPath([.polygon([(4, 4), (14, 4), (14, 14), (4, 14)])]) }
        try s.execute("edit.defineCustomShape", ["name": "Box"])
        try s.execute("edit.defineCustomShape")
        #expect(EditMenuCommands.customShapes(s).count == 2)
        #expect(EditMenuCommands.customShapes(s)[1].name == "Shape 2")
        let list = try s.execute("edit.presets.presetManager")
        #expect(list["customShapes"] == ["Box", "Shape 2"])
        #expect((list["brushes"]?.arrayValue?.count ?? 0) > 3)
        try s.execute("edit.presets.presetManager", ["action": "rename", "kind": "customShapes", "name": "Shape 2", "newName": "Star"])
        try s.execute("edit.presets.presetManager", ["action": "move", "kind": "customShapes", "index": 1, "to": 0])
        #expect(EditMenuCommands.customShapes(s)[0].name == "Star")
        try s.execute("edit.presets.presetManager", ["action": "delete", "kind": "customShapes", "name": "Box"])
        #expect(EditMenuCommands.customShapes(s).count == 1)
        #expect(throws: EngineError.self) { try s.execute("edit.presets.presetManager", ["action": "delete", "kind": "gradients", "index": 0]) }
        // Brushes: a renamed built-in becomes the user's preset.
        try s.execute("edit.presets.presetManager", ["action": "rename", "kind": "brushes", "index": 0, "newName": "First"])
        #expect(s.tools.presets[0].name == "First" && !s.tools.presets[0].builtin)
        // (The pattern library is managed through pattern_cmds' commands; without them it's empty.)
        if s.registry.spec("pattern.list")?.isAvailable != true { #expect(list["patterns"] == []) }
        // Export → import into a fresh session (photocraft saves "Mine" with brush.presets.save).
        s.tools.presets.append(BrushPreset(name: "Mine", brush: s.tools.brush))
        let out = try s.execute("edit.presets.exportImportPresets", ["action": "export"])
        #expect(out["brushes"] == 2, "built-ins are not exported by default (the renamed one is the user's now)")
        let t = Session()
        let r = try t.execute("edit.presets.exportImportPresets", ["action": "import", "data": .string(try #require(out["data"]).serialized())])
        #expect(r["brushes"]?.uint64Value == 2 && r["customShapes"]?.uint64Value == 1)
        #expect(t.tools.presets.contains { $0.name == "Mine" })
        #expect(EditMenuCommands.customShapes(t)[0].path == EditMenuCommands.customShapes(s)[0].path)
        #expect(throws: EngineError.self) { try t.execute("edit.presets.exportImportPresets", ["action": "import", "data": ["format": "other"]]) }
    }

    @Test func defineBrushPresetWrapsDefineFromSelection() throws {
        let s = try session(8)
        #expect(!s.isEnabled("edit.defineBrushPreset"))
        guard s.registry.spec("brush.defineFromSelection")?.isAvailable == true else { return }
        try s.execute("image.adjustments.invert")
        try s.execute("select.rect", ["x": 2, "y": 2, "width": 10, "height": 10])
        try s.execute("edit.defineBrushPreset")
        #expect(s.tools.presets.contains { $0.name == "Sampled Brush 1" })
    }

    @Test func findMatchesCases() {
        func f(_ t: String, _ q: String, _ c: Bool, _ w: Bool) -> [[Int]] {
            EditMenuCommands.findMatches(t, q, caseSensitive: c, wholeWord: w).map { [$0.0, $0.1] }
        }
        #expect(f("Cat cat CAT", "cat", false, false) == [[0, 3], [4, 7], [8, 11]])
        #expect(f("Cat cat CAT", "cat", true, false) == [[4, 7]])
        #expect(f("cat catalog bobcat", "cat", false, true) == [[0, 3]])
        #expect(f("Straße STRASSE", "straße", false, false) == [[0, 7]])
        #expect(f("abc", "", false, false).isEmpty)
    }

    @Test func findAndReplaceAcrossTypeLayers() throws {
        let s = try session(8)
        #expect(!s.isEnabled("edit.findAndReplaceText"))
        try addType(s, "Hello world", y: 20)
        try addType(s, "world peace, World", y: 40)
        let r = try s.execute("edit.findAndReplaceText", ["find": "world", "replace": "planet"])
        #expect(r["count"]?.uint64Value == 3 && r["layers"]?.uint64Value == 2)
        let ts = try texts(s)
        #expect(ts.contains("Hello planet"), "\(ts)")
        #expect(ts.contains("planet peace, planet"), "\(ts)")
        s.undo()
        // Step through matches: case-sensitive finds only lower-case "world".
        let f1 = try s.execute("edit.findAndReplaceText", ["find": "world", "action": "find", "caseSensitive": true])
        #expect(f1["found"]?["text"] == "world")
        let f2 = try s.execute("edit.findAndReplaceText", ["find": "world", "action": "changeFind", "replace": "Earth", "caseSensitive": true])
        #expect(f2["changed"]?.objectValue != nil)
        #expect(f2["found"]?["text"] == "world")
        #expect(f2["found"]?["layer"] != f2["changed"]?["layer"])
        #expect(throws: EngineError.self) { try s.execute("edit.findAndReplaceText", ["find": ""]) }
    }

    /// #703: `allLayers: false` with a raster layer active leaves nothing to search.
    @Test func findInTheActiveLayerFindsNothingWhenItIsNotType() throws {
        let s = try session(8)
        let id = try addType(s, "abc def", y: 12)
        try s.execute("layer.new.layer", ["name": "raster"])
        let steps = s.active?.history.entries.count
        for action in ["find", "change", "changeFind"] {
            for forward in [true, false] {
                let r = try s.execute("edit.findAndReplaceText", ["find": "abc", "replace": "x", "allLayers": false, "action": .string(action), "forward": .bool(forward)])
                #expect(r["found"] == .null && r["changed"] == .null, "\(action) \(forward): \(r)")
            }
        }
        let r = try s.execute("edit.findAndReplaceText", ["find": "abc", "replace": "x", "allLayers": false])
        #expect(r["count"]?.uint64Value == 0)
        #expect(s.active?.history.entries.count == steps)
        // With the type layer active, the same search finds it.
        try s.execute("layer.select", ["layer": .id(id)])
        let f = try s.execute("edit.findAndReplaceText", ["find": "abc", "allLayers": false, "action": "find"])
        #expect(f["found"]?["layer"]?.uint64Value == id.rawValue && f["found"]?["text"] == "abc")
    }

    @Test func replaceTextKeepsStylesAroundTheEdit() {
        var t = TextLayer(text: "Hello world", sizePt: 12)
        var bold = CharStyle()
        bold.weight = 700
        t.runs = [TextRun(len: 6, style: CharStyle()), TextRun(len: 5, style: bold)]
        // Inside the bold run: the new text is bold.
        EditMenuCommands.replaceText(&t, 7, 9, "XYZ")
        #expect(t.text == "Hello wXYZld")
        #expect(t.runs.map(\.len) == [6, 6])
        #expect(t.runs.last?.style.weight == 700)
        // At a run boundary the text joins the run before it (photocraft `replace_text`).
        EditMenuCommands.replaceText(&t, 6, 6, "+")
        #expect(t.text == "Hello +wXYZld")
        #expect(t.runs.map(\.len) == [7, 6])
    }
}
