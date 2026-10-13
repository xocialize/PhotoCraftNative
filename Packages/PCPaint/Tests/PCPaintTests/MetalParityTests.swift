// Port of photocraft-paint (crates/paint/src/render.rs), MIT OR Apache-2.0, © ArtCraft Team and the PhotoCraft contributors.
//
// Metal dab renderer against the CPU reference: the raw stroke buffer (coverage, wet-edge depth,
// per-dab colour, dual coverage) and the composited pixels, over brushes exercising every
// rasteriser branch and every depth/colour model the composite kernel handles.

import Foundation
import Metal
import Testing
import PCFoundation
@testable import PCPaint

struct ParityResult {
    var maxCoverage: Float = 0
    var maxPixel: Float = 0
    var mismatchedPixels = 0
    var pixels = 0
}

/// Renders `pts` with both renderers (chunked, incremental composite) and compares.
func parity(_ b: BrushSettings, _ pts: [StrokePoint], format: PixelFormat, background: [Float]? = nil, selection: Surface? = nil,
            lock: Bool = false, chunk: Int = 7) throws -> ParityResult {
    var pre = Surface(format: format)
    if let bg = background {
        pre.fill(PixelRect(x0: -40, y0: -40, x1: 300, y1: 220), with: bg)
    } else {
        // A ramp backdrop so blends and dithering see varied pixels.
        let r = PixelRect(x0: -40, y0: -40, x1: 300, y1: 220)
        let n = format.channels
        var data = [Float](repeating: 0, count: r.area * n)
        for i in 0..<r.area {
            for c in 0..<n { data[i * n + c] = Float((i * (7 + c * 3)) % 97) / 96 }
            if format.alpha { data[i * n + n - 1] = Float(i % 5) / 4 }
        }
        pre.writeRegion(r, data)
    }
    var cpuT = pre, gpuT = pre
    var cpu = StrokeRenderer(b, format: format)
    let gpu = try MetalStrokeRenderer(b, format: format)
    var i = 0
    while i < pts.count {
        let c = Array(pts[i..<min(i + chunk, pts.count)])
        cpu.push(c)
        try gpu.push(c)
        cpu.composite(pre: pre, target: &cpuT, selection: selection, lockTransparency: lock, all: false)
        try gpu.composite(pre: pre, target: &gpuT, selection: selection, lockTransparency: lock, all: false)
        i += chunk
    }
    cpu.finish()
    try gpu.finish()
    cpu.composite(pre: pre, target: &cpuT, selection: selection, lockTransparency: lock, all: false)
    try gpu.composite(pre: pre, target: &gpuT, selection: selection, lockTransparency: lock, all: false)
    var res = ParityResult()
    let (gm, gd) = try gpu.coverageMap()
    let cm = cpu.coverage
    #expect(gpu.bounds == cpu.bounds)
    for (k, t) in gm.tiles {
        let ct = cm.tiles[k]
        for i in 0..<t.cov.count {
            let c = ct?.cov[i] ?? 0
            res.maxCoverage = max(res.maxCoverage, abs(c - t.cov[i]))
            if let ct, !ct.depth.isEmpty { res.maxCoverage = max(res.maxCoverage, abs(ct.depth[i] - t.depth[i])) }
        }
        if let ct, !ct.col.isEmpty {
            for i in 0..<ct.col.count { res.maxCoverage = max(res.maxCoverage, abs(ct.col[i] - t.col[i])) }
        }
    }
    for k in cm.tiles.keys { #expect(gm.tiles[k] != nil, "GPU lacks tile \(k)") }
    if let gd, let cd = cpu.dualCoverage {
        for (k, t) in gd.tiles {
            for i in 0..<t.cov.count { res.maxCoverage = max(res.maxCoverage, abs((cd.tiles[k]?.cov[i] ?? 0) - t.cov[i])) }
        }
    }
    let area = cpu.bounds.union(PixelRect(x0: -40, y0: -40, x1: 300, y1: 220))
    let a = cpuT.readRegion(area), g = gpuT.readRegion(area)
    let tol: Float = format.sample == .u8 ? 0.5 / 255 : (format.sample == .u16 ? 0.5 / 65535 : 0)
    for i in a.indices {
        let d = abs(a[i] - g[i])
        res.maxPixel = max(res.maxPixel, d)
        if d > tol { res.mismatchedPixels += 1 }
    }
    res.pixels = a.count
    return res
}

let parityPoints: [StrokePoint] = (0..<40).map { (i: Int) -> StrokePoint in
    let t = Double(i)
    let x: Double = 20 + t * 5.3
    let y: Double = 80 + 45 * sin(t / 6)
    let p: Float = 0.3 + 0.7 * Float(abs(sin(t / 4)))
    let tx: Float = Float(i % 7) * 9
    let ty: Float = Float(i % 5) * -11
    return StrokePoint(x: x, y: y, pressure: p, tiltX: tx, tiltY: ty, rotation: Float(i) * 13, time: t * 9)
}

func parityBrushes() -> [(String, BrushSettings)] {
    let base = with(brush()) { $0.size = 28; $0.hardness = 0.5; $0.seed = 7; $0.color = SIMD4(0.9, 0.3, 0.1, 1) }
    let tip = GrayTile(width: 17, height: 11) { x, y in Float((x * 3 + y * 5) % 11) / 10 }
    var out: [(String, BrushSettings)] = [
        ("round soft", with(base) { $0.hardness = 0 }),
        ("round hard", with(base) { $0.hardness = 1 }),
        ("small tips", with(base) { $0.size = 4; $0.hardness = 0.3 }),
        ("pencil", with(base) { $0.size = 7; $0.aliased = true }),
        ("pencil 1px", with(base) { $0.size = 1; $0.aliased = true; $0.hardness = 1 }),
        ("block", with(base) { $0.aliased = true; $0.square = true; $0.size = 9 }),
        ("shape dynamics", with(base) {
            $0.shapeDynamics = ShapeDynamics(enabled: true, size: Dynamic(jitter: 0.6, control: .penPressure, minimum: 0.2), angle: .jitter(1),
                                             roundness: Dynamic(jitter: 0.7, minimum: 0.3), flipXJitter: true, flipYJitter: true)
            $0.roundness = 0.6
        }),
        ("projection + tilt", with(base) {
            $0.roundness = 0.7
            $0.shapeDynamics = ShapeDynamics(enabled: true, size: Dynamic(control: .penTilt, minimum: 1), tiltScale: 1.5, brushProjection: true)
        }),
        ("scatter + count", with(base) { $0.scattering = Scattering(enabled: true, scatter: .jitter(2), bothAxes: true, count: 3, countJitter: .jitter(0.5)) }),
        ("transfer", with(base) { $0.flow = 0.4; $0.opacity = 0.8; $0.transfer = Transfer(enabled: true, opacity: .controlled(.penPressure), flow: .jitter(0.6)) }),
        ("sampled tip", with(base) { $0.tip = .sampled(tip); $0.size = 34; $0.shapeDynamics = ShapeDynamics(enabled: true, angle: .controlled(.direction)) }),
        ("sampled tiny", with(base) { $0.tip = .sampled(tip); $0.size = 5 }),
        ("sampled aliased", with(base) { $0.tip = .sampled(tip); $0.aliased = true; $0.size = 20 }),
        ("noise", with(base) { $0.noise = true; $0.hardness = 0 }),
        ("wet edges", with(base) { $0.wetEdges = true; $0.size = 40 }),
        ("texture stroke", with(base) { $0.texture = Texture(enabled: true, pattern: .procedural(style: .canvas, size: 64, seed: 2), scale: 1.3, depth: 0.8) }),
        ("texture stroke 100%", with(base) { $0.texture = Texture(enabled: true, pattern: .procedural(style: .paper, size: 32, seed: 2), mode: .subtract, depth: 0.6) }),
        ("texture each tip", with(base) {
            $0.texture = Texture(enabled: true, pattern: .tile(tip), scale: 0.7, eachTip: true, mode: .height, depth: 0.5, depthJitter: .jitter(0.5))
        }),
        ("dual brush", with(base) {
            $0.dualBrush = DualBrush(enabled: true, mode: .colorBurn, size: 9, hardness: 0.4, spacing: 0.4, scatter: 1.5, bothAxes: true, count: 2)
        }),
        ("dual sampled", with(base) { $0.dualBrush = DualBrush(enabled: true, mode: .overlay, tip: .sampled(tip), size: 14, spacing: 0.5, flip: true) }),
        ("color dynamics", with(base) { $0.colorDynamics = ColorDynamics(enabled: true, fgBg: .jitter(1), hueJitter: 0.4, brightnessJitter: 0.2) }),
        ("erase", with(base) { $0.erase = true; $0.opacity = 0.7 }),
        ("dissolve", with(base) { $0.mode = .dissolve; $0.opacity = 0.6; $0.hardness = 0.2 }),
        ("multiply", with(base) { $0.mode = .multiply }),
        ("color mode", with(base) { $0.mode = .color }),
        ("smoothing", with(base) { $0.smoothing = Smoothing(amount: 0.6) }),
        ("airbrush", with(base) { $0.buildUp = true; $0.flow = 0.1; $0.buildUpRate = 80 }),
    ]
    out.append(("everything", with(base) {
        $0.noise = true; $0.wetEdges = true; $0.flow = 0.6
        $0.shapeDynamics = ShapeDynamics(enabled: true, size: .jitter(0.4), angle: .jitter(0.5), roundness: Dynamic(jitter: 0.5, minimum: 0.4))
        $0.texture = Texture(enabled: true, pattern: .procedural(style: .dots, size: 32, seed: 1), depth: 0.5)
        $0.dualBrush = DualBrush(enabled: true, size: 12, scatter: 1)
        $0.colorDynamics = ColorDynamics(enabled: true, hueJitter: 0.3)
    }))
    return out
}

@Suite(.serialized) struct MetalParityTests {
    @Test func gpuRecordLayoutsMatchTheShader() {
        #expect(MemoryLayout<PcpDab>.stride == 120)
        #expect(MemoryLayout<PcpRaster>.stride == 64)
        #expect(MemoryLayout<PcpJob>.stride == 32)
        #expect(MemoryLayout<PcpComp>.stride == 112)
        #expect(MemoryLayout<PcpCJob>.stride == 72)
    }

    @Test func everyBrushMatchesTheCPUReferenceInRGBA8() throws {
        guard MetalContext.shared != nil else { return }
        for (name, b) in parityBrushes() {
            let r = try parity(b, parityPoints, format: .rgba8)
            #expect(r.maxCoverage == 0, "\(name): coverage differs by \(r.maxCoverage)")
            #expect(r.maxPixel <= 1.0 / 255 + 1e-6, "\(name): pixels differ by \(r.maxPixel * 255) levels")
            #expect(r.mismatchedPixels == 0, "\(name): \(r.mismatchedPixels) of \(r.pixels) samples differ")
        }
    }

    @Test func everyDepthAndModelMatches() throws {
        guard MetalContext.shared != nil else { return }
        let formats: [PixelFormat] = [.rgba8, .rgba16, .rgba32f, .graya8, .gray8, .gray32f, .cmyka8,
                                      .make(.rgb, .u16, false), .make(.lab, .u8, true), .make(.cmyk, .f32, true)]
        let picks = parityBrushes().filter { ["shape dynamics", "color dynamics", "multiply", "erase", "wet edges", "dual brush"].contains($0.0) }
        for f in formats {
            for (name, b) in picks {
                let r = try parity(b, parityPoints, format: f)
                #expect(r.maxCoverage == 0, "\(f) \(name): coverage differs by \(r.maxCoverage)")
                #expect(r.mismatchedPixels == 0, "\(f) \(name): \(r.mismatchedPixels) of \(r.pixels) samples differ (max \(r.maxPixel))")
            }
        }
    }

    @Test func selectionAndLockTransparencyMatch() throws {
        guard MetalContext.shared != nil else { return }
        var sel = Surface(format: .gray32f)
        let sr = PixelRect(x0: 0, y0: 0, x1: 200, y1: 160)
        sel.writeRegion(sr, (0..<sr.area).map { Float($0 % 200) / 150 })
        for (name, b) in parityBrushes().filter({ ["round soft", "multiply", "erase"].contains($0.0) }) {
            for lock in [false, true] {
                let r = try parity(b, parityPoints, format: .rgba16, selection: sel, lock: lock)
                #expect(r.maxCoverage == 0 && r.mismatchedPixels == 0, "\(name) lock \(lock): \(r.mismatchedPixels) differ, max \(r.maxPixel)")
            }
        }
    }

    @Test func symmetryPassesMatchTheCPUUnionAfterEveryChunk() throws {
        guard MetalContext.shared != nil else { return }
        let names = ["shape dynamics", "color dynamics", "wet edges", "dual brush", "smoothing", "multiply"]
        for (name, b0) in parityBrushes().filter({ names.contains($0.0) }) {
            let b = with(b0) { $0.opacity = 0.7 }
            for (mode, fmt) in [(SymmetryMode.dual, PixelFormat.rgba8), (.vertical, .rgba16), (.diagonal, .cmyka8)] {
                let sym = PresetSymmetry(mode, center: SIMD2(120, 90), rotation: 15)!
                let passes = 1 + sym.mirrorCount
                let pre = Surface(format: fmt, defaultPixel: fromRGBA(fmt, SIMD4(0.9, 0.85, 0.7, 1)))
                var cpuT = pre, gpuT = pre
                var cpu = (0..<passes).map { _ in StrokeRenderer(b, format: fmt) }
                var live = UnionLive()
                let gpu = try MetalStrokeRenderer(b, format: fmt, passes: passes)
                var i = 0
                var first = true
                while i < parityPoints.count {
                    let c = Array(parityPoints[i..<min(i + 6, parityPoints.count)])
                    let all = [c] + sym.reflectedPasses(c)
                    for p in 0..<passes { cpu[p].push(all[p]) }
                    try gpu.push(passes: all)
                    StrokeRenderer.compositeUnionLive(&cpu, live: &live, full: first, pre: pre, target: &cpuT)
                    try gpu.compositeLive(pre: pre, target: &gpuT)
                    first = false
                    let area = PixelRect(x0: -60, y0: -60, x1: 320, y1: 260)
                    let a = cpuT.readRegion(area), g = gpuT.readRegion(area)
                    let bad = zip(a, g).filter { $0 != $1 }.count
                    #expect(bad == 0, "\(name) \(mode) \(fmt) after \(i + 6) points: \(bad) samples differ")
                    i += 6
                }
                for p in 0..<passes { cpu[p].finish() }
                try gpu.finish()
                var cpuF = pre, gpuF = pre
                cpu[0].compositeUnionMany(Array(cpu.dropFirst()), pre: pre, target: &cpuF)
                try gpu.composite(pre: pre, target: &gpuF, all: true)
                let area = PixelRect(x0: -60, y0: -60, x1: 320, y1: 260)
                #expect(cpuF.readRegion(area) == gpuF.readRegion(area), "\(name) \(mode) finished")
                #expect(gpu.bounds == cpu.reduce(PixelRect.empty) { $0.union($1.bounds) })
            }
        }
    }

    @Test func liveCompositeWithTailMatchesTheFinishedStroke() throws {
        guard MetalContext.shared != nil else { return }
        let b = with(brush()) { $0.size = 18; $0.hardness = 0.6; $0.smoothing = Smoothing(amount: 0.7); $0.opacity = 0.8 }
        for f in [PixelFormat.rgba8, .rgba32f] {
            let pre = Surface(format: f)
            var live = pre
            let r = try MetalStrokeRenderer(b, format: f)
            var i = 0
            while i < parityPoints.count {
                try r.push(Array(parityPoints[i..<min(i + 5, parityPoints.count)]))
                try r.compositeLive(pre: pre, target: &live)
                // After every chunk the live target is what finishing now would give.
                var expected = pre
                var cpu = StrokeRenderer(b, format: f)
                cpu.push(Array(parityPoints[0..<min(i + 5, parityPoints.count)]))
                cpu.finish()
                cpu.composite(pre: pre, target: &expected, all: true)
                let area = PixelRect(x0: -20, y0: -20, x1: 280, y1: 200)
                let lv = live.readRegion(area), ev = expected.readRegion(area)
                var bad = 0, worst: Float = 0, first = ""
                for j in lv.indices where lv[j] != ev[j] {
                    bad += 1
                    worst = max(worst, abs(lv[j] - ev[j]))
                    if first.isEmpty { let p = j / 4; first = "(\(Int(area.x0) + p % area.width), \(Int(area.y0) + p / area.width)) live \(lv[j]) cpu \(ev[j])" }
                }
                #expect(bad == 0, "\(f) after \(i + 5) points: \(bad) samples differ, max \(worst), first \(first); bounds \(r.bounds)")
                i += 5
            }
        }
    }
}
