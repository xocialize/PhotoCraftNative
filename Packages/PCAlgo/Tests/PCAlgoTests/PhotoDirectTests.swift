// Port of photocraft-algo (crates/algo/src/direct.rs tests), MIT OR Apache-2.0, © ArtCraft Team and the PhotoCraft contributors.

import Foundation
import Testing
@testable import PCAlgo

@Suite struct PhotoDirectTests {
    typealias Pose = DirectAlign.Pose

    /// A smooth random texture: a sum of a few sinusoids.
    static func texture(_ w: Int, _ h: Int, _ seed: UInt32) -> [Float] {
        let s = Float(seed)
        return (0..<(w * h)).map { i in
            let x = Float(i % w), y = Float(i / w)
            let v = sinf(x * 0.21 + s) * cosf(y * 0.17 - s) + sinf(x * 0.071 + y * 0.093 + s * 0.5) * 0.7 + cosf((x * 0.33 - y * 0.29) * 1.3 + s) * 0.4
            return 0.5 + 0.2 * v
        }
    }

    static func plane(_ w: Int, _ h: Int, _ luma: [Float]) -> DirectAlign.Plane { DirectAlign.Plane(w: w, h: h, luma: luma) }

    @Test func poseMatrixIsTheIdentityAtTheIdentityAndShiftsInPixels() {
        #expect(Pose.identity.matrix(width: 640, height: 480) == Homography.identity)
        let p = Pose(dx: 0.1, dy: -0.05)
        let (x, y) = p.matrix(width: 200, height: 100).apply(50, 20)
        #expect(abs(x - 70) < 1e-9 && abs(y - 15) < 1e-9)
        let q = Pose(scale: 1.5, rot: 0.3)
        let (x2, y2) = q.matrix(width: 200, height: 100).apply(100, 50)
        #expect(abs(x2 - 100) < 1e-9 && abs(y2 - 50) < 1e-9)
        #expect(Pose(vector: q.vector) == q)
        #expect(Pose.free(.translation).filter { $0 }.count == 2)
        #expect(Pose.free(.homography) == [Bool](repeating: true, count: Pose.count))
    }

    @Test func warpByTheIdentityIsExactAndMarksCoverage() {
        let (w, h) = (40, 30)
        let src = Self.texture(w, h, 1)
        let (o, v) = DirectAlign.warp(Self.plane(w, h, src), pose: .identity)
        #expect(zip(o, src).allSatisfy { abs($0 - $1) < 1e-6 })
        #expect(v.allSatisfy { $0 })
        let (_, v2) = DirectAlign.warp(Self.plane(w, h, src), pose: Pose(dx: 10.0 / Double(w)))
        #expect((0..<h).allSatisfy { y in !v2[y * w] && !v2[y * w + 9] && v2[y * w + 10] })
        let valid = (0..<(w * h)).map { $0 % w < 20 }
        let (_, v3) = DirectAlign.warp(DirectAlign.Plane(w: w, h: h, luma: src, valid: valid), pose: .identity)
        #expect(v3[5 * w + 10] && !v3[5 * w + 30])
    }

    @Test func costIsZeroAtTheTruthAndTheSentinelWithoutOverlap() {
        let (w, h) = (96, 72)
        let src = Self.texture(w, h, 2)
        let l = DirectAlign.levels(Self.plane(w, h, src))
        #expect(DirectAlign.cost(l[0], l[0], .identity).0 < 1e-9)
        #expect(DirectAlign.cost(l[0], l[0], Pose(dx: 2)).0 == 1e9)
        let bright = src.map { $0 + 0.2 }
        let lb = DirectAlign.levels(Self.plane(w, h, bright))
        #expect(DirectAlign.cost(l[0], lb[0], .identity).0 < 1e-6)
        #expect(DirectAlign.cost(l[0], lb[0], Pose(dx: 0.02)).0 > 1e-3)
    }

    @Test func correlationIsExposureIndependentAndLowForUnrelatedPictures() {
        let (w, h) = (96, 72)
        let src = Self.texture(w, h, 2)
        let l = DirectAlign.levels(Self.plane(w, h, src))
        let doubled = src.map { $0 * 2 }
        let ld = DirectAlign.levels(Self.plane(w, h, doubled))
        let (rms, _, corr) = DirectAlign.cost(l[0], ld[0], .identity)
        #expect(rms > 0.05 && corr > 0.9999, "rms \(rms) correlation \(corr)")
        let other = DirectAlign.levels(Self.plane(w, h, Self.texture(w, h, 7)))
        let (_, _, corr2) = DirectAlign.cost(l[0], other[0], .identity)
        #expect(abs(corr2) < 0.3, "unrelated textures correlate at \(corr2)")
        let flat = DirectAlign.levels(Self.plane(w, h, [Float](repeating: 0.5, count: w * h)))
        #expect(DirectAlign.cost(l[0], flat[0], .identity).2 == 0)
        let r = DirectAlign.register(reference: Self.plane(w, h, src), target: Self.plane(w, h, doubled), motion: .similarity)
        #expect(r.correlation > 0.999, "\(r)")
    }

    @Test func pyramidStopsAbove64Rows() {
        let l = DirectAlign.levels(Self.plane(40, 300, [Float](repeating: 0.25, count: 40 * 300)))
        #expect(l.map { [$0.w, $0.h] } == [[40, 300], [20, 150], [10, 75], [5, 38]])
        #expect(l.allSatisfy { $0.luma.allSatisfy { abs($0 - 0.25) < 1e-6 } })
        let valid = (0..<(40 * 300)).map { $0 % 40 < 20 }
        let l2 = DirectAlign.levels(DirectAlign.Plane(w: 40, h: 300, luma: [Float](repeating: 0.25, count: 40 * 300), valid: valid))
        let v = l2[2].valid!
        #expect(v[10 * 10 + 2] && !v[10 * 10 + 8])
    }

    @Test func nelderMeadFindsTheMinimumOfABowl() {
        let f = { (x: [Double]) -> Double in pow(x[0] - 0.3, 2) + 2 * pow(x[1] + 0.2, 2) }
        let r = DirectAlign.nelderMead(f, [0, 0], [-1, -1], [1, 1], [0.1, 0.1], [1e-6, 1e-6])
        #expect(abs(r[0] - 0.3) < 1e-4 && abs(r[1] + 0.2) < 1e-4, "\(r)")
        let r2 = DirectAlign.nelderMead(f, [0, 0], [-1, -1], [0.1, 1], [0.1, 0.1], [1e-6, 1e-6])
        #expect(abs(r2[0] - 0.1) < 1e-6, "\(r2)")
        #expect(DirectAlign.nelderMead(f, [], [], [], [], []).isEmpty)
        let (step, tol) = DirectAlign.levelSteps([0, 2], 3, 8000, 6000)
        #expect(abs(step[0] * 8000 - 8) < 1e-9 && abs(tol[1] * 4000 - 0.8) < 1e-9)
    }

    @Test func registersASimilarityToATenthOfAPixel() {
        let (w, h) = (320, 240)
        let reference = Self.texture(w, h, 3)
        let truth = Pose(dx: 3.3 / Double(w), dy: -2.1 / Double(h), scale: 1.012, rot: PhotoKit.radians(0.6))
        let m = truth.matrix(width: w, height: h)
        let target: [Float] = (0..<(w * h)).map { i in
            let (x, y) = m.apply(Double(i % w), Double(i / w))
            return DirectAlign.sample(reference, w, h, min(max(x, 0), Double(w - 1)), min(max(y, 0), Double(h - 1)))
        }
        for (motion, coarsen) in [(Panorama.Motion.similarity, 0), (.similarity, 1), (.homography, 0)] {
            let r = DirectAlign.register(reference: Self.plane(w, h, reference), target: Self.plane(w, h, target), motion: motion, coarsen: coarsen)
            let t0 = truth.matrix(width: w, height: h).apply(0, 0), r0 = r.h.apply(0, 0)
            let t1 = truth.matrix(width: w, height: h).apply(Double(w), Double(h)), r1 = r.h.apply(Double(w), Double(h))
            let corner = max(hypot(t0.0 - r0.0, t0.1 - r0.1), hypot(t1.0 - r1.0, t1.1 - r1.1))
            #expect(corner < 0.1 * Double(1 << coarsen) + 0.05, "\(motion) coarsen \(coarsen): corners off by \(corner) px, \(r.pose)")
            let searched = (w >> coarsen) * (h >> coarsen)
            #expect(r.rms < 0.01 && r.overlap > searched / 2, "\(motion): rms \(r.rms) overlap \(r.overlap) of \(searched)")
        }
        let t = Pose(dx: 4.0 / Double(w), dy: 3.0 / Double(h))
        let target2: [Float] = (0..<(w * h)).map { i in
            DirectAlign.sample(reference, w, h, min(max(Double(i % w) + 4, 0), Double(w - 1)), min(max(Double(i / w) + 3, 0), Double(h - 1)))
        }
        let r = DirectAlign.register(reference: Self.plane(w, h, reference), target: Self.plane(w, h, target2), motion: .translation)
        #expect(abs((r.pose.dx - t.dx) * Double(w)) < 0.1 && abs((r.pose.dy - t.dy) * Double(h)) < 0.1, "\(r.pose)")
        #expect(r.pose.scale == 1 && r.pose.rot == 0)
    }

    @Test func coverageKeepsUncoveredPixelsOutOfTheFit() {
        let (w, h) = (320, 240)
        let reference = Self.texture(w, h, 4)
        var target: [Float] = (0..<(w * h)).map { i in
            DirectAlign.sample(reference, w, h, min(max(Double(i % w) + 2.5, 0), Double(w - 1)), Double(i / w))
        }
        let valid = (0..<(w * h)).map { $0 % w < w / 2 }
        for i in 0..<(w * h) where !valid[i] { target[i] = Float((i * 7919) % 1000) / 1000 }
        let r = DirectAlign.register(reference: Self.plane(w, h, reference), target: DirectAlign.Plane(w: w, h: h, luma: target, valid: valid), motion: .translation)
        #expect(abs(r.pose.dx * Double(w) - 2.5) < 0.1, "\(r.pose)")
        #expect(r.overlap < w * h / 2 + w && r.overlap > w * h / 3)
    }
}
