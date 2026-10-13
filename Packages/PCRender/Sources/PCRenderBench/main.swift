// PCRender benchmark (new; scenes from BenchmarkDocuments). Composites photocraft-compose semantics (MIT OR Apache-2.0, © ArtCraft Team and the PhotoCraft contributors).
//
//   swift run -c release PCRenderBench [--size 4096] [--cpu-runs 3] [--gpu-runs 12] [--scene effects4|realistic20|all]
//
// For each scene: planning time, the CPU reference (cold = first render, building effect maps and
// effect shapes; warm = min of the following runs) and Metal (cold; warm = min over the last half
// of back-to-back renders, wall clock and GPU time), plus the CPU-vs-GPU difference.

import Foundation
import Metal
import PCDocument
import PCFoundation
import PCRender

func arg(_ name: String, _ def: String) -> String {
    let a = CommandLine.arguments
    if let i = a.firstIndex(of: name), i + 1 < a.count { return a[i + 1] }
    return def
}

let size = Int(arg("--size", "4096")) ?? 4096
let cpuRuns = Int(arg("--cpu-runs", "3")) ?? 3
let gpuRuns = Int(arg("--gpu-runs", "12")) ?? 12
let which = arg("--scene", "all")

func now() -> Double { Double(DispatchTime.now().uptimeNanoseconds) / 1e9 }
func ms(_ s: Double) -> String { String(format: "%8.1f ms", s * 1000) }

func timed<T>(_ body: () throws -> T) rethrows -> (T, Double) {
    let t = now()
    let r = try body()
    return (r, now() - t)
}

guard let device = MTLCreateSystemDefaultDevice() else { print("no Metal device"); exit(1) }
print("PCRender bench — \(device.name), \(ProcessInfo.processInfo.activeProcessorCount) cores, size \(size)², release build")

var scenes: [(String, () -> Document)] = []
if which == "all" || which == "effects4" { scenes.append(("effects4 (phase 1: 4 layers + effects)", { BenchmarkDocuments.effects4(size: size) })) }
if which == "all" || which == "realistic20" { scenes.append(("realistic20 (phase 2: 20-layer composite)", { BenchmarkDocuments.realistic20(size: size) })) }

for (name, make) in scenes {
    let (doc, buildTime) = timed(make)
    print("\n== \(name): \(BenchmarkDocuments.layerCount(doc)) layers, built in \(ms(buildTime))")
    let region = doc.bounds

    // CPU reference.
    let cpu = DocumentCompositor(backend: .cpu, metal: nil)
    var cpuOut: RGBABuffer?
    var cpuTimes: [Double] = []
    for _ in 0..<max(cpuRuns, 1) + 1 {
        let (out, t) = try timed { try cpu.render(doc, region: region) }
        cpuOut = out
        cpuTimes.append(t)
    }
    let (planCPU, planTime) = timed { cpu.plan(doc, region: region) }
    print("plan: \(planCPU.plan.ops.count) ops, \(ms(planTime)) (warm)")
    print("CPU   cold \(ms(cpuTimes[0]))   warm min \(ms(cpuTimes.dropFirst().min() ?? 0))")

    // Metal.
    guard let metal = try? MetalCompositor() else { print("Metal unavailable"); continue }
    let gpu = DocumentCompositor(backend: .metal, metal: metal)
    let p0 = gpu.plan(doc, region: region)
    let (cold, coldTime) = try timed { try metal.render(p0.plan, region: region, source: p0.source) }
    var wall: [Double] = [], gpuT: [Double] = [], withPlan: [Double] = []
    // A display or export reuses its target texture.
    let target = cold.texture
    for _ in 0..<max(gpuRuns, 2) {
        let t0 = now()
        let p = gpu.plan(doc, region: region)
        let t1 = now()
        let r = try metal.render(p.plan, region: region, source: p.source, into: target)
        let t2 = now()
        wall.append(t2 - t1); gpuT.append(r.gpuTime); withPlan.append(t2 - t0)
    }
    let tail = wall.count / 2
    print("Metal cold \(ms(coldTime)) (GPU \(ms(cold.gpuTime)), \(cold.cells) cells)")
    let st = metal.lastStats
    print("Metal last render CPU side: output \(ms(st.output)), prepare \(ms(st.prepare)), encode \(ms(st.encode)), wait \(ms(st.wait))")
    print("Metal warm min \(ms(wall.suffix(tail).min() ?? 0)) wall, \(ms(gpuT.suffix(tail).min() ?? 0)) GPU, \(ms(withPlan.suffix(tail).min() ?? 0)) incl. planning")
    // The same with half-float accumulators forced (the automatic policy picks float for plans
    // with adjustment layers or amplifying blend modes; half is not parity-safe there).
    metal.precision = .half
    var half: [Double] = []
    for _ in 0..<max(gpuRuns / 2, 2) {
        let p = gpu.plan(doc, region: region)
        let t1 = now()
        _ = try metal.render(p.plan, region: region, source: p.source, into: target)
        half.append(now() - t1)
    }
    metal.precision = .automatic
    print("Metal warm min \(ms(half.suffix(half.count / 2).min() ?? 0)) wall with rgba16Float accumulators forced")
    let speed = (cpuTimes.dropFirst().min() ?? 1) / max(wall.suffix(tail).min() ?? 1, 1e-9)
    print(String(format: "speed-up (warm CPU / warm Metal wall): %.1f×", speed))

    // Parity of the final composites.
    let g = try metal.renderBuffer(p0.plan, region: region, source: p0.source)
    if let c = cpuOut {
        var worst: Float = 0, sum: Double = 0, over = 0
        for i in c.px.indices {
            let d = c.px[i] - g.px[i]
            let m = max(abs(d.x), abs(d.y), abs(d.z), abs(d.w))
            worst = max(worst, m)
            sum += Double(m)
            if m > 1.0001 / 255 { over += 1 }
        }
        print(String(format: "CPU vs Metal: max %.3f levels, mean %.5f levels, %d px over 1 level (%.6f%%)", worst * 255,
                     sum / Double(c.px.count) * 255, over, Double(over) / Double(c.px.count) * 100))
    }
    print("resident \(metal.residentBytes >> 20) MB, tiles uploaded \(metal.tilesUploaded)")
}
