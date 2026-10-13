// Photoshop 27.11 as a function oracle: measurement batch M1 (ps-oracle `measure m1`, see
// Tools/PhotoshopOracle/RESULTS.md §5b). New in the port (phase 4); no photocraft counterpart.
//
// `PCRENDER_M1_DIR` is the batch directory (inputs/, psd/, tif/, manifest.json; default
// `$PHOTOCRAFT_FIXTURES/ps-measure/M1`, see Fixtures.swift); without it every test here is skipped. Each test rebuilds Photoshop's job as a document (or as the effect
// map it isolates), renders it with the CPU reference and Metal (CPU-vs-GPU checked as in every
// end-to-end test), and compares with Photoshop's flattened TIFF in 8-bit levels: max, mean and
// the share of pixels more than 2 levels off. `PCRENDER_M1_LOG=1` prints every fit.

import CoreGraphics
import Foundation
import ImageIO
import simd
import Testing
import PCDocument
import PCFoundation
@testable import PCRender

enum M1 {
    /// `PCRENDER_M1_DIR`, default `<fixtures>/ps-measure/M1`; nil without its `manifest.json`.
    static let dir: URL? = {
        guard let u = Fixtures.directory("PCRENDER_M1_DIR", default: "ps-measure/M1") else { return nil }
        return FileManager.default.fileExists(atPath: u.appendingPathComponent("manifest.json").path) ? u : nil
    }()
    static var available: Bool { dir != nil }
    static var log: Bool { ProcessInfo.processInfo.environment["PCRENDER_M1_LOG"] != nil }

    struct Image {
        var w: Int, h: Int, bits: Int
        /// Interleaved RGB samples (0…255 or 0…65535).
        var px: [Int32]
        func at(_ x: Int, _ y: Int) -> SIMD3<Int32> { let i = (y * w + x) * 3; return SIMD3(px[i], px[i + 1], px[i + 2]) }
        var scale: Float { bits == 16 ? 65535 : 255 }
        func rgb(_ x: Int, _ y: Int) -> SIMD3<Float> { let v = at(x, y); return SIMD3(Float(v.x), Float(v.y), Float(v.z)) / scale }
    }

    /// An RGB TIFF / PNG's stored samples (no colour management), relative to `root` (M1's batch).
    static func image(_ rel: String, root: URL? = dir) throws -> Image {
        let url = try #require(root).appendingPathComponent(rel)
        guard let src = CGImageSourceCreateWithURL(url as CFURL, nil), let img = CGImageSourceCreateImageAtIndex(src, 0, nil),
              let data = img.dataProvider?.data as Data? else { throw M1Error.unreadable(rel) }
        let (w, h, bpc, bpr) = (img.width, img.height, img.bitsPerComponent, img.bytesPerRow)
        let ch = img.bitsPerPixel / bpc
        let little = (img.bitmapInfo.rawValue & CGBitmapInfo.byteOrderMask.rawValue) == CGBitmapInfo.byteOrder16Little.rawValue
        let skip = [.first, .premultipliedFirst, .noneSkipFirst].contains(img.alphaInfo) ? 1 : 0
        var px = [Int32](repeating: 0, count: w * h * 3)
        data.withUnsafeBytes { (raw: UnsafeRawBufferPointer) in
            for y in 0..<h {
                for x in 0..<w {
                    for c in 0..<3 {
                        let k = c + skip
                        let v: Int32
                        if bpc == 8 {
                            v = Int32(raw[y * bpr + x * ch + k])
                        } else {
                            let o = y * bpr + (x * ch + k) * 2
                            let (a, b) = (UInt16(raw[o]), UInt16(raw[o + 1]))
                            v = Int32(little ? (a | b << 8) : (a << 8 | b))
                        }
                        px[(y * w + x) * 3 + c] = v
                    }
                }
            }
        }
        return Image(w: w, h: h, bits: bpc, px: px)
    }

    /// A 16-bit input as Photoshop holds it (15 bits: v >> 1, read back as round(v15 · 65535 / 32768)).
    static func photoshop16(_ img: Image) -> Image {
        var o = img
        o.px = img.px.map { Int32((Double($0 >> 1) * 65535 / 32768).rounded()) }
        return o
    }

    /// The manifest's jobs by id.
    static func jobs(root: URL? = dir) throws -> [String: [String: Any]] {
        let data = try Data(contentsOf: try #require(root).appendingPathComponent("manifest.json"))
        let root = try #require(try JSONSerialization.jsonObject(with: data) as? [String: Any])
        let list = try #require(root["jobs"] as? [[String: Any]])
        var out: [String: [String: Any]] = [:]
        for j in list { if let id = j["id"] as? String { out[id] = j } }
        return out
    }

    /// One layer's alpha from a PSD (8-bit, RLE or raw channels): its rect and samples.
    static func layerAlpha(psd rel: String, layer name: String, root: URL? = dir) throws -> (PixelRect, [UInt8]) {
        let d = [UInt8](try Data(contentsOf: try #require(root).appendingPathComponent(rel)))
        var p = 26
        func u16() -> Int { defer { p += 2 }; return Int(d[p]) << 8 | Int(d[p + 1]) }
        func i16() -> Int { let v = u16(); return v >= 32768 ? v - 65536 : v }
        func u32() -> Int { defer { p += 4 }; return Int(d[p]) << 24 | Int(d[p + 1]) << 16 | Int(d[p + 2]) << 8 | Int(d[p + 3]) }
        func i32() -> Int { let v = u32(); return v >= 1 << 31 ? v - (1 << 32) : v }
        p += u32()          // colour mode data
        p += u32()          // image resources
        _ = u32(); _ = u32() // layer and mask info, layer info lengths
        let count = abs(i16())
        var records: [(String, PixelRect, [(Int, Int)])] = []
        for _ in 0..<count {
            let (t, l, b, r) = (i32(), i32(), i32(), i32())
            var chans: [(Int, Int)] = []
            for _ in 0..<u16() { let id = i16(); chans.append((id, u32())) }
            p += 12
            let extra = u32(), end = p + extra
            p += u32(); p += u32()
            let n = Int(d[p])
            let layerName = String(bytes: d[(p + 1)..<(p + 1 + n)], encoding: .macOSRoman) ?? ""
            p = end
            records.append((layerName, PixelRect(x0: Int32(l), y0: Int32(t), x1: Int32(r), y1: Int32(b)), chans))
        }
        for (layerName, rect, chans) in records {
            let (w, h) = (rect.width, rect.height)
            for (id, len) in chans {
                let start = p
                defer { p = start + len }
                guard layerName == name, id == -1 else { continue }
                let comp = u16()
                if comp == 0 { return (rect, Array(d[p..<(p + w * h)])) }
                var out: [UInt8] = []
                out.reserveCapacity(w * h)
                let counts = (0..<h).map { _ in u16() }
                for c in counts {
                    let rowEnd = p + c
                    while p < rowEnd {
                        let k = Int(Int8(bitPattern: d[p])); p += 1
                        if k >= 0 { out += d[p..<(p + k + 1)]; p += k + 1 } else if k != -128 { out += [UInt8](repeating: d[p], count: 1 - k); p += 1 }
                    }
                }
                return (rect, out)
            }
        }
        throw M1Error.noLayer(name)
    }

    /// Identity input lattice: pixel (x, y < 512) holds entry n = 512y + x, r = n / 4096,
    /// g = (n / 64) mod 64, b = n mod 64, each round(i · 255 / 63); rows 512…527 a grey ramp.
    static func identity(_ x: Int, _ y: Int) -> SIMD3<Int32> {
        if y >= 512 { return SIMD3(repeating: Int32(x / 2)) }
        let n = y * 512 + x
        func v(_ i: Int) -> Int32 { Int32((Double(i) * 255 / 63).rounded()) }
        return SIMD3(v(n / 4096), v((n / 64) % 64), v(n % 64))
    }

    /// Max / mean levels and the share of pixels more than 2 levels off (worst channel per pixel).
    struct Fit: CustomStringConvertible {
        var n = 0, off = 0
        var max: Float = 0, sum: Double = 0
        mutating func add(_ levels: Float) {
            n += 1; sum += Double(levels)
            if levels > max { max = levels }
            if levels > 2 { off += 1 }
        }
        var mean: Float { Float(sum / Double(Swift.max(n, 1))) }
        var offShare: Float { Float(off) / Float(Swift.max(n, 1)) }
        var description: String { String(format: "max %.1f mean %.3f off %.3f %%", max, mean, offShare * 100) }
    }

    /// Photoshop's TIFF against a composite, in 8-bit levels (16-bit documents: 65535 / 255 units).
    static func fit(_ ps: Image, _ ours: RGBABuffer) -> Fit {
        var f = Fit()
        let s = ps.scale
        for y in 0..<ps.h {
            for x in 0..<ps.w {
                let o = ours.get(Int32(x), Int32(y))
                let mine = (simd_clamp(SIMD3(o.x, o.y, o.z), .zero, SIMD3(repeating: 1)) * s).rounded(.toNearestOrAwayFromZero)
                let v = ps.at(x, y)
                let d = simd_abs(mine - SIMD3(Float(v.x), Float(v.y), Float(v.z))) * 255 / s
                f.add(d.max())
            }
        }
        return f
    }

    /// A document holding `img` as its background.
    static func document(_ img: Image) -> Document {
        let depth: SampleType = img.bits == 16 ? .u16 : .u8
        var d = Document.withBackground(name: "m1", size: PixelSize(width: img.w, height: img.h), mode: .rgb, depth: depth, fill: .white)
        d.layers[0] = rasterLayer("Background", img)
        d.layers[0].locks.transparency = true
        d.layers[0].locks.position = true
        return d
    }

    static func rasterLayer(_ name: String, _ img: Image) -> Layer {
        let format = PixelFormat(mode: .rgb, sample: img.bits == 16 ? .u16 : .u8, alpha: true)
        var data = [Float](repeating: 1, count: img.w * img.h * 4)
        for i in 0..<(img.w * img.h) { for c in 0..<3 { data[i * 4 + c] = Float(img.px[i * 3 + c]) / img.scale } }
        var s = Surface(format: format)
        s.writeRegion(PixelRect(x0: 0, y0: 0, x1: Int32(img.w), y1: Int32(img.h)), data)
        return Layer.raster(name, surface: s)
    }

    static func say(_ s: String) { if log { print("m1: \(s)") } }

    /// CPU-vs-Metal tolerance where results round to document levels: one level, plus float slack
    /// for the flips `pow` / `exp` differences leave at a rounding boundary.
    static let flip: Float = 1.001 / 255
}

enum M1Error: Error { case unreadable(String), noLayer(String) }

@Suite(.enabled(if: M1.available, "measurement batch M1 not present (set PHOTOCRAFT_FIXTURES or PCRENDER_M1_DIR)"))
struct PhotoshopM1Tests {
    // MARK: Satin

    static let satinIDs: [String] = {
        var ids: [String] = []
        for c in ["linear", "gaussian", "cone", "cone-inverted", "ring"] { for inv in ["", "-inv"] { ids.append("satin-\(c)\(inv)-a19-d11-s14") } }
        return ids + ["satin-linear-a90-d11-s14", "satin-linear-a19-d30-s5", "satin-cone-a90-d11-s14", "satin-cone-a19-d30-s5"]
    }()

    /// The job's Satin with Photoshop's stored contour (smooth points: M1's PSDs carry no `Cnty`).
    /// Jobs without stored points (M2) take the points M1 stored for the same preset.
    static func satin(_ job: [String: Any]) throws -> Satin {
        let p = try #require(job["params"] as? [String: Any])
        let name = try #require(p["contour"] as? String)
        var stored = (job["result"] as? [String: Any])?["storedSatin"] as? [String: Any]
        if stored == nil, name != "Linear" {
            stored = try M1.jobs().values.compactMap { j -> [String: Any]? in
                guard ((j["params"] as? [String: Any])?["contour"] as? String) == name else { return nil }
                return (j["result"] as? [String: Any])?["storedSatin"] as? [String: Any]
            }.first
        }
        let pts = name == "Linear" ? [[0.0, 0.0], [255.0, 255.0]] : try #require(stored?["points"] as? [[Double]])
        let contour: Contour = name == "Linear" ? .linear
            : .custom(.init(name: name, points: pts.map { CurvePoint(input: Float($0[0] / 255), output: Float($0[1] / 255)) }))
        let color = try #require(p["color"] as? [Double])
        let mode: BlendMode = (p["mode"] as? String) == "multiply" ? .multiply : .normal
        return Satin(common: FxCommon(mode, Float(try #require(p["opacity"] as? Double)) / 100),
                     color: .rgb(Float(color[0] / 255), Float(color[1] / 255), Float(color[2] / 255)),
                     angle: Float(try #require(p["angle"] as? Double)), distance: Float(try #require(p["distance"] as? Double)),
                     size: Float(try #require(p["size"] as? Double)), contour: contour,
                     antiAlias: (p["antialias"] as? Bool) ?? false, invert: (p["invert"] as? Bool) ?? false)
    }

    /// The raw maps (Fill 0 % over black, white Normal 100 % Satin): the effect map itself.
    @Test func satinRawMaps() throws {
        let jobs = try M1.jobs()
        var worst = M1.Fit()
        for id in Self.satinIDs {
            let raw = "\(id)-raw"
            let job = try #require(jobs[raw])
            let ps = try M1.image("tif/\(raw).tif")
            let (rect, alpha) = try M1.layerAlpha(psd: "psd/\(raw).psd", layer: "Shapes")
            var shape = FxMap(w: ps.w, h: ps.h)
            for y in rect.y0..<rect.y1 {
                for x in rect.x0..<rect.x1 {
                    shape.v[Int(y) * ps.w + Int(x)] = Float(alpha[Int(y - rect.y0) * rect.width + Int(x - rect.x0)]) / 255
                }
            }
            let m = EffectMath.satinMap(shape, try Self.satin(job))
            var f = M1.Fit()
            for i in shape.v.indices where shape.v[i] > 0 {
                f.add(abs((m.v[i] * 255).rounded() - Float(ps.px[i * 3])))
            }
            M1.say("\(raw): \(f)")
            // Ring's raw map stays 5–8 % > 2 levels (max 5): Photoshop's contour spline sits up to
            // 0.015 below the natural spline through Ring's points; the composites are ≤ 1.3 %.
            #expect(f.mean < 1 && f.offShare < 0.08, "\(raw): \(f)")
            if f.mean > worst.mean { worst = f }
        }
        M1.say("satin raw maps, worst mean: \(worst)")
    }

    /// The full jobs (white shapes over 128 grey, black Multiply 50 % Satin) through the compositor.
    @Test func satinComposites() throws {
        let jobs = try M1.jobs()
        for id in Self.satinIDs {
            for name in [id, "\(id)-raw"] {
                let job = try #require(jobs[name])
                let p = try #require(job["params"] as? [String: Any])
                let ps = try M1.image("tif/\(name).tif")
                let bg = try #require(p["background"] as? [Double])
                var d = Document.withBackground(name: name, size: PixelSize(width: ps.w, height: ps.h), mode: .rgb, depth: .u8,
                                                fill: .rgb(Float(bg[0] / 255), Float(bg[1] / 255), Float(bg[2] / 255)))
                let (rect, alpha) = try M1.layerAlpha(psd: "psd/\(name).psd", layer: "Shapes")
                var data = [Float](repeating: 1, count: rect.area * 4)
                for i in 0..<rect.area { data[i * 4 + 3] = Float(alpha[i]) / 255 }
                var l = Layer.raster("Shapes", format: DT.rgba8)
                l.withRaster { $0.writeRegion(rect, data) }
                l.fillOpacity = Float((p["layerFill"] as? Double) ?? 100) / 100
                l.effects.items = [.satin(try Self.satin(job))]
                d.layers.append(l)
                let f = M1.fit(ps, DT.render(d, name: name))
                M1.say("\(name) composite: \(f)")
                #expect(f.mean < 1 && f.offShare < 0.05, "\(name): \(f)")
            }
        }
    }

    // MARK: Brightness / Contrast

    /// Light-mode Brightness/Contrast. M1's B/C layers were made in Photoshop 27's default Light
    /// mode (`brightnessModeLight`, which drops Brightness: `Brgh` is 0 in every PSD), so they
    /// measure Light Contrast −50, 0, 50, 100.
    @Test func lightContrast() throws {
        let base = try M1.image("tif/identity-rgb8.tif")
        for c in [-50, 0, 50, 100] {
            let ps = try M1.image("tif/bc-b0-c\(c)-rgb8.tif")
            var d = M1.document(base)
            d.layers.append(DT.adjustment(.brightnessContrast(.init(contrast: Float(c), mode: .light))))
            let f = M1.fit(ps, DT.render(d, tol: M1.flip, name: "bc-c\(c)"))
            M1.say("bc contrast \(c): \(f)")
            // Not exact yet (PORT-NOTES phase 4): saturated colours keep a (max, min)-dependent
            // residual of up to 3 levels in ProPhoto γ 1.8 that dark blues amplify in sRGB.
            #expect(f.mean < 2.1 && f.offShare < 0.25, "contrast \(c): \(f)")
        }
    }

    // MARK: Vibrance

    @Test func vibrance() throws {
        let base = try M1.image("tif/identity-rgb8.tif")
        for v in [-100, -50, 50, 100] {
            for s in [-50, 0, 50] {
                let ps = try M1.image("tif/vib-v\(v)-s\(s)-rgb8.tif")
                var d = M1.document(base)
                d.layers.append(DT.adjustment(.vibrance(vibrance: Float(v), saturation: Float(s))))
                let f = M1.fit(ps, DT.render(d, tol: M1.flip, name: "vib-v\(v)-s\(s)"))
                M1.say("vibrance \(v) saturation \(s): \(f)")
                // Saturation +50 amplifies the Vibrance stage's 1–3-level misses on colours whose
                // smallest channel lands near 0 (4–5 % of pixels).
                #expect(f.mean < 0.7 && f.offShare < 0.05, "vibrance \(v) saturation \(s): \(f)")
            }
        }
    }

    // MARK: Non-separable blends

    @Test func nonSeparableBlends() throws {
        let cases: [(BlendMode, String, Int)] = [(.luminosity, "luminosity", 8), (.color, "color", 8), (.hue, "hue", 8), (.saturation, "saturation", 8),
                                                 (.luminosity, "luminosity", 16)]
        for (mode, name, bits) in cases {
            for perm in ["a", "b"] {
                let job = "blend-\(name)-perm\(perm)-rgb\(bits)"
                let ps = try M1.image("tif/\(job).tif")
                var base = try M1.image(bits == 16 ? "tif/identity-rgb16.tif" : "inputs/identity-rgb8.png")
                var top = try M1.image("inputs/perm-\(perm)-rgb\(bits).png")
                if bits == 16 { top = M1.photoshop16(top) } else { base.bits = 8 }
                var d = M1.document(base)
                var l = M1.rasterLayer("top", top)
                l.blend = mode
                d.layers.append(l)
                let f = M1.fit(ps, DT.render(d, tol: M1.flip, name: job))
                M1.say("\(job): \(f)")
                #expect(f.max <= 1.01 && f.offShare == 0, "\(job): \(f)")
            }
        }
    }

    // MARK: Dissolve

    /// Characterisation only (Photoshop's pattern is not reproduced; see PORT-NOTES phase 4).
    @Test func dissolveCharacterisation() throws {
        func mask(_ id: String) throws -> (Int, Int, [Bool]) {
            let img = try M1.image("tif/\(id).tif")
            var m = [Bool](repeating: false, count: img.w * img.h)
            for y in 0..<img.h { for x in 0..<img.w { m[y * img.w + x] = img.at(x, y) == SIMD3(255, 0, 0) } }
            return (img.w, img.h, m)
        }
        let (w, h, a) = try mask("dissolve-a")
        let (_, _, b) = try mask("dissolve-b")
        let (wo, _, o) = try mask("dissolve-offset")
        #expect(a == b, "two builds differ")
        var same = 0, n = 0
        for y in 53..<256 { for x in 37..<256 { n += 1; if o[y * wo + x] == a[y * w + x] { same += 1 } } }
        #expect(same == n, "not anchored to the canvas: \(same)/\(n)")
        let coverage = Float(a.filter { $0 }.count) / Float(a.count)
        // Ours at the same 50 % over the same canvas.
        var ours = 0, agree = 0
        for y in 0..<h {
            for x in 0..<w {
                let red = PSBlend.dissolveNoise(Int32(x), Int32(y)) < 0.5
                if red { ours += 1 }
                if red == a[y * w + x] { agree += 1 }
            }
        }
        M1.say(String(format: "dissolve: Photoshop coverage %.4f, ours %.4f, pixel agreement %.4f", coverage, Float(ours) / Float(a.count),
                      Float(agree) / Float(a.count)))
        #expect(abs(coverage - 0.5104) < 0.001)
    }
}

/// PCIO's phase-4 requests (Photoshop's composites in ps-corpus; no M1 data needed).
struct Phase4RequestTests {
    /// A Grayscale document shows an RGB fill colour as its grey, as it stores it.
    @Test func grayDocumentFillsAreGrey() {
        var d = DT.docWhite(8, 8, mode: .grayscale)
        let red = PCColor.rgb(0.9, 0.2, 0.1)
        d.layers.append(Layer(name: "fill", content: .fill(.solid(red))))
        let p = DT.px(d, 3, 3)
        let g = ColorConvert.rgbToGray(red.rgb)
        #expect(abs(p.x - g) <= 1.0 / 255 && p.x == p.y && p.y == p.z, "\(p) vs grey \(g)")
    }

    /// Selective Color in a Grayscale document leaves grey pixels grey.
    @Test func grayDocumentSelectiveColorIsGrey() {
        var d = DT.docWhite(8, 8, mode: .grayscale)
        d.layers.append(DT.solidLayer("g", DT.rect(0, 0, 8, 8), DT.rgba(0.5, 0.5, 0.5)))
        var adj = [SIMD4<Float>](repeating: .zero, count: 9)
        adj[7] = SIMD4(0.6, -0.3, 0.2, 0.1)   // Neutrals
        d.layers.append(DT.adjustment(.selectiveColor(relative: false, adjustments: adj)))
        let p = DT.px(d, 3, 3)
        #expect(p.x == p.y && p.y == p.z, "\(p)")
    }

    /// Gradient Map reads Photoshop's luminosity 0.30 / 0.59 / 0.11.
    @Test func gradientMapUsesPhotoshopLuminosity() {
        var d = DT.docWhite(8, 8, depth: .u16)
        d.layers.append(DT.solidLayer("c", DT.rect(0, 0, 8, 8), DT.rgba(1, 0, 0), format: PixelFormat(mode: .rgb, sample: .u16, alpha: true)))
        d.layers.append(DT.adjustment(.gradientMap(stops: [GradientMapStop(0, SIMD3(0, 0, 0)), GradientMapStop(1, SIMD3(1, 1, 1))], reverse: false, dither: false)))
        let p = DT.px(d, 3, 3)
        #expect(abs(p.x - 0.3) < 2e-4, "\(p.x) vs 0.30 (Rec. 601 would give 0.299)")
    }
}

// MARK: - Batch M2 (phase 5)

enum M2 {
    /// `PCRENDER_M2_DIR`, default `<fixtures>/ps-measure/M2`; nil without its `manifest.json`.
    static let dir: URL? = {
        guard let u = Fixtures.directory("PCRENDER_M2_DIR", default: "ps-measure/M2") else { return nil }
        return FileManager.default.fileExists(atPath: u.appendingPathComponent("manifest.json").path) ? u : nil
    }()
    static var available: Bool { dir != nil }
    static func image(_ rel: String) throws -> M1.Image { try M1.image(rel, root: dir) }
}

/// Photoshop 27.11 batch M2 (ps-oracle `measure m2`, RESULTS.md §5c): Modern B/C and its pivot,
/// Satin with Anti-aliased off, Dissolve coverage, Vibrance hold-outs, Luminosity at 50 %,
/// Precise Outer Glow. `PCRENDER_M2_DIR=<batch>`; the Satin contours also need `PCRENDER_M1_DIR`.
@Suite(.enabled(if: M2.available, "measurement batch M2 not present (set PHOTOCRAFT_FIXTURES or PCRENDER_M2_DIR)"))
struct PhotoshopM2Tests {
    /// Modern (`brightnessModeModern`) B/C: one curve per channel, Contrast after Brightness.
    @Test func modernBrightnessContrast() throws {
        let base = try M2.image("tif/identity-rgb8.tif")
        var worst = M1.Fit()
        for b in [-150, -50, 0, 50, 150] {
            for c in b == 0 ? [-50, -25, 0, 25, 50, 75, 100] : [-50, 0, 50, 100] {
                let ps = try M2.image("tif/bcm-b\(b)-c\(c)-rgb8.tif")
                var d = M1.document(base)
                d.layers.append(DT.adjustment(.brightnessContrast(.init(brightness: Float(b), contrast: Float(c), mode: .modern))))
                let f = M1.fit(ps, DT.render(d, tol: M1.flip, name: "bcm-b\(b)-c\(c)"))
                M1.say("modern B/C b\(b) c\(c): \(f)")
                // Negative Brightness (the inverse of the positive curve) is the weakest part:
                // −150 reaches 5 levels, and with Contrast 100 9 % > 2 levels.
                #expect(f.max <= 5 && f.mean < 1.2 && f.offShare < 0.1, "b\(b) c\(c): \(f)")
                if f.mean > worst.mean { worst = f }
            }
        }
        let ps16 = try M2.image("tif/bcm-b50-c50-rgb16.tif")
        var d = M1.document(try M2.image("tif/identity-rgb16.tif"))
        d.layers.append(DT.adjustment(.brightnessContrast(.init(brightness: 50, contrast: 50, mode: .modern))))
        let f16 = M1.fit(ps16, DT.render(d, tol: M1.flip, name: "bcm-b50-c50-rgb16"))
        M1.say("modern B/C b50 c50 16-bit: \(f16)")
        #expect(f16.max <= 2 && f16.offShare == 0, "16-bit: \(f16)")
    }

    /// Modern Contrast's curve does not depend on the image (flat greys, half and half-black lattices).
    @Test func modernContrastPivotIsFixed() throws {
        for n in ["flat-032", "flat-064", "flat-096", "flat-128", "flat-160", "flat-192", "flat-224", "lattice-half", "lattice-left-black"] {
            let ps = try M2.image("tif/bcm-pivot-\(n)-b0-c50.tif")
            var d = M1.document(try M2.image("inputs/\(n)-rgb8.png"))
            d.layers.append(DT.adjustment(.brightnessContrast(.init(contrast: 50, mode: .modern))))
            let f = M1.fit(ps, DT.render(d, tol: M1.flip, name: "pivot-\(n)"))
            M1.say("modern contrast 50 over \(n): \(f)")
            #expect(f.max <= 1, "\(n): \(f)")
        }
    }

    /// Satin with Anti-aliased off (the contour read once per pixel), Linear at 30° (offset
    /// (−10, 6): sin 30° · 11 = 5.5 rounds away from 0) and sizes 7 / 15.
    @Test(.enabled(if: M1.available, "the Satin contours come from M1")) func satinVariants() throws {
        let jobs = try M1.jobs(root: M2.dir)
        for id in ["satin2-cone-noaa-a19-d11-s14", "satin2-ring-noaa-a19-d11-s14", "satin2-gaussian-noaa-a19-d11-s14", "satin2-linear-a30-d11-s14",
                   "satin2-linear-a19-d11-s7", "satin2-linear-a19-d11-s15"] {
            for name in [id, "\(id)-raw"] {
                let job = try #require(jobs[name])
                let p = try #require(job["params"] as? [String: Any])
                let ps = try M2.image("tif/\(name).tif")
                let bg = try #require(p["background"] as? [Double])
                var d = Document.withBackground(name: name, size: PixelSize(width: ps.w, height: ps.h), mode: .rgb, depth: .u8,
                                                fill: .rgb(Float(bg[0] / 255), Float(bg[1] / 255), Float(bg[2] / 255)))
                let (rect, alpha) = try M1.layerAlpha(psd: "psd/\(name).psd", layer: "Shapes", root: M2.dir)
                var data = [Float](repeating: 1, count: rect.area * 4)
                for i in 0..<rect.area { data[i * 4 + 3] = Float(alpha[i]) / 255 }
                var l = Layer.raster("Shapes", format: DT.rgba8)
                l.withRaster { $0.writeRegion(rect, data) }
                l.fillOpacity = Float((p["layerFill"] as? Double) ?? 100) / 100
                l.effects.items = [.satin(try PhotoshopM1Tests.satin(job))]
                d.layers.append(l)
                let f = M1.fit(ps, DT.render(d, name: name))
                M1.say("\(name): \(f)")
                // Ring's curve: see `satinRawMaps`.
                #expect(f.mean < 1 && f.offShare < (name.contains("ring") ? 0.08 : 0.02), "\(name): \(f)")
            }
        }
    }

    /// Dissolve: our coverage at each opacity, Fill and mask value matches Photoshop's (our own
    /// noise, AB-D-0130), and Fill / mask / Opacity use unrelated fields.
    @Test func dissolveCoverage() throws {
        let jobs = try M1.jobs(root: M2.dir)
        func render(opacity: Float, fill: Float, mask: Float?) -> [Bool] {
            var d = Document.withBackground(name: "d", size: PixelSize(width: 512, height: 512), mode: .rgb, depth: .u8, fill: .white)
            var l = DT.solidLayer("red", DT.rect(0, 0, 512, 512), DT.rgba(1, 0, 0))
            l.blend = .dissolve
            l.opacity = opacity; l.fillOpacity = fill
            if let mask {
                var m = Surface(format: PixelFormat(mode: .grayscale, sample: .u8, alpha: false))
                m.fill(DT.rect(0, 0, 512, 512), with: [mask])
                l.mask = LayerMask(surface: m)
            }
            d.layers.append(l)
            let r = DT.render(d, name: "dissolve")
            return r.px.map { $0.y < 0.5 }
        }
        for (id, job) in jobs where id.hasPrefix("dissolve-") && !id.contains("long") {
            let p = try #require(job["params"] as? [String: Any])
            let r = try #require(job["result"] as? [String: Any])
            let stored = try #require(r["stored"] as? [String: Any])
            let want = try #require((r["coverage"] as? [String: Any])?["coverage"] as? Double)
            let opacity = Float(try #require(stored["opacity"] as? Int)) / 255, fill = Float(try #require(stored["fillOpacity"] as? Int)) / 255
            let mask: Float? = (p["mask"] as? Bool) == true ? 128.0 / 255 : nil
            let red = render(opacity: opacity, fill: fill, mask: mask)
            let got = Double(red.filter { $0 }.count) / Double(red.count)
            M1.say(String(format: "dissolve %@: Photoshop %.4f, ours %.4f", id, want, got))
            #expect(abs(got - want) < 0.004, "\(id): \(got) vs \(want)")
        }
        let (o50, f50, m50) = (render(opacity: 128.0 / 255, fill: 1, mask: nil), render(opacity: 1, fill: 128.0 / 255, mask: nil), render(opacity: 1, fill: 1, mask: 128.0 / 255))
        func equal(_ a: [Bool], _ b: [Bool]) -> Double { Double(zip(a, b).filter { $0 == $1 }.count) / Double(a.count) }
        #expect(abs(equal(o50, f50) - 0.5) < 0.01 && abs(equal(o50, m50) - 0.5) < 0.01 && abs(equal(f50, m50) - 0.5) < 0.01)
        let o45 = render(opacity: 115.0 / 255, fill: 1, mask: nil)
        #expect(zip(o45, o50).allSatisfy { !$0 || $1 }, "nested: every pixel drawn at 45 % is drawn at 50 %")
    }

    /// Vibrance hold-outs (±25, ±75; Vibrance 100 at 16 bits).
    @Test func vibranceHoldOuts() throws {
        let base8 = try M2.image("tif/identity-rgb8.tif"), base16 = try M2.image("tif/identity-rgb16.tif")
        for (v, bits) in [(-75, 8), (-25, 8), (25, 8), (75, 8), (100, 16)] {
            let ps = try M2.image("tif/vib2-v\(v)-s0-rgb\(bits).tif")
            var d = M1.document(bits == 16 ? base16 : base8)
            d.layers.append(DT.adjustment(.vibrance(vibrance: Float(v), saturation: 0)))
            let f = M1.fit(ps, DT.render(d, tol: M1.flip, name: "vib2-v\(v)-\(bits)"))
            M1.say("vibrance \(v) (\(bits)-bit): \(f)")
            #expect(f.mean < 0.7 && f.offShare < 0.03, "vibrance \(v) \(bits)-bit: \(f)")
        }
    }

    /// Luminosity at 50 % opacity: the 8-bit whole-level result, then the opacity mix.
    @Test func luminosityAtHalfOpacity() throws {
        let base = try M2.image("inputs/identity-rgb8.png")
        for perm in ["a", "b"] {
            let ps = try M2.image("tif/blend2-luminosity-o50-perm\(perm)-rgb8.tif")
            var d = M1.document(base)
            var l = M1.rasterLayer("top", try M2.image("inputs/perm-\(perm)-rgb8.png"))
            l.blend = .luminosity
            l.opacity = 128.0 / 255
            d.layers.append(l)
            let f = M1.fit(ps, DT.render(d, tol: M1.flip, name: "lum50-\(perm)"))
            M1.say("luminosity 50 % perm-\(perm): \(f)")
            #expect(f.max <= 1.01 && f.offShare == 0, "perm-\(perm): \(f)")
        }
    }

    /// Precise Outer Glow (size 120, Linear) round a Fill-0 % square: Range 100 % and 50 %.
    @Test func preciseOuterGlowLinear() throws {
        for (id, range) in [("contour-linear-noaa", Float(1)), ("contour-linear-noaa-range50", Float(0.5))] {
            let ps = try M2.image("tif/\(id).tif")
            var d = Document.withBackground(name: id, size: PixelSize(width: 640, height: 640), mode: .rgb, depth: .u8, fill: .black)
            var l = DT.solidLayer("square", DT.rect(192, 192, 448, 448), DT.white)
            l.fillOpacity = 0
            l.effects.items = [.outerGlow(Glow(common: FxCommon(.normal, 1), paint: .color(.rgb(1, 1, 1)), technique: .precise, spread: 0, size: 120,
                                               contour: .linear, antiAlias: false, range: range, jitter: 0, noise: 0))]
            d.layers.append(l)
            let f = M1.fit(ps, DT.render(d, name: id))
            M1.say("\(id): \(f)")
            // Exact along the sides; off the diagonals Photoshop's distance runs up to ~2 px longer
            // than the Euclidean one (an approximate distance transform), up to 7 levels at Range 50 %.
            #expect(f.mean < 0.5 && f.offShare < 0.06, "\(id): \(f)")
        }
    }
}

/// Brightness/Contrast's three modes in the compositor (no measurement data needed).
struct BrightnessContrastModeTests {
    func grey(_ adj: Adjustment) -> SIMD4<Float> {
        var d = DT.docWhite(4, 4)
        d.layers.append(DT.solidLayer("g", DT.rect(0, 0, 4, 4), DT.rgba(0.4, 0.5, 0.6)))
        d.layers.append(DT.adjustment(adj))
        return DT.px(d, 1, 1)
    }

    @Test func lightIgnoresBrightnessModernAppliesIt() {
        let base = grey(.brightnessContrast(.init(mode: .modern)))
        #expect(DT.close4(grey(.brightnessContrast(.init(brightness: 60, mode: .light))), base, 0.5 / 255), "Light drops Brightness, as Photoshop 27 does")
        #expect(grey(.brightnessContrast(.init(brightness: 60, mode: .modern))).x > base.x + 0.05)
        #expect(!DT.close4(grey(.brightnessContrast(.init(contrast: 60, mode: .light))), grey(.brightnessContrast(.init(contrast: 60, mode: .modern))), 1.0 / 255),
                "Light Contrast (ProPhoto, pivot 157) differs from Modern's (per channel, pivot 128)")
    }

    /// Light mode's Exposure, Whites and Blacks (M3 fits) change pixels on CPU and Metal alike.
    @Test func lightExposureWhitesBlacksApply() {
        let base = grey(.brightnessContrast(.init(mode: .light)))
        for adj in [Adjustment.BrightnessContrast(mode: .light, exposure: 1), .init(mode: .light, exposure: -1), .init(mode: .light, whites: 50),
                    .init(mode: .light, whites: -50), .init(mode: .light, blacks: 50), .init(mode: .light, blacks: -50)] {
            #expect(!DT.close4(grey(.brightnessContrast(adj)), base, 0.5 / 255), "\(adj)")
        }
        // Exposure brightens / darkens monotonically; the composite grey curve is what Lab's L takes.
        let up = AdjustMath.lightToneLUT(.init(mode: .light, exposure: 1.25)), down = AdjustMath.lightToneLUT(.init(mode: .light, exposure: -1.25))
        #expect(zip(up, up.dropFirst()).allSatisfy { $0 <= $1 } && zip(down, down.dropFirst()).allSatisfy { $0 <= $1 })
        #expect(AdjustMath.lut(up, 0.5) > 0.7 && AdjustMath.lut(down, 0.5) < 0.32 && AdjustMath.lut(up, 1) == 1)
    }

    /// TODO: Highlights and Shadows are local in Photoshop (M3: the ramp rows of one job differ near
    /// the lattice, and the lattice's own greys differ from the ramp's by up to 56 levels), so no
    /// grey curve reproduces them; they stay identity (PORT-NOTES phase 5, M3).
    @Test func lightHighlightsShadowsAreIdentity() {
        let base = grey(.brightnessContrast(.init(mode: .light)))
        withKnownIssue("Light mode's Highlights / Shadows are local operators, not modelled") {
            for adj in [Adjustment.BrightnessContrast(mode: .light, highlights: 50), .init(mode: .light, shadows: 50)] {
                #expect(!DT.close4(grey(.brightnessContrast(adj)), base, 0.5 / 255), "\(adj)")
            }
        }
    }
}

// MARK: - Batch M3 (phase 5: Light mode)

enum M3 {
    /// `PCRENDER_M3_DIR`, default `<fixtures>/ps-measure/M3`; nil without its `manifest.json`.
    static let dir: URL? = {
        guard let u = Fixtures.directory("PCRENDER_M3_DIR", default: "ps-measure/M3") else { return nil }
        return FileManager.default.fileExists(atPath: u.appendingPathComponent("manifest.json").path) ? u : nil
    }()
    static var available: Bool { dir != nil }
    static func image(_ rel: String) throws -> M1.Image { try M1.image(rel, root: dir) }

    /// `M1.fit` over rows `ys` only (the lattice: 0..<512; the grey ramp: 512..<528).
    static func fit(_ ps: M1.Image, _ ours: RGBABuffer, rows ys: Range<Int>) -> M1.Fit {
        var f = M1.Fit()
        let s = ps.scale
        for y in ys {
            for x in 0..<ps.w {
                let o = ours.get(Int32(x), Int32(y))
                let mine = (simd_clamp(SIMD3(o.x, o.y, o.z), .zero, SIMD3(repeating: 1)) * s).rounded(.toNearestOrAwayFromZero)
                let v = ps.at(x, y)
                f.add((simd_abs(mine - SIMD3(Float(v.x), Float(v.y), Float(v.z))) * 255 / s).max())
            }
        }
        return f
    }

    typealias BC = Adjustment.BrightnessContrast
    /// Photoshop's job against our render: (lattice, ramp).
    static func run(_ job: String, _ bc: BC, bits: Int = 8) throws -> (lattice: M1.Fit, ramp: M1.Fit) {
        let ps = try image("tif/\(job)-rgb\(bits).tif")
        var d = M1.document(try image("tif/identity-rgb\(bits).tif"))
        d.layers.append(DT.adjustment(.brightnessContrast(bc)))
        let r = DT.render(d, tol: M1.flip, name: job)
        let out = (fit(ps, r, rows: 0..<512), fit(ps, r, rows: 512..<528))
        M1.say("light \(job) \(bits)-bit: lattice \(out.0) | ramp \(out.1)")
        return out
    }
}

/// Photoshop 27.11 batch M3 (ps-oracle `measure m3`, RESULTS.md §5d): Light mode's controls one at
/// a time and three combinations. The grey ramp carries the tone fit; the 64³ lattice adds how the
/// grey curve reaches colours (`AdjustMath.LightStageMode`), which is approximate. `PCRENDER_M3_DIR`.
@Suite(.enabled(if: M3.available, "measurement batch M3 not present (set PHOTOCRAFT_FIXTURES or PCRENDER_M3_DIR)"))
struct PhotoshopM3Tests {
    typealias BC = Adjustment.BrightnessContrast

    @Test func lightDefaultIsIdentity() throws {
        let (l, r) = try M3.run("light-default", BC(mode: .light))
        #expect(l.max == 0 && r.max == 0, "\(l) | \(r)")
    }

    /// Exposure ψ⁻¹(ψ(x) + EV) (`lightPsiPositive` / `lightPsiNegative`; +2.5 held out of ψ's
    /// fit gives the same numbers within 0.2 levels mean).
    @Test func lightExposure() throws {
        for (n, ev) in [("m5", -5.0), ("m2p5", -2.5), ("m1p25", -1.25), ("1p25", 1.25), ("2p5", 2.5), ("5", 5.0)] as [(String, Float)] {
            let (l, r) = try M3.run("light-exposure-\(n)", BC(mode: .light, exposure: ev))
            if ev > 0 {
                #expect(r.max <= 2, "ramp EV \(ev): \(r)")
            } else {
                // Negative Exposure's top 15 levels at −1.25 do not compose with −2.5 / −5.
                #expect(r.max <= 11 && r.mean < 1.1, "ramp EV \(ev): \(r)")
            }
            // Colours: the RGB tone on linear ProPhoto; Photoshop desaturates the most saturated
            // colours more (mean 4.4 at +1.25 / +2.5).
            #expect(l.mean < 4.6 && l.offShare < 0.5, "lattice EV \(ev): \(l)")
        }
        let (l16, r16) = try M3.run("light-exposure-1p25", BC(mode: .light, exposure: 1.25), bits: 16)
        #expect(r16.max <= 2 && l16.mean < 4.6, "16-bit: \(l16) | \(r16)")
    }

    /// Contrast (phase 4's model, fitted on M1) on M3's ramps — an independent check — and its
    /// colours.
    @Test func lightContrast() throws {
        for c: Float in [-50, 50, 100] {
            let (l, r) = try M3.run("light-contrast-\(c < 0 ? "m" : "")\(Int(abs(c)))", BC(contrast: c, mode: .light))
            #expect(r.max <= 2 && l.mean < 2.1 && l.offShare < 0.25, "contrast \(c): \(l) | \(r)")
        }
    }

    /// Whites and Blacks as flows (`AdjustMath.LightFlow`).
    @Test func lightWhitesBlacks() throws {
        // (job, adjustment, ramp max, lattice mean)
        let cases: [(String, BC, Float, Float)] = [
            ("light-whites-m100", BC(mode: .light, whites: -100), 2, 6.6), ("light-whites-m50", BC(mode: .light, whites: -50), 3, 4.7),
            ("light-whites-50", BC(mode: .light, whites: 50), 7, 9.1), ("light-whites-100", BC(mode: .light, whites: 100), 4, 12.3),
            ("light-blacks-m100", BC(mode: .light, blacks: -100), 2, 4.9), ("light-blacks-m50", BC(mode: .light, blacks: -50), 3, 2.5),
            ("light-blacks-50", BC(mode: .light, blacks: 50), 1, 4.7), ("light-blacks-100", BC(mode: .light, blacks: 100), 1, 8.2),
        ]
        for (job, bc, rampMax, latticeMean) in cases {
            let (l, r) = try M3.run(job, bc)
            #expect(r.max <= rampMax && l.mean < latticeMean, "\(job): \(l) | \(r)")
        }
    }

    /// The combinations, held out of every fit. Exposure then Contrast is exact on the ramp; the
    /// two with Highlights / Shadows wait on a model of those local controls.
    @Test func lightCombinations() throws {
        let (l, r) = try M3.run("light-combo-exposure1p25-contrast50", BC(contrast: 50, mode: .light, exposure: 1.25))
        #expect(r.max <= 2 && l.mean < 6, "exposure 1.25 + contrast 50: \(l) | \(r)")
        let (l2, r2) = try M3.run("light-combo-highlights-m50-shadows50", BC(mode: .light, highlights: -50, shadows: 50))
        let (l5, r5) = try M3.run("light-combo-five", BC(mode: .light, exposure: 0.625, whites: 25, blacks: -25, highlights: -30, shadows: 30))
        withKnownIssue("Highlights / Shadows are local in Photoshop and identity here") {
            #expect(r2.max <= 2 && l2.mean < 2, "highlights −50 + shadows 50: \(l2) | \(r2)")
            #expect(r5.max <= 2 && l5.mean < 3, "five controls: \(l5) | \(r5)")
        }
    }
}
