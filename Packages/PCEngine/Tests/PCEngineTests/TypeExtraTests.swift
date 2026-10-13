// Port of photocraft-engine (crates/engine/src/type_extra_cmds/tests.rs), MIT OR Apache-2.0, © ArtCraft Team and the PhotoCraft contributors.
//
// Fonts: photocraft's bundled JetBrains Mono → Menlo, Inter → PCPlatform's default family.
// Partly ported: `warp_text_changes_pixels_and_round_trips` (the stored warp, its TySh round trip,
// bad styles and clearing are checked; the arced pixels are not, PCPlatform does not render
// warps). The TySh round trips go through a PSD written and read by PCIO (the engine does not keep
// a generated TySh on the layer). `vertical_point_and_paragraph_conversion_keep_the_columns_in_place`
// reads glyph positions from PCPlatform's `TextEngine.layout` (the engine's `Layout` has no glyphs).

import Foundation
@testable import PCEngine
import PCDocument
import PCFoundation
import PCPlatform
import Testing

@Suite struct TypeExtraTests {
    func session(_ depth: Int) throws -> Session {
        let s = Session()
        try s.execute("file.new", ["width": 300, "height": 120, "depth": .int(depth), "background": "white"])
        return s
    }

    func textLayer(_ s: Session, _ text: String) throws -> LayerId {
        let r = try s.execute("type.create", ["x": 20, "y": 70, "text": .string(text), "size": 36, "color": "#000000"])
        return LayerId(try #require(r["layer"]?.uint64Value))
    }

    func text(_ s: Session, _ id: LayerId) throws -> TextLayer { try #require(s.active.flatMap { TypeCommands.textOf($0.doc, id) }) }

    /// Text layer `id` read back from the TySh PCIO writes for it in a PSD.
    func throughTySh(_ s: Session, _ id: LayerId) throws -> TextLayer {
        let doc = try #require(s.active?.doc)
        let bytes = try EngineIO.export(doc, as: "t.psd", services: s.services).bytes
        let back = try EngineIO.importFile(name: "t.psd", bytes: bytes, services: s.services).document
        let index = try #require(doc.walk().firstIndex { $0.layer.id == id })
        let layer = back.walk()[index].layer
        guard case .text(let t) = layer.content else { throw EngineError.other("layer \(id) came back as \(layer.content)") }
        return t
    }

    func ink(_ s: Session, _ id: LayerId) -> PixelRect { s.active?.doc.layer(id)?.surface?.contentBounds ?? .empty }

    func layout(_ s: Session, _ id: LayerId) throws -> TypeCommands.Layout {
        let d = try #require(s.active)
        return TypeExtraCommands.layout(d.doc, try text(s, id))
    }

    @Test func antiAliasAndOrientationAreOneStepEach() throws {
        let s = try session(8)
        #expect(!s.isEnabled("type.antiAlias.crisp"))
        let id = try textLayer(s, "Aa")
        for (cmd, aa) in [("type.antiAlias.crisp", AntiAlias.crisp), ("type.antiAlias.windows", .windows), ("type.antiAlias.windowsLcd", .windowsLcd),
                          ("type.antiAlias.none", .none)] {
            try s.execute(cmd, [:])
            #expect(try text(s, id).antialias == aa)
        }
        // No anti-aliasing: only fully covered or empty pixels.
        let surf = try #require(s.active?.doc.layer(id)?.surface)
        #expect(surf.readRGBA(surf.contentBounds).allSatisfy { $0.w == 0 || $0.w == 1 })
        try s.execute("type.orientation.vertical", [:])
        #expect(try text(s, id).orientation == .vertical)
        #expect(s.undo())
        #expect(try text(s, id).orientation == .horizontal)
        #expect(s.undo())
        #expect(try text(s, id).antialias == .windowsLcd)
    }

    @Test(arguments: ["left", "center", "right"])
    func pointAndParagraphConversionKeepTheTextInPlace(_ align: String) throws {
        let s = try session(8)
        let r = try s.execute("type.create", ["x": 150, "y": 70, "text": "Hello world", "size": 30, "align": .string(align)])
        let id = LayerId(try #require(r["layer"]?.uint64Value))
        let before = ink(s, id)
        #expect(!s.isEnabled("type.convertToPointText"))
        try s.execute("type.convertToParagraphText", [:])
        if case .box = try text(s, id).shape {} else { Issue.record("not a box") }
        let after = ink(s, id)
        #expect(abs(after.x0 - before.x0) <= 2 && abs(after.y0 - before.y0) <= 2, "\(align): \(before) → \(after)")
        #expect(try layout(s, id).lines.count == 1, "\(align): no new wraps")
        try s.execute("type.convertToPointText", [:])
        #expect(try text(s, id).shape == .point)
        let back = ink(s, id)
        #expect(abs(back.x0 - before.x0) <= 2 && abs(back.y0 - before.y0) <= 2, "\(align): \(before) → \(back)")
    }

    @Test(arguments: ["left", "center", "right"])
    func verticalPointAndParagraphConversionKeepTheColumnsInPlace(_ align: String) throws {
        let s = try session(8)
        _ = try? s.execute("image.canvasSize", ["width": 300, "height": 400])
        let r = try s.execute("type.create", ["x": 150, "y": 100, "text": "Hello world", "size": 30, "align": .string(align)])
        let id = LayerId(try #require(r["layer"]?.uint64Value))
        try s.execute("type.orientation.vertical", [:])
        let before = try #require(try layout(s, id).bounds())
        let docBefore = CGPoint(x: before[0], y: before[1]).applying(try text(s, id).transform.cgAffineTransform)
        try s.execute("type.convertToParagraphText", [:])
        guard case .box(let box) = try text(s, id).shape else { Issue.record("\(align): box expected"); return }
        #expect(try layout(s, id).lines.count == 1, "\(align): no new wraps")
        #expect(box.height > 0)
        // The column's first glyph stays where it was (glyph positions in document space).
        let dpi = Double(try #require(s.active).doc.resolutionDpi)
        func firstGlyph() throws -> CGPoint {
            let t = try text(s, id)
            return try #require(TextEngine.layout(t, dpi: dpi).glyphs.first).position.applying(t.transform.cgAffineTransform)
        }
        let pAfter = try firstGlyph()
        try s.execute("type.convertToPointText", [:])
        let pBack = try firstGlyph()
        #expect(abs(pAfter.x - pBack.x) < 1.5 && abs(pAfter.y - pBack.y) < 1.5, "\(align): \(pAfter) → \(pBack)")
        let back = try #require(try layout(s, id).bounds())
        let docBack = CGPoint(x: back[0], y: back[1]).applying(try text(s, id).transform.cgAffineTransform)
        #expect(abs(docBack.x - docBefore.x) < 1.5 && abs(docBack.y - docBefore.y) < 1.5, "\(align): \(docBefore) → \(docBack)")
    }

    /// Issue #446: the vertical command's description must not claim it stays horizontal.
    @Test func verticalOrientationParamsMatchHorizontal() {
        let r = CommandRegistry.standard()
        #expect(r.spec("type.orientation.vertical")?.params == r.spec("type.orientation.horizontal")?.params)
    }

    /// Issue #199: vertical type is laid out top to bottom, columns right to left, on the canvas.
    @Test func verticalOrientationRendersColumnsInsideTheCanvas() throws {
        let s = Session()
        try s.execute("file.new", ["width": 1000, "height": 600, "background": "#fff8e7", "name": "flyer"])
        // The issue's repro (its font is missing here: fallback fonts then cover the text).
        let r = try s.execute("type.create", ["x": 900, "y": 30, "text": "縦書きテスト", "size": 40, "font": "Noto Sans CJK JP", "name": "vertical"])
        let id = LayerId(try #require(r["layer"]?.uint64Value))
        let flat = ink(s, id)
        #expect(flat.width > flat.height, "horizontal first: \(flat)")
        let v = try s.execute("type.orientation.vertical", [:])
        #expect(v == ["orientation": "vertical"])
        let b = ink(s, id)
        #expect(b.height > b.width, "\(b)")
        #expect(b.x0 >= 0 && b.x1 <= 1000 && b.y0 >= 0 && b.y1 <= 600, "inside the canvas: \(b)")
        // On the anchor's x, running down from its y.
        #expect(b.x0 < 900 && b.x1 > 900 && b.y0 >= 25, "\(b)")
        // Latin text: a second column of a two-line layer sits left of the first.
        let two = LayerId(try #require(try s.execute("type.create", ["x": 500, "y": 30, "text": "ABC\nDEF", "size": 40])["layer"]?.uint64Value))
        try s.execute("type.orientation.vertical", ["layer": .id(two)])
        let l = try layout(s, two)
        #expect(l.vertical && l.lines.count == 2)
        let bb = try #require(l.bounds())
        #expect(bb[2] > 0 && bb[0] < -40 && bb[1] >= -1e-3 && bb[3] > 60, "\(bb)")
        // Bad layer ids fail cleanly.
        #expect(throws: EngineError.self) { try s.execute("type.orientation.vertical", ["layer": 9999]) }
    }

    @Test func paragraphToPointHardensSoftWraps() throws {
        let s = try session(8)
        let r = try s.execute("type.create", ["box": [10, 10, 120, 100], "text": "one two three four five six", "size": 18])
        let id = LayerId(try #require(r["layer"]?.uint64Value))
        let soft = try layout(s, id).lines.count
        #expect(soft >= 2)
        let out = try s.execute("type.convertToPointText", [:])
        #expect(out["inserted"] == .int(soft - 1))
        let t = try text(s, id)
        #expect(t.text.filter { $0 == "\n" }.count == soft - 1)
        #expect(t.text.replacingOccurrences(of: "\n", with: "") == "one two three four five six")
        #expect(try layout(s, id).lines.count == soft)
    }

    @Test(arguments: [8, 16, 32])
    func workPathAndShapeFollowTheGlyphs(_ depth: Int) throws {
        let s = try session(depth)
        let id = try textLayer(s, "oil")
        let before = ink(s, id)
        try s.execute("type.createWorkPath", [:])
        let wp = try #require(s.active?.doc.workPath)
        // 'o' has an outer contour and a counter (subtracted), plus 'i' (stem + dot) and 'l'.
        #expect(wp.subpaths.count >= 5, "\(wp.subpaths.count)")
        #expect(wp.subpaths.contains { $0.op == .subtract })
        let cb = try #require(wp.controlBounds)
        #expect(abs(cb.x - Double(before.x0)) < 3 && abs(cb.z - Double(before.x1)) < 3, "\(cb) vs \(before)")
        #expect(abs(cb.y - Double(before.y0)) < 3 && abs(cb.w - Double(before.y1)) < 3, "\(cb) vs \(before)")
        // Convert to Shape renders the same pixels (the counter of the 'o' stays open).
        let doc0 = try #require(s.active?.doc)
        let compBefore = try s.services.renderer.renderCPU(doc0, region: doc0.bounds).px
        try s.execute("type.convertToShape", [:])
        let l = try #require(s.active?.doc.layer(id))
        if case .shape = l.content {} else { Issue.record("not a shape layer") }
        #expect(!l.psdBlocks.contains { $0.key == PSDKey("TySh") })
        let doc1 = try #require(s.active?.doc)
        let compAfter = try s.services.renderer.renderCPU(doc1, region: doc1.bounds).px
        let diff = zip(compBefore, compAfter).reduce(Float(0)) { $0 + abs($1.0.x - $1.1.x) } / Float(compBefore.count)
        #expect(diff < 0.01, "depth \(depth): mean diff \(diff)")
        #expect(s.undo())
        if case .text = s.active?.doc.layer(id)?.content {} else { Issue.record("undo did not restore the type layer") }
    }

    @Test func warpTextIsStoredAndCleared() throws {
        let s = try session(8)
        let id = try textLayer(s, "WARP ME")
        let flat = ink(s, id)
        try s.execute("type.warpText", ["style": "arc", "bend": 60])
        let w = try #require(try text(s, id).warp)
        #expect(w.style == "warpArc")
        #expect(w.value == 60)
        // The regenerated TySh carries the warp (PSD round trip).
        #expect(try throughTySh(s, id).warp == w)
        #expect(throws: EngineError.self) { try s.execute("type.warpText", ["style": "spiral"]) }
        try s.execute("type.warpText", ["style": "none"])
        #expect(try text(s, id).warp == nil)
        #expect(ink(s, id) == flat)
        for (_, style) in TypeExtraCommands.warpStyles {
            try s.execute("type.warpText", ["style": .string(style), "bend": -40, "horizontalDistortion": 10])
            #expect(!ink(s, id).isEmpty, "\(style)")
            #expect(try text(s, id).warp?.horizontalDistortion == 10)
        }
    }

    @Test func openTypeTogglesStoreFeatures() throws {
        let s = try session(8)
        let id = try textLayer(s, "office 1/2")
        func st() throws -> CharStyle { try text(s, id).charRuns()[0].style }
        #expect(try st().ligatures)
        try s.execute("type.openType.standardLigatures", [:])
        #expect(try !st().ligatures)
        try s.execute("type.openType.fractions", [:])
        try s.execute("type.openType.discretionaryLigatures", ["on": true])
        try s.execute("type.openType.swash", ["range": [0, 3]])
        let cur = try st()
        #expect(TypeExtraCommands.featureOn(cur, "frac") && TypeExtraCommands.featureOn(cur, "dlig") && TypeExtraCommands.featureOn(cur, "swsh"))
        let runs = try text(s, id).charRuns()
        #expect(!TypeExtraCommands.featureOn(try #require(runs.last).style, "swsh"), "range respected")
        try s.execute("type.openType.fractions", [:])
        #expect(!TypeExtraCommands.featureOn(try st(), "frac"))
        // PSD round trip of the toggles.
        let back = try throughTySh(s, id).charRuns()[0].style
        #expect(TypeExtraCommands.featureOn(back, "swsh") && !back.ligatures)
    }

    @Test func loremUpdateFontsAndDefaultStyles() throws {
        let s = try session(16)
        // No type layer: a new paragraph box.
        let r = try s.execute("type.pasteLoremIpsum", [:])
        let boxId = LayerId(try #require(r["layer"]?.uint64Value))
        if case .box = try text(s, boxId).shape {} else { Issue.record("not a box") }
        let id = try textLayer(s, "Hi ")
        let r2 = try s.execute("type.pasteLoremIpsum", [:])
        #expect(try text(s, id).text.hasPrefix("Hi Lorem ipsum"))
        #expect(r2["caret"] == .int(TypeCommands.charCount(try text(s, id).text)))
        #expect(try s.execute("type.updateAllTextLayers", [:])["updated"] == 2)
        // A missing font is reported and replaced.
        try s.execute("type.setStyle", ["font": "No Such Font Family"])
        #expect(try s.execute("type.resolveMissingFonts", [:])["missing"] == ["No Such Font Family"])
        try s.execute("type.resolveMissingFonts", ["map": ["No Such Font Family": "Menlo"]])
        #expect(try text(s, id).charRuns()[0].style.fontFamily == "Menlo")
        try s.execute("type.setStyle", ["font": "Gone Sans"])
        #expect(try s.execute("type.replaceAllMissingFonts", [:])["replaced"] == 1)
        #expect(try text(s, id).charRuns()[0].style.fontFamily == FontCatalog.defaultFamily)
        // Default type styles: save from one layer, new layers and Load use them.
        #expect(!s.isEnabled("type.loadDefaultTypeStyles"))
        try s.execute("type.setStyle", ["size": 50, "font": "Menlo"])
        try s.execute("type.saveDefaultTypeStyles", [:])
        try s.selectLayer(boxId)
        try s.execute("type.loadDefaultTypeStyles", [:])
        #expect(try text(s, boxId).charRuns()[0].style.sizePt == 50)
        let nid = LayerId(try #require(try s.execute("type.create", ["x": 5, "y": 5, "text": "new"])["layer"]?.uint64Value))
        let style = try text(s, nid).charRuns()[0].style
        #expect(style.fontFamily == "Menlo" && style.sizePt == 50)
    }

    @Test func rasterizeTypeLayer() throws {
        let s = try session(8)
        let id = try textLayer(s, "R")
        try s.execute("type.rasterizeTypeLayer", [:])
        #expect(s.active?.doc.layer(id)?.rasterSurface != nil)
        #expect(!s.isEnabled("type.rasterizeTypeLayer"))
    }

    /// Every id of the six type modules keeps photocraft's label, menu path, shortcut and params.
    @Test func catalogMetadataMatchesPhotocraft() {
        let r = CommandRegistry.standard()
        let modules: Set<String> = ["type_cmds", "type_extra_cmds", "type_styles_cmds", "type_spell_cmds", "type_caret_cmds", "type_mask_cmds"]
        for c in PhotocraftCatalog.commands where modules.contains(c.module) {
            guard let spec = r.spec(c.id) else { Issue.record("missing \(c.id)"); continue }
            #expect(spec.isAvailable, "\(c.id)")
            #expect(spec.module == c.module, "\(c.id)")
            #expect(spec.label == c.label && spec.menu == c.menu && spec.shortcut == c.shortcut, "\(c.id)")
            // The catalogue could not read type.setStyle's computed notation.
            if c.id != "type.setStyle" { #expect(spec.params == c.params, "\(c.id)") }
        }
    }
}
