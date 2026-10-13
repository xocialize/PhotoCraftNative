// Port of photocraft-algo (crates/algo/src/inpaint.rs: Solver::costs, Solver::vote, Solver::transform, patch moments), MIT OR Apache-2.0, © ArtCraft Team and the PhotoCraft contributors.
//
// The Metal stages of the completion: per-target match costs (with the colour-adaptation
// moments), per-target gain/bias transforms, the vote, and the source patches' moments. The
// solver's buffers live in shared memory, so the CPU's PatchMatch and the GPU read and write the
// same pixels without copies. Every kernel sums in the CPU's order and uses only correctly rounded
// operations (MSL division is; its sqrt isn't, so the fit uses an exact integer square root), and
// the vote's exp() weights come from the CPU: the GPU path is bit-identical to the reference
// (the GPU flushes subnormal floats to zero, which image differences never reach).

import Metal
import PCFoundation

extension InpaintKit {
    final class InpaintGPU: @unchecked Sendable {
        /// Target boxes smaller than this stay on the CPU under `.auto` (dispatch costs more).
        static let minTargets = 96 * 96

        let gpu: AlgoGPU
        let force: Bool
        var device: any MTLDevice { gpu.device }

        init(gpu: AlgoGPU, force: Bool) { self.gpu = gpu; self.force = force }

        static func make(force: Bool) throws -> InpaintGPU { InpaintGPU(gpu: try AlgoGPU.shared(), force: force) }

        /// MSL `pca_inp_solver_params`.
        struct Params: BitwiseCopyable {
            var w: Int32, h: Int32, ch: Int32, r: Int32
            var tx0: Int32, ty0: Int32, tw: Int32, th: Int32
            var hx0: Int32, hy0: Int32, hw: Int32, hh: Int32
            var c8: Int32, adapted: UInt32, gainLo: Float, gainHi: Float
            var bias: Float, pad0: UInt32 = 0, pad1: UInt32 = 0, pad2: UInt32 = 0
        }

        func params(_ s: Solver) -> Params {
            Params(w: Int32(s.w), h: Int32(s.h), ch: Int32(s.ch), r: s.r,
                   tx0: Int32(s.tbox.x0), ty0: Int32(s.tbox.y0), tw: Int32(s.tbox.width), th: Int32(s.tbox.height),
                   hx0: Int32(s.holeBox.x0), hy0: Int32(s.holeBox.y0), hw: Int32(s.holeBox.width), hh: Int32(s.holeBox.height),
                   c8: Int32(s.c8), adapted: s.adapt.isNone ? 0 : 1, gainLo: s.adapt.gain.x, gainHi: s.adapt.gain.y, bias: s.adapt.bias)
        }

        /// A buffer the kernels can bind (every solver store is device-backed on this path).
        func buf<T>(_ s: Store<T>?) throws -> any MTLBuffer {
            if let b = s?.buffer { return b }
            guard let d = device.makeBuffer(length: 16, options: .storageModeShared) else { throw FilterError.gpuUnavailable("buffer") }
            return d
        }

        /// Encodes `name` over a `w × h` grid through the core's synthetic pass (frame at buffer 0,
        /// params at 1, `buffers` from 2).
        func encode<P: BitwiseCopyable>(_ cb: any MTLCommandBuffer, _ name: String, _ params: P, _ buffers: [any MTLBuffer],
                                        _ w: Int, _ h: Int) throws {
            if w <= 0 || h <= 0 { return }
            let pass = try GPUPass.synthetic(gpu, cb, rect: PixelRect(x0: 0, y0: 0, x1: Int32(w), y1: Int32(h)))
            try pass.dispatch(name, params: params, textures: [], buffers: buffers, width: w, height: h)
        }

        /// `Σs, Σs²` of every valid source patch (`Solver.prepare`).
        func sourceMoments(_ s: Solver, into sm: Store<SIMD2<Float>>) -> Bool {
            do {
                let p = params(s)
                try gpu.metal.run(label: "Inpaint source moments") { cb in
                    try encode(cb, "pca_inp_source_moments", p, [try buf(s.img), try buf(s.valid), try buf(sm)], s.w, s.h)
                }
                return true
            } catch { return false }
        }

        /// Every target's match cost, and with adaptation the full target patches' moments.
        func costs(_ s: Solver, _ nnf: Store<SIMD2<Int32>>, _ cost: Store<Float>) throws -> Bool {
            let p = params(s)
            try gpu.metal.run(label: "Inpaint costs") { cb in
                try encode(cb, "pca_inp_costs", p, [try buf(s.img), try buf(s.px), try buf(s.targets), try buf(s.full), try buf(nnf),
                                                    try buf(cost), try buf(s.tmom)], s.tbox.width, s.tbox.height)
            }
            return true
        }

        /// Gain and bias per channel of every voting target's match.
        func transforms(_ s: Solver, _ nnf: Store<SIMD2<Int32>>, _ cost: Store<Float>, into gb: Store<SIMD2<Float>>) throws -> Bool {
            let p = params(s)
            try gpu.metal.run(label: "Inpaint transforms") { cb in
                try encode(cb, "pca_inp_transforms", p, [try buf(s.img), try buf(s.px), try buf(s.targets), try buf(nnf), try buf(cost),
                                                         try buf(gb)], s.tbox.width, s.tbox.height)
            }
            return true
        }

        /// The vote, in place (a hole pixel's vote reads only source pixels, never another hole pixel).
        func vote(_ s: Solver, _ wt: Store<Float>, _ src: Store<Int32>, _ gb: Store<SIMD2<Float>>?) throws -> Bool {
            var p = params(s)
            p.adapted = gb == nil ? 0 : 1
            try gpu.metal.run(label: "Inpaint vote") { cb in
                try encode(cb, "pca_inp_vote", p, [try buf(s.img), try buf(s.px), try buf(wt), try buf(src), try buf(gb)],
                           s.holeBox.width, s.holeBox.height)
            }
            return true
        }
    }
}
