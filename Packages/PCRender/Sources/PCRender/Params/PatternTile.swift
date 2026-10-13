// Port of photocraft-compose (crates/compose/src/gradient_fill.rs, pattern.rs) and photocraft-gpu (compose.wgsl), MIT OR Apache-2.0, © ArtCraft Team and the PhotoCraft contributors.
//
// Pattern tiles as the compositor samples them (`compose::pattern::Tile`, built from photocraft-doc
// `Pattern`s by the render source) and their placement (`compose::pattern::Placement`).

import PCDocument
import PCFoundation

/// A pattern tile as the compositor samples it: straight RGBA as painted into the document's
/// colour mode (`compose::pattern::pattern_rgba`; phase 2 converts Grayscale/CMYK paint-in).
/// Samples are bilinear with wrap-around on premultiplied colour.
public struct PatternTile: Sendable, Hashable {
    public let id: String
    public let name: String
    public let width: Int
    public let height: Int
    /// Premultiplied RGBA, row-major.
    public let premultiplied: [SIMD4<Float>]
    /// Changes when the pixels change (GPU texture cache key).
    public let version: UInt64

    /// A tile from straight RGBA pixels (`width × height`).
    public init(id: String, name: String, width: Int, height: Int, straight: [SIMD4<Float>], version: UInt64 = 0) {
        precondition(straight.count == width * height, "PatternTile: pixel count")
        self.id = id; self.name = name; self.width = width; self.height = height; self.version = version
        self.premultiplied = straight.map { SIMD4($0.x * $0.w, $0.y * $0.w, $0.z * $0.w, $0.w) }
    }

    /// Most pixels a pattern may have to be painted (photocraft `MAX_PAINT_PIXELS`).
    public static let maxPaintPixels = 1 << 26

    public var isPaintable: Bool { width > 0 && height > 0 && width * height <= PatternTile.maxPaintPixels }

    @inline(__always) func at(_ x: Int, _ y: Int) -> SIMD4<Float> {
        var xi = x % width; if xi < 0 { xi += width }
        var yi = y % height; if yi < 0 { yi += height }
        return premultiplied[yi * width + xi]
    }

    /// Bilinear, wrapping sample at tile coordinates (pixel centres at `i + 0.5`); straight alpha.
    public func sample(_ u0: Double, _ v0: Double) -> SIMD4<Float> {
        let (u, v) = (u0 - 0.5, v0 - 0.5)
        let (x0, y0) = (u.rounded(.down), v.rounded(.down))
        let (fx, fy) = (Float(u - x0), Float(v - y0))
        let (ix, iy) = (Int(x0), Int(y0))
        var acc = SIMD4<Float>.zero
        for (dy, wy) in [(0, 1 - fy), (1, fy)] where wy != 0 {
            for (dx, wx) in [(0, 1 - fx), (1, fx)] where wx != 0 {
                acc += at(ix + dx, iy + dy) * (wx * wy)
            }
        }
        if acc.w <= 0 { return .zero }
        return SIMD4(acc.x / acc.w, acc.y / acc.w, acc.z / acc.w, min(acc.w, 1))
    }
}

/// Where a pattern sits: document point → tile coordinates (`compose::pattern::Placement`).
public struct PatternPlacement: Sendable, Hashable {
    public var origin: SIMD2<Double>
    /// Inverse rotation (cos, sin).
    public var cs: SIMD2<Double>
    public var invScale: Double

    /// `frame`: the layer's frame (used when `link`); `phase` in pixels; `scale` a fraction; `angle` degrees CCW.
    public init(frame: PixelRect, link: Bool, phase: SIMD2<Float>, scale: Float, angle: Float) {
        let anchor = frame.isEmpty ? SIMD2<Double>(0, 0) : SIMD2(Double(frame.x0), Double(frame.y0))
        self.init(anchor: anchor, link: link, phase: phase, scale: scale, angle: angle)
    }

    /// Linked patterns tile from `anchor` (layer effects: the effects reference point).
    public init(anchor: SIMD2<Double>, link: Bool, phase: SIMD2<Float>, scale: Float, angle: Float) {
        let base = link ? anchor : SIMD2<Double>(0, 0)
        origin = base + SIMD2(Double(phase.x), Double(phase.y))
        let s = Double(scale)
        invScale = (s.isFinite && s > 1e-3) ? 1 / s : 1
        let a = Double(angle) * .pi / 180
        cs = SIMD2(cos(a), sin(a))
    }

    /// Tile coordinates of document point `(x, y)`.
    @inline(__always) public func map(_ x: Double, _ y: Double) -> (Double, Double) {
        let (dx, dy) = (x - origin.x, y - origin.y)
        let (c, s) = (cs.x, cs.y)
        return ((dx * c - dy * s) * invScale, (dx * s + dy * c) * invScale)
    }
}

import Foundation
