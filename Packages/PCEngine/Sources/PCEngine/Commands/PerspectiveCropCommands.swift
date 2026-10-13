// Port of photocraft-engine (crates/engine/src/perspective_crop_cmds.rs), MIT OR Apache-2.0, © ArtCraft Team and the PhotoCraft contributors.
//
// The Perspective Crop tool's commit: `image.perspectiveCrop`. Four corners (TL, TR, BR, BL in
// document px) mark a quad that is a rectangle seen in perspective; the whole document is mapped
// through the homography taking it onto an upright W x H rectangle, which becomes the new canvas,
// in one undo step: every raster layer, layer mask, alpha channel and the Quick Mask is resampled
// through the map (PCAlgo's `Transform.warpSurfaceClipped`, bounded by the new canvas), the
// Background stays a Background over the background colour where the quad reaches past the
// image, and pixels outside the quad are deleted. Type, shape, fill and smart object layers are
// rasterized first; vector masks, paths, notes, slices and guides follow the affine map closest
// to the homography (exact when the quad is a parallelogram).

import Foundation
import PCAlgo
import PCDocument
import PCFoundation

enum PerspectiveCropCommands: CommandModule {
    static let name = "perspective_crop_cmds"
    static let m = name

    static let cmd = "image.perspectiveCrop"
    /// The largest output side (the `file.new`, Canvas Size and Crop limit).
    static let maxSide = 300_000
    /// Corner coordinates beyond this are refused (far past any canvas).
    static let maxCoord = 1e7
    /// The highest resolution (ppi) the crop may set, as for Image Size.
    static let maxResolution = 10_000.0
    /// photocraft image_cmds `MAX_RESAMPLE_BYTES` (64-bit).
    static let maxResampleBytes: UInt64 = 8 << 30

    static func bad(_ msg: String) -> EngineError { .bad(cmd, msg) }

    /// A number as Rust's `Display` writes it (whole numbers without a fraction).
    static func num(_ v: Double) -> String {
        if v.isFinite, v == v.rounded(), abs(v) < 1e16 { return String(Int64(v)) }
        return "\(v)"
    }

    /// `corners`: four `[x, y]` points, TL, TR, BR, BL, forming a convex quad clockwise on screen.
    static func corners(_ p: JSONValue) throws -> [SIMD2<Double>] {
        let shape = bad("`corners` must be four [x, y] points: top-left, top-right, bottom-right, bottom-left")
        guard let list = p["corners"]?.arrayValue, list.count == 4 else { throw shape }
        var q: [SIMD2<Double>] = []
        for c in list {
            guard let xy = c.arrayValue, xy.count == 2, let x = xy[0].doubleValue, let y = xy[1].doubleValue else { throw shape }
            if !(x.isFinite && y.isFinite) || abs(x) > maxCoord || abs(y) > maxCoord {
                throw bad("corner [\(num(x)), \(num(y))] must be finite and within ±\(num(maxCoord)) px")
            }
            q.append(SIMD2(x, y))
        }
        if !Transform.convexQuad(q) {
            throw bad("the corners must form a convex quadrilateral at least 1 px in area, in order top-left, top-right, bottom-right, bottom-left (clockwise on screen)")
        }
        return q
    }

    /// Output size: `width`/`height` in whole px; one alone keeps the quad's proportions; neither
    /// takes the quad's mean side lengths (`Transform.quadSize`).
    static func outSize(_ p: JSONValue, _ q: [SIMD2<Double>]) throws -> (Int, Int) {
        func side(_ key: String) throws -> Double? {
            guard let v = p[key], v != .null else { return nil }
            guard let n = v.doubleValue, n.isFinite, (1...Double(maxSide)).contains(n.rounded()) else {
                throw bad("`\(key)` = \(v.serialized()) must be a number of pixels from 1 to \(maxSide)")
            }
            return n.rounded()
        }
        let (qw, qh) = Transform.quadSize(q)
        let w: Double, h: Double
        switch (try side("width"), try side("height")) {
        case let (sw?, sh?): (w, h) = (sw, sh)
        case let (sw?, nil): (w, h) = (sw, sw * qh / qw)
        case let (nil, sh?): (w, h) = (sh * qw / qh, sh)
        case (nil, nil): (w, h) = (qw, qh)
        }
        func px(_ v0: Double) throws -> Int {
            let v = Double.maximum(v0.rounded(), 1)
            if !v.isFinite || v > Double(maxSide) {
                throw bad("the output would be \(num(v)) px on a side; the limit is \(maxSide)")
            }
            return Int(v)
        }
        return (try px(w), try px(h))
    }

    static func resolution(_ p: JSONValue) throws -> Float? {
        guard let v = p["resolution"], v != .null else { return nil }
        guard let r = v.doubleValue, r.isFinite, (1...maxResolution).contains(r) else {
            throw bad("`resolution` = \(v.serialized()) must be a number of pixels per inch from 1 to \(num(maxResolution))")
        }
        return Float(r)
    }

    static func interpolation(_ p: JSONValue) throws -> Interp {
        switch p["interpolation"] {
        case nil, .null?:
            return .bicubic
        case .string(let s)? where ["nearest", "nearestNeighbor", "bilinear", "bicubic"].contains(s):
            return Interp(parsing: s)
        case let v?:
            throw bad("`interpolation` = \(v.serialized()) must be \"bicubic\", \"bilinear\" or \"nearest\"")
        }
    }

    /// photocraft image_cmds `check_resample_budget`.
    static func checkResampleBudget(_ doc: Document, _ nw: Int, _ nh: Int) throws {
        let bpp = UInt64(Swift.max(doc.pixelFormat.bytesPerPixel, 1))
        func sat(_ a: UInt64, _ b: UInt64) -> UInt64 { let (r, o) = a.multipliedReportingOverflow(by: b); return o ? .max : r }
        let pixels = sat(UInt64(nw), UInt64(nh))
        if sat(pixels, bpp) <= maxResampleBytes { return }
        let mp = pixels / 1_000_000
        let maxMp = maxResampleBytes / bpp / 1_000_000
        throw bad("\(nw) x \(nh) px is \(mp) megapixels; resampling at this bit depth is limited to \(maxMp) megapixels. Choose a smaller size")
    }

    /// The affine map closest to the crop for geometry that can't take a homography (vector masks,
    /// paths, notes, guides): the quad's centroid goes to the output's centre and its mean
    /// horizontal and vertical edges to the output's sides. Exact when the quad is a parallelogram.
    static func nearestAffine(_ q: [SIMD2<Double>], _ w: Double, _ h: Double) -> PCAffine {
        let (tl, tr, br, bl) = (q[0], q[1], q[2], q[3])
        let u = SIMD2((tr.x - tl.x + br.x - bl.x) / 2, (tr.y - tl.y + br.y - bl.y) / 2)
        let v = SIMD2((bl.x - tl.x + br.x - tr.x) / 2, (bl.y - tl.y + br.y - tr.y) / 2)
        let det = u.x * v.y - v.x * u.y
        if !det.isFinite || abs(det) < 1e-12 { return .identity }
        let (m00, m01, m10, m11) = (w * v.y / det, -w * v.x / det, -h * u.y / det, h * u.x / det)
        let c = SIMD2((tl.x + tr.x + br.x + bl.x) / 4, (tl.y + tr.y + br.y + bl.y) / 4)
        return PCAffine(a: m00, b: m10, c: m01, d: m11, e: w / 2 - (m00 * c.x + m01 * c.y), f: h / 2 - (m10 * c.x + m11 * c.y))
    }

    /// A one-channel surface (mask, alpha channel, Quick Mask) through `h`, kept inside `clip`;
    /// what the map uncovers takes the surface's default (a mask's reveal or hide).
    static func warpGray(_ s: Surface, _ h: Homography, _ interp: Interp, _ clip: PixelRect) -> Surface {
        let def = s.defaultPixelValue
        var out = Surface(format: s.format, defaultPixel: def)
        let src = s.contentBounds
        if src.isEmpty { return out }
        // Content with alpha 1 over a transparent outside, so the edges blend into the default.
        let (lifted, n) = TransformCommands.withOpaqueAlpha(s, src)
        let warped = Transform.warpSurfaceClipped(lifted, srcRect: src, h: h, interp: interp, clip: clip,
                                                  on: TransformCommands.backend(src, h, clip: clip))
        TransformCommands.flatten(warped, onto: &out, def: def, n: n, clip: clip)
        out.prune()
        return out
    }

    /// Maps every layer's pixels and masks through `h` into `clip`. `backgroundId` is the
    /// document's Background, if it has one.
    static func warpLayers(_ layers: inout [Layer], _ h: Homography, _ interp: Interp, _ clip: PixelRect, _ bg: SIMD4<Float>,
                           _ backgroundId: LayerId?) {
        for i in layers.indices {
            var l = layers[i]
            let background = backgroundId == l.id
            switch l.content {
            case .group:
                l.withChildren { warpLayers(&$0, h, interp, clip, bg, nil) }
            case .raster(let surf):
                let src = surf.contentBounds
                let warped = Transform.warpSurfaceClipped(surf, srcRect: src, h: h, interp: interp, clip: clip,
                                                          on: TransformCommands.backend(src, h, clip: clip))
                if background {
                    // The Background stays opaque: the mapped pixels over the background colour.
                    let fmt = warped.format
                    var base = Surface(format: fmt)
                    base.fill(clip, with: fmt.components(fromRGBA: bg))
                    FloatCommands.compositeOver(&base, warped)
                    base.prune()
                    l.content = .raster(base)
                } else {
                    l.content = .raster(warped)
                }
            // Adjustment layers have no pixels; the rest was rasterized before.
            default:
                break
            }
            if var mk = l.mask {
                mk.surface = warpGray(mk.surface, h, interp, clip)
                l.mask = mk
            }
            l.fillCache = nil
            layers[i] = l
        }
    }

    static func apply(_ doc: inout Document, _ q: [SIMD2<Double>], _ h: Homography, _ size: (Int, Int), _ interp: Interp, _ bg: SIMD4<Float>) {
        let (w, ht) = size
        let clip = PixelRect(x: 0, y: 0, width: w, height: ht)
        let backgroundId = doc.background?.id
        warpLayers(&doc.layers, h, interp, clip, bg, backgroundId)
        for i in doc.channels.indices { doc.channels[i].surface = warpGray(doc.channels[i].surface, h, interp, clip) }
        if var qm = doc.quickMask {
            qm.surface = warpGray(qm.surface, h, interp, clip)
            doc.quickMask = qm
        }
        doc.selection = nil
        CanvasGeometry.transformGeometry(&doc, nearestAffine(q, Double(w), Double(ht)))
        doc.size = PixelSize(width: w, height: ht)
        CanvasGeometry.refresh(&doc, .shapes)
    }

    static func perspectiveCrop(_ s: Session, _ p: JSONValue) throws -> JSONValue {
        let q = try corners(p)
        let (w, h) = try outSize(p, q)
        let res = try resolution(p)
        let interp = try interpolation(p)
        guard let d = s.active else { throw EngineError.noDocument }
        try checkResampleBudget(d.doc, w, h)
        let rasterize = d.doc.walk().contains { e in
            switch e.layer.content {
            case .text, .shape, .fill, .smart: true
            default: false
            }
        }
        guard let map = Transform.quadToRect(q, width: Double(w), height: Double(h)) else { throw bad("the corners don't define a perspective") }
        let bg = s.tools.background
        try AnalysisCommands.compound(s, "Perspective Crop") { s in
            if rasterize { _ = try ExtraCommands.rasterizeAll(s) }
            try s.edit("Perspective Crop") { doc, _ in
                apply(&doc, q, map, (w, h), interp, bg)
                if let r = res { doc.resolutionDpi = r }
            }
        }
        let dpi: JSONValue = s.active.map { .float($0.doc.resolutionDpi) } ?? .null
        return ["width": .int(w), "height": .int(h), "resolution": dpi, "corners": .array(q.map { [.number($0.x), .number($0.y)] })]
    }

    static func register(into r: inout CommandRegistry) {
        r.add(CommandSpec(cmd, "Perspective Crop",
                          params: #"{"corners":[[x,y],[x,y],[x,y],[x,y]] (top-left, top-right, bottom-right, bottom-left; a convex quad, document px),"width":px,"height":px,"resolution":ppi,"interpolation":"bicubic|bilinear|nearest"="bicubic"} → {width,height,resolution,corners} (the quad is mapped onto an upright width x height canvas, all layers, one undo step; no width/height: the quad's mean side lengths, one alone keeps its proportions; type, shape, fill and smart object layers are rasterized)"#,
                          module: m, enabled: Pre.hasDoc, run: perspectiveCrop))
    }
}
