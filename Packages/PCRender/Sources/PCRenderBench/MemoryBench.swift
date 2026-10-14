// PCRender memory bench (new): the canvas's GPU declaration on a BenchmarkDocuments scene.
//
//   swift run -c release PCRenderBench --memory [--size 4096] [--runs 200] [--chunk 2048] [--low-cell 512]
//
// 1. Accessors against Metal's own allocation sizes (`allocatedSize`, heap sizes) and against the
//    device's `currentAllocatedSize`, after a cold and three warm view renders of the whole document.
// 2. `relieve` timing per level and for both ladders, with no render in flight: each run first
//    renders the whole document off-view (as an export band would) and then a 2048² viewport.
// 3. The 16 GB tier: a 12.7 GB budget, an admission shrink of everything, and the floor + transient
//    it leaves, then the next frame in the low-footprint mode (its cost and what it measures).

import Foundation
import Metal
import PCDocument
import PCFoundation
import PCRender

func memoryBench(size: Int, runs: Int, chunk: Int, lowCell: Int) throws {
    guard let device = MTLCreateSystemDefaultDevice() else { print("no Metal device"); return }
    func mib(_ b: Int) -> String { String(format: "%9.1f MiB", Double(b) / 1_048_576) }
    func pct(_ a: Int, _ b: Int) -> String { b == 0 ? (a == 0 ? "   0.00 %" : "      — ") : String(format: "%+7.2f %%", (Double(a) / Double(b) - 1) * 100) }
    func quantile(_ xs: [Double], _ q: Double) -> Double {
        let s = xs.sorted()
        return s.isEmpty ? 0 : s[min(s.count - 1, Int((Double(s.count) * q).rounded(.up)) - 1)]
    }

    let doc = BenchmarkDocuments.realistic20(size: size)
    let whole = doc.bounds
    let viewport = PixelRect(x: 0, y: 0, width: min(2048, size), height: min(2048, size))
    print("\n== memory: realistic20 \(size)², \(BenchmarkDocuments.layerCount(doc)) layers, chunk \(chunk), low-footprint cell \(lowCell)")

    // 1. Accuracy: the accessors against the device's own count.
    let metal = try MetalCompositor(chunkSize: chunk)
    metal.lowFootprintCell = lowCell
    let gpu = DocumentCompositor(backend: .metal, metal: metal)
    let canvas = try CanvasRenderer()
    let p = gpu.plan(doc, region: whole)
    let base = device.currentAllocatedSize
    canvas.displayLUT = DisplayLUT(device: device) { $0 }
    let (_, cold) = try timed { try canvas.show(p.plan, region: whole, source: p.source, compositor: metal) }
    var warm: [Double] = []
    for _ in 0..<3 {
        let q = gpu.plan(doc, region: whole)
        warm.append(try timed { try canvas.show(q.plan, region: whole, source: q.source, compositor: metal) }.1)
    }
    let delta = settled(device) - base
    let fp = metal.footprint, d = canvas.footprint
    print("whole-document view render: cold \(ms(cold)), warm \(ms(warm.min() ?? 0))")
    let rows: [(String, Int)] = [
        ("pages", fp.pages), ("leaf images", fp.leafImages), ("gather pages", fp.gatherPages), ("effect maps", fp.effectMaps),
        ("masks", fp.masks), ("patterns", fp.patterns), ("pool heaps", fp.poolHeaps), ("composite", d.composite), ("levels", d.levels), ("LUT", d.lut),
    ]
    for (n, a) in rows { print("  \(n.padding(toLength: 14, withPad: " ", startingAt: 0)) \(mib(a))") }
    let total = fp.persistent + d.bytes
    print("  accessors total \(mib(total)) vs device currentAllocatedSize delta \(mib(delta)): \(pct(total, delta))")
    print("  visible pages \(mib(fp.visiblePages)), visible effects \(mib(fp.visibleEffects)), sheddable on run \(mib(fp.sheddableOnRun)), transient \(mib(fp.transient))")
    // The transient against the sampled peak of the next (warm) frame.
    let q0 = gpu.plan(doc, region: whole)
    let rest = settled(device)
    let peak = try peakDuring(device) { try canvas.show(q0.plan, region: whole, source: q0.source, compositor: metal) }
    print("  warm frame: declared transient \(mib(fp.transient)), sampled peak above the settled count \(mib(peak - rest))")

    // 2. relieve timing, no render in flight.
    func prime() throws {
        metal.pressureCleared()
        let all = gpu.plan(doc, region: whole)
        _ = try metal.render(all.plan, region: whole, source: all.source)
        let v = gpu.plan(doc, region: viewport)
        try canvas.show(v.plan, region: viewport, source: v.source, compositor: metal)
    }
    try prime()
    let primed = metal.footprint
    print("\nviewport \(viewport.width)×\(viewport.height) after an off-view whole render: persistent \(mib(primed.persistent)), visible pages \(mib(primed.visiblePages)), visible effects \(mib(primed.visibleEffects)), sheddable on run \(mib(primed.sheddableOnRun)), transient \(mib(primed.transient))")
    print("relieve        p50          p99          max      freed (mean)")
    for level in ReliefLevel.allCases {
        var times: [Double] = [], freed: [Int] = []
        let n = level == .effects ? max(runs / 5, 10) : runs
        for _ in 0..<n {
            try prime()
            let t0 = Double(DispatchTime.now().uptimeNanoseconds) / 1e9
            freed.append(metal.relieve(level))
            times.append(Double(DispatchTime.now().uptimeNanoseconds) / 1e9 - t0)
        }
        print("\(level.description.padding(toLength: 12, withPad: " ", startingAt: 0)) \(ms(quantile(times, 0.5))) \(ms(quantile(times, 0.99))) \(ms(times.max() ?? 0)) \(mib(freed.reduce(0, +) / max(freed.count, 1)))")
    }
    // Each rung against the device's count: what it reports shedding from persistent bytes, and
    // what the device count fell by once Metal retired the memory.
    print("rung          persistent shed   device count fell by")
    for level in ReliefLevel.allCases {
        try prime()
        for l in ReliefLevel.allCases where l < level { metal.relieve(l) }
        let before = metal.footprint.persistent, dev0 = settled(device)
        metal.relieve(level)
        let shed = before - metal.footprint.persistent, fell = dev0 - settled(device)
        print("\(level.description.padding(toLength: 12, withPad: " ", startingAt: 0)) \(mib(shed))      \(mib(fell))   \(pct(shed, fell))")
    }
    for reason in [ReliefReason.run, .admission] {
        var times: [Double] = [], waits: [Double] = []
        var last: Relief?
        for _ in 0..<runs {
            try prime()
            let r = metal.relieve(requested: Int.max, reason: reason)
            times.append(r.elapsed); waits.append(r.waited); last = r
        }
        let rungs = last.map { $0.rungs.map { "\($0.level) \(mib($0.freed))" }.joined(separator: ", ") } ?? ""
        print("ladder \(reason == .run ? ".run      " : ".admission") p50 \(ms(quantile(times, 0.5))), p99 \(ms(quantile(times, 0.99))), max \(ms(times.max() ?? 0)) (lock wait p99 \(ms(quantile(waits, 0.99))))")
        print("  rungs: \(rungs)")
    }

    // Visible pages survive a run-level shrink: the next frame uploads no tile.
    try prime()
    let uploads = metal.tilesUploaded
    _ = metal.relieve(requested: Int.max, reason: .run)
    let v = gpu.plan(doc, region: viewport)
    try canvas.show(v.plan, region: viewport, source: v.source, compositor: metal)
    print("run-level shrink, then the next viewport frame: \(metal.tilesUploaded - uploads) tiles uploaded")

    // 3. The 16 GB tier.
    metal.pressureCleared()
    metal.memoryBudget = 12_700_000_000
    for _ in 0..<2 {
        let q = gpu.plan(doc, region: whole)
        try canvas.show(q.plan, region: whole, source: q.source, compositor: metal)
    }
    let before = metal.footprint
    print("\n16 GB tier (budget 12.7 GB → limits \(metal.limits)): whole-document view, persistent \(mib(before.persistent + canvas.footprint.bytes)) incl. display, transient \(mib(before.transient))")
    let r = metal.relieve(requested: Int.max, reason: .admission)
    let after = r.footprint
    let floor = after.persistent + canvas.footprint.bytes
    print("admission shrink: \(ms(r.elapsed)) under the lock, freed \(mib(r.freed)) — \(r.rungs.map { "\($0.level) \(mib($0.freed))" }.joined(separator: ", "))")
    print("floor \(mib(floor)) (visible pages \(mib(after.visiblePages)), visible effects \(mib(after.visibleEffects)), display \(mib(canvas.footprint.bytes))) + transient \(mib(after.transient)) = \(mib(floor + after.transient))")
    let q = gpu.plan(doc, region: whole)
    let rest16 = settled(device)
    var lowTime = 0.0
    let peak16 = try peakDuring(device) { lowTime = try timed { try canvas.show(q.plan, region: whole, source: q.source, compositor: metal) }.1 }
    print("  the next frame: sampled peak above the settled count \(mib(peak16 - rest16)) (declared transient \(mib(after.transient)))")
    var lowWarm: [Double] = []
    for _ in 0..<3 {
        let q = gpu.plan(doc, region: whole)
        lowWarm.append(try timed { try canvas.show(q.plan, region: whole, source: q.source, compositor: metal) }.1)
    }
    let next = metal.footprint
    let rest2 = settled(device)
    let q2 = gpu.plan(doc, region: whole)
    let peak2 = try peakDuring(device) { try canvas.show(q2.plan, region: whole, source: q2.source, compositor: metal) }
    print("  a warm low-footprint frame: sampled peak above the settled count \(mib(peak2 - rest2)) (declared transient \(mib(next.transient)))")
    print("next frame at \(metal.limits.renderCell)² cells: \(ms(lowTime)) (regrows the pool at the small cells), warm \(ms(lowWarm.min() ?? 0))")
    print("  then persistent \(mib(next.persistent + canvas.footprint.bytes)) incl. display (pool heaps \(mib(next.poolHeaps))), transient \(mib(next.transient)) → \(mib(next.persistent + canvas.footprint.bytes + next.transient))")

    // Low-footprint output equals normal output.
    metal.pressureCleared()
    metal.precision = .float
    let a = try metal.renderBuffer(q.plan, region: whole, source: q.source)
    _ = metal.relieve(.lowFootprint)
    let b = try metal.renderBuffer(q.plan, region: whole, source: q.source)
    print("low-footprint composite vs normal: \(a == b ? "identical" : "DIFFERENT")")
}

/// The device's allocation count once it stops falling (Metal retires freed memory late).
func settled(_ device: any MTLDevice) -> Int {
    var last = device.currentAllocatedSize
    for _ in 0..<50 {
        usleep(10_000)
        let now = device.currentAllocatedSize
        if now == last { return now }
        last = now
    }
    return last
}

/// The largest device allocation count sampled every 50 µs while `body` runs.
func peakDuring(_ device: any MTLDevice, _ body: () throws -> Void) rethrows -> Int {
    final class Box: @unchecked Sendable { var peak = 0; var done = false; let lock = NSLock() }
    let box = Box()
    box.peak = device.currentAllocatedSize
    let sampler = Thread {
        while true {
            let n = device.currentAllocatedSize
            box.lock.lock()
            box.peak = max(box.peak, n)
            let done = box.done
            box.lock.unlock()
            if done { return }
            usleep(50)
        }
    }
    sampler.start()
    try body()
    box.lock.lock(); box.done = true; box.lock.unlock()
    usleep(1_000)
    box.lock.lock(); defer { box.lock.unlock() }
    return max(box.peak, device.currentAllocatedSize)
}
