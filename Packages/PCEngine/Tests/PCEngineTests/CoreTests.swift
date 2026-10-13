// Port of photocraft-engine (crates/engine/src/tests.rs), MIT OR Apache-2.0, © ArtCraft Team and the PhotoCraft contributors.

import Foundation
import PCDocument
import PCEngine
import PCFoundation
import Testing

@Suite struct CoreTests {
    func session(_ w: Int = 64, _ h: Int = 64) throws -> Session {
        let s = Session()
        try s.execute("file.new", ["width": .int(w), "height": .int(h)])
        return s
    }

    @Test func registryCoversPhotocraft() {
        let r = CommandRegistry.standard()
        let report = CoverageReport(registry: r)
        #expect(report.missing == 0)
        #expect(report.total == PhotocraftCatalog.commands.count)
        #expect(Set(r.ids).count == r.count)
    }

    @Test func layerLifecycleWithUndo() throws {
        let s = try session()
        let id = try s.execute("layer.new.layer", ["name": "A"])["layer"]?.uint64Value
        #expect(id != nil)
        #expect(s.active?.doc.layers.count == 2)
        try s.execute("layer.setProps", ["opacity": 0.5, "blend": "Multiply"])
        let l = s.active?.doc.layer(LayerId(id!))
        #expect(l?.opacity == 0.5)
        #expect(l?.blend == .multiply)
        #expect(s.undo())
        #expect(s.active?.doc.layer(LayerId(id!))?.opacity == 1)
        #expect(s.redo())
        #expect(s.active?.doc.layer(LayerId(id!))?.opacity == 0.5)
        #expect(s.active?.lastTransaction == nil)
    }

    @Test func editsCommitTransactions() throws {
        let s = try session()
        try s.execute("layer.new.layer", .object([:]))
        let t1 = s.active?.lastTransaction
        #expect(t1?.ops.count == 1)
        if case .insertLayer? = t1?.ops.first {} else { Issue.record("expected insertLayer, got \(String(describing: t1?.ops))") }
        try s.execute("layer.setProps", ["opacity": 0.25])
        if case .setLayerProperties? = s.active?.lastTransaction?.ops.first {} else { Issue.record("expected setLayerProperties") }
        try s.execute("select.all", .object([:]))
        if case .setSelection? = s.active?.lastTransaction?.ops.first {} else { Issue.record("expected setSelection") }
        #expect(s.active?.lastDamage == .empty)
    }

    @Test func unknownAndDisabledCommandsError() throws {
        let s = Session()
        #expect(throws: EngineError.unknownCommand("nope.nope")) { try s.execute("nope.nope") }
        #expect(throws: EngineError.self) { try s.execute("layer.new.layer") }
        #expect(s.disabledReason("layer.new.layer") == "no document open")
    }

    @Test func fileNewVariants() throws {
        let s = Session()
        try s.execute("file.new", ["width": 512.0, "height": 256, "mode": "gray", "depth": 16, "background": "transparent", "resolution": 300])
        let d = try #require(s.active).doc
        #expect(d.size == PixelSize(width: 512, height: 256))
        #expect(d.mode == .grayscale)
        #expect(d.depth == .u16)
        #expect(d.resolutionDpi == 300)
        #expect(d.layers.count == 1)
        #expect(d.background == nil)
        #expect(throws: EngineError.self) { try s.execute("file.new", ["width": "wide"]) }
        #expect(s.documents.count == 1)
    }

    @Test func adjustmentLayersChangeComposite() throws {
        let s = try session(8, 8)
        let before = try s.execute("document.pixel", ["x": 1, "y": 1])
        try s.execute("layer.newAdjustmentLayer.invert", .object([:]))
        let after = try s.execute("document.pixel", ["x": 1, "y": 1])
        #expect(before[0]?.doubleValue == 1)
        #expect(after[0]?.doubleValue ?? 1 < 0.01)
    }

    @Test func destructiveInvertAndSelection() throws {
        let s = try session(16, 16)
        try s.execute("select.rect", ["x": 0, "y": 0, "width": 8, "height": 16])
        try s.execute("image.adjustments.invert", .object([:]))
        #expect(try s.execute("document.pixel", ["x": 2, "y": 2])[0]?.doubleValue ?? 1 < 0.01)
        #expect(try s.execute("document.pixel", ["x": 12, "y": 2])[0]?.doubleValue == 1)
        if case .paintTiles? = s.active?.lastTransaction?.ops.first {} else { Issue.record("expected paintTiles") }
    }

    @Test func canvasRotation() throws {
        let s = try session(30, 20)
        try s.execute("image.imageRotation.90cw", .object([:]))
        #expect(s.active?.doc.size == PixelSize(width: 20, height: 30))
        #expect(s.undo())
        #expect(s.active?.doc.size == PixelSize(width: 30, height: 20))
    }

    @Test func journalRecordsMutationsOnly() throws {
        let s = try session()
        try s.execute("document.inspect", .object([:]))
        try s.execute("layer.new.layer", .object([:]))
        #expect(s.journal.map(\.id) == ["file.new", "layer.new.layer"])
    }

    @Test func coalescedEditsShareOneStep() throws {
        let s = try session()
        try s.execute("layer.new.layer", .object([:]))
        let n = s.active!.history.entries.count
        for o in [0.9, 0.8, 0.7] { try s.execute("layer.setProps", ["opacity": .number(o), "coalesce": "drag"]) }
        #expect(s.active!.history.entries.count == n + 1)
    }

    @Test func unavailableCommandsReportWhy() throws {
        let s = try session()
        let reason = try #require(s.disabledReason("plugin.list"))
        #expect(reason.contains("plug-in host"))
        #expect(throws: EngineError.self) { try s.execute("plugin.list") }
    }
}
