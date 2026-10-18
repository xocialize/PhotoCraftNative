// PhotoCraftNative's own tests (AB-T-0324): `layer.layerMask.copy`, the Layers panel's drag and ⌥-drag of a mask
// thumbnail onto another layer. MIT OR Apache-2.0, © ArtCraft Team and the PhotoCraft contributors.

import PCDocument
import PCEngine
import PCFoundation
import Testing

@Suite struct LayerMaskCopyTests {
    let cmd = "layer.layerMask.copy"

    /// A Background, a plain pixel layer, a group, and a masked layer on top: a Hide All mask (black outside its
    /// content) revealing a 4 × 4 square at (2, 3), at 40 % density, 1.5 px feather, unlinked.
    func session(_ depth: SampleType = .u8) -> (s: Session, background: LayerId, plain: LayerId, group: LayerId, masked: LayerId, mask: LayerMask) {
        var doc = Document.withBackground(name: "Masks", size: PixelSize(width: 12, height: 10), mode: .rgb, depth: depth,
                                          fill: PCColor(mode: .rgb, c: SIMD4(1, 1, 1, 0)))
        let background = doc.layers[0].id
        let plain = Layer.raster("Plain", format: doc.pixelFormat)
        let group = Layer.group("Folder", [])
        var masked = Layer.raster("Masked", format: doc.pixelFormat)
        var surface = Surface(format: PixelFormat(mode: .grayscale, sample: depth, alpha: false), defaultPixel: [0])
        surface.fill(PixelRect(x0: 2, y0: 3, x1: 6, y1: 7), with: [1])
        let mask = LayerMask(surface: surface, enabled: true, linked: false, density: 0.4, feather: 1.5)
        masked.mask = mask
        doc.layers += [plain, group, masked]
        let s = Session()
        s.addDocument(doc)
        try? s.selectLayer(masked.id)
        return (s, background, plain.id, group.id, masked.id, mask)
    }

    @Test func copyingKeepsEverythingAboutTheMaskInOneStep() throws {
        for depth in [SampleType.u8, .u16, .f32] {
            let (s, _, plain, _, masked, mask) = session(depth)
            let before = try #require(s.active?.doc)
            let steps = try #require(s.active?.history.entries.count)
            #expect(s.isEnabled(cmd, ["from": .id(masked), "to": .id(plain)]))
            let r = try s.execute(cmd, ["from": .id(masked), "to": .id(plain)])
            #expect(r == ["layer": .id(plain), "replaced": false, "moved": false])
            let doc = try #require(s.active?.doc)
            let copy = try #require(doc.layer(plain)?.mask)
            #expect(copy == mask, "pixels where they sit, the outside value, density, feather, enabled and linked")
            #expect(copy.surface.pixel(x: 0, y: 0) == [0] && copy.surface.pixel(x: 100, y: 100) == [0], "a Hide All mask's black outside")
            #expect(copy.surface.pixel(x: 3, y: 4) == [1])
            #expect(doc.layer(masked)?.mask == mask, "a copy leaves the source's mask")
            #expect(s.active?.history.entries.count == steps + 1)
            #expect(s.active?.history.undoLabel == "Copy Layer Mask")
            #expect(s.active?.activeLayer == plain && s.active?.selectedLayers == [plain], "the target becomes the active layer")
            try s.execute("edit.undo")
            #expect(s.active?.doc == before)
            try s.execute("edit.redo")
            #expect(s.active?.doc.layer(plain)?.mask == mask)
        }
    }

    @Test func movingDeletesTheSourcesMaskInTheSameStep() throws {
        let (s, _, plain, _, masked, mask) = session()
        let before = try #require(s.active?.doc)
        let steps = try #require(s.active?.history.entries.count)
        let r = try s.execute(cmd, ["from": .id(masked), "to": .id(plain), "move": true])
        #expect(r == ["layer": .id(plain), "replaced": false, "moved": true])
        #expect(s.active?.doc.layer(plain)?.mask == mask)
        #expect(s.active?.doc.layer(masked)?.mask == nil)
        #expect(s.active?.history.entries.count == steps + 1)
        #expect(s.active?.history.undoLabel == "Move Layer Mask")
        try s.execute("edit.undo")
        #expect(s.active?.doc == before)
    }

    @Test func aTargetsOwnMaskIsReplaced() throws {
        let (s, _, plain, _, masked, mask) = session()
        try s.execute("layer.layerMask.revealAll", ["layer": .id(plain)])
        // `from` defaults to the active layer.
        try s.selectLayer(masked)
        let r = try s.execute(cmd, ["to": .id(plain)])
        #expect(r == ["layer": .id(plain), "replaced": true, "moved": false])
        #expect(s.active?.doc.layer(plain)?.mask == mask)
        #expect(s.active?.history.undoLabel == "Replace Layer Mask")
        try s.execute("edit.undo")
        #expect(s.active?.doc.layer(plain)?.mask == .revealAll())
    }

    @Test func foldersAndTheBackgroundTakeAMask() throws {
        let (s, background, _, group, masked, mask) = session()
        try s.execute(cmd, ["from": .id(masked), "to": .id(group)])
        #expect(s.active?.doc.layer(group)?.mask == mask, "folders take masks, as in Photoshop")
        try s.execute(cmd, ["from": .id(masked), "to": .id(background)])
        let doc = try #require(s.active?.doc)
        #expect(doc.layer(background)?.mask == mask)
        #expect(doc.background == nil && doc.layer(background)?.name == "Layer 0", "the Background becomes a layer, as Add Layer Mask makes it")
    }

    @Test func refusals() throws {
        let (s, _, plain, group, masked, _) = session()
        let revision = s.active?.revision
        let cases: [(JSONValue, String)] = [
            (["from": .id(plain), "to": .id(group)], "has no layer mask"),
            (["from": .id(masked), "to": .id(masked)], "the same layer"),
            (["from": .id(masked)], "`to` (a layer id) is required"),
            (["from": .id(masked), "to": .id(LayerId(999_999))], "999999"),
            (["from": .id(masked), "to": .id(plain), "move": "yes"], "`move` must be a bool"),
        ]
        for (p, reason) in cases {
            #expect(throws: EngineError.self) { try s.execute(cmd, p) }
            do {
                try s.execute(cmd, p)
            } catch {
                #expect("\(error)".contains(reason), "\(p): \(error)")
            }
        }
        #expect(!s.isEnabled(cmd, ["from": .id(plain), "to": .id(group)]))
        #expect(!s.isEnabled(cmd, ["from": .id(masked), "to": .id(masked)]))
        #expect(s.active?.revision == revision, "nothing changed")
        let spec = try #require(s.registry.spec(cmd))
        #expect(spec.menu.isEmpty, "a drag in the Layers panel: no menu item")
    }
}
