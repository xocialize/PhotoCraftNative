// Port of photocraft-engine (crates/engine/src/layer_mask_props_cmds/tests.rs), MIT OR Apache-2.0, © ArtCraft Team and the PhotoCraft contributors.

import Foundation
import PCDocument
import PCEngine
import PCFoundation
import Testing

@Suite struct LayerMaskPropsTests {
    let edit = "layer.layerMask.edit"

    func session(_ depth: SampleType, adjustment: Bool) -> (Session, LayerId, LayerId) {
        var doc = Document(name: "Masks", size: PixelSize(width: 8, height: 8), mode: .rgb, depth: depth)
        let background = Layer.raster("Unmasked", format: doc.pixelFormat)
        doc.layers.append(background)
        var layer = adjustment ? Layer(name: "Adjustment", content: .adjustment(.invert)) : Layer.raster("Pixels", format: doc.pixelFormat)
        var surface = Surface(format: PixelFormat(mode: .grayscale, sample: depth, alpha: false), defaultPixel: [1])
        surface.fill(PixelRect(x0: 1, y0: 2, x1: 5, y1: 6), with: [0.25])
        layer.mask = LayerMask(surface: surface, enabled: !adjustment, linked: false, density: 1, feather: 0)
        layer.vectorMask = VectorMask(path: VectorPath(inverted: true))
        let id = layer.id
        doc.layers.append(layer)
        doc.selection = Surface(format: .gray8, defaultPixel: [0.5])
        let s = Session()
        s.addDocument(doc)
        return (s, id, background.id)
    }

    @Test func editsPreserveMaskPixelsAndLayerAtAllDepthsWithUndoRedo() throws {
        for depth in [SampleType.u8, .u16, .f32] {
            for adjustment in [false, true] {
                let (s, id, background) = session(depth, adjustment: adjustment)
                // Explicit targets work even when another layer is active.
                try s.selectLayer(background)
                let before = try #require(s.active?.doc)
                let count = try #require(s.active?.history.entries.count)
                let result = try s.execute(edit, ["layer": .id(id), "document": .number(Double(before.id.rawValue)), "density": 25, "feather": 2.5])
                #expect(result == ["layer": .id(id), "density": 25, "feather": 2.5])
                var expected = before
                expected.updateLayer(id) { l in
                    l.mask?.density = 0.25
                    l.mask?.feather = 2.5
                }
                #expect(s.active?.doc == expected, "only density and feather change")
                #expect(s.active?.activeLayer == background)
                #expect(s.active?.history.entries.count == count + 1)
                try s.execute("edit.undo")
                #expect(s.active?.doc == before)
                try s.execute("edit.redo")
                #expect(s.active?.doc == expected)
                let revision = s.active?.revision
                try s.execute(edit, ["layer": .id(id), "density": 25])
                #expect(s.active?.revision == revision, "same value is not an edit")
                #expect(s.active?.history.entries.count == count + 1)
            }
        }
    }

    func render(_ s: Session) throws -> [SIMD4<Float>] {
        let doc = try #require(s.active?.doc)
        return try s.services.renderer.render(doc, region: doc.bounds).px
    }

    @Test func propertyCommandsUpdateRenderedEdgesWithoutRewritingTheMask() throws {
        for depth in [SampleType.u8, .u16, .f32] {
            for adjustment in [false, true] {
                var doc = Document(name: "Mask edge", size: PixelSize(width: 64, height: 8), mode: .rgb, depth: depth)
                var background = Layer.raster("White", format: doc.pixelFormat)
                background.withRaster { $0.fill(doc.bounds, with: [1, 1, 1, 1]) }
                doc.layers.append(background)
                var layer: Layer
                if adjustment {
                    layer = Layer(name: "Invert", content: .adjustment(.invert))
                } else {
                    layer = Layer.raster("Black", format: doc.pixelFormat)
                    layer.withRaster { $0.fill(doc.bounds, with: [0, 0, 0, 1]) }
                }
                var surface = Surface(format: PixelFormat(mode: .grayscale, sample: depth, alpha: false))
                surface.fill(PixelRect(x0: 0, y0: 0, x1: 32, y1: 8), with: [1])
                let raw = surface
                layer.mask = LayerMask(surface: surface, enabled: true, linked: true, density: 1, feather: 0)
                let id = layer.id
                doc.layers.append(layer)
                let s = Session()
                s.addDocument(doc)
                let at = { (px: [SIMD4<Float>], x: Int) in px[4 * 64 + x].x }
                let original = try render(s)
                #expect(at(original, 31) < 0.01 && at(original, 32) > 0.99)
                try s.execute(edit, ["density": 50])
                #expect(abs(at(try render(s), 60) - 0.5) < 0.01, "density reveals the hidden side")
                try s.execute(edit, ["feather": 8])
                let softHalf = try render(s)
                #expect(at(softHalf, 31) > 0.15 && at(softHalf, 32) < 0.35, "feather softens both sides of the edge")
                try s.execute(edit, ["density": 100])
                let softFull = try render(s)
                for x in [31, 32, 60] {
                    #expect(abs(at(softFull, x) - 2 * at(softHalf, x)) < 0.01, "density refreshes the cached feathered mask")
                }
                try s.execute(edit, ["feather": 0])
                #expect(try render(s) == original, "clearing feather restores the sharp edge")
                #expect(s.active?.doc.layer(id)?.mask?.surface == raw)
                try s.execute("edit.undo")
                #expect(try render(s) == softFull)
                try s.execute("edit.redo")
                #expect(try render(s) == original)
            }
        }
    }

    @Test func sliderUpdatesCoalesceWithoutMergingSeparateGestures() throws {
        let (s, id, _) = session(.u16, adjustment: false)
        let before = try #require(s.active?.doc)
        let count = try #require(s.active?.history.entries.count)
        for density in [80, 50, 0] {
            try s.execute(edit, ["density": .int(density), "coalesce": "mask-density-drag"])
        }
        let densityOnly = try #require(s.active?.doc)
        #expect(s.active?.history.entries.count == count + 1)
        for feather in [2.5, 1000.0] {
            try s.execute(edit, ["feather": .number(feather), "coalesce": "mask-feather-drag"])
        }
        let done = try #require(s.active?.doc)
        #expect(s.active?.history.entries.count == count + 2)
        #expect(done.layer(id)?.mask?.density == 0 && done.layer(id)?.mask?.feather == 1000)
        try s.execute("edit.undo")
        #expect(s.active?.doc == densityOnly)
        try s.execute("edit.undo")
        #expect(s.active?.doc == before)
        try s.execute("edit.redo")
        try s.execute("edit.redo")
        #expect(s.active?.doc == done)
    }

    @Test func malformedParamsMissingMasksAndStaleDocumentsDoNotEdit() throws {
        let (s, _, background) = session(.u8, adjustment: false)
        let before = try #require(s.active?.doc)
        let count = try #require(s.active?.history.entries.count)
        let revision = try #require(s.active?.revision)
        let bad: [JSONValue] = [
            .null, [], [:], ["density": "50"], ["density": .null], ["density": -0.01], ["density": 100.01], ["feather": false],
            ["feather": -0.01], ["feather": 1000.01], ["feather": 1e100], ["density": 25, "feather": []], ["layer": "bad", "density": 25],
            ["layer": .null, "density": 25], ["layer": -1, "density": 25], ["layer": .number(Double(UInt64.max)), "density": 25],
            ["layer": .id(background), "density": 25], ["document": "bad", "density": 25], ["document": .number(Double(UInt64.max)), "density": 25],
        ]
        for p in bad {
            #expect(throws: EngineError.self, "\(p)") { try s.execute(edit, p) }
            let st = try #require(s.active)
            #expect(st.doc == before, "\(p)")
            #expect(st.history.entries.count == count && st.revision == revision, "\(p)")
        }
        let empty = Session()
        #expect(!empty.isEnabled(edit))
        #expect(throws: EngineError.self) { try empty.execute(edit, ["density": 50]) }
    }
}
