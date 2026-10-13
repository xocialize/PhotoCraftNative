// Port of photocraft-engine (crates/engine/src/redeye_cmds.rs) with photocraft-algo's kernel (crates/algo/src/redeye.rs, ported locally as `RedEyeCommands.Kernel`), MIT OR Apache-2.0, © ArtCraft Team and the PhotoCraft contributors.
//
// Red Eye tool: click a pupil to neutralize the flash reflection. Toolbar-only (`paint.redEye`,
// empty menu path). The kernel runs on a window around each click plus the mask-filter halo; only
// the pixels whose RGB it changed are re-encoded, so CMYK (K) and Lab values outside the corrected
// pupil stay bit-exact.

import Foundation
import PCDocument
import PCFoundation
import PCPaint

enum RedEyeCommands: CommandModule {
    static let name = "redeye_cmds"
    static let cmd = "paint.redEye"
    static let miss = "no red-eye pixels near the click"

    static func bad(_ msg: String) -> EngineError { .bad(cmd, msg) }

    static func num(_ p: JSONValue, _ key: String, _ fallback: Float) throws -> Float {
        guard let v = p[key] else { return fallback }
        guard let x = v.doubleValue, x.isFinite else { throw bad("`\(key)` must be a finite number (got \(v.serialized()))") }
        return Float(x)
    }

    static func coord(_ v: JSONValue) -> Double? { v.doubleValue.flatMap { $0.isFinite ? $0 : nil } }

    static func pixel(_ x: Double, _ y: Double) throws -> (Int32, Int32) {
        guard x.isFinite, y.isFinite else { throw bad("click coordinates must be finite") }
        func clamp(_ v: Double) -> Int32 { Int32(min(max(v, Double(Int32.min)), Double(Int32.max)).rounded(.down)) }
        return (clamp(x), clamp(y))
    }

    /// One click, or a batch of clicks, as document pixels.
    static func clicks(_ p: JSONValue) throws -> [(Int32, Int32)] {
        if let arr = p["points"]?.arrayValue {
            if arr.isEmpty { throw bad("`points` is empty") }
            if arr.count > Kernel.maxPoints { throw bad("at most \(Kernel.maxPoints) points") }
            return try arr.map { q in
                guard let a = q.arrayValue, a.count == 2 else { throw bad("bad point \(q.serialized()) (want [x, y])") }
                guard let x = coord(a[0]), let y = coord(a[1]) else { throw bad("bad point \(q.serialized()) (want [x, y])") }
                return try pixel(x, y)
            }
        }
        switch (p["x"].flatMap(coord), p["y"].flatMap(coord)) {
        case let (x?, y?): return [try pixel(x, y)]
        case (nil, nil) where p["x"] == nil && p["y"] == nil: throw bad("missing `x`,`y` or `points`")
        default: throw bad("`x` and `y` must be finite numbers")
        }
    }

    static func readRect(_ cx: Int32, _ cy: Int32, _ radius: Float) throws -> PixelRect {
        let r: Int32 = radius.isFinite ? Int32(min(max(radius.rounded(.up), 0), 256)) : 64
        let ext = r &+ Kernel.haloRadius()
        let area = PixelRect(x0: sat(Int(cx) - Int(ext)), y0: sat(Int(cy) - Int(ext)), x1: sat(Int(cx) + Int(ext) + 1), y1: sat(Int(cy) + Int(ext) + 1))
        let cap = Int(Kernel.maxWindow)
        if area.isEmpty || area.width * area.height > cap * cap {
            throw bad("pupil window is larger than \(Kernel.maxWindow)² px")
        }
        return area
    }

    static func sat(_ v: Int) -> Int32 { Int32(clamping: v) }

    /// Write back only the pixels whose RGBA changed. Untouched pixels keep their original channel
    /// data, so CMYK (K) and Lab values outside the corrected pupil are never re-encoded.
    static func writeRGBA(_ surf: inout Surface, _ area: PixelRect, _ before: [SIMD4<Float>], _ px: [SIMD4<Float>]) {
        if area.isEmpty { return }
        let fmt = surf.format
        let n = fmt.channels
        let need = area.area
        guard px.count >= need, before.count >= need, n > 0 else { return }
        var data = surf.readRegion(area)
        guard data.count == need * n else { return }
        var enc = [Float](repeating: 0, count: 8)
        for i in 0..<need where rgbChanged(before[i], px[i]) {
            let o = i * n
            let alpha = data[o + n - 1]
            enc.withUnsafeMutableBufferPointer { e in _ = fromRGBA(fmt, px[i], into: e.baseAddress!) }
            for c in 0..<n { data[o + c] = enc[c] }
            if fmt.alpha { data[o + n - 1] = alpha }
        }
        surf.writeRegionSafe(area, &data)
    }

    static func rgbChanged(_ a: SIMD4<Float>, _ b: SIMD4<Float>) -> Bool {
        abs(a.x - b.x) > 1e-5 || abs(a.y - b.y) > 1e-5 || abs(a.z - b.z) > 1e-5
    }

    static func mixSelection(_ orig: [SIMD4<Float>], _ px: inout [SIMD4<Float>], _ area: PixelRect, _ sel: Surface) {
        let w = area.width
        if w == 0 { return }
        let cover = sel.coverage(area)
        for i in 0..<min(px.count, orig.count, cover.count) {
            let k = min(max(cover[i], 0), 1)
            if k >= 1 { continue }
            let o = orig[i]
            if k <= 0 { px[i] = o; continue }
            var p = px[i]
            p.x = o.x + (p.x - o.x) * k
            p.y = o.y + (p.y - o.y) * k
            p.z = o.z + (p.z - o.z) * k
            p.w = o.w
            px[i] = p
        }
    }

    static func restoreLocked(_ orig: [SIMD4<Float>], _ px: inout [SIMD4<Float>]) {
        for i in 0..<min(px.count, orig.count) where orig[i].w <= 1e-5 { px[i] = orig[i] }
    }

    static func countChanged(_ orig: [SIMD4<Float>], _ px: [SIMD4<Float>]) -> UInt32 {
        UInt32(clamping: zip(orig, px).filter { rgbChanged($0, $1) }.count)
    }

    static func applyClick(_ surf: inout Surface, _ sel: Surface?, _ lock: Bool, _ click: (Int32, Int32), _ pupil: Float, _ darken: Float,
                           _ clip: PixelRect) throws -> (PixelRect, UInt32) {
        let area = try readRect(click.0, click.1, Kernel.searchRadius(pupil)).intersect(clip)
        if area.isEmpty { return (.empty, 0) }
        var px = surf.readRGBA(area)
        let orig = px
        let n = Kernel.apply(&px, area.width, area.height, click: click, origin: (area.x0, area.y0), pupilSize: pupil, darken: darken)
        if n == 0 { return (area, 0) }
        if let sel { mixSelection(orig, &px, area, sel) }
        if lock { restoreLocked(orig, &px) }
        let changed = countChanged(orig, px)
        if changed == 0 { return (area, 0) }
        writeRGBA(&surf, area, orig, px)
        return (area, changed)
    }

    /// photocraft `commands::has_paintable`, then the layer's pixel lock.
    static let enabled: CommandEnabled = { s, _ in
        if Channels.editsChannel(s) { return nil }
        let l: Layer
        switch s.activeLayer() {
        case .failure(let e): return e.description
        case .success(let x): l = x
        }
        if case .raster = l.content {} else if l.mask == nil {
            return "active layer is \(l.content.article) \(l.content.kindName) layer without a mask"
        }
        guard let d = s.active, let id = d.activeLayer else { return "no active layer" }
        let locks = d.doc.effectiveLocks(id)
        if locks.pixels || locks.all { return "the layer \"\(d.doc.layer(id)?.name ?? "layer")\" is locked" }
        return nil
    }

    static func redEye(_ s: Session, _ p: JSONValue) throws -> JSONValue {
        let pts = try clicks(p)
        let pupilRaw = try num(p, "pupilSize", 50)
        let darken0 = try num(p, "darken", 50)
        if Kernel.unclampedWindowSide(pupilRaw) == nil { throw bad("pupil window is larger than \(Kernel.maxWindow)² px") }
        let pupil = min(max(pupilRaw, 1), 100)
        let darken = min(max(darken0, 0), 100)
        let id = Params.layerId(p) ?? s.active?.activeLayer
        let (damage, total) = try s.edit("Red Eye") { doc, active in
            let canvas = doc.bounds
            let sel = doc.selection
            return try Channels.withTargetSurface(&doc, layer: id ?? active, p) { surf, lock in
                var total: UInt32 = 0
                var damage = PixelRect.empty
                for c in pts {
                    let (area, n) = try applyClick(&surf, sel, lock, c, pupil, darken, canvas)
                    total = total &+ n
                    damage = damage.isEmpty ? area : damage.union(area)
                }
                if total == 0 { throw EngineError.other(miss) }
                return (damage, total)
            }
        }
        s.noteDamage(damage)
        return ["damage": .rect(damage), "pixels": .int(Int(total))]
    }

    static func register(into r: inout CommandRegistry) {
        r.add(CommandSpec(cmd, "Red Eye",
                          params: #"{"x":px, "y":px} | {"points":[[x,y],…] (at most 64)},"pupilSize":1..100=50,"darken":0..100=50,"layer":id?=active,"target":"pixels"|"mask"|"quickMask"|{"channel":i} → {"damage":[x,y,w,h], "pixels":n}"#,
                          module: name, enabled: enabled, run: redEye))
    }

    // MARK: - photocraft-algo redeye.rs

    /// Click-local red-eye correction: neutralize a red pupil around a click. The kernel never
    /// scans a full document; callers pass the search window plus a read halo that covers a 1 px
    /// morphological shrink and a Gaussian of σ = 0.8.
    enum Kernel {
        /// Gaussian σ applied to the pupil mask after a 1 px shrink.
        static let sigma: Float = 0.8
        /// Largest window (search + halo) the engine may allocate, in pixels on a side.
        static let maxWindow: UInt32 = 512
        /// Clicks one command may apply in a single history step.
        static let maxPoints = 64

        /// How far outside the search window the mask filter reads: 1 (erode) + ceil(σ·3) + 1.
        static func haloRadius() -> Int32 {
            let blur = (sigma * 3).rounded(.up)
            let b: Int32 = blur.isFinite ? Int32(min(max(blur, 0), 64)) : 3
            return 1 + b + 1
        }

        /// Search radius in document pixels for a Pupil Size in 1…100.
        static func searchRadius(_ pupilSize: Float) -> Float {
            let p: Float = pupilSize.isFinite ? min(max(pupilSize, 1), 100) : 50
            return min(max(4 + 1.20 * p, 8), 128)
        }

        /// Side length of the read rect (search + halo) before clamping Pupil Size; nil when
        /// `pupilSize` is non-finite or the side would exceed `maxWindow`.
        static func unclampedWindowSide(_ pupilSize: Float) -> UInt32? {
            guard pupilSize.isFinite else { return nil }
            let r = 4 + 1.20 * pupilSize
            guard r.isFinite else { return nil }
            let half = abs(r) + Float(haloRadius())
            guard half.isFinite, half <= Float(maxWindow) else { return nil }
            let side = (2 * half + 1).rounded(.up)
            guard side.isFinite, side <= Float(maxWindow) else { return nil }
            return UInt32(side)
        }

        static func luma(_ p: SIMD4<Float>) -> Float { 0.2126 * p.x + 0.7152 * p.y + 0.0722 * p.z }

        static func isRedEye(_ p: SIMD4<Float>) -> Bool {
            let (r, g, b) = (p.x, p.y, p.z)
            guard r.isFinite, g.isFinite, b.isFinite else { return false }
            if r <= g + 0.15 || r <= b + 0.15 { return false }
            if luma(p) >= 0.92 { return false }
            return max(r, g, b) - min(r, g, b) >= 0.08
        }

        static func withinSearch(_ dx: Int32, _ dy: Int32, _ radius: Float) -> Bool {
            let d = hypot(Float(dx), Float(dy))
            return d.isFinite && d <= radius
        }

        static func delta(_ origin: Int32, _ i: Int, _ click: Int32) -> Int32 {
            Int32(clamping: Int(Int32(clamping: Int(origin) + i)) - Int(click))
        }

        static func nearestSeed(_ mask: [Bool], _ w: Int, _ h: Int, _ origin: (Int32, Int32), _ click: (Int32, Int32), _ radius: Float) -> Int? {
            var best: (Int, Int64)?
            for y in 0..<h {
                for x in 0..<w {
                    let i = y * w + x
                    guard i < mask.count, mask[i] else { continue }
                    let dx = delta(origin.0, x, click.0), dy = delta(origin.1, y, click.1)
                    if !withinSearch(dx, dy, radius) { continue }
                    let d2 = Int64(dx) * Int64(dx) + Int64(dy) * Int64(dy)
                    if let b = best, d2 >= b.1 { continue }
                    best = (i, d2)
                }
            }
            return best?.0
        }

        static func floodKeep(_ mask: inout [Bool], _ w: Int, _ h: Int, _ seed: Int) {
            let n = mask.count
            if seed >= n || w == 0 { return }
            var keep = [Bool](repeating: false, count: n)
            var stack = [seed]
            while let i = stack.popLast() {
                guard i < n, !keep[i], mask[i] else { continue }
                keep[i] = true
                let x = i % w, y = i / w
                if x > 0 { stack.append(i - 1) }
                if x + 1 < w { stack.append(i + 1) }
                if y > 0, i >= w { stack.append(i - w) }
                if y + 1 < h { stack.append(i + w) }
                if stack.count > n * 4 { break }
            }
            mask = keep
        }

        static func erode(_ mask: [Bool], _ w: Int, _ h: Int) -> [Bool] {
            var out = [Bool](repeating: false, count: mask.count)
            for y in 0..<h {
                for x in 0..<w {
                    let i = y * w + x
                    var on = true
                    for dy in -1...1 {
                        for dx in -1...1 {
                            let xx = x + dx, yy = y + dy
                            if xx < 0 || yy < 0 || xx >= w || yy >= h { on = false; continue }
                            let j = yy * w + xx
                            if !(j < mask.count && mask[j]) { on = false }
                        }
                    }
                    if i < out.count { out[i] = on }
                }
            }
            return out
        }

        static func blur(_ src: [Float], _ w: Int, _ h: Int, _ sigma: Float) -> [Float] {
            let n = w * h
            if w == 0 || h == 0 || src.count < n { return [Float](repeating: 0, count: n) }
            if !sigma.isFinite || sigma < 0.1 { return Array(src.prefix(n)) }
            let rr = (sigma * 3).rounded(.up)
            let r: Int = rr.isFinite ? Int(min(max(rr, 1), 32)) : 3
            var k: [Float] = []
            var sum: Float = 0
            for i in -r...r {
                let wgt = exp(-Float(i * i) / (2 * sigma * sigma))
                if !wgt.isFinite { continue }
                k.append(wgt)
                sum += wgt
            }
            if k.isEmpty || !sum.isFinite || sum <= 0 { return Array(src.prefix(n)) }
            for i in k.indices { k[i] /= sum }
            var tmp = [Float](repeating: 0, count: n)
            var out = [Float](repeating: 0, count: n)
            for y in 0..<h {
                for x in 0..<w {
                    var a: Float = 0
                    for (ki, wgt) in k.enumerated() {
                        let xx = min(max(x + ki - r, 0), w - 1)
                        a += src[y * w + xx] * wgt
                    }
                    tmp[y * w + x] = a
                }
            }
            for y in 0..<h {
                for x in 0..<w {
                    var a: Float = 0
                    for (ki, wgt) in k.enumerated() {
                        let yy = min(max(y + ki - r, 0), h - 1)
                        a += tmp[yy * w + x] * wgt
                    }
                    out[y * w + x] = a
                }
            }
            return out
        }

        /// Correct red-eye in `px` (row-major RGBA, including the `haloRadius` border); `origin`
        /// is the document coordinate of `px[0]`. Returns how many pixels changed. Pixels farther
        /// than `searchRadius` from `click` are left untouched.
        static func apply(_ px: inout [SIMD4<Float>], _ w: Int, _ h: Int, click: (Int32, Int32), origin: (Int32, Int32), pupilSize: Float,
                          darken: Float) -> UInt32 {
            let n = w * h
            if w == 0 || h == 0 || px.count < n { return 0 }
            let radius = searchRadius(pupilSize)
            let tAmt: Float = darken.isFinite ? min(max(min(max(darken, 0), 100) / 100, 0), 1) : 0.5
            var hard = [Bool](repeating: false, count: n)
            for y in 0..<h {
                for x in 0..<w {
                    let i = y * w + x
                    let dx = delta(origin.0, x, click.0), dy = delta(origin.1, y, click.1)
                    if withinSearch(dx, dy, radius) && isRedEye(px[i]) { hard[i] = true }
                }
            }
            guard let seed = nearestSeed(hard, w, h, origin, click, radius) else { return 0 }
            floodKeep(&hard, w, h, seed)
            let eroded = erode(hard, w, h)
            let soft = blur(eroded.map { $0 ? 1 : 0 }, w, h, sigma)
            var changed: UInt32 = 0
            for y in 0..<h {
                for x in 0..<w {
                    let i = y * w + x
                    let dx = delta(origin.0, x, click.0), dy = delta(origin.1, y, click.1)
                    if !withinSearch(dx, dy, radius) { continue }
                    let p = px[i]
                    if luma(p) >= 0.92 { continue }
                    let m = min(max(i < soft.count ? soft[i] : 0, 0), 1)
                    let t = m * tAmt
                    if t <= 1e-4 { continue }
                    let (r0, g0, b0, a0) = (p.x, p.y, p.z, p.w)
                    let neut = (g0 + b0) * 0.5
                    let r1 = r0 + (neut - r0) * t
                    let scale = 1 - 0.45 * t
                    let (r2, g2, b2) = (r1 * scale, g0 * scale, b0 * scale)
                    if !r2.isFinite || !g2.isFinite || !b2.isFinite { continue }
                    if abs(r2 - r0) < 1e-6 && abs(g2 - g0) < 1e-6 && abs(b2 - b0) < 1e-6 { continue }
                    px[i] = SIMD4(r2, g2, b2, a0)
                    changed = changed &+ 1
                }
            }
            return changed
        }
    }
}
