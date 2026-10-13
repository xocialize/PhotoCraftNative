// Port of photocraft-engine (crates/engine/src/warp_cmds.rs tests), MIT OR Apache-2.0, © ArtCraft Team and the PhotoCraft contributors.
//
// Every photocraft test is ported. Added: the ids match photocraft's metadata, and
// `smartObjectWarpIsStoredInSourceSpace` (the stored warp on an object whose source can't be
// re-rendered: the cache is warped).

import Foundation
import PCAlgo
import PCDocument
@testable import PCEngine
import PCFoundation
import Testing

@Suite struct WarpTests {
    /// 80×60 document at `depth`, a new layer with a patterned 50×30 block at (10, 10).
    func session(_ depth: Int) throws -> Session {
        let s = Session()
        try s.execute("file.new", ["width": 80, "height": 60, "depth": .int(depth)])
        try s.execute("layer.new.layer")
        try s.edit("paint") { doc, a in
            guard let id = a else { throw EngineError.other("no layer") }
            doc.withRaster(of: id) { surf in
                for y in Int32(10)..<40 {
                    for x in Int32(10)..<60 {
                        let v = Float((x * 3 + y * 5) % 11) / 10
                        surf.setPixel(x: x, y: y, [v, 1 - v, 0.5, 1])
                    }
                }
            }
        }
        return s
    }

    func active(_ s: Session) -> Layer? { s.active.flatMap { st in st.activeLayer.flatMap { st.doc.layer($0) } } }

    func activeSurface(_ s: Session) -> Surface { active(s)?.surface ?? Surface(format: PixelFormat(mode: .rgb, sample: .u8, alpha: true)) }

    func smart(_ s: Session) -> SmartObject? {
        if case .smart(let sm)? = active(s)?.content { return sm }
        return nil
    }

    /// The active pixel layer as a smart object whose cache is its pixels and whose source can't
    /// be re-rendered (the cache is warped; SmartTests covers re-rendering from the source).
    func makeSmart(_ s: Session) throws {
        let id = try #require(s.active?.activeLayer)
        try s.edit("smart") { doc, _ in
            doc.updateLayer(id) { l in
                guard let surf = l.surface else { return }
                l.content = .smart(SmartObject(source: .linked(path: ""), transform: .identity, cache: surf))
            }
        }
    }

    func decodeWarp(_ v: JSONValue?) throws -> Warp { try #require(v).decode(as: Warp.self) }

    /// Warp on type sets its Warp Text (#3004): the layer stays type, one step; a custom mesh is
    /// refused rather than rasterizing.
    @Test func warpStyleOnTypeIsWarpText() throws {
        let s = Session()
        try s.execute("file.new", ["width": 200, "height": 100])
        try s.execute("type.create", ["x": 10, "y": 60, "text": "Hi"])
        let n = s.active?.history.pastCount ?? 0
        try s.execute("edit.transform.warp", ["style": "arc", "bend": 30])
        guard case .text(let t)? = active(s)?.content else { Issue.record("type"); return }
        #expect(t.warp?.style == "warpArc" && t.warp?.value == 30)
        #expect(s.active?.history.pastCount == n + 1)
        let b = SIMD4<Double>(0, 0, 10, 10)
        let mesh = BezierMesh.identity(bounds: b, cols: 1, rows: 1).mapPoints { SIMD2($0.x * 2, $0.y) }
        #expect(throws: (any Error).self) { try s.execute("edit.transform.warp", ["warp": .encoded(Warp.custom(mesh, bounds: b))]) }
    }

    @Test func identityAndBendZeroAreNoOpsAtEveryDepth() throws {
        for depth in [8, 16, 32] {
            let s = try session(depth)
            let before = activeSurface(s)
            let r = try s.execute("edit.transform.warp", ["style": "custom"])
            #expect(r["changed"] == false)
            try s.execute("edit.transform.warp", ["style": "flag", "bend": 0])
            // A custom identity mesh passed explicitly (forces a resample) stays within 1/255.
            let b = SIMD4<Double>(10, 10, 60, 40)
            var w = Warp.custom(BezierMesh.identity(bounds: b, cols: 2, rows: 2), bounds: b)
            w.mesh?.points[5].x += 1e-12 // not exactly identity
            try s.execute("edit.transform.warp", ["warp": .encoded(w)])
            let after = activeSurface(s)
            let r0 = PixelRect(x0: 10, y0: 10, x1: 60, y1: 40)
            #expect(after.contentBounds == r0, "\(depth)")
            let worst = zip(before.readRegion(r0), after.readRegion(r0)).map { abs($0 - $1) }.max() ?? 0
            #expect(worst <= 1 / 255, "\(depth): \(worst)")
        }
    }

    @Test func arcWarpsPixelsAndUndoes() throws {
        let s = try session(8)
        let before = activeSurface(s)
        try s.execute("edit.transform.warp", ["style": "arc", "bend": 50])
        let after = activeSurface(s)
        // As in Photoshop: the bottom edge keeps its corners, the top rises and spreads.
        let c = after.contentBounds
        #expect(c.y1 <= 41 && c.y0 < 8 && c.x0 < 8 && c.x1 > 62, "\(c)")
        s.undo()
        #expect(activeSurface(s) == before)
        #expect(throws: (any Error).self) { try s.execute("edit.transform.warp", ["style": "spiral"]) }
        #expect(throws: (any Error).self) { try s.execute("edit.transform.warp", [:]) }
        #expect(throws: (any Error).self) { try s.execute("edit.transform.warp", ["mesh": ["us": [0, 1], "vs": [0, 1], "points": [[0, 0]]]]) }
    }

    @Test func customMeshMovesAControlPoint() throws {
        let s = try session(16)
        var mesh = BezierMesh.identity(bounds: SIMD4(10, 10, 60, 40), cols: 1, rows: 1)
        mesh.points[15] = SIMD2(70, 50) // bottom-right corner
        try s.execute("edit.transform.warp", ["mesh": .encoded(mesh)])
        let b = activeSurface(s).contentBounds
        #expect(b.x1 >= 69 && b.y1 >= 49, "\(b)")
    }

    @Test func splitCutsExistingSectionsInsteadOfReplacingTheGrid() throws {
        let b = SIMD4<Double>(0, 0, 90, 60)
        let plain = Warp.custom(BezierMesh.identity(bounds: b, cols: 1, rows: 1), bounds: b)
        let cut = try #require(WarpCommands.splitWarp(plain, at: SIMD2(b.x + 0.25 * 90, 30), .vertical))
        let m = try #require(cut.mesh)
        for u in [0, 0.25, 1.0 / 3, 2.0 / 3, 1] {
            #expect(m.us.contains { abs($0 - u) < 1e-6 }, "default guides stay, cut at 0.25: \(m.us)")
        }
        #expect(m.vs == [0, 1.0 / 3, 2.0 / 3, 1])
        let grid = BezierMesh.identity(bounds: b, cols: 3, rows: 3)
        let cut2 = try #require(WarpCommands.splitWarp(Warp.custom(grid, bounds: b), at: SIMD2(45, 10), .vertical))
        let m2 = try #require(cut2.mesh)
        #expect(m2.vs == grid.vs)
        #expect(m2.us.count == grid.us.count + 1)
        for u in [0, 1.0 / 3, 0.5, 2.0 / 3, 1] { #expect(m2.us.contains { abs($0 - u) < 1e-6 }, "\(m2.us)") }
        let (nx0, nx1) = (grid.nx, m2.nx)
        for j in 0..<grid.ny { for i in 0..<3 { #expect(m2.points[j * nx1 + i] == grid.points[j * nx0 + i]) } }
    }

    @Test func splitCommandsEditMeshesExactly() throws {
        let s = try session(8)
        let w = Warp.preset(.bulge, bend: 30, bounds: SIMD4(10, 10, 60, 40))
        let split = try decodeWarp(try s.execute("edit.transform.splitWarpCrosswise", ["warp": .encoded(w), "at": [30.0, 20.0]])["warp"])
        let m = try #require(split.mesh)
        #expect((m.nx, m.ny) == (7, 7))
        let v = try decodeWarp(try s.execute("edit.transform.splitWarpVertically", ["warp": .encoded(split)])["warp"])
        #expect(v.mesh?.us.count == 4)
        let back = try decodeWarp(try s.execute("edit.transform.removeWarpSplit", ["warp": .encoded(v), "at": [30.0, 20.0]])["warp"])
        #expect((back.mesh?.us.count ?? 99) + (back.mesh?.vs.count ?? 99) < 7)
        // Splitting never changes the shape.
        for (x, y) in [(15.0, 15.0), (40.0, 33.0)] {
            let (a, b) = (w.map(x, y), split.map(x, y))
            #expect(abs(a.x - b.x) < 0.6 && abs(a.y - b.y) < 0.6, "\(a) \(b)")
        }
    }

    /// Adapted from `smart_object_warp_is_lossless` (see the header).
    @Test func smartObjectWarpIsLossless() throws {
        for depth in [8, 16, 32] {
            let s = try session(depth)
            try s.execute("layer.smartObjects.convertToSmartObject")
            let original = activeSurface(s)
            try s.execute("layer.smartObjects.warp", ["style": "wave", "bend": 60])
            let warped = activeSurface(s)
            #expect(warped != original, "\(depth)")
            #expect(smart(s)?.warp != nil)
            // Removing the warp re-renders the source exactly (no accumulated resampling).
            try s.execute("layer.smartObjects.warp", ["style": "none"])
            #expect(activeSurface(s) == original, "\(depth)")
            // Warping twice equals warping once with the second warp.
            try s.execute("layer.smartObjects.warp", ["style": "arc", "bend": 20])
            try s.execute("layer.smartObjects.warp", ["style": "wave", "bend": 60])
            #expect(activeSurface(s) == warped, "\(depth)")
            // Split on the stored warp keeps the appearance (within resampling of the mesh fit).
            try s.execute("edit.transform.splitWarpCrosswise")
            #expect(smart(s)?.warp?.style == .custom, "\(depth)")
        }
    }

    @Test func smartObjectWarpIsStoredInSourceSpace() throws {
        for depth in [8, 16, 32] {
            let s = try session(depth)
            try makeSmart(s)
            let original = activeSurface(s)
            try s.execute("layer.smartObjects.warp", ["style": "wave", "bend": 60])
            #expect(activeSurface(s) != original, "\(depth)")
            #expect(smart(s)?.warp?.style == .wave)
            #expect(smart(s)?.warp?.bounds == SIMD4(10, 10, 60, 40), "identity placement: source space is document space")
            // The frame of a warped smart object is its unwarped source box.
            #expect(WarpCommands.warpBounds(try #require(s.active?.doc), try #require(active(s))) == PixelRect(x0: 10, y0: 10, x1: 60, y1: 40))
            // Removing the warp clears the stored warp.
            try s.execute("layer.smartObjects.warp", ["style": "none"])
            #expect(smart(s)?.warp == nil)
            try s.execute("layer.smartObjects.warp", ["style": "arc", "bend": 20])
            // Split on the stored warp makes it custom.
            try s.execute("edit.transform.splitWarpCrosswise")
            #expect(smart(s)?.warp?.style == .custom, "\(depth)")
            // Warp Grid on the stored warp.
            let r = try s.execute("edit.transform.warpGrid", ["size": 3])
            #expect(try decodeWarp(r["warp"]).mesh?.us == [0, 1.0 / 3, 2.0 / 3, 1])
        }
    }

    @Test func crosswiseSplitOfAnIdentityCustomWarpIsFourByFour() throws {
        let s = try session(8)
        let r = try s.execute("edit.transform.splitWarpCrosswise", ["style": "custom", "rect": [0.0, 0.0, 90.0, 60.0]])
        let m = try #require(try decodeWarp(r["warp"]).mesh)
        #expect((m.us.count, m.vs.count) == (5, 5), "thirds, then the centre cut: \(m.us) \(m.vs)")
        for u in [0, 1.0 / 3, 0.5, 2.0 / 3, 1] {
            #expect(m.us.contains { abs($0 - u) < 1e-6 }, "\(m.us)")
            #expect(m.vs.contains { abs($0 - u) < 1e-6 }, "\(m.vs)")
        }
    }

    @Test func extremeRectIsBadParamsNotAGiantWarp() throws {
        let s = try session(8)
        for cmd in ["edit.transform.warp", "layer.smartObjects.warp"] {
            if cmd == "layer.smartObjects.warp" { try s.execute("layer.smartObjects.convertToSmartObject") }
            do {
                try s.execute(cmd, ["style": "arc", "bend": 50, "rect": [-1e30, -1e30, 1e30, 1e30]])
                Issue.record("\(cmd): no error")
            } catch let e as EngineError {
                guard case .badParams(_, let msg) = e else { Issue.record("\(cmd): \(e)"); continue }
                #expect(msg.contains("rect too large"), "\(cmd): \(msg)")
            }
        }
        try s.execute("layer.smartObjects.warp", ["style": "arc", "bend": 50, "rect": [10, 10, 60, 40]])
    }

    @Test func warpGridFitsTheSurfaceAndRejectsBadSizes() throws {
        let s = try session(8)
        for p: JSONValue in [[:], ["size": 0], ["size": -3], ["size": 65], ["size": 1.5], ["size": "custom"], ["size": "nope"], ["grid": [3, 3]]] {
            #expect(throws: (any Error).self, "\(p.serialized())") { try s.execute("edit.transform.warpGrid", p) }
        }
        let b = SIMD4<Double>(10, 10, 60, 40)
        var bent = BezierMesh.identity(bounds: b, cols: 1, rows: 1)
        bent.points[0].x += 12
        let out = try decodeWarp(try s.execute("edit.transform.warpGrid", ["warp": .encoded(Warp.custom(bent, bounds: b)), "size": 4])["warp"])
        let m = try #require(out.mesh)
        #expect(out.style == .custom)
        #expect(m.us == [0, 0.25, 0.5, 0.75, 1])
        #expect(m.vs == m.us)
        #expect(abs(m.eval(0, 0).x - bent.eval(0, 0).x) < 1e-3)
        #expect(abs(m.eval(1, 1).x - b.z) < 1e-3)
        let back = try decodeWarp(try s.execute("edit.transform.warpGrid", ["warp": .encoded(Warp.custom(m, bounds: b)), "size": "default"])["warp"])
        #expect(back.mesh?.us.count == 2)
    }

    @Test func idsMatchPhotocraft() throws {
        let s = Session()
        for id in ["edit.transform.warp", "layer.smartObjects.warp", "edit.transform.splitWarpCrosswise", "edit.transform.splitWarpHorizontally",
                   "edit.transform.splitWarpVertically", "edit.transform.removeWarpSplit", "edit.transform.warpGrid"] {
            let spec = try #require(s.registry.spec(id))
            let pc = try #require(PhotocraftCatalog.byId[id])
            #expect(spec.isAvailable)
            #expect(spec.module == pc.module && spec.label == pc.label && spec.menu == pc.menu && spec.shortcut == pc.shortcut && spec.params == pc.params, "\(id)")
        }
        #expect(PhotocraftCatalog.commands.filter { $0.module == "warp_cmds" }.count == 7)
    }
}
