// Geometry: integer pixel rectangles, tile coordinates and sizes.
// Port of photocraft-geom (crates/geom/src/lib.rs), MIT OR Apache-2.0, © ArtCraft Team and the
// PhotoCraft contributors. Affine/perspective maths use CoreGraphics and simd natively.

import CoreGraphics

/// Edge length of one surface tile, in pixels.
public let tileSize: Int32 = 256

/// A document size in pixels.
public struct PixelSize: Hashable, Sendable, Codable {
    public var width: Int
    public var height: Int
    public init(width: Int, height: Int) { self.width = width; self.height = height }
    public var rect: PixelRect { PixelRect(x0: 0, y0: 0, x1: Int32(clamping: width), y1: Int32(clamping: height)) }
}

/// A half-open integer rectangle `[x0, x1) × [y0, y1)` in document pixels (photocraft `Rect`).
/// 32-bit coordinates cover PSB's 300 000 px limit.
public struct PixelRect: Hashable, Sendable, Codable, CustomStringConvertible {
    public var x0: Int32
    public var y0: Int32
    public var x1: Int32
    public var y1: Int32

    public static let empty = PixelRect(x0: 0, y0: 0, x1: 0, y1: 0)

    public init(x0: Int32, y0: Int32, x1: Int32, y1: Int32) {
        self.x0 = x0; self.y0 = y0; self.x1 = x1; self.y1 = y1
    }

    /// Coordinates saturate at the Int32 range, as photocraft's `Rect` arithmetic does.
    public init(x: Int, y: Int, width: Int, height: Int) {
        self.init(x0: Int32(clamping: x), y0: Int32(clamping: y),
                  x1: Int32(clamping: x.addingReportingOverflow(width).overflow ? Int.max : x + width),
                  y1: Int32(clamping: y.addingReportingOverflow(height).overflow ? Int.max : y + height))
    }

    public var width: Int { max(0, Int(x1) - Int(x0)) }
    public var height: Int { max(0, Int(y1) - Int(y0)) }
    public var area: Int { width * height }
    public var isEmpty: Bool { x1 <= x0 || y1 <= y0 }
    public var cgRect: CGRect { CGRect(x: Int(x0), y: Int(y0), width: width, height: height) }
    public var description: String { "(\(x0),\(y0))–(\(x1),\(y1)) \(width)×\(height)" }

    public func intersect(_ o: PixelRect) -> PixelRect {
        let r = PixelRect(x0: max(x0, o.x0), y0: max(y0, o.y0), x1: min(x1, o.x1), y1: min(y1, o.y1))
        return r.isEmpty ? .empty : r
    }

    public func union(_ o: PixelRect) -> PixelRect {
        if isEmpty { return o }
        if o.isEmpty { return self }
        return PixelRect(x0: min(x0, o.x0), y0: min(y0, o.y0), x1: max(x1, o.x1), y1: max(y1, o.y1))
    }

    public func inset(by d: Int32) -> PixelRect {
        PixelRect(x0: PixelRect.sat(Int(x0) + Int(d)), y0: PixelRect.sat(Int(y0) + Int(d)),
                  x1: PixelRect.sat(Int(x1) - Int(d)), y1: PixelRect.sat(Int(y1) - Int(d)))
    }

    /// Grown by `d` on every side (a filter's halo).
    public func outset(by d: Int32) -> PixelRect { inset(by: -d) }

    /// Moved by (dx, dy), saturating at the Int32 range.
    public func offsetBy(dx: Int32, dy: Int32) -> PixelRect {
        PixelRect(x0: PixelRect.sat(Int(x0) + Int(dx)), y0: PixelRect.sat(Int(y0) + Int(dy)),
                  x1: PixelRect.sat(Int(x1) + Int(dx)), y1: PixelRect.sat(Int(y1) + Int(dy)))
    }

    @inlinable static func sat(_ v: Int) -> Int32 { Int32(clamping: v) }

    public func contains(x: Int32, y: Int32) -> Bool { x >= x0 && x < x1 && y >= y0 && y < y1 }

    public func contains(_ o: PixelRect) -> Bool {
        o.isEmpty || (o.x0 >= x0 && o.y0 >= y0 && o.x1 <= x1 && o.y1 <= y1)
    }

    /// Every tile this rectangle touches, row-major.
    public var tiles: [TileCoord] {
        if isEmpty { return [] }
        let tx0 = TileCoord.floorDiv(x0, tileSize), ty0 = TileCoord.floorDiv(y0, tileSize)
        let tx1 = TileCoord.floorDiv(x1 - 1, tileSize), ty1 = TileCoord.floorDiv(y1 - 1, tileSize)
        var out: [TileCoord] = []
        out.reserveCapacity(Int(tx1 - tx0 + 1) * Int(ty1 - ty0 + 1))
        for ty in ty0...ty1 { for tx in tx0...tx1 { out.append(TileCoord(tx: tx, ty: ty)) } }
        return out
    }
}

/// The coordinate of one 256×256 tile.
public struct TileCoord: Hashable, Sendable, Codable, Comparable {
    public var tx: Int32
    public var ty: Int32
    public init(tx: Int32, ty: Int32) { self.tx = tx; self.ty = ty }

    /// The tile containing document pixel `(x, y)`.
    public init(containing x: Int32, _ y: Int32) {
        self.init(tx: TileCoord.floorDiv(x, tileSize), ty: TileCoord.floorDiv(y, tileSize))
    }

    /// The tile's pixels, saturating at the Int32 range like photocraft's `Rect::from_xywh`: the
    /// last tile column and row before `Int32.max` (pixels from 2 147 483 392) end at `Int32.max`
    /// instead of overflowing.
    public var rect: PixelRect {
        let x0 = Int(tx) * Int(tileSize), y0 = Int(ty) * Int(tileSize)
        return PixelRect(x0: Int32(clamping: x0), y0: Int32(clamping: y0),
                         x1: Int32(clamping: x0 + Int(tileSize)), y1: Int32(clamping: y0 + Int(tileSize)))
    }

    public static func < (a: TileCoord, b: TileCoord) -> Bool { (a.ty, a.tx) < (b.ty, b.tx) }

    @inlinable static func floorDiv(_ a: Int32, _ b: Int32) -> Int32 {
        let q = a / b
        return (a % b != 0 && (a < 0) != (b < 0)) ? q - 1 : q
    }
}
