// Port of photocraft-engine (crates/engine/src/comps_cmds/tests.rs), MIT OR Apache-2.0, © ArtCraft Team and the PhotoCraft contributors.
//
// Every photocraft test is ported (`export_comps_to_files_naming` reads its PNGs back through
// PCIO; a PSD export of the comps also goes to the Photoshop oracle).

import Foundation
import PCDocument
@testable import PCEngine
import PCFoundation
import Testing

/// A 64×48 document with layers A (a red square at 4,4–14,14) and B (a blue one at 30,20–40,30).
private func session(_ depth: Int) throws -> (Session, LayerId, LayerId) {
    let s = Session()
    try s.execute("file.new", ["width": 64, "height": 48, "depth": .int(depth)])
    let (a, b) = try s.edit("setup") { doc, _ -> (LayerId, LayerId) in
        let fmt = doc.pixelFormat
        var a = Layer.raster("A", format: fmt)
        a.withRaster { $0.fill(PixelRect(x0: 4, y0: 4, x1: 14, y1: 14), with: fmt.components(fromRGBA: SIMD4(1, 0, 0, 1))) }
        var b = Layer.raster("B", format: fmt)
        b.withRaster { $0.fill(PixelRect(x0: 30, y0: 20, x1: 40, y1: 30), with: fmt.components(fromRGBA: SIMD4(0, 0, 1, 1))) }
        doc.layers.append(a)
        doc.layers.append(b)
        return (a.id, b.id)
    }
    return (s, a, b)
}

private func doc(_ s: Session) -> Document { s.active?.doc ?? Document(name: "", size: PixelSize(width: 1, height: 1), mode: .rgb, depth: .u8) }

private func pos(_ s: Session, _ id: LayerId) -> SIMD2<Int32>? { doc(s).layer(id)?.compPosition }

private func comp(_ v: JSONValue) -> UInt32 { UInt32(v["comp"]?.uint64Value ?? 0) }

@Suite struct CompsCommandsTests {
    @Test func captureApplyVisibilityPositionAppearanceIndependently() throws {
        for depth in [8, 16, 32] {
            let (s, a, b) = try session(depth)
            let c1 = comp(try s.execute("layerComp.new", ["name": "Start"]))
            // Change all three properties.
            try s.execute("layer.translate", ["layer": .id(a), "dx": 10, "dy": 5])
            try s.edit("t") { d, _ in
                d.updateLayer(b) { l in
                    l.visible = false
                    l.blend = .multiply
                    l.opacity = 0.5
                }
            }
            #expect(pos(s, a) == SIMD2(14, 9))

            // Visibility only.
            try s.execute("layerComp.setOptions", ["comp": .int(Int(c1)), "position": false, "appearance": false])
            try s.execute("layerComp.apply", ["comp": .int(Int(c1))])
            #expect(doc(s).layer(b)?.visible == true, "\(depth)")
            #expect(pos(s, a) == SIMD2(14, 9))
            #expect(doc(s).layer(b)?.blend == .multiply)

            // Position only.
            try s.edit("t") { d, _ in d.updateLayer(b) { $0.visible = false } }
            try s.execute("layerComp.setOptions", ["comp": .int(Int(c1)), "visibility": false, "position": true])
            try s.execute("layerComp.apply")
            #expect(pos(s, a) == SIMD2(4, 4))
            #expect(doc(s).layer(b)?.visible == false)

            // Appearance only.
            try s.execute("layerComp.setOptions", ["comp": "Start", "position": false, "appearance": true])
            try s.execute("layerComp.apply")
            let lb = try #require(doc(s).layer(b))
            #expect(lb.blend == .normal && lb.opacity == 1 && !lb.visible)
            // Pixels really moved (not just bounds bookkeeping).
            let surf = try #require(doc(s).layer(a)?.surface)
            #expect(surf.pixel(x: 5, y: 5)[3] > 0.9 && surf.pixel(x: 16, y: 11)[3] < 0.1)
        }
    }

    @Test func undoRedoAndLastDocumentState() throws {
        let (s, a, _) = try session(8)
        try s.execute("layerComp.new")
        #expect(doc(s).layerComps.first?.name == "Layer Comp 1")
        try s.execute("layer.translate", ["layer": .id(a), "dx": 3, "dy": 0])
        // A fresh document state (not a comp) is remembered when a comp is applied over it.
        try s.execute("layerComp.apply")
        #expect(pos(s, a) == SIMD2(4, 4))
        #expect(doc(s).lastDocumentState != nil)
        try s.execute("layerComp.restoreLastDocumentState")
        #expect(pos(s, a) == SIMD2(7, 4))
        #expect(doc(s).lastAppliedComp == nil)
        // Each step is one undo.
        #expect(s.undo())
        #expect(pos(s, a) == SIMD2(4, 4))
        #expect(s.undo())
        #expect(pos(s, a) == SIMD2(7, 4))
        #expect(s.redo())
        #expect(pos(s, a) == SIMD2(4, 4))
        try s.execute("layerComp.delete")
        #expect(doc(s).layerComps.isEmpty)
        #expect(s.undo())
        #expect(doc(s).layerComps.count == 1)
    }

    @Test func ordinaryLayoutEditsBecomeTheLastDocumentState() throws {
        for depth in [8, 16, 32] {
            let cases: [(String, JSONValue)] = [
                ("layer.translate", ["dx": 9, "dy": 3]), ("layer.setProps", ["visible": false]),
                ("layer.setProps", ["opacity": 0.25]), ("layer.setProps", ["blend": "multiply"]),
            ]
            for (command, params) in cases {
                let (s, a, _) = try session(depth)
                try s.execute("layerComp.new")
                try s.execute(command, params.setting("layer", .id(a)))
                let edited = doc(s).captureCompStates()
                try s.execute("layerComp.apply")
                #expect(doc(s).captureCompStates() != edited)
                #expect(s.isEnabled("layerComp.restoreLastDocumentState"))
                try s.execute("layerComp.restoreLastDocumentState")
                #expect(doc(s).captureCompStates() == edited, "\(depth)-bit \(command) \(params)")
            }
        }
    }

    @Test func cyclingCompsKeepsTheLatestEditedLayout() throws {
        let (s, a, _) = try session(8)
        let one = try s.execute("layerComp.new", ["name": "One"])["comp"] ?? .null
        try s.execute("layer.translate", ["layer": .id(a), "dx": 10, "dy": 0])
        let two = try s.execute("layerComp.new", ["name": "Two"])["comp"] ?? .null
        for dx in [7, 13] {
            try s.execute("layer.translate", ["layer": .id(a), "dx": .int(dx), "dy": 0])
            let edited = doc(s).captureCompStates()
            try s.execute("layerComp.apply", ["comp": one])
            try s.execute("layerComp.apply", ["comp": two])
            try s.execute("layerComp.apply", ["comp": two])
            try s.execute("layerComp.restoreLastDocumentState")
            #expect(doc(s).captureCompStates() == edited)
        }
    }

    @Test func unrecordedPropertiesDoNotReplaceTheBackupOnReapply() throws {
        let (s, a, _) = try session(8)
        try s.execute("layerComp.new", ["position": false, "appearance": false])
        try s.execute("layer.translate", ["layer": .id(a), "dx": 10, "dy": 0])
        try s.execute("layer.setProps", ["layer": .id(a), "visible": false, "opacity": 0.5])
        let edited = doc(s).captureCompStates()
        try s.execute("layerComp.apply")
        #expect(doc(s).layer(a)?.visible == true)
        try s.execute("layerComp.apply")
        try s.execute("layerComp.restoreLastDocumentState")
        #expect(doc(s).captureCompStates() == edited)
    }

    @Test func manageCompsAndCycle() throws {
        let (s, _, b) = try session(8)
        let c1 = comp(try s.execute("layerComp.new", ["name": "One", "comment": "first"]))
        try s.edit("hide") { d, _ in d.updateLayer(b) { $0.visible = false } }
        let c2 = comp(try s.execute("layerComp.new", ["name": "Two"]))
        let c3 = comp(try s.execute("layerComp.duplicate", ["comp": .int(Int(c1))]))
        #expect(doc(s).layerComps.map(\.name) == ["One", "One copy", "Two"])
        try s.execute("layerComp.rename", ["comp": .int(Int(c3)), "name": "Three"])
        try s.execute("layerComp.setComment", ["comp": "Three", "comment": "dup"])
        #expect(doc(s).comp(c3)?.comment == "dup")
        // Next/previous cycle through the list order and wrap.
        try s.execute("layerComp.apply", ["comp": .int(Int(c2))])
        try s.execute("layerComp.next")
        #expect(doc(s).lastAppliedComp == c1)
        #expect(doc(s).layer(b)?.visible == true)
        try s.execute("layerComp.previous")
        #expect(doc(s).lastAppliedComp == c2)
        #expect(doc(s).layer(b)?.visible == false)
        let l = try s.execute("layerComp.list")
        #expect(l["comps"]?.arrayValue?.count == 3)
        #expect(l["lastApplied"] == .int(Int(c2)))
        // Update one property: the visibility recorded in "One" follows the document again.
        try s.execute("layerComp.update", ["comp": .int(Int(c1)), "what": "visibility"])
        #expect(doc(s).comp(c1)?.state(b)?.visible == false)
        let r = try s.execute("layerComp.update", ["comp": "*"])
        #expect(r["updated"]?.arrayValue?.count == 3)
    }

    @Test func warningsForDeletedLayers() throws {
        let (s, a, _) = try session(8)
        try s.execute("layerComp.new")
        #expect(try s.execute("layerComp.updateWarnings")["count"] == 0)
        try s.edit("del") { d, _ in _ = d.remove(a) }
        let w = try s.execute("layerComp.updateWarnings")
        #expect(w["count"] == 1)
        #expect(w["warnings"]?[0]?["missingLayers"]?[0] == .id(a))
        // Applying still works (missing layers are skipped) and reports them.
        #expect(try s.execute("layerComp.apply")["missingLayers"] == 1)
        try s.execute("layerComp.updateWarnings", ["clear": true])
        #expect(try s.execute("layerComp.updateWarnings")["count"] == 0)
    }

    @Test func disabledStatesAndBadParams() throws {
        let s = Session()
        #expect(!s.isEnabled("layerComp.new"))
        try s.execute("file.new", ["width": 8, "height": 8])
        #expect(s.isEnabled("layerComp.new"))
        for id in ["layerComp.apply", "layerComp.update", "layerComp.next", "layerComp.delete", "file.export.layerCompsToFiles", "layerComp.restoreLastDocumentState"] {
            #expect(!s.isEnabled(id), "\(id)")
        }
        try s.execute("layerComp.new")
        for (id, p): (String, JSONValue) in [
            ("layerComp.apply", ["comp": 999]), ("layerComp.apply", ["comp": "nope"]), ("layerComp.update", ["what": "colour"]),
            ("layerComp.rename", .object([:])), ("layerComp.setOptions", .object([:])),
        ] {
            #expect(throws: EngineError.self, "\(id) \(p)") { try s.execute(id, p) }
        }
        #expect(s.isEnabled("file.export.layerCompsToFiles"))
    }

    @Test func exportCompsToFilesNaming() throws {
        let (s, _, b) = try session(8)
        try s.execute("layerComp.new", ["name": "With B"])
        try s.edit("hide") { d, _ in d.updateLayer(b) { $0.visible = false } }
        try s.execute("layerComp.new", ["name": "No/B"])
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("photocraft-comps-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let r = try s.execute("file.export.layerCompsToFiles", ["dir": .string(dir.path), "prefix": "doc"])
        let files = r["files"]?.arrayValue?.compactMap(\.stringValue) ?? []
        try #require(files.count == 2)
        #expect(files[0].hasSuffix("doc_0000_With B.png"), "\(files)")
        #expect(files[1].hasSuffix("doc_0001_No_B.png"), "\(files)")
        // Each file shows its comp: B's blue square only in the first.
        func blue(_ path: String) throws -> SIMD4<Float> {
            let d = try EngineIO.importPath(path, services: s.services).document
            return try s.services.renderer.render(d, region: PixelRect(x0: 35, y0: 25, x1: 36, y1: 26)).px[0]
        }
        let b0 = try blue(files[0]), b1 = try blue(files[1])
        #expect(b0.z > 0.9 && b0.x < 0.1, "\(b0)")
        #expect(b1.z > 0.9 && b1.x > 0.9, "\(b1)")
        let r2 = try s.execute("file.export.layerCompsToFiles", ["dir": .string(dir.path), "selectedOnly": true, "format": "jpg"])
        #expect(r2["files"]?.arrayValue?.count == 1)
        // Layered: each comp as a PSD (for the Photoshop oracle too).
        let r3 = try s.execute("file.export.layerCompsToFiles", ["dir": .string(dir.path), "prefix": "comps", "format": "psd"])
        for (i, f) in (r3["files"]?.arrayValue?.compactMap(\.stringValue) ?? []).enumerated() {
            let d = try EngineIO.importPath(f, services: s.services).document
            #expect(d.layers.count == 3, "\(f)")
            dropForOracle(URL(fileURLWithPath: f), as: "comps-to-files-\(i).psd")
        }
    }

    @Test func outOfRangeCompIdsAreRejectedNotWrapped() throws {
        // #914: 2^32 + id used to wrap to a real comp.
        let s = Session()
        try s.execute("file.new", ["width": 16, "height": 16])
        let c = comp(try s.execute("layerComp.new", ["name": "Start"]))
        let wrapped = JSONValue.number(Double((UInt64(1) << 32) + UInt64(c)))
        #expect(throws: EngineError.self) { try s.execute("layerComp.delete", ["comp": wrapped]) }
        #expect(throws: EngineError.self) { try s.execute("layerComp.setOptions", ["comp": wrapped, "name": "renamed"]) }
        #expect(doc(s).layerComps.count == 1)
        #expect(doc(s).layerComps.first?.name == "Start")
        #expect(throws: EngineError.self) { try s.execute("file.export.layerCompsToFiles", ["dir": "/tmp", "comps": [wrapped]]) }
    }

    @Test func unreachableCompPositionsLeaveTheLayerInPlace() throws {
        // #1017: a recorded position whose distance from the layer's current one leaves Int32 range
        // (e.g. from a file) is skipped; visibility still applies.
        for target in [SIMD2<Int32>(Int32.min, 4), SIMD2(4, Int32.min)] {
            let (s, a, b) = try session(8)
            let c = LayerComp(id: 1, name: "Far", comment: "", applyVisibility: true, applyPosition: true, applyAppearance: false, states: [
                CompLayerState(layer: a, visible: false, position: target),
                // Control: an ordinary position on another layer still moves it.
                CompLayerState(layer: b, position: SIMD2(31, 22)),
            ])
            try s.edit("far") { d, _ in CompsCommands.applyComp(&d, c, all: false) }
            #expect(pos(s, a) == SIMD2(4, 4), "\(target)")
            #expect(doc(s).layer(a)?.visible == false)
            #expect(pos(s, b) == SIMD2(31, 22))
        }
    }
}
