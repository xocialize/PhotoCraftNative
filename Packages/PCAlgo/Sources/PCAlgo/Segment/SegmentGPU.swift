// Port of photocraft-algo (crates/algo/src/matting.rs: box_mean, guided_filter_color; segment/gmm.rs: neg_log; segment/slic.rs: assignment; segment/focus.rs: sharpness), MIT OR Apache-2.0, © ArtCraft Team and the PhotoCraft contributors.
//
// The Metal paths of the segment area (Shaders/Segment.metal), on shared buffers through the
// selection area's runner (`SelectionKit.GPU`: buffer(0) params, buffer(1…) data). Box means use
// Kahan-compensated Float running sums (the CPU's are Double prefix sums), the guided filter's
// per-pixel 3×3 solve and the GMM likelihoods run in Float (the CPU's in Double); the SLIC
// assignment is exact.

import Foundation
import Metal
import PCFoundation

extension SegmentKit {
    enum GPU {
        typealias G = SelectionKit.GPU

        struct BoxParams: BitwiseCopyable { var w: UInt32; var h: UInt32; var r: UInt32; var planes: UInt32; var segment: UInt32; var pad0: UInt32 = 0; var pad1: UInt32 = 0; var pad2: UInt32 = 0 }

        /// Encodes clipped box means (photocraft `box_mean`) of `planes` planes of w × h floats.
        static func encodeBoxMean(_ e: G.Encoder, _ src: any MTLBuffer, _ tmp: any MTLBuffer, _ dst: any MTLBuffer, w: Int, h: Int, r: Int, planes: Int) throws {
            let seg = 256
            let p = BoxParams(w: UInt32(w), h: UInt32(h), r: UInt32(r), planes: UInt32(planes), segment: UInt32(seg))
            try e.dispatch("pca_seg_box_rows", p, [src, tmp], h * planes, (w + seg - 1) / seg)
            try e.dispatch("pca_seg_box_cols", p, [tmp, dst], w * planes, (h + seg - 1) / seg)
        }

        /// Box mean of one plane.
        static func boxMean(_ src: [Float], w: Int, h: Int, r: Int) throws -> [Float] {
            let n = w * h
            let s = try G.buffer(src), t = try G.zeros(n, of: Float.self), d = try G.zeros(n, of: Float.self)
            try G.run("box mean") { e in try encodeBoxMean(e, s, t, d, w: w, h: h, r: r, planes: 1) }
            return G.read(d, n, as: Float.self)
        }

        struct GuidedParams: BitwiseCopyable { var n: UInt32; var eps: Float; var pad0: UInt32 = 0; var pad1: UInt32 = 0 }

        /// The colour guided filter: 13 product planes, their box means, the per-pixel solve, the
        /// box means of (a, b), and the output.
        static func guidedFilterColor(_ guide: SegmentRGBImage, _ p: [Float], r: Int, eps: Float) throws -> [Float] {
            let w = guide.w, h = guide.h, n = w * h
            if n == 0 { return [] }
            let gb = try G.buffer(guide.px.map { SIMD4($0, 0) }), pb = try G.buffer(p)
            let planes = try G.zeros(13 * n, of: Float.self), tmp = try G.zeros(13 * n, of: Float.self), means = try G.zeros(13 * n, of: Float.self)
            let ab = try G.zeros(4 * n, of: Float.self), tmp4 = try G.zeros(4 * n, of: Float.self), mab = try G.zeros(4 * n, of: Float.self)
            let out = try G.zeros(n, of: Float.self)
            let gp = GuidedParams(n: UInt32(n), eps: eps)
            try G.run("guided filter") { e in
                try e.dispatch("pca_seg_guided_prep", gp, [gb, pb, planes], n)
                try encodeBoxMean(e, planes, tmp, means, w: w, h: h, r: r, planes: 13)
                try e.dispatch("pca_seg_guided_solve", gp, [means, ab], n)
                try encodeBoxMean(e, ab, tmp4, mab, w: w, h: h, r: r, planes: 4)
                try e.dispatch("pca_seg_guided_out", gp, [gb, mab, out], n)
            }
            return G.read(out, n, as: Float.self)
        }

        struct CostParams: BitwiseCopyable { var n: UInt32; var nfg: UInt32; var nbg: UInt32; var pad0: UInt32 = 0 }

        /// GMM data costs: per component (mean, log-norm), inv rows 0–2 as four float4s.
        static func dataCosts(_ img: SegmentRGBImage, _ fg: GMM, _ bg: GMM) throws -> ([Float], [Float]) {
            let n = img.px.count
            if n == 0 { return ([], []) }
            func pack(_ g: GMM) -> [SIMD4<Float>] {
                g.comps.prefix(16).flatMap { c -> [SIMD4<Float>] in
                    [SIMD4(c.mean, Float(c.logNorm)),
                     SIMD4(Float(c.inv[0][0]), Float(c.inv[0][1]), Float(c.inv[0][2]), 0),
                     SIMD4(Float(c.inv[1][0]), Float(c.inv[1][1]), Float(c.inv[1][2]), 0),
                     SIMD4(Float(c.inv[2][0]), Float(c.inv[2][1]), Float(c.inv[2][2]), 0)]
                }
            }
            let pf = pack(fg), pbg = pack(bg)
            let px = try G.buffer(img.px.map { SIMD4($0, 0) }), cfb = try G.buffer(pf), cbb = try G.buffer(pbg)
            let out = try G.zeros(2 * n, of: Float.self)
            try G.run("gmm costs") { e in
                try e.dispatch("pca_seg_gmm_costs", CostParams(n: UInt32(n), nfg: UInt32(pf.count / 4), nbg: UInt32(pbg.count / 4)), [px, cfb, cbb, out], n)
            }
            let o = G.read(out, 2 * n, as: Float.self)
            return (Array(o[0..<n]), Array(o[n...]))
        }

        struct SLICParams: BitwiseCopyable {
            var w: UInt32; var h: UInt32; var r: Int32; var wxy: Float
            var nbx: Int32; var nby: Int32; var bucket: Int32; var pad0: Int32 = 0
        }

        /// One SLIC assignment: each pixel takes the nearest centre whose (2r+1)² window covers it,
        /// ties to the lowest index; uncovered pixels keep their label.
        static func slicAssign(_ lab: any MTLBuffer, _ labels: [UInt32], _ centers: [[Float]], w: Int, h: Int, r: Int, wxy: Float) throws -> [UInt32] {
            let b = max(r, 1)
            let nbx = (w + b - 1) / b, nby = (h + b - 1) / b
            var buckets = [[UInt32]](repeating: [], count: nbx * nby)
            var packed: [SIMD4<Float>] = []
            for (k, c) in centers.enumerated() {
                let cx = Int(c[3].rounded()), cy = Int(c[4].rounded())
                let bx = min(max(cx / b, 0), nbx - 1), by = min(max(cy / b, 0), nby - 1)
                buckets[by * nbx + bx].append(UInt32(k))
                packed.append(SIMD4(c[0], c[1], c[2], 0))
                packed.append(SIMD4(c[3], c[4], Float(cx), Float(cy)))
            }
            var starts: [UInt32] = [0]
            var items: [UInt32] = []
            for bk in buckets { items.append(contentsOf: bk); starts.append(UInt32(items.count)) }
            let cb = try G.buffer(packed), sb = try G.buffer(starts), ib = try G.buffer(items), lb = try G.buffer(labels)
            let p = SLICParams(w: UInt32(w), h: UInt32(h), r: Int32(r), wxy: wxy, nbx: Int32(nbx), nby: Int32(nby), bucket: Int32(b))
            try G.run("slic assign") { e in try e.dispatch("pca_seg_slic_assign", p, [lab, cb, sb, ib, lb], w, h) }
            return G.read(lb, w * h, as: UInt32.self)
        }

        struct FocusParams: BitwiseCopyable { var w: UInt32; var h: UInt32; var pad0: UInt32 = 0; var pad1: UInt32 = 0 }

        /// Focus measure: the luma Laplacian energy, then its box mean of radius `r`.
        static func focusEnergy(_ img: SegmentRGBImage, r: Int) throws -> [Float] {
            let w = img.w, h = img.h, n = w * h
            if n == 0 { return [] }
            let px = try G.buffer(img.px.map { SIMD4($0, 0) })
            let lap = try G.zeros(n, of: Float.self), tmp = try G.zeros(n, of: Float.self), out = try G.zeros(n, of: Float.self)
            try G.run("focus") { e in
                try e.dispatch("pca_seg_laplacian", FocusParams(w: UInt32(w), h: UInt32(h)), [px, lap], w, h)
                try encodeBoxMean(e, lap, tmp, out, w: w, h: h, r: r, planes: 1)
            }
            return G.read(out, n, as: Float.self)
        }
    }
}
