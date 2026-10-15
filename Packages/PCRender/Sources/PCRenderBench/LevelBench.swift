// PCRender level-of-detail bench (new; AB-T-0256): a large document drawn at the levels a canvas
// shows it at, from reduced sources.
//
//   swift run -c release PCRenderBench --level [--size 30000] [--drawable 5120x2880] [--parity]
//
// The canvas model is PixelAgencyEditor's: a drawable-sized view at a zoom; the level is
// floor(log2(1 / zoom)) below 50 %; the composite covers what the view shows plus an eighth around
// it, aligned to the level. Each frame is the plan, the level render into a new half-float composite
// (as a view), its display reduction chain and one display pass into a drawable-sized target.
// `--parity` also composites the whole document at full resolution in bands (on the GPU) and
// reduces it exactly (`renderReduced`) to compare with the fit composite.

import Foundation
import Metal
import PCDocument
import PCFoundation
import PCRender

func levelBench(size: Int, drawable: (Int, Int), parity: Bool) throws {
    guard let device = MTLCreateSystemDefaultDevice() else { print("no Metal device"); return }
    func mib(_ b: Int) -> String { String(format: "%8.1f MiB", Double(b) / 1_048_576) }
    let (dw, dh) = drawable

    print("\n== level of detail: realistic20 \(size)², drawable \(dw)×\(dh)")
    let (doc, buildTime) = timed { BenchmarkDocuments.realistic20(size: size) }
    var tileBytes = 0, tiles = 0
    func walk(_ ls: [Layer]) {
        for l in ls {
            if let s = l.surface { tileBytes += s.tileCount * Int(tileSize) * Int(tileSize) * s.format.bytesPerPixel; tiles += s.tileCount }
            if let m = l.mask { tileBytes += m.surface.tileCount * Int(tileSize) * Int(tileSize) * m.surface.format.bytesPerPixel; tiles += m.surface.tileCount }
            if case .group(let g) = l.content { walk(g.children) }
        }
    }
    walk(doc.layers)
    print("built in \(ms(buildTime)): \(BenchmarkDocuments.layerCount(doc)) layers, \(tiles) tiles, \(mib(tileBytes)) of pixels")

    let metal = try MetalCompositor()
    let gpu = DocumentCompositor(backend: .metal, metal: metal)
    let canvas = try CanvasRenderer(context: metal.context)
    guard let target = metal.context.makeTexture(width: dw, height: dh, pixelFormat: .rgba16Float, usage: [.renderTarget, .shaderRead], storage: .private) else {
        print("no target"); return
    }

    struct View { var zoom: Double; var center: SIMD2<Double> }
    func levelOf(_ zoom: Double) -> Int { zoom < 0.5 ? min(LevelOfDetail.maxLevel, Int(floor(log2(1 / zoom)))) : 0 }
    func regionOf(_ v: View) -> (PixelRect, Int) {
        let level = levelOf(v.zoom)
        let w = Double(dw) / v.zoom, h = Double(dh) / v.zoom
        let visible = PixelRect(x: Int((v.center.x - w / 2).rounded(.down)), y: Int((v.center.y - h / 2).rounded(.down)),
                                width: Int(w.rounded(.up)), height: Int(h.rounded(.up))).intersect(doc.bounds)
        let margin = Int32(max(visible.width, visible.height) / 8)
        let r = LevelOfDetail.documentRect(LevelOfDetail.region(visible.outset(by: margin), level: level), level: level).intersect(doc.bounds)
        return (r, level)
    }

    struct Frame { var total = 0.0, plan = 0.0, render = 0.0, chain = 0.0, display = 0.0; var stats: MetalRenderStats?; var blocks = 0; var rect = PixelRect.empty }
    func frame(_ v: View) throws -> Frame {
        var f = Frame()
        let (region, level) = regionOf(v)
        let b0 = metal.blocksReduced
        let t0 = now()
        let p = gpu.plan(doc, region: region)
        let t1 = now()
        let r = try metal.render(p.plan, region: region, level: level, source: p.source, outputFormat: .rgba16Float, view: canvas.renderView)
        let t2 = now()
        try canvas.setComposite(r.texture, rect: r.rect)
        let t3 = now()
        let f0 = Double(1 << level)
        canvas.view = CanvasViewTransform(zoom: v.zoom * f0, translate: SIMD2(Double(dw) / 2 - v.center.x * v.zoom, Double(dh) / 2 - v.center.y * v.zoom))
        guard let cb = metal.context.queue.makeCommandBuffer() else { return f }
        let pass = MTLRenderPassDescriptor()
        pass.colorAttachments[0].texture = target
        pass.colorAttachments[0].loadAction = .dontCare
        pass.colorAttachments[0].storeAction = .store
        try canvas.encode(into: cb, pass: pass, format: target.pixelFormat)
        cb.commit(); cb.waitUntilCompleted()
        let t4 = now()
        f.plan = t1 - t0; f.render = t2 - t1; f.chain = t3 - t2; f.display = t4 - t3; f.total = t4 - t0
        f.stats = metal.lastStats; f.blocks = metal.blocksReduced - b0; f.rect = r.rect
        return f
    }
    func show(_ name: String, _ f: Frame) {
        print("\(name.padding(toLength: 34, withPad: " ", startingAt: 0)) \(ms(f.total))  [plan \(ms(f.plan)), render \(ms(f.render)) (fill \(ms(f.stats?.fill ?? 0)), prepare \(ms(f.stats?.prepare ?? 0)), encode \(ms(f.stats?.encode ?? 0)), wait \(ms(f.stats?.wait ?? 0))), chain \(ms(f.chain)), display \(ms(f.display))] \(f.rect.width)×\(f.rect.height), \(f.blocks) blocks reduced")
    }

    let centre = SIMD2(Double(size) / 2, Double(size) / 2)
    let fit = min(Double(dw) / Double(size), Double(dh) / Double(size))
    let fitView = View(zoom: fit, center: centre)
    print(String(format: "fit zoom %.4f: level %d", fit, levelOf(fit)))

    // 1. The first frame at fit: a sampled preview two levels coarser (one pixel in 4^level read),
    // then the fit level, then the same frame warm.
    let previewLevel = min(LevelOfDetail.maxLevel, levelOf(fit) + 2)
    do {
        let (region, _) = regionOf(fitView)
        let b0 = metal.blocksReduced
        let t0 = now()
        let p = gpu.plan(doc, region: region)
        let t1 = now()
        let r = try metal.render(p.plan, region: region, level: previewLevel, sampled: true, source: p.source, outputFormat: .rgba16Float,
                                 view: canvas.renderView)
        let t2 = now()
        try canvas.setComposite(r.texture, rect: r.rect)
        canvas.view = CanvasViewTransform(zoom: fit * Double(1 << previewLevel), translate: SIMD2(Double(dw) / 2 - centre.x * fit, Double(dh) / 2 - centre.y * fit))
        if let cb = metal.context.queue.makeCommandBuffer() {
            let pass = MTLRenderPassDescriptor()
            pass.colorAttachments[0].texture = target
            pass.colorAttachments[0].loadAction = .dontCare
            pass.colorAttachments[0].storeAction = .store
            try canvas.encode(into: cb, pass: pass, format: target.pixelFormat)
            cb.commit(); cb.waitUntilCompleted()
        }
        let t3 = now()
        let st = metal.lastStats
        print("first frame at fit: a sampled preview at level \(previewLevel) \(ms(t3 - t0))  [plan \(ms(t1 - t0)), render \(ms(t2 - t1)) (fill \(ms(st.fill)), prepare \(ms(st.prepare)), encode \(ms(st.encode)), wait \(ms(st.wait))), chain + display \(ms(t3 - t2))] \(r.rect.width)×\(r.rect.height), \(metal.blocksReduced - b0) blocks sampled")
    }
    let first = try frame(fitView)
    show("the fit level after it (cold)", first)
    var warm: [Double] = []
    for i in 0..<5 {
        let f = try frame(fitView)
        warm.append(f.total)
        if ProcessInfo.processInfo.environment["PCRENDER_WARM_DETAIL"] != nil { show("fit again (warm) \(i)", f) }
    }
    print("fit again (warm), min of 5        \(ms(warm.min() ?? 0))")
    if ProcessInfo.processInfo.environment["PCRENDER_STOP_AFTER_FIT"] != nil { return }
    let fp = metal.footprint, d = canvas.footprint
    print("after fit: pages \(mib(fp.pages)) (level pages \(mib(fp.levelPages))), leaf images \(mib(fp.leafImages)), gather \(mib(fp.gatherPages)), effect maps \(mib(fp.effectMaps)), masks \(mib(fp.masks)), pool \(mib(fp.poolHeaps))")
    print("        visible pages \(mib(fp.visiblePages)), visible effects \(mib(fp.visibleEffects)), display \(mib(d.bytes)) (composite \(mib(d.composite)), chain \(mib(d.levels)))")
    print("        viewport floor (visible pages + visible effects + display) \(mib(fp.visiblePages + fp.visibleEffects + d.bytes)), transient \(mib(fp.transient)), reduced-tile cache \(mib(ReducedTiles.shared.bytes))")

    // 2. Level changes: zooming in on the centre and back out, each a cold level.
    for z in [fit * 1.6, fit * 3.2, 0.5, 1.0, fit * 1.6, fit] {
        let f = try frame(View(zoom: z, center: centre))
        show(String(format: "zoom %.3f (level %d)", z, levelOf(z)), f)
    }

    // 3. Pans past the margin at fit × 1.6 and fit × 3.2: the view moves by 60 % of its width each time.
    for scale in [1.6, 3.2] {
        let z = fit * scale
        var c = SIMD2(Double(dw) / z / 2, centre.y)
        var times: [Frame] = []
        while c.x + Double(dw) / z / 2 <= Double(size) {
            times.append(try frame(View(zoom: z, center: c)))
            c.x += 0.6 * Double(dw) / z
        }
        for (i, f) in times.enumerated() { show(String(format: "pan at zoom %.3f, step %d", z, i), f) }
    }

    // 4. Damage at fit: one 256² change composites again (the plan's change region only).
    var edited = doc
    let id = edited.layers[1].id
    edited.withRaster(of: id) { $0.fill(PixelRect(x: size / 3, y: size / 9, width: 256, height: 256), with: [1, 0, 0, 1]) }
    let (fitRegion, fitLevel) = regionOf(fitView)
    let damage = PixelRect(x: size / 3, y: size / 9, width: 256, height: 256)
    let aligned = LevelOfDetail.documentRect(LevelOfDetail.region(damage, level: fitLevel), level: fitLevel).intersect(fitRegion)
    let b0 = metal.blocksReduced
    let (_, dt) = try timed {
        let p = gpu.plan(edited, region: aligned)
        _ = try metal.render(p.plan, region: aligned, level: fitLevel, source: p.source, outputFormat: .rgba16Float)
    }
    print("a 256² change at fit: \(ms(dt)), \(metal.blocksReduced - b0) blocks reduced")

    // 5. Parity of the fit composite against the exact reduction of the full-resolution composite.
    if parity {
        let p = gpu.plan(doc, region: fitRegion)
        let lod = try metal.renderBuffer(p.plan, region: fitRegion, level: fitLevel, source: p.source)
        let (exact, et) = try timed {
            try gpu.renderReduced(doc, rect: fitRegion, width: lod.rect.width, height: lod.rect.height)
        }
        var worst: Float = 0, sum = 0.0, over2 = 0, over8 = 0
        for i in lod.px.indices {
            let a = lod.px[i], b = exact.px[i]
            let pa = SIMD4(a.x * a.w, a.y * a.w, a.z * a.w, a.w), pb = SIMD4(b.x * b.w, b.y * b.w, b.z * b.w, b.w)
            let dd = (pa - pb) * 255
            let m = max(abs(dd.x), abs(dd.y), abs(dd.z), abs(dd.w))
            worst = max(worst, m); sum += Double(abs(dd.x) + abs(dd.y) + abs(dd.z) + abs(dd.w))
            if m > 2 { over2 += 1 }
            if m > 8 { over8 += 1 }
        }
        let n = Double(lod.px.count)
        print(String(format: "parity at fit (level %d) against renderReduced (full resolution in bands on the GPU, %@): max %.2f, mean %.3f levels, %.3f%% over 2, %.3f%% over 8",
                     fitLevel, ms(et), worst, sum / (n * 4), Double(over2) / n * 100, Double(over8) / n * 100))
    }
    _ = device
}

/// Tile reduction throughput (`--reduce`): RGBA8 and Gray8 tiles reduced at levels 1, 3 and 6, on
/// one thread and on all of them, in source bytes per second.
func reductionBench() {
    var rng = SystemRandomNumberGenerator()
    for format in [PixelFormat.rgba8, .gray8] {
        let n = 2048
        let tiles: [Tile] = (0..<n).map { _ in Tile(bytes: (0..<(Int(tileSize) * Int(tileSize) * format.bytesPerPixel)).map { _ in UInt8.random(in: 0...255, using: &rng) }) }
        let bytes = Double(n * Int(tileSize) * Int(tileSize) * format.bytesPerPixel)
        for level in [1, 3, 6] {
            let side = Int(tileSize) >> level, row = side * format.bytesPerPixel
            var out = [UInt8](repeating: 0, count: side * row * n)
            let one = timed {
                out.withUnsafeMutableBytes { o in
                    for i in 0..<n { tiles[i].bytes.withUnsafeBytes { reduceTile($0.baseAddress!, format, level, o.baseAddress! + i * side * row, row) } }
                }
            }.1
            let all = timed {
                out.withUnsafeMutableBytes { o in
                    let base = UnsafeSendableBox(o.baseAddress!)
                    DispatchQueue.concurrentPerform(iterations: n) { i in
                        tiles[i].bytes.withUnsafeBytes { reduceTile($0.baseAddress!, format, level, base.value + i * side * row, row) }
                    }
                }
            }.1
            print(String(format: "reduce %@ level %d: one thread %.1f GB/s, %d threads %.1f GB/s", "\(format.mode)\(format.channels * 8)", level,
                         bytes / one / 1e9, ProcessInfo.processInfo.activeProcessorCount, bytes / all / 1e9))
        }
    }
}

func reduceTile(_ src: UnsafeRawPointer, _ format: PixelFormat, _ level: Int, _ dst: UnsafeMutableRawPointer, _ row: Int) {
    LevelOfDetail.reduceTile(src, format: format, level: level, into: dst, rowBytes: row)
}

struct UnsafeSendableBox<T>: @unchecked Sendable { let value: T; init(_ v: T) { value = v } }
