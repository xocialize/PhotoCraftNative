// Port of photocraft-algo (crates/algo/src/wideangle.rs tests), MIT OR Apache-2.0, © ArtCraft Team and the PhotoCraft contributors.

import Foundation
import Testing
@testable import PCAlgo
import PCFoundation

@Suite struct GeometryWideAngleTests {
    @Test func cameraModelsRoundTrip() {
        let frame = PixelRect(x0: 0, y0: 0, x1: 600, y1: 400)
        for model in [WideModel.fisheye, .perspective] {
            let cam = WideAngle.Camera(WideAngle(model: model, focalLength: 15), frame: frame)
            for (x, y) in [(10.0, 20.0), (300, 200), (590, 350)] {
                let p = cam.pixel(cam.ray(x, y))!
                #expect(abs(p.x - x) < 1e-6 && abs(p.y - y) < 1e-6, "\(model)")
            }
        }
        let eq = WideAngle.Camera(WideAngle(), frame: PixelRect(x0: 0, y0: 0, x1: 800, y1: 400))
        #expect(eq.model == .fullSpherical)
        let p = eq.pixel(eq.ray(123, 77))!
        #expect(abs(p.x - 123) < 1e-6 && abs(p.y - 77) < 1e-6)
        // Perspective arcs are straight; fisheye arcs bend.
        let cam = WideAngle.Camera(WideAngle(model: .perspective), frame: frame)
        let mid = cam.arc(SIMD2(50, 50), SIMD2(550, 80), 10)[5]
        #expect(abs(mid.y - 65) < 2, "\(mid)")
        let fish = WideAngle.Camera(WideAngle(model: .fisheye, focalLength: 8), frame: frame)
        #expect(fish.arc(SIMD2(50, 60), SIMD2(550, 60), 10)[5].y < 50, "a line near the top bows away from the centre")
    }

    @Test func constraintsBecomeStraightAndLevel() {
        let frame = PixelRect(x0: 0, y0: 0, x1: 480, y1: 320)
        let p = WideAngle(model: .fisheye, focalLength: 8, constraints: [
            .init(a: SIMD2(60, 70), b: SIMD2(420, 70), orientation: .horizontal),
            .init(a: SIMD2(80, 60), b: SIMD2(80, 260), orientation: .free),
        ])
        let cam = WideAngle.Camera(p, frame: frame)
        let before = cam.arc(SIMD2(60, 70), SIMD2(420, 70), 24).map { abs($0.y - 70) }.max()!
        #expect(before > 10, "the fisheye curve bows: \(before)")
        let mesh = p.solve(frame: frame)
        #expect(mesh.residual < 2, "residual \(mesh.residual)")
        // The horizontal constraint is level.
        let ys = mesh.curves[0].map { mesh.map(frame: frame, $0).y }
        #expect(ys.max()! - ys.min()! < 2, "\(ys.max()! - ys.min()!)")
        // Far from the constraints the image barely moves.
        let c = mesh.map(frame: frame, SIMD2(300, 250))
        #expect(abs(c.x - 300) < 80 && abs(c.y - 250) < 40, "\(c)")
    }

    @Test(arguments: [Backend.cpu, .gpu])
    func noConstraintsIsIdentityAndRenders(_ backend: Backend) {
        if backend == .gpu && !AlgoGPU.isAvailable { return }
        let frame = PixelRect(x0: 0, y0: 0, x1: 64, y1: 48)
        var s = Surface(format: .rgba8)
        s.fill(frame, with: [0.2, 0.4, 0.6, 1])
        let mesh = WideAngle().solve(frame: frame)
        #expect(mesh.verts.allSatisfy { abs($0.dst.x - $0.src.x) < 1e-9 && abs($0.dst.y - $0.src.y) < 1e-9 })
        let out = WideAngle(scale: 80).apply(s, frame: frame, interp: .bilinear, on: backend)
        #expect(out.pixel(x: 32, y: 24)[3] > 0.99 && out.pixel(x: 1, y: 1)[3] < 0.01)
    }

    @Test(arguments: [Backend.cpu, .gpu])
    func noGapsAcrossTiles(_ backend: Backend) {
        if backend == .gpu && !AlgoGPU.isAvailable { return }
        let frame = PixelRect(x0: 0, y0: 0, x1: 772, y1: 517)
        var s = Surface(format: .rgba8)
        s.fill(frame, with: [0.2, 0.4, 0.6, 1])
        for p in [WideAngle(), WideAngle(model: .fisheye, focalLength: 12, constraints: [.init(a: SIMD2(20, 30), b: SIMD2(700, 35), orientation: .horizontal)])] {
            let out = p.apply(s, frame: frame, interp: .bilinear, on: backend)
            let r = PixelRect(x0: 80, y0: 80, x1: 690, y1: 440)
            let px = out.readRegion(r)
            let holes = stride(from: 3, to: px.count, by: 4).filter { px[$0] < 0.5 }.count
            #expect(holes == 0, "\(holes) holes")
        }
    }

    @Test func codableMatchesPhotocraft() throws {
        let json = #"{"model":"fisheye","focalLength":10,"constraints":[{"a":[1,2],"b":[3,4]},{"a":[5,6],"b":[7,8],"orientation":"vertical"}]}"#
        let w = try JSONDecoder().decode(WideAngle.self, from: Data(json.utf8))
        #expect(w.model == .fisheye && w.cropFactor == 1 && w.scale == 100 && w.constraints[0].orientation == .free && w.constraints[1].orientation == .vertical)
        #expect(WideModel(parsing: "spherical") == .fullSpherical && WideModel(parsing: "x") == nil)
    }

    /// The warp's sampling on the GPU vs the CPU over the channel variants.
    @Test func wideAngleParity() throws {
        let rect = PixelRect(x: 3, y: -2, width: 91, height: 63)
        var worst: Float = 0
        let p = WideAngle(model: .fisheye, focalLength: 9, scale: 92, constraints: [
            .init(a: SIMD2(10, 4), b: SIMD2(85, 6), orientation: .horizontal),
            .init(a: SIMD2(12, 2), b: SIMD2(14, 55), orientation: .free),
        ])
        let mesh = p.solve(frame: rect)
        for interp in Interp.allCases {
            let e = try GEO.variants(rect) { img, ctx, b in
                try MeshWarp.warpTriangles(img, srcRect: rect, verts: mesh.verts, tris: mesh.triangles(), interp: interp, context: ctx, on: b)
            }
            guard let e else { return }
            #expect(e <= 1.0 / 255.0, "\(interp): \(e)")
            worst = max(worst, e)
        }
        ParityLog.record("AdaptiveWideAngle", worst)
    }
}
