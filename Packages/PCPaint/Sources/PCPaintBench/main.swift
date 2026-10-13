// Port of photocraft-paint (crates/paint/examples/bench_brush.rs), MIT OR Apache-2.0, © ArtCraft Team and the PhotoCraft contributors.
//
// Brush engine benchmark: a 2,000-dab stroke with a 200 px soft brush with Shape Dynamics on a
// 4096² RGBA8 layer, CPU reference vs Metal, one-shot and fed in 16-point chunks with a composite
// after each chunk (as interactive painting does). Warm GPU: the minimum of several back-to-back
// runs after a warm-up run.
//
//   swift run -c release pcpaint-bench [runs]

import Foundation
import PCFoundation
import PCPaint

let runs = CommandLine.arguments.count > 1 ? max(Int(CommandLine.arguments[1]) ?? 5, 1) : 5
let n: Int32 = 4096

var base = Surface(format: .rgba8, defaultPixel: [1, 1, 1, 1])
base.fill(PixelRect(x0: 0, y0: 0, x1: n, y1: n), with: [0.8, 0.7, 0.6, 1])

var brush = BrushSettings()
brush.size = 200
brush.hardness = 0
brush.spacing = 0.05            // 10 px between dabs
brush.pressureSize = false
brush.color = SIMD4(0.1, 0.2, 0.7, 1)
brush.flow = 0.6
brush.seed = 1234
brush.shapeDynamics = ShapeDynamics(enabled: true, size: Dynamic(jitter: 0.35), angle: .jitter(0.5),
                                    roundness: Dynamic(jitter: 0.4, minimum: 0.6))

// A serpentine path long enough for exactly 2,000 dabs (10 px apart: 19,990 px), points every 16 px.
var path: [SIMD2<Double>] = []
var y = 300.0
var leftToRight = true
while true {
    let xs = leftToRight ? stride(from: 200.0, through: 3900, by: 16) : stride(from: 3900.0, through: 200, by: -16)
    for x in xs { path.append(SIMD2(x, y)) }
    y += 700
    leftToRight.toggle()
    if y > 3900 { break }
}
// Trim the path to 19,995 px.
var pts: [StrokePoint] = []
var len = 0.0
for (i, p) in path.enumerated() {
    if i > 0 {
        let d = (p - path[i - 1])
        let seg = (d * d).sum().squareRoot()
        if len + seg > 19_995 {
            let f = (19_995 - len) / seg
            let q = path[i - 1] + d * f
            pts.append(StrokePoint(x: q.x, y: q.y, pressure: 1, time: Double(i) * 8))
            break
        }
        len += seg
    }
    pts.append(StrokePoint(x: p.x, y: p.y, pressure: 1, time: Double(i) * 8))
}
let dabTotal = dabs(Stroke(brush: brush, points: pts)).count

func ms(_ t0: UInt64) -> Double { Double(DispatchTime.now().uptimeNanoseconds - t0) / 1e6 }

struct Timing { var total = Double.infinity; var dabs = Double.infinity; var composite = Double.infinity; var worstChunk = 0.0 }

@MainActor func cpuOneShot() -> (Timing, Surface) {
    var t = Timing()
    var s = base
    let pre = s
    let t0 = DispatchTime.now().uptimeNanoseconds
    var r = StrokeRenderer(brush, format: .rgba8)
    r.push(pts)
    r.finish()
    t.dabs = ms(t0)
    let t1 = DispatchTime.now().uptimeNanoseconds
    r.composite(pre: pre, target: &s, all: true)
    t.composite = ms(t1)
    t.total = ms(t0)
    return (t, s)
}

@MainActor func cpuChunked() -> Timing {
    var t = Timing()
    var s = base
    let pre = s
    let t0 = DispatchTime.now().uptimeNanoseconds
    var r = StrokeRenderer(brush, format: .rgba8)
    var i = 0
    while i < pts.count {
        let c0 = DispatchTime.now().uptimeNanoseconds
        r.push(Array(pts[i..<min(i + 16, pts.count)]))
        r.composite(pre: pre, target: &s, all: false)
        t.worstChunk = max(t.worstChunk, ms(c0))
        i += 16
    }
    r.finish()
    r.composite(pre: pre, target: &s, all: false)
    t.total = ms(t0)
    return t
}

@MainActor func gpuOneShot() throws -> (Timing, Surface) {
    var t = Timing()
    var s = base
    let pre = s
    let t0 = DispatchTime.now().uptimeNanoseconds
    let r = try MetalStrokeRenderer(brush, format: .rgba8)
    try r.push(pts)
    try r.finish()
    try r.sync()
    t.dabs = ms(t0)
    let t1 = DispatchTime.now().uptimeNanoseconds
    try r.composite(pre: pre, target: &s, all: true)
    t.composite = ms(t1)
    t.total = ms(t0)
    return (t, s)
}

@MainActor func gpuChunked() throws -> Timing {
    var t = Timing()
    var s = base
    let pre = s
    let t0 = DispatchTime.now().uptimeNanoseconds
    let r = try MetalStrokeRenderer(brush, format: .rgba8)
    var i = 0
    while i < pts.count {
        let c0 = DispatchTime.now().uptimeNanoseconds
        try r.push(Array(pts[i..<min(i + 16, pts.count)]))
        try r.composite(pre: pre, target: &s, all: false)
        t.worstChunk = max(t.worstChunk, ms(c0))
        i += 16
    }
    try r.finish()
    try r.composite(pre: pre, target: &s, all: false)
    t.total = ms(t0)
    return t
}

@MainActor func best(_ f: () throws -> Timing) rethrows -> Timing {
    var b = Timing()
    _ = try f()  // warm-up (pipelines, caches)
    for _ in 0..<runs {
        let t = try f()
        b.total = min(b.total, t.total)
        b.dabs = min(b.dabs, t.dabs)
        b.composite = min(b.composite, t.composite)
        b.worstChunk = b.worstChunk == 0 ? t.worstChunk : min(b.worstChunk, t.worstChunk)
    }
    return b
}

print("PCPaint brush benchmark — \(dabTotal) dabs, 200 px soft brush + Shape Dynamics, \(n)² RGBA8, \(pts.count) points; min of \(runs) warm runs")
let cpu1 = best { cpuOneShot().0 }
print(String(format: "CPU one-shot      total %8.1f ms   (dabs+accumulate %7.1f, composite %6.1f)", cpu1.total, cpu1.dabs, cpu1.composite))
let cpu2 = best { cpuChunked() }
print(String(format: "CPU 16-pt chunks  total %8.1f ms   (worst chunk %6.2f ms)", cpu2.total, cpu2.worstChunk))
if MetalContext.shared != nil {
    let gpu1 = try best { try gpuOneShot().0 }
    print(String(format: "GPU one-shot      total %8.1f ms   (dabs+accumulate %7.1f, composite %6.1f)", gpu1.total, gpu1.dabs, gpu1.composite))
    let gpu2 = try best { try gpuChunked() }
    print(String(format: "GPU 16-pt chunks  total %8.1f ms   (worst chunk %6.2f ms)", gpu2.total, gpu2.worstChunk))
    print(String(format: "speed-up one-shot %.1f×, chunked %.1f×", cpu1.total / gpu1.total, cpu2.total / gpu2.total))
    let (_, a) = cpuOneShot()
    let (_, g) = try gpuOneShot()
    let r = PixelRect(x0: 0, y0: 0, x1: n, y1: n)
    let ab = a.readInterleaved(r), gb = g.readInterleaved(r)
    var diff = 0, maxd = 0
    for i in ab.indices where ab[i] != gb[i] { diff += 1; maxd = max(maxd, abs(Int(ab[i]) - Int(gb[i]))) }
    print("parity: \(diff) of \(ab.count) bytes differ (max \(maxd) levels)")
} else {
    print("no Metal device")
}
