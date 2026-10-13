// Conversions between PSD planar big-endian channel data and interleaved native-endian surface
// bytes, matting, and the per-core band helpers.
// Port of photocraft-io (crates/io/src/pixels.rs), MIT OR Apache-2.0, © ArtCraft Team and the
// PhotoCraft contributors. `par_map` runs on `DispatchQueue.concurrentPerform`.

import Dispatch
import Foundation
import PCFoundation

public enum PSDPixels {
    /// PSD depth (bits) for a sample type.
    public static func psdDepth(_ s: SampleType) -> UInt16 {
        switch s {
        case .u8: 8
        case .u16: 16
        case .f32: 32
        }
    }

    /// Sample type for a PSD depth (1-bit is expanded to 8).
    public static func sampleForDepth(_ depth: UInt16) -> SampleType {
        switch depth {
        case 16: .u16
        case 32: .f32
        default: .u8
        }
    }

    @inline(__always) static func invertSample(_ p: UnsafeMutableRawBufferPointer, _ at: Int, _ s: SampleType) {
        switch s {
        case .u8: p[at] = 255 &- p[at]
        case .u16:
            let v = p.loadUnaligned(fromByteOffset: at, as: UInt16.self)
            p.storeBytes(of: 65535 &- v, toByteOffset: at, as: UInt16.self)
        case .f32:
            let v = p.loadUnaligned(fromByteOffset: at, as: Float.self)
            p.storeBytes(of: 1 - v, toByteOffset: at, as: Float.self)
        }
    }

    /// Interleaves planes (big-endian samples, `n` pixels each). `nil` planes (or planes too short
    /// for a pixel) are filled with `fill[c]` (a native-endian encoded sample). Channels whose
    /// `invert[c]` is set are inverted (PSD stores CMYK as `max − ink`).
    public static func interleave(_ planes: [[UInt8]?], _ fill: [[UInt8]], _ n: Int, _ s: SampleType, _ invert: [Bool]) -> [UInt8] {
        let bps = s.bytes
        let ch = planes.count
        let row = ch * bps
        guard n > 0, ch > 0 else { return [] }
        var out = [UInt8](repeating: 0, count: n * row)
        let ranges = bands(n)
        out.withUnsafeMutableBytes { o in
            let shared = SharedBuffer(UnsafeMutableRawBufferPointer(start: o.baseAddress, count: o.count))
            DispatchQueue.concurrentPerform(iterations: ranges.count) { k in
                let base = shared.pointer
                let band = ranges[k]
                for c in 0 ..< ch {
                    let inv = c < invert.count && invert[c]
                    let f = c < fill.count ? fill[c] : [UInt8](repeating: 0, count: bps)
                    if let pl = planes[c] {
                        pl.withUnsafeBytes { src in
                            for p in band {
                                let dst = (p * ch + c) * bps
                                if src.count >= (p + 1) * bps {
                                    let so = p * bps
                                    for q in 0 ..< bps { base[dst + q] = src[so + bps - 1 - q] }
                                    if inv { invertSample(base, dst, s) }
                                } else {
                                    for q in 0 ..< bps { base[dst + q] = q < f.count ? f[q] : 0 }
                                }
                            }
                        }
                    } else {
                        for p in band {
                            let dst = (p * ch + c) * bps
                            for q in 0 ..< bps { base[dst + q] = q < f.count ? f[q] : 0 }
                        }
                    }
                }
            }
        }
        return out
    }

    /// Splits interleaved native-endian bytes into big-endian planes.
    public static func deinterleave(_ bytes: [UInt8], _ ch: Int, _ s: SampleType, _ invert: [Bool]) -> [[UInt8]] {
        let bps = s.bytes
        guard ch > 0 else { return [] }
        let n = bytes.count / (ch * bps)
        var planes = [[UInt8]](repeating: [UInt8](repeating: 0, count: n * bps), count: ch)
        bytes.withUnsafeBytes { src in
            for c in 0 ..< ch {
                let inv = c < invert.count && invert[c]
                planes[c].withUnsafeMutableBytes { dst in
                    var tmp = [UInt8](repeating: 0, count: 4)
                    tmp.withUnsafeMutableBytes { t in
                        for p in 0 ..< n {
                            let so = (p * ch + c) * bps
                            for q in 0 ..< bps { t[q] = src[so + q] }
                            if inv { invertSample(t, 0, s) }
                            for q in 0 ..< bps { dst[p * bps + q] = t[bps - 1 - q] }
                        }
                    }
                }
            }
        }
        return planes
    }

    /// Native-endian encoding of the maximum sample value.
    public static func maxSample(_ s: SampleType) -> [UInt8] {
        switch s {
        case .u8: [255]
        case .u16: [255, 255]
        case .f32: withUnsafeBytes(of: Float(1)) { Array($0) }
        }
    }

    /// Native-endian encoding of zero.
    public static func zeroSample(_ s: SampleType) -> [UInt8] { [UInt8](repeating: 0, count: s.bytes) }

    /// Top of Photoshop's 16-bit Lab a*/b* scale: it stores `32768 + 256·a` (0...65280 spans
    /// −128...127, fitted on psd-tools `4x4_16bit_lab`), while documents keep a*/b* on the 8-bit
    /// scale `(a + 128) / 255` at every depth.
    public static let lab16ChromaMax: Float = 65280

    /// Rescales the a*/b* channels (1 and 2) of interleaved native-endian 16-bit Lab pixels with
    /// `ch` channels: PSD → document when `toDoc`, else document → PSD. Round-trips exactly.
    public static func lab16Chroma(_ bytes: inout [UInt8], _ ch: Int, toDoc: Bool) {
        guard ch >= 3 else { return }
        let k = toDoc ? 65535.0 / Double(lab16ChromaMax) : Double(lab16ChromaMax) / 65535.0
        let px = ch * 2
        guard px > 0 else { return }
        bytes.withUnsafeMutableBytes { b in
            var at = 0
            while at + px <= b.count {
                for c in 1 ..< 3 {
                    let v = b.loadUnaligned(fromByteOffset: at + 2 * c, as: UInt16.self)
                    let w = UInt16(min((Double(v) * k).rounded(), 65535))
                    b.storeBytes(of: w, toByteOffset: at + 2 * c, as: UInt16.self)
                }
                at += px
            }
        }
    }

    /// Quantises a normalised value to big-endian bytes.
    public static func encodeBE(_ v: Float, _ s: SampleType, _ out: inout [UInt8]) {
        switch s {
        case .u8: out.append(v.isNaN ? 0 : UInt8(min(max(v, 0), 1) * 255 + 0.5))
        case .u16:
            let x = v.isNaN ? 0 : UInt16(min(max(v, 0), 1) * 65535 + 0.5)
            out.append(UInt8(x >> 8)); out.append(UInt8(x & 0xFF))
        case .f32:
            let x = v.bitPattern
            out += [UInt8(x >> 24), UInt8(x >> 16 & 0xFF), UInt8(x >> 8 & 0xFF), UInt8(x & 0xFF)]
        }
    }

    /// Decodes a big-endian sample at `index` to a normalised value.
    public static func decodeBE(_ bytes: [UInt8], _ index: Int, _ s: SampleType) -> Float {
        switch s {
        case .u8: return Float(bytes[index]) / 255
        case .u16: return Float(UInt16(bytes[index * 2]) << 8 | UInt16(bytes[index * 2 + 1])) / 65535
        case .f32:
            let o = index * 4
            return Float(bitPattern: UInt32(bytes[o]) << 24 | UInt32(bytes[o + 1]) << 16 | UInt32(bytes[o + 2]) << 8 | UInt32(bytes[o + 3]))
        }
    }

    /// Photoshop stores the merged image of a transparent document matted against white:
    /// `m = c·a + w·(1 − a)` per stored channel, where `w` is the model's white.
    @inline(__always) public static func matte(_ c: Float, _ a: Float, _ white: Float) -> Float { c * a + white * (1 - a) }

    /// Inverse of `matte` (returns `white` where alpha is 0). Keeps HDR and negative samples;
    /// integer encoders own normalised-range clipping.
    @inline(__always) public static func unmatte(_ m: Float, _ a: Float, _ white: Float) -> Float {
        a <= 0 ? white : (m - white * (1 - a)) / a
    }

    /// `items.map(f)` concurrently, in order.
    public static func parMap<T: Sendable, R: Sendable>(_ items: [T], _ f: @Sendable (T) -> R) -> [R] {
        if items.count < 2 { return items.map(f) }
        let box = ParBox<R>(count: items.count)
        DispatchQueue.concurrentPerform(iterations: items.count) { i in box.set(i, f(items[i])) }
        return box.values()
    }

    /// `0..<n` split into about one band per core.
    public static func bands(_ n: Int) -> [Range<Int>] {
        let k = max(1, min(32, ProcessInfo.processInfo.activeProcessorCount))
        let step = max(1, (n + k - 1) / k)
        return stride(from: 0, to: n, by: step).map { $0 ..< min($0 + step, n) }
    }
}

/// A buffer written by concurrent workers on disjoint ranges.
struct SharedBuffer: @unchecked Sendable {
    let pointer: UnsafeMutableRawBufferPointer
    init(_ p: UnsafeMutableRawBufferPointer) { pointer = p }
}

/// Results of concurrent work by index.
final class ParBox<R>: @unchecked Sendable {
    private let lock = NSLock()
    private var items: [R?]
    init(count: Int) { items = Array(repeating: nil, count: count) }
    func set(_ i: Int, _ v: R) { lock.withLock { items[i] = v } }
    func values() -> [R] { lock.withLock { items.compactMap { $0 } } }
}
