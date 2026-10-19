// Port of photocraft-engine (crates/engine/src/tests.rs and the engine contract in docs/architecture.md §6: every edit is a command, replayable from the journal), MIT OR Apache-2.0, © ArtCraft Team and the PhotoCraft contributors.
//
// The litmus test: a multi-command edit driven only through `execute` (ids + JSON params, exactly
// what menus, shortcuts, the CLI and MCP send) — new document, layers, an adjustment layer, a text
// layer, a brush stroke, a filter, a selection and a layer mask — checked on the composite PCRender
// produces, then unwound and rewound through undo/redo, and replayed from the journal into a fresh
// session.

import Foundation
import PCDocument
import PCEngine
import PCFoundation
import Testing

@Suite struct LitmusTests {
    static let steps: [(String, JSONValue)] = [
        ("file.new", ["width": 96, "height": 64, "name": "Litmus"]),
        ("layer.new.layer", ["name": "Paint"]),
        ("tools.setColors", ["foreground": "#1e64c8"]),
        ("select.rect", ["x": 8, "y": 8, "width": 40, "height": 48]),
        ("edit.fill", ["contents": "foreground"]),
        ("select.deselect", .object([:])),
        ("paint.stroke", ["points": [[52, 12], [88, 52]], "size": 9, "hardness": 1.0, "color": "#e03c28"]),
        ("filter.blur.gaussianBlur", ["radius": 1.5]),
        ("type.create", ["x": 10, "y": 40, "text": "PC", "size": 24, "color": "#ffffff"]),
        ("layer.newAdjustmentLayer.hueSaturation", ["hue": 30, "saturation": -20]),
        ("select.rect", ["x": 0, "y": 0, "width": 48, "height": 64]),
        // Reveal Selection uses the selection up (AB-T-0285).
        ("layer.layerMask.revealSelection", .object([:])),
    ]

    /// The composite through PCRender (straight RGBA, row-major).
    func composite(_ s: Session) throws -> [Float] {
        let d = try #require(s.active)
        return try s.services.renderer.composite(d.doc, rect: d.doc.bounds)
    }

    func px(_ c: [Float], _ x: Int, _ y: Int) -> SIMD4<Float> {
        let i = (y * 96 + x) * 4
        return SIMD4(c[i], c[i + 1], c[i + 2], c[i + 3])
    }

    @Test func aMultiCommandEditThroughDispatchUndoesRedoesAndReplays() throws {
        let s = Session()
        // The composite of every history state, oldest first (the new document is state 0).
        var states: [(String, [Float])] = []
        for (id, params) in Self.steps {
            let before = s.active?.history.pastCount ?? -1
            do { try s.execute(id, params) } catch { Issue.record("\(id): \(error)"); return }
            if (s.active?.history.pastCount ?? 0) > before || id == "file.new" { states.append((id, try composite(s))) }
        }
        #expect(states.count == Self.steps.count - 1, "every step but Set Colors is a history state")
        let d = try #require(s.active)
        #expect(d.doc.layers.map(\.name).first == "Background")
        #expect(d.doc.layers.count == 4, "\(d.doc.layers.map(\.name))")
        let adjustment = try #require(d.doc.layers.last)
        if case .adjustment = adjustment.content {} else { Issue.record("top layer is \(adjustment.content.kindName)") }
        #expect(adjustment.mask != nil, "the selection became the adjustment's mask")
        if case .text = d.doc.layers[2].content {} else { Issue.record("no type layer") }

        let final = try composite(s)
        // The fill, shifted by Hue/Saturation inside the mask (left half): no longer the fill's blue.
        let fill = px(final, 30, 20)
        #expect(fill.w == 1 && abs(fill.z - 200.0 / 255) > 0.02, "\(fill)")
        // The stroke is outside the mask (right half): its red as painted (blurred at the edges).
        let stroke = px(final, 70, 32)
        #expect(stroke.x > 0.8 && stroke.y < 0.35 && stroke.z < 0.3, "\(stroke)")
        // Untouched background stays white.
        #expect(px(final, 90, 5) == SIMD4(1, 1, 1, 1))
        // The PCRender composite and the engine's pixel query agree.
        let q = try s.execute("document.pixel", ["x": 70, "y": 32])
        #expect(abs((q[0]?.floatValue ?? -1) - stroke.x) < 1e-5)

        // Undo every step back to the new document, checking each state's composite on the way.
        for k in stride(from: states.count - 2, through: 0, by: -1) {
            #expect(s.undo(), "undo to state \(k)")
            #expect(try composite(s) == states[k].1, "undo back to \(states[k].0)")
        }
        #expect(!s.undo(), "nothing before the new document")
        // Redo to the end: the final composite again.
        while s.redo() {}
        #expect(try composite(s) == final, "redo reaches the final state")

        // The journal replays into a fresh session, to the same pixels.
        let replay = Session()
        for inv in s.journal { try replay.execute(inv) }
        #expect(try composite(replay) == final, "the journal reproduces the document")

        // A PSD round trip through PCIO: Save As makes it the document's file; reopened, the
        // layers (adjustment with its mask, type, pixels) and the composite come back.
        let dir = try ioDir("litmus")
        defer { try? FileManager.default.removeItem(at: dir) }
        let psd = dir.appendingPathComponent("litmus.psd").path
        try s.execute("file.saveAs", ["path": .string(psd)])
        dropForOracle(URL(fileURLWithPath: psd), as: "litmus.psd")
        #expect(s.active?.isDirty == false && s.active?.path == psd)
        let o = try s.execute("file.open", ["path": .string(psd)])
        let back = s.documents[try #require(o["document"]?.intValue)].doc
        let saved = try #require(s.documents.first).doc
        #expect(back.layers.map(\.name) == saved.layers.map(\.name))
        if case .adjustment = back.layers.last?.content {} else { Issue.record("the adjustment layer came back as \(back.layers.last?.content.kindName ?? "nothing")") }
        #expect(back.layers.last?.mask != nil)
        if case .text = back.layers[2].content {} else { Issue.record("the type layer came back as \(back.layers[2].content.kindName)") }
        let reopened = try s.services.renderer.composite(back, rect: back.bounds)
        let worst = zip(final, reopened).map { abs($0 - $1) }.max() ?? 0
        #expect(worst <= 2.0 / 255, "the reopened PSD composites like the document (worst \(worst))")
        // …and the native format, exactly.
        let native = dir.appendingPathComponent("litmus.pcraft").path
        _ = s.setActive(0)
        try s.execute("file.saveAs", ["path": .string(native)])
        let n = try s.execute("file.open", ["path": .string(native)])
        let nd = s.documents[try #require(n["document"]?.intValue)].doc
        #expect(try s.services.renderer.composite(nd, rect: nd.bounds) == final, ".pcraft is lossless")
    }
}
