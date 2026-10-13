// Port of photocraft-engine (crates/engine/src/select_extra_cmds.rs: `select_sky`, `transform_selection`), MIT OR Apache-2.0, © ArtCraft Team and the PhotoCraft contributors.
//
// Select › Sky runs PCAlgo's classical sky segmentation (`SelectSky`) on the composite (or the
// active layer) and combines it with the selection. Select › Transform Selection transforms the
// selection mask only (not pixels): a quad (distort / perspective), an affine matrix, scale /
// rotate / skew / move about a reference point, or a warp (the params of `edit.transform.warp`).

import Foundation
import PCAlgo
import PCDocument
import PCFoundation
import PCRender

extension SelectExtraCommands {
    /// The document composite as a segmentation source (photocraft `CompositeSampler`).
    struct CompositeSampler: SegmentSampler {
        let renderer: EngineRenderer
        let doc: Document

        func rgba(_ r: PixelRect) -> [SIMD4<Float>] {
            if r.isEmpty { return [] }
            return (try? renderer.render(doc, region: r).px) ?? [SIMD4<Float>](repeating: .zero, count: r.area)
        }
    }

    // MARK: Sky

    static func selectSky(_ s: Session, _ p: JSONValue) throws -> JSONValue {
        guard let d = s.active else { throw EngineError.noDocument }
        let doc = d.doc
        let canvas = doc.bounds
        let params = SelectSky.Params(threshold: Float(p["threshold"]?.doubleValue ?? 50), softness: Float(p["softness"]?.doubleValue ?? 50))
        let all = p["sampleAllLayers"]?.boolValue ?? true
        let layer = d.activeLayer.flatMap { doc.layer($0) }?.surface
        let region: SelectionRegion?
        if !all, let surf = layer {
            region = SelectSky.select(SurfaceSegmentSampler(surf), canvas: canvas, params)
        } else {
            region = SelectSky.select(CompositeSampler(renderer: s.services.renderer, doc: doc), canvas: canvas, params)
        }
        let ms = p["mode"]?.stringValue ?? "replace"
        let mode = SelectionMode.parse(ms == "new" ? "replace" : ms)
        guard let region else {
            // Photoshop reports "No sky was detected" and leaves the selection alone.
            return ["selected": .bool(doc.selection != nil), "changed": false, "coverage": 0.0, "message": "No sky was detected"]
        }
        let total = region.mask.reduce(0.0) { $0 + Double($1) / 255 }
        let coverage = total / Swift.max(Double(canvas.width) * Double(canvas.height), 1)
        let b = region.bbox
        let selected = try s.edit("Select Sky") { doc, _ -> Bool in
            doc.selection = Selection.combineRegion(doc.selection, region, mode: mode)
            return doc.selection != nil
        }
        return ["selected": .bool(selected), "changed": true, "coverage": .number(coverage),
                "bounds": [.int(Int(b.x0)), .int(Int(b.y0)), .int(b.width), .int(b.height)]]
    }

    // MARK: Transform Selection

    static func num(_ p: JSONValue, _ k: String, _ d: Double) -> Double { p[k]?.doubleValue ?? d }

    static func referencePoint(_ p: JSONValue, _ r: [Double]) -> SIMD2<Double> {
        let (x0, y0, x1, y1) = (r[0], r[1], r[2], r[3])
        let (cx, cy) = ((x0 + x1) / 2, (y0 + y1) / 2)
        switch p["reference"] {
        case .array(let a)? where a.count >= 2:
            return SIMD2(a[0].doubleValue ?? cx, a[1].doubleValue ?? cy)
        case .string(let k)?:
            switch k {
            case "topLeft": return SIMD2(x0, y0)
            case "top": return SIMD2(cx, y0)
            case "topRight": return SIMD2(x1, y0)
            case "left": return SIMD2(x0, cy)
            case "right": return SIMD2(x1, cy)
            case "bottomLeft": return SIMD2(x0, y1)
            case "bottom": return SIMD2(cx, y1)
            case "bottomRight": return SIMD2(x1, y1)
            default: return SIMD2(cx, cy)
            }
        default:
            return SIMD2(cx, cy)
        }
    }

    /// The homography of the scale / rotate / skew / move params about the reference point.
    static func affineParams(_ p: JSONValue, _ r: [Double]) -> Homography {
        let ref = referencePoint(p, r)
        let (sx, sy) = (num(p, "scaleX", 100) / 100, num(p, "scaleY", 100) / 100)
        let a = num(p, "rotate", 0) * (Double.pi / 180)
        let (kx, ky) = (tan(num(p, "skewX", 0) * (Double.pi / 180)), tan(num(p, "skewY", 0) * (Double.pi / 180)))
        let (dx, dy) = (num(p, "dx", num(p, "x", 0)), num(p, "dy", num(p, "y", 0)))
        func t(_ x: Double, _ y: Double) -> Homography { Homography([1, 0, x, 0, 1, y, 0, 0, 1]) }
        let (sa, ca) = (sin(a), cos(a))
        let rot = Homography([ca, -sa, 0, sa, ca, 0, 0, 0, 1])
        let skew = Homography([1, kx, 0, ky, 1, 0, 0, 0, 1])
        let scale = Homography([sx, 0, 0, 0, sy, 0, 0, 0, 1])
        return t(ref.x + dx, ref.y + dy).mul(rot).mul(skew).mul(scale).mul(t(-ref.x, -ref.y))
    }

    static func boundsJSON(_ s: Session) -> JSONValue {
        guard let r = s.active?.doc.selection?.contentBounds else { return .null }
        return [.int(Int(r.x0)), .int(Int(r.y0)), .int(r.width), .int(r.height)]
    }

    static func transformSelection(_ s: Session, _ p: JSONValue) throws -> JSONValue {
        let cmd = "select.transformSelection"
        guard let d = s.active else { throw EngineError.noDocument }
        guard let sel = d.doc.selection else { throw EngineError.other("no selection") }
        let b = sel.contentBounds
        let rect: [Double]
        if let a = p["rect"]?.arrayValue, a.count == 4 {
            rect = a.map { $0.doubleValue ?? 0 }
        } else {
            rect = [Double(b.x0), Double(b.y0), Double(b.x1), Double(b.y1)]
        }
        let interp = Interp(parsing: p["interpolation"]?.stringValue ?? "bilinear")
        if ["warp", "style", "mesh", "grid"].contains(where: { p[$0] != nil }) {
            let i32 = TransformCommands.i32
            let r = PixelRect(x0: i32(rect[0].rounded(.down)), y0: i32(rect[1].rounded(.down)), x1: i32(rect[2].rounded(.up)), y1: i32(rect[3].rounded(.up)))
            let w = try WarpCommands.warpFromParams(cmd, p, WarpCommands.rectF(r))
            if w.isIdentity { return ["changed": false] }
            let map = WarpCommands.mapper(w)
            let selected = try s.edit("Transform Selection") { doc, _ -> Bool in
                if let cur = doc.selection { doc.selection = TransformCommands.nonEmpty(MeshWarp.warpMeshGray(cur, map: map, interp: interp)) }
                return doc.selection != nil
            }
            return ["changed": true, "selected": .bool(selected), "bounds": boundsJSON(s)]
        }
        let h: Homography
        if let q = TransformCommands.quadParam(p, key: p["quad"] != nil ? "quad" : "corners") {
            guard let hh = Homography.rectToQuad(rect, q) else { throw EngineError.bad(cmd, "degenerate quad") }
            h = hh
        } else if let mv = p["matrix"]?.arrayValue {
            let v = mv.compactMap(\.doubleValue)
            guard v.count == 6 else { throw EngineError.bad(cmd, "matrix must be [a, b, c, d, e, f]") }
            h = TransformCommands.matrixHomography(v)
        } else {
            h = affineParams(p, rect)
        }
        if h.inverse() == nil { throw EngineError.bad(cmd, "the transform collapses the selection") }
        if zip(h.m, Homography.identity.m).allSatisfy({ abs($0 - $1) < 1e-12 }) { return ["changed": false, "selected": true] }
        let selected = try s.edit("Transform Selection") { doc, _ -> Bool in
            if let cur = doc.selection { doc.selection = TransformCommands.nonEmpty(TransformCommands.warpGray(cur, h, interp)) }
            return doc.selection != nil
        }
        return ["changed": true, "selected": .bool(selected), "bounds": boundsJSON(s)]
    }
}
