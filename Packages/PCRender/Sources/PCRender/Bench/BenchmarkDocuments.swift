// Benchmark and parity documents for PCRender (new; photocraft's `perf/` scenes are not ported). The layer semantics they exercise are photocraft-compose's (crates/compose/src/lib.rs), MIT OR Apache-2.0, © ArtCraft Team and the PhotoCraft contributors.
//
// Procedural documents at any size: `effects4` (phase 1: four layers with heavy effects) and
// `realistic20` (phase 2: twenty layers mixing every layer kind a photo composite uses — pixel
// layers with masks and blend modes, adjustment layers inside and outside groups, clipping groups,
// fill layers, a type layer, an isolated group with opacity, Blend If and effects). Content is
// generated band by band in parallel, so a 4096² document builds in well under a second per layer.

import Foundation
import PCDocument
import PCFoundation

public enum BenchmarkDocuments {
    /// An RGBA8 surface over `rect` with straight RGBA from `f(x, y)` (u, v in 0…1 of `size`).
    static func procedural(_ rect: PixelRect, size: Int, _ f: @escaping @Sendable (Float, Float, Int32, Int32) -> SIMD4<Float>) -> Surface {
        var s = Surface(format: PixelFormat(mode: .rgb, sample: .u8, alpha: true))
        if rect.isEmpty { return s }
        let inv = 1 / Float(max(size, 1))
        var y = rect.y0
        while y < rect.y1 {
            let band = PixelRect(x0: rect.x0, y0: y, x1: rect.x1, y1: min(y + 256, rect.y1))
            let w = band.width
            var bytes = [UInt8](repeating: 0, count: band.area * 4)
            bytes.withUnsafeMutableBufferPointer { bp in
                let B = UnsafeSendable(bp)
                DispatchQueue.concurrentPerform(iterations: band.height) { j in
                    let py = band.y0 + Int32(j)
                    for i in 0..<w {
                        let px = band.x0 + Int32(i)
                        let c = f((Float(px) + 0.5) * inv, (Float(py) + 0.5) * inv, px, py)
                        let o = (j * w + i) * 4
                        for k in 0..<4 { B.value[o + k] = UInt8(min(max(c[k], 0), 1) * 255 + 0.5) }
                    }
                }
            }
            s.writeInterleaved(band, bytes)
            y = band.y1
        }
        s.prune()
        return s
    }

    /// A grayscale mask over `rect` (`f` gives 0…1), default `outside`.
    static func mask(_ rect: PixelRect, size: Int, outside: Float, _ f: @escaping @Sendable (Float, Float) -> Float) -> Surface {
        let rgba = procedural(rect, size: size) { u, v, _, _ in SIMD4(repeating: f(u, v)) }
        var m = Surface(format: PixelFormat(mode: .grayscale, sample: .u8, alpha: false), defaultPixel: [outside])
        if rect.isEmpty { return m }
        let raw = rgba.readRegion(rect)
        m.writeRegion(rect, stride(from: 0, to: raw.count, by: 4).map { raw[$0] })
        return m
    }

    @inline(__always) static func hash(_ x: Int32, _ y: Int32) -> Float {
        var h = UInt32(bitPattern: x) &* 0x8da6_b343 ^ UInt32(bitPattern: y) &* 0xd816_3841 ^ 0x9e37_79b9
        h ^= h >> 15; h = h &* 0x2c1b_3c6d; h ^= h >> 12
        return Float(h & 0xffff) / 65536
    }

    @inline(__always) static func smooth(_ e0: Float, _ e1: Float, _ x: Float) -> Float {
        let t = min(max((x - e0) / (e1 - e0), 0), 1)
        return t * t * (3 - 2 * t)
    }

    /// An ellipse's coverage (soft edge of `soft` in uv units).
    @inline(__always) static func ellipse(_ u: Float, _ v: Float, _ cx: Float, _ cy: Float, _ rx: Float, _ ry: Float, soft: Float) -> Float {
        let du = (u - cx) / rx, dv = (v - cy) / ry
        let d = (du * du + dv * dv).squareRoot()
        return 1 - smooth(1 - soft, 1 + soft, d)
    }

    /// A rounded rectangle's coverage.
    @inline(__always) static func roundRect(_ u: Float, _ v: Float, _ x0: Float, _ y0: Float, _ x1: Float, _ y1: Float, r: Float, soft: Float) -> Float {
        let cx = (x0 + x1) / 2, cy = (y0 + y1) / 2, hx = (x1 - x0) / 2 - r, hy = (y1 - y0) / 2 - r
        let qx = max(abs(u - cx) - hx, 0), qy = max(abs(v - cy) - hy, 0)
        let d = (qx * qx + qy * qy).squareRoot() - r
        return 1 - smooth(-soft, soft, d)
    }

    static func rect(_ size: Int, _ x0: Float, _ y0: Float, _ x1: Float, _ y1: Float) -> PixelRect {
        let s = Float(size)
        return PixelRect(x0: Int32(x0 * s), y0: Int32(y0 * s), x1: Int32((x1 * s).rounded(.up)), y1: Int32((y1 * s).rounded(.up)))
    }

    static func background(_ size: Int) -> Layer {
        var l = Layer.raster("Background", surface: procedural(PixelRect(x: 0, y: 0, width: size, height: size), size: size) { u, v, x, y in
            let n = hash(x, y) * 0.06 - 0.03
            return SIMD4(0.25 + 0.5 * u + n, 0.35 + 0.3 * v + n, 0.55 - 0.3 * u * v + n, 1)
        })
        l.locks.transparency = true
        l.locks.position = true
        return l
    }

    /// Phase 1: four layers with effects (drop shadow + stroke, outer glow + inner shadow in
    /// Multiply, inner bevel + colour overlay in Screen) over a full-canvas Background.
    public static func effects4(size: Int = 4096) -> Document {
        var d = Document(name: "effects4", size: PixelSize(width: size, height: size), mode: .rgb, depth: .u8)
        let s = Float(size)
        var a = Layer.raster("ellipse", surface: procedural(rect(size, 0.08, 0.1, 0.62, 0.6), size: size) { u, v, x, y in
            SIMD4(0.9, 0.35 + 0.2 * hash(x, y), 0.2, ellipse(u, v, 0.35, 0.35, 0.25, 0.22, soft: 0.004))
        })
        a.effects.items = [.dropShadow(Shadow(common: FxCommon(.multiply, 0.75), color: .black, angle: 120, useGlobalLight: false, distance: s * 0.006,
                                              spread: 0.1, size: s * 0.008)),
                           .stroke(StrokeFx(common: FxCommon(.normal, 1), size: s * 0.002, position: .outside, paint: .color(.rgb(1, 1, 1))))]
        var b = Layer.raster("panel", surface: procedural(rect(size, 0.4, 0.45, 0.92, 0.9), size: size) { u, v, _, _ in
            SIMD4(0.2 + 0.6 * u, 0.7, 0.5 + 0.3 * v, roundRect(u, v, 0.42, 0.47, 0.9, 0.88, r: 0.05, soft: 0.002))
        })
        b.blend = .multiply
        b.effects.items = [.outerGlow(Glow(common: FxCommon(.screen, 0.8), paint: .color(.rgb(1, 0.9, 0.4)), technique: .softer, spread: 0.1, size: s * 0.01)),
                           .innerShadow(Shadow(common: FxCommon(.multiply, 0.6), distance: s * 0.004, size: s * 0.006))]
        var c = Layer.raster("badge", surface: procedural(rect(size, 0.1, 0.62, 0.38, 0.92), size: size) { u, v, x, y in
            SIMD4(0.3, 0.4 + 0.3 * hash(x &+ 7, y), 0.9, roundRect(u, v, 0.12, 0.64, 0.36, 0.9, r: 0.03, soft: 0.002))
        })
        c.effects.items = [.bevelEmboss(Bevel(style: .innerBevel, technique: .smooth, depth: 1.5, size: s * 0.005, soften: 2)),
                           .colorOverlay(.init(common: FxCommon(.screen, 0.3), color: .rgb(1, 0.6, 0.2)))]
        d.layers = [background(size), a, b, c]
        return d
    }

    /// Phase 2: a 20-layer photo composite (see the file header). No rasterizer is needed: the type
    /// layer carries a cached raster, masks are pixel masks.
    public static func realistic20(size: Int = 4096) -> Document {
        var d = Document(name: "realistic20", size: PixelSize(width: size, height: size), mode: .rgb, depth: .u8)
        let s = Float(size)
        let full = PixelRect(x: 0, y: 0, width: size, height: size)
        var layers: [Layer] = [background(size)]

        // 2. Sky: the top 45 %, fading out.
        layers.append(Layer.raster("sky", surface: procedural(rect(size, 0, 0, 1, 0.45), size: size) { u, v, _, _ in
            SIMD4(0.45 + 0.2 * u, 0.65, 0.95, 1 - smooth(0.3, 0.45, v))
        }))
        // 3. Texture in Overlay at 35 %.
        var tex = Layer.raster("texture", surface: procedural(full, size: size) { _, _, x, y in
            let n = hash(x / 3, y / 3)
            return SIMD4(repeating: 0.35 + 0.3 * n)
        })
        tex.blend = .overlay; tex.opacity = 0.35
        layers.append(tex)
        // 4. Curves (S-curve).
        let sCurve = [CurvePoint(input: 0, output: 0), CurvePoint(input: 0.25, output: 0.2), CurvePoint(input: 0.75, output: 0.82), CurvePoint(input: 1, output: 1)]
        layers.append(Layer(name: "curves", content: .adjustment(.curves(.init(master: sCurve, perChannel: [[], [], []], space: .rgb, black: [], pencil: false)))))

        // 5–8. Pass-through group: subject with a feathered mask and a drop shadow, a rim light
        // and a Hue/Saturation clipped to it.
        var subject = Layer.raster("subject", surface: procedural(rect(size, 0.2, 0.25, 0.75, 0.95), size: size) { u, v, x, y in
            SIMD4(0.75 + 0.1 * hash(x, y), 0.55, 0.45, ellipse(u, v, 0.47, 0.6, 0.25, 0.33, soft: 0.003))
        })
        var sm = LayerMask(surface: mask(rect(size, 0.2, 0.25, 0.75, 0.95), size: size, outside: 1) { _, v in 1 - smooth(0.8, 0.95, v) })
        sm.feather = s * 0.002
        subject.mask = sm
        subject.effects.items = [.dropShadow(Shadow(common: FxCommon(.multiply, 0.6), angle: 135, useGlobalLight: false, distance: s * 0.006, size: s * 0.008))]
        var rim = Layer.raster("rim light", surface: procedural(rect(size, 0.2, 0.25, 0.75, 0.95), size: size) { u, v, _, _ in
            let r = ((u - 0.3) * (u - 0.3) + (v - 0.35) * (v - 0.35)).squareRoot()
            return SIMD4(1, 0.95, 0.85, max(0, 1 - r / 0.35))
        })
        rim.clipped = true; rim.blend = .screen; rim.opacity = 0.6
        var hs = Layer(name: "hue/sat", content: .adjustment(.hueSaturation(.init(hue: 8, saturation: 15, lightness: 0, colorize: false, ranges: HueRange.defaults))))
        hs.clipped = true
        layers.append(Layer.group("subject group", [subject, rim, hs]))

        // 9. Levels with a painted mask.
        var levels = Layer(name: "levels", content: .adjustment(.levels(.init(master: LevelsChannel(inBlack: 0.05, inWhite: 0.92, gamma: 1.1)))))
        levels.mask = LayerMask(surface: mask(rect(size, 0, 0.5, 1, 1), size: size, outside: 0) { u, _ in smooth(0.1, 0.6, u) })
        layers.append(levels)

        // 10–12. Isolated group at 85 %: a badge with a stroke and an outer glow, and a type layer
        // with a drop shadow.
        var badge = Layer.raster("badge", surface: procedural(rect(size, 0.62, 0.08, 0.95, 0.3), size: size) { u, v, _, _ in
            SIMD4(0.95, 0.75, 0.2, roundRect(u, v, 0.64, 0.1, 0.93, 0.28, r: 0.03, soft: 0.002))
        })
        badge.effects.items = [.stroke(StrokeFx(common: FxCommon(.normal, 1), size: s * 0.0015, position: .outside, paint: .color(.rgb(0.2, 0.1, 0.05)))),
                               .outerGlow(Glow(common: FxCommon(.screen, 0.7), paint: .color(.rgb(1, 1, 0.8)), size: s * 0.006))]
        var text = TextLayer(text: "PHOTOCRAFT", fontFamily: "Helvetica", sizePt: 96, color: .white)
        text.cache = procedural(rect(size, 0.08, 0.05, 0.6, 0.18), size: size) { u, v, x, y in
            // Blocky glyph-like strokes.
            let gx = Int((u - 0.08) / 0.052), gy = (v - 0.07) / 0.09
            let inGlyph = gy > 0 && gy < 1 && ((u - 0.08).truncatingRemainder(dividingBy: 0.052) < 0.04)
            let bar = Int(gy * 5) % 2 == 0 || (gx % 3 == 0)
            return SIMD4(1, 1, 1, inGlyph && bar ? 1 : 0)
        }
        var textLayer = Layer(name: "title", content: .text(text))
        textLayer.effects.items = [.dropShadow(Shadow(common: FxCommon(.multiply, 0.7), distance: s * 0.002, size: s * 0.003))]
        var decor = Layer.group("decor", [badge, textLayer])
        decor.blend = .normal; decor.opacity = 0.85
        layers.append(decor)

        // 13. Gradient fill in Soft Light over the bottom third (pixel mask).
        var grad = Layer(name: "gradient", content: .fill(.gradient(GradientFill(
            stops: [ColorStop(0, .rgb(0.1, 0.05, 0.3)), ColorStop(1, .rgb(1, 0.6, 0.2))], angle: 90, scale: 1, style: .linear, reverse: false,
            opacityStops: [OpacityStop(0, 1), OpacityStop(1, 0.3)]))))
        grad.blend = .softLight
        grad.mask = LayerMask(surface: mask(rect(size, 0, 0.6, 1, 1), size: size, outside: 0) { _, v in smooth(0.6, 0.75, v) })
        layers.append(grad)
        // 14. Warm tint: solid fill in Multiply at 20 %.
        var tint = Layer(name: "tint", content: .fill(.solid(.rgb(1, 0.85, 0.6))))
        tint.blend = .multiply; tint.opacity = 0.2
        layers.append(tint)
        // 15. Particles in Screen, hidden over the darks (Blend If › Underlying).
        var particles = Layer.raster("particles", surface: procedural(full, size: size) { _, _, x, y in
            let cell: Int32 = 48
            let cx = x / cell, cy = y / cell
            let jx = Float(cx * cell) + hash(cx, cy) * Float(cell), jy = Float(cy * cell) + hash(cy, cx &+ 3) * Float(cell)
            let r = ((Float(x) - jx) * (Float(x) - jx) + (Float(y) - jy) * (Float(y) - jy)).squareRoot()
            return SIMD4(1, 0.95, 0.8, max(0, 1 - r / 6) * (hash(cx, cy &+ 11) > 0.6 ? 1 : 0))
        })
        particles.blend = .screen
        particles.blendIf.set(0, BlendRangePair(.full, BlendRange(black: SIMD2(40, 90), white: SIMD2(255, 255))))
        layers.append(particles)
        // 16. Logo with a bevel and a drop shadow.
        var logo = Layer.raster("logo", surface: procedural(rect(size, 0.78, 0.78, 0.96, 0.96), size: size) { u, v, _, _ in
            SIMD4(0.85, 0.2, 0.25, ellipse(u, v, 0.87, 0.87, 0.07, 0.07, soft: 0.004))
        })
        logo.effects.items = [.bevelEmboss(Bevel(style: .innerBevel, technique: .smooth, depth: 1.2, size: s * 0.004, soften: 1)),
                              .dropShadow(Shadow(common: FxCommon(.multiply, 0.6), distance: s * 0.002, size: s * 0.004))]
        layers.append(logo)
        // 17–19. Global adjustments.
        layers.append(Layer(name: "brightness/contrast", content: .adjustment(.brightnessContrast(.init(brightness: 8, contrast: 12, legacy: false)))))
        layers.append(Layer(name: "color balance", content: .adjustment(.colorBalance(.init(shadows: SIMD3(-5, 0, 8), midtones: SIMD3(6, 0, -4),
                                                                                         highlights: SIMD3(0, 0, 0), preserveLuminosity: true)))))
        var vib = Layer(name: "vibrance", content: .adjustment(.vibrance(.init(vibrance: 25, saturation: 0))))
        vib.opacity = 0.7
        layers.append(vib)
        // 20. Vignette in Multiply.
        var vignette = Layer.raster("vignette", surface: procedural(full, size: size) { u, v, _, _ in
            let r = ((u - 0.5) * (u - 0.5) + (v - 0.5) * (v - 0.5)).squareRoot()
            return SIMD4(0.1, 0.08, 0.12, smooth(0.45, 0.75, r) * 0.8)
        })
        vignette.blend = .multiply
        layers.append(vignette)
        d.layers = layers
        return d
    }

    /// Layers in a document, groups' children included.
    public static func layerCount(_ d: Document) -> Int {
        func count(_ ls: [Layer]) -> Int { ls.reduce(0) { $0 + 1 + count($1.children ?? []) } }
        return count(d.layers)
    }
}
