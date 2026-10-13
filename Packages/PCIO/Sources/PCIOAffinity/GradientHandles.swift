// Port of photocraft-compose (crates/compose/src/gradient_fill.rs: `from_handles`, `handles`,
// `unit_reach`, `frame_dims`, `centre`; crates/compose/src/effects.rs: `gradient_units`),
// MIT OR Apache-2.0, © ArtCraft Team and the PhotoCraft contributors.
//
// Pure geometry: where a gradient fill's start and end points sit in its frame. photocraft-io's
// Affinity import calls `from_handles` (compose is not a dependency of this target).

import Foundation
import PCDocument
import PCFoundation

enum GradientHandles {
    /// Shortest gradient drag (pixels).
    static let minLen: Float = 0.5

    /// Rust's `f32::to_degrees` / `to_radians` constants.
    static let degreesPerRadian: Float = 57.2957795130823208767981548141051703
    static let radiansPerDegree: Float = Float.pi / 180

    /// Angle (degrees), scale and centre offset that put a gradient's start and end points at
    /// `from` and `to` in `frame` (inverse of `handles`). A zero-length drag keeps the direction
    /// of `fallbackAngle`.
    static func fromHandles(_ style: GradientStyle, _ from: SIMD2<Float>, _ to: SIMD2<Float>, _ frame: PixelRect,
                            _ fallbackAngle: Float) -> (angle: Float, scale: Float, offset: SIMD2<Float>) {
        let (dx, dy) = (to.x - from.x, to.y - from.y)
        var len = hypotf(dx, dy)
        let angle = len > 1e-4 ? atan2f(-dy, dx) * degreesPerRadian : fallbackAngle
        len = Float.maximum(len, minLen)
        let c = style == .linear ? SIMD2((from.x + to.x) / 2, (from.y + to.y) / 2) : from
        let (w, h) = frameDims(frame)
        let offset = SIMD2((c.x - Float(frame.x0) - w / 2) / w, (c.y - Float(frame.y0) - h / 2) / h)
        let scale = len / unitReach(style, angle, frame)
        return (angle, scale, offset)
    }

    /// The start and end points (document pixels) of a gradient laid out in `frame`.
    static func handles(_ style: GradientStyle, _ angle: Float, _ scale: Float, _ offset: SIMD2<Float>,
                        _ frame: PixelRect) -> (SIMD2<Float>, SIMD2<Float>) {
        let c = centre(offset, frame)
        let r = angle * radiansPerDegree
        let dir = SIMD2(cosf(r), -sinf(r))
        let reach = unitReach(style, angle, frame) * Float.maximum(scale, 1e-3)
        switch style {
        case .linear:
            let h = reach / 2
            return (c - dir * h, c + dir * h)
        default:
            return (c, c + dir * reach)
        }
    }

    static func frameDims(_ frame: PixelRect) -> (Float, Float) {
        (Float(max(frame.width, 1)), Float(max(frame.height, 1)))
    }

    /// The centre a gradient is laid out around: the frame's centre moved by `offset`.
    static func centre(_ offset: SIMD2<Float>, _ frame: PixelRect) -> SIMD2<Float> {
        let (w, h) = frameDims(frame)
        return SIMD2(Float(frame.x0) + w / 2 + offset.x * w, Float(frame.y0) + h / 2 + offset.y * h)
    }

    /// The gradient's reach from its centre at scale 1: the full chord for Linear, half the chord
    /// for Reflected, the radius for the others.
    static func unitReach(_ style: GradientStyle, _ angle: Float, _ frame: PixelRect) -> Float {
        let (w, h) = frameDims(frame)
        let (chord, len) = gradientUnits(angle, w, h)
        switch style {
        case .linear: return chord
        case .reflected: return chord / 2
        case .radial, .angle, .diamond: return len / 2
        }
    }

    /// Gradient length and chord of a `w`×`h` box along `angle` (photocraft compose
    /// `effects::gradient_units`): the length is the box's extent along the angle as an ellipse
    /// norm (fitted on Photoshop's renderings); Linear and Reflected span the chord through the
    /// centre, `min(w / |cos|, h / |sin|)`.
    static func gradientUnits(_ angle: Float, _ w: Float, _ h: Float) -> (chord: Float, len: Float) {
        let r = angle * radiansPerDegree
        let (s, c) = (sinf(r), cosf(r))
        let len = Float.maximum(((c * w) * (c * w) + (s * h) * (s * h)).squareRoot(), 1)
        let chord = Float.maximum(Float.minimum(w / Float.maximum(abs(c), 1e-6), h / Float.maximum(abs(s), 1e-6)), 1)
        return (chord, len)
    }
}
