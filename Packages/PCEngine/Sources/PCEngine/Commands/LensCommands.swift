// Port of photocraft-engine (crates/engine/src/lens_cmds.rs), MIT OR Apache-2.0, © ArtCraft Team and the PhotoCraft contributors.
//
// Filter › Lens Correction, Filter › Adaptive Wide Angle, Filter › Camera Raw Filter and
// File › Automate › Lens Correction (the batch twin, in LensCommands+Batch.swift).
//
// The three filters act on the active pixel layer (inside the selection) or, on a smart object,
// record a smart filter whose params are fully resolved (EXIF-derived values are written into
// them), so re-rendering is deterministic. Algorithms: PCAlgo `Lens` / `LensCorrection`,
// `WideAngle`, and `ToneKit.develop` (Camera Raw).

import Foundation
import PCAlgo
import PCDocument
import PCFoundation
import PCPlatform

enum LensCommands: CommandModule {
    static let name = "lens_cmds"

    static let lens = "filter.lensCorrection"
    static let wide = "filter.adaptiveWideAngle"
    static let raw = "filter.cameraRaw"
    static let lensBatchId = "file.automate.lensCorrection"

    static func register(into r: inout CommandRegistry) {
        r.add(specs())
    }

    static func bad(_ cmd: String, _ msg: String) -> EngineError { .bad(cmd, msg) }

    static func num(_ p: JSONValue, _ k: String, _ d: Double) -> Double {
        guard case .number(let v)? = p[k], v.isFinite else { return d }
        return v
    }

    static func flag(_ p: JSONValue, _ k: String, _ d: Bool) -> Bool {
        guard case .bool(let b)? = p[k] else { return d }
        return b
    }

    static func clamp(_ v: Double, _ lo: Double, _ hi: Double) -> Double { min(max(v, lo), hi) }

    /// Milliseconds since `t0` (photocraft `Stopwatch::ms`).
    static func ms(since t0: Date) -> Double { Date().timeIntervalSince(t0) * 1000 }

    // MARK: Params

    /// Lens Correction settings from params; `info` resolves `"profile":"auto"` (photocraft
    /// `lens_params`).
    static func lensParams(_ cmd: String, _ p: JSONValue, frame: PixelRect, info: Exif.CameraInfo?) throws -> LensCorrection {
        var lc = LensCorrection(correctDistortion: flag(p, "correctDistortion", true), correctVignette: flag(p, "correctVignette", true),
                                correctCa: flag(p, "correctCA", true), distortion: clamp(num(p, "distortion", 0), -100, 100),
                                redCyan: clamp(num(p, "redCyan", 0), -100, 100), blueYellow: clamp(num(p, "blueYellow", 0), -100, 100),
                                vignetteAmount: clamp(num(p, "vignetteAmount", 0), -100, 100),
                                vignetteMidpoint: clamp(num(p, "vignetteMidpoint", 50), 0, 100), vertical: clamp(num(p, "vertical", 0), -100, 100),
                                horizontal: clamp(num(p, "horizontal", 0), -100, 100), angle: num(p, "angle", 0),
                                scale: clamp(num(p, "scale", 100), 50, 150))
        switch p["edge"]?.stringValue ?? "transparency" {
        case "transparency": lc.edge = .transparency
        case "edgeExtension", "extension": lc.edge = .edgeExtension
        case "black": lc.edge = .color(SIMD4(0, 0, 0, 1))
        case "white": lc.edge = .color(SIMD4(1, 1, 1, 1))
        case "background", "color": lc.edge = .color(Params.color(p, "edgeColor", SIMD4(0, 0, 0, 1)))
        case let other: throw bad(cmd, "unknown edge `\(other)` (transparency|edgeExtension|black|white|color)")
        }
        let focal = num(p, "focalLength", 0)
        switch p["profile"]?.stringValue ?? "none" {
        case "none", "": lc.profile = nil
        case "generic": lc.profile = Lens.genericProfile(focal35mm: focal > 0 ? focal : 50)
        case "auto":
            lc.profile = (info?.focalLength35mm ?? info?.focalLength ?? (focal > 0 ? focal : nil)).map { Lens.genericProfile(focal35mm: $0) }
        case let other: throw bad(cmd, "unknown profile `\(other)` (none|auto|generic)")
        }
        if case .array(let line)? = p["straighten"] {
            func pt(_ v: JSONValue) -> SIMD2<Double>? {
                guard let a = v.arrayValue, a.count >= 2, case .number(let x) = a[0], case .number(let y) = a[1] else { return nil }
                return SIMD2(x, y)
            }
            guard line.count >= 2, let a = pt(line[0]), let b = pt(line[1]) else { throw bad(cmd, "`straighten` is [[x0,y0],[x1,y1]]") }
            lc.angle += Lens.straightenAngle(a, b)
        }
        if flag(p, "autoScale", false) { lc.scale = Lens.autoScale(lc, frame: frame) }
        return lc
    }

    /// Writes the resolved profile / angle / scale back into the params (for smart filters).
    static func resolvedLensParams(_ p: JSONValue, _ lc: LensCorrection) -> JSONValue {
        guard case .object(var m) = p else { return p }
        m["straighten"] = nil
        m["autoScale"] = nil
        m["layer"] = nil
        m["angle"] = .number(lc.angle)
        m["scale"] = .number(lc.scale)
        if let pr = lc.profile {
            m["profile"] = .string("generic")
            let rest = pr.name.hasPrefix("Generic Lens (") ? String(pr.name.dropFirst("Generic Lens (".count)) : pr.name
            let f = rest.split(separator: " ", omittingEmptySubsequences: false).first.flatMap { Double($0) } ?? 50
            m["focalLength"] = .number(f)
        } else {
            m["profile"] = .string("none")
        }
        return .object(m)
    }

    /// Adaptive Wide Angle settings; a zero focal length is taken from EXIF when present
    /// (photocraft `wide_params`).
    static func wideParams(_ cmd: String, _ p: JSONValue, info: Exif.CameraInfo?) throws -> WideAngle {
        var wa: WideAngle
        do { wa = try p.decode(as: WideAngle.self) } catch {
            throw bad(cmd, #"bad params: \#(RenderCommands.describe(error)) (constraints: [{"a":[x,y],"b":[x,y],"orientation":"free|horizontal|vertical"}])"#)
        }
        if wa.constraints.contains(where: { !($0.a.x.isFinite && $0.a.y.isFinite && $0.b.x.isFinite && $0.b.y.isFinite) }) {
            throw bad(cmd, "constraint points must be finite")
        }
        wa.scale = clamp(wa.scale, 50, 150)
        wa.cropFactor = clamp(wa.cropFactor, 0.1, 10)
        if wa.focalLength <= 0, let i = info {
            if let f = i.focalLength {
                wa.focalLength = f
                if let f35 = i.focalLength35mm { wa.cropFactor = clamp(f35 / f, 0.1, 10) }
            } else if let f35 = i.focalLength35mm {
                wa.focalLength = f35
                wa.cropFactor = 1
            }
        }
        return wa
    }

    /// Camera Raw settings, ACR names in camelCase (photocraft `raw_params`).
    static func rawParams(_ cmd: String, _ p: JSONValue) throws -> CameraRaw {
        var cr: CameraRaw
        do { cr = try p.removing("layer").decode(as: CameraRaw.self) } catch {
            throw bad(cmd, "bad params: \(RenderCommands.describe(error))")
        }
        // The noise stages turn these straight into a guided-filter radius and a blur sigma, so an
        // out-of-range value means unbounded work. Clamp to the documented 0..100 (photocraft #707).
        cr.noiseLuminance = min(max(cr.noiseLuminance, 0), 100)
        cr.noiseLuminanceDetail = min(max(cr.noiseLuminanceDetail, 0), 100)
        cr.noiseColor = min(max(cr.noiseColor, 0), 100)
        cr.noiseColorDetail = min(max(cr.noiseColorDetail, 0), 100)
        return cr
    }

    // MARK: Pixels

    /// Largest area Camera Raw develops in one pass. The pipeline holds the whole region as RGBA
    /// f32 plus the source and result planes (≥ 48 bytes per pixel), so beyond this a document is
    /// refused with an error rather than attempted (photocraft #962).
    static let maxRawPixels: UInt64 = 400_000_000

    /// The number of pixels in `area` if Camera Raw can develop it in one pass.
    static func rawPixels(_ area: PixelRect) -> Int? {
        let n = UInt64(max(area.width, 0)) * UInt64(max(area.height, 0))
        return n <= maxRawPixels ? Int(exactly: n) : nil
    }

    /// Camera Raw on a surface over `area` (RGB / Gray via RGBA, at the surface's depth;
    /// photocraft `camera_raw_surface`). An area above `maxRawPixels` is returned unchanged: the
    /// command rejects it with an error first, and this keeps the Smart Filter path bounded.
    static func cameraRawSurface(_ surf: Surface, _ area0: PixelRect, _ cr: CameraRaw) -> Surface {
        let area = area0.intersect(surf.contentBounds.union(area0))
        if area.isEmpty || cr.isIdentity { return surf }
        guard rawPixels(area) != nil else { return surf }
        let fmt = surf.format
        let (w, h) = (area.width, area.height)
        var px = surf.readRGBA(area)
        guard px.count == w * h else { return surf }
        ToneKit.develop(&px, w: w, h: h, cr, float: fmt.sample == .f32)
        let n = fmt.channels
        let orig = surf.readRegion(area)
        var data = PixelCodec.fromRGBA(fmt, rgba: px)
        if fmt.alpha && data.count == orig.count {
            // Alpha is untouched.
            var k = n - 1
            while k < data.count { data[k] = orig[k]; k += n }
        }
        var out = surf
        out.writeRegion(area, data)
        out.prune()
        return out
    }

    /// Mixes `new` over `old` by the selection's coverage (photocraft `mix_by_selection`).
    static func mixBySelection(_ old0: Surface, _ new: Surface, _ sel: Surface) -> Surface {
        let area = old0.contentBounds.union(new.contentBounds)
        let fmt = new.format
        let old = old0.format == fmt ? old0 : old0.convertedAny(to: fmt)
        var out = new
        if area.isEmpty { return out }
        let n = fmt.channels
        let o = old.readRegion(area), w = new.readRegion(area)
        guard o.count == w.count else { return out }
        let aw = area.width
        var r = [Float](repeating: 0, count: o.count)
        for i in 0..<(o.count / n) {
            let k = min(max(sel.sampleChannel(x: area.x0 + Int32(i % aw), y: area.y0 + Int32(i / aw), 0), 0), 1)
            let b = i * n
            if !fmt.alpha {
                for c in 0..<n { r[b + c] = o[b + c] + (w[b + c] - o[b + c]) * k }
                continue
            }
            let a = n - 1
            let oa = o[b + a] + (w[b + a] - o[b + a]) * k
            r[b + a] = oa
            for c in 0..<a {
                let pm = o[b + c] * o[b + a] + (w[b + c] * w[b + a] - o[b + c] * o[b + a]) * k
                r[b + c] = oa > 0 ? pm / oa : 0
            }
        }
        out.writeRegion(area, r)
        out.prune()
        return out
    }

    /// Smart-filter hook: re-applies a stored filter of this module, nil for other ids (photocraft
    /// `apply_to_surface`).
    static func applyToSurface(_ id: String, _ p: JSONValue, _ surf: Surface, canvas: PixelRect) -> Surface? {
        switch id {
        case lens:
            guard let lc = try? lensParams(id, p, frame: canvas, info: nil) else { return nil }
            return Lens.correct(surf, frame: canvas, lc)
        case wide:
            guard let wa = try? wideParams(id, p, info: nil) else { return nil }
            return wa.apply(surf, frame: canvas, interp: .bicubic)
        case raw:
            guard let cr = try? rawParams(id, p) else { return nil }
            return cameraRawSurface(surf, canvas, cr)
        default:
            return nil
        }
    }

    // MARK: Commands

    static func target(_ s: Session, _ p: JSONValue) throws -> LayerId {
        if let v = p["layer"]?.uint64Value { return LayerId(v) }
        guard let a = s.active?.activeLayer else { throw EngineError.other("no active layer") }
        return a
    }

    static func cameraInfo(_ doc: Document) -> Exif.CameraInfo? { doc.metadata.exif.map { Exif.read($0) } }

    static let filterable: CommandEnabled = { s, _ in
        guard let d = s.active else { return "no document open" }
        guard let id = d.activeLayer else { return "no active layer" }
        guard let l = d.doc.layer(id) else { return "no active layer" }
        switch l.content {
        case .raster: return nil
        case .smart(let sm) where sm.cache != nil: return nil
        default: return "filters need a pixel layer (active layer is \(l.content.article) \(l.content.kindName) layer)"
        }
    }

    static let rawEnabled: CommandEnabled = { s, p in
        if let why = filterable(s, p) { return why }
        guard let d = s.active else { return "no document open" }
        switch d.doc.mode {
        case .rgb, .grayscale: return nil
        case let m: return "Camera Raw Filter needs an RGB or Grayscale document (this one is \(MultichannelCommands.debugName(m)))"
        }
    }

    /// Runs `f` on the target layer: a pixel layer is edited in place inside the selection; a smart
    /// object gets a smart filter with the `stored` params (photocraft `run_filter`).
    static func runFilter(_ s: Session, _ cmd: String, _ label: String, _ stored0: JSONValue, floatBackground: Bool,
                          _ f: (Surface, PixelRect) -> Surface) throws -> LayerId {
        let id = try target(s, stored0)
        let stored = stored0.removing("layer")
        let services = s.services
        try s.edit(label) { doc, _ in
            let canvas = doc.bounds
            let selection = doc.selection
            let locks = doc.effectiveLocks(id)
            let background = doc.isBackground(id)
            guard let l = doc.layer(id) else { throw EngineError.noLayer(id) }
            if case .smart = l.content {
                let sf = SmartFilter(command: cmd, params: stored, blend: .normal, opacity: 1, visible: true)
                try FilterCommands.addSmartFilter(&doc, id, sf, selection: selection, services: services)
                return
            }
            if locks.all || locks.pixels { throw EngineError.other("layer \"\(l.name)\" is locked") }
            // A Background layer gains transparency when the edge mode exposes it (as in Photoshop).
            if floatBackground && background { _ = doc.updateLayer(id) { LayerOps.unlockBackground(&$0) } }
            let done: Void? = doc.withRaster(of: id) { surf in
                let out = f(surf, canvas)
                surf = selection.map { mixBySelection(surf, out, $0) } ?? out
            }
            if done == nil { throw EngineError.other("\(label) needs a pixel layer") }
        }
        return id
    }

    static func lensCorrection(_ s: Session, _ p: JSONValue) throws -> JSONValue {
        guard let st = s.active else { throw EngineError.noDocument }
        let frame = st.doc.bounds
        let lc = try lensParams(lens, p, frame: frame, info: cameraInfo(st.doc))
        let stored = resolvedLensParams(p, lc)
        let t0 = Date()
        // As in photocraft, the target comes from the stored params, which drop `layer`: the
        // active layer.
        let id = try runFilter(s, lens, "Lens Correction", stored, floatBackground: lc.edge == .transparency) { surf, canvas in Lens.correct(surf, frame: canvas, lc) }
        return ["layer": .id(id), "profile": .optional(lc.profile.map { .string($0.name) }), "angle": .number(lc.angle), "scale": .number(lc.scale),
                "params": stored, "ms": .number(ms(since: t0))]
    }

    static func adaptiveWideAngle(_ s: Session, _ p: JSONValue) throws -> JSONValue {
        guard let st = s.active else { throw EngineError.noDocument }
        let frame = st.doc.bounds
        let wa = try wideParams(wide, p, info: cameraInfo(st.doc))
        let t0 = Date()
        let mesh = wa.solve(frame: frame)
        let cam = WideAngle.Camera(wa, frame: frame)
        var stored = JSONValue.encoded(wa)
        if let l = p["layer"] { stored = stored.setting("layer", l) }
        let interp = Interp(parsing: p["interpolation"]?.stringValue ?? "bicubic")
        let id = try runFilter(s, wide, "Adaptive Wide Angle", stored, floatBackground: true) { surf, canvas in
            if canvas == frame {
                return MeshWarp.warpTriangles(surf, srcRect: canvas, verts: mesh.verts, tris: mesh.triangles(), interp: interp)
            }
            return wa.apply(surf, frame: canvas, interp: interp)
        }
        let model = switch cam.model {
        case .fisheye: "fisheye"
        case .perspective: "perspective"
        case .fullSpherical: "fullSpherical"
        case .auto: "auto"
        }
        let curves: [JSONValue] = mesh.curves.map { c in .array(c.map { JSONValue.array([.number($0.x), .number($0.y)]) }) }
        return ["layer": .id(id), "model": .string(model), "focalPx": .number(cam.f), "constraints": .int(wa.constraints.count),
                "curves": .array(curves), "residual": .number(mesh.residual), "params": stored.removing("layer"), "ms": .number(ms(since: t0))]
    }

    /// The transfer curve Camera Raw decodes `doc`'s values with (`CameraRaw.encodingGamma`):
    /// ProPhoto's gamma 1.8 (raws open in it), Adobe RGB's 563/256, 1 for linear sRGB, else 0 for
    /// the sRGB curve (photocraft `encoding_gamma`).
    static func encodingGamma(_ doc: Document) -> Float {
        let profile = ColorCommands.documentProfile(doc)
        let table: [(BuiltinProfile, Float)] = [(.proPhoto, 1.8), (.adobeRGB, 563 / 256), (.linearSRGB, 1)]
        return table.first { profile.sameColors(as: $0.0.profile) }?.1 ?? 0
    }

    static func cameraRawCmd(_ s: Session, _ p0: JSONValue) throws -> JSONValue {
        // The document's transfer curve goes with the settings, so a Smart Filter keeps it.
        var p = p0
        if p["encodingGamma"] == nil, let g = s.active.map({ encodingGamma($0.doc) }), g > 0, p.objectValue != nil {
            p = p.setting("encodingGamma", .number((Double(g) * 1e4).rounded() / 1e4))
        }
        let cr = try rawParams(raw, p)
        // New settings are strict; stored Smart Filters re-apply through the lenient `rawParams`.
        if let e = cr.validate() { throw bad(raw, e) }
        // The pixel path works on the canvas plus the layer's content in one buffer; a legal
        // 65536×65536 canvas is 2^32 pixels (photocraft #962).
        if !cr.isIdentity {
            guard let d = s.active else { throw EngineError.noDocument }
            let id = try target(s, p)
            let area = d.doc.layer(id)?.surface.map { d.doc.bounds.union($0.contentBounds) } ?? d.doc.bounds
            if rawPixels(area) == nil {
                throw bad(raw, "the image is too large for Camera Raw (\(area.width)×\(area.height) px; max \(maxRawPixels / 1_000_000) megapixels)")
            }
        }
        let t0 = Date()
        let id = try runFilter(s, raw, "Camera Raw Filter", p, floatBackground: false) { surf, canvas in
            cameraRawSurface(surf, canvas.union(surf.contentBounds), cr)
        }
        return ["layer": .id(id), "identity": .bool(cr.isIdentity), "ms": .number(ms(since: t0))]
    }

    // MARK: Specs

    static let lensDoc = ##"{"profile":"none|auto|generic","focalLength":mm=0,"correctDistortion":bool=true,"correctVignette":bool=true,"correctCA":bool=true,"autoScale":bool=false,"distortion":-100..100=0,"redCyan":-100..100=0,"blueYellow":-100..100=0,"vignetteAmount":-100..100=0,"vignetteMidpoint":0..100=50,"vertical":-100..100=0,"horizontal":-100..100=0,"angle":-180..180=0,"scale":50..150=100,"edge":"transparency|edgeExtension|black|white","straighten":[[x,y],[x,y]]?}"##

    static func specs() -> [CommandSpec] {
        [
            CommandSpec(lens, "Lens Correction…", menu: ["Filter"], shortcut: "Cmd+Shift+R", params: lensDoc, module: name,
                        enabled: filterable, run: lensCorrection),
            CommandSpec(wide, "Adaptive Wide Angle…", menu: ["Filter"], shortcut: "Cmd+Alt+Shift+A",
                        params: ##"{"model":"auto|fisheye|perspective|fullSpherical","focalLength":0..200=0,"cropFactor":0.1..10=1,"scale":50..150=100,"constraints":[{"a":[x,y],"b":[x,y],"orientation":"free|horizontal|vertical"}]}"##,
                        module: name, enabled: filterable, run: adaptiveWideAngle),
            CommandSpec(raw, "Camera Raw Filter…", menu: ["Filter"], shortcut: "Cmd+Shift+A",
                        params: ##"{"temperature":-100..100=0,"tint":-100..100=0,"exposure":-5..5=0,"contrast":-100..100=0,"highlights":-100..100=0,"shadows":-100..100=0,"whites":-100..100=0,"blacks":-100..100=0,"texture":-100..100=0,"clarity":-100..100=0,"dehaze":-100..100=0,"vibrance":-100..100=0,"saturation":-100..100=0,"curveHighlights":-100..100=0,"curveLights":-100..100=0,"curveDarks":-100..100=0,"curveShadows":-100..100=0,"curveSplits":[25,50,75],"pointCurve":[[in,out]],"pointCurveRed":[[in,out]],"pointCurveGreen":[[in,out]],"pointCurveBlue":[[in,out]],"hslHue":[8],"hslSat":[8],"hslLum":[8],"gradeShadows":{"hue":deg,"sat":0..100,"lum":-100..100},"gradeMidtones":{},"gradeHighlights":{},"gradeGlobal":{},"gradeBlending":0..100=50,"gradeBalance":-100..100=0,"sharpenAmount":0..150=0,"sharpenRadius":0.5..3=1,"sharpenDetail":0..100=25,"sharpenMasking":0..100=0,"noiseLuminance":0..100=0,"noiseLuminanceDetail":0..100=50,"noiseColor":0..100=0,"noiseColorDetail":0..100=50,"grainAmount":0..100=0,"grainSize":0..100=25,"grainRoughness":0..100=50,"vignetteAmount":-100..100=0,"vignetteMidpoint":0..100=50,"vignetteRoundness":-100..100=0,"vignetteFeather":0..100=50,"vignetteHighlights":0..100=0,"vignetteStyle":"highlightPriority|colorPriority|paintOverlay","seed":u32=0}"##,
                        module: name, enabled: rawEnabled, run: cameraRawCmd),
            CommandSpec(lensBatchId, "Lens Correction…", menu: ["File", "Automate"],
                        params: ##"{"input":folder|[files],"output":folder,"format":"same|jpg|png|tif|psd","quality":0..12?, …Filter › Lens Correction params ("profile" defaults to "auto")}"##,
                        module: name, enabled: Pre.always, run: lensBatch),
        ]
    }
}
