// Port of photocraft-algo (crates/algo/src/panorama.rs tests), MIT OR Apache-2.0, © ArtCraft Team and the PhotoCraft contributors.

import Foundation
import Testing
@testable import PCAlgo
import PCFoundation

@Suite struct PhotoPanoramaTests {
    typealias Placement = Panorama.Placement

    /// Smooth random texture: blobs over a gradient.
    static func scene(_ w: Int, _ h: Int, _ seed: UInt64) -> [Float] {
        var rng = PhotoKit.Rng(seed)
        var img: [Float] = (0..<(w * h)).map { 0.25 + 0.2 * (Float($0 % w) / Float(w)) }
        for _ in 0..<max(w * h / 900, 40) {
            let cx = Double(rng.next() % UInt64(w)), cy = Double(rng.next() % UInt64(h))
            let r = 3.0 + Double(rng.next() % 9)
            let v = Float(rng.next() % 1000) / 1000
            let sq = rng.next() % 2 == 0
            let x0 = PhotoKit.usize(max(cx - r, 0)), x1 = min(PhotoKit.usize(cx + r) + 1, w)
            let y0 = PhotoKit.usize(max(cy - r, 0)), y1 = min(PhotoKit.usize(cy + r) + 1, h)
            for y in y0..<y1 {
                for x in x0..<x1 {
                    let dx = Double(x) - cx, dy = Double(y) - cy
                    if sq ? (abs(dx) < r && abs(dy) < r * 0.6) : hypot(dx, dy) < r { img[y * w + x] = v }
                }
            }
        }
        return img
    }

    /// photo_util `bilinear` (edge-clamped), nil outside the image.
    static func sample(_ img: [Float], _ w: Int, _ h: Int, _ x: Double, _ y: Double) -> Float? {
        if x < 0 || y < 0 || x > Double(w - 1) || y > Double(h - 1) { return nil }
        let xf = PhotoKit.clamp(Float(x), 0, Float(w - 1)), yf = PhotoKit.clamp(Float(y), 0, Float(h - 1))
        let x0 = Int(xf.rounded(.down)), y0 = Int(yf.rounded(.down))
        let x1 = min(x0 + 1, w - 1), y1 = min(y0 + 1, h - 1)
        let tx = xf - Float(x0), ty = yf - Float(y0)
        func p(_ xx: Int, _ yy: Int) -> Float { img[yy * w + xx] }
        let top = p(x0, y0) + (p(x1, y0) - p(x0, y0)) * tx
        let bot = p(x0, y1) + (p(x1, y1) - p(x0, y1)) * tx
        return top + (bot - top) * ty
    }

    static func view(_ scene: [Float], _ sw: Int, _ sh: Int, _ tw: Int, _ th: Int, _ map: (Double, Double) -> (Double, Double)) -> [Float] {
        (0..<(tw * th)).map { i in
            let (x, y) = map(Double(i % tw), Double(i / tw))
            return sample(scene, sw, sh, x, y) ?? 0
        }
    }

    @Test func recoversTranslationsAndHomographies() throws {
        let (sw, sh) = (640, 300)
        let sc = Self.scene(sw, sh, 3)
        let (tw, th) = (260, 220)
        let offs: [(Double, Double)] = [(20, 30), (190, 40), (360, 25)]
        let imgs = offs.map { o in Self.view(sc, sw, sh, tw, th) { ($0 + o.0, $1 + o.1) } }
        let feats = try imgs.map { try Panorama.detect(width: tw, height: th, luma: $0, max: 700) }
        let matches = Panorama.matchPairs(feats)
        #expect(matches.count >= 2, "\(matches.count)")
        for layout in [Panorama.Layout.reposition, .collage, .perspective] {
            let a = try #require(Panorama.align(feats, matches: matches, options: .init(layout: layout, reference: 1)))
            #expect(a.reference == 1)
            for (i, p) in a.placements.enumerated() {
                let p = try #require(p)
                let (u, v) = p.forward(50, 60)
                let eu = 50 + offs[i].0 - offs[1].0, ev = 60 + offs[i].1 - offs[1].1
                #expect(abs(u - eu) < 1 && abs(v - ev) < 1, "\(layout) image \(i): (\(u),\(v)) vs (\(eu),\(ev))")
            }
            #expect(a.rms < 1, "\(layout) rms \(a.rms)")
        }
        let hq = Homography([1.05, 0.03, 180.0, -0.02, 1.0, 35.0, 0.0001, -0.00005, 1.0])
        let im2 = Self.view(sc, sw, sh, tw, th) { hq.apply($0, $1) }
        let feats2 = [feats[0], try Panorama.detect(width: tw, height: th, luma: im2, max: 700)]
        let m2 = Panorama.matchPairs(feats2)
        let a = try #require(Panorama.align(feats2, matches: m2, options: .init(layout: .perspective, reference: 0)))
        let p = try #require(a.placements[1])
        for (x, y) in [(20.0, 30.0), (70.0, 180.0), (40.0, 100.0)] {
            let (sx, sy) = hq.apply(x, y)
            let (u, v) = p.forward(x, y)
            #expect(abs(u - (sx - 20)) < 1.5 && abs(v - (sy - 30)) < 1.5, "(\(u),\(v)) vs (\(sx - 20),\(sy - 30))")
        }
    }

    @Test func rotatingCameraFocalAndCylindricalLayout() throws {
        let f = 300.0
        let (sw, sh) = (1400, 500)
        let sc = Self.scene(sw, sh, 9)
        let (tw, th) = (320, 240)
        let pans: [Double] = [-25, 0, 25]
        let imgs = pans.map { deg in
            Self.view(sc, sw, sh, tw, th) { x, y in
                let dx = x - Double(tw) / 2, dy = y - Double(th) / 2
                let t = atan2(dx, f) + PhotoKit.radians(deg)
                let hh = dy / hypot(dx, f)
                return (Double(sw) / 2 + f * t, Double(sh) / 2 + f * hh)
            }
        }
        let feats = try imgs.map { try Panorama.detect(width: tw, height: th, luma: $0, max: 700) }
        let matches = Panorama.matchPairs(feats)
        #expect(matches.filter { $0.b == $0.a + 1 }.count == 2)
        let est = matches.compactMap { Panorama.focalFromHomography($0.homography, SIMD2(160, 120), SIMD2(160, 120)) }
        #expect(est.contains { abs($0 - f) / f < 0.15 }, "focal estimates \(est)")
        let a = try #require(Panorama.align(feats, matches: matches, options: .init(layout: .cylindrical, reference: 1)))
        #expect(abs(a.focal - f) / f < 0.1, "focal \(a.focal)")
        let p = try #require(a.placements[2])
        let (u, _) = p.forward(160, 120)
        let expect = 160 + a.focal * PhotoKit.radians(25)
        #expect(abs(u - expect) < 4, "\(u) vs \(expect)")
        #expect(a.rms < 1.5, "rms \(a.rms)")
        let (u2, v2) = p.forward(40, 200)
        let (x, y) = try #require(p.inverse(u2, v2))
        #expect(abs(x - 40) < 1e-6 && abs(y - 200) < 1e-6)
    }

    @Test func placementRoundTripsAllProjections() throws {
        for projection in Panorama.Projection.allCases {
            let p = Placement(projection: projection, focal: 400, center: SIMD2(200, 150), k1: 0.05,
                              h: Homography([0.98, -0.1, 30.0, 0.1, 0.98, -12.0, 0.0, 0.0, 1.0]))
            for (x, y) in [(0.0, 0.0), (390.0, 20.0), (123.0, 280.0)] {
                let (u, v) = p.forward(x, y)
                let (bx, by) = try #require(p.inverse(u, v))
                #expect(abs(bx - x) < 1e-6 && abs(by - y) < 1e-6, "\(projection)")
            }
            let s = p.scaled(2)
            let (u, v) = p.forward(100, 50)
            let (u2, v2) = s.forward(200, 100)
            #expect(abs(u2 - 2 * u) < 1e-6 && abs(v2 - 2 * v) < 1e-6)
        }
    }

    @Test func photometricRecoversGainAndVignette() {
        let (w, h) = (200, 100)
        func base(_ x: Int32, _ y: Int32) -> Float { 0.3 + 0.2 * abs(sinf(Float(x) * 0.05) * cosf(Float(y) * 0.07)) }
        var imgs: [Panorama.RoiImage] = [], pls: [Placement] = []
        for (x0, g) in [(Int32(0), Float(1.0)), (Int32(100), Float(1.3))] {
            var px: [Float] = []
            for y in 0..<Int32(h) { for x in 0..<Int32(w) { px.append(base(x + x0, y) * g) } }
            imgs.append(Panorama.RoiImage(x0: x0, y0: 0, w: w, h: h, ch: 1, px: px, alpha: [Float](repeating: 1, count: w * h)))
            pls.append(Placement(projection: .plane, focal: 200, center: SIMD2(100, 50), k1: 0, h: Homography([1, 0, 100 + Double(x0), 0, 1, 50, 0, 0, 1])))
        }
        let ph = Panorama.photometric(imgs, geometry: (pls, [(w, h), (w, h)]), gain: true, vignette: false)
        let ratio = ph.gains[1][0] / ph.gains[0][0]
        #expect(abs(ratio - 1.3) < 0.03, "\(ph)")
        let pv = Panorama.photometric(imgs, geometry: (pls, [(w, h), (w, h)]), gain: true, vignette: true)
        #expect(abs(pv.vignette[0]) < 0.1, "\(pv)")
    }

    @Test func seamsAvoidDisagreementAndMultibandIsSeamless() throws {
        let (w, h) = (120, 40)
        var luma = [[Float]](repeating: [Float](repeating: 0.5, count: w * h), count: 2)
        let cover: [[Bool]] = [(0..<(w * h)).map { $0 % w < 80 }, (0..<(w * h)).map { $0 % w >= 40 }]
        for y in 0..<h { for x in 50..<58 { luma[1][y * w + x] = 1 } }
        let labels = Panorama.seamLabels(width: w, height: h, luma: luma, cover: cover, order: [0, 1])
        for y in 0..<h {
            let owner = (50..<58).map { labels[y * w + $0] }
            #expect(owner.allSatisfy { $0 == owner[0] }, "row \(y) split the object: \(owner)")
        }
        #expect(labels[5] == 0)
        #expect(labels[w - 1] == 1)
        func mk(_ x0: Int32, _ v: Float) -> Panorama.RoiImage {
            Panorama.RoiImage(x0: x0, y0: 0, w: 80, h: h, ch: 1, px: [Float](repeating: v, count: 80 * h), alpha: [Float](repeating: 1, count: 80 * h))
        }
        let imgs = [mk(0, 0.3), mk(40, 0.7)]
        let wts: [[Float]] = (0..<2).map { k in (0..<(80 * h)).map { i in ((Int32(i % 80) + imgs[k].x0) < 60) == (k == 0) ? 1 : 0 } }
        for backend in PhotoTest.backends {
            let (out, cov) = try Panorama.multiband(width: w, height: h, images: imgs, weights: wts, levels: 4, on: backend)
            let row = (0..<w).map { out[20 * w + $0] }
            #expect(abs(row[2] - 0.3) < 0.02 && abs(row[w - 3] - 0.7) < 0.02, "\(row)")
            let maxJump = zip(row, row.dropFirst()).map { abs($1 - $0) }.max()!
            #expect(maxJump < 0.1, "max step \(maxJump)")
            #expect(cov.allSatisfy { $0 == 1 })
        }
    }

    /// The Metal multi-band blend is bit-identical to the CPU's (holes, partial coverage, offsets
    /// clipped by the canvas, several channel counts and level counts).
    @Test func multibandGPUParity() throws {
        guard PhotoTest.gpu else { return }
        var worst: Float = 0
        for (w, h, ch, levels) in [(150, 90, 3, 4), (97, 61, 1, 7), (64, 64, 4, 1), (200, 37, 2, 5)] {
            var imgs: [Panorama.RoiImage] = [], wts: [[Float]] = []
            for k in 0..<3 {
                let rw = w / 2 + 7 * k, rh = h - 5 * k
                let x0 = Int32(k * w / 4) - (k == 2 ? 3 : 0), y0 = Int32(k * 2)
                let px = PhotoTest.pixels(rw, rh, ch, seed: UInt32(20 + k), hdr: k == 1)
                let alpha: [Float] = (0..<(rw * rh)).map { i in
                    let x = i % rw, y = i / rw
                    if hypotf(Float(x) - Float(rw) * 0.5, Float(y) - Float(rh) * 0.5) < 6 { return 0 }
                    return x < 4 ? Float(x) / 4 : 1
                }
                imgs.append(Panorama.RoiImage(x0: x0, y0: y0, w: rw, h: rh, ch: ch, px: px, alpha: alpha))
                wts.append((0..<(rw * rh)).map { i in hash01(Int32(i % rw), Int32(i / rw), UInt32(k), 3) > 0.4 ? 1 : 0.25 })
            }
            let (pc, cc) = try Panorama.multiband(width: w, height: h, images: imgs, weights: wts, levels: levels, on: .cpu)
            let (pg, cg) = try Panorama.multiband(width: w, height: h, images: imgs, weights: wts, levels: levels, on: .gpu)
            worst = max(worst, PhotoTest.maxDiff(pc, pg), PhotoTest.maxDiff(cc, cg))
        }
        ParityLog.record("Panorama multiband", worst)
        #expect(worst == 0)
    }

    @Test func pushPullFillsHolesFromTheirSurroundings() {
        let (w, h) = (9, 7)
        var px: [Float] = (0..<(w * h)).map { Float($0 % w) / Float(w) }
        let wt: [Float] = (0..<(w * h)).map { ($0 % w) > 5 ? 0 : 1 }
        let before = px
        Panorama.pushPull(w, h, 1, &px, wt)
        for i in 0..<(w * h) where wt[i] == 1 { #expect(px[i] == before[i]) }
        for i in 0..<(w * h) where wt[i] == 0 { #expect(px[i] > 0.2 && px[i] < 0.7, "\(px[i])") }
    }

    @Test func layoutNamesRoundTrip() {
        for l in Panorama.Layout.allCases { #expect(Panorama.Layout(parsing: l.name) == l) }
        #expect(Panorama.Layout(parsing: "fisheye") == nil)
    }
}
