// Port of photocraft-engine (crates/engine/src/edit_menu_cmds.rs: Content-Aware Scale, `ContentAwareScalePreview`), MIT OR Apache-2.0, © ArtCraft Team and the PhotoCraft contributors.
//
// Edit › Content-Aware Scale: the active pixel layer's content (or the selection's bounds) seam
// carved to a new size (PCAlgo's `SeamCarving`), steered by an alpha channel and/or skin tones,
// blended with a plain resample by Amount, placed at `x`/`y`. A background job when started in
// the background: the carving checks for cancellation before every seam. The transform box's live
// preview runs the same carving on a reduced copy (`ContentAwareScalePreview`).

import Foundation
import PCAlgo
import PCDocument
import PCFoundation

extension EditMenuCommands {
    /// How far from the origin Content-Aware Scale may place its result (px).
    static let casPositionLimit = 300_000.0

    /// What Content-Aware Scale does, read from its params against the active document: the
    /// command and the transform box's live preview share it (photocraft `CasPlan`).
    struct CasPlan: Sendable {
        var doc: Document
        var layer: LayerId
        /// The area scaled: the selection's bounds, else the layer's content.
        var region: PixelRect
        /// Where the result goes: `x`, `y` (default: the region's corner), `width`, `height`.
        var dst: PixelRect
        var amount: Float
        var protect: Surface?
        var skinTones: Bool
    }

    /// The surface of an alpha channel named by index or name (photocraft `channel_mask`).
    static func channelMask(_ doc: Document, _ v: JSONValue) -> Surface? {
        if let name = v.stringValue { return doc.channels.first { $0.name == name }?.surface }
        guard let i = v.uint64Value, i < UInt64(doc.channels.count) else { return nil }
        return doc.channels[Int(i)].surface
    }

    /// photocraft `cas_plan`.
    static func casPlan(_ s: Session, _ p: JSONValue) throws -> CasPlan {
        let cmd = "edit.contentAwareScale"
        let id = try pixelLayer(s).get()
        guard let st = s.active else { throw EngineError.noDocument }
        let doc = st.doc
        guard let surf = doc.layer(id)?.surface else { throw EngineError.noLayer(id) }
        let region = doc.selection.map { $0.contentBounds.intersect(doc.bounds) } ?? surf.contentBounds
        if region.isEmpty { throw EngineError.other("nothing to scale: the layer is empty") }
        let (w, h) = (region.width, region.height)
        func dim(_ k: String, _ pct: String, _ cur: Int) throws -> Int {
            let v: Double
            switch (p[k]?.doubleValue, p[pct]?.doubleValue) {
            case (let px?, _): v = px
            case (nil, let pc?): v = Double(cur) * pc / 100
            case (nil, nil): v = Double(cur)
            }
            if !(v >= 1 && v <= 60_000) { throw EngineError.bad(cmd, "`\(k)` must be 1..60000 px") }
            return Int(v.rounded())
        }
        let (nw, nh) = (try dim("width", "scaleX", w), try dim("height", "scaleY", h))
        func at(_ k: String, _ cur: Int32) throws -> Int32 {
            guard let v = p[k], v != .null else { return cur }
            guard let x = v.doubleValue, x >= -casPositionLimit, x <= casPositionLimit else {
                throw EngineError.bad(cmd, "`\(k)` must be a number of px within ±300000")
            }
            return Int32(x.rounded())
        }
        let dst = PixelRect(x: Int(try at("x", region.x0)), y: Int(try at("y", region.y0)), width: nw, height: nh)
        let raw = Float(p["amount"]?.doubleValue ?? 100)
        let amount = raw.isFinite ? min(max(raw, 0), 100) / 100 : 1
        // Protection: an alpha channel and/or skin tones.
        var protect: Surface?
        if let v = p["protect"], v != .null, v.stringValue != "none" {
            guard let m = channelMask(doc, v) else {
                throw EngineError.bad(cmd, "`protect` must name an alpha channel (index or name) or \"none\"")
            }
            protect = m
        }
        let skinTones = Params.bool(p, "protectSkinTones", false)
        return CasPlan(doc: doc, layer: id, region: region, dst: dst, amount: amount, protect: protect, skinTones: skinTones)
    }

    /// The scaled pixels: `img` (`w`×`h`, `fmt`) seam-carved to `nw`×`nh` where the protection
    /// (`protect`, one value per pixel, and the skin tones when asked) steers the seams, blended
    /// with a plain resample by `amount` (0…1). Checks `ctx` for cancellation before every seam
    /// (photocraft `cas_pixels`).
    static func casPixels(_ ctx: JobContext, _ label: String, _ img: [Float], _ w: Int, _ h: Int, _ fmt: PixelFormat,
                          _ protect0: [Float]?, _ skinTones: Bool, _ nw: Int, _ nh: Int, _ amount: Float) throws -> [Float] {
        let n = fmt.channels
        var protect = protect0
        if skinTones {
            var rgba = [Float](repeating: 0, count: w * h * 4)
            img.withUnsafeBufferPointer { b in
                for i in 0..<(w * h) where (i + 1) * n <= b.count {
                    let c = PixelCodec.toRGBA(fmt, b, i * n)
                    rgba[4 * i] = c.x; rgba[4 * i + 1] = c.y; rgba[4 * i + 2] = c.z; rgba[4 * i + 3] = c.w
                }
            }
            let skin = SeamCarving.skinMask(w: w, h: h, ch: 4, img: rgba)
            protect = protect.map { pm in zip(pm, skin).map { Swift.max($0, $1) } } ?? skin
        }
        try ctx.check()
        var carved: [Float] = []
        if amount > 0 {
            let control = CarveControl(cancelled: { ctx.isCancelled }, progress: { f in ctx.progress(0.05 + 0.9 * f, label) })
            do {
                carved = try SeamCarving.carve(w: w, h: h, ch: n, img: img, protect: protect, newW: nw, newH: nh, control: control)
            } catch {
                throw EngineError.cancelled
            }
        }
        let plain = amount < 1 ? SeamCarving.resizeBilinear(w: w, h: h, ch: n, img: img, newW: nw, newH: nh) : []
        switch (carved.isEmpty, plain.isEmpty) {
        case (false, true): return carved
        case (true, false): return plain
        default: return zip(carved, plain).map { c, l in l + (c - l) * amount }
        }
    }

    /// The writable pixels of layer `id` (photocraft `writable_surface`).
    static func withWritableSurface<R>(_ doc: inout Document, _ id: LayerId, _ body: (inout Surface) throws -> R) throws -> R {
        let locks = doc.effectiveLocks(id)
        guard let l = doc.layer(id) else { throw EngineError.noLayer(id) }
        if locks.all || locks.pixels {
            throw EngineError.other("Could not complete your request because the layer \"\(l.name)\" is locked")
        }
        guard let r = try doc.withRaster(of: id, body) else { throw EngineError.other("not a pixel layer") }
        return r
    }

    /// Edit › Content-Aware Scale (photocraft `content_aware_scale`).
    static func contentAwareScale(_ s: Session, _ p: JSONValue) throws -> JSONValue {
        let plan = try casPlan(s, p)
        let (id, region, dst) = (plan.layer, plan.region, plan.dst)
        let (w, h) = (region.width, region.height)
        let (nw, nh) = (dst.width, dst.height)
        let label = "Content-Aware Scale"
        // A background job when started in the background (#210): seam carving runs on a worker
        // against the document snapshot and checks for cancellation before every seam.
        return try s.runJob(label, lockDocument: true, work: { ctx in
            ctx.progress(0, label)
            guard let surf = plan.doc.layer(id)?.surface else { throw EngineError.noLayer(id) }
            let img = surf.readRegion(region)
            let protect = plan.protect.map { $0.coverage(region) }
            return try casPixels(ctx, label, img, w, h, surf.format, protect, plan.skinTones, nw, nh, plan.amount)
        }, apply: { s, out, _ in
            try s.edit(label) { doc, _ in
                try withWritableSurface(&doc, id) { surf in
                    Pixels.clearSurface(&surf, region, selection: nil)
                    surf.writeRegion(dst, out)
                    surf.prune()
                }
            }
            return ["from": [.int(w), .int(h)], "to": [.int(nw), .int(nh)], "bounds": [.int(Int(dst.x0)), .int(Int(dst.y0)), .int(nw), .int(nh)]]
        })
    }

    /// Content-Aware Scale on a reduced copy, for the transform box's live preview (#3096): the
    /// command's own carving, on the area scaled down so the longer of its sides before and after
    /// is at most `maxSide` px. Prepared from the session and `run` on any thread (photocraft
    /// `ContentAwareScalePreview`).
    struct ContentAwareScalePreview: Sendable {
        let plan: CasPlan
        let maxSide: Int

        /// `p` takes `edit.contentAwareScale`'s params; the same ones fail the same way.
        init(_ s: Session, _ p: JSONValue, maxSide: Int) throws {
            plan = try casPlan(s, p)
            self.maxSide = Swift.max(maxSide, 1)
        }

        /// The area scaled, in document px.
        var region: PixelRect { plan.region }

        /// The reduced sizes of the area before and after: (w, h, new w, new h).
        var reduced: (Int, Int, Int, Int) {
            let (w, h, nw, nh) = (plan.region.width, plan.region.height, plan.dst.width, plan.dst.height)
            let k = Swift.max(Double(Swift.max(w, h, nw, nh)) / Double(maxSide), 1)
            func side(_ v: Int) -> Int { Swift.max(Int((Double(v) / k).rounded()), 1) }
            return (side(w), side(h), side(nw), side(nh))
        }

        /// The size of `run`'s result, px.
        var size: PixelSize {
            let r = reduced
            return PixelSize(width: r.2, height: r.3)
        }

        /// The scaled pixels at the reduced size (`size`), in the layer's format, as a surface with
        /// its corner at the origin. Checks `ctx` for cancellation before every seam.
        func run(_ ctx: JobContext) throws -> Surface {
            guard let surf = plan.doc.layer(plan.layer)?.surface else { throw EngineError.noLayer(plan.layer) }
            let fmt = surf.format
            let n = fmt.channels
            let region = plan.region
            let (w, h) = (region.width, region.height)
            let (pw, ph, pnw, pnh) = reduced
            // Nearest samples of the area (and of the protecting channel) at the reduced size.
            let srcX: [Int32] = (0..<pw).map { i in region.x0 + Int32(Swift.min(Int((Double(i) + 0.5) * Double(w) / Double(pw)), w - 1)) }
            func srcY(_ j: Int) -> Int32 { region.y0 + Int32(Swift.min(Int((Double(j) + 0.5) * Double(h) / Double(ph)), h - 1)) }
            var img: [Float] = []
            img.reserveCapacity(pw * ph * n)
            for j in 0..<ph {
                try ctx.check()
                let row = surf.readRegion(PixelRect(x: Int(region.x0), y: Int(srcY(j)), width: w, height: 1))
                for x in srcX {
                    let at = Int(x - region.x0) * n
                    guard at >= 0, at + n <= row.count else { throw EngineError.other("preview read out of bounds") }
                    img.append(contentsOf: row[at..<(at + n)])
                }
            }
            let protect = plan.protect.map { m in (0..<(pw * ph)).map { i in m.sampleChannel(x: srcX[i % pw], y: srcY(i / pw), 0) } }
            let out = try casPixels(ctx, "Content-Aware Scale", img, pw, ph, fmt, protect, plan.skinTones, pnw, pnh, plan.amount)
            var s = Surface(format: fmt)
            s.writeRegion(PixelRect(x: 0, y: 0, width: pnw, height: pnh), out)
            return s
        }
    }
}
