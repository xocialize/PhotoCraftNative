// Port of photocraft-algo's photography timings (crates/algo/examples/bench_photo.rs), MIT OR Apache-2.0, © ArtCraft Team and the PhotoCraft contributors.

import Foundation
import Testing
@testable import PCAlgo
import PCFoundation

/// Release timings of the photo area (opt-in: `PCALGO_PERF=1 swift test -c release --filter PhotoPerfTests`).
@Suite(.serialized, .enabled(if: ProcessInfo.processInfo.environment["PCALGO_PERF"] != nil))
struct PhotoPerfTests {
    static func best(_ n: Int = 3, _ f: () throws -> Void) rethrows -> Double {
        var t = Double.infinity
        for _ in 0..<n {
            let t0 = DispatchTime.now().uptimeNanoseconds
            try f()
            t = min(t, Double(DispatchTime.now().uptimeNanoseconds - t0) / 1e6)
        }
        return t
    }

    static func report(_ name: String, cpu: Double, gpu: Double?) {
        if let gpu {
            print(String(format: "PERF\t%@\tcpu %.1f ms\tgpu-wall %.1f ms", name, cpu, gpu))
        } else {
            print(String(format: "PERF\t%@\tcpu %.1f ms", name, cpu))
        }
    }

    @Test func pyramid() throws {
        let (w, h, ch, n) = (4096, 3072, 4, 3)
        var imgs = (0..<n).map { PhotoTest.pixels(w, h, ch, seed: UInt32(1 + $0)) }
        imgs[1] = PhotoTest.blurImg(w, h, ch, imgs[1], 1)
        let luma = imgs.map { PhotoTest.lumaOf(w, h, ch, $0) }
        let alpha = [[Float]](repeating: [Float](repeating: 1, count: w * h), count: n)
        for p in [Pyramid.StackFusion(), Pyramid.StackFusion(halo: 0)] {
            _ = try Pyramid.fuseStack(width: w, height: h, channels: ch, images: imgs, luma: luma, alpha: alpha, p, on: .gpu)
            let g = try Self.best { _ = try Pyramid.fuseStack(width: w, height: h, channels: ch, images: imgs, luma: luma, alpha: alpha, p, on: .gpu) }
            let c = try Self.best(1) { _ = try Pyramid.fuseStack(width: w, height: h, channels: ch, images: imgs, luma: luma, alpha: alpha, p, on: .cpu) }
            Self.report("Pyramid.fuseStack halo \(p.halo) \(n)× \(w)x\(h)x\(ch)", cpu: c, gpu: g)
        }
        let wts = Pyramid.stackWeights(width: w, height: h, luma: luma, alpha: alpha)
        let lv = Pyramid.autoLevels(width: w, height: h)
        _ = try Pyramid.blend(width: w, height: h, channels: ch, images: imgs, weights: wts, levels: lv, on: .gpu)
        let g = try Self.best { _ = try Pyramid.blend(width: w, height: h, channels: ch, images: imgs, weights: wts, levels: lv, on: .gpu) }
        let c = try Self.best(1) { _ = try Pyramid.blend(width: w, height: h, channels: ch, images: imgs, weights: wts, levels: lv, on: .cpu) }
        Self.report("Pyramid.blend \(n)× \(w)x\(h)x\(ch)", cpu: c, gpu: g)
        _ = try Pyramid.stackWeights(width: w, height: h, luma: luma, alpha: alpha, on: .gpu)
        let swg = try Self.best { _ = try Pyramid.stackWeights(width: w, height: h, luma: luma, alpha: alpha, on: .gpu) }
        let sw = Self.best(1) { _ = Pyramid.stackWeights(width: w, height: h, luma: luma, alpha: alpha) }
        Self.report("Pyramid.stackWeights \(n)× \(w)x\(h)", cpu: sw, gpu: swg)
    }

    @Test func multiband() throws {
        let (w, h, ch) = (6000, 2000, 3)
        var imgs: [Panorama.RoiImage] = [], wts: [[Float]] = []
        for k in 0..<3 {
            let rw = 2400, rh = 1900
            let px = PhotoTest.pixels(rw, rh, ch, seed: UInt32(k + 1))
            imgs.append(Panorama.RoiImage(x0: Int32(k * 1800), y0: Int32(k * 30), w: rw, h: rh, ch: ch, px: px, alpha: [Float](repeating: 1, count: rw * rh)))
            wts.append((0..<(rw * rh)).map { i in (i % rw) < 1200 + 300 * k ? 1 : 0 })
        }
        let lv = Panorama.blendLevels(width: w, height: h)
        _ = try Panorama.multiband(width: w, height: h, images: imgs, weights: wts, levels: lv, on: .gpu)
        let g = try Self.best { _ = try Panorama.multiband(width: w, height: h, images: imgs, weights: wts, levels: lv, on: .gpu) }
        let c = try Self.best(1) { _ = try Panorama.multiband(width: w, height: h, images: imgs, weights: wts, levels: lv, on: .cpu) }
        Self.report("Panorama.multiband 3× 2400x1900 → \(w)x\(h)x\(ch)", cpu: c, gpu: g)
    }

    @Test func registration() throws {
        let (w, h) = (1200, 800)
        let img = PhotoPanoramaTests.scene(w, h, 5)
        _ = try Features.harris(width: w, height: h, img, max: 800, minDist: 17, on: .gpu)
        let g = try Self.best(5) { _ = try Features.harris(width: w, height: h, img, max: 800, minDist: 17, on: .gpu) }
        let c = try Self.best(5) { _ = try Features.harris(width: w, height: h, img, max: 800, minDist: 17, on: .cpu) }
        Self.report("Features.harris \(w)x\(h)", cpu: c, gpu: g)
        let corners = try Features.harris(width: w, height: h, img, max: 800, minDist: 17)
        let d = Self.best(5) { _ = Features.describe(width: w, height: h, img, corners: corners, upright: false) }
        Self.report("Features.describe \(corners.count) corners", cpu: d, gpu: nil)
        let feats = try (0..<4).map { k in
            try Panorama.detect(width: w, height: h, luma: PhotoPanoramaTests.scene(w, h, 5).enumerated().map { i, v in i % w < w - 300 * k ? v : 0.3 }, max: 800)
        }
        let m = Self.best(1) { _ = Panorama.matchPairs(feats) }
        Self.report("Panorama.matchPairs 4 images", cpu: m, gpu: nil)
        // Direct registration at the engine's search size (≤ 2048 px).
        let (dw, dh) = (2048, 1365)
        let ref = PhotoDirectTests.texture(dw, dh, 3)
        let truth = DirectAlign.Pose(dx: 3.3 / Double(dw), dy: -2.1 / Double(dh), scale: 1.004, rot: PhotoKit.radians(0.3))
        let mt = truth.matrix(width: dw, height: dh)
        let tgt: [Float] = (0..<(dw * dh)).map { i in
            let (x, y) = mt.apply(Double(i % dw), Double(i / dw))
            return DirectAlign.sample(ref, dw, dh, min(max(x, 0), Double(dw - 1)), min(max(y, 0), Double(dh - 1)))
        }
        let lv = DirectAlign.levels(DirectAlign.Plane(w: dw, h: dh, luma: ref))
        let one = Self.best(5) { _ = DirectAlign.cost(lv[0], lv[0], truth) }
        Self.report("DirectAlign.cost one evaluation \(dw)x\(dh)", cpu: one, gpu: nil)
        let r = Self.best(1) {
            _ = DirectAlign.register(reference: DirectAlign.Plane(w: dw, h: dh, luma: ref), target: DirectAlign.Plane(w: dw, h: dh, luma: tgt), motion: .similarity)
        }
        Self.report("DirectAlign.register similarity \(dw)x\(dh)", cpu: r, gpu: nil)
        let scan = PhotoScanCropTests.scan(2400, 1800, [
            ScanCrop.FoundPhoto(center: SIMD2(600, 500), width: 700, height: 500, angle: 5, area: 0),
            ScanCrop.FoundPhoto(center: SIMD2(1700, 1200), width: 800, height: 600, angle: -8, area: 0),
        ])
        let sc = Self.best(3) { _ = ScanCrop.findPhotos(width: 2400, height: 1800, rgba: scan) }
        Self.report("ScanCrop.findPhotos 2400x1800", cpu: sc, gpu: nil)
    }
}
