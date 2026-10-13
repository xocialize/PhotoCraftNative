// Port of photocraft-engine (crates/engine/src/select_extra_cmds.rs `mod tests` and `mod hang_tests`), MIT OR Apache-2.0, © ArtCraft Team and the PhotoCraft contributors.
//
// Every photocraft test is ported. Added: the ids match photocraft's metadata.

import Foundation
import PCDocument
import PCEngine
import PCFoundation
import Testing

@Suite struct SelectExtraCommandsTests {
    @Test func isolateLayersToggles() throws {
        let s = Session()
        try s.execute("file.new", ["width": 20, "height": 20])
        try s.execute("layer.new.layer")
        let active = try #require(s.active?.activeLayer)
        var r = try s.execute("select.isolateLayers")
        #expect(r["isolated"] == true)
        #expect(r["layers"] == .ids([active]))
        let d = s.active!
        let bg = d.doc.layers[0].id
        let isolated = d.view[SelectExtraCommands.IsolatedLayersKey.self]
        #expect(SelectExtraCommands.isolationShows(d.doc, isolated, active))
        #expect(!SelectExtraCommands.isolationShows(d.doc, isolated, bg))
        #expect(try s.execute("document.inspect")["isolatedLayers"] == .ids([active]))
        r = try s.execute("select.isolateLayers")
        #expect(r["isolated"] == false)
        #expect(s.active!.view[SelectExtraCommands.IsolatedLayersKey.self].isEmpty)
    }

    @Test func isolationShowsTheGroupsAboveAnIsolatedLayer() throws {
        var doc = Document(name: "t", size: PixelSize(width: 4, height: 4), mode: .rgb, depth: .u8)
        let inner = Layer.raster("in", format: doc.pixelFormat), other = Layer.raster("other", format: doc.pixelFormat)
        let group = Layer.group("G", [inner])
        doc.layers = [other, group]
        #expect(SelectExtraCommands.isolationShows(doc, [inner.id], group.id), "the group holding it")
        #expect(SelectExtraCommands.isolationShows(doc, [inner.id], inner.id))
        #expect(!SelectExtraCommands.isolationShows(doc, [inner.id], other.id))
        #expect(SelectExtraCommands.isolationShows(doc, [], other.id), "not isolated: everything shows")
    }

    // MARK: Sky

    /// A landscape: a sky gradient over the top 60 rows, a dark-green tree crown at (112, 35)
    /// and noisy brown ground below.
    func landscape(_ depth: Int) throws -> Session {
        let s = Session()
        try s.execute("file.new", ["width": 160, "height": 100, "depth": .int(depth)])
        try s.edit("paint") { doc, a in
            guard let id = a else { throw EngineError.other("no layer") }
            doc.withRaster(of: id) { surf in
                let n = surf.channels
                for y in 0..<100 {
                    for x in 0..<160 {
                        let (cx, cy): (Float, Float) = (112, 35)
                        let crown = ((Float(x) - cx) * (Float(x) - cx) + (Float(y) - cy) * (Float(y) - cy)).squareRoot() < 18
                        let nz = (Float((x * 7919 + y * 104_729) % 97) / 97 - 0.5) * 0.25
                        let c: [Float]
                        if crown {
                            c = [0.1 + nz * 0.5, 0.35 + nz, 0.1]
                        } else if y < 60 {
                            let t = Float(y) / 60
                            c = [0.25 + 0.4 * t, 0.5 + 0.3 * t, 0.9 + 0.05 * t]
                        } else {
                            c = [0.35 + nz, 0.3 + nz, 0.15]
                        }
                        var px = [Float](repeating: 1, count: n)
                        for k in 0..<min(3, n) { px[k] = c[k] }
                        surf.setPixel(x: Int32(x), y: Int32(y), px)
                    }
                }
            }
        }
        return s
    }

    func selBounds(_ s: Session) -> PixelRect? { s.active?.doc.selection?.contentBounds }

    @Test func skySelectsTheSkyAtEveryDepth() throws {
        for depth in [8, 16, 32] {
            let s = try landscape(depth)
            let r = try s.execute("select.sky")
            #expect(r["changed"] == true, "\(depth)")
            let cov = try #require(r["coverage"]?.doubleValue)
            #expect(cov > 0.45 && cov < 0.62, "depth \(depth): coverage \(cov)")
            let sel = try #require(s.active?.doc.selection)
            #expect(sel.sampleChannel(x: 10, y: 10, 0) > 0.9, "\(depth)")
            #expect(sel.sampleChannel(x: 10, y: 90, 0) < 0.1, "\(depth)")
            #expect(sel.sampleChannel(x: 112, y: 35, 0) < 0.1, "\(depth): tree")
            s.undo()
            #expect(s.active?.doc.selection == nil)
        }
    }

    @Test func skyWithoutSkyChangesNothing() throws {
        let s = Session()
        try s.execute("file.new", ["width": 40, "height": 40])
        _ = try? s.execute("edit.fill", ["color": "#504020"])
        let r = try s.execute("select.sky")
        #expect(r["changed"] == false)
        #expect(s.active?.doc.selection == nil)
    }

    // MARK: Transform Selection

    func rectSel() throws -> Session {
        let s = Session()
        try s.execute("file.new", ["width": 100, "height": 100])
        try s.execute("select.rect", ["x": 20, "y": 30, "width": 20, "height": 10])
        return s
    }

    @Test func transformSelectionScalesRotatesAndMoves() throws {
        let s = try rectSel()
        #expect(selBounds(s) == PixelRect(x0: 20, y0: 30, x1: 40, y1: 40))
        let full = PixelRect(x0: 0, y0: 0, x1: 100, y1: 100)
        let px0 = s.active?.doc.layers[0].surface?.readRegion(full)
        try s.execute("select.transformSelection", ["scaleX": 200, "scaleY": 200])
        let b = try #require(selBounds(s))
        #expect(abs(b.x0 - 10) <= 1 && abs(b.x1 - 50) <= 1 && abs(b.y0 - 25) <= 1 && abs(b.y1 - 45) <= 1, "\(b)")
        // Pixels untouched.
        #expect(s.active?.doc.layers[0].surface?.readRegion(full) == px0)
        s.undo()
        #expect(selBounds(s) == PixelRect(x0: 20, y0: 30, x1: 40, y1: 40))
        try s.execute("select.transformSelection", ["rotate": 90])
        let rb = try #require(selBounds(s))
        #expect(abs(rb.width - 10) <= 2 && abs(rb.height - 20) <= 2, "\(rb)")
        s.undo()
        try s.execute("select.transformSelection", ["dx": 30, "dy": -10, "reference": "topLeft"])
        #expect(selBounds(s) == PixelRect(x0: 50, y0: 20, x1: 70, y1: 30))
    }

    @Test func transformSelectionPerspectiveAndWarp() throws {
        let s = try rectSel()
        try s.execute("select.transformSelection", ["corners": [[25, 30], [35, 30], [45, 40], [15, 40]]])
        let sel = try #require(s.active?.doc.selection)
        #expect(sel.sampleChannel(x: 17, y: 39, 0) > 0.5 && sel.sampleChannel(x: 21, y: 31, 0) < 0.5)
        s.undo()
        let r = try s.execute("select.transformSelection", ["style": "arc", "bend": 50])
        #expect(r["changed"] == true)
        #expect(selBounds(s) != PixelRect(x0: 20, y0: 30, x1: 40, y1: 40))
        #expect(throws: (any Error).self) { try s.execute("select.transformSelection", ["scaleX": 0]) }
    }

    @Test func transformSelectionNeedsASelection() throws {
        let s = Session()
        try s.execute("file.new", ["width": 10, "height": 10])
        #expect(!s.isEnabled("select.transformSelection"))
    }

    /// Regression (panic_hunt): a huge off-canvas transform used to allocate a buffer spanning
    /// the old + new bounds and hang. It must return quickly without crashing.
    @Test func transformSelectionWithExtremeParamsTerminates() throws {
        let s = Session()
        try s.execute("file.new", ["width": 24, "height": 16])
        try s.execute("select.rect", ["x": 1, "y": 1, "width": 6, "height": 5])
        // dx/dy move the selection far off-canvas; scaleX enlarges it.
        #expect(throws: Never.self) { try s.execute("select.transformSelection", ["dx": 1e5, "dy": -1e5, "scaleX": 300.0]) }
        // The document is still usable.
        try s.execute("select.all")
    }

    @Test func idsMatchPhotocraft() throws {
        let s = Session()
        for id in ["select.sky", "select.isolateLayers", "select.transformSelection"] {
            let spec = try #require(s.registry.spec(id))
            let pc = try #require(PhotocraftCatalog.byId[id])
            #expect(spec.isAvailable)
            #expect(spec.module == pc.module && spec.label == pc.label && spec.menu == pc.menu && spec.shortcut == pc.shortcut && spec.params == pc.params, "\(id)")
        }
    }
}
