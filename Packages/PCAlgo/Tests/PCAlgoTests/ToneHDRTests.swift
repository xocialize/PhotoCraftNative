// Port of photocraft-algo (crates/algo/src/hdr.rs tests), MIT OR Apache-2.0, © ArtCraft Team and the PhotoCraft contributors.

import Foundation
import Testing
@testable import PCAlgo
import PCFoundation

@Suite struct ToneHDRTests {
    /// A radiance map with a wide range (12 stops left to right).
    static func scene(_ w: Int, _ h: Int) -> [SIMD3<Float>] {
        (0..<(w * h)).map { i in
            let (x, y) = (Float(i % w) / Float(w), Float(i / w) / Float(h))
            let base = 0.002 * powf(2, x * 12)
            let tex = 1 + 0.3 * sinf(y * 40)
            return SIMD3(base * tex, base * tex * 0.8, base * tex * 0.6)
        }
    }

    /// A smooth non-sRGB response.
    static func camera(_ e: Float) -> Float { Float.minimum(powf(Float.maximum(e, 0), 0.45), 1) }

    static func shoot(_ sc: [SIMD3<Float>], _ dt: Float) -> [SIMD4<Float>] {
        sc.map { r in
            let p = SIMD4(camera(r.x * dt), camera(r.y * dt), camera(r.z * dt), 1)
            return SIMD4((p.x * 255).rounded() / 255, (p.y * 255).rounded() / 255, (p.z * 255).rounded() / 255, 1)
        }
    }

    static var backends: [Backend] { AlgoGPU.isAvailable ? [.cpu, .gpu] : [.cpu] }

    // MARK: Parity

    @Test func toneMapParity() throws {
        var worst: Float = 0
        let methods: [HDRToneMethod] = [
            .localAdaptation(HdrToning(radius: 7, strength: 0.52)),
            .exposureGamma(exposure: 0.7, gamma: 1.8),
            .exposureGamma(exposure: -1, gamma: 0.05),
            .highlightCompression,
            .equalizeHistogram,
        ]
        for m in methods { worst = max(worst, try Parity.checkVariants(HDRToneMap(method: m))) }
        // Linear radiance well above 1.
        let r = PixelRect(x: 0, y: 0, width: 64, height: 40)
        for ch in [3, 4] {
            let hdr = TestImage.make(r, channels: ch, alpha: ch == 4, seed: 8, eightBit: false, hdr: true)
            for m in methods {
                if let e = try Parity.check(HDRToneMap(method: m), src: hdr, ctx: FilterContext(bounds: r, mode: .rgb, alpha: ch == 4)) {
                    worst = max(worst, e)
                }
            }
        }
        ParityLog.record("HDRToneMap", worst)
    }

    /// GPU merge vs CPU: radiance within 1e-4 relative (f32 vs photocraft's f64 accumulation),
    /// same response, base and ghost fraction.
    @Test func mergeParity() throws {
        guard AlgoGPU.isAvailable else { return }
        let (w, h) = (96, 64)
        let sc = Self.scene(w, h)
        var shots = [Float(0.5), 1, 2, 4].map { Self.shoot(sc, $0) }
        for y in 20..<40 { for x in 20..<40 { shots[2][y * w + x] = SIMD4(0.2, 0.2, 0.2, 1) } }
        var worst: Double = 0
        for ghosts in [false, true] {
            let opts = HDRMergeOptions(exposures: [0.5, 1, 2, 4], removeGhosts: ghosts)
            let c = try ToneKit.mergeHDR(w: w, h: h, images: shots, options: opts, on: .cpu)
            let g = try ToneKit.mergeHDR(w: w, h: h, images: shots, options: opts, on: .gpu)
            #expect(c.ghostBase == g.ghostBase && c.response == g.response)
            #expect(abs(c.ghostFraction - g.ghostFraction) < 1e-9, "\(c.ghostFraction) vs \(g.ghostFraction)")
            #expect(abs(c.stops - g.stops) < 1e-3)
            for i in 0..<c.px.count {
                for k in 0..<4 {
                    let a = Double(c.px[i][k]), b = Double(g.px[i][k])
                    worst = max(worst, abs(a - b) / max(1, abs(a)))
                }
            }
        }
        #expect(worst < 1e-4, "relative \(worst)")
        ParityLog.record("HDRMerge (relative)", Float(worst))
    }

    // MARK: photocraft hdr.rs tests

    /// photocraft `exposure_estimation_and_merge_recover_radiance`.
    @Test func exposureEstimationAndMergeRecoverRadiance() throws {
        let (w, h) = (192, 64)
        let sc = Self.scene(w, h)
        let dts: [Float] = [0.25, 1, 4, 16]
        let shots = dts.map { Self.shoot(sc, $0) }
        let est = ToneKit.estimateExposures(shots)
        for k in 1..<4 {
            let r = est[k] / est[k - 1]
            #expect((2.0..<8.0).contains(r), "ratio \(r) (\(est))")
        }
        for backend in Self.backends {
            let m = try ToneKit.mergeHDR(w: w, h: h, images: shots, options: HDRMergeOptions(exposures: dts.map(Double.init)), on: backend)
            let probe = { (x: Int) in Double(m.px[(h / 2) * w + x].y) / Double(sc[(h / 2) * w + x].y) }
            let k0 = probe(w / 2)
            for x in [10, 50, 100, 150, 170] {
                let r = probe(x) / k0
                #expect(abs(log(r)) < 0.25, "\(backend) x \(x): ratio \(r)")
            }
            #expect(m.stops > 9, "stops \(m.stops)")
            #expect(zip(m.response[0], m.response[0].dropFirst()).allSatisfy { $1 > $0 })
        }
    }

    /// photocraft `ghosts_come_from_the_base_exposure`.
    @Test func ghostsComeFromTheBaseExposure() throws {
        let (w, h) = (64, 64)
        let sc = [SIMD3<Float>](repeating: SIMD3(0.2, 0.2, 0.2), count: w * h)
        var shots = [Float(0.5), 1, 2].map { Self.shoot(sc, $0) }
        for y in 20..<40 { for x in 20..<40 { shots[2][y * w + x] = SIMD4(0.2, 0.2, 0.2, 1) } }
        for backend in Self.backends {
            let opts = { (g: Bool) in HDRMergeOptions(exposures: [0.5, 1, 2], removeGhosts: g, ghostBase: 1) }
            let plain = try ToneKit.mergeHDR(w: w, h: h, images: shots, options: opts(false), on: backend)
            let clean = try ToneKit.mergeHDR(w: w, h: h, images: shots, options: opts(true), on: backend)
            let at = { (m: HDRMerged, x: Int, y: Int) in m.px[y * w + x].y }
            let bg = at(clean, 5, 5)
            #expect(abs(at(clean, 30, 30) / bg - 1) < 0.15, "\(backend) ghost kept: \(at(clean, 30, 30)) vs \(bg)")
            #expect(abs(at(plain, 30, 30) / at(plain, 5, 5) - 1) > 0.2)
            #expect(clean.ghostFraction > 0.05 && clean.ghostBase == 1)
        }
    }

    /// photocraft `mtb_finds_shifts`.
    @Test func mtbFindsShifts() {
        let (w, h) = (128, 96)
        let img: [Float] = (0..<(w * h)).map { i in
            let (x, y) = (Float(i % w), Float(i / w))
            return 0.5 + 0.4 * (sinf(x * 0.21) * cosf(y * 0.17))
        }
        let (dx, dy): (Int32, Int32) = (5, -3)
        let shifted: [Float] = (0..<(w * h)).map { i in
            let x = Int32(i % w) - dx, y = Int32(i / w) - dy
            return img[Int(min(max(y, 0), Int32(h) - 1)) * w + Int(min(max(x, 0), Int32(w) - 1))] * 0.6
        }
        let (ox, oy) = ToneKit.mtbOffset(w: w, h: h, reference: shifted, image: img, levels: 4)
        #expect((ox, oy) == (dx, dy))
    }

    /// photocraft `tone_mapping_methods_produce_display_range`.
    @Test func toneMappingMethodsProduceDisplayRange() throws {
        let (w, h) = (96, 32)
        let sc = Self.scene(w, h)
        for backend in Self.backends {
            for method in [HDRToneMethod.localAdaptation(HdrToning(radius: 7, strength: 0.52)), .exposureGamma(exposure: 0, gamma: 1),
                           .highlightCompression, .equalizeHistogram] {
                var px = sc.map { SIMD4($0, 1) }
                try ToneKit.toneMap(&px, w: w, h: h, method: method, on: backend)
                #expect(px.allSatisfy { q in (0...1).contains(q.x) && (0...1).contains(q.y) && (0...1).contains(q.z) })
                let row = { (x: Int) in px[(h / 2) * w + x].y }
                #expect(row(w - 2) > row(2), "\(backend) \(method): not increasing")
                if case .exposureGamma = method { continue }
                #expect(row(4) > 0.01 && row(w - 4) < 0.999, "\(backend) \(method): \(row(4)) \(row(w - 4))")
            }
        }
    }

    /// The dense solver agrees with photocraft's `dense_and_sparse_solvers_agree` line fit.
    @Test func denseSolverFitsALine() {
        var ne = NormalEquations(2)
        for x in 0..<10 { ne.add([(0, Double(x)), (1, 1)], 2 * Double(x) + 1, 1) }
        let a = ne.solve()!
        #expect(abs(a[0] - 2) < 1e-9 && abs(a[1] - 1) < 1e-9)
        #expect(NormalEquations.solveDense(2, [1, 2, 2, 4], [1, 2]) == nil)
    }
}
