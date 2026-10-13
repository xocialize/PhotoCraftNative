// Port of photocraft-algo (crates/algo/src/puppet.rs tests), MIT OR Apache-2.0, © ArtCraft Team and the PhotoCraft contributors.

import Foundation
import Testing
@testable import PCAlgo
import PCFoundation

@Suite struct GeometryPuppetTests {
    static func blob(_ st: SampleType) -> Surface {
        var s = Surface(format: PixelFormat(mode: .rgb, sample: st, alpha: true))
        // An L shape: a vertical bar and a foot.
        for y in Int32(10)..<70 { for x in Int32(20)..<36 { s.setPixel(x: x, y: y, [Float((x + y) % 7) / 6, 0.5, Float(y) / 80, 1]) } }
        for y in Int32(56)..<70 { for x in Int32(36)..<70 { s.setPixel(x: x, y: y, [0.2, Float((x * 3) % 5) / 4, 0.8, 1]) } }
        return s
    }

    static func p(_ x: Double, _ y: Double) -> SIMD2<Double> { SIMD2(x, y) }

    static func bbox(_ s: Surface) -> PixelRect { ResampleKit.contentBounds(s) }

    @Test func meshCoversTheShapeOnly() {
        let s = Self.blob(.u8)
        let b = Self.bbox(s)
        let m = Puppet.buildMesh(s, bounds: b, density: .normal, expansion: 2)
        #expect(m.tris.count > 20)
        func inside(_ q: SIMD2<Double>) -> Bool {
            m.tris.contains { t in
                let xs = [m.verts[Int(t.x)], m.verts[Int(t.y)], m.verts[Int(t.z)]]
                return q.x >= xs.map(\.x).min()! && q.x <= xs.map(\.x).max()! && q.y >= xs.map(\.y).min()! && q.y <= xs.map(\.y).max()!
            }
        }
        #expect(inside(Self.p(28, 30)) && inside(Self.p(60, 62)))
        #expect(!inside(Self.p(60, 20)), "the empty corner of the L has no mesh")
        let more = Puppet.buildMesh(s, bounds: b, density: .more, expansion: 2), fewer = Puppet.buildMesh(s, bounds: b, density: .fewer, expansion: 2)
        #expect(more.tris.count > m.tris.count && m.tris.count > fewer.tris.count)
    }

    static func inMesh(_ m: PuppetMesh, _ q: SIMD2<Double>) -> Bool {
        m.tris.contains { t in
            let a = m.verts[Int(t.x)], b = m.verts[Int(t.y)], c = m.verts[Int(t.z)]
            let d0 = PuppetKit.orient(a, b, q), d1 = PuppetKit.orient(b, c, q), d2 = PuppetKit.orient(c, a, q)
            return (d0 >= 0 && d1 >= 0 && d2 >= 0) || (d0 <= 0 && d1 <= 0 && d2 <= 0)
        }
    }

    /// photocraft #3105: the mesh follows the outline grown by the expansion.
    @Test func meshFollowsTheOutline() {
        var s = Surface(format: PixelFormat(mode: .rgb, sample: .u8, alpha: true))
        for y in Int32(40)..<160 {
            for x in Int32(40)..<160 where hypot(Double(x) + 0.5 - 100, Double(y) + 0.5 - 100) <= 60 { s.setPixel(x: x, y: y, [0.3, 0.6, 0.9, 1]) }
        }
        let m = Puppet.buildMesh(s, bounds: Self.bbox(s), density: .normal, expansion: 2)
        func r(_ v: SIMD2<Double>) -> Double { hypot(v.x - 100, v.y - 100) }
        #expect(m.verts.allSatisfy { r($0) <= 63 }, "a vertex outside the grown disc")
        #expect(m.verts.filter { r($0) > 61 }.count >= 40, "the outline carries vertices")
        let area = m.tris.reduce(0.0) { $0 + abs(PuppetKit.orient(m.verts[Int($1.x)], m.verts[Int($1.y)], m.verts[Int($1.z)])) / 2 }
        let disc = Double.pi * 62 * 62
        #expect(abs(area / disc - 1) < 0.03, "\(area) vs \(disc)")
        // Sharp corners and a concave corner: every opaque pixel is inside the mesh, even without
        // an expansion, and the empty corner of the L is not.
        let l = Self.blob(.u8)
        let lm = Puppet.buildMesh(l, bounds: Self.bbox(l), density: .fewer, expansion: 0)
        var missing = 0
        for x in 20..<36 { for y in 10..<70 where !Self.inMesh(lm, Self.p(Double(x) + 0.5, Double(y) + 0.5)) { missing += 1 } }
        for x in 36..<70 { for y in 56..<70 where !Self.inMesh(lm, Self.p(Double(x) + 0.5, Double(y) + 0.5)) { missing += 1 } }
        #expect(missing == 0, "\(missing) opaque pixels outside the mesh")
        #expect(!Self.inMesh(lm, Self.p(40, 50)) && !Self.inMesh(lm, Self.p(60, 20)))
    }

    @Test(arguments: [Backend.cpu, .gpu])
    func noPinsOrUnmovedPinsAreIdentity(_ backend: Backend) {
        if backend == .gpu && !AlgoGPU.isAvailable { return }
        for st in [SampleType.u8, .u16, .f32] {
            let s = Self.blob(st)
            let b = Self.bbox(s)
            for pins in [[], [PuppetPin(src: Self.p(28, 20), dst: Self.p(28, 20)), PuppetPin(src: Self.p(60, 62), dst: Self.p(60, 62))]] {
                let out = Puppet.warp(s, bounds: b, PuppetWarp(pins: pins), interp: .bicubic, on: backend)!
                let worst = GEO.maxDiff(s.readRegion(b), out.readRegion(b))
                #expect(worst <= 1.0 / 255.0 + 1e-6, "\(st): \(worst)")
            }
        }
    }

    /// photocraft #951: an expansion that empties the mesh warps nothing.
    @Test func anExpansionThatEmptiesTheMeshWarpsNothing() {
        let solver = PuppetSolver(mesh: PuppetMesh(), pinSrc: [Self.p(10, 10)], fixedRotation: [true])
        #expect(solver.mesh.verts.isEmpty)
        let s = Self.blob(.u8)
        let b = Self.bbox(s)
        let w = PuppetWarp(pins: [PuppetPin(src: Self.p(28, 30), dst: Self.p(38, 25))], expansion: -200)
        #expect(Puppet.buildMesh(s, bounds: b, density: w.density, expansion: w.expansion).tris.isEmpty)
        let out = Puppet.warp(s, bounds: b, w, interp: .bilinear)!
        #expect(out.readRegion(b) == s.readRegion(b))
    }

    /// photocraft #1019: a pin dragged absurdly far is refused before rendering.
    @Test func aPinDraggedAbsurdlyFarIsRefusedBeforeRendering() {
        let s = Self.blob(.u8)
        let b = Self.bbox(s)
        func pin(_ dst: SIMD2<Double>) -> PuppetWarp {
            PuppetWarp(pins: [PuppetPin(src: Self.p(28, 20), dst: Self.p(28, 20)), PuppetPin(src: Self.p(60, 62), dst: dst)])
        }
        #expect(Puppet.warp(s, bounds: b, pin(Self.p(1_048_576, 1_048_576)), interp: .bilinear) == nil)
        #expect(Puppet.warp(s, bounds: b, pin(Self.p(-1e7, 62)), interp: .bilinear) == nil)
        let near = Puppet.warp(s, bounds: b, pin(Self.p(70, 66)), interp: .bilinear)
        #expect(near != nil && !Self.bbox(near!).isEmpty)
    }

    @Test(arguments: [Backend.cpu, .gpu])
    func aSinglePinTranslatesRigidly(_ backend: Backend) {
        if backend == .gpu && !AlgoGPU.isAvailable { return }
        let s = Self.blob(.u8)
        let b = Self.bbox(s)
        var w = PuppetWarp(pins: [PuppetPin(src: Self.p(28, 30), dst: Self.p(38, 25))], mode: .rigid)
        let mesh = Puppet.buildMesh(s, bounds: b, density: w.density, expansion: w.expansion)
        let (solver, v, _) = Puppet.deform(mesh, w)
        for (d, x) in zip(v, solver.mesh.verts) { #expect(abs(d.x - x.x - 10) < 1e-3 && abs(d.y - x.y + 5) < 1e-3, "\(d) \(x)") }
        let out = Puppet.warp(s, bounds: b, w, interp: .bilinear, on: backend)!
        #expect(Self.bbox(out) == b.offsetBy(dx: 10, dy: -5))
        #expect(out.pixel(x: 30, y: 20) == s.pixel(x: 20, y: 25))
        // A fixed rotation turns the whole mesh about the pin.
        w.pins = [PuppetPin(src: Self.p(28, 30), dst: Self.p(28, 30), rotate: 90)]
        let (solver2, v2, _) = Puppet.deform(mesh, w)
        let i = solver2.mesh.verts.indices.max { solver2.mesh.verts[$0].x < solver2.mesh.verts[$1].x }!
        let x = solver2.mesh.verts[i], d = v2[i]
        // (dx, dy) → (−dy, dx) for +90° with y down.
        let dx = x.x - 28, dy = x.y - 30
        #expect(abs(d.x - (28 - dy)) < 1 && abs(d.y - (30 + dx)) < 1, "\(x) → \(d)")
    }

    @Test func arapEnergyDecreasesAndModesDiffer() {
        let s = Self.blob(.u8)
        let mesh = Puppet.buildMesh(s, bounds: Self.bbox(s), density: .normal, expansion: 2)
        let src = [Self.p(28, 14), Self.p(64, 62), Self.p(28, 62)]
        let dst = [Self.p(10, 30), Self.p(70, 50), Self.p(28, 62)]
        let solver = PuppetSolver(mesh: mesh, pinSrc: src, fixedRotation: [false, false, false])
        let rot: [Double?] = [nil, nil, nil]
        let (v, e) = solver.solve(pinDst: dst, rotations: rot, mode: .rigid, iterations: 30, initial: nil)
        #expect(e.count == 30)
        let start = solver.energy(solver.solve(pinDst: dst, rotations: rot, mode: .rigid, iterations: 0, initial: nil).0, pinDst: dst, rotations: rot)
        #expect(e[0] <= start * (1 + 1e-9), "\(e[0]) vs \(start)")
        for k in 1..<e.count { #expect(e[k] <= e[k - 1] * (1 + 1e-6) + 1e-9, "\(e[k - 1]) → \(e[k])") }
        #expect(e[29] < start)
        // Pins are honoured closely.
        for (p, d) in zip(solver.pinPoints(v), dst) { #expect(PuppetKit.dist2(p, d) < 0.25, "\(p) vs \(d)") }
        let (vd, _) = solver.solve(pinDst: dst, rotations: rot, mode: .distort, iterations: 30, initial: nil)
        #expect(v != vd)
    }

    @Test func depthOrdersTriangles() {
        let s = Self.blob(.u8)
        let mesh = Puppet.buildMesh(s, bounds: Self.bbox(s), density: .fewer, expansion: 2)
        let pins = [Self.p(28, 14), Self.p(64, 62)]
        let solver = PuppetSolver(mesh: mesh, pinSrc: pins, fixedRotation: [false, false])
        let order = solver.drawOrder(depths: [1, 0], pinSrc: pins)
        func near0(_ t: Int) -> Bool {
            let tv = solver.mesh.tris[t]
            var c = SIMD2<Double>(0, 0)
            for i in [Int(tv.x), Int(tv.y), Int(tv.z)] { c = SIMD2(c.x + solver.mesh.verts[i].x / 3, c.y + solver.mesh.verts[i].y / 3) }
            return PuppetKit.dist2(c, pins[0]) < PuppetKit.dist2(c, pins[1])
        }
        // Triangles nearest the raised pin come last, all others first.
        let k = order.firstIndex { near0($0) }!
        #expect(order[..<k].allSatisfy { !near0($0) } && order[k...].allSatisfy { near0($0) })
    }

    @Test func codableMatchesPhotocraft() throws {
        let w = try JSONDecoder().decode(PuppetWarp.self, from: Data(#"{"pins":[{"src":[1,2],"dst":[3,4]},{"src":[5,6],"dst":[7,8],"rotate":30,"depth":2}],"mode":"distort"}"#.utf8))
        #expect(w.expansion == 2 && w.density == .normal && w.mode == .distort && w.pins[1].rotate == 30 && w.pins[1].depth == 2 && w.pins[0].rotate == nil)
        let json = String(decoding: try JSONEncoder().encode(w.pins[0]), as: UTF8.self)
        #expect(!json.contains("rotate") && !json.contains("depth"), "\(json)")
        #expect(!w.isIdentity && PuppetWarp(pins: [PuppetPin(src: Self.p(1, 1), dst: Self.p(1, 1), rotate: 720)]).isIdentity)
    }

    /// The warp's sampling on the GPU vs the CPU over the channel variants.
    @Test func puppetParity() throws {
        let rect = PixelRect(x: 3, y: -2, width: 61, height: 47)
        let w = PuppetWarp(pins: [PuppetPin(src: Self.p(15, 5), dst: Self.p(12, 9)), PuppetPin(src: Self.p(50, 35), dst: Self.p(58, 30), depth: 1),
                                  PuppetPin(src: Self.p(30, 20), dst: Self.p(33, 21), rotate: 25)])
        var worst: Float = 0
        for interp in Interp.allCases {
            let e = try GEO.variants(rect) { img, ctx, b in try Puppet.warp(img, w, interp: interp, context: ctx, on: b)! }
            guard let e else { return }
            #expect(e <= 1.0 / 255.0, "\(interp): \(e)")
            worst = max(worst, e)
        }
        ParityLog.record("PuppetWarp", worst)
    }
}
