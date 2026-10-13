// Port of photocraft-engine (crates/engine/src/pattern_cmds.rs tests, pattern_fill_cmds.rs tests), MIT OR Apache-2.0, © ArtCraft Team and the PhotoCraft contributors.
//
// `edit.fill` (edit_cmds) is not in this package yet: tests that filled a layer write the colour
// straight into it. Skipped: `fill_with_pattern_respects_selection` (Edit › Fill with a pattern is
// edit_cmds').

import Foundation
import PCDocument
@testable import PCEngine
import PCFoundation
import PCPaint
import Testing

@Suite struct PatternTests {
    typealias T = StyleTestSupport

    func session(_ depth: Int) throws -> Session { try T.session(40, 30, extra: ["depth": .int(depth)]) }

    func library(_ s: Session) -> [PCDocument.Pattern] { s.state[PatternCommands.LibraryKey.self] }

    @Test func libraryHasBuiltinsAndLists() throws {
        let s = Session()
        let v = try s.execute("pattern.list")
        #expect((v.arrayValue?.count ?? 0) >= 6)
        #expect(v[0]?["id"]?.stringValue?.count == 36)
        // Built-in ids are stable across sessions.
        #expect(PatternCommands.builtin()[0].id == library(Session())[0].id)
        #expect(Set(PatternCommands.builtin().map(\.id)).count == 7)
    }

    @Test func defineRenameDelete() throws {
        let s = try session(8)
        try T.fill(s, nil, SIMD4(1, 0, 0, 1))
        try s.execute("select.rect", ["x": 2, "y": 3, "width": 5, "height": 4])
        let r = try s.execute("edit.definePattern", ["name": "Red"])
        let id = try #require(r["pattern"]?.stringValue)
        let pat = try #require(PatternCommands.resolve(s, id))
        #expect(pat.width == 5 && pat.height == 4)
        #expect(!pat.surface.format.alpha, "opaque pattern drops alpha")
        #expect(abs(pat.surface.pixel(x: 1, y: 1)[0] - 1) < 1e-6)
        // Same content → same id (replayable); not duplicated.
        let n = library(s).count
        try s.execute("edit.definePattern", ["name": "Red"])
        #expect(library(s).count == n)
        try s.execute("pattern.rename", ["pattern": .string(id), "name": "Crimson"])
        #expect(PatternCommands.resolve(s, "Crimson")?.id == id)
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("pc-pat-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let path = dir.appendingPathComponent("lib.pat").path
        try s.execute("pattern.export", ["path": .string(path)])
        try s.execute("pattern.delete", ["pattern": "Crimson"])
        #expect(PatternCommands.resolve(s, "Crimson") == nil)
        #expect(throws: EngineError.self) { try s.execute("pattern.delete", ["pattern": "Crimson"]) }
        let v = try s.execute("pattern.import", ["path": .string(path)])
        #expect(v["imported"]?.arrayValue?.contains(.string(id)) == true, "\(v)")
        let back = try #require(PatternCommands.resolve(s, id))
        let r4 = PixelRect(x0: 0, y0: 0, x1: 5, y1: 4)
        #expect(back.surface.readRegion(r4) == pat.surface.readRegion(r4))
        #expect(throws: EngineError.self) { try s.execute("pattern.import", ["path": "/nonexistent.pat"]) }
    }

    @Test func defineDefaultsToTheDocumentNameNumbered() throws {
        let s = try T.session(8, 8, extra: ["name": "photo.jpg"])
        let a = try s.execute("edit.definePattern")
        #expect(a["info"]?["name"] == "photo")
        try T.fill(s, nil, SIMD4(0, 0, 1, 1))
        let b = try s.execute("edit.definePattern")
        #expect(b["info"]?["name"] == "photo 2")
        #expect(throws: EngineError.self) { try s.execute("edit.definePattern", ["rect": [20, 20, 30, 30]]) }
    }

    @Test func patternFillLayerRendersAtEveryDepthAndUndoes() throws {
        for depth in [8, 16, 32] {
            let s = try session(depth)
            let r = try s.execute("layer.newFillLayer.pattern", ["pattern": "Checkerboard"])
            let id = LayerId(try #require(r["layer"]?.uint64Value))
            let st = try #require(s.active)
            #expect(st.doc.patterns.count == 1, "copied into the document")
            if case .fill(.pattern)? = st.doc.layer(id)?.content {} else { Issue.record("not a pattern fill") }
            // Checkerboard: 8 px squares of 0.8 and 1.0 grey from the canvas origin.
            let (a, b) = (try T.pixel(s, 1, 1), try T.pixel(s, 9, 1))
            #expect(abs(a[0] - 0.8) < 0.01 && abs(b[0] - 1) < 0.01, "\(depth): \(a) \(b)")
            s.undo()
            #expect(s.active?.doc.patterns.isEmpty == true)
            #expect(throws: EngineError.self) { try s.execute("layer.newFillLayer.pattern", ["pattern": "nope"]) }
        }
    }

    @Test func patternOverlayComposesWithAnOutsideStroke() throws {
        let s = try session(8)
        try s.execute("layer.new.layer")
        try T.fill(s, PixelRect(x: 10, y: 10, width: 10, height: 10), SIMD4(0, 0, 1, 1))
        try s.execute("layer.layerStyle.patternOverlay", ["pattern": "Diagonal Lines"])
        try s.execute("layer.layerStyle.stroke", ["size": 3, "color": "#00ff00", "add": true])
        let out = try T.pixel(s, 8, 15)
        #expect(out[1] > 0.9 && out[0] < 0.1, "stroke outside: \(out)")
    }

    @Test func patternOverlayRendersAndBrushTextureUsesLibrary() throws {
        let s = try session(16)
        try s.execute("layer.new.layer")
        try T.fill(s, nil, SIMD4(0, 0, 1, 1))
        try s.execute("layer.layerStyle.patternOverlay", ["pattern": "Checkerboard", "opacity": 100])
        #expect(s.active?.doc.patterns.count == 1)
        let p = try T.pixel(s, 1, 1)
        #expect(abs(p[0] - 0.8) < 0.01 && abs(p[2] - 0.8) < 0.01, "\(p)")
        #expect(throws: EngineError.self) { try s.execute("layer.layerStyle.patternOverlay", ["pattern": "missing"]) }
        try s.execute("layer.layerStyle.stroke", ["size": 4, "color": "#ffffff", "add": true])
        #expect(T.effects(s).count == 2)
        try s.execute("brush.texturePattern", ["pattern": "Dots", "scale": 50])
        #expect(s.tools.brush.texture.enabled)
        #expect(s.tools.brush.texture.scale == 0.5)
        if case .tile = s.tools.brush.texture.pattern {} else { Issue.record("expected a tile texture") }
    }

    @Test func aPatternTooLargeToPaintIsRefusedNotAllocated() throws {
        // width × height overflows UInt32.
        let s = try session(8)
        s.state[PatternCommands.LibraryKey.self].append(PCDocument.Pattern(id: "huge", name: "Huge", width: 65_536, height: 65_536, surface: Surface(format: .rgba8)))
        do {
            try s.execute("brush.texturePattern", ["pattern": "huge"])
            Issue.record("expected an error")
        } catch {
            #expect("\(error)".contains("too large"), "\(error)")
        }
    }

    @Test func averageColorOfABuiltin() {
        let grid = PatternCommands.builtin()[3]
        let c = PatternCommands.averageColor(grid)
        #expect(c.c.x > 0.9 && c.c.x < 1 && c.c.x == c.c.y)
    }
}

@Suite struct PatternFillTests {
    typealias T = StyleTestSupport
    let set = PatternFillCommands.set

    func session(_ depth: Int) throws -> (Session, LayerId) {
        let s = try T.session(40, 30, extra: ["depth": .int(depth)])
        try s.execute("select.rect", ["x": 2, "y": 2, "width": 20, "height": 10])
        let id = try s.execute("layer.newFillLayer.pattern", ["pattern": "Checkerboard"])["layer"]?.uint64Value
        return (s, LayerId(try #require(id)))
    }

    func fill(_ s: Session, _ id: LayerId) -> Fill? {
        if case .fill(let f)? = s.active?.doc.layer(id)?.content { return f }
        return nil
    }

    @Test func editKeepsMasksIsOneStepAndUndoesAtEveryDepth() throws {
        for depth in [8, 16, 32] {
            let (s, id) = try session(depth)
            let before = try #require(s.active?.doc)
            let count = s.active?.history.entries.count ?? 0
            let r = try s.execute(set, ["layer": .id(id), "pattern": "Bricks", "scale": 250, "angle": -45, "link": false, "phase": [3, -4]])
            #expect(r["scale"] == 250.0)
            let bricks = try #require(PatternCommands.resolve(s, "Bricks"))
            let want = Fill.pattern(PatternFill(name: bricks.name, scale: 2.5, id: bricks.id, angle: -45, link: false, phase: SIMD2(3, -4)))
            #expect(fill(s, id) == want)
            let st = try #require(s.active)
            #expect(st.history.entries.count == count + 1)
            #expect(st.doc.patterns.contains { $0.id == bricks.id }, "the new pattern is copied into the document")
            #expect(st.doc.layer(id)?.mask == before.layer(id)?.mask, "the selection mask is kept")
            // Omitted values keep the layer's; Snap to Origin zeroes the phase.
            try s.execute(set, ["phase": [0, 0]])
            guard case .pattern(let pf)? = fill(s, id) else { Issue.record("not a pattern fill"); return }
            #expect(pf.scale == 2.5 && pf.angle == -45 && pf.phase == .zero && !pf.link)
            s.undo()
            s.undo()
            #expect(s.active?.doc == before)
            s.redo()
            #expect(fill(s, id) == want)
            let count2 = s.active?.history.entries.count ?? 0
            try s.execute(set, ["scale": 250, "angle": -45])
            #expect(s.active?.history.entries.count == count2, "an unchanged fill is not a history step")
        }
    }

    @Test func previewMatchesWhatTheCommandCommits() throws {
        let (s, id) = try session(8)
        let p: JSONValue = ["layer": .id(id), "pattern": "Dots", "scale": 50, "angle": 30]
        let count = s.active?.history.entries.count ?? 0
        let before = try #require(s.active?.doc)
        let shown = try PatternFillCommands.preview(s, set, p)
        #expect(s.active?.doc == before)
        #expect(s.active?.history.entries.count == count, "previewing is not an edit")
        try s.execute(set, p)
        #expect(shown == s.active?.doc)
        let q: JSONValue = ["pattern": "Grid", "scale": 300, "angle": 90, "link": false]
        let shown2 = try PatternFillCommands.preview(s, PatternFillCommands.create, q)
        try s.execute(PatternFillCommands.create, q)
        // Layer ids are allocated per process, so the preview's new layer has its own id: compare
        // what the documents look like.
        let all = PixelRect(x: 0, y: 0, width: 40, height: 30)
        let doc = try #require(s.active?.doc)
        #expect(try s.services.renderer.renderCPU(shown2, region: all).px == s.services.renderer.renderCPU(doc, region: all).px)
        #expect(shown2.layers.count == doc.layers.count)
        #expect(throws: EngineError.self) { try PatternFillCommands.preview(s, "edit.fill", [:]) }
    }

    @Test func badParamsAndTargetsAreErrorsNotPanics() throws {
        let (s, id) = try session(8)
        let before = try #require(s.active?.doc)
        let bad: [JSONValue] = [
            [1, 2], ["layer": -1], ["layer": "x"], ["layer": 999_999], ["document": 999_999], ["pattern": "nope"], ["pattern": ""], ["pattern": 5],
            ["scale": 0], ["scale": 1001], ["scale": "big"], ["angle": 181], ["angle": -1e300], ["link": "yes"], ["phase": [1]], ["phase": [1, "x"]],
            ["phase": [1e30, 0]], ["phase": ["x": 1]],
        ]
        for p in bad {
            #expect(throws: EngineError.self, "\(p)") { try s.execute(set, p) }
            if p.objectValue != nil { #expect(throws: EngineError.self, "\(p)") { try PatternFillCommands.preview(s, set, p) } }
        }
        try s.execute("layer.new.layer")
        #expect(throws: EngineError.self, "a pixel layer is not a Pattern Fill") { try s.execute(set, ["scale": 50]) }
        try s.execute("layer.newFillLayer.solidColor")
        #expect(throws: EngineError.self, "a Solid Color Fill is not a Pattern Fill") { try s.execute(set, ["scale": 50]) }
        #expect(s.active?.doc.layer(id) == before.layer(id))
        #expect(throws: EngineError.self, "no document") { try Session().execute(set) }
    }

    @Test func lockedLayerIsRefused() throws {
        let (s, id) = try session(8)
        try s.execute("layer.lockLayers", ["pixels": true])
        #expect(throws: EngineError.self) { try s.execute(set, ["layer": .id(id), "scale": 50]) }
    }
}
