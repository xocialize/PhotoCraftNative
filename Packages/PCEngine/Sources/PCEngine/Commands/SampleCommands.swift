// Port of photocraft-engine (crates/engine/src/sample_cmds.rs), MIT OR Apache-2.0, © ArtCraft Team and the PhotoCraft contributors.
//
// Eyedropper sampling (#1649): Photoshop's Sample Size (Point Sample, or the average of a 3×3 …
// 101×101 square centred on the clicked pixel) and Sample (which layers the colour comes from).
// The Eyedropper tool, the painting tools' ⌥-click eyedropper and the Info panel read colours
// through `sampleColor`, so they share one setting, as in Photoshop. Averages are taken in the
// document's own colour model and bit depth (CMYK documents average their composite RGB), weighted
// by alpha, rounded to the document's depth, then returned as straight-alpha RGBA.

import PCDocument
import PCFoundation
import PCRender

public enum SampleCommands: CommandModule {
    public static let name = "sample_cmds"
    static let m = "sample_cmds"

    /// The Sample Size choices: 1 = Point Sample, otherwise the side of the averaged square.
    public static let sampleSizes: [UInt32] = [1, 3, 5, 11, 31, 51, 101]

    /// Which layers the Eyedropper samples (its options bar's Sample menu).
    public enum SampleLayers: String, Sendable, CaseIterable {
        /// The active layer alone.
        case current
        /// The active layer and everything below it.
        case currentAndBelow
        /// The whole visible composite (Photoshop's default).
        case all
        /// `all` with adjustment layers left out.
        case allNoAdjustments
        /// `currentAndBelow` with adjustment layers left out.
        case currentAndBelowNoAdjustments

        /// Every choice in the options bar's order.
        public static let ordered: [SampleLayers] = [.current, .currentAndBelow, .all, .allNoAdjustments, .currentAndBelowNoAdjustments]

        var noAdjustments: Bool { self == .allNoAdjustments || self == .currentAndBelowNoAdjustments }
    }

    /// The pixels a sample of `size` at document point (`x`, `y`) averages: the `size`×`size`
    /// square centred on the pixel under the point, clipped to `canvas`. nil when the point is off
    /// the canvas (or not finite), or `size` is not one of `sampleSizes`.
    public static func sampleRect(_ x: Double, _ y: Double, _ size: UInt32, _ canvas: PixelRect) -> PixelRect? {
        guard x.isFinite, y.isFinite, sampleSizes.contains(size) else { return nil }
        let (fx, fy) = (x.rounded(.down), y.rounded(.down))
        guard fx >= Double(Int32.min), fx <= Double(Int32.max), fy >= Double(Int32.min), fy <= Double(Int32.max) else { return nil }
        let (px, py) = (Int32(fx), Int32(fy))
        guard canvas.contains(x: px, y: py) else { return nil }
        let r = Int32(size / 2)
        func sat(_ v: Int64) -> Int32 { Int32(clamping: v) }
        let square = PixelRect(x0: sat(Int64(px) - Int64(r)), y0: sat(Int64(py) - Int64(r)), x1: sat(Int64(px) + Int64(r) + 1), y1: sat(Int64(py) + Int64(r) + 1))
        return square.intersect(canvas)
    }

    /// Round `v` to what a channel of `depth` can store (32 bit keeps the float).
    static func quantize(_ v: Float, _ depth: SampleType) -> Float {
        var b = [UInt8](repeating: 0, count: 4)
        b.withUnsafeMutableBytes { writeSample($0, depth, 0, v) }
        return b.withUnsafeBytes { readSample($0, depth, 0) }
    }

    /// The alpha-weighted average of straight-alpha RGBA pixels `px`, taken in the channels of
    /// colour model `mode` at bit depth `depth`: each pixel is converted to `mode`, the colour
    /// channels are averaged weighted by alpha, the mean is rounded to `depth` and converted back
    /// to RGBA. Alpha is the mean coverage. Fully transparent (or empty) input averages to
    /// transparent black.
    public static func average(_ px: [SIMD4<Float>], _ mode: ColorMode, _ depth: SampleType) -> SIMD4<Float> {
        let fmt = PixelFormat(mode: mode, sample: depth, alpha: false)
        let n = min(fmt.channels, 8)
        var sum = [Double](repeating: 0, count: 8)
        var alpha = 0.0
        for p in px {
            let a = p.w.isFinite ? min(max(p.w, 0), 1) : 0
            if a <= 0 || !(p.x.isFinite && p.y.isFinite && p.z.isFinite) { continue }
            let native = fmt.components(fromRGBA: p)
            for i in 0..<min(native.count, n) { sum[i] += Double(native[i]) * Double(a) }
            alpha += Double(a)
        }
        if px.isEmpty || alpha <= 0 { return .zero }
        let mean = (0..<n).map { quantize(Float(sum[$0] / alpha), depth) }
        let c = PixelCodec.toRGBA(fmt, mean)
        return SIMD4(c.x, c.y, c.z, quantize(Float(alpha / Double(px.count)), depth))
    }

    /// The document that renders what `which` samples: the whole document, or a copy with the
    /// layers it leaves out hidden. `active` is the active layer (nil: Current Layer samples
    /// nothing).
    static func sampledDocument(_ doc: Document, _ active: LayerId?, _ which: SampleLayers) -> Document? {
        switch which {
        case .all:
            return doc
        case .current:
            // The active layer on its own, as if it were the only layer: its pixels, not how its
            // group, blend mode or opacity show it in the composite.
            guard let id = active, var layer = doc.layer(id) else { return nil }
            layer.visible = true
            layer.clipped = false
            layer.opacity = 1
            layer.fillOpacity = 1
            layer.blend = .normal
            var solo = doc
            solo.layers = [layer]
            return solo
        default:
            break
        }
        var copy = doc
        let walk = doc.walk().map { e -> (LayerPath, LayerId, Bool) in
            if case .adjustment = e.layer.content { return (e.path, e.layer.id, true) }
            return (e.path, e.layer.id, false)
        }
        if which == .currentAndBelow || which == .currentAndBelowNoAdjustments {
            // Everything composited after (above) the active layer in the bottom-to-top walk,
            // except its own contents: the walk lists a group before its children.
            guard let pos = walk.firstIndex(where: { $0.1 == active }) else { return nil }
            let own = walk[pos].0
            for (path, _, _) in walk[(pos + 1)...] where !path.starts(with: own) {
                _ = copy.updateLayer(at: path) { $0.visible = false }
            }
        }
        if which.noAdjustments {
            for (path, _, adj) in walk where adj { _ = copy.updateLayer(at: path) { $0.visible = false } }
        }
        return copy
    }

    /// The colour the Eyedropper picks at document point (`x`, `y`) with Sample Size `size` from
    /// the layers `which` names, as straight-alpha RGBA. A Point Sample is the composite pixel
    /// itself; larger sizes are the `average` of the square around it, clipped to the canvas.
    /// Transparent black off the canvas, over transparency, or when `which` needs an active layer
    /// and there is none.
    public static func sampleColor(_ doc: Document, _ active: LayerId?, _ x: Double, _ y: Double, _ size: UInt32, _ which: SampleLayers,
                                   renderer: EngineRenderer = .shared) -> SIMD4<Float> {
        guard let rect = sampleRect(x, y, size, doc.bounds), let src = sampledDocument(doc, active, which),
              let buf = try? renderer.renderExact(src, region: rect) else { return .zero }
        if size == 1 { return buf.px.first ?? .zero }
        return average(buf.px, averagingModel(doc), doc.depth)
    }

    /// The colour model the averages are taken in: the document's, except CMYK. CMYK documents are
    /// composited in RGB, and the profile's RGB → CMYK → RGB round trip is not exact, so averaging
    /// in CMYK would make a 3×3 sample of a flat area differ from its Point Sample.
    static func averagingModel(_ doc: Document) -> ColorMode {
        let m = doc.pixelFormat.mode
        return m == .cmyk ? .rgb : m
    }

    static func bad(_ cmd: String, _ msg: String) -> EngineError { .bad(cmd, msg) }

    /// The `size` param: 1 (Point Sample) or an averaged square's side; "point" is accepted too.
    static func sizeParam(_ cmd: String, _ p: JSONValue) throws -> UInt32 {
        switch p["size"] {
        case nil, .null?: return 1
        case .string("point")?: return 1
        case let v?:
            if let n = v.uint64Value, let u = UInt32(exactly: n), sampleSizes.contains(u) { return u }
            throw bad(cmd, "`size` = \(v.serialized()) must be \"point\" or one of [\(sampleSizes.map(String.init).joined(separator: ", "))]")
        }
    }

    /// The `sampleLayer` param (default `all`).
    static func layersParam(_ cmd: String, _ p: JSONValue) throws -> SampleLayers {
        switch p["sampleLayer"] {
        case nil, .null?: return .all
        case .string(let s)?:
            guard let v = SampleLayers(rawValue: s) else {
                throw bad(cmd, "unknown sampleLayer `\(s)` (\(SampleLayers.ordered.map(\.rawValue).joined(separator: "|")))")
            }
            return v
        case let v?: throw bad(cmd, "`sampleLayer` = \(v.serialized()) must be a string")
        }
    }

    static func coord(_ cmd: String, _ p: JSONValue, _ key: String) throws -> Double {
        guard let v = p[key]?.doubleValue, v.isFinite else { throw bad(cmd, "`\(key)` must be a finite number (document pixels)") }
        return v
    }

    public static func register(into r: inout CommandRegistry) {
        r.add(CommandSpec("document.sampleColor", "Sample Color",
                          params: #"{"x":f64,"y":f64,"size":"point"|1|3|5|11|31|51|101=1,"sampleLayer":"current"|"currentAndBelow"|"all"|"allNoAdjustments"|"currentAndBelowNoAdjustments"="all"} → [r,g,b,a] (the Eyedropper's Sample Size and Sample: the composite pixel, or the average of the size×size square centred on it, clipped to the canvas; transparent off the canvas)"#,
                          module: m, journal: false, enabled: Pre.hasDoc) { s, p in
            let cmd = "document.sampleColor"
            let (x, y) = (try coord(cmd, p, "x"), try coord(cmd, p, "y"))
            let size = try sizeParam(cmd, p)
            let which = try layersParam(cmd, p)
            guard let d = s.active else { throw EngineError.noDocument }
            return .rgba(sampleColor(d.doc, d.activeLayer, x, y, size, which, renderer: s.services.renderer))
        })
    }
}
