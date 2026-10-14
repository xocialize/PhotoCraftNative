import Foundation
import PCAlgo
import PCFoundation

// cr-measure (AB-T-0241): PCAlgo's Camera Raw develop on the Camera Raw tables' 17³ grid, for the fitting scripts in
// Tools/CameraRawFit/fit. Usage: cr-measure jobs.json out.bin
// jobs.json: [{"settings": {CameraRaw keys}, "layout": "grid" | "bg", "bg": 0…1, "patch": px, "pitch": px}]
// out.bin: per job, 17³ × 3 float32, the developed color of each grid color (r slowest), averaged over its patch.
struct Job: Decodable {
    var settings: CameraRaw
    var layout: String
    var bg: Float?
    var patch: Int?
    var pitch: Int?
}

let n = 17
let levels: [Float] = (0..<n).map { Float((Double($0) * 255 / Double(n - 1)).rounded()) / 255 }
let colors: [SIMD3<Float>] = (0..<(n * n * n)).map { i in SIMD3(levels[i / (n * n)], levels[(i / n) % n], levels[i % n]) }

let args = CommandLine.arguments
let jobs = try JSONDecoder().decode([Job].self, from: Data(contentsOf: URL(fileURLWithPath: args[1])))
var out = [Float]()
out.reserveCapacity(jobs.count * colors.count * 3)
for job in jobs {
    let patch = job.patch ?? 1, pitch = job.pitch ?? patch
    // Patches on a square grid of cells `pitch` apart, the background between them.
    let side = Int(Double(colors.count).squareRoot().rounded(.up))
    let w = side * pitch, h = ((colors.count + side - 1) / side) * pitch
    let bg = job.bg ?? 0
    var px = [SIMD4<Float>](repeating: SIMD4(bg, bg, bg, 1), count: w * h)
    func cell(_ k: Int) -> (Int, Int) { ((k % side) * pitch + (pitch - patch) / 2, (k / side) * pitch + (pitch - patch) / 2) }
    for (k, c) in colors.enumerated() {
        let (x0, y0) = cell(k)
        for y in y0..<(y0 + patch) { for x in x0..<(x0 + patch) { px[y * w + x] = SIMD4(c, 1) } }
    }
    if job.layout == "grid" && pitch != patch { fatalError("grid layout has no background") }
    try ToneKit.develop(&px, w: w, h: h, job.settings, float: false, on: .cpu)
    for k in 0..<colors.count {
        let (x0, y0) = cell(k)
        var sum = SIMD3<Float>()
        for y in y0..<(y0 + patch) { for x in x0..<(x0 + patch) { let q = px[y * w + x]; sum += SIMD3(q.x, q.y, q.z) } }
        sum /= Float(patch * patch)
        out += [sum.x, sum.y, sum.z]
    }
}
try out.withUnsafeBufferPointer { Data(buffer: $0) }.write(to: URL(fileURLWithPath: args[2]))
