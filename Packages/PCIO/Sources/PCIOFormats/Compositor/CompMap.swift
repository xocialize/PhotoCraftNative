// `.comp` layer features → PCDocument: blend modes, the 12 adjustment kinds (Grain, Add Noise and
// the blurs as filter adjustment layers, AB-T-0258), the 6 layer effects, and the text and shape
// metadata Compositor keeps beside a layer's PNG.
// Written from Compositor's Document/LayerAppearance.swift, LayerAdjustment.swift,
// ImageAdjustments.swift, Levels.swift, Curves.swift, HueSaturation.swift, LayerEffects.swift,
// TypeTool.swift and ShapeTool.swift; Compositor is MIT, © 2026 Wonder Assembly LLC.

import CoreGraphics
import CoreText
import Foundation
import PCDocument
import PCFoundation

enum CompMap {
    // MARK: Blend modes

    /// Compositor's 24 modes carry Photoshop's names, which are PCFoundation's labels.
    static func blendMode(_ name: String?) -> BlendMode? {
        guard let name else { return .normal }
        return BlendMode.layerModes.first { $0.label == name }
    }

    // MARK: Adjustments

    /// The PCDocument adjustment for `a`, or nil for a kind this version doesn't know. Grain, Add
    /// Noise, Gaussian Blur and Motion Blur, which Photoshop has no adjustment layer for, are filter
    /// adjustment layers with Compositor's settings and seeds.
    static func adjustment(_ a: CompAdjustment, layer: String, warn: (String) -> Void) -> Adjustment? {
        guard let kind = a.kind else { return nil }
        switch kind {
        case .hsv:
            return .hueSaturation(hueSaturation(a.resolvedHSV, layer: layer, warn: warn))
        case .levels:
            func ch(_ r: CompLevelRange) -> LevelsChannel {
                let n = r.normalized
                return LevelsChannel(inBlack: Float(n.black / 255), inWhite: Float(n.white / 255), gamma: Float(n.gamma),
                                     outBlack: Float(n.outputBlack / 255), outWhite: Float(n.outputWhite / 255))
            }
            let r = a.levels.count == 4 ? a.levels : Array(repeating: CompLevelRange(), count: 4)
            return .levels(.init(master: ch(r[0]), perChannel: [ch(r[1]), ch(r[2]), ch(r[3])]))
        case .curves:
            // Compositor's curves are monotone cubic Hermite through the handles, which no Photoshop
            // spline reproduces: each channel goes in as the 256-level map it evaluates to (Curves'
            // pencil form), channel first and composite after, as both apply them.
            let c = a.curves.count == 4 ? a.curves : Array(repeating: CompCurvePoint.line, count: 4)
            if c.contains(where: { $0.count > 2 }) {
                warn("Curves layer \"\(layer)\": imported as drawn (pencil) curves, the levels Compositor's smooth curves evaluate to; the handles are not kept")
            }
            let maps = c.map { pts in curveMap((0 ... 255).map { Float(hermite(pts, Double($0)) / 255) }) }
            return .curves(.init(master: maps[0], perChannel: [maps[1], maps[2], maps[3]], pencil: true))
        case .exposure:
            let e = a.exposure
            return .exposure(.init(exposure: Float(e?.exposure ?? 0), offset: Float(e?.offset ?? 0), gamma: Float(e?.gamma ?? 1)))
        case .gradientMap:
            let g = a.gradientMap
            let dark = g?.shadows ?? CompColor(red: 0, green: 0, blue: 0), light = g?.highlights ?? CompColor(red: 1, green: 1, blue: 1)
            warn("Gradient Map layer \"\(layer)\": brightness is read with Photoshop's weights (0.30 R + 0.59 G + 0.11 B); Compositor used Rec. 709's (0.2126, 0.7152, 0.0722)")
            return .gradientMap(.init(stops: [GradientMapStop(0, rgb(dark)), GradientMapStop(1, rgb(light))], reverse: g?.reversed ?? false))
        case .invert:
            return .invert
        case .blackWhite:
            let bw = a.blackWhite
            let weights = (bw?.weights ?? [40, 60, 40, 60, 20, 80]).map { Float($0) }
            var tint: SIMD3<Float>?
            if let bw, bw.tint, bw.tintSaturation > 0 {
                // Compositor colours the gray as the lightness of an HSL colour at the tint's hue and
                // saturation; Photoshop's tint is a colour whose luminosity is set to the gray.
                tint = hsl(bw.tintHue, bw.tintSaturation / 100, 0.5)
            }
            return .blackWhite(.init(weights: weights, tint: tint))
        case .colorBalance:
            guard let cb = a.colorBalance else { return .colorBalance(.init()) }
            func v(_ x: [Double]) -> SIMD3<Float> { SIMD3(Float(x[0]), Float(x[1]), Float(x[2])) }
            return .colorBalance(.init(shadows: v(cb.shadows), midtones: v(cb.midtones), highlights: v(cb.highlights),
                                       preserveLuminosity: cb.preserveLuminosity))
        case .grain:
            let g = a.grain
            return .filter(.grain(.init(amount: Float(g?.amount ?? 25), size: Float(g?.size ?? 1.5), roughness: Float(g?.roughness ?? 50),
                                        seed: g?.seed ?? 0)))
        case .addNoise:
            return .filter(.addNoise(.init(amount: Float(a.noiseAmount ?? 10), gaussian: a.noiseGaussian ?? false,
                                           monochromatic: a.noiseMonochromatic ?? false, seed: a.noiseSeed ?? 0)))
        case .gaussianBlur:
            return .filter(.gaussianBlur(.init(radius: Float(a.blurRadius ?? 10))))
        case .motionBlur:
            return .filter(.motionBlur(.init(angle: Float(a.motionAngle ?? 0), distance: Float(a.motionDistance ?? 10))))
        }
    }

    /// What an adjustment layer `adjustment` leaves out holds (its kind's name, as stored).
    static func unmappedReason(_ a: CompAdjustment) -> String { a.kindName }

    static func fmt(_ v: Double) -> String { v.rounded() == v ? String(Int(v)) : String(format: "%g", v) }

    static func hueSaturation(_ s: CompHueSaturation, layer: String, warn: (String) -> Void) -> Adjustment.HueSaturation {
        func wrapHue(_ h: Double) -> Float {
            var x = h.truncatingRemainder(dividingBy: 360)
            if x > 180 { x -= 360 } else if x <= -180 { x += 360 }
            return Float(x)
        }
        let m = s.adjustments[.master] ?? CompRangeAdjustment()
        let ranges = CompColorRange.colorRanges.map { r -> HueRange in
            let adj = s.adjustments[r] ?? CompRangeAdjustment()
            let b = s.bands[r] ?? r.defaultBand
            return HueRange(hue: wrapHue(adj.hue), saturation: Float(adj.saturation), lightness: Float(adj.lightness),
                            bounds: HueRange.canonicalBounds(SIMD4(Float(b.falloffStart), Float(b.rangeStart), Float(b.rangeEnd), Float(b.falloffEnd))))
        }
        if s.invertRange, s.range != .master, s.adjustments[s.range].map({ $0 != CompRangeAdjustment() }) == true {
            warn("Hue/Saturation layer \"\(layer)\": \"invert range\" on \(s.range.rawValue) has no Photoshop equivalent; the range applies inside its band instead of outside it")
        }
        // Colorize takes the hue as an absolute 0–360; otherwise it is a shift.
        let hue = s.colorize ? Float(m.hue.truncatingRemainder(dividingBy: 360)) : wrapHue(m.hue)
        return .init(hue: hue, saturation: Float(m.saturation), lightness: Float(m.lightness), colorize: s.colorize, ranges: ranges)
    }

    /// `CurvesSettings.value`: shape-preserving cubic Hermite through the points (0–255).
    static func hermite(_ p: [CompCurvePoint], _ x: Double) -> Double {
        guard p.count >= 2 else { return x }
        let i = min(p.count - 2, max(0, p.lastIndex(where: { $0.x <= x }) ?? 0))
        let d = zip(p, p.dropFirst()).map { ($1.y - $0.y) / ($1.x - $0.x) }
        func slope(_ j: Int) -> Double {
            if j == 0 { return d[0] }
            if j == p.count - 1 { return d[d.count - 1] }
            if d[j - 1] * d[j] <= 0 { return 0 }
            return 2 / (1 / d[j - 1] + 1 / d[j])
        }
        let h = p[i + 1].x - p[i].x, t = min(1, max(0, (x - p[i].x) / h))
        let y = (2 * t * t * t - 3 * t * t + 1) * p[i].y + (t * t * t - 2 * t * t + t) * h * slope(i)
            + (-2 * t * t * t + 3 * t * t) * p[i + 1].y + (t * t * t - t * t) * h * slope(i + 1)
        return min(255, max(0, y))
    }

    static func rgb(_ c: CompColor) -> SIMD3<Float> { SIMD3(Float(c.red), Float(c.green), Float(c.blue)) }
    static func pc(_ c: CompColor) -> PCColor { .rgb(Float(c.red), Float(c.green), Float(c.blue)) }

    /// HSL (hue in degrees, saturation and lightness 0–1) to RGB.
    static func hsl(_ hue: Double, _ s: Double, _ l: Double) -> SIMD3<Float> {
        let c = (1 - abs(2 * l - 1)) * s
        let hp = (hue.truncatingRemainder(dividingBy: 360) + 360).truncatingRemainder(dividingBy: 360) / 60
        let x = c * (1 - abs(hp.truncatingRemainder(dividingBy: 2) - 1))
        let (r, g, b): (Double, Double, Double) = switch hp {
        case ..<1: (c, x, 0)
        case ..<2: (x, c, 0)
        case ..<3: (0, c, x)
        case ..<4: (0, x, c)
        case ..<5: (x, 0, c)
        default: (c, 0, x)
        }
        let m = l - c / 2
        return SIMD3(Float(r + m), Float(g + m), Float(b + m))
    }

    // MARK: Effects

    /// The six effects as Photoshop layer styles. Compositor composites them in Normal (its own
    /// renderer, not Photoshop's Multiply/Screen defaults); sizes, distances and blurs are in layer
    /// pixels, so `scale` (document pixels per layer pixel) carries them to the document.
    static func effects(_ e: CompEffects, scale: Double) -> Effects {
        var items: [Effect] = []
        func common(_ enabled: Bool?, _ opacity: Double) -> FxCommon { FxCommon(enabled: enabled ?? true, blend: .normal, opacity: Float(opacity)) }
        func px(_ v: Double) -> Float { Float(v * scale) }
        if let s = e.shadow {
            items.append(.dropShadow(Shadow(common: common(s.enabled, s.opacity), color: pc(s.color), angle: Float(s.angle), useGlobalLight: false,
                                            distance: px(s.distance), spread: 0, size: px(s.blur))))
        }
        if let g = e.outerGlow {
            items.append(.outerGlow(Glow(common: common(g.enabled, g.opacity), paint: .color(pc(g.color)), size: px(g.size))))
        }
        if let s = e.innerShadow {
            items.append(.innerShadow(Shadow(common: common(s.enabled, s.opacity), color: pc(s.color), angle: Float(s.angle), useGlobalLight: false,
                                             distance: px(s.distance), spread: 0, size: px(s.blur), knocksOut: false)))
        }
        if let g = e.innerGlow {
            items.append(.innerGlow(Glow(common: common(g.enabled, g.opacity), paint: .color(pc(g.color)), size: px(g.size), source: .edge)))
        }
        if let o = e.colorOverlay {
            items.append(.colorOverlay(.init(common: common(o.enabled, o.opacity), color: pc(o.color))))
        }
        if let s = e.stroke {
            items.append(.stroke(StrokeFx(common: common(s.enabled, s.opacity), size: px(s.size), position: s.inside ? .inside : .outside,
                                          paint: .color(pc(s.color)))))
        }
        return Effects(enabled: true, items: items)
    }

    // MARK: Text

    /// Compositor's gap between text and its box, in layer pixels (`LayerTextStyle.padding`).
    static let textPadding = 12.0

    /// The type layer for `style`, drawn on `layerToDocument` (layer pixels → document). Its pixels
    /// stay Compositor's until the text is edited.
    static func text(_ style: CompTextStyle, box: (width: Double, height: Double), layerToDocument m: PCAffine, dpi: Double,
                     cache: Surface) -> TextLayer {
        let ptPerPx = 72 / max(dpi, 1)
        var base = CharStyle()
        base.fontFamily = style.fontName
        base.postscriptName = style.fontName
        base.sizePt = Float(style.fontSize * ptPerPx)
        base.color = pc(style.color)
        // Compositor kerns by `tracking` points of its pixel grid; Photoshop's tracking is 1/1000 em.
        base.tracking = Float(style.tracking / max(style.fontSize, 1) * 1000)
        if style.leading > 0 { base.leadingPt = Float(style.leading * ptPerPx) }

        var t = TextLayer(text: style.content, fontFamily: base.fontFamily, sizePt: base.sizePt, color: base.color)
        t.runs = textRuns(style, base: base)
        var ps = ParagraphStyle()
        ps.align = switch style.alignment { case .left: .left; case .center: .center; case .right: .right }
        t.paragraphs = [ParagraphRun(len: style.content.utf8.count, style: ps)]
        let p = textPadding
        if let b = style.boxSize {
            t.shape = .box(.init(x: Float(p), y: Float(p), width: Float(max(1, b.a - 2 * p)), height: Float(max(1, b.b - 2 * p))))
            t.transform = m
        } else {
            // Point text: text space starts at the first baseline; Compositor sets its first line
            // `padding` below the box top (`baseline = padding + lineHeight − descent`).
            let line = style.leading > 0 ? style.leading : style.fontSize * 1.2
            let font = CTFontCreateWithName(style.fontName as CFString, CGFloat(style.fontSize), nil)
            let baseline = p + line - Double(CTFontGetDescent(font))
            let x = switch style.alignment { case .left: p; case .center: box.width / 2; case .right: box.width - p }
            t.transform = PCAffine.translate(x, baseline).then(m)
        }
        t.cache = cache
        t.syncSummary()
        return t
    }

    /// Character runs from the per-letter colours and faces (UTF-16 ranges → UTF-8 byte lengths).
    static func textRuns(_ style: CompTextStyle, base: CharStyle) -> [TextRun] {
        let units = Array(style.content.utf16)
        guard !units.isEmpty else { return [TextRun(len: 0, style: base)] }
        var cuts: Set<Int> = [0, units.count]
        for r in style.colorRuns ?? [] { cuts.insert(min(r.location, units.count)); cuts.insert(min(r.location + r.length, units.count)) }
        for r in style.fontRuns ?? [] { cuts.insert(min(r.location, units.count)); cuts.insert(min(r.location + r.length, units.count)) }
        let edges = cuts.sorted()
        var runs: [TextRun] = []
        for (a, b) in zip(edges, edges.dropFirst()) where b > a {
            var s = base
            if let c = style.colorRuns?.first(where: { $0.location <= a && a < $0.location + $0.length }) {
                s.color = .rgb(Float(c.red), Float(c.green), Float(c.blue))
            }
            if let f = style.fontRuns?.first(where: { $0.location <= a && a < $0.location + $0.length }) {
                s.fontFamily = f.fontName
                s.postscriptName = f.fontName
            }
            let bytes = String(decoding: units[a ..< b], as: UTF16.self).utf8.count
            if let last = runs.last, last.style == s { runs[runs.count - 1].len += bytes } else { runs.append(TextRun(len: bytes, style: s)) }
        }
        return runs
    }

    // MARK: Shapes

    /// The shape layer for `style` in a layer box placed by `t` (whose `w` × `h` grid the PNG is),
    /// with Compositor's pixels as its rendered appearance.
    static func shape(_ style: CompShapeStyle, _ t: CompTransform, _ w: Int, _ h: Int, cache: Surface) -> ShapeLayer {
        let bw = t.width, bh = t.height
        // Unit square of the layer box → document (the rect Compositor draws the shape into).
        let m = t.pixelToDocument(1, 1)
        func doc(_ x: Double, _ y: Double) -> CGPoint { CGPoint(x: m.a * x + m.c * y + m.tx, y: m.b * x + m.d * y + m.ty) }
        let path = CGMutablePath()
        var live: LiveShape?
        let upright = t.radians == 0
        let rect = SIMD4<Double>(t.originX, t.originY, bw, bh)
        var fill: Fill? = .solid(pc(style.color))
        var stroke: ShapeStroke?
        switch style.kind {
        case .rectangle:
            let r = min(max(style.cornerRadius, 0), min(bw, bh) / 2)
            path.addPath(CGPath(roundedRect: CGRect(x: 0, y: 0, width: 1, height: 1), cornerWidth: r / max(bw, 1), cornerHeight: r / max(bh, 1), transform: nil),
                         transform: CGAffineTransform(a: m.a, b: m.b, c: m.c, d: m.d, tx: m.tx, ty: m.ty))
            if upright { live = .rect(rect: rect, radii: SIMD4(repeating: r)) }
        case .ellipse:
            path.addEllipse(in: CGRect(x: 0, y: 0, width: 1, height: 1), transform: CGAffineTransform(a: m.a, b: m.b, c: m.c, d: m.d, tx: m.tx, ty: m.ty))
            if upright { live = .ellipse(rect: rect) }
        case .line:
            let s = style.start ?? CompPair(0, 0), e = style.end ?? CompPair(1, 1)
            let a = doc(s.a, s.b), b = doc(e.a, e.b)
            let width = (style.lineWidth ?? 4) * (bw / Double(max(1, w)))
            path.move(to: a)
            path.addLine(to: b)
            fill = nil
            var st = ShapeStroke()
            st.width = Float(width)
            st.paint = .solid(pc(style.color))
            stroke = st
            live = .line(from: SIMD2(a.x, a.y), to: SIMD2(b.x, b.y), weight: width)
        }
        var shape = ShapeLayer(path: vectorPath(path), fill: fill, stroke: stroke, live: live)
        shape.cache = cache
        return shape
    }

    /// A CoreGraphics path as subpaths of corner/curve knots.
    static func vectorPath(_ cg: CGPath) -> VectorPath {
        var subpaths: [Subpath] = []
        var knots: [Knot] = []
        func pt(_ p: CGPoint) -> PCPoint { PCPoint(x: p.x, y: p.y) }
        func flush(closed: Bool) {
            guard !knots.isEmpty else { return }
            if closed, knots.count > 1, knots[0].anchor == knots[knots.count - 1].anchor {
                // The closing segment ended on the first knot: fold it into the first knot's handle.
                knots[0].inCtrl = knots[knots.count - 1].inCtrl
                knots.removeLast()
            }
            subpaths.append(Subpath(closed: closed, knots: knots, op: .combine))
            knots = []
        }
        cg.applyWithBlock { e in
            let el = e.pointee
            switch el.type {
            case .moveToPoint:
                flush(closed: false)
                let p = pt(el.points[0])
                knots = [Knot(anchor: p, inCtrl: p, outCtrl: p)]
            case .addLineToPoint:
                let p = pt(el.points[0])
                knots.append(Knot(anchor: p, inCtrl: p, outCtrl: p))
            case .addQuadCurveToPoint:
                guard let last = knots.last else { return }
                let c = el.points[0], p = el.points[1]
                let a = last.anchor
                let c1 = PCPoint(x: a.x + 2 / 3 * (c.x - a.x), y: a.y + 2 / 3 * (c.y - a.y))
                let c2 = PCPoint(x: p.x + 2 / 3 * (c.x - p.x), y: p.y + 2 / 3 * (c.y - p.y))
                knots[knots.count - 1].outCtrl = c1
                knots.append(Knot(anchor: pt(p), inCtrl: c2, outCtrl: pt(p)))
            case .addCurveToPoint:
                guard !knots.isEmpty else { return }
                knots[knots.count - 1].outCtrl = pt(el.points[0])
                knots.append(Knot(anchor: pt(el.points[2]), inCtrl: pt(el.points[1]), outCtrl: pt(el.points[2])))
            case .closeSubpath:
                flush(closed: true)
            @unknown default:
                break
            }
        }
        flush(closed: false)
        return VectorPath(subpaths)
    }
}
