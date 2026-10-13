// Port of photocraft-paint (crates/paint/src/tile.rs), MIT OR Apache-2.0, © ArtCraft Team and the PhotoCraft contributors.
//
// Grayscale bitmaps for sampled tips and texture patterns, with a compact Codable form. Values
// are 16-bit (0…65535 ↔ 0…1) so presets stay small; JSON carries them as base64 of the
// little-endian samples (`"data": "…"`), and also accepts a plain array of 0…1 floats.

import Foundation

/// A grayscale bitmap, row-major, 1 = full.
public struct GrayTile: Hashable, Sendable {
    public var width: UInt32
    public var height: UInt32
    public var data: [UInt16]

    public init(width: UInt32, height: UInt32, data: [UInt16]) {
        self.width = width; self.height = height; self.data = data
    }

    /// Build from a function returning 0…1 values.
    public init(width: UInt32, height: UInt32, _ f: (UInt32, UInt32) -> Float) {
        var d: [UInt16] = []
        d.reserveCapacity(Int(width) * Int(height))
        for y in 0..<height { for x in 0..<width { d.append(q16(f(x, y))) } }
        self.init(width: width, height: height, data: d)
    }

    /// Build from 0…1 floats (`width × height`).
    public init(width: UInt32, height: UInt32, floats v: [Float]) {
        precondition(v.count == Int(width) * Int(height), "GrayTile size mismatch")
        self.init(width: width, height: height, data: v.map(q16))
    }

    @inlinable public func get(_ x: UInt32, _ y: UInt32) -> Float {
        Float(data[Int(y * width + x)]) / 65535
    }

    public func toF32() -> [Float] { data.map { Float($0) / 65535 } }

    public var isValid: Bool { width > 0 && height > 0 && data.count == Int(width) * Int(height) }

    /// A box-filtered copy whose larger side is at most `maxSide` (the whole tile when it is
    /// already that small), quantised to 8-bit levels so it stores compactly. Deterministic. An
    /// invalid tile gives 1×1.
    public func preview(_ maxSide: UInt32) -> GrayTile {
        let q8 = { (v: UInt32) -> UInt16 in UInt16((v + 128) / 257 * 257) }
        if !isValid { return GrayTile(width: 1, height: 1, data: [0]) }
        let w = Int(width), h = Int(height)
        let mx = max(Int(maxSide), 1)
        let f = max((max(w, h) + mx - 1) / mx, 1)
        let nw = (w + f - 1) / f, nh = (h + f - 1) / f
        var sum = [UInt64](repeating: 0, count: nw * nh)
        var cnt = [UInt32](repeating: 0, count: nw * nh)
        for y in 0..<h {
            let base = (y / f) * nw
            for x in 0..<w {
                sum[base + x / f] += UInt64(data[y * w + x])
                cnt[base + x / f] += 1
            }
        }
        let d = (0..<(nw * nh)).map { i in q8(cnt[i] > 0 ? UInt32(sum[i] / UInt64(cnt[i])) : 0) }
        return GrayTile(width: UInt32(nw), height: UInt32(nh), data: d)
    }
}

/// Larger side of the previews kept for tips that are loaded on demand (`StoredTile`).
public let previewSide: UInt32 = 96

/// A tip or texture bitmap kept outside the brush settings by its owner and loaded only when the
/// brush is used: `preview` is a small copy for thumbnails and stroke previews; `full` is the
/// bitmap once the owner has loaded it (never serialised). Rendering uses `bitmap`: the full
/// bitmap, or the preview when the owner could not load it. Equal when key and size are.
public struct StoredTile: Hashable, Sendable, Codable {
    public var key: String
    public var width: UInt32
    public var height: UInt32
    public var preview: GrayTile
    public var full: GrayTile?

    public init(key: String, width: UInt32, height: UInt32, preview: GrayTile, full: GrayTile? = nil) {
        self.key = key; self.width = width; self.height = height; self.preview = preview; self.full = full
    }

    public var bitmap: GrayTile { full ?? preview }
    public var isLoaded: Bool { full != nil }

    public static func == (a: StoredTile, b: StoredTile) -> Bool {
        a.key == b.key && a.width == b.width && a.height == b.height
    }

    public func hash(into h: inout Hasher) { h.combine(key); h.combine(width); h.combine(height) }

    enum CodingKeys: String, CodingKey { case key, width, height, preview }

    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        key = try c.decode(String.self, forKey: .key)
        width = try c.decode(UInt32.self, forKey: .width)
        height = try c.decode(UInt32.self, forKey: .height)
        preview = try c.decode(GrayTile.self, forKey: .preview)
        full = nil
    }

    public func encode(to encoder: any Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(key, forKey: .key)
        try c.encode(width, forKey: .width)
        try c.encode(height, forKey: .height)
        try c.encode(preview, forKey: .preview)
    }
}

@inline(__always) func q16(_ v: Float) -> UInt16 {
    asU16(clampR(v, 0, 1) * 65535 + 0.5)
}

// MARK: Codable

extension GrayTile: Codable {
    enum CodingKeys: String, CodingKey { case width, height, data }

    public func encode(to encoder: any Encoder) throws {
        var bytes = [UInt8]()
        bytes.reserveCapacity(data.count * 2)
        for v in data { bytes.append(UInt8(v & 0xFF)); bytes.append(UInt8(v >> 8)) }
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(width, forKey: .width)
        try c.encode(height, forKey: .height)
        try c.encode(Base64.encode(bytes), forKey: .data)
    }

    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let w = try c.decode(UInt32.self, forKey: .width)
        let h = try c.decode(UInt32.self, forKey: .height)
        let n = Int(w) * Int(h)
        let d: [UInt16]
        if let s = try? c.decode(String.self, forKey: .data) {
            guard let b = Base64.decode(s) else {
                throw DecodingError.dataCorruptedError(forKey: .data, in: c, debugDescription: "invalid base64 in tile data")
            }
            d = stride(from: 0, to: b.count - 1, by: 2).map { UInt16(b[$0]) | (UInt16(b[$0 + 1]) << 8) }
        } else {
            d = try c.decode([Float].self, forKey: .data).map(q16)
        }
        if n == 0 || d.count != n {
            throw DecodingError.dataCorruptedError(forKey: .data, in: c,
                                                   debugDescription: "tile data has \(d.count) samples, expected \(w)×\(h)")
        }
        self.init(width: w, height: h, data: d)
    }
}

/// Standard base64 with padding (the tile Codable form; commands taking file bytes).
public enum Base64 {
    private static let alphabet = Array("ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/".utf8)

    public static func encode(_ b: [UInt8]) -> String {
        var out = [UInt8]()
        out.reserveCapacity((b.count + 2) / 3 * 4)
        var i = 0
        while i < b.count {
            let c1 = i + 1 < b.count ? UInt32(b[i + 1]) : 0
            let c2 = i + 2 < b.count ? UInt32(b[i + 2]) : 0
            let n = (UInt32(b[i]) << 16) | (c1 << 8) | c2
            let len = min(3, b.count - i)
            out.append(alphabet[Int(n >> 18) & 63])
            out.append(alphabet[Int(n >> 12) & 63])
            out.append(len > 1 ? alphabet[Int(n >> 6) & 63] : UInt8(ascii: "="))
            out.append(len > 2 ? alphabet[Int(n) & 63] : UInt8(ascii: "="))
            i += 3
        }
        return String(decoding: out, as: UTF8.self)
    }

    /// Decode standard base64 (whitespace ignored); nil on invalid input.
    public static func decode(_ str: String) -> [UInt8]? {
        func val(_ c: UInt8) -> UInt32? {
            switch c {
            case UInt8(ascii: "A")...UInt8(ascii: "Z"): UInt32(c - UInt8(ascii: "A"))
            case UInt8(ascii: "a")...UInt8(ascii: "z"): UInt32(c - UInt8(ascii: "a") + 26)
            case UInt8(ascii: "0")...UInt8(ascii: "9"): UInt32(c - UInt8(ascii: "0") + 52)
            case UInt8(ascii: "+"): 62
            case UInt8(ascii: "/"): 63
            default: nil
            }
        }
        let s = str.utf8.filter { !($0 == 0x20 || $0 == 0x09 || $0 == 0x0A || $0 == 0x0C || $0 == 0x0D) }
        if s.count % 4 != 0 { return nil }
        var out = [UInt8]()
        out.reserveCapacity(s.count / 4 * 3)
        var i = 0
        while i < s.count {
            let chunk = s[i..<i + 4]
            var pad = 0
            for x in chunk.reversed() { if x == UInt8(ascii: "=") { pad += 1 } else { break } }
            var n: UInt32 = 0
            for (k, x) in chunk.enumerated() {
                if k >= 4 - pad { n = n << 6 } else {
                    guard let v = val(x) else { return nil }
                    n = (n << 6) | v
                }
            }
            out.append(UInt8((n >> 16) & 0xFF))
            if pad < 2 { out.append(UInt8((n >> 8) & 0xFF)) }
            if pad < 1 { out.append(UInt8(n & 0xFF)) }
            i += 4
        }
        return out
    }
}

// MARK: Sampling

/// A float mip pyramid of a `GrayTile` for sampling at any scale without aliasing.
public struct Mips: Sendable {
    /// (width, height, values), level 0 = full resolution.
    public var levels: [(w: Int, h: Int, v: [Float])]

    public init(_ t: GrayTile) {
        var levels: [(w: Int, h: Int, v: [Float])] = [(Int(t.width), Int(t.height), t.toF32())]
        while let last = levels.last {
            let (w, h, v) = last
            if w <= 1 && h <= 1 { break }
            let nw = (w + 1) / 2, nh = (h + 1) / 2
            var nv = [Float](repeating: 0, count: nw * nh)
            for y in 0..<nh {
                for x in 0..<nw {
                    var s: Float = 0, c: Float = 0
                    for dy in 0..<2 {
                        for dx in 0..<2 {
                            let sx = x * 2 + dx, sy = y * 2 + dy
                            if sx < w && sy < h { s += v[sy * w + sx]; c += 1 }
                        }
                    }
                    nv[y * nw + x] = s / c
                }
            }
            levels.append((nw, nh, nv))
        }
        self.levels = levels
    }

    /// Mip level for drawing the tile at `px` pixels across its larger side.
    public func levelFor(_ px: Float) -> Int {
        let l0 = levels[0]
        let ratio = maxR(Float(max(l0.w, l0.h)) / maxR(px, 1), 1)
        return min(asUsize(log2f(ratio).rounded(.down)), levels.count - 1)
    }

    /// Bilinear sample at normalised `u, v` in 0…1 (outside = 0).
    @inline(__always) public func sampleClamped(_ level: Int, _ u: Float, _ v: Float) -> Float {
        let l = levels[level]
        return l.v.withUnsafeBufferPointer { d in
            Mips.sample(d, l.w, l.h, u, v)
        }
    }

    @inline(__always) static func sample(_ d: UnsafeBufferPointer<Float>, _ w: Int, _ h: Int, _ u: Float, _ v: Float) -> Float {
        let fx = u * Float(w) - 0.5
        let fy = v * Float(h) - 0.5
        let x0f = fx.rounded(.down), y0f = fy.rounded(.down)
        let tx = fx - x0f, ty = fy - y0f
        let x0 = asI64(x0f), y0 = asI64(y0f)
        @inline(__always) func get(_ x: Int64, _ y: Int64) -> Float {
            (x < 0 || y < 0 || x >= Int64(w) || y >= Int64(h)) ? 0 : d[Int(y) * w + Int(x)]
        }
        let a = get(x0, y0) + (get(x0 &+ 1, y0) - get(x0, y0)) * tx
        let b = get(x0, y0 &+ 1) + (get(x0 &+ 1, y0 &+ 1) - get(x0, y0 &+ 1)) * tx
        return a + (b - a) * ty
    }
}

/// A tiling float pattern (texture), sampled with wrap-around.
public struct PatternImage: Sendable, Equatable {
    public var width: Int
    public var height: Int
    public var data: [Float]

    public init(width: Int, height: Int, data: [Float]) {
        self.width = width; self.height = height; self.data = data
    }

    @inline(__always) public func sampleWrap(_ x: Float, _ y: Float) -> Float {
        let xi = Int(remEuclid(Int(asI64(x.rounded(.down))), width))
        let yi = Int(remEuclid(Int(asI64(y.rounded(.down))), height))
        return data[yi * width + xi]
    }
}
