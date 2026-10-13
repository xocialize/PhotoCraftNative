// Port of photocraft-algo (crates/algo/src/scancrop.rs, exif.rs, photo_util.rs tests), MIT OR Apache-2.0, © ArtCraft Team and the PhotoCraft contributors.

import Foundation
import Testing
@testable import PCAlgo

@Suite struct PhotoScanCropTests {
    typealias FoundPhoto = ScanCrop.FoundPhoto

    /// A scan: white background with rotated textured rectangles.
    static func scan(_ w: Int, _ h: Int, _ photos: [FoundPhoto]) -> [SIMD4<Float>] {
        var px = [SIMD4<Float>](repeating: SIMD4(0.97, 0.97, 0.96, 1), count: w * h)
        for (k, p) in photos.enumerated() {
            let a = PhotoKit.radians(p.angle)
            let s = sin(a), c = cos(a)
            for y in 0..<h {
                for x in 0..<w {
                    let dx = Double(x) + 0.5 - p.center.x, dy = Double(y) + 0.5 - p.center.y
                    let u = c * dx + s * dy, v = -s * dx + c * dy
                    if abs(u) < p.width / 2 && abs(v) < p.height / 2 {
                        let t = Float(sin(u * 0.05) * cos(v * 0.07))
                        px[y * w + x] = SIMD4(0.3 + 0.2 * t, 0.2 + 0.1 * Float(k), 0.5 - 0.2 * t, 1)
                    }
                }
            }
        }
        return px
    }

    @Test func findsRotatedPhotosInReadingOrder() {
        let truth = [
            FoundPhoto(center: SIMD2(150, 120), width: 180, height: 120, angle: 7, area: 0),
            FoundPhoto(center: SIMD2(450, 130), width: 160, height: 130, angle: -12, area: 0),
            FoundPhoto(center: SIMD2(300, 330), width: 220, height: 110, angle: 3, area: 0),
        ]
        let (w, h) = (600, 440)
        let found = ScanCrop.findPhotos(width: w, height: h, rgba: Self.scan(w, h, truth))
        #expect(found.count == 3, "\(found)")
        for (f, t) in zip(found, truth) {
            #expect(abs(f.angle - t.angle) < 1, "\(f) vs \(t)")
            #expect(abs(f.center.x - t.center.x) < 3 && abs(f.center.y - t.center.y) < 3, "\(f)")
            #expect(abs(f.width - t.width) < 6 && abs(f.height - t.height) < 6, "\(f)")
        }
        if let first = found.first {
            let c = first.corners()
            let mid = SIMD2((c[0].x + c[2].x) / 2, (c[0].y + c[2].y) / 2)
            #expect(abs(mid.x - first.center.x) < 1e-9)
        }
        #expect(ScanCrop.findPhotos(width: w, height: h, rgba: [SIMD4<Float>](repeating: SIMD4(1, 1, 1, 1), count: w * h)).isEmpty)
    }

    @Test func otsuSplitsTwoModesAndHullIsConvex() {
        let v: [Float] = (0..<1000).map { $0 < 600 ? 0.1 + Float($0 % 7) * 0.001 : 0.8 + Float($0 % 5) * 0.001 }
        let t = ScanCrop.otsu(v)
        #expect(t > 0.1 && t < 0.8, "\(t)")
        let pts: [SIMD2<Double>] = [[0, 0], [4, 0], [4, 4], [0, 4], [2, 2], [1, 3], [4, 0]]
        let hull = ScanCrop.convexHull(pts)
        #expect(hull.count == 4 && !hull.contains([2, 2]))
        let (c, w, h, a) = ScanCrop.minRect(hull)
        #expect(abs(c.x - 2) < 1e-9 && abs(c.y - 2) < 1e-9 && abs(w * h - 16) < 1e-9 && abs(a) <= 45)
    }
}

@Suite struct PhotoExifTests {
    @Test func roundTripsAndSurvivesGarbage() {
        let info = Exif.CameraInfo(make: "Generic", model: "Camera 1", lens: "24-70mm", exposureTime: 0.004, fNumber: 8, iso: 200,
                                   focalLength: 35, focalLength35mm: 52, dateTaken: "2024:02:17 12:40:19")
        let b = Exif.build(info)
        let r = Exif.read(b)
        #expect(r == info)
        #expect(abs(r.exposureFactor! - 0.004 * 2 / 64) < 1e-9)
        #expect(Exif.read(Array("Exif\0\0".utf8) + b) == info)
        #expect(Exif.read(Array("nonsense".utf8)) == Exif.CameraInfo())
        for cut in [5, 12, 30, b.count - 3] { _ = Exif.read(Array(b[0..<cut])) }
    }

    /// Hostile payloads: huge counts, offsets near `UInt32.max`, self-referencing IFDs and random
    /// bytes read as nil fields instead of trapping.
    @Test func hostilePayloadsNeverTrap() {
        func entry(_ tag: UInt16, _ typ: UInt16, _ count: UInt32, _ value: UInt32) -> [UInt8] {
            func le16(_ v: UInt16) -> [UInt8] { [UInt8(v & 0xFF), UInt8(v >> 8)] }
            func le32(_ v: UInt32) -> [UInt8] { [UInt8(v & 0xFF), UInt8((v >> 8) & 0xFF), UInt8((v >> 16) & 0xFF), UInt8(v >> 24)] }
            return le16(tag) + le16(typ) + le32(count) + le32(value)
        }
        var b: [UInt8] = Array("II*\0".utf8) + [8, 0, 0, 0]
        let entries = [
            entry(0x010F, 2, .max, 8),
            entry(0x0110, 2, 16, .max - 1),
            entry(0x829A, 5, .max, 20),
            entry(0x829D, 5, 1, .max - 3),
            entry(0x9003, 2, 0x4000_0000, 8),
            entry(0x8769, 4, 1, 8),
            entry(0x8769, 4, 1, .max),
        ]
        let n = UInt16(entries.count + 3)
        b += [UInt8(n & 0xFF), UInt8(n >> 8)]
        for e in entries { b += e }
        #expect(Exif.read(b) == Exif.CameraInfo())
        let be: [UInt8] = Array("MM\0*".utf8) + [0xFF, 0xFF, 0xFF, 0xFF]
        #expect(Exif.read(be) == Exif.CameraInfo())
        var x: UInt32 = 0x2545_F491
        for _ in 0..<200 {
            var noise: [UInt8] = Array("II*\0".utf8) + [8, 0, 0, 0]
            for _ in 0..<96 {
                x ^= x << 13; x ^= x >> 17; x ^= x << 5
                noise.append(UInt8(truncatingIfNeeded: x))
            }
            _ = Exif.read(noise)
        }
        let good = Exif.build(Exif.CameraInfo(make: "Make", exposureTime: 0.004, dateTaken: "2024:02:17 12:40:19"))
        for cut in 0..<good.count { _ = Exif.read(Array(good[0..<cut])) }
    }
}

/// photo_util's tests (the dense solver here is the Tone area's `NormalEquations`).
@Suite struct PhotoUtilTests {
    @Test func denseSolverFitsALine() {
        var ne = NormalEquations(2)
        for x in 0..<10 { ne.add([(0, Double(x)), (1, 1)], 2 * Double(x) + 1, 1) }
        let a = ne.solve()!
        #expect(abs(a[0] - 2) < 1e-9 && abs(a[1] - 1) < 1e-9)
        #expect(NormalEquations.solveDense(2, [1, 2, 2, 4], [1, 2]) == nil)
        #expect(PhotoKit.solve(2, [1, 2, 2, 4], [1, 2]) == nil)
        let s = PhotoKit.solve(2, [2, 1, 1, 3], [3, 5])!
        #expect(abs(s[0] - 0.8) < 1e-12 && abs(s[1] - 1.4) < 1e-12)
    }

    @Test func rngIsSplitMix64() {
        var r = PhotoKit.Rng(0)
        #expect(r.next() == 0xE220_A839_7B1D_CDAF)
        #expect(r.next() == 0x6E78_9E6A_A1B9_65F4)
        var u = PhotoKit.Rng(5)
        let v = u.unit()
        #expect(v >= 0 && v < 1)
        #expect(PhotoKit.stableOrder(5) { [3, 1, 3, 0, 1][$0] < [3, 1, 3, 0, 1][$1] } == [3, 1, 4, 0, 2])
    }
}
