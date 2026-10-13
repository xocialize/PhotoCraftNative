// Port of photocraft-engine (crates/engine/src/photo_cmds.rs), MIT OR Apache-2.0, © ArtCraft Team and the PhotoCraft contributors.
//
// Computational-photography automation: File › Automate › Photomerge, Merge to HDR Pro and Crop
// and Straighten Photos. The registration and blending code (PCAlgo's `Panorama`, `DirectAlign`,
// `Pyramid`) is shared with Edit › Auto-Align / Auto-Blend Layers (`AlignCommands`).
//
// Inputs are files (`"paths"`: an array or a folder) or, with `"useOpenDocuments": true`, the
// open documents (Photoshop's *Add Open Files*). Each command creates new documents; the sources
// are untouched. Open documents work fully. Files are read through the session's file-system
// service and imported by PCIO (flat images and layered documents alike: PSD/PSB, .pcraft,
// OpenRaster, Paint.NET, Affinity, SVG are flattened like any other source); camera settings come
// from the EXIF the import keeps.

import Foundation
import PCAlgo
import PCDocument
import PCFoundation
import PCPlatform

enum PhotoCommands: CommandModule {
    static let name = "photo_cmds"
    static let m = "photo_cmds"

    /// Longest side used for feature registration.
    static let registerSide = 1200

    /// Wall-clock milliseconds since `t0` (the `ms` fields of results).
    static func ms(since t0: DispatchTime) -> Double {
        Double(DispatchTime.now().uptimeNanoseconds &- t0.uptimeNanoseconds) / 1e6
    }

    static func divCeil(_ a: Int, _ b: Int) -> Int { b > 0 ? (a + b - 1) / b : a }

    // MARK: Sources

    /// One input image, flattened (photocraft `Source`).
    struct Source: Sendable {
        var name: String
        var surf: Surface
        var w: Int
        var h: Int
        var exif: Exif.CameraInfo
    }

    /// photocraft `file_name`.
    static func fileName(_ path: String) -> String { FileCommands.fileName(path) }

    /// Files of a folder that look like images we can open, sorted by name (photocraft
    /// `list_images`), listed through the session's file service.
    static func listImages(_ s: Session, _ dir: String) throws -> [String] { try FileCommands.listImages(s, dir) }

    /// A file as a document (photocraft `read_file` + `import`: every format PCIO reads, layered
    /// documents included) with its camera settings from the EXIF it carries.
    static func importFile(_ s: Session, _ path: String, _ cmd: String) throws -> (String, Document, Exif.CameraInfo) {
        let name = fileName(path)
        let doc = try FileCommands.import(s, name, try FileCommands.readFile(s, path))
        return (name, doc, doc.metadata.exif.map { Exif.read($0) } ?? Exif.CameraInfo())
    }

    /// The sources, their common pixel format and the first source's ICC profile (photocraft
    /// `load_sources`).
    static func loadSources(_ s: Session, _ p: JSONValue, _ cmd: String) throws -> ([Source], PixelFormat, [UInt8]?) {
        var docs: [(String, Document, Exif.CameraInfo)] = []
        if p["useOpenDocuments"]?.boolValue ?? false {
            for d in s.documents {
                docs.append((d.doc.name, d.doc, d.doc.metadata.exif.map { Exif.read($0) } ?? Exif.CameraInfo()))
            }
        }
        let paths: [String]
        switch p["paths"] ?? p["input"] {
        case .array(let a)?: paths = a.compactMap(\.stringValue)
        case .string(let dir)?: paths = try listImages(s, dir)
        default: paths = []
        }
        for path in paths { docs.append(try importFile(s, path, cmd)) }
        guard let first = docs.first?.1 else {
            throw EngineError.bad(cmd, "pass \"paths\" (files or a folder) or \"useOpenDocuments\": true")
        }
        var fmt = first.pixelFormat
        if [.cmyk, .lab, .multichannel].contains(fmt.mode) {
            // Registration and blending work in RGB; like Photoshop, the result is RGB.
            fmt = PixelFormat(mode: .rgb, sample: fmt.sample, alpha: true)
        }
        let icc = first.pixelFormat.mode == fmt.mode ? first.iccProfile : nil
        var out: [Source] = []
        for (name, d, info) in docs {
            let surf = try s.services.renderer.compositeToSurface(d, rect: d.bounds, format: fmt)
            out.append(Source(name: name, surf: surf, w: d.size.width, h: d.size.height, exif: info))
        }
        return (out, fmt, icc)
    }

    // MARK: Registration

    /// Luminance and coverage of `surf` over `area`, box-downsampled by `k` (photocraft `luma_alpha`).
    static func lumaAlpha(_ surf: Surface, _ area: PixelRect, _ k: Int) -> (Int, Int, [Float], [Float]) {
        let fmt = surf.format
        let n = fmt.channels
        let (w, h) = (area.width, area.height)
        let (sw, sh) = (max(divCeil(w, k), 1), max(divCeil(h, k), 1))
        var l = [Float](repeating: 0, count: sw * sh), a = l, cnt = l
        // Row by row keeps memory small for large images.
        for y in 0..<h {
            let row = surf.readRegion(PixelRect(x0: area.x0, y0: area.y0 + Int32(y), x1: area.x1, y1: area.y0 + Int32(y) + 1))
            row.withUnsafeBufferPointer { b in
                for x in 0..<w where (x + 1) * n <= b.count {
                    let q = PixelCodec.toRGBA(fmt, b, x * n)
                    let i = (y / k) * sw + x / k
                    l[i] += (0.2126 * q.x + 0.7152 * q.y + 0.0722 * q.z) * q.w + (1 - q.w) * 0
                    a[i] += q.w
                    cnt[i] += 1
                }
            }
        }
        for i in 0..<(sw * sh) {
            let c = max(cnt[i], 1)
            l[i] = a[i] > 0 ? l[i] / a[i] : 0
            a[i] /= c
        }
        return (sw, sh, l, a)
    }

    /// An alignment (photocraft `panorama::Alignment`; PCAlgo's has no public initializer).
    struct Aligned: Sendable {
        /// The layout actually used (Auto resolved).
        var layout: Panorama.Layout
        var reference: Int
        /// Per image; nil for images that couldn't be connected.
        var placements: [Panorama.Placement?]
        var focal: Double
        var k1: Double
        /// Verified pairs `(a, b, inliers)`.
        var pairs: [(Int, Int, Int)]
        var rms: Double
    }

    /// Registers `images` (surface, content area) and returns full-resolution placements;
    /// `focal35` is the 35 mm-equivalent focal length when known (EXIF) (photocraft `register`).
    static func registerImages(_ images: [(Surface, PixelRect)], _ layout: Panorama.Layout, reference: Int?, geometric: Bool,
                               focal35: Double?) -> Aligned? {
        let side = images.map { max($0.1.width, $0.1.height) }.max() ?? 1
        let k = max(divCeil(side, registerSide), 1)
        let prepared: [Panorama.PreparedImage] = images.map { s, r in
            let (w, h, l, a) = lumaAlpha(s, r, k)
            let valid = a.contains { $0 < 0.5 } ? a.map { $0 > 0.5 } : nil
            return Panorama.PreparedImage(w: w, h: h, luma: l, valid: valid)
        }
        guard let feats = try? Panorama.detectMany(prepared, max: 800) else { return nil }
        let matches = Panorama.matchPairs(feats)
        let focal = focal35.map { $0 / 36 * Double(side) / Double(k) }
        guard let a = Panorama.align(feats, matches: matches, options: Panorama.AlignOptions(layout: layout, focal: focal, reference: reference, geometric: geometric)) else {
            return nil
        }
        let kf = Double(k)
        return Aligned(layout: a.layout, reference: a.reference, placements: a.placements.map { $0?.scaled(kf) }, focal: a.focal * kf,
                       k1: a.k1, pairs: a.pairs, rms: a.rms * kf)
    }

    /// The intensity registration searches planes at most this many pixels across: the pose is
    /// resolution independent, so the fit still applies at full resolution.
    static let directSide = 2048
    /// A layer and its neighbour must share at least this fraction of the plane at the pose found.
    static let directMinOverlap = 0.25
    /// The reference and the warped layer must correlate at least this much: a bracket of one
    /// scene correlates near 1 whatever the exposure; unrelated pictures, or a pose that ran into
    /// the search box, do not.
    static let directMinCorrelation = 0.5

    /// The error of either registration when the layers have no detail in common.
    static let noDetail = "Auto-Align couldn't find enough matching detail between the layers"

    /// Why the intensity registration failed (its message).
    struct DirectFailure: Error {
        var message: String
    }

    /// Registers `images` (surface, content area, all of one size) by intensity (PCAlgo's
    /// `DirectAlign`), for layers that nearly coincide (a focus or exposure bracket, a burst):
    /// outward from the reference, each layer to the previous one aligned, starting from its pose.
    /// The luminance planes are built at the search scale (≤ `directSide` across). A layer whose
    /// best pose overlaps its neighbour too little or explains too little of it is no fit, and
    /// fails with `noDetail`. Planar layouts only; Auto means a similarity (Collage) (photocraft
    /// `register_direct`).
    static func registerDirect(_ images: [(Surface, PixelRect)], _ layout0: Panorama.Layout, _ reference: Int) -> Result<Aligned, DirectFailure> {
        let motion: Panorama.Motion, layout: Panorama.Layout
        switch layout0 {
        case .reposition: (motion, layout) = (.translation, .reposition)
        case .auto, .collage: (motion, layout) = (.similarity, .collage)
        case .perspective: (motion, layout) = (.homography, .perspective)
        case .cylindrical, .spherical:
            return .failure(DirectFailure(message: "the intensity registration supports the auto, perspective, collage and reposition projections"))
        }
        let n = images.count
        guard reference >= 0, reference < n else { return .failure(DirectFailure(message: "no layers to align")) }
        let area = images[reference].1
        let (fw, fh) = (max(area.width, 1), max(area.height, 1))
        if images.contains(where: { $0.1.width != area.width || $0.1.height != area.height }) {
            return .failure(DirectFailure(message: "the layers to align have different sizes"))
        }
        // Luminance at the search scale: the box average over k×k pixels, read row by row.
        let k = max(divCeil(max(fw, fh), directSide), 1)
        let planes: [([Float], [Bool]?)] = images.map { s, r in
            let (_, _, l, a) = lumaAlpha(s, r, k)
            return (l, a.contains { $0 < 0.5 } ? a.map { $0 > 0.5 } : nil)
        }
        let (w, h) = (max(divCeil(fw, k), 1), max(divCeil(fh, k), 1))
        let minOverlap = Int(directMinOverlap * Double(w * h))
        var poses = [DirectAlign.Pose?](repeating: nil, count: n)
        var rmss: [Double] = []
        var pairs: [(Int, Int, Int)] = []
        for dir in [1, -1] {
            var (prevLuma, prevValid) = planes[reference]
            var initial = DirectAlign.Pose.identity
            var i = reference + dir
            while i >= 0 && i < n {
                let (l, v) = planes[i]
                let target = DirectAlign.Plane(w: w, h: h, luma: l, valid: v)
                let reg = DirectAlign.register(reference: DirectAlign.Plane(w: w, h: h, luma: prevLuma, valid: prevValid), target: target,
                                               motion: motion, initial: initial, coarsen: 0)
                if reg.overlap < minOverlap || reg.correlation < directMinCorrelation { return .failure(DirectFailure(message: noDetail)) }
                initial = reg.pose
                let (wl, wv) = DirectAlign.warp(target, pose: reg.pose)
                (prevLuma, prevValid) = (wl, wv)
                pairs.append((i - dir, i, reg.overlap * k * k))
                rmss.append(reg.rms)
                poses[i] = reg.pose
                i += dir
            }
        }
        let center = SIMD2(Double(fw) / 2, Double(fh) / 2)
        let toCenter = Homography([1, 0, center.x, 0, 1, center.y, 0, 0, 1])
        func placement(_ hm: Homography) -> Panorama.Placement {
            Panorama.Placement(projection: .plane, focal: Double(max(fw, fh)), center: center, k1: 0, h: hm.mul(toCenter))
        }
        // The pose is in fractions of the layer: its matrix at full resolution places the layer.
        let placements: [Panorama.Placement?] = (0..<n).map { i in
            i == reference ? placement(.identity) : poses[i].map { placement($0.matrix(width: fw, height: fh)) }
        }
        let rms = rmss.isEmpty ? 0 : rmss.reduce(0, +) / Double(rmss.count)
        return .success(Aligned(layout: layout, reference: reference, placements: placements, focal: 0, k1: 0, pairs: pairs, rms: rms))
    }

    /// The 35 mm focal length agreed by the sources' EXIF (median), if any (photocraft `exif_focal`).
    static func exifFocal(_ srcs: [Source]) -> Double? {
        let f = srcs.compactMap(\.exif.focalLength35mm).sorted()
        return f.isEmpty ? nil : f[f.count / 2]
    }

    // MARK: Blending

    /// Splits a surface region into colour channels and coverage (photocraft `roi_of`).
    static func roiOf(_ surf: Surface, _ area: PixelRect) -> Panorama.RoiImage {
        let fmt = surf.format
        let n = fmt.channels
        let cc = fmt.mode.colorChannels
        let raw = surf.readRegion(area)
        let (w, h) = (area.width, area.height)
        var px: [Float] = []
        px.reserveCapacity(w * h * cc)
        var alpha: [Float] = []
        alpha.reserveCapacity(w * h)
        for o in stride(from: 0, to: raw.count - n + 1, by: n) {
            px.append(contentsOf: raw[o..<(o + cc)])
            alpha.append(fmt.alpha ? raw[o + n - 1] : 1)
        }
        return Panorama.RoiImage(x0: area.x0, y0: area.y0, w: w, h: h, ch: cc, px: px, alpha: alpha)
    }

    /// Placements, source sizes and the panorama offset (for vignette removal).
    typealias BlendGeometry = ([Panorama.Placement], [(Int, Int)], SIMD2<Double>)

    /// Result of `seamBlend`: per input, the pixels to keep (blended inside its seam region) and
    /// its mask; plus the blended composite (photocraft `Blended`).
    struct Blended: Sendable {
        var layers: [(Surface, Surface)]
        var composite: Surface
        var gains: [[Float]]
        var vignette: [Double]
    }

    static func clampData(_ v: Float, _ fmt: PixelFormat) -> Float { fmt.sample == .f32 ? v : min(max(v, 0), 1) }

    /// Gain compensation (+ optional vignetting), seams in `order`, multi-band blending. Inputs are
    /// surfaces already in panorama coordinates with alpha. `geometry` enables vignette removal
    /// (photocraft `seam_blend`).
    static func seamBlend(_ warped: [Surface], _ canvas: PixelRect, _ order: [Int], seamless: Bool, gains: Bool,
                          _ geometry: BlendGeometry?) throws -> Blended {
        let n = warped.count
        let fmt = warped.first?.format ?? .rgba8
        var rois: [Panorama.RoiImage] = warped.map { s in
            let b = s.contentBounds.intersect(canvas)
            return b.isEmpty ? Panorama.RoiImage(x0: 0, y0: 0, w: 0, h: 0, ch: fmt.mode.colorChannels, px: [], alpha: []) : roiOf(s, b)
        }
        // Photometric model in panorama coordinates relative to the canvas origin used by placements.
        let geo: ([Panorama.Placement], [(Int, Int)])? = geometry.map { pl, sizes, off in (pl.map { $0.translated(off.x, off.y) }, sizes) }
        let photo = Panorama.photometric(rois, geometry: geo, gain: seamless && gains, vignette: geo != nil)
        let vig = photo.vignette != [0, 0]
        for i in rois.indices {
            if photo.gains[i].allSatisfy({ abs($0 - 1) < 1e-6 }) && !vig { continue }
            var roi = rois[i]
            let ch = roi.ch
            for y in 0..<roi.h {
                for x in 0..<roi.w {
                    var r2 = 0.0
                    if vig, let (pl, sizes) = geo {
                        if let (sx, sy) = pl[i].inverse(Double(roi.x0 + Int32(x)) + 0.5, Double(roi.y0 + Int32(y)) + 0.5) {
                            let (w, h) = (Double(sizes[i].0), Double(sizes[i].1))
                            let (dx, dy) = (sx - w / 2, sy - h / 2)
                            r2 = (dx * dx + dy * dy) / (w * w / 4 + h * h / 4)
                        }
                    }
                    let k = y * roi.w + x
                    for c in 0..<ch {
                        let f = photo.factor(i, c, r2)
                        var v = roi.px[k * ch + c]
                        v = fmt.mode == .cmyk ? 1 - (1 - v) * f : v * f
                        if fmt.sample != .f32 { v = min(max(v, 0), 1) }
                        roi.px[k * ch + c] = v
                    }
                }
            }
            rois[i] = roi
        }
        // Seams on a ≤ 1000 px grid.
        let (cw, chh) = (max(canvas.width, 1), max(canvas.height, 1))
        let s = max(divCeil(max(cw, chh), 1000), 1)
        let (gw, gh) = (divCeil(cw, s), divCeil(chh, s))
        var luma = [[Float]](repeating: [Float](repeating: 0, count: gw * gh), count: n)
        var cover = [[Bool]](repeating: [Bool](repeating: false, count: gw * gh), count: n)
        for (i, roi) in rois.enumerated() {
            var accL = [Float](repeating: 0, count: gw * gh), accA = accL
            var accN = [UInt32](repeating: 0, count: gw * gh)
            for y in 0..<roi.h {
                for x in 0..<roi.w {
                    let (u, v) = (Int(roi.x0 - canvas.x0) + x, Int(roi.y0 - canvas.y0) + y)
                    let g = min(v / s, gh - 1) * gw + min(u / s, gw - 1)
                    let k = y * roi.w + x
                    var l: Float = 0
                    for c in 0..<roi.ch { l += roi.px[k * roi.ch + c] }
                    accL[g] += l / Float(roi.ch)
                    accA[g] += roi.alpha[k]
                    accN[g] += 1
                }
            }
            for g in 0..<(gw * gh) where accN[g] > 0 {
                luma[i][g] = accL[g] / Float(accN[g])
                cover[i][g] = accA[g] / Float(s * s) > 0.98
            }
        }
        let labels = Panorama.seamLabels(width: gw, height: gh, luma: luma, cover: cover, order: order)
        // Full-resolution weights: the seam label, falling back to the earliest covering image in
        // `order` where the label's image doesn't cover the pixel.
        var rank = [Int](repeating: Int.max, count: n)
        for (k, i) in order.enumerated() where i >= 0 && i < n { rank[i] = k }
        func alphaAt(_ j: Int, _ x: Int32, _ y: Int32) -> Float {
            let r = rois[j]
            let (lx, ly) = (Int(x) - Int(r.x0), Int(y) - Int(r.y0))
            return lx < 0 || ly < 0 || lx >= r.w || ly >= r.h ? 0 : r.alpha[ly * r.w + lx]
        }
        let weights: [[Float]] = rois.enumerated().map { i, roi in
            (0..<(roi.w * roi.h)).map { k in
                let (x, y) = (roi.x0 + Int32(k % roi.w), roi.y0 + Int32(k / roi.w))
                if roi.alpha[k] < 0.5 { return 0 }
                let (u, v) = (Int(x - canvas.x0), Int(y - canvas.y0))
                let lab = Int(labels[min(v / s, gh - 1) * gw + min(u / s, gw - 1)])
                if lab == i { return 1 }
                if lab >= 0 && lab < n && alphaAt(lab, x, y) >= 0.5 { return 0 }
                // Fallback: the earliest covering image wins.
                var first: Int?
                for j in 0..<n where alphaAt(j, x, y) >= 0.5 {
                    if first.map({ rank[j] < rank[$0] }) ?? true { first = j }
                }
                return first == i ? 1 : 0
            }
        }
        // Shift ROIs to canvas-relative coordinates for the blend.
        let local = rois.map { r in Panorama.RoiImage(x0: r.x0 - canvas.x0, y0: r.y0 - canvas.y0, w: r.w, h: r.h, ch: r.ch, px: r.px, alpha: r.alpha) }
        let levels = seamless ? min(Panorama.blendLevels(width: cw, height: chh), 7) : 1
        let (blend, cov) = try Panorama.multiband(width: cw, height: chh, images: local, weights: weights, levels: levels)
        let cc = fmt.mode.colorChannels
        let nch = fmt.channels
        var composite = Surface(format: fmt)
        var data = [Float](repeating: 0, count: cw * chh * nch)
        for i in 0..<(cw * chh) {
            for c in 0..<cc { data[i * nch + c] = clampData(blend[i * cc + c], fmt) }
            data[i * nch + nch - 1] = cov[i]
        }
        composite.writeRegion(PixelRect(x0: canvas.x0, y0: canvas.y0, x1: canvas.x0 + Int32(cw), y1: canvas.y0 + Int32(chh)), data)
        composite.prune()
        let layers: [(Surface, Surface)] = zip(rois, weights).map { roi, wt in
            let area = PixelRect(x0: roi.x0, y0: roi.y0, x1: roi.x0 + Int32(roi.w), y1: roi.y0 + Int32(roi.h))
            var px = [Float](repeating: 0, count: roi.w * roi.h * nch)
            var mask = [Float](repeating: 0, count: roi.w * roi.h)
            for k in 0..<(roi.w * roi.h) {
                let (u, v) = (Int(roi.x0 - canvas.x0) + k % roi.w, Int(roi.y0 - canvas.y0) + k / roi.w)
                let g = v * cw + u
                let inside = wt[k] > 0.5
                for c in 0..<cc { px[k * nch + c] = inside && seamless ? clampData(blend[g * cc + c], fmt) : roi.px[k * cc + c] }
                px[k * nch + nch - 1] = roi.alpha[k]
                mask[k] = wt[k]
            }
            var ls = Surface(format: fmt)
            if !area.isEmpty { ls.writeRegion(area, px) }
            ls.prune()
            var ms = Surface(format: .gray8, defaultPixel: [0])
            if !area.isEmpty { ms.writeRegion(area, mask) }
            ms.prune()
            return (ls, ms)
        }
        return Blended(layers: layers, composite: composite, gains: photo.gains, vignette: photo.vignette)
    }

    /// Seam order: the reference first, then by distance of each image's centre from it
    /// (photocraft `seam_order`).
    static func seamOrder(_ warped: [Surface], _ reference: Int) -> [Int] {
        guard !warped.isEmpty else { return [] }
        func centre(_ s: Surface) -> (Double, Double) {
            let b = s.contentBounds
            return (Double(Int(b.x0) + Int(b.x1)) / 2, Double(Int(b.y0) + Int(b.y1)) / 2)
        }
        let rc = centre(warped[min(max(reference, 0), warped.count - 1)])
        let dist = warped.map { s -> Double in
            let c = centre(s)
            return hypot(c.0 - rc.0, c.1 - rc.1)
        }
        return Array(warped.indices).sorted { a, b in
            let (ra, rb) = (a != reference, b != reference)
            if ra != rb { return !ra }
            if dist[a] != dist[b] { return dist[a] < dist[b] }
            return a < b
        }
    }

    // MARK: Photomerge

    static func photomerge(_ s: Session, _ p: JSONValue) throws -> JSONValue {
        let cmd = "file.automate.photomerge"
        let t0 = DispatchTime.now()
        let layoutName = p["layout"]?.stringValue ?? "auto"
        guard let layout = Panorama.Layout(parsing: layoutName) else {
            throw EngineError.bad(cmd, "unknown layout `\(layoutName)` (auto|perspective|cylindrical|spherical|collage|reposition)")
        }
        let blend = p["blend"]?.boolValue ?? true
        let vignette = p["vignetteRemoval"]?.boolValue ?? false
        let geometric = p["geometricCorrection"]?.boolValue ?? false
        let fill = p["contentAwareFill"]?.boolValue ?? false
        let (srcs, fmt, icc) = try loadSources(s, p, cmd)
        if srcs.count < 2 { throw EngineError.bad(cmd, "Photomerge needs two or more images") }
        let focalParam = p["focalLength"]?.doubleValue.flatMap { $0 > 0 ? $0 : nil }
        let docName = "Untitled_Panorama\(s.documents.count + 1)"
        // A background job when started in the background (#210): alignment, warping and blending
        // run on a worker, checking for cancellation between stages and images.
        return try s.runJob("Photomerge", lockDocument: false, work: { ctx -> PhotomergeOutput in
            ctx.progress(0, "Photomerge: aligning images")
            let focal35 = focalParam ?? exifFocal(srcs)
            let images = srcs.map { ($0.surf, PixelRect(x: 0, y: 0, width: $0.w, height: $0.h)) }
            guard let al = registerImages(images, layout, reference: nil, geometric: geometric, focal35: focal35) else {
                throw EngineError.other("Photomerge couldn't find enough matching detail between the images")
            }
            let tReg = ms(since: t0) / 1000
            try ctx.check()
            ctx.progress(0.35, "Photomerge: warping images")
            let placed = srcs.indices.filter { $0 < al.placements.count && al.placements[$0] != nil }
            // Parallel to `placed`.
            let placements = placed.compactMap { al.placements[$0] }
            let failed = srcs.indices.filter { !placed.contains($0) }.map { srcs[$0].name }
            // Canvas: union of the placed images.
            var (x0, y0, x1, y1) = (Double.greatestFiniteMagnitude, Double.greatestFiniteMagnitude, -Double.greatestFiniteMagnitude, -Double.greatestFiniteMagnitude)
            for (i, pl) in zip(placed, placements) {
                let b = pl.bounds(Double(srcs[i].w), Double(srcs[i].h))
                x0 = min(x0, b[0]); y0 = min(y0, b[1]); x1 = max(x1, b[2]); y1 = max(y1, b[3])
            }
            let (cw, ch) = ((x1 - x0).rounded(.up), (y1 - y0).rounded(.up))
            if !(cw.isFinite && ch.isFinite) || cw > 30_000 || ch > 30_000 || cw * ch > 6.0e8 {
                throw EngineError.other("the panorama would be \(BrushCommands.rustDisplay(cw))×\(BrushCommands.rustDisplay(ch)) px; try another layout")
            }
            let canvas = PixelRect(x: 0, y: 0, width: Int(cw), height: Int(ch))
            let offset = SIMD2(-x0.rounded(.down), -y0.rounded(.down))
            var warped: [Surface] = []
            for (k, (i, pl)) in zip(placed, placements).enumerated() {
                try ctx.check()
                ctx.progress(0.35 + 0.25 * Float(k) / Float(max(placed.count, 1)), "")
                warped.append(Panorama.warpPlaced(srcs[i].surf, rect: PixelRect(x: 0, y: 0, width: srcs[i].w, height: srcs[i].h), origin: .zero,
                                                  placement: pl, offset: offset, interp: .bicubic))
            }
            let tWarp = ms(since: t0) / 1000
            try ctx.check()
            ctx.progress(0.6, "Photomerge: blending images")
            var doc = Document(name: docName, size: PixelSize(width: Int(cw), height: Int(ch)), mode: fmt.mode, depth: fmt.sample)
            doc.iccProfile = icc
            var info: JSONValue = [:]
            let refPos = placed.firstIndex(of: al.reference) ?? 0
            if blend {
                let sizes = placed.map { (srcs[$0].w, srcs[$0].h) }
                let order = seamOrder(warped, refPos)
                let geo: BlendGeometry? = vignette ? (placements, sizes, offset) : nil
                let b = try seamBlend(warped, canvas, order, seamless: true, gains: true, geo)
                for (k, (px, mask)) in b.layers.enumerated() {
                    var l = Layer(name: srcs[placed[k]].name, content: .raster(px))
                    var m = LayerMask.hideAll()
                    m.surface = mask
                    l.mask = m
                    doc.layers.append(l)
                }
                info = ["gains": .array(b.gains.map { .floats($0) }), "vignette": .doubles(b.vignette)]
                try ctx.check()
                if fill {
                    ctx.progress(0.85, "Photomerge: filling edges")
                    doc.layers.append(Layer(name: "Content-Aware Fill", content: .raster(contentAwareFill(b.composite, canvas))))
                }
            } else {
                for (k, px) in warped.enumerated() { doc.layers.append(Layer(name: srcs[placed[k]].name, content: .raster(px))) }
            }
            let n = doc.layers.count
            try ctx.check()
            ctx.progress(1, "")
            let maxSide = srcs.map { max($0.w, $0.h) }.max() ?? 1
            let result: JSONValue = [
                "document": .null,
                "layout": .string(al.layout.name),
                "reference": .string(al.reference < srcs.count ? srcs[al.reference].name : ""),
                "focalLength35": .number(al.focal / Double(maxSide) * 36),
                "geometricK1": .number(al.k1),
                "rms": .number(al.rms),
                "pairs": .array(al.pairs.map { [.int($0.0), .int($0.1), .int($0.2)] }),
                "placed": .strings(placed.map { srcs[$0].name }),
                "failed": .strings(failed),
                "width": .int(Int(cw)),
                "height": .int(Int(ch)),
                "layers": .int(n),
                "photometric": info,
                "ms": ["register": .number(tReg * 1000), "warp": .number((tWarp - tReg) * 1000), "total": .number(ms(since: t0))],
            ]
            return PhotomergeOutput(doc: doc, info: result)
        }, apply: { s, out, _ in
            out.info.setting("document", .int(s.addDocument(out.doc)))
        })
    }

    /// A finished panorama and its result, carried from the job's worker.
    struct PhotomergeOutput: Sendable {
        var doc: Document
        var info: JSONValue
    }

    /// Fills the transparent areas of a composite (inside its bounding rectangle) with content-aware
    /// fill, at a reduced scale for large panoramas (photocraft `content_aware_fill`).
    static func contentAwareFill(_ comp: Surface, _ canvas: PixelRect) -> Surface {
        let fmt = comp.format
        let n = fmt.channels
        let (w, h) = (canvas.width, canvas.height)
        let k = max(Int((Double(w * h) / 1.5e6).squareRoot().rounded(.up)), 1)
        let (sw, sh) = (divCeil(w, k), divCeil(h, k))
        let full = comp.readRegion(canvas)
        let cc = n - 1
        guard cc > 0, sw > 0, sh > 0, full.count == w * h * n else { return comp }
        var small = [Float](repeating: 0, count: sw * sh * cc)
        var hole = [Bool](repeating: false, count: sw * sh)
        var accA = [Float](repeating: 0, count: sw * sh), cnt = accA
        for y in 0..<h {
            for x in 0..<w {
                let i = (y / k) * sw + x / k
                let o = (y * w + x) * n
                let a = full[o + cc]
                for c in 0..<cc { small[i * cc + c] += full[o + c] * a }
                accA[i] += a
                cnt[i] += 1
            }
        }
        for i in 0..<(sw * sh) {
            let a = accA[i]
            for c in 0..<cc { small[i * cc + c] = a > 0 ? small[i * cc + c] / a : 0 }
            hole[i] = a / max(cnt[i], 1) < 0.99
        }
        let source = hole.map { !$0 }
        let filled = InpaintKit.fill(width: sw, height: sh, channels: cc, image: small, hole: hole, source: source)
        var out = [Float](repeating: 0, count: w * h * n)
        for y in 0..<h {
            for x in 0..<w {
                let o = (y * w + x) * n
                let a = full[o + cc]
                // Bilinear upsampling of the fill under partially covered pixels.
                let fx = min(max((Float(x) + 0.5) / Float(k) - 0.5, 0), Float(sw - 1))
                let fy = min(max((Float(y) + 0.5) / Float(k) - 0.5, 0), Float(sh - 1))
                let (xi, yi) = (Int(fx), Int(fy))
                let (x2, y2) = (min(xi + 1, sw - 1), min(yi + 1, sh - 1))
                let (tx, ty) = (fx - Float(xi), fy - Float(yi))
                for c in 0..<cc {
                    func at(_ xx: Int, _ yy: Int) -> Float { filled[(yy * sw + xx) * cc + c] }
                    let fv = (at(xi, yi) * (1 - tx) + at(x2, yi) * tx) * (1 - ty) + (at(xi, y2) * (1 - tx) + at(x2, y2) * tx) * ty
                    out[o + c] = full[o + c] * a + fv * (1 - a)
                }
                out[o + cc] = 1
            }
        }
        var s = Surface(format: fmt)
        s.writeRegion(canvas, out)
        s.prune()
        return s
    }

    // MARK: Merge to HDR Pro

    static func shiftRGBA(_ px: [SIMD4<Float>], _ w: Int, _ h: Int, _ dx: Int, _ dy: Int) -> [SIMD4<Float>] {
        (0..<(w * h)).map { i in
            let (x, y) = (i % w - dx, i / w - dy)
            return px[min(max(y, 0), h - 1) * w + min(max(x, 0), w - 1)]
        }
    }

    static func mergeToHdr(_ s: Session, _ p: JSONValue) throws -> JSONValue {
        let cmd = "file.automate.mergeToHdrPro"
        let t0 = DispatchTime.now()
        let (srcs, _, icc) = try loadSources(s, p, cmd)
        if srcs.count < 2 { throw EngineError.bad(cmd, "Merge to HDR Pro needs two or more exposures") }
        let (w, h) = (srcs[0].w, srcs[0].h)
        if srcs.contains(where: { $0.w != w || $0.h != h }) { throw EngineError.other("the exposures must have the same pixel dimensions") }
        let area = PixelRect(x: 0, y: 0, width: w, height: h)
        var imgs = srcs.map { $0.surf.readRGBA(area) }
        // Exposures: explicit EV, EXIF, or estimated.
        let exposures: [Double], source: String
        switch p["exposures"]?.arrayValue {
        case let a? where a.count == srcs.count:
            (exposures, source) = (a.map { pow(2, $0.doubleValue ?? 0) }, "params")
        case _?:
            throw EngineError.bad(cmd, "`exposures` needs one EV value per image")
        case nil:
            let fromExif = srcs.compactMap(\.exif.exposureFactor)
            if fromExif.count == srcs.count {
                (exposures, source) = (fromExif, "exif")
            } else {
                (exposures, source) = (ToneKit.estimateExposures(imgs), "estimated")
            }
        }
        if exposures.contains(where: { !($0.isFinite && $0 > 0) }) { throw EngineError.bad(cmd, "exposures must be positive") }
        // Alignment (Ward's MTB) to the middle exposure, on a downsampled grey copy.
        let order = srcs.indices.sorted { a, b in exposures[a] != exposures[b] ? exposures[a] < exposures[b] : a < b }
        let mid = order[order.count / 2]
        var offsets = [(Int, Int)](repeating: (0, 0), count: srcs.count)
        if p["align"]?.boolValue ?? true {
            let k = max(divCeil(max(w, h), 1536), 1)
            func grey(_ im: [SIMD4<Float>]) -> (Int, Int, [Float]) {
                let (sw, sh) = (divCeil(w, k), divCeil(h, k))
                var g = [Float](repeating: 0, count: sw * sh), c = g
                for (i, q) in im.enumerated() {
                    let j = (i / w / k) * sw + (i % w) / k
                    g[j] += (54 * q.x + 183 * q.y + 19 * q.z) / 256
                    c[j] += 1
                }
                return (sw, sh, zip(g, c).map { $0 / max($1, 1) })
            }
            let (sw, sh, gref) = grey(imgs[mid])
            for i in srcs.indices where i != mid {
                let (_, _, gi) = grey(imgs[i])
                let (dx, dy) = ToneKit.mtbOffset(w: sw, h: sh, reference: gref, image: gi, levels: 5)
                offsets[i] = (Int(dx) * k, Int(dy) * k)
                if offsets[i] != (0, 0) { imgs[i] = shiftRGBA(imgs[i], w, h, offsets[i].0, offsets[i].1) }
            }
        }
        let ghostBase = p["ghostBase"]?.uint64Value.map { Int(clamping: $0) }
        if let g = ghostBase, g >= srcs.count { throw EngineError.bad(cmd, "`ghostBase` is an image index") }
        let merged: HDRMerged
        do {
            merged = try ToneKit.mergeHDR(w: w, h: h, images: imgs,
                                          options: HDRMergeOptions(exposures: exposures, removeGhosts: p["removeGhosts"]?.boolValue ?? false,
                                                                   ghostBase: ghostBase, response: nil))
        } catch { throw EngineError.wrap(error) }
        let mode: String
        switch p["mode"] {
        case .string(let v)?: mode = v
        case let v? where v.uint64Value != nil: mode = String(v.uint64Value ?? 0)
        default: mode = "32"
        }
        let depth: SampleType
        var px: [SIMD4<Float>]
        switch mode {
        case "32":
            (depth, px) = (.f32, merged.px)
        case "16", "8":
            let method = p["method"]?.stringValue ?? "localAdaptation"
            func f(_ k: String, _ d: Double) -> Float { Float(p[k]?.doubleValue ?? d) }
            func clamp(_ v: Float, _ lo: Float, _ hi: Float) -> Float { min(max(v, lo), hi) }
            let tm: HDRToneMethod
            switch method {
            case "localAdaptation":
                tm = .localAdaptation(HdrToning(radius: clamp(f("radius", 7), 1, 500), strength: clamp(f("strength", 0.52), 0.1, 4),
                                                gamma: clamp(f("gamma", 1), 0.1, 2), exposure: clamp(f("exposure", 0), -5, 5),
                                                detail: clamp(f("detail", 30), -100, 300), shadow: clamp(f("shadow", 0), -100, 100),
                                                highlight: clamp(f("highlight", 0), -100, 100), vibrance: clamp(f("vibrance", 0), -100, 100),
                                                saturation: clamp(f("saturation", 20), -100, 100), curve: []))
            case "exposureGamma": tm = .exposureGamma(exposure: f("exposure", 0), gamma: f("gamma", 1))
            case "highlightCompression": tm = .highlightCompression
            case "equalizeHistogram": tm = .equalizeHistogram
            case let other:
                throw EngineError.bad(cmd, "unknown method `\(other)` (localAdaptation|exposureGamma|highlightCompression|equalizeHistogram)")
            }
            var v = merged.px
            ToneKit.toneMap(&v, w: w, h: h, method: tm)
            (depth, px) = (mode == "16" ? .u16 : .u8, v)
        case let other:
            throw EngineError.bad(cmd, "`mode` must be 32|16|8, not \(other)")
        }
        for i in px.indices { px[i].w = 1 }
        var doc = Document(name: "Untitled_HDR\(s.documents.count + 1)", size: PixelSize(width: w, height: h), mode: .rgb, depth: depth)
        doc.iccProfile = depth == .f32 ? [UInt8](BuiltinProfile.linearSRGB.profile.data) : icc
        let fmt = doc.pixelFormat
        var surf = Surface(format: fmt)
        surf.writeRegion(area, PixelCodec.fromRGBA(fmt, rgba: px))
        doc.layers.append(Layer(name: "Background", content: .raster(surf)))
        let idx = s.addDocument(doc)
        let ev0 = exposures[order[0]]
        return [
            "document": .int(idx),
            "mode": .string(mode),
            "exposureSource": .string(source),
            "ev": .doubles(exposures.map { log2($0 / ev0) }),
            "offsets": .array(offsets.map { [.int($0.0), .int($0.1)] }),
            "ghostBase": .int(merged.ghostBase),
            "ghostFraction": .number(merged.ghostFraction),
            "stops": .number(merged.stops),
            "ms": .number(ms(since: t0)),
        ]
    }

    // MARK: Crop and Straighten Photos

    static func cropAndStraighten(_ s: Session, _ p: JSONValue) throws -> JSONValue {
        guard let st = s.active else { throw EngineError.noDocument }
        let doc = st.doc
        let fmt = doc.pixelFormat
        let area = doc.bounds
        let flat = try s.services.renderer.compositeToSurface(doc, rect: area, format: fmt)
        let (w, h) = (area.width, area.height)
        // Transparent pixels count as background.
        let rgba = flat.readRGBA(area).map { q -> SIMD4<Float> in
            guard q.w < 1 else { return q }
            let a = q.w
            return SIMD4(q.x * a + (1 - a), q.y * a + (1 - a), q.z * a + (1 - a), q.w)
        }
        let found = ScanCrop.findPhotos(width: w, height: h, rgba: rgba)
        if found.isEmpty { throw EngineError.other("no photos found on a uniform background") }
        var out: [JSONValue] = []
        for (k, f) in found.enumerated() {
            let (pw, ph) = (Int(max(f.width.rounded(), 1)), Int(max(f.height.rounded(), 1)))
            guard let hm = Homography.rectToQuad([0, 0, Double(pw), Double(ph)], f.corners())?.inverse() else { continue }
            let warped = Transform.warpSurface(flat, srcRect: area, h: hm, interp: .bicubic)
            let keep = PixelRect(x: 0, y: 0, width: pw, height: ph)
            var px = Surface(format: fmt)
            // Opaque, like a scanned print.
            let n = fmt.channels
            var data = warped.readRegion(keep)
            if warped.format.channels == n {
                for o in stride(from: n - 1, to: data.count, by: n) { data[o] = 1 }
            } else {
                data = PixelCodec.fromRGBA(fmt, rgba: warped.readRGBA(keep).map { SIMD4($0.x, $0.y, $0.z, 1) })
            }
            px.writeRegion(keep, data)
            var nd = Document(name: "\(doc.name) copy \(k + 1)", size: PixelSize(width: pw, height: ph), mode: doc.mode, depth: doc.depth)
            nd.iccProfile = doc.iccProfile
            nd.resolutionDpi = doc.resolutionDpi
            var bg = Layer(name: "Background", content: .raster(px))
            bg.locks.transparency = true
            bg.locks.position = true
            nd.layers.append(bg)
            let idx = s.addDocument(nd)
            out.append(["document": .int(idx), "width": .int(pw), "height": .int(ph), "angle": .number(f.angle), "center": .doubles([f.center.x, f.center.y])])
        }
        return ["photos": .array(out)]
    }

    // MARK: Registration

    static func register(into r: inout CommandRegistry) {
        r.add([
            CommandSpec("file.automate.photomerge", "Photomerge…", menu: ["File", "Automate"],
                        params: #"{"paths":[str]|folder,"useOpenDocuments":bool=false,"layout":"auto|perspective|cylindrical|spherical|collage|reposition","blend":bool=true,"vignetteRemoval":bool=false,"geometricCorrection":bool=false,"contentAwareFill":bool=false,"focalLength":mm=0 (35 mm equivalent; 0 = EXIF or estimated)} → new document, one masked layer per image"#,
                        module: m, enabled: Pre.always, run: photomerge),
            CommandSpec("file.automate.mergeToHdrPro", "Merge to HDR Pro…", menu: ["File", "Automate"],
                        params: #"{"paths":[str]|folder,"useOpenDocuments":bool=false,"exposures":[ev]? (default EXIF, else estimated),"align":bool=true,"removeGhosts":bool=false,"ghostBase":int?,"mode":"32|16|8","method":"localAdaptation|exposureGamma|highlightCompression|equalizeHistogram","radius":1..500=7,"strength":0.1..4=0.52,"gamma":0.1..2=1,"exposure":-5..5=0,"detail":-100..300=30,"shadow":-100..100=0,"highlight":-100..100=0,"vibrance":-100..100=0,"saturation":-100..100=20} → new document (32-bit linear, or tone-mapped 16/8-bit)"#,
                        module: m, enabled: Pre.always, run: mergeToHdr),
            CommandSpec("file.automate.cropAndStraightenPhotos", "Crop and Straighten Photos", menu: ["File", "Automate"],
                        params: "{} → one new document per photo found on the scan", module: m, enabled: Pre.hasDoc, run: cropAndStraighten),
        ])
    }
}
