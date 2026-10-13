// Port of photocraft-engine (crates/engine/src/image_cmds.rs: Image Size, `resample_doc`, `rotated_crop`), MIT OR Apache-2.0, © ArtCraft Team and the PhotoCraft contributors.
//
// What the Image menu resamples: Image Size (every resampling method, effects scaled with the
// pixels, resolution only with "none"), the Crop tool's W x H x Resolution target and its rotated
// frame (Image Rotation › Arbitrary + crop in one step). Pixels go through PCAlgo's `Resample`.

import Foundation
import PCAlgo
import PCDocument
import PCFoundation

extension ImageCommands {
    /// Image Size's resampling methods (photocraft `Method`); `none` changes the resolution only.
    enum Method {
        case none
        case filter(Resample)
        /// Photoshop's Automatic: Preserve Details where the image grows, Bicubic Sharper otherwise.
        case automatic
    }

    /// photocraft `parse_resample`: unknown names are Bicubic.
    static func parseResample(_ s: String) -> Method {
        switch s {
        case "none": .none
        case "automatic": .automatic
        case "nearest", "nearestNeighbor": .filter(.nearest)
        case "bilinear": .filter(.bilinear)
        case "bicubicSmoother": .filter(.bicubicSmoother)
        case "bicubicSharper": .filter(.bicubicSharper)
        case "bicubicAutomatic": .filter(.bicubicAutomatic)
        case "lanczos": .filter(.lanczos)
        case "preserveDetails": .filter(.preserveDetails)
        default: .filter(.bicubic)
        }
    }

    /// The largest raster Image Size resamples to: the decoders' default allocation budget.
    static let maxResampleBytes: UInt64 = 8 << 30

    /// Image › Image Size.
    static func imageSize(_ s: Session, _ p: JSONValue) throws -> JSONValue {
        let cmd = "image.imageSize"
        guard let d = s.active else { throw EngineError.noDocument }
        let (ow, oh) = (d.doc.size.width, d.doc.size.height)
        let resample = parseResample(p["resample"]?.stringValue ?? "bicubic")
        let pw = p["width"]?.doubleValue, ph = p["height"]?.doubleValue
        // A missing dimension keeps the aspect ratio.
        let (fw, fh): (Double, Double)
        switch (pw, ph) {
        case let (w?, h?): (fw, fh) = (w, h)
        case let (w?, nil): (fw, fh) = (w, w * Double(oh) / Double(max(ow, 1)))
        case let (nil, h?): (fw, fh) = (h * Double(ow) / Double(max(oh, 1)), h)
        case (nil, nil): (fw, fh) = (Double(ow), Double(oh))
        }
        func side(_ v: Double) -> Int { v.isNaN ? 1 : Int(min(max(v.rounded(), 1), 300_000)) }
        let (nw, nh) = (side(fw), side(fh))
        var resamples = true
        if case .none = resample { resamples = false }
        // Each side may reach 300000 px, but resampling writes real pixels: refuse a canvas whose
        // raster alone would pass the budget, before allocating any of it (#1544).
        if resamples && (nw, nh) != (ow, oh) {
            try checkResampleBudget(cmd, d.doc, nw, nh, ", or turn Resample off to change only the resolution")
        }
        let dpi = p["resolution"]?.doubleValue.map { Float($0) }
        if resamples && (nw, nh) != (ow, oh) {
            // Color Sampler points scale with the pixels (the same map `transformGeometry` applies).
            SamplerMap.set(s, .scale(Double(nw) / Double(max(ow, 1)), Double(nh) / Double(max(oh, 1))))
        }
        try s.edit("Image Size") { doc, _ in
            if let r = dpi { doc.resolutionDpi = min(max(r, 1), 10_000) }
            let filter: Resample
            switch resample {
            case .none: return
            case .filter(let f): filter = f
            case .automatic: filter = nw > ow || nh > oh ? .preserveDetails : .bicubicSharper
            }
            resampleDocument(&doc, nw, nh, filter)
        }
        // The size the document has now: without resampling `width`/`height` are ignored (#1815).
        guard let size = s.active?.doc.size else { throw EngineError.noDocument }
        return ["width": .int(size.width), "height": .int(size.height)]
    }

    /// Refuses to resample `doc` to `nw` x `nh` px when the raster alone would pass the budget,
    /// before allocating any of it (#1544). `hint` ends the message with what the caller can do
    /// instead (photocraft `check_resample_budget`).
    static func checkResampleBudget(_ cmd: String, _ doc: Document, _ nw: Int, _ nh: Int, _ hint: String) throws {
        let bpp = UInt64(max(doc.pixelFormat.bytesPerPixel, 1))
        let px = UInt64(max(nw, 0)).multipliedReportingOverflow(by: UInt64(max(nh, 0)))
        let pixels = px.overflow ? UInt64.max : px.partialValue
        let b = pixels.multipliedReportingOverflow(by: bpp)
        let bytes = b.overflow ? UInt64.max : b.partialValue
        if bytes <= maxResampleBytes { return }
        let mp = pixels / 1_000_000
        let maxMp = maxResampleBytes / bpp / 1_000_000
        throw bad(cmd, "\(nw) x \(nh) px is \(mp) megapixels; resampling at this bit depth is limited to \(maxMp) megapixels. Choose a smaller size\(hint)")
    }

    /// Resamples the whole document (pixels, masks, channels, selection, effects, vectors, guides)
    /// to `nw` x `nh` px with `filter`: the body of Image Size, shared by the Crop tool's W x H x
    /// Resolution mode. Callers check `checkResampleBudget` first (photocraft `resample_doc`).
    static func resampleDocument(_ doc: inout Document, _ nw: Int, _ nh: Int, _ filter: Resample) {
        let (ow, oh) = (doc.size.width, doc.size.height)
        let sx = Double(nw) / Double(max(ow, 1)), sy = Double(nh) / Double(max(oh, 1))
        if abs(sx - 1) < 1e-12 && abs(sy - 1) < 1e-12 { return }
        // Content that reaches the canvas edge keeps it: a Background stays opaque to the border.
        let canvas = PixelRect(x: 0, y: 0, width: ow, height: oh)
        forEachSurface(&doc.layers, masks: true) { surf, isMask in
            surf = Resample.resizeSurfaceInCanvas(surf, sx: sx, sy: sy, filter: isMask ? .bilinear : filter, canvas: canvas)
        }
        let k = Float((sx + sy) / 2)
        forEachLayer(&doc.layers) { LayerMenuCommands.scaleEffects(&$0.effects, k) }
        for i in doc.channels.indices {
            doc.channels[i].surface = Resample.resizeSurfaceInCanvas(doc.channels[i].surface, sx: sx, sy: sy, filter: .bilinear, canvas: canvas)
        }
        if var q = doc.quickMask {
            q.surface = Resample.resizeSurfaceInCanvas(q.surface, sx: sx, sy: sy, filter: .bilinear, canvas: canvas)
            doc.quickMask = q
        }
        if let sel = doc.selection {
            doc.selection = Resample.resizeSurfaceInCanvas(sel, sx: sx, sy: sy, filter: .bilinear, canvas: canvas)
        }
        // Vector geometry, guides and marks scale with the pixels; vectors re-render sharp.
        CanvasGeometry.transformGeometry(&doc, .scale(sx, sy))
        doc.size = PixelSize(width: nw, height: nh)
        CanvasGeometry.refresh(&doc, .all)
    }

    /// The Crop tool's rotated frame: `r` (document px) turned clockwise on screen by `angle`
    /// degrees about its centre. The document is rotated counter-clockwise by `angle` (Image
    /// Rotation › Arbitrary: the canvas grows to fit, the Background fills what the rotation
    /// uncovers with the background colour, other layers keep transparency there and every pixel
    /// of theirs), which makes the frame upright, then cropped to it (`deleteCroppedPixels` as for
    /// an unrotated crop), all in one undo step (photocraft `rotated_crop`).
    static func rotatedCrop(_ s: Session, _ r: PixelRect, _ angle: Double, _ delete: Bool, _ cropTarget: CropTarget) throws -> JSONValue {
        let cmd = "image.crop"
        guard let size = s.active?.doc.size else { throw EngineError.noDocument }
        let (w, h) = (Double(r.width), Double(r.height))
        let (cx, cy) = (Double(r.x0) + w / 2, Double(r.y0) + h / 2)
        // Where the frame's centre lands: the rotation `image.rotation.arbitrary` applies, clockwise
        // by `-angle` (x' = c·x − s·y, y' = s·x + c·y) about the old and new canvas centres.
        let new = ModeCommands.rotatedSize(size, -angle)
        let rad = -angle * (Double.pi / 180)
        let (sn, cs) = (sin(rad), cos(rad))
        let (dx, dy) = (cx - Double(size.width) / 2, cy - Double(size.height) / 2)
        let (ncx, ncy) = (Double(new.width) / 2 + cs * dx - sn * dy, Double(new.height) / 2 + sn * dx + cs * dy)
        let (x, y) = ((ncx - w / 2).rounded(), (ncy - h / 2).rounded())
        let far = bad(cmd, "the rotated frame is outside the 32-bit coordinate range")
        let limit = Double(Int32.max / 2)
        if !(x.isFinite && y.isFinite) || abs(x) > limit || abs(y) > limit { throw far }
        let (xi, yi) = (Int32(x), Int32(y))
        func end(_ o: Int32, _ len: Int) -> Int32? { Int32(exactly: Int64(o) + Int64(len)) }
        guard let x1 = end(xi, r.width), let y1 = end(yi, r.height) else { throw far }
        let target = PixelRect(x0: xi, y0: yi, x1: x1, y1: y1)
        try AnalysisCommands.compound(s, "Crop") { s in
            _ = try ModeCommands.rotateArbitrary(s, ["angle": .number(angle), "direction": "ccw"])
            // Color Sampler points follow the crop's origin shift too (the rotation moved them above).
            SamplerMap.set(s, .translate(-Double(target.x0), -Double(target.y0)))
            let ext = s.tools.background
            try s.edit("Crop") { doc, _ in
                try cropDocument(&doc, cmd, target, deletePixels: delete, extension: ext)
                doc.selection = nil
                cropTarget.apply(&doc)
            }
        }
        return cropResult(s, ["x": .int(Int(r.x0)), "y": .int(Int(r.y0)), "width": .int(r.width), "height": .int(r.height), "angle": .number(angle)])
    }
}
