// Port of photocraft-paint (crates/paint/src/symmetry.rs), MIT OR Apache-2.0, © ArtCraft Team and the PhotoCraft contributors.
//
// Straight painting symmetry axes. Geometry is independent of pixels and the UI.

import Foundation

public let symmetryMaxCoordinate: Double = 1_000_000

public enum SymmetryMode: String, Codable, Sendable, CaseIterable {
    case vertical, horizontal, dual, diagonal

    public var id: String { rawValue }
    public init?(id: String) { self.init(rawValue: id) }
}

public struct PresetSymmetry: Hashable, Sendable, Codable {
    public let mode: SymmetryMode
    public let center: SIMD2<Double>
    /// Clockwise degrees relative to the mode's initial direction (document y points down).
    public let rotation: Double

    public init?(_ mode: SymmetryMode, center: SIMD2<Double>, rotation: Double) {
        if !rotation.isFinite || !(center.x.isFinite && abs(center.x) <= symmetryMaxCoordinate && center.y.isFinite && abs(center.y) <= symmetryMaxCoordinate) {
            return nil
        }
        self.mode = mode
        self.center = center
        self.rotation = remEuclid(rotation, 360)
    }

    public var directions: [SIMD2<Double>] {
        let initial: Double
        switch mode {
        case .horizontal: initial = 0
        case .diagonal: initial = 45
        default: initial = 90
        }
        let a = toRadians(initial + rotation)
        let first = SIMD2(cos(a), sin(a))
        return mode == .dual ? [first, SIMD2(-first.y, first.x)] : [first]
    }

    public var mirrorCount: Int { mode == .dual ? 3 : 1 }

    /// The mirrored copies of `points` (stylus data kept), one per mirror.
    public func reflectedPasses(_ points: [StrokePoint]) -> [[StrokePoint]] {
        func reflect(_ p: StrokePoint, _ d: SIMD2<Double>) -> StrokePoint {
            let dx = p.x - center.x, dy = p.y - center.y
            let along = dx * d.x + dy * d.y
            var q = p
            q.x = center.x + 2 * along * d.x - dx
            q.y = center.y + 2 * along * d.y - dy
            return q
        }
        var copies = directions.map { d in points.map { reflect($0, d) } }
        if mode == .dual {
            copies.append(points.map { p in
                var q = p
                q.x = 2 * center.x - p.x
                q.y = 2 * center.y - p.y
                return q
            })
        }
        return copies
    }

    /// Clip infinite axes to document bounds without assuming that their centre is inside.
    public func segments(_ size: SIMD2<Double>) -> [(SIMD2<Double>, SIMD2<Double>)] {
        directions.compactMap { d in
            var lo = -Double.infinity, hi = Double.infinity
            for k in 0..<2 {
                let origin = center[k], direction = d[k], extent = size[k]
                if abs(direction) < 1e-12 {
                    if origin < 0 || origin > extent { return nil }
                } else {
                    let a = -origin / direction, b = (extent - origin) / direction
                    lo = maxR(lo, minR(a, b))
                    hi = minR(hi, maxR(a, b))
                }
            }
            if !lo.isFinite || !hi.isFinite || hi < lo { return nil }
            return (center + lo * d, center + hi * d)
        }
    }
}
