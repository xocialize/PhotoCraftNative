// Port of photocraft-algo (crates/algo/src/segment/grabcut.rs), MIT OR Apache-2.0, © ArtCraft Team and the PhotoCraft contributors.
//
// GrabCut and rectangle Object Selection (Rother, Kolmogorov & Blake, SIGGRAPH 2004): a trimap
// (definite / probable foreground and background), 5-component full-covariance GMMs per side, and
// iterated "assign components → learn GMMs → min cut" steps with the contrast-sensitive smoothness
// γ e^{−β‖z_m − z_n‖²}/dist(m, n) (γ = 50, β from the mean squared neighbour difference).

import Foundation
import PCFoundation

/// GrabCut and Object Selection (photocraft `segment::grabcut`).
public enum GrabCut {
    /// Definite background.
    public static let bg: UInt8 = 0
    /// Definite foreground.
    public static let fg: UInt8 = 1
    /// Probable background.
    public static let prBG: UInt8 = 2
    /// Probable foreground.
    public static let prFG: UInt8 = 3
    /// GrabCut's smoothness weight.
    public static let gamma: Float = 50
    /// Components per GMM.
    public static let k = 5
    static let maxSamples = 40_000

    static func isFG(_ t: UInt8) -> Bool { t == fg || t == prFG }

    /// Runs `iters` GrabCut iterations, updating the probable labels of `trimap` in place; returns
    /// the final (foreground, background) models, or nil if either side has no pixels.
    @discardableResult
    public static func grabcut(_ img: SegmentRGBImage, trimap: inout [UInt8], iters: Int) -> (GMM, GMM)? {
        let beta = QuickSelection.contrastBeta(img)
        let fixed = trimap.map { $0 == fg ? QuickSelection.hardFG : ($0 == bg ? QuickSelection.hardBG : QuickSelection.free) }
        var models: (GMM, GMM)?
        for _ in 0..<max(iters, 1) {
            var fs: [SIMD3<Float>] = [], bs: [SIMD3<Float>] = []
            for (p, t) in zip(img.px, trimap) { if isFG(t) { fs.append(p) } else { bs.append(p) } }
            fs = Segment.subsample(fs, max: maxSamples)
            bs = Segment.subsample(bs, max: maxSamples)
            let f: GMM, b: GMM
            if let (pf, pb) = models {
                f = pf.refit(fs) ?? pf
                b = pb.refit(bs) ?? pb
            } else {
                guard let nf = GMM.fit(fs, k: k, reg: GMM.defaultReg), let nb = GMM.fit(bs, k: k, reg: GMM.defaultReg) else { return nil }
                f = nf; b = nb
            }
            let (cf, cb) = (try? Segment.dataCosts(img, fg: f, bg: b)) ?? ([], [])
            let cut = QuickSelection.gridCut(img, costFG: cf, costBG: cb, fixed: fixed, gamma: gamma, beta: beta)
            var changed = 0
            for i in 0..<min(trimap.count, cut.count) where trimap[i] == prBG || trimap[i] == prFG {
                let nt = cut[i] ? prFG : prBG
                if nt != trimap[i] { changed += 1 }
                trimap[i] = nt
            }
            models = (f, b)
            if changed * 2000 < trimap.count { break }
        }
        return models
    }

    /// Object Selection (rectangle mode): GrabCut initialised from `rect` (outside background,
    /// inside probable foreground) on a working copy of about `workPx` pixels, then the boundary
    /// re-cut at full resolution. `canvas` bounds the analysis.
    public static func objectSelect(_ sampler: any SegmentSampler, canvas: PixelRect, rect r0: PixelRect, workPx: Int) -> SelectionRegion? {
        let rect = r0.intersect(canvas)
        if rect.width < 2 || rect.height < 2 { return nil }
        let margin = max(PCAMath.i32((Float(max(rect.width, rect.height)) * 0.15).rounded(.up)), 8)
        let window = rect.outset(by: margin).intersect(canvas)
        let step = Segment.scaleFor(window, maxPx: workPx)
        let img = sampler.rgbScaled(window, step: step)
        let lw = img.w, lh = img.h
        var trimap = [UInt8](repeating: bg, count: lw * lh)
        // Working pixel (x, y) covers doc pixels [x0 + x·step, …); its centre decides inside/outside.
        var anyBG = false
        for y in 0..<lh {
            for x in 0..<lw {
                let cx = window.x0 + Int32(x * step + step / 2), cy = window.y0 + Int32(y * step + step / 2)
                if rect.contains(x: cx, y: cy) { trimap[y * lw + x] = prFG } else { anyBG = true }
            }
        }
        if !anyBG {
            // The rectangle covers the whole canvas: a thin outer ring is background.
            let ring = max(min(lw, lh) / 50, 1)
            for y in 0..<lh { for x in 0..<lw where x < ring || y < ring || x + ring >= lw || y + ring >= lh { trimap[y * lw + x] = bg } }
        }
        guard let (f, b) = grabcut(img, trimap: &trimap, iters: 8) else { return nil }
        let low = Segment.cleanMask(trimap.map(isFG), w: lw, h: lh, frac: 0.1, holeFrac: 0.002)
        return Segment.finishRegion(sampler, window: window, step: step, low: low, lw: lw, lh: lh, models: (f, b))
    }
}
