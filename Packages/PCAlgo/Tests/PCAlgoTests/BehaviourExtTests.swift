// Port of photocraft-algo (crates/algo/src/tests_ext.rs), MIT OR Apache-2.0, © ArtCraft Team and the PhotoCraft contributors.
//
// photocraft's second-batch behaviour tests for the lead's filters, on both backends.

import Foundation
import Testing
@testable import PCAlgo
import PCFoundation

@Suite struct BehaviourExtTests {
    typealias B = Behaviour
    static let white: [Float] = [1, 1, 1, 1], black: [Float] = [0, 0, 0, 1]

    func variance(_ s: Surface, _ r: PixelRect, _ c: Int) -> Float {
        let v = s.readRegion(r)
        let x = stride(from: c, to: v.count, by: 4).map { v[$0] }
        let m = x.reduce(0, +) / Float(x.count)
        return x.map { ($0 - m) * ($0 - m) }.reduce(0, +) / Float(x.count)
    }

    func noisy(_ st: SampleType) throws -> Surface {
        try B.run(B.flat(st, B.R, [0.5, 0.5, 0.5, 1]), AddNoise(amount: 20, distribution: .gaussian, seed: 4))
    }

    @Test func identitiesAtZeroStrength() throws {
        let s = B.pattern(.u8, B.R)
        let cases: [any Filter] = [
            CustomKernel(kernel: (0..<25).map { $0 == 12 ? 1 : 0 }, scale: 1, offset: 0),
            ReduceNoise(strength: 0, preserveDetails: 60, reduceColorNoise: 0, sharpenDetails: 0),
            LensBlur(radius: 0, blades: 6), ShapeBlur(radius: 0, shape: .heart),
            TiltShift(blur: 0, angle: 30, focus: 0.1, transition: 0.2), IrisBlur(pins: [IrisPin(blur: 0)]),
            FieldBlur(pins: [FieldPin(blur: 0)]), SpinBlur(pins: [SpinPin(blurAngle: 0)]), PathBlur(paths: [BlurPath(speed: 0)]),
        ]
        for f in cases {
            for b in B.backends {
                func go<F: Filter>(_ f: F) throws {
                    let out = try B.run(s, f, on: b)
                    let d = zip(out.readRegion(B.R), s.readRegion(B.R)).map { abs($0 - $1) }.max()!
                    #expect(d <= 0.5 / 255, "\(f.label) on \(b) is not identity (\(d))")
                }
                try go(f)
            }
        }
    }

    @Test func flatImagesStayFlat() throws {
        let c: [Float] = [0.3, 0.55, 0.8, 1]
        let s = B.flat(.f32, B.R, c)
        let filters: [any Filter] = [ReduceNoise(strength: 10, preserveDetails: 0, reduceColorNoise: 100, sharpenDetails: 0),
                                     SmartBlur(radius: 3, threshold: 25, quality: .high), LensBlur(radius: 5, blades: 5, curvature: 50),
                                     ShapeBlur(radius: 4, shape: .ring), TiltShift(blur: 5, focus: 0, transition: 0.1)]
        for f in filters {
            for b in B.backends {
                func go<F: Filter>(_ f: F) throws {
                    let px = try B.run(s, f, on: b).pixel(x: 20, y: 15)
                    for k in 0..<4 { #expect(abs(px[k] - c[k]) < 2e-3, "\(f.label) \(b): \(px)") }
                }
                try go(f)
            }
        }
    }

    @Test func reduceNoiseLowersNoise() throws {
        let s = try noisy(.f32)
        let inner = PixelRect(x0: 8, y0: 8, x1: 32, y1: 22)
        for b in B.backends {
            let out = try B.run(s, ReduceNoise(strength: 10, preserveDetails: 0, reduceColorNoise: 100, sharpenDetails: 0), on: b)
            for c in 0..<3 { #expect(variance(out, inner, c) < variance(s, inner, c) * 0.5) }
        }
    }

    @Test func smartBlurKeepsEdgesAndSmoothsNoise() throws {
        var s = try noisy(.f32)
        s.fill(PixelRect(x0: 20, y0: 0, x1: 40, y1: 30), with: [1, 1, 1, 1])
        for b in B.backends {
            let out = try B.run(s, SmartBlur(radius: 3, threshold: 60, quality: .high), on: b)
            #expect(abs(out.pixel(x: 20, y: 15)[0] - 1) < 1e-5 && out.pixel(x: 19, y: 15)[0] < 0.8)
            #expect(variance(out, PixelRect(x0: 4, y0: 4, x1: 16, y1: 26), 0) < variance(s, PixelRect(x0: 4, y0: 4, x1: 16, y1: 26), 0))
            let edges = try B.run(s, SmartBlur(radius: 3, threshold: 60, quality: .high, mode: .edgeOnly), on: b)
            #expect(edges.pixel(x: 20, y: 15)[0] == 1 && edges.pixel(x: 30, y: 15)[0] == 0)
        }
    }

    @Test func shapedBlursSpreadAPointIntoTheShape() throws {
        var s = Surface(format: B.fmt(.f32))
        s.fill(B.R, with: Self.black)
        s.setPixel(x: 20, y: 15, Self.white)
        for b in B.backends {
            let ring = try B.run(s, ShapeBlur(radius: 6, shape: .ring), on: b)
            #expect(ring.pixel(x: 20, y: 15)[0] == 0 && ring.pixel(x: 25, y: 15)[0] > 0)
            let lb = try B.run(s, LensBlur(radius: 6, blades: 3, brightness: 100, threshold: 200), on: b)
            let v = lb.readRegion(B.R)
            let sum = stride(from: 0, to: v.count, by: 4).reduce(Float(0)) { $0 + v[$1] }
            #expect(sum > 1.5)
            #expect(lb.pixel(x: 20, y: 20)[0] != lb.pixel(x: 20, y: 10)[0], "triangular, not circular")
        }
    }

    @Test func lensBlurDepthMapKeepsFocalPlaneSharp() throws {
        let s = B.pattern(.f32, B.R)
        var d = FloatImage(rect: B.R, channels: 1)
        for y in 0..<30 { for x in 20..<40 { d.data[y * 40 + x] = 1 } }
        for b in B.backends {
            let out = try B.run(s, LensBlur(radius: 5, blades: 6, curvature: 100, depth: .layerMask, depthMap: d), on: b)
            #expect(out.pixel(x: 5, y: 10) == s.pixel(x: 5, y: 10))
            #expect(out.pixel(x: 30, y: 10) != s.pixel(x: 30, y: 10))
        }
    }

    @Test func galleryBlursFollowTheirGeometry() throws {
        let s = B.pattern(.f32, B.R)
        for b in B.backends {
            let ts = try B.run(s, TiltShift(blur: 6, focus: 0.1, transition: 0.2), on: b)
            #expect(ts.pixel(x: 10, y: 15) == s.pixel(x: 10, y: 15) && ts.pixel(x: 10, y: 1) != s.pixel(x: 10, y: 1))
            let ir = try B.run(s, IrisBlur(pins: [IrisPin(radiusX: 0.3, radiusY: 0.3, blur: 6)]), on: b)
            #expect(ir.pixel(x: 20, y: 15) == s.pixel(x: 20, y: 15) && ir.pixel(x: 1, y: 1) != s.pixel(x: 1, y: 1))
            let sp = try B.run(s, SpinBlur(pins: [SpinPin(radiusX: 0.3, radiusY: 0.3, blurAngle: 40)]), on: b)
            #expect(sp.pixel(x: 1, y: 1) == s.pixel(x: 1, y: 1) && sp.pixel(x: 24, y: 15) != s.pixel(x: 24, y: 15))
            var stripes = Surface(format: B.fmt(.f32))
            for y in Int32(0)..<30 { for x in Int32(0)..<40 { let v: Float = y % 2 == 0 ? 1 : 0; stripes.setPixel(x: x, y: y, [v, v, v, 1]) } }
            let pb = try B.run(stripes, PathBlur(paths: [BlurPath(points: [SIMD2(0, 0.5), SIMD2(1, 0.5)], speed: 6)]), on: b)
            #expect(abs(pb.pixel(x: 20, y: 10)[0] - 1) < 1e-5 && pb.pixel(x: 20, y: 11)[0] < 1e-5)
        }
    }

    @Test func customKernelShiftsAndOffsets() throws {
        let s = B.pattern(.f32, B.R)
        var k = [Float](repeating: 0, count: 25)
        k[13] = 2
        var id = [Float](repeating: 0, count: 25)
        id[12] = 1
        for b in B.backends {
            #expect(try B.run(s, CustomKernel(kernel: k, scale: 2, offset: 0), on: b).pixel(x: 10, y: 10)[0] == s.pixel(x: 11, y: 10)[0])
            #expect(abs(try B.run(B.flat(.f32, B.R, [0.2, 0.2, 0.2, 1]), CustomKernel(kernel: id, scale: 1, offset: 51), on: b).pixel(x: 5, y: 5)[0] - 0.4) < 1e-5)
        }
    }
}
