// PhotoCraftNative's own tests (AB-T-0309): Remove Background on a smart object masks it and keeps it a smart object,
// as Photoshop's Quick Action does. MIT OR Apache-2.0, © ArtCraft Team and the PhotoCraft contributors.

import Foundation
import PCDocument
@testable import PCEngine
import PCFoundation
import Testing

@Suite struct RemoveBackgroundSmartTests {
    /// A 1024 × 768 PNG: an orange disc (centre (512, 384), radius 200) on flat blue, a subject Apple Vision finds.
    static func discPNG(_ dir: URL) throws -> String {
        let s = Session()
        try s.execute("file.new", ["width": 1024, "height": 768, "background": "#3366d9"])
        try s.execute("select.rect", ["x": 312, "y": 184, "width": 400, "height": 400, "ellipse": true])
        try s.execute("edit.fill", ["contents": "color", "color": "#e64d1a"])
        let path = dir.appendingPathComponent("disc.png").path
        try FileCommands.saveDoc(s, try #require(s.active).doc, path)
        return path
    }

    /// Placed into a 512 × 384 canvas, the PNG is fitted at 50 %: the disc sits at (256, 192), radius 100.
    @Test func removeBackgroundMasksASmartObjectAndKeepsItOne() throws {
        let dir = try ioDir("remove-background-smart")
        defer { try? FileManager.default.removeItem(at: dir) }
        let png = try Self.discPNG(dir)
        let s = Session()
        try s.execute("file.new", ["width": 512, "height": 384])
        try s.execute("file.placeEmbedded", ["path": .string(png)])
        // A host may empty PCIntelligence's slots (AB-T-0304): Remove Background runs on the model-free Vision tier.
        s.intelligence.registry.removeAll()
        let st = try #require(s.active)
        let id = try #require(st.activeLayer)
        let placed = try #require(st.doc.layer(id))
        guard case .smart(let before) = placed.content else { Issue.record("a smart object expected"); return }
        #expect(placed.mask == nil && before.cache != nil)

        // Pixel-changing intelligence commands still refuse a smart object; the mask-only one and Select Subject don't.
        #expect(s.disabledReason("layer.removeBackground") == nil)
        #expect(s.disabledReason("paint.remove")?.contains("not a pixel layer") == true)
        #expect(s.disabledReason("select.subject") == nil)

        let steps = try #require(s.active?.history.entries.count)
        let r = try s.execute("layer.removeBackground")
        #expect(r["layer"] == .id(id))
        let l = try #require(s.active?.doc.layer(id))
        guard case .smart(let after) = l.content else { Issue.record("still a smart object"); return }
        #expect(after == before, "its source, transform and rendered placement are untouched")
        let mask = try #require(l.mask)
        #expect(mask.value(x: 256, y: 192) > 0.9, "the subject shows")
        #expect(mask.value(x: 20, y: 20) < 0.1 && mask.value(x: 400, y: 192) < 0.1, "the background is masked")
        #expect(s.active?.history.entries.count == steps + 1)
        #expect(s.active?.history.undoLabel == "Remove Background")
        try s.execute("edit.undo")
        #expect(s.active?.doc.layer(id) == placed)

        // Select Subject sampling only the smart object reads its rendered placement too.
        try s.execute("select.subject", ["sampleAllLayers": false])
        let sel = try #require(s.active?.doc.selection)
        #expect((sel.pixel(x: 256, y: 192).first ?? 0) > 0.9 && (sel.pixel(x: 20, y: 20).first ?? 1) < 0.1)
    }
}
