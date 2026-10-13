// Port of photocraft-algo (crates/algo/src/tests.rs, tests_ext.rs: GPU/CPU agreement; lib.rs `apply_in` edge contract), MIT OR Apache-2.0, © ArtCraft Team and the PhotoCraft contributors.
//
// GPU robustness over every catalog filter: degenerate documents (1×1, 1×N, N×1, 17×3), empty
// outputs, outputs reaching beyond the source and the bounds, empty layers, every colour mode
// (CMYK+alpha takes two planes) — no crashes, finite results, GPU within 1/255 of the CPU — and
// a census of where `.auto` runs on the CPU. `QA_TRACE=1 swift test …` prints each case before
// it runs (to find a crash).

import Foundation
import Testing
@testable import PCAlgo
import PCFoundation

enum QAGPU {
    struct Mode: Sendable, CustomStringConvertible {
        let name: String
        let channels: Int
        let mode: ColorMode
        let alpha: Bool
        var description: String { name }
    }

    static let modes: [Mode] = [
        Mode(name: "RGBA", channels: 4, mode: .rgb, alpha: true), Mode(name: "RGB", channels: 3, mode: .rgb, alpha: false),
        Mode(name: "Gray", channels: 1, mode: .grayscale, alpha: false), Mode(name: "Gray+A", channels: 2, mode: .grayscale, alpha: true),
        Mode(name: "CMYK", channels: 4, mode: .cmyk, alpha: false), Mode(name: "CMYK+A", channels: 5, mode: .cmyk, alpha: true),
        Mode(name: "Lab", channels: 3, mode: .lab, alpha: false), Mode(name: "Lab+A", channels: 4, mode: .lab, alpha: true),
    ]

    static let trace = ProcessInfo.processInfo.environment["QA_TRACE"] != nil
    static func note(_ s: @autoclosure () -> String) {
        guard trace else { return }
        print("QATRACE\t\(s())")
        fflush(stdout)
    }

    /// The source rectangle the Surface runner would read for `out`.
    static func source(_ f: any Filter, out: PixelRect, bounds: PixelRect) -> PixelRect {
        switch f.halo(bounds: bounds) {
        case .bounds: return bounds.union(out)
        case .radius(let r): return out.outset(by: r)
        }
    }

    enum Outcome { case cpuOnly, declined, ran(Float) }

    /// Runs `f` on both backends over `src` → `out` and checks shape, finiteness and parity.
    @discardableResult
    static func compare(_ f: any Filter, _ label: String, src: FloatImage, out: PixelRect, ctx: FilterContext,
                        tol: Float = 1.0 / 255.0, sourceLocation: SourceLocation = #_sourceLocation) throws -> Outcome {
        note("\(label) cpu")
        let cpu = try FilterEngine.apply(f, to: src, output: out, context: ctx, on: .cpu)
        #expect(cpu.rect == out && cpu.channels == src.channels, "\(label): CPU result shape", sourceLocation: sourceLocation)
        #expect(cpu.data.allSatisfy { $0.isFinite }, "\(label): CPU result not finite", sourceLocation: sourceLocation)
        guard AlgoGPU.isAvailable, FilterEngine.runsOnGPU(f, channels: src.channels, context: ctx) else { return .cpuOnly }
        note("\(label) gpu")
        let gpu: FloatImage
        do { gpu = try FilterEngine.apply(f, to: src, output: out, context: ctx, on: .gpu) } catch FilterError.gpuUnsupported { return .declined }
        #expect(gpu.rect == out && gpu.channels == src.channels, "\(label): GPU result shape", sourceLocation: sourceLocation)
        let err = Parity.maxError(cpu, gpu, alpha: ctx.alpha)
        #expect(err <= tol, "\(label): GPU vs CPU max error \(err)", sourceLocation: sourceLocation)
        return .ran(err)
    }

    static var indices: [Int] { Array(QA.catalog.indices) }

    static let wideBounds = PixelRect(x: 0, y: 0, width: 40, height: 30)
    static let layerRect = PixelRect(x: 2, y: 3, width: 23, height: 17)
    /// Partly outside the layer and the bounds, outside the layer only at a corner, wholly outside both.
    static let farOutputs = [PixelRect(x0: -6, y0: -5, x1: 33, y1: 22), PixelRect(x0: 30, y0: 20, x1: 47, y1: 35), PixelRect(x0: 52, y0: 41, x1: 59, y1: 44)]
    static let farModes = modes.filter { [4, 5].contains($0.channels) || $0.name == "Gray" }

    /// The catalog plus the MPS fast paths (radius-1 Median / Dust & Scratches without alpha).
    static var uncoveredCases: [(tag: String, filter: any Filter)] {
        QA.catalog + [("median", Median(radius: 1)), ("dustAndScratches", DustAndScratches(radius: 1, threshold: 10))]
    }

    /// Filters whose CPU path traps (index out of range) for a source that does not cover the
    /// output: they index their source window at output coordinates without a bounds check
    /// (`GalleryKit.variableBlur` line `level[o + c]`, `ReduceNoise.cpu` `yv[k]`, `OilPaint.cpu`).
    /// Filters whose CPU reference used to trap on a source that does not cover the output; the
    /// engine now pads such sources with transparency (`FilterEngine.run`), so none do.
    static func cpuTrapsOnUncoveredSource(_ f: any Filter) -> Bool { false }

    /// Where a backend did not read an uncovered source as transparent (window-relative passes that
    /// clamp at the source's edge; MPSImageAreaMin/Max for windows wholly outside it). Fixed by the
    /// engine's padding: none deviate now.
    static func deviatesOnUncoveredSource(_ f: any Filter, _ b: Backend) -> Bool { false }
}

@Suite struct QAGPURobustnessTests {
    /// Degenerate documents: the output is the whole 1×1 / 1×N / N×1 / 17×3 canvas, in every
    /// colour mode, with the source grown by the halo (bounds-halo filters see only the canvas).
    @Test(arguments: QAGPU.indices)
    func oddSizedDocuments(_ i: Int) throws {
        let e = QA.catalog[i]
        let sizes: [(Int, Int)] = [(1, 1), (1, 9), (9, 1), (17, 3)]
        var worst: Float = 0
        for (w, h) in sizes {
            let bounds = PixelRect(x: 0, y: 0, width: w, height: h)
            for m in QAGPU.modes {
                let src = TestImage.make(QAGPU.source(e.filter, out: bounds, bounds: bounds), channels: m.channels, alpha: m.alpha, seed: UInt32(w * 31 + h))
                let ctx = FilterContext(bounds: bounds, mode: m.mode, alpha: m.alpha)
                if case .ran(let err) = try QAGPU.compare(e.filter, "\(QA.name(e)) \(w)×\(h) \(m)", src: src, out: bounds, ctx: ctx) {
                    worst = max(worst, err)
                }
            }
        }
        ParityLog.record("QA odd sizes \(e.filter.label) #\(i)", worst)
    }

    /// Outputs reaching past the layer (the source is transparent there, as the Surface runner
    /// reads it) and past the bounds, partly or wholly: the backends agree.
    @Test(arguments: QAGPU.indices)
    func outputsReachingOutsideTheLayerAndBounds(_ i: Int) throws {
        let e = QA.catalog[i]
        for m in QAGPU.farModes {
            let layer = TestImage.make(QAGPU.layerRect, channels: m.channels, alpha: m.alpha, seed: 5)
            let ctx = FilterContext(bounds: QAGPU.wideBounds, mode: m.mode, alpha: m.alpha)
            for out in QAGPU.farOutputs {
                let src = layer.crop(layer.rect.union(QAGPU.source(e.filter, out: out, bounds: QAGPU.wideBounds)))
                try QAGPU.compare(e.filter, "\(QA.name(e)) out \(out) \(m)", src: src, out: out, ctx: ctx)
            }
        }
    }

    /// `FilterEngine.apply` documents that samples outside the source read as 0: running a
    /// neighbourhood filter on a source that does not cover the output grown by the halo must
    /// equal running it on that source padded with transparency. (The Surface runner always
    /// passes a covering source, so documents are unaffected; direct FloatImage callers are not.)
    /// Fix for every case below: in `FilterEngine.run`, for `.radius(r)` halos, replace `src` by
    /// `src.crop(src.rect.union(out.outset(by: r)))` when `!src.rect.contains(out.outset(by: r))`.
    @Test(arguments: QAGPU.uncoveredCases.indices)
    func uncoveredSourcesReadAsTransparent(_ i: Int) throws {
        let e = QAGPU.uncoveredCases[i]
        guard case .radius(let r) = e.filter.halo(bounds: QAGPU.wideBounds) else { return }
        for b in QA.backends {
            if b == .cpu && QAGPU.cpuTrapsOnUncoveredSource(e.filter) { continue }  // see `cpuTrapsOnUncoveredSources`
            let body = {
                for m in QAGPU.farModes {
                    let src = TestImage.make(QAGPU.layerRect, channels: m.channels, alpha: m.alpha, seed: 5)
                    let ctx = FilterContext(bounds: QAGPU.wideBounds, mode: m.mode, alpha: m.alpha)
                    if b == .gpu && !FilterEngine.runsOnGPU(e.filter, channels: m.channels, context: ctx) { continue }
                    for out in QAGPU.farOutputs {
                        QAGPU.note("\(QA.name(e)) uncovered \(out) \(m) \(b)")
                        let padded = src.crop(src.rect.union(out.outset(by: r)))
                        let got = try FilterEngine.apply(e.filter, to: src, output: out, context: ctx, on: b)
                        let want = try FilterEngine.apply(e.filter, to: padded, output: out, context: ctx, on: b)
                        let err = Parity.maxError(want, got, alpha: m.alpha)
                        #expect(err <= 1.0 / 255.0, "\(QA.name(e)) \(b) \(m) out \(out): uncovered vs transparent-padded source \(err)")
                    }
                }
            }
            if QAGPU.deviatesOnUncoveredSource(e.filter, b) {
                withKnownIssue("\(e.filter.label) on the \(b): an uncovered source is not read as transparent") { try body() }
            } else {
                try body()
            }
        }
    }

    /// Clearly-named reproduction of the CPU traps (Fatal error: Index out of range) for a source
    /// that does not cover the output: Tilt-Shift / Iris Blur / Field Blur (`GalleryKit.variableBlur`
    /// indexes `level[(y − win.y0)·lw + (x − win.x0)]` with no check that `out ⊆ src.rect`),
    /// Reduce Noise (`yv[k]` in the final write-back), Oil Paint (its window arrays). Disabled
    /// because a trap ends the test process. Fixed by the `FilterEngine.run` padding above (or
    /// per filter: `let src = src.rect.contains(out) ? src : src.crop(src.rect.union(out))`).
    @Test func cpuTrapsOnUncoveredSources() throws {
        for e in QA.catalog where QAGPU.cpuTrapsOnUncoveredSource(e.filter) {
            let src = TestImage.make(QAGPU.layerRect, channels: 4, alpha: true, seed: 5)
            let ctx = FilterContext(bounds: QAGPU.wideBounds, mode: .rgb, alpha: true)
            _ = try FilterEngine.apply(e.filter, to: src, output: QAGPU.farOutputs[0], context: ctx, on: .cpu)
        }
    }

    /// An empty output (zero width, zero height, `.empty`) returns an empty image on both backends,
    /// and the Surface runner leaves the layer alone for an empty area.
    @Test(arguments: QAGPU.indices)
    func emptyOutputs(_ i: Int) throws {
        let e = QA.catalog[i]
        let bounds = PixelRect(x: 0, y: 0, width: 40, height: 30)
        for m in QAGPU.modes where m.name == "RGBA" || m.name == "CMYK+A" {
            let src = TestImage.make(QAGPU.source(e.filter, out: bounds, bounds: bounds), channels: m.channels, alpha: m.alpha)
            let ctx = FilterContext(bounds: bounds, mode: m.mode, alpha: m.alpha)
            for out in [PixelRect(x0: 10, y0: 4, x1: 10, y1: 20), PixelRect(x0: 3, y0: 7, x1: 30, y1: 7), PixelRect.empty] {
                for b in QA.backends {
                    QAGPU.note("\(QA.name(e)) empty \(out) \(m) \(b)")
                    do {
                        let r = try FilterEngine.apply(e.filter, to: src, output: out, context: ctx, on: b)
                        #expect(r.rect == out && r.data.isEmpty, "\(QA.name(e)) \(m) \(b): empty output gave \(r.rect) with \(r.data.count) values")
                    } catch FilterError.gpuUnsupported where b == .gpu {}
                }
            }
        }
        for b in QA.backends {
            var s = QA.pattern(.u8)
            let before = s.readRegion(QA.R)
            try FilterEngine.apply(e.filter, to: &s, area: .empty, bounds: QA.R, on: b)
            #expect(s.readRegion(QA.R) == before, "\(QA.name(e)) \(b): an empty area changed the layer")
        }
    }

    /// An empty (transparent) layer: render filters draw into the bounds, everything else leaves
    /// it empty; the backends agree.
    @Test(arguments: QAGPU.indices)
    func emptyLayers(_ i: Int) throws {
        let e = QA.catalog[i]
        for (s, alpha) in [(SampleType.u8, true), (.f32, true), (.u16, false)] {
            let empty = Surface(format: QA.fmt(s, .rgb, alpha: alpha))
            let area = FilterEngine.outputArea(e.filter, content: .empty, bounds: QA.R)
            var results: [[Float]] = []
            for b in QA.backends {
                var out = empty
                QAGPU.note("\(QA.name(e)) empty layer \(s) \(b)")
                do { try FilterEngine.apply(e.filter, to: &out, area: area, bounds: QA.R, on: b) } catch FilterError.gpuUnsupported where b == .gpu { continue }
                let px = out.readRegion(QA.R)
                #expect(px.allSatisfy { $0.isFinite }, "\(QA.name(e)) \(s) \(b): not finite")
                results.append(px)
            }
            if results.count == 2 {
                let d = alpha ? QA.premulDiff(results[0], results[1], channels: 4) : QA.maxDiff(results[0], results[1])
                #expect(d <= 1.0 / 255.0 + 1e-6, "\(QA.name(e)) \(s): empty-layer GPU vs CPU \(d)")
            }
        }
    }

    /// Where `.auto` runs on the CPU (the filter declines the mode, or declines while encoding)
    /// for every colour mode. Informational: printed as `QAAUTO<TAB>filter<TAB>modes` lines; the
    /// expectation is only that `runsOnGPU` and the backend `.auto` actually used agree, except
    /// for declines found while encoding (which are by design, see `FilterEngine.run`).
    @Test func autoBackendCensus() throws {
        guard AlgoGPU.isAvailable else { return }
        let bounds = PixelRect(x: 0, y: 0, width: 24, height: 16)
        var lines: [String] = []
        for e in QA.catalog {
            var cpuModes: [String] = [], encodeDeclines: [String] = []
            for m in QAGPU.modes {
                let src = TestImage.make(QAGPU.source(e.filter, out: bounds, bounds: bounds), channels: m.channels, alpha: m.alpha)
                let ctx = FilterContext(bounds: bounds, mode: m.mode, alpha: m.alpha)
                let predicted = FilterEngine.runsOnGPU(e.filter, channels: m.channels, context: ctx)
                let (_, stats) = try FilterEngine.applyMeasured(e.filter, to: src, output: bounds, context: ctx, on: .auto)
                if stats.backend == .cpu { cpuModes.append(m.name) }
                if predicted && stats.backend == .cpu { encodeDeclines.append(m.name) }
                #expect(predicted || stats.backend == .cpu, "\(QA.name(e)) \(m): ran on the GPU although runsOnGPU said no")
            }
            if !cpuModes.isEmpty {
                lines.append("QAAUTO\t\(QA.name(e))\tcpu: \(cpuModes.joined(separator: ","))" + (encodeDeclines.isEmpty ? "" : "\tdeclined while encoding: \(encodeDeclines.joined(separator: ","))"))
            }
        }
        for l in lines { print(l) }
    }
}
