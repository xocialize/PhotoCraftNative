// Port of photocraft-compose (crates/compose/src/native.rs, mode-native CMYK flattening) extended to every layer kind and to Lab, MIT OR Apache-2.0, © ArtCraft Team and the PhotoCraft contributors.
//
// Native compositing of Lab and CMYK documents. Photoshop blends in the document's own colour
// model (measured on the ps-corpus blend bands: CMYK modes are the RGB formulas on ink brightness
// 1 − ink per channel, Lab has its own rules, see `PSBlend.blendLab`); photocraft composites both
// in display RGB except for plain Normal CMYK stacks. Here a Lab document's plan runs on buffers
// holding its stored channels (L/100, (a+128)/255, (b+128)/255) and a CMYK document's as two plans
// over ink brightness, one for C, M, Y and one for K (`NativeSpace`), whose results are merged and
// converted for display only at the end, as Photoshop's own merged image is. Colours (fills,
// effects, artboard backgrounds), patterns and layer pixels are converted into the plan's space
// when the plan is made; adjustments convert themselves (`PreparedAdjustment`, `pcr_adjust`).

import Foundation
import PCDocument
import PCFoundation
import simd

extension LeafID {
    /// The leaf's pixels in a native plan space (`plane` 1 = Lab or CMY ink, 2 = black).
    func native(_ plane: UInt64) -> LeafID { LeafID(raw: raw | plane << 5) }
}

extension NativeSpace {
    /// The plane bit of leaf ids in this space.
    var plane: UInt64 {
        switch self {
        case .none: 0
        case .lab, .cmykInk: 1
        case .cmykBlack: 2
        }
    }

    /// The document mode whose channels this space holds.
    var mode: ColorMode? {
        switch self {
        case .none: nil
        case .lab: .lab
        case .cmykInk, .cmykBlack: .cmyk
        }
    }
}

enum NativeConvert {
    // MARK: Colours

    /// Native channels of a document-mode colour's components (`c` in `space.mode`).
    @inline(__always) static func channels(_ c: SIMD4<Float>, _ space: NativeSpace) -> SIMD3<Float> {
        switch space {
        case .none, .lab: SIMD3(c.x, c.y, c.z)
        case .cmykInk: SIMD3(1 - c.x, 1 - c.y, 1 - c.z)
        case .cmykBlack: SIMD3(repeating: 1 - c.w)
        }
    }

    /// `c` as a plan colour: its native channels carried in an RGB colour.
    static func color(_ c: PCColor, _ space: NativeSpace) -> PCColor {
        guard let m = space.mode else { return c }
        let v = channels(c.converted(to: m).c, space)
        return PCColor.rgb(v.x, v.y, v.z, c.alpha)
    }

    /// Display RGB → native channels.
    static func fromRGB(_ rgb: [SIMD3<Float>], _ space: NativeSpace) -> [SIMD3<Float>] {
        switch space {
        case .none: return rgb
        case .lab: return rgb.map(AdjustMath.labNorm)
        case .cmykInk, .cmykBlack: return ColorConvert.rgbToCMYK(batch: rgb).map { channels($0, space) }
        }
    }

    static func fill(_ f: Fill, _ space: NativeSpace) -> Fill {
        if space == .none { return f }
        switch f {
        case .solid(let c): return .solid(color(c, space))
        case .gradient(var g):
            g.stops = g.stops.map { ColorStop($0.location, color($0.color, space)) }
            return .gradient(g)
        case .pattern: return f
        }
    }

    /// A fill's colours as a Grayscale document holds them: each colour's grey
    /// (`ColorConvert.rgbToGray`, what `Surface` stores when the fill is written), as R = G = B.
    /// Photoshop shows an RGB fill colour in a Grayscale document as that grey (PCIO request).
    static func grayFill(_ f: Fill) -> Fill {
        func g(_ c: PCColor) -> PCColor { let v = ColorConvert.rgbToGray(c.rgb); return .rgb(v, v, v, c.alpha) }
        switch f {
        case .solid(let c): return .solid(g(c))
        case .gradient(var gr):
            gr.stops = gr.stops.map { ColorStop($0.location, g($0.color)) }
            return .gradient(gr)
        case .pattern: return f
        }
    }

    static func gradient(_ g: StyleGradient, _ space: NativeSpace) -> StyleGradient {
        var o = g
        o.stops = g.stops.map { ColorStop($0.location, color($0.color, space)) }
        return o
    }

    static func paint(_ p: FxPaint, _ space: NativeSpace) -> FxPaint {
        switch p {
        case .color(let c): .color(color(c, space))
        case .gradient(let g): .gradient(gradient(g, space))
        case .pattern: p
        }
    }

    /// Every colour of a layer style in the plan's space.
    static func effects(_ fx: Effects, _ space: NativeSpace) -> Effects {
        if space == .none { return fx }
        var o = fx
        o.items = fx.items.map { e in
            switch e {
            case .dropShadow(var s): s.color = color(s.color, space); return .dropShadow(s)
            case .innerShadow(var s): s.color = color(s.color, space); return .innerShadow(s)
            case .outerGlow(var g): g.paint = paint(g.paint, space); return .outerGlow(g)
            case .innerGlow(var g): g.paint = paint(g.paint, space); return .innerGlow(g)
            case .stroke(var s): s.paint = paint(s.paint, space); return .stroke(s)
            case .colorOverlay(var c): c.color = color(c.color, space); return .colorOverlay(c)
            case .gradientOverlay(var g): g.gradient = gradient(g.gradient, space); return .gradientOverlay(g)
            case .patternOverlay: return e
            case .satin(var s): s.color = color(s.color, space); return .satin(s)
            case .bevelEmboss(var b):
                b.highlightColor = color(b.highlightColor, space); b.shadowColor = color(b.shadowColor, space)
                return .bevelEmboss(b)
            }
        }
        return o
    }

    // MARK: Pixels

    /// A surface's pixels as native channels + alpha (a document-mode surface's own channels,
    /// anything else through display RGB).
    static func image(_ s: Surface, _ space: NativeSpace, version: UInt64) -> RenderLeaf {
        let r = ContentBounds.of(s)
        let def = s.defaultPixelValue
        let outsideRGBA = Surface(format: s.format, defaultPixel: def).rgba(x: 0, y: 0)
        let outside: SIMD4<Float>
        if s.format.mode == space.mode {
            let a: Float = s.format.alpha ? (def.last ?? 1) : 1
            outside = SIMD4(channels(SIMD4(def.count > 0 ? def[0] : 0, def.count > 1 ? def[1] : 0, def.count > 2 ? def[2] : 0,
                                           def.count > 3 ? def[3] : 0), space), a)
        } else {
            outside = SIMD4(fromRGB([SIMD3(outsideRGBA.x, outsideRGBA.y, outsideRGBA.z)], space)[0], outsideRGBA.w)
        }
        if r.isEmpty { return .image(FloatImage(rect: .empty, channels: 4), outside: outside, version: version) }
        var img = FloatImage(rect: r, channels: 4)
        if s.format.mode == space.mode {
            let raw = s.readRegion(r), ch = s.channels, cc = s.format.mode.colorChannels
            img.data.withUnsafeMutableBufferPointer { o in
                for i in 0..<r.area {
                    var c = SIMD4<Float>.zero
                    for k in 0..<min(cc, 4) { c[k] = raw[i * ch + k] }
                    let v = channels(c, space)
                    o[i * 4] = v.x; o[i * 4 + 1] = v.y; o[i * 4 + 2] = v.z
                    o[i * 4 + 3] = s.format.alpha ? raw[i * ch + ch - 1] : 1
                }
            }
        } else {
            let px = s.readRGBA(r)
            let v = fromRGB(px.map { SIMD3($0.x, $0.y, $0.z) }, space)
            for i in 0..<r.area {
                img.data[i * 4] = v[i].x; img.data[i * 4 + 1] = v[i].y; img.data[i * 4 + 2] = v[i].z; img.data[i * 4 + 3] = px[i].w
            }
        }
        return .image(img, outside: outside, version: version)
    }

    /// A pattern as painted into the plan's space.
    static func pattern(_ p: Pattern, _ space: NativeSpace, version: UInt64) -> PatternTile? {
        guard p.isPaintable, let m = space.mode else { return nil }
        let rect = p.rect
        var straight: [SIMD4<Float>]
        if p.surface.format.mode == m {
            let raw = p.surface.readRegion(rect), ch = p.surface.channels, cc = m.colorChannels
            straight = (0..<rect.area).map { i in
                var c = SIMD4<Float>.zero
                for k in 0..<min(cc, 4) { c[k] = raw[i * ch + k] }
                return SIMD4(channels(c, space), p.surface.format.alpha ? raw[i * ch + ch - 1] : 1)
            }
        } else {
            let px = p.surface.readRGBA(rect)
            let v = fromRGB(px.map { SIMD3($0.x, $0.y, $0.z) }, space)
            straight = zip(v, px).map { SIMD4($0, $1.w) }
        }
        return PatternTile(id: p.id, name: p.name, width: Int(p.width), height: Int(p.height), straight: straight, version: version ^ space.plane)
    }

    // MARK: Adjustments on CMYK planes

    /// `adj` as it acts on one CMYK plane, or nil when it mixes channels (the document then
    /// composites in display RGB). Levels / Curves map ink brightness per channel (the black
    /// plane takes the K curve), Invert and Posterize act per channel, Brightness / Contrast per
    /// channel on ink brightness.
    static func planeAdjustment(_ adj: Adjustment, _ space: NativeSpace) -> Adjustment? {
        switch adj {
        case .invert, .posterize, .brightnessContrast: return adj
        case .levels(var lv):
            guard lv.space != .lab else { return nil }
            if lv.space == .cmyk && space == .cmykBlack { lv.perChannel = [lv.black, lv.black, lv.black] }
            lv.space = .rgb
            return .levels(lv)
        case .curves(var cv):
            guard cv.space != .lab else { return nil }
            if cv.space == .cmyk && space == .cmykBlack { cv.perChannel = [cv.black, cv.black, cv.black] }
            cv.space = .rgb
            return .curves(cv)
        default: return nil
        }
    }

    /// Whether every visible adjustment layer of `layers` acts per channel on CMYK planes.
    static func planeSafe(_ layers: [Layer]) -> Bool {
        layers.allSatisfy { l in
            if !l.visible { return true }
            if case .adjustment(let a) = l.content, planeAdjustment(a, .cmykInk) == nil { return false }
            return planeSafe(l.children ?? [])
        }
    }

    // MARK: Results

    /// Colour channels rounded to `q` steps per unit (nil: unchanged).
    static func quantized(_ b: RGBABuffer, _ q: Float?) -> RGBABuffer {
        guard let q else { return b }
        var o = b
        for i in o.px.indices {
            let v = o.px[i]
            o.px[i] = SIMD4(((SIMD3(v.x, v.y, v.z) * q + 0.5).rounded(.down)) / q, v.w)
        }
        return o
    }

    /// A Lab plan's buffer as display RGB (as `Surface.readRGBA` reads a Lab surface).
    static func labToRGB(_ b: RGBABuffer) -> RGBABuffer {
        var o = b
        o.px.withUnsafeMutableBufferPointer { p in
            let P = UnsafeSendable(p)
            parallelChunks(p.count, work: p.count * 8) { range in
                for i in range {
                    let q = P.value[i]
                    P.value[i] = SIMD4(AdjustMath.labDenorm(SIMD3(q.x, q.y, q.z)), q.w)
                }
            }
        }
        return o
    }

    /// Ink values (C, M, Y, K) of merged planes; `paper` flattens onto white paper (no ink).
    static func inks(_ ink: RGBABuffer, _ black: RGBABuffer, paper: Bool) -> [SIMD4<Float>] {
        (0..<ink.px.count).map { i in
            let a = ink.px[i], k = black.px[i]
            let c = SIMD4(1 - a.x, 1 - a.y, 1 - a.z, 1 - k.x)
            return paper ? c * min(max(a.w, 0), 1) : c
        }
    }

    /// Merged CMYK planes as display RGB (through the CMYK converter, as `Surface.readRGBA`).
    static func cmykToRGB(_ ink: RGBABuffer, _ black: RGBABuffer, paper: Bool = false) -> RGBABuffer {
        let rgb = ColorConvert.cmykToRGB(batch: inks(ink, black, paper: paper).map { simd_clamp($0, .zero, SIMD4(repeating: 1)) })
        return RGBABuffer(rect: ink.rect, px: (0..<rgb.count).map { SIMD4(rgb[$0], paper ? 1 : ink.px[$0].w) })
    }
}
