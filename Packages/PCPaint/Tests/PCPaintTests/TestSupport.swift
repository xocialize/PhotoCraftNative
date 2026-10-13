// Port of photocraft-paint (crates/paint/src/brush_tests.rs), MIT OR Apache-2.0, © ArtCraft Team and the PhotoCraft contributors.
//
// Shared helpers for the ported test suites.

import PCFoundation
@testable import PCPaint

func brush() -> BrushSettings {
    var b = BrushSettings()
    b.pressureSize = false
    b.spacing = 0.25
    return b
}

/// `base` with fields set (Rust's struct update syntax).
func with(_ base: BrushSettings, _ f: (inout BrushSettings) -> Void) -> BrushSettings {
    var b = base
    f(&b)
    return b
}

func line(_ x0: Double, _ x1: Double, _ y: Double) -> [StrokePoint] {
    [StrokePoint(x0, y, 1), StrokePoint(x1, y, 1)]
}

func dabsOf(_ b: BrushSettings, _ pts: [StrokePoint]) -> [Dab] { dabs(Stroke(brush: b, points: pts)) }

func raster(_ b: BrushSettings, _ d: Dab) -> (PixelRect, [Float]) {
    let ctx = BrushContext(b)
    let r = ctx.dabRect(d, dual: false)
    var v: [Float] = []
    ctx.rasterize(d, dual: false, rect: r, &v)
    return (r, v)
}

func at(_ r: (PixelRect, [Float]), _ x: Int32, _ y: Int32) -> Float {
    r.1[Int((y - r.0.y0) * Int32(r.0.width) + (x - r.0.x0))]
}

func paint(_ b: BrushSettings, _ pts: [StrokePoint]) -> Surface {
    var s = Surface(format: .rgba32f)
    renderStroke(&s, b, pts)
    return s
}

func alphaSum(_ s: Surface, _ r: PixelRect) -> Float {
    var t: Float = 0
    for y in r.y0..<r.y1 { for x in r.x0..<r.x1 { t += s.rgba(x, y).w } }
    return t
}

func pen(_ x: Double, _ y: Double, _ tiltX: Float, _ tiltY: Float, _ rotation: Float) -> StrokePoint {
    StrokePoint(x: x, y: y, pressure: 1, tiltX: tiltX, tiltY: tiltY, rotation: rotation)
}

extension PixelFormat {
    static func make(_ mode: ColorMode, _ sample: SampleType, _ alpha: Bool) -> PixelFormat {
        PixelFormat(mode: mode, sample: sample, alpha: alpha)
    }
}

func bitsEqual(_ a: [Float], _ b: [Float]) -> Bool {
    a.count == b.count && zip(a, b).allSatisfy { $0.bitPattern == $1.bitPattern }
}
