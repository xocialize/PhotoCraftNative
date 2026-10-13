// Shared fixtures: every test image is generated here, in memory (or written to a temporary
// directory when a URL is needed; these tests read no fixture data). MIT OR Apache-2.0,
// © ArtCraft Team and the PhotoCraft contributors.

import Foundation
import PCFoundation
@testable import PCPlatform

enum Fixtures {
    static let dir: URL = {
        let u = FileManager.default.temporaryDirectory.appendingPathComponent("pcplatform-fixtures")
        try? FileManager.default.createDirectory(at: u, withIntermediateDirectories: true)
        return u
    }()

    static func url(_ name: String) -> URL { dir.appendingPathComponent(name) }

    /// A deterministic gradient + noise raster in any format; alpha varies across the image.
    static func raster(_ f: PixelFormat, width: Int = 37, height: Int = 23, hdr: Bool = false) -> RasterBuffer {
        var v = [Float](repeating: 0, count: width * height * f.channels)
        var seed: UInt32 = 0x1234
        for y in 0..<height {
            for x in 0..<width {
                for k in 0..<f.channels {
                    seed = seed &* 1664525 &+ 1013904223
                    let noise = Float(seed >> 20) / 4096 * 0.2
                    var val = (Float(x) / Float(width - 1) * 0.6 + Float(y) / Float(height - 1) * 0.2 + Float(k) * 0.07 + noise)
                    val = val.truncatingRemainder(dividingBy: 1)
                    if f.alpha && k == f.channels - 1 { val = 0.25 + 0.75 * Float(x) / Float(width - 1) }
                    if hdr && !(f.alpha && k == f.channels - 1) { val *= 4 }
                    v[(y * width + x) * f.channels + k] = val
                }
            }
        }
        return RasterBuffer(width: width, height: height, format: f, floats: v)
    }

    /// A smooth, photo-like 8-bit RGB image (gradients, a disc, soft edges; little noise).
    static func smooth(width: Int, height: Int) -> RasterBuffer {
        var v = [Float](repeating: 0, count: width * height * 3)
        for y in 0..<height { for x in 0..<width {
            let u = Float(x) / Float(width), t = Float(y) / Float(height)
            let dx = u - 0.6, dy = t - 0.45
            let disc = max(0, min(1, (0.25 - (dx * dx + dy * dy).squareRoot()) * 20))
            let base = SIMD3<Float>(0.2 + 0.6 * u, 0.3 + 0.4 * t, 0.7 - 0.5 * u)
            let c = base * (1 - disc) + SIMD3(0.9, 0.5, 0.2) * disc
            for k in 0..<3 { v[(y * width + x) * 3 + k] = c[k] }
        } }
        return RasterBuffer(width: width, height: height, format: PixelFormat(mode: .rgb, sample: .u8, alpha: false), floats: v)
    }

    /// Max absolute difference of normalised samples.
    static func maxDiff(_ a: RasterBuffer, _ b: RasterBuffer) -> Float {
        let x = a.floats(), y = b.floats()
        precondition(x.count == y.count, "size mismatch \(a.width)×\(a.height)×\(a.format.channels) vs \(b.width)×\(b.height)×\(b.format.channels)")
        return zip(x, y).map { abs($0 - $1) }.max() ?? 0
    }

    static func meanDiff(_ a: RasterBuffer, _ b: RasterBuffer) -> Float {
        let x = a.floats(), y = b.floats()
        return zip(x, y).map { abs($0 - $1) }.reduce(0, +) / Float(max(x.count, 1))
    }

    /// A minimal uncompressed Bayer (RGGB) DNG: 16-bit, linear camera RGB = linear sRGB
    /// (ColorMatrix1 = XYZ(D65) → sRGB), neutral as-shot white. Three vertical patches: red, green,
    /// neutral gray. Apple's raw decoder needs about ≥ 200 px per side (measured: 256×192 is
    /// refused, 300×200 accepted).
    static func dng(width w: Int = 384, height h: Int = 256, orientation: UInt16 = 1) -> Data {
        var px = [UInt8](repeating: 0, count: w * h * 2)
        for y in 0..<h { for x in 0..<w {
            let scene: (Double, Double, Double) = x < w / 3 ? (0.6, 0.1, 0.1) : (x < 2 * w / 3 ? (0.1, 0.5, 0.1) : (0.3, 0.3, 0.3))
            let c = y % 2 == 0 ? (x % 2 == 0 ? scene.0 : scene.1) : (x % 2 == 0 ? scene.1 : scene.2)
            let v = UInt16(c * 65535)
            px[(y * w + x) * 2] = UInt8(v & 0xFF); px[(y * w + x) * 2 + 1] = UInt8(v >> 8)
        } }
        var t = TIFFWriter()
        t.long(254, [0]); t.long(256, [UInt32(w)]); t.long(257, [UInt32(h)]); t.short(258, [16]); t.short(259, [1]); t.short(262, [32803])
        t.ascii(271, "PhotoCraftNative"); t.ascii(272, "Synthetic"); t.long(273, [0]); t.short(274, [orientation]); t.short(277, [1])
        t.long(278, [UInt32(h)]); t.long(279, [UInt32(w * h * 2)]); t.short(284, [1])
        t.short(33421, [2, 2]); t.byte(33422, [0, 1, 1, 2]); t.byte(50706, [1, 4, 0, 0]); t.byte(50707, [1, 1, 0, 0])
        t.ascii(50708, "PhotoCraftNative Synthetic"); t.long(50714, [0]); t.long(50717, [65535])
        t.srational(50721, [3.2404542, -1.5371385, -0.4985314, -0.9692660, 1.8760108, 0.0415560, 0.0556434, -0.2040259, 1.0572252])
        t.rational(50728, [1, 1, 1]); t.short(50778, [21])
        return t.build(pixels: px, stripOffsetTag: 273)
    }
}

/// A little-endian TIFF writer for synthetic DNGs.
struct TIFFWriter {
    var entries: [(tag: UInt16, type: UInt16, count: UInt32, data: [UInt8])] = []
    static func le<T: FixedWidthInteger>(_ v: T) -> [UInt8] { withUnsafeBytes(of: v.littleEndian) { Array($0) } }
    mutating func short(_ t: UInt16, _ v: [UInt16]) { entries.append((t, 3, UInt32(v.count), v.flatMap(Self.le))) }
    mutating func long(_ t: UInt16, _ v: [UInt32]) { entries.append((t, 4, UInt32(v.count), v.flatMap(Self.le))) }
    mutating func byte(_ t: UInt16, _ v: [UInt8]) { entries.append((t, 1, UInt32(v.count), v)) }
    mutating func ascii(_ t: UInt16, _ s: String) { let b = Array(s.utf8) + [0]; entries.append((t, 2, UInt32(b.count), b)) }
    mutating func srational(_ t: UInt16, _ v: [Double]) {
        entries.append((t, 10, UInt32(v.count), v.flatMap { Self.le(Int32(($0 * 10000).rounded())) + Self.le(Int32(10000)) }))
    }
    mutating func rational(_ t: UInt16, _ v: [Double]) {
        entries.append((t, 5, UInt32(v.count), v.flatMap { Self.le(UInt32(($0 * 10000).rounded())) + Self.le(UInt32(10000)) }))
    }
    func build(pixels: [UInt8], stripOffsetTag: UInt16) -> Data {
        var es = entries.sorted { $0.tag < $1.tag }
        let ifdSize = 2 + es.count * 12 + 4
        var extra: [UInt8] = [], offsets: [Int: Int] = [:]
        for (i, e) in es.enumerated() where e.data.count > 4 {
            offsets[i] = 8 + ifdSize + extra.count
            extra += e.data
            if extra.count % 2 == 1 { extra.append(0) }
        }
        let pixStart = 8 + ifdSize + extra.count
        if let si = es.firstIndex(where: { $0.tag == stripOffsetTag }) { es[si].data = Self.le(UInt32(pixStart)) }
        var out: [UInt8] = [0x49, 0x49, 42, 0] + Self.le(UInt32(8)) + Self.le(UInt16(es.count))
        for (i, e) in es.enumerated() {
            out += Self.le(e.tag) + Self.le(e.type) + Self.le(e.count)
            if let off = offsets[i] { out += Self.le(UInt32(off)) } else { var d = e.data; while d.count < 4 { d.append(0) }; out += d }
        }
        out += [0, 0, 0, 0] + extra + pixels
        return Data(out)
    }
}
